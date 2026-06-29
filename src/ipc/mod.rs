//! The file-IPC channel. Lives at `<workspace>/.mnml/ipc/`:
//!   - `command`      — JSONL the host appends to (one command per line);
//!   - `screen.txt`   — the most recent rendered virtual screen (text);
//!   - `status.json`  — a snapshot of focus / panes / cursor / mode / counts;
//!   - `events.jsonl` — append-only log of what happened (keypresses, opens, …).
//!
//! P0 supports a small command set; later tracks (HTTP, CDP, palette, …) extend
//! it. The headless loop and (when wired) the E2E runner both speak this.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde::Deserialize;

use crate::app::App;
use crate::input::keymap::parse_key_spec;

#[derive(Debug, Deserialize)]
struct RawCommand {
    cmd: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    key: Option<String>,
    /// `run-command` / `register-command`: the command id.
    #[serde(default)]
    id: Option<String>,
    /// `register-command`: palette title.
    #[serde(default)]
    title: Option<String>,
    /// `register-command`: which-key / palette group (default `"plugin"`).
    #[serde(default)]
    group: Option<String>,
    /// `register-command`: keyspecs to bind.
    #[serde(default)]
    keys: Vec<String>,
    /// `type`: literal text to type.
    #[serde(default)]
    text: Option<String>,
    /// `click` / `scroll` / `hover`: cell coordinates inside the
    /// virtual screen. Use the column / row visible in `screen.txt`.
    #[serde(default)]
    col: Option<u16>,
    #[serde(default)]
    row: Option<u16>,
    /// `click`: which button. `"left"` (default), `"middle"`, or
    /// `"right"`. Case-insensitive; first character also accepted
    /// (`"l"` / `"m"` / `"r"`).
    #[serde(default)]
    button: Option<String>,
    /// `scroll`: wheel ticks. Positive ⇒ scroll up (into history),
    /// negative ⇒ scroll down (toward bottom). Defaults to 1.
    #[serde(default)]
    dy: Option<i32>,
    /// `click`: optional modifiers as a comma-separated list:
    /// `"ctrl"`, `"alt"`, `"shift"`, `"super"`. Case-insensitive.
    #[serde(default)]
    mods: Option<String>,
    /// `expect_screen` / `expect_status`: assertion mode.
    /// `"contains"` (default) or `"lacks"`. (The substring itself
    /// reuses the `text` field above — same as `type`.)
    #[serde(default)]
    expect: Option<String>,
    /// `wait_ms`: milliseconds to sleep before processing the next
    /// command. Lets async work (LSP, git, AI) settle before
    /// snapshot / assertion.
    #[serde(default)]
    ms: Option<u64>,
    /// `drag`: source + destination cell coords. `from_col, from_row`
    /// hold the press point; `col, row` (re-used from click) hold
    /// the release point. Synthesizes Down(left) → Drag(left)
    /// per-step → Up(left).
    #[serde(default)]
    from_col: Option<u16>,
    #[serde(default)]
    from_row: Option<u16>,
    /// `open-pty`: argv to run (first element = executable).
    #[serde(default)]
    command: Vec<String>,
    /// `open-pty`: optional working directory. Defaults to the
    /// workspace when not supplied.
    #[serde(default)]
    cwd: Option<String>,
    /// `set-activity-badge`: target section name.
    #[serde(default)]
    section: Option<String>,
    /// `set-activity-badge`: notification count (0 clears).
    #[serde(default)]
    count: Option<u32>,
}

#[derive(Debug)]
pub enum IpcCommand {
    /// Open a file (path relative to the workspace, or absolute).
    Open(PathBuf),
    /// Inject a key by spec (e.g. `"ctrl+q"`, `"down"`, `"enter"`).
    Key(String),
    /// Type literal text into the focused pane, char by char (`\n` ⇒ Enter).
    Type(String),
    /// Synthetic mouse click — fires a Down+Up pair at `(col, row)`
    /// through the same `dispatch_mouse` the terminal loop uses, so
    /// every chrome hit-rect (tabs, palette, tree, statusline chips)
    /// is exercisable from headless. `button` defaults to `Left`.
    Click {
        col: u16,
        row: u16,
        button: ratatui::crossterm::event::MouseButton,
        mods: ratatui::crossterm::event::KeyModifiers,
    },
    /// Synthetic mouse hover — fires a `Moved` event at `(col, row)`.
    /// Used to test hover-tooltip routing (integration chips,
    /// statusline tooltips, divider highlights).
    Hover { col: u16, row: u16 },
    /// Synthetic wheel scroll at `(col, row)`. Positive `dy` ⇒
    /// `ScrollUp` (into history); negative ⇒ `ScrollDown` (toward
    /// bottom). Fired `|dy|` times so callers can simulate a single
    /// vs multi-tick wheel motion.
    Scroll { col: u16, row: u16, dy: i32 },
    /// Synthetic mouse drag from `(from_col, from_row)` to `(col, row)`.
    /// Synthesizes Down(left) at the source, a sequence of Drag events
    /// along a Bresenham-style path to the destination (one event per
    /// cell traversed, so a 10-cell drag fires ~10 events), and Up(left)
    /// at the destination. Tests splitter resize + tab drag-reorder.
    /// All events fire in a single `drain_commands` iteration — no paint
    /// frames between them. For recordings that need to SHOW the drag
    /// motion, drive the raw `MouseDown` / `MouseMove` / `MouseUp`
    /// variants with interleaved `Wait`s instead.
    Drag {
        from_col: u16,
        from_row: u16,
        col: u16,
        row: u16,
    },
    /// Raw mouse-down event at `(col, row)`. Companion to `MouseMove` /
    /// `MouseUp` for driving drags one event at a time so a recording
    /// host can interleave `Wait` between events and the renderer
    /// paints intermediate frames (ghost chip, drop overlay, hover
    /// highlights).
    MouseDown {
        col: u16,
        row: u16,
        button: ratatui::crossterm::event::MouseButton,
        mods: ratatui::crossterm::event::KeyModifiers,
    },
    /// Raw mouse-move event at `(col, row)`. Companion to `MouseDown` /
    /// `MouseUp`. When a button is pressed (host previously fired
    /// `MouseDown` without `MouseUp`), this is treated as a drag step;
    /// otherwise it's a hover.
    MouseMove { col: u16, row: u16 },
    /// Raw mouse-up event at `(col, row)`. Companion to `MouseDown`.
    MouseUp {
        col: u16,
        row: u16,
        button: ratatui::crossterm::event::MouseButton,
        mods: ratatui::crossterm::event::KeyModifiers,
    },
    /// Sleep for `ms` milliseconds. Lets async work (LSP responses,
    /// git refreshes, AI completions, IO) settle before the next
    /// `snapshot` / `expect_screen`.
    Wait { ms: u64 },
    /// Assert that `screen.txt` contains (or lacks) `text`. Writes
    /// an event with `ok=true|false` to `events.jsonl` so a host
    /// script can assert pre/post-condition without round-tripping
    /// through file reads.
    ExpectScreen { text: String, contains: bool },
    /// Run a registered command by id (builtin or plugin-registered).
    RunCommand(String),
    /// Register a plugin command (`id`, `title`, `group`, `keys`).
    RegisterCommand {
        id: String,
        title: String,
        group: String,
        keys: Vec<String>,
    },
    /// Force a fresh dump of `screen.txt` / `status.json`.
    Snapshot,
    /// Bridge tier-2: show a toast message in the host. Used by
    /// siblings to surface progress / errors to the user without
    /// a separate notification channel.
    Toast(String),
    /// Bridge tier-2: spawn a new Pty pane running `command` in
    /// `cwd` (defaults to the workspace). The first element of
    /// `command` is the executable; the rest are args. Used by
    /// siblings to dispatch follow-on work (run a test, tail a
    /// log) into a fresh mnml pane instead of as a detached child
    /// the user can't see.
    OpenPty {
        cwd: Option<PathBuf>,
        command: Vec<String>,
    },
    /// Bridge tier-2: set a notification badge on an activity-bar
    /// section. `section` is either a builtin section name
    /// (`"agents"`, `"cloud_agents"`, etc.) or a manifest-registered
    /// Mount id. `count = 0` clears the badge. Used by siblings
    /// that want to surface a queue depth, action-needed count,
    /// etc. without taking focus.
    SetActivityBadge { section: String, count: u32 },
    /// Write every registered click-rect to `rects.json` in the IPC
    /// dir. Each entry has `{x, y, w, h, label}`. Used by the
    /// click-rect audit + by ad-hoc debugging (`./run.sh dump-rects`).
    DumpRects,
    /// Install a family sibling by catalog id — runs cargo install
    /// in a Pty pane and (if the entry has a MountStub) writes the
    /// activity-bar manifest. Equivalent to the user invoking the
    /// `mounts.install` / `sibling.install` palette pickers and
    /// selecting `id`. Used by the AI tool `install_mnml_sibling`.
    InstallSibling { id: String },
    /// Stop the loop.
    Quit,
    /// Stop the loop with the restart exit code (the `run.sh` wrapper rebuilds + relaunches).
    Restart,
    /// Unknown / malformed — recorded as an event but otherwise ignored.
    Unknown(String),
}

