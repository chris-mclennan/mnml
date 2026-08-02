//! Render state — the incremental-render surface libghostty exposes.
//!
//! The rough flow mnml uses:
//!
//! ```ignore
//! let mut rs = RenderState::new()?;
//! // (later, per frame)
//! let snapshot = rs.update(&terminal)?;
//! let colors = snapshot.colors()?;
//! let cursor = snapshot.cursor_viewport()?;
//! let dirty  = snapshot.dirty()?;
//! // Walk rows/cells:
//! let (mut rows_h, mut cells_h) = (RowIterator::new()?, CellIterator::new()?);
//! let mut row_iter = rows_h.update(&snapshot)?;
//! while let Some(mut row) = row_iter.next() {
//!     let mut cell_iter = cells_h.update(&row)?;
//!     while let Some(cell) = cell_iter.next() {
//!         let _ = cell.fg_color()?;
//!         let _ = cell.style()?;
//!         let _ = cell.graphemes()?;
//!     }
//!     row.set_dirty(false)?;
//! }
//! snapshot.set_dirty(Dirty::Clean)?;
//! ```
//!
//! The lifetimes on `Snapshot`/`Row`/`Cell` enforce that reads happen
//! before the next `rs.update()` — libghostty's contract on row/cell
//! iterators is that data is only valid until the next update.

use crate::error::{Error, check};
use crate::screen::RawCell;
use crate::style::{RgbColor, Style};
use crate::terminal::Terminal;
use libghostty_vt_sys as sys;
use std::marker::PhantomData;
use std::mem::MaybeUninit;
use std::ptr;

// ── Dirty ──────────────────────────────────────────────────────

/// Dirty state of a render snapshot.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Dirty {
    /// Nothing changed since the last set-clean.
    Clean,
    /// Some rows changed; incremental redraw is OK.
    Partial,
    /// Global state changed; renderer should redraw everything.
    Full,
}

impl From<sys::GhosttyRenderStateDirty> for Dirty {
    fn from(d: sys::GhosttyRenderStateDirty) -> Self {
        match d {
            sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_FALSE => Dirty::Clean,
            sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_PARTIAL => Dirty::Partial,
            sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_FULL => Dirty::Full,
            _ => Dirty::Full,
        }
    }
}

impl From<Dirty> for sys::GhosttyRenderStateDirty {
    fn from(d: Dirty) -> Self {
        match d {
            Dirty::Clean => sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_FALSE,
            Dirty::Partial => sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_PARTIAL,
            Dirty::Full => sys::GhosttyRenderStateDirty::GHOSTTY_RENDER_STATE_DIRTY_FULL,
        }
    }
}

// ── CursorViewport ─────────────────────────────────────────────

/// Cursor position within the viewport.
///
/// Only returned by [`Snapshot::cursor_viewport`] when the cursor is
/// actually within the viewport (`HAS_VALUE`). Otherwise the caller
/// gets `Ok(None)`.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct CursorViewport {
    pub x: u16,
    pub y: u16,
    pub wide_tail: bool,
}

// ── Colors ─────────────────────────────────────────────────────

/// Render-state color snapshot.
///
/// `palette` holds the current 256-color palette. mnml only reads indices
/// 0-15 (the ANSI palette) into its render grid.
#[derive(Debug, Clone)]
pub struct Colors {
    pub background: RgbColor,
    pub foreground: RgbColor,
    pub cursor: RgbColor,
    pub cursor_has_value: bool,
    pub palette: [RgbColor; 256],
}

// ── RenderState ────────────────────────────────────────────────

/// The libghostty-vt render state.
///
/// One per terminal, reused every frame. Each call to [`Self::update`]
/// returns a [`Snapshot`] scoped to the current frame — reads on it
/// (colors, iterators, cursor) become invalid on the next `update`.
pub struct RenderState<'alloc> {
    handle: sys::GhosttyRenderState,
    _marker: PhantomData<&'alloc ()>,
}

impl<'alloc> RenderState<'alloc> {
    /// Create a render state with the default allocator.
    pub fn new() -> Result<Self, Error> {
        let mut handle: sys::GhosttyRenderState = ptr::null_mut();
        // SAFETY: NULL allocator → default.
        let r = unsafe { sys::ghostty_render_state_new(ptr::null(), &mut handle) };
        check(r)?;
        Ok(RenderState {
            handle,
            _marker: PhantomData,
        })
    }

