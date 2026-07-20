#!/usr/bin/env bash
# NPC FailGuard - FINAL exhaustive Linux matrix.
# Every command x every condition: empty install, keys-no-provider, full
# rotation matrix vs mock upstream, corrupt files, daemon down, port busy,
# restart, uninstall. Zero real credit (mock provider only).
set -u

APP="$HOME/.npc-failguard/app"
CORE="$APP/core"
SVC="$APP/scripts/service.sh"
PX="http://127.0.0.1:8787"
MOCK="http://127.0.0.1:9797"

MG() { "$CORE/.venv/bin/python" "$CORE/manage.py" "$@"; }

PASS=0; FAIL=0; FAILED=""

chk() {  # chk <name> <grep-E-pattern> <text>
    local name="$1" pat="$2" text="$3"
    if printf '%s' "$text" | grep -qiE "$pat"; then
        echo "PASS $name"; PASS=$((PASS+1))
    else
        echo "FAIL $name  expected /$pat/ got:"
        printf '%s\n' "$text" | sed 's/^/    | /'
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    fi
}

chknot() {  # chknot <name> <pattern-that-must-NOT-appear> <text>
    local name="$1" pat="$2" text="$3"
    if printf '%s' "$text" | grep -qiE "$pat"; then
        echo "FAIL $name  must NOT match /$pat/ got:"
        printf '%s\n' "$text" | sed 's/^/    | /'
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    else
        echo "PASS $name"; PASS=$((PASS+1))
    fi
}

chkrc() {  # chkrc <name> <expected-rc> <actual-rc>
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS $name"; PASS=$((PASS+1))
    else
        echo "FAIL $name  expected rc=$want got rc=$got"
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    fi
}

post() {  # POST a minimal messages request through the proxy; prints body
    curl -s --max-time 15 -X POST "$PX/v1/messages" \
        -H 'content-type: application/json' \
        -d '{"model":"claude-sonnet-5","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}'
}

postcode() {  # prints just the http code WITH newline
    curl -s --max-time 15 -o /dev/null -w '%{http_code}\n' -X POST "$PX/v1/messages" \
        -H 'content-type: application/json' \
        -d '{"model":"claude-sonnet-5","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}'
}

poolsum() {  # "N keys: statusA=X statusB=Y current=<label>"
    curl -s --max-time 5 "$PX/_npc-failguard/status" | python3 -c '
import json,sys
d=json.load(sys.stdin); ks=d.get("keys",[])
c={}
cur="?"
for k in ks:
    c[k["status"]]=c.get(k["status"],0)+1
    if k.get("active"): cur=k["label"]
print(len(ks),"keys:"," ".join(f"{s}={n}" for s,n in sorted(c.items())),"current="+cur)'
}

resetpool() {  # fresh 1-key active pool + mock provider (used between C cases)
    MG first-setup --replace "$MOCK" "$1" >/dev/null 2>&1
}

echo "############ PHASE A: EMPTY INSTALL (no provider, no keys) ############"
OUT=$(bash "$SVC" wait-ready 2>&1); chk A0-daemon-ready "ready" "$OUT"

OUT=$(MG status 2>&1); RC=$?
chk  A1-status-empty "no keys yet" "$OUT"
chk  A1b-status-guides "provider : NOT SET yet" "$OUT"
chkrc A1c-status-rc0 0 $RC

OUT=$(MG first-setup 2>&1); RC=$?
chk  A2-setup-noargs-state "provider : NOT SET yet" "$OUT"
chk  A2b-setup-noargs-keys "keys     : none yet" "$OUT"
chk  A2c-setup-noargs-next "next: set provider" "$OUT"
chk  A2d-setup-noargs-free "free" "$OUT"
chkrc A2e-setup-noargs-rc0 0 $RC

OUT=$(MG usage 2>&1); RC=$?
chk  A3-usage-empty 'spent \$0\.0000' "$OUT"
chk  A3b-usage-nobudget "no budget set" "$OUT"
chkrc A3c-usage-rc0 0 $RC

OUT=$(MG set-budget 12.5 2>&1); chk A4-set-budget 'budget set to \$12\.50' "$OUT"
OUT=$(MG set-budget abc 2>&1); RC=$?
chk  A5-set-budget-bad "error: budget must be a number" "$OUT"
chkrc A5b-rc1 1 $RC
OUT=$(MG set-budget 0 2>&1); chk A5c-budget-clear "budget cleared" "$OUT"

