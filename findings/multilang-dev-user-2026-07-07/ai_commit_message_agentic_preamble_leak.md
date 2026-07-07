---
finding: ai-commit-message-agentic-preamble-leaks-into-seed
severity: SEV-2
agent: multilang-dev-user
language: ts | py | go
repro: e2e (live headless, real ANTHROPIC_API_KEY call, reproduced twice)
---

## Summary

`git.ai_commit` (the `C` key / "AI commit message" context-menu item / git
rail `m` chord) can seed the commit-message prompt with the model's
tool-use **narration** instead of an actual commit message, e.g.:

> `Let me look at the project context before writing the commit message.`

...even though the prompt sent to the model explicitly says:

> "Output ONLY the commit message — no preamble, no code fences."

## Repro

Real TypeScript repo (`/tmp/ts-test-workspace`), staged a small real diff
(`git add src/utils.ts`, a 3-line `slugify()` helper). Ran `mnml
/tmp/ts-test-workspace --headless`, fired `{"cmd":"run-command","id":"git.ai_commit"}`.
Toast: `asking Claude for a commit message…`. ~10s later the modal opened:

```
┌ Commit message (AI draft — edit & Enter) ────────────────┐
│ Let me look at the project context before writing the com│
└──────────────────────────────────────────────────────────┘
```

(confirmed full text via Home-key scroll — this is the actual start of the
line, not a display artifact). Reproduced this twice, on a fresh diff each
time.

## Root cause

`request_ai_commit_message()` (`src/app/ai.rs:1978`) embeds the full diff in
the prompt and asks for commit-message-only output, then dispatches through
the generic `spawn_ai_job()` (`src/app/ai.rs:722`). That function is
**always agentic**:
- CLI backend (`[ai] backend = "cli"`, the *default*): "CLI backend is
  unaffected (it always runs the full `claude` agent)" — per its own doc
  comment at `src/app/ai.rs:831`.
- API backend with `[ai] api_tools = true` (**default true**, per
  `ai_api_tools()` doc comment: "Default on — that's the point of the API
  backend being useful for more than short asks") — runs
  `crate::ai::api_client::agent_to_channel` (read_file/list_directory/grep
  tools), not the plain `stream_to_channel`.

So by default, *either* backend choice routes a "write me exactly this one
line, nothing else" task through a full agentic loop that's free to narrate
("Let me look at...") before or instead of producing the actual message —
there's no system-prompt override, no `tools=[]` for this specific
call, and no output-schema/tool-forcing to keep it on-message.

The consuming code then makes it worse: on `AiMsg::Done`, it takes only the
**first non-empty line** of the reply as the whole commit message
(`src/app/ai.rs:1918-1936`):

```rust
let summary = text
    .lines()
    .map(str::trim)
    .find(|l| !l.is_empty())
    .unwrap_or("")
    .trim_matches('`')
    .trim()
    .to_string();
```

If the model's actual final answer is multi-line and the first line happens
to be conversational narration (which the agentic path makes plausible), this
silently grabs the narration and drops whatever real commit message text
might follow it. There's no detection of "this doesn't look like a commit
subject" (e.g. starts with "Let me" / "I'll" / "I will" / ends with a
period on a full sentence) to fall back to a later line or retry.

My repro used my personal `~/.config/mnml/config.toml` (`[ai] backend =
"api"`), so the API+tools path is what actually fired here — but per the
code's own comments, the **default-config CLI backend is equally exposed**
(it always runs the full agent), so this isn't an artifact of my personal
setup.

## Impact

`git.ai_commit` is a headline, keybound (`C`), heavily-surfaced feature (git
rail chord, context menu, GitGraph WIP textarea). When it misfires this way,
the user gets a prompt pre-seeded with garbage that they have to notice,
discard, and type their own message instead — not catastrophic (they can
just overwrite the seeded text and hit Enter), but it defeats the point of
the feature and looks broken. Rated SEV-2 rather than SEV-1 since the app
doesn't crash and the fallback (type your own message) is always available.
Not language-specific — same risk on any repo/diff — but discovered while
driving the exact "AI commit message on a TypeScript diff" flow this task
asked for.

## Suggested fix direction (not applied)

For single-shot, format-constrained AI helpers (`git.ai_commit`,
`ai.write_branch_name`, `ai.recompose_branch`, `ai.write_pr_description`),
either (a) force `api_tools = false` / a tools-less call regardless of the
user's global `[ai] api_tools` setting, since the diff/context is already
fully embedded in the prompt and no tool access is needed, or (b) if tools
must stay available, strip a leading narration line (or take the *last*
non-empty line / require the reply to look like a commit subject) before
seeding the prompt, and surface a toast instead of silently seeding garbage
when the heuristic looks suspicious.
