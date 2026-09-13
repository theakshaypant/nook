#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="/tmp/nook-pac-chomp.pid"

case "${1:-}" in
    start)
        [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        (while true; do
            eww --config "$SCRIPT_DIR" update pac-mouth=open
            sleep 0.2
            eww --config "$SCRIPT_DIR" update pac-mouth=closed
            sleep 0.2
        done) &
        echo $! > "$PIDFILE"
        eww --config "$SCRIPT_DIR" update pac-deploying=true
        ;;
    stop)
        [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        eww --config "$SCRIPT_DIR" update pac-mouth=open pac-deploying=false
        ;;
esac
