#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"

# ---- error/exit UX: show what failed, never slam the window shut ----
FAILED_CMD=""
trap 'FAILED_CMD="$BASH_COMMAND at line $LINENO"' ERR
finish() {
    code=$?
    echo ""
    if [ $code -eq 0 ]; then
        echo "[✓] Done."
    else
        echo "!! FAILED (exit $code)"
        [ -n "$FAILED_CMD" ] && echo "!! While running: $FAILED_CMD"
    fi
    if [ -t 0 ]; then
        read -n 1 -s -r -p "Press any key to close..." _ || true
        echo ""
    fi
    exit $code
}
trap finish EXIT

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
    esac
done

echo "==> NPC FailGuard uninstaller"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "!! Uninstall is destructive; non-interactive runs need --yes."
        exit 1
    fi
    # ---- Confirmation 1 ----
    read -r -p "This will fully uninstall NPC FailGuard. Continue? [y/N] " ANS1
    case "${ANS1:-N}" in
        y|Y|yes|Yes|YES) ;;
        *)
            echo "Cancelled."
            exit 0
            ;;
    esac
    # ---- Confirmation 2 ----
    echo ""
    read -r -p "Are you absolutely sure? Type YES (uppercase) to proceed: " ANS2
    if [ "$ANS2" != "YES" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""
echo "==> Uninstalling..."
echo ""

# ---- 1. Service (systemd on Linux; Task Scheduler task if on Windows) ----
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        schtasks //End //TN "NPC FailGuard" >/dev/null 2>&1 || true
        schtasks //Delete //TN "NPC FailGuard" //F >/dev/null 2>&1 \
            || schtasks /Delete /TN "NPC FailGuard" /F >/dev/null 2>&1 || true
        echo "[✓] Removed scheduled task (if present)"
        ;;
    *)
        if systemctl --user list-unit-files npc-failguard.service >/dev/null 2>&1; then
            systemctl --user stop npc-failguard.service 2>/dev/null || true
            systemctl --user disable npc-failguard.service 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/npc-failguard.service"
            rm -f "$HOME/.config/systemd/user/default.target.wants/npc-failguard.service"
            systemctl --user daemon-reload 2>/dev/null || true
            echo "[✓] Removed systemd service"
        else
            echo "[✓] No systemd service to remove"
        fi
        ;;
esac

# ---- 2. Strip env vars ----
MARKER_START="# >>> npc-failguard env >>>"
MARKER_END="# <<< npc-failguard env <<<"

strip_marker_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    if grep -qF "$MARKER_START" "$file"; then
        local tmp
        tmp=$(mktemp)
        awk -v s="$MARKER_START" -v e="$MARKER_END" '
            $0 == s { inblock=1; next }
            $0 == e { inblock=0; next }
            !inblock { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
        echo "[✓] Cleaned env vars from $file"
    fi
}
strip_marker_block "$HOME/.bashrc"
strip_marker_block "$HOME/.zshrc"

# ---- 3. Revert the settings.json env keys we set (leave everything else) ----
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" <<'PYEOF' || true
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
env = data.get("env", {})
changed = False
if env.get("ANTHROPIC_BASE_URL", "").startswith("http://127.0.0.1:87"):
    for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"):
        if k in env:
            del env[k]
            changed = True
if changed:
    if not env:
        data.pop("env", None)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print("[✓] Reverted npc-failguard env keys in ~/.claude/settings.json")
PYEOF
fi

# ---- 4. Delete generated files inside core/ ----
if [ -d "$CORE_DIR" ]; then
    rm -rf "$CORE_DIR/.venv"
    rm -f  "$CORE_DIR/keys.json"
    rm -f  "$CORE_DIR/state.json"
    rm -f  "$CORE_DIR/provider.json"
    rm -f  "$CORE_DIR/api.txt"
    rm -rf "$CORE_DIR/logs"
    rm -rf "$CORE_DIR/__pycache__"
    echo "[✓] Cleaned generated files (venv, keys, state, logs)"
fi

echo ""
echo "==================================================================="
echo ""
echo "  NPC FailGuard has been uninstalled."
echo "  Open a NEW terminal so the removed env vars take effect."
echo ""
echo "  To also delete this folder itself, run:"
echo "  rm -rf \"$SCRIPT_DIR\""
echo ""
echo "==================================================================="
