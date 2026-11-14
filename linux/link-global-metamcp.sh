#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 GLOBAL_DIRECTORY METAMCP_DIRECTORY [--unlink]" >&2; exit 2; }
action=link
if [ "${3:-}" = --unlink ]; then action=unlink; elif [ "$#" -eq 3 ]; then echo 'Unknown option.' >&2; exit 2; fi
mcpkit_require_docker
exec node "$HERE/../common/stack.mjs" "$action" --dir "$1" --meta-dir "$2"
