#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-$HOME/mcp-kit/global}"
[ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|apply|remove} [DIRECTORY] [SERVER|--delete-volumes]" >&2; exit 2; }
case "$command" in
    start|apply) mcpkit_require_docker ;;
    stop|status|logs|remove) ;;
    *) echo "Usage: $0 {start|stop|status|logs|apply|remove} [DIRECTORY] [SERVER|--delete-volumes]" >&2; exit 2 ;;
esac
args=("$command" --dir "$dir" --expect-type global)
if [ "$#" -ge 3 ]; then
    if [ "$command" = logs ] && [ "$3" != --delete-volumes ]; then args+=(--server "$3")
    elif [ "$command" = remove ] && [ "$3" = --delete-volumes ]; then args+=(--delete-volumes)
    else echo 'The third argument is a server ID for logs or --delete-volumes for remove.' >&2; exit 2; fi
fi
exec node "$HERE/../common/stack.mjs" "${args[@]}"
