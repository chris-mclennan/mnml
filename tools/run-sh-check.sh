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
#   tools/run-sh-check.sh            (needs zig-out/bin/mnml-zig; ~30 s)
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

# ── 1b. the check sequence carries every audit ─────────────────────────
# `./run.sh check` is the gate in one line; a step dropped from it is a
# gate that silently stopped running. The two source audits are the ones
# with no other caller.
check "check: the sequence runs the glyph audit" 'grep -q "\"\$ZIG\" build glyph-audit" "$ROOT/run.sh"'
check "check: the sequence runs the hover-help audit" 'grep -q "\"\$ZIG\" build hover-audit" "$ROOT/run.sh"'
check "check: the sequence cross-compiles every shipped target" 'grep -q "\"\$ZIG\" build gate-targets" "$ROOT/run.sh"'

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

echo "run-sh-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
