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
/// channel — see `ipc::IpcCommand::RegisterCommand`). Lives on `App` (not the
/// static [`Registry`]) since it's per-session.
///
/// Two flavors, distinguished by `ex_run`:
///
/// - **`ex_run = None`** — IPC-registered. Invoking it doesn't call
///   Rust code; it appends a `{"event":"plugin-command","id":…}` line
///   the plugin reads. Requires the plugin to be running.
/// - **`ex_run = Some(cmdline)`** — Manifest-registered. Invoking runs
///   `cmdline` as an ex-command (e.g. `":term mnml-msg-slack"`). Works
///   whether the sibling is running or not.
#[derive(Debug, Clone)]
pub struct DynCommand {
    pub id: String,
    pub title: String,
    pub group: String,
    /// Keyspecs to bind (best-effort — bad specs are ignored). May be empty.
    pub keys: Vec<String>,
    /// If `Some`, invoking runs this ex-command line directly. If
    /// `None`, invocation queues an event for the plugin to react.
    #[allow(dead_code)]
    pub ex_run: Option<String>,
}

pub struct Registry {
    commands: Vec<Command>,
    by_id: HashMap<&'static str, usize>,
}

impl Registry {
    fn build() -> Self {
        let commands = builtin_commands();
        let mut by_id: HashMap<&'static str, usize> = HashMap::new();
        // Guard against silent last-writer-wins duplicates. Both
        // `Command` structs stay in `commands` (so the palette shows
        // both distinct titles), but a HashMap collect would let one
        // shadow the other for every id-based dispatch path (IPC,
        // :ex, keybindings). api-workflow SEV-2 2026-07-11 caught
        // `integrations.refresh` registered with two different
        // handlers this way; the binary-detection variant was
        // permanently unreachable. debug_assert lets tests catch
        // future duplicates immediately.
        for (i, c) in commands.iter().enumerate() {
            if let Some(&prev) = by_id.get(c.id) {
                debug_assert!(
                    false,
                    "duplicate command id {:?}: first at index {}, then at {}",
                    c.id, prev, i
                );
                // Release: keep the FIRST registration (source-order
                // priority) so a re-registration doesn't silently
                // shadow the original.
                continue;
            }
            by_id.insert(c.id, i);
        }
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
    // Reset the per-call failure flag — handlers that fail in a way
    // the user already saw via a toast (term missing binary,
    // etc.) set it before returning, and we honor that below.
    // 2026-06-07 bug-hunt SEV-3: forge.open_* + sibling launchers
    // used to report ok=true even when the binary wasn't on PATH.
    app.last_command_failed = false;
    let ok = if let Some(cmd) = registry().get(id) {
        (cmd.run)(app);
        !app.last_command_failed
    } else if app.run_dynamic_command(id) {
        !app.last_command_failed
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

/// Build a human-readable text dump of every command mnml knows —
/// builtins from the static registry plus any `DynCommand`s the
/// session has picked up from IPC / integration manifests. Grouped
/// by `group`, sorted within each group, one line each:
///
/// ```text
/// id                              title                                keys
/// ```
///
/// Opened as a scratch buffer via `view.commands_reference`. Users
/// hit `Ctrl+F` to search — mnml's editor Find works on this like
/// any other buffer.
pub fn build_commands_reference_text_public(dyn_cmds: &[DynCommand]) -> String {
    build_commands_reference_text(dyn_cmds)
}

fn build_commands_reference_text(dyn_cmds: &[DynCommand]) -> String {
    use std::collections::BTreeMap;

    struct Row {
        id: String,
        title: String,
        keys: String,
        origin: &'static str,
    }
    let mut by_group: BTreeMap<String, Vec<Row>> = BTreeMap::new();
    for c in registry().all() {
        by_group.entry(c.group.to_string()).or_default().push(Row {
            id: c.id.to_string(),
            title: c.title.to_string(),
            keys: c.key_hint(),
            origin: "builtin",
        });
    }
    for d in dyn_cmds {
        by_group.entry(d.group.clone()).or_default().push(Row {
            id: d.id.clone(),
            title: d.title.clone(),
            keys: d.keys.join(" / "),
            origin: "plugin",
        });
    }
    let mut total = 0usize;
    for rows in by_group.values_mut() {
        rows.sort_by(|a, b| a.id.cmp(&b.id));
        total += rows.len();
    }
    // Compute a column width per group so titles line up. Caps at 40
    // so a rogue verbose id doesn't push every title off the right
    // edge of a normal terminal.
    let mut out = String::new();
    out.push_str(&format!(
        "# mnml commands — {total} total across {} groups\n\n",
        by_group.len()
    ));
    out.push_str(
        "Hit Ctrl+F to search this buffer. `id` is what the palette and `[keys.*]` config\n\
         reference. Blank `keys` = palette-only (no default chord).\n\n",
    );
    for (group, rows) in &by_group {
        out.push_str(&format!("## {group}  ({})\n\n", rows.len()));
        let id_w = rows.iter().map(|r| r.id.chars().count()).max().unwrap_or(0);
        let id_w = id_w.min(40);
        let title_w = rows
            .iter()
            .map(|r| r.title.chars().count())
            .max()
            .unwrap_or(0)
            .min(60);
        for r in rows {
            let id_padded = format!("{:<width$}", r.id, width = id_w);
            let title_padded = format!("{:<width$}", r.title, width = title_w);
            let origin_tag = if r.origin == "plugin" {
                "  [plugin]"
            } else {
                ""
            };
            out.push_str(&format!(
                "  {id_padded}  {title_padded}  {}{}\n",
                r.keys, origin_tag
            ));
        }
        out.push('\n');
    }
    out
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
            id: "view.discovery",
            title: "Click discovery overlay (palette: 'view: discovery')",
            group: "view",
            // F1 used to live here too — collided with `view.help` and
            // `palette` (both claim F1). Kept on `view.help` only; the
            // discovery overlay is palette-only now. Untouched-surfaces
            // hunt SEV-3 (2026-06-08).
            keys: &[],
            run: |app| {
                app.show_discovery_overlay = !app.show_discovery_overlay;
            },
        },
        Command {
            id: "view.welcome",
            title: "Welcome overlay (shortcuts cheatsheet)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_welcome(),
        },
        Command {
            id: "view.about",
            title: "About mnml (version + workspace metadata)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_about(),
        },
        Command {
            id: "view.help",
            title: "Help overlay (auto-generated keymap reference)",
            group: "view",
            // F1 is the universal Help chord; doesn't collide with vim's `?`
            // (backwards search) or any editing input.
            keys: &["f1"],
            run: |app| {
                // qa-6th claude-agents SEV-2 2026-06-29: dashboard
                // has its own pane-specific help (lists >/< source
                // filter, W workspace, K kill, etc). F1 should
                // surface that instead of the global keymap dump
                // when the dashboard is active.
                if let Some(idx) = app.active
                    && let Some(crate::pane::Pane::ClaudeAgents(p)) = app.panes.get_mut(idx)
                {
                    p.show_help = !p.show_help;
                    return;
                }
                app.toggle_help_overlay();
            },
        },
        Command {
            id: "view.settings",
            title: "Settings overlay (keyboard-driven schema editor)",
            group: "view",
            // Ctrl+, is the universal "open settings" chord (VS Code,
            // Sublime, JetBrains all bind it). It used to point at
            // file.open_settings which loaded the raw TOML — that
            // leaked secrets (DocumentDB creds in one bug-hunt agent's
            // run on 2026-06-07). Schema-driven overlay is the
            // privacy-safe answer.
            keys: &["ctrl+,"],
            run: |app| app.open_settings_overlay(),
        },
        Command {
            id: "view.toggle_picker_position",
            title: "Picker: toggle position (center ⇄ top)",
            group: "view",
            keys: &[],
            run: |app| {
                let top = app.config.ui.picker_position.eq_ignore_ascii_case("top");
                app.config.ui.picker_position = if top { "center" } else { "top" }.to_string();
                app.toast(format!(
                    "picker position: {}",
                    app.config.ui.picker_position
                ));
            },
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
            id: "view.toggle_tree_section",
            title: "Toggle workspace section (collapse/expand the file list)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_tree_root_expanded(),
        },
        Command {
            id: "view.toggle_hidden",
            title: "Toggle hidden files in focused tree section",
            group: "view",
            keys: &[],
            run: |app| {
                // Toggle only the workspace section the active repo lives in.
                // For a primary-rooted active repo (or no extra workspaces),
                // that's `app.tree`; for an extra workspace, just that one.
                // Use `view.toggle_hidden_all` to propagate across every
                // section in one shot.
                let ws_idx = app.focused_tree_workspace_idx();
                let (target, label) = if let Some(i) = ws_idx {
                    let w = &mut app.extra_workspaces[i];
                    w.tree.show_hidden = !w.tree.show_hidden;
                    w.tree.refresh();
                    (w.tree.show_hidden, w.name.clone())
                } else {
                    app.tree.show_hidden = !app.tree.show_hidden;
                    app.tree.refresh();
                    let name = app
                        .workspace
                        .file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_else(|| "workspace".to_string());
                    (app.tree.show_hidden, name)
                };
                app.toast(format!(
                    "hidden ({label}): {}",
                    if target { "on" } else { "off" }
                ));
            },
        },
        Command {
            id: "view.toggle_hidden_all",
            title: "Toggle hidden files across every workspace section",
            group: "view",
            keys: &[],
            run: |app| {
                // Flip the primary tree's show_hidden, then propagate the same
                // state to every extra-workspace tree so they stay in sync.
                let target = !app.tree.show_hidden;
                app.tree.show_hidden = target;
                app.tree.refresh();
                for w in &mut app.extra_workspaces {
                    w.tree.show_hidden = target;
                    w.tree.refresh();
                }
                app.toast(
                    if target {
                        "hidden (all): on"
                    } else {
                        "hidden (all): off"
                    }
                    .to_string(),
                );
            },
        },
        Command {
            // Zen mode is palette-only — `Ctrl+Shift+Z` is the
            // universal Redo chord in VS Code (and every other modern
            // editor). Three independent persona hunts on 2026-06-08
            // flagged the prior `Ctrl+Shift+Z → Zen` binding as their
            // #1 muscle-memory trap (silently nukes redo and reshuffles
            // chrome). Zen lives in the palette as `view.zen`.
            id: "view.zen",
            title: "Zen mode (hide tree + bufferline + statusline)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_zen_mode(),
        },
        Command {
            // 2026-06-08 hunt fix — registered Redo so the keymap
            // routes `Ctrl+Shift+Z` to it BEFORE the standard input
            // handler's `'z' if shift => Redo` fallback (the keymap is
            // consulted first, so the fallback was dead code when
            // another command claimed the chord).
            id: "editor.redo",
            title: "Redo (Ctrl+Shift+Z / Ctrl+Y)",
            group: "editor",
            keys: &["ctrl+shift+z"],
            run: |app| {
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::Redo],
                        &mut crate::clipboard::Clipboard::new(),
                        0,
                    );
                }
            },
        },
        // vscode-mouse 2026-07-06 r2 SEV-2 — editor right-click had
        // NO clipboard ops. Register the five basics as palette
        // commands so the context menu (and any future palette
        // search) can reach them uniformly.
        Command {
            id: "editor.undo",
            title: "Undo (Ctrl+Z)",
            group: "editor",
            keys: &[],
            run: |app| {
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::Undo],
                        &mut crate::clipboard::Clipboard::new(),
                        0,
                    );
                }
            },
        },
        Command {
            id: "editor.cut",
            title: "Cut (Ctrl+X) — selection or current line",
            group: "editor",
            keys: &[],
            run: |app| {
                let ops = match app.active_editor() {
                    Some(b) if b.editor.has_selection() => {
                        vec![crate::edit_op::EditOp::CutSelection]
                    }
                    Some(_) => vec![
                        crate::edit_op::EditOp::YankLine,
                        crate::edit_op::EditOp::DeleteLine,
                    ],
                    None => return,
                };
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(ops, &mut crate::clipboard::Clipboard::new(), 0);
                }
            },
        },
        Command {
            id: "editor.copy",
            title: "Copy (Ctrl+C) — selection or current line",
            group: "editor",
            keys: &[],
            run: |app| {
                let ops = match app.active_editor() {
                    Some(b) if b.editor.has_selection() => {
                        vec![crate::edit_op::EditOp::YankSelection]
                    }
                    Some(_) => vec![crate::edit_op::EditOp::YankLine],
                    None => return,
                };
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(ops, &mut crate::clipboard::Clipboard::new(), 0);
                }
            },
        },
        Command {
            id: "editor.paste",
            title: "Paste (Ctrl+V)",
            group: "editor",
            keys: &[],
            run: |app| {
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::Paste],
                        &mut crate::clipboard::Clipboard::new(),
                        0,
                    );
                }
            },
        },
        Command {
            id: "editor.select_all",
            title: "Select all (Ctrl+A)",
            group: "editor",
            keys: &[],
            run: |app| {
                if let Some(b) = app.active_editor_mut() {
                    let _ = b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::SelectAll],
                        &mut crate::clipboard::Clipboard::new(),
                        0,
                    );
                }
            },
        },
        Command {
            id: "view.redraw",
            title: "Force a full redraw (clears the terminal)",
            group: "view",
            // qa-6th keyboard SEV-2 2026-06-29: was `ctrl+l`, but that
            // shadowed VS Code's editor.action.selectLine muscle
            // memory. The chord layer fired view.redraw before
            // standard.rs's SelectLine arm could execute. Dropped
            // the global chord; vim users can fire via :redraw,
            // standard users get the line-select they expect.
            keys: &[],
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
            id: "view.menu_bar_cycle",
            title: "Cycle menu bar visibility (always → auto-hide → hidden)",
            group: "view",
            keys: &[],
            run: |app| app.cycle_menu_bar(),
        },
        Command {
            id: "view.toggle_todo_highlight",
            title: "Toggle TODO/FIXME/HACK/XXX keyword highlight",
            group: "view",
            keys: &[],
            run: |app| app.toggle_todo_highlight(),
        },
        Command {
            id: "view.toggle_render_markdown",
            title: "Toggle inline-rendered markdown (render-markdown.nvim style)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_render_markdown(),
        },
        Command {
            id: "view.toggle_sticky_context",
            title: "Toggle sticky scope context (treesitter-context-style header)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_sticky_context(),
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
            run: |app| {
                // qa-6th claude-agents SEV-2 2026-06-29: Ctrl+G in
                // the dashboard cycles group-by; the global chord
                // was eating it. Defer to the pane when the active
                // pane is ClaudeAgents.
                if let Some(idx) = app.active
                    && let Some(crate::pane::Pane::ClaudeAgents(p)) = app.panes.get_mut(idx)
                {
                    p.cycle_group_by();
                    return;
                }
                app.open_goto_line_prompt();
            },
        },
        Command {
            id: "editor.bracket_match",
            title: "Jump to matching bracket",
            group: "editor",
            keys: &["ctrl+]"],
            run: |app| app.bracket_match_jump(),
        },
        // Standard-mode VS Code-canonical indent/outdent. The defaults
        // are unbound (`keys: &[]`) — the standard-mode keymap overlay
        // in `keymap.rs` re-binds them to `ctrl+]` / `ctrl+[`, which
        // vim users already have on `editor.bracket_match` / outdent.
        // Tab + BackTab still drive indent at the editor level in
        // standard mode; these chords are for VS Code muscle memory.
        // vscode-keyboard-2026-06-10 S3-01.
        Command {
            id: "editor.indent_line",
            title: "Indent the focused editor line (VSCode `Ctrl+]`)",
            group: "editor",
            keys: &[],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::Indent),
        },
        Command {
            id: "editor.outdent_line",
            title: "Outdent the focused editor line (VSCode `Ctrl+[`)",
            group: "editor",
            keys: &[],
            run: |app| app.run_editor_op(crate::edit_op::EditOp::Outdent),
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
            title: "Select word / add cursor at next occurrence (VSCode `Ctrl+D`)",
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
            title: "Toggle fold at cursor (vim `za`-ish; VS Code Ctrl+Shift+[)",
            group: "editor",
            // multilang 2026-06-28 F4: VS Code muscle memory.
            // Was previously bound to right-panel tab cycle —
            // moved (user choice) since the right panel has the
            // leader chord + click as keyboard paths.
            keys: &["Ctrl+Shift+["],
            run: |app| app.toggle_fold_at_cursor(),
        },
        Command {
            id: "editor.unfold_all",
            title: "Unfold every fold in the active buffer (vim `zR`-ish; VS Code Ctrl+Shift+])",
            group: "editor",
            keys: &["Ctrl+Shift+]"],
            run: |app| app.unfold_all_in_active(),
        },
        Command {
            id: "ai.spend_today",
            title: "AI: today's token + cost spend across all sessions (Claude + Codex)",
            group: "ai",
            // Walks every transcript modified in the last 24h
            // across ~/.claude/projects/ AND ~/.codex/sessions/,
            // sums tokens + cost, breaks down by workspace.
            // Result lands in a [ai-spend-today] scratch.
            keys: &[],
            run: |app| app.ai_spend_today(),
        },
        Command {
            id: "ai.session_search",
            title: "AI: grep every Claude transcript for a substring",
            group: "ai",
            // Walks every .jsonl under ~/.claude/projects/, matches
            // lowercase substrings against user/assistant text +
            // Bash commands + Edit file paths. Hits land in a
            // [session-search] scratch, grouped by workspace.
            keys: &[],
            run: |app| app.ai_session_search_prompt(),
        },
        Command {
            id: "ai.dashboard.open_transcript",
            title: "AI dashboard: open the focused session's transcript",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::OpenTranscript);
            },
        },
        Command {
            id: "ai.dashboard.yank_session_id",
            title: "AI dashboard: yank the focused session's id",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::YankSessionId);
            },
        },
        Command {
            id: "ai.dashboard.yank_cwd",
            title: "AI dashboard: yank the focused session's cwd",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::YankCwd);
            },
        },
        Command {
            id: "ai.dashboard.export_markdown",
            title: "AI dashboard: export the focused session's transcript as markdown",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::ExportMarkdown);
            },
        },
        Command {
            id: "ai.dashboard.kill",
            title: "AI dashboard: kill the focused session (with confirm)",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::KillPrompt);
            },
        },
        Command {
            id: "ai.dashboard.resume_in_pty",
            title: "AI dashboard: resume the focused session in a new mnml pty pane",
            group: "ai",
            keys: &[],
            run: |app| {
                use crate::claude_agents::ClaudeAgentsAction;
                app.claude_agents_action(ClaudeAgentsAction::ResumeSession);
            },
        },
        Command {
            id: "ai.dashboard",
            title: "AI: open Claude Agents dashboard (also lists Codex sessions)",
            group: "ai",
            // Scans ~/.claude/projects/*/<sid>.jsonl, cross-references
            // pgrep claude, renders one row per session with state /
            // model / tokens / cwd / last user+asst exchange. Useful
            // when you've got several CC sessions running and want a
            // unified overview. `:ag` finds this via title-fuzzy
            // (compute_cmdline_completions_for_app's 2-char title
            // gate).
            keys: &[],
            run: |app| app.open_claude_agents_pane(),
        },
        Command {
            id: "lsp.inlay_hints_toggle",
            title: "LSP: toggle inlay hints (type / parameter chips)",
            group: "lsp",
            // Flips `[editor] inlay_hints` for the current session.
            // Hints are clutter at scan-time but indispensable at
            // edit-time; many users want one chord between the two
            // states rather than editing the config.
            keys: &[],
            run: |app| {
                app.config.editor.inlay_hints = !app.config.editor.inlay_hints;
                let state = if app.config.editor.inlay_hints {
                    "on"
                } else {
                    "off"
                };
                app.toast(format!("inlay hints: {state}"));
            },
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
            id: "lsp.peek_definition",
            title: "LSP: peek definition in a horizontal split below the current pane",
            group: "lsp",
            // VS Code's Alt+F12 muscle memory: open the def below
            // the editor without losing the call-site context.
            // mnml uses a real pane (no floating overlay) — the
            // split is closable like any other pane.
            keys: &[],
            run: |app| app.peek_definition(),
        },
        Command {
            id: "lsp.peek_definition_overlay",
            title: "LSP: peek definition as a floating overlay (cursor doesn't move; VS Code Alt+F12)",
            group: "lsp",
            // True VS Code Alt+F12: a bordered box pops up over the
            // editor showing ~15 lines around the def. Esc closes;
            // arrows / j/k / PgUp/PgDn scroll within the box.
            // Cursor stays exactly where it was on close.
            keys: &["Alt+F12"],
            run: |app| app.peek_definition_overlay(),
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
            id: "view.move_to_new_tab",
            title: "Move active split to a new tab page (vim `Ctrl+W T`)",
            group: "view",
            keys: &[],
            run: |app| app.move_to_new_tab(),
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
        // Cross-host PR picker — fans out to every installed
        // `mnml-forge-*` sibling via its `--list-prs --json`
        // headless mode and shows the merged result in a single
        // fuzzy picker. Enter = open URL; Tab = jump to pipeline.
        // First call (or stale cache) blocks ~1-3s; subsequent
        // calls within 5 min use the cache (refresh with `pr.refresh`).
        Command {
            id: "pr.picker",
            title: "PRs: cross-host fuzzy picker (Enter ⇒ URL · Tab ⇒ pipeline)",
            group: "pr",
            keys: &[],
            run: |app| app.open_pr_picker(),
        },
        Command {
            id: "pr.refresh",
            title: "PRs: refresh cross-host cache (background)",
            group: "pr",
            keys: &[],
            run: |app| app.refresh_scm_prs(),
        },
        // Per-sibling launch shortcuts — equivalent to typing
        // `:term <binary>` from the cmdline, but discoverable
        // via the palette and chord-bindable via `[keys.global]`.
        // Replaces the pre-split `<host>.pull_requests` palette
        // commands users had bound to keychords. Whichkey wires
        // these under `<leader>i` (the integrations group).
        Command {
            id: "forge.open_bitbucket",
            title: "Forge: open Bitbucket viewer (mnml-forge-bitbucket)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-forge-bitbucket"),
        },
        Command {
            id: "forge.open_github",
            title: "Forge: open GitHub viewer (mnml-forge-github)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-forge-github"),
        },
        Command {
            id: "forge.open_gitlab",
            title: "Forge: open GitLab viewer (mnml-forge-gitlab)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-forge-gitlab"),
        },
        Command {
            id: "forge.open_azdevops",
            title: "Forge: open Azure DevOps viewer (mnml-forge-azdevops)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-forge-azdevops"),
        },
        Command {
            id: "forge.open_codebuild",
            title: "Forge: open AWS CodeBuild viewer (mnml-aws-codebuild)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-codebuild"),
        },
        Command {
            id: "forge.open_s3",
            title: "Forge: open Amazon S3 browser (mnml-fs-s3)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-fs-s3"),
        },
        Command {
            id: "forge.open_azure_blob",
            title: "Forge: open Azure Blob Storage browser (mnml-fs-azure-blob)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-fs-azure-blob"),
        },
        Command {
            id: "forge.open_datadog",
            title: "Forge: open Datadog observability browser (mnml-obs-datadog)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-obs-datadog"),
        },
        Command {
            id: "forge.open_buttondown",
            title: "Forge: open Buttondown newsletter browser (mnml-msg-buttondown)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-buttondown"),
        },
        Command {
            id: "forge.open_slack",
            title: "Forge: open Slack browse + post (mnml-msg-slack)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-slack"),
        },
        Command {
            id: "forge.open_teams",
            title: "Forge: open Microsoft Teams browse + post (mnml-msg-teams)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-teams"),
        },
        Command {
            id: "forge.open_mandrill",
            title: "Forge: open Mandrill email browser (mnml-msg-mandrill)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-mandrill"),
        },
        Command {
            id: "forge.open_docker",
            title: "Forge: open Docker container browser (mnml-virt-docker)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-virt-docker"),
        },
        Command {
            id: "forge.open_gmail",
            title: "Forge: open Gmail browse + send (mnml-msg-gmail)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-gmail"),
        },
        Command {
            id: "forge.open_gcal",
            title: "Forge: open Google Calendar (mnml-msg-gcal)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-msg-gcal"),
        },
        Command {
            id: "forge.open_jira",
            title: "Forge: open Jira ticket viewer (mnml-tracker-jira)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-tracker-jira"),
        },
        Command {
            id: "forge.open_cloudflare",
            title: "Forge: open Cloudflare CDN browser (mnml-cdn-cloudflare)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-cdn-cloudflare"),
        },
        Command {
            id: "forge.open_cloudwatch_logs",
            title: "Forge: open CloudWatch Logs viewer (mnml-aws-cloudwatch-logs)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-cloudwatch-logs"),
        },
        Command {
            id: "forge.open_amplify",
            title: "Forge: open AWS Amplify viewer (mnml-aws-amplify)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-amplify"),
        },
        Command {
            id: "forge.open_dynamodb",
            title: "Forge: open DynamoDB browser (mnml-db-dynamodb)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-db-dynamodb"),
        },
        Command {
            id: "forge.open_lambda",
            title: "Forge: open Lambda function browser (mnml-aws-lambda)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-lambda"),
        },
        Command {
            id: "forge.open_eventbridge",
            title: "Forge: open EventBridge buses + rules (mnml-aws-eventbridge)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-eventbridge"),
        },
        Command {
            id: "forge.open_rds",
            title: "Forge: open RDS database browser (mnml-aws-rds)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-rds"),
        },
        Command {
            id: "forge.open_ecs",
            title: "Forge: open ECS clusters + services browser (mnml-aws-ecs)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-ecs"),
        },
        Command {
            id: "forge.open_ecr",
            title: "Forge: open ECR container registry browser (mnml-aws-ecr)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-ecr"),
        },
        Command {
            id: "forge.open_cognito",
            title: "Forge: open Cognito User Pool browser (mnml-aws-cognito)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-cognito"),
        },
        Command {
            id: "forge.open_sqs",
            title: "Forge: open SQS queue browser (mnml-aws-sqs)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-sqs"),
        },
        Command {
            id: "forge.open_sns",
            title: "Forge: open SNS topic + subscription browser (mnml-aws-sns)",
            group: "forge",
            keys: &[],
            run: |app| app.run_ex_command("term mnml-aws-sns"),
        },
        Command {
            id: "integrations.refresh_binary_cache",
            title: "Integrations: refresh installed-binary detection",
            group: "integrations",
            keys: &[],
            run: |app| {
                crate::integration_detect::clear_cache();
                app.toast("integration detection refreshed");
            },
        },
        Command {
            id: "view.toggle_integrations_section",
            title: "Toggle the integrations section in the rail (collapse/expand)",
            group: "view",
            keys: &[],
            run: |app| {
                app.integration_section_expanded = !app.integration_section_expanded;
            },
        },
        Command {
            id: "markdown.cycle_engine",
            title: "Markdown preview engine — cycle builtin / glow (external ANSI renderer)",
            group: "markdown",
            keys: &[],
            run: |app| {
                let next = match app.config.ui.md_preview_engine.as_str() {
                    "builtin" => "glow",
                    "glow" => "builtin",
                    // Any custom:<cmd> value cycles back to builtin
                    // so users have an easy way to reset.
                    _ => "builtin",
                };
                app.config.ui.md_preview_engine = next.to_string();
                // Invalidate every open MdPreview pane's external
                // cache so the new engine kicks in on the next frame.
                for pane in app.panes.iter_mut() {
                    if let crate::pane::Pane::MdPreview(p) = pane {
                        p.external_cache = Default::default();
                        p.external_error_toasted = false;
                    }
                }
                app.toast(format!("md_preview_engine: {next}"));
            },
        },
        Command {
            id: "view.commands_reference",
            title: "Commands reference — every mnml command, grouped, in a scratch buffer",
            group: "view",
            keys: &[],
            run: |app| {
                let text = build_commands_reference_text(&app.dynamic_commands);
                app.open_scratch_with_text("[commands]".into(), text);
            },
        },
        Command {
            id: "view.toggle_hover_help",
            title: "Toggle the Ableton-style hover-help strip (bottom-left)",
            group: "view",
            keys: &[],
            run: |app| {
                app.config.ui.hover_help = !app.config.ui.hover_help;
                let state = if app.config.ui.hover_help {
                    "on"
                } else {
                    "off"
                };
                app.toast(format!("hover-help {state}"));
            },
        },
        Command {
            id: "view.toggle_right_panel",
            // design-critic Issue 8 — note the VS Code conflict in the
            // title so a user porting muscle memory sees it in the
            // palette. VS Code's Ctrl+Shift+B is "Run Build Task".
            // mnml has no build-task concept yet; if/when that lands,
            // the chord needs revisiting (Ctrl+Alt+B is the next pick).
            // (VS Code's Ctrl+Shift+B is "Run Build Task". mnml has
            // no build-task concept yet; if/when that lands, revisit
            // the chord — Ctrl+Alt+B is the next pick.)
            title: "Toggle the right side panel",
            group: "view",
            // vscode-user-keyboard S2-3 — natural mirror of Ctrl+B.
            keys: &["Ctrl+Shift+B"],
            run: |app| {
                app.right_panel_visible = !app.right_panel_visible;
                // Right-panel v2 (keyboard-verifier 2026-06-28 obs 2):
                // when hiding the panel, also close the hosted pane.
                // Previous behavior left the pane in app.panes so it
                // appeared as a ghost bufferline tab even though the
                // user "closed" it via toggling the panel. Re-opening
                // the panel returns to the empty-state copy; re-firing
                // outline.show / lsp.diagnostics creates fresh.
                if !app.right_panel_visible {
                    app.close_right_panel_hosted_panes();
                }
            },
        },
        Command {
            // vscode-user-keyboard 2026-06-28 SEV-2: keyboard users
            // had no way to open the right-click context menu over a
            // focused chip / row / tab. VS Code + macOS convention is
            // Shift+F10 (and the dedicated Menu key on PCs).
            // Routes by Focus: Tree → tree-row context menu over the
            // selected row; Pane → bufferline tab menu for the active
            // pane. Other focuses toast.
            id: "view.context_menu_at_focus",
            title: "Open the context menu for the focused element (Shift+F10)",
            group: "view",
            keys: &["Shift+F10"],
            run: |app| {
                app.open_context_menu_at_focus();
            },
        },
        Command {
            // Right-panel v3: keyboard tab-cycle. No default chord
            // — VS Code's Ctrl+Shift+[/] is the canonical
            // fold/unfold and was reclaimed for editor folds
            // (multilang F4, 2026-06-28). Reach the cycle via
            // `<leader>t]` / `<leader>t[` (whichkey) or click.
            id: "view.right_panel_next_tab",
            title: "Right panel: switch to next tab",
            group: "view",
            keys: &[],
            run: |app| {
                if app.right_panel_panes.len() > 1 {
                    app.right_panel_active_idx =
                        (app.right_panel_active_idx + 1) % app.right_panel_panes.len();
                }
            },
        },
        Command {
            id: "view.right_panel_prev_tab",
            title: "Right panel: switch to previous tab",
            group: "view",
            keys: &[],
            run: |app| {
                if app.right_panel_panes.len() > 1 {
                    let n = app.right_panel_panes.len();
                    app.right_panel_active_idx = (app.right_panel_active_idx + n - 1) % n;
                }
            },
        },
        Command {
            // Right-panel v3: keyboard close-active-tab. Mirrors
            // the × mouse button. Ctrl+Alt+W avoids the vim
            // NORMAL `Ctrl+W` window-prefix (just `ctrl+w` would
            // be eaten by the vim handler) and isn't a VS Code
            // chord for anything else.
            id: "view.right_panel_close_tab",
            title: "Right panel: close the active tab",
            group: "view",
            keys: &["ctrl+alt+w"],
            run: |app| {
                // crash-investigator SEV-1 #3: close_pane FIRST so
                // remove_pane_storage handles the right_panel_panes
                // shift atomically. Same fix as the × mouse handler.
                if let Some(pid) = app.right_panel_active_pane_id() {
                    app.close_pane(pid);
                }
            },
        },
        // vscode-user-keyboard S1-1 — chip toggle / edit / remove had
        // no palette commands; were context-menu-only and so
        // unreachable from the keyboard. Add a picker over the rail's
        // integration chips for each gesture.
        Command {
            id: "integrations.toggle_enabled",
            title: "Integrations: enable / disable a chip (picker)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_integration_toggle_picker(),
        },
        Command {
            id: "integrations.edit",
            title: "Integrations: edit a chip (picker)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_integration_edit_picker(),
        },
        Command {
            id: "integrations.remove",
            title: "Integrations: remove a chip (picker)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_integration_remove_picker(),
        },
        Command {
            // vscode-user-keyboard SEV-2 fix 2026-07-10 —
            // context-menu-only actions get palette twins so
            // keyboard-purists can reach them without Shift+F10.
            id: "integrations.copy_id",
            title: "Integrations: copy an id to clipboard (picker)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_integration_copy_id_picker(),
        },
        Command {
            id: "integrations.show_manifest",
            title: "Integrations: open a chip's manifest file (picker)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_integration_show_manifest_picker(),
        },
        // External-tool launchers: run if installed, else toast
        // `brew install <pkg>`. Match the integration_icon commands
        // (`:tools.htop` etc. — see config.rs default seeds).
        // design-critic Issue 2 — tools.* and term.* aliases for the
        // same Pty-launching action. term.* aligns with term.shell /
        // term.scratch_toggle; tools.* kept for back-compat and
        // because Settings UI / chips still reference them.
        Command {
            id: "tools.htop",
            title: "Tools: open htop (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("htop"),
        },
        Command {
            id: "term.htop",
            title: "Term: open htop (alias of tools.htop)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("htop"),
        },
        Command {
            id: "tools.iftop",
            title: "Tools: open iftop (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("iftop"),
        },
        Command {
            id: "term.iftop",
            title: "Term: open iftop (alias of tools.iftop)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("iftop"),
        },
        Command {
            id: "tools.btop",
            title: "Tools: open btop (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("btop"),
        },
        Command {
            id: "term.btop",
            title: "Term: open btop (alias of tools.btop)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("btop"),
        },
        // ── 2026-07-08 extension pass (TODO external-tools catalog). ──
        Command {
            id: "tools.ncdu",
            title: "Tools: open ncdu (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("ncdu"),
        },
        Command {
            id: "tools.lazygit",
            title: "Tools: open lazygit (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("lazygit"),
        },
        Command {
            id: "tools.gh",
            title: "Tools: open gh (GitHub CLI, or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("gh"),
        },
        Command {
            id: "tools.dust",
            title: "Tools: open dust (or hint brew install)",
            group: "term",
            keys: &[],
            run: |app| app.run_external_tool("dust"),
        },
        Command {
            id: "integrations.icon_picker",
            title: "Integrations: browse Nerd Font glyphs (copies to clipboard)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_icon_picker(),
        },
        Command {
            id: "integrations.patch_nerd_font_svg",
            title: "Integrations: bake an SVG into your Nerd Font as a glyph",
            group: "integrations",
            keys: &[],
            run: |app| app.open_patch_nerd_font_svg_prompt(),
        },
        Command {
            id: "integrations.glyph_builder",
            title: "Integrations: add custom glyph (SVG → font with live preview)",
            group: "integrations",
            keys: &[],
            run: |app| app.open_glyph_builder(),
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
            title: "Open path under cursor (supports `:line:col`) — palette / vim `gf`",
            group: "editor",
            // Ctrl+Shift+O used to live here too — collides with
            // `lsp.symbols` (which is the VS Code convention "Go to
            // Symbol in File"). Kept on lsp.symbols only; this
            // command stays palette-only + vim `gf`. Untouched-
            // surfaces hunt SEV-3 (2026-06-08).
            keys: &[],
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
            id: "file.new_folder",
            title: "New folder… (workspace-relative path)",
            group: "file",
            keys: &[],
            run: |app| {
                let ws = app.workspace.clone();
                app.open_new_folder_prompt(ws);
            },
        },
        Command {
            id: "file.cut",
            title: "Cut selected tree file (paste = move)",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.file_stage_clipboard(p, true);
                }
            },
        },
        Command {
            id: "file.copy",
            title: "Copy selected tree file (paste = duplicate)",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.file_stage_clipboard(p, false);
                }
            },
        },
        Command {
            id: "file.paste",
            title: "Paste the file clipboard into the selected tree row's dir",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.file_paste_into(p);
                } else {
                    let ws = app.workspace.clone();
                    app.file_paste_into(ws);
                }
            },
        },
        Command {
            id: "file.duplicate",
            title: "Duplicate the selected tree file in place (name-copy.ext)",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.file_duplicate(p);
                }
            },
        },
        Command {
            id: "file.rename",
            // F2 routing: `lsp.rename` also claims F2 (VS Code parity —
            // rename symbol under cursor). Real chord binding lives on
            // `lsp.rename` in the static keymap; when Focus == Tree,
            // `tui::dispatch_key` intercepts F2 and runs THIS command
            // instead. Palette users still search "rename" → this.
            title: "Rename the selected tree file (F2, when tree focused)",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.open_fs_rename_prompt(p);
                }
            },
        },
        Command {
            id: "file.delete",
            title: "Delete the selected tree file (Delete)",
            group: "file",
            keys: &["delete"],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.open_fs_delete_prompt(p);
                }
            },
        },
        Command {
            id: "view.focus_pane",
            title: "Focus the active pane (reverse of view.focus_tree)",
            group: "view",
            keys: &[],
            run: |app| {
                if app.active.is_some() {
                    app.focus_pane();
                }
            },
        },
        Command {
            id: "view.workspace_up",
            title: "Navigate the workspace root up one level (..)",
            group: "view",
            keys: &[],
            run: |app| app.navigate_workspace_up(),
        },
        Command {
            id: "file.move_to",
            title: "Move the selected tree file to a chosen folder…",
            group: "file",
            keys: &[],
            run: |app| {
                if let Some(p) = app.tree.selected_file() {
                    app.file_open_move_to_picker(p);
                }
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
            title: "Open mnml config TOML in an editor pane (escape hatch — schema overlay is Ctrl+,)",
            group: "file",
            // No keybinding — Ctrl+, used to live here but it routed
            // an "open settings" intent into raw-TOML editing, leaking
            // any secrets the config interpolates (DocumentDB creds,
            // API tokens, etc.) onto the screen. The palette command
            // still works for users who specifically want to hand-edit
            // the file.
            keys: &[],
            run: |app| app.open_settings(),
        },
        Command {
            // Bug-hunt seed #276 (2026-06-08): the chord-customization
            // infra existed but was undiscoverable. This palette
            // command opens config.toml jumped to `[keys.standard]`,
            // appending a documented stub when the section is missing.
            id: "keys.edit",
            title: "Customize keybindings (opens [keys.standard] in config.toml)",
            group: "file",
            keys: &[],
            run: |app| app.open_keys_config(),
        },
        Command {
            id: "nav.back",
            title: "Go back (previous cursor / file; in Browser pane: history.back)",
            group: "go",
            keys: &["alt+left"],
            // input-handler-reviewer 2026-06-28 SEV-1: Alt+Left
            // had two homes — global nav.back here and a browser
            // arm in pane.rs:565 — the chord layer fired this one
            // first, so the browser arm was dead code. Route by
            // active-pane type from a single home.
            run: |app| {
                if matches!(
                    app.active.and_then(|i| app.panes.get(i)),
                    Some(crate::pane::Pane::Browser(_))
                ) {
                    app.browser_back();
                } else {
                    app.nav_back_jump();
                }
            },
        },
        Command {
            id: "nav.forward",
            title: "Go forward (undo an Alt+Left; in Browser pane: history.forward)",
            group: "go",
            keys: &["alt+right"],
            run: |app| {
                if matches!(
                    app.active.and_then(|i| app.panes.get(i)),
                    Some(crate::pane::Pane::Browser(_))
                ) {
                    app.browser_forward();
                } else {
                    app.nav_forward_jump();
                }
            },
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
            // protocol. Used to also bind `f1` as a fallback, but f1
            // also belongs to `view.help` (universal Help convention).
            // F1 stays on Help — palette users have Ctrl+Shift+P /
            // the `:` cmdline / `Ctrl+K p` leader chord as backups.
            keys: &["ctrl+shift+p"],
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
            id: "buffer.pin_toggle",
            title: "Pin / Unpin the active tab (sticks to front of strip)",
            group: "buffer",
            keys: &[],
            run: |app| app.buffer_pin_toggle(),
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
            id: "tab.new",
            title: "New tab page",
            group: "tab",
            keys: &[],
            run: |app| app.tab_new(None),
        },
        Command {
            id: "tab.next",
            title: "Next tab page (vim gt)",
            group: "tab",
            keys: &[],
            run: |app| app.tab_next(),
        },
        Command {
            id: "tab.prev",
            title: "Previous tab page (vim gT)",
            group: "tab",
            keys: &[],
            run: |app| app.tab_prev(),
        },
        Command {
            id: "tab.first",
            title: "First tab page",
            group: "tab",
            keys: &[],
            run: |app| app.tab_first(),
        },
        Command {
            id: "tab.last",
            title: "Last tab page",
            group: "tab",
            keys: &[],
            run: |app| app.tab_last(),
        },
        Command {
            id: "tab.close",
            title: "Close active tab page",
            group: "tab",
            keys: &[],
            run: |app| app.tab_close(),
        },
        Command {
            id: "tab.only",
            title: "Close all other tab pages",
            group: "tab",
            keys: &[],
            run: |app| app.tab_only(),
        },
        Command {
            id: "tab.list",
            title: "List tab pages",
            group: "tab",
            keys: &[],
            run: |app| app.tab_list(),
        },
        Command {
            id: "tab.picker",
            title: "Fuzzy picker over tab pages",
            group: "tab",
            keys: &[],
            run: |app| app.open_tab_picker(),
        },
        Command {
            id: "tab.reopen",
            title: "Reopen last closed tab page",
            group: "tab",
            keys: &[],
            run: |app| app.tab_reopen(),
        },
        Command {
            id: "tab.move_left",
            title: "Move active tab page one position left",
            group: "tab",
            keys: &[],
            run: |app| app.tab_move("-1"),
        },
        Command {
            id: "tab.move_right",
            title: "Move active tab page one position right",
            group: "tab",
            keys: &[],
            run: |app| app.tab_move("+1"),
        },
        Command {
            id: "tab.goto_1",
            title: "Jump to tab page 1",
            group: "tab",
            keys: &["alt+1"],
            run: |app| app.switch_tab(0),
        },
        Command {
            id: "tab.goto_2",
            title: "Jump to tab page 2",
            group: "tab",
            keys: &["alt+2"],
            run: |app| app.switch_tab(1),
        },
        Command {
            id: "tab.goto_3",
            title: "Jump to tab page 3",
            group: "tab",
            keys: &["alt+3"],
            run: |app| app.switch_tab(2),
        },
        Command {
            id: "tab.goto_4",
            title: "Jump to tab page 4",
            group: "tab",
            keys: &["alt+4"],
            run: |app| app.switch_tab(3),
        },
        Command {
            id: "tab.goto_5",
            title: "Jump to tab page 5",
            group: "tab",
            keys: &["alt+5"],
            run: |app| app.switch_tab(4),
        },
        Command {
            id: "tab.goto_6",
            title: "Jump to tab page 6",
            group: "tab",
            keys: &["alt+6"],
            run: |app| app.switch_tab(5),
        },
        Command {
            id: "tab.goto_7",
            title: "Jump to tab page 7",
            group: "tab",
            keys: &["alt+7"],
            run: |app| app.switch_tab(6),
        },
        Command {
            id: "tab.goto_8",
            title: "Jump to tab page 8",
            group: "tab",
            keys: &["alt+8"],
            run: |app| app.switch_tab(7),
        },
        Command {
            id: "tab.goto_9",
            title: "Jump to tab page 9",
            group: "tab",
            keys: &["alt+9"],
            run: |app| app.switch_tab(8),
        },
        Command {
            id: "harpoon.add",
            title: "Harpoon: pin the active file into the next free slot",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_add_active(),
        },
        Command {
            id: "harpoon.menu",
            title: "Harpoon: open the pinned-files picker",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_open_menu(),
        },
        Command {
            id: "harpoon.goto_1",
            title: "Harpoon: jump to slot 1",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(1),
        },
        Command {
            id: "harpoon.goto_2",
            title: "Harpoon: jump to slot 2",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(2),
        },
        Command {
            id: "harpoon.goto_3",
            title: "Harpoon: jump to slot 3",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(3),
        },
        Command {
            id: "harpoon.goto_4",
            title: "Harpoon: jump to slot 4",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(4),
        },
        Command {
            id: "harpoon.goto_5",
            title: "Harpoon: jump to slot 5",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(5),
        },
        Command {
            id: "harpoon.goto_6",
            title: "Harpoon: jump to slot 6",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(6),
        },
        Command {
            id: "harpoon.goto_7",
            title: "Harpoon: jump to slot 7",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(7),
        },
        Command {
            id: "harpoon.goto_8",
            title: "Harpoon: jump to slot 8",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(8),
        },
        Command {
            id: "harpoon.goto_9",
            title: "Harpoon: jump to slot 9",
            group: "harpoon",
            keys: &[],
            run: |app| app.harpoon_goto(9),
        },
        Command {
            id: "editor.move_line_up",
            title: "Move current line / selection up (Alt+K / Alt+Up)",
            group: "editor",
            keys: &["alt+up", "alt+k"],
            run: |app| app.apply_op_active(crate::edit_op::EditOp::MoveLineUp),
        },
        Command {
            id: "editor.move_line_down",
            title: "Move current line / selection down (Alt+J / Alt+Down)",
            group: "editor",
            keys: &["alt+down", "alt+j"],
            run: |app| app.apply_op_active(crate::edit_op::EditOp::MoveLineDown),
        },
        Command {
            id: "view.cheatsheet",
            title: "Open the cheatsheet pane (every chord → command)",
            group: "view",
            keys: &[],
            run: |app| app.open_cheatsheet(),
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
            id: "tree.collapse_all",
            title: "Collapse all folders in the file tree",
            group: "view",
            keys: &[],
            run: |app| app.tree.collapse_all(),
        },
        Command {
            id: "tree.expand_all",
            title: "Expand all folders in the file tree",
            group: "view",
            keys: &[],
            run: |app| app.tree.expand_all_dirs(),
        },
        Command {
            id: "tree.toggle_collapse_all",
            title: "Toggle: collapse-all / expand-all",
            group: "view",
            keys: &[],
            run: |app| {
                if app.tree.is_fully_collapsed() {
                    app.tree.expand_all_dirs();
                } else {
                    app.tree.collapse_all();
                }
            },
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
            id: "clock.local",
            title: "Clock: show local time",
            group: "view",
            keys: &[],
            run: |app| {
                app.clock_show_utc = false;
                app.toast("clock: local");
            },
        },
        Command {
            id: "clock.utc",
            title: "Clock: show UTC",
            group: "view",
            keys: &[],
            run: |app| {
                app.clock_show_utc = true;
                app.toast("clock: UTC");
            },
        },
        Command {
            id: "clock.hide",
            title: "Clock: hide statusline clock chip",
            group: "view",
            keys: &[],
            run: |app| {
                app.config.ui.clock = false;
                app.toast("clock: hidden (`:set clock` to restore)");
            },
        },
        Command {
            id: "theme.pick",
            title: "Pick theme…",
            group: "view",
            keys: &[],
            run: |app| app.open_theme_picker(),
        },
        Command {
            id: "theme.toggle",
            title: "Theme: toggle (light ↔ dark)",
            group: "view",
            keys: &[],
            run: |app| app.toggle_theme(),
        },
        Command {
            id: "markdown.preview",
            title: "Markdown: open rendered preview (split)",
            group: "view",
            keys: &[],
            run: |app| app.open_md_preview(),
        },
        Command {
            id: "markdown.edit_raw",
            title: "Markdown: swap the active preview for the raw editor",
            group: "view",
            // 2026-07-10 — palette-exposes the `md_preview_to_edit`
            // path that used to be only reachable via clicking the
            // preview banner's `✏ Edit` chip. Useful for chord
            // access + for E2E tests that need to exercise the
            // editor pane's tree-sitter highlighting on a `.md`
            // file (opening `.md` routes to preview by default).
            keys: &[],
            run: |app| {
                let Some(pid) = app.active else {
                    app.toast("markdown.edit_raw: no active pane");
                    return;
                };
                app.md_preview_to_edit(pid);
            },
        },
        Command {
            id: "markdown.link_check",
            title: "Markdown: check all link targets (broken ones → Quickfix)",
            group: "view",
            keys: &[],
            run: |app| app.run_markdown_link_check(),
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
            id: "git.diff_all",
            title: "Git: diff everything vs HEAD (staged + unstaged)",
            group: "git",
            keys: &[],
            run: |app| app.open_diff_all(),
        },
        Command {
            id: "git.diff_next_file",
            title: "Git: jump to next file in the diff pane (]f)",
            group: "git",
            keys: &[],
            run: |app| app.diff_jump_file(true),
        },
        Command {
            id: "git.diff_prev_file",
            title: "Git: jump to previous file in the diff pane ([f)",
            group: "git",
            keys: &[],
            run: |app| app.diff_jump_file(false),
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
            id: "git.next_repo",
            title: "Git: cycle to next repo (multi-repo workspace)",
            group: "git",
            keys: &["alt+]"],
            run: |app| app.cycle_active_repo(true),
        },
        Command {
            id: "git.prev_repo",
            title: "Git: cycle to previous repo (multi-repo workspace)",
            group: "git",
            keys: &["alt+["],
            run: |app| app.cycle_active_repo(false),
        },
        Command {
            id: "git.refresh_repos",
            title: "Git: rediscover repos under workspace",
            group: "git",
            keys: &[],
            run: |app| app.rediscover_repos(),
        },
        Command {
            id: "view.switch_workspace",
            title: "Switch workspace (primary ↔ extras)",
            group: "view",
            keys: &[],
            run: |app| app.open_workspace_picker(),
        },
        Command {
            id: "view.manage_workspaces",
            title: "Manage workspaces… (rename / reorder / group)",
            group: "view",
            keys: &[],
            run: |app| app.open_workspaces_editor(),
        },
        Command {
            id: "view.add_workspace",
            title: "Add a workspace (runtime — not persisted)",
            group: "view",
            keys: &[],
            run: |app| {
                let prompt = crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::AddWorkspace,
                    "Workspace path (~/ supported)",
                );
                app.prompt = Some(prompt);
            },
        },
        Command {
            id: "view.remove_workspace",
            title: "Remove an extra workspace (runtime)",
            group: "view",
            keys: &[],
            run: |app| app.open_remove_workspace_picker(),
        },
        Command {
            id: "view.open_default_workspace",
            title: "Open the configured default workspace",
            group: "view",
            keys: &[],
            // Fires `add_workspace_runtime` against `config.default_workspace`.
            // From the empty-state ($HOME-as-workspace), the runtime path
            // promotes the new folder to PRIMARY (see the empty-state
            // special-case in add_workspace_runtime); from a real
            // workspace, it adds as an extra.
            run: |app| {
                let Some(p) = app.config.default_workspace.clone() else {
                    app.toast(
                        "no default_workspace configured \
                         (set [startup] default_workspace in ~/.config/mnml/config.toml)",
                    );
                    return;
                };
                app.add_workspace_runtime(p, None);
            },
        },
        // ── Activity bar (vscode-style left-rail icon strip) ──
        // Each command flips `App.active_section` to its matching
        // value; the rail layout dispatches on it to pick which
        // content to render. v1 only wires Explorer; the others
        // paint a placeholder.
        Command {
            id: "view.activity_explorer",
            title: "Activity: show Explorer",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Explorer),
        },
        Command {
            id: "view.activity_search",
            title: "Activity: show Search",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Search),
        },
        Command {
            id: "view.activity_git",
            title: "Activity: open git graph",
            group: "view",
            keys: &[],
            // The git-graph pane is mnml's "all git ops live here"
            // surface, so the activity-bar Git icon now jumps
            // straight there instead of switching to the placeholder
            // sub-panel that used to render at `ActivitySection::Git`.
            run: |app| {
                crate::command::run("git.graph", app);
            },
        },
        Command {
            id: "view.activity_debug",
            title: "Activity: show Debug",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Debug),
        },
        Command {
            id: "view.activity_integrations",
            title: "Activity: show Integrations",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Integrations),
        },
        Command {
            id: "view.activity_sessions",
            title: "Activity: show Sessions (vertical session tabs)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Sessions),
        },
        Command {
            id: "view.activity_agents",
            title: "Activity: show Agents (Claude / Codex dashboard)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Agents),
        },
        Command {
            id: "view.activity_cloud_agents",
            title: "Activity: show Cloud agents (ECS runner)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::CloudAgents),
        },
        Command {
            id: "view.activity_http",
            title: "Activity: show HTTP (.http files + recent requests)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Http),
        },
        Command {
            id: "view.activity_notes",
            title: "Activity: show Notes (workspace scratch notes)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Notes),
        },
        Command {
            id: "notes.new",
            title: "Notes: create a new note in .mnml/notes/",
            group: "notes",
            keys: &[],
            run: |app| app.notes_panel_new_note(),
        },
        Command {
            id: "view.activity_todos",
            title: "Activity: show TODOs (TODO/FIXME/XXX/HACK/REVIEW markers)",
            group: "view",
            keys: &[],
            run: |app| app.set_activity_section(crate::app::ActivitySection::Todos),
        },
        Command {
            id: "todos.refresh",
            title: "TODOs: rescan the workspace",
            group: "view",
            keys: &[],
            run: |app| app.todos_panel_refresh(),
        },
        Command {
            id: "cloud_agents.new_run",
            title: "Cloud agents: fire a new ECS run for a Jira ticket",
            group: "view",
            keys: &[],
            run: |app| app.prompt_cloud_run(),
        },
        Command {
            id: "agents.new_from_pr",
            title: "Agents: + New session from a PR (Claude Agent SDK · multi-select + action)",
            group: "view",
            keys: &[],
            run: |app| app.open_new_cloud_agent_wizard(),
        },
        Command {
            id: "cloud_agents.new_run_wizard",
            title: "Cloud agents: + New cloud run (Managed Agents · ECS)",
            group: "view",
            keys: &[],
            run: |app| app.open_new_cloud_run_wizard(),
        },
        Command {
            id: "cloud_agents.refresh_run_detail",
            title: "Cloud agents: refresh the active run-detail pane (logs + artifacts)",
            group: "view",
            keys: &[],
            run: |app| app.cloud_agent_run_refresh(),
        },
        Command {
            id: "cloud_agents.focus_quick_input",
            title: "Cloud agents: focus the quick-fire prompt input",
            group: "view",
            keys: &[],
            run: |app| {
                app.cloud_run_prompt_focused = true;
                app.cloud_agents_filter_focused = false;
            },
        },
        Command {
            id: "cloud_agents.spawn_worker",
            title: "Cloud agents: spawn ant beta:worker poll for a self-hosted sandbox",
            group: "view",
            keys: &[],
            run: |app| app.spawn_managed_agents_worker(),
        },
        Command {
            id: "cloud_agents.webhook_docs",
            title: "Cloud agents: open webhook-handler docs (alternative to ant poll)",
            group: "view",
            keys: &[],
            run: |app| app.open_managed_agents_webhook_docs(),
        },
        Command {
            id: "cloud_agents.toggle_view",
            title: "Cloud agents: toggle row density (compact ↔ standard)",
            group: "view",
            keys: &[],
            run: |app| app.cloud_agents_toggle_view(),
        },
        Command {
            id: "view.git_commit_focus",
            title: "Activity: focus the Git section's commit textarea",
            group: "view",
            keys: &[],
            run: |app| app.git_section_commit_focus(),
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
            id: "git.fetch",
            title: "Git: fetch --all --prune (refresh remote refs)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_fetch(),
        },
        Command {
            id: "git.pull",
            title: "Git: pull --ff-only (fail on non-fast-forward)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_pull(),
        },
        Command {
            id: "git.push",
            title: "Git: push (auto --set-upstream on first push)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_push(),
        },
        Command {
            id: "git.cherry_pick",
            title: "Git: cherry-pick the selected graph commit onto HEAD",
            group: "git",
            keys: &[],
            run: |app| app.run_git_cherry_pick(),
        },
        Command {
            id: "git.revert",
            title: "Git: revert the selected graph commit (creates a new commit)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_revert(),
        },
        Command {
            id: "ai.toggle_backend",
            title: "AI: toggle backend (cli ↔ api / direct HTTP)",
            group: "ai",
            keys: &[],
            run: |app| app.toggle_ai_backend(),
        },
        Command {
            id: "ai.toggle_inline_suggestions",
            title: "AI: toggle inline ghost-text suggestions (Cursor-style)",
            group: "ai",
            keys: &[],
            run: |app| app.toggle_inline_suggestions(),
        },
        Command {
            id: "ai.setup_suggestions",
            title: "AI: pick inline-suggestion backend (Claude API / local)",
            group: "ai",
            keys: &[],
            run: |app| app.open_suggest_backend_picker(),
        },
        Command {
            id: "ai.suggestion_stats",
            title: "AI: inline-suggestion accept rate",
            group: "ai",
            keys: &[],
            run: |app| app.ai_suggestion_stats(),
        },
        Command {
            id: "ai.show_config",
            title: "AI: show current backend / model / tools",
            group: "ai",
            keys: &[],
            run: |app| app.ai_show_config(),
        },
        Command {
            id: "ai.token_usage",
            title: "AI: token usage + cost estimate",
            group: "ai",
            keys: &[],
            run: |app| app.ai_token_usage(),
        },
        Command {
            id: "view.image_open",
            title: "View: open image file (PNG/JPG/GIF/WebP/BMP)",
            group: "view",
            keys: &[],
            run: |app| {
                // Best-effort: if the active editor's path is an image, open
                // that. Otherwise prompt with a file picker. Empty-tree case
                // ⇒ toast hint.
                let active_path = app
                    .active
                    .and_then(|i| app.panes.get(i))
                    .and_then(|p| p.as_editor().and_then(|b| b.path.clone()));
                if let Some(p) = active_path {
                    app.open_image_pane(&p);
                } else {
                    app.toast(
                        "view.image_open: open the file from the tree (Enter) or pick from Ctrl+P",
                    );
                }
            },
        },
        Command {
            id: "git.tag",
            title: "Git: create tag (annotated; on HEAD or selected graph commit)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_tag_prompt(),
        },
        Command {
            id: "git.tag_delete",
            title: "Git: delete tag (picker)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_tag_delete_picker(),
        },
        Command {
            id: "git.push_tags",
            title: "Git: push --tags (publish all local tags to origin)",
            group: "git",
            keys: &[],
            run: |app| app.run_git_push_tags(),
        },
        Command {
            id: "git.stash_list",
            title: "Git: stash list (pick to apply — keeps the stash)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_stash_list(),
        },
        Command {
            id: "git.stash_drop",
            title: "Git: stash drop (pick a stash to delete)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_stash_drop(),
        },
        Command {
            id: "git.reflog",
            title: "Git: reflog (HEAD history; pick to open commit diff)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_reflog(),
        },
        Command {
            id: "git.undo",
            title: "Git: undo last commit (reset --soft HEAD~1)",
            group: "git",
            keys: &[],
            run: |app| app.git_undo_last_commit(),
        },
        Command {
            id: "git.redo",
            title: "Git: redo the last undone commit",
            group: "git",
            keys: &[],
            run: |app| app.git_redo_commit(),
        },
        Command {
            id: "git.graph",
            title: "Git: commit graph (DAG browser)",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph(),
        },
        Command {
            id: "git.graph_filter_branch",
            title: "Graph: filter by branch…",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph_branch_filter_picker(),
        },
        Command {
            id: "git.graph_filter_clear",
            title: "Graph: clear branch filter (show all)",
            group: "git",
            keys: &[],
            run: |app| app.apply_git_graph_branch_filter(None),
        },
        Command {
            id: "git.graph_filter_date",
            title: "Graph: filter by date range…",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph_date_filter_prompt(),
        },
        Command {
            id: "git.graph_filter_author",
            title: "Graph: filter by author…",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph_author_filter_prompt(),
        },
        Command {
            id: "git.graph_filter_subject",
            title: "Graph: filter by subject (grep)…",
            group: "git",
            keys: &[],
            run: |app| app.open_git_graph_grep_filter_prompt(),
        },
        Command {
            id: "git.graph_filter_reset_all",
            title: "Graph: clear ALL filters (branch / date / author / subject)",
            group: "git",
            keys: &[],
            run: |app| {
                if let Some(crate::pane::Pane::GitGraph(g)) =
                    app.active.and_then(|i| app.panes.get_mut(i))
                {
                    g.filter = crate::git::log::LogFilter::default();
                    g.selected = 0;
                    g.scroll = 0;
                    g.refresh();
                    app.toast("graph filter: cleared all");
                } else {
                    app.toast("no active GitGraph pane");
                }
            },
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
            id: "git.merge",
            title: "Git: merge a branch into the current (--no-edit)",
            group: "git",
            // Picker over local branches (current excluded since git
            // refuses to merge into itself). Accept fires
            // `git merge --no-edit <name>` — conflicts toast as the
            // git error verbatim; user resolves via the editor.
            keys: &[],
            run: |app| app.open_merge_branch_picker(),
        },
        Command {
            id: "git.rebase",
            title: "Git: rebase the current branch onto another (local or remote)",
            group: "git",
            // Picker over local + remote branches. Accept fires
            // `git rebase <name>` — same conflict-handling
            // behavior as merge.
            keys: &[],
            run: |app| app.open_rebase_picker(),
        },
        Command {
            id: "git.worktree_add",
            title: "Git: add a linked worktree (prompt for path + branch)",
            group: "git",
            // Two-stage prompt: first the path (with directory
            // autocomplete from the AddWorkspace path-prompt UI),
            // then the branch name. Creates the worktree and adds
            // it as a workspace.
            keys: &[],
            run: |app| app.open_worktree_add_prompt(),
        },
        Command {
            id: "git.worktree_list",
            title: "Git: open another worktree as a workspace",
            group: "git",
            keys: &[],
            run: |app| app.open_worktree_workspace_picker(),
        },
        Command {
            id: "git.worktree_remove",
            title: "Git: remove a linked worktree (confirm prompt)",
            group: "git",
            keys: &[],
            run: |app| app.open_worktree_remove_picker(),
        },
        Command {
            id: "git.delete_branch",
            title: "Git: delete a local branch (picker, force -D, confirm prompt)",
            group: "git",
            // Picker over local branches (current branch excluded —
            // git refuses to delete checked-out). Enter → confirm
            // prompt "type 'delete' to force-delete branch X".
            // Force (-D) means unmerged branches go away too.
            keys: &[],
            run: |app| app.open_delete_branch_picker(),
        },
        Command {
            id: "git.recent_branches",
            title: "Git: recent branches (sorted by last commit date)",
            group: "git",
            // Surfaces the branches you actually work in week-to-week
            // ahead of stale ones. Same checkout flow as :git.checkout
            // but pre-ordered by `for-each-ref --sort=-committerdate`.
            keys: &[],
            run: |app| app.open_recent_branches_picker(),
        },
        Command {
            id: "git.copy_current_branch",
            title: "Git: copy current branch name to clipboard",
            group: "git",
            keys: &[],
            run: |app| app.copy_current_branch(),
        },
        Command {
            id: "git.copy_head_sha",
            title: "Git: copy HEAD SHA (full hex) to clipboard",
            group: "git",
            keys: &[],
            run: |app| app.copy_head_sha(),
        },
        Command {
            id: "ai.write_pr_description",
            title: "AI: draft a PR description from this branch's commits + diff vs main",
            group: "ai",
            // Resolves merge-base with origin/main (falling back to
            // origin/master / main / master), collects the diff +
            // commit subjects on this branch, asks Claude for a
            // Summary + Test plan markdown block. Result lands in a
            // [pr-description] scratch.
            keys: &[],
            run: |app| app.request_ai_pr_description(),
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
            // VS Code's `Ctrl+K Ctrl+I`. Chord chains parse now —
            // `ctrl+k` alone fires `whichkey.leader` after the
            // chord-chain timeout (vim's `timeoutlen` semantics);
            // pressing `ctrl+i` within the timeout fires this.
            //
            // `alt+k` was a temporary single-chord fallback while the
            // chord chain wasn't supported. Dropped after the chain
            // landed — `alt+k` collides with `editor.move_line_up`,
            // and the chord-warn at startup surfaced the collision.
            // vscode-keyboard-2026-06-10 S2-11.
            keys: &["ctrl+k ctrl+i"],
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
            // vscode-user-keyboard SEV-2 2026-07-10: was palette-only.
            // Ctrl+Shift+M is VS Code's Problems view chord and free
            // in mnml's global keymap.
            keys: &["ctrl+shift+m"],
            run: |app| app.open_diagnostics_pane(),
        },
        Command {
            id: "lsp.diagnostics_filter",
            title: "LSP: cycle diagnostics severity filter (All ↔ Warnings ↔ Errors)",
            group: "lsp",
            keys: &[],
            run: |app| app.cycle_diagnostics_filter(),
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
            // VS Code parity (F2). Bug-hunt seed #275 from the
            // VS-Code-keyboard hunt 2026-06-07 — chord was unbound.
            keys: &["f2"],
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
            id: "editor.format_external",
            title: "Format buffer with external formatter (prettier / rustfmt / gofmt / ruff / …)",
            group: "editor",
            keys: &[],
            run: |app| app.format_external_active(),
        },
        Command {
            id: "editor.format",
            title: "Format buffer (LSP if attached, else external formatter)",
            group: "editor",
            keys: &[],
            run: |app| app.format_smart(),
        },
        Command {
            id: "editor.lint_external",
            title: "Lint buffer with external linter (eslint / tsc / ruff / shellcheck / …)",
            group: "editor",
            keys: &[],
            run: |app| app.lint_external_active(),
        },
        Command {
            id: "tools.installer",
            title: "Browse external tools (Mason-style — LSPs / formatters / linters)",
            group: "tools",
            keys: &[],
            run: |app| app.open_tools_installer(),
        },
        Command {
            id: "dap.toggle_breakpoint",
            title: "DAP: toggle breakpoint at cursor line",
            group: "dap",
            keys: &["f9"],
            run: |app| app.dap_toggle_breakpoint(),
        },
        Command {
            id: "dap.clear_all_breakpoints",
            title: "DAP: clear all breakpoints in this buffer",
            group: "dap",
            keys: &[],
            run: |app| app.dap_clear_all_breakpoints(),
        },
        Command {
            id: "dap.list_breakpoints",
            title: "DAP: list all breakpoints across open buffers",
            group: "dap",
            keys: &[],
            run: |app| app.dap_list_breakpoints(),
        },
        Command {
            id: "dap.run",
            title: "DAP: start debug session for active buffer's filetype",
            group: "dap",
            keys: &["f5"],
            run: |app| app.dap_run(),
        },
        Command {
            id: "dap.continue",
            title: "DAP: continue (resume from breakpoint)",
            group: "dap",
            keys: &["shift+f5"],
            run: |app| app.dap_continue(),
        },
        Command {
            id: "dap.next",
            title: "DAP: step over",
            group: "dap",
            keys: &["f10"],
            run: |app| app.dap_next(),
        },
        Command {
            id: "dap.step_in",
            title: "DAP: step into",
            group: "dap",
            keys: &["f11"],
            run: |app| app.dap_step_in(),
        },
        Command {
            id: "dap.step_out",
            title: "DAP: step out",
            group: "dap",
            keys: &["shift+f11"],
            run: |app| app.dap_step_out(),
        },
        Command {
            id: "dap.pause",
            title: "DAP: pause running thread",
            group: "dap",
            keys: &[],
            run: |app| app.dap_pause(),
        },
        Command {
            id: "dap.step_back",
            title: "DAP: step backward (reverse — requires record-replay adapter)",
            group: "dap",
            keys: &[],
            run: |app| app.dap_step_back(),
        },
        Command {
            id: "dap.reverse_continue",
            title: "DAP: reverse-continue to previous breakpoint",
            group: "dap",
            keys: &[],
            run: |app| app.dap_reverse_continue(),
        },
        Command {
            id: "dap.terminate",
            title: "DAP: terminate session",
            group: "dap",
            keys: &[],
            run: |app| app.dap_terminate(),
        },
        Command {
            id: "dap.show",
            title: "DAP: show debug pane (call stack + output)",
            group: "dap",
            keys: &[],
            run: |app| app.open_debug_pane(),
        },
        Command {
            id: "dap.add_watch",
            title: "DAP: add a watch expression",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_add_watch_prompt(),
        },
        Command {
            id: "dap.set_variable",
            title: "DAP: set the value of the selected variable",
            group: "dap",
            keys: &[],
            run: |app| app.debug_pane_set_var(),
        },
        Command {
            id: "dap.remove_watch",
            title: "DAP: remove a watch expression (→ picker)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_remove_watch_picker(),
        },
        Command {
            id: "dap.clear_watches",
            title: "DAP: clear all watch expressions",
            group: "dap",
            keys: &[],
            run: |app| app.dap_clear_watches(),
        },
        Command {
            id: "dap.toggle_breakpoint_conditional",
            title: "DAP: toggle conditional breakpoint at cursor",
            group: "dap",
            keys: &["shift+f9"],
            run: |app| app.open_dap_breakpoint_conditional_prompt(),
        },
        Command {
            id: "dap.attach",
            title: "DAP: attach to a running process (→ picker)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_attach_picker(),
        },
        Command {
            id: "dap.pick_thread",
            title: "DAP: switch to a different thread (→ picker)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_thread_picker(),
        },
        Command {
            id: "dap.repl",
            title: "DAP: open the REPL pane (evaluate expressions)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_repl_pane(),
        },
        Command {
            id: "dap.exceptions",
            title: "DAP: toggle exception breakpoints (→ picker)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_exception_picker(),
        },
        Command {
            id: "dap.set_breakpoint_hit_count",
            title: "DAP: set hit-count on breakpoint (e.g. >= 5, % 10)",
            group: "dap",
            keys: &[],
            run: |app| app.open_dap_breakpoint_hit_count_prompt(),
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
            id: "snippet.pick_all",
            title: "Snippets: list ALL (every scope)…",
            group: "editor",
            keys: &[],
            run: |app| app.snippet_pick_all(),
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
            id: "http.send",
            title: "HTTP: send request (.http/.curl) — or re-fire a request pane",
            group: "http",
            // No global default key (`Ctrl+R` is vim's redo). Use `<leader>h s` or
            // the palette; a request pane also re-fires with its own `r` key.
            keys: &[],
            run: |app| app.send_request_from_active(),
        },
        Command {
            // http-2nd 2026-06-28 SEV-3b
            id: "http.next_block",
            title: "HTTP: move cursor to the next ### block in a multi-block file",
            group: "http",
            keys: &[],
            run: |app| app.http_next_block(),
        },
        Command {
            id: "http.prev_block",
            title: "HTTP: move cursor to the previous ### block",
            group: "http",
            keys: &[],
            run: |app| app.http_prev_block(),
        },
        Command {
            id: "http.sync",
            title: "HTTP: sync swagger sources → .curl stub files",
            group: "http",
            // Reads <workspace>/.mnml/sources.json (or
            // <workspace>/.rqst/sources.json for legacy workspaces)
            // and regenerates `.curl` files per swagger source. Same
            // logic the CLI's `mnml http sync` uses. Phase 2 of the
            // rqst→mnml port-back.
            keys: &[],
            run: |app| app.http_sync_sources(),
        },
        Command {
            id: "http.sync_check",
            title: "HTTP: check for drift between swagger sources + on-disk stubs (dry run)",
            group: "http",
            keys: &[],
            run: |app| app.http_sync_check(),
        },
        Command {
            id: "http.toggle_sync_normalize",
            title: "HTTP: toggle sync normalization ({{$isoTimestamp}} / {{$uuid}} substitution)",
            group: "http",
            keys: &[],
            run: |app| {
                app.config.http.sync_normalize = !app.config.http.sync_normalize;
                let state = if app.config.http.sync_normalize {
                    "on"
                } else {
                    "off"
                };
                app.toast(format!("sync_normalize: {state}"));
            },
        },
        Command {
            id: "http.bench",
            title: "HTTP: bench active request 10× (concurrent)",
            group: "http",
            keys: &[],
            run: |app| app.http_bench_active(10, 4),
        },
        Command {
            id: "http.pick_env",
            title: "HTTP: pick .env file (session override)",
            group: "http",
            keys: &[],
            run: |app| app.open_http_env_picker(),
        },
        Command {
            id: "http.reset_env",
            title: "HTTP: reset .env override (fall back to MNML_ENV)",
            group: "http",
            keys: &[],
            run: |app| app.http_reset_env(),
        },
        Command {
            id: "http.delete_env_key",
            title: "HTTP: delete env var (from active .env)",
            group: "http",
            keys: &[],
            run: |app| {
                if let Some(key) = app.pending_env_key_delete.take() {
                    app.http_delete_env_key(&key);
                }
            },
        },
        Command {
            id: "http.edit_env",
            title: "HTTP: structured editor for the active env file (.rqst/env/<name>.env)",
            group: "http",
            // Phase 3 polish — opens a picker over every var in
            // the active env file (plus a synthetic `+ Add new
            // variable…` row at the top). Accept an existing key
            // → prompt to edit the value. Accept `+add` → prompt
            // for `KEY=VALUE`. All writes round-trip through the
            // existing `upsert_env_var` helper (in-place replace +
            // append, preserves comments + ordering).
            keys: &[],
            run: |app| app.http_edit_env_open(),
        },
        Command {
            id: "http.lookup",
            title: "HTTP: lookup — fill an env var from a live API response",
            group: "http",
            // Multi-stage flow ported from rqst's `Ctrl+;` lookup:
            // stage 1 is a picker over `.curl` files under
            // `.rqst/lookups/`; accept fires it on a background
            // thread; stage 2 is a picker over the parsed items;
            // stage 3 is a prompt for the env var name; the final
            // write lands `<var>=<id>` in
            // `.rqst/env/<active>.env`. Phase 7 of the rqst→mnml
            // port-back.
            keys: &[],
            run: |app| app.http_lookup_open(),
        },
        Command {
            id: "browser.autocapture_toggle",
            title: "Browser: toggle auto-append network entries to captured log",
            group: "http",
            // Runtime override for `[browser] autocapture_to_log` —
            // affects every Browser pane in this session until restart.
            keys: &[],
            run: |app| {
                app.config.browser.autocapture_to_log = !app.config.browser.autocapture_to_log;
                app.toast(if app.config.browser.autocapture_to_log {
                    "browser autocapture → captured/log.jsonl: ON"
                } else {
                    "browser autocapture: OFF"
                });
            },
        },
        Command {
            id: "http.capture_now",
            title: "HTTP: append browser pane network entries → captured log",
            group: "http",
            // Phase 4 of the rqst→mnml port-back. Writes the active
            // browser pane's NetEntry list as JSONL into
            // `<workspace>/.rqst/captured/log.jsonl` so the captures
            // accumulate across sessions and can be reviewed/replayed
            // later.
            keys: &[],
            run: |app| app.http_capture_browser_net_to_log(),
        },
        Command {
            id: "http.capture_start",
            title: "HTTP: launch browser + start capturing (or dump current if browser is open)",
            group: "http",
            // Sidebar CAPTURED chip 2026-07-07 — one-click "start
            // capturing". No browser pane open ⇒ opens the browser
            // URL prompt (autocapture toggles the log on for every
            // network entry once the pane's live). Browser pane
            // already open ⇒ dumps the current NetEntry list to the
            // captured log (existing http.capture_now behavior).
            keys: &[],
            run: |app| {
                let has_browser = app
                    .panes
                    .iter()
                    .any(|p| matches!(p, crate::pane::Pane::Browser(_)));
                if has_browser {
                    app.http_capture_browser_net_to_log();
                } else {
                    app.open_browser_prompt();
                }
            },
        },
        Command {
            id: "http.view_captured",
            title: "HTTP: open .rqst/captured/log.jsonl (captured browser traffic)",
            group: "http",
            keys: &[],
            run: |app| app.open_http_captured_log(),
        },
        Command {
            id: "http.history",
            title: "HTTP: open .rqst/history.jsonl (one-line-per-send log)",
            group: "http",
            // Phase 9 — opens the JSONL history log as a regular
            // editor buffer for grep / jq / manual scan. A richer
            // picker (with per-entry re-fire) is a follow-up; the
            // file-as-buffer path is what rqst users use today.
            keys: &[],
            run: |app| app.open_http_history(),
        },
        Command {
            id: "http.history_global",
            title: "HTTP: history picker across all workspaces (~/.config/mnml/history-global.jsonl)",
            group: "http",
            // Cross-workspace recall. Every :http.send mirrors to
            // ~/.config/mnml/history-global.jsonl with a "workspace"
            // field; this command opens a picker over the last 100
            // entries from that file. Useful when you remember
            // firing a request but not which project you were in.
            keys: &[],
            run: |app| app.open_http_history_global(),
        },
        Command {
            id: "http.run_chain",
            title: "HTTP: run a .chain.json from .mnml/chains (multi-step request chain)",
            group: "http",
            // Postman runner arc. Picker over the workspace's
            // .mnml/chains/*.chain.json files. Enter spawns a worker
            // that runs the chain step-by-step (see http::chain::run);
            // the per-step trace + final pass/fail lands in a
            // [chain-trace] scratch.
            keys: &[],
            run: |app| app.open_http_chain_picker(),
        },
        Command {
            id: "http.view_source",
            title: "HTTP: open the active request's source file as text",
            group: "http",
            // Sibling of "Open as text" in the HTTP-row right-click
            // menu. Falls back to a toast when the pane has no
            // source (a fresh + New request that's never been saved).
            keys: &[],
            run: |app| {
                let Some(cur) = app.active else {
                    app.toast("view source: no active pane");
                    return;
                };
                let path = match app.panes.get(cur) {
                    Some(crate::pane::Pane::Request(rp)) => rp.source_path.clone(),
                    _ => {
                        app.toast("view source: not a Request pane");
                        return;
                    }
                };
                let Some(path) = path else {
                    app.toast("view source: unsaved request (Save-As first)");
                    return;
                };
                app.open_path_as_editor(&path);
            },
        },
        Command {
            id: "http.refresh",
            title: "HTTP: rescan collections / files / envs / captured log",
            group: "http",
            // Sidebar toolbar `↺` mirror. Cheap — walks the workspace
            // tree once. 2026-07-06.
            keys: &[],
            run: |app| {
                app.http_panel_refresh();
                app.toast("HTTP panel refreshed");
            },
        },
        Command {
            id: "http.toggle_collapse_all",
            title: "HTTP: collapse / expand all sidebar sections",
            group: "http",
            keys: &[],
            run: |app| {
                let all_collapsed = app.http_panel_section_collapsed.iter().all(|c| *c);
                for c in app.http_panel_section_collapsed.iter_mut() {
                    *c = !all_collapsed;
                }
            },
        },
        Command {
            id: "http.new_env",
            title: "HTTP: create a new .env in .mnml/env/",
            group: "http",
            // Mirror of `+ New env` in the HTTP sidebar — prompts for
            // a name, creates the file, switches the active env, and
            // opens it in the editor. design-critic 2026-07-06 r2.
            keys: &[],
            run: |app| app.http_new_env_prompt(),
        },
        Command {
            id: "http.new_chain",
            title: "HTTP: create a new .chain.json in .mnml/chains/",
            group: "http",
            // Mirror of `+ New chain` in the HTTP sidebar — prompts
            // for a name, creates the file with a login → whoami
            // starter template, opens it in the editor.
            keys: &[],
            run: |app| app.http_new_chain_prompt(),
        },
        Command {
            id: "http.new_collection",
            title: "HTTP: create a new request collection under .mnml/collections/",
            group: "http",
            // Mirror of `+ New collection` in the HTTP sidebar —
            // prompts for a name, creates a folder + starter
            // requests.http with `### list` / `### create` blocks.
            keys: &[],
            run: |app| app.http_new_collection_prompt(),
        },
        Command {
            id: "http.ai_build",
            title: "HTTP: build a request from a natural-language description (Claude)",
            group: "http",
            // Prompts for a NL description ("get the top 5 users
            // from prod"); a worker thread calls Claude's
            // /v1/messages with a curl-only system prompt; the
            // reply is parsed as curl and a new Request pane opens
            // on the Source tab. Requires $ANTHROPIC_API_KEY.
            keys: &[],
            run: |app| app.http_ai_build_prompt(),
        },
        Command {
            id: "http.save_mock",
            title: "HTTP: save current response as a sibling .mock.json",
            group: "http",
            keys: &[],
            run: |app| app.http_save_active_response_as_mock(),
        },
        Command {
            id: "http.replay_mock",
            title: "HTTP: replay sibling .mock.json into the active request pane",
            group: "http",
            keys: &[],
            run: |app| app.http_replay_active_request_from_mock(),
        },
        Command {
            id: "jwt.decode",
            title: "JWT: decode clipboard token (claims only, no signature)",
            group: "http",
            keys: &[],
            run: |app| app.jwt_decode_clipboard(),
        },
        Command {
            id: "auth.extract_bearer",
            title: "Auth: extract bearer token from clipboard text",
            group: "http",
            keys: &[],
            run: |app| app.auth_extract_bearer_from_clipboard(),
        },
        Command {
            id: "http.paste_curl",
            title: "HTTP: paste curl from clipboard — populate active Request pane",
            group: "http",
            // Reads the clipboard, parses as curl / .http / .rest,
            // overwrites the active Request pane's Method / URL /
            // Headers / Body in place. The Postman-style "paste a
            // curl from Chrome DevTools" workflow. Mirrors rqst's
            // Source tab. v2 of the Request pane UI will surface
            // this as a dedicated field; today it's palette + the
            // context menu.
            keys: &[],
            run: |app| app.http_paste_curl_to_active(),
        },
        Command {
            id: "http.paste_source",
            title: "HTTP: parse Source tab buffer into Method/URL/Headers/Body",
            group: "http",
            // Ctrl+Enter while focused on the Source field is the
            // primary trigger; the palette command is the
            // discoverability path. Parses source_buffer via
            // crate::http::parse, populates the structured fields,
            // clears the buffer, switches to Body tab.
            keys: &[],
            run: |app| app.http_parse_source_buffer(),
        },
        Command {
            id: "http.toggle_edit_split",
            title: "HTTP: split the Request edit area side-by-side (Body | Vars)",
            group: "http",
            keys: &[],
            run: |app| app.http_toggle_edit_split(),
        },
        Command {
            id: "http.diff_last_two",
            title: "HTTP: diff the active Request pane's last two responses",
            group: "http",
            // Compares prev_response to the current Done state
            // (status + headers + body) and opens a scratch
            // buffer with a unified-diff-like rendering. Useful
            // for 'did re-firing change anything?' debugging.
            keys: &[],
            run: |app| app.http_diff_last_two(),
        },
        Command {
            id: "http.fan_envs",
            title: "HTTP: fan the active request out against every env file in parallel",
            group: "http",
            // Reads every .mnml/env/*.env (or .rqst/env/*.env if
            // .mnml/ has none), spawns one send per env file with
            // the env applied to {{VAR}} substitution, collects
            // the (env_name, status, ms, error) tuple, renders a
            // table summary into the clipboard + toast.
            keys: &[],
            run: |app| app.http_fan_envs(),
        },
        Command {
            id: "http.import_postman",
            title: "HTTP: import a Postman Collection from clipboard",
            group: "http",
            // Postman Collection v2.1 JSON → one .curl per request
            // in .rqst/captured/postman-<collection-name>/. Folder
            // groups are flattened with a `<group>__<request>`
            // filename prefix so the collection's hierarchy stays
            // greppable.
            keys: &[],
            run: |app| app.http_import_postman_from_clipboard(),
        },
        Command {
            id: "http.import_har",
            title: "HTTP: import a .har file from clipboard or path",
            group: "http",
            // Parses Chrome / Firefox / Safari DevTools HAR exports
            // (`File → Save all as HAR`) into N `.curl` files in
            // `.rqst/captured/har-<timestamp>/`. Each entry's
            // method / URL / headers / postData becomes one curl
            // ready to fire or paste into a Request pane.
            keys: &[],
            run: |app| app.http_import_har_from_clipboard(),
        },
        Command {
            id: "http.params_add",
            title: "HTTP: add a query parameter (?key=value) to the active Request URL",
            group: "http",
            keys: &[],
            run: |app| app.http_params_add(),
        },
        Command {
            id: "http.params_clear",
            title: "HTTP: clear all query parameters from the active Request URL",
            group: "http",
            keys: &[],
            run: |app| app.http_params_clear(),
        },
        Command {
            id: "http.abort",
            title: "HTTP: cancel any in-flight bench / sync work",
            group: "http",
            // Sets the shared atomic abort flag. Long-running
            // workers (bench, sync) poll between iterations and
            // exit on the next boundary. send_streaming runs to
            // its natural socket-close (or 600s timeout) — but
            // the user's UI-side rx is dropped so they see the
            // toast clear immediately.
            keys: &[],
            run: |app| app.http_abort_all(),
        },
        Command {
            id: "http.set_method.get",
            title: "HTTP: set method = GET",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("GET"),
        },
        Command {
            id: "http.set_method.post",
            title: "HTTP: set method = POST",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("POST"),
        },
        Command {
            id: "http.set_method.put",
            title: "HTTP: set method = PUT",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("PUT"),
        },
        Command {
            id: "http.set_method.patch",
            title: "HTTP: set method = PATCH",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("PATCH"),
        },
        Command {
            id: "http.set_method.delete",
            title: "HTTP: set method = DELETE",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("DELETE"),
        },
        Command {
            id: "http.set_method.head",
            title: "HTTP: set method = HEAD",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("HEAD"),
        },
        Command {
            id: "http.set_method.options",
            title: "HTTP: set method = OPTIONS",
            group: "http",
            keys: &[],
            run: |app| app.http_set_method("OPTIONS"),
        },
        Command {
            id: "http.insert_header",
            title: "HTTP: insert a common header (Accept, Content-Type, Authorization, …)",
            group: "http",
            // Opens a picker over the IANA-common header names.
            // Enter inserts `Name: ` at the Headers field's cursor.
            keys: &[],
            run: |app| app.http_insert_header_picker(),
        },
        Command {
            id: "http.save_response",
            title: "HTTP: save active Response body to a file (prompt for path)",
            group: "http",
            keys: &[],
            run: |app| app.http_save_response_prompt(),
        },
        Command {
            id: "ws.connect",
            title: "WebSocket: connect to a URL (native, persistent)",
            group: "http",
            // Prompts for a wss:// URL; connects via tungstenite
            // on a background thread. Output streams into a
            // [ws-<host>] scratch buffer; subsequent :ws.send
            // commands push messages over the same connection.
            keys: &[],
            run: |app| app.ws_connect_prompt(),
        },
        Command {
            id: "ws.history",
            title: "WebSocket: picker over past URLs (~/.mnml/ws-history)",
            group: "http",
            keys: &[],
            run: |app| app.ws_history_picker(),
        },
        Command {
            id: "ws.send_message",
            title: "WebSocket: send a message on the active connection",
            group: "http",
            keys: &[],
            run: |app| app.ws_send_message_prompt(),
        },
        Command {
            id: "ws.disconnect",
            title: "WebSocket: close the active connection",
            group: "http",
            keys: &[],
            run: |app| app.ws_disconnect(),
        },
        Command {
            id: "ws.send",
            title: "WebSocket: send the active .ws file via websocat",
            group: "http",
            // Active file shape (JSON):
            //   { url, message, timeout_ms?, headers? }
            // Shells out to websocat on PATH; response lands in
            // [ws-response].
            keys: &[],
            run: |app| app.ws_send_active(),
        },
        Command {
            id: "http.format_body",
            title: "HTTP: pretty-print JSON Body field of the active Request pane",
            group: "http",
            // Parses the Body field as JSON and rewrites it with
            // 2-space indent. No-op when Body isn't valid JSON
            // (toasts the parse error). Useful after pasting a
            // minified payload from a browser DevTools panel.
            keys: &[],
            run: |app| app.http_format_body(),
        },
        Command {
            id: "http.copy_ai_prompt",
            title: "HTTP: copy AI-ready \"debug this failure\" prompt to clipboard",
            group: "http",
            // Structured markdown prompt with method / URL / status /
            // headers / body / env context / schema errors, obvious
            // sensitive-value redaction (Authorization, api-key,
            // Cookie, *-secret). Paste into Claude / Codex / etc.
            keys: &[],
            run: |app| app.http_copy_ai_prompt(),
        },
        Command {
            id: "http.regenerate_body",
            title: "HTTP: regenerate body dynamic values (fresh timestamps + UUIDs)",
            group: "http",
            // Rerolls every ISO 8601 timestamp and UUID in the
            // body — concrete → concrete-fresh, template →
            // template-then-fresh. One-click "give me another
            // order" gesture for repeated fires.
            keys: &[],
            run: |app| app.http_regenerate_body(),
        },
        Command {
            id: "http.show_schema_errors",
            title: "HTTP: open scratch buffer with response schema validation errors",
            group: "http",
            // For the active Request pane, opens a `[schema-errors]`
            // scratch listing every validator error from the last
            // response. No-op when there's no schema sidecar
            // (`<request>.schema.json`) or the response validated.
            keys: &[],
            run: |app| app.http_show_schema_errors(),
        },
        Command {
            id: "http.revalidate_schema",
            title: "HTTP: re-run schema validation on the active Request pane's last response",
            group: "http",
            // Useful after editing the sidecar `.schema.json` without
            // re-firing the request — picks up the edited schema and
            // re-runs validation against the existing response body.
            keys: &[],
            run: |app| app.http_revalidate_schema(),
        },
        Command {
            id: "http.cycle_method",
            title: "HTTP: cycle method (GET→POST→PUT→DELETE→PATCH→…)",
            group: "http",
            keys: &[],
            run: |app| app.http_cycle_method(),
        },
        Command {
            id: "http.new",
            title: "HTTP: new blank request pane (Postman-style scratch)",
            group: "http",
            // Opens an in-memory Request pane already in Edit view
            // with empty fields, no source file. User edits Method
            // / URL / Headers / Body and hits `r` to fire. `Ctrl+S`
            // toasts "no source file" — use `:w path.curl` from a
            // sibling editor to persist the curl (v2 follow-up: a
            // proper save-as prompt).
            keys: &[],
            run: |app| app.open_new_request_pane(),
        },
        Command {
            id: "http.send_streaming",
            title: "HTTP: send active request as a Server-Sent Events stream",
            group: "http",
            // Same parse as :http.send, but the worker uses an
            // SSE-aware reader with no client timeout — for
            // Anthropic / OpenAI / SSE-style text/event-stream
            // endpoints. Events are buffered + rendered into the
            // Response pane body when the stream closes. Phase 8
            // polish.
            keys: &[],
            run: |app| app.send_streaming_from_active(),
        },
        Command {
            id: "sse.parse_active_response",
            title: "SSE: parse active Response pane body as Server-Sent Events",
            group: "http",
            // Reads the active Request pane's Done response body,
            // runs it through `crate::sse::Reader`, toasts the
            // event count + first event's name/data. Useful when an
            // endpoint returns SSE but the body view shows raw
            // `data: …` lines — confirms the SSE shape is well-
            // formed and surfaces individual events. Full streaming-
            // send progressive display is a v2 follow-up.
            keys: &[],
            run: |app| app.sse_parse_active_response(),
        },
        Command {
            id: "auth.save_preset",
            title: "Auth: save current Authorization header as a named preset",
            group: "http",
            // Reads the active Request pane's Authorization header
            // and writes it as a preset to .mnml/auth/<name>.txt
            // for later reuse via :auth.apply_preset.
            keys: &[],
            run: |app| app.auth_save_preset_prompt(),
        },
        Command {
            id: "auth.apply_preset",
            title: "Auth: apply a saved preset → active Request Authorization header",
            group: "http",
            // Picker over .mnml/auth/*.txt presets. Enter writes
            // (or replaces) the Authorization header on the active
            // Request pane with the preset's content.
            keys: &[],
            run: |app| app.auth_apply_preset_picker(),
        },
        Command {
            id: "cookies.delete",
            title: "Cookies: remove one cookie (picker)",
            group: "http",
            keys: &[],
            run: |app| app.cookies_delete_picker(),
        },
        Command {
            id: "cookies.show",
            title: "Cookies: open picker over the persistent jar",
            group: "http",
            // Lists every cookie currently in the jar (host · name
            // · value preview). Enter on a row copies the name=value
            // pair to the clipboard.
            keys: &[],
            run: |app| app.cookies_show_picker(),
        },
        Command {
            id: "cookies.clear",
            title: "Cookies: clear every cookie in the jar",
            group: "http",
            keys: &[],
            run: |app| app.cookies_clear_jar(),
        },
        Command {
            id: "cookies.persist",
            title: "Cookies: write the jar to .mnml/cookies.json",
            group: "http",
            // The jar auto-saves on app exit; this is the explicit
            // 'flush now' for users who want the file on disk
            // immediately (e.g. before a workspace switch).
            keys: &[],
            run: |app| app.cookies_persist(),
        },
        Command {
            id: "cookies.normalize_clipboard",
            title: "Cookies: normalize clipboard text → canonical `name=v; name=v` form",
            group: "http",
            // Accepts any of the three DevTools shapes
            // (`name=value` per line, `name: value` per line, or
            // the proper `name=v; name=v` form) and rewrites the
            // clipboard with the canonical Cookie-header form. v2
            // would auto-fire when typing into a Cookie: header
            // value in the Request pane's Edit view.
            keys: &[],
            run: |app| app.cookies_normalize_clipboard(),
        },
        Command {
            id: "http.copy_curl",
            title: "HTTP: copy the request as a curl command",
            group: "http",
            keys: &[],
            run: |app| app.copy_active_curl(),
        },
        Command {
            id: "http.copy_response_headers",
            title: "HTTP: copy the response headers",
            group: "http",
            keys: &[],
            run: |app| app.http_copy_response_headers(),
        },
        Command {
            id: "cloud_agents.view_compact",
            title: "Cloud Agents: compact row density",
            group: "cloud_agents",
            keys: &[],
            run: |app| app.cloud_agents_set_view(crate::app::CloudAgentsView::Compact),
        },
        Command {
            id: "cloud_agents.view_standard",
            title: "Cloud Agents: standard row density",
            group: "cloud_agents",
            keys: &[],
            run: |app| app.cloud_agents_set_view(crate::app::CloudAgentsView::Standard),
        },
        Command {
            id: "http.save",
            title: "HTTP: save request (Save-As if new)",
            group: "http",
            keys: &[],
            run: |app| app.http_save_or_prompt_save_as(),
        },
        Command {
            id: "http.generate_code",
            title: "HTTP: generate code snippet from the active request",
            group: "http",
            keys: &[],
            run: |app| app.http_generate_code_prompt(),
        },
        Command {
            id: "http.toggle_view",
            title: "HTTP: toggle Request pane between Edit ⇄ Response",
            group: "http",
            keys: &[],
            run: |app| {
                use crate::pane::Pane;
                use crate::request_pane::ViewMode;
                if let Some(cur) = app.active
                    && let Some(Pane::Request(rp)) = app.panes.get_mut(cur)
                {
                    rp.view = match rp.view {
                        ViewMode::Edit => ViewMode::Response,
                        ViewMode::Response => ViewMode::Edit,
                    };
                }
            },
        },
        Command {
            id: "http.copy_response_body",
            title: "HTTP: copy the response body",
            group: "http",
            keys: &[],
            run: |app| app.copy_active_response_body(),
        },
        Command {
            id: "http.toggle_response_wrap",
            title: "HTTP: toggle response body wrap",
            group: "http",
            keys: &[],
            run: |app| app.http_toggle_response_wrap(),
        },
        Command {
            id: "http.toggle_auto_format_body",
            title: "HTTP: toggle auto-format request body (paste/send/load)",
            group: "http",
            keys: &[],
            run: |app| {
                app.config.http.auto_format_body = !app.config.http.auto_format_body;
                let state = if app.config.http.auto_format_body {
                    "on"
                } else {
                    "off"
                };
                app.toast(format!("auto_format_body: {state}"));
                if app.config.http.auto_format_body {
                    // Immediately format the currently-open body so
                    // the toggle feels responsive.
                    app.maybe_auto_format_active_body();
                }
            },
        },
        Command {
            id: "http.toggle_split_orientation",
            title: "HTTP: cycle Request/Response split orientation (Auto → Vertical → Horizontal)",
            group: "http",
            keys: &[],
            run: |app| {
                let Some(cur) = app.active else { return };
                if let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur) {
                    rp.split_orientation = rp.split_orientation.toggle();
                }
            },
        },
        Command {
            id: "http.set_env_var_value",
            title: "HTTP: set value for env var at cursor / active request pane",
            group: "http",
            keys: &[],
            run: |app| {
                let name = app.pending_var_at_cursor_name();
                if name.is_empty() {
                    app.toast("no {{VAR}} at cursor / active pane");
                    return;
                }
                app.accept_env_vars(&name);
            },
        },
        Command {
            id: "http.jump_to_env_var",
            title: "HTTP: jump to env var definition at cursor / active request pane",
            group: "http",
            keys: &[],
            run: |app| {
                let name = app.pending_var_at_cursor_name();
                if name.is_empty() {
                    app.toast("no {{VAR}} at cursor / active pane");
                    return;
                }
                app.open_env_var_definition(&name);
            },
        },
        Command {
            id: "http.ai_debug",
            title: "HTTP: ask Claude why this request is failing",
            group: "http",
            keys: &[],
            run: |app| app.ai_debug_request(),
        },
        Command {
            id: "term.shell",
            title: "Terminal: open a NEW shell (split below)",
            group: "term",
            keys: &[],
            run: |app| app.open_shell(),
        },
        Command {
            id: "mount.open",
            title: "Mount: open a hosted sibling pane (prompts for binary)",
            group: "mount",
            keys: &[],
            run: |app| app.prompt_mount_open(),
        },
        Command {
            id: "mounts.refresh",
            title: "Mounts: re-scan manifests in .mnml/mounts/ + ~/.config/mnml/mounts/",
            group: "mount",
            keys: &[],
            run: |app| app.refresh_mount_manifests(),
        },
        Command {
            id: "integrations.refresh",
            title: "Integrations: re-scan manifests in .mnml/integrations/ + ~/.config/mnml/integrations/",
            group: "integrations",
            keys: &[],
            run: |app| app.refresh_integration_manifests(),
        },
        Command {
            id: "mounts.install",
            title: "Mounts: install a Mount-capable family sibling (auto-registers manifest)",
            group: "mount",
            keys: &[],
            run: |app| app.open_mount_install_picker(),
        },
        Command {
            id: "sibling.install",
            title: "Sibling: install any family sibling by id (Pty or Mount)",
            group: "mount",
            keys: &[],
            run: |app| app.open_sibling_install_picker(),
        },
        Command {
            id: "term.rename",
            title: "Terminal: rename this session (shown in the tab)",
            group: "term",
            keys: &[],
            run: |app| app.open_rename_session_prompt(),
        },
        Command {
            id: "dock.new_text",
            title: "Dock: new text widget (bottom-left)",
            group: "dock",
            keys: &[],
            run: |app| crate::dock::push_text_at(app, crate::dock::DockCorner::BottomLeft),
        },
        Command {
            id: "dock.new_text_br",
            title: "Dock: new text widget (bottom-right)",
            group: "dock",
            keys: &[],
            run: |app| crate::dock::push_text_at(app, crate::dock::DockCorner::BottomRight),
        },
        Command {
            id: "dock.new_text_tl",
            title: "Dock: new text widget (top-left)",
            group: "dock",
            keys: &[],
            run: |app| crate::dock::push_text_at(app, crate::dock::DockCorner::TopLeft),
        },
        Command {
            id: "dock.new_text_tr",
            title: "Dock: new text widget (top-right)",
            group: "dock",
            keys: &[],
            run: |app| crate::dock::push_text_at(app, crate::dock::DockCorner::TopRight),
        },
        Command {
            id: "dock.new_log_tail",
            title: "Dock: tail a file (bottom-left)",
            group: "dock",
            keys: &[],
            // Defaults to the workspace's `~/.mnml/run.log` so
            // users have something to test with. They can pass
            // a path arg or right-click the widget to change it.
            run: |app| {
                let path = app.workspace.join(".mnml").join("run.log");
                crate::dock::push_log_tail(app, crate::dock::DockCorner::BottomLeft, path);
            },
        },
        Command {
            id: "dock.close_all",
            title: "Dock: close all widgets",
            group: "dock",
            keys: &[],
            run: |app| {
                app.dock_widgets.clear();
            },
        },
        Command {
            id: "dock.move_corner_next",
            title: "Dock: move focused widget to next corner",
            group: "dock",
            keys: &[],
            run: |app| crate::dock::cycle_focused_corner(app),
        },
        Command {
            id: "term.scratch_toggle",
            title: "Terminal: quick scratch strip at the bottom (Ctrl+`)",
            group: "term",
            // `ctrl+\\` used to be a second binding here but it collides
            // with `view.split_right` (added via #273 for VS Code parity)
            // — the keymap's HashMap insert order makes the later command
            // silently win, killing whichever binding loses. Post-fix
            // hunt 2026-06-08 SEV-3. Now scratch_toggle is `Ctrl+`` only;
            // VS Code's split chord lands on view.split_right unambiguously.
            keys: &["ctrl+`"],
            run: |app| app.toggle_scratch_term(),
        },
        Command {
            id: "term.focus_or_open_shell",
            title: "Terminal: focus existing shell or open one",
            group: "term",
            // #polish 2026-07-07 (vscode-user SEV-2 #5) — dropped
            // Ctrl+T; VS Code binds Ctrl+T to "Go to Symbol in
            // Workspace" and users hit it reflexively. Terminal
            // is already on Ctrl+backtick (the standard VS Code
            // chord for the same action).
            keys: &[],
            run: |app| app.focus_or_open_shell(),
        },
        Command {
            id: "picker.workspace_symbol",
            title: "Go to Symbol in Workspace (VS Code Ctrl+T)",
            group: "picker",
            // Alias for lsp.workspace_symbols so the VS Code chord
            // lands on the right thing.
            keys: &["ctrl+t"],
            run: |app| app.lsp_workspace_symbols(),
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
            title: "AI: open Claude Code (right dock)",
            group: "ai",
            // No global key — `Ctrl+Shift+A` isn't distinguishable in most terminals; use `<leader>a c`.
            keys: &[],
            run: |app| app.open_claude_code(),
        },
        Command {
            id: "ai.chat",
            title: "AI: Claude chat — prompt + file/selection context",
            group: "ai",
            keys: &[],
            run: |app| app.open_ai_chat_prompt(),
        },
        Command {
            id: "ai.claude_code_new",
            title: "AI: open a NEW Claude Code session (multi-session)",
            group: "ai",
            keys: &[],
            run: |app| app.open_claude_code_new(),
        },
        Command {
            id: "ai.codex",
            title: "AI: open Codex (right dock)",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex(),
        },
        Command {
            id: "ai.codex_new",
            title: "AI: open a NEW Codex session (multi-session)",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex_new(),
        },
        // 2026-07-09 — placement variants dispatched from the tab
        // strip's AI-chip right-click menu. Not registered on chords;
        // pure palette / context-menu entries.
        Command {
            id: "ai.claude_code_new_left",
            title: "AI: new Claude Code session in left half",
            group: "ai",
            keys: &[],
            run: |app| app.open_claude_code_new_at(crate::app::ai::PanePlacement::LeftHalf),
        },
        Command {
            id: "ai.claude_code_new_right",
            title: "AI: new Claude Code session in right half",
            group: "ai",
            keys: &[],
            run: |app| app.open_claude_code_new_at(crate::app::ai::PanePlacement::RightHalf),
        },
        Command {
            id: "ai.claude_code_new_top",
            title: "AI: new Claude Code session in top half",
            group: "ai",
            keys: &[],
            run: |app| app.open_claude_code_new_at(crate::app::ai::PanePlacement::TopHalf),
        },
        Command {
            id: "ai.claude_code_new_bottom",
            title: "AI: new Claude Code session in bottom half",
            group: "ai",
            keys: &[],
            run: |app| app.open_claude_code_new_at(crate::app::ai::PanePlacement::BottomHalf),
        },
        Command {
            id: "ai.codex_new_left",
            title: "AI: new Codex session in left half",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex_new_at(crate::app::ai::PanePlacement::LeftHalf),
        },
        Command {
            id: "ai.codex_new_right",
            title: "AI: new Codex session in right half",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex_new_at(crate::app::ai::PanePlacement::RightHalf),
        },
        Command {
            id: "ai.codex_new_top",
            title: "AI: new Codex session in top half",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex_new_at(crate::app::ai::PanePlacement::TopHalf),
        },
        Command {
            id: "ai.codex_new_bottom",
            title: "AI: new Codex session in bottom half",
            group: "ai",
            keys: &[],
            run: |app| app.open_codex_new_at(crate::app::ai::PanePlacement::BottomHalf),
        },
        Command {
            id: "mixr.show",
            title: "Mixr: open the TUI DJ in a Pty pane",
            group: "ai",
            keys: &[],
            run: |app| app.open_mixr(),
        },
        Command {
            id: "mixr.copy_track",
            title: "Mixr: copy the now-playing track title to clipboard",
            group: "ai",
            keys: &[],
            run: |app| {
                if let Some(np) = app.now_playing.as_ref()
                    && !np.track.is_empty()
                {
                    let track = np.track.clone();
                    app.clipboard.set(track.clone(), false);
                    app.toast(format!("copied: {track}"));
                } else {
                    app.toast("mixr: nothing playing");
                }
            },
        },
        Command {
            id: "browser.open",
            title: "Browser: open Chrome (CDP) — console / nav / eval",
            group: "browser",
            keys: &[],
            run: |app| app.open_browser_prompt(),
        },
        Command {
            id: "browser.dock_toggle",
            title: "Browser: dock Chrome side-by-side (macOS) / restore",
            group: "browser",
            keys: &[],
            run: |app| app.browser_dock_toggle(),
        },
        Command {
            id: "browser.install_cft",
            title: "Browser: install Chrome for Testing via npx",
            group: "browser",
            keys: &[],
            run: |app| app.browser_install_cft(),
        },
        Command {
            id: "browser.reload",
            title: "Browser: reload the current page (Page.reload)",
            group: "browser",
            // Same as `r` inside the browser pane; surfaces it via
            // the palette so users who can't recall the chord can
            // discover it.
            keys: &[],
            run: |app| app.browser_reload(),
        },
        Command {
            id: "browser.navigate",
            title: "Browser: navigate to a URL (prompt, seeded with current)",
            group: "browser",
            // Same as `g` inside the browser pane.
            keys: &[],
            run: |app| app.browser_navigate_prompt(),
        },
        Command {
            id: "browser.copy_url",
            title: "Browser: copy current URL to clipboard",
            group: "browser",
            keys: &[],
            run: |app| app.browser_copy_url(),
        },
        Command {
            id: "browser.back",
            title: "Browser: navigate back (window.history.back)",
            group: "browser",
            keys: &[],
            run: |app| app.browser_back(),
        },
        Command {
            id: "browser.forward",
            title: "Browser: navigate forward (window.history.forward)",
            group: "browser",
            keys: &[],
            run: |app| app.browser_forward(),
        },
        Command {
            id: "browser.devtools",
            title: "Browser: open DevTools (chrome://inspect hint)",
            group: "browser",
            keys: &[],
            run: |app| app.browser_open_devtools_hint(),
        },
        Command {
            id: "setup.install_to_path",
            title: "Setup: install mnml to PATH (so `mnml .` works anywhere)",
            group: "view",
            keys: &[],
            run: |app| app.show_install_to_path_hint(),
        },
        Command {
            id: "browser.network_throttle",
            title: "Browser: network throttle picker (Online/Offline/3G/WiFi)",
            group: "browser",
            keys: &[],
            run: |app| app.open_browser_network_throttle_picker(),
        },
        Command {
            id: "ai.write_branch_name",
            title: "AI: suggest a branch name from a natural-language description",
            group: "ai",
            keys: &[],
            run: |app| app.request_ai_write_branch_name(),
        },
        Command {
            id: "ai.recompose_branch",
            title: "AI: draft rewritten commit messages for this branch (does NOT mutate history)",
            group: "ai",
            // Walks merge-base..HEAD via git log, asks Claude to
            // rewrite each commit message, lands the draft in a
            // [recompose-suggestions] scratch. User applies the
            // rebase themselves — we deliberately don't mutate
            // history from inside mnml.
            keys: &[],
            run: |app| app.request_ai_recompose_branch(),
        },
        Command {
            id: "ai.explain_diff",
            title: "AI: explain the staged diff (or working-tree diff) — Claude walks through it",
            group: "ai",
            keys: &[],
            run: |app| app.request_ai_explain_diff(),
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
            id: "browser.print_pdf",
            title: "Browser: print the page to PDF (p) → .mnml/screenshots/",
            group: "browser",
            keys: &[],
            run: |app| app.browser_print_pdf(),
        },
        Command {
            id: "browser.snapshot",
            title: "Browser: snapshot state (URL + network + cookies + storage)",
            group: "browser",
            keys: &[],
            run: |app| app.browser_snapshot(),
        },
        Command {
            id: "browser.diff_snapshot",
            title: "Browser: diff latest snapshot vs current state",
            group: "browser",
            keys: &[],
            run: |app| app.browser_diff_snapshot(),
        },
        Command {
            id: "browser.clear_snapshots",
            title: "Browser: clear all captured snapshots",
            group: "browser",
            keys: &[],
            run: |app| app.browser_clear_snapshots(),
        },
        Command {
            id: "browser.device_picker",
            title: "Browser: device emulation picker (m) — mobile UA + viewport",
            group: "browser",
            keys: &[],
            run: |app| app.open_browser_device_picker(),
        },
        Command {
            id: "browser.scroll_node_into_view",
            title: "Browser: scroll the selected DOM node into view",
            group: "browser",
            keys: &[],
            run: |app| app.browser_scroll_node_into_view(),
        },
        Command {
            id: "browser.url_history",
            title: "Browser: fuzzy pick a previously-visited URL (Ctrl+R)",
            group: "browser",
            keys: &[],
            run: |app| app.open_browser_history_picker(),
        },
        Command {
            id: "browser.cookies",
            title: "Browser: toggle the cookies panel (K) — Network.getCookies",
            group: "browser",
            keys: &[],
            run: |app| app.browser_open_cookies(),
        },
        Command {
            id: "browser.delete_cookie",
            title: "Browser: delete the selected cookie (d in cookies panel)",
            group: "browser",
            keys: &[],
            run: |app| app.delete_selected_cookie(),
        },
        Command {
            id: "browser.wipe_profile",
            title: "Browser: wipe Chrome's user-data-dir (next open starts fresh)",
            group: "browser",
            keys: &[],
            run: |app| app.wipe_browser_profile(),
        },
        Command {
            id: "browser.edit_cookie",
            title: "Browser: edit the selected cookie's value (e in cookies panel)",
            group: "browser",
            keys: &[],
            run: |app| app.edit_selected_cookie(),
        },
        Command {
            id: "browser.add_cookie",
            title: "Browser: add a cookie scoped to the current origin (a in cookies panel)",
            group: "browser",
            keys: &[],
            run: |app| app.add_cookie_prompt(),
        },
        Command {
            id: "browser.edit_storage",
            title: "Browser: edit the selected Web Storage entry (e in storage panel)",
            group: "browser",
            keys: &[],
            run: |app| app.edit_selected_storage(),
        },
        Command {
            id: "browser.add_storage",
            title: "Browser: add a Web Storage entry (a in storage panel)",
            group: "browser",
            keys: &[],
            run: |app| app.add_storage_prompt(),
        },
        Command {
            id: "browser.delete_storage",
            title: "Browser: delete the selected Web Storage entry (d in storage panel)",
            group: "browser",
            keys: &[],
            run: |app| app.delete_selected_storage(),
        },
        Command {
            id: "browser.perf",
            title: "Browser: toggle the performance panel (P) — timings + Core Web Vitals",
            group: "browser",
            keys: &[],
            run: |app| app.browser_open_perf(),
        },
        Command {
            id: "browser.storage",
            title: "Browser: toggle the Web Storage panel (L) — localStorage + sessionStorage",
            group: "browser",
            keys: &[],
            run: |app| app.browser_open_storage(),
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
            title: "AI: ask Claude a question",
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
            id: "ai.reask",
            title: "AI: re-ask (fresh session)",
            group: "ai",
            keys: &[],
            run: |app| app.resend_active_ai(),
        },
        Command {
            id: "ai.cancel",
            title: "AI: cancel running job",
            group: "ai",
            keys: &[],
            run: |app| app.cancel_active_ai(),
        },
        Command {
            id: "ai.promote",
            title: "AI: promote to interactive (claude --resume)",
            group: "ai",
            keys: &[],
            run: |app| app.continue_active_ai(),
        },
        Command {
            id: "ai.apply",
            title: "AI: apply suggested change",
            group: "ai",
            keys: &[],
            run: |app| app.apply_ai_suggestion(),
        },
        Command {
            id: "ai.session_view",
            title: "AI: mirror this Claude session's transcript (live)",
            group: "ai",
            keys: &[],
            run: |app| app.open_session_view(),
        },
        Command {
            id: "cargo.test",
            title: "Cargo: run `cargo test` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_cargo_subcommand("test"),
        },
        Command {
            id: "cargo.check",
            title: "Cargo: run `cargo check` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_cargo_subcommand("check"),
        },
        Command {
            id: "cargo.clippy",
            title: "Cargo: run `cargo clippy --all-targets` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_cargo_subcommand("clippy --all-targets"),
        },
        Command {
            id: "cargo.build",
            title: "Cargo: run `cargo build` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_cargo_subcommand("build"),
        },
        Command {
            id: "cargo.fmt",
            title: "Cargo: run `cargo fmt` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_cargo_subcommand("fmt"),
        },
        Command {
            id: "npm.test",
            title: "npm: run `npm test` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("test", "test"),
        },
        Command {
            id: "npm.run",
            title: "npm: run `npm run dev` (use npm.run_script for a different script)",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("run", "run dev"),
        },
        Command {
            id: "npm.run_script",
            title: "npm: prompt for a script name → run `npm run <script>`",
            group: "test",
            keys: &[],
            run: |app| app.open_npm_run_script_prompt(),
        },
        Command {
            id: "npm.build",
            title: "npm: run `npm run build` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("build", "run build"),
        },
        Command {
            id: "npm.start",
            title: "npm: run `npm start` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("start", "start"),
        },
        Command {
            id: "npm.install",
            title: "npm: run `npm install` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("install", "install"),
        },
        Command {
            id: "npm.lint",
            title: "npm: run `npm run lint` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_npm_subcommand("lint", "run lint"),
        },
        Command {
            id: "pytest.run",
            title: "pytest: run the suite in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_pytest(""),
        },
        Command {
            id: "pytest.failed",
            title: "pytest: re-run only last-failed (`--lf`)",
            group: "test",
            keys: &[],
            run: |app| app.run_pytest("--lf"),
        },
        Command {
            id: "go.test",
            title: "Go: run `go test ./...` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_go_subcommand("test ./..."),
        },
        Command {
            id: "go.build",
            title: "Go: run `go build ./...` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_go_subcommand("build ./..."),
        },
        Command {
            id: "go.vet",
            title: "Go: run `go vet ./...` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_go_subcommand("vet ./..."),
        },
        Command {
            id: "go.run",
            title: "Go: run `go run .` in a pty pane",
            group: "test",
            keys: &[],
            run: |app| app.run_go_subcommand("run ."),
        },
        Command {
            id: "go.run_path",
            title: "go: prompt for a package path → run `go run <path>`",
            group: "test",
            keys: &[],
            run: |app| app.open_go_run_path_prompt(),
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
            // design-critic 2026-07-06 r2 — was "ai", the only ai-*
            // outlier that spawns a Pty. Every other Pty command
            // (`term.*`) lives in "term"; move here for consistent
            // help-overlay grouping.
            group: "term",
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
            // VS Code parity (Ctrl+\\). Bug-hunt seed #273 from the
            // VS-Code-keyboard hunt 2026-06-07 — chord was unbound.
            // (Ctrl+T is the scratch-terminal toggle, NOT split.)
            keys: &["ctrl+\\"],
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
            // VS Code convention. Bound in 2026-06-13 session-3 sweep
            // (vscode-keyboard hunt S2-07: directional split focus
            // had no chord at all, palette-only).
            keys: &["ctrl+k ctrl+left"],
            run: |app| app.focus_dir(crate::app::FocusDir::Left),
        },
        Command {
            id: "view.focus_right",
            title: "Focus split right",
            group: "view",
            keys: &["ctrl+k ctrl+right"],
            run: |app| app.focus_dir(crate::app::FocusDir::Right),
        },
        Command {
            id: "view.focus_up",
            title: "Focus split up",
            group: "view",
            keys: &["ctrl+k ctrl+up"],
            run: |app| app.focus_dir(crate::app::FocusDir::Up),
        },
        Command {
            id: "view.focus_down",
            title: "Focus split down",
            group: "view",
            keys: &["ctrl+k ctrl+down"],
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
        // qa-6th keyboard SEV-2 2026-06-29: Shift+F10 chip-menu
        // fallback required `hover_chip` to be set within 2s, but
        // hover_chip only fires on mouse movement — keyboard
        // purists could never reach these menus. These palette
        // commands fire each statusline chip's menu directly,
        // anchored at the chip's screen position.
        // qa-8th design MED-3 2026-06-30 — was `statusline.*` IDs,
        // which leaked widget vocabulary into command names. mnml's
        // convention is function-first: `git.*` for git operations,
        // `clock.*` for clock, etc. Renamed to match topic; users
        // searching `:git.` now find branch_menu, `:clock.` finds
        // clock_menu.
        Command {
            id: "editor.input_mode_menu",
            title: "Open mode menu (vim / standard)",
            group: "editor",
            keys: &[],
            run: |app| {
                let anchor = app
                    .rects
                    .statusline_mode_chip
                    .map(|r| (r.x, r.y.saturating_sub(1)))
                    .unwrap_or((0, 0));
                app.open_statusline_mode_context_menu(anchor);
            },
        },
        Command {
            id: "view.workspace_menu",
            title: "Open workspace menu",
            group: "view",
            keys: &[],
            run: |app| {
                let anchor = app
                    .rects
                    .statusline_workspace_chip
                    .map(|r| (r.x, r.y.saturating_sub(1)))
                    .unwrap_or((0, 0));
                app.open_statusline_workspace_context_menu(anchor);
            },
        },
        Command {
            id: "git.branch_menu",
            title: "Open branch menu",
            group: "git",
            keys: &[],
            run: |app| {
                let anchor = app
                    .rects
                    .statusline_branch_chip
                    .map(|r| (r.x, r.y.saturating_sub(1)))
                    .unwrap_or((0, 0));
                app.open_statusline_branch_context_menu(anchor);
            },
        },
        Command {
            id: "clock.menu",
            title: "Open clock menu (local ⇄ UTC)",
            group: "clock",
            keys: &[],
            run: |app| {
                let anchor = app
                    .rects
                    .statusline_clock_chip
                    .map(|r| (r.x, r.y.saturating_sub(1)))
                    .unwrap_or((0, 0));
                app.open_statusline_clock_context_menu(anchor);
            },
        },
    ];
    // Bitbucket panes moved to mnml-forge-bitbucket — the entire
    // bitbucket.* command surface was removed alongside the panes.
    // Users install mnml-forge-bitbucket and launch it via
    // `:term mnml-forge-bitbucket` (the default
    // `[[ui.integration_icon]]` now points at it).

    // GitHub commands moved to the standalone mnml-forge-github
    // binary in 2026-06.
    // GitLab + Azure DevOps commands moved to their mnml-forge-*
    // siblings in 2026-06. The cross-host `pr.picker` was removed
    // too — no in-core caches to aggregate.
    // `aws.*` commands moved to mnml-aws-codebuild in 2026-06.
    cmds
}
