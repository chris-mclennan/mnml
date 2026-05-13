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
}

impl FindState {
    pub fn recompute(&mut self, text: &str) {
        self.matches = if self.regex {
            find_all_regex(text, &self.query)
        } else if self.case_sensitive {
            find_all_case_sensitive(text, &self.query)
        } else {
            find_all_ci_ascii(text, &self.query)
        };
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
    /// Stamp of the last text-changing edit (used by `[editor] autosave_secs`).
    /// `None` until the first edit; cleared back to `None` on save.
    pub last_edited: Option<Instant>,
    /// `Some` when an in-buffer find is active (matches recomputed on every edit).
    pub find: Option<FindState>,
    /// Strip trailing whitespace from each line before writing. Honored by
    /// [`Self::save_to_disk`] + [`Self::save_as`]. Read from config at open.
    pub trim_trailing_ws_on_save: bool,
    /// Vim-style local marks (lowercase `a`-`z`), keyed by letter and stored as
    /// `(row, col)`. Set by `m<letter>`, jumped by `'<letter>` (line) or
    /// `` `<letter>`` (exact). Lost on buffer close (no persistence yet;
    /// uppercase / global marks would live on `App` and persist in session.json).
    pub marks: std::collections::HashMap<char, (usize, usize)>,
}

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
            last_edited: None,
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            marks: std::collections::HashMap::new(),
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
            last_edited: None,
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            marks: std::collections::HashMap::new(),
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
        let path = self.path.clone().unwrap();
        std::fs::write(&path, self.editor.text())?;
        self.saved_text = self.editor.text().to_string();
        self.dirty = false;
        self.last_edited = None;
        Ok(())
    }

    /// `:w <path>` — write the current text to `path`, then repoint the buffer
    /// at it (subsequent `:w` writes there). Errors propagate as `Err`.
    pub fn save_as(&mut self, path: PathBuf) -> std::io::Result<()> {
        if self.trim_trailing_ws_on_save {
            self.apply_trim_trailing_ws();
        }
        std::fs::write(&path, self.editor.text())?;
        self.path = Some(path);
        self.saved_text = self.editor.text().to_string();
        self.dirty = false;
        self.last_edited = None;
        Ok(())
    }

    /// Strip trailing space/tab from every line in the buffer (called from the
    /// save path when `[editor] trim_trailing_ws_on_save = true`). Preserves
    /// the trailing newline, clamps the cursor onto the new end-of-line if it
    /// was sitting in trimmed whitespace, and refreshes syntax highlights.
    /// No-op when nothing needs trimming.
    fn apply_trim_trailing_ws(&mut self) {
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
        EditCtx {
            cursor: self.editor.cursor(),
            line_len: line.chars().count(),
            line_idx: row,
            line_count: self.editor.line_count(),
            at_line_start: col == 0,
            at_line_end: self.editor.is_at_line_end(),
            has_selection: self.editor.has_selection(),
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
                for op in ops {
                    let out = self.editor.apply(op, viewport_rows, clipboard);
                    changed |= out.buffer_changed;
                }
                if changed {
                    self.recompute_dirty();
                    self.refresh_highlights();
                    self.refresh_find_matches();
                    self.last_edited = Some(Instant::now());
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
            changed |= self
                .editor
                .apply(op, viewport_rows, clipboard)
                .buffer_changed;
        }
        if changed {
            self.recompute_dirty();
            self.refresh_highlights();
            self.refresh_find_matches();
            self.last_edited = Some(Instant::now());
        }
        changed
    }

    /// Re-run the find-state's matches against the current text (no-op when no
    /// find is active). Cheap unless `query` is short on a huge file.
    pub fn refresh_find_matches(&mut self) {
        if let Some(f) = self.find.as_mut() {
            f.recompute(self.editor.text());
        }
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
}
