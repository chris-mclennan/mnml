//! `Pane::IntegrationDetail` — App-side helpers.
//!
//! Owns the open path (`open_integration_detail_pane`), the two
//! id-keyed action helpers used by both the pane's button strip
//! and the right-click menu (`toggle_integration_enabled_by_id`,
//! `open_integration_manifest_by_id`), and the click / keyboard
//! routing entry points invoked by the mouse / pane handlers.
//!
//! The pane never mutates the integration itself — every action
//! either dispatches a registered command or calls one of the
//! helpers here. That keeps the "no special-casing across layers"
//! spine intact: the click-router and the keyboard-router both
//! call `crate::ui::integration_detail_view::fire_action`, which
//! calls `dispatch_detail_action`, which reaches back into `App`.
//!
//! Idempotent open: firing `open_integration_detail_pane("slack")`
//! twice reuses the same pane (matches Outline / Diagnostics).

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::{IntegrationDetailPane, Pane};

/// 2026-08-06 — README state for the detail pane. `Loading` is
/// the initial value after the pane opens (a worker is fetching);
/// `Text` is a successful body; `NotFound` is any error (network,
/// 404, or the source having no README).
#[derive(Debug, Clone)]
pub enum ReadmeState {
    Loading,
    Text(String),
    NotFound,
}

impl App {
    /// Open (or refocus) the integration-detail pane for `id`. Hosts
    /// in the right panel by default (matches Outline / Diagnostics);
    /// falls back to a split in the active leaf when the right
    /// panel is closed.
    pub fn open_integration_detail_pane(&mut self, id: &str) {
        // Refuse silently if the id doesn't resolve to an installed
        // integration OR a fetched marketplace entry — toast a hint.
        // 2026-08-06 — was `integration_icons` only; extended to
        // include marketplace_entries so left-clicking a marketplace
        // row opens the detail pane instead of firing install.
        let known = self.config.ui.integration_icons.iter().any(|i| i.id == id)
            || self.marketplace_entries.iter().any(|e| e.id == id);
        if !known {
            self.toast(format!("no integration with id `{id}`"));
            return;
        }
        // Reuse an existing detail pane for the same id if present.
        if let Some((pid, _)) = self
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| matches!(p, Pane::IntegrationDetail(d) if d.id == id))
        {
            self.reveal_or_bring_to_front(pid);
            return;
        }
        // 2026-08-01 — was hosted in the right panel (narrow column).
        // User: "the integration page is showing up on right slide out
        // panel but should take the center like the http area does."
        // Host as a regular pane so it gets the full body area, tab
        // strip, drag-to-split behavior, and Ctrl+W close semantics
        // like every other center-hosted pane (Editor / Request / etc).
        let pane = Pane::IntegrationDetail(IntegrationDetailPane::new(id.to_string()));
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.reveal_pane(new_id);
        // Kick a README fetch if we don't already have one for this
        // id. Idempotent — cached `Text` / `NotFound` states short-
        // circuit here.
        self.spawn_readme_fetch(id);
    }

    /// Spawn a worker to fetch the README for `id`. Sources tried
    /// in order:
    ///   1. Installed integration's `repository` field → GitHub
    ///      raw README (falls back to `main`/`master`).
    ///   2. Marketplace app entries → `https://crates.io/api/v1/
    ///      crates/<id>/readme` (returns raw markdown).
    /// A cached `Loading`/`Text`/`NotFound` short-circuits the
    /// spawn so re-opens don't refetch.
    pub fn spawn_readme_fetch(&mut self, id: &str) {
        if self.readme_cache.contains_key(id) {
            return;
        }
        // Resolve the fetch source.
        let repo_url = self
            .config
            .ui
            .integration_icons
            .iter()
            .find(|i| i.id == id)
            .and_then(|i| i.repository.clone())
            .filter(|s| !s.trim().is_empty());
        let is_marketplace_app = self
            .marketplace_entries
            .iter()
            .find(|e| e.id == id)
            .is_some_and(|e| matches!(e.kind, crate::marketplace::MarketplaceKind::App));
        let source_id = id.to_string();
        self.readme_cache
            .insert(source_id.clone(), ReadmeState::Loading);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let state = fetch_readme_blocking(&source_id, repo_url.as_deref(), is_marketplace_app);
            let _ = tx.send((source_id, state));
        });
        self.readme_pending.push(rx);
    }

    pub fn drain_readme_fetches(&mut self) {
        let mut delivered: Vec<(String, ReadmeState)> = Vec::new();
        self.readme_pending.retain_mut(|rx| match rx.try_recv() {
            Ok(msg) => {
                delivered.push(msg);
                false
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => true,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => false,
        });
        for (id, state) in delivered {
            self.readme_cache.insert(id, state);
        }
    }
}

