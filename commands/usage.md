---
description: Show NPC FailGuard token/cost usage — how much credit is spent (and remaining, if a budget is set). Free, no credit used.
allowed-tools: Bash(bash:*)
---
## Token / cost usage

The proxy counts the `usage` block of every response that already passed through it — the counter never sends anything upstream, so checking this is always free.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" usage'`

Summarize for the user: total spent (and remaining vs. budget if one is set), plus a per-model line (requests, input/output/cache tokens, cost). Notes to mention when relevant:

- Token counts are exact (read from upstream responses). Dollar figures follow `core/pricing.json` — the user can edit those per-million-token rates to match their provider's billing.
- The provider's real remaining balance can't be queried (no balance API); "remaining" is budget − spent. To set a budget: `/npc-failguard:set-budget <usd>`.
- The same numbers appear live in the Claude Code status bar (bottom of the screen).
- To zero the counters (e.g. after a credit top-up): run manage.py `reset-usage` — offer this if the user asks to start counting fresh.
