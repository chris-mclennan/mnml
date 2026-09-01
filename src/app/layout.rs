//! Pane + layout methods on `App` — open / reveal / close panes,
//! split tree mutators, focus / divider drag / tab pages, full-screen mode.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move. This is
//! the most cross-coupled subsystem; every other `app/*.rs` reaches
//! these methods via `pub` (mostly) — visibility lifted where
//! `pub(super)` is sufficient.

use super::*;

/// True if the profile label belongs to an AI CLI (Claude Code /
/// Codex / any resumed session). Used to gate the
/// `auto_show_sessions_on_ai_activate` swap in `reveal_pane` +
/// the `_new` spawn variants.
pub(crate) fn is_ai_profile(label: &str) -> bool {
    label.starts_with("Claude") || label == "Codex"
}

impl App {
    /// Active tab page's split tree (mutable view).
    pub fn layout_mut(&mut self) -> &mut Layout {
        &mut self.layouts[self.active_layout]
    }

    /// #856 — `layout.merge_to_tabs` palette command. Flatten the
    /// current tab page's split tree into a single leaf whose tabs
    /// carry every pane from every leaf. Focus stays on the
    /// currently-active pane. No-op on Empty / single-leaf layouts.
    ///
    /// Toast reports the shape change so users know what happened
    /// (e.g. "merged 4 splits into 4 tabs"). Reverse:
    /// [`App::spread_tabs_to_splits`].
    pub fn merge_splits_to_tabs(&mut self) {
        let panes_before = self.layout().all_panes();
        if panes_before.len() <= 1 {
            self.toast("layout: nothing to merge");
            return;
        }
        let leaf_count = self.layout().leaves().len();
        if leaf_count <= 1 {
            self.toast("layout: already a single leaf");
            return;
        }
        let active_hint = self.active.unwrap_or(panes_before[0]);
        *self.layout_mut() = self.layout().merge_to_tabs(active_hint);
        self.toast(format!(
            "layout: merged {leaf_count} splits into {} tabs",
            panes_before.len()
        ));
    }

    /// #857 — `layout.spread_to_splits` palette command. Take the
    /// current tab page (must be a single leaf with N tabs) and
    /// spread each tab into its own split via the same shape
    /// heuristic multi-Claude auto-tile uses (1 leaf / H-split / 3
    /// / 2×2 / 3×2 / 4×2). No-op on layouts that already have any
    /// splits, or on single-tab leaves.
    ///
    /// Toast reports the shape change. Reverse:
    /// [`App::merge_splits_to_tabs`].
    pub fn spread_tabs_to_splits(&mut self) {
        let (n_tabs, has_split) = match self.layout() {
            Layout::Empty => (0, false),
            Layout::Leaf { tabs, .. } => (tabs.len(), false),
            Layout::Split { .. } => (0, true),
        };
        if has_split {
            self.toast("layout: already has splits; merge to tabs first");
            return;
        }
        if n_tabs <= 1 {
            self.toast("layout: nothing to spread");
            return;
        }
        let new_layout = self.layout().spread_to_splits();
        *self.layout_mut() = new_layout;
        let n_leaves = self.layout().leaves().len();
        self.toast(format!(
            "layout: spread {n_tabs} tabs into {n_leaves} splits"
        ));
    }

