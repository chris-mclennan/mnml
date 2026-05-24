//! Embedded terminal — one [`PtySession`] is the `Pane::Pty` payload: a live pty
//! plus a child process (`$SHELL`, `claude`, `codex`, …) whose output is parsed
//! into a [`vt100`] grid the renderer reads. A reader thread pumps the pty's
//! output into a `Mutex<vt100::Parser<TitleSink>>`; outbound keystrokes go through the pty's
//! write half on the UI thread (event-driven, so no writer thread needed).
//! Dropping the session kills the child and joins the reader.
//!
//! Each pty is a pane in the split tree — no separate tab strip;
//! multiple shells = multiple splits.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

/// How many lines of output vt100 keeps for scroll-back (`Shift+PgUp` / wheel).
const SCROLLBACK_LINES: usize = 5000;

/// vt100 0.16 delivers the OSC window title (`ESC]0;…` / `ESC]2;…`)
/// through a [`vt100::Callbacks`] impl rather than storing it on
/// `Screen`. This sink keeps the latest title so [`PtySession::tab_label`]
/// can pick it up — Claude Code / Codex / a shell all name their own
/// session this way.
#[derive(Default)]
pub struct TitleSink {
    title: String,
}

impl vt100::Callbacks for TitleSink {
    fn set_window_title(&mut self, _: &mut vt100::Screen, title: &[u8]) {
        self.title = String::from_utf8_lossy(title).into_owned();
    }
}

/// What runs inside a pty pane — a config record so the caller picks "shell" vs
/// "claude" without this module knowing about products.
#[derive(Debug, Clone)]
pub struct BinaryProfile {
    /// Tab/title label — `terminal (zsh)`, `claude code`, `codex`, …
    pub label: String,
    /// Executable (looked up on `PATH` if not absolute).
    pub exe: String,
    pub args: Vec<String>,
    /// Working directory; `None` ⇒ inherit.
    pub cwd: Option<PathBuf>,
    /// Extra env vars to set in the child.
    pub env: Vec<(String, String)>,
    /// For `claude` profiles: the `--session-id` / `--resume` id, so mnml can
    /// open a transcript mirror of this session. `None` for shells / codex.
    pub session_id: Option<String>,
}

