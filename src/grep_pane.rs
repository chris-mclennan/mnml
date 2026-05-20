//! `Pane::Grep` — workspace-grep results as a browsable list. The grep itself
//! is shelled out by `App::run_workspace_grep` (`rg --vimgrep`, falling back to
//! `git grep -n --column`); the parser + the pane state live here so they're
//! cheap to unit-test. `↑↓`/`jk` select, `Enter` jumps to the hit's file +
//! line, `r` re-runs the query, `Esc` → tree. Unlike the `Locations` picker
//! (which closes on Enter), the pane stays open — "jump and keep the list".

use std::path::{Path, PathBuf};

/// One match the workspace-grep tool produced.
#[derive(Debug, Clone)]
pub struct GrepHit {
    pub path: PathBuf,
    /// Workspace-relative path (what the grep tool emitted).
    pub rel: String,
    /// 0-based line/column of the match.
    pub line: u32,
    pub col: u32,
    /// The matched line, trim-left-trimmed for display.
    pub text: String,
}

pub struct GrepPane {
    pub query: String,
    /// Which tool produced these — drives the title and the `r` re-run.
    pub used: &'static str,
    pub hits: Vec<GrepHit>,
    pub selected: usize,
    pub scroll: usize,
    /// Hit indices the user has toggled off — they're skipped when
    /// `R` (replace) fires. Empty set ⇒ replace applies to every hit
    /// (back-compat with the original behavior). Sibling to Space-to-
    /// toggle in the pane key handler.
    pub disabled: std::collections::HashSet<usize>,
}

impl GrepPane {
    pub fn new(query: String, used: &'static str, hits: Vec<GrepHit>) -> Self {
        GrepPane {
            query,
            used,
            hits,
            selected: 0,
            scroll: 0,
            disabled: std::collections::HashSet::new(),
        }
    }

    /// Flip the enabled/disabled state of the currently-selected hit.
    /// Used by Space in the pane and by checkbox clicks.
    pub fn toggle_selected(&mut self) {
        if self.disabled.contains(&self.selected) {
            self.disabled.remove(&self.selected);
        } else {
            self.disabled.insert(self.selected);
        }
    }

    /// Toggle a specific hit by index (mouse click on the checkbox).
    pub fn toggle_hit(&mut self, idx: usize) {
        if idx >= self.hits.len() {
            return;
        }
        if self.disabled.contains(&idx) {
            self.disabled.remove(&idx);
        } else {
            self.disabled.insert(idx);
        }
    }

    /// Re-enable every hit.
    pub fn enable_all(&mut self) {
        self.disabled.clear();
    }

    /// Disable every hit (so the user can re-enable just the ones they want).
    pub fn disable_all(&mut self) {
        self.disabled = (0..self.hits.len()).collect();
    }

    /// Number of hits the user has marked active (enabled). When `disabled`
    /// is empty this equals `hits.len()`.
    pub fn enabled_count(&self) -> usize {
        self.hits.len().saturating_sub(self.disabled.len())
    }

    pub fn tab_title(&self) -> String {
        let n = self.hits.len();
        let q = if self.query.chars().count() > 24 {
            let truncated: String = self.query.chars().take(24).collect();
            format!("{truncated}…")
        } else {
            self.query.clone()
        };
        format!("grep:{q} ({n})")
    }

    /// Keep `selected` in range after a rebuild.
    pub fn clamp(&mut self) {
        if self.hits.is_empty() {
            self.selected = 0;
        } else if self.selected >= self.hits.len() {
            self.selected = self.hits.len() - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        if self.hits.is_empty() {
            return;
        }
        let n = self.hits.len() as isize;
        self.selected = (self.selected as isize + delta).clamp(0, n - 1) as usize;
    }

    pub fn selected_hit(&self) -> Option<&GrepHit> {
        self.hits.get(self.selected)
    }
}

/// Parse `rg --vimgrep` / `git grep -n --column` output (both share the
/// `path:line:col:text` shape) into `GrepHit`s, resolved against `workspace`.
/// 1-based on the wire; the hits store 0-based line/col so the editor's
/// `place_cursor(row, col)` accepts them directly. Lines that don't parse are
/// skipped; output is capped at 2000 hits.
pub fn parse_rg_vimgrep(stdout: &str, workspace: &Path) -> Vec<GrepHit> {
    let mut out = Vec::new();
    for line in stdout.lines().take(2000) {
        let mut it = line.splitn(4, ':');
        let (Some(rel), Some(ln), Some(col), Some(text)) =
            (it.next(), it.next(), it.next(), it.next())
        else {
            continue;
        };
        let (Ok(ln), Ok(col)) = (ln.parse::<u32>(), col.parse::<u32>()) else {
            continue;
        };
        out.push(GrepHit {
            path: workspace.join(rel),
            rel: rel.to_string(),
            line: ln.saturating_sub(1),
            col: col.saturating_sub(1),
            text: text.trim_start().to_string(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vimgrep_lines() {
        let ws = Path::new("/ws");
        let out = parse_rg_vimgrep(
            "src/app.rs:42:5:    let x = 1;\nsrc/lib.rs:10:1:fn foo() {}\n",
            ws,
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].rel, "src/app.rs");
        assert_eq!(out[0].path, ws.join("src/app.rs"));
        assert_eq!(out[0].line, 41);
        assert_eq!(out[0].col, 4);
        assert_eq!(out[0].text, "let x = 1;");
        assert_eq!(out[1].rel, "src/lib.rs");
        assert_eq!(out[1].line, 9);
        assert_eq!(out[1].col, 0);
    }

    #[test]
    fn text_may_contain_colons() {
        // The `text` chunk is whatever's left after the first three `:`s.
        let out = parse_rg_vimgrep("a.rs:1:1:url: https://x.com:8080/p\n", Path::new("/ws"));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].text, "url: https://x.com:8080/p");
    }

    #[test]
    fn malformed_lines_skipped() {
        let out = parse_rg_vimgrep("not vimgrep\nfoo:nan:1:t\nsrc:5:7:ok\n", Path::new("/ws"));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rel, "src");
        assert_eq!(out[0].text, "ok");
    }

    #[test]
    fn move_selection_clamps() {
        let mut p = GrepPane::new(
            "x".into(),
            "rg",
            vec![
                GrepHit {
                    path: PathBuf::from("/a"),
                    rel: "a".into(),
                    line: 0,
                    col: 0,
                    text: "a".into(),
                },
                GrepHit {
                    path: PathBuf::from("/b"),
                    rel: "b".into(),
                    line: 0,
                    col: 0,
                    text: "b".into(),
                },
            ],
        );
        p.move_selection(-5);
        assert_eq!(p.selected, 0);
        p.move_selection(99);
        assert_eq!(p.selected, 1);
    }

    #[test]
    fn tab_title_includes_count_and_truncates_query() {
        let p = GrepPane::new("hello".into(), "rg", Vec::new());
        assert_eq!(p.tab_title(), "grep:hello (0)");
        let long = "x".repeat(40);
        let p = GrepPane::new(long, "rg", Vec::new());
        // 24 chars + `…` (the truncation marker) + " (0)"
        assert!(p.tab_title().contains('…'));
    }
}
