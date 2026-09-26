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
#                                 glyph audit, the hover-help audit, the
#                                 cross-compile of all five shipped targets
#                                 (`zig build gate-targets`),
#                                 tools/run-sh-check.sh and
#                                 tools/run-ps1-check.py (run.ps1's structure
#                                 — the real ps1 check needs a PowerShell).
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
# Daily driver:
#   ./run.sh install [flags]      Install this build as the mnml you live in:
#                                 a verified ReleaseSafe build of the host and
#                                 the shipped integrations to PREFIX/bin
#                                 (default ~/.local), zig-out/share to
#                                 PREFIX/share, and each integration's manifest
#                                 into the STABLE profile's data root pointing
#                                 at PREFIX/bin — so a rebuild in this repo
#                                 never moves the binaries under the running
#                                 stable copy.
#                                   --prefix DIR   where to install (or $PREFIX)
#                                   --dry-run      print every step, change nothing
#                                   --allow-dirty  install from a dirty tree / a
#                                                  Debug build
#                                   --force        overwrite a PREFIX/bin/mnml
#                                                  that is not an mnml-zig
#   ./run.sh install-font         Put MnmlSymbols.ttf in the OS font directory
#                                 (~/Library/Fonts on macOS, ~/.local/share/
#                                 fonts on Linux), MERGING with whatever is
#                                 already there so an older face keeps the
#                                 codepoints this repo has no source for. The
#                                 old file is backed up to ~/Backups/mnml-zig/
#                                 fonts/ first. `install` only prints this step
#                                 — it never touches your font directory.
#                                   --dry-run      print every step, change nothing
#   ./run.sh installed-status     The installed mnml's version and prefix
#                                 against this tree's HEAD, and where the
#                                 stable profile's integration links point.
#
#   On Windows these three verbs are run.ps1's (plus `profile`) — the
#   same semantics, the same refusals, the same --dry-run plan, spelled
#   for PowerShell. docs/WINDOWS.md and docs/INSTALL-CHECKLIST.md.
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
#   MNML_PROFILE      Which mnml this is (default dev for a launch from here:
#                     its own data root ~/.config/mnml-dev, session-dev.zon,
#                     the ipc-zig mailbox and a `dev` chip on the statusline).
#                     `stable` runs this build against the installed mnml's
#                     state. The build / test / check / install verbs never
#                     set it — only a launch does (docs/CONFIG.md, Profiles).
#   PREFIX            Where `install` puts things (default ~/.local).
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
    log "$STALE_REASON — building ${OPTIMIZE}…"
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

# ── install ────────────────────────────────────────────────────────────
# The binaries an install carries: the host as `mnml`, plus one per
# folder under integrations/ named by its manifest's `.binary` line. The
# test fakes (mnml-fake-*) are not integrations and never install; the
# SDK sample is a fixture, so it ships as a binary (the SDK docs run it)
# but its manifest is not registered — a "Sample" chip is not something
# an install should put on your rail. The same set is listed in
# data/marketplace.zon, the catalogue the Marketplace tab reads; both
# derive from integrations/*/manifest.zon, and a unit test
# (src/app/marketplace_catalogue.zig) holds the catalogue to it.
shipped_integrations() {
  local d id bin cat
  for d in "$REPO"/integrations/*/; do
    [ -f "$d/manifest.zon" ] || continue
    id=$(basename "$d")
    bin=$(sed -n 's/^[[:space:]]*\.binary = "\([^"]*\)".*/\1/p' "$d/manifest.zon" | head -n 1)
    cat=$(sed -n 's/^[[:space:]]*\.category = "\([^"]*\)".*/\1/p' "$d/manifest.zon" | head -n 1)
    [ -n "$bin" ] || continue
    printf '%s %s %s\n' "$id" "$bin" "${cat:-integration}"
  done
}

# Is `$1` an mnml-zig? (`--version` says so; the Rust mnml and anything
# else on the machine do not.)
is_ours() {
  [ -x "$1" ] || return 1
  "$1" --version 2>/dev/null | grep -q '^mnml-zig '
}

# The installed mnml's stable data root — asked of the binary itself, so
# the ladder is never duplicated here.
installed_data_root() {
  "$1" profile 2>/dev/null | sed -n 's/^data: *//p' | head -n 1
}

