# API-workflow tester — 2026-07-09 session hunt

Verified via headless IPC (`.mnml/ipc/command` → `screen.txt` +
`status.json` + `events.jsonl`) plus direct `mnml discover`/`sync`.

## Findings

### 1. AI-prompt env classification uses OS env, not mnml's EnvSet — **SEV-2**
- `classify_vars` in `src/http/ai_prompt.rs` calls
  `std::env::var()` to decide whether a `{{VAR}}` is "defined"
  or "undefined". That's the OS process environment.
- mnml's actual var resolution reads
  `.rqst/env/*.env` / `.mnml/env/*.env` (`EnvSet`).
- Empirically confirmed: `MERCHANT_ID` resolves at send time
  (proven via `.rqst/history.jsonl` showing the expanded URL)
  but the copied AI prompt still lists it under
  "undefined vars: MERCHANT_ID".
- Additional issue: `http_copy_ai_prompt` (`src/app/http.rs:1775`)
  only passes `self.http_env_override` (explicit env picks)
  and doesn't fall back to `.rqst/config`'s `default_env`.
  So `active env: dev` is silently omitted for users who
  haven't manually picked an env — unlike every other
  env-consuming path in the codebase.
- **Fix**: replace `std::env::var()` with a lookup against
  the resolved `EnvSet` (build via
  `EnvSet::from_env_file(...)` at the call site).

### 2. `mnml discover --edge-cases` breaks formatted strings — **SEV-3**
- Root cause: `src/http/discover.rs:898-936`
  (`synth_example_edge_inner` for `string`).
- The min/max path truncates/pads strings to the schema's
  `minLength`/`maxLength` boundary. Defaults are 1 / 64 when
  the schema omits them.
- For `format: date-time|email|uuid` fields without explicit
  length constraints:
  - edge-min → `"createdAt":"2"`, `"email":"u"` (1-char
    truncations of ISO-timestamp / email / UUID bases)
  - edge-max → `x`-padded suffixes on the base ISO/email/UUID
    values, breaking the format
- edge-max also loses Tier-3 coherence: `email` reverts
  from the derived `john.smith@example.com` to generic
  `user@example.com`.
- Test coverage only exercises unformatted strings.
- **Fix**: when `format` is set to one of the fixed-shape
  formats (`date-time` / `date` / `email` / `uuid`), skip the
  length-boundary manipulation and return the base value
  as-is. Length-boundary edges are meant for opaque strings,
  not fixed-syntax ones.

## Verified clean — no findings
- **Preview-tab (commit `27d37ca`)**: entering HTTP creates
  an `is_preview` pane, leaving without editing drops it,
  typing promotes it and it survives a section change, 5x
  enter/leave cycles leak zero panes, idempotent re-entry
  doesn't duplicate, and `http.new`'s pinned tab correctly
  survives the leave-cleanup that closes only the untouched
  preview alongside it.
- **`⚡ AI` chip failure detection**: `is_response_failure`
  matches `build_prompt`'s branch logic exactly (2xx hidden;
  non-2xx and transport-error shown). Palette command no-ops
  cleanly on a 2xx response (clipboard untouched, no crash).
- **Redaction**: Bearer scheme preserved, token / API-key
  bodies gone, non-secret headers pass through unchanged.
- **`mnml sync` end-to-end**: happy path works.
- **Path-param env-var upgrade**: `{merchantId}` →
  `{{MERCHANT_ID}}` in generated curls.
- **Coherence pass**: derived email + +30min updatedAt +
  computed total all work in the happy-path stub.
