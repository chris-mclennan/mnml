//! Snippet expansion + placeholder navigation.
//!
//! Sub-extracted from `app/editor_features.rs` after Phase E.2 left
//! the file at 5121 lines. Pure non-destructive move.

use super::*;

impl App {
    /// `snippet.expand` (`Ctrl+J`) — look at the identifier prefix immediately
    /// left of the active editor's cursor; if it matches a snippet trigger for
    /// the file's extension (or `global`), replace the prefix with the
    /// expansion. Cursor lands at the `$0` marker (or at end if absent).
    /// No match ⇒ toast.
    pub fn snippet_expand_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let ext = b.language_ext.clone();
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        let (prefix_start, word) = crate::snippets::word_before_cursor(text, cursor);
        if word.is_empty() {
            self.toast("snippet: no trigger word before cursor");
            return;
        }
        let snippets = crate::snippets::snippets_for(&self.config.snippets, ext.as_deref());
        let Some(snip) = crate::snippets::find_by_trigger(&snippets, &word) else {
            self.toast(format!("no snippet matches '{word}'"));
            return;
        };
        let text = snip.text.clone();
        let cursor_offset = snip.cursor_offset;
        let placeholders = snip.placeholders.clone();
        self.apply_snippet_edit(prefix_start, cursor, text, cursor_offset, placeholders);
    }

    /// `snippet.pick_all` — list every snippet across every scope (not just
    /// the active editor's filetype). Useful when looking for "what
    /// snippets do I have configured?" without context-switching to the
    /// config file.
    pub fn snippet_pick_all(&mut self) {
        use crate::picker::PickerItem;
        // Walk the config's snippet table — `HashMap<scope, HashMap<trigger,
        // text>>` — and flatten into one Vec<Snippet>.
        let mut all: Vec<crate::snippets::Snippet> = Vec::new();
        let mut scopes: Vec<&String> = self.config.snippets.keys().collect();
        scopes.sort();
        for scope in scopes {
            let Some(table) = self.config.snippets.get(scope) else {
                continue;
            };
            let mut triggers: Vec<&String> = table.keys().collect();
            triggers.sort();
            for trigger in triggers {
                let Some(text) = table.get(trigger) else {
                    continue;
                };
                all.push(crate::snippets::Snippet::parse(
                    trigger.clone(),
                    text,
                    scope.clone(),
                ));
            }
        }
        if all.is_empty() {
            self.toast("no snippets configured (see [snippets.*] in config.toml)");
            return;
        }
        let items: Vec<PickerItem> = all
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let raw = s.text.replace("$0", "");
                let mut preview: String = raw
                    .lines()
                    .map(str::trim_end)
                    .filter(|l| !l.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ↵ ");
                if preview.chars().count() > 60 {
                    let truncated: String = preview.chars().take(60).collect();
                    preview = format!("{truncated}…");
                }
                PickerItem::new(
                    i.to_string(),
                    format!("[{}] {}  →  {}", s.scope, s.trigger, preview),
                    s.scope.clone(),
                )
            })
            .collect();
        let n = items.len();
        self.pending_snippets = all;
        self.open_picker(Picker::new(
            PickerKind::Snippets,
            format!("All snippets ({n})"),
            items,
        ));
    }

    pub fn snippet_pick(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let ext = b.language_ext.clone();
        let snippets = crate::snippets::snippets_for(&self.config.snippets, ext.as_deref());
        if snippets.is_empty() {
            self.toast("no snippets configured (see [snippets.*] in config.toml)");
            return;
        }
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = snippets
            .iter()
            .enumerate()
            .map(|(i, s)| {
                // Multi-line preview: collapse to a single inline string
                // joining lines with a `↵` glyph so the user sees the shape
                // of the expansion without the picker row going multi-line.
                // Strip placeholder markers (`$0`/`$1`/…) so the preview
                // shows what the inserted text looks like.
                let raw = s.text.replace("$0", "");
                let mut preview: String = raw
                    .lines()
                    .map(str::trim_end)
                    .filter(|l| !l.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ↵ ");
                // Cap so the preview doesn't blow up the picker row.
                if preview.chars().count() > 60 {
                    let truncated: String = preview.chars().take(60).collect();
                    preview = format!("{truncated}…");
                }
                PickerItem::new(
                    i.to_string(),
                    format!("{}  →  {}", s.trigger, preview),
                    s.scope.clone(),
                )
            })
            .collect();
        let n = items.len();
        self.pending_snippets = snippets;
        self.open_picker(Picker::new(
            PickerKind::Snippets,
            format!("Snippets ({n})"),
            items,
        ));
    }

    /// Picker-accept side: insert the chosen snippet's expansion at the cursor
    /// (no trigger word to consume).
    pub(super) fn snippet_insert_at_cursor(&mut self, idx: usize) {
        let Some(snip) = self.pending_snippets.get(idx).cloned() else {
            return;
        };
        let Some(b) = self.active_editor() else {
            return;
        };
        let cursor = b.editor.cursor();
        self.apply_snippet_edit(
            cursor,
            cursor,
            snip.text,
            snip.cursor_offset,
            snip.placeholders,
        );
    }

    /// Shared edit path: replace `[start, end)` with `text`, then place the
    /// cursor at `start + cursor_offset` so `$0` lands where the user expects.
    /// If `placeholders` is non-empty, jump the cursor to the first one
    /// instead and open a [`crate::snippets::SnippetSession`] so Tab cycles
    /// through the rest (and finally to the `$0` spot).
    fn apply_snippet_edit(
        &mut self,
        start: usize,
        end: usize,
        text: String,
        cursor_offset: usize,
        placeholders: Vec<usize>,
    ) {
        // No defaults — mnml's native snippets path. Defer to the richer
        // form with an empty `default_lens`.
        let zeros = vec![0usize; placeholders.len()];
        self.apply_snippet_edit_with_defaults(start, end, text, cursor_offset, placeholders, zeros);
    }

    /// Same as [`Self::apply_snippet_edit`] but carries an LSP-style
    /// `default_lens: Vec<usize>` parallel to `placeholders`. When the
    /// first stop has a non-zero default, the default text is selected
    /// (anchor at the stop, cursor at stop+default_len) so typing replaces
    /// it — vim-canonical `c{motion}` shape.
    pub(super) fn apply_snippet_edit_with_defaults(
        &mut self,
        start: usize,
        end: usize,
        text: String,
        cursor_offset: usize,
        placeholders: Vec<usize>,
        default_lens: Vec<usize>,
    ) {
        let pane_id = self.active;
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let inserted_len = text.len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange { start, end, text }];
        let mut clip = crate::clipboard::Clipboard::new();
        let changed = b.apply_edit_ops(ops, &mut clip, 0);
        if !changed {
            return;
        }
        // The cursor sits at `start + inserted_len` after the replace. First
        // stop is `placeholders[0]` if any, else the `$0` marker (or end).
        let first_stop_local = placeholders
            .first()
            .copied()
            .unwrap_or(cursor_offset.min(inserted_len));
        let first_default_len = default_lens.first().copied().unwrap_or(0);
        let target_cursor = start + first_stop_local;
        if first_default_len > 0 {
            // LSP default-as-selected: drop anchor at the placeholder, put
            // cursor at the default's end. Typing replaces the default.
            let end = target_cursor + first_default_len;
            b.editor.set_selection(target_cursor, end);
        } else {
            place_cursor_at_byte(b, target_cursor);
        }
        // Open a placeholder session if there are any tab stops — `$1..$9`
        // at the front, optionally `$0` appended as the final stop. (When
        // `$0` is absent we let Tab terminate at the last `$N` rather than
        // yanking the cursor to the end.)
        let mut stops: Vec<usize> = placeholders.iter().map(|&off| start + off).collect();
        let mut def_lens: Vec<usize> = default_lens.clone();
        if !placeholders.is_empty() && cursor_offset < inserted_len {
            stops.push(start + cursor_offset);
            def_lens.push(0);
        }
        let last_text_len = b.editor.text().len();
        let path_for_lsp = b.path.clone();
        let new_text_for_lsp = b.editor.text().to_string();
        // Only worth a session when there's somewhere to tab *to* — a single
        // stop is the one we already placed at, no second stop = nothing to
        // cycle. `current = 0` is where we just placed; advancing puts us at
        // index 1.
        if let (true, Some(pane_id)) = (stops.len() > 1, pane_id) {
            let n_stops = stops.len();
            // The user is currently sitting at index 0; mark it visited so
            // future Backtab-to-0 lands at the *end* of (now-modified)
            // default text instead of re-selecting the default.
            let mut stop_cursors = vec![None; n_stops];
            if first_default_len > 0 {
                stop_cursors[0] = Some(target_cursor + first_default_len);
            }
            // Defensive: pad def_lens to match stops len if caller passed
            // a shorter vec.
            while def_lens.len() < n_stops {
                def_lens.push(0);
            }
            self.snippet_session = Some(crate::snippets::SnippetSession {
                pane_id,
                stops,
                current: 0,
                last_text_len,
                stop_cursors,
                default_lens: def_lens,
            });
        } else {
            self.snippet_session = None;
        }
        // Keep LSP in sync (a snippet may contain identifiers the server
        // cares about) — same shape as buffer-edit paths elsewhere.
        if let Some(path) = path_for_lsp {
            self.lsp.did_change(&path, &new_text_for_lsp);
        }
    }

    /// Tab inside an open snippet session: advance to the next placeholder,
    /// accounting for any text the user inserted at the current one. Closes
    /// the session after the last stop.
    pub fn snippet_next_placeholder(&mut self) {
        self.snippet_step_placeholder(1);
    }

    /// Shift-Tab inside an open snippet session: walk back to the previous
    /// placeholder. No-op at the first stop (doesn't wrap — wrapping mid-edit
    /// is more confusing than helpful).
    pub fn snippet_prev_placeholder(&mut self) {
        self.snippet_step_placeholder(-1);
    }

    /// Shared step: `+1` = forward, `-1` = backward. Shifts all stops
    /// strictly after the current cursor by the text-length delta accrued
    /// since we last placed at a stop, then jumps to the new index.
    /// Records the cursor's exit position for the *current* stop so a
    /// later Backtab to it lands at the end of typed content (vim-ish).
    fn snippet_step_placeholder(&mut self, dir: i32) {
        let Some(mut sess) = self.snippet_session.take() else {
            return;
        };
        if Some(sess.pane_id) != self.active {
            // Pane drifted away — let the session die.
            return;
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let cur_len = b.editor.text().len();
        // Capture the exit cursor for the current stop before we move on.
        let exit_cursor = b.editor.cursor();
        let cur_idx = sess.current;
        if cur_idx < sess.stop_cursors.len() {
            sess.stop_cursors[cur_idx] = Some(exit_cursor);
        }
        // Net chars added (or removed) since we last placed at a stop —
        // shifts every position strictly after the active stop. `i64` to
        // tolerate net deletions.
        let delta = cur_len as i64 - sess.last_text_len as i64;
        for (i, off) in sess.stops.iter_mut().enumerate() {
            if i > cur_idx {
                *off = (*off as i64 + delta).max(0) as usize;
            }
        }
        // Same shift applied to recorded exit cursors of later stops (so
        // forward Tab → Backtab → forward chain still lands correctly).
        for (i, c) in sess.stop_cursors.iter_mut().enumerate() {
            if i > cur_idx
                && let Some(pos) = c
            {
                *pos = (*pos as i64 + delta).max(0) as usize;
            }
        }
        // Compute the new index. Forward off the end ⇒ session ends.
        // Backward at index 0 ⇒ stay put (no wrap).
        let new_idx_signed = cur_idx as i32 + dir;
        if dir > 0 && new_idx_signed >= sess.stops.len() as i32 {
            // Walked off the last stop. Don't restore the session.
            return;
        }
        if dir < 0 && new_idx_signed < 0 {
            // Already at the first stop — re-store and bail.
            sess.last_text_len = cur_len;
            self.snippet_session = Some(sess);
            return;
        }
        let new_idx = new_idx_signed as usize;
        // Three landing-position cases:
        //  1. Visited before — restore the recorded exit cursor (vim-ish
        //     "end of what was typed there").
        //  2. Unvisited with default text — select the default so typing
        //     replaces it (LSP convention).
        //  3. Unvisited bare placeholder — drop cursor at stop position.
        let visited_exit = sess.stop_cursors.get(new_idx).and_then(|c| *c);
        let default_len = sess.default_lens.get(new_idx).copied().unwrap_or(0);
        let stop_pos = sess.stops[new_idx];
        if let Some(exit) = visited_exit {
            place_cursor_at_byte(b, exit.min(cur_len));
        } else if default_len > 0 {
            let span_end = (stop_pos + default_len).min(cur_len);
            b.editor.set_selection(stop_pos.min(cur_len), span_end);
            // Mark visited at the default's end so a subsequent Backtab-back
            // doesn't re-select.
            if new_idx < sess.stop_cursors.len() {
                sess.stop_cursors[new_idx] = Some(span_end);
            }
        } else {
            place_cursor_at_byte(b, stop_pos.min(cur_len));
        }
        sess.current = new_idx;
        sess.last_text_len = cur_len;
        self.snippet_session = Some(sess);
    }
}
