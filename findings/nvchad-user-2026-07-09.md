# NvChad-user hunt — 2026-07-09 session

## Findings

### 1. Panel `/` filter keeps swallowing keystrokes after focus leaves the tree — **SEV-2**

The entry gate for each `/`-filter panel (HTTP, TODOs, Sessions,
Notes, Agents, CloudAgents) correctly requires
`Focus::Tree` + `picker.is_none()` + `no_pane_cmdline.is_none()`.

The **absorb block** does NOT re-check any of those. Once
`<section>_panel_filter_focused = true`, every subsequent
`KeyCode::Char(_)` / `Backspace` / `Enter` / `Esc` is captured
unconditionally, regardless of where visual focus has moved
and regardless of whether a picker or prompt is now above the
filter row.

**Result:** vim user hits `/`, glances at the panel, `Ctrl+W l`
(or any focus-pane action) back to the editor, and is silently
trapped. `/`, `:`, `i`, `dd`, `abc` all get appended to the
sidebar filter chip. Mode chip still says `NORMAL`, cursor
doesn't move, no toast, no dialog. Only `Esc` breaks out.

Same defect masks `?` reverse search, `n`/`N` repeat, `*`
word-search, macro replay `@a`, `:` ex commands from
`Focus::Pane` any time a filter is still focused.

**Picker variant:** opening `picker.files` with a filter still
focused routes the typed query into the filter, not the
picker's input. The picker overlay is visible but keyboard-
dead.

#### Repro (headless vim, notes.txt open at `Focus::Pane`)

```jsonc
{"cmd":"run-command","id":"view.focus_tree"}
{"cmd":"run-command","id":"view.activity_notes"}
{"cmd":"key","key":"/"}
{"cmd":"type","text":"scr"}
{"cmd":"run-command","id":"view.focus_pane"}
{"cmd":"key","key":"/"}
{"cmd":"key","key":"i"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"d"}
{"cmd":"snapshot"}
```

Filter chip after: `󰍉 scr/idd▏` — header `NOTES (0 of 2)`.
`status.json`: `"focus":"pane"`, `"mode":"NORMAL"`, cursor
unchanged. `notes.txt` never mutated.

#### Source

`src/tui/mod.rs` — repeats at six sites. Notes representative:
- Entry gate `938-950` — correctly gated.
- Absorb block `951-976` — `if app.notes_panel_filter_focused
  { match key.code { … } }` with no `focus`, `picker`,
  `prompt`, `whichkey`, `context_menu`, or `menu_open` checks.

Same shape at HTTP `798-834`, TODOs `873-897`, Sessions
`912-936`, Agents `993-…`, CloudAgents `~1027-…`.

**Integrations `738-782` is the counter-example that does it
right** — both entry AND absorb are wrapped in the outer
`if focus == Focus::Tree && active_section == Integrations &&
picker.is_none() && integration_edit.is_none()` block, so
leaving the tree implicitly stops capturing.

#### Fix

Two options per site:
1. Mirror the Integrations wrapping — hoist the absorb block
   under the same guard as the entry.
2. Add `&& app.focus == Focus::Tree && app.picker.is_none() &&
   app.prompt.is_none()` to the absorb-block predicate.

Should also clear `_filter_focused` on any `focus` /
`active_section` / picker-open / prompt-open transition.

### 2. Filter chip gives no persistent "still typing into me" cue — **SEV-3**

Downstream of SEV-2. If the sidebar is scrolled or the user
has since flipped `ActivitySection`, the filter chip that
owns the keyboard is off-screen — but still greedily eating
keys. `status.json` has no `<section>_panel_filter_focused`
mirror either.

**Suggested surface:** reflect "filter-focus in <section>" in
the mode chip alongside `NORMAL`/`INSERT`, OR render a
persistent statusline segment (e.g. `/scr` in cyan) while any
of the six filters is focused.

## Scenarios verified clean

- **HTTP preview drop-on-leave (commit 27d37ca)**:
  `view.activity_http` auto-opens preview; switching to
  `view.activity_notes` without touching it drops the pane;
  `activePane` returns to `notes.txt`.
- **AI tab-strip chip commands (commit e719498)**:
  `:ai.claude_code_new_left / _right / _top / _bottom` all
  resolve and split correctly. All four have `keys: &[]` — no
  chord surface, no collision. `<leader> a` whichkey submenu
  unchanged.
- **Integration remove confirm (commit 278e5bb)**: `d` while
  dialog is open is inert (no vim delete-line). `Esc`
  dismisses cleanly. `Enter` fires the focused button. Cancel
  is the default focused button.
- **`:e brand-new.txt`** still opens a fresh buffer.

## Files touched during hunt
- `src/tui/mod.rs` — the six filter-absorb blocks (lines 738-1050 area)
- `src/ui/notes_panel.rs`, `todos_panel.rs`, `sessions_panel.rs`
- `src/input/vim.rs:2666` — `/` → `find.find` dispatch (unreached under the bug)
- `src/app/find.rs:262` — Find prompt opener
- `src/app/picker.rs:1731` — `IntegrationRemoveConfirm` accept handler
- `src/tui/handlers/overlay.rs:440-495` — confirm-button key dispatcher
