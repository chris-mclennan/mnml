# mnml mouse-discoverability hunt — VS-Code-user persona (2026-06-07)

**Persona:** VS Code refugee, mouse-first. Keyboard for typing only — no `Ctrl+P`, no `Ctrl+S`, no `Ctrl+Shift+P`. If a feature isn't a click or hover away, the user assumes it doesn't exist.

**Severity counts**: SEV-1: 1 / SEV-2: 9 / SEV-3: 9.

## Executive summary

How mouse-discoverable does mnml feel? **Mostly yes for navigation and git, mostly no for editing fundamentals.** The chrome around the editor — tabs (open / close / reorder / context menu), file tree, activity rail, git-graph pane ([+]/[−] stage buttons, branch chips, Undo/Redo), workspace chip's context menu — all feel mouse-native. But the **moment-to-moment editing surface is keyboard-only**: there's no Save button anywhere (only `Ctrl+S`), right-click on text gives no context menu, Alt+click does not add a second cursor, hover over a symbol does not show LSP info, and both of the overlays a new user is most likely to open — Settings and "+ Add integration" — are explicitly keyboard-only.

Summary: **"the perimeter is friendly, the interior is for the vim crowd."**

## Top 3 worst

### 1. SEV-2 — No Save button anywhere
The statusline has 7+ chips (mode, mixr, LSP, size, clock, workspace, filetype) but none save. The bufferline has a `●` dirty dot, but clicking it triggers a *close*. The only mouse path to save: type changes → click `●` on bufferline → in the "Unsaved changes" modal, click `[S]ave`. **That workflow saves AND closes the tab**, which is wrong when the user just wanted to save. Right-click tab shows Close / Close-others / Close-all / Copy-path — no Save.

### 2. SEV-2 — Editor body has no right-click context menu
Right-clicked on text at row 2 col 42 — nothing. The gutter has an excellent menu (Toggle breakpoint, Go to definition, Find references, Hover info, Peek change, Toggle blame, Open at remote), but right-click on text gives nothing. Every other surface in mnml has a right-click menu — tree rows, tabs, workspace chip, mode chip. Text being the blind spot is jarring.

### 3. SEV-2 — Settings + Add integration overlays explicitly swallow clicks
Both have clear layouts that scream "click me." Both swallow every click except scroll-wheel. Source confirms by design (`src/tui.rs:2485` + `:2496`). The earlier 2026-06-07 fix for "+ Add integration" added click-outside-to-dismiss, but click-on-row to install / select still doesn't fire.

## SEV-1

**Silent exit during multi-tab + split + middle-click sequence.** After: open `main.rs` → click TABS `+` → drag tab to reorder → click tree right-click "Open in split" → drag splitter → middle-click on tab around col 50 row 1 — process exited. No stderr, no backtrace. Couldn't isolate a clean repro. The combination of tab-reorder-into-split-pane plus middle-close on a non-active tab is suspect. Marking SEV-1 because the loss is silent.

## SEV-2

- No Save button anywhere (top finding #1)
- No right-click context menu on editor text body (top finding #2)
- Settings overlay swallows clicks (top finding #3)
- "+ Add integration" overlay swallows row-click (partially fixed in 28418dd — click-outside-to-dismiss landed, click-on-row still TODO)
- **No Settings gear on the activity rail.** First place a mouse user clicks for preferences. mnml has File/Search/Git/Debug/Integrations — no gear.
- **Alt+click does not add a second cursor.** Tested: single-click placed cursor at col 30, Alt+click at col 50 → cursor jumped to col 18 (silent no-op).
- **Hover over text in editor does not show LSP info.** Gutter right-click menu has "Hover info" so the wire exists, just not on mouse-hover.
- **Drag-select moves cursor but creates no selection.** `Sel N` indicator absent (double-click selection populates `Sel` fine). `drag_select` is armed but SelectStart isn't extending across the drag.
- **Find-in-file (`Ctrl+F`) has no chip / button / menu entry.** Search rail icon is workspace-wide search; no in-buffer find affordance.
- **Open Terminal (`Ctrl+T`) has no chip / button.** Only chord.

## SEV-3

- **Welcome modal dismisses on first left-click anywhere, including inside the tree** — clicking `subdir` to expand it instead dismisses welcome AND selects the row but does NOT toggle.
- **Mode chip silent toggle.** Click `EDIT` chip "to see what it does" → now in NORMAL mode with j/k/h/l doing weird things. Right-click on chip is sensible (Use vim / Use standard); left-click silent toggle traps user.
- **Hover tooltips inconsistent.** Working: bufferline tree-row icons (new file / new folder / refresh tree). NOT working: bufferline `+` new-tab, `●━` theme, TABS close-x, all statusline chips, all activity rail icons, tree git-status badges. Matches the mnml mouse hunt's missing HoverChip variants.
- **Tree-row right-click on a Modified file (`M` badge) shows same context menu as clean file** — no Stage / Unstage / Discard / View diff.
- **Start-screen "Shortcuts" list not clickable.** Display-only — VS Code makes these clickable.
- **`rs` filetype chip in statusline does nothing on click.** VS Code users click this to switch language mode.
- **Branch chip in statusline opens full git graph instead of branch-switcher menu.** Left-click → switcher; right-click → graph would be more VS-Code-native.
- **Scrollbar isn't draggable.** Click thumb at col 118 row 25 — no jump-to-position, no drag.
- **No tooltips for tree git-status badges** (`?` untracked, `M` modified, `A` added).
- **`‹` back-nav chip on bufferline does not visibly do anything.** No toast, no state change. If history is empty, a "nothing to go back to" toast would help.

## What DOES work well (the perimeter)

- File tree single-click → preview tab, right-click full menu, drag onto folder prompts move
- Bufferline tabs: drag-reorder, middle-close, close-x, `+`, right-click menu
- Workspace chip right-click: Worktrees / Switch workspace / Add workspace / Refresh / Reveal in Finder
- Gutter right-click menu: 8 items (best mouse-contextual surface in the app)
- Splitter drag
- Git graph pane: full git GUI experience
- Activity rail click-to-switch (5 panes)
- Palette fully clickable
- Theme picker, Recent Files dropdown

## Methodology note

IPC `row` is 0-indexed (screen.txt awk line N → IPC row N-1). IPC `col` is character column (Python `s[i]`), not byte offset. The IPC schema doc calls them "cell coordinates inside the virtual screen" — correct but didn't save the agent from initially treating them as 1-indexed. **One-line clarification in `src/ipc/mod.rs` docs would help next driver.**
