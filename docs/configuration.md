# Конфигурация

## `.env`

В проекте нет одного общего конфигурационного файла: Linux-стек использует `.env`, а текущий Windows LOCAL — JSON-настройки и отдельный приватный файл секретов. Они не взаимозаменяемы. Ни один из файлов с секретами не следует добавлять в Git или отправлять в логи.

### Linux: `~/mcp-global/config/.env`

Это главный пользовательский файл конфигурации глобального набора. Его создаёт `linux/install-global.sh`, если файла ещё нет. Если файл уже существует, установщик его не перезаписывает. Файл читается Bash-скриптами `linux/run-global.sh` при запуске sidecar-сервисов и при регистрации конфигурации MCP в MetaMCP. Ожидаемый формат — shell assignments: `NAME=value`; комментарии начинаются с `#`. Значения должны быть корректны для `source` в Bash. Для значений со специальными символами используйте одинарные кавычки, если секрет не содержит одинарную кавычку; не оставляйте вокруг значения буквальные пробелы.

Начальный вариант файла:

```dotenv
# Общие значения по умолчанию для LLM API; сервисные значения ниже их переопределяют
LLM_API_ENDPOINT=https://api.openai.com/v1
LLM_API_KEY=
LLM_API_MODEL=gpt-4o-mini
LLM_API_PROVIDER=openai

# Graphiti: собственные значения необязательны; пустые наследуются от LLM_API_*
# GRAPHITI_API_ENDPOINT=
# GRAPHITI_API_KEY=
# GRAPHITI_API_MODEL=gpt-4o-mini
# GRAPHITI_EMBEDDER_MODEL=text-embedding-3-small
# GRAPHITI_GROUP_ID=multfinite-mcp-kit-global

# Cognee LLM: собственные значения необязательны; пустые наследуются от LLM_API_*
# COGNEE_LLM_API_ENDPOINT=
# COGNEE_LLM_API_KEY=
# COGNEE_LLM_API_MODEL=gpt-4o-mini
# COGNEE_LLM_API_PROVIDER=openai

# Cognee embeddings: endpoint/key/provider наследуются от LLM_API_*;
# модель и размерность специфичны для embeddings.
COGNEE_EMBEDDING_API_ENDPOINT=
COGNEE_EMBEDDING_API_KEY=
COGNEE_EMBEDDING_API_MODEL=text-embedding-3-small
COGNEE_EMBEDDING_API_PROVIDER=openai
COGNEE_EMBEDDING_DIMENSIONS=1536

# Публичный адрес MetaMCP (не адрес MCP endpoint)
APP_URL=
NEXT_PUBLIC_APP_URL=

# Neo4j; пароль должен совпадать с паролем созданного Neo4j
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=mcp-neo4j-pass
# NEO4J_DATABASE=neo4j

# Qdrant
QDRANT_URL=http://localhost:6333
# QDRANT_API_KEY=

# Интеграции
GITHUB_PERSONAL_ACCESS_TOKEN=
CONTEXT7_API_KEY=

# Переопределения Cognee (необязательны; значения по умолчанию описаны ниже)
# COGNEE_LLM_API_PROVIDER=openai
# COGNEE_LLM_API_KEY=
# COGNEE_LLM_API_MODEL=gpt-4o-mini
# COGNEE_LLM_API_ENDPOINT=
# COGNEE_EMBEDDING_API_PROVIDER=openai
# COGNEE_EMBEDDING_API_KEY=
# COGNEE_EMBEDDING_API_MODEL=text-embedding-3-small
# COGNEE_EMBEDDING_DIMENSIONS=1536
```

Пустые и закомментированные строки не задают ключ. Чтобы включить переменную, уберите `#` и укажите значение. Если в старом `~/mcp-global/config/.env` остался `OPENAI_API_KEY`, kit его игнорирует: это имя не является параметром конфигурации. Для общего ключа по умолчанию используйте `LLM_API_KEY`. Внутри контейнера Graphiti переменная `OPENAI_API_KEY` получает эффективный ключ из `GRAPHITI_API_KEY`, а если он пуст — из `LLM_API_KEY`.

Полный перечень поддерживаемых переменных этого файла:

