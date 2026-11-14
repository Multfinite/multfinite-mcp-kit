// Gateway route IDs are implementation details. Public MetaMCP names follow
// the corresponding project names in the README/upstream, without kit IDs.
export const GLOBAL_SERVER_NAMES = Object.freeze({
  sequentialthinking: 'sequentialthinking',
  graphiti: 'graphiti',
  cognee: 'cognee',
  'memory-bank-mcp': 'memory-bank-mcp',
  context7: 'context7',
  duckduckgo: 'duckduckgo-mcp-server',
  fetch: 'fetch',
  'github-mcp-server': 'github-mcp-server',
  // MetaMCP's server, namespace and endpoint constraints disallow dots.
  // drawio-mcp is the official upstream repository name for io.draw.
  'io-draw': 'drawio-mcp',
  'mcp-compass': 'mcp-compass',
  gdrive: 'gdrive',
  'neo4j-global': 'mcp-neo4j-cypher',
  'qdrant-global': 'mcp-server-qdrant',
  playwright: 'playwright-mcp',
});
export const LOCAL_SERVER_NAMES = Object.freeze({
  'desktop-commander': 'DesktopCommanderMCP',
  'windows-mcp': 'Windows-MCP',
  'linux-desktop': 'universal-computer-control',
  'everything-search': 'mcp-everything-search',
  filesystem: 'filesystem-mcp',
  git: 'git',
  codegraph: 'codegraph',
  'codebase-memory-mcp': 'codebase-memory-mcp',
  serena: 'serena',
  playwright: 'playwright-mcp',
  dbhub: 'dbhub',
  'simple-files-vectorstore': 'simple-files-vectorstore',
  markitdown: 'markitdown-mcp',
  obsidian: 'mcp-obsidian',
});

// New registrations contain one namespace and endpoint per server, with the
// same public name as that server. IDs remain the gateway route IDs internally.
const onePerServer = (ids) => Object.freeze(Object.fromEntries(ids.map((id) => [id, [id]])));
export const GLOBAL_GROUPS = onePerServer(Object.keys(GLOBAL_SERVER_NAMES));
export const GLOBAL_GROUP_NAMES = GLOBAL_SERVER_NAMES;
export function localGroups(linux) {
  return onePerServer(Object.keys(LOCAL_SERVER_NAMES).filter((id) => id !== (linux ? 'windows-mcp' : 'linux-desktop')));
}
export const LOCAL_GROUP_NAMES = LOCAL_SERVER_NAMES;

// V1 journals used grouped namespaces/endpoints. Keep their exact memberships
// solely to identify and migrate those records without deleting any links.
export const LEGACY_GLOBAL_GROUPS = Object.freeze({
  reasoning: ['sequentialthinking', 'mcp-compass'],
  memory: ['graphiti', 'cognee', 'memory-bank-mcp'],
  web: ['context7', 'duckduckgo', 'fetch'],
  integrations: ['github-mcp-server', 'io-draw', 'gdrive'],
  storage: ['neo4j-global', 'qdrant-global', 'fetch', 'playwright'],
});
export function legacyLocalGroups(linux) {
  return {
    system: ['desktop-commander', linux ? 'linux-desktop' : 'windows-mcp'],
    files: ['everything-search', 'filesystem', 'markitdown'],
    code: ['git', 'codegraph', 'codebase-memory-mcp', 'serena'],
    web: ['playwright'],
    data: ['dbhub'],
    memory: ['simple-files-vectorstore', 'obsidian'],
  };
}
// Names used by the short-lived V2 grouped layout (also targets of the
// previous V1 sharing migration). They are accepted only for migration.
export const LEGACY_GLOBAL_GROUP_NAMES = Object.freeze({
  reasoning: 'reasoning', memory: 'memory', web: 'web', integrations: 'integrations', storage: 'storage',
});
export const LEGACY_LOCAL_GROUP_NAMES = Object.freeze({
  system: 'system', files: 'files', code: 'code', web: 'browser', data: 'data', memory: 'notes',
});
