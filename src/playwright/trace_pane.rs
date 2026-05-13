//! State for [`Pane::Trace`](crate::pane::Pane::Trace) — a parsed Playwright
//! `trace.zip` shown as a scrollable text timeline (drawn by `ui/trace_view.rs`).
//! Opened from the [`TestsPane`](super::TestsPane) (`t` on a failed test that
//! retained a trace). Read-only: scroll + select a row; `r` re-parses.

use std::path::PathBuf;

use super::trace::TraceEvent;

pub struct TracePane {
    /// The test this trace belongs to (for the tab / header).
    pub test_title: String,
    /// The `trace.zip` on disk (so `r` can re-parse it).
    pub path: PathBuf,
    pub events: Vec<TraceEvent>,
    /// Index of the highlighted row.
    pub selected: usize,
    /// Top visible row.
    pub scroll: usize,
}

impl TracePane {
    pub fn new(test_title: impl Into<String>, path: PathBuf, events: Vec<TraceEvent>) -> Self {
        TracePane {
            test_title: test_title.into(),
            path,
            events,
            selected: 0,
            scroll: 0,
        }
    }

    pub fn tab_title(&self) -> String {
        format!("trace · {}", self.test_title)
    }

    /// Total wall time the trace spans (ms), from the last event's `at_ms` (+ its
    /// duration if it's an action).
    pub fn span_ms(&self) -> f64 {
        self.events
            .iter()
            .map(|e| e.at_ms + e.dur_ms.unwrap_or(0.0))
            .fold(0.0_f64, f64::max)
    }

    /// Move the selection by `delta` rows, clamped.
    pub fn move_selection(&mut self, delta: isize) {
        if self.events.is_empty() {
            self.selected = 0;
            return;
        }
        let max = self.events.len() as isize - 1;
        self.selected = (self.selected as isize + delta).clamp(0, max) as usize;
    }

    /// Re-read + re-parse the `trace.zip` (the `r` key). Returns `Err` with a
    /// reason on failure (the pane keeps its old contents).
    pub fn refresh(&mut self) -> Result<(), String> {
        let evs = super::trace::parse_trace_zip(&self.path)?;
        self.events = evs;
        self.selected = 0;
        self.scroll = 0;
        Ok(())
    }
}
