//! The text-editing core: a `String` + a byte cursor + selection anchor + undo/redo,
//! and `apply(EditOp)` — the single interpreter every input handler funnels through.
//!
//! Storage is a plain `String` (fine for typical source files; all mutation is
//! funnelled through `apply` so a rope can replace this later without touching
//! call sites). Columns are counted in **chars** for now (display-width / tabs /
//! CJK are a P2 refinement). All byte offsets are kept on char boundaries.

use std::path::{Path, PathBuf};

use crate::clipboard::Clipboard;
use crate::edit_op::{EditOp, EditOutcome};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct Snapshot {
    text: String,
    cursor: usize,
    anchor: Option<usize>,
}

/// On-disk shape of [`Editor`]'s undo + redo stacks plus the text those stacks
/// are valid against. Pinned with `text_hash` so a file edited outside mnml
/// (or by another tool) silently discards the stale history rather than
/// restoring offsets that no longer map onto the buffer.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub(crate) struct PersistedHistory {
    /// FNV-1a 64-bit hash of the file's text at save time.
    text_hash: u64,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
}

/// Cap on how many snapshots get written to disk per file — separate from the
/// in-memory [`UNDO_LIMIT`] so the on-disk file doesn't bloat for a buffer
/// you've heavily edited in one sitting.
pub(crate) const PERSISTED_UNDO_LIMIT: usize = 100;

/// Where to write `path`'s persistent undo file inside `workspace`.
/// `<workspace>/.mnml/undo/<fnv-hex>.json` — fnv hash of the absolute path,
/// keeping the filename stable across renames-as-text (a rename of the file
/// on disk would change the path → new history file).
pub fn undo_path_for(workspace: &Path, file_path: &Path) -> PathBuf {
    let key = file_path.to_string_lossy();
    let hash = fnv1a_64(&key);
    workspace
        .join(".mnml")
        .join("undo")
        .join(format!("{hash:016x}.json"))
}

/// Best-effort write of `editor`'s history to `path`. I/O errors are swallowed
/// (this is a UX nicety, not load-bearing) but the function returns whether
/// the write succeeded so callers can log + tests can assert.
pub fn save_history_to(editor: &Editor, path: &Path) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    if std::fs::create_dir_all(parent).is_err() {
        return false;
    }
    let snapshot = editor.snapshot_history();
    let Ok(json) = serde_json::to_string(&snapshot) else {
        return false;
    };
    std::fs::write(path, json).is_ok()
}

/// Best-effort load of an undo file at `path` into `editor`. Returns `true` if
/// the snapshot loaded AND its text-hash matched the editor's current text
/// (i.e. the file wasn't changed outside mnml since the history was saved).
/// Missing / corrupt / mismatched files just return `false`.
pub fn load_history_from(editor: &mut Editor, path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(h) = serde_json::from_str::<PersistedHistory>(&text) else {
        return false;
    };
    editor.restore_history(h)
}

/// Per-line `(col, depth)` for every `()[]{}` bracket in `text`. Depth is the
/// nesting level — `0` for the outermost pair, `1` for nested inside, etc. —
/// shared across `(`, `[`, `{` (no kind-mismatch tracking; the renderer just
/// wants a stable color cycle, not strict balance). Used by the editor's
/// rainbow-brackets renderer.
///
/// Cheap to call (~one walk of the buffer); the editor view skips it when
/// `[ui] bracket_rainbow` is off so files without rainbow pay nothing.
pub fn bracket_depths_per_line(text: &str) -> Vec<Vec<(usize, u32)>> {
    let mut out: Vec<Vec<(usize, u32)>> = vec![Vec::new()];
    let mut depth: u32 = 0;
    let mut col: usize = 0;
    for c in text.chars() {
        if c == '\n' {
            out.push(Vec::new());
            col = 0;
            continue;
        }
        match c {
            '(' | '[' | '{' => {
                out.last_mut().unwrap().push((col, depth));
                depth = depth.saturating_add(1);
            }
            ')' | ']' | '}' => {
                depth = depth.saturating_sub(1);
                out.last_mut().unwrap().push((col, depth));
            }
            _ => {}
        }
        col += 1;
    }
    out
}

