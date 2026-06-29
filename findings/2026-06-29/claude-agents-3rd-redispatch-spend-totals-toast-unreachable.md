---
finding: spend-totals-toast-unreachable
severity: SEV-3
agent: claude-agents-power-user
verifies: f9e7dfa
repro: e2e
---

## What happened
The `else` branch in `ai_spend_today()` that toasts `"today: N sessions ·
$X.XXXX"` is unreachable after the background-thread refactor in f9e7dfa.
Every code path that reaches that check has already called either
`SpendReportPane::fresh()` or `sr.refresh()`, both of which set `loading =
true`. The "totals when ready" user-facing toast that should fire once the
worker completes is never emitted.

## Steps to reproduce
1. Open `:ai.spend_today`.
2. Toast says "computing spend… (background)".
3. Wait 1-2s for the worker to finish (loading badge disappears from title bar).
4. Run `:ai.spend_today` again.

## Expected
Second invocation (with worker already done) shows "today: N sessions ·
$X.XXXX" toast confirming computed totals.

## Observed
Second invocation calls `sr.refresh()` which immediately resets `loading = true`
before the toast check, so the toast says "computing spend… (background)" again.
The totals toast fires only if the bg thread finishes between `refresh()` and
the loading check — a race that never occurs in practice.

## Suspected cause
`src/app/cloud_agents_methods.rs:1016-1046`. The `refresh()` call at line 1017
sets `loading = true` unconditionally. The `if p.loading` check at line 1045
always evaluates true. The `else` branch (lines 1048-1052) is dead.

The fix would be to fire the totals toast from `poll_pending()` when the worker
channel drains, or to toast in `App::tick()` after detecting `loading` flipped
to false.
