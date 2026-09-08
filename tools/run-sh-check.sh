#!/usr/bin/env bash
# tools/run-sh-check.sh — run.sh's non-interactive verbs on a throwaway
# workspace, with every override run.sh honors pointed at a tempdir:
#
#   TMPDIR          the marker lands under it (the app and run.sh agree)
#   MNML_DATA_ROOT  the app's config / session — never ~/.config/mnml
#   MNML_BIN        a copy of the real binary, so its mtime is ours to set
#   MNML_ZIG        a fake `zig` that logs its argv and builds nothing —
#                   which is how "the build path was taken" is observed
#                   without a 2-minute compile
#
# What it proves, in order:
#   1. `stale`: a 1970 binary is behind the sources (and names the file);
#      a binary touched now is current.
#   2. `status` / `restart` / `stop` with no instance say so and fail.
#   3. `./run.sh headless` from inside the workspace (no argument): the
#      stale binary takes the build path (fake zig sees
#      `build -Doptimize=ReleaseSafe`), the marker holds the workspace's
#      real path with no trailing newline, `status` reports the
#      workspace, the IPC dir and a live process.
#   4. `restart` appends {"cmd":"restart"}; the app exits 75, the wrapper
#      rebuilds (a second fake-zig line) and relaunches (a fresh `start`).
#   5. `stop` appends {"cmd":"quit"}; the loop exits 0 and the marker is
#      gone.
#   6. The terminal loop itself, on a pty (tools/pty-lifecycle.py): the
#      app writes the marker, quit removes it with exit 0, restart keeps
#      it with exit 75.
#
#   tools/run-sh-check.sh            (needs zig-out/bin/mnml-zig; ~15 s)
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REAL_BIN=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
[ -x "$REAL_BIN" ] || { echo "run-sh-check: build first: zig build -Doptimize=ReleaseSafe" >&2; exit 64; }

TMP=$(mktemp -d -t run-sh-check)
export TMPDIR="$TMP/tmp"
export MNML_DATA_ROOT="$TMP/data"
export MNML_BIN="$TMP/bin/mnml-zig"
export MNML_ZIG="$TMP/fakezig"
unset MNML_IPC_DIR MNML_IPC_SUBDIR MNML_OPTIMIZE
mkdir -p "$TMPDIR" "$MNML_DATA_ROOT" "$TMP/bin"
cp "$REAL_BIN" "$MNML_BIN"
ZIG_LOG="$TMP/zig.log"
cat > "$MNML_ZIG" <<EOF
#!/bin/sh
echo "\$*" >> "$ZIG_LOG"
EOF
chmod +x "$MNML_ZIG"
WS="$TMP/ws"
mkdir -p "$WS"
printf '# demo\n' > "$WS/README.md"
git init -q "$WS"
WS=$(cd "$WS" && pwd -P)
MARKER="$TMPDIR/mnml-zig-running-${USER:-x}.workspace"
IPC="$WS/.mnml/ipc-zig"
LOOP_PID=""

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1" ; [ -n "${2:-}" ] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

