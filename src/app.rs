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
    next_job_id: u64,
}

type HttpJobDone = (u64, Result<crate::request_pane::ResponseView, String>);
type AiJobDone = (u64, Result<String, String>);

impl App {
    pub fn new(workspace: PathBuf, config: Config) -> Result<App, String> {
        let workspace = workspace
            .canonicalize()
            .map_err(|e| format!("cannot open workspace {}: {e}", workspace.display()))?;
        let tree = Tree::open(&workspace);
        let git = GitStatus::new(&workspace);
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
            http_chan: None,
            ai_chan: None,
            next_job_id: 1,
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
    /// Open the command palette over the registered commands.
    pub fn open_command_palette(&mut self) {
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = crate::command::registry()
            .all()
            .iter()
            .filter(|c| c.id != "palette")
            .map(|c| PickerItem::new(c.id, format!("{}  ·  {}", c.group, c.title), c.key_hint()))
            .collect();
        self.open_picker(Picker::new(PickerKind::Commands, "Command palette", items));
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
                self.panes.push(Pane::Editor(buf));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
            }
            Err(e) => self.toast(format!("cannot open {}: {e}", path.display())),
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
            | Some(Pane::Request(_))
            | Some(Pane::Pty(_))
            | Some(Pane::Ai(_))
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
            | Some(Pane::Request(_))
            | Some(Pane::Pty(_))
            | Some(Pane::Ai(_)) => {
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
    /// Open a `Pane::Ai` showing `title` and the answer to `prompt`, and kick off
    /// `claude -p <prompt>` on a background thread (`tick` delivers the answer).
    pub fn ask_ai(&mut self, title: impl Into<String>, prompt: String) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let p = prompt.clone();
        std::thread::spawn(move || {
            let _ = tx.send((job_id, crate::ai::one_shot(&p)));
        });
        let pane = Pane::Ai(crate::ai::AiPane::new(title, prompt, job_id));
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

    /// Re-send the prompt an existing `Pane::Ai` holds.
    fn reask_ai(&mut self, pane_id: PaneId) {
        let prompt = match self.panes.get(pane_id) {
            Some(Pane::Ai(a)) => a.prompt.clone(),
            _ => return,
        };
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let p = prompt.clone();
        std::thread::spawn(move || {
            let _ = tx.send((job_id, crate::ai::one_shot(&p)));
        });
        if let Some(Pane::Ai(a)) = self.panes.get_mut(pane_id) {
            a.job_id = job_id;
            a.state = crate::ai::AiState::Asking;
            a.scroll = 0;
        }
    }

    /// `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests` — feed the active
    /// editor's selection (or the whole buffer) + a task prompt to `claude -p`.
    pub fn ai_action(&mut self, what: &str) {
        let (code, lang) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) => {
                let sel = b.editor.selected_text();
                let code = if sel.trim().is_empty() {
                    b.editor.text().to_string()
                } else {
                    sel
                };
                (code, b.language_ext.clone().unwrap_or_default())
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
                crate::pane::DiffScope::Staged => None,
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
        match crate::git::diff::apply_hunk(&self.workspace, &hunk, reverse) {
            Ok(()) => {
                self.toast(if reverse {
                    "unstaged hunk"
                } else {
                    "staged hunk"
                });
                self.git.refresh();
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
                        self.git.refresh();
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
        let discarded = match &self.panes[id] {
            Pane::Editor(b) => b.dirty.then(|| b.display_name()),
            Pane::MdPreview(_) | Pane::Diff(_) | Pane::Request(_) | Pane::Pty(_) | Pane::Ai(_) => {
                None
            }
        };
        if self.layout.contains(id) {
            self.layout.remove_leaf(id);
        }
        if self.active == Some(id) {
            self.active = self.layout.first_leaf();
        }
        self.remove_pane_storage(id);
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
            Pane::Request(r) => Some((r.title(), false)),
            Pane::Pty(s) => Some((s.title(), false)),
            Pane::Ai(a) => Some((a.tab_title(), false)),
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
                // `:set input=vim|standard` · `:set theme=onedark|gruvbox|catppuccin`
                if let Some(v) = rest.strip_prefix("input=") {
                    self.set_input_style(v.trim());
                } else if let Some(v) = rest.strip_prefix("theme=") {
                    self.set_theme(v.trim());
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
