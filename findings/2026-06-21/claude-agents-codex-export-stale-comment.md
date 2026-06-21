---
finding: codex-export-stale-comment
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
The `e` export command for Codex rows outputs a fallback markdown with the comment "Codex transcript format isn't parsed yet", but as of commit `ff174d2` the Codex transcript parser (`parse_codex_tail`) is fully implemented and extracts bash commands, user/assistant messages, token counts, and model. The export does not walk the Codex transcript file even though it could, producing an unnecessarily thin export.

## Steps to reproduce
1. Have a Codex session with some activity (the transcript file exists under `~/.codex/sessions/`).
2. Select the Codex row in `:ai.agents_dashboard`.
3. Press `e` to export.
4. Open the exported `.md` file.
5. Observe: "Codex transcript format isn't parsed yet" and no conversation history.

## Expected
The exported markdown should include the Codex session's conversation (user prompts, assistant responses, bash commands) from the parsed transcript, same as Claude exports do.

## Observed
Minimal metadata only. The comment is stale — the parser exists and works.

## Suspected cause
`export_transcript_as_markdown` in `src/claude_agents.rs` at line 2050-2068: the early return for `AgentSource::Codex` was written before `parse_codex_tail` was implemented. The function should use `parse_codex_tail` (or a full-file variant) to walk the Codex transcript and emit conversation markdown.
