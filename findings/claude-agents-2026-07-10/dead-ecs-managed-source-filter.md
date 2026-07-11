---
finding: dead-ecs-managed-source-filter
severity: SEV-2
agent: claude-agents-power-user
repro: e2e
---

## What happened
The Claude Agents dashboard's `>` / `<` source filter advertises 5 stops
(`all → claude → codex → ecs → managed → all`, per the help overlay and
`AgentSource::cycle`), but the `Ecs` and `AnthropicManaged` stops are
permanently dead — the pane's row set is built exclusively from
`prefetch_rows()` / `refresh_in_place()`, which only ever collect Claude
(`collect_rows`) and Codex (`collect_codex_rows`) rows. ECS-runner and
Anthropic-Managed-Agents rows are collected by a completely separate code
path (`App::refresh_agents_panel_if_due` → `ecs_runner::collect_cloud_rows_with_meta`
+ `anthropic_api::collect_managed_agent_rows`) that feeds only the rail
"Cloud Agents" activity-bar panel (`App::cloud_agents_rows`), never the
`Pane::ClaudeAgents` dashboard's `self.rows`.

Filtering the dashboard to `☁ecs` or `☁managed` therefore always shows
`0/<total>` regardless of how many cloud-agent runs actually exist, even
though those same runs are visible seconds later in the rail panel. Worse,
the empty-state copy ("no Claude sessions found under ~/.claude/projects/
in the last 7 days") implies a global emptiness / on-disk scan miss, not a
filter-scoping issue — actively misleading for a power user trying to
triage cloud-agent runs from the dashboard.

## Steps to reproduce
1. `command ai.dashboard` (with any workspace that has `~/.claude/projects/`
   transcripts — real user data works fine, no fixture needed).
2. `key >` three times to reach the `ecs` source-filter stop (or four times
   for `managed`).
3. Observe the title chip reads `☁ecs · 0/<N>` (or `☁managed · 0/<N>`) and
   the body shows "no Claude sessions found under ~/.claude/projects/ in
   the last 7 days" — for EVERY value of N, on every machine, regardless of
   whether ECS/managed cloud agents are actually running.
4. Confirm via `grep -n "fn build_anchored_from_rows\|fn refresh_in_place" src/claude_agents.rs`
   — neither path calls `ecs_runner::collect_cloud_rows_with_meta` or
   `anthropic_api::collect_managed_agent_rows`.
5. Contrast with the rail Cloud Agents panel (`App::cloud_agents_rows`,
   populated by `App::refresh_agents_panel_if_due`), which DOES merge both
   sources and can show non-zero rows at the very same moment the dashboard
   shows zero for the same filter.

## Expected
Either (a) the `>`/`<` cycle should skip `Ecs`/`AnthropicManaged` entirely
until the dashboard's row-collection actually merges those sources (matching
what `AgentSource::exe_name` / the help text imply is supported), or (b)
`ClaudeAgentsPane::rows` should be populated from the same cloud-row
collectors the rail panel uses so the filter stops have real data to show.

## Observed
`>` / `<` cycling through `ecs` and `managed` always yields `0/<total>`
rows and the misleading "no Claude sessions found under
~/.claude/projects/ in the last 7 days" empty-state message, even while
the separate rail Cloud Agents panel shows live ECS/managed rows at the
same instant.

## Suspected cause
`src/claude_agents.rs:773-811` (`refresh_in_place`) and `:1139-1150`
(`prefetch_rows`) only call `collect_rows` (Claude) + `collect_codex_rows`
(Codex) — no `Ecs` / `AnthropicManaged` merge. Those sources are only
collected in `src/app/mod.rs:7734-7766`
(`refresh_agents_panel_if_due`) into `App::cloud_agents_rows`, which feeds
`src/ui/cloud_agents_panel.rs` (the rail panel), not
`src/ui/claude_agents_view.rs` (the dashboard pane). The dashboard's
`>`/`<` handler (`src/tui/handlers/pane.rs:1149-1174`) and help text
(`src/ui/claude_agents_view.rs:942-954`) both assume all 5
`AgentSource` variants are reachable, but only 2 of 5 ever have rows.
