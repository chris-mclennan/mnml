---
agent: vscode-user
severity: SEV-3
verifies:
---

## CONFIRMED WORKING — v4 ai.* routes, v5 tests host, right-panel tab right-click menu

Three additional surfaces exercised; all behave as documented. Filing this as a "feature works as advertised" note rather than a bug.

### v4 — All 5 ai siblings route into the right panel

```
{"cmd":"open","path":"src/main.rs"}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"run-command","id":"ai.explain"}
# rightPanelPanes:[1], pane[1]="AI: explain …"
{"cmd":"run-command","id":"ai.fix"}
{"cmd":"run-command","id":"ai.refactor"}
{"cmd":"run-command","id":"ai.write_tests"}
# rightPanelPanes:[1,2,3], panes=[AI:fix, AI:refactor, AI:write tests]
{"cmd":"run-command","id":"ai.ask"}
{"cmd":"type","text":"what does add do"}
{"cmd":"key","key":"enter"}
# rightPanelPanes:[1,2,3], panes=[AI:refactor, AI:write tests, AI:what does…]
```

All five siblings (`ask`, `explain`, `fix`, `refactor`, `write_tests`) push into `right_panel_panes` via `ask_ai` (`src/app/ai.rs:1102-1106`). FIFO cap of `RIGHT_PANEL_MAX_TABS = 3` evicts the oldest pane on overflow — observed as expected (the toast "right panel full — closed oldest tab" fires). No editor-body splits created. AI panes correctly carry the `✦` activity glyph in their title once Claude streams a response.

### v5 — `test.run_all` hosts a Tests pane in the panel

```
{"cmd":"run-command","id":"test.run_all"}
# rightPanelPanes appended; pane title = "tests ✓0"  (or "tests …" while running)
```

`src/app/playwright.rs:126-130` is the same shape as the AI / Grep routes — push + right_panel_push when panel is visible. Verified.

### Right-panel tab right-click → context menu

Right-clicking on the active tab strip (col within `right_panel_tab:N`, row=1) opens a 2- or 3-item menu:
- "Switch to this tab" (only when right-clicked on an INACTIVE tab — context-aware, smart)
- "Close tab"
- "Hide side panel"

All three options exercised; all work:
- Switch → `right_panel_active_idx` flips to the clicked tab's index.
- Close → `close_pane` runs; `right_panel_panes` shrinks by 1; active idx clamps; the right panel stays visible.
- Hide → `view.toggle_right_panel` fires; `rightPanelVisible:false`; hosted panes closed too (so the bufferline doesn't leak ghost entries).

The menu auto-omits "Switch to this tab" when right-clicked on the already-active tab — a nice touch.

**Notes**:
The screen render of the context menu has a minor cosmetic glitch — the menu border ANSI characters punch through and obscure adjacent text in the right-panel body (the AI streaming text behind the menu shows broken vertical bar `│` characters where the menu border overlays its own border on the next-cell-over right-panel border). Probably the right-panel border isn't being properly suppressed under the popup. Cosmetic only; menu clicks land correctly. Not filing separately.
