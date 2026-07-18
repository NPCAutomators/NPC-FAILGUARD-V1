#!/usr/bin/env bash
# NPC FailGuard health probe. Prints ONE concise status line and always exits 0 —
# it is used by a SessionStart hook and must never block or fail a session.
set -u

PORT="${NPC_FAILGUARD_PORT:-8787}"
URL="http://127.0.0.1:${PORT}/_npc-failguard/status"

svc="unknown"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active --quiet npc-failguard.service 2>/dev/null; then
        svc="active"
    else
        svc="inactive"
    fi
fi

json="$(curl -s --max-time 3 "$URL" 2>/dev/null || true)"

if [ -z "$json" ]; then
    echo "NPC FailGuard: proxy NOT responding on ${URL} (service=${svc}). Try /npc-failguard:restart, or ./api-setup.sh if unconfigured."
    exit 0
fi

if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
from collections import Counter
try:
    keys = json.load(sys.stdin).get("keys", [])
except Exception:
    print("NPC FailGuard: proxy up (status unparseable)"); sys.exit(0)
total = len(keys)
counts = Counter(k.get("status", "?") for k in keys)
active = counts.get("active", 0)
cur = next((k.get("label", "?") for k in keys if k.get("active")), "?")
detail = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
if active == 0:
    print(f"NPC FailGuard: proxy up but 0/{total} keys usable [{detail}]. Run /npc-failguard:reset to revive them.")
else:
    print(f"NPC FailGuard: up — {active}/{total} keys active (current: {cur}) [{detail}].")
'
else
    echo "NPC FailGuard: proxy up (python3 unavailable for detail)."
fi
exit 0
