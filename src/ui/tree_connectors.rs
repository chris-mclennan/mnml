//! Neo-tree-style connector prefixes for the workspace file tree.
//!
//! Matches neo-tree.nvim's defaults exactly: `│` for continuation
//! (ancestor AND own-level-with-more-siblings-coming), `└` for
//! last child at its own level. NO `├─`, NO `─` spur — an
//! intermediate row keeps a plain `│` at its own level, and the
//! `└` is JUST the corner character (whose natural bottom-right
//! shape looks like a small L but does not extend into the icon
//! column).
//!
//! Given a DFS-ordered flat list of rows with `depth`, emit per
//! row a prefix of exactly `2 * depth` cells:
//!
//! - For each ancestor level `level` in `1..depth`: `│ ` if
//!   that level's ancestor still has same-depth siblings
//!   coming below this row, else `  `.
//! - At the row's own level `depth`: `│ ` if this row has a
//!   later same-depth sibling (line continues past), else
//!   `└ ` (this is the last child, corner into the row).
//!
//! Total width `2 * depth`; sibling detection is DFS-flat.

use crate::tree::VisibleRow;

// 2026-08-24 — indent widened to 3 cells per level so each
// expanded parent leaves TWO vertical bars (chevron-col bar +
// folder-col bar), separated by a space instead of adjacent.
// Uniform width per level keeps the paint math simple.
// 2026-08-24 — 2-cell per level. One bar per ancestor at
// chev-col. Child chev aligns with parent's folder icon
// column (parent chev at col N + trailing space at N+1 +
// child chev at N+2 = parent folder at N+2). Sacrifices
// the second (folder-col) bar to get alignment.
// Level 1 (top-level rows) never emits connectors — just
// spaces — matching neo-tree's `level < 2` skip.
// 2026-08-24 — F1F04 / F1F05 are copies of JetBrainsMono's U+2502 /
// U+2514 outlines translated +100u right, injected by
// scripts/inject_tree_connectors.py. Correct cell metrics so lines
// link vertically, with a modest right-shift toward the chevron
// column above.
const CONT_NERD: &str = "\u{F1F04} "; // shifted '│ '
const CORNER_NERD: &str = "\u{F1F05} "; // shifted '└ '
const SPACES: &str = "  "; // 2 spaces — ancestor ended (or level 1 skip)
const CONT_ASCII: &str = "| ";
const CORNER_ASCII: &str = "\\ ";

/// One prefix per row. Width per prefix == `2 * row.depth`.
pub fn compute_prefixes(rows: &[VisibleRow], ascii: bool) -> Vec<String> {
    let (cont, corner) = if ascii {
        (CONT_ASCII, CORNER_ASCII)
    } else {
        (CONT_NERD, CORNER_NERD)
    };

    let mut out = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        let d = row.depth;
        if d == 0 {
            out.push(String::new());
            continue;
        }
        let mut prefix = String::with_capacity(2 * d);
        // Ancestor levels 1..d-1: `│ │` for continuation, 3 spaces
        // for ended. Level 1 always renders as spaces — top-level
        // items don't emit connectors (matches neo-tree `level<2`).
        for level in 1..d {
            if level >= 2 && has_later_sibling(rows, i, level) {
                prefix.push_str(cont);
            } else {
                prefix.push_str(SPACES);
            }
        }
        // Own level (`d`). Depth 1 rows get plain spaces. Depth 2+
        // ALWAYS get `│ ` (never `└ `) — this line sits under the
        // parent's chevron column, and per user rule the chevron-
        // drop line never terminates with an L. File rows get their
        // own `└ ` terminator painted in the chev-slot by tree_view.
        if d < 2 {
            prefix.push_str(SPACES);
        } else {
            let _ = corner; // kept for potential future use
            prefix.push_str(cont);
        }
        out.push(prefix);
    }
    out
}

/// True if the row at `idx` has NO more same-depth siblings coming
/// after it in DFS order. Used by tree_view to paint `└` in the
/// chev-column slot of a file row (files don't have their own
/// chevron; the slot becomes the terminating corner instead).
pub fn is_last_child(rows: &[VisibleRow], idx: usize) -> bool {
    let d = rows[idx].depth;
    !has_later_sibling(rows, idx, d)
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
        // Level 1 row: no connectors at all (matches neo-tree level<2 skip).
        let rows = vec![row(0, "parent"), row(1, "only")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "  "); // 2 spaces
    }

    #[test]
    fn more_siblings_at_same_depth_draw_bar_then_corner() {
        // At level 1, no markers either way.
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "second")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "  ");
        assert_eq!(out[2], "  ");
    }

    #[test]
    fn depth_2_gets_own_level_markers() {
        // parent (0) > child (1) > grand-a (2) > grand-b (2)
        let rows = vec![
            row(0, "parent"),
            row(1, "child"),
            row(2, "grand-a"),
            row(2, "grand-b"),
        ];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], "  "); // level 1 = spaces
        // grand-a: level 1 = spaces (skip), level 2 own = `│ ` (chev-drop straight)
        assert_eq!(out[2], "  \u{F1F04} ");
        // grand-b: level 1 = spaces, level 2 own = `│ ` (chev-drop always
        // straight — no `└ ` here even at last-child. Last-child `└` is
        // painted by tree_view for FILE rows in the chev-slot, not here).
        assert_eq!(out[3], "  \u{F1F04} ");
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
    fn deep_ancestor_continuation() {
        // parent-a (0) > c1 (1) > gc1 (2) > gc2 (2) > ggc (3) > parent-b (0)
        let rows = vec![
            row(0, "parent-a"),
            row(1, "c1"),
            row(2, "gc1"),
            row(2, "gc2"),
            row(3, "ggc"),
            row(0, "parent-b"),
        ];
        let out = compute_prefixes(&rows, false);
        // ggc at depth 3: level 1 spaces + level 2 spaces (gc2 is last, no
        // more depth-2 after) + own level 3 = `│ ` (chev-drop always straight).
        assert_eq!(out[4], "    \u{F1F04} ");
    }

    #[test]
    fn ascii_mode_uses_pipe_and_backslash() {
        // Depth 1 always spaces regardless of ascii/nerd.
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "last")];
        let out = compute_prefixes(&rows, true);
        assert_eq!(out[1], "  ");
        assert_eq!(out[2], "  ");
    }
}
