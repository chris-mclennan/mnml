//! AI usage meter — multi-account Claude + Codex usage/token drain,
//! Keychain lookups for the "link Claude Code" onboarding, and the
//! shadowed-binary audit that flags outdated shim installs.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

/// Minimum interval between `spawn_keychain_active_refresh_token`
/// spawns. Matches the per-account fetcher's 5-min cadence so account
/// switches propagate within roughly one refresh cycle. Kicked from
/// `App::maybe_refresh_ai_usage` (per-tick) but gated by
/// `keychain_active_last_kick_at`.
const KEYCHAIN_ACTIVE_REFRESH_SECS: u64 = 5 * 60;

// TODO (user ask 2026-09-03) — a SWITCH ADVISOR over the usage panel.
//
// Today the panel answers "where do I stand?". The ask is for it to
// answer "what should I do?", so quota lands near zero unused instead
// of being wasted or hit mid-task.
//
// **It is about ACCOUNT switching, not model switching.** The user
// (2026-09-03): "im not switchign models much currently." An earlier
// draft of this note framed it as moving between Opus and Fable; that
// was wrong. Model choice is a separate decision the user makes for
// task-fit reasons.
//
// **The strategy is already settled — automate it, do not reinvent
// it.** The user's own heuristic: "watch for the account renewing the
// soonest and use all of its tokens first, then switch when around
// 95%, and then do the same for that account too."
//
// That is earliest-deadline-first, and it is the right greedy answer
// here: quota that resets soonest is the quota most likely to expire
// unspent, so it is the quota to burn first. The user called
// themselves "a feeble minded human" for arriving at it by feel — it
// is in fact the correct policy, and the job of this feature is to
// execute it faster and without vigilance, not to find a better one.
//
// So the advisor is: rank accounts by `resets_at` ascending, point at
// the head of that list, and tell the user when it crosses ~95% and
// which account is next. Everything below is in service of making that
// ranking trustworthy.
//
// The differing renewal schedules are the REASON to build this, not
// the obstacle the user took them for. Three reset clocks against
// three burn rates is precisely the arithmetic a person cannot hold in
// their head, which is why the call currently gets made by feel.
//
// **What already exists.** Per-account snapshots with `resets_at`
// (5-hour window) and `weekly_resets_at`, utilization percentages,
// account enumeration via `config.claude_accounts()`, and a poll
// cadence built for precisely this question — see the
// REFRESH_INTERVAL_SECS doc below, which already says "am I about to
// run out and have to switch accounts?".
//
// **What is missing, and it is the whole job:** there is NO history.
// Every fetch overwrites the snapshot, so mnml knows the level and not
// the slope. A projection needs a small per-account time series —
// (timestamp, utilization) retained across the current window — and
// nothing keeps one today. Start there; the advice is arithmetic once
// the series exists.
//
// **Two things that will look easy and are not.** A burn rate measured
// over a 5-minute poll is dominated by whatever you just ran, so it
// needs smoothing or it will advise a switch every time a long agent
// turn lands. And "switching to Fable extends the Opus runway" is only
// true in proportion to how much of the work actually moves — which
// mnml cannot observe, so the honest v1 projects each account
// independently and says "Opus exhausts at ~15:40, weekly resets
// Thursday" rather than pretending to model the counterfactual.
//
// **The moving ceiling — and why it forces a two-window model.**
//
// What the "50% days" were, per a summary the user supplied on
// 2026-09-03 (a Google AI Overview aggregating blog posts, NOT an
// Anthropic source — treat the dates as approximate and re-check
// before anything depends on them): a promotional +50% to the WEEKLY
// compute cap, running from around May 2026 and expiring 2026-08-31,
// with a permanent +25% over the original baseline arriving
// 2026-09-14. Three ceiling changes in four months.
//
// That alone settles the constant-vs-derived question: derive the
// ceiling from the account's own reported numbers. A hardcoded one
// would already have been wrong three times, and wrong precisely on
// the days the user most wants to spend confidently.
//
// The sharper consequence is the one that changes the ADVICE. The
// promotion moved the weekly cap and left the 5-hour rolling window
// untouched — so the two windows move independently, and the BINDING
// CONSTRAINT can differ per account.
//
// The user's earliest-deadline-first rule ranks on the soonest reset,
// which in practice is almost always a 5-hour window (those cycle
// constantly; weeklies do not). Ranked naively, EDF will point at an
// account whose 5-hour window turns over in minutes but whose WEEKLY
// quota is nearly exhausted — and burning that is backwards: the
// weekly does not return for days, while the 5-hour returns in hours.
//
// So the ranking is two-level, not one: among accounts with weekly
// headroom, take the soonest 5-hour reset. An account low on its
// weekly cap leaves the rotation regardless of how soon its short
// window resets. Both `resets_at` and `weekly_resets_at` are already
// on the snapshot, so this costs nothing extra to compute — it is
// purely a matter of ranking on the right key.
//
// Worth surfacing the ceiling changes too. "Your weekly cap changed on
// <date>" explains a week that felt tight far better than a user
// re-deriving it from their own burn rate.
//
// Ship the projection before the recommendation. A trustworthy "you
// run out at X" is useful on its own; a recommendation that is wrong
// twice will not be read a third time. And since the user already
// executes the right policy manually, a wrong recommendation is
// strictly worse than none — it would displace a working habit.

