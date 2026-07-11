# mnml VS Code mouse-user hunt — 2026-07-10

## Executive summary

**14 findings: 0 SEV-1, 6 SEV-2, 8 SEV-3.**

Stability was excellent — no crashes, no hangs, no data loss across dozens of clicks, drags, split creations, tab reorders, and menu opens. **Could a VS Code mouser get their day's work done without a chord?** Mostly yes: gear + `File` menu + right-click context menus cover the major actions, so `Ctrl+S`, `Ctrl+,`, `Ctrl+Shift+P` are all unnecessary. The one hard "stop" for a VS Code muscle-memory user is **no right-click context menu inside an editor pane's body** — that's the most-clicked affordance in VS Code and its absence is jarring. Beyond that, the biggest polish gaps are around **focus routing** (some clicks visibly select a target but don't route keystrokes there) and **settings rows only cycle-forward on click** with no way to jump directly to a value.

Explored: activity bar (Explorer / Http), tree (expand/collapse, context menu, up-nav `..`, action icons, workspace right-click, refresh), bufferline (click, middle-click, X, drag-reorder, drag-to-split, new-tab, theme toggle, window close), palette bar (all 6 chips), Request pane ({{VAR}} left+right-click, `[⇔]` split chip, divider click+drag, Send), settings overlay (row click cycle, Save/Cancel), gear + File + Selection menus, integration chip (left + right), statusline chips, right panel (open, drag-resize, host Outline, `×` close, "too narrow" hint), Shift+F10, hover tooltips, scroll-wheel, Alt+click multi-cursor.

**No SEV-1 findings.**

## SEV-2 findings

### [SEV-2] #1 — Right-click inside editor pane body shows no context menu
`{"cmd":"click","col":63,"row":2,"button":"right"}` on `lib.rs` body → nothing. Every other surface has right-click semantics (tree row, tab, workspace header, integration chip, activity bar icon, gear, several statusline chips) — only the surface users hit most often has none. A minimal 4-item menu (`Cut / Copy / Paste / Command Palette…`) would close the loop.

### [SEV-2] #2 — HTTP-panel `/ filter` row: click shows focus indicator but keystrokes route to previously-active pane
Click the `/ filter` row: placeholder switches from `/ filter` to `type to filter…` with a cursor (visible focus indicator). Type `api` — text is inserted into the Request pane's URL bar, not the filter. Filter stays empty. Visual focus indicator lies about where keystrokes will go.

### [SEV-2] #3 — Opening a Request pane from the tree leaves focus in the tree; clicks on the tabs strip / URL row / method chip don't recover it
`status.json` reports `focus:"tree"` after `click col 68 row 4` (URL row), `col 80 row 9` (tab strip), even though those clicks visibly fire pane actions (opening prompts, cycling values). Only a click deep inside the body content area (`col 60 row 30`) shifts `focus:"pane"`. Same shape observed for an editor pane (`status.json`) — a click on the first content row didn't focus, but a click a few rows down did. Next-keystroke lands in the previous pane.

### [SEV-2] #4 — Settings rows only cycle-forward on click; no way to click a specific value or open a dropdown
`Line numbers` row starts `[absolute]`. Click on the word `relative` → advances to `[off]`. Click on the word `off` → advances to `[relative]`. Any click cycles by +1, ignoring the value clicked. Rendered `[bracket]` visually reads as a radio button but isn't. VS Code / macOS convention: click the value you want. Painful for 5-item enums.

### [SEV-2] #5 — Middle-click and right-click on tabs inside a horizontally-split bufferline are dead
After `split_strip:*:Horizontal`, `bufferline_tab:*` rects disappear entirely from `rects.json`. Middle-click on a tab in the split does nothing (worked in single-pane bufferline). Right-click doesn't open the tab menu. Only left-click to switch survives.

### [SEV-2] #6 — Left-click on a `{{VAR}}` token and "Jump to definition" from the right-click menu both fail to open the env file
With `.mnml/env/dev.env` defining `API_URL=https://example.com` and `api.http` referencing `{{API_URL}}/users`: left-click on the var → no navigation, no toast, focus stays in tree. Right-click → menu appears with `Set value… / Jump to definition / Copy variable name`, but clicking `Jump to definition` just dismisses the menu — `dev.env` never opens. Silent no-op is the worst outcome; either open the sole env file as a fallback or toast "no active env selected".

