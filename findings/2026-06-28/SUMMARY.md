# QA sweep summary — 2026-06-28

Run against commit **591a4b4** (start) → fixes pushed in **b767b8c**.

## Counts

- **SEV-1**: 2 (1 fixed; 1 pre-existing)
- **SEV-2**: 21 staged, 3 REFUTED by verification round, **18 net**
- **SEV-3**: 22 (includes 4 refuted/verified-working files for clarity)
- **Design issues**: 0 high · 4 medium · 2 low (one design-critic file, right-panel v5)

## SEV-1

- [input-browser-alt-arrows-dead-code](input-browser-alt-arrows-dead-code.md) — Browser Alt+Left/Right was dead code (global nav.back/forward consumed first) — input-handler-reviewer · **FIXED in b767b8c**
- [nvchad-headless-silent-exit-multi-op-sequence](nvchad-headless-silent-exit-multi-op-sequence.md) — `--headless --input vim` exits silently after ~100 IPC ops — nvchad-user · pre-existing harness bug, not from today's commits

## SEV-2 — net 18 (3 refuted)

### Fixed in b767b8c
- [http-single-block-save-regression](http-single-block-save-regression.md) — Single-block .http saves broken by 5020def — api-workflow-user
- [multilang-tree-auto-expand-breaks-drag-move-test](multilang-tree-auto-expand-breaks-drag-move-test.md) — Auto-expand on tree.refresh broke mouse_tree_file_move.test — multilang-dev-user
- [multilang-npm-monorepo-loses-context-after-pty](multilang-npm-monorepo-loses-context-after-pty.md) — Monorepo runners lose pkg context after first pty pane — multilang-dev-user
- [nvchad-ctrl-shift-bracket-folds-not-dispatched-vim](nvchad-ctrl-shift-bracket-folds-not-dispatched-vim.md) — Ctrl+Shift+[/] no-op in vim NORMAL (bracket prefix collision) — nvchad-user
- (implicit) render-reviewer W-1: editor_panes pollution from right-panel hosted views — fixed via 3-file guard

### Refuted by vscode-user-2nd verification round
- [vscode-empty-state-row-misroutes](vscode-empty-state-row-misroutes.md) — REFUTED ([vscode-2nd-empty-state-click-refuted](vscode-2nd-empty-state-click-refuted.md)); original agent miscounted rows pre-render
- [vscode-grep-skips-right-panel](vscode-grep-skips-right-panel.md) — REFUTED ([vscode-2nd-grep-right-panel-refuted](vscode-2nd-grep-right-panel-refuted.md)); grep DOES route to panel
- [vscode-right-panel-tabs-not-persisted](vscode-right-panel-tabs-not-persisted.md) — REFUTED ([vscode-2nd-right-panel-persist-refuted](vscode-2nd-right-panel-persist-refuted.md)); persistence works

