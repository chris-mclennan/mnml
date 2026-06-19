//! HTTP send + `.http` / `.curl` / `.rest` file + request pane.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. Owns the `http.*` palette commands, the background HTTP
//! worker thread, request-pane multi-block writeback, and the
//! `splice_http_block` free fn.

use super::*;

/// Replace the named block inside an `.http` / `.rest` source with the
/// pre-rendered `new_block` text, leaving every other block untouched.
/// `name` is what `RequestPane.source_block_name` stored — `Some(s)` means
/// the matched block had `### s` (or `### ` alone when `s.is_empty()`); the
/// only `None` case here is a single-block file, which the caller handles
/// separately. Returns `None` when the file no longer parses as multi-block,
/// or no block matches — caller falls back to whole-file overwrite.
fn splice_http_block(existing: &str, name: Option<&str>, new_block: &str) -> Option<String> {
    let blocks = crate::http::file::parse_all(existing).ok()?;
    if blocks.len() < 2 {
        return None;
    }
    let lines: Vec<&str> = existing.split('\n').collect();
    // Resolve the `### name` separator on each block (`Block.name` is the text
    // after `###`; we also need to know whether the block had a separator at
    // all, since the leading block in a multi-block file doesn't).
    let block_separator_name = |b: &crate::http::file::Block| -> Option<String> {
        lines
            .get(b.start_line)
            .and_then(|l| l.trim_start().strip_prefix("###"))
            .map(|rest| rest.trim().to_string())
    };
    let target_idx = blocks.iter().position(|b| match name {
        // Match both "had a `###` separator" and the right name.
        Some(want) => block_separator_name(b).is_some_and(|n| n == want),
        // We only call this with `Some(name)` from the caller, but stay safe.
        None => block_separator_name(b).is_none(),
    })?;
    let target = &blocks[target_idx];
    let last_idx = lines.len().saturating_sub(1);
    let end = target.end_line.min(last_idx);
    // The replacement carries its own trailing newline (from `as_http_block`).
    // Trim it before splicing so the file's existing line structure isn't
    // double-newlined when we re-join.
    let replacement = new_block.trim_end_matches('\n');
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    out.extend(lines[..target.start_line].iter().map(|s| s.to_string()));
    for line in replacement.split('\n') {
        out.push(line.to_string());
    }
    if end < last_idx {
        out.extend(lines[end + 1..].iter().map(|s| s.to_string()));
    }
    let mut joined = out.join("\n");
    // Preserve the original file's trailing-newline policy.
    if existing.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    Some(joined)
}

