//! # mnml-bridge — Mount protocol for mnml sibling tools
//!
//! Bridge / Mount is the integration layer that lets sibling tools
//! (`mnml-tattle-tests`, `mnml-db-postgres`, …) render their UI as a
//! first-class pane inside mnml — owning the activity-bar icon, the
//! rail content, and the editor body — instead of running as a
//! plain `Pty` pane.
//!
//! ## The four tiers
//!
//! 1. **Env vars** — every Pty mnml spawns sees `MNML_WORKSPACE`,
//!    `MNML_THEME`, and `MNML_IPC_DIR`. Zero protocol; just read on
//!    startup. (Available today for any sibling.)
//! 2. **JSONL sibling → host** — sibling writes JSONL commands to
//!    `$MNML_IPC_DIR/command`; mnml ingests them. `toast`,
//!    `open-pty`, `open` (file), more coming. One-way.
//! 3. **mnml-bridge SDK** — this crate. Typed Rust API around tiers
//!    1 + 2, plus the Mount protocol below.
//! 4. **Mount** — sibling connects to a Unix-socket-per-mount,
//!    streams cell+style frames back, receives input events. Owns
//!    rail + body areas of an activity-bar section.
//!
//! ## Wire shape
//!
//! Length-prefixed JSON. Every message is a `Frame` or `Input`. The
//! 4-byte little-endian length precedes the JSON body so framing is
//! trivial (no streaming JSON parser needed).
//!
//! Host → Sibling:
//!   - `MountHello { cols, rows }` first
//!   - `Resize { cols, rows }` on terminal resize
//!   - `Input { event }` on every routed key / mouse event
//!
//! Sibling → Host:
//!   - `Frame { cells: Vec<Vec<Cell>> }` whenever the sibling has a
//!     new screen state. Cell-perfect; the host stamps these into
//!     its own ratatui frame.
//!
//! V1 keeps it simple: full frames, no diffing. A ~24x80 panel is
//! ~2 KB of JSON; serialization cost is negligible vs ratatui's
//! own draw cycle.

use serde::{Deserialize, Serialize};

#[cfg(feature = "client")]
pub mod client;

#[cfg(feature = "client")]
pub use client::Mount;

pub mod install;
pub mod ipc;
pub use install::{
    ChipSpec, CommandSpec, ContextMenuEntry, IntegrationSpec, MenuBarEntry, NotificationsSpec,
    OsNotifyPolicy, Requires, SettingsPage, StatuslineSpec, install_integration,
    integration_manifest_path, list_installed_integrations, uninstall_integration,
};
pub use ipc::{
    NotifyOpts, ProgressStatus, SegmentSide, ToastLevel, notify, progress_end, progress_start,
    progress_update, register_command, set_activity_badge, statusline_clear_segment,
    statusline_set_segment, toast, toast_dismiss, toast_error, toast_info, toast_persistent,
    toast_warn,
};

/// A single terminal cell — one grapheme + style. Mirrors
/// ratatui's `buffer::Cell` shape but with serde derived.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Cell {
    /// The grapheme cluster painted in this cell. Multi-codepoint
    /// (e.g. flag emoji) is fine; mnml stamps the whole thing into
    /// a single buffer cell.
    pub symbol: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<RgbOrIndex>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bg: Option<RgbOrIndex>,
    /// Bitfield of [`Modifier`] flags. Stored as u16 for compact wire shape.
    #[serde(default, skip_serializing_if = "is_zero_u16")]
    pub modifiers: u16,
}

fn is_zero_u16(v: &u16) -> bool {
    *v == 0
}

/// Either a true-color RGB triple or a 256-color palette index.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum RgbOrIndex {
    /// `[r, g, b]` 24-bit color.
    Rgb([u8; 3]),
    /// 0-255 palette index (terminal default semantics: 0-7 ANSI,
    /// 8-15 bright, 16-231 6×6×6 cube, 232-255 grayscale).
    Index(u8),
}

/// Bitflags for [`Cell::modifiers`]. Mirrors ratatui's `Modifier`
/// constants so a sibling can reuse its existing styling.
pub mod modifier {
    pub const BOLD: u16 = 1 << 0;
    pub const DIM: u16 = 1 << 1;
    pub const ITALIC: u16 = 1 << 2;
    pub const UNDERLINED: u16 = 1 << 3;
    pub const SLOW_BLINK: u16 = 1 << 4;
    pub const RAPID_BLINK: u16 = 1 << 5;
    pub const REVERSED: u16 = 1 << 6;
    pub const HIDDEN: u16 = 1 << 7;
    pub const CROSSED_OUT: u16 = 1 << 8;
}

