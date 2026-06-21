---
finding: peek-gutter-line-number-on-out-of-range-anchor
severity: SEV-3
agent: power-user-lsp-cheat-test
repro: code-review
---

# Peek-overlay gutter shows nonsense line numbers when LSP returns out-of-range anchor

## Surface

`src/peek_overlay.rs::PeekOverlay::load` + `src/ui/peek_overlay_view.rs`
(commit `883fd62`).

## What happens

`PeekOverlay::load` clamps an out-of-range `anchor_line` to
`total.len()-1` (line 37):

```rust
let anchor = (anchor_line as usize).min(total.len().saturating_sub(1));
```

…but stores the ORIGINAL `anchor_line` in `self.anchor_line` (line 42).
The renderer at `src/ui/peek_overlay_view.rs:59` builds the gutter line
number from the *original* anchor:

```rust
let line_num = po.anchor_line as usize + i - po.highlight_idx + 1;
```

So if LSP returns `anchor_line = 1000` for a 10-line file (clamped
internally to 9), the gutter prints line numbers like 994..1001 next
to lines that are actually 3..10 of the file. The title bar similarly
shows `path · line 1001` instead of `path · line 10`.

## Why it matters

- A stale `.rs.bk` file that LSP indexed once but has since shrunk.
- A workspace file that was rewritten externally between LSP's
  indexing pass and the user's peek (very common with code-gen).
- An LSP that returns 1-based vs 0-based positions inconsistently
  — rust-analyzer is good here but the wider ecosystem isn't.

The overlay LOOKS authoritative; a wildly wrong gutter undermines
that trust.

## Repro

Hard to trigger end-to-end without a stale-LSP setup. Code-review
finding — `PeekOverlay::load` stores `anchor_line` pre-clamp, and
the renderer dereferences it.

## Suggested fix

Store the clamped anchor in `self.anchor_line`:

```rust
let anchor = (anchor_line as usize).min(total.len().saturating_sub(1));
// ...
Some(PeekOverlay {
    path,
    anchor_line: anchor as u32, // store the clamped value
    ...
})
```

Or compute line numbers from `start` (already a local in `load`) and
store `start_line` on the struct instead. The renderer's `start_line + i + 1`
is simpler than `anchor + i - highlight_idx + 1`.
