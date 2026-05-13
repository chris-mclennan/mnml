//! State for [`Pane::Browser`](crate::pane::Pane::Browser) — a Chrome the IDE is
//! driving over CDP (see [`crate::cdp`]). Holds the live log (console output, page
//! navigations, eval results), the current URL, and the command channel to the
//! worker; dropping the pane tells the worker to kill Chrome. Drawn by
//! `ui/browser_view.rs`; keys in `tui.rs`.

use std::sync::mpsc::Sender;

use crate::cdp::CdpCommand;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogKind {
    /// Our own status notes ("launching Chrome…", "connected", "session ended").
    System,
    /// `console.log` / `info` / `debug` / a `Log.entryAdded`.
    Console,
    /// `console.error` / `console.warn` / a page error.
    ConsoleErr,
    /// A page navigation.
    Nav,
    /// A network request / response (filtered to Document / XHR / Fetch).
    Net,
    /// An `eval` request line (`» expr`) or its result (`= value`).
    Eval,
}

#[derive(Debug, Clone)]
pub struct LogLine {
    pub kind: LogKind,
    pub text: String,
}

/// One network request captured from the page (Document / XHR / Fetch only — the
/// asset firehose is dropped). Built from `Network.requestWillBeSent`, then the
/// `status` / `mime` filled in by `Network.responseReceived`, or `failed` by
/// `Network.loadingFailed`. The selectable rows behind the `n` panel; `y` copies
/// one as a curl command, `Enter` re-sends it in a request pane.
#[derive(Debug, Clone)]
pub struct NetEntry {
    /// CDP `requestId` — to match the later response / failure event.
    pub request_id: String,
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub post_data: Option<String>,
    pub status: Option<i64>,
    pub mime: Option<String>,
    pub failed: Option<String>,
}

impl NetEntry {
    /// `host/path` with no scheme / query, truncated — for the panel row.
    pub fn short_url(&self) -> String {
        let body = self
            .url
            .strip_prefix("https://")
            .or_else(|| self.url.strip_prefix("http://"))
            .unwrap_or(&self.url);
        let body = body.split(['?', '#']).next().unwrap_or(body);
        if body.chars().count() <= 60 {
            body.to_string()
        } else {
            let keep: String = body.chars().take(59).collect();
            format!("{keep}…")
        }
    }

    /// `200` / `✗` / `…` — the status column for the panel row.
    pub fn status_text(&self) -> String {
        if self.failed.is_some() {
            "✗".to_string()
        } else if let Some(s) = self.status {
            s.to_string()
        } else {
            "…".to_string()
        }
    }

    /// Render this request as a `curl` command line (same shape as the request pane's).
    pub fn as_curl(&self) -> String {
        let mut out = format!("curl '{}'", self.url);
        if self.method != "GET" && !(self.method == "POST" && self.post_data.is_some()) {
            out.push_str(&format!(" -X {}", self.method));
        }
        for (k, v) in &self.headers {
            // Skip pseudo-headers (`:method`, `:authority`, …) curl rejects.
            if k.starts_with(':') {
                continue;
            }
            out.push_str(&format!(" \\\n  -H '{}: {}'", k, v.replace('\'', "'\\''")));
        }
        if let Some(body) = &self.post_data {
            out.push_str(&format!(
                " \\\n  --data-raw '{}'",
                body.replace('\'', "'\\''")
            ));
        }
        out
    }

    /// As an [`crate::http::Request`] — for opening in a `Pane::Request`.
    pub fn to_request(&self) -> crate::http::Request {
        crate::http::Request {
            method: self.method.clone(),
            url: self.url.clone(),
            headers: self
                .headers
                .iter()
                .filter(|(k, _)| !k.starts_with(':'))
                .cloned()
                .collect(),
            body: self.post_data.clone(),
        }
    }
}

