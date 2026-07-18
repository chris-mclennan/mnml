# API-workflow hunt — round 12 (2026-07-14)

Driven headless via the file-IPC channel (`<workspace>/.mnml/ipc/`) against
`./target/debug/mnml` at commit `c6fef50e`. Two scratch workspaces:

- `api-round12-ws` — mirrors the exact round-11 repro fixture: only
  `.mnml/env/dev.env` (`TOKEN=devtoken123`, `BASE_URL=https://httpbin.org`),
  **no `.rqst/config`, no exported `$MNML_ENV`, no `[http] default_env`**
  config. Used for the priority verification pass and for the new
  env-resolution findings below.
- `env-order-ws` — `.rqst/env/dev.env` + `.mnml/env/dev.env` with an
  overlapping `TOKEN` key (to check override precedence) plus a
  `.rqst/config` for the `default_env` fallback check.

Real network egress to `httpbin.org` was available and used for live
Send / chain / dynamic-var verification (not a local stub server this
round — traffic is real but read-only/idempotent GETs).

## Executive summary

**Priority verification: round-11 SEV-1 fix (`active_envset()`) is
CONFIRMED CORRECT for all 4 originally-cited call sites** — but that same
investigation surfaced a **new, more consequential SEV-1**: the fix aligned
the Vars-tab *edit* surface with `write_env_var`'s pre-existing "dev"
literal fallback, but the actual **Send path** (and `mnml run` / `mnml
chain run` CLI, and the hover-tooltip / left-click branch-decision on a
`{{VAR}}` token) never got that same fallback. In the exact `.mnml`-only
workspace shape the round-11 fix targets, the Vars tab now confidently
shows every var as resolved (green, correct values) — but clicking **Send**
fails every time with `✗ bad request: builder error`, and `mnml run FILE`
/ `mnml chain run FILE` fail identically from the CLI. There is no
`[http] default_env` / `$MNML_ENV` hint anywhere in the failing UI path
telling the user why a fully-green Vars tab still can't send.

**5 findings this round: 2 SEV-1 · 2 SEV-2 · 1 SEV-2 (reconfirm).**
Two round-11 SEV-2/SEV-3 items reconfirmed still broken (KV table
scrolling, mock-replay marker). Everything else swept this round —
multi-block `.http` navigation + send, chain var-propagation across
steps, chain failure-handling (stops at first non-2xx, correct exit
code), dynamic vars (`$uuid`/`$timestamp`/`$isoTimestamp`/`$epoch`) in
URL/query/headers, `.mnml/env` overriding `.rqst/env` on the same key,
and `.rqst/config`'s `default_env` fallback when present — all came back
clean.

## Priority verification scoreboard

- **Round-11 SEV-1 fix (Vars-cell edit no longer wipes value on
  Tab-commit)** — **VERIFIED FIXED**, exact repro re-run:
  - Value-cell click on `TOKEN` (`devtoken123`) → immediate `Tab` with
    zero typing → `.mnml/env/dev.env` still reads `TOKEN=devtoken123`
    (was: wiped to `TOKEN=` pre-fix).
  - Name-cell rename: click `TOKEN` name cell → type `j` → `Tab` →
    `.mnml/env/dev.env` reads `TOKENj=devtoken123` (value preserved
    under the new name, old key gone cleanly — not the destructive
    `TOKENj=` + original deleted that round-11 reported).
  - Right-click "Set value…" on `{{BASE_URL}}` in the URL → prompt seeds
    correctly with `https://httpbin.org`; submitting unchanged leaves
    the `.env` file byte-identical.
  - All 4 call sites now agree with each other **within `src/app/http.rs`**
    (`active_envset()` used consistently by `pending_var_at_cursor_name`,
    `open_env_var_definition`, `http_kv_edit_begin_cell`,
    `http_kv_edit_commit`). No read/write disagreement found among these
    four.
