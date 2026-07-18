# vscode-keyboard-purist bug hunt — Round 7

Date: 2026-07-11
Driver: headless mnml + IPC (`--input standard`), workspace = fresh scratch tree.
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl+P / Ctrl+Shift+P / Ctrl+K / arrows only. No mouse.

## Executive summary

- SEV-1 count: 0
- SEV-2 count: 8
- SEV-3 count: 6

How keyboard-complete does mnml feel? Ninety percent of the day's work is fine —
open files (Ctrl+P), palette (Ctrl+Shift+P), edit reflexes (Ctrl+S/Z/Y/X/C/V/A),
find (Ctrl+F + F3), goto (Ctrl+G), tabs (Ctrl+W / Ctrl+Shift+T / Ctrl+Tab), zen
(Ctrl+K Z), settings (Ctrl+,), tree file ops (Ctrl+X/C/V/D when tree-focused),
and the leader chord chain (`Ctrl+K f`, `Ctrl+K g`, `Ctrl+K b`, `Ctrl+K l` all
feed the letter through to whichkey correctly — a one-chord win over pre-fix).
But the **entire right panel v2 experience** is quietly mouse-only. The panel
has a keyboard toggle, its tabs have a keyboard-cycle, its active tab has a
keyboard close chord — but there is **no keyboard chord to move focus INTO the
right panel**. Every shortcut the panel advertises in its own header
(`⏎ jump   r refresh   / filter` for outline, `⏎ jump · r refresh · s filter`
for problems) is unreachable. Same story for the empty-state row picker
(`▸ Outline / ▸ Problems / …`) — click-only. Shift+F10 on statusline chips is
similarly gated on a mouse hover_chip that a keyboard user never sets. Zoom out:
mnml *feels* like a keyboard-purist IDE until you hit the right panel and half
the statusline chrome, at which point you notice the mouse is not optional.

---

## SEV-2 (chord fires wrong action / no keyboard path to feature / multi-step chord broken)

### SEV-2 #1 — Right panel has NO keyboard focus path

`src/focus.rs` defines `enum Focus { Tree, Pane }`. There is no `RightPanel`
variant, and none of the focus movers reach the right panel:

- `view.focus_next_split` (`src/app/layout.rs:901`) iterates
  `layout.leaves()` — the right panel is not in the layout tree.
- `view.focus_dir` (Ctrl+K Ctrl+Right / Left / Up / Down,
  `src/app/layout.rs:849`) iterates `self.rects.editor_panes` — again
  excludes the right-panel pane.
- `focus.cycle` (Ctrl+E, `src/command.rs:2274`) toggles Tree ⇄ Pane only
  (`app.cycle_focus()`, which reads `Focus::next` in `src/focus.rs:13`).

Reproduced via IPC: with outline pane in the right panel and activePane=0
(main editor), pressed `ctrl+e`, `ctrl+k ctrl+right`, `view.focus_next_split`
— `activePane` stayed 0 every time (`status.json` verified).

Impact: user cannot pivot to the outline / problems / grep / AI-chat pane
without a mouse.

### SEV-2 #2 — Right-panel-advertised shortcuts unreachable by keyboard

The outline header advertises `⏎ jump   r refresh   / filter` (in the
right-panel border row). The problems header advertises
`⏎ jump · r refresh · s filter`. These keys ARE bound (see
`src/tui/handlers/pane.rs:770-800` for outline: `j`/`k`/`r`/`/`/`Enter`/
`Esc`/`G`), but the handler only fires when the OUTLINE pane is the active
pane (`app.active == outline_pane_id`). Because SEV-2 #1 blocks focus
transitions into the right panel, every one of these header hints is a
lie for keyboard users.

Repro: with outline open in right panel, pressed `r` — got typed as `r`
into the main editor buffer (dirty flag set). Same for `/` and `j`/`k`.

### SEV-2 #3 — Right panel resize is mouse-only

`right_panel_width` is stored in `config.ui.right_panel_width` (u16, clamp
10..80, `src/config.rs:574`). The only runtime path to change it is
drag-resize on the mouse handler (`app.rects.right_panel_edge`). There is
no `view.right_panel_wider` / `narrower` / `resize` / `expand` /
`collapse` command anywhere in `src/command.rs`.

A keyboard-only user has to quit mnml, hand-edit `~/.config/mnml/…`, and
relaunch to change the width.

### SEV-2 #4 — Right-panel empty-state options click-only

Empty right panel shows:

```
right panel

Add a panel:

▸ Outline    :outline.show
▸ Problems   :lsp.diagnostics
▸ AI chat    :ai.chat
▸ Grep       :find.grep
▸ Tests      :test.run

Hide: Ctrl+Shift+B
```

The `▸` markers make each row look focusable + selectable, but:

