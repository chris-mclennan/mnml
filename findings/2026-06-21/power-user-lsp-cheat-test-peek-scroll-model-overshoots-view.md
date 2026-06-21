---
finding: peek-scroll-model-overshoots-view
severity: SEV-3
agent: power-user-lsp-cheat-test
repro: code-review
---

# Peek-overlay scroll model can advance past the visible cap, making scroll-back feel unresponsive

## Surface

`src/peek_overlay.rs::scroll_down` + `src/ui/peek_overlay_view.rs:46`
(commit `883fd62`).

## What happens

The model bumps `po.scroll` until it reaches `lines.len() - 1`
(`scroll_down`, line 67):

```rust
if self.scroll + 1 < self.lines.len() { self.scroll += 1; }
```

But the renderer caps the effective scroll at `lines.len() - body_h`
(line 46):

```rust
let scroll = po.scroll.min(po.lines.len().saturating_sub(body_h.max(1)));
```

So if the overlay shows body_h = 10 lines and we have 15 lines, the
last useful scroll is 5 — but the model lets `po.scroll` walk to 14.
After 14 presses of `j`, the visible content has been frozen for the
last 9 presses; pressing `k` once doesn't visibly do anything (model
drops 14 → 13, but view-clamped both are 5). The user has to press
`k` 9 times before the scroll starts moving back.

## Why it matters

Per-feature it's small. But it's the same anti-pattern that bit the
hover popup, and it'd be cheaper to fix once. The overlay is supposed
to feel snappy ("press j once, scroll moves once").

## Repro

Hard via .test (no public peek_overlay_view RENDERED scroll API),
but code-review clear:

1. Open a peek overlay that loads 15 lines of source.
2. Press `j` enough times to exceed the cap.
3. Press `k` once — visible content doesn't move.

## Suggested fix

Make `scroll_down` aware of `body_h`. Pass body_h in (or store
last-rendered viewport height on the overlay) and clamp `scroll` to
`lines.len() - body_h` instead of `lines.len() - 1`. The renderer's
extra `.min(...)` then becomes a no-op.
