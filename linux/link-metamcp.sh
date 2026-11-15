#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/docker-common.sh
source "$HERE/docker-common.sh"
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 SOURCE_METAMCP_DIRECTORY TARGET_METAMCP_DIRECTORY --endpoint ENDPOINT [--unlink]" >&2
  echo "       $0 SOURCE_METAMCP_DIRECTORY TARGET_METAMCP_DIRECTORY --unlink" >&2
  exit 2
fi
source_dir=$1
target_dir=$2
shift 2
action=link-metamcp
endpoint=
endpoint_seen=false
unlink_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint)
      [ "$endpoint_seen" = false ] && [ "$#" -ge 2 ] && [ -n "$2" ] || { echo 'Pass one value after --endpoint.' >&2; exit 2; }
      endpoint=$2
      endpoint_seen=true
      shift 2
      ;;
    --unlink)
      [ "$unlink_seen" = false ] || { echo 'Duplicate --unlink option.' >&2; exit 2; }
      unlink_seen=true
      action=unlink-metamcp
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ "$action" = link-metamcp ] && [ "$endpoint_seen" = false ]; then
  echo 'A source endpoint is required: pass --endpoint NAME or a full /metamcp/NAME/mcp URL.' >&2
  exit 2
fi
if [ "$action" = unlink-metamcp ] && [ "$endpoint_seen" = true ]; then
  echo '--endpoint cannot be combined with --unlink.' >&2
  exit 2
fi
mcpkit_require_docker
args=("$action" --dir "$source_dir" --peer-dir "$target_dir" --expect-type meta)
if [ "$action" = link-metamcp ]; then args+=(--endpoint "$endpoint"); fi
exec node "$HERE/../common/stack.mjs" "${args[@]}"
