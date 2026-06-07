//! tmnl-handoff App methods — for sending commands to the parent tmnl
//! renderer when mnml is running as a `--blit` native client. The
//! enabling protocol piece is `tmnl-protocol::Message::OpenPane`,
//! drained from `App.pending_open_panes` by the blit loop each tick.
//!
//! This is the **simple variant** of pty-handoff (the task's "(2)"):
//! ask tmnl to *spawn a new tab* running `<command> <args…>`. The
//! existing pty session in mnml stays put; this is a fresh process
//! in a sibling tab. Useful when you want a CLI (`claude`, `codex`,
//! a shell) running in its own dedicated tab next to mnml rather
//! than embedded in a `Pane::Pty`.
//!
//! The hard variant — *moving* a running pty session from mnml's
//! pane into a new tmnl tab via `SCM_RIGHTS` fd-passing — landed in
//! task #49 / #50. See `pop_pty_to_tmnl` below for the sender side
//! and tmnl's `src/transfer.rs` for the receiver.

use super::*;

impl App {
    /// Ask the tmnl host to open a new native tab running `command`
    /// with `args`. When mnml isn't a tmnl native client, toasts an
    /// explanation instead of silently no-op'ing.
    pub fn tmnl_open_tab(&mut self, command: String, args: Vec<String>) {
        if !self.under_tmnl {
            self.toast(
                "tmnl.open-tab: mnml isn't running under tmnl — \
                 run this command in your shell instead",
            );
            return;
        }
        self.pending_open_panes.push((command.clone(), args));
        self.toast(format!("tmnl: opening {command} in a new tab"));
    }

    /// Convenience — open Claude Code in a new tmnl tab. Equivalent to
    /// `:tmnl.open-tab claude` but registers as a palette command.
    pub fn tmnl_open_claude_in_tab(&mut self) {
        self.tmnl_open_tab("claude".to_string(), Vec::new());
    }

    /// Convenience — open Codex in a new tmnl tab.
    pub fn tmnl_open_codex_in_tab(&mut self) {
        self.tmnl_open_tab("codex".to_string(), Vec::new());
    }

    /// Smart launcher for terminal-native tools (`htop`, `iftop`, …):
    /// under tmnl, opens the binary as a sibling native tab so it
    /// survives mnml's exit and gets its own chrome tab; standalone,
    /// opens it as a Pty pane inside mnml's layout.
    ///
    /// Pre-checks installation. If the binary isn't on PATH, yanks an
    /// OS-appropriate install command (`brew install …` on macOS,
    /// `apt install …` / `dnf install …` / `pacman -S …` on Linux)
    /// to the clipboard and toasts it. Auto-install is intentionally
    /// not the default — it would need sudo on Linux and writes to
    /// brew's prefix on macOS, which is the kind of side-effect that
    /// belongs behind a confirmation, not a click.
    pub fn launch_tool(&mut self, binary: &str, args: Vec<String>) {
        if !crate::integration_detect::is_binary_installed(binary) {
            self.tool_not_installed(binary);
            return;
        }
        if self.under_tmnl {
            self.tmnl_open_tab(binary.to_string(), args);
            return;
        }
        // Standalone — spawn as a Pty pane. `BinaryProfile::task` runs
        // via `$SHELL -c "<binary> <args…>"`.
        let cwd = self.workspace.clone();
        let cmdline = if args.is_empty() {
            binary.to_string()
        } else {
            format!("{binary} {}", args.join(" "))
        };
        self.open_pty(crate::pty_pane::BinaryProfile::task(binary, &cmdline, cwd));
    }

    /// Build an OS-appropriate install hint for a missing tool, yank
    /// it to the clipboard, and toast. Caller is [`Self::launch_tool`]
    /// when `is_binary_installed` returns false.
    fn tool_not_installed(&mut self, binary: &str) {
        let install_cmd = install_command_for(binary);
        self.clipboard.set(install_cmd.clone(), false);
        self.toast(format!(
            "{binary} not installed — `{install_cmd}` copied to clipboard"
        ));
    }

