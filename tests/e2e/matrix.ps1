# NPC FailGuard - FINAL exhaustive Windows matrix (PowerShell port of matrix.sh).
# Every command x every condition: empty install, keys-no-provider, full
# rotation matrix vs mock upstream, corrupt files, daemon down, port busy,
# restart, uninstall. Zero real credit (mock provider only).
# Runs on a checkout where install.ps1 has already created core\.venv.
# Must run in ONE CI step (the runner kills background processes between steps).

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$Core = Join-Path $Root "core"
$Py   = Join-Path $Core ".venv\Scripts\python.exe"
$Svc  = Join-Path $Root "scripts\service.ps1"
$PX   = "http://127.0.0.1:8787"
$MOCK = "http://127.0.0.1:9797"

$script:PASS = 0; $script:FAIL = 0; $script:FAILED = @()

function Chk($name, $pat, $text) {
    if ("$text" -match $pat) {
        Write-Host "PASS $name"; $script:PASS++
    } else {
        Write-Host "FAIL $name  expected /$pat/ got:"
        "$text" -split "`n" | ForEach-Object { Write-Host "    | $_" }
        $script:FAIL++; $script:FAILED += $name
    }
}

function ChkNot($name, $pat, $text) {
    if ("$text" -match $pat) {
        Write-Host "FAIL $name  must NOT match /$pat/ got:"
        "$text" -split "`n" | ForEach-Object { Write-Host "    | $_" }
        $script:FAIL++; $script:FAILED += $name
    } else {
        Write-Host "PASS $name"; $script:PASS++
    }
}

function ChkRc($name, $want, $got) {
    if ("$want" -eq "$got") { Write-Host "PASS $name"; $script:PASS++ }
    else {
        Write-Host "FAIL $name  expected rc=$want got rc=$got"
        $script:FAIL++; $script:FAILED += $name
    }
}

function MG { & $Py (Join-Path $Core "manage.py") @args 2>&1 | Out-String }

$BodyFile = Join-Path $env:TEMP "fg-body.json"
'{"model":"claude-sonnet-5","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}' |
    Set-Content -NoNewline $BodyFile
$StreamFile = Join-Path $env:TEMP "fg-stream.json"
'{"model":"claude-sonnet-5","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}' |
    Set-Content -NoNewline $StreamFile

function Post {
    & curl.exe -s --max-time 15 -X POST "$PX/v1/messages" `
        -H "content-type: application/json" --data "@$BodyFile" 2>&1 | Out-String
}
function PostCode {
    (& curl.exe -s --max-time 15 -o NUL -w "%{http_code}" -X POST "$PX/v1/messages" `
        -H "content-type: application/json" --data "@$BodyFile") | Out-String
}
function PoolSum {
    & $Py (Join-Path (Split-Path -Parent $PSCommandPath) "poolsum.py") 2>&1 | Out-String
}
function ResetPool($key) { MG first-setup --replace $MOCK $key | Out-Null }
function DaemonProc {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$Core\main.py*" }
}

Write-Host "############ PHASE A: EMPTY INSTALL (no provider, no keys) ############"
# CI kills the daemon the installer started between steps - start it the real
# production way (service.ps1 -> run-hidden.vbs -> hidden pythonw).
& $Svc start | Out-Null
$OUT = & $Svc wait-ready 2>&1 | Out-String; Chk A0-daemon-ready "ready" $OUT

$OUT = MG status; $RC = $LASTEXITCODE
Chk  A1-status-empty "no keys yet" $OUT
Chk  A1b-status-guides "provider : NOT SET yet" $OUT
ChkRc A1c-status-rc0 0 $RC

$OUT = MG first-setup; $RC = $LASTEXITCODE
Chk  A2-setup-noargs-state "provider : NOT SET yet" $OUT
Chk  A2b-setup-noargs-keys "keys     : none yet" $OUT
Chk  A2c-setup-noargs-next "next: set provider" $OUT
Chk  A2d-setup-noargs-free "free" $OUT
ChkRc A2e-setup-noargs-rc0 0 $RC

$OUT = MG usage; $RC = $LASTEXITCODE
Chk  A3-usage-empty 'spent \$0\.0000' $OUT
Chk  A3b-usage-nobudget "no budget set" $OUT
ChkRc A3c-usage-rc0 0 $RC

$OUT = MG set-budget 12.5; Chk A4-set-budget 'budget set to \$12\.50' $OUT
$OUT = MG set-budget abc; $RC = $LASTEXITCODE
Chk  A5-set-budget-bad "error: budget must be a number" $OUT
ChkRc A5b-rc1 1 $RC
$OUT = MG set-budget 0; Chk A5c-budget-clear "budget cleared" $OUT

