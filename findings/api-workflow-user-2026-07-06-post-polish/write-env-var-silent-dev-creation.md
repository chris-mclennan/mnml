---
finding: write-env-var-silent-dev-creation
severity: SEV-3
surface: env-resolution
---

**Repro**:
1. Start mnml in a fresh workspace that has no `.mnml/env/`, no `.rqst/env/`, `MNML_ENV` unset, no `[http] default_env` in config, no `.rqst/config`.
2. Complete the full `:http.lookup` flow: accept a file, wait for the response, pick an item, type a var name (e.g. `LOCATION_ID`), press Enter.
3. Inspect the filesystem.

**Expected**: Either an error ("no active env — pick one first"), or a prompt asking which env file should receive the write.

**Actual**: Silently creates `.mnml/env/dev.env` containing `LOCATION_ID=<picked-id>` and toasts `wrote LOCATION_ID=... → .../dev.env`. A file named `dev` appears from nowhere without the user ever having set up a `dev` environment.

**Root cause**: `src/app/http.rs` line 1735 in `write_env_var`:

```rust
.unwrap_or_else(|| "dev".to_string())
```

When `EnvSet::select_with_config_default(...)` returns an empty `EnvSet` (all four resolution tiers fail), `.name()` returns `None`, and the `"dev"` literal string is used as the env name. `write_env_var` then upserts into `.mnml/env/dev.env`, creating it if it doesn't exist.

**Scope**: The same `unwrap_or_else(|| "dev")` fallback appears in four places:
- `write_env_var` (line 1735) — lookup final stage, Vars-tab cell edit
- `http_delete_env_key` (line 1789) — Vars-tab delete
- `accept_env_edit_value` (line ~1643) — Vars-tab value edit
- `accept_env_add_key` (line ~1579) — "+ Add" in Vars tab

**Impact**: A user with only `.rqst/env/staging.env` who fires a lookup will find their var in the unexpected `.mnml/env/dev.env` rather than `staging.env`. The toast path is shown but easy to miss in the normal flow.

**Notes**: The mitigation is the toast showing the full path. This is SEV-3 rather than SEV-2 because the behavior is deterministic and recoverable. Upgrade consideration if the workspace has an existing env with a different name and the user is surprised when their var is not found in `staging`.

The fix is to either refuse the write when no env is resolvable (toast "no active env — use :http.select_env first") or ask for a filename via a prompt. The "dev" fallback was probably a convenience during development; it's a trap in real workspaces.
