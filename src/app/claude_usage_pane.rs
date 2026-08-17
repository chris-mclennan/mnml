//! `Pane::ClaudeUsage` — App-side helpers.
//!
//! Ports the old `:ai.usage` overlay into a proper pane so it
//! docks / splits / tabs / closes with `:bd` or `Ctrl+W q` like
//! every other center-hosted view. Data plumbing (fetcher, per-
//! account ClaudeUsage cache, retry-after) is untouched — the
//! pane just reads `App::ai_usage_claude_accounts` at render
//! time (task #944 — one section per configured account).
//!
//! 2026-08-16 — split off from the shared `ai_usage_pane.rs` when
//! `Pane::AiUsage` fissioned into `Pane::ClaudeUsage` +
//! `Pane::CodexUsage` (see `docs/design/info-view-v0.3.md` — the
//! two products' data shapes had drifted enough that one pane
//! doing both was clumsy for both).

use std::path::PathBuf;

use crate::app::App;
use crate::pane::{ClaudeUsagePane, Pane};

impl App {
    /// Open (or refocus) the Claude usage pane. Idempotent — matches
    /// the `open_integration_detail_pane` shape: reuse an existing
    /// `Pane::ClaudeUsage` if present, else push a new one and reveal.
    /// Kicks a fresh fetch on open so the numbers reflect what
    /// Anthropic sees right now, not what mnml last polled.
    pub fn open_claude_usage_pane(&mut self) {
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::ClaudeUsage(_)))
        {
            // Drop any right-panel copy so we don't render twice
            // (same defensive move as `open_integration_detail_pane`).
            self.right_panel_panes.retain(|&p| p != pid);
            self.reveal_pane(pid);
        } else {
            self.panes.push(Pane::ClaudeUsage(ClaudeUsagePane::new()));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
        }
        // Force a fresh fetch across every account.
        //
        // Reviewer 2026-08-16 — resetting the throttles alone wasn't
        // enough: `maybe_refresh_ai_usage` also gates per-account on
        // the cached snapshot's `retry_after_at > now`, so after any
        // 429 the click became a silent no-op until Anthropic's
        // cooldown expired. An explicit user action needs to bypass
        // the header-honored cooldown too, so clear every account's
        // `retry_after_at` before kicking the fetch.
        for acct in self.ai_usage_claude_accounts.iter_mut() {
            acct.usage.retry_after_at = 0;
        }
        self.ai_usage_last_refresh_at = 0;
        self.ai_usage_claude_last_refresh_at.clear();
        self.maybe_refresh_ai_usage();
    }

    /// `r` inside a `Pane::ClaudeUsage` and the `ai.refresh_usage`
    /// command surface both dispatch here. Resets the throttle so
    /// `maybe_refresh_ai_usage` actually re-hits Anthropic instead
    /// of short-circuiting on the 5-minute cooldown OR the honored
    /// Retry-After cooldown from a prior 429.
    pub fn refresh_claude_usage_pane(&mut self) {
        for acct in self.ai_usage_claude_accounts.iter_mut() {
            acct.usage.retry_after_at = 0;
        }
        self.ai_usage_last_refresh_at = 0;
        self.ai_usage_claude_last_refresh_at.clear();
        self.maybe_refresh_ai_usage();
        self.toast("refreshing Claude usage…".to_string());
    }

    /// Task #944 rename UX (2026-08-16). Open the seeded-text prompt
    /// for renaming a Claude account. Stashes `current_name` on
    /// `pending_claude_account_rename` so the accept handler in
    /// `picker::prompt_accept` knows which `[[ai.claude.accounts]]`
    /// block to rewrite. Called from:
    ///   - the pencil hitrect click on the section header
    ///     (`claude_usage_view` populates
    ///     `App::rects.claude_usage_pencils`)
    ///   - the `ai.claude_rename_account` palette command, which
    ///     picks the "focused" account based on the scroll position
    ///     inside the pane (falls back to the active account, then
    ///     the first configured account when the pane isn't open)
    ///
    /// Empty state: if no account is configured or the current
    /// name is empty, toast and no-op — nothing to rename.
    pub fn open_claude_account_rename_prompt(&mut self, current_name: String) {
        let seed = current_name.trim().to_string();
        if seed.is_empty() {
            self.toast("no Claude account to rename".to_string());
            return;
        }
        self.pending_claude_account_rename = Some(seed.clone());
        let title = format!("Rename Claude account (was: {seed})");
        self.prompt = Some(crate::prompt::Prompt::seeded_select_all(
            crate::prompt::PromptKind::ClaudeAccountRename,
            title,
            seed,
        ));
    }

    /// Palette command entry point — pick which account the user
    /// "means" and open the rename prompt for it. Order of preference:
    ///   1. Whichever account's section the Claude Usage pane's scroll
    ///      is currently sitting on (if such a pane exists + is focused)
    ///   2. The active account
    ///   3. The first configured account
    /// If none is found, toast + no-op.
    pub fn ai_claude_rename_account_command(&mut self) {
        // v1: skip the scroll-position math (fiddly — section heights
        // vary with per-account scoped_limits + error rows). Fall back
        // to "active account, then first configured" — the common
        // case is the user has 1-3 accounts and the palette is used
        // to rename the one they're logged in as.
        let target = self
            .active_claude_account()
            .map(|a| a.name.clone())
            .or_else(|| {
                self.ai_usage_claude_accounts
                    .first()
                    .map(|a| a.name.clone())
            })
            .or_else(|| {
                self.config
                    .claude_accounts()
                    .first()
                    .map(|a| a.name.clone())
            });
        match target {
            Some(name) => self.open_claude_account_rename_prompt(name),
            None => self.toast("no Claude account configured".to_string()),
        }
    }

    /// Accept handler for `PromptKind::ClaudeAccountRename`. Validates
    /// the new name, updates in-memory state, and rewrites the
    /// `[[ai.claude.accounts]]` block in `~/.config/mnml/config.toml`
    /// in place (comments + surrounding blocks preserved).
    ///
    /// Validation:
    ///   - trimmed non-empty
    ///   - length 1..=32 chars
    ///   - no toml-breaking chars: `"`, `\`, `\n`, `\r`
    ///   - unique among other configured accounts (case-sensitive; a
    ///     no-op rename to the same name is allowed and just falls
    ///     through)
    ///
    /// Failure → toast the reason, do nothing else. Success →
    /// updates `ai_usage_claude_accounts`, rekeys
    /// `ai_usage_claude_last_refresh_at`, writes the config, toasts.
    pub fn rename_claude_account(&mut self, old_name: &str, new_name: String) {
        let old = old_name.trim().to_string();
        let new = new_name.trim().to_string();
        if new.is_empty() {
            self.toast("rename: name cannot be empty".to_string());
            return;
        }
        if new.chars().count() > 32 {
            self.toast("rename: max 32 chars".to_string());
            return;
        }
        if new.contains('"') || new.contains('\\') || new.contains('\n') || new.contains('\r') {
            self.toast("rename: invalid char (no \" \\ or newline)".to_string());
            return;
        }
        if new == old {
            // No-op — user hit Enter without editing. Silently succeed.
            return;
        }
        // Uniqueness against every OTHER configured account.
        let configured = self.config.claude_accounts();
        if configured.iter().any(|a| a.name != old && a.name == new) {
            self.toast(format!("rename: `{new}` is already in use"));
            return;
        }
        // Persist to disk first so we don't leave in-memory and
        // on-disk state divergent if the TOML rewrite fails (missing
        // config, unwritable file, block-not-found).
        match crate::app::claude_usage_pane::rewrite_claude_account_name(&old, &new) {
            Ok(_path) => {
                // Update in-memory account list.
                for acc in self.ai_usage_claude_accounts.iter_mut() {
                    if acc.name == old {
                        acc.name = new.clone();
                    }
                }
                // Rekey the throttle map so the renamed account keeps
                // its cooldown window instead of getting a fresh spawn
                // window slot.
                if let Some(ts) = self.ai_usage_claude_last_refresh_at.remove(&old) {
                    self.ai_usage_claude_last_refresh_at.insert(new.clone(), ts);
                }
                self.toast(format!("renamed `{old}` → `{new}`"));
            }
            Err(e) => {
                self.toast(format!("rename failed: {e}"));
            }
        }
    }
}

