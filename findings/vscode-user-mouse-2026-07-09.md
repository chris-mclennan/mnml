# VS Code mouse tester — 2026-07-09 session hunt

Driven headless via `.mnml/ipc/command`. Workspace:
`/private/tmp/mnml-vscode-mouse-hunt-56192`.

## Findings

### 1. Cross-panel filter focus bleed on section switch — **SEV-2**

Same root cause as the nvchad-user's SEV-2 (filter absorb
block never re-checks state) but manifests as a data-loss
window in the mouse flow.

**Repro:**
1. Click Todos icon.
2. Click filter row at `(col=15, row=2)` to focus.
3. Type `baker` — Todos header shows `(1 of 1 hits)`, filter
   shows `baker▏`.
4. Click Notes icon at `(col=1, row=20)`.
5. Notes renders with unfocused `/ filter`.
6. Click Notes filter row — placeholder flips to
   `type to filter…▏` (Notes IS focused visually).
7. Type `apple` — nothing appears in the Notes filter.
8. Click Todos icon back — Todos filter now reads
   `bakerapple▏`, header shows `(0 of 1 hits)`.

Two filters "focused" at once. The older filter's absorb
block in `src/tui/mod.rs:873` intercepts before the newly-
clicked filter's handler runs. User sees the Notes cursor
blink while their query is silently dumped into Todos.

**Fix:** `set_activity_section` in `src/app/layout.rs` must
clear every `<section>_panel_filter_focused` on transition.
Combined with the nvchad-user's guard-hoist fix, this closes
both the keyboard and mouse angles of the same defect.

### 2. "No matches" hint truncated in all three panels — **SEV-3**

Panel body is ~27 cells wide; the hint
`"No matches — try clearing the filter (Esc)."` is 43 chars.
Rendered: `No matches — try clearing` (Todos/Notes) and
`No matches — clear the fi` (Sessions).

The `(Esc)` affordance is invisible — new users have no
mouse-clue how to unstick the empty view.

`src/ui/{todos,notes,sessions}_panel.rs`.

**Fix:** shorten to `"No matches — Esc clears"` (24 chars) or
wrap onto two lines.

### 3. Integration Remove confirm — title truncated + missing `?` — **SEV-3**

Dialog width is 45 cells inside its box. Rendered title:
`Remove integration 'browser' from the rail` — no trailing
`?`, and long integration ids will overflow silently.

`src/app/discovery.rs::open_integration_remove_confirm`.

**Fix:** widen the dialog when the id is long, or shorten to
`Remove '<id>' integration?`.

### 4. Filter-input rects not exposed via IPC — **SEV-3**

`todos_panel_filter_input`, `notes_panel_filter_input`,
`sessions_panel_filter_input` are populated on `PaneRects`
but omitted from `src/ipc/mod.rs::rects_dump_json`.

Same for `split_strip_ai_buttons`.

**Impact:** blocks headless test tooling from discovering
these hit targets without hardcoding coords.

**Fix:** add the four rect fields to the dump serializer.

### 5. Cancel + Esc + click-outside all preserve integration — **verified** (not a finding)

## Verified clean (mouse-only)

- **Panel filters** — click to focus, type to narrow, header
  `(N of M)`, Esc clears+unfocuses, click-outside-in-rail
  defocuses. (The SEV-2 above is the cross-panel case; the
  single-panel flow works.)
- **Integration Remove confirm** — right-click chip → Remove
  opens dialog; Cancel/Esc/click-outside preserves; Remove
  button removes + `(9)` → `(8)` count updates.
- **Tab-strip AI chips** — left-click `` spawns Claude
  Code; left-click `` spawns Codex. Right-click opens
  correctly-flavored menu. "Place new session in left/right/
  bottom half" places correctly. Existing `$` / `⊟` / `⊞`
  still fire.
- **HTTP preview tab** — entering HTTP auto-opens Request
  pane; leaving without touching drops it; typing a URL
  promotes it — leaving keeps it.

## Files
`/private/tmp/mnml-vscode-mouse-hunt-56192/.mnml/ipc/{screen.txt,rects.json,events.jsonl}`
