#!/usr/bin/env bash
# Drives mnml via IPC to demonstrate drag-to-split for the recorded demo.
# Backgrounded by editor-drag-to-split.tape; writes JSONL commands to
# the workspace's IPC file. mnml polls the file in its main loop.
#
# All output (stdout + stderr) is suppressed so the bg-job doesn't
# pollute the VHS-recorded terminal once mnml has taken it over.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  # Wait for mnml to create its IPC dir + command file. Bounded so the
  # tape doesn't deadlock if mnml fails to launch.
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done

  # Extra beat so the first paint settles (welcome marker check, tree
  # walk, statusline, etc.) before we start injecting commands.
  sleep 1.0

  # Open main.rs so the editor pane is populated and the file tree
  # expands to show src/ + its contents.
  echo '{"cmd":"open","path":"src/main.rs"}' >> "$CMD"
  sleep 1.5

  # Hold so the viewer reads the single-pane state.
  sleep 0.6

  # ── DRAG sequence using the raw mouse-event IPC commands ──────────
  # Atomic `drag` would synthesize Down + N drag-steps + Up inside
  # one drain_commands iteration with no paint between — no ghost
  # chip / drop overlay would render. The raw mouse_{down,move,up}
  # commands let us interleave the script's own sleeps between
  # events. mnml drains + paints once per main-loop tick, so as
  # long as each sleep is > the tick interval (~16-40ms) every
  # event gets its own painted frame.
  #
  # Path: tree row for src/editor.rs at (col=13, row=5) → right edge
  # of the editor area at (col=140, row=20). Tape renders at
  # Width=1280 / FontSize=13 ≈ 151 cols, so the file tree owns
  # x=0..30 and the editor body spans x=31..150. zone_for() classifies
  # the middle third of the editor as Center, outer thirds as edge
  # zones; x=140 sits firmly in DropZone::Right.

  # 1. Press at the source. The tree row registers a press; ghost
  #    chip won't appear until a Drag event comes in (mouse only
  #    transitions to drag mode on movement after press).
  echo '{"cmd":"mouse_down","col":13,"row":5}' >> "$CMD"
  sleep 0.18

  # 2. Walk the cursor across the editor area in 7 steps. Each move
  #    paints: the ghost chip following the cursor, then once we're
  #    inside the editor pane the drop overlay highlights the zone
  #    under the cursor.
  for pt in "30 8" "50 11" "70 14" "90 16" "110 18" "130 19" "140 20"; do
    set -- $pt
    echo "{\"cmd\":\"mouse_move\",\"col\":$1,\"row\":$2}" >> "$CMD"
    sleep 0.22
  done

  # 3. Hold at the right edge so the viewer sees the gray right-zone
  #    overlay highlighted before release.
  sleep 0.8

  # 4. Release — editor vertical-splits and editor.rs lands in the
  #    new right pane.
  echo '{"cmd":"mouse_up","col":140,"row":20}' >> "$CMD"
  sleep 0.4

  # Hold the post-drop two-pane state for a read.
  sleep 1.8

  # Quit so VHS's outer shell falls back to the prompt and the tape
  # can end cleanly.
  echo '{"cmd":"quit"}' >> "$CMD"
} > /dev/null 2>&1
