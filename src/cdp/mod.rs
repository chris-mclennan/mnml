//! Chrome DevTools Protocol — launch a Chrome/Chromium with remote debugging on a
//! free port, connect to its first page over the DevTools WebSocket, and drive it
//! from a [`Pane::Browser`](crate::pane::Pane::Browser): a live log of console
//! output + page navigations, `g` to navigate, `e` to eval JS in the page, `r` to
//! reload, a filtered network log. Closing the pane kills Chrome.
//!
//! A worker thread owns the WebSocket (tungstenite, sync): it pumps incoming
//! protocol messages out over an mpsc channel (`App.cdp_chan`) and services an
//! incoming command channel ([`CdpCommand`]) in the same loop (a short socket read
//! timeout makes this cooperative). Same shape as the pty / HTTP / AI workers.
//!
//! Mirrors: console + navigations + eval + a filtered request log (Document / XHR /
//! Fetch — the noisy asset traffic is dropped). No DOM / screenshots / curl export
//! yet (follow-ups). One browser pane at a time.

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

/// Wrap a JSON-RPC request with a `sessionId` top-level field — flatten-mode
/// routing for attached sub-targets (popups, new tabs, iframes). When the
/// pane's current target is the main page, callers pass the raw `rpc` string
/// straight through; for an attached target, they wrap it via this. Returns
/// the original on parse failure (worst case: the message goes to the main
/// session, which is the existing behaviour).
pub fn with_session(message: String, session_id: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(&message) else {
        return message;
    };
    if let Some(obj) = v.as_object_mut() {
        obj.insert(
            "sessionId".into(),
            serde_json::Value::String(session_id.to_string()),
        );
    }
    v.to_string()
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
pub fn capture_screenshot(id: i64) -> String {
    rpc(
        id,
        "Page.captureScreenshot",
        serde_json::json!({ "format": "png", "captureBeyondViewport": false }),
    )
}

/// Same as `capture_screenshot`, but clipped to `(x, y, width, height)`
/// — used for the node-screenshot flow (`S` in the DOM panel), where
/// the clip is the bounding-box of the selected DOM node.
pub fn capture_screenshot_clip(id: i64, x: f64, y: f64, width: f64, height: f64) -> String {
    rpc(
        id,
        "Page.captureScreenshot",
        serde_json::json!({
            "format": "png",
            "captureBeyondViewport": false,
            "clip": {
                "x": x,
                "y": y,
                "width": width,
                "height": height,
                "scale": 1.0,
            }
        }),
    )
}

/// `Network.setUserAgentOverride` — swap the page's reported `User-Agent`
/// (and `navigator.userAgent` in JS). Used by the device-emulation
/// picker to mimic mobile / tablet user agents.
pub fn set_user_agent_override(id: i64, user_agent: &str) -> String {
    rpc(
        id,
        "Network.setUserAgentOverride",
        serde_json::json!({ "userAgent": user_agent }),
    )
}

/// `Emulation.setDeviceMetricsOverride` — override the viewport size,
/// device pixel ratio, and `navigator.maxTouchPoints`-style "is-mobile"
/// signal. `width == 0 && height == 0` clears the override (per CDP).
pub fn set_device_metrics_override(
    id: i64,
    width: u32,
    height: u32,
    device_scale_factor: f64,
    mobile: bool,
) -> String {
    rpc(
        id,
        "Emulation.setDeviceMetricsOverride",
        serde_json::json!({
            "width": width,
            "height": height,
            "deviceScaleFactor": device_scale_factor,
            "mobile": mobile,
        }),
    )
}

/// `Emulation.clearDeviceMetricsOverride` — drop any device-metrics
/// override and let the page render with the real window dimensions.
pub fn clear_device_metrics_override(id: i64) -> String {
    rpc(
        id,
        "Emulation.clearDeviceMetricsOverride",
        serde_json::json!({}),
    )
}

/// `Page.printToPDF` — render the current page as a PDF (base64-encoded
/// in `result.data`). Uses default page size + margins; backgrounds on
/// so brand colors / CSS backgrounds aren't dropped.
pub fn print_to_pdf(id: i64) -> String {
    rpc(
        id,
        "Page.printToPDF",
        serde_json::json!({
            "printBackground": true,
            "preferCSSPageSize": false,
            "transferMode": "ReturnAsBase64",
        }),
    )
}

/// `DOM.getBoxModel` — fetches the node's content / padding / border /
/// margin quads. Each quad is `[x1, y1, x2, y2, x3, y3, x4, y4]` (8
/// numbers, the four corners of the rectangle in viewport coords).
/// Used by the node-screenshot flow to compute a bounding rect.
pub fn get_box_model(id: i64, node_id: i64) -> String {
    rpc(
        id,
        "DOM.getBoxModel",
        serde_json::json!({ "nodeId": node_id }),
    )
}
pub fn get_request_post_data(id: i64, request_id: &str) -> String {
    rpc(
        id,
        "Network.getRequestPostData",
        serde_json::json!({ "requestId": request_id }),
    )
}
pub fn get_document(id: i64) -> String {
    rpc(
        id,
        "DOM.getDocument",
        serde_json::json!({ "depth": -1, "pierce": true }),
    )
}
pub fn highlight_node(id: i64, node_id: i64) -> String {
    rpc(
        id,
        "Overlay.highlightNode",
        serde_json::json!({
            "nodeId": node_id,
            "highlightConfig": {
                "showInfo": true,
                "contentColor": { "r": 111, "g": 168, "b": 220, "a": 0.4 },
                "paddingColor": { "r": 200, "g": 200, "b": 100, "a": 0.35 },
                "marginColor":  { "r": 230, "g": 130, "b": 100, "a": 0.30 },
                "borderColor":  { "r": 80,  "g": 100, "b": 160, "a": 0.6 }
            }
        }),
    )
}
pub fn hide_highlight(id: i64) -> String {
    rpc(id, "Overlay.hideHighlight", serde_json::json!({}))
}

/// `Network.getCookies` — fetches every cookie the browser has stored
/// for the current top-level URL (no `urls` param ⇒ all cookies for
/// the page). Reply shape is `{ cookies: [{ name, value, domain,
/// path, expires (-1 ⇒ session), httpOnly, secure, sameSite }] }`.
/// Used by the `K` cookies panel.
pub fn get_cookies(id: i64) -> String {
    rpc(id, "Network.getCookies", serde_json::json!({}))
}

/// `Network.setCookie` — create or update a cookie. Domain/path
/// scope the cookie to a specific origin; passing the same name +
/// domain + path as an existing one replaces it (which is how the
/// `e` edit chord updates a value). Used by the cookies panel's
/// `e` (edit) and `a` (add) chords.
pub fn set_cookie(id: i64, name: &str, value: &str, domain: &str, path: &str) -> String {
    rpc(
        id,
        "Network.setCookie",
        serde_json::json!({
            "name": name,
            "value": value,
            "domain": domain,
            "path": path,
        }),
    )
}

/// `Network.deleteCookies` — clear a specific cookie. `name` is
/// required; `domain` + `path` narrow the match (a name-only delete
/// drops every cookie with that name across every domain, which is
/// usually too broad). Used by the `d` chord in the cookies panel.
pub fn delete_cookies(id: i64, name: &str, domain: &str, path: &str) -> String {
    rpc(
        id,
        "Network.deleteCookies",
        serde_json::json!({
            "name": name,
            "domain": domain,
            "path": path,
        }),
    )
}

/// `DOM.scrollIntoViewIfNeeded` — scrolls the page so `node_id`'s
/// bounding box is visible. Used by the `Z` chord in the DOM panel
/// to bring off-screen nodes into view before subsequent gestures
/// (`S` screenshot / `h` highlight / visual inspection). The reply
/// carries nothing useful beyond the ack.
pub fn scroll_into_view_if_needed(id: i64, node_id: i64) -> String {
    rpc(
        id,
        "DOM.scrollIntoViewIfNeeded",
        serde_json::json!({ "nodeId": node_id }),
    )
}

/// Spawn Chrome (the first of [`CHROME_BINS`] that runs) with remote debugging on a
/// free port, in a throwaway `profile_dir`, open `url` (`about:blank` if empty),
/// connect to its first page, then pump the WebSocket ↔ command channel until told
/// to [`CdpCommand::Close`] / the socket dies. Call from a worker thread.
pub fn run_session(
    url: &str,
    profile_dir: &Path,
    headless: bool,
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

    let mut child = match spawn_chrome(url, profile_dir, headless) {
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
    for (id, method) in (1i64..).zip([
        "Page.enable",
        "Runtime.enable",
        "Log.enable",
        "Network.enable",
        "DOM.enable",
        "Overlay.enable",
    ]) {
        let _ = ws.send(tungstenite::Message::text(rpc(
            id,
            method,
            serde_json::json!({}),
        )));
    }
    // `Target.setDiscoverTargets {discover:true}` so we see popup / new-tab
    // events (`Target.targetCreated` / `targetInfoChanged`) — the page pane
    // logs them as new navigations the user can spot.
    let _ = ws.send(tungstenite::Message::text(rpc(
        99,
        "Target.setDiscoverTargets",
        serde_json::json!({ "discover": true }),
    )));
    // `Target.setAutoAttach {autoAttach:true, flatten:true}` — Chrome auto-
    // attaches to new targets (popups, iframes, OAuth windows) and tags their
    // messages with `sessionId`. With `flatten:true`, sub-session messages
    // ride the same WebSocket; we pass `sessionId` on outbound to route there.
    let _ = ws.send(tungstenite::Message::text(rpc(
        98,
        "Target.setAutoAttach",
        serde_json::json!({
            "autoAttach": true,
            "waitForDebuggerOnStart": false,
            "flatten": true,
        }),
    )));
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

fn spawn_chrome(url: &str, profile_dir: &Path, headless: bool) -> Result<Child, String> {
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
            .arg("--disable-default-apps");
        if headless {
            // `--headless=new` is the modern path (Chrome 109+) — same DevTools
            // protocol surface as the headed mode but no window. `--no-sandbox`
            // and `--disable-gpu` keep CI / restricted environments happy.
            cmd.arg("--headless=new")
                .arg("--no-sandbox")
                .arg("--disable-gpu");
        }
        cmd.arg(url)
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
    fn with_session_adds_session_id_to_top_level() {
        let raw = rpc(42, "Page.navigate", serde_json::json!({"url": "https://x"}));
        let wrapped = with_session(raw, "sess-7");
        let v: serde_json::Value = serde_json::from_str(&wrapped).unwrap();
        assert_eq!(v["id"], 42);
        assert_eq!(v["sessionId"], "sess-7");
        assert_eq!(v["method"], "Page.navigate");
        assert_eq!(v["params"]["url"], "https://x");
        // Malformed input is returned as-is rather than panicking.
        assert_eq!(with_session("nope".into(), "s"), "nope");
    }

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
