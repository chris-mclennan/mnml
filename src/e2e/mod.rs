//! The `.test` end-to-end format + its runner. A `.test` file is a line-based
//! script of **steps** (drive the editor) and **expectations** (assert on the
//! rendered screen / app state), run against the same `App` + `ui::draw` the real
//! terminal and headless mode use — just with a `TestBackend` and synthesized key
//! events instead of crossterm. `mnml test <path…>` runs them; `tests/e2e.rs`
//! runs `tests/e2e/**/*.test` under `cargo test`.
//!
//! Grammar (one statement per line; `#`-comments and blank lines ignored):
//! ```text
//! write <relpath> <content>      # seed a fixture file in the temp workspace ("\n" → newline)
//! open  <relpath>                # open it in an editor pane (focuses the pane)
//! key   <keyspec>                # send a key — "ctrl+s", "enter", "down", "esc", "a", …
//! type  <text>                   # type literal text, char by char ("\n" → Enter)
//! command <id>                   # run a registered command by id
//! wait  <ms>                     # sleep + tick (for async/pty steps)
//! snippet <scope> <trig> <expansion>  # seed a [snippets.<scope>] entry on app.config
//! shell <cmd>                    # run `<cmd>` via $SHELL -c in workspace (non-zero exit fails)
//! ghost <text>                   # inject an AI ghost-text suggestion on the active editor
//! click <x> <y>                  # left-click at screen cell (x,y) — 0-based
//! rightclick <x> <y>             # right-click (opens context menus)
//! doubleclick <x> <y>            # double-click (row activation in list panes)
//! scroll <x> <y> <up|down>       # mouse wheel at (x,y)
//! expect screen contains <text>  # the rendered virtual screen contains the substring
//! expect screen lacks <text>     # …does not
//! expect dirty <true|false>      # the active editor's dirty flag
//! expect pane <text>             # the active pane's title contains the substring
//! expect file <relpath> contains <text>  # the file at <relpath> (workspace-rel) contains it
//! expect file <relpath> lacks <text>     # …does not
//! ```
//! `<text>` may be wrapped in `"…"` (one layer stripped); inside it `\n` `\t` `\\`
//! `\"` are unescaped.

use std::path::{Path, PathBuf};
use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};

use crate::app::App;
use crate::config::Config;

const SCREEN_W: u16 = 120;
const SCREEN_H: u16 = 40;

#[derive(Debug, Clone)]
enum Step {
    Write {
        rel: String,
        content: String,
    },
    Open(String),
    Key(KeyEvent),
    Type(String),
    Command(String),
    /// Run an ex command via `App::run_ex_command` — `ex bd!` runs `:bd!`.
    Ex(String),
    Wait(u64),
    Snippet {
        scope: String,
        trigger: String,
        expansion: String,
    },
    /// Run `<cmd>` via `$SHELL -c` (POSIX) / `cmd.exe /C` (Windows) in the
    /// workspace tempdir. Non-zero exit fails the test with stderr in the
    /// message. Useful for fixture setup that mnml itself can't do —
    /// `git init`, creating non-text files, etc.
    Shell(String),
    /// Inject an AI ghost-text suggestion onto the active editor — the
    /// real suggestion path is a worker thread (API / local model) that
    /// can't run deterministically in a test, so this seeds the state
    /// directly to exercise the accept/dismiss key handling.
    Ghost(String),
    /// A mouse interaction at `(x, y)` (0-based screen cells), dispatched
    /// through `tui::dispatch_mouse` — the same path the real event loop
    /// uses. Covers clicks, right-clicks, double-clicks, and wheel.
    Mouse {
        x: u16,
        y: u16,
        action: MouseAction,
    },
    /// A left-button drag: `Down` at `(from_x, from_y)`, then a
    /// Bresenham-style sequence of intermediate `Drag` events to
    /// `(to_x, to_y)`, then `Up`. Mirrors the IPC `drag` command's
    /// path so .test scripts can exercise drag-select / scrollbar
    /// drag / tab reorder.
    Drag {
        from_x: u16,
        from_y: u16,
        to_x: u16,
        to_y: u16,
    },
}

