//! Native WebSocket pane state + worker. Uses the existing
//! `tungstenite` dep (already in tree for CDP). A persistent
//! connection runs on a background thread; messages flow in
//! both directions over channels.
//!
//! Scope:
//!  - Single connection per pane (one URL, one socket).
//!  - Text and binary frames as messages.
//!  - User types into a single-line input + Enter to send.
//!  - Esc closes the connection.
//!
//! Out of scope (v2): subprotocol selection, ping/pong intervals,
//! reconnect-on-disconnect, history persistence beyond pane life.

use std::sync::mpsc::{Receiver, Sender};
use std::time::Instant;

pub enum WsMsg {
    /// Server → client message (or our own echo of a send).
    Recv {
        ts: Instant,
        text: String,
        outgoing: bool,
    },
    /// Connection state changed.
    State(WsState),
    /// Error from the worker (transport / parse / etc).
    Error(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsState {
    Connecting,
    Open,
    Closing,
    Closed,
}

pub struct WebsocketPane {
    pub url: String,
    pub state: WsState,
    pub log: Vec<LogEntry>,
    /// Pending input the user is typing. Enter → send + clear.
    pub input: String,
    pub input_cursor: usize,
    pub rx: Receiver<WsMsg>,
    /// Channel to the worker for sending messages or close.
    pub tx_out: Sender<OutMsg>,
    /// Scroll offset within the log (rows from the bottom — 0 =
    /// follow tail). Bumped by wheel + PgUp/PgDn.
    pub scroll: usize,
}

pub enum OutMsg {
    Send(String),
    Close,
}

pub struct LogEntry {
    pub ts: Instant,
    pub outgoing: bool,
    pub text: String,
}

impl WebsocketPane {
    /// Tab title — `ws://host` or `wss://host`, schema implied by
    /// the URL scheme. Truncates long URLs.
    pub fn tab_title(&self) -> String {
        let host = host_of_url(&self.url);
        let badge = match self.state {
            WsState::Connecting => "…",
            WsState::Open => "●",
            WsState::Closing => "▼",
            WsState::Closed => "·",
        };
        format!("ws {badge} {host}")
    }

    pub fn connect(url: String) -> Self {
        let (msg_tx, rx) = std::sync::mpsc::channel::<WsMsg>();
        let (tx_out, out_rx) = std::sync::mpsc::channel::<OutMsg>();
        let url_clone = url.clone();
        let msg_tx_send = msg_tx.clone();
        std::thread::spawn(move || worker(url_clone, msg_tx_send, out_rx));
        Self {
            url,
            state: WsState::Connecting,
            log: Vec::new(),
            input: String::new(),
            input_cursor: 0,
            rx,
            tx_out,
            scroll: 0,
        }
    }

    /// Drain pending messages into `log` + apply state changes.
    /// Called from App.tick. Also persists each message to
    /// `~/.mnml/ws-history/<host-slug>/history.jsonl` (2026-06-21).
    pub fn drain(&mut self) {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                WsMsg::Recv { ts, text, outgoing } => {
                    persist_history(&self.url, outgoing, &text);
                    self.log.push(LogEntry { ts, outgoing, text });
                }
                WsMsg::State(s) => self.state = s,
                WsMsg::Error(e) => {
                    self.log.push(LogEntry {
                        ts: Instant::now(),
                        outgoing: false,
                        text: format!("ERROR: {e}"),
                    });
                }
            }
        }
    }

    /// User pressed Enter — send the pending input.
    pub fn send_input(&mut self) {
        if self.input.is_empty() {
            return;
        }
        let payload = std::mem::take(&mut self.input);
        self.input_cursor = 0;
        persist_history(&self.url, true, &payload);
        // Mirror into log first (we won't get an echo from server).
        self.log.push(LogEntry {
            ts: Instant::now(),
            outgoing: true,
            text: payload.clone(),
        });
        let _ = self.tx_out.send(OutMsg::Send(payload));
    }

    pub fn close(&mut self) {
        let _ = self.tx_out.send(OutMsg::Close);
        self.state = WsState::Closing;
    }

    /// Insert a char at the cursor. Handles UTF-8 (cursor moves by
    /// `c.len_utf8()`). 2026-06-21 power-user-ws-git SEV-3 input-
    /// cursor-dead: was push()-only, cursor was always at end.
    pub fn input_insert(&mut self, c: char) {
        self.input.insert(self.input_cursor, c);
        self.input_cursor += c.len_utf8();
    }

