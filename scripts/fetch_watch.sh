#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
CUSTOM_FILE="/tmp/nook-watch-custom"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/watch_data.json"

mkdir -p "$CACHE_DIR"

empty='{"local":{"time":"--:--","date":"","tz":"","editing":false},"editing":false,"editing_tz":"","editing_city":"","cities":[]}'

if [[ ! -f "$CONFIG" ]]; then
    echo "$empty"
    exit 0
fi

editing=false
editing_tz=""
custom_time=""

if [[ -f "$CUSTOM_FILE" ]]; then
    editing=true
    content=$(cat "$CUSTOM_FILE" 2>/dev/null || true)
    editing_tz="${content%% *}"
    rest="${content#* }"
    if [[ "$rest" != "$content" ]] && [[ "$rest" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        custom_time="$rest"
    fi
fi

# Freeze output when editing but no time entered yet
if [[ "$editing" == true && -z "$custom_time" && -f "$CACHE_FILE" ]]; then
    jq --arg tz "$editing_tz" \
        '.editing = true | .editing_tz = $tz |
         .local.editing = ($tz == "local") |
         .editing_city = ((.cities[] | select(.tz == $tz)) // {names: "", flags: "", count: 0} | if .count > 1 then .flags else "\(.flags) \(.names)" end) |
         .cities = [.cities[] | .editing = (.tz == $tz)]' \
        "$CACHE_FILE"
    exit 0
fi

offset_to_mins() {
    local o="$1"
    local sign="${o:0:1}"
    local hh="${o:1:2}"
    local mm="${o:3:2}"
    local mins=$(( 10#$hh * 60 + 10#$mm ))
    [[ "$sign" == "-" ]] && mins=$(( -mins ))
    echo "$mins"
}

local_utc_offset=$(date '+%z')
local_offset_mins=$(offset_to_mins "$local_utc_offset")

mapfile -t names < <(sed -n 's/^ *- *name: *"\([^"]*\)"/\1/p' "$CONFIG")
mapfile -t timezones < <(sed -n 's/^ *timezone: *"\([^"]*\)"/\1/p' "$CONFIG")
mapfile -t flags < <(sed -n 's/^ *flag: *"\(.*\)"/\1/p' "$CONFIG")

base_offset_mins="$local_offset_mins"
base_hh=""
base_mm=""

if [[ -n "$custom_time" ]]; then
    base_hh="${custom_time%%:*}"
    base_mm="${custom_time##*:}"
    if [[ "$editing_tz" != "local" ]]; then
        tz_utc_offset=$(TZ="${editing_tz%%,*}" date '+%z' 2>/dev/null) || tz_utc_offset="+0000"
        base_offset_mins=$(offset_to_mins "$tz_utc_offset")
    fi
fi

compute_time() {
    local target_offset_mins="$1"
    local diff=$(( target_offset_mins - base_offset_mins ))
    local total=$(( 10#$base_hh * 60 + 10#$base_mm + diff ))
    while (( total < 0 )); do total=$(( total + 1440 )); done
    total=$(( total % 1440 ))
    printf '%02d:%02d' "$(( total / 60 ))" "$(( total % 60 ))"
}

local_dateinfo=$(date '+%H:%M|%a, %b %-d|%Z')
if [[ -n "$custom_time" ]]; then
    local_time=$(compute_time "$local_offset_mins")
else
    local_time="${local_dateinfo%%|*}"
fi
local_dateinfo="${local_dateinfo#*|}"
local_date="${local_dateinfo%%|*}"
local_tz="${local_dateinfo#*|}"
local_editing=false
[[ "$editing_tz" == "local" ]] && local_editing=true

# Build ungrouped city array
cities_raw="["
for i in "${!names[@]}"; do
    name="${names[$i]}"
    tz="${timezones[$i]:-UTC}"
    flag="${flags[$i]:-}"

    city_dateinfo=$(TZ="$tz" date '+%z|%H:%M|%-H' 2>/dev/null) || city_dateinfo="+0000|--:--|12"
    city_utc_offset="${city_dateinfo%%|*}"
    city_offset_mins=$(offset_to_mins "$city_utc_offset")
    diff_mins=$(( city_offset_mins - local_offset_mins ))

    if [[ -n "$custom_time" ]]; then
        city_time=$(compute_time "$city_offset_mins")
        city_hour=${city_time%%:*}
        city_hour=$(( 10#$city_hour ))
    else
        city_dateinfo="${city_dateinfo#*|}"
        city_time="${city_dateinfo%%|*}"
        city_hour="${city_dateinfo#*|}"
    fi

    if (( diff_mins == 0 )); then
        offset_str="same"
    else
        sign="+"
        abs_mins=$diff_mins
        if (( diff_mins < 0 )); then
            sign="-"
            abs_mins=$(( -diff_mins ))
        fi
        h=$(( abs_mins / 60 ))
        m=$(( abs_mins % 60 ))
        if (( m == 0 )); then
            offset_str="${sign}${h}h"
        elif (( m == 30 )); then
            offset_str="${sign}${h}.5h"
        else
            offset_str="${sign}${h}:$(printf '%02d' "$m")"
        fi
    fi

    is_night=false
    if (( city_hour >= 21 || city_hour < 6 )); then
        is_night=true
    fi

    [[ $i -gt 0 ]] && cities_raw+=","
    name_esc="${name//\"/\\\"}"
    cities_raw+="{\"name\":\"$name_esc\",\"time\":\"$city_time\",\"offset\":\"$offset_str\",\"flag\":\"$flag\",\"is_night\":$is_night,\"tz\":\"$tz\",\"diff_mins\":$diff_mins}"
done
cities_raw+="]"

# Group by offset, combine names/flags
grouped=$(echo "$cities_raw" | jq -c --arg editing_tz "$editing_tz" '
    group_by(.diff_mins)
    | map({
        names: (map(.name) | join(", ")),
        flags: (map(.flag) | join(" ")),
        count: length,
        time: .[0].time,
        offset: .[0].offset,
        is_night: .[0].is_night,
        tz: (map(.tz) | join(",")),
        editing: ((map(.tz) | join(",")) == $editing_tz),
        diff_mins: .[0].diff_mins
    })
    | sort_by((.diff_mins | fabs))
    | map(del(.diff_mins))')

result=$(jq -n \
    --arg time "$local_time" \
    --arg date "$local_date" \
    --arg tz "$local_tz" \
    --argjson local_editing "$local_editing" \
    --argjson editing "$editing" \
    --arg editing_tz "$editing_tz" \
    --argjson cities "$grouped" \
    '{local: {time: $time, date: $date, tz: $tz, editing: $local_editing}, editing: $editing, editing_tz: $editing_tz, editing_city: ($cities[] | select(.editing) | if .count > 1 then .flags else "\(.flags) \(.names)" end) // "", cities: $cities}')

tee "$CACHE_FILE" <<< "$result"
