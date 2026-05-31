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

set -eu

bundle_root="$(cd "$(dirname "$0")/../.." && pwd)"
mnml_bin="$bundle_root/Contents/Resources/bin/mnml"

# Make sure the user's normal PATH is loaded — Finder/LaunchServices
# strips $PATH down to a system minimum, so a Homebrew-installed
# `tmnl` won't be visible unless we source the shell profile.
if [ -f "$HOME/.zshrc" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.zshrc" 2>/dev/null || true
fi
if [ -f "$HOME/.bash_profile" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.bash_profile" 2>/dev/null || true
fi
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin"

if command -v tmnl >/dev/null 2>&1; then
    # tmnl present — launch mnml as a native pane inside tmnl.
    exec tmnl --mnml --editor "$mnml_bin"
fi

# Fallback — no tmnl on PATH. Open Terminal.app with mnml running
# in $HOME. The user can install tmnl later for the richer UX.
osascript <<EOF
tell application "Terminal"
    activate
    do script "exec '$mnml_bin'"
end tell
EOF
