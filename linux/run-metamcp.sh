#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-}"
if [ "$command" = set-lan ]; then
    [ -n "$dir" ] && [ "$#" -ge 4 ] || { echo "Usage: $0 set-lan DIRECTORY --lan-ip PRIVATE_IPV4 --allow-insecure-lan" >&2; exit 2; }
else
    [ -n "$dir" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|check-env|apply|set-lan|remove|recover-env|setup} DIRECTORY [--delete-volumes]" >&2; exit 2; }
fi
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
    set-lan) mcpkit_require_docker ;;
    stop|status|logs|check-env|apply|remove|recover-env) ;;
    *) echo "Unknown command: $command" >&2; exit 2 ;;
esac
args=("$command" --dir "$dir" --expect-type meta)
if [ "$command" = set-lan ]; then
    # Only the explicit LAN options are forwarded; stack.mjs validates them.
    args+=("${@:3}")
elif [ "$#" -ge 3 ]; then
    args+=("$3")
fi
exec node "$HERE/../common/stack.mjs" "${args[@]}"
