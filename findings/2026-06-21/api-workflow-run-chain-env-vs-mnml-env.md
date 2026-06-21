---
finding: run-chain-uses-mnml-env-var-not-config-default
severity: SEV-3
surface: http.run_chain
---

**Repro**:
1. Workspace has `.rqst/config` with `default_env=prod`.
2. `$MNML_ENV` is NOT set.
3. Run `:http.run_chain` on a chain that has `{{BASE_URL}}` templated.
4. The `prod.env` file has `BASE_URL=https://prod.example.com`.

**Expected**: chain uses `prod` env (from `.rqst/config` default), expands `{{BASE_URL}}` correctly.

**Actual**: `http_chain_run_path` (src/app/http.rs:381–410) captures `env_name` as:
```rust
let env_name = std::env::var("MNML_ENV").ok();
```
This only reads `$MNML_ENV`. The `EnvSet::select` resolution order (`explicit → $MNML_ENV → .rqst/config default_env`) is only applied in the App-side `send_request_from_active` call. In the chain worker (src/http/chain.rs:97), `EnvSet::select(workspace, env_name.as_deref())` is called with `env_name = None` when `$MNML_ENV` is unset — falling through to the `.rqst/config` `default_env` read, which IS implemented in `EnvSet::select`. So this actually works correctly via the fallthrough in `EnvSet::select`.

**Wait — revised**: The chain worker does call `EnvSet::select(workspace, env_name.as_deref())` where `env_name` comes from the spawn-site `std::env::var("MNML_ENV").ok()`. When `env_name` is `None`, `select` is called with `explicit = None`, which falls through to `$MNML_ENV` (re-read from process env — same result) then `.rqst/config`. So `.rqst/config`'s `default_env` IS honored for chains. The existing behavior is correct.

**The actual SEV-3 bug**: `http_chain_run_path` reads `$MNML_ENV` at the call site and threads it to the worker. If `$MNML_ENV` is set to `staging` but the user ran `:http.send` with an explicit `--env prod` argument (via the palette), the chain still uses `staging` — it ignores the explicit env the user set for the current send context. There's no mechanism to pass the currently-active explicit env override to the chain runner. This is especially confusing when the user switches env mid-session and expects a chain run to pick up their current context.

**Offending file:line**: `src/app/http.rs:391–392` — chain capture of `env_name` from process env only, with no reference to any App-side explicit env selection state. The App doesn't currently track an "explicit env" field (it re-runs `EnvSet::select` per-request using process env + config).
