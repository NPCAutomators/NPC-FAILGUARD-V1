# NPC FailGuard - keys + base URL setup (Windows).
# Mirrors api-setup.sh: all real logic lives in core/manage.py (cross-platform).
# Usage:  powershell -ExecutionPolicy Bypass -File api-setup.ps1 [-KeysFile <path>] [-BaseUrl <url>] [-Yes]
param(
    [string]$KeysFile = "",
    [string]$BaseUrl = "",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreDir   = Join-Path $ScriptDir "core"
$Port      = if ($env:NPC_FAILGUARD_PORT) { $env:NPC_FAILGUARD_PORT } else { "8787" }

function Pause-Exit([int]$Code) {
    Write-Host ""
    if ($Code -eq 0) { Write-Host "[OK] Done." } else { Write-Host "!! FAILED (exit $Code)" }
    if ([Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost") {
        Read-Host "Press Enter to close" | Out-Null
    }
    exit $Code
}

try {
    Write-Host "==> NPC FailGuard: keys + base URL setup (Windows)"
    Write-Host ""

    # ---- 0. core/ and venv must exist ----
    if (-not (Test-Path $CoreDir)) {
        Write-Host "!! core/ folder missing. Run install.ps1 first."
        Pause-Exit 1
    }
    $VenvPy = Join-Path $CoreDir ".venv\Scripts\python.exe"
    if (-not (Test-Path $VenvPy)) {
        Write-Host "!! Python venv missing at core\.venv - run install.ps1 first."
        Pause-Exit 1
    }

    $Interactive = [Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost"

    # ---- 1. Keys file: parameter or interactive prompt ----
    if (-not $KeysFile) {
        if (-not $Interactive) {
            Write-Host "!! No -KeysFile given and no interactive console."
            Write-Host "   Non-interactive usage: api-setup.ps1 -KeysFile <path> -BaseUrl <url> -Yes"
            Pause-Exit 1
        }
        while ($true) {
            $KeysFile = (Read-Host "Path to your API keys file (one key per line)").Trim().Trim('"').Trim("'")
            if (-not $KeysFile) { Write-Host "!! Empty path. Try again."; continue }
            if (-not (Test-Path $KeysFile)) { Write-Host "!! File not found: $KeysFile"; continue }
            break
        }
    } elseif (-not (Test-Path $KeysFile)) {
        Write-Host "!! File not found: $KeysFile"
        Pause-Exit 1
    }

    # ---- 2. Base URL: parameter or interactive prompt ----
    if (-not $BaseUrl) {
        if (-not $Interactive) {
            Write-Host "!! No -BaseUrl given and no interactive console."
            Pause-Exit 1
        }
        while ($true) {
            $BaseUrl = (Read-Host "Base URL (e.g. https://api.example.com)").Trim().TrimEnd('/')
            if ($BaseUrl -match '^https?://') { break }
            Write-Host "!! URL must start with http:// or https://. Try again."
        }
    } else {
        $BaseUrl = $BaseUrl.TrimEnd('/')
        if ($BaseUrl -notmatch '^https?://') {
            Write-Host "!! URL must start with http:// or https://"
            Pause-Exit 1
        }
    }

    # ---- 3. Confirm replacement if keys already exist ----
    if ((Test-Path (Join-Path $CoreDir "keys.json")) -and -not $Yes -and $Interactive) {
        $ans = Read-Host "Existing keys will be REPLACED and state reset. Continue? [y/N]"
        if ($ans -notmatch '^[yY]') { Write-Host "Cancelled."; Pause-Exit 0 }
    }

    # ---- 4. Replace key set + provider via manage.py (single source of truth) ----
    Write-Host "==> Importing keys from $KeysFile"
    & $VenvPy (Join-Path $CoreDir "manage.py") replace-txt $KeysFile
    if ($LASTEXITCODE -ne 0) { throw "manage.py replace-txt failed (exit $LASTEXITCODE)" }
    & $VenvPy (Join-Path $CoreDir "manage.py") set-base-url $BaseUrl
    if ($LASTEXITCODE -ne 0) { throw "manage.py set-base-url failed (exit $LASTEXITCODE)" }

    # ---- 5. Restart daemon ----
    Write-Host ""
    Write-Host "==> Restarting daemon"
    $ServicePs1 = Join-Path $ScriptDir "scripts\service.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ServicePs1 restart
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ServicePs1 wait-ready
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! Daemon did not come up on port $Port."
        Write-Host "   Check the log file: $CoreDir\logs\proxy.log"
        Pause-Exit 1
    }
    Write-Host "[OK] Daemon running"

    # ---- 6. Health check (uses a tiny amount of provider credit) ----
    Write-Host ""
    Write-Host "==> Health check..."
    $Body = '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
    $HttpCode = 0
    $RespBody = ""
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/messages" -Method Post `
            -ContentType "application/json" -Body $Body -TimeoutSec 120 -UseBasicParsing
        $HttpCode = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) {
            $HttpCode = [int]$_.Exception.Response.StatusCode
            # PS 7 exposes the body here; PS 5.1 needs the stream fallback
            $RespBody = $_.ErrorDetails.Message
            if (-not $RespBody) {
                try {
                    $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $RespBody = $reader.ReadToEnd()
                } catch {}
            }
        }
    }

    if ($HttpCode -eq 200) {
        Write-Host "[OK] Health check passed (HTTP 200)"
    } elseif ($HttpCode -eq 400) {
        Write-Host "[!] HTTP 400 - model may not exist on this provider."
        Write-Host "    That's fine; proxy is running. Claude Code will send its own model choice."
    } else {
        Write-Host "[!] Health check returned HTTP $HttpCode"
        if ($RespBody) { Write-Host "    Response body:"; Write-Host "    $RespBody" }
        Write-Host "    Check the log file: $CoreDir\logs\proxy.log"
    }

    Write-Host ""
    Write-Host "==================================================================="
    Write-Host "  Setup complete."
    Write-Host ""
    Write-Host "  Open a new terminal and run 'claude' to start using it."
    Write-Host "  Check status:  curl.exe -s http://127.0.0.1:$Port/_npc-failguard/status"
    Write-Host "  Log file:      $CoreDir\logs\proxy.log"
    Write-Host "==================================================================="
    Pause-Exit 0
} catch {
    Write-Host ""
    Write-Host "!! ERROR: $_"
    Write-Host ("!! At: " + $_.InvocationInfo.PositionMessage)
    Pause-Exit 1
}
