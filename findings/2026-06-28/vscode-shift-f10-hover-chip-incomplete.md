---
agent: vscode-user
severity: SEV-2
---

## SEV-2 Shift+F10 hover_chip-recent fallback misses integration chips + every statusline chip

**Reproduction (integration chip)**:
```
// Fresh session, pane focus, active editor open
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"esc"}
{"cmd":"click","col":80,"row":5}            // click into editor → focus=pane, active=Some
{"cmd":"wait_ms","ms":150}
{"cmd":"hover","col":4,"row":34}            // hover the browser integration chip (rect: x=3 y=34 w=4)
{"cmd":"wait_ms","ms":100}
{"cmd":"key","key":"shift+f10"}             // expected: integration chip context menu
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
```

The same right-click via mouse (`{"cmd":"click","col":4,"row":34,"button":"right"}`) DOES open the integration context menu, so the menu surface itself works.

**Expected**: per the task description ("hover_chip-recent fallback for Shift+F10") and the doc comment in `src/app/context_menus.rs:32-36`:

> keyboard-hunter v3 2026-06-28 SEV-2: was dead code because Focus::Pane with active.is_some() always matched first. Now a RECENT hover_chip (within 2s) takes priority — matches user intent when they hovered a chip and then hit Shift+F10 deliberately.

Hovering the chip and pressing Shift+F10 within 2s should pop the integration chip context menu (Disable / Edit… / Remove).

**Actual**: Shift+F10 opens the active editor's *tab* context menu (Pin tab / Close / Close others / …) — i.e. the focus-based fallback wins, the hover_chip override is ignored. Same behavior reproduces for `LauncherIcon` and `ActivityBarGear` hovers in my testing.

Additionally, every statusline chip variant (`StatuslineBranch`, `StatuslineWorkspace`, `StatuslineMode`, `StatuslineClock`, `StatuslineMixr`, `StatuslineLsp`, etc.) is NOT in the `hover_chip_anchor` match (`src/app/context_menus.rs:41-66`) — the closure only enumerates `IntegrationIcon` / `LauncherIcon` / `ActivityBarGear`. Hovering the branch chip and pressing Shift+F10 falls through to the tab context menu by design.

**Source pointer**: `src/app/context_menus.rs:37-86` — `open_context_menu_at_focus`. The early-out at line 72 (`if hover_recent && let Some(...) = hover_chip_anchor`) appears not to fire even for IntegrationIcon in my repro; my best guess is that `right-click` on the chip elsewhere updates `app.hover_chip` to the chip but the IPC `hover` synthetic event isn't taking the same path. Could also be `right_panel_visible` toggle re-painting the chips between the hover and the Shift+F10 keypress.

**Notes**: The unit test `context_menu_at_focus_uses_hover_chip_fallback_for_gear` (in `src/app/mod.rs:11807`) covers ActivityBarGear via direct App-state manipulation but doesn't drive the full Moved-event pipeline. The headless IPC repro is the closest analog to a real mouse-then-keyboard sequence, and it doesn't hit the override. SEV-2 because the feature was explicitly called out as landed and a keyboard-first user has no way to discover the right-click menus on chips otherwise.