OUT=$(MG reset-usage 2>&1); chk A6-reset-usage "usage counters reset" "$OUT"

OUT=$(MG remove-key nothing 2>&1); RC=$?
chk  A7-remove-nomatch "error: no key matches" "$OUT"
chkrc A7b-rc1 1 $RC

OUT=$(MG add-key "   " 2>&1); RC=$?
chk  A8-add-empty "error: empty key" "$OUT"
chkrc A8b-rc1 1 $RC

OUT=$(MG import-txt /does/not/exist.txt 2>&1); RC=$?
chk  A9-import-missing "error: cannot read" "$OUT"
chkrc A9b-rc1 1 $RC

OUT=$(MG replace-txt /does/not/exist.txt 2>&1); RC=$?
chk  A10-replace-missing "error: cannot read" "$OUT"
chkrc A10b-rc1 1 $RC

printf '# only comments\n\n' > /tmp/empty-keys.txt
OUT=$(MG import-txt /tmp/empty-keys.txt 2>&1); RC=$?
chk  A11-import-emptyfile "error: no keys found" "$OUT"
chkrc A11b-rc1 1 $RC

OUT=$(MG first-setup /typo/missing-keys.txt 2>&1); RC=$?
chk  A12-setup-badpath "error: keys file not found" "$OUT"
chkrc A12b-rc1 1 $RC
OUT=$(MG first-setup missing.txt 2>&1); RC=$?
chk  A12c-setup-badtxt "error: keys file not found" "$OUT"
chkrc A12d-rc1 1 $RC

OUT=$(MG set-base-url notaurl 2>&1); RC=$?
chk  A13-set-url-bad "error: base URL must start" "$OUT"
chkrc A13b-rc1 1 $RC

OUT=$(post); chk A14-proxy-noprovider "no provider set yet" "$OUT"
CODE=$(postcode); chk A14b-503 "^503$" "$CODE"

OUT=$(MG first-setup "" 2>&1); RC=$?
chk  A15-setup-emptystring "provider : NOT SET yet" "$OUT"
chkrc A15b-rc0 0 $RC

[ -f "$CORE/logs/proxy.log" ] && chk A16-logfile-exists "." "x" || chk A16-logfile-exists "missing" "proxy.log missing"

echo "############ PHASE B: KEYS BUT NO PROVIDER ############"
OUT=$(MG add-key sk-t-alpha000001 2>&1)
chk B1-add-key 'added \.\.\.000001 as key-1' "$OUT"
chk B1b-provider-hint "keys are saved" "$OUT"

OUT=$(MG add-key sk-t-alpha000001 2>&1); RC=$?
chk  B2-add-dup "already exists" "$OUT"
chkrc B2b-rc1 1 $RC

printf 'sk-t-beta000002\n# comment\nsk-t-alpha000001\n3  sk-t-gamma000003\n' > /tmp/keys3.txt
OUT=$(MG import-txt /tmp/keys3.txt 2>&1)
chk B3-import "imported 2 new keys" "$OUT"
chk B3b-import-skip "skipped 1 duplicate" "$OUT"

OUT=$(post); chk B4-proxy-still-noprovider "no provider set yet" "$OUT"

OUT=$(MG status 2>&1)
chk B5-status-3keys "3 keys" "$OUT"
chk B5b-status-hint "provider : NOT SET" "$OUT"

OUT=$(MG first-setup sk-t-clobber9 2>&1); RC=$?
chk  B6-noclobber "already configured: 3 keys" "$OUT"
chkrc B6b-rc2 2 $RC
OUT=$(MG status 2>&1); chk B7-refusal-untouched "3 keys" "$OUT"

OUT=$(MG remove-key key-2 2>&1)
chk B8-remove-label 'removed key-2 \(\.\.\.000002\)' "$OUT"

OUT=$(MG remove-key 000003 2>&1)
chk B9-remove-last6 'removed key-2 \(\.\.\.000003\)' "$OUT"

OUT=$(MG remove-key 0001 2>&1)
chk B10-remove-tail4 'removed key-1 \(\.\.\.000001\); 0 keys remain' "$OUT"

OUT=$(MG status 2>&1); chk B11-back-to-empty "no keys yet" "$OUT"

