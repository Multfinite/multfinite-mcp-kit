import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function sameSecret(received, expected) {
  if (typeof received !== 'string' || typeof expected !== 'string') return false;
  const a = Buffer.from(received, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function withoutHopByHop(headers) {
  const result = { ...headers };
  const nominated = String(headers.connection || '').toLowerCase().split(',').map((item) => item.trim());
  for (const name of ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', ...nominated]) delete result[name];
  return result;
}

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Length': Buffer.byteLength(data),
  });
  res.end(data);
}

async function unusedLoopbackPort() {
  const probe = net.createServer();
  await new Promise((resolve, reject) => {
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', resolve);
  });
  const { port } = probe.address();
  await new Promise((resolve, reject) => probe.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function proxyIsReady(port, key) {
  // A listening socket alone does not mean the upstream MCP server initialized.
  // Use the per-proxy secret to initialize a disposable session and close it.
  const call = (method, body, session) => new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const headers = { 'X-API-Key': key, Accept: 'application/json, text/event-stream' };
    if (body) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = Buffer.byteLength(data); }
    if (session) headers['Mcp-Session-Id'] = session;
    const req = http.request({ host: '127.0.0.1', port, path: '/mcp', method, headers, timeout: 5000 }, (res) => {
      let response = '';
      res.setEncoding('utf8');
      res.on('data', (part) => { response += part; if (response.length > 200000) req.destroy(); });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: response }));
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('Probe timed out')));
    req.on('error', reject);
    req.end(data);
  });
  let session;
  try {
    const response = await call('POST', { jsonrpc: '2.0', id: 0, method: 'initialize', params: {
      protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'mcpkit-readiness', version: '1.0.0' },
    } });
    session = response.headers['mcp-session-id'];
    if (response.status !== 200) return false;
    const content = String(response.headers['content-type'] || '').includes('text/event-stream')
      ? response.body.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n')
      : response.body;
    const message = JSON.parse(content);
    return message.id === 0 && Boolean(message.result?.protocolVersion) && !message.error;
  } catch {
    return false;
  } finally {
    if (session) { try { await call('DELETE', null, session); } catch { /* already closed */ } }
  }
}

async function terminateTree(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === 'win32') {
    // Only PIDs returned by spawn in this process are used, never a PID read
    // from disk. /T also stops the stdio server underneath mcp-proxy.
    try { await execFileAsync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }); }
    catch { try { child.kill(); } catch { /* already stopped */ } }
  } else {
    try { process.kill(-child.pid, 'SIGTERM'); }
    catch { try { child.kill(); } catch { /* already stopped */ } }
  }
}

/**
 * One authenticated gateway, with one path per native Windows MCP server.
 * Each mcp-proxy listens only on loopback and gets a separate ephemeral key;
 * the externally usable gateway key is never passed to the upstream process.
 * `specs` are local, trusted installer configuration, never HTTP input.
 */
