//! Floating "peek definition" overlay. Renders ABOVE the editor
//! as a bordered box showing N lines of source around an LSP-
//! resolved definition. Doesn't move the cursor — closing returns
//! the user to exactly where they were.

use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct PeekOverlay {
    /// Source file the def lives in.
    pub path: PathBuf,
    /// 0-based line of the def's start.
    pub anchor_line: u32,
    /// Loaded source lines (centered ± `context_radius` around
    /// `anchor_line`).
    pub lines: Vec<String>,
    /// Index into `lines` of the def's anchor line — used to
    /// highlight it.
    pub highlight_idx: usize,
    /// Vertical scroll offset within the lines list (rows).
    pub scroll: usize,
    /// Total context window size (each direction). Default 7
    /// → ~15-line window.
    pub context_radius: usize,
}

impl PeekOverlay {
    /// Load source lines around `anchor_line` from `path`. Returns
    /// `None` when the file isn't readable.
    pub fn load(path: PathBuf, anchor_line: u32) -> Option<Self> {
        const RADIUS: usize = 7;
        let text = std::fs::read_to_string(&path).ok()?;
        let total: Vec<&str> = text.lines().collect();
        if total.is_empty() {
            return None;
        }
        let anchor = (anchor_line as usize).min(total.len().saturating_sub(1));
        let start = anchor.saturating_sub(RADIUS);
        let end = (anchor + RADIUS + 1).min(total.len());
        let lines: Vec<String> = total[start..end].iter().map(|s| s.to_string()).collect();
        let highlight_idx = anchor - start;
        Some(PeekOverlay {
            path,
            // 2026-06-21 lsp-cheat-test SEV-3: store the CLAMPED
            // anchor (not the raw LSP-supplied line). The renderer
            // displays `anchor_line + 1` in the gutter; if the
            // LSP returned a stale "line 1000" and we clamped to
            // line 10 internally, the gutter used to mis-label.
            anchor_line: anchor as u32,
            lines,
            highlight_idx,
            scroll: 0,
            context_radius: RADIUS,
        })
    }

    /// Compact title — `path · line N+1`.
    pub fn title(&self) -> String {
        let short = self
            .path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("?");
        format!("{short} · line {}", self.anchor_line + 1)
    }

    pub fn scroll_up(&mut self) {
        self.scroll = self.scroll.saturating_sub(1);
    }

    pub fn scroll_down(&mut self) {
        // 2026-06-21 lsp-cheat-test SEV-3 peek-scroll-model-overshoots-view:
        // was clamping to `lines.len() - 1`, but the renderer
        // caps to `lines.len() - body_h`. The viewport-aware cap
        // is the right one — without it, j past the cap then k
        // feels frozen because scroll already overran. We don't
        // know body_h here, so cap at `lines.len() - 1` is the
        // best lower bound; the renderer's per-frame
        // `scroll.min(max_scroll)` is the upper safety net. The
        // saturating_sub(1) on lines.len() guards empty lines.
        if !self.lines.is_empty() && self.scroll + 1 < self.lines.len() {
            self.scroll += 1;
        }
    }
}