/// What a `Step::Mouse` does at its `(x, y)`.
#[derive(Debug, Clone, Copy)]
enum MouseAction {
    Click,
    RightClick,
    DoubleClick,
    ScrollUp,
    ScrollDown,
}

#[derive(Debug, Clone)]
enum Check {
    ScreenContains(String),
    ScreenLacks(String),
    Dirty(bool),
    PaneTitle(String),
    /// On-disk check — the file at `rel` (relative to the workspace) contains
    /// the given substring. Useful for save-path tests where the rendered
    /// screen wouldn't show the result.
    FileContains {
        rel: String,
        text: String,
    },
    /// On-disk check — the file at `rel` does **not** contain the substring.
    FileLacks {
        rel: String,
        text: String,
    },
    /// Active editor's `highlights` field has at least `min` non-trivial
    /// spans summed across all lines. Catches regressions where syntax
    /// highlighting silently breaks (e.g. a grammar's queries fail to
    /// compile and we end up emitting zero spans).
    HighlightsAtLeast {
        min: usize,
    },
}

#[derive(Debug, Clone)]
enum Stmt {
    Step(Step),
    Check(Check),
}

/// A `(line_number_1based, parsed_statement)`.
type Line = (usize, Stmt);

/// Result of running one `.test` file.
pub struct TestOutcome {
    pub name: String,
    pub passed: bool,
    /// `Some` with a human-readable reason when `!passed`.
    pub message: Option<String>,
}

/// Parse `.test` source into statements (with their 1-based line numbers).
fn parse(text: &str) -> Result<Vec<Line>, String> {
    let mut out = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let ln = i + 1;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (head, rest) = split1(line);
        let stmt = match head {
            "write" => {
                let (rel, content) = split1(rest);
                if rel.is_empty() {
                    return Err(format!("line {ln}: `write` needs a path"));
                }
                Stmt::Step(Step::Write {
                    rel: rel.to_string(),
                    content: unescape(content.trim()),
                })
            }
            "open" => {
                if rest.is_empty() {
                    return Err(format!("line {ln}: `open` needs a path"));
                }
                Stmt::Step(Step::Open(rest.trim().to_string()))
            }
            "key" => {
                let spec = rest.trim();
                let ev = crate::input::keymap::parse_key_spec(spec)
                    .ok_or_else(|| format!("line {ln}: unrecognised key spec `{spec}`"))?;
                Stmt::Step(Step::Key(ev))
            }
            "type" => Stmt::Step(Step::Type(unescape(rest))),
            "command" => {
                if rest.is_empty() {
                    return Err(format!("line {ln}: `command` needs an id"));
                }
                Stmt::Step(Step::Command(rest.trim().to_string()))
            }
            "ex" => {
                if rest.is_empty() {
                    return Err(format!("line {ln}: `ex` needs an ex command"));
                }
                Stmt::Step(Step::Ex(rest.trim().to_string()))
            }
            "wait" => {
                let ms = rest
                    .trim()
                    .parse::<u64>()
                    .map_err(|_| format!("line {ln}: `wait` needs a millisecond count"))?;
                Stmt::Step(Step::Wait(ms))
            }
            "snippet" => {
                let (scope, rest1) = split1(rest);
                let (trigger, expansion) = split1(rest1);
                if scope.is_empty() || trigger.is_empty() {
                    return Err(format!(
                        "line {ln}: `snippet` needs <scope> <trigger> <expansion>"
                    ));
                }
                Stmt::Step(Step::Snippet {
                    scope: scope.to_string(),
                    trigger: trigger.to_string(),
                    expansion: unescape(expansion),
                })
            }
            "shell" => {
                let cmd = rest.trim();
                if cmd.is_empty() {
                    return Err(format!("line {ln}: `shell` needs a command"));
                }
                Stmt::Step(Step::Shell(cmd.to_string()))
            }
            "ghost" => {
                let text = unescape(rest);
                if text.is_empty() {
                    return Err(format!("line {ln}: `ghost` needs suggestion text"));
                }
                Stmt::Step(Step::Ghost(text))
            }
            "click" | "rightclick" | "doubleclick" | "scroll" => {
                let (x, y, rest2) = parse_xy(ln, head, rest)?;
                let action = match head {
                    "click" => MouseAction::Click,
                    "rightclick" => MouseAction::RightClick,
                    "doubleclick" => MouseAction::DoubleClick,
                    _ => match rest2.trim() {
                        "up" => MouseAction::ScrollUp,
                        "down" => MouseAction::ScrollDown,
                        _ => {
                            return Err(format!("line {ln}: `scroll X Y <up|down>`"));
                        }
                    },
                };
                Stmt::Step(Step::Mouse { x, y, action })
            }
            "drag" => {
                // Form: `drag FROM_X FROM_Y TO_X TO_Y`.
                let (from_x, from_y, r1) = parse_xy(ln, "drag", rest)?;
                let (to_x, to_y, _r2) = parse_xy(ln, "drag", &r1)?;
                Stmt::Step(Step::Drag {
                    from_x,
                    from_y,
                    to_x,
                    to_y,
                })
            }
            "expect" => parse_expect(ln, rest)?,
            other => return Err(format!("line {ln}: unknown statement `{other}`")),
        };
        out.push((ln, stmt));
    }
    Ok(out)
}

