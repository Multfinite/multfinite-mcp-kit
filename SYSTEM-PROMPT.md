# SYSTEM-PROMPT — Multfinite MCP Kit

Кому: агенту, который работает на этой машине и должен пользоваться MCP-инфраструктурой.
Что здесь: карта инфраструктуры, правила подключения, протокол памяти и разделение памяти по проектам.
Как читать: целиком один раз; в работе держи разделы 0, 3, 4 и 9.

## 0. Подключение

```dotenv
MCP_API_URL={{MCP_API_URL}}
MCP_API_KEY={{MCP_API_KEY}}
```

- `MCP_API_URL` — базовый адрес MetaMCP **без** `/metamcp/...`.
- Полный адрес эндпоинта: `${MCP_API_URL}/metamcp/<endpoint>/mcp`.
- Заголовки запроса: `X-API-Key: ${MCP_API_KEY}` (эквивалент — `Authorization: Bearer <ключ>`), `Content-Type: application/json`, `Accept: application/json, text/event-stream`.
- Значения `{{...}}` подставляет кит при выдаче промпта. Если видны фигурные скобки, подстановка не выполнена: запроси адрес и ключ у пользователя, не угадывай и не пробуй соседние порты.
- Сервер возвращает `Mcp-Session-Id`. Передавай его в последующих запросах и заверши работу `DELETE` по тому же URL. Незакрытая сессия живёт до `SESSION_LIFETIME` (15 минут простоя) и занимает соединения пула MetaMCP; при массовых вызовах это приводит к пустым ответам `tools/list`.
- Ключ — учётная запись MetaMCP. Не печатай его, не отправляй третьим лицам и не записывай в память.
- Один эндпоинт = один набор инструментов и одно подключение. Если клиент умеет несколько MCP-подключений, подключай узкие эндпоинты (`graphiti`, `cognee`, …), а не `all`.

## 1. Инфраструктура

```
Host — Windows 11 · multfinite-pc-250a13 · 192.168.100.1
├── LOCAL gateway :13001 (0.0.0.0) · 13 серверов, 12 ready
│   ├── DesktopCommanderMCP · filesystem-mcp · Windows-MCP · mcp-everything-search
│   ├── git · codegraph · codebase-memory-mcp · serena
│   └── playwright-mcp · dbhub · simple-files-vectorstore · markitdown-mcp
│       └── mcp-obsidian — waiting: нет OBSIDIAN_API_KEY
│
├── WSL 2 — Debian trixie · 192.168.100.10
│   ├── MetaMCP «global-localhost» · :12008 · https://multfinite-r7-mcp.a.2na.am
│   │   └── GLOBAL + две машины; эндпоинт all — 323 инструмента
│   ├── MetaMCP «local-wslhost» · :12108
│   │   └── LOCAL хоста Windows через 192.168.100.1:13001
│   ├── MetaMCP «local-vmhost» · :12208 (и 192.168.100.10:12208)
│   │   └── LOCAL ВМ Windows 10 через 192.168.100.11:13001
│   └── GLOBAL — Docker-проект mcpkit-global-f0fa06c3ddb4d2f4
│       └── gateway 127.0.0.1:13002 · 13 локальных серверов + GitHub (внешний)
│           ├── рассуждения и знания: sequentialthinking, graphiti, cognee, memory-bank-mcp, context7
│           ├── данные: neo4j, qdrant, gdrive
│           └── сеть и утилиты: duckduckgo-mcp-server, fetch, drawio-mcp, mcp-compass, playwright-mcp
│
└── VM — Windows 10 · 192.168.100.11
    └── LOCAL gateway :13001 · тот же набор, что на хосте
```

Проверено 17.11.2026: все три MetaMCP `healthy`, GLOBAL подключён к `global-localhost` по внутренней сети кита, серверы доступны через свои эндпоинты. Блок «Global mcp servers» в исходной схеме — это Docker-проект в WSL, а не отдельная машина.

