---
agent: claude-agents-power-user
severity: SEV-3
surface: claude-agents-dashboard
---

# Filter-mode pause (p.paused) is invisible in the title bar

Pressing `/` sets `p.paused = true`, halting the 3s full refresh AND
the 500ms live tail. The title chip `" · paused"` at
`src/ui/claude_agents_view.rs:28` only appears when `p.paused_by_user`
is true (the `p`-key toggle). While typing a query, the header reads
"Claude Agents · /query · enter applies · esc clears" — no pause hint.

A user who opens the filter, pauses on a partially-typed query for
several seconds, then exits with Esc — has missed 5-15s of live tail
with no indication.

Sites:
- `src/ui/claude_agents_view.rs:28-29` — pause_chip only checks
  `paused_by_user`
- `src/tui/handlers/pane.rs:938` — `p.paused = true` on `/`

## Fix
The filter-mode header could include a `(paused)` suffix while paused,
OR pause_chip should check `p.paused || p.paused_by_user`.
