#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/gmail_data.json"
CACHE_MAX_AGE=600

mkdir -p "$CACHE_DIR"

EMPTY='{"total":0,"items":[],"updated":"--:--"}'

if [[ -f "$CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if (( age < CACHE_MAX_AGE )); then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

fallback_or_exit() {
    if [[ -f "$CACHE_FILE" ]]; then cat "$CACHE_FILE"; else echo "$EMPTY"; fi
    exit 0
}

if [[ ! -f "$CONFIG" ]]; then echo "$EMPTY"; exit 0; fi

creds_file=$(sed -n '/^gmail:/,/^[a-z]/{s/^ *credentials_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
token_file=$(sed -n '/^gmail:/,/^[a-z]/{s/^ *token_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
creds_file="${creds_file/#\~/$HOME}"
token_file="${token_file/#\~/$HOME}"

if [[ -z "$creds_file" || -z "$token_file" || ! -f "$creds_file" || ! -f "$token_file" ]]; then
    echo "$EMPTY"; exit 0
fi

get_access_token() {
    local access_token refresh_token expiry
    IFS=$'\t' read -r access_token refresh_token expiry < <(
        jq -r '[.access_token, .refresh_token, .expiry] | @tsv' "$token_file"
    )

    local expiry_epoch current_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
    current_epoch=$(date +%s)

    if (( current_epoch < expiry_epoch - 60 )); then
        echo "$access_token"
        return 0
    fi

    local client_id client_secret
    client_id=$(jq -r '.installed.client_id' "$creds_file")
    client_secret=$(jq -r '.installed.client_secret' "$creds_file")

    local response new_token expires_in new_expiry
    response=$(curl -s --connect-timeout 5 --max-time 10 -X POST "https://oauth2.googleapis.com/token" \
        -d "client_id=$client_id" \
        -d "client_secret=$client_secret" \
        -d "refresh_token=$refresh_token" \
        -d "grant_type=refresh_token") || return 1

    new_token=$(echo "$response" | jq -r '.access_token // empty')
    [[ -z "$new_token" ]] && return 1

    expires_in=$(echo "$response" | jq -r '.expires_in // 3600')
    new_expiry=$(date -d "+${expires_in} seconds" -Iseconds)

    local new_rt
    new_rt=$(echo "$response" | jq -r '.refresh_token // empty')

    jq --arg at "$new_token" --arg exp "$new_expiry" --arg rt "${new_rt:-$refresh_token}" \
        '.access_token = $at | .expiry = $exp | .refresh_token = $rt' "$token_file" > "${token_file}.tmp" && \
        mv "${token_file}.tmp" "$token_file"

    echo "$new_token"
}

access_token=$(get_access_token) || fallback_or_exit

list_response=$(curl -s --connect-timeout 5 --max-time 10 -G \
    "https://gmail.googleapis.com/gmail/v1/users/me/messages" \
    --data-urlencode "q=is:unread in:inbox" \
    -d "maxResults=20" \
    -H "Authorization: Bearer $access_token" 2>/dev/null) || fallback_or_exit

echo "$list_response" | jq -e '.error' &>/dev/null && fallback_or_exit

msg_ids=$(echo "$list_response" | jq -r '.messages[]?.id // empty')

if [[ -z "$msg_ids" ]]; then
    jq -n --arg now "$(date '+%H:%M')" '{total: 0, items: [], updated: $now}' | tee "$CACHE_FILE"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

while IFS= read -r msg_id; do
    [[ -z "$msg_id" ]] && continue
    curl -s --connect-timeout 5 --max-time 10 -G \
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/${msg_id}" \
        --data-urlencode "format=metadata" \
        --data-urlencode "metadataHeaders=From" \
        --data-urlencode "metadataHeaders=Subject" \
        --data-urlencode "metadataHeaders=Date" \
        -H "Authorization: Bearer $access_token" \
        > "$tmpdir/${msg_id}.json" 2>/dev/null &
done <<< "$msg_ids"
wait

# Collect valid responses (skip errors), one per line
for f in "$tmpdir"/*.json; do
    [[ ! -s "$f" ]] && continue
    jq -e '.error' "$f" &>/dev/null && continue
    jq -c '.' "$f"
done > "$tmpdir/all.jsonl"

tz=$(date +%z)
tz_off=$(( ${tz:0:3} * 3600 + ${tz:3:2} * 60 ))

jq -s -c \
    --argjson tz "$tz_off" \
    --arg now "$(date '+%H:%M')" \
    '
    def decode_html: gsub("&#39;"; "'"'"'") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&amp;"; "&");
    {
        total: length,
        items: [sort_by(.internalDate | tonumber) | reverse[] |
            (.payload.headers | map({(.name): .value}) | add) as $h |
            ($h.From // "Unknown") as $raw_from |
            ($raw_from | capture("^(?<name>.+?)\\s*<(?<email>.+)>$") //
                {name: ($raw_from | split("@")[0]), email: $raw_from}) as $from |
            {
                from_name: $from.name,
                subject: ($h.Subject // "(no subject)"),
                snippet: (.snippet // "" | decode_html),
                time: (.internalDate | tonumber / 1000 + $tz | strftime("%H:%M")),
                url: ("https://mail.google.com/mail/u/0/#inbox/" + .id)
            }
        ],
        updated: $now
    }' "$tmpdir/all.jsonl" | tee "$CACHE_FILE"
