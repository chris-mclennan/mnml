# SEV-2 — Ctrl+` cannot close the scratch terminal once it's focused

## What I did

1. `Ctrl+`` — opens the scratch strip at the bottom, focus lands in
   the PTY (title bar reads `scratch · Esc blurs · term.scratch_toggle
   closes`).
2. `Ctrl+`` again — expected: close the strip (VS Code semantics that
   the title bar advertises). Actual: the backtick character is
   forwarded to the shell inside the PTY. The strip stays open.
3. `Esc` — blurs the strip (per line 1422 of `src/tui/mod.rs`). Now
   press `Ctrl+`` — this goes through `toggle_scratch_term`, which
   sees `focused == false` and *focuses it again* (line 5138 of
   `src/app/mod.rs`) rather than closing.

There is no combination of keystrokes on the `Ctrl+`` chord that
closes an open, focused strip.

## Root cause

Two things fight each other:

- `src/tui/mod.rs:1419-1431`: when the scratch is focused, all keys
  route to `pty_key_bytes` (verified in `src/app/dispatch.rs:1737`).
  Ctrl+` isn't in the special-case list, so it falls through to
  `prefix_alt(c.to_string().into_bytes())` — the literal backtick
  goes to the shell.
- `src/app/mod.rs:5132-5155`: `toggle_scratch_term` only *closes* when
  `s.focused == true`. When called via the palette (or after `Esc`
  blurred), it focuses instead.

Net: from a focused state, the toggle can only reach the "close"
branch if the chord actually reaches the toggle. It never does.

## Why it matters

The title bar (`src/ui/scratch_term_view.rs:29`) literally advertises
"`term.scratch_toggle` closes". A VS Code user hits `Ctrl+`` and it
does the opposite. Escape hatch is Ctrl+Shift+P → "scratch" → toggle
twice (blur + close), which is not discoverable.

## Suggested fix (not applied)

Special-case Ctrl+` in the focused branch of `src/tui/mod.rs:1419`
BEFORE `pty_key_bytes` — mirror the Esc handling: close the scratch
term.

## Severity

SEV-2 — no crash, but the advertised chord has no working keyboard
path.
