// Run the real PowerShell installer on a POSIX host using synthetic dependencies.
// This checks orchestration/preservation, not native Windows installs or ACLs.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { prepareWindowsFixture } from './fixtures/windows-test-helpers.mjs';

const ps = process.env.MCP_POWERSHELL || 'pwsh';
const available = spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' }).status === 0;
const nativePs = process.env.MCP_POWERSHELL || (process.platform === 'win32' ? 'powershell' : 'pwsh');
const nativePsAvailable = spawnSync(nativePs, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0'], { encoding: 'utf8' }).status === 0;
const proxy = process.env.MCP_PROXY_CLI;
const skip = (process.platform === 'win32' && 'synthetic POSIX tools') || (!available && 'set MCP_POWERSHELL') || (!proxy && 'set MCP_PROXY_CLI');
const fixture = fileURLToPath(new URL('./fixtures/fake-stdio-mcp.cjs', import.meta.url));
const uvFixture = fileURLToPath(new URL('./fixtures/fake-uv.sh', import.meta.url));
const driver = fileURLToPath(new URL('./fixtures/installer-driver.ps1', import.meta.url));
const windowsDir = fileURLToPath(new URL('../windows/', import.meta.url));
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const writeJson = (file, data) => fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
const makeFile = (file, content, mode = 0o644) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, content, { mode }); };
function execute(env, file, ...args) {
  const result = spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', file, ...args], { env, encoding: 'utf8', timeout: 90000 });
  if (result.error) throw result.error;
  return result;
}
function success(result) { assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`); }

test('uses only the new native Windows LOCAL installer filename', () => {
  assert.equal(fs.existsSync(path.join(windowsDir, 'install-local-server.ps1')), true);
  assert.equal(fs.existsSync(path.join(windowsDir, 'install-local.ps1')), false);
});

test('forwards the LOCAL gateway port to run-local as a named parameter', () => {
  const source = fs.readFileSync(path.join(windowsDir, 'install-local-server.ps1'), 'utf8');
  assert.match(source, /\[hashtable\]\$NamedArguments/);
  assert.match(source, /-Command \$Command -Directory \$BaseDir @NamedArguments/);
  assert.match(source, /Invoke-Runner 'init' @\{\s*GatewayPort = \$GatewayPort\s*\}/);
});

test('run-local-servers binds its arguments to run-local by name', {
  skip: (process.platform !== 'win32' && 'Windows PowerShell wrapper') || (!nativePsAvailable && 'PowerShell is unavailable'),
}, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit wrapper '));
  const base = path.join(root, 'local');
  fs.mkdirSync(path.join(base, 'config', 'private'), { recursive: true });
  fs.writeFileSync(path.join(base, 'config', 'private', 'independent-windows-kit.json'), `${JSON.stringify({ version: 1, kind: 'windows-local', base })}\n`);
  for (const file of ['run-local-servers.ps1', 'independent-common.ps1', 'local-common.ps1']) {
    fs.copyFileSync(path.join(windowsDir, file), path.join(root, file));
  }
  // Mirror run-local.ps1's parameter order: an array splat would bind the
  // literal '-Directory' to Server and the path to the integer GatewayPort.
  fs.writeFileSync(path.join(root, 'run-local.ps1'), [
    "param([string]$Command = 'gateway-start', [string]$Server = '', [int]$GatewayPort = 13001, [string]$Directory = '')",
    "@($Command, $Directory, $Server) | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'received.txt') -Encoding UTF8",
    'exit 7',
    '',
  ].join('\n'));
  const result = spawnSync(nativePs, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', path.join(root, 'run-local-servers.ps1'), 'logs', base, 'filesystem'], { encoding: 'utf8' });
  assert.equal(result.status, 7, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  const received = fs.readFileSync(path.join(root, 'received.txt'), 'utf8').replace(/\r/g, '').trim().split('\n');
  assert.deepEqual(received, ['logs', base, 'filesystem']);
});

test('the private-directory helper applies a protected DACL on every PowerShell engine', {
  skip: (process.platform !== 'win32' && 'Windows ACLs') || (!nativePsAvailable && 'PowerShell is unavailable'),
}, () => {
  // Set-Acl also writes the descriptor's other sections, which some hosts
  // reject without SeSecurityPrivilege and abort the first install step.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit acl '));
  const helper = path.join(root, 'local-common.ps1');
  const probe = path.join(root, 'probe.ps1');
  fs.copyFileSync(path.join(windowsDir, 'local-common.ps1'), helper);
  fs.writeFileSync(probe, [
    'param([string]$Helper, [string]$Target)',
    "$ErrorActionPreference = 'Stop'",
    '. $Helper',
    'Protect-PrivateDirectory $Target',
    '(Get-Acl -LiteralPath $Target).Access.Count',
    '',
  ].join('\n'));
  const engines = [nativePs];
  if (available && ps !== nativePs) engines.push(ps);
  for (const engine of engines) {
    const target = path.join(root, `private-${path.basename(engine)}`);
    // Windows PowerShell 5.1 fails to load its own modules when it inherits a
    // PowerShell 7 module path, so let that engine derive its own.
    const fiveOne = path.basename(engine).toLowerCase().startsWith('powershell');
    const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !(fiveOne && name.toLowerCase() === 'psmodulepath')));
    const result = spawnSync(engine, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', probe, helper, target], { env, encoding: 'utf8', timeout: 60000 });
    assert.equal(result.status, 0, `${engine} failed:\n${result.stdout}\n${result.stderr}`);
    assert.equal(result.stdout.trim(), '3', `${engine} did not leave exactly three usable access rules`);
  }
});

test('wsl-keepalive refuses conflicting modes and never starts anything by accident', {
  skip: (!available && 'set MCP_POWERSHELL'),
}, () => {
  const script = path.join(windowsDir, 'wsl-keepalive.ps1');
  const conflicting = spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', script, '-Distribution', 'NoSuchDistro', '-Ensure', '-Hold'], { encoding: 'utf8', timeout: 60000 });
  assert.notEqual(conflicting.status, 0);
  assert.match(`${conflicting.stdout}${conflicting.stderr}`, /Choose either -Ensure or -Hold/);
});

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}
function installSyntheticNode(base) {
  const r = path.join(base, 'runtime');
  const node = path.join(r, 'node/node_modules/node/bin/node.exe');
  fs.mkdirSync(path.dirname(node), { recursive: true }); fs.symlinkSync(process.execPath, node);
  makeFile(path.join(r, 'node/node_modules/npm/bin/npm-cli.js'), `const path = require('path');\nconst expected = path.join(process.env.MCP_TEST_ROOT, 'python-3.12');\nif (process.env.npm_config_python !== expected || process.env.NODE_GYP_FORCE_PYTHON !== expected) process.exit(12);\nconsole.log('synthetic npm install');\n`);
  for (const entry of [
    'npm/core/node_modules/@wonderwhy-er/desktop-commander/dist/index.js',
    'npm/core/node_modules/@j0hanz/filesystem-mcp/dist/index.js',
    'npm/core/node_modules/@colbymchenry/codegraph/npm-shim.js',
    'npm/codebase/node_modules/codebase-memory-mcp/bin.js',
    'npm/core/node_modules/@playwright/mcp/cli.js',
    'npm/core/node_modules/@bytebase/dbhub/dist/index.js',
    'npm/vectorstore/node_modules/@lishenxydlgzs/simple-files-vectorstore/build/index.js',
  ]) makeFile(path.join(r, entry), fs.readFileSync(fixture, 'utf8'));
  const dest = path.join(r, 'npm/core/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs');
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.symlinkSync(proxy, dest);
}

function prepareSyntheticNodeBootstrap(base, root, bin, mode) {
  // Leave the MCP fixtures in place, but make the actual installer bootstrap
  // its isolated node/npm. Exercise both the standard npm CLI and shim fallback.
  installSyntheticNode(base);
  const nodeDir = path.join(base, 'runtime/node');
  const template = fs.readFileSync(path.join(nodeDir, 'node_modules/npm/bin/npm-cli.js'));
  makeFile(path.join(root, 'isolated-npm-cli.js'), template);
  fs.rmSync(nodeDir, { recursive: true, force: true });
  fs.symlinkSync(process.execPath, path.join(bin, 'node.exe'));
  const bootstrap = `
const fs = require('fs'), path = require('path');
const args = process.argv.slice(2), prefix = args[2];
if (args[0] !== 'install' || args[1] !== '--prefix' || prefix !== path.join(process.env.MCP_LOCAL_DIR, 'runtime', 'node') ||
    !args.some(x => x.startsWith('node@')) || !args.some(x => x.startsWith('npm@'))) process.exit(13);
const node = path.join(prefix, 'node_modules/node/bin/node.exe');
const npm = path.join(prefix, 'node_modules/npm/bin/npm-cli.js');
fs.mkdirSync(path.dirname(node), { recursive: true }); fs.symlinkSync(process.execPath, node);
fs.mkdirSync(path.dirname(npm), { recursive: true }); fs.copyFileSync(path.join(process.env.MCP_TEST_ROOT, 'isolated-npm-cli.js'), npm);
fs.appendFileSync(path.join(process.env.MCP_TEST_ROOT, 'node-bootstrap.log'), '${mode}\\n');
`;
  makeFile(path.join(root, 'bootstrap-npm.js'), bootstrap);
  if (mode === 'direct') {
    makeFile(path.join(bin, 'node_modules/npm/bin/npm-cli.js'), bootstrap);
    makeFile(path.join(bin, 'npm.cmd'), '#!/bin/sh\necho unexpected npm.cmd >&2\nexit 14\n', 0o755);
  } else {
    makeFile(path.join(bin, 'npm.cmd'), '#!/bin/sh\nexec "$MCP_TEST_NODE" "$MCP_TEST_ROOT/bootstrap-npm.js" "$@"\n', 0o755);
  }
}

test('PowerShell installer preserves settings, reports an incomplete venv, and succeeds on retry', { skip, timeout: 180000 }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-установка & '));
  const base = path.join(root, 'Профиль с пробелами');
  const bin = path.join(root, 'fake tools');
  const programs = path.join(root, 'program files x86');
  const home = path.join(root, 'home');
  const projects = path.join(root, 'existing projects');
  fs.mkdirSync(home); fs.mkdirSync(projects); fs.mkdirSync(bin);
  const setup = prepareWindowsFixture(root, bin);
  const { runner, installer } = setup;
  fs.copyFileSync(uvFixture, path.join(bin, 'uv.exe')); fs.chmodSync(path.join(bin, 'uv.exe'), 0o755);
  makeFile(path.join(programs, 'Microsoft Visual Studio/Installer/vswhere.exe'), '#!/bin/sh\necho fake-build-tools\n', 0o755);
  makeFile(path.join(root, 'python-3.12'), '#!/bin/sh\nexit 0\n', 0o755);
  makeFile(path.join(root, 'python-3.14'), '#!/bin/sh\nexit 0\n', 0o755);
  const oldEnv = `PROJECTS_DIR="${projects}"\nOBSIDIAN_API_KEY=existing-secret\n`;
  const oldJson = '{"mcpServers":{"custom":{"command":"keep"}}}\n';
  makeFile(path.join(base, 'config/.env'), oldEnv);
  makeFile(path.join(base, 'config/mcp-local.json'), oldJson);
  const env = { ...process.env, ...setup.env, OS: 'Windows_NT', PROCESSOR_ARCHITECTURE: 'AMD64', MCP_LOCAL_DIR: base,
    MCP_TEST_ROOT: root, MCP_TEST_NODE: process.execPath, MCP_TEST_FIXTURE: fixture, USERPROFILE: home, HOME: home, LOCALAPPDATA: root,
    ProgramFiles: root, 'ProgramFiles(x86)': programs, TEMP: root, npm_config_python: 'preserve-my-python', NODE_GYP_FORCE_PYTHON: 'preserve-forced-python',
    PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH}` };
  try {
    success(execute(env, runner, 'init'));
    const settingsFile = path.join(base, 'config/local-settings.json');
    const secretsFile = path.join(base, 'config/private/secrets.json');
    const settings = readJson(settingsFile); settings.port = await freePort(); writeJson(settingsFile, settings);
    const secrets = readJson(secretsFile);
    assert.equal(settings.projectsDir, path.join(base, 'data/projects'));
    assert.equal(secrets.obsidianApiKey, '');
    prepareSyntheticNodeBootstrap(base, root, bin, 'direct');
    const first = execute(env, driver, installer); success(first);
    assert.match(first.stdout, /Native LOCAL servers installed\. MetaMCP was not installed or started\./);
    assert.equal(fs.existsSync(setup.env.MCP_TEST_DOCKER_TRACE), false, 'default LOCAL installation must not invoke Docker');
    assert.equal(fs.readFileSync(path.join(root, 'node-bootstrap.log'), 'utf8'), 'direct\n');
    const vectorPackage = readJson(path.join(base, 'runtime/npm/vectorstore/package.json'));
    assert.equal(vectorPackage.overrides['@xenova/transformers'].sharp, '0.33.5');
    assert.deepEqual(readJson(secretsFile), secrets);
    assert.deepEqual(readJson(settingsFile), settings);
    assert.equal(fs.readFileSync(path.join(base, 'config/.env'), 'utf8'), oldEnv);
    assert.equal(fs.readFileSync(path.join(base, 'config/mcp-local.json'), 'utf8'), oldJson);
    const stateFile = path.join(base, 'config/private/gateway-state.json');
    const oldPid = readJson(stateFile).pid;
    const reinstall = execute(env, driver, installer); success(reinstall);
    assert.equal(fs.readFileSync(path.join(root, 'node-bootstrap.log'), 'utf8'), 'direct\n', 'reinstall must reuse the isolated Node runtime');
    assert.notEqual(readJson(stateFile).pid, oldPid, 'a running kit gateway must be stopped before package updates');
    assert.deepEqual(readJson(settingsFile), settings);
    assert.deepEqual(readJson(secretsFile), secrets);
    success(execute(env, runner, 'stop'));

    const git = path.join(base, 'runtime/python/git');
    fs.rmSync(git, { recursive: true }); fs.mkdirSync(git); makeFile(path.join(git, 'keep.txt'), 'user data');
    const incomplete = execute(env, driver, installer);
    assert.equal(incomplete.status, 1, `incomplete installation should fail:\n${incomplete.stdout}\n${incomplete.stderr}`);
    assert.match(incomplete.stdout, /Existing environment has no Scripts/);
    assert.equal(fs.readFileSync(path.join(git, 'keep.txt'), 'utf8'), 'user data');
    assert.deepEqual(readJson(secretsFile), secrets);

    fs.rmSync(git, { recursive: true }); // test fixture only: user must back up/remove manually
    const retry = execute(env, driver, installer); success(retry);
    assert.match(retry.stdout, /Native LOCAL servers installed\. MetaMCP was not installed or started\./);
    assert.equal(fs.existsSync(setup.env.MCP_TEST_DOCKER_TRACE), false, 'retry must not invoke Docker by default');
    assert.deepEqual(readJson(settingsFile), settings);
    assert.deepEqual(readJson(secretsFile), secrets);
    success(execute(env, runner, 'stop'));
  } finally {
    try { execute(env, runner, 'stop'); } catch { /* best effort */ }
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('PowerShell bootstraps a hash-verified uv without replacing an older uv', { skip, timeout: 120000 }, async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-uv-установка '));
  const base = path.join(root, 'Профиль с пробелами');
  const repoWindows = path.join(root, 'Репозиторий с пробелами/windows');
  const bin = path.join(root, 'fake tools');
  const home = path.join(root, 'home');
  const programs = path.join(root, 'program files x86');
  fs.mkdirSync(home); fs.mkdirSync(bin);
  const setup = prepareWindowsFixture(root, bin, repoWindows);
  const archiveRoot = path.join(root, 'wheel');
  const fakeExe = path.join(archiveRoot, 'uv-0.13.8.data/scripts/uv.exe');
  makeFile(fakeExe, fs.readFileSync(uvFixture), 0o755);
  const wheel = path.join(root, 'uv-wheel.zip');
  const zip = spawnSync('python3', ['-m', 'zipfile', '-c', wheel, 'uv-0.13.8.data'], { cwd: archiveRoot, stdio: 'ignore' });
  if (zip.error?.code === 'ENOENT') { fs.rmSync(root, { recursive: true, force: true }); t.skip('python3 is required'); return; }
  assert.equal(zip.status, 0, 'could not create a synthetic wheel');
  const oldUv = path.join(bin, 'uv.exe');
  makeFile(oldUv, fs.readFileSync(uvFixture, 'utf8').replace("printf 'uv 0.13.8\\n'", "printf 'uv 0.8.0\\n'"), 0o755);
  const oldHash = hash(oldUv);
  makeFile(path.join(programs, 'Microsoft Visual Studio/Installer/vswhere.exe'), '#!/bin/sh\necho fake-build-tools\n', 0o755);
  makeFile(path.join(root, 'python-3.12'), '#!/bin/sh\nexit 0\n', 0o755);
  makeFile(path.join(root, 'python-3.14'), '#!/bin/sh\nexit 0\n', 0o755);
  const manifestFile = path.join(repoWindows, 'manifest.json');
  const manifest = readJson(manifestFile);
  manifest.uvBootstrap = { version: '0.13.8', wheelUrl: 'https://example.invalid/test-only', wheelSha256: '0'.repeat(64), exeSha256: hash(fakeExe) };
  writeJson(manifestFile, manifest);
  const localRunner = path.join(repoWindows, 'run-local.ps1');
  const localInstaller = path.join(repoWindows, 'install-local-server.ps1');
  const env = { ...process.env, ...setup.env, OS: 'Windows_NT', PROCESSOR_ARCHITECTURE: 'AMD64', MCP_LOCAL_DIR: base,
    MCP_TEST_ROOT: root, MCP_TEST_NODE: process.execPath, MCP_TEST_FIXTURE: fixture, MCP_TEST_UV_WHEEL: wheel, USERPROFILE: home, HOME: home,
    LOCALAPPDATA: root, ProgramFiles: root, 'ProgramFiles(x86)': programs, TEMP: root, npm_config_python: 'keep-original', NODE_GYP_FORCE_PYTHON: 'keep-forced-python',
    PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH}` };
  try {
    success(execute(env, localRunner, 'init'));
    const settingsFile = path.join(base, 'config/local-settings.json');
    const settings = readJson(settingsFile); settings.port = await freePort(); writeJson(settingsFile, settings);
    prepareSyntheticNodeBootstrap(base, root, bin, 'shim');
    const badHash = execute(env, driver, localInstaller);
    assert.equal(badHash.status, 1, badHash.stdout);
    assert.match(badHash.stdout, /did not match its pinned SHA-256/);
    assert.equal(fs.readFileSync(path.join(root, 'node-bootstrap.log'), 'utf8'), 'shim\n');
    assert.equal(hash(oldUv), oldHash, 'a failed bootstrap must not change the pre-existing uv');
    assert.equal(fs.existsSync(path.join(base, 'runtime/uv/0.13.8/uv.exe')), false);

    manifest.uvBootstrap.wheelSha256 = hash(wheel); manifest.uvBootstrap.exeSha256 = '0'.repeat(64); writeJson(manifestFile, manifest);
    const badExecutable = execute(env, driver, localInstaller);
    assert.equal(badExecutable.status, 1, badExecutable.stdout);
    assert.match(badExecutable.stdout, /did not contain the expected executable/);
    assert.equal(fs.existsSync(path.join(base, 'runtime/uv/0.13.8/uv.exe')), false);
    assert.equal(hash(oldUv), oldHash);

    manifest.uvBootstrap.exeSha256 = hash(fakeExe); writeJson(manifestFile, manifest);
    const installed = execute(env, driver, localInstaller); success(installed);
    assert.match(installed.stdout, /Installation completed/);
    assert.equal(fs.readFileSync(path.join(root, 'node-bootstrap.log'), 'utf8'), 'shim\n', 'retry must reuse the isolated Node runtime');
    assert.equal(hash(oldUv), oldHash, 'the pre-existing uv must stay unchanged');
    assert.equal(hash(path.join(base, 'runtime/uv/0.13.8/uv.exe')), hash(fakeExe));
    success(execute(env, localRunner, 'stop'));
  } finally {
    try { execute(env, localRunner, 'stop'); } catch { /* best effort */ }
    fs.rmSync(root, { recursive: true, force: true });
  }
});
