#!/usr/bin/env bash
# run.sh — run the mnml-zig gate on Linux, from a Mac (or from Linux).
#
#   tools/linux/run.sh [build|unit|gate|corpus|mouse|fmt|all|shell]
#   tools/linux/run.sh raw <command…>      # anything, inside the container
#
# The repo is mounted read-only; the container builds in its own copy, so a
# Linux run never touches the host's .zig-cache or zig-out. The Zig package
# cache and the build cache are docker volumes, so only the first run pays
# for fetching dependencies.
#
# Needs docker (or podman — set MNML_LINUX_ENGINE=podman).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${MNML_LINUX_ENGINE:-docker}
IMAGE=${MNML_LINUX_IMAGE:-mnml-zig-linux-gate}
VOL_WORK=${MNML_LINUX_VOL_WORK:-mnml-zig-linux-work}
VOL_PKG=${MNML_LINUX_VOL_PKG:-mnml-zig-linux-pkg}

command -v "$ENGINE" >/dev/null 2>&1 || {
  cat >&2 <<EOF
$ENGINE is not installed. Install Docker Desktop:

    brew install --cask docker

then start it once and re-run this script. (podman works too:
\`brew install podman && podman machine init && podman machine start\`,
then MNML_LINUX_ENGINE=podman tools/linux/run.sh …)
EOF
  exit 127
}

PHASE=${1:-all}
[ $# -gt 0 ] && shift || true

# --platform only when the host is not already the image's architecture.
PLATFORM_ARGS=()
if [ -n "${MNML_LINUX_PLATFORM:-}" ]; then
  PLATFORM_ARGS=(--platform "$MNML_LINUX_PLATFORM")
fi

if ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || [ "${MNML_LINUX_REBUILD:-0}" = 1 ]; then
  echo "== building $IMAGE (first run downloads Zig + the fonts)"
  "$ENGINE" build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -t "$IMAGE" "$ROOT/tools/linux"
fi

"$ENGINE" volume create "$VOL_WORK" >/dev/null
"$ENGINE" volume create "$VOL_PKG" >/dev/null

exec "$ENGINE" run --rm -i ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
  -v "$ROOT":/repo:ro \
  -v "$VOL_WORK":/work \
  -v "$VOL_PKG":/zig-global-cache \
  "$IMAGE" "$PHASE" "$@"
