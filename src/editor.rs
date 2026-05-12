//! The text-editing core: a `String` + a byte cursor + selection anchor + undo/redo,
//! and `apply(EditOp)` — the single interpreter every input handler funnels through.
//!
//! Storage is a plain `String` (fine for typical source files; all mutation is
//! funnelled through `apply` so a rope can replace this later without touching
//! call sites). Columns are counted in **chars** for now (display-width / tabs /
//! CJK are a P2 refinement). All byte offsets are kept on char boundaries.

use crate::clipboard::Clipboard;
use crate::edit_op::{EditOp, EditOutcome};

#[derive(Debug, Clone)]
struct Snapshot {
    text: String,
    cursor: usize,
    anchor: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CharClass {
    Word,
    Punct,
    Space,
}

fn class_of(c: char) -> CharClass {
    if c.is_whitespace() {
        CharClass::Space
    } else if c.is_alphanumeric() || c == '_' {
        CharClass::Word
    } else {
        CharClass::Punct
    }
}

/// Vertical motions keep the "goal column" so repeated up/down through short
/// lines doesn't shrink the target. Everything else resets it to the new column.
fn op_preserves_goal_col(op: &EditOp) -> bool {
    use EditOp::*;
    match op {
        MoveUp | MoveDown | PageUp | PageDown => true,
        Repeat(_, inner) => op_preserves_goal_col(inner),
        _ => false,
    }
}

/// Whether an op is (a chain of) typed characters — used to decide whether to
/// keep the coalescing undo run alive.
fn op_is_insert_char(op: &EditOp) -> bool {
    match op {
        EditOp::InsertChar(_) => true,
        EditOp::Repeat(_, inner) => op_is_insert_char(inner),
        _ => false,
    }
}

const UNDO_LIMIT: usize = 2000;

#[derive(Debug, Clone)]
pub struct Editor {
    text: String,
    cursor: usize,
    anchor: Option<usize>,
    goal_col: usize,
    tab_width: usize,
    comment_token: String,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// True while a coalescing run of `InsertChar` is in progress.
    in_insert_run: bool,
}

impl Editor {
    pub fn new(text: impl Into<String>, tab_width: usize) -> Self {
        Editor {
            text: text.into(),
            cursor: 0,
            anchor: None,
            goal_col: 0,
            tab_width: tab_width.max(1),
            comment_token: "// ".to_string(),
            undo: Vec::new(),
            redo: Vec::new(),
            in_insert_run: false,
        }
    }

    pub fn empty() -> Self {
        Editor::new(String::new(), 4)
    }

