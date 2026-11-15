#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 1 ] || { echo "Usage: $0 MOVED_GLOBAL_OR_METAMCP_DIRECTORY" >&2; exit 2; }
exec node "$HERE/../common/stack.mjs" relocate --dir "$1"
