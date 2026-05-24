//! Playwright / test integration. For now: run the project's Playwright suite
//! (`npx playwright test --reporter=json`) on a worker thread, parse the JSON
//! report into a flat results list, and show it in a [`TestsPane`] with the
//! failures jump-to-source. Run all / run-file / run-test-at-cursor (via
//! Playwright's `file:line` selector) / `--last-failed`.
//!
//! Baked in — only shells out to `npx playwright` (degrades to a toast if it's
//! not there), like the git track shells out to `git`. CodeBuild integration
//! (for runs triggered from CI) is behind the `aws-codebuild` feature.
//!
//! Trace pane — runs with `--trace=retain-on-failure`; `t` on a failed test opens
//! its `trace.zip` parsed into a text timeline (see [`trace`] / [`trace_pane`]).
//!
//! Follow-ups: stream progress (the `line` reporter on stderr) instead of waiting
//! for the JSON at the end; clickable stack frames in a failure; heal-from-trace
//! (feed a failed trace to `claude -p`); a flaky-test dashboard.

pub mod flaky_pane;
pub mod history;
pub mod trace;
pub mod trace_pane;

use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TestStatus {
    Passed,
    Failed,
    Skipped,
    /// Passed, but only after a retry.
    Flaky,
}

impl TestStatus {
    pub fn glyph(self) -> &'static str {
        match self {
            TestStatus::Passed => "✓",
            TestStatus::Failed => "✗",
            TestStatus::Skipped => "⊘",
            TestStatus::Flaky => "≈",
        }
    }
}

/// One test (a Playwright "spec"), with where it lives and how it went.
#[derive(Debug, Clone)]
pub struct TestCase {
    pub title: String,
    /// `describe › subdescribe` path (may be empty).
    pub suite_path: String,
    /// Project-relative source file.
    pub file: String,
    pub line: u32,
    pub status: TestStatus,
    pub duration_ms: u64,
    /// First error message (+ a few stack lines) for a failure, if any.
    pub error: Option<String>,
    /// Absolute path to a retained `trace.zip`, if Playwright recorded one for
    /// this test (we run with `--trace=retain-on-failure`, so failures get one).
    pub trace_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Default)]
pub struct TestRun {
    /// The command line that produced this (for the header).
    pub command: String,
    pub tests: Vec<TestCase>,
    /// Top-level errors Playwright reported (config errors etc.).
    pub global_errors: Vec<String>,
}

impl TestRun {
    pub fn passed(&self) -> usize {
        self.tests
            .iter()
            .filter(|t| t.status == TestStatus::Passed)
            .count()
    }
    pub fn failed(&self) -> usize {
        self.tests
            .iter()
            .filter(|t| t.status == TestStatus::Failed)
            .count()
    }
    pub fn skipped(&self) -> usize {
        self.tests
            .iter()
            .filter(|t| t.status == TestStatus::Skipped)
            .count()
    }
    pub fn flaky(&self) -> usize {
        self.tests
            .iter()
            .filter(|t| t.status == TestStatus::Flaky)
            .count()
    }
    /// Project-relative `file`s of every failed test (for "rerun just the failures"
    /// if `--last-failed` isn't available).
    pub fn failed_files(&self) -> Vec<String> {
        let mut v: Vec<String> = self
            .tests
            .iter()
            .filter(|t| t.status == TestStatus::Failed)
            .map(|t| t.file.clone())
            .collect();
        v.sort();
        v.dedup();
        v
    }
}

