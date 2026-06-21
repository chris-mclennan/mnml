---
severity: SEV-3
surface: diagnostics pane (Problems)
hunt: vscode-user mixed-input
date: 2026-06-21
---

## [SEV-3] Diagnostics severity filter is keyboard-only — the "filter: <label>" chip is plain text, not clickable

**Reproduction**:
```jsonc
{"cmd":"key","key":"esc"}
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":600}
{"cmd":"snapshot"}
// When the pane has items, the second header row reads:
//   "  filter: All (3/3)  ·  `s` cycles severity"
// Click on the text "filter: All" or "All" or the
// "(3/3)" count chip — nothing happens.
{"cmd":"click","col":15,"row":4,"button":"left"}
{"cmd":"snapshot"}                                   // filter is unchanged
```

**Expected**: VS Code's Problems panel exposes the Errors / Warnings /
Info / Hints toggles as clickable chips in the panel header. The text
hint `\`s\` cycles severity` is great keyboard discoverability, but the
visible label "filter: All" reads as a chip — a mouse user reaches for it.

**Actual**: `src/ui/diagnostics_view.rs:99-109` renders the filter chip as
a plain `Paragraph` line. No `app.rects.<…>` registration, no hit-test
ever runs against it. The only path to cycle the filter is the bare `s`
keystroke wired in `src/tui.rs` (`Diagnostics` arm). A mouse user has to
reach for the keyboard, hit `s`, watch the label cycle. Right-click
context menu on the chip doesn't exist either.

The same pattern applies to the count chip "(3/3)" — visually a chip, but
not clickable.

**Source pointer**:
- `src/ui/diagnostics_view.rs:99-109` — chip renderer (text-only)
- `src/lsp/diagnostics_pane.rs:121-128` — `cycle_severity_filter()` body,
  not exposed via mouse
- `src/tui.rs` (Diagnostics key arm) — only `KeyCode::Char('s')` triggers
  it

**Notes**: Low-stakes (keyboard works, the hint is right there), but the
pattern leaks into how confident a mouse user feels about the rest of the
pane. If chip-looking text isn't clickable here, where else? See the
companion finding on the Websocket pane.

Suggested fix shape: add `app.rects.diagnostics_filter_chip: Option<Rect>`,
register from the renderer, hit-test in the mouse dispatcher's editor-pane
arm. Left-click cycles forward, right-click cycles back. Same wiring for
a "(N/M)" reset-to-all chip.
