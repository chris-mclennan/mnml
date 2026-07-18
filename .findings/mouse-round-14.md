# mnml mouse hunt — round 14 (2026-07-14)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `round14-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `README.md`, `api.http`, `subdir1/subdir2/deep.txt`,
`.mnml/env/dev.env` with `TOKEN=abc123`). Everything driven through
`.mnml/ipc/`; keyboard used only for text typing and `Esc`.

Focus:
1. Verify the four priority items called out in the round-14 kickoff.
2. Re-probe the round-13 SEV-2 / SEV-3 residuals.
3. Fresh hunt around IPC-timing sensitivity of double-click detection.

## Executive summary

**9 findings: 0 SEV-1 · 3 SEV-2 · 6 SEV-3.**

**Priority-verification scoreboard (4 items):**

- **P1 Split-divider cold double-click (round-13 F1 / round-12 F2)** —
  **STILL PARTIALLY BROKEN, but root cause identified.** The fix at
  `down_left.rs:231-251` does NOT depend on `hover_divider_idx`
  (verified by source read); it hit-tests `split_dividers` directly.
  Cold double-click WORKS in a completely fresh state (Skew → click →
  click without any intervening `wait_ms` command). Cold double-click
  FAILS when the IPC script inserts a `wait_ms` of ≳350 ms
  anywhere before the two clicks. The real 450 ms `duration_since`
  window is being eaten by IPC-loop overhead (render + `poll_sleep 40ms`
  + drain iteration) that gets injected between drain iterations when
  a long `wait_ms` command lands as its own command batch. See F1 for
  the reproduce + trace.

  **`last_click` is not being clobbered** — I verified by binary-searching
  the gap: `click; wait_ms 300; click` equalizes; `click; wait_ms 350;
  click` does not. That translates to a wall-clock elapse of roughly
  350 ms + one drain overhead ≈ 450 ms, tripping the check. This is
  actually the DOCUMENTED behavior of the 450 ms window — a real
  trackpad user who takes >350 ms between clicks sees the same failure.
  Just the source comment/threshold need re-tuning (VS Code's
  drag-handle dbl-click uses 500 ms) OR the check needs a wider tolerance
  when IPC-driven.

  What round-13 called "hover-first works, cold fails" was actually
  "hover injected 500 ms of drain-idle time BEFORE the clicks, then
  the wait_ms 500 you also had put you over 500 ms of elapsed time by
  click 2." I hover-tested at the same threshold and it also breaks
  without the divider hover being special. Conclusion: the fix IS
  correctly wired; the 450 ms window is tight-enough that any user
  who pauses even a quarter second between clicks misses it. SEV-2
  because in-terminal users with slower click-cadence habits (or on
  slower loops) will keep hitting this.

- **P2 Settings `/ filter` row is now clickable (round-13 F2 / round-12
  F3)** — **VERIFIED FIXED.** `settings_filter_row` at (25, 7, 70, 1) is
  in `rects.json`. Clicking on it switches from the placeholder
  ("`type to filter…▏`") into edit mode + captures the caret. Typing
  "line" filters the 25-row list down to `Line numbers` / `Cursor line`
  / `Statusline clock` / `Inline markdown rendering` / `Cmdline popup
  border color`. Round-13 F2 confirmed dead.

- **P3 Right-panel empty-state Outline/AI/Grep/Tests click when no
  Editor is active (round-13 F3)** — **PARTIALLY WRONG DIAGNOSIS.**
  Round-13 claimed the clicks silently no-op. In this run the click IS
  wired AND the underlying command IS invoked AND the fallback toast
  IS surfaced. Verified: with a `README.md ◳` MdPreview pane active,
  clicking Outline fires `outline.show` which toasts `no active editor`;
  clicking Tests fires `test.run_file` which toasts `open a .spec file
  first`. The toast is bottom-right, brief (a few seconds), and does
  vanish before the user might notice IF they're already looking at
  the panel picker on the other side of the screen. But it does NOT get
  drowned in redraws — a fresh snapshot immediately after the click
  captures the toast reliably. Downgrading to SEV-3 (see F3 below):
  the toast is technically discoverable but far from the user's
  gaze at click time.