do_install() {
  local prefix="${PREFIX:-$HOME/.local}" dry=0 force=0 allow_dirty=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) shift; prefix="$1" ;;
      --prefix=*) prefix="${1#--prefix=}" ;;
      --dry-run|-n) dry=1 ;;
      --force) force=1 ;;
      --allow-dirty) allow_dirty=1 ;;
      *) log "install: unknown flag $1"; return 2 ;;
    esac
    shift
  done
  local say="install"
  [ "$dry" = 1 ] && say="install --dry-run"

  # 1. A tree you can name. An install you cannot trace back to a commit
  #    is the thing that makes "which mnml is this?" unanswerable.
  #    Every git here only reads, and says `--no-optional-locks`: a
  #    plain `git status` rewrites the index under `.git/index.lock`,
  #    which races a build or a commit in the same checkout and, killed,
  #    leaves the lock behind (tools/run-sh-check.sh holds this).
  local dirty head
  head=$(cd "$REPO" && git --no-optional-locks rev-parse --short HEAD 2>/dev/null || echo unknown)
  dirty=$(cd "$REPO" && git --no-optional-locks status --porcelain 2>/dev/null | head -n 5)
  if [ -n "$dirty" ] && [ "$allow_dirty" = 0 ]; then
    log "$say: the tree is dirty — commit, stash, or pass --allow-dirty"
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    return 1
  fi
  # 2. ReleaseSafe. A Debug mnml is slow enough to be miserable all day.
  if [ "$OPTIMIZE" != ReleaseSafe ] && [ "$allow_dirty" = 0 ]; then
    log "$say: MNML_OPTIMIZE=$OPTIMIZE — install a ReleaseSafe build, or pass --allow-dirty"
    return 1
  fi
  # 3. Not over something that is not ours (the Rust mnml lives here on
  #    this machine, and it is not this program).
  local dest="$prefix/bin/mnml"
  if [ -e "$dest" ] && ! is_ours "$dest" && [ "$force" = 0 ]; then
    log "$say: $dest exists and is not an mnml-zig (\`$dest --version\` does not say so) — pass --force to replace it"
    return 1
  fi

  local built="$REPO/zig-out/bin/mnml-zig"
  if [ "$dry" = 1 ]; then
    log "would build: $ZIG build -Doptimize=ReleaseSafe -Dinstall-names=true"
  else
    log "building ReleaseSafe with the shipped names (-Dinstall-names)…"
    (cd "$REPO" && "$ZIG" build -Doptimize=ReleaseSafe -Dinstall-names=true) || { log "$say: the build failed"; return 1; }
    # 4. Verified: it runs, it says what it is, and it says it defaults
    #    to the stable profile — the whole point of -Dinstall-names.
    local ver
    ver=$("$built" --version 2>/dev/null)
    case "$ver" in
      "mnml-zig "*"(stable profile)") log "verified: $ver" ;;
      *) log "$say: $built --version said \"$ver\" — refusing to install an unverified build"; return 1 ;;
    esac
  fi

  # 5. The files.
  local id bin
  log "$say: prefix $prefix (HEAD $head${dirty:+, dirty})"
  install_one "$dry" "$built" "$prefix/bin/mnml" || return 1
  while read -r id bin cat; do
    [ -n "$id" ] || continue
    install_one "$dry" "$REPO/zig-out/bin/$bin" "$prefix/bin/$bin" || return 1
  done <<EOF2
