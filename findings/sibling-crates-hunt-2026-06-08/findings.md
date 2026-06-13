# Sibling crate hunt — 6 scaffolded API clients · 2026-06-08

First-time hunt on the 6 messaging / integration sibling crates
scaffolded by background agents earlier today. None had been
hunted before.

| Repo | Build | Tests | Clippy `-D warnings` | --check |
|------|-------|-------|----------------------|---------|
| `mnml-msg-slack` | ok | 25 pass | clean | ok |
| `mnml-msg-teams` | ok | 30 pass | clean | ok |
| `mnml-msg-gmail` | ok | 34 pass | clean | ok |
| `mnml-msg-mandrill` | ok | 20 pass | clean | ok |
| `mnml-msg-buttondown` | ok | 24 pass | clean | ok |
| `mnml-virt-docker` | ok | 20 pass | clean | ok |

Every finding is behavioral or design — no gate flagged anything.

**Severity tally:** HIGH 4 · MED 8 · LOW 12

## Top 3 worst across the family

1. **Sync HTTPS in the TUI event loop** (slack worst, teams close behind).
   One keystroke can freeze crossterm for minutes. Family-wide
   architectural debt. Slack's `maybe_load_detail` fires on EVERY arrow-key
   press + can do 11 × 30s = 330s blocking.
2. **Teams 401-retry appends a SECOND `Authorization` header instead of replacing it.**
   Auto-refresh silently doesn't work — users see "expired" errors and
   must restart.
3. **Gmail loopback OAuth can be hijacked by any local TCP connection.**
   First connection wins; any unrelated process (Chrome extension,
   security scanner) beats the browser → cryptic failure.

## Top 3 quick wins

1. **Stop labeling "wrote config template" as ERROR** in the shared
   `config::load()` shape (6 repos, ~10 lines each).
2. **Drop the `ends …XXXX` tail in `mask_env`** for gmail / mandrill /
   buttondown — three one-line edits, removes family-wide secret-tail leak.
3. **Rebind `Esc` to overlay-cancel only** in mandrill / buttondown /
   gmail / docker. Bind `q` + `Ctrl+C` to quit; leave Esc for back-nav.

## mnml-msg-slack

- **[HIGH]** `maybe_load_detail` (`src/app.rs:206-230`) runs on every
  arrow-key press; synchronously calls `slack::conversations_history`
  (30s) + up to 10 serial `users_info` calls (30s each). Worst case 330s
  block. `App::new` does the same on startup. **Fix: worker thread + mpsc.**
- **[MED]** No retry on `Retry-After` (`src/slack.rs:108-116`). Slack's
  `users.info` is Tier 4 (100/min); prefetch-10 loop guarantees throttling.
- **[MED]** `sort_channels` docstring lies (`src/app.rs:587-595`) —
  says members-first/unread/alpha; only does members + alpha. `last_read`
  parsed but unread.
- **[LOW]** Bytes-padding mismatches char-width in
  `truncate(&primary, 28)` + `format!("{:<28}")` — emoji/CJK names
  misalign secondary column.
- **[LOW]** `mask_token` exposes cookie-marker prefix + last 4 chars.
- **[LOW]** `ts_to_hms` drops subsecond — two messages in the same
  second render at the same time.

## mnml-msg-teams

- **[HIGH]** `send_json` 401-retry path (`src/teams.rs:90-130`) uses
  `b.try_clone()` + adds a second `Authorization` header instead of
  replacing the first. Most servers honor the stale one. **Auto-refresh
  silently does nothing.**
- **[MED]** Sync Graph calls in keystroke handler
  (`src/app.rs:272-322 refresh_detail_for_selection`).
- **[MED]** Hard-coded "v0.1 doesn't auto-retry" message on 429 surfaces
  even when `Retry-After` IS present.
- **[LOW]** `strip_html` emits stray `;` on entity-name buffer overflow.
- **[LOW]** `user_display_name` has no negative cache — 404s re-cost
  per render.

## mnml-msg-gmail

- **[HIGH]** Loopback OAuth listener (`src/auth.rs:208-220`)
  `listener.accept()` once. If anything else on the machine connects
  first (Chrome extension, security scanner), code reads request, fails
  to find `?code=`, bails. **Need a loop with deadline.**
- **[MED]** No `state` param in `build_auth_url` (`src/auth.rs:229-236`) —
  CSRF defense in depth missing.
- **[MED]** `interactive_login` writes "You're signed in" HTML even on
  `?error=…` redirect (`src/auth.rs:286-305`).
- **[MED]** `with_fresh_token` triggers refresh only on string-match
  `"gmail: 401"` (`src/gmail.rs:564-581`). 403 from revoked tokens never
  refreshes.
- **[MED]** `build_rfc822` doesn't MIME-encode subject + no `Date:`
  header. Non-ASCII subjects violate RFC 5322; missing Date is a spam
  signal.
- **[LOW]** `drop_section` relies on `to_ascii_lowercase` preserving
  byte length (`src/gmail.rs:352-373`).
- **[LOW]** `&v[v.len()-4..]` in `mask_env` can panic on multi-byte tails.

## mnml-msg-mandrill

- **[MED]** `--check` leaks last 4 chars of API key in plaintext
  (`src/main.rs:102`). Mandrill keys are 22 chars → 18% entropy revealed.
  **Same leak in buttondown:90 and gmail:188 — family-wide.**
- **[LOW]** `users/ping.json` returns `"PONG!"` (JSON-quoted) but code
  returns raw text without unquoting (`src/mandrill.rs:107-109`).
  Currently unused, dormant.
- **[LOW]** `extract_mandrill_error` falls through on non-JSON 500s with
  no body fragment. Other siblings include up to 200 chars — diag gap.

## mnml-msg-buttondown

- **[MED]** First-run UX: `--check` labels "wrote config template" as
  ERROR (`src/config.rs:93-108`). After `fs::write(EXAMPLE)`, `load()`
  returns Err and `--check` exits 2 with scary-red. **Same pattern in
  slack, teams, gmail, mandrill, docker — family-wide.** Fix: parse just-
  written default + return Ok.
- **[MED]** `unsubscribe` uses HTTP `DELETE` — destructive
  (`src/buttondown.rs:248-262`). API has `PATCH type=removed` which
  preserves the record + analytics history. PATCH is almost always
  what the user wants on the `X` keybinding.
- **[LOW]** `extract_bd_error` iterates `serde_json::Map` (unstable
  order) — multi-field validation errors render different messages
  between runs.
- **[LOW]** `Esc` quits the TUI in normal mode (`src/keys.rs:43`).
  **Same in mandrill, gmail, docker — 4 of 6 siblings.**

## mnml-virt-docker

- **[MED]** Destructive actions (stop/rm/rmi) block UI for the duration
  of the shell-out (`src/docker.rs:299-321`). `docker stop` waits 10s
  for SIGTERM; `docker compose down` 30s+.
- **[MED]** `Esc` quits the TUI mid-task (`src/keys.rs:42`).
- **[LOW]** `parse_compose_ps` ndjson fallback treats empty-string as
  "no services" — same surface for "compose file missing".
- **[LOW]** Crate is tokio-based; other 5 siblings sync. Inconsistent.
- **[LOW]** `rm_container` / `rm_volume` accept empty id without
  validation.

## Notes

- No live calls on credential-gated paths (Teams Graph, full Gmail
  OAuth). Findings on those are static-read.
- TUI resize / div-by-zero static scan: body-row math uniformly safe
  across all six.
