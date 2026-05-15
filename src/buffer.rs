//! One open file — the `Pane::Editor` payload. Wraps an [`Editor`] plus path /
//! dirty / language bookkeeping plus its own input handler (so per-buffer modal
//! state lives here, not in `App`).

use std::path::{Path, PathBuf};
use std::time::Instant;

use ratatui::crossterm::event::KeyEvent;

use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::editor::Editor;
use crate::highlight::{self, ColoredSpan};
use crate::input::{self, AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

/// Above this many bytes, skip syntax highlighting (re-parsing on every edit
/// would lag). Incremental parsing lifts this later.
const HIGHLIGHT_BYTE_LIMIT: usize = 2 * 1024 * 1024;

/// In-buffer find state — opened by `find.find` (`Ctrl+F`), advanced by `F3` /
/// `Shift+F3`. Stores byte ranges; recomputed on every text-changing edit.
#[derive(Debug, Clone, Default)]
pub struct FindState {
    pub query: String,
    pub matches: Vec<(usize, usize)>,
    /// Index into `matches` of the "current" match (the one the cursor is on).
    pub current: Option<usize>,
    /// When `true`, `query` is compiled as a regex (case-insensitive by default
    /// for parity with the literal mode); when `false`, the existing
    /// [`find_all_ci_ascii`] literal scan is used. Toggled by `find.toggle_regex`.
    pub regex: bool,
    /// When `true`, the literal scan is case-sensitive — used by
    /// "smart-case" find (any uppercase letter in the query implies a case-
    /// sensitive search). Ignored when `regex` is true; the (?i) prefix on
    /// the regex isn't applied either way once that flag's set.
    pub case_sensitive: bool,
    /// Restrict matches to this byte range (inclusive start, exclusive end).
    /// `None` ⇒ whole buffer. Set by `App::open_find_prompt` when the user
    /// triggered Find with a multi-line selection active — gives a quick
    /// "search inside this block" gesture without a separate UI toggle.
    pub range: Option<(usize, usize)>,
}

impl FindState {
    pub fn recompute(&mut self, text: &str) {
        let (lo, hi) = match self.range {
            Some((a, b)) => (a.min(text.len()), b.min(text.len())),
            None => (0, text.len()),
        };
        let scope = if lo < hi { &text[lo..hi] } else { "" };
        let raw_matches = if self.regex {
            find_all_regex(scope, &self.query)
        } else if self.case_sensitive {
            find_all_case_sensitive(scope, &self.query)
        } else {
            find_all_ci_ascii(scope, &self.query)
        };
        self.matches = raw_matches
            .into_iter()
            .map(|(s, e)| (s + lo, e + lo))
            .collect();
        if self.matches.is_empty() {
            self.current = None;
        } else if let Some(c) = self.current {
            self.current = Some(c.min(self.matches.len() - 1));
        }
    }
}

/// `find_all_ci_ascii`'s sibling — literal, case-*sensitive*, non-overlapping.
/// Same `(byte_start, byte_end)` shape. Used by smart-case search.
pub fn find_all_case_sensitive(text: &str, query: &str) -> Vec<(usize, usize)> {
    if query.is_empty() || text.len() < query.len() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut start = 0;
    while let Some(i) = text[start..].find(query) {
        let s = start + i;
        let e = s + query.len();
        out.push((s, e));
        start = e;
    }
    out
}

/// Regex-based version of [`find_all_ci_ascii`] — same `(byte_start, byte_end)`
/// shape, non-overlapping, char-boundary safe. The pattern is automatically
/// flagged case-insensitive (matching the literal mode's behavior). Invalid
/// patterns return an empty list (caller handles "no matches" gracefully).
pub fn find_all_regex(text: &str, pattern: &str) -> Vec<(usize, usize)> {
    if pattern.is_empty() {
        return Vec::new();
    }
    // `(?i)` inline flag keeps the build dependency-free of regex-builder API.
    let prefixed = format!("(?i){pattern}");
    let Ok(re) = regex::Regex::new(&prefixed) else {
        return Vec::new();
    };
    re.find_iter(text)
        .filter(|m| m.start() != m.end()) // skip zero-width matches (would loop forever in `next`)
        .map(|m| (m.start(), m.end()))
        .collect()
}

/// Locate every (byte-range) occurrence of `query` in `text`, ASCII-case-
/// insensitive. Matches are non-overlapping (advance past each one). The
/// byte-length is `query.len()`; UTF-8 byte boundaries are preserved.
pub fn find_all_ci_ascii(text: &str, query: &str) -> Vec<(usize, usize)> {
    if query.is_empty() || text.len() < query.len() {
        return Vec::new();
    }
    let q = query.as_bytes();
    let t = text.as_bytes();
    let nlen = q.len();
    let mut out = Vec::new();
    let mut i = 0;
    'outer: while i + nlen <= t.len() {
        if !text.is_char_boundary(i) {
            i += 1;
            continue;
        }
        for j in 0..nlen {
            if !t[i + j].eq_ignore_ascii_case(&q[j]) {
                i += 1;
                continue 'outer;
            }
        }
        if text.is_char_boundary(i + nlen) {
            out.push((i, i + nlen));
            i += nlen;
        } else {
            i += 1;
        }
    }
    out
}

