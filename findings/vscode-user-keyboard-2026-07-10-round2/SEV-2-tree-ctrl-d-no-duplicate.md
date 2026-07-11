# SEV-2 — Tree focus Ctrl+D never fires file.duplicate

## What I did

Focused the tree with `Ctrl+Shift+E`, navigated onto `src/lib.rs` with
arrow keys, then pressed `Ctrl+D`. Expected the VS Code "Duplicate"
gesture that `src/tui/handlers/pane.rs:110-113` claims to wire up:

```rust
KeyCode::Char('d') => {
    crate::command::run("file.duplicate", app);
    return;
}
```

Confirmed (via `ls`) that no `lib-copy.rs` was created. Ran the same
test on `notes.txt` — no `notes-copy.txt`. Ctrl+X (`cut`) and Ctrl+C
(`copied README.md`) toast messages *do* appear when the same
sequence is used, so the tree focus handler is otherwise wired.

## Root cause

`src/command.rs:841` registers a global keymap binding:

```rust
Command {
    id: "editor.add_cursor_at_next_word",
    keys: &["ctrl+d"],
    ...
}
```

`dispatch_chord_chain` in `src/tui/chord.rs:36` runs BEFORE
`handle_tree_key` (see `src/tui/mod.rs:1946`). When the keymap
resolves the chord to a registered command (any focus), the chain
consumes the key and returns `true`, so the tree handler never
sees Ctrl+D. Ctrl+X/C/V don't hit this pitfall because they're
handled inside the standard-input `InputResult` layer, which
`handle_pane_key` only reaches for pane focus — tree focus never
hits that layer either, so the tree branch fires.

## Why it matters

CLAUDE.md's Status block explicitly promises "Ctrl+X/C/V/D fire in
tree focus". The design-critic hunt saw the empty `keys: &[]` on
`file.duplicate` and flagged it. This finding proves the runtime
symptom that the design-critic could not: a keyboard-purist user
hits Ctrl+D on a file, expects a copy, gets a silent no-op (with a
subtle side-effect that the AddCursorAtNextWord op fires against
whatever editor was previously active).

## Suggested fix (not applied)

Give `file.duplicate` an explicit focus-gate in the keymap layer, or
add a focus check at the top of `dispatch_chord_chain` that skips
the global keymap when Focus == Tree AND the chord is one of the
file-manager verbs. Simplest: make the global Ctrl+D binding conditional
on Focus == Pane.

## Severity

SEV-2 — no crash, but a documented chord silently misfires.
