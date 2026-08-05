#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
NAV_FILE="/tmp/nook-calendar-nav"
EXPAND_FILE="/tmp/nook-calendar-expand"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/calendar_data.json"
RAW_MAX_AGE=300
CALLIST_CACHE="$CACHE_DIR/calendar_list.json"
CALLIST_MAX_AGE=86400

[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

EMPTY='{"nav_date":"","date_label":"","is_today":true,"all_day":[],"has_past":0,"alerts":[],"has_alerts":false,"events":[],"total":0,"updated":"--:--"}'

if [[ ! -f "$CONFIG" ]]; then echo "$EMPTY"; exit 0; fi

creds_file=$(sed -n '/^calendar:/,/^[a-z]/{s/^ *credentials_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
token_file=$(sed -n '/^calendar:/,/^[a-z]/{s/^ *token_file: *"\(.*\)"/\1/p}' "$CONFIG" | head -1)
creds_file="${creds_file/#\~/$HOME}"
token_file="${token_file/#\~/$HOME}"

if [[ -z "$creds_file" || -z "$token_file" || ! -f "$creds_file" || ! -f "$token_file" ]]; then
    echo "$EMPTY"; exit 0
fi

mapfile -t cal_ids < <(sed -n '/^calendar:/,/^[a-z]/{/^ *- *id:/s/^ *- *id: *"\([^"]*\)"/\1/p}' "$CONFIG")
mapfile -t cal_names < <(sed -n '/^calendar:/,/^[a-z]/{/^ *name:/s/^ *name: *"\([^"]*\)"/\1/p}' "$CONFIG")

if [[ ${#cal_ids[@]} -eq 0 ]]; then echo "$EMPTY"; exit 0; fi

nav_offset=0
if [[ -f "$NAV_FILE" ]]; then
    nav_offset=$(cat "$NAV_FILE" 2>/dev/null || echo 0)
    [[ "$nav_offset" =~ ^-?[0-9]+$ ]] || nav_offset=0
fi

IFS='|' read -r target_date date_label <<< "$(date -d "$nav_offset days" '+%Y-%m-%d|%a, %b %-d')"
is_today=false
[[ "$nav_offset" -eq 0 ]] && is_today=true

RAW_CACHE="$CACHE_DIR/calendar_raw_${target_date}.json"

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

resolve_calendar_ids() {
    local token="$1"
    need_callist=true
    if [[ -f "$CALLIST_CACHE" ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$CALLIST_CACHE") ))
        (( age < CALLIST_MAX_AGE )) && need_callist=false
    fi

    if [[ "$need_callist" == true ]]; then
        callist=$(curl -s --connect-timeout 5 --max-time 10 \
            "https://www.googleapis.com/calendar/v3/users/me/calendarList" \
            -H "Authorization: Bearer $token" 2>/dev/null) || return 1
        echo "$callist" | jq -e '.error' &>/dev/null && return 1
        echo "$callist" | jq -c '[.items[] | {id: .id, name: .summary}]' > "$CALLIST_CACHE"
    fi

    for i in "${!cal_ids[@]}"; do
        cfg_id="${cal_ids[$i]}"
        resolved=$(jq -r --arg q "$cfg_id" \
            '.[] | select(.id == $q or .name == $q) | .id' "$CALLIST_CACHE" | head -1)
        if [[ -n "$resolved" ]]; then
            cal_ids[$i]="$resolved"
        fi
    done
}

need_refresh=true
if [[ -f "$RAW_CACHE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$RAW_CACHE") ))
    (( age < RAW_MAX_AGE )) && need_refresh=false
fi

if [[ "$need_refresh" == true ]]; then
    find "$CACHE_DIR" -name "calendar_raw_*.json" -mtime +1 -delete 2>/dev/null || true

    access_token=$(get_access_token) || {
        if [[ -f "$CACHE_FILE" ]]; then cat "$CACHE_FILE"; else echo "$EMPTY"; fi
        exit 0
    }

    resolve_calendar_ids "$access_token" || true

    local_tz="${TZ:-$(readlink -f /etc/localtime | sed 's|.*/zoneinfo/||')}"
    tz_offset=$(date -d "$target_date" '+%:z')
    time_min="${target_date}T00:00:00${tz_offset}"
    time_max="${target_date}T23:59:59${tz_offset}"

    all_events="[]"
    for i in "${!cal_ids[@]}"; do
        cal_id="${cal_ids[$i]}"
        cal_name="${cal_names[$i]:-$cal_id}"
        encoded_id=$(printf '%s' "$cal_id" | jq -Rr @uri)

        response=$(curl -s --connect-timeout 5 --max-time 10 -G \
            "https://www.googleapis.com/calendar/v3/calendars/${encoded_id}/events" \
            --data-urlencode "timeMin=${time_min}" \
            --data-urlencode "timeMax=${time_max}" \
            --data-urlencode "timeZone=${local_tz}" \
            -d "singleEvents=true" \
            -d "orderBy=startTime" \
            -d "showDeleted=false" \
            -H "Authorization: Bearer $access_token" 2>/dev/null) || continue

        echo "$response" | jq -e '.error' &>/dev/null && continue

        cal_events=$(echo "$response" | jq -c --arg cal "$cal_name" \
            '[(.items // [])[] | {
                title: (.summary // "No title"),
                start_dt: (.start.dateTime // ""),
                start_date: (.start.date // ""),
                end_dt: (.end.dateTime // ""),
                end_date: (.end.date // ""),
                calendar: $cal,
                meeting_link: (([(.conferenceData.entryPoints // [])[] | select(.entryPointType == "video") | .uri][0]) // .hangoutLink // ""),
                attachments: [(.attachments // [])[] | {name: .title, url: .fileUrl}],
                event_url: (.htmlLink // ""),
                ical_uid: (.iCalUID // .id)
            }]' 2>/dev/null) || continue

        all_events=$(jq -c '. + $new' --argjson new "$cal_events" <<< "$all_events")
    done

    jq -n --arg date "$target_date" --argjson events "$all_events" \
        '{date: $date, events: $events}' > "$RAW_CACHE"
fi

now=$(date '+%H:%M')

expanded_id=""
if [[ -f "$EXPAND_FILE" ]]; then
    expanded_id=$(cat "$EXPAND_FILE" 2>/dev/null || echo "")
fi

jq -c \
    --arg date_label "$date_label" \
    --arg nav_date "$target_date" \
    --argjson is_today "$is_today" \
    --arg now "$now" \
    --arg expanded_id "$expanded_id" \
    '
    .events |
    group_by(.ical_uid) | map(
        if length > 1 then
            ([.[].calendar] | unique) as $cals |
            .[0] + {calendar: (if ($cals | length) > 1 then ($cals | length | tostring) else $cals[0] end)}
        else .[0] end
    ) |
    (map(select(.start_date != "")) | [.[] | {
        title: .title, calendar: .calendar, event_url: .event_url
    }]) as $all_day |
    def to_min: split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber);
    ($now | to_min) as $now_min |
    (map(select(.start_dt != "")) | sort_by(.start_dt) | [.[] |
        (.start_dt | split("T")[1][0:5]) as $start |
        (.end_dt | split("T")[1][0:5]) as $end |
        (.ical_uid | gsub("[^a-zA-Z0-9]"; "_")) as $eid |
        ($start | to_min) as $start_min |
        {
            id: $eid,
            title: .title, start: $start, end: $end,
            calendar: .calendar,
            meeting_link: (.meeting_link // ""),
            has_meeting: ((.meeting_link // "") != ""),
            attachments: (.attachments // []),
            has_attachments: ((.attachments | length) > 0),
            event_url: (.event_url // ""),
            is_past: ($is_today and $end <= $now),
            in_progress: ($is_today and $start <= $now and $end > $now),
            starting_soon: ($is_today and $start_min > $now_min and ($start_min - $now_min) <= 5),
            expanded: ($eid == $expanded_id)
        }
    ]) as $timed |
    ($timed | map(select(.is_past)) | length) as $past_count |
    ($timed | map(select(.is_past | not))) as $upcoming |
    [($timed[] | select(.in_progress) | {title, start, meeting_link, has_meeting, status: "now", badge: "NOW"}),
     ($timed[] | select(.starting_soon) |
        ((.start | to_min) - $now_min) as $mins |
        {title, start, meeting_link, has_meeting, status: "soon", badge: "in \($mins)m"})] as $alerts |
    {
        nav_date: $nav_date, date_label: $date_label, is_today: $is_today,
        all_day: $all_day, has_past: $past_count,
        alerts: $alerts, has_alerts: (($alerts | length) > 0),
        events: [$upcoming[] | del(.is_past, .starting_soon)],
        total: (($all_day | length) + ($timed | length)),
        updated: $now
    }' "$RAW_CACHE" | tee "$CACHE_FILE"
