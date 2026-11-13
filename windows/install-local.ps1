#Requires -Version 5.1
<#
.SYNOPSIS
    Установка локальных MCP-зависимостей на Windows.
    Запускать в PowerShell от имени пользователя (не обязательно админ).

.DESCRIPTION
    Ставит: Node.js, Python, uv, Git, Playwright, Everything, LSP-серверы.
    Кэширует все локальные MCP-серверы (npx/uvx).
    Создаёт шаблон конфига и .env.

.EXAMPLE
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    .\install-local.ps1
#>

$ErrorActionPreference = "Stop"

# ── Утилиты ──────────────────────────────────────────────────────────────────
function Write-Step  { param($msg) Write-Host "`n▸ $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Skip  { param($msg) Write-Host "  · $msg (уже есть)" -ForegroundColor DarkGray }
function Write-Warn  { param($msg) Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "  ✗ $msg" -ForegroundColor Red }

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$machinePath;$userPath"
}

function Test-Command {
    param([string]$cmd)
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Winget-Install {
    param([string]$Id, [string]$Name)
    if (Test-Command $Name) {
        Write-Skip "$Name"
        return
    }
    Write-Host "  → Установка $Name ($Id)..." -ForegroundColor DarkCyan
    winget install --id $Id `
        --accept-source-agreements `
        --accept-package-agreements `
        --silent 2>&1 | Out-Null
    Refresh-Path
    if (Test-Command $Name) {
        Write-Ok "$Name установлен"
    } else {
        Write-Warn "$Name установлен, но не в PATH. Перезапустите терминал."
    }
}

# ── Базовый путь ─────────────────────────────────────────────────────────────
$BaseDir   = "$env:USERPROFILE\mcp-local"
$ConfigDir = "$BaseDir\config"
$DataDir   = "$BaseDir\data"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Локальные MCP — установка зависимостей        ║" -ForegroundColor Cyan
Write-Host "║   Windows · Host / VM                           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── 0. Проверка winget ───────────────────────────────────────────────────────
Write-Step "Проверка winget..."

if (-not (Test-Command "winget")) {
    Write-Fail "winget не найден."
    Write-Host "  Установите App Installer из Microsoft Store:" -ForegroundColor Yellow
    Write-Host "  https://apps.microsoft.com/detail/9NBLGGH4NNS1" -ForegroundColor Yellow
    exit 1
}
Write-Ok "winget $(winget --version)"

# ── 1. Git ───────────────────────────────────────────────────────────────────
Write-Step "Git..."
Winget-Install -Id "Git.Git" -Name "git"

# ── 2. Node.js 20+ ──────────────────────────────────────────────────────────
Write-Step "Node.js..."

if (Test-Command "node") {
    $nodeVer = (node -v).TrimStart("v")
    $nodeMajor = [int]($nodeVer.Split(".")[0])
    if ($nodeMajor -ge 20) {
        Write-Skip "Node.js v$nodeVer"
    } else {
        Write-Warn "Node.js v$nodeVer < 20, обновление..."
        Winget-Install -Id "OpenJS.NodeJS.LTS" -Name "node"
    }
} else {
    Winget-Install -Id "OpenJS.NodeJS.LTS" -Name "node"
}

# ── 3. Python 3.11+ ─────────────────────────────────────────────────────────
Write-Step "Python..."

if (Test-Command "python") {
    $pyVer = (python --version 2>&1) -replace "Python ", ""
    $pyParts = $pyVer.Split(".")
    if ([int]$pyParts[0] -ge 3 -and [int]$pyParts[1] -ge 11) {
        Write-Skip "Python $pyVer"
    } else {
        Write-Warn "Python $pyVer < 3.11, обновление..."
        Winget-Install -Id "Python.Python.3.12" -Name "python"
    }
} else {
    Winget-Install -Id "Python.Python.3.12" -Name "python"
}

# ── 4. uv ────────────────────────────────────────────────────────────────────
Write-Step "uv..."

Refresh-Path
if (Test-Command "uv") {
    Write-Skip "uv $(uv --version)"
} else {
    Write-Host "  → Установка uv..." -ForegroundColor DarkCyan
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex" 2>&1 | Out-Null
    Refresh-Path
    # uv ставится в %USERPROFILE%\.local\bin или %USERPROFILE%\.cargo\bin
    $uvPaths = @(
        "$env:USERPROFILE\.local\bin",
        "$env:USERPROFILE\.cargo\bin"
    )
    foreach ($p in $uvPaths) {
        if (Test-Path "$p\uv.exe") {
            $env:Path = "$p;$env:Path"
            break
        }
    }
    if (Test-Command "uv") {
        Write-Ok "uv $(uv --version)"
    } else {
        Write-Warn "uv установлен, но не найден в PATH. Добавьте ~/.local/bin в PATH."
    }
}

# ── 5. Playwright (браузеры) ────────────────────────────────────────────────
Write-Step "Playwright Chromium..."

$pwMarker = "$env:LOCALAPPDATA\ms-playwright"
if (Test-Path "$pwMarker\chromium-*") {
    Write-Skip "Playwright Chromium"
} else {
    Write-Host "  → Загрузка Chromium (~150MB)..." -ForegroundColor DarkCyan
    npx -y playwright install chromium 2>&1 | Out-Null
    Write-Ok "Playwright Chromium установлен"
}

# ── 6. Everything (поиск файлов) ────────────────────────────────────────────
Write-Step "Everything (voidtools)..."

$askEverything = Read-Host "  Установить Everything для поиска файлов? (Y/n)"
if ($askEverything -notmatch "^[Nn]") {
    if (Test-Path "C:\Program Files\Everything\Everything.exe" -ErrorAction SilentlyContinue) {
        Write-Skip "Everything"
    } else {
        Winget-Install -Id "voidtools.Everything" -Name "Everything"
        Write-Warn "Запустите Everything после установки (нужен для индексации)"
    }
} else {
    Write-Skip "Everything пропущен"
}

# ── 7. LSP-серверы (для Serena) ─────────────────────────────────────────────
Write-Step "LSP-серверы (для Serena)..."

$lspPackages = @(
    @{ Name = "pyright";                      Cmd = "pyright" },
    @{ Name = "typescript-language-server";    Cmd = "typescript-language-server" }
)

foreach ($lsp in $lspPackages) {
    if (Test-Command $lsp.Cmd) {
        Write-Skip $lsp.Name
    } else {
        Write-Host "  → npm i -g $($lsp.Name)..." -ForegroundColor DarkCyan
        npm install -g $lsp.Name 2>&1 | Out-Null
        Refresh-Path
        Write-Ok "$($lsp.Name)"
    }
}

Write-Host "  ℹ Дополнительные LSP по мере необходимости:" -ForegroundColor DarkGray
Write-Host "    npm i -g vscode-langservers-extracted  (HTML/CSS/JSON/ESLint)" -ForegroundColor DarkGray
Write-Host "    npm i -g @astrojs/language-server      (Astro)" -ForegroundColor DarkGray
Write-Host "    npm i -g svelte-language-server        (Svelte)" -ForegroundColor DarkGray

# ── 8. Кэширование npx-пакетов ──────────────────────────────────────────────
Write-Step "Кэширование npx MCP-серверов..."
Write-Host "  (первый запуск может занять 1-3 мин)" -ForegroundColor DarkGray

$npxPackages = @(
    "@anthropic/mcp-desktop-commander",
    "@modelcontextprotocol/server-filesystem",
    "@modelcontextprotocol/server-git",
    "windows-mcp",
    "codegraph-mcp",
    "codebase-memory-mcp",
    "@anthropic/mcp-playwright",
    "@bytebase/dbhub",
    "simple-files-vectorstore",
    "mcp-obsidian",
    "mcp-everything-search"
)

foreach ($pkg in $npxPackages) {
    Write-Host "  → $pkg ... " -NoNewline -ForegroundColor DarkGray
    try {
        $proc = Start-Process -FilePath "npx" `
            -ArgumentList "-y", $pkg, "--help" `
            -NoNewWindow -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError "NUL"
        $proc.WaitForExit(90000) | Out-Null
        if (-not $proc.HasExited) { $proc.Kill() }
        Write-Host "cached" -ForegroundColor Green
    } catch {
        Write-Host "skip" -ForegroundColor Yellow
    }
}

# ── 9. Кэширование uvx-пакетов ──────────────────────────────────────────────
Write-Step "Кэширование uvx MCP-серверов..."

$uvxPackages = @(
    "mcp-server-git",
    "markitdown-mcp",
    "serena-mcp"
)

foreach ($pkg in $uvxPackages) {
    Write-Host "  → $pkg ... " -NoNewline -ForegroundColor DarkGray
    try {
        $proc = Start-Process -FilePath "uvx" `
            -ArgumentList $pkg, "--help" `
            -NoNewWindow -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError "NUL"
        $proc.WaitForExit(90000) | Out-Null
        if (-not $proc.HasExited) { $proc.Kill() }
        Write-Host "cached" -ForegroundColor Green
    } catch {
        Write-Host "skip" -ForegroundColor Yellow
    }
}

# ── 10. Директории ──────────────────────────────────────────────────────────
Write-Step "Создание директорий..."

$dirs = @(
    $BaseDir,
    $ConfigDir,
    "$DataDir\projects",
    "$DataDir\writing",
    "$DataDir\obsidian-vault",
    "$DataDir\vectorstore"
)

foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
Write-Ok "Директории в $BaseDir"

# ── 11. .env шаблон ─────────────────────────────────────────────────────────
Write-Step "Создание .env..."

$envFile = "$ConfigDir\.env"
if (Test-Path $envFile) {
    Write-Skip ".env уже существует"
} else {
    $projectsPath = "$DataDir\projects" -replace "\\", "/"
    $writingPath  = "$DataDir\writing" -replace "\\", "/"
    $vaultPath    = "$DataDir\obsidian-vault" -replace "\\", "/"
    $vectorPath   = "$DataDir\vectorstore" -replace "\\", "/"

    @"
# ============================================================================
# Локальные MCP — переменные окружения
# ============================================================================

# Пути (замените на реальные)
PROJECTS_DIR=$projectsPath
WRITING_DIR=$writingPath
OBSIDIAN_VAULT=$vaultPath
VECTORSTORE_DIR=$vectorPath

# Git — путь к основному репозиторию
GIT_REPO=$projectsPath/main

# БД (если dbhub подключается к локальной БД)
DBHUB_DSN=postgres://user:pass@localhost:5432/devdb

# MetaMCP (адрес, куда эта машина регистрируется)
METAMCP_HOST=http://<metamcp-ip>:3000
"@ | Out-File -FilePath $envFile -Encoding utf8

    Write-Ok ".env создан: $envFile"
    Write-Warn "Отредактируйте пути на реальные!"
}

# ── 12. Конфиг локальных MCP ────────────────────────────────────────────────
Write-Step "Создание mcp-local.json..."

$configFile = "$ConfigDir\mcp-local.json"
if (Test-Path $configFile) {
    Write-Skip "mcp-local.json уже существует"
} else {
    # Используем forward-slash пути для совместимости
    $pDir = $DataDir -replace "\\", "/"

    @"
{
  "mcpServers": {

    "desktop-commander": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-desktop-commander"],
      "env": {
        "ALLOWED_DIRS": "$pDir/projects;$pDir/writing"
      }
    },

    "filesystem": {
      "command": "npx",
      "args": [
        "-y", "@modelcontextprotocol/server-filesystem",
        "$pDir/projects",
        "$pDir/writing"
      ]
    },

    "windows-mcp": {
      "command": "npx",
      "args": ["-y", "windows-mcp"]
    },

    "everything-search": {
      "command": "npx",
      "args": ["-y", "mcp-everything-search"]
    },

    "git": {
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "$pDir/projects/main"]
    },

    "codegraph": {
      "command": "npx",
      "args": ["-y", "codegraph-mcp"],
      "env": {
        "PROJECT_ROOT": "$pDir/projects/main"
      }
    },

    "codebase-memory": {
      "command": "npx",
      "args": ["-y", "codebase-memory-mcp"]
    },

    "serena": {
      "command": "uvx",
      "args": ["serena-mcp"],
      "env": {
        "PROJECT_ROOT": "$pDir/projects/main"
      }
    },

    "playwright": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-playwright", "--caps", "core,tabs,pdf"]
    },

    "dbhub": {
      "command": "npx",
      "args": ["-y", "@bytebase/dbhub"],
      "env": {
        "DBHUB_DSN": "postgres://user:pass@localhost:5432/devdb"
      }
    },

    "vectorstore": {
      "command": "npx",
      "args": ["-y", "simple-files-vectorstore"],
      "env": {
        "DOCS_DIR": "$pDir/writing"
      }
    },

    "markitdown": {
      "command": "uvx",
      "args": ["markitdown-mcp"]
    },

    "obsidian": {
      "command": "npx",
      "args": ["-y", "mcp-obsidian"],
      "env": {
        "OBSIDIAN_VAULT_PATH": "$pDir/obsidian-vault"
      }
    }
  }
}
"@ | Out-File -FilePath $configFile -Encoding utf8

    Write-Ok "mcp-local.json создан: $configFile"
}

# ── 13. Финальная проверка ──────────────────────────────────────────────────
Write-Step "Проверка..."
Write-Host ""

$checks = @(
    @{ Name = "Node.js";    Cmd = "node" },
    @{ Name = "npm";        Cmd = "npm" },
    @{ Name = "Python";     Cmd = "python" },
    @{ Name = "uv";         Cmd = "uv" },
    @{ Name = "Git";        Cmd = "git" },
    @{ Name = "Playwright"; Cmd = "npx" },
    @{ Name = "pyright";    Cmd = "pyright" }
)

foreach ($c in $checks) {
    if (Test-Command $c.Cmd) {
        Write-Ok $c.Name
    } else {
        Write-Fail $c.Name
    }
}

# Everything — проверяем по пути
if (Test-Path "C:\Program Files\Everything\Everything.exe" -ErrorAction SilentlyContinue) {
    Write-Ok "Everything"
} else {
    Write-Fail "Everything"
}

# Playwright browsers
if (Test-Path "$env:LOCALAPPDATA\ms-playwright\chromium-*") {
    Write-Ok "Playwright Chromium"
} else {
    Write-Fail "Playwright Chromium"
}

# ── Итого ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   УСТАНОВКА ЗАВЕРШЕНА                          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Файлы:" -ForegroundColor White
Write-Host "    Конфиг:  $configFile"
Write-Host "    .env:    $envFile"
Write-Host "    Данные:  $DataDir\"
Write-Host ""
Write-Host "  Следующие шаги:" -ForegroundColor White
Write-Host "    1. Отредактируйте .env и mcp-local.json" -ForegroundColor DarkGray
Write-Host "       (пути к проектам, vault, БД)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    2. Зарегистрируйте эту машину в MetaMCP:" -ForegroundColor DarkGray
Write-Host "       На MetaMCP-хосте добавьте endpoint:" -ForegroundColor DarkGray
Write-Host "       host-local → http://<this-ip>:3001" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    3. Запустите локальный MCP-прокси:" -ForegroundColor DarkGray
Write-Host "       metamcp --config $configFile --port 3001" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    4. Для VM — запустите тот же скрипт," -ForegroundColor DarkGray
Write-Host "       уберите windows-mcp и everything-search" -ForegroundColor DarkGray
Write-Host "       если VM = Linux." -ForegroundColor DarkGray
Write-Host ""