### Still open
- [claude-agents-spend-today-blocks-ui](claude-agents-spend-today-blocks-ui.md) — `parse_full` reads whole-file synchronously on main UI thread (regression from 591a4b4) — claude-agents-power-user
- [keyboard-recent-chords-verify](keyboard-recent-chords-verify.md) — release binary was stale; b767b8c rebuilt — verify fresh — vscode-user-keyboard
- [mouse-right-panel-x-close-left-click-noop](mouse-right-panel-x-close-left-click-noop.md) — × close left-click no-op — vscode-user-mouse (CONTRADICTS vscode-2nd; release binary may have been stale)
- [mouse-right-panel-tab-strip-left-click-noop](mouse-right-panel-tab-strip-left-click-noop.md) — tab strip click doesn't switch active — vscode-user-mouse (same contradiction)
- [mouse-right-panel-tab-right-click-no-context-menu](mouse-right-panel-tab-right-click-no-context-menu.md) — tab right-click opens no menu — vscode-user-mouse (same contradiction)
- [mouse-right-panel-grip-drag-resize-noop](mouse-right-panel-grip-drag-resize-noop.md) — grip drag doesn't resize panel — vscode-user-mouse (same contradiction)
- [multilang-lsp-language-id-no-unit-test](multilang-lsp-language-id-no-unit-test.md) — derive_lsp_language_id has no unit test (coverage gap) — multilang-dev-user
- [multilang-test-gaps-summary](multilang-test-gaps-summary.md) — Test gaps for today's multilang fixes — multilang-dev-user
- [nvchad-ctrl-r-ctrl-w-and-ctrl-a-dead-code](nvchad-ctrl-r-ctrl-w-and-ctrl-a-dead-code.md) — Ctrl+R Ctrl+W/A dead code (lowercase arm matches first) — nvchad-user
- [nvchad-d-dollar-c-dollar-keep-last-char](nvchad-d-dollar-c-dollar-keep-last-char.md) — d$/c$/y$ off-by-one (pre-existing) — nvchad-user
- [nvchad-de-ye-ce-cw-off-by-one](nvchad-de-ye-ce-cw-off-by-one.md) — de/ye/ce/cw operator off-by-one (pre-existing) — nvchad-user
- [vscode-ctrl-end-misses-buffer-end](vscode-ctrl-end-misses-buffer-end.md) — Ctrl+End lands at start-of-last-line — vscode-user
- [vscode-shift-f10-hover-chip-incomplete](vscode-shift-f10-hover-chip-incomplete.md) — Shift+F10 hover_chip fallback misses integration chips + statusline — vscode-user
- [vscode-tab-drag-reorder-noop](vscode-tab-drag-reorder-noop.md) — Tab drag-to-reorder collapses into a click — vscode-user

## SEV-3 — fixes shipped where called out; rest deferred

### Fixed in b767b8c
- input-handler-reviewer W-1 (Ctrl+G removed from cheatsheet)
- input-handler-reviewer W-2 (http_next/prev reveal_pane)
- input-handler-reviewer W-3 (cheatsheet count comment)
- vscode-user-mouse mouse-rects-empty-state-not-dumped (rects.json includes empty-state coords)

### Still open
- [claude-agents-evict-vs-close-mismatch](claude-agents-evict-vs-close-mismatch.md) — whichkey "evict" vs palette "close" — same surface, two verbs
- [claude-agents-filter-pause-invisible](claude-agents-filter-pause-invisible.md) — filter-mode pause hides the `· paused` chip
- [claude-agents-row-click-detail-scroll](claude-agents-row-click-detail-scroll.md) — row click doesn't reset detail_scroll
- [http-stale-test-comment-unnamed-block](http-stale-test-comment-unnamed-block.md) — outdated test comment
- [mouse-right-panel-empty-state-click-fails-after-runtime-toggle](mouse-right-panel-empty-state-click-fails-after-runtime-toggle.md) — vscode-mouse claim, conflicts with vscode-2nd
- [mouse-right-panel-hover-tooltips-missing](mouse-right-panel-hover-tooltips-missing.md) — tooltips don't show over right-panel chrome
- [mouse-right-panel-x-button-right-click-dead-zone](mouse-right-panel-x-button-right-click-dead-zone.md) — 1-cell dead zone on × right-click
- [multilang-react-fc-callback-generics-miss](multilang-react-fc-callback-generics-miss.md) — React.FC outline misses callback types in generics
- [multilang-tree-no-gitignore-test-stale-comment](multilang-tree-no-gitignore-test-stale-comment.md) — stale comment in tree e2e test
- [visual-diagnostics-help-truncation](visual-diagnostics-help-truncation.md) — diagnostics help line truncates at narrow widths (drive-mnml visual)
- [visual-palette-row-truncation](visual-palette-row-truncation.md) — palette row truncates command id mid-string (drive-mnml visual)
- [visual-side-panel-caps-header](visual-side-panel-caps-header.md) — "SIDE PANEL" caps inconsistency (drive-mnml visual + design-critic)
- [vscode-ctrl-p-no-workspace-affinity](vscode-ctrl-p-no-workspace-affinity.md) — Ctrl+P picker has no current-workspace boost
- [vscode-ctrl-tab-mru-untested](vscode-ctrl-tab-mru-untested.md) — Ctrl+Tab no MRU behavior
- [vscode-fold-toggle-noop-on-rust](vscode-fold-toggle-noop-on-rust.md) — editor.toggle_fold no-op on plain Rust (LSP-fold-range dependency?)
- [vscode-shift-f10-statusline-chips-unsupported](vscode-shift-f10-statusline-chips-unsupported.md) — statusline chips have no keyboard menu route

