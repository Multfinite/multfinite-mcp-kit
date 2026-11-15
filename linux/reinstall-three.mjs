#!/usr/bin/env node
// Rebuild three independent MetaMCP instances without deleting a GLOBAL kit.
// All destructive Docker operations are limited to explicitly identified Meta
// projects; preflight and a typed confirmation precede any deletion.
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { inspectLiveGlobal, startLiveGlobal, enableLiveGlobalRestart, liveGlobalStatus, connectLiveGlobal } from '../common/live-global.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [globalUrlText, lanIp, orphanProject] = process.argv.slice(2);
const specs = [
  { dir: '/metamcp/global-localhost', port: 12008, url: globalUrlText },
  { dir: '/metamcp/local-wslhost', port: 12108, lan: lanIp },
  { dir: '/metamcp/local-vmhost', port: 12208, lan: lanIp },
];
function fail(message) { throw new Error(message); }
function run(exe, args, { input, capture = false, allowFailure = false } = {}) {
  const result = spawnSync(exe, args, {
    encoding: 'utf8', windowsHide: true, maxBuffer: 16 * 1024 * 1024,
    stdio: [input === undefined ? 'ignore' : 'pipe', capture ? 'pipe' : 'inherit', capture ? 'pipe' : 'inherit'],
    ...(input === undefined ? {} : { input }),
  });
  if (result.error || (result.status !== 0 && !allowFailure)) fail(`${exe} did not complete successfully${result.status === null ? '' : ` (exit ${result.status})`}.`);
  return result;
}
function question(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(prompt, (answer) => { rl.close(); resolve(answer.trim()); });
  });
}
function secret(prompt) {
  return new Promise((resolve, reject) => {
    let value = '';
    let finished = false;
    process.stdout.write(prompt);
    const finish = (error) => {
      if (finished) return;
      finished = true;
      process.stdin.off('data', onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write('\n');
      if (error) reject(error); else resolve(value);
    };
    const onData = (chunk) => {
      for (const ch of String(chunk)) {
        if (ch === '\u0003') return finish(new Error('Отменено.'));
        if (ch === '\r' || ch === '\n') return finish();
        if (ch === '\u007f' || ch === '\b') value = Array.from(value).slice(0, -1).join('');
        else if (ch >= ' ' && value.length < 1024) value += ch;
      }
    };
    process.stdin.setEncoding('utf8');
    process.stdin.setRawMode(true);
    process.stdin.on('data', onData);
    process.stdin.resume();
  });
}
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function projectId(name, kind) {
  const match = new RegExp(`^mcpkit-${kind}-([a-f0-9]{16})$`).exec(name || '');
  if (!match) fail(`Неизвестный проект ${name}; ничего не удалено.`);
  return match[1];
}
function checkState(base, kind) {
  const dir = fs.lstatSync(base);
  if (!dir.isDirectory() || dir.isSymbolicLink() || fs.realpathSync(base) !== base) fail(`Каталог должен быть обычным, без символьных ссылок: ${base}`);
  const priv = fs.lstatSync(path.join(base, '.mcpkit'));
  if (!priv.isDirectory() || priv.isSymbolicLink()) fail(`Неверный служебный каталог: ${base}`);
  const stateFile = path.join(base, '.mcpkit', 'state.json');
  if (!fs.lstatSync(stateFile).isFile() || fs.lstatSync(stateFile).isSymbolicLink()) fail(`Неверный state.json: ${base}`);
  const state = readJson(stateFile);
  const id = projectId(state.project, kind);
  if (state.version !== 1 || state.type !== kind || state.id !== id || state.base !== base || !Number.isInteger(state.port)) fail(`Состояние не принадлежит ${base}; оно сохранено.`);
  return state;
}
function mountpoints() {
  // Decode the escaped mountpoint field rather than follow a nested mount when
  // removing an owned directory. Never delete across another filesystem.
  return fs.readFileSync('/proc/self/mountinfo', 'utf8').trim().split('\n').map((line) => line.split(' ')[4].replace(/\\([0-7]{3})/g, (_, oct) => String.fromCharCode(parseInt(oct, 8))));
}
function checkNoMount(base) {
  if (mountpoints().some((target) => target === base || target.startsWith(`${base}/`))) fail(`В ${base} есть смонтированная файловая система; каталог не удалён.`);
}
function markerFor(spec, state) {
  const staged = path.join(spec.dir, '.mcpkit', 'first-setup.json');
  const owned = path.join(spec.dir, '.mcpkit', 'reinstall-three.json');
  const markerPath = fs.existsSync(staged) ? staged : fs.existsSync(owned) ? owned : null;
  if (!markerPath) return null;
  if (!fs.lstatSync(markerPath).isFile() || fs.lstatSync(markerPath).isSymbolicLink()) fail(`Неверный маркер ${markerPath}.`);
  const marker = readJson(markerPath);
  if (marker.version !== 1 || marker.project !== state.project || typeof marker.adminEmail !== 'string') fail(`Маркер не принадлежит ${state.project}.`);
  const expectedUrl = spec.lan ? `http://${spec.lan}:${spec.port}` : spec.url;
  if (state.port !== spec.port || state.appUrl !== expectedUrl || (state.lanIp || '') !== (spec.lan || '') || state.cleanTools !== true || state.cleanToolsPatch !== '1') fail(`Созданный экземпляр ${spec.dir} имеет другую конфигурацию; он сохранён.`);
  return { ...marker, staged: markerPath === staged };
}
function privateWrite(file, content) { fs.writeFileSync(file, content, { flag: 'wx', mode: 0o600 }); }
async function portAvailable(host, port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', (error) => error.code === 'EADDRINUSE' ? resolve(false) : reject(error));
    server.listen({ host, port, exclusive: true }, () => server.close((error) => error ? reject(error) : resolve(true)));
  });
}
function enableDockerBoot(endpoint) {
  if (endpoint !== 'unix:///var/run/docker.sock' || !fs.existsSync('/run/systemd/system')) {
    fail('Автоматически включить запуск Docker можно только для системной службы docker.service и локального /var/run/docker.sock. Старые MetaMCP не удалены.');
  }
  const enabled = () => run('systemctl', ['is-enabled', 'docker.service'], { capture: true, allowFailure: true }).stdout.trim() === 'enabled';
  if (!enabled()) {
    console.log('Для включения Docker при загрузке может потребоваться пароль sudo.');
    const root = process.getuid?.() === 0;
    const command = root ? 'systemctl' : 'sudo';
    const args = root ? ['enable', 'docker.service'] : ['systemctl', 'enable', 'docker.service'];
    const result = spawnSync(command, args, { stdio: 'inherit' });
    if (result.error || result.status !== 0 || !enabled()) fail('Не удалось включить Docker при загрузке; старые MetaMCP не удалены.');
  }
}

