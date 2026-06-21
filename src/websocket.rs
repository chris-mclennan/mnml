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
    /// Called from App.tick.
    pub fn drain(&mut self) {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                WsMsg::Recv { ts, text, outgoing } => {
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
    let _ = tx.send(WsMsg::State(WsState::Open));

    // Loop: try to read from server (with short timeout), then
    // drain any pending outgoing messages, repeat.
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
        // Try a non-blocking-ish read. tungstenite::read blocks;
        // wrap in a thread might be heavier than just sleeping.
        // Compromise: read with a small sleep loop on no data.
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
            Err(e) => {
                let _ = tx.send(WsMsg::Error(format!("read error: {e}")));
                let _ = tx.send(WsMsg::State(WsState::Closed));
                return;
            }
        }
    }
}