impl BinaryProfile {
    /// The user's `$SHELL` (interactive), or `/bin/sh`.
    pub fn shell(cwd: Option<PathBuf>) -> Self {
        let exe = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let name = exe.rsplit('/').next().unwrap_or("shell").to_string();
        BinaryProfile {
            label: format!("terminal ({name})"),
            exe,
            args: Vec::new(),
            cwd,
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `claude` (Claude Code), with a known `--session-id` (so mnml can mirror the
    /// transcript). If the workspace has a `.mnml/CLAUDE.md`, inject it via
    /// `--append-system-prompt` so the assistant orients before message #1.
    pub fn claude_code(workspace: PathBuf) -> Self {
        let sid = crate::ai::gen_session_id();
        let mut args = vec!["--session-id".to_string(), sid.clone()];
        let brief = workspace.join(".mnml").join("CLAUDE.md");
        if let Ok(text) = std::fs::read_to_string(&brief)
            && !text.trim().is_empty()
        {
            args.push("--append-system-prompt".to_string());
            args.push(text);
        }
        BinaryProfile {
            label: "claude code".to_string(),
            exe: "claude".to_string(),
            args,
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(sid),
        }
    }

    /// `claude` with an initial prompt as the trailing positional arg —
    /// boots an interactive session already seeded with `initial`
    /// (file/selection context the `ai.chat` wrapper formulated). Avoids
    /// the type-into-a-cold-pty timing problem.
    pub fn claude_code_with_prompt(workspace: PathBuf, initial: String) -> Self {
        let mut p = Self::claude_code(workspace);
        p.args.push(initial);
        p
    }

    /// `claude --resume <session_id>` — open an existing session (e.g. one started
    /// by an `ai.*` one-shot) interactively, with its conversation already loaded.
    pub fn claude_code_resume(workspace: PathBuf, session_id: String) -> Self {
        BinaryProfile {
            label: "claude code (resumed)".to_string(),
            exe: "claude".to_string(),
            args: vec!["--resume".to_string(), session_id.clone()],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: Some(session_id),
        }
    }

    /// A named `[tasks.<name>]` entry — run `cmdline` via `$SHELL -c` in a pty pane.
    /// `cwd` defaults to the workspace.
    pub fn task(name: &str, cmdline: &str, cwd: PathBuf) -> Self {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        BinaryProfile {
            label: format!("task: {name}"),
            exe: shell,
            args: vec!["-c".to_string(), cmdline.to_string()],
            cwd: Some(cwd),
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `codex` (OpenAI Codex CLI).
    pub fn codex(workspace: PathBuf) -> Self {
        BinaryProfile {
            label: "codex".to_string(),
            exe: "codex".to_string(),
            args: Vec::new(),
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
        }
    }

    /// `mixr` — the sibling TUI DJ app (`~/Projects/mixr-rs`). Launches with
    /// `--dashboard` so it lands directly on the controller view (skipping the
    /// browser); the user can press `v` in mixr to cycle through its Panel
    /// layouts to fit mnml's split.
    pub fn mixr(workspace: PathBuf) -> Self {
        BinaryProfile {
            label: "mixr".to_string(),
            exe: "mixr".to_string(),
            args: vec!["--dashboard".to_string()],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
        }
    }
}

/// One live pty + child + vt100 grid. Drop to kill the child + join the reader.
pub struct PtySession {
    pub profile: BinaryProfile,
    /// User-set session name (`:rename`). Shown in the pty-pane tab strip
    /// + the bufferline tab in place of `profile.label` when present.
    pub display_name: Option<String>,
    /// Shared with the reader thread (it writes, the renderer reads).
    pub parser: Arc<Mutex<vt100::Parser<TitleSink>>>,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    reader: Option<JoinHandle<()>>,
    child: Box<dyn Child + Send + Sync>,
    /// Set by the reader thread when the pty hits EOF / error (child gone).
    exited: Arc<Mutex<bool>>,
    /// Last `(rows, cols)` sent to the pty — skip the resize (and its SIGWINCH /
    /// child-redraw flicker) when the rendered size hasn't changed.
    last_size: (u16, u16),
    /// Total bytes the reader has processed — the event loop snapshots this to
    /// know when to redraw (an idle pty shouldn't force per-tick repaints).
    pub bytes_seen: Arc<AtomicU64>,
    /// `true` after the master fd has been handed off to another
    /// process (typically tmnl via SCM_RIGHTS — see
    /// `App::pop_pty_to_tmnl`). [`Drop`] checks this so the released
    /// child is not killed — its new owner is responsible for it.
    released: bool,
}

impl PtySession {
    pub fn spawn(profile: BinaryProfile, rows: u16, cols: u16) -> Result<Self, String> {
        let (rows, cols) = (rows.max(4), cols.max(20));
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("openpty: {e}"))?;

        let mut cmd = CommandBuilder::new(&profile.exe);
        for a in &profile.args {
            cmd.arg(a);
        }
        if let Some(cwd) = &profile.cwd {
            cmd.cwd(cwd);
        }
        for (k, v) in &profile.env {
            cmd.env(k, v);
        }
        // Themed powerline prompt. Sets `MNML_PROMPT_SCRIPT` (path to the
        // installed `prompt.sh`) plus the palette env vars the script
        // reads. The user opts in once via a one-line source in their
        // `.zshrc`/`.bashrc` — see README. Skipped for non-shell pty
        // sessions (claude / codex / etc.) since they don't render
        // their own prompt — heuristic: the profile.exe basename ends
        // in `sh` or matches a known shell.
        if is_shell_profile(&profile.exe) {
            for (k, v) in crate::shell_prompt::theme_env_vars("mnml") {
                cmd.env(k, v);
            }
        }
        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("spawn {}: {e} — is it on PATH?", profile.exe))?;
        drop(pair.slave);

        let parser = Arc::new(Mutex::new(vt100::Parser::new_with_callbacks(
            rows,
            cols,
            SCROLLBACK_LINES,
            TitleSink::default(),
        )));
        let exited = Arc::new(Mutex::new(false));
        let bytes_seen = Arc::new(AtomicU64::new(0));

        let mut reader_handle = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("clone pty reader: {e}"))?;
        let r_parser = Arc::clone(&parser);
        let r_exited = Arc::clone(&exited);
        let r_bytes = Arc::clone(&bytes_seen);
        let reader = std::thread::Builder::new()
            .name(format!("mnml-pty-{}", profile.exe))
            .spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    match reader_handle.read(&mut buf) {
                        Ok(0) | Err(_) => {
                            if let Ok(mut e) = r_exited.lock() {
                                *e = true;
                            }
                            return;
                        }
                        Ok(n) => {
                            if let Ok(mut p) = r_parser.lock() {
                                p.process(&buf[..n]);
                            }
                            r_bytes.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                }
            })
            .map_err(|e| format!("spawn pty reader thread: {e}"))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("take pty writer: {e}"))?;

        Ok(PtySession {
            profile,
            display_name: None,
            parser,
            writer,
            master: pair.master,
            reader: Some(reader),
            child,
            exited,
            last_size: (rows, cols),
            bytes_seen,
            released: false,
        })
    }

