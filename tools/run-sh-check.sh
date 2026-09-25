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
#   8. `install` on a throwaway repo into a throwaway PREFIX: the
#      dry-run plan, the three refusals (dirty tree, Debug, a
#      PREFIX/bin/mnml that is not ours), then a real copy — the host,
#      an integration, the font, the integration catalogue, the manifest
#      into the stable data root
#      and the link that points at PREFIX rather than a zig-out — and
#      the installed binary reaching a first frame headless. Plus the
#      font step `install` only PRINTS, and `install-font` — the one
#      verb that writes to the OS font directory — against a scratch
#      HOME: the two dry-runs (nothing installed / a face already
#      there), and that a failed merge leaves the installed face alone
#      after backing it up.
#
#  10. tools/tour.sh / tools/look.sh on a copy of themselves: a driver
#      whose `version` stamp is missing or disagrees with tools/drive is
#      refused (MNML_DRIVE_NO_REBUILD=1) or rebuilt (a fake $MNML_ZIG);
#      the stamp, not the mtime, decides; `diff` never checks; an app
#      binary older than src/ is a warning only; masks.zon hides the tree
#      header's workspace path under either root.
#
#   tools/run-sh-check.sh            (needs zig-out/bin/mnml-zig; ~30 s)
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REAL_BIN=${MNML_ZIG_BIN:-$ROOT/zig-out/bin/mnml-zig}
[ -x "$REAL_BIN" ] || { echo "run-sh-check: build first: zig build -Doptimize=ReleaseSafe" >&2; exit 64; }

# A template, not `-t NAME`: GNU mktemp wants the X's spelled out and
# fails on a bare prefix, which left TMP empty and every path below at /.
TMPDIR_BASE=${TMPDIR:-/tmp}; TMPDIR_BASE=${TMPDIR_BASE%/}
TMP=$(mktemp -d "${TMPDIR_BASE}/run-sh-check.XXXXXX") || { echo "run-sh-check: mktemp failed" >&2; exit 70; }
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

# ── 1b. the check sequence carries every audit ─────────────────────────
# `./run.sh check` is the gate in one line; a step dropped from it is a
# gate that silently stopped running. The two source audits are the ones
# with no other caller.
check "check: the sequence runs the glyph audit" 'grep -q "\"\$ZIG\" build glyph-audit" "$ROOT/run.sh"'
check "check: the sequence runs the hover-help audit" 'grep -q "\"\$ZIG\" build hover-audit" "$ROOT/run.sh"'
check "check: the sequence cross-compiles every shipped target" 'grep -q "\"\$ZIG\" build gate-targets" "$ROOT/run.sh"'
check "check: the sequence runs the Debug unit suite" 'grep -q "bash tools/debug-suite-check.sh" "$ROOT/run.sh"'
check "check: the sequence still runs the ReleaseSafe suite" 'grep -q "\"\$ZIG\" build test -Doptimize=ReleaseSafe" "$ROOT/run.sh"'
check "check: the ReleaseSafe suite runs under the trace runner (FLAKY reported, as in Debug)" 'grep -q "\"\$ZIG\" build test -Doptimize=ReleaseSafe -Dtest-trace=true" "$ROOT/run.sh"'
# tools/debug-suite-check.sh builds `unit-debug` and ends on a verdict a
# chain can read: the fake zig (logs, exits 0) and one that exits 1.
out=$(MNML_ZIG="$MNML_ZIG" bash "$ROOT/tools/debug-suite-check.sh" 2>&1); rc=$?
check "debug-suite-check: a green build says ok (exit 0)" '[ $rc -eq 0 ] && echo "$out" | tail -1 | grep -q "^unit debug: ok"' "$out"
check "debug-suite-check: it builds unit-debug" 'grep -q "^build unit-debug" "$ZIG_LOG"' "$(cat "$ZIG_LOG" 2>/dev/null)"
check "debug-suite-check: under the trace runner (FLAKY reported)" 'grep -q "^build unit-debug -Dtest-trace=true" "$ZIG_LOG"' "$(cat "$ZIG_LOG" 2>/dev/null)"
: > "$ZIG_LOG"
MNML_ZIG="$MNML_ZIG" bash "$ROOT/tools/debug-suite-check.sh" -Dtest-trace=false > /dev/null 2>&1
check "debug-suite-check: an explicit -Dtest-trace is passed alone, never twice" '[ "$(grep -c -- "-Dtest-trace" "$ZIG_LOG")" -eq 1 ] && grep -q -- "-Dtest-trace=false" "$ZIG_LOG"' "$(cat "$ZIG_LOG" 2>/dev/null)"
printf '#!/bin/sh\nexit 1\n' > "$TMP/failzig"; chmod +x "$TMP/failzig"
out=$(MNML_ZIG="$TMP/failzig" bash "$ROOT/tools/debug-suite-check.sh" 2>&1); rc=$?
check "debug-suite-check: a red build says UNIT DEBUG FAILED and keeps the exit" '[ $rc -eq 1 ] && echo "$out" | tail -1 | grep -q "^UNIT DEBUG FAILED"' "$out"
: > "$ZIG_LOG"

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
# start after a second build" is the relaunch. A start line ALONE is not
# it: the old instance's own start is still in the file until the
# truncation, so this waited on a line that was already there and could
# return before the relaunch had even execed — leaving the `stop` below
# to write its `quit` into a command file the relaunch then truncated.
# The relaunch is the moment the file holds a start and no `exit`.
if wait_for '[ "$(zig_builds)" -ge 2 ] && has_event "\"event\":\"start\"" && ! has_event "\"event\":\"exit\""' 20; then
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

