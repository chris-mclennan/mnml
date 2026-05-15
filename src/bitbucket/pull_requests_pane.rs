//! `Pane::BitbucketPullRequests` state — same minimal shape as the
//! pipelines pane (selection + scroll only; data lives in
//! `App.bitbucket_pull_requests`).

#[derive(Debug, Default)]
pub struct BitbucketPullRequestsPane {
    pub selected: usize,
    pub scroll: usize,
}

impl BitbucketPullRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "Bitbucket PRs".to_string()
    }
    pub fn move_selection(&mut self, delta: i64, max_idx: usize) {
        if max_idx == 0 {
            self.selected = 0;
            return;
        }
        let max = (max_idx - 1) as i64;
        let next = (self.selected as i64 + delta).clamp(0, max) as usize;
        self.selected = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn move_selection_clamps() {
        let mut p = BitbucketPullRequestsPane::new();
        p.move_selection(5, 3);
        assert_eq!(p.selected, 2);
        p.move_selection(-100, 3);
        assert_eq!(p.selected, 0);
    }
}
