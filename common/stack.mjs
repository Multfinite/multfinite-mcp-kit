#!/usr/bin/env node
// Independent MetaMCP / GLOBAL Compose projects for Linux and Windows.
// The legacy installations are deliberately not discovered or migrated.
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { GLOBAL_SERVER_NAMES, LOCAL_SERVER_NAMES, LEGACY_GLOBAL_GROUPS, LEGACY_GLOBAL_GROUP_NAMES, legacyLocalGroups, LEGACY_LOCAL_GROUP_NAMES } from './registration-manifest.mjs';
import { ensurePatchedSource, LAN_PATCH_VERSION, CLEAN_TOOLS_PATCH_VERSION, SINGLE_SERVER_ENDPOINT_PATCH_VERSION } from './metamcp-lan-source.mjs';
import { lanEnabledState, withAppUrl, validateLanIp } from './metamcp-lan-enable.mjs';
import { readLiveGlobalLink, assertLiveGlobalNetwork } from './live-global.mjs';
import { readLiveMetaPeerLinks, liveMetaPeerComposeFile, assertLiveMetaPeerNetworks, assertMetaPeerAppsRunning, linkMetaPeers, probeMetaPeerEndpoint, unlinkMetaPeers } from './live-metamcp.mjs';
import { prepareMetaPeerRegistration, commitMetaPeerRegistration } from './metamcp-peer-registration.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const revision = '05818ec2767b946f98d280ae9cefa401f0362d62';
const [action, ...argv] = process.argv.slice(2);

