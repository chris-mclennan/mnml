#!/bin/bash
# mnml-nightly-launcher — the executable inside mnml-nightly.app.
#
# Always launches the LATEST cargo release-build from the source
# tree at $HOME/Projects/mnml/target/release/mnml (no bundled
# binary). The whole point of the nightly icon is "click and get
# whatever I just compiled."
#
# Dispatch: same shape as the stable launcher — go through tmnl
# when available, fall back to Terminal.app. Prepends the dev
# binary's directory to PATH so `tmnl --mnml` resolves the
# nightly mnml (not whatever's globally installed).

dev_bin="$HOME/Projects/mnml/target/release/mnml"
src_root="$HOME/Projects/mnml"
log_file="${TMPDIR:-/tmp}/mnml-nightly-launcher.log"

{
  echo "----"
  echo "$(date '+%Y-%m-%d %H:%M:%S') mnml-nightly-launcher starting"
  echo "  dev_bin=$dev_bin"
} >> "$log_file" 2>&1

# Finder launches us with a minimal PATH that omits ~/.cargo/bin, so
# the auto-rebuild below would fail with `cargo: command not found`
# (the PATH export further down was too late — it only ran on the exec
# path, after the build). Set a usable PATH up front, before any cargo
# call. Covers rustup's ~/.cargo/bin plus the Homebrew prefixes where a
# brew-installed cargo might live.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# 2026-06-19 — auto-rebuild on demand. If the binary doesn't exist
# OR any source file is newer than the binary, rebuild before
# launching. cargo's incremental compile is ~5–15s when stale;
# a no-op is ~0.5s. User-requested: "can the icon just build if
# needed and not when not needed".
needs_build="no"
if [ ! -x "$dev_bin" ]; then
    needs_build="yes (no binary)"
elif [ -d "$src_root/src" ]; then
    # find returns paths of any source newer than the binary;
    # head -1 short-circuits at the first match.
    newer="$(find "$src_root/src" "$src_root/Cargo.toml" "$src_root/Cargo.lock" -newer "$dev_bin" -type f 2>/dev/null | head -1)"
    if [ -n "$newer" ]; then
        needs_build="yes ($newer)"
    fi
fi

if [ "$needs_build" != "no" ]; then
    echo "  needs_build=$needs_build" >> "$log_file"
    # Non-blocking notification (GUI notification — disappears
    # automatically). Background it so we don't have to wait.
    osascript -e "display notification \"Rebuilding mnml (incremental — usually <15s)\" with title \"mnml-nightly\"" 2>/dev/null &
    # Build with `--locked` for reproducibility against Cargo.lock.
    if ! (cd "$src_root" && cargo build --release 2>>"$log_file"); then
        osascript <<EOF
display dialog "mnml-nightly: build failed.\n\nSee $log_file for details." buttons {"OK"} default button "OK" with icon caution
EOF
        exit 1
    fi
fi

if [ ! -x "$dev_bin" ]; then
    osascript <<EOF
display dialog "mnml-nightly: no build at $dev_bin\n\nRun 'cargo build --release' in ~/Projects/mnml first." buttons {"OK"} default button "OK" with icon caution
EOF
    exit 1
fi

export PATH="$(dirname "$dev_bin"):/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Resolve tmnl, in order: $PATH → /Applications/tmnl-nightly.app
# (prefer nightly tmnl) → /Applications/tmnl.app (stable).
tmnl_bin=""
if [ -x "/Applications/tmnl-nightly.app/Contents/MacOS/tmnl" ]; then
    tmnl_bin="/Applications/tmnl-nightly.app/Contents/MacOS/tmnl"
elif command -v tmnl >/dev/null 2>&1; then
    tmnl_bin="$(command -v tmnl)"
elif [ -x "/Applications/tmnl.app/Contents/MacOS/tmnl" ]; then
    tmnl_bin="/Applications/tmnl.app/Contents/MacOS/tmnl"
fi

if [ -n "$tmnl_bin" ]; then
    echo "  found tmnl at $tmnl_bin — exec tmnl --mnml" >> "$log_file"
    # 2026-06-19 — removed --no-workspace so the user's
    # configured [startup] default_workspace is honored on icon
    # click. Empty-state landing is the fall-through when nothing
    # is configured.
    export TMNL_LAUNCH_ARGS="--input standard"
    exec "$tmnl_bin" --mnml
fi

echo "  tmnl not found — falling back to Terminal.app" >> "$log_file"
osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$dev_bin'"
end tell
EOF
