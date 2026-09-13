#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
EMPTY='{"deploy_command":"","ghosts":{"blinky":{"name":"","url":""},"inky":{"name":"","url":""},"pinky":{"name":"","url":""},"clyde":{"name":"","url":""}},"links":[],"total":0}'

if ! command -v yq &>/dev/null; then
    echo "$EMPTY"
    exit 0
fi

deploy_command=$(yq -r '.pac.deploy_command // ""' "$CONFIG" 2>/dev/null) || deploy_command=""
ghosts_json=$(yq -o=json '.pac.ghosts // {}' "$CONFIG" 2>/dev/null) || ghosts_json="{}"
links_json=$(yq -o=json '.pac.links // []' "$CONFIG" 2>/dev/null) || links_json="[]"
total=$(printf '%s' "$links_json" | jq 'length')

jq -n \
    --arg deploy "$deploy_command" \
    --argjson ghosts "$ghosts_json" \
    --argjson links "$links_json" \
    --argjson total "$total" \
    '{deploy_command: $deploy, ghosts: $ghosts, links: $links, total: $total}'
