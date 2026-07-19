# NPC FailGuard - Windows service control (hidden daemon via run-hidden.vbs).
# Usage: .\service.ps1 start|stop|restart|is-active|wait-ready
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$CoreDir   = Join-Path $RootDir "core"
$TaskName  = "NPC FailGuard"
$Port      = if ($env:NPC_FAILGUARD_PORT) { $env:NPC_FAILGUARD_PORT } else { "8787" }

function Get-ProxyProcess {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$CoreDir\main.py*" }
}

function Start-Proxy {
    if (Get-ProxyProcess) { Write-Host "already running"; return }
    $Vbs = Join-Path $ScriptDir "run-hidden.vbs"
    if (Test-Path $Vbs) {
        Start-Process wscript.exe -ArgumentList "//B //Nologo `"$Vbs`""
        Write-Host "started (hidden)"
    } else {
        Write-Host "run-hidden.vbs missing - run install.ps1 first"
        exit 1
    }
}

function Stop-Proxy {
    # legacy installs used a scheduled task - stop it too if present
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Get-ProxyProcess | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Host "stopped"
}

function Test-Active {
    if (Get-ProxyProcess) { return $true }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/_npc-failguard/status" -TimeoutSec 2 | Out-Null
        return $true
    } catch { return $false }
}

function Wait-Ready {
    for ($i = 0; $i -lt 20; $i++) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/_npc-failguard/status" -TimeoutSec 2 | Out-Null
            Write-Host "ready"
            return
        } catch { Start-Sleep -Milliseconds 500 }
    }
    Write-Host "not-ready"
    exit 1
}

switch ($args[0]) {
    "start"      { Start-Proxy }
    "stop"       { Stop-Proxy }
    "restart"    { Stop-Proxy; Start-Sleep 1; Start-Proxy }
    "is-active"  { if (Test-Active) { Write-Host "active" } else { Write-Host "inactive"; exit 1 } }
    "wait-ready" { Wait-Ready }
    default      { Write-Host "usage: service.ps1 start|stop|restart|is-active|wait-ready"; exit 2 }
}
