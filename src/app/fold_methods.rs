//! Vim-style bracket folds — `za` toggle, fold-selection, fold-all,
//! jump-section (`[[` / `]]`), fold-next/prev, unfold-all, and the
//! paragraph reflow (`gwip`) that shares neighbouring line-scan
//! primitives.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// `editor.toggle_fold` (`za`) — fold/unfold at the cursor. Picks the
    /// smallest enclosing bracket-pair (curly preferred over square over
    /// round) and toggles a fold for the line range it covers. Toasts when
    /// the cursor isn't inside any bracket pair.
    pub fn toggle_fold_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        // If the cursor sits on (or in the body of) an existing fold,
        // unfold it instead of folding tighter.
        let cur_row = b.editor.row_col().0;
        if let Some(&owner) = b.folds.keys().find(|&&s| {
            let end = b.folds.get(&s).copied().unwrap_or(s);
            cur_row >= s && cur_row <= end
        }) {
            let mut synced: Option<(PathBuf, Vec<(usize, usize)>)> = None;
            if let Some(b) = self.active_editor_mut() {
                b.folds.remove(&owner);
                if let Some(p) = b.path.clone() {
                    synced = Some((p, b.folds.iter().map(|(&s, &e)| (s, e)).collect()));
                }
                self.toast(format!("unfolded line {}", owner + 1));
            }
            if let Some((p, folds)) = synced {
                self.note_file_folds(&p, folds);
            }
            return;
        }
        // Find the smallest enclosing pair across the three bracket kinds.
        // Candidates come from two sources:
        //   (a) `enclosing_bracket_pair` — the fold CONTAINING the cursor.
        //   (b) An unmatched opener on the CURSOR'S OWN LINE (e.g., cursor
        //       on `if x > 0 {` folds that block, not the outer `fn`). Real
        //       vim's `za` picks the fold that *starts* on the header row
        //       when the cursor sits on it, not the parent. Regression
        //       fixed 2026-07-06 from nvchad-user audit.
        let pairs = [('{', '}'), ('[', ']'), ('(', ')')];
        let mut best: Option<(usize, usize)> = None;
        let text = b.editor.text().to_string();
        let (ls, le) = b.editor.line_byte_range(cur_row);
        for &(open, close) in &pairs {
            if let Some((o, c)) = b.editor.enclosing_bracket_pair(open, close) {
                let lo_line = b.editor.line_at_byte(o);
                let hi_line = b.editor.line_at_byte(c);
                if hi_line > lo_line {
                    let span = hi_line - lo_line;
                    if best.is_none_or(|(s, e)| (e - s) > span) {
                        best = Some((lo_line, hi_line));
                    }
                }
            }
            // Line-scan: last unmatched `open` on the current line, if any.
            let mut open_pos: Option<usize> = None;
            for (i, ch) in text[ls..le].char_indices() {
                if ch == open {
                    open_pos = Some(ls + i);
                } else if ch == close && open_pos.is_some() {
                    open_pos = None;
                }
            }
            if let Some(open_byte) = open_pos {
                // Walk forward with a depth counter to find the matching close.
                let mut depth: usize = 1;
                let mut close_byte: Option<usize> = None;
                for (i, ch) in text[open_byte + 1..].char_indices() {
                    if ch == open {
                        depth += 1;
                    } else if ch == close {
                        depth -= 1;
                        if depth == 0 {
                            close_byte = Some(open_byte + 1 + i);
                            break;
                        }
                    }
                }
                if let Some(c) = close_byte {
                    let lo_line = b.editor.line_at_byte(open_byte);
                    let hi_line = b.editor.line_at_byte(c);
                    if hi_line > lo_line {
                        let span = hi_line - lo_line;
                        if best.is_none_or(|(s, e)| (e - s) > span) {
                            best = Some((lo_line, hi_line));
                        }
                    }
                }
            }
        }
        let Some((start, end)) = best else {
            self.toast("nothing to fold here");
            return;
        };
        let mut synced: Option<(PathBuf, Vec<(usize, usize)>)> = None;
        if let Some(b) = self.active_editor_mut() {
            b.folds.insert(start, end);
            if let Some(p) = b.path.clone() {
                synced = Some((p, b.folds.iter().map(|(&s, &e)| (s, e)).collect()));
            }
            self.toast(format!("folded {} lines", end - start));
        }
        if let Some((p, folds)) = synced {
            self.note_file_folds(&p, folds);
        }
    }

    /// Vim `zf` in Visual mode — create a fold spanning the selected
    /// row range. Selection is remembered, then cleared. If the
    /// selection is single-line, toasts a hint. nvchad-round-8 SEV-3
    /// 2026-07-11.
    pub fn fold_selection_in_active(&mut self) {
        let Some(idx) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            return;
        };
        let Some((lo, hi)) = b.editor.selection() else {
            self.toast("zf — no selection");
            return;
        };
        let text = b.editor.text();
        let start_line = text[..lo].bytes().filter(|&b| b == b'\n').count();
        let hi_line = text[..hi].bytes().filter(|&b| b == b'\n').count();
        // End-of-selection at column 0 doesn't count the last line
        // (matches YankLines / other linewise selection semantics).
        let end_line = if hi > lo
            && hi > 0
            && text.as_bytes()[hi.saturating_sub(1)] == b'\n'
            && hi_line > start_line
        {
            hi_line - 1
        } else {
            hi_line
        };
        if end_line <= start_line {
            self.toast("zf — need multi-line selection");
            return;
        }
        let synced_path = b.path.clone();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            b.folds.insert(start_line, end_line);
            b.editor
                .apply(crate::edit_op::EditOp::SelectClear, 0, &mut self.clipboard);
            self.toast(format!("folded lines {}..{}", start_line + 1, end_line + 1));
        }
        if let Some(p) = synced_path {
            let entries: Vec<(usize, usize)> = self
                .active_editor()
                .map(|b| b.folds.iter().map(|(&s, &e)| (s, e)).collect())
                .unwrap_or_default();
            self.note_file_folds(&p, entries);
        }
    }

    /// `editor.fold_all_brackets` — vim `zM` when no LSP folds are
    /// available. Walks the active buffer, finds every `{…}`/`[…]`/
    /// `(…)` pair that spans more than one line, and adds it to
    /// `b.folds`. Skips nested pairs that would produce identical
    /// ranges. nvchad-round-7 SEV-2 2026-07-11.
    pub fn fold_all_brackets_in_active(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let text = b.editor.text().to_string();
        let mut new_folds: std::collections::BTreeMap<usize, usize> = b.folds.clone();
        // For each bracket family, do a one-pass stack scan.
        for &(open, close) in &[('{', '}'), ('[', ']'), ('(', ')')] {
            let mut stack: Vec<usize> = Vec::new();
            let bytes = text.as_bytes();
            let mut i = 0usize;
            let open_byte = open as u8;
            let close_byte = close as u8;
            while i < bytes.len() {
                let ch = bytes[i];
                if ch == open_byte {
                    stack.push(i);
                } else if ch == close_byte
                    && let Some(o) = stack.pop()
                {
                    let start_line = b.editor.line_at_byte(o);
                    let end_line = b.editor.line_at_byte(i);
                    if end_line > start_line {
                        new_folds.entry(start_line).or_insert(end_line);
                    }
                }
                i += 1;
            }
        }
        let synced_path = b.path.clone();
        let added = new_folds
            .len()
            .saturating_sub(self.active_editor().map(|b| b.folds.len()).unwrap_or(0));
        if let Some(b) = self.active_editor_mut() {
            b.folds = new_folds;
        }
        if added > 0 {
            self.toast(format!("zM — folded {added} block(s)"));
        } else {
            self.toast("zM — no more foldable blocks");
        }
        if let Some(p) = synced_path {
            let entries: Vec<(usize, usize)> = self
                .active_editor()
                .map(|b| b.folds.iter().map(|(&s, &e)| (s, e)).collect())
                .unwrap_or_default();
            self.note_file_folds(&p, entries);
        }
    }

    /// Vim `]]` / `[[` — jump to the next / previous section start.
    /// A "section" boundary is a line whose first char is `{` (C-like)
    /// or matches a top-level scope opener (`fn`, `class`, `struct`,
    /// etc. at column 0). Falls back to a heuristic: any non-blank
    /// line starting at column 0 that is preceded by a blank line.
    /// nvchad-round-9 SEV-2 2026-07-11.
    pub fn jump_section(&mut self, forward: bool, land_on_end: bool) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        let line_count = b.editor.line_count();
        let is_section_start = |line_str: &str| -> bool {
            let bytes = line_str.as_bytes();
            if bytes.is_empty() {
                return false;
            }
            // A brace-start line or a top-level keyword — both signal
            // a section boundary.
            let first = bytes[0];
            if first == b'{' {
                return true;
            }
            let trimmed = line_str.trim_start();
            for kw in &[
                "fn ",
                "class ",
                "struct ",
                "impl ",
                "trait ",
                "enum ",
                "def ",
                "function ",
                "async ",
            ] {
                if trimmed.starts_with(kw) && first == trimmed.as_bytes()[0] {
                    return true;
                }
            }
            false
        };
        let range: Box<dyn Iterator<Item = usize>> = if forward {
            Box::new((cur_row + 1)..line_count)
        } else {
            Box::new((0..cur_row).rev())
        };
        for row in range {
            let line = b.editor.line_str(row);
            if is_section_start(line) {
                let target = if land_on_end {
                    if forward {
                        row.saturating_sub(1)
                    } else {
                        (row + 1).min(line_count.saturating_sub(1))
                    }
                } else {
                    row
                };
                if let Some(b) = self.active_editor_mut() {
                    b.editor.place_cursor(target, 0);
                }
                return;
            }
        }
        self.toast(if forward {
            "]] — no section forward"
        } else {
            "[[ — no section back"
        });
    }

    /// Vim `[m` / `]m` — jump to the previous / next method start.
    /// Unlike [`jump_section`] which requires a top-level `fn` / `class`
    /// at column 0, this walks symbols from [`crate::regex_outline`]
    /// filtered to function / method kinds — so an indented `def foo`
    /// inside a class OR an `impl` block's inner methods qualify.
    /// Fires the big-jump nav hook so `Ctrl+O` returns.
    pub fn jump_method(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        let ext = b
            .path
            .as_ref()
            .and_then(|p| p.extension())
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_string();
        if ext.is_empty() {
            self.toast(if forward {
                "]m — unknown language"
            } else {
                "[m — unknown language"
            });
            return;
        }
        let text = b.editor.text().to_string();
        let symbols = crate::regex_outline::extract_symbols(&text, &ext);
        let is_method_kind = |k: &str| {
            matches!(
                k,
                "fn" | "function" | "method" | "def" | "func" | "constructor"
            )
        };
        let target: Option<u32> = if forward {
            symbols
                .iter()
                .find(|s| is_method_kind(s.kind) && (s.line as usize) > cur_row)
                .map(|s| s.line)
        } else {
            symbols
                .iter()
                .rev()
                .find(|s| is_method_kind(s.kind) && (s.line as usize) < cur_row)
                .map(|s| s.line)
        };
        match target {
            Some(row) => {
                let np = self.current_nav_point();
                if let Some(b) = self.active_editor_mut() {
                    b.editor.place_cursor(row as usize, 0);
                }
                if let Some(np) = np {
                    self.record_within_file_jump(np);
                }
            }
            None => self.toast(if forward {
                "]m — no method forward"
            } else {
                "[m — no method back"
            }),
        }
    }

    /// `zj` — jump the cursor to the start of the next fold (relative
    /// to current row). No-op when there are no folds after the cursor.
    /// nvchad-round-7 SEV-3 2026-07-11.
    pub fn fold_next_in_active(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        // nvchad-round-10 SEV-2 regression 2026-07-11 — was iterating
        // ALL fold starts including nested ones, so after `zM` (which
        // creates folds for every bracket pair) `zj` jumped inside
        // the current fold instead of skipping to the next top-level
        // block. Filter out folds whose start is strictly inside
        // another fold's range.
        let top_level: Vec<(usize, usize)> = top_level_folds(&b.folds);
        let next = top_level
            .iter()
            .find(|(s, _)| *s > cur_row)
            .map(|(s, _)| *s);
        if let Some(target) = next
            && let Some(b) = self.active_editor_mut()
        {
            b.editor.place_cursor(target, 0);
        } else {
            self.toast("zj — no fold after cursor");
        }
    }

    /// `zk` — jump to the start of the previous fold.
    pub fn fold_prev_in_active(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let cur_row = b.editor.row_col().0;
        let top_level: Vec<(usize, usize)> = top_level_folds(&b.folds);
        let prev = top_level
            .iter()
            .rev()
            .find(|(s, _)| *s < cur_row)
            .map(|(s, _)| *s);
        if let Some(target) = prev
            && let Some(b) = self.active_editor_mut()
        {
            b.editor.place_cursor(target, 0);
        } else {
            self.toast("zk — no fold before cursor");
        }
    }

    /// `editor.unfold_all` — drop every fold from the active buffer.
    pub fn unfold_all_in_active(&mut self) {
        let mut synced: Option<PathBuf> = None;
        let mut n = 0usize;
        if let Some(b) = self.active_editor_mut() {
            n = b.folds.len();
            b.folds.clear();
            if let Some(p) = b.path.clone() {
                synced = Some(p);
            }
        }
        if n > 0 {
            self.toast(format!("unfolded {n} fold(s)"));
        }
        if let Some(p) = synced {
            self.note_file_folds(&p, Vec::new());
        }
    }

    /// `editor.reflow_paragraph` — vim `gqq`. Greedy word-wrap the cursor's
    /// paragraph to `[editor] text_width`. The reflow op preserves the
    /// first line's leading indent on every wrapped line.
    pub fn reflow_paragraph_at_cursor(&mut self) {
        let width = self.config.editor.text_width;
        let Some(b) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let mut clip = crate::clipboard::Clipboard::new();
        let changed = b.apply_edit_ops(
            vec![crate::edit_op::EditOp::ReflowParagraph { width }],
            &mut clip,
            0,
        );
        if changed {
            self.toast(format!("reflow → {width} cols"));
        }
    }
}
