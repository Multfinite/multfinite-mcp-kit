#!/usr/bin/env node
// Independent MetaMCP / GLOBAL Compose projects for Linux and Windows.
// The legacy installations are deliberately not discovered or migrated.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline/promises';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const revision = '05818ec2767b946f98d280ae9cefa401f0362d62';
const [action, ...argv] = process.argv.slice(2);

function fail(message) { throw new Error(message); }
function parseArgs(args) {
  const result = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--delete-volumes') { result.deleteVolumes = true; continue; }
    const key = { '--dir': 'dir', '--port': 'port', '--app-url': 'appUrl', '--meta-dir': 'metaDir', '--server': 'server' }[arg];
    if (!key || i + 1 >= args.length || args[i + 1].startsWith('--') || result[key] !== undefined) fail(`Invalid argument: ${arg}`);
    result[key] = args[++i];
  }
  return result;
}
function privateWrite(file, text) {
  fs.writeFileSync(file, text, { flag: 'wx', mode: 0o600 });
}
function random() { return crypto.randomBytes(32).toString('hex'); }
function validPort(value) {
  const port = Number(value);
  if (!/^\d{1,5}$/.test(String(value)) || !Number.isInteger(port) || port < 1 || port > 65535) fail('Port must be an integer from 1 to 65535.');
  return port;
}
function validOrigin(value) {
  let u;
  try { u = new URL(value); } catch { fail('APP_URL must be an absolute http(s) origin.'); }
  if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password || u.pathname !== '/' || u.search || u.hash) fail('APP_URL must contain only scheme, host and optional port.');
  if (u.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(u.hostname)) fail('Use HTTPS for a non-loopback APP_URL. Configure the reverse proxy separately.');
  return u.origin;
}
function cleanEnv(extra = {}) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    const upper = name.toUpperCase();
    if (/^(MCPKIT_|COMPOSE_|POSTGRES_|BOOTSTRAP_|GIT_)/.test(upper) ||
        ['APP_URL', 'NEXT_PUBLIC_APP_URL', 'EXTRA_TRUSTED_ORIGINS', 'DATABASE_URL', 'BETTER_AUTH_SECRET', 'METAMCP_ADMIN_EMAILS', 'NEO4J_PASSWORD',
          'LLM_API_KEY', 'LLM_API_ENDPOINT', 'LLM_API_MODEL', 'LLM_API_PROVIDER', 'EMBEDDING_MODEL', 'EMBEDDING_DIMENSIONS',
          'CONTEXT7_API_KEY', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'].includes(upper)) delete env[name];
  }
  return { ...env, GIT_TERMINAL_PROMPT: '0', ...extra };
}
function run(exe, args, { capture = false, allowFailure = false, env = cleanEnv() } = {}) {
  const result = spawnSync(exe, args, { env, encoding: 'utf8', stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit', windowsHide: true, maxBuffer: 16 * 1024 * 1024 });
  if (result.error) fail(`Cannot start ${exe}: ${result.error.message}`);
  if (result.status !== 0 && !allowFailure) {
    const detail = capture ? `: ${(result.stderr || '').trim().slice(-1200)}` : '';
    fail(`${exe} failed (exit ${result.status})${detail}`);
  }
  return result;
}
function dockerContext() {
  // An explicit docker context is required for every command. Never silently
  // operate on DOCKER_HOST, a remote daemon, or another Docker Desktop context.
  if (process.env.DOCKER_HOST || process.env.DOCKER_CONTEXT) fail('Unset DOCKER_HOST and DOCKER_CONTEXT before using independent kit projects; no remote daemon is selected automatically.');
  const name = process.platform === 'win32' ? 'desktop-linux' : run('docker', ['context', 'show'], { capture: true }).stdout.trim();
  if (!name || /[\r\n]/.test(name)) fail('Cannot determine the local Docker context.');
  const endpoint = run('docker', ['context', 'inspect', name, '--format', '{{.Endpoints.docker.Host}}'], { capture: true }).stdout.trim();
  if (process.platform === 'win32') {
    if (!/^npipe:\/\/\/\/[.]\/pipe\/dockerDesktopLinuxEngine$/i.test(endpoint)) fail('desktop-linux is not the local Docker Desktop Linux engine.');
  } else if (!/^unix:\/\/\//.test(endpoint)) fail('This operation is restricted to a local Unix-socket Docker context.');
  run('docker', ['--context', name, 'info'], { capture: true });
  run('docker', ['--context', name, 'compose', 'version'], { capture: true });
  return name;
}
function originState(base) {
  const f = path.join(base, '.mcpkit', 'state.json');
  if (!fs.existsSync(f)) fail(`Independent kit state not found: ${f}. Existing/legacy files were not changed.`);
  const s = JSON.parse(fs.readFileSync(f, 'utf8'));
  if (s.version !== 1 || !['meta', 'global'].includes(s.type) || !/^[a-f0-9]{16}$/.test(s.id) ||
      s.project !== `mcpkit-${s.type}-${s.id}` || s.base !== base || validPort(s.port) !== s.port ||
      (s.type === 'meta' && validOrigin(s.appUrl) !== s.appUrl)) fail('Invalid or relocated kit state; no Docker resource was changed.');
  return s;
}
function readEnv(base, type) {
  const file = path.join(base, '.mcpkit', '.env');
  if (!fs.existsSync(file)) fail(`Missing private credentials: ${file}. Restore from backup; secrets are not regenerated.`);
  const values = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
    if (match) {
      if (Object.hasOwn(values, match[1])) fail(`Duplicate key in private env: ${match[1]}`);
      values[match[1]] = match[2];
    }
  }
  const required = type === 'meta' ? ['POSTGRES_PASSWORD', 'BETTER_AUTH_SECRET'] : ['MCPKIT_GATEWAY_KEY', 'MCPKIT_CONTROL_KEY', 'NEO4J_PASSWORD'];
  for (const key of required) {
    if (!/^[a-f0-9]{64}$/.test(values[key] || '')) {
      fail(`Invalid or missing ${key} in the private .env: expected the original 64 lowercase hexadecimal characters without quotes or spaces. Restore the exact original value from a private backup; existing credentials were not changed.`);
    }
  }
  if (type === 'global' && values.MCPKIT_GATEWAY_KEY === values.MCPKIT_CONTROL_KEY) fail('Gateway and control credentials must differ.');
  return values;
}
function initialize(type, opts) {
  const base = path.resolve(opts.dir || '');
  if (!opts.dir) fail('Pass --dir for the new independent installation.');
  if (fs.existsSync(base) && fs.lstatSync(base).isSymbolicLink()) fail('The installation directory must not itself be a symlink.');
  fs.mkdirSync(base, { recursive: true, mode: 0o700 });
  const existing = fs.readdirSync(base);
  if (existing.includes('.mcpkit') && fs.existsSync(path.join(base, '.mcpkit', 'state.json'))) {
    const state = originState(base);
    if (state.type !== type) fail('This directory belongs to a different kind of installation.');
    readEnv(base, type);
    console.log(`Existing ${type} installation preserved; port ${state.port} remains unchanged.`);
    return state;
  }
  if (existing.length) fail(`Directory is not empty and has no matching kit state; nothing was overwritten: ${base}`);
  const port = validPort(opts.port); // An explicit port is mandatory for every new instance.
  const appUrl = type === 'meta' ? validOrigin(opts.appUrl || `http://localhost:${port}`) : '';
  const id = crypto.randomBytes(8).toString('hex');
  const state = { version: 1, type, id, project: `mcpkit-${type}-${id}`, base, port, ...(type === 'meta' ? { appUrl, revision } : {}) };
  const priv = path.join(base, '.mcpkit');
  fs.mkdirSync(priv, { mode: 0o700 });
  const env = type === 'meta'
    ? `POSTGRES_PASSWORD=${random()}\nBETTER_AUTH_SECRET=${random()}\n# Configure an admin allowlist only after those accounts exist.\nMETAMCP_ADMIN_EMAILS=\n# APP_URL is always trusted; add only other origins you explicitly trust.\nEXTRA_TRUSTED_ORIGINS=\n`
    : `MCPKIT_GATEWAY_KEY=${random()}\nMCPKIT_CONTROL_KEY=${random()}\nNEO4J_PASSWORD=${random()}\n# Edit these values, then run apply. Keep this file private.\nLLM_API_KEY=\nLLM_API_ENDPOINT=https://api.openai.com/v1\nLLM_API_MODEL=gpt-4o-mini\nLLM_API_PROVIDER=openai\nEMBEDDING_MODEL=text-embedding-3-small\nEMBEDDING_DIMENSIONS=1536\nCONTEXT7_API_KEY=\n`;
  privateWrite(path.join(priv, '.env'), env);
  if (type === 'global') {
    const build = path.join(priv, 'build');
    const nodeBuild = path.join(priv, 'node-build');
    fs.mkdirSync(build, { mode: 0o700 });
    fs.mkdirSync(nodeBuild, { mode: 0o700 });
    for (const [source, dest] of [
      ['common/global/Dockerfile', path.join(build, 'Dockerfile')],
      ['common/global/global-kit.mjs', path.join(build, 'global-kit.mjs')],
      ['windows/gateway.mjs', path.join(build, 'gateway.mjs')],
      ['linux/services/node-mcp/Dockerfile', path.join(nodeBuild, 'Dockerfile')],
    ]) fs.copyFileSync(path.join(root, source), dest, fs.constants.COPYFILE_EXCL);
  }
  privateWrite(path.join(priv, 'state.json'), `${JSON.stringify(state, null, 2)}\n`);
  console.log(`Created ${type} state at ${base}. Docker project: ${state.project}.`);
  return state;
}
function config(state) {
  const priv = path.join(state.base, '.mcpkit');
  const common = {
    MCPKIT_INSTANCE: state.id,
    MCPKIT_PROJECT: state.project,
    MCPKIT_PORT: String(state.port),
    MCPKIT_IMAGE: `${state.project}-${state.type === 'meta' ? 'metamcp' : 'gateway'}:1`,
  };
  if (state.type === 'meta') {
    Object.assign(common, { MCPKIT_SOURCE: path.join(state.base, 'metamcp'), MCPKIT_APP_URL: state.appUrl });
  } else {
    Object.assign(common, { MCPKIT_BUILD_DIR: path.join(priv, 'build'), MCPKIT_NODE_BUILD_DIR: path.join(priv, 'node-build'), MCPKIT_NODE_IMAGE: `${state.project}-node:1` });
  }
  return common;
}
function composeArgs(ctx, state, command) {
  const args = ['--context', ctx, 'compose', '--project-name', state.project, '--project-directory', state.base,
    '--env-file', path.join(state.base, '.mcpkit', '.env'), '-f', path.join(root, 'common', state.type === 'meta' ? 'metamcp-compose.yml' : 'global-compose.yml')];
  if (state.type === 'meta' && process.platform === 'linux') args.push('-f', path.join(root, 'common', 'metamcp-linux.yml'));
  return [...args, ...command];
}
function compose(ctx, state, args, capture = false) {
  return run('docker', composeArgs(ctx, state, args), { capture, env: cleanEnv(config(state)) });
}
function inspect(ctx, kind, name) {
  const format = kind === 'container' || kind === 'image' ? '{{json .Config.Labels}}' : '{{json .Labels}}';
  const result = run('docker', ['--context', ctx, kind, 'inspect', '--format', format, name], { capture: true, allowFailure: true });
  if (result.status !== 0) {
    const error = (result.stderr || '').trim();
    // Docker Engine also reports a missing network as "network NAME not
    // found" rather than "No such network". Match the requested kind and
    // exact name so unrelated daemon/permission errors still fail closed.
    const namedMissing = `Error response from daemon: ${kind} ${name} not found`;
    if (/no such (?:container|image|network|volume|object)/i.test(error) ||
        error.toLowerCase() === namedMissing.toLowerCase()) return null;
    fail(`Cannot inspect ${kind} ${name}: ${error.slice(-500)}`);
  }
  try { return JSON.parse(result.stdout.trim()) || {}; } catch { fail(`Invalid labels on ${kind} ${name}.`); }
}
function checkLabel(labels, state, kind, name) {
  if (labels && (labels['com.multfinite.mcpkit.instance'] !== state.id ||
      (kind !== 'image' && labels['com.docker.compose.project'] !== state.project))) {
    fail(`${kind} ${name} is not owned by this kit instance; it was not changed.`);
  }
}
function checkResources(ctx, state) {
  const list = run('docker', ['--context', ctx, 'container', 'ls', '-aq', '--filter', `label=com.docker.compose.project=${state.project}`], { capture: true });
  for (const id of list.stdout.trim().split(/\s+/).filter(Boolean)) checkLabel(inspect(ctx, 'container', id), state, 'container', id);
  for (const suffix of state.type === 'global' ? ['default', 'client'] : ['default']) {
    const network = `${state.project}_${suffix}`;
    checkLabel(inspect(ctx, 'network', network), state, 'network', network);
  }
  const volumes = state.type === 'meta' ? ['postgres_data', 'uv_cache'] : ['gateway_data', 'neo4j_data', 'qdrant_data', 'cognee_system', 'cognee_data', 'memory_data', 'gdrive_data'];
  for (const suffix of volumes) {
    const name = `${state.project}_${suffix}`;
    checkLabel(inspect(ctx, 'volume', name), state, 'volume', name);
  }
}
function stopOwnedContainers(ctx, state) {
  // Stopping running containers must work even when the private .env is
  // missing or invalid. Select only this instance's Compose services, verify
  // ownership of every candidate before stopping anything, and leave one-off
  // containers alone. No credentials, networks or volumes are changed.
  const order = state.type === 'meta'
    ? ['app', 'postgres']
    : ['gateway', 'graphiti', 'cognee', 'gdrive', 'memory', 'neo4j', 'qdrant'];
  const result = run('docker', ['--context', ctx, 'container', 'ls', '-q', '--filter', `label=com.docker.compose.project=${state.project}`], { capture: true });
  const ids = result.stdout.trim().split(/\s+/).filter(Boolean);
  const groups = new Map(order.map((service) => [service, []]));
  let oneOffs = 0;
  for (const id of ids) {
    if (!/^[a-f0-9]{12,64}$/.test(id)) fail('Unexpected Docker container ID; no containers were stopped.');
    const labels = inspect(ctx, 'container', id);
    if (!labels) fail(`Container ${id} disappeared during preflight; no containers were stopped. Retry after checking status.`);
    checkLabel(labels, state, 'container', id);
    if (String(labels['com.docker.compose.oneoff'] || '').toLowerCase() === 'true') { oneOffs++; continue; }
    const service = labels['com.docker.compose.service'];
    if (!groups.has(service)) fail(`Unexpected service for container ${id}; no containers were stopped.`);
    groups.get(service).push(id);
  }
  if (oneOffs) console.log(`Leaving ${oneOffs} Compose one-off container(s) unchanged.`);
  if (![...groups.values()].some((group) => group.length)) {
    console.log(`No running kit service containers found for ${state.project}.`);
    return;
  }
  // Stop clients first, then their dependencies, preserving Compose's usual
  // dependency order. Already-stopped containers were not included above.
  for (const service of order) {
    const group = groups.get(service);
    if (group.length) run('docker', ['--context', ctx, 'container', 'stop', ...group]);
  }
  console.log('Kit service containers stopped. Credentials, files and volumes were not changed.');
}
function networkMembers(ctx, name) {
  const result = run('docker', ['--context', ctx, 'network', 'inspect', '--format', '{{json .Containers}}', name], { capture: true });
  let containers;
  try { containers = JSON.parse(result.stdout.trim()) || {}; } catch { fail(`Cannot inspect network membership: ${name}`); }
  if (typeof containers !== 'object' || Array.isArray(containers) || Object.keys(containers).some((id) => !/^[a-f0-9]{12,64}$/.test(id))) {
    fail(`Unexpected network membership: ${name}`);
  }
  return Object.keys(containers);
}
function sameContainer(a, b) { return a.startsWith(b) || b.startsWith(a); }
function requireUnusedByOthers(ctx, state) {
  // Compose down may remove project containers before discovering that a
  // different project's container still uses the network. Check first.
  for (const suffix of state.type === 'global' ? ['default', 'client'] : ['default']) {
    const name = `${state.project}_${suffix}`;
    if (!inspect(ctx, 'network', name)) continue;
    for (const id of networkMembers(ctx, name)) {
      const labels = inspect(ctx, 'container', id);
      if (!labels || labels['com.multfinite.mcpkit.instance'] !== state.id || labels['com.docker.compose.project'] !== state.project) {
        fail(`Network ${name} is used by another container (${id}). Disconnect it explicitly before removal; nothing was removed.`);
      }
    }
  }
}
function ensureSource(state) {
  const source = path.join(state.base, 'metamcp');
  const marker = path.join(source, '.git', 'mcpkit-instance');
  if (!fs.existsSync(source)) {
    const scratch = fs.mkdtempSync(path.join(state.base, '.mcpkit', 'clone-'));
    console.log('Cloning the pinned MetaMCP revision into the new kit directory...');
    run('git', ['clone', '--no-checkout', '--depth', '1', 'https://github.com/metatool-ai/metamcp.git', scratch]);
    run('git', ['-C', scratch, 'fetch', '--depth', '1', 'origin', revision]);
    run('git', ['-C', scratch, 'checkout', '--detach', revision]);
    privateWrite(path.join(scratch, '.git', 'mcpkit-instance'), `${state.id}\n`);
    fs.renameSync(scratch, source);
  }
  if (!fs.existsSync(marker) || fs.readFileSync(marker, 'utf8').trim() !== state.id) fail('MetaMCP clone is not owned by this installation. It was preserved.');
  const actual = run('git', ['-C', source, 'rev-parse', 'HEAD'], { capture: true }).stdout.trim();
  if (actual !== revision || state.revision !== revision) fail('MetaMCP clone revision differs from the saved revision. No build was attempted.');
  return source;
}
function ensureImages(ctx, state) {
  const images = state.type === 'meta' ? [[config(state).MCPKIT_IMAGE, 'app']] : [[config(state).MCPKIT_IMAGE, 'gateway'], [config(state).MCPKIT_NODE_IMAGE, 'memory']];
  let dirtyChecked = false;
  for (const [image, service] of images) {
    const labels = inspect(ctx, 'image', image);
    checkLabel(labels, state, 'image', image);
    if (labels) continue;
    if (state.type === 'meta' && !dirtyChecked) {
      const status = run('git', ['-C', path.join(state.base, 'metamcp'), 'status', '--porcelain', '--untracked-files=all'], { capture: true }).stdout;
      if (status.trim()) fail('MetaMCP clone has local/untracked files. They were not sent to Docker; restore an owned clean clone before building.');
      dirtyChecked = true;
    }
    console.log(`Building the isolated ${service} image; this can take a while.`);
    compose(ctx, state, ['build', service]);
    const built = inspect(ctx, 'image', image);
    if (!built) fail(`Built image is missing: ${image}`);
    checkLabel(built, state, 'image', image);
  }
}
async function start(ctx, state) {
  readEnv(state.base, state.type);
  checkResources(ctx, state);
  if (state.type === 'meta') ensureSource(state);
  ensureImages(ctx, state);
  checkResources(ctx, state);
  compose(ctx, state, ['up', '-d', '--no-recreate', '--no-build']);
  if (state.type === 'meta') {
    const target = `http://127.0.0.1:${state.port}/health`;
    let ready = false;
    for (let i = 0; i < 120; i++) {
      try { const r = await fetch(target, { signal: AbortSignal.timeout(2000), redirect: 'error' }); if (r.ok) { ready = true; break; } } catch { /* still starting */ }
      await delay(1000);
    }
    if (!ready) fail('MetaMCP did not become healthy within 120 seconds. Containers and data were kept; inspect logs.');
    console.log(`MetaMCP passed its local health check on port ${state.port}. Use its configured origin: ${state.appUrl}`);
    if (state.appUrl !== `http://localhost:${state.port}`) console.log('For an external origin, configure its HTTPS reverse proxy before signing in.');
    console.log('Create your own user and API key in the UI. Close signup yourself; an empty admin allowlist treats every signed-in user as an admin.');
  } else {
    console.log(`GLOBAL gateway is bound to 127.0.0.1:${state.port}. Servers may still be starting or waiting for credentials.`);
    console.log(`Private configuration: ${path.join(state.base, '.mcpkit', '.env')}`);
  }
}
async function confirm(message, expected) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) fail('Confirmation requires an interactive terminal.');
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try { return (await rl.question(`${message}\nType ${expected}: `)) === expected; } finally { rl.close(); }
}
function stoppedMetaService(ctx, state, service) {
  const result = run('docker', ['--context', ctx, 'container', 'ls', '-aq', '--no-trunc',
    '--filter', `label=com.docker.compose.project=${state.project}`], { capture: true });
  const ids = result.stdout.trim().split(/\s+/).filter(Boolean);
  const found = [];
  for (const id of ids) {
    if (!/^[a-f0-9]{12,64}$/.test(id)) fail('Unexpected Docker container ID; recovery was not performed.');
    const labels = inspect(ctx, 'container', id);
    if (!labels) fail('A container disappeared during recovery; no file was changed.');
    checkLabel(labels, state, 'container', id);
    if (labels['com.docker.compose.service'] === service &&
        String(labels['com.docker.compose.oneoff'] || '').toLowerCase() !== 'true') found.push(id);
  }
  if (found.length !== 1) fail(`Expected exactly one owned ${service} container; no file was changed.`);
  const running = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.State.Running}}', found[0]], { capture: true }).stdout.trim();
  if (running !== 'false') fail(`Stop the selected MetaMCP ${service} container before recovery; no file was changed.`);
  return found[0];
}
function containerEnvironment(ctx, id) {
  const result = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .Config.Env}}', id], { capture: true });
  let entries;
  try { entries = JSON.parse(result.stdout.trim()); } catch { fail('Could not read container configuration; no file was changed.'); }
  if (!Array.isArray(entries)) fail('Unexpected container configuration; no file was changed.');
  const values = Object.create(null);
  for (const entry of entries) {
    if (typeof entry !== 'string' || !entry.includes('=')) fail('Unexpected container environment; no file was changed.');
    const index = entry.indexOf('=');
    const key = entry.slice(0, index);
    if (!key || Object.hasOwn(values, key)) fail('Ambiguous container environment; no file was changed.');
    values[key] = entry.slice(index + 1);
  }
  return values;
}
function metaRecoverySnapshot(ctx, state) {
  const appId = stoppedMetaService(ctx, state, 'app');
  const postgresId = stoppedMetaService(ctx, state, 'postgres');
  const app = containerEnvironment(ctx, appId);
  const postgres = containerEnvironment(ctx, postgresId);
  const password = postgres.POSTGRES_PASSWORD;
  const secret = app.BETTER_AUTH_SECRET;
  if (!/^[a-f0-9]{64}$/.test(password || '') || !/^[a-f0-9]{64}$/.test(secret || '') ||
      app.POSTGRES_PASSWORD !== password || postgres.POSTGRES_USER !== 'metamcp_user' || postgres.POSTGRES_DB !== 'metamcp_db' ||
      app.POSTGRES_USER !== 'metamcp_user' || app.POSTGRES_DB !== 'metamcp_db' || app.POSTGRES_HOST !== 'postgres' || app.POSTGRES_PORT !== '5432' ||
      app.DATABASE_URL !== `postgresql://metamcp_user:${password}@postgres:5432/metamcp_db`) {
    fail('Container database credentials or configuration do not match the expected kit format; no file was changed.');
  }
  if (app.APP_URL !== state.appUrl || app.NEXT_PUBLIC_APP_URL !== state.appUrl ||
      typeof app.METAMCP_ADMIN_EMAILS !== 'string' || typeof app.EXTRA_TRUSTED_ORIGINS !== 'string' ||
      !app.EXTRA_TRUSTED_ORIGINS.startsWith(`${state.appUrl},`)) {
    fail('Container MetaMCP settings differ from the saved kit state; no file was changed.');
  }
  const mountsResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .Mounts}}', postgresId], { capture: true });
  let mounts;
  try { mounts = JSON.parse(mountsResult.stdout.trim()); } catch { fail('Cannot inspect the PostgreSQL mount; no file was changed.'); }
  const dbMounts = Array.isArray(mounts) ? mounts.filter((item) => item?.Destination === '/var/lib/postgresql/data') : [];
  const volume = `${state.project}_postgres_data`;
  if (dbMounts.length !== 1 || dbMounts[0].Type !== 'volume' || dbMounts[0].Name !== volume) {
    fail('Unexpected PostgreSQL data mount; no file was changed.');
  }
  const labels = inspect(ctx, 'volume', volume);
  if (!labels) fail('The PostgreSQL volume was not found; no file was changed.');
  checkLabel(labels, state, 'volume', volume);
  if (labels['com.docker.compose.volume'] !== 'postgres_data') fail('Unexpected PostgreSQL volume identity; no file was changed.');
  return { appId, postgresId, password, secret, admins: app.METAMCP_ADMIN_EMAILS,
    extraOrigins: app.EXTRA_TRUSTED_ORIGINS.slice(state.appUrl.length + 1) };
}
function safeDotenvLiteral(value) {
  if (typeof value !== 'string' || /[\x00-\x1f\x7f'\\]/.test(value)) {
    fail('Stored MetaMCP admin/origin settings need manual recovery; no file was changed.');
  }
  return `'${value}'`;
}
function privateRegularFile(file) {
  let item;
  try { item = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  if (!item.isFile() || item.isSymbolicLink() || item.size > 1024 * 1024) fail('The existing private .env is not a regular file or is too large; it was not changed.');
  return fs.readFileSync(file);
}
async function recoverMetaEnv(ctx, state) {
  if (process.platform !== 'linux' || state.type !== 'meta') fail('recover-env is only available for an independent MetaMCP on Linux.');
  const priv = path.join(state.base, '.mcpkit');
  for (const dir of [state.base, priv]) {
    const item = fs.lstatSync(dir);
    if (!item.isDirectory() || item.isSymbolicLink()) fail('The MetaMCP directory and private directory must not be links; nothing was changed.');
  }
  const stateFile = path.join(priv, 'state.json');
  const stateItem = fs.lstatSync(stateFile);
  if (!stateItem.isFile() || stateItem.isSymbolicLink() || stateItem.size > 1024 * 1024) fail('The kit state must be a regular file; nothing was changed.');
  const stateBytes = fs.readFileSync(stateFile);
  let savedState;
  try { savedState = JSON.parse(stateBytes.toString('utf8')); } catch { fail('Cannot read the kit state; nothing was changed.'); }
  if (JSON.stringify(savedState) !== JSON.stringify(state)) fail('The kit state changed during recovery; no file was changed.');
  const file = path.join(priv, '.env');
  const current = privateRegularFile(file);
  const snapshot = metaRecoverySnapshot(ctx, state);
  const recovered = `POSTGRES_PASSWORD=${snapshot.password}\nBETTER_AUTH_SECRET=${snapshot.secret}\n` +
    `METAMCP_ADMIN_EMAILS=${safeDotenvLiteral(snapshot.admins)}\nEXTRA_TRUSTED_ORIGINS=${safeDotenvLiteral(snapshot.extraOrigins)}\n`;
  if (current) {
    // Never replace a nonempty credential we cannot identify as the same
    // literal. PostgreSQL can have non-kit passwords and dotenv comments or
    // interpolation are ambiguous; those cases require manual review.
    let matching = 0;
    for (const [key, value] of [['POSTGRES_PASSWORD', snapshot.password], ['BETTER_AUTH_SECRET', snapshot.secret]]) {
      const pattern = new RegExp(`^\\s*(?:export\\s+)?${key}\\s*=\\s*(.*)$`);
      const matches = current.toString('utf8').split(/\r?\n/).map((line) => pattern.exec(line)).filter(Boolean);
      if (matches.length > 1) fail(`Multiple ${key} entries need manual review; no file was changed.`);
      if (matches.length === 1) {
        const raw = matches[0][1].trim();
        const empty = raw === '' || raw === "''" || raw === '""';
        const same = raw === value || raw === `'${value}'` || raw === `"${value}"`;
        if (!empty && !same) fail(`A different or unrecognized ${key} needs manual review; no file was changed.`);
        if (matches[0][0] === `${key}=${value}`) matching++;
      }
    }
    if (matching === 2) fail('The private .env already contains the same credentials as the containers; no recovery was performed.');
  }
  const message = `Recover the MetaMCP .env for ${state.project} from its stopped, verified containers?\n` +
    'The existing .env will be saved as a private backup. Containers and volumes are not changed.\n' +
    'Only MetaMCP settings from the containers will be restored; other or unapplied settings remain in the backup.\n' +
    'Container values may not be the current DB password or historical auth secret (e.g. after SQL changes or recreation with a different .env). Stop if unsure.';
  if (!(await confirm(message, `RECOVER ${state.project}`))) { console.log('Cancelled; no file was changed.'); return; }
  const rechecked = metaRecoverySnapshot(ctx, state);
  for (const key of ['appId', 'postgresId', 'password', 'secret', 'admins', 'extraOrigins']) {
    if (rechecked[key] !== snapshot[key]) fail('Container configuration changed during recovery; no file was changed.');
  }
  const checkedState = fs.lstatSync(stateFile);
  if (!checkedState.isFile() || checkedState.isSymbolicLink() || checkedState.size > 1024 * 1024 || !fs.readFileSync(stateFile).equals(stateBytes)) {
    fail('The kit state changed during recovery; no file was changed.');
  }
  const now = privateRegularFile(file);
  if ((current === null) !== (now === null) || (current && !current.equals(now))) fail('The private .env changed during recovery; no file was changed.');
  if (current) {
    const backup = path.join(priv, `.env.before-recovery-${crypto.randomBytes(8).toString('hex')}.backup`);
    privateWrite(backup, current);
    console.log(`Previous private configuration saved at ${backup}. Keep this backup private.`);
  }
  const temp = `${file}.recovery-${crypto.randomBytes(8).toString('hex')}.tmp`;
  let tempCreated = false;
  try {
    privateWrite(temp, recovered);
    tempCreated = true;
    const atCommit = privateRegularFile(file);
    if ((current === null) !== (atCommit === null) || (current && !current.equals(atCommit))) {
      fail('The private .env changed during recovery and was not replaced; a backup may have been saved.');
    }
    fs.renameSync(temp, file);
    tempCreated = false;
  } finally { if (tempCreated) { try { fs.unlinkSync(temp); } catch { /* left for inspection */ } } }
  console.log('MetaMCP credentials recovered from the verified containers. Containers and volumes were not changed.');
}
// Gateway diagnostics run inside the verified kit container. The control key
// never appears in command arguments or is sent to an unrelated host port.
function showGlobalStatus(ctx, state) {
  const id = compose(ctx, state, ['ps', '-q', 'gateway'], true).stdout.trim();
  if (!/^[a-f0-9]{12,64}$/.test(id)) { console.log('GLOBAL gateway is not running; no individual status is available.'); return; }
  const labels = inspect(ctx, 'container', id);
  if (!labels) fail('The GLOBAL gateway disappeared before status could be read.');
  checkLabel(labels, state, 'container', id);
  const script = "fetch('http://127.0.0.1:13001/_mcpkit/status',{headers:{'X-Mcpkit-Control':process.env.MCPKIT_CONTROL_KEY},signal:AbortSignal.timeout(5000)})" +
    ".then(async r=>{if(!r.ok)throw Error('gateway status unavailable');process.stdout.write(JSON.stringify(await r.json()))})" +
    ".catch(e=>{console.error(e.message);process.exitCode=1})";
  const result = compose(ctx, state, ['exec', '-T', 'gateway', 'node', '-e', script], true);
  let snapshot;
  try { snapshot = JSON.parse(result.stdout.trim()); } catch { fail('Invalid GLOBAL gateway status response.'); }
  if (snapshot.instanceId !== state.id || !Array.isArray(snapshot.servers)) fail('GLOBAL gateway status belongs to a different instance.');
  console.log('\nGLOBAL MCP servers (ready means MCP initialize succeeded):');
  for (const item of snapshot.servers) {
    if (typeof item.id !== 'string' || typeof item.status !== 'string' || typeof item.detail !== 'string') fail('Invalid GLOBAL server status.');
    console.log(`${item.status.padEnd(9)} ${item.id}${item.detail ? `: ${item.detail}` : ''}`);
  }
  console.log('GitHub MCP is registered directly in MetaMCP and needs its own token.');
}
function showGlobalLog(ctx, state, id) {
  const allowed = new Set(['sequentialthinking', 'graphiti', 'cognee', 'memory-bank-mcp', 'context7', 'duckduckgo', 'fetch', 'io-draw', 'mcp-compass', 'gdrive', 'neo4j-global', 'qdrant-global', 'playwright']);
  if (!allowed.has(id)) fail(`Unknown GLOBAL server: ${id}`);
  // HTTP sidecars log through their own Compose services; stdio servers log
  // into the gateway's named volume. No host path is accepted as input.
  const service = { graphiti: 'graphiti', cognee: 'cognee', 'memory-bank-mcp': 'memory', gdrive: 'gdrive' }[id];
  if (service) { compose(ctx, state, ['logs', '--tail', '100', service]); return; }
  const gatewayId = compose(ctx, state, ['ps', '-q', 'gateway'], true).stdout.trim();
  if (!/^[a-f0-9]{12,64}$/.test(gatewayId)) fail('Start the GLOBAL gateway to read its server log.');
  const labels = inspect(ctx, 'container', gatewayId);
  if (!labels) fail('The GLOBAL gateway disappeared before logs could be read.');
  checkLabel(labels, state, 'container', gatewayId);
  const script = "const fs=require('node:fs');const f='/data/logs/'+process.argv[1]+'.log';" +
    "if(!fs.existsSync(f)){console.log('No log yet.');process.exit(0)}" +
    "console.log(fs.readFileSync(f,'utf8').split('\\n').slice(-100).join('\\n'))";
  compose(ctx, state, ['exec', '-T', 'gateway', 'node', '-e', script, id]);
}
function connectLocalProjects(ctx, globalState, metaDir, detach) {
  if (globalState.type !== 'global' || !metaDir) fail('link/unlink requires the GLOBAL directory and --meta-dir for a kit-owned MetaMCP.');
  const meta = originState(path.resolve(metaDir));
  if (meta.type !== 'meta') fail('The selected MetaMCP directory does not contain an independent MetaMCP.');
  readEnv(meta.base, meta.type);
  checkResources(ctx, globalState);
  checkResources(ctx, meta);
  const gatewayId = compose(ctx, globalState, ['ps', '-q', 'gateway'], true).stdout.trim();
  const appId = compose(ctx, meta, ['ps', '-q', 'app'], true).stdout.trim();
  if (!/^[a-f0-9]{12,64}$/.test(gatewayId) || !/^[a-f0-9]{12,64}$/.test(appId)) fail('Start both the GLOBAL gateway and the selected MetaMCP first.');
  const gatewayLabels = inspect(ctx, 'container', gatewayId);
  const appLabels = inspect(ctx, 'container', appId);
  if (!gatewayLabels || !appLabels) fail('A selected container disappeared; no network was changed.');
  checkLabel(gatewayLabels, globalState, 'container', gatewayId);
  checkLabel(appLabels, meta, 'container', appId);
  if (gatewayLabels['com.docker.compose.service'] !== 'gateway' || appLabels['com.docker.compose.service'] !== 'app') fail('Unexpected service identity; no network was changed.');
  const network = `${globalState.project}_client`;
  const networkLabels = inspect(ctx, 'network', network);
  if (!networkLabels) fail('The isolated GLOBAL client network does not exist; start the GLOBAL project first.');
  checkLabel(networkLabels, globalState, 'network', network);
  const internal = run('docker', ['--context', ctx, 'network', 'inspect', '--format', '{{.Internal}}', network], { capture: true }).stdout.trim();
  if (internal !== 'true') fail('The GLOBAL client network is not internal; no network was changed.');
  const name = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.Name}}', gatewayId], { capture: true }).stdout.trim().replace(/^\//, '');
  if (!new RegExp(`^${globalState.project}-gateway-[0-9]+$`).test(name)) fail('Unexpected gateway container name; no network was changed.');
  const clientIds = networkMembers(ctx, network);
  const attached = clientIds.some((id) => sameContainer(id, appId));
  if (detach && attached) run('docker', ['--context', ctx, 'network', 'disconnect', network, appId]);
  else if (!detach) {
    if (!clientIds.some((id) => sameContainer(id, gatewayId))) fail('Gateway is not on the isolated client network; no network was changed.');
    const backend = `${globalState.project}_default`;
    const backendIds = networkMembers(ctx, backend);
    if (backendIds.some((id) => sameContainer(id, appId))) fail('MetaMCP is already on the GLOBAL backend network. Disconnect it explicitly before linking; no network was changed.');
    // Refuse an unexpected bridge or sidecar on the client network instead of
    // claiming isolation while an unauthenticated backend could be reachable.
    for (const id of clientIds) {
      if (sameContainer(id, gatewayId)) continue;
      const labels = inspect(ctx, 'container', id);
      const project = labels?.['com.docker.compose.project'] || '';
      if (!/^mcpkit-meta-[a-f0-9]{16}$/.test(project) || labels['com.multfinite.mcpkit.instance'] !== project.slice(-16) ||
          labels['com.docker.compose.service'] !== 'app' || backendIds.some((other) => sameContainer(id, other))) {
        fail(`Unexpected container on isolated GLOBAL client network (${id}); no network was changed.`);
      }
    }
    if (!attached) run('docker', ['--context', ctx, 'network', 'connect', network, appId]);
  }
  if (detach) { console.log('The selected MetaMCP was disconnected from the GLOBAL client network; records were not changed.'); return; }
  console.log(`MetaMCP is connected to the isolated GLOBAL client network. Gateway URL for connect-global: http://${globalState.project}-gateway:13001`);
  console.log('Traffic on this local Docker network is not encrypted; use it only if the host and network are trusted. Reconnect after recreating the MetaMCP app.');
}

