# Parity notes — branch `panels` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| NOTES and FINDINGS panels (the TODOS panel is the template) and their row menus; SESSIONS panel — S–M | remaining | done | `src/notes.zig`, `src/findings.zig`, `src/sessions.zig` (unit tests in each; `tests/e2e-zig/notes_panel.test`, `tests/e2e-zig/findings_panel.test`) |
| TODOS: the `.claude/`-aware action menu with the Claude Code / Codex fallback; the `.fixme(` / `.fail(` / `.skip(` scan; rescan on file change — M | remaining | done | `src/todos.zig` (`openRowMenu`, `pickAgent`, `test_markers`, `noteFileChanged` / `tick`; tests "mark done rewrites the file…", "the watcher's change event rescans once…") |
| Dock widgets — the whole tier (corners, Text / LogTail, presets, Overlay / Inline, opacity, kebab, drag-to-move with snap, session persistence) — L | remaining | done | `src/app/dock.zig`, `src/ui/dock_view.zig`, `src/core/dock.zig`; `tests/e2e-zig/dock_widget.test` |

## `## TODOs, notes & findings` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| `.fixme(` / `.fail(` / `.skip(` call sites | missing | done | `todos.matchLine`, `test_markers` | titled by the first string argument; never in markdown or a string |
| Rescan on file change, throttled | missing | done | `watch.check` → `todos.noteFileChanged`; `todos.tick` | 500 ms after the last change, a used panel only |
| Row menu → `.claude/` agents / commands / skills | missing | done | `todos.openRowMenu`, `pickAgent` | the agent row says what the fallback will do |
| "Fix with Claude Code / Codex" fallback | missing | done | `todos.openInAgent` | a pty pane to the right, the marker as the prompt |
| NOTES panel | missing | done | `src/notes.zig` | `<name>  <title>  <age>` |
| FINDINGS panel | missing | done | `src/findings.zig` | `<SEV> <name>  <title>  <age>`; frontmatter `severity:` / `status:`; resolved rows muted; `(N open of M)` |
| `notes.new` / `findings.new` | missing | done | `notes.newCmd`, `findings.newCmd` | seeded `note-N.md` / `finding-N.md`; a finding is written with the frontmatter template |
| `notes.refresh` / `findings.refresh` | missing | done | both `refresh` | scan workers on the todos shape |
| `⟳` chip right-click menu + auto-refresh | partial | partial | — | still left-click only; `ui.auto_refresh_off` still unread |
| Sort chip — click cycles, right-click lists | done (TODOS only) | done | `openSortMenu` in todos / notes / findings; `sessions.openSortMenu` | every list panel |
| Narrow-panel icon-only chip | missing | done | `src/ui/header.zig` ladder | full + count → icon + count → full alone → icon alone; tests at 26 / 30 / 34 / 40 / 50 in `findings.zig`, and the header's own |
| Four sort modes persisted for the three panels | partial | done | `todos.sort` / `notes.sort` / `findings.sort` | each persists `ui.<panel>_sort` |
| SESSIONS sort axis | partial | done | `sessions.sortCmd`, `sort_auto` / `sort_manual` | State / Manual; `J` / `K` build the manual order, persisted in `session.zon` |
| Row context menus (NOTES / FINDINGS / SEARCH / AGENTS) | missing | partial | `notes.openRowMenu`, `findings.openRowMenu`, `sessions.openRowMenu` | NOTES / FINDINGS / SESSIONS; SEARCH and AGENTS rows are other tracks |

Rows that stay as they are: the `⟳` chip's right-click menu and
`ui.auto_refresh_off` (the chip is a left-click rescan on every panel).

## `## Dock widgets` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Three-tier UI (middle tier) | missing | done | `render.zig` (`dock.draw` after the panes) | |
| Four corners + stacking + 50 % cap | missing | done | `dock.layout` | test "four corners anchor, a corner stacks inward, the stack stops at half the body" (break-checked) |
| `Text` content (`dock.new_text*`) | missing | done | `dock.promptNewText` / `acceptNewText` | |
| `LogTail` content (`dock.new_log_tail`) | missing | done | `dock.tailWorker`, `readTailInto`, `handle` | one read per widget per second, on the dock's `Io.Group` |
| `▼N` chip | missing | done | `dock_view.draw` | rows above the visible tail |
| Size presets | missing | done | `core/dock.Size` | Small / Medium / Large / Wide / Tall; 15–90 % clamp |
| Layout modes Overlay / Inline | missing | done | `dock.strips`, `bodyAfterStrips`, `layout` | strips tile left to right; each edge capped at a quarter |
| Opacity modes | missing | done | `dock.blend`, `dock_view.blendGround` | rgb blend at 45 %; other colours keep their cells |
| Kebab menu | missing | done | `dock.openMenu`, `MenuAction.dock_set` | current values ticked |
| Drag-to-move with snap | missing | done | `dock.mouse`, `continueDrag`, `dropTarget`, `applyDrop`; `dock_view.drawDrag` | ghost chip + landing preview; snap within 8 cells of a widget's centre |
| `dock.close_all` / `move_corner_next` | missing | done | `dock.closeAll`, `moveCornerNext` | |
| "New dock note" in the `+` menu | missing | done | `context_menus.openNewTabMenu` | |
| Session persistence of widgets | missing | done | `dock.capture` / `apply`; `session.Saved.dock`, `dock_hidden` | test "session round-trip: widgets, corners, sizes, placement, opacity and the hidden flag come back" |

Beyond the Rust rows: `dock.toggle` (hide / show all), `dock.add_preset`
(a picker: clock, git branch, log tail, note), `dock.edit`, `dock.rename`,
`dock.remove`, the Clock and Git-branch contents.

## Counts

`## TODOs, notes & findings` in the summary table moves from
9 done / 3 partial / 0 cut / 10 remaining to 20 done / 2 partial / 0 cut /
0 remaining (the `⟳` right-click menu and the SEARCH / AGENTS row menus
stay partial). `## Dock widgets` moves from 0 / 13 to 13 done.
Command ids: 830 → 857 (four TODOS, three NOTES, four FINDINGS, ten
SESSIONS, six dock — all Zig-only, listed in `docs/commands.md`).
