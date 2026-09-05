# Parity notes — branch `files` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| Files pane (`Pane` variant, listing, sorts, hidden toggle, filter, preview, breadcrumb, `files.open` / `open_split`) — M | remaining | done | `src/app/files_pane.zig` tests "listing: dirs first by name…", "the pane in the app…", "mouse: a row press…", "preview: p opens…"; `src/ui/files_view.zig` tests; `tests/e2e-zig/files_pane.test` |
| Multi-select with path-keyed marks and mark-aware operations / menus — S | remaining | done | `files_pane.zig` test "marks are keyed by path…" and "move_to acts on the marks…"; `file_clipboard.zig` test "a Files pane's marks are the subject…"; `tests/e2e-zig/files_trash_clipboard.test` |
| Workspace trash: undoable delete, "Delete permanently", `files.trash` / `restore_from_trash`, the bounds — M | remaining | done | `src/app/trash.zig` tests "delete moves the entry to the trash…", "a directory round-trips…", "bounds: age prunes by the stamp…", "the confirm: Cancel is the default…"; `tests/e2e-zig/files_trash_clipboard.test` |
| Background transfer worker + statusline progress chip + `transfer.cancel_all` + the `:qa` guard — M | remaining | done | `src/app/transfers.zig` tests "a copy of a tree lands whole…", "a move within one filesystem renames; cancel_all…", ":qa refuses while a transfer runs…" |
| File clipboard: `file.cut` / `copy` / `paste` / `duplicate`, `-copy-N`, the Ctrl+X/C/V/D chords, menu rows — S–M (listed under UI & theming) | remaining | done | `src/app/file_clipboard.zig` tests "copyName: -copy, then -copy-2…", "the tree: copy then paste…", "the tree: Ctrl+X/C/V fire in both profiles…"; `tests/e2e-zig/files_trash_clipboard.test` |

## `## File manager` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Files pane as a `Pane` (`files.open`) | missing | done | `Pane.files`, `src/app/files_pane.zig`, `src/ui/files_view.zig` | name / size / modified / kind columns; the tab title is the directory's name |
| `files.open_split` dual layout | missing | done | `files_pane.openSplitCmd` | two browsers side by side, the right one focused, no scratch tab |
| Three sort orders | missing | done | `FilesPane.Sort`, `setSort` | dirs first in every mode; `s` cycles; the `sort:` chip cycles on click and lists on right-click; column headers sort |
| Hidden-file toggle in the Files pane | missing | done | `files.toggle_hidden`, the `.` chip | `.` / `H` keys |
| Clickable breadcrumb + destinations picker | missing | done | `files_view.drawCrumbs`, `files.destinations` | each segment is a target; `b` / the dir menu open the Go to… picker (workspace, home, Downloads / Desktop / Documents / Projects, trash, `/`, every open browser) |
| Per-row git status badges | missing | done | `files_pane.gitBadge`, `files_view.gitStyle` | the porcelain letter, a directory carrying its first child's |
| `p` preview from the listing | missing | done | `files_pane.preview` | opens in a leaf of its own, reused on the next `p`; focus returns to the browser. The preview COLUMN (the head of the cursor file) paints at ≥ 80 cells besides |
| `/`-filter | missing | done | `FilesPane.applyFilter`, `filter_input` pill | case-insensitive substring; `(n of total)` in the crumb row |
| `file.*` ops from a focused Files pane | missing | done | `file_clipboard.targetPaths`, `tree.zig` runners defer to `files_pane.{rename,moveTo,newFile,newFolder}Cmd` | one definition of the subject: a FOCUSED pane's marks, else its cursor row, else the tree's cursor row |
| Multi-select `Space` / `a` / `Esc` | missing | done | `FilesPane.toggleMark / markAll / clearMarks` | `v` marks the range from the anchor, `*` inverts; both respect the filter |
| Ctrl-click toggle, Shift-click range | missing | done | `files_pane.click` | Cmd-click too |
| Right-click acts on marks | missing | done | `files_pane.openRowMenu` | the menu is titled `Marked` when more than one is marked; every row's command resolves the marks |
| Marks keyed by path | missing | done | `FilesPane.marks: StringHashMap` | survive a re-sort, a reload, a hidden toggle and navigating away; a mark whose file vanished is dropped on reload |
| Background transfers on a worker | missing | done | `src/app/transfers.zig` (`Io.Group`, `AppEvent.transfer`) | copy / move; a move on one filesystem is a rename; cancel stops between files and removes what the transfer created |
| Statusline transfer chip | missing | done | `transfers.chip` in `render.drawStatusline` | `⇄ 42% 3.1M/s`, `⇄2 …` for two; `sizing…` first; hidden at rest |
| `transfer.cancel_all` | missing | done | `transfers.cancelAllCmd` | |
| `:qa` refuses mid-transfer | missing | done | `ex.zig` (one delimited block) | toast + refusal; `:qa!` overrides |
| Undoable delete → trash | missing | done | `src/app/trash.zig` | `<data root>/trash/<workspace hash>/`, entries stamped `<unix>-<name>`, origins in `….index.zon` beside the trash |
| "Delete permanently" in the confirm | missing | done | `trash.confirmDelete` | `[D]elete / Delete [P]ermanently / [C]ancel`, Cancel the default; inside the trash only the permanent form |
| `files.trash` / `restore_from_trash` | missing | done | `trash.openTrashCmd / restoreCmd` | the trash is a Files pane titled `Trash`; restore refuses when the origin exists again |
| Trash bounds (7 d / 512 MB / 256 MB) | missing | done | `trash.prune`, `trash.tick` | age by the stamp, oldest-first eviction over the total, an oversize delete skips the trash; on the first tick and every ten minutes, and after every delete |
| Editor breadcrumb row | partial | partial | — | unchanged (not this branch) |

