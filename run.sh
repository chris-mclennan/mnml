#!/usr/bin/env bash
# mnml wrapper — build (in the repo) + run (in *your* cwd) with a restart-aware
# loop, plus subcommands for driving the running mnml from another shell.
# Family convention: subcommands `build`/`release`/`test`/`check`/`watch`/`help`
# are common across mnml + mixr-rs. Per-app modes follow.
#
# Usage:
#   ./run.sh                      Open the directory you ran it from. Builds with
#                                 cargo, runs the binary, and relaunches it
#                                 whenever it exits with code 75 (the "rebuild +
#                                 relaunch me" signal — sent by the `app.restart`
#                                 command, or `./run.sh restart`).
#   ./run.sh WORKSPACE [flags…]   Open WORKSPACE instead. Extra flags pass through
#                                 to mnml (e.g. --input vim, --ascii).
#
# Common dev subcommands (family-wide):
#   ./run.sh build [args]         cargo build [args]
#   ./run.sh release [args]       cargo build --release [args]
#   ./run.sh test [args]          cargo test [args]
#   ./run.sh check                cargo clippy --all-targets
#   ./run.sh watch                cargo watch -x build  (needs cargo-watch)
#   ./run.sh app [debug|release]  Build mnml.app into target/ (scripts/build-app.sh).
#   ./run.sh dmg [debug|release]  Build mnml-<version>.dmg into target/.
#   ./run.sh help                 show this
#
# mnml-specific modes:
#   ./run.sh restart              Tell the running mnml to rebuild + relaunch
#                                 (drops {"cmd":"restart"} in its IPC mailbox).
#   ./run.sh stop                 Send {"cmd":"quit"} to the running mnml.
#   ./run.sh status               Print marker state (workspace, IPC dir).
#   ./run.sh headless [WORKSPACE] Same restart loop, but --headless (virtual
#                                 screen + file-IPC; nothing on the terminal).
#
# Env:
#   MNML_RELEASE=1   Build/run target/release/mnml (the release profile has LTO
#                    on — slower rebuilds, snappier binary).
#
# State: a marker at $TMPDIR/mnml-running-$USER.workspace records the running
# mnml's workspace. A second instance overwrites it; restart/stop/status target
# the most recent.
# (no `set -u`: this juggles possibly-empty arrays on bash 3.2 / macOS)
set -o pipefail

INVOKE_DIR="$PWD"
cd "$(dirname "$0")"
REPO="$PWD"

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
  # ── Family-wide dev subcommands ─────────────────────────────────
  build)   shift; exec cargo build "$@" ;;
  release) shift; exec cargo build --release "$@" ;;
  test)    shift; exec cargo test "$@" ;;
  check)   exec cargo clippy --all-targets ;;
  dist-check) shift; exec ./scripts/dist-check.sh "$@" ;;
  newsletter) shift; exec ./scripts/send-release-newsletter.sh "$@" ;;
  app)     shift; exec ./scripts/build-app.sh "$@" ;;
  dmg)     shift; exec ./scripts/build-dmg.sh "$@" ;;
  watch)
    if ! command -v cargo-watch >/dev/null 2>&1; then
      echo "[run.sh] cargo-watch not installed — \`cargo install cargo-watch\`" >&2
      exit 1
    fi
    exec cargo watch -x build
    ;;
  # ── mnml-specific IPC subcommands ───────────────────────────────
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
  # ── Misc ────────────────────────────────────────────────────────
  -h|--help|help) grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
  # ── Implicit default ────────────────────────────────────────────
  headless) HEADLESS=1; shift ;;
  start) [ "$#" -gt 0 ] && shift ;;   # the implicit default when run with no args
esac

# Build profile.
if [ "${MNML_RELEASE:-0}" = "1" ]; then
  BUILD=(cargo build --release --quiet)
  BIN="$REPO/target/release/mnml"
else
  BUILD=(cargo build --quiet)
  BIN="$REPO/target/debug/mnml"
fi

# Default workspace = the dir you invoked run.sh from (not the repo). An explicit
# first non-flag arg overrides it. Either way, make sure mnml gets a workspace arg
# so it doesn't fall back to the repo (its cwd is the repo when we exec it).
ws_dir="$INVOKE_DIR"
has_ws=0
for a in "$@"; do
  case "$a" in -*) ;; *) ws_dir="$a"; has_ws=1; break ;; esac
done
ws_dir=$(cd "$ws_dir" 2>/dev/null && pwd || echo "$ws_dir")
ARGS=("$@")
[ "$has_ws" = 0 ] && ARGS=("$ws_dir" "${ARGS[@]}")

mkdir -p "$ws_dir/.mnml/ipc" 2>/dev/null || true
printf '%s' "$ws_dir" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

EXTRA=()
[ "$HEADLESS" = "1" ] && EXTRA+=(--headless)

while true; do
  if ! "${BUILD[@]}"; then echo "[run.sh] build failed; exiting" >&2; exit 1; fi
  "$BIN" "${EXTRA[@]}" "${ARGS[@]}"
  status=$?
  if [ "$status" -eq 75 ]; then
    echo "[run.sh] restart requested — rebuilding…" >&2
    continue
  fi
  exit "$status"
done
