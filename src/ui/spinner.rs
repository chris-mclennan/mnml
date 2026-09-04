//! The one busy-indicator in mnml.
//!
//! User ask 2026-09-04: "when i click refresh can i see the arrow spin
//! or something to indicate its doing what i asked for?" — and, in the
//! same breath, "i think we need a button component to handle all this,
//! and we start utilizing it".
//!
//! Both halves of that were already half-true. `ui::action_button`
//! exists and is barely used, and there were THREE spinner
//! implementations before this module: `agents_panel` and
//! `cloud_agents_panel` held byte-identical copies of a 6-frame arc,
//! and `toast_stack` used a different 8-frame braille at a different
//! cadence. Three answers to "is something happening?" in one app.
//!
//! Frames are the arc set, because it reads as rotation at a glance —
//! which is what a refresh button wants. Braille dots read as
//! indeterminate progress, which is a different statement.

/// Rotating arc. Six frames so a full turn is visually smooth without
/// the cadence needing to be fast enough to flicker.
pub const FRAMES: &[&str] = &["◜", "◠", "◝", "◞", "◡", "◟"];

/// Milliseconds per frame. 150ms × 6 ≈ a 0.9s rotation — fast enough
/// to read as motion, slow enough not to strobe on a 25fps redraw.
pub const FRAME_MS: u128 = 150;

/// The frame for right now.
///
/// Anchored to a process-static `Instant` rather than wall-clock, so a
/// clock change or DST shift cannot make the spinner jump or stall.
/// Every caller shares the anchor, so two spinners on screen turn in
/// step instead of beating against each other.
pub fn frame() -> &'static str {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    let ms = std::time::Instant::now().duration_since(*start).as_millis();
    FRAMES[(ms / FRAME_MS) as usize % FRAMES.len()]
}

/// An ASCII rotation for `--ascii` mode / fonts without the arcs.
pub const ASCII_FRAMES: &[&str] = &["|", "/", "-", "\\"];

/// [`frame`], in whichever alphabet the UI is running.
pub fn frame_for(ascii: bool) -> &'static str {
    if !ascii {
        return frame();
    }
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    let ms = std::time::Instant::now().duration_since(*start).as_millis();
    ASCII_FRAMES[(ms / FRAME_MS) as usize % ASCII_FRAMES.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every frame must be exactly one cell, or a spinning button
    /// changes width as it turns and the row reflows under the cursor.
    #[test]
    fn every_frame_is_one_cell() {
        for f in FRAMES.iter().chain(ASCII_FRAMES.iter()) {
            assert_eq!(f.chars().count(), 1, "frame {f:?} is not one char");
        }
    }

    /// The frame must actually advance, or "spinning" is a still image.
    #[test]
    fn the_frame_advances_over_time() {
        let a = frame();
        std::thread::sleep(std::time::Duration::from_millis(FRAME_MS as u64 + 40));
        let b = frame();
        assert_ne!(a, b, "the spinner did not advance across a frame boundary");
    }

    #[test]
    fn ascii_mode_uses_the_ascii_alphabet() {
        assert!(ASCII_FRAMES.contains(&frame_for(true)));
        assert!(FRAMES.contains(&frame_for(false)));
    }
}
