// Runs common/register.mjs (LOCAL profile) against an in-memory MetaMCP stand-in.
// Covers: first registration, stale-address/membership repair, no-op re-run,
// and refusal to adopt a same-named record owned by another user.
import assert from 'node:assert/strict';
import childProcess from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const register = path.join(here, '..', 'common', 'register.mjs');
const KEY = 'a'.repeat(64);
const tempDirs = [];
const GATEWAY = 'http://127.0.0.1:13001';

// Makes process.stdin/stdout look like a terminal so the interactive prompts run.
const preload = path.join(os.tmpdir(), `mcpkit-tty-preload-${process.pid}.cjs`);
fs.writeFileSync(preload, 'process.stdin.isTTY = true; process.stdout.isTTY = true; process.stdin.setRawMode = () => {};\n');

function fakeMetaMcp() {
  const db = { servers: [], namespaces: [], endpoints: [] };
  const uuid = () => crypto.randomUUID();
  const trpcOk = (res, data) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ result: { data: { success: true, data } } })); };
  const bad = (res, message) => { res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message } })); };
  const serverView = (s) => ({ ...s, servers: undefined });
  const nsGet = (ns) => ({ ...ns, servers: ns.serverUuids.map((id) => db.servers.find((s) => s.uuid === id)).filter(Boolean) });
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      if (req.method === 'POST' && url.pathname === '/api/auth/sign-in/email') {
        res.writeHead(200, { 'content-type': 'application/json', 'set-cookie': 'better-auth.session=s1; Path=/; HttpOnly' });
        return res.end('{}');
      }
      if (url.pathname === '/api/auth/get-session') {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ user: { id: 'admin-1' } }));
      }
      if (url.pathname === '/trpc/frontend.config.getAllConfigs') {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ result: { data: { json: [] } } }));
      }
      const procedure = url.pathname.replace('/trpc/frontend.', '');
      const input = req.method === 'POST' ? JSON.parse(raw || '{}') : (url.searchParams.get('input') ? JSON.parse(url.searchParams.get('input')) : undefined);
      switch (procedure) {
        case 'mcpServers.list': return trpcOk(res, db.servers.map(serverView));
        case 'namespaces.list': return trpcOk(res, db.namespaces.map((ns) => ({ ...ns, serverUuids: undefined })));
        case 'endpoints.list': return trpcOk(res, db.endpoints);
        case 'namespaces.get': {
          const ns = db.namespaces.find((item) => item.uuid === input.uuid);
          return ns ? trpcOk(res, nsGet(ns)) : bad(res, 'not found');
        }
        case 'mcpServers.create': {
          if (db.servers.some((s) => s.name === input.name)) return bad(res, 'duplicate');
          const record = { uuid: uuid(), name: input.name, description: input.description ?? null, type: input.type, command: null, args: [],
            env: {}, url: input.url ?? null, created_at: new Date().toISOString(), bearerToken: null, headers: input.headers || {},
            forward_headers: {}, user_id: input.user_id ?? null };
          db.servers.push(record);
          return trpcOk(res, record);
        }
        case 'mcpServers.update': {
          const record = db.servers.find((s) => s.uuid === input.uuid);
          if (!record) return bad(res, 'not found');
          for (const key of ['name', 'description', 'type', 'command', 'args', 'env', 'url', 'bearerToken', 'headers', 'forward_headers']) {
            if (Object.hasOwn(input, key)) record[key] = input[key] ?? null;
          }
          record.user_id = input.user_id ?? null;
          return trpcOk(res, { ...record });
        }
        case 'namespaces.create': {
          if (db.namespaces.some((n) => n.name === input.name)) return bad(res, 'duplicate');
          const ns = { uuid: uuid(), name: input.name, description: input.description, user_id: null, serverUuids: [...input.mcpServerUuids] };
          db.namespaces.push(ns);
          return trpcOk(res, { ...ns, serverUuids: undefined });
        }
        case 'namespaces.update': {
          const ns = db.namespaces.find((n) => n.uuid === input.uuid);
          if (!ns) return bad(res, 'not found');
          ns.name = input.name; ns.description = input.description ?? null; ns.serverUuids = [...(input.mcpServerUuids || [])];
          return trpcOk(res, { ...ns, serverUuids: undefined });
        }
        case 'endpoints.create': {
          if (db.endpoints.some((e) => e.name === input.name)) return bad(res, 'duplicate');
          const record = { uuid: uuid(), name: input.name, description: input.description, namespace_uuid: input.namespaceUuid,
            enable_api_key_auth: true, enable_oauth: false, enable_metamcp_admin_tools: false, user_id: null };
          db.endpoints.push(record);
          return trpcOk(res, record);
        }
        default: return bad(res, `unsupported ${procedure}`);
      }
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ db, origin: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })));
}