$OUT = MG reset-usage; Chk A6-reset-usage "usage counters reset" $OUT

$OUT = MG remove-key nothing; $RC = $LASTEXITCODE
Chk  A7-remove-nomatch "error: no key matches" $OUT
ChkRc A7b-rc1 1 $RC

$OUT = MG add-key "   "; $RC = $LASTEXITCODE
Chk  A8-add-empty "error: empty key" $OUT
ChkRc A8b-rc1 1 $RC

$OUT = MG import-txt "C:\does\not\exist.txt"; $RC = $LASTEXITCODE
Chk  A9-import-missing "error: cannot read" $OUT
ChkRc A9b-rc1 1 $RC

$OUT = MG replace-txt "C:\does\not\exist.txt"; $RC = $LASTEXITCODE
Chk  A10-replace-missing "error: cannot read" $OUT
ChkRc A10b-rc1 1 $RC

$EmptyKeys = Join-Path $env:TEMP "empty-keys.txt"
"# only comments`n" | Set-Content $EmptyKeys
$OUT = MG import-txt $EmptyKeys; $RC = $LASTEXITCODE
Chk  A11-import-emptyfile "error: no keys found" $OUT
ChkRc A11b-rc1 1 $RC

$OUT = MG first-setup "C:\typo\missing-keys.txt"; $RC = $LASTEXITCODE
Chk  A12-setup-badpath "error: keys file not found" $OUT
ChkRc A12b-rc1 1 $RC
$OUT = MG first-setup missing.txt; $RC = $LASTEXITCODE
Chk  A12c-setup-badtxt "error: keys file not found" $OUT
ChkRc A12d-rc1 1 $RC

$OUT = MG set-base-url notaurl; $RC = $LASTEXITCODE
Chk  A13-set-url-bad "error: base URL must start" $OUT
ChkRc A13b-rc1 1 $RC

$OUT = Post; Chk A14-proxy-noprovider "no provider set yet" $OUT
$CODE = PostCode; Chk A14b-503 "503" $CODE

$OUT = MG first-setup ""; $RC = $LASTEXITCODE
Chk  A15-setup-emptystring "provider : NOT SET yet" $OUT
ChkRc A15b-rc0 0 $RC

if (Test-Path (Join-Path $Core "logs\proxy.log")) { Chk A16-logfile-exists "." "x" }
else { Chk A16-logfile-exists "missing" "proxy.log missing" }

Write-Host "############ PHASE B: KEYS BUT NO PROVIDER ############"
$OUT = MG add-key sk-t-alpha000001
Chk B1-add-key 'added \.\.\.000001 as key-1' $OUT
Chk B1b-provider-hint "keys are saved" $OUT

$OUT = MG add-key sk-t-alpha000001; $RC = $LASTEXITCODE
Chk  B2-add-dup "already exists" $OUT
ChkRc B2b-rc1 1 $RC

$Keys3 = Join-Path $env:TEMP "keys3.txt"
"sk-t-beta000002`n# comment`nsk-t-alpha000001`n3  sk-t-gamma000003`n" | Set-Content $Keys3
$OUT = MG import-txt $Keys3
Chk B3-import "imported 2 new keys" $OUT
Chk B3b-import-skip "skipped 1 duplicate" $OUT

$OUT = Post; Chk B4-proxy-still-noprovider "no provider set yet" $OUT

$OUT = MG status
Chk B5-status-3keys "3 keys" $OUT
Chk B5b-status-hint "provider : NOT SET" $OUT

$OUT = MG first-setup sk-t-clobber9; $RC = $LASTEXITCODE
Chk  B6-noclobber "already configured: 3 keys" $OUT
ChkRc B6b-rc2 2 $RC
$OUT = MG status; Chk B7-refusal-untouched "3 keys" $OUT

$OUT = MG remove-key key-2
Chk B8-remove-label 'removed key-2 \(\.\.\.000002\)' $OUT

$OUT = MG remove-key 000003
Chk B9-remove-last6 'removed key-2 \(\.\.\.000003\)' $OUT

$OUT = MG remove-key 0001
Chk B10-remove-tail4 'removed key-1 \(\.\.\.000001\); 0 keys remain' $OUT

$OUT = MG status; Chk B11-back-to-empty "no keys yet" $OUT

$OUT = MG first-setup $MOCK
Chk B12-url-only-setup "provider set: $MOCK" $OUT
Chk B12b-keys-still-none "keys     : none yet" $OUT

$OUT = Post; Chk B13-proxy-nokeys "no API keys added yet" $OUT
$CODE = PostCode; Chk B13b-503 "503" $CODE