/// One rendered row of a flattened `DOM.getDocument` tree — built by [`parse_dom`].
/// `selector` is a `tag#id.cls > tag.cls` chain back to the root (good enough to
/// paste into a `document.querySelector` or copy out as a hint).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomRow {
    pub depth: usize,
    pub label: String,
    pub selector: String,
    /// The CDP `nodeId` for this node (0 if absent / synthetic) — used by
    /// `Overlay.highlightNode` to draw a box around this element in the page.
    pub node_id: i64,
}

/// Walk the JSON `result.root` of a CDP `DOM.getDocument` reply (full-tree,
/// `depth:-1 pierce:true`) into a flat, indented list of [`DomRow`]s. Element /
/// text / doctype / comment nodes are kept (document wrappers transparently
/// recursed); whitespace-only text and CDP shadow-root markers are skipped.
pub fn parse_dom(root: &serde_json::Value) -> Vec<DomRow> {
    let mut out: Vec<DomRow> = Vec::new();
    fn truncate(s: &str, max: usize) -> String {
        if s.chars().count() <= max {
            s.to_string()
        } else {
            let keep: String = s.chars().take(max - 1).collect();
            format!("{keep}…")
        }
    }
    fn walk(node: &serde_json::Value, depth: usize, parent_sel: &str, out: &mut Vec<DomRow>) {
        let node_type = node
            .get("nodeType")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0);
        let node_id = node
            .get("nodeId")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0);
        match node_type {
            9 | 11 => {
                // DOCUMENT_NODE / DOCUMENT_FRAGMENT_NODE — recurse transparently.
                if let Some(kids) = node.get("children").and_then(serde_json::Value::as_array) {
                    for c in kids {
                        walk(c, depth, parent_sel, out);
                    }
                }
            }
            10 => {
                // DOCTYPE
                let name = node
                    .get("nodeName")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("html");
                out.push(DomRow {
                    depth,
                    label: format!("<!DOCTYPE {}>", name.to_ascii_lowercase()),
                    selector: parent_sel.to_string(),
                    node_id,
                });
            }
            8 => {
                // COMMENT
                let v = node
                    .get("nodeValue")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let one = v.lines().next().unwrap_or("").trim();
                if !one.is_empty() {
                    out.push(DomRow {
                        depth,
                        label: format!("<!-- {} -->", truncate(one, 80)),
                        selector: parent_sel.to_string(),
                        node_id,
                    });
                }
            }
            3 => {
                // TEXT_NODE — skip pure whitespace.
                let v = node
                    .get("nodeValue")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                let trimmed = v.split_whitespace().collect::<Vec<_>>().join(" ");
                if !trimmed.is_empty() {
                    out.push(DomRow {
                        depth,
                        label: format!("“{}”", truncate(&trimmed, 80)),
                        selector: parent_sel.to_string(),
                        node_id,
                    });
                }
            }
            1 => {
                let tag = node
                    .get("nodeName")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("?")
                    .to_ascii_lowercase();
                // attributes: `[name, value, name, value, …]` per CDP.
                let mut id_attr = String::new();
                let mut class_attr = String::new();
                let mut other: Vec<(String, String)> = Vec::new();
                if let Some(attrs) = node.get("attributes").and_then(serde_json::Value::as_array) {
                    let mut it = attrs.iter();
                    while let (Some(k), Some(v)) = (it.next(), it.next()) {
                        match (k.as_str(), v.as_str()) {
                            (Some("id"), Some(val)) => id_attr = val.to_string(),
                            (Some("class"), Some(val)) => class_attr = val.to_string(),
                            (Some(k), Some(val)) => other.push((k.to_string(), val.to_string())),
                            _ => {}
                        }
                    }
                }
                let mut sel = if parent_sel.is_empty() {
                    tag.clone()
                } else {
                    format!("{parent_sel} > {tag}")
                };
                if !id_attr.is_empty() {
                    sel.push('#');
                    sel.push_str(&id_attr);
                }
                for c in class_attr.split_whitespace() {
                    sel.push('.');
                    sel.push_str(c);
                }
                // The display label: `<tag id="…" class="…" …>` (first-3 attrs).
                let mut label = format!("<{tag}");
                if !id_attr.is_empty() {
                    label.push_str(&format!(" id=\"{}\"", truncate(&id_attr, 40)));
                }
                if !class_attr.is_empty() {
                    label.push_str(&format!(" class=\"{}\"", truncate(&class_attr, 40)));
                }
                for (k, v) in other.iter().take(2) {
                    label.push_str(&format!(" {k}=\"{}\"", truncate(v, 30)));
                }
                if other.len() > 2 {
                    label.push_str(&format!(" …{}", other.len() - 2));
                }
                label.push('>');
                out.push(DomRow {
                    depth,
                    label,
                    selector: sel.clone(),
                    node_id,
                });
                if let Some(kids) = node.get("children").and_then(serde_json::Value::as_array) {
                    for c in kids {
                        walk(c, depth + 1, &sel, out);
                    }
                }
                // contentDocument (iframe) — recurse into it too.
                if let Some(doc) = node.get("contentDocument") {
                    walk(doc, depth + 1, &sel, out);
                }
            }
            _ => {} // unsupported (processing-instruction, etc.)
        }
    }
    walk(root, 0, "", &mut out);
    out
}