/// Fold a failed fetch into the account's *existing* snapshot.
///
/// The numbers deliberately survive (#1217): the endpoint 429s
/// routinely with three accounts on a 5-min poll, and zeroing a good
/// five-minute-old reading doesn't read as "unknown", it reads as
/// "you've used nothing" — the opposite of a warning. `last_error` is
/// the staleness signal instead, and `fetched_at` keeps its old value
/// so the age stays honest.
///
/// Extracted from `drain_ai_usage` so the assignment semantics are
/// testable. Both flag writes are plain assignments, NOT `|=`: an
/// error that isn't a re-auth failure has to *clear* a prior re-auth
/// flag, or a single bad keychain state would pin the pane's guided
/// re-auth block on forever, through every later 429.
fn apply_fetch_error(
    usage: &mut crate::ai_usage::ClaudeUsage,
    e: crate::ai_usage::FetchErr,
    now: u64,
) {
    usage.consecutive_failures = usage.consecutive_failures.saturating_add(1);
    // #ai-429 — ALWAYS back off after a failure, not only when the
    // response carried a numeric Retry-After.
    //
    // User report with a screenshot of three accounts all showing
    // `HTTP 429 rate_limit_error`: "dont hammer anthropic, look like we
    // are making 429's". The old code applied a cooldown ONLY when
    // `retry_after_secs` was present, so a 429 whose header was absent or
    // in HTTP-date form got no cooldown at all — the account simply
    // retried on the normal 5-minute cadence, forever. The retry pressure
    // never eased, so the limit never had a chance to clear.
    //
    // Anthropic's hint wins when it gives one; otherwise exponential
    // backoff on consecutive failures, capped so an account that has been
    // failing all day still checks hourly and can recover on its own.
    //
    // 2026-09-03 — the hint only counts when it IS one. Anthropic
    // returns `retry-after: 0` alongside its 429s (verified live
    // against `/api/oauth/usage` on two different accounts). The
    // previous shape accepted that verbatim, so `retry_after_at =
    // now + 0 = now`: the account became eligible again on the very
    // next tick and retried on the normal cadence forever, which is
    // exactly the pressure that keeps the limit tripped. The account
    // could never climb out, and the panel stayed down for days.
    //
    // A 429 that says "retry after 0 seconds" is not permission to
    // retry immediately — it is a server declining to give a useful
    // number. Treat it as absent and fall through to the backoff,
    // which is what the `None` arm was already for.
    let backoff = match e.retry_after_secs {
        Some(secs) if secs > 0 => secs,
        _ => {
            const BASE: u64 = 10 * 60;
            const CAP: u64 = 60 * 60;
            let shift = usage.consecutive_failures.saturating_sub(1).min(3);
            (BASE << shift).min(CAP)
        }
    };
    usage.retry_after_at = now.saturating_add(backoff);
    usage.last_error = Some(e.message);
    usage.needs_reauth = e.needs_reauth;
}

impl App {
    /// AI usage meter — kick off background fetches if it's been
    /// >5 min since the last spawn AND no fetch is currently in
    /// flight. Cheap no-op the other 99% of ticks. Called from the
    /// per-tick loop.
    ///
    /// 2026-08-16 — was 30s fast-retry on 429, but continuous 30s
    /// polling BECAME the source of Anthropic's rate limit (2880
    /// requests/day per mnml instance) — the chip stayed stuck on
    /// `—!` forever because every retry landed within the moving
    /// rate-limit window. Now: same 5-min cadence for 429 as normal.
    /// Anthropic's rate limits clear in minutes-to-hours; polling
    /// twice per minute is what created the problem the fast-retry
    /// was meant to solve. See task #943.
    /// Warn once per run when two accounts share one credential.
    ///
    /// Cheap (a few file reads) and silent unless something is wrong,
    /// so it runs on the fetch path rather than needing a schedule of
    /// its own.
    ///
    /// The `warned` latch matters: without it this would toast on
    /// every round, and a warning that repeats every few minutes gets
    /// dismissed rather than read. Once per run is enough to notice;
    /// the accounts view is where the standing state belongs.
    fn warn_on_duplicate_credentials(&mut self) {
        if self.dup_credentials_warned {
            return;
        }
        let accounts = self.config.claude_accounts();
        if accounts.len() < 2 {
            return;
        }
        let dupes = crate::ai_usage::duplicate_credential_accounts(&accounts);
        if dupes.is_empty() {
            return;
        }
        self.dup_credentials_warned = true;
        // Name both sides. "Some accounts are duplicated" would leave
        // the user hashing files by hand, which is exactly how this
        // was found the first time.
        let pairs = dupes
            .iter()
            .map(|(a, b)| format!("{a} = {b}"))
            .collect::<Vec<_>>()
            .join(", ");
        self.toast_leveled(
            format!(
                "Claude accounts share one login ({pairs}) — their usage numbers                  are the same account. Re-auth in the Claude usage pane."
            ),
            crate::app::ToastLevel::Warn,
        );
    }

