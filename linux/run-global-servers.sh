#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
command="${1:-}"; dir="${2:-$HOME/mcp-kit/global}"
[ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|status|logs|apply|remove|register-service|unregister-service} [DIRECTORY] [SERVER|--delete-volumes]" >&2; exit 2; }
case "$command" in
    register-service)
        [ "$#" -le 2 ] || { echo 'register-service takes only the GLOBAL directory.' >&2; exit 2; }
        node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]);const file=path.join(base,".mcpkit","state.json");try{const s=JSON.parse(fs.readFileSync(file,"utf8"));if(s.version!==1||s.type!=="global"||s.base!==base||typeof s.id!=="string"||! /^[a-f0-9]{16}$/.test(s.id)||s.project!==`mcpkit-global-${s.id}`||!Number.isInteger(s.port)||s.port<1||s.port>65535)process.exit(1)}catch{process.exit(1)}' "$dir" || { echo 'The selected directory is not an initialized independent GLOBAL installation.' >&2; exit 1; }
        source "$HERE/service-registration.sh"
        mcpkit_register_service global "$HERE/run-global-servers.sh" "$dir" start stop yes
        exit $? ;;
    unregister-service)
        [ "$#" -le 2 ] || { echo 'unregister-service takes only the GLOBAL directory.' >&2; exit 2; }
        source "$HERE/service-registration.sh"
        mcpkit_unregister_service global "$dir"
        exit $? ;;
    start|apply) mcpkit_require_docker ;;
    stop|status|logs|remove) ;;
    *) echo "Usage: $0 {start|stop|status|logs|apply|remove|register-service|unregister-service} [DIRECTORY] [SERVER|--delete-volumes]" >&2; exit 2 ;;
esac
args=("$command" --dir "$dir" --expect-type global)
if [ "$#" -ge 3 ]; then
    if [ "$command" = logs ] && [ "$3" != --delete-volumes ]; then args+=(--server "$3")
    elif [ "$command" = remove ] && [ "$3" = --delete-volumes ]; then args+=(--delete-volumes)
    else echo 'The third argument is a server ID for logs or --delete-volumes for remove.' >&2; exit 2; fi
fi
exec node "$HERE/../common/stack.mjs" "${args[@]}"