OUT=$(MG first-setup "$MOCK" 2>&1)
chk B12-url-only-setup "provider set: $MOCK" "$OUT"
chk B12b-keys-still-none "keys     : none yet" "$OUT"

OUT=$(post); chk B13-proxy-nokeys "no API keys added yet" "$OUT"
CODE=$(postcode); chk B13b-503 "^503$" "$CODE"

echo "############ PHASE C: MOCK UPSTREAM - FULL ROTATION MATRIX ############"
MOCKPY="${MOCKPY:-$(dirname "$0")/mock_provider.py}"
nohup python3 "$MOCKPY" >/tmp/mock.log 2>&1 &
for i in $(seq 1 20); do curl -s --max-time 1 "$MOCK/ping" >/dev/null 2>&1 && break; sleep 0.3; done
OUT=$(curl -s "$MOCK/ping"); chk C0-mock-up '"mock": ?"ok"' "$OUT"

OUT=$(MG first-setup --replace "$MOCK" sk-t-good001 2>&1)
chk C1-oneshot-setup "stored 1 key" "$OUT"
chk C1b-reloaded "proxy reloaded" "$OUT"
chk C1c-complete "setup complete" "$OUT"

OUT=$(post); chk C2-happy-path "PROXY-OK-42" "$OUT"

OUT=$(curl -s --max-time 15 -X POST "$PX/v1/messages" -H 'content-type: application/json' \
    -d '{"model":"claude-sonnet-5","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}')
chk C3-sse-stream "STREAM-OK-77" "$OUT"
chk C3b-sse-stop "message_stop" "$OUT"

printf 'sk-a-die401\nsk-b-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C4-rotate-on-401 "PROXY-OK-42" "$OUT"
OUT=$(poolsum); chk C4b-key1-dead "dead=1 active=1|active=1 dead=1" "$OUT"
OUT=$(tail -30 "$CORE/logs/proxy.log"); chk C4c-log-rotate "rotate key=key-1 status=401" "$OUT"

printf 'sk-c-bsy401\nsk-d-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C5-busy401-rotates "PROXY-OK-42" "$OUT"
OUT=$(poolsum); chk C5b-busy-not-dead "rate_limited=1" "$OUT"
chknot C5c-busy-no-dead "dead=" "$OUT"

printf 'sk-e-die403\nsk-f-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C6-rotate-on-403 "PROXY-OK-42" "$OUT"
OUT=$(poolsum); chk C6b-403-dead "dead=1" "$OUT"

printf 'sk-g-pay402\nsk-h-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C7-rotate-on-402 "PROXY-OK-42" "$OUT"
OUT=$(poolsum); chk C7b-402-exhausted "exhausted=1" "$OUT"

printf 'sk-i-thr429\nsk-j-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C8-rotate-on-429 "PROXY-OK-42" "$OUT"
OUT=$(poolsum); chk C8b-429-cooling "rate_limited=1" "$OUT"

printf 'sk-k-srv500\nsk-l-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C9-rotate-on-500 "PROXY-OK-42" "$OUT"
printf 'sk-m-srv529\nsk-n-good001\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C9b-rotate-on-529 "PROXY-OK-42" "$OUT"

printf 'sk-o-die401\nsk-p-die403\n' > /tmp/kk.txt; MG replace-txt /tmp/kk.txt >/dev/null 2>&1
OUT=$(post); chk C10-all-dead-503 "cooling down|rotation cap" "$OUT"
CODE=$(postcode); chk C10b-503 "^503$" "$CODE"
OUT=$(MG status 2>&1); chk C10c-status-shows-dead "2 dead|dead" "$OUT"

resetpool sk-q-bad400                       # fresh pool BEFORE passthrough tests
OUT=$(post); chk C11-400-passthrough "max_tokens required" "$OUT"
CODE=$(postcode); chk C11b-400 "^400$" "$CODE"
OUT=$(poolsum); chk C11c-no-rotation-on-400 "active=1" "$OUT"

resetpool sk-r-good001                      # fresh pool BEFORE GET test
OUT=$(curl -s --max-time 10 "$PX/v1/models"); chk C12-get-passthrough '"mock": ?"ok"' "$OUT"