    /// Right-click on a bufferline tab (the pane `id`) at screen cell `anchor`.
    pub fn open_tab_context_menu(&mut self, id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = self.panes.get(id).map(Pane::title).unwrap_or_default();
        let mut items = Vec::new();
        // Save: only for editor panes with a path AND only when dirty.
        // Surfaces the SEV-2 fix from the VS-Code-mouse hunt 2026-06-07
        // ("no Save button anywhere" — the menu had Close × 3 + Copy
        // path, no Save). Placed at the top because saving is the
        // most-common, lowest-cost action.
        if let Some(Pane::Editor(b)) = self.panes.get(id)
            && b.path.is_some()
            && b.dirty
        {
            items.push(MenuItem::new("Save", MenuAction::SavePane(id)));
        }
        // 2026-06-21 — VS Code-style Pin tab. Only offered for
        // editor panes (pty/Request/etc. tabs aren't pin-eligible).
        // Label flips based on current pinned state.
        if matches!(self.panes.get(id), Some(Pane::Editor(_))) {
            let pinned = matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.is_pinned);
            items.push(MenuItem::new(
                if pinned { "Unpin tab" } else { "Pin tab" },
                MenuAction::PinTab(id),
            ));
        }
        items.push(MenuItem::new("Close", MenuAction::CloseTab(id)));
        items.push(MenuItem::new(
            "Close others",
            MenuAction::CloseOtherTabs(id),
        ));
        items.push(MenuItem::new("Close all", MenuAction::CloseAllTabs));
        // #polish 2026-07-06 — Request pane tab: "View source"
        // opens the `.http`/`.curl`/`.rest` file as a plain text
        // Editor so the user can see the file syntax. Only when
        // the request has a saved source path.
        if let Some(Pane::Request(rp)) = self.panes.get(id)
            && let Some(p) = &rp.source_path
        {
            items.push(MenuItem::new(
                "View source (as text)",
                MenuAction::OpenPathAsText(p.clone()),
            ));
            items.push(MenuItem::new(
                "Copy path",
                MenuAction::CopyPath(rel_path(&self.workspace, p)),
            ));
            items.push(MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(p.clone()),
            ));
        }
        if let Some(Pane::Editor(b)) = self.panes.get(id)
            && let Some(p) = &b.path
        {
            if is_markdown_path(p) {
                items.push(MenuItem::new(
                    "Preview markdown",
                    MenuAction::PreviewMarkdown(p.clone()),
                ));
            }
            items.push(MenuItem::new(
                "Copy relative path",
                MenuAction::CopyPath(rel_path(&self.workspace, p)),
            ));
            // 2026-06-27: explicit absolute path entry (VS Code parity).
            items.push(MenuItem::new(
                "Copy absolute path",
                MenuAction::CopyPath(p.display().to_string()),
            ));
            // OS-aware label so "Reveal in Finder" reads
            // "Reveal in Explorer" on Windows / "Reveal in Files"
            // on Linux. Action under the hood is the same — the
            // RevealInFinder handler shells out to the platform
            // file browser.
            items.push(MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(p.clone()),
            ));
        }
        // Split this tab off into a new half of the current leaf.
        // Mirrors VS Code's Split & Move submenu — drag-to-split via
        // the keyboard. Available for any pane type that has a tab
        // (i.e. anything in the bufferline). After the split, the
        // dragged tab lives alone in the new half.
        use crate::app::tab_drop::DropZone;
        items.push(MenuItem::new(
            "Split right",
            MenuAction::SplitTabInto(id, DropZone::Right),
        ));
        items.push(MenuItem::new(
            "Split down",
            MenuAction::SplitTabInto(id, DropZone::Bottom),
        ));
        items.push(MenuItem::new(
            "Split left",
            MenuAction::SplitTabInto(id, DropZone::Left),
        ));
        items.push(MenuItem::new(
            "Split up",
            MenuAction::SplitTabInto(id, DropZone::Top),
        ));
        // #906 slice C (2026-08-20) — offer "Move to bottom panel"
        // for pane kinds that render with a right-panel-style draw
        // fn (Outline / Diagnostics / IntegrationDetail /
        // ClaudeUsage / CodexUsage / Tests / Grep). Other kinds hit
        // the "not hostable yet" fallback in draw_bottom_panel, so
        // hide the item rather than lead users to a dead-end.
        let hostable = matches!(
            self.panes.get(id),
            Some(
                Pane::Outline(_)
                    | Pane::Diagnostics(_)
                    | Pane::IntegrationDetail(_)
                    | Pane::ClaudeUsage(_)
                    | Pane::CodexUsage(_)
                    | Pane::Tests(_)
                    | Pane::Grep(_)
            )
        );
        if hostable {
            items.push(MenuItem::new(
                "Move to bottom panel",
                MenuAction::HostInBottomPanel(id),
            ));
        }
        // Claude / Codex / shell tabs can be renamed from here too.
        // mouse-round-7 SEV-3 2026-07-12 — plus the terminal-native
        // Restart (kill+respawn) / Clear (Ctrl+L) / Interrupt (Ctrl+C)
        // verbs a mouse user would reach for on a hung `btop` / `htop`
        // pane. `term.*` commands act on `App.active`; the menu opener
        // sets active to this tab first (see the RenameSession
        // handler pattern) so the right-click never acts on the
        // wrong session.
        if matches!(self.panes.get(id), Some(Pane::Pty(_))) {
            items.push(MenuItem::new("Rename…", MenuAction::RenameSession(id)));
            items.push(MenuItem::new("Restart", MenuAction::PtyRestart(id)));
            items.push(MenuItem::new(
                "Interrupt (Ctrl+C)",
                MenuAction::PtyInterrupt(id),
            ));
            items.push(MenuItem::new("Clear (Ctrl+L)", MenuAction::PtyClear(id)));
        }
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click menu for a tab in a pty pane's own tab strip
    /// (Claude / Codex / shell session): Rename → the session-name
    /// prompt; Color: … → set per-session accent (task #1178 f/u,
    /// 2026-08-23 user ask — mirrors the sessions-rail menu so the
    /// two entry points don't diverge); Close → close that session.
    pub fn open_pty_tab_context_menu(&mut self, id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let is_claude = matches!(
            self.panes.get(id),
            Some(Pane::Pty(s)) if s.profile.session_id.is_some()
                && s.profile.label.starts_with("Claude")
        );
        if !matches!(self.panes.get(id), Some(Pane::Pty(_))) {
            return;
        }
        let title = self.panes.get(id).map(Pane::title).unwrap_or_default();
        let mut items = vec![MenuItem::new("Rename…", MenuAction::RenameSession(id))];
        if is_claude {
            // Multi-session workflow (#4) — "Fork" reads more clearly
            // than "Open new Claude Code" for the case where you want
            // a parallel thread from within an active Claude pane.
            items.push(MenuItem::new(
                "Fork new Claude session",
                MenuAction::Command("ai.claude_code_new"),
            ));
        }
        // Same list rendered on the sessions-rail row — share via helper.
        items.extend(super::session_pane_methods::session_color_menu_items(id));
        items.push(MenuItem::new("Close", MenuAction::CloseTab(id)));
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Close every pane (optionally keeping `keep`), skipping dirty editors so
    /// nothing is lost silently — they're kept and counted.
    pub(super) fn close_panes_except(&mut self, keep: Option<PaneId>) {
        let mut kept_dirty = 0usize;
        let mut kept_pinned = 0usize;
        // Walk high→low so the indices below the one we close stay valid.
        for i in (0..self.panes.len()).rev() {
            if Some(i) == keep {
                continue;
            }
            if matches!(self.panes.get(i), Some(Pane::Editor(b)) if b.dirty) {
                kept_dirty += 1;
                continue;
            }
            // 2026-06-21 — VS Code-style pinned tabs are immune to
            // Close all / Close others. User must explicitly
            // unpin then close, or right-click → Close on that tab.
            if matches!(self.panes.get(i), Some(Pane::Editor(b)) if b.is_pinned) {
                kept_pinned += 1;
                continue;
            }
            self.force_close_pane(i);
        }
        let mut bits: Vec<String> = Vec::new();
        if kept_dirty > 0 {
            bits.push(format!("{kept_dirty} unsaved"));
        }
        if kept_pinned > 0 {
            bits.push(format!("{kept_pinned} pinned"));
        }
        if !bits.is_empty() {
            self.toast(format!("kept {}", bits.join(" + ")));
        }
    }

    pub fn active_pane(&self) -> Option<&Pane> {
        self.active.and_then(|i| self.panes.get(i))
    }

    pub fn active_pane_mut(&mut self) -> Option<&mut Pane> {
        match self.active {
            Some(i) => self.panes.get_mut(i),
            None => None,
        }
    }

    /// Show pane `id` in the focused leaf (demoting whatever it showed to a
    /// background buffer). If `id` is already shown in some leaf, just focus that
    /// leaf instead — a buffer is never in two leaves at once. If nothing is open,
    /// create the first leaf showing `id`.
    pub fn reveal_pane(&mut self, id: PaneId) {
        if id >= self.panes.len() {
            return;
        }
        // Capture the outgoing active for `Ctrl+Tab` (last-buffer toggle) —
        // skip the no-op case where we're "revealing" the already-active.
        let prior = self.active;
        // Optional: autosave the outgoing buffer if it's dirty and the
        // user opted in via `[editor] autosave_on_focus_loss`. Avoid
        // the no-op self-switch case.
        if self.config.editor.autosave_on_focus_loss
            && let Some(outgoing) = prior
            && outgoing != id
            && let Some(Pane::Editor(b)) = self.panes.get_mut(outgoing)
            && b.dirty
            && b.path.is_some()
            && b.save_to_disk().is_ok()
        {
            let upd = b.path.clone().map(|p| (p, b.editor.text().to_string()));
            if let Some((p, text)) = upd {
                self.lsp.did_save(&p, &text);
            }
        }
        if self.layout().contains(id) {
            // Already in the current layout — possibly as the
            // active tab of some leaf, possibly as a background
            // tab. Flip the containing leaf's active to this
            // pane, then set App::active.
            if let Some((active, _tabs)) = self.layout_mut().leaf_containing_mut(id) {
                *active = id;
            }
            self.active = Some(id);
        } else if let Some(other_tab) = self
            .layouts
            .iter()
            .enumerate()
            .find_map(|(i, l)| (i != self.active_layout && l.contains(id)).then_some(i))
        {
            // Pane lives in another tab page — switch tabs so the
            // invariant "each pane is in at most one leaf across all
            // tabs" holds.
            self.remember_active_for_tab();
            self.active_layout = other_tab;
            self.active = Some(id);
        } else if let Some(cur) = self.active {
            // 2026-06-22 multi-tab: instead of REPLACING the active
            // pane (the old set_leaf_pane behavior — which
            // orphaned the prior pane into a background bufferline
            // tab), ADD `id` to the focused leaf's tabs as the new
            // active. The user's "open a file in this split"
            // becomes a tab in that split, matching VS Code.
            if let Some((active, tabs)) = self.layout_mut().active_leaf_mut(cur) {
                if !tabs.contains(&id) {
                    tabs.push(id);
                }
                *active = id;
            } else {
                *self.layout_mut() = Layout::leaf(id);
            }
            self.active = Some(id);
        } else {
            *self.layout_mut() = Layout::leaf(id);
            self.active = Some(id);
        }
        if prior != self.active {
            self.last_active = prior;
        }
        self.focus = Focus::Pane;
        // one-tab-type 2026-07-18 — auto-switch the activity panel
        // to Sessions when the revealed pane is a Claude Code /
        // Codex Pty. Gated on `[ui] auto_show_sessions_on_ai_activate`
        // so vim users who `:bn`/`:bp`-cycle can turn it off.
        if self.config.ui.auto_show_sessions_on_ai_activate
            && matches!(self.panes.get(id), Some(Pane::Pty(s)) if is_ai_profile(&s.profile.label))
        {
            self.set_activity_section(crate::app::ActivitySection::Sessions);
        }
        self.retarget_outline_to_active();
        // If the revealed pane is a GitGraph, refresh it — its WIP virtual
        // row + commit list otherwise stay frozen at the last `after_git_change`
        // call. Picks up working-tree changes that happened externally (or in
        // another split) while the graph wasn't focused.
        if let Some(Pane::GitGraph(g)) = self.panes.get_mut(id) {
            g.refresh();
        }
        // MRU bookkeeping — push the now-active pane to the front (de-dupe
        // against any prior entry for the same id). Capped indirectly:
        // [`force_close_pane`] removes entries when a pane is closed.
        self.pane_mru.retain(|&id_| id_ != id);
        self.pane_mru.insert(0, id);
    }

    /// `:cnext` / `:cprev` / `:cfirst` / `:clast` / `]q` / `[q` —
    /// vim `Ctrl+W f` — split the active leaf horizontally, then open
    /// the file under the cursor in the new pane (vim canonical). Reuses
    /// `open_path_at_cursor` after splitting.
    pub fn split_open_file_under_cursor(&mut self) {
        // Pre-split, then route through the existing path-at-cursor logic.
        self.split_active(crate::layout::SplitDir::Vertical);
        self.open_path_at_cursor();
    }

    /// vim `Ctrl+W n` — open a fresh scratch buffer in a horizontal
    /// split below the active leaf.
    pub fn split_new_scratch(&mut self) {
        self.split_active(crate::layout::SplitDir::Vertical);
        let buf = crate::buffer::Buffer::scratch(&self.config);
        self.panes.push(Pane::Editor(buf));
        let new_id = self.panes.len() - 1;
        self.reveal_pane(new_id);
    }

    /// Open `path` in the focused leaf as a pinned tab. If it's already an
    /// open buffer it's revealed/refocused; otherwise a new buffer is
    /// opened. The buffer the focused leaf was showing stays open as a
    /// background tab.
    ///
    /// This is the default — explicit-open semantics. Use
    /// [`Self::open_path_preview`] from the tree-click handler (and only
    /// there) when you want VS Code's preview-tab behavior in standard
    /// input style.
    pub fn open_path(&mut self, path: &Path) {
        self.open_path_inner(path, false, false);
    }

    /// Like [`Self::open_path`] but forces the raw-editor pane —
    /// bypasses the extension-based auto-routing to MdPreview /
    /// Request / image viewer. `:e <path>` and `:edit <path>` route
    /// here so vim-style callers get the raw text every time
    /// (R7 vscode-mouse SEV-2 F5 2026-08-09 — user typed
    /// `:e mnml_state.md` expecting to edit, got MdPreview instead).
    /// Tree-clicks and picker-opens keep the auto-routing.
    pub fn open_path_force_editor(&mut self, path: &Path) {
        self.open_path_inner(path, false, true);
    }

    /// Open `path` from a tree-click. In **standard** input style this
    /// is the preview-tab gesture: the buffer is marked
    /// `is_preview = true` and clicking a *different* file in the tree
    /// replaces the preview slot rather than adding a new tab. First
    /// edit promotes it to a regular pinned tab.
    ///
    /// In **vim** input style this behaves identically to
    /// [`Self::open_path`] (every file is its own tab).
    ///
    /// Two callers only: the tree-click handler in `ui::tree_view`
    /// (routed via `tui.rs`), and the Files pane's `p` preview
    /// (`App::files_pane_preview`) — added #files item 4, because that is
    /// the same gesture: "show me this, I am still browsing". Every other
    /// caller — `:edit`, picker dispatch, grep hits, definition jumps,
    /// session restore — wants pinned semantics.
    pub fn open_path_preview(&mut self, path: &Path) {
        self.open_path_inner(path, true, false);
    }

    fn open_path_inner(&mut self, path: &Path, preview: bool, force_editor: bool) {
        // canonicalize() requires the file to exist; for a vim-style
        // `:e <newfile>` we want an absolute path anyway so the
        // first save lands where the user expects (not relative to
        // mnml's cwd). Fall back to "canonicalize the parent, append
        // basename" when canonicalize fails on the full path.
        let path = path.canonicalize().unwrap_or_else(|_| {
            if let (Some(parent), Some(base)) = (path.parent(), path.file_name()) {
                let parent_abs = parent
                    .canonicalize()
                    .unwrap_or_else(|_| parent.to_path_buf());
                parent_abs.join(base)
            } else {
                path.to_path_buf()
            }
        });
        // Image files get their own viewer pane instead of being loaded as
        // a text buffer (the binary contents would render as gibberish).
        // R7 vscode-mouse SEV-2 F5 2026-08-09 — `force_editor` (vim's
        // `:e`) skips these auto-routings so the raw editor opens even
        // for image / markdown / .http files.
        if !force_editor && is_image_extension(&path) {
            // Carry the preview intent, as the markdown branch does.
            let as_preview = preview && self.config.editor.input_style == "standard";
            self.open_image_pane_opts(&path, as_preview);
            return;
        }
        // qa-feature 2026-07-02 — markdown files open as a rendered
        // MdPreview pane by default (Obsidian-style "reading mode
        // first"). Click the `✏ Edit` chip in the preview's banner to
        // swap to raw editing. Preview-mode opens from tree clicks pass
        // preview=true; permanent opens (:edit, picker, grep, etc.)
        // pass preview=false — but the display style (rendered vs.
        // raw) is the same either way for markdown UNLESS the caller
        // is vim's `:e` (force_editor=true), which opens raw.
        if !force_editor && self.config.ui.markdown_opens_rendered && is_markdown_path(&path) {
            // Carry the preview intent. It used to be dropped here, so a
            // markdown file opened from the tree was ALWAYS a permanent
            // tab — never italic, never replaced.
            let as_preview = preview && self.config.editor.input_style == "standard";
            self.open_md_preview_for_path_opts(path.clone(), None, true, as_preview);
            return;
        }
        // #polish 2026-07-06 — `.http` / `.curl` / `.rest` open as
        // Request pane by default (parses the file, populates the
        // Request pane form fields, sets source_path so Ctrl+S
        // writes back). The raw text view is still one right-click
        // away via "Open as text" (or the "raw" chip in the
        // Request pane top bar) — see `open_path_as_editor`.
        if !force_editor
            && let Some(ext) = path.extension().and_then(|s| s.to_str())
            && matches!(ext, "http" | "curl" | "rest")
        {
            self.open_request_pane_from_file(&path);
            return;
        }
        // Push the *current* position onto the back-stack before navigating
        // (browser-style). Skip when the active editor is already on this
        // exact file — that'd just be churn. Clears the forward stack so
        // Alt+Right doesn't span unrelated trails.
        if let Some(here) = self.current_nav_point()
            && here.path != path
        {
            self.push_nav_back(here);
            self.nav_forward.clear();
        }
        // Bump the recent list — this happens whether the buffer was already
        // open or is freshly created (a re-focus is still a "recent use").
        self.note_recent_file(&path);
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            // Pin-promotion: a non-preview open (`preview = false`) on a
            // file that's currently shown as a preview pane CLEARS the
            // preview flag — so a tree double-click on a previewed file
            // turns it into a permanent tab. vscode-mouse-2026-06-10
            // SEV-2 #5.
            if !preview
                && let Some(Pane::Editor(b)) = self.panes.get_mut(i)
                && b.is_preview
            {
                b.is_preview = false;
            }
            self.reveal_pane(i);
            return;
        }
        // (Pane kind is picked by extension — only `Editor` exists in P0; `.http`
        // etc. route to `Pane::Request` once that track lands.)
        // Use open_or_new_empty so `:e <newfile>` creates an
        // in-memory dirty buffer instead of toasting "no such file"
        // — vim semantics. The first save writes the file.
        match Buffer::open_or_new_empty(&path, &self.config) {
            Ok(mut buf) => {
                // .editorconfig overrides the per-buffer settings (tab
                // width, trailing newline, trim ws). Closer-to-file wins.
                buf.apply_editorconfig(&self.workspace);
                buf.input.set_ex_history(self.ex_history.clone());
                // Restore the cursor + scroll from the last time we had this
                // file open (if anywhere in `file_cursors`); harmless when the
                // saved cursor doesn't fit the new file text.
                if let Some(&(cursor_byte, scroll)) = self.file_cursors.get(&path) {
                    let (row, col) = byte_to_row_col(buf.editor.text(), cursor_byte);
                    buf.editor.place_cursor(row, col);
                    buf.scroll = scroll;
                }
                // #polish 2026-07-06 — restore folds captured last close.
                // Out-of-range pairs get dropped (file may have shrunk
                // between sessions or since the last close).
                if let Some(folds) = self.file_folds.get(&path) {
                    let line_count = buf.editor.line_count();
                    for &(start, end) in folds {
                        if end >= start && start < line_count && end < line_count {
                            buf.folds.insert(start, end);
                        }
                    }
                }
                // Persistent undo — restore the editor's undo+redo stacks if
                // a matching `<workspace>/.mnml/undo/<hash>.json` exists. The
                // helper bails when the file's hash has drifted (file changed
                // outside mnml), so the worst case is "no history."
                let undo_path = crate::editor::undo_path_for(&self.workspace, &path);
                crate::editor::load_history_from(&mut buf.editor, &undo_path);
                let text = buf.editor.text().to_string();
                // VS Code preview-mode: when this call is a tree-click
                // (`preview = true`) AND input_style is `standard`, the
                // buffer opens as `is_preview = true` and *replaces*
                // any existing preview pane's buffer instead of opening
                // a new tab next to it. The first edit promotes it (set
                // is_preview = false); a double-click in the tree also
                // pins it immediately. Vim users skip the lookup
                // entirely — every file gets its own buffer regardless.
                // Explicit opens (`:edit`, picker, grep, etc.) call
                // `open_path` (preview = false) and never engage this.
                let is_standard = self.config.editor.input_style == "standard";
                let preview_active = preview && is_standard;
                // Preview-replacement is scoped to the *active layout* — a
                // preview tab in another tab page is not the target. Also
                // requires the active leaf itself to point at a preview
                // (so clicking a file from the tree in an empty new tab
                // opens fresh instead of stealing from another tab).
                let preview_idx = if preview_active {
                    self.active.filter(|&id| {
                        self.layout().contains(id)
                            && matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.is_preview)
                    })
                } else {
                    None
                };
                buf.is_preview = preview_active;
                let new_id = if let Some(idx) = preview_idx {
                    // Tell the LSP the old file is closing before we
                    // replace it.
                    if let Some(Pane::Editor(old)) = self.panes.get(idx)
                        && let Some(old_path) = old.path.clone()
                    {
                        self.lsp.did_close(&old_path);
                    }
                    self.panes[idx] = Pane::Editor(buf);
                    idx
                } else {
                    self.panes.push(Pane::Editor(buf));
                    self.panes.len() - 1
                };
                self.reveal_pane(new_id);
                self.lsp.did_open(&path, &text);
                // Initial inlay-hint / code-lens / document-link requests —
                // refreshed on save thereafter.
                let line_count = text.lines().count().max(1) as u32;
                self.lsp.inlay_hint(&path, line_count);
                self.lsp.code_lens(&path);
                self.lsp.document_link(&path);
                self.lsp.document_color(&path);
                let viewport = self.semantic_tokens_viewport_for(&path);
                self.lsp.semantic_tokens(&path, line_count, viewport);
                if viewport.is_some()
                    && let Some(b) = self.panes.iter_mut().find_map(|p| match p {
                        Pane::Editor(b) if b.path.as_deref() == Some(&path) => Some(b),
                        _ => None,
                    })
                {
                    b.last_semantic_viewport = viewport;
                }
                // Auto-open MD preview alongside, if enabled and not yet open.
                // Passive (focus stays on the editor we just opened).
                if self.config.ui.auto_md_preview && is_markdown_path(&path) {
                    self.open_md_preview_for_path(path.clone(), Some(new_id), false);
                }
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
        // Shift PaneIds in EVERY tab's layout, not just the active one — a
        // pane removed from `app.panes` re-indexes references across all
        // tabs that hold leaves with id > removed.
        for layout in &mut self.layouts {
            layout.shift_after(removed);
        }
        // The closed-tab stack holds layouts referencing the same PaneId
        // space; keep them aligned so `tab.reopen` doesn't restore a tab
        // whose leaves point at the wrong panes.
        for layout in &mut self.closed_tab_layouts {
            layout.shift_after(removed);
        }
        // Same shift for each tab's last-focused slot.
        for slot in &mut self.tab_actives {
            *slot = match *slot {
                Some(a) if a == removed => None,
                Some(a) if a > removed => Some(a - 1),
                other => other,
            };
        }
        self.active = self
            .active
            .map(|a| if a > removed { a - 1 } else { a })
            .filter(|_| !self.panes.is_empty());
        // Same shift for `last_active` (Ctrl+Tab target). Drop it when the
        // pane it pointed at is the one being removed.
        self.last_active = self.last_active.and_then(|a| {
            if a == removed {
                None
            } else if a > removed {
                Some(a - 1)
            } else {
                Some(a)
            }
        });
        // MRU: drop the removed pane's entry, shift higher ids down.
        self.pane_mru.retain(|&id| id != removed);
        for id in self.pane_mru.iter_mut() {
            if *id > removed {
                *id -= 1;
            }
        }
        // #1209 f/u (pre-push review) — the per-leaf tab-scroll maps
        // carry PaneIds too and were missed when they landed. Keys are
        // a leaf's FIRST tab id; `leaf_tab_last_active` also stores a
        // PaneId as its VALUE, so both halves need the shift.
        //
        // This matters because ids are REUSED: `panes.remove` compacts
        // the vec, so a later pane inherits the departed one's number.
        // Without the shift, a stale offset silently re-attaches to an
        // unrelated leaf that happens to reuse the id — clamped, so it
        // wouldn't panic, it would just scroll the wrong strip. The
        // map would also grow forever across open/close churn.
        self.leaf_tab_scroll = self
            .leaf_tab_scroll
            .drain()
            .filter(|(k, _)| *k != removed)
            .map(|(k, v)| (if k > removed { k - 1 } else { k }, v))
            .collect();
        self.leaf_tab_last_active = self
            .leaf_tab_last_active
            .drain()
            .filter(|(k, v)| *k != removed && *v != removed)
            .map(|(k, v)| {
                (
                    if k > removed { k - 1 } else { k },
                    if v > removed { v - 1 } else { v },
                )
            })
            .collect();
        // crash-investigator 2026-06-28 SEV-1 #1: right_panel_panes
        // also carries PaneIds and needs the same drop + shift. Without
        // it, closing a pane with a lower index than a hosted right-
        // panel pane left a stale id in the Vec, which the click /
        // hover paths then dereferenced into the wrong (or out-of-
        // bounds) app.panes slot.
        self.right_panel_panes.retain(|&id| id != removed);
        for id in self.right_panel_panes.iter_mut() {
            if *id > removed {
                *id -= 1;
            }
        }
        // Clamp the active idx to the (possibly shrunk) list length.
        if !self.right_panel_panes.is_empty()
            && self.right_panel_active_idx >= self.right_panel_panes.len()
        {
            self.right_panel_active_idx = self.right_panel_panes.len() - 1;
        }
        // Defensive: every other field that carries a PaneId across
        // events MUST get the same shift, or a follow-up event reads
        // a stale id and indexes into `panes` at a wrong (or now-
        // missing) slot. The 2026-06-07 SEV-1 hunt finding "silent
        // exit on multi-tab + split + middle-click" reproduces here:
        // user starts a drag-reorder (bufferline_drag_tab = Some(N)),
        // middle-clicks another tab to close, the close shifts panes,
        // and the next render reads bufferline_drag_tab and panics on
        // a stale id. Same hazard for drag_select, close_prompt, and
        // dragging_scrollbar.
        let shift_opt = |slot: &mut Option<PaneId>| match *slot {
            Some(a) if a == removed => *slot = None,
            Some(a) if a > removed => *slot = Some(a - 1),
            _ => {}
        };
        shift_opt(&mut self.rects.bufferline_drag_tab);
        shift_opt(&mut self.close_prompt);
        match self.drag_select {
            Some((a, _, _, _)) if a == removed => self.drag_select = None,
            Some((a, r, c, armed)) if a > removed => self.drag_select = Some((a - 1, r, c, armed)),
            _ => {}
        }
        if let Some(mut hit) = self.dragging_scrollbar {
            if hit.pane_id == removed {
                self.dragging_scrollbar = None;
            } else if hit.pane_id > removed {
                hit.pane_id -= 1;
                self.dragging_scrollbar = Some(hit);
            }
        }
        // Mouse-hover state: same shift-or-drop pattern as drag_select
        // above. The previous version wiped on `>= removed` which also
        // cancelled an in-progress hover timer on an UNRELATED open
        // pane (e.g. hovering pane 3, closing pane 1, hover state on
        // pane 3 evaporated and LSP-hover had to restart its 600ms
        // debounce). Code-review SEV-2 W-1, 2026-06-08.
        match self.mouse_hover_at {
            Some((a, _, _, _)) if a == removed => self.mouse_hover_at = None,
            Some((a, r, c, t)) if a > removed => self.mouse_hover_at = Some((a - 1, r, c, t)),
            _ => {}
        }
        match self.mouse_hover_fired {
            Some((a, _, _)) if a == removed => self.mouse_hover_fired = None,
            Some((a, r, c)) if a > removed => self.mouse_hover_fired = Some((a - 1, r, c)),
            _ => {}
        }
    }

    /// Empty-state H/V split entry point — used when no active pane
    /// exists (fresh workspace, all tabs closed) and the user clicks
    /// the split-strip H/V chip. Creates two empty scratch editors
    /// laid out in the requested direction, then focuses the second.
    /// 2026-07-18 — supports the "click H/V with no files loaded"
    /// UX where `split_active`'s "nothing to split" toast used to
    /// fire.
    pub fn open_scratch_split(&mut self, dir: crate::layout::SplitDir) {
        // First scratch — becomes pane 0 in a fresh workspace, or
        // just the next pane_id if some layout state already exists
        // (defensive; the caller only invokes this when active is
        // None).
        let first = crate::buffer::Buffer::scratch(&self.config);
        self.panes.push(Pane::Editor(first));
        let first_id = self.panes.len() - 1;
        self.reveal_pane(first_id);
        // Split it in the requested direction with a second scratch.
        let second = crate::buffer::Buffer::scratch(&self.config);
        let new_id = self.split_leaf_with(first_id, dir, Pane::Editor(second));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// Split the focused leaf, opening a fresh buffer (a re-open of the same file,
    /// or a scratch buffer) in the new half and focusing it.
    pub fn split_active(&mut self, dir: crate::layout::SplitDir) {
        let Some(cur) = self.active else {
            self.toast("nothing to split");
            return;
        };
        // vscode-user SEV-2 — re-reading from disk silently dropped
        // unsaved edits in the source buffer. Warn the user before
        // splitting a dirty buffer so they save first (or accept the
        // divergence). v2 will support live-linked split views; for
        // now this just prevents accidental data loss.
        let source_dirty = matches!(self.panes.get(cur), Some(Pane::Editor(b)) if b.dirty);
        if source_dirty {
            self.toast("split: source has unsaved edits — the new pane reads from disk (Ctrl+S to keep them in sync)");
        }
        // #polish 2026-07-06 — when the source is a Request pane,
        // the new split should also be a Request pane (a fresh
        // blank one). Was: fell through to a scratch editor
        // buffer, which the user reported as unexpected (image
        // showed a `[scratch]` panel next to a live request).
        // Mirrors the shape of `open_new_request_pane` (in
        // src/app/http.rs) — same URL-focused Edit mode + "not
        // sent yet" hint.
        if matches!(self.panes.get(cur), Some(Pane::Request(_))) {
            let request = crate::http::Request {
                method: "GET".to_string(),
                url: String::new(),
                headers: Vec::new(),
                body: None,
                insecure: false,
            };
            let mut rp = crate::request_pane::RequestPane::new(
                None,
                request,
                crate::http::script::Script::default(),
                0,
            );
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.focus = crate::request_pane::EditField::Url;
            rp.state = crate::request_pane::RunState::Failed(
                "not sent yet · press `r` to fire".to_string(),
            );
            let new_id = self.split_leaf_with(cur, dir, Pane::Request(rp));
            self.active = Some(new_id);
            self.focus = Focus::Pane;
            return;
        }
        let path = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.path.clone(),
            Some(Pane::MdPreview(p)) => Some(p.path.clone()),
            _ => None,
        };
        let new_buf = match path {
            Some(p) => {
                let mut b = Buffer::open(&p, &self.config)
                    .unwrap_or_else(|_| Buffer::scratch(&self.config));
                b.apply_editorconfig(&self.workspace);
                b
            }
            None => Buffer::scratch(&self.config),
        };
        let new_id = self.split_leaf_with(cur, dir, Pane::Editor(new_buf));
        self.active = Some(new_id);
        self.focus = Focus::Pane;
    }

    /// #878 step 2 (2026-08-19). Apply the declarative
    /// `[[startup.layout]]` block from config, honoring the boot-time
    /// gate: only fires when the layout is empty AND no panes are
    /// open (i.e. session restore didn't already populate the
    /// workspace). Callers: `main.rs` right after `try_restore_session`.
    /// Idempotent-ish — if a stray call runs after the layout is
    /// non-empty, it no-ops. Not called from headless / demo mode
    /// (both set up their own state before this could fire).
    ///
    /// Semantics: linear chain of splits. First entry lands in the
    /// initial (empty) leaf via `open_path` / `open_pty_dir`. Each
    /// subsequent entry has its `split` direction applied first,
    /// then the pane is opened in the new leaf. Invalid entries
    /// (validated at config-load time) never make it into the list,
    /// so the applier can trust the vec's shape.
    pub fn apply_startup_layout(&mut self) {
        // Boot-time gate: nothing to apply, or session restore already
        // owns the layout.
        if self.config.startup_layout.is_empty() {
            return;
        }
        if !matches!(self.layout(), crate::layout::Layout::Empty) || !self.panes.is_empty() {
            return;
        }
        let entries = self.config.startup_layout.clone();
        for (i, entry) in entries.iter().enumerate() {
            // Direction to split for entries after the first. Validated at
            // config load, but re-check defensively in case config was
            // built programmatically.
            let split_dir = if i == 0 {
                None
            } else {
                match entry.split.as_deref() {
                    Some("right") => Some(crate::layout::SplitDir::Horizontal),
                    Some("down") => Some(crate::layout::SplitDir::Vertical),
                    _ => continue,
                }
            };
            match entry.kind.as_str() {
                "editor" => {
                    let Some(raw) = entry.path.as_deref() else {
                        continue;
                    };
                    let path = crate::app::util::expand_tilde_and_resolve(&self.workspace, raw);
                    // Editor path: split first (creates a scratch pane
                    // in the new leaf), then open_path adds our file as
                    // a tab. The scratch is left in place — cheap enough
                    // (empty buffer) and the user closes it or ignores it.
                    // If step 2 UX tests surface friction, switch to a
                    // dedicated `split_leaf_with(cur, dir, Editor(buf))`
                    // helper — deferring that until we know the shape is
                    // actually painful in practice.
                    if let Some(d) = split_dir {
                        self.split_active(d);
                    }
                    self.open_path(&path);
                }
                "pty" => {
                    let Some(cmd) = entry.cmd.as_deref() else {
                        continue;
                    };
                    // Pty path uses `open_pty_dir` which does its own
                    // split, so we don't call `split_active` first.
                    // For the FIRST entry (i == 0, no split_dir),
                    // default to vertical (below) — matches the shell
                    // convention. For subsequent entries, use the
                    // entry's declared split direction.
                    let dir = split_dir.unwrap_or(crate::layout::SplitDir::Vertical);
                    let mut profile =
                        crate::pty_pane::BinaryProfile::shell(Some(self.workspace.clone()));
                    profile.args = vec!["-c".to_string(), cmd.to_string()];
                    // Label the tab with the command so it's obvious
                    // in the bufferline that this isn't a plain shell.
                    profile.label = cmd.to_string();
                    self.open_pty_dir(profile, dir);
                }
                _ => continue,
            }
        }
    }

    /// Replace `Leaf(leaf)` with `Split{leaf, new-pane}`; returns the new pane id.
    /// The source leaf's background tabs are preserved on the `first` side so
    /// splitting a leaf that held [A,B,C] with A active leaves [A,B,C] on the
    /// left and [new] on the right (rather than dropping B and C, which used
    /// to make them "vanish until the split closed" — 2026-07-06).
    pub(super) fn split_leaf_with(
        &mut self,
        leaf: PaneId,
        dir: crate::layout::SplitDir,
        pane: Pane,
    ) -> PaneId {
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        let source_tabs: Vec<PaneId> = self
            .layout()
            .leaf_containing(leaf)
            .map(|t| t.to_vec())
            .unwrap_or_else(|| vec![leaf]);
        self.layout_mut().replace_leaf(
            leaf,
            Layout::Split {
                dir,
                ratio: 50,
                first: Box::new(Layout::leaf_with_tabs(leaf, source_tabs)),
                second: Box::new(Layout::leaf(new_id)),
            },
        );
        // 2026-07-25 — auto-equalize toggle. When on (`[ui]
        // auto_equalize_splits = true` or via Window menu), any
        // new split rebalances the whole tree so all leaves stay
        // equal-size (33/33/33 for 3, 25×4 for 4, etc.). When off
        // (default), the new pane takes half of its parent leaf
        // — vim / tmux convention. Users on manual-drag-resize
        // workflows don't want their panes snapped back on every
        // open.
        if self.config.ui.auto_equalize_splits {
            self.layout_mut().rebalance_leaves();
        }
        new_id
    }

    /// `term.focus_or_open_shell` — VS Code's `Ctrl+`` shape: if there's
    /// already a terminal pane open, focus it; otherwise open a new shell.
    /// Quicker for "show me the terminal" gestures than always-open-new.
    pub fn focus_or_open_shell(&mut self) {
        if let Some(idx) = self.panes.iter().position(|p| matches!(p, Pane::Pty(_))) {
            self.reveal_pane(idx);
        } else {
            self.open_shell();
        }
    }

    /// `editor.open_at_cursor` (`Ctrl+Shift+O` / vim `gf`) — pull the
    /// "path-like" token under the cursor (e.g. `src/foo.rs:42:7`), resolve
    /// relative to the workspace, open + jump. Toasts when nothing path-like
    /// is under the cursor or the path doesn't exist.
    pub fn open_path_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        let Some((s, e)) = path_token_around(text, cursor) else {
            self.toast("no path under cursor");
            return;
        };
        let token = &text[s..e];
        // Strip trailing punctuation that often clings to a copied path
        // (commas, periods, parens, quotes).
        let token = token.trim_end_matches([',', '.', ')', ']', '\'', '"', ';', ':']);
        let (path_str, line_col): (&str, Option<(usize, usize)>) =
            match parse_path_with_position(token) {
                Some((p, l, c)) => (p, Some((l, c))),
                None => (token, None),
            };
        let path = std::path::Path::new(path_str);
        let abs = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.workspace.join(path)
        };
        if !abs.exists() {
            self.toast(format!("no such path: {path_str}"));
            return;
        }
        if abs.is_dir() {
            // We can't open a dir as a buffer; just toast it as a hint.
            self.toast(format!("(directory) {}", rel_path(&self.workspace, &abs)));
            return;
        }
        self.open_path(&abs);
        if let Some((line, col)) = line_col
            && let Some(b) = self.active_editor_mut()
        {
            b.editor
                .place_cursor(line.saturating_sub(1), col.saturating_sub(1));
        }
    }

    /// `view.equalize_splits` — vim `Ctrl+W =`. Rewrite every
    /// split's ratio so all leaves render at equal size regardless
    /// of tree shape. 2026-07-25 — previously did 50/50 at each
    /// level, which gave 50/25/25 on unbalanced 3-leaf trees;
    /// user's ask "make all 3 equal" is now honored.
    pub fn equalize_splits(&mut self) {
        self.layout_mut().equalize_splits();
    }

    /// `view.toggle_auto_equalize_splits` — flip the config toggle
    /// that auto-rebalances splits on every open / close. Toast
    /// the new state so the user sees the change reflected.
    pub fn toggle_auto_equalize_splits(&mut self) {
        self.config.ui.auto_equalize_splits = !self.config.ui.auto_equalize_splits;
        let msg = if self.config.ui.auto_equalize_splits {
            "auto-equalize splits: ON — new panes will rebalance"
        } else {
            "auto-equalize splits: OFF — panes keep their manual ratios"
        };
        self.toast(msg);
        // Rebalance NOW so flipping the flag on gives immediate
        // visual feedback (matches what the next split would do).
        if self.config.ui.auto_equalize_splits {
            self.layout_mut().rebalance_leaves();
        }
    }

    /// `view.maximize_height` — vim `Ctrl+W _`. Push the active leaf's
    /// share of its enclosing vertical split toward 90% (vim's "max
    /// height"). No-op if there's no vertical split.
    pub fn maximize_split_height(&mut self) {
        let Some(cur) = self.active else { return };
        if !self
            .layout_mut()
            .maximize_split_ratio_for(cur, crate::layout::SplitDir::Vertical)
        {
            self.toast("no vertical split to maximize");
        }
    }

    /// `view.maximize_width` — vim `Ctrl+W |`. Same but for horizontal.
    pub fn maximize_split_width(&mut self) {
        let Some(cur) = self.active else { return };
        if !self
            .layout_mut()
            .maximize_split_ratio_for(cur, crate::layout::SplitDir::Horizontal)
        {
            self.toast("no horizontal split to maximize");
        }
    }

    /// vim `Ctrl+W H/J/K/L` — move the active leaf within its immediate
    /// parent split. `(target_dir, to_second)`:
    ///   H ⇒ (Horizontal, false)  active on the left
    ///   L ⇒ (Horizontal, true)   active on the right
    ///   K ⇒ (Vertical,   false)  active on top
    ///   J ⇒ (Vertical,   true)   active on bottom
    /// Poor-man's version — operates on the immediate parent only (vim's
    /// canonical behavior promotes the leaf to the outermost split).
    pub fn move_active_split_edge(&mut self, dir: crate::layout::SplitDir, to_second: bool) {
        let Some(cur) = self.active else { return };
        if !self.layout_mut().move_active_to(cur, dir, to_second) {
            self.toast("nothing to rearrange");
        }
    }

    /// `view.rotate_splits` — vim `Ctrl+W r`. Swap the two sides of the
    /// smallest split that contains the active leaf.
    pub fn rotate_splits(&mut self) {
        let Some(cur) = self.active else { return };
        if self.layout_mut().swap_siblings_containing(cur) {
            self.toast("rotated splits");
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
        let leaves = self.layout().leaves();
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
            self.layout_mut().set_ratio_at(&path, ratio);
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
        // 2026-08-24 — closing a GitGraph tab is a session-scoped
        // "hide this repo" — record it so re-entering the Git
        // section doesn't spawn it back automatically.
        if let Some(Pane::GitGraph(g)) = self.panes.get(id) {
            self.git_closed_repos.insert(g.workspace.clone());
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
        // #1018 — if this was the zoomed leaf, clear the zoom so we
        // don't render a stale synthetic leaf holding a pane that no
        // longer exists in the layout. Cheap when nothing's zoomed.
        if self.zoomed_leaf == Some(id) {
            self.clear_zoom();
        }
        // Capture the cursor + scroll so a future `open_path` for this file
        // jumps back to where the user was. Done *before* the pane is removed
        // (and only for editor panes — other variants don't have a "position").
        if let Pane::Editor(b) = &self.panes[id]
            && let Some(p) = b.path.clone()
        {
            let cur = b.editor.cursor();
            let scroll = b.scroll;
            let folds: Vec<(usize, usize)> = b.folds.iter().map(|(&s, &e)| (s, e)).collect();
            self.note_file_cursor(&p, cur, scroll);
            self.note_file_folds(&p, folds);
            // Push onto the recently-closed stack so `buffer.reopen` can
            // bring it back. Skip if the file's still open in another pane
            // (closing one of several views of the same file isn't "closed").
            let still_open = self
                .panes
                .iter()
                .enumerate()
                .any(|(i, pane)| i != id && matches!(pane, Pane::Editor(b) if b.is_at(&p)));
            if !still_open {
                self.closed_buffers.push((p.clone(), cur, scroll));
                if self.closed_buffers.len() > CLOSED_BUFFERS_MAX {
                    let drop = self.closed_buffers.len() - CLOSED_BUFFERS_MAX;
                    self.closed_buffers.drain(..drop);
                }
                // #20 — surface the reopen affordance as an undo
                // chip so users see it without having to know the
                // `buffer.reopen` command exists.
                let label = p
                    .file_name()
                    .and_then(|s| s.to_str())
                    .map(|s| format!("closed {s}"))
                    .unwrap_or_else(|| "closed buffer".to_string());
                self.set_pending_undo(
                    label,
                    crate::app::UndoAction::ReopenClosedBuffer {
                        path: p,
                        cursor: cur,
                        scroll,
                    },
                );
            }
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
            | Pane::Browser(_)
            | Pane::Diagnostics(_)
            | Pane::Grep(_)
            | Pane::Flaky(_)
            | Pane::Outline(_)
            | Pane::Files(_)
            | Pane::Quickfix(_)
            | Pane::CmdlineHistory(_)
            | Pane::Cheatsheet(_)
            | Pane::Debug(_)
            | Pane::DapRepl(_)
            | Pane::Image(_) => (None, None),
            Pane::ClaudeAgents(_) => (None, None),
            Pane::Websocket(_) => (None, None),
            Pane::SpendReport(_) => (None, None),
            Pane::Mount(_) => (None, None),
            Pane::CloudAgentRun(_) => (None, None),
            Pane::NewCloudAgentWizard(_) => (None, None),
            Pane::NewCloudRunWizard(_) => (None, None),
            Pane::IntegrationDetail(_) => (None, None),
            Pane::ClaudeUsage(_) => (None, None),
            Pane::CodexUsage(_) => (None, None),
        };
        if self.layout().contains(id) {
            self.layout_mut().remove_leaf(id);
            // 2026-07-25 — auto-equalize on close. Without this,
            // closing one of four equal panes leaves the remaining
            // three at 50/25/25 (the surviving Split's ratio was
            // set for its original sibling count). Only fires when
            // the user opted in — matches the split-time behavior.
            if self.config.ui.auto_equalize_splits {
                self.layout_mut().rebalance_leaves();
            }
        }
        if self.active == Some(id) {
            self.active = self.layout().first_leaf();
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

    /// 2026-06-21 — VS Code-style pin toggle. Pins the active
    /// editor tab to the FRONT of the bufferline strip with a 📌
    /// glyph. Pinned tabs are immune to close-all / close-others
    /// and survive across sessions (persisted in session.json).
    /// No-op for non-editor panes.
    pub fn buffer_pin_toggle(&mut self) {
        let Some(i) = self.active else {
            self.toast("no active pane to pin");
            return;
        };
        if let Some(Pane::Editor(b)) = self.panes.get_mut(i) {
            b.is_preview = false;
            b.is_pinned = !b.is_pinned;
            let name = b
                .path
                .as_ref()
                .and_then(|p| p.file_name())
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| "untitled".to_string());
            let verb = if b.is_pinned { "pinned" } else { "unpinned" };
            self.toast(format!("{verb} {name}"));
        } else {
            self.toast("buffer.pin_toggle: not an editor pane");
        }
    }

    /// 2026-06-21 — pin / unpin a specific pane by id. Used by the
    /// bufferline tab right-click context menu.
    pub fn buffer_pin_toggle_at(&mut self, id: usize) {
        if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
            b.is_preview = false;
            b.is_pinned = !b.is_pinned;
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

    /// 2026-06-22 — click on a per-split tab chip. Switches the
    /// leaf whose current active is `leaf_active_was` to show
    /// `new_active` instead. The leaf must already contain
    /// `new_active` in its tabs list (otherwise no-op). Also
    /// updates `App::active` so focus follows the click.
    pub fn switch_split_tab(&mut self, leaf_active_was: PaneId, new_active: PaneId) {
        let Some((active, tabs)) = self.layout_mut().active_leaf_mut(leaf_active_was) else {
            return;
        };
        if !tabs.contains(&new_active) {
            return;
        }
        *active = new_active;
        self.active = Some(new_active);
        self.focus = Focus::Pane;
        self.retarget_outline_to_active();
    }

    /// 2026-06-22 — click × on a per-split tab chip. Removes
    /// `tab_to_close` from the leaf identified by
    /// `leaf_active_was`'s tabs. If the closed tab WAS the active
    /// one, the leaf falls back to another tab (rightward
    /// neighbour preferred). If it was the last tab, the leaf
    /// collapses (Layout::remove_leaf handles that).
    pub fn close_split_tab(&mut self, leaf_active_was: PaneId, tab_to_close: PaneId) {
        // 2026-06-22 — user expectation: clicking × on a tab
        // FULLY closes the pane (removes from app.panes + drops
        // it from every layout). Previously this called
        // `remove_leaf` only, which dropped the pane from the
        // visible tree but left it in `app.panes` — so the
        // global bufferline still showed it as a background tab
        // after the user thought it was closed.
        //
        // `close_pane` handles the dirty-buffer save prompt and
        // delegates to `force_close_pane` (full removal + layout
        // collapse + focus retarget). leaf_active_was is unused
        // — kept in the signature for symmetry with
        // `switch_split_tab` so the click handler doesn't need
        // to know which arg matters.
        let _ = leaf_active_was;
        self.close_pane(tab_to_close);
    }

    /// Switch to tab `idx` (no-op if out of range or already there). Saves
    /// the current focus into the outgoing tab's slot first; restores the
    /// incoming tab's last-focused pane.
    pub fn switch_tab(&mut self, idx: usize) {
        if idx >= self.layouts.len() || idx == self.active_layout {
            return;
        }
        self.remember_active_for_tab();
        self.active_layout = idx;
        let restored = self
            .tab_actives
            .get(idx)
            .copied()
            .unwrap_or(None)
            .or_else(|| self.layout().first_leaf());
        self.active = restored;
        // The active pane might be in a different tab now — clear the leaf
        // that's currently rendered as focused.
        self.focus = if self.active.is_some() {
            Focus::Pane
        } else {
            Focus::Tree
        };
    }

    /// R15 nvchad-user SEV-3 (2026-08-23) — programmatic tab-new for
    /// callers that will populate the tab themselves. Same as
    /// `tab_new(None)` but skips the placeholder scratch buffer — used
    /// by `open_claude_code_new_batch` past the 8-per-screen cap so
    /// the new tab isn't seeded with `[scratch]` alongside the Claudes.
    /// The `tab_new(None)` path stays scratch-seeded for interactive
    /// `:tabnew` (vim convention).
    pub fn tab_new_empty(&mut self) {
        self.remember_active_for_tab();
        let insert_at = self.active_layout + 1;
        self.layouts.insert(insert_at, Layout::Empty);
        self.tab_actives.insert(insert_at, None);
        self.active_layout = insert_at;
        self.active = None;
        // Deliberately no scratch buffer or toast — the immediately-
        // following spawn will populate + toast.
    }

    /// `:tabnew [path]` — open a fresh tab page after the active one.
    /// If `path` is already open in some other tab, switch to that
    /// tab instead of leaving an orphaned empty tab behind (mnml is
    /// file-deduped — one pane per path).
    pub fn tab_new(&mut self, path: Option<&Path>) {
        if let Some(p) = path {
            let canon = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
            if let Some(i) = self
                .panes
                .iter()
                .position(|pane| matches!(pane, Pane::Editor(b) if b.is_at(&canon)))
            {
                // Already open — reveal it (will cross-tab switch if
                // it's in a different tab).
                self.reveal_pane(i);
                return;
            }
        }
        self.remember_active_for_tab();
        let insert_at = self.active_layout + 1;
        self.layouts.insert(insert_at, Layout::Empty);
        self.tab_actives.insert(insert_at, None);
        self.active_layout = insert_at;
        self.active = None;
        if let Some(p) = path {
            // open_path will install a leaf in the (now-empty) active tab.
            self.open_path(p);
        } else {
            // SEV-2 fix 2026-07-07 — was: bare `:tabnew` left focus in
            // the tree, so vim users typing `:tabnew` then `i` got tree
            // navigation instead of insert mode. Open an empty scratch
            // buffer so the tab is immediately usable — matches vim
            // behavior (`:tabnew` opens `[No Name]` and lands on it).
            let scratch = crate::buffer::Buffer::scratch(&self.config);
            self.panes.push(crate::pane::Pane::Editor(scratch));
            let new_id = self.panes.len() - 1;
            *self.layout_mut() = crate::layout::Layout::leaf(new_id);
            self.active = Some(new_id);
            self.focus = Focus::Pane;
        }
        self.toast(format!("tab {}/{}", insert_at + 1, self.layouts.len()));
    }

    /// `:tabnext` / `:tabn` — go to the next tab (wraps).
    pub fn tab_next(&mut self) {
        if self.layouts.len() <= 1 {
            return;
        }
        let next = (self.active_layout + 1) % self.layouts.len();
        self.switch_tab(next);
        self.toast(format!("tab {}/{}", next + 1, self.layouts.len()));
    }

    /// `:tabprev` / `:tabp` — go to the previous tab (wraps).
    pub fn tab_prev(&mut self) {
        if self.layouts.len() <= 1 {
            return;
        }
        let prev = (self.active_layout + self.layouts.len() - 1) % self.layouts.len();
        self.switch_tab(prev);
        self.toast(format!("tab {}/{}", prev + 1, self.layouts.len()));
    }

    /// `:tabfirst` — jump to tab 1.
    pub fn tab_first(&mut self) {
        if self.layouts.len() <= 1 {
            return;
        }
        self.switch_tab(0);
        self.toast(format!("tab 1/{}", self.layouts.len()));
    }

    /// `:tablast` — jump to the last tab.
    pub fn tab_last(&mut self) {
        if self.layouts.len() <= 1 {
            return;
        }
        let last = self.layouts.len() - 1;
        self.switch_tab(last);
        self.toast(format!("tab {}/{}", last + 1, self.layouts.len()));
    }

    /// Close a specific tab page by index. Used by the bufferline's per-tab
    /// `⊗` click — closing a non-active tab leaves focus where it was; closing
    /// the active tab falls back to the new last tab (vim convention).
    pub fn tab_close_at(&mut self, idx: usize) {
        if self.layouts.len() <= 1 {
            self.toast(":tabclose — only one tab open");
            return;
        }
        if idx >= self.layouts.len() {
            return;
        }
        // Save active before any reshuffle.
        self.remember_active_for_tab();
        // Stash the dropped layout for `tab.reopen`. Cap the stack.
        let dropped = self.layouts.remove(idx);
        self.tab_actives.remove(idx);
        self.closed_tab_layouts.push(dropped);
        if self.closed_tab_layouts.len() > CLOSED_TAB_LAYOUTS_MAX {
            self.closed_tab_layouts.remove(0);
        }
        if self.active_layout == idx {
            // Closed the active tab — adopt the new "previous-or-clamp" tab.
            if self.active_layout >= self.layouts.len() {
                self.active_layout = self.layouts.len() - 1;
            }
            let restored = self
                .tab_actives
                .get(self.active_layout)
                .copied()
                .unwrap_or(None)
                .or_else(|| self.layout().first_leaf());
            self.active = restored;
            self.focus = if self.active.is_some() {
                Focus::Pane
            } else {
                Focus::Tree
            };
        } else if self.active_layout > idx {
            // Removed before the active — shift the active index down.
            self.active_layout -= 1;
        }
        self.toast(format!("tab closed · {} remaining", self.layouts.len()));
    }

    /// `:tabclose` / `:tabc` — drop the active tab. Panes that were in its
    /// layout become background buffers (still in `panes`, accessible via the
    /// bufferline / picker). Refuses when there's only one tab open. The
    /// dropped layout is stashed for `tab.reopen`.
    pub fn tab_close(&mut self) {
        self.tab_close_at(self.active_layout);
    }

    /// `:tabonly` / `:tabo` — drop every tab except the active one. Each
    /// dropped layout is stashed for `tab.reopen`.
    pub fn tab_only(&mut self) {
        if self.layouts.len() <= 1 {
            return;
        }
        // crash-investigator F-04 — defensive: clamp active_layout
        // to a valid index in case external state corruption (bad
        // session.json, race vs tab_close) left it past layouts.len().
        if self.active_layout >= self.layouts.len() {
            self.active_layout = 0;
        }
        // Pull the keep-tab aside, push every other layout onto the
        // closed-tab stack, then put the keep-tab back as the only entry.
        let keep_layout = std::mem::replace(&mut self.layouts[self.active_layout], Layout::Empty);
        let keep_active = self.tab_actives[self.active_layout];
        // Drain remaining layouts onto closed-stack (skipping the keep).
        for i in (0..self.layouts.len()).rev() {
            if i == self.active_layout {
                continue;
            }
            let dropped = self.layouts.remove(i);
            self.tab_actives.remove(i);
            self.closed_tab_layouts.push(dropped);
            if self.closed_tab_layouts.len() > CLOSED_TAB_LAYOUTS_MAX {
                self.closed_tab_layouts.remove(0);
            }
        }
        self.layouts = vec![keep_layout];
        self.tab_actives = vec![keep_active];
        self.active_layout = 0;
        self.toast("only tab kept · others dropped");
    }

    /// `view.move_to_new_tab` — vim `Ctrl+W T`. Move the active leaf
    /// out of the current tab's layout into a fresh new tab page.
    /// When the current tab has only one leaf, this is effectively
    /// `tab.new` after the active tab (the leaf moves with it). When
    /// there are siblings, the layout collapses around the removed
    /// leaf via `remove_leaf`.
    pub fn move_to_new_tab(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        // Pluck the leaf out of the current layout. `remove_leaf`
        // collapses splits around it; if it was the only leaf, the
        // layout becomes Empty (an empty tab).
        if self.layout().contains(id) {
            self.layout_mut().remove_leaf(id);
        }
        // The current tab's "active" needs to retarget — pick its
        // new first leaf (or None for the now-Empty single-pane case).
        let new_cur_active = self.layout().first_leaf();
        // Save the soon-to-be-outgoing tab's state.
        if let Some(slot) = self.tab_actives.get_mut(self.active_layout) {
            *slot = new_cur_active;
        }
        // Insert a fresh tab after the active with the moved leaf.
        let insert_at = self.active_layout + 1;
        self.layouts.insert(insert_at, Layout::leaf(id));
        self.tab_actives.insert(insert_at, Some(id));
        self.active_layout = insert_at;
        self.active = Some(id);
        self.focus = Focus::Pane;
        self.toast(format!(
            "moved to tab {}/{}",
            insert_at + 1,
            self.layouts.len()
        ));
    }

    /// `tab.reopen` — pop the most-recently-closed tab off the stack
    /// and insert it after the active tab. Restored leaves still
    /// reference the original PaneIds (which may have shifted via
    /// `remove_pane_storage`); panes that were closed individually
    /// since the tab close get filtered out as the layout is walked.
    pub fn tab_reopen(&mut self) {
        let Some(layout) = self.closed_tab_layouts.pop() else {
            self.toast("no closed tabs to reopen");
            return;
        };
        self.remember_active_for_tab();
        let insert_at = (self.active_layout + 1).min(self.layouts.len());
        let first_leaf = layout.first_leaf();
        self.layouts.insert(insert_at, layout);
        self.tab_actives.insert(insert_at, first_leaf);
        self.active_layout = insert_at;
        self.active = first_leaf;
        self.focus = if self.active.is_some() {
            Focus::Pane
        } else {
            Focus::Tree
        };
        self.toast(format!(
            "tab reopened · {}/{}",
            insert_at + 1,
            self.layouts.len()
        ));
    }

    /// Swap two tabs by index (used by bufferline drag-to-reorder).
    /// Active layout follows the swap so the visible tab doesn't
    /// change.
    pub fn tab_swap(&mut self, a: usize, b: usize) {
        if a == b || a >= self.layouts.len() || b >= self.layouts.len() {
            return;
        }
        self.layouts.swap(a, b);
        self.tab_actives.swap(a, b);
        if self.active_layout == a {
            self.active_layout = b;
        } else if self.active_layout == b {
            self.active_layout = a;
        }
    }

    /// `:tabmove [N]` — move the active tab to position N (1-based).
    /// Accepts: bare (→ last), `0` (→ first), `$` (→ last), `+N` /
    /// `-N` (relative), absolute N.
    pub fn tab_move(&mut self, arg: &str) {
        if self.layouts.len() <= 1 {
            return;
        }
        let cur = self.active_layout;
        let last = self.layouts.len() - 1;
        let target: usize = if arg.is_empty() || arg == "$" {
            last
        } else if let Some(rest) = arg.strip_prefix('+') {
            let n: usize = match rest.parse() {
                Ok(n) => n,
                Err(_) => {
                    self.toast(":tabmove — bad arg");
                    return;
                }
            };
            (cur + n).min(last)
        } else if let Some(rest) = arg.strip_prefix('-') {
            let n: usize = match rest.parse() {
                Ok(n) => n,
                Err(_) => {
                    self.toast(":tabmove — bad arg");
                    return;
                }
            };
            cur.saturating_sub(n)
        } else {
            // 1-based from the user's perspective; 0 also means "first"
            // (vim convention).
            let n: usize = match arg.parse() {
                Ok(n) => n,
                Err(_) => {
                    self.toast(":tabmove — bad arg");
                    return;
                }
            };
            if n == 0 { 0 } else { (n - 1).min(last) }
        };
        if target == cur {
            return;
        }
        // Reshuffle by removing the active and re-inserting at the
        // target index. tab_actives moves with the tab to keep per-
        // tab focus memory aligned.
        let lay = self.layouts.remove(cur);
        let act = self.tab_actives.remove(cur);
        self.layouts.insert(target, lay);
        self.tab_actives.insert(target, act);
        self.active_layout = target;
        self.toast(format!("tab moved → {}/{}", target + 1, self.layouts.len()));
    }

    /// Returns true when any editor pane in the tab page at `idx`
    /// has unsaved changes. Used by the bufferline chip + `:tabs`
    /// summary to flag tabs that need saving.
    pub fn tab_has_dirty_buffer(&self, idx: usize) -> bool {
        let Some(layout) = self.layouts.get(idx) else {
            return false;
        };
        layout
            .leaves()
            .into_iter()
            .any(|id| matches!(self.panes.get(id), Some(Pane::Editor(b)) if b.dirty))
    }

    /// `:tabs` — toast a one-line summary of every tab page.
    pub fn tab_list(&mut self) {
        let n = self.layouts.len();
        if n <= 1 {
            self.toast("1 tab (no others)");
            return;
        }
        let mut parts = Vec::with_capacity(n);
        for i in 0..n {
            let marker = if i == self.active_layout {
                '●'
            } else {
                '○'
            };
            // Headline: last-focused pane in this tab, fallback to
            // first leaf, fallback to "(empty)".
            let head = self
                .tab_actives
                .get(i)
                .copied()
                .unwrap_or(None)
                .or_else(|| self.layouts.get(i)?.first_leaf())
                .and_then(|id| self.panes.get(id))
                .map(|p| p.title())
                .unwrap_or_else(|| "(empty)".to_string());
            // Truncate to keep the toast readable when many tabs.
            let title: String = head.chars().take(20).collect();
            parts.push(format!("{marker}{} {title}", i + 1));
        }
        self.toast(parts.join(" · "));
    }

    /// `:set tab_width=N` — set the global tab width. Affects new buffers,
    /// indent-guide stride, and the `Tab` key in standard mode. Existing
    /// buffers keep whatever width they were opened with (use `:e!` to reload
    /// to the new setting).
    pub fn set_tab_width(&mut self, n: usize) {
        let n = n.clamp(1, 16);
        self.config.editor.tab_width = n;
        self.toast(format!("tab_width: {n} (re-open file to retake)"));
    }

    /// Tab pressed on the `:` cmdline ⇒ cycle through completion candidates.
    /// First Tab swaps in the alphabetically-first match; subsequent Tabs
    /// cycle through the list. Candidates come from
    /// [`crate::app::compute_cmdline_completions_for_app`] — the single
    /// source of truth shared with the floating popup. Cycle state
    /// persists on `App.cmdline_complete_state`; any non-Tab keystroke
    /// that mutates the cmdline drops it (we check `last_shown` vs.
    /// current text on each Tab).
    /// Mouse-click accept: jump to `idx` in the current cmdline
    /// completion popup, rewrite the cmdline with the chosen
    /// match. Companion to `cmdline_tab_complete` (which advances
    /// idx by one). Re-uses the same compute path so behavior
    /// stays consistent.
    pub fn cmdline_popup_accept(&mut self, idx: usize) {
        // Two paths can host the cmdline (see cmdline_popup_view):
        // 1. App.no_pane_cmdline (Ctrl+; from no-pane focus)
        // 2. Active editor's input handler
        let line = if let Some(text) = self.no_pane_cmdline.clone() {
            text
        } else if let Some(text) = self.active_editor_mut().and_then(|b| b.input.cmdline_get()) {
            text
        } else {
            return;
        };
        // `cmdline_get` returns the line WITHOUT the leading `:` —
        // the `:` is added by `pending_display`, and that is the
        // shape `cmdline_popup_list` expects. It also handles the
        // empty-cmdline (recent-commands) case, so accept indexes
        // the same list the popup drew. #1207.
        let Some(state) = crate::app::cmdline_popup_list(self, &line) else {
            return;
        };
        let (head_str, matches): (String, Vec<String>) = (state.head, state.matches);
        if idx >= matches.len() {
            return;
        }
        let new_line = format!("{}{}", head_str, matches[idx]);
        self.cmdline_popup_selected = idx;
        // Write back to whichever path was hosting the cmdline.
        if self.no_pane_cmdline.is_some() {
            self.no_pane_cmdline = Some(new_line.clone());
        } else if let Some(b) = self.active_editor_mut() {
            b.input.cmdline_set(Some(new_line.clone()));
        }
        let stored = crate::app::CmdlineCompleteState {
            head: head_str,
            matches,
            idx,
            last_shown: new_line,
        };
        self.cmdline_complete_state = Some(stored);
    }

    /// Move the cmdline popup selection by `delta` (positive =
    /// down). Used by Up/Down arrow keys when the popup is showing.
    /// Does NOT rewrite the cmdline — only updates the highlight.
    /// (Tab DOES rewrite, by vim convention; Enter accepts.)
    /// No-op when the popup would have <2 matches.
    ///
    /// 2026-06-19 — earlier impl rewrote the cmdline on every Down
    /// keystroke. That re-narrowed the match list to a single
    /// candidate, hiding the popup and looking-like-Enter to the
    /// user. Arrow keys now navigate visually only.
    pub fn cmdline_popup_move(&mut self, delta: isize) {
        let line = if let Some(text) = self.no_pane_cmdline.clone() {
            text
        } else if let Some(text) = self.active_editor_mut().and_then(|b| b.input.cmdline_get()) {
            text
        } else {
            return;
        };
        // #1207 — must be the list the popup DREW, not the raw
        // completer: on an empty cmdline the completer returns the
        // whole registry while the popup shows recent commands.
        let Some(state) = crate::app::cmdline_popup_list(self, &line) else {
            return;
        };
        if state.matches.len() < 2 {
            return;
        }
        let n = state.matches.len() as isize;
        let cur = self.cmdline_popup_selected.min(state.matches.len() - 1) as isize;
        // Wrap on single-step (delta = ±1) for the familiar
        // Tab-cycle feel; clamp on multi-step (PageUp/PageDown)
        // so the user lands at the boundary, not wraps past it.
        let new_idx = if delta.abs() == 1 {
            ((cur + delta).rem_euclid(n)) as usize
        } else {
            (cur + delta).clamp(0, n - 1) as usize
        };
        self.cmdline_popup_selected = new_idx;
        // Track last_shown as the CURRENT typed line so the
        // popup view's reset-on-type check doesn't fire next
        // frame (line hasn't actually changed — just the
        // selected index in the popup).
        let mut stored = state;
        stored.idx = new_idx;
        stored.last_shown = line;
        self.cmdline_complete_state = Some(stored);
    }

    /// Rewrite the cmdline to whatever is currently highlighted
    /// in the popup. Companion to `cmdline_popup_is_showing` —
    /// Enter handlers call these in pair so the user can type a
    /// prefix and hit Enter without manually Tab'ing to complete.
    pub fn cmdline_popup_accept_current(&mut self) {
        let idx = self.cmdline_popup_selected;
        self.cmdline_popup_accept(idx);
    }

    /// Jump the cmdline popup highlight to a specific index
    /// (clamped). Used by Home (idx=0) and End (idx=usize::MAX,
    /// clamps to last).
    pub fn cmdline_popup_move_to(&mut self, idx: usize) {
        let line = if let Some(text) = self.no_pane_cmdline.clone() {
            text
        } else if let Some(text) = self.active_editor_mut().and_then(|b| b.input.cmdline_get()) {
            text
        } else {
            return;
        };
        // #1207 — same source of truth as the view (see
        // cmdline_popup_move).
        let Some(state) = crate::app::cmdline_popup_list(self, &line) else {
            return;
        };
        if state.matches.len() < 2 {
            return;
        }
        self.cmdline_popup_selected = idx.min(state.matches.len() - 1);
        let mut stored = state;
        stored.idx = self.cmdline_popup_selected;
        stored.last_shown = line;
        self.cmdline_complete_state = Some(stored);
    }

    /// Returns true when the popup is currently displaying ≥2
    /// matches for the active cmdline. Used by key handlers that
    /// want to gate Up/Down between popup-nav (when showing) and
    /// vim ex-history nav (when not).
    pub fn cmdline_popup_is_showing(&self) -> bool {
        let line = if let Some(text) = self.no_pane_cmdline.clone() {
            text
        } else if let Some(text) = self.active_editor().and_then(|b| b.input.cmdline_get()) {
            text
        } else {
            return false;
        };
        crate::app::cmdline_popup_list(self, &line)
            .map(|s| !s.matches.is_empty())
            .unwrap_or(false)
    }

    /// qa-6th keyboard SEV-2 2026-06-29 — vim `Ctrl+R Ctrl+W`
    /// (insert word under cursor) and `Ctrl+R Ctrl+A` (WORD,
    /// whitespace-delimited). Reads the active editor cursor's
    /// word and inserts it into the cmdline at the caret.
    pub fn cmdline_insert_cursor_word(&mut self, want_big_word: bool) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let text = b.editor.text();
        let cur = b.editor.cursor();
        // Find the bounds of the (b)word containing the cursor.
        let is_keyword = |c: char| -> bool {
            if want_big_word {
                !c.is_whitespace()
            } else {
                c.is_alphanumeric() || c == '_'
            }
        };
        let bytes = text.as_bytes();
        let mut start = cur.min(bytes.len());
        while start > 0 {
            let prev = text[..start].chars().next_back();
            if let Some(c) = prev
                && is_keyword(c)
            {
                start -= c.len_utf8();
            } else {
                break;
            }
        }
        let mut end = cur.min(bytes.len());
        while end < bytes.len() {
            let next = text[end..].chars().next();
            if let Some(c) = next
                && is_keyword(c)
            {
                end += c.len_utf8();
            } else {
                break;
            }
        }
        if start == end {
            return;
        }
        let word = text[start..end].to_string();
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let Some(line) = b.input.cmdline_get() else {
            return;
        };
        // qa-7th code-review W-2 — vim inserts at the caret, not
        // end-of-line. Splice the word at the cmdline caret.
        let caret = b
            .input
            .cmdline_caret()
            .unwrap_or(line.len())
            .min(line.len());
        let mut new_line = String::with_capacity(line.len() + word.len());
        new_line.push_str(&line[..caret]);
        new_line.push_str(&word);
        new_line.push_str(&line[caret..]);
        b.input.cmdline_set(Some(new_line));
        b.input.set_cmdline_caret(caret + word.len());
    }

    /// R7 nvchad-user SEV-2 2026-08-08 — Ctrl+V in the vim `:`
    /// cmdline. Reads the OS clipboard, sanitizes control chars +
    /// newlines (keeps the ex-line single-line), splices at the
    /// caret. Mirrors the App-owned `no_pane_cmdline` Ctrl+V and
    /// the `Event::Paste` bracketed-paste path so all three cmdline
    /// entry surfaces behave identically.
    pub fn cmdline_paste_from_clipboard(&mut self) {
        let raw = self.clipboard.text();
        if raw.is_empty() {
            return;
        }
        let clean: String = raw
            .chars()
            .filter(|c| *c != '\n' && *c != '\r' && (*c as u32) >= 0x20)
            .collect();
        if clean.is_empty() {
            return;
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let Some(line) = b.input.cmdline_get() else {
            return;
        };
        let caret = b
            .input
            .cmdline_caret()
            .unwrap_or(line.len())
            .min(line.len());
        let mut new_line = String::with_capacity(line.len() + clean.len());
        new_line.push_str(&line[..caret]);
        new_line.push_str(&clean);
        new_line.push_str(&line[caret..]);
        b.input.cmdline_set(Some(new_line));
        b.input.set_cmdline_caret(caret + clean.len());
    }

    pub fn cmdline_tab_complete(&mut self) {
        let Some(b) = self.active_editor_mut() else {
            self.cmdline_complete_state = None;
            self.cmdline_popup_selected = 0;
            return;
        };
        let Some(line) = b.input.cmdline_get() else {
            // cmdline is closed — drop any stale cycle state.
            self.cmdline_complete_state = None;
            self.cmdline_popup_selected = 0;
            return;
        };
        // If the user edited the line since the last cycle, drop state.
        if let Some(st) = &self.cmdline_complete_state
            && st.last_shown != line
        {
            self.cmdline_complete_state = None;
        }
        // Compute or advance the cycle.
        let new_state = if let Some(mut st) = self.cmdline_complete_state.take() {
            if st.matches.is_empty() {
                self.cmdline_complete_state = None;
                return;
            }
            st.idx = (st.idx + 1) % st.matches.len();
            st
        } else {
            let Some(state) = compute_cmdline_completions_for_app(self, &line) else {
                return;
            };
            if state.matches.is_empty() {
                return;
            }
            state
        };
        let new_line = format!("{}{}", new_state.head, new_state.matches[new_state.idx]);
        // Stash before-write so `last_shown` can match against the line as
        // the handler reports it on the next Tab.
        let mut stored = new_state;
        stored.last_shown = new_line.clone();
        // Mirror the cycle index into the popup-selected so the
        // floating popup highlights the same row.
        self.cmdline_popup_selected = stored.idx;
        // Write back to the handler.
        if let Some(b) = self.active_editor_mut() {
            b.input.cmdline_set(Some(new_line));
        }
        self.cmdline_complete_state = Some(stored);
    }

    pub fn cycle_focus(&mut self) {
        let was_pane = self.focus == Focus::Pane;
        let has_right_panel = self.right_panel_visible && !self.right_panel_panes.is_empty();
        self.focus = self.focus.next(self.active.is_some(), has_right_panel);
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
        if let Some(pid) = self.active {
            self.focus = Focus::Pane;
            // Reset the unread-bytes counter on the active Pty
            // pane so the sessions panel's bell badge clears.
            if let Some(crate::pane::Pane::Pty(s)) = self.panes.get_mut(pid) {
                s.mark_seen();
            }
        }
    }

    /// Return focus from a docked side panel (Outline / Problems / Grep /
    /// …) to the last-active editor pane if one exists, otherwise fall
    /// back to the file tree. Matches VS Code's Esc-from-panel semantic.
    /// keyboard-round-8 SEV-3 2026-07-12.
    /// keyboard-round-9 SEV-2 2026-07-12 — was checking
    /// `self.active.is_some()` which is trivially true because the
    /// Outline / Problems pane IS the active pane. Result: Esc did
    /// nothing. Look for an EDITOR pane specifically; if none open,
    /// fall back to the tree.
    pub fn focus_pane_or_tree(&mut self) {
        // Find a live editor pane (excluding the side-panel type
        // panes the user is currently escaping from).
        let editor_target = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| matches!(p, Pane::Editor(_)).then_some(i))
            .next();
        if let Some(pid) = editor_target {
            self.active = Some(pid);
            self.focus_pane();
        } else {
            self.focus_tree();
        }
    }

    /// Toggle the file-tree rail in/out entirely (`Ctrl+B`). When the user
    /// hides it while focused there, focus snaps to the active pane.
    pub fn toggle_tree_visibility(&mut self) {
        self.tree_visible = !self.tree_visible;
        if !self.tree_visible && self.focus == Focus::Tree {
            self.focus = if self.active.is_some() {
                Focus::Pane
            } else {
                Focus::Tree
            };
        }
    }

    /// Set the active activity-bar section. Used by both the activity
    /// bar click handler and the `view.activity_*` commands. Clicking
    /// the *active* icon is treated as "I want to make sure it's
    /// showing" — idempotent. Switching INTO Search also focuses its
    /// input box so the user can start typing immediately; switching
    /// OUT of Search blurs the input.
    pub fn set_activity_section(&mut self, section: crate::app::ActivitySection) {
        if !self.tree_visible {
            self.tree_visible = true;
        }
        // #1146 (R10 vscode-keyboard F6, 2026-08-22) — captured
        // BEFORE the reset block below clears any filter-focused
        // flags; used AFTER `active_section = section` to arm the
        // new section's filter for keyboard-only users (VS Code
        // Ctrl+Shift+X shape). Set only on a fresh entry so an
        // idempotent re-click doesn't steal focus from a user
        // already typing on the panel.
        let entering_new_section = self.active_section != section;
        let entering_search = section == crate::app::ActivitySection::Search;
        let leaving_search =
            self.active_section == crate::app::ActivitySection::Search && !entering_search;
        let leaving_git = self.active_section == crate::app::ActivitySection::Git
            && section != crate::app::ActivitySection::Git;
        let entering_git = self.active_section != crate::app::ActivitySection::Git
            && section == crate::app::ActivitySection::Git;
        // Track HTTP entry BEFORE we clobber `active_section` — the
        // "open HttpHome on entry" hook needs to distinguish an
        // idempotent re-click on an already-active HTTP icon (leave
        // the main area alone) from a fresh entry. `leaving_http`
        // is the mirror for the preview-tab cleanup below.
        let entering_http = self.active_section != crate::app::ActivitySection::Http
            && section == crate::app::ActivitySection::Http;
        let leaving_http = self.active_section == crate::app::ActivitySection::Http
            && section != crate::app::ActivitySection::Http;
        // vscode-user-keyboard SEV-2 #1 + vscode-user-mouse SEV-2 +
        // nvchad-user SEV-2 (2026-07-09): switching activity
        // sections must reset any panel filter's focus flag, or
        // the *previous* panel's filter absorb block silently
        // steals the next section's keystrokes. Clear all four
        // symmetrically on every section change; a no-op when
        // none were focused.
        if self.active_section != section {
            self.http_panel_filter_focused = false;
            self.todos_panel_filter_focused = false;
            self.notes_panel_filter_focused = false;
            self.sessions_panel_filter_focused = false;
            // code-reviewer 2026-07-09: also clear Agents +
            // Integrations, which were part of the same bug
            // class but missed in the initial guard-hoist.
            self.agents_panel_filter_focused = false;
            self.integrations_panel_filter_focused = false;
            // 2026-07-10 audit: cloud agents' filter + quick-fire
            // prompt were also missing from this reset — same
            // class as the other 6.
            self.cloud_agents_filter_focused = false;
            self.cloud_run_prompt_focused = false;
            self.git_palette_filter_focused = false;
            // 2026-08-23 — Findings gained a `/` filter row (user
            // ask); clear its focus flag with the sibling panels.
            self.findings_panel_filter_focused = false;
            // Also snap focus back to Tree so `/` (and j/k nav)
            // on the newly-active panel land where the user
            // expects. HTTP auto-opens a Request pane and sets
            // focus = Pane; without this reset, arriving at
            // TODOs/Notes/Sessions from HTTP left `/` typing
            // into the hidden pane.
            self.focus = crate::focus::Focus::Tree;
        }
        self.active_section = section;
        if entering_search {
            self.search_input_focused = true;
        } else if leaving_search {
            self.search_input_focused = false;
        }
        // #1146 (R10 vscode-keyboard F6, 2026-08-22) — VS Code's
        // Ctrl+Shift+X focuses the Extensions view + its search
        // input in one chord. Same shape for every activity chord
        // family that ships a `/` filter: entering the section
        // should arm the filter so the next keystroke lands there
        // without an intermediate click.
        if entering_new_section {
            match section {
                crate::app::ActivitySection::Integrations => {
                    self.integrations_panel_filter_focused = true;
                }
                crate::app::ActivitySection::Sessions => {
                    self.sessions_panel_filter_focused = true;
                }
                crate::app::ActivitySection::Agents => {
                    self.agents_panel_filter_focused = true;
                }
                // R11 vscode-keyboard SEV-2 (2026-08-23) —
                // Http was auto-arming its filter here, but
                // entering the HTTP activity ALSO opens a
                // Request pane (below in this fn) which steals
                // Focus::Pane. The filter flag was set, but
                // typing landed in the pane's URL field instead
                // of `/`. HTTP's "top thing you type" is a URL,
                // not a filter — leave HTTP unarmed so the
                // pane's own focus wins.
                crate::app::ActivitySection::Notes => {
                    self.notes_panel_filter_focused = true;
                }
                crate::app::ActivitySection::Todos => {
                    self.todos_panel_filter_focused = true;
                }
                // 2026-08-24 (user ask) — same auto-arm as its
                // siblings so `/` isn't required to start typing.
                crate::app::ActivitySection::Findings => {
                    self.findings_panel_filter_focused = true;
                }
                crate::app::ActivitySection::CloudAgents => {
                    self.cloud_agents_filter_focused = true;
                }
                _ => {}
            }
        }
        // qa-feature 2026-06-30 — leaving the Git activity section
        // 2026-08-24 — was force-closing every GitGraph pane on
        // leave, which destroyed scroll/expanded/filter state and
        // meant returning to Git re-launched a fresh single-repo
        // view. New behavior: clear the current desktop-tab's
        // layout (git panes stay in `self.panes`) so
        // `open_git_graph` on re-entry can rebuild the multi-repo
        // tab strip and reuse the existing GitGraphPanes by
        // workspace path — state stays intact across the round trip.
        if leaving_git {
            let has_git = self
                .layout()
                .all_panes()
                .into_iter()
                .any(|id| matches!(self.panes.get(id), Some(crate::pane::Pane::GitGraph(_))));
            if has_git {
                // #1229 — restore whatever was on screen before Git took
                // the layout over. This used to unconditionally set
                // `Empty`, so leaving the Git section threw away the
                // user's editor tabs along with the git ones: a section
                // switch silently closed their work.
                //
                // The GitGraph panes themselves stay in `self.panes`, so
                // scroll / expanded / filter state survives the round
                // trip — `open_git_graph` deliberately reuses them. Only
                // their presence in the LAYOUT is scoped to the section.
                match self.pre_git_layout.take() {
                    Some((layout, active)) => {
                        *self.layout_mut() = layout;
                        // The stashed index may have been closed while we
                        // were in Git; fall back to whatever the restored
                        // layout actually contains.
                        let panes_now = self.layout().all_panes();
                        self.active = active
                            .filter(|i| panes_now.contains(i))
                            .or_else(|| panes_now.first().copied());
                    }
                    None => {
                        *self.layout_mut() = crate::layout::Layout::Empty;
                        self.active = None;
                    }
                }
            }
        }
        // 2026-08-24 — entering Git auto-builds the multi-repo tab
        // strip. Fires on ANY entry (mouse rail click, palette
        // `view.activity_git`, startup restore) so the tabs load
        // without the rail-click handler having to know. Redundant
        // rail-click call was removed; palette flow still works
        // because it also calls set_activity_section under the hood.
        if entering_git {
            // #1229 — stash the outgoing layout so leaving Git can put it
            // back. Guarded on the layout not already containing GitGraph
            // panes: without that, a re-entry that somehow lands here
            // would overwrite the real stash with a git-only layout and
            // strand the user's editor tabs permanently.
            let already_git = self
                .layout()
                .all_panes()
                .into_iter()
                .any(|id| matches!(self.panes.get(id), Some(crate::pane::Pane::GitGraph(_))));
            if !already_git {
                self.pre_git_layout = Some((self.layout().clone(), self.active));
            }
            self.open_git_graph();
        }
        // Entering HTTP from another section → land the user
        // directly on a blank form-style Request pane (Postman
        // feel) rather than the HttpHome dashboard. HttpHome
        // shipped as a hub-and-nav idea but in practice the
        // right thing to do when you click HTTP is start typing
        // a request, not stare at a summary.
        //
        // Guarded on:
        // - An active Request pane already exists → leave it
        //   (idempotent re-click on the HTTP icon shouldn't
        //   yank you off your in-progress request).
        // - `open_new_request_pane` spawns the pane in Edit view
        //   with source_path = None, so nothing gets persisted to
        //   disk until the user hits Save-As. Fixes the
        //   scratch-N.http workspace pileup.
        // - 2026-07-09 — the auto-opened pane is a *preview* tab
        //   (like editor tree-click preview). First edit promotes
        //   to a permanent tab; navigating away without editing
        //   closes it (see the "leaving HTTP" cleanup below).
        if entering_http {
            let has_active_request = self
                .active
                .and_then(|i| self.panes.get(i))
                .map(|p| matches!(p, crate::pane::Pane::Request(_)))
                .unwrap_or(false);
            if !has_active_request {
                self.open_new_request_pane();
                if let Some(cur) = self.active
                    && let Some(crate::pane::Pane::Request(rp)) = self.panes.get_mut(cur)
                {
                    rp.is_preview = true;
                }
            }
        }
        // Leaving HTTP → drop any untouched preview Request pane
        // so we don't accumulate scratch tabs the user just glanced
        // at. `is_preview` gets flipped to false on the first edit
        // (see `tui/handlers/pane.rs`), so what remains preview at
        // this point is genuinely unused.
        if leaving_http {
            // 2026-08-24 user ask — close any Request pane that's
            // still a preview OR that's genuinely blank (user
            // typed something then deleted it back to empty; the
            // preview flag doesn't restore itself, so
            // `is_effectively_blank` catches that case). Untouched
            // preview panes stay caught by the first branch;
            // typed-then-cleared panes are the newly-swept case.
            let to_close: Vec<usize> = self
                .panes
                .iter()
                .enumerate()
                .filter_map(|(i, p)| match p {
                    crate::pane::Pane::Request(rp)
                        if rp.is_preview || rp.is_effectively_blank() =>
                    {
                        Some(i)
                    }
                    _ => None,
                })
                .collect();
            let mut to_close = to_close;
            to_close.sort_unstable_by(|a, b| b.cmp(a));
            for pid in to_close {
                self.force_close_pane(pid);
            }
        }
    }

    /// Toggle the workspace "section" inside the rail (the click on the
    /// `> WORKSPACE-NAME` header — VS-Code Explorer style). When expanded,
    /// focus moves into the tree so keyboard nav picks up where it should.
    pub fn toggle_tree_root_expanded(&mut self) {
        self.tree_root_expanded = !self.tree_root_expanded;
        if self.tree_root_expanded {
            self.focus = Focus::Tree;
            self.rail_section = RailSection::Workspace;
        }
    }

    /// Toggle full-screen focus mode — hide everything but the editor (tree
    /// rail, bufferline, statusline gone). Always lands focus on the active
    /// pane when entering so the user can start typing immediately.
    ///
    /// #1096 (2026-08-20) — renamed from `toggle_zen_mode`. The behavior is
    /// unchanged; the label change is discoverability (VS Code users search
    /// for "full screen" / F11).
    pub fn toggle_fullscreen_mode(&mut self) {
        self.fullscreen_mode = !self.fullscreen_mode;
        if self.fullscreen_mode && self.active.is_some() {
            self.focus = Focus::Pane;
        }
    }
}

#[cfg(test)]
mod layout_tests {
    use super::*;
    use std::fs;

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        // vim input_style — these tests exercise layout/split/dedup
        // semantics that pre-date the standard-mode preview-tab UX
        // (where open_path replaces an active preview pane). Force
        // vim mode for unambiguous pane-management behavior.
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    /// #1229 — leaving the Git section used to set the layout to
    /// `Empty`, which threw away the user's EDITOR tabs along with the
    /// git ones. A section switch silently closed their work.
    ///
    /// User's spec: "when leaving git area the git tabs should disappear
    /// until user returns to git view" — the git tabs are scoped to the
    /// section, everything else is not.
    #[test]
    fn leaving_git_restores_the_editor_tabs_it_replaced() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        let editor_panes = app.layout().all_panes();
        assert_eq!(editor_panes.len(), 2, "two editor tabs before Git");

        app.set_activity_section(crate::app::ActivitySection::Git);
        let in_git = app.layout().all_panes();
        assert!(
            in_git
                .iter()
                .any(|&i| matches!(app.panes.get(i), Some(crate::pane::Pane::GitGraph(_)))),
            "entering Git should put a GitGraph pane in the layout"
        );

        app.set_activity_section(crate::app::ActivitySection::Explorer);
        let after = app.layout().all_panes();
        assert_eq!(
            after, editor_panes,
            "leaving Git did not restore the editor tabs it replaced"
        );
        assert!(
            !after
                .iter()
                .any(|&i| matches!(app.panes.get(i), Some(crate::pane::Pane::GitGraph(_)))),
            "git tabs are still in the layout after leaving the Git section"
        );
        assert!(
            app.active.is_some_and(|i| after.contains(&i)),
            "active pane should point into the restored layout"
        );
    }

    /// The other half of the spec — "until user returns". Git state is
    /// kept in `self.panes` across the round trip, so returning must
    /// bring the SAME pane back rather than a fresh one.
    #[test]
    fn returning_to_git_reuses_the_same_pane() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));

        app.set_activity_section(crate::app::ActivitySection::Git);
        let git_ids: Vec<usize> = app
            .layout()
            .all_panes()
            .into_iter()
            .filter(|&i| matches!(app.panes.get(i), Some(crate::pane::Pane::GitGraph(_))))
            .collect();
        assert!(!git_ids.is_empty(), "no git pane after entering Git");

        app.set_activity_section(crate::app::ActivitySection::Explorer);
        app.set_activity_section(crate::app::ActivitySection::Git);

        let git_ids_again: Vec<usize> = app
            .layout()
            .all_panes()
            .into_iter()
            .filter(|&i| matches!(app.panes.get(i), Some(crate::pane::Pane::GitGraph(_))))
            .collect();
        assert_eq!(
            git_ids, git_ids_again,
            "returning to Git built new panes instead of reusing the existing \
             ones — scroll/filter state would be lost on every round trip"
        );
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

    /// Standard-mode fixture for the preview-tab tests below — same as
    /// `app_with_files` but leaves `input_style = "standard"` (the
    /// default) so the preview path is active.
    fn app_with_files_standard() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "alpha").unwrap();
        std::fs::write(d.path().join("b.txt"), "beta").unwrap();
        std::fs::write(d.path().join("c.txt"), "gamma").unwrap();
        let cfg = Config::default();
        assert_eq!(cfg.editor.input_style, "standard");
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    /// `open_path` is the *explicit* open path — pinned in both input
    /// styles. Consecutive `open_path` calls should always grow the
    /// pane list, never replace-in-place, regardless of input style.
    /// Regression coverage for the `:edit foo` then `:edit bar` bug.
    #[test]
    fn open_path_is_pinned_under_standard_input_style() {
        let (d, mut app) = app_with_files_standard();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        app.open_path(&d.path().join("c.txt"));
        // Three explicit opens ⇒ three panes. (The pre-fix behavior
        // collapsed all three into one preview slot.)
        assert_eq!(app.panes.len(), 3);
        for (i, p) in app.panes.iter().enumerate() {
            let Pane::Editor(b) = p else {
                panic!("expected Editor pane at index {i}");
            };
            assert!(
                !b.is_preview,
                "explicit open must not be preview (pane {i})"
            );
        }
    }

    /// `open_path_preview` is the tree-click gesture. Under standard
    /// input style it sets `is_preview = true` and replaces the active
    /// preview slot in place — a single preview pane survives across
    /// multiple tree-clicks.
    #[test]
    fn open_path_preview_replaces_in_place_under_standard() {
        let (d, mut app) = app_with_files_standard();
        app.open_path_preview(&d.path().join("a.txt"));
        app.open_path_preview(&d.path().join("b.txt"));
        app.open_path_preview(&d.path().join("c.txt"));
        // Three preview-opens ⇒ one pane, holding c.txt.
        assert_eq!(app.panes.len(), 1);
        let Some(Pane::Editor(b)) = app.panes.first() else {
            panic!("expected an Editor pane");
        };
        assert!(b.is_preview);
        assert!(
            b.path.as_ref().unwrap().ends_with("c.txt"),
            "expected c.txt, got {:?}",
            b.path
        );
    }

    /// Mixing `open_path_preview` then `open_path` should not delete
    /// the preview — explicit pins are additive. (Edge case: a user
    /// previews a.txt from the tree, then `:edit b.txt`. We want both
    /// open, not b replacing a.)
    #[test]
    fn cmdline_insert_cursor_word_splices_at_caret_not_end() {
        // qa-7th code-review W-2 regression — vim's Ctrl+R Ctrl+W
        // inserts the word under cursor AT THE CMDLINE CARET, not
        // appended to the end. Pre-fix the code did push_str (the
        // comment claimed 'vim appends at end-of-line' which is
        // wrong); the fix splices at caret + updates the caret.
        let (d, mut app) = app_with_files();
        let path = d.path().join("a.txt").canonicalize().unwrap();
        std::fs::write(&path, "alpha beta gamma").unwrap();
        // Force vim mode and open the file.
        app.config.editor.input_style = "vim".to_string();
        app.open_path(&path);
        // Move cursor onto "beta" (col 6).
        let idx = app.active.unwrap();
        if let Some(crate::pane::Pane::Editor(b)) = app.panes.get_mut(idx) {
            b.editor.place_cursor(0, 6);
        }
        // Open the cmdline, type "%s/" + then 'x' + Left ×2 to put
        // the cmdline caret BEFORE the 'x' (caret at byte 3).
        if let Some(crate::pane::Pane::Editor(b)) = app.panes.get_mut(idx) {
            b.input.cmdline_set(Some("%s/x".to_string()));
            b.input.set_cmdline_caret(3);
        }
        // Fire the insert-word command.
        app.cmdline_insert_cursor_word(false);
        let idx = app.active.unwrap();
        if let Some(crate::pane::Pane::Editor(b)) = app.panes.get_mut(idx) {
            let line = b.input.cmdline_get().unwrap();
            assert_eq!(line, "%s/betax", "word spliced at caret, not appended");
            let caret = b.input.cmdline_caret().unwrap();
            assert_eq!(caret, 7, "caret advanced past inserted word");
        }
    }

    #[test]
    fn explicit_open_after_preview_keeps_both() {
        let (d, mut app) = app_with_files_standard();
        app.open_path_preview(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        assert_eq!(app.panes.len(), 2);
    }

    #[test]
    fn session_round_trips_split_layout() {
        let (d, mut app) = app_with_files();
        let a_path = d.path().join("a.txt").canonicalize().unwrap();
        let b_path = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a_path);
        app.split_active(crate::layout::SplitDir::Horizontal);
        app.open_path(&b_path);
        assert!(matches!(app.layout(), Layout::Split { .. }));
        app.save_session_on_quit();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.try_restore_session();
        match app2.layout() {
            Layout::Split { first, second, .. } => {
                let a = app2
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&a_path)))
                    .expect("a.txt should be re-opened");
                let b = app2
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&b_path)))
                    .expect("b.txt should be re-opened");
                assert!(matches!(**first, Layout::Leaf { active: id, .. } if id == a));
                assert!(matches!(**second, Layout::Leaf { active: id, .. } if id == b));
            }
            other => panic!("expected a Split, got {other:?}"),
        }
    }

    #[test]
    fn tab_new_with_existing_path_switches_tabs_not_orphans() {
        // Tab 1 has a.txt. `:tabnew a.txt` should switch back to tab 1,
        // NOT create an orphaned empty tab 2.
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        assert_eq!(app.layouts.len(), 2);
        assert_eq!(app.active_layout, 1);
        // Now from tab 2, try `:tabnew a.txt` (a.txt is in tab 1).
        app.tab_new(Some(&a));
        // Should be back on tab 1 with no orphans.
        assert_eq!(app.layouts.len(), 2, "no orphan tab created");
        assert_eq!(app.active_layout, 0);
    }

    #[test]
    fn tab_has_dirty_buffer_walks_layout() {
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.tab_new(None);
        app.open_path(&b);
        assert!(!app.tab_has_dirty_buffer(0));
        assert!(!app.tab_has_dirty_buffer(1));
        // Dirty tab 0 by editing a.txt.
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        if let Some(Pane::Editor(buf)) = app.panes.get_mut(a_id) {
            buf.dirty = true;
        }
        assert!(app.tab_has_dirty_buffer(0));
        assert!(!app.tab_has_dirty_buffer(1));
    }

    #[test]
    fn move_to_new_tab_pulls_split_out() {
        // 2026-06-22 — multi-tab semantics: `open_path(&b)` after a
        // split now ADDS b as a tab in the focused leaf (instead of
        // replacing the leaf's active pane). So after the setup:
        //   tab 0: Split { Leaf{a,[a]}, Leaf{active=b, tabs=[a-copy,b]} }
        // Moving b to a new tab pulls b out of the right leaf;
        // the right leaf still has a-copy, so the split STAYS.
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.split_active(crate::layout::SplitDir::Horizontal);
        app.open_path(&b);
        assert!(matches!(app.layout(), Layout::Split { .. }));
        let b_id = app.active.unwrap();
        app.move_to_new_tab();
        assert_eq!(app.layouts.len(), 2);
        assert_eq!(app.active_layout, 1);
        assert!(matches!(app.layout(), Layout::Leaf { active: id, .. } if *id == b_id));
        // Tab 0 still has the split (right leaf now single-tab w/
        // a-copy after b moved out).
        assert!(matches!(&app.layouts[0], Layout::Split { .. }));
    }

    #[test]
    fn split_preserves_background_tabs_in_source_leaf() {
        // Regression 2026-07-06 — splitting a leaf that held multiple
        // tabs used to drop every tab except the active one, so
        // background tabs vanished until the split closed and the
        // top bufferline came back. The fix keeps them in the source
        // leaf's tab list.
        let (d, mut app) = app_with_files();
        let a = d.path().join("a.txt").canonicalize().unwrap();
        let b = d.path().join("b.txt").canonicalize().unwrap();
        std::fs::write(d.path().join("c.txt"), "gamma").unwrap();
        let c = d.path().join("c.txt").canonicalize().unwrap();
        app.open_path(&a);
        app.open_path(&b);
        app.open_path(&c);
        // All three panes live in one leaf.
        let Layout::Leaf { tabs, .. } = app.layout() else {
            panic!("expected a single leaf before split");
        };
        assert_eq!(tabs.len(), 3, "sanity: three tabs before split");
        // Focus a (the leftmost tab) and split. Under the old bug the
        // left half would lose b and c; the fix keeps them.
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        app.reveal_pane(a_id);
        app.split_active(crate::layout::SplitDir::Horizontal);
        let Layout::Split { first, second, .. } = app.layout() else {
            panic!("expected split after split_active");
        };
        let Layout::Leaf { active, tabs } = &**first else {
            panic!("expected left leaf");
        };
        assert_eq!(*active, a_id, "left leaf still active on a");
        assert!(
            tabs.contains(&a_id),
            "left leaf must still contain a: {tabs:?}"
        );
        assert_eq!(
            tabs.len(),
            3,
            "left leaf must preserve all three source tabs, got {tabs:?}"
        );
        // Right side is the new split — one fresh pane.
        let Layout::Leaf {
            tabs: right_tabs, ..
        } = &**second
        else {
            panic!("expected right leaf");
        };
        assert_eq!(right_tabs.len(), 1, "right leaf holds only the new pane");
    }

    #[test]
    fn section_switch_clears_all_panel_filter_focused_flags() {
        // vscode-user-mouse + vscode-user-keyboard + nvchad-user
        // SEV-2 regression lock 2026-07-09.  Extended 2026-07-10
        // as more absorb blocks were audited: 9 flags total (HTTP,
        // TODOs, Notes, Sessions, Agents, Integrations, Cloud
        // Agents filter + quick-fire prompt, Git palette filter).
        // Previously any of these could persist across a section
        // switch, silently capturing keystrokes intended for the
        // now-active panel (or a picker / editor).
        //
        // #1146 (R10 vscode-keyboard F6, 2026-08-22) added a
        // deliberate exception: the DESTINATION section's own
        // filter flag is re-armed after the reset so `/` on the
        // new panel lands in its filter without an extra click.
        // Every *other* section's flag still clears.
        let (_d, mut app) = app_with_files();
        app.http_panel_filter_focused = true;
        app.todos_panel_filter_focused = true;
        app.notes_panel_filter_focused = true;
        app.sessions_panel_filter_focused = true;
        app.agents_panel_filter_focused = true;
        app.integrations_panel_filter_focused = true;
        app.cloud_agents_filter_focused = true;
        app.cloud_run_prompt_focused = true;
        app.git_palette_filter_focused = true;
        app.set_activity_section(crate::app::ActivitySection::Todos);
        assert!(!app.http_panel_filter_focused);
        // Todos = destination, re-armed by the F6 auto-arm.
        assert!(app.todos_panel_filter_focused);
        assert!(!app.notes_panel_filter_focused);
        assert!(!app.sessions_panel_filter_focused);
        assert!(!app.agents_panel_filter_focused);
        assert!(!app.integrations_panel_filter_focused);
        assert!(!app.cloud_agents_filter_focused);
        assert!(!app.cloud_run_prompt_focused);
        assert!(!app.git_palette_filter_focused);
        // Focus snapped back to Tree so `/` on the new panel
        // reaches the filter entry gate.
        assert_eq!(app.focus, crate::focus::Focus::Tree);
    }

    #[test]
    fn entering_http_opens_request_pane_as_preview() {
        // 2026-07-09 — user report: activating the HTTP section
        // auto-opens a fresh Request pane; if the user leaves
        // without touching it, the empty tab should disappear.
        let (_d, mut app) = app_with_files();
        app.set_activity_section(crate::app::ActivitySection::Http);
        let opened = app
            .panes
            .iter()
            .any(|p| matches!(p, crate::pane::Pane::Request(rp) if rp.is_preview));
        assert!(opened, "entering HTTP should create a preview Request pane");
    }

    #[test]
    fn leaving_http_drops_untouched_preview_request_pane() {
        let (_d, mut app) = app_with_files();
        let before = app.panes.len();
        app.set_activity_section(crate::app::ActivitySection::Http);
        // A preview Request pane was pushed.
        assert!(app.panes.len() > before);
        app.set_activity_section(crate::app::ActivitySection::Explorer);
        let remaining_preview = app
            .panes
            .iter()
            .filter(|p| matches!(p, crate::pane::Pane::Request(rp) if rp.is_preview))
            .count();
        assert_eq!(remaining_preview, 0, "preview request should be closed");
    }

    #[test]
    fn leaving_http_keeps_promoted_request_pane() {
        // If the user edited the URL, the request stops being a
        // preview — leaving HTTP must NOT close it. Verifies the
        // is_preview + is_effectively_blank guards on the cleanup
        // pass. 2026-08-24 — the second cleanup arm also drops
        // blank panes, so the test simulates a real edit (a URL)
        // instead of just flipping the preview flag on an empty
        // pane; otherwise the blank-pane branch closes it and the
        // "promoted" intent isn't what's being tested.
        let (_d, mut app) = app_with_files();
        app.set_activity_section(crate::app::ActivitySection::Http);
        let promoted = if let Some(cur) = app.active
            && let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur)
        {
            rp.request.url = "https://api.example.com/x".into();
            rp.is_preview = false;
            true
        } else {
            false
        };
        // Without this the `if let` chain can silently no-op and the
        // assertion below passes vacuously.
        assert!(
            promoted,
            "setup: active pane should be the preview Request pane"
        );
        app.set_activity_section(crate::app::ActivitySection::Explorer);
        let promoted_still_alive = app
            .panes
            .iter()
            .any(|p| matches!(p, crate::pane::Pane::Request(_)));
        assert!(
            promoted_still_alive,
            "promoted request should survive section change"
        );
    }

    #[test]
    fn open_path_at_cursor_jumps_to_position() {
        let (_d, mut app) = app_with_files();
        // Make a buffer whose text references another file with `:line:col`.
        let stub = app.workspace.join("ref.txt");
        std::fs::write(&stub, "see a.txt:1:3\n").unwrap();
        app.open_path(&stub);
        // Place the cursor inside the "a.txt:1:3" token.
        if let Some(b) = app.active_editor_mut() {
            // "see a.txt:1:3" — cursor at index of 'a' in "a.txt".
            let pos = b.editor.text().find("a.txt").unwrap();
            let (row, col) = byte_to_row_col(b.editor.text(), pos);
            b.editor.place_cursor(row, col);
        }
        app.open_path_at_cursor();
        // The active buffer is now `a.txt`, cursor at line 1, col 3 → (0, 2).
        let a = app.workspace.join("a.txt");
        assert_eq!(
            app.active_editor().unwrap().path.as_deref(),
            Some(a.as_path())
        );
        assert_eq!(app.active_editor().unwrap().editor.row_col(), (0, 2));
    }

    /// Pre-push review — `remove_pane_storage` must shift the #1209
    /// tab-scroll maps like every other PaneId-carrying field.
    /// `panes.remove` compacts the vec, so ids are REUSED: without
    /// the shift a stale offset silently re-attaches to whichever
    /// leaf later inherits the number.
    #[test]
    fn removing_a_pane_shifts_the_leaf_tab_scroll_maps() {
        let (d, mut app) = app_with_files();
        for n in ["a.txt", "b.txt"] {
            app.open_path(&d.path().join(n));
        }
        // Seed entries either side of the pane about to go: id 0 is
        // removed, id 2 must become id 1.
        app.leaf_tab_scroll.insert(0, 7);
        app.leaf_tab_scroll.insert(2, 9);
        app.leaf_tab_last_active.insert(2, 2);
        app.leaf_tab_last_active.insert(3, 0);

        app.force_close_pane(0);

        assert!(
            !app.leaf_tab_scroll.contains_key(&0),
            "the removed pane's own entry must be dropped"
        );
        assert_eq!(
            app.leaf_tab_scroll.get(&1),
            Some(&9),
            "id 2 should have shifted down to 1, keeping its offset"
        );
        assert_eq!(
            app.leaf_tab_last_active.get(&1),
            Some(&1),
            "both the KEY and the PaneId VALUE need shifting"
        );
        assert!(
            !app.leaf_tab_last_active.contains_key(&3),
            "an entry whose VALUE pointed at the removed pane must go"
        );
    }

    // ── #1207 — cmdline popup nav/accept agree with what's drawn ───

    /// The empty cmdline (`:` with nothing typed, or Ctrl+;) shows
    /// RECENT COMMANDS. The raw completer, given an empty token,
    /// matches `starts_with("")` — i.e. the whole registry. Arrow-nav
    /// used to walk that registry list while the popup drew recent
    /// commands, so the highlight ran off the end of the visible rows
    /// and Enter no-oped. Pin the two together.
    #[test]
    fn empty_cmdline_popup_navigates_recents_not_the_whole_registry() {
        let d = tempfile::tempdir().unwrap();
        let cfg = Config::default();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.recent_commands = vec!["view.settings".into(), "app.quit".into()];
        app.no_pane_cmdline = Some(String::new());

        let shown = crate::app::cmdline_popup_list(&app, "").expect("popup has rows");
        assert_eq!(shown.matches, app.recent_commands, "popup draws recents");

        // The completer on its own would hand back the full registry —
        // this is the divergence the fix closes.
        let raw = crate::app::compute_cmdline_completions_for_app(&app, "")
            .expect("completer returns something for an empty token");
        assert!(
            raw.matches.len() > shown.matches.len(),
            "precondition: the raw completer is much wider than the popup"
        );

        // Down twice from 0 must wrap within the 2 recents, never
        // land on an index only the registry list has.
        app.cmdline_popup_move(1);
        assert_eq!(app.cmdline_popup_selected, 1);
        app.cmdline_popup_move(1);
        assert_eq!(app.cmdline_popup_selected, 0, "wraps inside the drawn list");

        // And accept resolves against the same list, so Enter fires
        // the row the user is looking at instead of no-oping.
        app.cmdline_popup_move(1);
        app.cmdline_popup_accept_current();
        assert_eq!(app.no_pane_cmdline.as_deref(), Some("app.quit"));
    }

    /// The typed-text path must keep working unchanged — it was never
    /// broken, and it shares the new helper.
    #[test]
    fn typed_cmdline_popup_still_navigates_its_matches() {
        let d = tempfile::tempdir().unwrap();
        let cfg = Config::default();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.no_pane_cmdline = Some("view.".into());
        let shown = crate::app::cmdline_popup_list(&app, "view.").expect("matches for `view.`");
        assert!(shown.matches.len() >= 2, "several view.* commands exist");
        app.cmdline_popup_move(1);
        assert_eq!(app.cmdline_popup_selected, 1);
        app.cmdline_popup_accept_current();
        assert_eq!(
            app.no_pane_cmdline.as_deref(),
            Some(shown.matches[1].as_str())
        );
    }

    // ── #1018 — maximize / restore zoom ────────────────────────────

    #[test]
    fn toggle_zoom_no_active_pane_is_noop() {
        // Fresh app has no active pane; the toggle should stay None
        // (not panic, not toggle-into-Some(bogus)). Fires a toast we
        // don't need to inspect here.
        let d = tempfile::tempdir().unwrap();
        let cfg = Config::default();
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        assert_eq!(app.active, None);
        app.toggle_zoom_active_leaf();
        assert_eq!(app.zoomed_leaf, None);
    }

    #[test]
    fn toggle_zoom_flips_on_active_pane() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        let a = app.active.expect("pane a should be active");
        assert_eq!(app.zoomed_leaf, None);
        app.toggle_zoom_active_leaf();
        assert_eq!(app.zoomed_leaf, Some(a));
        app.toggle_zoom_active_leaf();
        assert_eq!(app.zoomed_leaf, None);
    }

    #[test]
    fn effective_layout_paints_only_zoomed_leaf() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        let a = app.active.unwrap();
        app.split_active(crate::layout::SplitDir::Horizontal);
        app.open_path(&d.path().join("b.txt"));
        let b = app.active.unwrap();
        assert_ne!(a, b);
        // Real layout: a Split with both leaves — cloned unchanged.
        let real = app.layout().clone();
        assert!(
            matches!(real, Layout::Split { .. }),
            "expected split after split_active"
        );
        // No zoom: effective mirrors real.
        assert!(matches!(
            app.effective_layout_for_render(),
            Layout::Split { .. }
        ));
        // Zoom leaf containing `b`.
        app.zoomed_leaf = Some(b);
        let zoomed = app.effective_layout_for_render();
        match zoomed {
            Layout::Leaf { active, tabs } => {
                assert_eq!(active, b);
                assert!(tabs.contains(&b));
                assert!(!tabs.contains(&a), "zoom on b's leaf should not surface a");
            }
            _ => panic!("expected synthetic Leaf under zoom"),
        }
    }

    #[test]
    fn closing_zoomed_pane_clears_zoom() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        let a = app.active.unwrap();
        app.zoomed_leaf = Some(a);
        app.force_close_pane(a);
        assert_eq!(
            app.zoomed_leaf, None,
            "closing the zoomed pane must clear zoom"
        );
    }

    #[test]
    fn switching_to_a_different_leafs_button_reassigns_zoom() {
        // Clicking ⛶ in leaf B when leaf A is currently zoomed should
        // switch the zoom to B, not un-zoom entirely. Matches the way
        // clicking any leaf's ⛶ implies "this is what I want big".
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        let a = app.active.unwrap();
        app.split_active(crate::layout::SplitDir::Horizontal);
        app.open_path(&d.path().join("b.txt"));
        let b = app.active.unwrap();
        app.active = Some(a);
        app.toggle_zoom_active_leaf();
        assert_eq!(app.zoomed_leaf, Some(a));
        app.active = Some(b);
        app.toggle_zoom_active_leaf();
        assert_eq!(
            app.zoomed_leaf,
            Some(b),
            "second toggle from a different active leaf should reassign"
        );
    }

    // ── #978 — arbitrary-depth splits ───────────────────────────────

    // ── #878 step 2 — apply_startup_layout ─────────────────────────

    #[test]
    fn apply_startup_layout_no_op_when_empty() {
        let (_d, mut app) = app_with_files();
        // No entries in cfg.startup_layout — should no-op regardless
        // of session state.
        assert!(app.config.startup_layout.is_empty());
        let panes_before = app.panes.len();
        app.apply_startup_layout();
        assert_eq!(app.panes.len(), panes_before);
    }

    #[test]
    fn apply_startup_layout_skips_when_layout_non_empty() {
        // Session restore already populated the layout — the applier
        // must NOT stack panes on top. Simulates "user has a saved
        // session; startup_layout is just the cold-start baseline."
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        assert!(!matches!(app.layout(), crate::layout::Layout::Empty));
        // Populate the config's startup_layout with an entry that
        // would otherwise fire.
        app.config
            .startup_layout
            .push(crate::config::StartupLayoutEntry {
                kind: "editor".to_string(),
                path: Some(d.path().join("b.txt").to_string_lossy().to_string()),
                cmd: None,
                split: None,
                ratio: None,
            });
        let panes_before = app.panes.len();
        app.apply_startup_layout();
        // Existing pane count unchanged — the gate skipped.
        assert_eq!(app.panes.len(), panes_before);
    }

    #[test]
    fn apply_startup_layout_opens_first_editor_entry() {
        let (d, mut app) = app_with_files();
        // Layout is empty at this point (no session, no open files).
        assert!(matches!(app.layout(), crate::layout::Layout::Empty));
        app.config
            .startup_layout
            .push(crate::config::StartupLayoutEntry {
                kind: "editor".to_string(),
                path: Some(d.path().join("a.txt").to_string_lossy().to_string()),
                cmd: None,
                split: None,
                ratio: None,
            });
        app.apply_startup_layout();
        // The file opened → layout is a single-tab leaf, one pane.
        assert!(matches!(app.layout(), crate::layout::Layout::Leaf { .. }));
        assert_eq!(app.panes.len(), 1);
    }

    #[test]
    fn apply_startup_layout_two_editor_entries_produce_a_split() {
        let (d, mut app) = app_with_files();
        app.config
            .startup_layout
            .push(crate::config::StartupLayoutEntry {
                kind: "editor".to_string(),
                path: Some(d.path().join("a.txt").to_string_lossy().to_string()),
                cmd: None,
                split: None,
                ratio: None,
            });
        app.config
            .startup_layout
            .push(crate::config::StartupLayoutEntry {
                kind: "editor".to_string(),
                path: Some(d.path().join("b.txt").to_string_lossy().to_string()),
                cmd: None,
                split: Some("right".to_string()),
                ratio: None,
            });
        app.apply_startup_layout();
        assert!(matches!(
            app.layout(),
            crate::layout::Layout::Split {
                dir: crate::layout::SplitDir::Horizontal,
                ..
            }
        ));
        // Two open files ⇒ ≥2 panes (may be more if split_active
        // opened a scratch buffer alongside).
        assert!(
            app.panes.len() >= 2,
            "expected ≥2 panes after two-entry layout, got {}",
            app.panes.len()
        );
    }

    #[test]
    fn split_active_can_nest_four_levels_deep() {
        // Verifies the "arbitrary depth" promise: repeatedly calling
        // `split_active` from the newly-focused pane recursively wraps
        // the current leaf in a fresh `Layout::Split`, no cap kicks
        // in, and every intermediate leaf remains addressable. `Layout`
        // is genuinely recursive (Split.first / Split.second are both
        // `Box<Layout>`), so this test is more a canary than a fix.
        let (d, mut app) = app_with_files();
        std::fs::write(d.path().join("c.txt"), "gamma").unwrap();
        std::fs::write(d.path().join("d.txt"), "delta").unwrap();
        std::fs::write(d.path().join("e.txt"), "epsilon").unwrap();
        // Start with one file open (1 leaf, 0 splits).
        app.open_path(&d.path().join("a.txt"));
        assert!(matches!(app.layout(), Layout::Leaf { .. }));

        // Split four times, alternating horizontal / vertical so the
        // resulting tree isn't a degenerate spine in one axis.
        for (i, dir) in [
            crate::layout::SplitDir::Horizontal,
            crate::layout::SplitDir::Vertical,
            crate::layout::SplitDir::Horizontal,
            crate::layout::SplitDir::Vertical,
        ]
        .iter()
        .enumerate()
        {
            app.split_active(*dir);
            // Depth after i splits should equal (i+1). Split.depth
            // returns the max recursion depth of the tree.
            assert_eq!(
                app.layout().max_depth(),
                i + 1,
                "after {} split(s), max_depth should be {}",
                i + 1,
                i + 1
            );
        }
        // Final geometry sanity: 5 leaves, 4 splits.
        assert_eq!(app.layout().leaves().len(), 5);
        // compute_rects should produce 5 leaf rects + 4 divider rects
        // without panicking, even at 4-deep nesting.
        let (leaves, dividers) = app.layout().compute_rects(ratatui::layout::Rect {
            x: 0,
            y: 0,
            width: 160,
            height: 40,
        });
        assert_eq!(leaves.len(), 5);
        assert_eq!(dividers.len(), 4);
    }
}

