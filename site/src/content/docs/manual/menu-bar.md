---
title: Menu bar
description: The chrome-row menu bar — File / Edit / Selection / View / Go / Run / Terminal / Window / Help — its keyboard reach at any terminal width, glyph strategy, and interaction with overlays and DAP sessions.
---

mnml paints a VS Code-style menu bar on the chrome row above the bufferline. Ten menus: a leading brand menu, then File / Edit / Selection / View / Go / Run / Terminal / Window / Help. Each entry dispatches an existing palette command — the menu bar is pure presentation on top of the command registry, not a parallel dispatcher.

The point isn't discoverability alone (the palette does that too) — it's giving people a mouse path and a keyboard-accelerator path that maps to muscle memory from other editors. Alt+F for File, F10 to summon, click a word to drop, arrow around, Enter to fire.

## Visibility mode

Set once in config; three values:

```toml
[ui]
menu_bar = "always"    # default — words always visible on the chrome row
# menu_bar = "auto"    # hidden until summoned via Alt+letter, F10, or mouse-at-top
# menu_bar = "hidden"  # never visible; palette-only flow
```

Cycle at runtime via the palette command `view.menu_bar_cycle`, or from the **View** menu itself (`Cycle menu bar (always / auto / hidden)`).

`"hidden"` disables both the paint and the Alt+letter / F10 accelerators — if you want the chrome row back completely, this is the setting.

## Keyboard

| Key | Effect |
|---|---|
| `Alt+<letter>` | Open the menu whose label starts with `<letter>` (case-insensitive). `Alt+F` → File, `Alt+V` → View, `Alt+M` → brand menu. |
| `F10` | Open the first alphabetic menu (skips the brand menu whose label leads with a Nerd Font glyph). |
| `←` / `→` | Cycle to the previous / next menu (wraps). |
| `↑` / `↓` | Move highlight up / down within the open dropdown (skips separators). |
| `Enter` | Fire the highlighted item's command. |
| `<letter>` | Type-ahead: jump highlight to the next item starting with `<letter>`. Repeat presses cycle through matches (highlight-only) before `Enter` commits. |
| `Esc` | Close without firing. |

Two rules are worth calling out because they cut real footguns:

### Alt+letter reaches clipped menus

At narrow terminal widths (roughly under ~140 columns), menu words that don't fit before the centered workspace-chip cluster get clipped off the chrome row. The dropdown still paints — at a fallback origin just right of the last visible menu word — so `Alt+V`, `Alt+G`, `Alt+R`, `Alt+T`, `Alt+W`, `Alt+H` all work regardless of whether their parent word is drawn. Arrow-nav also walks through every menu, not just the visible ones.

This wasn't the case before 2026-08-09: the prior gate silently no-op'd on any invisible menu, so on a 120-column terminal the last six of the ten menus were unreachable from the keyboard. Now: every menu is one Alt-chord away at any width.

### Alt+letter is inert while an overlay is open

If a picker, prompt, settings overlay, workspace picker, no-pane cmdline, or the vim `:` cmdline is up, `Alt+letter` falls through to the overlay instead of dropping a menu on top of it. That matches VS Code's behavior — a keyboard chord doesn't stack a new modal over an existing input.

Same rule for the mouse: clicking a menu word while a picker is open closes the picker and opens the menu, rather than layering both.

### Ctrl+chord while a menu is open closes the menu and runs the chord

