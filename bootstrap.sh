#!/usr/bin/env bash
# NPC FailGuard — one-command installer (curl entrypoint)
#
#   curl -fsSL https://raw.githubusercontent.com/NPCAutomators/NPC-FAILGUARD-V1/main/bootstrap.sh | bash
#
# If you publish under a different GitHub org/repo, change GITHUB_REPO below
# (or set NPC_FAILGUARD_GITHUB_REPO) and the matching line in README.md.
set -euo pipefail

# --- identity (edit when the public GitHub repo changes) --------------------
GITHUB_REPO="${NPC_FAILGUARD_GITHUB_REPO:-NPCAutomators/NPC-FAILGUARD-V1}"
GITHUB_BRANCH="${NPC_FAILGUARD_GITHUB_BRANCH:-main}"
# ---------------------------------------------------------------------------

TARBALL_URL="${NPC_FAILGUARD_TARBALL:-https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz}"
INSTALL_DIR="${NPC_FAILGUARD_INSTALL_DIR:-$HOME/.npc-failguard/app}"
KEEP_FILES="keys.json state.json provider.json api.txt stats.json pricing.json"

echo "==> NPC FailGuard bootstrap"
echo "    source: github.com/${GITHUB_REPO}@${GITHUB_BRANCH}"
for dep in curl tar python3; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "[!] Missing dependency: $dep — install it and re-run."
        exit 1
    }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading..."
curl -fsSL "$TARBALL_URL" -o "$TMP/app.tar.gz"
mkdir -p "$TMP/x"
tar -xzf "$TMP/app.tar.gz" -C "$TMP/x"
# portable (no GNU find -printf): locate install.sh, then take its dir
INSTALL_SH="$(find "$TMP/x" -maxdepth 2 -name install.sh 2>/dev/null | head -1)"
[ -n "$INSTALL_SH" ] || {
    echo "[!] install.sh not found inside the archive (wrong tarball?)."
    exit 1
}
SRC="$(dirname "$INSTALL_SH")"

if [ -d "$INSTALL_DIR" ]; then
    echo "==> Existing install found — upgrading (keys/state preserved)"
    for f in $KEEP_FILES; do
        [ -f "$INSTALL_DIR/core/$f" ] && cp -p "$INSTALL_DIR/core/$f" "$TMP/x/" || true
    done
    # stop the old daemon so the reinstall starts the NEW code (systemd
    # restarts it itself; this covers the no-systemd/nohup fallback)
    pkill -f "$INSTALL_DIR/core/main.py" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$SRC" "$INSTALL_DIR"
for f in $KEEP_FILES; do
    [ -f "$TMP/x/$f" ] && mv "$TMP/x/$f" "$INSTALL_DIR/core/$f" || true
done

echo "==> Running installer..."
bash "$INSTALL_DIR/install.sh" --no-keys < /dev/null

echo ""
echo "==================================================================="
echo "  Bootstrap complete."
echo "  1. Open a NEW terminal and run:  claude"
echo "  2. Inside Claude, type:"
echo "     /npc-failguard:setup <base-url> <key1 key2 ... or /path/keys.txt>"
echo "==================================================================="
