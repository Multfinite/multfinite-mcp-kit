#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/mcp-global"
METAMCP_DIR="$BASE_DIR/metamcp"
CONFIG_ENV="$BASE_DIR/config/.env"

header()  { echo -e "\n\033[1;36m═══ $1 ═══\033[0m"; }
success() { echo -e "\033[0;32m[OK]\033[0m $1"; }
info()    { echo -e "\033[0;34m[INFO]\033[0m $1"; }
warn()    { echo -e "\033[0;33m[WARN]\033[0m $1"; }
error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

check_docker() {
    header "Docker"
    if ! docker info >/dev/null 2>&1; then
        error "Docker не запущен"
        exit 1
    fi
    docker network create mcp-net 2>/dev/null || true
    success "Docker и сеть mcp-net готовы"
}

sync_config() {
    header "Синхронизация конфигурации"
    
    if [ ! -f "$CONFIG_ENV" ]; then
        error "Главный конфиг $CONFIG_ENV не найден!"
        exit 1
    fi

    set -a; source "$CONFIG_ENV"; set +a
    local port="${METAMCP_PORT:-12008}"
    local app_url="${APP_URL:-http://localhost:$port}"

    info "Обновление .env..."
    local target_env="$METAMCP_DIR/.env"
    touch "$target_env"

    cat <<EOF > "${target_env}.tmp"
APP_URL=${app_url}
NEXTAUTH_URL=${app_url}
METAMCP_PORT=${port}
PORT=12008
DATABASE_URL=postgresql://${POSTGRES_USER:-metamcp_user}:${POSTGRES_PASSWORD:-metamcp_pass}@pg:5432/${POSTGRES_DB:-metamcp_db}
NEXTAUTH_SECRET=${NEXTAUTH_SECRET:-$(openssl rand -base64 32 2>/dev/null || echo "secret-key-123")}
EOF

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^#.* ]] && echo "$line" >> "${target_env}.tmp" && continue
        key=$(echo "$line" | cut -d'=' -f1)
        if [ -n "$key" ] && ! grep -q "^${key}=" "${target_env}.tmp"; then
            echo "$line" >> "${target_env}.tmp"
        fi
    done < "$target_env"
    mv "${target_env}.tmp" "$target_env"

    if [ ! -f "$METAMCP_DIR/docker-compose.override.yml" ]; then
        info "Создание docker-compose.override.yml..."
        cat <<EOF > "$METAMCP_DIR/docker-compose.override.yml"
services:
  app:
    ports:
      - "${port}:12008"
    environment:
      - APP_URL=\${APP_URL}
      - NEXTAUTH_URL=\${NEXTAUTH_URL}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - default
      - mcp-net
networks:
  mcp-net:
    name: mcp-net
    external: true
EOF
    fi
    success "Конфигурация подготовлена"
}

