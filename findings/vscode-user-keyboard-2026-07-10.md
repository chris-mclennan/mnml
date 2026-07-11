# vscode-user keyboard hunt — 2026-07-10

Headless drive against HEAD after today's filter-absorb hoist +
panel j/k nav + AI-placement palette entries.

## Summary

4 issues (0 SEV-1, 3 SEV-2, 1 SEV-3). Cross-section switches
now clear filter focus (fix works). Three keyboard-completeness
gaps remain around the *same* section-re-entry and the two panel
+ chip menu surfaces the commit touched.

## SEV-2

**1. Same-section re-invoke doesn't reset focus.**
`set_activity_section` (`src/app/layout.rs:1882-1905`) gates the
whole `focus = Tree` + clear-flags block on
`active_section != section`. After Enter opens a TODO/Note
(focus = Pane, section unchanged), re-firing
`view.activity_todos` to hop back to the filter is a no-op for
focus — `/` types into the editor. Repro (fresh workspace):
```
{"cmd":"run-command","id":"view.activity_todos"}
{"cmd":"key","key":"/"} {"cmd":"type","text":"multi"} {"cmd":"key","key":"enter"}
{"cmd":"key","key":"enter"}                        // focus=Pane, section=Todos
{"cmd":"run-command","id":"view.activity_todos"}   // silent no-op for focus
{"cmd":"key","key":"/"} {"cmd":"type","text":"x"}  // "/x" hits editor
```
Move the focus reset outside the `!=` guard.

**2. `Copy id` / `Show manifest…` unreachable via keyboard.**
Added to `open_integration_chip_context_menu`
(`src/app/context_menus.rs:379-386`). Shift+F10
(`context_menus.rs:37-40, 98`) demands a `hover_chip`  <2 s
old — hover is mouse-only. `focus == Tree` routes to the tree
menu instead. No `integrations.copy_id` /
`integrations.show_manifest` palette id.
Repro: `Ctrl+Shift+P` → `copy id` — 0 relevant hits.

**3. Integrations + Agents panels still have no j/k/Enter nav.**
Today's fix landed `<section>_panel_cursor_*` on TODOs / Notes /
Sessions but skipped Integrations + Agents, same class. In
Integrations, `j` silently moves the *hidden* tree cursor
(`treeCursor: 0 → 2` observed) because the fall-through lands
in the tree handler; Enter then activates a tree row you can't
see. Repro:
```
{"cmd":"run-command","id":"view.activity_integrations"}
{"cmd":"key","key":"j"} {"cmd":"key","key":"j"} {"cmd":"key","key":"enter"}
```
`activeFile` unchanged; `treeCursor` bumped invisibly.

## SEV-3

**4. `+ Add integration` chip has no palette twin.**
The chip (`ui/mod.rs:3366`) calls `open_sibling_install_picker`
directly. Palette has `sibling.install` titled `"Sibling:
install any family sibling by id (Pty or Mount)"`; searching
`add integration` returns 3 refresh / glyph hits, none of which
is the add flow. Also the palette-bar `+` chip fires the string
`integrations.add` (`tui/mouse/down_left.rs:1011`) — not a
registered command id, silent no-op. Add an `integrations.add`
alias / retitle `sibling.install`.

## Verified working

- Cross-section HTTP → TODOs: focus resets, `/` reaches filter
  gate, `(N of M hits)` advances on type.
- Ctrl+P while filter focused: picker absorbs, filter chip
  retains prior text, Esc → editor focus.
- Confirm dialog title `Remove integration \`claude_code\`?`
  with backticks + `?`; Cancel is default (Enter → toast
  `integration remove cancelled`).
- All 8 AI new-placement palette commands fire; each spawns
  a Pty at the labeled half.
- `markdown.edit_raw` toasts `not a preview pane` on `.rs`;
  swaps `note.md ◳` → `note.md` (editor) on a preview pane.
- j/k/Enter on TODOs with + without filter navigates rows and
  opens the correct `multi.rs:N`.
- `Ctrl+K i b` opens whichkey → integrations → fires
  `forge.open_bitbucket`, `bitbucket` Pty pane appears.