    /// Ask the tmnl host to fire one of *its* commands by id over the
    /// blit channel (`Message::RunHostCommand`). Used by
    /// `[[ui.integration_icon]]` chips whose `command` field uses the
    /// `tmnl:<id>` prefix — e.g. `tmnl:browser.attach_dashboard` so
    /// the left-rail Playwright-dashboard chip can ask tmnl to mount
    /// a Browser pane on the spawned dashboard URL.
    ///
    /// Toasts an explanation when mnml isn't a tmnl native client (the
    /// command would otherwise silently vanish).
    pub fn tmnl_run_host_command(&mut self, id: String) {
        if !self.under_tmnl {
            self.toast(format!(
                "tmnl:{id} — mnml isn't running under tmnl; \
                 this command only fires under the tmnl host"
            ));
            return;
        }
        self.pending_host_commands.push(id);
    }

    /// Pop the focused pty pane out of mnml into a new tmnl tab —
    /// the *hard* handoff. Sends `Message::OpenPaneTransfer` with the
    /// pty master fd attached via SCM_RIGHTS to tmnl's transfer
    /// socket (`$TMNL_TRANSFER_SOCKET`). tmnl wraps the fd in an
    /// adopted `ShellSession` and surfaces it as a new tab; mnml
    /// removes its pane (without killing the child — the released
    /// flag on `PtySession` makes its `Drop` skip the kill).
    ///
    /// No-op + toast when:
    ///   • The focused pane isn't a `Pane::Pty` (nothing to pop).
    ///   • `$TMNL_TRANSFER_SOCKET` is unset (mnml isn't under a tmnl
    ///     new enough to expose the receiver — or isn't under tmnl
    ///     at all).
    ///   • The pty master doesn't expose a raw fd (portable-pty's
    ///     non-Unix backends; never hit on mnml's macOS / Linux
    ///     targets, but defended for safety).
    ///   • Connecting / writing to the transfer socket fails.
    #[cfg(unix)]
    pub fn pop_pty_to_tmnl(&mut self) {
        use std::os::unix::net::UnixStream;
        use tmnl_protocol::{Message, send_message_with_fd};

        let Some(pane_id) = self.active else {
            self.toast(":tmnl.pop-pty — no focused pane");
            return;
        };
        let Some(crate::pane::Pane::Pty(session)) = self.panes.get(pane_id) else {
            self.toast(":tmnl.pop-pty — focused pane isn't a terminal");
            return;
        };
        let Ok(socket_path) = std::env::var("TMNL_TRANSFER_SOCKET") else {
            self.toast(
                ":tmnl.pop-pty — not running under tmnl \
                 (TMNL_TRANSFER_SOCKET unset)",
            );
            return;
        };
        let Some(raw_fd) = session.raw_master_fd() else {
            self.toast(":tmnl.pop-pty — pty has no transferable fd");
            return;
        };
        // Snapshot the parts we need before we go mutable; the borrow
        // checker doesn't let us hold `session` across `close_pane`.
        let command = session.profile.exe.clone();
        let args = session.profile.args.clone();

        let stream = match UnixStream::connect(&socket_path) {
            Ok(s) => s,
            Err(e) => {
                self.toast(format!(":tmnl.pop-pty — connect {socket_path}: {e}"));
                return;
            }
        };
        let msg = Message::OpenPaneTransfer { command, args };
        if let Err(e) = send_message_with_fd(&stream, &msg, Some(raw_fd)) {
            self.toast(format!(":tmnl.pop-pty — send: {e}"));
            return;
        }
        // SCM_RIGHTS duplicated the fd into tmnl's process — we can
        // safely release ours now. Mark released *before* close so the
        // Drop path skips `child.kill()`.
        if let Some(crate::pane::Pane::Pty(session)) = self.panes.get_mut(pane_id) {
            session.mark_released();
        }
        self.toast("tmnl: handed off to a new tab");
        self.close_pane(pane_id);
    }
}