- **Two call sites round-11 flagged as "not re-verified... worth an
  audit pass" (the `EnvSet::select` anti-pattern at old-line `:4386` /
  `:4484`) turned out to be a red herring for THOSE specific line
  numbers** (they're `pending_var_at_cursor_name` / `open_env_var_definition`,
  both fixed) **but the audit found the identical anti-pattern alive in
  two OTHER files round-11 never looked at** — see Findings 2 and 3 below.

## Findings

### SEV-1

#### Finding 1 — Send / `mnml run` / `mnml chain run` all fail with "bad request: builder error" in the exact `.mnml`-only workspace the Vars tab shows as fully resolved

**surface**: env-resolution / http.send / cli-mode

**Repro** (workspace: only `.mnml/env/dev.env` with `BASE_URL` + `TOKEN`
set, no `.rqst/config`, no `$MNML_ENV`, no `[http] default_env`):

1. Open `req.curl` (`GET {{BASE_URL}}/get` with `Authorization: Bearer
   {{TOKEN}}`). Click the **Vars** tab — header reads `env: dev.env`,
   table shows `BASE_URL` = `https://httpbin.org`, `TOKEN` =
   `devtoken123`, both fully resolved, no warning glyphs.
2. Run `:http.send` (palette command, the `▶ Send` button, or the `r`
   key on a focused Request pane — all three route through the same
   `refire_request` / `send_request_from_active`).
3. Observe the Response pane.

**Expected**: the request sends successfully — `BASE_URL`/`TOKEN` are
right there, correctly resolved, in the tab the user is looking at.

**Actual**: `✗ bad request: builder error`. The template never got
expanded — `refire_request` resolves its `EnvSet` via
`EnvSet::select_with_config_default(workspace, http_env_override,
config.http.default_env)`, which (per `src/http/template.rs:83-98`)
tries explicit → `$MNML_ENV` → `[http] default_env` config → legacy
`.rqst/config`'s `default_env=` → **`Self::empty()`**. None of those
four are set in this workspace, so it comes back empty and
`{{BASE_URL}}/get` is sent to reqwest literally.

Same failure from the CLI, byte-for-byte:

```
$ mnml run req.curl --workspace ws/
warning: unresolved variables: BASE_URL, TOKEN
→ GET {{BASE_URL}}/get
mnml run: bad request: builder error
```

```
$ mnml chain run smoke.chain.json --workspace ws/
mnml chain: step 1: unresolved vars: BASE_URL, TOKEN
```

Passing `--env dev` explicitly on either CLI command makes both succeed
immediately (`env: dev` printed, `200 OK` from httpbin.org) — confirming
the vars/values themselves are fine; only the *implicit* "there's exactly
one `.mnml/env/*.env` file, use it" resolution is missing from every
send-time path.

**Root cause / why this is worse than a pre-existing gap**: this
specific 4-tier resolver (`select_with_config_default`, no "dev" literal
fallback) is not new — round-11's own report explicitly called it "the
correct 4-tier resolution" and contrasted it favorably against the
broken 0-config-default `EnvSet::select()` the Vars-tab edit-seed used
at the time. The round-11 fix (`active_envset()`, wrapping
`resolve_env_name_with_fallback`, which DOES add a literal `"dev"`
fallback — a convention that predates round-11 in `write_env_var`) was
scoped to bring the Vars-tab *read* path in line with the Vars-tab
*write* path. It was not scoped to reconcile with the *send* path, and
round-11's own report doesn't identify this as a live gap — but the
practical effect of "the edit surface now confidently agrees with itself
about vars being resolved" is that the gap between "what the UI shows"
and "what Send actually does" got **more convincing, not less** — a user
staring at a fully green Vars tab has zero signal that Send is about to
fail. Contrast the `write_env_var` path, which at least toasts `env: no
active env — using dev.env (set [http] default_env or MNML_ENV)` when it
falls back — the send path has no equivalent toast; it just fails.