`Ctrl+P` / `Ctrl+Shift+P` / `F1` / any global chord fired while a menu dropdown is showing closes the dropdown and dispatches the chord. The prior behavior was a silent no-op (the menu-key handler didn't recognize `Ctrl+letter`, and the accelerator gate refused because a menu was already open — nothing ever ran).

### F10 defers to DAP during a debug session

When `app.dap` is `Some` (an active Debug Adapter Protocol session), F10 falls through to `dap.next` (step over) instead of summoning the File menu. VS Code and IntelliJ convention. `Alt+F` / `Alt+E` / other letter accelerators still reach the menus during a debug session — only bare `F10` yields.

## Mouse

| Gesture | Effect |
|---|---|
| Click a menu word | Drop the dropdown below it. |
| Click an item | Fire the item's command and close the dropdown. |
| Click a submenu row | Open the submenu panel to the right of the parent. |
| Click outside | Close without firing. |
| Hover a word while another menu is open | Switch which menu is dropped (matches VS Code). |

Each word on the chrome row is padded to `" Label "` — a 2-cell click target on either side so trackpad users hit it without precision aiming.

## The menus

### Brand menu (`❯_  mnml`)

The leading menu, styled like the Apple menu on macOS. Four rows:

| Row | Command |
|---|---|
| About mnml… | `view.about` |
| Settings… | `view.settings` |
| Quit mnml | `app.quit` |

`Alt+M` opens it (matching the first alphabetic character of the label).

### File

The full new / open / save / close surface. Recent files render as a submenu populated live from `app.recent_files` (cap 10) — when the list is empty, the row reads `(no recent files)`.

| Row | Command |
|---|---|
| New file | `file.new` |
| Open file… | `picker.files` |
| Add folder to workspace… | `view.add_workspace` |
| Open recent file ▸ | (submenu — up to 10 recent + Clear recent files) |
| Switch workspace… | `view.switch_workspace` |
| Save | `file.save` |
| Save all | `file.save_all` |
| Close tab | `buffer.close` |
| Settings… | `view.settings` |
| Quit | `app.quit` |

There's no `Open recent file (picker)…` row — `Ctrl+R` covers that path independently.

### Edit

Find + replace, in-buffer and across the workspace.

| Row | Command |
|---|---|
| Find… | `find.find` |
| Find next | `find.next` |
| Find previous | `find.prev` |
| Replace… | `find.replace` |
| Find in files… | `find.grep` |
| Replace in files… | `find.grep_replace` |

### Selection

Selection expansion + multi-cursor. All rows fire editor operations that work identically in both vim and standard input modes.

| Row | Command |
|---|---|
| Expand selection | `lsp.selection_expand` |
| Shrink selection | `lsp.selection_shrink` |
| Add cursor above | `editor.add_cursor_above` |
| Add cursor below | `editor.add_cursor_below` |
| Add cursor at next match | `editor.add_cursor_at_next_word` |
| Select all occurrences | `editor.select_all_occurrences` |
| Clear extra cursors | `editor.clear_extra_cursors` |

### View

Toggles for the panels, chrome, and theme. This menu grew the most in the 2026-08-09 sweep — new rows for hover-help and workspace status dots landed alongside a rename and a deletion.

| Row | Command |
|---|---|
| Command palette | `view.discovery` |
| Toggle left panel | `view.toggle_tree` |
| Toggle right panel | `view.toggle_right_panel` |
| Cycle menu bar (always / auto / hidden) | `view.menu_bar_cycle` |
| Toggle word wrap | `view.toggle_wrap` |
| Toggle zen mode | `view.zen` |
| Toggle hover-help strip | `view.toggle_hover_help` |
| Toggle workspace status dots | `view.toggle_workspace_dots` |
| Commands reference… | `view.commands_reference` |
| Pick theme… | `theme.pick` |
| Toggle theme | `theme.toggle` |

Renames + removals in this menu:

- **Toggle left panel** — was **Toggle file tree**. The panel hosts Git / Integrations / Agents / HTTP / Findings depending on activity-bar selection, so the label was misleading. The `EC02` codicon matches the sidebar-toggle chip in the palette bar.
- **Toggle bufferline** — removed. It only affected the launcher-cluster row on the empty welcome screen (which the welcome body renders anyway); the toggle was inert. Deleted alongside the `bufferline_visible` field and `:set [no]bufferline` ex-arms.
- **Toggle hover-help strip** — toggles the Ableton-style info box docked to the bottom of the left panel. See [Hover-help](/manual/hover-help/) for the full surface.
- **Toggle workspace status dots** — toggles the `● / ○` markers on workspace-root rows in the tree. See [Workspaces → Workspace status dots](/manual/workspaces/#workspace-status-dots).

### Go

Navigation. The Go-to-line + Go-to-definition rows lead with a 3-space spacer because no confidently-correct Nerd Font glyph matches "jump to line" cleanly — icons only land where the glyph reads unambiguously as the action.

| Row | Command |
|---|---|
| Go to file… | `view.discovery` |
| Go to line… | `editor.goto_line` |
| Go to definition | `lsp.peek_definition` |
| Previous buffer | `buffer.prev` |
| Next buffer | `buffer.next` |
| Last buffer | `buffer.last` |

### Run

The DAP surface. Step-in / step-out use `F103` / `F102` (fa-angle-double-down / -up) rather than single arrows so the chevron pair reads as "descend into a frame" vs. "ascend out of one" — matching VS Code's convention.

| Row | Command |
|---|---|
| Start debugging | `dap.run` |
| Toggle breakpoint | `dap.toggle_breakpoint` |
| Conditional breakpoint… | `dap.toggle_breakpoint_conditional` |
| Step in | `dap.step_in` |
| Step out | `dap.step_out` |
| Step back | `dap.step_back` |

Bare F-key chords (`F5` start, `F9` toggle, `F10` step over, `F11` step in, `Shift+F11` step out) fire the same commands directly during an active session.

### Terminal

Pty pane spawns and management.

| Row | Command |
|---|---|
| New terminal (split below) | `term.shell` |
| Toggle scratch terminal | `term.scratch_toggle` |
| Rename terminal | `term.rename` |

### Window

The biggest menu — tabs, splits, layout reshape, focus movement, and the AI-grid layout toggle. Grouped by separators (menu items are flat; no submenu nesting yet).

Reopen / close / pin:

| Row | Command |
|---|---|
| Reopen closed tab | `buffer.reopen` |
| Close other tabs | `view.close_others` |
| Pin / unpin tab | `buffer.pin_toggle` |

Splits — the icons here (`EB56` split-right, `EB57` split-down) match the H/V chips in the top-right cluster so the menu item and the toolbar icon read as the same control:

| Row | Command |
|---|---|
| Split right | `view.split_right` |
| Split down | `view.split_down` |
| Close split | `view.close_split` |
| Equalize splits | `view.equalize_splits` |
| Auto-equalize on split / close (toggle) | `view.toggle_auto_equalize_splits` |

Layout reshape — reversible via each other:

| Row | Command |
|---|---|
| Merge splits into tabs | `layout.merge_to_tabs` |
| Spread tabs into splits | `layout.spread_to_splits` |

Resize + focus:

| Row | Command |
|---|---|
| Grow split width | `view.split_grow_width` |
| Grow split height | `view.split_grow_height` |
| Focus split left | `view.focus_left` |
| Focus split right | `view.focus_right` |
| Focus split up | `view.focus_up` |
| Focus split down | `view.focus_down` |

AI-grid layout toggle — same commands the palette-bar AI chip menu fires:

| Row | Command |
|---|---|
| AI layout: Grid (splits) | `view.ai_layout_grid` |
| AI layout: Tabs (stack in leaf) | `view.ai_layout_tabs` |

Restart:

| Row | Command |
|---|---|
| Restart mnml | `app.restart` |

### Help

Docs + welcome + about.

| Row | Command |
|---|---|
| Welcome | `view.welcome` |
| Keybindings & help | `view.help` |
| Commands reference… | `view.commands_reference` |
| About mnml | `view.about` |

## Glyphs

Every menu item leads with a Nerd Font glyph or a 3-space spacer that preserves alignment. The rule: **an icon appears only where a widely-recognized glyph matches the action semantically**; otherwise the row leads with a spacer.

For example the File menu uses `F0193` (single floppy) for Save but skips an icon for Save all — the closest match (`F0224` / trash-like glyphs) reads wrong. Similarly the Go menu's "Go to line…" and "Go to definition" rows lead with spacers because no Nerd Font glyph is a confidently-correct fit for "jump to line".

Where a glyph doesn't render (missing from the terminal's `font-codepoint-map`), it tofus as an empty box — the same width as the intended glyph, so alignment is preserved. To audit which manifest glyphs won't render on your system, see [`integrations.audit_glyphs`](/manual/integrations/installing/#diagnostics).

## Menu items from installed integrations

Any installed integration whose manifest declares `[[menu_bar]]` entries contributes rows to the menu bar (via `path = "File > Send via Slack"` slash-separated addresses). See [Launcher manifests → menu-bar entries](/manual/integrations/launcher-manifests/#menu_bar--menu-bar-entries) for the schema.

## Next

- [Hover-help](/manual/hover-help/) — the info box the View menu's hover-help toggle drives
- [Workspaces & the file rail](/manual/workspaces/) — the workspace status dots the View menu's dot toggle drives
- [Right side panel](/manual/right-panel/) — the panel the View menu's right-panel toggle drives
- [Chord chains](/manual/chord-chains/) — how leader-based chords compose alongside the menu-bar accelerators
- [Cheatsheet — all chords](/manual/cheatsheet-all/) — every default key across both input modes
