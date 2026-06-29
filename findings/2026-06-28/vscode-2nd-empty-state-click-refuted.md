---
agent: vscode-user
severity: SEV-3
verifies: vscode-empty-state-row-misroutes
---

## REFUTED — empty-state command rows route to the correct command

**Reproduction (`:outline.show` row)**:
```
{"cmd":"key","key":"esc"}
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":400}
{"cmd":"snapshot"}
# screen.txt shows ":outline.show" on mnml-row 5 (cat -n line 6)
#                  ":lsp.diagnostics" on mnml-row 6 (cat -n line 7)
{"cmd":"click","col":92,"row":5,"button":"left"}
{"cmd":"wait_ms","ms":500}
# status: rightPanelPanes:[1], panes[1].title == "lib.rs ⌥"  (outline ✓)
```

**Reproduction (`:lsp.diagnostics` row, fresh session)**:
```
# (same setup, then)
{"cmd":"click","col":92,"row":6,"button":"left"}
{"cmd":"wait_ms","ms":500}
# status: rightPanelPanes:[1], panes[1].title == "problems ✓"  (diagnostics ✓)
```

Both clicks route to the CORRECT command. Outline row → outline opens. Diagnostics row → diagnostics opens.

**Source confirmation**: `src/ui/mod.rs:902-913` registers the rects:
- `right_panel_empty_outline.y = hint_rect.y + 2`
- `right_panel_empty_diagnostics.y = hint_rect.y + 3`

`src/tui/mouse.rs:1394-1405` routes hits inside each rect to the correct command. The wiring is symmetric and correct.

**What the prior agent likely missed**:
The empty-state rects (`right_panel_empty_outline` / `right_panel_empty_diagnostics`) are NOT serialized into `rects.json` (the `rects_dump_json` function in `src/ipc/mod.rs:906-` omits them — only `right_panel_edge`, `right_panel_close`, and `right_panel_tab:N` are dumped). The prior agent saw this absence and inferred "the row→command mapping is off-by-one or swapped" — but absence from the audit dump does NOT mean missing from the click handler. The click handler reads the in-memory `app.rects` struct directly, not the JSON dump.

Recommendation (low priority polish): add `right_panel_empty_outline` and `right_panel_empty_diagnostics` to `rects_dump_json` so future audits don't repeat this false positive.

Additional timing observation: a click sent IMMEDIATELY after `view.toggle_right_panel` (within the same batch with no intervening snapshot or longer wait) can be processed BEFORE the next draw cycle has populated the empty-state rects. In that race the click is silently dropped (the rects are `None`). 400ms + a snapshot beat is enough; a tighter sequence may miss. This is the kind of harness-timing flake that may have produced the prior agent's "click does nothing" observation.
