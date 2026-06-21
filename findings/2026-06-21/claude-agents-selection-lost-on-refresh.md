---
finding: selection-lost-on-refresh
severity: SEV-2
agent: claude-agents-power-user
repro: e2e
---

## What happened
When a selected session disappears from the visible row list (due to 7-day age rolloff, or a filter that hides it, or the session itself is culled), `refresh_in_place` does not reset `self.selected` to a valid index. The cursor visually disappears (no `▸` marker) and subsequent `j` keypresses start navigating from the stale (out-of-bounds) index rather than from the top of the list.

## Steps to reproduce
1. Open `:ai.agents_dashboard` with several sessions.
2. Navigate down to session at index 3.
3. Apply a state filter (`1` for live) that hides all ended sessions and leaves only 1 visible row.
4. `p.selected` is still 3, but only index 0 exists. No row is highlighted.
5. Press `j` — no movement (already at or past the end). Press `k` — moves to index 2, still not visible. The cursor is "stuck" at an off-screen index.

## Expected
When the previously-selected session is no longer in the visible set, `selected` should fall back to 0 (or the last valid index) so the cursor lands on a visible row.

## Observed
`selected` retains the old value; no row is highlighted; navigation from that stale index behaves confusingly.

## Suspected cause
`refresh_in_place` in `src/claude_agents.rs` at lines 711-718: the `if let Some(sid) = prior_sid && let Some(new_idx) = ...` block only updates `selected` when the prior session is found in the new visible set. When it isn't found, `selected` is left unchanged. A fallback `else { self.selected = 0; }` (or `.min(vis.len().saturating_sub(1))`) is missing.