try {
  if (Number(process.versions.node.split('.')[0]) < 20) fail('Node.js 20 or newer is required.');
  if (!['init-meta', 'init-global', 'start', 'stop', 'status', 'logs', 'apply', 'remove', 'link', 'unlink', 'recover-env'].includes(action)) fail('Usage: stack.mjs {init-meta|init-global|start|stop|status|logs|apply|remove|link|unlink|recover-env} --dir DIR [--port PORT] [--app-url URL] [--delete-volumes] [--meta-dir DIR] [--server ID]');
  const opts = parseArgs(argv);
  if (opts.deleteVolumes && action !== 'remove') fail('--delete-volumes is only valid for remove.');
  if (opts.metaDir && !['link', 'unlink'].includes(action)) fail('--meta-dir is only valid for link/unlink.');
  if (opts.server && action !== 'logs') fail('--server is only valid for logs.');
  if (!opts.dir) fail('--dir is required.');
  const isInit = action === 'init-meta' || action === 'init-global';
  if (!isInit && (opts.port || opts.appUrl)) fail('Ports and APP_URL are only accepted for new installations.');
  if (action === 'init-global' && opts.appUrl) fail('--app-url is only for MetaMCP.');
  const base = path.resolve(opts.dir);
  const state = isInit ? initialize(action === 'init-meta' ? 'meta' : 'global', opts) : originState(base);
  if (opts.server && state.type !== 'global') fail('--server is only available for GLOBAL logs.');
  // Stopping, basic status and the explicit recovery path can operate without
  // credentials; creation, start, apply and removal still validate them.
  let envError = null;
  if (action === 'status') {
    try { readEnv(state.base, state.type); } catch (error) { envError = error; }
  } else if (!['stop', 'recover-env'].includes(action)) readEnv(state.base, state.type);
  const ctx = dockerContext();
  if (isInit || action === 'start') await start(ctx, state);
  else if (action === 'stop') stopOwnedContainers(ctx, state);
  else if (action === 'recover-env') await recoverMetaEnv(ctx, state);
  else if (action === 'link' || action === 'unlink') connectLocalProjects(ctx, state, opts.metaDir, action === 'unlink');
  else if (action === 'apply') {
    if (state.type !== 'global') fail('apply is only for GLOBAL services.');
    checkResources(ctx, state);
    ensureImages(ctx, state);
    console.log('Recreating only the kit gateway, Graphiti and Cognee containers to apply configuration. Named volumes are preserved.');
    compose(ctx, state, ['up', '-d', '--no-deps', '--force-recreate', '--no-build', 'gateway', 'graphiti', 'cognee']);
  } else if (action === 'remove') {
    const expected = `${opts.deleteVolumes ? 'DELETE' : 'REMOVE'} ${state.project}`;
    const warning = opts.deleteVolumes
      ? `WARNING: removing containers AND ALL named volumes of ${state.project}, including database and user data. Back them up first. Files in ${state.base} remain.`
      : `Removing containers and network of ${state.project}; writable container layers are lost. Named volumes and files in ${state.base} remain.`;
    if (!(await confirm(warning, expected))) { console.log('Cancelled; nothing was removed.'); process.exit(0); }
    checkResources(ctx, state);
    requireUnusedByOthers(ctx, state);
    compose(ctx, state, opts.deleteVolumes ? ['down', '--volumes'] : ['down']);
    console.log('Removal completed. No other projects or system packages were intentionally removed.');
  } else {
    checkResources(ctx, state);
    if (action === 'status') {
      if (envError) {
        // Compose needs a parseable env file even for `ps`. Fall back to
        // Docker's label-filtered container list without printing secrets.
        run('docker', ['--context', ctx, 'container', 'ls', '-a',
          '--filter', `label=com.docker.compose.project=${state.project}`,
          '--filter', `label=com.multfinite.mcpkit.instance=${state.id}`,
          '--format', 'table {{.Names}}\t{{.Status}}\t{{.Ports}}']);
        console.warn(`Private configuration needs attention; showing only container status: ${envError.message}`);
      } else compose(ctx, state, ['ps', '-a']);
      console.log(`Project: ${state.project}; port: ${state.port}; directory: ${state.base}`);
      if (state.type === 'global' && !envError) showGlobalStatus(ctx, state);
    } else if (opts.server) showGlobalLog(ctx, state, opts.server);
    else {
      compose(ctx, state, ['logs', '--tail', '100']);
      if (state.type === 'global') console.log('For an individual MCP server log use logs with its server ID. Logs may contain secrets or private data.');
    }
  }
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
}
