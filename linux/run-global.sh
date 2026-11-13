#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$HOME/mcp-global"
CONFIG_DIR="$BASE_DIR/config"
METAMCP_DIR="$BASE_DIR/metamcp"
CONFIG_ENV="$CONFIG_DIR/.env"
SEED_SQL="$SCRIPT_DIR/seed-global.sql"
SERVICES_COMPOSE="$SCRIPT_DIR/services/docker-compose.yml"
SERVICES_PROJECT="multfinite-mcp-kit-global"

header()  { echo -e "\n\033[1;36m═══ $* ═══\033[0m"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
warn()    { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

compose() { (cd "$METAMCP_DIR" && docker compose "$@"); }

# Older installs generated these example values. They are not credentials.
credential_value() {
    case "$1" in
        ''|sk-your-openai-key-here|sk-or-v1-your-key-here|ghp_your_token_here) printf '%s' '' ;;
        *) printf '%s' "$1" ;;
    esac
}

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
            unset GITHUB_PERSONAL_ACCESS_TOKEN CONTEXT7_API_KEY
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
            encode "$(credential_value "${GITHUB_PERSONAL_ACCESS_TOKEN:-}")"
            encode "$(credential_value "${CONTEXT7_API_KEY:-}")"
            printf '%s\n' 'END'
        )
    ); then
        error "Не удалось прочитать $CONFIG_ENV"
        return 1
    fi
    local -a values
    mapfile -t values <<< "$encoded"
    if [ "${#values[@]}" -ne 8 ] || [ "${values[7]}" != END ]; then
        error "Не удалось прочитать настройки MCP-серверов из $CONFIG_ENV"
        return 1
    fi
    SEED_NEO4J_URI="${values[0]}"
    SEED_NEO4J_USER="${values[1]}"
    SEED_NEO4J_PASSWORD="${values[2]}"
    SEED_QDRANT_URL="${values[3]}"
    SEED_QDRANT_API_KEY="${values[4]}"
    SEED_GITHUB_TOKEN="${values[5]}"
    SEED_CONTEXT7_KEY="${values[6]}"
}

