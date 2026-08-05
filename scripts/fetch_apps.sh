#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/apps_data.json"
CACHE_MAX_AGE=86400
EMPTY='{"total":0,"apps":[],"updated":"--:--"}'

mkdir -p "$CACHE_DIR"

if [[ "${NOOK_FORCE:-}" != 1 && -f "$CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if (( age < CACHE_MAX_AGE )); then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

resolve_icon() {
    local icon_name="$1"
    [[ "$icon_name" =~ ^/ ]] && [[ -f "$icon_name" ]] && echo "$icon_name" && return

    local dirs=(
        /var/lib/flatpak/exports/share/icons/hicolor/scalable/apps
        /usr/share/icons/hicolor/scalable/apps
        /var/lib/flatpak/exports/share/icons/hicolor/256x256/apps
        /usr/share/icons/hicolor/256x256/apps
        /usr/share/icons/hicolor/128x128/apps
        /usr/share/icons/hicolor/48x48/apps
        /usr/share/pixmaps
    )
    for d in "${dirs[@]}"; do
        for ext in svg png; do
            [[ -f "$d/${icon_name}.${ext}" ]] && echo "$d/${icon_name}.${ext}" && return
        done
    done
}

find_desktop_file() {
    local id="$1"
    local dirs=(
        "$HOME/.local/share/applications"
        /usr/share/applications
        /var/lib/flatpak/exports/share/applications
    )
    for d in "${dirs[@]}"; do
        [[ -f "$d/${id}.desktop" ]] && echo "$d/${id}.desktop" && return
    done
}

entries=""

while IFS= read -r desktop_id; do
    [[ -z "$desktop_id" ]] && continue

    desktop_file=$(find_desktop_file "$desktop_id") || true
    [[ -z "$desktop_file" ]] && continue

    IFS=$'\t' read -r name icon_name < <(awk -F= '
        /^\[Desktop Entry\]/ { ok=1; next }
        /^\[/ { ok=0 }
        ok && /^Name=/ && !n { n=$2 }
        ok && /^Icon=/ && !i { i=$2 }
        END { print n "\t" i }
    ' "$desktop_file")

    icon_path=$(resolve_icon "$icon_name") || true

    entries+=$(printf '%s\t%s\t%s\n' "$name" "${icon_path:-}" "$desktop_id")
    entries+=$'\n'
done < <(yq '.apps[]' "$CONFIG" 2>/dev/null) || {
    if [[ -f "$CACHE_FILE" ]]; then
        cat "$CACHE_FILE"
    else
        echo "$EMPTY"
    fi
    exit 0
}

printf '%s' "$entries" | grep -v '^$' \
    | jq -R 'split("\t") | {name:.[0], icon:.[1], desktop_id:.[2]}' \
    | jq -s --arg now "$(date '+%H:%M')" \
        '{apps: ., total: length, updated: $now}' \
    | tee "$CACHE_FILE"
