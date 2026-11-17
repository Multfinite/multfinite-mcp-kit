// Pair MetaMCP applications over a dedicated internal Docker network. Link
// metadata is stored by both independently-owned projects and consumed by the
// normal Compose lifecycle so a recreated app rejoins its peer networks.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const LINKS_FILE = 'live-metamcp-links.json';
const COMPOSE_FILE = 'metamcp-live-peers.yml';
const OVERLAY_MARKER = '# MCPKIT generated MetaMCP peer overlay v1';
const LINK_LABEL = 'com.multfinite.mcpkit.link';
const LINK_VERSION = 'metamcp-peer-v1';

function fail(message) { throw new Error(message); }
function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}
function projectId(project) {
  const match = /^mcpkit-meta-([a-f0-9]{16})$/.exec(project || '');
  return match?.[1] || null;
}
function assertMetaState(state) {
  if (!state || state.type !== 'meta' || !/^[a-f0-9]{16}$/.test(state.id || '') ||
      state.project !== `mcpkit-meta-${state.id}` || typeof state.base !== 'string' ||
      !path.isAbsolute(state.base) || path.resolve(state.base) !== state.base) {
    fail('MetaMCP peer link requires an independent kit MetaMCP state.');
  }
}
function privateDirectory(state) {
  assertMetaState(state);
  let base;
  let directory;
  let stateFile;
  try {
    base = fs.lstatSync(state.base);
    directory = fs.lstatSync(path.join(state.base, '.mcpkit'));
    stateFile = fs.lstatSync(path.join(state.base, '.mcpkit', 'state.json'));
  } catch { fail(`The private .mcpkit state is incomplete for ${state.project}; no Docker resource was changed.`); }
  if (!base.isDirectory() || base.isSymbolicLink() || !directory.isDirectory() || directory.isSymbolicLink() ||
      !stateFile.isFile() || stateFile.isSymbolicLink() ||
      (process.platform !== 'win32' && (directory.mode & 0o077) !== 0)) {
    fail(`The ${state.project} state directory must be a private, real directory; no Docker resource was changed.`);
  }
  return path.join(state.base, '.mcpkit');
}
function pairIdentity(leftProject, rightProject) {
  const leftId = projectId(leftProject);
  const rightId = projectId(rightProject);
  if (!leftId || !rightId || leftProject === rightProject) fail('Two different independent kit MetaMCP projects are required.');
  const projects = [leftProject, rightProject].sort();
  const digest = crypto.createHash('sha256').update(projects.join('\n')).digest('hex').slice(0, 24);
  return {
    projects,
    network: `mcpkit-meta-peer-${digest}`,
    labels: {
      [LINK_LABEL]: LINK_VERSION,
      'com.multfinite.mcpkit.peer-a': projects[0],
      'com.multfinite.mcpkit.peer-b': projects[1],
      'com.multfinite.mcpkit.link-id': digest,
    },
  };
}
function linkFile(state) { return path.join(privateDirectory(state), LINKS_FILE); }
function peerAlias(id) { return `mcpkit-meta-${id}`; }
function readJsonFile(file, description) {
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail(`Invalid ${description}; no Docker resource was changed.`); }
  return value;
}

export function readLiveMetaPeerLinks(state) {
  const file = linkFile(state);
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
    fail(`Invalid or non-private MetaMCP peer metadata for ${state.project}; no Docker resource was changed.`);
  }
  const value = readJsonFile(file, 'MetaMCP peer metadata');
  if (!exactKeys(value, ['version', 'project', 'links']) || value.version !== 1 || value.project !== state.project ||
      !Array.isArray(value.links) || value.links.length > 128) {
    fail(`MetaMCP peer metadata does not match ${state.project}; no Docker resource was changed.`);
  }
  const seen = new Set();
  const links = value.links.map((item) => {
    if (!exactKeys(item, ['peerProject', 'network', 'networkId'])) fail('Invalid MetaMCP peer metadata; no Docker resource was changed.');
    const peerId = projectId(item.peerProject);
    if (!peerId || item.peerProject === state.project || seen.has(item.peerProject) ||
        item.network !== pairIdentity(state.project, item.peerProject).network || !/^[a-f0-9]{64}$/.test(item.networkId || '')) {
      fail('MetaMCP peer metadata has an invalid project, network or Docker network identity; no Docker resource was changed.');
    }
    seen.add(item.peerProject);
    return { peerProject: item.peerProject, peerId, network: item.network, networkId: item.networkId, alias: peerAlias(peerId) };
  });
  return links.sort((a, b) => a.peerProject.localeCompare(b.peerProject));
}

