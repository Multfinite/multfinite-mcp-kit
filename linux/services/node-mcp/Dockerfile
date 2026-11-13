FROM node:20-bookworm-slim

# These two upstream MCP servers only support stdio. Run them through the
# Streamable HTTP proxy so MetaMCP can use separate persistent containers.
RUN npm install --global --omit=dev --no-audit --no-fund \
      mcp-proxy@6.10.0 \
      @allpepper/memory-bank-mcp@0.2.2 \
      @modelcontextprotocol/server-gdrive@2025.1.14 \
    && npm cache clean --force \
    && mkdir -p /mcpkit/memory /mcpkit/gdrive \
    && chown -R node:node /mcpkit

USER node
