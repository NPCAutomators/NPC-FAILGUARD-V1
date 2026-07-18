---
description: Send a tiny test message through the NPC FailGuard proxy to confirm end-to-end routing works (uses a small amount of credit).
allowed-tools: Bash(curl:*)
---
## NPC FailGuard end-to-end health check

> This sends a real upstream request and spends a tiny amount of provider credit. If the user just wants to know whether the proxy/keys are alive, `/npc-failguard:status` is free and usually enough — mention that.

!`curl -s --max-time 90 -w "\nHTTP %{http_code} in %{time_total}s\n" -H "content-type: application/json" -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"reply with the single word: ok"}]}' http://127.0.0.1:8787/v1/messages`

Interpret the result for the user:
- **HTTP 200** with a reply => proxy + key rotation working end to end.
- **HTTP 400** => proxy is fine, but that model isn't on this provider (harmless — Claude Code sends its own model).
- **HTTP 503** => all keys exhausted/rate-limited right now; suggest `/npc-failguard:status` then `/npc-failguard:reset`.
- **No response / timeout** => the free tier can take 60–120s (proxy waits it out), or the daemon is down; suggest `/npc-failguard:restart`.
