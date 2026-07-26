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
/// 2026-07-26 — Clone added for the per-session render cache.
#[derive(Clone)]
pub struct RenderGrid {
    pub rows: u16,
    pub cols: u16,
    /// Row-major, `rows * cols` cells.
    pub cells: Vec<RenderCell>,
    pub default_fg: RgbColor,
    pub default_bg: RgbColor,
    /// `(col, row)` of the cursor when visible + in the live viewport.
    pub cursor: Option<(u16, u16)>,
    /// #17 — libghostty's ANSI 16 palette (indices 0-15). Snapshotted
    /// from `snapshot.colors().palette[0..16]` so `cell_style` can
    /// detect when a cell's RGB matches one of these and swap for
    /// the mnml theme's equivalent color. Empty = "no remapping"
    /// (test cases + fallback).
    pub ansi_palette: [Option<RgbColor>; 16],
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

/// Look up the per-workspace launcher override for a built-in
/// integration. Reads `<workspace>/.mnml/integrations/<id>.toml`
/// for a `launcher = "..."` line; returns that path if present,
/// otherwise `default_exe`. Intentionally hand-scraped to avoid
/// pulling a TOML parser into the hot spawn path — the file only
/// ever has one field.
///
/// The right-click "Set launcher script…" writes this file; users
/// can also hand-edit it. Empty launcher / missing file = default.
pub fn resolve_launcher(workspace: &std::path::Path, id: &str, default_exe: &str) -> String {
    let path = workspace
        .join(".mnml")
        .join("integrations")
        .join(format!("{id}.toml"));
    let Ok(text) = std::fs::read_to_string(&path) else {
        return default_exe.to_string();
    };
    for line in text.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix("launcher") {
            let rest = rest.trim_start();
            let Some(rest) = rest.strip_prefix('=') else {
                continue;
            };
            let rest = rest.trim();
            if let Some(inner) = rest.strip_prefix('"')
                && let Some(end) = inner.find('"')
            {
                let val = &inner[..end];
                if !val.is_empty() {
                    return val.to_string();
                }
            }
        }
    }
    default_exe.to_string()
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
    /// The `IntegrationIcon.id` this pane was launched from
    /// ("btop" / "amplify" / "bitbucket_pipelines" / …). Set by the
    /// chip-click dispatcher; `None` for shells and any other pane
    /// not tied to a rail integration. The tab-icon resolver in
    /// `ui::mod::pty_icon` prefers this over label-based matching
    /// so the glyph is a deterministic lookup, not a substring
    /// guess. tree-redesign 2026-07-19 — user asked for
    /// "predictable and deterministic" tab glyph matching.
    pub integration_id: Option<String>,
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
            integration_id: None,
        }
    }

    /// `claude` (Claude Code), with a known `--session-id` (so mnml can mirror the
    /// transcript). If the workspace has a `.mnml/CLAUDE.md`, inject it via
    /// `--append-system-prompt` so the assistant orients before message #1.
    ///
    /// The exe defaults to `claude` on PATH; a per-workspace override at
    /// `<workspace>/.mnml/integrations/claude_code.toml` (set via the chip
    /// right-click "Set launcher script…") replaces it — useful for wrapper
    /// scripts like `./bin/claude-multi.sh` that add `--add-dir` flags.
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
        let exe = resolve_launcher(&workspace, "claude_code", "claude");
        BinaryProfile {
            label: "Claude Code".to_string(),
            exe,
            args,
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(sid),
            integration_id: Some("claude_code".to_string()),
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
        let exe = resolve_launcher(&workspace, "claude_code", "claude");
        BinaryProfile {
            label: "Claude Code (resumed)".to_string(),
            exe,
            args: vec!["--resume".to_string(), session_id.clone()],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(session_id),
            integration_id: Some("claude_code".to_string()),
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
            integration_id: None,
        }
    }

    /// `codex` (OpenAI Codex CLI). Same launcher-override story as
    /// `claude_code` — a workspace can point at a wrapper script via
    /// `<workspace>/.mnml/integrations/codex.toml`.
    pub fn codex(workspace: PathBuf) -> Self {
        let exe = resolve_launcher(&workspace, "codex", "codex");
        BinaryProfile {
            label: "Codex".to_string(),
            exe,
            args: Vec::new(),
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
            integration_id: Some("codex".to_string()),
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
            integration_id: Some("mixr".to_string()),
        }
    }

    /// Chainable setter — stamp an `IntegrationIcon.id` onto a
    /// profile built by `task()` (used by the rail-chip click
    /// dispatcher). Returns `self` so `BinaryProfile::task(...)
    /// .with_integration("btop")` reads left-to-right.
    /// tree-redesign 2026-07-19.
    pub fn with_integration(mut self, id: impl Into<String>) -> Self {
        self.integration_id = Some(id.into());
        self
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
    /// 2026-07-26 — render-grid cache. `render_grid()` is called
    /// once per visible pane per frame (25 FPS while any pty is
    /// open); each call runs a full libghostty-vt snapshot + copy
    /// of the whole terminal grid. For an 80×50 pane that's 4K
    /// cell allocations per frame per pane — with 5+ panes it
    /// dominates the frame budget even when the pty produced zero
    /// output.
    ///
    /// Cache is invalidated when `bytes_processed()` moves OR the
    /// rendered size changes. Wrapped in RefCell so the &self
    /// render_grid can update it.
    render_cache: RefCell<Option<RenderCache>>,
}

