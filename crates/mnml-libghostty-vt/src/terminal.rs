//! `Terminal` — the top-level libghostty-vt handle.
//!
//! Owns the C `GhosttyTerminal *`, tears it down on `Drop`. Holds
//! the user-installed `write_pty` callback in a boxed closure whose
//! address is passed to Ghostty as `userdata`. A tiny extern-C
//! trampoline forwards C-invoked calls into the Rust closure.

use crate::error::{Error, check};
use libghostty_vt_sys as sys;
use std::mem::MaybeUninit;
use std::os::raw::c_void;
use std::ptr;

/// Terminal construction options — mirrors `GhosttyTerminalOptions`.
#[derive(Debug, Copy, Clone)]
pub struct TerminalOptions {
    /// Width in cells. Must be > 0.
    pub cols: u16,
    /// Height in cells. Must be > 0.
    pub rows: u16,
    /// Maximum number of scrollback lines.
    pub max_scrollback: usize,
}

// Note: upstream ghostty removed `GhosttyTerminalOptions` in the July 2026
// libghostty-vt refactor — `ghostty_terminal_new` now takes `cols` + `rows`
// directly and scrollback is set post-hoc via
// `ghostty_terminal_set(OPT_SCROLLBACK_MAX_LINES, &size_t)`. `TerminalOptions`
// remains as our ergonomic bundle so callers don't have to change.

/// Behavior tag for [`Terminal::scroll_viewport`].
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum ScrollViewport {
    /// Scroll to the top of the scrollback.
    Top,
    /// Scroll to the bottom (active area).
    Bottom,
    /// Scroll by a delta amount. Positive = down, negative = up.
    Delta(isize),
}

/// The libghostty-vt terminal.
///
/// Lifetimes `'alloc, 'sys` are placeholder generic parameters preserved
/// from the pre-existing wrapper API for source compatibility with mnml.
/// They aren't presently used to bound anything the wrapper stores
/// (the terminal owns its own allocations via the C API's default
/// allocator), but they let callers write `Terminal<'static, 'static>`
/// without touching call sites.
pub struct Terminal<'alloc, 'sys> {
    handle: sys::GhosttyTerminal,
    /// Raw pointer to a heap-allocated `Box<dyn FnMut(&[u8])>`. Boxed
    /// twice so the outer pointer is thin (fat `Box<dyn Trait>`s can't
    /// round-trip through `*mut c_void`). Freed in `Drop`.
    write_pty_cb: Option<*mut Box<WritePtyCallback>>,
    _marker: std::marker::PhantomData<(&'alloc (), &'sys ())>,
}

/// Type of the user-installed pty-write callback.
///
/// The closure receives just the byte slice ghostty wants written back
/// to the pty. A `&Terminal` used to be passed alongside (uzaaft's
/// original design) but nothing consumed it — libghostty forbids
/// re-entering `vt_write` from the callback, so a handle would be
/// misleading. Callers that need to touch the terminal buffer the
/// bytes and flush after `vt_write` returns (this is mnml's pattern).
type WritePtyCallback = dyn FnMut(&[u8]) + 'static;

impl<'alloc, 'sys> Terminal<'alloc, 'sys> {
    /// Create a terminal with the default allocator.
    pub fn new(options: TerminalOptions) -> Result<Self, Error> {
        let mut handle: sys::GhosttyTerminal = ptr::null_mut();
        // SAFETY: NULL allocator → default. `handle` receives an owned
        // pointer we release in `Drop`.
        let r = unsafe {
            sys::ghostty_terminal_new(ptr::null(), &mut handle, options.cols, options.rows)
        };
        check(r)?;

        // Scrollback line limit is post-construction — `size_t*` value pointer.
        // NULL clears; passing `&count` sets the limit.
        // SAFETY: `handle` valid; `&scrollback` is a pointer to a stack size_t
        // which ghostty reads once during the set call.
        let scrollback: usize = options.max_scrollback;
        let r = unsafe {
            sys::ghostty_terminal_set(
                handle,
                sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                &scrollback as *const _ as *const c_void,
            )
        };
        if let Err(e) = check(r) {
            // SAFETY: `handle` came from a successful `_new`; freeing it
            // here reclaims resources before we return the error.
            unsafe { sys::ghostty_terminal_free(handle) };
            return Err(e);
        }

        Ok(Terminal {
            handle,
            write_pty_cb: None,
            _marker: std::marker::PhantomData,
        })
    }