/// Build an OS-appropriate install command for a missing terminal
/// tool. Used by [`App::launch_tool`] to surface a copy-pasteable
/// hint when the binary isn't on PATH.
///
/// macOS → `brew install <pkg>` (assumes Homebrew is in use; Mac
/// users without brew get the toast and copy the literal string).
/// Linux → tries to pick a package manager that exists on PATH, in
/// preference order: `apt-get` (Debian/Ubuntu — most common in our
/// sphere), `dnf` (Fedora/RHEL 8+), `pacman` (Arch). Falls back to
/// `apt-get` when nothing is detected. Linux commands are prefixed
/// with `sudo -A` so a configured `SUDO_ASKPASS` surfaces a GUI
/// prompt; without one the user sees the usual terminal prompt.
fn install_command_for(binary: &str) -> String {
    let pkg = package_name_for(binary);
    if cfg!(target_os = "macos") {
        return format!("brew install {pkg}");
    }
    if cfg!(target_os = "linux") {
        if which("apt-get") {
            return format!("sudo -A apt-get install -y {pkg}");
        }
        if which("dnf") {
            return format!("sudo -A dnf install -y {pkg}");
        }
        if which("pacman") {
            return format!("sudo -A pacman -S --noconfirm {pkg}");
        }
        // No detected package manager — best-effort default.
        return format!("sudo -A apt-get install -y {pkg}");
    }
    // Windows / BSDs etc. — surface the binary name and let the user
    // pick their installer.
    format!("install {pkg}")
}

/// Tiny `which`-style PATH probe. The `integration_detect` module has
/// one too, but it's tuned for sibling-binary lookups (per-OS
/// well-known install dirs); for `install_command_for` we only need
/// the cheap PATH walk.
fn which(name: &str) -> bool {
    let Ok(path) = std::env::var("PATH") else {
        return false;
    };
    path.split(':').any(|dir| {
        let p = std::path::Path::new(dir).join(name);
        p.is_file()
    })
}

