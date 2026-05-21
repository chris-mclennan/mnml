//! Native mixr panel — mnml hosts the sibling `mixr` DJ app as a
//! tmnl-protocol *client*.
//!
//! mnml plays the *server* role here: it binds a Unix socket, launches
//! `mixr --blit <socket>`, and receives `Frame`s of cells which the
//! docked mixr panel renders. It's the mirror of mnml's own `blit`
//! backend (which makes mnml a *client* of tmnl) — modelled on tmnl's
//! `src/server.rs`.

use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Child;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;

use ratatui::crossterm::event::{
    KeyCode as CtKeyCode, KeyEvent as CtKeyEvent, KeyModifiers as CtKeyMods,
    MouseButton as CtMouseButton, MouseEvent as CtMouseEvent, MouseEventKind as CtMouseKind,
};
use ratatui::layout::Rect;
use tmnl_protocol::{
    BUTTON_LEFT, BUTTON_MIDDLE, BUTTON_NONE, BUTTON_RIGHT, Frame, InputEvent,
    KeyCode as WireKeyCode, KeyInput, MOD_ALT, MOD_CTRL, MOD_SHIFT, MOD_SUPER, Message, MouseInput,
    MouseKind, PROTOCOL_VERSION, Resize, read_message, write_message,
};

/// One cell of mixr's screen, as received over the wire. `fg` / `bg`
/// are packed rgba (`tmnl_protocol::unpack_rgba` decodes them);
/// `attrs` is the wire attribute bitset.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MixrCell {
    pub ch: char,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u32,
}

impl MixrCell {
    pub fn blank() -> Self {
        MixrCell {
            ch: ' ',
            fg: 0,
            bg: 0,
            attrs: 0,
        }
    }
}

/// How the mixr panel is shown. `mixr.show` cycles
/// `Minimized → BottomStrip → Full → Minimized`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MixrSize {
    /// Hidden — only the `♪` statusline chip shows; mixr keeps running.
    Minimized,
    /// Docked — a strip along the bottom of the body, from the
    /// file-tree edge across (capped at `MAX_WIDTH`).
    BottomStrip,
    /// Maximised — as tall + wide as the body allows (width capped).
    Full,
}

/// Height (rows) of the docked `BottomStrip` view.
pub const STRIP_ROWS: u16 = 22;
/// Width cap (columns) for the docked panel — past this it stops
/// growing (a very wide screen would make mixr unusably large) and
/// stays left-aligned at the file-tree edge.
pub const MAX_WIDTH: u16 = 200;

/// Where the floating mixr panel (`Short` / `Medium`) is anchored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MixrPos {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Center,
}

impl MixrPos {
    /// The five anchors, in reposition-button order.
    pub const ALL: [MixrPos; 5] = [
        MixrPos::TopLeft,
        MixrPos::TopRight,
        MixrPos::BottomLeft,
        MixrPos::BottomRight,
        MixrPos::Center,
    ];

    /// A glyph showing which anchor this is — for the header button.
    pub fn glyph(self) -> char {
        match self {
            MixrPos::TopLeft => '▘',
            MixrPos::TopRight => '▝',
            MixrPos::BottomLeft => '▖',
            MixrPos::BottomRight => '▗',
            MixrPos::Center => '◆',
        }
    }
}

/// An in-progress drag of the floating mixr panel by its header.
#[derive(Clone, Copy, Debug)]
pub struct MixrPanelDrag {
    /// Cursor offset within the panel where the drag was grabbed.
    pub grab_dx: u16,
    pub grab_dy: u16,
    /// Current free top-left of the panel.
    pub x: u16,
    pub y: u16,
}