#[cfg(test)]
mod md_preview_tab_tests {
    use crate::app::App;
    use crate::config::Config;
    use crate::pane::Pane;

    fn app_with_md() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "standard".into();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        for n in ["a.md", "b.md", "c.md"] {
            std::fs::write(app.workspace.join(n), format!("# {n}\n")).unwrap();
        }
        (d, app)
    }

    /// USER REPORT — "gif also has same issue as md where once you look
    /// at it is loaded and doesn't disappear as you scroll away."
    ///
    /// Same defect, same cause: images route to `Pane::Image` before the
    /// preview logic runs, and `is_preview` only lived on `Buffer`.
    #[test]
    fn previewing_an_image_makes_a_preview_tab() {
        let (_d, mut app) = app_with_md();
        // A 1x1 PNG is enough — the pane only needs to open.
        let png: [u8; 67] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
            0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
            0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ];
        for n in ["one.png", "two.png"] {
            std::fs::write(app.workspace.join(n), png).unwrap();
        }

        app.open_path_preview(&app.workspace.join("one.png"));
        let is_prev = app.panes.iter().any(|p| match p {
            Pane::Image(ip) => ip.is_preview,
            _ => false,
        });
        assert!(is_prev, "an image preview opened as a permanent tab");

        // ...and the next one replaces it rather than stacking.
        let before = app.panes.len();
        app.open_path_preview(&app.workspace.join("two.png"));
        assert_eq!(
            app.panes.len(),
            before,
            "two image previews left {} tabs",
            app.panes.len()
        );
    }

    /// The rendered-first default is deliberate — raw markdown reads
    /// badly in a terminal — but it used to be UNCONDITIONAL, so there
    /// was no way to turn it off despite a prior report from someone who
    /// wanted the source (see `open_path_force_editor`).
    #[test]
    fn markdown_opens_rendered_by_default() {
        let (_d, mut app) = app_with_md();
        app.open_path(&app.workspace.join("a.md"));
        assert!(
            app.panes.iter().any(|p| matches!(p, Pane::MdPreview(_))),
            "markdown did not open rendered"
        );
    }

    /// ...and the option actually turns it off.
    #[test]
    fn the_option_opens_markdown_as_text() {
        let (_d, mut app) = app_with_md();
        app.config.ui.markdown_opens_rendered = false;
        app.open_path(&app.workspace.join("a.md"));
        assert!(
            app.panes.iter().any(|p| matches!(p, Pane::Editor(_))),
            "markdown_opens_rendered = false still opened a preview"
        );
        assert!(
            !app.panes.iter().any(|p| matches!(p, Pane::MdPreview(_))),
            "opened both"
        );
    }

    /// USER REPORT — End in the tree landed on TODO.md and opened a
    /// PERMANENT tab: "notice its not italic on the tab like it would be
    /// if i just pressed page down a bunch instead of end."
    ///
    /// The cause was not End. Markdown opens as `Pane::MdPreview`, and
    /// `is_preview` only existed on `Buffer` — so the preview intent was
    /// dropped for every `.md` file regardless of which key opened it.
    #[test]
    fn previewing_a_markdown_file_makes_a_preview_tab() {
        let (_d, mut app) = app_with_md();
        app.open_path_preview(&app.workspace.join("a.md"));
        let previewish = app.panes.iter().any(|p| match p {
            Pane::MdPreview(mp) => mp.is_preview,
            _ => false,
        });
        assert!(
            previewish,
            "a markdown preview opened as a permanent tab: {:?}",
            app.panes.iter().map(|p| p.title()).collect::<Vec<_>>()
        );
    }

    /// ...and the next preview REPLACES it rather than stacking, which
    /// is what makes it a preview at all.
    #[test]
    fn a_second_markdown_preview_replaces_the_first() {
        let (_d, mut app) = app_with_md();
        app.open_path_preview(&app.workspace.join("a.md"));
        let after_first = app.panes.len();
        app.open_path_preview(&app.workspace.join("b.md"));
        app.open_path_preview(&app.workspace.join("c.md"));
        assert_eq!(
            app.panes.len(),
            after_first,
            "three markdown previews left {} tabs: {:?}",
            app.panes.len(),
            app.panes.iter().map(|p| p.title()).collect::<Vec<_>>()
        );
        assert!(
            app.panes
                .iter()
                .any(|p| matches!(p, Pane::MdPreview(mp) if mp.path.ends_with("c.md"))),
            "the last preview is not the one showing"
        );
    }

    /// A PERMANENT open (`:e`, the picker, a double-click) must still be
    /// permanent — otherwise the next preview would eat it.
    #[test]
    fn a_permanent_markdown_open_is_not_replaceable() {
        let (_d, mut app) = app_with_md();
        app.open_path(&app.workspace.join("a.md"));
        let replaceable = app.panes.iter().any(|p| match p {
            Pane::MdPreview(mp) => mp.is_preview,
            _ => false,
        });
        assert!(!replaceable, "a permanent open produced a throwaway tab");

        app.open_path_preview(&app.workspace.join("b.md"));
        assert_eq!(
            app.panes.len(),
            2,
            "the preview replaced a permanently-opened tab"
        );
    }
}
