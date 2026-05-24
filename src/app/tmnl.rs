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
//! pane into a new tmnl tab via `SCM_RIGHTS` fd-passing — needs new
//! tmnl-protocol messages + a fair bit of unsafe Unix. Left as future
//! work (task #36's "(3)").

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
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
