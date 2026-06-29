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

/// Drain immediately-available scroll events in the SAME direction
/// from crossterm's queue. Non-scroll events return `Ok(None)`; the
/// caller dispatches the original event as-is.
///
/// Caps the batched count so a stuck wheel can't trigger thousands
/// of lines of scroll in one shot.
pub(crate) fn coalesce_scroll(first: &MouseEvent) -> std::io::Result<Option<MouseEvent>> {
    let same_dir = |k: MouseEventKind| -> bool {
        matches!(
            (first.kind, k),
            (MouseEventKind::ScrollUp, MouseEventKind::ScrollUp)
                | (MouseEventKind::ScrollDown, MouseEventKind::ScrollDown)
        )
    };
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
        match ev {
            CtEvent::Mouse(m) if same_dir(m.kind) => {
                count += 1;
                continue;
            }
            // code-reviewer W-2 2026-06-28: stash the non-scroll
            // event in a thread-local so the main event loop can
            // drain it before reading the next event. Previously
            // dropped, which lost interleaved clicks/keys during
            // wheel bursts.
            other => {
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
                    *slot = Some(other);
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