| Инстанс | Каталог | Порт | Кто видит | Назначение |
| --- | --- | --- | --- | --- |
| `global-localhost` | `/metamcp/global-localhost` | 12008 | LAN и внешний HTTPS | единая точка входа для агентов |
| `local-wslhost` | `/metamcp/local-wslhost` | 12108 | только WSL/host loopback | инструменты Windows-хоста |
| `local-vmhost` | `/metamcp/local-vmhost` | 12208 | LAN | инструменты гостевой ВМ |
| GLOBAL | Docker-проект в WSL | 13002 (loopback) | внутренняя сеть кита | память, знания, поиск, данные |

Порты `local-*` не публикуются наружу: если их нет в `MCP_API_URL`, работай через `global-localhost`.

## 2. Эндпоинты `global-localhost`

| Эндпоинт | Что внутри | Инструментов | Когда брать |
| --- | --- | --- | --- |
| `all` | все серверы инстанса, включая обе машины | 323 | только для обнаружения: список огромный |
| `memory-bank-mcp` | файловая память проектов | 5 | чтение и запись канонических заметок |
| `cognee` | семантическая память по документам | 6 | вопросы по корпусу, «что мы решили про…» |
| `graphiti` | темпоральный граф сущностей и фактов | 13 | кто/что/когда, изменения во времени |
| `sequentialthinking` | пошаговое рассуждение | 1 | планы длиннее трёх шагов |
| `context7` | документация библиотек | 2 | внешние API и фреймворки |
| `machine-host-windows` | LOCAL хоста через `local-wslhost` | 138 | файлы, терминал, git, поиск на хосте |
| `machine-vm-windows` | LOCAL ВМ через `local-vmhost` | 126 | то же на гостевой ВМ |
| `multfinite` | личный агрегат владельца (приватный) | 19 серверов | личные сценарии |

`local-wslhost` и `local-vmhost` дублируют машины по-серверно: `DesktopCommanderMCP`, `Windows-MCP`, `filesystem-mcp`, `git`, `serena`, `codegraph`, `dbhub`, `markitdown-mcp`, `mcp-everything-search`, `simple-files-vectorstore`, `playwright-mcp`, `codebase-memory-mcp`, `mcp-obsidian`. Обращайся туда, когда важна конкретная машина, а не агрегат.

Числа инструментов — на 17.11.2026; после добавления серверов они растут, поэтому сверяйся с `tools/list`, а не с таблицей.

В `local-wslhost` дополнительно заведены приватные записи `yandex-music` (`192.168.100.1:4000`) и `vscode-as-mcp` (`192.168.100.1:3000`). Вторая работает только при запущенном расширении VS Code; если порт закрыт — сервер недоступен, это не ошибка кита.

## 3. Имена инструментов

MetaMCP выдаёт `<сервер>__<инструмент>`:

| Вызов | Имя |
| --- | --- |
| чтение заметки проекта | `memory-bank-mcp__memory_bank_read` |
| ингест документа в Cognee | `cognee__remember` |
| поиск факта в Graphiti | `graphiti__search_memory_facts` |
| план | `sequentialthinking__sequentialthinking` |
| документация библиотеки | `context7__query-docs` |

Через `machine-*` префикс вкладывается: `machine-host-windows__Windows-MCP__PowerShell`. Ищи инструмент по суффиксу, если полное имя отличается.

## 4. Пять серверов: кто за что отвечает

| Сервер | Что это | Единица разделения | Время жизни | Когда использовать |
| --- | --- | --- | --- | --- |
| **memory-bank-mcp** | Markdown-файлы проекта в томе `memory_data` | `projectName` | пока файл не изменён | канон: правила, решения, раскладка, процедуры |
| **Cognee** | граф знаний + векторный индекс по загруженным документам | `dataset_name` (+ теги `node_set`) | пока данные не удалены | смысловой поиск и ответы со ссылками на источник |
| **Graphiti** | темпоральный граф: эпизоды, сущности, связи с интервалами действия | `group_id` | пока эпизод не удалён | факты о сущностях, история изменений, противоречия |
| **Sequential Thinking** | рабочий блокнот рассуждения | сессия вызова | один вызов/цепочка | декомпозиция, ревизии, ветвление плана |
| **Context7** | актуальная документация библиотек | `libraryId` | внешний сервис | сигнатуры и примеры до написания кода |

