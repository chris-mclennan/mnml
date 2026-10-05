#!/usr/bin/env bash
# demo/selftest.sh — check a built demo image before anyone sees it.
#
#   demo/selftest.sh [IMAGE]        (default mnml-demo:local)
#
# Runs attract/selftest.py in a throwaway container from IMAGE, with no
# network, as the image's own user: a headless `mnml --demo` at the
# page's 200x60 grid, driven through the file channel. It fails when the
# Jira or Bitbucket integration is missing (manifests, statusline
# segments, rail launchers, panes) or when a private-use glyph the app
# puts on screen is in none of the fonts the page serves. demo/build.sh
# runs it after every build; exit status is the test's.
set -euo pipefail
IMAGE=${1:-mnml-demo:local}
PLATFORM=$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')
exec docker run --rm --network none --memory 1g --pids-limit 512 --platform "$PLATFORM" \
  --entrypoint python3 "$IMAGE" /opt/mnml-demo/attract/selftest.py
