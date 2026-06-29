---
agent: vscode-user
severity: SEV-2
---

## SEV-2 Empty-state command rows in right panel misroute (`:outline.show` opens diagnostics; `:lsp.diagnostics` does nothing)

**Reproduction**:
```
{"cmd":"key","key":"esc"}
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
// Screen shows the SIDE PANEL empty-state with two clickable command rows:
//   row 6 col ~89: ":outline.show"
//   row 7 col ~89: ":lsp.diagnostics"
{"cmd":"click","col":92,"row":6}        // click the ":outline.show" row
{"cmd":"wait_ms","ms":400}
{"cmd":"snapshot"}
// → panel shows "problems ✓" (diagnostics), NOT "lib.rs ⌥" (outline)
```

Second click (`:lsp.diagnostics` line) after closing the misrouted tab via the `×` is silently dropped.

**Expected**: VS Code-style empty-state placeholders that read like clickable commands should run THAT command when clicked. Click the row that says `:outline.show` → outline tab opens; click `:lsp.diagnostics` → diagnostics tab opens.

**Actual**: 
- Clicking the visible `:outline.show` row opens the *diagnostics* tab.
- Clicking the visible `:lsp.diagnostics` row does nothing.
- Running `{"cmd":"run-command","id":"outline.show"}` does open outline correctly, confirming the underlying command works — only the click routing on the empty-state rows is broken.

**Source pointer**: the empty-state rows have no rect entries in `rects.json` (only `right_panel_edge`, `right_panel_close`, and `right_panel_tab:N` are dumped). The click is presumably resolved by hard-coded row-relative coordinates inside `src/ui/right_panel.rs` (or wherever the empty-state body is rendered). The row→command mapping is off-by-one or swapped.

**Notes**: This was flagged in the task description as a v3+ landing ("empty-state command lines clickable"). The lines render correctly; the click handler maps the wrong row to the wrong action. Right panel currently has no other obvious way to open outline/diagnostics from a fresh empty state without typing or hitting the palette — so this is the primary surface the feature was meant to support and it doesn't work.
