# Design critic — 2026-07-09 session audit

## TL;DR
Three real problems: (1) the three new filter panels don't actually
match each other in header copy/casing despite the commit messages
claiming parity; (2) the AI-launcher right-click menu has two items
that do the literal same thing; (3) flipping `tab_bar_ai_icon` to
`"both"` by default silently raised the width threshold for the
entire terminal+split button cluster from 9 to 15 cells, so narrow
split leaves now lose buttons that used to render fine.

## Issues

### 1. Filter-panel header drift — **medium**
- `todos_panel.rs:78` renders `"TODOs"` (mixed-case) while
  `notes_panel.rs:61` / `sessions_panel.rs` are all-caps.
- `todos_panel.rs:85-89` always shows a count
  (`"(N hits)"` even with no filter); Notes/Sessions only
  show `(N of M)` when filter is active.
- TODOs suffix `"hits"`; Notes/Sessions bare.
- Fix: unify to all-caps `"TODOS"`, pick one baseline-count
  rule, drop the `"hits"` suffix (or add it to the other two).

### 2. AI launcher right-click menu has duplicate items — **high**
- "Open new Claude Code session (right dock)" and "Place new
  session in right half" run the same code path — both are
  `open_pty_dir(profile, Horizontal)` (no swap).
- User can't tell them apart from the labels; picking either
  gives the same pane. 6 items should be 5.
- Fix: drop the parenthetical "(right dock)" from the top
  item, or drop the redundant right-half item from the
  placement list.

### 3. Default flip narrowed the split-button floor — **high**
- `split_buttons_width()` returns 15 cells for `"both"` vs 9
  for `"none"`.
- `paint_split_buttons` is all-or-nothing (`if area.width <
  total_w { return }`), per leaf.
- Leaves 9-14 cells wide used to show terminal+split
  buttons; now they show nothing. Regression in an unrelated
  feature caused by the AI-chip default flip.
- Fix: paint terminal+split first, only add AI chips if
  there's room, rather than gating the whole cluster on the
  AI-inclusive width. `src/ui/bufferline.rs:1262-1283`.

### 4. `⚡ AI` chip color reuses "orange = 4xx" hue — **low**
- Status codes render 4xx orange / 5xx red (`request_view.rs:1674`).
- The `⚡ AI` chip is unconditionally orange regardless of
  the underlying failure type.
- Chip is an action, not a status, so orange is confusing
  next to the status field on the same row.
- Fix: consider cyan or a neutral action color.
  `src/ui/request_view.rs:1912-1936`.

### 5. `IntegrationRemoveConfirm` title breaks the quoting convention — **low**
- Every other confirm-dialog title backtick-quotes the
  identifier (``Delete branch `name`?``).
- The new one uses single quotes:
  `Remove integration 'bitbucket' from the rail?`.
- `src/app/discovery.rs:269`.
- Fix: switch to backticks.

## Working well
- Filter-row visual idiom (chip bg, magnifier glyph, `▏`
  cursor, `type to filter…` placeholder) is byte-for-byte
  identical across HTTP/Agents/TODOs/Notes/Sessions.
- `IntegrationRemoveConfirm` correctly reuses
  `confirm_labels` + Cancel-default-focus plumbing.
- Preview-tab treatment on Request pane reuses the same
  italic styling as editor tabs (`bufferline.rs:700-701`)
  — one mental model for previews.
- `http.copy_ai_prompt` staying in the `http` command group
  is consistent with `http.ai_build`, not new drift.

## Out of scope but noted
- No help-overlay or tooltip explains what italic tab text
  means (preview tab) — pre-existing gap, now with a second
  surface (HTTP) relying on it silently.
- `SPLIT_BUTTONS_W_WITH_AI` constant (12) is dead for the
  `"both"` case (actual width computed inline as 15) —
  naming drift, not a design issue.
