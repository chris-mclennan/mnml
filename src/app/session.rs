//! Session save / restore — `<workspace>/.mnml/session.json`.
//!
//! `save_session_on_quit` writes open editor buffers + cursors + the
//! per-tab split tree + UI state; `try_restore_session` reads it back
//! on launch and re-opens the buffers + rebuilds the layout.
//!
//! Extracted from `app/mod.rs` (file-split follow-up). Pure
//! non-destructive move; no API change.

use super::*;

impl App {
    /// `[session] restore = true` ⇒ on quit, write the open editor buffers +
    /// their cursors to `<workspace>/.mnml/session.json` so the next launch can
    /// re-open them. Best-effort (errors are swallowed). No-op when restore is
    /// off, or when nothing is open.
    pub fn save_session_on_quit(&self) {
        if !self.config.session.restore {
            return;
        }
        // Save editor buffers in tab order, with PaneId → saved-index lookup
        // for the layout pass. Also fold the currently-open buffers' cursors
        // into `file_cursors` so per-file restore covers them even if the user
        // closes them after relaunch.
        let mut open: Vec<SavedBuffer> = Vec::new();
        let mut pane_to_idx: Vec<Option<usize>> = vec![None; self.panes.len()];
        let mut active: Option<usize> = None;
        let mut merged_cursors = self.file_cursors.clone();
        for (i, p) in self.panes.iter().enumerate() {
            if let Pane::Editor(b) = p
                && let Some(path) = &b.path
            {
                pane_to_idx[i] = Some(open.len());
                if self.active == Some(i) {
                    active = Some(open.len());
                }
                open.push(SavedBuffer {
                    path: path.to_string_lossy().into_owned(),
                    cursor_byte: b.editor.cursor(),
                    scroll: b.scroll,
                    breakpoints: b.breakpoints.clone(),
                    breakpoint_conditions: b.breakpoint_conditions.clone(),
                    breakpoint_hit_conditions: b.breakpoint_hit_conditions.clone(),
                });
                merged_cursors.insert(path.clone(), (b.editor.cursor(), b.scroll));
            }
        }
        // Try to mirror the split tree. If any leaf isn't an editor we can save
        // (e.g. a transient pty / diff / browser pane), drop layout — the buffer
        // list alone is enough for the most common case.
        //
        // Multi-tab persistence: write one SavedLayout per tab page in
        // `layouts`, plus `active_layout` so restore lands on the right
        // tab. Keep `layout` (single-tab field) populated with the
        // active tab's layout so older mnml binaries reading this
        // session.json still get a sensible single-tab restore.
        let layouts: Vec<Option<SavedLayout>> = self
            .layouts
            .iter()
            .map(|l| saved_layout_from(l, &pane_to_idx))
            .collect();
        let layout = layouts.get(self.active_layout).cloned().unwrap_or(None);
        let saved = SavedSession {
            workspace: self.workspace.to_string_lossy().into_owned(),
            open,
            active,
            layout,
            layouts: Some(layouts),
            active_layout: Some(self.active_layout),
            tree_visible: Some(self.tree_visible),
            tree_root_expanded: Some(self.tree_root_expanded),
            tree_width: Some(self.tree_width),
            git_section_expanded: Some(self.git_section_expanded),
            tree_expanded_dirs: Some(
                self.tree
                    .expanded_dirs()
                    .into_iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect(),
            ),
            tree_show_hidden: Some(self.tree.show_hidden),
            extra_workspaces: self
                .extra_workspaces
                .iter()
                .map(|w| SavedExtraWorkspace {
                    name: w.name.clone(),
                    expanded: w.expanded,
                    expanded_dirs: w
                        .tree
                        .expanded_dirs()
                        .into_iter()
                        .map(|p| p.to_string_lossy().into_owned())
                        .collect(),
                    show_hidden: Some(w.tree.show_hidden),
                })
                .collect(),
            recent_files: self
                .recent_files
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
            browser_url_history: self.browser_url_history.clone(),
            last_browser_device: self.last_browser_device,
            theme: Some(crate::ui::theme::cur().name.to_string()),
            wrap: Some(self.config.ui.wrap),
            clock_show_utc: Some(self.clock_show_utc),
            pty_session_names: {
                // Walk pty panes — record (session_id, display_name)
                // for any renamed Claude session so a later resume can
                // re-apply the name. Carry forward prior-launch entries
                // too (a Claude session not open this run still keeps
                // its saved name).
                let mut m = self.saved_pty_session_names.clone();
                for p in &self.panes {
                    if let Pane::Pty(s) = p
                        && let (Some(sid), Some(name)) = (&s.profile.session_id, &s.display_name)
                    {
                        m.insert(sid.clone(), name.clone());
                    }
                }
                m.into_iter().collect()
            },
            macros: self
                .macro_buffer
                .iter()
                .filter(|(_, keys)| !keys.is_empty())
                .map(|(reg, keys)| SavedMacro {
                    register: *reg,
                    keys: keys
                        .iter()
                        .map(|k| crate::input::keymap::Chord::of(k).to_spec())
                        .collect(),
                })
                .collect(),
            file_cursors: merged_cursors
                .iter()
                .map(|(p, &(c, s))| SavedFileCursor {
                    path: p.to_string_lossy().into_owned(),
                    cursor_byte: c,
                    scroll: s,
                })
                .collect(),
            global_marks: self
                .global_marks
                .iter()
                .map(|(&letter, (path, row, col))| SavedGlobalMark {
                    letter,
                    path: path.to_string_lossy().into_owned(),
                    row: *row,
                    col: *col,
                })
                .collect(),
            folds: self
                .panes
                .iter()
                .filter_map(|p| match p {
                    Pane::Editor(b) if !b.folds.is_empty() => {
                        b.path.as_ref().map(|path| SavedFolds {
                            path: path.to_string_lossy().into_owned(),
                            folds: b.folds.iter().map(|(&s, &e)| (s, e)).collect(),
                        })
                    }
                    _ => None,
                })
                .collect(),
            nav_back: self
                .nav_back
                .iter()
                .map(|np| SavedNavPoint {
                    path: np.path.to_string_lossy().into_owned(),
                    row: np.row,
                    col: np.col,
                })
                .collect(),
            nav_forward: self
                .nav_forward
                .iter()
                .map(|np| SavedNavPoint {
                    path: np.path.to_string_lossy().into_owned(),
                    row: np.row,
                    col: np.col,
                })
                .collect(),
            edit_history: self
                .panes
                .iter()
                .filter_map(|p| match p {
                    Pane::Editor(b) if !b.edit_history.is_empty() => {
                        b.path.as_ref().map(|path| SavedEditHistory {
                            path: path.to_string_lossy().into_owned(),
                            entries: b.edit_history.clone(),
                        })
                    }
                    _ => None,
                })
                .collect(),
            find_history: self.find_history.clone(),
            closed_buffers: self
                .closed_buffers
                .iter()
                .map(|(p, row, col)| SavedNavPoint {
                    path: p.to_string_lossy().into_owned(),
                    row: *row,
                    col: *col,
                })
                .collect(),
            ex_history: self.ex_history.clone(),
            dap_watches: self.dap_watches.clone(),
            harpoon: if self.harpoon.iter().all(|s| s.is_none()) {
                Vec::new()
            } else {
                self.harpoon
                    .iter()
                    .map(|s| s.as_ref().map(|p| p.to_string_lossy().into_owned()))
                    .collect()
            },
            git_graph_detail_col: self.git_graph_detail_col_override,
            diff_view_mode: if self.diff_view_mode_pref == crate::pane::DiffViewMode::Inline {
                None
            } else {
                Some(self.diff_view_mode_pref)
            },
            diff_wrap: self.diff_wrap_pref,
            ai_tokens_in: self.ai_tokens_in,
            ai_tokens_out: self.ai_tokens_out,
            suggest_shown: self.suggest_shown,
            suggest_accepted: self.suggest_accepted,
        };
        let Ok(text) = serde_json::to_string_pretty(&saved) else {
            return;
        };
        let dir = self.workspace.join(".mnml");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("session.json"), text);
    }

    /// Read `.mnml/session.json` and re-open the buffers in it (if the saved
    /// workspace matches). Called once from `main.rs` after `App::new` when
    /// `[session] restore = true`. Missing / mismatched / corrupt file ⇒ no-op.
    pub fn try_restore_session(&mut self) {
        if !self.config.session.restore {
            return;
        }
        let path = self.workspace.join(".mnml").join("session.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let Ok(saved) = serde_json::from_str::<SavedSession>(&text) else {
            return;
        };
        if saved.workspace != self.workspace.to_string_lossy() {
            return;
        }
        // saved-index → restored PaneId (None if the file was missing on disk).
        let mut idx_to_pane: Vec<Option<PaneId>> = vec![None; saved.open.len()];
        let mut active_pane: Option<PaneId> = None;
        for (i, b) in saved.open.iter().enumerate() {
            let p = std::path::Path::new(&b.path);
            if !p.exists() {
                continue;
            }
            self.open_path(p);
            if let Some(pid) = self.active {
                idx_to_pane[i] = Some(pid);
                if saved.active == Some(i) {
                    active_pane = Some(pid);
                }
                if let Some(Pane::Editor(buf)) = self.panes.get_mut(pid) {
                    // Restored buffers are pinned, not preview — otherwise
                    // the next open_path() in this loop would replace this
                    // one (preview-replacement) and we'd lose every buffer
                    // but the last.
                    buf.is_preview = false;
                    let (row, col) = byte_to_row_col(buf.editor.text(), b.cursor_byte);
                    buf.editor.place_cursor(row, col);
                    buf.scroll = b.scroll;
                    // Restore DAP breakpoints (drop any past the file's
                    // current end — file may have shrunk while mnml was
                    // closed).
                    let last_line = buf.editor.line_count().saturating_sub(1) as u32;
                    buf.breakpoints = b
                        .breakpoints
                        .iter()
                        .filter(|&&l| l <= last_line)
                        .copied()
                        .collect();
                    // Restore conditional-breakpoint conditions, but
                    // only for lines that survived the breakpoints
                    // filter above — orphaned conditions (e.g. line was
                    // never a breakpoint, or got trimmed for shrinkage)
                    // would never be applied.
                    let live: std::collections::HashSet<u32> =
                        buf.breakpoints.iter().copied().collect();
                    buf.breakpoint_conditions = b
                        .breakpoint_conditions
                        .iter()
                        .filter(|(l, _)| live.contains(l))
                        .map(|(l, c)| (*l, c.clone()))
                        .collect();
                    buf.breakpoint_hit_conditions = b
                        .breakpoint_hit_conditions
                        .iter()
                        .filter(|(l, _)| live.contains(l))
                        .map(|(l, c)| (*l, c.clone()))
                        .collect();
                }
            }
        }
        // Multi-tab layouts: prefer the new `layouts` Vec when
        // present. Each tab restores independently; tabs whose
        // SavedLayout can't be remapped (a leaf pointed at a buffer
        // that no longer exists) fall back to Layout::Empty.
        if let Some(saved_layouts) = saved.layouts.as_ref()
            && !saved_layouts.is_empty()
        {
            let mut restored_layouts: Vec<Layout> = Vec::with_capacity(saved_layouts.len());
            let mut restored_actives: Vec<Option<PaneId>> = Vec::with_capacity(saved_layouts.len());
            for slot in saved_layouts {
                let lay = slot
                    .as_ref()
                    .and_then(|sl| layout_from_saved(sl, &idx_to_pane))
                    .unwrap_or(Layout::Empty);
                let first = lay.first_leaf();
                restored_layouts.push(lay);
                restored_actives.push(first);
            }
            self.layouts = restored_layouts;
            self.tab_actives = restored_actives;
            self.active_layout = saved.active_layout.unwrap_or(0).min(self.layouts.len() - 1);
            // Sync top-level active with the restored layout's first leaf.
            self.active = self.tab_actives[self.active_layout];
        } else if let Some(sl) = saved.layout.as_ref()
            && let Some(restored) = layout_from_saved(sl, &idx_to_pane)
        {
            // Legacy single-tab session.json — load it as the only tab.
            *self.layout_mut() = restored;
        }
        // Restore the file-tree visibility flag too (`None` ⇒ leave the
        // launch-time default alone — an older session.json without the field).
        if let Some(v) = saved.tree_visible {
            self.tree_visible = v;
        }
        if let Some(v) = saved.tree_root_expanded {
            self.tree_root_expanded = v;
        }
        if let Some(v) = saved.tree_width {
            self.tree_width = v.clamp(8, 200);
        }
        if let Some(v) = saved.git_section_expanded {
            self.git_section_expanded = v;
        }
        if let Some(dirs) = saved.tree_expanded_dirs {
            self.tree
                .set_expanded_dirs(dirs.into_iter().map(PathBuf::from));
        }
        if let Some(v) = saved.tree_show_hidden
            && self.tree.show_hidden != v
        {
            self.tree.show_hidden = v;
            self.tree.refresh();
        }
        // Restore extra-workspace state (matched by name — renames lose
        // their previous state silently).
        for s in saved.extra_workspaces {
            if let Some(w) = self.extra_workspaces.iter_mut().find(|w| w.name == s.name) {
                w.expanded = s.expanded;
                if let Some(v) = s.show_hidden
                    && w.tree.show_hidden != v
                {
                    w.tree.show_hidden = v;
                    w.tree.refresh();
                }
                w.tree
                    .set_expanded_dirs(s.expanded_dirs.into_iter().map(PathBuf::from));
            }
        }
        if !saved.recent_files.is_empty() {
            // Honor the saved order (most-recent first), capping at the runtime
            // limit (which may have shrunk between versions).
            self.recent_files = saved
                .recent_files
                .into_iter()
                .map(PathBuf::from)
                .take(RECENT_FILES_MAX)
                .collect();
        }
        if !saved.browser_url_history.is_empty() {
            self.browser_url_history = saved
                .browser_url_history
                .into_iter()
                .take(BROWSER_URL_HISTORY_MAX)
                .collect();
        }
        if let Some(name) = saved.theme.as_deref() {
            // Best-effort — unknown theme names (e.g. someone deleted a theme
            // file) just leave the launch-default in place. Silent so the
            // restore doesn't toast on every cold start.
            let _ = self.set_theme_silent(name);
        }
        if let Some(w) = saved.wrap {
            self.config.ui.wrap = w;
        }
        if let Some(v) = saved.clock_show_utc {
            self.clock_show_utc = v;
        }
        self.saved_pty_session_names = saved.pty_session_names.into_iter().collect();
        // Drop indices that no longer point into the (potentially
        // shorter) preset table — older sessions could have saved an
        // out-of-range value after a code change.
        if let Some(idx) = saved.last_browser_device
            && idx < crate::browser_pane::DEVICE_PRESETS.len()
        {
            self.last_browser_device = Some(idx);
        }
        for m in saved.macros {
            let keys: Vec<_> = m
                .keys
                .iter()
                .filter_map(|spec| crate::input::keymap::parse_key_spec(spec))
                .collect();
            if !keys.is_empty() {
                self.macro_buffer.insert(m.register, keys);
            }
        }
        for fc in saved.file_cursors {
            self.file_cursors
                .insert(PathBuf::from(fc.path), (fc.cursor_byte, fc.scroll));
        }
        for gm in saved.global_marks {
            // Uppercase letters only — guard against malformed session files.
            if gm.letter.is_ascii_uppercase() {
                self.global_marks
                    .insert(gm.letter, (PathBuf::from(gm.path), gm.row, gm.col));
            }
        }
        // Restore folds onto any buffer whose path matches a saved entry.
        // Out-of-range pairs (start >= line_count, or end < start) get
        // dropped silently — likely stale because the file was edited
        // externally.
        for sf in saved.folds {
            let target = PathBuf::from(&sf.path);
            for p in self.panes.iter_mut() {
                if let Pane::Editor(b) = p
                    && b.path.as_deref() == Some(target.as_path())
                {
                    let line_count = b.editor.line_count();
                    for (start, end) in &sf.folds {
                        if *end >= *start && *start < line_count && *end < line_count {
                            b.folds.insert(*start, *end);
                        }
                    }
                    break;
                }
            }
        }
        // Nav stacks — `Alt+Left` / `Alt+Right` history. Trust the saved
        // entries' (row, col) blindly; if a file was deleted or edited
        // externally, the jump just lands at a clamped position. Capped at
        // the runtime maximum.
        self.nav_back = saved
            .nav_back
            .into_iter()
            .map(|np| NavPoint {
                path: PathBuf::from(np.path),
                row: np.row,
                col: np.col,
            })
            .collect();
        self.nav_forward = saved
            .nav_forward
            .into_iter()
            .map(|np| NavPoint {
                path: PathBuf::from(np.path),
                row: np.row,
                col: np.col,
            })
            .collect();
        if self.nav_back.len() > NAV_STACK_MAX {
            let drop_n = self.nav_back.len() - NAV_STACK_MAX;
            self.nav_back.drain(..drop_n);
        }
        if self.nav_forward.len() > NAV_STACK_MAX {
            let drop_n = self.nav_forward.len() - NAV_STACK_MAX;
            self.nav_forward.drain(..drop_n);
        }
        // Find query history — restore the most recent N (oldest first).
        if !saved.find_history.is_empty() {
            let take_from = saved.find_history.len().saturating_sub(FIND_HISTORY_MAX);
            self.find_history = saved.find_history.into_iter().skip(take_from).collect();
            self.find_history_cursor = self.find_history.len();
        }
        // Closed-buffer stack — restore the most recent N (oldest first).
        if !saved.closed_buffers.is_empty() {
            let take_from = saved
                .closed_buffers
                .len()
                .saturating_sub(CLOSED_BUFFERS_MAX);
            self.closed_buffers = saved
                .closed_buffers
                .into_iter()
                .skip(take_from)
                .map(|np| (PathBuf::from(np.path), np.row, np.col))
                .collect();
        }
        // Ex command history — restore the most recent 100. Push into
        // every open editor's input handler too so vim's cmdline Up/Down
        // can walk it immediately.
        if !saved.ex_history.is_empty() {
            let take_from = saved.ex_history.len().saturating_sub(100);
            self.ex_history = saved.ex_history.into_iter().skip(take_from).collect();
            for p in self.panes.iter_mut() {
                if let Pane::Editor(b) = p {
                    b.input.set_ex_history(self.ex_history.clone());
                }
            }
        }
        // DAP watch expressions — restore the list (cached results
        // re-eval on the next stop and aren't persisted).
        if !saved.dap_watches.is_empty() {
            self.dap_watches = saved.dap_watches;
        }
        // SCM/CI pane view-mode + collapse state.
        // (GH / GL / AZ view-mode + collapsed state all moved to
        // mnml-forge-* siblings in 2026-06.)
        // Harpoon slots — restore up to 9 (silently drop any extras a
        // hand-edited session.json might carry).
        for (i, slot) in saved.harpoon.into_iter().take(9).enumerate() {
            self.harpoon[i] = slot.map(PathBuf::from);
        }
        // GitGraph detail-divider drag override.
        self.git_graph_detail_col_override = saved.git_graph_detail_col;
        // Remembered diff view-mode + wrap toggle.
        if let Some(m) = saved.diff_view_mode {
            self.diff_view_mode_pref = m;
        }
        self.diff_wrap_pref = saved.diff_wrap;
        // AI token tally + suggestion accept tally — restored so the
        // cost / accept-rate readouts are lifetime, not per-launch.
        self.ai_tokens_in = saved.ai_tokens_in;
        self.ai_tokens_out = saved.ai_tokens_out;
        self.suggest_shown = saved.suggest_shown;
        self.suggest_accepted = saved.suggest_accepted;
        // Per-file change list — restore for any buffer we just re-opened.
        // Cursor sits past the newest entry so the first `g;` lands on the
        // most recent edit (vim convention).
        for seh in saved.edit_history {
            let target = PathBuf::from(&seh.path);
            for p in self.panes.iter_mut() {
                if let Pane::Editor(b) = p
                    && b.path.as_deref() == Some(target.as_path())
                {
                    let line_count = b.editor.line_count();
                    let entries: Vec<(usize, usize)> = seh
                        .entries
                        .into_iter()
                        .filter(|(r, _)| *r < line_count)
                        .collect();
                    let cap = entries.len();
                    b.edit_history = entries;
                    b.edit_history_cursor = cap;
                    break;
                }
            }
        }
        let fallback = idx_to_pane.iter().rev().flatten().next().copied();
        if let Some(p) = active_pane.or(fallback) {
            self.reveal_pane(p);
        }
    }
}

