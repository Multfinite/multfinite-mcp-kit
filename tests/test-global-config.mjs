// GLOBAL containers render kit files at start-up. A template can only be
// applied when the container is recreated, and every variable it interpolates
// must actually be passed by the Compose service.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

function composeServiceBlock(compose, name) {
  const lines = compose.split(/\r?\n/);
  const start = lines.findIndex((line) => line === `  ${name}:`);
  assert.notEqual(start, -1, `service ${name} is missing from global-compose.yml`);
  const block = [];
  for (const line of lines.slice(start + 1)) {
    if (/^ {2}[a-z0-9-]+:$/.test(line) || /^\S/.test(line)) break;
    block.push(line);
  }
  return block.join('\n');
}

test('every variable the llm-proxy template interpolates is passed by its service', () => {
  const template = read('common/llm-proxy/nginx.conf.template');
  const block = composeServiceBlock(read('common/global-compose.yml'), 'llm-proxy');
  const names = new Set([...template.matchAll(/\$\{(MCPKIT_[A-Z0-9_]+)\}/g)].map((match) => match[1]));
  assert.ok(names.size > 0, 'the template must interpolate at least one MCPKIT_ variable');
  for (const name of names) assert.match(block, new RegExp(`\\b${name}:`), `${name} is used by the template but not provided to llm-proxy`);
});

test('GLOBAL apply recreates the containers that embed kit configuration', () => {
  const stack = read('common/stack.mjs');
  const globalApply = /console\.log\('Recreating only[^']*'\);\s*compose\(ctx, state, \['up', '-d', '--no-deps', '--force-recreate', '--no-build'([\s\S]*?)\]\);/.exec(stack);
  assert.ok(globalApply, 'the GLOBAL apply branch must recreate containers explicitly');
  for (const service of ['gateway', 'llm-proxy', 'embeddings', 'graphiti', 'cognee']) {
    assert.match(globalApply[1], new RegExp(`'${service}'`), `${service} must be recreated by apply`);
  }
});
