#!/usr/bin/env bash
# Auto-rebuild + restart mnml on source changes. Needs `cargo-watch`:
#   cargo install cargo-watch        # one-time
#   ./dev.sh [WORKSPACE]             Interactive TUI, restarts on src/ change
#   ./dev.sh --headless [WORKSPACE]  Headless + file-IPC, restarts on src/ change
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v cargo-watch >/dev/null 2>&1; then
  echo "cargo-watch not installed. Install with: cargo install cargo-watch" >&2
  exit 1
fi

# -w src so editing the binary's own dirs doesn't loop; -x run rebuilds + reruns.
exec cargo watch -q -c -w src -w Cargo.toml -x "run -- $*"
