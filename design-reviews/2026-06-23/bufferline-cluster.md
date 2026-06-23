---
review: bufferline-cluster
agent: design-critic
date: 2026-06-23
commit: 0e07572
---

## TL;DR

The cluster lands cleanly as a structural change — the tab strip no longer
bleeds into the split buttons, the glyph fix is correct, and the dual-site
implementation (single-leaf bufferline + per-leaf split strip) is internally
consistent. The top three issues are: (1) none of the three new buttons surface
a tooltip on hover, breaking the discoverability contract every other clickable
chip in the app upholds; (2) the `btn_v_glyph` / `btn_h_glyph` variable names
are inverted relative to what each glyph draws, which will make future edits
error-prone; (3) `term.shell` lives in `group: "ai"` instead of `group: "term"`,
so the terminal button's backing command appears under the wrong palette section.

---

## Issues found

### 1. No tooltip on hover for any of the three buttons · severity: high

**What:** The terminal button (`ea85`), the V-split button (`eb56`), and the
H-split button (`eb57`) are never added to `hover_chip_at` in
`src/app/dispatch.rs` and have no `HoverChip` variants, so hovering them
produces no tooltip.

**Why it matters:** Every other clickable chip in mnml — statusline mode,
branch, LSP/WRAP/autosave, launcher icons, palette back/forward, bufferline
tabs and their close badges, the new-tab button, the theme toggle, the window
close, diff toolbar chips, fold chips, code-lens chips, tree icons, activity
bar icons, workspace header, integrations rail, now-playing chip — all have
tooltip coverage (see the 25-arm `hover_chip_at` in
`src/app/dispatch.rs:291-479` and `src/ui/tooltip.rs`). A user who moves the
mouse over the new cluster gets nothing, even though those buttons are the
most opaque things in the bufferline — the H/V split distinction especially is
non-obvious to someone who hasn't memorised codepoint semantics. This violates
the stated discoverability contract: "lets users learn what each chip does
without trial and error."

**Evidence:**
- `src/app/dispatch.rs:291-479` — `hover_chip_at` has no arm for
  `split_strip_term_buttons` or `split_strip_buttons`.
- `src/lib.rs:205-287` — `HoverChip` enum has no variant for split or
  terminal buttons.
- `src/ui/tooltip.rs:78` — `describe` would need matching arms.

**Proposed fix:** Add three `HoverChip` variants —
`SplitButtonTerminal`, `SplitButtonV`, `SplitButtonH` — each carrying the
pane id from the rect tuple. In `hover_chip_at`, after the existing
`bufferline_window_close` arm, iterate `split_strip_term_buttons` and
`split_strip_buttons` and return the matching variant. In `tooltip::describe`,
map each to a label:
- `SplitButtonTerminal` → primary `"open new shell below (term.shell)"`,
  sublabel `"ctrl+t = focus or open"`
- `SplitButtonV` → primary `"split editor right (view.split_right)"`,
  sublabel `"ctrl+\\"` (the bound chord)
- `SplitButtonH` → primary `"split editor down (view.split_down)"`,
  sublabel `"no default chord — use palette"`

The anchor rect is already registered per-frame in `split_strip_term_buttons`
and `split_strip_buttons`; no new rect storage is needed.

---

### 2. `btn_v_glyph` / `btn_h_glyph` variable names are semantically inverted · severity: medium

**What:** The variable named `btn_v_glyph` (suffix `-v`) is assigned
`\u{eb56}` (nf-cod-split_horizontal — a box with a *vertical* divider, i.e. a
side-by-side layout) and is dispatched to `SplitDir::Horizontal` (which creates
a side-by-side split). The variable named `btn_h_glyph` is assigned `\u{eb57}`
(nf-cod-split_vertical — a box with a *horizontal* divider, i.e. a stacked
layout) and is dispatched to `SplitDir::Vertical`. The glyphs and the actions
are correctly paired, but the variable names transpose the orientation axis: the
"v" glyph variable creates a horizontal split and the "h" glyph variable creates
a vertical split.

**Why it matters:** This is a silent trap for the next person who touches this
code (which could be the author two months from now). Nerd Font codepoint names
deliberately name the *divider line* orientation, not the resulting pane
arrangement; `split_horizontal` means "divider is horizontal" (= panes are
stacked), the opposite of what a reader expects from `SplitDir::Horizontal`.
The variable names `btn_v_glyph` / `btn_h_glyph` double down on the confusion
by using the pane-arrangement axis instead of the codepoint axis, and by
assigning each to the *opposite* codepoint. The duplicate implementation in
`src/ui/mod.rs:2131-2156` and `src/ui/bufferline.rs:692-716` means this must
be kept consistent in two places simultaneously.

