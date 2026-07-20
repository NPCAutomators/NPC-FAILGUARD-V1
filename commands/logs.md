---
description: Show the most recent NPC FailGuard proxy log lines (rotations, errors, latency).
allowed-tools: Bash(journalctl:*), Bash(tail:*)
---
## Recent NPC FailGuard logs

From the file log (works on every platform):
!`tail -n 50 "${CLAUDE_PLUGIN_ROOT}/core/logs/proxy.log" 2>/dev/null || echo "(no file log yet)"`

From the systemd journal (Linux only, may be unavailable):
!`journalctl --user -u npc-failguard.service -n 30 --no-pager 2>/dev/null || echo "(journal unavailable)"`

Summarize notable events for the user: recent rotations and why, any errors, and whether traffic is flowing normally. Both log sources being empty is normal on a fresh install (no traffic yet) — say so, don't treat it as a problem. Reading logs is always free. Call out patterns:
- many `throttled` => provider is busy (temporary, keys revive in ~30s)
- `exhausted` => that key's credit is spent (revives after ~5h)
- `unauthorized`/`dead` => a genuinely invalid key
- `revive key=...` => self-healing working: a cooled-down key came back
- `rotation cap reached` => one request hit many bad keys in a row; suggest `/npc-failguard:status`
