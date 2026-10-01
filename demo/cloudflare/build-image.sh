#!/usr/bin/env bash
# demo/cloudflare/build-image.sh — the base image wrangler builds on:
# mnml-demo:cf-amd64, demo/Dockerfile for linux/amd64, with the Linux
# binaries cross-compiled on this machine (demo/build.sh --cross).
#
# Needs docker's buildx plugin (wrangler needs it too): `docker buildx
# version` must answer. Re-run after changing the app or demo/.
set -euo pipefail
exec "$(cd "$(dirname "$0")/.." && pwd)/build.sh" mnml-demo:cf-amd64 --cross --platform linux/amd64 "$@"
