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
    pub fn maybe_refresh_ai_usage(&mut self) {
        const REFRESH_INTERVAL_SECS: u64 = 5 * 60;
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
            if now.saturating_sub(last) < REFRESH_INTERVAL_SECS {
                continue;
            }
            self.ai_usage_claude_last_refresh_at
                .insert(account.name.clone(), now);
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
                        });
                    existing.is_active = is_active;
                    if let Some(secs) = e.retry_after_secs {
                        existing.usage.retry_after_at = now_ts.saturating_add(secs);
                    }
                    existing.usage.last_error = Some(e.message);
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
