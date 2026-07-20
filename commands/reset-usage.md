---
description: Zero the NPC FailGuard usage counters (tokens + spend). The budget is kept. Use after topping up credit or switching accounts. Free, no credit used.
allowed-tools: Bash(bash:*)
---
## Reset usage counters

Zeroes the per-model token counts and spend in `core/stats.json` and resets the "since" timestamp. The budget (if set) is kept — so "remaining" starts counting down from the full budget again. Typical use: you just topped up provider credit.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" reset-usage'`

Confirm to the user that the counters are zeroed and the budget was kept — suggest `/npc-failguard:usage` (free) to verify the fresh state. If their total credit also changed, suggest `/npc-failguard:set-budget <usd>` to update it.