fn fetch_readme_blocking(
    id: &str,
    repo_url: Option<&str>,
    is_marketplace_app: bool,
) -> ReadmeState {
    let client = reqwest::blocking::Client::builder()
        // crates.io rejects generic user-agents with 403. Follows the
        // "App (contact)" convention documented in their crawler policy.
        .user_agent(format!(
            "mnml/{} (https://github.com/chris-mclennan/mnml)",
            env!("CARGO_PKG_VERSION")
        ))
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .ok();
    let Some(client) = client else {
        return ReadmeState::NotFound;
    };
    // Path A: GitHub repository — try raw README.md on main then
    // master. Only handles github.com URLs; other hosts fall
    // through to NotFound.
    if let Some(url) = repo_url
        && let Some(rest) = url
            .trim_end_matches('/')
            .strip_prefix("https://github.com/")
    {
        for branch in ["main", "master"] {
            let raw = format!("https://raw.githubusercontent.com/{rest}/{branch}/README.md");
            if let Ok(resp) = client.get(&raw).send()
                && resp.status().is_success()
                && let Ok(body) = resp.text()
                && !body.is_empty()
            {
                return ReadmeState::Text(body);
            }
        }
    }
    // Path B: crates.io app fallback. The `/readme` endpoint requires
    // a version segment (crates.io returns 400 without it), so we
    // fetch the crate metadata first to get `max_stable_version` +
    // `repository`, then try:
    //   1. github raw README.md on main / master (repo root)
    //   2. github raw apps/<id>/README.md (monorepo pattern —
    //      mnml-integrations layout)
    //   3. versioned crates.io /readme endpoint as last resort
    // 2026-08-06: was the version-less `/readme` URL which always
    // 400'd, so marketplace-only entries silently rendered without
    // their README.
    if is_marketplace_app {
        let meta_url = format!("https://crates.io/api/v1/crates/{id}");
        let (repo, version) = client
            .get(&meta_url)
            .send()
            .ok()
            .and_then(|r| r.text().ok())
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
            .map(|v| {
                let c = v.get("crate").cloned().unwrap_or_default();
                (
                    c.get("repository")
                        .and_then(|s| s.as_str())
                        .map(String::from),
                    c.get("max_stable_version")
                        .and_then(|s| s.as_str())
                        .map(String::from),
                )
            })
            .unwrap_or((None, None));
        // Build a candidate list. If the crate's declared `repository`
        // parses to a github repo, try that first; then always fall
        // back to the mnml-integrations monorepo `apps/<id>/README.md`
        // path for `mnml-*` crates (a lot of them declare a
        // split-out repo that 404s — the monorepo path is the
        // authoritative source). This keeps us on the RAW MARKDOWN
        // path so ASCII-art code blocks and fenced sections render
        // clean, instead of falling through to the crates.io HTML
        // `/readme` endpoint which mangles alignment on strip.
        // 2026-08-07 — user reported "text-based depictions of the
        // apps look bad".
        let mut candidates: Vec<String> = Vec::new();
        if let Some(url) = repo
            && let Some(rest) = url
                .trim_end_matches('/')
                .strip_prefix("https://github.com/")
        {
            for branch in ["main", "master"] {
                candidates.push(format!(
                    "https://raw.githubusercontent.com/{rest}/{branch}/README.md"
                ));
                candidates.push(format!(
                    "https://raw.githubusercontent.com/{rest}/{branch}/apps/{id}/README.md"
                ));
                candidates.push(format!(
                    "https://raw.githubusercontent.com/{rest}/{branch}/{id}/README.md"
                ));
            }
        }
        if id.starts_with("mnml-") {
            for branch in ["main", "master"] {
                candidates.push(format!(
                    "https://raw.githubusercontent.com/chris-mclennan/mnml-integrations/{branch}/apps/{id}/README.md"
                ));
            }
        }
        for raw in candidates {
            if let Ok(resp) = client.get(&raw).send()
                && resp.status().is_success()
                && let Ok(body) = resp.text()
                && !body.is_empty()
            {
                return ReadmeState::Text(body);
            }
        }
        if let Some(v) = version {
            let versioned = format!("https://crates.io/api/v1/crates/{id}/{v}/readme");
            if let Ok(resp) = client.get(&versioned).send()
                && resp.status().is_success()
                && let Ok(body) = resp.text()
                && !body.is_empty()
            {
                // crates.io's `/readme` endpoint returns rendered
                // HTML (GitHub-flavored, with `<h1>`, `<p>`, `<pre>`,
                // `<a>`, etc.) — not raw markdown. Strip tags so the
                // pane renders readable prose instead of dumping tag
                // source. Not a real markdown renderer — that's a
                // separate follow-up.
                return ReadmeState::Text(strip_html_to_plain(&body));
            }
        }
    }
    ReadmeState::NotFound
}

