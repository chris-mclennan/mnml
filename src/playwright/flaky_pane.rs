//! `Pane::Flaky` — the workspace's "flaky tests" dashboard. Lists every test
//! that's gone both ways across recent runs (per [`super::history::TestHistory`]),
//! with the most-recent outcome history shown as a mini bar (`✓✓✗✓✗`). Read-only;
//! `↑↓`/`jk` select, `Enter` jumps to the test in its source file, `r`
//! rebuilds from the current history. Built + refreshed by `App` so the data
//! lifecycle stays in one place.

use std::path::PathBuf;

use super::history::{HistOutcome, WobblyRow};

#[derive(Debug, Clone)]
pub struct FlakyItem {
    /// Absolute path to the spec file (workspace + the row's relative path).
    pub path: PathBuf,
    /// Workspace-relative spec file (for display).
    pub rel: String,
    pub title: String,
    pub line: u32,
    /// Most-recent-last outcomes for this test.
    pub outcomes: Vec<HistOutcome>,
}

pub struct FlakyPane {
    pub items: Vec<FlakyItem>,
    pub selected: usize,
    pub scroll: usize,
}

impl FlakyPane {
    /// Build from the rows the history surfaces; `resolve_path` turns each
    /// row's spec-file string into an absolute path (the caller knows the
    /// workspace + how Playwright reports relative paths).
    pub fn build(rows: Vec<WobblyRow>, resolve_path: impl Fn(&str) -> PathBuf) -> Self {
        let items: Vec<FlakyItem> = rows
            .into_iter()
            .map(|w| FlakyItem {
                path: resolve_path(&w.file),
                rel: w.file,
                title: w.title,
                line: w.line,
                outcomes: w.outcomes,
            })
            .collect();
        FlakyPane {
            items,
            selected: 0,
            scroll: 0,
        }
    }

    pub fn tab_title(&self) -> String {
        match self.items.len() {
            0 => "flaky ✓".to_string(),
            n => format!("flaky ≋{n}"),
        }
    }

    pub fn clamp(&mut self) {
        if self.items.is_empty() {
            self.selected = 0;
        } else if self.selected >= self.items.len() {
            self.selected = self.items.len() - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        if self.items.is_empty() {
            return;
        }
        let n = self.items.len() as isize;
        self.selected = (self.selected as isize + delta).clamp(0, n - 1) as usize;
    }

    pub fn selected_item(&self) -> Option<&FlakyItem> {
        self.items.get(self.selected)
    }
}

/// Render an outcome list as a compact glyph bar — `✓` = pass, `✗` = fail,
/// `~` = playwright's per-run "flaky" marker.
pub fn outcomes_glyphs(outcomes: &[HistOutcome]) -> String {
    outcomes
        .iter()
        .map(|o| match o {
            HistOutcome::Pass => '✓',
            HistOutcome::Fail => '✗',
            HistOutcome::Flaky => '~',
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(file: &str, title: &str, line: u32, outcomes: Vec<HistOutcome>) -> WobblyRow {
        WobblyRow {
            file: file.into(),
            suite_path: "S".into(),
            title: title.into(),
            outcomes,
            line,
        }
    }

    #[test]
    fn builds_items_with_resolved_path() {
        let rows = vec![
            row(
                "tests/a.spec.ts",
                "alpha",
                10,
                vec![HistOutcome::Pass, HistOutcome::Fail],
            ),
            row(
                "tests/b.spec.ts",
                "beta",
                5,
                vec![HistOutcome::Fail, HistOutcome::Pass],
            ),
        ];
        let p = FlakyPane::build(rows, |s| PathBuf::from("/ws").join(s));
        assert_eq!(p.items.len(), 2);
        assert_eq!(p.items[0].path, PathBuf::from("/ws/tests/a.spec.ts"));
        assert_eq!(p.items[0].title, "alpha");
        assert_eq!(p.items[0].line, 10);
        assert_eq!(p.tab_title(), "flaky ≋2");
    }

    #[test]
    fn glyphs_map_outcomes_to_chars() {
        assert_eq!(
            outcomes_glyphs(&[HistOutcome::Pass, HistOutcome::Fail, HistOutcome::Flaky]),
            "✓✗~"
        );
        assert_eq!(outcomes_glyphs(&[]), "");
    }
}