/// Run `npx playwright test --reporter=json <extra_args>` in `workspace`,
/// blocking. Call from a worker thread. Parses the JSON report from stdout;
/// falls back to the stderr text if Playwright errored before emitting one.
pub fn run(workspace: &std::path::Path, extra_args: &[String]) -> Result<TestRun, String> {
    let mut cmd = Command::new("npx");
    cmd.arg("playwright")
        .arg("test")
        .arg("--reporter=json")
        // Keep a trace for any test that fails — the trace pane (`t` in the tests
        // pane) parses it. Overrides whatever `use.trace` the project config sets.
        .arg("--trace=retain-on-failure");
    for a in extra_args {
        cmd.arg(a);
    }
    cmd.current_dir(workspace);
    // Stop Playwright opening its HTML report in a browser when there are failures.
    cmd.env("PW_TEST_HTML_REPORT_OPEN", "never");
    let cmdline = format!(
        "npx playwright test --reporter=json --trace=retain-on-failure{}{}",
        if extra_args.is_empty() { "" } else { " " },
        extra_args.join(" ")
    );

    let out = cmd.output().map_err(|e| {
        format!("running `npx playwright test`: {e} — is Playwright installed here?")
    })?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    match serde_json::from_str::<Value>(stdout.trim()) {
        Ok(v) => {
            let mut run = parse_report(&v);
            run.command = cmdline;
            Ok(run)
        }
        Err(_) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let msg = [stderr.trim(), stdout.trim()]
                .into_iter()
                .find(|s| !s.is_empty())
                .unwrap_or("Playwright produced no JSON report");
            Err(msg.lines().take(4).collect::<Vec<_>>().join("\n"))
        }
    }
}

/// Parse Playwright's `json` reporter output into a flat [`TestRun`].
pub fn parse_report(v: &Value) -> TestRun {
    let mut tests = Vec::new();
    if let Some(suites) = v.get("suites").and_then(Value::as_array) {
        for s in suites {
            walk_suite(s, "", &mut tests);
        }
    }
    let global_errors = v
        .get("errors")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    e.get("message")
                        .and_then(Value::as_str)
                        .map(|m| m.lines().next().unwrap_or(m).to_string())
                        .or_else(|| e.as_str().map(str::to_string))
                })
                .collect()
        })
        .unwrap_or_default();
    TestRun {
        command: String::new(),
        tests,
        global_errors,
    }
}

fn walk_suite(suite: &Value, parent_path: &str, out: &mut Vec<TestCase>) {
    // A suite's `title` is the file name at the top level, then describe names.
    // We only accumulate describe titles into the path (skip the file-level one,
    // which equals `file`).
    let title = suite.get("title").and_then(Value::as_str).unwrap_or("");
    let file = suite.get("file").and_then(Value::as_str).unwrap_or("");
    let is_file_level = !file.is_empty() && title == file;
    let path = if parent_path.is_empty() {
        if is_file_level {
            String::new()
        } else {
            title.to_string()
        }
    } else if is_file_level {
        parent_path.to_string()
    } else {
        format!("{parent_path} › {title}")
    };

    if let Some(specs) = suite.get("specs").and_then(Value::as_array) {
        for spec in specs {
            push_spec(spec, &path, out);
        }
    }
    if let Some(children) = suite.get("suites").and_then(Value::as_array) {
        for c in children {
            walk_suite(c, &path, out);
        }
    }
}

fn push_spec(spec: &Value, suite_path: &str, out: &mut Vec<TestCase>) {
    let title = spec
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("(test)")
        .to_string();
    let file = spec
        .get("file")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let line = spec.get("line").and_then(Value::as_u64).unwrap_or(0) as u32;

    // `tests[]` is per-project; usually one. Take the first; aggregate its results.
    let test0 = spec
        .get("tests")
        .and_then(Value::as_array)
        .and_then(|a| a.first());
    let (status, duration_ms, error, trace_path) = match test0 {
        Some(t) => {
            let results = t.get("results").and_then(Value::as_array);
            let duration_ms = results
                .map(|rs| {
                    rs.iter()
                        .filter_map(|r| r.get("duration").and_then(Value::as_u64))
                        .sum()
                })
                .unwrap_or(0);
            // `tests[].status`: "expected" | "unexpected" | "flaky" | "skipped".
            let st = match t.get("status").and_then(Value::as_str) {
                Some("expected") => TestStatus::Passed,
                Some("flaky") => TestStatus::Flaky,
                Some("skipped") => TestStatus::Skipped,
                _ => {
                    // Fall back to the last result's status.
                    let last = results.and_then(|rs| rs.last());
                    match last.and_then(|r| r.get("status")).and_then(Value::as_str) {
                        Some("passed") => TestStatus::Passed,
                        Some("skipped") => TestStatus::Skipped,
                        _ => TestStatus::Failed,
                    }
                }
            };
            let error = if matches!(st, TestStatus::Failed) {
                results.and_then(|rs| rs.iter().rev().find_map(result_error))
            } else {
                None
            };
            let trace = results.and_then(|rs| rs.iter().rev().find_map(result_trace_path));
            (st, duration_ms, error, trace)
        }
        None => {
            // No `tests` array — use the spec's `ok` flag.
            let ok = spec.get("ok").and_then(Value::as_bool).unwrap_or(true);
            (
                if ok {
                    TestStatus::Passed
                } else {
                    TestStatus::Failed
                },
                0,
                None,
                None,
            )
        }
    };

    out.push(TestCase {
        title,
        suite_path: suite_path.to_string(),
        file,
        line,
        status,
        duration_ms,
        error,
        trace_path,
    });
}

