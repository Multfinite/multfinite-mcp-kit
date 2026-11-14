// Optional real semantic-search test. Requires mcp-proxy, the actual npm
// vectorstore installation, and a pre-provisioned Xenova model cache; no model
// or package is downloaded or committed by this test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { startGateway } from '../windows/gateway.mjs';

const proxy = process.env.MCP_PROXY_CLI;
const entry = process.env.MCP_VECTORSTORE_CLI;
const modelCache = process.env.MCP_VECTORSTORE_CACHE;
const loader = fileURLToPath(new URL('./fixtures/vectorstore-offline.mjs', import.meta.url));
const key = 'a'.repeat(64);
const control = 'b'.repeat(64);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function rpc(url, message, session) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'X-API-Key': key, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json', ...(session ? { 'Mcp-Session-Id': session } : {}) },
    body: JSON.stringify(message),
    signal: AbortSignal.timeout(30000),
  });
  const text = await response.text();
  assert.ok(response.status === 200 || response.status === 202, `HTTP ${response.status}: ${text}`);
  const json = response.headers.get('content-type')?.includes('text/event-stream')
    ? text.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n')
    : text;
  return { body: json ? JSON.parse(json) : {}, session: response.headers.get('mcp-session-id') };
}

test('real vectorstore embeds Unicode-path files and searches them through MCP', {
  skip: (!proxy || !entry || !modelCache) && 'set MCP_PROXY_CLI, MCP_VECTORSTORE_CLI and MCP_VECTORSTORE_CACHE',
  timeout: 180000,
}, async () => {
  assert.ok(fs.existsSync(proxy), 'mcp-proxy CLI is missing');
  assert.ok(fs.existsSync(entry), 'vectorstore CLI is missing');
  assert.ok(fs.existsSync(path.join(modelCache, 'Xenova', 'all-MiniLM-L6-v2', 'onnx', 'model.onnx')), 'model cache is incomplete');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-вектор с пробелами-'));
  const docs = path.join(tmp, 'Заметки с пробелами');
  fs.mkdirSync(docs);
  fs.writeFileSync(path.join(docs, 'лес-forest.txt'), 'The intelligent fox lives beside a quiet river in the forest. It watches birds and swims.\n');
  fs.writeFileSync(path.join(docs, 'database.txt'), 'Relational database tables use SQL queries, indexes, and replication logs.\n');
  const watchFile = path.join(tmp, 'watch.json');
  fs.writeFileSync(watchFile, JSON.stringify({ watchList: [docs] }));
  let gateway;
  try {
    gateway = await startGateway({
      settings: { listenHost: '127.0.0.1', port: 0, tlsCertFile: '', tlsKeyFile: '', allowInsecureLan: false },
      gatewayKey: key, controlKey: control, instanceId: 'vector-real', proxyPath: proxy, logDir: tmp,
      startupTimeoutMs: 30000,
      specs: [{ id: 'vector', command: process.execPath, entry: loader, args: [loader, entry], cwd: tmp,
        env: { MCP_VECTORSTORE_TEST_CACHE: modelCache, WATCH_CONFIG_FILE: watchFile, WATCH_DIRECTORIES: '' } }],
    });
    for (let i = 0; i < 150 && gateway.snapshot().servers[0].status === 'starting'; i++) await sleep(200);
    assert.equal(gateway.snapshot().servers[0].status, 'ready', fs.readFileSync(path.join(tmp, 'vector.log'), 'utf8'));
    const url = `http://127.0.0.1:${gateway.address.port}/servers/vector/mcp`;
    const initialized = await rpc(url, { jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'mcpkit-vector-test', version: '1.0.0' },
    } });
    assert.ok(initialized.session);
    await rpc(url, { jsonrpc: '2.0', method: 'notifications/initialized' }, initialized.session);
    let stats;
    for (let i = 0; i < 70; i++) {
      const response = await rpc(url, { jsonrpc: '2.0', id: 10 + i, method: 'tools/call', params: { name: 'get_stats', arguments: {} } }, initialized.session);
      stats = JSON.parse(response.body.result.content[0].text);
      if (stats.totalDocuments >= 2) break;
      await sleep(1000);
    }
    assert.ok(stats.totalDocuments >= 2, `Documents were not indexed. ${fs.readFileSync(path.join(tmp, 'vector.log'), 'utf8')}`);
    const response = await rpc(url, { jsonrpc: '2.0', id: 100, method: 'tools/call', params: { name: 'search', arguments: { query: 'wild animals living near water', limit: 2 } } }, initialized.session);
    assert.ifError(response.body.error);
    const results = JSON.parse(response.body.result.content[0].text);
    assert.equal(results.length, 2);
    assert.match(results[0].source, /лес-forest\.txt$/);
    assert.match(results[0].content, /fox/);
  } finally {
    if (gateway) await gateway.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