/// What `Buffer::feed_key` reports back to the event loop.
pub enum BufferEvent {
    /// The buffer text changed.
    Edited,
    /// State changed but not the text (cursor moved, selection, pending chord) — just redraw.
    Redraw,
    /// The handler didn't want this key — try the keymap→command resolver / global chords.
    Unhandled(KeyEvent),
    /// Escalate to an app-level command.
    App(AppCommand),
    /// Nothing happened.
    NoOp,
}

pub struct Buffer {
    pub path: Option<PathBuf>,
    pub editor: Editor,
    /// First visible line (vertical scroll), and first visible column (horizontal scroll).
    pub scroll: usize,
    pub h_scroll: usize,
    pub dirty: bool,
    saved_text: String,
    pub language_ext: Option<String>,
    pub input: Box<dyn InputHandler>,
    /// When true, key input never mutates the text (used for diff views etc.).
    pub read_only: bool,
    /// Cached syntax highlighting — one span list per editor line. Recomputed on
    /// open and after every text-changing edit (cheap for normal-sized files).
    pub highlights: Vec<Vec<ColoredSpan>>,
    /// `Some` ⇔ blame-gutter mode is on for this buffer (`git.blame_toggle`):
    /// one entry per file line, computed when toggled on, refreshed on save.
    pub blame: Option<Vec<crate::git::blame::BlameLine>>,
    /// LSP diagnostics for this file (replaced wholesale on each `publishDiagnostics`).
    pub diagnostics: Vec<crate::lsp::Diagnostic>,
    /// LSP inlay hints — virtual text the server suggests at specific
    /// positions. Refreshed on save (and after the initial `did_open`
    /// reply lands). Rendered as dim chips in the editor view.
    pub inlay_hints: Vec<crate::lsp::InlayHint>,
    /// LSP code lenses — actionable annotations (like "5 references" or
    /// "Run | Debug") attached to specific lines. Rendered as dim chips
    /// at end-of-line. Refreshed on save.
    pub code_lenses: Vec<crate::lsp::CodeLens>,
    /// LSP document links — clickable URLs / paths the server identified.
    /// Refreshed on save (and after `did_open` if the server returns
    /// eagerly). `editor.open_url_at_cursor` consults these so `gx` works
    /// on server-recognized links too.
    pub document_links: Vec<crate::lsp::DocumentLink>,
    /// LSP color decorations — `(line, character, end_character, rgb_hex)`
    /// per recognized color literal. Painted as a `◆` glyph in that color
    /// just before the literal. Refreshed on save.
    pub color_decorations: Vec<crate::lsp::ColorDecoration>,
    /// Stamp of the last text-changing edit (used by `[editor] autosave_secs`).
    /// `None` until the first edit; cleared back to `None` on save.
    pub last_edited: Option<Instant>,
    /// Last-known on-disk modification time for `path`. Captured on open
    /// and refreshed on save. The App's tick compares this to the file's
    /// current mtime and toasts (clean buffer ⇒ auto-reload; dirty ⇒
    /// warn) when they diverge — catches "you edited this in another
    /// app" surprises.
    pub disk_mtime: Option<std::time::SystemTime>,
    /// `Some` when an in-buffer find is active (matches recomputed on every edit).
    pub find: Option<FindState>,
    /// Strip trailing whitespace from each line before writing. Honored by
    /// [`Self::save_to_disk`] + [`Self::save_as`]. Read from config at open.
    pub trim_trailing_ws_on_save: bool,
    /// Append a `\n` on save if the buffer doesn't already end with one
    /// (POSIX text file convention). Read from config at open.
    pub ensure_trailing_newline: bool,
    /// Vim-style local marks (lowercase `a`-`z`), keyed by letter and stored as
    /// `(row, col)`. Set by `m<letter>`, jumped by `'<letter>` (line) or
    /// `` `<letter>`` (exact). Lost on buffer close (no persistence yet;
    /// uppercase / global marks would live on `App` and persist in session.json).
    pub marks: std::collections::HashMap<char, (usize, usize)>,
    /// Code folds: `start_line → end_line` (inclusive, both 0-based file lines).
    /// Lines `[start+1, end]` are hidden in the editor; the start line shows
    /// `⋯ N lines` after its text. Cleared on every text-changing edit (simple
    /// invariant — a smarter offset-shift is a follow-up).
    pub folds: std::collections::BTreeMap<usize, usize>,
    /// Vim "change list" — `(row, col)` of every text-changing edit, oldest
    /// first; consecutive duplicates collapse so fast typing at one spot
    /// doesn't bury the history. `g;` walks back through it; `g,` walks
    /// forward. Capped at [`EDIT_HISTORY_MAX`].
    pub edit_history: Vec<(usize, usize)>,
    /// Cursor into [`Self::edit_history`] for `g;` / `g,` walking. Equal to
    /// `edit_history.len()` ⇒ "past the newest entry" (the next `g;` jumps
    /// to the most recent edit, then walks back).
    pub edit_history_cursor: usize,
}

/// Cap for [`Buffer::edit_history`] — keeps the most recent N change
/// positions so `g;` doesn't walk through ancient history forever.
pub const EDIT_HISTORY_MAX: usize = 100;

