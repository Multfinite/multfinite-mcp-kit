// Read and link an already existing independent GLOBAL project without
// adopting, rebuilding, deleting, or moving its state, containers or volumes.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const services = ['gateway', 'neo4j', 'qdrant', 'graphiti', 'cognee', 'memory', 'gdrive'];
const statusIds = ['sequentialthinking', 'graphiti', 'cognee', 'memory-bank-mcp', 'context7', 'duckduckgo', 'fetch', 'io-draw', 'mcp-compass', 'gdrive', 'neo4j-global', 'qdrant-global', 'playwright'];
function fail(message) { throw new Error(message); }
function cleanEnv() {
  return Object.fromEntries(Object.entries(process.env).filter(([name]) => !/^(DOCKER_HOST|DOCKER_CONTEXT|DOCKER_TLS_VERIFY|DOCKER_CERT_PATH)$/i.test(name)));
}
function command(ctx, args, { inherit = false } = {}) {
  const result = spawnSync('docker', ['--context', ctx, ...args], { env: cleanEnv(), encoding: 'utf8', stdio: inherit ? 'inherit' : ['ignore', 'pipe', 'pipe'], maxBuffer: 8 * 1024 * 1024, windowsHide: true });
  if (result.error || result.status !== 0) fail(`Docker could not ${args[0]} ${args[1] || ''}; inspect the existing GLOBAL locally.`);
  return inherit ? '' : result.stdout.trim();
}
function inspect(ctx, kind, name) {
  let item;
  try { item = JSON.parse(command(ctx, [kind, 'inspect', name]))[0]; } catch { fail(`Cannot inspect ${kind} ${name}.`); }
  if (!item || typeof item !== 'object') fail(`Invalid ${kind} inspection.`);
  return item;
}
function dockerList(value) { return value ? value.split(/\s+/).filter(Boolean) : []; }
function envMap(entries) {
  if (!Array.isArray(entries)) fail('GLOBAL gateway environment is unavailable.');
  const values = Object.create(null);
  for (const item of entries) {
    if (typeof item !== 'string' || !item.includes('=')) fail('GLOBAL gateway environment is invalid.');
    const index = item.indexOf('=');
    const key = item.slice(0, index);
    if (Object.hasOwn(values, key)) fail('GLOBAL gateway environment contains duplicate settings.');
    values[key] = item.slice(index + 1);
  }
  return values;
}
function checkGlobalLabels(labels, project, id) {
  if (labels?.['com.docker.compose.project'] !== project || labels?.['com.multfinite.mcpkit.instance'] !== id) fail('GLOBAL resource ownership is ambiguous; it was not changed.');
}