# ── 7. the break-check's usage path ────────────────────────────────────
# Not a run.sh verb, but it rides the same harness: a break-check that
# cannot print its usage cannot be trusted to restore a file. Its
# verdicts have their own fake-zig check, tools/break-check-selftest.sh.
"$ROOT/tools/break-check.sh" --help >/dev/null 2>&1; rc=$?
check "break-check: --help exits 0" '[ $rc -eq 0 ]'
"$ROOT/tools/break-check.sh" >/dev/null 2>&1; rc=$?
check "break-check: no arguments exits 64" '[ $rc -eq 64 ]'

# ── 8. install ─────────────────────────────────────────────────────────
# `install` is run against a throwaway repo — a copy of run.sh, a couple
# of integration manifests, and zig-out symlinked at the real one — so
# the guards (dirty tree, Debug, a foreign binary) are deterministic and
# the copy path runs with the binaries that are already built. The
# compile itself is the fake zig; what is proved here is everything
# around it. PREFIX and MNML_DATA_ROOT are both under $TMP: nothing
# reaches ~/.local or ~/.config/mnml.
FAKE="$TMP/repo"
mkdir -p "$FAKE/integrations/jira" "$FAKE/integrations/sample"
cp "$ROOT/run.sh" "$FAKE/run.sh"
ln -s "$ROOT/zig-out" "$FAKE/zig-out"
printf '.{\n    .id = "jira_work",\n    .label = "Jira",\n    .binary = "mnml-jira",\n    .category = "tracker",\n}\n' > "$FAKE/integrations/jira/manifest.zon"
printf '.{\n    .id = "sample",\n    .label = "Sample",\n    .binary = "mnml-sample",\n    .category = "sample",\n}\n' > "$FAKE/integrations/sample/manifest.zon"
git init -q "$FAKE"
(cd "$FAKE" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
PREFIX_OK="$TMP/prefix"
PREFIX_DRY="$TMP/prefix-dry"
PREFIX_FOREIGN="$TMP/prefix-foreign"

out=$(cd "$FAKE" && PREFIX="$PREFIX_DRY" ./run.sh install --dry-run 2>&1); rc=$?
check "install --dry-run: exit 0" '[ $rc -eq 0 ]' "$out"
check "install --dry-run: names the host copy" 'echo "$out" | grep -q "would copy   zig-out/bin/mnml-zig → $PREFIX_DRY/bin/mnml"' "$out"
check "install --dry-run: names the integration copy" 'echo "$out" | grep -q "would copy   zig-out/bin/mnml-jira → $PREFIX_DRY/bin/mnml-jira"' "$out"
check "install --dry-run: names the manifest write into the stable data root" 'echo "$out" | grep -q "would run    MNML_PROFILE=stable MNML_DATA_ROOT=$MNML_DATA_ROOT $PREFIX_DRY/bin/mnml-jira --install"' "$out"
check "install --dry-run: names the relink" 'echo "$out" | grep -q "would link   $MNML_DATA_ROOT/bin/mnml-jira → $PREFIX_DRY/bin/mnml-jira"' "$out"
check "install --dry-run: the sample is a fixture, not a chip" 'echo "$out" | grep -q "would skip   mnml-sample --install"' "$out"
check "install --dry-run: changed nothing" '[ ! -e "$PREFIX_DRY" ]'

printf 'scratch\n' > "$FAKE/dirty.txt"
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh install --dry-run 2>&1); rc=$?
check "install: a dirty tree is refused (exit 1)" '[ $rc -eq 1 ]' "$out"
check "install: says which file is dirty" 'echo "$out" | grep -q "dirty.txt"' "$out"
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh install --dry-run --allow-dirty 2>&1); rc=$?
check "install: --allow-dirty gets past it" '[ $rc -eq 0 ]' "$out"
rm -f "$FAKE/dirty.txt"

