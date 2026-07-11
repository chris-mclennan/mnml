# SEV-2 — F11 doesn't toggle full-screen and Zen has no chord

## What I did

1. `F11` from an editor pane — expected: VS Code's full-screen toggle
   (or, failing that, the closest mnml equivalent, Zen mode). Actual:
   nothing visible. No toast, no chrome change.
2. Searched for a chord binding to `view.zen`. `src/command.rs:402`
   confirms `keys: &[]` — palette-only. The comment above it
   explicitly says "Zen lives in the palette as `view.zen`."
3. `F11` is registered on `dap.step_in` at
   `src/command.rs:3603`. `src/app/dap.rs:297` early-returns when
   there is no DAP manager, so out of a debug session the chord
   *silently does nothing at all* — no toast that F11 isn't bound to
   anything you can use right now.

## Why it matters

VS Code users have F11 in muscle memory for the full-screen toggle
(with DAP-context stealing during a debug session). mnml has neither
a full-screen toggle nor a chord for its Zen equivalent. Two of the
three "focus" shortcuts a VS Code power user reaches for are absent
from the keyboard surface, so their instinct is to give up and use
the palette.

The palette works, but the discoverability gap is real: F11 doesn't
even toast to say "no DAP session; try Ctrl+Shift+P → view.zen".

## Suggested fix (not applied)

- Bind `view.zen` to `F11` (or `Ctrl+K Z` for VS Code parity) with a
  DAP-context override so an active debug session gets step-in.
- If F11 is intentionally reserved for DAP even without a session,
  toast "no active debug session" so the chord isn't a silent
  no-op.

## Severity

SEV-2 — a keyboard-purist has no chord to reach the closest thing
mnml has to full-screen mode.
