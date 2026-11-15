#!/usr/bin/env node
// Synthetic local Docker boundary for the MetaMCP peer-link tests. It models
// container labels and network membership; it never talks to a real daemon.
const fs = require('node:fs');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
const stateFile = process.env.MCP_TEST_META_LINK_STATE;
const traceFile = process.env.MCP_TEST_META_LINK_TRACE;
if (!stateFile || !traceFile) process.exit(90);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
fs.appendFileSync(traceFile, `${JSON.stringify(args)}\n`);
function fail(message, code = 1) { console.error(message); process.exit(code); }
function output(value) { process.stdout.write(value); }
function missing(kind, name) { fail(`Error response from daemon: ${kind} ${name} not found`); }
function networkAdd(network, container, alias) {
  const aliases = [container.Name.replace(/^\//, ''), `${container.Config.Labels['com.docker.compose.project']}-app`, alias, container.Id.slice(0, 12)];
  network.Containers ||= {};
  network.Containers[container.Id] = { Name: container.Name.replace(/^\//, ''), EndpointID: `endpoint-${container.Id.slice(0, 12)}`, MacAddress: '02:42:ac:10:00:02', IPv4Address: '172.30.0.2/16' };
  container.NetworkSettings.Networks ||= {};
  container.NetworkSettings.Networks[network.Name] = { NetworkID: network.Id, Aliases: [...new Set(aliases)] };
}
function networkDrop(network, containerId) {
  const container = state.containers[containerId];
  delete network.Containers?.[containerId];
  if (container?.NetworkSettings?.Networks) delete container.NetworkSettings.Networks[network.Name];
}
let command = args;
if (args[0] === '--context') {
  if (args[1] !== 'default') fail(`unexpected context ${args[1]}`);
  command = args.slice(2);
}
if (command[0] === 'context' && command[1] === 'show') { output('default\n'); process.exit(0); }
if (command[0] === 'context' && command[1] === 'inspect') { output('unix:///var/run/docker.sock\n'); process.exit(0); }
if (command[0] === 'info') { output('local synthetic Docker\n'); process.exit(0); }
if (command[0] === 'compose' && command[1] === 'version') { output('Docker Compose version v2.32.1\n'); process.exit(0); }
if (command[0] === 'compose') {
  const subcommand = command.find((item) => ['ps', 'up', 'down', 'config'].includes(item));
  if (subcommand === 'ps') { output('synthetic MetaMCP containers\n'); process.exit(0); }
  fail(`unexpected Compose command: ${command.join(' ')}`);
}
if (command[0] === 'exec') {
  if (command[1] !== '-i') fail('peer endpoint probe must pass credentials over stdin');
  const targetId = command[2];
  const target = state.containers[targetId];
  if (!target || target.State?.Running !== true) fail('peer endpoint probe target is not running');
  const evalAt = command.indexOf('-e');
  if (evalAt < 0 || typeof command[evalAt + 1] !== 'string') fail('peer endpoint probe script is missing');
  const syntax = spawnSync(process.execPath, ['--check'], { input: command[evalAt + 1], encoding: 'utf8' });
  if (syntax.error || syntax.status !== 0) fail(`invalid peer endpoint probe script: ${(syntax.stderr || '').slice(-300)}`);
  let input;
  try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { fail('invalid peer endpoint probe input'); }
  let endpoint;
  try { endpoint = new URL(input.url); } catch { fail('invalid peer endpoint probe URL'); }
  const networkName = Object.keys(target.NetworkSettings?.Networks || {}).find((name) => name.startsWith('mcpkit-meta-peer-'));
  const network = networkName && state.networks[networkName];
  const peer = network && Object.values(state.containers).find((item) => item.Id !== targetId &&
    item.NetworkSettings?.Networks?.[networkName]?.Aliases?.includes(endpoint.hostname));
  if (!network || !peer) fail('peer DNS alias is unreachable from target app');
  state.probes ||= [];
  state.probes.push({ targetId, peerId: peer.Id, url: input.url, hasApiKey: Boolean(input.apiKey) });
  if (process.env.MCP_TEST_META_LINK_PROBE_FAIL === '1') fail('MCP endpoint check failed: HTTP 401', 43);
  save(); output(JSON.stringify({ ok: true }) + String.fromCharCode(10)); process.exit(0);
}
if (command[0] === 'container' && command[1] === 'ls') {
  const filters = [];
  for (let i = 0; i < command.length - 1; i++) if (command[i] === '--filter') filters.push(command[++i]);
  let containers = Object.values(state.containers);
  for (const filter of filters) {
    const [key, value] = filter.replace(/^label=/, '').split('=');
    containers = containers.filter((item) => item.Config.Labels[key] === value);
  }
  output(containers.map((item) => item.Id).join('\n') + (containers.length ? '\n' : ''));
  process.exit(0);
}
if (['container', 'network', 'volume'].includes(command[0]) && command[1] === 'inspect') {
  const kind = command[0];
  const name = command.at(-1);
  const item = kind === 'container'
    ? (state.containers[name] || Object.values(state.containers).find((entry) => entry.Name.replace(/^\//, '') === name))
    : kind === 'network' ? state.networks[name] : state.volumes?.[name];
  if (!item) missing(kind, name);
  const formatAt = command.indexOf('--format');
  if (formatAt >= 0) {
    const format = command[formatAt + 1];
    if (kind === 'container' && format === '{{json .Config.Labels}}') { output(`${JSON.stringify(item.Config.Labels)}\n`); process.exit(0); }
    if (kind === 'network' && format === '{{json .Labels}}') { output(`${JSON.stringify(item.Labels)}\n`); process.exit(0); }
    if (kind === 'volume' && format === '{{json .Labels}}') { output(`${JSON.stringify(item.Labels)}\n`); process.exit(0); }
    fail(`unexpected inspect format ${format}`);
  }
  output(`${JSON.stringify([item])}\n`);
  process.exit(0);
}
if (command[0] === 'network' && command[1] === 'create') {
  const networkName = command.at(-1);
  if (state.networks[networkName]) fail(`Error response from daemon: network with name ${networkName} already exists`);
  const labels = {};
  for (let i = 2; i < command.length; i++) {
    if (command[i] === '--label') {
      const [key, ...rest] = command[++i].split('='); labels[key] = rest.join('=');
    }
  }
  state.networkSequence = (state.networkSequence || 0) + 1;
  const item = { Id: crypto.createHash('sha256').update(`${networkName}:${state.networkSequence}`).digest('hex'), Name: networkName,
    Driver: 'bridge', Scope: 'local', Internal: command.includes('--internal'), Labels: labels, Containers: {} };
  state.networks[networkName] = item; save(); output(`${item.Id}\n`); process.exit(0);
}
if (command[0] === 'network' && command[1] === 'connect') {
  const aliasAt = command.indexOf('--alias');
  const alias = aliasAt >= 0 ? command[aliasAt + 1] : '';
  const networkName = command[aliasAt >= 0 ? aliasAt + 2 : 2];
  const containerId = command.at(-1);
  const network = state.networks[networkName]; const container = state.containers[containerId];
  if (!network || !container) fail('network connect target missing');
  if (network.Containers?.[containerId]) fail('endpoint already exists');
  networkAdd(network, container, alias); save(); process.exit(0);
}
if (command[0] === 'network' && command[1] === 'disconnect') {
  const networkName = command.at(-2); const containerId = command.at(-1); const network = state.networks[networkName];
  if (!network) missing('network', networkName);
  if (!network.Containers?.[containerId]) fail(`container ${containerId} is not connected`);
  networkDrop(network, containerId); save(); process.exit(0);
}
if (command[0] === 'network' && command[1] === 'rm') {
  const networkName = command.at(-1); const network = state.networks[networkName];
  if (!network) missing('network', networkName);
  if (Object.keys(network.Containers || {}).length) fail(`network ${networkName} has active endpoints`);
  delete state.networks[networkName]; save(); output(`${networkName}\n`); process.exit(0);
}
fail(`unexpected Docker command: ${command.join(' ')}`);
