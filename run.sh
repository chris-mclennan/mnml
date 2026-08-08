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
#   ./run.sh clean [mode]         Reclaim target/ space (it bloats past 100GB
#                                 because cargo never GCs the incremental cache
#                                 + dep rlibs). Default mode = `incremental`
#                                 (safe, no recompile). `deps` is aggressive,
#                                 `all` is full cargo clean. Asks before deleting.
#   ./run.sh help                 show this
#
# mnml-specific modes:
#   ./run.sh restart              Tell the running mnml to rebuild + relaunch
#                                 (drops {"cmd":"restart"} in its IPC mailbox).
#   ./run.sh stop                 Send {"cmd":"quit"} to the running mnml.
#   ./run.sh status               Print marker state (workspace, IPC dir).
#   ./run.sh headless [WORKSPACE] Same restart loop, but --headless (virtual
#                                 screen + file-IPC; nothing on the terminal).
#   ./run.sh shot [OUT.png]       Screenshot the *real* running mnml (its
#                                 ghostty window) to a PNG and print the path.
#                                 The third way to observe mnml: actual pixels
#                                 (CoreText glyphs, icons, color) — not the
#                                 text cell-grid that headless/screen.txt give.
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

# mnml-libghostty-vt-sys's build.rs needs `zig` on PATH — ghostty a887df42+ requires
# zig 0.16.0. Homebrew installs it at /opt/homebrew/opt/zig/bin (unversioned
# formula); we also try /opt/homebrew/opt/zig@0.15/bin as a leftover from
# the previous zig 0.15.2 era. Without this prepend, `cargo build` would
# silently fail the mnml-libghostty-vt-sys crate and `./run.sh restart` would loop
# on the stale binary.
for ZIG_DIR in /opt/homebrew/opt/zig/bin /opt/homebrew/opt/zig@0.15/bin; do
  if [ -x "$ZIG_DIR/zig" ] && [[ ":$PATH:" != *":$ZIG_DIR:"* ]]; then
    export PATH="$ZIG_DIR:$PATH"
    break
  fi
done

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
  # ── target/ cleanup (cargo cache can balloon past 100GB) ────────
  # 2026-06-30 — discovered target/ at 238GB causing 22-minute
  # rebuilds. The incremental cache + dep rlibs accumulate stale
  # entries cargo never garbage-collects. Default `clean` removes
  # incremental only (safe, fast); explicit args remove more.
  clean)
    shift
    mode="${1:-incremental}"
    if [ ! -d "$REPO/target" ]; then
      echo "[run.sh clean] no target/ dir — nothing to do"
      exit 0
    fi
    echo "[run.sh clean] current sizes:"
    du -sh "$REPO/target" "$REPO/target/debug" "$REPO/target/debug/incremental" \
           "$REPO/target/debug/deps" "$REPO/target/debug/examples" \
           "$REPO/target/release" 2>/dev/null | sed 's|'"$REPO"'/||'
    echo
    case "$mode" in
      incremental)
        target_dir="$REPO/target/debug/incremental"
        rationale="safest — keeps compiled artifacts, only drops the bloat-prone fingerprint cache. Next build is normal-incremental fast."
        ;;
      deps)
        target_dir="$REPO/target/debug/deps $REPO/target/debug/incremental"
        rationale="aggressive — wipes compiled deps too. Next build is a full cold rebuild (~5-10min), but reclaims the most space."
        ;;
      all)
        target_dir="$REPO/target"
        rationale="nuclear — full cargo clean equivalent. Forces a complete rebuild including release/ and examples/."
        ;;
      *)
        echo "[run.sh clean] unknown mode: $mode" >&2
        echo "  usage: ./run.sh clean [incremental|deps|all]" >&2
        echo "         incremental  ~10-60GB, no recompile (default)" >&2
        echo "         deps         ~150-200GB, full dep recompile" >&2
        echo "         all          everything, full clean rebuild" >&2
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
    echo "[run.sh clean] done. new size:"
    du -sh "$REPO/target" 2>/dev/null | sed 's|'"$REPO"'/||'
    exit 0 ;;
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
  shot)    shift; exec bash "$REPO/scripts/shot.sh" "$@" ;;
  # ── Sandbox mode ────────────────────────────────────────────────
  # See mnml as a brand-new user would. Redirects $HOME + $XDG_CONFIG_HOME
  # at a tempdir + drops you into a fresh scratch workspace, so:
  #   - the welcome overlay fires (no .mnml/.welcomed marker in this ws)
  #   - the integrations panel shows only the 4 first-party defaults
  #     (browser / claude_code / codex / http) — no installed manifests
  #   - no session to restore, no saved theme override, no prompt.sh
  # Your real ~/.config/mnml/ is untouched — the tempdir dies with the
  # process. Per-workspace `.mnml/env/*.env` API tokens (Bitbucket, Jira,
  # Slack, …) live in each workspace and aren't touched either.
  #
  # Optional `--show <panel>` opens an activity-bar section on startup:
  #   integrations / sessions / agents / http / explorer / …
  #
  # Usage: ./run.sh sandbox [--show integrations]
  sandbox)
    shift
    sandbox_show=""
    if [ "${1:-}" = "--show" ] && [ -n "${2:-}" ]; then
      sandbox_show="$2"; shift 2
    fi
    sandbox_root="$(mktemp -d -t mnml-sandbox-XXXXXXXX)"
    sandbox_ws="$sandbox_root/workspace"
    mkdir -p "$sandbox_ws" "$sandbox_root/xdg"
    # Seed a tiny README so the tree isn't literally empty on landing.
    cat > "$sandbox_ws/README.md" <<'EOF'
# mnml sandbox workspace

This is a throwaway tempdir. Everything you do here vanishes when
you exit. Your real config at `~/.config/mnml/` is untouched.

Try:

- `F1` — help overlay
- `Ctrl+P` — fuzzy file picker
- `Ctrl+Shift+P` — command palette
- Click the puzzle-piece icon in the activity bar → Integrations panel
- `Marketplace` tab → what a fresh user sees for browsable integrations
EOF
    # Cleanup on any exit path (normal, Ctrl-C, SIGTERM).
    trap 'rm -rf "$sandbox_root"' EXIT INT TERM
    echo "[run.sh sandbox] tempdir: $sandbox_root"
    echo "[run.sh sandbox] workspace: $sandbox_ws"
    if ! (cd "$REPO" && cargo build --quiet); then
      echo "[run.sh sandbox] build failed; exiting" >&2
      exit 1
    fi
    bin="$REPO/target/debug/mnml"
    extra=()
    [ -n "$sandbox_show" ] && extra=(--show "$sandbox_show")
    HOME="$sandbox_root" XDG_CONFIG_HOME="$sandbox_root/xdg" \
      "$bin" --sandbox "${extra[@]}" "$sandbox_ws"
    exit $? ;;
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

# libghostty-vt is now built from source by mnml-libghostty-vt-sys's build.rs
# (see `GHOSTTY_COMMIT` there). First `cargo build` clones ghostty +
# runs `zig build` (needs zig 0.16.0 on PATH — this script prepends
# it above). Subsequent builds hit the zig + cargo caches.
#
# 2026-08-02 — the prebuilt fetch (`vendor/.../fetch-prebuilts.sh`)
# retired here; the 0.2.0 GitHub release is stale against the newer
# vendored headers and would ABI-mismatch. If we bring prebuilts back,
# put the fetch call back too.

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
