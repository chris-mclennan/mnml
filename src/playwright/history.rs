//! Persistent test outcomes — for each `(file, suite_path, title)`, the last
//! N outcomes across `npx playwright test` runs in this workspace. The point
//! is the **wobbly** glyph in the tests pane: a test that's gone both ways
//! recently gets highlighted so a human can see "this one flips, look at it"
//! without relying on Playwright's per-run `flaky` marker (which only covers
//! the single run's automatic retries, not run-to-run instability).
//!
//! Stored as JSON at `<workspace>/.mnml/test-history.json`. Best-effort —
//! corrupt / missing file ⇒ start fresh; write failures are swallowed (this
//! is a UX nicety, not load-bearing — a failed write must not break the run).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::playwright::{TestRun, TestStatus};

/// One outcome stored in the history file.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum HistOutcome {
    Pass,
    Fail,
    /// Playwright marked the test "flaky" in a single run (passed on retry).
    /// Treated like a fail for "wobbly" classification — both signal instability.
    Flaky,
}

/// How many outcomes to keep per test. Tuned to "recent enough to matter,
/// short enough that a fix shows up quickly."
const KEEP: usize = 10;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TestHistory {
    /// `(file\tsuite_path\ttitle)` → most-recent-last queue of outcomes.
    by_test: HashMap<String, Vec<HistOutcome>>,
    /// Same key as `by_test`, value = the last `tc.line` we recorded — so the
    /// flaky-dashboard can jump to source without re-running Playwright just
    /// to discover line numbers. `#[serde(default)]` keeps old test-history
    /// files (without this field) loadable; tests without a recorded line
    /// open at the top of their file.
    #[serde(default)]
    last_line: HashMap<String, u32>,
}

/// One row in the flaky-dashboard pane.
#[derive(Debug, Clone)]
pub struct WobblyRow {
    pub file: String,
    pub suite_path: String,
    pub title: String,
    /// Most-recent-last outcomes (use the same `[Pass, Fail, Flaky]` semantics
    /// the gutter glyph does).
    pub outcomes: Vec<HistOutcome>,
    /// 0-based line in `file`, or `0` if we never recorded one.
    pub line: u32,
}

