//! Append-only history log at `<workspace>/.rqst/history.jsonl`.
//!
//! One JSON line per completed request. Used for ad-hoc forensic queries:
//!   grep '"status":401' .rqst/history.jsonl
//!   jq -c 'select(.duration_ms > 1000)' .rqst/history.jsonl
//!
//! Append is open(append) + write — POSIX guarantees atomic appends for
//! lines under PIPE_BUF (4096 on Linux/macOS), and our lines are well
//! under that. No rename trick needed.
//!
//! 2026-06-20 — also mirror each line into a *global* log at
//! `~/.config/mnml/history-global.jsonl` with a `"workspace"` field
//! identifying the source. Lets `:http.history_global` recall a
//! request you made from any project, useful when you remember
//! firing it but not which workspace you were in.

use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Entry<'a> {
    pub method: &'a str,
    pub url: &'a str,
    pub status: Option<u16>,
    pub duration_ms: Option<u128>,
    pub body_bytes: Option<usize>,
    pub error: Option<&'a str>,
    /// http-2nd 2026-06-28 SEV-3c — request headers as
    /// `Vec<(name, value)>`. Stored alongside the response
    /// metadata so the history picker can rebuild a usable
    /// curl command, not just `curl -X METHOD URL`.
    pub headers: Option<&'a [(String, String)]>,
    /// The serialised request body (utf-8 string). None when
    /// the request was bodyless.
    pub request_body: Option<&'a str>,
}

pub fn append(workspace: &Path, entry: &Entry) {
    let dir = workspace.join(".rqst");
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = dir.join("history.jsonl");
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let payload = serde_json::json!({
        "ts": ts,
        "method": entry.method,
        "url": entry.url,
        "status": entry.status,
        "duration_ms": entry.duration_ms,
        "body_bytes": entry.body_bytes,
        "error": entry.error,
        "headers": entry.headers,
        "request_body": entry.request_body,
    });
    let mut line = match serde_json::to_string(&payload) {
        Ok(s) => s,
        Err(_) => return,
    };
    line.push('\n');
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Wrapper that writes to the workspace log AND mirrors to the
/// global log. The global log lets `:http.history_global` show
/// cross-workspace request history. App callers should prefer this
/// over [`append`] — tests use [`append`] directly to avoid HOME
/// pollution.
pub fn append_with_global_mirror(workspace: &Path, entry: &Entry) {
    append(workspace, entry);
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    append_global(workspace, entry, ts);
}

/// Mirror an entry into `~/.config/mnml/history-global.jsonl` with a
/// `workspace` field added so `:http.history_global` can show where
/// the request originated. Best-effort — silently no-ops if HOME
/// isn't set or the file can't be opened.
fn append_global(workspace: &Path, entry: &Entry, ts: u128) {
    let Some(path) = global_history_path() else {
        return;
    };
    if let Some(parent) = path.parent()
        && fs::create_dir_all(parent).is_err()
    {
        return;
    }
    let workspace_label = workspace
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    let payload = serde_json::json!({
        "ts": ts,
        "workspace": workspace_label,
        "workspace_path": workspace.to_string_lossy(),
        "method": entry.method,
        "url": entry.url,
        "status": entry.status,
        "duration_ms": entry.duration_ms,
        "body_bytes": entry.body_bytes,
        "error": entry.error,
        "headers": entry.headers,
        "request_body": entry.request_body,
    });
    let mut line = match serde_json::to_string(&payload) {
        Ok(s) => s,
        Err(_) => return,
    };
    line.push('\n');
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// `~/.config/mnml/history-global.jsonl`, or whatever
/// `$MNML_HISTORY_GLOBAL_PATH` points to (used by tests to avoid
/// touching the real user log). Returns `None` if neither is set.
pub fn global_history_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("MNML_HISTORY_GLOBAL_PATH") {
        return Some(PathBuf::from(p));
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".config/mnml/history-global.jsonl"))
}

/// Read the last `n` entries from the global history log (most
/// recent last). Used by `:http.history_global`.
pub fn tail_global(n: usize) -> Vec<Value> {
    let Some(path) = global_history_path() else {
        return Vec::new();
    };
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut out: Vec<Value> = text
        .lines()
        .rev()
        .take(n)
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    out.reverse();
    out
}

/// Rebuild a `curl` command from a history entry. Uses the persisted
/// `headers` + `request_body` when present; falls back to the minimal
/// `curl -X METHOD URL` form for older entries. Returns
/// `(curl_text, method, url)` so callers can drive `open_curl_scratch`.
/// Shared between the `HistoryRows` picker and the sectioned HTTP
/// sidebar so both re-fire history the same way.
pub fn entry_to_curl(v: &Value) -> (String, String, String) {
    let method = v
        .get("method")
        .and_then(|s| s.as_str())
        .unwrap_or("GET")
        .to_string();
    let url = v
        .get("url")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();
    let mut curl = String::from("curl");
    curl.push_str(&format!(" -X {method}"));
    if let Some(headers) = v.get("headers").and_then(|h| h.as_array()) {
        for h in headers {
            if let Some(pair) = h.as_array()
                && pair.len() == 2
                && let (Some(name), Some(value)) = (pair[0].as_str(), pair[1].as_str())
            {
                let escaped_value = value.replace('\'', r"'\''");
                curl.push_str(&format!(" -H '{name}: {escaped_value}'"));
            }
        }
    }
    if let Some(body) = v.get("request_body").and_then(|b| b.as_str())
        && !body.is_empty()
    {
        let escaped_body = body.replace('\'', r"'\''");
        curl.push_str(&format!(" --data-raw '{escaped_body}'"));
    }
    curl.push_str(&format!(" '{url}'"));
    (curl, method, url)
}

