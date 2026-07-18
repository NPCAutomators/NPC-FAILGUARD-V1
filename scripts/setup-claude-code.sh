#!/usr/bin/env bash
# NPC FailGuard - Claude Code auto-setup (Linux).
# 1. Detects the `claude` CLI; installs it via the official installer if missing.
# 2. Merges the proxy env into ~/.claude/settings.json (never clobbers other
#    settings) so Claude Code routes through the local rotating proxy.
# Usage: setup-claude-code.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

PORT="${NPC_FAILGUARD_PORT:-8787}"
SETTINGS_DIR="$HOME/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"
STATUSLINE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_JSON="$HOME/.claude.json"

echo "==> Claude Code setup"

# ---- 1. Detect / install the claude CLI ----
export PATH="$HOME/.local/bin:$PATH"
if command -v claude >/dev/null 2>&1; then
    echo "[✓] Claude Code already installed: $(claude --version 2>/dev/null || echo present)"
else
    echo "==> Claude Code not found, installing (official installer)..."
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    (dry-run) would run: curl -fsSL https://claude.ai/install.sh | bash"
    else
        if curl -fsSL https://claude.ai/install.sh | bash; then
            export PATH="$HOME/.local/bin:$PATH"
            hash -r 2>/dev/null || true
            if command -v claude >/dev/null 2>&1; then
                echo "[✓] Claude Code installed: $(claude --version 2>/dev/null || echo ok)"
            else
                echo "[!] Installer ran but 'claude' is not on PATH yet."
                echo "    Open a NEW terminal and check: claude --version"
            fi
        else
            echo "[!] Claude Code auto-install failed (network?)."
            echo "    Install manually:  curl -fsSL https://claude.ai/install.sh | bash"
            echo "    Then re-run: bash \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-claude-code.sh\""
            # settings merge below still runs - it's independent of the CLI
        fi
    fi
fi

# ---- 2. Merge proxy env into ~/.claude/settings.json ----
echo "==> Configuring $SETTINGS"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would merge env: ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
else
    mkdir -p "$SETTINGS_DIR"
    python3 - "$SETTINGS" "$PORT" "$STATUSLINE_SH" "$PLUGIN_DIR" "$CLAUDE_JSON" <<'PYEOF'
import json, os, sys

path, port, statusline, plugin_dir, claude_json = sys.argv[1:6]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError:
        backup = path + ".broken"
        os.replace(path, backup)
        print(f"[!] Existing settings.json was invalid JSON; moved to {backup}")
        data = {}

env = data.setdefault("env", {})
wanted = {
    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
    "ANTHROPIC_API_KEY": "npc-failguard-proxy-ignores-this",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
}
changed = {k: v for k, v in wanted.items() if env.get(k) != v}
env.update(wanted)

# Cost/credit indicator in the Claude Code bottom bar. Only set it if the
# user has no statusLine yet, or the existing one is ours - never clobber
# a custom statusline.
sl = data.get("statusLine")
if not sl or "npc-failguard" in json.dumps(sl) or "statusline.sh" in json.dumps(sl):
    new_sl = {"type": "command", "command": f'bash "{statusline}"', "padding": 0}
    if sl != new_sl:
        data["statusLine"] = new_sl
        changed["statusLine"] = statusline
else:
    print("[!] Existing custom statusLine found - left untouched.")
    print(f"    To add the credit indicator manually, run: bash \"{statusline}\"")

# ---- plugin auto-register (same proven schema the /plugin UI writes) ----
mkts = data.setdefault("extraKnownMarketplaces", {})
want_mkt = {"source": {"source": "directory", "path": plugin_dir}}
if mkts.get("npc-failguard-local") != want_mkt:
    mkts["npc-failguard-local"] = want_mkt
    changed["plugin-marketplace"] = plugin_dir
plugins = data.setdefault("enabledPlugins", {})
if plugins.get("npc-failguard@npc-failguard-local") is not True:
    plugins["npc-failguard@npc-failguard-local"] = True
    changed["plugin-enabled"] = "npc-failguard"

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)

if changed:
    print(f"[✓] settings.json updated ({', '.join(changed)})")
else:
    print("[✓] settings.json already configured (no changes)")

# ---- zero-touch onboarding: ~/.claude.json ----
# Skips the first-run wizard AND pre-approves our dummy API key so the
# "Detected a custom API key ... use it? (y/n)" prompt never appears.
# A past "No" is also healed: the suffix is removed from `rejected`.
cj = {}
if os.path.exists(claude_json):
    try:
        with open(claude_json) as f:
            cj = json.load(f)
    except ValueError:
        print(f"[!] {claude_json} is invalid JSON - left untouched "
              "(onboarding prompts may appear once).")
        cj = None
if cj is not None:
    suffix = "npc-failguard-proxy-ignores-this"[-20:]
    cj_changed = False
    if cj.get("hasCompletedOnboarding") is not True:
        cj["hasCompletedOnboarding"] = True
        cj_changed = True
    ckr = cj.setdefault("customApiKeyResponses", {})
    approved = ckr.setdefault("approved", [])
    rejected = ckr.setdefault("rejected", [])
    if suffix not in approved:
        approved.append(suffix)
        cj_changed = True
    if suffix in rejected:
        ckr["rejected"] = [s for s in rejected if s != suffix]
        cj_changed = True
    if cj_changed:
        tmp = claude_json + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cj, f, indent=2)
        os.replace(tmp, claude_json)
        print("[✓] ~/.claude.json: onboarding skipped + proxy key pre-approved")
    else:
        print("[✓] ~/.claude.json already configured (no changes)")
PYEOF
fi

echo ""
echo "  Claude Code will now route through the NPC FailGuard proxy."
echo "  Verify anytime with:  claude --version  and  claude doctor"
