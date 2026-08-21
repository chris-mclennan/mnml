//! AI usage meter — multi-account Claude + Codex usage/token drain,
//! Keychain lookups for the "link Claude Code" onboarding, and the
//! shadowed-binary audit that flags outdated shim installs.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

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
            let rx = crate::ai_usage::spawn_claude_fetch_account(
                account.name.clone(),
                account.resolved_token_path(),
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
        // Prefer whatever the config currently marks active. Fall
        // back to the first entry so a snapshot exists even if the
        // config was edited between fetch + render.
        let active_name: Option<String> = self
            .config
            .claude_accounts()
            .into_iter()
            .find(|a| a.active)
            .map(|a| a.name);
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
        let active_names: std::collections::HashSet<String> = self
            .config
            .claude_accounts()
            .into_iter()
            .filter(|a| a.active)
            .map(|a| a.name)
            .collect();
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
                    // Preserve any prior snapshot for this account so
                    // resets_at / weekly_resets_at survive a transient
                    // failure; overwrite percents to zero so the chip
                    // color reflects "no fresh data" and the pane's
                    // empty-state kicks in.
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
                    existing.usage.percent = 0;
                    existing.usage.weekly_percent = 0;
                    existing.usage.scoped_limits.clear();
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

    /// `:ai.link_claude_token` — open a prompt for the user to
    /// paste their Claude Code OAuth token. Accepting writes to
    /// `~/.config/mnml/ai_token` (chmod 600) + kicks a fresh fetch.
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

    /// Drain worker replies from any pending launcher-install
    /// fetches. Called each tick. Successful installs refresh the
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