export async function startGateway({ settings, gatewayKey, controlKey, instanceId, specs, proxyPath, logDir, nodePath = process.execPath, retryMs = 5000, startupTimeoutMs = 180000 }) {
  if (!gatewayKey || !controlKey || gatewayKey === controlKey) throw new Error('Two distinct gateway and control keys are required.');
  if (!fs.existsSync(proxyPath)) throw new Error(`mcp-proxy is missing: ${proxyPath}`);
  if (Boolean(settings.tlsCertFile) !== Boolean(settings.tlsKeyFile)) throw new Error('Both TLS certificate and private key are required.');
  if (!['127.0.0.1', '::1', 'localhost'].includes(settings.listenHost.toLowerCase()) && !settings.tlsCertFile && !settings.allowInsecureLan) {
    throw new Error('Refusing a non-loopback HTTP listener. Configure TLS or explicitly allow an encrypted private tunnel/VPN.');
  }
  fs.mkdirSync(logDir, { recursive: true });
  const records = new Map();
  for (const spec of specs) {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(spec.id) || records.has(spec.id)) throw new Error(`Invalid or duplicate server id: ${spec.id}`);
    records.set(spec.id, { spec, status: spec.waitReason ? 'waiting' : 'starting', detail: spec.waitReason || '', child: null, timer: null, port: null, internalKey: null });
  }
  let shuttingDown = false;
  let shutdownPromise;

  function snapshot() {
    return {
      instanceId,
      servers: [...records.values()].map(({ spec, status, detail }) => ({ id: spec.id, status, detail })),
    };
  }

  const handler = (req, res) => {
    if (req.url === '/_mcpkit/status' || req.url === '/_mcpkit/stop') {
      if (!sameSecret(req.headers['x-mcpkit-control'], controlKey)) return json(res, 401, { error: 'unauthorized' });
      if (req.url === '/_mcpkit/status' && req.method === 'GET') return json(res, 200, snapshot());
      if (req.url === '/_mcpkit/stop' && req.method === 'POST') {
        json(res, 200, { stopping: true, instanceId });
        setImmediate(() => { void close(); });
        return;
      }
      return json(res, 405, { error: 'method_not_allowed' });
    }
    if (!sameSecret(req.headers['x-api-key'], gatewayKey)) return json(res, 401, { error: 'unauthorized' });
    const match = /^\/servers\/([a-z0-9]+(?:-[a-z0-9]+)*)\/mcp$/.exec(req.url || '');
    if (!match || !records.has(match[1])) return json(res, 404, { error: 'not_found' });
    if (!['GET', 'POST', 'DELETE'].includes(req.method)) return json(res, 405, { error: 'method_not_allowed' });
    const record = records.get(match[1]);
    if (record.status !== 'ready' || !record.port) return json(res, 503, { error: 'server_not_ready', status: record.status });
    // Connection-specific headers apply to one HTTP hop only. In particular,
    // forwarding a client's `Connection: close` into a pooled local socket
    // can make the next MCP notification fail with HTTP 400.
    const headers = withoutHopByHop(req.headers);
    headers.host = `127.0.0.1:${record.port}`;
    headers['x-api-key'] = record.internalKey;
    // Do not forward another principal's bearer token or a control credential.
    delete headers.authorization;
    delete headers['x-mcpkit-control'];
    const upstream = http.request({ host: '127.0.0.1', port: record.port, path: '/mcp', method: req.method, headers }, (response) => {
      res.writeHead(response.statusCode || 502, withoutHopByHop(response.headers));
      response.pipe(res);
    });
    upstream.on('error', () => {
      if (!res.headersSent) json(res, 502, { error: 'upstream_unavailable' });
      else res.destroy();
    });
    req.on('aborted', () => upstream.destroy());
    res.on('close', () => { if (!res.writableEnded) upstream.destroy(); });
    req.pipe(upstream);
  };

  const server = settings.tlsCertFile
    ? https.createServer({ cert: fs.readFileSync(settings.tlsCertFile), key: fs.readFileSync(settings.tlsKeyFile) }, handler)
    : http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(settings.port, settings.listenHost, () => { server.off('error', reject); resolve(); });
  });

  async function launch(record) {
    if (shuttingDown || record.spec.waitReason) return;
    const { spec } = record;
    if (!fs.existsSync(spec.command) || (spec.entry && !fs.existsSync(spec.entry))) {
      record.status = 'error';
      record.detail = 'Package is not installed; rerun install-local.ps1.';
      return;
    }
    record.status = 'starting';
    record.detail = '';
    try {
      record.port = await unusedLoopbackPort();
      if (shuttingDown) return;
      record.internalKey = crypto.randomBytes(32).toString('hex');
      const logFile = path.join(logDir, `${spec.id}.log`);
      const fd = fs.openSync(logFile, 'a', 0o600);
      let child;
      try {
        // Do not inherit kit-specific credentials from the caller's shell into
        // every server. Windows environment names are case-insensitive; strip
        // all spellings before adding only this server's explicit credentials.
        const env = { ...process.env };
        const replacedNames = new Set(['MCPKIT_GATEWAY_KEY', 'MCPKIT_CONTROL_KEY', 'OBSIDIAN_API_KEY', 'DBHUB_DSN', 'DSN', 'PYTHONUNBUFFERED', 'PYTHONUTF8', 'PYTHONIOENCODING']);
        for (const name of Object.keys(env)) {
          const upper = name.toUpperCase();
          // Other MCP_PROXY_* options can change the internal listener or TLS;
          // an unrelated proxy configuration must not affect this kit.
          if (replacedNames.has(upper) || upper.startsWith('MCP_PROXY_')) delete env[name];
        }
        // PYTHONIOENCODING takes precedence over PYTHONUTF8, so override both
        // for MCP's UTF-8 stdio even if the caller uses a legacy code page.
        Object.assign(env, spec.env, { MCP_PROXY_API_KEY: record.internalKey, PYTHONUNBUFFERED: '1', PYTHONUTF8: '1', PYTHONIOENCODING: 'utf-8' });
        child = spawn(nodePath, [proxyPath, '--host', '127.0.0.1', '--port', String(record.port), '--server', 'stream', '--upstreamProtocol', 'auto', '--connectionTimeout', String(startupTimeoutMs), '--', spec.command, ...spec.args], {
          env, cwd: spec.cwd, windowsHide: true, detached: process.platform !== 'win32', stdio: ['ignore', fd, fd],
        });
      } finally { fs.closeSync(fd); }
      record.child = child;
      let ended = false;
      const onExit = (reason) => {
        if (ended) return;
        ended = true;
        if (record.child === child) record.child = null;
        if (shuttingDown) return;
        record.status = 'error';
        record.detail = `Server stopped (${reason}); see ${spec.id}.log. Retrying.`;
        record.timer = setTimeout(() => { record.timer = null; void launch(record); }, retryMs);
        record.timer.unref();
      };
      child.once('error', (error) => onExit(error.message));
      child.once('exit', (code, signal) => onExit(signal || `exit ${code}`));
      const deadline = Date.now() + startupTimeoutMs;
      while (!shuttingDown && !ended && Date.now() < deadline) {
        if (await proxyIsReady(record.port, record.internalKey)) {
          if (!ended && !shuttingDown) { record.status = 'ready'; record.detail = ''; }
          return;
        }
        await sleep(350);
      }
      if (!ended && !shuttingDown) {
        record.status = 'error';
        record.detail = `Startup timed out; see ${spec.id}.log. Retrying.`;
        await terminateTree(child);
      }
    } catch (error) {
      record.status = 'error';
      record.detail = `Could not launch server: ${error.message}`;
      if (!shuttingDown) {
        record.timer = setTimeout(() => { record.timer = null; void launch(record); }, retryMs);
        record.timer.unref();
      }
    }
  }

  async function close() {
    if (shutdownPromise) return shutdownPromise;
    shuttingDown = true;
    shutdownPromise = (async () => {
      for (const record of records.values()) if (record.timer) clearTimeout(record.timer);
      await Promise.all([...records.values()].map((record) => terminateTree(record.child)));
      await new Promise((resolve) => {
        server.close(resolve);
        // MCP SSE sessions can otherwise keep server.close() pending forever.
        if (server.closeAllConnections) server.closeAllConnections();
      });
    })();
    return shutdownPromise;
  }

  for (const record of records.values()) void launch(record);
  return { address: server.address(), snapshot, close, server };
}
