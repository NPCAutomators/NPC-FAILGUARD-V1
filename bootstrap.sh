#!/usr/bin/env bash
# NPC FailGuard — one-command installer (curl entrypoint)
#
#   curl -fsSL https://raw.githubusercontent.com/NPC-AUTOMATORS/NPC-FAILGUARD/main/bootstrap.sh | bash
#
# If you publish under a different GitHub org/repo, change GITHUB_REPO below
# (or set NPC_FAILGUARD_GITHUB_REPO) and the matching line in README.md.
set -euo pipefail

# --- identity (edit when the public GitHub repo changes) --------------------
GITHUB_REPO="${NPC_FAILGUARD_GITHUB_REPO:-NPC-AUTOMATORS/NPC-FAILGUARD}"
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
SRC="$(find "$TMP/x" -maxdepth 2 -name install.sh -printf '%h\n' | head -1)"
[ -n "$SRC" ] || {
    echo "[!] install.sh not found inside the archive (wrong tarball?)."
    exit 1
}

if [ -d "$INSTALL_DIR" ]; then
    echo "==> Existing install found — upgrading (keys/state preserved)"
    for f in $KEEP_FILES; do
        [ -f "$INSTALL_DIR/core/$f" ] && cp -p "$INSTALL_DIR/core/$f" "$TMP/x/" || true
    done
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
