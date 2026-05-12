//! `Pane::Request` — a request fired from a `.http` / `.curl` / `.rest` editor
//! (the `rqst.send` command), with its response below: status line, headers,
//! pretty-printed body, and `@assert` / `@capture` results. The send runs on a
//! background thread; [`crate::app::App::tick`] polls the result channel and
//! flips the pane from [`RunState::Sending`] to `Done` / `Failed`. The full
//! Postman-style editable field tabs are a later refinement — for now you edit
//! the `.http` file in a normal editor and re-fire from there.

use std::path::PathBuf;
use std::time::Duration;

use crate::http::Request;
use crate::http::script::{AssertionResult, Script};

pub struct RequestPane {
    /// The `.http`/`.curl`/`.rest` file the request was launched from (title only).
    pub source_path: Option<PathBuf>,
    /// The request being sent — templates already expanded, `@set-*` already applied.
    pub request: Request,
    /// Directives parsed from the same source (re-run on every send).
    pub script: Script,
    /// Set when this pane fires a send, matched against the worker's reply so a
    /// stale result (pane re-fired, or indices shifted) is ignored.
    pub job_id: u64,
    pub state: RunState,
    /// Top rendered row.
    pub scroll: usize,
}

pub enum RunState {
    Sending,
    Done(Box<ResponseView>),
    Failed(String),
}

pub struct ResponseView {
    pub status: u16,
    pub status_text: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub elapsed: Duration,
    pub assertions: Vec<AssertionResult>,
    pub captures: Vec<(String, String)>,
}

impl RequestPane {
    pub fn new(
        source_path: Option<PathBuf>,
        request: Request,
        script: Script,
        job_id: u64,
    ) -> Self {
        RequestPane {
            source_path,
            request,
            script,
            job_id,
            state: RunState::Sending,
            scroll: 0,
        }
    }

    pub fn title(&self) -> String {
        let base = self
            .source_path
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "request".to_string());
        let marker = match &self.state {
            RunState::Sending => "…",
            RunState::Failed(_) => "✗",
            RunState::Done(r) if r.assertions.iter().any(|a| !a.passed) => "✗",
            RunState::Done(_) => "⚡",
        };
        format!("{base} {marker}")
    }

    /// `METHOD url` as a one-liner.
    pub fn request_line(&self) -> String {
        format!("{} {}", self.request.method, self.request.url)
    }

    /// Render this request as a `curl` command line (for `rqst.copy_curl`).
    pub fn as_curl(&self) -> String {
        let mut out = format!("curl '{}'", self.request.url);
        if self.request.method != "GET"
            && !(self.request.method == "POST" && self.request.body.is_some())
        {
            out.push_str(&format!(" -X {}", self.request.method));
        }
        for (k, v) in &self.request.headers {
            out.push_str(&format!(" \\\n  -H '{}: {}'", k, v.replace('\'', "'\\''")));
        }
        if let Some(body) = &self.request.body {
            out.push_str(&format!(
                " \\\n  --data-raw '{}'",
                body.replace('\'', "'\\''")
            ));
        }
        out
    }
}
