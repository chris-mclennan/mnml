---
severity: SEV-3
surface: Claude Agents — Files drill-down panel
hunt: vscode-user mixed-input
date: 2026-06-21
---

## [SEV-3] Files-panel row click ignores Cmd/Ctrl/Alt — no "open in split", no "preview-vs-pin", no preview semantics; clicking opens the file immediately in a new editor pane

**Reproduction**:
```jsonc
{"cmd":"key","key":"esc"}
{"cmd":"run-command","id":"ai.agents_dashboard"}
{"cmd":"wait_ms","ms":2500}
// Cycle 'v' to Files view, j a few rows to a session that touched files
{"cmd":"key","key":"v"}
{"cmd":"key","key":"v"}
{"cmd":"key","key":"v"}                            // Summary → Todos → Files
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"j"}
{"cmd":"snapshot"}
// Detail panel shows e.g.
//   Edit scripts/create-worktree.sh
//   Edit scripts/heal-worktree.sh

{"cmd":"click","col":37,"row":28,"button":"left","mods":"super"}
{"cmd":"wait_ms","ms":300}
// File opens in a new editor pane — same as a plain left-click.
// Cmd/Ctrl ignored. There's no "open beside" / split semantics.

{"cmd":"click","col":37,"row":28,"button":"right"}
// no context menu — nothing happens
```

**Expected**: VS Code reflexes for file-list rows:
- single-click ⇒ preview (italic tab, gets replaced by next click)
- double-click ⇒ pin
- `Cmd/Ctrl+click` ⇒ open beside (split right)
- `Alt+click` ⇒ open in same column
- right-click ⇒ context menu (Open, Open to the Side, Copy Path, Reveal in
  Explorer)

Claude Agents Files panel is a quintessential file-list — it surfaces the
file paths an agent touched. The mouse expectations carry over.

**Actual**: `src/tui.rs:4881-4893` runs *before* the generic list-row
handler. Any left-click on a `claude_drill_files` rect calls
`app.open_path(&pb)` and returns. No modifier check
(`KeyModifiers::SUPER` / `CONTROL` / `ALT` are all dropped on the floor);
no double-click promote; no preview semantics. Every click is an "open"
and every "open" pins.

Additionally — `app.last_click` is NOT updated in this branch
(`src/tui.rs:4881-4893` returns before `last_click = Some(…)` would have
fired in the list_rows arm at `:4918`). So a quick double-click on a file
row registers as two separate "open" events on the *same* path: the first
opens, the second no-ops with no toast (the file is already open).
That's an internally inconsistent feedback model.

Right-click on a Files-panel row falls through to the context-menu
dispatcher, which doesn't currently know about this surface; in practice
right-click produces no menu (no `claude_files` arm in
`src/app/context_menus.rs`).

**Source pointer**:
- `src/tui.rs:4881-4893` — single-arm "any click opens" handler
- `src/ui/claude_agents_view.rs:594-643` — Files renderer that registers
  the click rects (`app.rects.claude_drill_files.push(…)`)
- `src/app/mod.rs:2026` — `claude_drill_files: Vec<(Rect, String)>`
- `src/app/context_menus.rs` — no arm for Claude Agents file rows

**Notes**: The keyboard help block on line 779 even documents
`(Files panel) click  open the file in an editor pane` — so this is
intended behaviour. The polish gap is "click is the *only* gesture
this surface understands" — modifier-clicks and right-click both fall
silent.

Suggested fix shape: read `m.modifiers` in the
`claude_drill_files` branch; `SUPER`/`CONTROL` ⇒ open in a horizontal
split (mirror the `open_in_split` path already used by `lsp.peek_definition`);
add a right-click context menu with at least Copy Path + Reveal in Tree.
