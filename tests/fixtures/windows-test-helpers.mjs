import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const sourceWindows = fileURLToPath(new URL('../../windows/', import.meta.url));

export function prepareWindowsFixture(root, bin, windowsDir = path.join(root, 'checkout with spaces/windows')) {
  fs.mkdirSync(bin, { recursive: true });
  fs.cpSync(sourceWindows, windowsDir, { recursive: true });
  const git = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
  if (git) fs.symlinkSync(git, path.join(bin, 'git.exe'));
  const docker = path.join(bin, 'docker.exe');
  const trace = path.join(root, 'docker-should-not-run.log');
  fs.writeFileSync(docker, '#!/bin/sh\nprintf called >> "$MCP_TEST_DOCKER_TRACE"\nexit 91\n', { mode: 0o755 });
  return {
    windowsDir,
    runner: path.join(windowsDir, 'run-local.ps1'),
    installer: path.join(windowsDir, 'install-local-server.ps1'),
    env: { MCP_TEST_DOCKER_TRACE: trace },
  };
}
