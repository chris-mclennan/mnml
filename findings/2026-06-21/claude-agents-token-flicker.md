---
finding: token-flicker
severity: SEV-2
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
Token counts and cost values in the row list and top-bar aggregate visibly decrease every 500ms for long-running sessions, then jump back up every 3 seconds. This is because `live_tail_selected` (the 500ms per-row tail) unconditionally overwrites lifetime-cache values with the smaller tail-window values.

## Steps to reproduce
1. Have a Claude session with a transcript file large enough that the tail window (256KB = roughly the last few hundred events) covers only a fraction of the total session.
2. Open `:ai.agents_dashboard` and select that session.
3. Watch the `tokens` and `cost` columns for the selected row and the top-bar `Σ tokens` and `≈ $X` aggregates.
4. Observe the values drop every ~500ms, then recover to the higher (correct) lifetime value on the 3s full refresh.

## Expected
Token and cost values should stay at the lifetime total (or monotonically increase), never decrease.

## Observed
Values oscillate: high value (lifetime) → low value (tail window, every 500ms) → high value (lifetime, every 3s) → repeat.

## Suspected cause
`live_tail_selected` in `src/claude_agents.rs` at lines 607-612 unconditionally assigns `row.tokens = stats.tokens` etc. from the 256KB tail-window parse, clobbering the lifetime value that `merge_lifetime_totals()` set during the last full refresh. The fix is to only apply the tail-window values when they are >= the current row values (same monotone guard that `merge_lifetime_totals` uses at lines 499-508), or to call `merge_lifetime_totals` after `live_tail_selected`.
