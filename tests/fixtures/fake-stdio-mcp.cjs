'use strict';
// A tiny legacy MCP server used only by gateway regression tests.
const readline = require('node:readline');
if (process.env.MCPKIT_TEST_PID_FILES === '1') {
  require('node:fs').writeFileSync(require('node:path').join(process.cwd(), 'fixture.pid'), String(process.pid));
}
const input = readline.createInterface({ input: process.stdin });
input.on('line', (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (!Object.prototype.hasOwnProperty.call(message, 'id')) return;
  let result;
  if (message.method === 'initialize') {
    result = { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'test-server', version: '1.0.0' } };
  } else if (message.method === 'tools/list') {
    result = { tools: [{ name: 'echo', description: 'Test tool', inputSchema: { type: 'object', properties: {} } }] };
  } else if (message.method === 'tools/call') {
    const names = ['OBSIDIAN_API_KEY', 'DSN', 'DBHUB_DSN', 'MCPKIT_GATEWAY_KEY', 'MCPKIT_CONTROL_KEY', 'MCP_PROXY_STREAM_ENDPOINT', 'MCP_PROXY_SSL_CERT', 'PYTHONIOENCODING', 'PYTHONUTF8', 'PYTHONUNBUFFERED'];
    const value = message.params?.arguments?.showEnvironment
      ? JSON.stringify(Object.fromEntries(names.map((name) => [name, Object.entries(process.env).find(([key]) => key.toUpperCase() === name)?.[1] ?? null])))
      : process.env.MCP_PROXY_API_KEY || '';
    result = { content: [{ type: 'text', text: value }] };
  } else if (message.method === 'ping') {
    result = {};
  } else {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } })}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, result })}\n`);
});