function composeOverlay(state, links) {
  const lines = [OVERLAY_MARKER, 'services:', '  app:', '    networks:', '      default: {}'];
  for (const link of links) {
    lines.push(`      mcpkit_peer_${link.peerId}:`, '        aliases:', `          - "${peerAlias(state.id)}"`);
  }
  lines.push('networks:');
  for (const link of links) {
    lines.push(`  mcpkit_peer_${link.peerId}:`, '    external: true', `    name: "${link.network}"`);
  }
  return `${lines.join('\n')}\n`;
}
function atomicWrite(file, text) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temporary, text, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally {
    try { fs.unlinkSync(temporary); } catch { /* already renamed or absent */ }
  }
}
function assertComposeOverlayWritable(state) {
  const file = path.join(privateDirectory(state), COMPOSE_FILE);
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!stat) return;
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) ||
      !fs.readFileSync(file, 'utf8').startsWith(`${OVERLAY_MARKER}\n`)) {
    fail(`A non-kit file occupies the reserved peer Compose overlay path for ${state.project}; it was preserved.`);
  }
}

// Compose overrides live beside the private state (not in the repository) and
// are generated only from validated hexadecimal project IDs and network names.
export function liveMetaPeerComposeFile(state) {
  const links = readLiveMetaPeerLinks(state);
  if (!links.length) return null;
  const file = path.join(privateDirectory(state), COMPOSE_FILE);
  const content = composeOverlay(state, links);
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (stat) {
    if (!stat.isFile() || stat.isSymbolicLink() ||
        (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) fail(`Invalid generated Compose overlay for ${state.project}.`);
    const existing = fs.readFileSync(file, 'utf8');
    if (existing !== content) {
      if (!existing.startsWith(`${OVERLAY_MARKER}\n`)) fail(`A non-kit file occupies the reserved peer Compose overlay path for ${state.project}; it was preserved.`);
      atomicWrite(file, content);
    }
  } else atomicWrite(file, content);
  return file;
}
function removeGeneratedComposeFile(state, expectedContent) {
  if (!expectedContent) return;
  const file = path.join(privateDirectory(state), COMPOSE_FILE);
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!stat) return;
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`Invalid generated Compose overlay for ${state.project}; it was preserved.`);
  if (fs.readFileSync(file, 'utf8') === expectedContent) fs.unlinkSync(file);
  else console.warn(`Modified peer Compose overlay was left untouched: ${file}`);
}

