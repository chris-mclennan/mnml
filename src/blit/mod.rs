//! BlitBackend mode — mnml renders into a ratatui `TestBackend` and ships
//! each frame's cell grid as a binary `Frame` over a Unix socket to a tmnl
//! server. Symmetric to `headless::run` but with a UDS sink instead of a
//! file-IPC dump.
//!
//! v2: also receives `Input` messages from tmnl (keyboard + mouse + scroll)
//! and feeds them through `tui::dispatch_key` / `tui::dispatch_mouse`, the
//! same paths the terminal loop uses. End result: mnml runs inside tmnl
//! identically to running in a real terminal.

use std::io::BufReader;
// Cross-platform UDS client. Unix uses std's `UnixStream`; Windows
// uses `uds_windows::UnixStream` (a wrapper around the Windows AF_UNIX
// support added in Win10 build 17063). Same path-addressed socket on
// every platform — matches the corresponding switch on tmnl's server
// side (see tmnl/src/server.rs).
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Mutex;
use std::sync::mpsc::{TryRecvError, channel};
use std::thread;
use std::time::Duration;
#[cfg(windows)]
use uds_windows::UnixStream;

use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{
    KeyCode as CtKeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers,
    MouseButton as CtMouseButton, MouseEvent, MouseEventKind,
};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier};

use crate::app::App;
use crate::input::CursorShape;
use crate::tui;
use crate::ui;

use tmnl_protocol::{
    BUTTON_LEFT, BUTTON_MIDDLE, BUTTON_RIGHT, DiffRun, Frame, InputEvent, KeyCode as WireKeyCode,
    KeyInput, MOD_ALT, MOD_CTRL, MOD_SHIFT, MOD_SUPER, Message, MouseInput, MouseKind,
    PROTOCOL_VERSION, WireCell, pack_rgba_u8, read_message, write_message,
};

const POLL_SLEEP: Duration = Duration::from_millis(16);
const INITIAL_RESIZE_TIMEOUT: Duration = Duration::from_secs(5);

const ATTR_BOLD: u32 = 1 << 0;
const ATTR_DIM: u32 = 1 << 1;
const ATTR_ITALIC: u32 = 1 << 2;
const ATTR_UNDERLINE: u32 = 1 << 3;
const ATTR_REVERSED: u32 = 1 << 4;
const ATTR_CROSSED_OUT: u32 = 1 << 5;