impl TestHistory {
    /// Read `<workspace>/.mnml/test-history.json`. Missing/corrupt ⇒ empty.
    pub fn load(workspace: &Path) -> Self {
        let path = Self::path(workspace);
        let Ok(s) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&s).unwrap_or_default()
    }

    /// Write the history to disk (creates `<workspace>/.mnml/` if needed).
    /// Best-effort: I/O errors are swallowed.
    pub fn save(&self, workspace: &Path) {
        let path = Self::path(workspace);
        let Some(parent) = path.parent() else { return };
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
        if let Ok(s) = serde_json::to_string(self) {
            let _ = std::fs::write(&path, s);
        }
    }

    fn path(workspace: &Path) -> PathBuf {
        workspace.join(".mnml").join("test-history.json")
    }

    /// Append every result in `run` to its test's outcome queue (skipped tests
    /// don't count — they tell us nothing about stability). Caps each queue
    /// at `KEEP` (oldest dropped).
    pub fn record_run(&mut self, run: &TestRun) {
        for tc in &run.tests {
            let outcome = match tc.status {
                TestStatus::Passed => HistOutcome::Pass,
                TestStatus::Failed => HistOutcome::Fail,
                TestStatus::Flaky => HistOutcome::Flaky,
                TestStatus::Skipped => continue,
            };
            let key = Self::key(&tc.file, &tc.suite_path, &tc.title);
            let v = self.by_test.entry(key.clone()).or_default();
            v.push(outcome);
            if v.len() > KEEP {
                let drop_n = v.len() - KEEP;
                v.drain(..drop_n);
            }
            self.last_line.insert(key, tc.line);
        }
    }

    /// Every wobbly test, grouped first by file (alphabetical), then by
    /// title. Used by the flaky-dashboard pane.
    pub fn wobbly_tests(&self) -> Vec<WobblyRow> {
        let mut rows: Vec<WobblyRow> = self
            .by_test
            .iter()
            .filter_map(|(k, outcomes)| {
                let mut parts = k.splitn(3, '\t');
                let file = parts.next()?.to_string();
                let suite_path = parts.next()?.to_string();
                let title = parts.next()?.to_string();
                let pass = outcomes.contains(&HistOutcome::Pass);
                let other = outcomes.iter().any(|o| *o != HistOutcome::Pass);
                if !(pass && other) {
                    return None;
                }
                let line = self.last_line.get(k).copied().unwrap_or(0);
                Some(WobblyRow {
                    file,
                    suite_path,
                    title,
                    outcomes: outcomes.clone(),
                    line,
                })
            })
            .collect();
        rows.sort_by(|a, b| a.file.cmp(&b.file).then(a.title.cmp(&b.title)));
        rows
    }

    /// "Wobbly" = at least one pass and at least one non-pass (fail or
    /// per-run-flaky) in the kept window. A new test with one outcome is not
    /// wobbly even if it failed — let it run a few times first.
    pub fn is_wobbly(&self, file: &str, suite_path: &str, title: &str) -> bool {
        let Some(v) = self.by_test.get(&Self::key(file, suite_path, title)) else {
            return false;
        };
        let pass = v.contains(&HistOutcome::Pass);
        let other = v.iter().any(|o| *o != HistOutcome::Pass);
        pass && other
    }

    /// How many tests in `run` are wobbly per the current history (for the
    /// pane header's tally). The history must already include this run's
    /// results (call [`Self::record_run`] first).
    pub fn wobbly_count(&self, run: &TestRun) -> usize {
        run.tests
            .iter()
            .filter(|tc| self.is_wobbly(&tc.file, &tc.suite_path, &tc.title))
            .count()
    }

    fn key(file: &str, suite_path: &str, title: &str) -> String {
        // Suite path matters because Playwright lets two tests share a title in
        // sibling `describe`s. Separator's a tab — not a legal filename char.
        format!("{file}\t{suite_path}\t{title}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::playwright::TestCase;

    fn case(title: &str, status: TestStatus) -> TestCase {
        TestCase {
            title: title.into(),
            suite_path: "S".into(),
            file: "x.spec.ts".into(),
            line: 1,
            status,
            duration_ms: 1,
            error: None,
            trace_path: None,
        }
    }

    #[test]
    fn records_caps_and_classifies() {
        let mut h = TestHistory::default();
        let run = TestRun {
            command: String::new(),
            global_errors: Vec::new(),
            tests: vec![
                case("flips", TestStatus::Passed),
                case("solid", TestStatus::Passed),
                case("dead", TestStatus::Failed),
                case("skipme", TestStatus::Skipped),
            ],
        };
        h.record_run(&run);
        // One pass each — not wobbly yet.
        assert!(!h.is_wobbly("x.spec.ts", "S", "flips"));
        assert!(!h.is_wobbly("x.spec.ts", "S", "solid"));
        // Skipped tests aren't recorded.
        assert!(!h.is_wobbly("x.spec.ts", "S", "skipme"));

        // Flip `flips` to a fail; now it's wobbly.
        let run2 = TestRun {
            command: String::new(),
            global_errors: Vec::new(),
            tests: vec![
                case("flips", TestStatus::Failed),
                case("solid", TestStatus::Passed),
            ],
        };
        h.record_run(&run2);
        assert!(h.is_wobbly("x.spec.ts", "S", "flips"));
        assert!(!h.is_wobbly("x.spec.ts", "S", "solid"));

        // Cap is KEEP=10 — record 12 more "pass"es for `flips`, the early
        // fail ages out.
        for _ in 0..12 {
            let r = TestRun {
                command: String::new(),
                global_errors: Vec::new(),
                tests: vec![case("flips", TestStatus::Passed)],
            };
            h.record_run(&r);
        }
        assert!(!h.is_wobbly("x.spec.ts", "S", "flips"));
    }

    #[test]
    fn round_trips_through_disk() {
        let d = tempfile::tempdir().unwrap();
        let mut h = TestHistory::default();
        h.record_run(&TestRun {
            command: String::new(),
            global_errors: Vec::new(),
            tests: vec![case("a", TestStatus::Passed), case("a", TestStatus::Failed)],
        });
        h.save(d.path());
        let h2 = TestHistory::load(d.path());
        assert!(h2.is_wobbly("x.spec.ts", "S", "a"));
    }

    #[test]
    fn missing_file_loads_empty() {
        let d = tempfile::tempdir().unwrap();
        let h = TestHistory::load(d.path());
        assert!(!h.is_wobbly("x.spec.ts", "S", "anything"));
    }
}
