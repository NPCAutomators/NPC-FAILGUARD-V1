---
name: manage
description: >-
  Operate and troubleshoot the NPC FailGuard API-key-rotation proxy — check key
  status, read logs, restart the daemon, revive dead/rate-limited keys, add or
  remove API keys, switch providers, and diagnose "no keys available" 503s, slow
  responses, or all-keys-dead situations. Use whenever the user mentions NPC
  FailGuard, the local API proxy, key rotation, ANTHROPIC_BASE_URL
  127.0.0.1:8787, or an npc-failguard.service issue.
allowed-tools: Bash(systemctl:*), Bash(journalctl:*), Bash(curl:*), Bash(tail:*), Bash(rm:*), Bash(python3:*), Bash(bash:*), Bash(sleep:*), Read
---

# Managing NPC FailGuard

NPC FailGuard is a **local proxy** (FastAPI daemon on `127.0.0.1:8787`) that transparently
rotates many API keys for any Anthropic-compatible provider. When a
key returns 401/402/429/5xx, the proxy silently retries the same request with the next
key — the client (Claude Code) just sees a slightly delayed 200 and never notices.

On **Linux** it runs as the systemd **user** service `npc-failguard.service`; on
**Windows** it runs as the Task Scheduler at-logon task `NPC FailGuard`. The plugin's
code lives at `${CLAUDE_PLUGIN_ROOT}/core/`; the running daemon uses the same `core/`
directory. Always control the daemon through `scripts/service.sh` (start | stop |
restart | is-active | wait-ready) — it picks systemd, a plain background process
(no D-Bus), or `schtasks` automatically.

## Quick operations

| Goal | Slash command | Cost |
|------|---------------|------|
| See key states | `/npc-failguard:status` | free (local endpoint) |
| End-to-end test | `/npc-failguard:health` | one tiny `/v1/messages` call (uses a little credit) |
| Recent logs | `/npc-failguard:logs` | free |
| Restart daemon | `/npc-failguard:restart` | free |
| Revive all keys | `/npc-failguard:reset` | free — clears `state.json` + hot-reload |
| Add ONE key | `/npc-failguard:add-key <key>` | free — appends + hot-reload |
| Add keys from a file | `/npc-failguard:add-keys-txt <path>` | free — appends + hot-reload |
| Remove a key | `/npc-failguard:remove-key <label\|last6>` | free — hot-reload |
| Replace ALL keys | `/npc-failguard:replace-txt <path>` | free — wipes state + hot-reload |
| Change provider URL | `/npc-failguard:set-base-url <url>` | free — hot-reload |
| Spend / token report | `/npc-failguard:usage` | free — reads `core/stats.json`, counted passively from responses |
| Set a credit budget | `/npc-failguard:set-budget <usd>` | free — statusline then shows `$ left`; `0` clears it |
| Zero usage counters | `/npc-failguard:reset-usage` | free — after a credit top-up; budget kept |
| Full setup (keys + URL) | `/npc-failguard:setup` | First-time setup / switch provider — base URL + keys in one shot, works before any key exists; free (`manage.py first-setup`) |
| Remove everything | `/npc-failguard:uninstall` | runs `uninstall.sh --yes` after user confirms |

All key-management commands are thin wrappers over `core/manage.py`, which masks keys
to their last 6 characters and **hot-reloads** the daemon via
`POST http://127.0.0.1:8787/_npc-failguard/reload` — no restart, so Claude Code's own
connection through the proxy is never cut.