/// Minimal HTML → plain-text stripper for the crates.io /readme
/// fallback. Removes tags, unescapes basic entities, and collapses
/// runs of whitespace. Not a full HTML parser — targets exactly the
/// GitHub-flavored markup that crates.io emits when it renders a
/// README to HTML: `<h1>`/`<h2>`/`<p>`/`<pre>`/`<code>`/`<a>`/`<li>`/
/// `<ol>`/`<ul>`/`<strong>`/`<em>`, plus `id=` / `class=` / `rel=` /
/// `aria-label=` attribute clutter.
fn strip_html_to_plain(html: &str) -> String {
    // Preserve block breaks: replace `<br>`/`</p>`/`</li>`/`</h*>`/
    // `</pre>` with a newline before dropping remaining tags.
    let with_breaks = {
        let re =
            regex::Regex::new(r"(?i)</p>|</li>|</h[1-6]>|</pre>|</div>|</blockquote>|<br\s*/?>")
                .ok();
        match re {
            Some(r) => r.replace_all(html, "\n").into_owned(),
            None => html.to_string(),
        }
    };
    // Drop every tag.
    let tagless = {
        let re = regex::Regex::new(r"<[^>]+>").ok();
        match re {
            Some(r) => r.replace_all(&with_breaks, "").into_owned(),
            None => with_breaks.clone(),
        }
    };
    // Unescape the entities crates.io/GitHub uses.
    let unescaped = tagless
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ");
    // Collapse runs of blank lines to at most 2, trim per-line
    // whitespace. Preserves single-line structure so headers /
    // paragraphs / list items sit apart.
    let mut out = String::with_capacity(unescaped.len());
    let mut blank_run = 0usize;
    for line in unescaped.lines() {
        let trimmed = line.trim_end();
        if trimmed.trim().is_empty() {
            blank_run += 1;
            if blank_run <= 2 {
                out.push('\n');
            }
        } else {
            blank_run = 0;
            out.push_str(trimmed);
            out.push('\n');
        }
    }
    out
}

impl App {
    /// Reveal an existing detail pane. Previously handled a right-
    /// panel branch; now that the detail pane lives in the center
    /// like any other pane, just delegate. (Kept the helper for
    /// callers instead of inlining `reveal_pane` at every open site.)
    fn reveal_or_bring_to_front(&mut self, pid: PaneId) {
        // Legacy: if a prior session left a copy of this pane in the
        // right panel, drop it there so we don't render twice — the
        // new center-hosted copy is the authoritative one.
        self.right_panel_panes.retain(|&p| p != pid);
        self.reveal_pane(pid);
    }

