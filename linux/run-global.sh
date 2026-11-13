#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$HOME/mcp-global"
CONFIG_DIR="$BASE_DIR/config"
METAMCP_DIR="$BASE_DIR/metamcp"
CONFIG_ENV="$CONFIG_DIR/.env"
SEED_SQL="$SCRIPT_DIR/seed-global.sql"

header()  { echo -e "\n\033[1;36m═══ $* ═══\033[0m"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
warn()    { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

compose() { (cd "$METAMCP_DIR" && docker compose "$@"); }

check_docker() {
    header "Docker"
    if ! docker info >/dev/null 2>&1; then
        error "Docker не запущен или недоступен текущему пользователю"
        return 1
    fi
    if [ ! -f "$METAMCP_DIR/.env" ]; then
        error "Не найден $METAMCP_DIR/.env. Сначала выполните install-global.sh."
        return 1
    fi

    # Older versions of this kit generated an override with this external
    # network. Keep those installations working without rewriting the override.
    if [ -f "$METAMCP_DIR/docker-compose.override.yml" ] &&
       grep -Eq '^[[:space:]]*name:[[:space:]]*mcp-net[[:space:]]*$' "$METAMCP_DIR/docker-compose.override.yml"; then
        if ! docker network inspect mcp-net >/dev/null 2>&1; then
            docker network create mcp-net >/dev/null
        fi
    fi
    success "Docker готов"
}

# The storage services publish their ports on the host. From the MetaMCP
# container, loopback in the kit's config must refer to Docker's host gateway.
container_uri() {
    local uri="$1"
    if [[ "$uri" =~ ^([[:alpha:]][[:alnum:]+.-]*://)(localhost|127[.]0[.]0[.]1|\[::1\])([:/?]|$)(.*)$ ]]; then
        printf '%s%s%s%s' "${BASH_REMATCH[1]}" 'host.docker.internal' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        printf '%s' "$uri"
    fi
}

load_seed_config() {
    if [ ! -f "$CONFIG_ENV" ]; then
        error "Не найден $CONFIG_ENV. Сначала выполните install-global.sh."
        return 1
    fi
    if [ ! -f "$SEED_SQL" ]; then
        error "Не найден $SEED_SQL. Файлы run-global.sh и seed-global.sql должны быть рядом."
        return 1
    fi

    # Source the kit config in a subshell: API keys and PostgreSQL variables in
    # it must not override the environment used by `docker compose`. Encode
    # values before passing them to psql so quotes/newlines are not SQL syntax.
    local encoded
    if ! encoded=$(
        (
            unset NEO4J_URI NEO4J_USER NEO4J_USERNAME NEO4J_PASSWORD QDRANT_URL QDRANT_API_KEY
            # shellcheck source=/dev/null
            if ! source "$CONFIG_ENV" >/dev/null; then
                exit 1
            fi
            encode() { printf '%s' "$1" | base64 | tr -d '\n'; printf '\n'; }
            encode "$(container_uri "${NEO4J_URI:-bolt://localhost:7687}")"
            encode "${NEO4J_USERNAME:-${NEO4J_USER:-neo4j}}"
            encode "${NEO4J_PASSWORD:-mcp-neo4j-pass}"
            encode "$(container_uri "${QDRANT_URL:-http://localhost:6333}")"
            encode "${QDRANT_API_KEY:-}"
            printf '%s\n' 'END'
        )
    ); then
        error "Не удалось прочитать $CONFIG_ENV"
        return 1
    fi
    local -a values
    mapfile -t values <<< "$encoded"
    if [ "${#values[@]}" -ne 6 ] || [ "${values[5]}" != END ]; then
        error "Не удалось прочитать настройки MCP-серверов из $CONFIG_ENV"
        return 1
    fi
    SEED_NEO4J_URI="${values[0]}"
    SEED_NEO4J_USER="${values[1]}"
    SEED_NEO4J_PASSWORD="${values[2]}"
    SEED_QDRANT_URL="${values[3]}"
    SEED_QDRANT_API_KEY="${values[4]}"
}

start_storage() {
    header "Вспомогательные БД"
    local name running
    for name in neo4j-mcp qdrant-mcp; do
        if ! docker inspect "$name" >/dev/null 2>&1; then
            warn "Контейнер $name не найден; для его создания запустите install-global.sh."
            continue
        fi
        running="$(docker inspect --format '{{.State.Running}}' "$name")"
        if [ "$running" != true ]; then
            info "Запуск $name..."
            docker start "$name" >/dev/null
        fi
    done
}

wait_for_metamcp() {
    local timeout="${METAMCP_START_TIMEOUT:-180}"
    local elapsed=0
    if [[ ! "$timeout" =~ ^[0-9]+$ ]] || [ "${#timeout}" -gt 7 ]; then
        error "METAMCP_START_TIMEOUT должен быть числом секунд"
        return 1
    fi
    timeout=$((10#$timeout))

    info "Ожидание MetaMCP и завершения миграций (до ${timeout} с)..."
    until compose exec -T app curl --silent --fail --max-time 2 http://127.0.0.1:12008/health >/dev/null 2>&1; do
        if (( elapsed >= timeout )); then
            error "MetaMCP не запустился за ${timeout} с. Проверьте логи: bash $SCRIPT_DIR/run-global.sh logs"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    success "MetaMCP запущен, миграции завершены"
}

auto_seed_mcp_config() {
    local force="${1:-false}" result
    header "Регистрация MCP-серверов по умолчанию"
    info "Добавляем только отсутствующие записи; существующие настройки не изменяются."

    # Use the application's actual DATABASE_URL and psql from the official
    # image, rather than guessing the container name, database or credentials.
    # ON_ERROR_STOP is essential: otherwise psql may exit 0 after a SQL error.
    # shellcheck disable=SC2016 # DATABASE_URL must expand inside the container.
    if ! result=$(
        {
            printf "\\set neo4j_uri_b64 '%s'\n" "$SEED_NEO4J_URI"
            printf "\\set neo4j_user_b64 '%s'\n" "$SEED_NEO4J_USER"
            printf "\\set neo4j_password_b64 '%s'\n" "$SEED_NEO4J_PASSWORD"
            printf "\\set qdrant_url_b64 '%s'\n" "$SEED_QDRANT_URL"
            printf "\\set qdrant_api_key_b64 '%s'\n" "$SEED_QDRANT_API_KEY"
            printf "\\set seed_force '%s'\n" "$force"
            cat "$SEED_SQL"
        } | compose exec -T app sh -c '
            if [ -z "${DATABASE_URL:-}" ]; then
                echo "DATABASE_URL не задан в контейнере MetaMCP" >&2
                exit 1
            fi
            exec psql --dbname="$DATABASE_URL" -X -v ON_ERROR_STOP=1 -qAt
        '
    ); then
        error "Не удалось подтвердить регистрацию MCP-серверов. При SQL-ошибке транзакция откатывается; проверьте ошибку PostgreSQL выше."
        return 1
    fi

    case "$result" in
        seeded)
            success "MCP-серверы по умолчанию зарегистрированы."
            info "Endpoint: /metamcp/global-sse/sse (новый endpoint требует API-ключ)."
            ;;
        endpoint-conflict)
            success "MCP-серверы добавлены в общий namespace global."
            warn "Endpoint global-sse уже используется в другом namespace или является приватным; он не изменён."
            warn "Создайте отдельный защищённый endpoint для namespace global в MetaMCP."
            ;;
        unprotected-namespace)
            success "MCP-серверы зарегистрированы в MetaMCP."
            warn "У namespace global есть endpoint без аутентификации; новые привязки не добавлены, чтобы не раскрыть доступ к инструментам."
            warn "Защитите endpoint и выполните: bash $SCRIPT_DIR/run-global.sh seed"
            ;;
        skipped)
            success "Первоначальная регистрация уже выполнена; ручные изменения сохранены."
            ;;
        *)
            error "Неожиданный результат регистрации: $result"
            return 1
            ;;
    esac
}

cmd_start() {
    check_docker
    load_seed_config
    start_storage

    header "MetaMCP Fullstack"
    # Starting/reinstalling must not recreate a running, manually configured
    # MetaMCP container just because the Compose file or image changed.
    compose up -d --no-recreate
    wait_for_metamcp
    auto_seed_mcp_config false
    cmd_status
}

cmd_seed() {
    check_docker
    load_seed_config
    wait_for_metamcp
    auto_seed_mcp_config true
}

cmd_stop() {
    header "Остановка"
    compose down || warn "Не удалось остановить MetaMCP через Docker Compose"
    docker stop neo4j-mcp qdrant-mcp 2>/dev/null || true
    success "Остановка завершена"
}

cmd_status() {
    echo -e "\n\033[1;35mMetaMCP Status\033[0m"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "metamcp|neo4j|qdrant" || true
}

case "${1:-start}" in
    start)   cmd_start ;;
    seed)    cmd_seed ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 2; cmd_start ;;
    status)  cmd_status ;;
    logs)    compose logs -f app ;;
    *) error "Использование: $0 {start|seed|stop|restart|status|logs}"; exit 2 ;;
esac
