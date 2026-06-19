//! Append-only history log at `<workspace>/.rqst/history.jsonl`.
//!
//! One JSON line per completed request. Used for ad-hoc forensic queries:
//!   grep '"status":401' .rqst/history.jsonl
//!   jq -c 'select(.duration_ms > 1000)' .rqst/history.jsonl
//!
//! Append is open(append) + write — POSIX guarantees atomic appends for
//! lines under PIPE_BUF (4096 on Linux/macOS), and our lines are well
//! under that. No rename trick needed.

use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

pub struct Entry<'a> {
    pub method: &'a str,
    pub url: &'a str,
    pub status: Option<u16>,
    pub duration_ms: Option<u128>,
    pub body_bytes: Option<usize>,
    pub error: Option<&'a str>,
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
            },
        );
        let entries = tail(&dir, 1);
        assert_eq!(entries[0]["status"], serde_json::Value::Null);
        assert_eq!(entries[0]["error"], "connection refused");
        let _ = fs::remove_dir_all(&dir);
    }
}