/// Anchor a `w`×`h` overlay panel within `body` at `pos`.
pub fn overlay_rect(body: Rect, w: u16, h: u16, pos: MixrPos) -> Rect {
    let w = w.min(body.width.max(1));
    let h = h.min(body.height.max(1));
    let (x, y) = match pos {
        MixrPos::TopLeft => (body.x, body.y),
        MixrPos::TopRight => (body.x + body.width - w, body.y),
        MixrPos::BottomLeft => (body.x, body.y + body.height - h),
        MixrPos::BottomRight => (body.x + body.width - w, body.y + body.height - h),
        MixrPos::Center => (
            body.x + (body.width - w) / 2,
            body.y + (body.height - h) / 2,
        ),
    };
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}

/// The anchor whose third of `body` the panel's centre sits in — used
/// to snap a drag on release.
pub fn nearest_pos(body: Rect, panel: Rect) -> MixrPos {
    let cx = panel.x.saturating_add(panel.width / 2);
    let cy = panel.y.saturating_add(panel.height / 2);
    let (tx, ty) = (body.width / 3, body.height / 3);
    let mid_x = cx >= body.x + tx && cx < body.x + 2 * tx;
    let mid_y = cy >= body.y + ty && cy < body.y + 2 * ty;
    if mid_x && mid_y {
        return MixrPos::Center;
    }
    let left = cx < body.x + body.width / 2;
    let top = cy < body.y + body.height / 2;
    match (left, top) {
        (true, true) => MixrPos::TopLeft,
        (false, true) => MixrPos::TopRight,
        (true, false) => MixrPos::BottomLeft,
        (false, false) => MixrPos::BottomRight,
    }
}

/// mnml's host side of a native mixr panel.
pub struct MixrPanel {
    socket_path: PathBuf,
    child: Child,
    frame_rx: Receiver<Frame>,
    /// The connected mixr client's write half — `Some` once it connects.
    writer: Arc<Mutex<Option<UnixStream>>>,
    /// Latest tab title mixr sent (`Message::Title`).
    title: Arc<Mutex<Option<String>>>,
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<MixrCell>,
    pub cursor: Option<(u16, u16)>,
    pub size: MixrSize,
    pub focused: bool,
    /// Where the floating (`Short` / `Medium`) panel is anchored.
    pub pos: MixrPos,
    /// User-set overlay width (columns) from the header `‹ ›` buttons;
    /// `None` ⇒ the default half-body width.
    pub custom_w: Option<u16>,
}

impl MixrPanel {
    /// Launch `mixr --blit <socket>` and host it; `cols`/`rows` is the
    /// initial panel grid. Errors if the socket can't be bound or
    /// `mixr` can't be spawned.
    pub fn launch(cols: u16, rows: u16) -> Result<MixrPanel, String> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let socket_path =
            std::env::temp_dir().join(format!("mnml-mixr-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("mixr_host: bind {}: {e}", socket_path.display()))?;

        let (frame_tx, frame_rx) = channel::<Frame>();
        let writer: Arc<Mutex<Option<UnixStream>>> = Arc::new(Mutex::new(None));
        let title: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let (writer_c, title_c) = (writer.clone(), title.clone());
        thread::spawn(move || accept_loop(listener, cols, rows, frame_tx, writer_c, title_c));

        let child = std::process::Command::new("mixr")
            .arg("--blit")
            .arg(&socket_path)
            .spawn()
            .map_err(|e| format!("mixr_host: spawn mixr: {e}"))?;

        Ok(MixrPanel {
            socket_path,
            child,
            frame_rx,
            writer,
            title,
            cols,
            rows,
            cells: vec![MixrCell::blank(); cols as usize * rows as usize],
            cursor: None,
            size: MixrSize::BottomStrip,
            focused: false,
            pos: MixrPos::BottomRight,
            custom_w: None,
        })
    }

    /// Drain frames mixr has sent and apply them. Returns true if any
    /// landed (the caller should redraw).
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

    /// The tab title mixr advertised, if any.
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

    /// Tell mixr the panel grid changed size. The local `cells` buffer
    /// is re-sized when mixr's next `Frame` arrives.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        if (cols, rows) != (self.cols, self.rows) {
            self.send(&Message::Resize(Resize { cols, rows }));
        }
    }

    /// Forward an input event to mixr.
    pub fn send_input(&self, ev: InputEvent) {
        self.send(&Message::Input(ev));
    }
}

