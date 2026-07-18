---
description: Import API keys from a text file into NPC FailGuard (appends to the existing pool). Free, no credit used, no restart needed.
argument-hint: <path-to-keys.txt>
allowed-tools: Bash(bash:*)
---
## Import keys from a text file

Appends every key found in the given file into the default `core/api.txt` + `keys.json` (duplicates are skipped), then hot-reloads the daemon — the existing keys and their state are kept. The file may contain blank lines, `#` comments, or numbered lines like `12  sk-abc...`.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" import-txt "$1"' _ "$ARGUMENTS"`

Based on the output above, tell the user how many keys were added and how many were skipped as duplicates. Never print full API keys. Suggest `/npc-failguard:status` (free) to see the updated pool.

If no path was provided or the file wasn't found, ask the user for the correct path and re-run. If they want to REPLACE the whole pool instead of appending, point them to `/npc-failguard:replace-txt`.
