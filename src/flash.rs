//! Flash/leap-style 2-char jump motion state.
//!
//! The vim handler accumulates `s<a><b>` and escalates to
//! `AppCommand::FlashStart(a, b)`. The App finds every visible occurrence of
//! `ab` in the active editor pane, assigns each a single-letter label from
//! `LABEL_POOL`, and stashes them in `App.flash_state`. While Some, the
//! `tui::dispatch_key` head intercepts: Esc cancels; any other char that
//! matches a label commits the jump (cursor → that match); anything else
//! cancels and re-dispatches the keystroke.
//!
//! Labels are deliberately drawn from chars that don't include `a` or `b`
//! so the user's mental "I'm typing the third letter to commit" doesn't
//! collide with the trigger pair.

use ratatui::layout::Rect;

use crate::layout::PaneId;

/// Up to this many matches get labelled. Beyond this, the rest are silently
/// dropped — flash isn't a search tool, it's a navigation gesture for
/// what's on screen RIGHT NOW.
pub const MAX_MATCHES: usize = 60;

/// Label alphabet — lowercase first (home-row biased), then uppercase. The
/// trigger pair's chars are filtered out when picking, so typing `sab<next>`
/// can't get confused.
const LABEL_POOL: &str = "fjdkslaghrueiwoqptyzxcvbnmFJDKSLAGHRUEIWOQPTYZXCVBNM";

/// One labelled target in the editor.
#[derive(Debug, Clone)]
pub struct FlashTarget {
    /// File row (0-based).
    pub row: usize,
    /// Column in chars from the start of the line (0-based, NOT byte offset
    /// — display column for cursor placement).
    pub col_chars: usize,
    /// The label char the user types to commit this jump.
    pub label: char,
}

/// Active flash session.
#[derive(Debug, Clone)]
pub struct FlashState {
    /// Which pane owns the labels. Switching panes drops the state.
    pub pane_id: PaneId,
    /// The trigger pair (for visual display + filter of label pool).
    pub pair: (char, char),
    /// All labelled targets — sorted top-to-bottom, left-to-right.
    pub targets: Vec<FlashTarget>,
}

/// Pick `n` labels from the alphabet pool, skipping any char that equals
/// `pair.0` or `pair.1` (case-insensitive) so typing the label is
/// unambiguous.
pub fn pick_labels(pair: (char, char), n: usize) -> Vec<char> {
    let a_lower = pair.0.to_ascii_lowercase();
    let b_lower = pair.1.to_ascii_lowercase();
    LABEL_POOL
        .chars()
        .filter(|&c| {
            let lc = c.to_ascii_lowercase();
            lc != a_lower && lc != b_lower
        })
        .take(n)
        .collect()
}

/// Map a target's `(row, col_chars)` to a screen `(x, y)` cell inside the
/// editor pane's text area, given the buffer's scroll/h_scroll state and
/// the pane's text rect. Returns `None` when the target is off-screen.
///
/// `text_rect` is the rect that `editor_view::draw_pane` uses for the body
/// (gutter excluded). `vert_scroll` is the file row at the top of the
/// viewport; `h_scroll` is the leftmost visible column. `wrap_width`
/// is `Some(text_w)` when soft-wrap is enabled — in that case multiple
/// visual rows map onto a single file row.
pub fn target_to_screen(
    target: &FlashTarget,
    text_rect: Rect,
    vert_scroll: usize,
    h_scroll: usize,
    wrap_width: Option<usize>,
) -> Option<(u16, u16)> {
    let text_w = text_rect.width as usize;
    let text_h = text_rect.height as usize;
    if text_w == 0 || text_h == 0 {
        return None;
    }
    if target.row < vert_scroll {
        return None;
    }
    let row_off = target.row - vert_scroll;
    let (visual_y, visual_x) = match wrap_width {
        Some(w) if w > 0 => {
            // Best-effort: this ignores fold-collapse + multi-line wrap of
            // earlier rows in the viewport. For a non-wrapping file this
            // matches the simple branch exactly. For wrap, the cursor can
            // land slightly off — the user will be able to see the label,
            // just not at the perfect cell. Improving this means walking
            // `next_visible_line` like editor_view does.
            (row_off + target.col_chars / w, target.col_chars % w)
        }
        _ => {
            if target.col_chars < h_scroll {
                return None;
            }
            (row_off, target.col_chars - h_scroll)
        }
    };
    if visual_y >= text_h || visual_x >= text_w {
        return None;
    }
    Some((text_rect.x + visual_x as u16, text_rect.y + visual_y as u16))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_labels_skips_trigger_chars() {
        let labels = pick_labels(('f', 'j'), 5);
        for c in &labels {
            assert_ne!(c.to_ascii_lowercase(), 'f');
            assert_ne!(c.to_ascii_lowercase(), 'j');
        }
        assert_eq!(labels.len(), 5);
    }

    #[test]
    fn pick_labels_caps_at_pool_size() {
        let labels = pick_labels(('a', 'b'), 1000);
        // Two letters excluded → at most LABEL_POOL.len() - chars-excluded.
        let expected_max = LABEL_POOL
            .chars()
            .filter(|&c| {
                let lc = c.to_ascii_lowercase();
                lc != 'a' && lc != 'b'
            })
            .count();
        assert_eq!(labels.len(), expected_max);
    }

    #[test]
    fn target_to_screen_clips_off_screen() {
        let r = Rect {
            x: 5,
            y: 10,
            width: 20,
            height: 8,
        };
        // Target row below viewport.
        let t = FlashTarget {
            row: 100,
            col_chars: 0,
            label: 'a',
        };
        assert_eq!(target_to_screen(&t, r, 0, 0, None), None);
        // Target row above viewport.
        let t2 = FlashTarget {
            row: 0,
            col_chars: 0,
            label: 'a',
        };
        assert_eq!(target_to_screen(&t2, r, 5, 0, None), None);
        // On-screen, no scroll.
        let t3 = FlashTarget {
            row: 3,
            col_chars: 7,
            label: 'a',
        };
        assert_eq!(target_to_screen(&t3, r, 0, 0, None), Some((12, 13)));
        // Horizontal scroll clip.
        assert_eq!(target_to_screen(&t3, r, 0, 10, None), None);
    }
}
