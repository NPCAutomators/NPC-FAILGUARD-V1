---
description: Restart the NPC FailGuard proxy daemon to adopt config or code changes.
allowed-tools: Bash(bash:*), Bash(curl:*)
---
## Restarting NPC FailGuard

> Note: this briefly interrupts the proxy. If Claude Code itself routes through NPC FailGuard, expect a ~2s blip — it will auto-retry.
> If the user only changed keys or the base URL, a restart is NOT needed — the key-management commands hot-reload automatically.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" restart && echo "readiness: $(bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" wait-ready)"`

Tell the user whether the restart succeeded (readiness `ready` means the status endpoint is answering). The helper works with systemd, falls back to starting the process directly when no D-Bus user session exists, and relaunches the hidden process on Windows. Suggest `/npc-failguard:status` (free, no credit) to confirm keys + provider are loaded.

If it failed, inspect it with:
- Linux: `journalctl --user -u npc-failguard.service -n 30 --no-pager`
- Any platform: `tail -n 30 "${CLAUDE_PLUGIN_ROOT}/core/logs/proxy.log"`
