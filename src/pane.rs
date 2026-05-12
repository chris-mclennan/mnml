//! The "open thing" abstraction. P0 has only `Editor`; later tracks add `Pty`,
//! `Request`, `Diff`, `Ai` — each is additive (a new variant + a new renderer),
//! never a refactor of the panes that already exist.

use crate::buffer::Buffer;

pub enum Pane {
    Editor(Buffer),
    // Pty(PtySession),       // Pty / AI-CLI track
    // Request(RequestPane),  // HTTP track
    // Diff(DiffView),        // Git / AI tracks
    // Ai(AiPanel),           // AI track
}

impl Pane {
    /// Short title for the bufferline tab.
    pub fn title(&self) -> String {
        match self {
            Pane::Editor(b) => b.display_name(),
        }
    }

    /// True if the pane has unsaved changes (drives the `●` marker).
    pub fn is_dirty(&self) -> bool {
        match self {
            Pane::Editor(b) => b.dirty,
        }
    }

    pub fn as_editor(&self) -> Option<&Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
        }
    }

    pub fn as_editor_mut(&mut self) -> Option<&mut Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
        }
    }
}
