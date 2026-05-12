#!/usr/bin/env bash
# mnml wrapper — build + run with a restart-aware loop, plus subcommands for
# driving the running mnml from another shell (or from an agent after a build).
#
# Usage:
#   ./run.sh [WORKSPACE] [mnml flags…]
#                       Start. Default subcommand. Builds with cargo, runs the
#                       binary, and *relaunches* it whenever it exits with code
#                       75 (the "rebuild + relaunch me" signal — sent by the
#                       `app.restart` command, or `./run.sh restart`).
#   ./run.sh restart    Tell the running mnml to rebuild + relaunch (drops a
#                       {"cmd":"restart"} line in its IPC mailbox). Use this from
#                       a sibling terminal whenever you want it to pick up new code.
#   ./run.sh stop       Send {"cmd":"quit"} to the running mnml.
#   ./run.sh status     Print marker state (workspace, IPC dir).
#   ./run.sh headless [WORKSPACE]
#                       Same restart loop, but in --headless mode (virtual screen
#                       + file-IPC; nothing on the terminal). Handy for agents.
#
# Env:
#   MNML_RELEASE=1      Build/run target/release/mnml instead of target/debug
#                       (the release profile has LTO on — slower rebuilds).
#
# State: a marker at $TMPDIR/mnml-running-$USER.workspace records the
# currently-running mnml's workspace path. A second instance overwrites it;
# `restart`/`stop`/`status` target the most recent.
set -uo pipefail
cd "$(dirname "$0")"

MARKER="${TMPDIR:-/tmp}/mnml-running-${USER:-x}.workspace"

send_cmd() {
  local cmd="$1"
  if [ ! -f "$MARKER" ]; then
    echo "[run.sh] no running mnml found (marker $MARKER missing)" >&2
    return 1
  fi
  local ws ipc_dir
  ws=$(cat "$MARKER")
  ipc_dir="$ws/.mnml/ipc"
  if [ ! -d "$ipc_dir" ]; then
    echo "[run.sh] IPC dir not found at $ipc_dir (mnml not running?)" >&2
    return 1
  fi
  printf '%s\n' "$cmd" >> "$ipc_dir/command"
  echo "[run.sh] $cmd → $ws"
}

HEADLESS=0
case "${1:-start}" in
  restart) send_cmd '{"cmd":"restart"}'; exit $? ;;
  stop)    send_cmd '{"cmd":"quit"}'; exit $? ;;
  status)
    if [ -f "$MARKER" ]; then
      ws=$(cat "$MARKER")
      echo "marker:    $MARKER"
      echo "workspace: $ws"
      if [ -d "$ws/.mnml/ipc" ]; then echo "ipc dir:   $ws/.mnml/ipc (exists)"
      else echo "ipc dir:   $ws/.mnml/ipc (MISSING — mnml likely not running)"; fi
    else
      echo "no marker — no mnml tracked"
    fi
    exit 0 ;;
  -h|--help) grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
  headless) HEADLESS=1; shift ;;
  start) shift ;;
esac

# Build profile.
if [ "${MNML_RELEASE:-0}" = "1" ]; then
  BUILD=(cargo build --release --quiet)
  BIN=./target/release/mnml
else
  BUILD=(cargo build --quiet)
  BIN=./target/debug/mnml
fi

# Figure out the workspace (first non-flag arg, else cwd) so the marker is right.
ws_dir="$PWD"
for a in "$@"; do
  case "$a" in
    -*) ;;                       # a flag — skip
    *) ws_dir="$a"; break ;;
  esac
done
ws_dir=$(cd "$ws_dir" 2>/dev/null && pwd || echo "$ws_dir")
mkdir -p "$ws_dir/.mnml/ipc" 2>/dev/null || true
printf '%s' "$ws_dir" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

EXTRA=()
[ "$HEADLESS" = "1" ] && EXTRA+=(--headless)

while true; do
  if ! "${BUILD[@]}"; then echo "[run.sh] build failed; exiting" >&2; exit 1; fi
  "$BIN" "${EXTRA[@]}" "$@"
  status=$?
  if [ "$status" -eq 75 ]; then
    echo "[run.sh] restart requested — rebuilding…" >&2
    continue
  fi
  exit "$status"
done