fn parse_expect(ln: usize, rest: &str) -> Result<Stmt, String> {
    let (what, arg) = split1(rest);
    let c = match what {
        "screen" => {
            let (op, text) = split1(arg);
            match op {
                "contains" => Check::ScreenContains(unescape(text)),
                "lacks" => Check::ScreenLacks(unescape(text)),
                _ => return Err(format!("line {ln}: expect screen <contains|lacks> …")),
            }
        }
        "dirty" => match arg.trim() {
            "true" => Check::Dirty(true),
            "false" => Check::Dirty(false),
            _ => return Err(format!("line {ln}: expect dirty <true|false>")),
        },
        "pane" => Check::PaneTitle(unescape(arg)),
        "highlights" => {
            // `expect highlights at_least <N>` — total spans across all
            // lines of the active editor must be ≥ N.
            let (op, num) = split1(arg);
            match op {
                "at_least" => {
                    let min: usize = num
                        .trim()
                        .parse()
                        .map_err(|_| format!("line {ln}: expect highlights at_least <usize>"))?;
                    Check::HighlightsAtLeast { min }
                }
                _ => return Err(format!("line {ln}: expect highlights at_least <N>")),
            }
        }
        "file" => {
            // `expect file <relpath> <contains|lacks> <text>`
            let (rel, rest1) = split1(arg);
            if rel.is_empty() {
                return Err(format!("line {ln}: expect file needs a path"));
            }
            let (op, text) = split1(rest1);
            match op {
                "contains" => Check::FileContains {
                    rel: rel.to_string(),
                    text: unescape(text),
                },
                "lacks" => Check::FileLacks {
                    rel: rel.to_string(),
                    text: unescape(text),
                },
                _ => return Err(format!("line {ln}: expect file <path> <contains|lacks> …")),
            }
        }
        _ => return Err(format!("line {ln}: unknown expectation `{what}`")),
    };
    Ok(Stmt::Check(c))
}

/// Split off the first whitespace-delimited token; return `(token, rest_trimmed_left)`.
fn split1(s: &str) -> (&str, &str) {
    let s = s.trim_start();
    match s.find(char::is_whitespace) {
        Some(i) => (&s[..i], s[i..].trim_start()),
        None => (s, ""),
    }
}

