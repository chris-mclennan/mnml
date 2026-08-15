# Hover-help / Info View coverage — R13 audit

**Mode**: report only (no source edits). **HEAD**: `d81b21ff`.
**Scope**: `src/ui/info_view_copy.rs` (1769 lines) against `src/lib.rs::HoverChip`
(100 variants), `src/menu_bar.rs` (76 top-level items across 10 menus),
`src/ui/icons.rs` (tree-row ext/filename tables), `src/command.rs::registry()`,
and the section-aware hint added in `51b81c37`.

## Summary

- **HoverChip**: 94/100 variants get real curated copy (94%). 6 variants
  intentionally return `None` from `chip_copy` ("tooltip already covers it" —
  see Gaps).
- **Tree-row languages**: 33 gaps — 18 extensions + 15 filename-keyed rows
  that have an icon (`src/ui/icons.rs`) but no `info_view_copy.rs` entry.
- **Menu bar items**: 31/76 top-level items curated (~41%). Every item still
  gets a non-empty generic fallback via `resolve_menu_bar_item_copy` (never
  raw `id · state`), but 5 of 10 menus (Brand/mnml, Selection, Run, Terminal,
  Help) have **zero** curated entries.
- **Command-id drift**: 0 orphans. Every `PaletteLink.command_id` in the file
  resolves in `src/command.rs::registry()`.
- **Chord/shortcut drift**: 4 confirmed inaccuracies (new findings this
  round, not previously flagged) — see Drift below. One is on the
  highest-traffic tree row (any directory).
- **Section-aware hint** (`51b81c37`): `ActivitySection` match is exhaustive
  (14 variants, compiles clean) — no missing sections. 3 of the 14 hint
  bodies contain factually wrong keybinding claims (Debug, Git, CloudAgents).

---

## 1. HoverChip coverage (100 variants)

Counted directly from `src/lib.rs:255-608` (`grep -cE` on top-level variant
lines confirms 100).

### Gaps — `chip_copy` returns `None` (src/ui/info_view_copy.rs:1171-1180)

- [ ] `BufferlineTabPage(usize)` — numbered tab-page pip. No entry;
  comment says "tooltip carries all the useful copy."
- [ ] `BufferlineTabPageClose(usize)` — the `×` on a tab-page pip. Same.
- [ ] `IntegrationsTabInstalled` — Integrations panel tab strip.
- [ ] `IntegrationsTabMarketplace` — same strip, Marketplace tab.
- [ ] `IntegrationsTabRefresh` — same strip, `⟳` chip.
- [ ] `IntegrationsTabSort` — same strip, `A-Z ▾` chip.

Design doc principle 1 ("every hoverable thing has copy, no `id · state`
fallback") is technically violated for these 6 — they fall through
`describe_info_view` to `empty_state_copy(app)` instead. In practice the
panel still shows something coherent (the focus-scoped empty-state copy),
so severity is low, but it's a real gap against the stated bar. All 4
Integrations-tab-strip chips are contiguous and cheap to fill in one pass —
recommend prioritizing those over the 2 bufferline-page chips (lower
traffic, edge case per file).

### Not gaps (verified, don't re-flag)

- `HttpToolbarChip(_) => None` catch-all — grounded against
  `src/ui/http_panel.rs:75-86`: exactly 2 toolbar chips exist
  (`http.refresh` idx 0, `http.toggle_collapse_all` idx 1), both curated.
  The catch-all never fires; not a real gap.
- `MenuBarItem { .. } => None` inside `chip_copy` — by design; `lookup()`
  routes `MenuBarItem` to `resolve_menu_bar_item_copy` *before* reaching
  `chip_copy` (src/ui/info_view_copy.rs:37-39), which always returns
  `Some` (curated or generic fallback). Best-covered variant in the file.
- Generic-but-real entries (not stale, just not per-sub-variant): the
  arms that intentionally collapse many concrete values into one body —
  `GitToolbarChip(_)`, `RailHeaderChip(_)`, `DiffToolbar(_)`,
  `ClaudeAgentsTopbarChip(_)`, `AgentsPanelChip(_)`, `GutterMark{..}`,
  `RequestTopBarChip(_)`, `SplitStripButton(_)`. These read fine; flagging
  only as a quality note in case a future `fill` pass wants to
  differentiate e.g. Fetch vs Push inside `GitToolbarChip`.

---

## 2. Tree-row language coverage

Ground truth: `src/ui/icons.rs::extension_icon` (63 extensions) +
`::filename_icon` (19 filename-keyed entries) — these are what the tree
renderer actually recognizes (per task framing). Compared against
`tree_row_copy` / `filename_row_copy` in `info_view_copy.rs`.

### Extension gaps (icon exists, no copy) — 18

`cjs`, `mjs`, `less`, `csv`, `ini` / `conf`, `rb`, `php`, `lua`, `ps1`,
`txt`, `lock`, `log`, `exe`, `dll`, `zip` / `gz` / `tgz`

Worth prioritizing: `rb` (Ruby), `php`, `lua` — real languages with no
coverage at all (not even a generic "syntax-only" blurb), same tier as the
already-covered C#/F#/Java set. `txt`/`log`/`lock` are lower-value (no
real "language" story) but still hit often in real workspaces
(`Cargo.lock`, `package-lock.json` falls to filename match instead, `*.log`
does not).

