//! Workspace grep via ripgrep / git-grep + grep-pane navigation +
//! per-file replace.
//!
//! Sub-extracted from `app/editor_features.rs`. Non-destructive move.

use super::*;

impl App {
    /// Search activity-bar section: focus the inline input box so the
    /// next keystrokes append to `search_query`. Also switches the
    /// active section to Search if it wasn't already + ensures the
    /// rail is visible.
    pub fn search_section_focus_input(&mut self) {
        if !self.tree_visible {
            self.tree_visible = true;
        }
        self.active_section = crate::app::ActivitySection::Search;
        self.search_input_focused = true;
    }

    /// Release focus on the search input. Other dispatch paths route
    /// to the editor again.
    pub fn search_section_blur(&mut self) {
        self.search_input_focused = false;
    }

    /// Append `c` to the search query (with simple cursor at end).
    /// Live-search would re-run on every keystroke; we wait for Enter
    /// to avoid the user paying for half-typed queries.
    pub fn search_section_insert_char(&mut self, c: char) {
        self.search_query.push(c);
        self.search_cursor = self.search_query.chars().count();
    }

    /// Drop the trailing char from the search query.
    pub fn search_section_backspace(&mut self) {
        if !self.search_query.is_empty() {
            self.search_query.pop();
            self.search_cursor = self.search_query.chars().count();
        }
    }

    /// Run the workspace grep on the current query — Enter inside the
    /// search input fires here. Populates `search_hits` + `search_used`.
    /// Multi-root workspaces are concat'd just like the existing pane
    /// grep.
    pub fn search_section_run(&mut self) {
        let q = self.search_query.trim().to_string();
        if q.is_empty() {
            self.search_hits.clear();
            self.search_used = "";
            return;
        }
        let (mut hits, used) = crate::app::grep_workspace(&self.workspace, &q);
        let extras: Vec<std::path::PathBuf> = self
            .extra_workspaces
            .iter()
            .map(|w| w.root.clone())
            .collect();
        for root in extras {
            let (mut extra_hits, _) = crate::app::grep_workspace(&root, &q);
            hits.append(&mut extra_hits);
        }
        self.search_hits = hits;
        self.search_used = used;
        self.search_selected = 0;
        self.search_scroll = 0;
    }

    /// Move selection in the inline results list by `delta` (positive
    /// = down, negative = up). No-op when there are no hits.
    pub fn search_section_select(&mut self, delta: isize) {
        if self.search_hits.is_empty() {
            return;
        }
        let len = self.search_hits.len() as isize;
        let new = (self.search_selected as isize + delta).clamp(0, len - 1);
        self.search_selected = new as usize;
    }

