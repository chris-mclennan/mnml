---
agent: vscode-user-mouse
severity: SEV-2
---

## SEV-2 Right-panel grip drag does not resize the panel

**Reproduction**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":101,"row":0,"button":"left"}     # toggle panel on
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
{"cmd":"drag","from_col":128,"from_row":24,"col":80,"row":24}
{"cmd":"wait_ms","ms":600}
{"cmd":"snapshot"}
```
`rects.json` reports `right_panel_edge` at `(127, 22, 3, 4)`. Drag source `(128, 24)` is inside that rect; drag destination `(80, 24)` is well to the left — a 48-cell drag along the grip's vertical row.

After the drag:
- `session.json` → `"right_panel_width": 32` (unchanged from default).
- Screen header `SIDE PANEL` still anchored at col 129 (panel still 32 cells wide).
- `right_panel_edge` still reports x=127.

Reproduces with `from_row=23`, `from_row=24`, and `from_row=25` (entire 4-row grip area). Reproduces with drag to col 80 or col 50. Reproduces with `right_panel_visible: true` pre-set in `session.json` so no toggle event interferes.

By contrast, the tree edge drag at `(28, 23) → (50, 23)` works against the same harness — only the right-panel grip ignores drags.

**Expected**: `src/tui/mouse.rs:1376-1378` calls `app.maybe_start_right_panel_edge_drag(x, y)` on `Down(Left)`, which sets `app.dragging_right_panel_edge = true`. Subsequent `Drag(Left)` events at `src/tui/mouse.rs:3176-3193` recompute width as `screen_w.saturating_sub(x).clamp(8, 120)`. A drag from col 128 → col 80 should grow the panel from ~32 to ~80 cells.

**Actual**: Width never moves. Either `maybe_start_right_panel_edge_drag` is failing the rect-contains check at click time, or the `Drag` branch is being preempted by an earlier arm.

**Impact**: Drag-to-resize is the discoverable mouse path advertised by the visible `┃` grip glyph. With it dead, the only way to change panel width is `:set rightpanelwidth` or editing `session.json` directly.

**Pairs with**: same render-side rect family that powers the × close + tab strip — strongly suggests a paint/dispatch ordering or release-mode optimization regression specific to the right-panel chrome rects. All three were among the "trio + W-1/2/3 + mouse SEV-1/2" fixes claimed in `6433be3`.
