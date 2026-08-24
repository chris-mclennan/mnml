//! Neo-tree-style vertical connector prefixes for the workspace
//! file tree.
//!
//! R16 (2026-08-24) — user pointed at neo-tree.nvim's look: just
//! continuous vertical guide lines at each ancestor level. No
//! horizontal ├─ / └─ elbows into individual rows — the rows
//! themselves already break the visual pattern via their icons,
//! so the elbow adds noise rather than clarity.
//!
//! Given a DFS-ordered flat list of rows with `depth`, emit per
//! row a prefix of exactly `2 * depth` cells. For each ancestor
//! level `level` in `0..depth`: draw `│ ` when that ancestor's
//! subtree still has more siblings coming below this row (the
//! line continues down), else `  `. The self-level cell
//! (`level == depth - 1`) is `│ ` on every row of a sibling
//! group except the last, which gets `  ` — same rule.
//!
//! Sibling detection is DFS-flat: for row `i` at level `l`,
//! walk forward — a row at exactly `l` seen before any row at
//! depth `< l` means another sibling is coming.

use crate::tree::VisibleRow;

const CONT_NERD: &str = "\u{2502} "; // │
const SPACES: &str = "  ";
const CONT_ASCII: &str = "| ";

/// One prefix per row. Width per prefix == `2 * row.depth`.
pub fn compute_prefixes(rows: &[VisibleRow], ascii: bool) -> Vec<String> {
    let cont = if ascii { CONT_ASCII } else { CONT_NERD };

    let mut out = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        let d = row.depth;
        if d == 0 {
            out.push(String::new());
            continue;
        }
        let mut prefix = String::with_capacity(2 * d);
        // Draw a continuation bar at every level whose subtree
        // still has a later sibling below this row; a plain
        // indent otherwise. `level` here is 1-based (level 1 =
        // depth-1 ancestor); we probe `has_later_sibling` for
        // that level's own depth.
        for level in 1..=d {
            if has_later_sibling(rows, i, level) {
                prefix.push_str(cont);
            } else {
                prefix.push_str(SPACES);
            }
        }
        out.push(prefix);
    }
    out
}

fn has_later_sibling(rows: &[VisibleRow], from_idx: usize, level: usize) -> bool {
    for r in rows.iter().skip(from_idx + 1) {
        if r.depth < level {
            return false;
        }
        if r.depth == level {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn row(depth: usize, name: &str) -> VisibleRow {
        VisibleRow {
            path: PathBuf::from(name),
            is_dir: false,
            is_expanded: false,
            depth,
            name: name.to_string(),
        }
    }

    #[test]
    fn empty_prefix_at_root() {
        let rows = vec![row(0, "a"), row(0, "b")];
        assert_eq!(compute_prefixes(&rows, false), vec!["", ""]);
    }

    #[test]
    fn only_child_gets_plain_indent() {
        let rows = vec![row(0, "parent"), row(1, "only")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "  "); // no later sibling at level 1
    }

    #[test]
    fn more_siblings_at_same_depth_draw_bars() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "second")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{2502} "); // │  — sibling still coming
        assert_eq!(out[2], "  "); // last of its group
    }

    #[test]
    fn continuation_from_uncle_still_coming() {
        let rows = vec![row(0, "parent-a"), row(1, "child"), row(0, "parent-b")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "  ");
    }

    #[test]
    fn deep_prefix_width_matches_two_times_depth() {
        let rows = vec![
            row(0, "a"),
            row(1, "b"),
            row(2, "c1"),
            row(2, "c2"),
            row(3, "d"),
        ];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[0].chars().count(), 0);
        assert_eq!(out[1].chars().count(), 2);
        assert_eq!(out[2].chars().count(), 4);
        assert_eq!(out[3].chars().count(), 4);
        assert_eq!(out[4].chars().count(), 6);
    }

    #[test]
    fn ancestor_continuation_draws_vertical_bar() {
        // parent-a (has later sibling parent-b at depth 0),
        // child-1 (depth 1, has later sibling child-2 at depth 1),
        // child-2 (last at depth 1 within parent-a's subtree),
        // grandchild (depth 2, only child of child-2),
        // parent-b (depth 0).
        let rows = vec![
            row(0, "parent-a"),
            row(1, "child-1"),
            row(1, "child-2"),
            row(2, "grandchild"),
            row(0, "parent-b"),
        ];
        let out = compute_prefixes(&rows, false);
        // child-1: level-1 continuation because child-2 (another
        // depth-1 sibling) is still coming.
        assert_eq!(out[1], "\u{2502} ");
        // child-2 (last depth-1 sibling in parent-a's subtree) →
        // no bar at own level.
        assert_eq!(out[2], "  ");
        // grandchild: no bars — child-2 has no more depth-1
        // siblings under parent-a, and grandchild itself is the
        // only depth-2 row in its subtree.
        assert_eq!(out[3], "    ");
    }

    #[test]
    fn ascii_mode_uses_pipe() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "last")];
        let out = compute_prefixes(&rows, true);
        assert_eq!(out[1], "| ");
        assert_eq!(out[2], "  ");
    }
}