/// One attached CDP target — the main page, an iframe, a popup / OAuth window.
/// Tracked in [`BrowserPane::targets`]; the user switches between them with
/// `T` and subsequent navigate / eval / reload route through that target's
/// session via the flatten-mode `sessionId` wire field.
#[derive(Debug, Clone)]
pub struct BrowserTarget {
    /// Empty for the main page (no sessionId needed); CDP `sessionId` otherwise.
    pub session_id: String,
    /// CDP `Target.targetId` (stable across navigations within the target).
    pub target_id: String,
    pub title: String,
    pub url: String,
    /// `"page"`, `"iframe"`, `"service_worker"`, `"shared_worker"`, …
    pub kind: String,
}

pub struct BrowserPane {
    /// The page's current URL (updated on `Page.frameNavigated`).
    pub url: String,
    /// Down-channel to the CDP worker (commands; `Drop` sends `Close`).
    pub cmd_tx: Sender<CdpCommand>,
    /// Attached targets — index 0 is the main page (always present); index 1+
    /// are popups / new tabs / iframes auto-attached via `Target.setAutoAttach`.
    pub targets: Vec<BrowserTarget>,
    /// Index into `targets` — which target subsequent commands route through.
    pub current_target: usize,
    pub log: Vec<LogLine>,
    /// Network requests (Document / XHR / Fetch), in arrival order.
    pub net: Vec<NetEntry>,
    /// True ⇒ the `n` network panel is showing (rows selectable instead of the log).
    pub net_focus: bool,
    /// Selected network row when `net_focus`.
    pub net_sel: usize,
    /// Flattened DOM rows (lazy — populated on the first `D` press, refreshed on `R`).
    pub dom: Vec<DomRow>,
    /// True ⇒ the `D` DOM panel is showing.
    pub dom_focus: bool,
    /// Selected DOM row when `dom_focus`.
    pub dom_sel: usize,
    /// Next JSON-RPC id for requests this pane issues.
    next_id: i64,
    /// The id of an in-flight `Runtime.evaluate`, so its reply can be matched.
    pub pending_eval: Option<i64>,
    /// The id of an in-flight `Page.captureScreenshot`, so its reply can be matched.
    pub pending_screenshot: Option<i64>,
    /// The id of an in-flight `DOM.getDocument`, so its reply can be matched.
    pub pending_dom: Option<i64>,
    /// Outstanding `Network.getRequestPostData` requests: `(rpc id, CDP requestId)`.
    pending_post_data: Vec<(i64, String)>,
    /// Top visible log row (`usize::MAX` ⇒ pinned to the bottom).
    pub scroll: usize,
    /// True once the worker reported the session ended.
    pub closed: bool,
}