pub struct Ipc {
    dir: PathBuf,
    cmd_path: PathBuf,
    screen_path: PathBuf,
    status_path: PathBuf,
    events_path: PathBuf,
    /// Bytes already consumed from `command`.
    cmd_offset: u64,
    /// True once a final "exit" event has been written (by
    /// headless::run on the happy path OR on signal-induced
    /// shutdown via the signal-hook handler in headless::run).
    /// `Drop` reads this to decide whether to emit an
    /// "unexpected" shutdown death certificate — covers panic-
    /// unwind and Err-propagation cases where the loop exits
    /// without emitting an event first.
    ///
    /// Signal coverage: SIGTERM / SIGINT / SIGHUP write an
    /// `"event":"exit","reason":"signal"` line. SIGKILL and
    /// `abort()` remain uncatchable by design (no Rust-runnable
    /// code can race the kernel).
    exit_event_written: std::sync::atomic::AtomicBool,
}

impl Drop for Ipc {
    fn drop(&mut self) {
        if !self
            .exit_event_written
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            // Best-effort death certificate. Writes to the events
            // log so the host has SOMETHING to grep for when an
            // unexpected exit happens. If the panic was a
            // poisoned mutex / OOM and writing fails, we tried.
            self.append_event(
                r#"{"event":"shutdown","reason":"unexpected","note":"ipc drop without happy-path exit"}"#,
            );
        }
    }
}

