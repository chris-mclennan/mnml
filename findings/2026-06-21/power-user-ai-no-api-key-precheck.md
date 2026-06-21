---
finding: no-api-key-precheck
severity: SEV-3
agent: power-user-ai
repro: e2e
---

# 4 new AI commands skip the `$ANTHROPIC_API_KEY` precheck — toast "asking Claude…" before the key error arrives

`:http.ai_build` introduced an upfront key check at `src/app/http.rs:440-442`:

```rust
if std::env::var("ANTHROPIC_API_KEY").is_err() {
    self.toast("http.ai_build: $ANTHROPIC_API_KEY not set");
    return;
}
```

None of the 4 new commands do this. They:

1. Toast `asking Claude…` immediately.
2. Spawn the worker, which eventually hits the API client's check
   (`src/ai/api_client.rs:573`) and replies `AiMsg::Failed(...)`.
3. Drain handler emits a second toast `ai.<flow>: $ANTHROPIC_API_KEY not set …`.

Verified end-to-end in headless mode with truly unset env (`env -i`):

```
ai.explain_diff: asking Claude (working tree)…
ai.explain_diff: $ANTHROPIC_API_KEY not set — switch `[ai] backend = "cli"` or set the key
```

Two toasts, second one overwriting the first. The user sees the first
"asking Claude…" cleanly for ~1s, which is misleading when the call
never actually went out.

Worse, the worker thread spawn (`spawn_ai_job`, line 597) clones the
prompt + does ~10 lines of setup before the API client checks the key.
Not expensive but wasteful for an obviously-doomed call. And the CLI
backend (`[ai] backend = "cli"`) doesn't gate on the env var — different
failure mode for the CLI users, but the precheck wouldn't apply there
anyway.

Edge case worth flagging: an **empty-string** `ANTHROPIC_API_KEY=""`
sails past `std::env::var("...").is_err()` (which only fails on unset).
Empty string then reaches the API and gets a 401:

```
ai.explain_diff: HTTP 401 Unauthorized: {"type":"error",...
```

The 401 message is technically truthful but mystifying — users with
`.env` files that injected blanks won't know to look at their key.
Also pre-existing on the older AI commands, but the surface area just
grew by 4.

**Fix shape**:
- Add the same precheck pattern to each of the four entry points
  (`request_ai_pr_description`, `request_ai_explain_diff`,
  `request_ai_write_branch_name`, `request_ai_recompose_branch`).
- Or extract a single `self.require_api_key("ai.flow")?` helper that
  returns `bool` and toasts; call it at every API-backed entry point.
- Treat empty `ANTHROPIC_API_KEY` as unset in api_client.rs (one-line
  fix: change `std::env::var(...).map_err(...)` to also map a `.trim().is_empty()` result).
