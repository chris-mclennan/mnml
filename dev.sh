#!/usr/bin/env bash
# Auto-rebuild + restart mnml on source changes. Needs `cargo-watch`:
#   cargo install cargo-watch        # one-time
#   ./dev.sh [WORKSPACE]             Interactive TUI, restarts on src/ change
#   ./dev.sh --headless [WORKSPACE]  Headless + file-IPC, restarts on src/ change
set -euo pipefail
cd "$(dirname "$0")"

# libghostty-vt-sys's build.rs needs `zig` on PATH — see run.sh for
# the same prepend. Without it, cargo build silently fails.
for ZIG_DIR in /opt/homebrew/opt/zig@0.15/bin /opt/homebrew/opt/zig/bin; do
  if [ -x "$ZIG_DIR/zig" ] && [[ ":$PATH:" != *":$ZIG_DIR:"* ]]; then
    export PATH="$ZIG_DIR:$PATH"
    break
  fi
done

if ! command -v cargo-watch >/dev/null 2>&1; then
  echo "cargo-watch not installed. Install with: cargo install cargo-watch" >&2
  exit 1
fi

# -w src so editing the binary's own dirs doesn't loop; -x run rebuilds + reruns.
exec cargo watch -q -c -w src -w Cargo.toml -x "run -- $*"