#[cfg(test)]
mod session_tests {
    use super::*;
    use std::fs;

    fn app_with_files() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        fs::write(d.path().join("b.txt"), "beta").unwrap();
        // vim input_style — these session-round-trip tests exercise
        // pane management orthogonal to the standard-mode preview-tab
        // UX. Force vim mode so `open_path` always pins.
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    #[test]
    fn session_round_trips_open_buffers_and_active() {
        let (d, mut app) = app_with_files();
        app.open_path(&d.path().join("a.txt"));
        app.open_path(&d.path().join("b.txt"));
        // Move b.txt's cursor onto "beta"'s `t` (byte 2).
        if let Some(Pane::Editor(b)) = app.panes.get_mut(1) {
            b.editor.place_cursor(0, 2);
            b.scroll = 0;
        }
        app.save_session_on_quit();
        assert!(d.path().join(".mnml/session.json").exists());
        // A fresh App on the same workspace + try_restore re-opens both.
        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app2.panes.is_empty());
        app2.try_restore_session();
        assert_eq!(app2.panes.len(), 2);
        // The previously-active (b.txt = index 1) should be focused.
        assert_eq!(app2.active, Some(1));
        // Cursor on b.txt was at (0, 2).
        if let Some(Pane::Editor(b)) = app2.panes.get(1) {
            assert_eq!(b.editor.row_col(), (0, 2));
        } else {
            panic!("expected an editor at index 1");
        }
    }

    #[test]
    fn session_round_trips_multi_tab_layouts() {
        // Two tab pages, each with a different active file. Save +
        // restore should re-open the buffers AND land on the same tab
        // with the same active layout.
        let (d, mut app) = app_with_files();
        let a_path = d.path().join("a.txt").canonicalize().unwrap();
        let b_path = d.path().join("b.txt").canonicalize().unwrap();
        // Tab 1: a.txt
        app.open_path(&a_path);
        // Tab 2: b.txt
        app.tab_new(None);
        app.open_path(&b_path);
        assert_eq!(app.layouts.len(), 2);
        assert_eq!(app.active_layout, 1);
        app.save_session_on_quit();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app2.try_restore_session();
        assert_eq!(
            app2.layouts.len(),
            2,
            "should restore both tabs, got {}",
            app2.layouts.len()
        );
        assert_eq!(app2.active_layout, 1);
        // Both files should be open as panes.
        let _a = app2
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&a_path)))
            .expect("a.txt should be re-opened");
        let _b = app2
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&b_path)))
            .expect("b.txt should be re-opened");
    }

    #[test]
    fn session_skips_save_when_restore_off() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha").unwrap();
        let mut cfg = Config::default();
        cfg.session.restore = false;
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_path(&d.path().join("a.txt"));
        app.save_session_on_quit();
        assert!(!d.path().join(".mnml/session.json").exists());
    }

    #[test]
    fn session_round_trips_tree_state() {
        let d = tempfile::tempdir().unwrap();
        // Need a sub-directory so the tree has something to expand/collapse.
        fs::create_dir(d.path().join("sub")).unwrap();
        fs::write(d.path().join("sub").join("c.txt"), "c").unwrap();
        fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Default after `Tree::open`: depth-0 dirs are expanded. Collapse `sub`.
        let sub = app.workspace.join("sub");
        let mut dirs: Vec<PathBuf> = app
            .tree
            .expanded_dirs()
            .into_iter()
            .filter(|p| p != &sub)
            .collect();
        dirs.sort();
        let collapsed_snapshot = dirs.clone();
        app.tree.set_expanded_dirs(dirs);
        // Also flip the section header (independent state) so we exercise both.
        app.tree_root_expanded = false;
        app.save_session_on_quit();

        let mut app2 = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Pre-restore, the default expansion is whatever Tree::open chose.
        // After restore, it should match what we saved.
        app2.try_restore_session();
        let mut got = app2.tree.expanded_dirs();
        got.sort();
        assert_eq!(got, collapsed_snapshot);
        assert!(!app2.tree_root_expanded);
    }
}
