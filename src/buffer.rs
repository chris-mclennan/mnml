//! One open file — the `Pane::Editor` payload. Wraps an [`Editor`] plus path /
//! dirty / language bookkeeping plus its own input handler (so per-buffer modal
//! state lives here, not in `App`).

use std::path::{Path, PathBuf};

use ratatui::crossterm::event::KeyEvent;

use crate::clipboard::Clipboard;
use crate::config::Config;
use crate::editor::Editor;
use crate::highlight::{self, ColoredSpan};
use crate::input::{self, AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

/// Above this many bytes, skip syntax highlighting (re-parsing on every edit
/// would lag). Incremental parsing lifts this later.
const HIGHLIGHT_BYTE_LIMIT: usize = 2 * 1024 * 1024;

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
}

impl Buffer {
    pub fn open(path: &Path, cfg: &Config) -> std::io::Result<Buffer> {
        let text = std::fs::read_to_string(path)?;
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_string());
        let mut editor = Editor::new(text.clone(), cfg.editor.tab_width);
        editor.set_comment_token(comment_token_for(ext.as_deref()));
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
        Buffer {
            path: None,
            editor: Editor::new(String::new(), cfg.editor.tab_width),
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
        if let Some(path) = &self.path {
            std::fs::write(path, self.editor.text())?;
            self.saved_text = self.editor.text().to_string();
            self.dirty = false;
        }
        Ok(())
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
