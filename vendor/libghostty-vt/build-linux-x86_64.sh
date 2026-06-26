#!/usr/bin/env bash
# Cross-build libghostty-vt.a for x86_64-linux inside a debian:bookworm
# container. Zig 0.15.2 is downloaded fresh; ghostty is pinned to the
# commit the libghostty-vt-sys 0.2.0 crate expects.
#
# Usage (from the host):
#   docker run --rm \
#     -v "$(pwd)/out":/out \
#     -v "$(pwd)/build-linux-x86_64.sh":/build.sh:ro \
#     debian:bookworm-slim bash /build.sh
#
# The result lands at out/lib/libghostty-vt.a — copy or symlink that
# into vendor/libghostty-vt/lib-x86_64-linux/.
set -euo pipefail

ZIG_VERSION="0.15.2"
# Zig changed download path naming around 0.14 — it's now
# `zig-x86_64-linux-VERSION.tar.xz` (arch first).
ZIG_TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT="fdbf9ff3a31d7531b691cb49c98fc465a1a503a0"

# Container deps. `xz-utils` for the Zig tarball, `git` for ghostty,
# `curl` to download, `ca-certificates` for HTTPS.
apt-get update
apt-get install --no-install-recommends -y \
    git curl ca-certificates xz-utils

# Zig 0.15.2 — ghostty pins this version; newer / older won't work.
mkdir -p /opt
cd /opt
curl -fsSL -O "$ZIG_URL"
tar xf "$ZIG_TARBALL"
ZIG_DIR="/opt/zig-x86_64-linux-${ZIG_VERSION}"
export PATH="$ZIG_DIR:$PATH"
zig version

# Clone ghostty at the pinned commit (shallow + unshallow the commit).
mkdir -p /work
cd /work
git init ghostty
cd ghostty
git remote add origin "$GHOSTTY_REPO"
git fetch --depth=1 origin "$GHOSTTY_COMMIT"
git checkout "$GHOSTTY_COMMIT"

# Cross-compile to x86_64-linux. The same flag-set the libghostty-vt-sys
# README recommends, minus the macOS xcframework bits.
zig build \
    --seed 0 \
    -Demit-lib-vt=true \
    -Dapp-runtime=none \
    -Demit-xcframework=false \
    -Doptimize=ReleaseFast \
    -Dcpu=baseline \
    -Dtarget=x86_64-linux \
    --prefix /out

# Sanity: file out/lib/libghostty-vt.a should report
# `ar archive` with x86-64 ELF members.
file /out/lib/libghostty-vt.a
ls -la /out/lib/