impl Ipc {
    /// Create `.mnml/ipc/` and (re)initialize its files for a fresh session.
    pub fn init(workspace: &Path) -> io::Result<Ipc> {
        let dir = workspace.join(".mnml").join("ipc");
        std::fs::create_dir_all(&dir)?;
        // 2026-06-07 bug-hunt SEV-3: open any git repo, run mnml,
        // and `.mnml/` shows up as untracked clutter (plus
        // git.status_pane / git.diff inside mnml then recursively
        // diffs its own IPC files). Best-effort append a `.mnml/`
        // line to the workspace's `.gitignore` on first creation.
        // Idempotent — checks the file content before appending.
        let _ = ensure_gitignore_excludes_mnml(workspace);
        let cmd_path = dir.join("command");
        let screen_path = dir.join("screen.txt");
        let status_path = dir.join("status.json");
        let events_path = dir.join("events.jsonl");
        // Snapshot any bytes the host pre-queued before our launch
        // and log them as a discrete event — `Ipc::init` then
        // truncates the channel so the live loop starts clean.
        // Without this, hosts that wrote commands then launched
        // mnml would silently lose those commands and hang waiting
        // for state changes that never came. 2026-06-07 bug-hunt SEV-3.
        let pre_queued = std::fs::read_to_string(&cmd_path).unwrap_or_default();
        // Truncate the command channel + events log so we start clean.
        std::fs::write(&cmd_path, b"")?;
        std::fs::write(&events_path, b"")?;
        std::fs::write(&screen_path, b"")?;
        std::fs::write(&status_path, b"{}")?;
        let ipc = Ipc {
            dir,
            cmd_path,
            screen_path,
            status_path,
            events_path,
            cmd_offset: 0,
            exit_event_written: std::sync::atomic::AtomicBool::new(false),
        };
        if !pre_queued.is_empty() {
            let lines = pre_queued.lines().count();
            ipc.append_event(&format!(
                "{{\"event\":\"ipc_init_truncated\",\"bytes\":{bytes},\"lines\":{lines}}}",
                bytes = pre_queued.len(),
            ));
        }
        Ok(ipc)
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Read any new lines appended to `command` since the last poll.
    pub fn poll(&mut self) -> Vec<IpcCommand> {
        let mut f = match std::fs::File::open(&self.cmd_path) {
            Ok(f) => f,
            Err(_) => return Vec::new(),
        };
        let len = f.metadata().map(|m| m.len()).unwrap_or(0);
        if len < self.cmd_offset {
            // file was truncated/rotated — start over
            self.cmd_offset = 0;
        }
        if len == self.cmd_offset {
            return Vec::new();
        }
        if io::Seek::seek(&mut f, io::SeekFrom::Start(self.cmd_offset)).is_err() {
            return Vec::new();
        }
        let mut buf = String::new();
        if f.read_to_string(&mut buf).is_err() {
            return Vec::new();
        }
        // Only consume up to the last complete line.
        let mut consumed = 0usize;
        let mut out = Vec::new();
        for line in buf.split_inclusive('\n') {
            if !line.ends_with('\n') {
                break; // partial line — leave it for next poll
            }
            consumed += line.len();
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            out.push(parse_command(trimmed));
        }
        self.cmd_offset += consumed as u64;
        out
    }

    pub fn write_screen(&self, text: &str) {
        let _ = std::fs::write(&self.screen_path, text.as_bytes());
    }
    pub fn write_status(&self, json: &str) {
        let _ = std::fs::write(&self.status_path, json.as_bytes());
    }
    /// Write a JSON dump of every registered click rect to
    /// `<ipc>/rects.json`. Triggered by the `dump-rects` IPC command
    /// + the headless render loop on every snapshot when
    /// `app.debug_rects` is enabled. Format: a JSON array of
    /// `{"label": str, "x": u16, "y": u16, "w": u16, "h": u16}`.
    pub fn write_rects(&self, json: &str) {
        let _ = std::fs::write(self.dir.join("rects.json"), json.as_bytes());
    }
    pub fn append_event(&self, json_line: &str) {
        if json_line.contains(r#""event":"exit""#) {
            self.exit_event_written
                .store(true, std::sync::atomic::Ordering::Relaxed);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.events_path)
        {
            let _ = writeln!(f, "{json_line}");
        }
    }
}

fn parse_command(line: &str) -> IpcCommand {
    let raw: RawCommand = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(_) => return IpcCommand::Unknown(line.to_string()),
    };
    match raw.cmd.as_str() {
        "open" => match raw.path {
            Some(p) => IpcCommand::Open(PathBuf::from(p)),
            None => IpcCommand::Unknown(line.to_string()),
        },
        "key" => match raw.key {
            Some(k) => IpcCommand::Key(k),
            None => IpcCommand::Unknown(line.to_string()),
        },
        "type" => match raw.text {
            Some(t) => IpcCommand::Type(t),
            None => IpcCommand::Unknown(line.to_string()),
        },
        "run-command" => match raw.id {
            Some(id) => IpcCommand::RunCommand(id),
            None => IpcCommand::Unknown(line.to_string()),
        },
        "register-command" => match raw.id {
            Some(id) => IpcCommand::RegisterCommand {
                title: raw.title.unwrap_or_else(|| id.clone()),
                group: raw.group.unwrap_or_else(|| "plugin".to_string()),
                keys: raw.keys,
                id,
            },
            None => IpcCommand::Unknown(line.to_string()),
        },
        "click" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::Click {
                col,
                row,
                button: parse_mouse_button(raw.button.as_deref()),
                mods: parse_mods(raw.mods.as_deref()),
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "hover" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::Hover { col, row },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "scroll" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::Scroll {
                col,
                row,
                dy: raw.dy.unwrap_or(1),
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "drag" => match (raw.from_col, raw.from_row, raw.col, raw.row) {
            (Some(fc), Some(fr), Some(tc), Some(tr)) => IpcCommand::Drag {
                from_col: fc,
                from_row: fr,
                col: tc,
                row: tr,
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "mouse_down" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::MouseDown {
                col,
                row,
                button: parse_mouse_button(raw.button.as_deref()),
                mods: parse_mods(raw.mods.as_deref()),
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "mouse_move" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::MouseMove { col, row },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "mouse_up" => match (raw.col, raw.row) {
            (Some(col), Some(row)) => IpcCommand::MouseUp {
                col,
                row,
                button: parse_mouse_button(raw.button.as_deref()),
                mods: parse_mods(raw.mods.as_deref()),
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "wait_ms" => match raw.ms {
            Some(ms) => IpcCommand::Wait { ms },
            None => IpcCommand::Unknown(line.to_string()),
        },
        "expect_screen" => match raw.text {
            Some(t) => {
                let contains = match raw.expect.as_deref() {
                    Some("lacks") => false,
                    _ => true, // default: contains
                };
                IpcCommand::ExpectScreen { text: t, contains }
            }
            None => IpcCommand::Unknown(line.to_string()),
        },
        "snapshot" => IpcCommand::Snapshot,
        "toast" => match raw.text {
            Some(t) => IpcCommand::Toast(t),
            None => IpcCommand::Unknown(line.to_string()),
        },
        "open-pty" => {
            if raw.command.is_empty() {
                IpcCommand::Unknown(line.to_string())
            } else {
                IpcCommand::OpenPty {
                    cwd: raw.cwd.map(PathBuf::from),
                    command: raw.command,
                }
            }
        }
        "set-activity-badge" => match (raw.section, raw.count) {
            (Some(s), Some(c)) => IpcCommand::SetActivityBadge {
                section: s,
                count: c,
            },
            _ => IpcCommand::Unknown(line.to_string()),
        },
        "dump-rects" => IpcCommand::DumpRects,
        "install-sibling" => match raw.id {
            Some(id) => IpcCommand::InstallSibling { id },
            None => IpcCommand::Unknown(line.to_string()),
        },
        "quit" => IpcCommand::Quit,
        "restart" => IpcCommand::Restart,
        _ => IpcCommand::Unknown(line.to_string()),
    }
}

/// Parse the `button` field on a click command. Accepts the full
/// word (`"left"` / `"middle"` / `"right"`) or the first letter
/// (`"l"` / `"m"` / `"r"`), case-insensitive. Anything else (and
/// `None`) ⇒ `Left` — the most common case, makes scripts terser.
/// On first `.mnml/` creation in a git repo, make sure the repo
/// gitignores it. Best-effort: any IO error is swallowed (the
/// `.mnml/` clutter is mild compared to crashing on a borderline
/// filesystem). Idempotent — only appends when the line is absent.
/// Skips when:
///   * `workspace/.git` doesn't exist (not a git repo, no point)
///   * `.gitignore` already has a literal `.mnml/` or `.mnml` line
///
/// Creates the gitignore if absent.
fn ensure_gitignore_excludes_mnml(workspace: &Path) -> io::Result<()> {
    if !workspace.join(".git").exists() {
        return Ok(());
    }
    let gi = workspace.join(".gitignore");
    let existing = std::fs::read_to_string(&gi).unwrap_or_default();
    // Match `.mnml`, `.mnml/`, `/.mnml`, `/.mnml/` as anchored or
    // non-anchored lines. Comments + indentation tolerated.
    let already = existing.lines().any(|line| {
        let t = line
            .split('#')
            .next()
            .unwrap_or("")
            .trim()
            .trim_start_matches('/')
            .trim_end_matches('/');
        t == ".mnml"
    });
    if already {
        return Ok(());
    }
    let mut out = existing;
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    out.push_str("# Added by mnml on first launch — workspace IPC + session state\n");
    out.push_str(".mnml/\n");
    std::fs::write(&gi, out)
}

fn parse_mouse_button(s: Option<&str>) -> ratatui::crossterm::event::MouseButton {
    use ratatui::crossterm::event::MouseButton;
    match s.map(str::to_ascii_lowercase).as_deref() {
        Some("middle" | "m") => MouseButton::Middle,
        Some("right" | "r") => MouseButton::Right,
        _ => MouseButton::Left,
    }
}

/// Parse the `mods` field — comma-separated list of modifier names.
/// Unknown names are silently dropped.
fn parse_mods(s: Option<&str>) -> ratatui::crossterm::event::KeyModifiers {
    use ratatui::crossterm::event::KeyModifiers;
    let Some(s) = s else {
        return KeyModifiers::NONE;
    };
    let mut out = KeyModifiers::NONE;
    for token in s.split(',') {
        match token.trim().to_ascii_lowercase().as_str() {
            "ctrl" | "control" => out |= KeyModifiers::CONTROL,
            "alt" | "option" => out |= KeyModifiers::ALT,
            "shift" => out |= KeyModifiers::SHIFT,
            "super" | "cmd" | "meta" => out |= KeyModifiers::SUPER,
            _ => {}
        }
    }
    out
}

/// Apply one IPC command to `app`. Key injection goes through the *same*
/// dispatcher as the terminal loop (`crate::tui::dispatch_key`), so headless
/// behavior matches the real UI. Returns a short JSON event description.
pub fn apply(app: &mut App, cmd: &IpcCommand) -> String {
    match cmd {
        IpcCommand::Open(p) => {
            let path = if p.is_absolute() {
                p.clone()
            } else {
                app.workspace.join(p)
            };
            app.open_path(&path);
            json_event(&[("event", "open"), ("path", &path.display().to_string())])
        }
        IpcCommand::Key(spec) => {
            // 2026-06-21 nvchad SEV-3 ipc-key-spec-rejects-chord-chains:
            // accept whitespace-separated chord chains (e.g.
            // "ctrl+w h" — vim window-prefix → focus left). Was:
            // single-chord only, so test scripts firing chord
            // sequences silently got `key_unparsed`. Each token
            // is parsed independently and dispatched in order.
            let tokens: Vec<&str> = spec.split_whitespace().collect();
            let parsed: Vec<KeyEvent> = tokens.iter().filter_map(|t| parse_key_spec(t)).collect();
            if parsed.len() == tokens.len() && !parsed.is_empty() {
                for ev in parsed {
                    crate::tui::dispatch_key(app, ev);
                }
                json_event(&[("event", "key"), ("key", spec)])
            } else {
                json_event(&[("event", "key_unparsed"), ("key", spec)])
            }
        }
        IpcCommand::Type(text) => {
            for c in text.chars() {
                let ev = if c == '\n' {
                    KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)
                } else {
                    KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
                };
                crate::tui::dispatch_key(app, ev);
            }
            json_event(&[("event", "type"), ("text", text)])
        }
        IpcCommand::RunCommand(id) => {
            let ok = crate::command::run(id, app);
            json_event(&[
                ("event", "command_run"),
                ("id", id),
                ("ok", if ok { "true" } else { "false" }),
            ])
        }
        IpcCommand::RegisterCommand {
            id,
            title,
            group,
            keys,
        } => {
            app.register_dynamic_command(crate::command::DynCommand {
                id: id.clone(),
                title: title.clone(),
                group: group.clone(),
                keys: keys.clone(),
            });
            json_event(&[
                ("event", "command_registered"),
                ("id", id),
                ("title", title),
            ])
        }
        IpcCommand::Click {
            col,
            row,
            button,
            mods,
        } => {
            use ratatui::crossterm::event::{MouseEvent, MouseEventKind};
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Down(*button),
                    column: *col,
                    row: *row,
                    modifiers: *mods,
                },
            );
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Up(*button),
                    column: *col,
                    row: *row,
                    modifiers: *mods,
                },
            );
            json_event(&[
                ("event", "click"),
                ("button", &format!("{button:?}")),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
            ])
        }
        IpcCommand::Hover { col, row } => {
            use ratatui::crossterm::event::{KeyModifiers, MouseEvent, MouseEventKind};
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Moved,
                    column: *col,
                    row: *row,
                    modifiers: KeyModifiers::NONE,
                },
            );
            json_event(&[
                ("event", "hover"),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
            ])
        }
        IpcCommand::Drag {
            from_col,
            from_row,
            col,
            row,
        } => {
            use ratatui::crossterm::event::{
                KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
            };
            // Press at source.
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Down(MouseButton::Left),
                    column: *from_col,
                    row: *from_row,
                    modifiers: KeyModifiers::NONE,
                },
            );
            // Bresenham-style linear-interpolated path, ~1 event per
            // cell. Avoids spamming hundreds of events for long drags
            // + keeps short drags responsive.
            let steps = (col.abs_diff(*from_col)).max(row.abs_diff(*from_row)) as usize;
            for s in 1..=steps {
                let t = s as f32 / steps as f32;
                let cx = (*from_col as f32 + (*col as f32 - *from_col as f32) * t).round() as u16;
                let cy = (*from_row as f32 + (*row as f32 - *from_row as f32) * t).round() as u16;
                crate::tui::dispatch_mouse(
                    app,
                    MouseEvent {
                        kind: MouseEventKind::Drag(MouseButton::Left),
                        column: cx,
                        row: cy,
                        modifiers: KeyModifiers::NONE,
                    },
                );
            }
            // Release at destination.
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Up(MouseButton::Left),
                    column: *col,
                    row: *row,
                    modifiers: KeyModifiers::NONE,
                },
            );
            json_event(&[
                ("event", "drag"),
                ("from", &format!("{from_col},{from_row}")),
                ("to", &format!("{col},{row}")),
                ("steps", &steps.to_string()),
            ])
        }
        IpcCommand::MouseDown {
            col,
            row,
            button,
            mods,
        } => {
            use ratatui::crossterm::event::{MouseEvent, MouseEventKind};
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Down(*button),
                    column: *col,
                    row: *row,
                    modifiers: *mods,
                },
            );
            json_event(&[
                ("event", "mouse_down"),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
            ])
        }
        IpcCommand::MouseMove { col, row } => {
            use ratatui::crossterm::event::{
                KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
            };
            // If a left button is currently held (host previously fired
            // MouseDown without MouseUp), this is a Drag step; otherwise
            // a Moved hover. Drives the ghost-chip + drop-overlay paint
            // path the same way a real mouse does mid-drag.
            let kind = if app.tree_drag.is_some() {
                MouseEventKind::Drag(MouseButton::Left)
            } else {
                MouseEventKind::Moved
            };
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind,
                    column: *col,
                    row: *row,
                    modifiers: KeyModifiers::NONE,
                },
            );
            json_event(&[
                ("event", "mouse_move"),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
            ])
        }
        IpcCommand::MouseUp {
            col,
            row,
            button,
            mods,
        } => {
            use ratatui::crossterm::event::{MouseEvent, MouseEventKind};
            crate::tui::dispatch_mouse(
                app,
                MouseEvent {
                    kind: MouseEventKind::Up(*button),
                    column: *col,
                    row: *row,
                    modifiers: *mods,
                },
            );
            json_event(&[
                ("event", "mouse_up"),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
            ])
        }
        IpcCommand::Wait { ms } => {
            std::thread::sleep(std::time::Duration::from_millis(*ms));
            json_event(&[("event", "wait_ms"), ("ms", &ms.to_string())])
        }
        IpcCommand::ExpectScreen { text, contains } => {
            // Read the most recent screen.txt the headless loop wrote.
            // Caller should `snapshot` first if they need post-command
            // state — this only reads what's on disk now.
            let screen_path = app.workspace.join(".mnml/ipc/screen.txt");
            let screen = std::fs::read_to_string(&screen_path).unwrap_or_default();
            let found = screen.contains(text.as_str());
            let ok = if *contains { found } else { !found };
            json_event(&[
                ("event", "expect_screen"),
                ("mode", if *contains { "contains" } else { "lacks" }),
                ("text", text),
                ("ok", if ok { "true" } else { "false" }),
            ])
        }
        IpcCommand::Scroll { col, row, dy } => {
            use ratatui::crossterm::event::{KeyModifiers, MouseEvent, MouseEventKind};
            let kind = if *dy >= 0 {
                MouseEventKind::ScrollUp
            } else {
                MouseEventKind::ScrollDown
            };
            // |dy| ticks — terminals usually deliver one per wheel
            // notch; tests can request multi-tick by passing a
            // larger value, mirroring a fast spin.
            for _ in 0..dy.unsigned_abs() {
                crate::tui::dispatch_mouse(
                    app,
                    MouseEvent {
                        kind,
                        column: *col,
                        row: *row,
                        modifiers: KeyModifiers::NONE,
                    },
                );
            }
            json_event(&[
                ("event", "scroll"),
                ("col", &col.to_string()),
                ("row", &row.to_string()),
                ("dy", &dy.to_string()),
            ])
        }
        IpcCommand::Snapshot => json_event(&[("event", "snapshot")]),
        IpcCommand::Toast(text) => {
            app.toast(text.clone());
            json_event(&[("event", "toast"), ("text", text)])
        }
        IpcCommand::OpenPty { cwd, command } => {
            if command.is_empty() {
                json_event(&[("event", "open_pty_error"), ("reason", "command empty")])
            } else {
                let exe = command[0].clone();
                let args: Vec<String> = command[1..].to_vec();
                let cwd_path = cwd.clone().unwrap_or_else(|| app.workspace.clone());
                let label = exe.rsplit('/').next().unwrap_or(&exe).to_string();
                let profile = crate::pty_pane::BinaryProfile {
                    label,
                    exe: exe.clone(),
                    args,
                    cwd: Some(cwd_path),
                    env: Vec::new(),
                    session_id: None,
                };
                app.open_pty(profile);
                json_event(&[("event", "open_pty"), ("exe", &exe)])
            }
        }
        IpcCommand::SetActivityBadge { section, count } => {
            app.set_activity_badge(section.clone(), *count);
            json_event(&[
                ("event", "set_activity_badge"),
                ("section", section),
                ("count", &count.to_string()),
            ])
        }
        IpcCommand::DumpRects => json_event(&[("event", "dump_rects")]),
        IpcCommand::InstallSibling { id } => {
            app.install_sibling(id);
            json_event(&[("event", "install_sibling"), ("id", id)])
        }
        IpcCommand::Quit => {
            // Scripts/E2E know what they're doing — force, bypassing the dirty guard.
            app.should_quit = true;
            json_event(&[("event", "quit")])
        }
        IpcCommand::Restart => {
            app.restart_requested = true;
            app.should_quit = true;
            json_event(&[("event", "restart")])
        }
        IpcCommand::Unknown(s) => json_event(&[("event", "unknown"), ("raw", s)]),
    }
}

