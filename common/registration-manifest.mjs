// Gateway route IDs are implementation details. These are the public names
// shown in MetaMCP, based on the project names in the README/upstream. Do not
// add host IDs, random prefixes or silently adopt existing records by name.
export const GLOBAL_GROUPS = Object.freeze({
  reasoning: ['sequentialthinking', 'mcp-compass'],
  memory: ['graphiti', 'cognee', 'memory-bank-mcp'],
  web: ['context7', 'duckduckgo', 'fetch'],
  integrations: ['github-mcp-server', 'io-draw', 'gdrive'],
  storage: ['neo4j-global', 'qdrant-global', 'fetch', 'playwright'],
});
export const GLOBAL_SERVER_NAMES = Object.freeze({
  sequentialthinking: 'sequentialthinking',
  graphiti: 'graphiti',
  cognee: 'cognee',
  'memory-bank-mcp': 'memory-bank-mcp',
  context7: 'context7',
  duckduckgo: 'duckduckgo-mcp-server',
  fetch: 'fetch',
  'github-mcp-server': 'github-mcp-server',
  // MetaMCP rejects dots in names. Use the upstream repository's name for io.draw.
  'io-draw': 'drawio-mcp',
  'mcp-compass': 'mcp-compass',
  gdrive: 'gdrive',
  'neo4j-global': 'mcp-neo4j-cypher',
  'qdrant-global': 'mcp-server-qdrant',
  playwright: 'playwright-mcp',
});
export const GLOBAL_GROUP_NAMES = Object.freeze({
  reasoning: 'reasoning', memory: 'memory', web: 'web', integrations: 'integrations', storage: 'storage',
});

export function localGroups(linux) {
  return {
    system: ['desktop-commander', linux ? 'linux-desktop' : 'windows-mcp'],
    files: ['everything-search', 'filesystem', 'markitdown'],
    code: ['git', 'codegraph', 'codebase-memory-mcp', 'serena'],
    web: ['playwright'],
    data: ['dbhub'],
    memory: ['simple-files-vectorstore', 'obsidian'],
  };
}
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
// Browser/notes avoid colliding with GLOBAL's web/memory group names.
export const LOCAL_GROUP_NAMES = Object.freeze({
  system: 'system', files: 'files', code: 'code', web: 'browser', data: 'data', memory: 'notes',
});
