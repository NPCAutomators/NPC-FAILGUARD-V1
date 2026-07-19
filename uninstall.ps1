# NPC FailGuard - Windows uninstaller.
# Mirrors uninstall.sh: removes the scheduled task, generated files, and the
# settings.json env keys we set (leaving everything else untouched).
# Usage:  powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Yes]
param([switch]$Yes)

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
    Write-Host "==> NPC FailGuard uninstaller (Windows)"
    Write-Host ""

    $Interactive = [Environment]::UserInteractive -and $Host.Name -eq "ConsoleHost"
    if (-not $Yes) {
        if (-not $Interactive) {
            Write-Host "!! Uninstall is destructive; non-interactive runs need -Yes."
            Pause-Exit 1
        }
        $ans1 = Read-Host "This will fully uninstall NPC FailGuard. Continue? [y/N]"
        if ($ans1 -notmatch '^(y|yes)$') { Write-Host "Cancelled."; Pause-Exit 0 }
        Write-Host ""
        $ans2 = Read-Host "Are you absolutely sure? Type YES (uppercase) to proceed"
        if ($ans2 -cne "YES") { Write-Host "Cancelled."; Pause-Exit 0 }
    }

    Write-Host ""
    Write-Host "==> Uninstalling..."
    Write-Host ""

    # ---- 1. Autostart (Run key + legacy scheduled task) + running daemon ----
    $RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Get-ItemProperty -Path $RunKey -Name $TaskName -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKey -Name $TaskName -ErrorAction SilentlyContinue
        Write-Host "[OK] Removed autostart entry"
    }
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] Removed scheduled task '$TaskName'"
    } catch {
        Write-Host "[OK] No scheduled task to remove"
    }
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$CoreDir\main.py*" } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Stopped daemon process (PID $($_.ProcessId))"
        }

    # ---- 2. Revert the settings.json keys we set (leave everything else) ----
    # PSCustomObject ops only - ConvertFrom-Json -AsHashtable needs PS 7.
    $Settings = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $Settings) {
        try {
            $data = Get-Content $Settings -Raw | ConvertFrom-Json
            $touched = $false
            if ($data.env -and
                "$($data.env.ANTHROPIC_BASE_URL)".StartsWith("http://127.0.0.1:87")) {
                foreach ($k in @("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
                                 "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")) {
                    $data.env.PSObject.Properties.Remove($k)
                }
                if (-not @($data.env.PSObject.Properties).Count) {
                    $data.PSObject.Properties.Remove("env")
                }
                $touched = $true
            }
            if ($data.statusLine -and
                ("$($data.statusLine.command)" -match "statusline")) {
                $data.PSObject.Properties.Remove("statusLine")
                $touched = $true
            }
            if ($touched) {
                $data | ConvertTo-Json -Depth 10 | Set-Content $Settings -Encoding UTF8
                Write-Host "[OK] Reverted npc-failguard keys in $Settings"
            }
        } catch {
            Write-Host "[!] Could not update ${Settings}: $_"
        }
    }

    # ---- 3. Delete generated files inside core/ ----
    if (Test-Path $CoreDir) {
        foreach ($item in @(".venv", "keys.json", "state.json", "provider.json",
                            "api.txt", "logs", "__pycache__")) {
            $p = Join-Path $CoreDir $item
            if (Test-Path $p) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Write-Host "[OK] Cleaned generated files (venv, keys, state, logs)"
    }

    Write-Host ""
    Write-Host "==================================================================="
    Write-Host ""
    Write-Host "  NPC FailGuard has been uninstalled."
    Write-Host ""
    Write-Host "  To also delete this folder itself, run:"
    Write-Host "  Remove-Item -Recurse -Force `"$ScriptDir`""
    Write-Host ""
    Write-Host "==================================================================="
    Pause-Exit 0
} catch {
    Write-Host ""
    Write-Host "!! ERROR: $_"
    Write-Host ("!! At: " + $_.InvocationInfo.PositionMessage)
    Pause-Exit 1
}
