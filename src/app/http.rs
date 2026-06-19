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

    /// `http.sync` — read `<workspace>/.mnml/sources.json` (or
    /// `<workspace>/.rqst/sources.json` for legacy workspaces) and
    /// regenerate `.curl` stub files for every `kind: "swagger"`
    /// source. Synchronous (fetches + writes happen on the UI
    /// thread); for large/slow sources we'd want a background
    /// thread + a trace pane like bench/chain. Phase 2 of the
    /// rqst→mnml port-back; 2026-06-19.
    pub fn http_sync_sources(&mut self) {
        let workspace = self.workspace.clone();
        match crate::http::sources::run_sync(&workspace) {
            Ok((_trace, total)) => {
                self.toast(format!(
                    "http.sync: wrote {total} request stub(s) — refresh the tree to see them"
                ));
                self.tree.refresh();
            }
            Err(e) => {
                self.toast(format!("http.sync failed: {e}"));
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
                    rp.state = RunState::Done(Box::new(rv));
                }
                Err(e) => {
                    toasts.push(format!("request failed: {e}"));
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