Also confirmed: the *interactive* per-request-pane experience is
identical to the CLI's — there is no way, short of typing `--env dev`
into a CLI invocation or exporting `$MNML_ENV`/setting
`[http] default_env` in a config file, to make Send work against a
workspace containing nothing but a single `.mnml/env/dev.env`. Given
CLAUDE.md documents "explicit `--env`, `$MNML_ENV`, `.rqst/config`'s
`default_env`" as the resolution order with no mention of a "dev"
literal fallback, arguably the *documented* behavior is what Send does
and the Vars-tab/hover/click-to-jump paths (Finding 1's fix + Findings
2/3 below) are the ones that silently introduced an undocumented 5th
tier — either way, the two surfaces now disagree with each other in a
way a user can't discover except by hitting Send and reading a
cryptic reqwest builder-error string.

**IPC trace** (`events.jsonl`, condensed):
```
{"event":"click","button":"Left","col":"63","row":"7"}   # Vars tab
{"event":"run-command","id":"http.send"}
```
Response pane after: `✗ bad request: builder error` (border title
`✗ failed`).

**Notes**: `src/app/http.rs:4133-4137` (`refire_request`'s env
resolution — the actual `:http.send`/`r`-key/Send-button path for an
already-open Request pane), `src/app/http.rs:4075-4079`
(`send_request_from_active`'s parallel path for a freshly-opened
`.curl`/`.http` Editor pane), `src/app/http.rs:1355-1357`
(`http_chain_run_path`'s 2-tier-only `env_name` computation — doesn't
even reach the 3rd/4th tier `select_with_config_default` provides),
`src/main.rs:678` (`do_run`'s raw `EnvSet::select`, 3-tier, same gap),
`src/http/chain.rs:131` (`chain::run`'s `EnvSet::select(workspace,
env_name)` — receives whatever `env_name` the caller computed, no
fallback of its own), `src/app/http.rs:349-369` (`active_envset()`,
the 5-tier-with-"dev"-fallback resolver the edit surface uses but Send
doesn't).

---

### SEV-2

#### Finding 2 — Hover tooltip on a `{{VAR}}` token falsely reports "not defined in active env" for vars that ARE defined, in the same `.mnml`-only workspace shape

**surface**: request-pane / env-resolution

**Repro**: same workspace as Finding 1. Hover the mouse over `{{BASE_URL}}`
in the URL field for ≥500ms (`HOVER_TOOLTIP_DELAY_MS`).

**Expected**: tooltip reads `= https://httpbin.org · click to jump to
env` (matches what the Vars tab, the right-click "Set value…" prompt,
and `open_env_var_definition`'s click-to-jump all correctly show for
the same var in the same workspace).

**Actual**: tooltip reads `not defined in active env · click to open env
file` — false. `BASE_URL` is defined; every other var-inspection surface
in the same frame agrees it's defined.

**IPC trace**:
```
{"event":"hover","col":"50","row":"4"}
{"event":"snapshot"}
```
`screen.txt` after:
```
┌ {{BASE_URL}} ──────────────────────────────────────┐
│ not defined in active env · click to open env file │
└──────────────────────────────────────────────────────┘
```

**Root cause**: `src/ui/tooltip.rs:1093-1104` (`HoverChip::RequestVarToken`
arm of `describe()`) resolves the env via:
```rust
let envset = crate::http::template::EnvSet::select(
    &app.workspace,
    app.http_env_override.as_deref(),
);
```
— the exact anti-pattern round-11 fixed at 4 sites in `src/app/http.rs`,
alive in a 5th location the round-11 sweep never looked at
(`src/ui/tooltip.rs`, a different file). Should call `app.active_envset()`
like the other var-inspection call sites now do.

**Notes**: `src/ui/tooltip.rs:1093-1104`.

#### Finding 3 — Left-click on a correctly-resolved `{{VAR}}` token opens the "Set value…" edit prompt instead of jumping to the definition (documented click-to-jump behavior), same root cause as Finding 2

**surface**: request-pane / env-resolution

**Repro**: same workspace. Left-click `{{BASE_URL}}` in the URL field
(the same token Finding 2's hover mis-reports).

**Expected** (per `CLAUDE.md`'s documented behavior: "Left-click a token
→ jump to its definition line in `.mnml/env/<active>.env`"): since
`BASE_URL` IS defined, the click should call `open_env_var_definition`
and jump to the line in `dev.env`.

**Actual**: the click opens the `EnvEditValue` prompt instead
(`Value for BASE_URL:` — correctly pre-seeded with
`https://httpbin.org`, so no data loss, but the wrong branch). This is
the branch reserved for *undefined* vars (one-click "define it" instead
of the two-step right-click → Set value flow). `Esc` correctly cancels
the whole flow with no partial write.

**Root cause**: `src/tui/mouse/down_left.rs:790-808` computes `resolved`
via the same broken `EnvSet::select(&app.workspace,
app.http_env_override.as_deref())` (no config_default, no "dev"
fallback) to decide which branch to take:
```rust
let resolved = match name.strip_prefix('$') {
    Some(dyn_name) => crate::http::template::dynamic_var(dyn_name).is_some(),
    None => envset.lookup(&name).is_some(),
};
if resolved || name.starts_with('$') {
    app.open_env_var_definition(&name);
} else {
    app.accept_env_vars(&name);
}
```
In this workspace shape `envset.lookup(&name)` is always `None`
regardless of the actual key, so `resolved` is always `false` and every
var (defined or not) routes to `accept_env_vars` (the edit-prompt path).
Not data-lossy — `accept_env_vars` itself correctly re-resolves via
`resolve_env_name_with_fallback` when seeding the prompt — but it's a
visibly wrong UX branch for a workflow CLAUDE.md explicitly documents,
and it's the third call site carrying the identical stale-resolver
anti-pattern the round-11 fix was meant to eliminate.

**IPC trace**:
```
{"event":"click","button":"Left","col":"51","row":"4"}
```
`screen.txt` after: `┌ Value for BASE_URL: ─...─┐` prompt open (not a
jump to `.mnml/env/dev.env`).

**Notes**: `src/tui/mouse/down_left.rs:790-808`.

#### Finding 4 (reconfirm of round-11 F2) — Params/Headers/Vars KV tables still have no scroll; overflow rows unreachable, keystrokes leak into the URL field

**surface**: request-pane (Vars tab)

Re-ran the round-11 repro shape with 14 vars in `dev.env`. Table renders
only `BASE_URL` / `TOKEN` / `VAR1` before running out of vertical space
— `VAR2`…`VAR12` are simply gone, no scrollbar, no "+N more" indicator,
no `edit_tab_scroll`-shaped field exists anywhere in `src/request_pane.rs`
(grepped — still absent). Confirmed the "keystrokes leak into URL"
compounding factor still reproduces too: with the Vars tab visually
focused (post row-click), pressing `j` (or `r`, the Send re-fire
shortcut) appends the literal character to the URL field instead of
doing anything to the table —

```
before: {{BASE_URL}}/get
after 'r' then 'j': {{BASE_URL}}/getrj
```

— which also means the `r`-key re-fire shortcut silently no-ops (types
`r` into the URL) whenever the KV table has "focus" by virtue of having
just been clicked, since `EditField` focus never actually leaves `Url`.
Unfixed since round-11.

**Notes**: no `edit_tab_scroll` / equivalent field in
`src/request_pane.rs`; `src/ui/request_view.rs` KV-table render path
unchanged from round-11's citation (`:1318-1322` era, row-count still
naively clipped to available height with no offset).

