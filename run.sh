#!/usr/bin/env bash
# mnml-zig wrapper — build (in the repo) + run (in *your* cwd) with a
# restart-aware loop, plus subcommands for driving the running mnml-zig
# from another shell. The same verbs as the Rust editor's run.sh,
# parameterized on binary / marker / IPC subdir (docs/DESIGN.md,
# "Side-by-side mechanics"), so both can run on one machine until cutover.
#
# Usage:
#   ./run.sh                      Open the directory you ran it from. Builds
#                                 ReleaseSafe only when a source is newer than
#                                 zig-out/bin/mnml-zig (says so either way),
#                                 runs the binary, and relaunches it whenever
#                                 it exits with code 75 — the "rebuild +
#                                 relaunch me" signal (the `app.restart`
#                                 command, or `./run.sh restart`). Any other
#                                 exit ends the loop.
#   ./run.sh WORKSPACE [flags…]   Open WORKSPACE instead. Flags pass through
#                                 to mnml-zig: --input vim|standard, --ascii,
#                                 --config PATH, --no-session, --startup-picker.
#
# Dev subcommands:
#   ./run.sh build [args]         zig build [args]                (Debug)
#   ./run.sh release [args]       zig build -Doptimize=ReleaseSafe [args]
#   ./run.sh test [args]          zig build test [args]
#   ./run.sh check                The verification sequence from
#                                 docs/CONTRIBUTING.md: fmt, the unit tests in
#                                 Debug and ReleaseSafe, a ReleaseSafe build,
#                                 the gate at three sizes, the corpus, the
#                                 glyph audit, tools/run-sh-check.sh.
#   ./run.sh stale                Say whether the binary is behind the sources
#                                 (exit 0 = a build is needed, 1 = current).
#   ./run.sh clean [mode]         Reclaim space: `incremental` (default) drops
#                                 .zig-cache/ — the local compile cache — and
#                                 keeps zig-out/; `all` drops both. Asks first.
#                                 ~/.cache/zig (fetched packages) is never
#                                 touched.
#   ./run.sh menu                 Interactive numbered picker.
#   ./run.sh help                 Show this.
#
# mnml-specific modes:
#   ./run.sh restart              Tell the running mnml-zig to rebuild +
#                                 relaunch ({"cmd":"restart"} in its IPC mailbox).
#   ./run.sh stop                 Send {"cmd":"quit"} to the running mnml-zig.
#   ./run.sh status               Print marker state (workspace, IPC dir,
#                                 whether the process is alive).
#   ./run.sh headless [WORKSPACE] Same restart loop, but --headless (virtual
#                                 screen + file-IPC; nothing on the terminal).
#   ./run.sh fresh [WORKSPACE]    Launch without restoring the session
#                                 (--no-session). For when a restored pane
#                                 wedges the app: a restart reopens it and
#                                 wedges it again. session.zon is left alone.
#   ./run.sh shot [OUT.png]       Screenshot the *real* running mnml-zig (its
#                                 ghostty window) to a PNG and print the path —
#                                 actual pixels, not the screen.txt cell grid.
#
# Env:
#   MNML_OPTIMIZE     Optimize mode for the launch build (default ReleaseSafe;
#                     `Debug` for a debug binary — same output path).
#   MNML_BIN          The binary to run (default zig-out/bin/mnml-zig).
#   MNML_IPC_SUBDIR   IPC dir name under <ws>/.mnml/ (default ipc-zig — a dev
#                     build's `-Dipc-subdir`; the Rust editor owns `ipc`).
#   MNML_IPC_DIR      An absolute IPC dir instead (the app honors it too).
#   MNML_ZIG          The zig to build with (default: `zig` on PATH).
#   MNML_E2E_ALLOW_SHELL  `check` runs the corpus with it set to 1 unless you
#                     export another value.
#
# State: the app writes ${TMPDIR:-/tmp}/mnml-zig-running-$USER.workspace on
# start (its workspace's real path, no newline) and removes it on a clean
# exit — not on a restart. Headless writes nothing, so this wrapper keeps the
# marker for a headless loop. A second instance overwrites it; restart / stop
# / status / shot target the most recent.
# (no `set -u`: this juggles possibly-empty arrays on bash 3.2 / macOS)
set -o pipefail

