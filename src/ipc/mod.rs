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
}

#[derive(Debug)]
pub enum IpcCommand {
    /// Open a file (path relative to the workspace, or absolute).
    Open(PathBuf),
    /// Inject a key by spec (e.g. `"ctrl+q"`, `"down"`, `"enter"`).
    Key(String),
    /// Force a fresh dump of `screen.txt` / `status.json`.
    Snapshot,
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
}

impl Ipc {
    /// Create `.mnml/ipc/` and (re)initialize its files for a fresh session.
    pub fn init(workspace: &Path) -> io::Result<Ipc> {
        let dir = workspace.join(".mnml").join("ipc");
        std::fs::create_dir_all(&dir)?;
        let cmd_path = dir.join("command");
        let screen_path = dir.join("screen.txt");
        let status_path = dir.join("status.json");
        let events_path = dir.join("events.jsonl");
        // Truncate the command channel + events log so we start clean.
        std::fs::write(&cmd_path, b"")?;
        std::fs::write(&events_path, b"")?;
        std::fs::write(&screen_path, b"")?;
        std::fs::write(&status_path, b"{}")?;
        Ok(Ipc {
            dir,
            cmd_path,
            screen_path,
            status_path,
            events_path,
            cmd_offset: 0,
        })
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
    pub fn append_event(&self, json_line: &str) {
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
        "snapshot" => IpcCommand::Snapshot,
        "quit" => IpcCommand::Quit,
        "restart" => IpcCommand::Restart,
        _ => IpcCommand::Unknown(line.to_string()),
    }
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
            if let Some(ev) = parse_key_spec(spec) {
                crate::tui::dispatch_key(app, ev);
                json_event(&[("event", "key"), ("key", spec)])
            } else {
                json_event(&[("event", "key_unparsed"), ("key", spec)])
            }
        }
        IpcCommand::Snapshot => json_event(&[("event", "snapshot")]),
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
    format!(
        "{{\"focus\":{},\"activePane\":{},\"activeFile\":{},\"cursor\":{{\"line\":{},\"col\":{}}},\"mode\":{},\"treeCursor\":{},\"treeSelection\":{},\"treeVisible\":{},\"panes\":[{}],\"quit\":{}}}",
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
