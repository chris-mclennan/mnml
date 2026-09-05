---
severity: SEV-3
status: open
---

# `git.worktree_add` path prompt has no filesystem-path autocomplete

## Summary

The `git.worktree_add` prompt (`Worktree: <path> [new-branch]`) is a plain
text field — typing a real, unambiguous directory prefix like
`~/Projects/mn` (which matches `~/Projects/mnml`, `mnml-zig`,
`mnml-hello`, all of which exist on disk) never shows any suggestion
dropdown or ghost-text completion. Pressing `Tab` does nothing either (no
insertion, no list). The field's other affordances are fine — cursor
movement, backspace, left/right-arrow editing all work correctly — this is
specifically about the absence of path completion, which the task brief
flagged as worth checking.

This doesn't block the flow (typing the full correct path still works and
the command otherwise behaves reasonably), so it's a discoverability/
convenience gap rather than a functional break.

## Repro (verified twice)

```json
{"cmd":"run-command","id":"git.worktree_add"}
{"cmd":"wait_ms","ms":300}
{"cmd":"type","text":"~/Projects/mn"}
{"cmd":"wait_ms","ms":400}
{"cmd":"snapshot"}
```

`screen.txt`:
```
╭ Worktree: <path> [new-branch] ───────────────────────────╮
│ ~/Projects/mn                                             │
│  enter to submit · esc to cancel                          │
╰──────────────────────────────────────────────────────────╯
```
No dropdown/suggestion list anywhere on screen despite three matching
directories existing (`~/Projects/mnml`, `~/Projects/mnml-zig`,
`~/Projects/mnml-hello`). `Tab` produces no change either. Reproduced
identically in a second, fresh launch.

Basic field affordances confirmed working in the same session:
`backspace`/`left`/typing mid-string all edit correctly (per the project's
"overlay text-field affordances" convention) — only path-specific
autocomplete is missing.

## Expected vs actual

- Expected (per task brief's explicit ask): typing a partial path under
  `~/Projects/` surfaces existing directory matches.
- Actual: plain text entry only, no completion of any kind.

## Command id

`git.worktree_add`