    /// #864 — snapshot the current in-memory rail order + persist
    /// via `discovery::persist_integration_icon_order`. Also
    /// updates the in-memory `integration_icon_order` field so
    /// subsequent renders + persists see the current order without
    /// waiting on a config reload. Called from every
    /// MoveIntegration{Up,Down,ToTop,ToBottom} handler.
    pub fn persist_integration_icon_order(&mut self) {
        let ids: Vec<String> = self
            .config
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.clone())
            .collect();
        self.config.ui.integration_icon_order.clone_from(&ids);
        if let Err(e) = crate::app::discovery::persist_integration_icon_order(&ids) {
            self.toast(format!("integration order: persist failed ({e})"));
        }
    }

    /// Flip enabled/disabled for the integration with `id`, toast,
    /// persist via `write_override_toml`. Same implementation as
    /// the right-click `ToggleIntegrationEnabled` handler — extracted
    /// so both call sites share behavior.
    ///
    /// #852 fix (2026-08-03) — used to route through
    /// `persist_integration_icons`, which writes
    /// `[[ui.integration_icon]]` blocks to config.toml. But since
    /// the 2026-08-01 config flip, `config::finalize` drops any
    /// raw entry whose id isn't in the pre-manifest builtin set
    /// (browser/claude_code/codex/http), so toggling any real
    /// marketplace-installed chip's enabled state silently
    /// evaporated on next launch. `write_override_toml` handles
    /// the manifest-backed case (writes `<id>.override.toml`) AND
    /// the no-base builtin case (promotes to an authored
    /// `<id>.toml`) — see da1ce2e3.
    pub fn toggle_integration_enabled_by_id(&mut self, id: &str) {
        let Some(slot_snapshot) = self
            .config
            .ui
            .integration_icons
            .iter_mut()
            .find(|i| i.id == id)
            .map(|slot| {
                slot.enabled = !slot.enabled;
                // 2026-08-06 — enabling defaults `in_palette_bar` to
                // true so the chip shows up on the top bar without
                // a second click. User can right-click "Hide from
                // top bar" to opt-out. Was: only `enabled` flipped
                // and any prior `in_palette_bar = false` (from a
                // stale slot) survived, so enabling did nothing
                // visible.
                if slot.enabled {
                    slot.in_palette_bar = true;
                }
                slot.clone()
            })
        else {
            return;
        };
        let now = slot_snapshot.enabled;
        self.toast(format!(
            "integration {id} {}",
            if now { "enabled" } else { "disabled" }
        ));
        if let Err(e) = crate::app::discovery::write_override_toml(&slot_snapshot) {
            self.toast(format!("integration: persist failed ({e})"));
        }
    }

    /// 2026-08-06 — flip `in_palette_bar` for `id` (top-bar
    /// visibility). Mirrors `toggle_integration_enabled_by_id`'s
    /// shape: mutate slot, snapshot, persist via
    /// `write_override_toml`. Toasts the new state.
    pub fn toggle_integration_palette_bar_by_id(&mut self, id: &str) {
        let Some(slot_snapshot) = self
            .config
            .ui
            .integration_icons
            .iter_mut()
            .find(|i| i.id == id)
            .map(|slot| {
                slot.in_palette_bar = !slot.in_palette_bar;
                slot.clone()
            })
        else {
            return;
        };
        let now = slot_snapshot.in_palette_bar;
        self.toast(format!(
            "integration {id} {} top bar",
            if now { "shown on" } else { "hidden from" }
        ));
        if let Err(e) = crate::app::discovery::write_override_toml(&slot_snapshot) {
            self.toast(format!("integration: persist failed ({e})"));
        }
    }

    /// Open the on-disk manifest for `id` in an editor pane. Prefers
    /// the workspace override (`<ws>/.mnml/integrations/<id>.toml`),
    /// falls back to the user manifest, else toasts a hint.
    /// Same logic as the right-click `ShowIntegrationManifest`
    /// handler — extracted for reuse from the detail pane's
    /// [Edit manifest] button.
    pub fn open_integration_manifest_by_id(&mut self, id: &str) {
        let ws_path = self
            .workspace
            .join(".mnml")
            .join("integrations")
            .join(format!("{id}.toml"));
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("."));
        let user_path = home
            .join(".config")
            .join("mnml")
            .join("integrations")
            .join(format!("{id}.toml"));
        if ws_path.exists() {
            self.open_path(&ws_path);
        } else if user_path.exists() {
            self.open_path(&user_path);
        } else {
            self.toast(format!(
                "no manifest file for `{id}` — it's a built-in default"
            ));
        }
    }

    /// Wrapper around `open_glyph_builder_for_edit_cp` that toasts on
    /// miss — used by the detail pane's [Bake glyph] button.
    pub fn open_glyph_builder_for_cp(&mut self, cp: u32) {
        if !self.open_glyph_builder_for_edit_cp(cp) {
            self.toast(format!("no glyph found for U+{cp:04X}"));
        }
    }

    /// Move the detail pane's button/link cursor by `delta`, clamped
    /// to the actionable-row count. Called from the pane keyboard
    /// handler for ↑ / ↓ / Tab / Shift+Tab.
    pub fn integration_detail_cursor_move(&mut self, delta: isize) {
        let Some(pid) = self.right_panel_active_pane_id().or(self.active) else {
            return;
        };
        let total = crate::ui::integration_detail_view::action_count(self, pid);
        if total == 0 {
            return;
        }
        let Some(Pane::IntegrationDetail(d)) = self.panes.get_mut(pid) else {
            return;
        };
        let new = (d.cursor as isize + delta).clamp(0, total as isize - 1) as usize;
        d.cursor = new;
    }

    /// Fire the currently-focused button/link — called from the
    /// pane keyboard handler for Enter / Space.
    pub fn integration_detail_fire_focused(&mut self) {
        let Some(pid) = self.right_panel_active_pane_id().or(self.active) else {
            return;
        };
        let Some(Pane::IntegrationDetail(d)) = self.panes.get(pid) else {
            return;
        };
        let action_idx = d.cursor;
        crate::ui::integration_detail_view::fire_action(self, pid, action_idx);
    }
}
