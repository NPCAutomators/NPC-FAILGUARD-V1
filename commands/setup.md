---
description: Guided setup — provider URL and/or API keys, each optional, all free (zero credit). Run with no arguments to see setup state and next steps.
argument-hint: "[base-url] [key1 key2 ... | /path/to/keys.txt]  (all optional)"
allowed-tools: Bash(bash:*)
---
## NPC FailGuard setup

The command below already ran BEFORE this request reached the model — that is
what makes setup possible even with zero working keys. Every argument is
optional and NOTHING here uses provider credit.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" first-setup "$@"' _ $ARGUMENTS`

Interpret the output above and guide the user warmly:

- The output always ends with a **setup-state block** (`provider :` / `keys :`
  lines). Relay it as a friendly checklist:
  - provider NOT SET → they can set it anytime: `/npc-failguard:setup https://api.example.com`
  - keys none yet → they can add keys anytime: `/npc-failguard:add-key <key>`
    or `/npc-failguard:add-keys-txt /path/file.txt`
  - both present → setup is COMPLETE; this very reply already traveled through
    the proxy, which is itself the proof it works.
- **Free verification** (suggest after any change, uses no credit):
  `/npc-failguard:status` — shows daemon up + key states.
  Only if the user explicitly wants an end-to-end paid test: `/npc-failguard:health`
  (send ONE tiny real request — costs a little credit; never run it unasked).
- **"already configured: N keys present"** → keys already exist. Ask whether they
  want to REPLACE everything (old keys + state wiped). Only after an explicit yes,
  re-run with `--replace` (same bash pattern). To merely add keys, point them to
  `/npc-failguard:add-key` / `/npc-failguard:add-keys-txt`.
- **"proxy not reachable"** → config is saved on disk anyway. Run
  `/npc-failguard:restart`, then `/npc-failguard:status` (both free).

Rules: never echo a full API key back to the user (they appear masked as
`...last6` — keep it that way). Tokens may arrive in any order, mixed with the
URL; `manage.py` sorts that out — do not pre-parse arguments. Setup with no
arguments is a normal, successful action (it prints state + guidance), not an
error.