## SEV-3 findings

### [SEV-3] #7 — Save-file affordance is hidden inside menus; no visible button, no dirty statusline chip
Only mouse paths to `file.save`: `File → Save`, `Shift+F10` on a tab (has Save), or… that's it. No floppy icon in chrome, no click-to-save on the tab's `●`, no autosave chip on statusline even when dirty. `Save` is missing from the tab right-click menu (#8). A Save icon next to the sidebar / right-panel toggles, or a dirty-file chip on the statusline, would close this.

### [SEV-3] #8 — Tab right-click menu is missing `Save`, `Pin tab`, `Copy relative path` — Shift+F10 menu on the same tab has them
Right-click menu: `Close / Close others / Close all / View source / Copy path / Reveal in Finder / Split right/down/left/up`. Shift+F10 menu: adds `Save / Pin tab / Copy relative path / Copy absolute path`. Right-click should be a superset, not a subset.

### [SEV-3] #9 — Hover tooltips need ~1000–1500ms of stable hover, not the documented 500ms
`HOVER_TOOLTIP_DELAY_MS = 500` per `src/app/mod.rs:77`, but every chip I hovered (clock, mode, tree.refresh, integration) failed to render tooltip after `wait_ms:500` or `wait_ms:800`, and reliably showed only after `wait_ms:1200–1500`. Feels like tooltips don't exist until you park the pointer.

### [SEV-3] #10 — Hover between adjacent statusline chips leaves a stale tooltip label on-screen
Hover `col 75, row 38` (LnCol) → wait 800 → hover `col 82, row 38` (Clock) → wait 800 → hover `col 2, row 38` (Mode) → wait 700 → snapshot: tooltip renders with `click: goto line` (LnCol label) while pointer is over the Mode chip. Only after moving into the editor and back does the correct Mode label appear.

### [SEV-3] #11 — Drag on Request pane's edit-split divider snaps to next ratio instead of tracking cursor
`{"cmd":"drag","from_col":71,"from_row":10,"col":100,"row":10}` on the `request_edit_split_divider` → divider ends at col 83 regardless of drag distance (the same next-ratio position a single click cycles to). Feels stuck.

### [SEV-3] #12 — Ctrl+click on a symbol without an LSP running gives zero feedback
Cursor moves under pointer (same as unmodified click); no toast, no statusline hint. Mouser can't tell if the modifier was recognized or if Ctrl+click just does nothing. VS Code posts "No definition found". Cheap fix: rate-limited toast "no LSP running".

### [SEV-3] #13 — Tree action icons (+ file, + folder, refresh, pull, collapse-all) have no visible affordance until hovered ~1s
Icons draw identically to the ▼/▶ chevrons elsewhere in the tree — a first-time mouser sweeps past them because they read as decoration on the workspace header. Combined with #9, discoverability is poor. A subtle bg shade on the icon-strip row would close it.

### [SEV-3] #14 — Top-right `×` (`bufferline_window_close`) in the palette bar does nothing on left-click, even with dirty tabs
Click `col 118, row 0` → no visible effect. `ps` confirms the mnml process is still up. The `×` reads as VS Code's window-close button (right-most × in a top bar), so a mouser expects a quit prompt or close-tab prompt. Getting nothing is confusing.

## Positive observations (anti-regressions)

- Every right-click I fired that landed on a real target opened an actionable menu — no dead right-clicks (except editor body — see #1).
- Alt+click multi-cursor works end-to-end.
- Drag-to-split (tab out of bufferline into editor area) creates a clean new split.
- Drag-to-reorder tabs within a single bufferline: position 1 → 4 landed at 4.
- `..` up-nav row opens the parent directory as the workspace.
- Right panel: toggle, drag-resize, host Outline, `×` close, narrow "too narrow" hint — all documented behavior worked.
- Palette bar `‹  ›` back/forward chips actually navigate file history.
- Middle-click closes a tab in single-pane bufferline.
- Scroll-wheel over editor works.
- `gear` / `File` / `Selection` menus give a mouser everything for basic file ops.
- Settings overlay `Save` / `Cancel` buttons work on click.

**Environment**: mnml `6b1c96cc6-dirty` from `~/Projects/mnml/target/release/mnml`, headless standard-mode, scratchpad workspace with a Rust file, `large.txt`, `api.http` referencing `{{API_URL}}`, `.mnml/env/dev.env` defining that variable.