/// The path of a `trace` attachment in one Playwright `result` object, if present.
fn result_trace_path(result: &Value) -> Option<PathBuf> {
    result
        .get("attachments")
        .and_then(Value::as_array)?
        .iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some("trace"))
        .and_then(|a| a.get("path").and_then(Value::as_str))
        .map(PathBuf::from)
}

/// Pull a short error string out of one Playwright `result` object.
fn result_error(result: &Value) -> Option<String> {
    // Newer reports: `errors: [{ message, stack, ... }]`. Older: `error: { message, stack }`.
    let err = result
        .get("errors")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .or_else(|| result.get("error"))?;
    let msg = err
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| err.as_str())?;
    // ANSI codes leak into Playwright error messages — strip them, keep the first
    // few lines.
    let cleaned = strip_ansi(msg);
    Some(cleaned.lines().take(6).collect::<Vec<_>>().join("\n"))
}

/// Drop CSI escape sequences (`\x1b[...m` etc.) from `s`.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            // Skip `[ ... <final byte>`.
            if chars.peek() == Some(&'[') {
                chars.next();
                while let Some(&n) = chars.peek() {
                    chars.next();
                    if n.is_ascii_alphabetic() || n == '~' {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

// ── the pane ────────────────────────────────────────────────────────

/// How the tests pane is sorting its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TestsSort {
    /// Playwright's natural order (file, then line) — grouped under per-file headers.
    #[default]
    FileLine,
    /// Slowest test first — flat list (file headers dropped). Find the long pole.
    DurationDesc,
}

impl TestsSort {
    pub fn next(self) -> Self {
        match self {
            TestsSort::FileLine => TestsSort::DurationDesc,
            TestsSort::DurationDesc => TestsSort::FileLine,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            TestsSort::FileLine => "file:line",
            TestsSort::DurationDesc => "slowest ↓",
        }
    }
}

/// The `Pane::Tests` payload.
pub struct TestsPane {
    pub workspace: PathBuf,
    pub state: TestsState,
    /// The `extra_args` of the run in flight / last run (so `r` re-runs the same).
    pub last_args: Vec<String>,
    /// Matched against the worker's reply.
    pub job_id: u64,
    pub scroll: usize,
    /// Index into `TestRun::tests` of the highlighted row (when `Done`).
    pub selected: usize,
    /// How rows are ordered in the renderer (`s` to cycle).
    pub sort: TestsSort,
}

pub enum TestsState {
    Running,
    Done(Box<TestRun>),
    Failed(String),
}

impl TestsPane {
    pub fn new(workspace: PathBuf, last_args: Vec<String>, job_id: u64) -> Self {
        TestsPane {
            workspace,
            state: TestsState::Running,
            last_args,
            job_id,
            scroll: 0,
            selected: 0,
            sort: TestsSort::default(),
        }
    }
    /// Indices into `TestRun::tests` in the *current* sort order. Renderers
    /// walk this rather than the raw `r.tests` so the selection follows.
    pub fn sorted_indices(&self, r: &TestRun) -> Vec<usize> {
        let n = r.tests.len();
        let mut idx: Vec<usize> = (0..n).collect();
        match self.sort {
            TestsSort::FileLine => {}
            TestsSort::DurationDesc => {
                idx.sort_by(|&a, &b| {
                    r.tests[b]
                        .duration_ms
                        .cmp(&r.tests[a].duration_ms)
                        .then(a.cmp(&b))
                });
            }
        }
        idx
    }
    pub fn tab_title(&self) -> String {
        match &self.state {
            TestsState::Running => "tests …".to_string(),
            TestsState::Failed(_) => "tests ✗".to_string(),
            TestsState::Done(r) => {
                let f = r.failed();
                if f > 0 {
                    format!("tests ✗{f}")
                } else {
                    format!("tests ✓{}", r.passed())
                }
            }
        }
    }
    /// The highlighted test (when results are in), for "jump to source".
    pub fn selected_test(&self) -> Option<&TestCase> {
        match &self.state {
            TestsState::Done(r) => r.tests.get(self.selected),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_ansi_removes_color_codes() {
        assert_eq!(
            strip_ansi("\x1b[31mError:\x1b[39m boom\x1b[2m at x\x1b[22m"),
            "Error: boom at x"
        );
        assert_eq!(strip_ansi("plain"), "plain");
    }

    #[test]
    fn parse_report_flattens_suites_and_specs() {
        let json = serde_json::json!({
            "suites": [
                {
                    "title": "login.spec.ts",
                    "file": "login.spec.ts",
                    "specs": [],
                    "suites": [
                        {
                            "title": "auth",
                            "file": "login.spec.ts",
                            "specs": [
                                { "title": "logs in", "file": "login.spec.ts", "line": 7, "ok": true,
                                  "tests": [{ "status": "expected", "results": [{ "status": "passed", "duration": 120 }] }] },
                                { "title": "rejects bad password", "file": "login.spec.ts", "line": 15, "ok": false,
                                  "tests": [{ "status": "unexpected", "results": [{ "status": "failed", "duration": 30,
                                      "errors": [{ "message": "[31mError:[39m expect(received).toBe(expected)\nline 2" }] }] }] },
                                { "title": "skips this", "file": "login.spec.ts", "line": 20,
                                  "tests": [{ "status": "skipped", "results": [{ "status": "skipped", "duration": 0 }] }] }
                            ]
                        }
                    ]
                }
            ],
            "errors": []
        });
        let run = parse_report(&json);
        assert_eq!(run.tests.len(), 3);
        assert_eq!(run.passed(), 1);
        assert_eq!(run.failed(), 1);
        assert_eq!(run.skipped(), 1);
        let pass = &run.tests[0];
        assert_eq!(pass.title, "logs in");
        assert_eq!(pass.suite_path, "auth");
        assert_eq!(pass.line, 7);
        assert_eq!(pass.duration_ms, 120);
        let fail = &run.tests[1];
        assert_eq!(fail.status, TestStatus::Failed);
        assert!(fail.error.as_deref().unwrap().contains("expect(received)"));
        assert!(!fail.error.as_deref().unwrap().contains('\u{1b}'));
        assert_eq!(run.failed_files(), vec!["login.spec.ts".to_string()]);
    }

    #[test]
    fn tests_sort_modes() {
        let pane = TestsPane::new(PathBuf::from("/"), Vec::new(), 1);
        let mk = |file: &str, line: u32, dur: u64| TestCase {
            title: format!("{file}:{line}"),
            suite_path: String::new(),
            file: file.into(),
            line,
            status: TestStatus::Passed,
            duration_ms: dur,
            error: None,
            trace_path: None,
        };
        let run = TestRun {
            command: String::new(),
            global_errors: Vec::new(),
            // a (50 + 200), b (10 + 100) — natural order is file:line.
            tests: vec![
                mk("a.spec.ts", 1, 50),
                mk("a.spec.ts", 2, 200),
                mk("b.spec.ts", 1, 10),
                mk("b.spec.ts", 2, 100),
            ],
        };
        // FileLine (default) ⇒ natural order.
        assert_eq!(pane.sorted_indices(&run), vec![0, 1, 2, 3]);
        // DurationDesc ⇒ slowest first: 200, 100, 50, 10.
        let mut pane = pane;
        pane.sort = TestsSort::DurationDesc;
        assert_eq!(pane.sorted_indices(&run), vec![1, 3, 0, 2]);
        // Cycle wraps back.
        assert_eq!(TestsSort::FileLine.next(), TestsSort::DurationDesc);
        assert_eq!(TestsSort::DurationDesc.next(), TestsSort::FileLine);
    }
}
