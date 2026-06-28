#!/usr/bin/env bash
#
# shot — screenshot the *real* running mnml (the ghostty window), not the
# headless virtual screen.
#
# mnml has three ways to be observed:
#   1. headless  — `--headless` renders to a ratatui TestBackend; the cell
#                  grid is dumped to `.mnml/ipc/screen.txt`.
#   2. screen.txt — the real terminal loop ALSO dumps `screen.txt` every
#                  frame (src/tui.rs). Same text-grid form as headless.
#   3. THIS       — a pixel screenshot of ghostty's actual window. The only
#                  way to see what `screen.txt` fundamentally can't: the
#                  CoreText-rendered glyphs, Nerd Font icons, true colors,
#                  cursor shape — the rendering quality mnml went
#                  terminal-agnostic for.
#
# How it finds the window: mnml sets its OSC window title to
# `mnml — <workspace-basename>` (src/tui.rs). We ask System Events for the
# ghostty window whose name starts with "mnml" (preferring the one matching
# the running instance's workspace from the run.sh marker), read its
# on-screen bounds, and `screencapture -R` just that region.
#
# Usage:  scripts/shot.sh [OUT.png]
#   OUT.png  where to write (default: $TMPDIR/mnml-shot.png). The absolute
#            path is printed to stdout on success — the only thing on stdout,
#            so callers can `OUT=$(scripts/shot.sh)`.
#
# Permissions (one-time macOS grants, prompted on first run):
#   - Screen Recording  (for screencapture)
#   - Accessibility     (for System Events window geometry)
#
set -o pipefail

OUT="${1:-${TMPDIR:-/tmp}/mnml-shot.png}"
# Absolutize OUT so the printed path is unambiguous regardless of cwd.
case "$OUT" in
  /*) : ;;
  *)  OUT="$PWD/$OUT" ;;
esac

# Prefer the window for the workspace the run.sh marker points at, so that
# with several mnml windows open we grab the one most-recently launched.
MARKER="${TMPDIR:-/tmp}/mnml-running-${USER:-x}.workspace"
WANT=""
if [ -f "$MARKER" ]; then
  WANT=$(basename "$(cat "$MARKER")")
fi

if ! pgrep -qx ghostty 2>/dev/null && ! pgrep -q -f Ghostty.app 2>/dev/null; then
  echo "[shot] ghostty is not running" >&2
  exit 1
fi

# Ask System Events for the bounds of the matching ghostty window. Returns
# "x y w h" for the first window whose name starts with "mnml" — preferring
# (when $WANT is set) one whose name also contains the workspace basename.
bounds=$(WANT="$WANT" osascript <<'APPLESCRIPT' 2>/dev/null
set want to (system attribute "WANT")
tell application "System Events"
  if not (exists process "ghostty") then return ""
  tell process "ghostty"
    set fallback to ""
    repeat with w in windows
      set nm to name of w
      if nm starts with "mnml" then
        set p to position of w
        set s to size of w
        set b to (item 1 of p as string) & " " & (item 2 of p as string) & " " & (item 1 of s as string) & " " & (item 2 of s as string)
        if want is not "" and nm contains want then return b
        if fallback is "" then set fallback to b
      end if
    end repeat
    return fallback
  end tell
end tell
APPLESCRIPT
)

if [ -z "$bounds" ]; then
  echo "[shot] no ghostty window titled 'mnml — …' found (is mnml running in ghostty?)" >&2
  exit 1
fi

read -r x y w h <<EOF
$bounds
EOF

if [ -z "$h" ] || [ "$w" -le 0 ] 2>/dev/null; then
  echo "[shot] could not read window bounds (got: '$bounds')" >&2
  exit 1
fi

# -x: silent (no shutter sound)   -o: omit window shadow   -R: region
if ! screencapture -x -o -R "${x},${y},${w},${h}" "$OUT"; then
  echo "[shot] screencapture failed (Screen Recording permission granted?)" >&2
  exit 1
fi

echo "$OUT"
