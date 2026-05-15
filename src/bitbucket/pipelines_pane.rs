//! `Pane::BitbucketPipelines` state — minimal: selection + scroll. The
//! actual pipeline data lives on `App.bitbucket_pipelines` (filled by the
//! shared worker thread, drained per-tick), so the pane is stateless beyond
//! "where the user is in the list" and "is the user looking at this".
//!
//! The flattened list is computed at render time from
//! `App.config.bitbucket.repos` × `App.bitbucket_pipelines` — keeps the
//! pane robust against repos being added/removed at runtime via `:source`.

#[derive(Debug, Default)]
pub struct BitbucketPipelinesPane {
    /// Index into the *flattened* list of pipelines (across every configured
    /// repo, in config order, newest-first within each repo). Header rows
    /// don't count — see `is_data_row` in the view.
    pub selected: usize,
    pub scroll: usize,
}

impl BitbucketPipelinesPane {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn tab_title(&self) -> String {
        "Bitbucket".to_string()
    }

    /// Move the selection by `delta` items, clamped to `[0, max_idx)`.
    /// A `max_idx` of `0` is a no-op (empty list — nothing to select).
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
    fn move_selection_clamps_to_max() {
        let mut p = BitbucketPipelinesPane::new();
        p.move_selection(1, 3);
        assert_eq!(p.selected, 1);
        p.move_selection(100, 3);
        assert_eq!(p.selected, 2);
        p.move_selection(-100, 3);
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn move_selection_noop_on_empty() {
        let mut p = BitbucketPipelinesPane::new();
        p.move_selection(5, 0);
        assert_eq!(p.selected, 0);
        // Once items exist, selection should land at 0 not stay invalid.
        p.move_selection(10, 1);
        assert_eq!(p.selected, 0);
    }
}