INVOKE_DIR="$PWD"
cd "$(dirname "$0")" || exit 1
REPO="$PWD"

ZIG="${MNML_ZIG:-zig}"
BIN="${MNML_BIN:-$REPO/zig-out/bin/mnml-zig}"
IPC_SUBDIR="${MNML_IPC_SUBDIR:-ipc-zig}"
OPTIMIZE="${MNML_OPTIMIZE:-ReleaseSafe}"
MARKER="${TMPDIR:-/tmp}/mnml-zig-running-${USER:-x}.workspace"

log() { echo "[run.sh] $*" >&2; }

# The IPC directory for a workspace: MNML_IPC_DIR when exported (the app
# honors the same variable), else <ws>/.mnml/<subdir>.
ipc_dir_for() {
  if [ -n "${MNML_IPC_DIR:-}" ]; then printf '%s' "$MNML_IPC_DIR"
  else printf '%s' "$1/.mnml/$IPC_SUBDIR"; fi
}

send_cmd() {
  local cmd="$1"
  if [ ! -f "$MARKER" ]; then
    log "no running mnml-zig found (marker $MARKER missing)"
    return 1
  fi
  local ws ipc_dir
  ws=$(cat "$MARKER")
  ipc_dir=$(ipc_dir_for "$ws")
  if [ ! -d "$ipc_dir" ]; then
    log "IPC dir not found at $ipc_dir (mnml-zig not running?)"
    return 1
  fi
  printf '%s\n' "$cmd" >> "$ipc_dir/command"
  log "$cmd → $ws"
}

# The first source newer than the binary, if any — under src/ sdk/
# integrations/ tools/ or build.zig*; the integrations' own build
# outputs are not sources.
newest_source() {
  local dirs=() d
  for d in src sdk integrations tools; do [ -d "$REPO/$d" ] && dirs+=("$REPO/$d"); done
  find "${dirs[@]}" "$REPO"/build.zig "$REPO"/build.zig.zon \
    -type d \( -name .zig-cache -o -name zig-out \) -prune -o \
    -type f -newer "$BIN" -print 2>/dev/null | head -n 1
}

# Sets STALE_REASON and returns 0 when a build is needed.
needs_build() {
  STALE_REASON=""
  if [ ! -x "$BIN" ]; then STALE_REASON="no binary at ${BIN#"$REPO"/} yet"; return 0; fi
  local newer
  newer=$(newest_source)
  if [ -n "$newer" ]; then STALE_REASON="${newer#"$REPO"/} is newer than ${BIN#"$REPO"/}"; return 0; fi
  return 1
}

build_bin() {
  (cd "$REPO" && "$ZIG" build -Doptimize="$OPTIMIZE")
}

# Build when the sources moved (or when `force` says so); one line either way.
ensure_built() {
  if [ "${1:-}" = force ]; then
    log "restart requested — rebuilding ($OPTIMIZE)…"
  elif needs_build; then
    log "$STALE_REASON — building $OPTIMIZE…"
  else
    log "${BIN#"$REPO"/} is current (nothing under src/ sdk/ integrations/ tools/ build.zig* is newer) — skipping the build"
    return 0
  fi
  if ! build_bin; then log "build failed; exiting"; return 1; fi
}

# One step of `check`: announce, run, time, stop on the first failure.
step() {
  local label="$1"; shift
  local start end
  start=$(date +%s)
  echo
  echo "── $label"
  if ! "$@"; then
    echo
    log "check FAILED at: $label"
    exit 1
  fi
  end=$(date +%s)
  CHECK_SUMMARY="$CHECK_SUMMARY
  ok  $((end - start))s  $label"
}