/// Parse a leading `X Y` cell-coordinate pair off `rest`; return
/// `(x, y, remainder)`. Used by the mouse statements.
fn parse_xy(ln: usize, kw: &str, rest: &str) -> Result<(u16, u16, String), String> {
    let (xs, r1) = split1(rest);
    let (ys, r2) = split1(r1);
    let coord_err = || format!("line {ln}: `{kw}` needs `X Y` cell coordinates");
    let x = xs.parse::<u16>().map_err(|_| coord_err())?;
    let y = ys.parse::<u16>().map_err(|_| coord_err())?;
    Ok((x, y, r2.to_string()))
}

/// Strip one optional layer of `"…"` and unescape `\n \t \\ \"`.
fn unescape(s: &str) -> String {
    let s = s.trim();
    let inner = if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        &s[1..s.len() - 1]
    } else {
        s
    };
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some('"') => out.push('"'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Run one `.test` file. Never panics — a parse error / IO error / failed
/// expectation all come back as `TestOutcome { passed: false, .. }`.
pub fn run_test(path: &Path) -> TestOutcome {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string());
    let fail = |msg: String| TestOutcome {
        name: name.clone(),
        passed: false,
        message: Some(msg),
    };

    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => return fail(format!("can't read: {e}")),
    };
    let stmts = match parse(&text) {
        Ok(s) => s,
        Err(e) => return fail(e),
    };
    let dir = match tempfile::tempdir() {
        Ok(d) => d,
        Err(e) => return fail(format!("tempdir: {e}")),
    };
    let workspace = dir.path().to_path_buf();
    let mut app = match App::new(workspace.clone(), Config::default()) {
        Ok(a) => a,
        Err(e) => return fail(format!("App::new: {e}")),
    };
    let mut term = match Terminal::new(TestBackend::new(SCREEN_W, SCREEN_H)) {
        Ok(t) => t,
        Err(e) => return fail(format!("TestBackend: {e}")),
    };

    macro_rules! render {
        () => {{
            app.tick();
            if let Err(e) = term.draw(|f| crate::ui::draw(f, &mut app)) {
                return fail(format!("render: {e}"));
            }
        }};
    }
    render!();

    for (ln, stmt) in &stmts {
        match stmt {
            Stmt::Step(step) => {
                if let Err(e) = run_step(&mut app, &workspace, step) {
                    return fail(format!("line {ln}: {e}"));
                }
                render!();
            }
            Stmt::Check(check) => {
                let screen = screen_text(term.backend().buffer());
                if let Err(e) = run_check(&app, &screen, check) {
                    return fail(format!("line {ln}: {e}"));
                }
            }
        }
    }

    TestOutcome {
        name,
        passed: true,
        message: None,
    }
}

