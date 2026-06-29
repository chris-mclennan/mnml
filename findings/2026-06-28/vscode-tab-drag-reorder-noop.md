---
agent: vscode-user
severity: SEV-2
---

## SEV-2 Tab drag-to-reorder ignores the drop point — drag collapses into a click

**Reproduction**:
```
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"open","path":"src/main.rs"}
{"cmd":"open","path":"README.md"}
{"cmd":"open","path":"Cargo.toml"}
{"cmd":"wait_ms","ms":200}
// bufferline_tab:0 rect at x=31 y=1 w=12  (lib.rs, leftmost)
// bufferline_tab:3 rect at x=89 y=1 w=16  (Cargo.toml, rightmost)
{"cmd":"drag","from_col":37,"from_row":1,"col":105,"row":1}   // drag lib.rs onto Cargo.toml
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

Then read `status.json`: `panes: ["lib.rs", "README.md", "Cargo.toml"]`, active = 0 (lib.rs).

(`main.rs` was already closed earlier in the run; relevant fact is the order: lib.rs is still in position 0.)

**Expected**: VS Code-style drag the tab from slot 0 to slot 3 (or 2, or wherever the drop col falls) → tab order becomes `["README.md", "Cargo.toml", "lib.rs"]` (lib.rs slot moved to the right). A drop indicator (caret / vertical bar) should be visible while dragging.

**Actual**: The drag was synthesized as Down(left) at (37,1) + a series of Drag(left) steps + Up(left) at (105,1). The end result is identical to a single click on the lib.rs tab — focus moved to it. No reorder. Inspecting `rects.bufferline_drag_ghost` / `bufferline_drag_tab` shows nothing persists across the drag.

**Source pointer**: `src/tui/mouse.rs` — `bufferline_drag_tab` / `bufferline_drag_ghost` / `update_tab_insert_hint` / `update_tab_drop_target` are referenced (lines ~502-505) for the Moved-event path, but the IPC Drag(Left) path apparently doesn't enter the same "tab drag-in-progress" state. The bufferline Down handler probably doesn't latch into a drag mode until N cells of movement, and the IPC drag's per-cell-step events don't trip the threshold consistently.

**Notes**: Drag-to-reorder is muscle memory for any VS Code user who opens many files. Without it, you can only reorder via close-and-reopen (which changes the recent files list) or via right-click context menu items that don't currently include "Move left" / "Move right". The drag visual hint also doesn't render during the synthetic drag — same hit-test path; same root cause likely.