Write-Host "############ PHASE C: MOCK UPSTREAM - FULL ROTATION MATRIX ############"
$MockPy = Join-Path (Split-Path -Parent $PSCommandPath) "mock_provider.py"
Start-Process -FilePath $Py -ArgumentList "`"$MockPy`"" -WindowStyle Hidden
foreach ($i in 1..20) {
    try { Invoke-RestMethod "$MOCK/ping" -TimeoutSec 1 | Out-Null; break } catch { Start-Sleep -Milliseconds 300 }
}
$OUT = & curl.exe -s "$MOCK/ping" | Out-String; Chk C0-mock-up '"mock": ?"ok"' $OUT

$OUT = MG first-setup --replace $MOCK sk-t-good001
Chk C1-oneshot-setup "stored 1 key" $OUT
Chk C1b-reloaded "proxy reloaded" $OUT
Chk C1c-complete "setup complete" $OUT

$OUT = Post; Chk C2-happy-path "PROXY-OK-42" $OUT

$OUT = & curl.exe -s --max-time 15 -X POST "$PX/v1/messages" -H "content-type: application/json" --data "@$StreamFile" 2>&1 | Out-String
Chk C3-sse-stream "STREAM-OK-77" $OUT
Chk C3b-sse-stop "message_stop" $OUT

$KK = Join-Path $env:TEMP "kk.txt"
"sk-a-die401`nsk-b-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C4-rotate-on-401 "PROXY-OK-42" $OUT
$OUT = PoolSum; Chk C4b-key1-dead "dead=1" $OUT
$OUT = Get-Content (Join-Path $Core "logs\proxy.log") -Tail 30 -ErrorAction SilentlyContinue | Out-String
Chk C4c-log-rotate "rotate key=key-1 status=401" $OUT

"sk-c-bsy401`nsk-d-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C5-busy401-rotates "PROXY-OK-42" $OUT
$OUT = PoolSum; Chk C5b-busy-not-dead "rate_limited=1" $OUT
ChkNot C5c-busy-no-dead "dead=" $OUT

"sk-e-die403`nsk-f-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C6-rotate-on-403 "PROXY-OK-42" $OUT
$OUT = PoolSum; Chk C6b-403-dead "dead=1" $OUT

"sk-g-pay402`nsk-h-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C7-rotate-on-402 "PROXY-OK-42" $OUT
$OUT = PoolSum; Chk C7b-402-exhausted "exhausted=1" $OUT

"sk-i-thr429`nsk-j-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C8-rotate-on-429 "PROXY-OK-42" $OUT
$OUT = PoolSum; Chk C8b-429-cooling "rate_limited=1" $OUT

"sk-k-srv500`nsk-l-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C9-rotate-on-500 "PROXY-OK-42" $OUT
"sk-m-srv529`nsk-n-good001`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C9b-rotate-on-529 "PROXY-OK-42" $OUT

"sk-o-die401`nsk-p-die403`n" | Set-Content $KK; MG replace-txt $KK | Out-Null
$OUT = Post; Chk C10-all-dead-503 "cooling down|rotation cap" $OUT
$CODE = PostCode; Chk C10b-503 "503" $CODE
$OUT = MG status; Chk C10c-status-shows-dead "dead" $OUT

ResetPool sk-q-bad400                       # fresh pool BEFORE passthrough tests
$OUT = Post; Chk C11-400-passthrough "max_tokens required" $OUT
$CODE = PostCode; Chk C11b-400 "400" $CODE
$OUT = PoolSum; Chk C11c-no-rotation-on-400 "active=1" $OUT

ResetPool sk-r-good001                      # fresh pool BEFORE GET test
$OUT = & curl.exe -s --max-time 10 "$PX/v1/models" | Out-String
Chk C12-get-passthrough '"mock": ?"ok"' $OUT

