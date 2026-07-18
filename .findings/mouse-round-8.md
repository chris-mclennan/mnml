# mnml mouse hunt — round 8 (2026-07-11)

Headless drive against `~/Projects/mnml/target/release/mnml`, standard input,
workspace = a scratch `round8-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`src/long.rs` [178 lines], `docs/{notes,README}.md`, `api.http` +
`.mnml/env/dev.env` with `TOKEN=abc123`). Everything driven through
`.mnml/ipc/`. Focus: less-covered gutter / scrollbar / statusbar-menu /
pty / range-selection surfaces.

## Executive summary

**18 findings: 0 SEV-1 · 9 SEV-2 · 9 SEV-3.**

Two dead-zone families dominate this round. **(1) Range selection is
broken** — shift-click on a second cell doesn't extend a selection from
the first click (it just moves the caret), and click-and-drag inside the
editor doesn't select either (drag-select never materialises; the caret
just teleports to the release point). Between those two, a mouse user
has no way to select an arbitrary text range in the editor. Double-click
(word) and Alt-click (multi-cursor) both still work; triple-click "works"
but only in the vim-`V` sense (anchor at line-start, cursor stays put),
which for a VS-Code user looks like "less than the full line got
selected". **(2) The gutter is almost entirely dead to the mouse** —
clicking a line number doesn't select the line (VS Code's oldest gutter
gesture), clicking a git-change bar doesn't open the hunk peek popover
even though the hover tooltip advertises hunk navigation, and fold arrows
only ever render *while hovered* — there's no persistent "this line is
foldable" affordance, so a mouse user has to guess which lines are
collapsible.

Beyond those two families the rough spots are still discoverability:
right-click on a **preview** tab drops "Pin tab", "Copy path", and
"Reveal in Finder" from the menu (a mouse user can't discover those
verbs until they've promoted the tab); right-click on a **Pty** pane
serves the generic dock/maximise menu with no `Paste` / `Copy` / `Clear`
/ `Restart` — the four verbs a terminal-pane user actually wants; the
**language** chip has no click action (VS Code opens the language
picker); the **line-column** chip has no right-click menu (every other
statusline chip does); and **hover-switching between menu-bar items**
doesn't work — Edit stays open even as you hover File, so tearing
through the menu bar means click-to-close, click-to-open every time.

Positives that held up: click-in-track and drag on the editor scrollbar
both scroll (not just the thumb — the track is a real jump target),
click-outside dismisses palette / settings / menus, right-click on the
mode / branch / clock / workspace / file-size chips all give real
menus with sensible verbs, activity-bar gear opens a proper "mnml" menu
with Settings / Command Palette / Cheatsheet / Themes / About once the
tooltip clears, and Alt-click multi-cursor + typing lands on every
extra cursor (three-cursor typing verified across three separate lines).
**Could I get my day's work done without a chord?** — mostly, but the
day would include "select the paragraph I want to replace" which
currently doesn't have a mouse path at all.

---

## [SEV-2] Shift-click doesn't extend selection

**Reproduction** (`src/main.rs`, line 12 = `    let m: HashMap…`,
line 14 = `    println!("{}", compute(3, 4));`):
```jsonc
{"cmd":"click","col":45,"row":13}                       // caret at line 12 col 15
{"cmd":"click","col":60,"row":15,"mods":"shift"}       // expect: extend
{"cmd":"type","text":"YY"}
```

**Expected**: shift-click extends the selection from the first-click
anchor to the shift-click position. Typing replaces the selection. This
is the canonical VS-Code / macOS / Windows shift-click convention.

**Actual**: shift-click teleports the caret to the new position without
setting an anchor. Typing `YY` inserts at column 22 of line 14 —
`    println!("{}", compuYYte(3, 4));`. No selection ever existed.

**Impact**: a mouse-first user cannot select a range that spans more
than one word (double-click) or line (triple-click SelectLine, which
itself is Vim-`V` shaped — see next finding). "Select from here to
there" is the most fundamental range-selection gesture in every GUI
editor since 1984 and it doesn't work.

**Source pointer**: `src/tui/mouse/down_left.rs` — the editor-body
click branch only tracks multi-click count and Alt/Ctrl; it never
checks `KeyModifiers::SHIFT` to promote the click into
"anchor stays, cursor moves".

---

## [SEV-2] Click-and-drag in the editor doesn't select text

**Reproduction**:
```jsonc
{"cmd":"drag","from_col":30,"from_row":3,"col":60,"row":5}
{"cmd":"type","text":"REPLACED"}
```

**Expected**: drag from (30, 3) to (60, 5) sweeps a rectangular /
character selection through those coordinates; typing replaces the
selection. VS Code's default drag gesture.

**Actual**: the caret ends up at the release point, no anchor is set,
no visual highlight appears, and `type` just inserts REPLACED at the
release position — splitting an existing word in half in my run
(`rREPLACEDesult` — REPLACED landed inside `result`).

**Note**: `down_left.rs:2790` sets `app.drag_select = Some((pid, row,
col, false));` when a single-click armed a possible drag. Either the
`Drag(left)` step handler isn't reading that flag, or the flag isn't
being flipped to true on the first movement event. IPC's `drag`
command *does* synthesise `Down → Drag-per-step → Up` (verified via
the palette right-panel edge drag — that one works fine), so the
missing piece is in the editor-body drag handler, not in IPC.

**Impact**: same as the shift-click gap — no way for a mouse user to
select an arbitrary character range.

---

## [SEV-2] Preview tabs' right-click menu is missing Pin / Copy path / Reveal in Finder

**Reproduction**:
```jsonc
{"cmd":"click","col":15,"row":6}                        // Explorer → notes.md (preview)
{"cmd":"click","col":52,"row":1,"button":"right"}       // right-click notes.md tab
{"cmd":"snapshot"}
```

**Expected**: same right-click menu on preview and pinned tabs; the
preview state is a *promotion* affordance, not a *feature-gating*
affordance.

**Actual**: side-by-side of the two menus rendered in the same session
(pinned tab = `lib.rs`, preview tab = `notes.md`):

| pinned (lib.rs)      | preview (notes.md) |
|----------------------|--------------------|
| Unpin tab            | Close              |
| Close                | Close others       |
| Close others         | Close all          |
| Close all            | Split right        |
| Copy relative path   | Split down         |
| Copy absolute path   | Split left         |
| Reveal in Finder     | Split up           |
| Split right          |                    |
| Split down           |                    |
| Split left           |                    |
| Split up             |                    |

Missing from preview menu: **Pin tab** (the exact verb the user is
looking for when they right-click a preview tab), **Copy relative
path**, **Copy absolute path**, **Reveal in Finder**.

**Impact**: three of the seven "chrome affordances" are hidden until
the tab is somehow promoted first. And "Pin tab" being missing from
the preview menu is particularly punishing — the whole point of
right-clicking a preview is often to pin it.

**Source pointer**: `src/tui/mouse/right_click.rs` (bufferline_tab
handler) — the menu builder is likely branching on `is_preview` and
building two separate menus rather than one menu whose *contents*
dynamically toggle `Pin ⇄ Unpin` at row 0.

---

## [SEV-2] Pty pane right-click has no terminal-specific actions (no Paste, Copy, Clear, Restart)

**Reproduction**:
```jsonc
{"cmd":"open-pty","command":["bash"]}
{"cmd":"click","col":60,"row":26,"button":"right"}      // right-click inside the pty body
```

**Actual menu**:
```
Dock left
Dock right
Dock top
Dock bottom
Maximize width
Maximize height
Full screen (zen)
Equalize splits
Close pane
```

That is the generic **pane-management** menu, identical to what you'd
get on any editor pane. It has **no** terminal-specific entries:
- **Paste** — right-click-to-paste is the most reflexive terminal
  gesture (macOS Terminal.app, iTerm2, Kitty, Alacritty, Ghostty).
- **Copy selection** — the flip side of that gesture.
- **Clear** / **Reset** — `Ctrl-L` isn't obvious to a non-terminal
  user.
- **Restart shell** — flagged as missing in Round 7 (SEV-3) for `btop`
  Pty tabs; still missing here.
- **Send SIGINT** — same.

**Impact**: someone who's used to iTerm2 or Ghostty will right-click
inside the bash pane expecting Paste and get "Dock top" instead —
which is a strong "this isn't a terminal" signal in the exact spot
where the affordance should feel most native.

---

## [SEV-2] Line-numbers chip in the gutter is not a click target

**Reproduction**:
```jsonc
{"cmd":"click","col":50,"row":13}   // put focus in the editor
{"cmd":"click","col":33,"row":6}    // click on the digit "5" (line 5's gutter number)
```

**Expected**: cursor jumps to line 5. VS Code / Sublime / IntelliJ /
JetBrains all treat a line-number click as "select this line" (Sublime
selects the whole line; VS Code moves the caret to line-start).

**Actual**: caret stays at line 12 col 15 (from the previous
click). Nothing visible happens. Verified with three line numbers
across the visible window.

**Impact**: the most common gutter gesture doesn't work. Combined with
"drag doesn't select" this means the user's only way to select line 5
is `↓↓↓↓` in vim mode or `↓ Home Shift+End` in standard mode.

---

## [SEV-2] Git-change bar clicks do nothing (no hunk peek / no revert)

**Reproduction** (`src/main.rs`, uncommitted change block at lines
21-23):
```jsonc
{"cmd":"click","col":31,"row":21}                      // click the ▎ marker
```

**Expected**: VS Code opens a hunk peek popover with Revert / Stage /
Copy diff / Next hunk / Previous hunk. GitLens adds annotations. Even
a mere "select the changed lines" would be actionable.

**Actual**: silent no-op. Caret doesn't move; no popover opens; no
toast. Meanwhile the *hover* tooltip on the same rect (`col=25 row=23`)
reads `▎ git: added (line 22) / ] c / [ c jumps hunks` — advertising
`]c` / `[c` which are keyboard-only vim chords. The mouse user hovers
the bar, learns nothing they can *click*, and moves on.

Suggested minimum: left-click = open hunk peek; right-click = menu
(Revert hunk / Stage hunk / Copy diff / Show hunk history).

---

## [SEV-2] Fold arrows only render on hover — no persistent "this line is foldable" affordance

**Reproduction**:
```jsonc
{"cmd":"snapshot"}                             // gutter shows only line numbers, no arrows
{"cmd":"hover","col":40,"row":4}               // hover the fn line
{"cmd":"snapshot"}                             // NOW a ▾ appears at col 25
{"cmd":"click","col":25,"row":4}               // click the arrow → block folds ✔
```

**Expected**: a discoverable, persistent glyph in the gutter for every
foldable header line (VS Code renders a `⌵` on hover but shows a
constant grey `▶`/`▼` when the gutter is "always show fold controls"
— and its default setting since 2021 is to hover-reveal). At minimum,
some indicator that the feature exists.

**Actual**: unless the user parks the mouse on a foldable header for
long enough to trigger hover render, they will never discover fold
exists. There's no palette command labelled "fold" that shows up in
`Ctrl+K`-less browsing either. The **first-time-user's odds of ever
folding a block via mouse are effectively zero**.

Bonus finding while confirming this: the fold-arrow click rect is not
exported to `rects.json` (only `tree_icon:file.new_folder` matches a
"fold"-family label). So the click-rect audit tooling can't verify
fold-arrow presence — it's a rendered glyph that happens to have a
click handler behind the same coordinates, without a named rect.

---

## [SEV-2] The Language chip has no click / right-click action

**Reproduction**:
```jsonc
{"cmd":"hover","col":117,"row":38}            // hover the "rs" chip on the far right
```

Tooltip:
```
language: rs
detected from file extension
```

- No `click:` hint in the tooltip (every other statusline chip's
  tooltip includes one).
- `{"cmd":"click","col":117,"row":38}` — no visible action.
- `{"cmd":"click","col":117,"row":38,"button":"right"}` — no menu.

**Expected**: click opens the language picker (`Set File Association`
in VS Code); right-click menu offers "Reset detection", "Show
language server logs", "Toggle rust-analyzer". At minimum the click
should do *something*.

**Impact**: for polyglot repos where mnml guessed wrong (e.g. `.env` →
plain vs shell), the user has no mouse path to override.

---

## [SEV-2] Menu-bar hover-switch is broken

**Reproduction**:
```jsonc
{"cmd":"click","col":16,"row":0}       // open Edit menu (menu_bar:2)
{"cmd":"hover","col":5,"row":0}        // hover File menu bar (menu_bar:0)
```

**Expected**: hovering an adjacent menu-bar item while a menu is open
switches to that item's menu. Standard macOS / Windows / GTK menu-bar
behavior since the 1990s.

**Actual**: hovering File shows a **tooltip** overlay
(`click: open menu / Alt+M`) *on top of* the still-open Edit menu.
The tooltip and the previous menu overlap. To switch, the user has to
click Edit to close it, then click File to open File — every time.

**Impact**: tearing through menu bars to look for a specific action is
a very common mouse workflow. Right now it's a click-per-menu.

---

## [SEV-3] Triple-click selects only line-start-to-cursor, not the whole line

**Reproduction**:
```jsonc
{"cmd":"click","col":50,"row":6}
{"cmd":"click","col":50,"row":6}
{"cmd":"click","col":50,"row":6}
{"cmd":"type","text":"REPLACED"}
```

**Expected**: VS Code / Sublime / most GUI editors: triple-click selects
the *entire* line (including trailing whitespace). Typing replaces the
whole line with `REPLACED`.

**Actual**: line 5 (`    for _ in 0..y {`) becomes `REPLACED..y {` —
i.e. only the prefix from col 1 through the caret position (~col 15)
was selected; the rest of the line (`..y {`) survived. This is Vim `V`
semantics (`SelectLine` sets `anchor = line_start` but leaves `cursor`
where it is — see `src/editor/mod.rs:2277`), which is technically
consistent with the modeless CLAUDE.md doctrine but is confusing for a
mouse-first user who expects triple-click to yield "the whole line".

Suggested fix (standard mode only): triple-click sets `cursor =
line_end + 1` so `type` replaces the full line. Vim mode keeps the
`V` shape.

---

## [SEV-3] Statusline lncol chip has no right-click menu

Every other statusline chip in this round produced a menu on
right-click:
- **mode chip** → "Input style" menu (Use vim / Use standard / Toggle
  keymap)
- **git branch chip** → "git ops menu" (per tooltip)
- **clock chip** → Show local time / Show UTC / Hide clock
- **workspace chip** → Switch repo / Next repo / Previous repo /
  Worktrees / Switch workspace / Add workspace / Manage workspaces /
  Refresh repos / Reveal in Finder
- **file chip** → "buffer menu" (per tooltip)
- **file-size chip** → click opens `:Stat`
- **LSP chip** → tiny "Status" menu (arguably too shallow — see next)

The **lncol chip** (`x=78, w=15`, rendered as `Ln 14/178 Col 22`) has:
- click → nothing
- right-click → nothing

Would benefit from: click = goto-line prompt; right-click = "Column ⇄
character", "Show line-end position", "Toggle sticky selection".

---

## [SEV-3] LSP chip right-click menu is a single "Status" row

Right-clicking `statusline_lsp_chip` renders:
```
┌ LSP ───────┐
│ Status     │
│            │
└────────────┘
```
Just one action, "Status" (which fires `:LspStatus`). The empty row
below it is an accidental visual artefact.

Expected additions: **Restart LSP**, **Show clients**, **Show logs**,
**Disable for this file**, **Disable globally**. VS Code's language
server chip menu has 6-8 verbs in it — that's what a right-click on
the LSP chip should feel like.

---

## [SEV-3] Menu bar tooltip on a bar item overlaps the currently-open menu

Adjacent to the hover-switch SEV-2 above but distinct: when you *do*
manage to hover a menu-bar item while another menu is open, the
tooltip renders on top of the open menu (see repro above — the "click:
open menu / Alt+M" tooltip overlaps the still-open Edit menu). Whichever
strategy for hover-switch you take, at minimum suppress the
menu-bar-item tooltip while any menu is open.

---

## [SEV-3] Long absolute paths in tooltips (again)

Round 7 flagged the `..` tree-up-row tooltip. Same shape here:

- `statusline_file_chip` hover renders the full 108-char absolute
  workspace-plus-file path, stretching the tooltip box to the full
  terminal width. Recommend middle-ellipsis
  (`/private/tmp/…/round8-ws/src/main.rs`) or last-two-segments only.
- `..` up-nav row tooltip: same problem as before (confirmed
  unchanged).

---

## [SEV-3] Theme-toggle chip has no right-click menu

Hovering `bufferline_theme_toggle` (`x=113, w=4`, rendered as `●━`)
shows `theme: onedark / click: toggle between configured themes`.
Right-click produces no menu.

Recommend: right-click → "Pick theme…" (opens the theme picker VS Code
style), "Reset to default", "Configure themes".

---

## [SEV-3] The bufferline "new tab" button (+) has no right-click menu

`bufferline_new_tab_button` (`x=110, w=3`) tooltip:
`click: open a new scratch buffer`. Right-click: nothing.

Would benefit from: **New file…** (with a name prompt) / **New from
template** / **Open recent file…** / **Reopen closed tab**.

---

## [SEV-3] Split-strip icons on the pane-header aren't discoverable — hover only shows a bare label

Hovering `split_strip:*:Horizontal` renders a tiny tooltip
`split right` (three chars, no verb, no click hint). Same for the
vertical icon (`split down`). This is enough for a returning user but
gives no click-hint for first-time discovery (compare to the palette
chips' more verbose `click: … · right-click: …` shape).

The AI split-strip (`split_strip_ai_claude` / `split_strip_ai_codex`)
has a better tooltip:
`open Claude / Codex in this split / click a chip to spawn ·
right-click: menu`. Aligning the plain split icons on that pattern
would fix the discoverability.

---

## [SEV-3] Right-panel edge has no double-click reset / no right-click menu / no hover tooltip

`right_panel_edge` (`x=87, w=1`):
- **Hover** → no tooltip. (`tree_edge` shares the same silence.)
- **Double-click** → no width reset. (There's an in-source comment
  around `src/lib.rs:465` that says `drag: resize · double-click: reset
  width` — but the tooltip only fires elsewhere and the double-click
  handler didn't trigger a reset in my run — width stayed at whatever
  it was.)
- **Right-click** → no menu.

VS Code's sidebar/panel edges give a right-click menu with
"Reset panel size", "Hide panel", "Move panel to right/bottom". The
right-panel edge is the exact place where "reset panel width" belongs.

Same three gaps apply to `tree_edge` (the left sidebar's resize
handle).

---

## Positives worth preserving

- **Editor scrollbar**: both **thumb drag** and **click-in-track**
  scroll the buffer. Thumb drag from `y=3` to `y=20` scrolled to
  ~line 30; click at `y=30` jumped to ~line 124; cursor stays put
  during scroll (VS Code convention).
- **Scroll wheel over editor** scrolls smoothly; positive `dy` shows
  history / earlier lines (matches IPC schema).
- **Mode chip left-click** toggles Vim ⇄ Standard; right-click opens
  the "Input style" menu.
- **Click-outside dismisses** the palette, settings, mode-chip menu,
  clock menu, workspace menu, LSP menu, tree right-click menu, and the
  activity-bar gear menu.
- **Activity-bar gear** opens a proper "mnml" menu with Settings /
  Command Palette / Cheatsheet / Themes / About once the tooltip
  clears out of the way.
- **Settings overlay** click-to-set: clicking `relative` in the
  `Line numbers` row changed the value from `[absolute]` to
  `[relative]` immediately, added the `*` modified marker, and click
  on another option (`off`) switched it again. Fully mouse-driven.
- **Alt-click multi-cursor** places extra cursors on separate lines;
  a subsequent `type` command inserts at all cursors *including* the
  primary. Confirmed line 2 / line 4 / line 6 all received the typed
  `AA`.
- **Fold arrow click (when visible)** correctly folds the block and
  a second click on the persistent `▸` marker unfolds it.
- **Middle-click** on a bufferline tab closes it. Middle-click on the
  bash Pty tab did NOT close it (silent no-op — see Note below).
- **Bufferline overflow indicator (`‹`)** click scrolls the tab strip
  by one position.
- **File-chip click** reveals the active file in the tree.
- **Filesize-chip click** fires `:Stat` and prints a one-line summary
  at the cmdline.
- **Search results click** on an individual hit line (`3:4  fn
  compute…`) jumps the editor to that file+line — verified caret
  landed at line 3 col 4 of `main.rs`.
- **`bufferline_tab_close` (×)** hits the correct tab even when
  the bufferline is overflowed / mid-scroll.
- **Right-panel drag-resize** honours a minimum width (~9 cells) —
  dragging past the min clamps rather than crashing.

---

## Notes / open questions for the code owner

- **Middle-click on a Pty tab was silently ignored** during my test
  run (middle-click on an editor tab closed it just fine). Not sure if
  intentional (protect against accidental terminal kill) or a bug. If
  intentional, a toast "middle-click disabled on Pty tabs — right-click
  → Close pane" would explain the behaviour. If unintentional,
  document the finding.
- **Fold-arrow click works but no rect is registered in
  `rects.json`.** The click-rect audit tooling can't verify fold-arrow
  presence via the standard "list rects → click each" pipeline. Adding
  a named rect (`fold_arrow:<line>`) would make it CI-testable.
- **Bufferline drag-to-reorder** produced unexpected results — dragging
  `lib.rs` at col 36 → col 90 didn't move `lib.rs` but swapped
  `main.rs` and `src/long.rs`. Not deterministic enough to log as a
  SEV finding this round but worth a follow-up drag-drop trace.
- **`Split right` from the tab right-click menu** appears to create a
  duplicate tab of the same file rather than splitting the pane visually
  — `pane_body` count stays at 1 after the action (verified via the
  rects.json snapshot). Same for the `split_strip:*:Horizontal` chip.
  This might be by-design (mnml's split model may be tab-based rather
  than view-based) but doesn't match a VS Code mouse user's mental
  model.
- **Ctrl-click on `compute` identifier** didn't jump to definition in
  the ~4s I waited after LSP loaded (`LSP 1` shown in statusline).
  Might be rust-analyzer indexing time in the ephemeral scratch
  workspace; noting for a followup but not scored this round.
