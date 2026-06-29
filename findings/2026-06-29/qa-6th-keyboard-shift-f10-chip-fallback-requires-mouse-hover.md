---
agent: vscode-user-keyboard
severity: SEV-2
---

# Shift+F10 hover_chip fallback is mouse-only — pure keyboard user can't reach chip context menus

**Verified on:** HEAD 029b0fe · `--input standard`

**Repro**
1. Start mnml headless. Do not move the mouse (or in headless mode, no mouse exists).
2. Hit `Shift+F10` while focus is on Pane.
3. Compare with `Ctrl+Shift+E` → tree-focused → `Shift+F10` (which DOES open tree row menu — works fine).
4. Try with focus anywhere outside Tree or active Pane (cmdline, settings overlay) → toast "no context menu at this focus".

**Expected**
A pure-keyboard user should be able to right-click-equivalent on:
- Integration chips (Browser, etc.)
- Launcher chips (rail icons like 󰡚, 󰒍, etc.)
- ActivityBar gear (settings)
- All 4 statusline chips (branch / workspace / mode / clock)

…purely with the keyboard. This is what the comment block in `src/app/context_menus.rs:14-26` advertises as VS Code + macOS Shift+F10 convention.

**Actual**
The "hover_chip fallback" in `open_context_menu_at_focus` requires `app.hover_chip` to be set within the last 2 seconds. `hover_chip` is set ONLY at `src/tui/mouse/mod.rs:421` — i.e., when the mouse pointer hovers over a chip. Keyboard navigation never sets it.

```rust
// context_menus.rs:37-40
let hover_recent = self
    .hover_chip
    .as_ref()
    .is_some_and(|(_, t)| t.elapsed() < std::time::Duration::from_secs(2));
```

So a keyboard purist who hits `Shift+F10` while editing always gets the bufferline-tab menu (Focus::Pane branch matches), never the gear / launcher / chip menu. The four statusline chips are entirely unreachable from the keyboard.

**Why this matters**
The "right-panel `enabled` opt-in" track (2026-06-28) leaned on right-click context menus for the integration toggle ("right-click to toggle, persisted to TOML"). A pure-keyboard user who wants to disable the `browser` chip has no keyboard chord to reach that menu — they have to use the palette to find the discrete command (if it exists).

**Suggested scope (not implementing)**
Add a Tab-cycle focus path through chips when the user holds e.g. Alt+Tab in the editor, or add a `focus_next_chip` / `focus_prev_chip` command that moves focus across chip groups and lets `Shift+F10` route by focus rather than hover.

**Related**
`src/app/context_menus.rs:27-177`, `src/tui/mouse/mod.rs:421`.
