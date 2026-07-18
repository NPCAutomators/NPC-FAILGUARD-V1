#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PROVIDER_JSON="$CORE_DIR/provider.json"
PORT="${NPC_FAILGUARD_PORT:-8787}"

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

echo "==> NPC FailGuard: keys + base URL setup"
echo ""

usage() {
    cat <<EOF
Usage: ./api-setup.sh [--keys-file <path>] [--base-url <url>] [--yes]

Without flags, prompts interactively (for terminal users).
With flags, runs fully non-interactively (for Claude Code / scripts):
  --keys-file <path>   text file with one API key per line
  --base-url <url>     provider base URL (http:// or https://)
  --yes                don't ask for confirmation
EOF
}

KEYS_FILE=""
BASE_URL=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keys-file) KEYS_FILE="${2:-}"; shift 2 ;;
        --base-url)  BASE_URL="${2:-}"; shift 2 ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *) echo "!! Unknown option: $1"; usage; exit 2 ;;
    esac
done

# ---- 0. core/ must exist ----
if [ ! -d "$CORE_DIR" ]; then
    echo "!! core/ folder missing. Run ./install.sh first."
    exit 1
fi

# ---- 1. Keys file: flag or interactive prompt ----
if [ -z "$KEYS_FILE" ]; then
    if [ ! -t 0 ]; then
        echo "!! No --keys-file given and no interactive terminal."
        echo "   Non-interactive usage: ./api-setup.sh --keys-file <path> --base-url <url> --yes"
        exit 1
    fi
    while true; do
        printf "Path to your API keys file (one key per line): "
        if ! IFS= read -r KEYS_FILE; then
            echo "!! No input received."
            exit 1
        fi
        KEYS_FILE="${KEYS_FILE#"${KEYS_FILE%%[![:space:]]*}"}"
        KEYS_FILE="${KEYS_FILE%"${KEYS_FILE##*[![:space:]]}"}"
        KEYS_FILE="${KEYS_FILE/#\~/$HOME}"
        KEYS_FILE="${KEYS_FILE#\'}"; KEYS_FILE="${KEYS_FILE%\'}"
        KEYS_FILE="${KEYS_FILE#\"}"; KEYS_FILE="${KEYS_FILE%\"}"
        [ -z "$KEYS_FILE" ] && { echo "!! Empty path. Try again."; continue; }
        [ ! -f "$KEYS_FILE" ] && { echo "!! File not found: $KEYS_FILE"; continue; }
        break
    done
else
    KEYS_FILE="${KEYS_FILE/#\~/$HOME}"
    if [ ! -f "$KEYS_FILE" ]; then
        echo "!! File not found: $KEYS_FILE"
        exit 1
    fi
fi

# ---- 2. Base URL: flag or interactive prompt ----
if [ -z "$BASE_URL" ]; then
    if [ ! -t 0 ]; then
        echo "!! No --base-url given and no interactive terminal."
        exit 1
    fi
    while true; do
        printf "Base URL (e.g. https://api.example.com): "
        if ! IFS= read -r BASE_URL; then
            echo "!! No input received."
            exit 1
        fi
        BASE_URL="${BASE_URL%/}"
        [[ "$BASE_URL" =~ ^https?:// ]] && break
        echo "!! URL must start with http:// or https://. Try again."
    done
else
    BASE_URL="${BASE_URL%/}"
    if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
        echo "!! URL must start with http:// or https://"
        exit 1
    fi
fi

# ---- 3. Confirm replacement if keys already exist ----
if [ -f "$CORE_DIR/keys.json" ] && [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
    read -r -p "Existing keys will be REPLACED and state reset. Continue? [y/N] " ans
    case "$ans" in
        [Yy]*) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

# ---- 4. Replace key set + provider via manage.py (single source of truth) ----
VENV_PY="$CORE_DIR/.venv/bin/python"
[ -x "$VENV_PY" ] || VENV_PY="$CORE_DIR/.venv/Scripts/python.exe"
[ -x "$VENV_PY" ] || VENV_PY="python3"

echo "==> Importing keys from $KEYS_FILE"
"$VENV_PY" "$CORE_DIR/manage.py" replace-txt "$KEYS_FILE"
"$VENV_PY" "$CORE_DIR/manage.py" set-base-url "$BASE_URL"

# ---- 5. Restart daemon (platform-aware) ----
echo ""
echo "==> Restarting daemon"
bash "$SCRIPT_DIR/scripts/service.sh" restart
if [ "$(bash "$SCRIPT_DIR/scripts/service.sh" wait-ready)" != "ready" ]; then
    echo "!! Daemon did not come up on port $PORT."
    echo "   Check: journalctl --user -u npc-failguard.service -n 30"
    exit 1
fi
echo "[✓] Daemon running"

# ---- 6. Health check (uses a tiny amount of provider credit) ----
echo ""
echo "==> Health check..."
HEALTH_TMP="$(mktemp)"
HTTP_CODE=$(curl -s -o "$HEALTH_TMP" -w "%{http_code}" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:$PORT/v1/messages" || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[✓] Health check passed (HTTP 200)"
elif [ "$HTTP_CODE" = "400" ]; then
    echo "[!] HTTP 400 — model may not exist on this provider."
    echo "    That's fine; proxy is running. Claude Code will send its own model choice."
else
    echo "[!] Health check returned HTTP $HTTP_CODE"
    echo "    Response body:"
    cat "$HEALTH_TMP"
    echo ""
    echo "    Check logs: journalctl --user -u npc-failguard.service -n 30"
fi
rm -f "$HEALTH_TMP"

echo ""
echo "==================================================================="
echo "  Setup complete."
echo ""
echo "  Open a new terminal and run 'claude' to start using it."
echo "  Check status:  curl -s http://127.0.0.1:$PORT/_npc-failguard/status | python3 -m json.tool"
echo "  Live logs:     journalctl --user -u npc-failguard.service -f"
echo "==================================================================="
