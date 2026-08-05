# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

eww-based desktop widgets for GNOME Wayland (X11 mode via XWayland). Seven widget files produce ten windows arranged in a grid along the right edge of a 1920x1200 screen.

## Commands

```bash
./nook.sh start        # kill existing eww, reopen all windows
./nook.sh stop         # kill eww
./nook.sh clear-cache  # rm -rf ~/.cache/nook
```

Geometry changes require a full restart (`./nook.sh stop && ./nook.sh start`) — eww reload ignores geometry in X11 mode.

eww must be built with X11 support (GNOME has no wlr-layer-shell):
```
cargo build --release --no-default-features --features=x11
```

Runtime deps: `jq`, `curl`, `yq`, `gh` (authenticated), Google OAuth creds for calendar/gmail.

## Architecture

### Data flow

```
config.yaml → scripts/fetch_*.sh → JSON stdout + tee to cache → defpoll variable → {var.field} in widgets
```

Each widget follows a three-layer pattern in its `.yuck` file:
1. **`defpoll`** — runs a shell script on a timer, parses stdout as JSON
2. **`defwidget`** — reusable components + one main composite widget
3. **`defwindow`** — pixel-precise geometry, `stacking "bottom"`, `windowtype "desktop"`, `focusable false`

Exception: the stats widget uses eww's built-in variables (`EWW_CPU`, `EWW_RAM`, `EWW_DISK`, `EWW_NET`, `EWW_TEMPS`) with no scripts.

### Interactivity via /tmp signal files

Calendar navigation, event expansion, and watch edit mode use `/tmp/nook-*` files as state. Button clicks write to these files; the next poll reads them. Calendar polls every 2s and watch every 1s to keep the UI responsive.

The reload button calls `scripts/reload.sh <widget>`, which force-fetches with `NOOK_FORCE=1` and pushes the result to eww via `eww update`.

### Config

`config.yaml` is in `.gitignore` (contains personal data). `config.example.yaml` is the tracked template. Scripts parse config with `sed` address ranges — except `fetch_apps.sh` which uses `yq`. eww never reads config directly.

## Adding a new widget

1. Create `widgets/<name>.yuck` — `defpoll`, `defwidget`, `defwindow`
2. Create `widgets/_<name>.scss` — underscore prefix (SCSS partial convention)
3. Add `(include "widgets/<name>.yuck")` to `eww.yuck`
4. Add `@import "widgets/<name>";` to `eww.scss`
5. Add the window name(s) to the `WINDOWS` array in `nook.sh`
6. Data scripts go in `scripts/`, assets in `assets/`

## eww patterns

- **No `if` widget** — use `(box :visible {condition} ...)` for conditional rendering
- **Paths** — all relative to config dir, no hardcoded `/home/...`
- **Button styling** — GTK defaults must be explicitly stripped (background, border, box-shadow, background-image all set to none); shared reset is in `eww.scss`
- **`defpoll :initial`** — must be valid JSON matching the script's output schema

## Script conventions

- `#!/usr/bin/env bash` + `set -euo pipefail`
- Cache in `${XDG_CACHE_HOME:-$HOME/.cache}/nook/` with per-script `CACHE_MAX_AGE`
- `NOOK_FORCE=1` env var bypasses cache
- On failure, serve stale cache or a hardcoded empty JSON fallback — never let eww receive invalid output
- JSON assembly with `jq`; use `--arg` for strings, `--argjson` for JSON values
- Use `date` for local time (jq's `strftime` outputs UTC)
- Final output through `tee "$CACHE_FILE"` (writes cache + stdout in one pass)
- Config parsing via `sed` address ranges (not `yq`, except in `fetch_apps.sh`)

## Styling

- **Theme: Warm & Earthy**
  - card bg: `#262220`, fg: `#c8c2ba`, muted: `#706860`, comment: `#9a918a`
  - amber: `#b89470`, sage: `#8a9878`, olive: `#8fa07a`, sand: `#c4a878`, terracotta: `#b07868`, clay: `#9a8478`
- Font: Source Code Pro
- Card: 15px border-radius, 13px 15px padding
- Shared styles (`.card`, `.header`, `.title`, `.footer`, `.empty`, `.badge`, button reset, scrollbar) live in `eww.scss`
- Widget-specific styles use short namespace prefixes (`cal-`, `email-`, `wh-`, `gauge-`, `app-`, etc.)

## Window geometry

All windows anchor `"top right"`. x is a negative offset from the right edge. Do not change widget dimensions or positions without explicit user approval — layout is manually tuned.

| Column | Widgets | Width |
|--------|---------|-------|
| 1 (rightmost) | github, stats-gauges/disk/net/temp | 375px |
| 2 | watch, apps | 440px |
| 3 | calendar, gmail | 500–625px |
| 4 (leftmost) | weather | 375px |
