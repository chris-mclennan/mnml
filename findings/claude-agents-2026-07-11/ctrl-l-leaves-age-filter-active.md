---
finding: ctrl-l-leaves-age-filter-active
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
`Ctrl+L` ("clear all filters") calls `ClaudeAgentsPane::clear_filters()`,
which resets `query`, `filter_mode`, `state_filter`, `source_filter`, and
`workspace_only` — but not `age_filter`. `any_filter_active()` (used for
the "filtered" indicator) also never checks `age_filter`. The toast still
says "filters cleared" even though a non-default age filter (`Today` /
`7d` isn't default-visible but `Month`/`All` are) silently survives.

## Steps to reproduce
1. Open `:ai.dashboard` with any rows present.
2. Press `A` twice to reach `All` — title bar shows `Claude Agents · All`.
3. Press `Ctrl+L`. Toast: "filters cleared".
4. Title bar still reads `Claude Agents · All` — verified via headless
   IPC screen dump before/after, chip text byte-identical.

## Expected
`Ctrl+L` is documented ("clear all filters at once") to drop every
narrow simultaneously, matching the persona's own "verify all four
narrows drop simultaneously" framing — but there are now 5 independent
narrows (text/state/source/workspace/age) after the age filter (#25 v4)
landed, and only 4 are wired into `clear_filters()`.

## Observed
Age filter persists across `Ctrl+L`, with a misleading "filters cleared"
toast and no visual indication that one narrow is still active.

## Suspected cause
`src/claude_agents.rs:985-992` (`clear_filters`) and
`src/claude_agents.rs:994-1001` (`any_filter_active`) both predate the
`AgeFilter` addition and were never updated to include it.