    /// Backspace = delete char before cursor.
    pub fn input_backspace(&mut self) {
        if self.input_cursor == 0 || self.input.is_empty() {
            return;
        }
        // Find the previous char boundary.
        let mut i = self.input_cursor.saturating_sub(1);
        while i > 0 && !self.input.is_char_boundary(i) {
            i -= 1;
        }
        self.input.replace_range(i..self.input_cursor, "");
        self.input_cursor = i;
    }

    /// Delete = remove char at cursor (vim x / VS Code Del).
    pub fn input_delete(&mut self) {
        if self.input_cursor >= self.input.len() {
            return;
        }
        let mut i = self.input_cursor + 1;
        while i < self.input.len() && !self.input.is_char_boundary(i) {
            i += 1;
        }
        self.input.replace_range(self.input_cursor..i, "");
    }

    /// Move cursor left by one char.
    pub fn input_left(&mut self) {
        if self.input_cursor == 0 {
            return;
        }
        let mut i = self.input_cursor - 1;
        while i > 0 && !self.input.is_char_boundary(i) {
            i -= 1;
        }
        self.input_cursor = i;
    }

    /// Move cursor right by one char.
    pub fn input_right(&mut self) {
        if self.input_cursor >= self.input.len() {
            return;
        }
        let mut i = self.input_cursor + 1;
        while i < self.input.len() && !self.input.is_char_boundary(i) {
            i += 1;
        }
        self.input_cursor = i;
    }

    pub fn input_home(&mut self) {
        self.input_cursor = 0;
    }

    pub fn input_end(&mut self) {
        self.input_cursor = self.input.len();
    }
}

/// Toggle non-blocking on the underlying TCP stream. tungstenite's
/// `MaybeTlsStream<TcpStream>` is what `connect()` returns; we
/// reach the raw TcpStream regardless of TLS wrapping.
fn set_socket_nonblocking(
    stream: &mut tungstenite::stream::MaybeTlsStream<std::net::TcpStream>,
    on: bool,
) {
    use tungstenite::stream::MaybeTlsStream;
    // mnml's tungstenite is built without TLS features (no wss://
    // support), so only Plain is reachable. The TLS arms are
    // gated so they don't compile-warn here while keeping
    // forward-compat if we ever enable wss.
    let MaybeTlsStream::Plain(tcp) = stream else {
        return;
    };
    let _ = tcp.set_nonblocking(on);
}

fn host_of_url(url: &str) -> String {
    let trimmed = url
        .strip_prefix("wss://")
        .or_else(|| url.strip_prefix("ws://"))
        .unwrap_or(url);
    let host = trimmed.split(['/', '?']).next().unwrap_or(trimmed);
    let max = 32usize;
    if host.chars().count() <= max {
        host.to_string()
    } else {
        let cut: String = host.chars().take(max).collect();
        format!("{cut}…")
    }
}

