---
agent: vscode-user
severity: SEV-2
---

## SEV-2 `find.grep` results never host into the right panel even when visible (v5 grep-as-tab broken)

**Reproduction**:
```
{"cmd":"key","key":"esc"}
{"cmd":"run-command","id":"view.toggle_right_panel"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"find.grep"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":"fn helper"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":2000}
{"cmd":"snapshot"}
```

Then read `.mnml/ipc/status.json`:
```json
"rightPanelVisible": true,
"rightPanelPanes": [],
"panes": [{"title":"grep:fn helper (2)", ...}]
```

**Expected**: Per the task description's v5 list and `src/app/grep.rs:166-170`:
```rust
if self.right_panel_visible {
    self.panes.push(pane);
    let new_id = self.panes.len() - 1;
    self.right_panel_push(new_id);
    return;
}
```
the grep pane should be appended to `right_panel_panes` and made the active right-panel tab. Compare `ai.ask` (`src/app/ai.rs:1102-1106`) which does the same thing — and *does* host into the right panel correctly under identical state.

**Actual**: The grep `Pane::Grep` is pushed into `app.panes`, but `right_panel_push` is apparently not called (or its push is later undone). `rightPanelPanes` stays empty; the grep pane ends up rendered in the editor body as a split, not in the right panel. Tried via the `find.grep` palette command and via the `run-command` IPC — same result. Repro is deterministic across fresh sessions.

A subsequent `find.grep` call falls into the "already showing a grep pane" branch (`src/app/grep.rs:149`) and refreshes in place, but the `reveal_pane` fallback still doesn't move it into the right panel even though the right panel is visible.

**Source pointer**: `src/app/grep.rs:130-171` `run_workspace_grep` — the `if self.right_panel_visible` branch is taken in the source but the post-state doesn't match. Either `right_panel_push` is being unwound by a later code path, or `self.right_panel_visible` is being flipped between the check and the push. Possibly related to the `Pane::Grep` being created while a prompt is active. The companion `find.grep_replace` re-open path on line 154 also lacks symmetric right-panel push handling.

**Notes**: This is one of the three v5 hosted-pane types the task description explicitly called out ("Outline / Diagnostics / AI / Tests / Grep as tabs"). Outline + Diagnostics + AI all route correctly; grep is the odd one out. Tests pane was not exercised here because there is no `tests.show` command in the registry (it may be tucked under `cargo.test` etc., but no documented right-panel hosting path).