**Evidence:**
- `src/ui/bufferline.rs:692-716` — `btn_v_glyph = eb56 → SplitDir::Horizontal`
- `src/ui/mod.rs:2131-2156` — identical pairing repeated verbatim

**Proposed fix:** Rename the variables to match the codepoint's own naming axis
(the divider), not the pane-arrangement axis:
```
let btn_split_right_glyph = if nerd { "\u{eb56}" } else { "|+" };  // vertical divider = side-by-side
let btn_split_down_glyph  = if nerd { "\u{eb57}" } else { "_+" };  // horizontal divider = stacked
```
and pair with `SplitDir::Horizontal` / `SplitDir::Vertical` respectively,
which then reads as: "right-split glyph → Horizontal dir" and "down-split
glyph → Vertical dir". The action-first naming (`split_right`, `split_down`)
mirrors the existing palette commands `view.split_right` and `view.split_down`,
closing the mental-model loop. Apply to both paint sites atomically.

---

### 3. `term.shell` lives in `group: "ai"` · severity: medium

**What:** The palette command backing the terminal button — `term.shell` — is
registered with `group: "ai"` (`src/command.rs:3633`). So are its siblings
`term.rename`, `term.scratch_toggle`, and `term.focus_or_open_shell`. A user
who opens the palette and types `:ai` sees terminal commands mixed with Claude /
AI commands; a user who types `:term` sees all four but must know to look under
`:ai` to understand the group hierarchy.

**Why it matters:** The palette group is the primary browsable namespace. The
CLAUDE.md lists the established groups as `http`, `git`, `ai`, `test`, `view`,
`lsp`, `browser`. `term` is the namespace for the commands (`term.shell`,
`term.scratch_toggle`, etc.) but is not a registered group. The terminal button
now has a visual identity on the bufferline; a user who sees the button, clicks
it, wants to find the keyboard equivalent via the palette, and types `:term`
will find the commands — but they'll appear under the `ai` group filter, which
is cognitively mismatched (a shell is not an AI feature). The mismatch is
especially visible now that the terminal button is co-located with split buttons
that are in `group: "view"`.

**Evidence:**
- `src/command.rs:3630-3663` — all four `term.*` commands use `group: "ai"`
- `src/command.rs:4201-4215` — `view.split_right` / `view.split_down` use
  `group: "view"`

**Proposed fix:** Change the four `term.*` commands to `group: "term"`. Add
`"term"` to whatever group documentation or palette-group list exists (check
FEATURES.md and the help overlay generator). This is the minimal change;
it does not require renaming any command IDs.

---

### 4. Zen mode does not clear `split_strip_term_buttons` / `split_strip_buttons` · severity: medium

**What:** When zen mode is active, `src/ui/mod.rs:121-198` explicitly clears a
large set of stale click-rect vecs before the early return. `split_strip_buttons`
and `split_strip_term_buttons` are missing from that clear list. Both vecs are
populated by `paint_leaf_tab_strip`, which *is* called inside the zen-mode path
(via `render_layout` on line 170). The buttons DO render and click-register in
zen mode, which may be intentional — but if the layout changes between frames
while in zen mode, stale rects from the prior frame could steal clicks.

**Why it matters:** The pattern throughout zen mode's early-return block is
explicit: every vec that could contain stale rects gets cleared. Missing these
two vecs is inconsistent with that pattern even if it hasn't caused a visible
bug yet. It also means in zen mode a user who closes a split leaf leaves the
dead split buttons' rects registered for one more frame — enough for an
accidental click to fire on a deleted leaf.

**Evidence:**
- `src/ui/mod.rs:121-163` — explicit clear block; `split_strip_buttons` and
  `split_strip_term_buttons` absent.
- `src/ui/mod.rs:433-434` — these vecs ARE cleared in the non-zen path,
  confirming the intent.

**Proposed fix:** Add two lines to the zen-mode clear block (alongside the
existing `split_dividers` clear at line 160):
```rust
app.rects.split_strip_buttons.clear();
app.rects.split_strip_term_buttons.clear();
```

---

### 5. ASCII fallback strings are 2 cells wide, not 3 · severity: low

**What:** In ASCII mode (`config.ui.ascii_icons = true`), the three buttons
render with these strings: `">_"` (terminal), `"|+"` (V-split), `"_+"` (H-split).
Each is 2 characters, but the surrounding ` glyph ` template adds a leading
space and a trailing space, producing `" >_ "` (4 cells). The const
`SPLIT_BTN_W = 3` / `SPLIT_BUTTONS_W = 9` allocate 3 cells per button. The
extra cell overflows by 1 per button, pushing the rightmost button 3 cells
right of the reserved area and overlapping the pane body.

