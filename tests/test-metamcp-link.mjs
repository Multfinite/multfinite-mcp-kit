// End-to-end tests for the independent MetaMCP-to-MetaMCP network link.
// Docker is replaced by a local synthetic CLI; no daemon or container is used.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const runner = path.join(root, 'linux/link-metamcp.sh');
const fake = path.join(root, 'tests/fixtures/fake-metamcp-link-docker.cjs');
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const writeJson = (file, value) => fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
const idFor = (value) => crypto.createHash('sha256').update(value).digest('hex');
const labelProject = 'com.docker.compose.project';
const labelInstance = 'com.multfinite.mcpkit.instance';

function makeInstance(rootDir, id, port) {
  const base = path.join(rootDir, `MetaMCP ${id.slice(0, 4)}`);
  const priv = path.join(base, '.mcpkit');
  fs.mkdirSync(priv, { recursive: true, mode: 0o700 });
  fs.chmodSync(priv, 0o700);
  const project = `mcpkit-meta-${id}`;
  const state = { version: 1, type: 'meta', id, project, base, port, appUrl: `http://localhost:${port}`, revision: 'fixture' };
  writeJson(path.join(priv, 'state.json'), state);
  fs.writeFileSync(path.join(priv, '.env'), `POSTGRES_PASSWORD=${'a'.repeat(64)}\nBETTER_AUTH_SECRET=${'b'.repeat(64)}\n`, { mode: 0o600 });
  const networkName = `${project}_default`;
  const networkId = idFor(`${project}:default`);
  const labels = { [labelProject]: project, [labelInstance]: id, 'com.docker.compose.network': 'default' };
  const network = { Id: networkId, Name: networkName, Driver: 'bridge', Scope: 'local', Internal: false, Labels: labels, Containers: {} };
  return { base, priv, state, networkName, network };
}
function addContainer(fixture, instance, service) {
  const id = idFor(`${instance.state.project}:${service}`);
  const name = `/${instance.state.project}-${service}-1`;
  const labels = { [labelProject]: instance.state.project, [labelInstance]: instance.state.id,
    'com.docker.compose.service': service, 'com.docker.compose.oneoff': 'False' };
  const container = { Id: id, Name: name, Config: { Labels: labels }, State: { Running: true },
    HostConfig: { NetworkMode: instance.networkName }, NetworkSettings: { Networks: {
      [instance.networkName]: { NetworkID: instance.network.Id, Aliases: [name.slice(1), `${instance.state.project}-${service}`, id.slice(0, 12)] },
    } } };
  fixture.containers[id] = container;
  instance.network.Containers[id] = { Name: name.slice(1), EndpointID: `endpoint-${id.slice(0, 12)}`, MacAddress: '02:42:ac:10:00:02', IPv4Address: '172.20.0.2/16' };
  return container;
}
function newFixture() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit metamcp peer '));
  const bin = path.join(temp, 'bin'); fs.mkdirSync(bin);
  const docker = path.join(bin, 'docker');
  const quote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
  fs.writeFileSync(docker, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(fake)} "$@"\n`, { mode: 0o755 });
  const env = { ...process.env };
  for (const key of ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'COMPOSE_FILE', 'COMPOSE_PROJECT_NAME']) delete env[key];
  Object.assign(env, {
    HOME: temp,
    PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${process.env.PATH || ''}`,
    MCP_TEST_META_LINK_STATE: path.join(temp, 'docker-state.json'),
    MCP_TEST_META_LINK_TRACE: path.join(temp, 'docker-trace.jsonl'),
  });
  const dockerState = { containers: {}, networks: {}, volumes: {} };
  const instances = [];
  for (const [index, id] of ['1111111111111111', '2222222222222222', '3333333333333333'].entries()) {
    const instance = makeInstance(temp, id, 12108 + index * 100);
    instances.push(instance);
    dockerState.networks[instance.networkName] = instance.network;
    addContainer(dockerState, instance, 'app');
    addContainer(dockerState, instance, 'postgres');
    for (const suffix of ['postgres_data', 'uv_cache']) {
      const name = `${instance.state.project}_${suffix}`;
      dockerState.volumes[name] = { Name: name, Labels: { [labelProject]: instance.state.project, [labelInstance]: id } };
    }
  }
  writeJson(env.MCP_TEST_META_LINK_STATE, dockerState);
  fs.writeFileSync(env.MCP_TEST_META_LINK_TRACE, '');
  return { temp, env, instances, stateFile: env.MCP_TEST_META_LINK_STATE, traceFile: env.MCP_TEST_META_LINK_TRACE };
}
function invoke(fixture, left, right, unlink = false) {
  const args = [runner, left.base, right.base, ...(unlink ? ['--unlink'] : [])];
  return spawnSync('bash', args, { cwd: root, env: fixture.env, encoding: 'utf8', timeout: 30000 });
}
function success(result) { assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`); }
function trace(fixture) { return fs.readFileSync(fixture.traceFile, 'utf8').trim().split(/\r?\n/).filter(Boolean).map(JSON.parse); }
function peerLinks(instance) {
  const file = path.join(instance.priv, 'live-metamcp-links.json');
  return fs.existsSync(file) ? readJson(file).links : [];
}
function pairNetworkName(left, right) {
  const projects = [left.state.project, right.state.project].sort();
  const hash = crypto.createHash('sha256').update(projects.join('\n')).digest('hex').slice(0, 24);
  return `mcpkit-meta-peer-${hash}`;
}
function cleanup(fixture) { fs.rmSync(fixture.temp, { recursive: true, force: true }); }

test('links only the two app containers, persists both directions, and is idempotent', { skip: process.platform === 'win32' }, () => {
  const fixture = newFixture(); const [left, right] = fixture.instances;
  try {
    const linked = invoke(fixture, left, right); success(linked);
    const networkName = pairNetworkName(left, right);
    const state = readJson(fixture.stateFile);
    const network = state.networks[networkName];
    assert.ok(network, 'the dedicated link network should exist');
    assert.equal(network.Driver, 'bridge'); assert.equal(network.Internal, true); assert.equal(network.Scope, 'local');
    assert.equal(network.Labels['com.multfinite.mcpkit.link'], 'metamcp-peer-v1');
    assert.deepEqual(Object.keys(network.Containers).sort(), [
      idFor(`${left.state.project}:app`), idFor(`${right.state.project}:app`),
    ].sort(), 'PostgreSQL must not join the peer network');
    const a = peerLinks(left); const b = peerLinks(right);
    assert.equal(a.length, 1); assert.equal(b.length, 1);
    assert.equal(a[0].peerProject, right.state.project); assert.equal(b[0].peerProject, left.state.project);
    assert.equal(a[0].networkId, network.Id); assert.equal(b[0].networkId, network.Id);
    assert.match(linked.stdout, new RegExp(`http://mcpkit-meta-${right.state.id}:12008/metamcp/all/mcp`));
    assert.match(linked.stdout, new RegExp(`http://mcpkit-meta-${left.state.id}:12008/metamcp/all/mcp`));
    assert.doesNotMatch(linked.stdout, /127\.0\.0\.1/);
    for (const [instance, peer] of [[left, right], [right, left]]) {
      const overlay = fs.readFileSync(path.join(instance.priv, 'metamcp-live-peers.yml'), 'utf8');
      assert.match(overlay, new RegExp(`name: "${networkName}"`));
      assert.match(overlay, new RegExp(`mcpkit-meta-${instance.state.id}`));
      const app = state.containers[idFor(`${instance.state.project}:app`)];
      assert.ok(app.NetworkSettings.Networks[networkName].Aliases.includes(`mcpkit-meta-${instance.state.id}`));
      assert.equal(app.NetworkSettings.Networks[`${peer.state.project}_default`], undefined);
    }
    const beforeRetry = trace(fixture);
    success(invoke(fixture, left, right));
    const afterRetry = trace(fixture);
    assert.equal(afterRetry.filter((args) => args.includes('create') && args.includes(networkName)).length,
      beforeRetry.filter((args) => args.includes('create') && args.includes(networkName)).length);
    assert.equal(afterRetry.filter((args) => args.includes('connect') && args.includes(networkName)).length,
      beforeRetry.filter((args) => args.includes('connect') && args.includes(networkName)).length);

    // A real lifecycle operation must pass the generated overlay to Compose.
    const lifecycle = spawnSync(process.execPath, [path.join(root, 'common/stack.mjs'), 'status', '--dir', left.base, '--expect-type', 'meta'],
      { cwd: root, env: fixture.env, encoding: 'utf8', timeout: 30000 });
    success(lifecycle);
    const composeCall = trace(fixture).find((args) => args[0] === '--context' && args[2] === 'compose' && args.includes('ps'));
    assert.ok(composeCall, 'the status lifecycle should call Compose');
    assert.ok(composeCall.includes(path.join(left.priv, 'metamcp-live-peers.yml')),
      'normal Compose lifecycle must load the peer network overlay');

    // Ordinary lifecycle commands fail closed if the external network vanished;
    // rerunning the dedicated link command safely recreates this exact pair.
    const oldNetworkId = network.Id;
    const damaged = readJson(fixture.stateFile);
    delete damaged.networks[networkName];
    for (const instance of [left, right]) delete damaged.containers[idFor(`${instance.state.project}:app`)].NetworkSettings.Networks[networkName];
    writeJson(fixture.stateFile, damaged);
    const staleLifecycle = spawnSync(process.execPath, [path.join(root, 'common/stack.mjs'), 'status', '--dir', left.base, '--expect-type', 'meta'],
      { cwd: root, env: fixture.env, encoding: 'utf8', timeout: 30000 });
    assert.notEqual(staleLifecycle.status, 0);
    assert.match(staleLifecycle.stderr, /is missing or was replaced/);
    success(invoke(fixture, left, right));
    const repaired = readJson(fixture.stateFile);
    assert.notEqual(repaired.networks[networkName].Id, oldNetworkId);
    assert.equal(peerLinks(left)[0].networkId, repaired.networks[networkName].Id);
    assert.equal(peerLinks(right)[0].networkId, repaired.networks[networkName].Id);

    success(invoke(fixture, left, right, true));
    const unlinked = readJson(fixture.stateFile);
    assert.equal(unlinked.networks[networkName], undefined);
    assert.equal(fs.existsSync(path.join(left.priv, 'live-metamcp-links.json')), false);
    assert.equal(fs.existsSync(path.join(right.priv, 'live-metamcp-links.json')), false);
    assert.equal(fs.existsSync(path.join(left.priv, 'metamcp-live-peers.yml')), false);
    assert.equal(fs.existsSync(path.join(right.priv, 'metamcp-live-peers.yml')), false);
    assert.equal(unlinked.containers[idFor(`${left.state.project}:app`)].NetworkSettings.Networks[networkName], undefined);
    success(invoke(fixture, left, right, true));
  } finally { cleanup(fixture); }
});

