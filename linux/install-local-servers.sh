#!/usr/bin/env bash
# Install native Linux LOCAL servers without installing or starting MetaMCP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dir="${1:-$HOME/mcp-kit/local}"
port="${2:-13001}"
[ "$#" -le 2 ] || { echo "Usage: $0 [DIRECTORY] [GATEWAY_PORT]" >&2; exit 2; }
for cmd in node npm python3 git; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd. Install it first; Node.js >=22.12 and Python >=3.11,<3.15 are required." >&2; exit 1; }
done
node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<22 || (a===22 && b<12)) { console.error("Node.js >=22.12 is required by the LOCAL packages."); process.exit(1); }'
python3 -c 'import sys; sys.exit(0 if (3,11) <= sys.version_info < (3,15) else "Python >=3.11 and <3.15 is required by the LOCAL packages")'
dir="$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$dir")"
node "$HERE/../common/local-control.mjs" init "$dir" "$port"
# Stop only this gateway before updating its own runtimes. No PID from disk is killed.
node "$HERE/../common/local-control.mjs" stop "$dir"
export NPM_CONFIG_CACHE="$dir/runtime/npm-cache"
manifest="$HERE/../windows/manifest.json"
for group in core codebase vectorstore; do
    mapfile -d '' -t packages < <(node -e 'const m=require(process.argv[1]); for(const p of m.npmGroups[process.argv[2]]) process.stdout.write(p+"\0")' "$manifest" "$group")
    [ "${#packages[@]}" -gt 0 ] || { echo "Could not read npm group $group" >&2; exit 1; }
    folder="$dir/runtime/npm/$group"
    mkdir -p "$folder"
    if [ ! -e "$folder/package.json" ]; then
        # Same isolated sharp override as the Windows installer; never replace
        # a package.json a user or an earlier installation already created.
        if [ "$group" = vectorstore ]; then initial='{"private":true,"overrides":{"@xenova/transformers":{"sharp":"0.33.5"}}}'
        else initial='{"private":true}'; fi
        (set -o noclobber; printf '%s\n' "$initial" > "$folder/package.json")
    fi
    echo "Installing LOCAL npm group: $group"
    npm install --prefix "$folder" --no-audit --no-fund --save-exact "${packages[@]}"
done
# Each server has a separate venv to avoid incompatible MCP SDK dependencies.
while IFS='|' read -r name spec; do
    [ -n "$name" ] || continue
    venv="$dir/runtime/python/$name"
    if [ ! -x "$venv/bin/python" ]; then
        if [ -e "$venv" ]; then echo "Incomplete existing venv was preserved: $venv. Back it up and inspect it before retrying." >&2; exit 1; fi
        python3 -m venv "$venv" || { echo 'Python venv is unavailable; on Debian/Ubuntu install python3-venv.' >&2; exit 1; }
    fi
    echo "Installing LOCAL Python server: $name"
    "$venv/bin/python" -m pip install --disable-pip-version-check "$spec"
done <<'EOF'
everything-search|mcp-server-everything-search==0.3.3
linux-desktop|universal-computer-control[input,linux,screenshot]==0.1.1
git|mcp-server-git==2026.11.11
serena|serena-agent==2.1.0
markitdown|markitdown-mcp==0.0.1a8
obsidian|mcp-obsidian==0.2.3
EOF
if [ "${MCPKIT_SKIP_BROWSER_DOWNLOAD:-0}" != 1 ]; then
    PLAYWRIGHT_BROWSERS_PATH="$dir/runtime/playwright-browsers" \
      node "$dir/runtime/npm/core/node_modules/@playwright/mcp/cli.js" install-browser chromium
else
    echo 'Playwright browser download was skipped; install Chromium before using that server.'
fi
if { ! command -v locate >/dev/null && ! command -v plocate >/dev/null; } || ! command -v which >/dev/null; then
    echo 'Everything Search on Linux requires plocate/locate, which, and an initialized index; install/configure them separately.' >&2
fi
if [ -z "${DISPLAY:-}" ]; then
    echo 'Linux desktop control waits for an interactive X11/XWayland session with DISPLAY.' >&2
fi
export PLAYWRIGHT_BROWSERS_PATH="$dir/runtime/playwright-browsers"
node "$HERE/../common/local-control.mjs" start "$dir"
echo 'LOCAL servers installed. No MetaMCP was installed or configured; use connect-local.sh separately.'
