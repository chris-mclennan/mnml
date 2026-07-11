# vscode-user keyboard hunt — 2026-07-10

Headless drive against HEAD after today's filter-absorb hoist +
panel j/k nav + AI-placement palette entries.

## Summary

4 issues (0 SEV-1, 3 SEV-2, 1 SEV-3). Cross-section switches
clear filter focus (the fix works). Three completeness gaps
remain around same-section re-entry and the panel/chip menu
surfaces the commit touched.

## SEV-2

**1. Same-section re-invoke doesn't reset focus.**
`set_activity_section` (`app/layout.rs:1882-1905`) gates
`focus = Tree` + flag-clear on `active_section != section`.
After Enter opens a TODO (focus=Pane, section unchanged),
re-firing `view.activity_todos` is a no-op for focus — `/`
types into the editor. Repro:
```
{"cmd":"run-command","id":"view.activity_todos"}
{"cmd":"key","key":"/"} {"cmd":"type","text":"multi"} {"cmd":"key","key":"enter"}
{"cmd":"key","key":"enter"}                        // focus=Pane
{"cmd":"run-command","id":"view.activity_todos"}   // silent no-op
{"cmd":"key","key":"/"} {"cmd":"type","text":"x"}  // "/x" hits editor
```
Move the focus reset outside the `!=` guard.

**2. `Copy id` / `Show manifest…` unreachable by keyboard.**
Added to `open_integration_chip_context_menu`
(`app/context_menus.rs:379-386`). Shift+F10
(`context_menus.rs:37-40, 98`) demands `hover_chip` <2s old —
hover is mouse-only; `focus == Tree` routes to the tree menu.
No `integrations.copy_id` / `integrations.show_manifest`
palette id. Repro: `Ctrl+Shift+P` → `copy id` — 0 hits.

**3. Integrations + Agents panels have no j/k/Enter nav.**
Today's fix landed row nav on TODOs / Notes / Sessions but
skipped Integrations + Agents. In Integrations, `j` silently
moves the *hidden* tree cursor (`treeCursor: 0→2` observed) via
fall-through; Enter activates a tree row you can't see. Repro:
```
{"cmd":"run-command","id":"view.activity_integrations"}
{"cmd":"key","key":"j"} {"cmd":"key","key":"j"} {"cmd":"key","key":"enter"}
```

## SEV-3

**4. `+ Add integration` chip has no palette twin.**
Chip calls `open_sibling_install_picker`; palette has
`sibling.install` (title `"Sibling: install any family
sibling…"`) — searching `add integration` returns 0 relevant
hits. Palette-bar `+` chip fires unregistered
`integrations.add` (`tui/mouse/down_left.rs:1011`) — silent
no-op even for mouse. Alias `integrations.add` →
`sibling.install`.

## Verified working

- HTTP → TODOs: focus resets, `/` reaches filter, `(N of M)`
  advances on type.
- Ctrl+P while filter focused: picker absorbs, filter keeps
  prior text, Esc → editor.
- Confirm dialog: `Remove integration \`claude_code\`?`,
  Cancel default (Enter → `integration remove cancelled`).
- All 8 AI new-placement palette commands spawn a Pty at the
  labeled half.
- `markdown.edit_raw` toasts on `.rs`; swaps `note.md ◳` →
  `note.md` on preview.
- j/k/Enter on TODOs with + without filter opens correct row.
- `Ctrl+K i b` fires `forge.open_bitbucket`.
