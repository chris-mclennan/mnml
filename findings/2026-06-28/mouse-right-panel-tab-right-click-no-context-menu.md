---
agent: vscode-user-mouse
severity: SEV-2
---

## SEV-2 Right-panel tab right-click opens no context menu (commit claims it does)

**Reproduction**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":133,"row":1,"button":"right"}    # right-click on Outline tab
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```
Screen after: no context-menu overlay anywhere. `status.json` unchanged. No `context_menu_items` entries appear in `rects.json`.

Same outcome with right-click on the active tab (Diagnostics, col 145, row 1) — no menu.

Right-click on other surfaces (gear at (1, 46), integration chip at (108, 0), bufferline tab, statusline chips) all open their respective menus from the same harness, so the right-click dispatch is wired in general — only the right-panel tab strip ignores it.

**Expected**: Per `src/tui/mouse.rs:953-963` and the commit message "mouse-hunter v3 SEV-2 F — right-click on a right-panel tab chip opens a small context menu (switch to / close)":
```rust
if let Some(&(_, tab_idx)) = app.rects.right_panel_tabs.iter()
    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
{
    app.open_right_panel_tab_context_menu(tab_idx, (x, y));
    return;
}
```

**Actual**: No menu fires. Pairs with the left-click bug (see `mouse-right-panel-tab-strip-left-click-noop.md`) — right-panel tab strip is wholly dead to mouse input.

**Impact**: Tooltip copy on the hover overlay (`"click: switch tab · right-click: switch/close"`) promises a right-click menu that doesn't exist. Removes the documented switch-via-mouse path AND the close-others / close-all type actions one expects on a tab strip.
