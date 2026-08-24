//! nvim-tree-style ├─ / └─ / │  connector prefixes for the
//! workspace file tree.
//!
//! User ask 2026-08-23: mnml's tree only indents; nvim-tree draws
//! visible connector lines between parent folders and children so
//! the hierarchy is obvious at a glance.
//!
//! Given a DFS-ordered flat list of rows with `depth`, emit per
//! row a prefix of exactly `2 * depth` cells:
//!
//! - For each ancestor level `level` in `0..depth-1`: `│ ` when
//!   that ancestor has a later same-depth sibling still coming
//!   (line-continues-down), else `  ` (line ends above us).
//! - Cells `2*(depth-1)..2*depth`: the elbow into this row.
//!   `├─` when this row has a later sibling at its own depth
//!   (line continues past us to the next sibling); `└─` when
//!   we're the last of our sibling group.
//!
//! Total width `2 * depth` matches the old `"  ".repeat(depth)`
//! padding, so downstream tree-view layout math is untouched.
//!
//! Sibling detection is DFS-flat: for row `i` at depth `d`, walk
//! forward — a row at exactly `d` seen before any row at depth
//! `< d` means another sibling is coming. O(n·d) worst case;
//! for typical tree sizes (< 500 visible rows) this is a
//! non-issue on the render path.

use crate::tree::VisibleRow;

const ELBOW_MORE_NERD: &str = "\u{251C}\u{2500}"; // ├─
const ELBOW_LAST_NERD: &str = "\u{2514}\u{2500}"; // └─
const CONT_NERD: &str = "\u{2502} "; //           │
const SPACES: &str = "  ";
const ELBOW_MORE_ASCII: &str = "+-";
const ELBOW_LAST_ASCII: &str = "\\-";
const CONT_ASCII: &str = "| ";

/// One prefix per row. Width per prefix == `2 * row.depth`.
pub fn compute_prefixes(rows: &[VisibleRow], ascii: bool) -> Vec<String> {
    let (cont, elbow_more, elbow_last) = if ascii {
        (CONT_ASCII, ELBOW_MORE_ASCII, ELBOW_LAST_ASCII)
    } else {
        (CONT_NERD, ELBOW_MORE_NERD, ELBOW_LAST_NERD)
    };

    let mut out = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        let d = row.depth;
        if d == 0 {
            out.push(String::new());
            continue;
        }
        let mut prefix = String::with_capacity(2 * d);
        // Ancestor cells — levels 0..d-1.
        for level in 0..d.saturating_sub(1) {
            if has_later_sibling(rows, i, level) {
                prefix.push_str(cont);
            } else {
                prefix.push_str(SPACES);
            }
        }
        // Elbow — based on this row's own-depth sibling status.
        if has_later_sibling(rows, i, d) {
            prefix.push_str(elbow_more);
        } else {
            prefix.push_str(elbow_last);
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
    fn elbow_last_for_only_child() {
        let rows = vec![row(0, "parent"), row(1, "only")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{2514}\u{2500}"); // └─
    }

    #[test]
    fn elbow_more_when_more_same_depth_siblings_follow() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "second")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{251C}\u{2500}"); // ├─
        assert_eq!(out[2], "\u{2514}\u{2500}"); // └─
    }

    #[test]
    fn continuation_from_uncle_still_coming() {
        // parent-a (has sibling later), child (only), parent-b
        let rows = vec![row(0, "parent-a"), row(1, "child"), row(0, "parent-b")];
        let out = compute_prefixes(&rows, false);
        // child depth 1 has no d=1 sibling after → elbow └─. No
        // ancestor levels for d=1.
        assert_eq!(out[1], "\u{2514}\u{2500}");
    }

    #[test]
    fn deep_prefix_width_matches_two_times_depth() {
        // a → b → c1, c2 → d
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
}
