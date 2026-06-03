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
log_file="${TMPDIR:-/tmp}/mnml-nightly-launcher.log"

{
  echo "----"
  echo "$(date '+%Y-%m-%d %H:%M:%S') mnml-nightly-launcher starting"
  echo "  dev_bin=$dev_bin"
} >> "$log_file" 2>&1

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
    echo "  found tmnl at $tmnl_bin — exec tmnl --mnml --startup-picker" >> "$log_file"
    export TMNL_LAUNCH_ARGS="--input standard --startup-picker"
    exec "$tmnl_bin" --mnml
fi

echo "  tmnl not found — falling back to Terminal.app" >> "$log_file"
osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$dev_bin'"
end tell
EOF
