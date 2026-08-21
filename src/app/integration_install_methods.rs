//! Mount runtime + integration manifest refresh methods on `App`.
//!
//! Previously this file also owned the legacy family-catalog install
//! flow (`install_integration_with_action` + `open_mount_install_picker`
//! + `open_integration_install_picker` + the CloudWatch/S3 install
//! prompt). That path was retired 2026-08-08 when `CATALOG` was
//! emptied — every install now goes through the Marketplace panel
//! (see `src/marketplace.rs`).

use super::*;

impl App {
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

    /// Refresh the integration manifest list — re-scans both dirs
    /// and re-merges chips + commands. Called by the
    /// `integrations.refresh` palette command; also fires
    /// implicitly after an integration's `--install` writes a new
    /// manifest file (user runs the palette command to pick up
    /// the change without restarting mnml).
    pub fn refresh_integration_manifests(&mut self) {
        self.integration_manifests = crate::integration_manifest::load_all(&self.workspace);
        // 2026-07-31 — re-run integration-glyph discovery FIRST so any
        // newly-installed SVG in ~/.config/mnml/glyphs/ shows up
        // before the merge pass fills IntegrationIcon.glyph.
        self.discover_integration_glyphs();
        // #1102 f/u (2026-08-20) — refresh the binary → version
        // cache BEFORE merge so `IntegrationIcon.version` picks up
        // the live `<binary> --version` result. Ordering matters:
        // merge reads from the cache to populate the icon field.
        self.refresh_binary_version_cache();
        self.merge_integration_manifests();
        // 2026-08-17 — re-spawn statusline-segment workers after
        // the manifest re-scan so newly-added or removed
        // `[[values_sources]]` entries take effect without a
        // restart. Dropping the old sender inside `start_…`
        // signals in-flight workers to exit on their next send.
        self.start_statusline_segment_workers();
        // #1117 (2026-08-21) — refresh the prefetch fleet on
        // manifest re-scan so newly-added or removed
        // `[[prefetch]]` entries take effect without a restart.
        self.start_prefetch_workers();
        // R9 api-workflow SEV-3 — users hitting the palette
        // `integrations.refresh` reasonably expect ALL on-disk
        // scanned state to be re-read, not just integration
        // manifests. HTTP panel's MOCKS section reads
        // `http_panel_mocks_cache` which was only rebuilt via the
        // separate `http.refresh` command or a full restart, so a
        // fresh `.mock.json` created by an integration didn't appear.
        // Piggyback on this palette-level refresh.
        self.http_panel_refresh();
        self.toast(format!(
            "integrations: {} manifest(s) loaded ({} integration glyph(s))",
            self.integration_manifests.len(),
            self.integration_glyph_svgs.len(),
        ));
    }

    /// #1102 f/u (2026-08-20) — resolve `<binary> --version` for
    /// every unique integration binary declared across the loaded
    /// manifests, keyed by binary basename. Clap's default
    /// `--version` format is `<name> <version>` (single line);
    /// we take the LAST whitespace-separated token so leading
    /// hyphenated names (`mnml-forge-bitbucket`) don't confuse
    /// the parse.
    ///
    /// Runs synchronously — each `--version` call is a cheap
    /// process spawn on an already-installed binary. On my box a
    /// full 15-integration sweep is <200ms. Called after
    /// manifest re-scan + post-install; NOT on every render.
    /// A binary that fails to spawn or exits non-zero silently
    /// drops out of the cache and the manifest's `version` field
    /// takes over as the byline fallback.
    pub fn refresh_binary_version_cache(&mut self) {
        use std::collections::HashSet;
        use std::process::{Command, Stdio};
        use std::time::Duration;
        let mut seen: HashSet<String> = HashSet::new();
        let mut fresh: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        let binaries: Vec<String> = self
            .integration_manifests
            .iter()
            .filter_map(|m| m.binary.clone())
            .collect();
        for binary in binaries {
            let basename = binary.rsplit('/').next().unwrap_or(&binary).to_string();
            if !seen.insert(basename.clone()) {
                continue;
            }
            let Ok(mut child) = Command::new(&binary)
                .arg("--version")
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .stdin(Stdio::null())
                .spawn()
            else {
                continue;
            };
            // Cheap poll-with-deadline — clap's --version prints
            // to stdout and exits immediately; anything taking
            // more than 500ms is misbehaving.
            let deadline = std::time::Instant::now() + Duration::from_millis(500);
            let mut finished = false;
            while std::time::Instant::now() < deadline {
                match child.try_wait() {
                    Ok(Some(_)) => {
                        finished = true;
                        break;
                    }
                    Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                    Err(_) => break,
                }
            }
            if !finished {
                let _ = child.kill();
                let _ = child.wait();
                continue;
            }
            let Ok(output) = child.wait_with_output() else {
                continue;
            };
            if !output.status.success() {
                continue;
            }
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(tok) = stdout.split_whitespace().next_back()
                && !tok.is_empty()
            {
                fresh.insert(basename, tok.to_string());
            }
        }
        self.binary_version_cache = fresh;
    }

