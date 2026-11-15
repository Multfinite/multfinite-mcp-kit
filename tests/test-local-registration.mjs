import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadLocalBundle } from '../common/local-registration.mjs';

function makeLocal({ marker = 'none', linkedMeta = false, key = 'a'.repeat(64) } = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit local registration '));
  const config = path.join(base, 'config');
  const privateDir = path.join(config, 'private');
  fs.mkdirSync(privateDir, { recursive: true });
  const settings = { version: 1, hostId: 'workstation-abc123', listenHost: '127.0.0.1', port: 13001 };
  fs.writeFileSync(path.join(config, 'local-settings.json'), `${JSON.stringify(settings)}\n`);
  fs.writeFileSync(path.join(privateDir, 'secrets.json'), `${JSON.stringify({ gatewayApiKey: key })}\n`);
  if (marker === 'independent') fs.writeFileSync(path.join(privateDir, 'independent-windows-kit.json'), `${JSON.stringify({ version: 1, kind: 'windows-local', base })}\n`);
  if (linkedMeta) fs.writeFileSync(path.join(privateDir, 'metamcp-state.json'), '{}\n');
  return { base, config, privateDir };
}

test('accepts the current native-only Windows LOCAL layout and preserves GLOBAL-style names', () => {
  const f = makeLocal();
  try {
    const bundle = loadLocalBundle(f.base, 'win32');
    assert.equal(bundle.id, 'workstation-abc123');
    assert.equal(bundle.key, 'a'.repeat(64));
    assert.equal(Object.keys(bundle.groups).length, 13);
    assert.equal(bundle.groups['desktop-commander'][0], 'desktop-commander');
    assert.equal(bundle.serverNames.filesystem, 'filesystem-mcp');
    assert.equal(bundle.groupNames.filesystem, 'filesystem-mcp');
    assert.ok(bundle.groups['windows-mcp']);
    assert.equal(bundle.groups['linux-desktop'], undefined);
  } finally { fs.rmSync(f.base, { recursive: true, force: true }); }
});

test('accepts the marked independent Windows LOCAL layout', () => {
  const f = makeLocal({ marker: 'independent' });
  try { assert.equal(loadLocalBundle(f.base, 'win32').id, 'workstation-abc123'); }
  finally { fs.rmSync(f.base, { recursive: true, force: true }); }
});

test('refuses the old linked Windows MetaMCP layout and invalid secrets', () => {
  const linked = makeLocal({ linkedMeta: true });
  try { assert.throws(() => loadLocalBundle(linked.base, 'win32'), /legacy-linked/); }
  finally { fs.rmSync(linked.base, { recursive: true, force: true }); }
  const invalid = makeLocal({ key: 'not-a-key' });
  try { assert.throws(() => loadLocalBundle(invalid.base, 'win32'), /Invalid LOCAL settings or gateway key/); }
  finally { fs.rmSync(invalid.base, { recursive: true, force: true }); }
});

test('requires an independent Linux LOCAL marker that matches hostId and directory', () => {
  const f = makeLocal();
  const markerFile = path.join(f.privateDir, 'linux-kit.json');
  try {
    assert.throws(() => loadLocalBundle(f.base, 'linux'), /marker is missing/);
    fs.writeFileSync(markerFile, `${JSON.stringify({ version: 1, hostId: 'different', base: f.base })}\n`);
    assert.throws(() => loadLocalBundle(f.base, 'linux'), /Invalid LOCAL settings or gateway key/);
    fs.writeFileSync(markerFile, `${JSON.stringify({ version: 1, hostId: 'workstation-abc123', base: f.base })}\n`);
    assert.ok(loadLocalBundle(f.base, 'linux').groups['linux-desktop']);
  } finally { fs.rmSync(f.base, { recursive: true, force: true }); }
});

test('resolves a deliberate Windows LOCAL root junction while still validating the target', (t) => {
  const f = makeLocal({ marker: 'independent' });
  const alias = path.join(path.dirname(f.base), `mcpkit local alias ${path.basename(f.base)}`);
  try {
    try { fs.symlinkSync(f.base, alias, process.platform === 'win32' ? 'junction' : 'dir'); }
    catch (error) { if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) { t.skip('directory links are unavailable'); return; } throw error; }
    const bundle = loadLocalBundle(alias, 'win32');
    assert.equal(bundle.privateDir, path.join(fs.realpathSync(alias), 'config', 'private'));
    assert.throws(() => loadLocalBundle(alias, 'linux'), /must not be a link/);
  } finally {
    fs.rmSync(alias, { recursive: true, force: true });
    fs.rmSync(f.base, { recursive: true, force: true });
  }
});

test('refuses linked settings and secrets instead of following them', (t) => {
  const f = makeLocal();
  const target = path.join(f.base, 'secrets-target.json');
  const secrets = path.join(f.privateDir, 'secrets.json');
  try {
    fs.writeFileSync(target, `${JSON.stringify({ gatewayApiKey: 'a'.repeat(64) })}\n`);
    fs.unlinkSync(secrets);
    try { fs.symlinkSync(target, secrets); }
    catch (error) { if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) { t.skip('symlinks are unavailable'); return; } throw error; }
    assert.throws(() => loadLocalBundle(f.base, 'win32'), /must be a regular file, not a link/);
  } finally { fs.rmSync(f.base, { recursive: true, force: true }); }
});
