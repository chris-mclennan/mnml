---
finding: help-overlay-stale-source-filter-cycle-text
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
`d6acd5b` (verified fixed and correct in this round — `>` / `<` now
cycle `None → Claude → Codex → None` / `None → Codex → Claude → None`,
never landing on Ecs/AnthropicManaged) changed the actual cycle behavior
in `src/tui/handlers/pane.rs` and `src/tui/mouse/mod.rs`, but never
updated the `?` help overlay's own row text, which still documents the
old, now-dead 5-stop cycle.

## Steps to reproduce
1. `:ai.dashboard`, press `?` (or F1).
2. Row under "Filters" reads: `> / <  cycle source filter (all → claude
   → codex → ecs → managed → all)`.
3. Compare against actual behavior (verified this round): the cycle is
   `None → claude → codex → None` only.

## Expected
Help text matches actual chord behavior.

## Observed
Help text still advertises `ecs` and `managed` as reachable stops, which
no longer exist in the cycle — directly misleading about a feature this
same fix commit intentionally removed. Note also
`tests/e2e/agents_help_source_filter_5stops.test` only asserts the help
text *contains* the literal substrings "claude"/"codex"/"ecs" (it
doesn't drive the actual `>` chord or assert cycle order), so it keeps
passing forever against this now-stale copy and gives false confidence.

## Suspected cause
`src/ui/claude_agents_view.rs:946-949` (`HELP_LINES` entry for `> / <`)
was not touched by `d6acd5b`.