    // ─── accessors ──────────────────────────────────────────────────
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn cursor(&self) -> usize {
        self.cursor
    }
    pub fn set_comment_token(&mut self, token: impl Into<String>) {
        self.comment_token = token.into();
    }
    /// Move the cursor to `(row, col)` (both clamped), clearing any selection.
    /// Used for click-to-place.
    pub fn place_cursor(&mut self, row: usize, col: usize) {
        let row = row.min(self.line_count().saturating_sub(1));
        self.cursor = self.byte_at_col(row, col);
        self.anchor = None;
        self.goal_col = self.col_at_byte(self.cursor);
        self.in_insert_run = false;
    }
    /// `(row, col)` of the cursor, 0-based, col in chars.
    pub fn row_col(&self) -> (usize, usize) {
        let row = self.current_line();
        let col = self.text[self.line_start(row)..self.cursor].chars().count();
        (row, col)
    }
    pub fn line_count(&self) -> usize {
        self.text.bytes().filter(|&b| b == b'\n').count() + 1
    }
    pub fn line_str(&self, line: usize) -> &str {
        let s = self.line_start(line);
        let e = self.line_end(line);
        &self.text[s..e]
    }
    /// Byte range `[start, end)` of line `line`'s content (the newline excluded).
    pub fn line_byte_range(&self, line: usize) -> (usize, usize) {
        (self.line_start(line), self.line_end(line))
    }
    /// Char-column count of `text[..byte_offset_within_line]` relative to the
    /// start of the line that contains `byte`. Public so the view can map a
    /// selection's byte offsets to columns.
    pub fn byte_to_col(&self, byte: usize) -> usize {
        self.col_at_byte(byte)
    }
    /// The full selection range as byte offsets `[lo, hi)`, or `None`.
    pub fn selection(&self) -> Option<(usize, usize)> {
        self.anchor
            .map(|a| (a.min(self.cursor), a.max(self.cursor)))
    }
    pub fn has_selection(&self) -> bool {
        self.anchor.map(|a| a != self.cursor).unwrap_or(false)
    }
    pub fn is_at_line_start(&self) -> bool {
        self.cursor == self.line_start(self.current_line())
    }
    pub fn is_at_line_end(&self) -> bool {
        self.cursor == self.line_end(self.current_line())
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    // ─── line geometry helpers ──────────────────────────────────────
    fn current_line(&self) -> usize {
        self.text[..self.cursor]
            .bytes()
            .filter(|&b| b == b'\n')
            .count()
    }
    /// Byte offset of the start of line `line` (clamped to last line).
    fn line_start(&self, line: usize) -> usize {
        if line == 0 {
            return 0;
        }
        let mut seen = 0;
        for (i, b) in self.text.bytes().enumerate() {
            if b == b'\n' {
                seen += 1;
                if seen == line {
                    return i + 1;
                }
            }
        }
        // line beyond the last → start of the last line
        self.text.rfind('\n').map(|i| i + 1).unwrap_or(0)
    }
    /// Byte offset just before line `line`'s newline (or EOF for the last line).
    fn line_end(&self, line: usize) -> usize {
        let start = self.line_start(line);
        match self.text[start..].find('\n') {
            Some(rel) => start + rel,
            None => self.text.len(),
        }
    }
    fn byte_at_col(&self, line: usize, col: usize) -> usize {
        let start = self.line_start(line);
        let end = self.line_end(line);
        let mut b = start;
        for (c, ch) in self.text[start..end].chars().enumerate() {
            if c == col {
                break;
            }
            b += ch.len_utf8();
        }
        b
    }
    fn col_at_byte(&self, byte: usize) -> usize {
        let line = self.text[..byte].bytes().filter(|&b| b == b'\n').count();
        self.text[self.line_start(line)..byte].chars().count()
    }
    fn prev_char_boundary(&self, byte: usize) -> usize {
        if byte == 0 {
            return 0;
        }
        let mut i = byte - 1;
        while !self.text.is_char_boundary(i) {
            i -= 1;
        }
        i
    }
    fn next_char_boundary(&self, byte: usize) -> usize {
        if byte >= self.text.len() {
            return self.text.len();
        }
        let mut i = byte + 1;
        while i < self.text.len() && !self.text.is_char_boundary(i) {
            i += 1;
        }
        i
    }
    fn char_before(&self, byte: usize) -> Option<char> {
        if byte == 0 {
            None
        } else {
            self.text[..byte].chars().next_back()
        }
    }
    fn char_at(&self, byte: usize) -> Option<char> {
        self.text[byte..].chars().next()
    }

    // ─── undo plumbing ──────────────────────────────────────────────
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            text: self.text.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
        }
    }
    /// Begin a fresh undo group for a mutation that is *about* to change text.
    fn checkpoint(&mut self) {
        self.redo.clear();
        self.in_insert_run = false;
        self.push_undo();
    }
    /// Begin / continue the coalescing group for typed characters.
    fn checkpoint_insert_run(&mut self) {
        self.redo.clear();
        if !self.in_insert_run {
            self.push_undo();
            self.in_insert_run = true;
        }
    }
    fn push_undo(&mut self) {
        self.undo.push(self.snapshot());
        if self.undo.len() > UNDO_LIMIT {
            self.undo.remove(0);
        }
    }
    fn restore(&mut self, s: Snapshot) {
        self.text = s.text;
        self.cursor = s.cursor.min(self.text.len());
        while !self.text.is_char_boundary(self.cursor) {
            self.cursor -= 1;
        }
        self.anchor = s.anchor.map(|a| a.min(self.text.len()));
        self.in_insert_run = false;
    }

    // ─── the interpreter ────────────────────────────────────────────
    pub fn apply(&mut self, op: EditOp, viewport_rows: usize, clip: &mut Clipboard) -> EditOutcome {
        let before_cursor = self.cursor;
        let before_len = self.text.len();
        let keep_goal_col = op_preserves_goal_col(&op);
        // Anything that isn't a typed character ends the coalescing undo run, so
        // a motion between two typing bursts splits them into separate undo steps.
        if !op_is_insert_char(&op) {
            self.in_insert_run = false;
        }
        let mut out = EditOutcome::default();
        self.apply_one(op, viewport_rows, clip, &mut out);
        out.cursor_moved |= self.cursor != before_cursor;
        out.buffer_changed |= self.text.len() != before_len;
        // Goal column tracks horizontal intent; vertical motions deliberately keep it.
        if !keep_goal_col {
            self.goal_col = self.col_at_byte(self.cursor);
        }
        out
    }

