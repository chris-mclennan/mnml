//! `mnml-libghostty-vt` — safe wrapper around Ghostty's `libghostty-vt` C ABI.
//!
//! This crate covers the API surface mnml consumes: the [`Terminal`] +
//! its [`TerminalOptions`], the [`render`] state machine (with lending
//! row/cell iterators), plus the small value types in [`style`] and
//! [`screen`]. Advanced callers can reach the raw C bindings via
//! [`sys`].
//!
//! For everything not covered here (key encoding, mouse encoding, OSC
//! parsing, kitty graphics, selection APIs) drop down to `sys::` — the
//! raw bindings are complete.

#![allow(clippy::result_large_err)]

pub use libghostty_vt_sys as sys;

pub mod error;
pub mod render;
pub mod screen;
pub mod style;
pub mod terminal;

pub use error::Error;
pub use render::{
    Cell, CellIter, CellIterator, Colors, CursorViewport, Dirty, RenderState, Row, RowIter,
    RowIterator, Snapshot,
};
pub use screen::{CellWide, RawCell};
pub use style::{RgbColor, Style, Underline};
pub use terminal::{ScrollViewport, Terminal, TerminalOptions};