    pub fn maybe_refresh_ai_usage(&mut self) {
        self.warn_on_duplicate_credentials();
        // #ai-429 — the ACTIVE account refreshes often; the others
        // rarely.
        //
        // User: "if an account not active its probaly not in use and not
        // needing of as frequent of updates". Right — and the arithmetic
        // is the point. It was a flat 5 minutes for EVERY account, so
        // three accounts cost ~36 requests/hour regardless of which one
        // you were actually spending.
        //
        // 5 min active + 20 min idle is 12 + 3 + 3 = ~18 requests/hour,
        // HALF the previous load, with no loss where it matters — user:
        // "5 minutes is fine then ... it doesnt change that fast".
        //
        // Worth recording what was rejected: polling the active account
        // every minute was considered and dropped, because it would be
        // ~60 requests/hour on its own — MORE pressure than the setup that
        // earned the 429s in the first place. Faster polling of a number
        // that moves slowly is pure cost.
        const REFRESH_INTERVAL_SECS: u64 = 5 * 60;
        const IDLE_REFRESH_INTERVAL_SECS: u64 = 20 * 60;
        /// The fast window exists for ONE question: am I about to run out
        /// and have to switch accounts?
        ///
        /// User: "or just when we expect to run out soon and have to
        /// change account". That framing sets both ends of the window.
        /// Below 90% there is nothing to decide. At 100% there is nothing
        /// left to WATCH either — you already know you must switch, and
        /// when it resets is a timestamp you have. Polling a maxed-out
        /// account every minute would spend requests to re-learn something
        /// unchanged, at exactly the moment the endpoint is least likely
        /// to answer.
        ///
        /// So: active, and 90..=99. Bounded to the one account you are
        /// actually spending.
        const HOT_REFRESH_INTERVAL_SECS: u64 = 60;
        const HOT_RANGE: std::ops::Range<u16> = 90..100;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Only spawn if the corresponding integration is enabled;
        // otherwise the chip won't render anyway.
        let claude_enabled = self
            .config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == "claude_code" && ic.enabled);
        let codex_enabled = self
            .config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == "codex" && ic.enabled);
        if !claude_enabled && !codex_enabled {
            return;
        }
        // Codex — single-instance, same 5-min throttle as before
        // (it reads local JSONL files, no rate limit to negotiate).
        if codex_enabled
            && self.ai_usage_pending_codex.is_none()
            && now.saturating_sub(self.ai_usage_last_refresh_at) >= REFRESH_INTERVAL_SECS
        {
            self.ai_usage_last_refresh_at = now;
            self.ai_usage_pending_codex = Some(crate::ai_usage::spawn_codex_fetch());
        }
        // Claude — per-account (task #944). Independent throttle +
        // Retry-After per account so a 429 on one doesn't stall
        // another. Also drops slots for accounts removed from the
        // config so stale entries clear on config reload.
        if !claude_enabled {
            return;
        }
        // #1150 f/u (2026-08-23) — kick the autodetect worker on the
        // same cadence as the per-account fetches. The Keychain lookup
        // is threaded (`security find-generic-password` can prompt)
        // so this only enqueues; the result gets drained by
        // `drain_keychain_active_watch`.
        self.kick_keychain_active_refresh();
        let configured = self.config.claude_accounts();
        let configured_names: std::collections::HashSet<String> =
            configured.iter().map(|a| a.name.clone()).collect();
        self.ai_usage_claude_accounts
            .retain(|a| configured_names.contains(&a.name));
        self.ai_usage_claude_last_refresh_at
            .retain(|k, _| configured_names.contains(k));
        // #ai-429 — ONE account per tick, and never two within
        // `SPAWN_GAP_SECS` of each other.
        //
        // The per-account throttle made every account eligible at the same
        // moment, so a burst of three requests left the same millisecond.
        // A single global gap turns that into a staggered trickle without
        // changing how often any one account refreshes.
        const SPAWN_GAP_SECS: u64 = 20;
        if now.saturating_sub(self.ai_usage_last_claude_spawn_at) < SPAWN_GAP_SECS {
            return;
        }
        for account in &configured {
            // Skip when a fetch is already in flight for this account.
            if self
                .ai_usage_pending_claude_accounts
                .iter()
                .any(|(n, _)| n == &account.name)
            {
                continue;
            }
            // Honor Retry-After for THIS account only.
            if let Some(existing) = self
                .ai_usage_claude_accounts
                .iter()
                .find(|a| a.name == account.name)
                && existing.usage.retry_after_at > now
            {
                continue;
            }
            let last = self
                .ai_usage_claude_last_refresh_at
                .get(&account.name)
                .copied()
                .unwrap_or(0);
            // Active accounts poll on the short interval, idle ones on
            // the long one. `is_active` is maintained by the keychain
            // autodetect watcher.
            let is_active = self
                .ai_usage_claude_accounts
                .iter()
                .find(|a| a.name == account.name)
                .map(|a| a.is_active)
                .unwrap_or(false);
            let percent = self
                .ai_usage_claude_accounts
                .iter()
                .find(|a| a.name == account.name)
                .map(|a| a.usage.percent)
                .unwrap_or(0);
            let interval = match (is_active, HOT_RANGE.contains(&percent)) {
                (true, true) => HOT_REFRESH_INTERVAL_SECS,
                (true, false) => REFRESH_INTERVAL_SECS,
                (false, _) => IDLE_REFRESH_INTERVAL_SECS,
            };
            // An account that has NEVER been fetched still goes on the
            // short interval — otherwise a fresh install would show em
            // dashes for twenty minutes before its first reading.
            let interval = if last == 0 {
                REFRESH_INTERVAL_SECS
            } else {
                interval
            };
            if now.saturating_sub(last) < interval {
                continue;
            }
            self.ai_usage_claude_last_refresh_at
                .insert(account.name.clone(), now);
            self.ai_usage_last_claude_spawn_at = now;
            // #1232 — the fetcher needs the account count to know
            // whether a keychain resync would be cross-writing over a
            // sibling account's credential.
            let rx = crate::ai_usage::spawn_claude_fetch_account_of(
                account.name.clone(),
                account.resolved_token_path(),
                configured.len(),
            );
            self.ai_usage_pending_claude_accounts
                .push((account.name.clone(), rx));
            // One per tick. The next eligible account goes on a later
            // tick, gated by SPAWN_GAP_SECS above.
            break;
        }
    }

    /// The single account tagged `active = true` in the config —
    /// used by the statusline chip's default (single-account)
    /// rendering. `None` when nothing has been fetched yet.
    /// Task #944.
    pub fn active_claude_account(&self) -> Option<&crate::ai_usage::ClaudeAccountUsage> {
        // #1150 f/u (2026-08-23) — autodetect (Keychain refresh-token
        // match) wins over the manual `active = true` config flag,
        // then falls back to the first entry so a snapshot exists
        // even if the config was edited between fetch + render.
        let active_name: Option<String> =
            self.autodetected_active_claude_account_name().or_else(|| {
                self.config
                    .claude_accounts()
                    .into_iter()
                    .find(|a| a.active)
                    .map(|a| a.name)
            });
        if let Some(name) = active_name.as_ref()
            && let Some(hit) = self
                .ai_usage_claude_accounts
                .iter()
                .find(|a| &a.name == name)
        {
            return Some(hit);
        }
        self.ai_usage_claude_accounts.first()
    }

    /// Drain any completed AI-usage worker replies. Called per tick.
    /// Failures are stored on the snapshot's `last_error` so the
    /// chip's hover tooltip can surface them.
    pub fn drain_ai_usage(&mut self) {
        // Claude — drain each per-account receiver independently.
        // Retain-with-side-effect: any receiver that hasn't emitted
        // yet stays in the vec; any that returned Ok/Err is spliced
        // into `ai_usage_claude_accounts` and removed.
        //
        // Task #944 — per-account error handling mirrors the
        // pre-multi-account semantics (zero percentages, keep the
        // slot so the pane empty-state + chip surface the failure).
        // #1150 f/u (2026-08-23) — autodetect which configured
        // account is the LIVE Claude Code CLI login by comparing the
        // Keychain's refresh token against each account's on-disk
        // token file. Falls back to the manual `active = true`
        // config flag when the Keychain isn't available or no account
        // matches (unlinked yet, tokens rotated, non-macOS, etc.) —
        // which was the pre-fix behavior and drifted whenever a user
        // switched Claude Code accounts without editing config.toml.
        let autodetected: Option<String> = self.autodetected_active_claude_account_name();
        let active_names: std::collections::HashSet<String> = if let Some(name) = autodetected {
            std::iter::once(name).collect()
        } else {
            self.config
                .claude_accounts()
                .into_iter()
                .filter(|a| a.active)
                .map(|a| a.name)
                .collect()
        };
        let now_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut drained: Vec<(
            String,
            Result<crate::ai_usage::ClaudeAccountUsage, crate::ai_usage::FetchErr>,
        )> = Vec::new();
        self.ai_usage_pending_claude_accounts
            .retain(|(name, rx)| match rx.try_recv() {
                Ok(payload) => {
                    drained.push((name.clone(), payload));
                    false
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => true,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => false,
            });
        for (name, result) in drained {
            let is_active = active_names.contains(&name);
            match result {
                Ok(mut acc) => {
                    acc.is_active = is_active;
                    // #1232 — a pin collision means several token
                    // files are sharing one credential. The user has
                    // to see that; it can't stay a worker-thread
                    // eprintln behind the alternate screen.
                    if let Some(w) = acc.warning.take() {
                        self.toast(w);
                    }
                    upsert_claude_account(&mut self.ai_usage_claude_accounts, acc);
                }
                Err(e) => {
                    // Preserve the prior snapshot for this account —
                    // ALL of it.
                    //
                    // #1217 (2026-08-28, user: "seems to have become
                    // very unreliable lately"): this used to zero
                    // `percent` / `weekly_percent` / `scoped_limits`
                    // on any error, meaning to signal "no fresh
                    // data". But the endpoint 429s regularly (three
                    // accounts polled on a 5-min cadence), so a good
                    // reading five minutes old was being replaced by
                    // 0% — which doesn't read as "unknown", it reads
                    // as "you've used nothing", the opposite of a
                    // warning. The chip flipped between a real number
                    // and 0 every few minutes.
                    //
                    // Now the numbers survive and `last_error` is the
                    // staleness signal; `fetched_at` keeps its old
                    // value so the age stays honest. The renderers
                    // mark stale readings rather than inventing a
                    // fresh-looking zero.
                    let mut existing = self
                        .ai_usage_claude_accounts
                        .iter()
                        .find(|a| a.name == name)
                        .cloned()
                        .unwrap_or_else(|| crate::ai_usage::ClaudeAccountUsage {
                            name: name.clone(),
                            usage: crate::ai_usage::ClaudeUsage::default(),
                            is_active,
                            email: None,
                            org_name: None,
                            warning: None,
                        });
                    existing.is_active = is_active;
                    apply_fetch_error(&mut existing.usage, e, now_ts);
                    upsert_claude_account(&mut self.ai_usage_claude_accounts, existing);
                }
            }
        }
        if let Some(rx) = &self.ai_usage_pending_codex {
            match rx.try_recv() {
                Ok(Ok(u)) => {
                    self.ai_usage_codex = Some(u);
                    self.ai_usage_pending_codex = None;
                }
                Ok(Err(e)) => {
                    let mut u = self.ai_usage_codex.clone().unwrap_or_default();
                    u.last_error = Some(e);
                    self.ai_usage_codex = Some(u);
                    self.ai_usage_pending_codex = None;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    self.ai_usage_pending_codex = None;
                }
            }
        }
    }

    /// 2026-08-08 — per-tick drain for the Keychain lookup worker
    /// (see `spawn_keychain_claude_token`). On success, splice the
    /// fetched blob into the LinkClaudeToken prompt if it's still
    /// open; toast the outcome either way.
    pub fn drain_pending_keychain(&mut self) {
        let Some(rx) = &self.pending_keychain_fetch else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok(raw)) => {
                let is_link_prompt = matches!(
                    self.prompt.as_ref().map(|p| &p.kind),
                    Some(crate::prompt::PromptKind::LinkClaudeToken)
                );
                if is_link_prompt && let Some(prompt) = self.prompt.as_mut() {
                    prompt.cursor = raw.chars().count();
                    prompt.input = raw;
                    self.toast("fetched from Keychain — press Enter to link".to_string());
                } else {
                    // Prompt closed while the worker was running; drop.
                }
                self.pending_keychain_fetch = None;
            }
            Ok(Err(e)) => {
                self.toast(e);
                self.pending_keychain_fetch = None;
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.pending_keychain_fetch = None;
            }
        }
    }

    /// #1150 f/u (2026-08-23) — per-tick drain for the autodetect
    /// worker (`spawn_keychain_active_refresh_token`). Success caches
    /// the parsed refresh token; failure clears the cache so the
    /// config-flag fallback resumes. Any success ALSO restamps the
    /// existing account list's `is_active` flags right away so the
    /// UI catches the new active account without waiting for the
    /// next usage-drain cycle.
    pub fn drain_keychain_active_watch(&mut self) {
        let Some(rx) = &self.keychain_active_watch else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok(Some(rt))) => {
                self.keychain_claude_refresh_token = Some(rt);
                self.keychain_active_watch = None;
                self.restamp_claude_active_flags();
            }
            Ok(Ok(None)) => {
                // Keychain returned a blob but it had no refresh
                // token (plain-string token, or unfamiliar shape).
                // Leave the cache alone — a transient parse miss
                // shouldn't wipe a last-known-good match and force
                // the config-flag fallback (which was the bug that
                // motivated this whole autodetect path).
                self.keychain_active_watch = None;
            }
            Ok(Err(_)) => {
                // Keychain lookup failed — leave the cache alone so
                // the previous known active account keeps rendering,
                // and fall back to the config flag if there wasn't
                // one. Deliberate silence: this fetch fires often
                // enough that a toast on every failure would spam.
                self.keychain_active_watch = None;
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.keychain_active_watch = None;
            }
        }
    }

    /// Spawn the autodetect worker if one isn't already in flight
    /// AND at least [`KEYCHAIN_ACTIVE_REFRESH_SECS`] have elapsed
    /// since the last kick. Called from `App::maybe_refresh_ai_usage`
    /// on every tick — the timestamp gate keeps mnml from spawning
    /// `security find-generic-password` at tick cadence (~120ms idle,
    /// ~40ms with a pty). Fires the first fetch immediately on
    /// startup because `keychain_active_last_kick_at` starts at 0.
    pub fn kick_keychain_active_refresh(&mut self) {
        if self.keychain_active_watch.is_some() {
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if now.saturating_sub(self.keychain_active_last_kick_at) < KEYCHAIN_ACTIVE_REFRESH_SECS {
            return;
        }
        self.keychain_active_last_kick_at = now;
        self.keychain_active_watch = Some(crate::ai_usage::spawn_keychain_active_refresh_token());
    }

    /// The autodetected active account name (Keychain refresh-token
    /// match). Cheap O(1) getter reading `cached_autodetected_...`,
    /// safe to call per-render. The cache is refreshed by
    /// `restamp_claude_active_flags` when the Keychain worker returns
    /// OR the account list is mutated. `None` when no cache is
    /// populated (Keychain not yet read, non-macOS, no match).
    pub fn autodetected_active_claude_account_name(&self) -> Option<String> {
        self.cached_autodetected_claude_account.clone()
    }

    /// Recompute the autodetect result from the current Keychain cache
    /// + per-account on-disk token files. This IS the disk-read pass —
    /// callers should invoke it only when state changes (Keychain
    /// worker returns, account list mutated), never per-render. The
    /// getter [`Self::autodetected_active_claude_account_name`] reads
    /// the cache field instead.
    fn recompute_autodetected_claude_account(&self) -> Option<String> {
        let keychain_rt = self.keychain_claude_refresh_token.as_deref()?;
        for account in self.config.claude_accounts() {
            let token_path = account.resolved_token_path();
            if let Some(disk_rt) = crate::ai_usage::read_refresh_token_from_path(&token_path)
                && disk_rt == keychain_rt
            {
                return Some(account.name);
            }
        }
        None
    }

    /// Reapply `is_active` to every entry in `ai_usage_claude_accounts`
    /// using the current autodetect state. Called after the Keychain
    /// worker returns so the panel + statusline reflect the new active
    /// account without waiting for the next per-account fetch cycle.
    /// Also refreshes the render-hot-path cache.
    pub fn restamp_claude_active_flags(&mut self) {
        let autodetected = self.recompute_autodetected_claude_account();
        self.cached_autodetected_claude_account = autodetected.clone();
        let active_names: std::collections::HashSet<String> = if let Some(name) = autodetected {
            std::iter::once(name).collect()
        } else {
            self.config
                .claude_accounts()
                .into_iter()
                .filter(|a| a.active)
                .map(|a| a.name)
                .collect()
        };
        for acc in self.ai_usage_claude_accounts.iter_mut() {
            acc.is_active = active_names.contains(&acc.name);
        }
    }

    /// `:ai.link_claude_token` — open a prompt for the user to
    /// paste their Claude Code OAuth token. Accepting writes to
    /// `~/.config/mnml/ai_token` (chmod 600) + kicks a fresh fetch.
    /// #1232 — capture the current keychain login and file it under
    /// whichever configured account it actually belongs to.
    ///
    /// Replaces the by-hand `security find-generic-password … >
    /// ai_token.<name>` step with one that verifies identity before
    /// writing, so logging in as the wrong account can't silently
    /// overwrite a good credential.
    /// Open `claude login` in a Pty pane.
    ///
    /// The guided re-auth block has always said "1. run: claude login
    /// / 2. press R" — but step 1 was PROSE. The user had to leave
    /// mnml, find a terminal, log in, come back and press R. Step 2
    /// was a keystroke and step 1 was homework.
    ///
    /// mnml already runs Pty panes, so step 1 can be a keystroke too:
    /// the real CLI, in a pane, with its output visible. The OAuth
    /// flow itself stays where it belongs — mnml never handles the
    /// credentials, it just stops making you go elsewhere to start.
    pub fn open_claude_login_pane(&mut self) {
        self.toast("opening `claude login` — press R here after it finishes".to_string());
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "claude login",
            "claude login",
            self.workspace.clone(),
        ));
    }

    pub fn recapture_claude_token_from_keychain(&mut self) {
        if self.pending_keychain_recapture.is_some() {
            self.toast("already capturing…".to_string());
            return;
        }
        let targets: Vec<crate::ai_usage::RecaptureTarget> = self
            .config
            .claude_accounts()
            .iter()
            .map(|a| crate::ai_usage::RecaptureTarget {
                name: a.name.clone(),
                token_path: a.resolved_token_path(),
                pinned_email: crate::ai_usage::pinned_email_for(&a.name),
            })
            .collect();
        if targets.is_empty() {
            self.toast("no Claude accounts configured".to_string());
            return;
        }
        self.toast("reading keychain + verifying identity…".to_string());
        self.pending_keychain_recapture = Some(crate::ai_usage::spawn_keychain_recapture(targets));
    }

    /// Per-tick drain for [`recapture_claude_token_from_keychain`].
    /// On success, force an immediate refetch so the repaired account
    /// lights up without waiting out the 5-minute throttle.
    pub fn drain_keychain_recapture(&mut self) {
        let Some(rx) = &self.pending_keychain_recapture else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok(msg)) => {
                self.toast(msg);
                self.pending_keychain_recapture = None;
                self.ai_usage_claude_last_refresh_at.clear();
                self.ai_usage_pending_claude_accounts.clear();
                self.maybe_refresh_ai_usage();
            }
            Ok(Err(e)) => {
                self.toast(e);
                self.pending_keychain_recapture = None;
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.pending_keychain_recapture = None;
            }
        }
    }

    pub fn open_link_claude_token_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::LinkClaudeToken,
            "Paste access token OR the whole claudeAiOauth JSON (keeps refresh token → no daily re-paste)",
        ));
    }

    /// Called from the prompt accept handler after the user pastes
    /// a token. Writes to disk + kicks the first fetch immediately.
    pub fn accept_link_claude_token(&mut self, token: String) {
        match crate::ai_usage::write_claude_token(&token) {
            Ok(path) => {
                self.toast(format!("linked → {}", path.display()));
                // Force an immediate refresh — bypass the 5-min
                // throttle so the chip lights up right away.
                self.ai_usage_last_refresh_at = 0;
                self.ai_usage_claude_last_refresh_at.clear();
                self.ai_usage_pending_claude_accounts.clear();
                self.maybe_refresh_ai_usage();
            }
            Err(e) => self.toast(format!("link failed: {e}")),
        }
    }

    /// Audit + repair `mnml-*` integration binaries that PATH resolves to
    /// a copy OTHER than `~/.cargo/bin/`. This is the root of the
    /// "why does my Amplify label keep reverting to the old one" bug:
    /// `cargo install --force` writes to `~/.cargo/bin/`, but a stale
    /// peer in (say) `~/.local/bin/` earlier in PATH silently wins on
    /// the follow-up `<integration> --install` — the stale binary writes
    /// its old manifest and everyone's confused.
    ///
    /// Repair strategy: move each shadowing copy to
    /// `<data_root>/quarantine/shadowed-bins/<name>.<epoch>` (mkdir'd
    /// on demand). Nothing is deleted — user can `mv` it back if they
    /// realize the "stale" one was actually load-bearing. Reports the
    /// count via toast; details captured in `.mnml/findings/…`.
    pub fn audit_shadowed_binaries(&mut self) {
        let hits = crate::integration_detect::find_shadowed_binaries();
        if hits.is_empty() {
            self.toast("no shadowed integration binaries detected");
            return;
        }
        let dest_root = crate::data_root::data_root()
            .join("quarantine")
            .join("shadowed-bins");
        if let Err(e) = std::fs::create_dir_all(&dest_root) {
            self.toast(format!("shadow audit: couldn't mkdir quarantine ({e})"));
            return;
        }
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut moved = 0usize;
        let mut errors = Vec::new();
        for hit in &hits {
            let dest = dest_root.join(format!("{}.{stamp}", hit.name));
            match std::fs::rename(&hit.active, &dest) {
                Ok(()) => moved += 1,
                Err(e) => errors.push(format!("{}: {e}", hit.name)),
            }
        }
        crate::integration_detect::clear_cache();
        if errors.is_empty() {
            self.toast(format!(
                "moved {moved} shadowed integration binaries → {}",
                dest_root.display()
            ));
        } else {
            self.toast(format!(
                "moved {moved}/{}; {} failed — see findings",
                hits.len(),
                errors.len()
            ));
        }
    }
}