$(shipped_integrations)
EOF2
  # share/: MnmlSymbols.ttf, data/marketplace.zon (the INTEGRATIONS
  # section's Marketplace default source — an installed mnml probes
  # <exe dir>/../share/mnml/marketplace.zon for it) and whatever else
  # the build puts there.
  if [ -d "$REPO/zig-out/share" ]; then
    if [ "$dry" = 1 ]; then
      (cd "$REPO/zig-out/share" && find . -type f | sed "s|^\./\(.*\)$|  would copy   zig-out/share/\1 → $prefix/share/\1|") >&2
    else
      mkdir -p "$prefix/share"
      cp -R "$REPO/zig-out/share/." "$prefix/share/"
      log "copied zig-out/share → $prefix/share"
    fi
  elif [ "$dry" = 1 ]; then
    log "  (no zig-out/share yet — the build makes it)"
  fi

  # 6. The manifests, in the STABLE profile's data root, pointing at the
  #    binaries just installed. Each integration writes its own
  #    (`<binary> --install`), so the manifest and the binary cannot
  #    drift; `<root>/bin/<name>` is then relinked from this repo's
  #    zig-out to PREFIX/bin, which is the bug this verb exists to fix:
  #    a rebuild here used to move the integrations under the running
  #    stable mnml.
  local root
  if [ "$dry" = 1 ]; then
    root=$(MNML_PROFILE=stable installed_data_root "$built" 2>/dev/null)
    [ -n "$root" ] || root="(the stable data root)"
  else
    root=$(MNML_PROFILE=stable installed_data_root "$prefix/bin/mnml")
    [ -n "$root" ] || { log "$say: could not ask $prefix/bin/mnml for its data root"; return 1; }
  fi
  log "$say: manifests → $root/integrations, links → $root/bin"
  while read -r id bin cat; do
    [ -n "$id" ] || continue
    if [ "$cat" = sample ]; then
      [ "$dry" = 1 ] && echo "  would skip   $bin --install (a fixture, not a chip on your rail)" >&2
      continue
    fi
    if [ "$dry" = 1 ]; then
      echo "  would run    MNML_PROFILE=stable MNML_DATA_ROOT=$root $prefix/bin/$bin --install" >&2
      echo "  would link   $root/bin/$bin → $prefix/bin/$bin" >&2
    else
      MNML_PROFILE=stable MNML_DATA_ROOT="$root" "$prefix/bin/$bin" --install >/dev/null 2>&1 ||
        log "  warning: $bin --install failed (the binary is installed; its manifest is not)"
      mkdir -p "$root/bin"
      rm -f "$root/bin/$bin"
      ln -s "$prefix/bin/$bin" "$root/bin/$bin"
    fi
  done <<EOF2
$(shipped_integrations)
EOF2

  # 7. The font. mnml paints its own block (the tree connectors, the
  #    terminal mark, the unfocused pane's hollow cursor) out of
  #    MnmlSymbols, and a terminal can only find it in the OS font
  #    directory. That is a change to a place outside PREFIX, so
  #    `install` only ever PRINTS it — `install-font` is the verb that
  #    does it, and it merges rather than overwrites.
  echo >&2
  echo "  the symbols font is installed separately — mnml's own glyphs (the tree" >&2
  echo "  connectors, the terminal mark, the unfocused pane's hollow cursor) need it" >&2
  echo "  in your OS font directory, which this verb does not write to:" >&2
  echo >&2
  echo "      ./run.sh install-font" >&2
  echo >&2
  echo "  or by hand (this OVERWRITES; install-font merges instead, keeping any" >&2
  echo "  glyphs an older MnmlSymbols carries that this build does not bake):" >&2
  echo >&2
  echo "      cp $prefix/share/mnml/fonts/MnmlSymbols.ttf $(font_dir)/" >&2
  echo >&2

  if [ "$dry" = 1 ]; then
    log "$say: nothing was changed"
  else
    log "installed. \`$prefix/bin/mnml\` is the stable profile; \`./run.sh\` here is the dev one."
    case ":$PATH:" in
      *":$prefix/bin:"*) ;;
      *) log "note: $prefix/bin is not on your PATH" ;;
    esac
  fi
}

# Where this OS looks for a user's fonts.
font_dir() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Fonts" ;;
    *)      echo "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" ;;
  esac
}

