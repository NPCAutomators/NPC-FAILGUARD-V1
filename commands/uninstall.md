---
description: Remove NPC FailGuard — stop the daemon, delete the service, and strip the shell env vars.
allowed-tools: Bash(cat:*), Bash(bash:*)
---
## Uninstall NPC FailGuard

Uninstalling is destructive. FIRST confirm with the user in the conversation that they really want a full uninstall (keys, state, service, and env vars are all removed). Remind them:
- If they only want to **switch providers** (not remove everything), they want `/npc-failguard:setup`, not this.
- The source folder itself is not deleted; they can `rm -rf` it manually afterward for a total wipe.

Once the user explicitly confirms, run it non-interactively:

```
bash "${CLAUDE_PLUGIN_ROOT}/uninstall.sh" --yes
```

It will:
- stop and remove the service (systemd unit on Linux, scheduled task on Windows),
- strip the `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` block from `~/.bashrc` and `~/.zshrc`,
- revert the npc-failguard env keys in `~/.claude/settings.json` (other settings untouched),
- delete generated files (`.venv`, `keys.json`, `state.json`, `provider.json`, `api.txt`, `logs/`).

After it finishes, tell the user to open a **new terminal** (or restart Claude Code) so the removed env vars take effect — the current session may still point at the now-dead proxy.