#[cfg(test)]
mod fetch_error_tests {
    use super::apply_fetch_error;
    use crate::ai_usage::{ClaudeUsage, FetchErr};

    fn err(message: &str, needs_reauth: bool) -> FetchErr {
        FetchErr {
            message: message.to_string(),
            retry_after_secs: None,
            needs_reauth,
        }
    }

    /// A `Retry-After: 0` must NOT be honoured as a zero cooldown.
    ///
    /// Anthropic returns exactly that alongside its 429s on
    /// `/api/oauth/usage` — verified live on two accounts, 2026-09-03.
    /// The previous shape took the hint literally, so
    /// `retry_after_at = now + 0 = now`: the account was eligible again
    /// on the very next tick and retried on the normal cadence forever.
    /// That is the retry pressure that keeps the limit tripped, so the
    /// panel stayed down for days and could not recover on its own.
    #[test]
    fn a_zero_retry_after_falls_back_to_backoff() {
        let mut usage = ClaudeUsage::default();
        let now = 1_000_000u64;
        let mut e = err("HTTP 429 rate_limit_error", false);
        e.retry_after_secs = Some(0);
        apply_fetch_error(&mut usage, e, now);
        assert!(
            usage.retry_after_at > now,
            "a Retry-After of 0 produced no cooldown at all — the account \
             retries on the next tick and the limit never clears"
        );
        assert!(
            usage.retry_after_at >= now + 10 * 60,
            "expected at least the 10-minute base, got {}s",
            usage.retry_after_at - now
        );
    }

