#!/usr/bin/env bash
# Drives mnml via IPC for the file-actions-cut-paste tape.
#
# Flow:
#   1. Left-click the file tree row for `Cargo.toml` to move the tree
#      cursor onto it. `focus_tree` is set implicitly.
#   2. Fire `Ctrl+X` — from tree focus this dispatches `file.cut`
#      (see `tui/handlers/pane.rs`), which stages Cargo.toml on
#      `App::file_clipboard` with `file_clipboard_cut = true` and
#      toasts "cut Cargo.toml".
#   3. Left-click the file tree row for `src/` to move the cursor
#      onto the folder.
#   4. Fire `Ctrl+V` — `file.paste` runs, which reads the clipboard
#      and calls `App::file_paste_into(selected_row.path)`.
#      Because src/ is a directory, the target dir IS src/. Cargo.toml
#      is `fs::rename`'d in (cut = move) and the tree refreshes.
#      Toast: "moved 1 item into src".
#
# The tree row coordinates come from `rects.json`, where the tree
# renders `tree_row:<N>` for each row (dumped 2026-07-07 to enable
# this tape). We locate rows by scraping the row-label strings from
# screen.txt is unreliable in the terminal path — instead we use the
# tree cursor via IPC `key: down` presses to walk to the row, then
# assert on screen state.
#
# All output suppressed so the bg job doesn't pollute the recorded PTY.

set -u
WS="$1"
CMD="$WS/.mnml/ipc/command"
RECTS="$WS/.mnml/ipc/rects.json"

wait_rects_has() {
  local pattern="$1"
  local i
  for i in $(seq 1 60); do
    if [ -e "$RECTS" ] && grep -Fq -- "$pattern" "$RECTS" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

{
  for _ in $(seq 1 80); do
    [ -e "$CMD" ] && break
    sleep 0.1
  done
  wait_rects_has "tree_toggle"
  sleep 0.6

  # Focus starts on the tree with cursor at row 0 (`.mnml/`).
  # Visible-tree layout (auto-expands make .mnml + src open):
  #   [0] .mnml/  (dir)
  #   [1]   .welcomed
  #   [2] src/   (dir)
  #   [3]   main.rs
  #   [4] Cargo.toml    ← 4 downs lands here (cut target)
  #   [5] README.md
  #
  # 1. Walk to Cargo.toml.
  echo '{"cmd":"key","key":"down"}' >> "$CMD"
  sleep 0.3
  echo '{"cmd":"key","key":"down"}' >> "$CMD"
  sleep 0.3
  echo '{"cmd":"key","key":"down"}' >> "$CMD"
  sleep 0.3
  echo '{"cmd":"key","key":"down"}' >> "$CMD"
  sleep 0.4

  # 2. Ctrl+X → file.cut. Stages Cargo.toml on clipboard.
  echo '{"cmd":"key","key":"ctrl+x"}' >> "$CMD"
  sleep 1.6

  # 3. Up once to land on main.rs (row 3, inside src/). `file.paste`
  #    resolves the target dir from the SELECTED file's parent — so
  #    a file inside src/ paste-targets src/ correctly. Selecting
  #    src/ itself doesn't work because `file.paste` uses
  #    `selected_file()`, which filters out dirs and falls back to
  #    the workspace root.
  echo '{"cmd":"key","key":"up"}' >> "$CMD"
  sleep 0.6

  # 4. Ctrl+V → file.paste. Moves Cargo.toml into src/.
  echo '{"cmd":"key","key":"ctrl+v"}' >> "$CMD"
  sleep 2.5
} >/dev/null 2>&1