| Переменная | Назначение, значение по умолчанию и пример |
|---|---|
| `NEO4J_URI` | Адрес Bolt, который используют Graphiti и legacy-сервер Neo4j. По умолчанию `bolt://localhost:7687`; в контейнерах `localhost`, `127.0.0.1` и `[::1]` автоматически заменяются на `host.docker.internal`, чтобы обращаться к опубликованному порту Docker-хоста. Пример удалённого сервера: `NEO4J_URI='bolt+s://neo4j.example.net:7687'`. Хост и порт должны быть доступны как с Docker-хоста, так и из контейнеров sidecar. |
| `NEO4J_USER` | Пользователь Neo4j; по умолчанию `neo4j`. Пример: `NEO4J_USER=app_user`. |
| `NEO4J_USERNAME` | Альтернативное имя той же настройки, поддерживаемое скриптами и Graphiti. Если заданы оба имени, `NEO4J_USERNAME` имеет приоритет над `NEO4J_USER`. Для стандартного случая достаточно `NEO4J_USER`. |
| `NEO4J_PASSWORD` | Пароль подключения Neo4j; по умолчанию `mcp-neo4j-pass`. Это пароль создаваемого инсталлятором нового контейнера Neo4j и должен совпадать с паролем, который передаётся MCP-серверам. Укажите сильный пароль до первого запуска, например `NEO4J_PASSWORD='replace-with-a-long-random-secret'`. У уже существующего контейнера инсталлятор пароль не меняет: при смене здесь отдельно измените пароль в самой БД и в UI MetaMCP. |
| `NEO4J_DATABASE` | Имя уже существующей базы Neo4j для Graphiti; по умолчанию `neo4j`. Пример: `NEO4J_DATABASE=knowledge`. Скрипт не создаёт указанную пользовательскую базу. Используйте отдельную базу/инстанс, если графы должны быть изолированы. Старый `neo4j-global` получает URI, имя пользователя и пароль, но не `NEO4J_DATABASE`. |
| `QDRANT_URL` | URL Qdrant для legacy-сервера `qdrant-global`; по умолчанию `http://localhost:6333`. Локальный адрес в контейнерном контексте превращается в `host.docker.internal`. Пример: `QDRANT_URL='https://qdrant.example.net:6333'`. |
| `QDRANT_API_KEY` | Необязательный API-ключ Qdrant для legacy-сервера. Если пуст, поле не добавляется. Пример: `QDRANT_API_KEY='…'`. Не задаёт ключ на самом сервере Qdrant и не включает там аутентификацию автоматически. |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Токен, который при первоначальной регистрации задаётся как Bearer token официального удалённого сервера `https://api.githubcopilot.com/mcp/`. Пример: `GITHUB_PERSONAL_ACCESS_TOKEN='github_pat_…'`. Можно оставить пустым и добавить токен в настройках сервера MetaMCP. Дайте токену только необходимые разрешения; переменная не создаёт доступ к GitHub и не обходит ограничения учётной записи/сервиса. |
| `CONTEXT7_API_KEY` | Необязательный ключ Context7. При первоначальной регистрации добавляется в окружение сервера `context7`; без него сервер работает с лимитами upstream. Пример: `CONTEXT7_API_KEY='…'`. |
| `APP_URL` | Публичный base URL MetaMCP (origin/base path reverse proxy), например `APP_URL=https://mcp.example.com`. При пустом значении используется имеющаяся настройка MetaMCP; при непустом `run-global.sh start` автоматически переносит его в `~/mcp-global/metamcp/.env` и пересоздаёт только app, если значение изменилось. Для применения без ожидания следующего старта используйте `apply-metamcp-config`. URL сам по себе не открывает порт/firewall и не настраивает TLS/proxy. |
| `NEXT_PUBLIC_APP_URL` | Дублирует публичный URL для frontend. В upstream Compose `APP_URL` является каноническим: он используется и для `NEXT_PUBLIC_APP_URL`. Автоматическая синхронизация записывает одинаковый origin в оба значения; обычно задавайте только `APP_URL=https://mcp.example.com`. |
| `LLM_API_ENDPOINT` | Глобальный endpoint по умолчанию для LLM API; применяется, когда соответствующая переменная сервиса пуста. По умолчанию `https://api.openai.com/v1`. Пример: `LLM_API_ENDPOINT=https://llm.example/v1`. |
| `LLM_API_KEY` | Глобальный API key по умолчанию для LLM API; применяется только если ключ конкретного сервиса пуст. Пример: `LLM_API_KEY='provider-key'`. Старый `OPENAI_API_KEY` вместо него не используется. |
| `LLM_API_MODEL` | Глобальная модель по умолчанию для LLM; применяется, если сервисная модель пуста. По умолчанию `gpt-4o-mini`. Пример: `LLM_API_MODEL=claude-3-5-sonnet`. |
| `LLM_API_PROVIDER` | Глобальный provider по умолчанию для поддерживающих его сервисов; сейчас используется Cognee, по умолчанию `openai`. Graphiti принимает OpenAI-compatible endpoint и отдельный provider-параметр не поддерживает. |
| `GRAPHITI_API_KEY` | API key Graphiti; если пуст, используется `LLM_API_KEY`. Graphiti использует ключ для LLM и embeddings. Пример: `GRAPHITI_API_KEY='graphiti-key'`. |
| `GRAPHITI_API_ENDPOINT` | API endpoint Graphiti; если пуст, используется `LLM_API_ENDPOINT`, затем `https://api.openai.com/v1`. Передаётся контейнеру как `OPENAI_BASE_URL`. Пример: `GRAPHITI_API_ENDPOINT=https://graphiti.example/v1`. Старое имя `GRAPHITI_BASE_URL` продолжает приниматься, но новое имя имеет приоритет. |
| `GRAPHITI_API_MODEL` | LLM-модель Graphiti; если пуст, используется `LLM_API_MODEL`, затем `gpt-4o-mini`. Передаётся как `MODEL_NAME`. Пример: `GRAPHITI_API_MODEL=gpt-4o-mini`. Старое имя `GRAPHITI_MODEL` продолжает приниматься. |
| `GRAPHITI_EMBEDDER_MODEL` | Модель эмбеддингов Graphiti; по умолчанию `text-embedding-3-small`. Передаётся как `EMBEDDER_MODEL`. Пример: `GRAPHITI_EMBEDDER_MODEL=text-embedding-3-small`. Модель и её размерность должны поддерживаться конфигурацией Graphiti. |
| `GRAPHITI_GROUP_ID` | Идентификатор группы Graphiti, по умолчанию `multfinite-mcp-kit-global`. Определяет группировку/изоляцию данных внутри Graphiti. Пример: `GRAPHITI_GROUP_ID=team-knowledge`. Используйте одинаковое значение для клиентов, которым нужен общий граф; изменение не переносит уже записанные данные. |
| `COGNEE_LLM_API_PROVIDER` | Provider языковой модели Cognee; если пуст, используется `LLM_API_PROVIDER`, затем `openai`. Выберите поддерживаемое Cognee значение. Старое имя `COGNEE_LLM_PROVIDER` принимается как алиас. |
| `COGNEE_LLM_API_KEY` | API key только для LLM Cognee; если пуст, используется `LLM_API_KEY`. Пример: `COGNEE_LLM_API_KEY='cognee-llm-key'`. |
| `COGNEE_LLM_API_MODEL` | Модель LLM Cognee; если пуст, используется `LLM_API_MODEL`, затем `gpt-4o-mini`. Пример: `COGNEE_LLM_API_MODEL=gpt-4o-mini`. Старое имя `COGNEE_LLM_MODEL` принимается как алиас. |
| `COGNEE_LLM_API_ENDPOINT` | Endpoint LLM Cognee; если пуст, используется `LLM_API_ENDPOINT`, затем `https://api.openai.com/v1`. Передаётся как `LLM_ENDPOINT`. Пример: `COGNEE_LLM_API_ENDPOINT=https://llm.example/v1`. Старое имя `COGNEE_LLM_ENDPOINT` принимается как алиас. Согласуйте provider, модель и endpoint с Cognee/LiteLLM. |
| `COGNEE_EMBEDDING_API_PROVIDER` | Provider embeddings Cognee; если пуст, используется глобальный `LLM_API_PROVIDER`, затем `openai`. Должен поддерживаться Cognee. Старое имя `COGNEE_EMBEDDING_PROVIDER` принимается как алиас. |
| `COGNEE_EMBEDDING_API_KEY` | API key embeddings Cognee; если пуст, используется глобальный `LLM_API_KEY`. Пример: `COGNEE_EMBEDDING_API_KEY='embedding-key'`. |
| `COGNEE_EMBEDDING_API_ENDPOINT` | Endpoint embeddings Cognee; если пуст, используется `LLM_API_ENDPOINT`, затем `https://api.openai.com/v1`. Передаётся как `EMBEDDING_ENDPOINT`. Пример: `COGNEE_EMBEDDING_API_ENDPOINT=https://embeddings.example/v1`. Старое имя `COGNEE_EMBEDDING_ENDPOINT` принимается как алиас. |
| `COGNEE_EMBEDDING_API_MODEL` | Модель embeddings Cognee; по умолчанию `text-embedding-3-small`. Пример: `COGNEE_EMBEDDING_API_MODEL=text-embedding-3-small`. Старое имя `COGNEE_EMBEDDING_MODEL` принимается как алиас. Модель и размерность должны соответствовать endpoint. |
| `COGNEE_EMBEDDING_DIMENSIONS` | Размерность вектора Cognee; по умолчанию `1536`. Пример: `COGNEE_EMBEDDING_DIMENSIONS=1536`. Укажите число, которое соответствует выбранной embedding-модели/провайдеру и уже созданным данным. Несоответствие модели и размерности может ломать индексацию и поиск. |

