#!/usr/bin/env bash
# ============================================================================
# install-global.sh
# Развёртывание глобального стека MetaMCP (Official Docker Compose)
#
# Запуск:
#   chmod +x install-global.sh
#   ./install-global.sh
# ============================================================================

set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }

# ── Пути ─────────────────────────────────────────────────────────────────────
BASE_DIR="${HOME}/mcp-global"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
METAMCP_DIR="${BASE_DIR}/metamcp"

# ── 0. Проверка ОС ───────────────────────────────────────────────────────────
header "Проверка окружения"

mkdir -p "${BASE_DIR}" "${CONFIG_DIR}" "${DATA_DIR}"

grep -qi microsoft /proc/version 2>/dev/null \
    && success "WSL обнаружен" \
    || warn "Это не WSL. Скрипт оптимизирован под WSL, но работает и на обычных Linux."

grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null \
    || error "Ожидается Debian/Ubuntu."

command -v sudo &>/dev/null || error "sudo не найден"

success "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"

# ── 1. Базовые пакеты ────────────────────────────────────────────────────────
header "Базовые пакеты"

if ls /etc/apt/sources.list.d/docker.* 2>/dev/null | grep -q .; then
    info "Чистим старые репозитории Docker..."
    sudo rm -f /etc/apt/keyrings/docker.* /etc/apt/sources.list.d/docker.*
fi

sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git ca-certificates gnupg lsb-release \
    build-essential jq unzip > /dev/null

success "Базовые пакеты установлены"

# ── 2. Docker ────────────────────────────────────────────────────────────────
header "Docker & Docker Compose"

DOCKER_OK=false

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    success "Docker работает ($(docker --version))"
    DOCKER_OK=true
elif command -v docker &>/dev/null && sudo docker info &>/dev/null 2>&1; then
    info "Фикс прав на docker.sock..."
    sudo chmod 666 /var/run/docker.sock
    if docker info &>/dev/null 2>&1; then
        success "Docker теперь доступен без sudo"
        DOCKER_OK=true
    fi
else
    error "Docker не найден. Установите Docker Desktop на Windows или Docker CE в WSL."
fi

# Проверка docker compose
if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose plugin доступен ($(docker compose version --short))"
elif command -v docker-compose &>/dev/null; then
    success "docker-compose доступен"
else
    error "Docker Compose не найден. Установите docker-compose-plugin"
fi

# ── 3. Клонирование и настройка MetaMCP (Official Quickstart) ─────────────
header "Установка MetaMCP (GitHub Official)"

if [ -d "${METAMCP_DIR}/.git" ]; then
    success "Репозиторий MetaMCP уже клонирован в ${METAMCP_DIR}"
else
    info "Клонирование https://github.com/metatool-ai/metamcp.git ..."
    git clone --depth 1 https://github.com/metatool-ai/metamcp.git "${METAMCP_DIR}" > /dev/null 2>&1
    success "MetaMCP клонирован"
fi

# Настройка .env для MetaMCP
METAMCP_ENV="${METAMCP_DIR}/.env"

if [ -f "$METAMCP_ENV" ]; then
    success "MetaMCP .env уже существует"
else
    info "Создание ${METAMCP_ENV} из example.env..."
    cp "${METAMCP_DIR}/example.env" "$METAMCP_ENV"

    # Генерация секретов
    AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "secret-$(date +%s)")
    PG_PASS="m3t4mcp_pass_$(openssl rand -hex 8 2>/dev/null || echo "123")"

    # Замена дефолтов
    sed -i "s|APP_URL=.*|APP_URL=http://localhost:12008|" "$METAMCP_ENV"
    sed -i "s|NEXT_PUBLIC_APP_URL=.*|NEXT_PUBLIC_APP_URL=http://localhost:12008|" "$METAMCP_ENV"
    sed -i "s|BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=${AUTH_SECRET}|" "$METAMCP_ENV"
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|" "$METAMCP_ENV"

    success "MetaMCP .env создан и сконфигурирован (порт 12008)"
fi

info "Предзагрузка Docker-образов MetaMCP..."
(cd "$METAMCP_DIR" && docker compose pull > /dev/null 2>&1) || true
success "Образы MetaMCP готовы"

# ── 4. Запуск вспомогательных векторных/графовых баз (Neo4j & Qdrant) ──────
header "Инфраструктура хранения (Neo4j & Qdrant)"

NEO4J_PASS="mcp-neo4j-pass"

# Neo4j
if docker ps -a --format '{{.Names}}' | grep -q '^neo4j-mcp$'; then
    docker ps --format '{{.Names}}' | grep -q '^neo4j-mcp$' || docker start neo4j-mcp > /dev/null
    success "Neo4j работает"
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

# Qdrant
if docker ps -a --format '{{.Names}}' | grep -q '^qdrant-mcp$'; then
    docker ps --format '{{.Names}}' | grep -q '^qdrant-mcp$' || docker start qdrant-mcp > /dev/null
    success "Qdrant работает"
else
    info "Создание qdrant-mcp..."
    docker run -d --name qdrant-mcp --restart unless-stopped \
        -p 6333:6333 -p 6334:6334 \
        -v "${DATA_DIR}/qdrant:/qdrant/storage" \
        qdrant/qdrant > /dev/null
    success "Qdrant запущен (http://localhost:6333)"
fi

# ── 5. Общий .env для API-ключей ─────────────────────────────────────────────
header "Конфигурация ключей API (.env)"

GLOBAL_ENV="${CONFIG_DIR}/.env"

if [ ! -f "$GLOBAL_ENV" ]; then
    cat > "$GLOBAL_ENV" << EOF
# ── LLM (OpenRouter / DeepSeek) ─────────────────────────
LLM_API_BASE=https://openrouter.ai/api/v1
LLM_API_KEY=sk-or-v1-your-key-here
LLM_MODEL=deepseek/deepseek-r1
EMBEDDING_MODEL=text-embedding-3-small

# ── Embeddings (OpenAI) ─────────────────────────────────
OPENAI_API_KEY=sk-your-openai-key-here

# ── Neo4j & Qdrant ──────────────────────────────────────
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=${NEO4J_PASS}
QDRANT_URL=http://localhost:6333

# ── Integrations ────────────────────────────────────────
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_your_token_here
GOOGLE_APPLICATION_CREDENTIALS=${CONFIG_DIR}/gdrive-credentials.json
EOF
    success "Файл ключей создан: ${GLOBAL_ENV}"
else
    success "Файл ключей уже существует: ${GLOBAL_ENV}"
fi

# ── 6. Итоговый статус ───────────────────────────────────────────────────────
echo ""
echo "============================================================================"
echo -e "  ${GREEN}${BOLD}✓ УСТАНОВКА ГЛОБАЛЬНОГО СТЕКА ЗАВЕРШЕНА${NC}"
echo "============================================================================"
echo ""
echo "  Запуск стека:"
echo "    ./run-global.sh start"
echo ""
echo "  Web UI MetaMCP после запуска:"
echo "    http://localhost:12008"
echo ""
echo "============================================================================"