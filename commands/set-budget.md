---
description: Set the NPC FailGuard credit budget in USD — enables the "remaining credit" display in usage and the status bar. Free, no credit used.
argument-hint: <usd, e.g. 50>
allowed-tools: Bash(bash:*)
---
## Set the credit budget

Providers don't expose a balance API, so NPC FailGuard computes "remaining credit" as *your stated budget minus accurately-counted spend*. Set the budget to whatever credit your provider account actually has.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" set-budget "$1"' _ "$ARGUMENTS"`

Confirm the new budget to the user and mention that the status bar and `/npc-failguard:usage` now show spent + remaining. If they just topped up credit, suggest also resetting the counters with manage.py `reset-usage` so the math starts fresh. If no amount was provided, ask how much credit their account has and re-run.
