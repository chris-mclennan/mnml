---
finding: branch-name-parser-weak
severity: SEV-3
agent: power-user-ai
repro: code-review
---

# `:ai.write_branch_name` parser misses common Claude-reply shapes

`src/app/ai.rs:1607-1615` (drain handler for the branch-name job):

```rust
let suggestion = text
    .lines()
    .next()
    .unwrap_or("")
    .trim()
    .trim_matches('`')
    .trim_matches('"')
    .to_string();
```

This handles `feat/foo-bar`, `` `feat/foo-bar` ``, and `"feat/foo-bar"`.
But Claude's replies aren't constrained — the prompt is best-effort.
Verified failures (independent test harness):

| Claude reply | Parsed result | Result |
|---|---|---|
| `` "`feat/foo-bar`" `` | `` `feat/foo-bar` `` | git refuses — backticks in branch name |
| `'feat/foo-bar'` | `'feat/foo-bar'` | git refuses — single quotes |
| ` ```\nfeat/foo-bar\n``` ` | `` `` `` (empty) | "empty reply" toast — must retry |
| `Branch name: feat/foo-bar` | `Branch name: feat/foo-bar` | git refuses — spaces + colon |

Repro:
```rust
let parse = |text: &str| text.lines().next().unwrap_or("").trim()
    .trim_matches('`').trim_matches('"').to_string();
assert_eq!(parse("\"`feat/foo-bar`\""), "`feat/foo-bar`"); // bug
```

The trim order (backticks first, then quotes) doesn't unwrap nested
wrappers. `trim_matches(|c| c == '`' || c == '"' || c == '\'')` would
fix the simple cases but still wouldn't strip the `Branch name:`
prose preamble.

**Fix shape**:
- Replace the `trim_matches` chain with a small regex/scanner that
  grabs the first `<type>/<slug>` token from the reply
  (`^(?:feat|fix|chore|docs|test|refactor)/[a-z0-9-]+`).
- Or: post-process with a sanity check — if the suggestion fails
  `git check-ref-format --branch <name>`, toast a friendlier
  "Claude returned `<x>` — couldn't parse a branch name from it,
  try rephrasing".

Severity SEV-3 because failure mode is a friendly git error message
when the user hits Enter — they just retry with different phrasing.
But it's a noisy first-impression bug on a new command.
