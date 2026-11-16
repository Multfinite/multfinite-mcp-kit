// Verify the pure LAN-conversion helpers and the early argument checks of
// set-lan. No Docker daemon, MetaMCP checkout, or network access is required.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { lanEnabledState, validateLanIp, withAppUrl } from '../common/metamcp-lan-enable.mjs';
import { LAN_PATCH_VERSION } from '../common/metamcp-lan-source.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const baseState = {
  version: 1, type: 'meta', id: 'a'.repeat(16), project: `mcpkit-meta-${'a'.repeat(16)}`,
  base: '/home/common/metamcp/local-vmhost', port: 12208, appUrl: 'http://127.0.0.1:12208', revision: 'x',
};

test('validateLanIp accepts only literal RFC 1918 IPv4 addresses', () => {
  assert.equal(validateLanIp('192.168.100.11'), '192.168.100.11');
  assert.equal(validateLanIp('10.0.0.5'), '10.0.0.5');
  assert.equal(validateLanIp('172.16.1.1'), '172.16.1.1');
  for (const bad of ['8.8.8.8', '172.32.0.1', '127.0.0.1', '0.0.0.0', 'localhost', '192.168.100', '192.168.100.11/32', undefined]) {
    assert.throws(() => validateLanIp(bad), /LAN IP must be/);
  }
});

test('lanEnabledState converts a loopback MetaMCP and keeps identity fields', () => {
  const next = lanEnabledState(baseState, '192.168.100.11');
  assert.equal(next.lanIp, '192.168.100.11');
  assert.equal(next.lanPatch, LAN_PATCH_VERSION);
  assert.equal(next.appUrl, 'http://192.168.100.11:12208');
  assert.equal(next.id, baseState.id);
  assert.equal(next.project, baseState.project);
  assert.equal(next.port, baseState.port);
  assert.equal(baseState.lanIp, undefined, 'the input state must not be mutated');
});

test('lanEnabledState is idempotent for the same address and refuses a different one', () => {
  const enabled = lanEnabledState(baseState, '192.168.100.11');
  assert.equal(lanEnabledState(enabled, '192.168.100.11'), enabled);
  assert.throws(() => lanEnabledState(enabled, '192.168.100.12'), /already uses LAN address 192.168.100.11/);
});

test('lanEnabledState refuses non-MetaMCP state', () => {
  assert.throws(() => lanEnabledState({ ...baseState, type: 'global' }, '192.168.100.11'), /only to MetaMCP/);
});

test('withAppUrl replaces only the APP_URL line and keeps other entries', () => {
  const env = [
    `POSTGRES_PASSWORD=${'1'.repeat(64)}`,
    `BETTER_AUTH_SECRET=${'2'.repeat(64)}`,
    "APP_URL='http://127.0.0.1:12208'",
    'METAMCP_ADMIN_EMAILS=admin@example.org',
    'EXTRA_TRUSTED_ORIGINS=',
    '',
  ].join('\n');
  const out = withAppUrl(env, 'http://192.168.100.11:12208');
  assert.equal(out, env.replace("APP_URL='http://127.0.0.1:12208'", "APP_URL='http://192.168.100.11:12208'"));
});

test('withAppUrl appends APP_URL when absent and rejects duplicates', () => {
  const out = withAppUrl('POSTGRES_PASSWORD=x\n', 'http://192.168.100.11:12208');
  assert.equal(out, "POSTGRES_PASSWORD=x\nAPP_URL='http://192.168.100.11:12208'\n");
  assert.throws(() => withAppUrl("APP_URL='http://a:1'\nAPP_URL='http://b:1'\n", 'http://192.168.100.11:12208'), /Multiple APP_URL/);
});

test('set-lan rejects missing LAN options before touching any directory', () => {
  const run = (args) => spawnSync(process.execPath, [`${root}common/stack.mjs`, 'set-lan', '--dir', '/nonexistent-mcpkit-test', '--expect-type', 'meta', ...args], { encoding: 'utf8' });
  const missingIp = run(['--allow-insecure-lan']);
  assert.notEqual(missingIp.status, 0);
  assert.match(missingIp.stderr, /set-lan requires --lan-ip/);
  const missingAck = run(['--lan-ip', '192.168.100.11']);
  assert.notEqual(missingAck.status, 0);
  assert.match(missingAck.stderr, /set-lan requires --lan-ip/);
  const extra = run(['--lan-ip', '192.168.100.11', '--allow-insecure-lan', '--port', '12300']);
  assert.notEqual(extra.status, 0);
  assert.match(extra.stderr, /only accepted for new installations|accepts no other install options/);
});
