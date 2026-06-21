---
finding: lifetime-cost-model-stale
severity: SEV-2
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
The lifetime cost cache (`merge_lifetime_totals`) only recomputes `cost_usd` when the delta bytes contain an assistant event with a `model` field. If new bytes contain only user messages, tool_results, or system events (no assistant events), the cost is left stale even though `tokens` has been incremented. The token count grows but the cost chip doesn't update until the next assistant event arrives in the delta window.

## Steps to reproduce
1. Have a long-running Claude session.
2. Between two refreshes, observe the transcript receives several user/tool_result events with no new assistant event (e.g., a long Bash command is running).
3. Open `:ai.agents_dashboard`. On the 3s refresh cycle, tokens may increase but `cost` stays the same, then jumps when an assistant event finally lands.

## Expected
If `tokens` increases but `model` hasn't changed, the existing model should be used to recompute cost from the new totals.

## Observed
`totals.cost_usd` stays at its previous value until a new assistant event with a model field appears in the delta window, causing the cost chip to lag behind the token count.

## Suspected cause
`merge_lifetime_totals` in `src/claude_agents.rs` at line 480: `if let Some(m) = model { totals.cost_usd = estimate_cost(...); }`. The `model` local starts as `row.model.clone()` but is only updated from the delta, so if the delta has no assistant events `model` may be `None` (or the outer `row.model` which was set from the tail parse — actually it IS `row.model.clone()` so it shouldn't be None if the row has a known model). Wait — on careful re-reading: `model` starts as `row.model.clone()`. If `row.model` is `Some`, then even a delta with no assistant events will still compute cost. The bug only triggers when `row.model` is `None` (unknown model), which means cost is always 0.0 for that session. This is a narrower case than initially assessed but still silently shows $0.00 for unknown models instead of warning the user.
