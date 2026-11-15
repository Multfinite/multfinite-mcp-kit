// Validate and read LOCAL gateway credentials for MetaMCP registration.
// This accepts both the marked independent installers and the current native-
// only Windows installer, which predates the independent-install marker.
import fs from 'node:fs';
import path from 'node:path';
import { localGroups, LOCAL_SERVER_NAMES, LOCAL_GROUP_NAMES } from './registration-manifest.mjs';

function fail(message) { throw new Error(message); }
function ordinaryFile(file, label) {
  let stat;
  try { stat = fs.lstatSync(file); } catch { fail(`${label} is missing.`); }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular file, not a link.`);
}
function ordinaryDirectory(dir, label) {
  let stat;
  try { stat = fs.lstatSync(dir); } catch { fail(`${label} is missing.`); }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a regular directory, not a link.`);
}
function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
  catch { fail(`Invalid LOCAL registration file: ${path.basename(file)}.`); }
}

export function loadLocalBundle(directory, platform = process.platform) {
  if (platform !== 'linux' && platform !== 'win32') fail('LOCAL registration supports Windows and Linux only.');
  const base = path.resolve(directory);
  ordinaryDirectory(base, 'LOCAL installation directory');
  const config = path.join(base, 'config');
  const privateDir = path.join(config, 'private');
  ordinaryDirectory(config, 'LOCAL config directory');
  ordinaryDirectory(privateDir, 'LOCAL private directory');

  const linux = platform === 'linux';
  const markerFile = path.join(privateDir, linux ? 'linux-kit.json' : 'independent-windows-kit.json');
  const settingsFile = path.join(config, 'local-settings.json');
  const secretsFile = path.join(privateDir, 'secrets.json');
  let marker = null;
  if (fs.existsSync(markerFile)) {
    ordinaryFile(markerFile, 'LOCAL ownership marker');
    marker = readJson(markerFile);
    if (marker.version !== 1 || (!linux && marker.kind !== 'windows-local') || typeof marker.base !== 'string' ||
        (linux ? marker.base !== base : marker.base.toLowerCase() !== base.toLowerCase())) {
      fail('Independent LOCAL marker is invalid or belongs to a different directory.');
    }
  } else if (linux) {
    fail('Independent Linux LOCAL marker is missing; run the LOCAL installer first.');
  }

  // A legacy Windows LOCAL directory that still owns a bundled MetaMCP is not
  // treated as a native-only source. Registration must point to the native
  // gateway, never to stale linked-stack configuration.
  if (!linux && fs.existsSync(path.join(privateDir, 'metamcp-state.json'))) {
    fail('A legacy-linked LOCAL directory is not accepted; use a native-only LOCAL installation.');
  }
  ordinaryFile(settingsFile, 'LOCAL settings');
  ordinaryFile(secretsFile, 'LOCAL gateway secrets');
  const settings = readJson(settingsFile);
  const secrets = readJson(secretsFile);
  if (settings.version !== 1 || typeof settings.hostId !== 'string' ||
      !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(settings.hostId) || settings.hostId.length > 32 ||
      (linux && marker.hostId !== settings.hostId) || !/^[a-f0-9]{64}$/.test(secrets.gatewayApiKey || '')) {
    fail('Invalid LOCAL settings or gateway key; run the LOCAL installer first.');
  }

  return {
    id: settings.hostId,
    key: secrets.gatewayApiKey,
    privateDir,
    groups: localGroups(linux),
    serverNames: LOCAL_SERVER_NAMES,
    groupNames: LOCAL_GROUP_NAMES,
  };
}