# ── install-font ───────────────────────────────────────────────────────
# The one verb that writes outside the repo and outside PREFIX, which is
# why it is a verb of its own and not a step of `install`.
#
# It MERGES. An already-installed MnmlSymbols may carry codepoints this
# repo has no source for — the Rust-era integration chips, spinners and
# marks around U+F1C03…F1F00 — and copying over the file would take
# them away with no way back. `zig build font-merge` keeps every
# codepoint the installed file maps, replaces the ones this build bakes,
# adds the new ones, and drops an outline no cmap points at. The old
# file is copied to ~/Backups/mnml-zig/fonts/ first, timestamped, so a
# merge that goes wrong is one `cp` from undone.
do_install_font() {
  local dry=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run|-n) dry=1 ;;
      *) log "install-font: unknown flag $1"; return 2 ;;
    esac
    shift
  done
  local say="install-font"
  [ "$dry" = 1 ] && say="install-font --dry-run"
  local dir dest backup_dir stamp
  dir=$(font_dir)
  dest="$dir/MnmlSymbols.ttf"
  backup_dir="$HOME/Backups/mnml-zig/fonts"
  stamp=$(date +%Y%m%d-%H%M%S)

  if [ -f "$dest" ]; then
    log "$say: merging into the installed face at $dest"
    if [ "$dry" = 1 ]; then
      echo "  would back up $dest → $backup_dir/MnmlSymbols-$stamp.ttf" >&2
      echo "  would run    $ZIG build font-merge -Dfont-in=$dest -Dfont-out=$dest" >&2
      log "$say: nothing was changed"
      return 0
    fi
    mkdir -p "$backup_dir" || return 1
    cp "$dest" "$backup_dir/MnmlSymbols-$stamp.ttf" || { log "$say: could not back up $dest"; return 1; }
    echo "  backed up    $dest → $backup_dir/MnmlSymbols-$stamp.ttf" >&2
    # Written through a temp file: a merge that fails must not leave a
    # half-font where a working one was.
    (cd "$REPO" && "$ZIG" build font-merge -Dfont-in="$dest" -Dfont-out="$dest.new") || {
      log "$say: the merge failed — $dest is untouched"; rm -f "$dest.new"; return 1; }
    mv -f "$dest.new" "$dest" || return 1
    echo "  merged       $dest" >&2
  else
    local built="$REPO/zig-out/share/mnml/fonts/MnmlSymbols.ttf"
    log "$say: no MnmlSymbols installed — copying this build's"
    if [ "$dry" = 1 ]; then
      echo "  would run    $ZIG build font" >&2
      echo "  would copy   zig-out/share/mnml/fonts/MnmlSymbols.ttf → $dest" >&2
      log "$say: nothing was changed"
      return 0
    fi
    (cd "$REPO" && "$ZIG" build font) || { log "$say: the font build failed"; return 1; }
    [ -f "$built" ] || { log "$say: $built is missing after the build"; return 1; }
    mkdir -p "$dir" || return 1
    cp "$built" "$dest" || return 1
    echo "  ${built#"$REPO"/} → $dest" >&2
  fi
  log "$say: done. Terminals read the font directory at launch — restart yours."
}

