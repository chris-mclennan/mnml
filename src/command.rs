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
            title: "Toggle file tree (rail on/off)",
            group: "view",
            keys: &["ctrl+b"],
            run: |app| app.toggle_tree_visibility(),
        },
        Command {
            id: "view.toggle_tree_section",
            title: "Toggle workspace section (collapse/expand the file list)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_tree_root_expanded(),
        },
        Command {
            id: "view.zen",
            title: "Zen mode (hide tree + bufferline + statusline)",
            group: "view",
            keys: &["ctrl+shift+z"],
            run: |app| app.toggle_zen_mode(),
        },
        Command {
            id: "view.redraw",
            title: "Force a full redraw (clears the terminal)",
            group: "view",
            keys: &["ctrl+l"],
            run: |app| {
                app.redraw_requested = true;
            },
        },
        Command {
            id: "view.toggle_relative_numbers",
            title: "Toggle relative line numbers",
            group: "view",
            keys: &[],
            run: |app| app.toggle_relative_line_numbers(),
        },
        Command {
            id: "view.toggle_whitespace",
            title: "Toggle visible whitespace markers (· / →)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_show_whitespace(),
        },
        Command {
            id: "view.toggle_bracket_rainbow",
            title: "Toggle rainbow brackets (depth-cycling color on ()[]{})",
            group: "view",
            keys: &[],
            run: |app| app.toggle_bracket_rainbow(),
        },
        Command {
            id: "view.close_others",
            title: "Close all other panes (keep active; respects unsaved guards)",
            group: "view",
            keys: &[],
            run: |app| app.close_other_panes(),
        },
        Command {
            id: "view.toggle_scrollbar",
            title: "Toggle the editor scrollbar (right-edge thumb)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_scrollbar(),
        },
        Command {
            id: "view.toggle_highlight_trailing_ws",
            title: "Toggle trailing-whitespace highlight (red bg on trailing space/tab)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_highlight_trailing_ws(),
        },
        Command {
            id: "view.toggle_highlight_word",
            title: "Toggle 'highlight other occurrences of word under cursor'",
            group: "view",
            keys: &[],
            run: |app| app.toggle_highlight_word_under_cursor(),
        },
        Command {
            id: "browser.toggle_headless",
            title: "Toggle CDP headless launch (takes effect on next browser.open)",
            group: "browser",
            keys: &[],
            run: |app| app.toggle_browser_headless(),
        },
        Command {
            id: "find.find",
            title: "Find in buffer",
            group: "find",
            keys: &["ctrl+f"],
            run: |app| app.open_find_prompt(),
        },
        Command {
            id: "find.next",
            title: "Find: next match",
            group: "find",
            keys: &["f3"],
            run: |app| app.find_next(),
        },
        Command {
            id: "find.prev",
            title: "Find: previous match",
            group: "find",
            keys: &["shift+f3"],
            run: |app| app.find_prev(),
        },
        Command {
            id: "find.toggle_regex",
            title: "Find: toggle regex mode (sticky)",
            group: "find",
            keys: &["alt+r"],
            run: |app| app.toggle_find_regex(),
        },
        Command {
            id: "find.word_forward",
            title: "Find: word under cursor (forward) — vim `*`",
            group: "find",
            keys: &[],
            run: |app| app.find_word_under_cursor(true),
        },
        Command {
            id: "find.word_backward",
            title: "Find: word under cursor (backward) — vim `#`",
            group: "find",
            keys: &[],
            run: |app| app.find_word_under_cursor(false),
        },
        Command {
            id: "find.replace",
            title: "Replace every match of the active find",
            group: "find",
            keys: &["ctrl+h"],
            run: |app| app.open_replace_prompt(),
        },
        Command {
            id: "find.grep",
            title: "Grep workspace (rg / git grep) → results pane",
            group: "find",
            keys: &["ctrl+shift+f"],
            run: |app| app.open_grep_prompt(),
        },
        Command {
            id: "find.grep_replace",
            title: "Replace every grep hit across every file (active grep pane)",
            group: "find",
            keys: &[],
            run: |app| app.open_grep_replace_prompt(),
        },
        Command {
            id: "find.clear",
            title: "Find: clear highlights",
            group: "find",
            keys: &[],
            run: |app| app.clear_find(),
        },
        Command {
            id: "editor.goto_line",
            title: "Go to line… (1-based)",
            group: "editor",
            keys: &["ctrl+g"],
            run: |app| app.open_goto_line_prompt(),
        },
        Command {
            id: "editor.bracket_match",
            title: "Jump to matching bracket",
            group: "editor",
            keys: &["ctrl+]"],
            run: |app| app.bracket_match_jump(),
        },
        Command {
            id: "editor.delete_line",
            title: "Delete the current line (VSCode `Ctrl+Shift+K`)",
            group: "editor",
            keys: &["ctrl+shift+k"],
            run: |app| {
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::DeleteLine],
                        &mut crate::clipboard::Clipboard::new(),
                        0,
                    );
                }
            },
        },
        Command {
            id: "editor.toggle_fold",
            title: "Toggle fold at cursor (vim `za`-ish)",
            group: "editor",
            keys: &[],
            run: |app| app.toggle_fold_at_cursor(),
        },
        Command {
            id: "editor.unfold_all",
            title: "Unfold every fold in the active buffer (vim `zR`-ish)",
            group: "editor",
            keys: &[],
            run: |app| app.unfold_all_in_active(),
        },
        Command {
            id: "editor.open_at_cursor",
            title: "Open path under cursor (supports `:line:col`)",
            group: "editor",
            keys: &["ctrl+shift+o"],
            run: |app| app.open_path_at_cursor(),
        },
        Command {
            id: "file.new",
            title: "New file… (workspace-relative path)",
            group: "file",
            keys: &["ctrl+n"],
            run: |app| {
                let ws = app.workspace.clone();
                app.open_new_file_prompt(ws);
            },
        },
        Command {
            id: "file.reload",
            title: "Reload active buffer from disk (refuses if dirty)",
            group: "file",
            keys: &[],
            run: |app| app.reload_active(false),
        },
        Command {
            id: "file.open_settings",
            title: "Open mnml config (creates the file if missing)",
            group: "file",
            keys: &["ctrl+,"],
            run: |app| app.open_settings(),
        },
        Command {
            id: "nav.back",
            title: "Go back (previous cursor / file)",
            group: "go",
            keys: &["alt+left"],
            run: |app| app.nav_back_jump(),
        },
        Command {
            id: "nav.forward",
            title: "Go forward (undo an Alt+Left)",
            group: "go",
            keys: &["alt+right"],
            run: |app| app.nav_forward_jump(),
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
            id: "picker.recent",
            title: "Recent files",
            group: "picker",
            keys: &["ctrl+r"],
            run: |app| app.open_recent_files_picker(),
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
            id: "buffer.reopen",
            title: "Re-open the most-recently-closed buffer",
            group: "buffer",
            keys: &["ctrl+shift+t"],
            run: |app| app.reopen_closed_buffer(),
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
            id: "git.peek_change",
            title: "Git: peek change at cursor (popup of HEAD diff)",
            group: "git",
            keys: &[],
            run: |app| app.peek_git_change_at_cursor(),
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
            id: "git.ai_recompose",
            title: "Git: rewrite HEAD's message with Claude (--amend)",
            group: "git",
            keys: &[],
            run: |app| app.request_ai_recompose_message(),
        },
        Command {
            id: "flaky.show",
            title: "Test: flaky-test dashboard (wobbly tests from history)",
            group: "test",
            keys: &[],
            run: |app| app.open_flaky_pane(),
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
            id: "lsp.completion",
            title: "LSP: complete at cursor (→ picker)",
            group: "lsp",
            keys: &["ctrl+space"],
            run: |app| app.lsp_completion(),
        },
        Command {
            id: "lsp.signature_help",
            title: "LSP: signature help (param info popup at cursor)",
            group: "lsp",
            keys: &[],
            run: |app| app.request_signature_help_at_cursor(),
        },
        Command {
            id: "lsp.rename",
            title: "LSP: rename symbol",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_rename(),
        },
        Command {
            id: "lsp.format",
            title: "LSP: format document",
            group: "lsp",
            keys: &["ctrl+shift+i"],
            run: |app| app.lsp_format(),
        },
        Command {
            id: "lsp.code_action",
            title: "LSP: code actions at cursor (→ picker)",
            group: "lsp",
            keys: &["ctrl+."],
            run: |app| app.lsp_code_action(),
        },
        Command {
            id: "lsp.symbols",
            title: "LSP: symbols in this file (→ picker)",
            group: "lsp",
            keys: &["ctrl+shift+o"],
            run: |app| app.lsp_symbols(),
        },
        Command {
            id: "lsp.workspace_symbols",
            title: "LSP: workspace symbols — search across the project",
            group: "lsp",
            // No global default key — `Ctrl+T` is `term.shell`. Use `<leader>l S`.
            keys: &[],
            run: |app| app.lsp_workspace_symbols(),
        },
        Command {
            id: "outline.show",
            title: "LSP: outline pane (symbols sidebar for this file)",
            group: "lsp",
            keys: &[],
            run: |app| app.open_outline_pane(),
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
            id: "snippet.expand",
            title: "Snippet: expand trigger word at cursor",
            group: "edit",
            keys: &["ctrl+j"],
            run: |app| app.snippet_expand_at_cursor(),
        },
        Command {
            id: "snippet.pick",
            title: "Snippet: insert from picker",
            group: "edit",
            keys: &[],
            run: |app| app.snippet_pick(),
        },
        Command {
            id: "snippet.next_placeholder",
            title: "Snippet: jump to next placeholder",
            group: "edit",
            // Tab is reserved for indent/insert in the editor — the binding
            // is intercepted directly in `tui::dispatch_key` while a session
            // is active; this entry is here so the palette can see it (and
            // so future remapping in `[keys.*]` is straightforward).
            keys: &[],
            run: |app| app.snippet_next_placeholder(),
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
            id: "rqst.copy_response_body",
            title: "HTTP: copy the response body",
            group: "http",
            keys: &[],
            run: |app| app.copy_active_response_body(),
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
            id: "browser.open",
            title: "Browser: open Chrome (CDP) — console / nav / eval",
            group: "browser",
            keys: &[],
            run: |app| app.open_browser_prompt(),
        },
        Command {
            id: "browser.screenshot",
            title: "Browser: screenshot the page → .mnml/screenshots/",
            group: "browser",
            keys: &[],
            run: |app| app.browser_screenshot(),
        },
        Command {
            id: "browser.dom",
            title: "Browser: open the DOM panel (selectable nodes, copy selector)",
            group: "browser",
            keys: &[],
            run: |app| app.browser_open_dom(),
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