function fail(message) { throw new Error(message); }
function parseArgs(args) {
  const result = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const flag = { '--delete-volumes': 'deleteVolumes', '--staged': 'staged', '--fresh': 'fresh', '--allow-insecure-lan': 'allowInsecureLan', '--clean-tools': 'cleanTools' }[arg];
    if (flag) { if (result[flag]) fail(`Duplicate argument: ${arg}`); result[flag] = true; continue; }
    const key = { '--dir': 'dir', '--port': 'port', '--app-url': 'appUrl', '--lan-ip': 'lanIp', '--admin-email': 'adminEmail', '--meta-dir': 'metaDir', '--peer-dir': 'peerDir', '--endpoint': 'endpoint', '--server': 'server', '--registration': 'registration', '--registration-file': 'registrationFile', '--expect-type': 'expectType' }[arg];
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
function privateLanIp(value) {
  if (typeof value !== 'string' || net.isIP(value) !== 4) fail('LAN IP must be a literal private IPv4 address.');
  const [a, b] = value.split('.').map(Number);
  if (!(a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168))) fail('LAN IP must be in an RFC 1918 private IPv4 range.');
  return value;
}
function lanOrigins(state) {
  return [`http://${state.lanIp}:${state.port}`, `http://localhost:${state.port}`, `http://127.0.0.1:${state.port}`].join(',');
}
function trustedOriginPrefix(state, appUrl) {
  return state.lanIp ? `${lanOrigins(state)},` : `${appUrl},`;
}
function validOrigin(value, state = null) {
  let u;
  try { u = new URL(value); } catch { fail('APP_URL must be an absolute http(s) origin.'); }
  if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password || u.pathname !== '/' || u.search || u.hash) fail('APP_URL must contain only scheme, host and optional port.');
  if (state?.lanIp) {
    if (u.origin !== `http://${state.lanIp}:${state.port}`) fail('The opt-in LAN instance must keep its configured LAN IP and port as APP_URL.');
  } else if (u.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(u.hostname)) fail('Use HTTPS for a non-loopback APP_URL. Configure the reverse proxy separately.');
  return u.origin;
}
function parseEnvOrigin(raw, state = null) {
  // Do not interpret shell syntax, Compose interpolation, comments or escapes.
  // Accept a literal URL with optional matching single or double quotes.
  if (typeof raw !== 'string' || raw !== raw.trim()) fail('APP_URL in the private .env must be a literal origin without surrounding spaces.');
  let value = raw;
  if ((raw.startsWith("'") && raw.endsWith("'")) || (raw.startsWith('"') && raw.endsWith('"'))) value = raw.slice(1, -1);
  if (!value || /[\s'"\\$#`,]/.test(value)) fail('APP_URL in the private .env must be a literal origin without interpolation or comments.');
  return validOrigin(value, state);
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
function originState(base, { allowRelocated = false } = {}) {
  const f = path.join(base, '.mcpkit', 'state.json');
  if (!fs.existsSync(f)) fail(`Independent kit state not found: ${f}. Existing/legacy files were not changed.`);
  const s = JSON.parse(fs.readFileSync(f, 'utf8'));
  if (!s || typeof s !== 'object' || Array.isArray(s) || s.version !== 1 || !['meta', 'global'].includes(s.type) ||
      typeof s.id !== 'string' || !/^[a-f0-9]{16}$/.test(s.id) || s.project !== `mcpkit-${s.type}-${s.id}` ||
      typeof s.base !== 'string' || !path.isAbsolute(s.base) || path.resolve(s.base) !== s.base || validPort(s.port) !== s.port) {
    fail(`Invalid kit state in ${f}; no Docker resource was changed.`);
  }
  if (s.lanIp !== undefined && (s.type !== 'meta' || privateLanIp(s.lanIp) !== s.lanIp || s.lanPatch !== LAN_PATCH_VERSION)) {
    fail(`Invalid or unsupported LAN state in ${f}; no Docker resource was changed.`);
  }
  if (s.cleanTools !== undefined && (s.type !== 'meta' || s.cleanTools !== true || s.cleanToolsPatch !== CLEAN_TOOLS_PATCH_VERSION)) {
    fail(`Invalid or unsupported clean-tool state in ${f}; no Docker resource was changed.`);
  }
  if (s.type === 'meta' && validOrigin(s.appUrl, s) !== s.appUrl) fail(`Invalid kit origin in ${f}; no Docker resource was changed.`);
  if (!allowRelocated && s.base !== base) {
    fail(`Kit state in ${f} refers to ${s.base}, not ${base}. On Linux, use linux/relocate-kit.sh after reviewing the move; no Docker resource was changed.`);
  }
  return s;
}
function sharingState(saved, base) {
  if (saved.base !== base) {
    console.log(`Using moved ${saved.type.toUpperCase()} directory ${base} for this sharing operation (saved path: ${saved.base}).`);
    console.log('The saved path is not changed; use linux/relocate-kit.sh for subsequent lifecycle commands.');
  }
  return { ...saved, base };
}
function readEnv(base, type, { ignoreAppUrl = false } = {}) {
  const file = path.join(base, '.mcpkit', '.env');
  if (!fs.existsSync(file)) fail(`Missing private credentials: ${file}. Restore from backup; secrets are not regenerated.`);
  const values = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
    if (match) {
      if (type === 'meta' && ignoreAppUrl && match[1] === 'APP_URL') continue;
      if (Object.hasOwn(values, match[1])) fail(`Duplicate key in private env: ${match[1]}`);
      values[match[1]] = match[2];
    } else if (type === 'meta' && !ignoreAppUrl && /^\s*(?:export\s+)?APP_URL(?:\s*[:=]|\s*$)/.test(line)) {
      fail('Write APP_URL in the private .env as APP_URL=... without export or spaces around the key.');
    }
  }
  const required = type === 'meta' ? ['POSTGRES_PASSWORD', 'BETTER_AUTH_SECRET'] : ['MCPKIT_GATEWAY_KEY', 'MCPKIT_CONTROL_KEY', 'NEO4J_PASSWORD'];
  for (const key of required) {
    if (!/^[a-f0-9]{64}$/.test(values[key] || '')) {
      fail(`Invalid or missing ${key} in the private .env: expected the original 64 lowercase hexadecimal characters without quotes or spaces. Restore the exact original value from a private backup; existing credentials were not changed.`);
    }
  }
  if (type === 'global' && values.MCPKIT_GATEWAY_KEY === values.MCPKIT_CONTROL_KEY) fail('Gateway and control credentials must differ.');
  if (type === 'meta' && !ignoreAppUrl && Object.hasOwn(values, 'APP_URL')) {
    parseEnvOrigin(values.APP_URL, originState(base, { allowRelocated: true }));
  }
  return values;
}
function configuredMetaOrigin(state) {
  const values = readEnv(state.base, 'meta');
  // Old installations did not have APP_URL in .env. Preserve their initial
  // origin unless the user explicitly adds the new configuration entry.
  return Object.hasOwn(values, 'APP_URL') ? parseEnvOrigin(values.APP_URL, state) : state.appUrl;
}
function validAdminEmail(value) {
  if (typeof value !== 'string' || value.length > 254 || !/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(value)) fail('Enter one plain administrator email address.');
  return value.toLowerCase();
}
function initialize(type, opts) {
  const base = path.resolve(opts.dir || '');
  if (!opts.dir) fail('Pass --dir for the new independent installation.');
  if (opts.lanIp) {
    if (type !== 'meta' || process.platform !== 'linux' || !opts.allowInsecureLan) fail('The Linux LAN mode requires --allow-insecure-lan. HTTP exposes credentials on the network.');
    privateLanIp(opts.lanIp);
    const local = Object.values(os.networkInterfaces()).flat().some((item) => item && item.family === 'IPv4' && item.address === opts.lanIp);
    if (!local) fail(`LAN address ${opts.lanIp} is not assigned to this host.`);
  } else if (opts.allowInsecureLan) fail('--allow-insecure-lan requires --lan-ip.');
  if (opts.staged && (type !== 'meta' || !opts.adminEmail)) fail('A staged MetaMCP installation requires --admin-email.');
  const adminEmail = opts.staged ? validAdminEmail(opts.adminEmail) : '';
  if (fs.existsSync(base) && fs.lstatSync(base).isSymbolicLink()) fail('The installation directory must not itself be a symlink.');
  fs.mkdirSync(base, { recursive: true, mode: 0o700 });
  const existing = fs.readdirSync(base);
  if (existing.includes('.mcpkit') && fs.existsSync(path.join(base, '.mcpkit', 'state.json'))) {
    const state = originState(base);
    if (state.type !== type) fail('This directory belongs to a different kind of installation.');
    if (opts.fresh) fail(`A fresh install refuses an existing instance: ${base}`);
    if (opts.cleanTools && !state.cleanTools) fail('Clean tool names cannot be enabled on an existing instance through init; its image and data were not changed.');
    if (opts.staged && (!setupMarker(state) || validPort(opts.port) !== state.port || (opts.lanIp || '') !== (state.lanIp || '') || Boolean(opts.cleanTools) !== Boolean(state.cleanTools) || setupMarker(state).adminEmail !== adminEmail || (opts.appUrl && parseEnvOrigin(opts.appUrl, state) !== state.appUrl))) {
      fail('The existing setup does not match the requested staged instance; it was preserved.');
    }
    readEnv(base, type);
    console.log(`Existing ${type} installation preserved; port ${state.port} remains unchanged.`);
    return state;
  }
  if (existing.length) fail(`Directory is not empty and has no matching kit state; nothing was overwritten: ${base}`);
  const port = validPort(opts.port); // An explicit port is mandatory for every new instance.
  const policy = opts.lanIp ? { lanIp: opts.lanIp, port } : null;
  const appUrl = type === 'meta' ? parseEnvOrigin(opts.appUrl || (opts.lanIp ? `http://${opts.lanIp}:${port}` : `http://localhost:${port}`), policy) : '';
  const id = crypto.randomBytes(8).toString('hex');
  const state = { version: 1, type, id, project: `mcpkit-${type}-${id}`, base, port, ...(type === 'meta' ? { appUrl, revision } : {}),
    ...(opts.lanIp ? { lanIp: opts.lanIp, lanPatch: LAN_PATCH_VERSION } : {}),
    ...(opts.cleanTools ? { cleanTools: true, cleanToolsPatch: CLEAN_TOOLS_PATCH_VERSION } : {}) };
  const priv = path.join(base, '.mcpkit');
  fs.mkdirSync(priv, { mode: 0o700 });
  const env = type === 'meta'
    ? `POSTGRES_PASSWORD=${random()}\nBETTER_AUTH_SECRET=${random()}\n# Public origin; edit this and run apply to change an existing container.\nAPP_URL='${appUrl}'\n# For a staged fresh install, the administrator is created before publication.\nMETAMCP_ADMIN_EMAILS=${adminEmail}\n# APP_URL is always trusted; add only other origins you explicitly trust.\n# MCP endpoints allow exactly one linked server by default.\n# Set MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT=false to opt out.\nMCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT=true\nEXTRA_TRUSTED_ORIGINS=\n`
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
  if (opts.staged) privateWrite(path.join(priv, 'first-setup.json'), `${JSON.stringify({ version: 1, project: state.project, adminEmail }, null, 2)}\n`);
  privateWrite(path.join(priv, 'state.json'), `${JSON.stringify(state, null, 2)}\n`);
  console.log(`Created ${type} state at ${base}. Docker project: ${state.project}.`);
  return state;
}
function setupMarker(state) {
  if (state.type !== 'meta') return null;
  const file = path.join(state.base, '.mcpkit', 'first-setup.json');
  if (!fs.existsSync(file)) return null;
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) fail('Invalid first-setup marker; no container was changed.');
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail('Invalid first-setup marker; no container was changed.'); }
  if (value.version !== 1 || value.project !== state.project || validAdminEmail(value.adminEmail) !== value.adminEmail) fail('Invalid first-setup marker; no container was changed.');
  return value;
}
function publicationMarker(state) {
  const file = path.join(state.base, '.mcpkit', 'publication-ready.json');
  if (!fs.existsSync(file)) return null;
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) fail('Invalid publication marker; inspect the installation.');
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail('Invalid publication marker; inspect the installation.'); }
  const setup = setupMarker(state);
  if (!setup || value.version !== 1 || value.project !== state.project || value.adminEmail !== setup.adminEmail) fail('Publication marker does not match this staged instance.');
  return value;
}
function config(state, { metaOriginOverride } = {}) {
  const priv = path.join(state.base, '.mcpkit');
  const common = {
    MCPKIT_INSTANCE: state.id,
    MCPKIT_PROJECT: state.project,
    MCPKIT_PORT: String(state.port),
    MCPKIT_IMAGE: `${state.project}-${state.type === 'meta' ? 'metamcp' : 'gateway'}:1`,
  };
  if (state.type === 'meta') {
    Object.assign(common, { MCPKIT_SOURCE: path.join(state.base, 'metamcp'), MCPKIT_APP_URL: metaOriginOverride ?? configuredMetaOrigin(state) });
    if (state.lanIp) Object.assign(common, { MCPKIT_LAN_IP: state.lanIp, MCPKIT_LAN_ORIGINS: lanOrigins(state) });
    const link = readLiveGlobalLink(state);
    if (link) common.MCPKIT_GLOBAL_CLIENT_NETWORK = link.network;
  } else {
    Object.assign(common, { MCPKIT_BUILD_DIR: path.join(priv, 'build'), MCPKIT_NODE_BUILD_DIR: path.join(priv, 'node-build'), MCPKIT_NODE_IMAGE: `${state.project}-node:1` });
  }
  return common;
}
function composeArgs(ctx, state, command, { staging = Boolean(setupMarker(state)) } = {}) {
  const args = ['--context', ctx, 'compose', '--project-name', state.project, '--project-directory', state.base,
    '--env-file', path.join(state.base, '.mcpkit', '.env'), '-f', path.join(root, 'common', state.type === 'meta' ? 'metamcp-compose.yml' : 'global-compose.yml')];
  if (state.type === 'meta' && process.platform === 'linux') args.push('-f', path.join(root, 'common', 'metamcp-linux.yml'));
  if (state.type === 'meta' && state.lanIp) args.push('-f', path.join(root, 'common', 'metamcp-lan.yml'));
  if (state.type === 'meta' && state.cleanTools) args.push('-f', path.join(root, 'common', 'metamcp-clean-tools.yml'));
  if (state.type === 'meta' && readLiveGlobalLink(state)) args.push('-f', path.join(root, 'common', 'metamcp-live-global.yml'));
  if (state.type === 'meta') {
    const peerOverlay = liveMetaPeerComposeFile(state);
    if (peerOverlay) args.push('-f', peerOverlay);
  }
  if (state.type === 'meta' && staging) args.push('-f', path.join(root, 'common', 'metamcp-staging.yml'));
  return [...args, ...command];
}
function compose(ctx, state, args, capture = false, overrides = {}) {
  if (state.type === 'meta') {
    if (readLiveGlobalLink(state)) assertLiveGlobalNetwork(ctx, state);
    assertLiveMetaPeerNetworks(ctx, state);
  }
  return run('docker', composeArgs(ctx, state, args, overrides), { capture, env: cleanEnv(config(state)) });
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
  ensurePatchedSource(source, { lan: Boolean(state.lanIp), cleanTools: Boolean(state.cleanTools) });
  return source;
}
function ensureImages(ctx, state) {
  const images = state.type === 'meta' ? [[config(state).MCPKIT_IMAGE, 'app']] : [[config(state).MCPKIT_IMAGE, 'gateway'], [config(state).MCPKIT_NODE_IMAGE, 'memory']];
  for (const [image, service] of images) {
    const labels = inspect(ctx, 'image', image);
    checkLabel(labels, state, 'image', image);
    if (labels) {
      if (state.type === 'meta' && labels['com.multfinite.mcpkit.single-server-per-endpoint-patch'] !== SINGLE_SERVER_ENDPOINT_PATCH_VERSION) {
        fail('The existing MetaMCP image predates the default one-server-per-endpoint policy. Its owned source is patched, but the image and containers were not changed; rebuild the app image, then recreate only app before retrying.');
      }
      if (state.lanIp && labels['com.multfinite.mcpkit.lan-patch'] !== LAN_PATCH_VERSION) fail('The existing LAN image does not have the expected source patch; no image was replaced.');
      if (state.cleanTools && labels['com.multfinite.mcpkit.clean-tools-patch'] !== CLEAN_TOOLS_PATCH_VERSION) fail('The existing image does not have the expected clean-tool patch; no image was replaced.');
      continue;
    }
    if (state.type === 'meta') {
      ensurePatchedSource(path.join(state.base, 'metamcp'), { lan: Boolean(state.lanIp), cleanTools: Boolean(state.cleanTools) });
    }
    console.log(`Building the isolated ${service} image; this can take a while.`);
    compose(ctx, state, ['build', service]);
    const built = inspect(ctx, 'image', image);
    if (!built) fail(`Built image is missing: ${image}`);
    checkLabel(built, state, 'image', image);
    if (state.type === 'meta' && built['com.multfinite.mcpkit.single-server-per-endpoint-patch'] !== SINGLE_SERVER_ENDPOINT_PATCH_VERSION) {
      fail('Built MetaMCP image lacks the default one-server-per-endpoint patch label.');
    }
    if (state.lanIp && built['com.multfinite.mcpkit.lan-patch'] !== LAN_PATCH_VERSION) fail('Built LAN image lacks its expected patch label.');
    if (state.cleanTools && built['com.multfinite.mcpkit.clean-tools-patch'] !== CLEAN_TOOLS_PATCH_VERSION) fail('Built image lacks its expected clean-tool patch label.');
  }
}
async function waitMetaHealth(state) {
  const target = `http://127.0.0.1:${state.port}/health`;
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(target, { signal: AbortSignal.timeout(Math.min(2000, Math.max(1, deadline - Date.now()))), redirect: 'error' });
      if (r.ok) return;
      await r.body?.cancel();
    } catch { /* still starting */ }
    const remaining = deadline - Date.now();
    if (remaining > 0) await delay(Math.min(1000, remaining));
  }
  fail('MetaMCP did not pass the local health check within 120 seconds. Inspect status and logs locally before retrying.');
}
async function waitStagedMetaHealth(ctx, state) {
  const id = ownedMetaService(ctx, state, 'app');
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const result = run('docker', ['--context', ctx, 'exec', id, 'curl', '-fsS', '--max-time', '2', 'http://127.0.0.1:12008/health'], { capture: true, allowFailure: true });
    if (result.status === 0) { requireRunningMetaApp(ctx, state, id, { staged: true }); return; }
    await delay(1000);
  }
  fail('Staged MetaMCP did not become healthy. It has not been intentionally published; inspect its status before retrying.');
}
async function start(ctx, state) {
  const staged = Boolean(setupMarker(state));
  readEnv(state.base, state.type);
  checkResources(ctx, state);
  if (state.type === 'meta') ensureSource(state);
  ensureImages(ctx, state);
  checkResources(ctx, state);
  // Staging resets all host port bindings before the app is started.
  compose(ctx, state, staged ? ['up', '-d', '--no-recreate', '--no-build', 'postgres', 'app'] : ['up', '-d', '--no-recreate', '--no-build']);
  if (state.type === 'meta') {
    if (staged) {
      await waitStagedMetaHealth(ctx, state);
      console.log('MetaMCP is staged without a host port. Create the administrator and close registration before activation.');
      return;
    }
    await waitMetaHealth(state);
    const id = requireRunningMetaApp(ctx, state);
    const currentOrigin = containerEnvironment(ctx, id).APP_URL;
    if (typeof currentOrigin !== 'string' || validOrigin(currentOrigin, state) !== currentOrigin) fail('The running app has an unexpected APP_URL; review its configuration.');
    console.log(`MetaMCP passed its local health check on port ${state.port}. Current app origin: ${currentOrigin}`);
    if (currentOrigin !== configuredMetaOrigin(state)) console.warn('APP_URL in the private .env differs from the running container; use apply after reviewing its warnings.');
    if (state.lanIp) console.log(`LAN HTTP is enabled on ${state.lanIp}:${state.port}; passwords and keys are not encrypted on that network.`);
    else if (currentOrigin !== `http://localhost:${state.port}`) console.log('For an external origin, configure its HTTPS reverse proxy before signing in.');
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
function ownedMetaService(ctx, state, service) {
  const result = run('docker', ['--context', ctx, 'container', 'ls', '-aq', '--no-trunc',
    '--filter', `label=com.docker.compose.project=${state.project}`], { capture: true });
  const ids = result.stdout.trim().split(/\s+/).filter(Boolean);
  const found = [];
  for (const id of ids) {
    if (!/^[a-f0-9]{12,64}$/.test(id)) fail('Unexpected Docker container ID; inspect the project state.');
    const labels = inspect(ctx, 'container', id);
    if (!labels) fail('A container disappeared during inspection; inspect the project state.');
    checkLabel(labels, state, 'container', id);
    if (labels['com.docker.compose.service'] === service &&
        String(labels['com.docker.compose.oneoff'] || '').toLowerCase() !== 'true') found.push(id);
  }
  if (found.length !== 1) fail(`Expected exactly one owned ${service} container; inspect the project state.`);
  return found[0];
}
function stoppedMetaService(ctx, state, service) {
  const id = ownedMetaService(ctx, state, service);
  const running = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.State.Running}}', id], { capture: true }).stdout.trim();
  if (running !== 'false') fail(`Stop the selected MetaMCP ${service} container before recovery; no file was changed.`);
  return id;
}
function dockerEnvironment(text, description) {
  let entries;
  try { entries = JSON.parse(text.trim()); } catch { fail(`Could not read ${description} configuration.`); }
  if (entries === null && description === 'image') entries = [];
  if (!Array.isArray(entries)) fail(`Unexpected ${description} configuration.`);
  const values = Object.create(null);
  for (const entry of entries) {
    if (typeof entry !== 'string' || !entry.includes('=')) fail(`Unexpected ${description} environment.`);
    const index = entry.indexOf('=');
    const key = entry.slice(0, index);
    if (!key || Object.hasOwn(values, key)) fail(`Ambiguous ${description} environment.`);
    values[key] = entry.slice(index + 1);
  }
  return values;
}
function containerEnvironment(ctx, id) {
  const result = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .Config.Env}}', id], { capture: true });
  return dockerEnvironment(result.stdout, 'container');
}
function requireRunningMetaApp(ctx, state, expectedId = null, { staged = false } = {}) {
  // The host health endpoint alone could be served by a different process.
  const id = ownedMetaService(ctx, state, 'app');
  if (expectedId && id !== expectedId) fail('The MetaMCP app container changed during the health check; inspect the project state.');
  const running = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.State.Running}}', id], { capture: true }).stdout.trim();
  const result = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .NetworkSettings.Ports}}', id], { capture: true });
  let ports;
  try { ports = JSON.parse(result.stdout); } catch { fail('Cannot inspect active app port bindings.'); }
  const published = ports && typeof ports === 'object' && !Array.isArray(ports) ? ports['12008/tcp'] : null;
  if (staged) {
    if (running !== 'true' || !ports || Object.values(ports).some((binding) => binding !== null && (!Array.isArray(binding) || binding.length))) {
      fail('The staged MetaMCP unexpectedly has a published port; inspect it before continuing.');
    }
  } else {
    const hosts = state.lanIp ? ['127.0.0.1', state.lanIp] : ['127.0.0.1'];
    if (running !== 'true' || !Array.isArray(published) || published.length !== hosts.length ||
        published.some((item) => item?.HostPort !== String(state.port) || !hosts.includes(item.HostIp)) ||
        hosts.some((host) => published.filter((item) => item?.HostIp === host).length !== 1) ||
        Object.entries(ports).some(([port, binding]) => port !== '12008/tcp' && binding !== null && (!Array.isArray(binding) || binding.length))) {
      fail('The owned MetaMCP app is not running on exactly its expected host bindings; inspect the project state.');
    }
  }
  const link = assertLiveGlobalNetwork(ctx, state);
  if (link) {
    const result = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .NetworkSettings.Networks}}', id], { capture: true });
    let networks;
    try { networks = JSON.parse(result.stdout); } catch { fail('Cannot inspect the MetaMCP-to-GLOBAL connection.'); }
    if (networks?.[link.network]?.NetworkID !== link.networkId) fail('The owned MetaMCP app is not attached to its saved GLOBAL client network.');
  }
  assertLiveMetaPeerNetworks(ctx, state);
  return id;
}
function metaContainerSnapshot(ctx, state, { stopped = false, allowLegacyPolicy = false } = {}) {
  const service = stopped ? stoppedMetaService : ownedMetaService;
  const appId = service(ctx, state, 'app');
  const postgresId = service(ctx, state, 'postgres');
  const imageId = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.Image}}', appId], { capture: true }).stdout.trim();
  if (!/^sha256:[a-f0-9]{64}$/.test(imageId)) fail('Cannot identify the running MetaMCP image; no file was changed.');
  const imageLabels = inspect(ctx, 'image', imageId);
  if (!imageLabels) fail('The running MetaMCP image is missing; no file was changed.');
  checkLabel(imageLabels, state, 'image', imageId);
  if (!allowLegacyPolicy && imageLabels['com.multfinite.mcpkit.single-server-per-endpoint-patch'] !== SINGLE_SERVER_ENDPOINT_PATCH_VERSION) {
    fail('The running MetaMCP image predates the one-server-per-endpoint policy. Rebuild and recreate only app before using this instance.');
  }
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
  const appUrl = app.APP_URL;
  let usableAppUrl = false;
  try { usableAppUrl = parseEnvOrigin(appUrl, state) === appUrl; } catch { /* reject an unexpected container URL below */ }
  const trustedPrefix = usableAppUrl ? trustedOriginPrefix(state, appUrl) : '';
  const singleServerPolicy = ['true', 'false'].includes(app.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT)
    ? app.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT
    : allowLegacyPolicy ? 'true' : null;
  if (!usableAppUrl || app.NEXT_PUBLIC_APP_URL !== appUrl ||
      !['true', 'false'].includes(singleServerPolicy) ||
      typeof app.METAMCP_ADMIN_EMAILS !== 'string' || typeof app.EXTRA_TRUSTED_ORIGINS !== 'string' ||
      !app.EXTRA_TRUSTED_ORIGINS.startsWith(trustedPrefix) ||
      (state.lanIp && (app.MCPKIT_MULTI_AUTH_ORIGINS !== lanOrigins(state) || app.MCPKIT_COOKIE_PREFIX !== `mcpkit-${state.id}` || app.NEXT_PUBLIC_MCPKIT_MULTI_ORIGIN !== 'true')) ||
      (state.cleanTools && app.MCPKIT_CLEAN_TOOL_NAMES !== 'true')) {
    fail('Container MetaMCP URL or admin settings are unexpected; inspect the project state.');
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
  return { appId, postgresId, password, secret, appUrl, admins: app.METAMCP_ADMIN_EMAILS,
    extraOrigins: app.EXTRA_TRUSTED_ORIGINS.slice(trustedPrefix.length),
    singleServerPolicy };
}
function hiddenInput(prompt) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) fail('An interactive terminal is required for a hidden password.');
  return new Promise((resolve, reject) => {
    let value = '';
    let settled = false;
    const previouslyRaw = Boolean(process.stdin.isRaw);
    process.stdout.write(prompt);
    const finish = (error) => {
      if (settled) return;
      settled = true;
      process.stdin.off('data', onData);
      process.stdin.setRawMode(previouslyRaw);
      process.stdin.pause();
      process.stdout.write('\n');
      if (error) reject(error); else resolve(value);
    };
    const onData = (chunk) => {
      for (const char of String(chunk)) {
        if (char === '\u0003' || char === '\u0004') return finish(new Error('Cancelled.'));
        if (char === '\r' || char === '\n') return finish();
        if (char === '\u007f' || char === '\b') value = Array.from(value).slice(0, -1).join('');
        else if (char >= ' ') value += char;
        if (value.length > 128) return finish(new Error('Password must be at most 128 characters.'));
      }
    };
    process.stdin.setEncoding('utf8');
    process.stdin.setRawMode(true);
    process.stdin.on('data', onData);
    process.stdin.resume();
  });
}
async function provisionStagedMeta(ctx, state) {
  const marker = setupMarker(state);
  if (!marker) fail('Provisioning is only available for an unpublished staged MetaMCP.');
  const id = requireRunningMetaApp(ctx, state, null, { staged: true });
  const snapshot = metaContainerSnapshot(ctx, state);
  if (snapshot.appId !== id || snapshot.admins !== marker.adminEmail || snapshot.appUrl !== configuredMetaOrigin(state)) {
    fail('Staged container or administrator settings changed; no account was created.');
  }
  let input;
  if (process.stdin.isTTY) {
    console.log(`Setting up administrator ${marker.adminEmail}. Password input is hidden.`);
    const password = await hiddenInput('Password (8–128 characters): ');
    if (password !== await hiddenInput('Repeat password: ')) fail('Passwords do not match.');
    input = { email: marker.adminEmail, password };
  } else {
    try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { fail('Expected private provisioning input on stdin.'); }
  }
  if (!input || typeof input !== 'object' || input.email !== marker.adminEmail || typeof input.password !== 'string' || input.password.length < 8 || input.password.length > 128) fail('Invalid provisioning credentials.');
  const script = fs.readFileSync(path.join(root, 'common', 'metamcp-provision.mjs'), 'utf8');
  const result = spawnSync('docker', ['--context', ctx, 'exec', '-i', id, 'node', '--input-type=module', '-e', script], {
    env: cleanEnv(), input: JSON.stringify({ origin: snapshot.appUrl, email: input.email, password: input.password }),
    encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 120000, maxBuffer: 1024 * 1024, windowsHide: true,
  });
  if (result.error || result.status !== 0) fail(`Administrator provisioning did not finish: ${(result.stderr || '').trim().slice(-500) || 'inspect the staged instance'}`);
  let provisioned;
  try { provisioned = JSON.parse(result.stdout); } catch { fail('Administrator provisioning returned an invalid result.'); }
  if (typeof provisioned.userId !== 'string' || !provisioned.userId || !/^sk_mt_[A-Za-z0-9]{64}$/.test(provisioned.apiKey || '')) fail('Administrator provisioning did not return a valid private client key.');
  const file = path.join(state.base, '.mcpkit', 'client-api-key');
  if (fs.existsSync(file)) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || fs.readFileSync(file, 'utf8').trim() !== provisioned.apiKey) fail('An existing client key file differs; it was not overwritten.');
  } else privateWrite(file, `${provisioned.apiKey}\n`);
  console.log(`Administrator created and UI/SSO signup closed. Private client API key: ${file}`);
}
async function activateStagedMeta(ctx, state) {
  const marker = setupMarker(state);
  if (!marker) fail('This MetaMCP is not in first-setup mode.');
  const appId = ownedMetaService(ctx, state, 'app');
  const portsText = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .NetworkSettings.Ports}}', appId], { capture: true }).stdout;
  let ports;
  try { ports = JSON.parse(portsText); } catch { fail('Cannot inspect staged app bindings.'); }
  if (!ports || typeof ports !== 'object' || Array.isArray(ports)) fail('Unexpected staged app bindings.');
  const alreadyPublished = Object.values(ports).some((binding) => binding !== null && (!Array.isArray(binding) || binding.length));
  if (alreadyPublished && !publicationMarker(state)) fail('An app was published before the ready marker; inspect it manually.');
  const id = requireRunningMetaApp(ctx, state, appId, { staged: !alreadyPublished });
  const snapshot = metaContainerSnapshot(ctx, state);
  if (snapshot.appId !== id || snapshot.admins !== marker.adminEmail || snapshot.appUrl !== configuredMetaOrigin(state)) fail('Staged settings changed; no container was published.');
  const keyFile = path.join(state.base, '.mcpkit', 'client-api-key');
  if (!fs.existsSync(keyFile) || !fs.lstatSync(keyFile).isFile() || fs.lstatSync(keyFile).isSymbolicLink()) {
    fail('The private client API key is missing; complete provisioning before publication.');
  }
  const key = fs.readFileSync(keyFile, 'utf8').trim();
  if (!/^sk_mt_[A-Za-z0-9]{64}$/.test(key)) fail('The private client API key is invalid; nothing was published.');
  // The key has a restricted alphabet and is sent over stdin to the owned
  // database container; it never appears in process arguments or output.
  const sql = `SELECT json_build_object('emails', (SELECT coalesce(json_agg(lower(email)), '[]'::json) FROM users), 'accounts', (SELECT count(*) FROM accounts JOIN users ON users.id = accounts.user_id WHERE provider_id = 'credential' AND account_id = users.id AND password IS NOT NULL), 'keys', (SELECT count(*) FROM api_keys JOIN users ON users.id = api_keys.user_id WHERE api_keys.name = 'mcpkit-client' AND api_keys.key = '${key}' AND api_keys.is_active), 'ui', (SELECT value FROM config WHERE id = 'DISABLE_SIGNUP'), 'sso', (SELECT value FROM config WHERE id = 'DISABLE_SSO_SIGNUP'))::text;`;
  const cmd = 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"';
  const query = spawnSync('docker', ['--context', ctx, 'exec', '-i', snapshot.postgresId, 'sh', '-c', cmd], {
    env: cleanEnv(), input: sql, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 30000, maxBuffer: 1024 * 1024, windowsHide: true,
  });
  let checked;
  try { if (query.error || query.status !== 0) throw new Error(); checked = JSON.parse(query.stdout.trim()); } catch { fail('Cannot verify staged account and registration settings; nothing was published.'); }
  if (!Array.isArray(checked.emails) || checked.emails.length !== 1 || checked.emails[0] !== marker.adminEmail || Number(checked.accounts) !== 1 || Number(checked.keys) !== 1 || checked.ui !== 'true' || checked.sso !== 'true') {
    fail('Staged account or registration settings are not safe for publication; nothing was published.');
  }
  const again = metaContainerSnapshot(ctx, state);
  for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) if (again[key] !== snapshot[key]) fail('Staged container settings changed; nothing was published.');
  requireRunningMetaApp(ctx, state, id, { staged: !alreadyPublished });
  const readyFile = path.join(state.base, '.mcpkit', 'publication-ready.json');
  if (!publicationMarker(state)) privateWrite(readyFile, `${JSON.stringify({ version: 1, project: state.project, adminEmail: marker.adminEmail }, null, 2)}\n`);
  if (!alreadyPublished) {
    try { compose(ctx, state, ['up', '-d', '--no-deps', '--force-recreate', '--no-build', 'app'], false, { staging: false }); }
    catch (error) { console.error('Publication may have started. Account and closed registration were checked, but inspect status before retrying.'); throw error; }
  }
  try {
    await waitMetaHealth(state);
    requireRunningMetaApp(ctx, state);
    const after = metaContainerSnapshot(ctx, state);
    if (after.postgresId !== snapshot.postgresId || after.password !== snapshot.password || after.secret !== snapshot.secret ||
        after.appUrl !== snapshot.appUrl || after.admins !== snapshot.admins || after.singleServerPolicy !== snapshot.singleServerPolicy) {
      fail('Published app configuration is unexpected.');
    }
    fs.unlinkSync(path.join(state.base, '.mcpkit', 'first-setup.json'));
    fs.unlinkSync(readyFile);
  } catch (error) { console.error('Publication may have completed; inspect the instance before retrying.'); throw error; }
  console.log(`MetaMCP activated: ${state.appUrl}. Registration remains closed.`);
}
function checkMetaEnv(ctx, state) {
  if (state.type !== 'meta') fail('check-env is only available for an independent MetaMCP.');
  const envFile = path.join(state.base, '.mcpkit', '.env');
  const stateFile = path.join(state.base, '.mcpkit', 'state.json');
  const original = privateRegularFile(envFile);
  const originalState = privateRegularFile(stateFile);
  if (!original || !originalState) fail('The kit state or private .env is missing; no files or containers were changed.');
  let savedState;
  try { savedState = JSON.parse(originalState.toString('utf8')); } catch { fail('Cannot read the kit state; no files or containers were changed.'); }
  if (JSON.stringify(savedState) !== JSON.stringify(state)) fail('The kit state changed during inspection; no files or containers were changed.');
  // Check credentials even when the proposed APP_URL is absent or invalid.
  const values = readEnv(state.base, 'meta', { ignoreAppUrl: true });
  const snapshot = metaContainerSnapshot(ctx, state);
  const rendered = renderedMetaConfig(ctx, state, state.appUrl);
  const app = renderedRuntimeEnvironment(rendered, 'app');
  const postgres = renderedRuntimeEnvironment(rendered, 'postgres');
  const singleServerPolicy = values.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT ?? 'true';
  if (!['true', 'false'].includes(singleServerPolicy) || snapshot.singleServerPolicy !== singleServerPolicy ||
      app?.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT !== singleServerPolicy ||
      snapshot.password !== values.POSTGRES_PASSWORD || snapshot.secret !== values.BETTER_AUTH_SECRET ||
      app?.POSTGRES_PASSWORD !== snapshot.password || postgres?.POSTGRES_PASSWORD !== snapshot.password ||
      app?.BETTER_AUTH_SECRET !== snapshot.secret) {
    fail('The private .env, rendered Compose credentials, or existing container configurations differ. No files or containers were changed. Review them locally without generating new secrets.');
  }
  const current = metaContainerSnapshot(ctx, state);
  for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
    if (current[key] !== snapshot[key]) fail('Container configuration changed during inspection; no files or containers were changed by this command.');
  }
  const checked = privateRegularFile(envFile);
  const checkedState = privateRegularFile(stateFile);
  if (!checked || !checked.equals(original) || !checkedState || !checkedState.equals(originalState)) {
    fail('The kit state or private .env changed during inspection; no files or containers were changed by this command.');
  }
  console.log('The private .env, rendered Compose credentials, and one-server-per-endpoint policy match the existing containers. No files or containers were changed.');
  console.log('This does not prove the current database password, the historical auth secret, database integrity, or application readiness.');
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
  if (!item.isFile() || item.isSymbolicLink() || item.size > 1024 * 1024) fail('A private configuration file is not a regular file or is too large; it was not changed.');
  return fs.readFileSync(file);
}
function relocationContainerIds(ctx, state, values) {
  checkResources(ctx, state);
  if (state.type === 'meta') {
    if (state.revision !== revision) fail('The MetaMCP revision is unexpected; no file was changed.');
    const snapshot = metaContainerSnapshot(ctx, state);
    if (snapshot.password !== values.POSTGRES_PASSWORD || snapshot.secret !== values.BETTER_AUTH_SECRET) {
      fail('MetaMCP container credentials differ from the private configuration; no file was changed.');
    }
    return [snapshot.appId, snapshot.postgresId];
  }
  const id = ownedMetaService(ctx, state, 'gateway');
  const env = containerEnvironment(ctx, id);
  if (env.MCPKIT_INSTANCE_ID !== state.id || env.MCPKIT_GATEWAY_KEY !== values.MCPKIT_GATEWAY_KEY ||
      env.MCPKIT_CONTROL_KEY !== values.MCPKIT_CONTROL_KEY || env.NEO4J_PASSWORD !== values.NEO4J_PASSWORD) {
    fail('GLOBAL gateway credentials differ from the private configuration; no file was changed.');
  }
  const result = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .Mounts}}', id], { capture: true });
  let mounts;
  try { mounts = JSON.parse(result.stdout); } catch { fail('Cannot inspect the GLOBAL gateway mount; no file was changed.'); }
  const mounted = Array.isArray(mounts) ? mounts.filter((item) => item?.Destination === '/data') : [];
  const volume = `${state.project}_gateway_data`;
  if (mounted.length !== 1 || mounted[0].Type !== 'volume' || mounted[0].Name !== volume) {
    fail('Unexpected GLOBAL gateway data mount; no file was changed.');
  }
  const labels = inspect(ctx, 'volume', volume);
  if (!labels) fail('The GLOBAL gateway data volume is missing; no file was changed.');
  checkLabel(labels, state, 'volume', volume);
  if (labels['com.docker.compose.volume'] !== 'gateway_data') fail('Unexpected GLOBAL gateway volume identity; no file was changed.');
  return [id];
}
async function relocateKit(ctx, saved, base) {
  if (process.platform !== 'linux') fail('relocate is only available on Linux.');
  if (saved.base === base) { console.log(`The ${saved.type} directory is already registered at ${base}; nothing was changed.`); return; }
  const dir = fs.lstatSync(base);
  const priv = path.join(base, '.mcpkit');
  if (!dir.isDirectory() || dir.isSymbolicLink()) fail('The new installation directory must be a real directory, not a link.');
  requirePrivateDirectory(priv);
  const stateFile = path.join(priv, 'state.json');
  const envFile = path.join(priv, '.env');
  const stateBytes = privateRegularFile(stateFile);
  const envBytes = privateRegularFile(envFile);
  if (!stateBytes || !envBytes || JSON.stringify(JSON.parse(stateBytes)) !== JSON.stringify(saved)) {
    fail('The state or private configuration is missing or changed; no file was changed.');
  }
  const ensureOldPath = () => {
    let previous;
    try { previous = fs.statSync(saved.base); }
    catch (error) { if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return; throw error; }
    const current = fs.statSync(base);
    if (previous.dev !== current.dev || previous.ino !== current.ino) {
      fail('The previous directory still exists as a different location. Inspect both copies before relocating; no file was changed.');
    }
  };
  const state = { ...saved, base };
  const values = readEnv(base, saved.type);
  ensureOldPath();
  const ids = relocationContainerIds(ctx, state, values);
  const unchanged = () => {
    requirePrivateDirectory(priv);
    const currentState = privateRegularFile(stateFile);
    const currentEnv = privateRegularFile(envFile);
    if (!currentState || !currentState.equals(stateBytes) || !currentEnv || !currentEnv.equals(envBytes)) {
      fail('The state or private configuration changed; no relocation was applied.');
    }
    ensureOldPath();
    const currentIds = relocationContainerIds(ctx, state, values);
    if (JSON.stringify(currentIds) !== JSON.stringify(ids)) fail('The kit containers changed; no relocation was applied.');
  };
  const message = `Update the saved directory of ${saved.project}?\nFrom: ${saved.base}\nTo:   ${base}\n` +
    'Only state.json will be updated after a private backup. Containers, volumes, databases and secrets are not changed.\n' +
    'Do not start, stop, apply, or relocate this project concurrently. A later Compose start/apply may recreate containers; preserve their writable layers first.';
  if (!(await confirm(message, `MOVE ${saved.type.toUpperCase()}`))) { console.log('Cancelled; no file was changed.'); process.exitCode = 1; return; }
  unchanged();
  const backup = path.join(priv, `state.before-move-${crypto.randomBytes(8).toString('hex')}.backup`);
  privateWrite(backup, stateBytes);
  const temp = path.join(priv, `state.move-${crypto.randomBytes(8).toString('hex')}.tmp`);
  let tempCreated = false;
  try {
    privateWrite(temp, `${JSON.stringify(state, null, 2)}\n`);
    tempCreated = true;
    unchanged();
    fs.renameSync(temp, stateFile);
    tempCreated = false;
  } finally { if (tempCreated) { try { fs.unlinkSync(temp); } catch { /* left for inspection */ } } }
  console.log(`Updated ${saved.project} directory to ${base}. Previous state: ${backup}. No Docker resource was changed.`);
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
  const snapshot = metaContainerSnapshot(ctx, state, { stopped: true, allowLegacyPolicy: true });
  const recovered = `POSTGRES_PASSWORD=${snapshot.password}\nBETTER_AUTH_SECRET=${snapshot.secret}\n` +
    `APP_URL=${safeDotenvLiteral(snapshot.appUrl)}\nMETAMCP_ADMIN_EMAILS=${safeDotenvLiteral(snapshot.admins)}\n` +
    `EXTRA_TRUSTED_ORIGINS=${safeDotenvLiteral(snapshot.extraOrigins)}\n` +
    `MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT=${snapshot.singleServerPolicy}\n`;
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
  const rechecked = metaContainerSnapshot(ctx, state, { stopped: true, allowLegacyPolicy: true });
  for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
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
function renderedMetaConfig(ctx, state, metaOriginOverride) {
  // Compose is the authority for dotenv quoting/interpolation. Capture its
  // complete rendering privately: it contains passwords and must not be logged.
  const result = run('docker', composeArgs(ctx, state, ['config', '--format', 'json']), {
    capture: true, allowFailure: true, env: cleanEnv(config(state, { metaOriginOverride })),
  });
  if (result.status !== 0) fail('Docker Compose could not read the private configuration. Review it locally; no container was changed.');
  try { return JSON.parse(result.stdout); } catch { fail('Docker Compose did not return a usable JSON configuration; no container was changed.'); }
}
function renderedRuntimeEnvironment(rendered, service) {
  const environment = rendered?.services?.[service]?.environment;
  if (!environment || typeof environment !== 'object' || Array.isArray(environment)) return null;
  const values = Object.create(null);
  for (const [key, value] of Object.entries(environment)) {
    if (typeof value !== 'string') return null;
    // Compose's config output escapes each literal dollar as $$ even in JSON,
    // so undo that serialization escape to obtain the actual runtime value.
    if (value.replaceAll('$$', '').includes('$')) return null;
    values[key] = value.replaceAll('$$', '$');
  }
  return values;
}
function renderedMetaSettings(ctx, state, envValues) {
  const rendered = renderedMetaConfig(ctx, state);
  const app = renderedRuntimeEnvironment(rendered, 'app');
  const postgres = renderedRuntimeEnvironment(rendered, 'postgres');
  const appUrl = configuredMetaOrigin(state);
  const trustedPrefix = trustedOriginPrefix(state, appUrl);
  const singleServerPolicy = envValues.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT ?? 'true';
  if (!app || !postgres || app.APP_URL !== appUrl || app.NEXT_PUBLIC_APP_URL !== appUrl ||
      !['true', 'false'].includes(singleServerPolicy) || app.MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT !== singleServerPolicy ||
      app.POSTGRES_PASSWORD !== envValues.POSTGRES_PASSWORD || postgres.POSTGRES_PASSWORD !== envValues.POSTGRES_PASSWORD ||
      app.BETTER_AUTH_SECRET !== envValues.BETTER_AUTH_SECRET ||
      typeof app.METAMCP_ADMIN_EMAILS !== 'string' || typeof app.EXTRA_TRUSTED_ORIGINS !== 'string' ||
      !app.EXTRA_TRUSTED_ORIGINS.startsWith(trustedPrefix) ||
      (state.lanIp && (app.MCPKIT_MULTI_AUTH_ORIGINS !== lanOrigins(state) || app.MCPKIT_COOKIE_PREFIX !== `mcpkit-${state.id}` || app.NEXT_PUBLIC_MCPKIT_MULTI_ORIGIN !== 'true')) ||
      (state.cleanTools && app.MCPKIT_CLEAN_TOOL_NAMES !== 'true')) {
    fail('Rendered MetaMCP settings or credentials do not match the private configuration; no container was changed.');
  }
  const admins = app.METAMCP_ADMIN_EMAILS;
  const emails = admins.split(',').map((value) => value.trim()).filter(Boolean);
  if ((admins.trim() && !emails.length) || emails.some((value) => !/^[^\s@\[\]<>:'"]+@[^\s@\[\]<>:'"]+$/.test(value))) {
    fail('METAMCP_ADMIN_EMAILS must be a comma-separated list of plain email addresses; no container was changed.');
  }
  const extraOrigins = app.EXTRA_TRUSTED_ORIGINS.slice(trustedPrefix.length);
  for (const value of extraOrigins.split(',').map((item) => item.trim()).filter(Boolean)) {
    let u;
    try { u = new URL(value); } catch { fail('EXTRA_TRUSTED_ORIGINS must contain literal origins, not Markdown links; no container was changed.'); }
    if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password || u.pathname !== '/' || u.search || u.hash || u.origin !== value) {
      fail('EXTRA_TRUSTED_ORIGINS must contain literal origins without paths, credentials or trailing slashes; no container was changed.');
    }
  }
  return { appUrl, admins, extraOrigins, singleServerPolicy, appEnv: app };
}
function checkMetaApplyResources(ctx, state, snapshot, planned, { after = false } = {}) {
  const outcome = after ? 'The app was recreated; inspect it before retrying.' : 'No container was changed.';
  checkResources(ctx, state);
  const appRunning = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.State.Running}}', snapshot.appId], { capture: true }).stdout.trim();
  const appHealth = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', snapshot.appId], { capture: true }).stdout.trim();
  const pgRunning = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.State.Running}}', snapshot.postgresId], { capture: true }).stdout.trim();
  const pgHealth = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', snapshot.postgresId], { capture: true }).stdout.trim();
  if (appRunning !== 'true' || (!after && appHealth !== 'healthy') || pgRunning !== 'true' || pgHealth !== 'healthy') {
    fail(`The app or PostgreSQL is not in the expected running/healthy state. ${outcome}`);
  }
  const image = config(state).MCPKIT_IMAGE;
  const labels = inspect(ctx, 'image', image);
  if (!labels) fail(`The existing MetaMCP image was not found. ${outcome}`);
  checkLabel(labels, state, 'image', image);
  if (labels['com.multfinite.mcpkit.single-server-per-endpoint-patch'] !== SINGLE_SERVER_ENDPOINT_PATCH_VERSION ||
      (state.lanIp && labels['com.multfinite.mcpkit.lan-patch'] !== LAN_PATCH_VERSION) ||
      (state.cleanTools && labels['com.multfinite.mcpkit.clean-tools-patch'] !== CLEAN_TOOLS_PATCH_VERSION)) {
    fail(`The existing MetaMCP image lacks its expected source patch labels. ${outcome}`);
  }
  const appImage = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{.Image}}', snapshot.appId], { capture: true }).stdout.trim();
  const taggedImage = run('docker', ['--context', ctx, 'image', 'inspect', '--format', '{{.Id}}', image], { capture: true }).stdout.trim();
  if (!/^sha256:[a-f0-9]{64}$/.test(appImage) || appImage !== taggedImage) fail(`The kit image tag no longer identifies the running app image. ${outcome}`);
  const imageResult = run('docker', ['--context', ctx, 'image', 'inspect', '--format', '{{json .Config.Env}}', image], { capture: true });
  const imageEnv = dockerEnvironment(imageResult.stdout, 'image');
  const appEnv = containerEnvironment(ctx, snapshot.appId);
  // Compose does not override these image defaults. A manually customized
  // command, entrypoint, user, or working directory could be lost on recreate.
  const runtimeFormat = '{{json .Config.Cmd}}\n{{json .Config.Entrypoint}}\n{{json .Config.User}}\n{{json .Config.WorkingDir}}';
  const imageRuntime = run('docker', ['--context', ctx, 'image', 'inspect', '--format', runtimeFormat, image], { capture: true }).stdout;
  const appRuntime = run('docker', ['--context', ctx, 'container', 'inspect', '--format', runtimeFormat, snapshot.appId], { capture: true }).stdout;
  if (imageRuntime !== appRuntime) fail(`The app has customized execution settings; review them locally before recreation. ${outcome}`);
  const editable = new Set(['APP_URL', 'NEXT_PUBLIC_APP_URL', 'METAMCP_ADMIN_EMAILS', 'EXTRA_TRUSTED_ORIGINS', 'MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT']);
  for (const [key, value] of Object.entries(planned.appEnv)) {
    if (!editable.has(key) && appEnv[key] !== value) fail(`The app has different non-URL settings; review them locally before recreation. ${outcome}`);
  }
  for (const [key, value] of Object.entries(appEnv)) {
    if (!Object.hasOwn(planned.appEnv, key) && imageEnv[key] !== value) fail(`The app has extra environment settings; review them locally before recreation. ${outcome}`);
  }
  const portsResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .HostConfig.PortBindings}}', snapshot.appId], { capture: true });
  let ports;
  try { ports = JSON.parse(portsResult.stdout); } catch { fail(`Cannot inspect app port bindings. ${outcome}`); }
  const published = ports && typeof ports === 'object' && !Array.isArray(ports) ? ports['12008/tcp'] : null;
  const portHosts = state.lanIp ? ['127.0.0.1', state.lanIp] : ['127.0.0.1'];
  if (!ports || Object.keys(ports).length !== 1 || !Array.isArray(published) || published.length !== portHosts.length ||
      published.some((item) => item?.HostPort !== String(state.port) || !portHosts.includes(item.HostIp)) ||
      portHosts.some((host) => published.filter((item) => item?.HostIp === host).length !== 1)) {
    fail(`The app has unexpected port bindings; review them before recreation. ${outcome}`);
  }
  const mountResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .Mounts}}', snapshot.appId], { capture: true });
  let mounts;
  try { mounts = JSON.parse(mountResult.stdout); } catch { fail(`Cannot inspect the app mounts. ${outcome}`); }
  const tmpfsResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .HostConfig.Tmpfs}}\n{{json .HostConfig.Mounts}}', snapshot.appId], { capture: true });
  let tmpfs, hostMounts;
  try { [tmpfs, hostMounts] = tmpfsResult.stdout.trim().split('\n').map((line) => JSON.parse(line)); }
  catch { fail(`Cannot inspect additional app mounts. ${outcome}`); }
  if ((tmpfs !== null && (typeof tmpfs !== 'object' || Array.isArray(tmpfs) || Object.keys(tmpfs).length)) ||
      (hostMounts !== null && (!Array.isArray(hostMounts) || hostMounts.some((item) => !['bind', 'volume'].includes(item?.Type))))) {
    fail(`The app has unexpected temporary or unsupported mounts; review and back them up before recreation. ${outcome}`);
  }
  const uvVolume = `${state.project}_uv_cache`;
  if (!Array.isArray(mounts) || mounts.length !== 1 || mounts[0]?.Type !== 'volume' || mounts[0].RW !== true ||
      mounts[0].Destination !== '/home/nextjs/.cache/uv' || mounts[0].Name !== uvVolume) {
    fail(`The app has unexpected mounts; review and back them up before recreation. ${outcome}`);
  }
  const uvLabels = inspect(ctx, 'volume', uvVolume);
  if (!uvLabels) fail(`The app cache volume was not found. ${outcome}`);
  checkLabel(uvLabels, state, 'volume', uvVolume);
  if (uvLabels['com.docker.compose.volume'] !== 'uv_cache') fail(`Unexpected cache volume identity. ${outcome}`);
  const hostsResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .HostConfig.ExtraHosts}}', snapshot.appId], { capture: true });
  let hosts;
  try { hosts = JSON.parse(hostsResult.stdout); } catch { fail(`Cannot inspect app host mappings. ${outcome}`); }
  const expectedHosts = process.platform === 'linux' ? ['host.docker.internal:host-gateway'] : [];
  const actualHosts = hosts === null ? [] : hosts;
  if (!Array.isArray(actualHosts) || actualHosts.length !== expectedHosts.length ||
      actualHosts.some((host, index) => typeof host !== 'string' || host.replace('=', ':') !== expectedHosts[index])) {
    fail(`The app has unexpected host mappings; review them before recreation. ${outcome}`);
  }
  const networkResult = run('docker', ['--context', ctx, 'container', 'inspect', '--format', '{{json .NetworkSettings.Networks}}', snapshot.appId], { capture: true });
  let networks;
  try { networks = JSON.parse(networkResult.stdout); } catch { fail(`Cannot inspect app networks. ${outcome}`); }
  const names = networks && typeof networks === 'object' && !Array.isArray(networks) ? Object.keys(networks) : [];
  const link = assertLiveGlobalNetwork(ctx, state);
  const peerLinks = assertLiveMetaPeerNetworks(ctx, state);
  const expectedNetworks = [`${state.project}_default`, ...(link ? [link.network] : []), ...peerLinks.map((peer) => peer.network)];
  if (names.length !== expectedNetworks.length || expectedNetworks.some((name) => !names.includes(name)) ||
      (link && networks[link.network]?.NetworkID !== link.networkId) ||
      peerLinks.some((peer) => networks[peer.network]?.NetworkID !== peer.networkId)) {
    fail(`The app has extra or unexpected networks. Review its connection details before applying. ${outcome}`);
  }
}
function replacePrivateFile(file, data) {
  // Write beside the target first, then rename, so an interrupted write never
  // leaves a truncated state or .env file behind.
  const temp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temp, data, { flag: 'wx', mode: 0o600 });
  fs.renameSync(temp, file);
}
// Converts an existing loopback-only MetaMCP to the explicit HTTP LAN mode.
// Order: validate, back up, write the new state/.env, build the LAN-patched app
// image, then hand over to applyMetaConfig, which asks for confirmation and
// recreates only the app container. PostgreSQL and named volumes are untouched.
async function enableMetaLan(ctx, saved, lanIp) {
  if (process.platform !== 'linux') fail('LAN mode is available only on Linux hosts.');
  if (saved.type !== 'meta') fail('set-lan applies only to a MetaMCP installation.');
  if (setupMarker(saved)) fail('Complete or remove the staged installation before enabling LAN access.');
  validateLanIp(lanIp);
  const local = Object.values(os.networkInterfaces()).flat().some((item) => item && item.family === 'IPv4' && item.address === lanIp);
  if (!local) fail(`LAN address ${lanIp} is not assigned to this host; no files were changed.`);
  const next = lanEnabledState(saved, lanIp);
  if (next === saved) {
    console.log(`LAN mode is already enabled on ${lanIp}; checking the app configuration.`);
    await applyMetaConfig(ctx, saved);
    return;
  }
  const priv = path.join(saved.base, '.mcpkit');
  const stateFile = path.join(priv, 'state.json');
  const envFile = path.join(priv, '.env');
  const oldState = privateRegularFile(stateFile);
  const oldEnv = privateRegularFile(envFile);
  if (!oldState || !oldEnv) fail('The kit state or private .env is missing; no files were changed.');
  const backupState = path.join(priv, 'state.json.pre-lan');
  const backupEnv = path.join(priv, '.env.pre-lan');
  // A backup left by an earlier failed attempt is reused only if it still equals
  // the current file; anything else is preserved for manual review.
  const sameOrMissing = (file, bytes) => !fs.existsSync(file) || (privateRegularFile(file)?.equals(bytes) ?? false);
  if (!sameOrMissing(backupState, oldState) || !sameOrMissing(backupEnv, oldEnv)) {
    fail('A pre-LAN backup differs from the current files. Review .mcpkit/*.pre-lan and move it aside before retrying; no files were changed.');
  }
  if (!fs.existsSync(backupState)) privateWrite(backupState, oldState);
  if (!fs.existsSync(backupEnv)) privateWrite(backupEnv, oldEnv);
  const newEnv = withAppUrl(oldEnv.toString('utf8'), next.appUrl);
  let image = '';
  try {
    replacePrivateFile(stateFile, `${JSON.stringify(next, null, 2)}\n`);
    replacePrivateFile(envFile, newEnv);
    // Read the image name only after the files are consistent: configuredMetaOrigin
    // validates APP_URL against the state it is given.
    image = config(next).MCPKIT_IMAGE;
    ensurePatchedSource(path.join(next.base, 'metamcp'), { lan: true, cleanTools: Boolean(next.cleanTools) });
    console.log('Building the app image with the LAN patch; the running container is not changed by this step.');
    compose(ctx, next, ['build', 'app']);
    const built = inspect(ctx, 'image', image);
    if (!built) fail(`Built image is missing: ${image}`);
    checkLabel(built, next, 'image', image);
    if (built['com.multfinite.mcpkit.lan-patch'] !== LAN_PATCH_VERSION) fail('Built image lacks the expected LAN patch label.');
  } catch (error) {
    // Restore the previous kit files; the running container was not recreated yet.
    replacePrivateFile(stateFile, oldState);
    replacePrivateFile(envFile, oldEnv);
    console.error('LAN preparation failed; the state and .env were restored from their previous content. Backups remain in .mcpkit/*.pre-lan.');
    throw error;
  }
  console.log(`LAN configuration saved for ${lanIp}:${next.port}. Confirm the app recreation below; PostgreSQL and volumes are kept.`);
  await applyMetaConfig(ctx, next);
}
async function applyMetaConfig(ctx, state) {
  const priv = path.join(state.base, '.mcpkit');
  for (const dir of [state.base, priv]) {
    const item = fs.lstatSync(dir);
    if (!item.isDirectory() || item.isSymbolicLink()) fail('The MetaMCP directory and private directory must not be links; no container was changed.');
  }
  const stateFile = path.join(priv, 'state.json');
  const envFile = path.join(priv, '.env');
  const stateBytes = privateRegularFile(stateFile);
  const envBytes = privateRegularFile(envFile);
  if (!stateBytes || !envBytes) fail('The kit state or private .env is missing; no container was changed.');
  const unchanged = (file, bytes) => { const current = privateRegularFile(file); return current !== null && current.equals(bytes); };
  let savedState;
  try { savedState = JSON.parse(stateBytes.toString('utf8')); } catch { fail('Cannot read the kit state; no container was changed.'); }
  if (JSON.stringify(savedState) !== JSON.stringify(state)) fail('The kit state changed during preflight; no container was changed.');
  const values = readEnv(state.base, 'meta');
  const before = metaContainerSnapshot(ctx, state);
  if (before.password !== values.POSTGRES_PASSWORD || before.secret !== values.BETTER_AUTH_SECRET) {
    fail('The .env credentials differ from the existing containers. Restore the correct values before applying; no container was changed.');
  }
  const planned = renderedMetaSettings(ctx, state, values);
  if (!unchanged(stateFile, stateBytes) || !unchanged(envFile, envBytes)) fail('The kit state or private .env changed during preflight; no container was changed.');
  if (!Object.hasOwn(values, 'APP_URL') && before.appUrl !== state.appUrl) {
    fail('The running app origin differs from the saved initial origin. Explicitly set APP_URL in the private .env before applying; no container was changed.');
  }
  if (!Object.hasOwn(values, 'METAMCP_ADMIN_EMAILS') && before.admins.trim() && !planned.admins.trim()) {
    fail('The existing admin allowlist would be cleared because METAMCP_ADMIN_EMAILS is missing. Set it explicitly after review; no container was changed.');
  }
  if (!Object.hasOwn(values, 'EXTRA_TRUSTED_ORIGINS') && before.extraOrigins.trim() && !planned.extraOrigins.trim()) {
    fail('Existing extra trusted origins would be cleared because EXTRA_TRUSTED_ORIGINS is missing. Set it explicitly after review; no container was changed.');
  }
  if (['appUrl', 'admins', 'extraOrigins', 'singleServerPolicy'].every((key) => before[key] === planned[key])) {
    const current = metaContainerSnapshot(ctx, state);
    for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
      if (current[key] !== before[key]) fail('Container configuration changed during inspection; no container was changed by this command.');
    }
    if (!unchanged(stateFile, stateBytes) || !unchanged(envFile, envBytes)) fail('The kit state or private .env changed during inspection; no container was changed.');
    console.log('Requested URL, admin/trusted-origin settings, and endpoint server policy already match the app container; no container was recreated. Check status separately.');
    return;
  }
  checkMetaApplyResources(ctx, state, before, planned);
  const count = (text) => text.split(',').map((value) => value.trim()).filter(Boolean).length;
  const message = `Apply MetaMCP configuration for ${state.project}?\n` +
    `Requested primary origin: ${planned.appUrl}\n` +
    `Admin allowlist: ${count(planned.admins)} address(es)${planned.admins === before.admins ? ' (unchanged)' : ' (changed)'}.\n` +
    `Additional trusted origins: ${count(planned.extraOrigins)}${planned.extraOrigins === before.extraOrigins ? ' (unchanged)' : ' (changed)'}.\n` +
    `One-server-per-endpoint policy: ${planned.singleServerPolicy === 'true' ? 'enabled' : 'DISABLED'}${planned.singleServerPolicy === before.singleServerPolicy ? ' (unchanged)' : ' (changed)'}.\n` +
    'Only the app container will be recreated; PostgreSQL and named volumes are not intentionally recreated or removed.\n' +
    'The app may run database migrations on startup. Back up the database and any files in the app container writable layer first; that layer will be lost.\n' +
    'Ensure the listed admin accounts already exist and disable public registration before exposing this service.\n' +
    (planned.admins.trim() ? '' : 'WARNING: an empty admin list makes every signed-in user an admin.\n') +
    'Do not run another start, stop, apply, or edit the .env at the same time.';
  if (!(await confirm(message, `APPLY ${state.project}`))) { console.log('Cancelled; no container was changed.'); process.exitCode = 1; return; }
  if (!unchanged(stateFile, stateBytes) || !unchanged(envFile, envBytes)) fail('The kit state or private .env changed during confirmation; no container was changed.');
  const rechecked = metaContainerSnapshot(ctx, state);
  for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
    if (rechecked[key] !== before[key]) fail('Container configuration changed during confirmation; no container was changed.');
  }
  const finalPlan = renderedMetaSettings(ctx, state, values);
  checkMetaApplyResources(ctx, state, rechecked, finalPlan);
  for (const key of ['appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
    if (finalPlan[key] !== planned[key]) fail('Rendered settings changed during confirmation; no container was changed.');
  }
  if (!unchanged(stateFile, stateBytes) || !unchanged(envFile, envBytes)) fail('The kit state or private .env changed during preflight; no container was changed.');
  try { compose(ctx, state, ['up', '-d', '--no-deps', '--force-recreate', '--no-build', 'app']); }
  catch (error) {
    console.error('App recreation may have started or partially completed. PostgreSQL and named volumes were not targeted. Check status before retrying.');
    throw error;
  }
  console.log('Compose reported app recreation complete. PostgreSQL and named volumes were not targeted for recreation or removal.');
  let after;
  try {
    after = metaContainerSnapshot(ctx, state);
    if (after.appId === before.appId || after.postgresId !== before.postgresId || after.password !== before.password || after.secret !== before.secret ||
        after.appUrl !== planned.appUrl || after.admins !== planned.admins || after.extraOrigins !== planned.extraOrigins || after.singleServerPolicy !== planned.singleServerPolicy) {
      fail('The resulting app configuration or PostgreSQL identity is unexpected.');
    }
    await waitMetaHealth(state);
    requireRunningMetaApp(ctx, state, after.appId);
    const current = metaContainerSnapshot(ctx, state);
    for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
      if (current[key] !== after[key]) fail('Container configuration changed during the health check.');
    }
    checkMetaApplyResources(ctx, state, current, finalPlan, { after: true });
  } catch (error) {
    console.error('App recreation may have completed, but a post-check failed. Inspect status and logs locally before retrying.');
    throw error;
  }
  console.log(`Applied MetaMCP origin and admin/trusted-origin settings. Current app origin: ${after.appUrl}`);
  console.log('Verify the HTTPS proxy, authentication and administrator permissions separately; the health check alone does not verify them.');
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
  const persistentLink = readLiveGlobalLink(meta);
  if (persistentLink && persistentLink.globalProject !== globalState.project) fail('This MetaMCP has a persistent link to a different GLOBAL; no network was changed.');
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
  if (detach) {
    if (persistentLink) {
      assertLiveGlobalNetwork(ctx, meta);
      fs.unlinkSync(path.join(meta.base, '.mcpkit', 'live-global-link.json'));
    }
    console.log('The selected MetaMCP was disconnected from the GLOBAL client network; records were not changed.'); return;
  }
  console.log(`MetaMCP is connected to the isolated GLOBAL client network. Gateway URL for connect-global: http://${globalState.project}-gateway:13001`);
  console.log(`Traffic on this local Docker network is not encrypted; use it only if the host and network are trusted. ${persistentLink ? 'The saved link survives app recreation.' : 'Reconnect after recreating the MetaMCP app.'}`);
}

