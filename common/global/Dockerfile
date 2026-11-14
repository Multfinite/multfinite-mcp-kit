FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/uv \
    && /opt/uv/bin/pip install --no-cache-dir uv==0.9.28 \
    && npm install --global --omit=dev --no-audit --no-fund mcp-proxy@6.10.0 @playwright/mcp@0.0.85 \
    && PLAYWRIGHT_BROWSERS_PATH=/opt/playwright node /usr/local/lib/node_modules/@playwright/mcp/cli.js install-browser --with-deps chromium \
    && chmod -R a+rX /opt/playwright \
    && npm cache clean --force \
    && mkdir -p /data /app \
    && chown node:node /data

COPY gateway.mjs global-kit.mjs /app/
USER node
ENV HOME=/data/home NPM_CONFIG_CACHE=/data/npm UV_CACHE_DIR=/data/uv \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
WORKDIR /data
CMD ["node", "/app/global-kit.mjs"]
