---
finding: refire-stale-template-expansion
severity: SEV-3
surface: env-resolution
---

**Repro**:
1. Create `.rqst/env/prod.env` with `BASE_URL=https://api.prod.example.com` and `.rqst/env/staging.env` with `BASE_URL=https://api.staging.example.com`.
2. Set active env to `prod` (via `MNML_ENV=prod` or `:http.select_env`).
3. Open `check.http`:
   ```
   GET {{BASE_URL}}/healthz
   ```
4. Fire `:http.send`. URL resolves to `https://api.prod.example.com/healthz`. Request pane opens in Done state.
5. Switch active env to `staging` via `:http.select_env`.
6. Press `r` in the Request pane to re-fire.

**Expected**: URL re-resolved against `staging` env: `https://api.staging.example.com/healthz`.

**Actual**: URL sent as `https://api.prod.example.com/healthz` (the value stored in the pane from step 4).

**Root cause**: `src/app/http.rs` `refire_request` lines 3259-3263:

```rust
let (request, script, source_path) = match self.panes.get(pane_id) {
    Some(Pane::Request(rp)) => (
        rp.request.clone(),  // post-expansion copy from step 4
        rp.script.clone(),
        rp.source_path.clone(),
    ),
    _ => return,
};
```

`RequestPane::request` holds the post-expansion request — `{{BASE_URL}}` has been replaced with the literal `https://api.prod.example.com`. `refire_request` takes that clone directly and fires it, without consulting the current env.

**Context**: This is partly intentional — the Edit view lets users type literal URLs that survive `r`. The pane is designed to hold the editable, already-resolved request. But the consequence is that switching envs between fires is silently ignored for Request-pane refires.

The source file still has `{{BASE_URL}}` — re-opening it and firing `:http.send` from the editor pane creates a NEW request pane with the template re-expanded against the new env. The stale values only survive in the existing Request pane.

**User expectation**: API developers who switch envs expect `r` to hit the new env's server. The workaround is to close the Request pane and re-fire from the editor pane.

**Distinction from documented behavior**: The inline docstring for `refire_request` says "Re-send the request a `Pane::Request` already holds" — this is an accurate description of the current behavior, but no UI text tells the user that env changes don't affect `r`. Filing as SEV-3 (design decision with poor discoverability) rather than a regression.
