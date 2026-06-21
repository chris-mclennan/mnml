//! `Pane::Diagnostics` — a workspace-wide "Problems" list: every LSP diagnostic
//! currently held on an open editor buffer, flattened into one navigable list
//! (errors first, then by file/line). Read-only; `↑↓`/`jk` select, `Enter`
//! jumps, `r` refreshes from the buffers. Built + refreshed by `App` from the
//! `Pane::Editor` buffers' `.diagnostics`.

use std::path::PathBuf;

use crate::lsp::{Diagnostic, Severity};

/// One row in the diagnostics list.
#[derive(Debug, Clone)]
pub struct DiagItem {
    pub path: PathBuf,
    /// Workspace-relative display path.
    pub rel: String,
    /// 0-based line/column of the diagnostic's start.
    pub line: u32,
    pub col: u32,
    pub severity: Severity,
    /// First non-empty line of the message, trimmed.
    pub message: String,
    pub source: Option<String>,
}

pub struct DiagnosticsPane {
    pub items: Vec<DiagItem>,
    pub selected: usize,
    /// Top rendered row.
    pub scroll: usize,
    /// Minimum severity shown in the list. `Hint` = all. Cycled by
    /// `s` chord. Errors-only mode is the common "ship this PR"
    /// view; full mode is for housekeeping. 2026-06-21.
    pub min_severity: Severity,
}

fn sev_rank(s: Severity) -> u8 {
    match s {
        Severity::Error => 0,
        Severity::Warning => 1,
        Severity::Info => 2,
        Severity::Hint => 3,
    }
}

impl DiagnosticsPane {
    /// Build from `(path, rel, &diagnostics)` triples — one per open editor buffer.
    pub fn build<'a>(
        sources: impl IntoIterator<Item = (PathBuf, String, &'a [Diagnostic])>,
    ) -> Self {
        let mut items: Vec<DiagItem> = Vec::new();
        for (path, rel, diags) in sources {
            for d in diags {
                let message = d
                    .message
                    .lines()
                    .map(str::trim)
                    .find(|l| !l.is_empty())
                    .unwrap_or("")
                    .to_string();
                items.push(DiagItem {
                    path: path.clone(),
                    rel: rel.clone(),
                    line: d.range.start.line,
                    col: d.range.start.character,
                    severity: d.severity,
                    message,
                    source: d.source.clone(),
                });
            }
        }
        items.sort_by(|a, b| {
            sev_rank(a.severity)
                .cmp(&sev_rank(b.severity))
                .then_with(|| a.rel.cmp(&b.rel))
                .then_with(|| a.line.cmp(&b.line))
                .then_with(|| a.col.cmp(&b.col))
        });
        DiagnosticsPane {
            items,
            selected: 0,
            scroll: 0,
            min_severity: Severity::Hint,
        }
    }

    /// Items that pass the current severity filter.
    pub fn visible(&self) -> Vec<&DiagItem> {
        let cap = sev_rank(self.min_severity);
        self.items
            .iter()
            .filter(|it| sev_rank(it.severity) <= cap)
            .collect()
    }

    /// Indices into `self.items` for rows that pass the current
    /// severity filter (parallel to `visible()`). Used by the
    /// renderer + click handler so flat_idx ↔ items index stays
    /// consistent.
    pub fn visible_indices(&self) -> Vec<usize> {
        let cap = sev_rank(self.min_severity);
        self.items
            .iter()
            .enumerate()
            .filter(|(_, it)| sev_rank(it.severity) <= cap)
            .map(|(i, _)| i)
            .collect()
    }

    /// Severity-filter label for the title bar.
    pub fn severity_label(&self) -> &'static str {
        match self.min_severity {
            Severity::Error => "errors only",
            Severity::Warning => "errors + warnings",
            Severity::Info => "errors + warnings + info",
            Severity::Hint => "all",
        }
    }

    /// `s` chord — cycle errors-only ↔ errors+warnings ↔ all.
    pub fn cycle_severity_filter(&mut self) {
        self.min_severity = match self.min_severity {
            Severity::Hint => Severity::Error,
            Severity::Error => Severity::Warning,
            Severity::Warning => Severity::Info,
            Severity::Info => Severity::Hint,
        };
        self.selected = 0;
        self.scroll = 0;
    }

    /// `(errors, warnings)` counts.
    pub fn counts(&self) -> (usize, usize) {
        let errors = self
            .items
            .iter()
            .filter(|i| i.severity == Severity::Error)
            .count();
        let warnings = self
            .items
            .iter()
            .filter(|i| i.severity == Severity::Warning)
            .count();
        (errors, warnings)
    }

    pub fn tab_title(&self) -> String {
        let (e, w) = self.counts();
        match (e, w) {
            (0, 0) => "problems ✓".to_string(),
            (e, 0) => format!("problems ✗{e}"),
            (0, w) => format!("problems ⚠{w}"),
            (e, w) => format!("problems ✗{e} ⚠{w}"),
        }
    }

    /// Keep `selected` in range after a rebuild.
    pub fn clamp(&mut self) {
        if self.items.is_empty() {
            self.selected = 0;
        } else if self.selected >= self.items.len() {
            self.selected = self.items.len() - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        let n = self.visible_indices().len();
        if n == 0 {
            return;
        }
        self.selected = (self.selected as isize + delta).clamp(0, n as isize - 1) as usize;
    }

    pub fn selected_item(&self) -> Option<&DiagItem> {
        let vis = self.visible_indices();
        vis.get(self.selected).and_then(|&i| self.items.get(i))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lsp::{Pos, Range};

    fn diag(line: u32, sev: Severity, msg: &str) -> Diagnostic {
        Diagnostic {
            range: Range {
                start: Pos { line, character: 0 },
                end: Pos { line, character: 1 },
            },
            severity: sev,
            message: msg.to_string(),
            source: None,
        }
    }

    #[test]
    fn build_sorts_errors_first_then_file_then_line() {
        let a = [
            diag(10, Severity::Warning, "w"),
            diag(2, Severity::Error, "e"),
        ];
        let b = [diag(5, Severity::Error, "e2")];
        let p = DiagnosticsPane::build(vec![
            (PathBuf::from("/x/b.rs"), "b.rs".into(), a.as_slice()),
            (PathBuf::from("/x/a.rs"), "a.rs".into(), b.as_slice()),
        ]);
        assert_eq!(p.items.len(), 3);
        // errors first, ordered by rel path
        assert_eq!(p.items[0].rel, "a.rs");
        assert_eq!(p.items[0].severity, Severity::Error);
        assert_eq!(p.items[1].rel, "b.rs");
        assert_eq!(p.items[1].severity, Severity::Error);
        // then the warning
        assert_eq!(p.items[2].severity, Severity::Warning);
        assert_eq!(p.counts(), (2, 1));
    }

    #[test]
    fn move_selection_clamps() {
        let a = [diag(1, Severity::Error, "e")];
        let mut p = DiagnosticsPane::build(vec![(PathBuf::from("/x"), "x".into(), a.as_slice())]);
        p.move_selection(-5);
        assert_eq!(p.selected, 0);
        p.move_selection(99);
        assert_eq!(p.selected, 0);
    }
}
