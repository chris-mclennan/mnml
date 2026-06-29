---
finding: no-mnml-native-default-env-config-key
severity: SEV-3
surface: env-resolution
---

**Repro**:

1. Create a fresh mnml workspace with no `.rqst/` directory.
2. Create `.mnml/env/staging.env` with `API_BASE=https://staging.api.example.com`.
3. Open `requests.http` referencing `{{API_BASE}}`.
4. `:http.send` without setting `$MNML_ENV`.

**Expected**: A way to declare `staging` as the default env in a workspace-level config
file (e.g., `mnml.toml` or `.mnml/config.toml`) so all sessions at this workspace
automatically use `staging.env` without setting a shell env var.

**Actual**: Without `MNML_ENV=staging` in the process environment, `EnvSet::select` returns
an empty set. `{{API_BASE}}` is left verbatim in the URL. The only options are:
- `MNML_ENV=staging` in shell profile (process-wide, affects ALL workspaces in that shell)
- `.rqst/config` with `default_env=staging` (legacy rqst format, not documented for new workspaces)

**Root cause** (`src/http/template.rs:66`):

`EnvSet::select` checks only three sources:
```rust
let name = explicit
    .map(str::to_string)
    .or_else(|| std::env::var("MNML_ENV").ok())   // process-wide
    .or_else(|| read_rqst_config_default_env(workspace)) // legacy .rqst/config only
    .filter(|s| !s.trim().is_empty());
```

There is no `[http]` section in `src/config.rs` (`Config` struct) and no TOML key
for `default_env`. New mnml workspaces without a `.rqst/config` legacy file have no
per-workspace env configuration path.

**Fix direction**: Add `[http]\ndefault_env = "staging"` to `mnml.toml` / Config, read it
as a fourth fallback in `EnvSet::select`, or add a `.mnml/config` KEY=VALUE file read
analogously to `.rqst/config`. Either approach lets per-workspace default env be checked
in alongside the workspace's other config without leaking into unrelated terminal sessions.