impl Drop for MixrPanel {
    fn drop(&mut self) {
        self.send(&Message::Quit);
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Apply one (diff) `Frame` to a cell buffer in place — reallocating
/// the buffer + updating `cur_cols`/`cur_rows` on a dimension change.
/// A free function so it's unit-testable without a live `MixrPanel`.
fn apply_frame_into(cells: &mut Vec<MixrCell>, cur_cols: &mut u16, cur_rows: &mut u16, f: &Frame) {
    if *cur_cols != f.cols || *cur_rows != f.rows {
        *cur_cols = f.cols;
        *cur_rows = f.rows;
        *cells = vec![MixrCell::blank(); f.cols as usize * f.rows as usize];
    }
    for run in &f.runs {
        let start = run.start as usize;
        for (i, wc) in run.cells.iter().enumerate() {
            if let Some(slot) = cells.get_mut(start + i) {
                *slot = MixrCell {
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
        // Greet the client + send the initial size — mixr's blit loop
        // blocks on a `Resize` before it starts rendering.
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

/// Translate a crossterm `KeyEvent` into a wire `InputEvent` for the
/// hosted mixr client. `None` for keys the protocol doesn't carry.
pub fn crossterm_key_to_input(key: &CtKeyEvent) -> Option<InputEvent> {
    let code = match key.code {
        CtKeyCode::Char(c) => WireKeyCode::Char(c),
        CtKeyCode::Backspace => WireKeyCode::Backspace,
        CtKeyCode::Enter => WireKeyCode::Enter,
        CtKeyCode::Left => WireKeyCode::Left,
        CtKeyCode::Right => WireKeyCode::Right,
        CtKeyCode::Up => WireKeyCode::Up,
        CtKeyCode::Down => WireKeyCode::Down,
        CtKeyCode::Home => WireKeyCode::Home,
        CtKeyCode::End => WireKeyCode::End,
        CtKeyCode::PageUp => WireKeyCode::PageUp,
        CtKeyCode::PageDown => WireKeyCode::PageDown,
        CtKeyCode::Tab => WireKeyCode::Tab,
        CtKeyCode::BackTab => WireKeyCode::BackTab,
        CtKeyCode::Delete => WireKeyCode::Delete,
        CtKeyCode::Insert => WireKeyCode::Insert,
        CtKeyCode::Esc => WireKeyCode::Esc,
        CtKeyCode::F(n) => WireKeyCode::F(n),
        _ => return None,
    };
    let m = key.modifiers;
    let mut mods = 0u8;
    if m.contains(CtKeyMods::SHIFT) {
        mods |= MOD_SHIFT;
    }
    if m.contains(CtKeyMods::CONTROL) {
        mods |= MOD_CTRL;
    }
    if m.contains(CtKeyMods::ALT) {
        mods |= MOD_ALT;
    }
    if m.contains(CtKeyMods::SUPER) {
        mods |= MOD_SUPER;
    }
    Some(InputEvent::Key(KeyInput {
        code,
        mods,
        press: true,
    }))
}

/// Translate a crossterm `MouseEvent` into a wire `InputEvent`.
/// `col`/`row` must already be panel-local.
pub fn crossterm_mouse_to_input(ev: &CtMouseEvent, col: u16, row: u16) -> InputEvent {
    let button = |b: CtMouseButton| match b {
        CtMouseButton::Left => BUTTON_LEFT,
        CtMouseButton::Right => BUTTON_RIGHT,
        CtMouseButton::Middle => BUTTON_MIDDLE,
    };
    let (kind, btn) = match ev.kind {
        CtMouseKind::Down(b) => (MouseKind::Down, button(b)),
        CtMouseKind::Up(b) => (MouseKind::Up, button(b)),
        CtMouseKind::Drag(b) => (MouseKind::Drag, button(b)),
        CtMouseKind::Moved => (MouseKind::Moved, BUTTON_NONE),
        CtMouseKind::ScrollUp => (MouseKind::ScrollUp, BUTTON_NONE),
        CtMouseKind::ScrollDown => (MouseKind::ScrollDown, BUTTON_NONE),
        CtMouseKind::ScrollLeft => (MouseKind::ScrollLeft, BUTTON_NONE),
        CtMouseKind::ScrollRight => (MouseKind::ScrollRight, BUTTON_NONE),
    };
    InputEvent::Mouse(MouseInput {
        kind,
        button: btn,
        col,
        row,
        mods: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tmnl_protocol::{DiffRun, WireCell};

    fn wire(ch: char) -> WireCell {
        WireCell {
            ch: ch as u32,
            fg: 0,
            bg: 0,
            attrs: 0,
        }
    }

    #[test]
    fn first_frame_sizes_the_buffer_and_writes_a_run() {
        let mut cells = Vec::new();
        let (mut c, mut r) = (0u16, 0u16);
        let f = Frame {
            seq: 0,
            cols: 4,
            rows: 2,
            cursor_col: 0,
            cursor_row: 0,
            cursor_shape: 0,
            cursor_visible: 0,
            runs: vec![DiffRun {
                start: 2,
                cells: vec![wire('h'), wire('i')],
            }],
        };
        apply_frame_into(&mut cells, &mut c, &mut r, &f);
        assert_eq!((c, r), (4, 2));
        assert_eq!(cells.len(), 8);
        assert_eq!(cells[2].ch, 'h');
        assert_eq!(cells[3].ch, 'i');
        assert_eq!(cells[0].ch, ' '); // untouched
    }

    #[test]
    fn a_later_diff_patches_without_clearing() {
        let mut cells = Vec::new();
        let (mut c, mut r) = (0u16, 0u16);
        let base = Frame {
            seq: 0,
            cols: 3,
            rows: 1,
            cursor_col: 0,
            cursor_row: 0,
            cursor_shape: 0,
            cursor_visible: 0,
            runs: vec![DiffRun {
                start: 0,
                cells: vec![wire('a'), wire('b'), wire('c')],
            }],
        };
        apply_frame_into(&mut cells, &mut c, &mut r, &base);
        // Same dims ⇒ no realloc; the run patches only cell 1.
        let diff = Frame {
            runs: vec![DiffRun {
                start: 1,
                cells: vec![wire('X')],
            }],
            ..base.clone()
        };
        apply_frame_into(&mut cells, &mut c, &mut r, &diff);
        assert_eq!(cells[0].ch, 'a'); // kept
        assert_eq!(cells[1].ch, 'X'); // patched
        assert_eq!(cells[2].ch, 'c'); // kept
    }

    #[test]
    fn overlay_rect_anchors_to_each_corner() {
        let body = Rect {
            x: 0,
            y: 0,
            width: 100,
            height: 40,
        };
        let br = overlay_rect(body, 20, 10, MixrPos::BottomRight);
        assert_eq!((br.x, br.y), (80, 30));
        let tl = overlay_rect(body, 20, 10, MixrPos::TopLeft);
        assert_eq!((tl.x, tl.y), (0, 0));
        let c = overlay_rect(body, 20, 10, MixrPos::Center);
        assert_eq!((c.x, c.y), (40, 15));
    }

    #[test]
    fn nearest_pos_snaps_to_the_containing_third() {
        let body = Rect {
            x: 0,
            y: 0,
            width: 90,
            height: 30,
        };
        let tl = Rect {
            x: 0,
            y: 0,
            width: 10,
            height: 4,
        };
        assert_eq!(nearest_pos(body, tl), MixrPos::TopLeft);
        let mid = Rect {
            x: 40,
            y: 13,
            width: 10,
            height: 4,
        };
        assert_eq!(nearest_pos(body, mid), MixrPos::Center);
    }
}