# A separate Compose project keeps the user's MetaMCP files and containers
# untouched. Each sidecar gets a private, un-published network; only the
# existing MetaMCP app is attached to it. Values are passed through the process
# environment, never as shell arguments or printed in the log.
services_compose() (
    unset NEO4J_URI NEO4J_USER NEO4J_USERNAME NEO4J_PASSWORD NEO4J_DATABASE
    unset OPENAI_API_KEY LLM_API_ENDPOINT LLM_API_KEY LLM_API_MODEL LLM_API_PROVIDER
    unset GRAPHITI_API_KEY GRAPHITI_API_ENDPOINT GRAPHITI_BASE_URL GRAPHITI_API_MODEL GRAPHITI_MODEL GRAPHITI_EMBEDDER_MODEL GRAPHITI_GROUP_ID
    unset COGNEE_LLM_API_PROVIDER COGNEE_LLM_PROVIDER COGNEE_LLM_API_KEY COGNEE_LLM_API_MODEL COGNEE_LLM_MODEL COGNEE_LLM_API_ENDPOINT COGNEE_LLM_ENDPOINT
    unset COGNEE_EMBEDDING_API_PROVIDER COGNEE_EMBEDDING_PROVIDER COGNEE_EMBEDDING_API_KEY COGNEE_EMBEDDING_API_ENDPOINT COGNEE_EMBEDDING_ENDPOINT COGNEE_EMBEDDING_API_MODEL COGNEE_EMBEDDING_MODEL COGNEE_EMBEDDING_DIMENSIONS
    if [ -f "$CONFIG_ENV" ]; then
        # shellcheck source=/dev/null
        if ! source "$CONFIG_ENV" >/dev/null; then
            error "Не удалось прочитать $CONFIG_ENV"
            return 1
        fi
    fi
    # OPENAI_API_KEY from older shared-key configs remains ignored. The
    # generic LLM_API_* values are explicit defaults overridden per consumer.
    unset OPENAI_API_KEY
    export MCPKIT_NEO4J_URI MCPKIT_NEO4J_USER MCPKIT_NEO4J_PASSWORD MCPKIT_NEO4J_DATABASE
    export MCPKIT_GRAPHITI_API_KEY MCPKIT_GRAPHITI_API_ENDPOINT MCPKIT_GRAPHITI_API_MODEL MCPKIT_GRAPHITI_EMBEDDER_MODEL MCPKIT_GRAPHITI_GROUP_ID
    export MCPKIT_COGNEE_LLM_API_PROVIDER MCPKIT_COGNEE_LLM_API_KEY MCPKIT_COGNEE_LLM_API_MODEL MCPKIT_COGNEE_LLM_API_ENDPOINT
    export MCPKIT_COGNEE_EMBEDDING_API_PROVIDER MCPKIT_COGNEE_EMBEDDING_API_KEY MCPKIT_COGNEE_EMBEDDING_API_ENDPOINT MCPKIT_COGNEE_EMBEDDING_API_MODEL MCPKIT_COGNEE_EMBEDDING_DIMENSIONS
    MCPKIT_NEO4J_URI="$(container_uri "${NEO4J_URI:-bolt://localhost:7687}")"
    MCPKIT_NEO4J_USER="${NEO4J_USERNAME:-${NEO4J_USER:-neo4j}}"
    MCPKIT_NEO4J_PASSWORD="${NEO4J_PASSWORD:-mcp-neo4j-pass}"
    MCPKIT_NEO4J_DATABASE="${NEO4J_DATABASE:-neo4j}"
    local graphiti_api_key cognee_llm_api_key cognee_embedding_api_key
    graphiti_api_key="$(credential_value "${GRAPHITI_API_KEY:-}")"
    [ -n "$graphiti_api_key" ] || graphiti_api_key="$(credential_value "${LLM_API_KEY:-}")"
    cognee_llm_api_key="$(credential_value "${COGNEE_LLM_API_KEY:-}")"
    [ -n "$cognee_llm_api_key" ] || cognee_llm_api_key="$(credential_value "${LLM_API_KEY:-}")"
    cognee_embedding_api_key="$(credential_value "${COGNEE_EMBEDDING_API_KEY:-}")"
    [ -n "$cognee_embedding_api_key" ] || cognee_embedding_api_key="$(credential_value "${LLM_API_KEY:-}")"

    MCPKIT_GRAPHITI_API_KEY="$graphiti_api_key"
    MCPKIT_GRAPHITI_API_ENDPOINT="${GRAPHITI_API_ENDPOINT:-${GRAPHITI_BASE_URL:-${LLM_API_ENDPOINT:-https://api.openai.com/v1}}}"
    MCPKIT_GRAPHITI_API_MODEL="${GRAPHITI_API_MODEL:-${GRAPHITI_MODEL:-${LLM_API_MODEL:-gpt-4o-mini}}}"
    MCPKIT_GRAPHITI_EMBEDDER_MODEL="${GRAPHITI_EMBEDDER_MODEL:-text-embedding-3-small}"
    MCPKIT_GRAPHITI_GROUP_ID="${GRAPHITI_GROUP_ID:-multfinite-mcp-kit-global}"
    MCPKIT_COGNEE_LLM_API_PROVIDER="${COGNEE_LLM_API_PROVIDER:-${COGNEE_LLM_PROVIDER:-${LLM_API_PROVIDER:-openai}}}"
    MCPKIT_COGNEE_LLM_API_KEY="$cognee_llm_api_key"
    MCPKIT_COGNEE_LLM_API_MODEL="${COGNEE_LLM_API_MODEL:-${COGNEE_LLM_MODEL:-${LLM_API_MODEL:-gpt-4o-mini}}}"
    MCPKIT_COGNEE_LLM_API_ENDPOINT="${COGNEE_LLM_API_ENDPOINT:-${COGNEE_LLM_ENDPOINT:-${LLM_API_ENDPOINT:-https://api.openai.com/v1}}}"
    MCPKIT_COGNEE_EMBEDDING_API_PROVIDER="${COGNEE_EMBEDDING_API_PROVIDER:-${COGNEE_EMBEDDING_PROVIDER:-${LLM_API_PROVIDER:-openai}}}"
    MCPKIT_COGNEE_EMBEDDING_API_KEY="$cognee_embedding_api_key"
    MCPKIT_COGNEE_EMBEDDING_API_ENDPOINT="${COGNEE_EMBEDDING_API_ENDPOINT:-${COGNEE_EMBEDDING_ENDPOINT:-${LLM_API_ENDPOINT:-https://api.openai.com/v1}}}"
    MCPKIT_COGNEE_EMBEDDING_API_MODEL="${COGNEE_EMBEDDING_API_MODEL:-${COGNEE_EMBEDDING_MODEL:-text-embedding-3-small}}"
    MCPKIT_COGNEE_EMBEDDING_DIMENSIONS="${COGNEE_EMBEDDING_DIMENSIONS:-1536}"
    docker compose -p "$SERVICES_PROJECT" -f "$SERVICES_COMPOSE" "$@"
)

# Do not adopt someone else's volume or network merely because its name
# happens to match ours. Compose labels identify resources made by this kit.
check_service_resources() {
    local kind spec name resource owner format
    for kind in network volume; do
        if [ "$kind" = network ]; then
            set -- graphiti:graphiti cognee:cognee memory:memory gdrive:gdrive
        else
            set -- cognee-system:cognee_system cognee-data:cognee_data memory-data:memory_data gdrive-data:gdrive_data
        fi
        format="{{index .Labels \"com.docker.compose.project\"}}|{{index .Labels \"com.docker.compose.$kind\"}}"
        for spec in "$@"; do
            name="$SERVICES_PROJECT-${spec%%:*}"
            resource="${spec#*:}"
            if owner="$(docker "$kind" inspect --format "$format" "$name" 2>/dev/null)"; then
                if [ "$owner" != "$SERVICES_PROJECT|$resource" ]; then
                    error "Существующий Docker $kind $name не принадлежит проекту $SERVICES_PROJECT; он не изменён."
                    return 1
                fi
            fi
        done
    done
}

connect_service_networks() {
    local app_id network attached
    command -v jq >/dev/null || { error "Для настройки сетей требуется jq."; return 1; }
    app_id="$(compose ps -q app)" || return 1
    if [ -z "$app_id" ]; then
        error "Не найден контейнер app в Compose MetaMCP."
        return 1
    fi
    for network in graphiti cognee memory gdrive; do
        network="$SERVICES_PROJECT-$network"
        attached="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$app_id")" || return 1
        if ! jq -e --arg network "$network" 'has($network)' <<< "$attached" >/dev/null; then
            # Another concurrent start may have attached it after the check.
            if ! docker network connect "$network" "$app_id"; then
                attached="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$app_id")" || return 1
                if ! jq -e --arg network "$network" 'has($network)' <<< "$attached" >/dev/null; then
                    error "Не удалось подключить MetaMCP к сети $network. Проверьте сетевой режим контейнера."
                    return 1
                fi
            fi
        fi
    done
}