auto_seed_mcp_config() {
    header "Сидинг конфигурации (Transactional & Adaptive)"

    info "Проверка базы данных..."
    if ! docker exec metamcp-pg psql -U metamcp_user -d metamcp_db -t -c "SELECT count(*) FROM information_schema.tables WHERE table_name = 'mcp_servers';" | grep -q 1; then
        error "Таблицы еще не созданы приложением MetaMCP."
        return 1
    fi

    info "Выполнение атомарной транзакции сидинга..."

    docker exec -i metamcp-pg psql -U metamcp_user -d metamcp_db << 'EOSQL'
BEGIN;

DO $$
DECLARE
    -- Флаги колонок mcp_servers
    has_srv_id boolean;
    has_srv_enabled boolean;
    has_srv_is_enabled boolean;
    has_srv_status boolean;
    has_srv_created_at boolean;

    -- Флаги колонок namespaces
    has_ns_id boolean;
    has_ns_created_at boolean;

    -- Флаги колонок endpoints
    has_ep_id boolean;
    has_ep_enabled boolean;

    -- Флаги колонок mappings
    has_map_id boolean;

    -- Переменные структуры SQL
    ns_uuid text := '00000000-0000-0000-0000-000000000001';
    ep_uuid text := '00000000-0000-0000-0000-000000000002';
    
    srv_cols text;
    srv_v_neo4j text;
    srv_v_qdrant text;
    srv_v_fetch text;
    srv_v_playwright text;
    
    ns_pk text;
    srv_pk text;
BEGIN
    -- 1. Инспекция схемы mcp_servers
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='mcp_servers' AND column_name='id') INTO has_srv_id;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='mcp_servers' AND column_name='enabled') INTO has_srv_enabled;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='mcp_servers' AND column_name='is_enabled') INTO has_srv_is_enabled;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='mcp_servers' AND column_name='status') INTO has_srv_status;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='mcp_servers' AND column_name='created_at') INTO has_srv_created_at;

    -- Инспекция схемы namespaces, endpoints, mappings
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='namespaces' AND column_name='id') INTO has_ns_id;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='namespaces' AND column_name='created_at') INTO has_ns_created_at;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='endpoints' AND column_name='id') INTO has_ep_id;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='endpoints' AND column_name='enabled') INTO has_ep_enabled;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='namespace_server_mappings' AND column_name='id') INTO has_map_id;

    -- Формирование списка колонок для mcp_servers
    srv_cols := 'name, description, type, command, args, env';
    IF has_srv_id THEN srv_cols := 'id, ' || srv_cols; END IF;
    IF has_srv_enabled THEN srv_cols := srv_cols || ', enabled';
    ELSIF has_srv_is_enabled THEN srv_cols := srv_cols || ', is_enabled';
    ELSIF has_srv_status THEN srv_cols := srv_cols || ', status';
    END IF;
    IF has_srv_created_at THEN srv_cols := srv_cols || ', created_at'; END IF;

    -- Формирование значений для Neo4j
    srv_v_neo4j := '''neo4j-global'', ''Neo4j Graph DB'', ''stdio'', ''npx'', ''["-y", "@modelcontextprotocol/server-neo4j"]''::jsonb, ''{"NEO4J_URI":"bolt://neo4j-mcp:7687","NEO4J_USERNAME":"neo4j","NEO4J_PASSWORD":"mcp-neo4j-pass"}''::jsonb';
    IF has_srv_id THEN srv_v_neo4j := 'gen_random_uuid()::text, ' || srv_v_neo4j; END IF;
    IF has_srv_enabled OR has_srv_is_enabled THEN srv_v_neo4j := srv_v_neo4j || ', true';
    ELSIF has_srv_status THEN srv_v_neo4j := srv_v_neo4j || ', ''active''';
    END IF;
    IF has_srv_created_at THEN srv_v_neo4j := srv_v_neo4j || ', NOW()'; END IF;

    -- Формирование значений для Qdrant
    srv_v_qdrant := '''qdrant-global'', ''Qdrant Vector DB'', ''stdio'', ''npx'', ''["-y", "@qdrant/mcp-server-qdrant"]''::jsonb, ''{"QDRANT_URL":"http://qdrant-mcp:6333"}''::jsonb';
    IF has_srv_id THEN srv_v_qdrant := 'gen_random_uuid()::text, ' || srv_v_qdrant; END IF;
    IF has_srv_enabled OR has_srv_is_enabled THEN srv_v_qdrant := srv_v_qdrant || ', true';
    ELSIF has_srv_status THEN srv_v_qdrant := srv_v_qdrant || ', ''active''';
    END IF;
    IF has_srv_created_at THEN srv_v_qdrant := srv_v_qdrant || ', NOW()'; END IF;

    -- Формирование значений для Fetch
    srv_v_fetch := '''fetch'', ''Web Fetcher'', ''stdio'', ''uvx'', ''["mcp-server-fetch"]''::jsonb, ''{}''::jsonb';
    IF has_srv_id THEN srv_v_fetch := 'gen_random_uuid()::text, ' || srv_v_fetch; END IF;
    IF has_srv_enabled OR has_srv_is_enabled THEN srv_v_fetch := srv_v_fetch || ', true';
    ELSIF has_srv_status THEN srv_v_fetch := srv_v_fetch || ', ''active''';
    END IF;
    IF has_srv_created_at THEN srv_v_fetch := srv_v_fetch || ', NOW()'; END IF;

    -- Формирование значений для Playwright
    srv_v_playwright := '''playwright'', ''Browser Automation'', ''stdio'', ''npx'', ''["-y", "@modelcontextprotocol/server-playwright"]''::jsonb, ''{}''::jsonb';
    IF has_srv_id THEN srv_v_playwright := 'gen_random_uuid()::text, ' || srv_v_playwright; END IF;
    IF has_srv_enabled OR has_srv_is_enabled THEN srv_v_playwright := srv_v_playwright || ', true';
    ELSIF has_srv_status THEN srv_v_playwright := srv_v_playwright || ', ''active''';
    END IF;
    IF has_srv_created_at THEN srv_v_playwright := srv_v_playwright || ', NOW()'; END IF;

    -- ВСТАВКА СЕРВЕРОВ
    EXECUTE format('INSERT INTO mcp_servers (%s) VALUES (%s) ON CONFLICT (name) DO NOTHING', srv_cols, srv_v_neo4j);
    EXECUTE format('INSERT INTO mcp_servers (%s) VALUES (%s) ON CONFLICT (name) DO NOTHING', srv_cols, srv_v_qdrant);
    EXECUTE format('INSERT INTO mcp_servers (%s) VALUES (%s) ON CONFLICT (name) DO NOTHING', srv_cols, srv_v_fetch);
    EXECUTE format('INSERT INTO mcp_servers (%s) VALUES (%s) ON CONFLICT (name) DO NOTHING', srv_cols, srv_v_playwright);

    -- 2. ВСТАВКА NAMESPACE
    ns_pk := CASE WHEN has_ns_id THEN 'id' ELSE 'name' END;
    IF NOT EXISTS (SELECT 1 FROM namespaces WHERE name = 'global') THEN
        EXECUTE format('INSERT INTO namespaces (%s name, description %s) VALUES (%s ''global'', ''Основное пространство инструментов'' %s)',
            CASE WHEN has_ns_id THEN 'id,' ELSE '' END,
            CASE WHEN has_ns_created_at THEN ', created_at' ELSE '' END,
            CASE WHEN has_ns_id THEN quote_literal(ns_uuid) || ',' ELSE '' END,
            CASE WHEN has_ns_created_at THEN ', NOW()' ELSE '' END
        );
    END IF;

    -- 3. ВСТАВКА ENDPOINT
    IF NOT EXISTS (SELECT 1 FROM endpoints WHERE name = 'global-sse') THEN
        EXECUTE format('INSERT INTO endpoints (%s name, path, namespace_id %s) VALUES (%s ''global-sse'', ''global'', (SELECT %s FROM namespaces WHERE name=''global'' LIMIT 1) %s)',
            CASE WHEN has_ep_id THEN 'id,' ELSE '' END,
            CASE WHEN has_ep_enabled THEN ', enabled' ELSE '' END,
            CASE WHEN has_ep_id THEN quote_literal(ep_uuid) || ',' ELSE '' END,
            ns_pk,
            CASE WHEN has_ep_enabled THEN ', true' ELSE '' END
        );
    END IF;

    -- 4. ПРИВЯЗКА (MAPPINGS)
    srv_pk := CASE WHEN has_srv_id THEN 'id' ELSE 'name' END;
    EXECUTE format('DELETE FROM namespace_server_mappings WHERE namespace_id = (SELECT %s FROM namespaces WHERE name=''global'' LIMIT 1)', ns_pk);

    EXECUTE format('
        INSERT INTO namespace_server_mappings (%s namespace_id, server_id)
        SELECT %s (SELECT %s FROM namespaces WHERE name=''global''), %s
        FROM mcp_servers WHERE name IN (''neo4j-global'', ''qdrant-global'', ''fetch'', ''playwright'')',
        CASE WHEN has_map_id THEN 'id,' ELSE '' END,
        CASE WHEN has_map_id THEN 'gen_random_uuid()::text,' ELSE '' END,
        ns_pk,
        srv_pk
    );