# Copy `$2` to `$3` (or say so, when `$1` is 1), via a temp file so a
# running copy is replaced rather than written through.
install_one() {
  local dry="$1" src="$2" dst="$3"
  if [ "$dry" = 1 ]; then
    if [ -f "$src" ]; then echo "  would copy   ${src#"$REPO"/} → $dst" >&2
    else echo "  would copy   ${src#"$REPO"/} → $dst  (not built yet)" >&2; fi
    return 0
  fi
  [ -f "$src" ] || { log "install: $src is missing — did the build run?"; return 1; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst.new" || return 1
  chmod +x "$dst.new"
  mv -f "$dst.new" "$dst" || return 1
  echo "  ${src#"$REPO"/} → $dst" >&2
}

# What is installed, against what this tree is.
do_installed_status() {
  local prefix="${PREFIX:-$HOME/.local}" dest
  dest="$prefix/bin/mnml"
  local head here
  head=$(cd "$REPO" && git --no-optional-locks rev-parse --short HEAD 2>/dev/null || echo unknown)
  # `git describe --dirty` refreshes the index and writes it back under
  # `.git/index.lock` — `--no-optional-locks` does not stop it — so the
  # `-dirty` is worked out here from a status that takes no lock
  # (tracked files only, as `--dirty` counts them).
  here=$(cd "$REPO" && git --no-optional-locks describe --tags --always 2>/dev/null || echo "$head")
  if [ -n "$(cd "$REPO" && git --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    here="$here-dirty"
  fi
  echo "prefix:    $prefix"
  if [ ! -e "$dest" ]; then
    echo "installed: nothing at $dest (./run.sh install)"
  elif is_ours "$dest"; then
    echo "installed: $("$dest" --version)"
    echo "here:      $here  (HEAD $head)"
    local root
    root=$(MNML_PROFILE=stable installed_data_root "$dest")
    echo "data:      ${root:-?}"
    if [ -n "$root" ] && [ -d "$root/bin" ]; then
      local l t
      for l in "$root"/bin/*; do
        [ -e "$l" ] || continue
        t=$(readlink "$l" || echo "$l")
        case "$t" in
          "$prefix"/*) echo "link:      $(basename "$l") → $t" ;;
          *) echo "link:      $(basename "$l") → $t  (NOT in $prefix — a rebuild there moves it under the running mnml)" ;;
        esac
      done
    fi
  else
    echo "installed: $dest is NOT an mnml-zig (\`--version\` does not say so) — ./run.sh install --force replaces it"
  fi
  exit 0
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
    # Debug: the unit suite through tools/debug-suite-check.sh (the one
    # verdict line, UNIT DEBUG FAILED, a chain stops on), then the e2e
    # gate — together what `zig build test -Doptimize=Debug` ran.
    step "tools/debug-suite-check.sh (the unit suite in Debug)" env MNML_ZIG="$ZIG" bash tools/debug-suite-check.sh
    step "zig build e2e -Doptimize=Debug -- --gate"       "$ZIG" build e2e -Doptimize=Debug -- --gate
    # The trace runner, as the Debug suite has: names each test as it
    # runs and reports a pass on a retry as FLAKY rather than failing.
    step "zig build test -Doptimize=ReleaseSafe -Dtest-trace=true" "$ZIG" build test -Doptimize=ReleaseSafe -Dtest-trace=true
    step "zig build -Doptimize=ReleaseSafe"               "$ZIG" build -Doptimize=ReleaseSafe
    step "mnml-zig test --gate --sizes 80x24,120x40,200x60" ./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60
    step "mnml-zig test (the corpus, MNML_E2E_ALLOW_SHELL=$MNML_E2E_ALLOW_SHELL)" ./zig-out/bin/mnml-zig test
    step "zig build glyph-audit"                          "$ZIG" build glyph-audit
    step "zig build chrome-audit"                         "$ZIG" build chrome-audit
    step "zig build hover-audit"                          "$ZIG" build hover-audit
    # Every shipped target compiled (exe, test binaries, integrations):
    # target-gated code is analysed only when its target is built, so a
    # native-green tree can still not compile for Windows or Linux.
    step "zig build gate-targets (all five shipped targets)" "$ZIG" build gate-targets
    step "tools/run-sh-check.sh"                          bash tools/run-sh-check.sh
    # run.ps1's structure: balance, quoting, the 5.1-incompatible
    # spellings, every verb reachable, the refusals and plan phrases
    # present. The real check (tools/run-ps1-check.ps1) needs a
    # PowerShell; there is none here, so it runs on the Windows guest
    # instead — docs/INSTALL-CHECKLIST.md, Windows 11 step W-0.
    if command -v python3 >/dev/null 2>&1; then
      step "tools/run-ps1-check.py (run.ps1 structure; no pwsh here)" python3 tools/run-ps1-check.py
    else
      log "check: no python3 — skipping tools/run-ps1-check.py"
    fi
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
  install)         shift; do_install "$@"; exit $? ;;
  install-font)    shift; do_install_font "$@"; exit $? ;;
  installed-status) do_installed_status ;;
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
        "install — install this build as the mnml you live in"
        "install-font — merge MnmlSymbols into your OS font directory"
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
            9) exec "$0" install ;;
            10) exec "$0" install-font ;;
            11) echo "bye"; exit 0 ;;
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
    echo
    do_installed_status ;;
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

# A launch from this repo is the dev profile unless you say otherwise:
# its own data root, session file, IPC mailbox, marker and a `dev` chip
# on the statusline, so it never touches the mnml you live in
# (docs/CONFIG.md, "Profiles"). Only a LAUNCH — build / test / check /
# install run in the stable profile, where the corpus and the installed
# binary live.
export MNML_PROFILE="${MNML_PROFILE:-dev}"

EXTRA=()
[ "$HEADLESS" = 1 ] && EXTRA+=(--headless)

# The loop below catches `app.restart`'s exit 75 (rebuild + relaunch);
# without this the app relaunches itself instead (src/main.zig).
export MNML_RUN_LOOP=1

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
