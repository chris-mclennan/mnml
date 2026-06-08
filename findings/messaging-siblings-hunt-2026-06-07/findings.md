# Messaging + tracker + virt siblings — bug hunt + code review

**Scope:** mnml-tracker-jira, mnml-msg-slack, mnml-msg-teams, mnml-msg-gmail, mnml-msg-mandrill, mnml-virt-docker.
**Date:** 2026-06-07.

**Build state:** all 6 build clean (`cargo build --release --quiet`), all clippy-clean. No `unwrap()` / `panic!()` in user-reachable code paths outside of mutex unwraps (reachable only after a prior panic).

## Summary

| Severity  | Count |
|-----------|------:|
| High      | 0     |
| Medium    | 5     |
| Low       | 12    |
| Tracking  | 4     |
| **Total** | **21**|

### Worst 3

1. **`mnml-msg-gmail` — OAuth loopback missing `state` parameter (Medium).** `src/auth.rs:229-236` builds the auth URL with no `state` param; loopback listener at `auth.rs:194-219` accepts any inbound connection on the ephemeral port. RFC 6749 §10.12 CSRF defense missing. Realistic exploit window narrow (local multi-user race); fix cheap.
2. **`mnml-tracker-jira` — JQL injection via fixVersion / component (Medium).** `src/app.rs:1090,1092` interpolates `version_name` (data-plane, from Jira API) and `component` (user TOML) into raw JQL without escaping `"`. A version named `Y" OR project = "OTHER` exfiltrates other-project issues. Fix: escape doubled-quote per Jira's JQL string-literal rules.
3. **Family-wide: blocking HTTP on the UI thread (Medium).** mnml-msg-slack / teams / gmail / mandrill / virt-docker all call blocking reqwest inside `submit_input()` / `refresh_active()` / per-keypress handlers. UI freezes for the full 30s reqwest timeout if backend is slow — user can't even press `q`. Only `mnml-tracker-jira` does this right (async tokio).

---

## mnml-tracker-jira

- **[Medium] M-1 — JQL injection.** `src/app.rs:1090-1093` in `resolve_tab_jql`:
  ```rust
  let mut jql = format!("project = {project} AND fixVersion = \"{version_name}\"");
  if let Some(c) = &tab.component {
      jql.push_str(&format!(" AND component = \"{c}\""));
  }
  ```
  `version_name` is server-data; Jira project-admins can name versions freely.
- **[Medium] M-2 — No pagination.** `src/app.rs:235` calls `self.client.search(&jql, 100)`. Jira caps at 100/page; tabs with >100 hits silently lose the tail (no "showing N of M" indicator). The `next_release` tab on a busy project hits this.
- **[Low] L-1 — `fetch_assignable_users` doesn't URL-encode `query`.** `src/jira.rs:226-229`. A typed `&maxResults=9999` injects an extra query param.
- **[Low] L-2 — Mutex unwraps in `src/blit.rs:53,232`.** Reachable only after a prior panic; opaque PoisonError if it fires.
- **[Tracking] `unwatch_issue` signature invites misuse** — comment documents this; fine for v1.

## mnml-msg-slack

- **[Medium] M-3 — Blocking HTTP on UI thread.** `src/app.rs:453,473,494`. `chat_post_message`, `reactions_add`, `search_messages` block the keypress handler.
- **[Low] L-3 — `mask_token` edge case** — `src/slack.rs:60-62`. Tokens of exactly 8 chars show "(8 chars)" only; 9-12 char tokens reveal most of the random suffix. Real Slack tokens are 50+ chars so cosmetic in production.
- **[Tracking] Clipboard outlier** — Slack uses `arboard` (system-lib dep); Teams/Gmail/Mandrill spawn `pbcopy`/`xclip` (zero deps). Family should pick one — different behavior on SSH-without-DISPLAY.
- **[Tracking] `Channel.last_read` parsed but unused** — v0.2 roadmap; comment acknowledges.

## mnml-msg-teams