start_services() {
    header "Дополнительные MCP-сервисы"
    if [ ! -f "$SERVICES_COMPOSE" ]; then
        error "Не найден $SERVICES_COMPOSE. Обновите весь комплект файлов."
        return 1
    fi
    command -v jq >/dev/null || { error "Для настройки сетей требуется jq."; return 1; }
    check_service_resources || return 1
    # Never recreate an existing service or its persistent volumes on start.
    services_compose up -d --no-recreate || return 1
    connect_service_networks || return 1
    info "Graphiti, Cognee, GitHub и Google Drive могут требовать ключи/авторизацию; подробности в README."
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

load_public_urls() {
    local encoded
    if [ ! -f "$CONFIG_ENV" ]; then
        error "Не найден $CONFIG_ENV. Сначала выполните install-global.sh."
        return 1
    fi
    if ! encoded=$(
        (
            unset APP_URL NEXT_PUBLIC_APP_URL
            # shellcheck source=/dev/null
            source "$CONFIG_ENV" >/dev/null || exit 1
            printf '%s\n' "$(printf '%s' "${APP_URL:-}" | base64 | tr -d '\n')"
            printf '%s\n' "$(printf '%s' "${NEXT_PUBLIC_APP_URL:-}" | base64 | tr -d '\n')"
        )
    ); then
        error "Не удалось прочитать URL MetaMCP из $CONFIG_ENV"
        return 1
    fi
    local -a urls
    mapfile -t urls <<< "$encoded"
    CONFIG_APP_URL="$(printf '%s' "${urls[0]:-}" | base64 -d)"
    CONFIG_NEXT_PUBLIC_APP_URL="$(printf '%s' "${urls[1]:-}" | base64 -d)"
    # Upstream Compose feeds APP_URL to both the server and NEXT_PUBLIC_APP_URL;
    # keep one canonical origin even if a stale, different frontend value exists.
    if [ -n "$CONFIG_APP_URL" ]; then
        CONFIG_NEXT_PUBLIC_APP_URL="$CONFIG_APP_URL"
    elif [ -n "$CONFIG_NEXT_PUBLIC_APP_URL" ]; then
        CONFIG_APP_URL="$CONFIG_NEXT_PUBLIC_APP_URL"
    fi
}

set_metamcp_url() {
    local key="$1" value="$2" escaped
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        error "$key не должен содержать переносы строк"
        return 1
    fi
    if grep -Fxq -- "$key=$value" "$METAMCP_DIR/.env"; then
        return 0
    fi
    escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
    if grep -q "^${key}=" "$METAMCP_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$METAMCP_DIR/.env"
    else
        printf '%s=%s\n' "$key" "$value" >> "$METAMCP_DIR/.env"
    fi
    chmod 600 "$METAMCP_DIR/.env"
    META_URL_CHANGED=true
}

sync_metamcp_public_urls() {
    META_URL_CHANGED=false
    load_public_urls || return 1
    if [ -z "$CONFIG_APP_URL" ] && [ -z "$CONFIG_NEXT_PUBLIC_APP_URL" ]; then
        info "APP_URL/NEXT_PUBLIC_APP_URL не заданы в kit .env; MetaMCP .env оставлен без изменений."
        return 0
    fi
    [ -z "$CONFIG_APP_URL" ] || set_metamcp_url APP_URL "$CONFIG_APP_URL" || return 1
    [ -z "$CONFIG_NEXT_PUBLIC_APP_URL" ] || set_metamcp_url NEXT_PUBLIC_APP_URL "$CONFIG_NEXT_PUBLIC_APP_URL" || return 1
}

# Compose reads the MetaMCP project .env on the host and injects these values
# into the container environment. Check the running container too: its env may
# be stale even when the host .env already contains the desired URL.
metamcp_app_public_urls_stale() {
    local app_id="$1" app_env
    if [ -z "$CONFIG_APP_URL" ] && [ -z "$CONFIG_NEXT_PUBLIC_APP_URL" ]; then
        return 1
    fi
    app_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$app_id" 2>/dev/null)" || return 0
    if [ -n "$CONFIG_APP_URL" ] && ! grep -Fqx -- "APP_URL=$CONFIG_APP_URL" <<< "$app_env"; then
        return 0
    fi
    if [ -n "$CONFIG_NEXT_PUBLIC_APP_URL" ] && ! grep -Fqx -- "NEXT_PUBLIC_APP_URL=$CONFIG_NEXT_PUBLIC_APP_URL" <<< "$app_env"; then
        return 0
    fi
    return 1
}

ensure_uv_cache_permissions() {
    local writable_test='test -w /home/nextjs/.cache/uv && { [ ! -e /home/nextjs/.cache/uv/CACHEDIR.TAG ] || test -w /home/nextjs/.cache/uv/CACHEDIR.TAG; }'
    # Older MetaMCP images/containers may have initialized the named uv cache
    # volume as root. Probe as the image's runtime user; only repair ownership
    # when needed, then keep the app running unprivileged as usual.
    if compose run --rm -T --no-deps --user 1001:1001 --entrypoint sh app -c "$writable_test" >/dev/null 2>&1; then
        return 0
    fi
    info "Исправление владельца uv cache для пользователя MetaMCP..."
    compose run --rm -T --no-deps --user 0:0 --entrypoint sh app -c \
        'chown -R 1001:1001 /home/nextjs/.cache/uv' || return 1
}

cmd_apply_metamcp_config() {
    check_docker
    [ -f "$METAMCP_DIR/.env" ] || { error "Не найден $METAMCP_DIR/.env. Сначала выполните install-global.sh."; return 1; }
    sync_metamcp_public_urls || return 1

    local app_id
    app_id="$(compose ps -a -q app)" || return 1
    if [ -z "$app_id" ]; then
        if [ "$META_URL_CHANGED" = true ]; then
            success "URL сохранены в MetaMCP .env; контейнер приложения пока не запущен, примените их следующей командой start."
        else
            success "Публичные URL MetaMCP уже соответствуют kit .env; приложение ещё не запущено."
        fi
        return 0
    fi
    if [ "$META_URL_CHANGED" != true ] && ! metamcp_app_public_urls_stale "$app_id"; then
        success "Публичные URL MetaMCP уже применены к контейнеру."
        return 0
    fi

    ensure_uv_cache_permissions || return 1
    warn "Для применения URL пересоздаётся только контейнер MetaMCP app; файлы в его writable layer могут быть потеряны. Named volumes не удаляются."
    compose up -d --no-deps --force-recreate app || return 1
    wait_for_metamcp || return 1
    start_services || return 1
    success "APP_URL и NEXT_PUBLIC_APP_URL применены к MetaMCP."
}

auto_seed_mcp_config() {
    local force="${1:-false}" result state blocked conflicts
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
            printf "\\set github_token_b64 '%s'\n" "$SEED_GITHUB_TOKEN"
            printf "\\set context7_key_b64 '%s'\n" "$SEED_CONTEXT7_KEY"
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

    IFS='|' read -r state blocked conflicts <<< "$result"
    case "$state" in
        seeded)
            success "MCP-серверы по умолчанию зарегистрированы."
            info "Адреса endpoints по группам перечислены в README; новые endpoints требуют API-ключ."
            if [ -n "$blocked" ]; then
                warn "У namespace ($blocked) есть endpoint без аутентификации; новые привязки туда не добавлены."
                warn "Защитите endpoint и выполните: bash $SCRIPT_DIR/run-global.sh seed"
            fi
            if [ -n "$conflicts" ]; then
                warn "Endpoint ($conflicts) уже используется другим namespace или пользователем и не изменён."
                warn "Создайте отдельный защищённый endpoint для нужного namespace в MetaMCP."
            fi
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
    sync_metamcp_public_urls || return 1
    start_storage

    header "MetaMCP Fullstack"
    # Starting/reinstalling must not recreate a running, manually configured
    # MetaMCP container just because the Compose file or image changed. A
    # changed public URL is the exception: Compose only passes updated env to
    # a newly created app container, so recreate app alone after ensuring deps.
    ensure_uv_cache_permissions || return 1
    local app_id
    app_id="$(compose ps -a -q app)" || return 1
    compose up -d --no-recreate
    if [ -n "$app_id" ] && metamcp_app_public_urls_stale "$app_id"; then
        warn "APP_URL в окружении контейнера отличается от kit .env: пересоздаётся только MetaMCP app; сохраните ручные файлы из writable layer."
        compose up -d --no-deps --force-recreate app || return 1
    fi
    wait_for_metamcp
    auto_seed_mcp_config false
    if ! start_services; then
        error "Дополнительные MCP-сервисы не запущены; записи MetaMCP сохранены. Исправьте ошибку и повторите start."
        return 1
    fi
    cmd_status
}

