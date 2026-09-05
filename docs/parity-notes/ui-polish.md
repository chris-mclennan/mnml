# Parity notes — branch `ui-polish` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## `## UI & theming` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Right panel — persisted visible + width | partial | done | `src/app.zig` (`initWith` seeds the slot), `src/app/settings.zig` number rows | `ui.right_panel_visible` / `ui.right_panel_width` read at init; the session restore still overrides; the default is 40 (the Rust 32 sized a panel that never held TODOS / NOTES / FINDINGS — the Zig chrome is tuned to 40, and 32 drops the sort chip to its icon); test "number rows: → steps the right panel width…" |
| Keyboard right-click `Shift+F10` | missing | done | `context_menus.contextMenuAtFocus` | tree row / panel row / active tab, anchored at the thing's rect |
| Menu glyphs | missing | done | `src/ui/menu_glyph.zig`, `render.paintMenuRows` | one glyph per command group, `MenuItem.icon` overrides; test "the + menu: five ▸ sections…" |
| `ascii_icons` blanks glyphs | partial | done | `menu_glyph.forItem(it, ascii)`, `render.paintMenuRows` | every group glyph has a one-character ASCII twin (`Entry.fallback`) and a row's own icon its `MenuItem.icon_ascii`; the column paints the twin under `ui.ascii_icons`, as every other glyph site does — the glyph audit checks each site (same test, ascii half) |
| Submenus | missing | done | `MenuState.sub`, `context_menus.openSubmenu`, `dispatch.overlayKey` | → / l / Enter / click open, ← / h step back, `.menu_item{1, i}` hits |
| Curated five-section `+` menu | missing | done | `context_menus.plus_sections`, `openNewTabMenu` | New / Open / Panels / Tools / Integrations, pinned rows first; main's `New dock note` joined the New section (seven rows) |
| Per-row kebab pin / hide / copy id | missing | done | `context_menus.openCuration`, `menu.pin_row` / `unpin_row` / `hide_row` / `copy_id` | ⋯ on the focused leaf row, or → on it; test "curation: → on a child row offers Pin / Hide / Copy…" |
| `plus_menu_pinned` / `hidden` | partial | done | `App.plus_pinned` / `plus_hidden`, `context_menus.persistPlus` | seeded from the config, written back to the home config, re-seeded on reload |
| F1 click-discovery overlay | partial | done | `src/app/discovery.zig` (`drawOverlay`, `explain`) | every hit tinted and labelled; the next click explains; `tests/e2e-zig/ui_discovery_f1.test` |
| Hover tooltips on chips | missing | done | `discovery.describe`, `src/ui/tooltip.zig` | `ui.hover_tooltip` popup and the `ui.hover_help` rail box; wake on motion only |
| Right-click menus throughout | partial | done | `context_menus.openStressMenu` / `openBranchMenu` / `openDiagnosticsMenu` / `openBellMenu` / `openToastMenu` | chip, toast and statusline menus |
| Inline images in the preview | missing | done | `ui/md_view.zig` (`renderWith` / `drawWith` / `Placement`), `md_preview.draw` | `ui.md_image_rows` per standalone image; test "images: a standalone ![alt](src) reserves rows…" |
| `render_markdown` inline in the editor | missing | done | `ui/editor_view.zig` (`// ── ui toggles ──`), `view.toggle_render_markdown` | landed in `1cf0904`; marks concealed off the cursor line |
| Preview tabs — images | missing | done | `src/app/image_pane.zig` (`open` replaces the preview tab in place), `PaneStore.findImagePreview` | `tests/e2e-zig/ui_image_preview.test` |
| Image rendering (kitty / iTerm2) | missing | done | `src/image/{root,kitty,iterm2,sixel,painter}.zig`, `tui/loop.zig` | kitty by probe, iTerm2 by `TERM_PROGRAM`, sixel for foot / mlterm, `MNML_IMAGE_PROTOCOL` override; text fallback headless |
| Stress meter — hover numbers | missing | done | `discovery.describeSegment` (`.stress`) | p50 / p95 / max / n in the tooltip |
| Stress meter — right-click Reset / Copy / Toast | partial | done | `context_menus.openStressMenu`, `perf.copy_stress` | |
| Toast right-click menu | missing | done | `context_menus.openToastMenu`, `toast.dismiss_clicked` / `copy_clicked` | |
| Undo chip beside the stack | missing | done | `App.armUndo` / `takeUndo`, `ui/toast.drawUndo` | armed by `buffer.close_others` / `close_right`; `tests/e2e-zig/ui_undo_chip.test` |
| Bell chip — three states | partial | done | `render.drawStatusline` (`bell_seg`) | idle `○`, yellow count, red count; no clock beside it (`ui.clock` stays unread) |
| Clickable statusline | partial | done | `ui/statusline.zig` (`Seg.id`), `dispatch.mouse` `.statusline_seg`, `render.SegId` | branch / diagnostics / AI / bell / stress / indent / encoding / transfers (right-click cancels) / input style; the host lanes (`dyn_left` / `dyn_right`, `seg_dyn_base = 0x100`) sit above the app's ids; `tests/e2e-zig/ui_statusline_clicks.test` |
| Settings overlay | done | done | `src/app/settings.zig` | 39 discrete rows + 9 number rows (`‹ [32] ›`) |

Rows that stay as they are: `file.cut` / `copy` / `paste` / `duplicate`
and the Ctrl+X/C/V/D chords (the file manager), `<leader>tr`, the
palette bar's integration `+` and narrow-drops-TABS, `menu.glyph_audit`
(spec only), `ui.external_browser`, the Clock, the stress meter's
bufferline copy, `Alt`-drag copies.

## `## Workspace trust` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| `RESTRICTED` statusline chip | missing | done | `ui/statusline.zig` (`Info.restricted`, `seg_restricted`), `render.drawStatusline` | click runs `workspace.review_trust`; test "review on a trusted workspace lists the claims; Forget…" |
| `workspace.review_trust` | missing | done | `src/app/workspace_trust.zig` | untrusted: the first dialog again; trusted: the claims re-read from disk with Keep / Forget |

`trusted.forget` (new id) drops the store line (`workspace_trust.removeEntry`)
and reloads under `.ask`.

## Counts

Command ids: 901 — main's 892 plus nine (`trusted.forget`,
`toast.dismiss_clicked`, `toast.copy_clicked`, `perf.copy_stress`,
`menu.pin_row` / `unpin_row` / `hide_row` / `copy_id`,
`editor.set_tab_width`); every one with a runner; `docs/commands.md`
regenerated (47 groups). F1 moved from `view.help` to `view.discovery`.

Rebased onto main `6149e99` (the `misc`, `files`, `panels`, `editor-ex`, `lsp-more` and `git-more` merges; `editor_view.Doc` carries the toggle block beside `labels` / `virtual_text` / `virtual_lines`):
the tips cover `.tab_close` and `.dock` hits; `menu_glyph.forItem` knows
`ai_profile` / `dock_set` rows; `Pane.image` sits beside `files` /
`tests` / `flaky` / `ai_apply` in every switch; the NOTES and TODOS
smoke tests run at the shipped 40.

## Checks run

- `zig build test` (Debug): 881 pass, 1 skipped (803 in the main
  binary); ReleaseSafe: see the branch report.
- Break-checks: `info.restricted and false` in `ui/statusline.zig` →
  "the RESTRICTED chip follows the file name…" fails; an early `return`
  in `md_view.flushPlacement` → "images: a standalone ![alt](src)
  reserves rows…" fails. Both through `tools/break-check.sh`, which
  confirms the break landed before running.
- Corpus, gate and width sweep: see the branch report.
