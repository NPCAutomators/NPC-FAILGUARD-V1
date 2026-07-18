#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- error/exit UX: show what failed, never slam the window shut ----
FAILED_CMD=""
trap 'FAILED_CMD="$BASH_COMMAND at line $LINENO"' ERR
finish() {
    code=$?
    [ "${RUNNING_INSTALL:-0}" = "1" ] && exit $code
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

echo "==> NPC FailGuard: system requirements installer"
echo ""

# ---- 1. Must NOT be run as root (we'll sudo where needed) ----
if [ "$(id -u)" -eq 0 ]; then
    echo "!! Do not run this script as root. Run as your normal user; it will sudo where needed."
    exit 1
fi

# ---- 2. sudo available? ----
if ! command -v sudo >/dev/null 2>&1; then
    echo "!! 'sudo' not installed. Install it first, or run system package steps manually."
    exit 1
fi

# ---- 3. Detect distro ----
DISTRO=""
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
else
    echo "!! Cannot detect distro (/etc/os-release missing)."
    exit 1
fi
echo "==> Detected distro: $DISTRO"

install_apt() {
    echo "==> Using apt (Debian/Ubuntu family)"
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        python3 python3-pip curl ca-certificates systemd
}

install_dnf() {
    echo "==> Using dnf (Fedora / RHEL family)"
    sudo dnf install -y python3 python3-pip curl ca-certificates systemd
}

install_pacman() {
    echo "==> Using pacman (Arch family)"
    sudo pacman -Sy --noconfirm python python-pip curl ca-certificates systemd
}

install_zypper() {
    echo "==> Using zypper (openSUSE)"
    sudo zypper --non-interactive install python3 python3-pip curl ca-certificates systemd
}

case "$DISTRO" in
    ubuntu|debian|linuxmint|pop|raspbian|kali)
        install_apt
        ;;
    fedora|rhel|centos|rocky|almalinux)
        install_dnf
        ;;
    arch|manjaro|endeavouros|artix)
        install_pacman
        ;;
    opensuse*|suse|sles)
        install_zypper
        ;;
    *)
        case "$DISTRO_LIKE" in
            *debian*) install_apt ;;
            *fedora*|*rhel*) install_dnf ;;
            *arch*) install_pacman ;;
            *suse*) install_zypper ;;
            *)
                echo "!! Unsupported distro: $DISTRO"
                echo "   Install manually: python3, python3-pip, curl, ca-certificates, systemd"
                echo "   Then re-run ./install.sh."
                exit 1
                ;;
        esac
        ;;
esac

echo "[✓] System packages installed"

# ---- 4. Verify Python version ----
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    echo "!! Python $PY_VER is too old (need 3.10+). Your distro may need a newer python3 package."
    exit 1
fi
echo "[✓] Python $PY_VER"

# ---- 5. Enable systemd user lingering (daemon survives after logout) ----
if command -v loginctl >/dev/null 2>&1; then
    if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        echo "[✓] User lingering already enabled"
    else
        sudo loginctl enable-linger "$USER"
        echo "[✓] Enabled systemd user lingering (daemon will run even after logout)"
    fi
else
    echo "[!] loginctl not found — daemon may stop when you log out. Not fatal for desktop use."
fi

# ---- 6. Ensure ~/.local/bin in PATH (for uv) ----
if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$RC" ] || continue
        if ! grep -qF 'HOME/.local/bin' "$RC"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
            echo "[✓] Added ~/.local/bin to PATH in $RC"
        fi
    done
    export PATH="$HOME/.local/bin:$PATH"
fi

echo ""
echo "==================================================================="
echo "  System requirements installed."
echo ""

# ---- 7. Offer to auto-run install.sh ----
if [ -x "$SCRIPT_DIR/install.sh" ] && [ -t 0 ]; then
    read -r -p "  Run ./install.sh now? [Y/n] " ANS
    case "${ANS:-Y}" in
        n|N|no|NO)
            echo "  OK. Run ./install.sh manually when ready, then ./api-setup.sh."
            ;;
        *)
            echo ""
            RUNNING_INSTALL=1
            exec "$SCRIPT_DIR/install.sh"
            ;;
    esac
else
    echo "  Next step: run ./install.sh"
fi
echo "==================================================================="