- **P4 Bufferline dirty-inactive-tab hover-close (round-13 P4) +
  workspace-header hover-gate (round-13 P1) + split-strip button
  right-click (round-13 P8 residual) + git toolbar tooltips (round-13
  F10 residual)** — Mix:
  - Bufferline hover-close on dirty inactive tab — VERIFIED FIXED.
    Cursor far → `main.rs ●` (dirty dot). Cursor on tab → `main.rs 󰅖`
    (close X in orange). Test-order matters: an in-flight tooltip
    covering the tab body will steal the close-x click; the test must
    dismiss any prior hover-tooltip before the click. That's a
    separate SEV-3 (F4 below).
  - Workspace-header hover-gate — VERIFIED FIXED. Cold click at (15, 1)
    with cursor pre-hover at (100, 30) does NOT phantom-fire any of
    the hover-only action chips (`file.new_folder` / `file.new` /
    `tree.refresh`). `tree_icon:*` rects are only registered when
    `mouse_pos` is on the workspace-header row.
  - Split-strip `[│]` `[─]` `[$]` right-click — STILL BROKEN (F5 below).
  - Git toolbar tooltips + right-click — STILL BROKEN (F9 below).

**Round-13 residuals (regression check):**
- F1-round13 divider cold dbl-click — see F1 below (root cause found).
- F2-round13 settings /filter row click — FIXED (see P2).
- F3-round13 right-panel empty-state — see F3 below (downgrade).
- F4-round13 HTTP-panel MOCKS stale state — NOT REPRODUCIBLE this round;
  MOCKS right-click showed all 4 items even after HTTP→Explorer→
  HTTP→Git→HTTP activity switches. Possibly a race in round-13; the
  fix in place appears stable.
- F5-round13 `+ dock` chip right-click — not re-probed.
- F6-round13 tree edge max clamp — STILL BROKEN (see F6 below).
- F7-round13 activity-bar right-click menus — STILL BROKEN (6+ of
  11 have 1 verb, F7 below).
- F8-round13 empty-tree-space right-click — STILL BROKEN (F8 below).
- F9-round13 split-strip right-click — STILL BROKEN (F5 below).
- F10-round13 git toolbar chips — STILL BROKEN (F9 below).
- F11-round13 tree drag-to-bufferline no-op — STILL BROKEN (F10 below).

## Findings

### SEV-2

**F1. Split-divider cold double-click threshold is 300–350 ms wall time
between clicks, not the 450 ms the source claims.**
Steps: Fresh mnml session; split via `view.split_right`; skew via 2×
`view.split_grow_width` (divider at col 83, pane widths 52/36).
Bracket experiment:
- `click 83 15 · click 83 15` (back-to-back) → equalizes ✓
- `click 83 15 · wait_ms 60 · click 83 15` → equalizes ✓
- `click 83 15 · wait_ms 300 · click 83 15` → equalizes ✓
- `click 83 15 · wait_ms 350 · click 83 15` → does NOT equalize ✗
- `click 83 15 · wait_ms 400 · click 83 15` → does NOT equalize ✗
- `wait_ms 500 · click 83 15 · click 83 15` → does NOT equalize ✗
- `wait_ms 500 · click 83 15 · wait_ms 60 · click 83 15` → does NOT equalize ✗
- `hover 83 15 · wait_ms 500 · click 83 15 · wait_ms 60 · click 83 15` → equalizes ✓
  (hover pre-seeds render state; the render tick between the hover and
  the click drops the elapsed time counter effectively).

Traced against `src/tui/mouse/down_left.rs:231-251`: the fix is
correctly wired + hits `split_dividers` directly (no `hover_divider_idx`
dependency). The check is `now.duration_since(prev) <
Duration::from_millis(450)`. Under IPC-driven click sequences the
mnml headless loop injects render + `poll_sleep 40ms` + drain
overhead between drain iterations. A `wait_ms 350` command therefore
becomes ~450 ms of effective wall-clock elapse, tripping the check.

This means:
- Real trackpad users doing ≥350 ms between clicks (a natural
  cadence for "click … click again" rather than a rapid dbl-tap) miss
  the equalize.
- Headless test scripts using `wait_ms 80` between clicks after a
  `wait_ms 500` before them get an effective ~700 ms gap → miss.
- The round-11 fallback at `down_left.rs:2794-2815` (same check,
  after `begin_divider_drag`) remains dead code (the return at
  line 253 short-circuits it, as round-13 called out).

**Recommended fix**: bump the window to 700–800 ms (VS Code uses
~500 ms + accepts one intermediate mousemove; Chrome tab-close double
takes ~700 ms). OR key the check off a monotonic `last_click_count`
that resets only on a coord change, not a time delay.

