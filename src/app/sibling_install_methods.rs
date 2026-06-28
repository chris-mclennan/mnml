//! Sibling-install + mount lifecycle methods on `App` (A-2 of the
//! file-split refactor — 2026-06-28). Owns the family-catalog install
//! flow (cargo install in a Pty pane with `PostInstallAction` callbacks),
//! the sibling-install picker, the mount manifest refresh, and
//! `App::open_mount{,_with_label}` for spawning a mnml_bridge
//! MountSession.
//!
//! Extracted from `src/app/mod.rs`. Pure non-destructive move — every
//! method keeps its signature + visibility, only the file changes.

use super::*;

impl App {
    /// Run `cargo install` for the family entry with `family_id` in
    /// a fresh Pty pane. Toasts a friendly message if the id isn't
    /// in the catalog. When the entry has a Mount stub, ALSO writes
    /// `~/.config/mnml/mounts/<id>.toml` so the activity-bar icon
    /// shows up immediately (clicking it before install completes
    /// will toast the install hint via `binary_on_path`).
    ///
    /// When called with a `post_action` (typically by
    /// `install_sibling_confirm_resolve` after the user accepted
    /// the "X not installed — install? y/n" prompt), the action is
    /// stashed in `install_post_actions` keyed by the install Pty's
    /// PaneId. `drain_install_post_actions` on each tick checks
    /// whether the install Pty exited; on success it fires the
    /// action so the user doesn't have to re-click.
    pub fn install_sibling_with_action(
        &mut self,
        family_id: &str,
        post_action: Option<crate::sibling_install::PostInstallAction>,
    ) {
        let Some(sibling) = crate::sibling_install::lookup(family_id) else {
            self.toast(format!("install: unknown sibling `{family_id}`"));
            return;
        };
        if sibling.is_builtin() {
            self.toast(format!(
                "{} is built into mnml — no install needed",
                sibling.binary
            ));
            return;
        }
        // Dedupe: if there's already an install Pty in flight for
        // this binary, don't spawn a second one. Just update the
        // captured post-install action so the one in-flight install
        // fires the most-recent intent when it completes. Prevents
        // the "user clicks again because the install pane looked
        // unresponsive → mnml spawns a second install → two cloudwatch
        // panes open" footgun.
        let already_running = self
            .install_post_actions
            .iter()
            .find(|(_, t)| t.binary == sibling.binary)
            .map(|(pid, _)| *pid);
        if let Some(pid) = already_running {
            if let Some(action) = post_action
                && let Some(tracker) = self.install_post_actions.get_mut(&pid)
            {
                tracker.action = action;
            }
            self.toast(format!(
                "{} install already in flight — will continue when it finishes",
                sibling.binary
            ));
            return;
        }
        // Mount-specific: write the manifest first so the icon
        // appears immediately. The install Pty runs in parallel; user
        // sees both progress + icon.
        let mount_msg = match crate::family_catalog::mount_stub_for(family_id) {
            Some(stub) => {
                match crate::sibling_install::write_mount_manifest(family_id, &stub, sibling.binary)
                {
                    Ok(path) => {
                        self.refresh_mount_manifests();
                        Some(format!("manifest → {}", path.display()))
                    }
                    Err(e) => Some(format!("manifest write failed: {e}")),
                }
            }
            None => None,
        };
        // Spawn the install in a Pty pane so user can watch progress.
        // `install_pipeline_argv` prefers a fast prebuilt download
        // (~1-2s) over the slow cargo-compile fallback (~30-60s)
        // when a prebuilt asset exists at the sibling's
        // `latest-build` GitHub release for our target triple.
        let argv = crate::sibling_install::install_pipeline_argv(sibling);
        let label = format!("install: {}", sibling.binary);
        let profile = crate::pty_pane::BinaryProfile {
            label,
            exe: argv[0].clone(),
            args: argv[1..].to_vec(),
            cwd: Some(self.workspace.clone()),
            env: Vec::new(),
            session_id: None,
        };
        self.open_pty(profile);
        let install_pane = self.active;
        // Stash the post-install action keyed by the new install Pty's
        // PaneId so `drain_install_post_actions` can fire it once the
        // install exits and the binary appears on PATH.
        if let (Some(pid), Some(action)) = (install_pane, post_action) {
            self.install_post_actions.insert(
                pid,
                InstallTracker {
                    family_id: family_id.to_string(),
                    binary: sibling.binary.to_string(),
                    action,
                },
            );
        }
        let mut toast = format!("installing {} — watch the pty pane", sibling.binary);
        if let Some(extra) = mount_msg {
            toast.push_str(" · ");
            toast.push_str(&extra);
        }
        self.toast(toast);
    }

