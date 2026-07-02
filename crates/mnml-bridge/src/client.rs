//! Sibling-side helpers — wraps the UDS connect + handshake +
//! per-tick send_frame + poll_input loop so a Mount sibling
//! becomes a few dozen lines.
//!
//! Pulled in by the `client` feature (on by default). Non-Rust
//! siblings — or Rust ones that want full control — can ignore
//! this module and use the wire types + `read_message` /
//! `write_message` directly.

use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use crate::{
    Cell, Geometry, HostMessage, InputEvent, RgbOrIndex, SiblingMessage, modifier, read_message,
    write_message,
};

/// Sibling-side handle to a Mount. Manages the UDS connection +
/// reads HostMessages on a background thread + buffers the latest
/// geometry / theme. Per-tick the sibling calls `send_frame_from_buffer`
/// to push its current ratatui buffer + `poll_input` to drain
/// pending input events.
pub struct Mount {
    writer: BufWriter<UnixStream>,
    rx_inputs: std::sync::mpsc::Receiver<InputEvent>,
    rx_geometry: std::sync::mpsc::Receiver<Geometry>,
    geometry: Geometry,
    theme: String,
    /// Set once the host sends Goodbye OR the socket closes —
    /// the sibling should drain and exit.
    done: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Mount {
    /// Connect to the socket named by `MNML_MOUNT_SOCKET`, wait
    /// for `Hello`, and start the input-reader thread. Returns
    /// `Err` if the env var is missing, the socket can't be opened,
    /// or the handshake doesn't complete within a 5 second
    /// deadline.
    pub fn connect_env() -> std::io::Result<Self> {
        let path = std::env::var("MNML_MOUNT_SOCKET").map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "MNML_MOUNT_SOCKET not set — this binary expects to be spawned by mnml as a Mount sibling",
            )
        })?;
        Self::connect(&path)
    }

    /// Connect to a specific socket path (useful for tests).
    pub fn connect(socket_path: &str) -> std::io::Result<Self> {
        let stream = UnixStream::connect(socket_path)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        let mut reader = BufReader::new(stream.try_clone()?);
        // Block on Hello.
        let hello: HostMessage = read_message(&mut reader)?.ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "host closed before Hello",
            )
        })?;
        let (geometry, theme) = match hello {
            HostMessage::Hello { geometry, theme } => (geometry, theme),
            _ => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "expected Hello as first message",
                ));
            }
        };
        // Clear the read timeout — the reader thread blocks
        // waiting for the next message.
        reader.get_mut().set_read_timeout(None)?;

        let (tx_input, rx_inputs) = std::sync::mpsc::channel();
        let (tx_geo, rx_geometry) = std::sync::mpsc::channel();
        let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let done_thread = done.clone();
        std::thread::spawn(move || {
            reader_loop(reader, tx_input, tx_geo, done_thread);
        });

        Ok(Mount {
            writer: BufWriter::new(stream),
            rx_inputs,
            rx_geometry,
            geometry,
            theme,
            done,
        })
    }

    /// Current geometry — refreshed every time `poll_input` /
    /// `tick` drains a `Resize` message.
    pub fn geometry(&self) -> Geometry {
        self.geometry
    }

    /// Theme name the host advertised (e.g. `"cyberdream"`).
    pub fn theme(&self) -> &str {
        &self.theme
    }

    /// True once the host sent Goodbye or the socket closed —
    /// the sibling should exit cleanly.
    pub fn is_done(&self) -> bool {
        self.done.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Apply pending geometry updates (from background reader)
    /// and drain pending input events. Returns the input events
    /// the sibling should process this frame.
    pub fn drain_inputs(&mut self) -> Vec<InputEvent> {
        while let Ok(g) = self.rx_geometry.try_recv() {
            self.geometry = g;
        }
        let mut out = Vec::new();
        while let Ok(ev) = self.rx_inputs.try_recv() {
            out.push(ev);
        }
        out
    }

    /// Ship a ratatui buffer to the host as a `Frame`.
    pub fn send_frame_from_buffer(
        &mut self,
        buffer: &ratatui::buffer::Buffer,
    ) -> std::io::Result<()> {
        let cells = buffer_to_cells(buffer);
        let msg = SiblingMessage::Frame { cells };
        write_message(&mut self.writer, &msg)?;
        self.writer.flush()?;
        Ok(())
    }

    /// Send a clean-exit message. Optional — letting `Drop` close
    /// the socket also marks the sibling disconnected on the host.
    pub fn send_bye(&mut self) {
        let _ = write_message(&mut self.writer, &SiblingMessage::Bye);
        let _ = self.writer.flush();
    }

    /// Convenience wrapper around [`crate::toast`] — surfaces a
    /// toast in the host without going through the Mount socket
    /// (uses the tier-2 JSONL command channel).
    pub fn toast(&self, message: impl AsRef<str>) {
        crate::ipc::toast(message)
    }

    /// Convenience wrapper around
    /// [`crate::set_activity_badge`] — sets / clears the badge on
    /// the sibling's own activity-bar section. Most siblings use
    /// their manifest `id` as `section`.
    pub fn set_activity_badge(&self, section: impl AsRef<str>, count: u32) {
        crate::ipc::set_activity_badge(section, count)
    }

    /// Convenience wrapper around
    /// [`crate::register_command`] — registers a plugin command
    /// + optional key chords with the host. Commands appear in
    /// the palette and (if `keys` is non-empty) fire on the
    /// given chords.
    pub fn register_command(
        &self,
        id: impl AsRef<str>,
        title: impl AsRef<str>,
        group: Option<&str>,
        keys: &[&str],
    ) {
        crate::ipc::register_command(id, title, group, keys)
    }
}

