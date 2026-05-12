//! Modeless, VSCode-style keymap. P0 stub: it ignores every key (so the editor
//! pane is read-only). P1 fills in the translation logic — typing, arrows,
//! Shift-select, Ctrl+C/X/V/Z/Y/A, word motions, indent, comment-toggle, save —
//! driven by `[keys.standard]` from config rather than a hardcoded table.

use ratatui::crossterm::event::KeyEvent;

use crate::config::Config;
use crate::input::{EditCtx, EditingMode, InputHandler, InputResult};

#[derive(Debug)]
pub struct StandardInputHandler {
    #[allow(dead_code)]
    tab_width: usize,
}

impl StandardInputHandler {
    pub fn new(cfg: &Config) -> Self {
        StandardInputHandler { tab_width: cfg.editor.tab_width }
    }
}

impl InputHandler for StandardInputHandler {
    fn handle_key(&mut self, _key: KeyEvent, _ctx: &EditCtx) -> InputResult {
        // P0: nothing is editable yet — let everything fall through to global chords.
        InputResult::Ignored
    }

    fn mode(&self) -> EditingMode {
        EditingMode::None
    }

    fn name(&self) -> &'static str {
        "standard"
    }
}