END $$;

COMMIT;
EOSQL

    if [ $? -eq 0 ]; then
        success "Транзакция сидинга прошла успешно!"
        info "Эндпоинт готов: $APP_URL/api/sse/global"
    else
        error "Ошибка выполнения транзакции. Все изменения были откачены (ROLLBACK)."
        return 1
    fi
}

cmd_start() {
    check_docker
    sync_config

    header "Вспомогательные БД"
    # ... запуск neo4j, qdrant ...

    header "MetaMCP Fullstack"
    (cd "$METAMCP_DIR" && docker compose up -d)

    # Ждем миграции и сидим
    auto_seed_mcp_config

    cmd_status
}

cmd_stop() {
    header "Остановка"
    (cd "$METAMCP_DIR" && docker compose down) || true
    docker stop neo4j-mcp qdrant-mcp 2>/dev/null || true
    success "Всё остановлено"
}

cmd_status() {
    echo -e "\n\033[1;35mMetaMCP Status\033[0m"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "metamcp|neo4j|qdrant"
}

case "${1:-start}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 2; cmd_start ;;
    status)  cmd_status ;;
    logs)    cd "$METAMCP_DIR" && docker compose logs -f app ;;
    *) echo "Использование: $0 {start|stop|restart|status|logs}" ;;
esac