### Filename-keyed gaps (icon exists, no copy) — 15 groups

`package-lock.json`, `pnpm-lock.yaml`, `tsconfig.json`,
`.gitignore`/`.gitattributes`, `.gitconfig`, `.eslintrc`, `.prettierrc`,
`.editorconfig`, `.dockerignore`, `.npmrc`, `.nvmrc`,
`docker-compose.yml`/`.yaml`/`compose.yml`/`.yaml`, `readme`/`readme.md`,
`license`, `copying`

Highest-value: `tsconfig.json` (every TS project has one, currently falls
to the generic `json` ext copy which says nothing about tsconfig's role),
`.gitignore` (near-universal), `readme.md` (currently double-covered
incorrectly — falls to the `md` extension arm, which is fine content-wise
but the title reads `"README.md — Markdown"` instead of something that
acknowledges it's the project readme).

---

## 3. Menu-bar item coverage

Ground truth: `src/menu_bar.rs::bar()` — 10 menus, 76 top-level
action/submenu rows (separators excluded). Compared against
`menu_item_copy` match arms (`src/ui/info_view_copy.rs:1463-1767`).

| Menu | Items | Curated | Notes |
|---|---:|---:|---|
| `❯_  mnml` (brand) | 3 | 0 | About / Settings / Quit — zero coverage |
| File | 10 | 5 | New file, Open, Save, Save all, Quit curated. Gaps: Add folder to workspace, Open recent file (submenu), Switch workspace, Close tab, Settings |
| Edit | 6 | 2 | Find, Replace curated. Gaps: Find next/prev, Find in files, Replace in files |
| Selection | 7 | 0 | Zero coverage (Expand/Shrink selection, multi-cursor rows) |
| View | 12 | 4 | wrap, left panel, bottom panel, hover-help curated. Gaps: Command palette, **Toggle right panel**, Cycle menu bar, zen mode, workspace dots, Commands reference, Pick theme, Toggle theme |
| Go | 6 | 1 | Only "Go to definition" curated. Gaps: Go to file, Go to line, Prev/Next/Last buffer |
| Run | 6 | 0 | Zero coverage (Start debugging, breakpoints, step in/out/back) |
| Terminal | 3 | 0 | Zero coverage |
| Window | 19 | 19 | **Fully curated** — every item has a dedicated arm |
| Help | 4 | 0 | Zero coverage (Welcome, Keybindings, Commands reference, About) |
| **Total** | **76** | **31** | **41%** |

Every uncurated item still resolves to a non-empty generic fallback
(`resolve_menu_bar_item_copy`'s tail: `"{Menu} → {Item}"` title +
`"Menu item. Click or press Enter to fire its command."` body), so nothing
regresses to raw `id · state`. But it's flat — no shortcut, no `try_it`,
no "what does this actually do" prose.

**Notable inconsistency**: `View → Toggle right panel` has no curated menu
entry, but its chrome-chip twin `PaletteRightPanelButton` (same action, same
chord `Ctrl+Shift+B`) *is* curated. A `fill` pass should add the mirror
entry so hovering the menu item and hovering the chip read consistently.

**Priority for a future `fill` pass**: Window is done; Run (debug — high
power-user value) and Go (navigation — high traffic) are the best next
targets before the zero-coverage utility menus (Terminal/Help/brand).

---

## 4. Drift check

### Command-id drift (try_it / TreeIcon cmd_id) — clean

Extracted every `"foo.bar"`-shaped string literal from
`info_view_copy.rs` (76 unique ids across `PaletteLink::new` calls +
`TreeIcon` match keys) and diffed against `grep -oE 'id:\s*"[^"]+"'` over
`src/command.rs` (708 registered ids). **Zero unresolved ids.** The one
near-miss, `"ai.agents_dashboard"`, only appears inside a code comment
documenting a *previous* self-correction (2026-08-11: fixed to
`"ai.dashboard"`) — not live code. No action needed.

### Chord drift — 4 new findings

These weren't caught by the 2026-08-11 fill-batch's self-correction pass
(which fixed `StatuslineBranch` and `AgentsPanelChip`). Grounded against
`src/command.rs::registry()` `keys:` arrays and the actual key-dispatch
code (`src/tui/handlers/pane.rs::handle_tree_key`, `src/tui/mod.rs`).

1. **`FoldChip` — `Ctrl+Shift+[/]` "Fold / unfold (standard)"**
   (`src/ui/info_view_copy.rs:635-638`). Actual bindings
   (`src/command.rs:947-961`): `Ctrl+Shift+[` = `editor.toggle_fold`
   (toggles the fold at cursor, both directions); `Ctrl+Shift+]` =
   `editor.unfold_all` (unfolds **every** fold in the buffer, not the one
   at cursor). The copy implies a symmetric fold/unfold pair on the same
   target — it isn't. Suggest: `Ctrl+Shift+[` "Toggle fold at cursor" /
   `Ctrl+Shift+]` "Unfold all in buffer".

2. **`tree_row_copy` directory row — `E / C` "Expand-all / collapse-all
   recursively"** (`src/ui/info_view_copy.rs:1205-1208`). `tree.expand_all`
   and `tree.collapse_all` (`src/command.rs:3026-3038`) both have
   `keys: &[]` — **no keyboard binding exists**. Confirmed by reading the
   full body of `handle_tree_key` (`src/tui/handlers/pane.rs:17-211`,
   the actual `Focus::Tree` key dispatcher) — no `'E'`/`'C'` arms. Both
   commands are only reachable via the tree row's right-click menu
   (`src/app/context_menus.rs:840-950`) or the palette. This is the
   **highest-traffic single entry with a factual error** in the file —
   every directory row in the tree shows it. (Note: the `E`/`C`
   expand-all/collapse-all convention is real for the *sibling-tool*
   trees per project memory — it looks like that convention leaked into
   mnml-core copy without the binding actually existing here.) Fix:
   drop the shortcut or point `try_it` at `tree.expand_all` /
   `tree.collapse_all` instead of claiming a chord.

3. **`section_focus_hint(Debug)` — "F5 continues, F10 steps over, F11
   steps in"** (`src/ui/hover_help.rs:620-623`). `f5` is bound to
   `dap.run` ("start debug session"), not continue
   (`src/command.rs:4272`). `dap.continue` is bound to `shift+f5`
   (`src/command.rs:4278`). F10/F11 claims are correct
   (`dap.next`/`dap.step_in`, confirmed at `src/command.rs:4286,4293`).
   Fix: "F5 starts a debug session, Shift+F5 continues, F10 steps over,
   F11 steps in" (or drop F5/continue conflation).

4. **`section_focus_hint(Git)` — "`,` opens the log"**
   (`src/ui/hover_help.rs:616-619`). No binding for `,` tied to git log
   / graph found anywhere in the codebase (`grep -rn "KeyCode::Char(',')"`
   only hits vim's `f`/`t` reverse-repeat in `src/input/vim.rs`, unrelated
   to git). `git.graph` itself has `keys: &[]`
   (`src/command.rs:3840-3844`) — click/palette only. This claim appears
   fabricated; no grounding found.

5. **`section_focus_hint(CloudAgents)` — "`r` opens the run in
   CloudWatch, `p` opens the PR"** (`src/ui/hover_help.rs:636-639`).
   `handle_tree_key` (the actual Focus::Tree key handler) has no `r`/`p`
   arms scoped to `ActivitySection::CloudAgents`. Opening CloudWatch / PR
   are **mouse-click-only web-link rows inside the `CloudAgentRun` detail
   pane** (`src/ui/cloud_agent_run_view.rs:175-177`, `("PR", ...)` /
   `("CloudWatch", ...)`), not keyboard shortcuts reachable from the
   sidebar row list this hint describes. The hint conflates a different
   pane's mouse affordances with this section's keyboard shortcuts.

Everything else spot-checked came back accurate: `Ctrl+E` → `focus.cycle`
(StatuslineMode), `Ctrl+K Ctrl+O` → `view.switch_workspace`
(StatuslineWorkspace), `Ctrl+Alt+W` → right-panel-close
(`RightPanelClose`), `Ctrl+Shift+M` → `lsp.diagnostics`
(StatuslineDiagnostics), `]c`/`[c` → `git.jump_next_change`/
`git.jump_prev_change` (GutterMark), `za` → vim fold-toggle (FoldChip),
`f9` → `dap.toggle_breakpoint` (GutterMark's `try_it`).

---

## 5. Section-aware hint (`51b81c37`) — accuracy pass

`section_focus_hint` (`src/ui/hover_help.rs:608-662`) matches
`crate::app::ActivitySection` exhaustively — all 14 current variants
(`LauncherIcon`, `Explorer`, `Search`, `Git`, `Debug`, `Integrations`,
`Sessions`, `Agents`, `CloudAgents`, `Http`, `Notes`, `Todos`, `Findings`,
`Mount`) present, `Explorer | LauncherIcon(_) => return None` falls
through to tree-row logic as designed. Compiles clean — **no missing
section**, confirmed against the live enum at
`src/app/mod.rs:1650-1702`.

Content accuracy: 3 of 14 non-fallthrough hints contain wrong keybinding
claims (Debug, Git, CloudAgents — detailed in §4 items 3-5). The other 9
(Search, Integrations, Sessions, Http, Notes, Todos, Findings) were spot-
checked for plausibility against their section's key-handling code and
read as accurate generic descriptions — none claim a chord that doesn't
exist. Not exhaustively re-derived (would need per-section deep dives
matching the Debug/Git/CloudAgents depth above); flag as **unverified but
plausible** rather than confirmed-clean.

---

## Recommended next `fill` pass (priority order)

1. Fix the 5 chord-drift items in §4 (small, surgical, high-signal —
   directory-row `E/C` and Debug `F5` are the highest-traffic).
2. Fill the 4 `IntegrationsTab*` `HoverChip` gaps (contiguous, same file
   region as `chip_copy`'s existing `None` arms).
3. Menu bar: Run + Go menus (debug + navigation, high power-user value),
   then close the `View → Toggle right panel` chip/menu inconsistency.
4. Tree-row: `rb`/`php`/`lua` extensions + `tsconfig.json`/`.gitignore`
   filename rows (highest hit-rate of the 33 tree gaps).
5. Lowest priority: `BufferlineTabPage`/`BufferlineTabPageClose` chips,
   Brand-menu / Terminal-menu / Help-menu items (low traffic, low
   confusion risk — the generic fallback already reads fine for these).

Not audited this round (out of scope per task): `EditorSymbol` target
(Phase 2, not yet wired — `lookup()` returns `None` unconditionally at
`src/ui/info_view_copy.rs:43`), rich-renderer inline-token behavior
(`[Chord]` / `:cmd.id` / `[[topic]]` parsing — still Phase 1.5 per the
design doc, `to_flat_pair` compresses everything to plain text today so
inline styling has no user-visible effect to audit yet).
