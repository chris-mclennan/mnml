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
                *self.layout_mut() = Layout::leaf(id);
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
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Open a pty pane running `cargo <subcmd>` in the workspace.
    /// Used by the cargo.* family of palette commands. Toasts when
    /// no Cargo.toml is found in the workspace or any parent.
    pub fn run_cargo_subcommand(&mut self, subcmd: &str) {
        self.run_manifest_command("Cargo.toml", "cargo", subcmd);
    }

    /// Open a prompt for an npm script name, then run
    /// `npm run <script>` in a pty pane. 2026-06-21 multilang SEV-3
    /// fix for `:npm.run` being hardcoded to `npm run dev`.
    pub fn open_npm_run_script_prompt(&mut self) {
        let pkg = find_manifest_dir(&self.workspace, &["package.json"]);
        if pkg.is_none() {
            self.toast("npm.run_script: no package.json found");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::NpmRunScript,
            "npm run: script name".to_string(),
        ));
    }

    /// Accept handler for `:npm.run_script` — fires the pty.
    pub fn npm_run_script_accept(&mut self, script: String) {
        let script = script.trim().to_string();
        if script.is_empty() {
            self.toast("npm.run_script: empty script name");
            return;
        }
        self.run_npm_subcommand(&format!("run {script}"));
    }

    /// `:go.run_path` — prompt for a package path, then run
    /// `go run <path>`. Most non-trivial Go projects put main in
    /// `cmd/<app>/main.go` rather than the module root; the bare
    /// `:go.run` (hardcoded `.`) is wrong for those.
    pub fn open_go_run_path_prompt(&mut self) {
        if find_manifest_dir(&self.workspace, &["go.mod"]).is_none() {
            self.toast("go.run_path: no go.mod found");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::GoRunPath,
            "go run: package path",
            "./",
        ));
    }

    /// Accept handler for `:go.run_path`.
    pub fn go_run_path_accept(&mut self, path: String) {
        let path = path.trim().to_string();
        if path.is_empty() {
            self.toast("go.run_path: empty path");
            return;
        }
        self.run_go_subcommand(&format!("run {path}"));
    }

    /// `npm <subcmd>` (test / run dev / build / start / install /
    /// lint). Requires a package.json at the workspace root.
    pub fn run_npm_subcommand(&mut self, subcmd: &str) {
        self.run_manifest_command("package.json", "npm", subcmd);
    }

    /// `pytest <args>`. Requires pyproject.toml OR setup.py OR
    /// a `tests/` dir that actually contains `test_*.py` files
    /// (a bare `tests/` dir is not enough — common in Rust
    /// repos, where it'd false-positive into "this is a Python
    /// project" and spawn pytest against Rust code).
    pub fn run_pytest(&mut self, args: &str) {
        let root = find_manifest_dir(&self.workspace, &["pyproject.toml", "setup.py"])
            .unwrap_or_else(|| self.workspace.clone());
        let has_pyproject = root.join("pyproject.toml").exists();
        let has_setup = root.join("setup.py").exists();
        let has_real_tests = root.join("tests").is_dir()
            && std::fs::read_dir(root.join("tests"))
                .map(|rd| {
                    rd.filter_map(|e| e.ok()).any(|e| {
                        e.file_name().to_string_lossy().starts_with("test_")
                            && e.file_name().to_string_lossy().ends_with(".py")
                    })
                })
                .unwrap_or(false);
        if !has_pyproject && !has_setup && !has_real_tests {
            self.toast(format!(
                "pytest: no pyproject.toml / setup.py / tests/test_*.py at {}",
                self.workspace.display()
            ));
            return;
        }
        let cmdline = if args.is_empty() {
            "pytest".to_string()
        } else {
            format!("pytest {args}")
        };
        let label = cmdline.clone();
        let profile = crate::pty_pane::BinaryProfile::task(&label, &cmdline, root);
        self.open_pty(profile);
    }

    /// `go <subcmd>` (test ./... / build / run / vet). Requires
    /// a go.mod somewhere in the ancestor chain.
    ///
    /// 2026-06-21 — `go run` auto-detects `cmd/<app>/` packages
    /// at the module root. Most non-trivial Go projects put main
    /// in `cmd/<app>/main.go` rather than the module root, so
    /// `go run .` is wrong there. Behavior:
    ///   - 0 `cmd/<app>/` dirs → run `go <subcmd>` literally
    ///     (default behavior, covers `go test ./...` etc.).
    ///   - 1 `cmd/<app>/` dir AND subcmd is `run .` → run
    ///     `go run ./cmd/<app>` (auto-pick the only binary).
    ///   - 2+ `cmd/<app>/` dirs AND subcmd is `run .` → open a
    ///     picker over them. Accept fires `go run ./cmd/<pick>`.
    pub fn run_go_subcommand(&mut self, subcmd: &str) {
        if subcmd == "run ." {
            let root = crate::app::playwright::find_manifest_dir(&self.workspace, &["go.mod"]);
            if let Some(root) = root {
                let cmd_dir = root.join("cmd");
                let entries: Vec<std::path::PathBuf> = std::fs::read_dir(&cmd_dir)
                    .ok()
                    .into_iter()
                    .flatten()
                    .filter_map(|e| e.ok())
                    .filter(|e| e.path().is_dir())
                    .map(|e| e.path())
                    .collect();
                match entries.len() {
                    0 => {} // fall through to default `go run .`
                    1 => {
                        let app = entries[0]
                            .file_name()
                            .unwrap()
                            .to_string_lossy()
                            .to_string();
                        return self.run_manifest_command(
                            "go.mod",
                            "go",
                            &format!("run ./cmd/{app}"),
                        );
                    }
                    _ => {
                        use crate::picker::{Picker, PickerItem, PickerKind};
                        let items: Vec<PickerItem> = entries
                            .iter()
                            .map(|p| {
                                let name = p.file_name().unwrap().to_string_lossy().to_string();
                                PickerItem::new(name.clone(), format!("cmd/{name}"), name)
                            })
                            .collect();
                        self.open_picker(Picker::new(
                            PickerKind::GoRunCmd,
                            "go run: pick a cmd/<app>",
                            items,
                        ));
                        return;
                    }
                }
            }
        }
        self.run_manifest_command("go.mod", "go", subcmd);
    }

    pub(crate) fn run_manifest_command(&mut self, manifest: &str, bin: &str, subcmd: &str) {
        // 2026-06-21 multilang+lsp-cheat-test SEV-2: was checking
        // only `self.workspace.join(manifest)`, so subdir of a
        // monorepo (e.g. `/repo/cmd/server` with go.mod at /repo/)
        // got "no manifest" even though Go itself would have
        // found one. Walk up until we hit a manifest or the
        // filesystem root.
        let root = find_manifest_dir(&self.workspace, &[manifest])
            .unwrap_or_else(|| self.workspace.clone());
        if !root.join(manifest).exists() {
            // Embedding the full `subcmd` (could be multi-word
            // like "run dev" or "clippy --all-targets") into the
            // command ID slug produced `npm.run dev: no package.json…`.
            // Use just the first word.
            let slug = subcmd.split_whitespace().next().unwrap_or(subcmd);
            self.toast(format!(
                "{bin}.{slug}: no {manifest} found in {} or any parent",
                self.workspace.display()
            ));
            return;
        }
        let label = format!("{bin} {subcmd}");
        let cmdline = format!("{bin} {subcmd}");
        let profile = crate::pty_pane::BinaryProfile::task(&label, &cmdline, root);
        self.open_pty(profile);
        // Record for the statusline `🧪` chip — `open_pty` appends
        // to `panes`, so the last index is this new pty.
        if !self.panes.is_empty() {
            self.last_test_run = Some((label, self.panes.len() - 1));
        }
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

    /// `t` in a tests pane — toasts a hint to run
    /// `mnml-test-playwright <path>` in any shell pane manually.
    pub fn open_selected_test_trace(&mut self) {
        self.toast("trace viewer: run `mnml-test-playwright <path>` in a shell");
    }

    /// Stub kept after the Trace pane moved out — the standalone
    /// `mnml-test-playwright` has its own `r` reload. The mnml command
    /// surface (`tests.refresh_trace`) is preserved as a no-op so
    /// existing keybindings don't error.
    pub fn refresh_active_trace(&mut self) {
        self.toast("trace viewer moved to mnml-test-playwright; press `r` inside the hosted pane");
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

    /// Stub kept after the Trace pane moved out — `heal_from_active_trace`
    /// used to read the trace events from a `Pane::Trace`, but those
    /// live in the standalone mnml-test-playwright now. The command surface
    /// is preserved as a no-op toast.
    pub fn heal_from_active_trace(&mut self) {
        self.toast(
            "trace-driven heal moved with the trace viewer to mnml-test-playwright; \
             use `tests.heal` (`h` on the test row) for the spec-only heal flow",
        );
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

/// Walk up from `start` until we find a directory containing any
/// of `manifests`. Returns the matching directory or `None`. Used
/// by the npm/pytest/cargo/go runners to handle monorepo subdirs
/// the way the tools themselves do (2026-06-21 SEV-2 fix).
pub fn find_manifest_dir(
    start: &std::path::Path,
    manifests: &[&str],
) -> Option<std::path::PathBuf> {
    let mut cur = start.to_path_buf();
    loop {
        for m in manifests {
            if cur.join(m).exists() {
                return Some(cur);
            }
        }
        if !cur.pop() {
            return None;
        }
    }
}
