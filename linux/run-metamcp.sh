#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-}"
[ -n "$dir" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|check-env|apply|remove|recover-env|setup|register-service|unregister-service} DIRECTORY [--delete-volumes]" >&2; exit 2; }
case "$command" in
    register-service)
        [ "$#" -eq 2 ] || { echo 'register-service takes only a MetaMCP directory.' >&2; exit 2; }
        node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]);try{const s=JSON.parse(fs.readFileSync(path.join(base,".mcpkit","state.json"),"utf8"));if(s.version!==1||s.type!=="meta"||s.base!==base||typeof s.id!=="string"||! /^[a-f0-9]{16}$/.test(s.id)||s.project!==`mcpkit-meta-${s.id}`||!Number.isInteger(s.port)||s.port<1||s.port>65535)process.exit(1)}catch{process.exit(1)}' "$dir" || { echo 'The selected directory is not an initialized independent MetaMCP installation.' >&2; exit 1; }
        source "$HERE/service-registration.sh"
        mcpkit_register_service metamcp "$HERE/run-metamcp.sh" "$dir" start stop yes
        exit $? ;;
    unregister-service)
        [ "$#" -eq 2 ] || { echo 'unregister-service takes only a MetaMCP directory.' >&2; exit 2; }
        source "$HERE/service-registration.sh"
        mcpkit_unregister_service metamcp "$dir"
        exit $? ;;
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
