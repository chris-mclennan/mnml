# SEV-2 — outline / diagnostics / grep / AI / tests in right panel have no chord

## What I did

Opened the right panel (`Ctrl+Shift+B`). Empty state shows five
suggested hosted panes as clickable rows:

```
▸ Outline  :outline.show
▸ Problems  :lsp.diagnostics
▸ AI chat  :ai.chat
▸ Grep  :find.grep
▸ Tests  :test.run
```

Each row is a mouse target. Tried each of the VS Code chords a
keyboard user would reflexively hit:

- `Ctrl+Shift+O` — mnml routes to `editor.symbol_search` (not the
  outline panel).
- `Ctrl+Shift+M` — no binding. (VS Code = Problems view.)
- `Ctrl+Shift+F` — routes to `find.grep` (this one *does* work,
  but it opens a grep pane, not a right-panel hosted grep).

Checked the registrations:

- `src/command.rs:3756` `outline.show` — `keys: &[]`.
- `src/command.rs:3460` `lsp.diagnostics` — `keys: &[]`.
- `src/command.rs:3762` `lsp.next_diagnostic` — bound elsewhere.

## Why it matters

The right panel is a full feature surface that a keyboard-purist can
only reach through:

1. `Ctrl+Shift+P` → search each command.
2. `Ctrl+K r` (whichkey `<leader>r`, but that toggles the panel
   itself, not populates it).

That's two levels of indirection for a top-of-mind action (open the
project's problems list) that VS Code covers in one chord.

## Suggested fix (not applied)

- `outline.show` → `Ctrl+Shift+O`
- `lsp.diagnostics` → `Ctrl+Shift+M`
- `ai.chat` → some `Ctrl+Alt+A` variant
- `test.run` — VS Code's task chord is `Ctrl+Shift+B`, already
  in use; consider `Ctrl+Shift+T`.

At minimum add whichkey entries under `<leader>r` for
outline/problems/AI/grep/tests so `Ctrl+K r o` reaches Outline.

## Severity

SEV-2 — no keyboard chord to a first-class panel; palette works
but is not the "hands on keys" experience the right panel invites.