    /// Thin wrapper — old call sites that don't have a post-action
    /// to chain (the palette/discovery/AI paths). Equivalent to
    /// `install_sibling_with_action(id, None)`.
    pub fn install_sibling(&mut self, family_id: &str) {
        self.install_sibling_with_action(family_id, None);
    }

    /// Walk `install_post_actions`. For each entry whose install
    /// Pty has exited (reader thread set `exited = true`), check
    /// whether the binary now resolves on PATH. If yes, fire the
    /// captured action. If no, toast the failure so the user knows
    /// the install didn't take. Either way, drop the entry — we
    /// don't retry a failed install on the next tick.
    pub(crate) fn drain_install_post_actions(&mut self) {
        if self.install_post_actions.is_empty() {
            return;
        }
        // Snapshot done-panes so we can mutate self while iterating.
        let done: Vec<(crate::layout::PaneId, InstallTracker)> = self
            .install_post_actions
            .iter()
            .filter_map(|(pid, tracker)| {
                let exited = matches!(self.panes.get(*pid), Some(Pane::Pty(s)) if s.is_exited());
                exited.then(|| (*pid, tracker.clone()))
            })
            .collect();
        for (pid, tracker) in done {
            self.install_post_actions.remove(&pid);
            if binary_on_path(&tracker.binary) {
                self.toast(format!("{} installed — continuing", tracker.binary));
                self.fire_post_install_action(tracker.action);
                // Auto-close the install Pty pane once the action
                // has fired. The pane otherwise sits there showing
                // "[process exited — Ctrl+W to close]" above the
                // actual viewer, cluttering the layout. On failure
                // we LEAVE it open so the user can read the error.
                self.close_pane(pid);
            } else {
                self.toast(format!(
                    "install failed for {} — see the pty pane for cargo output",
                    tracker.binary
                ));
            }
        }
    }

    fn fire_post_install_action(&mut self, action: crate::sibling_install::PostInstallAction) {
        use crate::sibling_install::PostInstallAction::*;
        match action {
            CloudWatchLogs {
                log_group,
                filter,
                label,
            } => self.open_cloudwatch_pane(&log_group, &filter, &label),
            S3Browse {
                bucket,
                prefix,
                label,
            } => self.open_s3_pane(&bucket, &prefix, &label),
        }
    }

    /// Show a yes/no confirm prompt to install the named family
    /// sibling. Accept fires `install_sibling`. Used by the
    /// "X not installed" toasts that previously just gave the
    /// install command and bailed.
    pub fn prompt_install_sibling(&mut self, family_id: &str) {
        self.prompt_install_sibling_with_action(family_id, None);
    }

