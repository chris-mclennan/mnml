---
agent: vscode-user-mouse
severity: SEV-2
verifies: mouse-right-panel-x-close-left-click-noop
verdict: REFUTED (fixed)
---

## Verdict — REFUTED against fresh binary

`target/release/mnml` mtime is Jun 28 23:13 (post b767b8c at 23:01). Re-ran the
exact reproduction from `mouse-right-panel-x-close-left-click-noop.md`.

**Repro (160x50 headless, MNML_COLS=160 MNML_ROWS=50)**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":600}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":700}
{"cmd":"snapshot"}
```

Before × click:
- `rects.json` → `right_panel_close at (158,1,1,1)`, `right_panel_tab:0 at (128,1,11,1)`
- `status.json` → `rightPanelPanes:[1]`, `panes:[{"main.rs"},{"main.rs ⌥"}]`

After `{"cmd":"click","col":158,"row":1,"button":"left"}`:
- `status.json` → `rightPanelPanes:[]`, `panes:[{"main.rs"}]`

The × close fires and removes the outline pane from the right panel AND from
`panes`. Prior agent appears to have been running against a stale release binary;
the fixed wiring at `src/tui/mouse.rs:1409-1423` is reaching `close_pane(pid)` as
expected.