    /// Refresh the state from the terminal and return a [`Snapshot`]
    /// scoped to this frame.
    pub fn update<'rs>(&'rs mut self, term: &Terminal<'_, '_>) -> Result<Snapshot<'rs>, Error> {
        // SAFETY: both handles are valid.
        let r = unsafe { sys::ghostty_render_state_update(self.handle, term.as_raw()) };
        check(r)?;
        Ok(Snapshot {
            handle: self.handle,
            _marker: PhantomData,
        })
    }
}

impl Drop for RenderState<'_> {
    fn drop(&mut self) {
        // SAFETY: handle owned by us; ghostty accepts NULL safely too.
        unsafe {
            sys::ghostty_render_state_free(self.handle);
        }
    }
}

// ── Snapshot ───────────────────────────────────────────────────

/// A live view into the render state after `update`. All reads through
/// the snapshot and its iterators must complete before the next
/// `RenderState::update`.
pub struct Snapshot<'rs> {
    handle: sys::GhosttyRenderState,
    _marker: PhantomData<&'rs mut ()>,
}

impl<'rs> Snapshot<'rs> {
    /// Read the current dirty state.
    pub fn dirty(&self) -> Result<Dirty, Error> {
        let mut out = MaybeUninit::<sys::GhosttyRenderStateDirty>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_DIRTY,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() }.into())
    }

    /// Reset the dirty state (typically to `Clean` after rendering a frame).
    ///
    /// Takes `&self`, not `&mut self`: the underlying C call mutates
    /// ghostty's state via the handle, but from Rust's borrow-checker
    /// view we're passing a pointer through. Callers that need
    /// exclusive access wrap the render state in a `RefCell`.
    pub fn set_dirty(&self, d: Dirty) -> Result<(), Error> {
        let val: sys::GhosttyRenderStateDirty = d.into();
        let r = unsafe {
            sys::ghostty_render_state_set(
                self.handle,
                sys::GhosttyRenderStateOption::GHOSTTY_RENDER_STATE_OPTION_DIRTY,
                &val as *const _ as *const _,
            )
        };
        check(r)
    }

    /// Whether the terminal thinks its cursor should be visible right
    /// now (respects DEC-mode 25 + any `visible` overrides ghostty
    /// applies internally).
    pub fn cursor_visible(&self) -> Result<bool, Error> {
        let mut out = MaybeUninit::<bool>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() })
    }

    /// Cursor position in viewport coordinates, or `None` if the cursor
    /// isn't currently inside the viewport.
    pub fn cursor_viewport(&self) -> Result<Option<CursorViewport>, Error> {
        let mut has_value = MaybeUninit::<bool>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
                has_value.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        if !unsafe { has_value.assume_init() } {
            return Ok(None);
        }
        let mut x = MaybeUninit::<u16>::uninit();
        let mut y = MaybeUninit::<u16>::uninit();
        let mut wide_tail = MaybeUninit::<bool>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
                x.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
                y.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        let r = unsafe {
            sys::ghostty_render_state_get(
                self.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL,
                wide_tail.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(Some(CursorViewport {
            x: unsafe { x.assume_init() },
            y: unsafe { y.assume_init() },
            wide_tail: unsafe { wide_tail.assume_init() },
        }))
    }

    /// Render-state colors: default fg/bg + explicit cursor color + the
    /// active 256-color palette.
    pub fn colors(&self) -> Result<Colors, Error> {
        let mut c = MaybeUninit::<sys::GhosttyRenderStateColors>::zeroed();
        // The sized-struct ABI requires `size` be set before calling.
        unsafe { (*c.as_mut_ptr()).size = std::mem::size_of::<sys::GhosttyRenderStateColors>() };
        let r = unsafe { sys::ghostty_render_state_colors_get(self.handle, c.as_mut_ptr()) };
        check(r)?;
        let c = unsafe { c.assume_init() };
        let palette: [RgbColor; 256] = std::array::from_fn(|i| RgbColor::from(c.palette[i]));
        Ok(Colors {
            background: c.background.into(),
            foreground: c.foreground.into(),
            cursor: c.cursor.into(),
            cursor_has_value: c.cursor_has_value,
            palette,
        })
    }
}

// ── RowIterator + Row ──────────────────────────────────────────

/// Reusable row-iteration handle. Allocate once, `.update()` per frame.
pub struct RowIterator {
    handle: sys::GhosttyRenderStateRowIterator,
}

impl RowIterator {
    pub fn new() -> Result<Self, Error> {
        let mut handle: sys::GhosttyRenderStateRowIterator = ptr::null_mut();
        // SAFETY: NULL allocator → default.
        let r = unsafe { sys::ghostty_render_state_row_iterator_new(ptr::null(), &mut handle) };
        check(r)?;
        Ok(RowIterator { handle })
    }

    /// Attach the iterator to a snapshot. Reads on the returned
    /// [`RowIter`] are scoped to the snapshot — `next()` returns
    /// [`Row`]s that borrow the iterator.
    pub fn update<'i, 'rs>(
        &'i mut self,
        snapshot: &'i Snapshot<'rs>,
    ) -> Result<RowIter<'i>, Error> {
        let r = unsafe {
            sys::ghostty_render_state_get(
                snapshot.handle,
                sys::GhosttyRenderStateData::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                &mut self.handle as *mut _ as *mut _,
            )
        };
        check(r)?;
        Ok(RowIter {
            handle: self.handle,
            _marker: PhantomData,
        })
    }
}

