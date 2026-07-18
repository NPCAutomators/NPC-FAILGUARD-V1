---
description: REPLACE NPC FailGuard's entire key pool with the keys from a text file (old keys and state are wiped). Free, no credit used, no restart needed.
argument-hint: <path-to-keys.txt>
allowed-tools: Bash(bash:*)
---
## Replace the whole key pool from a text file

**This wipes the current `keys.json` and `state.json`** and imports a fresh set from the given file, then hot-reloads the daemon. The file may contain blank lines, `#` comments, or numbered lines like `12  sk-abc...`.

Before running, briefly confirm with the user that they really want a full replacement (if they clearly asked to "replace", proceed). If they only want to ADD keys, use `/npc-failguard:add-keys-txt` instead.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" replace-txt "$1"' _ "$ARGUMENTS"`

Based on the output above, tell the user how many keys are now loaded (all starting as `active` since state was reset). Never print full API keys. Suggest `/npc-failguard:status` (free) to verify.

If no path was provided or the file wasn't found, ask the user for the correct path and re-run.
