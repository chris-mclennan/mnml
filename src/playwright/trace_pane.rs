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