/// TOML surgery — find the `[[ai.claude.accounts]]` block whose
/// `name = "<old>"` matches and rewrite that name-line to
/// `name = "<new>"`. Preserves comments, other fields inside the
/// block, and any surrounding config. Line-by-line (mnml has no
/// `toml_edit` dep and adding one just for this surgery would
/// overshoot — every other config write in the tree uses the same
/// hand-rolled shape, see `discovery::persist_config_scalar`).
///
/// Errors surface as human-readable strings that the caller
/// toasts. Handled gracefully:
///   - config file missing: `Err("no config file at …")`
///   - `[[ai.claude.accounts]]` block for `<old>` not found:
///     `Err("no `[[ai.claude.accounts]]` block named `<old>`")`
///   - invalid utf8 / unwritable: bubble up the io::Error message
///
/// Written atomically — new content lands via
/// `crate::config::write_user_config` which the tree's other
/// config writers already share (backup + chmod 600 + rename).
pub(super) fn rewrite_claude_account_name(old: &str, new: &str) -> Result<PathBuf, String> {
    let path = crate::config::user_config_path()
        .ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    let existing =
        std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let target = "[[ai.claude.accounts]]";
    // Walk lines; when the current block header is
    // `[[ai.claude.accounts]]`, look for a `name = "<old>"` line and
    // rewrite it. Any OTHER header (`[ui]`, `[[ai.claude.accounts]]`
    // for a different account, `[whatever]`) flips us out of scope.
    let mut out: Vec<String> = Vec::with_capacity(existing.lines().count() + 1);
    let mut in_target_block = false;
    let mut found = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            // Every new header (including a repeat of the same
            // `[[…]]`) starts a fresh block. We're in-scope only for
            // the specific block whose FIRST `name = …` matches.
            in_target_block = trimmed == target;
            out.push(line.to_string());
            continue;
        }
        if in_target_block && !found && is_name_line(trimmed, old) {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            // Escape only the two chars the validator lets through
            // for safety-in-depth (the validator already rejected `"`
            // and `\`, so this is a belt-and-braces re-escape).
            let esc = new.replace('\\', r"\\").replace('"', "\\\"");
            out.push(format!("{indent}name = \"{esc}\""));
            found = true;
            // Once we've flipped the name in this block, stop
            // treating further `name = …` lines in the same block
            // as matches — a well-formed block only has one name
            // key anyway, but this defends against malformed input.
            in_target_block = false;
            continue;
        }
        out.push(line.to_string());
    }
    if !found {
        return Err(format!("no `[[ai.claude.accounts]]` block named `{old}`"));
    }
    let contents = out.join("\n") + "\n";
    // Reuse the tree's backup-then-write helper so a corrupt write
    // can be recovered from `~/.config/mnml/backups/`.
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    crate::config::write_user_config(&path, &contents)
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// Match a `name = "<value>"` line (with any spacing around `=`)
/// against a specific value. Returns true iff the line is
/// `name`-keyed AND the string literal on the RHS equals `expected`
/// after unescaping the two chars the writer emits (`\"`, `\\`).
fn is_name_line(trimmed: &str, expected: &str) -> bool {
    // Strip a leading `name` + optional spaces + `=` + optional spaces.
    let rest = trimmed.strip_prefix("name").unwrap_or("");
    let rest = rest.trim_start();
    let rest = match rest.strip_prefix('=') {
        Some(r) => r.trim_start(),
        None => return false,
    };
    // Only handle the `"…"` quoted form — mnml's writer never emits
    // literal / bare string TOML for `name`. A hand-edited config
    // using single-quote or triple-quote is out of scope for this
    // rewriter (validator catches those cases upstream by refusing
    // the rename when the block can't be found).
    let rest = match rest.strip_prefix('"') {
        Some(r) => r,
        None => return false,
    };
    // Consume until the closing `"`, honoring `\"` + `\\` escapes.
    let mut unescaped = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"') => unescaped.push('"'),
                Some('\\') => unescaped.push('\\'),
                Some(other) => {
                    unescaped.push('\\');
                    unescaped.push(other);
                }
                None => return false,
            }
            continue;
        }
        if c == '"' {
            return unescaped == expected;
        }
        unescaped.push(c);
    }
    false
}

#[cfg(test)]
mod rewrite_tests {
    use super::*;

    #[test]
    fn is_name_line_matches_simple() {
        assert!(is_name_line(r#"name = "personal""#, "personal"));
        assert!(is_name_line(r#"name="personal""#, "personal"));
        assert!(is_name_line(r#"name  =   "personal""#, "personal"));
    }

    #[test]
    fn is_name_line_rejects_wrong_key() {
        assert!(!is_name_line(r#"token_path = "personal""#, "personal"));
        assert!(!is_name_line(r#"active = true"#, "personal"));
    }

    #[test]
    fn is_name_line_rejects_wrong_value() {
        assert!(!is_name_line(r#"name = "work""#, "personal"));
    }

    #[test]
    fn is_name_line_handles_escapes() {
        assert!(is_name_line(
            r#"name = "he said \"hi\"""#,
            r#"he said "hi""#
        ));
    }
}