cmd_seed() {
    check_docker
    load_seed_config
    wait_for_metamcp
    auto_seed_mcp_config true
}

# Explicit only: Docker environment is fixed at container creation. Applying
# changed Graphiti/Cognee keys recreates just these two kit-owned containers;
# their data stays in Neo4j/the named Cognee volumes, not their writable layer.
cmd_apply_services() {
    check_docker
    load_seed_config
    command -v jq >/dev/null || { error "Для настройки сетей требуется jq."; return 1; }
    wait_for_metamcp
    check_service_resources
    warn "Пересоздаются только контейнеры Graphiti и Cognee; их постоянные данные и MetaMCP не изменяются."
    services_compose up -d --no-deps --force-recreate mcpkit-graphiti mcpkit-cognee
    connect_service_networks
    success "Настройки Graphiti и Cognee применены."
}

cmd_stop() {
    header "Остановка"
    if [ -f "$SERVICES_COMPOSE" ]; then
        services_compose stop || warn "Не удалось остановить дополнительные MCP-сервисы"
    fi
    # Stop rather than `down`: removing the app container could discard files
    # the user created manually in its writable layer.
    compose stop || warn "Не удалось остановить MetaMCP через Docker Compose"
    docker stop neo4j-mcp qdrant-mcp 2>/dev/null || true
    success "Остановка завершена"
}

cmd_status() {
    echo -e "\n\033[1;35mMetaMCP Status\033[0m"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "metamcp|neo4j|qdrant|mcpkit" || true
}

case "${1:-start}" in
    start)          cmd_start ;;
    seed)           cmd_seed ;;
    apply-services)       cmd_apply_services ;;
    apply-metamcp-config) cmd_apply_metamcp_config ;;
    stop)                 cmd_stop ;;
    restart)        cmd_stop; sleep 2; cmd_start ;;
    status)         cmd_status ;;
    logs)           compose logs -f app ;;
    services-logs)  services_compose logs -f ;;
    *) error "Использование: $0 {start|seed|apply-services|apply-metamcp-config|stop|restart|status|logs|services-logs}"; exit 2 ;;
esac
