//! Embedded terminal — one [`PtySession`] is the `Pane::Pty` payload: a live pty
//! plus a child process (`$SHELL`, `claude`, `codex`, …) whose output is parsed
//! by [`libghostty_vt`] into a grid the renderer reads. libghostty-vt's terminal
//! is `!Send`/`!Sync`, so it lives on the UI thread: a reader thread pumps the
//! pty's raw bytes over an mpsc channel, and [`PtySession::pump`] drains them
//! into the terminal each frame. Outbound keystrokes — and the terminal's own
//! query responses (DSR/DA/…, captured via `on_pty_write`) — go through the
//! pty's write half on the UI thread. Dropping the session kills the child and
//! joins the reader.
//!
//! Each pty is a pane in the split tree — no separate tab strip;
//! multiple shells = multiple splits.

use std::cell::RefCell;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use libghostty_vt::render::{CellIterator, CursorViewport, RowIterator};
use libghostty_vt::style::{RgbColor, Underline};
use libghostty_vt::terminal::ScrollViewport;
use libghostty_vt::{RenderState, Terminal, TerminalOptions};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

/// How many lines of scroll-back libghostty-vt keeps (`Shift+PgUp` / wheel).
const SCROLLBACK_LINES: usize = 5000;

/// One rendered cell — a flat, owned snapshot the renderers read so they never
/// touch libghostty's lending iterators or FFI lifetimes directly.
#[derive(Clone, Default)]
pub struct RenderCell {
    /// The grapheme cluster for this column (empty ⇒ blank).
    pub text: String,
    /// Resolved foreground; `None` ⇒ use the terminal default.
    pub fg: Option<RgbColor>,
    /// Resolved background; `None` ⇒ use the terminal default.
    pub bg: Option<RgbColor>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

/// A whole-frame snapshot of the visible grid — produced by
/// [`PtySession::render_grid`], consumed by the pty renderers.
pub struct RenderGrid {
    pub rows: u16,
    pub cols: u16,
    /// Row-major, `rows * cols` cells.
    pub cells: Vec<RenderCell>,
    pub default_fg: RgbColor,
    pub default_bg: RgbColor,
    /// `(col, row)` of the cursor when visible + in the live viewport.
    pub cursor: Option<(u16, u16)>,
}

impl RenderGrid {
    /// Cell at `(row, col)`, or `None` if out of range.
    pub fn cell(&self, row: u16, col: u16) -> Option<&RenderCell> {
        if row >= self.rows || col >= self.cols {
            return None;
        }
        self.cells
            .get(row as usize * self.cols as usize + col as usize)
    }
}

/// What runs inside a pty pane — a config record so the caller picks "shell" vs
/// "claude" without this module knowing about products.
#[derive(Debug, Clone)]
pub struct BinaryProfile {
    /// Tab/title label — `terminal (zsh)`, `claude code`, `codex`, …
    pub label: String,
    /// Executable (looked up on `PATH` if not absolute).
    pub exe: String,
    pub args: Vec<String>,
    /// Working directory; `None` ⇒ inherit.
    pub cwd: Option<PathBuf>,
    /// Extra env vars to set in the child.
    pub env: Vec<(String, String)>,
    /// For `claude` profiles: the `--session-id` / `--resume` id, so mnml can
    /// open a transcript mirror of this session. `None` for shells / codex.
    pub session_id: Option<String>,
}

impl BinaryProfile {
    /// The user's `$SHELL` (interactive), or `/bin/sh`.
    pub fn shell(cwd: Option<PathBuf>) -> Self {
        let exe = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let name = exe.rsplit('/').next().unwrap_or("shell").to_string();
        BinaryProfile {
            label: format!("terminal ({name})"),
            exe,
            args: Vec::new(),
            cwd,
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `claude` (Claude Code), with a known `--session-id` (so mnml can mirror the
    /// transcript). If the workspace has a `.mnml/CLAUDE.md`, inject it via
    /// `--append-system-prompt` so the assistant orients before message #1.
    pub fn claude_code(workspace: PathBuf) -> Self {
        let sid = crate::ai::gen_session_id();
        let mut args = vec!["--session-id".to_string(), sid.clone()];
        let brief = workspace.join(".mnml").join("CLAUDE.md");
        if let Ok(text) = std::fs::read_to_string(&brief)
            && !text.trim().is_empty()
        {
            args.push("--append-system-prompt".to_string());
            args.push(text);
        }
        BinaryProfile {
            label: "claude code".to_string(),
            exe: "claude".to_string(),
            args,
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(sid),
        }
    }

    /// `claude` with an initial prompt as the trailing positional arg —
    /// boots an interactive session already seeded with `initial`
    /// (file/selection context the `ai.chat` wrapper formulated). Avoids
    /// the type-into-a-cold-pty timing problem.
    pub fn claude_code_with_prompt(workspace: PathBuf, initial: String) -> Self {
        let mut p = Self::claude_code(workspace);
        p.args.push(initial);
        p
    }

    /// `claude --resume <session_id>` — open an existing session (e.g. one started
    /// by an `ai.*` one-shot) interactively, with its conversation already loaded.
    pub fn claude_code_resume(workspace: PathBuf, session_id: String) -> Self {
        BinaryProfile {
            label: "claude code (resumed)".to_string(),
            exe: "claude".to_string(),
            args: vec!["--resume".to_string(), session_id.clone()],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(session_id),
        }
    }

    /// A named `[tasks.<name>]` entry — run `cmdline` via `$SHELL -c` in a pty pane.
    /// `cwd` defaults to the workspace.
    pub fn task(name: &str, cmdline: &str, cwd: PathBuf) -> Self {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        // multilang-dev-user F3 — drop the redundant 'task: ' prefix
        // so a bufferline tab for 'npm run dev' reads 'npm run dev'
        // not 'task: npm run dev'. The bufferline is already context
        // enough; the prefix was noise that compounded across 3-4
        // concurrent watchers.
        BinaryProfile {
            label: name.to_string(),
            exe: shell,
            args: vec!["-c".to_string(), cmdline.to_string()],
            cwd: Some(cwd),
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `codex` (OpenAI Codex CLI).
    pub fn codex(workspace: PathBuf) -> Self {
        BinaryProfile {
            label: "codex".to_string(),
            exe: "codex".to_string(),
            args: Vec::new(),
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `mixr` — the sibling TUI DJ app (`~/Projects/mixr`). Launches with
    /// `--dashboard` so it lands directly on the controller view (skipping the
    /// browser); the user can press `v` in mixr to cycle through its Panel
    /// layouts to fit mnml's split.
    pub fn mixr(workspace: PathBuf) -> Self {
        BinaryProfile {
            label: "mixr".to_string(),
            exe: "mixr".to_string(),
            args: vec!["--dashboard".to_string()],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
        }
    }
}

/// One live pty + child + libghostty-vt grid. Drop to kill the child + join
/// the reader.
pub struct PtySession {
    pub profile: BinaryProfile,
    /// User-set session name (`:rename`). Shown in the pty-pane tab strip
    /// + the bufferline tab in place of `profile.label` when present.
    pub display_name: Option<String>,
    /// libghostty-vt terminal — `!Send`/`!Sync`, so it lives only on the UI
    /// thread. Fed raw pty bytes (from `rx`) by [`PtySession::pump`].
    term: Terminal<'static, 'static>,
    /// Render state for reading the grid each frame. `RefCell` so the renderers
    /// can read through a `&self` while `update` takes `&mut`.
    render_state: RefCell<RenderState<'static>>,
    /// Raw pty output shipped from the reader thread; drained by `pump`.
    rx: Receiver<Vec<u8>>,
    /// Bytes the terminal wants written back to the pty (DSR/DA query replies,
    /// captured by the `on_pty_write` callback during `vt_write`); flushed by
    /// `pump`.
    responses: Rc<RefCell<Vec<u8>>>,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    reader: Option<JoinHandle<()>>,
    child: Box<dyn Child + Send + Sync>,
    /// Set by the reader thread when the pty hits EOF / error (child gone).
    exited: Arc<Mutex<bool>>,
    /// Last `(rows, cols)` sent to the pty — skip the resize (and its SIGWINCH /
    /// child-redraw flicker) when the rendered size hasn't changed.
    last_size: (u16, u16),
    /// Total bytes the reader has processed — the event loop snapshots this to
    /// know when to redraw (an idle pty shouldn't force per-tick repaints).
    pub bytes_seen: Arc<AtomicU64>,
    /// `bytes_seen` snapshot at the last time the user focused
    /// this pane. Unread count = `bytes_seen - bytes_seen_on_focus`.
    /// Reset to current bytes_seen when the pane is focused.
    pub bytes_seen_on_focus: u64,
    /// Last system-clock instant at which `bytes_seen` advanced.
    /// Used by the sessions panel to decide running vs idle.
    pub last_output_at: Option<std::time::Instant>,
    /// `bytes_seen` snapshot at the prior tick — used together
    /// with `last_output_at` to detect new output.
    pub last_bytes_snapshot: u64,
    /// Optional per-session accent color name (`"green"`, `"blue"`,
    /// …) used by the sessions panel. `None` ⇒ default active-
    /// color. Reset to `None` via the kebab's "None" choice.
    pub accent_color: Option<String>,
}

impl PtySession {
    pub fn spawn(profile: BinaryProfile, rows: u16, cols: u16) -> Result<Self, String> {
        let (rows, cols) = (rows.max(4), cols.max(20));
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("openpty: {e}"))?;

        let mut cmd = CommandBuilder::new(&profile.exe);
        for a in &profile.args {
            cmd.arg(a);
        }
        if let Some(cwd) = &profile.cwd {
            cmd.cwd(cwd);
        }
        // Override TERM to a universally-known terminfo entry. mnml's
        // parent process is often launched from Ghostty which sets
        // TERM=xterm-ghostty; ncurses tools (iftop / htop / less / vim)
        // fail with "Error opening terminal: xterm-ghostty" when the
        // terminfo entry isn't installed on the machine. Mnml's
        // internal ghostty terminal core still handles xterm-256color
        // output correctly, and profile.env below can still override
        // this per-profile if needed.
        cmd.env("TERM", "xterm-256color");
        for (k, v) in &profile.env {
            cmd.env(k, v);
        }
        // Themed powerline prompt. Sets `MNML_PROMPT_SCRIPT` (path to the
        // installed `prompt.sh`) plus the palette env vars the script
        // reads. The user opts in once via a one-line source in their
        // `.zshrc`/`.bashrc` — see README. Skipped for non-shell pty
        // sessions (claude / codex / etc.) since they don't render
        // their own prompt — heuristic: the profile.exe basename ends
        // in `sh` or matches a known shell.
        if is_shell_profile(&profile.exe) {
            for (k, v) in crate::shell_prompt::theme_env_vars("mnml") {
                cmd.env(k, v);
            }
        }
        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("spawn {}: {e} — is it on PATH?", profile.exe))?;
        drop(pair.slave);

        let mut term = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: SCROLLBACK_LINES,
        })
        .map_err(|e| format!("ghostty terminal: {e:?}"))?;
        // Buffer the terminal's pty-write requests (query replies — DSR/DA/…)
        // so `pump` can flush them back to the child. libghostty forbids
        // `vt_write` during this callback, so we only stash bytes here.
        let responses = Rc::new(RefCell::new(Vec::new()));
        {
            let sink = Rc::clone(&responses);
            term.on_pty_write(move |_term, data| {
                sink.borrow_mut().extend_from_slice(data);
            })
            .map_err(|e| format!("ghostty on_pty_write: {e:?}"))?;
        }
        let render_state =
            RefCell::new(RenderState::new().map_err(|e| format!("ghostty render state: {e:?}"))?);

        let exited = Arc::new(Mutex::new(false));
        let bytes_seen = Arc::new(AtomicU64::new(0));
        let (tx, rx) = channel::<Vec<u8>>();

        let mut reader_handle = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("clone pty reader: {e}"))?;
        let r_exited = Arc::clone(&exited);
        let r_bytes = Arc::clone(&bytes_seen);
        let reader = std::thread::Builder::new()
            .name(format!("mnml-pty-{}", profile.exe))
            .spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    match reader_handle.read(&mut buf) {
                        Ok(0) | Err(_) => {
                            if let Ok(mut e) = r_exited.lock() {
                                *e = true;
                            }
                            return;
                        }
                        Ok(n) => {
                            // Ship raw bytes to the UI thread, which owns the
                            // (!Send) terminal and feeds them in via `pump`.
                            if tx.send(buf[..n].to_vec()).is_err() {
                                return; // receiver (the session) was dropped
                            }
                            r_bytes.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                }
            })
            .map_err(|e| format!("spawn pty reader thread: {e}"))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("take pty writer: {e}"))?;

        Ok(PtySession {
            profile,
            display_name: None,
            term,
            render_state,
            rx,
            responses,
            writer,
            master: pair.master,
            reader: Some(reader),
            child,
            exited,
            last_size: (rows, cols),
            bytes_seen,
            bytes_seen_on_focus: 0,
            last_output_at: None,
            last_bytes_snapshot: 0,
            accent_color: None,
        })
    }

