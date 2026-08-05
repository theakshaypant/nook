#!/usr/bin/env bash
# Usage: ./nook.sh start|stop
# Requires: eww in PATH (built with --features=x11)
#   start — kills any running instance, then opens all widgets
#   stop  — kills eww and closes all widgets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINDOWS=(github stats-gauges stats-disk stats-net stats-temp watch calendar)

command -v eww &>/dev/null || { echo "eww not found in PATH"; exit 1; }

export GDK_BACKEND=x11

case "${1:-}" in
    start)
        eww --config "$SCRIPT_DIR" kill 2>/dev/null || true
        sleep 0.5
        for w in "${WINDOWS[@]}"; do
            eww --config "$SCRIPT_DIR" open "$w"
        done
        ;;
    stop)
        eww --config "$SCRIPT_DIR" kill 2>/dev/null || true
        ;;
    *)
        echo "Usage: $(basename "$0") start|stop"
        exit 1
        ;;
esac
