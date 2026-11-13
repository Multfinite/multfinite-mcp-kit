#!/usr/bin/env bash
# ============================================================================
# install-global.sh
# Развёртывание глобального стека MetaMCP (Official Docker Compose)
#
# Запуск:
#   bash install-global.sh
# ============================================================================

set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }

# ── Пути ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${HOME}/mcp-global"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
METAMCP_DIR="${BASE_DIR}/metamcp"

# ── 0. Проверка ОС ───────────────────────────────────────────────────────────
header "Проверка окружения"

mkdir -p "${BASE_DIR}" "${CONFIG_DIR}" "${DATA_DIR}"

if grep -qi microsoft /proc/version 2>/dev/null; then
    success "WSL обнаружен"
else
    warn "Это не WSL. Скрипт оптимизирован под WSL, но работает и на обычных Linux."
fi

grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null \
    || error "Ожидается Debian/Ubuntu."

command -v sudo &>/dev/null || error "sudo не найден"
success "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"

# ── 1. Базовые пакеты ────────────────────────────────────────────────────────
header "Базовые пакеты"

# Do not remove existing Docker APT repositories or keyrings.
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git ca-certificates gnupg lsb-release openssl \
    build-essential jq unzip > /dev/null

success "Базовые пакеты установлены"

# ── 2. Docker ────────────────────────────────────────────────────────────────
header "Docker & Docker Compose"

# Install only when the Docker executable is absent. A daemon that is stopped,
# inaccessible, rootless, or missing Compose must never trigger reinstallation.
# Use separate kit-owned APT filenames and do not replace the user's keyrings or
# sources. Reuse an already-configured Docker repository as-is.
install_missing_docker() {
    local distro codename arch repo_pattern
    distro="$(. /etc/os-release; printf '%s' "${ID:-}")"
    codename="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
    case "$distro" in debian|ubuntu) ;; *) error "Автоматическая установка Docker поддерживает только Debian/Ubuntu; установите Docker вручную." ;; esac
    [[ "$codename" =~ ^[a-zA-Z0-9._-]+$ ]] || error "Не удалось определить VERSION_CODENAME для репозитория Docker."
    arch="$(dpkg --print-architecture)"
    repo_pattern='^[[:space:]]*[^#[:space:]].*https?://download[.]docker[.]com/linux/(debian|ubuntu)([/[:space:]]|$)'
    if grep -RqsE --include='*.list' --include='*.sources' "$repo_pattern" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        info "Существующий APT-репозиторий Docker сохранён без изменений."
    else
        # A subshell ensures temporary downloads are removed even if any step
        # fails. Existing, different files are never overwritten.
        (
            scratch="$(mktemp -d)"
            trap 'rm -rf "$scratch"' EXIT
            curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o "$scratch/docker.asc"
            [ -s "$scratch/docker.asc" ] || { echo 'Empty Docker signing key' >&2; exit 1; }
            cat > "$scratch/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distro
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/mcpkit-docker.asc
EOF
            sudo install -m 0755 -d /etc/apt/keyrings
            for spec in "docker.asc:/etc/apt/keyrings/mcpkit-docker.asc" "docker.sources:/etc/apt/sources.list.d/mcpkit-docker.sources"; do
                file="${spec%%:*}"
                destination="${spec#*:}"
                if [ -e "$destination" ] || [ -L "$destination" ]; then
                    cmp -s "$scratch/$file" "$destination" || { echo "Existing $destination differs; it was not overwritten." >&2; exit 1; }
                else
                    sudo install -m 0644 "$scratch/$file" "$destination"
                fi
            done
        )
    fi
    sudo apt-get update -qq
    # Abort on conflicts instead of removing the user's existing packages.
    sudo apt-get install -y -qq --no-remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    if [ "$(id -u)" -ne 0 ]; then
        if ! getent group docker >/dev/null; then
            sudo groupadd docker || getent group docker >/dev/null || error "Не удалось создать группу docker."
        fi
        case " $(id -nG) " in
            *' docker '*) ;;
            *)
                sudo usermod -aG docker "$(id -un)"
                warn "Пользователь добавлен в группу docker (она даёт права администратора). Чтобы членство вступило в силу, выйдите из сеанса и войдите снова."
                ;;
        esac
    fi
}

if ! command -v docker &>/dev/null; then
    info "Docker не найден; установка официальных Docker Engine и Compose plugin..."
    install_missing_docker
fi
if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    error "Docker недоступен текущему пользователю. Запустите Docker, при необходимости заново войдите после добавления в группу docker, и настройте доступ без sudo."
fi
success "Docker работает ($(docker --version))"

# All commands below use the Compose plugin, not the separate docker-compose.
if docker compose version &>/dev/null; then
    success "Docker Compose plugin доступен ($(docker compose version --short))"
else
    error "Docker Compose plugin не найден. Установите docker-compose-plugin"
fi