pub fn run(mut app: App, socket: &Path) -> Result<bool, String> {
    let conn = UnixStream::connect(socket)
        .map_err(|e| format!("blit: connect {}: {e}", socket.display()))?;
    let reader_stream = conn.try_clone().map_err(|e| format!("blit: clone: {e}"))?;
    let writer = Mutex::new(conn);

    {
        let mut w = writer.lock().unwrap();
        write_message(
            &mut *w,
            &Message::Hello {
                version: PROTOCOL_VERSION,
            },
        )
        .map_err(|e| format!("blit: hello: {e}"))?;
        // Tell the renderer what to call this tab. Mirrors the OSC 0/2
        // terminal-title sequence that `tui::run` would normally emit
        // — under blit there's no real terminal to receive it, so we
        // send it as a `Title` message instead. Just the workspace
        // name (no `mnml — ` prefix) — matches what mnml's standalone
        // palette bar shows; tmnl's chrome chip pulls this directly.
        let title = match app.workspace.file_name().and_then(|n| n.to_str()) {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => "mnml".to_string(),
        };
        write_message(&mut *w, &Message::Title(title)).map_err(|e| format!("blit: title: {e}"))?;
    }

    let (resize_tx, resize_rx) = channel::<(u16, u16)>();
    let (input_tx, input_rx) = channel::<InputEvent>();
    let (quit_tx, quit_rx) = channel::<()>();
    let (disc_tx, disc_rx) = channel::<()>();
    thread::spawn(move || {
        let mut r = BufReader::new(reader_stream);
        loop {
            match read_message(&mut r) {
                Ok(Message::Resize(rz)) => {
                    if resize_tx.send((rz.cols, rz.rows)).is_err() {
                        break;
                    }
                }
                Ok(Message::Input(ev)) => {
                    if input_tx.send(ev).is_err() {
                        break;
                    }
                }
                Ok(Message::Quit) => {
                    let _ = quit_tx.send(());
                    break;
                }
                Ok(_) => {}
                Err(_) => {
                    let _ = disc_tx.send(());
                    break;
                }
            }
        }
    });

    let (mut cols, mut rows) = resize_rx
        .recv_timeout(INITIAL_RESIZE_TIMEOUT)
        .map_err(|_| "blit: no Resize from server within 5s".to_string())?;
    if cols == 0 || rows == 0 {
        return Err(format!("blit: server reported empty grid {cols}x{rows}"));
    }

    let backend = TestBackend::new(cols, rows);
    let mut terminal = Terminal::new(backend).map_err(|e| format!("blit: terminal: {e}"))?;

    // mnml is running as a tmnl native client.
    app.under_tmnl = true;
    app.run_startup_tasks();
    // Start the now-playing poller here too — the terminal loop in
    // `tui.rs` does the same. Without it the `♪` statusline chip
    // never tracks mixr when mnml is hosted under tmnl.
    app.start_now_playing_poller();

    let mut frame_seq: u64 = 0;
    let mut prev_cells: Vec<WireCell> = Vec::new();
    let mut prev_dims: (u16, u16) = (0, 0);
    loop {
        app.tick();

        // Forward any open-pane requests mnml queued this tick (e.g.
        // `mixr.show`) to the tmnl host as `OpenPane` messages.
        if !app.pending_open_panes.is_empty() {
            let mut w = writer.lock().unwrap();
            for (command, args) in app.pending_open_panes.drain(..) {
                let _ = write_message(&mut *w, &Message::OpenPane { command, args });
            }
        }

        let mut new_size: Option<(u16, u16)> = None;
        loop {
            match resize_rx.try_recv() {
                Ok(p) => new_size = Some(p),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    app.save_session_on_quit();
                    return Ok(app.restart_requested);
                }
            }
        }
        if let Some((nc, nr)) = new_size
            && (nc != cols || nr != rows)
            && nc > 0
            && nr > 0
        {
            cols = nc;
            rows = nr;
            // `terminal.resize(Rect)` only updates the viewport area; the
            // `TestBackend`'s underlying cell buffer keeps its original
            // dimensions, so subsequent draws into the new viewport index
            // past the storage and panic. Resize the backend explicitly
            // first.
            terminal.backend_mut().resize(cols, rows);
            terminal
                .resize(Rect::new(0, 0, cols, rows))
                .map_err(|e| format!("blit: resize: {e}"))?;
            // Wire-side diff baseline is per-cell against a flat vec keyed
            // by `cols`; on a dim change the diff would alias old offsets
            // onto new ones, so reset and re-send a full frame.
            prev_cells.clear();
        }

        if app.should_quit {
            app.save_session_on_quit();
            break;
        }
        if quit_rx.try_recv().is_ok() {
            app.save_session_on_quit();
            break;
        }
        if disc_rx.try_recv().is_ok() {
            app.save_session_on_quit();
            break;
        }

        loop {
            match input_rx.try_recv() {
                Ok(InputEvent::Key(k)) => {
                    let ke = key_to_crossterm(&k);
                    tui::dispatch_key(&mut app, ke);
                }
                Ok(InputEvent::Mouse(m)) => {
                    let me = mouse_to_crossterm(&m);
                    tui::dispatch_mouse(&mut app, me);
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    app.save_session_on_quit();
                    return Ok(app.restart_requested);
                }
            }
            if app.should_quit {
                break;
            }
        }
        if app.should_quit {
            app.save_session_on_quit();
            break;
        }

        terminal
            .draw(|f| ui::draw(f, &mut app))
            .map_err(|e| format!("blit: draw: {e}"))?;
        // `ui::draw` populates `app.rects.drawn_cursor_pos` only when it
        // actually called `set_cursor_position` this frame. Using
        // `terminal.get_cursor_position()` instead would return a stale
        // (0, 0) on the welcome screen and tmnl would paint a white flash
        // at the top-left before mnml has shown anything.
        let cursor = app.rects.drawn_cursor_pos;

        let buf = terminal.backend().buffer();
        // Authoritative dims come from the buffer itself, not our cols/rows
        // locals — a resize race could otherwise index past the storage.
        let bw = buf.area.width;
        let bh = buf.area.height;
        let mut cells = Vec::with_capacity(bw as usize * bh as usize);
        for y in 0..bh {
            for x in 0..bw {
                let c = &buf[(x, y)];
                let fg = color_to_rgba(c.fg, false);
                let bg = color_to_rgba(c.bg, true);
                let ch = c.symbol().chars().next().unwrap_or(' ') as u32;
                let attrs = modifier_to_bits(c.modifier);
                cells.push(WireCell { ch, fg, bg, attrs });
            }
        }

        let cursor_shape = match app.editing_mode().cursor_shape() {
            CursorShape::Block => 0u8,
            CursorShape::Underline => 1u8,
            CursorShape::Bar => 2u8,
        };
        let runs = if prev_cells.len() != cells.len() || prev_dims != (bw, bh) {
            vec![DiffRun {
                start: 0,
                cells: cells.clone(),
            }]
        } else {
            compute_runs(&prev_cells, &cells)
        };
        prev_cells.clear();
        prev_cells.extend_from_slice(&cells);
        prev_dims = (bw, bh);
        let frame = Frame {
            seq: frame_seq,
            cols: bw,
            rows: bh,
            cursor_col: cursor.map(|(x, _)| x).unwrap_or(0),
            cursor_row: cursor.map(|(_, y)| y).unwrap_or(0),
            cursor_shape,
            cursor_visible: u8::from(cursor.is_some()),
            runs,
        };
        frame_seq = frame_seq.wrapping_add(1);

        {
            let mut w = writer.lock().unwrap();
            if write_message(&mut *w, &Message::Frame(frame)).is_err() {
                break;
            }
        }

        thread::sleep(POLL_SLEEP);
    }

    Ok(app.restart_requested)
}

