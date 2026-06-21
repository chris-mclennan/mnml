---
finding: cheatsheet-Z-resets-selection
severity: SEV-3
agent: power-user-lsp-cheat-test
repro: code-review
---

# Cheatsheet `z`/`Z`/expand/collapse always reset `selected`/`scroll` to 0 — loses cursor position

## Surface

`src/cheatsheet.rs::toggle_collapsed_at_selection / collapse_all / expand_all`
(commit `1346dba`).

## What happens

All three methods unconditionally do:

```rust
self.selected = 0;
self.scroll = 0;
```

So if the user is at row 47 of the cheatsheet, presses `z` to fold
the section they're hovering, the cursor jumps back to row 0. To
keep browsing, they have to `j`-spam back down or `/` to find what
they were near.

This is uncharacteristic for fold UIs — usually toggling a section
keeps the cursor on the section header (so re-pressing `z` toggles
the same section back). Even simpler: keep the cursor on a
neighboring row.

## Why it matters

It's a quality-of-life thing, but cheatsheets are explicitly browsed
("scroll until I find what I want, fold uninteresting sections to
make the list shorter"). Resetting on every fold makes "fold as you
explore" actively counter-productive.

## Repro

Code-review finding; reproducible manually:

1. `:view.cheatsheet`
2. `j`-scroll down to a row in the middle of the list.
3. Press `z`.
4. Cursor jumps back to row 0.

## Suggested fix

In `toggle_collapsed_at_selection`: leave `selected`/`scroll`
untouched, then clamp post-toggle to `visible_row_count() - 1` so
the cursor doesn't fall off the end (this happens when collapsing
a section under the cursor — the rows it owned vanish).

For `collapse_all`/`expand_all`: same — instead of `selected = 0`,
remember which section the cursor was in (`selected_group()` before
the toggle) and place the cursor on that section's header (or, if
the section was expanded and now collapsed, on the row immediately
below the now-empty header).
