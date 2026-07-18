#!/usr/bin/env bash
# NPC FailGuard statusline for Claude Code (settings.json "statusLine").
# Claude Code pipes session JSON on stdin; we add the proxy's token/cost
# counters from the local /usage endpoint. Everything here is free: the
# endpoint only reports what already passed through the proxy - it never
# sends anything upstream, so the indicator itself costs zero tokens.
set -u

PORT="${NPC_FAILGUARD_PORT:-8787}"
SESSION_JSON="$(cat 2>/dev/null || true)"
USAGE_JSON="$(curl -s --max-time 1 "http://127.0.0.1:$PORT/_npc-failguard/usage" 2>/dev/null || true)"

python3 - "$SESSION_JSON" "$USAGE_JSON" <<'PYEOF'
import json, sys

def parse(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

session = parse(sys.argv[1] if len(sys.argv) > 1 else "")
stats = parse(sys.argv[2] if len(sys.argv) > 2 else "")

model = (session.get("model") or {}).get("display_name") or ""
parts = []

if stats:
    spent = stats.get("spent_usd", 0.0)
    budget = stats.get("budget_usd")
    if isinstance(budget, (int, float)):
        remaining = stats.get("remaining_usd", budget - spent)
        pct = min(100, max(0, round(spent * 100 / budget))) if budget else 0
        parts.append(f"${spent:.2f} spent | ${remaining:.2f} left ({pct}% used)")
    else:
        parts.append(f"${spent:.2f} spent")
    keys = stats.get("keys") or {}
    total = sum(keys.values()) if keys else 0
    if total:
        parts.append(f"keys {keys.get('active', 0)}/{total}")
else:
    parts.append("proxy down")

if model:
    parts.append(model)

print("NPC " + " | ".join(parts))
PYEOF