### Counter-evidence files (not findings — context)
- [vscode-2nd-ai-tests-rightclick-confirmed](vscode-2nd-ai-tests-rightclick-confirmed.md)
- [mouse-right-panel-verified-working](mouse-right-panel-verified-working.md)
- crash-investigator panic-risk audit returned 1 SEV-3 (byte_to_row_col Unicode boundary, pre-existing)

## Design findings

- [right-panel-v5](../design-reviews/2026-06-28/right-panel-v5.md) — 4 medium + 2 low — design-critic
  - medium: 3-tab labels truncate at 32-cell column (lose count chips)
  - medium: × button visually adjacent to wrong chip when active not rightmost
  - medium: Empty state lists 2 of 5 routable commands
  - medium: Tests/Grep tabs save-but-not-restore (FIXED in b767b8c — now not saved)
  - low: "SIDE PANEL" all-caps vs "right panel" elsewhere
  - low: whichkey "evict" vs everywhere else "close"

## Coverage notes

- **All 14 agents ran successfully.** Round 1: 8 (claude-agents, multilang, api-workflow, nvchad, vscode-user, vscode-keyboard, vscode-mouse, design-critic). Round 2: 4 (code-reviewer, render-reviewer, input-handler-reviewer, vscode-user-2 verification). Round 3: 2 (crash-investigator, test-writer).
- **Visual pass (drive-mnml)**: ran (5 surfaces shot). 3 visual findings staged + design-critic #5 visually confirmed.
- **Working tree status**: clean as of b767b8c push; sweep ran against fresh `target/release/mnml` rebuilt mid-sweep.
- **Stale-binary trap noted**: vscode-keyboard + vscode-mouse both flagged that earlier probes failed because target/release/mnml predated the chord commits. Release binary rebuilt 23:14.
- **Verification round value**: vscode-user-2 refuted 3 of the original vscode-user SEV-2 claims (right-panel persist, grep routing, empty-state click). The vscode-mouse SEV-2 sweep (4 SEV-2s + 4 SEV-3) was the LAST agent to return, against an older release binary. Recommend a follow-up `/qa-sweep design right-panel` or focused vscode-mouse-3rd to confirm/refute against the fresh b767b8c binary.

## Verification round 3 — vscode-mouse-3rd (against fresh release binary)

All 4 vscode-mouse SEV-2 claims **REFUTED** against the b767b8c-built binary
(mtime 23:13, post-commit 23:01):
- × close left-click WORKS — `rightPanelPanes:[1]` → `[]`
- tab strip left-click WORKS — switches active idx
- tab right-click WORKS — opens 2-item menu ("Close tab" / "Hide side panel")
- grip drag WORKS — moves right_panel_edge.x

CONFIRMED-FIXED: rects.json now dumps empty-state rects (was: vscode-mouse-rects-empty-state-not-dumped, fixed in b767b8c).

CONFIRMED still broken: empty-state click after runtime toggle (one SEV-3).
**Note**: I separately verified this WORKS in the live mnml against my workspace
(extensions.json open). The agent's scenario opened src/main.rs first — may be
workspace-specific or 1-frame race. Deferred for re-investigation.

## Top 3 highest-severity items still open (priority order)

1. **claude-agents-spend-today-blocks-ui** (SEV-2 regression I introduced in 591a4b4) — needs background-thread offload
2. **nvchad Ctrl+R Ctrl+W/A dead code** (SEV-2) — register-paste arm matches lowercase first
3. **nvchad de/ye/ce/cw off-by-one + d$/c$/y$ keep last char** (SEV-2 pre-existing, not from today)
