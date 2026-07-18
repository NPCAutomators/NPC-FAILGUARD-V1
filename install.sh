#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"

# ---- error/exit UX: show what failed, never slam the window shut ----
FAILED_CMD=""
trap 'FAILED_CMD="$BASH_COMMAND at line $LINENO"' ERR
finish() {
    code=$?
    # skip the pause when we exec into api-setup.sh (RUNNING_SETUP set below)
    [ "${RUNNING_SETUP:-0}" = "1" ] && exit $code
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

SKIP_CLAUDE=0
SKIP_KEYS=0
for arg in "$@"; do
    case "$arg" in
        --no-claude) SKIP_CLAUDE=1 ;;
        --no-keys)   SKIP_KEYS=1 ;;
    esac
done

echo "==> NPC FailGuard installer"
echo "    Install dir: $SCRIPT_DIR"
echo ""

# ---- 0. core/ must exist ----
if [ ! -d "$CORE_DIR" ]; then
    echo "!! core/ folder missing. Are you running this from the right place?"
    exit 1
fi

# ---- 1. Python 3.10+ check ----
if ! command -v python3 >/dev/null 2>&1; then
    echo "!! python3 not found. Run ./requirements.sh first."
    exit 1
fi
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    echo "!! Python $PY_VER too old. Need 3.10+."
    exit 1
fi
echo "[✓] Python $PY_VER"

# ---- 2. uv check / install ----
if ! command -v uv >/dev/null 2>&1; then
    echo "==> uv not found, installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv >/dev/null 2>&1; then
    echo "!! uv install failed. Install manually: https://docs.astral.sh/uv/"
    exit 1
fi
echo "[✓] uv $(uv --version | awk '{print $2}')"

# ---- 3. venv + deps ----
# The core is plain Python (3.10+). uv fetches a standalone CPython if the
# system one is too old, so this works on any Linux.
MIN_PY="3.10"
venv_ok() {
    [ -x "$CORE_DIR/.venv/bin/python" ] || return 1
    "$CORE_DIR/.venv/bin/python" -c "import sys; sys.exit(0 if sys.version_info[:2]>=(3,10) else 1)" >/dev/null 2>&1
}
# Rebuild if the venv is missing, broken/foreign (stale absolute path), or too old.
if [ -d "$CORE_DIR/.venv" ] && ! venv_ok; then
    echo "==> Existing venv is broken/foreign or older than Python $MIN_PY, recreating..."
    rm -rf "$CORE_DIR/.venv"
fi
if [ ! -d "$CORE_DIR/.venv" ]; then
    echo "==> Creating venv in core/ (Python >=$MIN_PY, fetched by uv if needed)..."
    uv venv --python ">=$MIN_PY" "$CORE_DIR/.venv" >/dev/null 2>&1
fi
echo "==> Installing dependencies..."
uv pip install --quiet -r "$CORE_DIR/requirements.txt" --python "$CORE_DIR/.venv/bin/python"
echo "[✓] Dependencies installed"

# ---- 4. Generate + install systemd user unit ----
mkdir -p "$HOME/.config/systemd/user"
UNIT_FILE="$HOME/.config/systemd/user/npc-failguard.service"

# systemd ExecStart splits on unescaped whitespace, so any space in the path
# must be encoded as \x20. WorkingDirectory takes the value verbatim.
CORE_DIR_EXEC="${CORE_DIR// /\\x20}"

cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=NPC FailGuard - API key rotating proxy
After=network-online.target
Wants=network-online.target
# StartLimit* must live in [Unit]; systemd ignores them in [Service]
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$CORE_DIR
ExecStart=$CORE_DIR_EXEC/.venv/bin/python $CORE_DIR_EXEC/main.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT

if systemctl --user list-units >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable npc-failguard.service >/dev/null 2>&1
    echo "[✓] Systemd user service installed + enabled"
else
    echo "[!] No systemd user session (D-Bus unavailable)."
    echo "    Unit file written; the daemon can also be started directly:"
    echo "    bash \"$SCRIPT_DIR/scripts/service.sh\" start"
fi

# ---- 5. Shell env vars (idempotent) ----
MARKER_START="# >>> npc-failguard env >>>"
MARKER_END="# <<< npc-failguard env <<<"

add_env_block() {
    local rc="$1"
    [ -f "$rc" ] || return 0
    if grep -qF "$MARKER_START" "$rc" 2>/dev/null; then
        echo "[✓] Env vars already in $rc (skipped)"
        return 0
    fi
    cat >> "$rc" <<ENVBLOCK

$MARKER_START
export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
export ANTHROPIC_API_KEY="npc-failguard-proxy-ignores-this"
$MARKER_END
ENVBLOCK
    echo "[✓] Added env vars to $rc"
}
add_env_block "$HOME/.bashrc"
add_env_block "$HOME/.zshrc"

# ---- 6. Log dir ----
mkdir -p "$CORE_DIR/logs"

# ---- 7. Claude Code auto-setup (detect / install / settings.json) ----
if [ "$SKIP_CLAUDE" -ne 1 ] && [ -x "$SCRIPT_DIR/scripts/setup-claude-code.sh" ]; then
    echo ""
    bash "$SCRIPT_DIR/scripts/setup-claude-code.sh" || {
        echo "[!] Claude Code auto-setup did not finish - see messages above."
        echo "    You can re-run it later: bash \"$SCRIPT_DIR/scripts/setup-claude-code.sh\""
    }
fi

echo ""
echo "==================================================================="
echo "  Installation complete."
echo "==================================================================="
echo ""

# ---- 8. Offer to auto-run api-setup.sh ----
if [ "$SKIP_KEYS" -eq 1 ]; then
    echo "  Keys/provider NOT configured yet (--no-keys)."
    echo "  Next: open a NEW terminal, run 'claude', then type:"
    echo "     /npc-failguard:setup <base-url> <key1 key2 ...>"
elif [ -x "$SCRIPT_DIR/api-setup.sh" ] && [ -t 0 ]; then
    read -r -p "Run ./api-setup.sh now to add your keys + base URL? [Y/n] " ANS
    case "${ANS:-Y}" in
        n|N|no|NO)
            echo "  OK. Run ./api-setup.sh manually when ready."
            echo "  After that, open a NEW terminal and run 'claude'."
            ;;
        *)
            echo ""
            RUNNING_SETUP=1
            exec "$SCRIPT_DIR/api-setup.sh"
            ;;
    esac
else
    echo "  Next step: run ./api-setup.sh"
    echo "  Then open a NEW terminal and run 'claude'."
fi