fn run_step(app: &mut App, workspace: &Path, step: &Step) -> Result<(), String> {
    // `.test` script paths must be workspace-relative. Without this
    // guard, `write /etc/passwd "..."` would land verbatim because
    // `Path::join` short-circuits on absolute input. Same hazard for
    // `open` and any other future fs-touching step. Untouched-
    // surfaces hunt SEV-2 (2026-06-08).
    let reject_unsafe_path = |rel: &str, kw: &str| -> Result<(), String> {
        let p = std::path::Path::new(rel);
        if p.is_absolute() {
            return Err(format!("{kw} {rel}: absolute paths are not allowed"));
        }
        if p.components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(format!(
                "{kw} {rel}: `..` components are not allowed (would escape workspace)"
            ));
        }
        Ok(())
    };
    match step {
        Step::Write { rel, content } => {
            reject_unsafe_path(rel, "write")?;
            let p = workspace.join(rel);
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent).map_err(|e| format!("mkdir: {e}"))?;
            }
            std::fs::write(&p, content).map_err(|e| format!("write {rel}: {e}"))
        }
        Step::Open(rel) => {
            reject_unsafe_path(rel, "open")?;
            // `App::open_path` is the explicit-open path — pinned by
            // default. (The tree-click preview behavior lives on
            // `open_path_preview` and is only invoked by the tree
            // click handler.) So no extra `is_preview = false` cleanup
            // is needed here.
            app.open_path(&workspace.join(rel));
            Ok(())
        }
        Step::Key(ev) => {
            crate::tui::dispatch_key(app, *ev);
            Ok(())
        }
        Step::Type(s) => {
            for c in s.chars() {
                let ev = if c == '\n' {
                    KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)
                } else {
                    KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
                };
                crate::tui::dispatch_key(app, ev);
            }
            Ok(())
        }
        Step::Command(id) => {
            if crate::command::run(id, app) {
                Ok(())
            } else {
                Err(format!("no such command `{id}`"))
            }
        }
        Step::Ex(cmd) => {
            app.run_ex_command(cmd);
            Ok(())
        }
        Step::Wait(ms) => {
            std::thread::sleep(Duration::from_millis(*ms));
            Ok(())
        }
        Step::Snippet {
            scope,
            trigger,
            expansion,
        } => {
            app.config
                .snippets
                .entry(scope.clone())
                .or_default()
                .insert(trigger.clone(), expansion.clone());
            Ok(())
        }
        Step::Shell(cmd) => {
            // POSIX shells go through $SHELL -c; Windows uses cmd.exe /C.
            // Workspace is cwd so paths in `<cmd>` resolve naturally.
            #[cfg(windows)]
            let mut shell = std::process::Command::new("cmd");
            #[cfg(windows)]
            shell.args(["/C", cmd]);
            #[cfg(not(windows))]
            let shell_path = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
            #[cfg(not(windows))]
            let mut shell = std::process::Command::new(shell_path);
            #[cfg(not(windows))]
            shell.args(["-c", cmd]);
            let out = shell
                .current_dir(workspace)
                .output()
                .map_err(|e| format!("shell spawn: {e}"))?;
            if !out.status.success() {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
                return Err(format!(
                    "shell `{cmd}` exited {}: {}{}",
                    out.status,
                    stderr.trim(),
                    if stderr.trim().is_empty() {
                        stdout.trim().to_string()
                    } else {
                        String::new()
                    }
                ));
            }
            Ok(())
        }
        Step::Ghost(text) => match app.active.and_then(|i| app.panes.get_mut(i)) {
            Some(crate::pane::Pane::Editor(b)) => {
                b.editor.ghost_suggestion = Some(text.clone());
                Ok(())
            }
            _ => Err("ghost: no active editor pane".to_string()),
        },
        Step::Mouse { x, y, action } => {
            let ev = |kind| MouseEvent {
                kind,
                column: *x,
                row: *y,
                modifiers: KeyModifiers::NONE,
            };
            let mut click = |btn| {
                crate::tui::dispatch_mouse(app, ev(MouseEventKind::Down(btn)));
                crate::tui::dispatch_mouse(app, ev(MouseEventKind::Up(btn)));
            };
            match action {
                MouseAction::Click => click(MouseButton::Left),
                MouseAction::RightClick => click(MouseButton::Right),
                MouseAction::DoubleClick => {
                    click(MouseButton::Left);
                    click(MouseButton::Left);
                }
                MouseAction::ScrollUp => {
                    crate::tui::dispatch_mouse(app, ev(MouseEventKind::ScrollUp));
                }
                MouseAction::ScrollDown => {
                    crate::tui::dispatch_mouse(app, ev(MouseEventKind::ScrollDown));
                }
            }
            Ok(())
        }
        Step::Drag {
            from_x,
            from_y,
            to_x,
            to_y,
        } => {
            // Same path as the IPC `drag` command in `src/ipc/mod.rs`:
            // Down at source, Bresenham-style interpolated `Drag`
            // events ~1 per cell, Up at destination.
            let ev = |kind, col, row| MouseEvent {
                kind,
                column: col,
                row,
                modifiers: KeyModifiers::NONE,
            };
            crate::tui::dispatch_mouse(
                app,
                ev(MouseEventKind::Down(MouseButton::Left), *from_x, *from_y),
            );
            let steps = (to_x.abs_diff(*from_x)).max(to_y.abs_diff(*from_y)) as usize;
            for s in 1..=steps {
                let t = s as f32 / steps as f32;
                let cx = (*from_x as f32 + (*to_x as f32 - *from_x as f32) * t).round() as u16;
                let cy = (*from_y as f32 + (*to_y as f32 - *from_y as f32) * t).round() as u16;
                crate::tui::dispatch_mouse(
                    app,
                    ev(MouseEventKind::Drag(MouseButton::Left), cx, cy),
                );
            }
            crate::tui::dispatch_mouse(
                app,
                ev(MouseEventKind::Up(MouseButton::Left), *to_x, *to_y),
            );
            Ok(())
        }
    }
}

