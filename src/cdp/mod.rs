//! Chrome DevTools Protocol — launch a Chrome/Chromium with remote debugging on a
//! free port, connect to its first page over the DevTools WebSocket, and drive it
//! from a [`Pane::Browser`](crate::pane::Pane::Browser): a live log of console
//! output + page navigations, `g` to navigate, `e` to eval JS in the page, `r` to
//! reload. Closing the pane kills Chrome.
//!
//! A worker thread owns the WebSocket (tungstenite, sync): it pumps incoming
//! protocol messages out over an mpsc channel (`App.cdp_chan`) and services an
//! incoming command channel ([`CdpCommand`]) in the same loop (a short socket read
//! timeout makes this cooperative). Same shape as the pty / HTTP / AI workers.
//!
//! First cut: console + navigations + eval only — no network capture / DOM /
//! screenshots yet (those are follow-ups). One browser pane at a time.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::time::Duration;

/// A command the main thread sends down to the CDP worker.
pub enum CdpCommand {
    /// A complete JSON-RPC request (`{"id":…,"method":…,"params":…}`) to send.
    Send(String),
    /// Kill Chrome and end the worker.
    Close,
}

/// Something the worker sends back up to the [`App`](crate::app::App).
pub enum CdpEvent {
    /// Chrome is up, the page WebSocket is open, base domains enabled.
    Connected { ws_url: String },
    /// A raw JSON-RPC message from the page (an event, or a reply to a request).
    Message(serde_json::Value),
    /// The session ended (closed / Chrome exited / socket error).
    Closed(String),
}

/// Binaries (and well-known macOS paths) we try, in order, for `browser.open`.
const CHROME_BINS: &[&str] = &[
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
];

/// Build a JSON-RPC request string with the given `id`, `method`, and `params`.
pub fn rpc(id: i64, method: &str, params: serde_json::Value) -> String {
    serde_json::json!({ "id": id, "method": method, "params": params }).to_string()
}

pub fn navigate(id: i64, url: &str) -> String {
    rpc(id, "Page.navigate", serde_json::json!({ "url": url }))
}
pub fn reload(id: i64) -> String {
    rpc(id, "Page.reload", serde_json::json!({}))
}
pub fn evaluate(id: i64, expr: &str) -> String {
    rpc(
        id,
        "Runtime.evaluate",
        serde_json::json!({ "expression": expr, "returnByValue": true, "userGesture": true }),
    )
}

/// Spawn Chrome (the first of [`CHROME_BINS`] that runs) with remote debugging on a
/// free port, in a throwaway `profile_dir`, open `url` (`about:blank` if empty),
/// connect to its first page, then pump the WebSocket ↔ command channel until told
/// to [`CdpCommand::Close`] / the socket dies. Call from a worker thread.
pub fn run_session(
    url: &str,
    profile_dir: &Path,
    out: &Sender<CdpEvent>,
    cmds: &Receiver<CdpCommand>,
) {
    macro_rules! bail {
        ($child:expr, $msg:expr) => {{
            if let Some(c) = $child.as_mut() {
                let _ = c.kill();
            }
            let _ = out.send(CdpEvent::Closed($msg));
            return;
        }};
    }

    let mut child = match spawn_chrome(url, profile_dir) {
        Ok(c) => Some(c),
        Err(e) => bail!(None::<Child>, e),
    };
    let port = match child.as_mut().and_then(read_debug_port) {
        Some(p) => p,
        None => bail!(
            child,
            "couldn't find Chrome's DevTools port — did it start?".into()
        ),
    };
    let ws_url = match page_ws_url(port) {
        Ok(u) => u,
        Err(e) => bail!(child, e),
    };
    let mut ws = match tungstenite::connect(&ws_url) {
        Ok((ws, _)) => ws,
        Err(e) => bail!(child, format!("connecting to {ws_url}: {e}")),
    };
    if let tungstenite::stream::MaybeTlsStream::Plain(s) = ws.get_mut() {
        let _ = s.set_read_timeout(Some(Duration::from_millis(60)));
    }
    // Enable the domains we mirror. (Requests the pane issues use ids ≥ 100, a
    // distinct range from these.)
    for (id, method) in (1i64..).zip(["Page.enable", "Runtime.enable", "Log.enable"]) {
        let _ = ws.send(tungstenite::Message::text(rpc(
            id,
            method,
            serde_json::json!({}),
        )));
    }
    let _ = out.send(CdpEvent::Connected { ws_url });

    loop {
        // outgoing commands
        loop {
            match cmds.try_recv() {
                Ok(CdpCommand::Send(json)) => {
                    let _ = ws.send(tungstenite::Message::text(json));
                }
                Ok(CdpCommand::Close) => {
                    let _ = ws.close(None);
                    bail!(child, "closed".into());
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => bail!(child, "closed".into()),
            }
        }
        if matches!(child.as_mut().map(Child::try_wait), Some(Ok(Some(_)))) {
            bail!(child, "Chrome exited".into());
        }
        // one incoming message (or a timeout)
        match ws.read() {
            Ok(tungstenite::Message::Text(t)) => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(t.as_str()) {
                    let _ = out.send(CdpEvent::Message(v));
                }
            }
            Ok(tungstenite::Message::Close(_)) => bail!(child, "page closed".into()),
            Ok(_) => {} // ping / pong / binary / continuation
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                bail!(child, "WebSocket closed".into())
            }
            Err(e) => bail!(child, format!("WebSocket error: {e}")),
        }
    }
}

