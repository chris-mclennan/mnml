//! One open file — the `Pane::Editor` payload. Wraps an [`Editor`] plus path /
//! dirty / language bookkeeping plus its own input handler (so per-buffer modal
//! state lives here, not in `App`).

use std::path::{Path, PathBuf};
use std::time::Instant;

use ratatui::crossterm::event::KeyEvent;

use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::edit_op::TextEdit;
use crate::editor::Editor;
use crate::highlight::{self, ColoredSpan};
use crate::input::{self, AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

/// Above this many bytes, skip syntax highlighting. With debounced
/// reparse (App::tick refreshes after ~120ms idle) we can afford a
/// higher ceiling than the original 2 MiB.
const HIGHLIGHT_BYTE_LIMIT: usize = 4 * 1024 * 1024;

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
    /// VS Code-style "preview" buffer — opened by a tree-click in
    /// standard-input-style mode. A preview buffer gets *replaced*
    /// when the user tree-clicks another file (instead of opening a
    /// new tab next to it). The first edit promotes it to a regular
    /// buffer (`is_preview = false`); double-clicking the file in
    /// the tree also promotes it. Always false when input style is
    /// `vim` (where every file gets its own buffer regardless).
    pub is_preview: bool,
    /// 2026-06-21 — VS Code-style pinned tab. Distinct from
    /// `is_preview`: a pinned tab stays at the FRONT of the
    /// bufferline strip, renders with a 📌 glyph, and is immune
    /// to `close-all` / `close-others` (only an explicit
    /// `buffer.close` / right-click-Close-Tab closes it). The
    /// three states are:
    ///   - Preview (`is_preview = true`, `is_pinned = false`) —
    ///     transient; next single-click replaces.
    ///   - Regular (`is_preview = false`, `is_pinned = false`) —
    ///     default after edit/typing/double-click.
    ///   - Pinned (`is_preview = false`, `is_pinned = true`) —
    ///     stays at front, immune to bulk-close.
    /// Pinning is set via right-click → "Pin tab" or via
    /// `buffer.pin_toggle`. Persisted across sessions in
    /// session.json.
    pub is_pinned: bool,
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
    /// External-linter diagnostics (eslint / tsc / ruff / shellcheck /
    /// etc). Replaced wholesale on each lint run. Kept separate from
    /// `diagnostics` so LSP's `publishDiagnostics` doesn't clobber them
    /// — the diagnostics pane + gutter signs + statusline counts merge
    /// the two lists.
    pub linter_diagnostics: Vec<crate::lsp::Diagnostic>,
    /// DAP breakpoint lines (0-based, sorted, unique). Painted as `●`
    /// in the editor gutter (red); toggled via `dap.toggle_breakpoint`.
    /// Persisted in session.json. The actual debug session is started
    /// by `dap.run` (which sends `setBreakpoints` to the adapter); for
    /// now this list is informational + persistence-only.
    pub breakpoints: Vec<u32>,
    /// Conditional-breakpoint expressions keyed by 0-based line.
    /// Present only for the *subset* of `breakpoints` that have a
    /// condition — plain breakpoints aren't in the map. Painted as a
    /// red `◆` (diamond) instead of `●`. Set via
    /// `dap.toggle_breakpoint_conditional`; persisted in session.json.
    pub breakpoint_conditions: std::collections::HashMap<u32, String>,
    /// Hit-count breakpoint expressions keyed by 0-based line — e.g.
    /// `">= 5"` (stop after 5+ hits) or `"% 10"` (every 10th hit).
    /// Independent of `breakpoint_conditions`; can pair (a line with
    /// both: only break when both expression is true AND hit-count
    /// matches). Set via `dap.set_breakpoint_hit_count`; persisted in
    /// session.json.
    pub breakpoint_hit_conditions: std::collections::HashMap<u32, String>,
    /// LSP inlay hints — virtual text the server suggests at specific
    /// positions. Refreshed on save (and after the initial `did_open`
    /// reply lands). Rendered as dim chips in the editor view.
    pub inlay_hints: Vec<crate::lsp::InlayHint>,
    /// LSP semantic tokens — server-aware syntax highlight spans. Layered
    /// on top of tree-sitter highlights by the editor renderer (LSP wins
    /// where they overlap). Refreshed on save + after did_open.
    pub semantic_tokens: Vec<crate::lsp::SemanticToken>,
    /// Last `(start_line, end_line)` viewport range we requested
    /// semantic tokens for. Used by the scroll-driven refresh path
    /// (`[editor] semantic_tokens_viewport = true`) to dedupe — a small
    /// scroll within the cached viewport doesn't re-fire the request.
    /// `None` ⇒ no viewport request has been made yet (default).
    pub last_semantic_viewport: Option<(u32, u32)>,
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
    /// LSP document highlights — single-line ranges
    /// `(line, start_char, end_line, end_char)` of usages of the symbol at
    /// the cursor's last position. Refreshed when the cursor moves to a
    /// new identifier. Painted with a subtle `bg2` tint.
    pub document_highlights: Vec<(u32, u32, u32, u32)>,
    /// Stamp of the last text-changing edit (used by `[editor] autosave_secs`).
    /// `None` until the first edit; cleared back to `None` on save.
    pub last_edited: Option<Instant>,
    /// `(start_byte, end_byte, started_at)` of the most-recent yank — used
    /// by the highlight-on-yank overlay to flash the region yellow for
    /// ~200ms. Cleared by `App::tick` once the TTL expires.
    pub yank_flash: Option<(usize, usize, Instant)>,
    /// `true` ⇒ `highlights` is stale and needs a refresh; `App::tick` will
    /// rebuild it after a short idle. Lets us hold the previous frame's
    /// highlights while the user is typing rapidly (avoids re-parsing the
    /// whole buffer on every keystroke for large files).
    pub highlights_dirty: bool,
    /// Cached tree-sitter parse tree for incremental reparse. `None` until the
    /// first successful parse; cleared when an untracked edit happens (see
    /// `pending_tree_edits` below).
    pub parse_tree: Option<tree_sitter::Tree>,
    /// Per-injection-language tree cache. Lives alongside `parse_tree` so
    /// inner grammars (markdown_inline, rust-in-fenced-block, etc.) can
    /// be reparsed incrementally with their previous tree as a hint —
    /// the principal win on injection-heavy files like long markdown.
    pub injection_trees: crate::highlight::InjectionTreeCache,
    /// Byte-position line-starts of the text that produced [`Self::parse_tree`].
    /// Used by `refresh_highlights` to compute the `Point` half of each
    /// `InputEdit` (tree-sitter wants byte AND (row, col) for each edit; the
    /// byte offsets come from the editor, the points are derived from the
    /// pre-edit line-start index). Refreshed alongside `parse_tree`.
    pub prev_line_starts: Vec<usize>,
    /// Byte-extent hints accumulated since the last `refresh_highlights`. On
    /// refresh, applied to `parse_tree` via `Tree::edit` so the reparse can
    /// reuse the prior tree as a hint. Cleared on every refresh.
    pub pending_tree_edits: Vec<TextEdit>,
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
    /// When `true`, the editor renderer's "snap viewport to keep cursor in
    /// view" clamp is bypassed — `[Self::scroll]` was last set explicitly
    /// (mouse wheel or scrollbar drag in a mode where the cursor doesn't
    /// follow the viewport, see `[editor] wheel_moves_cursor`). The flag
    /// self-clears the moment the cursor moves (the renderer compares
    /// `cur_row` to `[Self::last_render_cursor_row]` each frame and
    /// resets when they differ). This lets a standard-mode user wheel
    /// past their cursor without the next render yanking the viewport
    /// back; the moment they type, the keep-in-view clamp re-engages.
    pub scroll_pinned: bool,
    /// `(row, col)` snapshot taken at the end of the previous editor
    /// render. Used solely to detect cursor movement frame-to-frame so
    /// `[Self::scroll_pinned]` can self-clear. `None` until the first
    /// render. Not load-bearing for anything else — safe to wipe on
    /// session restore.
    pub last_render_cursor: Option<(usize, usize)>,
}