После изменения переменных Graphiti/Cognee примените изменения командой:

```sh
bash linux/run-global.sh apply-services
```

Она пересоздаёт только контейнеры Graphiti и Cognee, сохраняет их named volumes и не меняет настройки серверов MetaMCP. При обычном `start` kit также проверяет writable-доступ пользователя MetaMCP к named volume uv cache; если том был создан со старым root-владельцем, владельцем файлов становится uid/gid `1001:1001` (пользователь `nextjs`), приложение остаётся непривилегированным. После запуска kit sidecar-сервисов и подключения Docker-сетей `start` сбрасывает устаревший `Error Status` только для общих записей серверов, созданных kit по умолчанию (`neo4j-global`, `qdrant-global`, `fetch`, `duckduckgo`, `graphiti`, `cognee`, `memory-bank-mcp`, `gdrive`), чтобы старые версии MetaMCP повторили соединение после временной ошибки запуска. Конфигурации записей не меняются. Секреты GitHub, Context7 и параметры Neo4j/Qdrant, передаваемые при первоначальном seed, не обновляются повторным обычным `start`: существующие записи MetaMCP намеренно не перезаписываются. Измените такие серверы через UI MetaMCP либо отдельно выполните `bash linux/run-global.sh seed` после проверки поведения seed; seed добавляет отсутствующие записи, но не обновляет имеющиеся.

Команда `bash linux/run-global.sh start` автоматически синхронизирует непустые `APP_URL` / `NEXT_PUBLIC_APP_URL` из этого `.env` в upstream `~/mcp-global/metamcp/.env`. MetaMCP Compose читает этот host-side `.env` через `env_file` и передаёт URL как переменные окружения контейнера; официальный образ не содержит отдельного `.env` внутри контейнера. Скрипт сверяет значения с окружением app-контейнера и пересоздаёт только `app`, если там URL устарели, затем ждёт healthcheck и подключает sidecar-сети заново. Чтобы синхронизировать URL отдельно, не дожидаясь следующего `start`, выполните `bash linux/run-global.sh apply-metamcp-config`. **Перед запуском сохраните ручные файлы из writable layer контейнера app**; Compose volumes не удаляются. Публичный URL также требует настроенного DNS, TLS/reverse proxy или открытого порта и правил firewall. `APP_URL` сам по себе не публикует приложение в интернет.

> **Важно для первого запуска Neo4j.** Задайте `NEO4J_PASSWORD` до `install-global.sh`, создав `~/mcp-global/config/.env` вручную (папку можно создать заранее). Установщик создаёт `neo4j-mcp` только если такого контейнера ещё нет. Для уже созданного контейнера изменение `.env` не меняет пароль и не пересоздаёт контейнер.

#### Как значения попадают в контейнеры и MetaMCP

| Источник `.env` | Получатель |
|---|---|
| `LLM_API_*`, `GRAPHITI_API_*`, `GRAPHITI_EMBEDDER_MODEL`, `GRAPHITI_GROUP_ID`, Neo4j settings | Контейнер `mcpkit-graphiti`; выбранные API endpoint/key/model отображаются в `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `MODEL_NAME` и `EMBEDDER_MODEL`. Непустые `GRAPHITI_API_*` имеют приоритет над глобальными `LLM_API_*`. |
| `COGNEE_LLM_API_*`, `COGNEE_EMBEDDING_API_*`, `COGNEE_EMBEDDING_DIMENSIONS` | Контейнер `mcpkit-cognee`; LLM-настройки отображаются в `LLM_*`, embeddings — в `EMBEDDING_*`, включая `EMBEDDING_ENDPOINT`. Для каждого набора непустые сервисные значения переопределяют глобальные API defaults. Постоянные файлы Cognee находятся в отдельных volumes. |
| `APP_URL`, `NEXT_PUBLIC_APP_URL` | При `start` или `apply-metamcp-config` синхронизируются в одноимённые ключи `~/mcp-global/metamcp/.env`; если URL изменился, app пересоздаётся, чтобы Compose передал обновлённое окружение. |
| `NEO4J_URI`, пользователь, пароль | Запись legacy-сервера `neo4j-global` в MetaMCP как `NEO4J_URI`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`. |
| `QDRANT_URL`, `QDRANT_API_KEY` | Запись legacy-сервера `qdrant-global` как `QDRANT_URL`, `QDRANT_API_KEY` (пустой ключ опускается). |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Bearer token удалённого сервера `github-mcp-server`. |
| `CONTEXT7_API_KEY` | Переменная окружения `CONTEXT7_API_KEY` сервера `context7`. |

Graphiti, Cognee, Memory Bank и GDrive подключаются к MetaMCP по внутренним Docker DNS-именам и порту `8000`; наружу их порты не публикуются. Их адреса и другие свойства регистрации задаются seed-скриптом, а не `.env`.

### MetaMCP: `~/mcp-global/metamcp/.env`

Это отдельный `.env` самого upstream-приложения MetaMCP, а не файл API-ключей набора. Он создаётся копированием `${HOME}/mcp-global/metamcp/example.env`, если отсутствует. Установщик устанавливает права `600`, генерирует секреты и не изменяет уже существующий файл. Compose MetaMCP читает этот файл.

