---
agent: vscode-user-keyboard
severity: SEV-2
---

# Keyboard QA — recent chord additions (2026-06-28)

Driven headless (`mnml --headless --input standard /tmp/kbd-hunt-2026-06-28-vscode`).
Persona: VS Code keyboard-purist on standard mode. No mouse. Probed each
chord on the verification list both via the chord chain dispatcher
(real key path) and through the keymap probe (a one-shot test added to
`src/input/keymap.rs` and then reverted).

## Counts

- SEV-1: 0
- SEV-2: 1
- SEV-3: 2
- Verified working: 9 of 9 chord families (one with a caveat)

## Executive summary

Eight of the nine recent chord additions fire correctly from the
keyboard. The single behaviour gap is the new `Alt+Left` / `Alt+Right`
"browser back/forward" — both chords are also bound at the global
keymap to `nav.back` / `nav.forward` (the file/cursor jump-list),
which sits ABOVE the focused pane handler in `dispatch_key`, so the
Browser-pane special-case at `tui/handlers/pane.rs:565-566` never
runs. A Browser-pane user pressing `Alt+Left` gets "nothing to go
back to" (or jumps out of the browser tab to a previous editor
location) instead of `window.history.back()`.

Also worth noting in this session: the pre-shipped `target/release/mnml`
binary mtime (2026-06-28 16:43) **predated** commits `53c95a4` (Ctrl+Shift+[/])
and `4548d64` (Alt+F12 / Alt+Left/Right). On first probe, `Ctrl+Shift+[/]`
appeared dead — they were absent from the binary. Rebuilding (`cargo build
--release`) made them fire correctly. Not a finding per se, but the
"already-built binary" assumption from CLAUDE.md was stale.

Day-of-work feel: the keyboard-only flow remains very good for these
new chords. Right-panel toggle, fold/unfold, peek-def overlay, context
menu, leader-driven right-panel tabs, HTTP block nav, and AI backend
toggle all work as advertised. The single browser-chord conflict is
real but only bites browser-pane users — most VS Code keyboard users
won't notice.

---

## SEV-2-1 — Alt+Left / Alt+Right cannot reach Browser pane back/forward

The recent commit `4548d64 feat: LSP peek on Alt+F12 + browser back/forward
on Alt+Left/Right` adds a Browser-pane-only handler in `tui/handlers/pane.rs`:

```rust
KeyCode::Left if key.modifiers.contains(KeyModifiers::ALT) => app.browser_back(),
KeyCode::Right if key.modifiers.contains(KeyModifiers::ALT) => app.browser_forward(),
```

But the global keymap also has these chords:

- `src/command.rs:1746` — `nav.back` ← `keys: &["alt+left"]`
- `src/command.rs:1753` — `nav.forward` ← `keys: &["alt+right"]`

`dispatch_key` runs `dispatch_chord_chain` (which consults the keymap)
BEFORE `handle_pane_key`. The global chord chain matches first and
returns true, so the Browser handler is unreachable. Verified by
sending `alt+left` from editor focus and observing the toast
`nothing to go back to` (the `nav.back` empty-jumplist toast), not
a browser-CDP nav.

Repro (headless):
1. `mnml --headless --input standard /tmp/kbd-hunt-2026-06-28-vscode`
2. Open a `.rs` file.
3. Send `{"cmd":"key","key":"alt+left"}` — toast: `nothing to go back to`
   from `nav.back`, not the intended `browser.back`.

The keymap probe also confirms (`alt+left → Run(nav.back)`, `alt+right
→ Run(nav.forward)`); there's no way to reach `KeyCode::Left if ALT`
in the Browser pane unless the global chord is removed for that
focus.

Fix options:
- Drop the global `alt+left/right → nav.back/forward` defaults and
  make those palette-only (BR breakage for users who muscle-memoried
  the jump-list chord).
- Skip the chord chain for `alt+left/right` when `app.active` is a
  Browser pane (route to the pane handler instead). Mirrors the
  existing Request-pane intercept at `tui/mod.rs:1272-1294` for
  `ctrl+]`/`ctrl+[`.
- Move the Browser handler ABOVE the chord-chain in `dispatch_key`
  with the same focused-pane gate.

---

## SEV-3-1 — F10 → dap.next is shadowed by menu summon under default config

`src/command.rs:2407` (and similar) declares `keys: &["f10"]` → `dap.next`
(VS Code Step Over). But the menu-bar summon at `tui/mod.rs:240` claims
F10 BEFORE the chord chain runs:

```rust
if key.code == KeyCode::F(10) && key.modifiers.is_empty() && !menus.is_empty() {
    app.menu_open = Some(crate::menu_bar::MenuOpenState::new_keyboard(target));
    return true;
}
```

