//! Screen types — cell wide property, raw cell handle.
//!
//! `RawCell` wraps ghostty's opaque `GhosttyCell` (a `u64` packed value)
//! and exposes typed queries on it. The row-cells iterator in
//! [`crate::render`] hands out `Cell` views that can be turned into a
//! `RawCell` via [`Cell::raw_cell`].

use crate::error::{Error, check};
use libghostty_vt_sys as sys;
use std::mem::MaybeUninit;

/// Cell width property.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub enum CellWide {
    /// Not a wide character — cell width 1.
    Narrow,
    /// Wide character — cell width 2 (CJK, emoji, etc.).
    Wide,
    /// Spacer after a wide character — do not render.
    SpacerTail,
    /// Spacer at end of soft-wrapped line for a wide character.
    SpacerHead,
}

impl From<sys::GhosttyCellWide> for CellWide {
    fn from(w: sys::GhosttyCellWide) -> Self {
        match w {
            sys::GhosttyCellWide::GHOSTTY_CELL_WIDE_NARROW => CellWide::Narrow,
            sys::GhosttyCellWide::GHOSTTY_CELL_WIDE_WIDE => CellWide::Wide,
            sys::GhosttyCellWide::GHOSTTY_CELL_WIDE_SPACER_TAIL => CellWide::SpacerTail,
            sys::GhosttyCellWide::GHOSTTY_CELL_WIDE_SPACER_HEAD => CellWide::SpacerHead,
            _ => CellWide::Narrow,
        }
    }
}

/// Opaque cell handle — ghostty packs the full cell state into 64 bits.
///
/// Query typed data via the accessor methods, each of which calls
/// `ghostty_cell_get(kind, out)` under the hood.
///
/// The cell value is a bit-packed snapshot; it does NOT reference the
/// terminal or render-state and is safe to hold across render updates
/// (unlike row/cell iterators). But its semantics only make sense in
/// the context of the render state that produced it.
#[derive(Debug, Copy, Clone)]
pub struct RawCell(pub(crate) sys::GhosttyCell);

impl RawCell {
    /// The cell's wide property (narrow / wide / spacer).
    pub fn wide(&self) -> Result<CellWide, Error> {
        let mut out = MaybeUninit::<sys::GhosttyCellWide>::uninit();
        // SAFETY: we pass a valid out-ptr matching the CellWide output
        // type documented on GHOSTTY_CELL_DATA_WIDE.
        let r = unsafe {
            sys::ghostty_cell_get(
                self.0,
                sys::GhosttyCellData::GHOSTTY_CELL_DATA_WIDE,
                out.as_mut_ptr().cast(),
            )
        };
        check(r)?;
        // SAFETY: SUCCESS means the C API wrote a valid GhosttyCellWide.
        Ok(unsafe { out.assume_init() }.into())
    }

    /// Underlying opaque cell value. Exposed for advanced callers who
    /// need to interop with the sys-level API directly.
    pub fn as_raw(&self) -> sys::GhosttyCell {
        self.0
    }
}
