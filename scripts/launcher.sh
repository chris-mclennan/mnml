#!/bin/bash
# mnml-launcher — the executable inside mnml.app.
#
# Dispatch logic:
# - If `tmnl` is on PATH, open mnml inside a tmnl native tab
#   (GPU-rendered, family-aware). This is the "all three installed"
#   path and what the family icon-trio is meant to provide.
# - Otherwise fall back to opening mnml standalone in macOS's
#   Terminal.app. Works without tmnl, but loses tab/pane integration.
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

# Resolve tmnl, in order: $PATH → /Applications/tmnl.app bundle
# binary (the GUI installer doesn't always create a CLI symlink, so
# we hard-code that fallback).
tmnl_bin=""
if command -v tmnl >/dev/null 2>&1; then
    tmnl_bin="$(command -v tmnl)"
elif [ -x "/Applications/tmnl.app/Contents/MacOS/tmnl" ]; then
    tmnl_bin="/Applications/tmnl.app/Contents/MacOS/tmnl"
fi

if [ -n "$tmnl_bin" ]; then
    echo "  found tmnl at $tmnl_bin — exec tmnl --mnml" >> "$log_file"
    # tmnl resolves mnml via PATH; we prepended our bundled bin
    # above so the packaged mnml wins. Override tmnl's default
    # arg list so the icon-launch honors the user's configured
    # `[startup] default_workspace`. 2026-06-19 — earlier this
    # path passed `--no-workspace` to force the empty-state
    # landing on icon click, but that overrode the user's
    # explicit config every time. Now: if default_workspace is
    # set, open it; otherwise mnml falls through to the empty-
    # state landing on its own.
    export TMNL_LAUNCH_ARGS="--input standard"
    exec "$tmnl_bin" --mnml
fi

echo "  tmnl not found anywhere — falling back to Terminal.app" >> "$log_file"
osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$mnml_bin'"
end tell
EOF
