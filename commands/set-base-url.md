---
description: Change the upstream provider base URL NPC FailGuard forwards to. Free, no credit used, no restart needed.
argument-hint: <https://provider-url>
allowed-tools: Bash(bash:*)
---
## Change the provider base URL

Updates `core/provider.json` with the new upstream URL (must start with `http://` or `https://`), then hot-reloads the daemon. Claude Code keeps talking to the local proxy at `127.0.0.1:8787` — only where the proxy forwards to changes.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" set-base-url "$1"' _ "$ARGUMENTS"`

Based on the output above, confirm the new base URL to the user. Remind them their existing keys must be valid for the NEW provider — if they're switching providers, they likely also need `/npc-failguard:replace-txt` with that provider's keys. Suggest `/npc-failguard:status` (free), or `/npc-failguard:health` to verify a real request goes through (that one uses a tiny amount of credit).

If no URL was provided or it was rejected, ask the user for a valid URL and re-run.
