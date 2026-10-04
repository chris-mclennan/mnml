#!/usr/bin/env bash
# ghostty-hop.sh — run a command inside a new Ghostty window and relay it
# back: its stdout and stderr as they grow, its exit code, and (since it
# runs in the same directory) its output files.
#
#   tools/tour/ghostty-hop.sh COMMAND [ARG…]
#
# Why: macOS grants Accessibility and Screen Recording to the process
# that is "responsible" for a command. For a background Claude Code
# session that is Claude's versioned binary, so every Claude update
# silently drops the grants. A Ghostty launched through LaunchServices
# (`open -n`) is its own responsible process, holds the grants under a
# stable identity, and passes them to whatever runs in its window.
#
# Ghostty opens its first window only once it is the active app, so
# the launch takes the keyboard; the first thing the window does is hand
# it back to the app that was in front (NSRunningApplication activation
# with all its windows, so this one lands behind them, plus AXFrontmost — the AX call alone lags by seconds — and only while
# our Ghostty is the one in front; the grant it holds allows the AX part).
# The window closes when the command exits (`quit-after-last-window-
# closed`, `wait-after-command=false`, no too-quick-exit error page;
# `--config-default-files=false`, so nothing of the user's config
# applies). The command sees MNML_TOUR_IN_GHOSTTY=1 so it never hops
# again.
#
# `-e bash -c "exec PATH"`, not `-e PATH`: AppKit also reports an argv
# entry that is an existing path as a file to open, and Ghostty 1.3
# answers that with a modal "Allow Ghostty to execute …?" alert — which,
# when it wins the race against the window, blocks it forever. No
# argument here is an existing path.
#
# Exit: the command's own, or 69 when the window never ran the command
# (MNML_TOUR_GHOSTTY_START_S, default 60 s — a locked screen can do
# that) or 70 when it vanished without writing an exit code.
set -euo pipefail
[ $# -ge 1 ] || { echo "ghostty-hop.sh: usage: ghostty-hop.sh COMMAND [ARG…]" >&2; exit 64; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=${MNML_TOUR_GHOSTTY_APP:-/Applications/Ghostty.app}
[ -d "$APP" ] || { echo "ghostty-hop.sh: no Ghostty at $APP (MNML_TOUR_GHOSTTY_APP)" >&2; exit 69; }

DIR="$ROOT/.verify/ghostty-hop/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$DIR"
OUT="$DIR/stdout.log" ERR="$DIR/stderr.log" CODE="$DIR/exit" PIDF="$DIR/pid"
: > "$OUT"; : > "$ERR"

# The app in front now gets the keyboard back once the window is up
# (MNML_LOOK_FRONT=1: leave this window in front instead).
FRONT=$(lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*=\([0-9][0-9]*\).*/\1/p')
[ "${MNML_LOOK_FRONT:-}" = 1 ] && FRONT=""

# Ghostty runs its command through login(1), which starts from a fresh
# environment: carry over the working directory, PATH and the MNML_*
# knobs — nothing else (no tokens land in a file on disk).
{
  echo '#!/bin/bash'
  echo "echo \$\$ > $(printf '%q' "$PIDF")"
  printf 'prev=%q\n' "$FRONT"
  printf 'hlog=%q\n' "$DIR/handback.log"
  cat <<'HANDBACK'
# Hand the keyboard back, watching for the first few seconds in case
# Ghostty activates itself again as its window settles. Only while OUR
# Ghostty (login's parent) is the app in front; each hand-back is logged.
me=$(ps -o ppid= -p "$PPID" | tr -d ' ')
(
  for _ in $(seq 1 160); do
    front=$(lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed 's/.*=//')
    if [ -n "$prev" ] && [ "$front" = "$me" ] && kill -0 "$prev" 2>/dev/null; then
      osascript -l JavaScript -e "ObjC.import('ApplicationServices'); ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($prev).activateWithOptions(3); \$.AXUIElementSetAttributeValue(\$.AXUIElementCreateApplication($prev), \$('AXFrontmost'), \$.kCFBooleanTrue)" >/dev/null 2>&1
      echo "$(date +%T) front was $front (ours); handed back to $prev: $?" >> "$hlog"
      sleep 0.4  # the switch takes a moment to show in lsappinfo
    fi
    sleep 0.05
  done
) &
HANDBACK
  printf 'cd %q || exit 70\n' "$PWD"
  printf 'export PATH=%q\n' "$PATH"
  while IFS= read -r name; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done < <(compgen -e | grep -E '^MNML_' | grep -v '^MNML_TOUR_IN_GHOSTTY$' || true)
  echo 'export MNML_TOUR_IN_GHOSTTY=1 PYTHONUNBUFFERED=1'
  echo "echo 'mnml tour: running in this window for its macOS permissions; it closes when done.'"
  printf 'echo %q\n' "log: $DIR"
  # The command runs in the background of this shell so a TERM from the
  # caller can be passed on as an INT (the tour quits its window on one).
  printf '%q ' "$@"
  printf '> %q 2> %q < /dev/null &\n' "$OUT" "$ERR"
  echo 'child=$!'
  echo "trap 'kill -INT \$child 2>/dev/null' INT TERM HUP"
  echo 'while :; do wait $child; rc=$?; kill -0 $child 2>/dev/null || break; done'
  printf 'echo $rc > %q.tmp && mv %q.tmp %q\n' "$CODE" "$CODE" "$CODE"
} > "$DIR/run.sh"
chmod +x "$DIR/run.sh"

open -n -a "$APP" --args \
  --config-default-files=false \
  --wait-after-command=false \
  --abnormal-command-exit-runtime=0 \
  --quit-after-last-window-closed=true \
  --confirm-close-surface=false \
  --title="mnml tour (permissions hop)" \
  -e bash -c "exec $(printf '%q' "$DIR/run.sh")"

# Relay: print what each log gained since the last look, until the exit
# code lands. Byte offsets, so a partial last line is finished next time.
o_off=0 e_off=0
relay() {
  local n
  n=$(wc -c < "$OUT"); if [ "$n" -gt "$o_off" ]; then tail -c +$((o_off + 1)) "$OUT" | head -c $((n - o_off)); o_off=$n; fi
  n=$(wc -c < "$ERR"); if [ "$n" -gt "$e_off" ]; then tail -c +$((e_off + 1)) "$ERR" | head -c $((n - e_off)) >&2; e_off=$n; fi
}
# Interrupting the caller interrupts the command in the window.
trap '[ -s "$PIDF" ] && kill -TERM "$(cat "$PIDF")" 2>/dev/null; exit 130' INT TERM HUP

start_s=${MNML_TOUR_GHOSTTY_START_S:-60}
waited=0
until [ -s "$PIDF" ]; do
  if [ "$waited" -ge $((start_s * 5)) ]; then
    echo "ghostty-hop.sh: the Ghostty window did not start the command within ${start_s} s (a locked screen?); files: $DIR" >&2
    # Ours alone: the instance whose command line names this run's script.
    for p in $(pgrep -f -- "$DIR/run.sh" || true); do kill "$p" 2>/dev/null || true; done
    exit 69
  fi
  sleep 0.2; waited=$((waited + 1))
done
pid=$(cat "$PIDF")
while [ ! -s "$CODE" ]; do
  relay
  if ! kill -0 "$pid" 2>/dev/null && [ ! -s "$CODE" ]; then
    sleep 0.5
    [ -s "$CODE" ] && break
    relay
    echo "ghostty-hop.sh: the window's shell (pid $pid) ended without an exit code; files: $DIR" >&2
    exit 70
  fi
  sleep 0.5
done
relay
exit "$(cat "$CODE")"
