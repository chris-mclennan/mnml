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

/// Page performance metrics fetched via the eval flow in
/// [`BrowserPane::fetch_perf`]. All fields are millisecond timings
/// (relative to navigation start); `None` ⇒ the metric isn't
/// available for this page (e.g. LCP only fires on real DOMs, not
/// `about:blank`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PerfMetrics {
    pub dns: Option<f64>,
    pub tcp: Option<f64>,
    pub ttfb: Option<f64>,
    pub response: Option<f64>,
    pub dom_interactive: Option<f64>,
    pub load: Option<f64>,
    pub fcp: Option<f64>,
    pub lcp: Option<f64>,
}

/// The IIFE we eval to read `performance.*` timings + LCP. Wrapped
/// in try/catch since some pages (file://, sandboxes) restrict
/// access to PerformanceObserver entries.
pub(crate) const PERF_EVAL_EXPR: &str = "(function(){\
try{\
const n=(performance.getEntriesByType('navigation')||[])[0]||{};\
const paint=performance.getEntriesByType('paint')||[];\
const fcpEntry=paint.find(p=>p.name==='first-contentful-paint');\
let lcp=null;try{const a=performance.getEntriesByType('largest-contentful-paint')||[];if(a.length)lcp=a[a.length-1].startTime;}catch(_){}\
return{\
dns:n.domainLookupEnd-n.domainLookupStart,\
tcp:n.connectEnd-n.connectStart,\
ttfb:n.responseStart-n.requestStart,\
response:n.responseEnd-n.responseStart,\
dom_interactive:n.domInteractive-n.fetchStart,\
load:n.loadEventEnd-n.fetchStart,\
fcp:fcpEntry?fcpEntry.startTime:null,\
lcp:lcp\
};\
}catch(e){return{error:String(e)};}\
})()";

/// Parse the `Runtime.evaluate` reply's value (the PERF IIFE return)
/// into [`PerfMetrics`]. Returns `Err` when the eval reported a
/// caught error (origin denied access).
pub fn parse_perf_eval(v: &serde_json::Value) -> Result<PerfMetrics, String> {
    if let Some(e) = v.get("error").and_then(serde_json::Value::as_str) {
        return Err(e.to_string());
    }
    // Each field can be a number, NaN/null, or missing. JSON.stringify
    // turns NaN/Infinity into `null`, and division-by-zero on a metric
    // that hasn't fired yet (e.g. loadEventEnd=0) produces a negative
    // number we want to treat as "not yet available" — coerce <= 0
    // to None for that reason.
    let pick = |k: &str| -> Option<f64> {
        v.get(k)
            .and_then(serde_json::Value::as_f64)
            .filter(|n| n.is_finite() && *n > 0.0)
    };
    Ok(PerfMetrics {
        dns: pick("dns"),
        tcp: pick("tcp"),
        ttfb: pick("ttfb"),
        response: pick("response"),
        dom_interactive: pick("dom_interactive"),
        load: pick("load"),
        fcp: pick("fcp"),
        lcp: pick("lcp"),
    })
}

/// One Web Storage entry (either `localStorage` or `sessionStorage`).
/// Read via the eval flow in [`BrowserPane::fetch_storage`] —
/// `Runtime.evaluate` against an IIFE that returns both storages so
/// we don't need to enable the `DOMStorage` CDP domain or extract a
/// securityOrigin from the page URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageEntry {
    pub key: String,
    pub value: String,
    /// `true` = `localStorage`, `false` = `sessionStorage`. Drives the
    /// row chip the renderer paints in front of each entry.
    pub is_local: bool,
}

/// The IIFE we eval to read both storages in one Runtime.evaluate.
/// Wrapped in try/catch since `file://` and some sandboxed origins
/// throw on access; the App treats `{ error: <str> }` as a toast.
pub(crate) const STORAGE_EVAL_EXPR: &str = "(function(){\
try{\
const l=[];for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);l.push([k,localStorage.getItem(k)]);}\
const s=[];for(let i=0;i<sessionStorage.length;i++){const k=sessionStorage.key(i);s.push([k,sessionStorage.getItem(k)]);}\
return{local:l,session:s};\
}catch(e){return{error:String(e)};}\
})()";

/// Parse the `Runtime.evaluate` reply's value (the IIFE return) into a
/// flat `Vec<StorageEntry>` (local first, then session). Returns `Err`
/// when the eval landed an `error` field (origin denied access) so the
/// App can toast.
pub fn parse_storage_eval(v: &serde_json::Value) -> Result<Vec<StorageEntry>, String> {
    if let Some(e) = v.get("error").and_then(serde_json::Value::as_str) {
        return Err(e.to_string());
    }
    let mut out = Vec::new();
    let walk = |arr: Option<&serde_json::Value>, is_local: bool, out: &mut Vec<StorageEntry>| {
        let Some(arr) = arr.and_then(serde_json::Value::as_array) else {
            return;
        };
        for pair in arr {
            let Some(pair) = pair.as_array() else {
                continue;
            };
            if pair.len() < 2 {
                continue;
            }
            let key = pair[0].as_str().unwrap_or("").to_string();
            let value = pair[1].as_str().unwrap_or("").to_string();
            out.push(StorageEntry {
                key,
                value,
                is_local,
            });
        }
    };
    walk(v.get("local"), true, &mut out);
    walk(v.get("session"), false, &mut out);
    Ok(out)
}

/// One cookie returned by `Network.getCookies`. Projected from the
/// CDP reply by [`parse_cookies`]; the rendered row carries
/// `name=value` + the domain / path / expires + the
/// `secure`/`httpOnly`/`sameSite` flags.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CookieEntry {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    /// `-1` = session cookie (no expiration); otherwise a Unix epoch
    /// seconds value the browser returned. The renderer formats it as
    /// a humanized age (or `session`).
    pub expires: i64,
    pub http_only: bool,
    pub secure: bool,
    /// Verbatim `"Strict"` / `"Lax"` / `"None"` / `""` from the reply.
    pub same_site: String,
}

