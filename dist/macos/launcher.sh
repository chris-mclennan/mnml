#!/bin/sh
# mnml-launcher — the executable inside mnml.app.
#
# A Finder launch has no terminal, so this opens one and runs the
# bundled mnml in it: ghostty when it is installed (the CLI on PATH, or
# the app bundle's own binary), Terminal.app otherwise. The startup
# picker is on (`MNML_STARTUP_PICKER=1`) so an icon click lands on the
# chooser rather than on `$HOME`.
#
# The launcher lives at <mnml.app>/Contents/MacOS/mnml-launcher and the
# binary at <mnml.app>/Contents/Resources/bin/mnml; the bundle root is
# resolved from $0 so the .app can move.
#
# No `set -eu`: Finder hands over a bare PATH, and the recovery below
# must not exit silently on an unset variable.

bundle_root="$(cd "$(dirname "$0")/../.." && pwd)"
mnml_bin="$bundle_root/Contents/Resources/bin/mnml"
log_file="${TMPDIR:-/tmp}/mnml-launcher.log"

{
    echo "----"
    echo "$(date '+%Y-%m-%d %H:%M:%S') mnml-launcher starting"
    echo "  bundle_root=$bundle_root"
} >> "$log_file" 2>&1

# A usable PATH without sourcing rc files (untrusted from here): the
# bundled binary first, then Homebrew (both arches), then the system.
export PATH="$bundle_root/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export MNML_STARTUP_PICKER=1

ghostty_bin=""
if command -v ghostty >/dev/null 2>&1; then
    ghostty_bin="$(command -v ghostty)"
elif [ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]; then
    ghostty_bin="/Applications/Ghostty.app/Contents/MacOS/ghostty"
fi

if [ -n "$ghostty_bin" ]; then
    echo "  ghostty at $ghostty_bin" >> "$log_file"
    exec "$ghostty_bin" -e "$mnml_bin"
fi

echo "  no ghostty — Terminal.app" >> "$log_file"
# Terminal inherits nothing of this environment: pass the picker along.
osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "MNML_STARTUP_PICKER=1 exec '$mnml_bin'"
end tell
APPLESCRIPT
