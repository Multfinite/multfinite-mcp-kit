#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "Usage: $0 METAMCP_DIRECTORY PEER_METAMCP_DIRECTORY [--unlink]" >&2; exit 2; }
action=link-metamcp
if [ "${3:-}" = --unlink ]; then action=unlink-metamcp; elif [ "$#" -eq 3 ]; then echo 'Unknown option.' >&2; exit 2; fi
mcpkit_require_docker
exec node "$HERE/../common/stack.mjs" "$action" --dir "$1" --peer-dir "$2" --expect-type meta
