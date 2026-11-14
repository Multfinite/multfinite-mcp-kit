// Windows-local Docker Desktop orchestration with a real PowerShell runner,
// local Git clone, synthetic native MCPs and a mocked Docker boundary. The
// optional real Compose binary resolves YAML but does not run any containers.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { prepareDockerFixture } from './fixtures/docker-test-helpers.mjs';

const ps = process.env.MCP_POWERSHELL || 'pwsh';
const available = spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' }).status === 0;
const proxy = process.env.MCP_PROXY_CLI;
const skip = (process.platform === 'win32' && 'synthetic POSIX executables') || (!available && 'set MCP_POWERSHELL') || (!proxy && 'set MCP_PROXY_CLI');
const fixture = fileURLToPath(new URL('./fixtures/fake-stdio-mcp.cjs', import.meta.url));
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const writeJson = (f, data) => fs.writeFileSync(f, `${JSON.stringify(data, null, 2)}\n`);
const readEnv = (f) => Object.fromEntries(fs.readFileSync(f, 'utf8').split(/\r?\n/).filter((s) => /^[A-Z][A-Z0-9_]*=/.test(s)).map((s) => { const i = s.indexOf('='); return [s.slice(0, i), s.slice(i + 1)]; }));
async function freePort() {
  const server = net.createServer(); await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port; await new Promise((resolve) => server.close(resolve)); return port;
}
function invoke(env, runner, ...args) {
  const result = spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', runner, ...args], { env, encoding: 'utf8', timeout: 90000 });
  if (result.error) throw result.error;
  return result;
}
function success(result) { assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`); }
function installFakes(base) {
  const r = path.join(base, 'runtime');
  const node = path.join(r, 'node/node_modules/node/bin/node.exe');
  fs.mkdirSync(path.dirname(node), { recursive: true }); fs.symlinkSync(process.execPath, node);
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
    const dest = path.join(r, name); fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, `#!/usr/bin/env node\n${fs.readFileSync(fixture, 'utf8')}`, { mode: 0o755 });
  }
  const dest = path.join(r, 'npm/core/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs');
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.symlinkSync(proxy, dest);
}

