import fs from 'node:fs';
import path from 'node:path';
import { startGateway } from './gateway.mjs';

// All commands and HTTP destinations here are kit configuration, not request
// parameters. The host publishes this container's port on loopback only.
const npx = '/usr/local/bin/npx';
const uvx = '/opt/uv/bin/uvx';
const home = process.env.HOME || '/data/home';
for (const dir of [home, '/data/logs', '/data/work']) fs.mkdirSync(dir, { recursive: true });
const work = '/data/work';
const stdio = (id, command, args, env = {}) => ({ id, command, args, env, cwd: work });
const sidecar = (id, host, waitReason = '') => ({ id, upstream: { host, port: 8000, path: '/mcp' }, waitReason });
const llmWait = process.env.LLM_API_KEY ? '' : 'Set LLM_API_KEY in the private GLOBAL env and apply the new configuration.';
const specs = [
  stdio('sequentialthinking', npx, ['-y', '@modelcontextprotocol/server-sequential-thinking@2025.12.18']),
  sidecar('graphiti', 'graphiti', llmWait),
  sidecar('cognee', 'cognee', llmWait),
  sidecar('memory-bank-mcp', 'memory'),
  stdio('context7', npx, ['-y', '@upstash/context7-mcp@4.7.0'], { CONTEXT7_API_KEY: process.env.CONTEXT7_API_KEY || '' }),
  stdio('duckduckgo', uvx, ['--from', 'duckduckgo-mcp-server[browser]==0.7.0', 'duckduckgo-mcp-server']),
  // This fetch release uses the v1 McpError API and httpx<0.28. MCP 2
  // changes that API; isolate and pin a compatible SDK in its own uvx tool.
  stdio('fetch', uvx, ['--with', 'mcp==1.26.0', '--from', 'mcp-server-fetch==2025.4.7', 'mcp-server-fetch']),
  stdio('io-draw', npx, ['-y', '@drawio/mcp@1.12.0'], { DRAWIO_BROWSER: 'off' }),
  stdio('mcp-compass', npx, ['-y', '@liuyoshio/mcp-compass@1.0.7']),
  sidecar('gdrive', 'gdrive'),
  stdio('neo4j-global', uvx, ['--from', 'mcp-neo4j-cypher==0.6.0', 'mcp-neo4j-cypher'], {
    NEO4J_URI: 'bolt://neo4j:7687', NEO4J_USERNAME: 'neo4j', NEO4J_PASSWORD: process.env.NEO4J_PASSWORD || '',
  }),
  stdio('qdrant-global', uvx, ['--from', 'mcp-server-qdrant==0.8.1', 'mcp-server-qdrant'], { QDRANT_URL: 'http://qdrant:6333' }),
  stdio('playwright', process.execPath, ['/usr/local/lib/node_modules/@playwright/mcp/cli.js', '--headless', '--browser', 'chromium']),
];

const gateway = await startGateway({
  settings: { listenHost: '0.0.0.0', port: 13001, tlsCertFile: '', tlsKeyFile: '', allowInsecureLan: true },
  gatewayKey: process.env.MCPKIT_GATEWAY_KEY,
  controlKey: process.env.MCPKIT_CONTROL_KEY,
  instanceId: process.env.MCPKIT_INSTANCE_ID,
  specs,
  proxyPath: '/usr/local/lib/node_modules/mcp-proxy/dist/bin/mcp-proxy.mjs',
  logDir: '/data/logs',
});
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => { void gateway.close(); });
console.log('GLOBAL gateway started. Readiness depends on the individual servers and their credentials.');