`file.cut` / `file.copy` / `file.paste` / `file.duplicate` (the `UI &
theming` rows) are real runners in `src/app/file_clipboard.zig`.

## Counts

`## File manager` in the summary table moves from 0 done / 1 partial /
0 cut / 21 missing to 21 done / 1 partial / 0 cut / 0 missing. Command
ids: 854 after the `misc` merge (eighteen `files.*` verbs on top of
its 836), every one with a runner;
`docs/commands.md` regenerated.

## Deliberate differences from Rust

- The trash lives under the data root keyed by a hash of the workspace
  (`<data root>/trash/<wyhash>/`), not `<workspace>/.mnml/trash` — a
  deleted file must not reappear in the tree, in grep, or in git status.
  With no data root (the unit tests) it falls back to `.mnml/trash`.
- The origin index is `<trash>.index.zon` BESIDE the trash directory, so
  it never paints as a row among the user's deleted files.
- Trash entries are named `<unix stamp>-<name>` (a counter when the
  name repeats within a second) and the age bound reads the stamp, not
  the mtime — a rename does not touch the mtime, so an untouched file
  would otherwise be pruned on the tick it was trashed.
- The tree's Ctrl+X/C/V/D fire in both profiles (Rust parity: the tree
  never edits text); vim additionally gets ranger's two-key `yy` / `dd`
  and `P` on both the tree and the Files pane. `D` duplicates in both.
- `Move to…` from a Files pane acts on the marks and runs as one
  background move; the tree's own `Move to…` still moves its cursor row.
- The destinations picker has no volumes / recents sections; it lists
  the workspace, home and its usual folders, the trash, `/` and every
  open browser's directory.

## Checks run

- `zig build test` (Debug and `-Doptimize=ReleaseSafe`): see the branch report (rebased onto the `misc` merge before the split).
- `mnml-zig test` (the whole corpus): 231/232 — the one failure is
  `settings_persist_to_workspace.test`, which asserts TOML by design.
- `mnml-zig test tests/e2e-zig/files_pane.test tests/e2e-zig/files_trash_clipboard.test`: 2/2.
- `mnml-zig test --gate`: 47/47; `--gate --sizes 80x24,120x40,200x60`: 141/141.
- Break-checks: the preview's post-`openPath` re-fetch of the pane
  reverted to the stale `f.preview_pane = opened` → the `files_pane`
  preview test crashes (the second `p` finds a null preview pane); the
  `Move to…` prefill reverted to the bare `relPath(cwd)` → the
  `move_to` test fails (the typed folder appended to the absolute
  workspace path). Both confirmed in the file (`grep BREAK-CHECK`)
  before the run and restored from a scratch copy after.