/// Parse `Network.getCookies`'s `cookies: [...]` array into a flat
/// `Vec<CookieEntry>`. Tolerates missing fields with sensible defaults
/// — a malformed entry never aborts the parse.
pub fn parse_cookies(arr: &serde_json::Value) -> Vec<CookieEntry> {
    let Some(arr) = arr.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .map(|c| CookieEntry {
            name: c
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string(),
            value: c
                .get("value")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string(),
            domain: c
                .get("domain")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string(),
            path: c
                .get("path")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("/")
                .to_string(),
            // CDP returns a float (with fractional seconds) for `expires`;
            // -1 ⇒ session cookie. We coerce to i64; rounding the fractional
            // milliseconds doesn't matter for our humanized display.
            expires: c
                .get("expires")
                .and_then(serde_json::Value::as_f64)
                .map(|f| f as i64)
                .unwrap_or(-1),
            http_only: c
                .get("httpOnly")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            secure: c
                .get("secure")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            same_site: c
                .get("sameSite")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string(),
        })
        .collect()
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
    /// Selected row in the **filtered** network view (index into
    /// [`Self::visible_net_indices`]). Resolves through the filter via
    /// [`Self::selected_net`] / [`Self::move_net_sel`].
    pub net_sel: usize,
    /// Fuzzy filter narrowing the network panel — typed via `/` while
    /// `net_focus`. Empty ⇒ every captured request is visible.
    pub net_filter: String,
    /// True while the user is typing the filter (printable keys append,
    /// Backspace pops). Enter exits filter mode (keeps the filter); Esc
    /// clears the filter + exits the filter mode.
    pub net_filter_mode: bool,
    /// Flattened DOM rows (lazy — populated on the first `D` press, refreshed on `R`).
    pub dom: Vec<DomRow>,
    /// True ⇒ the `D` DOM panel is showing.
    pub dom_focus: bool,
    /// Selected row in the **filtered** DOM view (index into
    /// [`Self::visible_dom_indices`]). Resolves through the filter via
    /// [`Self::selected_dom`] / [`Self::move_dom_sel`].
    pub dom_sel: usize,
    /// Fuzzy filter narrowing the DOM panel — typed via `/` while
    /// `dom_focus`. Empty ⇒ every parsed row is visible.
    pub dom_filter: String,
    /// True while the user is typing the DOM filter (printable keys
    /// append, Backspace pops). Enter exits filter mode (keeps the
    /// filter); Esc clears the filter + exits the filter mode.
    pub dom_filter_mode: bool,
    /// True ⇒ every change in `dom_sel` fires `Overlay.highlightNode` so
    /// the page's overlay box tracks the keyboard selection in real time.
    /// Toggled via `H` in DOM-panel focus. Default off — explicit `h`
    /// still draws a one-shot highlight without enabling follow.
    pub dom_hover_highlight: bool,
    /// Cookies for the current top-level URL, fetched lazily on the
    /// first `K` press (and refreshed on `R` inside the panel).
    /// Populated from `Network.getCookies` via [`parse_cookies`].
    pub cookies: Vec<CookieEntry>,
    /// True ⇒ the `K` cookies panel is showing.
    pub cookies_focus: bool,
    /// Selected cookies row when `cookies_focus`.
    pub cookies_sel: usize,
    /// The id of an in-flight `Network.getCookies` request, so its reply
    /// can be matched (the panel shows a "fetching cookies…" hint until
    /// it lands).
    pub pending_cookies: Option<i64>,
    /// `localStorage` + `sessionStorage` entries for the current page,
    /// fetched lazily on the first `L` press (and refreshed on `R`
    /// inside the panel). Populated via the eval flow described on
    /// [`STORAGE_EVAL_EXPR`].
    pub storage: Vec<StorageEntry>,
    /// True ⇒ the `L` Web Storage panel is showing.
    pub storage_focus: bool,
    /// Selected storage row when `storage_focus`.
    pub storage_sel: usize,
    /// The id of an in-flight Web Storage `Runtime.evaluate` so its
    /// reply can be routed to the storage panel (not the regular eval
    /// log).
    pub pending_storage: Option<i64>,
    /// Page performance metrics for the current page, fetched lazily
    /// on the first `P` press and refreshed on `R` inside the panel.
    pub perf: PerfMetrics,
    /// True ⇒ the `P` performance panel is showing.
    pub perf_focus: bool,
    /// The id of an in-flight perf `Runtime.evaluate` so its reply
    /// routes to the perf panel.
    pub pending_perf: Option<i64>,
    /// Next JSON-RPC id for requests this pane issues.
    next_id: i64,
    /// The id of an in-flight `Runtime.evaluate`, so its reply can be matched.
    pub pending_eval: Option<i64>,
    /// The id of an in-flight `Page.captureScreenshot`, so its reply can be matched.
    pub pending_screenshot: Option<i64>,
    /// The id of an in-flight `DOM.getBoxModel` (from the `S`
    /// node-screenshot flow) — once its reply lands the App computes
    /// the bbox + fires `Page.captureScreenshot` with clip. Distinct
    /// from `pending_screenshot` so the two reply paths don't collide.
    pub pending_node_screenshot: Option<i64>,
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
            net_filter: String::new(),
            net_filter_mode: false,
            dom: Vec::new(),
            dom_focus: false,
            dom_sel: 0,
            dom_filter: String::new(),
            dom_filter_mode: false,
            dom_hover_highlight: false,
            cookies: Vec::new(),
            cookies_focus: false,
            cookies_sel: 0,
            pending_cookies: None,
            storage: Vec::new(),
            storage_focus: false,
            storage_sel: 0,
            pending_storage: None,
            perf: PerfMetrics::default(),
            perf_focus: false,
            pending_perf: None,
            next_id: 100,
            pending_eval: None,
            pending_screenshot: None,
            pending_node_screenshot: None,
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

    /// Clamp + move the (filtered) network-panel selection by `delta`.
    /// `net_sel` is an index into [`Self::visible_net_indices`], so the
    /// clamp is against the *filtered* row count.
    pub fn move_net_sel(&mut self, delta: isize) {
        let n = self.visible_net_indices().len();
        if n == 0 {
            self.net_sel = 0;
            return;
        }
        let max = n - 1;
        let cur = self.net_sel.min(max) as isize;
        self.net_sel = (cur + delta).clamp(0, max as isize) as usize;
    }

    /// The currently-selected network entry, resolved through the filter.
    /// Returns `None` when the filtered view is empty or selection drifted.
    pub fn selected_net(&self) -> Option<&NetEntry> {
        let v = self.visible_net_indices();
        v.get(self.net_sel).and_then(|&i| self.net.get(i))
    }

    /// Indices into [`Self::net`] that pass the current fuzzy filter, in
    /// arrival order (so the selected-row mapping is stable). Empty
    /// `net_filter` returns every index. Match target is
    /// `"<METHOD> <short_url>"` so `get api` or `post v2/login` both
    /// work.
    pub fn visible_net_indices(&self) -> Vec<usize> {
        if self.net_filter.is_empty() {
            return (0..self.net.len()).collect();
        }
        self.net
            .iter()
            .enumerate()
            .filter_map(|(i, e)| {
                let hay = format!("{} {}", e.method, e.short_url());
                crate::fuzzy::fuzzy_match(&self.net_filter, &hay).map(|_| i)
            })
            .collect()
    }

    /// Append `c` to the live network filter, snap selection back to the
    /// top (the previous filtered position no longer makes sense).
    pub fn net_filter_push(&mut self, c: char) {
        self.net_filter.push(c);
        self.net_sel = 0;
    }

    /// Pop one char off the live network filter. When the query empties,
    /// the pane stays in filter mode (Esc / Enter exit).
    pub fn net_filter_pop(&mut self) {
        self.net_filter.pop();
        self.net_sel = 0;
    }

    /// Clear the filter + exit filter mode.
    pub fn net_filter_clear_and_exit(&mut self) {
        self.net_filter.clear();
        self.net_filter_mode = false;
        self.net_sel = 0;
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

    /// Fire-and-forget eval — doesn't push a `» …` log line, doesn't
    /// claim `pending_eval` (so the reply falls through to the no-op
    /// catch-all). Used by the storage / cookie edit/add/delete flows
    /// where we don't care about the eval result.
    pub fn eval_silent(&mut self, expr: &str) {
        let expr = expr.trim();
        if expr.is_empty() || self.closed {
            return;
        }
        let e = expr.to_string();
        self.send(|id| crate::cdp::evaluate(id, &e));
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

    /// `S` in the DOM panel — capture a screenshot of the selected
    /// node only. Two-step CDP flow: first `DOM.getBoxModel`, then on
    /// reply compute the bounding rect + fire
    /// `Page.captureScreenshot` with a `clip` argument. The eventual
    /// PNG is written through the same path as a full-page screenshot.
    /// No-op if the panel has no selection or `selected_dom().node_id`
    /// is 0 (synthetic / un-screenshottable node).
    pub fn screenshot_selected_dom(&mut self) {
        if self.closed {
            return;
        }
        let Some(node_id) = self.selected_dom().map(|r| r.node_id) else {
            return;
        };
        if node_id == 0 {
            return;
        }
        self.push(LogKind::System, "capturing node screenshot…");
        let id = self.send(|id| crate::cdp::get_box_model(id, node_id));
        self.pending_node_screenshot = Some(id);
    }

    /// Fire `Page.captureScreenshot` clipped to a rect. Called by the
    /// App after the `DOM.getBoxModel` reply lands and the bbox is
    /// computed.
    pub fn screenshot_clip(&mut self, x: f64, y: f64, width: f64, height: f64) {
        if self.closed {
            return;
        }
        let id = self.send(|id| crate::cdp::capture_screenshot_clip(id, x, y, width, height));
        self.pending_screenshot = Some(id);
    }

    /// True when `rpc_id` is the one we stashed in
    /// `pending_node_screenshot`. Used by the App's CDP reply
    /// dispatcher to match a `DOM.getBoxModel` reply.
    pub fn is_pending_node_screenshot(&self, rpc_id: i64) -> bool {
        self.pending_node_screenshot == Some(rpc_id)
    }

    /// `P` (or refresh from the panel) — eval-fetch `performance.*`
    /// timings + paint entries + LCP. Reply lands later as a
    /// [`PerfMetrics`] (see `App::apply_cdp_message`).
    pub fn fetch_perf(&mut self) {
        if self.closed {
            return;
        }
        self.push(LogKind::System, "fetching performance metrics…");
        let id = self.send(|id| crate::cdp::evaluate(id, PERF_EVAL_EXPR));
        self.pending_perf = Some(id);
    }

    /// True when `rpc_id` is the one stashed in `pending_perf`.
    pub fn is_pending_perf(&self, rpc_id: i64) -> bool {
        self.pending_perf == Some(rpc_id)
    }

    /// `L` (or refresh from the panel) — eval-fetch
    /// `localStorage` + `sessionStorage` for the current top-level
    /// page. Reply lands later as a `storage` vector (see
    /// `App::apply_cdp_message`); errors (denied origins) become a
    /// toast.
    pub fn fetch_storage(&mut self) {
        if self.closed {
            return;
        }
        self.push(LogKind::System, "fetching localStorage / sessionStorage…");
        let id = self.send(|id| crate::cdp::evaluate(id, STORAGE_EVAL_EXPR));
        self.pending_storage = Some(id);
    }

    /// True when `rpc_id` is the one stashed in `pending_storage` —
    /// the App uses it to route the eval reply to the storage panel
    /// instead of the regular Eval log.
    pub fn is_pending_storage(&self, rpc_id: i64) -> bool {
        self.pending_storage == Some(rpc_id)
    }

    /// Replace the storage list with `entries` (a fresh fetch result);
    /// clamp the selection so it stays inside the new list.
    pub fn set_storage(&mut self, entries: Vec<StorageEntry>) {
        let n = entries.len();
        self.storage = entries;
        if self.storage_sel >= n {
            self.storage_sel = n.saturating_sub(1);
        }
    }

    /// Clamp + move the storage-panel selection by `delta`.
    pub fn move_storage_sel(&mut self, delta: isize) {
        if self.storage.is_empty() {
            self.storage_sel = 0;
            return;
        }
        let max = self.storage.len() - 1;
        let cur = self.storage_sel.min(max) as isize;
        self.storage_sel = (cur + delta).clamp(0, max as isize) as usize;
    }

    /// The currently-selected storage entry, if the panel is non-empty.
    pub fn selected_storage(&self) -> Option<&StorageEntry> {
        self.storage
            .get(self.storage_sel.min(self.storage.len().saturating_sub(1)))
    }

    /// `K` (or refresh from the panel) — `Network.getCookies`; the
    /// parsed list lands later as a `cookies` vector (see
    /// `App::apply_cdp_message`).
    pub fn fetch_cookies(&mut self) {
        if self.closed {
            return;
        }
        self.push(LogKind::System, "fetching cookies…");
        let id = self.send(crate::cdp::get_cookies);
        self.pending_cookies = Some(id);
    }

    /// True when `rpc_id` is the one stashed in `pending_cookies` —
    /// used by the App's CDP reply dispatcher to match the
    /// `Network.getCookies` reply.
    pub fn is_pending_cookies(&self, rpc_id: i64) -> bool {
        self.pending_cookies == Some(rpc_id)
    }

    /// Replace the cookies list with `cookies` (a fresh
    /// `Network.getCookies` reply); clamp the selection so it stays
    /// inside the new list.
    pub fn set_cookies(&mut self, cookies: Vec<CookieEntry>) {
        let n = cookies.len();
        self.cookies = cookies;
        if self.cookies_sel >= n {
            self.cookies_sel = n.saturating_sub(1);
        }
    }

    /// `e` / `a` in the cookies panel — fire `Network.setCookie` with
    /// the given `{name, value, domain, path}`. Same name+domain+path
    /// as an existing cookie replaces it (the edit semantics); a new
    /// tuple creates a fresh cookie. The reply is fire-and-forget; the
    /// App refreshes via `R` to confirm.
    pub fn set_cookie(&mut self, name: &str, value: &str, domain: &str, path: &str) {
        if self.closed || name.is_empty() {
            return;
        }
        let (n, v, d, p) = (
            name.to_string(),
            value.to_string(),
            domain.to_string(),
            path.to_string(),
        );
        self.send(|id| crate::cdp::set_cookie(id, &n, &v, &d, &p));
        self.push(LogKind::System, format!("set cookie {name}={value}"));
    }

    /// `d` in the cookies panel — fire `Network.deleteCookies` for the
    /// selected cookie. Returns the cookie's name on success (so the
    /// App can toast). The reply is fire-and-forget; we optimistically
    /// drop the row locally so the user sees the change before the
    /// round-trip lands.
    pub fn delete_selected_cookie(&mut self) -> Option<String> {
        if self.closed {
            return None;
        }
        let (name, domain, path) = self
            .selected_cookie()
            .map(|c| (c.name.clone(), c.domain.clone(), c.path.clone()))?;
        self.send(|id| crate::cdp::delete_cookies(id, &name, &domain, &path));
        if self.cookies_sel < self.cookies.len() {
            self.cookies.remove(self.cookies_sel);
        }
        if self.cookies_sel >= self.cookies.len() {
            self.cookies_sel = self.cookies.len().saturating_sub(1);
        }
        self.push(LogKind::System, format!("deleted cookie {name}"));
        Some(name)
    }

    /// Clamp + move the cookies-panel selection by `delta`.
    pub fn move_cookies_sel(&mut self, delta: isize) {
        if self.cookies.is_empty() {
            self.cookies_sel = 0;
            return;
        }
        let max = self.cookies.len() - 1;
        let cur = self.cookies_sel.min(max) as isize;
        self.cookies_sel = (cur + delta).clamp(0, max as isize) as usize;
    }

    /// The currently-selected cookie, if the panel is non-empty.
    pub fn selected_cookie(&self) -> Option<&CookieEntry> {
        self.cookies
            .get(self.cookies_sel.min(self.cookies.len().saturating_sub(1)))
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

    /// Clamp + move the (filtered) DOM-panel selection by `delta`.
    /// `dom_sel` is an index into [`Self::visible_dom_indices`] so the
    /// clamp is against the *filtered* row count.
    pub fn move_dom_sel(&mut self, delta: isize) {
        let n = self.visible_dom_indices().len();
        if n == 0 {
            self.dom_sel = 0;
            return;
        }
        let max = n - 1;
        let cur = self.dom_sel.min(max) as isize;
        self.dom_sel = (cur + delta).clamp(0, max as isize) as usize;
        self.maybe_hover_highlight();
    }

    /// Direct `dom_sel` setter — clamps to the filtered list, then
    /// fires the hover overlay (when enabled). Used by the `g` / `G` /
    /// `Home` / `End` chords that jump rather than step.
    pub fn set_dom_sel(&mut self, idx: usize) {
        let max = self.visible_dom_indices().len().saturating_sub(1);
        self.dom_sel = idx.min(max);
        self.maybe_hover_highlight();
    }

    /// Indices into [`Self::dom`] that pass the current fuzzy filter,
    /// in tree order (so depth-indent stays readable). Empty filter
    /// returns every index. Match target is `"<label> <selector>"` so
    /// either side narrows — `div#main` (selector) or `class="card"`
    /// (label) both work.
    pub fn visible_dom_indices(&self) -> Vec<usize> {
        if self.dom_filter.is_empty() {
            return (0..self.dom.len()).collect();
        }
        self.dom
            .iter()
            .enumerate()
            .filter_map(|(i, r)| {
                let hay = format!("{} {}", r.label, r.selector);
                crate::fuzzy::fuzzy_match(&self.dom_filter, &hay).map(|_| i)
            })
            .collect()
    }

    /// Append `c` to the live DOM filter, snap selection back to the
    /// top (the previous filtered position no longer makes sense).
    pub fn dom_filter_push(&mut self, c: char) {
        self.dom_filter.push(c);
        self.dom_sel = 0;
        self.maybe_hover_highlight();
    }

    /// Pop one char off the live DOM filter. When the query empties,
    /// the pane stays in filter mode (Esc / Enter exit).
    pub fn dom_filter_pop(&mut self) {
        self.dom_filter.pop();
        self.dom_sel = 0;
        self.maybe_hover_highlight();
    }

    /// Clear the filter + exit filter mode.
    pub fn dom_filter_clear_and_exit(&mut self) {
        self.dom_filter.clear();
        self.dom_filter_mode = false;
        self.dom_sel = 0;
        self.maybe_hover_highlight();
    }

    /// Toggle the DOM-hover follow mode. Entering follow mode immediately
    /// fires the highlight for the current selection so the user gets
    /// visible feedback on the toggle; leaving follow mode hides any
    /// drawn overlay.
    pub fn toggle_dom_hover_highlight(&mut self) {
        self.dom_hover_highlight = !self.dom_hover_highlight;
        if self.dom_hover_highlight {
            self.highlight_selected_dom();
        } else {
            self.hide_highlight();
        }
    }

    /// If follow mode is on, fire `Overlay.highlightNode` for the current
    /// selection. Called on every selection change; cheap (one CDP
    /// fire-and-forget WebSocket frame), no reply to wait on.
    fn maybe_hover_highlight(&mut self) {
        if self.dom_hover_highlight {
            self.highlight_selected_dom();
        }
    }

    /// The currently-selected DOM row, resolved through the filter.
    /// Returns `None` when the filtered view is empty or selection drifted.
    pub fn selected_dom(&self) -> Option<&DomRow> {
        let v = self.visible_dom_indices();
        v.get(self.dom_sel).and_then(|&i| self.dom.get(i))
    }

    /// `Z` in the DOM panel — `DOM.scrollIntoViewIfNeeded` for the
    /// selected node, bringing it into the viewport. No-op if no node
    /// is selected or `node_id == 0` (synthetic / un-scrollable).
    /// Pairs naturally with `S` (node screenshot) and `h` (highlight)
    /// which both require the node to be in-viewport.
    pub fn scroll_selected_dom_into_view(&mut self) {
        let Some(node_id) = self.selected_dom().map(|r| r.node_id) else {
            return;
        };
        if node_id == 0 || self.closed {
            return;
        }
        self.send(|id| crate::cdp::scroll_into_view_if_needed(id, node_id));
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

    /// Drain every queued outbound CDP message and return its parsed
    /// JSON. Used by the hover-highlight test to verify that selection
    /// changes do (or don't) emit `Overlay.highlightNode` frames.
    fn drain_cdp(rx: &std::sync::mpsc::Receiver<CdpCommand>) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        while let Ok(cmd) = rx.try_recv() {
            if let CdpCommand::Send(json) = cmd
                && let Ok(v) = serde_json::from_str::<serde_json::Value>(&json)
            {
                out.push(v);
            }
        }
        out
    }

    fn count_method(msgs: &[serde_json::Value], method: &str) -> usize {
        msgs.iter().filter(|m| m["method"] == method).count()
    }

    #[test]
    fn dom_hover_highlight_follows_selection_when_enabled() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        // Seed two dom rows so we can move the selection.
        p.dom = vec![
            DomRow {
                depth: 0,
                label: "<html>".into(),
                selector: "html".into(),
                node_id: 1,
            },
            DomRow {
                depth: 0,
                label: "<body>".into(),
                selector: "body".into(),
                node_id: 2,
            },
        ];
        // Drain the initial `Page.navigate` so we see only what follows.
        let _ = drain_cdp(&rx);

        // Off by default — moving the selection doesn't fire highlightNode.
        p.move_dom_sel(1);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 0);

        // Toggle on — immediate fire for the current selection.
        p.toggle_dom_hover_highlight();
        assert!(p.dom_hover_highlight);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 1);

        // Moving the selection now fires highlightNode again.
        p.move_dom_sel(-1);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 1);

        // Toggle off — hideHighlight fires once; subsequent moves are quiet.
        p.toggle_dom_hover_highlight();
        assert!(!p.dom_hover_highlight);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.hideHighlight"), 1);
        p.move_dom_sel(1);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 0);
    }

    #[test]
    fn visible_net_indices_narrow_by_method_and_url() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        for (i, (method, url)) in [
            ("GET", "https://a.test/api/widgets"),
            ("POST", "https://a.test/api/widgets"),
            ("GET", "https://a.test/api/orders"),
            ("PUT", "https://b.test/login"),
        ]
        .iter()
        .enumerate()
        {
            p.note_net_request(
                &format!("rid-{i}"),
                &serde_json::json!({"method": *method, "url": *url}),
            );
        }
        assert_eq!(p.visible_net_indices().len(), 4);

        // URL-substring narrows correctly.
        p.net_filter.push_str("widgets");
        let v = p.visible_net_indices();
        assert_eq!(v, vec![0, 1]);

        // Distinct host narrows to just that host's row.
        p.net_filter.clear();
        p.net_filter.push_str("login");
        let v = p.visible_net_indices();
        assert_eq!(v, vec![3]);

        // Method discriminator works when paired with something
        // url-specific (fuzzy is subsequence-based, so `POST` alone
        // could match unrelated rows whose URLs happen to contain
        // p-o-s-t in order).
        p.net_filter.clear();
        p.net_filter.push_str("POST widgets");
        let v = p.visible_net_indices();
        assert_eq!(v, vec![1]);

        // No match ⇒ empty. Use a query no row can subsequence.
        p.net_filter.clear();
        p.net_filter.push_str("zzz-xxx");
        assert!(p.visible_net_indices().is_empty());

        // Clearing restores everything.
        p.net_filter.clear();
        assert_eq!(p.visible_net_indices().len(), 4);
    }

    #[test]
    fn filter_push_pop_clear_resets_selection() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        for i in 0..3 {
            p.note_net_request(
                &format!("rid-{i}"),
                &serde_json::json!({"method": "GET", "url": format!("https://a/{i}")}),
            );
        }
        p.move_net_sel(2);
        assert_eq!(p.net_sel, 2);

        // Push a char ⇒ selection snaps to top.
        p.net_filter_push('a');
        assert_eq!(p.net_sel, 0);
        // (filter "a" matches all three URLs — `a/0`, `a/1`, `a/2`.)
        assert_eq!(p.visible_net_indices().len(), 3);

        // Pop ⇒ selection snaps to top again.
        p.move_net_sel(2);
        p.net_filter_pop();
        assert_eq!(p.net_sel, 0);
        assert_eq!(p.net_filter, "");
        assert!(!p.net_filter_mode);

        // Enter filter mode + clear-exits.
        p.net_filter_mode = true;
        p.net_filter.push_str("foo");
        p.move_net_sel(1);
        p.net_filter_clear_and_exit();
        assert_eq!(p.net_filter, "");
        assert_eq!(p.net_sel, 0);
        assert!(!p.net_filter_mode);
    }

    #[test]
    fn selected_net_resolves_through_filter() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.note_net_request(
            "a",
            &serde_json::json!({"method": "GET", "url": "https://a.test/x"}),
        );
        p.note_net_request(
            "b",
            &serde_json::json!({"method": "POST", "url": "https://a.test/login"}),
        );
        p.note_net_request(
            "c",
            &serde_json::json!({"method": "GET", "url": "https://a.test/y"}),
        );
        p.net_filter.push_str("POST");
        // visible_net_indices = [1]; net_sel=0 ⇒ resolves to the POST.
        let e = p.selected_net().expect("selection");
        assert_eq!(e.method, "POST");
        assert_eq!(e.url, "https://a.test/login");
    }

    #[test]
    fn screenshot_selected_dom_fires_get_box_model() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![DomRow {
            depth: 0,
            label: "<button>".into(),
            selector: "button".into(),
            node_id: 42,
        }];
        // Drain the initial Page.navigate.
        let _ = drain_cdp(&rx);

        p.screenshot_selected_dom();
        assert!(p.pending_node_screenshot.is_some());

        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "DOM.getBoxModel"), 1);
        let req = msgs
            .iter()
            .find(|m| m["method"] == "DOM.getBoxModel")
            .unwrap();
        assert_eq!(req["params"]["nodeId"], 42);
    }

    #[test]
    fn parse_perf_eval_picks_positive_finite_numbers() {
        let v = serde_json::json!({
            "dns": 12.0,
            "tcp": 0,        // zero ⇒ None (not yet available)
            "ttfb": 234.5,
            "response": -1,  // negative ⇒ None
            "dom_interactive": 555,
            "load": 0,
            "fcp": 1700.0,
            "lcp": null,
        });
        let m = parse_perf_eval(&v).unwrap();
        assert_eq!(m.dns, Some(12.0));
        assert!(m.tcp.is_none());
        assert_eq!(m.ttfb, Some(234.5));
        assert!(m.response.is_none());
        assert_eq!(m.dom_interactive, Some(555.0));
        assert!(m.load.is_none());
        assert_eq!(m.fcp, Some(1700.0));
        assert!(m.lcp.is_none());
    }

    #[test]
    fn parse_perf_eval_propagates_error() {
        let v = serde_json::json!({ "error": "SecurityError" });
        assert!(parse_perf_eval(&v).is_err());
    }

    #[test]
    fn parse_storage_eval_flattens_local_and_session() {
        let v = serde_json::json!({
            "local": [["theme", "dark"], ["user", "alice"]],
            "session": [["tab", "1"]]
        });
        let entries = parse_storage_eval(&v).expect("ok");
        assert_eq!(entries.len(), 3);
        assert!(entries[0].is_local);
        assert_eq!(entries[0].key, "theme");
        assert_eq!(entries[0].value, "dark");
        assert!(entries[1].is_local);
        assert_eq!(entries[1].key, "user");
        assert!(!entries[2].is_local); // sessionStorage
        assert_eq!(entries[2].key, "tab");
    }

    #[test]
    fn parse_storage_eval_propagates_error() {
        let v = serde_json::json!({ "error": "SecurityError: blocked" });
        let err = parse_storage_eval(&v).expect_err("err");
        assert!(err.contains("SecurityError"));
    }

    #[test]
    fn parse_storage_eval_skips_malformed_pairs() {
        let v = serde_json::json!({
            "local": [["good", "ok"], ["lonely"]],
            "session": "not an array"
        });
        let entries = parse_storage_eval(&v).expect("ok");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].key, "good");
    }

    #[test]
    fn fetch_storage_fires_runtime_evaluate_with_iife() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        let _ = drain_cdp(&rx);
        p.fetch_storage();
        assert!(p.pending_storage.is_some());
        let msgs = drain_cdp(&rx);
        let req = msgs
            .iter()
            .find(|m| m["method"] == "Runtime.evaluate")
            .expect("evaluate");
        let expr = req["params"]["expression"].as_str().unwrap_or("");
        assert!(expr.contains("localStorage"));
        assert!(expr.contains("sessionStorage"));
    }

    #[test]
    fn parse_cookies_extracts_known_fields() {
        let arr = serde_json::json!([
            {
                "name": "sid",
                "value": "abc123",
                "domain": ".example.com",
                "path": "/",
                "expires": 1900000000.5,
                "httpOnly": true,
                "secure": true,
                "sameSite": "Strict"
            },
            {
                "name": "csrf",
                "value": "deadbeef",
                "domain": "example.com",
                // path omitted → defaults to "/"
                "expires": -1, // session
                "httpOnly": false,
                "secure": false
                // sameSite omitted → ""
            }
        ]);
        let cookies = parse_cookies(&arr);
        assert_eq!(cookies.len(), 2);
        assert_eq!(cookies[0].name, "sid");
        assert_eq!(cookies[0].value, "abc123");
        assert!(cookies[0].http_only);
        assert!(cookies[0].secure);
        assert_eq!(cookies[0].same_site, "Strict");
        assert_eq!(cookies[0].expires, 1_900_000_000);
        assert_eq!(cookies[1].path, "/");
        assert_eq!(cookies[1].expires, -1);
        assert!(cookies[1].same_site.is_empty());
    }

    #[test]
    fn parse_cookies_handles_non_array_input() {
        assert!(parse_cookies(&serde_json::json!({})).is_empty());
        assert!(parse_cookies(&serde_json::json!(null)).is_empty());
    }

    #[test]
    fn delete_selected_cookie_fires_cdp_and_drops_row() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        let _ = drain_cdp(&rx);
        p.set_cookies(vec![
            CookieEntry {
                name: "a".into(),
                value: "1".into(),
                domain: ".x".into(),
                path: "/".into(),
                expires: -1,
                http_only: false,
                secure: false,
                same_site: String::new(),
            },
            CookieEntry {
                name: "b".into(),
                value: "2".into(),
                domain: ".x".into(),
                path: "/p".into(),
                expires: -1,
                http_only: false,
                secure: false,
                same_site: String::new(),
            },
        ]);
        p.cookies_sel = 1;
        let name = p.delete_selected_cookie();
        assert_eq!(name.as_deref(), Some("b"));
        assert_eq!(p.cookies.len(), 1);
        assert_eq!(p.cookies[0].name, "a");
        // Selection should clamp back into the new range.
        assert_eq!(p.cookies_sel, 0);
        let msgs = drain_cdp(&rx);
        let req = msgs
            .iter()
            .find(|m| m["method"] == "Network.deleteCookies")
            .expect("delete request");
        assert_eq!(req["params"]["name"], "b");
        assert_eq!(req["params"]["domain"], ".x");
        assert_eq!(req["params"]["path"], "/p");
    }

    #[test]
    fn delete_selected_cookie_noops_on_empty_list() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        let _ = drain_cdp(&rx);
        assert!(p.delete_selected_cookie().is_none());
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Network.deleteCookies"), 0);
    }

    #[test]
    fn cookies_panel_state_round_trips() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        let _ = drain_cdp(&rx);

        p.fetch_cookies();
        assert!(p.pending_cookies.is_some());
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Network.getCookies"), 1);

        // Reply lands → set_cookies replaces, clamps selection.
        p.cookies_sel = 5; // out-of-range against fresh list
        p.set_cookies(vec![
            CookieEntry {
                name: "a".into(),
                value: "1".into(),
                domain: ".x".into(),
                path: "/".into(),
                expires: -1,
                http_only: false,
                secure: true,
                same_site: String::new(),
            },
            CookieEntry {
                name: "b".into(),
                value: "2".into(),
                domain: ".x".into(),
                path: "/".into(),
                expires: -1,
                http_only: true,
                secure: false,
                same_site: "Lax".into(),
            },
        ]);
        assert_eq!(p.cookies.len(), 2);
        assert_eq!(p.cookies_sel, 1); // clamped

        p.move_cookies_sel(-3);
        assert_eq!(p.cookies_sel, 0);
        p.move_cookies_sel(5);
        assert_eq!(p.cookies_sel, 1);
        assert_eq!(p.selected_cookie().unwrap().name, "b");
    }

    #[test]
    fn scroll_selected_dom_into_view_fires_cdp() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![DomRow {
            depth: 0,
            label: "<button>".into(),
            selector: "button".into(),
            node_id: 99,
        }];
        let _ = drain_cdp(&rx);

        p.scroll_selected_dom_into_view();
        let msgs = drain_cdp(&rx);
        let req = msgs
            .iter()
            .find(|m| m["method"] == "DOM.scrollIntoViewIfNeeded")
            .expect("scroll request");
        assert_eq!(req["params"]["nodeId"], 99);
    }

    #[test]
    fn scroll_selected_dom_into_view_skips_synthetic() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![DomRow {
            depth: 0,
            label: "<!DOCTYPE html>".into(),
            selector: String::new(),
            node_id: 0,
        }];
        let _ = drain_cdp(&rx);
        p.scroll_selected_dom_into_view();
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "DOM.scrollIntoViewIfNeeded"), 0);
    }

    #[test]
    fn screenshot_selected_dom_skips_synthetic_nodes() {
        // node_id == 0 (synthetic / un-screenshottable) ⇒ no-op.
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![DomRow {
            depth: 0,
            label: "<!DOCTYPE html>".into(),
            selector: String::new(),
            node_id: 0,
        }];
        let _ = drain_cdp(&rx);
        p.screenshot_selected_dom();
        assert!(p.pending_node_screenshot.is_none());
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "DOM.getBoxModel"), 0);
    }

    #[test]
    fn screenshot_clip_fires_capture_screenshot_with_clip() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        let _ = drain_cdp(&rx);
        p.screenshot_clip(10.0, 20.0, 100.0, 40.0);
        assert!(p.pending_screenshot.is_some());
        let msgs = drain_cdp(&rx);
        let req = msgs
            .iter()
            .find(|m| m["method"] == "Page.captureScreenshot")
            .expect("capture");
        assert_eq!(req["params"]["clip"]["x"], 10.0);
        assert_eq!(req["params"]["clip"]["y"], 20.0);
        assert_eq!(req["params"]["clip"]["width"], 100.0);
        assert_eq!(req["params"]["clip"]["height"], 40.0);
    }

    #[test]
    fn visible_dom_indices_narrow_by_label_or_selector() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![
            DomRow {
                depth: 0,
                label: r#"<div id="main" class="card">"#.into(),
                selector: "html > body > div#main.card".into(),
                node_id: 1,
            },
            DomRow {
                depth: 1,
                label: r#"<button class="primary">"#.into(),
                selector: "html > body > div#main > button.primary".into(),
                node_id: 2,
            },
            DomRow {
                depth: 2,
                label: r#"<span>"#.into(),
                selector: "html > body > div#main > button > span".into(),
                node_id: 3,
            },
        ];
        // No filter ⇒ all visible.
        assert_eq!(p.visible_dom_indices().len(), 3);

        // Selector-substring narrows correctly.
        p.dom_filter.push_str("button");
        let v = p.visible_dom_indices();
        assert_eq!(v, vec![1, 2]); // both rows have `button` in their selector

        // Label-substring narrows correctly.
        p.dom_filter.clear();
        p.dom_filter.push_str("primary");
        let v = p.visible_dom_indices();
        assert_eq!(v, vec![1]);

        // No match ⇒ empty.
        p.dom_filter.clear();
        p.dom_filter.push_str("zzz-xxx");
        assert!(p.visible_dom_indices().is_empty());

        // Clear restores everything.
        p.dom_filter.clear();
        assert_eq!(p.visible_dom_indices().len(), 3);
    }

    #[test]
    fn dom_filter_push_pop_clear_resets_selection() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![
            DomRow {
                depth: 0,
                label: "<a>".into(),
                selector: "a".into(),
                node_id: 1,
            },
            DomRow {
                depth: 0,
                label: "<b>".into(),
                selector: "b".into(),
                node_id: 2,
            },
            DomRow {
                depth: 0,
                label: "<c>".into(),
                selector: "c".into(),
                node_id: 3,
            },
        ];
        p.move_dom_sel(2);
        assert_eq!(p.dom_sel, 2);

        // Push a char ⇒ selection snaps to top.
        p.dom_filter_push('a');
        assert_eq!(p.dom_sel, 0);

        // Pop ⇒ selection snaps to top again.
        p.move_dom_sel(2);
        p.dom_filter_pop();
        assert_eq!(p.dom_sel, 0);
        assert_eq!(p.dom_filter, "");

        // Enter filter mode + clear-exits.
        p.dom_filter_mode = true;
        p.dom_filter.push_str("foo");
        p.move_dom_sel(1);
        p.dom_filter_clear_and_exit();
        assert_eq!(p.dom_filter, "");
        assert_eq!(p.dom_sel, 0);
        assert!(!p.dom_filter_mode);
    }

    #[test]
    fn selected_dom_resolves_through_filter() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![
            DomRow {
                depth: 0,
                label: "<div>".into(),
                selector: "div".into(),
                node_id: 11,
            },
            DomRow {
                depth: 0,
                label: "<button>".into(),
                selector: "button".into(),
                node_id: 22,
            },
            DomRow {
                depth: 0,
                label: "<span>".into(),
                selector: "span".into(),
                node_id: 33,
            },
        ];
        p.dom_filter.push_str("button");
        // visible_dom_indices = [1]; dom_sel = 0 ⇒ resolves to button.
        let r = p.selected_dom().expect("selection");
        assert_eq!(r.node_id, 22);
    }

    #[test]
    fn set_dom_sel_clamps_and_fires_hover_when_enabled() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut p = BrowserPane::new("about:blank".into(), tx);
        p.dom = vec![
            DomRow {
                depth: 0,
                label: "a".into(),
                selector: "a".into(),
                node_id: 11,
            },
            DomRow {
                depth: 0,
                label: "b".into(),
                selector: "b".into(),
                node_id: 22,
            },
        ];
        let _ = drain_cdp(&rx);

        p.set_dom_sel(99); // clamp to last
        assert_eq!(p.dom_sel, 1);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 0); // off

        p.toggle_dom_hover_highlight();
        let _ = drain_cdp(&rx);
        p.set_dom_sel(0);
        let msgs = drain_cdp(&rx);
        assert_eq!(count_method(&msgs, "Overlay.highlightNode"), 1); // on
    }
}
