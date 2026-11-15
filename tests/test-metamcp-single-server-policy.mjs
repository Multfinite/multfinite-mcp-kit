// Verify the default MetaMCP source patch against a small pinned-source fixture.
// No MetaMCP checkout, Docker daemon, or network access is required.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ensurePatchedSource } from '../common/metamcp-lan-source.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const composeFile = path.join(root, 'common/metamcp-compose.yml');

const fixtureFiles = {
  'apps/backend/src/lib/metamcp/utils.ts': `import { oauthSessionsRepository } from "../../db/repositories/oauth-sessions.repo";\n\nexport function sanitizeName(name: string): string {\n  return name;\n}\n`,
  'apps/backend/src/lib/metamcp/metamcp-proxy.ts': `import { sanitizeName } from "./utils";\n\nexport const createServer = async (namespaceUuid: string) => {\n  const namespace = await namespacesRepository.findByUuid(namespaceUuid);\n  server.setRequestHandler(ListToolsRequestSchema, async (request) => {\n    const result = await listToolsWithMiddleware(request, handlerContext);\n    const adminContext = getAdminToolsContext(handlerContext.sessionId);\n\n    if (adminContext?.enabled && adminContext.userId) {\n      result.tools.push(...getAdminToolsForMcp());\n    }\n\n    return result;\n  });\n\n  server.setRequestHandler(CallToolRequestSchema, async (request) => {\n    if (isExposedAdminToolName(request.params.name)) {\n      return executeAdminTool(request.params.name);\n    }\n    return await callToolWithMiddleware(request, handlerContext);\n  });\n\n  server.setRequestHandler(GetPromptRequestSchema, async (request) => {\n    const { name } = request.params;\n    const clientForPrompt = promptToClient[name];\n  });\n\n  server.setRequestHandler(ListPromptsRequestSchema, async (request) => {\n    const serverParams = await getMcpServers(\n      namespaceUuid,\n      includeInactiveServers,\n    );\n    const allPrompts = [];\n    return {\n      prompts: allPrompts,\n      nextCursor: request.params?.cursor,\n    };\n  });\n\n  server.setRequestHandler(ListResourcesRequestSchema, async (request) => {\n    const serverParams = await getMcpServers(\n      namespaceUuid,\n      includeInactiveServers,\n    );\n  });\n\n  server.setRequestHandler(ReadResourceRequestSchema, async (request) => {\n    const { uri } = request.params;\n  });\n\n  server.setRequestHandler(\n    ListResourceTemplatesRequestSchema,\n    async (request) => {\n      const serverParams = await getMcpServers(\n        namespaceUuid,\n        includeInactiveServers,\n      );\n    },\n  );\n};\n`,
  'apps/backend/src/routers/public-metamcp/openapi/handlers.ts': `import { sanitizeName } from "../../../lib/metamcp/utils";\n\nexport const createMiddlewareEnabledHandlers = () => {\n  return {\n    handlerContext,\n    listToolsWithMiddleware,\n    callToolWithMiddleware,\n  };\n};\n`,
};

function makeSource() {
  const source = fs.mkdtempSync(path.join(os.tmpdir(), 'mcpkit-policy-source-'));
  for (const [relative, text] of Object.entries(fixtureFiles)) {
    const file = path.join(source, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
  }
  execFileSync('git', ['-C', source, 'init', '-q']);
  execFileSync('git', ['-C', source, 'config', 'user.name', 'MCP Kit test']);
  execFileSync('git', ['-C', source, 'config', 'user.email', 'mcpkit-test@example.invalid']);
  execFileSync('git', ['-C', source, 'add', '.']);
  execFileSync('git', ['-C', source, 'commit', '-qm', 'fixture']);
  return source;
}

test('default MetaMCP source patch enforces one server without the clean-tools overlay', (t) => {
  const source = makeSource();
  t.after(() => fs.rmSync(source, { recursive: true, force: true }));

  ensurePatchedSource(source);
  const utils = fs.readFileSync(path.join(source, 'apps/backend/src/lib/metamcp/utils.ts'), 'utf8');
  const proxy = fs.readFileSync(path.join(source, 'apps/backend/src/lib/metamcp/metamcp-proxy.ts'), 'utf8');
  const openApi = fs.readFileSync(path.join(source, 'apps/backend/src/routers/public-metamcp/openapi/handlers.ts'), 'utf8');
  const compose = fs.readFileSync(composeFile, 'utf8');
  const stack = fs.readFileSync(path.join(root, 'common/stack.mjs'), 'utf8');

  assert.match(utils, /MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT === "false"/);
  assert.match(utils, /count !== 1/);
  assert.equal((proxy.match(/await mcpkitAssertSingleServerPerEndpoint\(namespaceUuid\)/g) || []).length, 8);
  assert.match(openApi, /listToolsWithMiddleware: enforceSingleServerList/);
  assert.match(openApi, /callToolWithMiddleware: enforceSingleServerCall/);
  assert.match(compose, /MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT: "\$\{MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT:-true\}"/);
  assert.match(compose, /single-server-per-endpoint-patch: "1"/);
  assert.doesNotMatch(compose, /metamcp-clean-tools\.yml/);
  assert.match(stack, /MCPKIT_ENFORCE_SINGLE_SERVER_PER_ENDPOINT=true/);
  assert.match(stack, /ensurePatchedSource\(source, \{ lan: Boolean\(state\.lanIp\), cleanTools: Boolean\(state\.cleanTools\) \}\);/);

  const patched = fs.readFileSync(path.join(source, 'apps/backend/src/lib/metamcp/utils.ts'));
  ensurePatchedSource(source);
  assert.deepEqual(fs.readFileSync(path.join(source, 'apps/backend/src/lib/metamcp/utils.ts')), patched);

  // The independent clean-name option can be layered onto the same patch.
  ensurePatchedSource(source, { cleanTools: true });
  const cleanProxy = fs.readFileSync(path.join(source, 'apps/backend/src/lib/metamcp/metamcp-proxy.ts'), 'utf8');
  const cleanOpenApi = fs.readFileSync(path.join(source, 'apps/backend/src/routers/public-metamcp/openapi/handlers.ts'), 'utf8');
  assert.match(cleanProxy, /MCPKIT_CLEAN_TOOL_NAMES === "true"/);
  assert.match(cleanOpenApi, /listToolsWithMiddleware: cleanList/);
  assert.match(cleanOpenApi, /await mcpkitAssertSingleServerPerEndpoint\(context\.namespaceUuid\)/);
  ensurePatchedSource(source, { cleanTools: true });

  const changed = path.join(source, 'apps/backend/src/lib/metamcp/utils.ts');
  fs.appendFileSync(changed, '\n// user edit\n');
  const before = fs.readFileSync(changed);
  assert.throws(() => ensurePatchedSource(source, { cleanTools: true }), /Local edits/);
  assert.deepEqual(fs.readFileSync(changed), before);
});