/// Write the current `screen.txt` + `status.json`. Both frontends call this
/// after rendering — headless reads `TestBackend::buffer()`, the terminal loop
/// reads `Terminal::current_buffer_mut()`.
pub fn dump_screen_status(ipc: &Ipc, screen: &ratatui::buffer::Buffer, app: &App) {
    ipc.write_screen(&screen_to_text(screen));
    ipc.write_status(&status_json(app));
    // Always emit `rects.json` alongside the screen so headless
    // audit scripts can verify click rects without a separate IPC
    // round-trip. Cheap (a few hundred bytes of JSON per frame at
    // worst). Added 2026-06-19 with the click-rect audit toolkit.
    ipc.write_rects(&rects_dump_json(app));
}

/// Serialize every registered click rect to JSON. Walks the
/// well-known fields on `App.rects` (single `Option<Rect>` and
/// `Vec<(Rect, label)>` shapes) and emits one entry per visible
/// rect. Used by the `dump-rects` IPC command + the click-rect audit
/// test. The label is the descriptive name of the field (or the
/// embedded command-id for tagged vec entries) so the consumer can
/// look up what fires when that rect is clicked.
pub fn rects_dump_json(app: &App) -> String {
    let mut out = String::from("[\n");
    let mut first = true;
    let push_rect = |out: &mut String, first: &mut bool, label: &str, r: ratatui::layout::Rect| {
        if !*first {
            out.push_str(",\n");
        }
        *first = false;
        out.push_str(&format!(
            "  {{\"label\":\"{label}\",\"x\":{x},\"y\":{y},\"w\":{w},\"h\":{h}}}",
            x = r.x,
            y = r.y,
            w = r.width,
            h = r.height
        ));
    };
    macro_rules! one {
        ($label:expr, $field:expr) => {
            if let Some(r) = $field {
                push_rect(&mut out, &mut first, $label, r);
            }
        };
    }
    one!("tree_toggle", app.rects.tree_toggle);
    one!("tree_edge", app.rects.tree_edge);
    one!(
        "integration_section_toggle",
        app.rects.integration_section_toggle
    );
    one!(
        "statusline_workspace_chip",
        app.rects.statusline_workspace_chip
    );
    one!("statusline_branch_chip", app.rects.statusline_branch_chip);
    one!("statusline_mode_chip", app.rects.statusline_mode_chip);
    one!("statusline_clock_chip", app.rects.statusline_clock_chip);
    one!("statusline_mixr_chip", app.rects.statusline_mixr_chip);
    one!("activity_bar_gear", app.rects.activity_bar_gear);
    one!("cmdline_bar", app.rects.cmdline_bar);
    // vscode-user-mouse / vscode-user SEV-3 — the new palette-bar
    // chrome was invisible to the headless click-rect audit. All
    // chips have rects already; just expose them.
    one!("palette_sidebar_button", app.rects.palette_sidebar_button);
    one!(
        "palette_right_panel_button",
        app.rects.palette_right_panel_button
    );
    one!("palette_back_button", app.rects.palette_back_button);
    one!("palette_forward_button", app.rects.palette_forward_button);
    one!("palette_search_chip", app.rects.palette_search_chip);
    one!("palette_dropdown_button", app.rects.palette_dropdown_button);
    one!(
        "palette_add_integration_button",
        app.rects.palette_add_integration_button
    );
    one!("right_panel_edge", app.rects.right_panel_edge);
    one!("right_panel_close", app.rects.right_panel_close);
    // vscode-user 2nd 2026-06-28 SEV-2: the empty-state click
    // targets were registered in app.rects + handled in mouse.rs
    // but never dumped to rects.json, so a headless / IPC-driven
    // user couldn't actually click them deterministically. (The
    // real mouse path always worked.)
    one!(
        "right_panel_empty_outline",
        app.rects.right_panel_empty_outline
    );
    one!(
        "right_panel_empty_diagnostics",
        app.rects.right_panel_empty_diagnostics
    );
    one!("right_panel_empty_ai", app.rects.right_panel_empty_ai);
    one!("right_panel_empty_grep", app.rects.right_panel_empty_grep);
    one!("right_panel_empty_test", app.rects.right_panel_empty_test);
    one!(
        "bufferline_new_tab_button",
        app.rects.bufferline_new_tab_button
    );
    one!("bufferline_theme_toggle", app.rects.bufferline_theme_toggle);
    one!("bufferline_window_close", app.rects.bufferline_window_close);
    // qa-6th mouse SEV-2 2026-06-29 — the ‹/› overflow chevrons
    // had click handlers in mouse/down_left.rs but the rects
    // never made it to rects.json, so IPC-driven users couldn't
    // see them and the agent reported them as missing.
    one!(
        "bufferline_overflow_left",
        app.rects.bufferline_overflow_left
    );
    one!(
        "bufferline_overflow_right",
        app.rects.bufferline_overflow_right
    );
    for (r, _) in &app.rects.bufferline_tab_close {
        push_rect(&mut out, &mut first, "bufferline_tab_close", *r);
    }
    for (r, i) in &app.rects.bufferline_tab_page_chips {
        push_rect(&mut out, &mut first, &format!("tab_page:{i}"), *r);
    }
    for (r, i) in &app.rects.bufferline_tab_page_close {
        push_rect(&mut out, &mut first, &format!("tab_page_close:{i}"), *r);
    }
    for (r, i) in &app.rects.menu_bar_words {
        push_rect(&mut out, &mut first, &format!("menu_bar:{i}"), *r);
    }
    for (r, label) in &app.rects.tree_icon_buttons {
        push_rect(&mut out, &mut first, &format!("tree_icon:{label}"), *r);
    }
    for (r, idx) in &app.rects.integration_icon_rects {
        push_rect(&mut out, &mut first, &format!("integration:{idx}"), *r);
    }
    for (r, section) in &app.rects.activity_bar_icons {
        push_rect(&mut out, &mut first, &format!("activity:{section:?}"), *r);
    }
    for (r, idx) in &app.rects.launcher_icon_rects {
        push_rect(&mut out, &mut first, &format!("launcher:{idx}"), *r);
    }
    // Extra rect families added per reviewer feedback (overstated
    // "every registered click rect" claim) — the ones most likely
    // to be subject to the same chip-overlap bug pattern that
    // motivated the audit toolkit.
    for (r, idx) in &app.rects.extra_workspace_toggles {
        push_rect(
            &mut out,
            &mut first,
            &format!("extra_workspace_toggle:{idx}"),
            *r,
        );
    }
    for (r, idx) in &app.rects.discovery_integration_rows {
        push_rect(
            &mut out,
            &mut first,
            &format!("discovery_integration_row:{idx}"),
            *r,
        );
    }
    for (r, _) in &app.rects.git_rail_rows {
        push_rect(&mut out, &mut first, "git_rail_row", *r);
    }
    for (r, id) in &app.rects.bufferline_tabs {
        push_rect(&mut out, &mut first, &format!("bufferline_tab:{id}"), *r);
    }
    // mouse-hunter v3 SEV-1 A — right_panel_tabs were not dumped.
    for (r, idx) in &app.rects.right_panel_tabs {
        push_rect(&mut out, &mut first, &format!("right_panel_tab:{idx}"), *r);
    }
    for (r, leaf_active, dir) in &app.rects.split_strip_buttons {
        push_rect(
            &mut out,
            &mut first,
            &format!("split_strip:{leaf_active}:{dir:?}"),
            *r,
        );
    }
    for (r, leaf_active) in &app.rects.split_strip_term_buttons {
        push_rect(
            &mut out,
            &mut first,
            &format!("split_strip_term:{leaf_active}"),
            *r,
        );
    }
    // 2026-06-19 — second batch of rect families per vscode-user-
    // mouse agent's "toolkit misses what it was built for" finding.
    if let Some(r) = app.rects.picker_box {
        push_rect(&mut out, &mut first, "picker_box", r);
    }
    for (r, idx) in &app.rects.picker_items {
        push_rect(&mut out, &mut first, &format!("picker_item:{idx}"), *r);
    }
    for (r, pid, field) in &app.rects.request_fields {
        push_rect(
            &mut out,
            &mut first,
            &format!("request_field:{pid}:{field:?}"),
            *r,
        );
    }
    for (r, idx) in &app.rects.context_menu_items {
        push_rect(
            &mut out,
            &mut first,
            &format!("context_menu_item:{idx}"),
            *r,
        );
    }
    // 2026-06-19 — api-workflow third hunt: tabbed Edit-view chip
    // rects weren't in the dump, making the click bug undetectable
    // via the toolkit.
    for (r, pid, tab) in &app.rects.request_edit_tabs {
        push_rect(
            &mut out,
            &mut first,
            &format!("request_edit_tab:{pid}:{tab:?}"),
            *r,
        );
    }
    for (r, pid, view) in &app.rects.request_tabs {
        push_rect(
            &mut out,
            &mut first,
            &format!("request_tab:{pid}:{view:?}"),
            *r,
        );
    }
    out.push_str("\n]");
    out
}

