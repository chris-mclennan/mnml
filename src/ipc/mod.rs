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
}

#[derive(Debug)]
pub enum IpcCommand {
    /// Open a file (path relative to the workspace, or absolute).
    Open(PathBuf),
    /// Inject a key by spec (e.g. `"ctrl+q"`, `"down"`, `"enter"`).
    Key(String),
    /// Type literal text into the focused pane, char by char (`\n` ⇒ Enter).
    Type(String),
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

/// Write the current `screen.txt` + `status.json`. Both frontends call this
/// after rendering — headless reads `TestBackend::buffer()`, the terminal loop
/// reads `Terminal::current_buffer_mut()`.
pub fn dump_screen_status(ipc: &Ipc, screen: &ratatui::buffer::Buffer, app: &App) {
    ipc.write_screen(&screen_to_text(screen));
    ipc.write_status(&status_json(app));
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
        assert!(matches!(parse_command(r#"{"cmd":"bogus"}"#), Unknown(_)));
        // Malformed JSON ⇒ Unknown, never a panic.
        assert!(matches!(parse_command("not json at all"), Unknown(_)));
        assert!(matches!(parse_command("{"), Unknown(_)));
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
