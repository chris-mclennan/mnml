---
agent: input-handler-reviewer
severity: SEV-2
introduced_by: 10c01c1
fixed_in: pending
---

# Ctrl+Alt+W shadowed by menu-bar Alt+letter accelerator

`src/tui/mod.rs:271` uses `key.modifiers.contains(KeyModifiers::ALT)`
which is a SUBSET check — Ctrl+Alt+W has both CONTROL and ALT set, so
the accelerator branch fires. The 'W' char matches the "Window" menu's
first alphabetic char, the accelerator consumes the keystroke with an
early `return;`, and `dispatch_chord_chain` (which would have fired
`view.right_panel_close_tab`) is never reached.

In the default config (`menu_bar = "always"`) the menu bar is visible
and the accelerator path is open. So the new chord I just registered
in 10c01c1 doesn't work in the default config.

## Fix
Add `&& !key.modifiers.contains(KeyModifiers::CONTROL)` to the
accelerator branch's guard, so Ctrl+Alt+anything falls through to
the chord layer.