fn worker(
    url: String,
    tx: Sender<WsMsg>,
    out_rx: Receiver<OutMsg>,
) {
    use tungstenite::Message;

    let parsed_url = match tungstenite::http::Uri::try_from(&url[..]) {
        Ok(u) => u,
        Err(e) => {
            let _ = tx.send(WsMsg::Error(format!("invalid url: {e}")));
            let _ = tx.send(WsMsg::State(WsState::Closed));
            return;
        }
    };

    let result = tungstenite::connect(parsed_url);
    let (mut socket, _resp) = match result {
        Ok(t) => t,
        Err(e) => {
            let _ = tx.send(WsMsg::Error(format!("connect failed: {e}")));
            let _ = tx.send(WsMsg::State(WsState::Closed));
            return;
        }
    };
    // 2026-06-21 — Set the underlying TCP socket non-blocking so
    // `socket.read()` returns WouldBlock instead of stalling the
    // worker. Was: read blocked until the server spoke, which
    // meant `OutMsg::Send`/`Close` queued via out_rx were stuck
    // behind it — first `:ws.send_message` to a quiet echo/RPC
    // server deadlocked (the SEV-1 power-user-ws-git finding).
    set_socket_nonblocking(socket.get_mut(), true);
    let _ = tx.send(WsMsg::State(WsState::Open));

    loop {
        // Drain pending outgoing first so user-initiated sends
        // don't sit behind a slow read.
        while let Ok(out) = out_rx.try_recv() {
            match out {
                OutMsg::Send(text) => {
                    if let Err(e) = socket.send(Message::Text(text.into())) {
                        let _ = tx.send(WsMsg::Error(format!("send failed: {e}")));
                    }
                }
                OutMsg::Close => {
                    let _ = socket.close(None);
                    let _ = tx.send(WsMsg::State(WsState::Closed));
                    return;
                }
            }
        }
        match socket.read() {
            Ok(Message::Text(s)) => {
                let _ = tx.send(WsMsg::Recv {
                    ts: Instant::now(),
                    text: s.to_string(),
                    outgoing: false,
                });
            }
            Ok(Message::Binary(b)) => {
                let _ = tx.send(WsMsg::Recv {
                    ts: Instant::now(),
                    text: format!("(binary {} bytes)", b.len()),
                    outgoing: false,
                });
            }
            Ok(Message::Close(_)) => {
                let _ = tx.send(WsMsg::State(WsState::Closed));
                return;
            }
            Ok(_) => {} // ping / pong handled by tungstenite
            Err(tungstenite::Error::ConnectionClosed)
            | Err(tungstenite::Error::AlreadyClosed) => {
                let _ = tx.send(WsMsg::State(WsState::Closed));
                return;
            }
            Err(tungstenite::Error::Io(io)) if io.kind() == std::io::ErrorKind::WouldBlock => {
                // No data — sleep briefly so the loop doesn't burn
                // CPU. 25ms gives a UI-imperceptible round-trip
                // between out_rx drain and read.
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            Err(e) => {
                let _ = tx.send(WsMsg::Error(format!("read error: {e}")));
                let _ = tx.send(WsMsg::State(WsState::Closed));
                return;
            }
        }
    }
}

/// 2026-06-21 — best-effort persist a single message to
/// `~/.mnml/ws-history/<host-slug>/history.jsonl`. Appends one
/// JSON line. Silently no-ops when HOME isn't set or the dir
/// can't be created — the file is informational, not load-bearing.
fn persist_history(url: &str, outgoing: bool, text: &str) {
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let host = host_of_url(url);
    let slug = host
        .replace(['/', ':'], "_")
        .replace(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '.' && c != '-', "_");
    if slug.is_empty() {
        return;
    }
    let dir = std::path::PathBuf::from(home)
        .join(".mnml/ws-history")
        .join(&slug);
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("history.jsonl");
    let ts_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    // Encode text as a JSON string literal (escape control chars
    // + quote + backslash). Newlines flattened to \n.
    let escaped = text
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t");
    let line = format!(
        "{{\"ts\":{ts_ms},\"url\":\"{url}\",\"outgoing\":{outgoing},\"text\":\"{escaped}\"}}\n"
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// 2026-06-21 — `:ws.history` reader. Walks
/// `~/.mnml/ws-history/*/history.jsonl`, returns
/// `Vec<(url, last_ts_ms, message_count)>` sorted by last_ts
/// descending. Used by the history picker.
pub fn read_ws_history() -> Vec<(String, u128, usize)> {
    let mut out: std::collections::BTreeMap<String, (u128, usize)> =
        std::collections::BTreeMap::new();
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let root = std::path::PathBuf::from(home).join(".mnml/ws-history");
    let Ok(rd) = std::fs::read_dir(&root) else {
        return Vec::new();
    };
    for d in rd.flatten() {
        let p = d.path().join("history.jsonl");
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let mut last_ts: u128 = 0;
        let mut url_seen: Option<String> = None;
        let mut count = 0usize;
        for line in text.lines() {
            count += 1;
            // Cheap field-extract without pulling serde_json — both
            // fields are at fixed positions in the writer.
            if let Some(ts_str) = line
                .strip_prefix("{\"ts\":")
                .and_then(|s| s.split(',').next())
                && let Ok(ts) = ts_str.parse::<u128>()
            {
                last_ts = last_ts.max(ts);
            }
            if url_seen.is_none()
                && let Some(rest) = line.split("\"url\":\"").nth(1)
                && let Some(end) = rest.find('"')
            {
                url_seen = Some(rest[..end].to_string());
            }
        }
        if let Some(u) = url_seen {
            out.entry(u).or_insert((last_ts, count)).0 = last_ts;
            out.get_mut(&out.keys().next().unwrap().clone()); // no-op for borrow
        }
    }
    let mut rows: Vec<(String, u128, usize)> = out
        .into_iter()
        .map(|(url, (ts, count))| (url, ts, count))
        .collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    rows
}