    fn apply_one(&mut self, op: EditOp, vp: usize, clip: &mut Clipboard, out: &mut EditOutcome) {
        use EditOp::*;
        match op {
            Repeat(n, inner) => {
                for _ in 0..n {
                    self.apply_one((*inner).clone(), vp, clip, out);
                }
            }

            // ── motion ──
            MoveLeft => self.move_horizontal(-1, false),
            MoveRight => self.move_horizontal(1, false),
            MoveUp => self.move_vertical(-1),
            MoveDown => self.move_vertical(1),
            PageUp => {
                for _ in 0..vp.max(1) {
                    self.move_vertical(-1);
                }
            }
            PageDown => {
                for _ in 0..vp.max(1) {
                    self.move_vertical(1);
                }
            }
            MoveWordRight => self.move_word_right(),
            MoveWordLeft => self.move_word_left(),
            MoveWordEnd => self.move_word_end(),
            MoveLineStart => self.cursor = self.line_start(self.current_line()),
            MoveLineFirstNonWs => {
                let line = self.current_line();
                let (s, e) = (self.line_start(line), self.line_end(line));
                let mut b = s;
                for ch in self.text[s..e].chars() {
                    if !ch.is_whitespace() {
                        break;
                    }
                    b += ch.len_utf8();
                }
                self.cursor = b;
            }
            MoveLineEnd => self.cursor = self.line_end(self.current_line()),
            MoveBufferStart => self.cursor = 0,
            MoveBufferEnd => self.cursor = self.text.len(),
            MoveToLine(n) => {
                let line = n.saturating_sub(1).min(self.line_count().saturating_sub(1));
                self.cursor = self.line_start(line);
            }

            // ── selection ──
            SelectStart => self.anchor = Some(self.cursor),
            SelectClear => self.anchor = None,
            SelectAll => {
                self.anchor = Some(0);
                self.cursor = self.text.len();
            }
            SelectLine => {
                let line = self.current_line();
                let start = self.line_start(line);
                let end = if self.line_end(line) < self.text.len() {
                    self.line_end(line) + 1 // include trailing newline
                } else {
                    self.line_end(line)
                };
                self.anchor = Some(start);
                self.cursor = end;
            }
            SelectWord => {
                let (lo, hi) = self.word_bounds_at(self.cursor);
                self.anchor = Some(lo);
                self.cursor = hi;
            }
            AddCursorBelow | AddCursorAbove => { /* multi-cursor: not yet */ }

            // ── text mutation ──
            InsertChar(c) => {
                self.delete_selection_if_any(out);
                self.checkpoint_insert_run();
                self.text.insert(self.cursor, c);
                self.cursor += c.len_utf8();
                out.buffer_changed = true;
            }
            InsertStr(s) => {
                if s.is_empty() {
                    return;
                }
                self.delete_selection_if_any(out);
                self.checkpoint();
                self.text.insert_str(self.cursor, &s);
                self.cursor += s.len();
                out.buffer_changed = true;
            }
            InsertNewline => {
                self.delete_selection_if_any(out);
                self.checkpoint();
                self.text.insert(self.cursor, '\n');
                self.cursor += 1;
                out.buffer_changed = true;
            }
            InsertNewlineBelow => {
                self.anchor = None;
                self.checkpoint();
                let line = self.current_line();
                let eol = self.line_end(line);
                self.text.insert(eol, '\n');
                self.cursor = eol + 1;
                out.buffer_changed = true;
            }
            InsertNewlineAbove => {
                self.anchor = None;
                self.checkpoint();
                let line = self.current_line();
                let bol = self.line_start(line);
                self.text.insert(bol, '\n');
                self.cursor = bol;
                out.buffer_changed = true;
            }
            Backspace => {
                if self.delete_selection_if_any(out) {
                    return;
                }
                if self.cursor == 0 {
                    return;
                }
                self.checkpoint();
                let prev = self.prev_char_boundary(self.cursor);
                self.text.replace_range(prev..self.cursor, "");
                self.cursor = prev;
                out.buffer_changed = true;
            }
            DeleteForward => {
                if self.delete_selection_if_any(out) {
                    return;
                }
                if self.cursor >= self.text.len() {
                    return;
                }
                self.checkpoint();
                let next = self.next_char_boundary(self.cursor);
                self.text.replace_range(self.cursor..next, "");
                out.buffer_changed = true;
            }
            DeleteWordLeft => {
                if self.delete_selection_if_any(out) {
                    return;
                }
                let target = self.word_left_target();
                if target == self.cursor {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(target..self.cursor, "");
                self.cursor = target;
                out.buffer_changed = true;
            }
            DeleteWordRight => {
                if self.delete_selection_if_any(out) {
                    return;
                }
                let target = self.word_right_target();
                if target == self.cursor {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(self.cursor..target, "");
                out.buffer_changed = true;
            }
            DeleteToLineStart => {
                let bol = self.line_start(self.current_line());
                if bol == self.cursor {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(bol..self.cursor, "");
                self.cursor = bol;
                out.buffer_changed = true;
            }
            DeleteToLineEnd => {
                let eol = self.line_end(self.current_line());
                if eol == self.cursor {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(self.cursor..eol, "");
                out.buffer_changed = true;
            }
            DeleteLine => {
                self.anchor = None;
                self.checkpoint();
                let line = self.current_line();
                let start = self.line_start(line);
                let has_newline_after = self.line_end(line) < self.text.len();
                if has_newline_after {
                    // delete the line and its trailing newline; the line below shifts up to `line`
                    let end = self.line_end(line) + 1;
                    self.text.replace_range(start..end, "");
                    self.cursor = start.min(self.text.len());
                } else if start > 0 {
                    // last line, not the first: remove the preceding newline + the line
                    let prev_line_start = self.line_start(line - 1);
                    let cut_from = self.prev_char_boundary(start);
                    self.text.replace_range(cut_from..self.text.len(), "");
                    self.cursor = prev_line_start.min(self.text.len());
                } else {
                    // the only line
                    self.text.clear();
                    self.cursor = 0;
                }
                out.buffer_changed = true;
            }
            DeleteSelection => {
                self.delete_selection_if_any(out);
            }
            ReplaceSelection(s) => {
                self.checkpoint();
                if let Some((lo, hi)) = self.selection() {
                    self.text.replace_range(lo..hi, &s);
                    self.cursor = lo + s.len();
                } else {
                    self.text.insert_str(self.cursor, &s);
                    self.cursor += s.len();
                }
                self.anchor = None;
                out.buffer_changed = true;
            }
            Indent => {
                self.checkpoint();
                let pad: String = " ".repeat(self.tab_width);
                let changed = self.for_each_selected_line(|ed, bol| {
                    ed.text.insert_str(bol, &pad);
                    pad.len() as isize
                });
                if changed {
                    out.buffer_changed = true;
                } else {
                    self.pop_checkpoint();
                }
            }
            Outdent => {
                self.checkpoint();
                let tw = self.tab_width;
                let changed = self.for_each_selected_line(|ed, bol| {
                    let mut remove = 0usize;
                    for ch in ed.text[bol..].chars().take(tw) {
                        if ch == ' ' {
                            remove += 1;
                        } else if ch == '\t' {
                            remove += 1;
                            break;
                        } else {
                            break;
                        }
                    }
                    if remove > 0 {
                        ed.text.replace_range(bol..bol + remove, "");
                    }
                    -(remove as isize)
                });
                if changed {
                    out.buffer_changed = true;
                } else {
                    self.pop_checkpoint();
                }
            }
            ToggleLineComment => {
                self.checkpoint();
                let token = self.comment_token.clone();
                let trimmed = token.trim_end().to_string();
                // Decide add vs remove from the first selected line's leading content.
                let first_line = self.text
                    [..self.selection().map(|(l, _)| l).unwrap_or(self.cursor)]
                    .bytes()
                    .filter(|&b| b == b'\n')
                    .count();
                let fl_start = self.line_start(first_line);
                let fl_indent_end = {
                    let mut b = fl_start;
                    for ch in self.line_str(first_line).chars() {
                        if ch.is_whitespace() {
                            b += ch.len_utf8();
                        } else {
                            break;
                        }
                    }
                    b
                };
                let already = self.text[fl_indent_end..].starts_with(&trimmed);
                let changed = self.for_each_selected_line(|ed, bol| {
                    // find indent end
                    let mut ie = bol;
                    for ch in ed.text[bol..].chars() {
                        if ch == '\n' {
                            return 0;
                        }
                        if ch.is_whitespace() {
                            ie += ch.len_utf8();
                        } else {
                            break;
                        }
                    }
                    if already {
                        if ed.text[ie..].starts_with(&token) {
                            ed.text.replace_range(ie..ie + token.len(), "");
                            -(token.len() as isize)
                        } else if ed.text[ie..].starts_with(&trimmed) {
                            ed.text.replace_range(ie..ie + trimmed.len(), "");
                            -(trimmed.len() as isize)
                        } else {
                            0
                        }
                    } else {
                        ed.text.insert_str(ie, &token);
                        token.len() as isize
                    }
                });
                if changed {
                    out.buffer_changed = true;
                } else {
                    self.pop_checkpoint();
                }
            }
            MoveLineUp => {
                let line = self.current_line();
                if line == 0 {
                    return;
                }
                self.checkpoint();
                self.swap_lines(line - 1, line);
                let col = self.goal_col;
                self.cursor = self.byte_at_col(line - 1, col);
                out.buffer_changed = true;
            }
            MoveLineDown => {
                let line = self.current_line();
                if line + 1 >= self.line_count() {
                    return;
                }
                self.checkpoint();
                self.swap_lines(line, line + 1);
                let col = self.goal_col;
                self.cursor = self.byte_at_col(line + 1, col);
                out.buffer_changed = true;
            }

            // ── clipboard / registers ──
            YankLine => {
                let line = self.current_line();
                let mut s = self.line_str(line).to_string();
                s.push('\n');
                clip.set(s.clone(), true);
                out.clipboard_set = Some(s);
                out.clipboard_linewise = true;
            }
            YankSelection => {
                if let Some((lo, hi)) = self.selection() {
                    let s = self.text[lo..hi].to_string();
                    clip.set(s.clone(), false);
                    out.clipboard_set = Some(s);
                }
            }
            CutSelection => {
                if let Some((lo, hi)) = self.selection() {
                    let s = self.text[lo..hi].to_string();
                    clip.set(s.clone(), false);
                    out.clipboard_set = Some(s);
                    self.checkpoint();
                    self.text.replace_range(lo..hi, "");
                    self.cursor = lo;
                    self.anchor = None;
                    out.buffer_changed = true;
                }
            }
            PasteAfter => {
                let s = clip.text();
                if s.is_empty() {
                    return;
                }
                self.checkpoint();
                if clip.is_linewise() {
                    let line = self.current_line();
                    let eol = self.line_end(line);
                    let insert_at = if eol < self.text.len() { eol + 1 } else { eol };
                    let mut payload = s.clone();
                    if eol >= self.text.len() && !self.text.is_empty() {
                        payload = format!("\n{}", s.trim_end_matches('\n'));
                    }
                    self.text.insert_str(insert_at, &payload);
                    self.cursor = if eol < self.text.len() {
                        insert_at
                    } else {
                        insert_at + 1
                    };
                } else {
                    let at = self.next_char_boundary(self.cursor).min(self.text.len());
                    self.text.insert_str(at, &s);
                    self.cursor = at + s.len();
                }
                self.anchor = None;
                out.buffer_changed = true;
            }
            PasteBefore => {
                let s = clip.text();
                if s.is_empty() {
                    return;
                }
                self.checkpoint();
                if clip.is_linewise() {
                    let line = self.current_line();
                    let bol = self.line_start(line);
                    self.text.insert_str(bol, &s);
                    self.cursor = bol;
                } else {
                    self.text.insert_str(self.cursor, &s);
                    self.cursor += s.len();
                }
                self.anchor = None;
                out.buffer_changed = true;
            }
            Paste => {
                let s = clip.text();
                if s.is_empty() {
                    return;
                }
                self.delete_selection_if_any(out);
                self.checkpoint();
                self.text.insert_str(self.cursor, &s);
                self.cursor += s.len();
                self.anchor = None;
                out.buffer_changed = true;
            }

            // ── history ──
            Undo => {
                if let Some(s) = self.undo.pop() {
                    let cur = self.snapshot();
                    self.redo.push(cur);
                    self.restore(s);
                    out.buffer_changed = true;
                }
            }
            Redo => {
                if let Some(s) = self.redo.pop() {
                    let cur = self.snapshot();
                    self.undo.push(cur);
                    self.restore(s);
                    out.buffer_changed = true;
                }
            }
        }
    }

    /// Pop the most recent undo snapshot back off — used when a "mutation" turned
    /// out to be a no-op so we don't leave a redundant undo step.
    fn pop_checkpoint(&mut self) {
        self.undo.pop();
    }

    /// Delete the active selection if there is one. Returns true if it deleted.
    fn delete_selection_if_any(&mut self, out: &mut EditOutcome) -> bool {
        if let Some((lo, hi)) = self.selection() {
            if hi > lo {
                self.checkpoint();
                self.text.replace_range(lo..hi, "");
                self.cursor = lo;
                self.anchor = None;
                out.buffer_changed = true;
                return true;
            }
            self.anchor = None;
        }
        false
    }

    // ─── motion internals ───────────────────────────────────────────
    fn move_horizontal(&mut self, dir: i32, _word: bool) {
        if dir < 0 {
            self.cursor = self.prev_char_boundary(self.cursor);
        } else {
            self.cursor = self.next_char_boundary(self.cursor);
        }
    }
    fn move_vertical(&mut self, dir: i32) {
        let line = self.current_line();
        let target = if dir < 0 {
            if line == 0 {
                return;
            }
            line - 1
        } else {
            if line + 1 >= self.line_count() {
                self.cursor = self.text.len();
                return;
            }
            line + 1
        };
        self.cursor = self.byte_at_col(target, self.goal_col);
    }

    fn move_word_right(&mut self) {
        let len = self.text.len();
        if self.cursor >= len {
            return;
        }
        let mut i = self.cursor;
        // skip the current run (whatever class the char under the cursor is, if not space)
        if let Some(c) = self.char_at(i)
            && class_of(c) != CharClass::Space
        {
            let cls = class_of(c);
            while i < len {
                match self.char_at(i) {
                    Some(c) if class_of(c) == cls => i = self.next_char_boundary(i),
                    _ => break,
                }
            }
        }
        // skip whitespace
        while i < len {
            match self.char_at(i) {
                Some(c) if class_of(c) == CharClass::Space => i = self.next_char_boundary(i),
                _ => break,
            }
        }
        self.cursor = i;
    }
    fn move_word_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let mut i = self.cursor;
        // step back over whitespace
        while i > 0 {
            match self.char_before(i) {
                Some(c) if class_of(c) == CharClass::Space => i = self.prev_char_boundary(i),
                _ => break,
            }
        }
        // step back over the run to its start
        if let Some(c) = self.char_before(i) {
            let cls = class_of(c);
            while i > 0 {
                match self.char_before(i) {
                    Some(c) if class_of(c) == cls => i = self.prev_char_boundary(i),
                    _ => break,
                }
            }
        }
        self.cursor = i;
    }
    fn move_word_end(&mut self) {
        let len = self.text.len();
        if self.cursor >= len {
            return;
        }
        let mut i = self.next_char_boundary(self.cursor);
        // skip whitespace
        while i < len {
            match self.char_at(i) {
                Some(c) if class_of(c) == CharClass::Space => i = self.next_char_boundary(i),
                _ => break,
            }
        }
        // advance to the end of this run
        if let Some(c) = self.char_at(i) {
            let cls = class_of(c);
            while i < len {
                let nxt = self.next_char_boundary(i);
                match self.char_at(nxt) {
                    Some(c) if class_of(c) == cls => i = nxt,
                    _ => break,
                }
            }
        }
        self.cursor = i;
    }
    fn word_left_target(&self) -> usize {
        let mut i = self.cursor;
        while i > 0 {
            match self.char_before(i) {
                Some(c) if class_of(c) == CharClass::Space => i = self.prev_char_boundary(i),
                _ => break,
            }
        }
        if let Some(c) = self.char_before(i) {
            let cls = class_of(c);
            while i > 0 {
                match self.char_before(i) {
                    Some(c) if class_of(c) == cls => i = self.prev_char_boundary(i),
                    _ => break,
                }
            }
        }
        i
    }
    fn word_right_target(&self) -> usize {
        let len = self.text.len();
        let mut i = self.cursor;
        if let Some(c) = self.char_at(i)
            && class_of(c) != CharClass::Space
        {
            let cls = class_of(c);
            while i < len {
                match self.char_at(i) {
                    Some(c) if class_of(c) == cls => i = self.next_char_boundary(i),
                    _ => break,
                }
            }
        }
        while i < len {
            match self.char_at(i) {
                Some(c) if class_of(c) == CharClass::Space => i = self.next_char_boundary(i),
                _ => break,
            }
        }
        i
    }
    fn word_bounds_at(&self, byte: usize) -> (usize, usize) {
        let cls = self
            .char_at(byte)
            .or_else(|| self.char_before(byte))
            .map(class_of)
            .unwrap_or(CharClass::Space);
        let mut lo = byte;
        while lo > 0 {
            match self.char_before(lo) {
                Some(c) if class_of(c) == cls => lo = self.prev_char_boundary(lo),
                _ => break,
            }
        }
        let mut hi = byte;
        while hi < self.text.len() {
            match self.char_at(hi) {
                Some(c) if class_of(c) == cls => hi = self.next_char_boundary(hi),
                _ => break,
            }
        }
        (lo, hi)
    }

    /// Run `f(self, byte_of_line_start)` for each line touched by the selection
    /// (or just the current line if there's no selection). `f` returns the byte
    /// delta it applied at that line so subsequent line starts shift correctly.
    /// Returns true if anything changed. The cursor is left at its old column on
    /// the same logical line.
    fn for_each_selected_line(&mut self, mut f: impl FnMut(&mut Self, usize) -> isize) -> bool {
        let (cur_line, cur_col) = self.row_col();
        let (first, last) = match self.selection() {
            Some((lo, hi)) => {
                let fl = self.text[..lo].bytes().filter(|&b| b == b'\n').count();
                // if the selection ends exactly at a line start, don't include that line
                let hi_line = self.text[..hi].bytes().filter(|&b| b == b'\n').count();
                let ll = if hi > lo && hi == self.line_start(hi_line) && hi_line > fl {
                    hi_line - 1
                } else {
                    hi_line
                };
                (fl, ll)
            }
            None => (cur_line, cur_line),
        };
        let mut changed = false;
        for line in first..=last {
            let bol = self.line_start(line);
            let delta = f(&mut *self, bol);
            if delta != 0 {
                changed = true;
            }
        }
        // restore cursor to (cur_line, cur_col), clamped
        self.cursor = self.byte_at_col(cur_line.min(self.line_count().saturating_sub(1)), cur_col);
        self.anchor = None;
        changed
    }

    fn swap_lines(&mut self, a: usize, b: usize) {
        debug_assert!(a < b);
        let a_start = self.line_start(a);
        let a_end = self.line_end(a);
        let b_start = self.line_start(b);
        let b_end = self.line_end(b);
        let a_text = self.text[a_start..a_end].to_string();
        let b_text = self.text[b_start..b_end].to_string();
        // replace b first (later in the string) so a's offsets stay valid
        self.text.replace_range(b_start..b_end, &a_text);
        self.text.replace_range(a_start..a_end, &b_text);
    }
}

// ─── tests ──────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit_op::EditOp::*;

    fn ed(s: &str) -> (Editor, Clipboard) {
        (Editor::new(s, 4), Clipboard::detached())
    }
    fn run(e: &mut Editor, c: &mut Clipboard, ops: &[EditOp]) {
        for op in ops {
            e.apply(op.clone(), 10, c);
        }
    }

    #[test]
    fn insert_and_undo_coalesce() {
        let (mut e, mut c) = ed("");
        run(
            &mut e,
            &mut c,
            &[InsertChar('a'), InsertChar('b'), InsertChar('c')],
        );
        assert_eq!(e.text(), "abc");
        e.apply(Undo, 10, &mut c);
        assert_eq!(e.text(), ""); // whole burst undone as one group
        e.apply(Redo, 10, &mut c);
        assert_eq!(e.text(), "abc");
    }

    #[test]
    fn motion_breaks_the_insert_run() {
        let (mut e, mut c) = ed("");
        run(&mut e, &mut c, &[InsertChar('a'), InsertChar('b')]);
        e.apply(MoveLeft, 10, &mut c);
        run(&mut e, &mut c, &[InsertChar('X')]);
        assert_eq!(e.text(), "aXb");
        e.apply(Undo, 10, &mut c);
        assert_eq!(e.text(), "ab");
        e.apply(Undo, 10, &mut c);
        assert_eq!(e.text(), "");
    }

    #[test]
    fn new_edit_clears_redo() {
        let (mut e, mut c) = ed("");
        run(&mut e, &mut c, &[InsertChar('a')]);
        e.apply(Undo, 10, &mut c);
        run(&mut e, &mut c, &[InsertChar('b')]);
        e.apply(Redo, 10, &mut c); // nothing to redo
        assert_eq!(e.text(), "b");
    }

    #[test]
    fn utf8_boundaries() {
        let (mut e, mut c) = ed("héllo");
        // move right twice → past 'h' and 'é'
        e.apply(MoveRight, 10, &mut c);
        e.apply(MoveRight, 10, &mut c);
        assert_eq!(e.cursor(), "hé".len());
        e.apply(Backspace, 10, &mut c);
        assert_eq!(e.text(), "hllo");
    }

    #[test]
    fn word_motions() {
        let (mut e, mut c) = ed("foo bar.baz qux");
        e.apply(MoveWordRight, 10, &mut c);
        assert_eq!(e.cursor(), "foo ".len()); // start of "bar"
        e.apply(MoveWordRight, 10, &mut c);
        assert_eq!(e.cursor(), "foo bar".len()); // start of "."
        e.apply(MoveWordRight, 10, &mut c);
        assert_eq!(e.cursor(), "foo bar.".len()); // start of "baz"
        e.apply(MoveWordLeft, 10, &mut c);
        assert_eq!(e.cursor(), "foo bar".len());
    }

    #[test]
    fn vertical_keeps_goal_col() {
        let (mut e, mut c) = ed("abcdef\nxy\nlongline");
        // go to col 5 on line 0
        for _ in 0..5 {
            e.apply(MoveRight, 10, &mut c);
        }
        assert_eq!(e.row_col(), (0, 5));
        e.apply(MoveDown, 10, &mut c); // line 1 only has 2 chars → clamp to col 2
        assert_eq!(e.row_col(), (1, 2));
        e.apply(MoveDown, 10, &mut c); // line 2 long enough → back to col 5
        assert_eq!(e.row_col(), (2, 5));
    }

    #[test]
    fn line_nav_and_to_line() {
        let (mut e, mut c) = ed("one\n  two\nthree");
        e.apply(MoveToLine(2), 10, &mut c);
        assert_eq!(e.row_col(), (1, 0));
        e.apply(MoveLineFirstNonWs, 10, &mut c);
        assert_eq!(e.row_col(), (1, 2));
        e.apply(MoveLineEnd, 10, &mut c);
        assert_eq!(e.row_col(), (1, 5));
        e.apply(MoveBufferEnd, 10, &mut c);
        assert_eq!(e.cursor(), e.text().len());
        e.apply(MoveBufferStart, 10, &mut c);
        assert_eq!(e.cursor(), 0);
    }

    #[test]
    fn selection_and_replace() {
        let (mut e, mut c) = ed("hello world");
        e.apply(SelectStart, 10, &mut c);
        for _ in 0..5 {
            e.apply(MoveRight, 10, &mut c);
        }
        assert_eq!(e.selection(), Some((0, 5)));
        e.apply(ReplaceSelection("HI".to_string()), 10, &mut c);
        assert_eq!(e.text(), "HI world");
        e.apply(Undo, 10, &mut c);
        assert_eq!(e.text(), "hello world");
    }

    #[test]
    fn delete_selection_via_typing() {
        let (mut e, mut c) = ed("abcdef");
        e.apply(SelectStart, 10, &mut c);
        for _ in 0..3 {
            e.apply(MoveRight, 10, &mut c);
        }
        e.apply(InsertChar('Z'), 10, &mut c); // replaces "abc"
        assert_eq!(e.text(), "Zdef");
    }

    #[test]
    fn delete_line_middle_first_last() {
        let (mut e, mut c) = ed("a\nb\nc");
        e.apply(MoveToLine(2), 10, &mut c);
        e.apply(DeleteLine, 10, &mut c);
        assert_eq!(e.text(), "a\nc");
        // delete first
        e.apply(MoveBufferStart, 10, &mut c);
        e.apply(DeleteLine, 10, &mut c);
        assert_eq!(e.text(), "c");
        // delete last (== only)
        e.apply(DeleteLine, 10, &mut c);
        assert_eq!(e.text(), "");
    }

    #[test]
    fn yank_line_and_paste() {
        let (mut e, mut c) = ed("alpha\nbeta");
        e.apply(YankLine, 10, &mut c); // yanks "alpha\n" linewise
        e.apply(PasteAfter, 10, &mut c); // after line 0
        assert_eq!(e.text(), "alpha\nalpha\nbeta");
        e.apply(MoveBufferStart, 10, &mut c);
        e.apply(PasteBefore, 10, &mut c);
        assert_eq!(e.text(), "alpha\nalpha\nalpha\nbeta");
    }

    #[test]
    fn cut_copy_paste_charwise() {
        let (mut e, mut c) = ed("foobar");
        e.apply(SelectStart, 10, &mut c);
        for _ in 0..3 {
            e.apply(MoveRight, 10, &mut c);
        }
        e.apply(CutSelection, 10, &mut c); // cut "foo"
        assert_eq!(e.text(), "bar");
        e.apply(MoveBufferEnd, 10, &mut c);
        e.apply(Paste, 10, &mut c);
        assert_eq!(e.text(), "barfoo");
    }

    #[test]
    fn repeat_op() {
        let (mut e, mut c) = ed("alpha beta gamma delta");
        e.apply(Repeat(3, Box::new(MoveWordRight)), 10, &mut c);
        assert_eq!(e.cursor(), "alpha beta gamma ".len());
    }

    #[test]
    fn indent_outdent_selection() {
        let (mut e, mut c) = ed("a\nb\nc");
        e.apply(SelectAll, 10, &mut c);
        e.apply(Indent, 10, &mut c);
        assert_eq!(e.text(), "    a\n    b\n    c");
        e.apply(SelectAll, 10, &mut c);
        e.apply(Outdent, 10, &mut c);
        assert_eq!(e.text(), "a\nb\nc");
    }

    #[test]
    fn toggle_line_comment() {
        let (mut e, mut c) = ed("foo();\nbar();");
        e.apply(SelectAll, 10, &mut c);
        e.apply(ToggleLineComment, 10, &mut c);
        assert_eq!(e.text(), "// foo();\n// bar();");
        e.apply(SelectAll, 10, &mut c);
        e.apply(ToggleLineComment, 10, &mut c);
        assert_eq!(e.text(), "foo();\nbar();");
    }

    #[test]
    fn move_line_up_down() {
        let (mut e, mut c) = ed("one\ntwo\nthree");
        e.apply(MoveToLine(2), 10, &mut c); // on "two"
        e.apply(MoveLineUp, 10, &mut c);
        assert_eq!(e.text(), "two\none\nthree");
        e.apply(MoveLineDown, 10, &mut c);
        assert_eq!(e.text(), "one\ntwo\nthree");
    }

    #[test]
    fn open_lines() {
        let (mut e, mut c) = ed("a\nb");
        e.apply(InsertNewlineBelow, 10, &mut c);
        assert_eq!(e.text(), "a\n\nb");
        assert_eq!(e.row_col(), (1, 0));
        e.apply(MoveBufferStart, 10, &mut c);
        e.apply(InsertNewlineAbove, 10, &mut c);
        assert_eq!(e.text(), "\na\n\nb");
        assert_eq!(e.row_col(), (0, 0));
    }
}