…gated on `app.config.ui.menu_bar != "hidden"`. The default is `"always"`
(`config.rs:1174`), so out of the box, F10 opens the File menu — `dap.next`
is dead in default config. Users who set `menu_bar = "hidden"` get the
debug step-over.

Not a hard bug — F10 menu-summon is canonical Windows/VS-Code convention —
but the `dap.next` binding is hidden behaviour. A discoverable note in
the command title (e.g. "DAP step-over (F10; only when menu_bar = hidden)")
or a doc line near both bindings would help.

Verified by sending `f10` from editor focus — File menu opens, no
DAP toast / step.

---

## SEV-3-2 — `whichkey.leader` fallback firing only resolves on the next loop tick after wait_ms

Not a chord-firing bug, but an observation while verifying `<leader>` chords:

`tick_chord_chain` only fires the chord-chain fallback during the
main loop iteration (`headless.rs:36`, `tui::run_loop` equivalent).
When `wait_ms` runs inside `drain_commands` it blocks the loop, so a
1.5s `wait_ms` after `Ctrl+K` doesn't open `whichkey` until the wait
returns and the loop ticks once more. This matches the existing E2E
harness expectation; just worth noting for tape-recorder authors:
budget at least `CHORD_CHAIN_TIMEOUT_MS (1000ms) + POLL_SLEEP (40ms)
+ 1 iteration` between a leader-prefix and a snapshot if the fallback
needs to fire.

No code change recommended.

---

## Verified working (one line each)

- **Ctrl+Shift+B → `view.toggle_right_panel`** — `rightPanelVisible`
  flips both directions; on hide, hosted panes drain correctly.
- **Ctrl+Shift+[ → `editor.toggle_fold`** — folds enclosing block at
  cursor; toast `folded N lines`; `⋯ N hidden` glyph appears.
- **Ctrl+Shift+] → `editor.unfold_all`** — drops every fold; toast
  `unfolded 1 fold(s)`.
- **Alt+F12 → `lsp.peek_definition_overlay`** — chord-chain dispatches
  the command. Real overlay rendering requires the LSP to respond
  with a definition; with no Cargo.toml in the scratch workspace,
  rust-analyzer didn't index in time to verify the floating box,
  but the command runs (the keymap probe confirms `Run(lsp.peek_definition_overlay)`).
- **Shift+F10 → `view.context_menu_at_focus`** —
  - In Pane focus: opens the active tab's context menu (Close /
    Close others / Copy path / Reveal / Split right/down/left/up).
  - In Tree focus: opens the selected row's context menu (Open /
    Open in split / New file… / Rename… / Delete… / Copy path…).
  - Hover-chip fallback: not verified end-to-end in headless (would
    need a mouse hover within 2s), but the routing logic at
    `app/context_menus.rs:37-86` reads correctly.
- **`<leader>t]` (Ctrl+K t ]) → `view.right_panel_next_tab`** —
  `rightPanelActiveIdx` advances modulo `rightPanelPanes.len()`.
- **`<leader>t[` (Ctrl+K t [) → `view.right_panel_prev_tab`** — same
  in reverse.
- **`<leader>tx` (Ctrl+K t x) → `view.right_panel_close_tab`** — evicts
  the active hosted pane (e.g. `rightPanelPanes [1, 2]` → `[1]`).
- **`<leader>h]` (Ctrl+K h ]) → `http.next_block`** — jumps cursor
  from line 1 (`### get users`) to line 5 (`### create user`) in
  the sample.http fixture.
- **`<leader>h[` (Ctrl+K h [) → `http.prev_block`** — symmetric
  jumps back.
- **`<leader>ab` (Ctrl+K a b) → `ai.toggle_backend`** — toast
  `ai.backend: cli` (or `api` depending on prior state).

---

## Method

- Used file-IPC under `/tmp/kbd-hunt-2026-06-28-vscode/.mnml/ipc/`.
- Appended JSON commands to `command` with `>>` (truncating with `>`
  resets the cmd_offset and causes timing edge cases).
- Verified each chord both by side-effect on `status.json` /
  `screen.txt` AND by a one-shot keymap probe (a `#[test]` added to
  `src/input/keymap.rs::tests` that called `Keymap::resolve_seq` for
  each chord and printed the resolution; removed before finishing).
- During the probe I temporarily added an `eprintln!` to
  `dispatch_chord_chain` to confirm the chord arrives intact at the
  resolver (it does; removed). The output proved both `keycode` and
  `modifiers` are exactly `Char('[')` + `CTRL|SHIFT` etc., refuting
  any terminal-layer mangling.

## Files exercised

- Fixture workspace: `/tmp/kbd-hunt-2026-06-28-vscode/{hello.rs,notes.md,sample.http}`.
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml` (rebuilt
  during this session — original was older than the recently-landed
  chord commits).