impl Buffer {
    pub fn open(path: &Path, cfg: &Config) -> std::io::Result<Buffer> {
        let text = std::fs::read_to_string(path)?;
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_string())
            .or_else(|| ext_for_filename(path));
        let mut editor = Editor::new(text.clone(), cfg.editor.tab_width);
        editor.set_comment_token(comment_token_for(ext.as_deref()));
        editor.auto_pair = cfg.editor.auto_pair;
        editor.auto_indent = cfg.editor.auto_indent;
        let mut b = Buffer {
            path: Some(path.to_path_buf()),
            editor,
            scroll: 0,
            h_scroll: 0,
            dirty: false,
            saved_text: text,
            language_ext: ext,
            input: input::make_handler(cfg),
            read_only: false,
            highlights: Vec::new(),
            blame: None,
            diagnostics: Vec::new(),
            inlay_hints: Vec::new(),
            code_lenses: Vec::new(),
            document_links: Vec::new(),
            color_decorations: Vec::new(),
            last_edited: None,
            disk_mtime: std::fs::metadata(path).and_then(|m| m.modified()).ok(),
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            ensure_trailing_newline: cfg.editor.ensure_trailing_newline,
            marks: std::collections::HashMap::new(),
            folds: std::collections::BTreeMap::new(),
            edit_history: Vec::new(),
            edit_history_cursor: 0,
        };
        b.refresh_highlights();
        Ok(b)
    }

    /// Open a buffer that input can't mutate (diff views, log tails, …).
    pub fn open_readonly(path: &Path, cfg: &Config) -> std::io::Result<Buffer> {
        let mut b = Buffer::open(path, cfg)?;
        b.read_only = true;
        Ok(b)
    }

    /// Apply any `.editorconfig` settings that match the buffer's path,
    /// walking up from the file's directory to (and including) `workspace`.
    /// No-op when the buffer has no path. Closer-to-file settings win.
    /// Run by `App` right after `Buffer::open` so the per-file overrides
    /// land before any edits.
    pub fn apply_editorconfig(&mut self, workspace: &Path) {
        let Some(path) = self.path.clone() else {
            return;
        };
        let cfg = crate::editorconfig::resolve_for(&path, workspace);
        if let Some(w) = cfg.tab_width
            && w >= 1
        {
            self.editor.set_tab_width(w);
        }
        if let Some(v) = cfg.insert_final_newline {
            self.ensure_trailing_newline = v;
        }
        if let Some(v) = cfg.trim_trailing_whitespace {
            self.trim_trailing_ws_on_save = v;
        }
    }

    pub fn scratch(cfg: &Config) -> Buffer {
        let mut editor = Editor::new(String::new(), cfg.editor.tab_width);
        editor.auto_pair = cfg.editor.auto_pair;
        editor.auto_indent = cfg.editor.auto_indent;
        Buffer {
            path: None,
            editor,
            scroll: 0,
            h_scroll: 0,
            dirty: false,
            saved_text: String::new(),
            language_ext: None,
            input: input::make_handler(cfg),
            read_only: false,
            highlights: Vec::new(),
            blame: None,
            diagnostics: Vec::new(),
            inlay_hints: Vec::new(),
            code_lenses: Vec::new(),
            document_links: Vec::new(),
            color_decorations: Vec::new(),
            last_edited: None,
            disk_mtime: None,
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            ensure_trailing_newline: cfg.editor.ensure_trailing_newline,
            marks: std::collections::HashMap::new(),
            folds: std::collections::BTreeMap::new(),
            edit_history: Vec::new(),
            edit_history_cursor: 0,
        }
    }

    /// Re-run tree-sitter over the current text (no-op for unknown languages /
    /// huge files). Call after any edit that changes the text.
    pub fn refresh_highlights(&mut self) {
        let text = self.editor.text();
        if text.len() > HIGHLIGHT_BYTE_LIMIT {
            self.highlights.clear();
            return;
        }
        let ext = self.language_ext.as_deref().unwrap_or("");
        self.highlights = highlight::highlight_lines(text, ext);
    }

    /// Spans for editor line `line`, or `&[]` if unhighlighted.
    pub fn line_spans(&self, line: usize) -> &[ColoredSpan] {
        self.highlights
            .get(line)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    pub fn display_name(&self) -> String {
        self.path
            .as_ref()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "[scratch]".to_string())
    }

    pub fn is_at(&self, path: &Path) -> bool {
        self.path.as_deref().map(|p| p == path).unwrap_or(false)
    }

    pub fn recompute_dirty(&mut self) {
        self.dirty = self.editor.text() != self.saved_text;
    }

    pub fn save_to_disk(&mut self) -> std::io::Result<()> {
        if self.path.is_none() {
            return Ok(());
        }
        if self.trim_trailing_ws_on_save {
            self.apply_trim_trailing_ws();
        }
        if self.ensure_trailing_newline {
            self.apply_ensure_trailing_newline();
        }
        let path = self.path.clone().unwrap();
        std::fs::write(&path, self.editor.text())?;
        self.saved_text = self.editor.text().to_string();
        self.dirty = false;
        self.last_edited = None;
        self.disk_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        Ok(())
    }

    /// `:w <path>` — write the current text to `path`, then repoint the buffer
    /// at it (subsequent `:w` writes there). Errors propagate as `Err`.
    pub fn save_as(&mut self, path: PathBuf) -> std::io::Result<()> {
        if self.trim_trailing_ws_on_save {
            self.apply_trim_trailing_ws();
        }
        if self.ensure_trailing_newline {
            self.apply_ensure_trailing_newline();
        }
        std::fs::write(&path, self.editor.text())?;
        self.disk_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        self.path = Some(path);
        self.saved_text = self.editor.text().to_string();
        self.dirty = false;
        self.last_edited = None;
        Ok(())
    }

    /// Append a single `\n` to the buffer if it doesn't already end with one
    /// (and the buffer isn't empty). Goes through `apply_edit_ops` so undo
    /// can revert it.
    fn apply_ensure_trailing_newline(&mut self) {
        let text = self.editor.text();
        if text.is_empty() || text.ends_with('\n') {
            return;
        }
        let end = text.len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: end,
            end,
            text: "\n".to_string(),
        }];
        self.apply_edit_ops(ops, &mut crate::clipboard::Clipboard::new(), 0);
    }

    /// Strip trailing space/tab from every line in the buffer (called from the
    /// save path when `[editor] trim_trailing_ws_on_save = true`). Preserves
    /// the trailing newline, clamps the cursor onto the new end-of-line if it
    /// was sitting in trimmed whitespace, and refreshes syntax highlights.
    /// No-op when nothing needs trimming.
    pub fn apply_trim_trailing_ws(&mut self) {
        let original = self.editor.text();
        let mut out = String::with_capacity(original.len());
        let mut changed = false;
        let trailing_nl = original.ends_with('\n');
        let lines: Vec<&str> = if trailing_nl {
            // Skip the final empty "line after the last newline" so we don't
            // re-add a newline below.
            let mut v: Vec<&str> = original.split('\n').collect();
            v.pop();
            v
        } else {
            original.split('\n').collect()
        };
        for (i, line) in lines.iter().enumerate() {
            let trimmed = line.trim_end_matches([' ', '\t']);
            if trimmed.len() != line.len() {
                changed = true;
            }
            out.push_str(trimmed);
            if i + 1 < lines.len() || trailing_nl {
                out.push('\n');
            }
        }
        if !changed {
            return;
        }
        let (row, col) = self.editor.row_col();
        let end = self.editor.text().len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: 0,
            end,
            text: out,
        }];
        self.apply_edit_ops(ops, &mut crate::clipboard::Clipboard::new(), 0);
        // The replace landed the cursor at the end of the new text; put it
        // back, clamped to the (possibly-shortened) line.
        self.editor.place_cursor(row, col);
    }

    pub fn editing_mode(&self) -> EditingMode {
        self.input.mode()
    }

    fn make_ctx(&self) -> EditCtx {
        let (row, col) = self.editor.row_col();
        let line = self.editor.line_str(row);
        let cur = self.editor.cursor();
        // Pre-compute the closest find matches around the cursor so vim's
        // `gn` / `gN` text-objects (especially in operator-pending state)
        // can chain selection + operator atomically without re-scanning.
        let (next_match, prev_match) = match self.find.as_ref() {
            Some(f) if !f.matches.is_empty() => {
                // Vim's `gn` selects the match the cursor is *on* if any,
                // else the next one (wraps). `gN` is the mirror.
                let contains_cur = |(s, e): &&(usize, usize)| *s <= cur && cur < *e;
                let next = f
                    .matches
                    .iter()
                    .find(contains_cur)
                    .copied()
                    .or_else(|| f.matches.iter().find(|(s, _)| *s >= cur).copied())
                    .or_else(|| Some(f.matches[0]));
                let prev = f
                    .matches
                    .iter()
                    .rev()
                    .find(contains_cur)
                    .copied()
                    .or_else(|| f.matches.iter().rev().find(|(_, e)| *e <= cur).copied())
                    .or_else(|| f.matches.last().copied());
                (next, prev)
            }
            _ => (None, None),
        };
        EditCtx {
            cursor: cur,
            line_len: line.chars().count(),
            line_idx: row,
            line_count: self.editor.line_count(),
            at_line_start: col == 0,
            at_line_end: self.editor.is_at_line_end(),
            has_selection: self.editor.has_selection(),
            next_find_match: next_match,
            prev_find_match: prev_match,
        }
    }

    /// Feed one key through the handler → editor. `viewport_rows` is the editor
    /// body height (for page motions).
    pub fn feed_key(
        &mut self,
        key: KeyEvent,
        clipboard: &mut Clipboard,
        viewport_rows: usize,
    ) -> BufferEvent {
        if self.read_only {
            return BufferEvent::Unhandled(key);
        }
        let ctx = self.make_ctx();
        match self.input.handle_key(key, &ctx) {
            InputResult::Ops(ops) => {
                let mut changed = false;
                // Snapshot per-op so single-point edits get accurate line
                // deltas and folds can shift instead of being dropped.
                for op in ops {
                    let cursor_line_before = self.editor.row_col().0;
                    let lines_before = self.editor.line_count();
                    let out = self.editor.apply(op, viewport_rows, clipboard);
                    if out.buffer_changed {
                        let lines_after = self.editor.line_count();
                        let delta = lines_after as i64 - lines_before as i64;
                        if delta != 0 {
                            self.shift_folds_after(cursor_line_before, delta);
                        }
                    }
                    changed |= out.buffer_changed;
                }
                if changed {
                    self.recompute_dirty();
                    self.refresh_highlights();
                    self.refresh_find_matches();
                    self.last_edited = Some(Instant::now());
                    self.note_edit_position();
                    BufferEvent::Edited
                } else {
                    BufferEvent::Redraw
                }
            }
            InputResult::Consumed => BufferEvent::Redraw,
            InputResult::Ignored => BufferEvent::Unhandled(key),
            InputResult::App(cmd) => BufferEvent::App(cmd),
        }
    }

    /// Apply a batch of editor ops that didn't come from a key (LSP rename /
    /// code actions), then refresh the dirty flag + syntax highlights. Returns
    /// `true` if anything changed. `read_only` buffers are left untouched.
    pub fn apply_edit_ops(
        &mut self,
        ops: Vec<crate::edit_op::EditOp>,
        clipboard: &mut Clipboard,
        viewport_rows: usize,
    ) -> bool {
        if self.read_only {
            return false;
        }
        let mut changed = false;
        for op in ops {
            // Direction hint for fold-aware snap *after* the editor moves —
            // pulls the cursor out of any folded body it landed in.
            use crate::edit_op::EditOp as E;
            let direction = match &op {
                E::MoveDown | E::PageDown | E::HalfPageDown | E::MoveBufferEnd => Some(true),
                E::MoveUp | E::PageUp | E::HalfPageUp | E::MoveBufferStart => Some(false),
                E::Repeat(_, inner) => match inner.as_ref() {
                    E::MoveDown | E::PageDown | E::HalfPageDown => Some(true),
                    E::MoveUp | E::PageUp | E::HalfPageUp => Some(false),
                    _ => None,
                },
                _ => None,
            };
            changed |= self
                .editor
                .apply(op, viewport_rows, clipboard)
                .buffer_changed;
            if let Some(going_down) = direction {
                self.snap_cursor_out_of_fold(going_down);
            }
        }
        if changed {
            self.recompute_dirty();
            self.refresh_highlights();
            self.refresh_find_matches();
            self.last_edited = Some(Instant::now());
            self.folds.clear();
            self.note_edit_position();
        }
        changed
    }

    /// Shift fold start/end pairs so they survive a line-count change at
    /// `at_line` (the cursor's line at edit time). `delta` is the net line
    /// change (`+1` for an inserted newline, `-1` for a removed line, etc.).
    /// Folds *entirely above* `at_line` are unchanged. Folds *entirely
    /// below* shift by `delta`. Folds straddling `at_line` are dropped
    /// (they're likely broken). Negative deltas that would push a fold's
    /// start at-or-before `at_line` also drop the fold (collapsed too far).
    fn shift_folds_after(&mut self, at_line: usize, delta: i64) {
        if self.folds.is_empty() {
            return;
        }
        let pairs: Vec<(usize, usize)> = self.folds.iter().map(|(&s, &e)| (s, e)).collect();
        self.folds.clear();
        for (start, end) in pairs {
            // Above edit point — keep.
            if end < at_line {
                self.folds.insert(start, end);
                continue;
            }
            // Strictly below the edit line — shift both bounds.
            if start > at_line {
                let new_start = (start as i64 + delta).max(0) as usize;
                let new_end = (end as i64 + delta).max(0) as usize;
                if new_start < new_end {
                    self.folds.insert(new_start, new_end);
                }
                continue;
            }
            // Straddles `at_line` (the edit happened inside the fold) ⇒
            // drop. The fold's structure is no longer trustworthy.
        }
    }

    /// Append the cursor's current `(row, col)` to [`Self::edit_history`] —
    /// called after a text-changing edit. Skips when the new position is
    /// adjacent to the previous (same row, columns within a few of each
    /// other) so a burst of typing doesn't bury the change list. Resets the
    /// `g;`/`g,` walk cursor back to the end (after the newest entry).
    fn note_edit_position(&mut self) {
        let (row, col) = self.editor.row_col();
        let last = self.edit_history.last().copied();
        let near = last.is_some_and(|(r, c)| r == row && c.abs_diff(col) < 4);
        if !near {
            self.edit_history.push((row, col));
            if self.edit_history.len() > EDIT_HISTORY_MAX {
                let drop_n = self.edit_history.len() - EDIT_HISTORY_MAX;
                self.edit_history.drain(..drop_n);
            }
        }
        self.edit_history_cursor = self.edit_history.len();
    }

    /// Vim `g;` — walk to the previous entry on the change list and place
    /// the cursor there. Returns `Some((row, col))` of the new position,
    /// `None` when there's nothing further back. The walk position
    /// (`edit_history_cursor`) shifts down by one each call.
    pub fn jump_prev_edit(&mut self) -> Option<(usize, usize)> {
        if self.edit_history.is_empty() || self.edit_history_cursor == 0 {
            return None;
        }
        self.edit_history_cursor -= 1;
        let (row, col) = self.edit_history[self.edit_history_cursor];
        self.editor.place_cursor(row, col);
        Some((row, col))
    }

    /// Vim `g,` — walk forward through the change list (paired with `g;`).
    /// Returns `None` when already at the newest entry.
    pub fn jump_next_edit(&mut self) -> Option<(usize, usize)> {
        if self.edit_history_cursor + 1 >= self.edit_history.len() {
            return None;
        }
        self.edit_history_cursor += 1;
        let (row, col) = self.edit_history[self.edit_history_cursor];
        self.editor.place_cursor(row, col);
        Some((row, col))
    }

    /// Re-run the find-state's matches against the current text (no-op when no
    /// find is active). Cheap unless `query` is short on a huge file.
    pub fn refresh_find_matches(&mut self) {
        if let Some(f) = self.find.as_mut() {
            f.recompute(self.editor.text());
        }
    }

    // ─── folds ──────────────────────────────────────────────────────
    /// True when `line` (0-based) is inside any fold's *body* (i.e. should
    /// be hidden by the renderer). The fold's start line is *not* hidden.
    pub fn is_line_folded_body(&self, line: usize) -> bool {
        for (&start, &end) in &self.folds {
            if line > start && line <= end {
                return true;
            }
        }
        false
    }

    /// Walk the buffer's lines and produce the next visible file-line at or
    /// after `from`. Lines hidden by a fold's body are skipped. Returns
    /// `None` if every line at-or-after `from` is hidden (only possible at
    /// the trailing edge of the file).
    pub fn next_visible_line(&self, from: usize) -> Option<usize> {
        let n = self.editor.line_count();
        let mut line = from;
        while line < n {
            if !self.is_line_folded_body(line) {
                return Some(line);
            }
            line += 1;
        }
        None
    }

    /// Map a *visible* row index (0-based, starting at `start_file_line`) to
    /// the file line it points at. Skips any folded body. Returns `None`
    /// when `visible_row` runs past the end of the buffer.
    pub fn visible_to_file_row(&self, start_file_line: usize, visible_row: usize) -> Option<usize> {
        let n = self.editor.line_count();
        let mut visible = 0usize;
        let mut line = start_file_line;
        while line < n {
            if !self.is_line_folded_body(line) {
                if visible == visible_row {
                    return Some(line);
                }
                visible += 1;
            }
            line += 1;
        }
        None
    }

    /// Inverse of [`Self::visible_to_file_row`] — how many visible rows lie
    /// between `start_file_line` and `target_file_line` (exclusive). When
    /// `target_file_line` is hidden, returns the index of the fold's start
    /// instead so the caret has somewhere to land.
    pub fn file_to_visible_row(&self, start_file_line: usize, target_file_line: usize) -> usize {
        let mut visible = 0usize;
        let mut line = start_file_line;
        while line < target_file_line {
            if !self.is_line_folded_body(line) {
                visible += 1;
            }
            line += 1;
        }
        visible
    }

    /// Called from `apply_edit_ops` after a vertical motion lands the
    /// cursor inside a folded body. `going_down=true` jumps the cursor
    /// past the fold (to the line after its end); `false` retreats to
    /// the fold's start. No-op when the cursor is on a visible line.
    pub fn snap_cursor_out_of_fold(&mut self, going_down: bool) {
        let row = self.editor.row_col().0;
        let Some(start) = self.fold_owner_of(row) else {
            return;
        };
        let end = self.folds.get(&start).copied().unwrap_or(start);
        let line_count = self.editor.line_count();
        let target = if going_down {
            (end + 1).min(line_count.saturating_sub(1))
        } else {
            start
        };
        self.editor.place_cursor(target, 0);
    }

    /// If `line` sits inside a fold's body, return the fold's start line —
    /// useful for snapping the cursor out of hidden space.
    pub fn fold_owner_of(&self, line: usize) -> Option<usize> {
        self.folds
            .iter()
            .find(|&(&start, &end)| line > start && line <= end)
            .map(|(&start, _)| start)
    }
}

