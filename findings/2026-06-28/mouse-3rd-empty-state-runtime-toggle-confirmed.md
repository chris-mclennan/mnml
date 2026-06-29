---
agent: vscode-user-mouse
severity: SEV-3
verifies: mouse-right-panel-empty-state-click-fails-after-runtime-toggle
verdict: CONFIRMED (still broken)
---

## Verdict — CONFIRMED still broken after b767b8c

Fresh binary, scenario B (runtime toggle then click):

```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":1000}
{"cmd":"snapshot"}
```

State after toggle:
- `rects.json` → `right_panel_empty_outline at (129,5,13,1)`,
  `right_panel_empty_diagnostics at (129,6,16,1)` (both registered correctly).
- Screen confirms `:outline.show` rendered on screen row 5 col ~129,
  `:lsp.diagnostics` on row 6.

After `{"cmd":"click","col":133,"row":5,"button":"left"}`:
- `status.json` → `rightPanelPanes:[]`, `panes:[{"main.rs"}]` — no outline opened.

After `{"cmd":"click","col":133,"row":4,"button":"left"}` (off-by-one safety
check):
- `status.json` → `rightPanelPanes:[]`, still nothing.

Same outcome with `view.toggle_right_panel` opening the panel and a
`wait_ms":1000` beat before the click. The empty-state click path at
`src/tui/mouse.rs:1394-1405` is NOT reached when the panel was opened via a
runtime toggle. The contemporaneous fix shipped the rects to `rects.json`
(`mouse-rects-empty-state-not-dumped.md` is confirmed-fixed) but did not address
the live-click no-op.

**Speculation on root cause** (worth a fresh investigation pass; not verified
here): the `Down(Left)` arm at `src/tui/mouse.rs:1369-1405` runs the tree-edge
drag check, the right-panel-edge drag check, the tab-strip check, then the
empty-state checks. After a runtime toggle, the panel-edge or focus-shift may
swallow the down event before reaching line 1394 — but the rects.json proves
the empty-state rects ARE registered, so it's a dispatch ordering issue not a
paint issue.