Is the daemon alive? (works on Linux and Windows Git Bash)
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/service.sh" is-active     # expect: active
```

## Key state machine (what the statuses mean)

Each key is in one of these states; the proxy **self-heals** — no state ever requires
a manual reset to recover:

- **active** — usable now.
- **rate_limited** — a 429, a transient 5xx, or a provider "busy" throttle. Auto-revives
  after a short cooldown (~30–60s, or the server's `Retry-After`, capped at 60s).
- **exhausted** — a 402 "credit/limit" response. Auto-revives after ~5h
  (some providers refill credit periodically).
- **dead** — a genuinely invalid key (body says "invalid token"). Retried once after a
  6h safety window, in case it was a mis-classified throttle.

Crucially, a provider-wide "Free access is busy" spell returns HTTP 401 but is a
**temporary throttle, not a dead key** — NPC FailGuard detects this from the response body
and cools the key down briefly instead of killing it. This prevents the old failure mode
where a busy spell marked every key dead at once. As an extra guard, one request rotates
through at most 10 keys (`MAX_ROTATIONS_PER_REQUEST`) before returning the last upstream
error, so a single bad request can't burn the whole pool. Revivals are logged
(`revive key=… -> active`), making self-healing visible in the logs.

## Troubleshooting playbook

**"No keys available" / 503 from the proxy**
1. `/npc-failguard:status` — see how many keys are active vs rate_limited/exhausted/dead.
2. If most are `rate_limited`/`exhausted`: the provider is throttling or credit is spent.
   Wait for the `Retry-After` window; keys revive on their own. Don't reconfigure.
3. If most are `dead`: keys are genuinely invalid, or a throttle was mis-read. Run
   `/npc-failguard:reset` to force-revive and re-test with `/npc-failguard:health`. If they die
   again immediately with "invalid token", the keys really are bad → add fresh keys with
   `/npc-failguard:replace-txt <path>` (or `/npc-failguard:setup` to also change the URL).

**Responses are very slow (then succeed)**
- Free-tier providers are intermittently slow (observed 60–124s, then 200). The proxy
  waits up to 600s, so this is normal — not a bug. A short client timeout can misread it
  as a failure. Confirm with `/npc-failguard:logs` (you'll see high `latency=` then `status=200`).

**Daemon won't start after a restart**
- First check the file log (cross-platform): `tail -n 30 "${CLAUDE_PLUGIN_ROOT}/core/logs/proxy.log"`.
  On Linux with systemd, also `journalctl --user -u npc-failguard.service -n 30 --no-pager`.
  On Windows there is no journalctl — the file log is the only log.
  Common causes: `keys.json` or `provider.json` missing/empty (run `/npc-failguard:setup`),
  or port 8787 already in use.

**Switching providers (one provider → another)**
- `/npc-failguard:replace-txt <new-keys-file>` + `/npc-failguard:set-base-url <new-url>`, or
  `/npc-failguard:setup` to do both at once. Old keys and state are wiped automatically.
  Then `/npc-failguard:health`.

**Client not actually using the proxy**
- Primary mechanism: `~/.claude/settings.json` → `env.ANTHROPIC_BASE_URL=http://127.0.0.1:8787`
  (written by `scripts/setup-claude-code.sh` / `install.ps1`). On Linux the
  `.bashrc`/`.zshrc` marker block is a belt-and-suspenders extra. A stale `.env` sourced
  in the terminal can still bypass both — check with `echo $ANTHROPIC_BASE_URL`.

## Windows notes

- Daemon = Task Scheduler task `NPC FailGuard` (at-logon, `pythonw.exe core\main.py`).
  Install/uninstall via `install.ps1` / `uninstall.ps1`; setup via `api-setup.ps1`.
- `scripts/service.sh` works from Git Bash (Claude Code's shell on Windows) and shells
  out to `schtasks`/`powershell.exe`; `scripts/service.ps1` is the native equivalent.
- No systemd/journalctl — logs live in `core/logs/proxy.log` (daily rotation, 7 days).
- The venv python is `core/.venv/Scripts/python.exe` (not `bin/python`); the slash
  commands already handle both paths.

## Safety notes

- Personal use only. `keys.json`, `api.txt`, and `state.json` hold real secrets — never
  print full keys (the status endpoint and manage.py already mask to the last 6 chars)
  and never paste their contents into chat or anywhere external.
- Don't run `/npc-failguard:uninstall`, `/npc-failguard:replace-txt`, or delete
  `core/keys.json` unless the user explicitly asks — replace-txt wipes the whole pool.
- The proxy that Claude Code itself may be running through is this very daemon; key
  changes use the hot-reload endpoint precisely so no restart is needed. A restart
  causes a brief blip that auto-retries, but avoid needless restarts mid-task.
