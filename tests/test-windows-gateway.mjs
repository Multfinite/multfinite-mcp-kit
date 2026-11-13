import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { startGateway } from '../windows/gateway.mjs';
import { buildServerSpecs } from '../windows/local-kit.mjs';

const proxyPath = process.env.MCP_PROXY_CLI;
const fixture = fileURLToPath(new URL('./fixtures/fake-stdio-mcp.cjs', import.meta.url));
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const gatewayKey = 'a'.repeat(64);
const controlKey = 'b'.repeat(64);
const settings = { listenHost: '127.0.0.1', port: 0, tlsCertFile: '', tlsKeyFile: '', allowInsecureLan: false };

async function rpc(url, key, message, session, extraHeaders = {}) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', 'X-API-Key': key, ...(session ? { 'Mcp-Session-Id': session } : {}), ...extraHeaders },
    body: JSON.stringify(message),
  });
  const text = await response.text();
  assert.ok(response.status === 200 || response.status === 202, `Unexpected HTTP ${response.status}: ${text}`);
  const body = response.headers.get('content-type')?.includes('text/event-stream')
    ? text.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n')
    : text;
  return { result: body ? JSON.parse(body) : null, session: response.headers.get('mcp-session-id') };
}

test('local gateway authenticates, routes independent MCP sessions and stops children', { skip: !proxyPath && 'set MCP_PROXY_CLI to the installed mcp-proxy CLI' }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit path with spaces '));
  const localFixture = path.join(root, 'fake server.cjs');
  fs.copyFileSync(fixture, localFixture);
  const isolatedNames = new Set(['OBSIDIAN_API_KEY', 'DSN', 'DBHUB_DSN', 'MCPKIT_GATEWAY_KEY', 'MCPKIT_CONTROL_KEY', 'PYTHONIOENCODING', 'PYTHONUTF8', 'PYTHONUNBUFFERED']);
  const isIsolated = (name) => isolatedNames.has(name.toUpperCase()) || name.toUpperCase().startsWith('MCP_PROXY_');
  const original = Object.fromEntries(Object.entries(process.env).filter(([name]) => isIsolated(name)));
  for (const name of Object.keys(original)) delete process.env[name];
  process.env.Obsidian_Api_Key = 'inherited-obsidian';
  process.env.DSN = 'inherited-database';
  process.env.DBHUB_DSN = 'inherited-legacy-database';
  process.env.MCPKIT_GATEWAY_KEY = 'inherited-gateway';
  process.env.MCPKIT_CONTROL_KEY = 'inherited-control';
  // These would make an internal proxy serve a different endpoint or try to
  // read missing TLS files if inherited from an unrelated application.
  process.env.MCP_PROXY_STREAM_ENDPOINT = '/elsewhere';
  process.env.Mcp_Proxy_Ssl_Cert = path.join(root, 'not-a-cert.pem');
  process.env.PythonIoEncoding = 'cp866';
  process.env.PythonUtf8 = '0';
  process.env.PythonUnbuffered = '0';
  const specs = [
    { id: 'one', command: process.execPath, entry: localFixture, args: [localFixture], cwd: root, env: {} },
    { id: 'two', command: process.execPath, entry: localFixture, args: [localFixture], cwd: root, env: { OBSIDIAN_API_KEY: 'only-two', DSN: 'only-two-database' } },
    { id: 'waiting', command: process.execPath, args: [], cwd: root, env: {}, waitReason: 'key missing' },
    { id: 'not-installed', command: path.join(root, 'not-a-program'), args: [], cwd: root, env: {} },
  ];
  let gateway;
  try {
    gateway = await startGateway({ settings, gatewayKey, controlKey, instanceId: 'test-instance', specs, proxyPath, logDir: root, startupTimeoutMs: 15000 });
    for (let i = 0; i < 100; i++) {
      if (gateway.snapshot().servers.filter((s) => s.status === 'ready').length === 2) break;
      await delay(100);
    }
    assert.deepEqual(gateway.snapshot().servers.map((s) => s.status), ['ready', 'ready', 'waiting', 'error']);
    const base = `http://127.0.0.1:${gateway.address.port}`;
    assert.equal((await fetch(`${base}/servers/one/mcp`)).status, 401);
    assert.equal((await fetch(`${base}/servers/one/mcp`, { headers: { 'X-API-Key': 'wrong' } })).status, 401);
    assert.equal((await fetch(`${base}/_mcpkit/status`, { headers: { 'X-API-Key': gatewayKey } })).status, 401);
    assert.equal((await fetch(`${base}/servers/one/mcp?api_key=${gatewayKey}`)).status, 401);
    assert.equal((await fetch(`${base}/servers/not-real/mcp`, { headers: { 'X-API-Key': gatewayKey } })).status, 404);
    assert.equal((await fetch(`${base}/servers/waiting/mcp`, { headers: { 'X-API-Key': gatewayKey } })).status, 503);
    const status = await fetch(`${base}/_mcpkit/status`, { headers: { 'X-Mcpkit-Control': controlKey } });
    assert.equal((await status.json()).instanceId, 'test-instance');
    const url = `${base}/servers/one/mcp`;
    const initialize = { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'test', version: '1' } } };
    const init = await rpc(url, gatewayKey, initialize);
    assert.ok(init.session);
    await rpc(url, gatewayKey, { jsonrpc: '2.0', method: 'notifications/initialized' }, init.session);
    const list = await rpc(url, gatewayKey, { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, init.session);
    assert.equal(list.result.result.tools[0].name, 'echo');
    const call = await rpc(url, gatewayKey, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'echo', arguments: {} } }, init.session);
    const leakedToUpstream = call.result.result.content[0].text;
    assert.notEqual(leakedToUpstream, gatewayKey, 'the externally usable key must not be inherited by an MCP server');
    assert.notEqual(leakedToUpstream, controlKey);
    assert.match(leakedToUpstream, /^[a-f0-9]{64}$/);
    const second = await rpc(`${base}/servers/two/mcp`, gatewayKey, initialize);
    assert.ok(second.session);
    assert.notEqual(second.session, init.session);
    await rpc(`${base}/servers/two/mcp`, gatewayKey, { jsonrpc: '2.0', method: 'notifications/initialized' }, second.session);
    const getEnvironment = async (serverUrl, session) => {
      const result = await rpc(serverUrl, gatewayKey, { jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'echo', arguments: { showEnvironment: true } } }, session);
      return JSON.parse(result.result.result.content[0].text);
    };
    const oneEnv = await getEnvironment(url, init.session);
    const twoEnv = await getEnvironment(`${base}/servers/two/mcp`, second.session);
    assert.deepEqual(oneEnv, { OBSIDIAN_API_KEY: null, DSN: null, DBHUB_DSN: null, MCPKIT_GATEWAY_KEY: null, MCPKIT_CONTROL_KEY: null, MCP_PROXY_STREAM_ENDPOINT: null, MCP_PROXY_SSL_CERT: null, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1', PYTHONUNBUFFERED: '1' });
    assert.deepEqual(twoEnv, { ...oneEnv, OBSIDIAN_API_KEY: 'only-two', DSN: 'only-two-database' });
    // urllib and some MCP clients close each client-side connection. These
    // hop-by-hop headers must not poison a reused gateway-to-proxy socket.
    const closeInit = await rpc(url, gatewayKey, initialize, null, { Connection: 'close' });
    await rpc(url, gatewayKey, { jsonrpc: '2.0', method: 'notifications/initialized' }, closeInit.session, { Connection: 'close' });
    const closeList = await rpc(url, gatewayKey, { jsonrpc: '2.0', id: 4, method: 'tools/list', params: {} }, closeInit.session, { Connection: 'close' });
    assert.equal(closeList.result.result.tools[0].name, 'echo');
  } finally {
    if (gateway) await gateway.close();
    for (const name of Object.keys(process.env)) if (isIsolated(name)) delete process.env[name];
    Object.assign(process.env, original);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('public listener requires TLS or explicit VPN/tunnel opt-in', async () => {
  await assert.rejects(startGateway({ settings: { ...settings, listenHost: '0.0.0.0' }, gatewayKey, controlKey, instanceId: 'a', specs: [], proxyPath: fixture, logDir: os.tmpdir() }), /non-loopback HTTP/);
  await assert.rejects(startGateway({ settings: { ...settings, tlsCertFile: '/missing', tlsKeyFile: '' }, gatewayKey, controlKey, instanceId: 'a', specs: [], proxyPath: fixture, logDir: os.tmpdir() }), /Both TLS/);
});

test('TLS listener authenticates control requests', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-tls-'));
  const key = path.join(root, 'key.pem'); const cert = path.join(root, 'cert.pem');
  const openssl = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost', '-keyout', key, '-out', cert, '-days', '1'], { stdio: 'ignore' });
  if (openssl.error?.code === 'ENOENT') { fs.rmSync(root, { recursive: true, force: true }); t.skip('openssl is not installed'); return; }
  assert.equal(openssl.status, 0, 'could not create a test certificate');
  const gateway = await startGateway({ settings: { ...settings, listenHost: '0.0.0.0', tlsCertFile: cert, tlsKeyFile: key }, gatewayKey, controlKey, instanceId: 'tls-test', specs: [], proxyPath: fixture, logDir: root });
  const getStatus = (control) => new Promise((resolve, reject) => {
    const req = https.get({ host: '127.0.0.1', port: gateway.address.port, path: '/_mcpkit/status', headers: { 'X-Mcpkit-Control': control }, rejectUnauthorized: false }, (res) => {
      let body = ''; res.setEncoding('utf8'); res.on('data', (part) => { body += part; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(body) }));
    }); req.on('error', reject);
  });
  try {
    assert.equal((await getStatus('wrong')).status, 401);
    assert.equal((await getStatus(controlKey)).body.instanceId, 'tls-test');
  } finally { await gateway.close(); fs.rmSync(root, { recursive: true, force: true }); }
});

