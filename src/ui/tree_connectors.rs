//! Connector prefixes for the workspace file tree.
//!
//! R16 (2026-08-24) — neo-tree-style column math (`│` at ancestor
//! levels whose subtree still has siblings coming, corner or
//! tee at own level).
//!
//! 2026-08-24 update — added the horizontal spur at OWN-level
//! connectors so the connector visually reaches into the icon
//! column, matching what mnml-neo-tree-in-the-wild renders (as
//! opposed to the bare-defaults screenshot from the plugin
//! README). Ancestor levels stay `│ ` (they don't attach to the
//! row's icon, just carry the line down through it).
//!
//! Given a DFS-ordered flat list of rows with `depth`, emit per
//! row a prefix of exactly `2 * depth` cells:
//!
//! - For each ancestor level `level` in `1..depth`: `│ ` if
//!   that level's ancestor still has same-depth siblings
//!   coming below this row, else `  `.
//! - At the row's own level `depth`: `├─` (T + spur) if this
//!   row has a later same-depth sibling (line continues past),
//!   else `└─` (corner + spur, this is the last child).
//!
//! Total width `2 * depth`; sibling detection is DFS-flat.

use crate::tree::VisibleRow;

const CONT_NERD: &str = "\u{2502} "; // │  — ancestor continuation
const TEE_NERD: &str = "\u{251C}\u{2500}"; // ├─  — own level, more siblings coming
const CORNER_NERD: &str = "\u{2514}\u{2500}"; // └─  — own level, last child
const SPACES: &str = "  ";
const CONT_ASCII: &str = "| ";
const TEE_ASCII: &str = "|-";
const CORNER_ASCII: &str = "\\-";

/// One prefix per row. Width per prefix == `2 * row.depth`.
pub fn compute_prefixes(rows: &[VisibleRow], ascii: bool) -> Vec<String> {
    let (cont, tee, corner) = if ascii {
        (CONT_ASCII, TEE_ASCII, CORNER_ASCII)
    } else {
        (CONT_NERD, TEE_NERD, CORNER_NERD)
    };

    let mut out = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        let d = row.depth;
        if d == 0 {
            out.push(String::new());
            continue;
        }
        let mut prefix = String::with_capacity(2 * d);
        // Ancestor levels 1..d-1: `│ ` for continuation, `  ` for
        // ended.
        for level in 1..d {
            if has_later_sibling(rows, i, level) {
                prefix.push_str(cont);
            } else {
                prefix.push_str(SPACES);
            }
        }
        // Own level (`d`): `├─` (T + spur) if more siblings coming
        // after us, `└─` (corner + spur) if we're the last child.
        // The horizontal spur reaches into the icon column.
        if has_later_sibling(rows, i, d) {
            prefix.push_str(tee);
        } else {
            prefix.push_str(corner);
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
    fn only_child_gets_corner() {
        let rows = vec![row(0, "parent"), row(1, "only")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{2514}\u{2500}"); // └─ — last (and only) child
    }

    #[test]
    fn more_siblings_at_same_depth_draw_tee_then_corner() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "second")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{251C}\u{2500}"); // ├─ — sibling still coming
        assert_eq!(out[2], "\u{2514}\u{2500}"); // └─ — last of its group
    }

    #[test]
    fn continuation_from_uncle_still_coming() {
        let rows = vec![row(0, "parent-a"), row(1, "child"), row(0, "parent-b")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "\u{2514}\u{2500}"); // last child of parent-a
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
        let rows = vec![
            row(0, "parent-a"),
            row(1, "child-1"),
            row(1, "child-2"),
            row(2, "grandchild"),
            row(0, "parent-b"),
        ];
        let out = compute_prefixes(&rows, false);
        // child-1: level-1 own-level, more siblings coming → ├─.
        assert_eq!(out[1], "\u{251C}\u{2500}");
        // child-2: level-1 own-level, last of parent-a's kids → └─.
        assert_eq!(out[2], "\u{2514}\u{2500}");
        // grandchild: level-1 has ended (space+space), level-2
        // own-level is corner (only child of child-2) → └─.
        assert_eq!(out[3], "  \u{2514}\u{2500}");
    }

    #[test]
    fn ascii_mode_uses_pipe_and_dashes() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "last")];
        let out = compute_prefixes(&rows, true);
        assert_eq!(out[1], "|-");
        assert_eq!(out[2], "\\-");
    }
}
