#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command="${1:-start}"
dir="${2:-$HOME/mcp-kit/local}"
server="${3:-}"
[ "$#" -le 3 ] || { echo "Usage: $0 {start|stop|restart|status|logs} [DIRECTORY] [SERVER]" >&2; exit 2; }
case "$command" in start|stop|restart|status|logs) ;; *) echo "Unknown command: $command" >&2; exit 2;; esac
if [ "$command" != logs ] && [ -n "$server" ]; then echo 'SERVER is only accepted for logs.' >&2; exit 2; fi
args=("$command" "$dir")
[ -z "$server" ] || args+=("$server")
exec node "$HERE/../common/local-control.mjs" "${args[@]}"
