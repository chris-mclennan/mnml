---
severity: SEV-2
surface: peek_definition_overlay
hunt: vscode-user mixed-input
date: 2026-06-21
---

## [SEV-2] Peek-definition overlay is keyboard-only — mouse clicks pass through to whatever is underneath, never dismiss the overlay, never scroll it

**Reproduction** (code-review confirmed; live trigger requires a working
LSP):
```jsonc
{"cmd":"open","path":"src/main.rs"}
// place cursor on a symbol with a known definition
{"cmd":"run-command","id":"lsp.peek_definition_overlay"}
{"cmd":"wait_ms","ms":1500}
// overlay is now rendered floating over the editor.
{"cmd":"click","col":20,"row":10,"button":"left"}    // click inside the overlay box
// nothing happens to the overlay — the click goes through to the
// editor pane behind it and *places the cursor* on whatever line
// happened to be at row 10 of the *underlying* editor, while the
// overlay continues to render on top.
{"cmd":"click","col":5,"row":35,"button":"left"}     // click outside the overlay
// same — overlay stays. Click hits whatever is under it.
{"cmd":"scroll","col":20,"row":10,"dy":-3}           // try to wheel-scroll inside the overlay
// scrolls the editor under it; the overlay's `po.scroll` never moves.
```

**Expected**: VS Code's Peek Definition (`Alt+F12`) closes on click-outside
(click the editor under the overlay closes it and lands the cursor there)
and is mouse-scrollable inside the box (mouse wheel scrolls the peek
content). Both are reasonable. The overlay's own title bar literally says
`Esc closes` — but a VS Code user reaches for the mouse first.

**Actual**: `src/tui.rs:413-449` handles `peek_overlay` for keyboard only
— `Esc` closes, `Up/Down/j/k/PgUp/PgDn` scroll, any other key drops the
overlay + falls through. The mouse handler in the same file
(`dispatch_mouse` / `dispatch_mouse_event` around line 3280+) never
references `app.peek_overlay`. The overlay is drawn in
`src/ui/mod.rs:584-586` after almost everything else, so it visually
blocks the underlying surface, but click hit-tests run against the rect
table assembled during that frame — which still records the underlying
editor / tree / tabs as the click targets. Net effect: the user sees a
floating box that captures no mouse input. Clicking *inside* the box
mutates the editor underneath; the user only realises after closing the
peek with `Esc`.

**Source pointer**:
- `src/ui/peek_overlay_view.rs:1-72` — renderer registers no rects
- `src/tui.rs:413-449` — keyboard-only modal handler
- `src/tui.rs` (mouse dispatcher) — no `peek_overlay` check before any
  click / scroll / hover branch
- `src/ui/mod.rs:584-586` — drawn last, so visually blocks but isn't a
  click trap

**Notes**: The welcome overlay (`src/tui.rs:3280-3282`) gets this right
("any left-click dismisses + persists the marker"). The completion popup,
the command palette, and the prompt overlay all also have mouse handling.
Peek is the outlier.

Suggested fix shape: before the editor-pane mouse branch, add
`if app.peek_overlay.is_some() { … }` modal arm — left-click inside the
overlay's bounds becomes a no-op (or scrolls + selects a peek line),
left-click outside dismisses, wheel scrolls `po.scroll`. The overlay's
draw routine needs to publish its `Rect` so the dispatcher can hit-test
it.
