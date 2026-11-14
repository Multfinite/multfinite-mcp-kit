#!/usr/bin/env node
// Linux lifecycle for the same authenticated native gateway used on Windows.
// Control uses a separate key and never kills a PID read from disk.
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [action, directory, extra] = process.argv.slice(2);
const base = path.resolve(directory || path.join(os.homedir(), 'mcp-kit', 'local'));
const config = path.join(base, 'config');
const priv = path.join(config, 'private');
const settingsFile = path.join(config, 'local-settings.json');
const secretsFile = path.join(priv, 'secrets.json');
const stateFile = path.join(priv, 'gateway-state.json');
const markerFile = path.join(priv, 'linux-kit.json');
const logs = path.join(base, 'logs');
const read = (file) => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const hex = (bytes = 32) => crypto.randomBytes(bytes).toString('hex');
function fail(message) { throw new Error(message); }
function create(file, value) { fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 }); }
function portNumber(value) {
  if (!/^\d{1,5}$/.test(String(value)) || Number(value) < 1 || Number(value) > 65535) fail('Port must be between 1 and 65535.');
  return Number(value);
}
function init() {
  if (fs.existsSync(base) && fs.lstatSync(base).isSymbolicLink()) fail('The installation directory itself must not be a symlink.');
  fs.mkdirSync(base, { recursive: true, mode: 0o700 });
  if (fs.existsSync(markerFile)) {
    const marker = read(markerFile);
    if (marker.version !== 1 || marker.base !== base || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(marker.hostId)) fail('Invalid or relocated Linux LOCAL state.');
    if (!fs.existsSync(settingsFile) || !fs.existsSync(secretsFile)) fail('LOCAL settings or secrets are missing. Restore them from backup.');
    console.log(`Existing LOCAL configuration preserved at ${base}.`);
    return;
  }
  if (fs.readdirSync(base).length) fail(`Directory is not empty and has no Linux LOCAL marker; it was not changed: ${base}`);
  const port = portNumber(extra || '13001');
  const host = os.hostname().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 20).replace(/-+$/, '') || 'linux';
  const hostId = `${host}-${hex(3)}`;
  for (const dir of [priv, logs, path.join(base, 'runtime'), path.join(base, 'data', 'projects'), path.join(base, 'data', 'writing')]) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  create(settingsFile, {
    version: 1, hostId, listenHost: '127.0.0.1', port, tlsCertFile: '', tlsKeyFile: '', allowInsecureLan: false,
    projectsDir: path.join(base, 'data', 'projects'), writingDir: path.join(base, 'data', 'writing'),
    everythingSdkPath: path.join(base, 'runtime', 'everything-sdk', 'Everything64.dll'), obsidianHost: '127.0.0.1', obsidianPort: 27124,
  });
  create(secretsFile, { gatewayApiKey: hex(), obsidianApiKey: '', dbhubDsn: '' });
  create(markerFile, { version: 1, base, hostId });
  console.log(`Created independent Linux LOCAL configuration: ${base}`);
}
function getConfig() {
  const marker = read(markerFile);
  const settings = read(settingsFile);
  const secrets = read(secretsFile);
  if (marker.version !== 1 || marker.base !== base || marker.hostId !== settings.hostId || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(marker.hostId) ||
      settings.version !== 1 || !/^[a-f0-9]{64}$/.test(secrets.gatewayApiKey || '')) fail('Invalid Linux LOCAL configuration; it was not changed.');
  portNumber(settings.port);
  return { settings, secrets };
}
function alive(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    // A terminated but unreaped child cannot serve requests. Do not signal it.
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const afterName = stat.slice(stat.lastIndexOf(')') + 2);
    return !afterName.startsWith('Z ');
  } catch (error) { return error.code === 'EPERM'; }
}
function removeMatching(id) {
  try { if (read(stateFile).instanceId === id) fs.unlinkSync(stateFile); } catch { /* already removed */ }
}
function control(state, method) {
  return new Promise((resolve, reject) => {
    const hostname = ['0.0.0.0', '::', '[::]'].includes(state.host) ? '127.0.0.1' : state.host;
    const opts = {
      host: hostname, port: state.port, path: `/_mcpkit/${method}`, method: method === 'stop' ? 'POST' : 'GET',
      headers: { 'X-Mcpkit-Control': state.controlKey }, timeout: 2500,
    };
    if (state.certPem) {
      opts.ca = state.certPem;
      opts.checkServerIdentity = (_host, cert) => cert.fingerprint256 === state.certFingerprint ? undefined : new Error('Gateway certificate does not match saved pin.');
    }
    const req = (state.certPem ? https : http).request(opts, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { data += chunk; if (data.length > 200000) req.destroy(); });
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          if (res.statusCode !== 200 || result.instanceId !== state.instanceId) fail('Unexpected gateway control response.');
          resolve(result);
        } catch (error) { reject(error); }
      });
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('Gateway control timed out.')));
    req.on('error', reject);
    req.end();
  });
}
async function current() {
  if (!fs.existsSync(stateFile)) return null;
  const state = read(stateFile);
  if (!Number.isSafeInteger(state.pid) || state.pid < 1 || !/^[a-f0-9]{32}$/.test(state.instanceId || '') ||
      !/^[a-f0-9]{64}$/.test(state.controlKey || '') || typeof state.host !== 'string') fail('Invalid gateway state; no process was touched.');
  portNumber(state.port);
  try { return { state, status: await control(state, 'status') }; }
  catch (error) {
    if (alive(state.pid)) fail(`Recorded PID ${state.pid} is alive but did not authenticate as the kit gateway. Nothing was killed; inspect ${stateFile}.`);
    removeMatching(state.instanceId);
    return null;
  }
}
function show(status) {
  if (!Array.isArray(status.servers)) fail('Invalid gateway status.');
  for (const item of status.servers) console.log(`${item.status.padEnd(9)} ${item.id}${item.detail ? `: ${item.detail}` : ''}`);
  console.log('Waiting means a server needs additional configuration; readiness only checks MCP initialize.');
}
function requireSettled(status) {
  show(status);
  if (status.servers.some((item) => item.status === 'error' || item.status === 'starting')) {
    fail('Some LOCAL servers failed or are still starting. The gateway remains running; inspect status and individual logs.');
  }
}
async function start() {
  if (Number(process.versions.node.split('.')[0]) < 24) fail('Node.js 24 or newer is required to run the LOCAL packages.');
  const { settings } = getConfig();
  const lockPath = path.join(priv, 'start.lock');
  let lock;
  try { lock = fs.openSync(lockPath, 'wx', 0o600); } catch { fail(`Another start may be running; inspect ${lockPath} before removing a stale lock.`); }
  try {
    const running = await current();
    if (running) { console.log('Gateway is already running.'); requireSettled(running.status); return; }
    const controlKey = hex();
    const instanceId = hex(16);
    const certPem = settings.tlsCertFile ? fs.readFileSync(settings.tlsCertFile, 'utf8') : '';
    const certFingerprint = certPem ? new crypto.X509Certificate(certPem).fingerprint256 : '';
    const state = { pid: 0, instanceId, controlKey, host: settings.listenHost, port: settings.port, certPem, certFingerprint };
    const stamp = `${Date.now()}-${hex(4)}`;
    const out = fs.openSync(path.join(logs, `gateway-${stamp}.out.log`), 'a', 0o600);
    const err = fs.openSync(path.join(logs, `gateway-${stamp}.err.log`), 'a', 0o600);
    let child;
    try {
      child = spawn(process.execPath, [path.join(root, 'windows', 'local-kit.mjs'), 'serve'], {
        cwd: base, detached: true, stdio: ['ignore', out, err],
        env: { ...process.env, MCP_LOCAL_DIR: base, MCPKIT_NATIVE_LINUX: '1', MCPKIT_CONTROL_KEY: controlKey, MCPKIT_INSTANCE_ID: instanceId,
          PLAYWRIGHT_BROWSERS_PATH: path.join(base, 'runtime', 'playwright-browsers') },
      });
    } finally { fs.closeSync(out); fs.closeSync(err); }
    if (!child.pid) fail('Could not start the native gateway; inspect gateway logs.');
    state.pid = child.pid;
    try { create(stateFile, state); } catch (error) { child.kill('SIGTERM'); throw error; }
    child.unref();
    let status;
    for (let i = 0; i < 100; i++) {
      try { status = await control(state, 'status'); break; }
      catch { if (!alive(child.pid)) break; await delay(200); }
    }
    if (!status) {
      if (!alive(child.pid)) removeMatching(instanceId);
      fail('Gateway did not start. Inspect gateway logs; no unrelated process was killed.');
    }
    // Match the Windows controller: allow slow servers time to initialize,
    // but do not report a successful installation if any remain in error.
    const deadline = Date.now() + 190000;
    while (Array.isArray(status.servers) && status.servers.some((item) => item.status === 'starting') && Date.now() < deadline) {
      await delay(750);
      status = await control(state, 'status');
    }
    console.log(`LOCAL gateway listening on ${settings.listenHost}:${settings.port}.`);
    requireSettled(status);
  } finally { fs.closeSync(lock); fs.unlinkSync(lockPath); }
}
async function stop() {
  // Serialize stop with start so a shutdown cannot remove state belonging to
  // a concurrently launched gateway. Never signal a PID read from disk.
  const lockPath = path.join(priv, 'start.lock');
  let lock;
  try { lock = fs.openSync(lockPath, 'wx', 0o600); } catch { fail(`Another lifecycle action may be running; inspect ${lockPath} before removing a stale lock.`); }
  try {
    const running = await current();
    if (!running) { console.log('LOCAL gateway is not running.'); return; }
    await control(running.state, 'stop');
    for (let i = 0; i < 80; i++) {
      if (!alive(running.state.pid)) { removeMatching(running.state.instanceId); console.log('LOCAL gateway stopped; data was kept.'); return; }
      await delay(250);
    }
    fail('Gateway shutdown was not confirmed. No PID was killed.');
  } finally { fs.closeSync(lock); fs.unlinkSync(lockPath); }
}
function logFiles(name) {
  const manifest = read(path.join(root, 'windows', 'manifest.json'));
  const ids = manifest.servers.map((id) => id === 'windows-mcp' ? 'linux-desktop' : id);
  if (name && name !== 'gateway' && !ids.includes(name)) fail('Unknown server log.');
  let files = [];
  if (!name || name === 'gateway') files = fs.readdirSync(logs).filter((f) => /^gateway-.*\.(?:out|err)\.log$/.test(f)).sort().slice(-2).map((f) => path.join(logs, f));
  if (name && name !== 'gateway') files.push(path.join(logs, `${name}.log`));
  if (!name) files.push(...ids.map((id) => path.join(logs, `${id}.log`)));
  for (const file of files) if (fs.existsSync(file)) console.log(`\n--- ${path.basename(file)} ---\n${fs.readFileSync(file, 'utf8').split('\n').slice(-100).join('\n')}`);
}
try {
  if (process.platform !== 'linux') fail('This controller is for Linux.');
  if (Number(process.versions.node.split('.')[0]) < 20) fail('Node.js 20 or newer is required.');
  if (action === 'init') init();
  else {
    getConfig();
    if (action === 'start') await start();
    else if (action === 'stop') await stop();
    else if (action === 'restart') { await stop(); await start(); }
    else if (action === 'status') { const running = await current(); if (!running) fail('LOCAL gateway is not running.'); requireSettled(running.status); }
    else if (action === 'logs') logFiles(extra || '');
    else fail('Usage: local-control.mjs {init|start|stop|restart|status|logs} DIRECTORY [PORT_OR_SERVER]');
  }
} catch (error) { console.error(`ERROR: ${error.message}`); process.exitCode = 1; }
