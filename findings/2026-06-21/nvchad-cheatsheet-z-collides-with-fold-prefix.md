---
finding: nvchad-cheatsheet-z-collides-with-fold-prefix
severity: SEV-2
agent: nvchad-power-user
repro: headless-ipc
---

# Cheatsheet's `z`/`Z` collapse chords half-fire when a vim user types `zc` / `zo` / `za`

`src/tui.rs:2134-2147` — the Cheatsheet pane binds bare `z`
(toggle collapsed-at-cursor) and bare `Z` (collapse-all OR
expand-all depending on state). Vim's `z` is the **fold prefix**
— `zc` close, `zo` open, `za` toggle, `zR` open all, `zM` close
all. A NvChad user inside the Cheatsheet who reaches for `zc` /
`zo` / `za` fires the bare-`z` collapse on the first keystroke,
and the second key (`c`/`o`/`a`) is silently swallowed (no arm).

## Reproduction

```jsonc
{"cmd":"run-command","id":"view.cheatsheet"}
{"cmd":"wait_ms","ms":300}
{"cmd":"key","key":"z"}                          // collapses 'ai' section
{"cmd":"key","key":"c"}                          // silently swallowed
{"cmd":"snapshot"}
```

**Expected** (vim user): two-keystroke chord `zc` either closes a
fold or is a no-op (because cheatsheet has no folds). Typing `zo`
then expecting "open fold at cursor" should be inert.

**Actual**: `z` immediately collapses the highlighted section.
The follow-up `c` does nothing visible. The user wonders why their
fold chord half-worked.

Even worse for `Z` (vim `ZZ` is "save and quit"):

```jsonc
{"cmd":"key","key":"Z"}                          // toggles collapse-all
{"cmd":"key","key":"Z"}                          // toggles back
```

A vim user typing `ZZ` to save+quit (which works perfectly in the
editor — `src/input/vim.rs:931`) hits the cheatsheet's
`Z`-toggles-all twice, ending up exactly where they started, and
their session was never saved/closed. (Cheatsheet has no buffer
to save, but the muscle-memory failure mode is identical: type
the chord, get nothing.)

## Source pointer

`src/tui.rs:2134-2147`:

```rust
KeyCode::Char('z') => {
    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
        c.toggle_collapsed_at_selection();
    }
}
KeyCode::Char('Z') => {
    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
        if c.collapsed.is_empty() {
            c.collapse_all();
        } else {
            c.expand_all();
        }
    }
}
```

## Notes

- Vim's `z` prefix tradition is older than the cheatsheet pane;
  picking `z` for a section toggle was always going to step on it.
- Two adjacent findings under the same hunt
  (`power-user-lsp-cheat-test-cheatsheet-Z-asymmetry-after-single-collapse.md`
  and `…cheatsheet-Z-resets-selection.md`) already document Z's
  state-machine quirks; this finding is the orthogonal "vim chord
  collision" angle.
- A clean fix: bind `<Space>` for section-toggle (the cheatsheet
  has no other use for Space), and leave `z`/`Z` untouched. Or
  require a leader (`<leader>z`) for the section toggles.