function makeLocalKit() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit register sim '));
  tempDirs.push(base);
  const config = path.join(base, 'config');
  const privateDir = path.join(config, 'private');
  fs.mkdirSync(privateDir, { recursive: true });
  fs.writeFileSync(path.join(config, 'local-settings.json'), `${JSON.stringify({ version: 1, hostId: 'workstation-abc123', listenHost: '127.0.0.1', port: 13001 })}\n`);
  fs.writeFileSync(path.join(privateDir, 'secrets.json'), `${JSON.stringify({ gatewayApiKey: KEY })}\n`);
  fs.writeFileSync(path.join(privateDir, 'linux-kit.json'), `${JSON.stringify({ version: 1, base, hostId: 'workstation-abc123' })}\n`);
  return base;
}

function runRegister(base, origin) {
  const answers = [[`MetaMCP origin`, origin], ['Gateway base URL', GATEWAY], ['Authentication:', '1'], ['MetaMCP account email:', 'admin@example.test'], ['Password (not echoed):', 'pw']];
  return new Promise((resolve) => {
    const child = childProcess.spawn(process.execPath, ['--require', preload, register, 'local', '--dir', base], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    let next = 0;
    const onData = (chunk) => {
      out += chunk;
      while (next < answers.length && out.includes(answers[next][0])) {
        child.stdin.write(`${answers[next][1]}\n`);
        out = out.slice(out.lastIndexOf(answers[next][0]) + answers[next][0].length);
        next += 1;
        // Close stdin after the last answer so the process can exit on its own.
        if (next === answers.length) child.stdin.end();
      }
    };
    const guard = setTimeout(() => child.kill(), 120000);
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code) => { clearTimeout(guard); resolve({ code, out: out + '' }); });
    child.stdin.on('error', () => {});
  });
}

async function runFull(base, origin) {
  const result = await runRegister(base, origin);
  return result;
}

test.after(() => {
  fs.rmSync(preload, { force: true });
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

test('first run creates kit records; repeat run makes no changes', async () => {
  const mm = await fakeMetaMcp();
  try {
    const base = makeLocalKit();
    const first = await runFull(base, mm.origin);
    assert.equal(first.code, 0, first.out);
    assert.ok(mm.db.servers.length >= 1);
    assert.ok(mm.db.namespaces.length === mm.db.servers.length);
    assert.ok(mm.db.servers.every((s) => s.user_id === null));
    const second = await runFull(base, mm.origin);
    assert.equal(second.code, 0, second.out);
  } finally { mm.close(); }
});

test('stale gateway address and changed membership are repaired in place', async () => {
  const mm = await fakeMetaMcp();
  try {
    const base = makeLocalKit();
    assert.equal((await runFull(base, mm.origin)).code, 0);
    const desktop = mm.db.servers.find((s) => s.name === 'DesktopCommanderMCP');
    const staleUrl = 'http://192.168.100.1:13001/servers/desktop-commander/mcp';
    desktop.url = staleUrl;
    const ns = mm.db.namespaces.find((n) => n.name === 'DesktopCommanderMCP');
    ns.serverUuids = [];
    const count = mm.db.servers.length;

    const repair = await runFull(base, mm.origin);
    assert.equal(repair.code, 0, repair.out);
    assert.match(repair.out, /Updated server DesktopCommanderMCP/);
    assert.match(repair.out, /Updated namespace DesktopCommanderMCP/);
    assert.equal(desktop.url, `${GATEWAY}/servers/desktop-commander/mcp`);
    assert.deepEqual(ns.serverUuids, [desktop.uuid]);
    assert.equal(mm.db.servers.length, count, 'no duplicate records');

    const again = await runFull(base, mm.origin);
    assert.equal(again.code, 0, again.out);
    assert.doesNotMatch(again.out, /Updated (server|namespace)/);
  } finally { mm.close(); }
});

test('a same-named record owned by another user is never adopted or changed', async () => {
  const mm = await fakeMetaMcp();
  try {
    mm.db.servers.push({ uuid: crypto.randomUUID(), name: 'DesktopCommanderMCP', description: 'MCP Kit local: desktop-commander',
      type: 'STREAMABLE_HTTP', command: null, args: [], env: {}, url: 'https://private.example/mcp', created_at: '', bearerToken: null,
      headers: {}, forward_headers: {}, user_id: 'someone-else' });
    const before = JSON.stringify(mm.db.servers);
    const base = makeLocalKit();
    const result = await runFull(base, mm.origin);
    assert.notEqual(result.code, 0);
    assert.match(result.out, /not adopted/);
    assert.equal(JSON.stringify(mm.db.servers), before);
  } finally { mm.close(); }
});
