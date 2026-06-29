---
agent: vscode-user-mouse
severity: SEV-2
---

## SEV-2 Right-panel tab strip left-click doesn't switch active tab

**Reproduction**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}      # tab 0 (Outline)
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"lsp.diagnostics"}   # tab 1 (Diagnostics), now active
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":133,"row":1,"button":"left"}   # tab 0 (Outline) — inactive
{"cmd":"wait_ms","ms":600}
{"cmd":"snapshot"}
```
`rects.json` reports:
```
right_panel_tab:0 at (128, 1, 11, 1)   # Outline chip
right_panel_tab:1 at (140, 1, 12, 1)   # Diagnostics chip (active)
```
After the click on tab 0 at (133, 1) — well within Outline's 128-138 range — `status.json` still shows `"rightPanelActiveIdx":1`. The active tab does NOT switch.

Reproduces at cols 130 / 133 / 135 / 138 (every cell of tab 0). Reproduces with `right_panel_visible: true` pre-set in `session.json` (i.e. not a toggle-vs-click race). Reproduces with `right_panel_active_idx: 0` pre-set then opening lsp.diagnostics second (so the click-target *should* be a non-active tab regardless of order).

Bufferline tab click at row 1 (e.g. `bufferline_tab:0` at (31, 1, 13, 1)) DOES work from the same harness, so the click dispatch infrastructure is fine — only the right-panel tab strip ignores clicks.

**Expected**: Left-click on any tab chip in the right-panel header switches to that tab. Per `src/tui/mouse.rs:1379-1390`:
```rust
if let Some(&(_, tab_idx)) = app.rects.right_panel_tabs.iter()
    .find(|(rect, _)| crate::app::dispatch::contains(*rect, x, y))
{
    app.right_panel_active_idx = tab_idx;
    return;
}
```

**Actual**: `right_panel_active_idx` is unchanged after the click. The two-tabs view stays on whichever tab was last opened (FIFO-active = `right_panel_panes.len() - 1`).

**Impact**: Right-panel is shipped as a multi-tab host (Outline / Diagnostics / Ai / Tests / Grep, cap = 3). Once two tabs are present, the user has no mouse path to switch between them. Keyboard `<leader>tn` / `<leader>tp` exists but the whole right-panel feature was advertised as "click the tab to switch" (the panel chrome looks like a tab strip).

**Severity rationale**: Tab strip looks clickable, behaves dead. Combined with the SEV-2 × close bug, mouse-only users essentially cannot operate the right panel at all once it has multiple hosted panes.