    /// Raw fd of the pty master, when available. Used by the
    /// `:tmnl.pop-pty` handoff path to attach the fd via SCM_RIGHTS
    /// before transferring ownership to tmnl. `None` for backends
    /// that don't expose an OS fd (portable-pty's serial / Windows
    /// paths; not hit in practice on mnml's Unix-only targets).
    #[cfg(unix)]
    pub fn raw_master_fd(&self) -> Option<std::os::unix::io::RawFd> {
        self.master.as_raw_fd()
    }

    /// Mark this session as released — its master fd has been
    /// transferred to another process (tmnl). [`Drop`] now skips
    /// killing the child + waiting on it; the new owner is the
    /// reaper. The reader thread is still joined so its exit isn't
    /// stranded.
    pub fn mark_released(&mut self) {
        self.released = true;
    }

    /// Return the child's OS pid. Used only by tests that verify
    /// `Drop` skips `child.kill()` when `released` is set — locking
    /// that invariant down so a future refactor can't silently
    /// reintroduce the kill-the-adopted-child bug.
    #[cfg(test)]
    pub fn child_pid_for_test(&self) -> Option<u32> {
        self.child.process_id()
    }

    /// Resize the pty (and the parser grid) to `rows × cols`. No-op when
    /// unchanged — every resize SIGWINCHes the child into a redraw.
    pub fn resize(&mut self, rows: u16, cols: u16) {
        let (rows, cols) = (rows.max(4), cols.max(20));
        if self.last_size == (rows, cols) {
            return;
        }
        self.last_size = (rows, cols);
        let _ = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        if let Ok(mut p) = self.parser.lock() {
            p.screen_mut().set_size(rows, cols);
        }
    }

    pub fn write_bytes(&mut self, bytes: &[u8]) {
        let _ = self.writer.write_all(bytes);
        let _ = self.writer.flush();
    }

    /// Scroll the view `delta` lines further into the scroll-back history (negative
    /// ⇒ back toward the live bottom). Clamped by vt100 to the available history.
    pub fn scroll_history(&self, delta: isize) {
        if let Ok(mut p) = self.parser.lock() {
            let cur = p.screen().scrollback() as isize;
            p.screen_mut().set_scrollback((cur + delta).max(0) as usize);
        }
    }
    /// Jump to the oldest line (`usize::MAX` is clamped to the max history).
    pub fn scroll_to_top(&self) {
        if let Ok(mut p) = self.parser.lock() {
            p.screen_mut().set_scrollback(usize::MAX);
        }
    }
    /// Back to the live view (bottom).
    pub fn scroll_to_bottom(&self) {
        if let Ok(mut p) = self.parser.lock() {
            p.screen_mut().set_scrollback(0);
        }
    }

    pub fn is_exited(&self) -> bool {
        self.exited.lock().map(|e| *e).unwrap_or(true)
    }

    pub fn bytes_processed(&self) -> u64 {
        self.bytes_seen.load(Ordering::Relaxed)
    }