    /// Spawn a hosted integration as a `Pane::Mount`. Called by the
    /// MountBinary prompt's accept handler.
    pub fn open_mount(&mut self, binary: &str) {
        let label = binary.rsplit('/').next().unwrap_or(binary).to_string();
        self.open_mount_with_label(binary, &label);
    }

    /// Same as `open_mount` but with an explicit display label —
    /// used by manifest mounts so the pane tab shows the manifest
    /// `name` instead of the raw binary basename.
    pub fn open_mount_with_label(&mut self, binary: &str, label: &str) {
        self.open_mount_with_args(binary, label, &[]);
    }

    /// Full form — accepts extra CLI args to hand to the mount
    /// binary. Used by manifest mounts whose integration needs flags
    /// (e.g. `mnml-forge-bitbucket --only prs`). 2026-07-20.
    pub fn open_mount_with_args(&mut self, binary: &str, label: &str, args: &[String]) {
        let geometry = mnml_bridge::Geometry { cols: 80, rows: 24 };
        let env = self.bridge_env();
        let workspace = self.workspace.clone();
        match crate::mount::MountSession::spawn(
            &workspace,
            label.to_string(),
            binary,
            args,
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

    /// #992 (2026-08-18) — apply an available integration update.
    /// Shared by (a) the marketplace-row `↑ Update to X` chip click,
    /// (b) the integration-chip right-click "Update to X" menu item.
    /// Both surfaces need the SAME install-spec routing (Cargo vs
    /// CargoGit vs LauncherToml vs plain-id fallback) and the same
    /// optimistic clear of `integration_updates`.
    ///
    /// Silent no-op with toast if the id's install spec can't be
    /// classified — the chip / menu item shouldn't render in that
    /// case, but defense against races.
    pub fn apply_integration_update(&mut self, id: &str) {
        let install_spec = self
            .marketplace_entries
            .iter()
            .find(|e| e.id == id)
            .map(|e| e.install.clone());
        let cmd = match install_spec {
            Some(crate::marketplace::InstallSpec::Cargo { name })
                if crate::marketplace::is_safe_crate_component(&name) =>
            {
                Some(format!(
                    "term cargo install --force {name} && $HOME/.cargo/bin/{name} --install && echo '✓ {name} updated'",
                ))
            }
            Some(crate::marketplace::InstallSpec::Cargo { .. }) => None,
            Some(crate::marketplace::InstallSpec::CargoGit { repo, .. }) => {
                if crate::marketplace::is_safe_repo_slug(&repo)
                    && crate::marketplace::is_safe_crate_component(id)
                {
                    Some(format!(
                        "term cargo install --force --git https://github.com/{repo}.git {id} && $HOME/.cargo/bin/{id} --install && echo '✓ {id} updated'",
                    ))
                } else {
                    None
                }
            }
            // LauncherToml installs have no cargo version — never
            // enqueued for update checks, so this branch is
            // effectively unreachable.
            Some(crate::marketplace::InstallSpec::LauncherToml { .. }) => None,
            None if crate::marketplace::is_safe_crate_component(id) => Some(format!(
                "term cargo install --force {id} && $HOME/.cargo/bin/{id} --install && echo '✓ {id} updated'",
            )),
            None => None,
        };
        if let Some(cmd) = cmd {
            self.run_ex_command(&cmd);
            // Optimistic clear — the background sweep will
            // re-populate if the install fails or the version
            // didn't move. Makes the chip disappear immediately
            // (matches "I clicked, so it's happening").
            if let Ok(mut guard) = self.integration_updates.lock() {
                guard.remove(id);
            }
            self.toast(format!("updating {id}..."));
        } else {
            self.toast(format!("cannot update {id}: unknown install source"));
        }
    }
}
