//! Generic blit-host facility — mnml hosts an arbitrary external binary
//! as a pane. The binary speaks `tmnl-protocol` over a Unix socket
//! (the same wire mnml uses for the `mixr_host` panel and for tmnl's
//! own native-client `--blit` flag).
//!
//! Architecture (mirrors `mixr_host`): mnml binds a Unix socket, spawns
//! `<binary> --blit <socket> [args…]`, accepts the connection, and pumps
//! `Frame`s from the child into a cell buffer. Input events go back the
//! other way. Drop kills the child + removes the socket file.
//!
//! This is the "third class of integration" (after command-only plugins
//! and Cargo features) — see `docs/PLUGINS.md`. Used by `Pane::BlitHost`
//! via the `:host.launch` ex-command, and (eventually) by `mixr_host`
//! once it's consolidated to share the same primitives.

use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Child;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;

use tmnl_protocol::{
    Frame, InputEvent, Message, PROTOCOL_VERSION, Resize, read_message, write_message,
};

/// `(bg, fg, accent)` packed-rgba colors handed to the hosted binary on
/// connect (`Message::Palette`) so it re-themes to match mnml. Built by
/// the host from mnml's active theme.
pub type HostPalette = (u32, u32, u32);

/// One cell of the hosted binary's screen, decoded off the wire. `fg` /
/// `bg` are packed rgba (`tmnl_protocol::unpack_rgba` decodes them);
/// `attrs` is the wire attribute bitset.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlitCell {
    pub ch: char,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u32,
}

impl BlitCell {
    pub fn blank() -> Self {
        BlitCell {
            ch: ' ',
            fg: 0,
            bg: 0,
            attrs: 0,
        }
    }
}

/// A connection to one hosted binary. Owns the child process, the bound
/// Unix socket, and the receiver end of a Frame channel; sends input +
/// resize back over the socket.
pub struct BlitChannel {
    socket_path: PathBuf,
    child: Child,
    frame_rx: Receiver<Frame>,
    writer: Arc<Mutex<Option<UnixStream>>>,
    title: Arc<Mutex<Option<String>>>,
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<BlitCell>,
    pub cursor: Option<(u16, u16)>,
    /// The binary path mnml launched — used for the pane's tab title
    /// when the hosted child hasn't yet sent a `Message::Title`.
    pub binary_label: String,
}

impl BlitChannel {
    /// Launch `<binary> --blit <socket> [args…]` and host it. `cols`/`rows`
    /// is the initial cell grid; `palette` is mnml's theme handed to the
    /// child on connect. Errors if the socket can't be bound or the
    /// binary can't be spawned.
    pub fn launch(
        binary: &str,
        args: &[String],
        cols: u16,
        rows: u16,
        palette: HostPalette,
    ) -> Result<BlitChannel, String> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        // Use the binary's file-name as the socket id so multiple hosts
        // don't collide. Falls back to "blit" if the path has no name.
        let sock_id = std::path::Path::new(binary)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("blit");
        let socket_path = std::env::temp_dir().join(format!(
            "mnml-host-{}-{}.sock",
            sock_id,
            std::process::id()
        ));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("pane_host: bind {}: {e}", socket_path.display()))?;

        let (frame_tx, frame_rx) = channel::<Frame>();
        let writer: Arc<Mutex<Option<UnixStream>>> = Arc::new(Mutex::new(None));
        let title: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let (writer_c, title_c) = (writer.clone(), title.clone());
        thread::spawn(move || {
            accept_loop(listener, cols, rows, palette, frame_tx, writer_c, title_c)
        });

        let mut cmd = std::process::Command::new(binary);
        cmd.arg("--blit").arg(&socket_path);
        for a in args {
            cmd.arg(a);
        }
        let child = cmd
            .spawn()
            .map_err(|e| format!("pane_host: spawn {binary}: {e}"))?;

        let binary_label = std::path::Path::new(binary)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(binary)
            .to_string();

        Ok(BlitChannel {
            socket_path,
            child,
            frame_rx,
            writer,
            title,
            cols,
            rows,
            cells: vec![BlitCell::blank(); cols as usize * rows as usize],
            cursor: None,
            binary_label,
        })
    }

    /// Drain frames the child has sent and apply them. Returns true if
    /// any landed (caller should redraw).
    pub fn drain_frames(&mut self) -> bool {
        let mut any = false;
        while let Ok(f) = self.frame_rx.try_recv() {
            apply_frame_into(&mut self.cells, &mut self.cols, &mut self.rows, &f);
            self.cursor = if f.cursor_visible != 0 {
                Some((f.cursor_col, f.cursor_row))
            } else {
                None
            };
            any = true;
        }
        any
    }

    /// The tab title the child advertised over the wire, if any.
    pub fn title(&self) -> Option<String> {
        self.title.lock().ok().and_then(|t| t.clone())
    }

    fn send(&self, msg: &Message) {
        if let Ok(mut guard) = self.writer.lock()
            && let Some(s) = guard.as_mut()
            && write_message(s, msg).is_err()
        {
            *guard = None;
        }
    }

    /// Tell the hosted child the grid changed size. The local `cells`
    /// buffer is re-sized when its next `Frame` arrives.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        if (cols, rows) != (self.cols, self.rows) {
            self.send(&Message::Resize(Resize { cols, rows }));
        }
    }

    /// Forward an input event to the hosted child.
    pub fn send_input(&self, ev: InputEvent) {
        self.send(&Message::Input(ev));
    }
}

