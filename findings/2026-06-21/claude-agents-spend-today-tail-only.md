---
finding: spend-today-tail-only
severity: SEV-2
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
`:ai.spend_today` calls `spend_today()` which calls `parse_tail()` (256KB window) on each Claude transcript touched in the last 24h. For any session longer than roughly 256KB of transcript (a few hundred assistant turns), the command underreports both tokens and cost. Long sessions that represent the majority of the day's spend silently show much less than actual cost.

## Steps to reproduce
1. Have a Claude session with a large transcript (>1MB, common for multi-hour sessions).
2. Run `:ai.spend_today`.
3. Compare the reported cost to the per-row `cost` shown in `:ai.agents_dashboard` (which uses the `lifetime_cache` incremental reader).
4. `:ai.spend_today` reports significantly less.

## Expected
`:ai.spend_today` should use the same lifetime totals as the dashboard — either reading the full file once or using the incremental cache.

## Observed
`:ai.spend_today` shows tail-window costs only, potentially missing 80%+ of a long session's spend.

## Suspected cause
`spend_today()` in `src/claude_agents.rs` at line 2233: `let stats = parse_tail(&fp)` — uses the 256KB tail reader. The `lifetime_cache` on `ClaudeAgentsPane` is not accessible from this standalone function. The fix is to either do a full-file read in `spend_today()` (no 256KB cap), or expose a version of the lifetime-aware parser.
