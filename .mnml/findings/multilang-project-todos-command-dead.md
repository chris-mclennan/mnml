---
severity: SEV-2
status: open
---

# `project.todos` command is a dead stub ("not implemented yet") — real feature lives at `view.activity_todos`

## Summary

`docs/commands.md` lists `project.todos` as "Project: scan for TODO / FIXME
/ HACK / XXX comments", reachable from the palette. Running it produces a
toast: **`project.todos: not implemented yet`**. The TODOS-scan feature
itself is fully implemented and works well — it's just bound to a
different command id, `view.activity_todos` ("Activity: show TODOs
(TODO/FIXME/XXX/HACK/REVIEW markers)"), which correctly opens a live
`TODOS (N)` panel that scans the whole workspace (including across the
Python + TypeScript sub-projects), finds `TODO`/`FIXME` comments and even
`@pytest.mark.skip(reason=...)` markers.

A palette user typing "todo" and picking the command literally named
`project.todos` gets told the feature doesn't exist, when it does — under
a differently-named command. `project.next_todo` / `project.prev_todo`
(cursor-jump navigation) also work correctly and independently confirm the
scan data exists; only the panel-opening command `project.todos` is dead.

## Repro (verified twice, same session)

Workspace: `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt-py`
(planted `TODO`/`FIXME` comments in `pkgapp/util.py`, `pkgapp/shapes.py`,
`ts-app/src/types.ts`, `ts-app/src/util.ts`, plus a
`@pytest.mark.skip(reason=...)` in `tests/test_shapes.py`).

```json
{"cmd":"run-command","id":"project.todos"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

`screen.txt`:
```
                                                  ╭────────────────────────────────────╮
                                                  │ project.todos: not implemented yet │
                                                  ╰────────────────────────────────────╯
```

Reproduced a second time later in the same session (fresh toast, identical
text).

Contrast — the actually-working command:

```json
{"cmd":"run-command","id":"view.activity_todos"}
```
→ opens `TODOS (6)` panel: correctly lists all 6 planted markers across
both the Python and TypeScript sub-trees, including the pytest skip
marker's reason string as the row title.

## Expected vs actual

- Expected: `project.todos` opens the TODOS scan panel (same as
  `view.activity_todos`), or is removed from `commands.md` / the palette if
  intentionally superseded.
- Actual: fires a permanent "not implemented yet" toast; the working
  command has a different, non-obvious id.

## Command id

`project.todos` (dead); working equivalent is `view.activity_todos`