- **[Medium] M-4 — URL path injection via Graph IDs.** `src/teams.rs:172,192,199,207,215,231,242`. team_id/channel_id/chat_id/message_id inserted into URL paths verbatim. Server-controlled so unlikely to bite, but defense-in-depth (URL-encode segments) is cheap.
- **[Medium] M-5 — RwLock token unwraps poison-prone.** `src/teams.rs:50,57,69,75,98,105`. Any panic between `refresh_token` and `*self.token.write().unwrap() = fresh` (line 65→69) poisons the lock; every subsequent Graph call panics with opaque PoisonError.
- **[Low] L-4 — 429 retry-after message is wrong.** `src/teams.rs:121-125`. Hard-codes `"Retry-After unset"` without ever reading the header. Misleading error.
- **[Low] L-5 — Search response shape brittle.** `src/teams.rs:259-281`. If Microsoft adds a sibling field, results silently empty.

## mnml-msg-gmail

- **[Medium] M-6 (worst-3 #1) — OAuth missing `state` parameter + permissive listener.**
  - `src/auth.rs:229-236` (`build_auth_url`) — no `state=…` on the auth URL.
  - `src/auth.rs:214` — `listener.accept()` takes any inbound, no path validation beyond "did it start with `/?`".
  - Fix: generate `state = random_hex(32)`, append `&state=…`, verify on redirect; bonus: 10-min `accept` timeout.
- **[Low] L-6 — `expires_at` overflow.** `src/auth.rs:336` — `now_unix() + parsed.expires_in` where `expires_in: u64`. Malicious/buggy token endpoint with `u64::MAX` panics in debug, wraps in release. Use `saturating_add`.
- **[Low] L-7 — Loopback listener no timeout.** `src/auth.rs:214`. If user closes browser without completing, `mnml-msg-gmail auth` hangs forever (only Ctrl-C exits).

## mnml-msg-mandrill

- **[Low] L-8 — Whitespace-only `MANDRILL_API_KEY` passes validation.** `src/mandrill.rs:36-44`. `.filter(|s| !s.is_empty())` should be `.filter(|s| !s.trim().is_empty())` + `.trim()`. Same applies to Slack's env vars.
- **[Low] L-9 — Path traversal via Mandrill message ID.** `src/app.rs:386` writes to `$TMPDIR/mnml-msg-mandrill-{id}.txt` where `id` is server-controlled. Trust is high but a sanitizer is one line.
- **[Low] L-10 — `$PAGER` spawn (Unix-typical).** `src/app.rs:391-396`. Documented Unix model — not a "bug" but flagged.

## mnml-virt-docker

- **[Low] L-11 — `docker` args lack `--` separator.** `src/docker.rs:117,174,195,233,269,293,297,301,305,309,313`. A container name or `compose_file` config value starting with `-` is parsed as a flag.
- **[Low] L-12 — Mutex unwraps in `src/blit.rs:53,233`** (same shape as tracker-jira L-2).
- **[Tracking] `inspect()` returns full raw JSON uncapped.** `src/docker.rs:125-131`. Probably fine; docker output rarely >100KB.

---

## Cross-cutting

- **Blocking HTTP** (M-3) — 4 of 5 scaffolded apps share the pattern. Recommended: spawn a `JoinHandle`, drain in `tick()`.
- **Token-file format inconsistency** — jira = raw text, teams/gmail = JSON, slack/mandrill = env var.
- **Whitespace-trim missing** on every env-based auth (slack, mandrill).

---

## Suggested follow-up priority

1. mnml-msg-gmail: OAuth `state` parameter (M-6)
2. mnml-tracker-jira: escape `"` in JQL string-literals (M-1)
3. mnml-tracker-jira: paginate `search` past 100 issues (M-2)
4. Family: move blocking HTTP off UI thread (M-3)
5. mnml-msg-teams: URL-encode Graph ID path segments (M-4)
6. mnml-msg-teams: poison-tolerant RwLock pattern (M-5)
7. Family: trim whitespace from env-var tokens (L-8)
8. mnml-virt-docker: insert `--` before user-controlled args (L-11)
