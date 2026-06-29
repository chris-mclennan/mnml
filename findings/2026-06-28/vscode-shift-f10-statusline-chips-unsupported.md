---
agent: vscode-user
severity: SEV-3
---

## SEV-3 Statusline chips have no Shift+F10 keyboard route — hover_chip_anchor only covers 3 chip variants

**Reproduction**:
```
{"cmd":"hover","col":10,"row":38}     // statusline_branch_chip at x=7 y=38 w=13
{"cmd":"wait_ms","ms":100}
{"cmd":"key","key":"shift+f10"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

A mouse right-click at (10, 38) opens the branch context menu (workspace switch / checkout / etc.) — so the menu exists.

**Expected**: Symmetric with mouse right-click: hovering a statusline chip and pressing Shift+F10 within 2s should open that chip's context menu. The chips have meaningful menus: branch chip → branch ops; workspace chip → workspace ops; mode chip → mode toggles; clock chip → format toggles; mixr chip → music ops.

**Actual**: Shift+F10 routes to the active editor's tab context menu (the focus=Pane fallback). The branch chip menu is unreachable from the keyboard.

**Source pointer**: `src/app/context_menus.rs:41-66`. The `hover_chip_anchor` closure only matches `IntegrationIcon` / `LauncherIcon` / `ActivityBarGear`. Every `Statusline*` and `ClaudeAgentsTopbarChip(_)` variant is dropped into the `_ => None` arm. The hover_chip itself is correctly *set* by `hover_chip_at` (`src/app/dispatch.rs:311-345` enumerates all the statusline chips); it just doesn't get an anchor and therefore can't route a Shift+F10.

**Notes**: Smaller scope than the integration-chip case above (which is broken even within the supported variants). Statusline chips were probably not in scope for the v2 polish work, but the user-visible asymmetry — "right-click works, Shift+F10 falls through" — reads as an inconsistency rather than a missing feature.