fn run_check(app: &App, screen: &str, check: &Check) -> Result<(), String> {
    match check {
        Check::ScreenContains(t) => {
            if screen.contains(t.as_str()) {
                Ok(())
            } else {
                Err(format!(
                    "screen does not contain {t:?}\n── rendered screen ──\n{screen}"
                ))
            }
        }
        Check::ScreenLacks(t) => {
            if screen.contains(t.as_str()) {
                Err(format!(
                    "screen unexpectedly contains {t:?}\n── rendered screen ──\n{screen}"
                ))
            } else {
                Ok(())
            }
        }
        Check::Dirty(want) => {
            let got = matches!(app.active_pane(), Some(crate::pane::Pane::Editor(b)) if b.dirty);
            if got == *want {
                Ok(())
            } else {
                Err(format!("active editor dirty == {got}, expected {want}"))
            }
        }
        Check::PaneTitle(t) => match app.active_pane() {
            Some(p) if p.title().contains(t.as_str()) => Ok(()),
            Some(p) => Err(format!(
                "active pane title {:?} does not contain {t:?}",
                p.title()
            )),
            None => Err(format!(
                "no active pane (expected one whose title contains {t:?})"
            )),
        },
        Check::FileContains { rel, text } => {
            let path = app.workspace.join(rel);
            let body = std::fs::read_to_string(&path)
                .map_err(|e| format!("can't read {}: {e}", path.display()))?;
            if body.contains(text.as_str()) {
                Ok(())
            } else {
                Err(format!("file {rel} does not contain {text:?}"))
            }
        }
        Check::FileLacks { rel, text } => {
            let path = app.workspace.join(rel);
            let body = std::fs::read_to_string(&path)
                .map_err(|e| format!("can't read {}: {e}", path.display()))?;
            if body.contains(text.as_str()) {
                Err(format!("file {rel} unexpectedly contains {text:?}"))
            } else {
                Ok(())
            }
        }
        Check::HighlightsAtLeast { min } => {
            let count = match app.active_pane() {
                Some(crate::pane::Pane::Editor(b)) => {
                    b.highlights.iter().map(|line| line.len()).sum::<usize>()
                }
                _ => {
                    return Err("expect highlights: no active editor pane".to_string());
                }
            };
            if count >= *min {
                Ok(())
            } else {
                Err(format!(
                    "expected ≥ {min} highlight spans, got {count} (highlighting may be broken)"
                ))
            }
        }
    }
}

/// Flatten a `TestBackend` buffer to text (rows joined by `\n`, no trailing one).
fn screen_text(buf: &ratatui::buffer::Buffer) -> String {
    let area = buf.area;
    let mut s =
        String::with_capacity(area.width as usize * area.height as usize + area.height as usize);
    for y in 0..area.height {
        for x in 0..area.width {
            s.push_str(buf[(x, y)].symbol());
        }
        if y + 1 < area.height {
            s.push('\n');
        }
    }
    s
}

