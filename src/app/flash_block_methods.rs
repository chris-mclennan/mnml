//! Flash/leap motion (`s<a><b>`), vim visual-block replace / insert /
//! change / repeat-insert replay, quickfix + cmdline-history overlays,
//! the single `run_editor_op` entry point, and the `:s/.../.../gc`
//! interactive-confirm handlers (`replace_confirm_*`).
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// Flash/leap `s<a><b>` — find every visible occurrence of `ab` in the
    /// active editor's viewport, label each, and arm the dispatcher to
    /// intercept the next keystroke for a jump. Empty result ⇒ toast and
    /// leave the cursor where it is.
    pub fn flash_start(&mut self, a: char, b: char) {
        let Some(pid) = self.active else {
            return;
        };
        let Some(Pane::Editor(buf)) = self.panes.get(pid) else {
            return;
        };
        let text = buf.editor.text();
        let scroll = buf.scroll;
        // Per-pane visible-row count — derived from the recorded text rect.
        // If the rect isn't recorded yet (e.g. first frame), fall back to a
        // reasonable height so flash still does something useful.
        let vp_h = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, p)| *p == pid)
            .map(|(r, _)| r.height as usize)
            .unwrap_or(40);

        // Build line index for the viewport. Each entry is `(file_row,
        // line_text)`.
        let mut lines: Vec<(usize, &str)> = Vec::new();
        let mut row = 0usize;
        for line in text.split_inclusive('\n') {
            if row >= scroll {
                lines.push((row, line.trim_end_matches('\n')));
                if lines.len() >= vp_h {
                    break;
                }
            }
            row += 1;
        }
        if row < scroll && lines.is_empty() {
            // File shorter than the scroll position — nothing to label.
            self.toast("flash: nothing visible");
            return;
        }

        // Scan each line for case-insensitive `ab` occurrences.
        let pair = (a, b);
        let a_lower = a.to_ascii_lowercase();
        let b_lower = b.to_ascii_lowercase();
        let mut hits: Vec<(usize, usize)> = Vec::new();
        for (file_row, line) in &lines {
            let mut prev: Option<char> = None;
            for (col_chars, c) in line.chars().enumerate() {
                if let Some(p) = prev
                    && p.to_ascii_lowercase() == a_lower
                    && c.to_ascii_lowercase() == b_lower
                {
                    hits.push((*file_row, col_chars - 1));
                    if hits.len() >= crate::flash::MAX_MATCHES {
                        break;
                    }
                }
                prev = Some(c);
            }
            if hits.len() >= crate::flash::MAX_MATCHES {
                break;
            }
        }

        if hits.is_empty() {
            self.toast(format!("flash: no \"{a}{b}\" on screen"));
            return;
        }

        let labels = crate::flash::pick_labels(pair, hits.len());
        let targets: Vec<crate::flash::FlashTarget> = hits
            .into_iter()
            .zip(labels)
            .map(|((row, col_chars), label)| crate::flash::FlashTarget {
                row,
                col_chars,
                label,
            })
            .collect();
        self.flash_state = Some(crate::flash::FlashState {
            pane_id: pid,
            pair,
            targets,
        });
    }

    /// Flash intercept: try to consume a character as a label. Returns
    /// `true` if the keystroke was consumed (label matched or universal
    /// cancel like Esc); `false` if the dispatcher should re-handle the
    /// key normally.
    pub fn flash_consume_char(&mut self, c: char) -> bool {
        let Some(state) = self.flash_state.as_ref() else {
            return false;
        };
        let target = state
            .targets
            .iter()
            .find(|t| t.label == c)
            .map(|t| (state.pane_id, t.row, t.col_chars));
        self.flash_state = None;
        if let Some((pid, row, col)) = target {
            // Push current position on the back-stack so Alt+Left returns
            // (mirrors editor.jump_*-style navigation).
            if let Some(np) = self.current_nav_point() {
                self.push_nav_back(np);
                self.nav_forward.clear();
            }
            if let Some(Pane::Editor(buf)) = self.panes.get_mut(pid) {
                buf.editor.place_cursor(row, col);
            }
            true
        } else {
            // Unknown label ⇒ cancel and let the key fall through.
            false
        }
    }

    pub fn flash_cancel(&mut self) {
        self.flash_state = None;
    }

    /// Visual-block `I` / `A` ⇒ start a block-insert. Captures the rect,
    /// drops the block selection, places the cursor at the (column-aligned)
    /// insert origin, and asks the active input handler to enter Insert mode.
    /// The actual multi-row replay happens in
    /// [`Self::block_insert_replay_if_done`] when the handler returns to
    /// Normal mode (typically Esc out of Insert).
    /// V-BLOCK `r<c>` — fill every cell in the block rectangle with
    /// `<c>`. Each row's column range is clamped to the row's actual
    /// end, so short lines don't get padded. Single atomic undo step.
    /// nvchad-round-7 SEV-2 2026-07-11.
    pub fn block_replace_with(&mut self, ch: char) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let Some((rmin, cmin, rmax, cmax)) = b.editor.block_selection() else {
            b.editor.block_anchor = None;
            return;
        };
        let clip = &mut self.clipboard;
        b.editor.atomic_undo(|ed| {
            for row in (rmin..=rmax).rev() {
                let line_len_chars = ed.line_str(row).chars().count();
                let start_col = cmin.min(line_len_chars);
                let end_col = (cmax + 1).min(line_len_chars);
                if end_col <= start_col {
                    continue;
                }
                let start_byte = ed.byte_at_col_pub(row, start_col);
                let end_byte = ed.byte_at_col_pub(row, end_col);
                let width = end_col - start_col;
                let repl: String = std::iter::repeat_n(ch, width).collect();
                ed.apply(
                    crate::edit_op::EditOp::ReplaceRange {
                        start: start_byte,
                        end: end_byte,
                        text: repl,
                    },
                    0,
                    clip,
                );
            }
        });
        b.editor.block_anchor = None;
        b.dirty = true;
    }

    pub fn block_insert_start(&mut self, append: bool) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let Some((rmin, cmin, rmax, cmax)) = b.editor.block_selection() else {
            return;
        };
        let col = if append { cmax + 1 } else { cmin };
        // The "other rows" exclude the top row — the user types literally
        // there during Insert; we only replay onto the rest.
        let other_rows: Vec<usize> = ((rmin + 1)..=rmax).collect();
        // Drop the block selection so Insert renders without the rect tint.
        b.editor.block_anchor = None;
        // Place the cursor at (rmin, col). `byte_at_col_pub` clamps to line
        // length, so on short lines `A` lands at EOL (vim's behavior — and
        // why we still record `col` for the replay's per-row recomputation).
        let start_byte = b.editor.byte_at_col_pub(rmin, col);
        b.editor.set_cursor_byte(start_byte);
        let top_row_byte_len_before = b.editor.line_byte_len(rmin);
        self.block_insert_state = Some(BlockInsertState {
            other_rows,
            col,
            start_byte,
            top_row_byte_len_before,
            top_row: rmin,
            pane_id: idx,
            append,
        });
        // Drive the handler into Insert (Vim mode flip via trait method).
        b.input.request_insert_mode();
    }

    /// Populate / open a `Pane::Quickfix`. `hits` are the entries to show.
    /// Vim canonical drivers: `:cexpr <text>` parses `file:line:col:text`,
    /// LSP references could also route here in a future change.
    pub fn open_quickfix(&mut self, title: &str, hits: Vec<crate::grep_pane::GrepHit>) {
        let pane = Pane::Quickfix(crate::grep_pane::GrepPane::new(
            title.to_string(),
            "quickfix",
            hits,
        ));
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Quickfix(_)))
        {
            if let Some(Pane::Quickfix(g)) = self.panes.get_mut(id)
                && let Pane::Quickfix(replacement) = pane
            {
                *g = replacement;
            }
            self.reveal_pane(id);
            return;
        }
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Jump to the file:line of the highlighted quickfix entry.
    pub fn jump_to_selected_quickfix_hit(&mut self) {
        let Some(i) = self.active else { return };
        let Some(Pane::Quickfix(g)) = self.panes.get(i) else {
            return;
        };
        let Some(hit) = g.hits.get(g.selected).cloned() else {
            return;
        };
        self.open_path(&hit.path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(hit.line as usize, hit.col as usize);
        }
    }

    /// `view.cmdline_history` (vim `q:`) — open a pane listing recent `:`
    /// commands. Selecting one + Enter re-fires it.
    pub fn open_cmdline_history(&mut self) {
        let pane = Pane::CmdlineHistory(crate::pane::CmdlineHistoryPane::from_history(
            &self.ex_history,
        ));
        // Reveal an existing pane if one's open; otherwise split below the
        // active pane (like the outline / grep panes).
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::CmdlineHistory(_)))
        {
            if let Some(Pane::CmdlineHistory(h)) = self.panes.get_mut(id) {
                *h = crate::pane::CmdlineHistoryPane::from_history(&self.ex_history);
            }
            self.reveal_pane(id);
            return;
        }
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-fire the highlighted entry in the active cmdline-history pane,
    /// then close the pane.
    pub fn cmdline_history_accept(&mut self) {
        let Some(i) = self.active else { return };
        let Some(Pane::CmdlineHistory(h)) = self.panes.get(i) else {
            return;
        };
        let Some(entry) = h.selected_entry().map(String::from) else {
            return;
        };
        self.force_close_pane(i);
        self.run_ex_command(&entry);
    }

    /// vim `<count>o` / `<count>O` ⇒ open one new line (the rest get
    /// filled with the typed text on Esc), enter Insert mode, save state.
    pub fn repeat_insert_start(&mut self, count: usize, above: bool) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        let op = if above {
            crate::edit_op::EditOp::InsertNewlineAbove
        } else {
            crate::edit_op::EditOp::InsertNewlineBelow
        };
        b.editor.apply(op, 20, &mut self.clipboard);
        b.recompute_dirty();
        b.refresh_highlights();
        let first_row = if above { cur_row } else { cur_row + 1 };
        let start_byte = b.editor.byte_at_col_pub(first_row, 0);
        let first_row_byte_len_before = b.editor.line_byte_len(first_row);
        self.repeat_insert_state = Some(RepeatInsertState {
            count,
            first_row,
            first_row_byte_len_before,
            start_byte,
            pane_id: idx,
            above,
        });
        b.input.request_insert_mode();
    }

    /// Polled by `App::tick`. When a `<count>o` / `<count>O` state is set AND
    /// the active handler has returned to Normal, capture the text typed on
    /// `first_row` and replicate it on `count - 1` more lines below the
    /// first (vim's behavior).
    pub fn repeat_insert_replay_if_done(&mut self) {
        let Some(state) = self.repeat_insert_state.as_ref() else {
            return;
        };
        if state.pane_id >= self.panes.len() {
            self.repeat_insert_state = None;
            return;
        }
        let Some(Pane::Editor(b)) = self.panes.get(state.pane_id) else {
            self.repeat_insert_state = None;
            return;
        };
        if b.input.mode() == crate::input::EditingMode::Insert {
            return;
        }
        let state = self.repeat_insert_state.take().unwrap();
        let Some(Pane::Editor(b)) = self.panes.get_mut(state.pane_id) else {
            return;
        };
        // Whatever the user typed on first_row is the chunk to replay.
        let now_len = b.editor.line_byte_len(state.first_row);
        if now_len <= state.first_row_byte_len_before {
            return;
        }
        let added = now_len - state.first_row_byte_len_before;
        let typed: String = b
            .editor
            .text()
            .get(state.start_byte..state.start_byte + added)
            .map(|s| s.to_string())
            .unwrap_or_default();
        if typed.is_empty() || state.count <= 1 {
            return;
        }
        // After the first row's content, insert `(count - 1)` more lines
        // each containing `typed`. Splice in one go below first_row.
        let payload: String = (1..state.count).map(|_| format!("\n{typed}")).collect();
        // Insert AT THE END of first_row (after any trailing chars the user
        // may have typed past the original line end, since `o` opens a
        // fresh empty line we know the row has only `typed`'s content).
        let insert_at = state.start_byte + added;
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: insert_at,
            end: insert_at,
            text: payload,
        }];
        b.apply_edit_ops(ops, &mut self.clipboard, 20);
        // Cursor returns to the END of the FIRST typed line (vim convention
        // — same as if the user just hit Esc on a regular `o<text>`).
        b.editor.set_cursor_byte(insert_at);
        b.recompute_dirty();
    }

    /// Visual-block `c` / `s` ⇒ delete the rectangle first, then start a
    /// block-insert at the rect's leftmost column (now collapsed since the
    /// slice is gone). On Esc the typed run is replayed on every other row,
    /// same as plain [`Self::block_insert_start`].
    pub fn block_change_start(&mut self) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let Some((rmin, cmin, rmax, _cmax)) = b.editor.block_selection() else {
            return;
        };
        // Delete the rectangle. Editor::apply on DeleteBlock leaves the
        // cursor at (rmin, cmin) — exactly where we want to insert.
        b.editor
            .apply(crate::edit_op::EditOp::DeleteBlock, 20, &mut self.clipboard);
        b.recompute_dirty();
        b.refresh_highlights();
        let other_rows: Vec<usize> = ((rmin + 1)..=rmax).collect();
        let start_byte = b.editor.byte_at_col_pub(rmin, cmin);
        b.editor.set_cursor_byte(start_byte);
        let top_row_byte_len_before = b.editor.line_byte_len(rmin);
        self.block_insert_state = Some(BlockInsertState {
            other_rows,
            col: cmin,
            start_byte,
            top_row_byte_len_before,
            top_row: rmin,
            pane_id: idx,
            append: false,
        });
        b.input.request_insert_mode();
    }

    /// Polled by [`Self::tick`]. When a block-insert state is pending AND
    /// the active handler has returned to Normal mode, replay the typed run
    /// on every "other row" in the rect, then clear the state. Idempotent.
    pub fn block_insert_replay_if_done(&mut self) {
        let Some(state) = self.block_insert_state.as_ref() else {
            return;
        };
        // Pane still exists?
        if state.pane_id >= self.panes.len() {
            self.block_insert_state = None;
            return;
        }
        // Handler still in Insert? Keep waiting.
        let Some(Pane::Editor(b)) = self.panes.get(state.pane_id) else {
            self.block_insert_state = None;
            return;
        };
        if b.input.mode() == crate::input::EditingMode::Insert {
            return;
        }
        // Snapshot the inserted text by comparing the top row's new byte
        // length to what we captured at start. If it shrunk (user Backspaced
        // past the original insert position), nothing to replay.
        let state = self.block_insert_state.take().unwrap();
        let Some(Pane::Editor(b)) = self.panes.get_mut(state.pane_id) else {
            return;
        };
        let top_row_byte_len_now = b.editor.line_byte_len(state.top_row);
        if top_row_byte_len_now <= state.top_row_byte_len_before {
            return;
        }
        let inserted_len = top_row_byte_len_now - state.top_row_byte_len_before;
        let inserted: String = b
            .editor
            .text()
            .get(state.start_byte..state.start_byte + inserted_len)
            .map(|s| s.to_string())
            .unwrap_or_default();
        if inserted.is_empty() || state.other_rows.is_empty() {
            return;
        }
        // For each other row (descending so earlier byte offsets stay
        // valid), splice `inserted` at the col-aligned byte position. Rows
        // shorter than `col` get the splice appended at EOL — vim canonical
        // (block A on short lines, anyway).
        let mut ops: Vec<crate::edit_op::EditOp> = Vec::with_capacity(state.other_rows.len());
        let mut targets: Vec<(usize, usize)> = state
            .other_rows
            .iter()
            .map(|&row| (row, b.editor.byte_at_col_pub(row, state.col)))
            .collect();
        targets.sort_by_key(|&(_, b)| std::cmp::Reverse(b));
        for (_, byte) in targets {
            ops.push(crate::edit_op::EditOp::ReplaceRange {
                start: byte,
                end: byte,
                text: inserted.clone(),
            });
        }
        // Single coalesced edit so one Undo reverts the whole block insert.
        // nvchad-round-7 SEV-2 2026-07-11 — apply_edit_ops opens a
        // fresh checkpoint per op, so N rows became N undo entries.
        // Wrap the loop in atomic_undo instead.
        let clip = &mut self.clipboard;
        b.editor.atomic_undo(|ed| {
            for op in ops {
                ed.apply(op, 20, clip);
            }
        });
        b.dirty = true;
        // Cursor returns to the insert origin (vim convention).
        b.editor.set_cursor_byte(state.start_byte);
        b.recompute_dirty();
    }

    /// `view.toggle_color_column` — flip `[ui] color_column` between 0 (off)
    /// and 80 (vim's classic line-length hint). The exact column can be set
    /// via `:set colorcolumn=N`.
    /// Apply a single `EditOp` to the active editor's buffer. Used by
    /// command-registry entries that just want to fire an op without
    /// going through the input handler (multi-cursor chords, etc.).
    pub fn run_editor_op(&mut self, op: crate::edit_op::EditOp) {
        let Some(idx) = self.active else { return };
        // qa-6th nvchad SEV-3: vim jumplist parity. Vim populates
        // the jumplist before "big jumps" — `gg`, `G`, `<num>G`,
        // search, `*`, `#`, paragraph nav, etc. Push the current
        // position onto nav_back BEFORE the op runs so Ctrl+o
        // (vim) / Alt+Left (standard) returns to where the user
        // was. Cross-file jumps already get this via reveal_pane
        // and open_path; this closes the in-buffer gap.
        let is_big_jump = matches!(
            op,
            crate::edit_op::EditOp::MoveBufferStart
                | crate::edit_op::EditOp::MoveBufferEnd
                | crate::edit_op::EditOp::MoveToLine(_)
                | crate::edit_op::EditOp::MoveDownFirstNonWs
                | crate::edit_op::EditOp::MoveUpFirstNonWs
                | crate::edit_op::EditOp::MoveParagraph { .. }
        );
        if is_big_jump && let Some(np) = self.current_nav_point() {
            self.push_nav_back(np);
            self.nav_forward.clear();
        }
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            b.editor.apply(op, 20, &mut self.clipboard);
            b.recompute_dirty();
            b.refresh_highlights();
        }
    }

    /// Jump the cursor to the *next* pending match in `replace_confirm`
    /// (the last entry — `remaining` is reverse-ordered, pop returns the
    /// first remaining match). Toast the prompt label so the user sees the
    /// available chord (y/n/a/q). Caller drains the state if there's
    /// nothing left.
    pub(crate) fn replace_confirm_jump_to_current(&mut self) {
        let Some(rc) = self.replace_confirm.as_ref() else {
            return;
        };
        let pane_id = rc.pane_id;
        let Some(&(start, _)) = rc.remaining.last() else {
            return;
        };
        let n = rc.remaining.len();
        let total = rc.total;
        let find = rc.find.clone();
        let replace = rc.replace.clone();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id) {
            place_cursor_at_byte(b, start);
        }
        self.toast(format!(
            "{}/{} replace {find:?} → {replace:?} ?  y/n/a/q",
            total - n + 1,
            total
        ));
    }

    /// `y` (replace) in the interactive replace overlay. Apply at the
    /// current match, shift remaining offsets by the replacement's length
    /// delta, advance.
    pub fn replace_confirm_yes(&mut self) {
        let Some(mut rc) = self.replace_confirm.take() else {
            return;
        };
        if let Some((start, end)) = rc.remaining.pop() {
            let new_text = rc.replace.clone();
            let delta = new_text.len() as i64 - (end - start) as i64;
            if let Some(Pane::Editor(b)) = self.panes.get_mut(rc.pane_id) {
                let mut clip = crate::clipboard::Clipboard::new();
                let ops = vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end,
                    text: new_text,
                }];
                b.apply_edit_ops(ops, &mut clip, 0);
            }
            rc.applied += 1;
            // Shift later matches by the length delta (they're at higher
            // byte offsets, so they all move).
            for (s, e) in rc.remaining.iter_mut() {
                *s = (*s as i64 + delta).max(0) as usize;
                *e = (*e as i64 + delta).max(0) as usize;
            }
        }
        if rc.remaining.is_empty() {
            self.toast(format!(":s/c — replaced {}/{}", rc.applied, rc.total));
        } else {
            self.replace_confirm = Some(rc);
            self.replace_confirm_jump_to_current();
        }
    }

    /// `n` (skip) in the interactive replace overlay. Advance without
    /// editing.
    pub fn replace_confirm_no(&mut self) {
        let Some(mut rc) = self.replace_confirm.take() else {
            return;
        };
        rc.remaining.pop();
        if rc.remaining.is_empty() {
            self.toast(format!(":s/c — replaced {}/{}", rc.applied, rc.total));
        } else {
            self.replace_confirm = Some(rc);
            self.replace_confirm_jump_to_current();
        }
    }

    /// `a` (apply this and all remaining) in the interactive replace overlay.
    pub fn replace_confirm_all(&mut self) {
        let Some(mut rc) = self.replace_confirm.take() else {
            return;
        };
        // Drain remaining into ReplaceRange ops (reverse order so earlier
        // offsets stay valid).
        let mut ops: Vec<crate::edit_op::EditOp> = Vec::with_capacity(rc.remaining.len());
        let count = rc.remaining.len();
        // `remaining` is reverse-ordered (pop = first match). Iterate as-is
        // so we apply later → earlier (== descending byte offset, valid
        // without shifting).
        while let Some((s, e)) = rc.remaining.pop() {
            ops.insert(
                0,
                crate::edit_op::EditOp::ReplaceRange {
                    start: s,
                    end: e,
                    text: rc.replace.clone(),
                },
            );
        }
        // Now `ops` is in descending offset order (insert(0) reversed).
        if let Some(Pane::Editor(b)) = self.panes.get_mut(rc.pane_id) {
            let mut clip = crate::clipboard::Clipboard::new();
            b.apply_edit_ops(ops, &mut clip, 0);
        }
        rc.applied += count;
        self.toast(format!(":s/c — replaced {}/{}", rc.applied, rc.total));
    }

    /// `q` / Esc in the interactive replace overlay. Drop the state.
    pub fn replace_confirm_quit(&mut self) {
        if let Some(rc) = self.replace_confirm.take() {
            self.toast(format!(
                ":s/c — quit at {}/{} replacement(s)",
                rc.applied, rc.total
            ));
        }
    }
}