    pub fn title(&self) -> String {
        let base = self.tab_label();
        if self.is_exited() {
            format!("{base} ✗")
        } else {
            base
        }
    }

    /// The session's tab/title label. The *name* is the user-set
    /// `display_name` (right-click rename / `:rename`) → the program's
    /// OSC window title → the binary profile's label. When the session
    /// is a Claude Code instance that's thinking, the current spinner
    /// glyph is appended (`my-session ✽`) — the name stays put so the
    /// tab is still identifiable, the glyph animates frame to frame.
    pub fn tab_label(&self) -> String {
        let (osc, glyph) = match self.parser.lock() {
            Ok(p) => (
                p.callbacks().title.clone(),
                detect_spinner_glyph(p.screen()),
            ),
            Err(_) => (String::new(), None),
        };
        let name = resolve_tab_label(self.display_name.as_deref(), &osc, &self.profile.label);
        match glyph {
            Some(g) => format!("{name} {g}"),
            None => name,
        }
    }
}

/// Pick a pty session's tab *name* from the candidate sources, in
/// priority order: an explicit user-set name, the program's OSC window
/// title, then the binary profile's default label. Blank candidates
/// are skipped. The thinking-spinner glyph is layered on by the caller
/// ([`PtySession::tab_label`]) — it's not a name. Pure — unit-tested.
pub(crate) fn resolve_tab_label(
    display_name: Option<&str>,
    osc_title: &str,
    profile_label: &str,
) -> String {
    for cand in [display_name, Some(osc_title)].into_iter().flatten() {
        let cand = cand.trim();
        if !cand.is_empty() {
            return cand.to_string();
        }
    }
    profile_label.to_string()
}

/// Scan a pty screen for a Claude-Code-style spinner — a row carrying
/// *both* a spinner glyph and an ellipsis (e.g. `✽ Wandering…`).
/// Returns the *current* glyph; Claude cycles it frame to frame, so a
/// caller that appends it to the tab label gets a live animation while
/// keeping the session name. `None` when no such line is visible —
/// Heuristic: is this `BinaryProfile.exe` a shell program (`bash`,
/// `zsh`, `fish`, `sh`, …) for which the themed prompt env vars are
/// meaningful? AI CLIs (claude, codex) and one-shot tools render their
/// own UI and shouldn't get a shell-style PS1 injected.
fn is_shell_profile(exe: &str) -> bool {
    let base = std::path::Path::new(exe)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(exe);
    matches!(
        base,
        "sh" | "bash" | "zsh" | "fish" | "dash" | "ksh" | "tcsh"
    )
}

/// Claude idle, or a non-Claude program. The two-signal (glyph +
/// ellipsis) test rejects unrelated lines that merely contain a star.
/// Bottom-up scan: Claude's spinner sits near the input prompt.
fn detect_spinner_glyph(screen: &vt100::Screen) -> Option<char> {
    const SPINNER_CHARS: &[char] = &[
        '✱', '✶', '✦', '✧', '⋆', '✽', '✻', '❋', '✿', '✺', '✷', '✸', '✹', '❉', '❅', '◐', '◓', '◑',
        '◒',
    ];
    let (rows, cols) = screen.size();
    for row in (0..rows).rev() {
        let mut line = String::new();
        for col in 0..cols {
            if let Some(c) = screen.cell(row, col) {
                line.push_str(c.contents());
            }
        }
        let Some(glyph) = line.chars().find(|c| SPINNER_CHARS.contains(c)) else {
            continue;
        };
        if line.contains('…') || line.contains("...") {
            return Some(glyph);
        }
    }
    None
}