# ── 3. Клонирование и настройка MetaMCP (Official Quickstart) ──────────────────
header "Установка MetaMCP (GitHub Official)"

if [ -d "${METAMCP_DIR}/.git" ]; then
    success "Репозиторий MetaMCP уже клонирован в ${METAMCP_DIR}"
else
    info "Клонирование https://github.com/metatool-ai/metamcp.git ..."
    git clone --depth 1 https://github.com/metatool-ai/metamcp.git "${METAMCP_DIR}" > /dev/null 2>&1
    success "MetaMCP клонирован"
fi

METAMCP_ENV="${METAMCP_DIR}/.env"
if [ -f "$METAMCP_ENV" ]; then
    success "MetaMCP .env уже существует и не изменяется"
else
    info "Создание ${METAMCP_ENV} из example.env..."
    META_APP_URL='http://localhost:12008'
    META_NEXT_PUBLIC_APP_URL="$META_APP_URL"
    if [ -f "$CONFIG_DIR/.env" ]; then
        if ! URL_VALUES=$( (
            unset APP_URL NEXT_PUBLIC_APP_URL
            # shellcheck source=/dev/null
            source "$CONFIG_DIR/.env" >/dev/null || exit 1
            printf '%s\n' "$(printf '%s' "${APP_URL:-}" | base64 | tr -d '\n')"
            printf '%s\n' "$(printf '%s' "${NEXT_PUBLIC_APP_URL:-}" | base64 | tr -d '\n')"
        ) ); then
            error "Не удалось прочитать $CONFIG_DIR/.env"
        fi
        mapfile -t URL_VALUES <<< "$URL_VALUES"
        if [ -n "${URL_VALUES[0]:-}" ]; then
            META_APP_URL="$(printf '%s' "${URL_VALUES[0]}" | base64 -d)"
        elif [ -n "${URL_VALUES[1]:-}" ]; then
            META_APP_URL="$(printf '%s' "${URL_VALUES[1]}" | base64 -d)"
        fi
        META_NEXT_PUBLIC_APP_URL="$META_APP_URL"
    fi
    if [[ "$META_APP_URL" == *$'\n'* || "$META_APP_URL" == *$'\r'* ]]; then
        error "APP_URL/NEXT_PUBLIC_APP_URL не должны содержать переносы строк"
    fi
    sed_escape() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
    META_APP_URL_ESCAPED="$(sed_escape "$META_APP_URL")"
    META_NEXT_PUBLIC_APP_URL_ESCAPED="$(sed_escape "$META_NEXT_PUBLIC_APP_URL")"
    AUTH_SECRET="$(openssl rand -hex 32)"
    PG_PASS="m3t4mcp_pass_$(openssl rand -hex 16)"
    cp "${METAMCP_DIR}/example.env" "$METAMCP_ENV"
    chmod 600 "$METAMCP_ENV"
    sed -i \
        -e "s|^APP_URL=.*|APP_URL=${META_APP_URL_ESCAPED}|" \
        -e "s|^NEXT_PUBLIC_APP_URL=.*|NEXT_PUBLIC_APP_URL=${META_NEXT_PUBLIC_APP_URL_ESCAPED}|" \
        -e "s|^BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=${AUTH_SECRET}|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|" \
        -e 's|^BOOTSTRAP_USER_EMAIL=.*|BOOTSTRAP_USER_EMAIL=|' \
        -e 's|^BOOTSTRAP_USER_PASSWORD=.*|BOOTSTRAP_USER_PASSWORD=|' \
        -e 's|^BOOTSTRAP_RECREATE_USER=.*|BOOTSTRAP_RECREATE_USER=false|' \
        -e '/^BOOTSTRAP_NAMESPACES=/s/"update":true/"update":false/g' \
        -e '/^BOOTSTRAP_ENDPOINTS=/s/"update":true/"update":false/g' \
        "$METAMCP_ENV"

    success "MetaMCP .env создан и сконфигурирован (порт 12008)"
    info "Тестовые учётные данные MetaMCP отключены; создайте свою учётную запись в Web UI."
fi

info "Предзагрузка Docker-образов MetaMCP..."
if (cd "$METAMCP_DIR" && docker compose pull > /dev/null 2>&1); then
    success "Образы MetaMCP готовы"
else
    warn "Предзагрузка не удалась; Docker Compose попробует получить образы при запуске."
fi

# ── 4. Общий .env для API-ключей ─────────────────────────────────────────────
header "Конфигурация ключей API (.env)"
GLOBAL_ENV="${CONFIG_DIR}/.env"

if [ ! -f "$GLOBAL_ENV" ]; then
    cat > "$GLOBAL_ENV" << EOF
# ── OpenAI-compatible APIs: each service uses its own key and base URL ──
GRAPHITI_API_KEY=
GRAPHITI_BASE_URL=https://api.openai.com/v1
# Graphiti uses this API key/base URL for its LLM and embeddings.
# GRAPHITI_MODEL=gpt-4o-mini
# GRAPHITI_EMBEDDER_MODEL=text-embedding-3-small
# GRAPHITI_GROUP_ID=multfinite-mcp-kit-global

