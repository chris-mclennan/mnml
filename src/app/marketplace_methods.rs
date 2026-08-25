//! Marketplace tab: async fetch of integration launchers/apps from
//! configured sources, per-source drain into `marketplace_entries`,
//! and the install/uninstall flow. Includes the launcher-download
//! worker (`install_launcher_from_url`) and its per-tick drain
//! (`drain_launcher_installs`).
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

/// P4c — download a launcher TOML from `url` and write it to the
/// user's integrations dir at `<id>.toml`. Blocking (small files,
/// runs on the main loop tick where the user clicks install).
/// Returns the written path or an error string.
fn install_launcher_from_url(id: &str, url: &str) -> Result<std::path::PathBuf, String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(format!(
            "mnml-launcher-install/{}",
            env!("CARGO_PKG_VERSION")
        ))
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let body = client
        .get(url)
        .send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.text())
        .map_err(|e| format!("fetch: {e}"))?;
    // Parse first — refuse to install a broken TOML rather than
    // dropping garbage in ~/.config/mnml/integrations/.
    let parsed: crate::integration_manifest::IntegrationManifest =
        toml::from_str(&body).map_err(|e| format!("parse toml: {e}"))?;
    if parsed.id != id {
        return Err(format!(
            "manifest id {:?} doesn't match expected {:?}",
            parsed.id, id
        ));
    }
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .ok_or_else(|| "no $HOME".to_string())?;
    let dir = home.join(".config").join("mnml").join("integrations");
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let path = dir.join(format!("{id}.toml"));
    std::fs::write(&path, body).map_err(|e| format!("write: {e}"))?;
    // 2026-08-06 — SVG asset side-fetch. If the launcher declares
    // `chip.glyph_svg`, treat it as a filename relative to the TOML
    // URL (typical: `htop.svg` next to `htop.toml` in the source
    // repo's launcher folder). Fetch + drop into pending-glyphs so
    // discover/bake can pick it up on next `integrations.refresh`
    // (or on the next startup — the discover pass is idempotent).
    // Best-effort — a missing SVG isn't a fatal install error; the
    // launcher still installs and falls back to `chip.fallback` /
    // any codepoint declared on `chip.glyph`.
    if let Some(chip) = &parsed.chip
        && let Some(svg_name) = &chip.glyph_svg
        && !svg_name.is_empty()
    {
        let svg_url = url
            .rsplit_once('/')
            .map(|(prefix, _)| format!("{prefix}/{svg_name}"));
        if let Some(svg_url) = svg_url {
            let pending = home.join(".cache").join("mnml").join("pending-glyphs");
            let _ = std::fs::create_dir_all(&pending);
            if let Ok(bytes) = client
                .get(&svg_url)
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.bytes())
            {
                let _ = std::fs::write(pending.join(format!("{id}.svg")), &bytes);
            }
        }
    }
    Ok(path)
}

impl App {
    // ── Marketplace (P4b) ─────────────────────────────────────
    //
    // Async fetch pattern: `refresh_marketplace()` spawns one thread
    // per configured source, each posts to an mpsc. `drain_marketplace()`
    // (called on each event loop tick) polls the receivers and merges
    // arrived entries into `marketplace_entries`, then persists to
    // the on-disk cache. Chunked delivery — the tab renders whatever's
    // arrived without waiting for every source.