Установщик клонирует текущую ветку `main` MetaMCP и копирует её `example.env`, поэтому состав upstream-настроек может измениться со временем. Ниже описаны как переменные, которые специально меняет этот проект, так и остальные переменные и JSON-ключи из upstream `example.env`, используемого на момент составления этого справочника. После установки именно скопированный `~/mcp-global/metamcp/example.env` и комментарии в нём — окончательный источник для вашей версии.

| Переменная / ключ | Назначение и пример |
|---|---|
| `APP_URL` | Публичный базовый URL MetaMCP, используемый сервером для ссылок. При первом создании upstream `.env` берётся из `~/mcp-global/config/.env`; иначе исходное значение `http://localhost:12008`. Для внешнего доступа укажите, например, `APP_URL=https://mcp.example.com`; `run-global.sh start` синхронизирует его автоматически, а `apply-metamcp-config` применяет немедленно. |
| `NEXT_PUBLIC_APP_URL` | URL MetaMCP, встраиваемый во frontend. В upstream Compose `APP_URL` подставляется в оба поля и является каноническим. Синхронизация при `start` и команда `apply-metamcp-config` поддерживают одинаковый origin в обоих значениях; app пересоздаётся только при изменении URL или несоответствии окружения контейнера. |
| `BETTER_AUTH_SECRET` | Секрет подписи/шифрования Better Auth. Генерируется случайно при создании `.env` (64 шестнадцатеричных символа). Держите постоянным и конфиденциальным; замена может повлиять на сессии/зашифрованные данные. Не используйте демонстрационные значения. |
| `POSTGRES_HOST` | Имя хоста PostgreSQL для приложения; берётся из upstream `example.env`, обычно это service name Compose, например `postgres`. Изменяйте только вместе с соответствующей конфигурацией PostgreSQL. |
| `POSTGRES_PORT` | Порт PostgreSQL, обычно `5432`. Это порт внутри Docker-сети, не обязательно опубликованный порт хоста. |
| `POSTGRES_USER` | Пользователь PostgreSQL приложения, обычно `metamcp_user`. Должен соответствовать созданному пользователю в БД. |
| `POSTGRES_PASSWORD` | Пароль PostgreSQL; установщик генерирует случайный пароль при создании файла. Согласуйте его с сервисом БД и URL подключения. Не путайте с `NEO4J_PASSWORD`. |
| `POSTGRES_DB` | Имя базы MetaMCP, обычно `metamcp_db`; должно соответствовать БД в Compose. |
| `DATABASE_URL` | Строка подключения MetaMCP к PostgreSQL. Обычно строится из `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, например `postgresql://metamcp_user:<пароль>@postgres:5432/metamcp_db`. При ручной смене параметров проверьте, что `DATABASE_URL` тоже согласован. Seed использует именно `DATABASE_URL` приложения. |
| `BOOTSTRAP_USER_EMAIL` | Email пользователя, которого upstream bootstrap может создать. Проект очищает значение, чтобы не создавать тестового пользователя; учётную запись следует создать в UI. Пример upstream-настройки: `BOOTSTRAP_USER_EMAIL=admin@example.com`. |
| `BOOTSTRAP_USER_PASSWORD` | Пароль bootstrap-пользователя. Очищен установщиком; заполнение может создать учётную запись согласно логике upstream. Не храните слабый тестовый пароль. |
| `BOOTSTRAP_RECREATE_USER` | Управляет пересозданием bootstrap-пользователя. Установщик задаёт `false`; не включайте без понимания последствий для пользователя. |
| `BOOTSTRAP_NAMESPACES` | Upstream JSON-массив bootstrap namespace-записей. Установщик сохраняет записи из `example.env`, но меняет `"update":true` на `"update":false`, чтобы bootstrap не переписывал пользовательские namespace. Формат JSON зависит от версии MetaMCP; пример формы элемента — `{"name":"Default","update":false}`. |
| `BOOTSTRAP_ENDPOINTS` | Upstream JSON-массив bootstrap endpoint-записей. Аналогично, установщик сохраняет исходный массив, но меняет `"update":true` на `"update":false`. Пример формы элемента — `[{"name":"Public","update":false}]`. |

Полный набор остальных переменных из upstream `example.env`:

| Переменная | Назначение и пример |
|---|---|
| `NODE_ENV` | Режим Node.js, в upstream-шаблоне `production`. Для стандартной установки оставьте без изменений. |
| `LOG_LEVEL` | Уровень логирования; upstream default `errors-only`, варианты в шаблоне: `all`, `info`, `errors-only`, `none`. Пример `LOG_LEVEL=info` для диагностики; учитывайте, что логи могут содержать чувствительные сведения. |
| `METAMCP_ADMIN_EMAILS` | Необязательный список email администраторов через запятую. Администраторы могут менять глобальные настройки, общие ресурсы и STDIO-команды, запускаемые внутри контейнера. Пример `METAMCP_ADMIN_EMAILS=admin@example.com`. В upstream предупреждают: адреса должны принадлежать уже зарегистрированным пользователям до открытия регистрации; иначе кто-то может зарегистрировать этот адрес. |
| `TRUST_PROXY` | Доверенные reverse-proxy hops/subnets для определения клиентского IP (например, для rate limiting). В upstream default `loopback`. Пример: `TRUST_PROXY=loopback` либо корректная схема доверия вашего прокси по документации MetaMCP. Не доверяйте произвольным внешним заголовкам. |
| `OAUTH_ACCESS_TOKEN_EXPIRES_IN_SECONDS` | Время жизни OAuth access token в секундах; upstream default `3600` (1 час). Пример `OAUTH_ACCESS_TOKEN_EXPIRES_IN_SECONDS=3600`. Неположительные/неверные значения игнорируются. |
| `OAUTH_REFRESH_TOKEN_EXPIRES_IN_SECONDS` | Время жизни refresh token в секундах; upstream default `604800` (7 дней). Пример `OAUTH_REFRESH_TOKEN_EXPIRES_IN_SECONDS=604800`. Неположительные/неверные значения игнорируются. |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | Client ID и секрет внешнего OpenID Connect провайдера. Необходимы для OIDC; храните secret конфиденциально. Callback URL строится как `${APP_URL}/api/auth/oauth2/callback/oidc`. |
| `OIDC_DISCOVERY_URL` | URL OIDC discovery document, пример `https://idp.example.com/.well-known/openid-configuration`. |
| `OIDC_AUTHORIZATION_URL` | Authorization URL провайдера, если требуется вашей конфигурации; пример `https://idp.example.com/auth`. |
| `OIDC_PROVIDER_ID` | Внутренний ID провайдера, необязательный; upstream default `oidc`. |
| `OIDC_SCOPES` | Запрашиваемые OIDC scopes; upstream example `openid email profile`. Оставьте необходимые провайдеру scopes. |
| `OIDC_PKCE` | Включение PKCE; upstream example `true`. Следуйте требованиям OIDC-провайдера. |
| `TRANSFORM_LOCALHOST_TO_DOCKER_INTERNAL` | Docker networking switch; upstream example `true`, преобразует локальные host адреса в адрес, доступный из Docker. Согласуйте с сетевой топологией при использовании внешних/удалённых MCP. |
| `BOOTSTRAP_ENABLE` | Включает bootstrap-конфигурацию; upstream default `true`. Проект оставляет это значение из `example.env`. |
| `BOOTSTRAP_FAIL_HARD` | Останавливать ли инициализацию приложения при ошибке bootstrap; upstream default `false`. |
| `BOOTSTRAP_DEBUG` | Отладочное логирование bootstrap; upstream default `false`. Включайте временно и проверяйте логи перед публикацией. |
| `BOOTSTRAP_API_KEYS` | JSON-массив создаваемых API keys; upstream example включает ключи `Public` (public) и `Private` (private). Установщик его не меняет. Подробности ключей объектов описаны ниже. |
| `BOOTSTRAP_USER_NAME` | Имя одиночного legacy bootstrap-пользователя, upstream example `Admin`. Установщик очищает email/password, но не обязательно меняет это поле. |
| `BOOTSTRAP_USERS` | Необязательный JSON-массив нескольких пользователей; каждый объект задаёт email/password и опционально name. Имеет приоритет над одиночными `BOOTSTRAP_USER_*` по upstream. Пример: `BOOTSTRAP_USERS=[{"email":"admin@example.com","password":"<strong-password>","name":"Admin"}]`. Не храните production-пароль в публичном файле. |
| `BOOTSTRAP_WARN_PASSWORD_CHANGE` | Показывать ли предупреждение при смене bootstrap password; upstream default `true`. |
| `BOOTSTRAP_DELETE_OTHER_USERS` | Удалять ли пользователей, не перечисленных в bootstrap-конфигурации; upstream default `false`. Не включайте, если есть пользовательские учётные записи, которые не должны удаляться. |
| `BOOTSTRAP_PRESERVE_API_KEYS` | Сохранять ли существующие API keys при пересоздании пользователей; upstream default `true`. |
| `BOOTSTRAP_ONLY_FIRST_RUN` | Выполнять bootstrap только при первом запуске; upstream default `false`. Изменение поведения может повлиять на последующее применение bootstrap-конфигурации. |
| `BOOTSTRAP_DISABLE_REGISTRATION_UI` | Отключить ли регистрацию из UI; upstream default `false`. Рекомендуется оценить при публичном размещении. |
| `BOOTSTRAP_DISABLE_REGISTRATION_SSO` | Отключить ли регистрацию через SSO; upstream default `true`. Это отдельная настройка от регистрации через UI. |
| `EXTRA_TRUSTED_ORIGINS` | Дополнительные доверенные origins Better Auth, разделённые запятыми. Пример: `EXTRA_TRUSTED_ORIGINS=https://mcp.example.com,https://admin.example.com`. Указывайте только контролируемые вами origins. |

#### JSON-ключи внутри `BOOTSTRAP_*`

Значения `BOOTSTRAP_API_KEYS`, `BOOTSTRAP_NAMESPACES`, `BOOTSTRAP_ENDPOINTS` и `BOOTSTRAP_USERS` должны быть корректным JSON в одной строке `.env`. Для длинных значений используйте кавычки/экранирование, совместимые с синтаксисом dotenv и Compose, либо применяйте UI MetaMCP вместо bootstrap. Ключи объектов:

| Объект / ключ | Значение |
|---|---|
| Пользователь (`BOOTSTRAP_USERS`) — `email`, `password` | Обязательные адрес и пароль. |
| Пользователь — `name` | Необязательное отображаемое имя. |
| API key (`BOOTSTRAP_API_KEYS`) — `name` | Обязательное имя ключа. |
| API key — `is_public` | `true` для общего/public key, `false` для пользовательского/private key; default upstream `false`. Public key даёт доступ в пределах конфигурации endpoint, защищайте его как секрет. |
| API key — `user_email` или `owner` | Необязательный email владельца private key; `owner` — alias `user_email`. Если не задан, upstream использует первого пользователя. |
| Namespace (`BOOTSTRAP_NAMESPACES`) — `name` | Обязательное имя namespace. |
| Namespace — `description` | Необязательное описание. |
| Namespace — `is_public` | Public/shared namespace (`true`) или пользовательский (`false`); default upstream `false`. |
| Namespace — `user_email` или `owner` | Необязательный email владельца private namespace; `owner` — alias `user_email`. |
| Namespace — `update` | Обновлять ли существующую namespace с таким именем; upstream default `true`. Установщик меняет буквальное `"update":true` на `"update":false`, чтобы не перезаписывать существующие записи. |
| Endpoint (`BOOTSTRAP_ENDPOINTS`) — `name` | Обязательное имя endpoint. |
| Endpoint — `description` | Необязательное описание. |
| Endpoint — `enable_auth` | Включает API-key auth; upstream default `true`. Не отключайте на публично доступном endpoint. |
| Endpoint — `enable_auth_query` | Разрешает передачу ключа через query string; default `false`, требуется `enable_auth=true`. Query string может попадать в историю/логи, поэтому предпочтительнее Authorization header. |
| Endpoint — `enable_auth_oauth` | Включает OAuth authentication; default `false`. Это отдельная возможность от API-key auth. |
| Endpoint — `is_public` | Public endpoint (`true`) либо принадлежащий пользователю (`false`); default upstream `true`. |
| Endpoint — `user_email` или `owner` | Необязательный владелец private endpoint; `owner` — alias `user_email`. |
| Endpoint — `namespace` | Namespace, в котором создаётся endpoint; если не задан, upstream выбирает первый доступный. Указывайте имя существующего namespace. |
| Endpoint — `update` | Обновлять ли существующий endpoint; upstream default `true`. Установщик меняет буквальное `"update":true` на `"update":false`. |

