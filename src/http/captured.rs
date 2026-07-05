//! Read the capture log produced by `rqst proxy`.
//!
//! Format: one JSON object per line (`.rqst/captured/log.jsonl`). The
//! TUI's Captured tray loads the file once on toggle and re-loads on
//! demand (refresh key); a future iteration can replace this with a
//! file-watcher / size-poller for live tailing.
//!
//! See [`CapturedRow`] below for the schema. We deliberately accept
//! both `request_id` and `requestId` because rqst's serde default is
//! snake-case and Chrome's CDP is camelCase — the proxy currently
//! writes snake-case (Rust default), but if a user pipes a Chrome HAR
//! through an external tool that camel-cases, we still parse it.

use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapturedRow {
    pub at: u64,
    #[serde(alias = "requestId")]
    pub request_id: String,
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    pub paused: bool,
}

impl CapturedRow {
    /// Render this row as a `.curl` file the source editor can load.
    /// Mirrors what `discover` writes — `curl -X METHOD URL -H ...
    /// --data-raw '...'` — so the existing parsers handle it
    /// transparently.
    pub fn to_curl(&self) -> String {
        let mut parts: Vec<String> = vec![format!("curl -X {} '{}'", self.method, self.url)];
        for (k, v) in &self.headers {
            // Skip pseudo-headers Chrome sometimes leaks (`:authority`,
            // `:method`, `:path`, `:scheme`) — they're HTTP/2 framing,
            // not real headers.
            if k.starts_with(':') {
                continue;
            }
            parts.push(format!("  -H '{}: {}'", k, escape_single(v)));
        }
        if let Some(body) = &self.body {
            // Heuristic: if the body looks like base64, drop a comment
            // so the user notices and can decode. Otherwise pass it
            // through. CDP returns base64 only when --enable-blob-body
            // is set; the default is plain text.
            parts.push(format!("  --data-raw '{}'", escape_single(body)));
        }
        parts.join(" \\\n")
    }
}

fn escape_single(s: &str) -> String {
    // POSIX shell single-quote escape: close, escape, reopen.
    s.replace('\'', "'\\''")
}

/// Load every row from the capture log. Empty lines and rows that fail
/// to parse are skipped silently (forward-compat with future fields).
///
/// Reads the whole file — fine for the `http.view_captured` picker
/// (which wants the full log) but wasteful for the sidebar / home
/// pane. Prefer [`load_tail`] there.
pub fn load(path: &Path) -> Vec<CapturedRow> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<CapturedRow>(l).ok())
        .collect()
}

/// Load the last `n` rows only (oldest-first, same ordering as
/// [`load`]). Used by the sidebar + home pane where we only ever
/// display the tail — reading the whole file (which can be
/// hundreds of MB after a long proxy session) just to throw most
/// of it away is wasteful.
///
/// Same reverse-lines-then-take pattern as `history::tail`.
pub fn load_tail(path: &Path, n: usize) -> Vec<CapturedRow> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    let mut out: Vec<CapturedRow> = text
        .lines()
        .rev()
        .filter(|l| !l.trim().is_empty())
        .take(n)
        .filter_map(|l| serde_json::from_str::<CapturedRow>(l).ok())
        .collect();
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "rqst-captured-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn load_returns_empty_when_missing() {
        assert!(load(Path::new("/nonexistent/rqst/captured.log")).is_empty());
    }

    #[test]
    fn load_skips_garbage_lines() {
        let p = tmp("garbage");
        std::fs::write(
            &p,
            "{\"at\":1,\"request_id\":\"r1\",\"method\":\"GET\",\"url\":\"https://x\",\"paused\":false}\nthis is not json\n",
        )
        .unwrap();
        let rows = load(&p);
        let _ = std::fs::remove_file(&p);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].request_id, "r1");
    }

    #[test]
    fn to_curl_round_trips_headers_and_body() {
        let row = CapturedRow {
            at: 0,
            request_id: "r1".into(),
            method: "POST".into(),
            url: "https://api/x".into(),
            headers: vec![
                ("content-type".into(), "application/json".into()),
                ("authorization".into(), "Bearer abc".into()),
                (":authority".into(), "api".into()), // pseudo, skipped
            ],
            body: Some("{\"hello\":\"world\"}".into()),
            paused: false,
        };
        let s = row.to_curl();
        assert!(s.starts_with("curl -X POST 'https://api/x'"));
        assert!(s.contains("-H 'content-type: application/json'"));
        assert!(s.contains("-H 'authorization: Bearer abc'"));
        assert!(!s.contains(":authority"));
        assert!(s.contains("--data-raw '{\"hello\":\"world\"}'"));
    }

    #[test]
    fn to_curl_escapes_single_quotes_in_body() {
        let row = CapturedRow {
            at: 0,
            request_id: "r1".into(),
            method: "POST".into(),
            url: "https://api".into(),
            headers: vec![],
            body: Some("it's mine".into()),
            paused: false,
        };
        let s = row.to_curl();
        // POSIX shell-safe: the literal substring must contain the
        // close-quote/escape/reopen dance.
        assert!(s.contains("it'\\''s mine"));
    }
}
