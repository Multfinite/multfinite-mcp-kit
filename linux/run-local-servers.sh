#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command="${1:-start}"
dir="${2:-$HOME/mcp-kit/local}"
server="${3:-}"
[ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|restart|status|logs|register-service|unregister-service} [DIRECTORY] [SERVER]" >&2; exit 2; }
case "$command" in
    register-service)
        [ -z "$server" ] || { echo 'register-service takes only the LOCAL directory.' >&2; exit 2; }
        node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]);try{const read=f=>JSON.parse(fs.readFileSync(path.join(base,f),"utf8"));const marker=read("config/private/linux-kit.json"),settings=read("config/local-settings.json"),secrets=read("config/private/secrets.json");if(marker.version!==1||marker.base!==base||marker.hostId!==settings.hostId||! /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(marker.hostId)||settings.version!==1||!Number.isInteger(settings.port)||settings.port<1||settings.port>65535||! /^[a-f0-9]{64}$/.test(secrets.gatewayApiKey||""))process.exit(1)}catch{process.exit(1)}' "$dir" || { echo 'The selected directory is not an initialized independent Linux LOCAL installation.' >&2; exit 1; }
        source "$HERE/service-registration.sh"
        mcpkit_register_service local "$HERE/run-local-servers.sh" "$dir" start stop yes
        exit $? ;;
    unregister-service)
        [ -z "$server" ] || { echo 'unregister-service takes only the LOCAL directory.' >&2; exit 2; }
        source "$HERE/service-registration.sh"
        mcpkit_unregister_service local "$dir"
        exit $? ;;
    start|stop|restart|status|logs) ;;
    *) echo "Unknown command: $command" >&2; exit 2;;
esac
if [ "$command" != logs ] && [ -n "$server" ]; then echo 'SERVER is only accepted for logs.' >&2; exit 2; fi
args=("$command" "$dir")
[ -z "$server" ] || args+=("$server")
exec node "$HERE/../common/local-control.mjs" "${args[@]}"
