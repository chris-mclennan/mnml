# Design critic — 2026-07-10 session audit

## TL;DR
All 5 findings from 2026-07-09 verified fixed. New findings mostly cluster
around one root cause: the "+ New X" action-chip idiom now has **three
different visual treatments** across four sibling panels (Agents = filled
pill, Notes/Integrations = green text, Sessions = dim-gray text), so the same
gesture reads with wildly different affordance strength depending which panel
you're in. Second: Sessions' keyboard-cursor indicator is a 1-cell left
stripe that a user-set `accent_color` can silently override entirely, unlike
Todos/Notes' unmissable whole-row highlight. Third: the Integrations panel
header is the only one of five sibling panel headers using `t.fg` instead of
`t.comment`.

## Verified fixed (2026-07-09 items)
1. Filter-panel header drift — confirmed: TODOS/NOTES/SESSIONS all render
   all-caps label in `t.comment`, count `(N of M)` gated on filter-active only.
   `todos_panel.rs:78-92`.
2. AI launcher menu duplicates — 5 distinct items now.
3. Split-button width floor — core cluster still paints at 9 cells.
4. `⚡ AI` chip — now cyan.
5. `IntegrationRemoveConfirm` — backtick-quoted, shortened.

## Issues found

### 1. "+ New X" action chip has three unrelated visual treatments — medium/high
**What:** Agents panel's `+ New session` is a filled pill (`bg=t.green,
fg=t.bg_darker`, `agents_panel.rs:178-184`). Notes' `+ New note` and the new
Integrations `+ Add integration` are green **text** on the panel bg, no fill
(`notes_panel.rs:264-274`, `ui/mod.rs:3360-3372`). Sessions' `+ New session`
is `t.comment` (dim gray) bold text — the least-affordant of the three
(`sessions_panel.rs:472-480`).
**Why it matters:** A user who learns "green pill = click me" in Agents won't
recognize the dim-gray Sessions chip as interactive at all; it reads more like
a disabled label than a call-to-action for the panel's single most common
action.
**Evidence:** `src/ui/agents_panel.rs:178-184` vs
`src/ui/sessions_panel.rs:472-480` vs `src/ui/notes_panel.rs:264-274`.
**Proposed fix:** Pick one treatment (the Notes/Integrations green-text style
is the majority — 2 of 4) and apply it to Sessions; reconsider whether Agents'
pill should downgrade to match or the other three should upgrade to pills.

### 2. Sessions keyboard-cursor row highlight can vanish under a custom accent — medium
**What:** Todos/Notes highlight the focused row with a full `t.bg2` fill.
Sessions instead paints a 1-cell-wide left accent stripe, and per the
priority comment "user-set color always wins; then keyboard-cursor cyan" —
if a session has any custom `accent_color` set (green/blue/yellow/etc.), the
cursor's cyan indicator is fully overridden and never shown.
**Why it matters:** A user arrow-keying through a Sessions list with several
custom-colored tabs has no visual indication of which row is under keyboard
focus — they have to track it mentally.
**Evidence:** `src/ui/sessions_panel.rs:182-202`.
**Proposed fix:** Reserve the cyan accent for cursor regardless of
`accent_color` (move the custom color to a different visual channel, e.g. a
small dot in the name row) or add a secondary cue (bg2 on row 1) that survives
accent overrides.

### 3. Integrations panel header is the one outlier of five siblings — low
**What:** TODOS / NOTES / SESSIONS / AGENTS / CLOUD AGENTS headers all use
`t.comment` (dim) for the bold label. INTEGRATIONS uses `t.fg` (bright).
**Evidence:** `src/ui/mod.rs:2996-3003` vs `src/ui/todos_panel.rs:76-82`,
`src/ui/cloud_agents_panel.rs:82-91`.
**Proposed fix:** Switch INTEGRATIONS header to `t.fg` → `t.comment` for
parity, or if the brightness is intentional (it's an overlay/panel hybrid),
note that as a documented exception.

### 4. Integration context menu buries the two new inspection actions — low
**What:** Order is Toggle → Move-to-top/up/down/bottom (4 items) → Edit… →
Copy id → Show manifest… → Remove. Copy id / Show manifest are read-only,
frequently-used lookups but sit 6 items deep, sandwiched right before the
destructive Remove.
**Evidence:** `src/app/context_menus.rs:346-387`.
**Proposed fix:** Move Copy id / Show manifest up to directly after Toggle
(before the reorder cluster) — they're inspection actions used far more
often than reordering, and grouping them away from Remove reduces mis-click
risk further than the 2026-07-09 fix already achieved.

### 5. AI split-position command titles drift from `ai.claude_code_new`'s phrasing — low
**What:** `ai.claude_code_new` reads "AI: open a NEW Claude Code session
(multi-session)". The 8 sibling split commands read "AI: new Claude Code
session in left half" — different verb ("open a NEW" vs bare "new"), and drop
the "(multi-session)" qualifier that explains *why* this doesn't reuse the
existing session.
**Evidence:** `src/command.rs:4841-4915`.
**Proposed fix:** Normalize to one phrasing, e.g. "AI: open a new Claude Code
session — left half".

## Patterns that are working well
- Filter-row idiom stays byte-for-byte consistent across six panels now
  including Integrations (chip bg, magnifier glyph, `▏` cursor).
- `markdown.edit_raw`'s title and placement in the `view` group correctly
  mirrors `markdown.preview` / `markdown.link_check`'s "Markdown: <verb>…"
  format — no drift there.
- Integration Remove confirm now matches the backtick-quote convention.
- Bitbucket's new `in_palette_bar = true` doesn't crowd the top strip — it's
  still the only community manifest opted in besides the built-in browser
  chip.

## Out of scope but noted
- `markdown.preview` / `markdown.edit_raw` are a toggle pair in behavior but
  not in naming (`preview` noun vs `edit_raw` verb+adjective) — a user
  tab-completing `markdown.` won't obviously guess they're inverses. Not
  today's regression, worth a rename pass (`markdown.raw`?) sometime.
- INTEGRATIONS has no `(N of M)` count anywhere in its header — the
  Installed/Marketplace tab labels carry counts instead, which is a
  reasonable alternate solution, not a gap.