out=$(cd "$FAKE" && MNML_OPTIMIZE=Debug PREFIX="$PREFIX_OK" ./run.sh install --dry-run 2>&1); rc=$?
check "install: a Debug build is refused (exit 1)" '[ $rc -eq 1 ]' "$out"
check "install: says why" 'echo "$out" | grep -q "MNML_OPTIMIZE=Debug"' "$out"

mkdir -p "$PREFIX_FOREIGN/bin"
printf '#!/bin/sh\necho "mnml: unknown flag: $*" >&2\nexit 1\n' > "$PREFIX_FOREIGN/bin/mnml"
chmod +x "$PREFIX_FOREIGN/bin/mnml"
out=$(cd "$FAKE" && PREFIX="$PREFIX_FOREIGN" ./run.sh install --dry-run 2>&1); rc=$?
check "install: will not overwrite a binary that is not an mnml-zig (exit 1)" '[ $rc -eq 1 ]' "$out"
check "install: says --force is the way" 'echo "$out" | grep -q -- "--force"' "$out"
check "install: left the foreign binary alone" 'grep -q "unknown flag" "$PREFIX_FOREIGN/bin/mnml"'

out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh install 2>&1); rc=$?
check "install: exit 0" '[ $rc -eq 0 ]' "$out"
check "install: verified the build before copying" 'echo "$out" | grep -q "verified: mnml-zig "' "$out"
check "install: the host landed as PREFIX/bin/mnml" '[ -x "$PREFIX_OK/bin/mnml" ]'
check "install: PREFIX/bin/mnml --version says what it is" '"$PREFIX_OK/bin/mnml" --version | grep -q "^mnml-zig "' "$("$PREFIX_OK/bin/mnml" --version 2>&1)"
check "install: the integration landed too" '[ -x "$PREFIX_OK/bin/mnml-jira" ]'
check "install: the font came with it" '[ -f "$PREFIX_OK/share/mnml/fonts/MnmlSymbols.ttf" ]'
# The Marketplace tab's default source rides in share/ beside the font:
# without it an installed mnml lists no integrations at all.
check "install: the integration catalogue came with it" '[ -f "$PREFIX_OK/share/mnml/marketplace.zon" ]' "$(ls "$PREFIX_OK/share/mnml" 2>&1)"
check "install: the manifest went to the stable data root" '[ -f "$MNML_DATA_ROOT/integrations/jira_work.zon" ]' "$(ls "$MNML_DATA_ROOT/integrations" 2>&1)"
check "install: the data root's link points at PREFIX, not at a zig-out" '[ "$(readlink "$MNML_DATA_ROOT/bin/mnml-jira")" = "$PREFIX_OK/bin/mnml-jira" ]' "$(readlink "$MNML_DATA_ROOT/bin/mnml-jira" 2>&1)"
check "install: the sample binary ships, its manifest does not" '[ -x "$PREFIX_OK/bin/mnml-sample" ] && [ ! -f "$MNML_DATA_ROOT/integrations/sample.zon" ]'
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh installed-status 2>&1)
check "installed-status: names the installed version" 'echo "$out" | grep -q "^installed: mnml-zig "' "$out"
check "installed-status: names the data root" 'echo "$out" | grep -q "^data:      $MNML_DATA_ROOT\$"' "$out"
check "installed-status: the link reads as pointing into the prefix" 'echo "$out" | grep -q "^link:      mnml-jira → $PREFIX_OK/bin/mnml-jira\$"' "$out"

