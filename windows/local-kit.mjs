import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startGateway } from './gateway.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MANIFEST = JSON.parse(fs.readFileSync(path.join(HERE, 'manifest.json'), 'utf8'));
const BASE = path.resolve(process.env.MCP_LOCAL_DIR || path.join(os.homedir(), 'mcp-local'));
const CONFIG = path.join(BASE, 'config');
const PRIVATE = path.join(CONFIG, 'private');
const SETTINGS_FILE = path.join(CONFIG, 'local-settings.json');
const SECRETS_FILE = path.join(PRIVATE, 'secrets.json');
const STATE_FILE = path.join(PRIVATE, 'gateway-state.json');
const LOGS = path.join(BASE, 'logs');
const RUNTIME = path.join(BASE, 'runtime');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

function writeJson(file, value) {
  // The caller only uses this for kit-owned settings and generated state.
  const temp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temp, file);
  } finally { try { fs.unlinkSync(temp); } catch { /* already renamed */ } }
}

function validateSettings(settings, secrets) {
  if (!settings || settings.version !== 1) throw new Error('Unsupported local settings version.');
  if (typeof settings.hostId !== 'string' || settings.hostId.length > 32 || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(settings.hostId)) throw new Error('hostId must contain only lowercase letters, digits, and single hyphens (max 32 characters).');
  if (typeof settings.listenHost !== 'string' || !/^[a-zA-Z0-9.:-]+$/.test(settings.listenHost)) throw new Error('Invalid listenHost.');
  if (!Number.isInteger(settings.port) || settings.port < 1 || settings.port > 65535) throw new Error('port must be between 1 and 65535.');
  for (const key of ['projectsDir', 'writingDir', 'everythingSdkPath']) {
    if (typeof settings[key] !== 'string' || !path.isAbsolute(settings[key])) throw new Error(`${key} must be an absolute path.`);
  }
  // Upstream mcp-obsidian disables TLS verification. Keep the API and its
  // bearer key on this computer unless the user provides a local tunnel.
  if (typeof settings.obsidianHost !== 'string' || !['127.0.0.1', 'localhost'].includes(settings.obsidianHost.toLowerCase())) throw new Error('obsidianHost must be localhost or 127.0.0.1; use a local tunnel for a remote Obsidian API.');
  if (!Number.isInteger(settings.obsidianPort) || settings.obsidianPort < 1 || settings.obsidianPort > 65535) throw new Error('Invalid obsidianPort.');
  if (typeof settings.allowInsecureLan !== 'boolean') throw new Error('allowInsecureLan must be true or false.');
  if (!secrets || typeof secrets.gatewayApiKey !== 'string' || !/^[a-f0-9]{64}$/.test(secrets.gatewayApiKey)) throw new Error('Invalid gateway key in secrets.json; do not delete it on an existing installation.');
  for (const key of ['obsidianApiKey', 'dbhubDsn']) if (typeof secrets[key] !== 'string') throw new Error(`${key} must be a string in secrets.json.`);
  for (const key of ['tlsCertFile', 'tlsKeyFile', 'advertiseBaseUrl', 'metamcpOwnerEmail', 'linuxSshTarget', 'linuxKitDir']) if (typeof settings[key] !== 'string') throw new Error(`${key} must be a string.`);
  if (Boolean(settings.tlsCertFile) !== Boolean(settings.tlsKeyFile)) throw new Error('Set both tlsCertFile and tlsKeyFile, or leave both blank.');
  for (const key of ['tlsCertFile', 'tlsKeyFile']) {
    if (settings[key] && (!path.isAbsolute(settings[key]) || !fs.existsSync(settings[key]))) throw new Error(`${key} must be an existing absolute file path.`);
  }
  if (!['127.0.0.1', '::1', 'localhost'].includes(settings.listenHost.toLowerCase()) && !settings.tlsCertFile && !settings.allowInsecureLan) {
    throw new Error('A non-loopback listener needs TLS, or explicit HTTP opt-in for an encrypted private VPN/tunnel.');
  }
}

