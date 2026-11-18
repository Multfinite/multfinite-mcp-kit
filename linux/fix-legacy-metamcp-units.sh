#!/usr/bin/env bash
# Find system-level units that duplicate a kit MetaMCP and can stop its
# containers. Units created by `run-metamcp.sh register-service` live in the user
# manager and are marked "mcpkit-managed-service"; anything else in the system
# manager that runs run-metamcp.sh is a legacy duplicate.
#
# Why it matters: run-metamcp.sh start works in the foreground, so a Type=forking
# unit reports a start timeout. With Restart=on-failure systemd then repeats
# ExecStop (run-metamcp.sh stop), which stops the containers that were just
# started - roughly every two minutes.
set -euo pipefail

remove=no
directories=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --remove) remove=yes; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) directories+=("$1"); shift ;;
    esac
done

command -v systemctl >/dev/null 2>&1 || { echo 'systemctl is required.' >&2; exit 1; }

unit_instances() {
    {
        systemctl list-units --all --type=service --no-legend --no-pager 'metamcp@*.service' 2>/dev/null | awk '{print $1}'
        for link in /etc/systemd/system/*.wants/metamcp@*.service; do
            [ -L "$link" ] && basename "$link"
        done
    } | sed '/^$/d' | sort -u
}

found=0
units=()
while read -r unit; do
    [ -n "$unit" ] || continue
    fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
    exec_start="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
    case "$exec_start" in
        *run-metamcp.sh*) ;;
        *)
            if [ -f "$fragment" ] && grep -q 'run-metamcp\.sh' "$fragment"; then :; else continue; fi
            ;;
    esac
    if [ -f "$fragment" ] && grep -q 'mcpkit-managed-service' "$fragment"; then continue; fi
    if [ "${#directories[@]}" -gt 0 ]; then
        matched=no
        for directory in "${directories[@]}"; do
            case "$exec_start" in *"$directory"*) matched=yes ;; esac
        done
        [ "$matched" = yes ] || continue
    fi
    found=1
    units+=("$unit")
    echo "conflicting unit: $unit"
    echo "  file:  ${fragment:-(template)}"
    echo "  state: $(systemctl is-active "$unit" 2>/dev/null || true) / $(systemctl is-enabled "$unit" 2>/dev/null || true)"
    echo "  type:  $(systemctl show "$unit" -p Type --value 2>/dev/null) with Restart=$(systemctl show "$unit" -p Restart --value 2>/dev/null)"
    echo "  start: $(printf '%s' "$exec_start" | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' | tr -s ' ' | cut -c1-160)"
    echo "  stop:  $(systemctl show "$unit" -p ExecStop --value 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' | tr -s ' ' | cut -c1-160)"
done < <(unit_instances)

if [ "$found" -eq 0 ]; then
    echo 'No conflicting system-level MetaMCP units were found.'
    exit 0
fi

cat <<'NOTE'

These units compete with the kit's per-user units: every restart runs
run-metamcp.sh stop and stops the containers that were just started.

The kit registers its own units with:
    bash linux/run-metamcp.sh register-service DIRECTORY

Remove the duplicates once, as root:
    sudo bash linux/fix-legacy-metamcp-units.sh --remove
NOTE

[ "$remove" = yes ] || exit 1

if [ "$(id -u)" -ne 0 ]; then
    echo 'Removal requires root: rerun with sudo.' >&2
    exit 1
fi

backup="/var/backups/mcpkit-legacy-units-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$backup"
for unit in "${units[@]}"; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    fragment="$(systemctl show "$unit" -p FragmentPath --value)"
    if [ -f "$fragment" ]; then
        mv -f "$fragment" "$backup/" && echo "moved $fragment -> $backup/"
    fi
    for link in /etc/systemd/system/*.wants/"$unit"; do
        [ -L "$link" ] || continue
        rm -f "$link" && echo "removed link $link"
    done
done
systemctl daemon-reload
echo "Legacy unit files are preserved in $backup. The kit's per-user units were not changed."
