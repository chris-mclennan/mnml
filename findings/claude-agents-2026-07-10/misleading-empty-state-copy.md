---
finding: misleading-empty-state-copy
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
When any filter combination narrows the Claude Agents dashboard's visible
row set to zero, the empty-state message only branches on whether the text
query (`/`) is empty — it never accounts for `state_filter`, `source_filter`,
`workspace_only`, or `age_filter`. So filtering to a state/source/workspace
combo that happens to match nothing (e.g. `1` for Streaming when nothing is
currently live, `W` workspace-only in a workspace with no active sessions,
or the dead `ecs`/`managed` source stops — see the companion SEV-2 finding)
all render the exact same copy: "no Claude sessions found under
~/.claude/projects/ in the last 7 days." That phrasing reads as "the on-disk
scan found nothing at all," not "your current filter combo excludes
everything," which sends a power user down the wrong troubleshooting path
(e.g. double-checking `~/.claude/projects/` on disk) instead of the right
one (checking/clearing their active filters).

## Steps to reproduce
1. `command ai.dashboard` in a workspace with real Claude session history.
2. `key 1` (state filter → Streaming) when no sessions are currently live.
3. Observe body text: "no Claude sessions found under ~/.claude/projects/
   in the last 7 days" — even though the title chip correctly shows
   `state:live · 0/<N>` and N is clearly non-zero.
4. `key 0` to clear, `key W` to toggle workspace-only in a workspace with
   zero recorded sessions — same misleading copy again.

## Expected
The empty-state copy should distinguish "literally nothing on disk" (query
empty, no filters active, 0 total rows) from "your filters exclude every
row" (any filter active, 0 visible out of N total) — e.g. "no sessions
match the current filters (N total, all hidden) · Ctrl+L to clear."

## Observed
Same static copy for every empty-result cause except the text-query case,
which already gets its own (correct) `no sessions match {query:?}` message.

## Suspected cause
`src/ui/claude_agents_view.rs:150-156` — the `vis.is_empty()` branch only
checks `p.query.is_empty()`, ignoring `state_filter` / `source_filter` /
`workspace_only` / `age_filter` when choosing which message to show.
