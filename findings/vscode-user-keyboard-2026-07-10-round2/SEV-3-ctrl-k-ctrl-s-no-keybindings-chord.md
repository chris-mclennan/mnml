# SEV-3 — Ctrl+K Ctrl+S doesn't open a keybindings editor

## What I did

Pressed `Ctrl+K Ctrl+S` (VS Code's "Keyboard Shortcuts" chord). What
mnml did:

1. Ctrl+K opened the whichkey leader overlay.
2. Ctrl+S was fed to the overlay as the character `s` (since the
   chord chain code at `src/tui/mod.rs:1950-1955` extracts the
   `KeyCode::Char(c)` from the modifier-stripped chord).
3. That routed into `<leader>s` = the `+split` submenu.

So the chord opens a *split* submenu, not a keybindings editor.

The command `keys.edit` at `src/command.rs:2147-2152` opens
`config.toml` at `[keys.standard]` — the closest thing mnml has to
a keybindings UI. It has `keys: &[]`, i.e., palette-only.

## Why it matters

VS Code users hit `Ctrl+K Ctrl+S` reflexively to look up "what chord
is bound to X". mnml has three things a user might mean:
`keys.edit` (raw TOML editor), the cheatsheet pane, and the
whichkey overlay. None land under the VS Code muscle-memory chord.

## Suggested fix (not applied)

Bind `keys.edit` (or a new `keys.cheatsheet` command that opens a
searchable cheatsheet pane) to `Ctrl+K Ctrl+S`. Also consider
`Ctrl+K Ctrl+R` for the raw TOML editor if the cheatsheet is the
primary landing.

## Severity

SEV-3 — chord silently opens the wrong thing (a split menu). No
crash, palette reaches every command.
