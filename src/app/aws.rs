//! AWS feature App-level glue — openers + drain methods for
//! `Pane::CodeBuilds` (`aws codebuild list-builds-for-project`) and
//! `Pane::LogTail` (`aws logs tail --follow`). Behind the
//! `aws-codebuild` Cargo feature.
//!
//! Shells out to the `aws` CLI (no SDK), so the build configuration is
//! the user's existing AWS credentials / SSO session — same as a
//! manual `aws codebuild …` call. Project + log-group names come
//! from `[ci] project = "…"` and `[ci] region = "…"` in the user's
//! workspace config.

#![cfg(feature = "aws-codebuild")]

use super::*;

/// Single-quote a string for safe interpolation into a shell command
/// (the embedded pty's bash). Wraps in `'…'`; any inner `'` is
/// escaped as `'\''` per POSIX-shell rules.
pub(crate) fn single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

impl App {
    /// Open the AWS CodeBuild builds-list pane for the project configured
    /// in `[ci] project = "…"`. Re-focuses an existing pane if open;
    /// otherwise spawns a refresh worker and splits a new pane in below
    /// the focused leaf.
    pub fn open_codebuilds_pane(&mut self) {
        let project = match self.config.ci.project.clone() {
            Some(p) => p,
            None => {
                self.toast("aws: configure [ci] project = \"…\" first");
                return;
            }
        };
        // Re-focus existing pane (refresh worker may still be pumping).
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::CodeBuilds(_)))
        {
            // Re-fire the refresh so `r` isn't the only way to get fresh data.
            let rx =
                crate::aws::codebuild::spawn_refresh(project, self.config.ci.region.clone());
            if let Some(Pane::CodeBuilds(p)) = self.panes.get_mut(id) {
                p.pending = Some(rx);
                p.loading = true;
            }
            self.reveal_pane(id);
            return;
        }
        let rx = crate::aws::codebuild::spawn_refresh(project, self.config.ci.region.clone());
        let pane = Pane::CodeBuilds(crate::aws::codebuilds_pane::CodeBuildsPane::new(rx));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
        self.toast("aws: CodeBuild builds (loading…)");
    }

    /// Re-fire the CodeBuild refresh worker for the active builds pane.
    pub fn refresh_active_codebuilds(&mut self) {
        let project = match self.config.ci.project.clone() {
            Some(p) => p,
            None => return,
        };
        let region = self.config.ci.region.clone();
        let Some(id) = self.active else { return };
        let rx = crate::aws::codebuild::spawn_refresh(project, region);
        if let Some(Pane::CodeBuilds(p)) = self.panes.get_mut(id) {
            p.pending = Some(rx);
            p.loading = true;
        }
    }

    /// `Enter` on the selected build → open the CloudWatch deep-link in
    /// the OS default browser. `y` copies the same URL to the clipboard.
    pub fn open_selected_codebuild_url(&mut self) {
        let url_opt = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::CodeBuilds(cb) => cb.selected_record(),
                _ => None,
            })
            .and_then(|r| r.logs_deep_link.clone());
        let Some(url) = url_opt else {
            self.toast("no logs URL for this build");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened build logs in browser");
    }

    /// `T` on the selected build → tail logs in a dedicated `Pane::LogTail`
    /// with per-line severity coloring. Sibling to the pty-based
    /// [`Self::tail_selected_codebuild_logs`] — same `aws logs tail
    /// --follow` data source, different rendering.
    pub fn tail_selected_codebuild_logs_classified(&mut self) {
        let logs_info = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::CodeBuilds(cb) => cb.selected_record(),
                _ => None,
            })
            .and_then(|r| Some((r.logs_group.clone()?, r.logs_stream.clone()?)));
        let Some((group, stream)) = logs_info else {
            self.toast("no logs group/stream for this build");
            return;
        };
        let region = self.config.ci.region.clone();
        let cwd = self.workspace.clone();
        // Drop any previous tail before starting a new one (single-stream
        // model — the channel is shared, so two tails would interleave).
        if let Some(prev_pid) = self.log_tail_pane_id.take() {
            self.close_pane(prev_pid);
        }
        self.log_tail_chan = None;
        match crate::aws::log_tail_pane::LogTailPane::spawn(group, stream, region, cwd) {
            Ok((pane, rx)) => {
                self.log_tail_chan = Some(rx);
                let pid = self.split_leaf_with(
                    self.active.unwrap_or(0),
                    crate::layout::SplitDir::Horizontal,
                    Pane::LogTail(pane),
                );
                self.active = Some(pid);
                self.log_tail_pane_id = Some(pid);
                self.focus = Focus::Pane;
                self.toast("tailing logs (colored) — Ctrl+W closes");
            }
            Err(e) => {
                self.toast(format!("log tail failed: {e}"));
            }
        }
    }

    /// Drain the LogTail channel into the active `Pane::LogTail`. Called
    /// by `App::tick`. No-op when no tail is running.
    pub fn drain_log_tail_events(&mut self) {
        let Some(rx) = &self.log_tail_chan else {
            return;
        };
        let mut batch: Vec<crate::aws::log_tail_pane::LogTailEvent> = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            batch.push(ev);
        }
        if batch.is_empty() {
            return;
        }
        let Some(pid) = self.log_tail_pane_id else {
            return;
        };
        for ev in batch {
            use crate::aws::log_tail_pane::LogTailEvent;
            match ev {
                LogTailEvent::Line(text) => {
                    if let Some(Pane::LogTail(p)) = self.panes.get_mut(pid) {
                        p.push_line(text);
                    }
                }
                LogTailEvent::Exited(_) => {
                    // The pane's `exited` Arc is already flipped by the
                    // reader thread; just toast.
                    self.toast("log tail: process exited");
                }
                LogTailEvent::Failed(msg) => {
                    self.toast(format!(
                        "log tail error: {}",
                        msg.lines().next().unwrap_or("")
                    ));
                }
            }
        }
    }

    /// `t` on the selected build → live-tail its CloudWatch logs in a pty
    /// pane (`aws logs tail --follow`). Each invocation opens a new tail
    /// pane; close with `Ctrl+W`.
    pub fn tail_selected_codebuild_logs(&mut self) {
        let logs_info = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::CodeBuilds(cb) => cb.selected_record(),
                _ => None,
            })
            .and_then(|r| Some((r.logs_group.clone()?, r.logs_stream.clone()?)));
        let Some((group, stream)) = logs_info else {
            self.toast("no logs group/stream for this build");
            return;
        };
        let region_flag = self
            .config
            .ci
            .region
            .as_deref()
            .map(|r| format!(" --region {}", single_quote(r)))
            .unwrap_or_default();
        let cmd = format!(
            "aws logs tail --follow --log-group-name {} --log-stream-names {}{}",
            single_quote(&group),
            single_quote(&stream),
            region_flag
        );
        let title = format!("logs · {}", &stream[..stream.len().min(8)]);
        let profile = crate::pty_pane::BinaryProfile::task(&title, &cmd, self.workspace.clone());
        self.open_pty(profile);
        self.toast("tailing build logs (Ctrl+W to close)");
    }

    /// `y` on the selected build → copy the CloudWatch deep-link.
    pub fn copy_selected_codebuild_url(&mut self) {
        let url_opt = self
            .active
            .and_then(|i| self.panes.get(i))
            .and_then(|p| match p {
                Pane::CodeBuilds(cb) => cb.selected_record(),
                _ => None,
            })
            .and_then(|r| r.logs_deep_link.clone());
        let Some(url) = url_opt else {
            self.toast("no logs URL for this build");
            return;
        };
        self.clipboard.set(url, false);
        self.toast("copied logs URL");
    }

    /// Drain pending CodeBuild refresh channels into every open
    /// `Pane::CodeBuilds`. Cheap when channels are idle.
    pub(super) fn drain_codebuild_events(&mut self) {
        for pane in self.panes.iter_mut() {
            if let Pane::CodeBuilds(p) = pane {
                p.drain_pending();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_quote_wraps_no_quotes() {
        assert_eq!(single_quote("plain"), "'plain'");
    }

    #[test]
    fn single_quote_handles_interior_quotes() {
        // POSIX: end the literal, escape one ', re-open.
        assert_eq!(single_quote("a'b"), "'a'\\''b'");
    }

    #[test]
    fn single_quote_empty_string() {
        assert_eq!(single_quote(""), "''");
    }
}
