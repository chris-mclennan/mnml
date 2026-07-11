---
finding: macos-pgrep-af-kills-live-detection
severity: SEV-1
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
`scan_running_pids()` shells out to `pgrep -af <exe>` expecting GNU-style
output (`"<pid> <full cmdline>"`), but on macOS/BSD `pgrep -a` means
"include process ancestors in the match set" — it does **not** print the
cmdline. The correct BSD flag for that is `-l` (long output) combined with
`-f` (match full args): `pgrep -fl <exe>`. As a result, on macOS every
`pgrep -af claude` / `pgrep -af codex` call returns bare PID lines with no
trailing space, `line.splitn(2, ' ')` fails to extract a cmdline, and
`scan_running_pids()` silently returns an **empty Vec**, always — no
Claude/Codex process is ever associated with its session row, no matter
how many are genuinely running.

Downstream this breaks: state is always `Ended` (never `Streaming` /
`ToolCall` / `Idle`), the `● N live` counter in the title bar is
permanently stuck at 0, live-tail never engages, and `K` (kill) always
reports "no PID — session already ended" for sessions that are in fact
live and killable — the kill action is completely non-functional on
macOS. This is the primary dev platform (`env` reports `Platform: darwin`).

## Steps to reproduce
1. Compile a trivial long-running binary literally named `claude` (a
   script won't do — shebang execution rewrites argv[0] to the
   interpreter, e.g. `/bin/bash`, which breaks the exe-basename check
   too) and launch it as `./claude --session-id <uuid>` where `<uuid>`
   matches a fixture transcript filename under
   `~/.claude/projects/<ws>/<uuid>.jsonl`.
2. Confirm real process presence: `ps -p <pid> -o pid,command` shows the
   full path + `--session-id <uuid>` args.
3. Open `:ai.dashboard`, refresh (`r`). The row for `<uuid>` shows
   `state: ended`, `pid —`, and the header shows `0 live`.
4. Select that row, press `K`. Toast reads `no PID — session already
   ended` (verified via headless IPC `events.jsonl` / `screen.txt`).
5. Manually run the exact command mnml issues:
   `pgrep -af claude` → prints bare PID lines, no cmdline, confirming the
   parser starves.  `pgrep -fl claude` (the correct BSD invocation) →
   prints `<pid> <full cmdline>` correctly and would parse fine.

## Expected
Live Claude/Codex processes are detected, state reflects
Streaming/ToolCall/Idle appropriately, and `K` sends a real SIGTERM to a
genuinely running PID.

## Observed
`scan_running_pids()` returns empty on macOS unconditionally. All
sessions show `ended` regardless of real process state; `K` never sends
a signal to a live session because `row.pid` is always `None`.

## Suspected cause
`src/claude_agents.rs:2735-2736` — `pgrep -af <exe>` (Linux/GNU-pgrep
semantics for `-a`, wrong on macOS's BSD pgrep where `-a` = "include
ancestors"). Should be `pgrep -fl <exe>` (or `-afl` if ancestor-inclusion
is actually wanted) so the second column carries the process's full
argument list the parser at `src/claude_agents.rs:2744-2769` expects.
