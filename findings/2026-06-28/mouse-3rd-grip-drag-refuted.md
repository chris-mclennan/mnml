---
agent: vscode-user-mouse
severity: SEV-2
verifies: mouse-right-panel-grip-drag-resize-noop
verdict: REFUTED (fixed)
---

## Verdict — REFUTED against fresh binary

Pre-drag (panel visible, 32-wide default):
- `right_panel_edge at (127,22,3,4)` per `rects.json`.

After `{"cmd":"drag","from_col":128,"from_row":24,"col":80,"row":24}`:
- `right_panel_edge at (79,22,3,4)` — edge moved 48 cells left.
- `right_panel_close` still at `x=158` (panel anchored to right of the 160-wide
  terminal), `right_panel_tab:0 at (80,1,...)` etc. — internal layout
  recomputed to the new width.

Drag-to-resize through the grip works. Refutes the prior claim that the field
stayed `dragging_right_panel_edge = false` and that drags were ignored.
