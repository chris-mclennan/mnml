# Multi-account Claude — feasibility scoping

**Status:** design / feasibility (2026-08-07). No code yet.
**Ask:** "todo feature for multi account support with claude. scope it out
for feasibility. like a load balancer for tokens across all your accounts,
I have 3."

## What "multi-account" means here — two separate surfaces

There are **two** places Claude auth flows through mnml today, and they
have different token stores. A multi-account solution needs to pick one
(or handle both cleanly). Naming them so the rest of this doc can be
precise:

### Surface A — mnml's own AI features
- Token file: `~/.config/mnml/ai_token` (single OAuth token, chmod 600)
- Read via `src/ai_usage.rs::read_claude_token`
- Used by mnml's own suggest / rewrite / summarise API calls that hit
  `https://api.anthropic.com/...` directly
- Quota surface: `src/ai_usage.rs::ClaudeUsage { percent, weekly_percent }`
  polled from `/api/oauth/usage`
- Statusline chip: `src/ui/statusline.rs` renders ` 42%s·88%w `

### Surface B — Claude Code CLI (the app inside a `Pane::Pty`)
- Token file: `~/.claude/.credentials.json` (single-active-account, keyring
  or plain-JSON depending on OS keychain state)
- Used by the `claude` CLI itself when the user spawns a Claude Code pane
- Quota surface: same `/api/oauth/usage` endpoint, but keyed by whichever
  account the CLI is currently authed as
- Switching accounts today = `claude auth login` in a terminal (interactive
  browser OAuth), no programmatic swap

**Which one does the user care about?** Almost certainly **Surface B** —
the user's "I have 3" reads as three Claude Code plans, each with its own
weekly quota, and they want mnml to spread new Claude Code sessions across
them. This doc scopes B; Surface A is trivially additive at the end.

---

## Feasibility per surface

### Surface B (Claude Code CLI multi-account)

**Approach: three credential files + swap-before-spawn.**

The `claude` CLI only reads `~/.claude/.credentials.json` — a single file.
So the strategy is: keep the three real credential blobs under a mnml-owned
directory, and swap whichever one is "active" into place *just before* we
spawn each Claude Code Pty pane.

- Storage: `~/.config/mnml/claude-accounts/<label>.json` — chmod 600, one
  file per account. Label is user-chosen (e.g. "personal", "work",
  "shared"). Populate by having the user `claude auth login` inside a
  disposable shell → copy the resulting `~/.claude/.credentials.json`
  → move to `<label>.json`. (A future `:ai.import_claude_account
  <label>` palette command can do this in one shot.)
- Config: `~/.config/mnml/ai_accounts.toml`
  ```toml
  active = "personal"        # last-used, for the statusline chip
  strategy = "quota_aware"   # or "round_robin" or "manual"

  [[account]]
  label = "personal"
  path = "~/.config/mnml/claude-accounts/personal.json"
  weight = 1.0
  enabled = true

  [[account]]
  label = "work"
  path = "~/.config/mnml/claude-accounts/work.json"
  weight = 1.0
  enabled = true

  [[account]]
  label = "shared"
  path = "~/.config/mnml/claude-accounts/shared.json"
  weight = 0.5               # use less often — shared quota
  enabled = true
  ```
