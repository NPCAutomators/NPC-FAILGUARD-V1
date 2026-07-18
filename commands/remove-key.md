---
description: Remove one API key from NPC FailGuard by its label (key-N) or last 6 characters. Free, no credit used, no restart needed.
argument-hint: <key-label or last-6-chars>
allowed-tools: Bash(bash:*)
---
## Remove an API key

Removes the matching key from `keys.json`, `core/api.txt`, and `state.json`, relabels the remaining keys, and hot-reloads the daemon. Identify the key by its label (e.g. `key-7`) or the last 6 characters shown by `/npc-failguard:status`.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" remove-key "$1"' _ "$ARGUMENTS"`

Based on the output above, confirm to the user which key was removed (masked form only — never print full keys). Note that remaining keys were relabeled and their runtime state was reset, so previously dead/rate-limited keys will be retried fresh. Suggest `/npc-failguard:status` (free) to see the updated pool.

If no argument was given, first run `/npc-failguard:status` mentally on their behalf: ask which key they want removed and offer the masked list from the status endpoint.
