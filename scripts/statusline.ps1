# NPC FailGuard statusline for Claude Code (Windows, PowerShell 5.1+).
# Claude Code pipes session JSON on stdin; we add the proxy's token/cost
# counters from the local /usage endpoint. Everything here is free: the
# endpoint only reports what already passed through the proxy - it never
# sends anything upstream, so the indicator itself costs zero tokens.
$ErrorActionPreference = "SilentlyContinue"
$port = if ($env:NPC_FAILGUARD_PORT) { $env:NPC_FAILGUARD_PORT } else { "8787" }

$session = $null
try { $session = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch {}

$stats = $null
try {
    $stats = Invoke-RestMethod -UseBasicParsing -TimeoutSec 1 `
        -Uri "http://127.0.0.1:$port/_npc-failguard/usage"
} catch {}

$parts = @()
if ($stats) {
    $spent = [double]$stats.spent_usd
    $budget = $stats.budget_usd
    if ($null -ne $budget) {
        $remaining = if ($null -ne $stats.remaining_usd) { [double]$stats.remaining_usd }
                     else { [double]$budget - $spent }
        $pct = if ([double]$budget -gt 0) {
            [Math]::Min(100, [Math]::Max(0, [Math]::Round($spent * 100 / [double]$budget)))
        } else { 0 }
        $parts += ('${0:0.00} spent | ${1:0.00} left ({2}% used)' -f $spent, $remaining, $pct)
    } else {
        $parts += ('${0:0.00} spent' -f $spent)
    }
    if ($stats.keys) {
        $total = 0
        $stats.keys.PSObject.Properties | ForEach-Object { $total += [int]$_.Value }
        if ($total -gt 0) {
            $active = [int]$stats.keys.active
            $parts += "keys $active/$total"
        }
    }
} else {
    $parts += "proxy down"
}

$model = $null
try { $model = $session.model.display_name } catch {}
if ($model) { $parts += $model }

Write-Output ("NPC " + ($parts -join " | "))
