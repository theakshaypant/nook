#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/weather_data.json"
CACHE_MAX_AGE=900
LOC_CACHE="$CACHE_DIR/weather_location.json"
LOC_MAX_AGE=86400

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"

FALLBACK='{"city":"--","temp":0,"feels_like":0,"high":0,"low":0,"condition":"--","icon":"","icon_gif":"overcast","humidity":0,"wind":0,"uv":0,"pressure":0,"theme":"cloudy","temp_class":"mild","hourly":[],"updated":"--:--"}'

[[ -d "$CACHE_DIR" ]] || mkdir -p "$CACHE_DIR"

if [[ -f "$CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if (( age < CACHE_MAX_AGE )); then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

fallback_or_exit() {
    if [[ -f "$CACHE_FILE" ]]; then cat "$CACHE_FILE"; else echo "$FALLBACK"; fi
    exit 0
}

cfg_city=$(sed -n '/^weather:/,/^[a-z]/{/^ *city:/s/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p}' "$CONFIG" 2>/dev/null)

if [[ -z "$cfg_city" ]]; then
    fallback_or_exit
fi

need_location=true
if [[ -f "$LOC_CACHE" ]]; then
    loc_age=$(( $(date +%s) - $(stat -c %Y "$LOC_CACHE") ))
    cached_city=$(jq -r '.cfg_city // ""' "$LOC_CACHE")
    if (( loc_age < LOC_MAX_AGE )) && [[ "$cached_city" == "$cfg_city" ]]; then
        need_location=false
    fi
fi

if $need_location; then
    loc_data=$(curl -s --connect-timeout 5 --max-time 10 \
      "https://geocoding-api.open-meteo.com/v1/search?name=$(printf '%s' "$cfg_city" | jq -sRr @uri)&count=1") || fallback_or_exit
    echo "$loc_data" | jq --arg cfg "$cfg_city" '{
      city: .results[0].name,
      lat: .results[0].latitude,
      lon: .results[0].longitude,
      cfg_city: $cfg
    }' > "$LOC_CACHE"
fi

IFS='|' read -r lat lon city <<< "$(jq -r '[
  (.lat // 0 | tostring),
  (.lon // 0 | tostring),
  (.city // "Unknown")
] | join("|")' "$LOC_CACHE")"

weather=$(curl -s --connect-timeout 5 --max-time 10 \
  "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day,surface_pressure&hourly=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min,uv_index_max&timezone=auto&forecast_days=2") || fallback_or_exit

city_tz=$(echo "$weather" | jq -r '.timezone')
read -r city_hour city_time <<< "$(TZ="$city_tz" date '+%-H %H:%M')"

echo "$weather" | jq --arg city "$city" --arg now "$city_time" --argjson ch "$city_hour" '
def wmo_info(is_day):
  if . == 0 then
    {cond: "Clear sky", icon: (if is_day then "☀️" else "🌙" end),
     gif: (if is_day then "clear-day" else "clear-night" end),
     theme: (if is_day then "clear-day" else "clear-night" end)}
  elif . == 1 then
    {cond: "Mainly clear", icon: (if is_day then "🌤️" else "🌙" end),
     gif: (if is_day then "mostly-clear-day" else "clear-night" end),
     theme: (if is_day then "clear-day" else "clear-night" end)}
  elif . == 2 then
    {cond: "Partly cloudy", icon: "⛅",
     gif: (if is_day then "partly-cloudy-day" else "partly-cloudy-night" end),
     theme: (if is_day then "cloudy" else "cloudy-night" end)}
  elif . == 3 then
    {cond: "Overcast", icon: "☁️", gif: "overcast",
     theme: (if is_day then "cloudy" else "cloudy-night" end)}
  elif . == 45 or . == 48 then
    {cond: "Foggy", icon: "🌫️", gif: "fog",
     theme: (if is_day then "fog" else "fog-night" end)}
  elif . >= 51 and . <= 55 then
    {cond: "Drizzle", icon: "🌦️", gif: "drizzle",
     theme: (if is_day then "rain" else "rain-night" end)}
  elif (. >= 61 and . <= 67) or (. >= 80 and . <= 82) then
    {cond: (if . >= 80 then "Showers" elif . >= 66 then "Freezing rain" else "Rain" end),
     icon: "🌧️", gif: "rain",
     theme: (if is_day then "rain" else "rain-night" end)}
  elif (. >= 71 and . <= 77) or (. >= 85 and . <= 86) then
    {cond: (if . >= 85 then "Snow showers" else "Snow" end),
     icon: "🌨️", gif: "snow",
     theme: (if is_day then "snow" else "snow-night" end)}
  elif . >= 95 then
    {cond: "Thunderstorm", icon: "⛈️", gif: "thunderstorms-rain",
     theme: (if is_day then "storm" else "storm-night" end)}
  else
    {cond: "Unknown", icon: "?", gif: "overcast",
     theme: (if is_day then "cloudy" else "cloudy-night" end)}
  end;

def theme_bg:
  {"clear-day":"#523a14","clear-night":"#161630","cloudy":"#2a2a2a","cloudy-night":"#1c1c24","rain":"#1a2230","rain-night":"#141a24","snow":"#242838","snow-night":"#1a1e2e","storm":"#1e1430","storm-night":"#161020","fog":"#282824","fog-night":"#1e1e1a"}[.] // "#262220";

def temp_class:
  if . < 5 then "cold"
  elif . < 15 then "cool"
  elif . < 25 then "mild"
  elif . < 33 then "warm"
  else "hot" end;

.current as $c |
.daily as $d |
.hourly as $h |
($c.is_day == 1) as $is_day |
($c.weather_code | wmo_info($is_day)) as $w |

[range($ch; $ch + 12) | . as $i |
  ($h.weather_code[$i] | wmo_info($h.is_day[$i] == 1)) as $hw |
  {
    time: (if $i == $ch then "Now" else ($h.time[$i] | split("T")[1] | split(":")[0]) end),
    temp: ($h.temperature_2m[$i] | round),
    icon: $hw.icon,
    temp_class: ($h.temperature_2m[$i] | temp_class)
  }
] |

{
  city: $city,
  temp: ($c.temperature_2m | round),
  feels_like: ($c.apparent_temperature | round),
  high: ($d.temperature_2m_max[0] | round),
  low: ($d.temperature_2m_min[0] | round),
  condition: $w.cond,
  icon: $w.icon,
  icon_gif: $w.gif,
  humidity: $c.relative_humidity_2m,
  wind: ($c.wind_speed_10m | round),
  uv: ($d.uv_index_max[0] | round),
  pressure: ($c.surface_pressure | round),
  theme: $w.theme,
  theme_bg: ($w.theme | theme_bg),
  temp_class: ($c.temperature_2m | temp_class),
  hourly: .,
  updated: $now
}
' | tee "$CACHE_FILE"