Параметр `BOOTSTRAP_API_KEYS` в upstream-шаблоне содержит по умолчанию JSON-массив `[{"name":"Public","is_public":true},{"name":"Private","is_public":false}]`; его объекты и ключи описаны в таблице выше. Установщик проекта не меняет этот массив. Bootstrap-конфиг MetaMCP и записи, которые отдельно добавляет `seed-global.sql`, — разные механизмы; сверяйте имена endpoint/namespace, чтобы не создавать конфликты или неосознанно открытые endpoints.

При первом создании MetaMCP `.env` установщик берёт публичный origin из `APP_URL` (или из `NEXT_PUBLIC_APP_URL`, если `APP_URL` пуст) в kit `.env` и записывает его в оба ключа. `APP_URL` — каноническое значение, как ожидает upstream Compose. Если ни один адрес не задан, остаётся default `http://localhost:12008`. Установщик генерирует `BETTER_AUTH_SECRET` и пароль PostgreSQL, очищает bootstrap email/password, устанавливает `BOOTSTRAP_RECREATE_USER=false` и меняет `update:true` на `update:false` у bootstrap namespace/endpoints. Уже существующий MetaMCP `.env` при повторном запуске установщика не изменяется.

При ручном изменении `.env` одного редактирования может быть недостаточно: `run-global.sh start` запускает MetaMCP с `docker compose up -d --no-recreate`, чтобы не уничтожать конфигурацию существующего контейнера. Для применения изменений следуйте процедуре MetaMCP/Compose и заранее сохраните ручные данные контейнера. Не удаляйте контейнер и не запускайте `down -v`, если не хотите потерять данные.

### Linux: переменная запуска

`METAMCP_START_TIMEOUT` — дополнительная переменная окружения, которую `linux/run-global.sh` читает при запуске. Это максимальное ожидание готовности MetaMCP и завершения миграций в секундах; по умолчанию `180`. Пример: `METAMCP_START_TIMEOUT=300 bash linux/run-global.sh start`. Допустимо только целое неотрицательное число. Это переменная окружения процесса, а не параметр, читаемый из `~/mcp-global/config/.env`.

### Windows LOCAL: настройки и секреты

Стандартный путь — `%USERPROFILE%\mcp-local`; `$env:MCP_LOCAL_DIR` задаёт альтернативный путь. Для установки MetaMCP поверх уже настроенных серверов используется `.\windows\install-local.ps1 -MetaMcpOnly`: эта команда не переустанавливает серверные пакеты. Полная установка — `.\windows\install-local.ps1`. Оба варианта запускают MetaMCP в Docker Desktop **на этом Windows-компьютере**, а не подключаются по SSH к Linux.

| Файл / значение | Назначение |
|---|---|
| `config\local-settings.json` | `hostId`, `listenHost`, `port`, `projectsDir`, `writingDir`, `everythingSdkPath`, `obsidianHost`, `obsidianPort` и необязательные TLS-параметры шлюза. Настройки уже существующей установки сохраняются. Для автоматического локального Docker-маршрута нужен IPv4 loopback без TLS: `127.0.0.1`. |
| `config\private\secrets.json` | `gatewayApiKey`, `obsidianApiKey`, `dbhubDsn`. Не отправляйте файл и его содержимое в чат. При изменении Obsidian/DBHub выполните `restart`. |
| `config\private\metamcp.env` | Сгенерированные параметры PostgreSQL и секрет auth; новая установка не содержит автоматически созданного пользователя. Старый файл может содержать прежние bootstrap-данные: он сохраняется, команда `credentials` показывает их только для старой установки. Не удаляйте и не публикуйте файл. Сохранённые при первой установке порт и APP_URL переопределяются действующим состоянием. |
| `config\private\metamcp-state.json` | Идентификатор Compose-проекта, путь клона, действующие порты и при необходимости последний явно выбранный администратор. Public-группы не имеют владельца. Храните вместе с секретами и PostgreSQL volume; используйте команды `set-ports` и `seed`, а не редактируйте файл вручную. |
| `$env:MCPKIT_METAMCP_PORT`, `$env:MCPKIT_METAMCP_BACKEND_PORT` | Порты Windows только при **первой** настройке; по умолчанию `13008` и `13009`. `MCPKIT_METAMCP_BACKEND_PORT=0` не публикует backend. Для существующей установки используйте `set-ports`. |
| `$env:MCPKIT_DOCKER_START_TIMEOUT`, `$env:MCPKIT_METAMCP_START_TIMEOUT` | Необязательные таймауты запуска Docker Desktop и MetaMCP в секундах. |

Старые `config\.env` и `config\mcp-local.json` не изменяются. При первом создании `local-settings.json` существующие валидные `PROJECTS_DIR`, `WRITING_DIR`, `DBHUB_DSN` и `OBSIDIAN_API_KEY` читаются из старого `.env` буквально; дальнейшие изменения старых файлов не обновляют действующие настройки. JSON-пути Windows должны содержать удвоенные обратные слеши.

Проверить и изменить порты существующей установки:

```powershell
.\windows\run-local.ps1 ports
.\windows\run-local.ps1 set-ports -WebPort 13008 -BackendPort 13009
```

Frontend обслуживает UI и MCP endpoint; backend напрямую доступен только на loopback и не нужен для обычного подключения. Чтобы его не публиковать, укажите `-BackendPort 0`. Порты внутри контейнера остаются 12008/12009. `port` в `local-settings.json` — отдельный порт шлюза Windows, а не MetaMCP.

Установщик клонирует закреплённую версию upstream MetaMCP и собирает её в отдельный образ; существующий посторонний каталог `metamcp` не используется и не меняется. Отдельный Compose-проект хранит PostgreSQL и кэш в собственных volumes. Обычный `start` применяет `--no-recreate`, `stop` не удаляет контейнеры и volumes. Для изменения портов, обновления старой bootstrap-конфигурации или добавления администратора требуется пересоздать только app-контейнер: скрипт сохраняет его записываемый слой в локальном Docker-образе и запускает новый контейнер из него. Образ может содержать секреты; не публикуйте его. База, volumes и существующие пароли не изменяются. Если изменение не удалось, оно остаётся ожидающим и повторяется при `start`. UI и backend доступны только через `127.0.0.1`, PostgreSQL не публикуется.

