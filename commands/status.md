---
description: Show NPC FailGuard proxy status — how many keys are active, dead, rate-limited, and which key is in use. Free, no credit used.
allowed-tools: Bash(curl:*), Bash(bash:*), Bash(python3:*)
---
## NPC FailGuard proxy status

Service state: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" is-active 2>/dev/null || echo "not-active"`

Key states (raw):
!`curl -s --max-time 5 http://127.0.0.1:8787/_npc-failguard/status | python3 -m json.tool 2>/dev/null || echo '{"error":"proxy not responding on 127.0.0.1:8787"}'`

Using the data above, give the user a short, clear summary:
- total keys, and how many are active / rate_limited / exhausted / dead
- which key label is currently active
- anything needing attention (e.g. dead keys) and the exact fix — `/npc-failguard:reset` to revive, `/npc-failguard:add-keys-txt` to add more keys, or `/npc-failguard:setup` to reconfigure

Empty-install cases are NORMAL, not errors — answer warmly, no alarm:
- `keys` is an empty list → the proxy is healthy, just no keys yet: point to `/npc-failguard:add-key <key>` or `/npc-failguard:add-keys-txt <file>` (free).
- proxy not responding → suggest `/npc-failguard:restart` then re-run this (both free).

This command is the free verify step after ANY change — it never contacts the provider and never costs credit. Keep it to a few lines. Do NOT paste the raw JSON back to the user, and never print full API keys.