/// Insert-or-replace a `KEY=VALUE` line in an `.env` file body.
/// Preserves comments + ordering of other keys. If `var` isn't
/// present, appends a new line. Used by the lookup picker's
/// final stage to write picked items to the active env file.
/// Errs only when a malformed value would corrupt the file.
fn upsert_env_var(existing: &str, var: &str, value: &str) -> Result<String, String> {
    if value.contains('\n') {
        return Err("lookup: value can't contain newline".into());
    }
    let mut replaced = false;
    let mut out = String::with_capacity(existing.len() + var.len() + value.len() + 8);
    for line in existing.lines() {
        let trimmed = line.trim_start();
        if !replaced
            && !trimmed.starts_with('#')
            && let Some((k, _)) = trimmed.split_once('=')
            && k.trim() == var
        {
            out.push_str(&format!("{var}={value}\n"));
            replaced = true;
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !replaced {
        if !out.ends_with('\n') && !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&format!("{var}={value}\n"));
    }
    Ok(out)
}

impl App {
    /// Right-click on the Request pane URL row — exposes copy-as-curl,
    /// re-fire, switch to Response view.
    pub fn open_request_url_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Send", MenuAction::Command("http.send")),
            MenuItem::new("Copy as curl", MenuAction::Command("http.copy_curl")),
            MenuItem::new(
                "Switch to Response",
                MenuAction::Command("http.toggle_view"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(Some("Request".into()), anchor, items));
    }

    /// `y` in the browser pane's network panel — copy the selected request as a
    /// curl command to the clipboard.
    pub fn copy_net_entry_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Browser(b)) => b.selected_net().map(crate::browser_pane::NetEntry::as_curl),
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no network request selected"),
        }
    }

    /// `Enter` in the browser pane's network panel — open the selected request in a
    /// `Pane::Request` (split below the browser) and re-send it.
    pub fn open_net_entry_as_request(&mut self) {
        let Some(cur) = self.active else { return };
        let request = match self.panes.get(cur) {
            Some(Pane::Browser(b)) => b
                .selected_net()
                .map(crate::browser_pane::NetEntry::to_request),
            _ => None,
        };
        let Some(request) = request else {
            self.toast("no network request selected");
            return;
        };
        let script = crate::http::script::Script::default();
        let job_id = self.spawn_http_job(request.clone(), script.clone());
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            None, request, script, job_id,
        ));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// `http.lookup` — open the lookup picker (stage 1: pick a
    /// `.curl` file under `<workspace>/.rqst/lookups/`). Subsequent
    /// stages — fire-request → pick-item → enter-var-name → write-
    /// to-env — are chained by the picker/prompt accept handlers.
    /// Phase 7 of the rqst→mnml port-back.
    pub fn http_lookup_open(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let dir = self.workspace.join(".rqst").join("lookups");
        let workspace = self.workspace.clone();
        let mut items: Vec<PickerItem> = Vec::new();
        if let Ok(read) = std::fs::read_dir(&dir) {
            for entry in read.flatten() {
                let path = entry.path();
                if path
                    .extension()
                    .and_then(|e| e.to_str())
                    .is_some_and(|e| matches!(e, "curl" | "http" | "rest"))
                {
                    let label = crate::http::lookup::relative_label(&path, &workspace);
                    items.push(PickerItem::new(
                        path.to_string_lossy().into_owned(),
                        label,
                        String::new(),
                    ));
                }
            }
        }
        if items.is_empty() {
            self.toast(format!(
                "no lookups in {} — add a `.curl` file under that dir",
                dir.display()
            ));
            return;
        }
        items.sort_by(|a, b| a.label.cmp(&b.label));
        self.open_picker(Picker::new(
            PickerKind::LookupFile,
            "Lookup file",
            items,
        ));
    }

    /// Accept handler for `PickerKind::LookupFile`. Spawns a
    /// background thread that fires the chosen `.curl` file as an
    /// HTTP request; on response, `App::tick`'s drain opens the
    /// `LookupItem` picker with parsed list rows.
    pub fn accept_lookup_file(&mut self, file_path: &std::path::Path) {
        use crate::http::{self, template::EnvSet};
        let text = match std::fs::read_to_string(file_path) {
            Ok(t) => t,
            Err(e) => {
                self.toast(format!("lookup: read {}: {e}", file_path.display()));
                return;
            }
        };
        let mut request = match http::parse(&text) {
            Ok(r) => r,
            Err(e) => {
                self.toast(format!("lookup: parse {}: {e}", file_path.display()));
                return;
            }
        };
        let script = http::script::parse(&text);
        let mut env = EnvSet::select(&self.workspace, None);
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in request.headers.iter_mut() {
            *v = http::template::expand(v, &env);
        }
        if let Some(body) = request.body.as_mut() {
            *body = http::template::expand(body, &env);
        }
        let file_label = crate::http::lookup::relative_label(file_path, &self.workspace);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let result = http::send(&request)
                .map(|r| (r.body, file_label.clone()))
                .map_err(|e| format!("lookup fire: {e}"));
            let _ = tx.send(result);
        });
        self.lookup_fire_rx = Some(rx);
        self.toast("lookup: firing request…");
    }

    /// Drain the in-flight lookup-fire result. On success, parses
    /// the response body for list items and opens the
    /// `PickerKind::LookupItem` picker. Called from `App::tick`.
    pub fn drain_lookup_fire_result(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let Some(rx) = self.lookup_fire_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok((body, label))) => {
                self.lookup_fire_rx = None;
                let Some(parsed) = crate::http::lookup::parse_items(&body) else {
                    self.toast(format!(
                        "lookup: {label} response wasn't a recognized list shape"
                    ));
                    return;
                };
                if parsed.is_empty() {
                    self.toast(format!("lookup: {label} returned 0 items"));
                    return;
                }
                let items: Vec<PickerItem> = parsed
                    .iter()
                    .enumerate()
                    .map(|(i, item)| {
                        PickerItem::new(
                            i.to_string(),
                            item.label.clone(),
                            item.id.clone(),
                        )
                    })
                    .collect();
                self.pending_lookup_items = parsed;
                self.open_picker(Picker::new(
                    PickerKind::LookupItem,
                    &format!("Lookup item · {label}"),
                    items,
                ));
            }
            Ok(Err(e)) => {
                self.lookup_fire_rx = None;
                self.toast(e);
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.lookup_fire_rx = None;
                self.toast("lookup: worker dropped");
            }
        }
    }

    /// Accept handler for `PickerKind::LookupItem`. Stashes the
    /// picked item's id into `pending_lookup_picked_id` and opens
    /// the var-name prompt.
    pub fn accept_lookup_item(&mut self, idx: usize) {
        let Some(item) = self.pending_lookup_items.get(idx).cloned() else {
            return;
        };
        self.pending_lookup_picked_id = Some(item.id.clone());
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::LookupVarName,
            format!("Env var name for {} ({}):", item.label, item.id),
        ));
    }

    /// Accept handler for `PromptKind::LookupVarName`. Writes
    /// `<var>=<id>` to `<workspace>/.rqst/env/<current>.env`
    /// (appending or replacing in place if the var exists), toasts
    /// the write.
    pub fn accept_lookup_var_name(&mut self, var: &str) {
        let var = var.trim();
        if var.is_empty() {
            self.toast("lookup: var name can't be empty");
            return;
        }
        let Some(id) = self.pending_lookup_picked_id.take() else {
            return;
        };
        let env_name = crate::http::template::EnvSet::select(&self.workspace, None)
            .name()
            .map(str::to_string)
            .unwrap_or_else(|| "dev".to_string());
        let env_path = self
            .workspace
            .join(".rqst")
            .join("env")
            .join(format!("{env_name}.env"));
        let existing = std::fs::read_to_string(&env_path).unwrap_or_default();
        let updated = match upsert_env_var(&existing, var, &id) {
            Ok(s) => s,
            Err(e) => {
                self.toast(format!("lookup: {e}"));
                return;
            }
        };
        if let Some(parent) = env_path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("lookup: mkdir {}: {e}", parent.display()));
            return;
        }
        match std::fs::write(&env_path, updated) {
            Ok(()) => self.toast(format!("wrote {var}={id} → {}", env_path.display())),
            Err(e) => self.toast(format!("lookup: write {}: {e}", env_path.display())),
        }
    }

    /// `http.capture_now` — append every NetEntry from the active
    /// browser pane into `<workspace>/.rqst/captured/log.jsonl`.
    /// The captured log persists across browser sessions so the
    /// user can review or re-fire entries later. Phase 4 of the
    /// rqst→mnml port-back.
    pub fn http_capture_browser_net_to_log(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.capture_now: no active pane");
            return;
        };
        let entries: Vec<crate::http::captured::CapturedRow> = match self.panes.get(cur) {
            Some(Pane::Browser(b)) => {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                b.net
                    .iter()
                    .map(|n| crate::http::captured::CapturedRow {
                        at: now,
                        request_id: n.request_id.clone(),
                        method: n.method.clone(),
                        url: n.url.clone(),
                        headers: n.headers.clone(),
                        body: n.post_data.clone(),
                        paused: false,
                    })
                    .collect()
            }
            _ => {
                self.toast("http.capture_now: needs an active browser pane");
                return;
            }
        };
        if entries.is_empty() {
            self.toast("http.capture_now: browser pane has no network entries yet");
            return;
        }
        let log_path = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join("log.jsonl");
        if let Some(parent) = log_path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("http.capture_now: mkdir {}: {e}", parent.display()));
            return;
        }
        let count = entries.len();
        let mut written = 0;
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            Ok(mut f) => {
                use std::io::Write;
                for row in &entries {
                    if let Ok(line) = serde_json::to_string(row) {
                        if f.write_all(line.as_bytes()).is_ok()
                            && f.write_all(b"\n").is_ok()
                        {
                            written += 1;
                        }
                    }
                }
                self.toast(format!(
                    "http.capture_now: wrote {written}/{count} entries to {}",
                    log_path.display()
                ));
            }
            Err(e) => self.toast(format!("http.capture_now: open {}: {e}", log_path.display())),
        }
    }

    /// `http.view_captured` — load `.rqst/captured/log.jsonl` and
    /// open a picker over the entries. Enter opens the chosen row
    /// as a fresh `.curl` editor buffer (via `CapturedRow::to_curl`)
    /// so the user can fire it again. Phase 4 of the rqst→mnml
    /// port-back — replaces the v1 stub that just opened the JSONL
    /// file in an editor.
    pub fn open_http_captured_log(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let path = self
            .workspace
            .join(".rqst")
            .join("captured")
            .join("log.jsonl");
        let rows = crate::http::captured::load(&path);
        if rows.is_empty() {
            self.toast(format!(
                "http.view_captured: no entries at {} — run http.capture_now first",
                path.display()
            ));
            return;
        }
        let items: Vec<PickerItem> = rows
            .iter()
            .enumerate()
            .map(|(i, r)| {
                // Display: "METHOD short_url" (matching browser pane's
                // short_url convention — host + path, no scheme/query).
                let short = r
                    .url
                    .strip_prefix("https://")
                    .or_else(|| r.url.strip_prefix("http://"))
                    .unwrap_or(&r.url);
                let short = short.split(['?', '#']).next().unwrap_or(short);
                let detail = if r.body.as_deref().unwrap_or("").is_empty() {
                    String::new()
                } else {
                    format!("(body: {} bytes)", r.body.as_deref().unwrap().len())
                };
                PickerItem::new(i.to_string(), format!("{} {short}", r.method), detail)
            })
            .collect();
        self.pending_captured_rows = rows;
        self.open_picker(Picker::new(
            PickerKind::CapturedRows,
            "Captured requests",
            items,
        ));
    }

    /// `http.history` — load `.rqst/history.jsonl` and open a
    /// picker over the most recent 100 entries. Enter opens the
    /// chosen entry's method/URL as a `.curl` scratch buffer so
    /// the user can re-fire it. Phase 9 of the rqst→mnml
    /// port-back — replaces the v1 stub that just opened the file
    /// in an editor.
    pub fn open_http_history(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let workspace = self.workspace.clone();
        let rows = crate::http::history::tail(&workspace, 100);
        if rows.is_empty() {
            self.toast(format!(
                "http.history: no history yet at {}",
                workspace.join(".rqst").join("history.jsonl").display()
            ));
            return;
        }
        let items: Vec<PickerItem> = rows
            .iter()
            .enumerate()
            .rev()
            .map(|(i, v)| {
                let method = v
                    .get("method")
                    .and_then(|s| s.as_str())
                    .unwrap_or("?")
                    .to_string();
                let url = v
                    .get("url")
                    .and_then(|s| s.as_str())
                    .unwrap_or("")
                    .to_string();
                let status = v.get("status").and_then(|s| s.as_u64());
                let dur = v.get("duration_ms").and_then(|d| d.as_u64());
                let detail = match (status, dur) {
                    (Some(s), Some(d)) => format!("{s} · {d}ms"),
                    (Some(s), None) => format!("{s}"),
                    (None, Some(d)) => format!("FAILED · {d}ms"),
                    (None, None) => "FAILED".to_string(),
                };
                let short = url
                    .strip_prefix("https://")
                    .or_else(|| url.strip_prefix("http://"))
                    .unwrap_or(&url)
                    .split(['?', '#'])
                    .next()
                    .unwrap_or(&url)
                    .to_string();
                PickerItem::new(i.to_string(), format!("{method} {short}"), detail)
            })
            .collect();
        self.pending_history_rows = rows;
        self.open_picker(Picker::new(PickerKind::HistoryRows, "HTTP history", items));
    }

    /// `http.save_mock` — freeze the active Request pane's response
    /// to disk as a `<source>.curl.mock.json` sidecar. The mock
    /// captures status + status_text + headers + body so it can be
    /// re-served by `http.replay_mock` for offline review or
    /// canned-data testing. Phase 6 of the rqst→mnml port-back.
    pub fn http_save_active_response_as_mock(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.save_mock: no active pane");
            return;
        };
        let (source_path, mock) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(rp_path) = rp.source_path.as_ref() else {
                    self.toast("http.save_mock: pane has no source file path");
                    return;
                };
                let crate::request_pane::RunState::Done(rv) = &rp.state else {
                    self.toast("http.save_mock: response not ready yet");
                    return;
                };
                (
                    rp_path.clone(),
                    crate::http::mock::Mock {
                        status: rv.status,
                        status_text: rv.status_text.clone(),
                        headers: rv.headers.clone(),
                        body: rv.body.clone(),
                    },
                )
            }
            _ => {
                self.toast("http.save_mock: needs an active Request pane");
                return;
            }
        };
        let mock_path = crate::http::mock::sibling_path(&source_path);
        match crate::http::mock::save(&mock_path, &mock) {
            Ok(()) => self.toast(format!("saved mock → {}", mock_path.display())),
            Err(e) => self.toast(format!("http.save_mock: {e}")),
        }
    }

    /// `http.replay_mock` — load the active Request pane's sibling
    /// `.mock.json` and serve it as if it had been the live
    /// response. The pane's state flips to `Done` with the mock's
    /// status / headers / body — no network call. Phase 6 of the
    /// rqst→mnml port-back.
    pub fn http_replay_active_request_from_mock(&mut self) {
        let Some(cur) = self.active else {
            self.toast("http.replay_mock: no active pane");
            return;
        };
        let mock_path = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(p) = rp.source_path.as_ref() else {
                    self.toast("http.replay_mock: pane has no source file path");
                    return;
                };
                crate::http::mock::sibling_path(p)
            }
            _ => {
                self.toast("http.replay_mock: needs an active Request pane");
                return;
            }
        };
        let mock = match crate::http::mock::load(&mock_path) {
            Ok(m) => m,
            Err(e) => {
                self.toast(format!("http.replay_mock: {e}"));
                return;
            }
        };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.state = crate::request_pane::RunState::Done(Box::new(
                crate::request_pane::ResponseView {
                    status: mock.status,
                    status_text: mock.status_text,
                    headers: mock.headers,
                    body: mock.body,
                    elapsed: std::time::Duration::ZERO,
                    assertions: Vec::new(),
                    captures: Vec::new(),
                },
            ));
            rp.view = crate::request_pane::ViewMode::Response;
        }
        self.toast(format!("replayed mock ({})", mock_path.display()));
    }

    /// Parse the active editor as an HTTP request, expanding env
    /// vars from `.mnml/env/$MNML_ENV` (or `.rqst/env/`). Returns
    /// `None` when there's no active editor, it isn't a recognized
    /// HTTP file, or parsing/template expansion fails. Used by
    /// `http.bench` and similar one-off-request commands; the
    /// richer `send_request_from_active` path does full multi-block
    /// block-aware parsing for `.http` / `.rest`.
    fn parse_active_as_request(&mut self) -> Option<crate::http::Request> {
        use crate::http::{self, template::EnvSet};
        let cur = self.active?;
        // From a Request pane, just clone the in-flight request.
        if let Some(Pane::Request(rp)) = self.panes.get(cur) {
            return Some(rp.request.clone());
        }
        let (ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => return None,
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            return None;
        }
        let (mut request, script_src) = if matches!(ext.as_str(), "http" | "rest")
            && let Ok(blocks) = http::file::parse_all(&text)
        {
            let lines: Vec<&str> = text.split('\n').collect();
            let b = blocks
                .iter()
                .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                .unwrap_or(&blocks[0]);
            let src = lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n");
            (b.request.clone(), src)
        } else {
            match http::parse(&text) {
                Ok(r) => (r, text.clone()),
                Err(_) => return None,
            }
        };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select(&self.workspace, None);
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in request.headers.iter_mut() {
            *v = http::template::expand(v, &env);
        }
        if let Some(body) = request.body.as_mut() {
            *body = http::template::expand(body, &env);
        }
        Some(request)
    }

    /// `http.bench` — fire the active editor's request `n` times
    /// across `concurrency` worker threads, then write the summary
    /// trace to the clipboard and toast a one-liner. The full
    /// trace has the p50/p95/p99/max + status-class breakdown so
    /// the user can paste it into a buffer for inspection. Phase 5
    /// of the rqst→mnml port-back; 2026-06-19.
    ///
    /// Runs on a background thread (10 sequential 30-second
    /// reqwest calls = up to 5 minutes of frozen UI without
    /// this). `App::tick` drains the result channel.
    pub fn http_bench_active(&mut self, n: u32, concurrency: u32) {
        if self.http_bench_rx.is_some() {
            self.toast("http.bench already running");
            return;
        }
        let Some(req) = self.parse_active_as_request() else {
            self.toast("http.bench: no active .http/.curl/.rest editor");
            return;
        };
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let trace = crate::http::bench::run(&req, n, concurrency);
            let _ = tx.send(trace);
        });
        self.http_bench_rx = Some(rx);
        self.toast(format!("http.bench: firing {n}× ({concurrency} concurrent)…"));
    }

    /// Drain the in-flight `http.bench` result and surface it via
    /// toast + clipboard. Called from `App::tick`.
    pub fn drain_http_bench_result(&mut self) {
        let Some(rx) = self.http_bench_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(trace) => {
                self.http_bench_rx = None;
                // Pull the "bench summary" headline out for the
                // toast; full trace lands on the clipboard for the
                // user to inspect.
                let headline = trace
                    .lines()
                    .find(|l| l.trim_start().starts_with("bench summary"))
                    .unwrap_or("bench: complete")
                    .trim()
                    .to_string();
                self.clipboard.set(trace, false);
                self.toast(format!("{headline} (full trace → clipboard)"));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.http_bench_rx = None;
                self.toast("http.bench: worker dropped");
            }
        }
    }

    /// `jwt.decode` — decode the JWT currently on the clipboard
    /// (claims segment only — signature isn't verified, this is
    /// purely a display tool for tokens you already have). Toasts
    /// the headline claims (`sub`, `email`, `exp`) so a user can
    /// quickly check who/when a token is for. Phase 8 of the
    /// rqst→mnml port-back; 2026-06-19.
    pub fn jwt_decode_clipboard(&mut self) {
        let token = self.clipboard.text();
        if token.trim().is_empty() {
            self.toast("jwt.decode: clipboard is empty");
            return;
        }
        let Some(claims) = crate::jwt::decode(&token) else {
            self.toast("jwt.decode: not a valid JWT (3 dot-separated segments)");
            return;
        };
        let mut parts: Vec<String> = Vec::new();
        if let Some(sub) = claims.sub.as_deref() {
            parts.push(format!("sub={sub}"));
        }
        if let Some(email) = claims.email.as_deref() {
            parts.push(format!("email={email}"));
        }
        if let Some(exp) = claims.exp_display() {
            parts.push(format!("exp={exp}"));
        }
        if claims.is_expired() {
            parts.push("EXPIRED".into());
        }
        let msg = if parts.is_empty() {
            "jwt.decode: (token has no standard claims)".to_string()
        } else {
            format!("jwt: {}", parts.join(" · "))
        };
        self.toast(msg);
    }

    /// `auth.extract_bearer` — pull a bearer token out of arbitrary
    /// clipboard text (a paste of `Authorization: Bearer eyJ…` or
    /// just `Bearer eyJ…`, or the bare JWT itself). Writes the
    /// extracted token back to the clipboard so the user can paste
    /// it into an env file. Phase 8 of the rqst→mnml port-back.
    pub fn auth_extract_bearer_from_clipboard(&mut self) {
        let raw = self.clipboard.text();
        match crate::auth::extract_bearer_from_clipboard(&raw) {
            Some(token) => {
                let preview = if token.len() > 18 {
                    format!("{}…{}", &token[..6], &token[token.len() - 6..])
                } else {
                    token.clone()
                };
                self.clipboard.set(token, false);
                self.toast(format!("bearer: {preview} (copied)"));
            }
            None => {
                self.toast("auth.extract_bearer: no bearer token found");
            }
        }
    }

    /// `http.sync` — read `<workspace>/.mnml/sources.json` (or
    /// `<workspace>/.rqst/sources.json` for legacy workspaces) and
    /// regenerate `.curl` stub files for every `kind: "swagger"`
    /// source. Runs on a background thread (reqwest's blocking
    /// client has a 30-second per-request timeout; 6 sources ×
    /// 30s = potentially 3 minutes of frozen UI without this).
    /// `App::tick` drains the result channel + toasts. Reviewer-
    /// flagged 2026-06-19 — phase 2 of the rqst→mnml port-back.
    pub fn http_sync_sources(&mut self) {
        if self.http_sync_rx.is_some() {
            self.toast("http.sync already running");
            return;
        }
        let workspace = self.workspace.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let result = crate::http::sources::run_sync(&workspace);
            let _ = tx.send(result);
        });
        self.http_sync_rx = Some(rx);
        self.toast("http.sync: fetching swagger sources…");
    }

    /// Drain the in-flight `http.sync` result. Called from
    /// `App::tick`; no-op when nothing is pending or the worker
    /// hasn't responded yet.
    pub fn drain_http_sync_result(&mut self) {
        let Some(rx) = self.http_sync_rx.as_ref() else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok((_trace, total))) => {
                self.http_sync_rx = None;
                self.toast(format!(
                    "http.sync: wrote {total} request stub(s) — tree refreshed"
                ));
                self.tree.refresh();
            }
            Ok(Err(e)) => {
                self.http_sync_rx = None;
                self.toast(format!("http.sync failed: {e}"));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.http_sync_rx = None;
                self.toast("http.sync: worker dropped");
            }
        }
    }

    /// `http.send` — parse the active `.http`/`.rest`/`.curl` editor (the block
    /// under the cursor for multi-block `.http` files), expand `{{vars}}` against
    /// `.mnml/env/$MNML_ENV`, open a `Pane::Request` split, and fire the request
    /// on a background thread. `tick` delivers the response.
    pub fn send_request_from_active(&mut self) {
        use crate::http::{self, template::EnvSet};
        let Some(cur) = self.active else {
            self.toast("no active editor");
            return;
        };
        // From an existing request pane, `http.send` just re-fires it.
        if matches!(self.panes.get(cur), Some(Pane::Request(_))) {
            self.refire_request(cur);
            return;
        }
        let (path, ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.path.clone(),
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => {
                self.toast("not an editor");
                return;
            }
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            self.toast("http.send needs a .http / .rest / .curl file");
            return;
        }

        // Pick the request + the directive text. For `.http`/`.rest`, use the
        // block under the cursor; otherwise treat the whole buffer as one request.
        // `source_block_name` is captured iff the file is genuinely multi-block
        // (>1 parsed block) — single-block files round-trip through the simple
        // overwrite path on save.
        let (mut request, script_src, source_block_name): (http::Request, String, Option<String>) =
            if matches!(ext.as_str(), "http" | "rest")
                && let Ok(blocks) = http::file::parse_all(&text)
            {
                let lines: Vec<&str> = text.split('\n').collect();
                let b = blocks
                    .iter()
                    .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                    .unwrap_or(&blocks[0]);
                let src =
                    lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n");
                let block_name = if blocks.len() > 1 {
                    // Multi-block. `b.name` is `Some(s)` when the block had a
                    // `###` separator with text, `None` for the leading
                    // headerless block. Distinguish the two on save by
                    // remembering "no separator at all" vs "bare ###" — if the
                    // block's first line *is* `###`, store `Some("")`.
                    if lines
                        .get(b.start_line)
                        .is_some_and(|l| l.trim_start().starts_with("###"))
                    {
                        Some(b.name.clone().unwrap_or_default())
                    } else {
                        None
                    }
                } else {
                    None
                };
                (b.request.clone(), src, block_name)
            } else {
                match http::parse(&text) {
                    Ok(r) => (r, text.clone(), None),
                    Err(e) => {
                        self.toast(format!("can't parse request: {e}"));
                        return;
                    }
                }
            };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select(&self.workspace, None);
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in &mut request.headers {
            *v = http::template::expand(v, &env);
        }
        if let Some(b) = &mut request.body {
            *b = http::template::expand(b, &env);
        }

        let job_id = self.spawn_http_job(request.clone(), script.clone());
        let mut rp = crate::request_pane::RequestPane::new(path, request, script, job_id);
        rp.source_block_name = source_block_name;
        let new_id =
            self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, Pane::Request(rp));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-send the request a `Pane::Request` already holds (its `r` key / re-`http.send`).
    fn refire_request(&mut self, pane_id: PaneId) {
        // Apply edits from the Headers field (the editable buffer is the
        // source of truth in Edit mode — parse it back before sending).
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.commit_headers();
        }
        let (request, script) = match self.panes.get(pane_id) {
            Some(Pane::Request(rp)) => (rp.request.clone(), rp.script.clone()),
            _ => return,
        };
        let job_id = self.spawn_http_job(request, script);
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.job_id = job_id;
            rp.state = crate::request_pane::RunState::Sending;
            rp.scroll = 0;
        }
    }

    /// Allocate a job id, ensure the result channel exists, spawn the worker.
    fn spawn_http_job(
        &mut self,
        request: crate::http::Request,
        script: crate::http::script::Script,
    ) -> u64 {
        use crate::request_pane::ResponseView;
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .http_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        std::thread::spawn(move || {
            let result: Result<ResponseView, String> = (|| {
                let resp = crate::http::send(&request)?;
                let assertions = crate::http::script::run_assertions(
                    &script,
                    resp.status,
                    &resp.headers,
                    &resp.body,
                );
                let mut env = crate::http::template::EnvSet::empty();
                let captures = crate::http::script::apply_captures(
                    &script,
                    &resp.headers,
                    &resp.body,
                    &mut env,
                );
                Ok(ResponseView {
                    status: resp.status,
                    status_text: resp.status_text,
                    headers: resp.headers,
                    body: resp.body,
                    elapsed: resp.elapsed,
                    assertions,
                    captures,
                })
            })();
            let _ = tx.send((job_id, result));
        });
        job_id
    }

    /// `http.copy_curl` — copy the active request (in an editor: parse the buffer;
    /// in a request pane: the request it holds) to the clipboard as a curl command.
    pub fn copy_active_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => Some(rp.as_curl()),
            Some(Pane::Editor(b))
                if matches!(b.language_ext.as_deref(), Some("http" | "rest" | "curl")) =>
            {
                crate::http::parse(b.editor.text()).ok().map(|r| {
                    crate::request_pane::RequestPane::new(None, r, Default::default(), 0).as_curl()
                })
            }
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no request here to copy"),
        }
    }

    /// Deliver any completed background HTTP sends to their request panes.
    pub(super) fn drain_http_jobs(&mut self) {
        use crate::request_pane::RunState;
        let Some((_, rx)) = &self.http_chan else {
            return;
        };
        let done: Vec<HttpJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        let workspace = self.workspace.clone();
        for (job_id, result) in done {
            let Some(Pane::Request(rp)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Request(rp) if rp.job_id == job_id && matches!(rp.state, RunState::Sending)),
            ) else {
                continue;
            };
            match result {
                Ok(rv) => {
                    let failed = rv.assertions.iter().filter(|a| !a.passed).count();
                    let total = rv.assertions.len();
                    toasts.push(if total > 0 {
                        format!(
                            "← {} · {}/{} asserts passed",
                            rv.status,
                            total - failed,
                            total
                        )
                    } else {
                        format!("← {} {}", rv.status, rv.status_text)
                    });
                    // Phase 9 — append to .rqst/history.jsonl so
                    // grep/jq workflows AND the in-app `http.history`
                    // viewer see the request.
                    crate::http::history::append(
                        &workspace,
                        &crate::http::history::Entry {
                            method: &rp.request.method,
                            url: &rp.request.url,
                            status: Some(rv.status),
                            duration_ms: Some(rv.elapsed.as_millis()),
                            body_bytes: Some(rv.body.len()),
                            error: None,
                        },
                    );
                    rp.state = RunState::Done(Box::new(rv));
                }
                Err(e) => {
                    toasts.push(format!("request failed: {e}"));
                    // Failed sends still get a history entry so
                    // forensic queries can find them.
                    crate::http::history::append(
                        &workspace,
                        &crate::http::history::Entry {
                            method: &rp.request.method,
                            url: &rp.request.url,
                            status: None,
                            duration_ms: None,
                            body_bytes: None,
                            error: Some(&e),
                        },
                    );
                    rp.state = RunState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    /// `Ctrl+S` over the active `Pane::Request` — write the current request
    /// (with the in-pane edits applied) back to its source file as a curl
    /// command. Pane has no `source_path` ⇒ toast and bail.
    pub fn save_request_to_source(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.commit_headers();
        }
        // Snapshot the pane state in one pass so we can let go of the borrow
        // before any disk I/O.
        let (path, ext, source_block_name, curl_text, http_block) = match self.panes.get(cur) {
            Some(Pane::Request(rp)) => {
                let Some(p) = rp.source_path.clone() else {
                    self.toast("no source file to save to (re-fire is in-memory only)");
                    return;
                };
                let ext = p
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                (
                    p,
                    ext,
                    rp.source_block_name.clone(),
                    rp.as_curl(),
                    rp.as_http_block(rp.source_block_name.as_deref()),
                )
            }
            _ => return,
        };
        // Multi-block `.http` / `.rest` source: splice just that block in
        // place so the other blocks survive. If the splice can't find a
        // home for the edit (file was edited externally and the block we
        // sent from is gone) we refuse rather than overwrite — losing the
        // other blocks would be the worst possible outcome.
        if matches!(ext.as_str(), "http" | "rest") && source_block_name.is_some() {
            let existing = match std::fs::read_to_string(&path) {
                Ok(t) => t,
                Err(e) => {
                    self.toast(format!("save failed: {e}"));
                    return;
                }
            };
            let Some(new_text) =
                splice_http_block(&existing, source_block_name.as_deref(), &http_block)
            else {
                self.toast(
                    "can't locate the source block (file changed?) — re-fire from the editor to refresh",
                );
                return;
            };
            match std::fs::write(&path, &new_text) {
                Ok(()) => {
                    let rel = rel_path(&self.workspace, &path);
                    self.toast(format!("saved block → {rel}"));
                    self.git.refresh();
                }
                Err(e) => self.toast(format!("save failed: {e}")),
            }
            return;
        }
        // Single-block source (`.curl`, or `.http` whose only block is the
        // one we're saving): overwrite with the curl one-liner. Same as the
        // pre-multi-block behavior.
        match std::fs::write(&path, format!("{curl_text}\n")) {
            Ok(()) => {
                let rel = rel_path(&self.workspace, &path);
                self.toast(format!("saved request → {rel}"));
                self.git.refresh();
            }
            Err(e) => self.toast(format!("save failed: {e}")),
        }
    }
}

#[cfg(test)]
mod http_tests {
    use super::*;

    #[test]
    fn request_pane_save_writes_curl_back_to_source() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("hello.curl");
        std::fs::write(&src, "curl 'https://x/'\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Build a Request pane manually (no real HTTP send — we just want to
        // exercise the save-back path).
        let (cmd_tx, _cmd_rx) = std::sync::mpsc::channel::<crate::cdp::CdpCommand>();
        let _ = cmd_tx; // silence unused; we don't have a worker
        let req = crate::http::Request {
            method: "POST".into(),
            url: "https://example.test/v1".into(),
            headers: vec![("Accept".into(), "application/json".into())],
            body: Some(r#"{"q":1}"#.into()),
        };
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            Some(src.clone()),
            req,
            crate::http::script::Script::default(),
            1,
        ));
        app.panes.push(pane);
        app.active = Some(app.panes.len() - 1);
        app.save_request_to_source();
        let on_disk = std::fs::read_to_string(&src).unwrap();
        assert!(on_disk.contains("curl 'https://example.test/v1'"));
        // POST + --data-raw lets curl infer POST, so `-X POST` is omitted.
        assert!(on_disk.contains("Accept: application/json"));
        assert!(on_disk.contains(r#"--data-raw '{"q":1}'"#));
    }

    #[test]
    fn splice_http_block_preserves_other_blocks() {
        let src = "\
### one
GET https://example.com/one

### two
POST https://example.com/two
Content-Type: application/json

{\"a\": 1}

### three
GET https://example.com/three
";
        let new_two = "### two\nPUT https://example.com/two-EDITED\n";
        let out = splice_http_block(src, Some("two"), new_two).unwrap();
        // The other blocks survive verbatim.
        assert!(out.contains("### one\nGET https://example.com/one"));
        assert!(out.contains("### three\nGET https://example.com/three"));
        // The target block is the edited one, not the original.
        assert!(out.contains("PUT https://example.com/two-EDITED"));
        assert!(!out.contains("POST https://example.com/two"));
        // Trailing-newline policy preserved.
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn splice_http_block_returns_none_for_single_block() {
        let src = "GET https://example.com\n";
        let new_text = "### x\nPUT https://example.com\n";
        // Single-block file ⇒ caller falls back to whole-file overwrite.
        assert!(splice_http_block(src, Some("x"), new_text).is_none());
    }

    #[test]
    fn splice_http_block_returns_none_when_name_missing() {
        let src = "\
### a
GET https://example.com/a

### b
GET https://example.com/b
";
        // No block named "missing" ⇒ caller falls back to overwrite (which the
        // user would notice is destructive — better than silently editing the
        // wrong block).
        assert!(splice_http_block(src, Some("missing"), "### missing\nGET x\n").is_none());
    }

    #[test]
    fn splice_http_block_handles_unnamed_leading_block() {
        // The leading block in a multi-block .http file may not have a `###`
        // separator. Editing it shouldn't disturb the named blocks below.
        let src = "\
GET https://example.com/leading

### second
GET https://example.com/second
";
        // The unnamed leading block: matched with `Some(\"\")`? No — by the
        // capture rule it gets `None` (no `###` separator at all). The save
        // path won't reach `splice_http_block` for None, so this test
        // documents what `splice_http_block` does in case it's called: it
        // matches the block whose start_line has no `###` prefix.
        let new_text = "PUT https://example.com/leading-EDITED\n";
        let out = splice_http_block(src, None, new_text).unwrap();
        assert!(out.contains("PUT https://example.com/leading-EDITED"));
        assert!(out.contains("### second\nGET https://example.com/second"));
        assert!(!out.contains("GET https://example.com/leading\n"));
    }
}