impl BrowserPane {
    pub fn new(url: String, cmd_tx: Sender<CdpCommand>) -> Self {
        let mut p = BrowserPane {
            url: url.clone(),
            cmd_tx,
            targets: vec![BrowserTarget {
                session_id: String::new(),
                target_id: String::new(),
                title: "main".into(),
                url: url.clone(),
                kind: "page".into(),
            }],
            current_target: 0,
            log: Vec::new(),
            net: Vec::new(),
            net_focus: false,
            net_sel: 0,
            dom: Vec::new(),
            dom_focus: false,
            dom_sel: 0,
            next_id: 100,
            pending_eval: None,
            pending_screenshot: None,
            pending_dom: None,
            pending_post_data: Vec::new(),
            scroll: usize::MAX, // follow the tail
            closed: false,
        };
        let dest = if url.trim().is_empty() {
            "about:blank".to_string()
        } else {
            url
        };
        p.push(LogKind::System, format!("launching Chrome → {dest}"));
        p
    }

    pub fn push(&mut self, kind: LogKind, text: impl Into<String>) {
        self.log.push(LogLine {
            kind,
            text: text.into(),
        });
    }

    /// Record a `Network.requestWillBeSent` (its `request` object) as a [`NetEntry`].
    pub fn note_net_request(&mut self, request_id: &str, request: &serde_json::Value) {
        let method = request
            .get("method")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("GET")
            .to_string();
        let url = request
            .get("url")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_string();
        let headers = request
            .get("headers")
            .and_then(serde_json::Value::as_object)
            .map(|m| {
                m.iter()
                    .map(|(k, v)| {
                        (
                            k.clone(),
                            match v {
                                serde_json::Value::String(s) => s.clone(),
                                other => other.to_string(),
                            },
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        let post_data = request
            .get("postData")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        // Body present but not inlined? Ask Chrome for it (filled in by id later).
        let want_post_data = post_data.is_none()
            && request
                .get("hasPostData")
                .and_then(serde_json::Value::as_bool)
                == Some(true);
        self.net.push(NetEntry {
            request_id: request_id.to_string(),
            method,
            url,
            headers,
            post_data,
            status: None,
            mime: None,
            failed: None,
        });
        if want_post_data {
            let rid = request_id.to_string();
            let id = self.send(|id| crate::cdp::get_request_post_data(id, &rid));
            self.pending_post_data.push((id, request_id.to_string()));
        }
    }

    /// A `Network.getRequestPostData` reply (`rpc_id` → its `result.postData`) —
    /// fill the body of the [`NetEntry`] we asked about.
    pub fn fill_post_data(&mut self, rpc_id: i64, data: &str) {
        let Some(pos) = self
            .pending_post_data
            .iter()
            .position(|(id, _)| *id == rpc_id)
        else {
            return;
        };
        let (_, request_id) = self.pending_post_data.remove(pos);
        if let Some(e) = self
            .net
            .iter_mut()
            .rev()
            .find(|e| e.request_id == request_id)
        {
            e.post_data = Some(data.to_string());
        }
    }

    /// True if `rpc_id` is an outstanding `Network.getRequestPostData` we issued.
    pub fn is_pending_post_data(&self, rpc_id: i64) -> bool {
        self.pending_post_data.iter().any(|(id, _)| *id == rpc_id)
    }

    /// Fill in the response status / mime for the matching pending [`NetEntry`].
    pub fn note_net_response(&mut self, request_id: &str, status: i64, mime: Option<&str>) {
        if let Some(e) = self
            .net
            .iter_mut()
            .rev()
            .find(|e| e.request_id == request_id)
        {
            e.status = Some(status);
            e.mime = mime.map(str::to_string);
        }
    }

    /// Mark the matching pending [`NetEntry`] as failed.
    pub fn note_net_failed(&mut self, request_id: &str, why: &str) {
        if let Some(e) = self
            .net
            .iter_mut()
            .rev()
            .find(|e| e.request_id == request_id)
        {
            e.failed = Some(why.to_string());
        }
    }

    /// Clamp + move the network-panel selection by `delta`.
    pub fn move_net_sel(&mut self, delta: isize) {
        if self.net.is_empty() {
            self.net_sel = 0;
            return;
        }
        let max = self.net.len() - 1;
        let cur = self.net_sel.min(max) as isize;
        self.net_sel = (cur + delta).clamp(0, max as isize) as usize;
    }

    /// The currently-selected network entry, if the panel is non-empty.
    pub fn selected_net(&self) -> Option<&NetEntry> {
        self.net
            .get(self.net_sel.min(self.net.len().saturating_sub(1)))
    }

    fn fresh_id(&mut self) -> i64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Build + send a JSON-RPC request with a fresh id; returns that id.
    /// When the user has switched to a non-main target via `T`, the message
    /// is wrapped with the target's `sessionId` so Chrome routes it there
    /// (flatten mode — same WebSocket, message-level routing).
    fn send(&mut self, build: impl FnOnce(i64) -> String) -> i64 {
        let id = self.fresh_id();
        let mut msg = build(id);
        if let Some(session) = self.current_session()
            && !session.is_empty()
        {
            msg = crate::cdp::with_session(msg, &session);
        }
        let _ = self.cmd_tx.send(CdpCommand::Send(msg));
        id
    }

    /// Session id for the currently-targeted entry, or `None` for the main
    /// page (which doesn't need a `sessionId` field).
    pub fn current_session(&self) -> Option<String> {
        self.targets.get(self.current_target).and_then(|t| {
            if t.session_id.is_empty() {
                None
            } else {
                Some(t.session_id.clone())
            }
        })
    }

    pub fn current_target_label(&self) -> String {
        match self.targets.get(self.current_target) {
            Some(t) if t.session_id.is_empty() => "main".to_string(),
            Some(t) => {
                let title = if t.title.is_empty() {
                    "(no title)"
                } else {
                    &t.title
                };
                format!("{}: {}", t.kind, title)
            }
            None => "(no target)".to_string(),
        }
    }

    /// Record a `Target.attachedToTarget` event from the protocol — pushes a
    /// new entry on `targets`. Idempotent on `session_id`.
    pub fn note_attached_target(&mut self, session_id: &str, target_info: &serde_json::Value) {
        if self
            .targets
            .iter()
            .any(|t| t.session_id == session_id && !session_id.is_empty())
        {
            return;
        }
        let target_id = target_info
            .get("targetId")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_string();
        let kind = target_info
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("page")
            .to_string();
        let url = target_info
            .get("url")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_string();
        let title = target_info
            .get("title")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_string();
        self.targets.push(BrowserTarget {
            session_id: session_id.to_string(),
            target_id,
            title,
            url,
            kind,
        });
    }

    /// `Target.targetInfoChanged` — update title/url for the matching target.
    pub fn note_target_info_changed(&mut self, target_info: &serde_json::Value) {
        let target_id = match target_info.get("targetId").and_then(|v| v.as_str()) {
            Some(t) => t,
            None => return,
        };
        for t in &mut self.targets {
            if t.target_id == target_id {
                if let Some(s) = target_info.get("title").and_then(|v| v.as_str()) {
                    t.title = s.to_string();
                }
                if let Some(s) = target_info.get("url").and_then(|v| v.as_str()) {
                    t.url = s.to_string();
                }
            }
        }
    }

    /// `Target.detachedFromTarget` — drop the matching target. If it was the
    /// current selection, snap back to the main page (index 0).
    pub fn note_detached_target(&mut self, session_id: &str) {
        let idx = self.targets.iter().position(|t| t.session_id == session_id);
        let Some(idx) = idx else { return };
        if idx == 0 {
            return; // never drop the main entry
        }
        self.targets.remove(idx);
        if self.current_target >= idx {
            self.current_target = self.current_target.saturating_sub(1);
        }
    }

    /// Switch which target subsequent commands route through.
    pub fn switch_target(&mut self, idx: usize) {
        if idx < self.targets.len() {
            self.current_target = idx;
            let label = self.current_target_label();
            self.push(LogKind::System, format!("→ target: {label}"));
        }
    }

    /// `Page.navigate` — bare hostnames get an `https://` prefix.
    pub fn navigate(&mut self, url: &str) {
        let url = url.trim();
        if url.is_empty() {
            return;
        }
        let url = if url.contains("://") || url.starts_with("about:") {
            url.to_string()
        } else {
            format!("https://{url}")
        };
        self.push(LogKind::Nav, format!("navigate → {url}"));
        let u = url;
        self.send(|id| crate::cdp::navigate(id, &u));
    }

    pub fn reload(&mut self) {
        self.push(LogKind::Nav, "reload");
        self.send(crate::cdp::reload);
    }

    /// `Runtime.evaluate` — the result lands later (matched by id) as a `= …` line.
    pub fn eval(&mut self, expr: &str) {
        let expr = expr.trim();
        if expr.is_empty() {
            return;
        }
        self.push(LogKind::Eval, format!("» {expr}"));
        let e = expr.to_string();
        let id = self.send(|id| crate::cdp::evaluate(id, &e));
        self.pending_eval = Some(id);
    }

    /// `s` — `Page.captureScreenshot`; the PNG lands later (matched by id) and is
    /// written to `.mnml/screenshots/` (see `App::apply_cdp_message`).
    pub fn screenshot(&mut self) {
        if self.closed {
            return;
        }
        self.push(LogKind::System, "capturing screenshot…");
        let id = self.send(crate::cdp::capture_screenshot);
        self.pending_screenshot = Some(id);
    }

    /// `D` (or refresh from the panel) — `DOM.getDocument`; the parsed tree lands
    /// later as a `dom` list (see `App::apply_cdp_message`).
    pub fn fetch_dom(&mut self) {
        if self.closed {
            return;
        }
        self.push(LogKind::System, "fetching DOM…");
        let id = self.send(crate::cdp::get_document);
        self.pending_dom = Some(id);
    }

    /// Replace the flat DOM with `rows` (a fresh `DOM.getDocument` reply).
    pub fn set_dom(&mut self, rows: Vec<DomRow>) {
        let n = rows.len();
        self.dom = rows;
        if self.dom_sel >= n {
            self.dom_sel = n.saturating_sub(1);
        }
    }

    /// Clamp + move the DOM-panel selection by `delta`.
    pub fn move_dom_sel(&mut self, delta: isize) {
        if self.dom.is_empty() {
            self.dom_sel = 0;
            return;
        }
        let max = self.dom.len() - 1;
        let cur = self.dom_sel.min(max) as isize;
        self.dom_sel = (cur + delta).clamp(0, max as isize) as usize;
    }

    /// The currently-selected DOM row, if the panel is non-empty.
    pub fn selected_dom(&self) -> Option<&DomRow> {
        self.dom
            .get(self.dom_sel.min(self.dom.len().saturating_sub(1)))
    }

    /// `Overlay.highlightNode` for the selected DOM row (no-op if no node).
    pub fn highlight_selected_dom(&mut self) {
        let Some(node_id) = self.selected_dom().map(|r| r.node_id) else {
            return;
        };
        if node_id == 0 || self.closed {
            return;
        }
        self.send(|id| crate::cdp::highlight_node(id, node_id));
    }

    /// `Overlay.hideHighlight` — clear any highlight box drawn on the page.
    pub fn hide_highlight(&mut self) {
        if self.closed {
            return;
        }
        self.send(crate::cdp::hide_highlight);
    }

    pub fn tab_title(&self) -> String {
        let u = self.url.trim();
        let short = u
            .strip_prefix("https://")
            .or_else(|| u.strip_prefix("http://"))
            .unwrap_or(u);
        let short: String = short.chars().take(28).collect();
        if short.is_empty() {
            "browser".to_string()
        } else {
            format!("browser · {short}")
        }
    }
}

impl Drop for BrowserPane {
    fn drop(&mut self) {
        // Tell the worker to kill Chrome (best-effort — it may already be gone).
        let _ = self.cmd_tx.send(CdpCommand::Close);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> NetEntry {
        NetEntry {
            request_id: "1.7".into(),
            method: "POST".into(),
            url: "https://api.test/v1/things?q=1".into(),
            headers: vec![
                (":method".into(), "POST".into()),
                ("content-type".into(), "application/json".into()),
                ("x-token".into(), "ab'cd".into()),
            ],
            post_data: Some(r#"{"a":1}"#.into()),
            status: Some(201),
            mime: Some("application/json".into()),
            failed: None,
        }
    }

    #[test]
    fn as_curl_drops_pseudo_headers_and_quotes_body() {
        let c = entry().as_curl();
        assert!(c.starts_with("curl 'https://api.test/v1/things?q=1'"));
        assert!(!c.contains(":method")); // pseudo-header skipped
        assert!(c.contains("-H 'content-type: application/json'"));
        assert!(c.contains(r"x-token: ab'\''cd")); // single-quote escaped
        assert!(c.contains(r#"--data-raw '{"a":1}'"#));
        // POST-with-body ⇒ no explicit -X (curl infers it from --data-raw).
        assert!(!c.contains("-X POST"));
    }

    #[test]
    fn to_request_filters_pseudo_headers() {
        let r = entry().to_request();
        assert_eq!(r.method, "POST");
        assert_eq!(r.url, "https://api.test/v1/things?q=1");
        assert!(r.headers.iter().all(|(k, _)| !k.starts_with(':')));
        assert_eq!(r.body.as_deref(), Some(r#"{"a":1}"#));
    }

    #[test]
    fn note_net_request_then_response_matches_by_id() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.note_net_request(
            "42",
            &serde_json::json!({
                "method": "GET",
                "url": "https://x.test/data",
                "headers": { "accept": "application/json" },
            }),
        );
        assert_eq!(p.net.len(), 1);
        assert_eq!(p.net[0].method, "GET");
        assert_eq!(
            p.net[0].headers,
            vec![("accept".to_string(), "application/json".to_string())]
        );
        p.note_net_response("42", 200, Some("application/json"));
        assert_eq!(p.net[0].status, Some(200));
        assert_eq!(p.net[0].mime.as_deref(), Some("application/json"));
        p.note_net_failed("nope", "ERR"); // no match — nothing changes
        assert!(p.net[0].failed.is_none());
        p.note_net_failed("42", "ERR_TIMED_OUT");
        assert_eq!(p.net[0].failed.as_deref(), Some("ERR_TIMED_OUT"));
    }

    #[test]
    fn deferred_post_data_is_requested_then_filled() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.note_net_request(
            "9.1",
            &serde_json::json!({
                "method": "POST",
                "url": "https://api.test/upload",
                "headers": {},
                "hasPostData": true, // body present but not inlined
            }),
        );
        // A `Network.getRequestPostData` was sent; grab its id from the wire.
        let id = loop {
            match rx.try_recv() {
                Ok(CdpCommand::Send(json)) => {
                    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
                    if v["method"] == "Network.getRequestPostData" {
                        break v["id"].as_i64().unwrap();
                    }
                }
                Ok(_) => {}
                Err(_) => panic!("no getRequestPostData request was sent"),
            }
        };
        assert!(p.is_pending_post_data(id));
        assert!(p.net[0].post_data.is_none());
        p.fill_post_data(id, "name=x&size=10");
        assert_eq!(p.net[0].post_data.as_deref(), Some("name=x&size=10"));
        assert!(!p.is_pending_post_data(id)); // consumed
        // An inlined body needs no follow-up request.
        p.note_net_request(
            "9.2",
            &serde_json::json!({"method": "POST", "url": "https://api.test/x", "postData": "a=1"}),
        );
        assert_eq!(p.net[1].post_data.as_deref(), Some("a=1"));
        assert!(rx.try_recv().is_err()); // nothing more sent
    }

    #[test]
    fn parse_dom_flattens_with_selectors_and_skips_ws() {
        // A minimal CDP DOM.getDocument shape: a document wrapping an html element
        // with a body containing a div (id+class) holding "  hi   " and a comment.
        let root = serde_json::json!({
            "nodeType": 9,
            "children": [
                { "nodeType": 10, "nodeName": "html" },
                {
                    "nodeType": 1, "nodeName": "HTML", "attributes": [],
                    "children": [
                        {
                            "nodeType": 1, "nodeName": "BODY", "attributes": [],
                            "children": [
                                {
                                    "nodeType": 1, "nodeName": "DIV",
                                    "attributes": ["id", "main", "class", "card sm", "data-x", "1"],
                                    "children": [
                                        { "nodeType": 3, "nodeValue": "   \n  " }, // skipped
                                        { "nodeType": 3, "nodeValue": "  hi   there " },
                                        { "nodeType": 8, "nodeValue": "todo" }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        });
        let rows = parse_dom(&root);
        // doctype + <html> + <body> + <div> + text "hi there" + comment
        assert_eq!(rows.len(), 6);
        assert_eq!(rows[0].label, "<!DOCTYPE html>");
        assert_eq!(rows[0].depth, 0); // document wrapper is transparent
        assert!(rows[1].label.starts_with("<html"));
        assert_eq!(rows[1].depth, 0);
        assert_eq!(rows[2].depth, 1);
        assert!(rows[3].label.contains(r#"id="main""#));
        assert!(rows[3].label.contains(r#"class="card sm""#));
        assert!(rows[3].label.contains(r#"data-x="1""#));
        assert_eq!(rows[3].depth, 2);
        assert_eq!(rows[3].selector, "html > body > div#main.card.sm");
        assert_eq!(rows[4].label, "“hi there”"); // whitespace collapsed
        assert_eq!(rows[4].depth, 3);
        assert!(rows[5].label.starts_with("<!--"));
    }

    #[test]
    fn move_net_sel_clamps() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.move_net_sel(5); // empty ⇒ stays 0
        assert_eq!(p.net_sel, 0);
        for _ in 0..3 {
            p.note_net_request("x", &serde_json::json!({"url": "https://a/b"}));
        }
        p.move_net_sel(10);
        assert_eq!(p.net_sel, 2);
        p.move_net_sel(-1);
        assert_eq!(p.net_sel, 1);
        p.move_net_sel(-9);
        assert_eq!(p.net_sel, 0);
    }

    #[test]
    fn target_attach_detach_and_switch() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("https://example.test".into(), tx);
        // Starts with the main target only.
        assert_eq!(p.targets.len(), 1);
        assert_eq!(p.current_target, 0);
        assert!(p.current_session().is_none());

        // Attach a popup.
        p.note_attached_target(
            "sess-1",
            &serde_json::json!({
                "targetId": "T-abc",
                "type": "page",
                "title": "Login - Provider",
                "url": "https://idp.test/login"
            }),
        );
        assert_eq!(p.targets.len(), 2);
        assert_eq!(p.targets[1].session_id, "sess-1");
        assert_eq!(p.targets[1].title, "Login - Provider");

        // Idempotent on session id — a duplicate attached event does nothing.
        p.note_attached_target(
            "sess-1",
            &serde_json::json!({"targetId": "T-abc", "type": "page"}),
        );
        assert_eq!(p.targets.len(), 2);

        // Switch to it.
        p.switch_target(1);
        assert_eq!(p.current_target, 1);
        assert_eq!(p.current_session().as_deref(), Some("sess-1"));

        // Title update.
        p.note_target_info_changed(&serde_json::json!({
            "targetId": "T-abc",
            "title": "Login (renamed)",
            "url": "https://idp.test/login?step=2"
        }));
        assert_eq!(p.targets[1].title, "Login (renamed)");
        assert_eq!(p.targets[1].url, "https://idp.test/login?step=2");

        // Detach — current snaps back to main.
        p.note_detached_target("sess-1");
        assert_eq!(p.targets.len(), 1);
        assert_eq!(p.current_target, 0);
        // Detaching the main is a no-op (the main entry's session_id is "").
        p.note_detached_target("");
        assert_eq!(p.targets.len(), 1);
    }
}