HEADLESS=0
case "${1:-start}" in
  # ── Dev subcommands ─────────────────────────────────────────────
  build)   shift; cd "$REPO" && exec "$ZIG" build "$@" ;;
  release) shift; cd "$REPO" && exec "$ZIG" build -Doptimize=ReleaseSafe "$@" ;;
  test)    shift; cd "$REPO" && exec "$ZIG" build test "$@" ;;
  check)
    cd "$REPO" || exit 1
    CHECK_SUMMARY=""
    export MNML_E2E_ALLOW_SHELL="${MNML_E2E_ALLOW_SHELL:-1}"
    step "zig fmt --check src build.zig tools"            "$ZIG" fmt --check src build.zig tools
    step "zig build test -Doptimize=Debug"                "$ZIG" build test -Doptimize=Debug
    step "zig build test -Doptimize=ReleaseSafe"          "$ZIG" build test -Doptimize=ReleaseSafe
    step "zig build -Doptimize=ReleaseSafe"               "$ZIG" build -Doptimize=ReleaseSafe
    step "mnml-zig test --gate --sizes 80x24,120x40,200x60" ./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60
    step "mnml-zig test (the corpus, MNML_E2E_ALLOW_SHELL=$MNML_E2E_ALLOW_SHELL)" ./zig-out/bin/mnml-zig test
    step "zig build glyph-audit"                          "$ZIG" build glyph-audit
    step "tools/run-sh-check.sh"                          bash tools/run-sh-check.sh
    echo
    echo "── check: all green$CHECK_SUMMARY"
    exit 0 ;;
  stale)
    if needs_build; then log "$STALE_REASON — a build is needed"; exit 0
    else log "${BIN#"$REPO"/} is current"; exit 1; fi ;;
  # ── cache cleanup ───────────────────────────────────────────────
  clean)
    shift
    mode="${1:-incremental}"
    if [ ! -d "$REPO/.zig-cache" ] && [ ! -d "$REPO/zig-out" ]; then
      echo "[run.sh clean] no .zig-cache/ or zig-out/ — nothing to do"
      exit 0
    fi
    echo "[run.sh clean] current sizes:"
    du -sh "$REPO/.zig-cache" "$REPO/zig-out" 2>/dev/null | sed 's|'"$REPO"'/||'
    echo
    case "$mode" in
      incremental)
        target_dir="$REPO/.zig-cache"
        rationale="safe — drops the local compile cache; zig-out/ and the binary stay. The next build is a cold compile (~2-3 min)."
        ;;
      all)
        target_dir="$REPO/.zig-cache $REPO/zig-out"
        rationale="everything local — the compile cache and the installed binaries. ~/.cache/zig (fetched packages) is left alone."
        ;;
      *)
        echo "[run.sh clean] unknown mode: $mode" >&2
        echo "  usage: ./run.sh clean [incremental|all]" >&2
        echo "         incremental  .zig-cache/ only (default)" >&2
        echo "         all          .zig-cache/ + zig-out/" >&2
        exit 2
        ;;
    esac
    echo "[run.sh clean] about to remove ($mode):"
    for d in $target_dir; do echo "  $d"; done
    echo "[run.sh clean] $rationale"
    printf "[run.sh clean] proceed? [y/N] "
    read -r ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "[run.sh clean] aborted"; exit 0 ;;
    esac
    for d in $target_dir; do rm -rf "$d"; done
    echo "[run.sh clean] done."
    exit 0 ;;
  menu)
    shift
    TEAL=$'\033[38;2;83;192;188m'
    GREEN=$'\033[38;2;152;195;121m'
    GREY=$'\033[38;2;92;99;112m'
    BOLD=$'\033[1m'
    RST=$'\033[0m'
    printf '\n%s%s┌─ mnml-zig launcher ──────────────────────────────────┐%s\n' \
        "$BOLD" "$TEAL" "$RST"
    printf '%s%s│%s  Pick a mode:                                        %s%s│%s\n' \
        "$BOLD" "$TEAL" "$RST" "$BOLD" "$TEAL" "$RST"
    printf '%s%s└──────────────────────────────────────────────────────┘%s\n\n' \
        "$BOLD" "$TEAL" "$RST"
    PS3=$'\n'"  ${GREEN}→${RST} pick a number: "
    COLUMNS=1
    options=(
        "mnml-zig — standalone in this terminal"
        "mnml-zig — fresh (no session restore)"
        "mnml-zig — headless (no window; file IPC)"
        "build — debug build"
        "release — ReleaseSafe build"
        "test — zig build test"
        "check — the verification sequence"
        "status — the running instance"
        "quit"
    )
    select choice in "${options[@]}"; do
        case "$REPLY" in
            1) exec "$0" ;;
            2) exec "$0" fresh ;;
            3) exec "$0" headless ;;
            4) exec "$0" build ;;
            5) exec "$0" release ;;
            6) exec "$0" test ;;
            7) exec "$0" check ;;
            8) exec "$0" status ;;
            9) echo "bye"; exit 0 ;;
            *) printf '  %sunknown choice %q — try again%s\n' "$GREY" "$REPLY" "$RST" ;;
        esac
    done
    ;;
  # ── IPC subcommands ─────────────────────────────────────────────
  restart) send_cmd '{"cmd":"restart"}'; exit $? ;;
  stop)    send_cmd '{"cmd":"quit"}'; exit $? ;;
  status)
    if [ -f "$MARKER" ]; then
      ws=$(cat "$MARKER")
      ipc_dir=$(ipc_dir_for "$ws")
      echo "marker:    $MARKER"
      echo "workspace: $ws"
      if [ -d "$ipc_dir" ]; then echo "ipc dir:   $ipc_dir (exists)"
      else echo "ipc dir:   $ipc_dir (MISSING — mnml-zig likely not running)"; fi
      pids=$(pgrep -f -- "$BIN" 2>/dev/null | tr '\n' ' ')
      if [ -n "$pids" ]; then echo "process:   running (pid ${pids% })"
      else echo "process:   not running (no $BIN process; the marker is stale)"; fi
    else
      echo "no marker — no mnml-zig tracked ($MARKER)"
    fi
    exit 0 ;;
  fresh)   shift; set -- --no-session "$@" ;;
  shot)    shift; exec bash "$REPO/scripts/shot.sh" "$@" ;;
  # ── Misc ────────────────────────────────────────────────────────
  -h|--help|help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  # ── Implicit default ────────────────────────────────────────────
  headless) HEADLESS=1; shift ;;
  start) [ "$#" -gt 0 ] && shift ;;   # the implicit default when run with no args