/// FNV-1a 64-bit — a fast, dependency-free string hash. Stable across runs;
/// not cryptographic. Good enough as a "did the file change?" guard.
pub(crate) fn fnv1a_64(s: &str) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h = FNV_OFFSET;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
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
        MoveUp | MoveDown | PageUp | PageDown | HalfPageUp | HalfPageDown => true,
        Repeat(_, inner) => op_preserves_goal_col(inner),
        _ => false,
    }
}

/// Matching closing char for an auto-pair open char, or `None` if `c` isn't a
/// configured open. Single-char pairs only.
fn auto_pair_close(c: char) -> Option<char> {
    match c {
        '(' => Some(')'),
        '[' => Some(']'),
        '{' => Some('}'),
        '"' => Some('"'),
        '\'' => Some('\''),
        '`' => Some('`'),
        _ => None,
    }
}

/// True if `c` is one of the close chars our auto-pair would have inserted.
/// (Used for the "skip over an auto-inserted close" shortcut.)
fn is_auto_pair_close(c: char) -> bool {
    matches!(c, ')' | ']' | '}' | '"' | '\'' | '`')
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
    /// Auto-insert the matching close char after `(`/`[`/`{`/`"`/`'`/`` ` ``.
    /// Toggled by `[editor] auto_pair`; off in `Editor::new` so unit tests have
    /// vanilla behavior.
    pub auto_pair: bool,
    /// On `Enter`, carry forward the previous line's leading whitespace
    /// (`auto_indent`). Off in `Editor::new` so unit tests get vanilla
    /// newlines; on by default for real buffers via `[editor] auto_indent`.
    pub auto_indent: bool,
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
            auto_pair: false,
            auto_indent: false,
        }
    }

    pub fn empty() -> Self {
        Editor::new(String::new(), 4)
    }

    // ─── persistent undo ────────────────────────────────────────────
    /// Take a serializable snapshot of the current undo + redo stacks pinned
    /// to the current text. The on-disk file is keyed by path's hash by the
    /// caller; we only return the bytes here so the I/O layer can decide.
    pub(crate) fn snapshot_history(&self) -> PersistedHistory {
        let take_tail = |v: &[Snapshot]| -> Vec<Snapshot> {
            let n = v.len();
            let start = n.saturating_sub(PERSISTED_UNDO_LIMIT);
            v[start..].to_vec()
        };
        PersistedHistory {
            text_hash: fnv1a_64(&self.text),
            undo: take_tail(&self.undo),
            redo: take_tail(&self.redo),
        }
    }

    /// Restore an undo+redo stack previously produced by [`Self::snapshot_history`].
    /// Returns `true` if the text-hash matches (so the offsets in the
    /// snapshots still map onto the current buffer); returns `false` and
    /// leaves history empty otherwise.
    pub(crate) fn restore_history(&mut self, h: PersistedHistory) -> bool {
        if h.text_hash != fnv1a_64(&self.text) {
            return false;
        }
        self.undo = h.undo;
        self.redo = h.redo;
        // Cap the in-memory stack at the runtime UNDO_LIMIT in case the
        // disk constant ever exceeded it.
        let trim = |v: &mut Vec<Snapshot>| {
            if v.len() > UNDO_LIMIT {
                let drop = v.len() - UNDO_LIMIT;
                v.drain(..drop);
            }
        };
        trim(&mut self.undo);
        trim(&mut self.redo);
        true
    }

    // ─── accessors ──────────────────────────────────────────────────
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// The identifier under the cursor — the maximal run of `[A-Za-z0-9_]`
    /// chars containing the cursor byte. Empty when the cursor isn't on or
    /// adjacent to an identifier char. Used by the "highlight word under
    /// cursor" view feature.
    pub fn word_under_cursor(&self) -> &str {
        let bytes = self.text.as_bytes();
        let len = self.text.len();
        let cur = self.cursor.min(len);
        let is_id = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
        // Cursor may be one past the last id char (typical insert mode); the
        // standard editor-word check is "cursor or cursor-1 sits on an id char".
        if cur == 0 && (cur >= len || !is_id(bytes[0])) {
            return "";
        }
        if cur >= len && (cur == 0 || !is_id(bytes[cur - 1])) {
            return "";
        }
        if cur < len && !is_id(bytes[cur]) && (cur == 0 || !is_id(bytes[cur - 1])) {
            return "";
        }
        let mut start = cur;
        while start > 0 && is_id(bytes[start - 1]) {
            start -= 1;
        }
        let mut end = cur;
        while end < len && is_id(bytes[end]) {
            end += 1;
        }
        &self.text[start..end]
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
    /// The selected text, or `""` when there's no selection.
    pub fn selected_text(&self) -> String {
        self.selection()
            .map(|(lo, hi)| self.text[lo..hi].to_string())
            .unwrap_or_default()
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

    /// True when auto-pair should fire — i.e. the next char is "empty space"
    /// (newline, whitespace, end-of-buffer, or a closing bracket / quote). If
    /// the next char is a word char we'd be wrapping live code, so don't.
    fn next_char_allows_pair(&self) -> bool {
        match self.text[self.cursor..].chars().next() {
            None => true,
            Some(c) if c.is_whitespace() => true,
            Some(')' | ']' | '}' | '>' | ',' | ';' | ':') => true,
            _ => false,
        }
    }

    /// True if the next char in the buffer is exactly `c` (used to skip over
    /// an already-auto-paired close char).
    fn cursor_on_char(&self, c: char) -> bool {
        self.text[self.cursor..].starts_with(c)
    }

    /// `(row, col)` of the bracket that matches the one under the cursor, or
    /// `None` if the cursor isn't on a bracket. Used by `editor.bracket_match`
    /// (`Ctrl+]`) to jump to the pair, and by the editor renderer to paint a
    /// match-highlight.
    pub fn bracket_match(&self) -> Option<(usize, usize)> {
        let here = self.text[self.cursor..].chars().next()?;
        let (open, close, forward) = match here {
            '(' => ('(', ')', true),
            '[' => ('[', ']', true),
            '{' => ('{', '}', true),
            ')' => ('(', ')', false),
            ']' => ('[', ']', false),
            '}' => ('{', '}', false),
            _ => return None,
        };
        const BUDGET: usize = 50_000;
        let (cur_row, cur_col) = self.row_col();
        if forward {
            let mut depth: usize = 1;
            let mut row = cur_row;
            let mut col = cur_col + 1;
            let mut iter = self.text[self.cursor + here.len_utf8()..].chars();
            for _ in 0..BUDGET {
                let ch = iter.next()?;
                if ch == '\n' {
                    row += 1;
                    col = 0;
                    continue;
                }
                if ch == open {
                    depth += 1;
                } else if ch == close {
                    depth -= 1;
                    if depth == 0 {
                        return Some((row, col));
                    }
                }
                col += 1;
            }
            None
        } else {
            let prefix = &self.text[..self.cursor];
            let mut chars: Vec<char> = prefix.chars().collect();
            let mut row = 0usize;
            let mut col = 0usize;
            let mut positions: Vec<(usize, usize)> = Vec::with_capacity(chars.len());
            for ch in &chars {
                positions.push((row, col));
                if *ch == '\n' {
                    row += 1;
                    col = 0;
                } else {
                    col += 1;
                }
            }
            let take = chars.len().min(BUDGET);
            let start = chars.len() - take;
            chars.drain(..start);
            let positions = &positions[start..];
            let mut depth: usize = 1;
            for (i, ch) in chars.iter().enumerate().rev() {
                if *ch == close {
                    depth += 1;
                } else if *ch == open {
                    depth -= 1;
                    if depth == 0 {
                        return Some(positions[i]);
                    }
                }
            }
            None
        }
    }

    /// The leading whitespace (' ' / '\t') of the current line, up to the
    /// cursor — what `auto_indent` carries forward when Enter is pressed mid-
    /// line. (If the cursor sits inside the indent, only the chars before it
    /// are copied — typing Enter doesn't *expand* the indent.)
    fn leading_indent_of_line_to_cursor(&self) -> String {
        let line = self.current_line();
        let bol = self.line_start(line);
        let mut out = String::new();
        for ch in self.text[bol..self.cursor].chars() {
            if ch == ' ' || ch == '\t' {
                out.push(ch);
            } else {
                break;
            }
        }
        out
    }

    /// The leading whitespace of `line`, irrespective of the cursor — used by
    /// `InsertNewlineBelow` (vim `o`), which opens a fresh line *below* the
    /// current one and wants its full indent.
    fn leading_indent_of_line(&self, line: usize) -> String {
        let mut out = String::new();
        for ch in self.line_str(line).chars() {
            if ch == ' ' || ch == '\t' {
                out.push(ch);
            } else {
                break;
            }
        }
        out
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
            HalfPageUp => {
                for _ in 0..(vp / 2).max(1) {
                    self.move_vertical(-1);
                }
            }
            HalfPageDown => {
                for _ in 0..(vp / 2).max(1) {
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
                // Auto-pair: typing `(` / `[` / `{` / `"` / `'` / `` ` `` inserts
                // the close char after the cursor when it makes sense (the next
                // char is end-of-line, whitespace, or another closer). When the
                // user types the same close char while the cursor sits *on*
                // an auto-inserted close, we skip over it instead of doubling
                // it up (`""` → type `"` → still `""`, cursor moved past).
                let close = auto_pair_close(c);
                if self.auto_pair
                    && let Some(closer) = close
                    && self.next_char_allows_pair()
                {
                    self.text.insert(self.cursor, c);
                    self.cursor += c.len_utf8();
                    self.text.insert(self.cursor, closer);
                    // Leave the cursor between the pair.
                    out.buffer_changed = true;
                } else if self.auto_pair && is_auto_pair_close(c) && self.cursor_on_char(c) {
                    // Skip over the auto-inserted close: just move past it.
                    self.cursor += c.len_utf8();
                } else {
                    self.text.insert(self.cursor, c);
                    self.cursor += c.len_utf8();
                    out.buffer_changed = true;
                }
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
                let indent = if self.auto_indent {
                    self.leading_indent_of_line_to_cursor()
                } else {
                    String::new()
                };
                self.text.insert(self.cursor, '\n');
                self.cursor += 1;
                if !indent.is_empty() {
                    self.text.insert_str(self.cursor, &indent);
                    self.cursor += indent.len();
                }
                out.buffer_changed = true;
            }
            InsertNewlineBelow => {
                self.anchor = None;
                self.checkpoint();
                let line = self.current_line();
                let eol = self.line_end(line);
                let indent = if self.auto_indent {
                    self.leading_indent_of_line(line)
                } else {
                    String::new()
                };
                self.text.insert(eol, '\n');
                self.cursor = eol + 1;
                if !indent.is_empty() {
                    self.text.insert_str(self.cursor, &indent);
                    self.cursor += indent.len();
                }
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
                // Smart pair-backspace: when auto-pair is on and the cursor
                // sits between a paired `()` / `[]` / `""` etc., delete both
                // chars in one keystroke (so the undo of an auto-pair insert
                // is a single backspace).
                let pair_close = self.text[prev..self.cursor]
                    .chars()
                    .next()
                    .and_then(auto_pair_close);
                let next_byte = self.next_char_boundary(self.cursor);
                let next_char = self.text[self.cursor..next_byte].chars().next();
                if self.auto_pair
                    && let Some(closer) = pair_close
                    && next_char == Some(closer)
                {
                    self.text.replace_range(prev..next_byte, "");
                    self.cursor = prev;
                    out.buffer_changed = true;
                    return;
                }
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
            ReplaceRange { start, end, text } => {
                let len = self.text.len();
                let start = start.min(len);
                let end = end.min(len).max(start);
                if self.text.is_char_boundary(start) && self.text.is_char_boundary(end) {
                    self.checkpoint();
                    self.text.replace_range(start..end, &text);
                    self.cursor = start + text.len();
                    self.anchor = None;
                    out.buffer_changed = true;
                }
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
            DuplicateLine => {
                self.checkpoint();
                let line = self.current_line();
                let bol = self.line_start(line);
                let eol = self.line_end(line);
                // Insert `\n<line-text>` right after the current line content.
                // (Works for the last line — no trailing newline needed beyond
                // what gets inserted.)
                let body = self.text[bol..eol].to_string();
                self.text.insert(eol, '\n');
                self.text.insert_str(eol + 1, &body);
                // Move the cursor to the same column on the new line.
                let col = self.col_at_byte(self.cursor);
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

    #[test]
    fn auto_pair_inserts_close_and_keeps_cursor_between() {
        let (mut e, mut c) = ed("");
        e.auto_pair = true;
        e.apply(InsertChar('('), 10, &mut c);
        assert_eq!(e.text(), "()");
        assert_eq!(e.cursor(), 1);
    }

    #[test]
    fn auto_pair_skips_over_existing_close() {
        let (mut e, mut c) = ed("");
        e.auto_pair = true;
        e.apply(InsertChar('('), 10, &mut c); // → "()" with cursor at 1
        // Typing the close char while sitting on it: just step over.
        e.apply(InsertChar(')'), 10, &mut c);
        assert_eq!(e.text(), "()");
        assert_eq!(e.cursor(), 2);
    }

    #[test]
    fn auto_pair_skipped_when_next_char_is_word() {
        // Typing `(` right before a word — we'd be wrapping live code, so don't.
        let (mut e, mut c) = ed("name");
        e.auto_pair = true;
        e.apply(InsertChar('('), 10, &mut c);
        assert_eq!(e.text(), "(name");
        assert_eq!(e.cursor(), 1);
    }

    #[test]
    fn duplicate_line_inserts_copy_below() {
        let (mut e, mut c) = ed("foo\nbar");
        e.apply(MoveBufferStart, 10, &mut c);
        e.apply(DuplicateLine, 10, &mut c);
        assert_eq!(e.text(), "foo\nfoo\nbar");
        // Cursor moved to the duplicate (same col on the new line).
        assert_eq!(e.row_col().0, 1);
    }

    #[test]
    fn duplicate_last_line_no_trailing_newline() {
        let (mut e, mut c) = ed("only");
        e.apply(DuplicateLine, 10, &mut c);
        assert_eq!(e.text(), "only\nonly");
    }

    #[test]
    fn word_under_cursor_basic() {
        let (mut e, _) = ed("let foo = bar;\nfoo()");
        // Cursor at start — on 'l'.
        assert_eq!(e.word_under_cursor(), "let");
        // After "let "...
        e.place_cursor(0, 4);
        assert_eq!(e.word_under_cursor(), "foo");
        // On the `=` — empty.
        e.place_cursor(0, 8);
        assert_eq!(e.word_under_cursor(), "");
        // On line 2, cursor at "f" of "foo()".
        e.place_cursor(1, 0);
        assert_eq!(e.word_under_cursor(), "foo");
        // After the open paren — not in a word.
        e.place_cursor(1, 4);
        assert_eq!(e.word_under_cursor(), "");
    }

    #[test]
    fn bracket_match_open_to_close() {
        let (e, _) = ed("fn f() { x }");
        // Cursor at 0 — not on a bracket.
        assert_eq!(e.bracket_match(), None);
        // Place cursor on the `(`.
        let mut e = e;
        e.place_cursor(0, 4);
        let m = e.bracket_match().unwrap();
        assert_eq!(m, (0, 5)); // the `)` is at col 5
    }

    #[test]
    fn bracket_match_across_lines() {
        let mut e = ed("{\n  a\n  b\n}").0;
        // Place cursor on the `}` (row 3, col 0).
        e.place_cursor(3, 0);
        let m = e.bracket_match().unwrap();
        assert_eq!(m, (0, 0)); // matches the `{`
    }

    #[test]
    fn smart_pair_backspace_deletes_both() {
        let (mut e, mut c) = ed("");
        e.auto_pair = true;
        e.apply(InsertChar('('), 10, &mut c); // → "()" cursor at 1
        e.apply(Backspace, 10, &mut c);
        assert_eq!(e.text(), "");
        assert_eq!(e.cursor(), 0);
    }

    #[test]
    fn pair_backspace_skipped_when_no_pair() {
        // `(x` — backspace just deletes the `(`, not the trailing `x`.
        let (mut e, mut c) = ed("(x");
        e.auto_pair = true;
        e.apply(MoveLineStart, 10, &mut c);
        e.apply(MoveRight, 10, &mut c); // cursor between `(` and `x`
        e.apply(Backspace, 10, &mut c);
        assert_eq!(e.text(), "x");
    }

    #[test]
    fn auto_indent_carries_leading_whitespace() {
        let (mut e, mut c) = ed("    let x = 1;");
        e.auto_indent = true;
        // Cursor at end of line.
        e.apply(MoveLineEnd, 10, &mut c);
        e.apply(InsertNewline, 10, &mut c);
        // The new line starts with the same 4-space indent.
        assert_eq!(e.text(), "    let x = 1;\n    ");
    }

    #[test]
    fn auto_indent_only_copies_chars_before_cursor() {
        // Mid-line Enter shouldn't *expand* the indent — only the indent chars
        // before the split point carry forward.
        let (mut e, mut c) = ed("    abc");
        e.auto_indent = true;
        // Place cursor between the two leading spaces.
        e.place_cursor(0, 2);
        e.apply(InsertNewline, 10, &mut c);
        // The split leaves "  " on line 0, "  abc" on line 1; line 1's leading
        // indent (copied from line 0 prefix) is two spaces.
        assert_eq!(e.text(), "  \n    abc");
    }

    #[test]
    fn auto_indent_off_by_default() {
        let (mut e, mut c) = ed("    hi");
        e.apply(MoveLineEnd, 10, &mut c);
        e.apply(InsertNewline, 10, &mut c);
        assert_eq!(e.text(), "    hi\n");
    }

    #[test]
    fn auto_pair_off_by_default() {
        let (mut e, mut c) = ed("");
        e.apply(InsertChar('('), 10, &mut c);
        assert_eq!(e.text(), "(");
        assert_eq!(e.cursor(), 1);
    }

    #[test]
    fn persistent_undo_round_trips() {
        let d = tempfile::tempdir().unwrap();
        let file = d.path().join("a.txt");
        std::fs::write(&file, "abc").unwrap();
        let undo_path = undo_path_for(d.path(), &file);

        // Editor over the file; type a few chars to build an undo stack.
        let (mut e, mut c) = ed("abc");
        e.apply(MoveBufferEnd, 10, &mut c);
        for ch in "DE".chars() {
            e.apply(InsertChar(ch), 10, &mut c);
        }
        e.apply(MoveLeft, 10, &mut c); // break the insert run so a snapshot lands
        assert_eq!(e.text(), "abcDE");
        assert!(e.can_undo());

        // Save it.
        assert!(save_history_to(&e, &undo_path));
        assert!(undo_path.exists());

        // Fresh editor over the same text — undo stack empty until restore.
        let (mut e2, _c) = ed("abcDE");
        assert!(!e2.can_undo());
        assert!(load_history_from(&mut e2, &undo_path));
        assert!(e2.can_undo());

        // Undo collapses back to "abc" — same as the original editor would.
        let mut c2 = Clipboard::detached();
        e2.apply(Undo, 10, &mut c2);
        assert_eq!(e2.text(), "abc");
    }

    #[test]
    fn persistent_undo_rejects_when_text_drifts() {
        let d = tempfile::tempdir().unwrap();
        let file = d.path().join("a.txt");
        let undo_path = undo_path_for(d.path(), &file);

        let (mut e, mut c) = ed("foo");
        e.apply(InsertChar('!'), 10, &mut c);
        e.apply(MoveLeft, 10, &mut c);
        assert!(save_history_to(&e, &undo_path));

        // Fresh editor over a *different* text (file changed outside mnml).
        let (mut e2, _c) = ed("totally different");
        assert!(!load_history_from(&mut e2, &undo_path));
        assert!(!e2.can_undo());
    }

    #[test]
    fn bracket_depths_track_nesting() {
        // ((a)) on one line — depths 0, 1, 1, 0.
        let d = bracket_depths_per_line("((a))");
        assert_eq!(d, vec![vec![(0, 0), (1, 1), (3, 1), (4, 0)]]);
        // Multi-line + mixed brackets.
        let t = "fn f(x) {\n  [y]\n}";
        let d = bracket_depths_per_line(t);
        // line 0: `(` depth 0 at col 4, `)` depth 0 at col 6, `{` depth 0 at col 8
        assert_eq!(d[0], vec![(4, 0), (6, 0), (8, 0)]);
        // line 1: `[` depth 1 at col 2, `]` depth 1 at col 4
        assert_eq!(d[1], vec![(2, 1), (4, 1)]);
        // line 2: `}` depth 0
        assert_eq!(d[2], vec![(0, 0)]);
    }

    #[test]
    fn fnv1a_64_is_stable() {
        // Sanity — same input ⇒ same hash, different inputs ⇒ different.
        assert_eq!(fnv1a_64("hello"), fnv1a_64("hello"));
        assert_ne!(fnv1a_64("hello"), fnv1a_64("hellp"));
    }

    #[test]
    fn undo_path_includes_hex_hash() {
        let p = undo_path_for(Path::new("/ws"), Path::new("/ws/src/main.rs"));
        // .mnml/undo/<16 hex chars>.json
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        assert!(name.ends_with(".json"));
        assert_eq!(name.len(), 16 + ".json".len());
    }
}