// Check the gateway, every existing service and both networks by identity. No
// build directory or .env is needed; those may have moved independently of the
// still-running GLOBAL. Docker inspect contains secrets and is never printed.
export function inspectLiveGlobal(ctx, project, { requireRunning = true } = {}) {
  const match = /^mcpkit-global-([a-f0-9]{16})$/.exec(project || '');
  if (!match) fail('The selected GLOBAL project is not an independent kit project.');
  const id = match[1];
  const ids = dockerList(command(ctx, ['container', 'ls', '-a', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${project}`]));
  const items = new Map();
  for (const containerId of ids) {
    if (!/^[a-f0-9]{64}$/.test(containerId)) fail('Unexpected GLOBAL container ID.');
    const item = inspect(ctx, 'container', containerId);
    const labels = item.Config?.Labels || {};
    checkGlobalLabels(labels, project, id);
    if (String(labels['com.docker.compose.oneoff'] || '').toLowerCase() === 'true') continue;
    const service = labels['com.docker.compose.service'];
    if (!services.includes(service) || items.has(service)) fail('GLOBAL services are missing or ambiguous; no container was changed.');
    items.set(service, item);
  }
  if (services.some((service) => !items.has(service))) fail('The installed GLOBAL is incomplete; no container or data was deleted.');
  if (requireRunning && services.some((service) => items.get(service).State?.Running !== true)) fail('One or more existing GLOBAL containers are stopped.');
  const gateway = items.get('gateway');
  if (!new RegExp(`^/${project}-gateway-[0-9]+$`).test(gateway.Name || '')) fail('Unexpected GLOBAL gateway name.');
  const env = envMap(gateway.Config?.Env);
  if (env.MCPKIT_INSTANCE_ID !== id || !/^[a-f0-9]{64}$/.test(env.MCPKIT_GATEWAY_KEY || '') ||
      !/^[a-f0-9]{64}$/.test(env.MCPKIT_CONTROL_KEY || '') || env.MCPKIT_GATEWAY_KEY === env.MCPKIT_CONTROL_KEY) {
    fail('GLOBAL gateway credentials or identity are invalid; they were not replaced.');
  }
  const bindings = gateway.HostConfig?.PortBindings?.['13001/tcp'];
  if (!Array.isArray(bindings) || bindings.length !== 1 || bindings[0].HostIp !== '127.0.0.1' || !/^\d+$/.test(bindings[0].HostPort || '')) fail('GLOBAL gateway host binding is unexpected.');
  const client = inspect(ctx, 'network', `${project}_client`);
  const backend = inspect(ctx, 'network', `${project}_default`);
  checkGlobalLabels(client.Labels, project, id);
  checkGlobalLabels(backend.Labels, project, id);
  if (client.Internal !== true || client.Labels?.['com.docker.compose.network'] !== 'client' || backend.Labels?.['com.docker.compose.network'] !== 'default') fail('The GLOBAL networks are not the expected isolated pair.');
  const clientMembers = Object.keys(client.Containers || {});
  const backendMembers = Object.keys(backend.Containers || {});
  if (requireRunning && (!clientMembers.includes(gateway.Id) || !backendMembers.includes(gateway.Id))) fail('The GLOBAL gateway is not connected to both expected networks.');
  if (gateway.State?.Running && !(gateway.NetworkSettings?.Networks?.[`${project}_client`]?.Aliases || []).includes(`${project}-gateway`)) fail('The GLOBAL gateway network alias is missing.');
  for (const member of clientMembers) {
    if (member === gateway.Id) continue;
    const item = inspect(ctx, 'container', member);
    const labels = item.Config?.Labels || {};
    const metaProject = labels['com.docker.compose.project'] || '';
    if (!/^mcpkit-meta-[a-f0-9]{16}$/.test(metaProject) || labels['com.multfinite.mcpkit.instance'] !== metaProject.slice(-16) ||
        labels['com.docker.compose.service'] !== 'app' || backendMembers.includes(member) ||
        (item.NetworkSettings?.Networks?.[`${project}_client`]?.Aliases || []).includes(`${project}-gateway`)) {
      fail('An unexpected container or gateway alias is present on the GLOBAL client network.');
    }
  }
  if (!/^[a-f0-9]{64}$/.test(client.Id || '')) fail('GLOBAL client network ID is invalid.');
  return { ctx, project, id, items, gatewayId: gateway.Id, gatewayKey: env.MCPKIT_GATEWAY_KEY,
    clientNetworkId: client.Id, clientMembers, backendMembers, url: `http://${project}-gateway:13001` };
}

// A link is local metadata only: the GLOBAL project and its network remain
// independently owned. Pin the Docker network ID so a same-named replacement
// cannot silently acquire access to the MetaMCP container.
export function readLiveGlobalLink(metaState) {
  if (metaState?.type !== 'meta') return null;
  if (!path.isAbsolute(metaState.base || '') || path.resolve(metaState.base) !== metaState.base ||
      !/^[a-f0-9]{16}$/.test(metaState.id || '') || metaState.project !== `mcpkit-meta-${metaState.id}`) fail('Invalid MetaMCP identity for GLOBAL link.');
  const file = path.join(metaState.base, '.mcpkit', 'live-global-link.json');
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  if (!stat.isFile() || stat.isSymbolicLink()) fail('Invalid GLOBAL link metadata; no network was changed.');
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail('Invalid GLOBAL link metadata; no network was changed.'); }
  if (!value || value.version !== 1 || value.metaProject !== metaState.project ||
      !/^mcpkit-global-[a-f0-9]{16}$/.test(value.globalProject || '') || !/^[a-f0-9]{64}$/.test(value.networkId || '')) {
    fail('GLOBAL link metadata does not match this MetaMCP; no network was changed.');
  }
  return { globalProject: value.globalProject, networkId: value.networkId, network: `${value.globalProject}_client` };
}
export function assertLiveGlobalNetwork(ctx, metaState) {
  const link = readLiveGlobalLink(metaState);
  if (!link) return null;
  const global = inspectLiveGlobal(ctx, link.globalProject, { requireRunning: false });
  if (global.clientNetworkId !== link.networkId) fail('The linked GLOBAL client network was replaced; no MetaMCP container was changed.');
  return link;
}

// Start only verified existing containers. No Compose up/build/recreate and no
// changes to the older GLOBAL or to any volume, network definition or files.
export function startLiveGlobal(info) {
  const current = inspectLiveGlobal(info.ctx, info.project, { requireRunning: false });
  for (const service of ['neo4j', 'qdrant', 'memory', 'gdrive', 'graphiti', 'cognee', 'gateway']) {
    const item = current.items.get(service);
    if (!item.State?.Running) command(info.ctx, ['container', 'start', item.Id], { inherit: true });
  }
  return inspectLiveGlobal(info.ctx, info.project);
}
export function enableLiveGlobalRestart(info) {
  const current = inspectLiveGlobal(info.ctx, info.project);
  const ids = services.map((service) => current.items.get(service).Id);
  command(info.ctx, ['container', 'update', '--restart', 'unless-stopped', ...ids], { inherit: true });
  const after = inspectLiveGlobal(info.ctx, info.project);
  if (services.some((service) => after.items.get(service).Id !== current.items.get(service).Id ||
      after.items.get(service).HostConfig?.RestartPolicy?.Name !== 'unless-stopped')) fail('Could not confirm the restart policy of every existing GLOBAL container.');
}
export function liveGlobalStatus(info) {
  const current = inspectLiveGlobal(info.ctx, info.project);
  const script = "fetch('http://127.0.0.1:13001/_mcpkit/status',{headers:{'X-Mcpkit-Control':process.env.MCPKIT_CONTROL_KEY},signal:AbortSignal.timeout(5000)})" +
    ".then(async r=>{if(!r.ok)throw Error('gateway unavailable');process.stdout.write(JSON.stringify(await r.json()))})" +
    ".catch(()=>{process.stderr.write('gateway unavailable');process.exitCode=1})";
  let result;
  try { result = JSON.parse(command(info.ctx, ['exec', current.gatewayId, 'node', '-e', script])); } catch { fail('Could not read the existing GLOBAL gateway status.'); }
  if (result.instanceId !== current.id || !Array.isArray(result.servers) || result.servers.length !== statusIds.length ||
      statusIds.some((id) => result.servers.filter((item) => item?.id === id && ['ready', 'starting', 'waiting', 'error'].includes(item.status)).length !== 1)) {
    fail('GLOBAL gateway status has an unexpected identity or server list.');
  }
  return result.servers.map(({ id, status }) => ({ id, status }));
}
export function connectLiveGlobal(info, metaState) {
  const current = inspectLiveGlobal(info.ctx, info.project);
  if (!metaState || metaState.type !== 'meta' || !/^[a-f0-9]{16}$/.test(metaState.id || '') || metaState.project !== `mcpkit-meta-${metaState.id}`) fail('Invalid selected MetaMCP identity.');
  const ids = dockerList(command(info.ctx, ['container', 'ls', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${metaState.project}`, '--filter', 'label=com.docker.compose.service=app']));
  if (ids.length !== 1 || !/^[a-f0-9]{64}$/.test(ids[0])) fail('Expected one running selected MetaMCP app.');
  const app = inspect(info.ctx, 'container', ids[0]);
  const labels = app.Config?.Labels || {};
  if (labels['com.multfinite.mcpkit.instance'] !== metaState.id || labels['com.docker.compose.project'] !== metaState.project ||
      labels['com.docker.compose.service'] !== 'app' || app.State?.Running !== true || current.backendMembers.includes(app.Id)) fail('The selected MetaMCP app is not isolated from the GLOBAL backend network.');
  const existing = readLiveGlobalLink(metaState);
  if (existing && (existing.globalProject !== info.project || existing.networkId !== current.clientNetworkId)) fail('This MetaMCP is already linked to another GLOBAL network; no link was changed.');
  if (!current.clientMembers.includes(app.Id)) command(info.ctx, ['network', 'connect', `${info.project}_client`, app.Id], { inherit: true });
  const linked = inspectLiveGlobal(info.ctx, info.project);
  if (!linked.clientMembers.includes(app.Id) || linked.clientNetworkId !== current.clientNetworkId) fail('Could not confirm the MetaMCP-to-GLOBAL network connection.');
  if (!existing) {
    const file = path.join(metaState.base, '.mcpkit', 'live-global-link.json');
    fs.writeFileSync(file, `${JSON.stringify({ version: 1, metaProject: metaState.project, globalProject: info.project, networkId: linked.clientNetworkId }, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  }
  console.log('GLOBAL client network link saved for future MetaMCP app recreation.');
  return linked;
}
