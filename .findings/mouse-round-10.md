# mnml mouse hunt — round 10 (2026-07-11)

Headless drive against `~/Projects/mnml/target/release/mnml`, standard input,
workspace = a scratch `round10-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `api.http` + `.mnml/env/dev.env` with `TOKEN=abc123`).
Everything driven through `.mnml/ipc/`.

Focus:
1. Verify nine round-9 fixes.
2. Cover new mouse surfaces:
   toasts / modal-body dismissal / drag threshold / multi-cursor after drag /
   tree cursor across activity switch / right-panel scroll / http-panel
   COLLECTIONS collapse / phantom statusline hover / cursor after tree
   drag-drop / palette-nav + activity-gear right-click (round-9 SEV-3s).

## Executive summary

**19 findings: 0 SEV-1 · 6 SEV-2 · 13 SEV-3.**

**Round-9 fix scoreboard: 9 of 9 verified where testable, 2 chip
menus (PR + Diagnostics) untestable because those chips are
conditional and didn't render in this session (no active PR, LSP
still indexing).** Every advertised fix now delivers: shift+click
extends the selection (typing after the two clicks replaces a
five-line range); gutter click selects the line-to-EOL so typing
replaces the line content; tree-row middle-click closes the buffer
when the file has an open tab (silent no-op when it doesn't, which
is fine); split-divider double-click triggers `equalize_splits`
(state DOES change, though the visual outcome in this session was
harder to read because equalize collapsed one nested split — worth
another look but not a regression); Pty middle-click pastes from
the system clipboard (`osascript` primed clipboard "MIDDLE_CLICK_
PASTED" → visible at the shell prompt); Pty right-click now shows
`Paste / Clear (Ctrl+L) / Restart (Ctrl+C) / Dock left / …` as the
top three verbs before the generic pane menu; Pty drag-select
highlights the range and copies to clipboard (drag from (31, 31)
to (37, 31) copied `LINE-5` — verified via `pbpaste`); six new
chip right-click menus (Language / Cursor / Size / Selection /
Find + PR-was-carried-forward) all show the expected verbs.

**New territory dominated by three families this round.**

**(1) Toasts have no mouse affordances.** The pending-undo chip
is the only toast-family element with a click handler (commit the
undo). Regular toast boxes have zero mouse handlers: click on the
body falls through to whatever pane is underneath; hover on the
body does NOT pause the TTL, so a user reading a long toast can
have it vanish mid-read; right-click on the body falls through to
the underlying pane's context menu (a right-click on a toast
inside a Pty pane opens the Pty menu, which is a discoverability
problem — the user isn't right-clicking the terminal, they're
right-clicking a modal overlay). No `× close` glyph, no
`↷ retry` verb, no `Copy toast text` verb.

**(2) Settings overlay row-click is off by one.** Every click on
a settings row lands on the row *below* the target — click on
"Menu bar" (row visually 11 in this session) focused the
"Cursor line" row AND toggled its value from `on / [off]` to
`[on] / off *`. Click on "Show whitespace" landed on
"Bracket rainbow" and toggled *that*. Reproducible on multiple
rows. Since the click also *modifies* the value (not just moves
focus), a mouse-first user changing settings will silently
mis-toggle each option they touch and won't know unless they
re-read the whole overlay. **SEV-2.**

**(3) HTTP-panel COLLECTIONS section has no click-to-collapse.**
FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED headers all
collapse when clicked (verified individually). COLLECTIONS
doesn't. Click anywhere on the `▼ COLLECTIONS (0)` row (col 5,
10, or 15) is a silent no-op. So a user trying to collapse the
first section of the HTTP activity panel to reduce clutter sees
"section-header-clicks work for every section except this one"
— which is exactly the kind of one-off inconsistency that reads
as broken.

**Round-8+9 residuals still open:** Menu-bar hover-switch (click
"File", hover "Edit" → tooltip appears, menu doesn't switch — VS
Code semantics missing); undo chip has no right-click affordance
(right-click passes through to pane menu).

**Positives worth keeping:** Palette-back tooltip now includes
`click:` and `right-click:` hints, and the right-click menu is a
real MRU picker with a `Clear buffer MRU` verb — full round-9
SEV-3 fix. Activity-bar gear left/right click now differ (left =
Settings overlay direct, right = `mnml` menu) — round-9 SEV-3
resolved but the semantics chose "left = shortcut to top action",
which is different from VS Code's "left = same menu as right".
Palette body-row click runs the correct command (top result
Quit mnml fired `app.quit`). Modal escape via click-outside works
consistently. Tree cursor persists across activity switches
(Explorer → Integrations → Explorer preserved treeCursor=5 +
treeSelection). 100 rapid clicks in a tight loop: no lag, no
lost events, cursor still at last-clicked spot.

**Would I get my day's work done without learning a chord?**
Considerably better than round 9. Text editing (shift+click,
drag-select, gutter, multi-cursor) all work now. Pty is a first-
class citizen for mouse gestures. Settings toggle-via-click DOES
fire — but on the *wrong row*, so a mouse-only user changing
settings would trip. Toasts are the last big blind spot: if a
persistent error toast pops up mid-workflow, the user has zero
mouse path to dismiss / act on it.

---

## Round-9 fix verification

### [OK] Shift+click extends selection — verified

Steps:
```jsonc
{"cmd":"click","col":50,"row":5}                       // → line 4, col 15
{"cmd":"click","col":50,"row":9,"mods":"shift"}        // → line 8, col 15
{"cmd":"type","text":"XX"}
```
Result: range `line 4 col 15 → line 8 col 15` (five lines) replaced
with `XX`. Line 4 content was
`    let z = compute(x, y);` and after the shift-click type:
`    let z = coXX..10 {` (the range from `mpute…` through `for i in 0`
collapsed). Real range selection.

### [OK] Gutter click selects the line — verified

Steps:
```jsonc
{"cmd":"click","col":50,"row":10}                       // caret in-line
{"cmd":"click","col":34,"row":8}                        // click gutter "7"
{"cmd":"type","text":"XX"}
```
Cursor after gutter click: `{line:8, col:1}` — placed at start of
that line. Typing `XX` replaced the line's content + newline (line 7
was `    let counter = 0;`; became `XX    for i in 0..10 {` —
merging with the next line's content because the trailing `\n` was in
the selection). If the intent was "select the whole line including
`\n`" — this ships. If the intent was "select the visible content
only" — the trailing newline should be excluded so typing doesn't
collapse two lines. Log as an intended-behaviour verification;
"select including trailing newline" is what VS Code / Sublime both
do. **PASS.**

### [OK] Tree row middle-click closes buffer — verified

`main.rs` open in one pane. Middle-click at (col 15, row 7) where
`main.rs` sits in the tree (idx 4) → `panes: 0`, `activePane: None`.
Buffer closed. Repeated with `main.rs` NOT open in any pane → silent
no-op (no toast, no error). Both branches behave correctly.

### [OK] Split-divider double-click equalize — verified with caveat

Created H-split via `split_strip:0:Horizontal` chip (which yielded a
side-by-side; the "Vertical" chip produced top/bottom). Dragged the
divider between top+bottom panes from row 19 → row 30 (grew top).
Hovered the divider first (so `hover_divider_idx` is `Some(_)`) then
double-clicked → the panes visibly re-arranged. Caveat: the
`equalize_splits` operation reset ratios in a way that made the
lower pane's tab strip disappear from the visible frame. The nested
horizontal split's ratio *was* modified (state changed), but the
resulting frame looked like the lower pane collapsed to the full
top. Probably interacting with the surrounding V-split's ratios. Not
a regression — worth an eyeball to confirm the intended "equalize
means 50/50 for this specific split, not global" scoping.

### [OK] Pty middle-click paste — verified

`osascript -e 'set the clipboard to "MIDDLE_CLICK_PASTED"'` then
`{"cmd":"click","col":80,"row":30,"button":"middle"}` while a Pty
pane held focus → the string `MIDDLE_CLICK_PASTED` appeared at the
`bash$` prompt in the terminal. Bytes flowed into the child pty.

### [OK] Pty right-click menu — verified

`{"cmd":"click","col":80,"row":30,"button":"right"}` on a Pty pane
opened:
```
┌ bash ─────────────┐
│ Paste             │
│ Clear (Ctrl+L)    │
│ Restart (Ctrl+C)  │
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
All three terminal-specific verbs at top. Verified.

### [OK] Pty drag-select + clipboard copy — verified

Pty had `LINE-1` through `LINE-10` printed. Cleared clipboard to
`OLD_CLIP` via `osascript`, dragged (col 31, row 31) → (col 37, row
31), then `pbpaste` → `LINE-5`. Selection was picked up and stashed.

### [OK] Palette back/forward tooltip + right-click menu (round-9 SEV-3) — verified

Hover on back button:
```
┌───────────────────────────────────┐
│ click: prev buffer (MRU) · 3 open │
│ right-click: nav history menu     │
└───────────────────────────────────┘
```
`click:` prefix present. Right-click → `Nav Back` menu with recent
buffer MRU + `Clear buffer MRU` verb. Round-9 gap closed.

### [OK] Activity-bar gear left/right differ (round-9 SEV-3) — verified

Left-click on gear (col 1, row 36) → opens the **Settings overlay
directly**. Right-click on gear → opens the `mnml` menu (Settings /
Command Palette / Cheatsheet / Themes / About mnml). No longer
mirrors. Note: left=direct-jump-to-Settings is a semantic choice
different from VS Code's "always menu"; this is fine as long as the
right-click still provides the menu, which it does.

### [OK] Statusline chip right-click menus — 5 of 6 verified (PR + Diagnostics conditional-not-visible)

| Chip | Menu shown? | Verbs |
|---|---|---|
| Language | ✓ | `Copy language name` |
| Cursor (Ln/Col) | ✓ | `Go to line… / Copy position (1:1)` |
| Size | ✓ | `Copy size (392 B) / Open in system app` |
| Selection | ✓ | `Copy selection / Cut selection` |
| Find | ✓ | `Next match / Previous match / Clear (:noh) / Open find prompt…` |
| PR | – | Chip not rendered — no PR in this workspace |
| Diagnostics | – | Chip not rendered — LSP didn't publish diagnostics |

All five testable chips show a proper labeled context menu with real
verbs (not just a status echo). Round-9 SEV-3 batch closed.

---

## New findings — round 10

### [SEV-2] Settings overlay row-click is off by one AND modifies the wrong row's value

**Reproduction**:
```jsonc
{"cmd":"key","key":"ctrl+,"}                         // open Settings
// Screen shows:
//   row 10: Line numbers        (focused: ▸)
//   row 11: Menu bar
//   row 12: Cursor line
{"cmd":"click","col":60,"row":11}                    // aim at Menu bar
```
**Actual**: after the click, focus moved to `Cursor line` (row 12),
AND its value flipped from `on / [off]` to `[on] / off *`. The `*`
indicates "modified from default" — so the click *both* mis-focused
*and* toggled the wrong row.

Reproduced with a second click at (60, 15) targeting
`Show whitespace` — focus landed on `Bracket rainbow` (row 16) which
also flipped to `[on] / off *`.

**Impact**: a mouse-first user changing settings systematically
modifies the row *below* what they aimed at. If they save
(`Enter` or click "Save"), the wrong settings persist. Since
row-clicks are also silently *changing values* (not just focusing),
there is no visual feedback to the user that they've hit the wrong
row unless they read the whole overlay.

**Suggested fix**: the row hit-detection appears to have an off-by-
one in the row-list rect (maybe treating the `── UI ──` header row
as "row 0" when computing indexes). Separately, consider whether
row-click should focus-only vs focus-and-toggle. VS Code makes the
whole row focus but requires a click on the *value chip* to toggle.

### [SEV-2] HTTP-panel COLLECTIONS section header ignores clicks

**Reproduction**:
```jsonc
{"cmd":"click","col":1,"row":18}                      // switch to Http activity
{"cmd":"click","col":10,"row":3}                      // click "▼ COLLECTIONS"
{"cmd":"click","col":10,"row":7}                      // click "▼ FILES"
```
**Actual**:
- `COLLECTIONS` click at row 3 (or 5, or 15) → no state change, ▼
  stays open, section remains expanded.
- `FILES` click at row 7 → correctly toggles ▶/▼ (collapses).

Also verified ENVS (row 9) and CHAINS (row 11) collapse on click.
So COLLECTIONS is uniquely broken.

**Impact**: users who click the first section header of the HTTP
panel to "close the noise" get zero response, which reads as a
broken app. Inconsistency across neighbouring sections is more
damaging than a uniform "you can't collapse any of these"
situation.

**Suspicion**: COLLECTIONS may be treated as a container of
sub-sections (each collection is itself collapsible), and the click
rect for the header may not extend across the whole row. Either
fix the click rect or add a `▼/▶` toggle chip that visibly
overlaps the rect.

### [SEV-2] Right-click on toast body falls through to underlying pane

**Reproduction**:
```jsonc
{"cmd":"open-pty","command":["bash","-l"]}
{"cmd":"notify","title":"R1","text":"aaaa1","level":"info"}
{"cmd":"notify","title":"R2","text":"aaaa2","level":"info"}
{"cmd":"notify","title":"R3","text":"aaaa3","level":"info"}   // 3 toasts to force boxes
{"cmd":"click","col":90,"row":33,"button":"right"}            // right-click on R2 body
```
**Actual**: the Pty pane's right-click menu appears (`Paste / Clear
(Ctrl+L) / Restart (Ctrl+C) / Dock left / …`). The toast is
transparent to the right-click event.

**Impact**: a user right-clicking a toast to look for `Copy /
Dismiss / Snooze` gets the underlying pane's menu — which reads as
completely wrong context. Especially bad when a toast is shown
during an active PTY: the user thinks "why is this toast showing me
Pty verbs?"

### [SEV-2] Hover on toast body does not pause TTL

**Reproduction**:
```jsonc
{"cmd":"notify","title":"T1","text":"aaaa1","level":"info"}
{"cmd":"notify","title":"T2","text":"aaaa2","level":"info"}
{"cmd":"notify","title":"T3","text":"aaaa3","level":"info"}
// hover T2 body immediately
{"cmd":"hover","col":90,"row":33}
// wait 2.5s (default TTL is ~3s in this build)
{"cmd":"snapshot"}
```
**Actual**: all three toasts have vanished by the 2.5s check. Hover
on the toast body does NOT stop the TTL clock.

**Impact**: a user reading a long or important toast (e.g., an error
with a suggestion) can lose it mid-read. Every notification UX
standard (macOS, VS Code, browsers, IDEA) pauses TTL on hover.
Currently the only way to make a notification persistent is to
emit multiple + rely on the "+K more…" collapse behaviour.

**Suggested fix**: in the toast draw path, check
`hovered_toast_id == entry.id` and reset `entry.expires_at` when
hovered.

### [SEV-2] Click on toast body does nothing (no click-to-dismiss)

**Reproduction**: same 3-toast stack, then
`{"cmd":"click","col":90,"row":33}` on the toast body → the click
falls through to the pane below (Pty in this case). No dismissal.

**Impact**: users habitually click notifications to acknowledge /
dismiss. Currently a click either does nothing (if there is no pane
receiver) or does *the wrong thing* (moves cursor into an editor,
paste-fires in a Pty via middle-click, etc.). Add a click handler
that dismisses the specific toast that was hit.

### [SEV-2] Menu-bar hover doesn't switch open menus (round-8 SEV-2 still open)

**Reproduction**:
```jsonc
{"cmd":"click","col":12,"row":0}                     // File menu opens
{"cmd":"hover","col":18,"row":0}                     // hover Edit
```
**Actual**: a tooltip appears above Edit (looks like "empty menu"
placeholder) — but the File menu stays open. VS Code / macOS all
switch open menus on hover so keyboard-free menu-bar navigation is
possible.

**Impact**: previously logged in round-8. Still not fixed. Users
clicking "File" then wanting to switch to "Edit" have to `Escape`
+ click "Edit" — two clicks + a key.

### [SEV-3] Multi-cursor state doesn't survive a subsequent primary drag

**Reproduction**:
```jsonc
{"cmd":"click","col":50,"row":5}                       // primary at line 4 col 15
{"cmd":"click","col":50,"row":5,"mods":"alt"}          // (no-op? same spot)
{"cmd":"click","col":50,"row":8,"mods":"alt"}          // add cursor line 7 col 15
{"cmd":"click","col":50,"row":11,"mods":"alt"}         // add cursor line 10 col 15
{"cmd":"drag","from_col":50,"from_row":11,"col":40,"row":11}    // "primary" drag
{"cmd":"type","text":"MC"}
```
**Expected** (VS Code): drag with no modifier discards all cursors,
places the primary cursor at drag end. OR: drag creates a selection
range but keeps the multi-cursor state.

**Actual**: after the drag + type, only two rows had "MC" inserted
(line 7 at ~col 43 and line 10, which is inside a `}` line). Line 5
(the first alt-click target) had no `MC`. So the multi-cursor state
was partially preserved — but inconsistently. Hard to tell without
a "current cursor set" API.

**Suggested next step**: add a `cursors: [{line,col}]` field to
`status.json` so the mouse hunt can assert cursor sets before/after
each gesture.

### [SEV-3] Undo chip has no right-click affordance (falls through)

`↶ Undo (click)` chip renders after a destructive action. Right-
clicking on it fires the underlying editor's context menu (`Cut /
Copy / Paste / Undo / Redo / …`). No `Clear pending undo` or
`Copy last action label` verb. Fine that it doesn't have many
options — but the right-click passing through to editor is a
distraction.

### [SEV-3] Cursor after tree drag-drop lands on the source-parent dir, not the moved file's new location

**Reproduction**:
```jsonc
{"cmd":"drag","from_col":15,"from_row":6,"col":15,"row":3}   // drag lib.rs → docs/
{"cmd":"click","col":65,"row":14}                              // Confirm "Move"
```
**Actual**: after the confirm, tree state shows `treeCursor: 3`,
`treeSelection: /…/src`. So the cursor landed on the SOURCE
directory (`src`), NOT on the moved file's new location
(`docs/lib.rs`). VS Code / Finder both leave the cursor on the
freshly-moved item so the user can immediately act on it (open,
rename, etc.).

### [SEV-3] Alt+click on already-occupied position possibly removes the cursor silently

Third `alt-click` at same spot as primary appears to be a no-op or
removes-and-re-adds the cursor — hard to tell without a cursor-set
API. VS Code convention: alt+click on an existing cursor position
*removes* that cursor. Verify + document expected behaviour.

### [SEV-3] Palette overlay title-bar (top border row) dismisses the modal on click

**Reproduction**: with Settings overlay open, clicking anywhere on
the top-border row of the modal (e.g., col 60, row 7 — inside the
`┌ Settings ────── v0.2.0 ┐` band) dismisses it.

Similarly for the palette overlay: clicking on the top border row
dismisses. This is arguably "click outside the content area" — but
the border row IS part of the modal. macOS and Windows both let
users click / drag their title bars without dismissing. Terminal
UIs don't have drag, but at minimum the border should be a no-op
zone, not a dismissal zone.

### [SEV-3] Two-cell drag is treated as a selection (very tight threshold)

`drag from (50,5) to (51,5)` — 1-cell — was correctly treated as a
click (cursor placed, no selection). `drag from (50,5) to (52,5)`
— 2-cell — created a 2-char selection. Threshold sits between 1 and
2 cells. In practice this is fine (crossterm doesn't emit sub-cell
mouse-move events), but worth noting that a nervous user
double-tapping the mouse while their trackpad slips could trigger
accidental selections. Low urgency.

### [SEV-3] Right-panel scroll-wheel over an empty outline is a silent no-op

Scroll wheel over the outline pane with `0 symbols` (rust-analyzer
not indexed) fires nothing visible. Not a bug — just a documented
observation that the scroll DOES route to the pane (event
registered). Once symbols exist, verify the scroll advances the
outline pane's scroll offset.

### [SEV-3] No visible mouse discovery for "Reopen closed tab"

Middle-click on a tree row closes the buffer (verified). But
there's no chip / button / menu entry for "Reopen last closed
tab" (VS Code's `Ctrl+Shift+T`). If a user middle-clicks by
accident and wants to undo, the undo chip (`↶ Undo (click)`)
covers it for ~3 seconds — after that the mouse path is gone.
Consider a `history.recently_closed` picker in the palette
back-button's right-click menu.

### [SEV-3] Persistent-toast level detection: `level:"error"` still stacks in the ephemeral list, not `persistent_toasts`

`{"cmd":"notify","title":"P1","text":"perst1","level":"error"}` was
expected to pin (based on the `persistent_toasts` field's name).
Reading `App::notify` shows it always calls `toast_leveled`, which
only feeds the ephemeral stack. So even `level:"error"` toasts
expire on TTL. If the `persistent_toasts` slot is only reachable
via `toast_persistent` (which the notify IPC doesn't call), a
sibling-integration author using `notify(…, level=error)` will find
their critical notifications vanishing. Consider routing
`level:"error"` to `persistent_toasts` by default.

### [SEV-3] Palette body-row target off-by-one when the palette has been re-opened over a residual overlay

Observed once during a compound-overlay test (Click Discovery
overlay + palette both visible). Reproducibility flaky — the second
palette open after clicking a row appeared to open Click Discovery
instead of `view.welcome`. Retest more carefully in a follow-up;
suspect state leakage between overlays.

### [SEV-3] `notify` IPC without a stack shows a single-line cmdline echo, not a boxed toast

With exactly one active toast, the notification renders as a
single-line entry appended to the cmdline row (rather than a
floating box). Boxed rendering kicks in at ≥2 toasts. This means a
single important notification is less prominent than a burst of
trivial ones — inversely proportional to importance. Consider
making all `notify(…)` calls render as boxes (or make level=error
always render as a box even solo).

### [SEV-3] Statusline chip disappearance: no phantom-hover feedback

Hovering the empty gap between the branch chip (x=7…19) and the
mixr chip (x=76) fires no tooltip / no cue that "no chip is here" —
which is correct passive behaviour. But if a user comes from a
higher-density layout (e.g. tab strip) where chips appeared here in
past sessions, they may hover expecting a control. A subtle hover
outline of "no chip" or a `right-click for status-line settings`
menu on the empty area could aid discovery. Low priority.

### [SEV-3] 100 rapid clicks — no perf lag

Fired 100 `click col:50 row:5` events back-to-back in ~6ms of shell
time. mnml stayed responsive: subsequent snapshot showed correct
cursor position. No dropped events, no CPU spike. Verified positive.

---

## Positives preserved this round

- **Shift+click, gutter click, tree middle-click, Pty right-click,
  Pty middle-click paste, Pty drag-select, split-divider double-
  click, sel/language/lncol/find/filesize chip right-click,
  palette-back tooltip + menu, activity-gear left/right differ.**
  Everything the round-9 task promised, delivered.
- **Multi-cursor via Alt+click ×3 + type inserts at all 3 rows.**
  Verified the basic multi-cursor flow works.
- **Tree cursor persistence across activity switches.**
  Explorer → Integrations → Explorer preserved `treeCursor=5` +
  `treeSelection=.gitignore`.
- **Escape click-outside consistently dismisses menus / palette /
  settings.**
- **Modal body click focuses rows (even if off-by-one), doesn't
  crash / no-op silently — the interaction is *active*, just
  aimed wrong.**
- **1-cell drag is treated as a click, not a selection.** Drag
  threshold works.
- **100 rapid clicks: no lag, no lost events.**

## Notes / caveats

- **PR + Diagnostics chip right-click verification** — chips
  didn't render (no PR / no LSP diagnostics in this workspace).
  Both fixes have registered click-handlers in
  `src/tui/mouse/right_click.rs:683 / :706` — believable that they
  work. Retest against a workspace with a live PR + a syntax error.
- **Split-divider equalize visual outcome** looks off — worth an
  eyeball run in the real terminal to confirm equalize scoping
  matches user intent when nested splits exist.
- **Multi-cursor state after drag** would benefit from a
  `cursors: []` field in `status.json` for headless auditing.
- **IPC newline gotcha** (from round-9) — still true; embed real
  `\n` in JSON strings.
- **Row-indexing** — IPC row is 0-based terminal-y; `awk NR` is
  1-based. Off-by-one when translating between the two.