    /// Drain raw pty output from the reader thread into the terminal, then
    /// flush any query replies the terminal produced (via `on_pty_write`) back
    /// to the pty. Call once per frame on the UI thread, before rendering.
    pub fn pump(&mut self) {
        let mut wrote = false;
        while let Ok(chunk) = self.rx.try_recv() {
            self.term.vt_write(&chunk);
            wrote = true;
        }
        if wrote {
            let mut out = self.responses.borrow_mut();
            if !out.is_empty() {
                let _ = self.writer.write_all(&out);
                let _ = self.writer.flush();
                out.clear();
            }
        }
    }

    /// Snapshot the visible grid into a flat, owned [`RenderGrid`] the renderers
    /// index directly — all of libghostty's lending-iterator + FFI-lifetime
    /// handling stays inside [`snapshot_grid`].
    pub fn render_grid(&self) -> RenderGrid {
        snapshot_grid(&self.term, &mut self.render_state.borrow_mut())
    }

    /// Reset the unread counter to "all read" — called when the
    /// user focuses this pane. After this, `unread_bytes()`
    /// returns 0 until the reader produces more output.
    pub fn mark_seen(&mut self) {
        self.bytes_seen_on_focus = self.bytes_processed();
    }

    /// How many bytes have arrived since the last `mark_seen`.
    /// Used by the sessions panel to render the `🔔` bell badge.
    pub fn unread_bytes(&self) -> u64 {
        self.bytes_processed()
            .saturating_sub(self.bytes_seen_on_focus)
    }

