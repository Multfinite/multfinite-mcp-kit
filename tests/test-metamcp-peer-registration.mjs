// Exercise directional MetaMCP registration against a local frontend-API fake.
// No Docker daemon or real MetaMCP instance is used.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { commitMetaPeerRegistration, prepareMetaPeerRegistration, resolveMetaPeerEndpoint } from '../common/metamcp-peer-registration.mjs';

const KEY = `sk_mt_${'s'.repeat(64)}`;
const ADMIN_EMAIL = 'admin@example.test';
const ADMIN_PASSWORD = 'test-password-only';

function makeState(root, label, id, port, appUrl) {
  const base = path.join(root, label);
  const priv = path.join(base, '.mcpkit');
  fs.mkdirSync(priv, { recursive: true, mode: 0o700 });
  fs.chmodSync(priv, 0o700);
  const state = { version: 1, type: 'meta', id, project: `mcpkit-meta-${id}`, base, port, appUrl };
  fs.writeFileSync(path.join(priv, 'state.json'), `${JSON.stringify(state)}\n`, { mode: 0o600 });
  return { ...state, priv };
}
function send(res, value, status = 200, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(JSON.stringify(value));
}
function trpc(res, data) { send(res, { result: { data: { json: { success: true, data } } } }); }
async function body(req) {
  let text = '';
  for await (const chunk of req) text += chunk;
  return text ? JSON.parse(text) : null;
}
async function fakeMetaApi() {
  const db = { servers: [], namespaces: [], endpoints: [], calls: [], conflicts: new Set() };
  let origin = '';
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (req.headers.origin !== origin) return send(res, { error: 'bad origin' }, 403);
      if (req.method === 'POST' && url.pathname === '/api/auth/sign-in/email') {
        const input = await body(req);
        if (input?.email !== ADMIN_EMAIL || input?.password !== ADMIN_PASSWORD) return send(res, { error: 'bad login' }, 401);
        return send(res, { success: true }, 200, { 'set-cookie': 'mcp-session=test-session; Path=/; HttpOnly; SameSite=Lax' });
      }
      if (url.pathname === '/api/auth/get-session') {
        if (req.headers.cookie !== 'mcp-session=test-session') return send(res, { error: 'unauthorized' }, 401);
        return send(res, { user: { id: 'admin-user-id' } });
      }
      const prefix = '/trpc/frontend.';
      if (!url.pathname.startsWith(prefix) || req.headers.cookie !== 'mcp-session=test-session') {
        return send(res, { error: 'unauthorized' }, 401);
      }
      const procedure = url.pathname.slice(prefix.length);
      const input = req.method === 'POST' ? await body(req) :
        (url.searchParams.has('input') ? JSON.parse(url.searchParams.get('input')) : undefined);
      db.calls.push({ procedure, input });
      if (procedure === 'config.getAllConfigs') return send(res, { result: { data: [] } });
      if (procedure === 'mcpServers.list') return trpc(res, db.servers);
      if (procedure === 'namespaces.list') return trpc(res, db.namespaces);
      if (procedure === 'endpoints.list') return trpc(res, db.endpoints);
      if (procedure === 'namespaces.get') {
        const namespace = db.namespaces.find((item) => item.uuid === input?.uuid);
        if (!namespace) return trpc(res, null);
        const result = { ...namespace, servers: namespace.serverUuids.map((uuid) => db.servers.find((item) => item.uuid === uuid)).filter(Boolean) };
        return trpc(res, result);
      }
      if (procedure === 'mcpServers.create') {
        if (db.servers.some((item) => item.name === input.name) || db.conflicts.has(`server:${input.name}`)) return send(res, { error: 'conflict' }, 409);
        const record = { ...input, uuid: crypto.randomUUID() };
        db.servers.push(record);
        return trpc(res, record);
      }
      if (procedure === 'namespaces.create') {
        if (db.namespaces.some((item) => item.name === input.name) || db.conflicts.has(`namespace:${input.name}`)) return send(res, { error: 'conflict' }, 409);
        const record = { uuid: crypto.randomUUID(), name: input.name, description: input.description, user_id: input.user_id, serverUuids: input.mcpServerUuids };
        db.namespaces.push(record);
        return trpc(res, record);
      }
      if (procedure === 'endpoints.create') {
        if (db.endpoints.some((item) => item.name === input.name) || db.conflicts.has(`endpoint:${input.name}`)) return send(res, { error: 'conflict' }, 409);
        const record = {
          uuid: crypto.randomUUID(), name: input.name, description: input.description, user_id: input.user_id,
          namespace_uuid: input.namespaceUuid, enable_api_key_auth: input.enableApiKeyAuth,
          enable_oauth: input.enableOauth, use_query_param_auth: input.useQueryParamAuth,
          enable_metamcp_admin_tools: input.enableMetamcpAdminTools,
        };
        db.endpoints.push(record);
        return trpc(res, record);
      }
      return send(res, { error: `unknown procedure ${procedure}` }, 404);
    } catch {
      return send(res, { error: 'fake API error' }, 500);
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  origin = `http://localhost:${port}`;
  return { server, db, port, origin, close: () => new Promise((resolve) => server.close(resolve)) };
}
async function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit peer registration '));
  const api = await fakeMetaApi();
  const source = makeState(root, 'source A', '1111111111111111', 12108, 'http://localhost:12108');
  const target = makeState(root, 'target B', '2222222222222222', api.port, api.origin);
  fs.writeFileSync(path.join(source.priv, 'client-api-key'), `${KEY}\n`, { mode: 0o600 });
  return { root, api, source, target, cleanup: async () => { await api.close(); fs.rmSync(root, { recursive: true, force: true }); } };
}

 test('registers only source A in target B, uses the selected endpoint and is idempotent', async () => {
  const f = await fixture();
  try {
    const endpoint = 'http://127.0.0.1:12108/metamcp/all/mcp';
    const prepared = await prepareMetaPeerRegistration(f.source, f.target, endpoint, { email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
    assert.equal(prepared.endpointName, 'all');
    assert.equal(prepared.sourceUrl, `http://mcpkit-meta-${f.source.id}:12008/metamcp/all/mcp`);
    assert.equal(prepared.sourceApiKey, KEY);
    await commitMetaPeerRegistration(prepared);

    assert.equal(f.api.db.calls.filter((item) => item.procedure === 'mcpServers.create').length, 1);
    assert.equal(f.api.db.calls.filter((item) => item.procedure === 'namespaces.create').length, 1);
    assert.equal(f.api.db.calls.filter((item) => item.procedure === 'endpoints.create').length, 1);
    assert.equal(f.api.db.servers.length, 1);
    assert.equal(f.api.db.namespaces.length, 1);
    assert.equal(f.api.db.endpoints.length, 1);
    const name = `mcpkit-meta-${f.source.id}-all`;
    const server = f.api.db.servers[0];
    assert.equal(server.name, name);
    assert.equal(server.url, prepared.sourceUrl);
    assert.deepEqual(server.headers, { 'X-API-Key': KEY });
    assert.equal(server.user_id, null);
    const namespace = f.api.db.namespaces[0];
    assert.equal(namespace.name, name);
    assert.deepEqual(namespace.serverUuids, [server.uuid]);
    assert.equal(namespace.user_id, null);
    const destinationEndpoint = f.api.db.endpoints[0];
    assert.equal(destinationEndpoint.name, name);
    assert.equal(destinationEndpoint.namespace_uuid, namespace.uuid);
    assert.equal(destinationEndpoint.enable_api_key_auth, true);
    assert.equal(destinationEndpoint.enable_oauth, false);
    assert.equal(destinationEndpoint.user_id, null);
    assert.equal(f.api.db.calls.some((item) => item.procedure.endsWith('.create') && item.input?.url?.includes(f.source.appUrl)), false);

    const journalPath = path.join(f.target.priv, 'metamcp-peer-registrations');
    const journalFile = path.join(journalPath, fs.readdirSync(journalPath)[0]);
    const journal = fs.readFileSync(journalFile, 'utf8');
    assert.doesNotMatch(journal, new RegExp(KEY));

    const retried = await prepareMetaPeerRegistration(f.source, f.target, 'all', { email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
    await commitMetaPeerRegistration(retried);
    assert.equal(f.api.db.servers.length, 1);
    assert.equal(f.api.db.namespaces.length, 1);
    assert.equal(f.api.db.endpoints.length, 1);
  } finally { await f.cleanup(); }
});

test('does not adopt a conflicting MetaMCP record by name', async () => {
  const f = await fixture();
  try {
    const name = `mcpkit-meta-${f.source.id}-all`;
    f.api.db.servers.push({ uuid: crypto.randomUUID(), name, user_id: null });
    const prepared = await prepareMetaPeerRegistration(f.source, f.target, 'all', { email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
    await assert.rejects(commitMetaPeerRegistration(prepared), /already in use; it was not adopted or changed/);
    assert.equal(f.api.db.servers.length, 1);
    assert.equal(f.api.db.namespaces.length, 0);
    assert.equal(f.api.db.endpoints.length, 0);
    assert.equal(f.api.db.calls.filter((item) => item.procedure.endsWith('.create')).length, 0);
  } finally { await f.cleanup(); }
});

test('validates that a full endpoint URL belongs to source A', async () => {
  const f = await fixture();
  try {
    assert.equal(resolveMetaPeerEndpoint(f.source, 'all').name, 'all');
    assert.throws(() => resolveMetaPeerEndpoint(f.source, 'http://127.0.0.1:12109/metamcp/all/mcp'), /does not belong/);
    assert.throws(() => resolveMetaPeerEndpoint(f.source, 'http://127.0.0.1:12108/metamcp/all/sse'), /form \/metamcp/);
  } finally { await f.cleanup(); }
});