esac

# Default workspace = the dir you invoked run.sh from (not the repo). The
# first non-flag argument that is a directory overrides it; a flag's value
# (`--input vim`, `--config PATH`) is never mistaken for one. The binary
# runs from INVOKE_DIR so a relative file or --config path resolves the way
# you typed it.
ws_dir="$INVOKE_DIR"
has_ws=0
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    --input|--config) skip=1 ;;
    -*) ;;
    *) if [ "$has_ws" = 0 ] && [ -d "$INVOKE_DIR/$a" -o -d "$a" ]; then ws_dir="$a"; has_ws=1; fi ;;
  esac
done
cd "$INVOKE_DIR" || exit 1
ws_dir=$(cd "$ws_dir" 2>/dev/null && pwd -P || echo "$ws_dir")
ARGS=("$@")
[ "$has_ws" = 0 ] && ARGS=("$ws_dir" "${ARGS[@]}")

# Headless writes no marker; keep one here so restart / stop / status
# reach a headless loop too. Either way, a marker still naming this
# workspace is cleaned up when the loop ends (a crash leaves none behind).
if [ "$HEADLESS" = 1 ]; then printf '%s' "$ws_dir" > "$MARKER"; fi
cleanup_marker() {
  [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$ws_dir" ] && rm -f "$MARKER"
}
trap cleanup_marker EXIT

EXTRA=()
[ "$HEADLESS" = 1 ] && EXTRA+=(--headless)

force=""
while true; do
  ensure_built $force || exit 1
  "$BIN" "${ARGS[@]}" "${EXTRA[@]}"
  status=$?
  if [ "$status" -eq 75 ]; then
    force=force
    [ "$HEADLESS" = 1 ] && printf '%s' "$ws_dir" > "$MARKER"
    continue
  fi
  exit "$status"
done
