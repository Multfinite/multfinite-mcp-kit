#!/usr/bin/env bash
# Shared Docker startup for Linux entry points. Sourcing this file has no side effects.

mcpkit_require_docker() {
    local context endpoint i
    if ! command -v docker >/dev/null 2>&1; then
        echo 'Docker CLI не найден. Установите Docker Engine и Compose plugin.' >&2
        return 1
    fi
    if docker info >/dev/null 2>&1; then
        docker compose version >/dev/null 2>&1 || { echo 'Docker Compose plugin недоступен.' >&2; return 1; }
        return 0
    fi

    # Never start a local system service to "repair" an explicitly selected
    # remote/rootless/Desktop daemon. In particular, do not modify contexts.
    context="$(docker context show 2>/dev/null || true)"
    endpoint="${DOCKER_HOST:-}"
    if [ -z "$endpoint" ] && [ -n "$context" ]; then
        endpoint="$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    fi
    case "$endpoint" in
        ''|unix:///var/run/docker.sock|unix:///run/docker.sock) ;;
        *)
            echo "Выбран нестандартный Docker endpoint ($endpoint); системная служба не запускается. Запустите и настройте выбранный Docker самостоятельно." >&2
            return 1
            ;;
    esac
    if [ -n "${DOCKER_CONTEXT:-}" ] && [ "${DOCKER_CONTEXT}" != default ]; then
        echo 'Выбран нестандартный Docker context; системная служба не запускается автоматически.' >&2
        return 1
    fi
    if [ -n "$context" ] && [ "$context" != default ]; then
        echo "Выбран Docker context $context; системная служба не запускается автоматически." >&2
        return 1
    fi

    # If it is already running, a failed docker info usually means missing
    # permissions. Restarting the service will not grant those permissions.
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            echo 'Служба Docker работает, но текущий пользователь не имеет доступа к выбранному демону. Проверьте сокет и членство в группе docker; после изменения группы нужен новый вход.' >&2
            return 1
        fi
        echo 'Запуск службы Docker через systemctl (может потребоваться sudo)...'
        if [ "$(id -u)" -eq 0 ]; then
            systemctl start docker || { echo 'Не удалось запустить службу Docker.' >&2; return 1; }
        elif command -v sudo >/dev/null 2>&1; then
            sudo systemctl start docker || { echo 'Не удалось запустить службу Docker через sudo.' >&2; return 1; }
        else
            echo 'Для запуска Docker требуется sudo или администратор.' >&2; return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        if service docker status >/dev/null 2>&1; then
            echo 'Служба Docker работает, но текущий пользователь не имеет доступа к демону. Проверьте права и повторный вход.' >&2
            return 1
        fi
        echo 'Запуск службы Docker через service (может потребоваться sudo)...'
        if [ "$(id -u)" -eq 0 ]; then
            service docker start || { echo 'Не удалось запустить службу Docker.' >&2; return 1; }
        elif command -v sudo >/dev/null 2>&1; then
            sudo service docker start || { echo 'Не удалось запустить службу Docker через sudo.' >&2; return 1; }
        else
            echo 'Для запуска Docker требуется sudo или администратор.' >&2; return 1
        fi
    else
        echo 'Не найден systemd или service для запуска Docker. Запустите выбранный демон вручную.' >&2
        return 1
    fi
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            docker compose version >/dev/null 2>&1 || { echo 'Docker Compose plugin недоступен.' >&2; return 1; }
            return 0
        fi
        sleep 1
    done
    echo 'Docker не стал доступен за 30 секунд. Проверьте service docker status, журналы и права на сокет; после добавления в группу docker нужен новый вход.' >&2
    return 1
}
