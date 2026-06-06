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
        let mut items = vec![
            MenuItem::new("Close", MenuAction::CloseTab(id)),
            MenuItem::new("Close others", MenuAction::CloseOtherTabs(id)),
            MenuItem::new("Close all", MenuAction::CloseAllTabs),
        ];
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
                "Copy path",
                MenuAction::CopyPath(rel_path(&self.workspace, p)),
            ));
        }
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
        if !matches!(self.panes.get(id), Some(Pane::Pty(_))) {
            return;
        }
        let title = self.panes.get(id).map(Pane::title).unwrap_or_default();
        let items = vec![
            MenuItem::new("Rename…", MenuAction::RenameSession(id)),
            MenuItem::new("Close", MenuAction::CloseTab(id)),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Close every pane (optionally keeping `keep`), skipping dirty editors so
    /// nothing is lost silently — they're kept and counted.
    pub(super) fn close_panes_except(&mut self, keep: Option<PaneId>) {
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
            self.active = Some(id);
        } else if let Some(other_tab) = self
            .layouts
            .iter()
            .enumerate()
            .find_map(|(i, l)| (i != self.active_layout && l.contains(id)).then_some(i))
        {
            // Pane lives in another tab page — switch tabs so the
            // invariant "each pane is in at most one leaf across all
            // tabs" holds. Otherwise set_leaf_pane below would
            // duplicate the leaf reference into the active tab.
            self.remember_active_for_tab();
            self.active_layout = other_tab;
            self.active = Some(id);
        } else if let Some(cur) = self.active {
            self.layout_mut().set_leaf_pane(cur, id);
            self.active = Some(id);
        } else {
            *self.layout_mut() = Layout::Leaf(id);
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
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        // Image files get their own viewer pane instead of being loaded as
        // a text buffer (the binary contents would render as gibberish).
        if is_image_extension(&path) {
            self.open_image_pane(&path);
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
            self.reveal_pane(i);
            return;
        }
        // (Pane kind is picked by extension — only `Editor` exists in P0; `.http`
        // etc. route to `Pane::Request` once that track lands.)
        match Buffer::open(&path, &self.config) {
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
            | Some(Pane::Trace(_))
            | Some(Pane::Browser(_))
            | Some(Pane::Diagnostics(_))
            | Some(Pane::Grep(_))
            | Some(Pane::Flaky(_))
            | Some(Pane::Outline(_))
            | Some(Pane::Quickfix(_))
            | Some(Pane::CmdlineHistory(_))
            | Some(Pane::Cheatsheet(_))
            | Some(Pane::Debug(_))
            | Some(Pane::DapRepl(_))
            | Some(Pane::Image(_))
            | None => None,
            #[cfg(feature = "aws-codebuild")]
            Some(Pane::CodeBuilds(_)) => None,
            #[cfg(feature = "aws-codebuild")]
            Some(Pane::LogTail(_)) => None,
            Some(Pane::BlitHost(_)) => None,
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
                first: Box::new(Layout::Leaf(leaf)),
                second: Box::new(Layout::Leaf(new_id)),
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
                self.closed_buffers.push((p, cur, scroll));
                if self.closed_buffers.len() > CLOSED_BUFFERS_MAX {
                    let drop = self.closed_buffers.len() - CLOSED_BUFFERS_MAX;
                    self.closed_buffers.drain(..drop);
                }
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
            | Pane::Trace(_)
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
            #[cfg(feature = "aws-codebuild")]
            Pane::CodeBuilds(_) => (None, None),
            #[cfg(feature = "aws-codebuild")]
            Pane::LogTail(_) => (None, None),
            Pane::BlitHost(_) => (None, None),
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
        // Pull the keep-tab aside, push every other layout onto the
        // closed-tab stack, then put the keep-tab back as the only entry.
        let keep_layout = std::mem::replace(
            self.layouts.get_mut(self.active_layout).unwrap(),
            Layout::Empty,
        );
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
        self.layouts.insert(insert_at, Layout::Leaf(id));
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
    /// [`crate::input::vim::EX_COMPLETION_NAMES`] for the FIRST word, and
    /// from the workspace filesystem for trailing args of path-accepting
    /// commands (`:e` / `:edit` / `:sp` / `:vsp` / `:tabnew` / `:badd` /
    /// `:saveas` / `:source` / `:r`). Cycle state persists on
    /// `App.cmdline_complete_state`; any non-Tab keystroke that mutates the
    /// cmdline drops it (we check `last_shown` vs. current text on each Tab).
    pub fn cmdline_tab_complete(&mut self) {
        let Some(b) = self.active_editor_mut() else {
            self.cmdline_complete_state = None;
            return;
        };
        let Some(line) = b.input.cmdline_get() else {
            // cmdline is closed — drop any stale cycle state.
            self.cmdline_complete_state = None;
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
        if self.active.is_some() {
            self.focus = Focus::Pane;
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
        self.active_section = section;
        if entering_search {
            self.search_input_focused = true;
        } else if leaving_search {
            self.search_input_focused = false;
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
                assert!(matches!(**first, Layout::Leaf(id) if id == a));
                assert!(matches!(**second, Layout::Leaf(id) if id == b));
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
        // Tab 1 has a.txt + b.txt as a split. Move b.txt to a new
        // tab — tab 1 should collapse to just a.txt, tab 2 should
        // hold b.txt as a single leaf.
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
        assert!(matches!(app.layout(), Layout::Leaf(id) if *id == b_id));
        // Tab 1 collapsed to a single leaf (a.txt).
        let a_id = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(buf) if buf.is_at(&a)))
            .unwrap();
        assert!(matches!(&app.layouts[0], Layout::Leaf(id) if *id == a_id));
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
