#!/usr/bin/env bash
# demo/build.sh — build the web demo's image (default tag mnml-demo:local).
#
#   demo/build.sh [TAG] [--cross]
#
# --cross: build the Linux binaries here, with this machine's Zig
# (cross-compiling to the docker engine's architecture), and hand them to
# the image instead of compiling inside docker — minutes rather than
# a quarter hour, and no compile space on docker's disk.
#
# The context is the repository's tracked (and new, not ignored) files,
# streamed as a tar: the legacy docker builder has no per-Dockerfile
# ignore file, and the checkout's zig-pkg/ and .zig-cache/ are gigabytes
# the image does not need (the Dockerfile fetches the packages itself).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=mnml-demo:local CROSS=0
for a in "$@"; do case "$a" in --cross) CROSS=1 ;; *) TAG=$a ;; esac; done
cd "$ROOT"
VERSION=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -1)+g$(git log -1 --format=%h -- . ":(exclude)demo")
# A local image with Zig 0.16 already in it saves the tarball download.
BUILDER_ARGS=()
for img in ${MNML_DEMO_BUILDER:-mnml-zig-linux-gate mnml-pty-stress}; do
  if docker image inspect "$img" >/dev/null 2>&1; then BUILDER_ARGS=(--build-arg "BUILDER=$img"); break; fi
done
start=$(date +%s)
# zig-out/ is git-ignored scratch: the staged extras live there and are
# renamed into the context's root by tar's -s.
STAGE_REL=zig-out/demo-stage
STAGE=$ROOT/$STAGE_REL
rm -rf "$STAGE"
mkdir -p "$STAGE/demo-prebuilt" "$STAGE/zig-pkg"
PKG=$STAGE_REL/zig-pkg
if [ "$CROSS" = 1 ]; then
  case "$(docker info -f '{{.Architecture}}')" in
    aarch64|arm64) ZT=aarch64-linux-gnu ;; x86_64|amd64) ZT=x86_64-linux-gnu ;;
    *) echo "build.sh: unknown docker architecture" >&2; exit 1 ;;
  esac
  echo "build.sh: zig build -Dtarget=$ZT (ReleaseSafe) on this machine"
  zig build -Dtarget="$ZT" -Doptimize=ReleaseSafe -Dinstall-names -Dversion="$VERSION" --prefix "$STAGE/demo-prebuilt"
elif [ -d zig-pkg ]; then
  # zig-pkg/ (git-ignored) rides along when the checkout has fetched it, so
  # the image does not download the packages again; an empty one otherwise.
  PKG=zig-pkg
fi
{ git ls-files -z -co --exclude-standard; printf '%s\0' "$PKG" "$STAGE_REL/demo-prebuilt"; } \
  | COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --null -s ",^$STAGE_REL/,," -cf - -T - \
  | docker build -f demo/Dockerfile ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} --build-arg MNML_VERSION="$VERSION" -t "$TAG" -
echo "demo/build.sh: $TAG built in $(( $(date +%s) - start ))s; $(docker image inspect "$TAG" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1e6}')"
