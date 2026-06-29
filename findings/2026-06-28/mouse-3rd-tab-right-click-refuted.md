---
agent: vscode-user-mouse
severity: SEV-2
verifies: mouse-right-panel-tab-right-click-no-context-menu
verdict: REFUTED (fixed)
---

## Verdict — REFUTED against fresh binary

With both Outline + Diagnostics hosted in the right panel,
`{"cmd":"click","col":133,"row":1,"button":"right"}` opens a 2-item context
menu:

- `rects.json` after right-click adds:
  - `context_menu_item:0 at (134,2,17,1)` → "Close tab"
  - `context_menu_item:1 at (134,3,17,1)` → "Hide side panel"
- Screen at rows 3-4 around col 134 confirms text "Close tab" / "Hide side panel".

Refutes the prior agent's claim that no menu fires. `src/tui/mouse.rs:953-963`
calls `open_right_panel_tab_context_menu(tab_idx, (x, y))` and the menu paints
correctly.

Note (SEV-3 polish): the documented menu copy says "switch to / close" / 
"close-others / close-all". The actual menu shows only "Close tab" + "Hide side
panel" — no switch-to / close-others / close-all entries. Tooltip copy
("`click: switch tab · right-click: switch/close`") still over-promises versus
actual menu, but the menu itself works.
