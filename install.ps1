# NPC FailGuard - Windows installer.
# Mirrors requirements.sh + install.sh: uv, venv (Python >=3.10), deps,
# Task Scheduler at-logon task, and Claude Code auto-setup.
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1 [-NoClaude]
param([switch]$NoClaude)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreDir   = Join-Path $ScriptDir "core"
$TaskName  = "NPC FailGuard"

function Pause-Exit([int]$Code) {
    Write-Host ""
    if ($Code -eq 0) { Write-Host "[OK] Done." } else { Write-Host "!! FAILED (exit $Code)" }
    if ([Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost") {
        Read-Host "Press Enter to close" | Out-Null
    }
    exit $Code
}

try {
    Write-Host "==> NPC FailGuard installer (Windows)"
    Write-Host "    Install dir: $ScriptDir"
    Write-Host ""

    # ---- 0. core/ must exist ----
    if (-not (Test-Path $CoreDir)) {
        Write-Host "!! core/ folder missing. Are you running this from the right place?"
        Pause-Exit 1
    }

    # ---- 1. uv check / install ----
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) {
        Write-Host "==> uv not found, installing..."
        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
        $uv = Get-Command uv -ErrorAction SilentlyContinue
    }
    if (-not $uv) {
        Write-Host "!! uv install failed. Install manually: https://docs.astral.sh/uv/"
        Pause-Exit 1
    }
    Write-Host "[OK] uv $((uv --version) -replace 'uv ','')"

    # ---- 2. venv + deps (uv downloads CPython if the machine lacks 3.10+) ----
    $VenvPy = Join-Path $CoreDir ".venv\Scripts\python.exe"
    $venvOk = $false
    if (Test-Path $VenvPy) {
        & $VenvPy -c "import sys; sys.exit(0 if sys.version_info[:2]>=(3,10) else 1)" 2>$null
        $venvOk = ($LASTEXITCODE -eq 0)
    }
    if ((Test-Path (Join-Path $CoreDir ".venv")) -and -not $venvOk) {
        Write-Host "==> Existing venv broken or older than Python 3.10, recreating..."
        Remove-Item -Recurse -Force (Join-Path $CoreDir ".venv")
    }
    if (-not (Test-Path (Join-Path $CoreDir ".venv"))) {
        Write-Host "==> Creating venv (Python >=3.10, fetched by uv if needed)..."
        uv venv --python ">=3.10" (Join-Path $CoreDir ".venv") | Out-Null
    }
    Write-Host "==> Installing dependencies..."
    uv pip install --quiet -r (Join-Path $CoreDir "requirements.txt") --python $VenvPy
    Write-Host "[OK] Dependencies installed"

    # ---- 3. Task Scheduler at-logon task (pythonw = no console window) ----
    $PythonW = Join-Path $CoreDir ".venv\Scripts\pythonw.exe"
    if (-not (Test-Path $PythonW)) { $PythonW = $VenvPy }  # fallback
    $Action  = New-ScheduledTaskAction -Execute $PythonW `
        -Argument "`"$CoreDir\main.py`"" -WorkingDirectory $CoreDir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Days 3650)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Settings $Settings -Description "NPC FailGuard - API key rotating proxy" | Out-Null
    Write-Host "[OK] Scheduled task '$TaskName' registered (starts at logon)"

    # ---- 4. Log dir + start now ----
    New-Item -ItemType Directory -Force (Join-Path $CoreDir "logs") | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[OK] Daemon started"

    # ---- 5. Claude Code auto-setup ----
    if (-not $NoClaude) {
        Write-Host ""
        Write-Host "==> Claude Code setup"
        $claude = Get-Command claude -ErrorAction SilentlyContinue
        if ($claude) {
            Write-Host "[OK] Claude Code already installed: $(claude --version 2>$null)"
        } else {
            Write-Host "==> Claude Code not found, installing (official installer)..."
            try {
                Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
            } catch {
                Write-Host "[!] Native installer failed, trying winget..."
                try { winget install --accept-source-agreements --accept-package-agreements Anthropic.ClaudeCode }
                catch { Write-Host "[!] Auto-install failed. Install manually: irm https://claude.ai/install.ps1 | iex" }
            }
        }

        # Merge proxy env into settings.json (never clobber other settings)
        $SettingsDir = Join-Path $env:USERPROFILE ".claude"
        $Settings    = Join-Path $SettingsDir "settings.json"
        New-Item -ItemType Directory -Force $SettingsDir | Out-Null
        $data = @{}
        if (Test-Path $Settings) {
            try { $data = Get-Content $Settings -Raw | ConvertFrom-Json -AsHashtable }
            catch {
                Move-Item $Settings "$Settings.broken" -Force
                Write-Host "[!] Existing settings.json was invalid JSON; moved to settings.json.broken"
                $data = @{}
            }
        }
        if (-not $data.ContainsKey("env")) { $data["env"] = @{} }
        $data["env"]["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8787"
        $data["env"]["ANTHROPIC_API_KEY"] = "npc-failguard-proxy-ignores-this"
        $data["env"]["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        $data | ConvertTo-Json -Depth 10 | Set-Content $Settings -Encoding UTF8
        Write-Host "[OK] $Settings configured (routes Claude Code through the proxy)"
    }

    Write-Host ""
    Write-Host "==================================================================="
    Write-Host "  Installation complete."
    Write-Host "  Next: powershell -ExecutionPolicy Bypass -File api-setup.ps1"
    Write-Host "        (or from Claude Code: /npc-failguard:setup)"
    Write-Host "==================================================================="
    Pause-Exit 0
} catch {
    Write-Host ""
    Write-Host "!! ERROR: $_"
    Write-Host ("!! At: " + $_.InvocationInfo.PositionMessage)
    Pause-Exit 1
}
