//! Bufferline + save/reload methods on `App` — tab splice/swap,
//! next/prev buffer cycling, `:w` / `:w <path>` / `:wa`, on-disk
//! reload with dirty-guard, and the `Ctrl+,` settings and
//! `keymap.edit` open-in-editor entry points.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// Swap two panes' positions in `app.panes`, then walk every tab
    /// page's layout (plus `app.active`) and rewrite leaf references
    /// so they still resolve to the same content after the move. Used
    /// by bufferline drag-reorder to let the user reorder tabs by
    /// click-and-drag.
    /// Splice `src` next to `dst` in the bufferline (drag-reorder
    /// canonical). Uses a series of adjacent swaps so that at the
    /// end, `src` is at the slot immediately BEFORE `dst` (or
    /// immediately after if src > dst — matches the drag direction).
    /// nvchad-round-10 SEV-3 2026-07-11 — was calling
    /// `swap_bufferline_tabs` which literally swapped the two arena
    /// positions, so a drag of `A` onto `B` in `[W X A Y Z B T]`
    /// gave `[W X B Y Z A T]` (swap) instead of `[W X Y Z A B T]`
    /// (splice).
    pub fn splice_bufferline_tabs(&mut self, src: PaneId, dst: PaneId) {
        if src == dst || src >= self.panes.len() || dst >= self.panes.len() {
            return;
        }
        // nvchad-round-10 SEV-3 2026-07-12 — condition was
        // `cur + 1 < dst` (and `cur > dst + 1`), which stopped ONE
        // swap short and left the source adjacent to dst instead of
        // taking dst's slot. VS Code / Chrome / most bufferlines
        // splice-drop: A dropped ON B moves A into B's slot and
        // shifts B out. For [A, B, C] with src=0, dst=2 the persona
        // expects [B, C, A]; the old code produced [B, A, C] (one
        // fewer swap). Loop to `cur < dst` so src actually reaches
        // dst's position.
        let mut cur = src;
        if cur < dst {
            while cur < dst {
                self.swap_bufferline_tabs(cur, cur + 1);
                cur += 1;
            }
        } else {
            while cur > dst {
                self.swap_bufferline_tabs(cur, cur - 1);
                cur -= 1;
            }
        }
    }

    pub fn swap_bufferline_tabs(&mut self, a: PaneId, b: PaneId) {
        if a == b || a >= self.panes.len() || b >= self.panes.len() {
            return;
        }
        self.panes.swap(a, b);
        // Every tab page's layout tree may carry leaf refs to either id.
        for layout in self.layouts.iter_mut() {
            layout.swap_leaf_refs(a, b);
        }
        // `app.active` is a PaneId — if it's one of the swapped ids,
        // flip it so focus follows the moved tab.
        if let Some(active) = self.active {
            self.active = Some(if active == a {
                b
            } else if active == b {
                a
            } else {
                active
            });
        }
        // Per-tab-page actives carry PaneIds too — flip on swap.
        for slot in self.tab_actives.iter_mut() {
            if let Some(pid) = slot {
                if *pid == a {
                    *slot = Some(b);
                } else if *pid == b {
                    *slot = Some(a);
                }
            }
        }
    }

    /// Cycle the focused leaf to the next open buffer (wrapping). A buffer
    /// already visible in another leaf just gets focused there.
    pub fn next_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        // nvchad-user SEV-2 — skip Pty entries when cycling so vim
        // users don't get trapped. crash-investigator F-02 follow-on
        // — if EVERY pane is Pty, the loop exhausts and `next` ends
        // up back at a Pty; no-op rather than misleadingly "moving"
        // to another Pty pane the user just came from.
        // qa-feature 2026-06-30 — also skip GitGraph (viewer, no
        // file semantics) alongside Pty so cycling stays among
        // editable buffers.
        let skip = |p: Option<&Pane>| -> bool {
            matches!(p, Some(Pane::Pty(_)) | Some(Pane::GitGraph(_)))
        };
        let n = self.panes.len();
        let mut next = (cur + 1) % n;
        for _ in 0..n {
            if !skip(self.panes.get(next)) {
                break;
            }
            next = (next + 1) % n;
        }
        if skip(self.panes.get(next)) {
            return;
        }
        self.reveal_pane(next);
    }
    pub fn prev_buffer(&mut self) {
        if self.panes.is_empty() {
            return;
        }
        let cur = self.active.unwrap_or(0);
        let skip = |p: Option<&Pane>| -> bool {
            matches!(p, Some(Pane::Pty(_)) | Some(Pane::GitGraph(_)))
        };
        let n = self.panes.len();
        let mut prev = (cur + n - 1) % n;
        for _ in 0..n {
            if !skip(self.panes.get(prev)) {
                break;
            }
            prev = (prev + n - 1) % n;
        }
        if skip(self.panes.get(prev)) {
            return;
        }
        self.reveal_pane(prev);
    }

    // ── Vim tab pages ─────────────────────────────────────────────────────
    //
    // Each tab page is one independent split tree (`Layout`). Pane storage
    // (`App.panes`) is shared — closing a tab leaves its panes as background
    // buffers (still in the bufferline). `tab_actives` remembers the last-
    // focused pane per tab so switching back lands where you left off.

    /// Save the current focus into the active tab's slot. Call before
    /// switching tabs.
    pub(crate) fn remember_active_for_tab(&mut self) {
        if let Some(slot) = self.tab_actives.get_mut(self.active_layout) {
            *slot = self.active;
        }
    }

    pub fn save_active(&mut self) {
        // Request-pane writeback: `Ctrl+S` over a `Pane::Request` serialises
        // the edited request (URL / method / headers / body) back to its
        // source file as a `curl` command.
        if matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Request(_))
        ) {
            self.save_request_to_source();
            return;
        }
        // willSaveWaitUntil → format-on-save → disk. Each pre-save hook
        // fires its LSP request, stashes a (path, deadline) marker, and
        // chains forward when its reply lands. The deadline catches
        // misbehaving / unresponsive servers so a save can never be
        // gated forever.
        if self.config.editor.will_save_wait_until
            && let Some(b) = self.active_editor()
            && let Some(path) = b.path.clone()
            && self.lsp.will_save_wait_until(&path)
        {
            self.pending_will_save = Some((
                path,
                std::time::Instant::now() + std::time::Duration::from_millis(2000),
            ));
            return;
        }
        self.save_active_after_will_save();
    }

    /// The actual write — extracted so the format-on-save flow can call it
    /// after the LSP reply lands (or after the deadline times out).
    pub fn save_active_now(&mut self) {
        let workspace = self.workspace.clone();
        let saved_path = match self.active_editor_mut() {
            Some(buf) if buf.path.is_some() => {
                let name = buf.display_name();
                match buf.save_to_disk() {
                    Ok(()) => {
                        let p = buf.path.clone();
                        // Persist the undo/redo stack alongside the file so a
                        // close-and-reopen keeps your history.
                        if let Some(ref fp) = p {
                            let undo_path = crate::editor::undo_path_for(&workspace, fp);
                            crate::editor::save_history_to(&buf.editor, &undo_path);
                        }
                        self.toast(format!("saved {name}"));
                        self.git.refresh();
                        // Any open GitGraph pane's WIP virtual row reflects
                        // working-tree state — refresh after the save so a
                        // side-by-side graph+editor split updates live.
                        self.refresh_git_graph_panes();
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
    /// Vim `:w <path>` — write the active editor to `<path>` WITHOUT
    /// repointing the buffer. The tab title, dirty state, and
    /// subsequent bare `:w` target all stay pinned to the original
    /// path. Vim canonical. Use `save_active_as` for the repointing
    /// (`:saveas` / `:file`) semantic. R12 nvchad SEV-3 2026-08-23.
    pub fn write_active_to(&mut self, raw_path: &str) {
        let path = std::path::PathBuf::from(raw_path);
        let abs = if path.is_absolute() {
            path
        } else {
            self.workspace.join(&path)
        };
        if let Some(parent) = abs.parent()
            && !parent.as_os_str().is_empty()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("write: cannot create {}: {e}", parent.display()));
            return;
        }
        let Some(buf) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        if let Err(e) = buf.write_to(&abs) {
            self.toast(format!("write failed: {e}"));
            return;
        }
        // Best-effort: refresh git/tree so the new file shows up. The
        // buffer stays pinned to its original path so no LSP re-open
        // fires (write goes to a different file that we're not editing).
        self.git.refresh();
        self.tree.refresh();
        self.toast(format!("wrote to {}", rel_path(&self.workspace, &abs)));
    }

    /// `:saveas <path>` / `:file <path>` — save the active editor to a
    /// new path AND repoint the buffer at it (relative paths are
    /// resolved against the workspace). Subsequent bare `:w` writes
    /// to the new path. Refreshes git/tree/LSP. Toasts the result.
    pub fn save_active_as(&mut self, raw_path: &str) {
        let path = std::path::PathBuf::from(raw_path);
        let abs = if path.is_absolute() {
            path
        } else {
            self.workspace.join(&path)
        };
        // Make sure the parent dir exists (`:w newdir/foo.rs` shouldn't fail
        // with ENOENT — it's an explicit save, not an accidental write).
        if let Some(parent) = abs.parent()
            && !parent.as_os_str().is_empty()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("save-as: cannot create {}: {e}", parent.display()));
            return;
        }
        let Some(buf) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let prev_path = buf.path.clone();
        if let Err(e) = buf.save_as(abs.clone()) {
            self.toast(format!("save-as failed: {e}"));
            return;
        }
        // Best-effort: refresh subsystems that care about file paths.
        self.git.refresh();
        self.tree.refresh();
        self.refresh_md_previews(&abs);
        self.refresh_blame_for(&abs);
        // LSP: close the old `path` (if any) and open the new one with the
        // current text — the new extension might mean a different server.
        if let Some(p) = prev_path {
            self.lsp.did_close(&p);
        }
        if let Some(b) = self.active_editor() {
            let t = b.editor.text().to_string();
            self.lsp.did_open(&abs, &t);
        }
        self.toast(format!("saved to {}", rel_path(&self.workspace, &abs)));
    }

    /// `file.open_settings` (`Ctrl+,`) — open `~/.config/mnml/config.toml`
    /// (or `$XDG_CONFIG_HOME/mnml/config.toml`) in an editor pane. Creates
    /// the file (+ parent dirs) with a one-line `# mnml config` placeholder
    /// if it doesn't exist yet so the buffer isn't blank.
    pub fn open_settings(&mut self) {
        let Some(path) = crate::config::user_config_path() else {
            self.toast("can't resolve config path (no HOME / XDG_CONFIG_HOME)");
            return;
        };
        if !path.exists() {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&path, "# mnml config\n") {
                self.toast(format!("can't create settings file: {e}"));
                return;
            }
        }
        self.open_path(&path);
    }

    /// `keys.edit` — open `config.toml` and jump the cursor to the
    /// `[keys.standard]` section. If the section doesn't exist yet,
    /// append a commented stub explaining the schema first so the
    /// user has a starting point. The infrastructure to override
    /// chords via `[keys.global]` / `[keys.vim]` / `[keys.standard]`
    /// has existed since the keymap was config-driven; this command
    /// closes the *discoverability* gap (bug-hunt seed #276 from the
    /// VS-Code-keyboard hunt 2026-06-07).
    pub fn open_keys_config(&mut self) {
        let Some(path) = crate::config::user_config_path() else {
            self.toast("can't resolve config path (no HOME / XDG_CONFIG_HOME)");
            return;
        };
        if !path.exists() {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&path, "# mnml config\n") {
                self.toast(format!("can't create settings file: {e}"));
                return;
            }
        }
        // Read the current contents. If `[keys.standard]` is absent,
        // append a commented stub so the user lands on something
        // they can immediately edit (rather than an empty file).
        let mut contents = std::fs::read_to_string(&path).unwrap_or_default();
        let header_missing = !contents.contains("[keys.standard]");
        if header_missing {
            if !contents.is_empty() && !contents.ends_with('\n') {
                contents.push('\n');
            }
            contents.push_str(KEYS_STANDARD_STUB);
            if let Err(e) = std::fs::write(&path, &contents) {
                self.toast(format!("can't append [keys.standard] stub: {e}"));
                return;
            }
        }
        self.open_path(&path);
        // Find the `[keys.standard]` line and place the cursor on
        // the row below the header so the user lands inside the
        // section, ready to type a new binding.
        let target_row = contents
            .lines()
            .position(|l| l.trim() == "[keys.standard]")
            .map(|i| i + 1)
            .unwrap_or(0);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(target_row, 0);
            b.scroll = target_row.saturating_sub(3);
        }
    }

    /// Re-read the active buffer from disk, preserving cursor + scroll. Refuses
    /// when the buffer is dirty unless `force=true` (`:e!` / a "discard then
    /// reload" prompt). Notifies LSP with the new text.
    pub fn reload_active(&mut self, force: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("nothing to reload (scratch buffer)");
            return;
        };
        if b.dirty && !force {
            self.toast("unsaved changes — use :e! to discard");
            return;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                self.toast(format!("reload failed: {e}"));
                return;
            }
        };
        let (row, col, scroll) = match self.active_editor() {
            Some(b) => (b.editor.row_col().0, b.editor.row_col().1, b.scroll),
            None => return,
        };
        let clip = &mut self.clipboard;
        if let Some(b) = self.active.and_then(|i| self.panes.get_mut(i))
            && let Pane::Editor(b) = b
        {
            let end = b.editor.text().len();
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start: 0,
                    end,
                    text,
                }],
                clip,
                0,
            );
            b.editor.place_cursor(row, col);
            b.scroll = scroll;
        }
        if let Some(b) = self.active_editor() {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&path, &t);
        }
        self.toast(format!("reloaded {}", rel_path(&self.workspace, &path)));
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
}
