import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const exists = (relative) => fs.existsSync(path.join(root, relative));
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

test('obsolete combined-install entrypoints and bundled LOCAL MetaMCP are removed', () => {
  for (const file of [
    'linux/install-global.sh', 'linux/run-global.sh', 'linux/register-local.sh',
    'linux/seed-global.sql', 'linux/seed-local.sql', 'linux/services/docker-compose.yml',
    'windows/install-servers.ps1', 'windows/run-servers.ps1', 'windows/metamcp-local.ps1',
    'windows/metamcp.local.yml', 'windows/metamcp-backend.local.yml', 'windows/seed-local.sql',
  ]) assert.equal(exists(file), false, `${file} must not be shipped`);
  for (const file of ['linux/install-global-servers.sh', 'linux/run-global-servers.sh', 'windows/install-metamcp.ps1', 'windows/run-metamcp.ps1']) {
    assert.equal(exists(file), true, `${file} is a current independent entrypoint`);
  }
  const localRunner = read('windows/run-local.ps1');
  assert.doesNotMatch(localRunner, /metamcp-local\.ps1|Start-MetaMcp|Repair-MetaSeed|reset-metamcp-records|uninstall-metamcp/);
});