function loadConfig() {
  if (!fs.existsSync(SETTINGS_FILE) || !fs.existsSync(SECRETS_FILE)) throw new Error('Run install-local.ps1 first.');
  const settings = readJson(SETTINGS_FILE);
  const secrets = readJson(SECRETS_FILE);
  validateSettings(settings, secrets);
  return { settings, secrets };
}

export function buildServerSpecs(settings, secrets, base = BASE, nodePath = process.execPath) {
  const runtime = path.join(base, 'runtime');
  const core = path.join(runtime, 'npm', 'core', 'node_modules');
  const npm = (group, ...parts) => path.join(runtime, 'npm', group, 'node_modules', ...parts);
  const py = (name, exe) => path.join(runtime, 'python', name, process.platform === 'win32' ? 'Scripts' : 'bin', process.platform === 'win32' ? `${exe}.exe` : exe);
  const work = path.join(runtime, 'work');
  const nodeSpec = (id, entry, args = [], env = {}, waitReason = '') => ({ id, command: nodePath, entry, args: [entry, ...args], env, waitReason, cwd: path.join(work, id) });
  const pythonSpec = (id, name, exe, args = [], env = {}, waitReason = '') => ({ id, command: py(name, exe), args, env, waitReason, cwd: path.join(work, id) });
  const projectsMissing = !fs.existsSync(settings.projectsDir) ? 'projectsDir does not exist.' : '';
  const writingMissing = !fs.existsSync(settings.writingDir) ? 'writingDir does not exist.' : '';
  const commonPath = [path.dirname(nodePath), path.join(core, '.bin'), process.env.PATH || process.env.Path || ''].join(path.delimiter);
  const commonEnv = { PATH: commonPath, Path: commonPath };
  const sdkMissing = process.platform === 'win32' && !fs.existsSync(settings.everythingSdkPath) ? 'Everything SDK DLL is missing; rerun installation or set everythingSdkPath.' : '';
  const obsidianMissing = secrets.obsidianApiKey.trim() ? '' : 'Set obsidianApiKey in config/private/secrets.json and restart.';
  // DBHub's SQLite parser does not URL-decode percent escapes. A relative DSN
  // plus cwd preserves spaces, Unicode, # and UNC profile paths without ever
  // placing an encoded path in the SQLite filename.
  const dbDsn = secrets.dbhubDsn.trim() || 'sqlite:////./dbhub.sqlite';
  const filesystemEntry = npm('core', '@j0hanz', 'filesystem-mcp', 'dist', 'index.js');
  const watchConfig = path.join(runtime, 'vector-watch.json');
  const specs = [
    nodeSpec('desktop-commander', npm('core', '@wonderwhy-er', 'desktop-commander', 'dist', 'index.js'), ['--no-onboarding'], { DESKTOP_COMMANDER_DISABLE_TELEMETRY: '1' }),
    pythonSpec('everything-search', 'everything-search', 'mcp-server-everything-search', [], { EVERYTHING_SDK_PATH: settings.everythingSdkPath, EVERYTHING_SEARCH_TOOL_NAME: 'everything_search' }, sdkMissing),
    nodeSpec('filesystem', path.join(HERE, 'filesystem-launcher.mjs'), [filesystemEntry, settings.projectsDir, settings.writingDir], { FS_PORT: '' }, projectsMissing || writingMissing),
    pythonSpec('windows-mcp', 'windows-mcp', 'windows-mcp', ['serve', '--transport', 'stdio'], { ANONYMIZED_TELEMETRY: 'false' }, process.platform === 'win32' ? '' : 'Windows-MCP requires an interactive Windows desktop.'),
    pythonSpec('git', 'git', 'mcp-server-git'),
    // The upstream shim prunes older fallback bundles. Keep that cache in the
    // kit rather than touching an existing ~/.codegraph installation.
    nodeSpec('codegraph', npm('core', '@colbymchenry', 'codegraph', 'npm-shim.js'), ['serve', '--mcp', '--path', settings.projectsDir], { CODEGRAPH_TELEMETRY: '0', CODEGRAPH_INSTALL_DIR: path.join(runtime, 'codegraph') }, projectsMissing),
    nodeSpec('codebase-memory-mcp', npm('codebase', 'codebase-memory-mcp', 'bin.js')),
    pythonSpec('serena', 'serena', 'serena', ['start-mcp-server', '--transport', 'stdio', '--enable-web-dashboard', 'false', '--enable-gui-log-window', 'false', '--open-web-dashboard', 'false']),
    nodeSpec('playwright', npm('core', '@playwright', 'mcp', 'cli.js'), ['--headless', '--browser', 'chromium'], { PLAYWRIGHT_MCP_PORT: '', PLAYWRIGHT_MCP_CONFIG: '' }),
    nodeSpec('dbhub', npm('core', '@bytebase', 'dbhub', 'dist', 'index.js'), ['--transport', 'stdio'], { DSN: dbDsn }),
    nodeSpec('simple-files-vectorstore', npm('vectorstore', '@lishenxydlgzs', 'simple-files-vectorstore', 'build', 'index.js'), [], { WATCH_CONFIG_FILE: watchConfig, WATCH_DIRECTORIES: '' }, writingMissing),
    pythonSpec('markitdown', 'markitdown', 'markitdown-mcp'),
    pythonSpec('obsidian', 'obsidian', 'mcp-obsidian', [], { OBSIDIAN_API_KEY: secrets.obsidianApiKey, OBSIDIAN_PROTOCOL: 'https', OBSIDIAN_HOST: settings.obsidianHost, OBSIDIAN_PORT: String(settings.obsidianPort) }, obsidianMissing),
  ];
  specs.find((spec) => spec.id === 'dbhub').cwd = path.join(base, 'data');
  for (const spec of specs) spec.env = { ...commonEnv, ...spec.env };
  if (specs.map((s) => s.id).join(',') !== MANIFEST.servers.join(',')) throw new Error('Server manifest does not match runtime definitions.');
  return specs;
}