    /// Tick — refresh `last_output_at` when `bytes_seen` has
    /// moved since the last tick. Called from the event loop's
    /// per-frame Pty maintenance pass.
    pub fn tick_activity(&mut self) {
        let now_bytes = self.bytes_processed();
        if now_bytes > self.last_bytes_snapshot {
            self.last_bytes_snapshot = now_bytes;
            self.last_output_at = Some(std::time::Instant::now());
        }
    }

    /// Resize the pty (and the parser grid) to `rows × cols`. No-op when
    /// unchanged — every resize SIGWINCHes the child into a redraw.
    pub fn resize(&mut self, rows: u16, cols: u16) {
        let (rows, cols) = (rows.max(4), cols.max(20));
        if self.last_size == (rows, cols) {
            return;
        }
        self.last_size = (rows, cols);
        let _ = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        // libghostty's resize takes (cols, rows, cell_w_px, cell_h_px).
        let _ = self.term.resize(cols, rows, 0, 0);
    }

    pub fn write_bytes(&mut self, bytes: &[u8]) {
        let _ = self.writer.write_all(bytes);
        let _ = self.writer.flush();
    }

    /// Whether the child process has enabled any form of mouse
    /// tracking (X10 / normal / button / any-event via the
    /// standard `CSI ?1000h / ?1002h / ?1003h` sequences).
    /// When true, mnml forwards mouse events to the child
    /// instead of handling them itself (dock menu, focus, etc.).
    pub fn is_mouse_tracking(&self) -> bool {
        self.term.is_mouse_tracking().unwrap_or(false)
    }