test('local Docker setup is isolated, automatic, retryable and preserves existing files', { skip, timeout: 240000 }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-local-docker- & '));
  const home = path.join(root, 'дом'); const base = path.join(root, 'Профиль с пробелами'); const bin = path.join(root, 'инструменты');
  fs.mkdirSync(home); fs.mkdirSync(base);
  const setup = prepareDockerFixture(root, bin);
  const env = { ...process.env, ...setup.env, OS: 'Windows_NT', USERPROFILE: home, HOME: home, MCP_LOCAL_DIR: base,
    PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH}`,
    POSTGRES_PASSWORD: 'unrelated-database-password', APP_URL: 'https://unrelated.example',
    DOCKER_CONTEXT: 'unrelated-remote-context', COMPOSE_FILE: 'unrelated.yml', MCPKIT_METAMCP_PORT: '12080', MCPKIT_METAMCP_BACKEND_PORT: '0' };
  const existingClone = path.join(base, 'metamcp'); fs.mkdirSync(existingClone); fs.writeFileSync(path.join(existingClone, 'do-not-touch.txt'), 'existing user clone');
  const legacy = path.join(base, 'config/.env'); fs.mkdirSync(path.dirname(legacy), { recursive: true }); fs.writeFileSync(legacy, 'OTHER=keep\n');
  try {
    success(invoke(env, setup.runner, 'init'));
    const settingsFile = path.join(base, 'config/local-settings.json');
    const settings = readJson(settingsFile); settings.port = await freePort();
    // Settings written by the previous version must remain untouched.
    Object.assign(settings, { advertiseBaseUrl: '', metamcpOwnerEmail: '', linuxSshTarget: '', linuxKitDir: '' });
    writeJson(settingsFile, settings);
    const secretsFile = path.join(base, 'config/private/secrets.json'); const secrets = readJson(secretsFile);
    installFakes(base);
    const first = invoke(env, setup.runner, 'start'); success(first);
    assert.match(first.stdout, /Registered the 13 Windows servers in shared/);
    assert.match(first.stdout, /database backup and server-name migration/i);
    assert.match(first.stdout, /Reconnect MCP clients/);
    const firstDocker = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(firstDocker.databaseBackups.length, 1);
    assert.equal(firstDocker.startCalls, 1, 'the same app container is restarted after the seed');
    assert.equal(firstDocker.appRecreates || 0, 0);
    assert.ok(firstDocker.sharedSeed.serverNames.includes('filesystem'));
    assert.ok(firstDocker.sharedSeed.serverNames.every((name) => !name.startsWith('winpub-')));
    for (const suffix of ['system', 'files', 'code', 'web', 'data', 'memory']) {
      assert.match(first.stdout, new RegExp(`http://localhost:12080/metamcp/local-${settings.hostId}-${suffix}/mcp`));
    }
    assert.match(first.stdout, /Docker Desktop can reach the authenticated loopback/);
    assert.match(first.stdout, /MetaMCP: http:\/\/localhost:12080/);
    assert.doesNotMatch(first.stdout, /SSH|VPN/i);
    const metaFile = path.join(base, 'config/private/metamcp-state.json'); const meta = readJson(metaFile);
    const metaEnvFile = path.join(base, 'config/private/metamcp.env'); const metaEnv = readEnv(metaEnvFile);
    assert.equal(meta.port, 12080); assert.equal(meta.backendPort, 0); assert.equal(meta.envCreated, true);
    assert.equal(meta.ownerEmail, ''); assert.equal(meta.manualAuthApplied, true);
    assert.match(meta.cloneDir, /metamcp-kit-[a-f0-9]{16}$/);
    assert.equal(fs.readFileSync(path.join(existingClone, 'do-not-touch.txt'), 'utf8'), 'existing user clone');
    assert.equal(fs.existsSync(path.join(meta.cloneDir, '.env')), false, 'secrets must stay outside the Docker build context');
    assert.match(metaEnv.POSTGRES_PASSWORD, /^[a-f0-9]{64}$/);
    assert.match(metaEnv.BETTER_AUTH_SECRET, /^[a-f0-9]{64}$/);
    assert.equal(metaEnv.BOOTSTRAP_ENABLE, 'false');
    for (const name of ['BOOTSTRAP_USER_EMAIL', 'BOOTSTRAP_USER_PASSWORD', 'BOOTSTRAP_API_KEYS', 'METAMCP_ADMIN_EMAILS']) {
      assert.equal(metaEnv[name], undefined, `${name} must not be generated`);
    }
    assert.equal(readJson(setup.env.MCP_TEST_CAPTURE).gatewayKey, secrets.gatewayApiKey);
    assert.equal(readJson(setup.env.MCP_TEST_CAPTURE).port, settings.port);
    assert.equal(readJson(setup.env.MCP_TEST_CAPTURE).ownerEmail, '');
    assert.deepEqual(readJson(setup.env.MCP_TEST_DOCKER_STATE).users || [], []);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).appliedAuth.bootstrap, 'false');
    const credentials = invoke(env, setup.runner, 'credentials'); success(credentials);
    assert.match(credentials.stdout, /No bootstrap login was created/);
    const beforeSignupSeed = invoke(env, setup.runner, 'seed'); success(beforeSignupSeed);
    assert.match(beforeSignupSeed.stdout, /shared, API-key-protected groups/);
    assert.deepEqual(readJson(setup.env.MCP_TEST_DOCKER_STATE).users || [], []);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).sharedSeed.owner, null);
    const trace = fs.readFileSync(setup.env.MCP_TEST_DOCKER_TRACE, 'utf8');
    for (const secret of [secrets.gatewayApiKey, metaEnv.POSTGRES_PASSWORD, metaEnv.BETTER_AUTH_SECRET]) {
      assert.ok(!trace.includes(secret), 'secrets must not appear in docker command arguments');
      assert.ok(!first.stdout.includes(secret), 'secrets must not appear in normal startup output');
    }
    const envBefore = fs.readFileSync(metaEnvFile, 'utf8');
    // Simulate the user signing up and disabling registration in the UI.
    const signedUp = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    signedUp.users = [{ id: 'alice-id', email: 'alice@example.com' }]; signedUp.signupDisabled = true;
    writeJson(setup.env.MCP_TEST_DOCKER_STATE, signedUp);
    const second = invoke(env, setup.runner, 'start'); success(second);
    assert.match(second.stdout, /already initialized/);
    assert.equal(readJson(metaFile).ownerEmail, '');
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).sharedSeed.serverCount, 13);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).signupDisabled, true);
    const stateBefore = fs.readFileSync(metaFile, 'utf8');
    const third = invoke(env, setup.runner, 'start'); success(third);
    assert.match(third.stdout, /already initialized/);
    assert.equal(fs.readFileSync(metaFile, 'utf8'), stateBefore); assert.equal(fs.readFileSync(metaEnvFile, 'utf8'), envBefore);
    assert.deepEqual(readJson(settingsFile), settings); assert.deepEqual(readJson(secretsFile), secrets);
    assert.equal(fs.readFileSync(legacy, 'utf8'), 'OTHER=keep\n');
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).upCalls, 3);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).databaseBackups.length, 2, 'ordinary starts do not back up or restart an initialized app');
    // A failed backup must not apply the seed and must restart the same app.
    const beforeBackupFailure = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    const backupFailure = invoke({ ...env, MCP_TEST_BACKUP_FAIL: '1' }, setup.runner, 'seed');
    assert.notEqual(backupFailure.status, 0);
    assert.match(backupFailure.stdout, /backup; no migration was attempted/i);
    const afterBackupFailure = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(afterBackupFailure.running, true);
    assert.equal(afterBackupFailure.seeds, beforeBackupFailure.seeds);
    assert.deepEqual(afterBackupFailure.databaseBackups, beforeBackupFailure.databaseBackups);
    success(invoke(env, setup.runner, 'status'));
    success(invoke(env, setup.runner, 'seed'));
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).signupDisabled, true);
    // Partial seed diagnostics must not hide the other usable groups.
    const withWarnings = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    withWarnings.seedWarnings = { blocked: `local-${settings.hostId}-web`, conflicts: 'server:git', deferred: 'obsidian' };
    writeJson(setup.env.MCP_TEST_DOCKER_STATE, withWarnings);
    const warningResult = invoke(env, setup.runner, 'seed'); success(warningResult);
    assert.match(warningResult.stdout, /unauthenticated endpoint/i);
    assert.match(warningResult.stdout, /could not be safely merged or linked/);
    assert.match(warningResult.stdout, /legacy mappings were not added/);
    assert.match(warningResult.stdout, new RegExp(`local-${settings.hostId}-code/mcp`));
    assert.doesNotMatch(warningResult.stdout, new RegExp(`local-${settings.hostId}-web/mcp`));
    const afterWarnings = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    delete afterWarnings.seedWarnings; writeJson(setup.env.MCP_TEST_DOCKER_STATE, afterWarnings);

    const beforeUnsafe = readJson(setup.env.MCP_TEST_DOCKER_STATE).upCalls;
    const unsafe = invoke({ ...env, MCP_TEST_UNSAFE_PORT: '1' }, setup.runner, 'start');
    assert.notEqual(unsafe.status, 0); assert.match(unsafe.stdout, /Unsafe published ports/);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).upCalls, beforeUnsafe);
    const remote = invoke({ ...env, MCP_TEST_REMOTE_CONTEXT: '1' }, setup.runner, 'start');
    assert.notEqual(remote.status, 0); assert.match(remote.stdout, /does not point to the local Docker Desktop named pipe/);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).upCalls, beforeUnsafe);
    const bridge = invoke({ ...env, MCP_TEST_BRIDGE_FAIL: '1' }, setup.runner, 'start');
    assert.notEqual(bridge.status, 0); assert.match(bridge.stdout, /cannot reach the loopback Windows gateway/);
    assert.equal(readJson(settingsFile).listenHost, '127.0.0.1', 'a failed bridge must not widen the listener');

    success(invoke(env, setup.runner, 'stop'));
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).running, false);
    assert.equal(fs.readFileSync(metaEnvFile, 'utf8'), envBefore);
    assert.equal(fs.readFileSync(metaFile, 'utf8'), stateBefore);

    // Losing a credentials file never silently rotates the existing DB secret.
    fs.unlinkSync(metaEnvFile);
    const missing = invoke(env, setup.runner, 'start');
    assert.notEqual(missing.status, 0); assert.match(missing.stdout, /credentials were not regenerated/);
    assert.equal(fs.existsSync(metaEnvFile), false);
    fs.writeFileSync(metaEnvFile, envBefore); // restore disposable fixture only
    success(invoke(env, setup.runner, 'gateway-stop'));

    // One broken server must not prevent MetaMCP and the other twelve records
    // from being set up; it still yields an honest nonzero exit status.
    const broken = path.join(base, 'runtime/npm/codebase/node_modules/codebase-memory-mcp/bin.js');
    const saved = fs.readFileSync(broken); fs.unlinkSync(broken);
    const partial = invoke(env, setup.runner, 'start');
    assert.notEqual(partial.status, 0); assert.match(partial.stdout, /error\s+codebase-memory-mcp/);
    assert.match(partial.stdout, /MetaMCP: http:\/\/localhost:12080/);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).running, true);
    fs.writeFileSync(broken, saved, { mode: 0o755 });
    success(invoke(env, setup.runner, 'restart'));

    // A colliding, differently owned container must never be started/stopped.
    const dockerState = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    const app = `${meta.project}-app`; const oldLabels = dockerState.container[app];
    dockerState.container[app] = { ...oldLabels, 'com.multfinite.mcpkit.instance': 'someone-else' }; writeJson(setup.env.MCP_TEST_DOCKER_STATE, dockerState);
    const beforeCollision = dockerState.upCalls;
    const collision = invoke(env, setup.runner, 'start');
    assert.notEqual(collision.status, 0); assert.match(collision.stdout, /not owned by this kit/);
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).upCalls, beforeCollision);
    dockerState.container[app] = oldLabels; writeJson(setup.env.MCP_TEST_DOCKER_STATE, dockerState);

    // An old installation had no backend-port or pending-change fields.
    // A failed switch keeps its DB, secrets, and app snapshot for a retry.
    const legacyState = readJson(metaFile);
    delete legacyState.backendPort; delete legacyState.portsPending; delete legacyState.appImage;
    writeJson(metaFile, legacyState);
    const oldVolumes = readJson(setup.env.MCP_TEST_DOCKER_STATE).volume;
    const failedChange = invoke({ ...env, MCP_TEST_RECREATE_FAIL: '1' }, setup.runner, 'set-ports', '-WebPort', '13008', '-BackendPort', '13009');
    assert.notEqual(failedChange.status, 0); assert.match(failedChange.stdout, /simulated port conflict/);
    const pending = readJson(metaFile);
    assert.equal(pending.port, 13008); assert.equal(pending.backendPort, 13009); assert.equal(pending.portsPending, true);
    assert.match(pending.appImage, /-app-backup:[0-9]{14}-[a-f0-9]{8}$/);
    assert.equal(fs.readFileSync(metaEnvFile, 'utf8'), envBefore);
    assert.deepEqual(readJson(setup.env.MCP_TEST_DOCKER_STATE).volume, oldVolumes);
    success(invoke(env, setup.runner, 'start'));
    const changed = readJson(metaFile); const changedDocker = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(changed.portsPending, false); assert.equal(changed.port, 13008); assert.equal(changed.backendPort, 13009);
    assert.equal(changedDocker.lastAppImage, changed.appImage);
    assert.equal(changedDocker.lastFrontendPort, '13008'); assert.equal(changedDocker.lastBackendPort, '13009');
    assert.equal(changedDocker.lastAppUrl, 'http://localhost:13008');
    assert.ok(changedDocker.snapshots >= 2); assert.equal(changedDocker.appRecreates, 1);
    assert.deepEqual(changedDocker.volume, oldVolumes); assert.equal(fs.readFileSync(metaEnvFile, 'utf8'), envBefore);
    success(invoke(env, setup.runner, 'start'));
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).appRecreates, 1);
    success(invoke(env, setup.runner, 'stop'));
  } finally {
    try { invoke(env, setup.runner, 'stop'); } catch { /* fixture cleanup */ }
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('legacy bootstrap is disabled without changing accounts, signup, volumes or private endpoints', { skip, timeout: 240000 }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-legacy-auth-'));
  const home = path.join(root, 'home'); const base = path.join(root, 'local'); const bin = path.join(root, 'bin');
  fs.mkdirSync(home); fs.mkdirSync(base);
  const setup = prepareDockerFixture(root, bin);
  const env = { ...process.env, ...setup.env, OS: 'Windows_NT', USERPROFILE: home, HOME: home, MCP_LOCAL_DIR: base,
    PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH}` };
  try {
    success(invoke(env, setup.runner, 'init'));
    const settingsFile = path.join(base, 'config/local-settings.json'); const settings = readJson(settingsFile);
    settings.port = await freePort(); writeJson(settingsFile, settings);
    installFakes(base);
    success(invoke(env, setup.runner, 'start'));
    const metaFile = path.join(base, 'config/private/metamcp-state.json'); const meta = readJson(metaFile);
    const envFile = path.join(base, 'config/private/metamcp.env');
    const oldEmail = `local-${meta.instanceId}@mcpkit.local`; const oldPassword = 'a'.repeat(48);
    const oldEnv = fs.readFileSync(envFile, 'utf8').replace('BOOTSTRAP_ENABLE=false', 'BOOTSTRAP_ENABLE=true') +
      `BOOTSTRAP_USER_NAME=Windows LOCAL\nBOOTSTRAP_USER_EMAIL=${oldEmail}\nBOOTSTRAP_USER_PASSWORD=${oldPassword}\n` +
      `BOOTSTRAP_API_KEYS=[{"name":"Windows LOCAL","user_email":"${oldEmail}"}]\nMETAMCP_ADMIN_EMAILS=${oldEmail}\n`;
    fs.writeFileSync(envFile, oldEnv);
    delete meta.manualAuthApplied; delete meta.authPending; delete meta.additionalAdminEmails;
    meta.ownerEmail = oldEmail; writeJson(metaFile, meta);
    const previous = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    previous.users = [{ id: 'legacy-id', email: oldEmail }]; previous.signupDisabled = true;
    // Model the rejected V2 state: old private records plus the second set of
    // prefixed public records. V3 must run despite the existing V2 marker.
    previous.sharedSeed = { version: 2, serverCount: 13, owner: null,
      groups: ['code', 'data', 'files', 'memory', 'system', 'web'].map((suffix) => `local-${settings.hostId}-${suffix}`) };
    previous.seedRecords = { 'legacy-id': { owner: 'legacy-id', group: `local-${settings.hostId}`, serverCount: 13 } };
    previous.appliedAuth = { bootstrap: 'true', email: oldEmail, password: oldPassword, admins: oldEmail };
    const volumes = JSON.stringify(previous.volume);
    writeJson(setup.env.MCP_TEST_DOCKER_STATE, previous);

    const migrated = invoke(env, setup.runner, 'start'); success(migrated);
    let docker = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(docker.signupDisabled, true, 'upgrade must not reopen a closed signup');
    assert.equal(docker.sharedSeed.owner, null);
    assert.equal(docker.sharedSeed.serverCount, 13);
    assert.equal(docker.seedRecords['legacy-id'].group, `local-${settings.hostId}`, 'legacy endpoint remains intact');
    assert.equal(docker.seedRecords['legacy-id'].endpointPublic, true);
    assert.equal(docker.seedRecords['legacy-id'].serverCount, 0, 'old server duplicates were consolidated');
    assert.equal(docker.sharedSeed.version, 3);
    assert.match(migrated.stdout, new RegExp(`local-${settings.hostId}-code/mcp`));
    assert.deepEqual(docker.appliedAuth, { bootstrap: 'false', email: '', password: '', admins: oldEmail });
    assert.equal(readJson(metaFile).manualAuthApplied, true);
    assert.equal(docker.appRecreates, 1); assert.equal(JSON.stringify(docker.volume), volumes);
    assert.equal(fs.readFileSync(envFile, 'utf8'), oldEnv, 'legacy credentials are not rewritten');
    const legacyCredentials = invoke(env, setup.runner, 'credentials'); success(legacyCredentials);
    assert.ok(legacyCredentials.stdout.includes(oldEmail)); assert.ok(legacyCredentials.stdout.includes(oldPassword));

    success(invoke(env, setup.runner, 'enable-signup'));
    docker = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(docker.signupDisabled, false); assert.equal(docker.explicitSignupEnables, 1);
    docker.users.push({ id: 'manual-id', email: 'person@example.com' });
    writeJson(setup.env.MCP_TEST_DOCKER_STATE, docker);
    const selected = invoke(env, setup.runner, 'seed', '-OwnerEmail', 'person@example.com'); success(selected);
    docker = readJson(setup.env.MCP_TEST_DOCKER_STATE);
    assert.equal(docker.users.length, 2, 'neither account is deleted');
    assert.equal(docker.seedRecords['legacy-id'].group, `local-${settings.hostId}`);
    assert.equal(docker.seedRecords['manual-id'], undefined, 'no new private endpoint is created');
    assert.equal(docker.sharedSeed.serverCount, 13);
    assert.equal(docker.appliedAuth.admins, `${oldEmail},person@example.com`);
    assert.equal(docker.appRecreates, 2); assert.equal(JSON.stringify(docker.volume), volumes);
    assert.equal(docker.signupDisabled, false, 'the user must close signup manually');
    assert.equal(readJson(metaFile).ownerEmail, 'person@example.com');
    assert.deepEqual(readJson(metaFile).additionalAdminEmails, ['person@example.com']);
    assert.equal(fs.readFileSync(envFile, 'utf8'), oldEnv);
    assert.match(selected.stdout, new RegExp(`local-${settings.hostId}-code/mcp`));

    docker.signupDisabled = true; writeJson(setup.env.MCP_TEST_DOCKER_STATE, docker); // UI setting
    success(invoke(env, setup.runner, 'start'));
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).signupDisabled, true, 'restart must preserve the UI setting');
    const missing = invoke(env, setup.runner, 'seed', '-OwnerEmail', 'missing@example.com');
    assert.notEqual(missing.status, 0); assert.match(missing.stdout, /account was not found/);
    assert.equal(readJson(metaFile).ownerEmail, 'person@example.com');
    assert.equal(readJson(setup.env.MCP_TEST_DOCKER_STATE).appRecreates, 2);
    const stillAccessible = invoke(env, setup.runner, 'credentials'); success(stillAccessible);
    assert.ok(stillAccessible.stdout.includes(oldEmail));
    success(invoke(env, setup.runner, 'stop'));
  } finally {
    try { invoke(env, setup.runner, 'stop'); } catch { /* fixture cleanup */ }
    fs.rmSync(root, { recursive: true, force: true });
  }
});