/// Sent by the host once on connection, then on every terminal resize.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Geometry {
    pub cols: u16,
    pub rows: u16,
}

/// Routed input event from the host. Key / mouse events that
/// happened inside the mount's area are forwarded as-is.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InputEvent {
    /// A single keypress (key spec, e.g. `"down"`, `"ctrl+c"`).
    Key { spec: String },
    /// Mouse click. `button` is `"left" | "middle" | "right"`.
    Click { col: u16, row: u16, button: String },
    /// Mouse wheel. Positive `dy` ⇒ scroll up.
    Scroll { col: u16, row: u16, dy: i16 },
    /// Mouse hover (cursor moved over the mount).
    Hover { col: u16, row: u16 },
}

/// Host → sibling messages.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum HostMessage {
    /// First message after connect — tells the sibling the initial
    /// area size.
    Hello { geometry: Geometry, theme: String },
    /// Sent on terminal / pane resize.
    Resize { geometry: Geometry },
    /// Forwarded user input.
    Input { event: InputEvent },
    /// Host is going away (mnml quitting, mount being unmounted).
    Goodbye,
}

/// Sibling → host messages.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SiblingMessage {
    /// A full screen of cells. `cells.len()` rows × `cells[i].len()`
    /// cols — must match the most recent `Hello`/`Resize` geometry.
    /// Rows shorter than the advertised `cols` are right-padded
    /// with default cells by the host.
    Frame { cells: Vec<Vec<Cell>> },
    /// Sibling is voluntarily exiting (clean shutdown).
    Bye,
}

/// Read a length-prefixed JSON message from a stream.
///
/// Wire format: `[u8; 4]` little-endian length, then `length` bytes
/// of UTF-8 JSON. Returns `Ok(None)` on clean EOF, `Err` on truncated
/// reads or malformed JSON.
pub fn read_message<R, T>(r: &mut R) -> std::io::Result<Option<T>>
where
    R: std::io::Read,
    T: serde::de::DeserializeOwned,
{
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    if len > 16 * 1024 * 1024 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("bridge message too large: {len} bytes"),
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    let parsed: T = serde_json::from_slice(&body).map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("bridge JSON parse: {e}"),
        )
    })?;
    Ok(Some(parsed))
}

/// Write a length-prefixed JSON message to a stream.
pub fn write_message<W, T>(w: &mut W, msg: &T) -> std::io::Result<()>
where
    W: std::io::Write,
    T: Serialize,
{
    let body = serde_json::to_vec(msg).map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("bridge JSON serialize: {e}"),
        )
    })?;
    let len = body.len() as u32;
    w.write_all(&len.to_le_bytes())?;
    w.write_all(&body)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrip() {
        let frame = SiblingMessage::Frame {
            cells: vec![vec![Cell {
                symbol: "x".to_string(),
                fg: Some(RgbOrIndex::Rgb([255, 0, 0])),
                bg: None,
                modifiers: modifier::BOLD,
            }]],
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &frame).unwrap();
        let mut cursor = std::io::Cursor::new(&buf);
        let back: SiblingMessage = read_message(&mut cursor).unwrap().unwrap();
        match back {
            SiblingMessage::Frame { cells } => {
                assert_eq!(cells.len(), 1);
                assert_eq!(cells[0][0].symbol, "x");
                assert_eq!(cells[0][0].fg, Some(RgbOrIndex::Rgb([255, 0, 0])));
                assert_eq!(cells[0][0].modifiers, modifier::BOLD);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn host_hello_roundtrip() {
        let hello = HostMessage::Hello {
            geometry: Geometry { cols: 80, rows: 24 },
            theme: "cyberdream".to_string(),
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &hello).unwrap();
        let mut cursor = std::io::Cursor::new(&buf);
        let back: HostMessage = read_message(&mut cursor).unwrap().unwrap();
        match back {
            HostMessage::Hello { geometry, theme } => {
                assert_eq!(geometry.cols, 80);
                assert_eq!(geometry.rows, 24);
                assert_eq!(theme, "cyberdream");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn eof_returns_none() {
        let mut empty = std::io::Cursor::new(Vec::<u8>::new());
        let res: Option<HostMessage> = read_message(&mut empty).unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn rejects_oversize_length() {
        // 4-byte length = 100 MB; should be rejected before allocation.
        let mut buf = (100u32 * 1024 * 1024).to_le_bytes().to_vec();
        buf.extend_from_slice(b"junk");
        let mut cursor = std::io::Cursor::new(&buf);
        let res: std::io::Result<Option<HostMessage>> = read_message(&mut cursor);
        assert!(res.is_err());
    }
}