    /// Load the on-disk marketplace cache into `marketplace_entries`.
    /// Best-effort — silent no-op if the cache is missing / malformed.
    /// Called once at App::new so a fresh mnml has something to render
    /// even before the first fetch completes. Passive: no network I/O
    /// here — the auto-refresh path is
    /// `maybe_refresh_marketplace_on_startup()`, invoked by the real
    /// interactive `main.rs` after `App::new` returns so unit tests /
    /// headless runs / `.test` E2E stays hermetic.
    pub fn load_marketplace_cache(&mut self) {
        let Some(path) = crate::marketplace::MarketplaceCache::path() else {
            return;
        };
        let Some(cache) = crate::marketplace::MarketplaceCache::load_from(&path) else {
            return;
        };
        self.marketplace_entries = cache.entries;
        self.marketplace_last_fetched = cache.fetched_at;
        // Caches written before the 2026-08-25 dedupe fix can carry
        // cross-source duplicate rows — collapse on load too.
        crate::marketplace::dedupe_entries_by_id(&mut self.marketplace_entries);
        // `ready` is derived from the shipped `ready_ids()` list at
        // fetch time; re-derive on load so a binary upgrade that
        // changes the list takes effect without waiting out the
        // cache TTL (2026-08-25: launchers gained the ready gate —
        // stale caches held ready=false for btop/htop/iftop/vscode).
        for e in &mut self.marketplace_entries {
            e.ready = crate::marketplace::is_ready(&e.id);
        }
        sort_marketplace_entries(&mut self.marketplace_entries);
    }

    /// Interactive-startup hook: if the on-disk marketplace cache is
    /// missing or past its TTL, kick off a silent background refresh
    /// so entries added/removed from the catalog reconcile without
    /// the user having to click ⟳. Called only from `main.rs` after
    /// `App::new`, never from the shared constructor path, so the
    /// test suite / headless / E2E harness never touches the network.
    pub fn maybe_refresh_marketplace_on_startup(&mut self) {
        if !self.config.marketplace.enabled {
            return;
        }
        let path = match crate::marketplace::MarketplaceCache::path() {
            Some(p) => p,
            None => return,
        };
        let stale = match crate::marketplace::MarketplaceCache::load_from(&path) {
            Some(cache) => cache.is_expired(),
            None => true,
        };
        if stale {
            self.refresh_marketplace_silent();
        }
    }

    /// Spawn a fetch thread for every configured marketplace source.
    /// Non-blocking — results arrive via `drain_marketplace()`.
    /// No-op when `config.marketplace.enabled = false`.
    pub fn refresh_marketplace(&mut self) {
        if !self.config.marketplace.enabled {
            self.toast("marketplace disabled — enable in config".to_string());
            return;
        }
        let count = self.spawn_marketplace_fetches();
        self.toast(format!("marketplace: refreshing {count} source(s)…"));
    }

    /// Same as `refresh_marketplace()` but without the toast — used by
    /// the startup auto-refresh so a routine relaunch doesn't pop
    /// unexpected chatter over the recent-files splash.
    pub fn refresh_marketplace_silent(&mut self) {
        if !self.config.marketplace.enabled {
            return;
        }
        self.spawn_marketplace_fetches();
    }

