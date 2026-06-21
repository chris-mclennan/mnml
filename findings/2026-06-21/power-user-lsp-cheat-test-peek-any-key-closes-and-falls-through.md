---
finding: peek-any-key-closes-and-falls-through
severity: SEV-2
agent: power-user-lsp-cheat-test
repro: code-review
---

# Peek overlay fall-through executes any non-navigation keystroke against the editor

## Surface

`src/tui.rs:413-449` — the peek overlay's key handler (commit `883fd62`).

## What happens

Inside the `app.peek_overlay.is_some()` block:

- `Esc` closes and `return`s.
- `Up`/`Down`/`k`/`j`/`PageUp`/`PageDown` scroll and `return`.
- The catch-all `_` arm runs `app.peek_overlay = None;` and DOES NOT
  `return` (line 447):

```rust
_ => app.peek_overlay = None, // fall through
```

So any non-navigation keystroke (e.g. `gd`, `:`, `i`, `c`, `dd`,
`o`, `x`, …) closes the overlay AND THEN gets dispatched against
the underlying editor. From the user's perspective they pressed
ONE key but TWO things happened: the overlay vanished, and the
editor's cursor moved / entered insert mode / changed a character.

## Why it matters

The standard VS Code peek-overlay behavior is "Esc closes, anything
else is for the overlay". mnml's design is "Esc closes, navigation
scrolls, anything else closes-then-runs". That's a real choice — it
makes the overlay feel transient — but it has at least two sharp
edges:

1. Vim-mode user opens peek, then types `x` to dismiss it (assuming
   any key dismisses, as the comment promises). `x` is also `delete
   char under cursor` in vim mode. Result: overlay closes, character
   under cursor is deleted, file becomes dirty. *Surprising delete*.

2. `gd` is the chord to invoke goto-def. If the user opens peek by
   accident and presses `gd` to "go define instead", peek closes,
   the `g` enters partial chord state, and the `d` finishes a chord
   that may not be `goto-def` (e.g. `gd` may not be the bound chord —
   `gd` is followed by `g` for `gg` etc).

## Repro

Code-review finding. Easy to demonstrate manually:

1. Open any file in vim mode.
2. Position cursor on a character.
3. Invoke `:lsp.peek_definition_overlay` (fails to open if no LSP;
   to test the fall-through, manually set `app.peek_overlay` from
   a fake unit test instead).
4. Press `x`. Observe: overlay closes AND the char is deleted.

## Suggested fix

Pick one of:

- **Strict modal** (recommended for VS Code parity): change the `_`
  arm to `_ => { return; }` — overlay-up state swallows all other keys.
- **Esc-only close**: replace the `_ => app.peek_overlay = None`
  with `_ => return` (same as above; phrased differently).
- **Explicit fall-through**: keep the current behavior but ONLY for
  keys that match a documented allowlist (e.g. `:`, `/`, `Ctrl+P`).
  Bare letter keys should not close-and-execute.

If the design choice is genuinely "any key closes and falls through",
the discoverability of that needs work — the title bar currently
only says `Esc closes`.
