#!/usr/bin/env bash
#
# drive-check — mnml-drive refuses to act on a window that is not its own.
#
# The safety rule this asserts is the whole reason the tool is allowed to
# exist: the developer has their own ghostty windows open, and the harness
# must never post an event into one. Every case below is a way the record
# can stop describing a window we own, and every one of them must end in
# exit 3 with nothing posted.
#
# No window is launched: each case is a drive.json that is already wrong,
# which is exactly the state a crashed or killed harness leaves behind.
#
# Usage: tools/drive/drive-check.sh [path/to/mnml-drive]
set -uo pipefail
DRIVE="${1:-zig-out/bin/mnml-drive}"
[ -x "$DRIVE" ] || { echo "drive-check: no $DRIVE (zig build -Ddrive)"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

expect_refused() { # name, root, verb...
  local name="$1" root="$2"; shift 2
  local out rc
  out=$("$DRIVE" "$@" --data-root "$root" 2>&1); rc=$?
  if [ "$rc" -ne 3 ]; then
    echo "  FAIL $name: expected exit 3 (refused), got $rc"
    echo "        $out"
    fails=$((fails + 1))
  elif ! printf '%s' "$out" | grep -qiE 'refus|no harness|unreadable'; then
    echo "  FAIL $name: exit 3 but no reason given"
    echo "        $out"
    fails=$((fails + 1))
  else
    echo "  ok   $name"
  fi
}

echo "drive-check: a harness that is not ours is never driven"

# 1. No record at all. Nothing has been launched; there is no window to
#    guess at, and guessing is the failure mode this tool must not have.
mkdir -p "$TMP/empty"
expect_refused "no drive.json"        "$TMP/empty" info
expect_refused "no drive.json (click)" "$TMP/empty" click 1 1

# 2. A record naming a pid that is gone — what a crashed harness leaves.
#    The window id in it may well have been handed to somebody else by
#    now, which is precisely why the pid is checked and not just the id.
mkdir -p "$TMP/dead"
cat > "$TMP/dead/drive.json" <<'JSON'
{"pid":999999,"windowId":424242,"title":"mnml-drive harness","x":0.00,"y":38.00,"w":960.00,"h":680.00,"cols":120,"rows":40,"cellW":8.0000,"cellH":17.0000,"workspace":"/tmp/ws","dataRoot":"/tmp/dr","ipcDir":"/tmp/ws/.mnml/ipc-zig"}
JSON
expect_refused "dead pid"          "$TMP/dead" info
expect_refused "dead pid (type)"   "$TMP/dead" type hello
expect_refused "dead pid (click)"  "$TMP/dead" click 5 5
expect_refused "dead pid (scroll)" "$TMP/dead" scroll 5 5 up
expect_refused "dead pid (shot)"   "$TMP/dead" shot "$TMP/never.png"
[ -f "$TMP/never.png" ] && { echo "  FAIL dead pid: shot wrote a file anyway"; fails=$((fails + 1)); }

# 3. A live pid that is NOT a window of ours: this process. It exists, so
#    the liveness check passes and the window check is the only thing
#    standing between the harness and somebody else's screen.
mkdir -p "$TMP/notours"
sed "s/999999/$$/" "$TMP/dead/drive.json" > "$TMP/notours/drive.json"
# `info` and not `key`: a keyboard verb ALSO refuses when the harness is
# not the active application, so a `key` here passes whether or not the
# window check works — which is exactly how this script first passed with
# the window check deliberately broken. `info` is the verb that does
# nothing but the check.
expect_refused "live pid, not our window" "$TMP/notours" info
expect_refused "live pid, not our window (shot)" "$TMP/notours" shot "$TMP/never2.png"
[ -f "$TMP/never2.png" ] && { echo "  FAIL live pid: shot photographed somebody else's window"; fails=$((fails + 1)); }

# 4. A truncated record. Half a record is not a record; it must not be
#    read as zeroes and acted on.
mkdir -p "$TMP/torn"
printf '{"pid":%d,"windowId":' "$$" > "$TMP/torn/drive.json"
expect_refused "truncated drive.json" "$TMP/torn" info

if [ "$fails" -eq 0 ]; then
  echo "drive-check: all cases refused"
  exit 0
fi
echo "drive-check: $fails case(s) did not refuse"
exit 1
