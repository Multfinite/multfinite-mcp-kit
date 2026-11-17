#!/usr/bin/env bash
# Переводит приватный .env GLOBAL на префиксные имена MCPKIT_<SERVER>_<WHAT>.
#
# Старые общие имена не удаляются, а комментируются: остаются справкой о прежних
# значениях. Конфигурация их больше не читает — источник истины только MCPKIT_*.
# Скрипт идемпотентен: если префиксное имя уже есть, значение не перезаписывается.
# Перед изменением рядом остаётся копия .env.bak-<дата>.
set -euo pipefail

env_file="${1:-$HOME/mcp-kit/global/.mcpkit/.env}"

if [ ! -f "$env_file" ]; then
    echo "Нет файла настроек: $env_file" >&2
    exit 1
fi

backup="${env_file}.bak-$(date +%Y%m%d-%H%M%S)"
cp -- "$env_file" "$backup"
chmod 600 "$backup"
echo "Копия: $backup"

value_of() {
    # Последнее непустое значение старого имени.
    grep -E "^$1=" "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

has_key() {
    grep -qE "^$1=" "$env_file"
}

add_new() {
    local key="$1" value="$2"
    [ -n "$value" ] || return 0
    has_key "$key" && return 0
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
    echo "  + $key"
}

comment_old() {
    local key="$1"
    grep -qE "^$key=" "$env_file" || return 0
    # Без sed -i: перенос через временный файл, чтобы не зависеть от GNU/BSD.
    awk -v k="$key" '
        index($0, k "=") == 1 { print "# deprecated: " $0; next }
        { print }
    ' "$env_file" > "${env_file}.tmp"
    mv -- "${env_file}.tmp" "$env_file"
    chmod 600 "$env_file"
    echo "  ~ $key помечен устаревшим"
}

llm_endpoint="$(value_of LLM_API_ENDPOINT)"
llm_key="$(value_of LLM_API_KEY)"
llm_model="$(value_of LLM_API_MODEL)"
llm_provider="$(value_of LLM_API_PROVIDER)"
embedding_model="$(value_of EMBEDDING_MODEL)"
embedding_dims="$(value_of EMBEDDING_DIMENSIONS)"
neo4j_password="$(value_of NEO4J_PASSWORD)"
context7_key="$(value_of CONTEXT7_API_KEY)"

echo "Перенос значений:"
add_new MCPKIT_GRAPHITI_API_ENDPOINT "$llm_endpoint"
add_new MCPKIT_GRAPHITI_API_KEY "$llm_key"
add_new MCPKIT_GRAPHITI_API_MODEL "$llm_model"
add_new MCPKIT_GRAPHITI_EMBEDDER_MODEL "$embedding_model"
add_new MCPKIT_COGNEE_LLM_API_ENDPOINT "$llm_endpoint"
add_new MCPKIT_COGNEE_LLM_API_KEY "$llm_key"
add_new MCPKIT_COGNEE_LLM_API_MODEL "$llm_model"
add_new MCPKIT_COGNEE_LLM_API_PROVIDER "$llm_provider"
add_new MCPKIT_COGNEE_EMBEDDING_API_ENDPOINT "$llm_endpoint"
add_new MCPKIT_COGNEE_EMBEDDING_API_KEY "$llm_key"
add_new MCPKIT_COGNEE_EMBEDDING_API_MODEL "$embedding_model"
add_new MCPKIT_COGNEE_EMBEDDING_API_PROVIDER "$llm_provider"
add_new MCPKIT_COGNEE_EMBEDDING_DIMENSIONS "$embedding_dims"
add_new MCPKIT_NEO4J_PASSWORD "$neo4j_password"
add_new MCPKIT_CONTEXT7_API_KEY "$context7_key"

echo "Помечаю старые имена:"
for old in LLM_API_ENDPOINT LLM_API_KEY LLM_API_MODEL LLM_API_PROVIDER \
           EMBEDDING_MODEL EMBEDDING_DIMENSIONS NEO4J_PASSWORD CONTEXT7_API_KEY; do
    comment_old "$old"
done

echo
echo "Готово. Проверьте префиксные имена и примените настройки:"
echo "  bash linux/run-global-servers.sh apply \"\$HOME/mcp-kit/global\""