fn reader_loop<R: Read>(
    mut reader: R,
    tx_input: std::sync::mpsc::Sender<InputEvent>,
    tx_geo: std::sync::mpsc::Sender<Geometry>,
    done: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    loop {
        match read_message::<_, HostMessage>(&mut reader) {
            Ok(Some(HostMessage::Input { event })) => {
                if tx_input.send(event).is_err() {
                    break;
                }
            }
            Ok(Some(HostMessage::Resize { geometry })) => {
                let _ = tx_geo.send(geometry);
            }
            Ok(Some(HostMessage::Hello { .. })) => {
                // Shouldn't happen post-handshake; ignore.
            }
            Ok(Some(HostMessage::Goodbye)) | Ok(None) | Err(_) => {
                done.store(true, std::sync::atomic::Ordering::Relaxed);
                break;
            }
        }
    }
}

/// Convert a `ratatui::buffer::Buffer` into the wire `Vec<Vec<Cell>>`
/// shape. Used by `Mount::send_frame_from_buffer`.
pub fn buffer_to_cells(buffer: &ratatui::buffer::Buffer) -> Vec<Vec<Cell>> {
    let area = buffer.area;
    let mut rows = Vec::with_capacity(area.height as usize);
    for y in 0..area.height {
        let mut row = Vec::with_capacity(area.width as usize);
        for x in 0..area.width {
            let cell = match buffer.cell((area.x + x, area.y + y)) {
                Some(c) => c,
                None => continue,
            };
            row.push(cell_to_wire(cell));
        }
        rows.push(row);
    }
    rows
}

fn cell_to_wire(cell: &ratatui::buffer::Cell) -> Cell {
    Cell {
        symbol: cell.symbol().to_string(),
        fg: ratatui_color_to_wire(cell.fg),
        bg: ratatui_color_to_wire(cell.bg),
        modifiers: ratatui_modifier_to_wire(cell.modifier),
    }
}

fn ratatui_color_to_wire(c: ratatui::style::Color) -> Option<RgbOrIndex> {
    use ratatui::style::Color;
    match c {
        Color::Reset | Color::Black => None,
        Color::Red => Some(RgbOrIndex::Index(1)),
        Color::Green => Some(RgbOrIndex::Index(2)),
        Color::Yellow => Some(RgbOrIndex::Index(3)),
        Color::Blue => Some(RgbOrIndex::Index(4)),
        Color::Magenta => Some(RgbOrIndex::Index(5)),
        Color::Cyan => Some(RgbOrIndex::Index(6)),
        Color::Gray => Some(RgbOrIndex::Index(7)),
        Color::DarkGray => Some(RgbOrIndex::Index(8)),
        Color::LightRed => Some(RgbOrIndex::Index(9)),
        Color::LightGreen => Some(RgbOrIndex::Index(10)),
        Color::LightYellow => Some(RgbOrIndex::Index(11)),
        Color::LightBlue => Some(RgbOrIndex::Index(12)),
        Color::LightMagenta => Some(RgbOrIndex::Index(13)),
        Color::LightCyan => Some(RgbOrIndex::Index(14)),
        Color::White => Some(RgbOrIndex::Index(15)),
        Color::Indexed(i) => Some(RgbOrIndex::Index(i)),
        Color::Rgb(r, g, b) => Some(RgbOrIndex::Rgb([r, g, b])),
    }
}

fn ratatui_modifier_to_wire(m: ratatui::style::Modifier) -> u16 {
    use ratatui::style::Modifier;
    let mut out = 0;
    if m.contains(Modifier::BOLD) {
        out |= modifier::BOLD;
    }
    if m.contains(Modifier::DIM) {
        out |= modifier::DIM;
    }
    if m.contains(Modifier::ITALIC) {
        out |= modifier::ITALIC;
    }
    if m.contains(Modifier::UNDERLINED) {
        out |= modifier::UNDERLINED;
    }
    if m.contains(Modifier::SLOW_BLINK) {
        out |= modifier::SLOW_BLINK;
    }
    if m.contains(Modifier::RAPID_BLINK) {
        out |= modifier::RAPID_BLINK;
    }
    if m.contains(Modifier::REVERSED) {
        out |= modifier::REVERSED;
    }
    if m.contains(Modifier::HIDDEN) {
        out |= modifier::HIDDEN;
    }
    if m.contains(Modifier::CROSSED_OUT) {
        out |= modifier::CROSSED_OUT;
    }
    out
}
