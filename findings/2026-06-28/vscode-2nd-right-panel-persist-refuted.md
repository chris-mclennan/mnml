---
agent: vscode-user
severity: SEV-3
verifies: vscode-right-panel-tabs-not-persisted
---

## REFUTED — right-panel hosted tabs ARE persisted and restored across restart

**Reproduction**:
```
# session 1
{"cmd":"key","key":"esc"}
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":300}
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":500}
# status after: rightPanelVisible:true rightPanelPanes:[1,2] rightPanelActiveIdx:1
{"cmd":"quit"}
# session 2 — re-launch headless on same workspace
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
# status after: rightPanelVisible:true rightPanelPanes:[1,2] rightPanelActiveIdx:1
```

The prior report claimed `session.json` only contained `right_panel_visible` and `right_panel_width`. Inspecting the actual on-disk file after the quit shows:

```json
"right_panel_visible": true,
"right_panel_width": 32,
"right_panel_tabs": ["outline", "diagnostics"],
"right_panel_active_idx": 1,
```

On restart, status.json showed `rightPanelPanes:[1,2]` and pane titles `lib.rs ⌥` (outline) + `problems ✓` (diagnostics) — both tabs re-hosted with the active idx (1, the diagnostics tab) restored.

**Source confirmation**: `src/app/session.rs:79-99` (save) and `src/app/session.rs:387-405` (restore) implement the persistence. The save serializes `right_panel_tabs` as a `Vec<String>` of kind names; restore matches "outline" → `open_outline_pane()` and "diagnostics" → `open_diagnostics_pane()`. Tests/Grep are saved as kind strings too but the restore arm only matches outline/diagnostics — by design per the inline comment ("just re-host an empty pane on re-open"). AI is intentionally skipped (live session state isn't worth chasing).

**What the prior agent likely missed**: They appear to have inspected `session.json` in a workspace where the right panel was NEVER populated, or quit before the right_panel_panes vec had a chance to fill. The keys are emitted UNCONDITIONALLY by the save path (the `Some(...)` wrapping is always populated, never `None`), so the absence in the JSON they observed is inconsistent with the current code.