    /// Open the focused hit in the editor (Enter on a result row,
    /// while focus is NOT on the input box). Falls back gracefully
    /// when no hit is selected.
    pub fn search_section_open_selected(&mut self) {
        let Some(hit) = self.search_hits.get(self.search_selected).cloned() else {
            return;
        };
        let (path, line, col) = (hit.path, hit.line as usize, hit.col as usize);
        self.open_path(&path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line, col);
        }
    }

    /// Open a specific hit by index — used by the mouse handler when
    /// a result row is clicked. Sets `search_selected` to the hit
    /// before opening so the highlight follows the click.
    pub fn search_section_open_hit(&mut self, idx: usize) {
        if idx >= self.search_hits.len() {
            return;
        }
        self.search_selected = idx;
        self.search_section_open_selected();
    }

    /// `find.grep` (palette) — prompt for a query and grep the workspace.
    pub fn open_grep_prompt(&mut self) {
        let seed = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) if b.editor.has_selection() => b
                .editor
                .selected_text()
                .lines()
                .next()
                .unwrap_or("")
                .to_string(),
            _ => String::new(),
        };
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Grep,
            "Grep workspace",
            seed,
        ));
    }

    /// Run `rg --vimgrep <q> .` in the workspace (falling back to `git grep`),
    /// parse `path:line:col:text` lines, and open the results in a `Pane::Grep`
    /// (split below the focused leaf). If a grep pane is already open for an
    /// earlier query, *that* pane is refilled in place — only one grep pane at
    /// a time.
    pub fn run_workspace_grep(&mut self, q: String) {
        let q = q.trim().to_string();
        if q.is_empty() {
            return;
        }
        // Multi-root: run grep in the primary workspace + each extra,
        // concat the hits. `used` reflects the tool of the primary run
        // (consistent — extras presumably have the same toolchain
        // available since they're sibling user dirs).
        let (mut hits, used) = grep_workspace(&self.workspace, &q);
        for ws in &self.extra_workspaces {
            let (mut extra_hits, _) = grep_workspace(&ws.root, &q);
            hits.append(&mut extra_hits);
        }
        if hits.is_empty() {
            self.toast(format!("{used}: no matches for {q:?}"));
            return;
        }
        // Already showing a grep pane somewhere? Refresh it in place.
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Grep(_))) {
            if let Some(Pane::Grep(g)) = self.panes.get_mut(id) {
                *g = crate::grep_pane::GrepPane::new(q, used, hits);
            }
            // Right-panel v5 — bring the existing grep tab forward.
            if let Some(idx) = self.right_panel_panes.iter().position(|&pid| pid == id) {
                self.right_panel_active_idx = idx;
            } else {
                self.reveal_pane(id);
            }
            return;
        }
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(q, used, hits));
        // Right-panel v5 — host grep results in the panel as a tab
        // when visible. Each row is path:line:content; at narrow
        // widths the path takes most of the cells, but the user can
        // drag the column wider for the full hit text.
        if self.right_panel_visible {
            self.panes.push(pane);
            let new_id = self.panes.len() - 1;
            self.right_panel_push(new_id);
            return;
        }
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-run the grep that produced the active `Pane::Grep` (the `r` key).
    pub fn rerun_active_grep(&mut self) {
        let q = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g.query.clone(),
            _ => return,
        };
        let (hits, used) = grep_workspace(&self.workspace, &q);
        if let Some(Pane::Grep(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            *g = crate::grep_pane::GrepPane::new(q, used, hits);
        }
    }

    pub fn move_grep_selection(&mut self, delta: isize) {
        if let Some(Pane::Grep(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.move_selection(delta);
        }
    }

    /// `y` in a grep pane — copy the selected hit's `path:line` (1-based) to
    /// the system clipboard so the user can paste it into a commit message,
    /// chat, etc.
    pub fn copy_selected_grep_hit(&mut self) {
        let s = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g
                .selected_hit()
                .map(|h| format!("{}:{}", h.rel, h.line + 1)),
            _ => None,
        };
        let Some(s) = s else { return };
        self.clipboard.set(s.clone(), false);
        self.toast(format!("copied {s}"));
    }

    /// Open the highlighted grep hit's file and place the cursor there.
    pub fn jump_to_selected_grep_hit(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => g
                .selected_hit()
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

    /// `find.grep_replace` (the `R` key in a `Pane::Grep`) — prompt for a
    /// replacement string. The grep pane's query is the seed, but the input
    /// starts empty so the user can type the replacement without first deleting
    /// the seed. Requires an active grep pane with at least one hit.
    pub fn open_grep_replace_prompt(&mut self) {
        let (query, n) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) if !g.hits.is_empty() => (g.query.clone(), g.hits.len()),
            Some(Pane::Grep(_)) => {
                self.toast("no grep hits to replace");
                return;
            }
            _ => return,
        };
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::GrepReplace,
            format!("Replace {n}× \"{query}\" with"),
        ));
    }

    /// Replace every hit in the active `Pane::Grep` across every file it
    /// matched. For each unique file:
    /// - **Open + clean** ⇒ apply `EditOp::ReplaceRange`s through the buffer
    ///   (so undo works + LSP `didChange` fires).
    /// - **Not open** ⇒ read the file from disk, splice in reverse, write back.
    /// - **Open + dirty** ⇒ skip + toast (refuse to clobber unsaved edits).
    ///
    /// The match positions are re-derived from each file's live text via
    /// `crate::buffer::find_all_ci_ascii` (rather than trusting the grep tool's
    /// line/col, which might be stale by now). After replacing, the grep query
    /// is re-run so the pane reflects the new state.
    pub fn run_grep_replace(&mut self, replacement: String) {
        // Snapshot the (query, unique-file-paths) from the active grep pane.
        // Per-hit toggle: hits whose index is in `g.disabled` are excluded —
        // files with NO enabled hits are skipped entirely.
        let (query, files, disabled_files) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Grep(g)) => {
                use std::collections::HashSet;
                let mut files: Vec<PathBuf> = Vec::new();
                let mut disabled_files: HashSet<PathBuf> = HashSet::new();
                // Group hit-indices by file so we can see which files
                // have at least one enabled hit.
                let mut hits_by_file: std::collections::HashMap<PathBuf, Vec<usize>> =
                    std::collections::HashMap::new();
                for (i, h) in g.hits.iter().enumerate() {
                    hits_by_file.entry(h.path.clone()).or_default().push(i);
                }
                for (path, idxs) in &hits_by_file {
                    let any_enabled = idxs.iter().any(|i| !g.disabled.contains(i));
                    if any_enabled {
                        if !files.iter().any(|p| p == path) {
                            files.push(path.clone());
                        }
                    } else {
                        disabled_files.insert(path.clone());
                    }
                }
                (g.query.clone(), files, disabled_files)
            }
            _ => return,
        };
        let _ = disabled_files; // (currently unused — kept for future per-line replace path)
        if query.is_empty() {
            return;
        }
        let mut total_replacements = 0usize;
        let mut files_changed = 0usize;
        let mut files_skipped: Vec<String> = Vec::new();
        let mut io_errors: Vec<String> = Vec::new();
        for path in &files {
            // Is this file open as an editor pane? (Take the first such pane.)
            let open_idx = self.panes.iter().position(
                |p| matches!(p, Pane::Editor(b) if b.path.as_deref() == Some(path.as_path())),
            );
            if let Some(idx) = open_idx {
                let is_dirty = matches!(self.panes.get(idx), Some(Pane::Editor(b)) if b.dirty);
                if is_dirty {
                    files_skipped.push(rel_path(&self.workspace, path));
                    continue;
                }
                let text = match self.panes.get(idx) {
                    Some(Pane::Editor(b)) => b.editor.text().to_string(),
                    _ => continue,
                };
                let matches = crate::buffer::find_all_ci_ascii(&text, &query);
                if matches.is_empty() {
                    continue;
                }
                let ops: Vec<crate::edit_op::EditOp> = matches
                    .iter()
                    .rev()
                    .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                        start: *s,
                        end: *e,
                        text: replacement.clone(),
                    })
                    .collect();
                let n = ops.len();
                let clip = &mut self.clipboard;
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.apply_edit_ops(ops, clip, 0);
                    // Persist the change to disk so the grep re-run reflects
                    // it (and so the user doesn't have to save N files by hand).
                    match b.save_to_disk() {
                        Ok(()) => {}
                        Err(e) => {
                            io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                            continue;
                        }
                    }
                }
                // Push the new text through LSP just like a normal save.
                if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                    let t = b.editor.text().to_string();
                    self.lsp.did_change(path, &t);
                }
                total_replacements += n;
                files_changed += 1;
            } else {
                // Not open — splice on disk.
                let text = match std::fs::read_to_string(path) {
                    Ok(s) => s,
                    Err(e) => {
                        io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                        continue;
                    }
                };
                let matches = crate::buffer::find_all_ci_ascii(&text, &query);
                if matches.is_empty() {
                    continue;
                }
                let mut out = String::with_capacity(text.len());
                let mut cursor = 0usize;
                for (s, e) in &matches {
                    out.push_str(&text[cursor..*s]);
                    out.push_str(&replacement);
                    cursor = *e;
                }
                out.push_str(&text[cursor..]);
                if let Err(e) = std::fs::write(path, &out) {
                    io_errors.push(format!("{}: {e}", rel_path(&self.workspace, path)));
                    continue;
                }
                total_replacements += matches.len();
                files_changed += 1;
            }
        }
        // Toast a summary.
        let mut parts = vec![format!(
            "replaced {total_replacements} in {files_changed} files"
        )];
        if !files_skipped.is_empty() {
            parts.push(format!(
                "skipped {} (unsaved): {}",
                files_skipped.len(),
                files_skipped.join(", ")
            ));
        }
        if !io_errors.is_empty() {
            parts.push(format!("{} errored", io_errors.len()));
        }
        self.toast(parts.join(" · "));
        // Refresh the grep pane against the new state.
        self.rerun_active_grep();
    }
}

