#!/usr/bin/env bash
# api-bench.sh — N `ping`s (default 200) through `mnml remote`, p50 / p95
# (docs/API.md, docs/research/api-design.md §8). Each sample is a whole
# `mnml remote ping`: process start, the socket, `initialize`, the round
# trip, exit.
#
# Against $MNML_API when it is set (run it in a pane of the mnml you want
# measured); otherwise against a scratch mnml this script starts itself,
# under a pseudo-terminal, with its own HOME, data root and API directory —
# never the instance you are using — and stops again on the way out.
#
#   tools/api-bench.sh [N]
#   MNML_BENCH_ROOT=DIR   where the scratch instance lives (default: mktemp
#                         under $TMPDIR); keep it short — the socket path
#                         has to fit a sockaddr_un
#   MNML_BIN=PATH         the binary (default zig-out/bin/mnml-zig)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
bin="${MNML_BIN:-$repo/zig-out/bin/mnml-zig}"
n="${1:-200}"

if [ -z "${MNML_API:-}" ]; then
  root="${MNML_BENCH_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/mnml-api-bench.XXXXXX")}"
  mkdir -p "$root/home" "$root/data" "$root/ws" "$root/api" "$root/tmp"
  # TMPDIR too: the running-instance marker `run.sh` reads lives there,
  # and the scratch instance must not take yours.
  export HOME="$root/home" MNML_DATA_ROOT="$root/data" MNML_API_DIR="$root/api" TMPDIR="$root/tmp"
  unset MNML_API_TOKEN
  if [ "$(uname)" = Darwin ]; then
    script -q /dev/null "$bin" "$root/ws" --no-session </dev/null >/dev/null 2>&1 &
  else
    script -qc "'$bin' '$root/ws' --no-session" /dev/null </dev/null >/dev/null 2>&1 &
  fi
  pty_pid=$!
  trap 'kill "$pty_pid" 2>/dev/null || true; wait "$pty_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 150); do
    ls "$root/api"/*.zon >/dev/null 2>&1 && break
    sleep 0.1
  done
  ls "$root/api"/*.zon >/dev/null 2>&1 || { echo "api-bench: the scratch mnml never wrote its marker" >&2; exit 1; }
  cd "$root/ws"
fi

python3 - "$bin" "$n" <<'PY'
import subprocess, sys, time
bin, n = sys.argv[1], int(sys.argv[2])
samples = []
for _ in range(n):
    t0 = time.perf_counter()
    r = subprocess.run([bin, "remote", "ping"], capture_output=True, text=True)
    samples.append((time.perf_counter() - t0) * 1000)
    if r.returncode != 0 or r.stdout.strip() != "pong":
        sys.exit(f"api-bench: ping failed (exit {r.returncode}): {r.stderr.strip()}")
samples.sort()
pct = lambda p: samples[min(len(samples) - 1, int(round(p / 100 * (len(samples) - 1))))]
print(f"api-bench: {n} x `mnml remote ping`  p50 {pct(50):.2f} ms  p95 {pct(95):.2f} ms  max {samples[-1]:.2f} ms")

# The socket alone: the same pings on one connection, no process start.
import glob, json, os, re, socket
path = os.environ.get("MNML_API")
if not path:
    for m in glob.glob(os.path.join(os.environ.get("MNML_API_DIR", ""), "*.zon")):
        hit = re.search(r'\.socket\s*=\s*"([^"]+)"', open(m).read())
        if hit: path = hit.group(1)
if path:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    f = s.makefile("rwb")
    def call(obj):
        f.write((json.dumps(obj) + "\n").encode()); f.flush()
        return f.readline()
    call({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"token": os.environ.get("MNML_API_TOKEN", "")}})
    rt = []
    for i in range(n):
        t0 = time.perf_counter()
        call({"jsonrpc": "2.0", "id": i + 1, "method": "ping"})
        rt.append((time.perf_counter() - t0) * 1000)
    rt.sort()
    q = lambda p: rt[min(len(rt) - 1, int(round(p / 100 * (len(rt) - 1))))]
    print(f"api-bench: {n} x ping on one connection   p50 {q(50):.3f} ms  p95 {q(95):.3f} ms  max {rt[-1]:.3f} ms")
PY
