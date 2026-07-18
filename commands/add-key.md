---
description: Add one API key to NPC FailGuard's rotation pool. Free, no credit used, no restart needed.
argument-hint: <api-key>
allowed-tools: Bash(bash:*)
---
## Add one API key

Adds the given key to `core/api.txt` + `keys.json` with the next `key-N` label, then hot-reloads the daemon (no restart, live traffic is not interrupted).

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" add-key "$1"' _ "$ARGUMENTS"`

Based on the output above, tell the user whether the key was added (manage.py masks keys to their last 6 characters — never print a full key yourself either, even if the user pasted one in the command). If it was a duplicate or invalid, say so plainly. Suggest `/npc-failguard:status` (free) to see the updated pool.

If no key was provided in the command arguments, ask the user for the key and re-run with it.