    /// Install a callback invoked when the terminal needs to write
    /// bytes back to the pty (device-status queries, mode reports).
    ///
    /// libghostty forbids calling [`Terminal::vt_write`] from inside
    /// this callback (no reentrancy). Buffer the bytes and flush them
    /// after `vt_write` returns.
    pub fn on_pty_write<F>(&mut self, f: F) -> Result<(), Error>
    where
        F: FnMut(&[u8]) + 'static,
    {
        // Drop the previous callback, if any, before installing the new
        // one. (Two `on_pty_write` calls would otherwise leak the first.)
        if let Some(prev) = self.write_pty_cb.take() {
            // SAFETY: `prev` was produced by Box::into_raw in a prior
            // successful call to this method.
            unsafe { drop(Box::from_raw(prev)) };
        }

        // Double-box the closure so we hold a THIN pointer we can send
        // through ghostty's `*mut c_void` userdata slot.
        let inner: Box<WritePtyCallback> = Box::new(f);
        let outer: *mut Box<WritePtyCallback> = Box::into_raw(Box::new(inner));

        // Install userdata + the trampoline.
        //
        // ABI gotcha: `ghostty_terminal_set`'s `value` arg for POINTER-
        // typed options (OPT_USERDATA, OPT_WRITE_PTY) IS the pointer
        // itself — not a pointer-to-pointer. See vt/terminal.h line
        // 1073–1075: "The value is passed directly for pointer types
        // (callbacks, userdata) or as a pointer to the value for non-
        // pointer types". Passing `&outer as *const _` (a stack-slot
        // address holding the real pointer) registers a pointer to a
        // local that goes out of scope the moment this fn returns —
        // ghostty will later dereference stale/reused stack memory when
        // it fires the callback. That was the STATUS_ACCESS_VIOLATION.
        // SAFETY: valid handle; `outer` was Box::into_raw'd and lives
        // until Drop or the next `on_pty_write` call, and the fn
        // pointer has 'static lifetime.
        let r = unsafe {
            sys::ghostty_terminal_set(
                self.handle,
                sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_USERDATA,
                outer as *const c_void,
            )
        };
        if let Err(e) = check(r) {
            unsafe { drop(Box::from_raw(outer)) };
            return Err(e);
        }

        let r = unsafe {
            sys::ghostty_terminal_set(
                self.handle,
                sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                write_pty_trampoline as *const c_void,
            )
        };
        if let Err(e) = check(r) {
            // Best-effort: clear userdata to NULL before dropping the
            // box so ghostty doesn't retain a dangling pointer. NULL
            // here means "clear the option to default" per the header.
            unsafe {
                sys::ghostty_terminal_set(
                    self.handle,
                    sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_USERDATA,
                    ptr::null(),
                );
                drop(Box::from_raw(outer));
            }
            return Err(e);
        }

        // Retain the outer pointer so `Drop` can free it later.
        self.write_pty_cb = Some(outer);
        Ok(())
    }

    /// Feed bytes into the terminal parser.
    pub fn vt_write(&mut self, data: &[u8]) -> Result<(), Error> {
        if data.is_empty() {
            return Ok(());
        }
        // SAFETY: `data.as_ptr()` valid for `data.len()` bytes.
        unsafe {
            sys::ghostty_terminal_vt_write(self.handle, data.as_ptr(), data.len());
        }
        Ok(())
    }

