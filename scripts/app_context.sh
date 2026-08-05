#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
desktop_id="$1"

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

desktop_file=$(find_desktop_file "$desktop_id") || true
[[ -z "${desktop_file:-}" ]] && exit 0

IFS=$'\t' read -r app_name action_ids < <(awk '
    /^\[Desktop Entry\]/ { ok=1; next }
    /^\[/ { ok=0 }
    ok && /^Name=/ && !n { n=substr($0,6) }
    ok && /^Actions=/ && !a { a=substr($0,9) }
    END { print n "\t" a }
' "$desktop_file")
action_ids=$(tr -d ' ' <<< "$action_ids")

[[ -z "$action_ids" ]] && exit 0

CONFIG="$SCRIPT_DIR/config.yaml"
idx=0; i=0
while IFS= read -r aid; do
    [[ "$aid" == "$desktop_id" ]] && idx=$i
    i=$((i + 1))
done < <(yq '.apps[]' "$CONFIG" 2>/dev/null)
total=$(( i > 0 ? i : 1 ))
# dock=440px, card padding=30px, row padding=20px → row=390px
# app center from screen right = 440 + 440 - 25 - 390*(2*idx+1)/(2*total)
# popup (220px) margin-right = center - 110
margin_right=$(( 745 - 390 * (2 * idx + 1) / (2 * total) ))

json=$(awk '
    /^\[Desktop Action / {
        if (ok && n && e) print n "\t" e
        ok=1; n=""; e=""; next
    }
    /^\[/ { if (ok && n && e) print n "\t" e; ok=0 }
    ok && /^Name=/ && !n { n=substr($0,6) }
    ok && /^Exec=/ && !e { e=substr($0,6) }
    END { if (ok && n && e) print n "\t" e }
' "$desktop_file" \
    | jq -R 'split("\t") | {name: .[0], exec: (.[1] | gsub(" %[uUfF]$"; ""))}' \
    | jq -sc --arg name "$app_name" --argjson mr "$margin_right" \
        '{name: $name, actions: ., margin_right: $mr}')

eww --config "$SCRIPT_DIR" update "app-context=$json"
eww --config "$SCRIPT_DIR" open app-context-menu 2>/dev/null || true