/// 2026-07-26 — cached snapshot invalidation key + payload.
struct RenderCache {
    /// bytes_processed() at snapshot time. Mismatch = pty has new
    /// output → recompute.
    bytes_at_snapshot: u64,
    /// (rows, cols) at snapshot time. Mismatch = resize → recompute.
    size: (u16, u16),
    grid: RenderGrid,
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
        // ncurses tools (iftop / htop / less / vim) fail with "Error
        // opening terminal: xterm-ghostty" when Ghostty's terminfo
        // isn't installed system-wide (stock macOS/Linux ncurses
        // packages don't ship it). Ghostty bundles its own compiled
        // terminfo in the .app bundle; prepend it to `TERMINFO_DIRS`
        // so children resolve `TERM=xterm-ghostty` correctly without
        // us having to touch TERM or COLORTERM. No feature loss for
        // Ghostty-aware apps.
        if let Some(dirs) = terminfo_search_dirs() {
            cmd.env("TERMINFO_DIRS", dirs);
        }
        // 2026-07-20 — stamp `MNML_PANE=1` on every Pty child so
        // siblings can detect they're running inside mnml and
        // adjust their chrome (drop border block, since mnml
        // already draws pane borders). User asked for this on
        // amplify + bitbucket panes so the in-mnml view is flush.
        cmd.env("MNML_PANE", "1");
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
            render_cache: RefCell::new(None),
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
        // 2026-07-26 — cache-hit path. When the pty has produced
        // zero new bytes since last snapshot AND the pane size
        // hasn't changed, return the cached grid. Eliminates the
        // per-frame full-terminal snapshot cost when idle pty
        // panes are on-screen (which was O(N_panes × 4000 cells)
        // per frame at 25 FPS).
        let now_bytes = self.bytes_processed();
        let size = self.last_size;
        {
            let cache = self.render_cache.borrow();
            if let Some(c) = cache.as_ref()
                && c.bytes_at_snapshot == now_bytes
                && c.size == size
            {
                return c.grid.clone();
            }
        }
        let grid = snapshot_grid(&self.term, &mut self.render_state.borrow_mut());
        *self.render_cache.borrow_mut() = Some(RenderCache {
            bytes_at_snapshot: now_bytes,
            size,
            grid: grid.clone(),
        });
        grid
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
    /// OSC window title → the binary profile's label. The thinking
    /// spinner used to be appended here (`my-session ✽`); that made
    /// the tab read as "airplane star Claude Code ✻ $ ×" — three
    /// icons where the user wanted one. The spinner now animates
    /// the LEADING pane icon via [`current_spinner_glyph`], so the
    /// label stays clean.
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
        let screen_text = if self.display_name.is_none() && !prefixes.is_empty() {
            let grid = self.render_grid();
            Some(grid_to_text(&grid))
        } else {
            None
        };