async function serve() {
  const { settings, secrets } = loadConfig();
  const controlKey = process.env.MCPKIT_CONTROL_KEY;
  const instanceId = process.env.MCPKIT_INSTANCE_ID;
  if (!controlKey || !instanceId) throw new Error('Use run-local.ps1 start to launch the gateway.');
  const specs = buildServerSpecs(settings, secrets);
  for (const spec of specs) fs.mkdirSync(spec.cwd, { recursive: true, mode: 0o700 });
  writeJson(path.join(RUNTIME, 'vector-watch.json'), { watchList: [settings.writingDir] });
  const proxyPath = path.join(RUNTIME, 'npm', 'core', 'node_modules', 'mcp-proxy', 'dist', 'bin', 'mcp-proxy.mjs');
  const gateway = await startGateway({ settings, gatewayKey: secrets.gatewayApiKey, controlKey, instanceId, specs, proxyPath, logDir: LOGS });
  const cleanup = async () => {
    await gateway.close();
    try { if (readJson(STATE_FILE).instanceId === instanceId) fs.unlinkSync(STATE_FILE); } catch { /* state may already be gone */ }
  };
  // The stop handler closes the listener; clean the state when it finishes.
  gateway.server.once('close', () => { void cleanup(); });
  for (const signal of ['SIGINT', 'SIGTERM', ...(process.platform === 'win32' ? ['SIGBREAK'] : [])]) process.once(signal, () => { void cleanup(); });
  console.log(`Gateway started (${instanceId}).`);
}

// PowerShell owns configuration, lifecycle and registration. This process is
// only the long-lived MCP transport and child-server supervisor.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== 'serve') {
    console.error('Use run-local.ps1 to manage the gateway.');
    process.exitCode = 1;
  } else {
    serve().catch((error) => { console.error(`ERROR: ${error.message}`); process.exitCode = 1; });
  }
}