CODES=$(for i in $(seq 1 10); do postcode & done; wait)
N200=$(printf '%s\n' "$CODES" | grep -c '^200$')
chk C13-parallel-10x200 "^10$" "$N200"

MG reset-usage >/dev/null 2>&1
post >/dev/null; post >/dev/null; post >/dev/null
OUT=$(MG usage 2>&1)
chk C14-usage-3req "3 req" "$OUT"
chk C14b-usage-tokens "in 30 / out 15" "$OUT"

curl -s --max-time 15 -X POST "$PX/v1/messages" -H 'content-type: application/json' \
    -d '{"model":"claude-sonnet-5","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}' >/dev/null
OUT=$(MG usage 2>&1); chk C15-usage-counts-sse "4 req" "$OUT"

MG set-budget 10 >/dev/null 2>&1
OUT=$(MG usage 2>&1); chk C16-budget-line 'of \$10\.00 budget' "$OUT"
MG reset-usage >/dev/null 2>&1
OUT=$(MG usage 2>&1); chk C17-usage-reset 'spent \$0\.0000' "$OUT"

echo "############ PHASE D: CORRUPT FILES ############"
resetpool sk-t-good001
echo 'not-json{{{' > "$CORE/keys.json"
OUT=$(MG status 2>&1); RC=$?
chkrc D1-corrupt-keys-status-rc0 0 $RC
OUT=$(MG add-key sk-t-recover01 2>&1); chk D1b-corrupt-keys-addok "added \.\.\.over01 as key-1" "$OUT"

echo 'garbage' > "$CORE/stats.json"
OUT=$(MG usage 2>&1); RC=$?
chk  D2-corrupt-stats-usage 'spent \$' "$OUT"
chkrc D2b-rc0 0 $RC

echo '}{bad' > "$CORE/provider.json"
OUT=$(MG status 2>&1); chk D3-corrupt-provider-status "provider : NOT SET" "$OUT"
OUT=$(post); chk D3b-proxy-noprovider "no provider set yet" "$OUT"
OUT=$(MG set-base-url "$MOCK" 2>&1); chk D3c-provider-recover "base URL set to $MOCK" "$OUT"
resetpool sk-t-good001
OUT=$(post); chk D3d-full-recovery "PROXY-OK-42" "$OUT"

echo 'XX' > "$CORE/state.json"
bash "$SVC" restart >/dev/null 2>&1
OUT=$(bash "$SVC" wait-ready 2>&1); chk D4-corrupt-state-restart "ready" "$OUT"
OUT=$(post); chk D4b-still-works "PROXY-OK-42" "$OUT"

echo 'nope' > "$CORE/pricing.json"
OUT=$(MG usage 2>&1); RC=$?
chkrc D5-corrupt-pricing-rc0 0 $RC

echo "############ PHASE E: DAEMON DOWN - EVERY COMMAND ############"
bash "$SVC" stop >/dev/null 2>&1; sleep 1

OUT=$(MG status 2>&1); RC=$?
chk  E1-status-down "proxy not responding" "$OUT"
chk  E1b-status-fix-hint "free to fix: restart" "$OUT"
chkrc E1c-rc1 1 $RC

OUT=$(MG add-key sk-t-offline77 2>&1); RC=$?
chk  E2-add-key-down "added \.\.\.line77" "$OUT"
chk  E2b-saved-to-disk "changes saved to disk" "$OUT"
chkrc E2c-rc0 0 $RC

OUT=$(MG usage 2>&1); RC=$?
chk  E3-usage-down 'spent \$' "$OUT"
chkrc E3b-rc0 0 $RC

OUT=$(MG first-setup 2>&1); RC=$?
chk  E4-setup-noargs-down "provider :" "$OUT"
chkrc E4b-rc0 0 $RC

OUT=$(MG set-base-url "$MOCK" 2>&1)
chk E5-set-url-down "base URL set" "$OUT"
chk E5b-hint "saved to disk" "$OUT"

OUT=$(MG remove-key offline77 2>&1)
chk E6-remove-down "removed key-2 \(\.\.\.line77\)" "$OUT"

