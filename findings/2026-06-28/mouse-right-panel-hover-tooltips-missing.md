---
agent: vscode-user-mouse
severity: SEV-3
---

## SEV-3 Hover tooltips never render over right-panel tabs or × button

**Reproduction (inactive tab)**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":500}
{"cmd":"hover","col":133,"row":1}        # over Outline tab (inactive)
{"cmd":"wait_ms","ms":1500}
{"cmd":"snapshot"}
```
Screen shows no tooltip overlay. The 1500ms wait is 3× the 500ms `HOVER_TOOLTIP_DELAY_MS` threshold + a paint cycle, so timing isn't the issue.

**Reproduction (× close button)**:
```jsonl
# (same setup, then)
{"cmd":"hover","col":158,"row":1}
{"cmd":"wait_ms","ms":1500}
{"cmd":"snapshot"}
```
Same — no tooltip overlay.

**Sanity check (same harness, different chip)**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"hover","col":80,"row":0}
{"cmd":"wait_ms","ms":800}
{"cmd":"snapshot"}
# screen renders:
#   ┌─────────────────────────────────────────────┐
#   │ command palette                             │
#   │ click: open files, commands, recent (Cmd+P) │
#   └─────────────────────────────────────────────┘
```
…tooltips work in general — only the right-panel chrome doesn't get them.

**Source check**: `src/app/dispatch.rs:458-472` has the hover-chip detection wired for `RightPanelTab(pid)` and `RightPanelClose`. `src/ui/tooltip.rs:312-340` has the `describe()` arms for both with distinct active/inactive copy ("click: switch · ×: close · right-click: menu" vs "click: switch tab · right-click: switch/close"). Code looks correct. Most likely cause: `hover_chip` isn't being set because `hover_chip_at` returns `None` at the test coords, OR `describe()` returns `None` (e.g. because the `?` short-circuits via `right_panel_panes.position(&pid)` or `right_panel_tabs.find(idx)`).

**Pairs with**: SEV-2 tab strip + × close click bugs. Strongly suggests the right-panel chrome rects are getting clobbered or never set in some render path.

**Expected**: 500ms+ hover over any right-panel chip surfaces a tooltip with active/inactive-specific copy (the copy is in the source, just dead).

**Actual**: Mouse-only users get no feedback explaining what each tab / × does.

**Severity rationale**: SEV-3 — tooltip is discovery polish, not a blocker. But combined with the SEV-2 click bugs, the right panel is doubly inscrutable: clicks dead AND tooltips missing.