    /// Write an SGR mouse-report escape sequence to the child.
    /// This is the `CSI < <buttons>;<col>;<row> M/m` extended
    /// form (`?1006`); modern crossterm / termion / etc. clients
    /// enable it whenever they call EnableMouseCapture. `col` /
    /// `row` are 1-based cell coordinates INSIDE the pty grid.
    /// `pressed` = trailing `M`; released = trailing `m`.
    pub fn write_sgr_mouse_report(&mut self, button_code: u32, col: u16, row: u16, pressed: bool) {
        let final_byte = if pressed { 'M' } else { 'm' };
        let bytes = format!("\x1b[<{button_code};{col};{row}{final_byte}");
        self.write_bytes(bytes.as_bytes());
    }

    /// Scroll the view `delta` lines further into the scroll-back history
    /// (negative ⇒ back toward the live bottom). libghostty's `Delta` is
    /// "up is negative", so we negate the old vt100 "+ = further back" sign.
    pub fn scroll_history(&mut self, delta: isize) {
        self.term.scroll_viewport(ScrollViewport::Delta(-delta));
    }
    /// Jump to the oldest line in scroll-back.
    pub fn scroll_to_top(&mut self) {
        self.term.scroll_viewport(ScrollViewport::Top);
    }
    /// Back to the live view (bottom).
    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_viewport(ScrollViewport::Bottom);
    }

    pub fn is_exited(&self) -> bool {
        self.exited.lock().map(|e| *e).unwrap_or(true)
    }

    pub fn bytes_processed(&self) -> u64 {
        self.bytes_seen.load(Ordering::Relaxed)
    }

    /// PID of the child process the pty is hosting (the shell or
    /// Claude or whatever). Used by the sessions-panel port
    /// scanner to discover listening TCP ports.
    pub fn pid(&self) -> Option<u32> {
        self.child.process_id()
    }

    pub fn title(&self) -> String {
        let base = self.tab_label();
        if self.is_exited() {
            format!("{base} ✗")
        } else {
            base
        }
    }

