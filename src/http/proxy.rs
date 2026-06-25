//! Headless CDP capture — ports the spirit of rqst's `rqst proxy`
//! into mnml. Spawns headless Chrome, attaches via the existing
//! `crate::cdp::run_session` machinery, subscribes to Network
//! events, and appends every captured request to
//! `<workspace>/.rqst/captured/log.jsonl`.
//!
//! Surface today (phase 4 follow-up of the rqst→mnml port-back):
//!   * Used by the `mnml proxy --url URL` CLI subcommand
//!   * Runs until either `--seconds N` elapses or `Network.loadingFinished`
//!     stops firing for `--idle-ms` (default 2000)
//!
//! Pause/edit/continue (Fetch domain) is NOT ported — the existing
//! mnml CDP only enables `Network.enable`, which is observation
//! only. For pre-flight mutations, use rqst-style with the browser
//! pane's UI in mnml (`Pane::Browser` + `http.capture_now` reads
//! the same NetEntry list).
//!
//! For format compatibility with the existing in-app
//! `http.view_captured` picker, this writer emits the same
//! `CapturedRow` shape as `crate::http::captured`.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::cdp::{CdpEvent, run_session};
use crate::http::captured::CapturedRow;

#[derive(Debug, Clone)]
pub struct Options {
    pub workspace: PathBuf,
    pub url: String,
    /// Hard timeout for the whole capture session. None ⇒ no cap.
    pub max_seconds: Option<u64>,
    /// Quiescence cutoff — stop after this much time has passed
    /// with no new network event. Default 2000ms.
    pub idle_ms: u64,
    /// Print each captured request to stderr as it arrives.
    pub verbose: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            workspace: PathBuf::from("."),
            url: String::new(),
            max_seconds: None,
            idle_ms: 2000,
            verbose: true,
        }
    }
}

/// Path mnml writes the JSONL log to. Same path the
/// `http.view_captured` palette command reads.
pub fn captured_log_path(workspace: &Path) -> PathBuf {
    workspace.join(".rqst").join("captured").join("log.jsonl")
}

/// Drive a headless CDP capture session. Returns the count of
/// requests written to the log.
pub fn run(opts: Options) -> Result<usize, String> {
    use std::fs;
    use std::io::Write;

    let log_path = captured_log_path(&opts.workspace);
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create log dir: {e}"))?;
    }
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| format!("open {}: {e}", log_path.display()))?;

    // Chrome's user-data-dir for this run — keep it fresh so cached
    // auth from a prior session doesn't leak into the log.
    let profile_dir =
        std::env::temp_dir().join(format!("mnml-proxy-profile-{}", std::process::id()));
    fs::create_dir_all(&profile_dir).map_err(|e| format!("mkdir profile: {e}"))?;

    let (event_tx, event_rx) = mpsc::channel::<CdpEvent>();
    // The cmd_tx half stays in scope here so the worker doesn't see
    // Disconnected and bail before we're ready to stop it; dropping
    // it at end-of-fn signals exit.
    let (cmd_tx, cmd_rx) = mpsc::channel::<crate::cdp::CdpCommand>();
    let url = opts.url.clone();
    let pd = profile_dir.clone();
    let session_handle = std::thread::spawn(move || {
        run_session(&url, &pd, true, &event_tx, &cmd_rx);
    });

    let started = Instant::now();
    let mut last_event = Instant::now();
    let mut written: usize = 0;

    loop {
        // Drain anything queued; block briefly so we don't busy-poll.
        match event_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(CdpEvent::Connected { ws_url }) => {
                if opts.verbose {
                    eprintln!("mnml proxy: attached to {ws_url}");
                }
            }
            Ok(CdpEvent::Message(v)) => {
                last_event = Instant::now();
                if let Some(method) = v.get("method").and_then(|m| m.as_str())
                    && method == "Network.requestWillBeSent"
                    && let Some(row) = decode_network_request(&v)
                {
                    if opts.verbose {
                        eprintln!("  {} {}", row.method, row.url);
                    }
                    if let Ok(line) = serde_json::to_string(&row) {
                        let _ = writeln!(log, "{line}");
                        written += 1;
                    }
                }
            }
            Ok(CdpEvent::Closed(reason)) => {
                if opts.verbose {
                    eprintln!("mnml proxy: session closed — {reason}");
                }
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => { /* fall through */ }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        // Termination checks.
        if let Some(cap) = opts.max_seconds
            && started.elapsed() >= Duration::from_secs(cap)
        {
            if opts.verbose {
                eprintln!("mnml proxy: --seconds {cap} elapsed, stopping ({written} captured)");
            }
            break;
        }
        if written > 0 && last_event.elapsed() >= Duration::from_millis(opts.idle_ms) {
            if opts.verbose {
                eprintln!(
                    "mnml proxy: idle for {}ms, stopping ({written} captured)",
                    opts.idle_ms
                );
            }
            break;
        }
    }
    drop(cmd_tx); // worker's Receiver will see Disconnected → exit
    let _ = session_handle.join();
    // Best-effort clean up the throwaway profile.
    let _ = fs::remove_dir_all(&profile_dir);
    Ok(written)
}

/// Decode a `Network.requestWillBeSent` event into a `CapturedRow`.
/// Returns `None` if the event shape is unexpected.
fn decode_network_request(v: &serde_json::Value) -> Option<CapturedRow> {
    let p = v.get("params")?;
    let request = p.get("request")?;
    let request_id = p.get("requestId")?.as_str()?.to_string();
    let method = request.get("method")?.as_str()?.to_string();
    let url = request.get("url")?.as_str()?.to_string();
    let headers: Vec<(String, String)> = request
        .get("headers")
        .and_then(|h| h.as_object())
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();
    let body = request
        .get("postData")
        .and_then(|b| b.as_str())
        .map(str::to_string);
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    Some(CapturedRow {
        at,
        request_id,
        method,
        url,
        headers,
        body,
        paused: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_network_request_extracts_method_and_url() {
        let v = serde_json::json!({
            "method": "Network.requestWillBeSent",
            "params": {
                "requestId": "r1",
                "request": {
                    "method": "POST",
                    "url": "https://api/x",
                    "headers": {"content-type": "application/json"},
                    "postData": "{\"k\":1}"
                }
            }
        });
        let row = decode_network_request(&v).unwrap();
        assert_eq!(row.method, "POST");
        assert_eq!(row.url, "https://api/x");
        assert_eq!(row.body.as_deref(), Some("{\"k\":1}"));
        assert!(row.headers.iter().any(|(k, _)| k == "content-type"));
    }

    #[test]
    fn captured_log_path_under_workspace() {
        let p = captured_log_path(Path::new("/tmp/x"));
        assert!(p.ends_with(".rqst/captured/log.jsonl"));
    }

    #[test]
    fn decode_returns_none_on_missing_fields() {
        let v = serde_json::json!({"method": "Network.requestWillBeSent", "params": {}});
        assert!(decode_network_request(&v).is_none());
    }
}
