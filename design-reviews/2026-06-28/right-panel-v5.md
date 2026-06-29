---
agent: design-critic
surface: right-panel
commit: 591a4b4
issues_high: 0
issues_medium: 4
issues_low: 2
---

# Design review: right-panel v5

## TL;DR

The right-panel v5 is structurally solid — routing, FIFO displacement,
drag-resize, session persistence, and per-state tooltips are all
well-thought-out. Three issues stand out: (1) at the 3-tab cap in the
default 32-cell column, every tab label truncates to ~7 chars, which
hides the dynamic count suffix that is the whole point of live tab
titles; (2) the × button semantically acts on the active tab but is
visually pinned to the rightmost corner, creating a silent mismatch when
inactive tabs appear to the right of the active one; (3) the empty-state
hint teaches only 2 of the 5 commands that now route to the panel, leaving
ai.chat, find.grep, and test.run undiscoverable from the empty state.

## Issues found

### 1. Three-tab labels at 32 cells truncate dynamic count suffixes · severity: medium

At 3 tabs in a 32-cell column, each chip gets ~9 cells (`strip_end =
width - 2 = 30`, minus 2 separator gaps, divided by 3 ≈ 9 cells per chip,
minus 2 padding spaces = 7 display chars). Diagnostics `"problems ✗2 ⚠1"`
truncates to `"problem…"` — the error/warning counts that are the only
live state signal disappear. Grep `"grep:search_term (24)"` → `"grep:s…"`
— query and count both vanish. Outline `"main.rs ⌥42"` → `"main.rs"` —
count lost. Tests `"tests ✓15"` → `"tests …"` — glyph cut off.

**Fix:** Add `panel_chip_label(max_width: usize) -> String` short-label
branch. At 7-char budget: Diagnostics → `"✗2⚠1"`, Tests → `"✓15"`, Grep →
4-char query + count, Outline → filename only.

### 2. × button visually adjacent to rightmost chip even when not active · severity: medium

When active tab is NOT rightmost (e.g. `[Outline(active)][Diagnostics]`),
the bg2 bridge doesn't paint and the × sits next to inactive Diagnostics.
User reading left-to-right sees × as belonging to Diagnostics — but
clicking closes Outline. Silent destructive action on wrong target.

**Fix:** Option A — when active not rightmost, paint × with `t.bg_dark`
+ fg `t.comment` so it visually signals "mode-dependent, not local close".
Option B — move × INTO the active chip (VS Code model), drop corner ×.

### 3. Empty state lists 2 of 5 routable commands · severity: medium

Hint renders `:outline.show` and `:lsp.diagnostics`. Panel now also
routes `:ai.chat`, `:find.grep`, `:test.run` when visible — none appear
in the hint. First-time users assume panel is outline/diagnostics-only.

**Fix:** Extend hint to all 5 commands. Either expand hint_rect to 8
rows or two-column layout (`:outline.show  :ai.chat` / `:lsp.diagnostics
:find.grep` / `  :test.run`). Register click rects for the 3 new lines.

### 4. Session restore silently drops Tests + Grep tabs · severity: medium

`save_session_on_quit` serializes "tests"/"grep" but `try_restore_session`
only matches "outline"/"diagnostics"; `_ => {}` discards. User closes
with [Outline][Diag][Tests], restarts → [Outline][Diag] silently.

**Fix:** Option A — restore empty Tests/Grep placeholder panes. Option B
— don't save them (filter_map → None like AI) + toast on next launch
"tests tab not restored".

### 5. "SIDE PANEL" header diverges from feature name · severity: low

Empty-state header is `" SIDE PANEL"` (screaming-caps). Everywhere else
the feature is named "right panel" lowercase (command title, tooltip,
whichkey, context menu, toast).

**Fix:** Change header to `" right panel"`.

### 6. Whichkey "evict" is unique vocabulary in a close-flavored action · severity: low

Whichkey label is `"right panel: evict active tab"`. Command title says
"close", context menu says "Close tab", × tooltip says "close active tab".
"Evict" appears nowhere else. Causes a pause for whichkey discovery users.

**Fix:** Change whichkey label to `"right panel: close tab"`.

## Patterns that are working well

- Routing logic is clean and uniform across all 5 pane kinds
- FIFO displacement with a toast is the right UX decision
- Per-state tooltips (active vs inactive) correctly suppress the "× close"
  hint when hovering inactive tabs
- Drag-edge grip + "too narrow" guard at <16 cells reads correctly
- Session persistence for Outline/Diag is defensive correct
- Right-click context menu on tab chips covers the real actions

## Out of scope but noted

- `view.right_panel_close_tab` has `keys: &[]` due to Ctrl+Shift+W
  collision with vim NORMAL mode `Ctrl+W` prefix — chord-layer arch
  issue, not panel design
- Grep pane's 58-char hint `"⏎ jump   r re-run   R replace-all..."` will
  overflow at 32 cells — predates right-panel hosting