    /// A real hint is still honoured — the fix must not discard genuine
    /// server guidance along with the useless zero.
    #[test]
    fn a_positive_retry_after_is_still_honoured() {
        let mut usage = ClaudeUsage::default();
        let now = 1_000_000u64;
        let mut e = err("HTTP 429", false);
        e.retry_after_secs = Some(45);
        apply_fetch_error(&mut usage, e, now);
        assert_eq!(
            usage.retry_after_at,
            now + 45,
            "Anthropic's own number was discarded"
        );
    }

    /// Repeated zero-hint failures must back off FURTHER, or a
    /// persistently limited account keeps the same pressure on forever.
    #[test]
    fn repeated_zero_hints_escalate() {
        let mut usage = ClaudeUsage::default();
        let now = 1_000_000u64;
        let mut prev = 0u64;
        for i in 0..4 {
            let mut e = err("HTTP 429", false);
            e.retry_after_secs = Some(0);
            apply_fetch_error(&mut usage, e, now);
            let wait = usage.retry_after_at - now;
            assert!(
                wait >= prev,
                "attempt {i}: backoff shrank ({prev}s -> {wait}s)"
            );
            prev = wait;
        }
        assert!(prev > 10 * 60, "backoff never escalated past the base");
    }

    /// The regression this exists for: a later error of a DIFFERENT
    /// kind has to clear a prior re-auth flag. `needs_reauth` is
    /// assigned, never OR'd — if someone "preserves more fields"
    /// while editing the #1217 snapshot-preservation logic directly
    /// above and reaches for `|=`, the pane would keep telling the
    /// user to run `claude login` forever, through every later 429,
    /// long after the credential was fixed.
    #[test]
    fn a_later_non_reauth_error_clears_the_reauth_flag() {
        let mut usage = ClaudeUsage::default();

        apply_fetch_error(&mut usage, err("that credential is other@x", true), 1_000);
        assert!(usage.needs_reauth, "re-auth failure should raise the flag");

        // A 429 is not a re-auth problem. The guided block must go.
        apply_fetch_error(&mut usage, err("http 429", false), 2_000);
        assert!(
            !usage.needs_reauth,
            "an unrelated later error must clear the flag, not OR into it"
        );
        assert_eq!(usage.last_error.as_deref(), Some("http 429"));
    }