impl Drop for RowIterator {
    fn drop(&mut self) {
        // SAFETY: handle owned by us.
        unsafe {
            sys::ghostty_render_state_row_iterator_free(self.handle);
        }
    }
}

/// Cursor over rows in a snapshot — lending iterator (each `next()`
/// returns a [`Row`] borrowed from `self`).
pub struct RowIter<'i> {
    handle: sys::GhosttyRenderStateRowIterator,
    _marker: PhantomData<&'i mut ()>,
}

impl<'i> RowIter<'i> {
    /// Advance to the next row. Returns `None` at end-of-rows.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<Row<'_>> {
        // SAFETY: valid iterator handle.
        let ok = unsafe { sys::ghostty_render_state_row_iterator_next(self.handle) };
        if ok {
            Some(Row {
                handle: self.handle,
                _marker: PhantomData,
            })
        } else {
            None
        }
    }
}

/// The current row of a [`RowIter`]. Query data via the methods; the
/// row invalidates when the iterator advances.
pub struct Row<'i> {
    handle: sys::GhosttyRenderStateRowIterator,
    _marker: PhantomData<&'i mut ()>,
}

impl<'i> Row<'i> {
    /// Whether ghostty considers this row dirty.
    pub fn dirty(&self) -> Result<bool, Error> {
        let mut out = MaybeUninit::<bool>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_row_get(
                self.handle,
                sys::GhosttyRenderStateRowData::GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(unsafe { out.assume_init() })
    }

    /// Set (or clear) this row's dirty bit. Takes `&self` — see
    /// [`Snapshot::set_dirty`] for the rationale.
    pub fn set_dirty(&self, dirty: bool) -> Result<(), Error> {
        // The set counterpart is on the row iterator's `_row_set`, not `_get`.
        let val: bool = dirty;
        let r = unsafe {
            sys::ghostty_render_state_row_set(
                self.handle,
                sys::GhosttyRenderStateRowOption::GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                &val as *const _ as *const _,
            )
        };
        check(r)
    }

    /// Access the raw row-iterator handle. Used to populate a
    /// [`CellIterator`].
    pub(crate) fn as_raw(&self) -> sys::GhosttyRenderStateRowIterator {
        self.handle
    }
}

// ── CellIterator + Cell ────────────────────────────────────────

/// Reusable per-row cell-iteration handle. `.update(&row)` populates it
/// with the row's cells; iterate with `.next()`.
pub struct CellIterator {
    handle: sys::GhosttyRenderStateRowCells,
}

impl CellIterator {
    pub fn new() -> Result<Self, Error> {
        let mut handle: sys::GhosttyRenderStateRowCells = ptr::null_mut();
        let r = unsafe { sys::ghostty_render_state_row_cells_new(ptr::null(), &mut handle) };
        check(r)?;
        Ok(CellIterator { handle })
    }

    /// Attach the iterator to a row. Reads on the returned [`CellIter`]
    /// are scoped to the row.
    pub fn update<'i>(&'i mut self, row: &'i Row<'_>) -> Result<CellIter<'i>, Error> {
        let r = unsafe {
            sys::ghostty_render_state_row_get(
                row.as_raw(),
                sys::GhosttyRenderStateRowData::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &mut self.handle as *mut _ as *mut _,
            )
        };
        check(r)?;
        Ok(CellIter {
            handle: self.handle,
            _marker: PhantomData,
        })
    }
}

impl Drop for CellIterator {
    fn drop(&mut self) {
        // SAFETY: handle owned by us.
        unsafe {
            sys::ghostty_render_state_row_cells_free(self.handle);
        }
    }
}

/// Cursor over cells in a row — lending iterator (`next()` returns a
/// [`Cell`] borrowed from `self`).
pub struct CellIter<'i> {
    handle: sys::GhosttyRenderStateRowCells,
    _marker: PhantomData<&'i mut ()>,
}

