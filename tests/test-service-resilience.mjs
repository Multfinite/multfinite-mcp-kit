// Two independent things have to hold for kit services to survive a logon:
// no competing system unit may stop the containers, and a WSL session holder
// must keep the systemd user manager alive. These are static checks on the
// shipped helpers and the documented entry points.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

test('a helper detects and removes system-level units that duplicate a kit MetaMCP', () => {
  const file = path.join(root, 'linux', 'fix-legacy-metamcp-units.sh');
  assert.equal(fs.existsSync(file), true, 'linux/fix-legacy-metamcp-units.sh must be shipped');
  const script = read('linux/fix-legacy-metamcp-units.sh');
  // The reported symptom comes from Type=forking plus Restart=on-failure.
  assert.match(script, /run-metamcp\\?\.sh/);
  assert.match(script, /--remove/);
  // Removal must be reversible and must not touch kit-owned units.
  assert.match(script, /mcpkit-managed-service/);
  assert.match(script, /var\/backups\/mcpkit-legacy-units/);
  assert.match(script, /systemctl daemon-reload/);
});

test('service registration warns about a competing system unit', () => {
  const script = read('linux/service-registration.sh');
  assert.match(script, /mcpkit_warn_legacy_system_units/);
  assert.match(script, /fix-legacy-metamcp-units\.sh/);
});

test('the WSL keepalive helper holds a session and repairs kit units', () => {
  const script = read('windows/wsl-keepalive.ps1');
  assert.match(script, /sleep infinity/);
  assert.match(script, /mcpkit-managed-service/);
  assert.match(script, /systemctl --user restart/);
  assert.match(script, /Win32_Process/);
  // A repeating, short pass replaces the long-lived holder that Task Scheduler
  // terminated with 0xC000013A.
  assert.match(script, /-Register/);
  assert.match(script, /RepetitionInterval/);
});

test('the autostart guide names the helper and the legacy-unit pitfall', () => {
  const doc = read('docs/wsl-autostart.md');
  assert.match(doc, /wsl-keepalive\.ps1 -Distribution Debian -Register/);
  assert.match(doc, /fix-legacy-metamcp-units\.sh/);
  assert.match(doc, /user@1000/);
});