test('all thirteen README servers use the real packages and isolated credentials', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp local paths '));
  try {
    const projects = path.join(root, 'project with spaces');
    const writing = path.join(root, 'notes, with comma');
    fs.mkdirSync(projects); fs.mkdirSync(writing);
    const s = { projectsDir: projects, writingDir: writing, everythingSdkPath: path.join(root, 'Everything64.dll'), obsidianHost: '127.0.0.1', obsidianPort: 27124 };
    const secrets = { gatewayApiKey: gatewayKey, dbhubDsn: '', obsidianApiKey: 'only-obsidian' };
    const specs = buildServerSpecs(s, secrets, root);
    assert.equal(specs.length, 13);
    assert.equal(new Set(specs.map((item) => item.id)).size, 13);
    assert.ok(specs.find((item) => item.id === 'filesystem').args.some((arg) => arg.includes('@j0hanz')));
    assert.ok(specs.find((item) => item.id === 'desktop-commander').entry.includes('@wonderwhy-er'));
    assert.ok(specs.find((item) => item.id === 'serena').args.includes('start-mcp-server'));
    assert.equal(specs.find((item) => item.id === 'codegraph').env.CODEGRAPH_TELEMETRY, '0');
    assert.equal(specs.find((item) => item.id === 'codegraph').env.CODEGRAPH_INSTALL_DIR, path.join(root, 'runtime', 'codegraph'));
    assert.ok(specs.find((item) => item.id === 'windows-mcp').args.includes('serve'));
    assert.equal(specs.find((item) => item.id === 'obsidian').env.OBSIDIAN_API_KEY, 'only-obsidian');
    assert.equal(specs.find((item) => item.id === 'git').env.OBSIDIAN_API_KEY, undefined);
    assert.ok(specs.find((item) => item.id === 'simple-files-vectorstore').env.WATCH_CONFIG_FILE.endsWith('vector-watch.json'));
    assert.ok(specs.find((item) => item.id === 'dbhub').env.DSN.startsWith('sqlite:'));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