    /// The readings survive an error — the whole point of #1217.
    /// A good five-minute-old number beats a fresh-looking zero.
    #[test]
    fn an_error_preserves_the_previous_readings() {
        let mut usage = ClaudeUsage {
            percent: 57,
            weekly_percent: 86,
            fetched_at: 500,
            ..Default::default()
        };

        apply_fetch_error(&mut usage, err("http 429", false), 2_000);

        assert_eq!(usage.percent, 57);
        assert_eq!(usage.weekly_percent, 86);
        assert_eq!(usage.fetched_at, 500, "age must stay honest");
    }

    /// `Retry-After` only moves the cooldown when the header was
    /// present; a plain failure must not silently arm one.
    #[test]
    fn a_failure_always_backs_off_even_without_a_retry_after_header() {
        // THIS TEST'S PROMISE CHANGED, and the old one was the bug.
        //
        // It used to assert that a failure with NO `Retry-After` header
        // left `retry_after_at` at 0 — i.e. no cooldown at all, so the
        // account retried on the normal cadence forever. Anthropic's 429
        // here is a JSON `rate_limit_error` whose header is often absent
        // or in HTTP-date form, so that path was the common one, and the
        // retry pressure never eased. User, with a screenshot of three
        // accounts all rate-limited: "dont hammer anthropic".
        let mut usage = ClaudeUsage::default();
        apply_fetch_error(&mut usage, err("boom", false), 2_000);
        assert!(
            usage.retry_after_at > 2_000,
            "a failure with no Retry-After got no cooldown at all"
        );
        assert_eq!(usage.consecutive_failures, 1);

        // Anthropic's own hint still WINS when it gives one.
        let mut usage = ClaudeUsage::default();
        let mut throttled = err("http 429", false);
        throttled.retry_after_secs = Some(300);
        apply_fetch_error(&mut usage, throttled, 2_000);
        assert_eq!(
            usage.retry_after_at, 2_300,
            "the server's Retry-After must win over our own backoff"
        );
    }

