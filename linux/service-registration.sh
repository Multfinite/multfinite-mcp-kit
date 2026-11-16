#!/usr/bin/env bash
# Helpers for registering MCP Kit runners as per-user systemd services.
# Source from a Linux runner; these functions never install or alter Docker.

mcpkit_systemd_quote() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
        echo 'systemd service arguments cannot contain newlines.' >&2
        return 1
    }
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    value=${value//\$/\$\$}
    printf '"%s"' "$value"
}

mcpkit_service_location() {
    local kind="$1" directory="$2" digest
    digest="$(printf '%s\0%s' "$kind" "$directory" | sha256sum | cut -c1-16)" || return 1
    MCPKIT_SYSTEMD_UNIT="mcpkit-${kind}-${digest}.service"
    MCPKIT_SYSTEMD_UNIT_FILE="$HOME/.config/systemd/user/$MCPKIT_SYSTEMD_UNIT"
    MCPKIT_SYSTEMD_MARKER="# mcpkit-managed-service: v1 kind=$kind directory=$directory"
}

mcpkit_require_user_systemd() {
    command -v systemctl >/dev/null 2>&1 || { echo 'systemctl is required to register a service.' >&2; return 1; }
    systemctl --user show-environment >/dev/null 2>&1 || {
        echo 'The current user systemd manager is unavailable. Start a systemd-enabled Linux/WSL user session, then retry.' >&2
        return 1
    }
}

mcpkit_register_service() {
    local kind="$1" runner="$2" directory="$3" start_command="$4" stop_command="$5" pass_directory="$6"
    local runner_abs bash_path quoted_command quoted_dir env_name env_value unit_dir temp_file
    [ "$#" -eq 6 ] || { echo 'Internal error: invalid service registration arguments.' >&2; return 2; }
    [[ "$kind" =~ ^[a-z0-9-]+$ ]] || { echo 'Invalid service kind.' >&2; return 2; }
    [ -f "$runner" ] || { echo "Runner not found: $runner" >&2; return 1; }
    [ -d "$directory" ] || { echo "Installation directory not found: $directory" >&2; return 1; }
    runner_abs="$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$runner")" || return 1
    directory="$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$directory")" || return 1
    bash_path="$(command -v bash)" || { echo 'bash is required to register a service.' >&2; return 1; }
    mcpkit_service_location "$kind" "$directory" || return 1
    mcpkit_require_user_systemd || return 1

    unit_dir="$HOME/.config/systemd/user"
    install -d -m 700 "$unit_dir" || return 1
    if [ -e "$MCPKIT_SYSTEMD_UNIT_FILE" ] && ! grep -Fqx -- "$MCPKIT_SYSTEMD_MARKER" "$MCPKIT_SYSTEMD_UNIT_FILE"; then
        echo "Refusing to replace a unit not owned by MCP Kit: $MCPKIT_SYSTEMD_UNIT_FILE" >&2
        return 1
    fi

    quoted_command="$(mcpkit_systemd_quote "$bash_path") $(mcpkit_systemd_quote "$runner_abs") $(mcpkit_systemd_quote "$start_command")" || return 1
    local quoted_stop
    quoted_stop="$(mcpkit_systemd_quote "$bash_path") $(mcpkit_systemd_quote "$runner_abs") $(mcpkit_systemd_quote "$stop_command")" || return 1
    if [ "$pass_directory" = yes ]; then
        quoted_dir="$(mcpkit_systemd_quote "$directory")" || return 1
        quoted_command+=" $quoted_dir"
        quoted_stop+=" $quoted_dir"
    elif [ "$pass_directory" != no ]; then
        echo 'Internal error: invalid directory argument mode.' >&2
        return 2
    fi

    temp_file="$(mktemp "$unit_dir/.mcpkit-service.XXXXXX")" || return 1
    {
        printf '%s\n' "$MCPKIT_SYSTEMD_MARKER"
        printf '[Unit]\nDescription=Multfinite MCP Kit %s runner\n\n' "$kind"
        printf '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
        printf 'Environment=%s\n' "$(mcpkit_systemd_quote "HOME=$HOME")"
        printf 'Environment=%s\n' "$(mcpkit_systemd_quote "PATH=$PATH")"
        printf 'WorkingDirectory=%s\n' "$(mcpkit_systemd_quote "$directory")"
        for env_name in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY PULSE_SERVER; do
            if [[ -v $env_name ]]; then
                env_value="${!env_name}"
                printf 'Environment=%s\n' "$(mcpkit_systemd_quote "$env_name=$env_value")"
            fi
        done
        printf 'ExecStart=%s\n' "$quoted_command"
        printf 'ExecStop=%s\n' "$quoted_stop"
        printf 'TimeoutStartSec=5min\nTimeoutStopSec=2min\n\n[Install]\nWantedBy=default.target\n'
    } > "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    chmod 600 "$temp_file"
    mv -f -- "$temp_file" "$MCPKIT_SYSTEMD_UNIT_FILE" || { rm -f -- "$temp_file"; return 1; }
    systemctl --user daemon-reload || return 1
    systemctl --user enable --now "$MCPKIT_SYSTEMD_UNIT"
}

mcpkit_unregister_service() {
    local kind="$1" directory="$2"
    [ "$#" -eq 2 ] || { echo 'Internal error: invalid service unregistration arguments.' >&2; return 2; }
    [[ "$kind" =~ ^[a-z0-9-]+$ ]] || { echo 'Invalid service kind.' >&2; return 2; }
    directory="$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$directory")" || return 1
    mcpkit_service_location "$kind" "$directory" || return 1
    mcpkit_require_user_systemd || return 1
    if [ -e "$MCPKIT_SYSTEMD_UNIT_FILE" ]; then
        if ! grep -Fqx -- "$MCPKIT_SYSTEMD_MARKER" "$MCPKIT_SYSTEMD_UNIT_FILE"; then
            echo "Refusing to remove a unit not owned by MCP Kit: $MCPKIT_SYSTEMD_UNIT_FILE" >&2
            return 1
        fi
        systemctl --user disable "$MCPKIT_SYSTEMD_UNIT" || return 1
        rm -f -- "$MCPKIT_SYSTEMD_UNIT_FILE" || return 1
        systemctl --user daemon-reload || return 1
        echo "Removed auto-start registration $MCPKIT_SYSTEMD_UNIT. A currently running server was left running."
    else
        echo "No MCP Kit service is registered for $directory."
    fi
}
