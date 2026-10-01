#!/usr/bin/env bash
# demo/run-local.sh — the web demo's local trial: one fresh container.
#
#   demo/run-local.sh [--port N] [--cap SECONDS] [--idle SECONDS] [--rebuild] [--dev]
#   demo/run-local.sh stop [NAME…]     # stop this script's containers (all, or the named)
#
# Starts mnml-demo-<port>-<id>, a NEW container from mnml-demo:local
# (built by demo/build.sh on first use, or with --rebuild), and prints the
# URL. The demo runs with `--network none` — no route anywhere — and a
# second container, mnml-demo-<port>-<id>-relay, publishes the port on
# 127.0.0.1 and splices it to the demo's socket (attract/relay.py): docker
# drops published ports on a network-less container. Both are --rm and
# share one volume, removed by `stop`.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${MNML_DEMO_IMAGE:-mnml-demo:local}
PORT=7681 CAP=600 IDLE=180 REBUILD=0 DEV=()

stop_all() {
  local names=("$@") n
  if [ $# -eq 0 ]; then
    names=()
    while IFS= read -r n; do names+=("$n"); done < <(docker ps -a --filter label=mnml-demo=1 --format '{{.Names}}' | grep -v -- '-relay$' || true)
  fi
  for n in ${names[@]+"${names[@]}"}; do
    docker rm -f "$n" "$n-relay" >/dev/null 2>&1 || true
    docker volume rm "$n-sock" >/dev/null 2>&1 || true
    echo "stopped $n"
  done
}

if [ "${1:-}" = stop ]; then shift; stop_all "$@"; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2 ;;
    --cap) CAP=$2; shift 2 ;;
    --idle) IDLE=$2; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    # this checkout's runner, flows and page over the image's (no rebuild)
    --dev) D="$ROOT/demo"; DEV=(-e MNML_DEMO_DEV=1 -v "$D/attract:/opt/mnml-demo/attract:ro" -v "$D/flows:/opt/mnml-demo/flows:ro"
             -v "$D/web/index.html:/opt/mnml-demo/web/index.html:ro")
           # an image older than the page's own xterm.js: a local copy (git-ignored)
           [ -d "$D/web/vendor" ] && DEV+=(-v "$D/web/vendor:/opt/mnml-demo/web/vendor:ro"); shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "run-local.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  "$ROOT/demo/build.sh" "$IMAGE"
fi

ID=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
NAME="mnml-demo-$PORT-$ID"
VOL="$NAME-sock"
docker volume create --label mnml-demo=1 "$VOL" >/dev/null
docker run -d --rm --name "$NAME" --label mnml-demo=1 \
  --network none \
  --mount "type=volume,src=$VOL,dst=/run/mnml-demo" \
  --memory 1g --pids-limit 512 --cpus 2 \
  -e MNML_DEMO_LISTEN=unix:/run/mnml-demo/http.sock \
  -e MNML_DEMO_CAP_S="$CAP" -e MNML_DEMO_IDLE_S="$IDLE" \
  ${DEV[@]+"${DEV[@]}"} "$IMAGE" >/dev/null
docker run -d --rm --name "$NAME-relay" --label mnml-demo=1 \
  --mount "type=volume,src=$VOL,dst=/run/mnml-demo" \
  -p "127.0.0.1:$PORT:7681" \
  --entrypoint python3 "$IMAGE" /opt/mnml-demo/attract/relay.py >/dev/null
for _ in $(seq 1 50); do
  curl -fsS -m 1 "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "$NAME: http://localhost:$PORT  (cap ${CAP}s, idle ${IDLE}s; stop: demo/run-local.sh stop $NAME)"
