//! Mock = a frozen response saved next to a request file. Useful for
//! offline review or for `rqst replay` against canned data.
//!
//! File format (JSON, sibling with `.mock.json` suffix):
//!
//! ```json
//! {
//!   "status": 401,
//!   "status_text": "Unauthorized",
//!   "headers": [["content-type", "application/json"]],
//!   "body": "{\"error\":\"token expired\"}",
//!   "ts": 1234567890
//! }
//! ```
//!
//! Save on demand via `Ctrl+Shift+M` from the TUI; a CLI `rqst replay
//! <path>` prints the mock as if it were a live response.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Mock {
    pub status: u16,
    pub status_text: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

pub fn save(path: &Path, mock: &Mock) -> Result<(), std::io::Error> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)?;
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let payload = json!({
        "status": mock.status,
        "status_text": mock.status_text,
        "headers": mock.headers.iter().map(|(k, v)| vec![k.clone(), v.clone()]).collect::<Vec<_>>(),
        "body": mock.body,
        "ts": ts,
    });
    fs::write(
        path,
        serde_json::to_string_pretty(&payload).unwrap_or_default(),
    )?;
    Ok(())
}

pub fn load(path: &Path) -> Result<Mock, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("parse mock: {e}"))?;
    let status = v
        .get("status")
        .and_then(|s| s.as_u64())
        .ok_or_else(|| "mock missing status".to_string())? as u16;
    let status_text = v
        .get("status_text")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();
    let body = v
        .get("body")
        .and_then(|s| s.as_str())
        .unwrap_or("")
        .to_string();
    let headers = v
        .get("headers")
        .and_then(|h| h.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|pair| {
                    let p = pair.as_array()?;
                    let k = p.first()?.as_str()?.to_string();
                    let val = p.get(1)?.as_str()?.to_string();
                    Some((k, val))
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Mock {
        status,
        status_text,
        headers,
        body,
    })
}

/// Default mock path for a given request file: same path with `.mock.json`
/// suffix. e.g. `requests/auth/login.curl` → `requests/auth/login.curl.mock.json`.
pub fn sibling_path(request: &Path) -> PathBuf {
    let mut p = request.as_os_str().to_os_string();
    p.push(".mock.json");
    PathBuf::from(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rqst-mock-{name}-{}-{}",
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
    fn save_then_load_round_trips() {
        let dir = temp("rt");
        let path = dir.join("foo.mock.json");
        let m = Mock {
            status: 401,
            status_text: "Unauthorized".to_string(),
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: r#"{"error":"expired"}"#.to_string(),
        };
        save(&path, &m).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(loaded.status, 401);
        assert_eq!(loaded.status_text, "Unauthorized");
        assert_eq!(loaded.headers, m.headers);
        assert_eq!(loaded.body, m.body);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn sibling_path_appends_mock_json_suffix() {
        let p = sibling_path(Path::new("requests/auth/login.curl"));
        assert_eq!(p.to_string_lossy(), "requests/auth/login.curl.mock.json");
    }

    #[test]
    fn load_reports_missing_status() {
        let dir = temp("missing");
        let path = dir.join("bad.mock.json");
        fs::write(&path, "{}").unwrap();
        let err = load(&path).unwrap_err();
        assert!(err.contains("missing status"));
        let _ = fs::remove_dir_all(&dir);
    }
}