/// Poll the command channel and apply every queued command, logging each as an
/// event. Returns true if any command was processed (so the caller can redraw).
pub fn drain_commands(ipc: &mut Ipc, app: &mut App) -> bool {
    let cmds = ipc.poll();
    let any = !cmds.is_empty();
    for c in &cmds {
        let ev = apply(app, c);
        ipc.append_event(&ev);
    }
    any
}

/// Emit a `{"event":"plugin-command","id":…}` line for every plugin-registered
/// command invoked since the last call (from the palette, a keybinding, or an
/// IPC `run-command`) so the plugin that owns it can react. Both run loops call
/// this once per iteration after input handling.
pub fn drain_plugin_events(ipc: &Ipc, app: &mut App) {
    for id in app.take_pending_plugin_invocations() {
        ipc.append_event(&json_event(&[("event", "plugin-command"), ("id", &id)]));
    }
}

/// Render a `ratatui::buffer::Buffer` to plain text (rows joined by `\n`,
/// trailing spaces trimmed). Used for `screen.txt`.
pub fn screen_to_text(buf: &ratatui::buffer::Buffer) -> String {
    let area = buf.area;
    let mut out = String::with_capacity((area.width as usize + 1) * area.height as usize);
    for y in area.top()..area.bottom() {
        let mut row = String::with_capacity(area.width as usize);
        for x in area.left()..area.right() {
            row.push_str(buf[(x, y)].symbol());
        }
        out.push_str(row.trim_end());
        out.push('\n');
    }
    out
}

