//! The text-editing core: a `String` + a byte cursor + selection anchor + undo/redo,
//! and `apply(EditOp)` — the single interpreter every input handler funnels through.
//!
//! Storage is a plain `String` (fine for typical source files; all mutation is
//! funnelled through `apply` so a rope can replace this later without touching
//! call sites). Columns are counted in **chars** for now (display-width / tabs /
//! CJK are a P2 refinement). All byte offsets are kept on char boundaries.

use std::path::{Path, PathBuf};

use crate::clipboard::Clipboard;
use crate::edit_op::{CaseTransform, EditOp, EditOutcome};

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
/// Closing char for a bracket-pair text object opener (`(` → `)`, `[` → `]`,
/// `{` → `}`). For any non-bracket the close is the same char (so `match_close_for`
/// composes safely with quotes if you ever call it on one).
fn match_close_for(open: char) -> char {
    match open {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        c => c,
    }
}

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
    /// `Some((anchor_byte, cursor_byte))` for the last selection that was
    /// "closed" (cleared, yanked, deleted, or changed). vim's `gv` restores
    /// it. `None` until the user has made at least one selection.
    last_selection: Option<(usize, usize)>,
    /// Vim visual-block mode anchor (byte position). When `Some`, the
    /// editor is in block-select mode: the rectangle is computed from
    /// `(byte_to_rowcol(block_anchor), byte_to_rowcol(cursor))` — min/max
    /// of rows + cols. The regular `anchor` is independent (block mode
    /// uses its own state so motions don't conflict with charwise).
    pub block_anchor: Option<usize>,
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
            block_anchor: None,
            auto_pair: false,
            auto_indent: false,
            last_selection: None,
        }
    }

    /// Capture the current selection as `last_selection` (the buffer's "gv
    /// memory"). Called by `Editor::apply` on ops that close the selection
    /// — Yank, Cut, ReplaceSelection, DeleteSelection, SelectClear.
    fn remember_selection(&mut self) {
        if let Some(anchor) = self.anchor
            && anchor != self.cursor
        {
            let (lo, hi) = if anchor < self.cursor {
                (anchor, self.cursor)
            } else {
                (self.cursor, anchor)
            };
            self.last_selection = Some((lo, hi));
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
    /// Set the selection to the byte range `[start, end)`. The cursor lands
    /// at `end` and the anchor at `start`. Clamps to text bounds. No-op when
    /// either offset isn't on a char boundary.
    pub fn set_selection(&mut self, start: usize, end: usize) {
        let len = self.text.len();
        let s = start.min(len);
        let e = end.min(len);
        if !self.text.is_char_boundary(s) || !self.text.is_char_boundary(e) {
            return;
        }
        self.anchor = Some(s);
        self.cursor = e;
        self.goal_col = self.col_at_byte(self.cursor);
    }

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
    /// The visual-block rectangle as `(rmin, cmin, rmax, cmax)` (inclusive,
    /// chars, 0-based). `None` when not in block-select mode.
    pub fn block_selection(&self) -> Option<(usize, usize, usize, usize)> {
        let anchor = self.block_anchor?;
        let (ar, ac) = self.row_col_at(anchor);
        let (cr, cc) = self.row_col();
        let (rmin, rmax) = (ar.min(cr), ar.max(cr));
        let (cmin, cmax) = (ac.min(cc), ac.max(cc));
        Some((rmin, cmin, rmax, cmax))
    }

    /// `(row, char_col)` of the byte position `byte` (clamped to text bounds).
    pub fn row_col_at(&self, byte: usize) -> (usize, usize) {
        let byte = byte.min(self.text.len());
        let row = self.text[..byte].bytes().filter(|&c| c == b'\n').count();
        let bol = self.line_start(row);
        let col = self.text[bol..byte].chars().count();
        (row, col)
    }

    /// Build the per-row byte ranges for the visual-block rectangle. Returns
    /// `Vec<(start_byte, end_byte)>` — one entry per row in `[rmin..=rmax]`.
    /// For each row, start is the byte of column `cmin` clamped to the
    /// line's content (or the line's EOL if the line is shorter than `cmin`),
    /// and end is the byte of column `cmax + 1` clamped to EOL. Rows shorter
    /// than `cmin` get an empty `(eol, eol)` entry (vim convention — no
    /// edit on those rows).
    pub fn block_ranges(
        &self,
        rmin: usize,
        cmin: usize,
        rmax: usize,
        cmax: usize,
    ) -> Vec<(usize, usize)> {
        let mut out = Vec::with_capacity(rmax - rmin + 1);
        let line_count = self.line_count();
        for r in rmin..=rmax.min(line_count.saturating_sub(1)) {
            let (s, e) = self.line_byte_range(r);
            let line_text = &self.text[s..e];
            let line_chars = line_text.chars().count();
            // Walk to char col cmin
            let start = if line_chars <= cmin {
                e
            } else {
                let mut b = s;
                for (col, ch) in line_text.chars().enumerate() {
                    if col == cmin {
                        break;
                    }
                    b += ch.len_utf8();
                }
                b
            };
            let end = if line_chars <= cmax {
                e
            } else {
                let mut b = s;
                for (col, ch) in line_text.chars().enumerate() {
                    if col == cmax + 1 {
                        break;
                    }
                    b += ch.len_utf8();
                }
                b
            };
            out.push((start, end));
        }
        out
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
    /// Public byte-offset → 0-based line index. Mirrors [`Self::current_line`]
    /// but for any caller (folds, click-to-place, etc.).
    pub fn line_at_byte(&self, byte: usize) -> usize {
        let byte = byte.min(self.text.len());
        self.text[..byte].bytes().filter(|&b| b == b'\n').count()
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
            MoveLineLastNonWs => {
                let line = self.current_line();
                let (s, e) = (self.line_start(line), self.line_end(line));
                let slice = &self.text[s..e];
                // walk back over trailing whitespace
                let mut last_nonws_end = s;
                let mut idx = s;
                for ch in slice.chars() {
                    let nxt = idx + ch.len_utf8();
                    if !ch.is_whitespace() {
                        last_nonws_end = nxt;
                    }
                    idx = nxt;
                }
                if last_nonws_end == s {
                    // blank line — go to start
                    self.cursor = s;
                } else {
                    // land on the last non-blank char (one char back from its end)
                    let mut c = s;
                    let mut prev = s;
                    for ch in slice.chars() {
                        let nxt = c + ch.len_utf8();
                        if nxt == last_nonws_end {
                            prev = c;
                            break;
                        }
                        c = nxt;
                    }
                    self.cursor = prev;
                }
            }
            MoveLineEnd => self.cursor = self.line_end(self.current_line()),
            MoveParagraph { forward } => {
                let cur_row = self.current_line();
                let line_count = self.line_count();
                let is_blank = |row: usize| {
                    let (s, e) = self.line_byte_range(row);
                    self.text[s..e].chars().all(|c| c.is_whitespace())
                };
                let target = if forward {
                    // Skip the current run, then find the next blank.
                    let mut skipped_current = false;
                    let mut row = cur_row + 1;
                    let mut found = None;
                    while row < line_count {
                        if is_blank(row) {
                            if skipped_current {
                                found = Some(row);
                                break;
                            }
                            // landed on the current paragraph's trailing blank
                            // — vim convention: jump past it to the NEXT blank
                            // after intervening text. Keep walking.
                            row += 1;
                            continue;
                        }
                        skipped_current = true;
                        row += 1;
                    }
                    found.unwrap_or_else(|| line_count.saturating_sub(1))
                } else {
                    // Walk back to the previous blank.
                    if cur_row == 0 {
                        0
                    } else {
                        let mut skipped_current = false;
                        let mut row = cur_row - 1;
                        let mut found = None;
                        loop {
                            if is_blank(row) {
                                if skipped_current {
                                    found = Some(row);
                                    break;
                                }
                                if row == 0 {
                                    break;
                                }
                                row -= 1;
                                continue;
                            }
                            skipped_current = true;
                            if row == 0 {
                                break;
                            }
                            row -= 1;
                        }
                        found.unwrap_or(0)
                    }
                };
                self.cursor = self.line_start(target);
            }
            MoveSentence { forward } => {
                // Sentence boundary = `.`/`!`/`?` followed by whitespace, or
                // a blank line. Vim's sentence motion is famously loose; this
                // is the common-case approximation.
                let bytes = self.text.as_bytes();
                let len = bytes.len();
                if forward {
                    let mut i = self.cursor + 1;
                    while i < len {
                        let c = bytes[i];
                        if (c == b'.' || c == b'!' || c == b'?') && i + 1 < len {
                            let nxt = bytes[i + 1];
                            if nxt == b' ' || nxt == b'\n' || nxt == b'\t' {
                                // land on the char after the whitespace
                                let mut j = i + 1;
                                while j < len && (bytes[j] == b' ' || bytes[j] == b'\t') {
                                    j += 1;
                                }
                                self.cursor = j;
                                return;
                            }
                        }
                        i += 1;
                    }
                    self.cursor = len;
                } else {
                    // Walk backward; find the *start* of the current sentence
                    // (just-past the prior boundary, or BOF).
                    let mut i = self.cursor.saturating_sub(1);
                    while i > 0 {
                        let c = bytes[i];
                        if (c == b'.' || c == b'!' || c == b'?') && i + 1 < len {
                            let nxt = bytes[i + 1];
                            if nxt == b' ' || nxt == b'\n' || nxt == b'\t' {
                                let mut j = i + 1;
                                while j < len && (bytes[j] == b' ' || bytes[j] == b'\t') {
                                    j += 1;
                                }
                                if j < self.cursor {
                                    self.cursor = j;
                                    return;
                                }
                            }
                        }
                        i -= 1;
                    }
                    self.cursor = 0;
                }
            }
            MoveBufferStart => self.cursor = 0,
            MoveBufferEnd => self.cursor = self.text.len(),
            MoveToLine(n) => {
                let line = n.saturating_sub(1).min(self.line_count().saturating_sub(1));
                self.cursor = self.line_start(line);
            }
            SetCursorByte(b) => {
                let mut b = b.min(self.text.len());
                while b > 0 && !self.text.is_char_boundary(b) {
                    b -= 1;
                }
                self.cursor = b;
                self.goal_col = self.col_at_byte(b);
            }

            // ── selection ──
            SelectStart => self.anchor = Some(self.cursor),
            SelectClear => {
                self.remember_selection();
                self.anchor = None;
            }
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
            SelectInnerWord => {
                // vim `iw` — identifier run under the cursor. Reuses
                // `word_bounds_at` which is what SelectWord already used.
                let (lo, hi) = self.word_bounds_at(self.cursor);
                self.anchor = Some(lo);
                self.cursor = hi;
            }
            SelectInnerQuote(q) => {
                if let Some((open, close)) = self.enclosing_quote_pair_on_line(q) {
                    // Inner range: between the two quotes.
                    self.anchor = Some(open + q.len_utf8());
                    self.cursor = close;
                }
            }
            SelectAroundQuote(q) => {
                if let Some((open, close)) = self.enclosing_quote_pair_on_line(q) {
                    self.anchor = Some(open);
                    self.cursor = close + q.len_utf8();
                }
            }
            SelectInnerBracket(open) => {
                let close = match_close_for(open);
                if let Some((o, c)) = self.enclosing_bracket_pair(open, close) {
                    self.anchor = Some(o + open.len_utf8());
                    self.cursor = c;
                }
            }
            RestoreLastSelection => {
                if let Some((lo, hi)) = self.last_selection {
                    let lo = lo.min(self.text.len());
                    let hi = hi.min(self.text.len());
                    self.anchor = Some(lo);
                    self.cursor = hi;
                }
            }
            SwapAnchorCursor => {
                if let Some(a) = self.anchor {
                    self.anchor = Some(self.cursor);
                    self.cursor = a;
                    self.goal_col = self.col_at_byte(self.cursor);
                }
            }
            FindCharOnLine {
                ch,
                forward,
                before,
                inclusive,
            } => {
                let line = self.current_line();
                let ls = self.line_start(line);
                let le = self.line_end(line);
                let cur = self.cursor;
                if forward {
                    // Scan from one char past cursor to end-of-line.
                    let after = (cur + 1).min(le);
                    if let Some(off) = self.text[after..le].find(ch) {
                        let target = after + off;
                        // `f`: land on target. `t`: one *before* target.
                        // For operator-pending (`inclusive`), bump one cell
                        // forward so the operator's range includes the find
                        // char (for `f`) or stops exactly on it (for `t`).
                        let base = if before {
                            self.prev_char_boundary(target)
                        } else {
                            target
                        };
                        self.cursor = if inclusive {
                            self.next_char_boundary(base)
                        } else {
                            base
                        };
                        self.goal_col = self.col_at_byte(self.cursor);
                    }
                } else {
                    // Backward scan from start-of-line up to (but not
                    // including) the cursor.
                    let before_cur = cur.min(le);
                    let slice = &self.text[ls..before_cur];
                    if let Some(off) = slice.rfind(ch) {
                        let target = ls + off;
                        let base = if before {
                            self.next_char_boundary(target)
                        } else {
                            target
                        };
                        // For an inclusive backward operator, the range
                        // wants to cover one cell less (the `f` form should
                        // include the target → cursor lands ON the target,
                        // not before it; for `t`, one past).
                        let _ = inclusive;
                        self.cursor = base;
                        self.goal_col = self.col_at_byte(self.cursor);
                    }
                }
            }
            SelectAroundBracket(open) => {
                let close = match_close_for(open);
                if let Some((o, c)) = self.enclosing_bracket_pair(open, close) {
                    self.anchor = Some(o);
                    self.cursor = c + close.len_utf8();
                }
            }
            SelectInnerParagraph => {
                let (lo, hi) = self.paragraph_bounds(false);
                self.anchor = Some(lo);
                self.cursor = hi;
            }
            SelectAroundParagraph => {
                let (lo, hi) = self.paragraph_bounds(true);
                self.anchor = Some(lo);
                self.cursor = hi;
            }
            SelectAroundWord => {
                // vim `aw` — `iw` extended to include trailing whitespace,
                // or (when the word sits at end-of-line) leading whitespace
                // back to the previous non-space (vim's "around" semantics).
                let (lo, mut hi) = self.word_bounds_at(self.cursor);
                let bytes = self.text.as_bytes();
                let mut hi_extended = false;
                while hi < self.text.len() && matches!(bytes[hi], b' ' | b'\t') {
                    hi += 1;
                    hi_extended = true;
                }
                let mut lo_new = lo;
                if !hi_extended {
                    // No trailing ws to grab — fall back to leading ws.
                    while lo_new > 0 && matches!(bytes[lo_new - 1], b' ' | b'\t') {
                        lo_new -= 1;
                    }
                }
                self.anchor = Some(lo_new);
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
            ReplaceCharAtCursor(c) => {
                if let Some((lo, hi)) = self.selection() {
                    // visual r<c>: replace each non-newline char with c
                    self.checkpoint();
                    let mut out_s = String::with_capacity(hi - lo);
                    for ch in self.text[lo..hi].chars() {
                        if ch == '\n' {
                            out_s.push('\n');
                        } else {
                            out_s.push(c);
                        }
                    }
                    self.text.replace_range(lo..hi, &out_s);
                    self.cursor = lo;
                    self.anchor = None;
                    out.buffer_changed = true;
                } else {
                    let cur = self.cursor;
                    if let Some(target) = self.text[cur..].chars().next()
                        && target != '\n'
                    {
                        self.checkpoint();
                        let end = cur + target.len_utf8();
                        let mut buf = [0u8; 4];
                        let s = c.encode_utf8(&mut buf);
                        self.text.replace_range(cur..end, s);
                        // cursor stays at `cur` (vim convention)
                        out.buffer_changed = true;
                    }
                }
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
            ToggleCaseChar => {
                // vim `~` — toggle the ASCII letter under the cursor + advance.
                if self.cursor < self.text.len() {
                    let b = self.text.as_bytes()[self.cursor];
                    if b.is_ascii_alphabetic() {
                        self.checkpoint();
                        let toggled = if b.is_ascii_uppercase() {
                            b.to_ascii_lowercase()
                        } else {
                            b.to_ascii_uppercase()
                        };
                        // Single-byte ASCII swap; replace_range keeps it safe.
                        let s = std::str::from_utf8(&[toggled]).unwrap().to_string();
                        self.text.replace_range(self.cursor..self.cursor + 1, &s);
                        out.buffer_changed = true;
                    }
                    // Advance to the next char boundary (handles multi-byte).
                    let mut next = self.cursor + 1;
                    while next < self.text.len() && !self.text.is_char_boundary(next) {
                        next += 1;
                    }
                    self.cursor = next;
                }
            }
            ChangeNumberAtCursor { delta } => {
                let line = self.current_line();
                let bol = self.line_start(line);
                let eol = self.line_end(line);
                let bytes = self.text.as_bytes();
                // Walk forward from cursor on this line until we hit a digit.
                let mut digit_pos = self.cursor.max(bol);
                while digit_pos < eol && !bytes[digit_pos].is_ascii_digit() {
                    digit_pos += 1;
                }
                if digit_pos >= eol {
                    return;
                }
                // The number's start: walk back through digits.
                let mut start = digit_pos;
                while start > bol && bytes[start - 1].is_ascii_digit() {
                    start -= 1;
                }
                // Maybe a leading `-` sign — qualifies when the char *before*
                // it isn't an identifier char (digit / letter / `_`).
                if start > bol && bytes[start - 1] == b'-' {
                    let qualifies = start - 1 == bol
                        || !(bytes[start - 2].is_ascii_alphanumeric() || bytes[start - 2] == b'_');
                    if qualifies {
                        start -= 1;
                    }
                }
                // The number's end: walk forward through digits.
                let mut end = digit_pos;
                while end < eol && bytes[end].is_ascii_digit() {
                    end += 1;
                }
                let num_str = &self.text[start..end];
                let Ok(n) = num_str.parse::<i64>() else {
                    return;
                };
                let new_n = n.saturating_add(delta);
                let new_str = new_n.to_string();
                if new_str == num_str {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(start..end, &new_str);
                // Cursor lands on the last char of the new number (vim).
                self.cursor = start + new_str.len().saturating_sub(1);
                self.anchor = None;
                out.buffer_changed = true;
            }
            ReflowParagraph { width } => {
                let (start, end) = self.paragraph_bounds(false);
                if end <= start {
                    return;
                }
                let body = &self.text[start..end];
                if body.trim().is_empty() {
                    return;
                }
                // Keep the leading whitespace of the first line as the
                // common indent — applied to every wrapped line so indented
                // prose stays indented.
                let first_line_end = body.find('\n').unwrap_or(body.len());
                let indent: String = body[..first_line_end]
                    .chars()
                    .take_while(|c| c.is_whitespace())
                    .collect();
                // Greedy word-wrap. Words = runs of non-whitespace; the
                // separator between them is always a single space (no
                // attempt to preserve double-space-after-period etc.).
                let words: Vec<&str> = body.split_whitespace().filter(|w| !w.is_empty()).collect();
                if words.is_empty() {
                    return;
                }
                let target = width.max(indent.chars().count() + 8);
                let mut wrapped = String::with_capacity(body.len());
                let mut line_chars = 0usize;
                for (i, w) in words.iter().enumerate() {
                    let wlen = w.chars().count();
                    if i == 0 {
                        wrapped.push_str(&indent);
                        wrapped.push_str(w);
                        line_chars = indent.chars().count() + wlen;
                    } else if line_chars + 1 + wlen > target {
                        wrapped.push('\n');
                        wrapped.push_str(&indent);
                        wrapped.push_str(w);
                        line_chars = indent.chars().count() + wlen;
                    } else {
                        wrapped.push(' ');
                        wrapped.push_str(w);
                        line_chars += 1 + wlen;
                    }
                }
                if wrapped == body {
                    return;
                }
                self.checkpoint();
                self.text.replace_range(start..end, &wrapped);
                self.cursor = start;
                self.anchor = None;
                out.buffer_changed = true;
            }
            TransformSelectionCase(kind) => {
                if let Some((lo, hi)) = self.selection() {
                    let original = &self.text[lo..hi];
                    let transformed: String = match kind {
                        CaseTransform::Lower => original.to_lowercase(),
                        CaseTransform::Upper => original.to_uppercase(),
                        CaseTransform::Toggle => original
                            .chars()
                            .map(|c| {
                                if c.is_ascii_uppercase() {
                                    c.to_ascii_lowercase()
                                } else if c.is_ascii_lowercase() {
                                    c.to_ascii_uppercase()
                                } else {
                                    c
                                }
                            })
                            .collect(),
                    };
                    if transformed != original {
                        self.checkpoint();
                        self.text.replace_range(lo..hi, &transformed);
                        // Cursor lands at the end of the transformed range
                        // (vim parks it at the start, but landing at the end
                        // is more useful when chaining; both are common).
                        self.cursor = lo + transformed.len();
                        self.anchor = None;
                        out.buffer_changed = true;
                    } else {
                        // No actual change (e.g. lowercasing all-lowercase
                        // text) — still drop the selection like vim does.
                        self.cursor = lo;
                        self.anchor = None;
                    }
                }
            }
            JoinLines { keep_space } => {
                // vim `J` (keep_space=true) / `gJ` (keep_space=false).
                let line = self.current_line();
                let total = self.line_count();
                if line + 1 < total {
                    self.checkpoint();
                    let bol = self.line_start(line);
                    let eol = self.line_end(line);
                    // Walk back from end-of-line past trailing whitespace
                    // (only when we're keeping the space — `gJ` preserves
                    // *all* whitespace verbatim, vim convention).
                    let mut trim_end = eol;
                    if keep_space {
                        while trim_end > bol {
                            let b = self.text.as_bytes()[trim_end - 1];
                            if b == b' ' || b == b'\t' {
                                trim_end -= 1;
                            } else {
                                break;
                            }
                        }
                    }
                    // Same for leading whitespace on the next line — `gJ`
                    // keeps it; `J` eats it.
                    let next_bol = eol + 1;
                    let next_eol = self.line_end(line + 1);
                    let mut next_first = next_bol;
                    if keep_space {
                        while next_first < next_eol {
                            let b = self.text.as_bytes()[next_first];
                            if b == b' ' || b == b'\t' {
                                next_first += 1;
                            } else {
                                break;
                            }
                        }
                    }
                    // Insert " " between unless we're in `gJ` mode, OR the
                    // (post-trim) current line is empty.
                    let separator = if !keep_space || trim_end == bol {
                        ""
                    } else {
                        " "
                    };
                    self.text.replace_range(trim_end..next_first, separator);
                    // Cursor lands ON the inserted space (or at the join
                    // boundary when none was inserted).
                    self.cursor = trim_end;
                    self.anchor = None;
                    out.buffer_changed = true;
                }
            }

            // ── clipboard / registers ──
            SetRegisterHint(reg) => {
                clip.set_pending_register(reg);
            }
            YankLine => {
                let line = self.current_line();
                let mut s = self.line_str(line).to_string();
                s.push('\n');
                clip.set_yank(s.clone(), true);
                out.clipboard_set = Some(s);
                out.clipboard_linewise = true;
            }
            BlockSelectStart => {
                self.block_anchor = Some(self.cursor);
                // Block mode is independent of charwise; clear any
                // lingering charwise anchor.
                self.anchor = None;
            }
            BlockSelectClear => {
                self.block_anchor = None;
            }
            YankBlock => {
                if let Some((rmin, cmin, rmax, cmax)) = self.block_selection() {
                    let ranges = self.block_ranges(rmin, cmin, rmax, cmax);
                    let mut parts: Vec<String> = Vec::with_capacity(ranges.len());
                    for (s, e) in &ranges {
                        parts.push(self.text[*s..*e].to_string());
                    }
                    let joined = parts.join("\n");
                    clip.set_yank(joined.clone(), false);
                    out.clipboard_set = Some(joined);
                    self.block_anchor = None;
                }
            }
            DeleteBlock => {
                if let Some((rmin, cmin, rmax, cmax)) = self.block_selection() {
                    let ranges = self.block_ranges(rmin, cmin, rmax, cmax);
                    // Yank into clipboard first (vim convention — `d` yanks).
                    let mut parts: Vec<String> = Vec::with_capacity(ranges.len());
                    for (s, e) in &ranges {
                        parts.push(self.text[*s..*e].to_string());
                    }
                    let joined = parts.join("\n");
                    clip.set(joined.clone(), false);
                    out.clipboard_set = Some(joined);
                    // Splice descending so earlier byte offsets stay valid.
                    self.checkpoint();
                    let mut sorted = ranges.clone();
                    sorted.sort_by_key(|r| std::cmp::Reverse(r.0));
                    for (s, e) in sorted {
                        if s < e {
                            self.text.replace_range(s..e, "");
                        }
                    }
                    // Land cursor at the rectangle's top-left (the byte at
                    // rmin's start-of-line + cmin chars, clamped to the
                    // post-edit line content).
                    let (line_s, line_e) = self.line_byte_range(rmin);
                    let line_text = &self.text[line_s..line_e];
                    let mut b = line_s;
                    for (col, ch) in line_text.chars().enumerate() {
                        if col == cmin {
                            break;
                        }
                        b += ch.len_utf8();
                    }
                    self.cursor = b;
                    self.block_anchor = None;
                    self.anchor = None;
                    out.buffer_changed = true;
                }
            }
            YankSelection => {
                if let Some((lo, hi)) = self.selection() {
                    let s = self.text[lo..hi].to_string();
                    clip.set_yank(s.clone(), false);
                    out.clipboard_set = Some(s);
                    self.remember_selection();
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
            PasteAfterEnd => {
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
                    // gp: cursor at END of pasted block (vim convention).
                    self.cursor = insert_at + payload.len();
                } else {
                    let at = self.next_char_boundary(self.cursor).min(self.text.len());
                    self.text.insert_str(at, &s);
                    self.cursor = at + s.len();
                }
                self.anchor = None;
                out.buffer_changed = true;
            }
            PasteBeforeEnd => {
                let s = clip.text();
                if s.is_empty() {
                    return;
                }
                self.checkpoint();
                if clip.is_linewise() {
                    let line = self.current_line();
                    let bol = self.line_start(line);
                    self.text.insert_str(bol, &s);
                    self.cursor = bol + s.len();
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
                self.remember_selection();
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

    /// Byte range of the paragraph the cursor sits in. A "paragraph" is a
    /// maximal run of non-blank lines (blank = empty or whitespace-only).
    /// When `around` is true, the range also includes the trailing blank
    /// lines that immediately follow the paragraph (vim's `ap` semantic).
    /// If the cursor is on a blank line, returns the range of that blank
    /// run instead (graceful no-op for the operator).
    fn paragraph_bounds(&self, around: bool) -> (usize, usize) {
        let n = self.line_count();
        let cur_line = self.current_line();
        let is_blank = |l: usize| self.line_str(l).trim().is_empty();
        // Walk up to the first blank line above (or buffer start).
        let mut start_line = cur_line;
        if is_blank(start_line) {
            // Cursor on a blank line — select the blank run.
            while start_line > 0 && is_blank(start_line - 1) {
                start_line -= 1;
            }
            let mut end_line = cur_line;
            while end_line + 1 < n && is_blank(end_line + 1) {
                end_line += 1;
            }
            return (self.line_start(start_line), self.line_end(end_line));
        }
        while start_line > 0 && !is_blank(start_line - 1) {
            start_line -= 1;
        }
        let mut end_line = cur_line;
        while end_line + 1 < n && !is_blank(end_line + 1) {
            end_line += 1;
        }
        if around {
            // Pull in trailing blank lines.
            while end_line + 1 < n && is_blank(end_line + 1) {
                end_line += 1;
            }
        }
        (self.line_start(start_line), self.line_end(end_line))
    }

    /// Find the smallest bracket pair surrounding the cursor. `open` /
    /// `close` are the matching delimiter chars (e.g. `(` and `)`).
    /// Returns `(open_byte, close_byte)` (pointing at the bracket chars
    /// themselves), or `None` when the cursor isn't inside a pair.
    /// Walks the buffer with a depth counter so nested pairs are handled.
    /// Capped at 50k chars per side so a malformed file doesn't hang.
    pub fn enclosing_bracket_pair(&self, open: char, close: char) -> Option<(usize, usize)> {
        const BUDGET: usize = 50_000;
        // Walk backward to find the unmatched open.
        let mut depth: usize = 0;
        let mut i = self.cursor;
        let mut steps = 0;
        let open_byte = loop {
            if i == 0 {
                return None;
            }
            i = self.prev_char_boundary(i);
            let ch = self.text[i..].chars().next()?;
            if ch == close {
                depth += 1;
            } else if ch == open {
                if depth == 0 {
                    break i;
                }
                depth -= 1;
            }
            steps += 1;
            if steps > BUDGET {
                return None;
            }
        };
        // Walk forward to find the matching close.
        let mut depth: usize = 0;
        let mut j = self.cursor;
        let mut steps = 0;
        let close_byte = loop {
            if j >= self.text.len() {
                return None;
            }
            let ch = self.text[j..].chars().next()?;
            if ch == open {
                depth += 1;
            } else if ch == close {
                if depth == 0 {
                    break j;
                }
                depth -= 1;
            }
            j += ch.len_utf8();
            steps += 1;
            if steps > BUDGET {
                return None;
            }
        };
        Some((open_byte, close_byte))
    }

    /// Find the surrounding pair of `q` characters on the cursor's line.
    /// Returns `(open_byte, close_byte)` (both pointing at the quote chars),
    /// or `None` when there isn't a matching pair flanking the cursor. Used
    /// by the `i"` / `a"` family of text objects — restricted to a single
    /// line so a multi-line string elsewhere in the buffer can't fool the
    /// scan. Treats backslash-escaped quotes as literal.
    fn enclosing_quote_pair_on_line(&self, q: char) -> Option<(usize, usize)> {
        let line = self.current_line();
        let ls = self.line_start(line);
        let le = self.line_end(line);
        let line_text = &self.text[ls..le];
        // Find every unescaped occurrence of `q` on this line.
        let mut quotes: Vec<usize> = Vec::new();
        let bytes = line_text.as_bytes();
        let qb = q as u8;
        let mut i = 0;
        while i < line_text.len() {
            if bytes[i] == qb {
                let escaped = i > 0 && bytes[i - 1] == b'\\';
                if !escaped {
                    quotes.push(ls + i);
                }
            }
            i += 1;
        }
        if quotes.len() < 2 {
            return None;
        }
        // Pair up consecutively: (quotes[0], quotes[1]), (quotes[2], quotes[3]), …
        // Then find the pair whose range contains the cursor (or the cursor
        // exactly on a quote — vim picks the pair you're on).
        let cur = self.cursor;
        for pair in quotes.chunks_exact(2) {
            let (a, b) = (pair[0], pair[1]);
            if cur >= a && cur <= b {
                return Some((a, b));
            }
        }
        None
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
    fn block_selection_yank_and_delete() {
        // 4 lines of "abcdef" — yank the column 1..=2 rectangle on rows 0..=2
        let (mut e, mut c) = ed("abcdef\nghijkl\nmnopqr\nstuvwx");
        // Cursor at (0,1)
        e.apply(MoveRight, 10, &mut c); // → cursor at byte 1, row 0 col 1
        e.apply(BlockSelectStart, 10, &mut c);
        // Move down 2 (row 2) and right 1 (col 2)
        e.apply(MoveDown, 10, &mut c);
        e.apply(MoveDown, 10, &mut c);
        e.apply(MoveRight, 10, &mut c);
        let rect = e.block_selection().unwrap();
        assert_eq!(rect, (0, 1, 2, 2));
        // Yank — clipboard should hold "bc\nhi\nno" (rows 0..=2, cols 1..=2)
        e.apply(YankBlock, 10, &mut c);
        assert_eq!(c.text(), "bc\nhi\nno");
        assert!(e.block_selection().is_none()); // cleared after yank

        // Delete: re-establish at (0,1)..(2,2), delete the rectangle
        let (mut e, mut c) = ed("abcdef\nghijkl\nmnopqr\nstuvwx");
        e.apply(MoveRight, 10, &mut c);
        e.apply(BlockSelectStart, 10, &mut c);
        e.apply(MoveDown, 10, &mut c);
        e.apply(MoveDown, 10, &mut c);
        e.apply(MoveRight, 10, &mut c);
        e.apply(DeleteBlock, 10, &mut c);
        assert_eq!(e.text(), "adef\ngjkl\nmpqr\nstuvwx");
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
    fn join_lines_inserts_single_space_eating_indent() {
        let (mut e, mut c) = ed("foo \n   bar");
        e.cursor = 0;
        e.apply(JoinLines { keep_space: true }, 10, &mut c);
        // Trailing ws on first line + leading ws on second eaten; one space.
        assert_eq!(e.text(), "foo bar");
        // Cursor lands at the join boundary (where the inserted space is).
        assert_eq!(e.cursor(), 3);
    }

    #[test]
    fn join_lines_no_separator_for_empty_first_line() {
        let (mut e, mut c) = ed("\nbar");
        e.cursor = 0;
        e.apply(JoinLines { keep_space: true }, 10, &mut c);
        // Empty first line → no separator inserted.
        assert_eq!(e.text(), "bar");
        assert_eq!(e.cursor(), 0);
    }

    #[test]
    fn join_lines_noop_on_last_line() {
        let (mut e, mut c) = ed("only");
        e.apply(JoinLines { keep_space: true }, 10, &mut c);
        assert_eq!(e.text(), "only");
    }

    #[test]
    fn join_lines_count_chains_two_joins() {
        let (mut e, mut c) = ed("a\nb\nc");
        e.cursor = 0;
        // 3J ⇒ 2 join ops; should pull both lines up.
        e.apply(JoinLines { keep_space: true }, 10, &mut c);
        e.apply(JoinLines { keep_space: true }, 10, &mut c);
        assert_eq!(e.text(), "a b c");
    }

    #[test]
    fn join_lines_no_space_preserves_whitespace() {
        // vim `gJ` — concatenates the lines verbatim, keeping any
        // trailing/leading whitespace.
        let (mut e, mut c) = ed("foo \n   bar");
        e.cursor = 0;
        e.apply(JoinLines { keep_space: false }, 10, &mut c);
        assert_eq!(e.text(), "foo    bar");
    }

    #[test]
    fn case_transform_lowercases_selection() {
        let (mut e, mut c) = ed("HELLO World");
        e.cursor = 0;
        e.apply(SelectAll, 10, &mut c);
        e.apply(
            TransformSelectionCase(crate::edit_op::CaseTransform::Lower),
            10,
            &mut c,
        );
        assert_eq!(e.text(), "hello world");
    }

    #[test]
    fn case_transform_uppercases_selection() {
        let (mut e, mut c) = ed("Hello World");
        e.cursor = 0;
        e.apply(SelectAll, 10, &mut c);
        e.apply(
            TransformSelectionCase(crate::edit_op::CaseTransform::Upper),
            10,
            &mut c,
        );
        assert_eq!(e.text(), "HELLO WORLD");
    }

    #[test]
    fn case_transform_toggle_swaps_each_letter() {
        let (mut e, mut c) = ed("Hello, World!");
        e.cursor = 0;
        e.apply(SelectAll, 10, &mut c);
        e.apply(
            TransformSelectionCase(crate::edit_op::CaseTransform::Toggle),
            10,
            &mut c,
        );
        // Punctuation untouched; each ASCII letter swapped.
        assert_eq!(e.text(), "hELLO, wORLD!");
    }

    #[test]
    fn reflow_paragraph_wraps_long_line_to_width() {
        // Long single-line paragraph wraps to the requested width.
        let (mut e, mut c) = ed("the quick brown fox jumps over the lazy dog");
        e.cursor = 0;
        e.apply(ReflowParagraph { width: 16 }, 10, &mut c);
        // Each line should be <= 16 chars.
        for line in e.text().lines() {
            assert!(line.chars().count() <= 16, "line longer than 16: {line:?}");
        }
        // Round-trip preserves the words in order.
        let words: Vec<&str> = e.text().split_whitespace().collect();
        assert_eq!(
            words,
            vec![
                "the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"
            ]
        );
    }

    #[test]
    fn reflow_paragraph_collapses_multi_line_paragraph() {
        let (mut e, mut c) = ed("alpha\nbeta\ngamma");
        e.cursor = 0;
        // Wide enough for everything on one line.
        e.apply(ReflowParagraph { width: 80 }, 10, &mut c);
        assert_eq!(e.text(), "alpha beta gamma");
    }

    #[test]
    fn reflow_paragraph_preserves_first_line_indent() {
        let (mut e, mut c) = ed("    indented prose that goes on for a while now");
        e.cursor = 0;
        e.apply(ReflowParagraph { width: 24 }, 10, &mut c);
        // Every line starts with the 4-space indent.
        for line in e.text().lines() {
            assert!(line.starts_with("    "), "line missing indent: {line:?}");
        }
    }

    #[test]
    fn reflow_paragraph_skips_blank_paragraph() {
        let (mut e, mut c) = ed("\n\n");
        e.apply(ReflowParagraph { width: 20 }, 10, &mut c);
        assert_eq!(e.text(), "\n\n");
    }

    #[test]
    fn toggle_case_char_swaps_and_advances() {
        let (mut e, mut c) = ed("aBc");
        e.cursor = 0;
        e.apply(ToggleCaseChar, 10, &mut c);
        assert_eq!(e.text(), "ABc");
        assert_eq!(e.cursor(), 1);
        e.apply(ToggleCaseChar, 10, &mut c);
        assert_eq!(e.text(), "Abc");
        assert_eq!(e.cursor(), 2);
    }

    #[test]
    fn toggle_case_char_skips_non_alpha_but_advances() {
        let (mut e, mut c) = ed("a 1");
        e.cursor = 1; // on the space
        e.apply(ToggleCaseChar, 10, &mut c);
        assert_eq!(e.text(), "a 1"); // unchanged
        assert_eq!(e.cursor(), 2); // advanced past
    }

    #[test]
    fn change_number_increments_at_cursor() {
        let (mut e, mut c) = ed("count = 41");
        e.cursor = 0;
        e.apply(ChangeNumberAtCursor { delta: 1 }, 10, &mut c);
        assert_eq!(e.text(), "count = 42");
        // Cursor lands on the last digit.
        assert_eq!(e.cursor(), 9);
    }

    #[test]
    fn change_number_decrements_with_count() {
        let (mut e, mut c) = ed("v=10");
        e.cursor = 0;
        e.apply(ChangeNumberAtCursor { delta: -3 }, 10, &mut c);
        assert_eq!(e.text(), "v=7");
    }

    #[test]
    fn change_number_picks_up_negative_sign_in_parens() {
        let (mut e, mut c) = ed("(-5)");
        e.cursor = 0;
        e.apply(ChangeNumberAtCursor { delta: 1 }, 10, &mut c);
        assert_eq!(e.text(), "(-4)");
    }

    #[test]
    fn change_number_doesnt_steal_id_minus() {
        // `x-5` is "5 with no sign" — the `-` is part of the prior identifier.
        let (mut e, mut c) = ed("x-5");
        e.cursor = 0;
        e.apply(ChangeNumberAtCursor { delta: 1 }, 10, &mut c);
        assert_eq!(e.text(), "x-6");
    }

    #[test]
    fn change_number_noop_when_no_digit_on_line() {
        let (mut e, mut c) = ed("just words");
        e.apply(ChangeNumberAtCursor { delta: 1 }, 10, &mut c);
        assert_eq!(e.text(), "just words");
    }

    #[test]
    fn case_transform_no_selection_is_noop() {
        let (mut e, mut c) = ed("Hello");
        e.cursor = 0;
        e.apply(
            TransformSelectionCase(crate::edit_op::CaseTransform::Upper),
            10,
            &mut c,
        );
        assert_eq!(e.text(), "Hello");
    }

    #[test]
    fn find_char_on_line_forward_and_backward() {
        let (mut e, mut c) = ed("hello world\nfoobar");
        e.cursor = 0;
        // f-o → move to first 'o'
        e.apply(
            EditOp::FindCharOnLine {
                ch: 'o',
                forward: true,
                before: false,
                inclusive: false,
            },
            10,
            &mut c,
        );
        assert_eq!(e.cursor, 4);
        // f-o again from there → second 'o' on the same line
        e.apply(
            EditOp::FindCharOnLine {
                ch: 'o',
                forward: true,
                before: false,
                inclusive: false,
            },
            10,
            &mut c,
        );
        assert_eq!(e.cursor, 7);
        // F-h → backward to 'h'
        e.apply(
            EditOp::FindCharOnLine {
                ch: 'h',
                forward: false,
                before: false,
                inclusive: false,
            },
            10,
            &mut c,
        );
        assert_eq!(e.cursor, 0);
        // t-w forward from 'h' → just before 'w'
        e.apply(
            EditOp::FindCharOnLine {
                ch: 'w',
                forward: true,
                before: true,
                inclusive: false,
            },
            10,
            &mut c,
        );
        assert_eq!(e.cursor, 5); // 'w' is at 6, before is 5
        // f-x (not on this line) → no-op
        let before = e.cursor;
        e.apply(
            EditOp::FindCharOnLine {
                ch: 'x',
                forward: true,
                before: false,
                inclusive: false,
            },
            10,
            &mut c,
        );
        assert_eq!(e.cursor, before);
    }

    #[test]
    fn restore_last_selection_brings_it_back() {
        let (mut e, mut c) = ed("hello world");
        // Make a selection [0, 5)
        e.cursor = 0;
        e.apply(EditOp::SelectStart, 10, &mut c);
        e.cursor = 5;
        // YankSelection captures last_selection, then explicit SelectClear.
        e.apply(EditOp::YankSelection, 10, &mut c);
        e.apply(EditOp::SelectClear, 10, &mut c);
        assert!(e.selection().is_none());
        e.cursor = 7; // move somewhere
        e.apply(EditOp::RestoreLastSelection, 10, &mut c);
        assert_eq!(e.selection(), Some((0, 5)));
        assert_eq!(e.cursor, 5);
    }

    #[test]
    fn enclosing_bracket_pair_finds_nested() {
        let (mut e, _) = ed("fn f() { let x = (1 + (2 * 3)) }");
        // Cursor inside the inner (2 * 3)
        let inner = e.text().find("2 * 3").unwrap() + 1;
        e.cursor = inner;
        let pair = e.enclosing_bracket_pair('(', ')').unwrap();
        // Should be the inner ( and matching )
        let open = e.text().find("(2").unwrap();
        let close = e.text()[open..].find(')').unwrap() + open;
        assert_eq!(pair, (open, close));
        // Cursor inside braces — bracket-pair for `{` `}`
        let bi = e.text().find("let").unwrap();
        e.cursor = bi;
        let pair = e.enclosing_bracket_pair('{', '}').unwrap();
        let bo = e.text().find('{').unwrap();
        let bc = e.text().rfind('}').unwrap();
        assert_eq!(pair, (bo, bc));
    }

    #[test]
    fn enclosing_quote_pair_on_line_finds_inner_range() {
        let (mut e, _) = ed("let s = \"hello world\";\nother line");
        // Cursor inside the string (col 12 = inside "hello world")
        e.place_cursor(0, 12);
        let pair = e.enclosing_quote_pair_on_line('"').unwrap();
        // Open quote at col 8, close at col 20 (chars)
        // Convert by re-deriving from text
        let text = e.text();
        let open = text.find('"').unwrap();
        let close = text[open + 1..].find('"').unwrap() + open + 1;
        assert_eq!(pair, (open, close));
        // Cursor outside any string → None.
        e.place_cursor(0, 3);
        assert_eq!(e.enclosing_quote_pair_on_line('"'), None);
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
