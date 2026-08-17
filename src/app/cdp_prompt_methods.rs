//! CDP prompt + clipboard helpers on `App` — the `add/edit/delete`
//! prompts and accept-handlers for LocalStorage / SessionStorage /
//! IndexedDB / Cookies rows, DOM-selector copy, screenshot + PDF
//! save-to-disk, and Request-pane response-body copy. The heavy
//! lifting (CDP protocol, keychain) lives in `cdp.rs`; this file
//! is the App-method surface.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// `ai.session_view` — open a live transcript mirror for the active `Pane::Pty`'s
    /// session (a `claude` pane started by mnml, which knows its `--session-id`).
    pub fn open_session_view(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Pty(s)) => match &s.profile.session_id {
                Some(sid) => sid.clone(),
                None => {
                    self.toast("this terminal has no Claude session to mirror");
                    return;
                }
            },
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => {
                self.toast("open a Claude Code pane first (<leader>a c)");
                return;
            }
        };
        let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid) else {
            self.toast("can't locate the session transcript ($HOME unset?)");
            return;
        };
        // If we're already showing this session's mirror, just focus it.
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Ai(a) if a.is_live() && a.session_id == sid))
        {
            self.reveal_pane(i);
            return;
        }
        let pane = Pane::Ai(crate::ai::AiPane::live(sid, path));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    // ─── Playwright: test runner ────────────────────────────────────
    // ─── CDP browser pane ───────────────────────────────────────────
    /// `e` in the storage panel — open a prompt seeded with the
    /// selected entry's current value; accept ⇒ eval `setItem`.
    pub fn edit_selected_storage(&mut self) {
        let stash = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b
                .selected_storage()
                .map(|s| (s.is_local, s.key.clone(), s.value.clone())),
            _ => None,
        };
        let Some((is_local, key, value)) = stash else {
            self.toast("no storage entry selected");
            return;
        };
        let scope = if is_local { "local" } else { "session" };
        self.pending_storage_edit = Some((is_local, key.clone()));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserStorageEdit,
            format!("New value for {scope}.{key}"),
            value,
        ));
    }

    /// `a` in the storage panel — prompt for `local|key=value` or
    /// `session|key=value`. The scope prefix picks the storage; default
    /// is `local` if omitted.
    pub fn add_storage_prompt(&mut self) {
        if !matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Browser(_))
        ) {
            self.toast("no browser pane open");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserStorageAdd,
            "New entry (local|key=value or session|key=value)",
            "local|".to_string(),
        ));
    }

    /// `d` in the storage panel — eval `removeItem` for the selected
    /// entry. Drops the row locally; the `R` refresh confirms.
    pub fn delete_selected_storage(&mut self) {
        let stash = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_storage().map(|s| (s.is_local, s.key.clone())),
            _ => None,
        };
        let Some((is_local, key)) = stash else {
            self.toast("no storage entry selected");
            return;
        };
        let scope = if is_local {
            "localStorage"
        } else {
            "sessionStorage"
        };
        let expr = format!(
            "{}.removeItem({})",
            scope,
            serde_json::Value::String(key.clone())
        );
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.eval_silent(&expr);
            b.storage
                .retain(|s| !(s.is_local == is_local && s.key == key));
            if b.storage_sel >= b.storage.len() {
                b.storage_sel = b.storage.len().saturating_sub(1);
            }
        }
        self.toast(format!("deleted {key}"));
    }

    /// Accept handler for `BrowserStorageEdit` — eval `setItem` against
    /// the `(is_local, key)` stash with the new value. Refreshes the
    /// panel to show the update.
    pub fn accept_storage_edit(&mut self, new_value: String) {
        let Some((is_local, key)) = self.pending_storage_edit.take() else {
            return;
        };
        let scope = if is_local {
            "localStorage"
        } else {
            "sessionStorage"
        };
        let expr = format!(
            "{}.setItem({}, {})",
            scope,
            serde_json::Value::String(key.clone()),
            serde_json::Value::String(new_value),
        );
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.eval_silent(&expr);
            b.fetch_storage();
        }
        self.toast(format!("updated {key}"));
    }

    /// Accept handler for `BrowserStorageAdd` — parse
    /// `scope|key=value`; the scope (`local` / `session`) picks the
    /// storage, default `local`. A bare `key=value` (no `|`) goes to
    /// localStorage.
    pub fn accept_storage_add(&mut self, input: String) {
        let (scope, rest) = match input.split_once('|') {
            Some((s, r)) => (s.trim().to_lowercase(), r.to_string()),
            None => ("local".to_string(), input),
        };
        let (key, value) = match rest.split_once('=') {
            Some((k, v)) => (k.trim().to_string(), v.to_string()),
            None => (rest.trim().to_string(), String::new()),
        };
        if key.is_empty() {
            self.toast("storage key required");
            return;
        }
        let is_local = scope != "session";
        let storage = if is_local {
            "localStorage"
        } else {
            "sessionStorage"
        };
        let expr = format!(
            "{}.setItem({}, {})",
            storage,
            serde_json::Value::String(key.clone()),
            serde_json::Value::String(value),
        );
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.eval_silent(&expr);
            b.fetch_storage();
        }
        self.toast(format!("added {key}"));
    }

    /// `y` in the storage panel — copy the selected entry's
    /// `key=value` pair to the clipboard.
    pub fn copy_storage_key_value(&mut self) {
        let pair = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b
                .selected_storage()
                .map(|s| format!("{}={}", s.key, s.value)),
            _ => None,
        };
        match pair {
            Some(s) if !s.is_empty() => {
                self.clipboard.set(s, false);
                self.toast("copied storage entry");
            }
            _ => self.toast("no storage entry selected"),
        }
    }

    /// `c` in the storage panel — copy just the selected entry's value
    /// (no `key=` prefix). Common when the value is a JWT / token / ID
    /// the user wants to drop directly into code or a curl call.
    pub fn copy_storage_value_only(&mut self) {
        let value = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_storage().map(|s| s.value.clone()),
            _ => None,
        };
        match value {
            Some(v) if !v.is_empty() => {
                self.clipboard.set(v, false);
                self.toast("copied storage value");
            }
            Some(_) => self.toast("storage value is empty"),
            None => self.toast("no storage entry selected"),
        }
    }

    /// `e` in the cookies panel — open a prompt seeded with the
    /// selected cookie's current value; accept ⇒ `Network.setCookie`
    /// with the new value, keeping name + domain + path the same.
    pub fn edit_selected_cookie(&mut self) {
        let stash = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_cookie().map(|c| {
                (
                    c.name.clone(),
                    c.value.clone(),
                    c.domain.clone(),
                    c.path.clone(),
                )
            }),
            _ => None,
        };
        let Some((name, value, domain, path)) = stash else {
            self.toast("no cookie selected");
            return;
        };
        self.pending_cookie_edit = Some((name.clone(), domain, path));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::BrowserCookieEdit,
            format!("New value for {name}"),
            value,
        ));
    }

    /// `a` in the cookies panel — prompt for `name=value`; accept ⇒
    /// `Network.setCookie` scoped to the current page's domain (path
    /// `/`). Quick way to seed a session token for testing.
    pub fn add_cookie_prompt(&mut self) {
        if !matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Browser(_))
        ) {
            self.toast("no browser pane open");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::BrowserCookieAdd,
            "New cookie (name=value)",
        ));
    }

    /// Accept handler for `BrowserCookieEdit` — round-trip the new
    /// value through `Network.setCookie` for the `pending_cookie_edit`
    /// stash. Refreshes the panel so the new value is visible.
    pub fn accept_cookie_edit(&mut self, new_value: String) {
        let Some((name, domain, path)) = self.pending_cookie_edit.take() else {
            return;
        };
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.set_cookie(&name, &new_value, &domain, &path);
            b.fetch_cookies();
        }
        self.toast(format!("updated cookie {name}"));
    }

    /// Accept handler for `BrowserCookieAdd` — parse `name=value` from
    /// the input; domain comes from the active pane's URL host. A bare
    /// name with no `=` adds an empty-value cookie (rare but legal).
    pub fn accept_cookie_add(&mut self, input: String) {
        let (name, value) = match input.split_once('=') {
            Some((n, v)) => (n.trim().to_string(), v.to_string()),
            None => (input.trim().to_string(), String::new()),
        };
        if name.is_empty() {
            self.toast("cookie name required");
            return;
        }
        let domain = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => crate::app::cdp::host_of_url(&b.url),
            _ => String::new(),
        };
        if let Some(Pane::Browser(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.set_cookie(&name, &value, &domain, "/");
            b.fetch_cookies();
        }
        self.toast(format!("added cookie {name}"));
    }

    /// `d` in the cookies panel — fire `Network.deleteCookies` for the
    /// selected cookie. The row is dropped optimistically (the actual
    /// reply is fire-and-forget); the next `R` re-fetch confirms with
    /// the browser. Toast the cookie's name on success.
    pub fn delete_selected_cookie(&mut self) {
        let name = match self.active.and_then(|i| self.panes.get_mut(i)) {
            Some(Pane::Browser(b)) => b.delete_selected_cookie(),
            _ => None,
        };
        match name {
            Some(n) => self.toast(format!("deleted cookie {n}")),
            None => self.toast("no cookie selected"),
        }
    }

    /// `y` in the cookies panel — copy the selected cookie's
    /// `name=value` pair to the clipboard.
    pub fn copy_cookie_name_value(&mut self) {
        let pair = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b
                .selected_cookie()
                .map(|c| format!("{}={}", c.name, c.value)),
            _ => None,
        };
        match pair {
            Some(s) if !s.is_empty() => {
                self.clipboard.set(s, false);
                self.toast("copied cookie");
            }
            _ => self.toast("no cookie selected"),
        }
    }

    /// `c` in the cookies panel — copy just the selected cookie's value
    /// (no `name=` prefix). Common when the value is a session token / JWT
    /// the user wants to paste directly into code or another tool.
    pub fn copy_cookie_value_only(&mut self) {
        let value = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_cookie().map(|c| c.value.clone()),
            _ => None,
        };
        match value {
            Some(v) if !v.is_empty() => {
                self.clipboard.set(v, false);
                self.toast("copied cookie value");
            }
            Some(_) => self.toast("cookie value is empty"),
            None => self.toast("no cookie selected"),
        }
    }

    /// `c` in the browser pane's DOM panel — copy the selected node's CSS-ish
    /// selector to the clipboard.
    pub fn copy_dom_selector(&mut self) {
        let sel = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_dom().map(|r| r.selector.clone()),
            _ => None,
        };
        match sel {
            Some(s) if !s.is_empty() => {
                self.clipboard.set(s, false);
                self.toast("copied selector");
            }
            _ => self.toast("no selector for the highlighted row"),
        }
    }

    /// Decode a base64 PNG (from `Page.captureScreenshot`), write it under
    /// `<workspace>/.mnml/screenshots/shot-<millis>.png`, and hand it to the OS's
    /// default image viewer (best-effort). Returns the path.
    pub(crate) fn save_screenshot_png(&self, b64: &str) -> Result<std::path::PathBuf, String> {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|e| format!("base64 decode: {e}"))?;
        let dir = self.workspace.join(".mnml").join("screenshots");
        std::fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let path = dir.join(format!("shot-{millis}.png"));
        std::fs::write(&path, &bytes).map_err(|e| format!("writing {}: {e}", path.display()))?;
        // Hand the PNG to the OS's default image viewer — best-effort, errors
        // ignored (no viewer available is fine, the file is already on disk).
        open_path_external(&path);
        Ok(path)
    }

    /// Decode a base64 PDF (from `Page.printToPDF`), write it under
    /// `<workspace>/.mnml/screenshots/page-<millis>.pdf`, and hand it to the
    /// OS's default PDF viewer (best-effort). Returns the path. Same dir as
    /// the screenshot helper — "captures from the browser pane" all live in
    /// one place so they're easy to find.
    pub(crate) fn save_pdf_bytes(&self, b64: &str) -> Result<std::path::PathBuf, String> {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|e| format!("base64 decode: {e}"))?;
        let dir = self.workspace.join(".mnml").join("screenshots");
        std::fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let path = dir.join(format!("page-{millis}.pdf"));
        std::fs::write(&path, &bytes).map_err(|e| format!("writing {}: {e}", path.display()))?;
        open_path_external(&path);
        Ok(path)
    }

    // ─── HTTP: request pane ─────────────────────────────────────────
    /// `Y` in a request pane — copy the *response* body to the clipboard.
    pub fn copy_active_response_body(&mut self) {
        use crate::request_pane::RunState;
        let body = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => match &rp.state {
                RunState::Done(r) => Some(r.body.clone()),
                RunState::Sending => {
                    self.toast("wait for the response first");
                    return;
                }
                RunState::Streaming(r) => Some(r.body.clone()),
                RunState::Failed(_) => {
                    self.toast("no response — the request failed");
                    return;
                }
            },
            _ => None,
        };
        match body {
            Some(b) if !b.is_empty() => {
                self.clipboard.set(b, false);
                self.toast("copied response body");
            }
            Some(_) => self.toast("response body is empty"),
            None => self.toast("not a request pane"),
        }
    }
}