- Focus never lands on this pane (SEV-2 #1).
- Arrow keys / Tab / Enter with focus on the tree or editor pane do
  nothing to these rows.
- The `:outline.show` label communicates the ex-command name — but with no
  cmdline visible, the user isn't prompted to type it.

Rects for these rows are dumped in `rects.json` (`right_panel_empty_outline`
etc.) — a mouse can click. A keyboard user is dead-ended.

### SEV-2 #5 — Ctrl+Alt+W (right panel close-tab) is undiscoverable

Right-panel header renders `outline ⌥ | problems ✓ | 󰐕 | ×`. The `×` is a
mouse click target. There's a keyboard chord for it (`Ctrl+Alt+W`, bound
in `src/command.rs:1841`) but no tooltip / hint / statusline chip
mentions it. The empty-state overlay only lists `Hide: Ctrl+Shift+B`
(the whole-panel toggle, not the per-tab close).

Reachable via whichkey (`<leader>tx`) but nothing in the visible UI
points you there.

### SEV-2 #6 — Shift+F10 cannot open right-panel context menus

`open_context_menu_at_focus` (`src/app/context_menus.rs:27`) routes by
Focus:

- Focus::Tree → tree-row menu.
- Focus::Pane + `app.active.is_some()` → active tab menu.
- hover_chip fallback (needs recent mouse hover).

There's no branch that recognizes the right panel. So pressing Shift+F10
while the right panel is showing an outline never gives you the
right-panel-tab menu (e.g. "Close others", "Move to left"). The active
editor tab's menu opens instead.

### SEV-2 #7 — Shift+F10 cannot reach integration-chip / launcher-chip menus without a mouse hover

`open_context_menu_at_focus` recognizes `HoverChip::IntegrationIcon`,
`LauncherIcon`, `ActivityBarGear`, `StatuslineBranch`, `StatuslineWorkspace`,
`StatuslineMode`, `StatuslineClock` as fallback targets — but the
`hover_chip` field is set only by mouse `Moved` events (verify:
grep for `hover_chip = ` in `src/tui/mouse/`). Every one of the seven
chip menus is thus keyboard-unreachable via Shift+F10.

Partial mitigation: some chip menus have palette twins —
`view.workspace_menu`, `git.branch_menu`, `editor.input_mode_menu`,
`clock.menu` — but **integration-chip menu, launcher-chip menu, and
activity-bar gear menu have NO palette command**. Right-clicking a
sibling integration icon is impossible from the keyboard.

### SEV-2 #8 — Tab / Shift+Tab does not cycle focus

