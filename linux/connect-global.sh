#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -le 1 ] || { echo "Usage: $0 [GLOBAL_DIRECTORY]" >&2; exit 2; }
exec node "$HERE/../common/register.mjs" global --dir "${1:-$HOME/mcp-kit/global}"
