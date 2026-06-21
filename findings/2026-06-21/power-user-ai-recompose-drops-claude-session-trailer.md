---
finding: recompose-drops-claude-session-trailer
severity: SEV-3
agent: power-user-ai
repro: code-review
---

# `:ai.recompose_branch` prompt only protects `Co-Authored-By:` — drops `Claude-Session:` trailers

`src/app/ai.rs:1980-2000` — the recompose prompt:

```
- Preserve any `Co-Authored-By:` trailers verbatim.
```

But mnml's commit policy (the `Co-Authored-By: Claude Opus 4.7 …\n
Claude-Session: …` block) emits **two** trailer lines per commit. The
prompt only protects the first.

What this means in practice: a user runs `:ai.recompose_branch` on a
branch where every commit was authored by Claude (i.e. has both
trailers). Claude reads the prompt, sees only `Co-Authored-By:`
mentioned, and is likely to:

- Keep `Co-Authored-By:` ✓
- Strip `Claude-Session:` (model treats it as boilerplate) ✗

Net: the user pastes the suggested message into `git rebase -i` → reword,
loses the session link. Not destructive (it's only metadata), but breaks
the `claude.ai/code/session_…` link from the repo, which the user explicitly
relies on for the session-bounce review hook (`pre-push-review.sh`).

Less directly: the prompt also doesn't mention "Signed-off-by:",
"Reviewed-by:", "Fixes #…" lines, ticket-key footers, etc. Anything
non-`Co-Authored-By:` is at Claude's discretion to preserve or drop.

**Fix shape** (one-line prompt change):
```
- Preserve any trailer lines verbatim — these include:
  `Co-Authored-By:`, `Claude-Session:`, `Signed-off-by:`, `Reviewed-by:`,
  `Fixes:`, ticket-key footers (`TE-1234`), and the `🤖 Generated …` line.
- A trailer line is any line at the END of the body matching `<Key>: <value>`.
```

Also worth: paste a short example into the prompt of what the input/output
should look like so Claude sees the trailer block explicitly.
