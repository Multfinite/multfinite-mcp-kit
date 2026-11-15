// Register one independent MetaMCP endpoint as a remote MCP server in another
// independent MetaMCP. Records are created through the authenticated frontend
// API, never by direct database access; existing records are not adopted or
// modified.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const NAME_RE = /^[a-zA-Z0-9_-]{1,64}$/;
const UUID_RE = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const SERVER_KEYS = ['uuid', 'name', 'description', 'type', 'command', 'args', 'env', 'url', 'bearerToken', 'headers', 'forward_headers', 'user_id'];

function fail(message) { throw new Error(message); }
function digest(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}
function assertMetaState(state) {
  if (!state || state.version !== 1 || state.type !== 'meta' || !/^[a-f0-9]{16}$/.test(state.id || '') ||
      state.project !== `mcpkit-meta-${state.id}` || typeof state.base !== 'string' ||
      !path.isAbsolute(state.base) || path.resolve(state.base) !== state.base ||
      !Number.isInteger(state.port) || state.port < 1 || state.port > 65535 || typeof state.appUrl !== 'string') {
    fail('MetaMCP peer registration requires two independent kit MetaMCP states.');
  }
}
function privateDirectory(state) {
  assertMetaState(state);
  let base;
  let directory;
  try {
    base = fs.lstatSync(state.base);
    directory = fs.lstatSync(path.join(state.base, '.mcpkit'));
  } catch { fail(`The private .mcpkit state is incomplete for ${state.project}.`); }
  if (!base.isDirectory() || base.isSymbolicLink() || !directory.isDirectory() || directory.isSymbolicLink() ||
      (process.platform !== 'win32' && (directory.mode & 0o077) !== 0)) {
    fail(`The ${state.project} state directory must be a private, real directory.`);
  }
  return path.join(state.base, '.mcpkit');
}

export function resolveMetaPeerEndpoint(source, endpoint) {
  assertMetaState(source);
  if (typeof endpoint !== 'string' || !endpoint || endpoint !== endpoint.trim() || /[\r\n\0]/.test(endpoint)) {
    fail('Pass --endpoint as a MetaMCP endpoint name or its full /metamcp/<name>/mcp URL.');
  }
  let name = endpoint;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(endpoint)) {
    let url;
    try { url = new URL(endpoint); } catch { fail('The source endpoint URL is invalid.'); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash ||
        url.pathname.includes('%') || url.pathname.includes('..')) {
      fail('The source endpoint URL must be a plain HTTP(S) MetaMCP endpoint without credentials, query or fragment.');
    }
    const match = /^\/metamcp\/([a-zA-Z0-9_-]{1,64})\/mcp$/.exec(url.pathname);
    if (!match) fail('The source endpoint URL must have the form /metamcp/<name>/mcp.');
    const allowedOrigins = new Set([
      source.appUrl,
      `http://localhost:${source.port}`,
      `http://127.0.0.1:${source.port}`,
      ...(source.lanIp ? [`http://${source.lanIp}:${source.port}`] : []),
    ]);
    if (!allowedOrigins.has(url.origin)) fail('The source endpoint URL does not belong to the selected MetaMCP A.');
    name = match[1];
  }
  if (!NAME_RE.test(name)) fail('Endpoint names may contain only letters, digits, underscores and hyphens (1–64 characters).');
  const serverName = `mcpkit-meta-${source.id}-${name}`;
  return {
    name,
    serverName,
    sourceUrl: `http://mcpkit-meta-${source.id}:12008/metamcp/${name}/mcp`,
  };
}