    /// Resize the terminal.
    pub fn resize(
        &mut self,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<(), Error> {
        // SAFETY: valid terminal handle.
        let r = unsafe {
            sys::ghostty_terminal_resize(self.handle, cols, rows, cell_width_px, cell_height_px)
        };
        check(r)
    }

    /// Column count (cells).
    pub fn cols(&self) -> Result<u16, Error> {
        let mut out = MaybeUninit::<u16>::uninit();
        // SAFETY: out matches documented COLS output type (`uint16_t *`).
        let r = unsafe {
            sys::ghostty_terminal_get(
                self.handle,
                sys::GhosttyTerminalData::GHOSTTY_TERMINAL_DATA_COLS,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() })
    }

    /// Row count (cells).
    pub fn rows(&self) -> Result<u16, Error> {
        let mut out = MaybeUninit::<u16>::uninit();
        let r = unsafe {
            sys::ghostty_terminal_get(
                self.handle,
                sys::GhosttyTerminalData::GHOSTTY_TERMINAL_DATA_ROWS,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() })
    }

    /// Whether any mouse-tracking mode is active.
    pub fn is_mouse_tracking(&self) -> Result<bool, Error> {
        let mut out = MaybeUninit::<bool>::uninit();
        // SAFETY: MOUSE_TRACKING documented output type `bool *`.
        let r = unsafe {
            sys::ghostty_terminal_get(
                self.handle,
                sys::GhosttyTerminalData::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() })
    }

    /// Current terminal title (set via OSC 0/2), or `None` if unset /
    /// empty.
    ///
    /// The returned string is copied out of the C-side buffer so callers
    /// don't have to worry about the "valid until next vt_write" contract
    /// on the borrowed buffer.
    pub fn title(&self) -> Option<String> {
        let mut out = MaybeUninit::<sys::GhosttyString>::uninit();
        // SAFETY: TITLE returns a GhosttyString*.
        let r = unsafe {
            sys::ghostty_terminal_get(
                self.handle,
                sys::GhosttyTerminalData::GHOSTTY_TERMINAL_DATA_TITLE,
                out.as_mut_ptr().cast(),
            )
        };
        if r != sys::GhosttyResult::GHOSTTY_SUCCESS {
            return None;
        }
        let s = unsafe { out.assume_init() };
        if s.ptr.is_null() || s.len == 0 {
            return None;
        }
        // SAFETY: ghostty guarantees valid UTF-8 for OSC titles; if it
        // isn't, we drop bytes rather than panicking on the render loop.
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Scroll the viewport.
    pub fn scroll_viewport(&mut self, sv: ScrollViewport) {
        let (tag, value) = match sv {
            ScrollViewport::Top => (
                sys::GhosttyTerminalScrollViewportTag::GHOSTTY_SCROLL_VIEWPORT_TOP,
                sys::GhosttyTerminalScrollViewportValue { delta: 0 },
            ),
            ScrollViewport::Bottom => (
                sys::GhosttyTerminalScrollViewportTag::GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
                sys::GhosttyTerminalScrollViewportValue { delta: 0 },
            ),
            ScrollViewport::Delta(d) => (
                sys::GhosttyTerminalScrollViewportTag::GHOSTTY_SCROLL_VIEWPORT_DELTA,
                sys::GhosttyTerminalScrollViewportValue { delta: d },
            ),
        };
        let behavior = sys::GhosttyTerminalScrollViewport { tag, value };
        // SAFETY: valid terminal handle + valid tagged union.
        unsafe {
            sys::ghostty_terminal_scroll_viewport(self.handle, behavior);
        }
    }

    /// Raw handle — for advanced callers that need to interop with the
    /// sys-level API (e.g. the render state, which takes the C handle).
    pub(crate) fn as_raw(&self) -> sys::GhosttyTerminal {
        self.handle
    }
}

impl Drop for Terminal<'_, '_> {
    fn drop(&mut self) {
        // Order matters: clear callback + userdata FIRST so ghostty
        // stops reading the box pointer, THEN free the box, THEN free
        // the terminal. NULL as the `value` arg tells ghostty to clear
        // the option (per vt/terminal.h line 1076).
        // SAFETY: `handle` is still valid before ghostty_terminal_free.
        unsafe {
            sys::ghostty_terminal_set(
                self.handle,
                sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                ptr::null(),
            );
            sys::ghostty_terminal_set(
                self.handle,
                sys::GhosttyTerminalOption::GHOSTTY_TERMINAL_OPT_USERDATA,
                ptr::null(),
            );
        }
        if let Some(outer) = self.write_pty_cb.take() {
            // SAFETY: pointer came from Box::into_raw in `on_pty_write`.
            unsafe { drop(Box::from_raw(outer)) };
        }
        // SAFETY: freeing our own allocation. Ghostty accepts NULL too.
        unsafe { sys::ghostty_terminal_free(self.handle) };
    }
}

// SAFETY: `write_pty_trampoline` is invoked by libghostty-vt with the
// userdata pointer we registered — a thin `*mut Box<WritePtyCallback>`
// produced by `Box::into_raw` in `on_pty_write`. Ghostty guarantees
// `data`/`len` describe a valid byte range for the call.
unsafe extern "C" fn write_pty_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    if userdata.is_null() || data.is_null() {
        return;
    }
    // SAFETY: userdata was Box::into_raw(Box::new(inner_box)); it lives
    // until Terminal::Drop frees it. Reborrow mutably for the callback.
    let outer = userdata as *mut Box<WritePtyCallback>;
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    unsafe {
        (**outer)(bytes);
    }
}

#[cfg(test)]
mod tests {
    //! Terminal callback regression tests.
    //!
    //! Locks in the pointer-typed-option ABI contract: pass the pointer
    //! VALUE directly, not a pointer-to-pointer. Getting this wrong lets
    //! ghostty read stack-slot-turned-garbage the next time it fires
    //! the callback — the STATUS_ACCESS_VIOLATION we shipped as UB on
    //! macOS/Linux and shattered on Windows CI.

    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// Feed a Device Status Report query (`ESC [ 6 n`) — ghostty replies
    /// with the cursor position via the `write_pty` callback. Verifies
    /// the trampoline actually fires with meaningful bytes, so the
    /// pointer-typed-option registration must be correct.
    #[test]
    fn on_pty_write_receives_dsr_reply() {
        let mut term = Terminal::new(TerminalOptions {
            cols: 20,
            rows: 5,
            max_scrollback: 0,
        })
        .unwrap();
        let sink: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
        {
            let sink = Rc::clone(&sink);
            term.on_pty_write(move |bytes| {
                sink.borrow_mut().extend_from_slice(bytes);
            })
            .unwrap();
        }
        // DSR-6 (cursor position report). Ghostty replies with `ESC [ y ; x R`.
        term.vt_write(b"\x1b[6n").unwrap();
        let reply = sink.borrow();
        assert!(
            reply.starts_with(b"\x1b["),
            "expected CSI-prefixed DSR reply, got {reply:?}"
        );
        assert!(
            reply.ends_with(b"R"),
            "expected DSR reply to terminate with 'R', got {reply:?}"
        );
    }