test('one MetaMCP can link to multiple peers and unlink just one pair', { skip: process.platform === 'win32' }, () => {
  const fixture = newFixture(); const [main, peerA, peerB] = fixture.instances;
  try {
    success(invoke(fixture, main, peerA));
    success(invoke(fixture, main, peerB));
    const metaLinks = peerLinks(main);
    assert.equal(metaLinks.length, 2);
    assert.deepEqual(metaLinks.map((item) => item.peerProject).sort(), [peerA.state.project, peerB.state.project].sort());
    const overlay = fs.readFileSync(path.join(main.priv, 'metamcp-live-peers.yml'), 'utf8');
    assert.match(overlay, new RegExp(pairNetworkName(main, peerA)));
    assert.match(overlay, new RegExp(pairNetworkName(main, peerB)));
    success(invoke(fixture, main, peerA, true));
    assert.deepEqual(peerLinks(main).map((item) => item.peerProject), [peerB.state.project]);
    assert.equal(peerLinks(peerA).length, 0);
    const remaining = fs.readFileSync(path.join(main.priv, 'metamcp-live-peers.yml'), 'utf8');
    assert.doesNotMatch(remaining, new RegExp(pairNetworkName(main, peerA)));
    assert.match(remaining, new RegExp(pairNetworkName(main, peerB)));
    const state = readJson(fixture.stateFile);
    assert.equal(state.networks[pairNetworkName(main, peerA)], undefined);
    assert.ok(state.networks[pairNetworkName(main, peerB)]);
  } finally { cleanup(fixture); }
});

