#!/usr/bin/env bash
# Drives mnml via IPC for the right-panel-ai-chat tape (v4).
#
# Beats:
#   ~1s  → open src/lib.rs into the editor
#   ~4s  → view.toggle_right_panel  (open panel — empty state)
#   ~7s  → ai.explain               (AI chat opens as a tab in the panel;
#                                    pane shows the "Asking…" state)
#  ~15s  → (recording ends)
#
# The AI request fires `claude -p <prompt>` under `[ai] backend = "cli"`
# (the default). On this machine `claude` is on PATH so the pane
# transitions from "Asking…" → streaming → "Done" within the recording.
# If `claude` is missing the pane still appears + tabs render — the
# user just sees the Asking/Error state instead.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  sleep 1.0

  # Open lib.rs — ai.explain feeds the active editor's buffer to claude.
  echo '{"cmd":"open","path":"src/lib.rs"}' >> "$CMD"

  # Open the panel — empty state.
  sleep 3.0
  echo '{"cmd":"run-command","id":"view.toggle_right_panel"}' >> "$CMD"

  # Fire ai.explain — chat lands in the panel as a tab (v4 routing).
  sleep 3.0
  echo '{"cmd":"run-command","id":"ai.explain"}' >> "$CMD"
} >/dev/null 2>&1