    /// The session's tab/title label. The *name* is the user-set
    /// `display_name` (right-click rename / `:rename`) → the program's
    /// OSC window title → the binary profile's label. When the session
    /// is a Claude Code instance that's thinking, the current spinner
    /// glyph is appended (`my-session ✽`) — the name stays put so the
    /// tab is still identifiable, the glyph animates frame to frame.
    ///
    /// Callers that have access to `[ui] ticket_prefixes` should prefer
    /// [`PtySession::tab_label_with_prefixes`] — it auto-fills the
    /// label from the most recent matching ticket token in scrollback
    /// when no user rename is set.
    pub fn tab_label(&self) -> String {
        self.tab_label_with_prefixes(&[])
    }

    /// Same as [`tab_label`], but when `display_name` is unset AND
    /// `prefixes` is non-empty, scans the visible scrollback for the
    /// most recent `<prefix><digits>` token (e.g. `TE-1234`) and uses
    /// it as the tab name. Falls through to OSC title / profile label
    /// when no match is found.
    pub fn tab_label_with_prefixes(&self, prefixes: &[String]) -> String {
        let osc = self.term.title().map(|s| s.to_string()).unwrap_or_default();
        let grid = self.render_grid();
        let glyph = detect_spinner_glyph(&grid);
        let screen_text = if self.display_name.is_none() && !prefixes.is_empty() {
            Some(grid_to_text(&grid))
        } else {
            None
        };

        // Priority: user rename > ticket scan > OSC title > profile.label.
        let ticket = screen_text.and_then(|t| scan_for_ticket(&t, prefixes));
        let name = if let Some(t) = ticket {
            t
        } else {
            resolve_tab_label(self.display_name.as_deref(), &osc, &self.profile.label)
        };
        match glyph {
            Some(g) => format!("{name} {g}"),
            None => name,
        }
    }
}

/// SGR mouse-report button code for a given crossterm mouse
/// button. Left = 0, Middle = 1, Right = 2.
pub fn sgr_mouse_button_code(button: ratatui::crossterm::event::MouseButton) -> u32 {
    use ratatui::crossterm::event::MouseButton;
    match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}

/// Encode the modifier bits into the SGR button field. Shift =
/// 4, Alt = 8, Ctrl = 16. Added directly to the button code.
pub fn sgr_mouse_mod_bits(mods: ratatui::crossterm::event::KeyModifiers) -> u32 {
    use ratatui::crossterm::event::KeyModifiers;
    let mut bits = 0;
    if mods.contains(KeyModifiers::SHIFT) {
        bits |= 4;
    }
    if mods.contains(KeyModifiers::ALT) {
        bits |= 8;
    }
    if mods.contains(KeyModifiers::CONTROL) {
        bits |= 16;
    }
    bits
}

/// Build a flat [`RenderGrid`] from a terminal + render state. Contains all of
/// libghostty's lending-iterator + FFI-lifetime handling in one place (shared
/// by [`PtySession::render_grid`] and the unit tests).
fn snapshot_grid<'a>(term: &Terminal<'a, 'a>, rs: &mut RenderState<'a>) -> RenderGrid {
    let cols = term.cols().unwrap_or(0);
    let mut grid = RenderGrid {
        rows: 0,
        cols,
        cells: Vec::new(),
        default_fg: RgbColor {
            r: 0xff,
            g: 0xff,
            b: 0xff,
        },
        default_bg: RgbColor { r: 0, g: 0, b: 0 },
        cursor: None,
    };

    let Ok(snapshot) = rs.update(term) else {
        return grid;
    };
    if let Ok(colors) = snapshot.colors() {
        grid.default_fg = colors.foreground;
        grid.default_bg = colors.background;
    }
    if snapshot.cursor_visible().unwrap_or(false)
        && let Ok(Some(CursorViewport { x, y, .. })) = snapshot.cursor_viewport()
    {
        grid.cursor = Some((x, y));
    }

    if let (Ok(mut rows_h), Ok(mut cells_h)) = (RowIterator::new(), CellIterator::new())
        && let Ok(mut row_iter) = rows_h.update(&snapshot)
    {
        while let Some(row) = row_iter.next() {
            let mut row_cells: Vec<RenderCell> = Vec::with_capacity(cols as usize);
            if let Ok(mut cell_iter) = cells_h.update(row) {
                while let Some(cell) = cell_iter.next() {
                    // Wide-char handling: libghostty marks the 2nd
                    // column of a CJK/emoji glyph as `SpacerTail` (or
                    // `SpacerHead` for end-of-row overflow). We push
                    // an EMPTY RenderCell for spacer slots so column
                    // alignment stays correct without painting a
                    // spurious space underneath the wide glyph. The
                    // Wide cell itself carries the multi-codepoint
                    // grapheme; the host terminal visually spans it
                    // across both columns.
                    let wide = cell.raw_cell().ok().and_then(|c| c.wide().ok());
                    if matches!(
                        wide,
                        Some(libghostty_vt::screen::CellWide::SpacerTail)
                            | Some(libghostty_vt::screen::CellWide::SpacerHead)
                    ) {
                        row_cells.push(RenderCell::default());
                        continue;
                    }
                    let text: String = cell
                        .graphemes()
                        .map(|g| g.into_iter().collect())
                        .unwrap_or_default();
                    let st = cell.style().ok();
                    row_cells.push(RenderCell {
                        text,
                        fg: cell.fg_color().ok().flatten(),
                        bg: cell.bg_color().ok().flatten(),
                        bold: st.as_ref().map(|s| s.bold).unwrap_or(false),
                        italic: st.as_ref().map(|s| s.italic).unwrap_or(false),
                        underline: st
                            .as_ref()
                            .map(|s| s.underline != Underline::None)
                            .unwrap_or(false),
                        inverse: st.as_ref().map(|s| s.inverse).unwrap_or(false),
                    });
                }
            }
            // Keep every row exactly `cols` wide so `RenderGrid::cell`'s
            // row-major indexing stays aligned.
            row_cells.resize(cols as usize, RenderCell::default());
            grid.cells.extend(row_cells);
            grid.rows += 1;
        }
    }
    // Clear libghostty's dirty bookkeeping now that we've consumed
    // the frame — the contract is "caller resets dirty after
    // rendering". Without this, snapshot.dirty() returns `Full`
    // forever and any future incremental-redraw optimisation that
    // gates on the dirty bit would always do a full walk.
    let _ = snapshot.set_dirty(libghostty_vt::render::Dirty::Clean);
    grid
}