function readSourceApiKey(source) {
  const file = path.join(privateDirectory(source), 'client-api-key');
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
    fail(`The private client API key file for ${source.project} is not a protected regular file.`);
  }
  const key = fs.readFileSync(file, 'utf8').trim();
  if (!/^sk_mt_[A-Za-z0-9]{64}$/.test(key)) fail(`The private client API key for ${source.project} is invalid.`);
  return key;
}
function readSavedClientKey(state) {
  const file = path.join(privateDirectory(state), 'client-api-key');
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) ||
      !/^sk_mt_[A-Za-z0-9]{64}\s*$/.test(fs.readFileSync(file, 'utf8'))) {
    fail(`The private client API key file for ${state.project} is invalid.`);
  }
  return file;
}
function question(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(prompt, (answer) => { rl.close(); resolve(answer.trim()); });
  });
}
function hiddenInput(prompt, { optional = false } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) fail('This operation needs a terminal for private credentials; secrets are never accepted as command-line arguments.');
  return new Promise((resolve, reject) => {
    let value = '';
    let settled = false;
    process.stdout.write(prompt);
    const cleanup = () => {
      process.stdin.off('data', onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write('\n');
    };
    const onData = (chunk) => {
      for (const c of String(chunk)) {
        if (c === '\u0003') {
          if (!settled) { settled = true; cleanup(); reject(new Error('Cancelled.')); }
          return;
        }
        if (c === '\r' || c === '\n') {
          if (!settled) {
            settled = true;
            cleanup();
            if (!optional && !value) reject(new Error('A non-empty value is required.'));
            else resolve(value);
          }
          return;
        }
        if (c === '\u007f' || c === '\b') { value = Array.from(value).slice(0, -1).join(''); continue; }
        if (c >= ' ' && c !== '\u007f' && value.length < 8192) value += c;
      }
    };
    process.stdin.setEncoding('utf8');
    process.stdin.setRawMode(true);
    process.stdin.on('data', onData);
    process.stdin.resume();
  });
}
async function credentials(source, target) {
  let sourceApiKey = readSourceApiKey(source);
  if (sourceApiKey === null) {
    sourceApiKey = await hiddenInput(
      `API key for endpoint ${source.project} (press Enter only if that endpoint is open): `,
      { optional: true },
    );
    if (sourceApiKey && /[\r\n\0]/.test(sourceApiKey)) fail('Invalid source API key.');
  }
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    fail('MetaMCP B registration requires an interactive administrator login; credentials are never accepted in arguments.');
  }
  const email = await question(`Administrator email for ${target.project}: `);
  const password = await hiddenInput('MetaMCP B password (not echoed): ');
  if (!email || /[\r\n\0]/.test(email) || !password) fail('Administrator email and password are required.');
  return { sourceApiKey, email, password };
}
function cookieFrom(response) {
  const lines = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : [response.headers.get('set-cookie') || ''];
  const pairs = [];
  for (const line of lines) {
    for (const part of line.split(/,\s*(?=[^;,=\s]+=[^;,]*)/)) {
      const pair = part.split(';', 1)[0].trim();
      if (/^[^=;\s]+=[^;\r\n]+$/.test(pair)) pairs.push(pair);
    }
  }
  return pairs.join('; ');
}
function clientFor(target, cookie = '') {
  const origin = target.appUrl;
  let parsedOrigin;
  try { parsedOrigin = new URL(origin); } catch { fail('The target MetaMCP has an invalid application origin.'); }
  if (!['http:', 'https:'].includes(parsedOrigin.protocol) || parsedOrigin.pathname !== '/' ||
      parsedOrigin.username || parsedOrigin.password || parsedOrigin.search || parsedOrigin.hash) {
    fail('The target MetaMCP application origin is invalid.');
  }
  const localAddress = `http://127.0.0.1:${target.port}`;
  async function request(url, options = {}) {
    const parsed = new URL(url);
    if (parsed.origin !== origin) fail('Unexpected MetaMCP API request origin.');
    const headers = {
      ...(options.headers || {}),
      host: parsedOrigin.host,
      origin,
    };
    let response;
    try {
      response = await fetch(`${localAddress}${parsed.pathname}${parsed.search}`, {
        ...options, headers, redirect: 'error', signal: AbortSignal.timeout(30000),
      });
    } catch {
      fail('Could not reach the selected MetaMCP B through its local published port.');
    }
    let body;
    try { body = await response.json(); } catch { fail(`MetaMCP B returned non-JSON (HTTP ${response.status}).`); }
    if (!response.ok) fail(`MetaMCP B rejected an API request (HTTP ${response.status}); check login, permissions and version.`);
    return { response, body };
  }
  async function trpc(procedure, input, mutation = false) {
    const headers = { cookie };
    const options = { headers };
    let suffix = '';
    if (mutation) {
      options.method = 'POST';
      headers['content-type'] = 'application/json';
      options.body = JSON.stringify(input);
    } else if (input !== undefined) suffix = `?input=${encodeURIComponent(JSON.stringify(input))}`;
    const { body } = await request(`${origin}/trpc/frontend.${procedure}${suffix}`, options);
    let value = body?.result?.data;
    if (value && typeof value === 'object' && Object.hasOwn(value, 'json')) value = value.json;
    if (!value || typeof value !== 'object' || value.success !== true) {
      fail(`MetaMCP procedure ${procedure} failed; existing records were not updated or deleted.`);
    }
    return value.data;
  }
  return { origin, request, trpc, get cookie() { return cookie; }, set cookie(value) { cookie = value; } };
}
async function login(target, email, password) {
  const client = clientFor(target);
  const { response } = await client.request(`${client.origin}/api/auth/sign-in/email`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password }),
  });
  const cookie = cookieFrom(response);
  if (!cookie) fail('MetaMCP B login did not return a session cookie.');
  client.cookie = cookie;
  const session = await client.request(`${client.origin}/api/auth/get-session`, { headers: { cookie } });
  if (!session.body?.user?.id || typeof session.body.user.id !== 'string') fail('The MetaMCP B session is not authenticated.');
  return { client, userId: session.body.user.id };
}
async function requireAdmin(client) {
  let result;
  try { result = await client.trpc('config.getAllConfigs'); }
  catch { fail('Cannot confirm administrator access to MetaMCP B; no records were changed.'); }
  let value = result;
  if (value && !Array.isArray(value) && typeof value === 'object' && Object.hasOwn(value, 'json')) value = value.json;
  if (!Array.isArray(value)) fail('Cannot confirm MetaMCP B administrator access or API version; no records were changed.');
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
function serverHash(server) {
  return digest(JSON.stringify(canonical(Object.fromEntries(SERVER_KEYS.map((key) => [key, server[key] ?? null])))));
}
function atomicWrite(file, object) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(object, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally { try { fs.unlinkSync(temporary); } catch { /* renamed or absent */ } }
}
function registrationStore(target) {
  const privateDir = privateDirectory(target);
  const directory = path.join(privateDir, 'metamcp-peer-registrations');
  try { fs.mkdirSync(directory, { mode: 0o700 }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
    fail('The MetaMCP peer registration journal directory must be a private, real directory.');
  }
  return directory;
}
function validJournal(value, prepared) {
  return exactKeys(value, ['version', 'sourceProject', 'sourceEndpoint', 'sourceUrl', 'targetProject', 'targetOrigin', 'owner', 'server', 'namespace', 'endpoint', 'pending']) &&
    value.version === 1 && value.sourceProject === prepared.source.project && value.sourceEndpoint === prepared.endpointName &&
    value.sourceUrl === prepared.sourceUrl && value.targetProject === prepared.target.project &&
    value.targetOrigin === prepared.client.origin && value.owner === prepared.userId &&
    (value.server === null || (value.server && typeof value.server === 'object')) &&
    (value.namespace === null || (value.namespace && typeof value.namespace === 'object')) &&
    (value.endpoint === null || (value.endpoint && typeof value.endpoint === 'object')) &&
    (value.pending === null || (value.pending && typeof value.pending.kind === 'string' && typeof value.pending.name === 'string'));
}
function validSavedRecord(record, name) {
  return record && typeof record === 'object' && UUID_RE.test(record.uuid || '') && record.name === name;
}
function serverMatches(current, saved, desired) {
  return current && current.uuid === saved.uuid && current.name === desired.name && current.type === desired.type &&
    current.url === desired.url && current.description === desired.description && current.user_id === null &&
    JSON.stringify(canonical(current.headers || {})) === JSON.stringify(canonical(desired.headers || {})) &&
    serverHash(current) === saved.hash;
}
function hasOpenEndpoint(endpoints, namespaceUuid) {
  return endpoints.some((item) => item.namespace_uuid === namespaceUuid && !item.enable_api_key_auth && !item.enable_oauth);
}

export async function prepareMetaPeerRegistration(source, target, endpoint, suppliedCredentials = null) {
  assertMetaState(source); assertMetaState(target);
  if (source.project === target.project || source.base === target.base) fail('Choose a source MetaMCP A and a different target MetaMCP B.');
  const resolved = resolveMetaPeerEndpoint(source, endpoint);
  const values = suppliedCredentials || await credentials(source, target);
  const providedApiKey = values.sourceApiKey ?? readSourceApiKey(source);
  if (providedApiKey !== null && providedApiKey !== undefined && providedApiKey !== '' &&
      (typeof providedApiKey !== 'string' || !/^[\x21-\x7e]{1,8192}$/.test(providedApiKey))) {
    fail('The source MetaMCP API key contains invalid characters.');
  }
  const sourceApiKey = providedApiKey || null;
  if (!values || typeof values.email !== 'string' || !values.email || typeof values.password !== 'string' || !values.password) {
    fail('MetaMCP B administrator email and password are required.');
  }
  const targetClientKeyFile = readSavedClientKey(target);
  const { client, userId } = await login(target, values.email, values.password);
  await requireAdmin(client);
  return {
    source, target, endpointName: resolved.name, serverName: resolved.serverName,
    sourceUrl: resolved.sourceUrl, sourceApiKey: sourceApiKey || null,
    targetClientKeyFile, client, userId,
  };
}

export async function commitMetaPeerRegistration(prepared) {
  const { source, target, endpointName } = prepared;
  const store = registrationStore(target);
  const journalFile = path.join(store, `${digest(`${source.project}\n${target.project}\n${endpointName}`)}.json`);
  const lockFile = `${journalFile}.lock`;
  let lock;
  try { lock = fs.openSync(lockFile, 'wx', 0o600); }
  catch { fail(`MetaMCP peer registration may already be running; inspect ${lockFile} before removing a stale lock.`); }
  try { return await commitMetaPeerRegistrationLocked(prepared, journalFile); }
  finally { fs.closeSync(lock); fs.unlinkSync(lockFile); }
}

async function commitMetaPeerRegistrationLocked(prepared, journalFile) {
  const { source, target, endpointName, serverName, sourceUrl, sourceApiKey, targetClientKeyFile, client, userId } = prepared;
  let journal;
  try {
    const stat = fs.lstatSync(journalFile);
    if (!stat.isFile() || stat.isSymbolicLink() ||
        (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) fail('Invalid MetaMCP peer registration journal; it was preserved.');
    try { journal = JSON.parse(fs.readFileSync(journalFile, 'utf8')); } catch { fail('Invalid MetaMCP peer registration journal; it was preserved.'); }
    if (!validJournal(journal, prepared)) fail('Saved MetaMCP peer registration state differs from the selected source, target or endpoint; no API records were changed.');
    if (journal.pending) fail(`A previous ${journal.pending.kind} ${journal.pending.name} operation has an unknown outcome. Inspect MetaMCP B and the private journal before retrying.`);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (!journal) {
    journal = {
      version: 1, sourceProject: source.project, sourceEndpoint: endpointName, sourceUrl,
      targetProject: target.project, targetOrigin: client.origin, owner: userId,
      server: null, namespace: null, endpoint: null, pending: null,
    };
    atomicWrite(journalFile, journal);
  }
  const save = () => atomicWrite(journalFile, journal);
  const [servers, namespaces, endpoints] = await Promise.all([
    client.trpc('mcpServers.list'), client.trpc('namespaces.list'), client.trpc('endpoints.list'),
  ]);
  if (!Array.isArray(servers) || !Array.isArray(namespaces) || !Array.isArray(endpoints)) fail('MetaMCP B returned an unexpected records list.');
  const description = `MCP Kit peer ${source.project} endpoint ${endpointName}`;
  const desiredServer = {
    name: serverName, description, type: 'STREAMABLE_HTTP', url: sourceUrl,
    headers: sourceApiKey ? { 'X-API-Key': sourceApiKey } : {}, user_id: null,
  };
  const kinds = [
    ['server', journal.server, servers, serverName],
    ['namespace', journal.namespace, namespaces, serverName],
    ['endpoint', journal.endpoint, endpoints, serverName],
  ];
  for (const [kind, saved, current, name] of kinds) {
    if (saved) {
      if (!validSavedRecord(saved, name) || !current.some((item) => item.uuid === saved.uuid && item.name === name && item.user_id === null)) {
        fail(`Previously created ${kind} ${name} is missing, private or renamed; it was not recreated.`);
      }
    } else if (current.some((item) => item.name === name)) {
      fail(`${kind[0].toUpperCase()}${kind.slice(1)} name ${name} is already in use; it was not adopted or changed.`);
    }
  }
  if (journal.server) {
    const existing = servers.find((item) => item.uuid === journal.server.uuid);
    if (!serverMatches(existing, journal.server, desiredServer)) {
      fail(`Previously created server ${serverName} was edited or no longer matches endpoint ${endpointName}; it was not updated.`);
    }
  } else {
    async function createServer() {
      journal.pending = { kind: 'server', name: serverName }; save();
      const created = await client.trpc('mcpServers.create', desiredServer, true);
      if (!created || !UUID_RE.test(created.uuid || '') || created.name !== serverName || created.user_id !== null ||
          created.type !== desiredServer.type || created.url !== desiredServer.url ||
          JSON.stringify(canonical(created.headers || {})) !== JSON.stringify(canonical(desiredServer.headers))) {
        fail('MetaMCP B returned an unexpected server record; inspect the pending operation before retrying.');
      }
      journal.server = { uuid: created.uuid, name: serverName, hash: serverHash(created) };
      journal.pending = null; save();
      servers.push(created);
    }
    await createServer();
  }
  let namespace = journal.namespace ? namespaces.find((item) => item.uuid === journal.namespace.uuid) : null;
  if (journal.namespace && !namespace) fail(`Previously created namespace ${serverName} is missing; it was not recreated.`);
  if (!namespace) {
    journal.pending = { kind: 'namespace', name: serverName }; save();
    namespace = await client.trpc('namespaces.create', {
      name: serverName, description, mcpServerUuids: [journal.server.uuid], user_id: null,
    }, true);
    if (!namespace || !UUID_RE.test(namespace.uuid || '') || namespace.name !== serverName || namespace.user_id !== null) {
      fail('MetaMCP B returned an unexpected namespace; inspect the pending operation before retrying.');
    }
    journal.namespace = { uuid: namespace.uuid, name: serverName };
    journal.pending = null; save();
    namespaces.push(namespace);
  }
  const detailed = await client.trpc('namespaces.get', { uuid: journal.namespace.uuid });
  const members = Array.isArray(detailed?.servers) ? detailed.servers.map((item) => item.uuid).sort() : [];
  if (detailed?.user_id !== null || detailed?.name !== serverName ||
      JSON.stringify(members) !== JSON.stringify([journal.server.uuid].sort())) {
    fail(`Namespace ${serverName} was changed or does not contain exactly the selected remote server; no endpoint was added.`);
  }
  if (journal.endpoint) {
    const existing = endpoints.find((item) => item.uuid === journal.endpoint.uuid);
    if (!existing || existing.namespace_uuid !== journal.namespace.uuid || existing.name !== serverName ||
        existing.user_id !== null || !existing.enable_api_key_auth || existing.enable_oauth || existing.enable_metamcp_admin_tools) {
      fail(`Previously created endpoint ${serverName} is missing or was edited; it was not recreated.`);
    }
    if (hasOpenEndpoint(endpoints, journal.namespace.uuid)) fail(`Namespace ${serverName} also has an unauthenticated endpoint; inspect it before use.`);
  } else {
    if (hasOpenEndpoint(endpoints, journal.namespace.uuid)) fail(`Namespace ${serverName} has an unauthenticated endpoint; no new endpoint was added.`);
    if (endpoints.some((item) => item.name === serverName)) fail(`Endpoint name ${serverName} is already in use; it was not adopted or changed.`);
    journal.pending = { kind: 'endpoint', name: serverName }; save();
    const created = await client.trpc('endpoints.create', {
      name: serverName, description, namespaceUuid: journal.namespace.uuid,
      enableApiKeyAuth: true, enableOauth: false, useQueryParamAuth: false,
      enableClientMaxRate: false, enableMaxRate: false, enableMetamcpAdminTools: false,
      createMcpServer: false, user_id: null,
    }, true);
    if (!created || !UUID_RE.test(created.uuid || '') || created.name !== serverName || created.user_id !== null ||
        created.namespace_uuid !== journal.namespace.uuid || !created.enable_api_key_auth || created.enable_oauth || created.enable_metamcp_admin_tools) {
      fail('MetaMCP B returned an unexpected protected endpoint; inspect the pending operation before retrying.');
    }
    journal.endpoint = { uuid: created.uuid, name: serverName };
    journal.pending = null; save();
    endpoints.push(created);
  }
  const targetHostUrl = `http://127.0.0.1:${target.port}/metamcp/${serverName}/mcp`;
  const targetContainerUrl = `http://mcpkit-meta-${target.id}:12008/metamcp/${serverName}/mcp`;
  const clientKeyFile = targetClientKeyFile;
  console.log(`Registered ${source.project} endpoint ${endpointName} in ${target.project} as server, namespace and endpoint ${serverName}.`);
  console.log(`MCP server URL stored in B: ${sourceUrl}`);
  console.log(`Protected endpoint on B: ${targetHostUrl}`);
  console.log(`From another container on the peer network, B's endpoint is: ${targetContainerUrl}`);
  console.log(clientKeyFile
    ? `A valid MetaMCP B API key is available at ${clientKeyFile}; the endpoint requires API-key authentication.`
    : 'The endpoint on B requires API-key authentication; create a MetaMCP API key in B before using it.');
  console.log(`Private registration journal: ${journalFile}`);
  return { name: serverName, sourceUrl, targetHostUrl, targetContainerUrl };
}