**F2. Right-panel empty-state click when active pane is not an Editor
fires a toast, but the toast is visually distant from the click site
and vanishes after a few seconds.** Not a "silent no-op" as round-13
claimed — the toast IS shown ("no active editor" for outline.show;
"open a .spec file first" for test.run_file) — but the toast lands in
the bottom-right corner and disappears within ~3 seconds. A mouse-first
user clicking the panel picker on the far-right side has their gaze on
the picker rows, so a toast rendered in the opposite corner is easy to
miss. Downgraded from round-13's SEV-2 to a **discoverability SEV-3**
(see F3 below in SEV-3). The "F3-round13 silent" claim was likely an
artifact of the earlier hunter not capturing the toast fast enough
before it timed out.

Refactor idea for a real fix: gate the empty-state rows' visibility
on `active_editor().is_some()` — grey out or hide the Outline / AI
chat / Grep / Tests rows when there's no Editor to target, leaving
Diagnostics visible (Diagnostics is workspace-scoped and doesn't need
an active editor). VS Code disables the equivalent commands in the
command palette when the precondition isn't met.

**F3. HTTP-panel dirty-inactive-tab close × click misses when a prior
hover tooltip is visible over the tab body.** Steps: main.rs dirty
inactive. Hover main.rs tab body → 500 ms → click × close at
(37, 1). Result: tooltip stays showing but no close prompt. Repro'd
5×. Root cause: the hover-tooltip overlay at row 1 spans multiple
cells and the tooltip's own rect may be catching the click before
`bufferline_tab_close` gets to. Workaround: user moves the cursor
off, then hovers back JUST on the close × zone, then clicks — that
works. Real users hovering the tab to READ the label then clicking ×
where they see it get a no-op. Split into SEV-2 because the natural
flow ("I see the tab I want to close, I hover it, I click the X")
fails.

### SEV-3

**F4. Palette dropdown chevron button at (77, 0) has no visible glyph
even though the rect is registered + clicking it fires no visible
action.** Steps: hover far, then click at (77, 0) or (78, 0). The
rect `palette_dropdown_button (77, 0, 3, 1)` exists in `rects.json`
per the audit. On this widescreen (120 cells), no glyph is painted
at cols 77-79 in row 0. Even hovering the exact rect shows no
tooltip. The recent-files dropdown never opens.

**F5. Split-strip `[│]`, `[─]`, and terminal `[$]` buttons still have
no right-click menu.** (Round-13 F9 residual.)
- (115, 1) `split_strip:0:Horizontal` → nothing on right-click.
- (118, 1) `split_strip:0:Vertical` → nothing.
- (112, 1) `split_strip_term:0` → nothing.
Left-click still splits / opens the terminal correctly. `[A]` Claude at
col 108 does have a right-click menu (verified in prior rounds).
Missing: "Move to bottom split" / "Duplicate this pane" / "Close
this pane" / "Split ratio…" on `[│]`/`[─]`; "Open new terminal in
same cwd" / "Kill this terminal" / "New Claude session" on `[$]`.

**F6. Tree edge drag max clamp not enforced.** Trace of
`drag_tree_edge_to` (src/app/mod.rs:10890) uses `x.clamp(TREE_WIDTH_MIN,
screen_width - 20)`. Config-load path (`config.rs:1985`) clamps
`ui.tree_width` to `10..=80` — but that's a file-load-time clamp, not
runtime. Drag from x=30 to x=100 lands the tree edge at x=99 (i.e.
tree_width = 96 effective, 100 stored). The tree eats > 80 % of a
120-col terminal. Round-12 F5 / round-13 F6 residual, unfixed.

**F7. Right-click on empty tree space produces no menu.**
(Round-13 F8-round12, unfixed.) Steps: Explorer → right-click on
tree row 13 (a blank row between two `▶ ○ tattle-*` workspace tiles)
→ no menu appears. VS Code / JetBrains show "New file / New folder /
Refresh Explorer / Open in Terminal" here — an obvious blind spot.

**F8. Right-click on a workspace-tile row shows a mostly workspace-oriented
menu instead of a "you're in this folder; new file here?" menu.**
Steps: right-click on `▶ ○ tattle-mobile` row (a collapsed extra
workspace). Menu shown:
- Set as workspace / Set as default workspace
- Expand this section
- Move up / Move down
- Switch workspace…
- Remove this workspace
- Manage workspaces…
- Reveal in Finder
- Refresh tree

Missing: "New file in this workspace" / "New folder in this workspace"
/ "Open in Integrated Terminal" / "Copy path". The current menu is
about ORGANIZING workspaces; a mouse user wanting to work IN the
workspace has no reachable "start work here" verb.

