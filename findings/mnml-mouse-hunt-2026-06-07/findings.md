# mnml mouse bug-hunt — 2026-06-07

**8 findings: 0 SEV-1, 1 SEV-2, 7 SEV-3.** Stability excellent — no panics across ~600 click/hover/scroll events including a 200-event burst that processed in 34 ms. Mouse IPC is solid: malformed JSON gracefully logs `unknown`, out-of-bounds clicks (col=65535) don't crash, click-on-stale-chip-position is no-op. Most routing works. Interesting failures cluster around two themes: two modal overlays trap the mouse (no click-outside-to-dismiss), and the `HoverChip` enum is incomplete (Welcome promises tooltips on every chip but several categories have no variant).

## Worst-3

1. **`+ Add integration` overlay traps the mouse** — opens one click after dismissing welcome, no click-outside-to-dismiss, can only be closed via Esc. First-time users hit it within seconds.
2. **Editor mouse wheel moves the CURSOR instead of the viewport** — every other pane scrolls correctly. Quietly moves the user's cursor on every wheel-scroll.
3. **Activity bar + several bufferline icon chips have no hover tooltips** — Welcome promises "hover any clickable chip" but 6 categories aren't wired into `HoverChip`.

## Full findings

### [SEV-2] `+ Add integration` overlay is a mouse trap

**Source**: `src/tui.rs:2496-2503`. Mouse handler swallows all non-scroll events while overlay is open. Compare to the sibling `show_discovery_overlay` at `tui.rs:2507-2520` which correctly handles click-outside.

### [SEV-3] Settings overlay also no click-outside-to-dismiss
Same "swallow non-scroll, return" pattern at `tui.rs:2485-2492`.

### [SEV-3] Editor mouse wheel moves cursor not viewport
`src/app/dispatch.rs:466-476` — applies `MoveUp`/`MoveDown` ops instead of adjusting `b.scroll`. Every other pane arm (MdPreview, Diff, Request, Pty, Ai) adjusts `scroll` directly without moving cursor. Editor is the outlier.

### [SEV-3] Activity bar icons have no hover tooltip
`src/lib.rs:196` — `HoverChip` enum has no variant for activity bar icons. `ActivitySection::meta().tooltip` field exists but isn't read on the hover path.

### [SEV-3] Bufferline icon chips + palette top-bar arrows have no tooltips either
Same root: missing `HoverChip` variants. Affected rects: `bufferline_new_tab_button`, `bufferline_window_close`, `bufferline_theme_toggle`, `bufferline_overflow_left`, `bufferline_overflow_right`, `palette_back_button`, `palette_forward_button`, `palette_search_chip`, `palette_dropdown_button`.

### [SEV-3] Welcome overlay says "click outside to dismiss" but ANY click dismisses
`src/tui.rs:2471-2474`. Fix: gate dismiss on `!contains(welcome_rect, x, y)`, OR update border text to "click anywhere to dismiss" (one-line).

### [SEV-3] Pty tab strip `+` always launches Claude Code
`src/tui.rs:3261-3270`. Even when existing tab is a shell. No way to add another shell tab via mouse.

### [SEV-3] "New file in /" — bare slash when creating in workspace root
`src/app/mod.rs:3542` (and `:3554` for folders). `rel_path` returns empty when `parent == workspace`, so format string produces `"in /"`.

### [SEV-3] Scroll wheel doesn't clear active hover tooltip
`src/tui.rs:3871-3873`. Scroll arms take early-return path before `app.hover_chip = None;` runs.

## Note on build cache

The cached release binary (built 17:00) predated the new mouse IPC commands. Every `click`/`hover`/`scroll` logged as `{"event":"unknown",...}`. Rebuilt 20:14 to pick them up. Future bug-hunt sessions should `cargo build --release` before starting.

## Coverage

**Explored**: tree rail click-to-open + collapse/expand, workspace header + chips, bufferline tab click / middle-close / × close / `+` new tabpage / `‹›` overflow / tabpage chip switch + close / theme toggle / window close, palette top-bar back/forward/search/dropdown, statusline chips, activity bar all 5 icons, integration `+` chip + section toggle, settings overlay + wheel scroll, picker scroll/click/dismiss, context menus (open/accept/click-outside cancel), unsaved-changes prompt buttons, gutter right-click menu, pty pane tab strip `+`/`×`, editor ctrl+click / alt+click / double-click word-select / triple-click line-select / middle-click paste, scroll wheel routing, hover+scroll+click interactions, 200-event burst.

**Did not drive**: drag operations (IPC `click` is Down+Up at same coord, no Drag events — splitter drag / tab reorder / scrollbar drag / tree-edge resize need real Drag), LSP popup interactions, real subprocess pty interactions.

The new `drag` IPC command (just shipped after this hunt) closes the drag-event gap for future hunts.
