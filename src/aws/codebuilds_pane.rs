//! `Pane::CodeBuilds` payload — list of recent AWS CodeBuild builds for
//! the configured project. Refreshes async via [`super::codebuild::spawn_refresh`].

use std::sync::mpsc::Receiver;

use super::codebuild::{CodeBuildEvent, CodeBuildRecord};

#[derive(Debug, Default)]
pub struct CodeBuildsPane {
    pub items: Vec<CodeBuildRecord>,
    pub selected: usize,
    pub scroll: usize,
    pub loading: bool,
    pub last_error: Option<String>,
    /// Active refresh worker. `Some` from `spawn_refresh` time until the
    /// first event lands; then taken + cleared.
    pub pending: Option<Receiver<CodeBuildEvent>>,
}

impl CodeBuildsPane {
    pub fn new(pending: Receiver<CodeBuildEvent>) -> Self {
        Self {
            loading: true,
            pending: Some(pending),
            ..Default::default()
        }
    }

    pub fn tab_title(&self) -> String {
        if self.loading && self.items.is_empty() {
            "CodeBuild · loading…".to_string()
        } else {
            format!("CodeBuild · {}", self.items.len())
        }
    }

    pub fn move_selection(&mut self, delta: i64) {
        if self.items.is_empty() {
            return;
        }
        let n = self.items.len() as i64;
        let next = (self.selected as i64 + delta).clamp(0, n - 1) as usize;
        self.selected = next;
    }

    pub fn selected_record(&self) -> Option<&CodeBuildRecord> {
        self.items.get(self.selected)
    }

    /// Drain the pending refresh's channel into `items`. Called from
    /// `App::tick`. Returns `true` if any state changed.
    pub fn drain_pending(&mut self) -> bool {
        // Take the receiver out so the match arms can re-assign `pending`
        // without overlapping the borrow.
        let Some(rx) = self.pending.take() else {
            return false;
        };
        let mut updated = false;
        let mut done = false;
        loop {
            match rx.try_recv() {
                Ok(CodeBuildEvent::Builds(builds)) => {
                    updated = true;
                    let prior_selected_id = self.selected_record().map(|r| r.id.clone());
                    self.items = builds;
                    self.last_error = None;
                    self.loading = false;
                    if let Some(id) = prior_selected_id
                        && let Some(pos) = self.items.iter().position(|r| r.id == id)
                    {
                        self.selected = pos;
                    }
                    if self.selected >= self.items.len() {
                        self.selected = self.items.len().saturating_sub(1);
                    }
                    done = true;
                }
                Ok(CodeBuildEvent::Failed(msg)) => {
                    updated = true;
                    self.last_error = Some(msg);
                    self.loading = false;
                    done = true;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    done = true;
                    break;
                }
            }
        }
        if !done {
            // Worker still alive but hasn't emitted yet — put the receiver back.
            self.pending = Some(rx);
        }
        updated
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aws::codebuild::BuildStatus;

    fn record(id: &str, n: u64) -> CodeBuildRecord {
        CodeBuildRecord {
            id: id.to_string(),
            build_number: n,
            status: BuildStatus::Succeeded,
            started_at_ms: Some(n as i64 * 1000),
            duration_ms: Some(30_000),
            source_version: None,
            initiator: None,
            logs_deep_link: None,
            logs_group: None,
            logs_stream: None,
        }
    }

    #[test]
    fn move_selection_clamps() {
        let (_, rx) = std::sync::mpsc::channel();
        let mut p = CodeBuildsPane::new(rx);
        p.items = vec![record("a", 1), record("b", 2), record("c", 3)];
        p.move_selection(1);
        assert_eq!(p.selected, 1);
        p.move_selection(100);
        assert_eq!(p.selected, 2);
        p.move_selection(-100);
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn move_selection_noop_on_empty() {
        let (_, rx) = std::sync::mpsc::channel();
        let mut p = CodeBuildsPane::new(rx);
        p.move_selection(1);
        assert_eq!(p.selected, 0);
    }
}