    /// Like `prompt_install_sibling` but captures a follow-on action
    /// (CloudWatchLogs / S3Browse / etc) that gets fired
    /// automatically after the install succeeds. Used by
    /// `open_cloudwatch_pane` + `open_s3_pane` when the binary
    /// isn't on PATH — the user accepts the prompt and the original
    /// action just happens, no second click needed.
    pub fn prompt_install_sibling_with_action(
        &mut self,
        family_id: &str,
        post_action: Option<crate::sibling_install::PostInstallAction>,
    ) {
        let Some(sibling) = crate::sibling_install::lookup(family_id) else {
            return;
        };
        let title = format!("{} not installed. Install via cargo? (y/n)", sibling.binary);
        self.pending_install_family_id = Some(family_id.to_string());
        self.pending_install_after_action = post_action;
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::SiblingInstallConfirm,
            title,
        ));
    }

    /// Accept handler for the SiblingInstallConfirm prompt. The
    /// dispatcher matches on the prompt's first character so this
    /// just fires the install when the input starts with `y`.
    pub fn install_sibling_confirm_resolve(&mut self, input: &str) {
        let id = self.pending_install_family_id.take();
        let action = self.pending_install_after_action.take();
        if input.trim().to_ascii_lowercase().starts_with('y')
            && let Some(family_id) = id
        {
            self.install_sibling_with_action(&family_id, action);
        }
    }

    /// Open a picker over Mount-capable family siblings — i.e.
    /// catalog entries that have a `MountStub` registered. Accept
    /// fires `install_sibling`, which writes the manifest +
    /// spawns `cargo install` in a Pty pane. Used by the
    /// `mounts.install` palette command.
    pub fn open_mount_install_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = crate::family_catalog::CATALOG
            .iter()
            .filter(|s| !s.is_private())
            .filter(|s| crate::family_catalog::mount_stub_for(s.id).is_some())
            .map(|s| {
                let installed = binary_on_path(s.binary);
                let detail = if installed {
                    format!("INSTALLED · {}", s.one_liner)
                } else {
                    s.one_liner.to_string()
                };
                PickerItem::new(s.id.to_string(), s.binary.to_string(), detail)
            })
            .collect();
        if items.is_empty() {
            self.toast("no Mount-capable siblings in the catalog yet");
            return;
        }
        self.open_picker(Picker::new(
            PickerKind::SiblingInstall,
            "Install Mount sibling",
            items,
        ));
    }

    /// Like `open_mount_install_picker` but spans the entire catalog
    /// (Pty + Mount siblings). Used by the `sibling.install` palette
    /// command and the AI tool.
    pub fn open_sibling_install_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = crate::family_catalog::CATALOG
            .iter()
            .filter(|s| !s.is_builtin())
            .filter(|s| !s.is_private())
            .map(|s| {
                let installed = binary_on_path(s.binary);
                let kind_tag = if crate::family_catalog::mount_stub_for(s.id).is_some() {
                    "Mount"
                } else {
                    "Pty"
                };
                let detail = if installed {
                    format!("INSTALLED · {} · {}", kind_tag, s.one_liner)
                } else {
                    format!("{} · {}", kind_tag, s.one_liner)
                };
                PickerItem::new(s.id.to_string(), s.binary.to_string(), detail)
            })
            .collect();
        if items.is_empty() {
            self.toast("catalog is empty");
            return;
        }
        self.open_picker(Picker::new(
            PickerKind::SiblingInstall,
            "Install family sibling",
            items,
        ));
    }

    /// Refresh the manifest list — re-scans both manifest dirs.
    /// Called by the `mounts.refresh` palette command + on app
    /// resume from background.
    pub fn refresh_mount_manifests(&mut self) {
        self.mount_manifests = crate::mount_manifest::load_all(&self.workspace);
        self.toast(format!(
            "mounts: {} manifest(s) loaded",
            self.mount_manifests.len()
        ));
    }

    /// Spawn a hosted sibling as a `Pane::Mount`. Called by the
    /// MountBinary prompt's accept handler.
    pub fn open_mount(&mut self, binary: &str) {
        let label = binary.rsplit('/').next().unwrap_or(binary).to_string();
        self.open_mount_with_label(binary, &label);
    }

    /// Same as `open_mount` but with an explicit display label —
    /// used by manifest mounts so the pane tab shows the manifest
    /// `name` instead of the raw binary basename.
    pub fn open_mount_with_label(&mut self, binary: &str, label: &str) {
        let geometry = mnml_bridge::Geometry { cols: 80, rows: 24 };
        let env = self.bridge_env();
        let workspace = self.workspace.clone();
        match crate::mount::MountSession::spawn(
            &workspace,
            label.to_string(),
            binary,
            &[],
            &env,
            Some(&workspace),
            geometry,
        ) {
            Ok(session) => {
                let pane = Pane::Mount(session);
                match self.active {
                    Some(cur) => {
                        let new_id =
                            self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                        self.active = Some(new_id);
                    }
                    None => {
                        self.panes.push(pane);
                        let id = self.panes.len() - 1;
                        *self.layout_mut() = Layout::leaf(id);
                        self.active = Some(id);
                    }
                }
                self.focus = Focus::Pane;
                self.toast(format!("mounted {binary}"));
            }
            Err(e) => {
                self.toast(format!("mount failed: {e}"));
            }
        }
    }
}
