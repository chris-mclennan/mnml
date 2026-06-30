---
agent: vscode-user
severity: SEV-2
---

# Bufferline overflow chevrons (`‹` / `›`) are effectively non-functional

The chevron click handler decrements/increments `bufferline_first_visible`,
but the very next render frame in `src/ui/bufferline.rs:180-200` immediately
auto-corrects the value so the active tab stays visible. Net effect: clicking
‹ or › does nothing visible whenever the active tab lives inside the currently
rendered window (the common case).

## Reproduction

```jsonl
{"cmd":"open","path":"main.rs"}
{"cmd":"open","path":"hello.py"}
{"cmd":"open","path":"app.js"}
{"cmd":"open","path":"notes.md"}
{"cmd":"open","path":"config.toml"}
{"cmd":"open","path":"mnml.out"}
{"cmd":"snapshot"}
// Bufferline shows: ‹ hello.py | app.js | notes.md | config.toml | mnml.out
// main.rs is overflowed (offscreen left); active = mnml.out (last)
{"cmd":"click","col":30,"row":1,"button":"left"}
{"cmd":"wait_ms","ms":250}
{"cmd":"snapshot"}
// Bufferline strip identical — main.rs NOT revealed
```

Same behavior on `›` after switching active to main.rs (Ctrl+P) and clicking the
right chevron — no scroll.

**Expected (VS Code parity)**: clicking the chevron scrolls the tab strip by one
in the chosen direction, even if it pushes the active tab offscreen. The chevron
is the user's explicit "I want to see the other tabs" signal.

**Actual**: chevron click increments/decrements the scroll offset, then the
render guard at `src/ui/bufferline.rs:198-200` clamps it back so the active
tab remains in view. The strip never visibly moves while the user keeps clicking.

**Source pointer**: `src/ui/bufferline.rs:170-201` (auto-clamp on every render);
`src/tui/mouse/down_left.rs:461-476` (chevron handler does the right thing in
isolation but is undone before paint).

**Notes**: rects.json correctly registers `bufferline_overflow_left/right`;
the click events log fine, the state mutation just never makes it onto the
screen. Easy way out: skip the auto-clamp once `bufferline_first_visible`
was set by an explicit chevron click in the current frame, OR honor the
manual offset until the user switches tabs.
