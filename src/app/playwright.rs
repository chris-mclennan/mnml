//! Playwright runner + flaky-test dashboard + trace viewer.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. Owns the `test.*` palette commands, the `Pane::Tests` /
//! `Pane::Trace` / `Pane::Flaky` lifecycle, and the heal-with-AI
//! handoffs into a `Pane::Ai`.

use super::*;

impl App {
    /// Build a fresh [`crate::playwright::flaky_pane::FlakyPane`] from the
    /// current [`crate::playwright::history::TestHistory`].
    fn build_flaky_pane(&self) -> crate::playwright::flaky_pane::FlakyPane {
        let ws = self.workspace.clone();
        let rows = self.test_history.wobbly_tests();
        crate::playwright::flaky_pane::FlakyPane::build(rows, move |rel| ws.join(rel))
    }

    /// `flaky.show` — open the flaky-test dashboard (or refocus + refresh
    /// the one that's already open) in a split below the focused leaf.
    pub fn open_flaky_pane(&mut self) {
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Flaky(_))) {
            let fresh = self.build_flaky_pane();
            if let Some(Pane::Flaky(f)) = self.panes.get_mut(id) {
                f.items = fresh.items;
                f.clamp();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Flaky(self.build_flaky_pane());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Rebuild the item list of any open flaky panes (called after each test
    /// run, or on the pane's `r` key).
    pub fn refresh_flaky_panes(&mut self) {
        if !self.panes.iter().any(|p| matches!(p, Pane::Flaky(_))) {
            return;
        }
        let fresh = self.build_flaky_pane();
        for pane in &mut self.panes {
            if let Pane::Flaky(f) = pane {
                f.items = fresh.items.clone();
                f.clamp();
            }
        }
    }

    pub fn move_flaky_selection(&mut self, delta: isize) {
        if let Some(Pane::Flaky(f)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            f.move_selection(delta);
        }
    }

    /// Open the highlighted test's file and place the cursor on its line.
    pub fn jump_to_selected_flaky(&mut self) {
        let target = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Flaky(f)) => f.selected_item().map(|it| (it.path.clone(), it.line)),
            _ => None,
        };
        let Some((path, line)) = target else {
            return;
        };
        self.open_path(&path);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, 0);
        }
    }

    /// Open a `Pane::Tests` and kick off `npx playwright test --reporter=json
    /// <extra_args>` on a worker thread (`tick` delivers the results).
    fn run_playwright(&mut self, extra_args: Vec<String>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .tests_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let ws = self.workspace.clone();
        let args = extra_args.clone();
        std::thread::spawn(move || {
            let _ = tx.send((job_id, crate::playwright::run(&ws, &args)));
        });
        // Re-use an existing tests pane if there is one; else open a split.
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Tests(_))) {
            if let Some(Pane::Tests(t)) = self.panes.get_mut(id) {
                t.state = crate::playwright::TestsState::Running;
                t.last_args = extra_args;
                t.job_id = job_id;
                t.scroll = 0;
                t.selected = 0;
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Tests(crate::playwright::TestsPane::new(
            self.workspace.clone(),
            extra_args,
            job_id,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `test.run_all` — the whole Playwright suite.
    pub fn run_tests_all(&mut self) {
        self.run_playwright(Vec::new());
    }

    /// `test.run_file` — the active editor's spec file.
    pub fn run_tests_file(&mut self) {
        match self.active_editor().and_then(|b| b.path.as_deref()) {
            Some(p) => {
                let rel = rel_path(&self.workspace, p);
                self.run_playwright(vec![rel]);
            }
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.run_at_cursor` — the test at the cursor (Playwright's `file:line` selector).
    pub fn run_tests_at_cursor(&mut self) {
        match self.active_editor() {
            Some(b) => match &b.path {
                Some(p) => {
                    let rel = rel_path(&self.workspace, p);
                    let line = b.editor.row_col().0 + 1;
                    self.run_playwright(vec![format!("{rel}:{line}")]);
                }
                None => self.toast("open a saved .spec file first"),
            },
            None => self.toast("open a .spec file first"),
        }
    }

    /// `test.rerun_failed` — re-run just the failures of the last run (Playwright's `--last-failed`).
    pub fn rerun_failed_tests(&mut self) {
        self.run_playwright(vec!["--last-failed".to_string()]);
    }

    /// `r` in a tests pane — re-run with the same args as last time.
    pub fn rerun_active_tests(&mut self) {
        let args = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => t.last_args.clone(),
            _ => return,
        };
        self.run_playwright(args);
    }

    /// `t` in a tests pane — parse the highlighted test's retained `trace.zip` (we
    /// run with `--trace=retain-on-failure`, so failures have one) and open it as a
    /// `Pane::Trace` timeline in a split below.
    pub fn open_selected_test_trace(&mut self) {
        let info = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) => tc
                    .trace_path
                    .clone()
                    .map(|p| (tc.title.clone(), p))
                    .ok_or("no trace for that test (only failed tests retain one)"),
                None => return,
            },
            _ => {
                self.toast("select a test in the results pane first");
                return;
            }
        };
        let (title, path) = match info {
            Ok(v) => v,
            Err(msg) => {
                self.toast(msg);
                return;
            }
        };
        let events = match crate::playwright::trace::parse_trace_zip(&path) {
            Ok(e) => e,
            Err(e) => {
                self.toast(format!("trace: {e}"));
                return;
            }
        };
        let pane = Pane::Trace(crate::playwright::trace_pane::TracePane::new(
            title, path, events,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// `r` in a trace pane — re-parse the `trace.zip`.
    pub fn refresh_active_trace(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Trace(tr)) = self.panes.get_mut(cur)
            && let Err(e) = tr.refresh()
        {
            self.toast(format!("trace: {e}"));
        }
    }

    /// `test.heal` (`h` in a tests pane) — hand the highlighted *failing* test (its
    /// title, file, error, and the spec source) to `claude -p` and ask for a fix.
    /// Reuses the AI machinery; `c` in the resulting `Pane::Ai` promotes it to an
    /// interactive Claude Code session (which can actually apply the fix / call
    /// your healer agent).
    pub fn heal_selected_test(&mut self) {
        let info = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if tc.status == crate::playwright::TestStatus::Failed => Some((
                    tc.title.clone(),
                    tc.suite_path.clone(),
                    tc.file.clone(),
                    tc.line,
                    tc.error.clone().unwrap_or_default(),
                )),
                Some(_) => {
                    self.toast("that test isn't failing — nothing to heal");
                    None
                }
                None => None,
            },
            _ => {
                self.toast("select a failing test in the results pane first");
                None
            }
        };
        let Some((title, suite, file, line, error)) = info else {
            return;
        };
        let src = std::fs::read_to_string(self.workspace.join(&file)).unwrap_or_default();
        let where_ = if suite.is_empty() {
            format!("{file}:{line}")
        } else {
            format!("{suite} › {title}  ({file}:{line})")
        };
        let prompt = format!(
            "This Playwright test is failing. Work out why and propose a fix — change the \
             test or the code under test as appropriate. Be concise; reply with the patch in a \
             fenced block plus a short note.\n\n## Failing test\n{where_}\n\n## Error\n```\n{error}\n```\n\n## {file}\n```ts\n{src}\n```"
        );
        self.ask_ai(format!("AI: heal {title}"), prompt);
    }

    /// `h` in a `Pane::Trace` — hand the failed test's *execution trace* (the
    /// timeline of actions / console output / errors) to `claude -p` and ask for a
    /// fix. Complements [`Self::heal_selected_test`] (which feeds the spec source):
    /// here Claude sees what actually happened at runtime and uses its tools to read
    /// the spec / code itself. `c` in the resulting `Pane::Ai` promotes it to an
    /// interactive Claude Code session.
    pub fn heal_from_active_trace(&mut self) {
        let (title, timeline) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Trace(tr)) => (tr.test_title.clone(), tr.timeline_text()),
            _ => {
                self.toast("open a trace pane first (`t` on a failed test)");
                return;
            }
        };
        if timeline.trim().is_empty() {
            self.toast("this trace has no events to heal from");
            return;
        }
        let prompt = format!(
            "A Playwright test failed. Below is its execution trace — the actions it \
             ran, console output, and errors, in order. Work out why it failed and \
             propose a fix; use your tools to read the spec and the code under test as \
             needed. Be concise: reply with the patch in a fenced block plus a short \
             note.\n\n## Failed test\n{title}\n\n## Execution trace\n```\n{timeline}\n```"
        );
        self.ask_ai(format!("AI: heal from trace · {title}"), prompt);
    }

    /// Jump the editor to the source of the highlighted test in a `Pane::Tests`.
    pub fn jump_to_selected_test(&mut self) {
        let Some(cur) = self.active else { return };
        let (rel, line) = match self.panes.get(cur) {
            Some(Pane::Tests(t)) => match t.selected_test() {
                Some(tc) if !tc.file.is_empty() => {
                    (tc.file.clone(), tc.line.saturating_sub(1) as usize)
                }
                _ => return,
            },
            _ => return,
        };
        let path = self.workspace.join(&rel);
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(id) {
                b.editor.place_cursor(line, 0);
            }
            self.active = Some(id);
            self.focus = Focus::Pane;
        } else {
            self.open_path(&path);
            if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
                b.editor.place_cursor(line, 0);
            }
        }
    }

    /// Move the highlighted-test cursor in a `Pane::Tests`.
    pub fn tests_move_selection(&mut self, delta: isize) {
        if let Some(Pane::Tests(t)) = self.active.and_then(|i| self.panes.get_mut(i))
            && let crate::playwright::TestsState::Done(r) = &t.state
        {
            let n = r.tests.len();
            if n == 0 {
                return;
            }
            let new = (t.selected as isize + delta).clamp(0, n as isize - 1) as usize;
            t.selected = new;
        }
    }

    pub(super) fn drain_tests_jobs(&mut self) {
        use crate::playwright::TestsState;
        let Some((_, rx)) = &self.tests_chan else {
            return;
        };
        let done: Vec<TestsJobDone> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        let mut refresh_flaky = false;
        for (job_id, result) in done {
            let Some(Pane::Tests(t)) = self.panes.iter_mut().find(
                |p| matches!(p, Pane::Tests(t) if t.job_id == job_id && matches!(t.state, TestsState::Running)),
            ) else {
                continue;
            };
            match result {
                Ok(run) => {
                    let (p, f, s) = (run.passed(), run.failed(), run.skipped());
                    toasts.push(if f > 0 {
                        format!(
                            "tests: {f} failed, {p} passed{}",
                            if s > 0 {
                                format!(", {s} skipped")
                            } else {
                                String::new()
                            }
                        )
                    } else {
                        format!(
                            "tests: all {p} passed{}",
                            if s > 0 {
                                format!(" ({s} skipped)")
                            } else {
                                String::new()
                            }
                        )
                    });
                    t.selected = run
                        .tests
                        .iter()
                        .position(|tc| tc.status == crate::playwright::TestStatus::Failed)
                        .unwrap_or(0);
                    // Update the workspace's persistent test-outcome history so
                    // run-to-run wobbly tests light up with a `≋` glyph.
                    self.test_history.record_run(&run);
                    self.test_history.save(&self.workspace);
                    t.state = TestsState::Done(Box::new(run));
                    // History changed ⇒ any open flaky pane should reflect it.
                    refresh_flaky = true;
                }
                Err(e) => {
                    toasts.push(format!(
                        "playwright: {}",
                        e.lines().next().unwrap_or("error")
                    ));
                    t.state = TestsState::Failed(e);
                }
            }
        }
        for tt in toasts {
            self.toast(tt);
        }
        if refresh_flaky {
            self.refresh_flaky_panes();
        }
    }
}
