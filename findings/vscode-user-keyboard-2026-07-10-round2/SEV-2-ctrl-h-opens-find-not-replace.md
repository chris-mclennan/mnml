# SEV-2 — Ctrl+H opens Find, not Replace, on the first invocation

## What I did

1. Focused an editor pane. Pressed `Ctrl+H` — the overlay title bar
   reads "Find", one input box, no replacement field. VS Code opens
   a two-field bar labeled Find + Replace.
2. Typed "println" and pressed `Ctrl+H` a second time — NOW the
   overlay title reads `Replace 1× "println" with`. A working
   replace, but on the second invocation.

The code documents this — `src/app/find.rs:515-534`:

```rust
None => {
    // vscode-user SEV-3 — Ctrl+H used to toast 'find first' and stop.
    // VS Code opens the find bar directly with replace mode active.
    // We don't have a separate 'replace mode' flag, but we can at
    // least open the find prompt for the user so they don't have to
    // hit Ctrl+F separately.
    self.open_find_prompt();
    ...
    self.toast("Ctrl+H: type a find pattern, then Ctrl+H to replace");
}
```

## Why it matters

VS Code parity says one chord opens a two-field bar. mnml's two-step
flow needs the user to press Ctrl+H, type, press Ctrl+H again,
type again, Enter — vs. VS Code's press Ctrl+H, type/Tab/type/Enter.

The chord "does the right thing" eventually but the sequence is
different enough that a keyboard-purist looking to bang out a quick
replace hits a friction wall.

## Suggested fix (not applied)

Add a two-field Replace prompt kind (Find on top row, Replace on
bottom row, Tab to switch) and route Ctrl+H directly to it whether
or not there's an active find state. The existing single-line
prompt idiom already covers the typing surface — only the layout
needs a second row.

## Severity

SEV-2 — chord fires wrong overlay on the first invocation; second
invocation reaches the right one.