impl<'i> CellIter<'i> {
    /// Advance to the next cell. Returns `None` at end-of-row.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<Cell<'_>> {
        // SAFETY: valid handle.
        let ok = unsafe { sys::ghostty_render_state_row_cells_next(self.handle) };
        if ok {
            Some(Cell {
                handle: self.handle,
                _marker: PhantomData,
            })
        } else {
            None
        }
    }
}

/// Current cell of a [`CellIter`]. Query via the methods; each
/// invalidates on iterator advance.
pub struct Cell<'i> {
    handle: sys::GhosttyRenderStateRowCells,
    _marker: PhantomData<&'i mut ()>,
}

impl<'i> Cell<'i> {
    /// Get the raw cell handle (a `u64` packed value with typed queries
    /// in [`RawCell`]).
    pub fn raw_cell(&self) -> Result<RawCell, Error> {
        let mut out = MaybeUninit::<sys::GhosttyCell>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        Ok(RawCell(unsafe { out.assume_init() }))
    }

    /// Full SGR-derived style. `NoValue` is mapped to the default style.
    pub fn style(&self) -> Result<Style, Error> {
        let mut out = Style::default_sys();
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                &mut out as *mut _ as *mut _,
            )
        };
        check(r)?;
        Ok(out.into())
    }

    /// Resolved foreground color for this cell, or `None` if the cell
    /// doesn't have an explicit fg (renderer picks its default).
    pub fn fg_color(&self) -> Result<Option<RgbColor>, Error> {
        let mut out = MaybeUninit::<sys::GhosttyColorRgb>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                out.as_mut_ptr().cast(),
            )
        };
        match r {
            sys::GhosttyResult::GHOSTTY_SUCCESS => Ok(Some(unsafe { out.assume_init() }.into())),
            sys::GhosttyResult::GHOSTTY_INVALID_VALUE => Ok(None),
            other => Err(other.into()),
        }
    }

    /// Resolved background color for this cell, or `None`.
    pub fn bg_color(&self) -> Result<Option<RgbColor>, Error> {
        let mut out = MaybeUninit::<sys::GhosttyColorRgb>::uninit();
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                out.as_mut_ptr().cast(),
            )
        };
        match r {
            sys::GhosttyResult::GHOSTTY_SUCCESS => Ok(Some(unsafe { out.assume_init() }.into())),
            sys::GhosttyResult::GHOSTTY_INVALID_VALUE => Ok(None),
            other => Err(other.into()),
        }
    }

    /// Return the cell's grapheme cluster as a sequence of `char`s.
    ///
    /// Uses ghostty's `GRAPHEMES_UTF8` query which uniformly handles
    /// single-codepoint cells + multi-codepoint clusters (emoji flags,
    /// combining marks). Returns `Ok(vec![])` for empty cells.
    ///
    /// mnml's typical usage is `.into_iter().collect::<String>()`.
    pub fn graphemes(&self) -> Result<Vec<char>, Error> {
        // Query 1: cap=0, ptr=null → GHOSTTY_OUT_OF_SPACE with the
        // required size in `len`. For empty cells the C API returns
        // SUCCESS with len=0.
        let mut buf = sys::GhosttyBuffer {
            ptr: std::ptr::null_mut(),
            cap: 0,
            len: 0,
        };
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                &mut buf as *mut _ as *mut _,
            )
        };
        match r {
            sys::GhosttyResult::GHOSTTY_SUCCESS => {
                // Empty cell.
                return Ok(Vec::new());
            }
            sys::GhosttyResult::GHOSTTY_OUT_OF_SPACE => {
                // Fall through — `buf.len` now holds the required cap.
            }
            other => return Err(other.into()),
        }

        let needed = buf.len;
        if needed == 0 {
            return Ok(Vec::new());
        }
        let mut bytes: Vec<u8> = vec![0u8; needed];
        let mut buf = sys::GhosttyBuffer {
            ptr: bytes.as_mut_ptr(),
            cap: needed,
            len: 0,
        };
        let r = unsafe {
            sys::ghostty_render_state_row_cells_get(
                self.handle,
                sys::GhosttyRenderStateRowCellsData::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                &mut buf as *mut _ as *mut _,
            )
        };
        check(r)?;
        bytes.truncate(buf.len);
        // Ghostty encodes valid UTF-8; be defensive and use lossy on
        // the render path so a rogue byte never panics.
        Ok(String::from_utf8_lossy(&bytes).chars().collect())
    }
}
