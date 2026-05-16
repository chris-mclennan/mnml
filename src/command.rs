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
    let ok = if let Some(cmd) = registry().get(id) {
        (cmd.run)(app);
        true
    } else if app.run_dynamic_command(id) {
        true
    } else {
        app.toast(format!("no such command: {id}"));
        false
    };
    if ok {
        // Track for the recent-commands picker. Skip the recent-picker
        // command itself so it doesn't dominate its own list, and skip
        // self-referential `vim.dot_repeat` / `vim.macro_replay` to keep
        // the recents focused on user intent.
        if !matches!(
            id,
            "picker.recent_commands" | "vim.dot_repeat" | "vim.macro_replay" | "palette"
        ) {
            app.note_recent_command(id);
        }
    }
    ok
}

fn builtin_commands() -> Vec<Command> {
    #[allow(unused_mut)]
    let mut cmds = vec![
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
            id: "view.focus_tree",
            title: "Focus the file tree (without toggling)",
            group: "view",
            // VSCode convention. `Ctrl+B` toggles tree visibility; this just
            // moves focus there (and forces it visible if it was hidden).
            keys: &["ctrl+shift+e"],
            run: |app| {
                app.tree_visible = true;
                app.focus_tree();
            },
        },
        Command {
            id: "view.about",
            title: "About mnml — version + key state snapshot",
            group: "view",
            keys: &[],
            run: |app| app.show_about(),
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
            id: "view.toggle_breadcrumb",
            title: "Toggle the editor breadcrumb row (path above each pane)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_breadcrumb(),
        },
        Command {
            id: "editor.toggle_auto_pair",
            title: "Toggle bracket / quote auto-pairing",
            group: "editor",
            keys: &[],
            run: |app| app.toggle_auto_pair(),
        },
        Command {
            id: "view.toggle_auto_md_preview",
            title: "Toggle auto-open markdown preview on file open",
            group: "view",
            keys: &[],
            run: |app| {
                app.config.ui.auto_md_preview = !app.config.ui.auto_md_preview;
                let on = app.config.ui.auto_md_preview;
                app.toast(format!(
                    "auto-preview md: {}",
                    if on { "on" } else { "off" }
                ));
            },
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
            id: "view.toggle_color_column",
            title: "Toggle line-length color column (vim :set cc=80)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_color_column(),
        },
        Command {
            id: "view.toggle_wrap",
            title: "Toggle line wrapping (vim :set wrap)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_wrap(),
        },
        Command {
            id: "view.toggle_bufferline",
            title: "Toggle bufferline (open-tabs strip)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_bufferline(),
        },
        Command {
            id: "view.toggle_todo_highlight",
            title: "Toggle TODO/FIXME/HACK/XXX keyword highlight",
            group: "view",
            keys: &[],
            run: |app| app.toggle_todo_highlight(),
        },
        Command {
            id: "project.next_todo",
            title: "Jump to next TODO / FIXME / HACK / XXX (vim ]t)",
            group: "project",
            keys: &[],
            run: |app| app.jump_todo(true),
        },
        Command {
            id: "project.prev_todo",
            title: "Jump to previous TODO / FIXME / HACK / XXX (vim [t)",
            group: "project",
            keys: &[],
            run: |app| app.jump_todo(false),
        },
        Command {
            id: "view.cmdline_history",
            title: "Open cmdline-history pane (vim q:)",
            group: "view",
            keys: &[],
            run: |app| app.open_cmdline_history(),
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
            id: "find.selection_forward",
            title: "Find: selected text (forward) — vim visual `*`",
            group: "find",
            keys: &[],
            run: |app| app.find_selection_under_cursor(true),
        },
        Command {
            id: "find.selection_backward",
            title: "Find: selected text (backward) — vim visual `#`",
            group: "find",
            keys: &[],
            run: |app| app.find_selection_under_cursor(false),
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
            id: "editor.add_cursor_below",
            title: "Add cursor on the line below (VSCode `Ctrl+Alt+Down`)",
            group: "editor",
            keys: &["ctrl+alt+down", "ctrl+alt+j"],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::AddCursorBelow),
        },
        Command {
            id: "editor.add_cursor_above",
            title: "Add cursor on the line above (VSCode `Ctrl+Alt+Up`)",
            group: "editor",
            keys: &["ctrl+alt+up", "ctrl+alt+k"],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::AddCursorAbove),
        },
        Command {
            id: "editor.clear_extra_cursors",
            title: "Drop all extra cursors (keep the primary)",
            group: "editor",
            keys: &[],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::ClearExtraCursors),
        },
        Command {
            id: "editor.add_cursor_at_next_word",
            title: "Add cursor at next occurrence of word (VSCode `Ctrl+D`)",
            group: "editor",
            // `Ctrl+D` for standard mode (VS Code muscle memory); the vim
            // handler intercepts Ctrl+D as HalfPageDown before the keymap
            // sees it, so vim users aren't affected.
            keys: &["ctrl+d"],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::AddCursorAtNextWord),
        },
        Command {
            id: "editor.select_all_occurrences",
            title: "Select all occurrences of word at cursor (VSCode `Ctrl+Shift+L`)",
            group: "editor",
            keys: &["ctrl+shift+l"],
            run: |app| app.select_all_occurrences(),
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
            id: "lsp.fold_all",
            title: "LSP: fold all (server-suggested ranges)",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_fold_all(),
        },
        Command {
            id: "lsp.selection_expand",
            title: "LSP: expand selection to next semantic range",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_selection_expand(),
        },
        Command {
            id: "lsp.selection_shrink",
            title: "LSP: shrink selection to previous semantic range",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_selection_shrink(),
        },
        Command {
            id: "lsp.highlight_symbol",
            title: "LSP: highlight all usages of symbol at cursor",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_highlight_symbol(),
        },
        Command {
            id: "lsp.clear_highlights",
            title: "LSP: clear symbol highlights",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_clear_highlights(),
        },
        Command {
            id: "lsp.incoming_calls",
            title: "LSP: incoming calls (who calls this)",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_incoming_calls(),
        },
        Command {
            id: "lsp.outgoing_calls",
            title: "LSP: outgoing calls (what this calls)",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_outgoing_calls(),
        },
        Command {
            id: "lsp.supertypes",
            title: "LSP: supertypes of type at cursor",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_supertypes(),
        },
        Command {
            id: "lsp.subtypes",
            title: "LSP: subtypes of type at cursor",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_subtypes(),
        },
        Command {
            id: "editor.reflow_paragraph",
            title: "Reflow current paragraph to text_width (vim `gqq`)",
            group: "editor",
            keys: &[],
            run: |app| app.reflow_paragraph_at_cursor(),
        },
        Command {
            id: "view.cursor_to_center",
            title: "Scroll cursor to viewport center (vim `zz`)",
            group: "view",
            keys: &[],
            run: |app| app.scroll_cursor_in_view(0.5),
        },
        Command {
            id: "view.cursor_to_top",
            title: "Scroll cursor to viewport top (vim `zt`)",
            group: "view",
            keys: &[],
            run: |app| app.scroll_cursor_in_view(0.0),
        },
        Command {
            id: "view.cursor_to_bottom",
            title: "Scroll cursor to viewport bottom (vim `zb`)",
            group: "view",
            keys: &[],
            run: |app| app.scroll_cursor_in_view(1.0),
        },
        Command {
            id: "view.move_cursor_view_top",
            title: "Move cursor to top of viewport (vim `H`)",
            group: "view",
            keys: &[],
            run: |app| app.move_cursor_in_view(0.0),
        },
        Command {
            id: "view.move_cursor_view_middle",
            title: "Move cursor to middle of viewport (vim `M`)",
            group: "view",
            keys: &[],
            run: |app| app.move_cursor_in_view(0.5),
        },
        Command {
            id: "view.move_cursor_view_bottom",
            title: "Move cursor to bottom of viewport (vim `L`)",
            group: "view",
            keys: &[],
            run: |app| app.move_cursor_in_view(1.0),
        },
        Command {
            id: "view.scroll_buffer_down",
            title: "Scroll buffer one line down (vim `Ctrl+E`)",
            group: "view",
            keys: &[],
            run: |app| app.scroll_buffer(1),
        },
        Command {
            id: "view.scroll_buffer_up",
            title: "Scroll buffer one line up (vim `Ctrl+Y`)",
            group: "view",
            keys: &[],
            run: |app| app.scroll_buffer(-1),
        },
        Command {
            id: "view.hscroll_left",
            title: "Scroll viewport one column left (vim `zh`)",
            group: "view",
            keys: &[],
            run: |app| app.hscroll_buffer(-1),
        },
        Command {
            id: "view.hscroll_right",
            title: "Scroll viewport one column right (vim `zl`)",
            group: "view",
            keys: &[],
            run: |app| app.hscroll_buffer(1),
        },
        Command {
            id: "view.hscroll_left_half",
            title: "Scroll viewport a half-screen left (vim `zH`)",
            group: "view",
            keys: &[],
            run: |app| app.hscroll_buffer_half_screen(-1),
        },
        Command {
            id: "view.hscroll_right_half",
            title: "Scroll viewport a half-screen right (vim `zL`)",
            group: "view",
            keys: &[],
            run: |app| app.hscroll_buffer_half_screen(1),
        },
        Command {
            id: "view.split_goto_definition",
            title: "Split + jump to definition (vim `Ctrl+W d`)",
            group: "view",
            keys: &[],
            run: |app| app.split_goto_definition(),
        },
        Command {
            id: "view.split_open_file_under_cursor",
            title: "Split + open file under cursor (vim `Ctrl+W f`)",
            group: "view",
            keys: &[],
            run: |app| app.split_open_file_under_cursor(),
        },
        Command {
            id: "view.split_new_scratch",
            title: "Split + open a fresh scratch buffer (vim `Ctrl+W n`)",
            group: "view",
            keys: &[],
            run: |app| app.split_new_scratch(),
        },
        Command {
            id: "view.maximize_height",
            title: "Maximize active split height (vim `Ctrl+W _`)",
            group: "view",
            keys: &[],
            run: |app| app.maximize_split_height(),
        },
        Command {
            id: "view.maximize_width",
            title: "Maximize active split width (vim `Ctrl+W |`)",
            group: "view",
            keys: &[],
            run: |app| app.maximize_split_width(),
        },
        Command {
            id: "view.equalize_splits",
            title: "Equalize every split's ratio to 50/50 (vim `Ctrl+W =`)",
            group: "view",
            keys: &[],
            run: |app| app.equalize_splits(),
        },
        Command {
            id: "view.rotate_splits",
            title: "Rotate the active split with its sibling (vim `Ctrl+W r`)",
            group: "view",
            keys: &[],
            run: |app| app.rotate_splits(),
        },
        Command {
            id: "view.move_split_left",
            title: "Move active split to the left of its parent (vim `Ctrl+W H`)",
            group: "view",
            keys: &[],
            run: |app| app.move_active_split_edge(crate::layout::SplitDir::Horizontal, false),
        },
        Command {
            id: "view.move_split_right",
            title: "Move active split to the right of its parent (vim `Ctrl+W L`)",
            group: "view",
            keys: &[],
            run: |app| app.move_active_split_edge(crate::layout::SplitDir::Horizontal, true),
        },
        Command {
            id: "view.move_split_up",
            title: "Move active split to the top of its parent (vim `Ctrl+W K`)",
            group: "view",
            keys: &[],
            run: |app| app.move_active_split_edge(crate::layout::SplitDir::Vertical, false),
        },
        Command {
            id: "view.move_split_down",
            title: "Move active split to the bottom of its parent (vim `Ctrl+W J`)",
            group: "view",
            keys: &[],
            run: |app| app.move_active_split_edge(crate::layout::SplitDir::Vertical, true),
        },
        Command {
            id: "view.split_grow_height",
            title: "Grow active split's height (vim `Ctrl+W +`)",
            group: "view",
            keys: &[],
            run: |app| app.adjust_split(crate::layout::SplitDir::Vertical, 5),
        },
        Command {
            id: "view.split_shrink_height",
            title: "Shrink active split's height (vim `Ctrl+W -`)",
            group: "view",
            keys: &[],
            run: |app| app.adjust_split(crate::layout::SplitDir::Vertical, -5),
        },
        Command {
            id: "view.split_grow_width",
            title: "Grow active split's width (vim `Ctrl+W >`)",
            group: "view",
            keys: &[],
            run: |app| app.adjust_split(crate::layout::SplitDir::Horizontal, 5),
        },
        Command {
            id: "view.split_shrink_width",
            title: "Shrink active split's width (vim `Ctrl+W <`)",
            group: "view",
            keys: &[],
            run: |app| app.adjust_split(crate::layout::SplitDir::Horizontal, -5),
        },
        Command {
            id: "view.close_others",
            title: "Close every pane except the active one (vim `:only`)",
            group: "view",
            keys: &[],
            run: |app| app.close_other_panes(),
        },
        Command {
            id: "editor.file_info",
            title: "Toast file info: <path> · Ln N/M · X% (vim `Ctrl+G`)",
            group: "editor",
            keys: &[],
            run: |app| app.show_file_info(),
        },
        Command {
            id: "picker.marks",
            title: "Pick a mark to jump to (local + global)",
            group: "go",
            keys: &[],
            run: |app| app.open_marks_picker(),
        },
        Command {
            id: "picker.recent_commands",
            title: "Pick a recently-run command",
            group: "go",
            keys: &[],
            run: |app| app.open_recent_commands_picker(),
        },
        Command {
            id: "editor.keyword_complete",
            title: "Keyword completion: scan buffer for matches (vim insert `Ctrl+N`)",
            group: "editor",
            keys: &[],
            run: |app| app.keyword_complete(false),
        },
        Command {
            id: "editor.keyword_complete_back",
            title: "Keyword completion (backward, vim insert `Ctrl+P`)",
            group: "editor",
            keys: &[],
            run: |app| app.keyword_complete(true),
        },
        Command {
            id: "editor.insert_word_under_cursor",
            title: "Insert identifier under cursor (vim insert `Ctrl+R Ctrl+W`)",
            group: "editor",
            keys: &[],
            run: |app| app.insert_word_under_cursor(),
        },
        Command {
            id: "editor.insert_bigword_under_cursor",
            title: "Insert WORD under cursor (vim insert `Ctrl+R Ctrl+A`)",
            group: "editor",
            keys: &[],
            run: |app| app.insert_bigword_under_cursor(),
        },
        Command {
            id: "qf.next",
            title: "Quickfix: next grep result (`:cnext`)",
            group: "go",
            keys: &[],
            run: |app| app.quickfix_navigate(1),
        },
        Command {
            id: "qf.prev",
            title: "Quickfix: prev grep result (`:cprev`)",
            group: "go",
            keys: &[],
            run: |app| app.quickfix_navigate(-1),
        },
        Command {
            id: "qf.first",
            title: "Quickfix: first grep result",
            group: "go",
            keys: &[],
            run: |app| app.quickfix_navigate(i32::MIN),
        },
        Command {
            id: "qf.last",
            title: "Quickfix: last grep result",
            group: "go",
            keys: &[],
            run: |app| app.quickfix_navigate(i32::MAX),
        },
        Command {
            id: "vim.dot_repeat",
            title: "Vim: repeat last change (.)",
            group: "vim",
            keys: &[],
            run: |app| app.dot_replay(),
        },
        Command {
            id: "find.select_match_forward",
            title: "Select next find match (vim `gn`)",
            group: "find",
            keys: &[],
            run: |app| app.select_find_match(true),
        },
        Command {
            id: "find.select_match_backward",
            title: "Select previous find match (vim `gN`)",
            group: "find",
            keys: &[],
            run: |app| app.select_find_match(false),
        },
        Command {
            id: "editor.repeat_last_substitute",
            title: "Repeat last :s on current line (vim `&`)",
            group: "editor",
            keys: &[],
            run: |app| app.repeat_last_substitute(),
        },
        Command {
            id: "editor.file_stats",
            title: "File stats: lines / words / chars / bytes / cursor position (vim `g Ctrl+G`)",
            group: "editor",
            keys: &[],
            run: |app| app.show_file_stats(),
        },
        Command {
            id: "editor.char_info",
            title: "Toast char info: dec / hex / U+XXXX (vim `ga`)",
            group: "editor",
            keys: &[],
            run: |app| app.show_char_info(),
        },
        Command {
            id: "editor.char_utf8",
            title: "Toast UTF-8 byte sequence of char under cursor (vim `g8`)",
            group: "editor",
            keys: &[],
            run: |app| app.show_char_utf8(),
        },
        Command {
            id: "editor.open_url_at_cursor",
            title: "Open URL under cursor in OS browser (vim `gx`)",
            group: "editor",
            keys: &[],
            run: |app| app.open_url_at_cursor(),
        },
        Command {
            id: "editor.jump_prev_edit",
            title: "Jump to previous edit position (vim `g;`)",
            group: "editor",
            // Vim chord-bound; not exposed as a global default.
            keys: &[],
            run: |app| app.jump_prev_edit(),
        },
        Command {
            id: "vim.go_to_last_insert",
            title: "Vim: jump to last edit + enter Insert (gi)",
            group: "vim",
            keys: &[],
            run: |app| app.vim_go_to_last_insert(),
        },
        Command {
            id: "git.jump_prev_change",
            title: "Git: jump to previous changed hunk in this buffer (vim `[c`)",
            group: "git",
            keys: &[],
            run: |app| app.git_jump_to_change(false),
        },
        Command {
            id: "git.jump_next_change",
            title: "Git: jump to next changed hunk in this buffer (vim `]c`)",
            group: "git",
            keys: &[],
            run: |app| app.git_jump_to_change(true),
        },
        Command {
            id: "editor.jump_next_edit",
            title: "Jump to next edit position (vim `g,`)",
            group: "editor",
            keys: &[],
            run: |app| app.jump_next_edit(),
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
            title: "Next buffer (positional)",
            group: "buffer",
            keys: &["ctrl+pagedown"],
            run: |app| app.next_buffer(),
        },
        Command {
            id: "buffer.prev",
            title: "Previous buffer (positional)",
            group: "buffer",
            keys: &["ctrl+pageup"],
            run: |app| app.prev_buffer(),
        },
        Command {
            id: "buffer.last",
            title: "Switch to previously-active buffer (vim `Ctrl+^`)",
            group: "buffer",
            // `Ctrl+Tab` for VSCode/IDE muscle memory; `ctrl+6` is a vim
            // alias (Ctrl+^ is hard to type on most keyboards).
            keys: &["ctrl+tab", "ctrl+6"],
            run: |app| app.switch_to_last_buffer(),
        },
        Command {
            id: "vim.macro_toggle",
            title: "Vim: start / stop macro recording (q)",
            group: "vim",
            keys: &[],
            run: |app| app.macro_toggle(),
        },
        Command {
            id: "vim.macro_replay",
            title: "Vim: replay last recorded macro (@)",
            group: "vim",
            keys: &[],
            run: |app| app.macro_replay(),
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
            id: "git.switch_repo",
            title: "Git: switch active repo (multi-repo workspace)",
            group: "git",
            keys: &[],
            run: |app| app.open_repo_picker(),
        },
        Command {
            id: "git.refresh_repos",
            title: "Git: rediscover repos under workspace",
            group: "git",
            keys: &[],
            run: |app| app.rediscover_repos(),
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
            id: "git.stash",
            title: "Git: stash (push -u, optional message)",
            group: "git",
            keys: &[],
            run: |app| app.open_stash_prompt(),
        },
        Command {
            id: "git.stash_pop",
            title: "Git: stash pop (apply + drop most recent)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_stash_pop(),
        },
        Command {
            id: "git.graph",
            title: "Git: commit graph (DAG browser)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph(),
        },
        Command {
            id: "git.file_history",
            title: "Git: file history (commits touching this file)",
            group: "git",
            keys: &[],
            run: |app| app.open_file_history_picker(),
        },
        Command {
            id: "git.diff_orig",
            title: "Git: diff active buffer against on-disk version (vim :DiffOrig)",
            group: "git",
            keys: &[],
            run: |app| app.open_diff_buffer_vs_disk(),
        },
        Command {
            id: "git.browse",
            title: "Git: open file at cursor on remote (GitHub / GitLab / Bitbucket)",
            group: "git",
            keys: &[],
            run: |app| app.open_on_remote_host(),
        },
        Command {
            id: "view.reveal_active",
            title: "Reveal active file in OS Finder / Explorer",
            group: "view",
            keys: &[],
            run: |app| app.reveal_active_file(),
        },
        Command {
            id: "project.todos",
            title: "Project: scan for TODO / FIXME / HACK / XXX comments",
            group: "project",
            keys: &[],
            run: |app| app.open_todos_pane(),
        },
        Command {
            id: "find.find_backward",
            title: "Find (reverse — vim ?)",
            group: "find",
            keys: &[],
            run: |app| app.open_find_prompt_backward(),
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
            id: "git.codex_commit",
            title: "Git: write a commit message with Codex (from the staged diff)",
            group: "git",
            keys: &[],
            run: |app| app.request_codex_commit_message(),
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
            id: "lsp.goto_declaration",
            title: "LSP: go to declaration",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_goto_declaration(),
        },
        Command {
            id: "lsp.goto_type_definition",
            title: "LSP: go to type definition",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_goto_type_definition(),
        },
        Command {
            id: "lsp.goto_implementation",
            title: "LSP: go to implementation",
            group: "lsp",
            keys: &[],
            run: |app| app.lsp_goto_implementation(),
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
            id: "lsp.signature_next",
            title: "LSP: next signature (overload)",
            group: "lsp",
            // Bound directly in `tui::dispatch_key` to Down while the popup is
            // up *and* has more than one signature — keeping that condition in
            // the keymap layer would require new gating machinery for one
            // case, so the binding lives at the dispatch site instead.
            keys: &[],
            run: |app| {
                if let Some(s) = app.signature.as_mut() {
                    s.cycle();
                }
            },
        },
        Command {
            id: "lsp.signature_prev",
            title: "LSP: previous signature (overload)",
            group: "lsp",
            keys: &[],
            run: |app| {
                if let Some(s) = app.signature.as_mut() {
                    s.cycle_prev();
                }
            },
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
            id: "lsp.quick_fix",
            title: "LSP: quick fix (auto-apply first code action)",
            group: "lsp",
            // Standard "fix this for me" chord across most IDEs.
            keys: &["alt+enter"],
            run: |app| app.lsp_quick_fix(),
        },
        Command {
            id: "lsp.organize_imports",
            title: "LSP: organize imports",
            group: "lsp",
            keys: &["alt+shift+o"],
            run: |app| app.lsp_organize_imports(),
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
            id: "snippet.prev_placeholder",
            title: "Snippet: jump to previous placeholder",
            group: "edit",
            // Same dispatch-site binding as `next_placeholder`; Shift-Tab is
            // taken by Outdent in the editor.
            keys: &[],
            run: |app| app.snippet_prev_placeholder(),
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
            title: "Terminal: open a NEW shell (split below)",
            group: "ai",
            keys: &[],
            run: |app| app.open_shell(),
        },
        Command {
            id: "term.focus_or_open_shell",
            title: "Terminal: focus existing shell or open one (VS Code Ctrl+`)",
            group: "ai",
            keys: &["ctrl+t"],
            run: |app| app.focus_or_open_shell(),
        },
        Command {
            id: "ai.session_picker",
            title: "AI: pick from past Claude sessions for this workspace",
            group: "ai",
            keys: &[],
            run: |app| app.open_ai_session_picker(),
        },
        Command {
            id: "picker.clipboard",
            title: "Clipboard: pick from register history and paste at cursor",
            group: "edit",
            keys: &[],
            run: |app| app.open_clipboard_picker(),
        },
        Command {
            id: "buffer.next_dirty",
            title: "Jump to next unsaved buffer",
            group: "buffer",
            keys: &[],
            run: |app| app.jump_dirty_pane(true),
        },
        Command {
            id: "buffer.prev_dirty",
            title: "Jump to previous unsaved buffer",
            group: "buffer",
            keys: &[],
            run: |app| app.jump_dirty_pane(false),
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
            id: "browser.screenshot_node",
            title: "Browser: screenshot the selected DOM node → .mnml/screenshots/",
            group: "browser",
            keys: &[],
            run: |app| app.browser_screenshot_node(),
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
    ];
    // Bitbucket: lean-build-safe — the worker only spins up when
    // `[[bitbucket.repos]]` is non-empty, so the command is harmless to
    // surface in every build.
    cmds.push(Command {
        id: "bitbucket.pipelines",
        title: "Bitbucket: open pipelines dashboard",
        group: "bitbucket",
        // No global default key — opens via `<leader>B p` (wired in whichkey.rs)
        // or the palette / `:BB`.
        keys: &[],
        run: |app| app.open_bitbucket_pipelines_pane(),
    });
    cmds.push(Command {
        id: "bitbucket.refresh_active",
        title: "Bitbucket: refresh the active pipelines pane",
        group: "bitbucket",
        keys: &[],
        run: |app| app.refresh_active_bitbucket_pane(),
    });
    cmds.push(Command {
        id: "bitbucket.open_selected_url",
        title: "Bitbucket: open selected pipeline in browser",
        group: "bitbucket",
        keys: &[],
        run: |app| app.open_selected_bitbucket_pipeline_url(),
    });
    cmds.push(Command {
        id: "bitbucket.copy_selected_url",
        title: "Bitbucket: copy selected pipeline URL",
        group: "bitbucket",
        keys: &[],
        run: |app| app.copy_selected_bitbucket_pipeline_url(),
    });
    cmds.push(Command {
        id: "bitbucket.pull_requests",
        title: "Bitbucket: open pull-requests dashboard",
        group: "bitbucket",
        keys: &[],
        run: |app| app.open_bitbucket_pull_requests_pane(),
    });
    cmds.push(Command {
        id: "bitbucket.open_selected_pr_url",
        title: "Bitbucket: open selected PR in browser",
        group: "bitbucket",
        keys: &[],
        run: |app| app.open_selected_bitbucket_pr_url(),
    });
    cmds.push(Command {
        id: "bitbucket.copy_selected_pr_url",
        title: "Bitbucket: copy selected PR URL",
        group: "bitbucket",
        keys: &[],
        run: |app| app.copy_selected_bitbucket_pr_url(),
    });
    // GitHub: sibling commands. `<leader>C g` chord (in the +ci whichkey
    // group) is the muscle-memory entry point.
    cmds.push(Command {
        id: "github.actions",
        title: "GitHub: open Actions dashboard",
        group: "github",
        keys: &[],
        run: |app| app.open_github_actions_pane(),
    });
    cmds.push(Command {
        id: "github.refresh_active",
        title: "GitHub: refresh the active Actions pane",
        group: "github",
        keys: &[],
        run: |app| app.refresh_active_github_pane(),
    });
    cmds.push(Command {
        id: "github.open_selected_url",
        title: "GitHub: open selected run in browser",
        group: "github",
        keys: &[],
        run: |app| app.open_selected_github_run_url(),
    });
    cmds.push(Command {
        id: "github.copy_selected_url",
        title: "GitHub: copy selected run URL",
        group: "github",
        keys: &[],
        run: |app| app.copy_selected_github_run_url(),
    });
    cmds.push(Command {
        id: "github.pull_requests",
        title: "GitHub: open pull-requests dashboard",
        group: "github",
        keys: &[],
        run: |app| app.open_github_pull_requests_pane(),
    });
    cmds.push(Command {
        id: "github.open_selected_pr_url",
        title: "GitHub: open selected PR in browser",
        group: "github",
        keys: &[],
        run: |app| app.open_selected_github_pr_url(),
    });
    cmds.push(Command {
        id: "github.copy_selected_pr_url",
        title: "GitHub: copy selected PR URL",
        group: "github",
        keys: &[],
        run: |app| app.copy_selected_github_pr_url(),
    });
    // GitLab — mirror of BB/GH commands.
    cmds.push(Command {
        id: "gitlab.pipelines",
        title: "GitLab: open pipelines dashboard",
        group: "gitlab",
        keys: &[],
        run: |app| app.open_gitlab_pipelines_pane(),
    });
    cmds.push(Command {
        id: "gitlab.merge_requests",
        title: "GitLab: open merge-requests dashboard",
        group: "gitlab",
        keys: &[],
        run: |app| app.open_gitlab_merge_requests_pane(),
    });
    cmds.push(Command {
        id: "gitlab.refresh_active",
        title: "GitLab: refresh the active pane",
        group: "gitlab",
        keys: &[],
        run: |app| app.refresh_active_gitlab_pane(),
    });
    cmds.push(Command {
        id: "gitlab.open_selected_pipeline_url",
        title: "GitLab: open selected pipeline in browser",
        group: "gitlab",
        keys: &[],
        run: |app| app.open_selected_gitlab_pipeline_url(),
    });
    cmds.push(Command {
        id: "gitlab.copy_selected_pipeline_url",
        title: "GitLab: copy selected pipeline URL",
        group: "gitlab",
        keys: &[],
        run: |app| app.copy_selected_gitlab_pipeline_url(),
    });
    cmds.push(Command {
        id: "gitlab.open_selected_mr_url",
        title: "GitLab: open selected MR in browser",
        group: "gitlab",
        keys: &[],
        run: |app| app.open_selected_gitlab_mr_url(),
    });
    cmds.push(Command {
        id: "gitlab.copy_selected_mr_url",
        title: "GitLab: copy selected MR URL",
        group: "gitlab",
        keys: &[],
        run: |app| app.copy_selected_gitlab_mr_url(),
    });
    // Azure DevOps
    cmds.push(Command {
        id: "azdevops.builds",
        title: "Azure DevOps: open builds dashboard",
        group: "azdevops",
        keys: &[],
        run: |app| app.open_azdevops_builds_pane(),
    });
    cmds.push(Command {
        id: "azdevops.pull_requests",
        title: "Azure DevOps: open pull-requests dashboard",
        group: "azdevops",
        keys: &[],
        run: |app| app.open_azdevops_pull_requests_pane(),
    });
    cmds.push(Command {
        id: "azdevops.refresh_active",
        title: "Azure DevOps: refresh the active pane",
        group: "azdevops",
        keys: &[],
        run: |app| app.refresh_active_azdevops_pane(),
    });
    cmds.push(Command {
        id: "azdevops.open_selected_build_url",
        title: "Azure DevOps: open selected build in browser",
        group: "azdevops",
        keys: &[],
        run: |app| app.open_selected_azdevops_build_url(),
    });
    cmds.push(Command {
        id: "azdevops.copy_selected_build_url",
        title: "Azure DevOps: copy selected build URL",
        group: "azdevops",
        keys: &[],
        run: |app| app.copy_selected_azdevops_build_url(),
    });
    cmds.push(Command {
        id: "azdevops.open_selected_pr_url",
        title: "Azure DevOps: open selected PR in browser",
        group: "azdevops",
        keys: &[],
        run: |app| app.open_selected_azdevops_pr_url(),
    });
    cmds.push(Command {
        id: "azdevops.copy_selected_pr_url",
        title: "Azure DevOps: copy selected PR URL",
        group: "azdevops",
        keys: &[],
        run: |app| app.copy_selected_azdevops_pr_url(),
    });
    // Cross-host: one fuzzy picker over every open PR across all 4 SCM
    // hosts. Reads from the per-host caches the SCM workers populate;
    // accept opens the chosen PR's web URL.
    cmds.push(Command {
        id: "pr.picker",
        title: "Pull requests: fuzzy picker over all hosts",
        group: "pr",
        keys: &[],
        run: |app| app.open_pr_picker(),
    });
    // Cross-nav between paired PR + pipeline panes (per host). Bound to
    // `c` (on a PR row) and `P` (on a pipeline row) inside each pane —
    // these aliases keep them in the palette too for discovery.
    cmds.push(Command {
        id: "bitbucket.pipeline_log",
        title: "Bitbucket: open log for selected pipeline",
        group: "bitbucket",
        keys: &[],
        run: |app| app.open_bitbucket_pipeline_log(),
    });
    cmds.push(Command {
        id: "github.run_log",
        title: "GitHub: open log for selected workflow run",
        group: "github",
        keys: &[],
        run: |app| app.open_github_run_log(),
    });
    cmds.push(Command {
        id: "gitlab.pipeline_log",
        title: "GitLab: open log for selected pipeline",
        group: "gitlab",
        keys: &[],
        run: |app| app.open_gitlab_pipeline_log(),
    });
    cmds.push(Command {
        id: "azdevops.build_log",
        title: "Azure DevOps: open log for selected build",
        group: "azdevops",
        keys: &[],
        run: |app| app.open_azdevops_build_log(),
    });
    cmds.push(Command {
        id: "bitbucket.jump_pr_to_pipeline",
        title: "Bitbucket: PR → pipeline on same branch",
        group: "bitbucket",
        keys: &[],
        run: |app| app.jump_from_bb_pr_to_pipeline(),
    });
    cmds.push(Command {
        id: "bitbucket.jump_pipeline_to_pr",
        title: "Bitbucket: pipeline → PR on same branch",
        group: "bitbucket",
        keys: &[],
        run: |app| app.jump_from_bb_pipeline_to_pr(),
    });
    cmds.push(Command {
        id: "github.jump_pr_to_run",
        title: "GitHub: PR → workflow run on same branch",
        group: "github",
        keys: &[],
        run: |app| app.jump_from_gh_pr_to_run(),
    });
    cmds.push(Command {
        id: "github.jump_run_to_pr",
        title: "GitHub: workflow run → PR on same branch",
        group: "github",
        keys: &[],
        run: |app| app.jump_from_gh_run_to_pr(),
    });
    cmds.push(Command {
        id: "gitlab.jump_mr_to_pipeline",
        title: "GitLab: MR → pipeline on same branch",
        group: "gitlab",
        keys: &[],
        run: |app| app.jump_from_gl_mr_to_pipeline(),
    });
    cmds.push(Command {
        id: "gitlab.jump_pipeline_to_mr",
        title: "GitLab: pipeline → MR on same branch",
        group: "gitlab",
        keys: &[],
        run: |app| app.jump_from_gl_pipeline_to_mr(),
    });
    cmds.push(Command {
        id: "azdevops.jump_pr_to_build",
        title: "Azure DevOps: PR → build on same branch",
        group: "azdevops",
        keys: &[],
        run: |app| app.jump_from_az_pr_to_build(),
    });
    cmds.push(Command {
        id: "azdevops.jump_build_to_pr",
        title: "Azure DevOps: build → PR on same branch",
        group: "azdevops",
        keys: &[],
        run: |app| app.jump_from_az_build_to_pr(),
    });
    #[cfg(feature = "private")]
    {
        cmds.push(Command {
            id: "private.test_executions",
            title: "the private integration: open DocumentDB live TestExecutions browser",
            group: "private",
            keys: &[],
            run: |app| app.open_private_executions_pane(),
        });
        cmds.push(Command {
            id: "private.codebuilds",
            title: "the private integration: open AWS CodeBuild builds-list pane",
            group: "private",
            keys: &[],
            run: |app| app.open_codebuilds_pane(),
        });
        cmds.push(Command {
            id: "private.run_tests",
            title: "the private integration: run playwright tests with settings.json defaults",
            group: "private",
            keys: &[],
            run: |app| app.run_private_tests(),
        });
        cmds.push(Command {
            id: "private.run_tests_pick_env",
            title: "the private integration: run playwright tests… (pick env)",
            group: "private",
            keys: &[],
            run: |app| app.open_private_env_picker(),
        });
        cmds.push(Command {
            id: "private.run_tests_pick_branch",
            title: "the private integration: run playwright tests… (pick branch)",
            group: "private",
            keys: &[],
            run: |app| app.open_private_branch_picker(),
        });
        cmds.push(Command {
            id: "private.tail_codebuild_logs_classified",
            title: "the private integration: tail CodeBuild logs (severity-colored, in-app)",
            group: "private",
            keys: &[],
            run: |app| app.tail_selected_codebuild_logs_classified(),
        });
    }
    cmds
}
