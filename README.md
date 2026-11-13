
## The idea

### Structure

├── 🌐 Global \
│ ├── [sequentialthinking](https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking)  
│ ├── [graphiti](https://github.com/getzep/graphiti)  
│ ├── [cognee](https://github.com/topoteretes/cognee)  
│ ├── [memory-bank-mcp](https://github.com/alioshr/memory-bank-mcp)  
│ ├── [context7](https://github.com/upstash/context7)  
│ ├── [duckduckgo](https://github.com/nickclyde/duckduckgo-mcp-server)  
│ ├── [fetch](https://github.com/modelcontextprotocol/servers/blob/main/src/fetch/README.md)  
│ ├── [github-mcp-server](https://github.com/mcp/github/github-mcp-server)  
│ ├── [io.draw](https://github.com/mcp/io.draw/mcp)  
│ ├── [mcp-compass](https://github.com/liuyoshio/mcp-compass)  
│ └── [gdrive](https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive)  
│  
├── 💻 LOCAL \
│ ├── [DesktopCommanderMCP](https://github.com/wonderwhy-er/DesktopCommanderMCP)  
│ ├── [mcp-everything-search](https://github.com/mamertofabian/mcp-everything-search)  
│ ├── [filesystem-mcp](https://github.com/j0hanz/filesystem-mcp)  
│ ├── [Windows-MCP](https://github.com/CursorTouch/Windows-MCP)  
│ ├── [git](https://github.com/modelcontextprotocol/servers/tree/main/src/git)  
│ ├── [codegraph](https://github.com/colbymchenry/codegraph)  
│ ├── [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)  
│ ├── [serena](https://github.com/oraios/serena)  
│ ├── [playwright-mcp](https://github.com/mcp/microsoft/playwright-mcp)  
│ ├── [dbhub](https://github.com/mcp/bytebase/dbhub)  
│ ├── [simple-files-vectorstore](https://github.com/lishenxydlgzs/simple-files-vectorstore)  
│ ├── [markitdown](https://github.com/mcp/microsoft/markitdown)  
│ └── [mcp-obsidian](https://github.com/MarkusPfundstein/mcp-obsidian)  
│  
└── 💻 LOCAL (the same as above)\
&nbsp;&nbsp;&nbsp;&nbsp;├── ...\
&nbsp;&nbsp;&nbsp;&nbsp;└── ...

### MetaMCP

**MetaMCP** *.env*  
```
APP_URL=${YOUR_PUBLIC_DOMAIN}
NEXT_PUBLIC_APP_URL=http://localhost:12008
```

## Installation and run

### Global on Linux

1. Run `/linux/install-global.sh` to install.
2. Run `npx -y @metamcp/mcp-server-metamcp --config ~/mcp-global/config/metamcp.json` to startup MetaMCP.