impl Drop for BlitChannel {
    fn drop(&mut self) {
        self.send(&Message::Quit);
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Apply one (diff) `Frame` to a cell buffer in place — reallocating
/// the buffer + updating `cur_cols`/`cur_rows` on a dimension change.
fn apply_frame_into(cells: &mut Vec<BlitCell>, cur_cols: &mut u16, cur_rows: &mut u16, f: &Frame) {
    if *cur_cols != f.cols || *cur_rows != f.rows {
        *cur_cols = f.cols;
        *cur_rows = f.rows;
        *cells = vec![BlitCell::blank(); f.cols as usize * f.rows as usize];
    }
    for run in &f.runs {
        let start = run.start as usize;
        for (i, wc) in run.cells.iter().enumerate() {
            if let Some(slot) = cells.get_mut(start + i) {
                *slot = BlitCell {
                    ch: char::from_u32(wc.ch).unwrap_or(' '),
                    fg: wc.fg,
                    bg: wc.bg,
                    attrs: wc.attrs,
                };
            }
        }
    }
}

fn accept_loop(
    listener: UnixListener,
    init_cols: u16,
    init_rows: u16,
    palette: HostPalette,
    frame_tx: Sender<Frame>,
    writer_slot: Arc<Mutex<Option<UnixStream>>>,
    title_slot: Arc<Mutex<Option<String>>>,
) {
    for incoming in listener.incoming() {
        let Ok(stream) = incoming else { continue };
        let Ok(reader_half) = stream.try_clone() else {
            continue;
        };
        {
            let mut guard = writer_slot.lock().unwrap();
            if guard.is_some() {
                drop(stream); // single client
                continue;
            }
            *guard = Some(stream);
        }
        // Greet + initial Resize (the blit client blocks on the first
        // Resize before it starts rendering), then the palette so the
        // child re-themes to match mnml.
        if let Some(s) = writer_slot.lock().unwrap().as_mut() {
            let _ = write_message(
                s,
                &Message::Hello {
                    version: PROTOCOL_VERSION,
                },
            );
            let _ = write_message(
                s,
                &Message::Resize(Resize {
                    cols: init_cols,
                    rows: init_rows,
                }),
            );
            let (bg, fg, accent) = palette;
            let _ = write_message(s, &Message::Palette { bg, fg, accent });
        }
        let ftx = frame_tx.clone();
        let tslot = title_slot.clone();
        let wslot = writer_slot.clone();
        thread::spawn(move || reader_loop(reader_half, ftx, tslot, wslot));
    }
}

fn reader_loop(
    stream: UnixStream,
    frame_tx: Sender<Frame>,
    title_slot: Arc<Mutex<Option<String>>>,
    writer_slot: Arc<Mutex<Option<UnixStream>>>,
) {
    let mut r = BufReader::new(stream);
    loop {
        match read_message(&mut r) {
            Ok(Message::Frame(f)) => {
                if frame_tx.send(f).is_err() {
                    break;
                }
            }
            Ok(Message::Title(t)) => {
                if let Ok(mut slot) = title_slot.lock() {
                    *slot = Some(t);
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    *writer_slot.lock().unwrap() = None;
}

/// Pack a ratatui `Color` into the wire's rgba u32. mnml's theme colors
/// are always `Color::Rgb`; any other variant (shouldn't occur for a
/// theme color) falls back to opaque black.
pub fn pack_color(c: ratatui::style::Color) -> u32 {
    match c {
        ratatui::style::Color::Rgb(r, g, b) => tmnl_protocol::pack_rgba_u8(r, g, b, 0xff),
        _ => tmnl_protocol::pack_rgba_u8(0, 0, 0, 0xff),
    }
}

/// Translate a crossterm `KeyEvent` into a wire `InputEvent` for the
/// hosted child. `None` for keys the protocol doesn't carry. Mirrors
/// `mixr_host::crossterm_key_to_input` exactly — kept here as a thin
/// re-export so callers don't need to pull `mixr_host` in.
pub fn crossterm_key_to_input(
    key: &ratatui::crossterm::event::KeyEvent,
) -> Option<InputEvent> {
    crate::mixr_host::crossterm_key_to_input(key)
}

/// Translate a crossterm `MouseEvent` into a wire `InputEvent`. `col` /
/// `row` are the cell-grid coordinates within the pane (caller subtracts
/// the pane origin). Mirrors `mixr_host::crossterm_mouse_to_input`.
///
/// Unused today — `Pane::BlitHost`'s wheel events go through the
/// regular `dispatch.rs` wheel path directly. Kept here so a future
/// click/drag forwarding step has a one-call entry point.
#[allow(dead_code)]
pub fn crossterm_mouse_to_input(
    ev: &ratatui::crossterm::event::MouseEvent,
    col: u16,
    row: u16,
) -> InputEvent {
    crate::mixr_host::crossterm_mouse_to_input(ev, col, row)
}

/// One mnml-side pane payload — wraps a [`BlitChannel`] and a tab
/// title. Lives at `Pane::BlitHost(BlitHostPane)`.
pub struct BlitHostPane {
    pub channel: BlitChannel,
    /// User-provided title override; falls back to the wire `Title`
    /// (from `channel.title()`), then the binary's file name.
    pub title_override: Option<String>,
}

impl BlitHostPane {
    pub fn new(channel: BlitChannel) -> Self {
        Self {
            channel,
            title_override: None,
        }
    }

    /// Resolved tab title: override > wire Title > binary label.
    pub fn tab_title(&self) -> String {
        if let Some(t) = &self.title_override {
            return t.clone();
        }
        if let Some(t) = self.channel.title() {
            return t;
        }
        self.channel.binary_label.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blit_cell_blank_is_space() {
        let c = BlitCell::blank();
        assert_eq!(c.ch, ' ');
        assert_eq!(c.fg, 0);
        assert_eq!(c.bg, 0);
        assert_eq!(c.attrs, 0);
    }

    #[test]
    fn pack_color_rgb_packs_with_full_alpha() {
        let c = ratatui::style::Color::Rgb(0x12, 0x34, 0x56);
        let packed = pack_color(c);
        // pack_rgba_u8(r, g, b, a) packs as (r, g, b, a) bytes — verify
        // that all four bytes ended up in the result (exact bit layout
        // is tmnl-protocol's contract, not ours).
        assert_eq!(packed, tmnl_protocol::pack_rgba_u8(0x12, 0x34, 0x56, 0xff));
    }

    #[test]
    fn pack_color_non_rgb_falls_back_to_black() {
        // Any non-Rgb variant returns opaque black (mnml's theme colors
        // are always Rgb; this is just a safety net).
        let packed = pack_color(ratatui::style::Color::Reset);
        assert_eq!(packed, tmnl_protocol::pack_rgba_u8(0, 0, 0, 0xff));
    }
}
