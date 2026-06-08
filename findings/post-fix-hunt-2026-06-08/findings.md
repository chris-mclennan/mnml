# Post-fix bug hunt — 2026-06-08

Driven via headless IPC against the binary after the 8-hour 20-commit
SEV-1/SEV-2 batch landed. Focus: regressions + fresh issues exposed
by the day's changes (mode-aware wheel, scrollbar drag, drag-select
fix, stale-PaneId close, settings overlay clicks, body context menu,
LSP hover-on-mouse, new chords, new hover tooltips).

**Severity counts: 0 SEV-1, 1 SEV-2, 4 SEV-3.**

## Top 3 (worst first)

### 1. SEV-2 — drag-select anchor uses swapped (col, row)

`src/tui.rs:3905` destructures `app.drag_select` as `(pid, ox, oy, armed)`
but the tuple is stored at `tui.rs:3822` as `(pid, row, col, false)`.
Result: `ox` binds to `row`, `oy` binds to `col`, then
`b.editor.place_cursor(oy, ox)` is effectively `place_cursor(col, row)`
— args swapped.

**Repro** (5-line file, 26-char lines):
- Drag from screen `(50, 3)` → `(60, 3)` — a single-line 10-cell drag.
- Expected: `Sel 10`.
- Observed: `Sel 94`. Anchor landed at `(file row=5, col=1)`, cursor at
  `(file row=1, col=15)`, selection spans 4+ lines.

The e2e test `mouse_drag_select.test` only asserted `Sel ` (any non-zero
count), which is why this shipped. Tighten to `Sel 10`.

**Fix** (in this commit): rename tuple fields to `(pid, orow, ocol,
armed)`, call `place_cursor(orow, ocol)`. Tighten e2e to `Sel 10`.

### 2. SEV-3 — `Ctrl+\` chord double-bound

Both `term.scratch_toggle` (`command.rs:2806`) and `view.split_right`
(`command.rs:3154`) declare `keys: &["ctrl+\\"]`. `Keymap::build`
inserts into a `HashMap`, so the later command in registry order wins
silently. `term.scratch_toggle`'s `ctrl+\` binding is dead even though
its title still claims the chord.

Same dedup hazard the team already burned on (2026-06-06 fix:
`+integrations` shadowed by `+insert` killed weeks of forge chords).

**Fix** (in this commit):
- Remove `"ctrl+\\"` from `term.scratch_toggle.keys`.
- Add a startup `eprintln!` warning in `Keymap::build` when two
  registry commands claim the same chord — so the next collision
  surfaces in seconds, not weeks.

### 3. SEV-3 — IPC `command/name` shape doesn't exist

Task prompt said `{"cmd":"command","name":"view.settings"}`. Real shape
is `{"cmd":"run-command","id":"..."}`. Every command-by-name in my
first 20 minutes logged as `unknown`. **Not a code bug** — bad agent
prompt. Could add an alias parser arm in `ipc/mod.rs:267` for symmetry
with the `.test` script keyword if desired.

## Remaining SEV-3s

### Standard-mode wheel may not scroll viewport when `wrap = true`

Could not cleanly isolate from session state. With `wrap=on` + standard
mode, repeated `{"cmd":"scroll","dy":-10}` events did not move the
viewport in multiple runs; same with `wrap=off` worked. Vim mode +
`wrap=on` works because cursor-follows-wheel uses `MoveDown` ops (a
different path). Existing `mouse_wheel_scroll.test` only covers
`wrap=off`. **Suggested follow-up:** add `mouse_wheel_scroll_wrap_on.test`
with a 50-line file containing some lines longer than viewport, toggle
wrap on, ctrl+home, scroll down 10, assert viewport moved.

### Settings overlay `*` modified marker never clears after save

Toggle a setting, save (click outside), reopen — `*` persists.
Arguably correct (`*` = "differs from default", not "unsaved") but
confusing UX. Either keep + document, or split into two markers
(`~` unsaved + `*` differs-from-default).

## What I verified clean

- **SEV-1 stale-PaneId close fix** (commit `063dd20`): the multi-tab +
  drag + middle-click sequence does NOT crash mnml. 5 back-to-back
  drag+middle-click cycles ran clean.
- **F2 → Rename, Ctrl+\ → Split right, Shift+Alt+↓/↑ → Duplicate line,
  `<leader>fg` → Grep workspace** — all wired and firing.
- **4 new hover tooltips** (`BufferlineNewTab`, `BufferlineThemeToggle`,
  `BufferlineTabClose`, window close): verified at the right cells.
- **Right-click editor body context menu**: paints at EOL, past EOL,
  mid-line.
- **Bufferline tab dirty Save**: end-to-end verified — typed `X` into a
  file, right-clicked tab, clicked Save, confirmed content on disk +
  `dirty:false` in status.
- **Settings overlay click-to-focus + click-outside-to-save**: works.
- **Scrollbar drag in vim mode**: works at col 119 (must be ON the
  bar, not the pad at col 118).

## Did not exercise

- **LSP hover on mouse-over**: rust-analyzer wasn't running in the
  headless harness; the wiring at `app/lsp.rs:330-343` looks correct.
- **Scrollbar drag in standard mode at full width**: unreliable
  `view.toggle_tree` behavior in session; e2e `mouse_scrollbar_drag.test`
  passes so trusting that path.
