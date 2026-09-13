#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"

cmd=$(yq -r '.pac.deploy_command // ""' "$CONFIG" 2>/dev/null) || cmd=""
if [[ -n "$cmd" ]]; then
    eval "$cmd"
fi
