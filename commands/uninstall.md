---
description: Remove NPC FailGuard — stop the daemon, delete the service, and strip the shell env vars.
allowed-tools: Bash(cat:*), Bash(bash:*)
---
## Uninstall NPC FailGuard

Uninstalling is destructive. FIRST confirm with the user in the conversation that they really want a full uninstall (keys, state, service, and env vars are all removed). Remind them:
- If they only want to **switch providers** (not remove everything), they want `/npc-failguard:setup`, not this.
- The source folder itself is not deleted; they can `rm -rf` it manually afterward for a total wipe.

**⚠️ Warn about THIS session before running:** if this very Claude Code session routes through the proxy (it almost certainly does), stopping the daemon cuts this session's API connection — expect an "API error" on the NEXT message after uninstall. That error is **expected and harmless**: the uninstall itself completes fully. Tell the user up front:
- finish anything else they need from this session FIRST — uninstall should be the last command;
- after uninstall, this session cannot answer anymore; they'll need to restart Claude Code, which will then use their own real `ANTHROPIC_API_KEY` (or normal Claude login) — if they don't have one, Claude Code won't work until they set that up or reinstall NPC FailGuard.

Once the user explicitly confirms, run it non-interactively:

```
bash "${CLAUDE_PLUGIN_ROOT}/uninstall.sh" --yes
```

It will:
- stop and remove the service (systemd unit on Linux, autostart entry on Windows),
- strip the `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` block from `~/.bashrc` and `~/.zshrc`,
- revert the npc-failguard env keys in `~/.claude/settings.json` (other settings untouched),
- delete generated files (`.venv`, `keys.json`, `state.json`, `provider.json`, `api.txt`, `logs/`).

Immediately BEFORE running the command, post the goodbye message (the tool result may never render after the daemon dies): uninstall is running; if the next message errors, that's the expected connection cut — the uninstall still finished. To verify later: `systemctl --user status npc-failguard` should say not-found/inactive, and a **new terminal** should have no `ANTHROPIC_BASE_URL` pointing at 127.0.0.1:8787. Then restart Claude Code (new terminal) to continue with their own credentials — or reinstall anytime with the install script.