printf 'sk-t-off1\nsk-t-off2\n' > /tmp/kk.txt
OUT=$(MG import-txt /tmp/kk.txt 2>&1); chk E7-import-down "imported 2 new keys" "$OUT"
OUT=$(MG replace-txt /tmp/kk.txt 2>&1); chk E8-replace-down "replaced key set with 2 keys" "$OUT"
OUT=$(MG set-budget 5 2>&1); chk E9-budget-down 'budget set to \$5\.00' "$OUT"
OUT=$(MG reset-usage 2>&1); chk E10-resetusage-down "usage counters reset" "$OUT"

OUT=$(bash "$SVC" is-active 2>&1); RC=$?
chk  E11-is-active-down "inactive" "$OUT"
chkrc E11b-rc1 1 $RC

curl -s --max-time 3 "$PX/_npc-failguard/status" >/dev/null 2>&1
chkrc E12-port-closed 7 $?

echo "############ PHASE F: PORT 8787 BUSY ############"
nohup python3 -m http.server 8787 --bind 127.0.0.1 >/tmp/squat.log 2>&1 &
SQUAT=$!
sleep 1
: > "$CORE/logs/daemon.out"
bash "$SVC" start >/dev/null 2>&1
sleep 2
OUT=$(cat "$CORE/logs/daemon.out" 2>/dev/null)
chk F1-bind-error-logged "address already in use|error while attempting to bind" "$OUT"
OUT=$(MG status 2>&1); RC=$?
chk  F2-status-not-fooled "proxy not responding" "$OUT"
chkrc F2b-rc1 1 $RC
kill "$SQUAT" 2>/dev/null; sleep 1

echo "############ PHASE G: RESTART / RECOVERY ############"
bash "$SVC" restart >/dev/null 2>&1
OUT=$(bash "$SVC" wait-ready 2>&1); chk G1-wait-ready "ready" "$OUT"
OUT=$(bash "$SVC" is-active 2>&1); chk G2-is-active "^active" "$OUT"

MG first-setup --replace "$MOCK" sk-t-good001 >/dev/null 2>&1
OUT=$(MG status 2>&1); chk G3-status-after-restart "1 keys \(1 active\); current: key-1" "$OUT"
OUT=$(post); chk G4-post-after-restart "PROXY-OK-42" "$OUT"

OUT=$(bash "$SVC" start 2>&1); chk G5-double-start "already running" "$OUT"

bash "$SVC" stop >/dev/null 2>&1; sleep 1
OUT=$(bash "$SVC" is-active 2>&1); chk G6-stopped "inactive" "$OUT"
bash "$SVC" start >/dev/null 2>&1
OUT=$(bash "$SVC" wait-ready 2>&1); chk G7-up-again "ready" "$OUT"

echo "############ PHASE H: UNINSTALL ############"
OUT=$(bash "$APP/uninstall.sh" </dev/null 2>&1); RC=$?
chk  H1-refuse-noninteractive "need --yes" "$OUT"
[ "$RC" != "0" ] && chk H1b-nonzero-rc "." "x" || chk H1b-nonzero-rc "nonzero" "rc was 0"
[ -d "$APP" ] && chk H1c-still-installed "." "x" || chk H1c-still-installed "gone" "app dir removed by refused uninstall!"

OUT=$(bash "$APP/uninstall.sh" --yes 2>&1); RC=$?
chkrc H2-uninstall-rc0 0 $RC
chk H2a-uninstall-msg "has been uninstalled" "$OUT"
[ ! -f "$CORE/keys.json" ] && chk H2b-keys-wiped "." "x" || chk H2b-keys-wiped "gone" "keys.json still present"
[ ! -d "$CORE/.venv" ] && chk H2c-venv-wiped "." "x" || chk H2c-venv-wiped "gone" ".venv still present"
sleep 1
pgrep -f "$CORE/main.py" >/dev/null 2>&1 && chk H3-daemon-dead "dead" "daemon still running" || chk H3-daemon-dead "." "x"
curl -s --max-time 3 "$PX/_npc-failguard/status" >/dev/null 2>&1 && chk H4-port-closed "closed" "port still open" || chk H4-port-closed "." "x"
OUT=$(cat "$HOME/.claude/settings.json" 2>/dev/null || echo '{}')
chknot H5-settings-cleaned "ANTHROPIC_BASE_URL" "$OUT"

echo ""
echo "=================================================================="
echo "TOTAL: $PASS passed, $FAIL failed"
[ -n "$FAILED" ] && echo "FAILED:$FAILED"
echo "=================================================================="
exit $FAIL
