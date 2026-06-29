---
agent: vscode-user-mouse
severity: SEV-2
---

## SEV-2 Right-panel × close button left-click is a no-op (mouse-only users can't remove a hosted pane)

**Reproduction**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}    # panel hosts main.rs ⌥
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":158,"row":1,"button":"left"}   # the × glyph
{"cmd":"wait_ms","ms":600}
{"cmd":"snapshot"}
```
`rects.json` reports `right_panel_close` at `(158, 1, 1, 1)` and `panes[1].title == "main.rs ⌥"`. After the click, status still shows `panes:[{"main.rs"},{"main.rs ⌥"}], rightPanelPanes:[1]` — the outline pane is still there.

Same outcome with `right_panel_visible: true` pre-set in `session.json` (i.e. no toggle-then-click race). Same outcome whether you click col 156, 157, 158, or 159. Same outcome with `outline.show` opened via the palette button (not just `run-command`).

Run the closure path directly and it works:
```jsonl
{"cmd":"run-command","id":"view.right_panel_close_tab"}
# → rightPanelPanes:[], panes:[{"main.rs"}]
```
…so `close_pane` works fine. The defect is in the mouse-click path that wraps it.

**Expected**: Left-clicking the × on the right-panel header closes the active hosted tab (per the comment at `src/tui/mouse.rs:1406-1422` "Right-panel v3 `×` on the header closes the active tab").

**Actual**: Click hits the `right_panel_close` rect (verified in `rects.json`) but no close fires. The pane and bufferline-filter exclusion both remain.

**Source pointer**: `src/tui/mouse.rs:1409-1423` reads `app.rects.right_panel_close`, calls `app.right_panel_active_pane_id()` then `app.close_pane(pid)`. The wiring LOOKS correct. Possibilities to verify:
- Some earlier `Down(Left)` arm returns before line 1409 (rect-shadow), even though no other rect in `rects.json` covers (158, 1).
- The release-mode binary diverges from the source path (worth `cargo build --release` then re-running this scenario fresh; it reproduces against the current `target/release/mnml`).

**Impact**: The × is the only mouse-only way to close a right-panel-hosted pane (Outline / Diagnostics / Ai / Tests / Grep). Today the user must reach for a chord (`<leader>tx` / `view.right_panel_close_tab`) or the palette — defeats the whole "VS Code-style close glyph" promise.
