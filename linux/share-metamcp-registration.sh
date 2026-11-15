#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 2 ] || { echo "Usage: $0 METAMCP_DIRECTORY REGISTRATION_JOURNAL.json" >&2; exit 2; }
exec node "$HERE/../common/stack.mjs" share-registration --dir "$1" --registration-file "$2"