/// Build the `status.json` body for the current app state.
pub fn status_json(app: &App) -> String {
    let focus = match app.focus {
        crate::focus::Focus::Tree => "tree",
        crate::focus::Focus::Pane => "pane",
    };
    let active_file = app
        .active_editor()
        .and_then(|b| b.path.clone())
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let (cur_row, cur_col) = app
        .active_editor()
        .map(|b| {
            let (r, c) = b.editor.row_col();
            (r + 1, c + 1)
        })
        .unwrap_or((0, 0));
    let mode = app.editing_mode().label().unwrap_or("none");
    let tree_cursor = app.tree.cursor();
    let tree_sel = app
        .tree
        .selected_row()
        .map(|r| r.path.display().to_string())
        .unwrap_or_default();
    let panes: Vec<String> = app
        .panes
        .iter()
        .map(|p| {
            format!(
                "{{\"title\":{},\"dirty\":{}}}",
                json_str(&p.title()),
                p.is_dirty()
            )
        })
        .collect();
    // mouse-hunter v3 SEV-3 K — right-panel state for headless
    // harness assertions.
    let right_panel_panes_json = app
        .right_panel_panes
        .iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "{{\"focus\":{},\"activePane\":{},\"activeFile\":{},\"cursor\":{{\"line\":{},\"col\":{}}},\"mode\":{},\"treeCursor\":{},\"treeSelection\":{},\"treeVisible\":{},\"rightPanelVisible\":{},\"rightPanelPanes\":[{}],\"rightPanelActiveIdx\":{},\"panes\":[{}],\"quit\":{}}}",
        json_str(focus),
        app.active
            .map(|i| i.to_string())
            .unwrap_or_else(|| "null".to_string()),
        json_str(&active_file),
        cur_row,
        cur_col,
        json_str(mode),
        tree_cursor,
        json_str(&tree_sel),
        app.tree_visible,
        app.right_panel_visible,
        right_panel_panes_json,
        app.right_panel_active_idx,
        panes.join(","),
        app.should_quit,
    )
}