fn modifier_to_bits(m: Modifier) -> u32 {
    let mut a = 0u32;
    if m.contains(Modifier::BOLD) {
        a |= ATTR_BOLD;
    }
    if m.contains(Modifier::DIM) {
        a |= ATTR_DIM;
    }
    if m.contains(Modifier::ITALIC) {
        a |= ATTR_ITALIC;
    }
    if m.contains(Modifier::UNDERLINED) {
        a |= ATTR_UNDERLINE;
    }
    if m.contains(Modifier::REVERSED) {
        a |= ATTR_REVERSED;
    }
    if m.contains(Modifier::CROSSED_OUT) {
        a |= ATTR_CROSSED_OUT;
    }
    a
}

fn color_to_rgba(c: Color, is_bg: bool) -> u32 {
    if let Color::Rgb(r, g, b) = c {
        return pack_rgba_u8(r, g, b, 0xff);
    }
    let t = crate::ui::theme::cur();
    let resolve_indexed = |i: u8| -> u32 {
        if (i as usize) < t.base16.len() {
            color_to_rgba_inner(t.base16[i as usize])
        } else {
            ansi256_to_rgba(i)
        }
    };
    match c {
        Color::Reset => {
            if is_bg {
                color_to_rgba_inner(t.bg_dark)
            } else {
                color_to_rgba_inner(t.fg)
            }
        }
        Color::Black => resolve_indexed(0),
        Color::Red => resolve_indexed(1),
        Color::Green => resolve_indexed(2),
        Color::Yellow => resolve_indexed(3),
        Color::Blue => resolve_indexed(4),
        Color::Magenta => resolve_indexed(5),
        Color::Cyan => resolve_indexed(6),
        Color::Gray => resolve_indexed(7),
        Color::DarkGray => resolve_indexed(8),
        Color::LightRed => resolve_indexed(9),
        Color::LightGreen => resolve_indexed(10),
        Color::LightYellow => resolve_indexed(11),
        Color::LightBlue => resolve_indexed(12),
        Color::LightMagenta => resolve_indexed(13),
        Color::LightCyan => resolve_indexed(14),
        Color::White => resolve_indexed(15),
        Color::Indexed(i) => resolve_indexed(i),
        Color::Rgb(_, _, _) => unreachable!(),
    }
}

fn color_to_rgba_inner(c: Color) -> u32 {
    match c {
        Color::Rgb(r, g, b) => pack_rgba_u8(r, g, b, 0xff),
        _ => pack_rgba_u8(0xab, 0xb2, 0xbf, 0xff),
    }
}

fn ansi256_to_rgba(i: u8) -> u32 {
    if i < 16 {
        let palette = [
            (0x10, 0x11, 0x1c),
            (0xe0, 0x60, 0x60),
            (0x84, 0xc8, 0x6f),
            (0xee, 0xbb, 0x57),
            (0x6e, 0xa2, 0xe7),
            (0xc9, 0x7a, 0xea),
            (0x5f, 0xb3, 0xa1),
            (0xab, 0xb2, 0xbf),
            (0x42, 0x46, 0x4e),
            (0xff, 0x82, 0x82),
            (0xa6, 0xe2, 0x8c),
            (0xff, 0xd7, 0x71),
            (0x82, 0xb3, 0xff),
            (0xdc, 0xa5, 0xff),
            (0x84, 0xd6, 0xc5),
            (0xff, 0xff, 0xff),
        ];
        let (r, g, b) = palette[i as usize];
        pack_rgba_u8(r, g, b, 0xff)
    } else if i < 232 {
        let n = i - 16;
        let r = (n / 36) * 51;
        let g = ((n / 6) % 6) * 51;
        let b = (n % 6) * 51;
        pack_rgba_u8(r, g, b, 0xff)
    } else {
        let v = 8 + (i - 232) * 10;
        pack_rgba_u8(v, v, v, 0xff)
    }
}

