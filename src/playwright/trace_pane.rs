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
    /// If `true`, the renderer hides rows whose `error` is `None`. Toggled
    /// with `e` in the pane. The selection still indexes the raw `events`
    /// vector — `visible_indices` is the filtered mapping.
    pub errors_only: bool,
}

impl TracePane {
    pub fn new(test_title: impl Into<String>, path: PathBuf, events: Vec<TraceEvent>) -> Self {
        TracePane {
            test_title: test_title.into(),
            path,
            events,
            selected: 0,
            scroll: 0,
            errors_only: false,
        }
    }

    /// Indices into `events` that the renderer should draw, in order. When
    /// `errors_only` is on, only rows with `error.is_some()`. Otherwise all.
    pub fn visible_indices(&self) -> Vec<usize> {
        if self.errors_only {
            self.events
                .iter()
                .enumerate()
                .filter(|(_, e)| e.error.is_some())
                .map(|(i, _)| i)
                .collect()
        } else {
            (0..self.events.len()).collect()
        }
    }

    /// `e` in the pane — flip the filter. If turning it on hides the current
    /// selection, snap to the first error (or to 0 if none).
    pub fn toggle_errors_only(&mut self) {
        self.errors_only = !self.errors_only;
        if self.errors_only
            && self
                .events
                .get(self.selected)
                .is_none_or(|e| e.error.is_none())
        {
            self.selected = self
                .events
                .iter()
                .position(|e| e.error.is_some())
                .unwrap_or(0);
        }
        self.scroll = 0;
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

    /// Move the selection by `delta` rows, clamped. Walks the *visible* row
    /// list — when `errors_only` is on, skipping over filtered-out events.
    pub fn move_selection(&mut self, delta: isize) {
        let visible = self.visible_indices();
        if visible.is_empty() {
            self.selected = 0;
            return;
        }
        // Find the visible row that's currently at-or-past the selection.
        let cur_pos = visible
            .iter()
            .position(|&i| i >= self.selected)
            .unwrap_or(visible.len() - 1);
        let max = visible.len() as isize - 1;
        let new_pos = (cur_pos as isize + delta).clamp(0, max) as usize;
        self.selected = visible[new_pos];
    }

    /// Render the timeline as plain text — for handing to `claude -p` (heal). One
    /// line per event (`+1234ms  ⏵ page.click("…")  (5ms)`); the `detail` / `error`
    /// body is inlined for error events and the selected row. Capped so the prompt
    /// stays bounded.
    pub fn timeline_text(&self) -> String {
        const MAX_EVENTS: usize = 400;
        const MAX_BODY_LINES: usize = 24;
        let mut out = String::new();
        for (i, e) in self.events.iter().enumerate().take(MAX_EVENTS) {
            let dur = e
                .dur_ms
                .map(|d| format!("  ({d:.0}ms)"))
                .unwrap_or_default();
            out.push_str(&format!(
                "+{:>8.0}ms  {} {}{}\n",
                e.at_ms,
                e.kind.glyph(),
                e.title,
                dur
            ));
            let want_body = e.error.is_some() || i == self.selected;
            if want_body && !e.detail.trim().is_empty() {
                for line in e.detail.lines().take(MAX_BODY_LINES) {
                    out.push_str("            | ");
                    out.push_str(line);
                    out.push('\n');
                }
            }
            if let Some(err) = &e.error {
                for line in err.lines().take(MAX_BODY_LINES) {
                    out.push_str("            ✗ ");
                    out.push_str(line);
                    out.push('\n');
                }
            }
        }
        if self.events.len() > MAX_EVENTS {
            out.push_str(&format!(
                "… ({} more events not shown)\n",
                self.events.len() - MAX_EVENTS
            ));
        }
        out
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::playwright::trace::EventKind;

    fn ev(at: f64, kind: EventKind, title: &str, detail: &str, error: Option<&str>) -> TraceEvent {
        TraceEvent {
            at_ms: at,
            dur_ms: None,
            kind,
            title: title.into(),
            detail: detail.into(),
            error: error.map(str::to_string),
        }
    }

    #[test]
    fn errors_only_filters_and_clamps_selection() {
        let mut p = TracePane::new(
            "t",
            PathBuf::from("/tmp/trace.zip"),
            vec![
                ev(0.0, EventKind::Action, "page.goto", "", None),
                ev(10.0, EventKind::Action, "page.click", "", None),
                ev(20.0, EventKind::Error, "boom", "", Some("err")),
                ev(30.0, EventKind::Action, "page.fill", "", None),
            ],
        );
        // selection starts on row 0 (an action).
        assert_eq!(p.selected, 0);
        p.toggle_errors_only();
        assert!(p.errors_only);
        // Selection snapped to the only error row (index 2).
        assert_eq!(p.selected, 2);
        // visible_indices is just [2] now.
        assert_eq!(p.visible_indices(), vec![2]);
        // Moving down in errors-only mode stays put (only one visible row).
        p.move_selection(1);
        assert_eq!(p.selected, 2);
        // Flip the filter off — selection persists.
        p.toggle_errors_only();
        assert!(!p.errors_only);
        assert_eq!(p.selected, 2);
        // And moving forward goes to row 3.
        p.move_selection(1);
        assert_eq!(p.selected, 3);
    }

    #[test]
    fn timeline_text_inlines_errors_and_selected_detail() {
        let p = TracePane::new(
            "checkout works",
            PathBuf::from("/tmp/trace.zip"),
            vec![
                ev(0.0, EventKind::Action, "page.goto(\"/\")", "url=/", None),
                ev(
                    120.0,
                    EventKind::Action,
                    "page.click(\"#buy\")",
                    "selector=#buy",
                    None,
                ),
                ev(
                    300.0,
                    EventKind::Error,
                    "locator.click: timeout",
                    "",
                    Some("TimeoutError: waiting for #buy\n  at checkout.spec.ts:42"),
                ),
            ],
        );
        let txt = p.timeline_text();
        assert!(txt.contains("page.goto(\"/\")"));
        // selected == 0 ⇒ its detail is inlined; row 1's is not.
        assert!(txt.contains("| url=/"));
        assert!(!txt.contains("selector=#buy"));
        // error rows always inline their error body.
        assert!(txt.contains("✗ TimeoutError: waiting for #buy"));
        assert!(txt.contains("checkout.spec.ts:42"));
    }
}