#### Finding 5 (reconfirm of round-11 F3) — Replayed mock responses carry no persistent marker distinguishing them from a live response

**surface**: http.replay_mock

**Repro**: `http.send` a real request (200 OK, 298ms) → `http.save_mock`
→ `http.replay_mock` on the same pane.

**Actual**: the Response pane border reads `200 OK · 0ms · 307 B` — the
`0ms` elapsed time is the *only* signal, and it's set via
`elapsed: std::time::Duration::ZERO` in `http_replay_mock_from_path`
(`src/app/http.rs:3190-3229`) rather than any explicit "this is a mock"
flag on `ResponseView`. No `[MOCK]` badge, no distinct color, no
persistent indicator in the tab title or Timeline tab. A genuinely fast
real response (sub-millisecond, plausible against localhost) would be
visually indistinguishable. Unfixed since round-11.

**Notes**: `src/app/http.rs:3190-3229` (`http_replay_mock_from_path`)
builds `RunState::Done(ResponseView{..})` with no `source`/`is_mock`
field on `ResponseView` at all (checked the struct — no such field
exists).

## Swept clean this round

- **Multi-block `.http` navigation + send.** `.http` file with 3 named
  blocks (`login` / `fetch-orders` / `delete-thing`) opens directly as a
  Request pane on block 1; `http.next_block` correctly advances to
  block 2 (title + URL + query param all update); `:http.send` fires
  the CURRENTLY-SELECTED block (`?block=2` echoed back by httpbin, not
  block 1's `?block=1`).
- **Chain cross-step variable propagation.** A 2-step chain where step 1
  `extract`s `ORIGIN` from `$.origin` and step 2 references
  `{{ORIGIN}}` in its URL correctly threads the extracted value through
  (`?origin_seen=104.1.234.19` echoed back, matching step 1's real
  origin).
- **Chain failure handling.** A step hitting `httpbin.org/status/500`
  correctly stops the chain (`mnml chain: step 1: stopping at
  non-success 500`, exit code 1) — step 2 never fires.
- **Dynamic vars** (`{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`,
  `{{$epoch}}`) all resolve correctly and independently (fresh values
  per occurrence) across URL query params and a header
  (`X-Request-Id: {{$uuid}}`) in a single live send — verified via the
  echoed request body from httpbin.org.
- **`.mnml/env` overrides `.rqst/env` on the same key.** `.rqst/env/dev.env`
  had `TOKEN=rqst_token_value` + `SHARED=from_rqst`; `.mnml/env/dev.env`
  had `TOKEN=mnml_token_value` only. A live send with `--env dev`
  correctly sent `Authorization: Bearer mnml_token_value` (mnml wins)
  and `X-Shared: from_rqst` (rqst-only key still resolves) — confirms
  `EnvSet::load`'s two-pass merge (`src/http/template.rs:38-56`) is
  correct.
- **`.rqst/config`'s `default_env` fallback** — with no `--env` and no
  `$MNML_ENV`, a `.rqst/config` containing `default_env=dev` correctly
  auto-selected `dev` for a `mnml run` CLI invocation (`env: dev`
  printed, request succeeded). This is the ONE fallback tier that DOES
  work identically across the edit-surface / send-path resolvers — the
  gap in Finding 1 is specifically about the literal-"dev"-when-nothing-
  else-matches 5th tier, not this documented 3rd tier.

## How the round-11 fix landed, in context

The round-11 fix is solid for what it targeted (the destructive
Vars-cell edit) and I could not find any remaining read/write
disagreement within `src/app/http.rs`'s KV-edit surface. But the fix's
premise — "one helper, same fallback everywhere" — turned out to mean
"everywhere within one file," and the underlying inconsistency round-11
itself flagged in its closing paragraph ("Three different fallback
behaviors for 'no active env resolved'... across render / edit-seed
+commit-lookup / write... the actual defect") is still there in a 4th
and 5th shape: the *send* path (CLI + interactive, never touched) is
now the odd one out against an edit/inspect surface that's internally
consistent with itself but not with Send. Finding 1 is the sharp edge
of that: a completely green, fully-resolved-looking Vars tab that
cannot actually send a request, with no error message pointing at the
real cause.