- Selection at spawn-time (`quota_aware`):
  1. Poll `/api/oauth/usage` for each enabled account (cached ~60s per
     account so we're not hammering the endpoint on every Pty spawn).
  2. Pick the account with the LOWEST `max(percent, weekly_percent)`.
  3. Ties broken by `weight` (higher wins), then by LRU (least recently
     spawned).
  4. Refuse to pick an account over ~95% weekly — surface a toast
     "all accounts at capacity, retry in Xh."
- Selection at spawn-time (`round_robin`): ignore quota, cycle through
  enabled accounts by LRU.
- Selection at spawn-time (`manual`): honour `active` from config and
  never auto-switch. Statusline chip shows a picker on click.
- Per-pane binding: each `Pane::Pty` records which account label was
  swapped in at spawn. Once bound, a pane stays on that account for
  its entire lifetime — no mid-session swap. Killing the pane frees
  the binding.
- The swap itself:
  ```rust
  fn use_account(label: &str) -> Result<()> {
      let src = accounts_dir().join(format!("{label}.json"));
      let dst = home_dir().join(".claude").join(".credentials.json");
      fs::copy(&src, &dst)?;   // atomic on most filesystems; add
                               // an .tmp-rename dance if we hit races
      Ok(())
  }
  ```
  We swap once per Pty spawn, immediately before `portable_pty::spawn`.
  The child inherits whatever's on disk at that instant. Concurrent
  spawns are rare, but the swap → spawn window is a race — mitigate by
  holding a process-wide `Mutex<()>` for the duration.

**Risks & unknowns:**

- **Anthropic ToS.** Rotating between OAuth tokens to work around
  per-account quota may or may not be within terms — worth checking
  before shipping this widely. Personal use for one user's three own
  accounts is almost certainly fine; publishing as a headline feature
  might not be.
- **Concurrent Claude Code sessions.** If two Pty panes are alive at the
  same time using different accounts, they'll each try to read
  `~/.claude/.credentials.json` on demand. That file is now bound to
  whichever spawn happened LAST. In practice Claude Code caches the
  token in memory after startup — so as long as the file is correct at
  spawn-time, the running session doesn't care what's on disk after.
  Needs verification.
- **Refresh tokens.** Claude Code refreshes its access token on expiry
  and writes back to `.credentials.json`. If we've since swapped in a
  different account's file, the refresh writes to the wrong file.
  Mitigation: after each Pty pane exits, read `.credentials.json` back
  and if it differs from the account's stored copy, update the stored
  copy. Wire this into the Pty exit hook.
- **Interactive login inside Claude Code.** `claude auth login` inside
  a running Pty session would overwrite `.credentials.json`. We don't
  need to prevent this — worst case, one account's stored file gets
  updated. Same "refresh-back" logic above handles it.

**Statusline chip changes:**

Currently: ` 42%s·88%w `.
With multi-account: ` 42%s·88%w · personal (3/3) `.
Click → dropdown listing all accounts with their live % + a manual pick.
When strategy = `quota_aware`, the label auto-updates per spawn; when
`manual`, click actually swaps.

**Rough size:** ~600 lines new code across `src/ai_accounts.rs` (new
module), `src/ai_usage.rs` (multi-account poller), `src/ui/statusline.rs`
(chip render + picker), `src/app/pty.rs` (swap-before-spawn hook),
`src/app/ai.rs` (palette commands `:ai.link_account`, `:ai.pick_account`,
`:ai.remove_account`). About 1 week of focused work.

### Surface A (mnml's own AI features)

Trivially additive on top of Surface B's account list:

- Same `ai_accounts.toml` — add an `used_for_mnml_ai = true` flag on
  each `[[account]]` block.
- `src/ai_usage.rs::fetch_claude_blocking` currently reads a single
  token. Change to: `for account in enabled_accounts_for_mnml_ai { … }`.
  Aggregate the response — pick the highest-quota account for each
  outgoing request.
- No pane-binding to worry about (mnml's API calls are stateless per
  request).

~200 additional lines. Do this in a second commit after Surface B lands.

---

## What we're NOT designing (out of scope)

- **Anthropic-billed API keys** (as opposed to Claude Code OAuth tokens).
  Those live in `ANTHROPIC_API_KEY` env var or explicit config, use a
  different auth flow, and route to different rate-limit buckets. If a
  user wants to load-balance API keys, that's a separate design.
- **Codex accounts.** The AI meter chip parses Codex quota too but Codex
  ships a single-account model. Skipping until there's an ask.
- **Cross-machine coordination.** Two mnml instances on different laptops
  both using the same three accounts would need a shared quota database.
  Punting; single-machine is the useful case.

---

## Recommended next step

Green-light Surface B with `strategy = "quota_aware"` as the default.
Two questions to resolve before implementation starts:

1. **ToS check.** User confirms this is acceptable use for their own
   three plans. (Design-critic ask — I can't answer this.)
2. **Refresh-token roundtrip.** Verify empirically that Claude Code's
   refresh flow writes back to `.credentials.json` on disk (vs. keeping
   it in memory and never persisting). One session with `strace` /
   `fs_usage` will settle it.

If both come back green, this is a ~1-week feature. If either surfaces
a blocker, revisit the design (may need a Claude Code fork or a shim
wrapper binary).
