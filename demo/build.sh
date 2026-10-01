#!/usr/bin/env bash
# demo/build.sh — build the web demo's image (default tag mnml-demo:local).
#
#   demo/build.sh [TAG]
#
# The context is the repository's tracked (and new, not ignored) files,
# streamed as a tar: the legacy docker builder has no per-Dockerfile
# ignore file, and the checkout's zig-pkg/ and .zig-cache/ are gigabytes
# the image does not need (the Dockerfile fetches the packages itself).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:-mnml-demo:local}
cd "$ROOT"
VERSION=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -1)+g$(git rev-parse --short HEAD)
# A local image with Zig 0.16 already in it saves the tarball download.
BUILDER_ARGS=()
for img in ${MNML_DEMO_BUILDER:-mnml-zig-linux-gate mnml-pty-stress}; do
  if docker image inspect "$img" >/dev/null 2>&1; then BUILDER_ARGS=(--build-arg "BUILDER=$img"); break; fi
done
start=$(date +%s)
# zig-pkg/ (git-ignored) rides along when the checkout has fetched it, so
# the image does not download the packages again; an empty one otherwise.
mkdir -p zig-pkg
{ git ls-files -z -co --exclude-standard; printf 'zig-pkg\0'; } \
  | COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --null -T - -cf - \
  | docker build -f demo/Dockerfile ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} --build-arg MNML_VERSION="$VERSION" -t "$TAG" -
echo "demo/build.sh: $TAG built in $(( $(date +%s) - start ))s; $(docker image inspect "$TAG" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1e6}')"