fn unpack_mods(m: u8) -> KeyModifiers {
    let mut out = KeyModifiers::empty();
    if m & MOD_SHIFT != 0 {
        out |= KeyModifiers::SHIFT;
    }
    if m & MOD_CTRL != 0 {
        out |= KeyModifiers::CONTROL;
    }
    if m & MOD_ALT != 0 {
        out |= KeyModifiers::ALT;
    }
    if m & MOD_SUPER != 0 {
        out |= KeyModifiers::SUPER;
    }
    out
}

fn key_to_crossterm(k: &KeyInput) -> KeyEvent {
    let code = match k.code {
        WireKeyCode::Char(c) => CtKeyCode::Char(c),
        WireKeyCode::Backspace => CtKeyCode::Backspace,
        WireKeyCode::Enter => CtKeyCode::Enter,
        WireKeyCode::Left => CtKeyCode::Left,
        WireKeyCode::Right => CtKeyCode::Right,
        WireKeyCode::Up => CtKeyCode::Up,
        WireKeyCode::Down => CtKeyCode::Down,
        WireKeyCode::Home => CtKeyCode::Home,
        WireKeyCode::End => CtKeyCode::End,
        WireKeyCode::PageUp => CtKeyCode::PageUp,
        WireKeyCode::PageDown => CtKeyCode::PageDown,
        WireKeyCode::Tab => CtKeyCode::Tab,
        WireKeyCode::BackTab => CtKeyCode::BackTab,
        WireKeyCode::Delete => CtKeyCode::Delete,
        WireKeyCode::Insert => CtKeyCode::Insert,
        WireKeyCode::Esc => CtKeyCode::Esc,
        WireKeyCode::F(n) => CtKeyCode::F(n),
    };
    KeyEvent {
        code,
        modifiers: unpack_mods(k.mods),
        kind: KeyEventKind::Press,
        state: KeyEventState::empty(),
    }
}

fn mouse_to_crossterm(m: &MouseInput) -> MouseEvent {
    let button = match m.button {
        BUTTON_LEFT => CtMouseButton::Left,
        BUTTON_RIGHT => CtMouseButton::Right,
        BUTTON_MIDDLE => CtMouseButton::Middle,
        _ => CtMouseButton::Left,
    };
    let kind = match m.kind {
        MouseKind::Down => MouseEventKind::Down(button),
        MouseKind::Up => MouseEventKind::Up(button),
        MouseKind::Drag => MouseEventKind::Drag(button),
        MouseKind::Moved => MouseEventKind::Moved,
        MouseKind::ScrollUp => MouseEventKind::ScrollUp,
        MouseKind::ScrollDown => MouseEventKind::ScrollDown,
        MouseKind::ScrollLeft => MouseEventKind::ScrollLeft,
        MouseKind::ScrollRight => MouseEventKind::ScrollRight,
    };
    MouseEvent {
        kind,
        column: m.col,
        row: m.row,
        modifiers: unpack_mods(m.mods),
    }
}

const MERGE_GAP: usize = 4;
const FULL_REPLACE_THRESHOLD: usize = 70;

fn compute_runs(prev: &[WireCell], cur: &[WireCell]) -> Vec<DiffRun> {
    debug_assert_eq!(prev.len(), cur.len());
    let n = cur.len();
    let mut runs: Vec<DiffRun> = Vec::new();
    let mut changed_total = 0usize;
    let mut i = 0;
    while i < n {
        if prev[i] == cur[i] {
            i += 1;
            continue;
        }
        let start = i;
        let mut last_change = i + 1;
        let mut j = i + 1;
        while j < n {
            if prev[j] == cur[j] {
                if j - last_change >= MERGE_GAP {
                    break;
                }
            } else {
                last_change = j + 1;
            }
            j += 1;
        }
        let end = last_change;
        let run_cells: Vec<WireCell> = cur[start..end].to_vec();
        changed_total += run_cells.len();
        runs.push(DiffRun {
            start: start as u32,
            cells: run_cells,
        });
        i = end;
    }
    // If most of the grid changed, the per-run framing overhead is a tax;
    // fall back to a single full-grid run.
    if n > 0 && (changed_total * 100 / n) > FULL_REPLACE_THRESHOLD {
        return vec![DiffRun {
            start: 0,
            cells: cur.to_vec(),
        }];
    }
    runs
}
