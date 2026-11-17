#!/usr/bin/env node
// Create-only registration through MetaMCP's authenticated frontend API.
// No database access, UPDATE, DELETE, or adoption of records by name.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { GLOBAL_GROUPS, GLOBAL_SERVER_NAMES, GLOBAL_GROUP_NAMES } from './registration-manifest.mjs';
import { loadLocalBundle } from './local-registration.mjs';
import { inspectLiveGlobal, startLiveGlobal, enableLiveGlobalRestart, liveGlobalStatus, connectLiveGlobal } from './live-global.mjs';

const [profile, ...rawArgs] = process.argv.slice(2);
function fail(message) { throw new Error(message); }
function parseArgs(args) {
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--json-stdin' && !opts.jsonStdin) { opts.jsonStdin = true; continue; }
    const key = { '--dir': 'dir', '--meta-dir': 'metaDir', '--live-global': 'liveGlobal' }[args[i]];
    if (!key || !args[i + 1] || opts[key]) fail('Usage: register.mjs {local|global} --dir DIRECTORY [--json-stdin --meta-dir METAMCP]');
    opts[key] = args[++i];
  }
  return opts;
}
const json = (file) => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const random = (n) => crypto.randomBytes(n).toString('hex');
function writeAtomic(file, object) {
  const temp = `${file}.${process.pid}.${random(4)}.tmp`;
  try {
    fs.writeFileSync(temp, `${JSON.stringify(object, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temp, file);
  } finally { try { fs.unlinkSync(temp); } catch { /* renamed */ } }
}
function question(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(prompt, (answer) => { rl.close(); resolve(answer.trim()); });
  });
}
function secret(prompt) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) fail('Registration requires an interactive terminal for private credentials.');
  return new Promise((resolve, reject) => {
    let value = '';
    let settled = false;
    process.stdout.write(prompt);
    const cleanup = () => {
      process.stdin.off('data', onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write('\n');
    };
    const onData = (chunk) => {
      for (const c of String(chunk)) {
        if (c === '\u0003') { if (!settled) { settled = true; cleanup(); reject(new Error('Cancelled.')); } return; }
        if (c === '\r' || c === '\n') { if (!settled) { settled = true; cleanup(); resolve(value); } return; }
        if (c === '\u007f' || c === '\b') { value = Array.from(value).slice(0, -1).join(''); continue; }
        if (c >= ' ' && c !== '\u007f' && value.length < 8192) value += c;
      }
    };
    process.stdin.setEncoding('utf8');
    process.stdin.setRawMode(true);
    process.stdin.on('data', onData);
    process.stdin.resume();
  });
}
function validateUrl(text, allowPath) {
  let u;
  try { u = new URL(text); } catch { fail('Enter an absolute http(s) URL.'); }
  if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password || u.search || u.hash) fail('URL must not contain credentials, query parameters, or a fragment.');
  if (!allowPath && u.pathname !== '/') fail('MetaMCP URL must be an origin without a path.');
  // The pinned MetaMCP database accepts DNS/IPv4 hostnames and this path
  // character set, but not IPv6 literals or percent-encoded path segments.
  // Reject unsupported URLs before starting a create-only operation.
  if (allowPath && (!/^[a-z0-9-]+(?:\.[a-z0-9-]+)*$/i.test(u.hostname) ||
      u.pathname.includes('..') || !/^\/[a-z0-9._~:/@!$&'()*+,;=-]*$/i.test(u.pathname))) {
    fail('This MetaMCP version requires a DNS/IPv4 gateway hostname and an unescaped URL path; IPv6 literals and percent-encoded paths are not supported.');
  }
  const base = `${u.origin}${allowPath ? u.pathname.replace(/\/$/, '') : ''}`;
  const insecure = u.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
  return { base, insecure };
}
function globalBundle(base) {
  const privateDir = path.join(base, '.mcpkit');
  const state = json(path.join(privateDir, 'state.json'));
  if (state.version !== 1 || state.type !== 'global' || state.base !== base || !/^[a-f0-9]{16}$/.test(state.id) || state.project !== `mcpkit-global-${state.id}`) fail('Invalid GLOBAL kit state.');
  const matches = fs.readFileSync(path.join(privateDir, '.env'), 'utf8').split(/\r?\n/).filter((line) => line.startsWith('MCPKIT_GATEWAY_KEY='));
  if (matches.length !== 1) fail('GLOBAL gateway key is missing or duplicated.');
  const key = matches[0].slice('MCPKIT_GATEWAY_KEY='.length);
  if (!/^[a-f0-9]{64}$/.test(key)) fail('Invalid GLOBAL gateway key.');
  return { id: state.id, key, privateDir, groups: GLOBAL_GROUPS,
    serverNames: GLOBAL_SERVER_NAMES, groupNames: GLOBAL_GROUP_NAMES };
}
function cookieFrom(response) {
  const lines = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : [response.headers.get('set-cookie') || ''];
  const pairs = [];
  for (const line of lines) {
    // Node versions that coalesce Set-Cookie may separate cookies with commas.
    for (const part of line.split(/,\s*(?=[^;,=\s]+=[^;,]*)/)) {
      const pair = part.split(';', 1)[0].trim();
      if (/^[^=;\s]+=[^;\r\n]+$/.test(pair)) pairs.push(pair);
    }
  }
  return pairs.join('; ');
}
let localTransport = null;
function verifiedLocalMeta(dir, origin) {
  if (process.env.DOCKER_HOST || process.env.DOCKER_CONTEXT) fail('Unset DOCKER_HOST and DOCKER_CONTEXT before local registration.');
  function docker(args) {
    const result = spawnSync('docker', args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, windowsHide: true });
    if (result.error || result.status !== 0) fail('Cannot verify the selected local MetaMCP container.');
    return result.stdout.trim();
  }
  const base = path.resolve(dir);
  const privateDir = path.join(base, '.mcpkit');
  if (fs.realpathSync(base) !== base || !fs.lstatSync(privateDir).isDirectory() || fs.lstatSync(privateDir).isSymbolicLink() ||
      !fs.lstatSync(path.join(privateDir, 'state.json')).isFile() || fs.lstatSync(path.join(privateDir, 'state.json')).isSymbolicLink()) fail('The selected local MetaMCP directory is not a regular kit directory.');
  const state = json(path.join(privateDir, 'state.json'));
  if (state.version !== 1 || state.type !== 'meta' || state.base !== base || !/^[a-f0-9]{16}$/.test(state.id) ||
      state.project !== `mcpkit-meta-${state.id}` || !Number.isInteger(state.port) || state.port < 1 || state.port > 65535 || state.appUrl !== origin ||
      fs.existsSync(path.join(base, '.mcpkit', 'first-setup.json'))) fail('Local MetaMCP state or origin does not match the selected registration.');
  const context = docker(['context', 'show']);
  if (!context || !/^unix:\/\/\//.test(docker(['context', 'inspect', context, '--format', '{{.Endpoints.docker.Host}}']))) fail('Local registration requires a local Unix-socket Docker context.');
  const ids = docker(['--context', context, 'container', 'ls', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${state.project}`, '--filter', 'label=com.docker.compose.service=app']).split(/\s+/).filter(Boolean);
  if (ids.length !== 1 || !/^[a-f0-9]{12,64}$/.test(ids[0])) fail('Expected one running kit-owned MetaMCP app.');
  let app;
  try { app = JSON.parse(docker(['--context', context, 'container', 'inspect', ids[0]]))[0]; } catch { fail('Cannot inspect the selected MetaMCP app.'); }
  const labels = app?.Config?.Labels || {};
  const ports = app?.NetworkSettings?.Ports?.['12008/tcp'];
  const expectedHosts = state.lanIp ? ['127.0.0.1', state.lanIp] : ['127.0.0.1'];
  const env = (app?.Config?.Env || []).filter((entry) => entry.startsWith('APP_URL='));
  if (app?.State?.Running !== true || labels['com.multfinite.mcpkit.instance'] !== state.id || labels['com.docker.compose.project'] !== state.project ||
      labels['com.docker.compose.service'] !== 'app' || String(labels['com.docker.compose.oneoff'] || '').toLowerCase() === 'true' ||
      !Array.isArray(ports) || ports.length !== expectedHosts.length ||
      ports.some((binding) => binding?.HostPort !== String(state.port) || !expectedHosts.includes(binding.HostIp)) ||
      expectedHosts.some((host) => ports.filter((binding) => binding?.HostIp === host).length !== 1) ||
      env.length !== 1 || env[0] !== `APP_URL=${origin}`) fail('The selected app identity or host bindings are unexpected.');
  return { address: `http://127.0.0.1:${state.port}`, containerId: app.Id, context, privateDir, state };
}
function liveGlobalBundle(project, meta, gateway) {
  const live = inspectLiveGlobal(meta.context, project);
  if (!live.clientMembers.includes(meta.containerId) || live.url !== gateway) fail('The selected MetaMCP is not connected to the expected isolated GLOBAL gateway.');
  liveGlobalStatus(live); // authenticated identity and server inventory, never prints secrets
  return { id: live.id, key: live.gatewayKey, privateDir: meta.privateDir, groups: GLOBAL_GROUPS,
    serverNames: GLOBAL_SERVER_NAMES, groupNames: GLOBAL_GROUP_NAMES };
}
async function request(url, opts = {}) {
  let response;
  let address = url;
  let options = opts;
  if (localTransport) {
    const parsed = new URL(url);
    if (parsed.origin !== localTransport.origin) fail('Unexpected registration request origin.');
    address = `${localTransport.address}${parsed.pathname}${parsed.search}`;
    options = { ...opts, headers: { ...(opts.headers || {}), host: new URL(localTransport.origin).host } };
  }
  try { response = await fetch(address, { ...options, redirect: 'error', signal: AbortSignal.timeout(30000) }); }
  catch { fail('Network/TLS request failed or timed out. No redirect was followed; check the URL, certificates and connectivity.'); }
  let body;
  try { body = await response.json(); } catch { fail(`MetaMCP returned non-JSON (HTTP ${response.status}); check the origin and version.`); }
  if (!response.ok) fail(`MetaMCP rejected a request (HTTP ${response.status}); check login, permissions and server version.`);
  return { response, body };
}
async function login(origin, supplied = null) {
  const mode = supplied ? '1' : (await question('Authentication: [1] email/password, [2] existing browser session cookie (SSO) [1]: ')) || '1';
  let cookie;
  if (mode === '1') {
    const email = supplied ? supplied.email : await question('MetaMCP account email: ');
    const password = supplied ? supplied.password : await secret('Password (not echoed): ');
    if (typeof email !== 'string' || typeof password !== 'string' || !email || !password) fail('Email and password are required.');
    const result = await request(`${origin}/api/auth/sign-in/email`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify({ email, password }),
    });
    cookie = cookieFrom(result.response);
    if (!cookie) fail('Login did not return a session cookie. For SSO use an existing session cookie.');
  } else if (mode === '2') {
    cookie = await secret('Paste the Cookie header value (not echoed): ');
    if (!cookie || /[\r\n]/.test(cookie)) fail('Invalid cookie value.');
  } else fail('Unknown authentication method.');
  const session = await request(`${origin}/api/auth/get-session`, { headers: { cookie } });
  if (!session.body?.user?.id || typeof session.body.user.id !== 'string') fail('The MetaMCP session is not authenticated.');
  return { cookie, userId: session.body.user.id };
}
async function requireAdmin(origin, cookie) {
  // This read-only procedure is restricted to administrators in the pinned
  // MetaMCP revision. Never print its response: config values can be private.
  let body;
  try { ({ body } = await request(`${origin}/trpc/frontend.config.getAllConfigs`, { headers: { cookie, origin } })); }
  catch { fail('Cannot confirm MetaMCP administrator access. Use an administrator account; no records were changed.'); }
  let value = body?.result?.data;
  if (value && !Array.isArray(value) && typeof value === 'object' && Object.hasOwn(value, 'json')) value = value.json;
  if (!Array.isArray(value)) fail('Cannot confirm MetaMCP administrator access or version; no records were changed.');
}
async function trpc(origin, cookie, procedure, input, mutation = false) {
  const headers = { cookie, origin };
  const options = { headers };
  let suffix = '';
  if (mutation) {
    options.method = 'POST';
    headers['content-type'] = 'application/json';
    options.body = JSON.stringify(input);
  } else if (input !== undefined) suffix = `?input=${encodeURIComponent(JSON.stringify(input))}`;
  const { body } = await request(`${origin}/trpc/frontend.${procedure}${suffix}`, options);
  let value = body?.result?.data;
  if (value && typeof value === 'object' && Object.hasOwn(value, 'json')) value = value.json;
  if (!value || typeof value !== 'object' || value.success !== true) fail(`MetaMCP procedure ${procedure} failed. Existing records were not updated or deleted.`);
  return value.data;
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
function serverHash(server) {
  const keys = ['uuid', 'name', 'description', 'type', 'command', 'args', 'env', 'url', 'bearerToken', 'headers', 'forward_headers', 'user_id'];
  return digest(JSON.stringify(canonical(Object.fromEntries(keys.map((key) => [key, server[key] ?? null])))));
}
function hasOpenEndpoint(endpoints, namespace) {
  return endpoints.some((e) => e.namespace_uuid === namespace && !e.enable_api_key_auth && !e.enable_oauth);
}
async function main() {
  if (!['local', 'global'].includes(profile)) fail('Choose local or global.');
  if (Number(process.versions.node.split('.')[0]) < 20) fail('Node.js 20 or newer is required.');
  const opts = parseArgs(rawArgs);
  if (!opts.dir && !opts.liveGlobal) fail('--dir is required unless selecting an existing live GLOBAL.');
  if (opts.dir && opts.liveGlobal) fail('Choose either --dir or --live-global, not both.');
  if (!opts.jsonStdin && (!process.stdin.isTTY || !process.stdout.isTTY)) fail('Registration requires an interactive terminal.');
  if (opts.jsonStdin && (profile !== 'global' || !opts.metaDir)) fail('Private stdin registration requires GLOBAL and a local --meta-dir.');
  if (opts.liveGlobal && (profile !== 'global' || !opts.metaDir || !/^mcpkit-global-[a-f0-9]{16}$/.test(opts.liveGlobal))) {
    fail('An existing GLOBAL project and local MetaMCP directory are required.');
  }
  if (!opts.jsonStdin && opts.metaDir && !opts.liveGlobal) fail('Interactive --meta-dir requires --live-global.');
  const interactiveLive = Boolean(opts.liveGlobal && !opts.jsonStdin);
  let supplied = null;
  if (opts.jsonStdin) {
    try { supplied = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { fail('Invalid private registration input.'); }
    if (!supplied || typeof supplied.target !== 'string' || typeof supplied.gateway !== 'string' ||
        typeof supplied.email !== 'string' || typeof supplied.password !== 'string' || !supplied.email || !supplied.password) fail('Invalid private registration input.');
  }
  const base = opts.dir ? path.resolve(opts.dir) : null;
  console.log(`This creates public ${profile.toUpperCase()} servers, each with a same-named namespace and endpoint, without instance prefixes. An administrator account is required.`);
  console.log('New endpoints require a MetaMCP API key. Every MetaMCP user can use the shared servers and their configured credentials/data.');
  if (profile === 'local') console.log('WARNING: shared LOCAL servers can expose files, databases, terminals and desktop control to other users.');
  console.log('Existing records are never updated or deleted; conflicting names are not adopted.');
  console.log('The MetaMCP host must be able to reach the gateway URL; it can differ from the address reachable from this terminal.');
  // For an existing local Docker project, derive both addresses instead of
  // asking the user to copy credentials, a gateway URL, or an uncertain path.
  const savedMeta = interactiveLive ? json(path.join(path.resolve(opts.metaDir), '.mcpkit', 'state.json')) : null;
  const target = validateUrl(supplied ? supplied.target : interactiveLive ? savedMeta.appUrl : await question('MetaMCP origin (for example https://mcp.example.org): '), false);
  const gateway = validateUrl(supplied ? supplied.gateway : interactiveLive ? `http://${opts.liveGlobal}-gateway:13001` : await question('Gateway base URL as seen FROM MetaMCP: '), true);
  if (interactiveLive) console.log(`Selected MetaMCP: ${target.base}; existing GLOBAL: ${opts.liveGlobal}.`);
  if (target.insecure || gateway.insecure) {
    console.log('WARNING: non-loopback HTTP sends credentials/keys without transport encryption. Use HTTPS or a separately encrypted private tunnel/VPN.');
    if (!supplied && (await question('Type TRUSTED TUNNEL to confirm this network is protected: ')) !== 'TRUSTED TUNNEL') fail('Cancelled; no records were changed.');
  }
  const meta = opts.metaDir ? verifiedLocalMeta(opts.metaDir, target.base) : null;
  if (meta) localTransport = { origin: target.base, address: meta.address };
  const existingGlobal = interactiveLive ? inspectLiveGlobal(meta.context, opts.liveGlobal, { requireRunning: false }) : null;
  let bundle = interactiveLive ? null : opts.liveGlobal ? liveGlobalBundle(opts.liveGlobal, meta, gateway.base)
    : profile === 'local' ? loadLocalBundle(base) : globalBundle(base);
  console.log('Use only a MetaMCP instance you trust: its server records will contain the gateway key.');
  const auth = await login(target.base, supplied);
  await requireAdmin(target.base, auth.cookie);
  if (interactiveLive) {
    console.log('Starting verified existing GLOBAL containers if necessary; they will not be rebuilt or recreated.');
    const running = startLiveGlobal(existingGlobal);
    let statuses = null;
    const deadline = Date.now() + 90_000;
    while (!statuses && Date.now() < deadline) {
      try { statuses = liveGlobalStatus(running); } catch { await delay(2000); }
    }
    if (!statuses) fail('The existing GLOBAL gateway did not become ready; no MetaMCP records were created.');
    console.log(`GLOBAL gateway responded; ${statuses.filter((item) => item.status === 'ready').length}/${statuses.length} servers are ready.`);
    for (const item of statuses.filter((entry) => entry.status !== 'ready')) console.log(`  ${item.id}: ${item.status}`);
    enableLiveGlobalRestart(running);
    connectLiveGlobal(running, meta.state);
    bundle = liveGlobalBundle(opts.liveGlobal, meta, gateway.base);
  }
  const expectedOwner = null;
  const publicOwner = { user_id: null };
  const keyHash = digest(bundle.key);
  const journalId = digest(`${target.base}\n${auth.userId}\n${gateway.base}\n${profile}\n${bundle.id}`).slice(0, 32);
  const registryDir = path.join(bundle.privateDir, 'registrations');
  fs.mkdirSync(registryDir, { recursive: true, mode: 0o700 });
  const file = path.join(registryDir, `${journalId}.json`);
  const lockFile = `${file}.lock`;
  let lock;
  try { lock = fs.openSync(lockFile, 'wx', 0o600); } catch { fail(`Registration may already be running; inspect ${lockFile} before removing a stale lock.`); }
  try {
    let journal;
    if (fs.existsSync(file)) {
      journal = json(file);
      if (![1, 2, 3].includes(journal.version) || journal.origin !== target.base || journal.owner !== auth.userId || journal.gateway !== gateway.base ||
          journal.profile !== profile || journal.hostId !== bundle.id || journal.keyHash !== keyHash ||
          (journal.version === 1 && !new RegExp(`^mcpkit-${profile}-[a-f0-9]{12}$`).test(journal.prefix || '')) ||
          (journal.version === 2 && journal.naming !== 'official-v1') ||
          (journal.version === 3 && journal.naming !== 'official-per-server-v1') ||
          !journal.servers || !journal.namespaces || !journal.endpoints) {
        fail('Saved registration state differs from the selected target or key. Existing records were not changed; inspect it manually.');
      }
      if (journal.pending) fail(`A previous operation has an unknown outcome (${journal.pending.kind} ${journal.pending.name}). Inspect the MetaMCP UI and the journal before retrying; no records were changed now.`);
      if (journal.version !== 3) {
        fail('This registration uses the older grouped layout. Do not recreate it; use the explicit sharing migration described in the independent installation guide, then manage existing records in MetaMCP.');
      }
    } else {
      journal = { version: 3, naming: 'official-per-server-v1', origin: target.base, owner: auth.userId, gateway: gateway.base, profile, hostId: bundle.id, keyHash,
        servers: {}, namespaces: {}, endpoints: {}, pending: null };
      writeAtomic(file, journal);
    }
    const save = () => writeAtomic(file, journal);
    async function create(kind, name, procedure, body) {
      journal.pending = { kind, name };
      save(); // A lost response is never treated as permission to adopt by name.
      const data = await trpc(target.base, auth.cookie, procedure, body, true);
      if (!data || typeof data.uuid !== 'string' || data.name !== name || data.user_id !== expectedOwner) fail(`Unexpected ${kind} response; inspect the pending operation before retrying.`);
      return data;
    }
    const serverList = await trpc(target.base, auth.cookie, 'mcpServers.list');
    const namespaceList = await trpc(target.base, auth.cookie, 'namespaces.list');
    const endpointList = await trpc(target.base, auth.cookie, 'endpoints.list');
    if (!Array.isArray(serverList) || !Array.isArray(namespaceList) || !Array.isArray(endpointList)) fail('Unexpected MetaMCP list response.');
    const serverIds = [...new Set(Object.values(bundle.groups).flat())];
    const groups = Object.keys(bundle.groups);
    const validUuid = (value) => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
    const kinds = [
      ['server', journal.servers, serverList, serverIds, bundle.serverNames],
      ['namespace', journal.namespaces, namespaceList, groups, bundle.groupNames],
      ['endpoint', journal.endpoints, endpointList, groups, bundle.groupNames],
    ];
    // Check all visible name conflicts and all saved UUIDs before creating the
    // first record. Private endpoints belonging to other users are not listed
    // by this API, so the server can still reject a later endpoint creation.
    for (const [kind, saved, current, ids, names] of kinds) {
      if (!saved || typeof saved !== 'object' || Array.isArray(saved) || Object.keys(saved).some((id) => !ids.includes(id))) {
        fail(`Invalid saved ${kind} records; no MetaMCP records were changed.`);
      }
      const used = new Set();
      for (const id of ids) {
        const name = names[id];
        if (typeof name !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(name)) fail(`Invalid expected ${kind} name; no records were changed.`);
        const record = saved[id];
        if (Object.hasOwn(saved, id)) {
          if (!record || typeof record !== 'object' || !validUuid(record.uuid) || record.name !== name || used.has(record.uuid.toLowerCase())) {
            fail(`Invalid saved ${kind} identity; no MetaMCP records were changed.`);
          }
          used.add(record.uuid.toLowerCase());
          const existing = current.find((item) => item.uuid === record.uuid);
          if (!existing) fail(`Previously registered ${kind} ${name} is missing or inaccessible; it was not recreated.`);
          if (existing.user_id !== expectedOwner || existing.name !== name) {
            fail(`Previously registered ${kind} ${record.name} is not public or still has an old/edited name. Convert the existing registration explicitly; see the independent installation guide. No records were changed.`);
          }
          if (kind === 'endpoint' && (existing.namespace_uuid !== journal.namespaces[id]?.uuid ||
              !existing.enable_api_key_auth || existing.enable_metamcp_admin_tools)) {
            fail(`Previously registered endpoint ${name} has unexpected settings or namespace; no records were changed.`);
          }
        }
        if (current.some((item) => item.name === name && item.uuid !== record?.uuid)) {
          fail(`The ${kind} name ${name} is already in use; it was not adopted or renamed. No MetaMCP records were changed.`);
        }
      }
    }
    for (const id of serverIds) {
      const name = bundle.serverNames[id];
      const known = journal.servers[id];
      if (known) {
        const existing = serverList.find((s) => s.uuid === known.uuid);
        if (!existing) fail(`Previously created server ${name} is missing or inaccessible. It was not recreated.`);
        continue; // Edits are preserved. Hash is checked before a new mapping.
      }
      if (serverList.some((s) => s.name === name)) fail(`Server name ${name} already exists; it was not adopted or changed.`);
      const isGithub = id === 'github-mcp-server';
      const body = { name, description: `MCP Kit ${profile}: ${id}`, type: 'STREAMABLE_HTTP',
        url: isGithub ? 'https://api.githubcopilot.com/mcp/' : `${gateway.base}/servers/${id}/mcp`,
        ...(isGithub ? {} : { headers: { 'X-API-Key': bundle.key } }), ...publicOwner };
      const created = await create('server', name, 'mcpServers.create', body);
      journal.servers[id] = { uuid: created.uuid, name, hash: serverHash(created) };
      journal.pending = null;
      save();
      serverList.push(created);
      console.log(`Created server ${name}`);
    }
    for (const [group, members] of Object.entries(bundle.groups)) {
      const name = bundle.groupNames[group];
      const uuids = members.map((id) => journal.servers[id].uuid);
      let ns = journal.namespaces[group];
      if (ns) {
        if (!namespaceList.some((item) => item.uuid === ns.uuid)) fail(`Previously created namespace ${name} is missing or inaccessible; it was not recreated.`);
      } else {
        if (namespaceList.some((item) => item.name === name)) fail(`Namespace name ${name} exists; it was not adopted or changed.`);
        for (const id of members) {
          const record = journal.servers[id];
          const current = serverList.find((s) => s.uuid === record.uuid);
          if (!current || serverHash(current) !== record.hash) fail(`Server ${record.name} was changed or removed; it was not attached to a new namespace.`);
        }
        const created = await create('namespace', name, 'namespaces.create', { name, description: `MCP Kit ${profile}: ${group}`, mcpServerUuids: uuids, ...publicOwner });
        ns = journal.namespaces[group] = { uuid: created.uuid, name, servers: uuids };
        journal.pending = null;
        save();
        namespaceList.push(created);
        console.log(`Created namespace ${name}`);
      }
      const endpoint = journal.endpoints[group];
      if (endpoint) {
        if (!endpointList.some((item) => item.uuid === endpoint.uuid)) fail(`Previously created endpoint ${name} is missing or inaccessible; it was not recreated.`);
        continue;
      }
      if (endpointList.some((item) => item.name === name)) fail(`Endpoint name ${name} exists; it was not adopted or changed.`);
      const detailed = await trpc(target.base, auth.cookie, 'namespaces.get', { uuid: ns.uuid });
      const actual = (detailed?.servers || []).map((server) => server.uuid).sort();
      if (detailed?.user_id !== expectedOwner || JSON.stringify(actual) !== JSON.stringify([...ns.servers].sort())) fail(`Namespace ${name} was edited; a new endpoint was not added.`);
      if (hasOpenEndpoint(endpointList, ns.uuid)) fail(`Namespace ${name} has an unauthenticated endpoint; no new endpoint was added.`);
      const created = await create('endpoint', name, 'endpoints.create', {
        name, description: `MCP Kit ${profile}: ${group}`, namespaceUuid: ns.uuid,
        enableApiKeyAuth: true, enableOauth: false, useQueryParamAuth: false,
        enableClientMaxRate: false, enableMaxRate: false, enableMetamcpAdminTools: false, createMcpServer: false, ...publicOwner,
      });
      if (created.namespace_uuid !== ns.uuid || !created.enable_api_key_auth) fail('Endpoint result is not the expected protected endpoint; inspect the pending operation.');
      journal.endpoints[group] = { uuid: created.uuid, name };
      journal.pending = null;
      save();
      endpointList.push(created);
      console.log(`Created protected endpoint ${name}`);
    }
    console.log('\nRegistration complete. Existing records and user changes were not updated or deleted.');
    for (const group of Object.keys(bundle.groups)) console.log(`${group}: ${target.base}/metamcp/${bundle.groupNames[group]}/mcp`);
    console.log('Create a PRIVATE API key in the MetaMCP UI for this account and enter it when a client asks for one.');
    console.log('Any valid MetaMCP API key can access a shared endpoint; issue keys only to trusted clients.');
    if (profile === 'global') console.log('GitHub MCP requires its own token; set it manually in the newly created GitHub server in MetaMCP.');
    console.log(`Registration journal: ${file}. Keep it with the kit configuration; it contains no password or gateway key.`);
  } finally {
    fs.closeSync(lock);
    fs.unlinkSync(lockFile);
  }
}
try { await main(); } catch (error) { console.error(`ERROR: ${error.message}`); process.exitCode = 1; }
