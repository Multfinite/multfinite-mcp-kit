import assert from 'node:assert/strict';
import test from 'node:test';
import { kitDescription, isKitRecord, serverUpdateBody, namespaceUpdateBody } from '../common/register-update.mjs';

const UUID = '11111111-1111-4111-8111-111111111111';
const NS_UUID = '22222222-2222-4222-8222-222222222222';
const KEY = 'a'.repeat(64);

function existingServer(overrides = {}) {
  return {
    uuid: UUID, name: 'DesktopCommanderMCP', description: kitDescription('local', 'desktop-commander'),
    type: 'STREAMABLE_HTTP', command: null, args: [], env: {}, url: 'http://192.168.100.1:13001/servers/desktop-commander/mcp',
    created_at: '2026-11-16T10:47:46Z', bearerToken: null, headers: { 'X-API-Key': KEY }, forward_headers: {}, user_id: null,
    ...overrides,
  };
}
const desired = (url) => ({ name: 'DesktopCommanderMCP', description: kitDescription('local', 'desktop-commander'), type: 'STREAMABLE_HTTP',
  url, headers: { 'X-API-Key': KEY } });

test('kit record is recognised only when public and described by this kit', () => {
  assert.equal(isKitRecord(existingServer(), 'local', 'desktop-commander'), true);
  assert.equal(isKitRecord(existingServer({ user_id: 'someone' }), 'local', 'desktop-commander'), false, 'private record must not be adopted');
  assert.equal(isKitRecord(existingServer({ description: 'hand made' }), 'local', 'desktop-commander'), false);
  assert.equal(isKitRecord(existingServer(), 'global', 'desktop-commander'), false, 'profile must match');
  assert.equal(isKitRecord(null, 'local', 'x'), false);
});

test('stale gateway address is rewritten and nothing else is sent unnecessarily', () => {
  const body = serverUpdateBody(existingServer(), desired('http://192.168.100.10:13001/servers/desktop-commander/mcp'));
  assert.equal(body.uuid, UUID);
  assert.equal(body.url, 'http://192.168.100.10:13001/servers/desktop-commander/mcp');
  assert.equal(body.user_id, null);
  assert.deepEqual(body.headers, { 'X-API-Key': KEY });
  for (const [key, value] of Object.entries(body)) if (key !== 'user_id') assert.notEqual(value, null, `${key} must not be null`);
  assert.equal(Object.hasOwn(body, 'command'), false);
  assert.equal(Object.hasOwn(body, 'bearerToken'), false);
});

test('an up-to-date record produces no update call', () => {
  const current = existingServer();
  assert.equal(serverUpdateBody(current, desired(current.url)), null);
});

test('user-set bearer token and extra headers are preserved when the URL changes', () => {
  const current = existingServer({ bearerToken: 'secret-token', headers: { 'X-API-Key': KEY, 'X-Team': 'ops' }, url: 'https://old.example/mcp' });
  const body = serverUpdateBody(current, desired('https://api.githubcopilot.com/mcp/'));
  assert.equal(body.bearerToken, 'secret-token');
  assert.deepEqual(body.headers, { 'X-API-Key': KEY, 'X-Team': 'ops' });
});

test('GitHub entry without desired headers keeps the existing headers and token', () => {
  const current = existingServer({ name: 'github-mcp-server', url: 'https://old/mcp', headers: {}, bearerToken: 'gh-token', description: kitDescription('global', 'github-mcp-server') });
  const body = serverUpdateBody(current, { name: 'github-mcp-server', description: kitDescription('global', 'github-mcp-server'), type: 'STREAMABLE_HTTP', url: 'https://api.githubcopilot.com/mcp/' });
  assert.equal(body.bearerToken, 'gh-token');
  assert.equal(body.url, 'https://api.githubcopilot.com/mcp/');
  assert.deepEqual(body.headers, {});
});

test('namespace membership and description are reconciled', () => {
  const ns = { uuid: NS_UUID, name: 'desktop', description: kitDescription('local', 'desktop') };
  const same = namespaceUpdateBody(ns, { name: 'desktop', description: kitDescription('local', 'desktop'), serverUuids: ['b', 'a'], actualServerUuids: ['a', 'b'] });
  assert.equal(same, null);
  const changed = namespaceUpdateBody(ns, { name: 'desktop', description: kitDescription('local', 'desktop'), serverUuids: ['a', 'c'], actualServerUuids: ['a', 'b'] });
  assert.deepEqual(changed.mcpServerUuids, ['a', 'c']);
  assert.equal(changed.uuid, NS_UUID);
  assert.equal(changed.user_id, null);
});
