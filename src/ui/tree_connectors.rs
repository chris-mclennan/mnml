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
// 2026-08-24 — chev-col bar shifted 1 cell right so it visually
// sits under the Nerd Font chevron glyph. At last-child, ONLY
// the folder-col bar terminates with `└` (curls into the row's
// icon area); the chev-col bar stays a straight `│` — the
// chevron-drop line has no L-shape, ever.
const CONT_NERD: &str = " \u{2502}\u{2502}"; // ' ││'  (pad, chev col, folder col)
const CORNER_NERD: &str = " \u{2502}\u{2514}"; // ' │└' (chev straight, folder curls)
const SPACES: &str = "   "; // 3 spaces — ancestor level fully skipped
const CONT_ASCII: &str = " ||";
const CORNER_ASCII: &str = " |\\";

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
        let mut prefix = String::with_capacity(3 * d);
        // Ancestor levels 1..d-1: `│ ` for continuation, `  ` for
        // ended.
        for level in 1..d {
            if has_later_sibling(rows, i, level) {
                prefix.push_str(cont);
            } else {
                prefix.push_str(SPACES);
            }
        }
        // Own level (`d`): `│ ` if more siblings coming after us
        // (line continues down to reach the next sibling), `└ ` if
        // we're the last child. NO horizontal spur — neo-tree
        // doesn't reach into the icon column.
        if has_later_sibling(rows, i, d) {
            prefix.push_str(cont);
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
        assert_eq!(out[1], " \u{2502}\u{2514}"); // ' │└'  chev straight, folder curls
    }

    #[test]
    fn more_siblings_at_same_depth_draw_bar_then_corner() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "second")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], " \u{2502}\u{2502}"); // ' ││'  chev-col + folder-col straight
        assert_eq!(out[2], " \u{2502}\u{2514}"); // ' │└'  last of its group
    }

    #[test]
    fn continuation_from_uncle_still_coming() {
        let rows = vec![row(0, "parent-a"), row(1, "child"), row(0, "parent-b")];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[1], " \u{2502}\u{2514}"); // last child of parent-a
    }

    #[test]
    fn deep_prefix_width_matches_three_times_depth() {
        let rows = vec![
            row(0, "a"),
            row(1, "b"),
            row(2, "c1"),
            row(2, "c2"),
            row(3, "d"),
        ];
        let out = compute_prefixes(&rows, false);
        assert_eq!(out[0].chars().count(), 0);
        assert_eq!(out[1].chars().count(), 3);
        assert_eq!(out[2].chars().count(), 6);
        assert_eq!(out[3].chars().count(), 6);
        assert_eq!(out[4].chars().count(), 9);
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
        // child-1: level-1 continuation (child-2 still coming) → `│ │`.
        assert_eq!(out[1], "\u{2502} \u{2502}");
        // child-2: corner (last depth-1 sibling in parent-a) → `└  `.
        assert_eq!(out[2], "\u{2514}  ");
        // grandchild: level-1 has ended (no more depth-1 under
        // parent-a) → 3 spaces, level-2 is corner (only child of
        // child-2) → `└  `.
        assert_eq!(out[3], "   \u{2514}  ");
    }

    #[test]
    fn ascii_mode_uses_pipe_and_backslash() {
        let rows = vec![row(0, "parent"), row(1, "first"), row(1, "last")];
        let out = compute_prefixes(&rows, true);
        assert_eq!(out[1], "| |");
        assert_eq!(out[2], "\\  ");
    }
}
