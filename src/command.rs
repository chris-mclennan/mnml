//! The command registry — the spine the palette, which-key, keybindings, and
//! (later) plugins all hang off of. Every non-text-editing action is a named
//! [`Command`]. P0 ships a small builtin set; the registry is a process-global
//! `OnceLock` (the builtin commands never change; dynamic/plugin commands get a
//! `Mutex` when that track lands).
//!
//! Default keybindings live here as `keys: &[&str]` (parsed by
//! `input::keymap::Keymap`). User `[keys.*]` config overlays them. A command may
//! list several keyspecs — e.g. the palette is `ctrl+shift+p` *and* `f1`, because
//! legacy terminals can't transmit the former.

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
    /// Default keyspecs (`"ctrl+q"`, `"f1"`, `"ctrl+shift+p"`, …). May be empty
    /// (palette-only). `input::keymap::Keymap` parses these; `[keys.*]` overlays.
    pub keys: &'static [&'static str],
    pub run: CommandFn,
}

impl Command {
    /// A short human-readable hint for the palette (`"ctrl+shift+p / f1"` or `""`).
    pub fn key_hint(&self) -> String {
        self.keys.join(" / ")
    }
}

/// A command registered at runtime by an out-of-process plugin (over the file-IPC
/// channel — see `ipc::IpcCommand::RegisterCommand`). Invoking it doesn't call
/// Rust code; it appends a `{"event":"plugin-command","id":…}` line the plugin
/// reads. Lives on `App` (not the static [`Registry`]) since it's per-session.
#[derive(Debug, Clone)]
pub struct DynCommand {
    pub id: String,
    pub title: String,
    pub group: String,
    /// Keyspecs to bind (best-effort — bad specs are ignored). May be empty.
    pub keys: Vec<String>,
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

/// Run a command by id against `app`. Builtins call their Rust handler; a
/// plugin-registered (`DynCommand`) id is queued for the IPC layer to report.
/// Returns false if the id matches neither.
pub fn run(id: &str, app: &mut App) -> bool {
    if let Some(cmd) = registry().get(id) {
        (cmd.run)(app);
        return true;
    }
    if app.run_dynamic_command(id) {
        return true;
    }
    app.toast(format!("no such command: {id}"));
    false
}

fn builtin_commands() -> Vec<Command> {
    vec![
        Command {
            id: "app.quit",
            title: "Quit mnml",
            group: "app",
            keys: &["ctrl+q"],
            run: |app| app.request_quit(),
        },
        Command {
            id: "app.restart",
            title: "Restart mnml (rebuild + relaunch via run.sh)",
            group: "app",
            keys: &[],
            run: |app| app.request_restart(),
        },
        Command {
            id: "view.toggle_tree",
            title: "Toggle file tree",
            group: "view",
            keys: &["ctrl+b"],
            run: |app| app.tree_visible = !app.tree_visible,
        },
        Command {
            id: "focus.cycle",
            title: "Cycle focus (tree ⇄ editor)",
            group: "view",
            keys: &["ctrl+e"],
            run: |app| app.cycle_focus(),
        },
        Command {
            id: "file.save",
            title: "Save file",
            group: "file",
            keys: &["ctrl+s"],
            run: |app| app.save_active(),
        },
        Command {
            id: "file.save_all",
            title: "Save all files",
            group: "file",
            keys: &[],
            run: |app| app.save_all(),
        },
        Command {
            id: "picker.files",
            title: "Open file…",
            group: "go",
            keys: &["ctrl+p"],
            run: |app| app.open_file_picker(),
        },
        Command {
            id: "picker.buffers",
            title: "Switch buffer…",
            group: "go",
            keys: &[],
            run: |app| app.open_buffer_picker(),
        },
        Command {
            id: "palette",
            title: "Command palette",
            group: "go",
            // `ctrl+shift+p` only arrives distinct under the kitty keyboard
            // protocol; `f1` is the terminal-proof fallback (also a VSCode binding).
            keys: &["ctrl+shift+p", "f1"],
            run: |app| app.open_command_palette(),
        },
        Command {
            id: "buffer.close",
            title: "Close buffer",
            group: "buffer",
            keys: &["ctrl+w"],
            run: |app| app.close_active_pane(),
        },
        Command {
            id: "buffer.next",
            title: "Next buffer",
            group: "buffer",
            keys: &["ctrl+pagedown"],
            run: |app| app.next_buffer(),
        },
        Command {
            id: "buffer.prev",
            title: "Previous buffer",
            group: "buffer",
            keys: &["ctrl+pageup"],
            run: |app| app.prev_buffer(),
        },
        Command {
            id: "tree.refresh",
            title: "Refresh file tree",
            group: "view",
            keys: &[],
            run: |app| app.tree.refresh(),
        },
        Command {
            id: "editor.use_vim",
            title: "Editing: use vim keymap",
            group: "editor",
            keys: &[],
            run: |app| app.set_input_style("vim"),
        },
        Command {
            id: "editor.use_standard",
            title: "Editing: use standard (VSCode) keymap",
            group: "editor",
            keys: &[],
            run: |app| app.set_input_style("standard"),
        },
        Command {
            id: "editor.toggle_keymap",
            title: "Editing: toggle vim ⇄ standard keymap",
            group: "editor",
            keys: &[],
            run: |app| app.toggle_input_style(),
        },
        Command {
            id: "theme.pick",
            title: "Pick theme…",
            group: "view",
            keys: &[],
            run: |app| app.open_theme_picker(),
        },
        Command {
            id: "markdown.preview",
            title: "Markdown: open rendered preview (split)",
            group: "view",
            keys: &[],
            run: |app| app.open_md_preview(),
        },
        Command {
            id: "git.diff_file",
            title: "Git: diff this file (split)",
            group: "git",
            keys: &[],
            run: |app| app.open_diff_file(),
        },
        Command {
            id: "git.diff",
            title: "Git: diff the worktree",
            group: "git",
            keys: &[],
            run: |app| app.open_diff_worktree(),
        },
        Command {
            id: "git.blame_toggle",
            title: "Git: toggle blame gutter",
            group: "git",
            keys: &[],
            run: |app| app.toggle_blame(),
        },
        Command {
            id: "git.commit",
            title: "Git: commit staged changes",
            group: "git",
            keys: &[],
            run: |app| app.open_commit_prompt(),
        },
        Command {
            id: "git.graph",
            title: "Git: commit graph (DAG browser)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph(),
        },
        Command {
            id: "git.status_pane",
            title: "Git: status / staging view",
            group: "git",
            keys: &[],
            run: |app| app.open_git_status(),
        },
        Command {
            id: "git.ai_commit",
            title: "Git: write a commit message with Claude (from the staged diff)",
            group: "git",
            keys: &[],
            run: |app| app.request_ai_commit_message(),
        },
        Command {
            id: "git.checkout",
            title: "Git: checkout a branch (local or remote)",
            group: "git",
            keys: &[],
            run: |app| app.open_branch_picker(),
        },
        Command {
            id: "git.new_branch",
            title: "Git: create a new branch",
            group: "git",
            keys: &[],
            run: |app| app.open_new_branch_prompt(),
        },
        Command {
            id: "git.worktrees",
            title: "Git: worktrees → open a shell in one",
            group: "git",
            keys: &[],
            run: |app| app.open_worktree_picker(),
        },
        Command {
            id: "lsp.goto_definition",
            title: "LSP: go to definition",
            group: "lsp",
            keys: &["f12"],
            run: |app| app.lsp_goto_definition(),
        },
        Command {
            id: "lsp.hover",
            title: "LSP: hover (docs at cursor)",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_hover(),
        },
        Command {
            id: "lsp.references",
            title: "LSP: find references (→ picker)",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_references(),
        },
        Command {
            id: "lsp.diagnostics",
            title: "LSP: diagnostics list (project problems)",
            group: "lsp",
            keys: &[],
            run: |app| app.open_diagnostics_pane(),
        },
        Command {
            id: "lsp.next_diagnostic",
            title: "LSP: next diagnostic",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_goto_diagnostic(true),
        },
        Command {
            id: "lsp.prev_diagnostic",
            title: "LSP: previous diagnostic",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_goto_diagnostic(false),
        },
        Command {
            id: "rqst.send",
            title: "HTTP: send request (.http/.curl) — or re-fire a request pane",
            group: "http",
            // No global default key (`Ctrl+R` is vim's redo). Use `<leader>h s` or
            // the palette; a request pane also re-fires with its own `r` key.
            keys: &[],
            run: |app| app.send_request_from_active(),
        },
        Command {
            id: "rqst.copy_curl",
            title: "HTTP: copy the request as a curl command",
            group: "http",
            keys: &[],
            run: |app| app.copy_active_curl(),
        },
        Command {
            id: "rqst.ai_debug",
            title: "HTTP: ask Claude why this request is failing",
            group: "http",
            keys: &[],
            run: |app| app.ai_debug_request(),
        },
        Command {
            id: "term.shell",
            title: "Terminal: open a shell (split below)",
            group: "ai",
            keys: &["ctrl+t"],
            run: |app| app.open_shell(),
        },
        Command {
            id: "ai.claude_code",
            title: "AI: open Claude Code (split below)",
            group: "ai",
            // No global key — `Ctrl+Shift+A` isn't distinguishable in most terminals; use `<leader>a c`.
            keys: &[],
            run: |app| app.open_claude_code(),
        },
        Command {
            id: "ai.codex",
            title: "AI: open Codex (split below)",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex(),
        },
        Command {
            id: "ai.ask",
            title: "AI: ask Claude a question (claude -p)",
            group: "ai",
            keys: &[],
            run: |app| app.open_ai_ask_prompt(),
        },
        Command {
            id: "ai.explain",
            title: "AI: explain the selection (or this file)",
            group: "ai",
            keys: &[],
            run: |app| app.ai_action("explain"),
        },
        Command {
            id: "ai.fix",
            title: "AI: find & fix bugs in the selection (or this file)",
            group: "ai",
            keys: &[],
            run: |app| app.ai_action("fix"),
        },
        Command {
            id: "ai.refactor",
            title: "AI: refactor the selection (or this file)",
            group: "ai",
            keys: &[],
            run: |app| app.ai_action("refactor"),
        },
        Command {
            id: "ai.write_tests",
            title: "AI: write tests for the selection (or this file)",
            group: "ai",
            keys: &[],
            run: |app| app.ai_action("write_tests"),
        },
        Command {
            id: "ai.session_view",
            title: "AI: mirror this Claude session's transcript (live)",
            group: "ai",
            keys: &[],
            run: |app| app.open_session_view(),
        },
        Command {
            id: "test.run_all",
            title: "Tests: run the whole Playwright suite",
            group: "test",
            keys: &[],
            run: |app| app.run_tests_all(),
        },
        Command {
            id: "test.run_file",
            title: "Tests: run this spec file",
            group: "test",
            keys: &[],
            run: |app| app.run_tests_file(),
        },
        Command {
            id: "test.run_at_cursor",
            title: "Tests: run the test at the cursor",
            group: "test",
            keys: &[],
            run: |app| app.run_tests_at_cursor(),
        },
        Command {
            id: "test.rerun_failed",
            title: "Tests: re-run last-failed (Playwright --last-failed)",
            group: "test",
            keys: &[],
            run: |app| app.rerun_failed_tests(),
        },
        Command {
            id: "test.heal",
            title: "Tests: ask Claude to fix the highlighted failing test",
            group: "test",
            keys: &[],
            run: |app| app.heal_selected_test(),
        },
        Command {
            id: "task.run",
            title: "Tasks: run a configured task in a terminal pane",
            group: "ai",
            keys: &[],
            run: |app| app.open_task_picker(),
        },
        Command {
            id: "whichkey.leader",
            title: "Leader menu (which-key)",
            group: "view",
            // `<space>` in vim Normal also opens this (the vim handler routes it).
            keys: &["ctrl+k"],
            run: |app| app.open_whichkey(),
        },
        Command {
            id: "view.split_right",
            title: "Split editor right (side by side)",
            group: "view",
            keys: &[],
            run: |app| app.split_active(crate::layout::SplitDir::Horizontal),
        },
        Command {
            id: "view.split_down",
            title: "Split editor down (stacked)",
            group: "view",
            keys: &[],
            run: |app| app.split_active(crate::layout::SplitDir::Vertical),
        },
        Command {
            id: "view.focus_left",
            title: "Focus split left",
            group: "view",
            keys: &[],
            run: |app| app.focus_dir(crate::app::FocusDir::Left),
        },
        Command {
            id: "view.focus_right",
            title: "Focus split right",
            group: "view",
            keys: &[],
            run: |app| app.focus_dir(crate::app::FocusDir::Right),
        },
        Command {
            id: "view.focus_up",
            title: "Focus split up",
            group: "view",
            keys: &[],
            run: |app| app.focus_dir(crate::app::FocusDir::Up),
        },
        Command {
            id: "view.focus_down",
            title: "Focus split down",
            group: "view",
            keys: &[],
            run: |app| app.focus_dir(crate::app::FocusDir::Down),
        },
        Command {
            id: "view.focus_next_split",
            title: "Focus next split",
            group: "view",
            keys: &[],
            run: |app| app.focus_next_split(),
        },
        Command {
            id: "view.close_split",
            title: "Close split / buffer",
            group: "view",
            keys: &[],
            run: |app| app.close_active_pane(),
        },
    ]
}
