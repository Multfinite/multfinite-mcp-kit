// Local, disposable Git repository plus a simulated Docker Desktop CLI.
// The real Compose binary can optionally resolve the supplied YAML, but no
// actual container, image, Windows executable or Docker daemon is touched.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const fixtureDir = path.dirname(fileURLToPath(import.meta.url));
const sourceWindows = fileURLToPath(new URL('../../windows/', import.meta.url));
const gitExecutable = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const writeJson = (file, value) => fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
function git(cwd, ...args) {
  const result = spawnSync(gitExecutable, args, { cwd, encoding: 'utf8', env: { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } });
  assert.equal(result.status, 0, `fixture git failed: ${result.stderr}`);
  return result.stdout.trim();
}
export function prepareDockerFixture(root, bin, windowsDir = path.join(root, 'checkout with spaces/windows')) {
  assert.ok(gitExecutable, 'git is required for the synthetic MetaMCP clone');
  fs.mkdirSync(bin, { recursive: true });
  fs.cpSync(sourceWindows, windowsDir, { recursive: true });
  const upstream = path.join(root, 'synthetic upstream with spaces');
  fs.mkdirSync(upstream, { recursive: true });
  fs.copyFileSync(path.join(fixtureDir, 'metamcp-upstream-compose.yml'), path.join(upstream, 'docker-compose.yml'));
  fs.writeFileSync(path.join(upstream, 'Dockerfile'), 'FROM scratch\n');
  git(upstream, 'init', '--quiet');
  git(upstream, 'add', 'Dockerfile', 'docker-compose.yml');
  git(upstream, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'fixture');
  const revision = git(upstream, 'rev-parse', 'HEAD');
  const manifestFile = path.join(windowsDir, 'manifest.json');
  const manifest = readJson(manifestFile);
  manifest.metamcp.repository = upstream;
  manifest.metamcp.revision = revision;
  writeJson(manifestFile, manifest);
  const gitExe = path.join(bin, 'git.exe');
  if (fs.existsSync(gitExe)) fs.unlinkSync(gitExe);
  fs.symlinkSync(gitExecutable, gitExe);
  const docker = path.join(bin, 'docker.exe');
  fs.copyFileSync(path.join(fixtureDir, 'fake-docker.cjs'), docker); fs.chmodSync(docker, 0o755);
  return {
    windowsDir,
    runner: path.join(windowsDir, 'run-local.ps1'),
    installer: path.join(windowsDir, 'install-local.ps1'),
    manifestFile,
    env: {
      MCP_TEST_DOCKER_STATE: path.join(root, 'fake-docker-state.json'),
      MCP_TEST_DOCKER_TRACE: path.join(root, 'fake-docker-trace.jsonl'),
      MCP_TEST_CAPTURE: path.join(root, 'private-sql-bundle.json'),
      ...(process.env.MCP_TEST_REAL_COMPOSE ? { MCP_TEST_REAL_COMPOSE: process.env.MCP_TEST_REAL_COMPOSE } : {}),
    },
  };
}