**Why it matters:** ASCII mode is the usability fallback for environments
without Nerd Font coverage. A user in that environment sees the rightmost
H-split fallback `_+` rendered 3 columns into the pane body on every frame.

**Evidence:**
- `src/ui/bufferline.rs:691-693` — `">_"`, `"|+"`, `"_+"` are each 2 chars.
- `src/ui/bufferline.rs:704-708` — format is `" "` + glyph + `" "` = 4 cells.
- `SPLIT_BUTTONS_W = 9` at line 669 allocates exactly 9 cells for 3 × 3,
  but each ASCII button occupies 4 cells → 12 cells total.

**Proposed fix:** Use single-character ASCII fallbacks:
- terminal: `"$"` (shell prompt) or `"T"`
- V-split: `"|"` (vertical bar reads as the split line)
- H-split: `"-"` (horizontal bar)

Each is 1 char, renders as ` $ `, ` | `, ` - ` (3 cells each = 9 total,
matching `SPLIT_BUTTONS_W`). Apply identically to the `mod.rs` copy.

---

### 6. `icon_for_pane` duplicates `bufferline::draw`'s glyph dispatch · severity: low

**What:** The function `icon_for_pane` at `src/ui/mod.rs:2177-2223` is a
copy of the per-pane glyph lookup already present inline in
`src/ui/bufferline.rs:237-270`. Both must be kept in sync as new `Pane`
variants are added. The comment at line 2178 acknowledges this: "duplicates
the dispatch in `bufferline::draw` but kept inline here so the per-leaf tab
strip doesn't need a public API on bufferline."

**Why it matters:** As of this commit the two tables ARE in sync, but any
future `Pane` variant addition will require a change in two places. There are
already 23 pane variants; the pattern will drift. This is a maintainability
smell, not a user-visible bug today.

**Proposed fix:** Extract a `pub fn icon_for_pane(pane: &Pane, nerd: bool) -> (&'static str, Color)`
from `bufferline.rs` as a public function and call it from both sites. The
"no public API" concern is already moot — `paint_split_buttons` and
`SPLIT_BUTTONS_W` are `pub` in `bufferline.rs`.

---

## Patterns that are working well

**Dual-site symmetry is complete.** Both the single-leaf bufferline path
(`paint_split_buttons` in `bufferline.rs`) and the multi-leaf per-strip path
(`paint_leaf_tab_strip` in `mod.rs`) now have all three buttons with the same
glyph set, the same 3-cell width, and the same click dispatch. The reserved
space (`SPLIT_BUTTONS_W` / `SPLIT_BTNS_TOTAL`) is consistent. This is the
right structure.

**Click handlers are correctly ordered.** In `tui.rs:4694-4730`, the dispatch
checks split-tab-close BEFORE split-tab-switch, and terminal-button BEFORE
V/H-split. That priority order prevents the close badge from being shadowed
and prevents the terminal button from being swallowed by the split buttons.

**Tab strip scroll math correctly accounts for the new 9-cell reservation.**
`tabs_max_x` at `bufferline.rs:120-123` subtracts `SPLIT_BUTTONS_W` before
the tab layout loop, so the overflow chevrons and tab clipping continue to work
correctly. The `‹`/`›` chevrons are unaffected by the commit.

**Glyph fix is correct.** `\u{eb55}` → `\u{eb57}` for the horizontal-split
button was the right fix. The old `eb55` is nf-cod-split_horizontal with the
wrong orientation; `eb57` (nf-cod-split_vertical) correctly renders stacked
panes.

---

## Out of scope but noted

**`term.shell` has no default keyboard binding.** The command description says
"Terminal: open a NEW shell (split below)" with `keys: &[]`. `Ctrl+T` is bound
to `term.focus_or_open_shell` (focus-or-open), not to `term.shell` (always
opens new). The terminal button calls `open_shell()` directly (new shell,
not focus-or-open). This behavioral gap — button vs keyboard — is a design
decision the author may have made deliberately, but it means the button and
`Ctrl+T` have subtly different semantics. Not a bufferline design bug per se,
but worth being explicit about in the tooltip text (issue 1's proposed fix
addresses this by surfacing "ctrl+t = focus or open" as the sublabel).

**The cluster background blends correctly.** Both `paint_split_buttons`
(bufferline) and `paint_leaf_tab_strip` (mod.rs) use `t.bg_darker` for the
button bg — the same value as the surrounding bufferline / strip bg. The
buttons are therefore visually embedded in the strip, not set off. Whether
this is the intended "quiet" treatment or an accidental blend is a pixel-level
judgment call that requires real eyes. Flagged for awareness only.
