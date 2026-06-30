---
agent: vscode-user
severity: SEV-3
---

# Settings overlay persists every keystroke to disk; [Save] / [Cancel] semantics are inverted vs VS Code

The new `[Save]` / `[Cancel]` chips at the overlay's bottom-right LOOK like
the VS Code "Save Settings JSON" pattern, but the persist model is the
opposite: every left/right keystroke writes the value to
`<workspace>/.mnml/config.toml` immediately. `[Save]` just dismisses; the
write already happened. `[Cancel]` rolls the file back to the snapshot taken
on open.

This is fine in isolation, but combined with the new chips it's misleading:
a user who tweaks "Cursor line: on" → "Cursor line: off" expecting Save to
commit and Cancel to revert will get the right outcome on Cancel … by
luck, after the workspace config file has been overwritten and reverted.

## Reproduction (the per-key write is observable)

```jsonl
{"cmd":"key","key":"ctrl+shift+p"}
{"cmd":"type","text":"view.settings"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":400}
{"cmd":"key","key":"left"}                  // toggle the focused row
{"cmd":"wait_ms","ms":150}
// In a separate terminal: stat -f %m /tmp/.../.mnml/config.toml
// → mtime updates BEFORE [Save] is clicked.
```

Also:

* `r` reset on a row that was *already at default* writes the default value
  back to the workspace file even though the in-memory state was unchanged
  (verified: workspace `.mnml/config.toml` ends up with
  `relative_line_numbers = false, line_numbers = true` after reset+Save on
  a row that hadn't been touched). Treating "reset" as "set explicitly" is
  surprising; VS Code's reset removes the override entirely.

**Expected**: `[Save]` is the only thing that touches disk; the overlay edits
work on an in-memory clone. `[Cancel]` discards. Default-equal values aren't
written to the workspace file.

**Actual**: persist-per-keystroke + snapshot-restore-on-cancel. The chip
labels don't match the model.

**Source pointer**:
- `src/app/settings.rs:1036-1045` `persist_setting_to_workspace` — called
  from every `apply_setting` path.
- `src/app/settings.rs:988-1003` `close_settings_overlay_save` — only
  persists `default_workspace` (the rest already on disk).
- `src/app/settings.rs:1009-1029` `close_settings_overlay_cancel` —
  restores the snapshot file.

**Notes**: Either rename the chips ("Apply" / "Revert"?) or change the
write model. The chip patch shipped today (commit 7f0fde5) inherited the
older auto-persist model without realizing the new chip labels would
mislead a VS Code reader.