/// Concatenate a [`RenderGrid`]'s visible cells into a plain-text string,
/// row-major with newlines between rows. Empty cells become a single space.
///
/// Used by [`scan_for_ticket`] to extract searchable text from a pty.
fn grid_to_text(grid: &RenderGrid) -> String {
    let mut text = String::with_capacity((grid.rows as usize) * (grid.cols as usize + 1));
    for r in 0..grid.rows {
        for c in 0..grid.cols {
            match grid.cell(r, c) {
                Some(cell) if !cell.text.is_empty() => text.push_str(&cell.text),
                _ => text.push(' '),
            }
        }
        text.push('\n');
    }
    text
}

/// Scan `text` for the last (rightmost) token shaped `<prefix><digits>`
/// for any prefix in `prefixes`. Returns the matched token (e.g.
/// `"TE-1234"`) or `None` if no match.
///
/// "Last match" is by character position in the input — the visible
/// pty grid is row-major top-to-bottom, so the last match is the most
/// recently rendered line (most recent in the user's conversation).
///
/// Pure — unit-tested.
pub(crate) fn scan_for_ticket(text: &str, prefixes: &[String]) -> Option<String> {
    if prefixes.is_empty() {
        return None;
    }
    let mut best: Option<(usize, String)> = None;
    for prefix in prefixes {
        if prefix.is_empty() {
            continue;
        }
        let bytes = text.as_bytes();
        let pbytes = prefix.as_bytes();
        let mut i = 0;
        while i + pbytes.len() <= bytes.len() {
            if &bytes[i..i + pbytes.len()] == pbytes {
                // Count contiguous ASCII digits after the prefix.
                let mut j = i + pbytes.len();
                let start_digits = j;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                if j > start_digits {
                    let token = format!("{prefix}{}", &text[start_digits..j]);
                    if best.as_ref().map(|(p, _)| i > *p).unwrap_or(true) {
                        best = Some((i, token));
                    }
                    i = j;
                    continue;
                }
            }
            i += 1;
        }
    }
    best.map(|(_, t)| t)
}

/// Pick a pty session's tab *name* from the candidate sources, in
/// priority order: an explicit user-set name, the program's OSC window
/// title, then the binary profile's default label. Blank candidates
/// are skipped. The thinking-spinner glyph is layered on by the caller
/// ([`PtySession::tab_label`]) — it's not a name. Pure — unit-tested.
pub(crate) fn resolve_tab_label(
    display_name: Option<&str>,
    osc_title: &str,
    profile_label: &str,
) -> String {
    for cand in [display_name, Some(osc_title)].into_iter().flatten() {
        let cand = cand.trim();
        if !cand.is_empty() {
            return cand.to_string();
        }
    }
    profile_label.to_string()
}

