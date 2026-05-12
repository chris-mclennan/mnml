//! The "open thing" abstraction. `Editor` is the workhorse; `MdPreview` is a
//! read-only rendered-markdown view. Later tracks add `Pty`, `Request`, `Diff`,
//! `Ai` — each is additive (a new variant + a new renderer + a `match` arm
//! here), never a refactor of the panes that already exist.

use std::path::PathBuf;

use crate::buffer::Buffer;

// `Editor`'s payload (`Buffer`) is much bigger than `MdPreview`'s; boxing it
// would ripple a `Box` through every `Pane::Editor(b)` site for a handful of
// bytes of slack in a Vec that holds ~1–10 panes. Not worth it (revisit if more
// chunky variants land).
#[allow(clippy::large_enum_variant)]
pub enum Pane {
    Editor(Buffer),
    /// A rendered-markdown view of `path`. `source` is a snapshot of the `.md`
    /// text (refreshed when the source buffer is saved); `scroll` is the top row.
    MdPreview(MdPreview),
    // Pty(PtySession),       // Pty / AI-CLI track
    // Request(RequestPane),  // HTTP track
    // Diff(DiffView),        // Git / AI tracks
    // Ai(AiPanel),           // AI track
}

pub struct MdPreview {
    pub path: PathBuf,
    pub source: String,
    pub scroll: usize,
}

impl MdPreview {
    pub fn title(&self) -> String {
        let name = self
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "markdown".to_string());
        format!("{name} ◳")
    }
}

impl Pane {
    /// Short title for the bufferline tab.
    pub fn title(&self) -> String {
        match self {
            Pane::Editor(b) => b.display_name(),
            Pane::MdPreview(p) => p.title(),
        }
    }

    /// True if the pane has unsaved changes (drives the `●` marker).
    pub fn is_dirty(&self) -> bool {
        match self {
            Pane::Editor(b) => b.dirty,
            Pane::MdPreview(_) => false,
        }
    }

    pub fn as_editor(&self) -> Option<&Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            Pane::MdPreview(_) => None,
        }
    }

    pub fn as_editor_mut(&mut self) -> Option<&mut Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            Pane::MdPreview(_) => None,
        }
    }
}