#[cfg(test)]
mod grep_tests {
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
    fn grep_pane_jump_opens_file_and_places_cursor() {
        // Manually seed a Pane::Grep — the grep tool itself (rg / git grep)
        // isn't reliably available in test sandboxes, but the rest of the flow
        // (jump-to-hit) is the part we want to cover end-to-end.
        let (_d, mut app) = app_with_files();
        // `app.workspace` is the *canonicalized* tmp dir; the buffer the editor
        // opens will hold the same canonical form, so compare against it.
        let abs = app.workspace.join("a.txt");
        // a.txt is `alpha`; pretend a tool matched at line 0, col 2.
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "alpha".into(),
            "rg",
            vec![crate::grep_pane::GrepHit {
                path: abs.clone(),
                rel: "a.txt".into(),
                line: 0,
                col: 2,
                text: "alpha".into(),
            }],
        ));
        app.panes.push(pane);
        let id = app.panes.len() - 1;
        *app.layout_mut() = Layout::leaf(id);
        app.active = Some(id);
        app.focus = Focus::Pane;

        app.jump_to_selected_grep_hit();

        // Opening the file added an editor pane and focused it.
        assert!(matches!(
            app.active.and_then(|i| app.panes.get(i)),
            Some(Pane::Editor(b)) if b.is_at(&abs)
        ));
        let buf = app.active_editor().unwrap();
        assert_eq!(buf.editor.row_col(), (0, 2));
    }

    #[test]
    fn grep_replace_writes_open_buffer_and_disk() {
        // Two files, both contain `foo`. Open one as an editor (clean), leave
        // the other on disk only. `run_grep_replace("BAR")` should rewrite
        // both, replacing every match.
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "foo bar foo").unwrap();
        fs::write(d.path().join("b.txt"), "say foo loud").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let a = app.workspace.join("a.txt");
        let b = app.workspace.join("b.txt");
        app.open_path(&a); // a.txt now open as a clean editor

        // Seed a Pane::Grep with hits for both files (positions don't need to
        // be real — `run_grep_replace` re-derives matches via find_all_ci_ascii).
        let mk_hit = |path: &Path, rel: &str| crate::grep_pane::GrepHit {
            path: path.to_path_buf(),
            rel: rel.into(),
            line: 0,
            col: 0,
            text: "".into(),
        };
        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "foo".into(),
            "rg",
            vec![mk_hit(&a, "a.txt"), mk_hit(&b, "b.txt")],
        ));
        app.panes.push(pane);
        let grep_id = app.panes.len() - 1;
        // Make the grep pane the active one (so run_grep_replace targets it).
        *app.layout_mut() = Layout::leaf(grep_id);
        app.active = Some(grep_id);

        app.run_grep_replace("BAR".into());

        // a.txt was open + clean ⇒ the buffer + disk both updated.
        let a_buf = app
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&a) => Some(b),
                _ => None,
            })
            .unwrap();
        // The open buffer + on-disk file both got the in-memory update.
        // Disk version has a trailing `\n` because the open buffer goes
        // through `save_to_disk` which honors `ensure_trailing_newline`.
        assert_eq!(a_buf.editor.text(), "BAR bar BAR\n");
        assert!(!a_buf.dirty); // saved through to disk
        assert_eq!(fs::read_to_string(&a).unwrap(), "BAR bar BAR\n");

        // b.txt was disk-only ⇒ just the disk got rewritten. The
        // disk-write path (grep_replace's direct splice, not `save_to_disk`)
        // doesn't apply `ensure_trailing_newline` — that's a save-only step.
        assert_eq!(fs::read_to_string(&b).unwrap(), "say BAR loud");
    }

    #[test]
    fn grep_replace_skips_dirty_open_buffer() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "foo").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let a = app.workspace.join("a.txt");
        app.open_path(&a);
        // Make the buffer dirty (without changing the matched text).
        if let Some(Pane::Editor(b)) = app
            .panes
            .iter_mut()
            .find(|p| matches!(p, Pane::Editor(b) if b.is_at(&a)))
        {
            b.editor.place_cursor(0, 3);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::InsertStr("!".into())],
                &mut Clipboard::new(),
                0,
            );
        }

        let pane = Pane::Grep(crate::grep_pane::GrepPane::new(
            "foo".into(),
            "rg",
            vec![crate::grep_pane::GrepHit {
                path: a.clone(),
                rel: "a.txt".into(),
                line: 0,
                col: 0,
                text: "".into(),
            }],
        ));
        app.panes.push(pane);
        let grep_id = app.panes.len() - 1;
        *app.layout_mut() = Layout::leaf(grep_id);
        app.active = Some(grep_id);

        app.run_grep_replace("BAR".into());

        // Disk is untouched (the dirty buffer was skipped).
        assert_eq!(fs::read_to_string(&a).unwrap(), "foo");
    }
}
