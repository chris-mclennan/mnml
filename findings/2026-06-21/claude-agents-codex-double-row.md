---
finding: codex-double-row
severity: SEV-1
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
Every active Codex session appears twice in the dashboard: once as an "ended" row with transcript data (correct tokens/bash), and once as a "streaming" stub row with no token data. The disk-based row always shows `Ended` state even while Codex is running.

## Steps to reproduce
1. Start a Codex session (`codex` CLI), let it run.
2. Open `:ai.agents_dashboard`.
3. Observe two rows for the same session — one `· ended` (with tokens from the transcript file) and one `● live` (with `pid-XXXXX` as the session id, no token data).

## Expected
One row per active Codex session, showing `● live` or `▸ exec` state, with both transcript data and a valid PID.

## Observed
Duplicate rows. The "ended" row has the transcript data but no PID. The "live" stub row has the PID and correct state but no token/cost/bash data. `K` on the "ended" row shows "no PID — session already ended" even though the session is live.

## Suspected cause
`collect_codex_rows` in `src/claude_agents.rs` at line 1098: the PID match uses `sid == &session_id`. For Codex sessions, `scan_running_pids(AgentSource::Codex)` always returns `sid = ""` (empty string) because `parse_session_id_arg` only looks for `--session-id` / `--resume` flags, which Codex CLI doesn't emit. So the disk rows never get a PID assigned, always appear `Ended`, and the `on_disk_pids` set (line 1182) is always empty, so ALL pgrep-found pids become stub rows.
