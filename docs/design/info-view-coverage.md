# Info View coverage — 2026-08-10

Audit-mode sweep against `src/lib.rs::HoverChip`, `src/menu_bar.rs`,
`src/ui/icons.rs` (tree renderer) vs `src/ui/info_view_copy.rs`.
Read-only pass; no source edits.

## Summary

- **HoverChip:** 32 / 90 variants have a curated entry (**36 %**).
  Indexed HoverChips (`HttpToolbarChip`) counted per concrete index.
- **Menu items:** 12 arms match a live menu row (**~16 %** of ~76 rows),
  but 2 of those arms are dead code (see Drift #1 + #2).
- **Tree languages:** 23 / 65 extensions the tree renderer recognizes
  have a language entry (**~35 %**). Directory copy is universal.
  Filename-specific rows (`package.json`, `.env`, `Dockerfile`, etc.)
  have no dedicated arm — only the `dockerfile` extension pass matches
  by coincidence.
- **Drift issues:** 4 (1 orphan command id, 2 misrouted / broken match
  guards, 1 stale chord).

Highest-signal gaps sit in the statusline (Phase-1 flagship — 11
statusline chips still fall through) and the palette-bar cluster
(back / forward / dropdown / add-integration — every user sees these).

---

## Gaps (ranked by visibility)

### Statusline family (11 gaps — highest signal, always visible)

- [ ] `HoverChip::StatuslineFile` — src/lib.rs:528
- [ ] `HoverChip::StatuslineDiagnostics` — src/lib.rs:532
- [ ] `HoverChip::StatuslineLanguage` — src/lib.rs:535 *(Phase-1 top-50 nominee)*
- [ ] `HoverChip::StatuslineSymbol` — src/lib.rs:538
- [ ] `HoverChip::StatuslinePr` — src/lib.rs:541
- [ ] `HoverChip::StatuslineMacroRec` — src/lib.rs:544
- [ ] `HoverChip::StatuslineFind` — src/lib.rs:547
- [ ] `HoverChip::StatuslineSel` — src/lib.rs:550
- [ ] `HoverChip::StatuslineProgress` — src/lib.rs:553
- [ ] `HoverChip::StatuslineBgTasks` — src/lib.rs:556
- [ ] `HoverChip::StatuslineAi` — src/lib.rs:559
- [ ] `HoverChip::StatuslineNowPlaying` — src/lib.rs:363 *(Phase-1 top-50 nominee — `mixr`)*
- [ ] `HoverChip::StatuslineMixrPlay` — src/lib.rs:426
- [ ] `HoverChip::StatuslineMixrFfwd` — src/lib.rs:428
- [ ] `HoverChip::StatuslineTestChip` — src/lib.rs:430

### Palette bar (5 gaps — every session hits these)

- [ ] `HoverChip::PaletteBackButton` — src/lib.rs:366
- [ ] `HoverChip::PaletteForwardButton` — src/lib.rs:368
- [ ] `HoverChip::PaletteDropdownButton` — src/lib.rs:370
- [ ] `HoverChip::PaletteAddIntegration` — src/lib.rs:400
- [ ] `HoverChip::PendingUndoChip` — src/lib.rs:506 *(palette-bar cluster)*

### Bufferline + tab strip (7 gaps)

- [ ] `HoverChip::BufferlineTabsLabel` — src/lib.rs:337
- [ ] `HoverChip::BufferlineNewRequest` — src/lib.rs:511
- [ ] `HoverChip::SplitStripButton(H)` — src/lib.rs:374 *(2 concrete: Horizontal, Vertical)*
- [ ] `HoverChip::SplitStripTermButton` — src/lib.rs:378
- [ ] `HoverChip::SplitStripAiButton` — src/lib.rs:381
- [ ] `HoverChip::SplitTabChip(PaneId)` — src/lib.rs:404
- [ ] `HoverChip::SplitTabClose(PaneId)` — src/lib.rs:406
- [ ] `HoverChip::SplitTabPlus(PaneId)` — src/lib.rs:409

### Tree row languages (42 extensions unrecognized by `tree_row_copy`)

Extensions the renderer icons but the copy dictionary skips — grouped:

- **Very common:** `xml`, `txt`, `lock`, `log`, `svg`, `png` / `jpg` /
  `jpeg` / `gif` / `webp`, `zip` / `gz` / `tgz`
- **JS ecosystem cousins:** `cjs`, `mjs`, `vue`, `svelte`, `less`
- **C family:** `c`, `cpp`, `h`, `hpp`
- **JVM / Kotlin / Swift / .NET / Ruby / PHP / Lua / Powershell:**
  `java`, `kt`, `swift`, `cs`, `csproj`, `sln`, `cshtml`, `razor`,
  `fs`, `rb`, `php`, `lua`, `ps1`
- **Config alternates:** `ini`, `conf`, `csv`
- **HTTP requester files (mnml's own):** `http`, `curl`, `rest`,
  `request` — worth a dedicated entry given HTTP is a first-class
  pane
- **Bin:** `exe`, `dll`

Also missing: **filename-keyed rows** (`package.json`, `tsconfig.json`,
`.env`, `.gitignore`, `Dockerfile`, `README.md`, `Makefile`, etc.) —
`tree_row_copy` currently dispatches on extension only. Add a
`filename_copy(&str)` pass before the extension fall-through.

### Menu items (dominant menus mostly bare)

- [ ] **Selection menu** — 0 / 7 items covered (Expand / Shrink
  selection, Add cursor above / below / next-match / all-occurrences,
  Clear extra cursors)
- [ ] **Go menu** — 1 / 6 (only "Go to definition"; missing Go to
  file, Go to line, Prev / Next / Last buffer)
- [ ] **Run menu** — 0 / 6 (Start debugging, Toggle breakpoint,
  Conditional breakpoint, Step in / out / back)
- [ ] **Terminal menu** — 0 / 3 (New terminal, Toggle scratch terminal,
  Rename terminal)
- [ ] **Window menu** — 0 / 19 (splits, focus L/R/U/D, merge, spread,
  AI layout, restart, reopen, close others, pin)
- [ ] **Help menu** — 0 / 4 (Welcome, Keybindings & help, Commands
  reference, About mnml)
- [ ] **Brand menu** — 0 / 3 (About, Settings, Quit — "Quit" catches
  via the File arm coincidentally)
- [ ] **File menu** — 4 / 10 (missing Add folder, Open recent, Switch
  workspace, Close tab, Settings — Save arm is broken, see Drift #1)
- [ ] **Edit menu** — 2 / 6 (missing Find next / prev, Find in files,
  Replace in files)
- [ ] **View menu** — 3 / 12 (missing Command palette, Toggle right
  panel, Cycle menu bar, Toggle zen, Toggle workspace dots, Commands
  reference, Pick theme, Toggle theme)

Ranked highest-value first: **Window > Selection > Run > Help >
Terminal > Brand** — the Window menu is the largest and its
splits/focus items are all keyboard-power-user territory that
benefits from `try_it` links.

### Integration + agents panels (10 gaps)

- [ ] `HoverChip::SessionsTab(PaneId)` — src/lib.rs:355 *(Sessions
  activity-bar view row — visible whenever a Claude / Codex session
  is open)*
- [ ] `HoverChip::ClaudeAgentsTopbarChip(kind)` — src/lib.rs:319
  *(5 kinds: View, Sort, Group, Source, Workspace)*
- [ ] `HoverChip::CloudAgentsNewRunButton` — src/lib.rs:414
- [ ] `HoverChip::CloudRunAutoRefresh` — src/lib.rs:416
- [ ] `HoverChip::CloudRunRefresh` — src/lib.rs:418
- [ ] `HoverChip::WorkspaceHeader` — src/lib.rs:323
- [ ] `HoverChip::ExtraWorkspaceHeader(usize)` — src/lib.rs:326
- [ ] `HoverChip::TreeIcon(&'static str)` — src/lib.rs:314 *(the tree
  toolbar row — new file / new folder / refresh / collapse-all)*
- [ ] `HoverChip::TreeUpRow` — src/lib.rs:471 *(the `..` row above the
  file tree)*
- [ ] `HoverChip::DockKebab` / `DockEmptyChip` — src/lib.rs:422 / 424

### Right panel + resize grips (5 gaps)

- [ ] `HoverChip::RightPanelTab(PaneId)` — src/lib.rs:392
- [ ] `HoverChip::RightPanelClose` — src/lib.rs:395
- [ ] `HoverChip::RightPanelGrip` — src/lib.rs:518
- [ ] `HoverChip::TreeRailGrip` — src/lib.rs:521
- [ ] `HoverChip::ScrollbarThumb` — src/lib.rs:515

### HTTP / Request pane (10 gaps — a full pane family that ships in v0.2)

- [ ] `HoverChip::RequestTopBarChip(Method|Env|Send|Save|Clear|Code)` —
  src/lib.rs:454 *(6 subvariants — Method / Env / Send are the
  headline chips)*
- [ ] `HoverChip::RequestSplitToggle` — src/lib.rs:458
- [ ] `HoverChip::RequestEditSplitChip` — src/lib.rs:461
- [ ] `HoverChip::RequestEditSplitDivider` — src/lib.rs:481 *(behaves
  differently from other grips — click cycles ratios, users are
  confused per src/ui/tooltip.rs:1359 comment)*
- [ ] `HoverChip::HttpCollectionAddRequestChip(usize)` — src/lib.rs:486
- [ ] `HoverChip::RequestVarToken(usize)` — src/lib.rs:494 *(the
  `{{VAR}}` hover — has rich per-var behavior; deserves a dedicated
  entry)*
- [ ] `HoverChip::RequestResponseCopy` — src/lib.rs:496
- [ ] `HoverChip::RequestResponseWrap` — src/lib.rs:498
- [ ] `HoverChip::RequestResponseAiPrompt` — src/lib.rs:501
- [ ] `HoverChip::RequestResponseFormat` — src/lib.rs:503

### Edge / advanced (7 gaps — lowest priority)

- [ ] `HoverChip::ToastBox(usize)` — src/lib.rs:281
- [ ] `HoverChip::RailHeaderChip(GitRailHeaderAction)` — src/lib.rs:283
  *(6 sub-actions: Fetch, Pull, Push, StageAll, Commit, Graph — the
  `GitToolbarChip(_)` catch-all reads roughly the same and could
  share copy)*
- [ ] `HoverChip::DiffToolbar(DiffToolbarAction)` — src/lib.rs:292
  *(5 subvariants: ViewInline, ViewHunk, ViewSplit, ToggleWrap, Close)*
- [ ] `HoverChip::CodeLensChip` — src/lib.rs:297
- [ ] `HoverChip::SplitDivider` — src/lib.rs:301
- [ ] `HoverChip::GitGraphLane { .. }` — src/lib.rs:437
- [ ] `HoverChip::GitGraphCommitMsg { .. }` — src/lib.rs:446
- [ ] `HoverChip::GutterMark { kind }` — src/lib.rs:564 *(carries
  a `GutterMarkKind` — 5 variants: DapArrow, ConditionalBreakpoint,
  Breakpoint, Diagnostic(sev), GitChange(kind); one arm per kind
  would give real state-aware copy)*

---

## Drift

1. **Broken match arm — `File → Save` copy is DEAD CODE.**
   `src/ui/info_view_copy.rs:544` guard is
   `i == "Save" || i.contains("Save ") && !i.contains("all")`.
   Menu labels carry glyph prefixes (`"\u{F0193}  Save"`, `"\u{F0194}
     Save all"`), so `i == "Save"` never matches, and `contains("Save ")`
   only matches "Save all" — which is then excluded by `!contains("all")`.
   Neither File-menu Save item routes here. Rewrite as
   `i.contains(" Save") && !i.contains("all")` (leading space anchors
   past the glyph, keeps Save-all out) or match on the command id if
   the copy fn gets access to it.

2. **Orphan match arm — `("Edit", "Undo")`.**
   `src/ui/info_view_copy.rs:590` — Edit menu has no `Undo` item today
   (only Find / Find next / Find prev / Replace / Find in files /
   Replace in files, per src/menu_bar.rs:212). The arm never fires.
   Either delete or, if Undo is being added, ensure the menu row
   lands with the expected label (Undo is currently input-layer-only —
   `editor.undo` has `keys: &[]`).

3. **Orphan command id — `AgentsPanelChip(_)` `try_it` points at
   `ai.agents_dashboard`.**
   `src/ui/info_view_copy.rs:297` — that id does not exist in
   `src/command.rs`. Real command is `ai.dashboard`
   (src/command.rs:1033). Click on the Try-it link will silently
   noop. Same body is duplicated for `StatuslineAiCodex` (line ~101)
   using the correct `ai.dashboard` id — copy the id, keep the fix
   local.

4. **Stale chord — `BufferlineNewTab` claims `Ctrl+T`.**
   `src/ui/info_view_copy.rs:184` shortcut says `Ctrl+T = New tab`,
   but `tab.new` binds to `Ctrl+K n` (src/command.rs:2713) with a
   comment explicitly rejecting Ctrl+T (would collide with VS Code
   workspace-symbols). Also the body ("Opens a new empty editor
   buffer in a fresh tab") is wrong — `tab.new` creates a new
   *tab page* (vim-style workspace), not a new buffer. The BufferlineNewTab
   click handler fires `app.tab_new(None)` (src/tui/mouse/down_left.rs:1391),
   so `try_it` is technically correct — but the shortcut hint and body
   both need to be reworded around "tab page" and the real chord.

5. **Stale chord — `StatuslineBranch` shortcut points at
   `Ctrl+Shift+B` for "Focus branch picker".**
   `src/ui/info_view_copy.rs:69` — `Ctrl+Shift+B` is bound to
   `view.toggle_right_panel` (src/command.rs, verified this run).
   `git.branch_menu` has `keys: &[]`. Either add a real chord for
   the branch picker or drop the shortcut hint.

No `docs:` URLs are set on any current entry, so no manual-page drift
to check.

---

## Notes on coverage arithmetic

- HoverChip count includes indexed variants (each concrete index is a
  distinct "covered" cell). `HttpToolbarChip` currently has 2 real
  indexes (verified in src/ui/http_panel.rs:75-86); both are covered
  plus a `_ => None` fallback. `HttpSectionChip` has 5 render sites
  (src/ui/http_panel.rs L706 / 728 / 751 / 789 / 811) with per-section
  variance — the current catch-all arm groups them all under one
  generic entry, which counts as covered but leaves per-section
  discoverability on the table.
- Menu items counted from `src/menu_bar.rs::bar()` — 10 menus, ~76
  action rows (Separator + Submenu excluded).
- Tree language count = extensions in `src/ui/icons.rs::extension_icon`
  (65 unique). Filename-keyed rows in `filename_icon` (~22) are counted
  separately since `tree_row_copy` doesn't touch them.