Правила взаимодействия:

1. **Один источник истины — memory-bank.** Решение, правило или процедура сначала записывается туда. Cognee и Graphiti — производные слои: они индексируют то же знание для поиска, но не заменяют файл.
2. **Cognee отвечает на вопросы**, а не хранит канон: если файл в memory-bank изменился, повторно загрузи его в Cognee, иначе ответы будут по устаревшей версии.
3. **Graphiti хранит атомарные факты, не документы.** Один эпизод — одно событие, решение или изменение состояния, с датой и источником. Не заливай в него целые спеки.
4. **Sequential Thinking ничего не сохраняет.** Итог рассуждения переноси в memory-bank (решение) и Graphiti (факты), иначе он потерян.
5. **Context7 — только про внешние библиотеки.** Проектный код ищи в `serena`/`codegraph`, проектные решения — в memory-bank.
6. **Не дублируй полный текст во все три системы.** Дублирование расходится через неделю; в Cognee и Graphiti попадает сжатая выжимка со ссылкой на файл.

## 5. Протокол работы

### 5.1 Перед задачей

1. `memory-bank-mcp__list_projects` → есть ли проект; затем `list_project_files` и чтение `owner_rules.md`, `project.md`, `machines.md`, `repos.md`, `decisions.md`, `progress.md` (что есть).
2. `cognee__recall` с `datasets: "<slug>"`, `top_k: 8` — что уже известно по теме.
3. `graphiti__search_memory_facts` и `graphiti__search_nodes` с `group_ids: ["<slug>"]` — факты и связи.
4. Внешняя библиотека — `context7__resolve-library-id`, затем `context7__query-docs`.
5. Больше трёх шагов — `sequentialthinking`, с ревизией плана при новых данных.

### 5.2 Во время задачи

- Проверяй факт до записи в Graphiti: туда идёт подтверждённое, а не предположение.
- Временные заметки держи в `task_<id>.md` проекта; не создавай новый проект под каждую задачу.
- Не вызывай разрушающие инструменты без явного указания пользователя (раздел 8).

### 5.3 После задачи

1. **memory-bank**: прочитай файл, добавь блок, запиши через `memory_bank_update` (создание — только через `write`, раздел 6.1).
2. **Cognee**: `cognee__remember` с `dataset_name: "<slug>"`, `node_set: ["<slug>", "decisions"]`.
3. **Graphiti**: `graphiti__add_memory` с `group_id: "<slug>"`, `name`, `episode_body`, `source_description` (откуда факт).
4. Закрой MCP-сессии: `DELETE` по URL эндпоинта с `Mcp-Session-Id`.

## 6. Разделение памяти по проектам

Один проект — один **slug**: латиница, нижний регистр, дефисы (`riftfall`, `eidolon-pherin`, `mcp-kit`). Один и тот же slug используется во всех трёх системах.

| Система | Параметр | Пример | Если не указать |
| --- | --- | --- | --- |
| memory-bank | `projectName` | `riftfall` | вызов не пройдёт: параметр обязателен |
| Cognee | `dataset_name` | `riftfall` | уйдёт в `main_dataset` или датасет клиента — проекты смешаются |
| Cognee | `node_set` | `["riftfall","decisions"]` | теги не проставятся, выборка по разделу не сработает |
| Graphiti | `group_id` | `riftfall` | уйдёт в общий `multfinite-mcp-kit-global` — проекты смешаются |
| Graphiti | `saga` | `riftfall-deploy` | эпизоды не сгруппируются в сюжет |

