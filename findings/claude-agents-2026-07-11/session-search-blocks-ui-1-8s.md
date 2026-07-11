---
finding: session-search-blocks-ui-1-8s
severity: SEV-2
agent: claude-agents-power-user
repro: e2e
---

## What happened
`:ai.session_search` (`ai_session_search_run` → `search_all_transcripts`)
runs entirely synchronously on the main event-loop thread inside the
prompt-accept handler. Against this machine's real
`~/.claude/projects/` (3,576 `.jsonl` files, 3.5GB total), a query with
no matches takes **1.4–1.8s wall-clock** to resolve — measured twice
(cold + warm FS cache) via headless IPC round-trip timing. During that
window the whole UI is unresponsive (no render tick, no input
processing) since it's the same thread handling the `enter` key that
triggered the search.

## Steps to reproduce
1. `mnml <any-workspace> --headless` (real `$HOME`, not a fixture — this
   needs the actual corpus size to reproduce).
2. `:ai.session_search`, type a query guaranteed not to match (e.g.
   `xylophone_zzz_nonexistent_query_12345`), press Enter.
3. Time from the `enter` IPC write to `screen.txt` reflecting the
   "no matches for ..." toast: 1.77s (cold), 1.39s (warm re-run with a
   different nonce query).

## Expected
Session search should feel roughly instant (sub-200ms) for interactive
use, or at minimum not freeze the whole TUI — the file-parsing comment
elsewhere in this same module (`parse_full`, re: `spend_today`) already
identifies synchronous large-file reads on the main thread as a SEV-2
freeze risk and moved that path off degenerate full-file reads. Session
search has no equivalent guard.

## Observed
1.4–1.8s blocking UI freeze per search against the real, currently-in-use
corpus — worse for a no-match / rare-match query since there's no
early-exit until every file has been scanned line-by-line (the 200-hit
cap only short-circuits on the *found* path, not the miss path).

## Suspected cause
`src/claude_agents.rs:2167` (`search_all_transcripts`) — full recursive
`BufReader` line scan across every `.jsonl` under `~/.claude/projects/`,
called synchronously from `src/app/cloud_agents_methods.rs:1099`
(`ai_session_search_run`), whose own doc comment states "grep is fast
enough for a few hundred MB; if it ever gets too slow we can move to a
worker" — the real corpus is already 3.5GB, past that stated assumption.
