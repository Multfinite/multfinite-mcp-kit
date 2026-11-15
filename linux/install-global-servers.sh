#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
dir="${1:-$HOME/mcp-kit/global}"
port="${2:-}"
[ "$#" -le 2 ] || { echo "Usage: $0 [DIRECTORY] [GATEWAY_PORT]" >&2; exit 2; }
command -v node >/dev/null || { echo 'Install Node.js 20+ first.' >&2; exit 1; }
if [ ! -f "$dir/.mcpkit/state.json" ] && [ -z "$port" ]; then
    [ -t 0 ] || { echo 'Choose the GLOBAL gateway port as the second argument.' >&2; exit 2; }
    read -r -p 'Loopback port for the new GLOBAL gateway (1-65535): ' port
    [ -n "$port" ] || { echo 'A port is required.' >&2; exit 2; }
fi
mcpkit_require_docker
args=(init-global --dir "$dir")
[ -z "$port" ] || args+=(--port "$port")
exec node "$HERE/../common/stack.mjs" "${args[@]}"