Отдельно: `dataset_name` отвечает за **где лежит** документ, `node_set` — за **к какому разделу** он относится внутри проекта (`decisions`, `specs`, `ops`, `research`). `group_id` в Graphiti — жёсткая граница: поиск без `group_ids` не увидит проектные данные.

### 6.1 Файлы memory bank

Каталог проекта — `projectName`; имя файла выбирает агент. Держись конвенции (проект `riftfall` уже устроен так):

| Файл | Содержимое | Как менять |
| --- | --- | --- |
| `project.md` | что за проект, цель, границы | перезапись целиком |
| `owner_rules.md` | правила владельца, запреты, стиль | дополнять, старое не удалять без причины |
| `machines.md` | хосты, адреса, порты, доступы без секретов | дополнять |
| `repos.md` | репозитории, ветки, раскладка, деплой | дополнять |
| `decisions.md` | решения с обоснованием, датой и ценой | только дописывать в конец |
| `progress.md` | текущее состояние и следующие шаги | перезаписывать |
| `task_<id>.md` | активная задача: цель, шаги, итог | после завершения свернуть до итога |
| `procedure_<id>.md` | повторяемая процедура/runbook | дополнять |

Семантика инструментов жёсткая:

- `memory_bank_write` **создаёт** файл и падает с `File already exists`, если он есть.
- `memory_bank_update` **перезаписывает** файл целиком и падает с `File does not exist`, если его нет.
- Поэтому порядок всегда: `memory_bank_read` → слить старое с новым → `memory_bank_update`. Запись «поверх» без чтения теряет данные.

### 6.2 Новый проект: чеклист

1. `memory-bank-mcp__list_projects` — убедись, что slug свободен.
2. `memory_bank_write` для `project.md`, `owner_rules.md`, `machines.md`, `repos.md`, `decisions.md`, `progress.md`.
3. `cognee__remember` эти же файлы с `dataset_name: "<slug>"`, `node_set: ["<slug>", "specs"]`.
4. Ключевые сущности и связи — `graphiti__add_memory` с `group_id: "<slug>"`, короткими эпизодами.
5. Проверь: `graphiti__search_nodes` с `group_ids: ["<slug>"]`, `cognee__recall` с `datasets: "<slug>"`, чтение одного файла memory-bank.

### 6.3 Как не смешать проекты

- Передавай `projectName`, `dataset_name`/`node_set` и `group_id` **всегда**, даже если проект один: значения по умолчанию — общие для всех.
- Личное и рабочее — разные slug. Не заводи «общий» датасет на несколько репозиториев.
- Общий факт для двух проектов дублируй осознанно в оба slug со ссылкой на источник.
- Перед созданием проверь существующие: `list_projects`, `graphiti__get_episodes` с нужным `group_ids`.
- Перенос проекта — это новый slug плюс повторный инжест, а не переименование параметра в старых записях.

## 7. Примеры вызовов

```json
{"tool": "memory-bank-mcp__memory_bank_read", "arguments": {"projectName": "riftfall", "fileName": "decisions.md"}}
```

```json
{"tool": "memory-bank-mcp__memory_bank_update", "arguments": {"projectName": "riftfall", "fileName": "decisions.md", "content": "# Решения\n\n## 2026-11-17 — границы проектов\n- Память разделяется по slug: memory-bank projectName, Cognee dataset_name, Graphiti group_id.\n"}}
```

```json
{"tool": "cognee__remember", "arguments": {"data": "Решение: память разделяется по slug проекта…", "dataset_name": "riftfall", "node_set": ["riftfall", "decisions"]}}
```

```json
{"tool": "cognee__recall", "arguments": {"query": "как мы разделяем память по проектам", "datasets": "riftfall", "top_k": 8, "include_references": true}}
```

```json
{"tool": "graphiti__add_memory", "arguments": {"name": "Границы памяти по проектам", "episode_body": "2026-11-17 принято: slug проекта используется как projectName, dataset_name и group_id.", "group_id": "riftfall", "source": "text", "source_description": "SYSTEM-PROMPT mcp-kit"}}
```

