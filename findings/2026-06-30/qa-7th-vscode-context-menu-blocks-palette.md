---
agent: vscode-user
severity: SEV-3
---

# A statusline context menu opened from the palette absorbs the next Ctrl+Shift+P

After running `statusline.workspace_menu` (or `branch_menu`) from
`Ctrl+Shift+P`, the resulting context menu is shown. Pressing `Esc` once
appears to dismiss it on screen, but the next `Ctrl+Shift+P` + `type "…"`
keystrokes route into the *still-active* menu's filter state instead of
opening a new palette. A second `Esc` (sometimes a third) is required to
fully release the menu before the palette re-opens.

## Reproduction

```jsonl
{"cmd":"key","key":"ctrl+shift+p"}
{"cmd":"type","text":"statusline.workspace_menu"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":400}
// workspace menu visible
{"cmd":"key","key":"esc"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"ctrl+shift+p"}
{"cmd":"type","text":"statusline.clock_menu"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":400}
{"cmd":"snapshot"}
// EXPECTED: clock menu opens.
// ACTUAL: workspace menu still on screen; clock menu never opens. A second
// Esc is required before the palette will reopen.
```

**Expected**: one `Esc` reliably dismisses the menu and the next palette
launch is clean.

**Actual**: takes two Esc's to fully release the workspace / branch menu
state. The first Esc closes the menu but leaves some flag set that swallows
the next palette keystroke.

**Source pointer**: probably in
`src/app/mod.rs:open_statusline_workspace_context_menu` (and friends) —
the menu's keystroke-routing state isn't fully unwound on the first Esc.

**Notes**: a Mac VS Code user with menubar context menus expects single-Esc
dismissal. Two-Esc behavior reads as "the editor is stuck."
