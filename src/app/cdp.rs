//! Chrome DevTools Protocol (CDP) + browser pane methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor.
//! Pure non-destructive move: no API
//! change. Owns the `browser.*` palette commands, the CDP event drain,
//! all browser sub-panel pickers (DOM / cookies / storage / perf /
//! targets / devices / URL history), the Chrome profile-dir resolver,
//! and the small free-fn parsers (`bbox_from_quad`, `cdp_short_url`,
//! etc.) the browser methods reach for.

use super::*;

/// A short text rendering of a CDP `RemoteObject` (console args, eval results).
fn cdp_remote_object_str(o: &serde_json::Value) -> String {
    if let Some(v) = o.get("value") {
        return match v {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        };
    }
    if let Some(u) = o
        .get("unserializableValue")
        .and_then(serde_json::Value::as_str)
    {
        return u.to_string();
    }
    if let Some(d) = o.get("description").and_then(serde_json::Value::as_str) {
        return d.to_string();
    }
    o.get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("?")
        .to_string()
}

/// True if a CDP `Network.*` event's resource `type` is worth showing in the
/// browser pane (the page + its data calls — not the asset firehose). `None`
/// (type absent) is treated as interesting (it's usually the main document).
fn cdp_resource_type_is_interesting(rtype: Option<&str>) -> bool {
    !matches!(
        rtype,
        Some(
            "Image"
                | "Media"
                | "Font"
                | "Stylesheet"
                | "Script"
                | "TextTrack"
                | "Manifest"
                | "Other"
                | "Prefetch"
                | "SignedExchange"
        )
    )
}

/// Shorten a URL for a log line: drop the scheme, keep `host/path` (no query),
/// truncate. (Cross-origin hosts are kept so it's clear; same-origin still shows
/// the host — fine for a one-line log.)
fn cdp_short_url(url: &str) -> String {
    let body = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let body = body.split(['?', '#']).next().unwrap_or(body);
    if body.chars().count() <= 70 {
        body.to_string()
    } else {
        let keep: String = body.chars().take(69).collect();
        format!("{keep}…")
    }
}

/// Extract just the host (no scheme, no port, no path) from a URL.
/// Returns empty when the URL has no recognizable host (e.g.
/// `about:blank`). Used by the cookie-add flow to scope a new cookie
/// to the active browser pane's origin.
pub(super) fn host_of_url(url: &str) -> String {
    let s = url
        .trim()
        .strip_prefix("https://")
        .or_else(|| url.trim().strip_prefix("http://"))
        .unwrap_or(url.trim());
    s.split(['/', '?', '#', ':'])
        .next()
        .unwrap_or("")
        .to_string()
}

/// `DOM.getBoxModel.content` is `[x1, y1, x2, y2, x3, y3, x4, y4]` — the
/// four corners of the node's content quad in viewport coords. Compute
/// the axis-aligned bounding box `(x, y, width, height)` we can hand
/// to `Page.captureScreenshot.clip`. Returns `None` when the array
/// isn't 8 numeric entries (off-screen / detached nodes can yield an
/// empty / shorter quad).
fn bbox_from_quad(q: &[serde_json::Value]) -> Option<(f64, f64, f64, f64)> {
    if q.len() != 8 {
        return None;
    }
    let mut nums = q.iter().map(|v| v.as_f64());
    let mut xs = [0.0_f64; 4];
    let mut ys = [0.0_f64; 4];
    for i in 0..4 {
        xs[i] = nums.next()??;
        ys[i] = nums.next()??;
    }
    let x_min = xs.iter().cloned().fold(f64::INFINITY, f64::min);
    let y_min = ys.iter().cloned().fold(f64::INFINITY, f64::min);
    let x_max = xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let y_max = ys.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    if !x_min.is_finite() || !y_min.is_finite() || !x_max.is_finite() || !y_max.is_finite() {
        return None;
    }
    Some((x_min, y_min, x_max - x_min, y_max - y_min))
}

/// Render a `Runtime.evaluate` reply (`{result:{result:<RemoteObject>, exceptionDetails?}}`) to text.
fn cdp_eval_result_text(v: &serde_json::Value) -> String {
    let res = v.get("result");
    if let Some(ex) = res.and_then(|r| r.get("exceptionDetails")) {
        let msg = ex
            .get("exception")
            .and_then(|e| e.get("description"))
            .and_then(serde_json::Value::as_str)
            .or_else(|| ex.get("text").and_then(serde_json::Value::as_str))
            .unwrap_or("exception");
        return format!("⚠ {}", msg.lines().next().unwrap_or(msg));
    }
    res.and_then(|r| r.get("result"))
        .map(cdp_remote_object_str)
        .unwrap_or_else(|| "undefined".to_string())
}

