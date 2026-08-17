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
    /// implicitly after a sibling's `--install` writes a new
    /// manifest file (user runs the palette command to pick up
    /// the change without restarting mnml).
    pub fn refresh_integration_manifests(&mut self) {
        self.integration_manifests = crate::integration_manifest::load_all(&self.workspace);
        // 2026-07-31 — re-run sibling-glyph discovery FIRST so any
        // newly-installed SVG in ~/.config/mnml/glyphs/ shows up
        // before the merge pass fills IntegrationIcon.glyph.
        self.discover_integration_glyphs();
        self.merge_integration_manifests();
        // 2026-08-17 — re-spawn statusline-segment workers after
        // the manifest re-scan so newly-added or removed
        // `[[values_sources]]` entries take effect without a
        // restart. Dropping the old sender inside `start_…`
        // signals in-flight workers to exit on their next send.
        self.start_statusline_segment_workers();
        // R9 api-workflow SEV-3 — users hitting the palette
        // `integrations.refresh` reasonably expect ALL on-disk
        // scanned state to be re-read, not just integration
        // manifests. HTTP panel's MOCKS section reads
        // `http_panel_mocks_cache` which was only rebuilt via the
        // separate `http.refresh` command or a full restart, so a
        // fresh `.mock.json` created by a sibling didn't appear.
        // Piggyback on this palette-level refresh.
        self.http_panel_refresh();
        self.toast(format!(
            "integrations: {} manifest(s) loaded ({} sibling glyph(s))",
            self.integration_manifests.len(),
            self.integration_glyph_svgs.len(),
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
        self.open_mount_with_args(binary, label, &[]);
    }

    /// Full form — accepts extra CLI args to hand to the mount
    /// binary. Used by manifest mounts whose sibling needs flags
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
}