fn json_event(pairs: &[(&str, &str)]) -> String {
    let body: Vec<String> = pairs
        .iter()
        .map(|(k, v)| format!("{}:{}", json_str(k), json_str(v)))
        .collect();
    format!("{{{}}}", body.join(","))
}

fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    #[test]
    fn parses_plugin_commands() {
        assert!(matches!(
            parse_command(r#"{"cmd":"register-command","id":"p.a","title":"A"}"#),
            IpcCommand::RegisterCommand { .. }
        ));
        assert!(matches!(
            parse_command(r#"{"cmd":"run-command","id":"file.save"}"#),
            IpcCommand::RunCommand(_)
        ));
        assert!(matches!(
            parse_command(r#"{"cmd":"type","text":"hi"}"#),
            IpcCommand::Type(_)
        ));
        // missing the required field ⇒ Unknown
        assert!(matches!(
            parse_command(r#"{"cmd":"run-command"}"#),
            IpcCommand::Unknown(_)
        ));
    }

    #[test]
    fn parse_command_covers_every_arm() {
        use IpcCommand::*;
        assert!(matches!(
            parse_command(r#"{"cmd":"open","path":"a.txt"}"#),
            Open(_)
        ));
        assert!(matches!(parse_command(r#"{"cmd":"open"}"#), Unknown(_)));
        assert!(matches!(
            parse_command(r#"{"cmd":"key","key":"ctrl+s"}"#),
            Key(_)
        ));
        assert!(matches!(parse_command(r#"{"cmd":"key"}"#), Unknown(_)));
        assert!(matches!(parse_command(r#"{"cmd":"type"}"#), Unknown(_)));
        assert!(matches!(parse_command(r#"{"cmd":"snapshot"}"#), Snapshot));
        assert!(matches!(parse_command(r#"{"cmd":"quit"}"#), Quit));
        assert!(matches!(parse_command(r#"{"cmd":"restart"}"#), Restart));
        assert!(matches!(
            parse_command(r#"{"cmd":"install-sibling","id":"tattle_tests"}"#),
            InstallSibling { .. }
        ));
        assert!(matches!(
            parse_command(r#"{"cmd":"install-sibling"}"#),
            Unknown(_)
        ));
        assert!(matches!(parse_command(r#"{"cmd":"bogus"}"#), Unknown(_)));
        // Malformed JSON ⇒ Unknown, never a panic.
        assert!(matches!(parse_command("not json at all"), Unknown(_)));
        assert!(matches!(parse_command("{"), Unknown(_)));
    }

    #[test]
    fn parses_mouse_commands() {
        use ratatui::crossterm::event::{KeyModifiers, MouseButton};

        // click defaults to Left + NONE.
        let cmd = parse_command(r#"{"cmd":"click","col":5,"row":10}"#);
        match cmd {
            IpcCommand::Click {
                col,
                row,
                button,
                mods,
            } => {
                assert_eq!(col, 5);
                assert_eq!(row, 10);
                assert!(matches!(button, MouseButton::Left));
                assert_eq!(mods, KeyModifiers::NONE);
            }
            other => panic!("expected Click, got {other:?}"),
        }

        // explicit middle + ctrl
        let cmd =
            parse_command(r#"{"cmd":"click","col":1,"row":2,"button":"middle","mods":"ctrl"}"#);
        match cmd {
            IpcCommand::Click { button, mods, .. } => {
                assert!(matches!(button, MouseButton::Middle));
                assert_eq!(mods, KeyModifiers::CONTROL);
            }
            other => panic!("expected Click, got {other:?}"),
        }

        // 'r' alias
        let cmd = parse_command(r#"{"cmd":"click","col":1,"row":2,"button":"r"}"#);
        match cmd {
            IpcCommand::Click { button, .. } => assert!(matches!(button, MouseButton::Right)),
            other => panic!("expected Click, got {other:?}"),
        }

        // hover
        assert!(matches!(
            parse_command(r#"{"cmd":"hover","col":0,"row":0}"#),
            IpcCommand::Hover { col: 0, row: 0 }
        ));

        // scroll dy defaults to 1
        match parse_command(r#"{"cmd":"scroll","col":3,"row":4}"#) {
            IpcCommand::Scroll { col, row, dy } => {
                assert_eq!(col, 3);
                assert_eq!(row, 4);
                assert_eq!(dy, 1);
            }
            other => panic!("expected Scroll, got {other:?}"),
        }
        // negative dy
        match parse_command(r#"{"cmd":"scroll","col":0,"row":0,"dy":-3}"#) {
            IpcCommand::Scroll { dy, .. } => assert_eq!(dy, -3),
            other => panic!("expected Scroll, got {other:?}"),
        }
        // missing required field ⇒ Unknown
        assert!(matches!(
            parse_command(r#"{"cmd":"click","col":5}"#),
            IpcCommand::Unknown(_)
        ));
        assert!(matches!(
            parse_command(r#"{"cmd":"hover","row":5}"#),
            IpcCommand::Unknown(_)
        ));
    }

    #[test]
    fn parse_mods_handles_aliases_and_combinations() {
        use ratatui::crossterm::event::KeyModifiers;
        assert_eq!(
            parse_mods(Some("ctrl,shift")),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT
        );
        assert_eq!(parse_mods(Some("alt")), KeyModifiers::ALT);
        assert_eq!(parse_mods(Some("option")), KeyModifiers::ALT);
        assert_eq!(parse_mods(Some("cmd")), KeyModifiers::SUPER);
        assert_eq!(parse_mods(Some("meta")), KeyModifiers::SUPER);
        // Case-insensitive, unknown tokens dropped.
        assert_eq!(
            parse_mods(Some("Ctrl,Hyper,Alt")),
            KeyModifiers::CONTROL | KeyModifiers::ALT
        );
        assert_eq!(parse_mods(None), KeyModifiers::NONE);
    }

    #[test]
    fn ipc_init_skips_gitignore_outside_git_repo() {
        let dir = tempfile::tempdir().unwrap();
        // No .git dir ⇒ no gitignore touch.
        let _ipc = Ipc::init(dir.path()).unwrap();
        assert!(!dir.path().join(".gitignore").exists());
    }

    #[test]
    fn ipc_init_creates_gitignore_in_git_repo() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join(".git")).unwrap();
        let _ipc = Ipc::init(dir.path()).unwrap();
        let gi = std::fs::read_to_string(dir.path().join(".gitignore")).unwrap();
        assert!(
            gi.contains(".mnml/"),
            "gitignore should mention .mnml/: {gi}"
        );
        assert!(
            gi.contains("Added by mnml"),
            "should include header comment"
        );
    }

    #[test]
    fn ipc_init_appends_to_existing_gitignore() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join(".git")).unwrap();
        let gi = dir.path().join(".gitignore");
        std::fs::write(&gi, "target/\n").unwrap();
        let _ipc = Ipc::init(dir.path()).unwrap();
        let content = std::fs::read_to_string(&gi).unwrap();
        assert!(content.contains("target/"), "existing entries preserved");
        assert!(content.contains(".mnml/"), "new entry added");
    }

    #[test]
    fn ipc_init_is_idempotent_on_gitignore() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join(".git")).unwrap();
        // .mnml already present — should NOT double-append.
        let gi = dir.path().join(".gitignore");
        std::fs::write(&gi, "target/\n.mnml/\n").unwrap();
        let _ipc = Ipc::init(dir.path()).unwrap();
        let content = std::fs::read_to_string(&gi).unwrap();
        assert_eq!(
            content.matches(".mnml/").count(),
            1,
            "second init should not append duplicate; content:\n{content}"
        );
    }

    #[test]
    fn poll_reads_complete_lines_then_advances_the_offset() {
        let dir = tempfile::tempdir().unwrap();
        let mut ipc = Ipc::init(dir.path()).unwrap();
        std::fs::write(
            &ipc.cmd_path,
            "{\"cmd\":\"quit\"}\n{\"cmd\":\"snapshot\"}\n",
        )
        .unwrap();
        assert_eq!(ipc.poll().len(), 2);
        // Already consumed — a second poll with no new bytes yields nothing.
        assert!(ipc.poll().is_empty());
    }

    #[test]
    fn poll_holds_a_partial_line_until_its_newline_arrives() {
        let dir = tempfile::tempdir().unwrap();
        let mut ipc = Ipc::init(dir.path()).unwrap();
        // A line with no trailing newline is not yet a command.
        std::fs::write(&ipc.cmd_path, "{\"cmd\":\"quit\"}").unwrap();
        assert!(ipc.poll().is_empty(), "partial line must not be consumed");
        // The host finishes the line — now it parses.
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&ipc.cmd_path)
            .unwrap();
        f.write_all(b"\n").unwrap();
        drop(f);
        assert_eq!(ipc.poll().len(), 1);
    }

    #[test]
    fn poll_skips_blank_lines() {
        let dir = tempfile::tempdir().unwrap();
        let mut ipc = Ipc::init(dir.path()).unwrap();
        std::fs::write(&ipc.cmd_path, "\n\n{\"cmd\":\"quit\"}\n\n").unwrap();
        assert_eq!(ipc.poll().len(), 1);
    }

    #[test]
    fn poll_resets_when_the_command_file_is_truncated() {
        let dir = tempfile::tempdir().unwrap();
        let mut ipc = Ipc::init(dir.path()).unwrap();
        std::fs::write(
            &ipc.cmd_path,
            "{\"cmd\":\"snapshot\"}\n{\"cmd\":\"snapshot\"}\n",
        )
        .unwrap();
        assert_eq!(ipc.poll().len(), 2);
        // The host rewrote (truncated) the channel — `len < offset` ⇒
        // start over rather than miss the new content.
        std::fs::write(&ipc.cmd_path, "{\"cmd\":\"quit\"}\n").unwrap();
        assert_eq!(ipc.poll().len(), 1);
    }

    #[test]
    fn apply_restart_sets_both_restart_and_quit() {
        let dir = tempfile::tempdir().unwrap();
        let mut app = App::new(dir.path().to_path_buf(), Config::default()).unwrap();
        apply(&mut app, &IpcCommand::Restart);
        assert!(app.should_quit);
        assert!(app.restart_requested);
    }

    #[test]
    fn json_str_escapes_the_dangerous_characters() {
        assert_eq!(json_str("plain"), "\"plain\"");
        assert_eq!(json_str("a\"b"), "\"a\\\"b\"");
        assert_eq!(json_str("a\\b"), "\"a\\\\b\"");
        assert_eq!(json_str("line\nbreak"), "\"line\\nbreak\"");
        assert_eq!(json_str("tab\there"), "\"tab\\there\"");
        // A bare control char becomes a \u escape.
        assert_eq!(json_str("\u{1}"), "\"\\u0001\"");
    }

    #[test]
    fn screen_to_text_trims_trailing_space_and_joins_rows() {
        let buf = ratatui::buffer::Buffer::with_lines(["ab  ", "cd"]);
        assert_eq!(screen_to_text(&buf), "ab\ncd\n");
    }

    #[test]
    fn plugin_command_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let ipc = Ipc::init(dir.path()).unwrap();
        let mut app = App::new(dir.path().to_path_buf(), Config::default()).unwrap();

        apply(
            &mut app,
            &IpcCommand::RegisterCommand {
                id: "plugin.x".into(),
                title: "X".into(),
                group: "plugin".into(),
                keys: vec![],
            },
        );
        assert!(app.dynamic_commands.iter().any(|c| c.id == "plugin.x"));

        // Invoke it the way a keybinding/palette would.
        assert!(crate::command::run("plugin.x", &mut app));
        drain_plugin_events(&ipc, &mut app);

        let log = std::fs::read_to_string(dir.path().join(".mnml/ipc/events.jsonl")).unwrap();
        assert!(log.contains(r#""event":"plugin-command""#), "log: {log}");
        assert!(log.contains(r#""id":"plugin.x""#), "log: {log}");
    }
}
