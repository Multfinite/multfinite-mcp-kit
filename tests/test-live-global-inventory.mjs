// The live GLOBAL reader verifies an existing project by service name, so its
// inventory must cover every Compose service; otherwise a real GLOBAL is
// rejected and the linked MetaMCP cannot start.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { globalServices, optionalGlobalServices } from '../common/live-global.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));

function composeServices(text) {
  const found = [];
  let inServices = false;
  let current = null;
  for (const line of text.split(/\r?\n/)) {
    if (/^services:/.test(line)) { inServices = true; continue; }
    if (!inServices) continue;
    if (/^\S/.test(line)) break;
    const header = /^ {2}([a-z0-9-]+):$/.exec(line);
    if (header) { current = { name: header[1], profiled: false }; found.push(current); continue; }
    if (current && /^ {4}profiles:/.test(line)) current.profiled = true;
  }
  return found;
}

test('the live GLOBAL inventory matches global-compose.yml exactly once per service', () => {
  const services = composeServices(fs.readFileSync(path.join(root, 'common/global-compose.yml'), 'utf8'));
  const required = services.filter((service) => !service.profiled).map((service) => service.name).sort();
  const optional = services.filter((service) => service.profiled).map((service) => service.name).sort();
  assert.ok(required.length > 0, 'global-compose.yml must declare services');
  assert.deepEqual([...globalServices].sort(), required);
  assert.deepEqual([...optionalGlobalServices].sort(), optional);
  assert.equal(new Set([...globalServices, ...optionalGlobalServices]).size,
    globalServices.length + optionalGlobalServices.length, 'no service may be verified twice');
});