    /// Two consecutive `on_pty_write` installs — the old boxed closure
    /// must be freed, and the new one must receive the callback bytes.
    /// If drop-order were wrong (or the outer box leaked), miri /
    /// address-sanitizer would flag it.
    #[test]
    fn on_pty_write_can_be_reinstalled() {
        let mut term = Terminal::new(TerminalOptions {
            cols: 20,
            rows: 5,
            max_scrollback: 0,
        })
        .unwrap();
        let first: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
        {
            let first = Rc::clone(&first);
            term.on_pty_write(move |b| first.borrow_mut().extend_from_slice(b))
                .unwrap();
        }
        let second: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
        {
            let second = Rc::clone(&second);
            term.on_pty_write(move |b| second.borrow_mut().extend_from_slice(b))
                .unwrap();
        }
        term.vt_write(b"\x1b[6n").unwrap();
        assert!(
            first.borrow().is_empty(),
            "old callback should have been unregistered"
        );
        assert!(
            !second.borrow().is_empty(),
            "new callback should have received DSR reply"
        );
    }

    /// The scrollback line limit passed via `TerminalOptions.max_scrollback`
    /// must actually reach the C side. Round-trip via
    /// `ghostty_terminal_get(DATA_SCROLLBACK_MAX_LINES)`.
    ///
    /// Regression coverage: without this test, a swallowed `GhosttyResult`
    /// on the internal `_set(OPT_SCROLLBACK_MAX_LINES, …)` call would
    /// silently ship a Terminal running on ghostty's default limit rather
    /// than the configured one — the same failure-shape as the pointer-
    /// typed-option bug the reviewer caught a few commits ago.
    #[test]
    fn scrollback_max_lines_round_trips() {
        let requested: usize = 123;
        let term = Terminal::new(TerminalOptions {
            cols: 20,
            rows: 5,
            max_scrollback: requested,
        })
        .unwrap();
        let mut out = std::mem::MaybeUninit::<usize>::uninit();
        let r = unsafe {
            sys::ghostty_terminal_get(
                term.handle,
                sys::GhosttyTerminalData::GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
                out.as_mut_ptr().cast(),
            )
        };
        assert_eq!(
            r,
            sys::GhosttyResult::GHOSTTY_SUCCESS,
            "SCROLLBACK_MAX_LINES query should succeed for a configured limit"
        );
        assert_eq!(
            unsafe { out.assume_init() },
            requested,
            "configured limit must round-trip through _set/_get"
        );
    }

    /// Dropping a Terminal that has an installed callback must not leak
    /// or double-free — the Drop path clears userdata+trampoline before
    /// freeing the closure box.
    #[test]
    fn drop_after_on_pty_write_is_clean() {
        let mut term = Terminal::new(TerminalOptions {
            cols: 20,
            rows: 5,
            max_scrollback: 0,
        })
        .unwrap();
        let sink: Rc<RefCell<Vec<u8>>> = Rc::new(RefCell::new(Vec::new()));
        {
            let sink = Rc::clone(&sink);
            term.on_pty_write(move |b| sink.borrow_mut().extend_from_slice(b))
                .unwrap();
        }
        term.vt_write(b"\x1b[6n").unwrap();
        drop(term);
        // If we get here without a double-free / segfault, Drop is sound.
        assert!(!sink.borrow().is_empty());
    }
}
