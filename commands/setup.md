---
description: First-time setup or provider switch — give API keys + provider base URL in one shot, entirely from inside Claude Code. Works even before any key is configured.
argument-hint: <base-url> <key1 key2 ... | /path/to/keys.txt>
allowed-tools: Bash(bash:*)
---
## NPC FailGuard setup

The command below already ran BEFORE this request reached the model — that is
what makes first-time setup possible even with zero working keys: keys + URL
land in the proxy first, then this very reply travels through it.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" first-setup "$@"' _ $ARGUMENTS`

Interpret the output above:

- **"first-setup done: N keys, base URL …"** → tell the user setup is complete
  and working (this very reply already went through the proxy). Suggest
  `/npc-failguard:status` (free) and `/npc-failguard:set-budget <usd>`.
- **"already configured: N keys present"** → keys already exist. Ask the user to
  confirm they want to REPLACE everything (old keys + state wiped). Only after an
  explicit yes, re-run:
  `bash -c '…manage.py first-setup --replace <their args>'` (same pattern as above).
  If they only want to add keys, point them to `/npc-failguard:add-key` /
  `/npc-failguard:add-keys-txt`.
- **"error: no base URL found"** → ask for the provider base URL
  (must start with http:// or https://) and re-run with all arguments.
- **"error: no API keys found"** → ask for keys (pasted directly, space or comma
  separated, or a path to a .txt file) and re-run with all arguments.
- **"proxy not reachable"** after a done-line → keys are saved; the daemon is not
  running. Run `/npc-failguard:restart`, then `/npc-failguard:status`.

Rules: never echo a full API key back to the user (they appear masked as
`...last6` in the output — keep it that way). Keys may arrive in any order,
mixed with the URL; `manage.py` sorts that out — do not pre-parse arguments.