/// Scan a pty screen for a Claude-Code-style spinner — a row carrying
/// *both* a spinner glyph and an ellipsis (e.g. `✽ Wandering…`).
/// Returns the *current* glyph; Claude cycles it frame to frame, so a
/// caller that appends it to the tab label gets a live animation while
/// keeping the session name. `None` when no such line is visible —
/// Heuristic: is this `BinaryProfile.exe` a shell program (`bash`,
/// `zsh`, `fish`, `sh`, …) for which the themed prompt env vars are
/// meaningful? AI CLIs (claude, codex) and one-shot tools render their
/// own UI and shouldn't get a shell-style PS1 injected.
fn is_shell_profile(exe: &str) -> bool {
    let base = std::path::Path::new(exe)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(exe);
    matches!(
        base,
        "sh" | "bash" | "zsh" | "fish" | "dash" | "ksh" | "tcsh"
    )
}

/// Claude idle, or a non-Claude program. The two-signal (glyph +
/// ellipsis) test rejects unrelated lines that merely contain a star.
/// Bottom-up scan: Claude's spinner sits near the input prompt.
fn detect_spinner_glyph(grid: &RenderGrid) -> Option<char> {
    const SPINNER_CHARS: &[char] = &[
        '✱', '✶', '✦', '✧', '⋆', '✽', '✻', '❋', '✿', '✺', '✷', '✸', '✹', '❉', '❅', '◐', '◓', '◑',
        '◒',
    ];
    for row in (0..grid.rows).rev() {
        let mut line = String::new();
        for col in 0..grid.cols {
            if let Some(c) = grid.cell(row, col) {
                line.push_str(&c.text);
            }
        }
        let Some(glyph) = line.chars().find(|c| SPINNER_CHARS.contains(c)) else {
            continue;
        };
        if line.contains('…') || line.contains("...") {
            return Some(glyph);
        }
    }
    None
}

impl Drop for PtySession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        if let Some(j) = self.reader.take() {
            let _ = j.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_tab_label_prefers_name_then_osc_then_profile() {
        // An explicit user name wins.
        assert_eq!(resolve_tab_label(Some("mine"), "osc", "Claude"), "mine");
        // No user name → the program's OSC window title.
        assert_eq!(
            resolve_tab_label(None, "Claude · refactor", "Claude"),
            "Claude · refactor"
        );
        // Nothing set → the binary profile's label.
        assert_eq!(resolve_tab_label(None, "", "Claude"), "Claude");
        assert_eq!(resolve_tab_label(None, "   ", "Codex"), "Codex");
        // Blank candidates are skipped.
        assert_eq!(resolve_tab_label(Some(" "), "osc", "Codex"), "osc");
    }

