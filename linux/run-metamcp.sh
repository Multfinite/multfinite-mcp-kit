#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-}"
[ -n "$dir" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|remove|recover-env} DIRECTORY [--delete-volumes]" >&2; exit 2; }
case "$command" in
    start) mcpkit_require_docker ;;
    stop|status|logs|remove|recover-env) ;;
    *) echo "Unknown command: $command" >&2; exit 2 ;;
esac
args=("$command" --dir "$dir")
[ "$#" -lt 3 ] || args+=("$3")
exec node "$HERE/../common/stack.mjs" "${args[@]}"
