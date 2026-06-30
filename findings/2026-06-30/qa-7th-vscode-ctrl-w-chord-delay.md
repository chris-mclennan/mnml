---
agent: vscode-user
severity: SEV-2
---

# Ctrl+W in standard mode stalls 1000ms before closing the tab

In standard input mode, `Ctrl+W` is the canonical VS Code close-tab gesture and
fires `buffer.close`. But mnml's keymap also reserves `Ctrl+W h/j/k/l/Ctrl+W`
as a vim window-prefix chord chain (kept even in standard mode — see
`src/input/keymap.rs:185-214`, the `is_vim_style` strip list does NOT remove
`ctrl+w` from standard mode). Result: every single press of Ctrl+W becomes a
`PendingWithFallback` for `CHORD_CHAIN_TIMEOUT_MS = 1000ms` before
`buffer.close` actually fires.

## Reproduction

```jsonl
{"cmd":"open","path":"main.rs"}
{"cmd":"open","path":"hello.py"}
{"cmd":"open","path":"app.js"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+w"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
// At t=200ms no tab is closed (status.json still shows 3 panes).
{"cmd":"wait_ms","ms":1100}
{"cmd":"snapshot"}
// At t=1300ms the timeout fires and one tab closes.
```

VS Code closes on key-down, not after a 1-second timeout. A user rattling off
four `Ctrl+W`'s to clear their tab strip sees nothing visible for a full second,
then four buffers vanish at once.

**Expected**: Ctrl+W closes the active tab immediately (or at most one
key-up later) — that's what every VS Code, Sublime, JetBrains, browser tab
user expects.

**Actual**: closes ~1000ms after the LAST Ctrl+W press, after the chord
timeout. If a non-matching follow-up key is pressed sooner, the queued
fallbacks fire in a burst.

**Source pointer**:
- `src/input/keymap.rs:185-214` — strip-list of chord-prefix Ctrl+letter
  chords for vim mode does NOT also apply to standard mode. `ctrl+w` stays
  a prefix in standard mode.
- `src/tui/chord.rs:52-67` — `PendingWithFallback` waits the full
  `CHORD_CHAIN_TIMEOUT_MS` before firing the fallback.
- `src/command.rs:1858-1864` — `buffer.close` is the registered fallback.

**Notes**: For VS Code muscle memory, the entire `Ctrl+W <letter>` chord chain
shouldn't exist in standard mode (window-nav has palette / mouse / `:split` ex
equivalents). Stripping `ctrl+w` from the standard-mode keymap would let it
fire as a direct binding, no chord pending. Alternatively make Ctrl+W not
have any sub-chords in standard mode so the resolver returns `Run` instead
of `PendingWithFallback`.
