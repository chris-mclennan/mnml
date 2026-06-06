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

    /// Apply a batch of buffer-side `TextEdit`s to the live snippet
    /// session's stops + recorded exit positions. Called from the
    /// editor-input pipeline after every `BufferEvent::Edited` so the
    /// session stays aligned with the buffer as the user types — even
    /// when the cursor wanders away from the current stop and edits
    /// happen at other positions. No-op when no session is active or
    /// when the active pane doesn't match the session's pane.
    pub fn apply_snippet_text_edits(&mut self, pane_id: usize, edits: &[crate::edit_op::TextEdit]) {
        if edits.is_empty() {
            return;
        }
        let Some(sess) = self.snippet_session.as_mut() else {
            return;
        };
        if sess.pane_id != pane_id {
            return;
        }
        for ed in edits {
            let delta = ed.new_end_byte as i64 - ed.old_end_byte as i64;
            for off in sess.stops.iter_mut() {
                // Strict `>` so a stop sitting at the edit's start
                // (typical: the active stop the user is typing at)
                // stays put — the cursor moves with the edit naturally;
                // we don't want to double-shift.
                if *off > ed.start_byte {
                    *off = (*off as i64 + delta).max(ed.start_byte as i64) as usize;
                }
            }
            for c in sess.stop_cursors.iter_mut().flatten() {
                if *c > ed.start_byte {
                    *c = (*c as i64 + delta).max(ed.start_byte as i64) as usize;
                }
            }
        }
        // Track total text length so any future caller that needs it
        // doesn't go stale. Doesn't drive the shift any more.
        if let Some(b) = match self.active {
            Some(p) => self.panes.get(p),
            None => None,
        } && let Pane::Editor(buf) = b
        {
            self.snippet_session.as_mut().unwrap().last_text_len = buf.editor.text().len();
        }
    }

    /// Shared step: `+1` = forward, `-1` = backward. Records the
    /// cursor's exit position for the *current* stop so a later
    /// Backtab to it lands at the end of typed content, then jumps to
    /// the new index. Stop positions are now kept live by
    /// [`Self::apply_snippet_text_edits`] — this method no longer needs
    /// to bulk-shift on Tab.
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

#[cfg(test)]
mod snippet_position_tests {
    use super::*;
    use crate::config::Config;
    use crate::edit_op::TextEdit;
    use crate::snippets::SnippetSession;

    fn app_with_session(stops: Vec<usize>, current: usize) -> App {
        // Use pane_id 0 — `apply_snippet_text_edits` matches against
        // the session's `pane_id` field and doesn't actually touch the
        // pane unless the active editor exists; for these tests we
        // only assert on stop positions, so a synthetic pane id is OK.
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let stop_cursors = vec![None; stops.len()];
        let default_lens = vec![0; stops.len()];
        app.snippet_session = Some(SnippetSession {
            pane_id: 0,
            stops,
            current,
            last_text_len: 0,
            stop_cursors,
            default_lens,
        });
        app
    }

    #[test]
    fn apply_text_edit_shifts_stops_after_edit_position() {
        // Stops at 50, 70. Insert 5 chars at position 30 (between
        // start of buffer and stop 0). Both stops should shift by 5.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 30,
                old_end_byte: 30,
                new_end_byte: 35,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![55, 75]);
    }

    #[test]
    fn apply_text_edit_does_not_shift_stops_before_edit_position() {
        // Stops at 50, 70. Insert 5 chars at position 90 (after both
        // stops). Neither stop should shift.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 90,
                old_end_byte: 90,
                new_end_byte: 95,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![50, 70]);
    }

    #[test]
    fn apply_text_edit_partial_shift_when_edit_falls_between_stops() {
        // Stops at 50, 70. Insert 5 chars at position 60 (between).
        // Only stop[1] shifts.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 60,
                old_end_byte: 60,
                new_end_byte: 65,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![50, 75]);
    }

    #[test]
    fn apply_text_edit_at_exact_stop_position_does_not_shift_that_stop() {
        // Stop at 50. Insert 5 chars at position 50 (at the stop —
        // the user typing AT the active stop). Stop stays at 50
        // because the cursor moves naturally with the insertion;
        // shifting would double-count.
        let mut app = app_with_session(vec![50], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 50,
                old_end_byte: 50,
                new_end_byte: 55,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![50]);
    }

    #[test]
    fn apply_text_edit_handles_deletion() {
        // Stops at 50, 70. Delete 10 chars at position 30
        // (start=30, old_end=40, new_end=30). Both stops shift by -10.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 30,
                old_end_byte: 40,
                new_end_byte: 30,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![40, 60]);
    }

    #[test]
    fn apply_text_edit_deletion_clamps_stops_inside_range() {
        // Stops at 50, 70. Delete 20 chars at position 40
        // (start=40, old_end=60, new_end=40). Stop[0] at 50 is INSIDE
        // the deleted range; clamp to start_byte (40). Stop[1] at 70
        // shifts by -20 → 50.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 40,
                old_end_byte: 60,
                new_end_byte: 40,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![40, 50]);
    }

    #[test]
    fn apply_text_edit_no_op_when_no_session_active() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app.snippet_session.is_none());
        // Should not panic and should not create a session.
        app.apply_snippet_text_edits(
            0,
            &[TextEdit {
                start_byte: 10,
                old_end_byte: 10,
                new_end_byte: 15,
            }],
        );
        assert!(app.snippet_session.is_none());
    }

    #[test]
    fn apply_text_edit_no_op_when_pane_mismatch() {
        // Session was opened in pane 0; edit reports pane 99 — leave
        // the session untouched.
        let mut app = app_with_session(vec![50, 70], 0);
        app.apply_snippet_text_edits(
            99,
            &[TextEdit {
                start_byte: 10,
                old_end_byte: 10,
                new_end_byte: 30,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![50, 70]);
    }

    #[test]
    fn apply_text_edit_also_shifts_recorded_exit_cursors() {
        // Stops at 50, 70 with stop[1] previously visited at exit
        // cursor 80. Insert 5 chars at position 30. Both stops shift,
        // and the recorded exit cursor also shifts.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.snippet_session.as_mut().unwrap().stop_cursors[1] = Some(80);
        app.apply_snippet_text_edits(
            pane_id,
            &[TextEdit {
                start_byte: 30,
                old_end_byte: 30,
                new_end_byte: 35,
            }],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![55, 75]);
        assert_eq!(s.stop_cursors[1], Some(85));
    }

    #[test]
    fn apply_text_edit_batch_applies_each_in_order() {
        // Two edits in sequence: first shifts +5 at position 30,
        // second shifts +10 at position 80. Stop at 50 → 55 → 55
        // (second edit is past it). Stop at 70 → 75 → 75.
        let mut app = app_with_session(vec![50, 70], 0);
        let pane_id = 0usize;
        app.apply_snippet_text_edits(
            pane_id,
            &[
                TextEdit {
                    start_byte: 30,
                    old_end_byte: 30,
                    new_end_byte: 35,
                },
                TextEdit {
                    start_byte: 80,
                    old_end_byte: 80,
                    new_end_byte: 90,
                },
            ],
        );
        let s = app.snippet_session.as_ref().unwrap();
        assert_eq!(s.stops, vec![55, 75]);
    }
}
