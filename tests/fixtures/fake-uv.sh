#!/usr/bin/env bash
# Synthetic uv for the POSIX PowerShell installer test; no packages are fetched.
set -euo pipefail
if [[ ${1-} == --version ]]; then
    printf 'uv 0.13.8\n'
elif [[ ${1-} == python && ${2-} == find ]]; then
    request="${*: -1}"
    if [[ "$request" == *3.14* ]]; then printf '%s\n' "$MCP_TEST_ROOT/python-3.14"; else printf '%s\n' "$MCP_TEST_ROOT/python-3.12"; fi
elif [[ ${1-} == venv && ${2-} == --python ]]; then
    venv="$4"
    mkdir -p "$venv/Scripts" "$venv/bin"
    version=3.12
    [[ $(basename "$venv") != windows-mcp ]] || version=3.14
    # Execute the installer's real -c probe with a simulated interpreter
    # version. Reject embedded double quotes: Windows PowerShell 5.1 loses
    # those when passing native arguments, even though POSIX PowerShell does not.
    cat > "$venv/Scripts/python.exe" <<EOF
#!/usr/bin/env python3
import sys
if len(sys.argv) != 3 or sys.argv[1] != '-c' or chr(34) in sys.argv[2]:
    sys.exit(17)
sys.version_info = tuple(map(int, '$version'.split('.')))
exec(sys.argv[2])
EOF
    chmod +x "$venv/Scripts/python.exe"
elif [[ ${1-} == pip && ${2-} == install && ${3-} == --python ]]; then
    venv="$(dirname "$(dirname "$4")")"
    package="${5%%==*}"
    case "$package" in
        windows-mcp) entry=windows-mcp ;;
        mcp-server-everything-search) entry=mcp-server-everything-search ;;
        mcp-server-git) entry=mcp-server-git ;;
        serena-agent) entry=serena ;;
        markitdown-mcp) entry=markitdown-mcp ;;
        mcp-obsidian) entry=mcp-obsidian ;;
        *) echo "unexpected fake Python package: $package" >&2; exit 1 ;;
    esac
    printf '#!/bin/sh\nexit 0\n' > "$venv/Scripts/$entry.exe"
    { printf '#!/usr/bin/env node\n'; cat "$MCP_TEST_FIXTURE"; } > "$venv/bin/$entry"
    chmod +x "$venv/Scripts/$entry.exe" "$venv/bin/$entry"
else
    echo "unexpected fake uv arguments: $*" >&2
    exit 1
fi
