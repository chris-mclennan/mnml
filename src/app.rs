//! Pure application state — no rendering, no event loop. The terminal loop
//! (`tui.rs`) and the headless loop (`headless.rs`) both drive an `App`; the
//! render path (`ui::draw`) reads it and fills `rects` for mouse hit-testing.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ratatui::layout::Rect;

use crate::buffer::Buffer;
use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::focus::Focus;
use crate::git::GitStatus;
use crate::input::EditingMode;
use crate::layout::{Layout, PaneId};
use crate::pane::Pane;
use crate::picker::{Picker, PickerKind};
use crate::tree::Tree;

const TOAST_TTL: Duration = Duration::from_secs(4);

/// Direction for `Ctrl+W`-style focus navigation between splits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusDir {
    Left,
    Right,
    Up,
    Down,
}

/// `p` made relative to `workspace` (for `git` arguments). Falls back to `p` if
/// it isn't under `workspace`.
fn rel_path(workspace: &Path, p: &Path) -> String {
    p.strip_prefix(workspace)
        .unwrap_or(p)
        .to_string_lossy()
        .into_owned()
}

/// Turn a file's `(range, new_text)` LSP edits into `EditOp::ReplaceRange`s with
/// byte offsets resolved against `text`, sorted *descending* by start so applying
/// them in order keeps the earlier offsets valid. Edits with unresolvable
/// positions are dropped.
fn build_replace_ops(
    text: &str,
    edits: &[(crate::lsp::Range, String)],
) -> Vec<crate::edit_op::EditOp> {
    let mut tuples: Vec<(usize, usize, String)> = edits
        .iter()
        .filter_map(|(r, t)| {
            let s = crate::lsp::byte_at(text, r.start.line, r.start.character)?;
            let e = crate::lsp::byte_at(text, r.end.line, r.end.character)?;
            Some((s.min(e), s.max(e), t.clone()))
        })
        .collect();
    tuples.sort_by_key(|t| std::cmp::Reverse(t.0));
    tuples
        .into_iter()
        .map(|(start, end, text)| crate::edit_op::EditOp::ReplaceRange { start, end, text })
        .collect()
}

/// Screen regions captured during render, consumed for mouse routing on the next event.
#[derive(Debug, Default, Clone)]
pub struct PaneRects {
    pub tree: Option<Rect>,
    /// Tree scroll offset at render time (so a click maps to the right row).
    pub tree_scroll: usize,
    pub bufferline: Option<Rect>,
    /// `(rect, pane_id)` for each tab in the bufferline (whole tab → activate).
    pub bufferline_tabs: Vec<(Rect, PaneId)>,
    /// `(rect, pane_id)` for each tab's close badge (the trailing `×`/`●` → close).
    pub bufferline_tab_close: Vec<(Rect, PaneId)>,
    /// The whole central split-tree area.
    pub body: Option<Rect>,
    /// `(text_area, pane_id)` per visible editor leaf — the editable region
    /// (gutter excluded). Click → focus that leaf + place the cursor; also the
    /// geometry `Ctrl+W`-style focus navigation uses.
    pub editor_panes: Vec<(Rect, PaneId)>,
    /// One entry per split divider, with enough info to drag-resize it.
    pub split_dividers: Vec<crate::layout::DividerHit>,
    pub statusline: Option<Rect>,
    /// The picker overlay's outer box (when open) and `(rect, filtered-index)` per visible row.
    pub picker_box: Option<Rect>,
    pub picker_items: Vec<(Rect, usize)>,
    /// On-screen cell where the picker's query caret should sit (when open).
    pub picker_caret: Option<(u16, u16)>,
    /// `(rect, choice)` per button in the close-confirm overlay (0=Save, 1=Discard, 2=Cancel).
    pub close_prompt_buttons: Vec<(Rect, u8)>,
    /// On-screen cell where the text-input prompt's caret should sit (when open).
    pub prompt_caret: Option<(u16, u16)>,
    /// The context-menu overlay's outer box (when open) and `(rect, item-index)` per row.
    pub context_menu_box: Option<Rect>,
    pub context_menu_items: Vec<(Rect, usize)>,
}

pub struct App {
    pub workspace: PathBuf,
    pub config: Config,
    pub panes: Vec<Pane>,
    pub layout: Layout,
    /// The focused pane id. Invariant (see [`crate::layout`]): every pane is in
    /// exactly one leaf, so this uniquely identifies the focused leaf. `None` ⇔
    /// `layout == Empty` ⇔ no panes open.
    pub active: Option<PaneId>,
    pub focus: Focus,
    pub tree: Tree,
    pub tree_visible: bool,
    pub git: GitStatus,
    pub toast: Option<(String, Instant)>,
    pub should_quit: bool,
    /// Set alongside `should_quit` when the loop should exit *for a rebuild+relaunch*
    /// (the `run.sh` wrapper watches for the distinct exit code).
    pub restart_requested: bool,
    /// True after a quit was refused because of unsaved changes — a second
    /// `request_quit` then goes through. Cleared by saving.
    pub quit_armed: bool,
    pub rects: PaneRects,
    /// The active register / system-clipboard bridge, threaded into `Editor::apply`.
    pub clipboard: Clipboard,
    /// The fuzzy-picker / command-palette overlay, when open. Steals key input.
    pub picker: Option<Picker>,
    /// Resolved key→command table (registry defaults + `[keys.*]` config).
    /// Rebuilt when the input style changes (a mode section may rebind a chord).
    pub keymap: crate::input::keymap::Keymap,
    /// While a leader sequence is in flight: the keys typed after `<leader>`
    /// (`Some("")` ⇒ the popup just opened). Steals key input like the picker.
    pub whichkey: Option<String>,
    /// The split divider currently being dragged (between mouse-down on it and
    /// mouse-up), so drag events resize *that* split even off-target.
    pub dragging: Option<crate::layout::DividerHit>,
    /// A buffer whose close is awaiting a Save/Discard/Cancel decision (the
    /// confirm overlay is up). Steals key input like the picker.
    pub close_prompt: Option<PaneId>,
    /// The single-line text-input overlay (commit message, …), when open. Steals
    /// key input like the picker.
    pub prompt: Option<crate::prompt::Prompt>,
    /// The right-click context menu, when open. Steals key + mouse input.
    pub context_menu: Option<crate::context_menu::ContextMenu>,
    /// The LSP hover popup, when open (set when a `textDocument/hover` reply
    /// arrives). The next key dismisses it (j/k/arrows scroll it first).
    pub hover: Option<crate::hover::HoverPopup>,
    /// `(path, line, character)` of an in-flight LSP rename — captured when the
    /// rename prompt opens so the accept handler sends the request for that spot.
    pending_rename: Option<(PathBuf, u32, u32)>,
    /// The as-you-type LSP completion popup, when open. Populated from a
    /// `textDocument/completion` reply (auto-triggered as you type, or via
    /// `lsp.completion`); re-filtered locally as you keep typing.
    pub completion: Option<crate::completion::CompletionPopup>,
    /// Channel for background HTTP sends (lazily created on the first `rqst.send`):
    /// worker threads send `(job_id, result)`; [`Self::tick`] drains it and updates
    /// the matching `Pane::Request`.
    http_chan: Option<(
        std::sync::mpsc::Sender<HttpJobDone>,
        std::sync::mpsc::Receiver<HttpJobDone>,
    )>,
    /// Channel for background `claude -p` runs (lazily created); worker threads
    /// send `(job_id, result)`, [`Self::tick`] drains it into the matching `Pane::Ai`.
    ai_chan: Option<(
        std::sync::mpsc::Sender<AiJobDone>,
        std::sync::mpsc::Receiver<AiJobDone>,
    )>,
    /// Channel for background `npx playwright test` runs → the matching `Pane::Tests`.
    tests_chan: Option<(
        std::sync::mpsc::Sender<TestsJobDone>,
        std::sync::mpsc::Receiver<TestsJobDone>,
    )>,
    /// Job id of an in-flight "AI: write me a commit message" run (it shares
    /// `ai_chan`; when it lands, the commit prompt opens pre-seeded instead of an
    /// answer landing in a `Pane::Ai`).
    pending_commit_msg_job: Option<u64>,
    next_job_id: u64,
    /// Commands registered at runtime by IPC plugins (`register-command`). They
    /// show up in the palette/which-key + keymap; invoking one queues its id in
    /// `pending_plugin_invocations` for the IPC layer to log as an event.
    pub dynamic_commands: Vec<crate::command::DynCommand>,
    /// Plugin-command ids invoked since the IPC layer last drained them.
    pending_plugin_invocations: Vec<String>,
    /// LSP client subsystem — one server subprocess per (project-root, language),
    /// feeding diagnostics + go-to-def/hover results back through `tick`.
    pub lsp: crate::lsp::LspManager,
}

type HttpJobDone = (u64, Result<crate::request_pane::ResponseView, String>);
type AiJobDone = (u64, Result<String, String>);
type TestsJobDone = (u64, Result<crate::playwright::TestRun, String>);

impl App {
    pub fn new(workspace: PathBuf, config: Config) -> Result<App, String> {
        let workspace = workspace
            .canonicalize()
            .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
        let tree = Tree::open(&workspace);
        let git = GitStatus::new(&workspace);
        let lsp = crate::lsp::LspManager::new(&workspace, &config);
        let keymap = crate::input::keymap::Keymap::build(&config);
        Ok(App {
            workspace,
            config,
            panes: Vec::new(),
            layout: Layout::Empty,
            active: None,
            focus: Focus::Tree,
            tree,
            tree_visible: true,
            git,
            toast: None,
            should_quit: false,
            restart_requested: false,
            quit_armed: false,
            rects: PaneRects::default(),
            clipboard: Clipboard::new(),
            picker: None,
            keymap,
            whichkey: None,
            dragging: None,
            close_prompt: None,
            prompt: None,
            context_menu: None,
            hover: None,
            pending_rename: None,
            completion: None,
            http_chan: None,
            ai_chan: None,
            tests_chan: None,
            pending_commit_msg_job: None,
            next_job_id: 1,
            dynamic_commands: Vec::new(),
            pending_plugin_invocations: Vec::new(),
            lsp,
        })
    }

    // ─── which-key (leader menu) ────────────────────────────────────
    /// Open the leader popup (the next keys walk the trie in `whichkey.rs`).
    pub fn open_whichkey(&mut self) {
        self.whichkey = Some(String::new());
    }
    pub fn whichkey_cancel(&mut self) {
        self.whichkey = None;
    }
    /// Feed one key into the leader sequence: descend a group, run a leaf, or
    /// (dead end) toast and close.
    pub fn whichkey_feed(&mut self, ch: char) {
        let Some(mut prefix) = self.whichkey.take() else {
            return;
        };
        prefix.push(ch);
        match crate::whichkey::lookup(&prefix) {
            Some(crate::whichkey::Leader::Cmd { id, .. }) => {
                let id = *id;
                crate::command::run(id, self);
            }
            Some(crate::whichkey::Leader::Group { .. }) => self.whichkey = Some(prefix),
            None => self.toast(format!("no leader mapping: <leader>{prefix}")),
        }
    }
    /// `(prefix-typed-so-far, continuations)` for the popup, if open.
    pub fn whichkey_menu(&self) -> Option<(&str, Vec<crate::whichkey::Entry>)> {
        let prefix = self.whichkey.as_deref()?;
        Some((prefix, crate::whichkey::continuations(prefix)))
    }

    // ─── context menu (right-click) ─────────────────────────────────
    /// Right-click in the file tree on `path` (at screen cell `anchor`).
    pub fn open_tree_context_menu(&mut self, path: PathBuf, is_dir: bool, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let rel = rel_path(&self.workspace, &path);
        let items = if is_dir {
            vec![
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
                MenuItem::new("Refresh tree", MenuAction::Command("tree.refresh")),
            ]
        } else {
            vec![
                MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
                MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
                MenuItem::new("Reveal in Finder", MenuAction::RevealInFinder(path.clone())),
                MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            ]
        };
        self.context_menu = Some(ContextMenu::new(Some(name), anchor, items));
    }

