// MetaMCP source must remain upstream-owned and unmodified by the kit.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

test('Linux lifecycle builds only from a clean pinned upstream clone and never patches it', () => {
  const stack = read('common/stack.mjs');
  assert.doesNotMatch(stack, /metamcp-lan-source|ensurePatchedSource|single-server-per-endpoint-patch|clean-tools-patch|MCPKIT_CLEAN_TOOL_NAMES|MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT/);
  assert.match(stack, /status', '--porcelain', '--untracked-files=all'/);
  // Запрет по умолчанию остаётся; сборка с локальными правками возможна только явно.
  assert.match(stack, /if \(!allowLocalSource\)/);
  assert.match(stack, /--allow-local-source/);
  assert.match(stack, /will not match the pinned revision/);
});

test('MetaMCP Compose overlays contain no source-patch features', () => {
  const compose = read('common/metamcp-compose.yml');
  const lan = read('common/metamcp-lan.yml');
  assert.doesNotMatch(`${compose}\n${lan}`, /single-server-per-endpoint-patch|clean-tools-patch|lan-patch|MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT|MCPKIT_CLEAN_TOOL_NAMES|MCPKIT_MULTI_AUTH_ORIGINS|MCPKIT_COOKIE_PREFIX|NEXT_PUBLIC_MCPKIT_MULTI_ORIGIN/);
  assert.match(compose, /context: \$\{MCPKIT_SOURCE\}/);
  assert.match(lan, /\$\{MCPKIT_LAN_IP\}:\$\{MCPKIT_PORT\}:12008/);
});

test('the clean-tools overlay and source patch module are not shipped', () => {
  assert.equal(fs.existsSync(path.join(root, 'common/metamcp-lan-source.mjs')), false);
  assert.equal(fs.existsSync(path.join(root, 'common/metamcp-clean-tools.yml')), false);
  assert.doesNotMatch(read('linux/install-metamcp.sh'), /clean-tools/);
});
