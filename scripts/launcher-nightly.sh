#!/bin/bash
# mnml-nightly-launcher — the executable inside mnml-nightly.app.
#
# Always launches the LATEST cargo release-build from the source
# tree at $HOME/Projects/mnml/target/release/mnml (no bundled
# binary). The whole point of the nightly icon is "click and get
# whatever I just compiled."
#
# 2026-06-22 — tmnl integration removed; the launcher opens
# mnml in macOS's Terminal.app.

dev_bin="$HOME/Projects/mnml/target/release/mnml"
src_root="$HOME/Projects/mnml"
log_file="${TMPDIR:-/tmp}/mnml-nightly-launcher.log"

{
  echo "----"
  echo "$(date '+%Y-%m-%d %H:%M:%S') mnml-nightly-launcher starting"
  echo "  dev_bin=$dev_bin"
} >> "$log_file" 2>&1

# Finder launches us with a minimal PATH that omits ~/.cargo/bin, so
# the auto-rebuild below would fail with `cargo: command not found`.
# Set a usable PATH up front, before any cargo call. Covers rustup's
# ~/.cargo/bin plus the Homebrew prefixes where a brew-installed
# cargo might live.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Auto-rebuild on demand. If the binary doesn't exist OR any source
# file is newer than the binary, rebuild before launching. cargo's
# incremental compile is ~5–15s when stale; a no-op is ~0.5s.
needs_build="no"
if [ ! -x "$dev_bin" ]; then
    needs_build="yes (no binary)"
elif [ -d "$src_root/src" ]; then
    newer="$(find "$src_root/src" "$src_root/Cargo.toml" "$src_root/Cargo.lock" -newer "$dev_bin" -type f 2>/dev/null | head -1)"
    if [ -n "$newer" ]; then
        needs_build="yes ($newer)"
    fi
fi

if [ "$needs_build" != "no" ]; then
    echo "  needs_build=$needs_build" >> "$log_file"
    osascript -e "display notification \"Rebuilding mnml (incremental — usually <15s)\" with title \"mnml-nightly\"" 2>/dev/null &
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

osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$dev_bin'"
end tell
EOF
