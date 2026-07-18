# design-round-4 — polish-stream audit (2026-07-14)

Design-critic pass over the last several sessions of polish work: hover popup
redesign, TypeScript inlay hints, tree chevron unification, bufferline
hover-close, AI chip right-click menu, HTTP-panel section menus + filter
isolation, right-panel v2, palette recents-at-top, `Ctrl+Shift+E`, the `@`
picker-prefix toast, the grep-unavailable chip, and the menu-bar mnemonic
fix. Read-only pass (source + `git show` on the landing commits); no code
changed.

Nine findings: 1 high, 5 medium, 3 low. The strongest one (#1) is a
same-session regression risk — the newly-shipped mnemonic feature silently
breaks itself on the menu it matters most for (View, the keyboard user's
toggle menu).

---

## Issue 1 — Menu-bar mnemonics collide silently; View menu breaks on 6 of 8 items
**Category:** Chord conflict
**Severity:** high

**What:** The keyboard-round-9 mnemonic fix (`f3370600`) matches a pressed
key against the **first alphabetic letter of each item's label** and fires
the first match — no collision handling, no cycling through same-letter
items on repeat press, no underline to show which letter is "claimed."
Several menus have heavy label-prefix collisions, so most of their items are
now *unreachable* by the very feature meant to make them keyboard-fast:

- **View** (`src/menu_bar.rs:249-298`): "Toggle file tree", "Toggle right
  panel", "Toggle bufferline", "Toggle word wrap", "Toggle zen mode",
  "Toggle hover-help strip", "Toggle theme" — **7 of 11 items start with
  T.** Pressing `T` always fires "Toggle file tree"; the other six toggles
  (including zen mode and hover-help, both mouse-hard-to-reach) can only be
  reached with arrow keys or the mouse.
- **File** (`src/menu_bar.rs:131-176`): `O` always opens "Open file…"
  ("Open folder…" unreachable); `S` always fires "Save" ("Save all" and
  "Settings…" unreachable).
- **Edit** (`src/menu_bar.rs:178-208`): `F` always fires "Find…" ("Find
  next", "Find previous", "Find in files…" unreachable); `R` always fires
  "Replace…" ("Replace in files…" unreachable).
- **Selection** (`src/menu_bar.rs:213-244`): `A` always fires "Add cursor
  above" ("Add cursor below", "Add cursor at next match" unreachable).

**Why it matters:** This is the exact "advertise a keyboard path, then the
keyboard path silently does the wrong thing" pattern the same commit was
written to fix (mnemonic-letter leak). A user who's learned "Alt+V then T"
opens the file tree fine, but "Alt+V then T" a second or third time (hoping
to reach hover-help or zen mode) keeps re-firing "Toggle file tree" with no
feedback that anything went wrong — worse than no mnemonic at all, because
it *looks* like it's working.

**Evidence:** `src/tui/mod.rs:543-566` (`find_map` returns first match,
no dedup/cycle); `src/menu_bar.rs:249-298` (View), `:131-176` (File),
`:178-208` (Edit), `:213-244` (Selection).

**Proposed fix:** Either (a) pick a genuinely unique mnemonic letter per
item within each menu (VS Code/GTK convention — not necessarily the first
letter, e.g. "Toggle **r**ight panel", "Toggle **w**ord wrap", "Toggle
**z**en mode", "Toggle **h**over-help") and underline it in the render, or
(b) make repeat-presses of a colliding letter cycle through the matches
(classic Windows/GTK "type the same letter again to move to the next
match" behavior). (a) is cheaper and gives users a permanent visual cue via
underline; (b) needs no relabeling but needs state (`last_mnemonic_char`,
`last_mnemonic_idx`).

---

## Issue 2 — "Hide these icons" on the AI chip menu has no way back except a memorized palette command
**Category:** Discoverability
**Severity:** medium

**What:** The AI chip's new right-click menu (`d537ac1e`) adds a visibility
submenu including "Hide these icons," which sets `[ui] tab_bar_ai_icon =
"none"`. Once fired, the chip that hosted the menu disappears — so
right-click-to-undo is gone. The four backing commands
(`view.tab_bar_ai_claude_only/codex_only/both/none`) are registered with
`keys: &[]` and the field is **not** in the Settings overlay (unlike its
sibling toggles `editor.inlay_hints` and `hover_help`, both of which are
settings rows — `src/app/settings.rs:665-668`, `:1052`).

**Why it matters:** A user who clicks "Hide these icons" out of curiosity
(or fat-fingers it — it's the 4th item in a 5-item visibility block, right
next to "Show both") has to already know the palette id
`view.tab_bar_ai_both` (or open `config.toml` by hand) to get the chip
back. Every other config-flip this session shipped alongside a Settings row
or a persistent visible toggle; this one is a one-way door discoverable
only in the palette.

**Evidence:** `src/tui/mouse/right_click.rs:1053-1090` (menu items,
`is_codex` glyph_cp branch); `src/command.rs` (`view.tab_bar_ai_none` etc,
`keys: &[]`); `src/app/settings.rs:665-668,1052` (sibling rows present,
`tab_bar_ai_icon` absent).

**Proposed fix:** Add `ui.tab_bar_ai_icon` as a Settings discrete-choice row
(`▸ AI tab-bar chips:  [claude] / codex / both / none`) — it's a 4-value
enum, a perfect fit for the v1 Settings capability already used by
`hover_help` and `inlay_hints` right next to it in the same config struct.

---

## Issue 3 — `tab_bar_ai_icon` doc comment contradicts its own default
**Category:** Naming
**Severity:** low

**What:** The field doc at `src/config.rs:801-814` reads `"both" (default
2026-07-09)` and shows `tab_bar_ai_icon = "both"` as the example TOML. The
actual `Default` impl two sessions later (`src/config.rs:1533-1537`) sets
`"claude_code"` and explains the flip in a comment — but the doc comment
above the field was never updated to match.

**Why it matters:** Small, but this is exactly the kind of drift that
compounds — a future contributor (or Claude session) reading the struct doc
first will confidently state the wrong default, and the doc's own example
TOML block now demonstrates a non-default value without saying so.

**Evidence:** `src/config.rs:806-814` vs `src/config.rs:1533-1537`.

**Proposed fix:** Update the doc comment's "(default 2026-07-09)" annotation
and example TOML to match the current default (`"claude_code"`), or restore
`"both"` as the default if the 2026-07-12 flip was meant to be session-local
— pick one and make the comment and the code agree.

---

## Issue 4 — Inlay hints render as an end-of-line list, which strips the positional meaning parameter-name hints exist for
**Category:** Ergonomics
**Severity:** medium

**What:** All inlay hints on a line — type hints, parameter-name hints,
return-type hints — get concatenated into a single `· `-separated chip
painted at end-of-line (`src/ui/editor_view.rs:963-1027`), rather than
inline at each hint's actual column (VS Code's behavior, and what
`textDocument/inlayHint`'s per-hint `character` field is designed for).
Type hints on a `let`/`const` line mostly survive this fine (usually one
hint per line, appearing right after the thing it types). Parameter-name
hints on a multi-arg call site do not: their entire value is showing *which
positional argument maps to which parameter*, and end-of-line concatenation
removes that adjacency — `foo(1, 2, true)` becomes `foo(1, 2, true)  a: ·
b: · flag:` with no visual line connecting each hint back to its argument.

**Why it matters:** "Inlay hints" is a specific, well-known VS Code feature
name; a user who enables it expecting inline parameter names at call sites
gets a feature that only reliably helps for the type-hint case. The commit
history (`ed0e70a5` → `275648ab` → `4d0ed027`'s follow-ups) shows this was a
deliberate trade-off after inline-paint corrupted code — a legitimate
implementation constraint, not an oversight — but nothing in the toast
(`"inlay hints: on"`) or the command title ("type / parameter chips") warns
the user the parameter-name case is degraded.

**Evidence:** `src/ui/editor_view.rs:963-1027` (end-of-line concatenation,
comment at `:955-961` documenting the trade-off); `src/lsp/mod.rs:357-361`
(`InlayHint` has no `kind` field to distinguish Type vs Parameter, so even a
future fix has to infer the kind from label shape).

**Proposed fix:** Short-term: mention the trade-off in the toggle command's
title or a first-toggle-on toast ("inlay hints: on (end-of-line; VS-Code
style inline parameter names not yet supported)"). Longer-term: since column
data is already captured (`h.character`), a narrower fix scoped to
parameter-name hints specifically (short `name:` labels only, one per
argument) could still paint inline at the argument's column without
re-triggering the token-splicing bug that sent type hints to end-of-line —
type hints (longer labels, `: SomeGeneric<T>`) can stay end-of-line where
they're safe.

---

## Issue 5 — `#` (workspace symbols) picker-prefix has no "fetching…" toast; `@` (document symbols) does
**Category:** Discoverability
**Severity:** medium

**What:** `keyboard-round-9`'s fix for the `@` picker-prefix (`780d348c`)
added `app.toast("Symbols: fetching…")` before firing the async
`lsp.symbols` request, specifically because a slow/empty LSP reply left the
user staring at a closed picker with zero feedback. The sibling `#` prefix
(workspace symbols) two branches below it fires `lsp.workspace_symbols` the
same way, with the exact same async-black-hole risk, and got no toast.

**Why it matters:** `@` and `#` are documented together as siblings
(`"Symbols: fetching…"`/`@` = current-file symbols, `#` = workspace
symbols) — a user who hits the black-hole once on `#` has no reason to
expect `@` behaves differently, and vice versa. The fix only reached half
of the pair it was meant to cover.

**Evidence:** `src/tui/handlers/overlay.rs:422-449` — `@` arm (`:428-443`)
has the toast; `#` arm (`:444-448`) does not.

**Proposed fix:** Add the same `app.toast("Symbols: fetching…")` (or a
`#`-specific `"Workspace symbols: fetching…"`) to the `#` arm before
`crate::command::run("lsp.workspace_symbols", app)`.

---

## Issue 6 — "Symbols: fetching…" breaks the toast voice convention
**Category:** Naming
**Severity:** low

**What:** Every other toast added in this polish stream (and ~32 of 36
sampled across the codebase) is lowercase-first, colon-free-prefix, present-
tense (`"fetching…"`, `"inlay hints: on"`, `"tab-bar AI chips: hidden"`,
`"HTTP panel refreshed"` is one of only 4 outliers). `"Symbols: fetching…"`
introduces a `Title-Case-Word: ` prefix that doesn't match any other toast
in the codebase.

**Why it matters:** Toasts are a high-frequency, low-attention UI surface —
consistency in capitalization is what lets a user pattern-match "this is a
status toast" without reading closely. This is a one-line copy fix, called
out because it's a fresh regression against an otherwise-consistent
convention, landed in the same commit as issue #5.

**Evidence:** `src/tui/handlers/overlay.rs:440`; contrast with
`src/app/grep.rs:150` (`"grep unavailable — install ripgrep…"`, lowercase)
and `src/command.rs:1038` (`"inlay hints: {state}"`, lowercase).

**Proposed fix:** Lowercase to `"symbols: fetching…"` to match
`"inlay hints: {state}"` and `"tab-bar AI chips: {state}"`'s
`noun: state` shape.

---

## Issue 7 — Workspace-root context menus don't mirror the dir-row menu they claim to imitate, and the primary/extra workspace headers have drifted from each other
**Category:** Visual inconsistency
**Severity:** medium

**What:** `open_workspace_header_context_menu` (`src/app/context_menus.rs:
513-585`) got "Expand recursively" / "Collapse recursively" added on
2026-07-12 with the comment "the workspace header should get them too
since it IS a directory (the top one)." True as far as it goes — but the
same directory-row menu (`open_tree_context_menu`, is_dir branch,
`:220-253`) also has "New file…", "New folder…", "Cut", "Copy", "Paste
here", "Duplicate", "Move to…", none of which made it onto the workspace
header menu. A second, separate menu for **extra**-workspace headers
(`open_extra_workspace_header_context_menu`, `:589-662`) didn't even get
the 2026-07-12 Expand/Collapse-recursively addition, so right-clicking the
primary workspace header and an extra workspace header (visually identical
rows, same section-header idiom per the file-level doc comment) now offer
different verb sets.

**Why it matters:** A user who wants to create a new top-level file has no
"New file…" on the one row that represents the workspace root — they have
to right-click a specific existing file/folder inside it (if one exists) or
know a palette command. And a user who's learned "right-click the workspace
header → Expand recursively" from the primary workspace will find that
gesture silently missing when they try it on an extra (secondary)
workspace's header, no visible reason why.

**Evidence:** `src/app/context_menus.rs:220-253` (dir-row menu, full verb
set) vs `:541-564` (primary workspace header — has recursive expand/
collapse, missing New file/folder + clipboard ops) vs `:604-661` (extra
workspace header — missing recursive expand/collapse too).

**Proposed fix:** Factor a shared `directory_menu_items(path, is_root)`
builder used by all three call sites (dir row, primary header, extra
header) so the three menus can't drift again; root-only items (Set as
default workspace, Remove workspace) get appended on top instead of being
copy-pasted alongside a hand-maintained subset of the directory verbs.

---

## Issue 8 — Bufferline hover-close doesn't reveal on the tab a user is most likely to want to close: a dirty inactive tab
**Category:** Ergonomics
**Severity:** medium

**What:** The hover-close fix (`9691a806`) makes the `×` glyph appear on
any hovered inactive tab so it can be closed in one click — except when
that tab `is_dirty`. The badge-selection `if`/`else if` chain checks
`is_pinned` → `is_dirty` → `is_active` → `is_hovered` in that order
(`src/ui/bufferline.rs:218-226`), so a dirty tab always shows the orange
`●` regardless of hover state, and the close hit-rect is explicitly gated
`!inputs.is_dirty` (`:351-353`) — no close rect is ever registered for a
hovered dirty tab.

**Why it matters:** The commit's own stated motivation was "closing a
non-active tab took two clicks (focus → click ×)." Dirty (unsaved) tabs are
disproportionately the ones a user wants to dismiss quickly (scratch edit,
accidental change, "never mind") — and those are exactly the tabs this fix
doesn't help with. The two-click tax the fix was written to remove is still
there for the case it was arguably written for.

**Evidence:** `src/ui/bufferline.rs:218-226` (if-chain precedence),
`:351-353` (close-rect gate excludes `is_dirty`).

**Proposed fix:** On hover, let a dirty inactive tab's badge flip to `×`
too (in a color distinct from both the active-tab red and the plain-hover
grey, e.g. orange-tinted `×`, so "this will prompt to save" stays legible)
and register its close hit-rect the same as any other hovered tab — the
existing unsaved-changes confirm flow on `buffer.close` already handles the
"are you sure" step, so this is a render + hit-rect change only, no new
confirm logic needed.

---

## Issue 9 — HTTP-panel MOCKS section right-click menu is the only one of seven with no section-specific verb
**Category:** Missing verb
**Severity:** low

**What:** `open_http_panel_section_context_menu` (`src/app/context_menus.rs:
984-1041`) gives every section a creation/action verb — FILES → "New
request…", RECENT → "Clear recent history", CAPTURED → "Start capture" /
"Clear captured", ENVS → "New env…", CHAINS → "New chain…", COLLECTIONS →
"New collection…" — except MOCKS (`section 5`), which gets `vec![]` and
falls straight to the two universal items ("Toggle all sections", "Refresh
HTTP panel").

**Why it matters:** A user who's just learned "right-click a section header
= section verbs" from any of the other six sections will right-click MOCKS
expecting the same and get an empty-feeling menu with no way to tell if
that's intentional (mocks are derived from captures, no from-scratch
creation flow exists — `http.save_mock` / `http.replay_mock` are the actual
verbs, but neither is reachable from here).

**Evidence:** `src/app/context_menus.rs:1022` (`5 => ("MOCKS", vec![])`);
contrast with the other six arms at `:987-1029`.

**Proposed fix:** If mocks genuinely can't be created from scratch, add a
non-mutating discoverability item instead of leaving the section bare —
e.g. "How mocks work…" (opens the relevant hover-help/manual anchor) or
surface `http.save_mock` here if a request is currently open/focused. Even
a disabled/greyed placeholder row beats silently breaking the pattern the
other six sections just taught the user.

---

## Patterns that are working well

- **The `/`-filter idiom is genuinely unified.** HTTP, TODOs, Notes,
  Sessions, Agents, Cloud Agents, Integrations, and git-palette filters all
  share the same field-naming convention (`<panel>_filter_focused`), the
  same guard-hoist comment lineage (`src/tui/mod.rs:898-903`), and the same
  `/` → focus, Esc → clear+unfocus, Enter → accept+unfocus chord shape. This
  is exactly the kind of "one mechanism, many call sites" discipline
  CLAUDE.md asks for, and it shows.
- **Tree chevrons are now a single glyph pair used everywhere.** After
  three failed Nerd-Font attempts, `CHEVRON_OPEN`/`CHEVRON_CLOSED` (▼/▶,
  `src/ui/tree_view.rs:38-39`) are shared by tree section headers, tree
  folder rows, and the editor gutter fold arrows (`src/ui/editor_view.rs:
  577,596`, comment explicitly cross-references the tree's glyph choice)
  — a real example of resisting the temptation to let three near-identical
  chevron implementations drift.
- **The grep-unavailable persistent chip is a good escalation pattern.**
  Toast on first failure would have been ignorable; `toast_persistent` +
  explicit `toast_dismiss` on next success (`src/app/grep.rs:147-161`) is
  the right shape for "the tool is missing, not just this query failed,"
  and it self-clears instead of nagging forever.

## Out of scope but noted

- `MenuAction::Command("view.remove_workspace")` fired from the
  extra-workspace header menu's "Remove this workspace" item
  (`src/app/context_menus.rs:643-646`) doesn't appear to pass `ws_idx`
  through — worth a bug-hunt pass to confirm it removes the *right-clicked*
  workspace and not whichever one is currently focused/expanded. Functional
  question, not a design one; flagging for the user-sim agents.
- The command-palette (`:` cmdline popup) still has no `── Recent ──`
  header distinguishing recency-boosted rows from plain matches when a
  query is typed (only the per-row `★` marker) — this was raised in
  mouse-round-11 as SEV-3 and appears unchanged. Not re-litigated in detail
  here since it predates this polish stream.
