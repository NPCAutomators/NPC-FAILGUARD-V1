---
description: Revive ALL NPC FailGuard keys by clearing runtime state. Use if every key shows dead/rate-limited.
allowed-tools: Bash(rm:*), Bash(curl:*), Bash(bash:*), Bash(python3:*)
---
## Reset NPC FailGuard key state

This clears `core/state.json` (the per-key dead / rate-limit history) and hot-reloads the daemon, so every key starts `active` again — without restarting the proxy or interrupting traffic. Your `keys.json` and provider are left untouched.

Step 1 — clear the state file:
!`rm -f "${CLAUDE_PLUGIN_ROOT}/core/state.json" && echo "state cleared"`

Step 2 — hot-reload (falls back to restart if the daemon is down):
!`curl -s -X POST --max-time 10 http://127.0.0.1:8787/_npc-failguard/reload || { echo "reload failed - daemon down? restarting..."; bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" restart; bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" wait-ready; }`

Step 3 — verify:
!`curl -s --max-time 5 http://127.0.0.1:8787/_npc-failguard/status | python3 -c "import json,sys; d=json.load(sys.stdin); ks=d['keys']; print(sum(1 for k in ks if k['status']=='active'),'of',len(ks),'keys active')" 2>/dev/null || echo "status check failed"`

Confirm to the user how many keys are now active. Remind them: keys self-heal automatically (throttled keys retry in ~30s, exhausted after ~5h, dead keys after ~6h), so a manual reset is rarely needed — mainly useful right after fixing keys or a provider outage.
