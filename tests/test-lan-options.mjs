// LAN publication changes the app origin, so the option must stay limited to
// the two commands that can validate it, and must never run without the
// explicit insecure-HTTP acknowledgement.
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const stack = path.join(root, 'common', 'stack.mjs');
const run = (...args) => spawnSync(process.execPath, [stack, ...args], { encoding: 'utf8', timeout: 60000 });

test('LAN options are rejected for commands that cannot apply them', () => {
  const result = run('start', '--dir', path.join(root, 'does-not-exist'), '--lan-ip', '192.168.100.10', '--allow-insecure-lan');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /LAN options are only available for init-meta and apply/);
});

test('apply refuses LAN publication without the insecure-HTTP acknowledgement', () => {
  const result = run('apply', '--dir', path.join(root, 'does-not-exist'), '--allow-insecure-lan');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /--allow-insecure-lan requires --lan-ip/);
});
