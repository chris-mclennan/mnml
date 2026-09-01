//! Wheel-coalescing helper extracted from `mouse/mod.rs` (T-3 of
//! the file-split refactor — 2026-06-29, code-reviewer N-1 follow-
//! through). When the read event is `ScrollUp`/`Down`, drains every
//! other same-direction scroll from crossterm's queue, sums them,
//! and returns ONE synthetic event with the magnitude stashed in
//! `SCROLL_BATCH_COUNT`. Fixes post-release over-scroll: macOS
//! generates 30+ events per wheel spin; without this they queue
//! and keep applying for ~2s after release.
//!
//! A non-scroll event read during the drain is stashed in
//! `COALESCE_LEFTOVER`; the main event loop drains the stash via
//! [`take_coalesce_leftover`] before reading the next event so the
//! interleaved click/key isn't lost.

use ratatui::crossterm::event::{self, Event as CtEvent, MouseEvent, MouseEventKind};

/// What the drain loop should do with an event it just read.
///
/// Extracted as a pure function because [`coalesce_scroll`] reads from
/// crossterm's global queue, which a unit test cannot inject into — so
/// the POLICY is testable even though the loop is not.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DrainAction {
    /// Another scroll in the same direction — fold it into the batch.
    Count,
    /// A bare motion report. Discard and KEEP DRAINING: all-motion
    /// tracking interleaves these with every wheel burst, and treating
    /// one as a stop meant bursts barely coalesced.
    Skip,
    /// Anything else — stash it for the main loop and stop.
    StashAndStop,
}

pub(crate) fn drain_action(first: MouseEventKind, ev: &CtEvent) -> DrainAction {
    let same_dir = matches!(
        (first, mouse_kind(ev)),
        (MouseEventKind::ScrollUp, Some(MouseEventKind::ScrollUp))
            | (MouseEventKind::ScrollDown, Some(MouseEventKind::ScrollDown))
    );
    if same_dir {
        DrainAction::Count
    } else if matches!(mouse_kind(ev), Some(MouseEventKind::Moved)) {
        DrainAction::Skip
    } else {
        DrainAction::StashAndStop
    }
}

fn mouse_kind(ev: &CtEvent) -> Option<MouseEventKind> {
    match ev {
        CtEvent::Mouse(m) => Some(m.kind),
        _ => None,
    }
}

/// Drain immediately-available scroll events in the SAME direction
/// from crossterm's queue. Non-scroll events return `Ok(None)`; the
/// caller dispatches the original event as-is.
///
/// Caps the batched count so a stuck wheel can't trigger thousands
/// of lines of scroll in one shot.
pub(crate) fn coalesce_scroll(first: &MouseEvent) -> std::io::Result<Option<MouseEvent>> {
    if !matches!(
        first.kind,
        MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
    ) {
        return Ok(None);
    }
    const SCROLL_BATCH_CAP: u32 = 40;
    let mut count: u32 = 1;
    while count < SCROLL_BATCH_CAP {
        if !event::poll(std::time::Duration::ZERO)? {
            break;
        }
        let ev = event::read()?;
        // Policy lives in `drain_action` so it can be unit-tested; the
        // loop only performs it. Keeping the decision inline would mean
        // the tests below asserted something nothing calls.
        match drain_action(first.kind, &ev) {
            DrainAction::Count => {
                count += 1;
                continue;
            }
            DrainAction::Skip => continue,
            DrainAction::StashAndStop => {
                COALESCE_LEFTOVER.with(|s| {
                    let mut slot = s.borrow_mut();
                    // code-reviewer 3rd 2026-06-29 N-1: assert in
                    // debug builds so a future refactor calling
                    // coalesce_scroll twice without draining is
                    // caught.
                    debug_assert!(
                        slot.is_none(),
                        "COALESCE_LEFTOVER was not drained before re-stashing"
                    );
                    *slot = Some(ev);
                });
                break;
            }
        }
    }
    if count <= 1 {
        return Ok(None);
    }
    SCROLL_BATCH_COUNT.store(count, std::sync::atomic::Ordering::Relaxed);
    Ok(Some(*first))
}

/// The most recent coalesced batch's magnitude. Read by the scroll
/// dispatcher to apply N lines instead of 1. Reset to 1 after each
/// consumption.
pub(crate) static SCROLL_BATCH_COUNT: std::sync::atomic::AtomicU32 =
    std::sync::atomic::AtomicU32::new(1);

thread_local! {
    /// code-reviewer W-2 2026-06-28: holds a non-scroll event that
    /// [`coalesce_scroll`] read from the crossterm queue but
    /// can't dispatch itself. The main event loop drains via
    /// [`take_coalesce_leftover`] before reading more events so
    /// interleaved clicks/keys survive wheel bursts.
    static COALESCE_LEFTOVER: std::cell::RefCell<Option<CtEvent>> =
        const { std::cell::RefCell::new(None) };
}

/// Take any event left over from the most recent `coalesce_scroll`
/// call. The main event loop polls this before `event::read()`.
pub(crate) fn take_coalesce_leftover() -> Option<CtEvent> {
    COALESCE_LEFTOVER.with(|s| s.borrow_mut().take())
}

/// Read + consume the pending coalesced scroll magnitude. Returns
/// 1 when no coalescing happened.
pub(crate) fn take_scroll_batch_count() -> u32 {
    SCROLL_BATCH_COUNT
        .swap(1, std::sync::atomic::Ordering::Relaxed)
        .max(1)
}

#[cfg(test)]
mod drain_policy_tests {
    use super::*;
    use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn mouse(kind: MouseEventKind) -> CtEvent {
        CtEvent::Mouse(MouseEvent {
            kind,
            column: 1,
            row: 1,
            modifiers: ratatui::crossterm::event::KeyModifiers::NONE,
        })
    }

    #[test]
    fn same_direction_scrolls_are_folded_into_the_batch() {
        assert_eq!(
            drain_action(
                MouseEventKind::ScrollDown,
                &mouse(MouseEventKind::ScrollDown)
            ),
            DrainAction::Count
        );
    }

    /// The regression: a motion report used to END the drain. With
    /// all-motion tracking on, motion interleaves with every wheel
    /// burst, so coalescing almost never got past one event and the
    /// view advanced in lurches.
    #[test]
    fn a_motion_report_does_not_stop_the_drain() {
        assert_eq!(
            drain_action(MouseEventKind::ScrollDown, &mouse(MouseEventKind::Moved)),
            DrainAction::Skip,
            "a bare motion report ended the wheel drain"
        );
    }

    /// ...but a real interleaved event must still be preserved, or
    /// clicks and keys get eaten during a wheel burst.
    #[test]
    fn a_click_or_key_is_stashed_and_stops_the_drain() {
        assert_eq!(
            drain_action(
                MouseEventKind::ScrollDown,
                &mouse(MouseEventKind::Down(
                    ratatui::crossterm::event::MouseButton::Left
                ))
            ),
            DrainAction::StashAndStop
        );
        assert_eq!(
            drain_action(
                MouseEventKind::ScrollDown,
                &CtEvent::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))
            ),
            DrainAction::StashAndStop
        );
    }

    /// An OPPOSITE-direction scroll must stop the batch, or a reversal
    /// mid-spin would be summed into the wrong direction.
    #[test]
    fn an_opposite_scroll_stops_the_drain() {
        assert_eq!(
            drain_action(MouseEventKind::ScrollDown, &mouse(MouseEventKind::ScrollUp)),
            DrainAction::StashAndStop
        );
    }
}
