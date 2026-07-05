//! State for [`crate::pane::Pane::HttpHome`] — the "HTTP hub" main
//! pane opened when the user activates the HTTP activity section.
//!
//! Renders four rows of content on top of the same caches the
//! sidebar reads (`App::http_panel_recent_cache`,
//! `http_panel_captured_cache`, `http_panel_files_cache`):
//!
//!   1. Quick actions row (+ New request, ⟳ Start capture, ↓ Paste curl)
//!   2. Recent  (up to 12 rows — status + method + short-url + duration)
//!   3. Captured (up to 12 rows — method + short-url)
//!   4. Files   (up to 12 rows — relative path)
//!
//! Rows are click-to-open (same routing as the sidebar). The pane
//! owns almost no state — the caches live on `App` so refreshing
//! either the sidebar or the home pane updates both.

#[derive(Debug, Default)]
pub struct HttpHomePane {
    /// Scroll offset (top row of content that's currently visible).
    /// Kept for wheel routing; keyboard navigation is a follow-up.
    pub scroll: u16,
}

impl HttpHomePane {
    pub fn new() -> Self {
        Self { scroll: 0 }
    }

    pub fn tab_title(&self) -> String {
        "HTTP".to_string()
    }
}
