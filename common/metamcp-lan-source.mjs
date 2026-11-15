// Exact, opt-in changes to the pinned upstream MetaMCP source. LAN support
// and clean client-visible tool names can be enabled independently; ordinary
// existing installations keep upstream behavior. The revision is pinned.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const LAN_PATCH_VERSION = '1';
export const CLEAN_TOOLS_PATCH_VERSION = '1';

const lanReplacements = {
  'apps/backend/src/auth.ts': [
    [
      'const BETTER_AUTH_URL = process.env.APP_URL;',
      `const mcpkitOrigins = (process.env.MCPKIT_MULTI_AUTH_ORIGINS || "")
  .split(",").filter(Boolean);
for (const origin of mcpkitOrigins) {
  const url = new URL(origin);
  if (url.protocol !== "http:" || url.origin !== origin || url.username || url.password) {
    throw new Error("Invalid MCP Kit local origin");
  }
}
if (mcpkitOrigins.length && !/^mcpkit-[a-f0-9]{16}$/.test(process.env.MCPKIT_COOKIE_PREFIX || "")) {
  throw new Error("A unique MCP Kit cookie prefix is required");
}
const BETTER_AUTH_URL = mcpkitOrigins.length
  ? { allowedHosts: mcpkitOrigins.map((origin) => new URL(origin).host), protocol: "http" as const }
  : process.env.APP_URL;`,
    ],
    [
      `    crossSubDomainCookies: {
      enabled: true,
    },`,
      `    ...(mcpkitOrigins.length
      ? {
          // Next's internal rewrite sets x-forwarded-host from the original
          // Host. Better Auth still limits it to the exact configured hosts.
          trustedProxyHeaders: true,
          cookiePrefix: process.env.MCPKIT_COOKIE_PREFIX,
          crossSubDomainCookies: { enabled: false },
        }
      : { crossSubDomainCookies: { enabled: true } }),`,
    ],
  ],
  'apps/frontend/lib/env.ts': [
    [
      '  // Client-side: use next-runtime-env\n  const NEXT_PUBLIC_APP_URL = env("NEXT_PUBLIC_APP_URL");',
      '  // Client-side: the LAN install explicitly permits both configured hosts.\n  if (env("NEXT_PUBLIC_MCPKIT_MULTI_ORIGIN") === "true") return window.location.origin;\n  const NEXT_PUBLIC_APP_URL = env("NEXT_PUBLIC_APP_URL");',
    ],
  ],
  'apps/backend/src/trpc.ts': [
    [
      '      headers.set("cookie", req.headers.cookie);',
      `      headers.set("cookie", req.headers.cookie);
      if (process.env.MCPKIT_MULTI_AUTH_ORIGINS && typeof req.headers["x-forwarded-host"] === "string") {
        headers.set("x-forwarded-host", req.headers["x-forwarded-host"]);
      }`,
    ],
  ],
  'apps/backend/src/middleware/better-auth-mcp.middleware.ts': [
    [
      '    headers.set("cookie", req.headers.cookie);',
      `    headers.set("cookie", req.headers.cookie);
    if (process.env.MCPKIT_MULTI_AUTH_ORIGINS && typeof req.headers["x-forwarded-host"] === "string") {
      headers.set("x-forwarded-host", req.headers["x-forwarded-host"]);
    }`,
    ],
  ],
  'apps/backend/src/routers/oauth/utils.ts': [
    [
      'export function getBaseUrl(req: express.Request): string {\n  // Prioritize APP_URL environment variable',
      `export function getBaseUrl(req: express.Request): string {
  if (process.env.MCPKIT_MULTI_AUTH_ORIGINS) {
    const host = req.headers["x-forwarded-host"];
    const origin = typeof host === "string" ? \`http://\${host}\` : "";
    if (!process.env.MCPKIT_MULTI_AUTH_ORIGINS.split(",").includes(origin)) {
      throw new Error("Unrecognized MCP Kit local origin");
    }
    return origin;
  }
  // Prioritize APP_URL environment variable`,
    ],
  ],
  'apps/backend/src/middleware/api-key-oauth.middleware.ts': [
    [
      'function getBaseUrl(req: express.Request): string {\n  // Prioritize APP_URL environment variable',
      `function getBaseUrl(req: express.Request): string {
  if (process.env.MCPKIT_MULTI_AUTH_ORIGINS) {
    const host = req.headers["x-forwarded-host"];
    const origin = typeof host === "string" ? \`http://\${host}\` : "";
    if (!process.env.MCPKIT_MULTI_AUTH_ORIGINS.split(",").includes(origin)) {
      throw new Error("Unrecognized MCP Kit local origin");
    }
    return origin;
  }
  // Prioritize APP_URL environment variable`,
    ],
    [
      '        const introspectUrl = new URL("/oauth/introspect", baseUrl);',
      `        // The external host port is published by Docker and does not
        // exist inside this container. Keep self-introspection on the backend.
        const introspectUrl = new URL("/oauth/introspect",
          process.env.MCPKIT_MULTI_AUTH_ORIGINS ? "http://127.0.0.1:12009" : baseUrl);`,
    ],
  ],
};

