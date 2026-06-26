#!/usr/bin/env bash
# Build libghostty-vt.a for aarch64-linux, native on linux/arm64
# (Apple Silicon — no emulation needed). Mirrors
# build-linux-x86_64-from-arm64.sh; only the `-Dtarget` changes.
# The `--seed 0` / `-Dcpu=baseline` flags dodge a Zig 0.15.2 stdlib
# panic during dependency-graph construction.
#
# Usage (from the host):
#   docker run --rm --platform linux/arm64 \
#     -v "$(pwd)/out":/out \
#     -v "$(pwd)/build-aarch64-linux-from-arm64.sh":/build.sh:ro \
#     debian:bookworm-slim bash /build.sh
set -euo pipefail

ZIG_VERSION="0.15.2"
ZIG_TARBALL="zig-aarch64-linux-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT="fdbf9ff3a31d7531b691cb49c98fc465a1a503a0"

apt-get update
apt-get install --no-install-recommends -y \
    git curl ca-certificates xz-utils

mkdir -p /opt
cd /opt
curl -fsSL -O "$ZIG_URL"
tar xf "$ZIG_TARBALL"
ZIG_DIR="/opt/zig-aarch64-linux-${ZIG_VERSION}"
export PATH="$ZIG_DIR:$PATH"
zig version

mkdir -p /work
cd /work
git init ghostty
cd ghostty
git remote add origin "$GHOSTTY_REPO"
git fetch --depth=1 origin "$GHOSTTY_COMMIT"
git checkout "$GHOSTTY_COMMIT"

zig build \
    -Demit-lib-vt=true \
    -Dapp-runtime=none \
    -Demit-xcframework=false \
    -Doptimize=ReleaseFast \
    -Dcpu=baseline \
    -Dtarget=aarch64-linux \
    --prefix /out

file /out/lib/libghostty-vt.a
ls -la /out/lib/