fn spawn_chrome(url: &str, profile_dir: &Path) -> Result<Child, String> {
    let url = if url.trim().is_empty() {
        "about:blank"
    } else {
        url.trim()
    };
    for bin in CHROME_BINS {
        let mut cmd = Command::new(bin);
        cmd.arg("--remote-debugging-port=0")
            .arg(format!("--user-data-dir={}", profile_dir.display()))
            .arg("--no-first-run")
            .arg("--no-default-browser-check")
            .arg("--disable-background-networking")
            .arg("--disable-component-update")
            .arg("--disable-default-apps")
            .arg(url)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        if let Ok(c) = cmd.spawn() {
            return Ok(c);
        }
    }
    Err("no Chrome / Chromium found (tried google-chrome, chromium, …)".to_string())
}

/// Read Chrome's stderr for the `DevTools listening on ws://127.0.0.1:PORT/…` line
/// and return PORT. After finding it, keeps draining stderr on a detached thread so
/// Chrome doesn't block on a full pipe over a long session.
fn read_debug_port(child: &mut Child) -> Option<u16> {
    let stderr = child.stderr.take()?;
    let mut reader = BufReader::new(stderr);
    let mut line = String::new();
    let mut port = None;
    for _ in 0..200 {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF — Chrome exited
            Ok(_) => {
                if let Some(rest) = line.split("ws://").nth(1)
                    && let Some(hostport) = rest.split('/').next()
                    && let Some(p) = hostport
                        .split(':')
                        .nth(1)
                        .and_then(|s| s.trim().parse::<u16>().ok())
                {
                    port = Some(p);
                    break;
                }
            }
            Err(_) => break,
        }
    }
    if port.is_some() {
        std::thread::spawn(move || {
            let mut sink = String::new();
            while reader.read_line(&mut sink).map(|n| n > 0).unwrap_or(false) {
                sink.clear();
            }
        });
    }
    port
}

/// Hit `http://127.0.0.1:PORT/json` and return the first page target's
/// `webSocketDebuggerUrl` (retrying briefly — the endpoint can lag the port line).
fn page_ws_url(port: u16) -> Result<String, String> {
    let url = format!("http://127.0.0.1:{port}/json");
    let mut last = "no response".to_string();
    for _ in 0..25 {
        match reqwest::blocking::Client::new()
            .get(&url)
            .timeout(Duration::from_secs(2))
            .send()
            .and_then(|r| r.text())
        {
            Ok(body) => {
                if let Ok(serde_json::Value::Array(arr)) =
                    serde_json::from_str::<serde_json::Value>(&body)
                {
                    let page = arr
                        .iter()
                        .find(|t| t.get("type").and_then(|x| x.as_str()) == Some("page"))
                        .or_else(|| arr.first());
                    if let Some(ws) = page
                        .and_then(|p| p.get("webSocketDebuggerUrl"))
                        .and_then(|x| x.as_str())
                    {
                        return Ok(ws.to_string());
                    }
                }
                last = "no page target in /json".to_string();
            }
            Err(e) => last = e.to_string(),
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    Err(format!("couldn't reach Chrome's /json endpoint: {last}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_helpers_shape_json() {
        let v: serde_json::Value = serde_json::from_str(&navigate(7, "https://x.test")).unwrap();
        assert_eq!(v["id"], 7);
        assert_eq!(v["method"], "Page.navigate");
        assert_eq!(v["params"]["url"], "https://x.test");
        let v: serde_json::Value = serde_json::from_str(&evaluate(2, "1+1")).unwrap();
        assert_eq!(v["method"], "Runtime.evaluate");
        assert_eq!(v["params"]["expression"], "1+1");
        assert_eq!(v["params"]["returnByValue"], true);
    }
}
