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

pub struct BrowserPane {
    /// The page's current URL (updated on `Page.frameNavigated`).
    pub url: String,
    /// Down-channel to the CDP worker (commands; `Drop` sends `Close`).
    pub cmd_tx: Sender<CdpCommand>,
    pub log: Vec<LogLine>,
    /// Next JSON-RPC id for requests this pane issues.
    next_id: i64,
    /// The id of an in-flight `Runtime.evaluate`, so its reply can be matched.
    pub pending_eval: Option<i64>,
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
            log: Vec::new(),
            next_id: 100,
            pending_eval: None,
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

    fn fresh_id(&mut self) -> i64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Build + send a JSON-RPC request with a fresh id; returns that id.
    fn send(&mut self, build: impl FnOnce(i64) -> String) -> i64 {
        let id = self.fresh_id();
        let _ = self.cmd_tx.send(CdpCommand::Send(build(id)));
        id
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