При первом `start` автоматически создаются 13 public-серверов с короткими именами, например `filesystem` и `git`, и public namespace/endpoints `local-<hostId>-{system,files,code,web,data,memory}` с разделением по темам и точными именами серверов из README. Для этого учётная запись не нужна. Все новые endpoints требуют API key и остаются на loopback: public означает видимость всем пользователям MetaMCP, а не анонимный или сетевой доступ. Любой ключ с доступом к public endpoint позволяет вызывать его инструменты; не выдавайте его недоверенным пользователям. Скрипт выводит фактические URL `/metamcp/<endpoint>/mcp`; SSE доступен по `/sse`.

Учётную запись пользователь создаёт в UI самостоятельно. Upstream bootstrap отключён, поэтому он не создаёт пользователей и не сбрасывает выбранную в UI настройку регистрации при перезапуске. В **Настройки → Настройки авторизации** вручную отключите регистрацию через форму и при необходимости через SSO; в **API Keys** самостоятельно создайте личный ключ. Ключ Windows-шлюза не совпадает с клиентским ключом MetaMCP. При пустом списке администраторов upstream считает администратором любого вошедшего пользователя; закройте регистрацию сразу после создания нужных учётных записей.

На старой установке `start` отключает ещё действующий bootstrap без изменения состояния регистрации и учётных записей. Если регистрация закрыта, её можно явно открыть командой `enable-signup`. Миграция V3 переиспользует старые серверы V1 и устраняет совместимые дубликаты V2, по возможности сохраняя UUID, подключения, mappings, настройки инструментов, OAuth-сессию и аудит. Старый endpoint и namespace остаются с прежними UUID и URL и безопасно переводятся в public; при конфликтах или дополнительных чужих серверах перевод откладывается. Различающиеся соединения, tool schemas и ограничения, несколько OAuth-сессий, чужие имена и неизвестные ссылки БД не удаляются автоматически; выводится предупреждение, и соответствующие дубликаты могут остаться до ручного разрешения конфликта. Если в целевом namespace есть открытый endpoint, новые инструменты туда не добавляются; уже существующие mappings могут быть доступны без ключа. Чужой или заменённый namespace не используется даже по явной команде `seed`.

Для применения миграции и при каждом явном `seed` скрипт останавливает только app, делает `pg_dump` в `mcpkit-backups` внутри PostgreSQL volume и запускает тот же app-контейнер: это сбрасывает старые активные и подготовленные MCP-сессии без пересоздания контейнера. Дамп содержит секреты и не является независимой копией volume — храните отдельный защищённый backup. При ошибке backup миграция БД не применяется. Переименование меняет имена MCP-инструментов (например, на `filesystem__...`), даже если URL старого endpoint тот же: переподключите клиентов и обновите их allowlist. Повторный обычный `start` не делает новый дамп и не восстанавливает удалённые записи. Явный `seed` после проверки предупреждений может восстановить удалённые defaults, но не перезаписывает существующие настройки или отключённые mappings.

Отдельная команда `reset-metamcp-records` по подтверждению `DELETE ALL LOCAL RECORDS` удаляет **все** серверы, namespaces и endpoints этой Windows-базы, включая ручные, и в той же транзакции создаёт 13 серверов и шесть защищённых групп. Удаляются их настройки инструментов, mappings и серверные OAuth-сессии; ссылки аудита на удалённые записи очищаются. Учётные записи, MetaMCP API keys, регистрация, файлы Windows-серверов, другие базы и volumes сохраняются. Перед сбросом создайте независимую защищённую копию; автоматический `pg_dump` внутри того же volume содержит секреты и не является такой копией. При неизвестных внешних ссылках или триггерах сброс блокируется. Он не вызывается при обычном `start` или `seed`; повторный явный вызов снова удалит записи. При неопределённом результате или ошибке перезапуска не повторяйте сброс вслепую — запустите `start` и проверьте MetaMCP и backup.

В обычном случае `-OwnerEmail` не нужен даже при нескольких учётных записях. Если на старой установке есть список администраторов и новому пользователю нужны права администратора, после регистрации и проверки предупреждений используйте `seed -OwnerEmail 'you@example.com'`: эта команда одновременно выполняет явный `seed` и добавляет выбранного существующего пользователя к прежнему списку администраторов. Данные и права Docker, ACL Windows и резервные копии БД необходимо защищать: серверы могут выполнять команды, управлять рабочим столом и изменять файлы.

Команды: `start`, `stop`, `restart`, `status`, `logs [имя]`, `seed [-OwnerEmail email]`, `reset-metamcp-records` (явный полный сброс с подтверждением), `enable-signup`, `ports`, `set-ports`; `credentials` оставлена только для получения исходного пароля старой учётной записи. Логи MetaMCP: `logs metamcp`; логи отдельного сервера: `logs codebase-memory-mcp`. Docker Desktop должен быть в режиме Linux containers; связь `host.docker.internal` со шлюзом проверяется при запуске, но без изменения firewall или расширения listener на LAN.

## `linux/services/docker-compose.yml`

Это Compose-описание четырёх sidecar-контейнеров набора. Оно настраивается через `~/mcp-global/config/.env` и `linux/run-global.sh`, а не через `.env` MetaMCP. `MCPKIT_*` — промежуточные переменные окружения, которые формирует `run-global.sh`; вручную задавать их обычно не нужно. Внутренние переменные `MCPKIT_*` соответствуют глобальным `LLM_API_*`, сервисным `MCPKIT_GRAPHITI_API_*`, `MCPKIT_COGNEE_LLM_API_*`, `MCPKIT_COGNEE_EMBEDDING_API_*` и дополнительным настройкам Neo4j, Graphiti и размерности embeddings. Их значения и соответствия переменным контейнеров указаны в таблицах Linux `.env` выше.

