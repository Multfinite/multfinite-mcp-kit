#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
dir=''; port=''; app_url=''; lan_ip=''; admin_email=''; staged=0; setup=0; fresh=0; insecure=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir|--port|--app-url|--lan-ip|--admin-email)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in --dir) dir="$2";; --port) port="$2";; --app-url) app_url="$2";; --lan-ip) lan_ip="$2";; --admin-email) admin_email="$2";; esac
            shift 2 ;;
        --staged) staged=1; shift ;;
        --setup) staged=1; setup=1; shift ;;
        --fresh) fresh=1; shift ;;
        --allow-insecure-lan) insecure=1; shift ;;
        *) echo "Usage: $0 [--dir DIR] [--port PORT] [--app-url HTTPS_ORIGIN] [--lan-ip IPV4 --allow-insecure-lan] [--staged|--setup --admin-email EMAIL] [--fresh]" >&2; exit 2 ;;
    esac
done
command -v node >/dev/null || { echo 'Install Node.js 20+ first.' >&2; exit 1; }
command -v git >/dev/null || { echo 'Install Git first.' >&2; exit 1; }
if [ "$setup" -eq 1 ]; then
    [ -t 0 ] && [ -t 1 ] || { echo 'Interactive --setup requires a terminal.' >&2; exit 2; }
    if [ -z "$admin_email" ]; then read -r -p 'Administrator email: ' admin_email; fi
    [ -n "$admin_email" ] || { echo 'An administrator email is required.' >&2; exit 2; }
fi
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
if [ "$staged" -eq 1 ]; then
    # The staging overlay relies on the Compose !reset tag to suppress all
    # host ports until the administrator is created and signup is closed.
    compose_version="$(docker compose version --short)"
    if [[ ! "$compose_version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        echo 'Cannot determine Docker Compose version; staged setup was not started.' >&2; exit 1
    fi
    major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]})); patch=$((10#${BASH_REMATCH[3]}))
    if (( major < 2 || (major == 2 && (minor < 24 || (minor == 24 && patch < 4))) )); then
        echo 'Staged setup requires Docker Compose 2.24.4 or newer.' >&2; exit 1
    fi
fi
args=(init-meta --dir "$dir")
[ -z "$port" ] || args+=(--port "$port")
[ -z "$app_url" ] || args+=(--app-url "$app_url")
[ -z "$lan_ip" ] || args+=(--lan-ip "$lan_ip")
[ -z "$admin_email" ] || args+=(--admin-email "$admin_email")
[ "$staged" -eq 0 ] || args+=(--staged)
[ "$fresh" -eq 0 ] || args+=(--fresh)
[ "$insecure" -eq 0 ] || args+=(--allow-insecure-lan)
if [ "$setup" -eq 1 ]; then
    node "$HERE/../common/stack.mjs" "${args[@]}"
    exec bash "$HERE/run-metamcp.sh" setup "$dir"
fi
exec node "$HERE/../common/stack.mjs" "${args[@]}"
