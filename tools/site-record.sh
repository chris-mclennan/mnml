#!/usr/bin/env bash
# site-record.sh — the website's recordings: real-window video of mnml.
#
#   tools/site-record.sh FLOW… [--exe PATH] [--keep-mov]
#   tools/site-record.sh all          every tools/site-record/flows/*.flow
#
# Each FLOW is one launch of the tour's harness window (tools/tour/,
# docs/DRIVE.md): 200x60, the user's own ghostty font, decoration off,
# a private workspace (a small git repo, the offline Jira and Bitbucket,
# three planted agent transcripts) under a private HOME, driven through
# the file channel so it never takes the keyboard. The window alone is
# recorded (ScreenCaptureKit, tools/site-record/winrec.swift — another
# window over it is never in the file), encoded to VP9 WebM without
# audio, and written with a PNG poster:
#
#   site/public/media/<name>.webm   <name>.png      (1600 px wide)
#   site/src/media.json             [{name, title, seconds, flow}]
#
# Every screen the app writes while recording is scanned for the home
# path, the user name and work names; a hit fails the flow. Every
# screen change must have a captured frame within 150 ms.
#
# FLOW format, one step a line (`#` comments; shell quoting):
#   title: Hero                 flow: one sentence    (both required)
#   fps: 30                     width: 1600           (optional)
#   session_cwd: ~/tour         the planted agent transcripts' cwd (the
#                               sessions table prints it verbatim)
#   relative_data_root: yes     spell the data root relative (an install
#                               toast names a file under it); no shell panes
#   …setup steps…               run before recording starts
#   record                      the recording starts here
#   reset                       Esc twice, close every pane, the explorer
#   run ID                      a command id (the palette's ids)
#   key SPEC                    one chord: ctrl+p, enter, esc
#   keys [@MS] SPEC…            several chords, MS apart (default 350)
#   type TEXT                   a whole string at once
#   slowtype TEXT [MS]          one character every MS (default 55); \n = Enter
#   open PATH                   open a workspace file
#   click COL ROW [right]       hover COL ROW       find-click TEXT [ROW]
#   wait MS                     sleep, then let the frame settle
#   sleep MS                    sleep only
#   until TEXT [MS]             wait for TEXT on screen
#   heal BAD KEY GOOD           press KEY while BAD is on screen
#   poster                      shoot the poster here (default: the last frame)
#   shell CMD                   a command in the workspace (planting a file)
#   copy SRC [DEST]             a file from beside the flow into the workspace
#   note TEXT                   printed, nothing else
#
# Needs: macOS 15+, ghostty, `zig build -Ddrive`, swiftc, ffmpeg with
# libvpx-vp9, python3; Screen Recording + Accessibility for the terminal
# that runs it (`zig-out/bin/mnml-drive doctor`) — without them this
# re-runs itself in a Ghostty window that holds them (tools/tour/ghostty-hop.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  ""|-h|--help|help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ -x "$ROOT/zig-out/bin/mnml-drive" ] || { echo "site-record.sh: build the driver first: zig build -Ddrive" >&2; exit 64; }
MNML_STAMP_WHO=site-record.sh python3 "$ROOT/tools/tour/stamp.py" drive || exit $?
if [ -z "${MNML_TOUR_IN_GHOSTTY:-}" ] && ! "$ROOT/zig-out/bin/mnml-drive" doctor >/dev/null 2>&1; then
  echo "site-record.sh: this process lacks Accessibility / Screen Recording; running in a Ghostty window that holds them" >&2
  exec "$ROOT/tools/tour/ghostty-hop.sh" "$ROOT/tools/site-record.sh" "$@"
fi
if [ "$1" = all ]; then
  shift
  set -- "$ROOT"/tools/site-record/flows/*.flow "$@"
fi
exec python3 "$ROOT/tools/site-record/record.py" "$@"