# ── 8a. the gits run.sh runs to READ take no lock ─────────────────────
# A plain `git status` (and `git describe --dirty`, which
# `--no-optional-locks` does not stop) refreshes the index and writes it
# back under `.git/index.lock`: in the checkout a verification chain runs
# in, that races the user's own commit and, killed, leaves a stale lock.
# A tracked file whose stat data is stale but whose content is not — a
# `touch` — is what makes git write; the index's inode says whether it did.
inode() { ls -i "$FAKE/.git/index" | awk '{ print $1 }'; }
touch -t 202001010000 "$FAKE/integrations/jira/manifest.zon"
before=$(inode)
(cd "$FAKE" && git status --porcelain > /dev/null)
check "git-read: the control — a plain git status rewrites a stale index" '[ "$(inode)" != "$before" ]'
touch -t 202101010000 "$FAKE/integrations/jira/manifest.zon"
before=$(inode)
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh install --dry-run 2>&1); rc=$?
check "git-read: install's dirty-tree check leaves the index alone" '[ "$(inode)" = "$before" ]' "$out"
check "git-read: and a touched-but-unchanged tree is clean to it (exit 0)" '[ $rc -eq 0 ]' "$out"
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh installed-status 2>&1)
check "git-read: installed-status leaves the index alone" '[ "$(inode)" = "$before" ]' "$out"
check "git-read: installed-status calls the touched tree clean" 'echo "$out" | grep "^here:" | grep -vq -- "-dirty"' "$out"
printf 'edited\n' >> "$FAKE/integrations/jira/manifest.zon"
out=$(cd "$FAKE" && PREFIX="$PREFIX_OK" ./run.sh installed-status 2>&1)
check "git-read: installed-status says -dirty for an edited tracked file" 'echo "$out" | grep "^here:" | grep -q -- "-dirty  (HEAD "' "$out"
(cd "$FAKE" && git checkout -q -- integrations/jira/manifest.zon)
# Every read-only git the build and the tooling run says so: a `status`
# without `--no-optional-locks`, or a `describe --dirty` at all, is a lock
# taken in the checkout on every `zig build` / chain step.
lockers=$(cd "$ROOT" && grep -nE '(\bgit\b[^|;&#]*[ "]status\b|"git",[^;]*"status"|describe[^|;#]*--dirty)' build.zig run.sh tools/*.sh scripts/*.sh 2>/dev/null \
    | grep -v '^tools/run-sh-check.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)' \
    | grep -vE -- '--no-optional-locks[^|;]*status|describe[^|;]*--dirty' ; \
    cd "$ROOT" && grep -nE 'describe[^|;#]*--dirty' build.zig run.sh tools/*.sh scripts/*.sh 2>/dev/null \
    | grep -v '^tools/run-sh-check.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)')
check "git-read: every status the build and tools run is --no-optional-locks; no describe --dirty" '[ -z "$lockers" ]' "$lockers"

# ── 8b. the font step, and install-font ────────────────────────────────
# `install` must never write to the OS font directory; it prints the
# step instead. `install-font` is the verb that does, with HOME pointed
# at a tempdir so no real ~/Library/Fonts is touched.
out=$(cd "$FAKE" && PREFIX="$PREFIX_DRY" ./run.sh install --dry-run 2>&1)
check "install --dry-run: names install-font as the font step" 'echo "$out" | grep -q "\./run.sh install-font"' "$out"
check "install --dry-run: prints the by-hand copy command too" 'echo "$out" | grep -q "cp $PREFIX_DRY/share/mnml/fonts/MnmlSymbols.ttf "' "$out"

FONT_HOME="$TMP/fonthome"
case "$(uname -s)" in
  Darwin) FONT_DIR="$FONT_HOME/Library/Fonts" ;;
  *)      FONT_DIR="$FONT_HOME/.local/share/fonts" ;;
esac
mkdir -p "$FONT_HOME"
out=$(cd "$FAKE" && HOME="$FONT_HOME" XDG_DATA_HOME= ./run.sh install-font --dry-run 2>&1); rc=$?
check "install-font --dry-run: exit 0 with nothing installed" '[ $rc -eq 0 ]' "$out"
check "install-font --dry-run: says there is no face to merge with" 'echo "$out" | grep -q "no MnmlSymbols installed"' "$out"
check "install-font --dry-run: names the destination" 'echo "$out" | grep -q "→ $FONT_DIR/MnmlSymbols.ttf"' "$out"
check "install-font --dry-run: wrote nothing" '[ ! -e "$FONT_DIR" ]'

# Now with a face already there: it must MERGE, and back up first.
mkdir -p "$FONT_DIR"
printf 'not really a font, but a file that is in the way\n' > "$FONT_DIR/MnmlSymbols.ttf"
BEFORE=$(cksum < "$FONT_DIR/MnmlSymbols.ttf")
out=$(cd "$FAKE" && HOME="$FONT_HOME" XDG_DATA_HOME= ./run.sh install-font --dry-run 2>&1); rc=$?
check "install-font --dry-run: exit 0 with a face installed" '[ $rc -eq 0 ]' "$out"
check "install-font --dry-run: merges rather than overwrites" 'echo "$out" | grep -q "would run    .*font-merge -Dfont-in=$FONT_DIR/MnmlSymbols.ttf"' "$out"
check "install-font --dry-run: names the backup" 'echo "$out" | grep -q "would back up .* → $FONT_HOME/Backups/mnml-zig/fonts/MnmlSymbols-"' "$out"
check "install-font --dry-run: still wrote nothing" '[ "$(cksum < "$FONT_DIR/MnmlSymbols.ttf")" = "$BEFORE" ]'

# For real. The fake zig builds nothing, so the merge produces no file —
# which is the failure this must survive: the installed face is left
# exactly as it was, and the backup is already on disk.
out=$(cd "$FAKE" && HOME="$FONT_HOME" XDG_DATA_HOME= ./run.sh install-font 2>&1); rc=$?
check "install-font: a merge that produces no file fails loudly" '[ $rc -ne 0 ]' "$out"
check "install-font: and leaves the installed face untouched" '[ "$(cksum < "$FONT_DIR/MnmlSymbols.ttf")" = "$BEFORE" ]' "$out"
check "install-font: the backup was taken before the merge ran" 'ls "$FONT_HOME/Backups/mnml-zig/fonts/"MnmlSymbols-*.ttf >/dev/null 2>&1' "$(ls -R "$FONT_HOME/Backups" 2>&1)"
check "install-font: no half-written .new is left behind" '[ ! -e "$FONT_DIR/MnmlSymbols.ttf.new" ]'
check "install-font: asked zig for the merge" 'grep -q "build font-merge" "$ZIG_LOG"' "$(cat "$ZIG_LOG")"
check "install-font: an unknown flag exits 2" 'out=$(cd "$FAKE" && HOME="$FONT_HOME" ./run.sh install-font --nope 2>&1); [ $? -eq 2 ]'

# The installed binary runs: a headless session on a throwaway
# workspace, its data root private, reaching its own first frame.
INST_WS="$TMP/inst-ws"; mkdir -p "$INST_WS"; printf '# inst\n' > "$INST_WS/README.md"; git init -q "$INST_WS"
( cd "$INST_WS" && "$PREFIX_OK/bin/mnml" --headless . >/dev/null 2>&1 ) &
INST_PID=$!
INST_IPC="$INST_WS/.mnml/ipc-zig"
if wait_for '[ -f "$INST_IPC/events.jsonl" ] && grep -q "\"event\":\"start\"" "$INST_IPC/events.jsonl"' 20; then
  ok "install: the installed binary starts headless on its own workspace"
else
  bad "install: the installed binary never reached a first frame" "$(ls -R "$INST_WS/.mnml" 2>&1)"
fi
printf '{"cmd":"quit"}\n' >> "$INST_IPC/command" 2>/dev/null
wait_for '! kill -0 "$INST_PID" 2>/dev/null' 15 || kill "$INST_PID" 2>/dev/null
wait "$INST_PID" 2>/dev/null

# ── 9. broker serve / status with a socket override the OS cannot hold ─
# A `<SERVICE>_BROKER_SOCKET` longer than a `sockaddr_un` printed
# `bitbucket: could not serve (BindFailed)` and exited — no hint that a
# LENGTH was the problem, and the automatic /tmp fallback applies only
# to the DERIVED path, never to an explicit override. Both verbs now
# name the variable and both numbers. Private paths throughout: the
# real bucket under ~/.tattle-claude-artifacts is never touched.
BROKER_DIR="$TMP/broker"
mkdir -p "$BROKER_DIR"
export BITBUCKET_RATELIMIT_STATE="$BROKER_DIR/bitbucket-ratelimit.json"
export JIRA_RATELIMIT_STATE="$BROKER_DIR/jira-ratelimit.json"
LONG_SOCK="$BROKER_DIR"
while [ ${#LONG_SOCK} -lt 104 ]; do LONG_SOCK="$LONG_SOCK/deeeeeeep"; done
LONG_SOCK="$LONG_SOCK/bitbucket-broker.sock"
out=$(BITBUCKET_BROKER_SOCKET="$LONG_SOCK" "$MNML_BIN" broker serve --service bitbucket 2>&1); rc=$?
check "broker serve: a too-long override exits 1 instead of hanging or binding" '[ $rc -eq 1 ]' "$out"
check "broker serve: names the length and the limit" 'echo "$out" | grep -q "socket path is ${#LONG_SOCK} bytes; the OS allows "' "$out"
check "broker serve: names the variable to change" 'echo "$out" | grep -q "set BITBUCKET_BROKER_SOCKET shorter or unset it for the default"' "$out"
check "broker serve: never the bare BindFailed" '! echo "$out" | grep -q "BindFailed"' "$out"
check "broker serve: refused up front — no socket, no lock, no directory" '[ ! -e "$LONG_SOCK" ] && [ -z "$(ls -A "$BROKER_DIR")" ]' "$(ls -R "$BROKER_DIR" 2>&1)"
out=$(BITBUCKET_BROKER_SOCKET="$LONG_SOCK" "$MNML_BIN" broker status --service bitbucket 2>&1)
check "broker status: says the same rather than 'no broker at …'" 'echo "$out" | grep -q "socket path is ${#LONG_SOCK} bytes"' "$out"
check "broker status: not the line an absent broker prints" '! echo "$out" | grep -q "no broker at"' "$out"
# And with no override the ordinary answer is unchanged — the new
# message must not swallow the one that says nothing is listening.
out=$("$MNML_BIN" broker status --service bitbucket 2>&1)
check "broker status: an ordinary path still reports an absent broker" 'echo "$out" | grep -q "no broker at"' "$out"
check "broker status: and says nothing about a length" '! echo "$out" | grep -q "socket path is"' "$out"

# ── 10. tour.sh / look.sh and a stale harness ─────────────────────────
# The first tour from main used an mnml-drive built the day before the
# driver changed: its launch never wrote `allow_input`, and every state
# failed with "the channel refused input". Both scripts now compare the
# driver's `version` stamp (a hash of tools/drive/*.zig + src/core/key.zig,
# build.zig `driveSourceHash`) against the checkout before they launch.
# On a copy of the scripts and the driver's sources, with fake drivers
# and a fake zig — nothing opens a window, nothing is compiled.
TR="$TMP/tourrepo"
mkdir -p "$TR/tools/tour" "$TR/tools/drive" "$TR/src/core" "$TR/zig-out/bin"
cp "$ROOT/tools/tour.sh" "$ROOT/tools/look.sh" "$TR/tools/"
cp "$ROOT"/tools/tour/*.py "$TR/tools/tour/"
cp "$ROOT"/tools/drive/*.zig "$TR/tools/drive/"
cp "$ROOT/src/core/key.zig" "$TR/src/core/"
stamp_hash() { (cd "$1" && python3 -c 'import sys; sys.path.insert(0, "tools/tour"); import stamp; print(stamp.source_hash())'); }
HASH=$(stamp_hash "$TR")
DRV="$TR/zig-out/bin/mnml-drive"
DRV_LOG="$TMP/drive.log"
fake_drive() {  # $1: the stamp `version` prints ("" = a driver too old to know the verb)
  if [ -n "$1" ]; then
    printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$1" = version ] && { echo "source %s"; exit 0; }\nexit 2\n' "$DRV_LOG" "$1" > "$DRV"
  else
    printf '#!/bin/sh\necho "$*" >> "%s"\necho "mnml-drive usage"\nexit 2\n' "$DRV_LOG" > "$DRV"
  fi
  chmod +x "$DRV"
}
check "stamp: the checkout's hash is sixteen hex digits" 'echo "$HASH" | grep -Eq "^[0-9a-f]{16}$"' "$HASH"
# The real driver, when there is one, prints a stamp of the same shape.
if [ -x "$ROOT/zig-out/bin/mnml-drive" ]; then
  real=$("$ROOT/zig-out/bin/mnml-drive" version 2>&1)
  check "stamp: the built mnml-drive answers \`version\` with a source stamp" 'echo "$real" | grep -Eq "^source [0-9a-f]{16}$"' "$real"
  # Built after its sources last changed, it must agree with stamp.py to
  # the digit: build.zig and the script hash the same bytes the same way.
  if [ -z "$(find "$ROOT/tools/drive" "$ROOT/src/core/key.zig" -name '*.zig' -newer "$ROOT/zig-out/bin/mnml-drive" 2>/dev/null)" ]; then
    want="source $(stamp_hash "$ROOT")"
    check "stamp: build.zig's driveSourceHash and stamp.py agree" '[ "$real" = "$want" ]' "$real vs $want"
  fi
fi
# a) A driver too old to have `version`, rebuilds refused: tour.sh stops.
fake_drive ""
: > "$DRV_LOG"
out=$(MNML_DRIVE_NO_REBUILD=1 "$TR/tools/tour.sh" run --out "$TMP/tourout" 2>&1); rc=$?
check "tour.sh: a driver too old to report its sources is refused (exit 64)" '[ $rc -eq 64 ]' "$out"
check "tour.sh: in one line that names the rebuild" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -q "mnml-drive is stale (too old to report its sources; tools/drive is $HASH) — rebuild: zig build -Ddrive"' "$out"
check "tour.sh: nothing launched" '! grep -q launch "$DRV_LOG"' "$(cat "$DRV_LOG")"
check "tour.sh: no workspace built" '[ ! -e "$TR/.verify/tour-ws" ] && [ ! -e "$TMP/tourout" ]' "$(ls -la "$TR/.verify" 2>&1)"
# b) A driver built from other sources: look.sh launch refuses the same way.
fake_drive "0123456789abcdef"
out=$(MNML_DRIVE_NO_REBUILD=1 "$TR/tools/look.sh" launch "$TMP/ws" 2>&1); rc=$?
check "look.sh launch: a driver built from other sources is refused (exit 64)" '[ $rc -eq 64 ]' "$out"
check "look.sh launch: names both stamps" 'echo "$out" | grep -q "built from 0123456789abcdef; tools/drive is $HASH"' "$out"
# c) The mtime is not the test: a 1970 driver whose stamp matches is used…
fake_drive "$HASH"
touch -t 197001010000 "$DRV"
out=$(MNML_DRIVE_NO_REBUILD=1 "$TR/tools/look.sh" launch "$TMP/no-such-ws" 2>&1); rc=$?
check "look.sh launch: a 1970 driver with the right stamp passes the check" '! echo "$out" | grep -q stale && echo "$out" | grep -q "no such workspace"' "$out"
# …and one edit under tools/drive makes that same driver stale.
echo "// touched by run-sh-check" >> "$TR/tools/drive/keys.zig"
NEW=$(stamp_hash "$TR")
out=$(MNML_DRIVE_NO_REBUILD=1 "$TR/tools/look.sh" launch "$TMP/no-such-ws" 2>&1); rc=$?
check "look.sh launch: an edit under tools/drive makes the driver stale" '[ $rc -eq 64 ] && [ "$NEW" != "$HASH" ] && echo "$out" | grep -q "built from $HASH; tools/drive is $NEW"' "$out"
# d) Rebuilds allowed: the fake zig "builds" a driver with the new stamp
# and the verb goes on (to look.py's own no-such-workspace answer).
TZ_LOG="$TMP/tourzig.log"
{
  echo '#!/bin/sh'
  echo "echo \"\$*\" >> \"$TZ_LOG\""
  echo "printf '#!/bin/sh\\n[ \"\$1\" = version ] && { echo \"source $NEW\"; exit 0; }\\nexit 2\\n' > \"$DRV\""
  echo "chmod +x \"$DRV\""
} > "$TMP/tourzig"
chmod +x "$TMP/tourzig"
out=$(MNML_ZIG="$TMP/tourzig" "$TR/tools/look.sh" launch "$TMP/no-such-ws" 2>&1); rc=$?
check "look.sh launch: a stale driver is rebuilt with zig build -Ddrive" '[ "$(cat "$TZ_LOG" 2>/dev/null)" = "build -Ddrive" ]' "$out"
check "look.sh launch: says it is rebuilding, then goes on" 'echo "$out" | grep -q "rebuilding: zig build -Ddrive" && echo "$out" | grep -q "no such workspace"' "$out"
# e) A rebuild that fails stops, naming its log.
fake_drive "0123456789abcdef"
printf '#!/bin/sh\necho "compile error"\nexit 1\n' > "$TMP/badzig"; chmod +x "$TMP/badzig"
out=$(MNML_ZIG="$TMP/badzig" "$TR/tools/tour.sh" run --out "$TMP/tourout" 2>&1); rc=$?
check "tour.sh: a failed rebuild stops (exit 64) and names its log" '[ $rc -eq 64 ] && echo "$out" | grep -q "zig build -Ddrive failed (exit 1); see $TR/.verify/drive-rebuild.log"' "$out"
# f) diff never launches, so a stale driver does not stop it.
mkdir -p "$TMP/tourout-empty"
out=$(MNML_DRIVE_NO_REBUILD=1 "$TR/tools/tour.sh" diff --out "$TMP/tourout-empty" 2>&1); rc=$?
check "tour.sh diff: skips the driver check" '[ $rc -eq 0 ] && ! echo "$out" | grep -q stale' "$out"
# g) The app binary: warned about, never refused.
mkdir -p "$TR/src/app"; echo "// a source" > "$TR/src/app/x.zig"
printf '#!/bin/sh\n' > "$TR/zig-out/bin/mnml-zig"; chmod +x "$TR/zig-out/bin/mnml-zig"
touch -t 197001010000 "$TR/zig-out/bin/mnml-zig"
out=$(cd "$TR" && python3 tools/tour/stamp.py app 2>&1); rc=$?
check "stamp app: a 1970 mnml-zig older than src/ is a warning, exit 0" '[ $rc -eq 0 ] && echo "$out" | grep -q "warning: zig-out/bin/mnml-zig is older than src/app/x.zig"' "$out"
touch "$TR/zig-out/bin/mnml-zig"
out=$(cd "$TR" && python3 tools/tour/stamp.py app 2>&1)
check "stamp app: a fresh mnml-zig says nothing" '[ -z "$out" ]' "$out"
# h) The tree header's workspace path is masked wherever the checkout
# lives: `/Use…` under /Users, `/pr…` under /private/tmp.
out=$(cd "$ROOT" && python3 -c '
import sys
sys.path.insert(0, "tools/tour")
import tour
m = tour.load_masks()
for line in ("   │  ● /Use…            │ x", "   │  ● /pr…             │ x"):
    got = [r for r in tour.masks_for("start", m, line) if r[1] == 0]
    a, b = line.index("/"), line.index("\u2026") + 1  # the path cells
    assert any(r[0] <= a and r[0] + r[2] >= b for r in got), (line, got)
print("masked")
' 2>&1)
check "masks.zon: the tree header's path is masked under either root" '[ "$out" = masked ]' "$out"

echo "run-sh-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