    /// Right-click on a bufferline tab (the pane `id`) at screen cell `anchor`.
    pub fn open_tab_context_menu(&mut self, id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self.panes.get(id).map(Pane::title).unwrap_or_default();
        let mut items = vec![
            MenuItem::new("Close", MenuAction::CloseTab(id)),
            MenuItem::new("Close others", MenuAction::CloseOtherTabs(id)),
            MenuItem::new("Close all", MenuAction::CloseAllTabs),
        ];
        if let Some(Pane::Editor(b)) = self.panes.get(id)
            && let Some(p) = &b.path
        {
            items.push(MenuItem::new(
                "Copy path",
                MenuAction::CopyPath(rel_path(&self.workspace, p)),
            ));
        }
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    pub fn context_menu_cancel(&mut self) {
        self.context_menu = None;
    }
    pub fn context_menu_move(&mut self, delta: isize) {
        if let Some(m) = &mut self.context_menu {
            if delta < 0 {
                m.move_up();
            } else {
                m.move_down();
            }
        }
    }
    pub fn context_menu_select(&mut self, i: usize) {
        if let Some(m) = &mut self.context_menu {
            m.set_selected(i);
        }
    }
    /// Run the highlighted context-menu item and close the menu.
    pub fn context_menu_accept(&mut self) {
        let Some(menu) = self.context_menu.take() else {
            return;
        };
        let Some(item) = menu.items.into_iter().nth(menu.selected) else {
            return;
        };
        self.run_menu_action(item.action);
    }

    fn run_menu_action(&mut self, action: crate::context_menu::MenuAction) {
        use crate::context_menu::MenuAction::*;
        match action {
            OpenPath(p) => self.open_path(&p),
            OpenInSplit(p) => {
                self.split_active(crate::layout::SplitDir::Horizontal);
                self.open_path(&p);
            }
            RevealInFinder(p) => {
                // macOS; harmless no-op (an Err we ignore) elsewhere.
                let _ = std::process::Command::new("open").arg("-R").arg(&p).spawn();
            }
            CopyPath(text) => {
                self.clipboard.set(text.clone(), false);
                self.toast(format!("copied {text}"));
            }
            Command(id) => {
                crate::command::run(id, self);
            }
            CloseTab(id) => self.close_pane(id),
            CloseOtherTabs(id) => self.close_panes_except(Some(id)),
            CloseAllTabs => self.close_panes_except(None),
        }
    }

    /// Close every pane (optionally keeping `keep`), skipping dirty editors so
    /// nothing is lost silently — they're kept and counted.
    fn close_panes_except(&mut self, keep: Option<PaneId>) {
        let mut kept_dirty = 0usize;
        // Walk high→low so the indices below the one we close stay valid.
        for i in (0..self.panes.len()).rev() {
            if Some(i) == keep {
                continue;
            }
            if matches!(self.panes.get(i), Some(Pane::Editor(b)) if b.dirty) {
                kept_dirty += 1;
                continue;
            }
            self.force_close_pane(i);
        }
        if kept_dirty > 0 {
            self.toast(format!(
                "kept {kept_dirty} unsaved buffer(s) — save or :q! them"
            ));
        }
    }

    // ─── picker / palette ───────────────────────────────────────────
    pub fn open_picker(&mut self, picker: Picker) {
        self.whichkey = None;
        self.picker = Some(picker);
    }
    pub fn close_picker(&mut self) {
        self.picker = None;
    }
    /// Open the fuzzy file finder over every file in the workspace.
    pub fn open_file_picker(&mut self) {
        use crate::picker::PickerItem;
        let root = self.workspace.clone();
        let items: Vec<PickerItem> = self
            .tree
            .all_files()
            .into_iter()
            .map(|p| {
                let rel = p.strip_prefix(&root).unwrap_or(&p).to_path_buf();
                let label = rel.to_string_lossy().to_string();
                let dir = rel
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                PickerItem::new(p.to_string_lossy().to_string(), label, dir)
            })
            .collect();
        self.open_picker(Picker::new(PickerKind::Files, "Open file", items));
    }
    /// Open the buffer switcher over the currently-open panes.
    pub fn open_buffer_picker(&mut self) {
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = self
            .panes
            .iter()
            .enumerate()
            .map(|(i, p)| {
                PickerItem::new(
                    i.to_string(),
                    p.title(),
                    if p.is_dirty() { "●" } else { "" },
                )
            })
            .collect();
        if items.is_empty() {
            self.toast("no open buffers");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Buffers, "Switch buffer", items));
    }
    /// Open the command palette over the registered commands (builtins + any
    /// plugin-registered ones).
    pub fn open_command_palette(&mut self) {
        use crate::picker::PickerItem;
        let mut items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| PickerItem::new(c.id, format!("{}  ·  {}", c.group, c.title), c.key_hint()))
            .collect();
        for dc in &self.dynamic_commands {
            items.push(PickerItem::new(
                dc.id.clone(),
                format!("{}  ·  {}", dc.group, dc.title),
                dc.keys.join(" / "),
            ));
        }
        self.open_picker(Picker::new(PickerKind::Commands, "Command palette", items));
    }

    // ─── plugin-registered (dynamic) commands ───────────────────────
    /// Add (or replace) a plugin-registered command and bind any keyspecs it asked
    /// for. Idempotent on `id`.
    pub fn register_dynamic_command(&mut self, dc: crate::command::DynCommand) {
        for spec in &dc.keys {
            self.keymap.bind(spec, &dc.id);
        }
        if let Some(slot) = self.dynamic_commands.iter_mut().find(|c| c.id == dc.id) {
            *slot = dc;
        } else {
            self.toast(format!("plugin command registered: {}", dc.title));
            self.dynamic_commands.push(dc);
        }
    }
    /// If `id` is a plugin command, queue it for the IPC layer to log and return
    /// true; otherwise false. (Called by `command::run` after the builtin lookup.)
    pub fn run_dynamic_command(&mut self, id: &str) -> bool {
        if self.dynamic_commands.iter().any(|c| c.id == id) {
            self.pending_plugin_invocations.push(id.to_string());
            true
        } else {
            false
        }
    }
    /// Take the plugin-command ids invoked since the last call (the IPC layer
    /// appends a `plugin-command` event for each so the plugin can react).
    pub fn take_pending_plugin_invocations(&mut self) -> Vec<String> {
        std::mem::take(&mut self.pending_plugin_invocations)
    }
    /// Open the theme picker over the built-in themes.
    pub fn open_theme_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::ui::theme::cur().name;
        let items: Vec<PickerItem> = crate::ui::theme::names()
            .into_iter()
            .map(|n| PickerItem::new(n, n, if n == cur { "current" } else { "" }))
            .collect();
        self.open_picker(Picker::new(PickerKind::Themes, "Theme", items));
    }
    /// Switch the active theme by name, re-highlight open buffers, and remember it.
    pub fn set_theme(&mut self, name: &str) {
        match crate::ui::theme::set(name) {
            Some(t) => {
                self.config.ui.theme = t.name.to_string();
                for pane in &mut self.panes {
                    if let Some(b) = pane.as_editor_mut() {
                        b.refresh_highlights();
                    }
                }
                self.toast(format!("theme: {}", t.name));
            }
            None => self.toast(format!(
                "unknown theme: {name} (have: {})",
                crate::ui::theme::names().join(", ")
            )),
        }
    }
    /// Act on the picker's current selection, then close it.
    pub fn picker_accept(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let Some(item) = picker.selected_item().cloned() else {
            return;
        };
        match picker.kind {
            PickerKind::Files => self.open_path(Path::new(&item.id)),
            PickerKind::Buffers => {
                if let Ok(i) = item.id.parse::<usize>()
                    && i < self.panes.len()
                {
                    self.reveal_pane(i);
                }
            }
            PickerKind::Commands => {
                crate::command::run(&item.id, self);
            }
            PickerKind::Themes => self.set_theme(&item.id),
            PickerKind::Tasks => self.run_task(&item.id),
            PickerKind::Branches => self.checkout_branch(&item.id),
            PickerKind::Worktrees => self.open_worktree_shell(&item.id),
            PickerKind::Locations => {
                let mut parts = item.id.split('\t');
                if let (Some(p), Some(l), Some(c)) = (parts.next(), parts.next(), parts.next()) {
                    let path = std::path::PathBuf::from(p);
                    let line: usize = l.parse().unwrap_or(0);
                    let col: usize = c.parse().unwrap_or(0);
                    self.open_path(&path);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line, col);
                    }
                }
            }
        }
    }

    // ─── as-you-type LSP completion popup ───────────────────────────
    /// Move the completion-popup selection by `delta` rows (no-op if none open).
    pub fn completion_move(&mut self, delta: isize) {
        if let Some(p) = &mut self.completion {
            p.move_by(delta);
        }
    }

    /// Accept the highlighted completion: replace the identifier prefix left of
    /// the cursor with the item's insert text, then close the popup.
    pub fn completion_accept(&mut self) {
        let Some(popup) = self.completion.take() else {
            return;
        };
        let Some(item) = popup.current().cloned() else {
            return;
        };
        let prefix_len = popup.prefix.len(); // bytes — prefix chars are all id chars
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&popup.path)))
        else {
            return;
        };
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let cursor = b.editor.cursor();
            let start = cursor.saturating_sub(prefix_len);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end: cursor,
                    text: item.insert.clone(),
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx) {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&popup.path, &t);
        }
    }

    /// The identifier prefix (`[A-Za-z0-9_]*`) immediately left of the active
    /// editor's cursor, or `None` if there's no active editor.
    fn cursor_id_prefix(&self) -> Option<String> {
        let b = self.active_editor()?;
        let cur = b.editor.cursor();
        let t = b.editor.text();
        let mut v: Vec<char> = t[..cur]
            .chars()
            .rev()
            .take_while(|&c| c.is_alphanumeric() || c == '_')
            .collect();
        v.reverse();
        Some(v.into_iter().collect())
    }

    /// Called after every editor edit. Keeps an open completion popup in sync
    /// with what's being typed (re-filtering it, or closing it once the prefix
    /// empties / stops matching), and auto-triggers a fresh request on a member
    /// access (`.` / `:`) or the first character of a new word.
    pub fn completion_on_edit(&mut self, typed: Option<char>) {
        let is_id = |c: char| c.is_alphanumeric() || c == '_';
        let Some(prefix) = self.cursor_id_prefix() else {
            self.completion = None;
            return;
        };
        if let Some(popup) = &mut self.completion {
            if prefix.is_empty() || !popup.refilter(&prefix) {
                self.completion = None;
            } else {
                return; // already showing — refiltered locally, no re-request
            }
        }
        match typed {
            Some('.') | Some(':') => self.request_completion_at_cursor(),
            Some(c) if is_id(c) => {
                // Auto-trigger only at the start of a word (the char *before*
                // the one just typed isn't an identifier char) — subsequent
                // keystrokes just narrow the popup that this request opens.
                let at_word_start = self.active_editor().is_some_and(|b| {
                    let cur = b.editor.cursor();
                    let before: Vec<char> = b.editor.text()[..cur].chars().collect();
                    before.len() < 2 || !is_id(before[before.len() - 2])
                });
                if at_word_start {
                    self.request_completion_at_cursor();
                }
            }
            _ => {}
        }
    }

    /// Fire a `textDocument/completion` at the active editor's cursor — the reply
    /// (`tick` → `apply_lsp_event`) opens the popup. Assumes the server already
    /// has the latest text (the edit path sends `didChange` first). Silent if
    /// there's no server for the file.
    fn request_completion_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let (row, col) = b.editor.row_col();
        self.lsp.completion(&path, row as u32, col as u32);
    }

    /// `task.run` — open a picker over `[tasks.<name>]` config entries.
    pub fn open_task_picker(&mut self) {
        use crate::picker::PickerItem;
        if self.config.tasks.is_empty() {
            self.toast("no [tasks.*] defined in config".to_string());
            return;
        }
        let items: Vec<PickerItem> = self
            .config
            .tasks
            .iter()
            .map(|(name, t)| PickerItem::new(name.clone(), name.clone(), t.cmd.clone()))
            .collect();
        self.open_picker(Picker::new(PickerKind::Tasks, "Run task", items));
    }

    /// Run a named `[tasks.<name>]` entry in a new pty pane.
    pub fn run_task(&mut self, name: &str) {
        let Some(def) = self.config.tasks.get(name).cloned() else {
            self.toast(format!("unknown task: {name}"));
            return;
        };
        let cwd = match &def.cwd {
            Some(rel) => {
                let p = Path::new(rel);
                if p.is_absolute() {
                    p.to_path_buf()
                } else {
                    self.workspace.join(p)
                }
            }
            None => self.workspace.clone(),
        };
        self.open_pty(crate::pty_pane::BinaryProfile::task(name, &def.cmd, cwd));
    }

    /// `[startup] tasks = [...]` — run each on workspace open (called once by the
    /// event loop). Unknown names are toasted and skipped.
    pub fn run_startup_tasks(&mut self) {
        let names = self.config.startup_tasks.clone();
        for name in names {
            self.run_task(&name);
        }
    }

    // ─── panes / buffers ────────────────────────────────────────────
    pub fn active_pane(&self) -> Option<&Pane> {
        self.active.and_then(|i| self.panes.get(i))
    }
    pub fn active_pane_mut(&mut self) -> Option<&mut Pane> {
        match self.active {
            Some(i) => self.panes.get_mut(i),
            None => None,
        }
    }
    pub fn active_editor(&self) -> Option<&Buffer> {
        self.active_pane().and_then(Pane::as_editor)
    }
    pub fn active_editor_mut(&mut self) -> Option<&mut Buffer> {
        self.active_pane_mut().and_then(Pane::as_editor_mut)
    }

    /// Show pane `id` in the focused leaf (demoting whatever it showed to a
    /// background buffer). If `id` is already shown in some leaf, just focus that
    /// leaf instead — a buffer is never in two leaves at once. If nothing is open,
    /// create the first leaf showing `id`.
    pub fn reveal_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        if self.layout.contains(id) {
            self.active = Some(id);
        } else if let Some(cur) = self.active {
            self.layout.set_leaf_pane(cur, id);
            self.active = Some(id);
        } else {
            self.layout = Layout::Leaf(id);
            self.active = Some(id);
        }
        self.focus = Focus::Pane;
    }

    /// Open `path` in the focused leaf. If it's already an open buffer it's
    /// revealed/refocused; otherwise a new buffer is opened. The buffer the
    /// focused leaf was showing stays open as a background tab.
    pub fn open_path(&mut self, path: &Path) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            self.reveal_pane(i);
            return;
        }
        // (Pane kind is picked by extension — only `Editor` exists in P0; `.http`
        // etc. route to `Pane::Request` once that track lands.)
        match Buffer::open(&path, &self.config) {
            Ok(buf) => {
                let text = buf.editor.text().to_string();
                self.panes.push(Pane::Editor(buf));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
                self.lsp.did_open(&path, &text);
            }
            Err(e) => self.toast(format!("cannot open {}: {e}", path.display())),
        }
    }

    /// Tell the LSP server `path` was saved (re-reads the file — we just wrote it).
    fn notify_lsp_saved(&mut self, path: &Path) {
        if let Ok(text) = std::fs::read_to_string(path) {
            self.lsp.did_save(path, &text);
        }
    }

    // ─── LSP commands ───────────────────────────────────────────────
    /// `lsp.goto_definition` — ask the server where the symbol under the cursor
    /// is defined; the answer arrives async (`tick` jumps there).
    pub fn lsp_goto_definition(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_definition(p, l, c),
            "go-to-definition",
        );
    }
    /// `lsp.hover` — ask the server for hover docs at the cursor (`tick` toasts them).
    pub fn lsp_hover(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.hover(p, l, c), "hover");
    }
    /// `lsp.references` — find references to the symbol at the cursor (→ picker).
    pub fn lsp_references(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.references(p, l, c), "references");
    }
    /// `lsp.{next,prev}_diagnostic` — move the cursor to the next / previous
    /// diagnostic in the active buffer (wrapping), and show its message in the
    /// hover popup.
    pub fn lsp_goto_diagnostic(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        if b.diagnostics.is_empty() {
            self.toast("no diagnostics in this file");
            return;
        }
        let (row, col) = b.editor.row_col();
        let cur = (row as u32, col as u32);
        let mut diags: Vec<(u32, u32, String)> = b
            .diagnostics
            .iter()
            .map(|d| {
                (
                    d.range.start.line,
                    d.range.start.character,
                    d.message.clone(),
                )
            })
            .collect();
        diags.sort_by_key(|&(l, c, _)| (l, c));
        let target = if forward {
            diags
                .iter()
                .find(|&&(l, c, _)| (l, c) > cur)
                .or_else(|| diags.first())
        } else {
            diags
                .iter()
                .rev()
                .find(|&&(l, c, _)| (l, c) < cur)
                .or_else(|| diags.last())
        };
        let Some(&(l, c, ref msg)) = target else {
            return;
        };
        let (l, c, msg) = (l, c, msg.clone());
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(l as usize, c as usize);
        }
        match crate::hover::HoverPopup::from_text(&msg) {
            Some(h) => self.hover = Some(h),
            None => self.toast(msg),
        }
    }
    /// `lsp.rename` — open a one-line prompt (seeded with the identifier under
    /// the cursor); on accept, send `textDocument/rename` for that spot.
    pub fn lsp_rename(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let (row, col) = b.editor.row_col();
        let word = self.word_under_cursor();
        self.pending_rename = Some((path, row as u32, col as u32));
        let kind = crate::prompt::PromptKind::LspRename;
        self.prompt = Some(match word {
            Some(w) => crate::prompt::Prompt::seeded(kind, "Rename symbol to", w),
            None => crate::prompt::Prompt::new(kind, "Rename symbol to"),
        });
    }
    /// The `[A-Za-z0-9_]` run straddling the active editor's cursor, if any.
    fn word_under_cursor(&self) -> Option<String> {
        let b = self.active_editor()?;
        let (row, col) = b.editor.row_col();
        let chars: Vec<char> = b.editor.line_str(row).chars().collect();
        let is_id = |c: char| c.is_alphanumeric() || c == '_';
        let col = col.min(chars.len());
        let mut start = col;
        while start > 0 && is_id(chars[start - 1]) {
            start -= 1;
        }
        let mut end = col;
        while end < chars.len() && is_id(chars[end]) {
            end += 1;
        }
        (start < end).then(|| chars[start..end].iter().collect())
    }
    /// `lsp.completion` (`Ctrl+Space`) — manually ask the server for completions
    /// at the cursor; the reply (`tick` → `apply_lsp_event`) opens the popup
    /// ([`Self::completion_on_edit`] auto-triggers it as you type otherwise).
    pub fn lsp_completion(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        self.lsp.did_change(&path, &text);
        if !self.lsp.completion(&path, row as u32, col as u32) {
            self.toast("no language server for this file (completion)");
        }
    }
    fn lsp_request_at_cursor(
        &mut self,
        send: impl FnOnce(&mut crate::lsp::LspManager, &Path, u32, u32) -> bool,
        what: &str,
    ) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        // Sync the latest text first so positions line up, then send the request.
        self.lsp.did_change(&path, &text);
        if !send(&mut self.lsp, &path, row as u32, col as u32) {
            self.toast(format!("no language server for this file ({what})"));
        }
    }
    /// Apply one LSP event (called from `tick`).
    fn apply_lsp_event(&mut self, ev: crate::lsp::LspEvent) {
        use crate::lsp::LspEvent;
        match ev {
            LspEvent::Diagnostics { path, diags } => {
                for pane in &mut self.panes {
                    if let Pane::Editor(b) = pane
                        && b.is_at(&path)
                    {
                        b.diagnostics = diags.clone();
                    }
                }
                self.refresh_diagnostics_panes();
            }
            LspEvent::GotoDefinition {
                path,
                line,
                character,
            } => {
                self.open_path(&path);
                if let Some(b) = self.active_editor_mut() {
                    b.editor.place_cursor(line as usize, character as usize);
                }
            }
            LspEvent::Hover { text } => match crate::hover::HoverPopup::from_text(&text) {
                Some(h) => self.hover = Some(h),
                None => self.toast("hover: (nothing)"),
            },
            LspEvent::References(locs) => {
                use crate::picker::PickerItem;
                if locs.is_empty() {
                    self.toast("no references");
                    return;
                }
                let n = locs.len();
                let items: Vec<PickerItem> = locs
                    .into_iter()
                    .map(|(p, l, c)| {
                        let rel = rel_path(&self.workspace, &p);
                        PickerItem::new(
                            format!("{}\t{}\t{}", p.display(), l, c),
                            format!("{rel}:{}:{}", l + 1, c + 1),
                            String::new(),
                        )
                    })
                    .collect();
                self.open_picker(Picker::new(
                    PickerKind::Locations,
                    format!("References ({n})"),
                    items,
                ));
            }
            LspEvent::Rename(edits) => self.apply_rename_edits(edits),
            LspEvent::Completion(items) => {
                use crate::completion::{CompletionItem, CompletionPopup};
                if items.is_empty() {
                    return;
                }
                // Build from the *current* cursor — the request may have been
                // fired a few keystrokes ago; we filter against the live prefix.
                let Some(prefix) = self.cursor_id_prefix() else {
                    return;
                };
                let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
                    return;
                };
                let cis: Vec<CompletionItem> = items
                    .into_iter()
                    .take(500)
                    .map(|(label, insert, detail)| CompletionItem {
                        label,
                        insert,
                        detail: detail.unwrap_or_default(),
                    })
                    .collect();
                let popup = CompletionPopup::new(path, cis, &prefix);
                if !popup.is_empty() {
                    self.completion = Some(popup);
                }
            }
            LspEvent::Message(m) => self.toast(m),
        }
    }

    /// Apply a flattened `WorkspaceEdit` (from `textDocument/rename`): edit each
    /// affected file — through `Editor::apply` if it's open as a buffer (left
    /// dirty for review), else by splicing the file on disk directly.
    fn apply_rename_edits(&mut self, edits: Vec<(PathBuf, Vec<(crate::lsp::Range, String)>)>) {
        if edits.is_empty() {
            self.toast("rename: no changes");
            return;
        }
        let (mut buffers, mut disk, mut total) = (0usize, 0usize, 0usize);
        for (path, file_edits) in edits {
            let idx = self
                .panes
                .iter()
                .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)));
            if let Some(idx) = idx {
                let ops = match self.panes.get(idx) {
                    Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &file_edits),
                    _ => Vec::new(),
                };
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let clip = &mut self.clipboard;
                let applied = match self.panes.get_mut(idx) {
                    Some(Pane::Editor(b)) => b.apply_edit_ops(ops, clip, 0),
                    _ => false,
                };
                if applied {
                    buffers += 1;
                    total += n;
                    if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                        let t = b.editor.text().to_string();
                        self.lsp.did_change(&path, &t);
                    }
                }
            } else if let Ok(text) = std::fs::read_to_string(&path) {
                let ops = build_replace_ops(&text, &file_edits);
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let mut s = text;
                for op in &ops {
                    if let crate::edit_op::EditOp::ReplaceRange { start, end, text } = op {
                        s.replace_range(*start..*end, text);
                    }
                }
                if std::fs::write(&path, s).is_ok() {
                    disk += 1;
                    total += n;
                }
            }
        }
        if disk > 0 {
            self.git.refresh();
        }
        self.toast(format!(
            "renamed {total} occurrence(s): {buffers} open buffer(s), {disk} on-disk file(s) — review & save"
        ));
    }

    pub fn drain_lsp_events(&mut self) {
        for ev in self.lsp.poll() {
            self.apply_lsp_event(ev);
        }
    }

    // ─── diagnostics ("Problems") list pane ─────────────────────────
    /// Collect every diagnostic currently held on an open editor buffer into a
    /// fresh [`DiagnosticsPane`].
    fn build_diagnostics_pane(&self) -> crate::lsp::diagnostics_pane::DiagnosticsPane {
        let sources = self.panes.iter().filter_map(|p| match p {
            Pane::Editor(b) => {
                let path = b.path.clone()?;
                if b.diagnostics.is_empty() {
                    return None;
                }
                let rel = rel_path(&self.workspace, &path);
                Some((path, rel, b.diagnostics.as_slice()))
            }
            _ => None,
        });
        crate::lsp::diagnostics_pane::DiagnosticsPane::build(sources)
    }

    /// `lsp.diagnostics` — open the project-wide diagnostics list (or refocus +
    /// refresh the one that's already open) in a split below the focused leaf.
    pub fn open_diagnostics_pane(&mut self) {
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Diagnostics(_)))
        {
            let fresh = self.build_diagnostics_pane();
            if let Some(Pane::Diagnostics(d)) = self.panes.get_mut(id) {
                d.items = fresh.items;
                d.clamp();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Diagnostics(self.build_diagnostics_pane());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Rebuild the item list of any open diagnostics pane (called when
    /// diagnostics change, or on the pane's `r` key).
    pub fn refresh_diagnostics_panes(&mut self) {
        if !self.panes.iter().any(|p| matches!(p, Pane::Diagnostics(_))) {
            return;
        }
        let fresh = self.build_diagnostics_pane();
        for pane in &mut self.panes {
            if let Pane::Diagnostics(d) = pane {
                d.items = fresh.items.clone();
                d.clamp();
            }
        }
    }

    pub fn move_diagnostics_selection(&mut self, delta: isize) {
        if let Some(Pane::Diagnostics(d)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            d.move_selection(delta);
        }
    }

    /// Open the highlighted diagnostic's file and place the cursor there.
    pub fn jump_to_selected_diagnostic(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Diagnostics(d)) => d
                .selected_item()
                .map(|it| (it.path.clone(), it.line, it.col)),
            _ => None,
        };
        let Some((path, line, col)) = target else {
            return;
        };
        self.open_path(&path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, col as usize);
        }
    }

    /// Drop `app.panes[removed]` and re-index every higher reference (the layout's
    /// leaves, `active`). Caller must have already detached `removed` from the
    /// layout if it was in a leaf.
    fn remove_pane_storage(&mut self, removed: PaneId) {
        if removed >= self.panes.len() {
            return;
        }
        self.panes.remove(removed);
        self.layout.shift_after(removed);
        self.active = self
            .active
            .map(|a| if a > removed { a - 1 } else { a })
            .filter(|_| !self.panes.is_empty());
    }

    /// Split the focused leaf, opening a fresh buffer (a re-open of the same file,
    /// or a scratch buffer) in the new half and focusing it.
    pub fn split_active(&mut self, dir: crate::layout::SplitDir) {
        let Some(cur) = self.active else {
            self.toast("nothing to split");
            return;
        };
        // The new half re-opens the current file fresh (own cursor), else a scratch.
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::MdPreview(p)) => Some(p.path.clone()),
            Some(Pane::Diff(_))
            | Some(Pane::GitGraph(_))
            | Some(Pane::GitStatus(_))
            | Some(Pane::Request(_))
            | Some(Pane::Pty(_))
            | Some(Pane::Ai(_))
            | Some(Pane::Tests(_))
            | Some(Pane::Diagnostics(_))
            | None => None,
        };
        let new_buf = match path {
            Some(p) => {
                Buffer::open(&p, &self.config).unwrap_or_else(|_| Buffer::scratch(&self.config))
            }
            None => Buffer::scratch(&self.config),
        };
        let new_id = self.split_leaf_with(cur, dir, Pane::Editor(new_buf));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Replace `Leaf(leaf)` with `Split{leaf, new-pane}`; returns the new pane id.
    fn split_leaf_with(
        &mut self,
        leaf: PaneId,
        dir: crate::layout::SplitDir,
        pane: Pane,
    ) -> PaneId {
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.layout.replace_leaf(
            leaf,
            Layout::Split {
                dir,
                ratio: 50,
                first: Box::new(Layout::Leaf(leaf)),
                second: Box::new(Layout::Leaf(new_id)),
            },
        );
        new_id
    }

    /// Open a rendered-markdown preview of the active `.md` buffer, in a split to
    /// the right. If one's already open for this file, just focus it.
    pub fn open_md_preview(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) if b.language_ext.as_deref() == Some("md") => b.path.clone(),
            Some(Pane::Editor(_))
            | Some(Pane::Diff(_))
            | Some(Pane::GitGraph(_))
            | Some(Pane::GitStatus(_))
            | Some(Pane::Request(_))
            | Some(Pane::Pty(_))
            | Some(Pane::Ai(_))
            | Some(Pane::Tests(_))
            | Some(Pane::Diagnostics(_)) => {
                self.toast("not a markdown file");
                return;
            }
            Some(Pane::MdPreview(p)) => Some(p.path.clone()), // already a preview — re-open beside it
            None => None,
        };
        let Some(path) = path else {
            self.toast("markdown preview needs a saved .md file");
            return;
        };
        // Already showing a preview of this file somewhere? Focus it.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::MdPreview(mp) if mp.path == path))
        {
            self.reveal_pane(id);
            return;
        }
        let source = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.editor.text().to_string(),
            _ => std::fs::read_to_string(&path).unwrap_or_default(),
        };
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::MdPreview(crate::pane::MdPreview {
                path,
                source,
                scroll: 0,
            }),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// After a `.md` buffer is saved, refresh any open previews of that file.
    fn refresh_md_previews(&mut self, path: &Path) {
        let fresh = std::fs::read_to_string(path).ok();
        for pane in &mut self.panes {
            if let Pane::MdPreview(p) = pane
                && p.path == path
            {
                if let Some(s) = &fresh {
                    p.source = s.clone();
                }
                p.scroll = 0;
            }
        }
    }

    // ─── pty / AI-CLI panes ─────────────────────────────────────────
    /// Open an embedded terminal (`profile` = shell / `claude` / `codex`) as a
    /// stacked split below the focused leaf (a terminal "drawer"), and focus it.
    pub fn open_pty(&mut self, profile: crate::pty_pane::BinaryProfile) {
        // The initial size is a guess — `ui/pty_view` resizes the session to its
        // rendered area on the first frame.
        match crate::pty_pane::PtySession::spawn(profile, 24, 80) {
            Ok(s) => {
                let pane = Pane::Pty(s);
                match self.active {
                    Some(cur) => {
                        let new_id =
                            self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                        self.active = Some(new_id);
                    }
                    None => {
                        self.panes.push(pane);
                        let id = self.panes.len() - 1;
                        self.layout = Layout::Leaf(id);
                        self.active = Some(id);
                    }
                }
                self.focus = Focus::Pane;
            }
            Err(e) => self.toast(format!("can't open terminal: {e}")),
        }
    }

    pub fn open_shell(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(
            self.workspace.clone(),
        )));
    }
    pub fn open_claude_code(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::claude_code(
            self.workspace.clone(),
        ));
    }
    pub fn open_codex(&mut self) {
        self.open_pty(crate::pty_pane::BinaryProfile::codex(
            self.workspace.clone(),
        ));
    }

    /// True if any pane is a pty (the event loop polls faster while one's open so
    /// streaming output stays smooth).
    pub fn has_pty_pane(&self) -> bool {
        self.panes.iter().any(|p| matches!(p, Pane::Pty(_)))
    }

    // ─── AI: `claude -p` one-shots ──────────────────────────────────
    /// Allocate a job id + fresh session id and spawn `claude -p --session-id …`
    /// on a worker thread. Returns `(job_id, session_id, cancel_flag)` — set the
    /// flag to ask the worker to kill its child and bail.
    fn spawn_ai_job(
        &mut self,
        prompt: String,
    ) -> (u64, String, std::sync::Arc<std::sync::atomic::AtomicBool>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let session_id = crate::ai::gen_session_id();
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let sid = session_id.clone();
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        std::thread::spawn(move || {
            let _ = tx.send((
                job_id,
                crate::ai::one_shot_cancellable(&prompt, &sid, &worker_cancel),
            ));
        });
        (job_id, session_id, cancel)
    }

    /// Open a `Pane::Ai` showing `title` and the answer to `prompt`, and kick off
    /// `claude -p <prompt>` on a background thread (`tick` delivers the answer).
    pub fn ask_ai(&mut self, title: impl Into<String>, prompt: String) {
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt.clone());
        let pane = Pane::Ai(crate::ai::AiPane::new(
            title, prompt, session_id, job_id, cancel,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-send the prompt an existing `Pane::Ai` holds (with a fresh session id).
    /// No-op for a live transcript mirror (it has no `-p` prompt). Signals any
    /// still-running worker for this pane to bail first.
    fn reask_ai(&mut self, pane_id: PaneId) {
        let prompt = match self.panes.get(pane_id) {
            Some(Pane::Ai(a)) if !a.is_live() => {
                a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
                a.prompt.clone()
            }
            _ => return,
        };
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt);
        if let Some(Pane::Ai(a)) = self.panes.get_mut(pane_id) {
            a.job_id = job_id;
            a.session_id = session_id;
            a.state = crate::ai::AiState::Asking;
            a.scroll = 0;
            a.cancel = cancel;
        }
    }

    /// `x` in an `Asking` `Pane::Ai` — ask the worker to kill `claude -p` and bail
    /// (the reply lands as `Failed("cancelled")`).
    pub fn cancel_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Ai(a)) = self.panes.get(cur)
            && matches!(a.state, crate::ai::AiState::Asking)
        {
            a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            self.toast("cancelling…");
        }
    }

    /// `c` in a `Pane::Ai`: open `claude --resume <session>` interactively (a split
    /// below) so you can carry the conversation further — and flip this pane into
    /// a live transcript mirror of that session.
    pub fn continue_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Ai(a)) if matches!(a.state, crate::ai::AiState::Asking) => {
                self.toast("wait for the answer first");
                return;
            }
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => return,
        };
        // Flip the source pane to a live mirror (unless it already is one).
        if let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid)
            && let Some(Pane::Ai(a)) = self.panes.get_mut(cur)
            && !a.is_live()
        {
            let turns = crate::ai::transcript::read(&path);
            let last_len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            a.state = crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            };
            a.scroll = usize::MAX;
        }
        self.open_pty(crate::pty_pane::BinaryProfile::claude_code_resume(
            self.workspace.clone(),
            sid,
        ));
    }

    /// `ai.session_view` — open a live transcript mirror for the active `Pane::Pty`'s
    /// session (a `claude` pane started by mnml, which knows its `--session-id`).
    pub fn open_session_view(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Pty(s)) => match &s.profile.session_id {
                Some(sid) => sid.clone(),
                None => {
                    self.toast("this terminal has no Claude session to mirror");
                    return;
                }
            },
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => {
                self.toast("open a Claude Code pane first (<leader>a c)");
                return;
            }
        };
        let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid) else {
            self.toast("can't locate the session transcript ($HOME unset?)");
            return;
        };
        // If we're already showing this session's mirror, just focus it.
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Ai(a) if a.is_live() && a.session_id == sid))
        {
            self.reveal_pane(i);
            return;
        }
        let pane = Pane::Ai(crate::ai::AiPane::live(sid, path));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-read any live transcript mirrors whose `.jsonl` has grown — incrementally:
    /// only the bytes past `last_len` are read and parsed (up to the last complete
    /// line) and their turns appended. A shrunk file (rotation / rewrite) triggers a
    /// full re-read.
    fn refresh_live_ai_panes(&mut self) {
        use std::io::{Read, Seek, SeekFrom};
        for pane in &mut self.panes {
            let Pane::Ai(a) = pane else { continue };
            let crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            } = &mut a.state
            else {
                continue;
            };
            let len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
            if len < *last_len {
                // file shrank / rotated — re-read from scratch.
                *turns = crate::ai::transcript::read(path);
                *last_len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
                continue;
            }
            if len == *last_len {
                continue;
            }
            // Append-only growth: read just the new tail, parse complete lines.
            let mut chunk = String::new();
            let ok = std::fs::File::open(&*path)
                .and_then(|mut f| {
                    f.seek(SeekFrom::Start(*last_len))?;
                    f.read_to_string(&mut chunk)
                })
                .is_ok();
            if !ok {
                continue;
            }
            let Some(cut) = chunk.rfind('\n').map(|i| i + 1) else {
                continue; // a partial line is still being written — wait for the rest
            };
            turns.extend(crate::ai::transcript::parse(&chunk[..cut]));
            *last_len += cut as u64;
        }
    }

    /// `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests` — feed the active
    /// editor's selection (or the whole buffer) + a task prompt to `claude -p`.
    /// For `fix`/`refactor` the source range is remembered as the answer pane's
    /// [`ApplyTarget`](crate::ai::ApplyTarget) so `a` can apply the suggested code.
    pub fn ai_action(&mut self, what: &str) {
        let (code, lang, target) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) => {
                let sel = b.editor.selected_text();
                let (code, range) = if sel.trim().is_empty() {
                    let t = b.editor.text();
                    (t.to_string(), (0usize, t.len()))
                } else {
                    let r = b.editor.selection().unwrap_or((0, 0));
                    (sel, r)
                };
                let target = if matches!(what, "fix" | "refactor") {
                    b.path.clone().map(|path| crate::ai::ApplyTarget {
                        path,
                        start: range.0.min(range.1),
                        end: range.0.max(range.1),
                    })
                } else {
                    None
                };
                (code, b.language_ext.clone().unwrap_or_default(), target)
            }
            // Re-fire from an existing AI pane.
            Some(Pane::Ai(_)) => {
                if let Some(cur) = self.active {
                    self.reask_ai(cur);
                }
                return;
            }
            _ => {
                self.toast("AI actions need an editor (select code, or use the whole file)");
                return;
            }
        };
        if code.trim().is_empty() {
            self.toast("nothing to send");
            return;
        }
        let title = format!("AI: {}", what.replace('_', " "));
        self.ask_ai(title, crate::ai::action_prompt(what, &code, &lang));
        if target.is_some()
            && let Some(Pane::Ai(a)) = self.active.and_then(|i| self.panes.get_mut(i))
        {
            a.target = target;
        }
    }

    /// `a` in a Done `Pane::Ai` — apply the first fenced code block from the
    /// answer over the range the AI was asked about (offsets clamped to the
    /// buffer's current length). The edit is left dirty: review it, undo to
    /// revert. No-op without a recorded target / a code block in the answer.
    pub fn apply_ai_suggestion(&mut self) {
        let Some(cur) = self.active else { return };
        let parsed: Result<(crate::ai::ApplyTarget, String), &'static str> =
            match self.panes.get(cur) {
                Some(Pane::Ai(a)) => match (&a.target, &a.state) {
                    (None, _) => Err("nothing to apply here (use AI `fix`/`refactor` on a buffer)"),
                    (Some(_), crate::ai::AiState::Asking) => Err("wait for the answer first"),
                    (Some(t), crate::ai::AiState::Done(text)) => {
                        match crate::ai::first_code_block(text) {
                            Some(code) => Ok((t.clone(), code)),
                            None => Err("no code block in the answer to apply"),
                        }
                    }
                    (Some(_), _) => Err("nothing to apply (the run didn't finish ok)"),
                },
                _ => return,
            };
        let (target, code) = match parsed {
            Ok(v) => v,
            Err(msg) => {
                self.toast(msg);
                return;
            }
        };
        if !self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        {
            self.open_path(&target.path);
        }
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        else {
            self.toast("couldn't open the source file");
            return;
        };
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let len = b.editor.text().len();
            let start = target.start.min(len);
            let end = target.end.min(len).max(start);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end,
                    text: code,
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx)
            && let Some(p) = b.path.clone()
        {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&p, &t);
        }
        self.reveal_pane(idx);
        self.toast("applied — review it; undo to revert");
    }

    /// `rqst.ai_debug` (`.` in a request pane) — hand the request + its response
    /// (or transport error) to `claude -p` and ask why it's failing / how to fix.
    pub fn ai_debug_request(&mut self) {
        use crate::request_pane::RunState;
        let prompt = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => {
                let req = &rp.request;
                let mut req_text = format!("{} {}\n", req.method, req.url);
                for (k, v) in &req.headers {
                    req_text.push_str(&format!("{k}: {v}\n"));
                }
                if let Some(b) = &req.body {
                    req_text.push_str(&format!("\n{b}\n"));
                }
                let resp_text = match &rp.state {
                    RunState::Sending => "(still in flight — wait for it)".to_string(),
                    RunState::Failed(e) => format!("transport error: {e}"),
                    RunState::Done(r) => {
                        let mut s = format!("{} {}\n", r.status, r.status_text);
                        for (k, v) in &r.headers {
                            s.push_str(&format!("{k}: {v}\n"));
                        }
                        let body: String = r.body.chars().take(4000).collect();
                        s.push_str(&format!("\n{body}\n"));
                        s
                    }
                };
                if matches!(rp.state, RunState::Sending) {
                    self.toast("wait for the response first");
                    return;
                }
                format!(
                    "This HTTP request isn't behaving. What's likely wrong and how do I fix it? \
                     Be concise.\n\n## Request\n```http\n{req_text}```\n\n## Response\n```\n{resp_text}```"
                )
            }
            _ => {
                self.toast("open a request pane first (rqst.send)");
                return;
            }
        };
        self.ask_ai("AI: debug request", prompt);
    }

    /// Re-fire the active `Pane::Ai`'s prompt (its `r` key).
    pub fn resend_active_ai(&mut self) {
        if let Some(cur) = self
            .active
            .filter(|&i| matches!(self.panes.get(i), Some(Pane::Ai(_))))
        {
            self.reask_ai(cur);
        }
    }

    /// `ai.ask` — accepted from the text-input prompt: a free-text question to `claude -p`.
    pub fn open_ai_ask_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::AiAsk,
            "Ask Claude",
        ));
    }

    /// Deliver any completed `claude -p` runs to their `Pane::Ai`.
    fn drain_ai_jobs(&mut self) {
        use crate::ai::AiState;
        let Some((_, rx)) = &self.ai_chan else {
            return;
        };
        let done: Vec<AiJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, result) in done {
            // An "AI: write me a commit message" job? Route it to the commit prompt.
            if self.pending_commit_msg_job == Some(job_id) {
                self.pending_commit_msg_job = None;
                for pane in &mut self.panes {
                    if let Pane::GitStatus(g) = pane
                        && g.ai_msg_job == Some(job_id)
                    {
                        g.ai_msg_job = None;
                    }
                }
                match result {
                    Ok(text) => {
                        let summary = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("")
                            .trim_matches('`')
                            .trim()
                            .to_string();
                        if summary.is_empty() {
                            toasts.push("AI returned an empty commit message".to_string());
                        } else {
                            self.prompt = Some(crate::prompt::Prompt::seeded(
                                crate::prompt::PromptKind::GitCommit,
                                "Commit message (AI draft — edit & Enter)",
                                summary,
                            ));
                        }
                    }
                    Err(e) => toasts.push(format!("AI commit message: {e}")),
                }
                continue;
            }
            let Some(Pane::Ai(a)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Ai(a) if a.job_id == job_id && matches!(a.state, AiState::Asking)),
            ) else {
                continue;
            };
            match result {
                Ok(text) => {
                    toasts.push(format!("{} — done", a.title));
                    a.state = AiState::Done(text);
                }
                Err(e) => {
                    toasts.push(format!("AI: {e}"));
                    a.state = AiState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    // ─── Playwright: test runner ────────────────────────────────────
    /// Open a `Pane::Tests` and kick off `npx playwright test --reporter=json
    /// <extra_args>` on a worker thread (`tick` delivers the results).
    fn run_playwright(&mut self, extra_args: Vec<String>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .tests_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let ws = self.workspace.clone();
        let args = extra_args.clone();
        std::thread::spawn(move || {
            let _ = tx.send((job_id, crate::playwright::run(&ws, &args)));
        });
        // Re-use an existing tests pane if there is one; else open a split.
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Tests(_))) {
            if let Some(Pane::Tests(t)) = self.panes.get_mut(id) {
                t.state = crate::playwright::TestsState::Running;
                t.last_args = extra_args;
                t.job_id = job_id;
                t.scroll = 0;
                t.selected = 0;
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Tests(crate::playwright::TestsPane::new(
            self.workspace.clone(),
            extra_args,
            job_id,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `test.run_all` — the whole Playwright suite.
    pub fn run_tests_all(&mut self) {
        self.run_playwright(Vec::new());
    }

    /// `test.run_file` — the active editor's spec file.
    pub fn run_tests_file(&mut self) {
        match self.active_editor().and_then(|b| b.path.as_deref()) {
            Some(p) => {
                let rel = rel_path(&self.workspace, p);
                self.run_playwright(vec![rel]);
            }
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.run_at_cursor` — the test at the cursor (Playwright's `file:line` selector).
    pub fn run_tests_at_cursor(&mut self) {
        match self.active_editor() {
            Some(b) => match &b.path {
                Some(p) => {
                    let rel = rel_path(&self.workspace, p);
                    let line = b.editor.row_col().0 + 1;
                    self.run_playwright(vec![format!("{rel}:{line}")]);
                }
                None => self.toast("open a saved .spec file first"),
            },
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.rerun_failed` — re-run just the failures of the last run (Playwright's `--last-failed`).
    pub fn rerun_failed_tests(&mut self) {
        self.run_playwright(vec!["--last-failed".to_string()]);
    }

    /// `r` in a tests pane — re-run with the same args as last time.
    pub fn rerun_active_tests(&mut self) {
        let args = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => t.last_args.clone(),
            _ => return,
        };
        self.run_playwright(args);
    }

    /// `test.heal` (`h` in a tests pane) — hand the highlighted *failing* test (its
    /// title, file, error, and the spec source) to `claude -p` and ask for a fix.
    /// Reuses the AI machinery; `c` in the resulting `Pane::Ai` promotes it to an
    /// interactive Claude Code session (which can actually apply the fix / call
    /// your healer agent).
    pub fn heal_selected_test(&mut self) {
        let info = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if tc.status == crate::playwright::TestStatus::Failed => Some((
                    tc.title.clone(),
                    tc.suite_path.clone(),
                    tc.file.clone(),
                    tc.line,
                    tc.error.clone().unwrap_or_default(),
                )),
                Some(_) => {
                    self.toast("that test isn't failing — nothing to heal");
                    None
                }
                None => None,
            },
            _ => {
                self.toast("select a failing test in the results pane first");
                None
            }
        };
        let Some((title, suite, file, line, error)) = info else {
            return;
        };
        let src = std::fs::read_to_string(self.workspace.join(&file)).unwrap_or_default();
        let where_ = if suite.is_empty() {
            format!("{file}:{line}")
        } else {
            format!("{suite} › {title}  ({file}:{line})")
        };
        let prompt = format!(
            "This Playwright test is failing. Work out why and propose a fix — change the \
             test or the code under test as appropriate. Be concise; reply with the patch in a \
             fenced block plus a short note.\n\n## Failing test\n{where_}\n\n## Error\n```\n{error}\n```\n\n## {file}\n```ts\n{src}\n```"
        );
        self.ask_ai(format!("AI: heal {title}"), prompt);
    }

    /// Jump the editor to the source of the highlighted test in a `Pane::Tests`.
    pub fn jump_to_selected_test(&mut self) {
        let Some(cur) = self.active else { return };
        let (rel, line) = match self.panes.get(cur) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if !tc.file.is_empty() => {
                    (tc.file.clone(), tc.line.saturating_sub(1) as usize)
                }
                _ => return,
            },
            _ => return,
        };
        let path = self.workspace.join(&rel);
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    /// Move the highlighted-test cursor in a `Pane::Tests`.
    pub fn tests_move_selection(&mut self, delta: isize) {
        if let Some(Pane::Tests(t)) = self.active.and_then(|i| self.panes.get_mut(i))
            && let crate::playwright::TestsState::Done(r) = &t.state
        {
            let n = r.tests.len();
            if n == 0 {
                return;
            }
            let new = (t.selected as isize + delta).clamp(0, n as isize - 1) as usize;
            t.selected = new;
        }
    }

    fn drain_tests_jobs(&mut self) {
        use crate::playwright::TestsState;
        let Some((_, rx)) = &self.tests_chan else {
            return;
        };
        let done: Vec<TestsJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, result) in done {
            let Some(Pane::Tests(t)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Tests(t) if t.job_id == job_id && matches!(t.state, TestsState::Running)),
            ) else {
                continue;
            };
            match result {
                Ok(run) => {
                    let (p, f, s) = (run.passed(), run.failed(), run.skipped());
                    toasts.push(if f > 0 {
                        format!(
                            "tests: {f} failed, {p} passed{}",
                            if s > 0 {
                                format!(", {s} skipped")
                            } else {
                                String::new()
                            }
                        )
                    } else {
                        format!(
                            "tests: all {p} passed{}",
                            if s > 0 {
                                format!(" ({s} skipped)")
                            } else {
                                String::new()
                            }
                        )
                    });
                    t.selected = run
                        .tests
                        .iter()
                        .position(|tc| tc.status == crate::playwright::TestStatus::Failed)
                        .unwrap_or(0);
                    t.state = TestsState::Done(Box::new(run));
                }
                Err(e) => {
                    toasts.push(format!(
                        "playwright: {}",
                        e.lines().next().unwrap_or("error")
                    ));
                    t.state = TestsState::Failed(e);
                }
            }
        }
        for tt in toasts {
            self.toast(tt);
        }
    }

    // ─── HTTP: request pane ─────────────────────────────────────────
    /// `rqst.send` — parse the active `.http`/`.rest`/`.curl` editor (the block
    /// under the cursor for multi-block `.http` files), expand `{{vars}}` against
    /// `.mnml/env/$MNML_ENV`, open a `Pane::Request` split, and fire the request
    /// on a background thread. `tick` delivers the response.
    pub fn send_request_from_active(&mut self) {
        use crate::http::{self, template::EnvSet};
        let Some(cur) = self.active else {
            self.toast("no active editor");
            return;
        };
        // From an existing request pane, `rqst.send` just re-fires it.
        if matches!(self.panes.get(cur), Some(Pane::Request(_))) {
            self.refire_request(cur);
            return;
        }
        let (path, ext, text, cursor_row) = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => (
                b.path.clone(),
                b.language_ext.clone().unwrap_or_default(),
                b.editor.text().to_string(),
                b.editor.row_col().0,
            ),
            _ => {
                self.toast("not an editor");
                return;
            }
        };
        if !matches!(ext.as_str(), "http" | "rest" | "curl") {
            self.toast("rqst.send needs a .http / .rest / .curl file");
            return;
        }

        // Pick the request + the directive text. For `.http`/`.rest`, use the
        // block under the cursor; otherwise treat the whole buffer as one request.
        let (mut request, script_src): (http::Request, String) =
            if matches!(ext.as_str(), "http" | "rest")
                && let Ok(blocks) = http::file::parse_all(&text)
            {
                let lines: Vec<&str> = text.split('\n').collect();
                let b = blocks
                    .iter()
                    .find(|b| cursor_row >= b.start_line && cursor_row <= b.end_line)
                    .unwrap_or(&blocks[0]);
                let src =
                    lines[b.start_line..=b.end_line.min(lines.len().saturating_sub(1))].join("\n");
                (b.request.clone(), src)
            } else {
                match http::parse(&text) {
                    Ok(r) => (r, text.clone()),
                    Err(e) => {
                        self.toast(format!("can't parse request: {e}"));
                        return;
                    }
                }
            };
        let script = http::script::parse(&script_src);
        let mut env = EnvSet::select(&self.workspace, None);
        http::script::apply_pre(&script, &mut request, &mut env);
        request.url = http::template::expand(&request.url, &env);
        for (_, v) in &mut request.headers {
            *v = http::template::expand(v, &env);
        }
        if let Some(b) = &mut request.body {
            *b = http::template::expand(b, &env);
        }

        let job_id = self.spawn_http_job(request.clone(), script.clone());
        let pane = Pane::Request(crate::request_pane::RequestPane::new(
            path, request, script, job_id,
        ));
        let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Re-send the request a `Pane::Request` already holds (its `r` key / re-`rqst.send`).
    fn refire_request(&mut self, pane_id: PaneId) {
        let (request, script) = match self.panes.get(pane_id) {
            Some(Pane::Request(rp)) => (rp.request.clone(), rp.script.clone()),
            _ => return,
        };
        let job_id = self.spawn_http_job(request, script);
        if let Some(Pane::Request(rp)) = self.panes.get_mut(pane_id) {
            rp.job_id = job_id;
            rp.state = crate::request_pane::RunState::Sending;
            rp.scroll = 0;
        }
    }

    /// Allocate a job id, ensure the result channel exists, spawn the worker.
    fn spawn_http_job(
        &mut self,
        request: crate::http::Request,
        script: crate::http::script::Script,
    ) -> u64 {
        use crate::request_pane::ResponseView;
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .http_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        std::thread::spawn(move || {
            let result: Result<ResponseView, String> = (|| {
                let resp = crate::http::send(&request)?;
                let assertions = crate::http::script::run_assertions(
                    &script,
                    resp.status,
                    &resp.headers,
                    &resp.body,
                );
                let mut env = crate::http::template::EnvSet::empty();
                let captures = crate::http::script::apply_captures(
                    &script,
                    &resp.headers,
                    &resp.body,
                    &mut env,
                );
                Ok(ResponseView {
                    status: resp.status,
                    status_text: resp.status_text,
                    headers: resp.headers,
                    body: resp.body,
                    elapsed: resp.elapsed,
                    assertions,
                    captures,
                })
            })();
            let _ = tx.send((job_id, result));
        });
        job_id
    }

    /// `rqst.copy_curl` — copy the active request (in an editor: parse the buffer;
    /// in a request pane: the request it holds) to the clipboard as a curl command.
    pub fn copy_active_curl(&mut self) {
        let curl = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => Some(rp.as_curl()),
            Some(Pane::Editor(b))
                if matches!(b.language_ext.as_deref(), Some("http" | "rest" | "curl")) =>
            {
                crate::http::parse(b.editor.text()).ok().map(|r| {
                    crate::request_pane::RequestPane::new(None, r, Default::default(), 0).as_curl()
                })
            }
            _ => None,
        };
        match curl {
            Some(c) => {
                self.clipboard.set(c, false);
                self.toast("copied request as curl");
            }
            None => self.toast("no request here to copy"),
        }
    }

    /// Deliver any completed background HTTP sends to their request panes.
    fn drain_http_jobs(&mut self) {
        use crate::request_pane::RunState;
        let Some((_, rx)) = &self.http_chan else {
            return;
        };
        let done: Vec<HttpJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, result) in done {
            let Some(Pane::Request(rp)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Request(rp) if rp.job_id == job_id && matches!(rp.state, RunState::Sending)),
            ) else {
                continue;
            };
            match result {
                Ok(rv) => {
                    let failed = rv.assertions.iter().filter(|a| !a.passed).count();
                    let total = rv.assertions.len();
                    toasts.push(if total > 0 {
                        format!(
                            "← {} · {}/{} asserts passed",
                            rv.status,
                            total - failed,
                            total
                        )
                    } else {
                        format!("← {} {}", rv.status, rv.status_text)
                    });
                    rp.state = RunState::Done(Box::new(rv));
                }
                Err(e) => {
                    toasts.push(format!("request failed: {e}"));
                    rp.state = RunState::Failed(e);
                }
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    // ─── git: diff pane + blame ─────────────────────────────────────
    /// Workspace-relative path of an arbitrary path, for `git` arguments.
    fn rel_to_workspace(&self, p: &Path) -> String {
        rel_path(&self.workspace, p)
    }

    /// Toggle the editor's blame-gutter mode for the active buffer (computing
    /// `git blame` when turning it on).
    pub fn toggle_blame(&mut self) {
        let Some(cur) = self.active else { return };
        let already_on = matches!(self.panes.get(cur), Some(Pane::Editor(b)) if b.blame.is_some());
        if already_on {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
                b.blame = None;
            }
            self.toast("blame: off");
            return;
        }
        let rel = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => match &b.path {
                Some(p) => rel_path(&self.workspace, p),
                None => {
                    self.toast("blame needs a saved file");
                    return;
                }
            },
            _ => {
                self.toast("blame: not an editor");
                return;
            }
        };
        let lines = crate::git::blame::blame(&self.workspace, &rel);
        if lines.is_empty() {
            self.toast("git blame returned nothing (untracked file?)");
            return;
        }
        if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
            b.blame = Some(lines);
        }
        self.toast("blame: on");
    }

    /// If a buffer with blame mode on was just saved, recompute its blame.
    fn refresh_blame_for(&mut self, path: &Path) {
        let rel = rel_path(&self.workspace, path);
        let ws = self.workspace.clone();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.blame.is_some()
                && b.is_at(path)
            {
                b.blame = Some(crate::git::blame::blame(&ws, &rel));
            }
        }
    }
    fn fetch_diff(&self, scope: &crate::pane::DiffScope) -> Vec<crate::git::diff::Hunk> {
        use crate::pane::DiffScope;
        match scope {
            DiffScope::Unstaged(Some(p)) => {
                crate::git::diff::diff_file(&self.workspace, &self.rel_to_workspace(p))
            }
            DiffScope::Unstaged(None) => crate::git::diff::diff_worktree(&self.workspace),
            DiffScope::Staged => crate::git::diff::diff_staged(&self.workspace),
            DiffScope::Commit(h) => crate::git::diff::show_commit(&self.workspace, h),
        }
    }
    /// Open a `git diff` view of the active editor's file, in a split to the right.
    pub fn open_diff_file(&mut self) {
        let Some(cur) = self.active else {
            self.toast("no active buffer");
            return;
        };
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::Diff(d)) => match &d.scope {
                crate::pane::DiffScope::Unstaged(p) => p.clone(),
                crate::pane::DiffScope::Staged | crate::pane::DiffScope::Commit(_) => None,
            },
            _ => None,
        };
        let Some(path) = path else {
            self.toast("git diff needs a saved file");
            return;
        };
        let scope = crate::pane::DiffScope::Unstaged(Some(path));
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes in that file");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// Open a `git diff` view of the whole worktree, in the focused leaf.
    pub fn open_diff_worktree(&mut self) {
        let scope = crate::pane::DiffScope::Unstaged(None);
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no unstaged changes");
            return;
        }
        self.panes
            .push(Pane::Diff(crate::pane::DiffView::new(scope, hunks)));
        let id = self.panes.len() - 1;
        self.reveal_pane(id);
    }
    /// Re-run the active diff pane's `git diff` (after staging, or on demand).
    pub fn refresh_active_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let scope = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.scope.clone(),
            _ => return,
        };
        let hunks = self.fetch_diff(&scope);
        if let Some(Pane::Diff(d)) = self.panes.get_mut(cur) {
            d.cursor = d.cursor.min(hunks.len().saturating_sub(1));
            d.hunks = hunks;
        }
    }
    /// Stage (`reverse == false`) / unstage the cursor hunk of the active diff pane.
    pub fn apply_cursor_hunk(&mut self, reverse: bool) {
        let Some(cur) = self.active else { return };
        let hunk = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => d.hunks.get(d.cursor).cloned(),
            _ => return,
        };
        let Some(hunk) = hunk else { return };
        if matches!(
            self.panes.get(cur),
            Some(Pane::Diff(d)) if matches!(d.scope, crate::pane::DiffScope::Commit(_))
        ) {
            self.toast("that's a committed change — nothing to stage");
            return;
        }
        match crate::git::diff::apply_hunk(&self.workspace, &hunk, reverse) {
            Ok(()) => {
                self.toast(if reverse {
                    "unstaged hunk"
                } else {
                    "staged hunk"
                });
                self.after_git_change();
                self.refresh_active_diff();
            }
            Err(e) => self.toast(format!("git apply failed: {e}")),
        }
    }
    /// Jump the source editor to the cursor hunk's first new-file line (if that
    /// file is open). Used by Enter in the diff pane.
    pub fn jump_to_cursor_hunk(&mut self) {
        let Some(cur) = self.active else { return };
        let (path, line) = match self.panes.get(cur) {
            Some(Pane::Diff(d)) => match d.hunks.get(d.cursor) {
                Some(h) => (h.file.clone(), h.new_start.saturating_sub(1)),
                None => return,
            },
            _ => return,
        };
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    // ─── commit ─────────────────────────────────────────────────────
    /// Open the commit-message prompt. Commits whatever is staged when accepted;
    /// if nothing's staged, `git commit` says so.
    pub fn open_commit_prompt(&mut self) {
        let staged = self.git.snapshot().staged;
        let title = if staged > 0 {
            format!("Commit message ({staged} staged)")
        } else {
            "Commit message (nothing staged — stage hunks first)".to_string()
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GitCommit,
            title,
        ));
    }
    pub fn prompt_cancel(&mut self) {
        self.prompt = None;
        self.pending_rename = None;
    }
    pub fn prompt_accept(&mut self) {
        let Some(p) = self.prompt.take() else { return };
        match p.kind {
            crate::prompt::PromptKind::GitCommit => {
                let msg = p.input.trim();
                if msg.is_empty() {
                    self.toast("commit cancelled (empty message)");
                    return;
                }
                match crate::git::commit::commit(&self.workspace, msg) {
                    Ok(summary) => {
                        self.toast(summary);
                        self.after_git_change();
                        self.refresh_active_diff();
                    }
                    Err(e) => self.toast(format!("git commit: {e}")),
                }
            }
            crate::prompt::PromptKind::AiAsk => {
                let q = p.input.trim();
                if q.is_empty() {
                    return;
                }
                let short: String = q.chars().take(24).collect();
                let ellip = if q.chars().count() > 24 { "…" } else { "" };
                self.ask_ai(format!("AI: {short}{ellip}"), q.to_string());
            }
            crate::prompt::PromptKind::NewBranch => {
                let name = p.input.clone();
                self.create_branch(&name);
            }
            crate::prompt::PromptKind::LspRename => {
                let new_name = p.input.trim().to_string();
                let Some((path, line, ch)) = self.pending_rename.take() else {
                    return;
                };
                if new_name.is_empty() {
                    self.toast("rename cancelled (empty name)");
                    return;
                }
                // Sync the buffer's current text so the server's positions line up.
                let text = self.panes.iter().find_map(|p| match p {
                    Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                    _ => None,
                });
                if let Some(t) = text {
                    self.lsp.did_change(&path, &t);
                }
                if !self.lsp.rename(&path, line, ch, &new_name) {
                    self.toast("no language server for this file (rename)");
                }
            }
        }
    }

    // ─── git graph (graphical-Git-GUI-style commit DAG) ─────────────────────
    /// Open the commit-DAG browser as a split to the right of the focused leaf.
    pub fn open_git_graph(&mut self) {
        let pane = Pane::GitGraph(crate::git::graph::GitGraphPane::open(&self.workspace));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }
    /// Re-run `git log` for the active git-graph pane (after a commit / fetch).
    pub fn refresh_active_git_graph(&mut self) {
        if let Some(Pane::GitGraph(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.refresh();
        }
    }
    fn refresh_git_graph_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitGraph(g) = pane {
                g.refresh();
            }
        }
    }
    /// Open the selected commit's diff (`git show <hash>`) as a `Pane::Diff` in a
    /// split to the right of the graph pane.
    pub fn open_selected_commit_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        let scope = crate::pane::DiffScope::Commit(hash.clone());
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast(format!(
                "commit {} has no file changes (merge?)",
                hash.chars().take(9).collect::<String>()
            ));
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// Copy the selected commit's full hash to the clipboard.
    pub fn copy_selected_commit_hash(&mut self) {
        let Some(cur) = self.active else { return };
        let hash = match self.panes.get(cur) {
            Some(Pane::GitGraph(g)) => g.selected_commit().map(|c| c.hash.clone()),
            _ => None,
        };
        let Some(hash) = hash else { return };
        self.clipboard.set(hash.clone(), false);
        self.toast(format!(
            "copied {}",
            hash.chars().take(12).collect::<String>()
        ));
    }

    // ─── git status / staging view ──────────────────────────────────
    /// Open the staging view as a split to the right of the focused leaf.
    pub fn open_git_status(&mut self) {
        let pane = Pane::GitStatus(crate::git::stage::GitStatusPane::open(&self.workspace));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                self.layout = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }
    fn refresh_git_status_panes(&mut self) {
        for pane in &mut self.panes {
            if let Pane::GitStatus(g) = pane {
                g.refresh();
            }
        }
    }
    /// After any staging/commit change: refresh the cached status + all git panes.
    fn after_git_change(&mut self) {
        self.git.refresh();
        self.refresh_git_status_panes();
        self.refresh_git_graph_panes();
    }
    /// `(rel, is_staged)` for the highlighted file in the active git-status pane.
    fn git_status_selection(&self) -> Option<(String, bool)> {
        match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.rel.clone(), st)),
            _ => None,
        }
    }
    pub fn git_stage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if staged {
            self.toast("already staged — `u` to unstage");
            return;
        }
        match crate::git::stage::stage(&self.workspace, &rel) {
            Ok(()) => {
                self.toast(format!("staged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add: {e}")),
        }
    }
    pub fn git_unstage_selected(&mut self) {
        let Some((rel, staged)) = self.git_status_selection() else {
            return;
        };
        if !staged {
            self.toast("not staged — `s` to stage");
            return;
        }
        match crate::git::stage::unstage(&self.workspace, &rel) {
            Ok(()) => {
                self.toast(format!("unstaged {rel}"));
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }
    /// Space in the status pane — stage if unstaged, unstage if staged.
    pub fn git_toggle_selected(&mut self) {
        match self.git_status_selection() {
            Some((_, false)) => self.git_stage_selected(),
            Some((_, true)) => self.git_unstage_selected(),
            None => {}
        }
    }
    pub fn git_stage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::stage_all(&self.workspace) {
            Ok(()) => {
                self.toast("staged all changes");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git add -A: {e}")),
        }
    }
    pub fn git_unstage_all_active(&mut self) {
        if !matches!(self.active_pane(), Some(Pane::GitStatus(_))) {
            return;
        }
        match crate::git::stage::unstage_all(&self.workspace) {
            Ok(()) => {
                self.toast("unstaged everything");
                self.after_git_change();
            }
            Err(e) => self.toast(format!("git restore --staged: {e}")),
        }
    }
    /// Enter in the status pane — open the highlighted file's diff in a split.
    pub fn git_status_open_diff(&mut self) {
        let Some(cur) = self.active else { return };
        let sel = match self.panes.get(cur) {
            Some(Pane::GitStatus(g)) => g.selected_entry().map(|(e, st)| (e.abs.clone(), st)),
            _ => None,
        };
        let Some((abs, staged)) = sel else { return };
        let scope = if staged {
            crate::pane::DiffScope::Staged
        } else {
            crate::pane::DiffScope::Unstaged(Some(abs))
        };
        let hunks = self.fetch_diff(&scope);
        if hunks.is_empty() {
            self.toast("no diff for that file (untracked? — stage it to see it)");
            return;
        }
        let new_id = self.split_leaf_with(
            cur,
            crate::layout::SplitDir::Horizontal,
            Pane::Diff(crate::pane::DiffView::new(scope, hunks)),
        );
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }
    /// `C` in the status pane — ask `claude -p` to write a commit message from the
    /// staged diff; when it lands, the commit prompt opens pre-seeded with the
    /// first line (`drain_ai_jobs` routes it via `pending_commit_msg_job`).
    pub fn request_ai_commit_message(&mut self) {
        if self.git.snapshot().staged == 0 {
            self.toast("nothing staged — stage some changes first");
            return;
        }
        let diff = crate::git::stage::staged_diff(&self.workspace);
        if diff.trim().is_empty() {
            self.toast("no staged diff to summarise");
            return;
        }
        // Keep the prompt from getting silly-long on huge diffs.
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let prompt = format!(
            "Write a git commit message for the staged changes below. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something. \
             Output ONLY the commit message — no preamble, no code fences.\n\n\
             ```diff\n{diff}\n```"
        );
        let (job_id, _sid, _cancel) = self.spawn_ai_job(prompt);
        self.pending_commit_msg_job = Some(job_id);
        if let Some(Pane::GitStatus(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.ai_msg_job = Some(job_id);
        }
        self.toast("asking Claude for a commit message…");
    }

    // ─── branches / worktrees ───────────────────────────────────────
    /// Open a fuzzy picker over local + remote branches; accept ⇒ checkout.
    pub fn open_branch_picker(&mut self) {
        use crate::picker::PickerItem;
        let cur = crate::git::branch::current(&self.workspace);
        let mut items: Vec<PickerItem> = Vec::new();
        for b in crate::git::branch::local_branches(&self.workspace) {
            let detail = if Some(&b) == cur.as_ref() {
                "current"
            } else {
                "local"
            };
            items.push(PickerItem::new(format!("local:{b}"), b, detail));
        }
        for b in crate::git::branch::remote_branches(&self.workspace) {
            items.push(PickerItem::new(format!("remote:{b}"), b.clone(), "remote"));
        }
        if items.is_empty() {
            self.toast("no branches (not a git repo?)");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Branches, "Checkout branch", items));
    }
    /// Checkout the branch a `PickerKind::Branches` item id encodes.
    pub fn checkout_branch(&mut self, id: &str) {
        let result = if let Some(name) = id.strip_prefix("local:") {
            crate::git::branch::checkout(&self.workspace, name).map(|_| name.to_string())
        } else if let Some(remote) = id.strip_prefix("remote:") {
            crate::git::branch::checkout_track(&self.workspace, remote).map(|_| remote.to_string())
        } else {
            crate::git::branch::checkout(&self.workspace, id).map(|_| id.to_string())
        };
        match result {
            Ok(name) => self.after_checkout(&name),
            Err(e) => self.toast(format!("git checkout: {e}")),
        }
    }
    /// Open the "new branch name" prompt; accept ⇒ `git checkout -b <name>`.
    pub fn open_new_branch_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NewBranch,
            "New branch name (off current HEAD)",
        ));
    }
    pub fn create_branch(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.toast("branch creation cancelled (empty name)");
            return;
        }
        match crate::git::branch::create(&self.workspace, name) {
            Ok(()) => self.after_checkout(name),
            Err(e) => self.toast(format!("git checkout -b: {e}")),
        }
    }
    /// Open a picker over `git worktree list`; accept ⇒ a shell pane in that dir.
    pub fn open_worktree_picker(&mut self) {
        use crate::picker::PickerItem;
        let wts = crate::git::branch::worktrees(&self.workspace);
        if wts.is_empty() {
            self.toast("no worktrees (not a git repo?)");
            return;
        }
        let items: Vec<PickerItem> = wts
            .into_iter()
            .map(|w| {
                let detail = if w.is_current {
                    format!("{} · current", w.label)
                } else {
                    w.label.clone()
                };
                PickerItem::new(
                    w.path.display().to_string(),
                    w.path.display().to_string(),
                    detail,
                )
            })
            .collect();
        self.open_picker(Picker::new(
            PickerKind::Worktrees,
            "Worktree → shell",
            items,
        ));
    }
    /// Open a shell pane in `path` (a worktree directory).
    pub fn open_worktree_shell(&mut self, path: &str) {
        self.open_pty(crate::pty_pane::BinaryProfile::shell(Some(PathBuf::from(
            path,
        ))));
    }
    /// Common tail of a checkout / new-branch: refresh git + tree, warn that open
    /// editors may now be stale (their file on disk could differ).
    fn after_checkout(&mut self, label: &str) {
        self.after_git_change();
        self.tree.refresh();
        let dirty_open = self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.dirty));
        if dirty_open {
            self.toast(format!(
                "switched to {label} — heads up: you have unsaved edits open"
            ));
        } else {
            self.toast(format!(
                "switched to {label} — reopen files if their content changed"
            ));
        }
    }

    /// Move focus to the leaf in direction `d` of the focused one (by the rects
    /// recorded at last render). No wrap.
    pub fn focus_dir(&mut self, d: FocusDir) {
        let Some(cur) = self.active else { return };
        let Some(&(cur_rect, _)) = self.rects.editor_panes.iter().find(|(_, p)| *p == cur) else {
            return;
        };
        let (cx, cy) = (
            cur_rect.x as i32 + cur_rect.width as i32 / 2,
            cur_rect.y as i32 + cur_rect.height as i32 / 2,
        );
        let mut best: Option<(i64, PaneId)> = None;
        for &(r, pid) in &self.rects.editor_panes {
            if pid == cur {
                continue;
            }
            let (mx, my) = (
                r.x as i32 + r.width as i32 / 2,
                r.y as i32 + r.height as i32 / 2,
            );
            let on_side = match d {
                FocusDir::Left => mx < cx,
                FocusDir::Right => mx > cx,
                FocusDir::Up => my < cy,
                FocusDir::Down => my > cy,
            };
            if !on_side {
                continue;
            }
            // Require some overlap on the perpendicular axis (so a left-and-up
            // neighbour doesn't steal a "go left").
            let overlap = match d {
                FocusDir::Left | FocusDir::Right => {
                    r.y < cur_rect.y + cur_rect.height && cur_rect.y < r.y + r.height
                }
                FocusDir::Up | FocusDir::Down => {
                    r.x < cur_rect.x + cur_rect.width && cur_rect.x < r.x + r.width
                }
            };
            if !overlap {
                continue;
            }
            let dist = ((mx - cx) as i64).pow(2) + ((my - cy) as i64).pow(2);
            if best.is_none_or(|(bd, _)| dist < bd) {
                best = Some((dist, pid));
            }
        }
        if let Some((_, pid)) = best {
            self.active = Some(pid);
            self.focus = Focus::Pane;
        }
    }

    /// Cycle focus to the next leaf (left-to-right / top-to-bottom order).
    pub fn focus_next_split(&mut self) {
        let leaves = self.layout.leaves();
        if leaves.len() < 2 {
            return;
        }
        let here = self
            .active
            .and_then(|a| leaves.iter().position(|&l| l == a))
            .unwrap_or(0);
        self.active = Some(leaves[(here + 1) % leaves.len()]);
        self.focus = Focus::Pane;
    }

    /// If `(x, y)` is on a split divider, begin dragging it. Returns true if so.
    pub fn begin_divider_drag(&mut self, x: u16, y: u16) -> bool {
        if let Some(d) = self
            .rects
            .split_dividers
            .iter()
            .find(|d| {
                x >= d.rect.x
                    && x < d.rect.x + d.rect.width
                    && y >= d.rect.y
                    && y < d.rect.y + d.rect.height
            })
            .cloned()
        {
            self.dragging = Some(d);
            true
        } else {
            false
        }
    }
    /// Continue a divider drag: set the split's ratio from the pointer position.
    pub fn drag_divider_to(&mut self, x: u16, y: u16) {
        if let Some(d) = &self.dragging {
            let ratio = d.ratio_for(x, y);
            let path = d.path.clone();
            self.layout.set_ratio_at(&path, ratio);
        }
    }
    pub fn end_divider_drag(&mut self) {
        self.dragging = None;
    }

    /// Close the buffer at `id`. If it's a dirty editor, this opens the
    /// Save/Discard/Cancel confirm overlay instead and returns; otherwise it
    /// closes immediately. Use [`Self::force_close_pane`] to skip the prompt.
    pub fn close_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        let dirty = matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.dirty);
        if dirty {
            self.close_prompt = Some(id);
            return;
        }
        self.force_close_pane(id);
    }

    /// Close the buffer at `id` unconditionally, discarding unsaved changes (with
    /// a toast). If it's shown in a leaf, that leaf is removed (its parent split
    /// collapses into the sibling); if the closed leaf was focused, focus moves
    /// to the next leaf — or, if none remain but a background buffer does, that
    /// buffer is shown.
    pub fn force_close_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        let (discarded, closed_path) = match &self.panes[id] {
            Pane::Editor(b) => (b.dirty.then(|| b.display_name()), b.path.clone()),
            Pane::MdPreview(_)
            | Pane::Diff(_)
            | Pane::GitGraph(_)
            | Pane::GitStatus(_)
            | Pane::Request(_)
            | Pane::Pty(_)
            | Pane::Ai(_)
            | Pane::Tests(_)
            | Pane::Diagnostics(_) => (None, None),
        };
        if self.layout.contains(id) {
            self.layout.remove_leaf(id);
        }
        if self.active == Some(id) {
            self.active = self.layout.first_leaf();
        }
        self.remove_pane_storage(id);
        // If no other editor pane still shows that file, tell the LSP server.
        if let Some(p) = closed_path
            && !self
                .panes
                .iter()
                .any(|pane| matches!(pane, Pane::Editor(b) if b.is_at(&p)))
        {
            self.lsp.did_close(&p);
        }
        // If we dropped the last leaf but background buffers remain, show one.
        if self.active.is_none() && !self.panes.is_empty() {
            self.reveal_pane(self.panes.len() - 1);
        }
        if let Some(name) = discarded {
            self.toast(format!("closed {name} — discarded unsaved changes"));
        }
        if self.active.is_none() {
            self.focus = Focus::Tree;
        }
    }

    pub fn close_active_pane(&mut self) {
        if let Some(i) = self.active {
            self.close_pane(i);
        }
    }
    pub fn force_close_active_pane(&mut self) {
        if let Some(i) = self.active {
            self.force_close_pane(i);
        }
    }

    /// Resolve the close-confirm overlay. `choice`: 0 = Save (then close),
    /// 1 = Discard (close, lose changes), 2 = Cancel.
    pub fn close_prompt_resolve(&mut self, choice: u8) {
        let Some(id) = self.close_prompt.take() else {
            return;
        };
        match choice {
            0 => {
                // Save then close. A save failure aborts the close (the toast says why).
                let ok = match self.panes.get_mut(id) {
                    Some(Pane::Editor(b)) if b.path.is_some() => match b.save_to_disk() {
                        Ok(()) => true,
                        Err(e) => {
                            self.toast(format!("save failed: {e}"));
                            false
                        }
                    },
                    Some(Pane::Editor(_)) => {
                        self.toast("can't save a scratch buffer — pick Discard or Cancel");
                        false
                    }
                    _ => true,
                };
                if ok {
                    self.git.refresh();
                    self.disarm_quit();
                    self.force_close_pane(id);
                }
            }
            1 => self.force_close_pane(id),
            _ => {} // cancel
        }
    }
    /// `(display_name, has_path)` for the buffer awaiting a close decision, if any.
    pub fn close_prompt_info(&self) -> Option<(String, bool)> {
        let id = self.close_prompt?;
        match self.panes.get(id)? {
            Pane::Editor(b) => Some((b.display_name(), b.path.is_some())),
            Pane::MdPreview(p) => Some((p.title(), false)),
            Pane::Diff(d) => Some((d.title(), false)),
            Pane::GitGraph(g) => Some((g.tab_title(), false)),
            Pane::GitStatus(g) => Some((g.tab_title(), false)),
            Pane::Request(r) => Some((r.title(), false)),
            Pane::Pty(s) => Some((s.title(), false)),
            Pane::Ai(a) => Some((a.tab_title(), false)),
            Pane::Tests(t) => Some((t.tab_title(), false)),
            Pane::Diagnostics(d) => Some((d.tab_title(), false)),
        }
    }

    /// Cycle the focused leaf to the next open buffer (wrapping). A buffer
    /// already visible in another leaf just gets focused there.
    pub fn next_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        self.reveal_pane((cur + 1) % self.panes.len());
    }
    pub fn prev_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        self.reveal_pane((cur + self.panes.len() - 1) % self.panes.len());
    }

    pub fn save_active(&mut self) {
        let saved_path = match self.active_editor_mut() {
            Some(buf) if buf.path.is_some() => {
                let name = buf.display_name();
                match buf.save_to_disk() {
                    Ok(()) => {
                        let p = buf.path.clone();
                        self.toast(format!("saved {name}"));
                        self.git.refresh();
                        self.disarm_quit();
                        p
                    }
                    Err(e) => {
                        self.toast(format!("save failed: {e}"));
                        None
                    }
                }
            }
            Some(_) => {
                self.toast("nothing to save (scratch buffer)".to_string());
                None
            }
            None => {
                self.toast("no active editor".to_string());
                None
            }
        };
        if let Some(p) = saved_path {
            self.refresh_md_previews(&p);
            self.refresh_blame_for(&p);
            self.notify_lsp_saved(&p);
        }
    }
    pub fn save_all(&mut self) {
        let mut n = 0;
        let mut saved: Vec<std::path::PathBuf> = Vec::new();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane
                && b.path.is_some()
                && b.dirty
                && b.save_to_disk().is_ok()
            {
                n += 1;
                if let Some(p) = &b.path {
                    saved.push(p.clone());
                }
            }
        }
        self.git.refresh();
        self.disarm_quit();
        for p in saved {
            self.refresh_md_previews(&p);
            self.refresh_blame_for(&p);
            self.notify_lsp_saved(&p);
        }
        self.toast(format!("saved {n} file(s)"));
    }

    pub fn editing_mode(&self) -> EditingMode {
        match self.focus {
            Focus::Pane => self
                .active_editor()
                .map(Buffer::editing_mode)
                .unwrap_or(EditingMode::None),
            _ => EditingMode::None,
        }
    }

    pub fn pending_display(&self) -> Option<String> {
        if self.focus == Focus::Pane {
            self.active_editor().and_then(|b| b.input.pending_display())
        } else {
            None
        }
    }

    // ─── keymap (vim ⇄ standard) ────────────────────────────────────
    /// Swap every editor buffer's input handler to `style` (`"vim"` | `"standard"`),
    /// remember it as the new default, and toast the result.
    pub fn set_input_style(&mut self, style: &str) {
        let style = match style {
            "vim" => "vim",
            "standard" | "vscode" => "standard",
            other => {
                self.toast(format!("unknown input style: {other}"));
                return;
            }
        };
        self.config.editor.input_style = style.to_string();
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane {
                b.input = crate::input::make_handler_for(style, &self.config);
            }
        }
        // A `[keys.<style>]` section may rebind chords — re-resolve the table.
        self.keymap = crate::input::keymap::Keymap::build(&self.config);
        self.toast(format!("input: {style}"));
    }
    pub fn toggle_input_style(&mut self) {
        let next = if self.config.editor.input_style == "vim" {
            "standard"
        } else {
            "vim"
        };
        self.set_input_style(next);
    }

    /// Turn hybrid relative line numbers on/off (`:set [no]relativenumber`,
    /// `view.toggle_relative_numbers`).
    pub fn set_relative_line_numbers(&mut self, on: bool) {
        self.config.ui.relative_line_numbers = on;
        self.toast(if on {
            "relative line numbers: on"
        } else {
            "relative line numbers: off"
        });
    }
    pub fn toggle_relative_line_numbers(&mut self) {
        self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
    }

    /// Interpret a vim `:`-line (without the leading `:`). Anything we don't
    /// recognise is bridged to a registered command if one matches, else toasted.
    pub fn run_ex_command(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        // Bare number ⇒ jump to that line.
        if let Ok(n) = line.parse::<usize>() {
            if let Some(b) = self.active_editor_mut() {
                b.editor.place_cursor(n.saturating_sub(1), 0);
            }
            return;
        }
        let (cmd, rest) = match line.split_once(char::is_whitespace) {
            Some((c, r)) => (c, r.trim()),
            None => (line, ""),
        };
        match cmd {
            "w" | "write" => {
                if rest.is_empty() {
                    self.save_active();
                } else {
                    self.toast(":w <path> not supported yet");
                }
            }
            "q" | "quit" => {
                if self.active.is_some() && self.active_pane().is_some_and(Pane::is_dirty) {
                    self.toast("unsaved changes — use :q! to discard");
                } else {
                    self.close_active_pane();
                    if self.panes.is_empty() {
                        self.should_quit = true;
                    }
                }
            }
            "q!" | "quit!" => {
                self.force_close_active_pane();
                if self.panes.is_empty() {
                    self.should_quit = true;
                }
            }
            "wq" | "x" | "xit" => {
                self.save_active();
                // After a successful save the buffer's clean, so this won't prompt.
                self.close_active_pane();
                if self.panes.is_empty() {
                    self.should_quit = true;
                }
            }
            "wa" | "wall" => self.save_all(),
            "wqa" | "wqall" | "xa" | "xall" => {
                self.save_all();
                self.should_quit = true;
            }
            "qa" | "qall" | "quitall" => self.should_quit = true,
            "qa!" | "qall!" => self.should_quit = true,
            "bd" | "bdelete" => self.close_active_pane(),
            "bn" | "bnext" => self.next_buffer(),
            "bp" | "bprev" | "bprevious" => self.prev_buffer(),
            "e" | "edit" => {
                if rest.is_empty() {
                    self.toast(":e needs a path");
                } else {
                    let p = self.workspace.join(rest);
                    self.open_path(&p);
                }
            }
            "set" => {
                // `:set input=vim|standard` · `:set theme=…` · `:set [no]relativenumber`
                let opt = rest.trim();
                if let Some(v) = rest.strip_prefix("input=") {
                    self.set_input_style(v.trim());
                } else if let Some(v) = rest.strip_prefix("theme=") {
                    self.set_theme(v.trim());
                } else if matches!(opt, "relativenumber" | "rnu") {
                    self.set_relative_line_numbers(true);
                } else if matches!(opt, "norelativenumber" | "nornu") {
                    self.set_relative_line_numbers(false);
                } else if matches!(opt, "relativenumber!" | "rnu!" | "invrelativenumber") {
                    self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
                } else {
                    self.toast(format!(":set {rest} — not supported"));
                }
            }
            "noh" | "nohl" | "nohlsearch" => {}
            other => {
                // Last resort: maybe it names a registered command.
                if crate::command::registry().get(other).is_some() {
                    crate::command::run(other, self);
                } else {
                    self.toast(format!(":{line} — unknown command"));
                }
            }
        }
    }

    // ─── focus ──────────────────────────────────────────────────────
    pub fn cycle_focus(&mut self) {
        let was_pane = self.focus == Focus::Pane;
        self.focus = self.focus.next(self.active.is_some());
        if was_pane
            && self.focus != Focus::Pane
            && let Some(b) = self.active_editor_mut()
        {
            b.input.on_blur();
        }
    }
    pub fn focus_tree(&mut self) {
        if self.focus == Focus::Pane
            && let Some(b) = self.active_editor_mut()
        {
            b.input.on_blur();
        }
        self.focus = Focus::Tree;
    }
    pub fn focus_pane(&mut self) {
        if self.active.is_some() {
            self.focus = Focus::Pane;
        }
    }

    // ─── tree ───────────────────────────────────────────────────────
    /// Enter/click on the row under the tree cursor: open a file, or expand/collapse a dir.
    pub fn tree_activate(&mut self) {
        if let Some(file) = self.tree.selected_file() {
            self.open_path(&file);
        } else {
            self.tree.toggle_current();
        }
    }

    // ─── misc ───────────────────────────────────────────────────────
    pub fn request_quit(&mut self) {
        let dirty = self.panes.iter().any(|p| p.is_dirty());
        if dirty && !self.quit_armed {
            self.quit_armed = true;
            self.toast("unsaved changes — press quit again, or save first");
        } else {
            self.should_quit = true;
        }
    }
    fn disarm_quit(&mut self) {
        self.quit_armed = false;
    }
    /// Exit so the `run.sh` wrapper rebuilds and relaunches us with the same args.
    pub fn request_restart(&mut self) {
        self.restart_requested = true;
        self.should_quit = true;
    }

    pub fn toast(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }
    /// Current toast text if it hasn't expired.
    pub fn live_toast(&self) -> Option<&str> {
        self.toast
            .as_ref()
            .filter(|(_, t)| t.elapsed() < TOAST_TTL)
            .map(|(s, _)| s.as_str())
    }

    /// Per-event-loop housekeeping (cheap).
    pub fn tick(&mut self) {
        self.git.tick();
        self.drain_http_jobs();
        self.drain_ai_jobs();
        self.drain_tests_jobs();
        self.drain_lsp_events();
        self.refresh_live_ai_panes();
        if let Some((_, t)) = &self.toast
            && t.elapsed() >= TOAST_TTL
        {
            self.toast = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    #[test]
    fn open_path_dedups_and_refocuses() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        assert_eq!(app.panes.len(), 2);
        app.open_path(&d.path().join("a.txt")); // already open → no new pane
        assert_eq!(app.panes.len(), 2);
        assert_eq!(app.active, Some(0));
        assert_eq!(app.focus, Focus::Pane);
    }

    #[test]
    fn close_clears_when_empty() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.close_active_pane();
        assert!(app.panes.is_empty());
        assert!(app.active.is_none());
        assert_eq!(app.focus, Focus::Tree);
        assert!(matches!(app.layout, Layout::Empty));
    }

    #[test]
    fn editing_mode_is_none_without_editor() {
        let (_d, app) = app_with_files();
        assert_eq!(app.editing_mode(), EditingMode::None);
    }
}
