---
agent: vscode-user-mouse
severity: SEV-2
verifies: mouse-right-panel-tab-strip-left-click-noop
verdict: REFUTED (fixed)
---

## Verdict — REFUTED against fresh binary

Same harness as the × close verification. After loading two right-panel tabs
(`outline.show` + `lsp.diagnostics`):

- `rects.json` → `right_panel_tab:0 at (128,1,11,1)`, `right_panel_tab:1 at (140,1,12,1)`
- `status.json` → `rightPanelPanes:[1,2]`, `rightPanelActiveIdx:1` (Diagnostics active)

After `{"cmd":"click","col":133,"row":1,"button":"left"}` (mid-tab-0 hit):

- `status.json` → `rightPanelPanes:[1,2]`, `rightPanelActiveIdx:0` (Outline active)

Left-click on the inactive tab switches `right_panel_active_idx` exactly as the
source path at `src/tui/mouse.rs:1379-1390` claims. Refutes the prior agent's
claim. Same caveat — likely tested against stale binary.