| Сервис | Внутренний адрес, используемый MetaMCP | Настройки контейнера |
|---|---|---|
| `mcpkit-graphiti` | `http://mcpkit-graphiti:8000/mcp` | `NEO4J_URI`, `NEO4J_USER`, `NEO4J_PASSWORD`, `NEO4J_DATABASE`; `OPENAI_API_KEY`, `OPENAI_BASE_URL`; `MODEL_NAME`, `EMBEDDER_MODEL`, `GRAPHITI_GROUP_ID`. API settings берутся из непустых `GRAPHITI_API_*`, иначе из `LLM_API_*`. Без итогового API key сервер ждёт настройки. |
| `mcpkit-cognee` | `http://mcpkit-cognee:8000/mcp` | `TRANSPORT_MODE=http`; `MCP_ALLOWED_HOSTS=mcpkit-cognee:*`; `LLM_PROVIDER`, `LLM_API_KEY`, `LLM_MODEL`, `LLM_ENDPOINT`; `EMBEDDING_PROVIDER`, `EMBEDDING_API_KEY`, `EMBEDDING_ENDPOINT`, `EMBEDDING_MODEL`, `EMBEDDING_DIMENSIONS`; каталоги данных фиксированы как `/cognee-storage/system` и `/cognee-storage/data`. Непустые `COGNEE_*_API_*` переопределяют глобальные API defaults. |
| `mcpkit-memory-bank` | `http://mcpkit-memory-bank:8000/mcp` | `MEMORY_BANK_ROOT=/mcpkit/memory`; данные хранятся в volume `multfinite-mcp-kit-global-memory-data`. `mcp-proxy` принимает Streamable HTTP на порту 8000 внутри Docker-сети. |
| `mcpkit-gdrive` | `http://mcpkit-gdrive:8000/mcp` | `GDRIVE_CREDENTIALS_PATH=/mcpkit/gdrive/credentials.json`; контейнер ждёт OAuth-файл в volume `multfinite-mcp-kit-global-gdrive-data`. Получение credentials описано в README. |

Compose объявляет изолированные Docker-сети `multfinite-mcp-kit-global-{graphiti,cognee,memory,gdrive}` и volumes для Cognee, GDrive и Memory Bank. Порты sidecar на хост не публикуются. Не меняйте имена сетей/volumes без одновременного изменения seed URL и скрипта подключения MetaMCP. Официальные env-названия контейнеров и внутренние фиксированные параметры относятся к реализации Compose; основные пользовательские параметры находятся в таблице Linux `.env`.

## Прочие настройки

- `linux/seed-global.sql` задаёт серверы, их тип подключения, команды/аргументы, URL, namespace, endpoint и auth defaults. Эти настройки не являются `.env`-переменными. Имена серверов допускают латиницу, цифры, `_` и `-` (поэтому `io.draw` называется `io-draw`). Группы и endpoint URL приведены в основном README.
- Новые endpoints защищены API-key authentication. API keys создаются в UI MetaMCP, затем настраиваются в MCP-клиенте как `Authorization: Bearer <key>` или `X-API-Key: <key>`. Sidecar HTTP-сервисы сами по себе не проверяют этот ключ.
- `linux/run-global.sh` принимает команды `start`, `stop`, `restart`, `status`, `logs`, `services-logs`, `seed`, `apply-services`, `apply-metamcp-config`. Это аргументы запуска, а не ключи конфигурации.
- Linux использует фиксированный базовый путь `${HOME}/mcp-global/{config,data,metamcp}`. Windows по умолчанию использует `$env:USERPROFILE\mcp-local` и поддерживает переопределение через `$env:MCP_LOCAL_DIR`. Это переменная среды PowerShell, а не настройка Linux `.env`.
- Если исполняемый файл Docker отсутствует, Linux-инсталлятор устанавливает официальный Engine и Compose plugin и при необходимости добавляет текущего пользователя в группу `docker`. Группа даёт права, эквивалентные администраторским; после изменения членства может потребоваться новый вход. Уже установленный Docker, существующие APT-репозитории и keyrings не заменяются; если daemon недоступен или plugin отсутствует при наличии Docker, установщик сообщает об этом и не переустанавливает Docker.
- Linux-инсталлятор задаёт фиксированные имена контейнеров `neo4j-mcp` и `qdrant-mcp`, публикует Neo4j на `7474`/`7687`, Qdrant на `6333`/`6334`, включает Neo4j plugin `apoc` и хранит их данные в `~/mcp-global/data/{neo4j,qdrant}`. Эти параметры не настраиваются переменными `.env`; изменение портов, образов или mount-путей требует редактирования `linux/install-global.sh` и соответствующей сетевой конфигурации. Пароль нового Neo4j контейнера — исключение, он читается из `NEO4J_PASSWORD`.
- Linux GLOBAL по умолчанию использует `http://localhost:12008`; его run-скрипт проверяет health на внутреннем порту `12008`. При изменении публичного адреса согласуйте Compose, `APP_URL`, `NEXT_PUBLIC_APP_URL` и URL клиентов. Windows LOCAL использует отдельную команду `set-ports`, описанную выше.
- `TEST_DATABASE_URL` используется только интеграционными тестами seed/reset (`tests/test-global-seed.sh`, `tests/test-local-seed.sh`, `tests/test-windows-seed.sh`, `tests/test-windows-reset.sh`) и должен указывать на отдельную тестовую PostgreSQL БД, в которой можно создавать и удалять схемы. Пример: `TEST_DATABASE_URL='postgresql://user:password@localhost:5432/test_db' bash tests/test-windows-reset.sh`. Не используйте production БД.

## Где применять изменения

- Linux API-ключи и параметры sidecar: `~/mcp-global/config/.env`; для Graphiti/Cognee выполнить `bash linux/run-global.sh apply-services`.
- Настройки существующих записей GitHub, Context7, Neo4j и Qdrant: менять через UI MetaMCP. `start` не перезаписывает существующие записи; `seed` добавляет отсутствующие по правилам README.
- Публичный URL MetaMCP: задайте `APP_URL` / `NEXT_PUBLIC_APP_URL` в `~/mcp-global/config/.env` и выполните `bash linux/run-global.sh apply-metamcp-config`. Секрет auth и параметры PostgreSQL настраиваются в `~/mcp-global/metamcp/.env` согласно правилам upstream; заранее сохраните ручные файлы из writable layer перед пересозданием app.
- Windows: для имеющихся серверов выполнить `install-local.ps1 -MetaMcpOnly`; настройки каталогов — в `config\local-settings.json`, ключ Obsidian и DSN DBHub — в `config\private\secrets.json`. После изменений выполнить `restart`. Старые `.env` и `mcp-local.json` автоматически не обновляют действующие настройки.
- Установщик Linux задаёт права `600` созданным `.env`; на Windows проверьте ACL профиля пользователя. Не помещайте пароли/API-ключи в Git, публичный JSON, скриншоты, логи или команды, сохраняемые в shell history.