    fn spawn_marketplace_fetches(&mut self) -> usize {
        self.marketplace_pending.clear();
        for source in self.config.marketplace.effective_sources() {
            let id = source.id().to_string();
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let result = crate::marketplace::fetch_source(&source);
                let _ = tx.send(result);
            });
            self.marketplace_pending.push((id, rx));
        }
        self.marketplace_pending.len()
    }

    /// Poll every pending marketplace fetch. Called from the event
    /// loop's per-tick drain. Returns true when at least one source
    /// delivered — the render layer uses that to know it needs to
    /// repaint.
    pub fn drain_marketplace(&mut self) -> bool {
        let mut any = false;
        let mut errored: Vec<(String, String)> = Vec::new();
        let mut delivered: Vec<(String, Vec<crate::marketplace::MarketplaceEntry>)> = Vec::new();
        self.marketplace_pending
            .retain_mut(|(source_id, rx)| match rx.try_recv() {
                Ok(Ok(entries)) => {
                    delivered.push((source_id.clone(), entries));
                    false
                }
                Ok(Err(e)) => {
                    errored.push((source_id.clone(), e));
                    false
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => true,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => false,
            });
        for (source_id, entries) in delivered {
            any = true;
            // Replace entries for this source (a re-fetch fully
            // supersedes prior entries; no stale-entry merge).
            self.marketplace_entries
                .retain(|e| e.source_id != source_id);
            self.marketplace_entries.extend(entries);
        }
        if any {
            crate::marketplace::dedupe_entries_by_id(&mut self.marketplace_entries);
            sort_marketplace_entries(&mut self.marketplace_entries);
        }
        for (source_id, e) in errored {
            eprintln!("marketplace: {source_id}: {e}");
        }
        if any {
            // Persist to on-disk cache. Best-effort — a write failure
            // just means next launch re-fetches.
            self.marketplace_last_fetched = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            if let Some(path) = crate::marketplace::MarketplaceCache::path() {
                let cache = crate::marketplace::MarketplaceCache {
                    fetched_at: self.marketplace_last_fetched,
                    ttl_secs: self.config.marketplace.cache_ttl_secs,
                    entries: self.marketplace_entries.clone(),
                };
                let _ = cache.save_to(&path);
            }
            if self.marketplace_pending.is_empty() {
                self.toast(format!(
                    "marketplace: {} entries",
                    self.marketplace_entries.len()
                ));
            }
        }
        any
    }

    /// P4c — install action for a marketplace entry. Dispatches by
    /// entry kind:
    ///
    /// - **App** (`InstallSpec::Cargo`) — spawn `cargo install <name>`
    ///   as a Pty pane so the user sees compile output. On success,
    ///   the integration's own `--install` subcommand handles manifest
    ///   registration; user runs it manually after cargo finishes.
    /// - **Launcher** (`InstallSpec::LauncherToml`) — download the
    ///   TOML via blocking HTTP + write to
    ///   `~/.config/mnml/integrations/<id>.toml`. Toast on success.
    ///
    /// Blocking on the launcher path is fine because the file is tiny
    /// (kilobytes) and the request completes in ~200ms. Cargo install
    /// is naturally async via the Pty.
    /// vscode-mouse r4 SEV-2 + user report 2026-08-06 — click on a
    /// marketplace row now opens a `[Install] [Cancel]` dialog
    /// instead of firing install immediately. Prevents the "I
    /// misclicked and cargo started" surprise on a fat cursor.
    pub fn open_marketplace_install_prompt(&mut self, idx: usize) {
        let Some(entry) = self.marketplace_entries.get(idx) else {
            return;
        };
        let title = match &entry.install {
            crate::marketplace::InstallSpec::Cargo { name } => {
                format!("Install `{name}` via cargo?")
            }
            crate::marketplace::InstallSpec::LauncherToml { .. } => {
                format!("Install launcher `{}`?", entry.id)
            }
            crate::marketplace::InstallSpec::CargoGit { repo, .. } => {
                format!("Install `{}` from private repo {repo}?", entry.id)
            }
        };
        self.pending_marketplace_install_idx = Some(idx);
        let mut p =
            crate::prompt::Prompt::new(crate::prompt::PromptKind::MarketplaceInstallConfirm, title);
        p.cursor = 0; // focus [Install]
        self.prompt = Some(p);
    }

    /// Accept handler for the MarketplaceInstallConfirm dialog. Same
    /// input contract as the other confirm prompts — anything
    /// starting with `y` = install.
    pub fn marketplace_install_confirm_resolve(&mut self, input: &str) {
        let idx = self.pending_marketplace_install_idx.take();
        if input.trim().to_ascii_lowercase().starts_with('y')
            && let Some(idx) = idx
        {
            self.install_marketplace_entry(idx);
        }
    }

    pub fn install_marketplace_entry(&mut self, idx: usize) {
        let Some(entry) = self.marketplace_entries.get(idx).cloned() else {
            return;
        };
        match &entry.install {
            crate::marketplace::InstallSpec::Cargo { name } => {
                self.toast(format!("installing {name}…"));
                // 2026-08-06 — auto-chain the integration's own
                // `--install` subcommand so the marketplace click is
                // truly one-step (dialog → cargo → chip visible).
                // Was: user had to `<binary> --install` manually
                // after cargo finished. Chained via `&&` so a
                // failed cargo (compile error, network, etc) skips
                // the second step cleanly.
                //
                // Runs in the same Pty pane so the user sees both
                // outputs sequentially.
                // 2026-08-08 — after cargo install + --install both
                // succeed, write a `run-command` JSON line to the mnml
                // IPC command file to auto-fire integrations.refresh.
                // Previously the toast asked the user to run it manually
                // — but the Install button then stayed as "Install"
                // until they did, which read as "install didn't work".
                //
                // `--force` is REQUIRED, not optional: without it,
                // cargo silently skips whenever the binary is already
                // installed at any version — so a marketplace click
                // that means "upgrade to latest" turns into a no-op
                // and the integration's OLD --install runs, writing stale
                // labels + missing SVGs. --force always installs the
                // newest published version.
                //
                // 2026-08-08 — SECOND landmine: the `<name> --install`
                // that follows the cargo install shell-resolves via
                // PATH. If ANY older copy of the binary sits in a
                // PATH dir ahead of ~/.cargo/bin (e.g. a stale
                // ~/.local/bin/<name>), the stale one runs and writes
                // its old manifest — cargo installed the new binary
                // for nothing. Explicit path to the freshly-installed
                // binary ensures the RIGHT binary writes the manifest.
                let ipc_cmd = self.workspace.join(".mnml").join("ipc").join("command");
                self.run_ex_command(&format!(
                    "term cargo install --force {name} && $HOME/.cargo/bin/{name} --install && echo '{{\"cmd\":\"run-command\",\"id\":\"integrations.refresh\"}}' >> {ipc} && echo '✓ {name} installed'",
                    ipc = ipc_cmd.display(),
                ));
            }
            crate::marketplace::InstallSpec::CargoGit { repo, path } => {
                let name = entry.id.clone();
                // Defense-in-depth: `repo` came in via a validated
                // `RawMarketplaceSource::GithubMonorepoApps` (both
                // repo slug + apps_dir sanity-checked at config load
                // — see `config.rs::into_source`), `name` came from
                // `parse_github_dir_children` which drops any entry
                // outside the safe crate charset, and `path` was
                // built as `apps_dir/name` from those two. Assert
                // here so a future refactor that adds another entry
                // path can't silently reach this shell command with
                // an unchecked string.
                //
                // `path` is retained on the InstallSpec because the
                // README-fetch path uses it (github.com/<repo>/<path>/
                // README.md) — but it's NOT passed to `cargo install`.
                // Cargo rejects `--git URL --path X` as mutually
                // exclusive; instead, the sub-crate in a workspace is
                // identified positionally by its Cargo.toml `name`,
                // which we assume matches the directory name (id).
                // Errors out with the first-fix landmine 2026-08-16.
                if !crate::marketplace::is_safe_repo_slug(repo)
                    || !crate::marketplace::is_safe_repo_subpath(path)
                    || !crate::marketplace::is_safe_crate_component(&name)
                {
                    self.toast(format!(
                        "install refused: {name}/{repo}/{path} contains an unsafe character"
                    ));
                    return;
                }
                self.toast(format!("installing {name} from {repo}…"));
                // Private-repo install: cargo shells to git which
                // uses the user's git credential.helper — same auth
                // path that lets them `git clone` the private repo
                // on the terminal. If they can't clone, cargo can't
                // fetch. Runs in a Pty pane so the auth prompt (if
                // any) is visible + interactive.
                //
                // --force + explicit ~/.cargo/bin path for the same
                // reasons the crates.io arm needs them (see comments
                // above).
                let ipc_cmd = self.workspace.join(".mnml").join("ipc").join("command");
                self.run_ex_command(&format!(
                    "term cargo install --force --git https://github.com/{repo}.git {name} && $HOME/.cargo/bin/{name} --install && echo '{{\"cmd\":\"run-command\",\"id\":\"integrations.refresh\"}}' >> {ipc} && echo '✓ {name} installed'",
                    ipc = ipc_cmd.display(),
                ));
            }
            crate::marketplace::InstallSpec::LauncherToml { url } => {
                let id = entry.id.clone();
                let url = url.clone();
                self.toast(format!("fetching launcher {id}…"));
                // vscode-mouse SEV-1 2026-08-05 — was: blocking
                // reqwest::blocking on the UI thread (froze render
                // for up to 10s). Now: worker thread + per-tick
                // drain in `drain_launcher_installs`.
                let (tx, rx) = std::sync::mpsc::channel();
                std::thread::spawn(move || {
                    let result = install_launcher_from_url(&id, &url)
                        .map(|path| (id.clone(), path))
                        .map_err(|e| (id, e));
                    let _ = tx.send(result);
                });
                self.launcher_install_pending.push(rx);
            }
        }
    }
    /// integration manifests + flip the panel to Installed so the
    /// user sees where the chip landed. Failures toast the error.
    pub fn drain_launcher_installs(&mut self) {
        let mut delivered: Vec<Result<(String, std::path::PathBuf), (String, String)>> = Vec::new();
        self.launcher_install_pending
            .retain_mut(|rx| match rx.try_recv() {
                Ok(msg) => {
                    delivered.push(msg);
                    false
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => true,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => false,
            });
        if delivered.is_empty() {
            return;
        }
        let mut any_ok = false;
        for r in delivered {
            match r {
                Ok((id, _path)) => {
                    any_ok = true;
                    self.toast(format!("installed {id} — see Installed tab"));
                }
                Err((_id, e)) => {
                    self.toast(format!("install failed: {e}"));
                }
            }
        }
        // Refresh once per drain (not per-entry) even on partial
        // failures — the manifest state may have partial writes.
        self.refresh_integration_manifests();
        // 2026-08-06 — an installed launcher may have side-fetched
        // its custom SVG into ~/.cache/mnml/pending-glyphs/. Kick a
        // discover pass so the codepoint is assigned before the
        // next paint. The actual bake stays a user action
        // (fontforge is heavy) — surface a toast when there's new
        // pending SVG bytes so the user knows to run
        // `integrations.bake_integration_glyphs`.
        if any_ok {
            let before = self.integration_glyph_svgs.len();
            self.discover_integration_glyphs();
            let after = self.integration_glyph_svgs.len();
            if after > before {
                self.toast(format!(
                    "{} new SVG glyph(s) pending — run `integrations.bake_integration_glyphs` to render",
                    after - before
                ));
            }
            self.integrations_panel_tab = crate::app::IntegrationsPanelTab::Installed;
        }
    }
}

/// Marketplace-tab sort order:
/// 1. Official sources before Community.
/// 2. Within a provenance, group by kind (Launcher before App) so
///    the `[launcher]` and `[app]` chip strips stay contiguous
///    instead of alphabetically interleaving.
/// 3. Alphabetical (case-insensitive) by label within each group.
fn sort_marketplace_entries(entries: &mut [crate::marketplace::MarketplaceEntry]) {
    entries.sort_by(|a, b| {
        let ap = matches!(a.provenance, crate::marketplace::Provenance::Official);
        let bp = matches!(b.provenance, crate::marketplace::Provenance::Official);
        let ak = kind_sort_key(&a.kind);
        let bk = kind_sort_key(&b.kind);
        bp.cmp(&ap)
            .then_with(|| ak.cmp(&bk))
            .then_with(|| a.label.to_lowercase().cmp(&b.label.to_lowercase()))
    });
}

fn kind_sort_key(k: &crate::marketplace::MarketplaceKind) -> u8 {
    match k {
        crate::marketplace::MarketplaceKind::Launcher => 0,
        crate::marketplace::MarketplaceKind::App => 1,
    }
}