const cleanToolReplacements = {
  'apps/backend/src/lib/metamcp/utils.ts': [
    [
      'import { oauthSessionsRepository } from "../../db/repositories/oauth-sessions.repo";',
      'import { oauthSessionsRepository } from "../../db/repositories/oauth-sessions.repo";\nimport { namespacesRepository } from "../../db/repositories/namespaces.repo";',
    ],
    [
      'export function sanitizeName(name: string): string {',
      `// Keep MetaMCP's internal routing, filters, overrides and audit identity
// unchanged. Only the external representation drops the single-server prefix.
// Refuse multiple servers rather than silently route a duplicate tool name.
export async function mcpkitSingleServerPrefix(namespaceUuid: string): Promise<string> {
  const namespace = await namespacesRepository.findByUuidWithServers(namespaceUuid);
  if (!namespace || namespace.servers.length !== 1) {
    throw new Error("Clean tool names require exactly one server in the namespace");
  }
  const name = sanitizeName(namespace.servers[0].name);
  if (!name || name.includes("__")) {
    throw new Error("The single server name cannot be used for clean tool routing");
  }
  return \`\${name}__\`;
}

export function mcpkitCleanItems<T extends { name: string }>(items: T[], prefix: string): T[] {
  const seen = new Set<string>();
  return items.map((item) => {
    if (!item.name.startsWith(prefix) || item.name.length === prefix.length) {
      throw new Error("Unexpected item identity; refusing ambiguous clean names");
    }
    const name = item.name.slice(prefix.length);
    if (seen.has(name)) throw new Error(\`Duplicate clean name: \${name}\`);
    seen.add(name);
    return { ...item, name };
  });
}

export function sanitizeName(name: string): string {`,
    ],
  ],
  'apps/backend/src/lib/metamcp/metamcp-proxy.ts': [
    [
      'import { sanitizeName } from "./utils";',
      'import { mcpkitCleanItems, mcpkitSingleServerPrefix, sanitizeName } from "./utils";',
    ],
    [
      `    if (adminContext?.enabled && adminContext.userId) {
      result.tools.push(...getAdminToolsForMcp());
    }

    return result;
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    if (isExposedAdminToolName(request.params.name)) {`,
      `    if (process.env.MCPKIT_CLEAN_TOOL_NAMES === "true") {
      if (adminContext?.enabled && adminContext.userId) {
        throw new Error("MetaMCP admin tools cannot be combined with clean tool names");
      }
      const prefix = await mcpkitSingleServerPrefix(namespaceUuid);
      return { ...result, tools: mcpkitCleanItems(result.tools, prefix) };
    }
    if (adminContext?.enabled && adminContext.userId) {
      result.tools.push(...getAdminToolsForMcp());
    }

    return result;
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    if (process.env.MCPKIT_CLEAN_TOOL_NAMES === "true") {
      const adminContext = getAdminToolsContext(handlerContext.sessionId);
      if (adminContext?.enabled && adminContext.userId) {
        throw new Error("MetaMCP admin tools cannot be combined with clean tool names");
      }
      const prefix = await mcpkitSingleServerPrefix(namespaceUuid);
      return callToolWithMiddleware({
        ...request,
        params: { ...request.params, name: prefix + request.params.name },
      }, handlerContext);
    }
    if (isExposedAdminToolName(request.params.name)) {`,
    ],
    [
      `  server.setRequestHandler(GetPromptRequestSchema, async (request) => {
    const { name } = request.params;
    const clientForPrompt = promptToClient[name];`,
      `  server.setRequestHandler(GetPromptRequestSchema, async (request) => {
    const name = process.env.MCPKIT_CLEAN_TOOL_NAMES === "true"
      ? (await mcpkitSingleServerPrefix(namespaceUuid)) + request.params.name
      : request.params.name;
    const clientForPrompt = promptToClient[name];`,
    ],
    [
      `    return {
      prompts: allPrompts,
      nextCursor: request.params?.cursor,
    };`,
      `    const prompts = process.env.MCPKIT_CLEAN_TOOL_NAMES === "true"
      ? mcpkitCleanItems(allPrompts, await mcpkitSingleServerPrefix(namespaceUuid))
      : allPrompts;
    return {
      prompts,
      nextCursor: request.params?.cursor,
    };`,
    ],
  ],
  'apps/backend/src/routers/public-metamcp/openapi/handlers.ts': [
    [
      'import { sanitizeName } from "../../../lib/metamcp/utils";',
      'import { mcpkitCleanItems, mcpkitSingleServerPrefix, sanitizeName } from "../../../lib/metamcp/utils";',
    ],
    [
      `  return {
    handlerContext,
    listToolsWithMiddleware,
    callToolWithMiddleware,
  };
};`,
      `  const cleanList: ListToolsHandler = async (request, context) => {
    const result = await listToolsWithMiddleware(request, context);
    if (process.env.MCPKIT_CLEAN_TOOL_NAMES !== "true") return result;
    const prefix = await mcpkitSingleServerPrefix(context.namespaceUuid);
    return { ...result, tools: mcpkitCleanItems(result.tools, prefix) };
  };
  const cleanCall: CallToolHandler = async (request, context) => {
    if (process.env.MCPKIT_CLEAN_TOOL_NAMES !== "true") {
      return callToolWithMiddleware(request, context);
    }
    const prefix = await mcpkitSingleServerPrefix(context.namespaceUuid);
    return callToolWithMiddleware({
      ...request,
      params: { ...request.params, name: prefix + request.params.name },
    }, context);
  };

  return {
    handlerContext,
    listToolsWithMiddleware: cleanList,
    callToolWithMiddleware: cleanCall,
  };
};`,
    ],
  ],
};

