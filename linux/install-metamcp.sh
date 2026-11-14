#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
dir=''; port=''; app_url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir|--port|--app-url)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in --dir) dir="$2";; --port) port="$2";; --app-url) app_url="$2";; esac
            shift 2 ;;
        *) echo "Usage: $0 [--dir DIR] [--port PORT] [--app-url HTTPS_ORIGIN]" >&2; exit 2 ;;
    esac
done
command -v node >/dev/null || { echo 'Install Node.js 20+ first.' >&2; exit 1; }
command -v git >/dev/null || { echo 'Install Git first.' >&2; exit 1; }
if [ -z "$dir" ]; then
    [ -t 0 ] || { echo 'Use --dir for a non-interactive installation.' >&2; exit 2; }
    read -r -p "Instance directory [${HOME}/mcp-kit/metamcp/instance]: " dir
    dir="${dir:-$HOME/mcp-kit/metamcp/instance}"
fi
if [ ! -f "$dir/.mcpkit/state.json" ] && [ -z "$port" ]; then
    [ -t 0 ] || { echo 'Every new MetaMCP requires an explicit --port.' >&2; exit 2; }
    read -r -p 'Port for this new MetaMCP (1-65535): ' port
    [ -n "$port" ] || { echo 'A port is required.' >&2; exit 2; }
fi
if [ ! -f "$dir/.mcpkit/state.json" ] && [ -z "$app_url" ] && [ -t 0 ]; then
    read -r -p 'Public HTTPS origin, or Enter for localhost: ' app_url
fi
mcpkit_require_docker
args=(init-meta --dir "$dir")
[ -z "$port" ] || args+=(--port "$port")
[ -z "$app_url" ] || args+=(--app-url "$app_url")
exec node "$HERE/../common/stack.mjs" "${args[@]}"
