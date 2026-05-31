#!/usr/bin/env bash
#
# dist-check — run cargo-dist's validation locally before pushing a tag.
#
# `dist plan` does the same plan-job validation the CI runs (reads
# dist-workspace.toml + Cargo metadata, computes the matrix, checks
# WiX GUIDs + wix/main.wxs + profile.dist + sibling path-deps). If
# it fails locally, the tag-and-push will fail in CI ~10 min later
# at the same point — but on the cloud's dime.
#
# `dist build --artifacts=local` then attempts a real build for the
# current host triple. Catches dep / compile / sibling-clone issues
# that `plan` can't.
#
# Doesn't catch cross-platform-only failures (Windows-specific code,
# Linux-only system deps) — those still need CI. But ~80% of the
# config errors that cost CI minutes today are caught here in
# seconds.
#
# Usage:
#   ./scripts/dist-check.sh          # plan + local build
#   ./scripts/dist-check.sh plan     # just the plan job (fastest)

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v dist >/dev/null 2>&1; then
    echo "error: cargo-dist's \`dist\` binary not on PATH." >&2
    echo "       install with: cargo install cargo-dist --version 0.32.0" >&2
    exit 1
fi

MODE="${1:-full}"

echo "── dist plan ──"
dist plan

if [ "$MODE" = "plan" ]; then
    echo
    echo "✓ plan only — skipping local build (pass no arg for full check)"
    exit 0
fi

echo
echo "── dist build --artifacts=local ──"
dist build --artifacts=local

echo
echo "✓ local validation passed. ok to tag + push."
