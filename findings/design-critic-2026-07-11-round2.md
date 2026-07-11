---
review: overlays-fold-arrows-activitybar-chords
agent: design-critic
date: 2026-07-11
---

## TL;DR
The recent batch is functionally solid (regression tests, careful UTF-8 handling,
good commit hygiene) but shipped two sibling overlays same-day that quietly
diverge from each other and from the established caret/row/hint conventions, and
the fold-arrow priority ordering has a real discoverability hole for the single
most common editing state: a header line with an uncommitted git change.

## Issues found

### 1. Caret color disagrees between the two overlays shipped the same day · severity: medium
**What:** glyph_builder's text-field caret is `fg(bg_dark).bg(fg)` (inverted using
theme fg); integration_edit's caret is `fg(bg_dark).bg(cyan)`. Same feature
(9fcd0b4 / 2221f99), same day, two different caret colors, and neither matches
the ex-prompt's native terminal cursor (`app.rects.prompt_caret`, a real blinking
hardware caret, not a painted cell).
**Evidence:** `src/ui/glyph_builder_overlay.rs:223` vs `src/ui/integration_edit_overlay.rs:134`; `src/ui/prompt.rs:3-4,47,193-194`.
**Proposed fix:** Pick one caret color (cyan bg reads better against both
light/dark themes since it's already the "focus" accent used elsewhere in both
panels) and use it in both; add a `design_tokens::text_field_caret_style()` so a
third overlay can't reintroduce a third color.

### 2. Both overlays' hint rows don't match their own shared helper's doc comment · severity: low
**What:** `design_tokens::paint_hint_row` is documented as producing
`Tab field · ↵ save · esc cancel`-style lines, but glyph_builder renders
`"Tab field · … · esc"` and integration_edit renders `"Tab · … · esc"` — both
drop "cancel", and only one keeps "field" after Tab.
**Evidence:** `src/ui/design_tokens.rs:154`; `src/ui/glyph_builder_overlay.rs:177`; `src/ui/integration_edit_overlay.rs:198`.
**Proposed fix:** Normalize to `"Tab field · <edit hints> · ↵ <verb> · esc cancel"` in both, and update the doc comment if "cancel" is being deliberately dropped for space.

### 3. New overlay rows drop the settings-row colon convention · severity: low
**What:** CLAUDE.md's Family Settings convention is `▸ <label>:  [value] *` with
the colon baked into the label and trailing-space alignment. Both new overlays
use `{label:<11}` / `{label:<12}` with no colon at all (`path`, `id`, `command`
render bare). Settings itself uses `{:30}  ` with colon-in-label.
**Evidence:** `src/ui/glyph_builder_overlay.rs:128`; `src/ui/integration_edit_overlay.rs:120`; `src/ui/settings_overlay.rs:189`.
**Proposed fix:** Either fold these two panels' rows into the documented
`▸ label: value` shape, or explicitly scope the CLAUDE.md convention to
Settings-only overlays so future panels aren't held to a rule they were never
meant to follow.

### 4. Fold hover-arrow is fully hidden on any line with a git change, diagnostic, or breakpoint · severity: high
**What:** Sign-column priority is continuation → dap-arrow → breakpoint →
error/warning → git-change → info/hint → fold-arrow (lowest). The *hover-only*
`▾` foldable-arrow (unfolded state) has **no fallback at all** when suppressed —
unlike the folded `▸` case, which at least has the `⋯ N hidden` chip on the same
line. A user actively editing a function (git-change mark on the header line —
an extremely common state while coding) will hover that line and see nothing;
clicking does nothing either, since the click rect is only emitted when the
arrow is drawn.
**Evidence:** `src/ui/editor_view.rs:510-578` (priority chain + `fold_arrow_rows.push` only inside the `is_folded`/`is_foldable` branches).
**Proposed fix:** For the *unfolded, foldable* case only, still draw the fold
arrow when hovered even if a git/diagnostic mark would otherwise win — e.g. flash
the arrow on hover with the mark showing on non-hover frames — since hover is a
transient, opt-in signal and won't visually compete with the persistent mark.

### 5. Modal-block guard is copy-pasted per overlay, not a single mechanism · severity: low
**What:** Three separate `App.rects` fields (`settings_overlay_rect`,
`integration_edit_overlay_rect`, `glyph_builder_overlay_rect`) each independently
guard mouse click leak-through, checked at three different call sites in
`tui/mouse/mod.rs`. Every new modal overlay needs its own field + its own guard
clause remembered by hand — exactly the kind of thing that regresses (74eb3fa
was a bug fix for a panel that forgot this).
**Evidence:** `src/app/mod.rs:2267,2273,2279`; `src/tui/mouse/mod.rs:629,675,818`.
**Proposed fix:** Replace the three fields with one `active_modal_rect: Option<Rect>` set by whichever overlay is topmost each frame, checked once in the mouse dispatcher before any pane/tree click routing — closes the class of bug, not just the three instances.

### 6. `Ctrl+1..8` bufferline focus vs. vim/tmux window-number muscle memory · severity: low
**What:** New `Ctrl+1`..`Ctrl+9` (d8690f12) matches VS Code, but mnml also ships
vim-mode as a first-class input handler. Vim/tmux users' strongest `Ctrl+<num>`
association is tmux `Ctrl+b <num>` (different prefix, no real collision) — low
risk, but worth a one-line help-overlay mention since this is the first `Ctrl+<digit>`
family bound with no leader, in a codebase that otherwise routes numbered actions
through `<leader>` or `g` prefixes.
**Evidence:** `src/command.rs` (`view.focus_tab_1..8`, `view.focus_tab_last`).
**Proposed fix:** No code change; just confirm it's listed in the keybindings help overlay so it's discoverable outside muscle memory.

## Patterns that are working well
- The 74eb3fa/29f625f/dcf69c3 fix chain shows real regression discipline: click
  rects, focus rows, and Shift+Tab direction were all caught and fixed same-day
  with clear commit provenance tied to hunter-report IDs.
- `view.focus_tab_last` correctly implements VS Code's "9 = last, not literal
  9th" semantic rather than a naive index — good attention to the source
  convention rather than a surface-level copy.
- The Ctrl+G triple-context split (vim file-info vs standard goto-line vs
  Claude Agents group-by cycle) is intentional and well-commented at each site
  — a good example of the pluggable-input-layer contract working as designed
  rather than accidental overload.

## Out of scope but noted
- HTTP filter chip missing a right-click menu (vscode-mouse round 2) — not
  re-litigated here, still open.
- `search_case_mode` / sibling state-field naming audit was inconclusive — no
  field by that name found in the current tree; flag to the requester in case
  it's mid-branch or already renamed.