function git(source, args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^GIT_/i.test(key)));
  const result = spawnSync('git', ['-C', source, ...args], { encoding: 'utf8', env: { ...env, GIT_TERMINAL_PROMPT: '0' }, maxBuffer: 16 * 1024 * 1024, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('Cannot inspect the owned MetaMCP source.');
  return result.stdout;
}
function patched(original, changes) {
  let value = original;
  for (const [before, after] of changes) {
    if (value.split(before).length !== 2) throw new Error('Pinned upstream source differs from the expected MCP Kit patch; no files changed.');
    value = value.replace(before, after);
  }
  return value;
}

// Require a clean clone or precisely our previously applied patch. Do not
// overwrite local edits, staged changes, untracked files, or symlinks. The
// complete preflight happens before any of the owned clone's files are changed.
export function ensurePatchedSource(source, { lan = false, cleanTools = false } = {}) {
  const replacements = {
    ...(lan ? lanReplacements : {}),
    ...(cleanTools ? cleanToolReplacements : {}),
  };
  const files = Object.keys(replacements);
  const status = git(source, ['status', '--porcelain', '--untracked-files=all']).trimEnd().split('\n').filter(Boolean);
  const allowed = new Set(files.map((file) => ` M ${file}`));
  if (status.some((line) => !allowed.has(line))) throw new Error('MetaMCP clone has unexpected changes; no build was attempted.');
  const plans = files.map((file) => {
    const filePath = path.join(source, file);
    if (!fs.lstatSync(filePath).isFile() || fs.lstatSync(filePath).isSymbolicLink()) throw new Error('Unexpected source file; no build was attempted.');
    const baseline = git(source, ['show', `HEAD:${file}`]);
    const expected = patched(baseline, replacements[file]);
    const current = fs.readFileSync(filePath, 'utf8');
    if (current !== baseline && current !== expected) throw new Error(`Local edits in ${file} were preserved; no build was attempted.`);
    return { filePath, current, expected };
  });
  for (const item of plans) if (item.current !== item.expected) fs.writeFileSync(item.filePath, item.expected);
}
