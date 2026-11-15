#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
dir=''; port=''; app_url=''; lan_ip=''; admin_email=''; staged=0; fresh=0; insecure=0; clean_tools=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir|--port|--app-url|--lan-ip|--admin-email)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in --dir) dir="$2";; --port) port="$2";; --app-url) app_url="$2";; --lan-ip) lan_ip="$2";; --admin-email) admin_email="$2";; esac
            shift 2 ;;
        --staged) staged=1; shift ;;
        --fresh) fresh=1; shift ;;
        --allow-insecure-lan) insecure=1; shift ;;
        --clean-tools) clean_tools=1; shift ;;
        *) echo "Usage: $0 [--dir DIR] [--port PORT] [--app-url HTTPS_ORIGIN] [--lan-ip IPV4 --allow-insecure-lan] [--clean-tools] [--staged --admin-email EMAIL] [--fresh]" >&2; exit 2 ;;
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
if [ ! -f "$dir/.mcpkit/state.json" ] && [ -z "$app_url" ] && [ -z "$lan_ip" ] && [ "$staged" -eq 0 ] && [ -t 0 ]; then
    read -r -p 'Public HTTPS origin, or Enter for localhost: ' app_url
fi
mcpkit_require_docker
args=(init-meta --dir "$dir")
[ -z "$port" ] || args+=(--port "$port")
[ -z "$app_url" ] || args+=(--app-url "$app_url")
[ -z "$lan_ip" ] || args+=(--lan-ip "$lan_ip")
[ -z "$admin_email" ] || args+=(--admin-email "$admin_email")
[ "$staged" -eq 0 ] || args+=(--staged)
[ "$fresh" -eq 0 ] || args+=(--fresh)
[ "$insecure" -eq 0 ] || args+=(--allow-insecure-lan)
[ "$clean_tools" -eq 0 ] || args+=(--clean-tools)
exec node "$HERE/../common/stack.mjs" "${args[@]}"
