---
agent: vscode-user-mouse
severity: SEV-3
verifies: vscode-2nd-empty-state-click-refuted
---

## SEV-3 Empty-state `:outline.show` / `:lsp.diagnostics` click fires when panel loaded from session BUT not after a runtime toggle (regression to the "refuted" finding)

**Two reproductions** — same harness, same workspace, same click coords, ONE difference (how the panel got opened) flips the outcome:

### A. Panel pre-loaded from session → click WORKS
```jsonl
# session.json before launch:
# {"right_panel_visible":true, ...}
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":133,"row":5,"button":"left"}   # ":outline.show" row
{"cmd":"wait_ms","ms":600}
{"cmd":"snapshot"}
# status.json: rightPanelPanes:[1], panes[1].title == "main.rs ⌥"  ✓
```
…and same shape for `:lsp.diagnostics` at row 6 → `"problems ✓"` opens. This matches `findings/2026-06-28/vscode-2nd-empty-state-click-refuted.md`.

### B. Panel toggled at runtime via click → click FAILS
```jsonl
# session.json before launch:
# {"right_panel_visible":false, ...}  (or session absent → default off)
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":101,"row":0,"button":"left"}   # palette right-panel toggle button
{"cmd":"wait_ms","ms":1000}
{"cmd":"snapshot"}
# screen now shows the panel + empty-state with :outline.show on row 5
{"cmd":"click","col":133,"row":5,"button":"left"}   # SAME click as scenario A
{"cmd":"wait_ms","ms":1000}
{"cmd":"snapshot"}
# status.json: rightPanelPanes:[], panes:[main.rs only]  ✗
```
Same outcome via `{"cmd":"run-command","id":"view.toggle_right_panel"}` instead of the palette button click. Same outcome with `wait_ms` bumped to 2000ms between toggle and click (so it's NOT the timing-race the earlier "refuted" note theorized).

### C. Panel toggled via panel button + snapshot beat → click STILL FAILS
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}                                  # the "snapshot beat" the prior agent recommended
{"cmd":"click","col":133,"row":5,"button":"left"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
# status: rightPanelPanes:[] — no outline added
```

**Expected**: The empty-state command rows are clickable; clicking either fires the matching command, regardless of how the panel was opened.

**Actual**: Only the session-preloaded path lights up the rect. A runtime toggle (click or `run-command`) leaves the rect "dead" until the panel was opened on a prior session.

**Source pointer**: `src/ui/mod.rs:902-913` registers `right_panel_empty_outline` / `right_panel_empty_diagnostics` on each frame where panel is visible AND `right_panel_panes` is empty. Note these rects are NOT serialized in `rects.json` (`src/ipc/mod.rs:906-` only dumps `right_panel_edge`, `right_panel_close`, and `right_panel_tab:N`), so audits can't directly verify the rect is present — but the screen shows the empty-state text rendered at the expected location in BOTH scenarios A and B.

**Pairs with**: the SEV-2 tab strip + × close bugs in this batch. The common factor is "click rects registered inside the right-panel render path are sometimes dead even when the screen shows the chrome correctly". The session-loaded path being the one that works is the data point that may point at the actual cause.

**Severity rationale**: SEV-3 because (a) the prior `refuted` finding already covers the session-loaded happy path, (b) there's still a typeable fallback (palette → `outline.show`), and (c) once the user opens a panel once and quits, future launches start in scenario A and the click works. But it's a real regression — the discovery surface explicitly invites the click and most users will toggle the panel at runtime, then hit the dead row.
