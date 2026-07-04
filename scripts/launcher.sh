#!/bin/bash
# mnml-launcher — the executable inside mnml.app.
#
# Opens mnml in Ghostty when available, else falls back to
# Terminal.app.
#
# Pathing: the executable lives at <Bundle>/Contents/MacOS/mnml-launcher;
# the actual mnml binary ships at <Bundle>/Contents/Resources/bin/mnml.
# Resolve the bundle root from $0 so the .app is relocatable.
#
# NOTE: do NOT use `set -eu`. Finder strips PATH; if we then `source
# ~/.zshrc` to recover it, any unset-variable reference in the
# user's zshrc trips `set -u` and the launcher exits silently with
# no window opening. Both bit us before — keep error handling
# explicit instead.

bundle_root="$(cd "$(dirname "$0")/../.." && pwd)"
mnml_bin="$bundle_root/Contents/Resources/bin/mnml"
log_file="${TMPDIR:-/tmp}/mnml-launcher.log"

{
  echo "----"
  echo "$(date '+%Y-%m-%d %H:%M:%S') mnml-launcher starting"
  echo "  bundle_root=$bundle_root"
  echo "  mnml_bin=$mnml_bin"
} >> "$log_file" 2>&1

# Recover a useful PATH without sourcing user rc files (those are
# untrusted code from this launcher's perspective). Static set of the
# common locations covers Homebrew (Apple Silicon + Intel), cargo,
# and the inherited system PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
echo "  PATH=$PATH" >> "$log_file"

# Prepend the bundled binary's dir so a packaged mnml wins over a
# globally-installed one.
export PATH="$bundle_root/Contents/Resources/bin:$PATH"

# Prefer Ghostty (better Nerd Font rendering, native macOS feel),
# fall back to Terminal.app.
ghostty_bin=""
if command -v ghostty >/dev/null 2>&1; then
    ghostty_bin="$(command -v ghostty)"
elif [ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]; then
    ghostty_bin="/Applications/Ghostty.app/Contents/MacOS/ghostty"
fi
if [ -n "$ghostty_bin" ]; then
    # Force the ARM64 slice of Ghostty's universal binary on Apple
    # Silicon so we can't accidentally launch under Rosetta if a
    # parent process (Finder, Launcher, whatever) was translated. The
    # `arch` tool is a no-op when the requested slice matches the
    # native arch, so on Intel it just falls through to arch=x86_64.
    host_arch="$(/usr/bin/uname -m 2>/dev/null || echo unknown)"
    if [ "$host_arch" = "arm64" ]; then
        echo "  arm64 host — exec /usr/bin/arch -arm64 ghostty -e mnml" >> "$log_file"
        exec /usr/bin/arch -arm64 "$ghostty_bin" -e "$mnml_bin"
    else
        echo "  $host_arch host — exec ghostty -e mnml" >> "$log_file"
        exec "$ghostty_bin" -e "$mnml_bin"
    fi
fi
echo "  ghostty not found — falling back to Terminal.app" >> "$log_file"
osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$mnml_bin'"
end tell
EOF
