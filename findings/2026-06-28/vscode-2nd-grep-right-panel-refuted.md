---
agent: vscode-user
severity: SEV-3
verifies: vscode-grep-skips-right-panel
---

## REFUTED — find.grep DOES route into the right panel when visible

**Reproduction**:
```
{"cmd":"key","key":"esc"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"find.grep"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":"helper"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":2000}
{"cmd":"snapshot"}
```

Status after the snapshot:
```json
"rightPanelVisible": true,
"rightPanelPanes": [0],
"rightPanelActiveIdx": 0,
"panes": [{"title": "grep:helper (1987)", "dirty": false}]
```

The grep pane was created and inserted into `right_panel_panes` exactly as `src/app/grep.rs:166-170` declares. No editor-body split occurred (the only pane in `app.panes` is the grep pane itself; if it had split the editor, there would be an editor pane too).

**What the prior agent likely missed**: I cannot reproduce the failure they described. The exact same JSONL sequence they pasted produces a hosted grep tab. Possible explanations:
- A stale build of the binary (the prior run was before commit `35ee68c` finished compiling / propagated).
- Right panel was hidden between toggle and grep due to some preceding state (e.g. session.json restored `right_panel_visible=false` from a prior run).
- Misread of `status.json` (the prior report quoted `"panes":[{"title":"grep:fn helper (2)"...}]` which would indicate the grep pane was created but the right-panel slice was empty; the snapshot I captured does NOT exhibit that condition).

**Source confirmation**: `src/app/grep.rs:166-170`:
```rust
if self.right_panel_visible {
    self.panes.push(pane);
    let new_id = self.panes.len() - 1;
    self.right_panel_push(new_id);
    return;
}
```
runs as written. Verified the `rightPanelPanes` field in the dumped status reflects the push.
