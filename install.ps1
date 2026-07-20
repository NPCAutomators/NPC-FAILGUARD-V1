# NPC FailGuard - Windows installer.
# Mirrors requirements.sh + install.sh: uv, venv (Python >=3.10), deps,
# hidden autostart at logon (HKCU Run key), and Claude Code auto-setup.
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1 [-NoClaude]
param([switch]$NoClaude)

$ErrorActionPreference = "Stop"
# Older Win10 PowerShell 5.1 may not offer TLS 1.2 by default; the uv and
# Claude Code download endpoints require it.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}
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

    # ---- 3. Autostart at logon (hidden; no admin rights needed) ----
    # HKCU Run key + wscript/run-hidden.vbs: fully hidden (no console window
    # to accidentally close) and always writable by the current user.
    # Older versions used a Task Scheduler task; it can be admin-locked
    # ("Access is denied"), so remove it best-effort and escalate via UAC
    # only if it is still there.
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$CoreDir\main.py*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        # try/catch: with EAP=Stop, PS 5.1 turns native stderr under 2> into
        # a terminating error (e.g. schtasks "Access is denied")
        try { schtasks /Delete /TN "$TaskName" /F 2>$null | Out-Null } catch {}
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host "[!] Old '$TaskName' task is admin-locked; asking for admin (UAC) to remove it..."
        try {
            Start-Process powershell -Verb RunAs -Wait -ArgumentList `
                "-NoProfile -Command schtasks /Delete /TN \`"$TaskName\`" /F"
        } catch {
            Write-Host "[!] Elevation declined - delete the '$TaskName' task manually in Task Scheduler."
        }
    }

    $HiddenVbs = Join-Path $ScriptDir "scripts\run-hidden.vbs"
    $RunKey    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (-not (Test-Path $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
    Set-ItemProperty -Path $RunKey -Name $TaskName `
        -Value "wscript.exe //B //Nologo `"$HiddenVbs`""
    Write-Host "[OK] Autostart registered (starts hidden at logon)"

    # ---- 4. Log dir + start now ----
    # service.ps1 tries the hidden wscript path first, then falls back to a
    # direct Start-Process (needed on CI runners / non-interactive sessions
    # where wscript cannot spawn processes).
    New-Item -ItemType Directory -Force (Join-Path $CoreDir "logs") | Out-Null
    & (Join-Path $ScriptDir "scripts\service.ps1") start
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

        # The installer drops claude.exe in known dirs but the PATH change only
        # reaches NEW terminals (and sometimes not at all) - fix it explicitly.
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
            $ClaudeDirs = @(
                (Join-Path $env:USERPROFILE ".local\bin"),
                (Join-Path $env:LOCALAPPDATA "Programs\claude"),
                (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links")
            )
            foreach ($d in $ClaudeDirs) {
                if (Test-Path (Join-Path $d "claude.exe")) {
                    $env:Path = "$d;$env:Path"
                    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
                    if (-not $UserPath) { $UserPath = "" }
                    if (($UserPath -split ";") -notcontains $d) {
                        [Environment]::SetEnvironmentVariable("Path", "$d;$UserPath", "User")
                        Write-Host "[OK] Added $d to your user PATH"
                    }
                    break
                }
            }
        }
        $claude = Get-Command claude -ErrorAction SilentlyContinue
        if ($claude) {
            Write-Host "[OK] claude found at: $($claude.Source)"
            Write-Host "    (open a NEW terminal window if 'claude' is not recognized elsewhere)"
        } else {
            Write-Host "[!] 'claude' still not on PATH."
            Write-Host "    Open a brand NEW terminal window and try 'claude' again."
            Write-Host "    If it is still missing, run:  irm https://claude.ai/install.ps1 | iex"
        }

        # Merge proxy env + statusline + plugin + onboarding via the venv python
        # (same engine as Linux; avoids PS 5.1 JSON quirks, never clobbers).
        # Pass the ps1 PATH only - PS 5.1 mangles embedded quotes when the
        # path contains spaces (e.g. usernames like "Insha - allah").
        $StatuslinePs1 = Join-Path $ScriptDir "scripts\statusline.ps1"
        $MergePy       = Join-Path $ScriptDir "scripts\claude-merge.py"
        & $VenvPy $MergePy `
            --settings (Join-Path $env:USERPROFILE ".claude\settings.json") `
            --claude-json (Join-Path $env:USERPROFILE ".claude.json") `
            --statusline-ps1 $StatuslinePs1 `
            --plugin-dir $ScriptDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] Claude Code settings merge reported an error (see above)."
        } else {
            Write-Host "[OK] Claude Code configured (proxy routing + statusline + plugin)"
        }
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
