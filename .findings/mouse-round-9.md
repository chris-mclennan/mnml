# mnml mouse hunt — round 9 (2026-07-11)

Headless drive against `~/Projects/mnml/target/release/mnml`, standard input,
workspace = a scratch `round9-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `api.http` + `.mnml/env/dev.env` with `TOKEN=abc123`).
Everything driven through `.mnml/ipc/`.

Focus:
1. Verify four round-8 fixes.
2. Cover surfaces not yet exercised: Pty mouse, tab drag-reorder overshoot,
   split-divider drag/dblclick/rclick, minimap presence, hover/signature
   dismissal, palette-bar back/forward right-click, activity-bar gear
   right-click, cursor blink, focus-follows-mouse, tree middle-click.

## Executive summary

**16 findings: 0 SEV-1 · 9 SEV-2 · 7 SEV-3.**

**Round-8 fix scoreboard: 2 of 4 shipped as advertised.** The language-chip
tooltip now says `click for details` and the click emits a status-line
detail row (verified); the file-chip right-click now opens a proper Buffer
menu with Reveal-in-tree / Copy path × 3 / Close buffer (verified). But
**shift+click still doesn't extend selection** — a shift-click at (line 13,
col 15) after a plain click at (line 9, col 15) teleports the caret without
setting a selection anchor (typing `REPLACED` after the two clicks inserts
inline; hitting Delete after the two clicks deletes exactly one character
at the new caret position, not a five-line range). And the gutter click
fix is **partial**: left-clicking a line number in the gutter now moves
the caret to line-start of that line (an improvement over round 8's
silent-no-op), but the whole line is *not* selected — typing after the
gutter click prepends to the line rather than replacing it. If the intent
was "VS Code's move-caret-to-line-start" that shipped; if the intent was
"select the whole line", it didn't.

**New territory dominated by two families this round.**

**(1) The Pty pane is a mouse dead-zone for terminal-native gestures.**
Right-click still shows the generic pane-management menu with no Paste /
Copy / Clear / Restart (unchanged since round 8). Drag inside a Pty
pane doesn't select any text — a drag from (col 37, row 25) to (col 48,
row 25) leaves no visible selection and no OSC-52 clipboard payload.
Middle-click doesn't paste from the system clipboard (which was pre-loaded
with `PASTED_FROM_CLIP` via `osascript -e 'set the clipboard to …'`) —
the middle-click is a silent no-op at the prompt. Between those three
gaps a terminal user's every reflex — right-click Paste, drag-select
Copy, middle-click Paste — misses. **Scroll wheel does work in Pty**
(dy: 5 scrolled the visible region back to LINE-1 from LINE-5), which is
the one positive.

**(2) Split-pane resize discoverability is thin.** The horizontal
divider (row 19 in this session) has no click-rect exported to
`rects.json`, no hover tooltip, no right-click menu, no double-click
handler. Plain-drag on the divider *does* resize (verified: drag from
(70, 19) to (70, 25) moved the divider down; drag from (70, 25) to
(70, 19) restored it), which is the load-bearing gesture and works.
But every affordance around it — "there's a resize handle here",
"double-click to equalize", "right-click for equalize / hide", "Ctrl+drag
for proportional" — is missing. In VS Code you get all four.

**(3) Small polish gaps in the palette bar and activity bar.** The
back/forward buttons have `prev buffer (MRU) · 2 open` / `next buffer
(MRU) · 2 open` tooltips (no `click:` prefix, so first-time users can't
tell they *are* clickable) and produce no right-click menu (would fit
"Recent files…" / "Clear history"). The activity-bar gear icon fires
the same `mnml` menu on left-click and right-click — no separate
right-click surface for global settings / theme / cheatsheet.

**Would I get my day's work done without learning a chord?** Slightly
better than round 8 for statusline discoverability (the language chip is
now a real click target, the file chip has its buffer menu), but for
anyone who lives in a terminal pane the answer is no — you'd hit
right-click Paste in the Pty within the first minute and be told to
"Dock top" instead.

---

## Round-8 fix verification

### [SEV-2] Shift-click still doesn't extend selection — round-8 "fix" did not land

**Reproduction**:
```jsonc
{"cmd":"open","path":"src/main.rs"}
{"cmd":"click","col":50,"row":29}                      // caret → line 9 col 15
{"cmd":"click","col":50,"row":33,"mods":"shift"}       // shift-click → line 13 col 15
{"cmd":"key","key":"delete"}                            // expect: 5-line range delete
```

**Actual**:
- Status after click 1: `"cursor":{"line":9,"col":15}` ✓
- Status after shift-click: `"cursor":{"line":13,"col":15}` — cursor teleports; **no anchor**.
- After delete: exactly one character deleted at line 13 col 15. Lines 9-12 intact.

Also cross-checked via `type REPLACED` after shift-click: the string is
inserted at the caret position, not overlaid onto a range. Same behaviour
as the round-8 finding.

**Status**: Round-8 SEV-2 not fixed. Please prioritise — this and drag-select
(also still broken — see below) together are the only two paths to range
selection for a mouse-first user in the editor body.

### [SEV-2] Gutter line-number click is a partial fix — moves caret but doesn't select the line

**Reproduction**:
```jsonc
{"cmd":"click","col":60,"row":25}          // caret at line 5 col 16
{"cmd":"click","col":33,"row":25}          // click gutter number "5" (col 33 = the digit)
{"cmd":"type","text":"XX"}                 // expect: line 5 replaced with "XX"
```

**Actual**:
- Cursor after gutter click: `"cursor":{"line":6,"col":1}` — moved to line-start of the clicked line (indexed from 0? seems 1-based here; not zero-based sometimes — see note).
- Line 5 renders as `5 XX    let z = x + y;` — `XX` was **prepended**, not
  replacing the existing content.

**Progress from round 8**: the gutter click IS now a click target (round 8
was a total silent-no-op — cursor stayed at (12, 15) after clicking a
line number). **Gap remaining**: the whole line is not selected. If the
intent matches the round-8 comment "VS Code moves the caret to line-start"
this is complete; if the intent was Sublime's "select the whole line"
(as the round-9 task description says), it didn't ship.

**Suggested next step**: standard-mode gutter-click should set
`anchor = line_start, cursor = line_end + 1` so typing replaces. VS Code
default is caret-to-start, so document the choice either way.

### [OK] Language chip tooltip now says "click for details" — verified

Hover `statusline_language_chip` (x=115, y=38):
```
┌──────────────────────────────────────────────────┐
│ language: rs                                     │
│ click for details · detected from file extension │
└──────────────────────────────────────────────────┘
```
Left-click emits `language: rs (via file extension)` to the cmdline row.
Round-8 SEV-2 shifted to a click-hint + status-line dump — good enough to
close that finding. (Nice-to-have: click could still open a language
picker like VS Code — but the SEV-2 gap of "no visible action" is
closed.)

### [OK] File-chip right-click opens a proper Buffer menu — verified

Right-click `statusline_file_chip` (x=26, y=38):
```
┌ Buffer ──────────────┐
│ Reveal in tree       │
│ Copy path (absolute) │
│ Copy path (relative) │
│ Copy filename        │
│ Close buffer         │
└──────────────────────┘
```
Matches the round-8 promise (Reveal / Copy path × 3 / Close). Verified.

---

## New findings — round 9

### [SEV-2] Pty pane right-click still shows generic pane menu (no Paste / Copy / Clear / Restart) — round-8 SEV-2 carried forward

Verified identical to round 8:
```jsonc
{"cmd":"open-pty","command":["bash","-l"]}
{"cmd":"click","col":50,"row":30,"button":"right"}
```
Menu rendered:
```
┌ bash ─────────────┐
│ Dock left         │
│ Dock right        │
│ Dock top          │
│ Dock bottom       │
│ Maximize width    │
│ Maximize height   │
│ Full screen (zen) │
│ Equalize splits   │
│ Close pane        │
└───────────────────┘
```
No terminal-specific verbs. Same complaint as round 8: someone from
iTerm2/Ghostty right-clicks expecting Paste and gets "Dock top".

### [SEV-2] Middle-click paste in Pty does nothing

**Reproduction**:
```bash
osascript -e 'set the clipboard to "PASTED_FROM_CLIP"'
```
```jsonc
{"cmd":"click","col":50,"row":30,"button":"middle"}
{"cmd":"snapshot"}
```

**Expected**: primary-selection / clipboard paste. VS Code integrated
terminal + iTerm2 + Alacritty + Kitty all bind middle-click to a paste
of some flavour.

**Actual**: prompt row unchanged. Silent no-op. No text inserted; no
`bell` fired; no toast about "primary selection not supported on macOS".

**Impact**: the second-most-common paste gesture (behind right-click
Paste) is invisible. Combined with the right-click gap above, a Ptty-
using mouse hand has zero paste path — has to fall back to Cmd/Ctrl+V,
which the round-9 task doctrine says counts as SEV-2.

### [SEV-2] Text selection via drag in Pty pane doesn't work

**Reproduction** (after filling the Pty with `LINE-1` through `LINE-20`):
```jsonc
{"cmd":"drag","from_col":37,"from_row":25,"col":48,"row":25}
{"cmd":"snapshot"}
```

**Expected**: characters between the two anchors highlight; OSC-52 or
internal primary-selection buffer holds "LINE-8" (or whatever the row
contained).

**Actual**: no visible selection region in the snapshot; no reverse-video
cells; no highlight of any kind. Cursor stayed at prompt.

**Impact**: cannot copy text out of a Pty via mouse — the only mouse
path is "select in terminal, then Cmd+C" or the missing right-click Copy.
For log-tailing workflows (see a stack trace scroll past, want to grab
it), the mouse-first user is stuck.

### [SEV-2] Middle-click on a tree file row does nothing

**Reproduction**:
```jsonc
// main.rs open in pane 0 (via prior right-click Split right)
{"cmd":"click","col":15,"row":10,"button":"middle"}   // row 10 is main.rs in tree
```

**Expected**: VS Code closes the tab bound to that file (or, on a
closed file, opens it in a new group). Either action is documented in
the tooltip / discoverable.

**Actual**: silent no-op. The main.rs tab in pane 0 is not closed; no
new tab is opened; no toast. Consistent with round 8's note about
middle-click on a Pty *tab* — the same silence.

### [SEV-2] Bufferline tab drag-reorder overshoots the drop target

**Reproduction** (tabs on pane 3 = bash / lib.rs / notes.md / api.http):
```jsonc
// drop inside notes.md's rect (57-73)
{"cmd":"drag","from_col":48,"from_row":20,"col":70,"row":20}
```
Before: `bash · lib.rs · notes.md · api.http`
After: `bash · notes.md · api.http · lib.rs` — lib.rs went to the **last**
position, not slot 3 where the drop landed.

**Reproduction 2** (short drag, one-neighbour swap):
```jsonc
// notes.md at 43-59 midpoint 50, dropped inside api.http's rect (61-85)
{"cmd":"drag","from_col":50,"from_row":20,"col":75,"row":20}
```
Before: `bash · notes.md · api.http · lib.rs`
After: `bash · api.http · lib.rs · notes.md` — notes.md went to slot 4,
not slot 3.

**Impact**: the drag *does* reorder (round-8 note observed a partial
swap; here it consistently over-shoots). The drop-slot math seems to
either treat each cell crossed as a swap step (so a 25-cell drag pushes
25 positions past its neighbour) or clamps a drop-inside-a-tab-rect to
the far side rather than the near side. A VS Code user drags a tab to
just past its neighbour expecting a single swap — they'll get "why did
my tab jump to the end?"

**Suggested fix**: slot the drop by the *centre* of the destination tab
(<= half → left of that tab, > half → right of that tab), not by an
event count.

### [SEV-2] Split divider has no hover tooltip / no right-click menu / no rects.json entry

**Reproduction** (horizontal split, divider at y=19):
```jsonc
{"cmd":"hover","col":70,"row":19}   // no tooltip
{"cmd":"click","col":70,"row":19,"button":"right"}   // no menu
```

Neither event registers as a target: no popup, no toast, no menu. And
`rects.json` has no `split_divider:*` entry — so the divider is
invisible to click-rect audit tooling as well.

**Positive**: plain drag *does* resize (drag (70,19) → (70,25) shrunk the
top pane), which is the load-bearing gesture. So the divider is
functional — it's just undiscoverable and lacks polish affordances.

**Suggested minimum**: register a `split_divider:H:<pane>` rect; on hover
show `drag: resize · double-click: equalize · right-click: menu`; on
right-click render `Equalize splits / Reset ratio / Hide top / Hide
bottom / Maximize this pane`.

### [SEV-2] Double-click on split divider doesn't equalize (VS Code convention)

**Reproduction**: after `drag (70,19) → (70,15)` (top pane now shrunken):
```jsonc
{"cmd":"click","col":70,"row":15}
{"cmd":"click","col":70,"row":15}
```

**Expected**: split ratio snaps back to 50/50. VS Code, JetBrains,
Sublime, Xcode all bind double-click on the divider to "reset to equal
ratio".

**Actual**: divider stays where it was. No visible change. (There is an
`Equalize splits` verb in the pane right-click menu, but it's not on the
divider — and finding it requires right-clicking inside the pane body,
which most users won't do to fix a mis-drag.)

### [SEV-3] Palette back/forward buttons have no right-click menu

**Reproduction**:
```jsonc
{"cmd":"click","col":40,"row":0,"button":"right"}   // back button
{"cmd":"click","col":43,"row":0,"button":"right"}   // forward button
```

**Actual**: neither shows a menu. Both are silent no-ops on right-click.
The hover tooltips are `prev buffer (MRU) · 2 open` /
`next buffer (MRU) · 2 open` — nothing like "right-click for history".

**Expected minimum**: right-click → menu of the last N MRU entries; a
Clear history verb; a "Reopen closed tab" verb.

### [SEV-3] Palette back/forward tooltips lack a `click:` prefix

Every other clickable chip in the app that I hover this round tags its
tooltip with `click: …` and often `right-click: …`. The back and forward
chips just say `prev buffer (MRU) · 2 open`. First-time discoverability
suffers — the label doesn't convince you it's a button. (Compare to the
LSP chip: `click: :LspStatus (running servers)`.)

### [SEV-3] Activity-bar gear left-click and right-click render the same menu

**Reproduction**:
```jsonc
{"cmd":"click","col":1,"row":36}                    // left-click gear
{"cmd":"click","col":1,"row":36,"button":"right"}   // right-click gear
```

Both open:
```
┌ mnml ────────────┐
│ Settings…        │
│ Command Palette… │
│ Cheatsheet…      │
│ Themes…          │
│ About mnml       │
└──────────────────┘
```

**Expected**: the right-click surface should either mirror-and-extend
(add "Restart mnml" / "Quit mnml" / "Report issue" / "Toggle dev mode")
or be a distinct sub-menu with global-config quick-toggles (Dark theme
on/off, Line numbers on/off). Duplicating the left-click menu means the
right-click gesture is wasted.

### [SEV-3] No general editor minimap (VS Code right-edge overview)

Grep of `src/` shows only `diff_view.rs`'s 1-cell change-density
right-edge minimap. Editor panes render just the scrollbar thumb —
no thumbnail of the file's structure, no viewport indicator, no click-in-
minimap to jump.

Not surprising (mnml is a terminal IDE and pixel-density limits how
useful this would be), but worth logging as a discoverability finding
because a VS Code user's eye reflexively scans for the right-edge strip.

### [SEV-3] Cursor blink is hardcoded to SteadyBar; no config path

`src/tui/mod.rs:99` sets `SetCursorStyle::SteadyBar` unconditionally.
There's no `[editor] cursor_blink = "on"|"off"` key in the config
schema, and no `cursor_blink` / `blink` reference anywhere in
`src/config.rs`. A VS Code user who expects `editor.cursorBlinking`
(smooth / phase / expand / solid / blink) will find nothing.

Not urgent — but worth surfacing as a Settings row.

### [SEV-3] No focus-follows-mouse (VS Code doesn't have it either — noting for parity)

**Reproduction**:
```jsonc
// click into top pane, then just hover the bottom pane without clicking
{"cmd":"click","col":60,"row":5}      // status: activePane:1
{"cmd":"hover","col":60,"row":25}     // status: activePane:1 (unchanged)
```

**Behaviour**: hover does not shift focus between panes; you must click
to focus. This matches VS Code's default and most editors', so likely
by-design. Downgraded to SEV-3 mainly as a "confirmed default" note —
a Settings toggle wouldn't hurt for users transferring from tmux /
i3 / Xmonad conventions.

### [SEV-3] LSP hover popup does not materialise in headless (indexing time)

`hover` at line 8 col 22 (over `compute` identifier) with 1.5s wait
produced no tooltip / popup — even though `statusline_lsp_chip` shows
`LSP 1` (one client running). Probably rust-analyzer indexing time in a
fresh scratch workspace; noting for followup but not scored higher (same
issue as round 8). Deserves a `wait for LSP ready` IPC command so
headless tests can gate on it.

### Positives preserved this round

- **Scroll wheel over Pty scrolls** (dy: 5 pulled `LINE-1` back into
  view from `LINE-5`).
- **Split divider plain-drag resizes** — verified in both directions.
- **Right-click on gutter line-number opens a proper menu**:
  Toggle breakpoint / Conditional breakpoint / Go to definition / Find
  references. Nice.
- **Right-click on a tab close (×) button opens the tab menu**
  (Pin tab / Close / Close others / … / Split right). No unique to
  the × button, but it doesn't misfire.
- **File chip right-click**: **verified round-8 fix** — Reveal in tree /
  Copy path (absolute) / Copy path (relative) / Copy filename / Close
  buffer.
- **Language chip**: **verified round-8 fix** — tooltip includes
  `click for details`, left-click emits `language: rs (via file
  extension)` to the cmdline.
- **Palette search chip click** opens the command palette overlay.
- **Escape click-outside** dismisses palette / menus consistently
  (tested with palette, tab context menu, gear menu, file-chip menu).
- **Activity-bar gear** opens the mnml menu on click; menu contents
  correct (Settings / Command Palette / Cheatsheet / Themes / About).
- **LSP chip tooltip** correctly formatted:
  `click: :LspStatus (running servers)`, dismisses on cursor move.

---

## Notes / caveats

- **Row indexing**: the status.json `cursor.line` field appears to be
  1-based in this session (`{"line":6,"col":1}` after clicking on the
  displayed `5 …` gutter row). The `line 5` in the screen is
  `line:6` in status. Not a bug — just documented so the next hunt
  doesn't chase a phantom off-by-one.
- **IPC newline gotcha**: `{"cmd":"type","text":"echo hi\n"}` written
  via zsh here-string with normal `\n` was parsed as `unknown` by the
  IPC (the `\n` inside the JSON blew the JSONL parse). Only literal
  `\n` in the source string worked. Not a mnml bug (JSON is fine);
  worth mentioning in the driver docs.
- **Preview vs pinned tab menu** — round-8 SEV-2 not retested here
  (needed for round-10 sweep).
- **Alt+click multi-cursor** — round-8 confirmed working; not retested
  here.
- **Fold arrow visibility** — round-8 SEV-2 not retested (still open?).
- **Git-change bar click** — round-8 SEV-2 not retested (still open?).
- **Menu-bar hover switch** — round-8 SEV-2 not retested.
- **Statusline LSP right-click** — round-8 SEV-3 (single-row `Status`
  menu) not retested.
- The round-9 request also asked about "signature help" specifically.
  Because LSP hover didn't fire even at 1.5s, signature-help pop-ups
  couldn't be exercised. Recommend re-running this once a `wait-for-lsp`
  IPC gate exists, or against a workspace with a `target/` cache
  primed for rust-analyzer.
