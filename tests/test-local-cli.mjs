// End-to-end PowerShell lifecycle and SSH-boundary tests with synthetic MCP servers.
// On Linux/macOS: MCP_POWERSHELL=/path/to/pwsh MCP_PROXY_CLI=/path/to/mcp-proxy.mjs node --test tests/test-local-cli.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const runner = fileURLToPath(new URL('../windows/run-local.ps1', import.meta.url));
const fixture = fileURLToPath(new URL('./fixtures/fake-stdio-mcp.cjs', import.meta.url));
const proxy = process.env.MCP_PROXY_CLI;
const powershell = process.env.MCP_POWERSHELL || 'pwsh';
const psAvailable = spawnSync(powershell, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' }).status === 0;
const unsupported = (process.platform === 'win32' && 'synthetic POSIX executables; Windows requires real installed packages') || (!psAvailable && 'set MCP_POWERSHELL to PowerShell Core');
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const writeJson = (f, data) => fs.writeFileSync(f, `${JSON.stringify(data, null, 2)}\n`);
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function freePort() {
  const s = net.createServer();
  await new Promise((resolve) => s.listen(0, '127.0.0.1', resolve));
  const port = s.address().port;
  await new Promise((resolve) => s.close(resolve));
  return port;
}
function invoke(env, ...args) {
  // The scripts still target Windows. OS only permits these protocol tests to
  // exercise PowerShell on Linux/macOS with synthetic POSIX executables.
  const result = spawnSync(powershell, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', runner, ...args], { env: { ...env, OS: 'Windows_NT' }, encoding: 'utf8', timeout: 50000 });
  if (result.error) throw result.error;
  return result;
}
function assertSuccess(result) { assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`); }
function installFakes(base) {
  const r = path.join(base, 'runtime');
  const node = path.join(r, 'node/node_modules/node/bin/node.exe');
  fs.mkdirSync(path.dirname(node), { recursive: true });
  fs.symlinkSync(process.execPath, node);
  const entries = [
    'npm/core/node_modules/@wonderwhy-er/desktop-commander/dist/index.js',
    'npm/core/node_modules/@j0hanz/filesystem-mcp/dist/index.js',
    'npm/core/node_modules/@colbymchenry/codegraph/npm-shim.js',
    'npm/codebase/node_modules/codebase-memory-mcp/bin.js',
    'npm/core/node_modules/@playwright/mcp/cli.js',
    'npm/core/node_modules/@bytebase/dbhub/dist/index.js',
    'npm/vectorstore/node_modules/@lishenxydlgzs/simple-files-vectorstore/build/index.js',
  ];
  for (const [name, exe] of [['everything-search', 'mcp-server-everything-search'], ['git', 'mcp-server-git'], ['serena', 'serena'], ['markitdown', 'markitdown-mcp'], ['obsidian', 'mcp-obsidian']]) entries.push(`python/${name}/bin/${exe}`);
  for (const name of entries) {
    const dest = path.join(r, name);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, `#!/usr/bin/env node\n${fs.readFileSync(fixture, 'utf8')}`, { mode: 0o755 });
  }
  const dest = path.join(r, 'npm/core/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs');
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.symlinkSync(proxy, dest);
}

test('preserves legacy files, manages the gateway, and never kills a port occupant', { skip: unsupported || (!proxy && 'set MCP_PROXY_CLI to an installed mcp-proxy CLI'), timeout: 120000 }, async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp kit '));
  const base = path.join(tmp, 'Профиль с пробелами');
  const config = path.join(base, 'config');
  const projects = path.join(tmp, 'существующие проекты');
  const writing = path.join(tmp, 'заметки, все');
  fs.mkdirSync(config, { recursive: true }); fs.mkdirSync(projects); fs.mkdirSync(writing);
  const oldEnv = `\uFEFF# user settings\r\nPROJECTS_DIR="${projects}"\r\nWRITING_DIR='${writing}'\r\nOTHER=keep\r\n`;
  const oldJson = '{"mcpServers":{"my-own-server":{"command":"keep"}}}\n';
  fs.writeFileSync(path.join(config, '.env'), oldEnv);
  fs.writeFileSync(path.join(config, 'mcp-local.json'), oldJson);
  const env = { ...process.env, MCP_LOCAL_DIR: base, HOME: path.join(tmp, 'home'), USERPROFILE: path.join(tmp, 'home'), MCPKIT_TEST_PID_FILES: '1' };
  fs.mkdirSync(env.HOME);
  try {
    assertSuccess(invoke(env, 'init'));
    const settingsFile = path.join(config, 'local-settings.json');
    const secretsFile = path.join(config, 'private/secrets.json');
    const stateFile = path.join(config, 'private/gateway-state.json');
    const settings = readJson(settingsFile);
    assert.equal(settings.projectsDir, projects); assert.equal(settings.writingDir, writing);
    const secrets = readJson(secretsFile);
    settings.port = await freePort();
    writeJson(settingsFile, settings);
    assertSuccess(invoke(env, 'init'));
    assert.deepEqual(readJson(secretsFile), secrets, 'reinitialization must not rotate secrets');
    assert.deepEqual(readJson(settingsFile), settings, 'reinitialization must not overwrite settings');
    assert.equal(fs.readFileSync(path.join(config, '.env'), 'utf8'), oldEnv);
    assert.equal(fs.readFileSync(path.join(config, 'mcp-local.json'), 'utf8'), oldJson);
    installFakes(base);
    const started = invoke(env, 'start'); assertSuccess(started);
    assert.match(started.stdout, /Ready: 11; waiting for configuration: 2; starting: 0; errors: 0/);
    assert.equal((await fetch(`http://127.0.0.1:${settings.port}/servers/git/mcp`)).status, 401);
    const state = readJson(stateFile);
    assertSuccess(invoke(env, 'start'));
    assert.equal(readJson(stateFile).pid, state.pid, 'second start must not replace a running gateway');
    assertSuccess(invoke(env, 'status'));

    const git = path.join(base, 'runtime/python/git/bin/mcp-server-git');
    fs.unlinkSync(git);
    const missing = invoke(env, 'restart');
    assert.notEqual(missing.status, 0, 'missing package must make restart fail');
    assert.match(missing.stdout, /error\s+git/);
    assert.notEqual(invoke(env, 'start').status, 0, 'an already-running gateway with an error is not a successful start');
    fs.writeFileSync(git, `#!/usr/bin/env node\n${fs.readFileSync(fixture, 'utf8')}`, { mode: 0o755 });
    assertSuccess(invoke(env, 'restart'));
    const pids = fs.readdirSync(path.join(base, 'runtime/work'), { withFileTypes: true })
      .filter((d) => d.isDirectory()).map((d) => path.join(base, 'runtime/work', d.name, 'fixture.pid'))
      .filter(fs.existsSync).map((f) => Number(fs.readFileSync(f, 'utf8')));
    assert.ok(pids.length >= 10);
    assertSuccess(invoke(env, 'stop'));
    await delay(300);
    for (const pid of pids) {
      let alive = false;
      try { process.kill(pid, 0); alive = true; } catch { /* exited */ }
      assert.equal(alive, false, `fixture PID ${pid} survived shutdown`);
    }
    assertSuccess(invoke(env, 'stop'));
    assert.equal(fs.existsSync(stateFile), false);
    assert.deepEqual(readJson(secretsFile), secrets);
    assert.equal(fs.readFileSync(path.join(config, '.env'), 'utf8'), oldEnv);
    assert.equal(fs.readFileSync(path.join(config, 'mcp-local.json'), 'utf8'), oldJson);

    const occupied = net.createServer();
    await new Promise((resolve) => occupied.listen(settings.port, '127.0.0.1', resolve));
    try {
      const collision = invoke(env, 'start');
      assert.notEqual(collision.status, 0, 'occupied port should make start fail');
      assert.equal(occupied.listening, true, 'an unrelated process must not be killed');
    } finally { await new Promise((resolve) => occupied.close(resolve)); }
  } finally {
    try { invoke(env, 'stop'); } catch { /* best-effort cleanup */ }
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('PowerShell controls a TLS gateway using the pinned certificate', { skip: unsupported || (!proxy && 'set MCP_PROXY_CLI to an installed mcp-proxy CLI'), timeout: 120000 }, async (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-tls-runner-'));
  const base = path.join(tmp, 'Профиль с пробелами');
  const env = { ...process.env, MCP_LOCAL_DIR: base, HOME: tmp };
  const cert = path.join(tmp, 'certificate.pem'); const key = path.join(tmp, 'private-key.pem');
  const openssl = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost', '-keyout', key, '-out', cert, '-days', '1'], { stdio: 'ignore' });
  if (openssl.error?.code === 'ENOENT') { fs.rmSync(tmp, { recursive: true, force: true }); t.skip('openssl is not installed'); return; }
  assert.equal(openssl.status, 0, 'could not create a test certificate');
  try {
    assertSuccess(invoke(env, 'init'));
    installFakes(base);
    const settingsFile = path.join(base, 'config/local-settings.json');
    const stateFile = path.join(base, 'config/private/gateway-state.json');
    const settings = readJson(settingsFile);
    Object.assign(settings, { port: await freePort(), tlsCertFile: cert, tlsKeyFile: key });
    writeJson(settingsFile, settings);
    assertSuccess(invoke(env, 'start'));
    assertSuccess(invoke(env, 'status'));
    const state = readJson(stateFile);
    assert.ok(state.certPin.length > 100, 'state should pin the actual certificate');
    writeJson(stateFile, { ...state, certPin: 'not-the-certificate' });
    const wrongPin = invoke(env, 'status');
    assert.notEqual(wrongPin.status, 0, 'a different certificate must be rejected');
    assert.match(wrongPin.stdout, /still alive but not responding/);
    assert.doesNotThrow(() => process.kill(state.pid, 0), 'failed pin validation must not kill the gateway');
    writeJson(stateFile, state);
    assertSuccess(invoke(env, 'stop'));
  } finally {
    try { invoke(env, 'stop'); } catch { /* best-effort cleanup */ }
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('first initialization imports literal legacy values but ignores the sample database', { skip: unsupported }, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit legacy '));
  const base = path.join(tmp, 'base'); const config = path.join(base, 'config');
  fs.mkdirSync(config, { recursive: true });
  const env = { ...process.env, MCP_LOCAL_DIR: base, HOME: tmp };
  const old = 'DBHUB_DSN=postgres://user:pass@localhost:5432/devdb\nOBSIDIAN_API_KEY=legacy-secret-value\n';
  fs.writeFileSync(path.join(config, '.env'), old);
  try {
    const result = invoke(env, 'init'); assertSuccess(result);
    assert.doesNotMatch(result.stdout, /legacy-secret-value/);
    const secrets = readJson(path.join(config, 'private/secrets.json'));
    assert.equal(secrets.obsidianApiKey, 'legacy-secret-value');
    assert.equal(secrets.dbhubDsn, '');
    assert.equal(fs.readFileSync(path.join(config, '.env'), 'utf8'), old);
    fs.writeFileSync(path.join(config, '.env'), 'DBHUB_DSN=postgres://real:secret@database.example/db\n');
    assertSuccess(invoke(env, 'init'));
    assert.deepEqual(readJson(path.join(config, 'private/secrets.json')), secrets, 'subsequent init must not override private settings');
    const second = path.join(tmp, 'second'); fs.mkdirSync(path.join(second, 'config'), { recursive: true });
    fs.writeFileSync(path.join(second, 'config/.env'), 'DBHUB_DSN="postgres://real:secret@database.example/db"\n');
    assertSuccess(invoke({ ...env, MCP_LOCAL_DIR: second }, 'init'));
    assert.equal(readJson(path.join(second, 'config/private/secrets.json')).dbhubDsn, 'postgres://real:secret@database.example/db');
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

test('SSH registration sends the secret on stdin, never in arguments', { skip: unsupported }, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit ssh '));
  const base = path.join(tmp, 'base');
  const fakebin = path.join(tmp, 'bin');
  fs.mkdirSync(fakebin); fs.mkdirSync(path.join(tmp, 'home'));
  const env = { ...process.env, MCP_LOCAL_DIR: base, HOME: path.join(tmp, 'home'), PATH: `${fakebin}${path.delimiter}${process.env.PATH}`, CAPTURE: tmp };
  const fakeSsh = `#!${process.execPath}\nconst fs=require('fs'),path=require('path');let data='';process.stdin.setEncoding('utf8');process.stdin.on('data',s=>data+=s);process.stdin.on('end',()=>{fs.writeFileSync(path.join(process.env.CAPTURE,'args.json'),JSON.stringify(process.argv.slice(2)));fs.writeFileSync(path.join(process.env.CAPTURE,'stdin.json'),data);});\n`;
  fs.writeFileSync(path.join(fakebin, 'ssh'), fakeSsh, { mode: 0o755 });
  try {
    assertSuccess(invoke(env, 'init'));
    const settingsFile = path.join(base, 'config/local-settings.json');
    const secretsFile = path.join(base, 'config/private/secrets.json');
    const s = readJson(settingsFile);
    Object.assign(s, { advertiseBaseUrl: 'https://win.example.com', metamcpOwnerEmail: 'alice@example.com', linuxSshTarget: 'alice@linux.example.com', linuxKitDir: "/home/alice/проекты/it's \"kit\"" });
    writeJson(settingsFile, s);
    const key = readJson(secretsFile).gatewayApiKey;
    assertSuccess(invoke(env, 'register'));
    const args = readJson(path.join(tmp, 'args.json'));
    const body = readJson(path.join(tmp, 'stdin.json'));
    assert.equal(args[0], '--'); assert.equal(args[1], 'alice@linux.example.com');
    assert.equal(args[2], "bash '/home/alice/проекты/it'\\''s \"kit\"/linux/register-local.sh' --stdin");
    assert.doesNotMatch(JSON.stringify(args), new RegExp(key));
    assert.equal(body.gatewayKey, key);
    assert.equal(body.ownerEmail, 'alice@example.com');
    assertSuccess(invoke(env, 'seed'));
    assert.match(readJson(path.join(tmp, 'args.json'))[2], / --force$/);
    assertSuccess(invoke(env, 'export'));
    const exported = path.join(base, 'config/private/registration.json');
    assert.equal(readJson(exported).gatewayKey, key);
    const originalExport = fs.readFileSync(exported, 'utf8');
    for (const url of ['https://user:password@host/', 'https://host/path?token=x', 'http://192.168.1.20:13001']) {
      s.advertiseBaseUrl = url; writeJson(settingsFile, s);
      assert.notEqual(invoke(env, 'export').status, 0, `unsafe URL accepted: ${url}`);
      assert.equal(fs.readFileSync(exported, 'utf8'), originalExport, 'failed validation must not overwrite the existing bundle');
    }
    s.allowInsecureLan = true; writeJson(settingsFile, s);
    assertSuccess(invoke(env, 'export'));
    assert.equal(readJson(exported).baseUrl, 'http://192.168.1.20:13001');
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});
