#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 GLOBAL_DIRECTORY METAMCP_DIRECTORY [REGISTRATION_ID]" >&2; exit 2; }
args=(share-global --dir "$1" --meta-dir "$2")
[ "$#" -lt 3 ] || args+=(--registration "$3")
exec node "$HERE/../common/stack.mjs" "${args[@]}"