/// Files conventionally named without an extension (`Makefile`, `Rakefile`, …)
/// — pick the highlight/comment language from the filename instead.
fn ext_for_filename(path: &Path) -> Option<String> {
    let name = path.file_name().and_then(|n| n.to_str())?;
    let ext = match name {
        "Makefile" | "makefile" | "GNUmakefile" => "make",
        "Rakefile" | "Gemfile" | "Vagrantfile" | "Brewfile" | "Podfile" | "Fastfile" => "rb",
        ".env" | ".envrc" => "sh",
        _ => return None,
    };
    Some(ext.to_string())
}

fn comment_token_for(ext: Option<&str>) -> &'static str {
    match ext {
        Some(
            "rs" | "ts" | "tsx" | "js" | "jsx" | "cjs" | "mjs" | "c" | "cpp" | "h" | "hpp" | "cs"
            | "go" | "java" | "kt" | "swift" | "php" | "scss" | "less",
        ) => "// ",
        Some("py" | "rb" | "sh" | "bash" | "zsh" | "toml" | "yaml" | "yml" | "ini" | "conf") => {
            "# "
        }
        Some("lua" | "sql") => "-- ",
        Some("html" | "htm" | "xml" | "vue" | "svelte") => "<!-- ", // close token is wired with comment support later
        _ => "// ",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn filename_fallback_recognises_makefile_and_rakefile() {
        assert_eq!(
            ext_for_filename(Path::new("Makefile")).as_deref(),
            Some("make")
        );
        assert_eq!(
            ext_for_filename(Path::new("GNUmakefile")).as_deref(),
            Some("make")
        );
        assert_eq!(
            ext_for_filename(Path::new("/x/Rakefile")).as_deref(),
            Some("rb")
        );
        assert_eq!(
            ext_for_filename(Path::new("Gemfile")).as_deref(),
            Some("rb")
        );
        assert_eq!(ext_for_filename(Path::new(".env")).as_deref(), Some("sh"));
        assert_eq!(ext_for_filename(Path::new("not-special.txt")), None);
    }

    #[test]
    fn find_all_ci_ascii_finds_overlapping_at_non_overlapping_positions() {
        // case-insensitive, non-overlapping (advance past each match).
        assert_eq!(
            find_all_ci_ascii("foo Foo fOO bar", "foo"),
            vec![(0, 3), (4, 7), (8, 11)]
        );
        // empty query / text shorter than query.
        assert!(find_all_ci_ascii("hello", "").is_empty());
        assert!(find_all_ci_ascii("hi", "hello").is_empty());
        // non-overlap: "aaaa" with query "aa" → (0,2) (2,4), not (0,2)(1,3)(2,4).
        assert_eq!(find_all_ci_ascii("aaaa", "aa"), vec![(0, 2), (2, 4)]);
        // UTF-8 boundary safety: text contains a multi-byte char, query is ASCII.
        let t = "café fé";
        let r = find_all_ci_ascii(t, "fé");
        // both occurrences match — the function falls back to byte-exact for
        // non-ASCII, so case is preserved.
        assert_eq!(r.len(), 2);
        for (s, e) in r {
            assert!(t.is_char_boundary(s));
            assert!(t.is_char_boundary(e));
        }
    }

    #[test]
    fn shift_folds_after_below_edit_shifts_both_bounds() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n7\n").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.folds.insert(5, 6); // fold lines 5..=6
        b.shift_folds_after(2, 1); // inserted a line at row 2, lines below shift +1
        // Old fold at 5..=6 ⇒ now at 6..=7.
        assert!(b.folds.contains_key(&6));
        assert_eq!(b.folds.get(&6).copied(), Some(7));
    }

    #[test]
    fn shift_folds_after_above_edit_preserved() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.folds.insert(0, 2); // above the edit
        b.shift_folds_after(5, -1);
        assert_eq!(b.folds.get(&0).copied(), Some(2));
    }

    #[test]
    fn shift_folds_after_straddling_dropped() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.folds.insert(2, 5); // contains the edit line 3
        b.shift_folds_after(3, 1);
        assert!(b.folds.is_empty());
    }

    #[test]
    fn fold_visibility_helpers_skip_body() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        // Fold lines [2..=4]
        b.folds.insert(2, 4);
        // Body = 3, 4
        assert!(!b.is_line_folded_body(2)); // start visible
        assert!(b.is_line_folded_body(3));
        assert!(b.is_line_folded_body(4));
        assert!(!b.is_line_folded_body(5));
        // visible_to_file_row should skip the body. File has 8 logical
        // lines (final "\n" produces a trailing empty line 7).
        assert_eq!(b.visible_to_file_row(0, 0), Some(0));
        assert_eq!(b.visible_to_file_row(0, 2), Some(2));
        assert_eq!(b.visible_to_file_row(0, 3), Some(5));
        assert_eq!(b.visible_to_file_row(0, 4), Some(6));
        assert_eq!(b.visible_to_file_row(0, 5), Some(7));
        assert_eq!(b.visible_to_file_row(0, 6), None);
        // file_to_visible_row
        assert_eq!(b.file_to_visible_row(0, 5), 3);
    }

    #[test]
    fn snap_cursor_out_of_fold_picks_direction() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        b.folds.insert(2, 4);
        // Place cursor in body (line 3), snap down → line 5
        b.editor.place_cursor(3, 0);
        b.snap_cursor_out_of_fold(true);
        assert_eq!(b.editor.row_col().0, 5);
        // Body again (line 4), snap up → line 2
        b.editor.place_cursor(4, 0);
        b.snap_cursor_out_of_fold(false);
        assert_eq!(b.editor.row_col().0, 2);
        // Cursor on visible line — no-op.
        b.editor.place_cursor(0, 0);
        b.snap_cursor_out_of_fold(true);
        assert_eq!(b.editor.row_col().0, 0);
    }

    #[test]
    fn edits_clear_folds() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        b.folds.insert(0, 2);
        let mut clip = crate::clipboard::Clipboard::new();
        b.apply_edit_ops(vec![crate::edit_op::EditOp::InsertChar('x')], &mut clip, 0);
        assert!(b.folds.is_empty());
    }

    #[test]
    fn find_all_case_sensitive_basic() {
        assert_eq!(find_all_case_sensitive("foo Foo foO", "foo"), vec![(0, 3)]);
        assert_eq!(
            find_all_case_sensitive("Foo Foo Foo", "Foo"),
            vec![(0, 3), (4, 7), (8, 11)]
        );
        assert!(find_all_case_sensitive("anything", "").is_empty());
    }

    #[test]
    fn find_state_recompute_keeps_current_in_range() {
        let mut f = FindState {
            query: "abc".into(),
            ..Default::default()
        };
        f.recompute("abc x abc y abc");
        assert_eq!(f.matches.len(), 3);
        f.current = Some(2);
        f.recompute("abc x abc"); // shrunk: only 2 matches now
        assert_eq!(f.matches.len(), 2);
        assert_eq!(f.current, Some(1));
        f.recompute(""); // no matches → current cleared
        assert!(f.matches.is_empty());
        assert!(f.current.is_none());
    }

    #[test]
    fn trim_trailing_ws_on_save_strips_and_preserves_cursor() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("x.txt");
        std::fs::write(&path, "  hi   \n  there\t\nlast  ").unwrap();
        let mut cfg = Config::default();
        cfg.editor.trim_trailing_ws_on_save = true;
        // Disable ensure_trailing_newline for this test so the assertion
        // focuses on trim behavior alone.
        cfg.editor.ensure_trailing_newline = false;
        let mut b = Buffer::open(&path, &cfg).unwrap();
        b.editor.place_cursor(0, 4); // on `hi` (col 4 is inside the trailing ws)
        b.save_to_disk().unwrap();
        let on_disk = std::fs::read_to_string(&path).unwrap();
        // Each line's trailing space/tab gone; final no-newline line trimmed too.
        assert_eq!(on_disk, "  hi\n  there\nlast");
        // Cursor was at col 4 (in the trimmed region) — clamp to new line end.
        assert_eq!(b.editor.row_col(), (0, 4));
    }

    #[test]
    fn trim_trailing_ws_off_leaves_file_alone() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("x.txt");
        std::fs::write(&path, "hi   \n").unwrap();
        let cfg = Config::default(); // trim_trailing_ws_on_save = false
        let mut b = Buffer::open(&path, &cfg).unwrap();
        b.save_to_disk().unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hi   \n");
    }

    #[test]
    fn find_all_regex_basic_patterns() {
        // Literal-like.
        assert_eq!(find_all_regex("foo bar foo", "foo"), vec![(0, 3), (8, 11)]);
        // Character class.
        let t = "abc 123 def 45";
        assert_eq!(find_all_regex(t, r"\d+"), vec![(4, 7), (12, 14)]);
        // Anchors + case-insensitive default.
        assert_eq!(find_all_regex("FOO foo", r"^foo"), vec![(0, 3)]);
        // Empty / invalid ⇒ empty.
        assert!(find_all_regex("anything", "").is_empty());
        assert!(find_all_regex("anything", r"[").is_empty());
    }

    #[test]
    fn find_state_recompute_honors_regex_flag() {
        let t = "x1 y22 z333";
        let mut s = FindState {
            query: r"\w\d+".into(),
            regex: false,
            ..Default::default()
        };
        s.recompute(t);
        // Literal mode treats `\w\d+` as a literal string ⇒ no matches.
        assert!(s.matches.is_empty());
        s.regex = true;
        s.recompute(t);
        assert_eq!(s.matches, vec![(0, 2), (3, 6), (7, 11)]);
    }

    fn buf_with_lines(lines: usize) -> Buffer {
        // Many tests touch positions like (3, 5) which `place_cursor` would
        // clamp on an empty scratch buffer. Open a real file with `lines`
        // padded lines so coordinates land where we expect.
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("scratch.txt");
        let body = (0..lines)
            .map(|_| "0123456789".to_string())
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(&p, body).unwrap();
        Buffer::open(&p, &Config::default()).unwrap()
    }

    #[test]
    fn ensure_trailing_newline_appends_when_missing() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("nl.txt");
        fs::write(&p, "no newline").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.save_to_disk().unwrap();
        let on_disk = fs::read_to_string(&p).unwrap();
        assert_eq!(on_disk, "no newline\n");
    }

    #[test]
    fn ensure_trailing_newline_skips_when_present() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("nl.txt");
        fs::write(&p, "ok\n").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        // Force a save (text matches → dirty is false → save_to_disk no-ops
        // for dirty checks but we still want the file write).
        b.save_to_disk().unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "ok\n");
    }

    #[test]
    fn ensure_trailing_newline_skips_empty_buffer() {
        let cfg = Config::default();
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("empty.txt");
        fs::write(&p, "").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.save_to_disk().unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "");
    }

    #[test]
    fn ensure_trailing_newline_off_leaves_file_alone() {
        let mut cfg = Config::default();
        cfg.editor.ensure_trailing_newline = false;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("no-nl.txt");
        fs::write(&p, "x").unwrap();
        let mut b = Buffer::open(&p, &cfg).unwrap();
        b.save_to_disk().unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "x");
    }

    #[test]
    fn edit_history_dedups_nearby_positions() {
        let mut b = buf_with_lines(10);
        // Place at (0, 0) and record. Then place at (0, 1) (adjacent col,
        // within the dedup threshold) — should NOT push a new entry.
        b.editor.place_cursor(0, 0);
        b.note_edit_position();
        b.editor.place_cursor(0, 1);
        b.note_edit_position();
        assert_eq!(b.edit_history.len(), 1);
        // Move to a different row → a new entry.
        b.editor.place_cursor(2, 0);
        b.note_edit_position();
        assert_eq!(b.edit_history.len(), 2);
    }

    #[test]
    fn edit_history_jump_prev_next_walks_history() {
        let mut b = buf_with_lines(10);
        // Build a history of three distinct positions.
        for (r, c) in &[(0usize, 0usize), (3, 5), (7, 1)] {
            b.editor.place_cursor(*r, *c);
            b.note_edit_position();
        }
        assert_eq!(b.edit_history.len(), 3);
        // After the last edit, cursor index sits past the newest. `g;`
        // walks back through them.
        assert_eq!(b.jump_prev_edit(), Some((7, 1)));
        assert_eq!(b.jump_prev_edit(), Some((3, 5)));
        assert_eq!(b.jump_prev_edit(), Some((0, 0)));
        assert_eq!(b.jump_prev_edit(), None); // exhausted
        // `g,` walks forward.
        assert_eq!(b.jump_next_edit(), Some((3, 5)));
        assert_eq!(b.jump_next_edit(), Some((7, 1)));
        assert_eq!(b.jump_next_edit(), None); // already at newest
    }
}