        // Priority: user rename > ticket scan > OSC title > profile.label.
        let ticket = screen_text.and_then(|t| scan_for_ticket(&t, prefixes));
        if let Some(t) = ticket {
            t
        } else {
            resolve_tab_label(self.display_name.as_deref(), &osc, &self.profile.label)
        }
    }

    /// The current thinking-spinner glyph, if this session's rendered
    /// output shows one. Bufferline uses this to animate the LEADING
    /// pane icon — the same slot the static integration glyph
    /// occupies when idle — so the tab reads as one icon + one label.
    ///
    /// 2026-07-18 v3 — empirically-measured Claude Code v2.1.214
    /// spinner. Extracted @anthropic-ai/claude-code, ran it against
    /// a slow-thinking prompt in a pty, timestamped 45s of on-screen
    /// ornament-char emissions:
    ///
    /// - 8-frame palindromic sequence: `✳ ✢ ✳ ✶ ✻ ✽ ✻ ✶`.
    ///   Star EXPANDS `✳→✢→✳→✶→✻→✽` then CONTRACTS `✽→✻→✶→✳`.
    ///   Distinctive "breathing" feel — the asymmetry-around-symmetry
    ///   is what makes Claude Code's animation recognizable vs a
    ///   generic `✻→✽→✻→✱` rotation.
    /// - Frame rate: measured median 109ms → 110ms per frame,
    ///   total cycle ~880ms.
    /// - Codepoints: U+2733 ✳ · U+2722 ✢ · U+2736 ✶ · U+273B ✻ ·
    ///   U+273D ✽.
    /// - Idle char (`current_spinner_glyph` returns None): mnml
    ///   uses the SAME `✳` (U+2733) as its static brand mark — matches
    ///   Claude Code's own idle glyph.
    ///
    /// Not just "some chars that look about right" — this is the
    /// actual sequence, in the actual order, at the actual rate that
    /// Claude Code prints. The tab animation should feel identical
    /// to what the user sees in Claude Code's own pane.
    pub fn current_spinner_glyph(&self) -> Option<char> {
        // 2026-07-18 v6 — user report after the tab overhaul: "the
        // animation no longer matches the prompt one, its animating
        // from asterisk to big orange dot."
        //
        // v5 grid-sampled every frame, returning `None` whenever
        // the spinner row wasn't visible in the grid at that
        // instant (between-frame gap, momentary redraw). `pty_icon`
        // then fell back to the STATIC branded Claude Code glyph
        // for that frame — the "big orange dot" — flickering
        // between spinner char and static icon.
        //
        // Restore the empirically-measured palindromic timer (v3)
        // but gate it on `is_claude_thinking(grid)` — a robust
        // detector that only requires a bottom-region row starting
        // with a known Claude spinner char and ending with `…`.
        // Timer animation eliminates the None-flicker; the phase
        // won't be locked to Claude's clock, but the sequence,
        // rate, and character set are Claude's own so the tab
        // reads as an in-family mirror.
        if !is_claude_thinking(&self.render_grid()) {
            return None;
        }
        const CYCLE_MS: u128 = 110;
        const CLAUDE_FRAMES: &[char] = &['✳', '✢', '✳', '✶', '✻', '✽', '✻', '✶'];
        static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
        let start = START.get_or_init(std::time::Instant::now);
        let ms = std::time::Instant::now().duration_since(*start).as_millis();
        let idx = (ms / CYCLE_MS) as usize % CLAUDE_FRAMES.len();
        Some(CLAUDE_FRAMES[idx])
    }

    /// True if Codex is currently in a thinking/working state.
    /// Codex's animation is a color shimmer on a static `•` (the
    /// character never changes), so `current_spinner_glyph` returns
    /// None even when it's active. Detect via a co-signal: `•`
    /// present in the bottom rows AND a "Working" label or an
    /// elapsed-time token like `12s` / `1m 32s`.
    pub fn is_codex_thinking(&self) -> bool {
        detect_codex_thinking(&self.render_grid())
    }

    /// One-line summary of what the session is currently doing —
    /// shown as row 3 in the Sessions panel. Preference order:
    ///
    ///   1. Claude's `<glyph> Verb… (…s ·…)` status line if visible.
    ///   2. Any non-chrome line near the bottom of the grid.
    ///
    /// Returns `None` when nothing meaningful is on screen (fresh
    /// pane, cleared terminal). The caller is responsible for
    /// truncating to fit its row.
    pub fn session_summary(&self) -> Option<String> {
        summarize_grid(&self.render_grid())
    }

    /// Up to `max` lines of grid content for the Sessions-panel
    /// hover tooltip — same filters as `session_summary` (no
    /// footer chips, no input prompt, no chrome), but returns
    /// several lines so the tooltip reads as "what's on this
    /// pane's screen right now" rather than a bare one-liner.
    /// Most-recent-first (bottom-of-grid → top).
    pub fn session_summary_lines(&self, max: usize) -> Vec<String> {
        summarize_grid_lines(&self.render_grid(), max)
    }
}

/// Flatten a single grid row to a plain string, using a space
/// for cells whose `text` is empty (styled blanks). Without this,
/// two adjacent styled runs with an empty spacer cell between
/// them (e.g. `"auto mode"` `" "` `"on"`) render as `"automodeon"`
/// — which broke `is_footer_chip` matching after a user report:
/// row 2 read `"automodeon (shift+tabtocycle)·↵foragents"` even
/// with the footer-chip filter in place.
fn row_to_string(grid: &RenderGrid, row: u16) -> String {
    let mut line = String::new();
    for col in 0..grid.cols {
        if let Some(c) = grid.cell(row, col) {
            if c.text.is_empty() {
                line.push(' ');
            } else {
                line.push_str(&c.text);
            }
        }
    }
    line
}

