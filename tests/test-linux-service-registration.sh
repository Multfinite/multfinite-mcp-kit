#!/usr/bin/env bash
# Exercise Linux per-user service generation without a real systemd manager or Docker.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo 'Node.js is required for this test.' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MCPKIT_TEST_SYSTEMCTL_LOG"
exit 0
SH
chmod +x "$TMP/bin/systemctl"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export MCPKIT_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log"
META="$TMP/independent Meta %\$ 'quoted'"
GLOBAL="$TMP/independent GLOBAL %\$ 'quoted'"
LOCAL="$TMP/independent LOCAL %\$ 'quoted'"
mkdir -p "$META/.mcpkit" "$GLOBAL/.mcpkit" "$LOCAL/config/private"
node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]),id="0123456789abcdef";fs.writeFileSync(path.join(base,".mcpkit","state.json"),JSON.stringify({version:1,type:"meta",base,id,project:`mcpkit-meta-${id}`,port:12008,appUrl:"http://localhost:12008"}));' "$META"
node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]),id="0123456789abcdef";fs.writeFileSync(path.join(base,".mcpkit","state.json"),JSON.stringify({version:1,type:"global",base,id,project:`mcpkit-global-${id}`,port:13002}));' "$GLOBAL"
node -e 'const fs=require("node:fs"),path=require("node:path");const base=path.resolve(process.argv[1]),hostId="test-host",privateDir=path.join(base,"config","private");fs.writeFileSync(path.join(privateDir,"linux-kit.json"),JSON.stringify({version:1,base,hostId}));fs.writeFileSync(path.join(base,"config","local-settings.json"),JSON.stringify({version:1,hostId,port:13001}));fs.writeFileSync(path.join(privateDir,"secrets.json"),JSON.stringify({gatewayApiKey:"a".repeat(64)}));' "$LOCAL"

bash "$ROOT/linux/run-metamcp.sh" register-service "$META"
bash "$ROOT/linux/run-global-servers.sh" register-service "$GLOBAL"
bash "$ROOT/linux/run-local-servers.sh" register-service "$LOCAL"
source "$ROOT/linux/service-registration.sh"
mcpkit_service_location metamcp "$META"
META_UNIT="$MCPKIT_SYSTEMD_UNIT_FILE"
mcpkit_service_location global "$GLOBAL"
GLOBAL_UNIT="$MCPKIT_SYSTEMD_UNIT_FILE"
mcpkit_service_location local "$LOCAL"
LOCAL_UNIT="$MCPKIT_SYSTEMD_UNIT_FILE"
MCP_TARGET="$HOME/.config/systemd/user/mcpkit-mcp-servers.target"
test -f "$MCP_TARGET"
for unit in "$META_UNIT" "$GLOBAL_UNIT" "$LOCAL_UNIT"; do
    test -f "$unit"
    test "$(stat -c '%a' "$unit")" = 600
    ! grep -Fq -- 'After=default.target' "$unit"
done
quote() { mcpkit_systemd_quote "$1"; }
BASH_ARG="$(quote "$(command -v bash)")"
META_RUNNER="$(quote "$ROOT/linux/run-metamcp.sh")"
GLOBAL_RUNNER="$(quote "$ROOT/linux/run-global-servers.sh")"
LOCAL_RUNNER="$(quote "$ROOT/linux/run-local-servers.sh")"
START="$(quote start)"
STOP="$(quote stop)"
META_DIR="$(quote "$META")"
GLOBAL_DIR="$(quote "$GLOBAL")"
LOCAL_DIR="$(quote "$LOCAL")"
grep -Fxq -- "ExecStart=$BASH_ARG $META_RUNNER $START $META_DIR" "$META_UNIT"
grep -Fxq -- "ExecStop=$BASH_ARG $META_RUNNER $STOP $META_DIR" "$META_UNIT"
grep -Fxq -- 'Wants=mcpkit-mcp-servers.target' "$META_UNIT"
grep -Fxq -- 'After=mcpkit-mcp-servers.target' "$META_UNIT"
grep -Fxq -- 'WantedBy=default.target' "$MCP_TARGET"
grep -Fxq -- "ExecStart=$BASH_ARG $GLOBAL_RUNNER $START $GLOBAL_DIR" "$GLOBAL_UNIT"
grep -Fxq -- 'WantedBy=mcpkit-mcp-servers.target' "$GLOBAL_UNIT"
grep -Fxq -- "WorkingDirectory=$(mcpkit_systemd_path_value "$META")" "$META_UNIT"
grep -Fxq -- "ExecStop=$BASH_ARG $GLOBAL_RUNNER $STOP $GLOBAL_DIR" "$GLOBAL_UNIT"
grep -Fxq -- "ExecStart=$BASH_ARG $LOCAL_RUNNER $START $LOCAL_DIR" "$LOCAL_UNIT"
grep -Fxq -- "ExecStop=$BASH_ARG $LOCAL_RUNNER $STOP $LOCAL_DIR" "$LOCAL_UNIT"
grep -Fq -- '--user enable --now' "$MCPKIT_TEST_SYSTEMCTL_LOG"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$MCP_TARGET" "$META_UNIT" "$GLOBAL_UNIT" "$LOCAL_UNIT"
fi

# Removing a registration must not require the original installation directory.
rm -rf -- "$META" "$GLOBAL" "$LOCAL"
bash "$ROOT/linux/run-metamcp.sh" unregister-service "$META"
bash "$ROOT/linux/run-global-servers.sh" unregister-service "$GLOBAL"
bash "$ROOT/linux/run-local-servers.sh" unregister-service "$LOCAL"
test ! -e "$META_UNIT"
test ! -e "$GLOBAL_UNIT"
test ! -e "$LOCAL_UNIT"
grep -Fq -- '--user disable' "$MCPKIT_TEST_SYSTEMCTL_LOG"

# The legacy GLOBAL entry point registers only after both existing config files exist.
: > "$MCPKIT_TEST_SYSTEMCTL_LOG"
LEGACY="$HOME/mcp-global"
mkdir -p "$LEGACY/config" "$LEGACY/metamcp"
if bash "$ROOT/linux/run-global.sh" register-service >/dev/null 2>&1; then
    echo 'Legacy GLOBAL registration unexpectedly accepted an incomplete installation.' >&2
    exit 1
fi
if grep -Fq -- '--user enable --now' "$MCPKIT_TEST_SYSTEMCTL_LOG"; then
    echo 'Incomplete legacy GLOBAL registration touched systemd.' >&2
    exit 1
fi
printf 'legacy config\n' > "$LEGACY/config/.env"
printf 'legacy MetaMCP config\n' > "$LEGACY/metamcp/.env"
bash "$ROOT/linux/run-global.sh" register-service
source "$ROOT/linux/service-registration.sh"
mcpkit_service_location global-legacy "$LEGACY"
LEGACY_UNIT="$MCPKIT_SYSTEMD_UNIT_FILE"
test -f "$LEGACY_UNIT"
LEGACY_RUNNER="$(quote "$ROOT/linux/run-global.sh")"
grep -Fxq -- "ExecStart=$BASH_ARG $LEGACY_RUNNER $START" "$LEGACY_UNIT"
grep -Fxq -- "ExecStop=$BASH_ARG $LEGACY_RUNNER $STOP" "$LEGACY_UNIT"
rm -rf -- "$LEGACY"
bash "$ROOT/linux/run-global.sh" unregister-service
test ! -e "$LEGACY_UNIT"
echo 'Linux service registration tests passed with mocked systemd.'