$Codes = 1..10 | ForEach-Object -Parallel {
    & curl.exe -s --max-time 15 -o NUL -w "%{http_code}" -X POST "http://127.0.0.1:8787/v1/messages" `
        -H "content-type: application/json" --data "@$using:BodyFile"
} -ThrottleLimit 10
$N200 = @($Codes | Where-Object { "$_" -match "^200" }).Count
Chk C13-parallel-10x200 "^10$" "$N200"

MG reset-usage | Out-Null
Post | Out-Null; Post | Out-Null; Post | Out-Null
$OUT = MG usage
Chk C14-usage-3req "3 req" $OUT
Chk C14b-usage-tokens "in 30 / out 15" $OUT

& curl.exe -s --max-time 15 -X POST "$PX/v1/messages" -H "content-type: application/json" --data "@$StreamFile" | Out-Null
$OUT = MG usage; Chk C15-usage-counts-sse "4 req" $OUT

MG set-budget 10 | Out-Null
$OUT = MG usage; Chk C16-budget-line 'of \$10\.00 budget' $OUT
MG reset-usage | Out-Null
$OUT = MG usage; Chk C17-usage-reset 'spent \$0\.0000' $OUT

Write-Host "############ PHASE D: CORRUPT FILES ############"
ResetPool sk-t-good001
"not-json{{{" | Set-Content (Join-Path $Core "keys.json")
$OUT = MG status; $RC = $LASTEXITCODE
ChkRc D1-corrupt-keys-status-rc0 0 $RC
$OUT = MG add-key sk-t-recover01; Chk D1b-corrupt-keys-addok 'added \.\.\.over01 as key-1' $OUT

"garbage" | Set-Content (Join-Path $Core "stats.json")
$OUT = MG usage; $RC = $LASTEXITCODE
Chk  D2-corrupt-stats-usage 'spent \$' $OUT
ChkRc D2b-rc0 0 $RC

"}{bad" | Set-Content (Join-Path $Core "provider.json")
$OUT = MG status; Chk D3-corrupt-provider-status "provider : NOT SET" $OUT
$OUT = Post; Chk D3b-proxy-noprovider "no provider set yet" $OUT
$OUT = MG set-base-url $MOCK; Chk D3c-provider-recover "base URL set to $MOCK" $OUT
ResetPool sk-t-good001
$OUT = Post; Chk D3d-full-recovery "PROXY-OK-42" $OUT

"XX" | Set-Content (Join-Path $Core "state.json")
& $Svc restart | Out-Null
$OUT = & $Svc wait-ready 2>&1 | Out-String; Chk D4-corrupt-state-restart "ready" $OUT
$OUT = Post; Chk D4b-still-works "PROXY-OK-42" $OUT

"nope" | Set-Content (Join-Path $Core "pricing.json")
$OUT = MG usage; $RC = $LASTEXITCODE
ChkRc D5-corrupt-pricing-rc0 0 $RC

Write-Host "############ PHASE E: DAEMON DOWN - EVERY COMMAND ############"
& $Svc stop | Out-Null; Start-Sleep 1

$OUT = MG status; $RC = $LASTEXITCODE
Chk  E1-status-down "proxy not responding" $OUT
Chk  E1b-status-fix-hint "free to fix: restart" $OUT
ChkRc E1c-rc1 1 $RC

$OUT = MG add-key sk-t-offline77; $RC = $LASTEXITCODE
Chk  E2-add-key-down 'added \.\.\.line77' $OUT
Chk  E2b-saved-to-disk "changes saved to disk" $OUT
ChkRc E2c-rc0 0 $RC

$OUT = MG usage; $RC = $LASTEXITCODE
Chk  E3-usage-down 'spent \$' $OUT
ChkRc E3b-rc0 0 $RC

$OUT = MG first-setup; $RC = $LASTEXITCODE
Chk  E4-setup-noargs-down "provider :" $OUT
ChkRc E4b-rc0 0 $RC

$OUT = MG set-base-url $MOCK
Chk E5-set-url-down "base URL set" $OUT
Chk E5b-hint "saved to disk" $OUT

$OUT = MG remove-key offline77
Chk E6-remove-down 'removed key-2 \(\.\.\.line77\)' $OUT

"sk-t-off1`nsk-t-off2`n" | Set-Content $KK
$OUT = MG import-txt $KK; Chk E7-import-down "imported 2 new keys" $OUT
$OUT = MG replace-txt $KK; Chk E8-replace-down "replaced key set with 2 keys" $OUT
$OUT = MG set-budget 5; Chk E9-budget-down 'budget set to \$5\.00' $OUT
$OUT = MG reset-usage; Chk E10-resetusage-down "usage counters reset" $OUT

$OUT = & $Svc is-active 2>&1 | Out-String; $RC = $LASTEXITCODE
Chk  E11-is-active-down "inactive" $OUT
ChkRc E11b-rc1 1 $RC

& curl.exe -s --max-time 3 "$PX/_npc-failguard/status" 2>&1 | Out-Null
ChkRc E12-port-closed 7 $LASTEXITCODE

Write-Host "############ PHASE F: PORT 8787 BUSY ############"
$Squat = Start-Process -FilePath $Py -ArgumentList "-m","http.server","8787","--bind","127.0.0.1" -WindowStyle Hidden -PassThru
Start-Sleep 1
# start the daemon the direct way WITH output capture so the bind error is visible
$DaemonErr = Join-Path $env:TEMP "fg-daemon.err"
$DaemonOut = Join-Path $env:TEMP "fg-daemon.out"
$P = Start-Process -FilePath $Py -ArgumentList "`"$(Join-Path $Core 'main.py')`"" -WorkingDirectory $Core `
    -RedirectStandardError $DaemonErr -RedirectStandardOutput $DaemonOut -WindowStyle Hidden -PassThru
Start-Sleep 3
$OUT = (Get-Content $DaemonErr -ErrorAction SilentlyContinue | Out-String) + (Get-Content $DaemonOut -ErrorAction SilentlyContinue | Out-String)
Chk F1-bind-error-logged "address already in use|error while attempting to bind|only one usage of each socket" $OUT
$OUT = MG status; $RC = $LASTEXITCODE
Chk  F2-status-not-fooled "proxy not responding" $OUT
ChkRc F2b-rc1 1 $RC
Stop-Process -Id $Squat.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $P.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 1

Write-Host "############ PHASE G: RESTART / RECOVERY ############"
& $Svc restart | Out-Null
$OUT = & $Svc wait-ready 2>&1 | Out-String; Chk G1-wait-ready "ready" $OUT
$OUT = & $Svc is-active 2>&1 | Out-String; Chk G2-is-active "active" $OUT

MG first-setup --replace $MOCK sk-t-good001 | Out-Null
$OUT = MG status; Chk G3-status-after-restart '1 keys \(1 active\); current: key-1' $OUT
$OUT = Post; Chk G4-post-after-restart "PROXY-OK-42" $OUT

$OUT = & $Svc start 2>&1 | Out-String; Chk G5-double-start "already running" $OUT

& $Svc stop | Out-Null; Start-Sleep 1
$OUT = & $Svc is-active 2>&1 | Out-String; Chk G6-stopped "inactive" $OUT
& $Svc start | Out-Null
$OUT = & $Svc wait-ready 2>&1 | Out-String; Chk G7-up-again "ready" $OUT

$SlIn = Join-Path $env:TEMP "sl-in.json"
'{"model":{"display_name":"CI"}}' | Set-Content -NoNewline $SlIn
$OUT = cmd /c "set PSModulePath=&& powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\scripts\statusline.ps1`" < `"$SlIn`"" 2>&1 | Out-String
Chk G8-statusline-renders "\S" $OUT

Write-Host "############ PHASE H: UNINSTALL ############"
$OUT = cmd /c "set PSModulePath=&& echo.| powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\uninstall.ps1`"" 2>&1 | Out-String
Chk H1-refuse-noninteractive "need -Yes|Cancelled" $OUT
if (Test-Path (Join-Path $Core "keys.json")) { Chk H1c-still-installed "." "x" }
else { Chk H1c-still-installed "intact" "keys.json removed by refused uninstall!" }

$OUT = cmd /c "set PSModulePath=&& echo.| powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\uninstall.ps1`" -Yes" 2>&1 | Out-String
$RC = $LASTEXITCODE
ChkRc H2-uninstall-rc0 0 $RC
Chk H2a-uninstall-msg "has been uninstalled" $OUT
if (-not (Test-Path (Join-Path $Core "keys.json"))) { Chk H2b-keys-wiped "." "x" }
else { Chk H2b-keys-wiped "gone" "keys.json still present" }
if (-not (Test-Path (Join-Path $Core ".venv"))) { Chk H2c-venv-wiped "." "x" }
else { Chk H2c-venv-wiped "gone" ".venv still present" }
Start-Sleep 1
if (DaemonProc) { Chk H3-daemon-dead "dead" "daemon still running" }
else { Chk H3-daemon-dead "." "x" }
& curl.exe -s --max-time 3 "$PX/_npc-failguard/status" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Chk H4-port-closed "." "x" }
else { Chk H4-port-closed "closed" "port still open" }
$Run = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "NPC FailGuard" -ErrorAction SilentlyContinue
if (-not $Run) { Chk H5-runkey-gone "." "x" }
else { Chk H5-runkey-gone "gone" "Run-key autostart entry still present" }
$OUT = Get-Content (Join-Path $env:USERPROFILE ".claude\settings.json") -Raw -ErrorAction SilentlyContinue
ChkNot H6-settings-cleaned "ANTHROPIC_BASE_URL" "$OUT"

Write-Host ""
Write-Host "=================================================================="
Write-Host "TOTAL: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAILED.Count) { Write-Host "FAILED: $($script:FAILED -join ' ')" }
Write-Host "=================================================================="
exit $script:FAIL