cleanup() {
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null
  pkill -f -- "$MNML_BIN" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Poll a condition for up to $2 seconds.
wait_for() {
  local tries=$(( ${2:-10} * 10 ))
  while [ "$tries" -gt 0 ]; do
    if eval "$1"; then return 0; fi
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}
has_event() { [ -f "$IPC/events.jsonl" ] && grep -q "$1" "$IPC/events.jsonl"; }
zig_builds() { [ -f "$ZIG_LOG" ] && grep -c 'build -Doptimize=ReleaseSafe' "$ZIG_LOG" || echo 0; }

echo "run-sh-check: $ROOT/run.sh on $WS"

# ── 1. stale ───────────────────────────────────────────────────────────
touch -t 197001010000 "$MNML_BIN"
out=$("$ROOT/run.sh" stale 2>&1); rc=$?
check "stale: a 1970 binary needs a build (exit 0)" '[ $rc -eq 0 ]' "$out"
check "stale: names the newer source" 'echo "$out" | grep -q "is newer than"' "$out"
touch "$MNML_BIN"
out=$("$ROOT/run.sh" stale 2>&1); rc=$?
check "stale: a binary touched now is current (exit 1)" '[ $rc -eq 1 ]' "$out"
check "stale: says so" 'echo "$out" | grep -q "is current"' "$out"

# ── 2. nothing running ─────────────────────────────────────────────────
rm -f "$MARKER"
out=$("$ROOT/run.sh" status 2>&1)
check "status: no marker → says so" 'echo "$out" | grep -q "no marker"' "$out"
"$ROOT/run.sh" restart >/dev/null 2>&1; rc=$?
check "restart: no marker → exit 1" '[ $rc -eq 1 ]'
"$ROOT/run.sh" stop >/dev/null 2>&1; rc=$?
check "stop: no marker → exit 1" '[ $rc -eq 1 ]'

# ── 3. the headless loop, stale binary ─────────────────────────────────
touch -t 197001010000 "$MNML_BIN"
LOOP_LOG="$TMP/loop.log"
( cd "$WS" && "$ROOT/run.sh" headless > "$LOOP_LOG" 2>&1; echo "loop exit=$?" >> "$LOOP_LOG" ) &
LOOP_PID=$!
if wait_for 'has_event "\"event\":\"start\""' 20; then
  ok "headless: the app started (events.jsonl has start)"
else
  bad "headless: no start event within 20s" "$(cat "$LOOP_LOG" 2>/dev/null)"
fi
check "headless: the stale binary took the build path (log line)" 'grep -q "is newer than.*building ReleaseSafe" "$LOOP_LOG"' "$(cat "$LOOP_LOG")"
check "headless: zig was invoked with build -Doptimize=ReleaseSafe" '[ "$(zig_builds)" -eq 1 ]' "zig.log: $(cat "$ZIG_LOG" 2>/dev/null)"
check "marker: exists" '[ -f "$MARKER" ]'
check "marker: holds the workspace's real path" '[ "$(cat "$MARKER" 2>/dev/null)" = "$WS" ]' "got: $(cat "$MARKER" 2>/dev/null)"
check "marker: no trailing newline" '[ "$(wc -c < "$MARKER" | tr -d " ")" -eq ${#WS} ]'
out=$("$ROOT/run.sh" status 2>&1)
check "status: workspace line" 'echo "$out" | grep -q "^workspace: $WS\$"' "$out"
check "status: ipc dir exists" 'echo "$out" | grep -q "^ipc dir:   $IPC (exists)"' "$out"
check "status: process running" 'echo "$out" | grep -q "^process:   running (pid [0-9]"' "$out"

# ── 4. restart ─────────────────────────────────────────────────────────
"$ROOT/run.sh" restart >/dev/null 2>&1; rc=$?
check "restart: exit 0" '[ $rc -eq 0 ]'
check "restart: appended {\"cmd\":\"restart\"}" '[ "$(tail -n 1 "$IPC/command")" = "{\"cmd\":\"restart\"}" ]' "$(tail -n 2 "$IPC/command")"
# The relaunched instance truncates events.jsonl on init, so "a fresh
# start after a second build" is the relaunch.
if wait_for '[ "$(zig_builds)" -ge 2 ] && has_event "\"event\":\"start\""' 20; then
  ok "restart: exit 75 → a second build → relaunch (fresh start event)"
else
  bad "restart: no relaunch within 20s" "zig.log: $(cat "$ZIG_LOG"); loop.log: $(cat "$LOOP_LOG"); events: $(cat "$IPC/events.jsonl" 2>/dev/null)"
fi
check "restart: the wrapper said it was rebuilding" 'grep -q "restart requested — rebuilding" "$LOOP_LOG"' "$(cat "$LOOP_LOG")"
check "restart: marker survives the relaunch" '[ "$(cat "$MARKER" 2>/dev/null)" = "$WS" ]'
# Let the relaunched instance settle on its first frame before the stop
# line, so the line lands after its init truncation.
wait_for '[ -s "$IPC/status.json" ]' 10 || true

# ── 5. stop ────────────────────────────────────────────────────────────
"$ROOT/run.sh" stop >/dev/null 2>&1; rc=$?
check "stop: exit 0" '[ $rc -eq 0 ]'
check "stop: appended {\"cmd\":\"quit\"}" '[ "$(tail -n 1 "$IPC/command")" = "{\"cmd\":\"quit\"}" ]' "$(tail -n 2 "$IPC/command")"
if wait_for '! kill -0 "$LOOP_PID" 2>/dev/null' 20; then
  wait "$LOOP_PID" 2>/dev/null
  LOOP_PID=""
  ok "stop: the loop ended"
else
  bad "stop: the loop is still running after 20s" "events: $(cat "$IPC/events.jsonl" 2>/dev/null)"
fi
check "stop: loop exit 0" 'grep -q "^loop exit=0$" "$LOOP_LOG"' "$(cat "$LOOP_LOG")"
check "stop: events end with quit, exit" '[ "$(tail -n 2 "$IPC/events.jsonl" | tr "\n" " ")" = "{\"event\":\"quit\"} {\"event\":\"exit\"} " ]' "$(tail -n 3 "$IPC/events.jsonl")"
check "stop: marker removed" '[ ! -f "$MARKER" ]'

# ── 6. the terminal loop on a pty ──────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
  touch "$MNML_BIN"
  PTY_WS="$TMP/pty-ws"; mkdir -p "$PTY_WS"; printf '# pty\n' > "$PTY_WS/README.md"; git init -q "$PTY_WS"
  out=$(python3 "$ROOT/tools/pty-lifecycle.py" "$MNML_BIN" "$PTY_WS" quit 2>&1); rc=$?
  check "pty: the app writes the marker; quit → exit 0, marker removed" '[ $rc -eq 0 ]' "$out"
  out=$(python3 "$ROOT/tools/pty-lifecycle.py" "$MNML_BIN" "$PTY_WS" restart 2>&1); rc=$?
  check "pty: restart → exit 75, marker kept for the relaunch" '[ $rc -eq 0 ]' "$out"
else
  echo "  skip pty: no python3"
fi

echo "run-sh-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