try {
  if (process.platform !== 'linux' || Number(process.versions.node.split('.')[0]) < 20) fail('Нужен Linux и Node.js 20+.');
  if (!process.stdin.isTTY || !process.stdout.isTTY) fail('Запустите команду в интерактивной консоли.');
  if (process.env.DOCKER_HOST || process.env.DOCKER_CONTEXT) fail('Снимите DOCKER_HOST и DOCKER_CONTEXT; удалённый Docker не используется.');
  let external;
  try { external = new URL(globalUrlText); } catch { fail('Укажите внешний HTTPS origin GLOBAL.'); }
  if (external.protocol !== 'https:' || external.username || external.password || external.pathname !== '/' || external.search || external.hash || external.origin !== globalUrlText) fail('GLOBAL адрес должен быть HTTPS origin без пути и параметров.');
  if (net.isIP(lanIp || '') !== 4) fail('Укажите LAN IPv4 адрес этого хоста.');
  const [a, b] = lanIp.split('.').map(Number);
  if (!(a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168))) fail('LAN IPv4 должен относиться к частной сети RFC 1918.');
  if (!Object.values(os.networkInterfaces()).flat().some((item) => item && item.family === 'IPv4' && item.address === lanIp)) fail('LAN IPv4 не назначен этому хосту.');
  if (orphanProject) projectId(orphanProject, 'meta');
  run('git', ['--version'], { capture: true });
  const version = run('docker', ['compose', 'version', '--short'], { capture: true }).stdout.trim();
  const parts = /^v?(\d+)\.(\d+)\.(\d+)/.exec(version);
  if (!parts || Number(parts[1]) < 2 || (Number(parts[1]) === 2 && (Number(parts[2]) < 24 || (Number(parts[2]) === 24 && Number(parts[3]) < 4)))) fail('Для безопасной подготовки нужен Docker Compose 2.24.4 или новее.');
  const context = run('docker', ['context', 'show'], { capture: true }).stdout.trim();
  const endpoint = run('docker', ['context', 'inspect', context, '--format', '{{.Endpoints.docker.Host}}'], { capture: true }).stdout.trim();
  if (!/^unix:\/\/\//.test(endpoint)) fail('Нужен локальный Docker с Unix-сокетом.');
  const info = run('docker', ['--context', context, 'info'], { capture: true, allowFailure: true });
  if (info.status !== 0) {
    if (endpoint !== 'unix:///var/run/docker.sock' || !fs.existsSync('/run/systemd/system')) fail('Локальный Docker недоступен; ничего не удалено.');
    console.log('Пробуем запустить системную службу Docker; может потребоваться sudo.');
    const rootUser = process.getuid?.() === 0;
    const started = spawnSync(rootUser ? 'systemctl' : 'sudo', rootUser ? ['start', 'docker.service'] : ['systemctl', 'start', 'docker.service'], { stdio: 'inherit' });
    if (started.error || started.status !== 0 || run('docker', ['--context', context, 'info'], { capture: true, allowFailure: true }).status !== 0) fail('Docker недоступен или нет прав на сокет; ничего не удалено.');
  }
  const metaRoot = path.dirname(specs[0].dir);
  if (fs.realpathSync(metaRoot) !== metaRoot || !fs.lstatSync(metaRoot).isDirectory() || fs.lstatSync(metaRoot).isSymbolicLink()) fail('Каталог /metamcp должен быть обычным каталогом без ссылок.');
  fs.accessSync(metaRoot, fs.constants.W_OK | fs.constants.X_OK);
  const docker = (...args) => run('docker', ['--context', context, ...args], { capture: true }).stdout.trim();
  const list = (text) => text ? text.split(/\s+/).filter(Boolean) : [];
  const inspect = (kind, name) => {
    try { return JSON.parse(docker(kind, 'inspect', name))[0]; } catch { fail(`Не удалось проверить ${kind} ${name}; ничего не удалено.`); }
  };
  const labelsOf = (kind, item) => kind === 'container' ? item.Config?.Labels || {} : item.Labels || {};
  function checkLabels(kind, item, project, name) {
    const labels = labelsOf(kind, item), id = projectId(project, 'meta');
    if (labels['com.docker.compose.project'] !== project || labels['com.multfinite.mcpkit.instance'] !== id) fail(`${kind} ${name} имеет чужие или отсутствующие метки; он сохранён.`);
  }
  function ensureMetaRestart(state) {
    const ids = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${state.project}`));
    const services = new Map();
    for (const id of ids) {
      const item = inspect('container', id);
      checkLabels('container', item, state.project, id);
      const labels = item.Config?.Labels || {};
      if (String(labels['com.docker.compose.oneoff'] || '').toLowerCase() === 'true') continue;
      const name = labels['com.docker.compose.service'];
      if (!['app', 'postgres'].includes(name) || services.has(name) || !item.State?.Running) fail(`Сервисы ${state.project} имеют неожиданное состояние; автозапуск не изменён.`);
      services.set(name, item);
    }
    if (services.size !== 2) fail(`Сервисы ${state.project} неполны; автозапуск не изменён.`);
    const update = [...services.values()].filter((item) => item.HostConfig?.RestartPolicy?.Name !== 'unless-stopped');
    if (update.length) run('docker', ['--context', context, 'container', 'update', '--restart', 'unless-stopped', ...update.map((item) => item.Id)]);
    for (const item of services.values()) {
      const after = inspect('container', item.Id);
      checkLabels('container', after, state.project, item.Id);
      if (!after.State?.Running || after.HostConfig?.RestartPolicy?.Name !== 'unless-stopped') fail(`Не удалось подтвердить автозапуск ${state.project}.`);
    }
  }
  const gateways = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', 'label=com.docker.compose.service=gateway'));
  const globals = gateways.map((id) => ({ id, detail: inspect('container', id) })).filter(({ detail }) => /^mcpkit-global-[a-f0-9]{16}$/.test(detail.Config?.Labels?.['com.docker.compose.project'] || ''));
  if (globals.length !== 1) fail('Не удалось однозначно определить установленный независимый GLOBAL. Его данные и MetaMCP не изменены.');
  const globalItem = globals[0];
  const globalLabels = globalItem.detail.Config.Labels;
  const globalProject = globalLabels['com.docker.compose.project'];
  const globalId = projectId(globalProject, 'global');
  if (globalLabels['com.multfinite.mcpkit.instance'] !== globalId) fail('Метки GLOBAL не совпадают; ничего не изменено.');
  let globalInfo = inspectLiveGlobal(context, globalProject, { requireRunning: false });
  const globalDir = globalLabels['com.docker.compose.project.working_dir'];
  console.log(`Сохраняем установленный GLOBAL: ${globalProject}. Его файлы, контейнеры и данные не удаляются.`);
  if (typeof globalDir === 'string' && path.isAbsolute(globalDir)) console.log(`Docker указал исходный каталог GLOBAL: ${globalDir}`);
  console.log(`GLOBAL MetaMCP: ${globalUrlText}; LOCAL: localhost и ${lanIp}, порты 12108/12208.`);
  console.log('ВНИМАНИЕ: HTTP в LAN не шифрует пароли и API-ключи. GLOBAL и его данные не удаляются.');

  const dirs = [];
  const seenStates = new Set();
  const oldProjects = new Set(orphanProject ? [orphanProject] : []);
  for (const spec of specs) {
    let entry;
    try { entry = fs.lstatSync(spec.dir); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    if (entry.isSymbolicLink()) fail(`Каталог ${spec.dir} является ссылкой; он сохранён.`);
    const state = checkState(spec.dir, 'meta');
    if (seenStates.has(state.project)) fail('Два каталога ссылаются на один MetaMCP проект; ничего не удалено.');
    seenStates.add(state.project);
    const marker = markerFor(spec, state);
    if (marker) {
      if (orphanProject === state.project) fail('Проект для очистки совпадает с новым экземпляром; ничего не удалено.');
      spec.existing = { state, marker }; continue;
    }
    checkNoMount(spec.dir);
    dirs.push({ spec, state });
    oldProjects.add(state.project);
  }
  const allNames = docker('container', 'ls', '-a', '--no-trunc', '--format', '{{.ID}} {{.Names}}').split('\n').filter(Boolean).map((line) => line.trim().split(/\s+/, 2));
  const allVolumes = list(docker('volume', 'ls', '--format', '{{.Name}}'));
  const allNetworks = list(docker('network', 'ls', '--format', '{{.Name}}'));
  const imageRefs = list(docker('image', 'ls', '--format', '{{.Repository}}:{{.Tag}}'));
  const owned = { containers: [], volumes: [], networks: [], images: [] };
  for (const project of oldProjects) {
    projectId(project, 'meta');
    const ids = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${project}`));
    const idSet = new Set(ids);
    for (const [id, name] of allNames) if (name.startsWith(`${project}-`) && !idSet.has(id)) fail(`Контейнер ${name} имеет неожиданные метки; удаление отменено.`);
    for (const id of ids) {
      const item = inspect('container', id);
      checkLabels('container', item, project, id);
      if (!['app', 'postgres', 'lan'].includes(item.Config?.Labels?.['com.docker.compose.service'])) fail(`Неожиданный сервис ${id}; удаление отменено.`);
      owned.containers.push(id);
    }
    const volumeNames = new Set([...allVolumes.filter((value) => value.startsWith(`${project}_`)),
      ...list(docker('volume', 'ls', '--filter', `label=com.docker.compose.project=${project}`, '--format', '{{.Name}}'))]);
    for (const name of volumeNames) {
      const item = inspect('volume', name);
      checkLabels('volume', item, project, name);
      const users = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `volume=${name}`));
      if (users.some((id) => !idSet.has(id))) fail(`Том ${name} используется посторонним контейнером; удаление отменено.`);
      owned.volumes.push(name);
    }
    const networkNames = new Set([...allNetworks.filter((value) => value.startsWith(`${project}_`)),
      ...list(docker('network', 'ls', '--filter', `label=com.docker.compose.project=${project}`, '--format', '{{.Name}}'))]);
    for (const name of networkNames) {
      const item = inspect('network', name);
      checkLabels('network', item, project, name);
      if (Object.keys(item.Containers || {}).some((id) => !idSet.has(id))) fail(`Сеть ${name} используется посторонним контейнером; удаление отменено.`);
      owned.networks.push(name);
    }
    const imageName = `${project}-metamcp:1`;
    if (imageRefs.includes(imageName)) {
      const image = inspect('image', imageName);
      if (image.Config?.Labels?.['com.multfinite.mcpkit.instance'] !== projectId(project, 'meta') || !/^sha256:[a-f0-9]{64}$/.test(image.Id || '')) fail(`Образ ${imageName} имеет неожиданные метки; удаление отменено.`);
      const users = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `ancestor=${image.Id}`));
      if (users.some((id) => !idSet.has(id))) fail(`Образ ${imageName} используется посторонним контейнером; удаление отменено.`);
      owned.images.push({ name: imageName, id: image.Id, project });
    }
  }
  // Refuse directory removal if it overlaps a bind mount or volume used by
  // any other container (including both generations of GLOBAL). rmSync does
  // not follow symlinks, and mountpoints inside the directories are checked.
  let warnedAboutProtectedPaths = false;
  function checkProtectedDirs() {
    const protectedPaths = [];
    const protect = (value) => {
      if (typeof value !== 'string' || !path.isAbsolute(value)) return;
      protectedPaths.push(path.resolve(value));
      // Existing bind sources and Docker volume mountpoints may be symlinks.
      // Docker members often cannot traverse /var/lib/docker directly; use a
      // read-only privileged realpath rather than assume an inaccessible path
      // cannot overlap an old MetaMCP directory.
      try { protectedPaths.push(fs.realpathSync(value)); }
      catch (error) {
        if (error.code === 'ENOENT') return;
        if (error.code !== 'EACCES' || process.getuid?.() === 0) throw error;
        if (!warnedAboutProtectedPaths) {
          console.log('Для проверки расположения Docker-томов может потребоваться пароль sudo.');
          warnedAboutProtectedPaths = true;
        }
        const result = spawnSync('sudo', ['/usr/bin/realpath', '--', value], { encoding: 'utf8', stdio: ['inherit', 'pipe', 'inherit'] });
        const resolved = result.stdout?.replace(/\n$/, '') || '';
        if (result.error || result.status !== 0 || !path.isAbsolute(resolved)) fail('Не удалось проверить защищённый путь Docker; ничего не удалено.');
        protectedPaths.push(path.resolve(resolved));
      }
    };
    protect(root);
    protect(globalDir);
    const ids = list(docker('container', 'ls', '-a', '-q', '--no-trunc'));
    for (const id of ids) {
      if (owned.containers.includes(id)) continue;
      const item = inspect('container', id);
      for (const mount of item.Mounts || []) protect(mount.Source);
    }
    const inside = (child, parent) => {
      const relative = path.relative(parent, child);
      return !relative || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
    };
    const overlaps = (a, b) => inside(a, b) || inside(b, a);
    for (const { spec } of dirs) if (protectedPaths.some((item) => overlaps(spec.dir, item))) fail(`В ${spec.dir} может находиться содержимое другого проекта; каталог сохранён.`);
  }
  checkProtectedDirs();
  // Docker can publish through firewall rules without owning a listening
  // socket, so check running Docker bindings as well as the host socket.
  async function checkPorts() {
    const ids = list(docker('container', 'ls', '-q', '--no-trunc'));
    const runningBindings = ids.map((id) => inspect('container', id)).filter((item) => item.State?.Running)
      .flatMap((item) => Object.values(item.NetworkSettings?.Ports || {}).flatMap((bindings) =>
        Array.isArray(bindings) ? bindings.map((binding) => ({ binding, item })) : []));
    for (const spec of specs) for (const host of spec.lan ? ['127.0.0.1', spec.lan] : ['127.0.0.1']) {
      const matching = runningBindings.filter(({ binding }) => binding.HostPort === String(spec.port) && [host, '0.0.0.0', '::', ''].includes(binding.HostIp));
      const allowed = ({ item }) => owned.containers.includes(item.Id) ||
        (spec.existing && item.Config?.Labels?.['com.docker.compose.project'] === spec.existing.state.project &&
         item.Config?.Labels?.['com.multfinite.mcpkit.instance'] === spec.existing.state.id && item.Config?.Labels?.['com.docker.compose.service'] === 'app');
      if (matching.some((entry) => !allowed(entry))) fail(`Порт ${host}:${spec.port} опубликован посторонним контейнером; ничего не удалено.`);
      const available = await portAvailable(host, spec.port);
      if (!available && !matching.some(allowed)) fail(`Порт ${host}:${spec.port} занят посторонним процессом; ничего не удалено.`);
    }
  }
  await checkPorts();
  console.log(`Будут удалены только старые MetaMCP: ${[...oldProjects].join(', ') || 'нет'}.`);
  console.log(`Каталогов: ${dirs.length}; контейнеров: ${owned.containers.length}; томов: ${owned.volumes.length}; сетей: ${owned.networks.length}; собственных образов: ${owned.images.length}.`);
  if (oldProjects.size || dirs.length) console.log('ВНИМАНИЕ: старые данные MetaMCP удаляются до сборки новых. При ошибке сборки они сами не восстановятся.');
  const existingAdmin = specs.find((spec) => spec.existing)?.existing.marker.adminEmail;
  const email = (existingAdmin || await question('Email администратора для всех трёх экземпляров: ')).toLowerCase();
  if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(email)) fail('Некорректный email.');
  if (specs.some((spec) => spec.existing && spec.existing.marker.adminEmail !== email)) fail('У начатых экземпляров разные администраторы; они сохранены.');
  const password = await secret(`Пароль администратора ${email} (не отображается, 12–128 символов): `);
  if (password.length < 12 || password.length > 128) fail('Пароль должен содержать от 12 до 128 символов.');
  if (!existingAdmin && password !== await secret('Повторите пароль: ')) fail('Пароли не совпадают.');
  if ((oldProjects.size || dirs.length) && (await question('Удалить перечисленные старые MetaMCP и их данные? Введите DELETE METAMCP: ')) !== 'DELETE METAMCP') fail('Отменено; ничего не удалено.');

  // Verify the existing gateway before removing anything. This starts only
  // already-owned GLOBAL containers if needed; it never uses Compose up.
  globalInfo = startLiveGlobal(globalInfo);
  let globalStatus;
  const statusDeadline = Date.now() + 90_000;
  while (!globalStatus && Date.now() < statusDeadline) {
    try { globalStatus = liveGlobalStatus(globalInfo); } catch { await delay(2000); }
  }
  if (!globalStatus) fail('Существующий GLOBAL не отвечает как ожидаемый шлюз; старые MetaMCP не удалены.');
  enableDockerBoot(endpoint);
  enableLiveGlobalRestart(globalInfo);
  console.log(`Шлюз GLOBAL отвечает. Готовых серверов: ${globalStatus.filter((item) => item.status === 'ready').length}/${globalStatus.length}.`);
  for (const item of globalStatus.filter((item) => item.status !== 'ready')) console.log(`  ${item.id}: ${item.status}`);

  if (oldProjects.size || dirs.length) {
    // Recheck identities and foreign users immediately before the first change.
    for (const { spec, state } of dirs) {
      const current = checkState(spec.dir, 'meta');
      if (current.project !== state.project || markerFor(spec, current)) fail('Каталог изменился во время подтверждения; ничего не удалено.');
      checkNoMount(spec.dir);
    }
    for (const id of owned.containers) {
      const item = inspect('container', id);
      const project = item.Config?.Labels?.['com.docker.compose.project'];
      if (!oldProjects.has(project)) fail('Контейнер изменился; ничего не удалено.');
      checkLabels('container', item, project, id);
    }
    for (const name of owned.volumes) {
      const item = inspect('volume', name);
      const project = item.Labels?.['com.docker.compose.project'];
      if (!oldProjects.has(project)) fail(`Том ${name} изменился; ничего не удалено.`);
      checkLabels('volume', item, project, name);
      const users = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `volume=${name}`));
      if (users.some((id) => !owned.containers.includes(id))) fail(`Том ${name} используется посторонним контейнером; ничего не удалено.`);
    }
    for (const name of owned.networks) {
      const item = inspect('network', name);
      const project = item.Labels?.['com.docker.compose.project'];
      if (!oldProjects.has(project)) fail(`Сеть ${name} изменилась; ничего не удалено.`);
      checkLabels('network', item, project, name);
      if (Object.keys(item.Containers || {}).some((id) => !owned.containers.includes(id))) fail(`Сеть ${name} используется посторонним контейнером; ничего не удалено.`);
    }
    for (const image of owned.images) {
      const item = inspect('image', image.name);
      if (item.Id !== image.id || item.Config?.Labels?.['com.multfinite.mcpkit.instance'] !== projectId(image.project, 'meta')) fail(`Образ ${image.name} изменился; ничего не удалено.`);
      const users = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `ancestor=${image.id}`));
      if (users.some((id) => !owned.containers.includes(id))) fail(`Образ ${image.name} используется посторонним контейнером; ничего не удалено.`);
    }
    checkProtectedDirs();
    await checkPorts();
    if (owned.containers.length) run('docker', ['--context', context, 'container', 'rm', '-f', ...owned.containers]);
    if (owned.volumes.length) run('docker', ['--context', context, 'volume', 'rm', ...owned.volumes]);
    if (owned.networks.length) run('docker', ['--context', context, 'network', 'rm', ...owned.networks]);
    if (owned.images.length) run('docker', ['--context', context, 'image', 'rm', '--no-prune', ...owned.images.map((image) => image.name)]);
    for (const { spec } of dirs) { checkNoMount(spec.dir); fs.rmSync(spec.dir, { recursive: true }); }
    console.log('Старые выбранные MetaMCP удалены. GLOBAL не удалялся.');
  }
  const gateway = globalInfo.url;
  for (const spec of specs) {
    console.log(`\n=== ${spec.dir} : ${spec.port} ===`);
    const stack = path.join(root, 'common', 'stack.mjs');
    let existing = spec.existing;
    if (!existing) {
      const args = [stack, 'init-meta', '--dir', spec.dir, '--port', String(spec.port), '--staged', '--fresh', '--clean-tools', '--admin-email', email];
      if (spec.lan) args.push('--lan-ip', spec.lan, '--allow-insecure-lan');
      else args.push('--app-url', spec.url);
      run(process.execPath, args);
      const state = checkState(spec.dir, 'meta');
      existing = { state, marker: markerFor(spec, state) };
      if (!existing.marker?.staged) fail('Новый экземпляр не остался в безопасном режиме подготовки.');
    } else if (existing.marker.staged) {
      const readyPath = path.join(spec.dir, '.mcpkit', 'publication-ready.json');
      let wasPublished = false;
      if (fs.existsSync(readyPath)) {
        const ids = list(docker('container', 'ls', '-a', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${existing.state.project}`, '--filter', 'label=com.docker.compose.service=app'));
        if (ids.length !== 1) fail('Неоднозначное прерванное включение MetaMCP; проверьте его состояние.');
        const app = inspect('container', ids[0]);
        checkLabels('container', app, existing.state.project, ids[0]);
        wasPublished = Object.values(app.HostConfig?.PortBindings || {}).some((items) => Array.isArray(items) && items.length > 0);
        if (wasPublished && !app.State?.Running) fail('Прерванное включение остановлено после назначения порта; проверьте состояние вручную.');
      }
      // Never start a previously published container with a staging override.
      if (!wasPublished) run(process.execPath, [stack, 'start', '--dir', spec.dir]);
    }
    if (existing.marker.staged) {
      const readyPath = path.join(spec.dir, '.mcpkit', 'publication-ready.json');
      if (!fs.existsSync(readyPath)) run(process.execPath, [stack, 'provision-meta', '--dir', spec.dir], { input: JSON.stringify({ email, password }) });
      const markerPath = path.join(spec.dir, '.mcpkit', 'reinstall-three.json');
      if (!fs.existsSync(markerPath)) privateWrite(markerPath, `${JSON.stringify({ version: 1, project: existing.state.project, adminEmail: email }, null, 2)}\n`);
      else {
        const ownMarker = readJson(markerPath);
        if (ownMarker.version !== 1 || ownMarker.project !== existing.state.project || ownMarker.adminEmail !== email) fail('Служебный маркер другого экземпляра не изменён.');
      }
      run(process.execPath, [stack, 'activate-meta', '--dir', spec.dir]);
    } else {
      run(process.execPath, [stack, 'start', '--dir', spec.dir]);
    }
    ensureMetaRestart(existing.state);
    if (!spec.lan) {
      globalInfo = connectLiveGlobal(globalInfo, existing.state);
      run(process.execPath, [path.join(root, 'common', 'register.mjs'), 'global', '--live-global', globalProject, '--meta-dir', spec.dir, '--json-stdin'], {
        input: JSON.stringify({ target: existing.state.appUrl, gateway, email, password }),
      });
    }
  }
  console.log('\nГотово: существующий GLOBAL сохранён; GLOBAL MetaMCP подключён к нему, два LOCAL MetaMCP установлены отдельно.');
  for (const spec of specs) console.log(`${spec.dir}: ${spec.lan ? `http://localhost:${spec.port} и http://${spec.lan}:${spec.port}` : spec.url}; ключ: ${spec.dir}/.mcpkit/client-api-key`);
  console.log('Docker включён при загрузке; контейнеры используют unless-stopped. Существующий reverse proxy не изменялся.');
  console.log('Graphiti/Cognee, Google Drive и GitHub могут требовать своих учётных данных; состояние серверов проверяется отдельно.');
  console.log('Не отправляйте пароли, ключи или содержимое приватных файлов в переписку.');
} catch (error) {
  console.error(`ОСТАНОВЛЕНО: ${error.message}`);
  console.error('GLOBAL и другие проекты намеренно не удалялись. Если ошибка произошла после начала удаления или создания, проверьте выведенное состояние перед повтором.');
  process.exitCode = 1;
}