function requirePrivateDirectory(dir) {
  const item = fs.lstatSync(dir);
  if (!item.isDirectory() || item.isSymbolicLink() || (item.mode & 0o077) !== 0) {
    fail(`Private directory must be a real directory inaccessible to group/other users: ${dir}. No database records were changed.`);
  }
}
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}
function sharingManifest(journal) {
  if (![1, 2].includes(journal?.version) || !['global', 'local'].includes(journal.profile) ||
      (journal.version === 2 && journal.naming !== 'official-v1')) {
    fail('Only completed grouped v1/v2 independent LOCAL/GLOBAL registrations can be converted.');
  }
  const linuxLocal = journal.servers && Object.hasOwn(journal.servers, 'linux-desktop');
  const definitions = journal.profile === 'global' ? LEGACY_GLOBAL_GROUPS : legacyLocalGroups(linuxLocal);
  const serverNames = journal.profile === 'global' ? GLOBAL_SERVER_NAMES : LOCAL_SERVER_NAMES;
  const previousGroups = journal.profile === 'global' ? LEGACY_GLOBAL_GROUP_NAMES : LEGACY_LOCAL_GROUP_NAMES;
  const groups = Object.keys(definitions);
  const serverIds = [...new Set(Object.values(definitions).flat())];
  const validUuid = (value) => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
  if (journal.pending !== null || typeof journal.owner !== 'string' || !journal.owner || journal.owner.length > 320 || /[\x00-\x1f\x7f]/.test(journal.owner) ||
      (journal.version === 1 && !new RegExp(`^mcpkit-${journal.profile}-[a-f0-9]{12}$`).test(journal.prefix || '')) ||
      !exactKeys(journal.servers, serverIds) || !exactKeys(journal.namespaces, groups) || !exactKeys(journal.endpoints, groups)) {
    fail('Registration is incomplete, pending, or has unexpected records; no database records were changed.');
  }
  const unique = (ids) => new Set(ids.map((value) => value.toLowerCase())).size === ids.length;
  const servers = serverIds.map((id) => {
    const item = journal.servers[id];
    const name = serverNames[id];
    const oldName = journal.version === 1 ? `${journal.prefix}-${id}` : name;
    if (!item || !validUuid(item.uuid) || item.name !== oldName || !/^[a-f0-9]{64}$/.test(item.hash || '') ||
        typeof name !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(name) || /__/.test(name)) {
      fail('Registration contains an invalid server record; no database records were changed.');
    }
    return { uuid: item.uuid, old_name: item.name, name };
  });
  if (!unique(servers.map((item) => item.uuid)) || !unique(servers.map((item) => item.name))) fail('Duplicate registered server UUID or name; no database records were changed.');
  const namespaces = groups.map((group) => {
    const item = journal.namespaces[group];
    const name = serverNames[definitions[group][0]];
    const oldName = journal.version === 1 ? `${journal.prefix}-${group}` : previousGroups[group];
    const expected = definitions[group].map((id) => journal.servers[id].uuid.toLowerCase()).sort();
    if (!item || !validUuid(item.uuid) || item.name !== oldName || typeof name !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(name) || !Array.isArray(item.servers) ||
        item.servers.some((id) => !validUuid(id)) || JSON.stringify(item.servers.map((id) => id.toLowerCase()).sort()) !== JSON.stringify(expected)) {
      fail('Registration contains an invalid namespace or membership; no database records were changed.');
    }
    return { uuid: item.uuid, old_name: item.name, previous_name: previousGroups[group], name,
      servers: [...item.servers], member_names: definitions[group].map((id) => serverNames[id]) };
  });
  if (!unique(namespaces.map((item) => item.uuid)) || !unique(namespaces.map((item) => item.name))) fail('Duplicate registered namespace UUID or name; no database records were changed.');
  const endpoints = groups.map((group) => {
    const item = journal.endpoints[group];
    const oldName = journal.version === 1 ? `${journal.prefix}-${group}` : previousGroups[group];
    if (!item || !validUuid(item.uuid) || item.name !== oldName) {
      fail('Registration contains an invalid endpoint; no database records were changed.');
    }
    return { uuid: item.uuid, old_name: item.name, previous_name: previousGroups[group],
      name: serverNames[definitions[group][0]], namespace_uuid: journal.namespaces[group].uuid };
  });
  if (!unique(endpoints.map((item) => item.uuid)) || !unique(endpoints.map((item) => item.name))) fail('Duplicate registered endpoint UUID or name; no database records were changed.');
  const anchors = new Set(groups.map((group) => definitions[group][0]));
  const additional = serverIds.filter((id) => !anchors.has(id)).map((id) => {
    const source = groups.find((group) => definitions[group].includes(id));
    return { namespace_uuid: crypto.randomUUID(), endpoint_uuid: crypto.randomUUID(), name: serverNames[id],
      server_uuid: journal.servers[id].uuid, source_namespace_uuid: journal.namespaces[source].uuid,
      source_endpoint_uuid: journal.endpoints[source].uuid, description: `MCP Kit ${journal.profile}: ${id}` };
  });
  if (!unique([...namespaces.map((item) => item.uuid), ...additional.map((item) => item.namespace_uuid)]) ||
      !unique([...endpoints.map((item) => item.uuid), ...additional.map((item) => item.endpoint_uuid)]) ||
      !unique([...namespaces.map((item) => item.name), ...additional.map((item) => item.name)])) {
    fail('Duplicate generated namespace or endpoint identity; no database records were changed.');
  }
  return { owner: journal.owner, servers, namespaces, endpoints, additional };
}
function registeredGlobalJournal(state, snapshot, gatewayKey, registration) {
  const dir = path.join(state.base, '.mcpkit', 'registrations');
  requirePrivateDirectory(dir);
  if (registration && !/^[a-f0-9]{32}$/.test(registration)) fail('The registration ID must be 32 lowercase hexadecimal characters.');
  const names = registration ? [`${registration}.json`] : fs.readdirSync(dir).filter((name) => /^[a-f0-9]{32}\.json$/.test(name));
  const candidates = [];
  for (const name of names) {
    const file = path.join(dir, name);
    const bytes = privateRegularFile(file);
    if (!bytes) continue;
    let journal;
    try { journal = JSON.parse(bytes.toString('utf8')); } catch { continue; }
    if (!journal || ![1, 2].includes(journal.version) || journal.profile !== 'global' || journal.hostId !== state.id ||
        journal.origin !== snapshot.appUrl || journal.keyHash !== sha256(gatewayKey) ||
        typeof journal.owner !== 'string' || typeof journal.gateway !== 'string') continue;
    const expected = sha256(`${journal.origin}\n${journal.owner}\n${journal.gateway}\n${journal.profile}\n${journal.hostId}`).slice(0, 32);
    if (name !== `${expected}.json`) continue;
    candidates.push({ file, bytes, journal, id: expected });
  }
  if (candidates.length !== 1) {
    if (candidates.length > 1) console.log(`Matching registration IDs: ${candidates.map((item) => item.id).join(', ')}`);
    fail('Expected exactly one matching GLOBAL registration for this MetaMCP origin and gateway key. If there are several, select one with --registration; no database records were changed.');
  }
  return candidates[0];
}
function shareSql(ctx, postgresId, manifest, apply) {
  const template = fs.readFileSync(path.join(root, 'common', 'share-registration.sql'), 'utf8');
  const parts = template.split('__MCPKIT_BUNDLE_BASE64__');
  if (parts.length !== 2) fail('Invalid sharing SQL template; no database records were changed.');
  const encoded = Buffer.from(JSON.stringify({ ...manifest, apply }), 'utf8').toString('base64');
  const sql = `${parts[0]}${encoded}${parts[1]}`;
  const command = 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"';
  const result = spawnSync('docker', ['--context', ctx, 'exec', '-i', postgresId, 'sh', '-c', command], {
    input: sql, encoding: 'utf8', env: cleanEnv(), maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0 || result.stdout.trim() !== 'MCPKIT_PUBLIC_OK') {
    const detail = (result.stderr || '').split(/\r?\n/).find((line) => /\b(?:ERROR|FATAL):/.test(line));
    const hint = detail ? ` ${detail.slice(0, 300)}` : '';
    if (apply) fail(`The sharing transaction did not report success; it may have committed. Inspect the records and the backup before retrying.${hint}`);
    fail(`Registration sharing preflight failed; no database records were changed.${hint}`);
  }
}
function backupMetaForSharing(ctx, state, postgresId) {
  const directory = path.join(state.base, '.mcpkit', 'backups');
  try { fs.mkdirSync(directory, { mode: 0o700 }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  requirePrivateDirectory(directory);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const file = path.join(directory, `before-registration-sharing-${stamp}-${crypto.randomBytes(6).toString('hex')}.dump`);
  const fd = fs.openSync(file, 'wx', 0o600);
  let success = false;
  try {
    const command = 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom';
    const result = spawnSync('docker', ['--context', ctx, 'exec', postgresId, 'sh', '-c', command], {
      stdio: ['ignore', fd, 'pipe'], encoding: 'utf8', env: cleanEnv(), maxBuffer: 1024 * 1024,
    });
    if (result.error || result.status !== 0) fail('Could not create the PostgreSQL backup; no database records were changed.');
    fs.fsyncSync(fd);
    success = true;
  } finally {
    fs.closeSync(fd);
    if (!success) { try { fs.unlinkSync(file); } catch { /* private partial backup may remain */ } }
  }
  const check = fs.openSync(file, 'r');
  const magic = Buffer.alloc(5);
  let length;
  try { length = fs.readSync(check, magic, 0, magic.length, 0); } finally { fs.closeSync(check); }
  if (length !== magic.length || magic.toString('ascii') !== 'PGDMP') fail(`PostgreSQL backup has an unexpected format: ${file}. No database records were changed.`);
  const archive = fs.openSync(file, 'r');
  let verified;
  try {
    // --list can exit after the catalog without reading all archive data.
    // Keep the Docker stdin open and drain the rest to avoid a broken pipe.
    const command = 'pg_restore --list >/dev/null; status=$?; cat >/dev/null || exit 1; exit "$status"';
    verified = spawnSync('docker', ['--context', ctx, 'exec', '-i', postgresId, 'sh', '-c', command], {
      stdio: [archive, 'ignore', 'pipe'], encoding: 'utf8', env: cleanEnv(), maxBuffer: 1024 * 1024,
    });
  } finally { fs.closeSync(archive); }
  if (verified.error || verified.status !== 0) fail(`Could not read the PostgreSQL backup catalog: ${file}. No database records were changed.`);
  console.log(`Private database dump: ${file} (contains secrets; copy it off this machine). Its catalog was read, but a restore was not verified.`);
  return file;
}
function snapshotFiles(files) {
  return files.map((file) => {
    const bytes = privateRegularFile(file);
    if (!bytes) fail(`Missing private kit file: ${file}. No database records were changed.`);
    return { file, bytes };
  });
}
function assertFilesUnchanged(files) {
  for (const item of files) {
    const current = privateRegularFile(item.file);
    if (!current || !current.equals(item.bytes)) fail('A kit state, configuration, or registration changed; no sharing update was attempted.');
  }
}
function prepareSharingMeta(ctx, meta, savedMeta) {
  if (process.platform !== 'linux' || meta.type !== 'meta' || meta.revision !== revision) {
    fail('Sharing requires a local Linux independent MetaMCP with the expected pinned revision.');
  }
  const dir = fs.lstatSync(meta.base);
  if (!dir.isDirectory() || dir.isSymbolicLink()) fail('The MetaMCP directory must be a real directory, not a link.');
  const priv = path.join(meta.base, '.mcpkit');
  requirePrivateDirectory(priv);
  const files = snapshotFiles([path.join(priv, 'state.json'), path.join(priv, '.env')]);
  // Compare the bytes on disk to the original state, not the temporary view
  // whose base points at the directory explicitly selected for this command.
  if (JSON.stringify(JSON.parse(files[0].bytes)) !== JSON.stringify(savedMeta)) fail('The MetaMCP state changed; no database records were changed.');
  const env = readEnv(meta.base, 'meta');
  checkResources(ctx, meta);
  const before = metaContainerSnapshot(ctx, meta);
  if (before.password !== env.POSTGRES_PASSWORD || before.secret !== env.BETTER_AUTH_SECRET) {
    fail('MetaMCP credentials differ from its existing containers; no database records were changed.');
  }
  requireRunningMetaApp(ctx, meta, before.appId);
  const postgresStatus = run('docker', ['--context', ctx, 'container', 'inspect', '--format',
    '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', before.postgresId], { capture: true }).stdout.trim();
  if (postgresStatus !== 'true healthy') fail('The selected MetaMCP PostgreSQL container must be running and healthy.');
  return { before, files, priv };
}
async function shareSelectedRegistration(ctx, meta, prepared, selected, extraCheck = () => {}) {
  const lockFile = `${selected.file}.lock`;
  let lock;
  try { lock = fs.openSync(lockFile, 'wx', 0o600); } catch { fail('The registration is locked; inspect the lock before retrying. No database records were changed.'); }
  try {
    const unchanged = () => {
      requirePrivateDirectory(prepared.priv);
      requirePrivateDirectory(path.dirname(selected.file));
      assertFilesUnchanged([...prepared.files, { file: selected.file, bytes: selected.bytes }]);
      const current = metaContainerSnapshot(ctx, meta);
      for (const key of ['appId', 'postgresId', 'password', 'secret', 'appUrl', 'admins', 'extraOrigins', 'singleServerPolicy']) {
        if (current[key] !== prepared.before[key]) fail('MetaMCP containers changed during inspection; no sharing update was attempted.');
      }
      requireRunningMetaApp(ctx, meta, prepared.before.appId);
      checkResources(ctx, meta);
      extraCheck();
    };
    unchanged();
    const manifest = sharingManifest(selected.journal);
    shareSql(ctx, prepared.before.postgresId, manifest, false);
    const profile = selected.journal.profile.toUpperCase();
    console.log(`Public server names: ${manifest.servers.map((item) => item.name).join(', ')}`);
    console.log('New endpoint URLs:');
    for (const item of [...manifest.endpoints, ...manifest.additional]) console.log(`  ${prepared.before.appUrl}/metamcp/${item.name}/mcp`);
    console.log('Existing groups retain all of their members. These renamed endpoints expose MORE THAN ONE server:');
    for (const item of manifest.namespaces.filter((entry) => entry.member_names.length > 1)) {
      console.log(`  ${item.name}: ${item.member_names.join(', ')}`);
    }
    const message = `Rename and make the registered ${profile} records shared in ${meta.project}?\n` +
      `Registration: ${selected.id}; ${manifest.servers.length} existing servers, ${manifest.namespaces.length} existing groups, ${manifest.additional.length} additional single-server endpoints.\n` +
      'All MetaMCP users can use the shared servers, including configured credentials and stored data.\n' +
      'Server connection settings may have been edited; they are not compared with the journal hash and will be shared as they are. Review them first.\n' +
      (profile === 'LOCAL' ? 'WARNING: LOCAL tools can expose files, terminal, databases and desktop control.\n' : '') +
      'Existing group memberships and endpoint authentication remain unchanged; additional endpoints copy their source group settings. Any valid MetaMCP API key can use a shared API-key endpoint.\n' +
      'Old endpoint URLs and server-prefixed tool names will change; reconnect clients. Avoid concurrent edits during this operation.\n' +
      'A private database dump and migration plan will be saved first. The database changes run in one transaction; no existing records are deleted.';
    if (!(await confirm(message, `SHARE ${profile}`))) { console.log('Cancelled; no database records were changed.'); process.exitCode = 1; return; }
    unchanged();
    const backup = backupMetaForSharing(ctx, meta, prepared.before.postgresId);
    const plan = `${backup}.plan.json`;
    privateWrite(plan, `${JSON.stringify({ version: 1, registration: selected.id, manifest }, null, 2)}\n`);
    unchanged();
    try { shareSql(ctx, prepared.before.postgresId, manifest, true); }
    catch (error) { console.error(`Database backup: ${backup}; migration plan: ${plan}. Inspect the result before retrying.`); throw error; }
    console.log(`${profile} registration ${selected.id} is shared. Existing UUIDs, endpoint authentication, settings, and mappings were preserved; additional endpoints were created.`);
    console.log(`Private migration plan: ${plan}`);
    console.log('Refresh MetaMCP and reconnect clients using the new URLs. Direct SQL does not invalidate existing MetaMCP pool sessions; active/idle sessions may temporarily retain old server names.');
    console.log('Only trusted users/clients should receive access; shared services can use configured credentials.');
  } finally {
    fs.closeSync(lock);
    fs.unlinkSync(lockFile);
  }
}
async function shareGlobalRegistration(ctx, globalState, savedGlobal, metaDir, registration) {
  if (process.platform !== 'linux' || globalState.type !== 'global' || !metaDir) {
    fail('GLOBAL sharing requires a local Linux GLOBAL directory and independent MetaMCP directory.');
  }
  const dir = fs.lstatSync(globalState.base);
  if (!dir.isDirectory() || dir.isSymbolicLink()) fail('The GLOBAL directory must be a real directory, not a link.');
  const priv = path.join(globalState.base, '.mcpkit');
  requirePrivateDirectory(priv);
  const files = snapshotFiles([path.join(priv, 'state.json'), path.join(priv, '.env')]);
  if (JSON.stringify(JSON.parse(files[0].bytes)) !== JSON.stringify(savedGlobal)) fail('The GLOBAL state changed; no database records were changed.');
  const env = readEnv(globalState.base, 'global');
  checkResources(ctx, globalState);
  // If the directory moved, do not trust a copied state/journal alone: also
  // match its original credentials and data volume to the owned gateway.
  const gatewayIds = savedGlobal.base === globalState.base ? null : relocationContainerIds(ctx, globalState, env);
  const metaBase = path.resolve(metaDir);
  const savedMeta = originState(metaBase, { allowRelocated: true });
  const meta = sharingState(savedMeta, metaBase);
  const prepared = prepareSharingMeta(ctx, meta, savedMeta);
  const selected = registeredGlobalJournal(globalState, prepared.before, env.MCPKIT_GATEWAY_KEY, registration);
  await shareSelectedRegistration(ctx, meta, prepared, selected, () => {
    requirePrivateDirectory(priv);
    assertFilesUnchanged(files);
    checkResources(ctx, globalState);
    if (gatewayIds && JSON.stringify(relocationContainerIds(ctx, globalState, env)) !== JSON.stringify(gatewayIds)) {
      fail('The GLOBAL gateway changed during inspection; no sharing update was attempted.');
    }
  });
}
async function shareRegistrationFile(ctx, meta, savedMeta, registrationFile) {
  if (!registrationFile) fail('Pass the completed registration journal file.');
  const prepared = prepareSharingMeta(ctx, meta, savedMeta);
  const file = path.resolve(registrationFile);
  requirePrivateDirectory(path.dirname(file));
  const bytes = privateRegularFile(file);
  if (!bytes) fail('Registration journal not found; no database records were changed.');
  let journal;
  try { journal = JSON.parse(bytes.toString('utf8')); } catch { fail('Invalid registration journal; no database records were changed.'); }
  if (!journal || ![1, 2].includes(journal.version) || !['global', 'local'].includes(journal.profile) ||
      journal.origin !== prepared.before.appUrl || typeof journal.owner !== 'string' || !journal.owner ||
      typeof journal.gateway !== 'string' || !journal.gateway || /[\r\n\0]/.test(journal.owner + journal.gateway) ||
      !/^[a-f0-9]{64}$/.test(journal.keyHash || '') ||
      (journal.profile === 'global' ? !/^[a-f0-9]{16}$/.test(journal.hostId || '') :
        !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(journal.hostId || '') || journal.hostId.length > 32)) {
    fail('Journal target or identity is invalid; no database records were changed.');
  }
  const id = sha256(`${journal.origin}\n${journal.owner}\n${journal.gateway}\n${journal.profile}\n${journal.hostId}`).slice(0, 32);
  if (path.basename(file) !== `${id}.json`) fail('Journal filename or identity changed; preserve its original filename. No database records were changed.');
  await shareSelectedRegistration(ctx, meta, prepared, { file, bytes, journal, id });
}

try {
  if (Number(process.versions.node.split('.')[0]) < 20) fail('Node.js 20 or newer is required.');
  if (!['init-meta', 'init-global', 'start', 'stop', 'status', 'logs', 'apply', 'set-lan', 'remove', 'link', 'unlink', 'link-metamcp', 'unlink-metamcp', 'check-env', 'recover-env', 'share-global', 'share-registration', 'relocate', 'provision-meta', 'activate-meta'].includes(action)) fail('Usage: stack.mjs {init-meta|init-global|start|stop|status|logs|apply|set-lan|remove|link|unlink|link-metamcp|unlink-metamcp|check-env|recover-env|share-global|share-registration|relocate|provision-meta|activate-meta} --dir DIR [options]');
  const opts = parseArgs(argv);
  if (opts.expectType && !['meta', 'global'].includes(opts.expectType)) fail('Unknown expected kit type.');
  if (opts.deleteVolumes && action !== 'remove') fail('--delete-volumes is only valid for remove.');
  if (opts.metaDir && !['link', 'unlink', 'share-global'].includes(action)) fail('--meta-dir is only valid for link/unlink/share-global.');
  if (opts.peerDir && !['link-metamcp', 'unlink-metamcp'].includes(action)) fail('--peer-dir is only valid for link-metamcp/unlink-metamcp.');
  if (['link-metamcp', 'unlink-metamcp'].includes(action) !== Boolean(opts.peerDir)) fail('link-metamcp/unlink-metamcp require --peer-dir.');
  if (opts.endpoint && action !== 'link-metamcp') fail('--endpoint is only valid for link-metamcp.');
  if ((action === 'link-metamcp') !== Boolean(opts.endpoint)) fail('link-metamcp requires --endpoint to select an endpoint on the first MetaMCP.');
  if (opts.server && action !== 'logs') fail('--server is only valid for logs.');
  if (opts.registration && action !== 'share-global') fail('--registration is only valid for share-global.');
  if (opts.registrationFile && action !== 'share-registration') fail('--registration-file is only valid for share-registration.');
  if (!opts.dir) fail('--dir is required.');
  const isInit = action === 'init-meta' || action === 'init-global';
  if (isInit && opts.expectType && opts.expectType !== (action === 'init-meta' ? 'meta' : 'global')) fail('The requested and expected kit types differ.');
  if (!isInit && (opts.port || opts.appUrl)) fail('Ports and APP_URL are only accepted for new installations.');
  if (action === 'init-global' && opts.appUrl) fail('--app-url is only for MetaMCP.');
  if (!['init-meta', 'set-lan'].includes(action) && (opts.staged || opts.fresh || opts.lanIp || opts.adminEmail || opts.allowInsecureLan || opts.cleanTools)) fail('Staging, fresh-install, clean-tool and LAN options are only available for init-meta and set-lan.');
  if (action === 'set-lan' && (!opts.lanIp || !opts.allowInsecureLan || opts.staged || opts.fresh || opts.adminEmail || opts.cleanTools || opts.port || opts.appUrl)) {
    fail('set-lan requires --lan-ip <private IPv4 of this host> and --allow-insecure-lan, and accepts no other install options.');
  }
  if (opts.adminEmail && !opts.staged) fail('--admin-email requires --staged.');
  const base = path.resolve(opts.dir);
  const isSharing = action === 'share-global' || action === 'share-registration';
  const saved = isInit ? initialize(action === 'init-meta' ? 'meta' : 'global', opts) :
    originState(base, { allowRelocated: isSharing || action === 'relocate' });
  const state = isSharing ? sharingState(saved, base) : saved;
  if (opts.expectType && state.type !== opts.expectType) fail(`Expected a ${opts.expectType} project at ${base}; no Docker resource was changed.`);
  if (opts.server && state.type !== 'global') fail('--server is only available for GLOBAL logs.');
  let peerState = null;
  if (['link-metamcp', 'unlink-metamcp'].includes(action)) {
    if (state.type !== 'meta') fail('MetaMCP peer links require --dir to select an independent MetaMCP.');
    peerState = originState(path.resolve(opts.peerDir));
    if (peerState.type !== 'meta' || peerState.project === state.project || peerState.base === state.base) {
      fail('--peer-dir must select a different independent kit MetaMCP; no Docker resource was changed.');
    }
  }
  // The peer-link operation uses the MetaMCP frontend API and Docker ownership
  // checks, but does not need to read the project's Compose secrets.
  let envError = null;
  if (action === 'status') {
    try { readEnv(state.base, state.type); } catch (error) { envError = error; }
  } else if (!['stop', 'check-env', 'recover-env', 'relocate', 'link-metamcp', 'unlink-metamcp'].includes(action)) readEnv(state.base, state.type);
  const ctx = dockerContext();
  if (isInit || action === 'start') await start(ctx, state);
  else if (action === 'provision-meta') {
    if (state.type !== 'meta') fail('provision-meta is only for a MetaMCP.');
    await provisionStagedMeta(ctx, state);
  } else if (action === 'activate-meta') {
    if (state.type !== 'meta') fail('activate-meta is only for a MetaMCP.');
    await activateStagedMeta(ctx, state);
  } else if (action === 'stop') stopOwnedContainers(ctx, state);
  else if (action === 'check-env') checkMetaEnv(ctx, state);
  else if (action === 'recover-env') await recoverMetaEnv(ctx, state);
  else if (action === 'relocate') await relocateKit(ctx, saved, base);
  else if (action === 'link' || action === 'unlink') connectLocalProjects(ctx, state, opts.metaDir, action === 'unlink');
  else if (action === 'link-metamcp') {
    // Argument order is directional: A is the first/source instance, B the
    // second/target. Only B receives a remote MCP server, namespace and endpoint.
    assertMetaPeerAppsRunning(ctx, state, peerState);
    const registration = await prepareMetaPeerRegistration(state, peerState, opts.endpoint);
    linkMetaPeers(ctx, state, peerState);
    probeMetaPeerEndpoint(ctx, state, peerState, registration.sourceUrl, registration.sourceApiKey);
    await commitMetaPeerRegistration(registration);
  }
  else if (action === 'unlink-metamcp') unlinkMetaPeers(ctx, state, peerState);
  else if (action === 'share-global') await shareGlobalRegistration(ctx, state, saved, opts.metaDir, opts.registration);
  else if (action === 'share-registration') await shareRegistrationFile(ctx, state, saved, opts.registrationFile);
  else if (action === 'set-lan') await enableMetaLan(ctx, state, opts.lanIp);
  else if (action === 'apply') {
    if (state.type === 'meta' && setupMarker(state)) fail('Complete or remove the staged installation before applying configuration.');
    if (state.type === 'meta') await applyMetaConfig(ctx, state);
    else {
      checkResources(ctx, state);
      ensureImages(ctx, state);
      console.log('Recreating only the kit gateway, Graphiti and Cognee containers to apply configuration. Named volumes are preserved.');
      compose(ctx, state, ['up', '-d', '--no-deps', '--force-recreate', '--no-build', 'gateway', 'graphiti', 'cognee']);
    }
  } else if (action === 'remove') {
    if (state.type === 'meta' && readLiveMetaPeerLinks(state).length) {
      const command = process.platform === 'win32'
        ? '.\\windows\\link-metamcp.ps1 META_DIRECTORY PEER_DIRECTORY -Unlink'
        : 'bash linux/link-metamcp.sh META_DIRECTORY PEER_DIRECTORY --unlink';
      fail(`Disconnect every MetaMCP peer (${command}) before removing this project; containers and data were not changed.`);
    }
    const expected = `${opts.deleteVolumes ? 'DELETE' : 'REMOVE'} ${state.project}`;
    const warning = opts.deleteVolumes
      ? `WARNING: removing containers AND ALL named volumes of ${state.project}, including database and user data. Back them up first. Files in ${state.base} remain.`
      : `Removing containers and network of ${state.project}; writable container layers are lost. Named volumes and files in ${state.base} remain.`;
    // A cancelled removal must fail shell chains: otherwise a following
    // reinstall or directory deletion could run despite the cancellation.
    if (!(await confirm(warning, expected))) { console.log('Cancelled; nothing was removed.'); process.exit(1); }
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