fn summarize_grid(grid: &RenderGrid) -> Option<String> {
    let mut activity: Option<String> = None;
    let mut fallback: Option<String> = None;
    // Bottom-up scan — the latest content and the status line both
    // live near the bottom.
    for row in (0..grid.rows).rev() {
        let line = row_to_string(grid, row);
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Skip lines that are just repeated single characters (box
        // borders, separators) — those are chrome, not content.
        if is_chrome_line(trimmed) {
            continue;
        }
        // Skip Claude Code's persistent footer chips — "auto mode
        // on (shift+tab to cycle)", "↵ for agents", etc. Those
        // never carry per-session context; they're always visible
        // at the bottom of the pty.
        if is_footer_chip(trimmed) {
            continue;
        }
        // Skip the pending-input prompt row — `) ...` or `> ...`.
        // If the user is typing, that's not a session summary;
        // if they haven't typed, it's blank chrome.
        if is_input_prompt(trimmed) {
            continue;
        }
        // Claude Code's activity line: `<glyph> <Verb>` optionally
        // followed by an ellipsis or a `for Ns` duration. Recognise
        // either shape so we still catch it when the ellipsis has
        // fallen off between animation frames.
        if activity.is_none() && looks_like_activity_line(trimmed) {
            let cleaned = strip_leading_spinner_chars(trimmed).trim().to_string();
            if !cleaned.is_empty() {
                activity = Some(cleaned);
            }
        }
        if fallback.is_none() {
            let cleaned = strip_leading_spinner_chars(trimmed).trim().to_string();
            if cleaned.chars().count() >= 3 {
                fallback = Some(cleaned);
            }
        }
        if activity.is_some() {
            break;
        }
    }
    activity.or(fallback)
}

fn summarize_grid_lines(grid: &RenderGrid, max: usize) -> Vec<String> {
    if max == 0 {
        return Vec::new();
    }
    // Two-pass:
    //   1. Collect every dim (low-contrast) content line — those
    //      are Claude Code's session-summary chips above the
    //      composer. Highest signal-to-noise.
    //   2. Fill remaining slots with plain content lines,
    //      bottom-up.
    // Dedup across passes so a line that qualifies as both dim
    // AND recent isn't emitted twice.
    let mut dim_hits: Vec<(u16, String)> = Vec::new();
    let mut plain_hits: Vec<(u16, String)> = Vec::new();
    for row in (0..grid.rows).rev() {
        let line = row_to_string(grid, row);
        let trimmed = line.trim();
        if trimmed.is_empty()
            || is_chrome_line(trimmed)
            || is_footer_chip(trimmed)
            || is_input_prompt(trimmed)
            || is_worked_completion(trimmed)
        {
            continue;
        }
        let cleaned = strip_leading_spinner_chars(trimmed).trim().to_string();
        if cleaned.chars().count() < 3 {
            continue;
        }
        if is_dim_row(grid, row) {
            dim_hits.push((row, cleaned));
        } else {
            plain_hits.push((row, cleaned));
        }
    }
    let mut out: Vec<String> = Vec::with_capacity(max);
    let mut seen_rows: std::collections::HashSet<u16> = std::collections::HashSet::new();
    for (row, text) in dim_hits.into_iter().chain(plain_hits) {
        if !seen_rows.insert(row) {
            continue;
        }
        if out.last().map(|s| s == &text).unwrap_or(false) {
            continue;
        }
        out.push(text);
        if out.len() >= max {
            break;
        }
    }
    out
}

fn is_chrome_line(s: &str) -> bool {
    let chars: Vec<char> = s.chars().collect();
    if chars.is_empty() {
        return true;
    }
    // All the same non-alphanumeric char → separator/border.
    let first = chars[0];
    if !first.is_alphanumeric() && chars.iter().all(|&c| c == first || c.is_whitespace()) {
        return true;
    }
    false
}

/// Claude Code paints `<spinner> Worked for Ns` as a completion
/// summary when a turn finishes. It's structurally identical to
/// the in-progress "Sautéed for 27s" indicator but conveys no
/// per-session context — you just get "yes, it did something" —
/// so treat it as chrome and hide from the sessions summary.
/// User report 2026-07-18: "im not sure if showing ✻ Worked for
/// 30s is very helpful."
fn is_worked_completion(s: &str) -> bool {
    let cleaned = strip_leading_spinner_chars(s).trim();
    if !cleaned.starts_with("Worked for ") && !cleaned.starts_with("worked for ") {
        return false;
    }
    // Bounded — anything longer is unlikely to be Claude's
    // completion chip and might be prose that starts with "Worked
    // for the last 5 years at ...".
    cleaned.chars().count() < 30
}

/// Detect whether a grid row is rendered noticeably dimmer than
/// the terminal's default foreground. Claude Code uses a
/// low-contrast style for its "session summary" line just above
/// the prompt — that's the row we want to surface as the primary
/// summary when the pane is at rest. User: "claude code adds a
/// little summary sometimes in darker text and they put it above
/// the prompt. pretty helpful sometimes when there is a lot
/// going on."
fn is_dim_row(grid: &RenderGrid, row: u16) -> bool {
    // Reference brightness — 60% of the default fg.
    let default_bright =
        grid.default_fg.r as u32 + grid.default_fg.g as u32 + grid.default_fg.b as u32;
    if default_bright == 0 {
        return false;
    }
    let threshold = (default_bright * 3) / 5;
    let mut total = 0u32;
    let mut dim = 0u32;
    for col in 0..grid.cols {
        let Some(cell) = grid.cell(row, col) else {
            continue;
        };
        if cell.text.is_empty() || cell.text.chars().all(|c| c.is_whitespace()) {
            continue;
        }
        total += 1;
        let Some(fg) = cell.fg else {
            continue;
        };
        let b = fg.r as u32 + fg.g as u32 + fg.b as u32;
        if b < threshold {
            dim += 1;
        }
    }
    // Need enough cells to be confident + a clear supermajority
    // (≥ 60%) of them noticeably dim. Guards against a stray
    // syntax-colored keyword tripping the check.
    total >= 4 && dim * 5 >= total * 3
}

/// Recognise Claude Code's persistent bottom-of-screen footer
/// chips — text that's always visible regardless of what the
/// session is doing, so it never belongs in a session summary.
fn is_footer_chip(s: &str) -> bool {
    // Casefold once; every marker below is ASCII-lowercased.
    let lower = s.to_ascii_lowercase();
    const MARKERS: &[&str] = &[
        "auto mode",
        "manual mode",
        "plan mode",
        "shift+tab to cycle",
        "shift+tab to change",
        "for agents",
        "for approval",
        "for planning",
        "for accept",
        "for accept edits",
        "for tools",
        "for interrupt",
        "esc to interrupt",
        "esc to close",
        "esc to cancel",
        "tab to amend",
        "for compact",
        "context left until auto-compact",
        "context left",
        "shortcuts",
        // Startup-banner "action needed" line — the user was
        // seeing this leak through as row 4 of the card. It's
        // persistent chrome, not per-session context.
        "mcp server needs authentication",
        "mcp servers need authentication",
        "run /mcp",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

/// Row starts with a pending-input marker (`>` or `)`) — Claude
/// Code's / mnml's composer prompt. Either blank chrome or an
/// in-progress edit — not a summary.
fn is_input_prompt(s: &str) -> bool {
    let first = match s.chars().next() {
        Some(c) => c,
        None => return false,
    };
    matches!(first, '>' | ')' | '❯')
}

/// True if this line looks like Claude Code's activity indicator —
/// `<spinner-glyph> <Verb>` followed by either an ellipsis or a
/// `for Ns` / `for Nm` / `for Nh` duration token. Tolerant of the
/// ellipsis disappearing between animation frames.
fn looks_like_activity_line(s: &str) -> bool {
    if s.contains('…') || s.contains("...") {
        return true;
    }
    // Any " for <digits><s|m|h>" token near the end reads as an
    // activity duration (e.g. "Sautéed for 27s"). Only accept
    // this when the line is short — a real Claude activity line is
    // ~30 chars; body prose containing "…for 5s…" incidentally
    // wouldn't match this filter.
    if s.chars().count() > 60 {
        return false;
    }
    let bytes = s.as_bytes();
    if let Some(pos) = s.find(" for ") {
        let mut i = pos + 5;
        let mut saw_digit = false;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            saw_digit = true;
            i += 1;
        }
        if saw_digit && i < bytes.len() && matches!(bytes[i], b's' | b'm' | b'h') {
            return true;
        }
    }
    false
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
/// Convert a `ratatui::style::Color` to a libghostty `RgbColor`.
/// mnml themes are always RGB in practice; non-RGB variants fall
/// back to a sensible default (white for fg-ish, black for bg-ish).
fn theme_color_to_rgb(c: ratatui::style::Color) -> RgbColor {
    if let ratatui::style::Color::Rgb(r, g, b) = c {
        RgbColor { r, g, b }
    } else {
        RgbColor {
            r: 0xff,
            g: 0xff,
            b: 0xff,
        }
    }
}

/// by [`PtySession::render_grid`] and the unit tests).
fn snapshot_grid<'a>(term: &Terminal<'a, 'a>, rs: &mut RenderState<'a>) -> RenderGrid {
    let cols = term.cols().unwrap_or(0);
    // Pull defaults from the active mnml theme so uncolored terminal
    // text blends with the editor color scheme instead of the
    // libghostty white-on-black default (#17). Falls back to
    // white-on-black when the theme's fg/bg aren't RGB (shouldn't
    // happen — theme palette is always RGB — but safe).
    let t = crate::ui::theme::cur();
    let (default_fg, default_bg) = (theme_color_to_rgb(t.fg), theme_color_to_rgb(t.bg_dark));
    let mut grid = RenderGrid {
        rows: 0,
        cols,
        cells: Vec::new(),
        default_fg,
        default_bg,
        cursor: None,
        ansi_palette: [None; 16],
    };

    let Ok(snapshot) = rs.update(term) else {
        return grid;
    };
    if let Ok(colors) = snapshot.colors() {
        grid.default_fg = colors.foreground;
        grid.default_bg = colors.background;
        for (i, slot) in grid.ansi_palette.iter_mut().enumerate() {
            *slot = Some(colors.palette[i]);
        }
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
/// Build a `TERMINFO_DIRS` value that includes every terminfo
/// directory a child pty might need. Prepends bundled locations
/// (Ghostty.app on macOS, `/usr/local/share/terminfo` where users
/// often drop custom entries) to the parent's `$TERMINFO_DIRS`
/// (or the ncurses defaults if unset). Returns `None` when the
/// resulting list is empty — caller then skips the env override
/// so ncurses uses its compiled-in defaults.
fn terminfo_search_dirs() -> Option<String> {
    let mut dirs: Vec<String> = Vec::new();
    #[cfg(target_os = "macos")]
    {
        let ghostty = "/Applications/Ghostty.app/Contents/Resources/terminfo";
        if std::path::Path::new(ghostty).is_dir() {
            dirs.push(ghostty.to_string());
        }
    }
    for extra in ["/usr/local/share/terminfo", "/opt/homebrew/share/terminfo"] {
        if std::path::Path::new(extra).is_dir() {
            dirs.push(extra.to_string());
        }
    }
    let inherited = std::env::var("TERMINFO_DIRS").unwrap_or_default();
    if !inherited.is_empty() {
        dirs.push(inherited);
    } else {
        // ncurses defaults so we don't shadow the system terminfo db.
        for def in ["/usr/share/terminfo", "/etc/terminfo", "/lib/terminfo"] {
            if std::path::Path::new(def).is_dir() {
                dirs.push(def.to_string());
            }
        }
    }
    if dirs.is_empty() {
        None
    } else {
        Some(dirs.join(":"))
    }
}

/// ([`PtySession::tab_label`]) — it's not a name. Pure — unit-tested.
pub(crate) fn resolve_tab_label(
    display_name: Option<&str>,
    osc_title: &str,
    profile_label: &str,
) -> String {
    for cand in [display_name, Some(osc_title)].into_iter().flatten() {
        let cleaned = strip_leading_spinner_chars(cand.trim());
        if !cleaned.is_empty() {
            return cleaned.to_string();
        }
    }
    profile_label.to_string()
}

/// Claude Code (and some other AI CLIs) set their OSC window title
/// to `"✻ Claude Code"` — with the CURRENT frame of their thinking
/// spinner as the leading character. That worked fine as a terminal
/// window title but read as "SVG_icon * Claude Code" in mnml's tab
/// (icon slot + spinner-prefix in the label) — the user saw two
/// icons for one pane. Strip leading non-alphanumeric decorative
/// chars so the tab label reads as just the name.
///
/// 2026-07-18 second pass — the char-set enumeration was fragile
/// (Claude Code's spinner cycles through 20+ Unicode ornament stars;
/// listing them all is a maintenance liability). Widen to "any
/// leading char that isn't an ASCII/Unicode word char, `[`, `(`, or
/// `<`" — those brackets are the only non-alpha starters a legit
/// tab title would use. Everything else gets shed until we reach a
/// word char.
pub(crate) fn strip_leading_spinner_chars(s: &str) -> &str {
    // Find the byte-offset of the first char that could plausibly
    // start a real tab title.
    let cutoff = s
        .char_indices()
        .find(|(_, c)| c.is_alphanumeric() || matches!(*c, '(' | '[' | '<' | '"' | '\''))
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    s[cutoff..].trim_start()
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
/// Scan the pty grid's bottom rows for signs Codex is working.
/// Codex's status widget prints `•` + an elapsed-time counter
/// (`12s`, `1m 32s`, `1h 03m 09s`) and often the word "Working".
/// Either combination of `•` + elapsed-time-shape OR `•` + "Working"
/// is a strong-enough signal that a bare `•` in a comment/README
/// wouldn't false-positive. Only the last 4 rows are scanned since
/// Codex's status widget lives at the bottom of the composer.
fn detect_codex_thinking(grid: &RenderGrid) -> bool {
    let scan_start = grid.rows.saturating_sub(4);
    for row in scan_start..grid.rows {
        let mut line = String::new();
        for col in 0..grid.cols {
            if let Some(c) = grid.cell(row, col) {
                line.push_str(&c.text);
            }
        }
        if !line.contains('•') {
            continue;
        }
        if line.contains("Working") {
            return true;
        }
        // Elapsed-time shape: a run of digits followed by `s`, `m `,
        // or `h `. Enough to detect Codex's compact time format
        // without pulling in a regex crate.
        let bytes = line.as_bytes();
        for i in 0..bytes.len() {
            if !bytes[i].is_ascii_digit() {
                continue;
            }
            let mut j = i;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 3 || j == i {
                continue;
            }
            if j < bytes.len() && matches!(bytes[j], b's' | b'm' | b'h') {
                return true;
            }
        }
    }
    false
}

/// True if Claude Code is currently in a thinking state — used to
/// gate the palindromic tab-icon animation so it doesn't run when
/// Claude is idle. Detection: any row in the bottom region of the
/// grid starts with a known Claude spinner char AND contains an
/// ellipsis (`…` or `...`) — the shape of Claude's `<glyph>
/// Verb…` status line.
///
/// Tolerant of false negatives (a brief between-frame gap won't
/// blank the animation — the check runs every render, and the
/// timer keeps advancing between checks), but strict on
/// false positives (won't animate on scrollback content).
fn is_claude_thinking(grid: &RenderGrid) -> bool {
    const CLAUDE_SPINNER_CHARS: &[char] = &['·', '✢', '✳', '✱', '✶', '✻', '✽', '❋'];
    for row in (0..grid.rows).rev() {
        let mut line = String::new();
        for col in 0..grid.cols {
            if let Some(c) = grid.cell(row, col) {
                line.push_str(&c.text);
            }
        }
        if !line.contains('…') && !line.contains("...") {
            continue;
        }
        let Some(first) = line.chars().find(|c| !c.is_whitespace()) else {
            continue;
        };
        if CLAUDE_SPINNER_CHARS.contains(&first) {
            return true;
        }
    }
    false
}

// Legacy detector kept for tests that document the char set Claude
// Code has historically cycled through. Live rendering uses the
// palindromic timer gated on `is_claude_thinking`.
#[cfg(test)]
fn detect_spinner_glyph(grid: &RenderGrid) -> Option<char> {
    const SPINNER_CHARS: &[char] = &[
        '·', '✢', '✳', '✱', '✶', '✦', '✧', '⋆', '✽', '✻', '❋', '✿', '✺', '✷', '✸', '✹', '❉', '❅',
        '◐', '◓', '◑', '◒',
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
    fn strip_leading_spinner_chars_scrubs_osc_prefix() {
        // Claude Code's OSC title is often "✻ Claude Code" — the
        // spinner glyph as leading char cycles frame to frame.
        assert_eq!(strip_leading_spinner_chars("✻ Claude Code"), "Claude Code");
        assert_eq!(strip_leading_spinner_chars("✽ Claude Code"), "Claude Code");
        assert_eq!(strip_leading_spinner_chars("• Codex"), "Codex");
        // No leading spinner — unchanged.
        assert_eq!(strip_leading_spinner_chars("Claude Code"), "Claude Code");
        // Doubled prefix like "✻ ✽ Claude" — sheds both.
        assert_eq!(strip_leading_spinner_chars("✻ ✽ Claude"), "Claude");
        // Spinner in the MIDDLE isn't stripped — only leading.
        assert_eq!(
            strip_leading_spinner_chars("Working ✻ 12s"),
            "Working ✻ 12s"
        );
    }

    #[test]
    fn resolve_tab_label_scrubs_leading_spinner_from_osc() {
        // OSC title from Claude Code — the leading ✻ was being
        // painted next to mnml's own icon slot, producing the
        // "double icon" the 2026-07-18 hunt found.
        assert_eq!(
            resolve_tab_label(None, "✻ Claude Code", "claude code"),
            "Claude Code"
        );
    }

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
    fn resolve_launcher_returns_default_when_no_manifest() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            resolve_launcher(dir.path(), "claude_code", "claude"),
            "claude"
        );
    }

    #[test]
    fn resolve_launcher_reads_override_from_manifest() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".mnml/integrations")).unwrap();
        std::fs::write(
            dir.path().join(".mnml/integrations/claude_code.toml"),
            "launcher = \"./bin/multi.sh\"\n",
        )
        .unwrap();
        assert_eq!(
            resolve_launcher(dir.path(), "claude_code", "claude"),
            "./bin/multi.sh"
        );
    }

    #[test]
    fn resolve_launcher_empty_string_falls_back_to_default() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".mnml/integrations")).unwrap();
        std::fs::write(
            dir.path().join(".mnml/integrations/claude_code.toml"),
            "launcher = \"\"\n",
        )
        .unwrap();
        assert_eq!(
            resolve_launcher(dir.path(), "claude_code", "claude"),
            "claude"
        );
    }

    #[test]
    fn resolve_launcher_survives_comments_and_whitespace() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".mnml/integrations")).unwrap();
        std::fs::write(
            dir.path().join(".mnml/integrations/codex.toml"),
            "# comment\n\n   launcher  =  \"wrap.sh\"   \n",
        )
        .unwrap();
        assert_eq!(resolve_launcher(dir.path(), "codex", "codex"), "wrap.sh");
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
    fn is_footer_chip_matches_claude_persistent_footer() {
        assert!(is_footer_chip(
            "auto mode on (shift+tab to cycle) · ↵ for agents"
        ));
        assert!(is_footer_chip("↵ for agents"));
        assert!(is_footer_chip("? for shortcuts"));
        assert!(is_footer_chip("Context left until auto-compact: 43%"));
        assert!(is_footer_chip("Shift+Tab to change mode"));
        // The confirmation-menu footer added 2026-07-18.
        assert!(is_footer_chip("Esc to cancel · Tab to amend"));
        assert!(is_footer_chip("Tab to amend"));
        // Startup-banner chrome — user screenshot 2026-07-18.
        assert!(is_footer_chip("manual mode on"));
        assert!(is_footer_chip("plan mode on (shift+tab to cycle)"));
        assert!(is_footer_chip(
            "⚠ 1 MCP server needs authentication · run /mcp"
        ));
        assert!(is_footer_chip("run /mcp"));
        assert!(!is_footer_chip("Sautéed for 27s"));
        assert!(!is_footer_chip("● I'll pull up TE-1234 from Jira."));
        // "2. Yes, and don't ask again ..." is menu content, not
        // chrome — must NOT be filtered.
        assert!(!is_footer_chip("2. Yes, and don't ask again for plugin"));
    }

    #[test]
    fn is_worked_completion_matches_claudes_done_chip() {
        assert!(is_worked_completion("✻ Worked for 30s"));
        assert!(is_worked_completion("· Worked for 5s"));
        assert!(is_worked_completion("Worked for 3m 15s"));
        // Prose that starts with "Worked for the last ..." shouldn't
        // hit — length guard rejects it.
        assert!(!is_worked_completion(
            "Worked for the last 5 years at Company X on payments infrastructure"
        ));
        // Different verb — real activity, shouldn't be dropped.
        assert!(!is_worked_completion("✻ Sautéed for 27s"));
    }

    #[test]
    fn is_input_prompt_matches_composer_lines() {
        assert!(is_input_prompt("> "));
        assert!(is_input_prompt("> tell me about TE-1234"));
        assert!(is_input_prompt(") Look for the ordering-channel feature"));
        assert!(is_input_prompt("❯ do the thing"));
        assert!(!is_input_prompt("Sautéed for 27s"));
    }

    #[test]
    fn looks_like_activity_line_matches_claudes_status_shape() {
        assert!(looks_like_activity_line("✻ Sautéed for 27s"));
        assert!(looks_like_activity_line("· Reading files…"));
        assert!(looks_like_activity_line("✳ Working…"));
        // Long body prose with an incidental "for 5s" doesn't count.
        assert!(!looks_like_activity_line(
            "A long paragraph of body text that happens to say Baked for 5s in the middle of a sentence"
        ));
        assert!(!looks_like_activity_line("auto mode on"));
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
