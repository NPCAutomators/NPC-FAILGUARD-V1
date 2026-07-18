#!/usr/bin/env bash
# NPC FailGuard - platform-aware service control.
# Usage: service.sh start|stop|restart|is-active|wait-ready
# Works with: systemd user session (Linux), no-D-Bus fallback (nohup),
# and Windows Task Scheduler via Git Bash (schtasks).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$ROOT_DIR/core"
PORT="${NPC_FAILGUARD_PORT:-8787}"
UNIT="npc-failguard.service"
WIN_TASK="NPC FailGuard"

is_windows() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

have_systemd_bus() {
    command -v systemctl >/dev/null 2>&1 || return 1
    # bus reachable? ("Failed to connect to bus" would exit non-zero here)
    systemctl --user list-units >/dev/null 2>&1 || return 1
    # unit actually installed? otherwise fall back to running main.py directly
    systemctl --user cat "$UNIT" >/dev/null 2>&1
}

venv_python() {
    if is_windows; then
        echo "$CORE_DIR/.venv/Scripts/python.exe"
    else
        echo "$CORE_DIR/.venv/bin/python"
    fi
}

proxy_pid() {
    # PID of a main.py process running from this core dir (no-systemd fallback)
    pgrep -f "$CORE_DIR/main.py" 2>/dev/null | head -1
}

do_start() {
    if is_windows; then
        schtasks //Run //TN "$WIN_TASK" >/dev/null 2>&1 \
            || schtasks /Run /TN "$WIN_TASK" >/dev/null 2>&1 \
            || { echo "cannot start task '$WIN_TASK' - run install.ps1 first"; return 1; }
    elif have_systemd_bus; then
        systemctl --user start "$UNIT"
    else
        if [ -n "$(proxy_pid)" ]; then
            echo "already running (pid $(proxy_pid), no systemd bus)"
            return 0
        fi
        nohup "$(venv_python)" "$CORE_DIR/main.py" \
            >>"$CORE_DIR/logs/daemon.out" 2>&1 &
        echo "started directly (pid $!, no systemd bus available)"
    fi
}

do_stop() {
    if is_windows; then
        schtasks //End //TN "$WIN_TASK" >/dev/null 2>&1 \
            || schtasks /End /TN "$WIN_TASK" >/dev/null 2>&1 || true
        # schtasks /End doesn't always kill children; be sure
        local pid; pid="$(proxy_pid)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    elif have_systemd_bus; then
        systemctl --user stop "$UNIT"
    else
        local pid; pid="$(proxy_pid)"
        if [ -n "$pid" ]; then kill "$pid"; echo "stopped pid $pid"; fi
    fi
}

do_is_active() {
    if is_windows || ! have_systemd_bus; then
        if [ -n "$(proxy_pid)" ]; then echo "active"; return 0; fi
        # fall back to a port probe (pgrep may be unavailable on Git Bash)
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/_npc-failguard/status" >/dev/null 2>&1; then
            echo "active"; return 0
        fi
        echo "inactive"; return 1
    fi
    systemctl --user is-active "$UNIT"
}

do_wait_ready() {
    # Poll the status endpoint for up to 10s (replaces the old sleep-2 race)
    for _ in $(seq 1 20); do
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/_npc-failguard/status" >/dev/null 2>&1; then
            echo "ready"
            return 0
        fi
        sleep 0.5
    done
    echo "not-ready"
    return 1
}

case "${1:-}" in
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_stop; sleep 1; do_start ;;
    is-active) do_is_active ;;
    wait-ready) do_wait_ready ;;
    *) echo "usage: $0 start|stop|restart|is-active|wait-ready"; exit 2 ;;
esac
