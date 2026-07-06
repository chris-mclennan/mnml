//! Pane + layout methods on `App` — open / reveal / close panes,
//! split tree mutators, focus / divider drag / tab pages, zen mode.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move. This is
//! the most cross-coupled subsystem; every other `app/*.rs` reaches
//! these methods via `pub` (mostly) — visibility lifted where
//! `pub(super)` is sufficient.

use super::*;

impl App {
    /// Active tab page's split tree (mutable view).
    pub fn layout_mut(&mut self) -> &mut Layout {
        &mut self.layouts[self.active_layout]
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
        // Claude / Codex / shell tabs can be renamed from here too.
        if matches!(self.panes.get(id), Some(Pane::Pty(_))) {
            items.push(MenuItem::new("Rename…", MenuAction::RenameSession(id)));
        }
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Right-click menu for a tab in a pty pane's own tab strip
    /// (Claude / Codex / shell session): Rename → the session-name
    /// prompt; Close → close that session.
    pub fn open_pty_tab_context_menu(&mut self, id: PaneId, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let is_claude = matches!(
            self.panes.get(id),
            Some(Pane::Pty(s)) if s.profile.session_id.is_some()
                && s.profile.label.starts_with("claude")
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
        self.open_path_inner(path, false);
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
    /// Only the tree-click handler in `ui::tree_view` (routed via
    /// `tui.rs`) should call this. Every other caller — `:edit`, picker
    /// dispatch, grep hits, definition jumps, session restore — wants
    /// pinned semantics.
    pub fn open_path_preview(&mut self, path: &Path) {
        self.open_path_inner(path, true);
    }

    fn open_path_inner(&mut self, path: &Path, preview: bool) {
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
        if is_image_extension(&path) {
            self.open_image_pane(&path);
            return;
        }
        // qa-feature 2026-07-02 — markdown files open as a rendered
        // MdPreview pane by default (Obsidian-style "reading mode
        // first"). Click the `✏ Edit` chip in the preview's banner to
        // swap to raw editing. Preview-mode opens from tree clicks pass
        // preview=true; permanent opens (:edit, picker, grep, etc.)
        // pass preview=false — but the display style (rendered vs.
        // raw) is the same either way for markdown.
        if is_markdown_path(&path) {
            self.open_md_preview_for_path(path.clone(), None, true);
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

    /// Replace `Leaf(leaf)` with `Split{leaf, new-pane}`; returns the new pane id.
    pub(super) fn split_leaf_with(
        &mut self,
        leaf: PaneId,
        dir: crate::layout::SplitDir,
        pane: Pane,
    ) -> PaneId {
        self.panes.push(pane);
        let new_id = self.panes.len() - 1;
        self.layout_mut().replace_leaf(
            leaf,
            Layout::Split {
                dir,
                ratio: 50,
                first: Box::new(Layout::leaf(leaf)),
                second: Box::new(Layout::leaf(new_id)),
            },
        );
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

    /// `view.equalize_splits` — vim `Ctrl+W =`. Reset every split's ratio to
    /// 50/50 so the panes share the screen evenly at every nesting level.
    pub fn equalize_splits(&mut self) {
        self.layout_mut().equalize_splits();
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
        // Capture the cursor + scroll so a future `open_path` for this file
        // jumps back to where the user was. Done *before* the pane is removed
        // (and only for editor panes — other variants don't have a "position").
        if let Pane::Editor(b) = &self.panes[id]
            && let Some(p) = b.path.clone()
        {
            let cur = b.editor.cursor();
            let scroll = b.scroll;
            self.note_file_cursor(&p, cur, scroll);
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
        };
        if self.layout().contains(id) {
            self.layout_mut().remove_leaf(id);
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
            self.focus = Focus::Tree;
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
        // the `:` is added by `pending_display`. Same shape that
        // `compute_cmdline_completions_for_app` expects.
        let Some(state) = compute_cmdline_completions_for_app(self, &line) else {
            return;
        };
        if idx >= state.matches.len() {
            return;
        }
        let new_line = format!("{}{}", state.head, &state.matches[idx]);
        self.cmdline_popup_selected = idx;
        // Write back to whichever path was hosting the cmdline.
        if self.no_pane_cmdline.is_some() {
            self.no_pane_cmdline = Some(new_line.clone());
        } else if let Some(b) = self.active_editor_mut() {
            b.input.cmdline_set(Some(new_line.clone()));
        }
        let mut stored = state;
        stored.idx = idx;
        stored.last_shown = new_line;
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
        let Some(state) = compute_cmdline_completions_for_app(self, &line) else {
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
        let Some(state) = compute_cmdline_completions_for_app(self, &line) else {
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
        if line.trim().is_empty() {
            return false;
        }
        compute_cmdline_completions_for_app(self, &line)
            .map(|s| s.matches.len() >= 2)
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
        let new_line = format!("{}{}", new_state.head, &new_state.matches[new_state.idx]);
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
        if let Some(pid) = self.active {
            self.focus = Focus::Pane;
            // Reset the unread-bytes counter on the active Pty
            // pane so the sessions panel's bell badge clears.
            if let Some(crate::pane::Pane::Pty(s)) = self.panes.get_mut(pid) {
                s.mark_seen();
            }
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
        let entering_search = section == crate::app::ActivitySection::Search;
        let leaving_search =
            self.active_section == crate::app::ActivitySection::Search && !entering_search;
        let leaving_git = self.active_section == crate::app::ActivitySection::Git
            && section != crate::app::ActivitySection::Git;
        // Track HTTP entry BEFORE we clobber `active_section` — the
        // "open HttpHome on entry" hook needs to distinguish an
        // idempotent re-click on an already-active HTTP icon (leave
        // the main area alone) from a fresh entry.
        let entering_http = self.active_section != crate::app::ActivitySection::Http
            && section == crate::app::ActivitySection::Http;
        self.active_section = section;
        if entering_search {
            self.search_input_focused = true;
        } else if leaving_search {
            self.search_input_focused = false;
        }
        // qa-feature 2026-06-30 — leaving the Git activity section
        // auto-closes any open GitGraph panes so the editor area
        // returns to the file the user was working on. The graph
        // is a viewer, tied to the Git section; keeping it open
        // when the user has moved to Explorer/Debug/etc. feels
        // stale. Reopen via the Git icon or :git.graph.
        if leaving_git {
            let to_close: Vec<usize> = self
                .panes
                .iter()
                .enumerate()
                .filter_map(|(i, p)| matches!(p, crate::pane::Pane::GitGraph(_)).then_some(i))
                .collect();
            // Close descending so arena shifts don't invalidate ids.
            let mut to_close = to_close;
            to_close.sort_unstable_by(|a, b| b.cmp(a));
            for pid in to_close {
                self.force_close_pane(pid);
            }
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
        if entering_http {
            let has_active_request = self
                .active
                .and_then(|i| self.panes.get(i))
                .map(|p| matches!(p, crate::pane::Pane::Request(_)))
                .unwrap_or(false);
            if !has_active_request {
                self.open_new_request_pane();
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

    /// Toggle "zen" focus mode — hide everything but the editor (tree rail,
    /// bufferline, statusline gone). Always lands focus on the active pane
    /// when entering so the user can start typing immediately.
    pub fn toggle_zen_mode(&mut self) {
        self.zen_mode = !self.zen_mode;
        if self.zen_mode && self.active.is_some() {
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
}
