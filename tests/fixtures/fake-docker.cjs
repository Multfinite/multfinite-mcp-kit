#!/usr/bin/env node
// Synthetic Docker Desktop boundary for POSIX PowerShell tests. This does NOT
// test real Docker networking or build an image. Secrets on stdin are never
// written to the argument trace.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
const stateFile = process.env.MCP_TEST_DOCKER_STATE;
const traceFile = process.env.MCP_TEST_DOCKER_TRACE;
if (!stateFile || !traceFile) process.exit(90);
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : { container: {}, volume: {}, network: {}, image: {}, seeds: 0 };
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
fs.appendFileSync(traceFile, `${JSON.stringify(args)}\n`);
const isCompose = args[0] === '--context' && args[1] === 'desktop-linux' && args[2] === 'compose';
const polluted = Object.keys(process.env).filter((name) =>
  (/^(COMPOSE_|POSTGRES_|BOOTSTRAP_|METAMCP_)/i.test(name) || /^(DOCKER_HOST|DOCKER_CONTEXT|DATABASE_URL|APP_URL|BETTER_AUTH_SECRET)$/i.test(name)) &&
  !(isCompose && name.toUpperCase() === 'APP_URL'));
if (polluted.length) { console.error(`unrelated environment leaked: ${polluted.join(',')}`); process.exit(91); }
function fail(message, code = 1) { console.error(message); process.exit(code); }
function input() { return new Promise((resolve) => { let data = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', (part) => data += part); process.stdin.on('end', () => resolve(data)); }); }
function envFile(file) {
  return Object.fromEntries(fs.readFileSync(file, 'utf8').split(/\r?\n/).filter((line) => /^[A-Z][A-Z0-9_]*=/.test(line)).map((line) => { const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)]; }));
}
function writeJson(value) { console.log(JSON.stringify(value)); }
function composeConfig(e, clone) {
  const labels = { 'com.multfinite.mcpkit.instance': e.MCPKIT_INSTANCE };
  const appEnv = { ...e,
    POSTGRES_HOST: 'postgres', POSTGRES_PORT: '5432', POSTGRES_USER: 'metamcp_user', POSTGRES_DB: 'metamcp_db',
    DATABASE_URL: `postgresql://metamcp_user:${e.POSTGRES_PASSWORD}@postgres:5432/metamcp_db`, NEXT_PUBLIC_APP_URL: e.APP_URL,
    BOOTSTRAP_ENABLE: 'false', BOOTSTRAP_USER_NAME: '', BOOTSTRAP_USER_EMAIL: '', BOOTSTRAP_USER_PASSWORD: '',
    BOOTSTRAP_USERS: '', BOOTSTRAP_API_KEYS: '', BOOTSTRAP_NAMESPACES: '', BOOTSTRAP_ENDPOINTS: '',
    BOOTSTRAP_RECREATE_USER: 'false', BOOTSTRAP_DELETE_OTHER_USERS: 'false', METAMCP_ADMIN_EMAILS: e.MCPKIT_METAMCP_ADMIN_EMAILS || '' };
  const ports = [{ host_ip: process.env.MCP_TEST_UNSAFE_PORT ? '0.0.0.0' : '127.0.0.1', published: e.MCPKIT_METAMCP_PORT, target: 12008, protocol: 'tcp' }];
  if (Number(e.MCPKIT_METAMCP_BACKEND_PORT) > 0) ports.push({ host_ip: '127.0.0.1', published: e.MCPKIT_METAMCP_BACKEND_PORT, target: 12009, protocol: 'tcp' });
  return { services: {
    app: { image: e.MCPKIT_IMAGE, container_name: `${e.MCPKIT_PROJECT}-app`, build: { context: clone, dockerfile: 'Dockerfile' },
      ports, labels,
      volumes: [{ type: 'volume', source: 'uv_cache', target: '/home/nextjs/.cache/uv' }], environment: appEnv },
    postgres: { image: 'postgres:16-alpine', container_name: `${e.MCPKIT_PROJECT}-postgres`, labels,
      volumes: [{ type: 'volume', source: 'postgres_data', target: '/var/lib/postgresql/data' }],
      environment: { POSTGRES_USER: 'metamcp_user', POSTGRES_PASSWORD: e.POSTGRES_PASSWORD, POSTGRES_DB: 'metamcp_db' } },
  } };
}
async function main() {
  if (args[0] === 'context' && args[1] === 'inspect') {
    console.log(process.env.MCP_TEST_REMOTE_CONTEXT ? 'tcp://remote.example:2376' : 'npipe:////./pipe/dockerDesktopLinuxEngine'); return;
  }
  if (args[0] !== '--context' || args[1] !== 'desktop-linux') fail('The expected local Desktop context was not selected');
  const command = args.slice(2);
  if (command[0] === 'info') { console.log('Docker Desktop|linux'); return; }
  if (command[0] === 'compose' && command[1] === 'version') { console.log('v2.32.1'); return; }
  if (command[0] === 'compose') {
    const project = command[command.indexOf('--project-name') + 1];
    const clone = command[command.indexOf('--project-directory') + 1];
    const envPath = command[command.indexOf('--env-file') + 1];
    if (process.env.MCPKIT_ENV_FILE !== envPath) fail('wrong private env file');
    const e = envFile(envPath);
    // Compose shell interpolation overrides the initial values in the env
    // file. Model that for an existing installation whose ports were changed.
    for (const name of ['APP_URL', 'MCPKIT_METAMCP_PORT', 'MCPKIT_METAMCP_BACKEND_PORT', 'MCPKIT_METAMCP_ADMIN_EMAILS', 'MCPKIT_IMAGE']) {
      if (process.env[name] !== undefined) e[name] = process.env[name];
    }
    if (project !== e.MCPKIT_PROJECT) fail('wrong project');
    const operation = command.find((x) => ['config', 'build', 'up', 'ps'].includes(x));
    if (operation === 'config') {
      if (process.env.MCP_TEST_REAL_COMPOSE) {
        const result = spawnSync(process.env.MCP_TEST_REAL_COMPOSE, command.slice(1), { env: process.env, encoding: 'utf8' });
        if (result.status !== 0) fail(result.stderr || 'real Compose config failed');
        if (process.env.MCP_TEST_UNSAFE_PORT) { const config = JSON.parse(result.stdout); config.services.app.ports[0].host_ip = '0.0.0.0'; writeJson(config); }
        else process.stdout.write(result.stdout);
      } else writeJson(composeConfig(e, clone));
      return;
    }
    const labels = { 'com.multfinite.mcpkit.instance': e.MCPKIT_INSTANCE, 'com.docker.compose.project': project };
    if (operation === 'build') { state.image[e.MCPKIT_IMAGE] = labels; save(); return; }
    if (operation === 'up') {
      const recreate = command.includes('--force-recreate');
      if (!command.includes('--no-build') || (recreate ? (!command.includes('--no-deps') || command.at(-1) !== 'app') : !command.includes('--no-recreate'))) fail('missing preservation flags');
      if (recreate && process.env.MCP_TEST_RECREATE_FAIL) fail('simulated port conflict');
      const postgresOnly = command.at(-1) === 'postgres';
      const appOnly = command.at(-1) === 'app';
      const newApp = !state.container[`${project}-app`];
      if (!postgresOnly) state.container[`${project}-app`] ||= labels;
      if (!appOnly) state.container[`${project}-postgres`] ||= labels;
      if (!postgresOnly && (newApp || recreate)) {
        const applied = composeConfig(e, clone).services.app.environment;
        state.appliedAuth = { bootstrap: applied.BOOTSTRAP_ENABLE, email: applied.BOOTSTRAP_USER_EMAIL,
          password: applied.BOOTSTRAP_USER_PASSWORD, admins: applied.METAMCP_ADMIN_EMAILS };
      }
      for (const suffix of ['postgres_data', 'uv_cache']) state.volume[`${project}_${suffix}`] ||= labels;
      state.network[`${project}_metamcp-network`] ||= labels;
      if (!postgresOnly) {
        state.running = true;
        state.lastAppImage = e.MCPKIT_IMAGE;
        state.lastFrontendPort = e.MCPKIT_METAMCP_PORT;
        state.lastBackendPort = e.MCPKIT_METAMCP_BACKEND_PORT;
        state.lastAppUrl = e.APP_URL;
      }
      if (recreate) state.appRecreates = (state.appRecreates || 0) + 1;
      state.upCalls = (state.upCalls || 0) + 1; save(); return;
    }
    if (operation === 'ps') { console.log(`${project}-app running\n${project}-postgres running`); return; }
    fail('Unexpected compose operation');
  }
  if (['container', 'volume', 'network', 'image'].includes(command[0]) && command[1] === 'inspect') {
    const kind = command[0]; const name = command.at(-1); const labels = state[kind][name];
    if (!labels) fail(`Error: No such ${kind}: ${name}`);
    writeJson(labels); return;
  }
  if (command[0] === 'container' && command[1] === 'ls') {
    const filter = command[command.indexOf('--filter') + 1]; const project = filter.slice('label=com.docker.compose.project='.length);
    for (const [name, labels] of Object.entries(state.container)) if (labels['com.docker.compose.project'] === project) console.log(name);
    return;
  }
  if (command[0] === 'stop') { state.running = false; state.stopCalls = (state.stopCalls || 0) + 1; save(); return; }
  if (command[0] === 'start') {
    if (!state.container[command.at(-1)]) fail('cannot restart an unowned container');
    state.running = true; state.startCalls = (state.startCalls || 0) + 1; save(); return;
  }
  if (command[0] === 'commit') {
    const container = command.at(-2); const image = command.at(-1);
    if (!state.container[container] || state.image[image]) fail('cannot snapshot container');
    state.image[image] = state.container[container]; state.snapshots = (state.snapshots || 0) + 1; save();
    console.log('sha256:synthetic'); return;
  }
  if (command[0] === 'logs') { console.log('synthetic MetaMCP log'); return; }
  if (command[0] === 'exec' && command.includes('sh') && command.includes('-c')) {
    const script = command.at(-1);
    if (script.includes('pg_dump')) {
      if (state.running || !command.some((arg) => arg.endsWith('-postgres'))) fail('backup must use the owned PostgreSQL container with the app stopped');
      if (process.env.MCP_TEST_BACKUP_FAIL) fail('simulated backup failure');
      const name = script.match(/mcpkit-pre-(?:seed|reset)-v3-[0-9]{14}-[a-f0-9]{8}\.dump/);
      if (!name) fail('invalid database backup name');
      state.databaseBackups ||= []; state.databaseBackups.push(name[0]); save();
      console.log('backup-ok'); return;
    }
    if (script.includes('psql')) {
      const text = await input();
      if (text.includes("SELECT 'signup-open'")) {
        state.signupDisabled = false; state.explicitSignupEnables = (state.explicitSignupEnables || 0) + 1; save();
        console.log('signup-open'); return;
      }
      const match = text.match(/\\set local_bundle_b64 '([A-Za-z0-9+/=]+)'/);
      if (!match || !text.includes('host.docker.internal:') || text.includes('DISABLE_SIGNUP')) fail('invalid or unsafe SQL input');
      const bundle = JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
      if (process.env.MCP_TEST_CAPTURE) fs.writeFileSync(process.env.MCP_TEST_CAPTURE, JSON.stringify(bundle));
      const users = state.users || [];
      const matches = bundle.ownerEmail ? users.filter((u) => u.email.toLowerCase() === bundle.ownerEmail.toLowerCase()) : [];
      if (bundle.ownerEmail && !matches.length) { console.log('missing|||||'); return; }
      if (bundle.ownerEmail && matches.length !== 1) { console.log('ambiguous|||||'); return; }
      const base = `local-${bundle.hostId}`;
      const mode = text.match(/\\set local_force '(true|false|skip-only|reset-all)'/)?.[1];
      if (!mode || !command.some((arg) => arg.endsWith('-postgres'))) fail('invalid local seed mode or container');
      const previous = state.sharedSeed;
      const initialized = [3, 4].includes(previous?.version);
      if (mode === 'skip-only' && !initialized) { console.log('needs-apply|||||'); return; }
      const result = initialized && !['true', 'reset-all'].includes(mode) ? 'skipped' : 'seeded';
      if (result === 'seeded') {
        if (state.running || !state.databaseBackups?.length) fail('app must be stopped and PostgreSQL backed up before applying seed');
        if (mode === 'reset-all') {
          if (process.env.MCP_TEST_RESET_FAIL) fail('simulated reset transaction failure');
          if (!state.databaseBackups.at(-1).startsWith('mcpkit-pre-reset-v3-')) fail('reset requires its own pre-change backup');
          state.resetCalls = (state.resetCalls || 0) + 1;
          state.seedRecords = {};
          state.manualRecords = [];
        }
        const version = mode === 'reset-all' || !previous || previous.version === 4 ? 4 : 3;
        state.sharedSeed = { serverCount: 13, owner: null, version,
          serverNames: ['desktop-commander', 'everything-search', 'filesystem', 'windows-mcp', 'git', 'codegraph',
            'codebase-memory-mcp', 'serena', 'playwright', 'dbhub', 'simple-files-vectorstore', 'markitdown', 'obsidian'],
          groups: ['code', 'data', 'files', 'memory', 'system', 'web'].map((suffix) => version === 4 ? suffix : `${base}-${suffix}`) };
        for (const legacy of Object.values(state.seedRecords || {})) {
          legacy.owner = null; legacy.serverCount = 0; legacy.endpointPublic = true;
        }
        state.seeds++;
      }
      save();
      const warnings = result === 'seeded' ? (state.seedWarnings || {}) : {};
      const groups = state.sharedSeed.groups.filter((group) => !(warnings.blocked || '').split(',').includes(group));
      const owner = matches[0] ? Buffer.from(matches[0].email).toString('base64') : '';
      console.log(`${result}|${owner}|${groups.join(',')}|${warnings.blocked || ''}|${warnings.conflicts || ''}|${warnings.deferred || ''}`); return;
    }
    if (script.includes('curl')) { if (state.running) return; fail('not running'); }
  }
  if (command[0] === 'exec' && command.includes('node') && command.includes('-e')) {
    const config = JSON.parse(await input());
    if (process.env.MCP_TEST_BRIDGE_FAIL) fail('simulated Docker Desktop route failure');
    const req = http.get({ hostname: '127.0.0.1', port: config.port, path: '/_mcpkit/status', headers: { 'X-Mcpkit-Control': config.key }, timeout: 5000 }, (res) => {
      let body = ''; res.setEncoding('utf8'); res.on('data', (part) => body += part);
      res.on('end', () => { try { if (res.statusCode === 200 && JSON.parse(body).instanceId === config.instanceId) { console.log('bridge-ok'); return; } } catch {} process.exitCode = 1; });
    });
    req.on('error', () => { process.exitCode = 1; }); req.on('timeout', () => req.destroy()); return;
  }
  fail(`Unexpected synthetic Docker command: ${command.join(' ')}`);
}
main().catch((error) => { console.error(error.stack); process.exit(1); });