/// Read the last `n` history entries (most recent last). Used by the
/// (future) Ctrl+H history modal. Reads the entire file and tail-truncates,
/// which is fine for files up to a few MB; rotate later if needed.
pub fn tail(workspace: &Path, n: usize) -> Vec<Value> {
    let path = workspace.join(".rqst").join("history.jsonl");
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut out: Vec<Value> = text
        .lines()
        .rev()
        .take(n)
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rqst-history-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn append_writes_jsonl_in_dot_rqst() {
        let dir = temp("append");
        append(
            &dir,
            &Entry {
                method: "POST",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(123),
                body_bytes: Some(456),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        let path = dir.join(".rqst/history.jsonl");
        assert!(path.exists());
        let text = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 1);
        let parsed: Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(parsed["method"], "POST");
        assert_eq!(parsed["status"], 200);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tail_returns_last_n_entries_in_order() {
        let dir = temp("tail");
        for i in 0..5 {
            append(
                &dir,
                &Entry {
                    method: "GET",
                    url: &format!("https://x/{i}"),
                    status: Some(200),
                    duration_ms: Some(i),
                    body_bytes: Some(0),
                    error: None,
                    headers: None,
                    request_body: None,
                },
            );
        }
        let recent = tail(&dir, 3);
        assert_eq!(recent.len(), 3);
        // last three URLs in insertion order
        assert_eq!(recent[0]["url"], "https://x/2");
        assert_eq!(recent[1]["url"], "https://x/3");
        assert_eq!(recent[2]["url"], "https://x/4");
        let _ = fs::remove_dir_all(&dir);
    }

    // Serialize the two tests that mutate the process-wide
    // MNML_HISTORY_GLOBAL_PATH env var. Without this, cargo's
    // parallel test runner races them.
    static GLOBAL_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn append_with_global_mirror_writes_workspace_and_global() {
        let _guard = GLOBAL_ENV_LOCK.lock().unwrap();
        let dir = temp("mirror");
        let global = dir.join("global.jsonl");
        // SAFETY: env var override is per-process; serialized via
        // GLOBAL_ENV_LOCK so no other test reads while we mutate.
        unsafe {
            std::env::set_var("MNML_HISTORY_GLOBAL_PATH", &global);
        }
        append_with_global_mirror(
            &dir,
            &Entry {
                method: "GET",
                url: "https://x/global",
                status: Some(200),
                duration_ms: Some(7),
                body_bytes: Some(0),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        unsafe {
            std::env::remove_var("MNML_HISTORY_GLOBAL_PATH");
        }
        assert!(dir.join(".rqst/history.jsonl").exists());
        assert!(global.exists());
        let text = fs::read_to_string(&global).unwrap();
        let entry: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(entry["url"], "https://x/global");
        assert!(entry["workspace"].as_str().is_some());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tail_global_returns_n_recent_from_env_path() {
        let _guard = GLOBAL_ENV_LOCK.lock().unwrap();
        let dir = temp("tail-global");
        let global = dir.join("global.jsonl");
        unsafe {
            std::env::set_var("MNML_HISTORY_GLOBAL_PATH", &global);
        }
        for i in 0..4 {
            append_with_global_mirror(
                &dir,
                &Entry {
                    method: "GET",
                    url: &format!("https://x/g/{i}"),
                    status: Some(200),
                    duration_ms: Some(i),
                    body_bytes: Some(0),
                    error: None,
                    headers: None,
                    request_body: None,
                },
            );
        }
        let recent = tail_global(2);
        unsafe {
            std::env::remove_var("MNML_HISTORY_GLOBAL_PATH");
        }
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0]["url"], "https://x/g/2");
        assert_eq!(recent[1]["url"], "https://x/g/3");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_records_error_when_set() {
        let dir = temp("err");
        append(
            &dir,
            &Entry {
                method: "GET",
                url: "https://broken",
                status: None,
                duration_ms: None,
                body_bytes: None,
                error: Some("connection refused"),
                headers: None,
                request_body: None,
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries[0]["status"], serde_json::Value::Null);
        assert_eq!(entries[0]["error"], "connection refused");
        let _ = fs::remove_dir_all(&dir);
    }

    /// test-writer 2026-06-28 coverage gap: the new headers +
    /// request_body fields must persist correctly. Without this
    /// lock-in, an accidental rename in the json! call would
    /// silently break picker.rs's curl-rebuild path.
    #[test]
    fn append_writes_headers_and_body_to_jsonl() {
        let dir = temp("headers-body");
        let headers = vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("Authorization".to_string(), "Bearer abc123".to_string()),
        ];
        let body = r#"{"name":"alice"}"#;
        append(
            &dir,
            &Entry {
                method: "POST",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(50),
                body_bytes: Some(10),
                error: None,
                headers: Some(&headers),
                request_body: Some(body),
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries.len(), 1);
        let v = &entries[0];
        let h = v["headers"].as_array().expect("headers is array");
        assert_eq!(h.len(), 2);
        assert_eq!(h[0][0], "Content-Type");
        assert_eq!(h[0][1], "application/json");
        assert_eq!(h[1][0], "Authorization");
        assert_eq!(h[1][1], "Bearer abc123");
        assert_eq!(v["request_body"].as_str(), Some(body));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_with_none_headers_and_body_serialises_null() {
        let dir = temp("none-headers");
        append(
            &dir,
            &Entry {
                method: "GET",
                url: "https://x/y",
                status: Some(200),
                duration_ms: Some(5),
                body_bytes: Some(0),
                error: None,
                headers: None,
                request_body: None,
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries[0]["headers"], serde_json::Value::Null);
        assert_eq!(entries[0]["request_body"], serde_json::Value::Null);
        let _ = fs::remove_dir_all(&dir);
    }
}
