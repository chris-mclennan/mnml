//! The command registry — the spine the palette, which-key, keybindings, and
//! (later) plugins all hang off of. Every non-text-editing action is a named
//! [`Command`]. P0 ships a small builtin set; the registry is a process-global
//! `OnceLock` (the builtin commands never change; dynamic/plugin commands get a
//! `Mutex` when that track lands).

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::app::App;

pub type CommandFn = fn(&mut App);

#[derive(Clone)]
pub struct Command {
    pub id: &'static str,
    pub title: &'static str,
    /// Which-key group / palette section (e.g. `"file"`, `"view"`, `"git"`).
    pub group: &'static str,
    /// A human-readable default binding hint shown in the palette (the actual
    /// resolution table is built from `[keys.*]` config later).
    pub default_key: &'static str,
    pub run: CommandFn,
}

pub struct Registry {
    commands: Vec<Command>,
    by_id: HashMap<&'static str, usize>,
}

impl Registry {
    fn build() -> Self {
        let commands = builtin_commands();
        let by_id = commands
            .iter()
            .enumerate()
            .map(|(i, c)| (c.id, i))
            .collect();
        Registry { commands, by_id }
    }

    pub fn get(&self, id: &str) -> Option<&Command> {
        self.by_id.get(id).map(|&i| &self.commands[i])
    }

    pub fn all(&self) -> &[Command] {
        &self.commands
    }
}

/// The process-global registry.
pub fn registry() -> &'static Registry {
    static R: OnceLock<Registry> = OnceLock::new();
    R.get_or_init(Registry::build)
}

/// Run a command by id against `app`. Returns false if the id is unknown.
pub fn run(id: &str, app: &mut App) -> bool {
    match registry().get(id) {
        Some(cmd) => {
            (cmd.run)(app);
            true
        }
        None => {
            app.toast(format!("no such command: {id}"));
            false
        }
    }
}

fn builtin_commands() -> Vec<Command> {
    vec![
        Command {
            id: "app.quit",
            title: "Quit mnml",
            group: "app",
            default_key: "ctrl+q",
            run: |app| app.request_quit(),
        },
        Command {
            id: "app.restart",
            title: "Restart mnml (rebuild + relaunch via run.sh)",
            group: "app",
            default_key: "",
            run: |app| app.request_restart(),
        },
        Command {
            id: "view.toggle_tree",
            title: "Toggle file tree",
            group: "view",
            default_key: "ctrl+b",
            run: |app| app.tree_visible = !app.tree_visible,
        },
        Command {
            id: "focus.cycle",
            title: "Cycle focus (tree ⇄ editor)",
            group: "view",
            default_key: "ctrl+e",
            run: |app| app.cycle_focus(),
        },
        Command {
            id: "file.save",
            title: "Save file",
            group: "file",
            default_key: "ctrl+s",
            run: |app| app.save_active(),
        },
        Command {
            id: "file.save_all",
            title: "Save all files",
            group: "file",
            default_key: "",
            run: |app| app.save_all(),
        },
        Command {
            id: "buffer.close",
            title: "Close buffer",
            group: "buffer",
            default_key: "",
            run: |app| app.close_active_pane(),
        },
        Command {
            id: "buffer.next",
            title: "Next buffer",
            group: "buffer",
            default_key: "",
            run: |app| app.next_buffer(),
        },
        Command {
            id: "buffer.prev",
            title: "Previous buffer",
            group: "buffer",
            default_key: "",
            run: |app| app.prev_buffer(),
        },
        Command {
            id: "tree.refresh",
            title: "Refresh file tree",
            group: "view",
            default_key: "",
            run: |app| app.tree.refresh(),
        },
    ]
}
