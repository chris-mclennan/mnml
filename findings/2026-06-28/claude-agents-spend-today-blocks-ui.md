---
agent: claude-agents-power-user
severity: SEV-2
surface: claude-agents-dashboard
introduced_by: 591a4b4
---

# :ai.spend_today blocks the main UI thread reading entire session files

`ai_spend_today()` calls `SpendReportPane::fresh()` which calls
`spend_today()` synchronously on the main UI thread. `spend_today()`
iterates every Claude session file modified in the last 24h and calls
`parse_full()` (the new function added in commit 591a4b4 to fix the
256KB tail undercount). `parse_full` calls `parse_stats(path, None)`
which executes `std::fs::read_to_string(path)` — whole-file read with
no cap.

For a user who ran three 4-hour Opus sessions (transcript files grow to
50-200 MB each from hundreds of tool-result turns), this reads
150-600 MB from disk sequentially. On a modern SSD the freeze is
measurable (1-5s); on a slow external drive or with several such
sessions, 10+ seconds with no spinner, toast, or feedback. Render loop
is fully blocked.

The prior `parse_tail` (256KB cap) ran in microseconds. The
`parse_full` change is correct for accuracy but the sync call site is
the problem.

Sites:
- `src/claude_agents.rs:1674` — `parse_full` / `read_to_string`
- `src/pane.rs:183` — `SpendReportPane::fresh`
- `src/app/cloud_agents_methods.rs:1007-1048` — `ai_spend_today`

## Possible fixes
- Move spend_today into a background thread; show a spinner toast
  ("computing spend…") and stream the result back via mpsc
- Cap parse_full at e.g. 10MB per file (still 40× more than parse_tail
  but bounded)
- Use a streaming line parser instead of read_to_string for
  arbitrarily-large files