function cleanDockerEnv() {
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    const upper = name.toUpperCase();
    if (/^(DOCKER_HOST|DOCKER_CONTEXT|DOCKER_TLS_VERIFY|DOCKER_CERT_PATH|COMPOSE_|MCPKIT_|POSTGRES_|BOOTSTRAP_)/.test(upper) ||
        ['APP_URL', 'NEXT_PUBLIC_APP_URL', 'DATABASE_URL', 'BETTER_AUTH_SECRET', 'METAMCP_ADMIN_EMAILS',
          'NEO4J_PASSWORD', 'LLM_API_KEY', 'CONTEXT7_API_KEY'].includes(upper)) delete env[name];
  }
  return env;
}
function docker(ctx, args, { allowFailure = false, input, timeout = 30000 } = {}) {
  const result = spawnSync('docker', ['--context', ctx, ...args], {
    env: cleanDockerEnv(), encoding: 'utf8', stdio: input === undefined ? ['ignore', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe'],
    ...(input === undefined ? {} : { input }), timeout, windowsHide: true, maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) fail(`Cannot start Docker: ${result.error.message}`);
  if (result.status !== 0 && !allowFailure) {
    fail(`Docker ${args[0]} ${args[1] || ''} failed (exit ${result.status}): ${(result.stderr || '').trim().slice(-700)}`);
  }
  return result;
}
function dockerList(text, description) {
  const ids = text.trim().split(/\s+/).filter(Boolean);
  if (ids.some((id) => !/^[a-f0-9]{64}$/.test(id)) || new Set(ids).size !== ids.length) fail(`Unexpected Docker ${description} identity.`);
  return ids;
}
function inspect(ctx, kind, name) {
  const result = docker(ctx, [kind, 'inspect', name], { allowFailure: true });
  if (result.status !== 0) {
    const message = (result.stderr || '').trim();
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const missing = new RegExp(`(?:No such ${kind}:\\s*${escaped}|${kind}\\s+${escaped}\\s+not found)`, 'i');
    if (missing.test(message)) return null;
    fail(`Cannot inspect Docker ${kind} ${name}: ${message.slice(-500)}`);
  }
  let values;
  try { values = JSON.parse(result.stdout); } catch { fail(`Invalid Docker ${kind} inspection for ${name}.`); }
  if (!Array.isArray(values) || values.length !== 1 || !values[0] || typeof values[0] !== 'object') fail(`Ambiguous Docker ${kind} inspection for ${name}.`);
  return values[0];
}
function labelsOf(container) { return container.Config?.Labels || {}; }
function oneOff(labels) { return String(labels['com.docker.compose.oneoff'] || '').toLowerCase() === 'true'; }
function projectContainers(ctx, project, id) {
  const ids = dockerList(docker(ctx, ['container', 'ls', '-a', '-q', '--no-trunc', '--filter', `label=com.docker.compose.project=${project}`]).stdout, 'container list');
  const services = new Map();
  for (const containerId of ids) {
    const item = inspect(ctx, 'container', containerId);
    if (!item || item.Id !== containerId) fail(`A selected ${project} container changed during inspection; no network was changed.`);
    const labels = labelsOf(item);
    if (labels['com.docker.compose.project'] !== project || labels['com.multfinite.mcpkit.instance'] !== id) {
      fail(`Container ${containerId} is not owned by ${project}; no network was changed.`);
    }
    if (oneOff(labels)) continue;
    const service = labels['com.docker.compose.service'];
    if (!['app', 'postgres'].includes(service) || services.has(service)) fail(`Unexpected or ambiguous ${project} service container; no network was changed.`);
    services.set(service, item);
  }
  return services;
}
function checkDefaultNetwork(ctx, state, app) {
  const name = `${state.project}_default`;
  const network = inspect(ctx, 'network', name);
  if (!network && app?.State?.Running !== true) return;
  const labels = network?.Labels || {};
  if (!network || network.Name !== name || !/^[a-f0-9]{64}$/.test(network.Id || '') || network.Driver !== 'bridge' ||
      labels['com.docker.compose.project'] !== state.project || labels['com.docker.compose.network'] !== 'default' ||
      labels['com.multfinite.mcpkit.instance'] !== state.id) {
    fail(`The private default network of ${state.project} is missing or has unexpected ownership; no network was changed.`);
  }
  const members = network.Containers && typeof network.Containers === 'object' ? Object.keys(network.Containers) : [];
  for (const memberId of members) {
    if (!/^[a-f0-9]{64}$/.test(memberId)) fail(`Unexpected member on ${name}; no network was changed.`);
    const member = inspect(ctx, 'container', memberId);
    const memberLabels = member ? labelsOf(member) : {};
    if (!member || memberLabels['com.docker.compose.project'] !== state.project ||
        memberLabels['com.multfinite.mcpkit.instance'] !== state.id ||
        !['app', 'postgres'].includes(memberLabels['com.docker.compose.service'])) {
      fail(`Another project is attached to private network ${name}; no network was changed.`);
    }
  }
  if (app?.State?.Running === true) {
    const endpoint = app.NetworkSettings?.Networks?.[name];
    if (!endpoint || endpoint.NetworkID !== network.Id || !members.includes(app.Id)) {
      fail(`The running ${state.project} app is not on its own private Docker network; no network was changed.`);
    }
  }
}
function validateAppNetworks(state, app) {
  const expectedDefault = `${state.project}_default`;
  if (app.HostConfig?.NetworkMode !== expectedDefault) fail(`The ${state.project} app uses an unexpected Docker network mode; no network was changed.`);
  const networks = app.NetworkSettings?.Networks;
  if (networks !== undefined && networks !== null && (typeof networks !== 'object' || Array.isArray(networks))) {
    fail(`Invalid Docker network configuration for ${state.project}; no network was changed.`);
  }
  for (const name of Object.keys(networks || {})) {
    const match = /^mcpkit-(?:meta|global)-[a-f0-9]{16}_default$/.exec(name);
    if (match && name !== expectedDefault) fail(`The ${state.project} app is already attached to another project's private backend network (${name}); no network was changed.`);
  }
}
function metaApp(ctx, project, id, { requireRunning = false } = {}) {
  const services = projectContainers(ctx, project, id);
  const app = services.get('app');
  if (!app) {
    checkDefaultNetwork(ctx, { project, id }, null);
    if (requireRunning) fail(`No owned MetaMCP app container was found for ${project}.`);
    return null;
  }
  const expectedName = new RegExp(`^/${project.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-app-[0-9]+$`);
  if (!expectedName.test(app.Name || '')) fail(`Unexpected MetaMCP app container name for ${project}; no network was changed.`);
  validateAppNetworks({ project, id }, app);
  checkDefaultNetwork(ctx, { project, id }, app);
  if (app.State?.Running !== true && requireRunning) fail(`Start both MetaMCP app containers before linking ${project}.`);
  return app;
}
function pairApps(ctx, identity, left, right, { requireRunning = false } = {}) {
  const leftId = projectId(left.project);
  const rightId = projectId(right.project);
  const a = metaApp(ctx, left.project, leftId, { requireRunning });
  const b = metaApp(ctx, right.project, rightId, { requireRunning });
  if (requireRunning && (!a || !b || a.State?.Running !== true || b.State?.Running !== true)) {
    fail('Start both owned MetaMCP app containers before linking; no network was changed.');
  }
  return new Map([[left.project, a], [right.project, b]]);
}
function validatePairNetwork(ctx, identity, apps, { requireAliases = false } = {}) {
  const network = inspect(ctx, 'network', identity.network);
  if (!network) return null;
  if (network.Name !== identity.network || !/^[a-f0-9]{64}$/.test(network.Id || '') ||
      network.Driver !== 'bridge' || network.Internal !== true || network.Scope !== 'local') {
    fail(`Docker network ${identity.network} is not the expected internal bridge; no network was changed.`);
  }
  for (const [name, value] of Object.entries(identity.labels)) {
    if (network.Labels?.[name] !== value) fail(`Docker network ${identity.network} is not owned by this MetaMCP pair; no network was changed.`);
  }
  const members = network.Containers && typeof network.Containers === 'object' ? Object.keys(network.Containers) : [];
  const seenProjects = new Set();
  for (const memberId of members) {
    if (!/^[a-f0-9]{64}$/.test(memberId)) fail(`Unexpected member on ${identity.network}; no network was changed.`);
    const member = inspect(ctx, 'container', memberId);
    const labels = member ? labelsOf(member) : {};
    const project = labels['com.docker.compose.project'];
    const id = projectId(project);
    const expected = apps.get(project);
    if (!member || !identity.projects.includes(project) || labels['com.multfinite.mcpkit.instance'] !== id ||
        labels['com.docker.compose.service'] !== 'app' || oneOff(labels) || !expected || expected.Id !== memberId ||
        member.State?.Running !== true || seenProjects.has(project)) {
      fail(`Unexpected container on internal MetaMCP peer network ${identity.network}; no network was changed.`);
    }
    const endpoint = member.NetworkSettings?.Networks?.[identity.network];
    if (!endpoint || endpoint.NetworkID !== network.Id ||
        (requireAliases && !(endpoint.Aliases || []).includes(peerAlias(id)))) {
      fail(`MetaMCP app network alias or identity is invalid on ${identity.network}; no network was changed.`);
    }
    seenProjects.add(project);
  }
  return network;
}
function linkRecord(metaState, peerState, networkId) {
  return { peerProject: peerState.project, network: pairIdentity(metaState.project, peerState.project).network, networkId };
}
function writePeerLinks(state, links) {
  const file = linkFile(state);
  const sorted = [...links].sort((a, b) => a.peerProject.localeCompare(b.peerProject));
  if (!sorted.length) {
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink()) fail(`Invalid MetaMCP peer metadata for ${state.project}; it was not removed.`);
      fs.unlinkSync(file);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    return;
  }
  atomicWrite(file, `${JSON.stringify({ version: 1, project: state.project, links: sorted.map(({ peerProject, network, networkId }) => ({ peerProject, network, networkId })) }, null, 2)}\n`);
}
function replacePeerLink(state, peerProject, replacement) {
  const links = readLiveMetaPeerLinks(state).filter((link) => link.peerProject !== peerProject);
  if (replacement) links.push(replacement);
  writePeerLinks(state, links);
}
function removePeerLink(state, peerProject) {
  writePeerLinks(state, readLiveMetaPeerLinks(state).filter((link) => link.peerProject !== peerProject));
}
function createNetwork(ctx, identity) {
  const args = ['network', 'create', '--driver', 'bridge', '--internal'];
  for (const [name, value] of Object.entries(identity.labels)) args.push('--label', `${name}=${value}`);
  args.push(identity.network);
  const created = docker(ctx, args, { allowFailure: true });
  if (created.status !== 0 && !inspect(ctx, 'network', identity.network)) {
    fail(`Could not create internal Docker network ${identity.network}: ${(created.stderr || '').trim().slice(-600)}`);
  }
  const network = validatePairNetwork(ctx, identity, new Map(), { requireAliases: false });
  if (!network) fail(`Docker did not create ${identity.network}.`);
  return network;
}
function connectApp(ctx, identity, apps, project) {
  const app = apps.get(project);
  if (!app) fail(`No owned MetaMCP app container was found for ${project}.`);
  const id = projectId(project);
  const network = validatePairNetwork(ctx, identity, apps, { requireAliases: false });
  if (!network) fail(`Docker network ${identity.network} disappeared during linking.`);
  const endpoint = app.NetworkSettings?.Networks?.[identity.network];
  const attached = Object.hasOwn(network.Containers || {}, app.Id);
  if (attached && endpoint?.NetworkID === network.Id && (endpoint.Aliases || []).includes(peerAlias(id))) return;
  if (attached) docker(ctx, ['network', 'disconnect', identity.network, app.Id]);
  docker(ctx, ['network', 'connect', '--alias', peerAlias(id), identity.network, app.Id]);
}
export function assertMetaPeerAppsRunning(ctx, source, target) {
  assertMetaState(source); assertMetaState(target);
  const identity = pairIdentity(source.project, target.project);
  pairApps(ctx, identity, source, target, { requireRunning: true });
}
export function probeMetaPeerEndpoint(ctx, source, target, sourceUrl, apiKey = null) {
  assertMetaState(source); assertMetaState(target);
  const identity = pairIdentity(source.project, target.project);
  const apps = pairApps(ctx, identity, source, target, { requireRunning: true });
  const network = validatePairNetwork(ctx, identity, apps, { requireAliases: true });
  if (!network || network.Id !== readLiveMetaPeerLinks(source).find((item) => item.peerProject === target.project)?.networkId ||
      network.Id !== readLiveMetaPeerLinks(target).find((item) => item.peerProject === source.project)?.networkId) {
    fail('The saved MetaMCP peer network is missing or has changed; the MCP endpoint was not registered.');
  }
  for (const instance of [source, target]) {
    const app = apps.get(instance.project);
    if (!app || !Object.hasOwn(network.Containers || {}, app.Id)) fail(`The running ${instance.project} app is not attached to the peer network.`);
  }
  let url;
  try { url = new URL(sourceUrl); } catch { fail('The source MCP endpoint URL is invalid.'); }
  if (url.origin !== `http://${peerAlias(source.id)}:12008` ||
      !/^\/metamcp\/[a-zA-Z0-9_-]{1,64}\/mcp$/.test(url.pathname) || url.search || url.hash || url.username || url.password) {
    fail('The source MCP endpoint must resolve through the selected MetaMCP peer alias.');
  }
  if (apiKey !== null && (typeof apiKey !== 'string' || apiKey.length > 8192 || /[\r\n\0]/.test(apiKey))) {
    fail('The source MCP API key contains invalid characters.');
  }
  const script = `const fs=require('node:fs');const input=JSON.parse(fs.readFileSync(0,'utf8'));(async()=>{try{const headers={accept:'application/json, text/event-stream','content-type':'application/json'};if(input.apiKey)headers['X-API-Key']=input.apiKey;const response=await fetch(input.url,{method:'POST',headers,body:JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'mcpkit-peer-link',version:'1.0.0'}}}),redirect:'error',signal:AbortSignal.timeout(15000)});const text=await response.text();if(!response.ok)throw new Error('HTTP '+response.status+' '+(text||'').replace(/\\s+/g,' ').slice(0,200)+' @ '+input.url);let message=null;if((response.headers.get('content-type')||'').includes('text/event-stream')){for(const line of text.split(/\\r?\\n/)){if(line.startsWith('data:')){try{const value=JSON.parse(line.slice(5).trim());if(value&&value.id===1)message=value;}catch{}}}}else{try{message=JSON.parse(text);}catch{}}if(!message||message.jsonrpc!=='2.0'||message.id!==1||!message.result||typeof message.result.protocolVersion!=='string'||!message.result.serverInfo)throw new Error('unexpected MCP initialize response');process.stdout.write(JSON.stringify({ok:true}));}catch(error){console.error('MCP endpoint check failed: '+String(error&&error.message||'request failed').slice(0,120));process.exitCode=1;}})();`;
  const result = docker(ctx, ['exec', '-i', apps.get(target.project).Id, 'node', '-e', script], {
    input: JSON.stringify({ url: sourceUrl, apiKey }), timeout: 25000,
  });
  let checked;
  try { checked = JSON.parse(result.stdout); } catch { fail('Could not verify the source MCP endpoint from the target MetaMCP container; no server record was created.'); }
  if (checked?.ok !== true) fail('The source MCP endpoint did not complete an MCP initialize request; no server record was created.');
  console.log(`Verified MCP endpoint connectivity from ${target.project} to ${source.project}.`);
}
function pairRecordFrom(links, peerProject) { return links.find((link) => link.peerProject === peerProject) || null; }

export function linkMetaPeers(ctx, left, right) {
  assertMetaState(left); assertMetaState(right);
  if (left.project === right.project || path.resolve(left.base) === path.resolve(right.base)) fail('Choose two different independent MetaMCP directories.');
  privateDirectory(left); privateDirectory(right);
  assertComposeOverlayWritable(left); assertComposeOverlayWritable(right);
  const identity = pairIdentity(left.project, right.project);
  const leftLinks = readLiveMetaPeerLinks(left);
  const rightLinks = readLiveMetaPeerLinks(right);
  const oldLeft = pairRecordFrom(leftLinks, right.project);
  const oldRight = pairRecordFrom(rightLinks, left.project);
  if ((oldLeft && oldLeft.network !== identity.network) || (oldRight && oldRight.network !== identity.network)) fail('Saved MetaMCP peer metadata does not match this pair; no network was changed.');
  if ((!oldLeft && leftLinks.length >= 128) || (!oldRight && rightLinks.length >= 128)) fail('Each MetaMCP is limited to 128 peer networks.');
  let apps = pairApps(ctx, identity, left, right, { requireRunning: false });
  let network = inspect(ctx, 'network', identity.network);
  if (!network) network = createNetwork(ctx, identity);
  else validatePairNetwork(ctx, identity, apps, { requireAliases: false });
  // A missing/replaced network with the exact deterministic pair labels can be
  // rebuilt by this explicit command. Ordinary Compose operations stay pinned
  // to the saved network ID and fail closed until this repair is run. Stopped
  // apps are configured for automatic attachment at their next Compose start.
  for (const project of [left.project, right.project]) {
    if (apps.get(project)?.State?.Running === true) connectApp(ctx, identity, apps, project);
    apps = pairApps(ctx, identity, left, right, { requireRunning: false });
  }
  const finalApps = pairApps(ctx, identity, left, right, { requireRunning: false });
  const finalNetwork = validatePairNetwork(ctx, identity, finalApps, { requireAliases: true });
  if (!finalNetwork) fail('Could not confirm the internal MetaMCP peer network.');
  for (const project of [left.project, right.project]) {
    const app = finalApps.get(project);
    if (app.State?.Running === true && !Object.hasOwn(finalNetwork.Containers || {}, app.Id)) {
      fail(`Could not confirm the running ${project} app on its internal peer network.`);
    }
  }
  replacePeerLink(left, right.project, linkRecord(left, right, finalNetwork.Id));
  replacePeerLink(right, left.project, linkRecord(right, left, finalNetwork.Id));
  liveMetaPeerComposeFile(left);
  liveMetaPeerComposeFile(right);
  console.log(`Saved the transport network for ${left.project} → ${right.project} on ${identity.network}.`);
  console.log('Docker network metadata is stored in both kit states for lifecycle repair; the MCP server registration direction is first MetaMCP → second MetaMCP.');
  return finalNetwork;
}

export function unlinkMetaPeers(ctx, left, right) {
  assertMetaState(left); assertMetaState(right);
  if (left.project === right.project || path.resolve(left.base) === path.resolve(right.base)) fail('Choose two different independent MetaMCP directories.');
  privateDirectory(left); privateDirectory(right);
  assertComposeOverlayWritable(left); assertComposeOverlayWritable(right);
  const identity = pairIdentity(left.project, right.project);
  const leftLinksBefore = readLiveMetaPeerLinks(left);
  const rightLinksBefore = readLiveMetaPeerLinks(right);
  const oldLeft = pairRecordFrom(leftLinksBefore, right.project);
  const oldRight = pairRecordFrom(rightLinksBefore, left.project);
  const leftOverlayBefore = leftLinksBefore.length ? composeOverlay(left, leftLinksBefore) : null;
  const rightOverlayBefore = rightLinksBefore.length ? composeOverlay(right, rightLinksBefore) : null;
  const network = inspect(ctx, 'network', identity.network);
  if (network) {
    const apps = pairApps(ctx, identity, left, right, { requireRunning: false });
    const checked = validatePairNetwork(ctx, identity, apps, { requireAliases: false });
    if (!checked) fail(`Docker network ${identity.network} disappeared during unlink.`);
    for (const id of Object.keys(checked.Containers || {})) docker(ctx, ['network', 'disconnect', '--force', identity.network, id]);
    const empty = validatePairNetwork(ctx, identity, apps, { requireAliases: false });
    if (!empty || Object.keys(empty.Containers || {}).length) fail(`Docker network ${identity.network} still has members; metadata was preserved.`);
    docker(ctx, ['network', 'rm', identity.network]);
    if (inspect(ctx, 'network', identity.network)) fail(`Docker network ${identity.network} remains; saved metadata was preserved.`);
  }
  // Files are removed only after the exact pair network is gone. If interrupted
  // here, a second --unlink safely completes the metadata cleanup.
  if (oldLeft) removePeerLink(left, right.project);
  if (oldRight) removePeerLink(right, left.project);
  if (readLiveMetaPeerLinks(left).length) liveMetaPeerComposeFile(left);
  else removeGeneratedComposeFile(left, leftOverlayBefore);
  if (readLiveMetaPeerLinks(right).length) liveMetaPeerComposeFile(right);
  else removeGeneratedComposeFile(right, rightOverlayBefore);
  console.log(network || oldLeft || oldRight
    ? `Disconnected ${left.project} and ${right.project}; only their internal peer network was removed.`
    : `No MetaMCP peer link exists between ${left.project} and ${right.project}.`);
  return null;
}

export function assertLiveMetaPeerNetworks(ctx, state) {
  const links = readLiveMetaPeerLinks(state);
  for (const link of links) {
    const identity = pairIdentity(state.project, link.peerProject);
    if (identity.network !== link.network) fail('Saved MetaMCP peer network name is inconsistent; no Compose operation was run.');
    const peerId = projectId(link.peerProject);
    const apps = new Map([
      [state.project, metaApp(ctx, state.project, state.id, { requireRunning: false })],
      [link.peerProject, metaApp(ctx, link.peerProject, peerId, { requireRunning: false })],
    ]);
    const network = validatePairNetwork(ctx, identity, apps, { requireAliases: true });
    if (!network || network.Id !== link.networkId) {
      const command = process.platform === 'win32'
        ? '.\\windows\\link-metamcp.ps1 SOURCE_DIRECTORY TARGET_DIRECTORY -Endpoint ENDPOINT'
        : 'bash linux/link-metamcp.sh SOURCE_DIRECTORY TARGET_DIRECTORY --endpoint ENDPOINT';
      fail(`Saved MetaMCP peer network ${link.network} is missing or was replaced; rerun the original directional ${command} command for this pair to repair it, or unlink it before continuing.`);
    }
    for (const [project, app] of apps) {
      if (app?.State?.Running === true && !Object.hasOwn(network.Containers || {}, app.Id)) {
        fail(`Running MetaMCP ${project} is detached from its saved peer network; rerun the original directional link-metamcp command with its --endpoint value.`);
      }
    }
  }
  return links;
}