test('saves a durable peer link when one app is stopped and attaches its active peer immediately', { skip: process.platform === 'win32' }, () => {
  const fixture = newFixture(); const [left, right] = fixture.instances;
  try {
    const before = readJson(fixture.stateFile);
    const stoppedId = idFor(`${right.state.project}:app`);
    const stopped = before.containers[stoppedId];
    stopped.State.Running = false;
    stopped.NetworkSettings.Networks = {};
    delete before.networks[right.networkName].Containers[stoppedId];
    writeJson(fixture.stateFile, before);
    success(invoke(fixture, left, right));
    const network = readJson(fixture.stateFile).networks[pairNetworkName(left, right)];
    assert.deepEqual(Object.keys(network.Containers), [idFor(`${left.state.project}:app`)]);
    assert.equal(peerLinks(left)[0].networkId, network.Id);
    assert.equal(peerLinks(right)[0].networkId, network.Id);
    assert.ok(fs.existsSync(path.join(right.priv, 'metamcp-live-peers.yml')),
      'the stopped app has a Compose overlay ready for its next start');
  } finally { cleanup(fixture); }
});

test('refuses unowned apps, non-kit state and a same-named foreign network before changing connectivity', { skip: process.platform === 'win32' }, () => {
  const fixture = newFixture(); const [left, right] = fixture.instances;
  try {
    const initial = readJson(fixture.stateFile);
    const rightApp = initial.containers[idFor(`${right.state.project}:app`)];
    rightApp.Config.Labels[labelInstance] = 'ffffffffffffffff';
    writeJson(fixture.stateFile, initial);
    const unowned = invoke(fixture, left, right);
    assert.notEqual(unowned.status, 0); assert.match(unowned.stderr, /not owned/);
    assert.equal(Object.keys(readJson(fixture.stateFile).networks).filter((name) => name.startsWith('mcpkit-meta-peer-')).length, 0);

    const clean = newFixture();
    try {
      const before = readJson(clean.stateFile);
      const name = pairNetworkName(clean.instances[0], clean.instances[1]);
      before.networks[name] = { Id: idFor('foreign-network'), Name: name, Driver: 'bridge', Scope: 'local', Internal: true,
        Labels: { 'com.multfinite.mcpkit.link': 'not-the-kit-pair' }, Containers: {} };
      writeJson(clean.stateFile, before);
      const foreign = invoke(clean, clean.instances[0], clean.instances[1]);
      assert.notEqual(foreign.status, 0); assert.match(foreign.stderr, /not owned by this MetaMCP pair/);
      assert.equal(Object.keys(readJson(clean.stateFile).networks[name].Containers).length, 0);
      assert.equal(fs.existsSync(path.join(clean.instances[0].priv, 'live-metamcp-links.json')), false);
    } finally { cleanup(clean); }

    const legacy = path.join(fixture.temp, 'legacy'); fs.mkdirSync(legacy);
    const noState = spawnSync('bash', [runner, legacy, right.base], { cwd: root, env: fixture.env, encoding: 'utf8', timeout: 30000 });
    assert.notEqual(noState.status, 0); assert.match(noState.stderr, /Independent kit state not found/);
  } finally { cleanup(fixture); }
});

test('refuses an app already connected to another MetaMCP backend network', { skip: process.platform === 'win32' }, () => {
  const fixture = newFixture(); const [left, right, third] = fixture.instances;
  try {
    const state = readJson(fixture.stateFile);
    const app = state.containers[idFor(`${left.state.project}:app`)];
    const otherName = `${third.state.project}_default`;
    app.NetworkSettings.Networks[otherName] = { NetworkID: state.networks[otherName].Id, Aliases: [] };
    state.networks[otherName].Containers[app.Id] = { Name: app.Name.slice(1), EndpointID: 'unsafe', MacAddress: '02:42:ac:10:00:99', IPv4Address: '172.20.0.9/16' };
    writeJson(fixture.stateFile, state);
    const result = invoke(fixture, left, right);
    assert.notEqual(result.status, 0); assert.match(result.stderr, /already attached to another project's private backend network/);
    assert.equal(Object.keys(readJson(fixture.stateFile).networks).filter((name) => name.startsWith('mcpkit-meta-peer-')).length, 0);
  } finally { cleanup(fixture); }
});