impl App {
    /// `browser.open` — prompt for a URL, then launch Chrome on it. Multiple
    /// browser panes can coexist; each gets its own CDP worker + (in
    /// `workspace` / `shared` modes) a per-pane sibling profile dir.
    pub fn open_browser_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserUrl,
            "Open URL in Chrome",
            "https://",
        ));
    }

    /// Resolve the `--user-data-dir` for Chrome based on the
    /// `[browser] profile_mode` config:
    /// * `"workspace"` (default) — `<workspace>/.mnml/chrome-profile/`.
    ///   Per-workspace, persists across mnml relaunches in the same
    ///   workspace.
    /// * `"shared"` — `$HOME/.mnml/chrome-profile/`. One profile across
    ///   every workspace; handy when you sign into the same services
    ///   from multiple repos.
    /// * `"ephemeral"` — a fresh `tempfile::tempdir()` per `open_browser`
    ///   call. Clean-slate for login testing; state vanishes when the
    ///   pane closes.
    fn chrome_profile_dir(&self) -> std::path::PathBuf {
        self.chrome_profile_dir_for_pane(0)
    }

    /// Same as [`Self::chrome_profile_dir`] but tagged with `pane_index`
    /// — when another browser pane is already running, the second + later
    /// opens land in a sibling dir (`-1`, `-2`, …) so Chrome doesn't refuse
    /// to start against a `--user-data-dir` that already has a process
    /// holding the lock. `pane_index == 0` ⇒ no suffix (the first / only
    /// pane keeps the existing single-pane path).
    fn chrome_profile_dir_for_pane(&self, pane_index: usize) -> std::path::PathBuf {
        let suffix = if pane_index == 0 {
            String::new()
        } else {
            format!("-{pane_index}")
        };
        match self.config.browser.profile_mode.as_str() {
            "shared" => match std::env::var_os("HOME").map(PathBuf::from) {
                Some(h) => h.join(".mnml").join(format!("chrome-profile{suffix}")),
                None => self
                    .workspace
                    .join(".mnml")
                    .join(format!("chrome-profile{suffix}")),
            },
            "ephemeral" => match tempfile::tempdir() {
                Ok(td) => {
                    // The TempDir RAII guard would delete the dir as
                    // soon as it dropped, but we need Chrome to outlive
                    // this fn. `into_path` keeps it on disk; the OS
                    // will clean it up next reboot, or the user can
                    // `:browser.wipe_profile` to drop it sooner.
                    td.keep()
                }
                Err(_) => self
                    .workspace
                    .join(".mnml")
                    .join("chrome-profile-ephemeral"),
            },
            _ => self
                .workspace
                .join(".mnml")
                .join(format!("chrome-profile{suffix}")),
        }
    }

    /// `browser.wipe_profile` — remove the workspace-scoped (or shared)
    /// Chrome profile dir so the next `browser.open` starts fresh.
    /// No-op in `ephemeral` mode (every open already starts fresh).
    /// Refuses to run while a browser pane is open (Chrome would have
    /// the files locked).
    pub fn wipe_browser_profile(&mut self) {
        if self.panes.iter().any(|p| matches!(p, Pane::Browser(_))) {
            self.toast("close the browser pane first — Chrome has the profile locked");
            return;
        }
        if self.config.browser.profile_mode == "ephemeral" {
            self.toast("profile_mode = ephemeral — every open already starts fresh");
            return;
        }
        let dir = self.chrome_profile_dir();
        if !dir.exists() {
            self.toast("no profile to wipe");
            return;
        }
        match std::fs::remove_dir_all(&dir) {
            Ok(_) => self.toast(format!("wiped {}", dir.display())),
            Err(e) => self.toast(format!("wipe failed: {e}")),
        }
    }

    /// Helper — returns the active pane as `Pane::Browser` if it is one.
    /// With multi-pane browsers, callers that used to do
    /// `panes.iter().find(|p| matches!(p, Pane::Browser(_)))` need to
    /// scope to the *focused* pane instead, or the wrong browser pane
    /// receives the operation.
    pub fn active_browser_mut(&mut self) -> Option<&mut crate::browser_pane::BrowserPane> {
        let idx = self.active?;
        match self.panes.get_mut(idx)? {
            Pane::Browser(b) => Some(b),
            _ => None,
        }
    }

    /// Immutable counterpart of [`Self::active_browser_mut`].
    pub fn active_browser(&self) -> Option<&crate::browser_pane::BrowserPane> {
        let idx = self.active?;
        match self.panes.get(idx)? {
            Pane::Browser(b) => Some(b),
            _ => None,
        }
    }

    /// Launch Chrome on `url` over CDP and open a `Pane::Browser` (split below).
    /// Multiple browser panes can coexist — each gets its own CDP worker +
    /// per-pane channels. The second + later panes (in `workspace` /
    /// `shared` profile modes) land in a sibling `chrome-profile-N` dir so
    /// Chrome doesn't refuse to start against an already-locked user-data-dir.
    pub fn open_browser(&mut self, url: &str) {
        let existing_browsers = self
            .panes
            .iter()
            .filter(|p| matches!(p, Pane::Browser(_)))
            .count();
        let url = url.trim().to_string();
        let (ev_tx, ev_rx) = std::sync::mpsc::channel::<crate::cdp::CdpEvent>();
        let (cmd_tx, cmd_rx) = std::sync::mpsc::channel::<crate::cdp::CdpCommand>();
        let profile_dir = self.chrome_profile_dir_for_pane(existing_browsers);
        let _ = std::fs::create_dir_all(&profile_dir);
        let headless = self.config.browser.headless;
        let (worker_url, worker_dir) = (url.clone(), profile_dir);
        std::thread::spawn(move || {
            crate::cdp::run_session(&worker_url, &worker_dir, headless, &ev_tx, &cmd_rx);
        });
        let mut browser_pane = crate::browser_pane::BrowserPane::with_channel(url, cmd_tx, ev_rx);
        // Re-apply the user's most-recent device-emulation preset so the
        // choice survives across `browser.open` calls (and mnml relaunches
        // via session.json). The commands queue on cmd_tx and the worker
        // dispatches them as soon as the CDP WS is up.
        if let Some(idx) = self.last_browser_device
            && idx < crate::browser_pane::DEVICE_PRESETS.len()
        {
            browser_pane.set_device(idx);
        }
        let pane = Pane::Browser(browser_pane);
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
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
    }

    /// `g` in a browser pane — prompt for a URL to navigate to (seeded with the
    /// current URL).
    pub fn browser_navigate_prompt(&mut self) {
        let url = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.url.clone(),
            _ => return,
        };
        let seed = if url.trim().is_empty() {
            "https://".to_string()
        } else {
            url
        };
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserNavigate,
            "Navigate to",
            seed,
        ));
    }

    /// `e` in a browser pane — prompt for JS to evaluate in the page.
    pub fn browser_eval_prompt(&mut self) {
        if !matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Browser(_))
        ) {
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::BrowserEval,
            "Eval JS in the page",
        ));
    }

    /// `r` in a browser pane — reload the page.
    pub fn browser_reload(&mut self) {
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.reload();
        }
    }

    /// `:browser.back` — `window.history.back()` via Runtime.evaluate.
    /// CDP doesn't expose Page.goBack directly; runtime eval is the
    /// portable path.
    pub fn browser_back(&mut self) {
        match self.active_browser_mut() {
            Some(b) => b.eval_silent("window.history.back()"),
            None => self.toast("browser.back: no browser pane focused"),
        }
    }

    /// `:browser.forward` — `window.history.forward()` via Runtime.evaluate.
    pub fn browser_forward(&mut self) {
        match self.active_browser_mut() {
            Some(b) => b.eval_silent("window.history.forward()"),
            None => self.toast("browser.forward: no browser pane focused"),
        }
    }

    /// `:browser.devtools` — open Chrome's DevTools UI for the
    /// currently-driven page. CDP doesn't expose "open DevTools UI"
    /// as a method (it's a Chrome UI concern, not a protocol one),
    /// so we resolve the target's WebSocket debugger URL via the
    /// HTTP introspection endpoint (`/json`) and shell-out `open`
    /// (macOS) / `xdg-open` (Linux) to launch DevTools in the
    /// user's existing Chrome window. Falls back to a toast hint
    /// when introspection fails (no debugger port, etc.).
    pub fn browser_open_devtools_hint(&mut self) {
        let port = match self.active_browser_mut() {
            Some(b) => b.debugger_port,
            None => {
                self.toast("browser.devtools: no browser pane focused");
                return;
            }
        };
        let Some(port) = port else {
            self.toast("browser.devtools: no debugger port — open via :browser.open");
            return;
        };
        let cur_url = match self.active_browser_mut() {
            Some(b) => b.url.clone(),
            None => String::new(),
        };
        // Walk /json/list for the target whose `url` matches ours,
        // grab its devtoolsFrontendUrl, hand it to `open` (macOS) /
        // `xdg-open` (linux) to launch DevTools in Chrome itself.
        std::thread::spawn(move || {
            let json_url = format!("http://localhost:{port}/json/list");
            let Ok(resp) = reqwest::blocking::get(json_url) else {
                return;
            };
            let Ok(body) = resp.text() else { return };
            let Ok(targets) = serde_json::from_str::<serde_json::Value>(&body) else {
                return;
            };
            let arr = match targets.as_array() {
                Some(a) => a,
                None => return,
            };
            let target = arr
                .iter()
                .find(|t| {
                    t.get("url").and_then(|u| u.as_str()) == Some(cur_url.as_str())
                })
                .or_else(|| arr.first());
            let Some(t) = target else { return };
            let Some(dt_url) = t
                .get("devtoolsFrontendUrl")
                .and_then(|u| u.as_str())
            else {
                return;
            };
            let full = if dt_url.starts_with("http") {
                dt_url.to_string()
            } else {
                format!("http://localhost:{port}{dt_url}")
            };
            #[cfg(target_os = "macos")]
            let opener = "open";
            #[cfg(target_os = "linux")]
            let opener = "xdg-open";
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            let opener = "open";
            let _ = std::process::Command::new(opener).arg(&full).status();
        });
        self.toast("browser.devtools: launching…");
    }

    /// `:browser.copy_url` — copy the active browser pane's current
    /// URL to the system clipboard. Toasts when there's no browser
    /// pane focused.
    pub fn browser_copy_url(&mut self) {
        let url = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.url.clone(),
            _ => {
                self.toast("browser.copy_url: no browser pane focused");
                return;
            }
        };
        if url.trim().is_empty() {
            self.toast("browser.copy_url: pane has no URL yet");
            return;
        }
        self.clipboard.set(url.clone(), false);
        let short = url
            .strip_prefix("https://")
            .or_else(|| url.strip_prefix("http://"))
            .unwrap_or(&url);
        let short: String = short.chars().take(48).collect();
        self.toast(format!("browser: {short} → clipboard"));
    }

    /// `s` in a browser pane (or `browser.screenshot`) — capture the viewport;
    /// the PNG is written to `.mnml/screenshots/` when the reply arrives.
    pub fn browser_screenshot(&mut self) {
        match self.active_browser_mut() {
            Some(b) => b.screenshot(),
            None => self.toast("no browser pane open"),
        }
    }

    /// `p` in a browser pane (or `browser.print_pdf`) — render the current
    /// page as a PDF via `Page.printToPDF`; the file lands in
    /// `.mnml/screenshots/page-<ms>.pdf` when the reply arrives.
    pub fn browser_print_pdf(&mut self) {
        match self.active_browser_mut() {
            Some(b) => b.print_pdf(),
            None => self.toast("no browser pane open"),
        }
    }

    /// `browser.snapshot` — freeze the active browser pane's state
    /// (URL + network + cookies + storage) into [`BrowserPane::snapshots`].
    /// Always refreshes cookies + storage first so the snapshot
    /// captures the latest server state, not just what was cached the
    /// last time the panels were opened.
    pub fn browser_snapshot(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        // Trigger cookie + storage refresh — these are fire-and-forget
        // (their replies arrive async via the CDP channel). The
        // capture below uses whatever's already cached; the diff a
        // few seconds later will reflect any updates that landed.
        b.fetch_cookies();
        b.fetch_storage();
        let n = b.capture_snapshot();
        let label = b
            .snapshots
            .last()
            .map(|s| s.label.clone())
            .unwrap_or_default();
        self.toast(format!("snapshot #{n} captured at {label}"));
    }

    /// `browser.diff_snapshot` — open the diff panel comparing the
    /// most-recent snapshot against the current live state. Toggle
    /// off when already open. Toasts when there's no snapshot yet.
    pub fn browser_diff_snapshot(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        if b.snapshots.is_empty() {
            self.toast("no snapshot to diff against — capture one with browser.snapshot");
            return;
        }
        b.snapshot_diff_open = !b.snapshot_diff_open;
        b.snapshot_diff_scroll = 0;
    }

    /// `browser.clear_snapshots` — drop every captured snapshot for
    /// the active pane and close the diff panel.
    pub fn browser_clear_snapshots(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        let n = b.snapshots.len();
        b.snapshots.clear();
        b.snapshot_diff_open = false;
        self.toast(format!("cleared {n} snapshot(s)"));
    }

    /// `Z` in a browser pane's DOM panel (`browser.scroll_node_into_view`)
    /// — `DOM.scrollIntoViewIfNeeded` for the selected node. Brings an
    /// off-screen node into the viewport so subsequent `S` (screenshot)
    /// / `h` (highlight) gestures actually see the node. Fire-and-forget;
    /// no reply handling needed.
    pub fn browser_scroll_node_into_view(&mut self) {
        match self.active_browser_mut() {
            Some(b) => {
                if !b.dom_focus {
                    self.toast("scroll-into-view needs the DOM panel open (D)");
                    return;
                }
                if b.selected_dom().map(|r| r.node_id).unwrap_or(0) == 0 {
                    self.toast("no node selected");
                    return;
                }
                b.scroll_selected_dom_into_view();
                self.toast("scrolled node into view");
            }
            None => self.toast("no browser pane open"),
        }
    }

    /// `S` in a browser pane's DOM panel (`browser.screenshot_node`) —
    /// capture a screenshot clipped to the selected DOM node's bounding
    /// box. Two-step CDP flow under the hood: `DOM.getBoxModel` →
    /// `Page.captureScreenshot { clip }`. The eventual PNG lands in
    /// `.mnml/screenshots/` via the same path as a full-page screenshot.
    pub fn browser_screenshot_node(&mut self) {
        match self.active_browser_mut() {
            Some(b) => {
                if !b.dom_focus {
                    self.toast("node screenshot needs the DOM panel open (D)");
                    return;
                }
                if b.selected_dom().map(|r| r.node_id).unwrap_or(0) == 0 {
                    self.toast("no node selected");
                    return;
                }
                b.screenshot_selected_dom();
            }
            None => self.toast("no browser pane open"),
        }
    }

    /// `Ctrl+R` in a browser pane — fuzzy picker over the App-wide
    /// `browser_url_history`. Accept ⇒ `Page.navigate` the active
    /// browser pane to the chosen URL. The history accumulates from
    /// `Page.frameNavigated` events across the session and persists in
    /// session.json so previously-visited URLs are available on fresh
    /// launch.
    pub fn open_browser_history_picker(&mut self) {
        use crate::picker::PickerItem;
        if !matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Browser(_))
        ) {
            self.toast("no browser pane open");
            return;
        }
        if self.browser_url_history.is_empty() {
            self.toast("no browser history yet");
            return;
        }
        // Best-effort short label: host + path, mirroring the
        // network-panel `short_url` shape. Full URL kept as detail.
        let items: Vec<PickerItem> = self
            .browser_url_history
            .iter()
            .map(|u| {
                let short = u
                    .strip_prefix("https://")
                    .or_else(|| u.strip_prefix("http://"))
                    .unwrap_or(u)
                    .to_string();
                PickerItem::new(u.clone(), short, u.clone())
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::BrowserHistory,
            format!("Browser history ({})", self.browser_url_history.len()),
            items,
        ));
    }

    /// Accept handler for `PickerKind::BrowserHistory` — navigate the
    /// active browser pane to `url`. Empty / whitespace urls toast.
    pub fn browser_navigate_to(&mut self, url: &str) {
        let url = url.trim();
        if url.is_empty() {
            self.toast("history: empty URL");
            return;
        }
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.navigate(url);
        } else {
            self.toast("no browser pane open");
        }
    }

    /// `T` in the browser pane — open a picker over discovered CDP targets
    /// (main page + auto-attached popups / new tabs / iframes). Accept ⇒
    /// `browser.switch_target` routes subsequent commands there.
    pub fn open_browser_target_picker(&mut self) {
        use crate::picker::PickerItem;
        let Some(b) = self.active_browser() else {
            self.toast("no browser pane open");
            return;
        };
        if b.targets.len() <= 1 {
            self.toast("only one target (no popups / iframes attached)");
            return;
        }
        let items: Vec<PickerItem> = b
            .targets
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let star = if i == b.current_target { "● " } else { "  " };
                let label = if t.session_id.is_empty() {
                    format!("{star}main · {}", t.url)
                } else {
                    let title = if t.title.is_empty() {
                        "(no title)"
                    } else {
                        &t.title
                    };
                    format!("{star}{} · {title}", t.kind)
                };
                PickerItem::new(i.to_string(), label, t.url.clone())
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::BrowserTargets,
            format!("Browser targets ({})", b.targets.len()),
            items,
        ));
    }

    /// Accept handler for `PickerKind::BrowserTargets` — `idx` is parsed from
    /// `PickerItem.id`. Switches the active browser pane's current target.
    pub fn switch_browser_target(&mut self, idx: usize) {
        if let Some(b) = self.active_browser_mut() {
            b.switch_target(idx);
        }
    }

    /// `m` in a browser pane (or `browser.device_picker`) — open a picker
    /// over [`crate::browser_pane::DEVICE_PRESETS`] plus a top "Reset"
    /// entry. Accept ⇒ `browser_set_device` or `browser_clear_device`.
    pub fn open_browser_device_picker(&mut self) {
        use crate::picker::PickerItem;
        let Some(b) = self.active_browser() else {
            self.toast("no browser pane open");
            return;
        };
        let current = b.current_device;
        let mut items: Vec<PickerItem> =
            Vec::with_capacity(crate::browser_pane::DEVICE_PRESETS.len() + 1);
        let reset_star = if current.is_none() { "● " } else { "  " };
        items.push(PickerItem::new(
            "reset",
            format!("{reset_star}Reset — clear device emulation"),
            "real Chrome viewport",
        ));
        for (i, p) in crate::browser_pane::DEVICE_PRESETS.iter().enumerate() {
            let star = if current == Some(i) { "● " } else { "  " };
            let kind = if p.mobile { "mobile" } else { "desktop" };
            items.push(PickerItem::new(
                i.to_string(),
                format!("{star}{}", p.label),
                format!(
                    "{}×{} · {}× · {kind}",
                    p.width, p.height, p.device_scale_factor
                ),
            ));
        }
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::BrowserDevices,
            "Device emulation".to_string(),
            items,
        ));
    }

    /// Accept handler for the device picker (preset row). Applies the
    /// preset to the active browser pane (UA + viewport override).
    pub fn browser_set_device(&mut self, idx: usize) {
        match self.active_browser_mut() {
            Some(b) => {
                b.set_device(idx);
                if let Some(p) = crate::browser_pane::DEVICE_PRESETS.get(idx) {
                    let label = p.label.to_string();
                    let (w, h) = (p.width, p.height);
                    // Remember the choice so subsequent `browser.open` calls
                    // (in this session or after a relaunch via session.json)
                    // auto-apply it.
                    self.last_browser_device = Some(idx);
                    self.toast(format!("emulating: {label} ({w}×{h})"));
                }
            }
            None => self.toast("no browser pane open"),
        }
    }

    /// Accept handler for the device picker (Reset row). Clears any
    /// active device emulation on the active browser pane.
    pub fn browser_clear_device(&mut self) {
        match self.active_browser_mut() {
            Some(b) => {
                b.clear_device();
                self.last_browser_device = None;
                self.toast("device emulation cleared");
            }
            None => self.toast("no browser pane open"),
        }
    }

    /// `P` in a browser pane (or `browser.perf`) — fetch
    /// `performance.*` metrics via Runtime.evaluate if we haven't
    /// yet, and toggle into the perf panel. (`R` in the panel
    /// re-fetches.) Closes the other panels.
    pub fn browser_open_perf(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        if b.perf == crate::browser_pane::PerfMetrics::default() && b.pending_perf.is_none() {
            b.fetch_perf();
        }
        b.perf_focus = true;
        b.net_focus = false;
        b.dom_focus = false;
        b.cookies_focus = false;
        b.storage_focus = false;
    }

    /// `L` in a browser pane (or `browser.storage`) — fetch
    /// `localStorage` + `sessionStorage` via Runtime.evaluate if we
    /// haven't yet, and toggle into the Web Storage panel. (`R` in the
    /// panel re-fetches; `y` copies the selected `key=value`.) Closes
    /// the net / DOM / cookies panels if open.
    pub fn browser_open_storage(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        if b.storage.is_empty() && b.pending_storage.is_none() {
            b.fetch_storage();
        }
        b.storage_focus = true;
        b.net_focus = false;
        b.dom_focus = false;
        b.cookies_focus = false;
        b.storage_sel = b.storage_sel.min(b.storage.len().saturating_sub(1));
    }

    /// `K` in a browser pane (or `browser.cookies`) — fetch
    /// `Network.getCookies` if we haven't yet, and toggle into the
    /// cookies panel. (`R` in the panel re-fetches; `y` copies the
    /// selected `name=value`.) Closes the net + DOM panels if open.
    pub fn browser_open_cookies(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        if b.cookies.is_empty() && b.pending_cookies.is_none() {
            b.fetch_cookies();
        }
        b.cookies_focus = true;
        b.net_focus = false;
        b.dom_focus = false;
        b.storage_focus = false;
        b.cookies_sel = b.cookies_sel.min(b.cookies.len().saturating_sub(1));
    }

    /// `D` in a browser pane (or `browser.dom`) — fetch `DOM.getDocument` if we
    /// haven't yet, and toggle into the DOM panel. (`R` in the panel re-fetches.)
    pub fn browser_open_dom(&mut self) {
        let Some(b) = self.active_browser_mut() else {
            self.toast("no browser pane open");
            return;
        };
        if b.dom.is_empty() && b.pending_dom.is_none() {
            b.fetch_dom();
        }
        b.dom_focus = true;
        b.net_focus = false;
        b.cookies_focus = false;
        b.storage_focus = false;
        b.dom_sel = b.dom_sel.min(b.dom.len().saturating_sub(1));
    }

    /// Drain every browser pane's CDP worker event channel. Each pane owns
    /// its own `event_rx`; we walk the pane list, drain each receiver, then
    /// dispatch. Indices are captured up front so `apply_cdp_message`'s
    /// `idx` argument lines up with the pane that produced the event.
    pub(super) fn drain_cdp_events(&mut self) {
        let browser_idxs: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| matches!(p, Pane::Browser(_)).then_some(i))
            .collect();
        for idx in browser_idxs {
            // Collect events from this pane's receiver up front so the
            // borrow ends before apply_cdp_message takes `&mut self`.
            let events: Vec<crate::cdp::CdpEvent> = {
                let Some(Pane::Browser(b)) = self.panes.get(idx) else {
                    continue;
                };
                let mut events = Vec::new();
                while let Ok(ev) = b.event_rx.try_recv() {
                    events.push(ev);
                }
                events
            };
            for ev in events {
                match ev {
                    crate::cdp::CdpEvent::Connected { ws_url } => {
                        // Parse the debugger port out of
                        // `ws://localhost:PORT/devtools/page/…` so
                        // `:browser.devtools` can hit `/json/list`.
                        let port = ws_url
                            .strip_prefix("ws://")
                            .or_else(|| ws_url.strip_prefix("wss://"))
                            .and_then(|rest| rest.split_once('/'))
                            .and_then(|(host, _)| host.rsplit_once(':'))
                            .and_then(|(_, p)| p.parse::<u16>().ok());
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.debugger_port = port;
                            b.push(crate::browser_pane::LogKind::System, "connected to Chrome");
                        }
                    }
                    crate::cdp::CdpEvent::Message(v) => self.apply_cdp_message(idx, v),
                    crate::cdp::CdpEvent::Closed(reason) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.closed = true;
                            b.push(
                                crate::browser_pane::LogKind::System,
                                format!("session ended: {reason}"),
                            );
                        }
                    }
                }
            }
        }
    }

    /// Apply one raw CDP message (an event, or a reply to one of our requests) to
    /// the browser pane at `idx`.
    fn apply_cdp_message(&mut self, idx: usize, v: serde_json::Value) {
        use crate::browser_pane::LogKind;
        // A reply to a request we issued?
        if let Some(id) = v.get("id").and_then(serde_json::Value::as_i64) {
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_perf(id)) {
                let value = v
                    .get("result")
                    .and_then(|r| r.get("result"))
                    .and_then(|ro| ro.get("value"));
                let parsed = value
                    .map(crate::browser_pane::parse_perf_eval)
                    .unwrap_or_else(|| Err("no value in reply".to_string()));
                match parsed {
                    Ok(m) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.pending_perf = None;
                            b.perf = m;
                            b.push(LogKind::System, "performance loaded");
                        }
                    }
                    Err(e) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.pending_perf = None;
                            b.push(LogKind::ConsoleErr, format!("perf: {e}"));
                        }
                        self.toast(format!("perf: {e}"));
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_storage(id)) {
                // Web Storage eval reply (`L` panel). The result is a
                // `RemoteObject` with `type:'object', value:<obj>` —
                // already JSON-ified by `returnByValue:true`.
                let value = v
                    .get("result")
                    .and_then(|r| r.get("result"))
                    .and_then(|ro| ro.get("value"));
                let parsed = value
                    .map(crate::browser_pane::parse_storage_eval)
                    .unwrap_or_else(|| Err("no value in reply".to_string()));
                match parsed {
                    Ok(entries) => {
                        let n = entries.len();
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.pending_storage = None;
                            b.set_storage(entries);
                            b.push(LogKind::System, format!("storage loaded ({n} entries)"));
                        }
                    }
                    Err(e) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.pending_storage = None;
                            b.push(LogKind::ConsoleErr, format!("storage: {e}"));
                        }
                        self.toast(format!("storage: {e}"));
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_eval == Some(id)) {
                let text = cdp_eval_result_text(&v);
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_eval = None;
                    b.push(LogKind::Eval, format!("= {text}"));
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_screenshot == Some(id))
            {
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_screenshot = None;
                }
                let data = v
                    .get("result")
                    .and_then(|r| r.get("data"))
                    .and_then(serde_json::Value::as_str);
                match data.map(|d| self.save_screenshot_png(d)) {
                    Some(Ok(path)) => {
                        let p = path.display().to_string();
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::System, format!("screenshot → {p}"));
                        }
                        self.toast(format!("screenshot saved: {p}"));
                    }
                    Some(Err(e)) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, format!("screenshot failed: {e}"));
                        }
                        self.toast(format!("screenshot failed: {e}"));
                    }
                    None => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, "screenshot: empty reply from Chrome");
                        }
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_pdf(id)) {
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_pdf = None;
                }
                let data = v
                    .get("result")
                    .and_then(|r| r.get("data"))
                    .and_then(serde_json::Value::as_str);
                match data.map(|d| self.save_pdf_bytes(d)) {
                    Some(Ok(path)) => {
                        let p = path.display().to_string();
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::System, format!("pdf → {p}"));
                        }
                        self.toast(format!("pdf saved: {p}"));
                    }
                    Some(Err(e)) => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, format!("pdf failed: {e}"));
                        }
                        self.toast(format!("pdf failed: {e}"));
                    }
                    None => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(LogKind::ConsoleErr, "pdf: empty reply from Chrome");
                        }
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_node_screenshot(id))
            {
                // `DOM.getBoxModel` reply → parse content quad → compute
                // bbox → fire `Page.captureScreenshot` with `clip`.
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_node_screenshot = None;
                }
                let quad = v
                    .get("result")
                    .and_then(|r| r.get("model"))
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array());
                match quad.and_then(|q| bbox_from_quad(q)) {
                    Some((x, y, w, h)) if w > 0.0 && h > 0.0 => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.screenshot_clip(x, y, w, h);
                        }
                    }
                    _ => {
                        if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                            b.push(
                                LogKind::ConsoleErr,
                                "node screenshot: bbox unavailable (off-screen / display:none?)",
                            );
                        }
                        self.toast("node screenshot: bbox unavailable");
                    }
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_post_data(id)) {
                let data = v
                    .get("result")
                    .and_then(|r| r.get("postData"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.fill_post_data(id, data);
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.is_pending_cookies(id)) {
                let cookies = v
                    .get("result")
                    .and_then(|r| r.get("cookies"))
                    .map(crate::browser_pane::parse_cookies)
                    .unwrap_or_default();
                let n = cookies.len();
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_cookies = None;
                    b.set_cookies(cookies);
                    b.push(LogKind::System, format!("cookies loaded ({n} entries)"));
                }
                return;
            }
            if matches!(self.panes.get(idx), Some(Pane::Browser(b)) if b.pending_dom == Some(id)) {
                let rows = v
                    .get("result")
                    .and_then(|r| r.get("root"))
                    .map(crate::browser_pane::parse_dom)
                    .unwrap_or_default();
                let n = rows.len();
                if let Some(Pane::Browser(b)) = self.panes.get_mut(idx) {
                    b.pending_dom = None;
                    b.set_dom(rows);
                    b.push(LogKind::System, format!("DOM loaded ({n} rows)"));
                }
                return;
            }
            return;
        }
        let method = v
            .get("method")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let params = v.get("params");
        // URL captured during the match so we can push it onto the
        // App-wide `browser_url_history` after the `&mut b` borrow
        // ends. NLL drops `b` at last use, so the post-match write
        // compiles cleanly.
        let mut nav_url: Option<String> = None;
        // Same pattern for the new auto-capture-to-log path: the
        // match arms push (id, request-json) pairs here; we write
        // them to .rqst/captured/log.jsonl after the borrow ends.
        let mut autocapture_pending: Vec<(String, serde_json::Value)> = Vec::new();
        let Some(Pane::Browser(b)) = self.panes.get_mut(idx) else {
            return;
        };
        match method {
            "Runtime.consoleAPICalled" => {
                let typ = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("log");
                let text = params
                    .and_then(|p| p.get("args"))
                    .and_then(serde_json::Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(cdp_remote_object_str)
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .unwrap_or_default();
                let kind = if matches!(typ, "error" | "assert") {
                    LogKind::ConsoleErr
                } else {
                    LogKind::Console
                };
                b.push(kind, format!("console.{typ}: {text}"));
            }
            "Log.entryAdded" => {
                let entry = params.and_then(|p| p.get("entry"));
                let level = entry
                    .and_then(|e| e.get("level"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("info");
                let text = entry
                    .and_then(|e| e.get("text"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let kind = if level == "error" {
                    LogKind::ConsoleErr
                } else {
                    LogKind::Console
                };
                b.push(kind, format!("[{level}] {text}"));
            }
            "Runtime.exceptionThrown" => {
                let det = params.and_then(|p| p.get("exceptionDetails"));
                let msg = det
                    .and_then(|d| d.get("exception"))
                    .and_then(|e| e.get("description"))
                    .and_then(serde_json::Value::as_str)
                    .or_else(|| {
                        det.and_then(|d| d.get("text"))
                            .and_then(serde_json::Value::as_str)
                    })
                    .unwrap_or("exception");
                b.push(
                    LogKind::ConsoleErr,
                    format!("⚠ {}", msg.lines().next().unwrap_or(msg)),
                );
            }
            "Page.frameNavigated" => {
                let frame = params.and_then(|p| p.get("frame"));
                let is_main = frame.map(|f| f.get("parentId").is_none()).unwrap_or(false);
                if is_main
                    && let Some(url) = frame
                        .and_then(|f| f.get("url"))
                        .and_then(serde_json::Value::as_str)
                {
                    b.url = url.to_string();
                    nav_url = Some(url.to_string());
                    b.push(LogKind::Nav, format!("→ {url}"));
                    // DevTools' default: don't carry the prior page's
                    // network log + DOM into the new page. Mirrors the
                    // "Preserve log: off" Chrome default. Selections reset
                    // so the panels open at the top of the new page's data.
                    b.net.clear();
                    b.net_sel = 0;
                    b.dom.clear();
                    b.dom_sel = 0;
                }
            }
            "Target.targetCreated" => {
                let ti = params.and_then(|p| p.get("targetInfo"));
                let ty = ti
                    .and_then(|i| i.get("type"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                // The page we're driving fires this for itself (`attached:true`) — skip.
                let attached = ti
                    .and_then(|i| i.get("attached"))
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                if ty == "page" && !attached {
                    let url = ti
                        .and_then(|i| i.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("about:blank");
                    b.push(LogKind::Nav, format!("⤴ new tab → {url}"));
                }
            }
            "Target.attachedToTarget" => {
                // Multi-page: a popup / new tab / iframe auto-attached. Add
                // it to the pane's target list so the user can `T` to it.
                let session_id = params
                    .and_then(|p| p.get("sessionId"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let ti = params.and_then(|p| p.get("targetInfo"));
                if !session_id.is_empty()
                    && let Some(ti) = ti
                {
                    b.note_attached_target(session_id, ti);
                    let label = b
                        .targets
                        .last()
                        .map(|t| {
                            if t.title.is_empty() {
                                t.url.clone()
                            } else {
                                t.title.clone()
                            }
                        })
                        .unwrap_or_default();
                    b.push(LogKind::System, format!("attached → {label}"));
                }
            }
            "Target.targetInfoChanged" => {
                if let Some(ti) = params.and_then(|p| p.get("targetInfo")) {
                    b.note_target_info_changed(ti);
                }
            }
            "Target.detachedFromTarget" => {
                let session_id = params
                    .and_then(|p| p.get("sessionId"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if !session_id.is_empty() {
                    b.note_detached_target(session_id);
                    b.push(LogKind::System, "detached target".to_string());
                }
            }
            "Network.requestWillBeSent" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let req = params.and_then(|p| p.get("request"));
                    let method = req
                        .and_then(|r| r.get("method"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("GET");
                    let url = req
                        .and_then(|r| r.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    b.push(LogKind::Net, format!("→ {method} {}", cdp_short_url(url)));
                    if let (Some(id), Some(req)) = (
                        params
                            .and_then(|p| p.get("requestId"))
                            .and_then(serde_json::Value::as_str),
                        req,
                    ) {
                        b.note_net_request(id, req);
                        // Auto-capture: write the request to
                        // <workspace>/.rqst/captured/log.jsonl so the
                        // `:http.view_captured` picker reflects
                        // everything you've browsed, not just what
                        // you explicitly `:http.capture_now`-d. Config
                        // knob `[browser] autocapture_to_log` gates
                        // this; default on. 2026-06-19 user-requested
                        // — "rqst had this when you opened the browser."
                        autocapture_pending.push((id.to_string(), req.clone()));
                    }
                }
            }
            "Network.responseReceived" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let resp = params.and_then(|p| p.get("response"));
                    let status = resp
                        .and_then(|r| r.get("status"))
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(0);
                    let url = resp
                        .and_then(|r| r.get("url"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    b.push(LogKind::Net, format!("← {status} {}", cdp_short_url(url)));
                    if let Some(id) = params
                        .and_then(|p| p.get("requestId"))
                        .and_then(serde_json::Value::as_str)
                    {
                        let mime = resp
                            .and_then(|r| r.get("mimeType"))
                            .and_then(serde_json::Value::as_str);
                        b.note_net_response(id, status, mime);
                    }
                }
            }
            "Network.loadingFailed" => {
                let rtype = params
                    .and_then(|p| p.get("type"))
                    .and_then(serde_json::Value::as_str);
                if cdp_resource_type_is_interesting(rtype) {
                    let why = params
                        .and_then(|p| p.get("errorText"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("failed");
                    b.push(LogKind::ConsoleErr, format!("✗ request failed: {why}"));
                    if let Some(id) = params
                        .and_then(|p| p.get("requestId"))
                        .and_then(serde_json::Value::as_str)
                    {
                        b.note_net_failed(id, why);
                    }
                }
            }
            _ => {} // loadEventFired, snapshots, etc. — not mirrored here
        }
        if let Some(url) = nav_url {
            self.note_browser_url(url);
        }
        if !autocapture_pending.is_empty() && self.config.browser.autocapture_to_log {
            self.append_browser_autocapture(autocapture_pending);
        }
    }

    /// Append each pending request to
    /// `<workspace>/.rqst/captured/log.jsonl` as a `CapturedRow` so
    /// `:http.view_captured` reflects everything the browser pane
    /// has seen. Best-effort: ignores I/O errors so a write failure
    /// doesn't poison the CDP loop. Gated by `[browser]
    /// autocapture_to_log` (default on). 2026-06-19 — user-requested
    /// "rqst had a button that captured what the browser did, do
    /// the same for the in-app browser."
    fn append_browser_autocapture(&self, rows: Vec<(String, serde_json::Value)>) {
        use std::io::Write;
        let log_path = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join("log.jsonl");
        if let Some(parent) = log_path.parent()
            && std::fs::create_dir_all(parent).is_err()
        {
            return;
        }
        let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        else {
            return;
        };
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        for (request_id, req) in rows {
            let method = req
                .get("method")
                .and_then(|m| m.as_str())
                .unwrap_or("GET")
                .to_string();
            let url = req
                .get("url")
                .and_then(|u| u.as_str())
                .unwrap_or("")
                .to_string();
            let headers: Vec<(String, String)> = req
                .get("headers")
                .and_then(|h| h.as_object())
                .map(|obj| {
                    obj.iter()
                        .filter_map(|(k, v)| {
                            v.as_str().map(|s| (k.clone(), s.to_string()))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let body = req
                .get("postData")
                .and_then(|b| b.as_str())
                .map(str::to_string);
            let row = crate::http::captured::CapturedRow {
                at,
                request_id,
                method,
                url,
                headers,
                body,
                paused: false,
            };
            if let Ok(line) = serde_json::to_string(&row) {
                let _ = writeln!(f, "{line}");
            }
        }
    }

    /// Push `url` to the front of `browser_url_history` (de-duped),
    /// capping at [`BROWSER_URL_HISTORY_MAX`]. `about:blank` is skipped
    /// — it's the noisy initial state, not a real navigation target.
    /// Called from every main-frame `Page.frameNavigated`.
    pub fn note_browser_url(&mut self, url: String) {
        if url == "about:blank" || url.is_empty() {
            return;
        }
        self.browser_url_history.retain(|u| u != &url);
        self.browser_url_history.insert(0, url);
        if self.browser_url_history.len() > BROWSER_URL_HISTORY_MAX {
            self.browser_url_history.truncate(BROWSER_URL_HISTORY_MAX);
        }
    }

    /// Toggle CDP headless launch (`:set [no]headless`). Takes effect on the
    /// **next** `browser.open` — an in-flight browser pane is unaffected.
    pub fn set_browser_headless(&mut self, on: bool) {
        self.config.browser.headless = on;
        self.toast(if on {
            "browser: headless on (next open)"
        } else {
            "browser: headless off (next open)"
        });
    }

    pub fn toggle_browser_headless(&mut self) {
        self.set_browser_headless(!self.config.browser.headless);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn note_browser_url_dedupes_and_caps() {
        let mut h: Vec<String> = Vec::new();
        // Inline the same shape `note_browser_url` uses on App so we can
        // exercise the dedupe / cap logic without spinning up a full App.
        let push = |h: &mut Vec<String>, url: &str| {
            if url == "about:blank" || url.is_empty() {
                return;
            }
            h.retain(|u| u != url);
            h.insert(0, url.to_string());
            if h.len() > BROWSER_URL_HISTORY_MAX {
                h.truncate(BROWSER_URL_HISTORY_MAX);
            }
        };
        push(&mut h, "https://a.test/");
        push(&mut h, "https://b.test/");
        push(&mut h, "https://a.test/"); // move-to-front, dedupe
        assert_eq!(h, vec!["https://a.test/", "https://b.test/"]);

        // about:blank + empty are skipped.
        push(&mut h, "about:blank");
        push(&mut h, "");
        assert_eq!(h.len(), 2);

        // Cap enforced.
        for i in 0..BROWSER_URL_HISTORY_MAX + 10 {
            push(&mut h, &format!("https://h.test/{i}"));
        }
        assert_eq!(h.len(), BROWSER_URL_HISTORY_MAX);
        assert!(h[0].ends_with(&format!("/{}", BROWSER_URL_HISTORY_MAX + 9)));
    }

    #[test]
    fn bbox_from_quad_computes_axis_aligned_rect() {
        // A 100×40 rectangle anchored at (10, 20). Corners walk clockwise:
        // (10,20) → (110,20) → (110,60) → (10,60).
        let q = vec![
            json!(10.0),
            json!(20.0),
            json!(110.0),
            json!(20.0),
            json!(110.0),
            json!(60.0),
            json!(10.0),
            json!(60.0),
        ];
        let (x, y, w, h) = bbox_from_quad(&q).expect("bbox");
        assert_eq!(x, 10.0);
        assert_eq!(y, 20.0);
        assert_eq!(w, 100.0);
        assert_eq!(h, 40.0);
    }

    #[test]
    fn bbox_from_quad_handles_rotated_input() {
        // A 50×50 square rotated ~45° so the bbox is wider than either side.
        let q = vec![
            json!(50.0),
            json!(0.0),
            json!(100.0),
            json!(50.0),
            json!(50.0),
            json!(100.0),
            json!(0.0),
            json!(50.0),
        ];
        let (x, y, w, h) = bbox_from_quad(&q).expect("bbox");
        assert_eq!(x, 0.0);
        assert_eq!(y, 0.0);
        assert_eq!(w, 100.0);
        assert_eq!(h, 100.0);
    }

    #[test]
    fn bbox_from_quad_rejects_malformed_input() {
        // Shorter array
        assert!(bbox_from_quad(&[json!(1.0), json!(2.0)]).is_none());
        // Non-numeric entry
        let q = vec![
            json!(0.0),
            json!(0.0),
            json!(10.0),
            json!(0.0),
            json!("bad"),
            json!(10.0),
            json!(0.0),
            json!(10.0),
        ];
        assert!(bbox_from_quad(&q).is_none());
    }

    #[test]
    fn chrome_profile_dir_honors_mode() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        // workspace (default) ⇒ <workspace>/.mnml/chrome-profile
        let app = App::new(d.path().to_path_buf(), cfg.clone()).unwrap();
        let p = app.chrome_profile_dir();
        // App::new canonicalizes the workspace, so the workspace dir
        // in `app` is the canonical form of `d.path()`.
        let canon = d.path().canonicalize().unwrap();
        assert!(p.starts_with(&canon), "{p:?} should start with {canon:?}");
        assert!(p.ends_with("chrome-profile"));
        // ephemeral ⇒ a brand new dir per call, not under workspace
        cfg.browser.profile_mode = "ephemeral".to_string();
        let app = App::new(d.path().to_path_buf(), cfg.clone()).unwrap();
        let p1 = app.chrome_profile_dir();
        let p2 = app.chrome_profile_dir();
        assert_ne!(p1, p2, "ephemeral should hand back a fresh dir each call");
        // shared ⇒ under $HOME (when set)
        cfg.browser.profile_mode = "shared".to_string();
        // SAFETY: setting + restoring an env var in a serial test.
        let prior = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", "/tmp/mnml-test-home") };
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        let p = app.chrome_profile_dir();
        assert!(p.starts_with("/tmp/mnml-test-home"));
        match prior {
            Some(h) => unsafe { std::env::set_var("HOME", h) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }
}