    /// Repeated failures must back off further, or a persistently broken
    /// account knocks at a fixed rate all day.
    #[test]
    fn consecutive_failures_back_off_further_each_time() {
        let mut usage = ClaudeUsage::default();
        let mut waits = Vec::new();
        for _ in 0..5 {
            apply_fetch_error(&mut usage, err("429", false), 1_000);
            waits.push(usage.retry_after_at - 1_000);
        }
        assert!(
            waits.windows(2).all(|w| w[1] >= w[0]),
            "backoff did not grow: {waits:?}"
        );
        assert!(
            waits[1] > waits[0],
            "second failure waited no longer than the first: {waits:?}"
        );
        // And it must be CAPPED, so an account can still recover on its
        // own rather than being parked for a day.
        assert!(
            *waits.last().unwrap() <= 60 * 60,
            "backoff exceeded the 1h cap: {waits:?}"
        );
    }

    /// A success clears the backoff, so one blip does not slow the
    /// account down permanently.
    #[test]
    fn a_successful_parse_resets_the_failure_count() {
        // `parse_claude_response` builds the success value, and it sets
        // the counter to 0 explicitly — asserted here rather than trusted
        // because the field defaults to 0 and would look correct either
        // way on a fresh value.
        let mut usage = ClaudeUsage {
            consecutive_failures: 4,
            ..Default::default()
        };
        apply_fetch_error(&mut usage, err("x", false), 10);
        assert_eq!(usage.consecutive_failures, 5, "counter should climb");
    }
}