VS Code (with vim disabled) uses Ctrl+1, Ctrl+`, etc. for pane focus.
Some users expect Tab to focus-cycle overlays. In mnml:

- Tab in editor pane inserts spaces (as designed).
- Tab in tree is consumed but does nothing.
- Tab in http-panel-filter behaves as typing into filter input.
- No chord anywhere cycles focus between tree / editor / right panel.

`focus.cycle` (Ctrl+E) is the only focus-cycle chord and it only flips
Tree ⇄ Pane.

---

## SEV-3 (visual / polish / discoverability)

### SEV-3 #1 — Icon picker Enter with no edit context: silent no-op

Fired `integrations.icon_picker` from a fresh session (no
`integration_edit` open). Typed `folder` (narrowed to 2 hits), pressed
Enter. Picker closed. No toast, no clipboard write, no error — the picked
glyph went nowhere. The picker offered "+ Create custom glyph…" only
when launched from an integration edit; otherwise it doesn't warn users
that Enter is meaningless.

### SEV-3 #2 — Icon picker: selected-glyph footer suppressed in small terminals

`src/ui/picker.rs::draw_glyph_grid` gates the "selected: `<name>` `\u{XXXX}`"
footer on `list_area.height >= 3`. In our headless render the picker was
seven cells tall, but the way it sizes reserved rows made the footer
invisible in headless. A keyboard user pressing arrow-right cannot tell
which glyph is currently selected without the footer.

### SEV-3 #3 — F11 fires DAP step-in, not zen / fullscreen

`src/command.rs:3697` binds F11 to `dap.step_in`. VS Code / macOS
convention is F11 = toggle fullscreen (or zen). Zen mode exists in mnml
(`view.zen`, bound to Ctrl+K Z) but has no F11 alias. A VS Code
keyboard-purist hitting F11 with no DAP session running gets a silent
no-op — expected a mode change.

### SEV-3 #4 — Right panel "Add a panel" empty state: cryptic `:foo.bar` labels

Each row shows `▸ Outline  :outline.show`. The `:outline.show` reads as
"type this into cmdline" — but there's no cmdline visible when the panel
is empty. If the intent is "click here", `:outline.show` is noise. If
the intent is "run this ex-command", give a cmdline chord hint (e.g.
`⌘: :outline.show`).

### SEV-3 #5 — Palette re-filter after arrow-move keeps selection by INDEX not by IDENTITY

Repro: `Ctrl+Shift+P`, type `outline` → 53 hits, `Down` to row 2, type
`.sh` → 10 hits. Now row 2 is a different, unrelated command (`Delete
the current line`) rather than either the previously-selected row (if
still in the filtered set) or row 0 (a clean reset). Small UX
inconsistency vs. VS Code's palette which resets to row 0 on new
keystrokes.

### SEV-3 #6 — Palette right-panel picker rows advertise no keyboard chord

The empty right-panel state (`right panel / Add a panel: / ▸ Outline …`)
and the outline header (`⏎ jump  r refresh  / filter`) both list keys
that require right-panel focus — which as covered above has no keyboard
chord to reach. The header chips lie to keyboard users. If the panel
truly can't be focused, drop those hints (or add the chord that makes
them true).

---

## Verifications (no bug)

- **Leader chord chain feeds opener letter correctly.** `Ctrl+K f`, `Ctrl+K g`,
  `Ctrl+K b`, `Ctrl+K l` each open the `<leader> f/g/b/l` submenu — no
  double-tap needed. `Ctrl+K f f` opens the files picker in two chords total.
- **Ctrl+P fuzzy file picker.** Types → fuzzy narrows (7 → 1 for `read`).
  Enter opens. Esc closes and returns focus to pane. Second invocation of
  Ctrl+P opens a fresh picker (empty query, cursor at row 0).
- **Ctrl+Shift+P palette.** Filter + arrows + Enter + Esc all work.
  Typing after arrow-move re-filters (with SEV-3 #5 caveat on selection
  identity).
- **Ctrl+X / C / V / D from tree focus.** Route to `file.cut` / `file.copy`
  / `file.paste` / `file.duplicate` (see `src/tui/handlers/pane.rs:92-115`).
  `file.copy` on a tree-selected `main.rs` toasted `copied main.rs` and set
  `file_clipboard`.
- **Ctrl+X / C / V / D from pane focus.** Do editor operations, NOT file
  operations. `Ctrl+X` cuts current line. `Ctrl+D` (multi-cursor next
  occurrence) leaves `main.rs` untouched on disk. Verified — no cross-fire.
- **`file.move_to`.** Palette-triggered, opens a workspace-path prompt.
  Esc cancels.
- **HTTP panel `/` filter.** `/` focuses filter, typing narrows, Esc
  clears filter and unfocuses.
- **Shift+F10 tree-row (file) / tree-row (dir) / editor tab.** Correct
  menu opens each time. Menu items are keyboard-navigable via
  Down/Up + Enter (highlight visible only after first interaction —
  by design, per `src/context_menu.rs::interacted`). Down + Down + Enter
  fired the 3rd item (`New file…`) → prompt opened as expected.
- **Settings overlay.** `Ctrl+,` opens. `j`/`k` / arrow-keys move rows,
  `h`/`l` / arrow-keys change value, `r` reset row, `Shift+r` reset all,
  `Enter` save + close, `Esc` cancel + revert, `/` focuses filter, first
  `Esc` clears filter, second `Esc` closes.
- **Editing reflexes.** Ctrl+S save; Ctrl+Z undo; Ctrl+Shift+Z redo;
  Ctrl+A select-all; Ctrl+/ toggle comment; Ctrl+L select line;
  Alt+Down move line; Shift+Alt+Down duplicate; Ctrl+F + F3 / Shift+F3;
  Ctrl+G goto line.
- **Ctrl+K Z zen mode.** Enters + exits cleanly. Chrome hides + returns.
- **Ctrl+W close tab, Ctrl+Shift+T reopen closed, Ctrl+Tab MRU cycle.**
- **Ctrl+Alt+W closes right-panel active tab** (verified when panel had
  outline + problems, chord closed active and cycled to remaining).
- **Ctrl+K t ] / Ctrl+K t [.** Cycles right-panel tabs when >1 open.
- **Ctrl+Shift+B toggle right panel.** Works idempotently; rapid-repeat
  (4x in a row) stable.
- **Ctrl+B toggle tree.** Works.
- **Right-panel v2 body content.** With outline visible in right panel,
  editor body isn't obliterated — left = editor, right = outline. Splits
  don't route into it (per plan).

---

## Files touched to verify

- `src/focus.rs` — Focus enum (Tree / Pane only, no RightPanel).
- `src/app/context_menus.rs` — `open_context_menu_at_focus` routing.
- `src/app/layout.rs:849, 901` — focus_dir + focus_next_split.
- `src/tui/handlers/pane.rs:77-115, 770-800` — Ctrl+X/C/V/D tree gating +
  outline pane keys.
- `src/command.rs:1763-1853` — right-panel commands
  (`view.toggle_right_panel`, `right_panel_next_tab`, `right_panel_prev_tab`,
  `right_panel_close_tab` = Ctrl+Alt+W).
- `src/command.rs:5556` — `whichkey.leader` bound to Ctrl+K.
- `src/command.rs:2274` — `focus.cycle` (Ctrl+E, Tree ⇄ Pane only).
- `src/command.rs:5594` — `view.focus_right` (Ctrl+K Ctrl+Right, splits only).
- `src/command.rs:5641, 5655, 5669, 5683` — chip menu palette twins for
  mode / workspace / branch / clock (no twins for integration icon /
  launcher / gear).
- `src/config.rs:574, 979, 1759, 1962` — right_panel_width config, no
  runtime command.
- `src/tui/handlers/overlay.rs:315-333` — settings-overlay key handler.
- `src/context_menu.rs:327-356` — interacted flag semantics.
- `src/ui/picker.rs:200-280` — icon-picker footer gate.
- `src/command.rs:3697-3703` — F11 → dap.step_in.
