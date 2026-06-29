---
agent: vscode-user
severity: SEV-2
---

## SEV-2 Right-panel hosted-tab list (`right_panel_panes`) not persisted to `session.json` — restart drops Outline + Diagnostics

**Reproduction**:
```
// session 1
{"cmd":"open","path":"src/lib.rs"}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":300}
// status shows rightPanelPanes=[2,3] (outline + diagnostics)
{"cmd":"quit"}
// session 2 — relaunch headless on same workspace, dismiss welcome, snapshot
// status shows rightPanelVisible=true, rightPanelPanes=[]
```

After quit, inspecting `<ws>/.mnml/session.json` shows only `right_panel_visible` and `right_panel_width` keys — no record of which panes were hosted, in what order, or which was active:
```json
"right_panel_visible": true,
"right_panel_width": 32,
```

**Expected**: Per the task description ("session persistence (restart restores Outline + Diagnostics tabs)"), the right-panel hosted pane list and active index should be persisted to `session.json` and restored on next launch — so a Ctrl+B-style "I always have outline + problems pinned to the right column" workflow survives a restart.

**Actual**: Restart loses the right-panel tabs. Right panel comes back visible (good — the visibility bit is persisted) but empty, with the same `:outline.show / :lsp.diagnostics` empty-state hint that a fresh-install user sees. The user has to re-open every hosted tab manually.

**Source pointer**: `session.json` is written by something around `src/session.rs` (or `src/app/session_methods.rs` if split). The serialization of `App` -> session presumably emits `right_panel_visible` + `right_panel_width` but skips `right_panel_panes` and `right_panel_active_idx`. The restore path on relaunch would need to know how to re-construct the underlying panes (outline tied to a buffer path, diagnostics global, ai chat with a session id, etc.) — non-trivial but the task description claims it's done.

**Notes**: Coupled with the v5 work and the FIFO toast logic landing 2026-06-28, this should have been part of the same commit cluster. The asymmetry — width persists, content doesn't — feels worse than not persisting either: the user opens a fresh mnml and sees an empty 32-cell column reserved for content that's no longer there.
