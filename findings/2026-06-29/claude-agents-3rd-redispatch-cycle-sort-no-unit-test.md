---
finding: cycle-sort-cursor-preserve-no-unit-test
severity: SEV-3
agent: claude-agents-power-user
verifies: 54301a9
repro: e2e
---

## What happened
`ClaudeAgentsPane::cycle_sort()` correctly preserves the focused row across
sort cycles (the sid is captured before reordering, then re-located after), but
there is no unit test or e2e test locking this behavior. A future refactor of
the sort path could silently break cursor preservation with no test coverage
catching it.

## Steps to reproduce
(Would-be regression — behavior is correct today)

1. Open `ai.dashboard` with 3+ sessions.
2. Navigate to row 2 (not the top).
3. Press `s` to cycle sort.
4. Verify the same session is still selected.

## Expected
Same session remains selected (new position in the list after reorder).

## Observed
Works correctly in current code. No test guards it.

## Suspected cause
No test file covers this path. The unit test module in `src/claude_agents.rs`
(starting at line 2613) has no test for `cycle_sort`. An e2e test requires real
`~/.claude/projects/` JSONL fixtures to populate multiple rows; the write
directive in the test harness only supports writing to the workspace tempdir,
not HOME.