# Cognee LLM and embeddings are independently configurable. Set a provider,
# API key, model and OpenAI-compatible /v1 endpoint for each component.
COGNEE_LLM_PROVIDER=openai
COGNEE_LLM_API_KEY=
COGNEE_LLM_MODEL=gpt-4o-mini
COGNEE_LLM_ENDPOINT=https://api.openai.com/v1
COGNEE_EMBEDDING_PROVIDER=openai
COGNEE_EMBEDDING_API_KEY=
COGNEE_EMBEDDING_MODEL=text-embedding-3-small
COGNEE_EMBEDDING_DIMENSIONS=1536
COGNEE_EMBEDDING_ENDPOINT=https://api.openai.com/v1

# ── Neo4j & Qdrant ──────────────────────────────────────
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=mcp-neo4j-pass
# NEO4J_DATABASE=neo4j  # Graphiti's database; must already exist.
QDRANT_URL=http://localhost:6333

# ── Public MetaMCP address ───────────────────────────────
# Set the public origin (normally HTTPS) and apply it to MetaMCP with
# `bash linux/run-global.sh apply-metamcp-config`.
APP_URL=
# If omitted, NEXT_PUBLIC_APP_URL inherits APP_URL.
NEXT_PUBLIC_APP_URL=

# ── Integrations ────────────────────────────────────────
GITHUB_PERSONAL_ACCESS_TOKEN=
CONTEXT7_API_KEY=
# Google Drive requires a separate OAuth flow; see README.
EOF
    chmod 600 "$GLOBAL_ENV"
    success "Файл ключей создан: ${GLOBAL_ENV}"
else
    success "Файл ключей уже существует и не изменяется: ${GLOBAL_ENV}"
fi

# For a new Neo4j container use the same password that will be registered in
# MetaMCP. Loading the file in a subshell cannot change Compose's environment.
if ! NEO4J_PASS=$(
    unset NEO4J_PASSWORD
    # shellcheck source=/dev/null
    if ! source "$GLOBAL_ENV" >/dev/null; then exit 1; fi
    printf '%s' "${NEO4J_PASSWORD:-mcp-neo4j-pass}"
); then
    error "Не удалось прочитать $GLOBAL_ENV"
fi

# ── 5. Запуск вспомогательных баз (Neo4j & Qdrant) ──────────────────────────
header "Инфраструктура хранения (Neo4j & Qdrant)"

if docker inspect neo4j-mcp >/dev/null 2>&1; then
    if [ "$(docker inspect --format '{{.State.Running}}' neo4j-mcp)" != true ]; then
        docker start neo4j-mcp > /dev/null
    fi
    success "Существующий Neo4j работает"
else
    info "Создание neo4j-mcp..."
    docker run -d --name neo4j-mcp --restart unless-stopped \
        -p 7474:7474 -p 7687:7687 \
        -e NEO4J_AUTH="neo4j/${NEO4J_PASS}" \
        -e NEO4J_PLUGINS='["apoc"]' \
        -v "${DATA_DIR}/neo4j/data:/data" \
        -v "${DATA_DIR}/neo4j/logs:/logs" \
        neo4j:community > /dev/null
    success "Neo4j запущен (bolt://localhost:7687)"
fi

if docker inspect qdrant-mcp >/dev/null 2>&1; then
    if [ "$(docker inspect --format '{{.State.Running}}' qdrant-mcp)" != true ]; then
        docker start qdrant-mcp > /dev/null
    fi
    success "Существующий Qdrant работает"
else
    info "Создание qdrant-mcp..."
    docker run -d --name qdrant-mcp --restart unless-stopped \
        -p 6333:6333 -p 6334:6334 \
        -v "${DATA_DIR}/qdrant:/qdrant/storage" \
        qdrant/qdrant > /dev/null
    success "Qdrant запущен (http://localhost:6333)"
fi

warn "Порты Neo4j и Qdrant опубликованы на хосте; ограничьте сетевой доступ и используйте надёжный пароль Neo4j."

# ── 6. Первый запуск и регистрация MCP-серверов ──────────────────────────────
header "Запуск стека и регистрация MCP-серверов"
bash "$SCRIPT_DIR/run-global.sh" start

# ── 7. Итоговый статус ───────────────────────────────────────────────────────
echo ""
echo "============================================================================"
echo -e "  ${GREEN}${BOLD}✓ ГЛОБАЛЬНЫЙ СТЕК УСТАНОВЛЕН И ЗАПУЩЕН${NC}"
echo "============================================================================"
echo ""
echo "  Web UI MetaMCP (если используется стандартный APP_URL):"
echo "    http://localhost:12008"
echo ""
echo "  Повторный запуск:"
echo "    bash $SCRIPT_DIR/run-global.sh start"
echo ""
echo "============================================================================"