/// Map a binary name to a package name for the target OS. Most are
/// 1:1; the few exceptions live here.
fn package_name_for(binary: &str) -> &str {
    // Today everything we surface is 1:1. Future entries (e.g.
    // `btm` → `bottom`, `kubectl` → varies) go here.
    binary
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Serialize tests that mutate `$TMNL_TRANSFER_SOCKET`. Rust's
    /// default test harness runs `#[test]` functions in parallel, so
    /// two tests reading + writing the same env var on different
    /// threads can interleave (one's `set_var` clobbers another's
    /// state mid-test). Lock + drop at function scope.
    #[cfg(unix)]
    fn env_lock() -> &'static std::sync::Mutex<()> {
        static M: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        M.get_or_init(|| std::sync::Mutex::new(()))
    }

    #[test]
    fn install_command_for_macos_uses_brew() {
        if cfg!(target_os = "macos") {
            assert_eq!(install_command_for("htop"), "brew install htop");
            assert_eq!(install_command_for("iftop"), "brew install iftop");
        }
    }

    #[test]
    fn install_command_for_linux_prefers_a_real_package_manager() {
        // On Linux this should yield something starting with `sudo -A`
        // since the helper always offers GUI/CLI prompt support. We
        // don't pin the specific PM since CI may have any combination.
        if cfg!(target_os = "linux") {
            let cmd = install_command_for("htop");
            assert!(
                cmd.starts_with("sudo -A "),
                "expected sudo-prefixed install command, got `{cmd}`"
            );
            assert!(cmd.contains("htop"));
        }
    }

    #[test]
    fn tmnl_open_tab_no_op_when_not_under_tmnl() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(!app.under_tmnl);
        app.tmnl_open_tab("claude".to_string(), Vec::new());
        // No pane request enqueued — the toast is the user-facing
        // signal but we can't assert on toasts here without more
        // plumbing; the pending vec stays empty.
        assert!(app.pending_open_panes.is_empty());
    }

    #[test]
    fn tmnl_open_tab_queues_when_under_tmnl() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.under_tmnl = true;
        app.tmnl_open_tab("claude".to_string(), vec!["--model".into(), "opus".into()]);
        assert_eq!(app.pending_open_panes.len(), 1);
        assert_eq!(app.pending_open_panes[0].0, "claude");
        assert_eq!(
            app.pending_open_panes[0].1,
            vec!["--model".to_string(), "opus".to_string()]
        );
    }

    #[test]
    fn tmnl_open_claude_convenience() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.under_tmnl = true;
        app.tmnl_open_claude_in_tab();
        assert_eq!(app.pending_open_panes[0].0, "claude");
        assert!(app.pending_open_panes[0].1.is_empty());
    }

    #[test]
    fn tmnl_run_host_command_no_op_when_not_under_tmnl() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(!app.under_tmnl);
        app.tmnl_run_host_command("browser.attach_dashboard".to_string());
        assert!(app.pending_host_commands.is_empty());
    }

    #[test]
    fn tmnl_run_host_command_queues_when_under_tmnl() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.under_tmnl = true;
        app.tmnl_run_host_command("browser.attach_dashboard".to_string());
        app.tmnl_run_host_command("split.browser_clipboard".to_string());
        assert_eq!(
            app.pending_host_commands,
            vec![
                "browser.attach_dashboard".to_string(),
                "split.browser_clipboard".to_string(),
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn pop_pty_no_focused_pty_is_a_no_op() {
        let _env_guard = env_lock().lock().unwrap();
        // No focused pane at all → toast + no panic. The shape of the
        // call is what we're asserting; toast contents are inspected
        // by the full-loop tests, not here.
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(app.active.is_none());
        // SAFETY: env_lock above serializes against the other tests
        // here that mutate this var; we own it for the duration.
        unsafe { std::env::set_var("TMNL_TRANSFER_SOCKET", "/tmp/unused-pop-pty-test.sock") };
        app.pop_pty_to_tmnl();
        // No panic, no state mutation past the toast.
        assert!(app.active.is_none());
    }

    /// End-to-end SCM_RIGHTS round-trip: spin up a real pty pane
    /// (the child is a `cat` so the pty is alive but quiet),
    /// listen on a temp transfer socket, fire `pop_pty_to_tmnl`,
    /// and assert that the receiver got an `OpenPaneTransfer` *with*
    /// an attached fd. Validates the whole sender side: connect,
    /// send_message_with_fd with the master fd, mark released, close
    /// the pane.
    #[cfg(unix)]
    #[test]
    fn pop_pty_transfers_master_fd_via_scm_rights() {
        let _env_guard = env_lock().lock().unwrap();
        use std::os::unix::io::FromRawFd;
        use std::os::unix::net::UnixListener;
        use std::sync::atomic::{AtomicU32, Ordering};
        use std::time::Duration;
        use tmnl_protocol::{Message, read_message_with_fd};

        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let socket_path = std::env::temp_dir().join(format!(
            "mnml-pop-pty-test-{}-{}.sock",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind");
        let (event_tx, event_rx) = std::sync::mpsc::channel::<(Message, bool)>();
        let listener_thread = std::thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() {
                if let Ok((msg, fd)) = read_message_with_fd(&stream) {
                    let _ = event_tx.send((msg, fd.is_some()));
                    if let Some(raw) = fd {
                        // SAFETY: read_message_with_fd hands us a raw
                        // fd that's freshly duplicated by the kernel —
                        // it's unique to this process. Wrapping +
                        // dropping closes it cleanly.
                        let _ = unsafe { std::os::unix::io::OwnedFd::from_raw_fd(raw) };
                    }
                }
            }
        });

        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        // Spawn a tiny pty pane running `cat` (quiet, doesn't exit).
        // Use an explicit BinaryProfile so `exe` is literally "cat"
        // (the convenience `BinaryProfile::task` wraps via `$SHELL -c`,
        // which would assert on the shell path instead).
        let profile = crate::pty_pane::BinaryProfile {
            label: "cat".to_string(),
            exe: "cat".to_string(),
            args: Vec::new(),
            cwd: Some(app.workspace.clone()),
            env: Vec::new(),
            session_id: None,
        };
        let session = crate::pty_pane::PtySession::spawn(profile, 24, 80).expect("spawn cat pty");
        let pane_id = app.panes.len();
        app.panes.push(crate::pane::Pane::Pty(session));
        app.active = Some(pane_id);

        // SAFETY: tests are sequential per env-var write; this thread
        // is the only writer.
        unsafe { std::env::set_var("TMNL_TRANSFER_SOCKET", &socket_path) };
        app.pop_pty_to_tmnl();

        let (msg, had_fd) = event_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("receiver got the handoff");
        listener_thread.join().expect("listener thread");
        let _ = std::fs::remove_file(&socket_path);

        match msg {
            Message::OpenPaneTransfer { command, args } => {
                assert_eq!(command, "cat");
                assert!(args.is_empty());
            }
            other => panic!("expected OpenPaneTransfer, got {other:?}"),
        }
        assert!(had_fd, "SCM_RIGHTS fd was not attached");
        // After a successful handoff the pane is removed.
        assert!(
            app.panes.get(pane_id).is_none()
                || !matches!(app.panes.get(pane_id), Some(crate::pane::Pane::Pty(_)))
        );
    }

    /// Verify that dropping a released `PtySession` does **not** kill
    /// the child process. A regression here would silently terminate
    /// the program the user just handed off to tmnl. Asserts via
    /// `kill -0 <pid>` which returns 0 when the process is alive.
    #[cfg(unix)]
    #[test]
    fn released_pty_drop_does_not_kill_child() {
        use crate::pty_pane::{BinaryProfile, PtySession};

        let profile = BinaryProfile {
            label: "cat".to_string(),
            exe: "cat".to_string(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            session_id: None,
        };
        let mut session = match PtySession::spawn(profile, 24, 80) {
            Ok(s) => s,
            Err(_) => return,
        };
        let pid = match session.child_pid_for_test() {
            Some(p) => p,
            None => return,
        };

        session.mark_released();
        drop(session);

        // Give the OS a moment to propagate any kill (if it happened).
        std::thread::sleep(std::time::Duration::from_millis(50));

        let status = std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .status()
            .expect("kill -0 invocation failed");
        assert!(
            status.success(),
            "child (pid {pid}) was killed by Drop despite released=true — \
             regression in PtySession::drop released guard"
        );
        // Clean up the surviving `cat`.
        let _ = std::process::Command::new("kill")
            .args([&pid.to_string()])
            .status();
    }

    /// `pop_pty_to_tmnl` no-ops when `TMNL_TRANSFER_SOCKET` is unset,
    /// even with a focused pty pane present. The existing
    /// `pop_pty_no_focused_pty_is_a_no_op` test sets the env var so it
    /// short-circuits at "no focused pane"; this one is its complement.
    #[cfg(unix)]
    #[test]
    fn pop_pty_socket_env_unset_is_a_no_op() {
        let _env_guard = env_lock().lock().unwrap();
        use crate::pty_pane::{BinaryProfile, PtySession};

        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let profile = BinaryProfile {
            label: "cat".to_string(),
            exe: "cat".to_string(),
            args: Vec::new(),
            cwd: Some(app.workspace.clone()),
            env: Vec::new(),
            session_id: None,
        };
        let session = match PtySession::spawn(profile, 24, 80) {
            Ok(s) => s,
            Err(_) => return,
        };
        let pane_id = app.panes.len();
        app.panes.push(crate::pane::Pane::Pty(session));
        app.active = Some(pane_id);

        let saved = std::env::var("TMNL_TRANSFER_SOCKET").ok();
        // SAFETY: tests are single-threaded at env-mutation; save+restore.
        unsafe { std::env::remove_var("TMNL_TRANSFER_SOCKET") };
        app.pop_pty_to_tmnl();
        if let Some(v) = saved {
            unsafe { std::env::set_var("TMNL_TRANSFER_SOCKET", v) };
        }

        assert!(
            matches!(app.panes.get(pane_id), Some(crate::pane::Pane::Pty(_))),
            "pty pane was removed despite TMNL_TRANSFER_SOCKET being unset"
        );
    }

    /// `pop_pty_to_tmnl` no-ops when the transfer socket env var
    /// points at a non-existent socket file.
    #[cfg(unix)]
    #[test]
    fn pop_pty_connect_failure_is_a_no_op() {
        let _env_guard = env_lock().lock().unwrap();
        use crate::pty_pane::{BinaryProfile, PtySession};

        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let profile = BinaryProfile {
            label: "cat".to_string(),
            exe: "cat".to_string(),
            args: Vec::new(),
            cwd: Some(app.workspace.clone()),
            env: Vec::new(),
            session_id: None,
        };
        let session = match PtySession::spawn(profile, 24, 80) {
            Ok(s) => s,
            Err(_) => return,
        };
        let pane_id = app.panes.len();
        app.panes.push(crate::pane::Pane::Pty(session));
        app.active = Some(pane_id);

        let bogus = d.path().join("no-such-transfer.sock");
        // SAFETY: see above.
        unsafe { std::env::set_var("TMNL_TRANSFER_SOCKET", &bogus) };
        app.pop_pty_to_tmnl();

        assert!(
            matches!(app.panes.get(pane_id), Some(crate::pane::Pane::Pty(_))),
            "pty pane was removed despite connect failing to {bogus:?}"
        );
    }
}