    fn p(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn scan_for_ticket_empty_prefixes_returns_none() {
        assert_eq!(scan_for_ticket("TE-1234 mentioned here", &[]), None);
    }

    #[test]
    fn scan_for_ticket_no_match_returns_none() {
        let prefixes = [p("TE-"), p("MIX-")];
        assert_eq!(
            scan_for_ticket("nothing ticket-shaped here", &prefixes),
            None
        );
        // Prefix without trailing digits doesn't match.
        assert_eq!(scan_for_ticket("we use TE- for tickets", &prefixes), None);
    }

    #[test]
    fn scan_for_ticket_single_match() {
        let prefixes = [p("TE-")];
        assert_eq!(
            scan_for_ticket("we just shipped TE-1234 yesterday", &prefixes),
            Some("TE-1234".to_string())
        );
    }

    #[test]
    fn scan_for_ticket_multiple_matches_returns_last_in_text() {
        // The screen renders top-to-bottom row-major; the rightmost
        // match in the joined text is the most recently rendered line.
        let prefixes = [p("TE-")];
        let txt =
            "TE-100 was an early one\nthen later TE-9999 came along\nand most recent TE-12345 wins";
        assert_eq!(
            scan_for_ticket(txt, &prefixes),
            Some("TE-12345".to_string())
        );
    }

    #[test]
    fn scan_for_ticket_multiple_prefixes_returns_globally_rightmost() {
        // With multiple prefixes configured, the GLOBALLY rightmost
        // match wins — regardless of which prefix it matched.
        let prefixes = [p("TE-"), p("MIX-"), p("PROJ-")];
        let txt = "earlier we discussed PROJ-77 then MIX-123 then TE-5";
        assert_eq!(scan_for_ticket(txt, &prefixes), Some("TE-5".to_string()));
    }

    #[test]
    fn scan_for_ticket_ignores_empty_prefix_strings() {
        // An empty prefix would match every byte boundary — defensive
        // skip in scan_for_ticket. Empty prefixes are filtered at
        // config load time too, but the function shouldn't trip on a
        // malformed input.
        let prefixes = [p(""), p("TE-")];
        assert_eq!(
            scan_for_ticket("see TE-1 for details", &prefixes),
            Some("TE-1".to_string())
        );
    }

    #[test]
    fn scan_for_ticket_handles_prefix_at_end_without_digits() {
        // Don't match `TE-` with nothing after it (the chat ended
        // mid-thought).
        let prefixes = [p("TE-")];
        assert_eq!(scan_for_ticket("incomplete TE-", &prefixes), None);
    }

    #[test]
    fn scan_for_ticket_handles_digits_with_non_digit_after() {
        // Match the digit run, then the trailing characters are
        // irrelevant.
        let prefixes = [p("TE-")];
        assert_eq!(
            scan_for_ticket("see TE-1234. it's done", &prefixes),
            Some("TE-1234".to_string())
        );
    }

    #[test]
    fn scan_for_ticket_does_not_include_letters_in_digit_run() {
        // `TE-1234x` is NOT a valid ticket — the `x` breaks the digit
        // run. Match is just the digit prefix.
        let prefixes = [p("TE-")];
        assert_eq!(
            scan_for_ticket("misformed TE-1234x reference", &prefixes),
            Some("TE-1234".to_string())
        );
    }

    /// Build a [`RenderGrid`] by feeding `chunks` to a fresh libghostty
    /// terminal — the unit-test stand-in for a live pty.
    fn test_grid(rows: u16, cols: u16, chunks: &[&[u8]]) -> RenderGrid {
        let mut term = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: 0,
        })
        .unwrap();
        for c in chunks {
            term.vt_write(c);
        }
        let mut rs = RenderState::new().unwrap();
        snapshot_grid(&term, &mut rs)
    }

    #[test]
    fn grid_to_text_round_trip() {
        // Sanity-check that grid_to_text + scan_for_ticket compose correctly
        // through a real libghostty grid.
        let grid = test_grid(
            10,
            60,
            &[
                b"first line\r\n",
                b"mentioned TE-42 in passing\r\n",
                b"then TE-99 came up\r\n",
            ],
        );
        let text = grid_to_text(&grid);
        let prefixes = [p("TE-")];
        assert_eq!(scan_for_ticket(&text, &prefixes), Some("TE-99".to_string()));
    }

    #[test]
    fn detect_spinner_glyph_finds_claude_spinner() {
        let grid = test_grid(
            6,
            60,
            &[
                b"idle output line\r\n",
                "✽ Wandering… (3s · esc to interrupt)\r\n".as_bytes(),
            ],
        );
        assert_eq!(detect_spinner_glyph(&grid), Some('✽'));
    }

    #[test]
    fn detect_spinner_glyph_none_without_a_spinner() {
        let grid = test_grid(6, 60, &[b"just some normal output\r\nno spinner here\r\n"]);
        assert!(detect_spinner_glyph(&grid).is_none());
        // A spinner glyph but no ellipsis → rejected (two-signal combo).
        let grid2 = test_grid(6, 60, &["✽ a starred heading\r\n".as_bytes()]);
        assert!(detect_spinner_glyph(&grid2).is_none());
    }

    #[test]
    fn shell_profile_uses_env_shell() {
        // Don't actually mutate the process env (parallel tests) — just check the
        // shape of a constructed profile against whatever $SHELL is.
        let p = BinaryProfile::shell(None);
        assert!(!p.exe.is_empty());
        assert!(p.label.starts_with("terminal ("));
        assert!(p.args.is_empty());
    }

    #[test]
    fn claude_profile_injects_claude_md_when_present() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".mnml")).unwrap();
        std::fs::write(dir.path().join(".mnml/CLAUDE.md"), "# brief\nhello mnml").unwrap();
        let p = BinaryProfile::claude_code(dir.path().to_path_buf());
        assert_eq!(p.exe, "claude");
        let i = p
            .args
            .iter()
            .position(|a| a == "--append-system-prompt")
            .expect("flag");
        assert!(p.args[i + 1].contains("hello mnml"));

        // And skips it when absent.
        let dir2 = tempfile::tempdir().unwrap();
        let p2 = BinaryProfile::claude_code(dir2.path().to_path_buf());
        assert!(!p2.args.iter().any(|a| a == "--append-system-prompt"));
    }

    #[test]
    fn spawns_a_short_shell_command_and_reaps() {
        // Spawn `sh -c 'exit 0'`-ish via a profile so we exercise the pty path.
        let mut prof = BinaryProfile::shell(None);
        prof.exe = "/bin/sh".to_string();
        prof.args = vec!["-c".to_string(), "true".to_string()];
        let Ok(s) = PtySession::spawn(prof, 24, 80) else {
            // CI without a pty — skip rather than fail.
            return;
        };
        // Give the child a moment to exit; the reader sets `exited` on EOF.
        for _ in 0..50 {
            if s.is_exited() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        // Dropping joins the reader thread without hanging.
        drop(s);
    }
}
