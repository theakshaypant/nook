#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
widget="$1"
fetch="$SCRIPT_DIR/scripts/fetch_${widget}.sh"

[[ -x "$fetch" ]] || exit 1

data=$(NOOK_FORCE=1 "$fetch")
eww --config "$SCRIPT_DIR" update "${widget}-data=$data"
