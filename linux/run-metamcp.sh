#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-}"
[ -n "$dir" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|check-env|apply|remove|recover-env|setup} DIRECTORY [--delete-volumes]" >&2; exit 2; }
case "$command" in
    setup)
        [ "$#" -eq 2 ] || { echo 'setup takes only a MetaMCP directory.' >&2; exit 2; }
        mcpkit_require_docker
        # A ready marker may remain after interrupted publication. Activation
        # validates it and the database again; do not provision a published app.
        if [ ! -e "$dir/.mcpkit/publication-ready.json" ]; then
            node "$HERE/../common/stack.mjs" provision-meta --dir "$dir" --expect-type meta
        fi
        exec node "$HERE/../common/stack.mjs" activate-meta --dir "$dir" --expect-type meta ;;
    start) mcpkit_require_docker ;;
    stop|status|logs|check-env|apply|remove|recover-env) ;;
    *) echo "Unknown command: $command" >&2; exit 2 ;;
esac
args=("$command" --dir "$dir" --expect-type meta)
[ "$#" -lt 3 ] || args+=("$3")
exec node "$HERE/../common/stack.mjs" "${args[@]}"