impl Drop for PtySession {
    fn drop(&mut self) {
        if self.released {
            // Released sessions belong to another process now (tmnl,
            // via the pty-fd handoff). Killing the child here would
            // terminate the code the user is still using over in the
            // new tab — the child's pid is shared between processes,
            // not parent-specific.
            //
            // We also intentionally don't `join` the reader thread:
            // it holds a *duped* master fd (from `try_clone_reader`),
            // so closing our `master` doesn't make it see EOF. There
            // is no portable_pty API to interrupt a blocking pty
            // read, so the thread would hang forever in `read()`
            // until the child dies in the receiving process. Letting
            // the JoinHandle drop detaches the thread — the OS reaps
            // it on process exit (which, for the `:tmnl.pop-pty`
            // flow, is usually shortly after).
            //
            // v1 known limitation: until then, both mnml's leaked
            // reader and tmnl's adopted reader contend for the pty
            // master. The bytes mnml reads are dropped (its parser
            // Arc decrefs but the reader's clone keeps it alive),
            // so tmnl may see a thinned-out stream. Acceptable
            // because the typical flow is "pop, then close mnml" —
            // the leak window is short.
            self.reader.take();
            return;
        }
        let _ = self.child.kill();
        if let Some(j) = self.reader.take() {
            let _ = j.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_tab_label_prefers_name_then_osc_then_profile() {
        // An explicit user name wins.
        assert_eq!(resolve_tab_label(Some("mine"), "osc", "Claude"), "mine");
        // No user name → the program's OSC window title.
        assert_eq!(
            resolve_tab_label(None, "Claude · refactor", "Claude"),
            "Claude · refactor"
        );
        // Nothing set → the binary profile's label.
        assert_eq!(resolve_tab_label(None, "", "Claude"), "Claude");
        assert_eq!(resolve_tab_label(None, "   ", "Codex"), "Codex");
        // Blank candidates are skipped.
        assert_eq!(resolve_tab_label(Some(" "), "osc", "Codex"), "osc");
    }

    #[test]
    fn detect_spinner_glyph_finds_claude_spinner() {
        let mut p = vt100::Parser::new(6, 60, 0);
        p.process(b"idle output line\r\n");
        p.process("✽ Wandering… (3s · esc to interrupt)\r\n".as_bytes());
        assert_eq!(detect_spinner_glyph(p.screen()), Some('✽'));
    }

    #[test]
    fn detect_spinner_glyph_none_without_a_spinner() {
        let mut p = vt100::Parser::new(6, 60, 0);
        p.process(b"just some normal output\r\nno spinner here\r\n");
        assert!(detect_spinner_glyph(p.screen()).is_none());
        // A spinner glyph but no ellipsis → rejected (two-signal combo).
        let mut p2 = vt100::Parser::new(6, 60, 0);
        p2.process("✽ a starred heading\r\n".as_bytes());
        assert!(detect_spinner_glyph(p2.screen()).is_none());
    }

    #[test]
    fn shell_profile_uses_env_shell() {
        // Don't actually mutate the process env (parallel tests) — just check the
        // shape of a constructed profile against whatever $SHELL is.
        let p = BinaryProfile::shell(None);
        assert!(!p.exe.is_empty());
        assert!(p.label.starts_with("terminal ("));
        assert!(p.args.is_empty());
    }

    #[test]
    fn claude_profile_injects_claude_md_when_present() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".mnml")).unwrap();
        std::fs::write(dir.path().join(".mnml/CLAUDE.md"), "# brief\nhello mnml").unwrap();
        let p = BinaryProfile::claude_code(dir.path().to_path_buf());
        assert_eq!(p.exe, "claude");
        let i = p
            .args
            .iter()
            .position(|a| a == "--append-system-prompt")
            .expect("flag");
        assert!(p.args[i + 1].contains("hello mnml"));

        // And skips it when absent.
        let dir2 = tempfile::tempdir().unwrap();
        let p2 = BinaryProfile::claude_code(dir2.path().to_path_buf());
        assert!(!p2.args.iter().any(|a| a == "--append-system-prompt"));
    }

    #[test]
    fn spawns_a_short_shell_command_and_reaps() {
        // Spawn `sh -c 'exit 0'`-ish via a profile so we exercise the pty path.
        let mut prof = BinaryProfile::shell(None);
        prof.exe = "/bin/sh".to_string();
        prof.args = vec!["-c".to_string(), "true".to_string()];
        let Ok(s) = PtySession::spawn(prof, 24, 80) else {
            // CI without a pty — skip rather than fail.
            return;
        };
        // Give the child a moment to exit; the reader sets `exited` on EOF.
        for _ in 0..50 {
            if s.is_exited() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        // Dropping joins the reader thread without hanging.
        drop(s);
    }
}