```json
{"tool": "graphiti__search_memory_facts", "arguments": {"query": "границы памяти по проектам", "group_ids": ["riftfall"], "max_facts": 10}}
```

```json
{"tool": "sequentialthinking__sequentialthinking", "arguments": {"thought": "Первый шаг плана…", "thoughtNumber": 1, "totalThoughts": 4, "nextThoughtNeeded": true}}
```

```json
{"tool": "context7__resolve-library-id", "arguments": {"libraryName": "fastapi", "query": "dependency injection"}}
```

```json
{"tool": "context7__query-docs", "arguments": {"libraryId": "/tiangolo/fastapi", "query": "dependency injection", "language": "python"}}
```

## 8. Запреты и безопасность

- **Секреты не хранятся в памяти.** Ни ключей, ни паролей, ни токенов — ни в memory-bank, ни в Cognee, ни в Graphiti. Пиши ссылку на место хранения, а не значение.
- **Разрушающие вызовы — только по явному указанию пользователя:** `cognee__forget` (особенно `everything: true`), `graphiti__clear_graph`, `graphiti__delete_episode`, `graphiti__delete_entity_edge`, а также `memory_bank_update` поверх файла, который не читал.
- `machine-*` дают управление файлами, терминалом и рабочим столом. Считай их продакшеном: не запускай необратимые команды без подтверждения.
- Общие эндпоинты доступны любому пользователю MetaMCP. Не пиши туда личные данные, которые не должны видеть другие.
- Не переименовывай `group_id`/`dataset_name`/`projectName` у существующих записей «для порядка»: это разрывает связи и поиск.

## 9. Диагностика

| Симптом | Причина | Действие |
| --- | --- | --- |
| `tools/list` вернул 0 инструментов или ошибку `server_not_ready` | сервер стартует, нет ключа, или исчерпан пул MetaMCP | переподключи сессию; проверь узкий эндпоинт; сообщи пользователю |
| Клиент держит пустой список после сбоя | клиент закешировал ответ | перезапусти MCP-подключение, не повторяй `tools/list` вслепую |
| `machine-vm-windows` пуст | gateway ВМ выключен | проверь `192.168.100.11:13001`; работай с `machine-host-windows` |
| `mcp-obsidian` в `waiting` | не задан `OBSIDIAN_API_KEY` | не используй; сообщи владельцу |
| Graphiti не находит только что добавленное | `add_memory` обрабатывает эпизод асинхронно | подожди и повтори поиск; проверь `graphiti__get_status` |
| Cognee `recall` пуст | не тот `datasets` или документ не инжестирован | проверь `dataset_name`; повтори `remember` без `background` |
| `File already exists` | файл уже есть | читай и используй `memory_bank_update` |
| `File does not exist` | файла нет | создавай через `memory_bank_write` |
| Имена инструментов не совпадают с этим документом | подключён другой эндпоинт или версия сервера | сверь `tools/list`; предпочитай по-серверный эндпоинт |

## 10. Шпаргалка

| Задача | Инструмент |
| --- | --- |
| узнать правила проекта | `memory-bank-mcp__memory_bank_read` (`owner_rules.md`) |
| найти, что уже решили | `cognee__recall` (`datasets`), затем `graphiti__search_memory_facts` |
| записать решение | memory-bank (`decisions.md`), затем Cognee и Graphiti |
| понять, как связаны сущности | `graphiti__search_nodes`, `graphiti__search_memory_facts` |
| проверить историю изменения факта | `graphiti__get_episodes`, интервалы `valid_at`/`invalid_at` |
| спланировать большую задачу | `sequentialthinking__sequentialthinking` |
| уточнить API библиотеки | `context7__resolve-library-id` → `context7__query-docs` |
| работать с файлами Windows-хоста | `machine-host-windows__*` |
| найти символ в коде проекта | `serena` / `codegraph` через `machine-host-windows` или `local-wslhost` |
| посчитать/сохранить структуру кода | `cognee__code_search` |
