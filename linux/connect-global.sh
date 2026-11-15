#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --live-global ]; then
    [ "$#" -eq 3 ] || { echo "Usage: $0 --live-global GLOBAL_PROJECT METAMCP_DIRECTORY" >&2; exit 2; }
    exec node "$HERE/../common/register.mjs" global --live-global "$2" --meta-dir "$3"
fi
[ "$#" -le 1 ] || { echo "Usage: $0 [GLOBAL_DIRECTORY] | --live-global GLOBAL_PROJECT METAMCP_DIRECTORY" >&2; exit 2; }
exec node "$HERE/../common/register.mjs" global --dir "${1:-$HOME/mcp-kit/global}"
