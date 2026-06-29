---
agent: vscode-user-mouse
severity: SEV-3
---

## SEV-3 `right_panel_empty_outline` / `right_panel_empty_diagnostics` rects not exported to `rects.json` — audit tools blind to two registered click targets

**Reproduction**:
```jsonl
# pre-set session.json with right_panel_visible: true
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```
After: `rects.json` contains `right_panel_edge`, `right_panel_close` (or omitted when empty-state), `right_panel_tab:N` (only when hosted) — but never `right_panel_empty_outline` or `right_panel_empty_diagnostics`, even when the screen clearly shows the ":outline.show" / ":lsp.diagnostics" rows and `src/ui/mod.rs:902-913` has populated both fields on `app.rects`.

**Source pointer**: `src/ipc/mod.rs:929-1080` (the `rects_dump_json` function) calls `one!()` for many `Option<Rect>` fields including `right_panel_edge` and `right_panel_close`, but skips the two empty-state rects. The struct fields exist (`src/app/mod.rs:1625-1627`); the click handler reads them (`src/tui/mouse.rs:1394-1405`); only the JSON dump omits them.

**Expected**: Every registered click rect that powers a user-visible action gets serialized so audit harnesses + the existing test toolkit can verify it's painted in the right place. The 2026-06-19 click-rect-audit comment in `rects_dump_json` says "the ones most likely to be subject to the same chip-overlap bug pattern that motivated the audit toolkit" — these two rects are EXACTLY that pattern (newly-added v3-polish click targets that ship without test coverage).

**Actual**: Two click rects are invisible to the audit dump. This made the prior agent's "the row→command mapping is off-by-one or swapped" finding (since refuted) take longer to investigate; same gap will haunt future hunts.

**Severity rationale**: SEV-3 — not a user-facing bug, but it's a test-coverage / debuggability gap that has already caused at least one false-positive bug report (`vscode-empty-state-row-misroutes.md` → `vscode-2nd-empty-state-click-refuted.md`).

**Suggested fix**: Add `one!("right_panel_empty_outline", app.rects.right_panel_empty_outline);` and the same for `_diagnostics` near line 962 in `src/ipc/mod.rs`. ~6 lines.