/// Run every `*.test` under `root` (recursively), or `root` itself if it's a file.
/// Returns `(outcomes, all_passed)`.
pub fn run_path(root: &Path) -> (Vec<TestOutcome>, bool) {
    let mut files: Vec<PathBuf> = Vec::new();
    if root.is_file() {
        files.push(root.to_path_buf());
    } else {
        for entry in ignore::WalkBuilder::new(root).build().flatten() {
            let p = entry.path();
            if p.is_file() && p.extension().is_some_and(|e| e == "test") {
                files.push(p.to_path_buf());
            }
        }
    }
    files.sort();
    let outcomes: Vec<TestOutcome> = files.iter().map(|p| run_test(p)).collect();
    let all_passed = outcomes.iter().all(|o| o.passed);
    (outcomes, all_passed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_basic_script() {
        let src = "\
# a comment
write foo.txt hello
open foo.txt
type \" world\"
key ctrl+s
expect screen contains \"hello world\"
expect dirty false
";
        let stmts = parse(src).unwrap();
        assert_eq!(stmts.len(), 6);
        assert!(matches!(stmts[0].1, Stmt::Step(Step::Write { .. })));
        assert!(matches!(stmts[3].1, Stmt::Step(Step::Key(_))));
        assert!(matches!(stmts[5].1, Stmt::Check(Check::Dirty(false))));
    }

    #[test]
    fn unescape_strips_quotes_and_escapes() {
        assert_eq!(unescape(r#""a\nb""#), "a\nb");
        assert_eq!(unescape("plain"), "plain");
        assert_eq!(unescape(r#""tab\there""#), "tab\there");
    }

    #[test]
    fn rejects_bad_key_spec() {
        assert!(parse("key ctrl+nope+x").is_err());
    }

    #[test]
    fn parses_shell_step() {
        let stmts = parse("shell echo hi\n").unwrap();
        match &stmts[0].1 {
            Stmt::Step(Step::Shell(cmd)) => assert_eq!(cmd, "echo hi"),
            other => panic!("expected Shell, got {other:?}"),
        }
    }

    #[test]
    fn rejects_empty_shell_command() {
        assert!(parse("shell   \n").is_err());
    }

    #[test]
    fn parses_ghost_step() {
        let stmts = parse("ghost \"a + b\"\n").unwrap();
        match &stmts[0].1 {
            Stmt::Step(Step::Ghost(text)) => assert_eq!(text, "a + b"),
            other => panic!("expected Ghost, got {other:?}"),
        }
        assert!(parse("ghost   \n").is_err());
    }

    #[test]
    fn parses_mouse_steps() {
        let stmts =
            parse("click 12 5\nrightclick 3 1\ndoubleclick 8 8\nscroll 40 20 down\n").unwrap();
        assert!(matches!(
            stmts[0].1,
            Stmt::Step(Step::Mouse {
                x: 12,
                y: 5,
                action: MouseAction::Click
            })
        ));
        assert!(matches!(
            stmts[1].1,
            Stmt::Step(Step::Mouse {
                action: MouseAction::RightClick,
                ..
            })
        ));
        assert!(matches!(
            stmts[2].1,
            Stmt::Step(Step::Mouse {
                action: MouseAction::DoubleClick,
                ..
            })
        ));
        assert!(matches!(
            stmts[3].1,
            Stmt::Step(Step::Mouse {
                x: 40,
                y: 20,
                action: MouseAction::ScrollDown
            })
        ));
        // Non-numeric coords + a bad scroll direction are rejected.
        assert!(parse("click x y\n").is_err());
        assert!(parse("scroll 1 2 sideways\n").is_err());
    }

    #[test]
    fn runs_a_tiny_edit_script() {
        // Exercise the full pipeline without a .test file on disk.
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("t.test");
        std::fs::write(
            &file,
            "\
write hello.txt seedtext
open hello.txt
expect screen contains seedtext
expect dirty false
type ZZZ
expect dirty true
expect screen contains ZZZseedtext
",
        )
        .unwrap();
        let o = run_test(&file);
        assert!(o.passed, "{:?}", o.message);
    }
}