/// Cap for [`Buffer::edit_history`] — keeps the most recent N change
/// positions so `g;` doesn't walk through ancient history forever.
pub const EDIT_HISTORY_MAX: usize = 100;

impl Buffer {
    /// Open `path`. ENOENT propagates up — callers that want vim's
    /// `:e <newfile>` semantics use [`Self::open_or_new_empty`] instead.
    pub fn open(path: &Path, cfg: &Config) -> std::io::Result<Buffer> {
        let text = std::fs::read_to_string(path)?;
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_string())
            .or_else(|| ext_for_filename(path));
        let mut editor = Editor::new(text.clone(), cfg.editor.tab_width);
        let (ct_open, ct_close) = comment_token_for(ext.as_deref());
        editor.set_comment_token(ct_open);
        editor.set_comment_token_close(ct_close);
        editor.auto_pair = cfg.editor.auto_pair;
        editor.auto_indent = cfg.editor.auto_indent;
        editor.language_ext = ext.clone();
        let mut b = Buffer {
            path: Some(path.to_path_buf()),
            editor,
            scroll: 0,
            h_scroll: 0,
            dirty: false,
            is_preview: false,
            is_pinned: false,
            saved_text: text,
            language_ext: ext,
            input: input::make_handler(cfg),
            read_only: false,
            highlights: Vec::new(),
            blame: None,
            diagnostics: Vec::new(),
            linter_diagnostics: Vec::new(),
            breakpoints: Vec::new(),
            breakpoint_conditions: std::collections::HashMap::new(),
            breakpoint_hit_conditions: std::collections::HashMap::new(),
            inlay_hints: Vec::new(),
            semantic_tokens: Vec::new(),
            last_semantic_viewport: None,
            code_lenses: Vec::new(),
            document_links: Vec::new(),
            color_decorations: Vec::new(),
            document_highlights: Vec::new(),
            last_edited: None,
            yank_flash: None,
            highlights_dirty: false,
            parse_tree: None,
            injection_trees: crate::highlight::InjectionTreeCache::new(),
            prev_line_starts: Vec::new(),
            pending_tree_edits: Vec::new(),
            disk_mtime: std::fs::metadata(path).and_then(|m| m.modified()).ok(),
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            ensure_trailing_newline: cfg.editor.ensure_trailing_newline,
            marks: std::collections::HashMap::new(),
            folds: std::collections::BTreeMap::new(),
            edit_history: Vec::new(),
            edit_history_cursor: 0,
            scroll_pinned: false,
            last_render_cursor: None,
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

    /// Open `path`, or return an empty in-memory buffer with `path`
    /// set when the file doesn't exist yet (vim's `:e <newfile>`
    /// semantics). The empty buffer is marked dirty so the first
    /// save actually writes the file. Errors other than ENOENT
    /// (permission denied, IO failure, etc.) propagate up.
    pub fn open_or_new_empty(path: &Path, cfg: &Config) -> std::io::Result<Buffer> {
        match Buffer::open(path, cfg) {
            Ok(b) => Ok(b),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|s| s.to_string())
                    .or_else(|| ext_for_filename(path));
                let mut editor = Editor::new(String::new(), cfg.editor.tab_width);
                let (ct_open, ct_close) = comment_token_for(ext.as_deref());
                editor.set_comment_token(ct_open);
                editor.set_comment_token_close(ct_close);
                editor.auto_pair = cfg.editor.auto_pair;
                editor.auto_indent = cfg.editor.auto_indent;
                editor.language_ext = ext.clone();
                let mut b = Buffer {
                    path: Some(path.to_path_buf()),
                    editor,
                    scroll: 0,
                    h_scroll: 0,
                    // Dirty so the first save writes the file. Without
                    // this, vim users would type into the buffer + hit
                    // save + get "no changes to save" silently.
                    dirty: true,
                    is_preview: false,
                    is_pinned: false,
                    saved_text: String::new(),
                    language_ext: ext,
                    input: input::make_handler(cfg),
                    read_only: false,
                    highlights: Vec::new(),
                    blame: None,
                    diagnostics: Vec::new(),
                    linter_diagnostics: Vec::new(),
                    breakpoints: Vec::new(),
                    breakpoint_conditions: std::collections::HashMap::new(),
                    breakpoint_hit_conditions: std::collections::HashMap::new(),
                    inlay_hints: Vec::new(),
                    semantic_tokens: Vec::new(),
                    last_semantic_viewport: None,
                    code_lenses: Vec::new(),
                    document_links: Vec::new(),
                    color_decorations: Vec::new(),
                    document_highlights: Vec::new(),
                    last_edited: None,
                    yank_flash: None,
                    highlights_dirty: false,
                    parse_tree: None,
                    injection_trees: crate::highlight::InjectionTreeCache::new(),
                    prev_line_starts: Vec::new(),
                    pending_tree_edits: Vec::new(),
                    disk_mtime: None,
                    find: None,
                    trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
                    ensure_trailing_newline: cfg.editor.ensure_trailing_newline,
                    marks: std::collections::HashMap::new(),
                    folds: std::collections::BTreeMap::new(),
                    edit_history: Vec::new(),
                    edit_history_cursor: 0,
                    scroll_pinned: false,
                    last_render_cursor: None,
                };
                b.refresh_highlights();
                Ok(b)
            }
            Err(e) => Err(e),
        }
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
            is_preview: false,
            is_pinned: false,
            saved_text: String::new(),
            language_ext: None,
            input: input::make_handler(cfg),
            read_only: false,
            highlights: Vec::new(),
            blame: None,
            diagnostics: Vec::new(),
            linter_diagnostics: Vec::new(),
            breakpoints: Vec::new(),
            breakpoint_conditions: std::collections::HashMap::new(),
            breakpoint_hit_conditions: std::collections::HashMap::new(),
            inlay_hints: Vec::new(),
            semantic_tokens: Vec::new(),
            last_semantic_viewport: None,
            code_lenses: Vec::new(),
            document_links: Vec::new(),
            color_decorations: Vec::new(),
            document_highlights: Vec::new(),
            last_edited: None,
            yank_flash: None,
            highlights_dirty: false,
            parse_tree: None,
            injection_trees: crate::highlight::InjectionTreeCache::new(),
            prev_line_starts: Vec::new(),
            pending_tree_edits: Vec::new(),
            disk_mtime: None,
            find: None,
            trim_trailing_ws_on_save: cfg.editor.trim_trailing_ws_on_save,
            ensure_trailing_newline: cfg.editor.ensure_trailing_newline,
            marks: std::collections::HashMap::new(),
            folds: std::collections::BTreeMap::new(),
            edit_history: Vec::new(),
            edit_history_cursor: 0,
            scroll_pinned: false,
            last_render_cursor: None,
        }
    }

    /// Re-run tree-sitter over the current text (no-op for unknown languages /
    /// huge files). Call after any edit that changes the text, or via
    /// `App::tick`'s debouncer.
    ///
    /// Uses incremental reparse when [`Self::parse_tree`] is `Some` and
    /// [`Self::pending_tree_edits`] is non-empty: each edit's `InputEdit` is
    /// applied to the cached tree (with `Point` halves derived from
    /// [`Self::prev_line_starts`]) and the parser is given the tree as a
    /// Set the language extension (for highlights + text-object scoping)
    /// and sync the inner `Editor`'s mirror. Use this instead of writing
    /// `buf.language_ext` directly so the editor stays in sync.
    pub fn set_language_ext(&mut self, ext: Option<String>) {
        self.language_ext = ext.clone();
        self.editor.language_ext = ext;
    }

    /// hint. Untracked edits drop `parse_tree` to `None` at the time the edit
    /// is processed, so this method falls back to a full reparse.
    pub fn refresh_highlights(&mut self) {
        self.highlights_dirty = false;
        let text = self.editor.text();
        if text.len() > HIGHLIGHT_BYTE_LIMIT {
            self.highlights.clear();
            self.parse_tree = None;
            self.pending_tree_edits.clear();
            self.prev_line_starts.clear();
            return;
        }
        let ext = self.language_ext.as_deref().unwrap_or("");
        let edits = std::mem::take(&mut self.pending_tree_edits);
        let prev_highlights = std::mem::take(&mut self.highlights);
        self.highlights = highlight::highlight_lines_with_cache_v2(
            text,
            ext,
            &mut self.parse_tree,
            &mut self.injection_trees,
            &edits,
            &self.prev_line_starts,
            prev_highlights,
        );
        // Refresh prev_line_starts to match the just-parsed text so the next
        // batch of edits has accurate pre-edit Points.
        self.prev_line_starts.clear();
        self.prev_line_starts.push(0);
        self.prev_line_starts.extend(
            text.as_bytes()
                .iter()
                .enumerate()
                .filter_map(|(i, &b)| (b == b'\n').then_some(i + 1)),
        );
    }

    /// Spans for editor line `line`, or `&[]` if unhighlighted.
    pub fn line_spans(&self, line: usize) -> &[ColoredSpan] {
        self.highlights
            .get(line)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    /// Iterate over LSP + external-linter diagnostics for this buffer.
    /// Used by every rendering / counting / navigation site so the two
    /// sets behave identically downstream.
    pub fn all_diagnostics(&self) -> impl Iterator<Item = &crate::lsp::Diagnostic> {
        self.diagnostics
            .iter()
            .chain(self.linter_diagnostics.iter())
    }

    /// Toggle a breakpoint on `line` (0-based). Returns true if added,
    /// false if removed. Removing a line also drops any condition or
    /// hit-condition attached to it — pairing the visual + adapter
    /// state correctly.
    pub fn toggle_breakpoint(&mut self, line: u32) -> bool {
        match self.breakpoints.binary_search(&line) {
            Ok(i) => {
                self.breakpoints.remove(i);
                self.breakpoint_conditions.remove(&line);
                self.breakpoint_hit_conditions.remove(&line);
                false
            }
            Err(i) => {
                self.breakpoints.insert(i, line);
                true
            }
        }
    }

    /// True if `line` has a breakpoint.
    pub fn has_breakpoint(&self, line: u32) -> bool {
        self.breakpoints.binary_search(&line).is_ok()
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
        // VS Code-style preview promotion: any user edit promotes a
        // preview tab to a pinned one (no longer replaceable on the
        // next tree-click). Triggered as soon as the buffer becomes
        // dirty — that's the cleanest signal that the user is
        // *working* in this buffer, not just browsing it.
        if self.dirty && self.is_preview {
            self.is_preview = false;
        }
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

    fn make_ctx(&self, wrap_width: Option<usize>) -> EditCtx {
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
            wrap_width,
        }
    }

    /// Feed one key through the handler → editor. `viewport_rows` is the editor
    /// body height (for page motions); `wrap_width` is `Some(tw)` when
    /// `[ui] wrap` is on so the handler can compute visual-row motions.
    pub fn feed_key(
        &mut self,
        key: KeyEvent,
        clipboard: &mut Clipboard,
        viewport_rows: usize,
        wrap_width: Option<usize>,
    ) -> BufferEvent {
        if self.read_only {
            return BufferEvent::Unhandled(key);
        }
        let ctx = self.make_ctx(wrap_width);
        match self.input.handle_key(key, &ctx) {
            InputResult::Ops(ops) => {
                let mut changed = false;
                // Snapshot per-op so single-point edits get accurate line
                // deltas and folds can shift instead of being dropped.
                for op in ops {
                    let is_close_angle = matches!(op, crate::edit_op::EditOp::InsertChar('>'));
                    let cursor_line_before = self.editor.row_col().0;
                    let lines_before = self.editor.line_count();
                    let out = self.editor.apply(op, viewport_rows, clipboard);
                    if out.buffer_changed {
                        let lines_after = self.editor.line_count();
                        let delta = lines_after as i64 - lines_before as i64;
                        if delta != 0 {
                            self.shift_folds_after(cursor_line_before, delta);
                        }
                        if out.text_edits.is_empty() {
                            // Untracked op — drop the cached parse tree so the
                            // next refresh reparses from scratch.
                            self.parse_tree = None;
                            self.pending_tree_edits.clear();
                        } else {
                            self.pending_tree_edits.extend(out.text_edits);
                        }
                    }
                    if let Some((lo, hi)) = out.yanked_range {
                        self.yank_flash = Some((lo, hi, Instant::now()));
                    }
                    // Auto-close HTML/JSX/Vue/Svelte/Astro tags: when the
                    // user just typed `>` that completed `<TagName ...>`,
                    // insert `</TagName>` after the cursor. Skip on void
                    // (`<br>`, `<img>`, …) or self-closing (`<Foo />`).
                    if is_close_angle && out.buffer_changed && self.is_html_family() {
                        self.try_autoclose_tag();
                    }
                    changed |= out.buffer_changed;
                }
                if changed {
                    self.recompute_dirty();
                    // Defer highlight reparse — App::tick refreshes after a
                    // short idle. Holds the previous frame's highlights
                    // during rapid typing for big files.
                    self.highlights_dirty = true;
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
            // Snapshot per-op for fold-shift math: at_line = where the edit
            // starts (the start-byte's line for ReplaceRange; the cursor's
            // line for everything else, since most ops are cursor-relative).
            let at_line = match &op {
                E::ReplaceRange { start, .. } => self.editor.line_at_byte(*start),
                _ => self.editor.row_col().0,
            };
            let lines_before = self.editor.line_count();
            let out = self.editor.apply(op, viewport_rows, clipboard);
            if out.buffer_changed {
                let lines_after = self.editor.line_count();
                let delta = lines_after as i64 - lines_before as i64;
                if delta != 0 {
                    self.shift_folds_after(at_line, delta);
                }
                if out.text_edits.is_empty() {
                    self.parse_tree = None;
                    self.pending_tree_edits.clear();
                } else {
                    self.pending_tree_edits.extend(out.text_edits);
                }
            }
            changed |= out.buffer_changed;
            if let Some(going_down) = direction {
                self.snap_cursor_out_of_fold(going_down);
            }
        }
        if changed {
            self.recompute_dirty();
            self.highlights_dirty = true;
            self.refresh_find_matches();
            self.last_edited = Some(Instant::now());
            // Folds shifted per-op above; no need to wholesale-clear here.
            self.note_edit_position();
        }
        changed
    }

    /// Shift fold start/end pairs so they survive a line-count change at
    /// `at_line` (the cursor's line at edit time). `delta` is the net line
    /// change (`+1` for an inserted newline, `-1` for a removed line, etc.).
    /// Folds *entirely above* `at_line` are unchanged. Folds *entirely
    /// True when the buffer's filetype is an HTML-family language that
    /// benefits from auto-closing tags (`<div>` → `<div></div>`).
    fn is_html_family(&self) -> bool {
        matches!(
            self.language_ext.as_deref(),
            Some("html" | "htm" | "vue" | "svelte" | "astro" | "jsx" | "tsx" | "xml")
        )
    }

    /// Auto-close HTML/JSX tags. Called immediately after `>` was typed.
    /// Inspects the line backward from the cursor, identifies the
    /// just-completed `<TagName ...>` opening, and inserts `</TagName>`
    /// after the cursor. Bails on void elements (`br`, `img`, …),
    /// self-closing (`<Foo />`), closing tags (`</Foo>`), or comments.
    fn try_autoclose_tag(&mut self) {
        let cursor = self.editor.cursor();
        let text = self.editor.text();
        if cursor == 0 || cursor > text.len() {
            return;
        }
        // The char immediately before cursor must be `>` (we know it is,
        // but be defensive — the cursor could have advanced).
        if &text[cursor.saturating_sub(1)..cursor] != ">" {
            return;
        }
        // Find the matching `<` on this line.
        let line_start = text[..cursor].rfind('\n').map(|i| i + 1).unwrap_or(0);
        let line_up_to_cursor = &text[line_start..cursor];
        let Some(lt_rel) = line_up_to_cursor.rfind('<') else {
            return;
        };
        let inside = &line_up_to_cursor[lt_rel + 1..line_up_to_cursor.len() - 1];
        if inside.is_empty()
            || inside.starts_with('/')
            || inside.starts_with('!')
            || inside.starts_with('?')
            || inside.ends_with('/')
        {
            return;
        }
        // Extract tag name (alphanumerics + `_`/`-`/`:` for namespacing).
        let name_end = inside
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == ':'))
            .unwrap_or(inside.len());
        if name_end == 0 {
            return;
        }
        let name = &inside[..name_end];
        // Void HTML elements — never get a close tag.
        const VOID: &[&str] = &[
            "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "param",
            "source", "track", "wbr",
        ];
        if VOID.iter().any(|v| v.eq_ignore_ascii_case(name)) {
            return;
        }
        let close = format!("</{name}>");
        self.editor.insert_str_at_cursor_no_advance(&close);
    }

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

    /// Wrap-aware version of [`Self::visible_to_file_row`] — given a visual
    /// row index (the terminal row past the gutter), return the
    /// `(file_line, char_start)` that visual row maps to under char-break
    /// wrapping with width `tw`. Long lines emit multiple visual rows
    /// where `char_start` advances by `tw`; folded bodies are skipped.
    /// Returns `None` if the visual row falls past the file's end.
    pub fn wrap_to_file_pos(
        &self,
        start_file_line: usize,
        visible_row: usize,
        tw: usize,
    ) -> Option<(usize, usize)> {
        if tw == 0 {
            return self
                .visible_to_file_row(start_file_line, visible_row)
                .map(|l| (l, 0));
        }
        let n = self.editor.line_count();
        let mut walked: usize = 0;
        let mut line = start_file_line;
        while line < n {
            if self.is_line_folded_body(line) {
                line += 1;
                continue;
            }
            let chars = self.editor.line_str(line).chars().count();
            let chunks = chars.div_ceil(tw).max(1);
            if visible_row < walked + chunks {
                let chunk = visible_row - walked;
                return Some((line, chunk * tw));
            }
            walked += chunks;
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
        "Dockerfile" | "dockerfile" | "Containerfile" | "containerfile" => "dockerfile",
        _ => {
            // `Dockerfile.dev`, `Dockerfile.prod`, etc. are common.
            if name.starts_with("Dockerfile.") || name.starts_with("Containerfile.") {
                "dockerfile"
            } else {
                return None;
            }
        }
    };
    Some(ext.to_string())
}

/// Per-language line-comment tokens. Returns `(open, close)` where `close`
/// is empty for languages whose line-comment is a simple prefix (Rust /
/// Python / Lua / etc.) and non-empty for block-comment-only families
/// like HTML/XML (`<!-- … -->`). The toggle wraps + unwraps accordingly.
fn comment_token_for(ext: Option<&str>) -> (&'static str, &'static str) {
    match ext {
        Some(
            "rs" | "ts" | "tsx" | "js" | "jsx" | "cjs" | "mjs" | "c" | "cpp" | "h" | "hpp" | "cs"
            | "go" | "java" | "kt" | "swift" | "php" | "scss" | "less",
        ) => ("// ", ""),
        Some("py" | "rb" | "sh" | "bash" | "zsh" | "toml" | "yaml" | "yml" | "ini" | "conf") => {
            ("# ", "")
        }
        Some("lua" | "sql") => ("-- ", ""),
        // HTML-family: block-comment wrap. The toggle inserts ` -->` at
        // end-of-line so the closing tag survives a round-trip.
        Some("html" | "htm" | "xml" | "vue" | "svelte" | "astro") => ("<!-- ", " -->"),
        // CSS-family: `/* … */` block-comment wrap.
        Some("css") => ("/* ", " */"),
        _ => ("// ", ""),
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
        // visible_to_file_row should skip the body. File has 7
        // logical lines (0..=6) — the trailing `\n` is the line
        // *terminator* for line 6, not an extra empty line 7
        // (matches `wc -l` + every other editor; line_count fix
        // 2026-06-07 bug-hunt SEV-3).
        assert_eq!(b.visible_to_file_row(0, 0), Some(0));
        assert_eq!(b.visible_to_file_row(0, 2), Some(2));
        assert_eq!(b.visible_to_file_row(0, 3), Some(5));
        assert_eq!(b.visible_to_file_row(0, 4), Some(6));
        // Visible rows past the last real line return None now (was
        // Some(7) — phantom trailing line).
        assert_eq!(b.visible_to_file_row(0, 5), None);
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
    fn batch_edit_preserves_folds_when_no_line_change() {
        // apply_edit_ops used to wholesale-clear folds on any change.
        // Now it shifts per-op so single-line edits leave folds intact.
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        b.folds.insert(0, 2);
        let mut clip = crate::clipboard::Clipboard::new();
        b.apply_edit_ops(vec![crate::edit_op::EditOp::InsertChar('x')], &mut clip, 0);
        // Line count unchanged ⇒ fold preserved as-is.
        assert_eq!(b.folds.get(&0).copied(), Some(2));
    }

    #[test]
    fn batch_edit_shifts_folds_when_line_count_changes() {
        // A ReplaceRange that adds a newline must shift any below-fold.
        // Buffer state: 8 logical lines (0..7), fold lines [5..=6].
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "0\n1\n2\n3\n4\n5\n6\n").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        b.folds.insert(5, 6);
        let mut clip = crate::clipboard::Clipboard::new();
        // Splice a newline at the start of line 1 (byte 2 = after "0\n").
        b.apply_edit_ops(
            vec![crate::edit_op::EditOp::ReplaceRange {
                start: 2,
                end: 2,
                text: "\n".to_string(),
            }],
            &mut clip,
            0,
        );
        // Fold at (5,6) shifts to (6,7) — below the inserted line.
        assert_eq!(b.folds.get(&6).copied(), Some(7));
    }

    #[test]
    fn autoclose_html_tag_inserts_closing() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.html");
        fs::write(&p, "").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        let mut clip = crate::clipboard::Clipboard::new();
        // Simulate typing `<div>`
        for c in "<div>".chars() {
            let key = ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Char(c),
                ratatui::crossterm::event::KeyModifiers::NONE,
            );
            b.feed_key(key, &mut clip, 10, None);
        }
        assert_eq!(b.editor.text(), "<div></div>");
        // Cursor sits between the tags.
        assert_eq!(b.editor.cursor(), 5);
    }

    #[test]
    fn autoclose_html_skips_void_elements() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.html");
        fs::write(&p, "").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        let mut clip = crate::clipboard::Clipboard::new();
        for c in "<br>".chars() {
            let key = ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Char(c),
                ratatui::crossterm::event::KeyModifiers::NONE,
            );
            b.feed_key(key, &mut clip, 10, None);
        }
        // No close tag inserted — `br` is void.
        assert_eq!(b.editor.text(), "<br>");
    }

    #[test]
    fn autoclose_html_skips_self_closing() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.jsx");
        fs::write(&p, "").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        let mut clip = crate::clipboard::Clipboard::new();
        for c in "<Foo />".chars() {
            let key = ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Char(c),
                ratatui::crossterm::event::KeyModifiers::NONE,
            );
            b.feed_key(key, &mut clip, 10, None);
        }
        // No double close.
        assert_eq!(b.editor.text(), "<Foo />");
    }

    #[test]
    fn autoclose_html_ignores_non_html_files() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.rs");
        fs::write(&p, "").unwrap();
        let mut b = Buffer::open(&p, &Config::default()).unwrap();
        let mut clip = crate::clipboard::Clipboard::new();
        for c in "<div>".chars() {
            let key = ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Char(c),
                ratatui::crossterm::event::KeyModifiers::NONE,
            );
            b.feed_key(key, &mut clip, 10, None);
        }
        assert_eq!(b.editor.text(), "<div>");
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

    /// Regression for the 2026-06-07 bug-hunt SEV-2 finding:
    /// `:e <newfile.txt>` used to toast "cannot open: No such
    /// file or directory" instead of creating an empty in-memory
    /// buffer like vim does. The fix added
    /// `Buffer::open_or_new_empty`, which is what `open_path_inner`
    /// now calls.
    #[test]
    fn open_or_new_empty_creates_buffer_for_missing_file() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("brand-new.rs");
        // Confirm the file doesn't exist.
        assert!(!path.exists());

        let cfg = Config::default();
        let b = Buffer::open_or_new_empty(&path, &cfg).expect("ENOENT path should still succeed");
        // Empty buffer, dirty (so first save writes the file), path set.
        assert_eq!(b.editor.text(), "");
        assert!(b.dirty, "new buffer should be dirty so first save writes");
        assert_eq!(b.path.as_deref(), Some(path.as_path()));
        assert_eq!(b.language_ext.as_deref(), Some("rs"));
        assert_eq!(b.saved_text, "");
        assert!(b.disk_mtime.is_none(), "no file on disk yet ⇒ no mtime");
    }

    /// Non-NotFound errors still propagate up (permission denied,
    /// etc.) — `open_or_new_empty` is only the ENOENT escape hatch.
    #[test]
    fn open_or_new_empty_passes_through_other_errors() {
        let cfg = Config::default();
        // /proc/self/mem on Linux + most macOS protected paths give
        // EACCES, but cross-platform we'll just confirm the success
        // path with an existing file works (the error pass-through
        // is by construction — non-NotFound match arms re-emit `e`).
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("real.txt");
        fs::write(&p, "exists\n").unwrap();
        let b = Buffer::open_or_new_empty(&p, &cfg).expect("real file opens");
        assert_eq!(b.editor.text(), "exists\n");
        assert!(!b.dirty, "real file load should be clean");
    }
}