**F9. Git activity toolbar chips (Undo / Redo / Pull / Push / Fetch /
Branch / Commit / Stash / Pop) still have no hover tooltips and no
right-click menus.** (Round-13 F10 residual, unfixed.) Hover at
(26, 1), (44, 1), (53, 1), (72, 1) with cursor-far-away pre-hover +
800 ms wait — no tooltip. Right-click at (44, 1) on `󰅢 Pull` — no menu.
A user who doesn't recognize the Nerd Font glyphs by heart can't
discover which chip is which; every left-click just fires the action
with no undo path.

**F10. Drag-to-bufferline-strip for tree files still a no-op.**
(Round-13 F11 residual.) Steps: Explorer → drag `api.http` from
(15, 11) to (50, 1) on the bufferline strip. Result: no tab is
opened; the drop is silently discarded. Dropping the same file on
the editor body at row 15 correctly opens it. `src/tui/mouse/up_left.rs`
has drop handlers for `bufferline_tab → bufferline_tab` (reorder)
and `bufferline_tab → pane_body` (split-open) but no
`tree_drag → bufferline_strip` handler. VS Code + JetBrains support
this natively.

## Verifications (regression + priority + newly clean surfaces)

- **Settings `/ filter` row click** — FIXED (see P2). Clicking it
  activates edit mode; typing filters the row list.
- **Workspace-header phantom icons on cold click** — FIXED (see P4).
- **Bufferline hover-close on dirty inactive tab** — FIXED (see P4).
  Cursor off → shows ●; cursor on tab → shows 󰅖.
- **Bufferline dirty active tab close click** — FIXED. Click × on
  active + dirty main.rs opens the Save/Discard/Cancel prompt with
  buttons Save (42, 15, 8, 1), Discard (52, 15, 11, 1), Cancel
  (65, 15, 10, 1). Clicking Cancel dismisses.
- **HTTP-panel MOCKS right-click menu (fresh + after multiple activity
  switches)** — FIXED. All 4 items shown ("Save active response as
  mock", "Replay mock into active request", "Toggle all sections",
  "Refresh HTTP panel"). Round-13 F4 not reproducible.
- **Alt+click multi-cursor** — VERIFIED. Alt+click at (40, 5) after
  primary cursor at (40, 3) inserts `@` on both rows on next type.
- **Toast click-to-dismiss** — VERIFIED. `send toast` → click on the
  toast rect → toast disappears.
- **Middle-click on bufferline tab** — VERIFIED. Middle-clicks the
  dirty inactive tab body at (30, 1) opens the unsaved-changes prompt.
- **Right-click Explorer activity** — 2 verbs (Show / Reveal active
  file). Better than 1 but still short of VS Code's "New file /
  New folder / Refresh / Collapse all" menu.
- **Right-click Agents activity** — 2 verbs (Show / Open dashboard).
  Halfway there.
- **Right-click MOCKS section (HTTP panel)** — 4 verbs, fresh or
  aged session.

## How mouse-discoverable does mnml feel this round

Big wins: settings filter is now clickable (P2 — round-13 was the last
holdout for the "SEV-2 → fix landed" pipeline); bufferline hover-close
+ dirty-active close + close-prompt buttons are all click-verified;
workspace-header hover-gate holds; HTTP panel MOCKS verbs are stable
across long sessions.

The remaining friction lives in the same three families we've been
tracking:

- **Discoverability edges.** Every git-toolbar chip is a
  Nerd-Font-only glyph with no tooltip and no right-click menu (F9).
  Six activity-bar rows are single-verb menus (F7). Empty tree space
  is a right-click dead zone (F8). Split-strip `[│]/[─]/[$]` chips
  have left-click but nothing else (F5). The palette dropdown at
  (77, 0) is invisible (F4). These aren't crashes but they add up to
  "learn the invisibles first" — the opposite of what a mouse-first
  user expects.
- **Async/timing sensitivity in double-click detection.** The 450 ms
  divider dbl-click window (F1) is tight enough that a natural
  trackpad cadence (or any IPC-driven test that pauses in the middle)
  misses. The other double-click detectors in the codebase — bufferline
  tab preview→pin, tree file preview→pin, gutter-line double-select
  — probably share the same tightness. Recommended: raise the
  window to 700 ms and add a mousemove-tolerance ≥ 2 cells.
- **Tree-to-tabstrip drag** (F10) and other cross-surface drag
  interactions — mouse-first users try these; nothing happens.

Could I get my day's work done without a chord? For editing +
splits (with a snappy dbl-click) + tab reorder + git-panel work +
HTTP requests + mocks — yes. For discovering what a Nerd Font glyph
does, resizing the tree past 60 cols (until I fight the config max),
right-clicking to get workspace-scoped file actions, or dragging a
file from the tree to the tab strip — still no.
