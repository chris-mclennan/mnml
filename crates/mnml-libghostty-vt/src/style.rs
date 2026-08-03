//! Style types: `RgbColor`, `Underline`, `Style`.
//!
//! These are plain value types — no FFI handles, no Drop. `From` impls
//! do the sys-crate conversions.

use libghostty_vt_sys as sys;

/// 24-bit RGB color. Layout matches the C struct exactly.
#[repr(C)]
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Default)]
pub struct RgbColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<sys::GhosttyColorRgb> for RgbColor {
    fn from(c: sys::GhosttyColorRgb) -> Self {
        RgbColor {
            r: c.r,
            g: c.g,
            b: c.b,
        }
    }
}

impl From<RgbColor> for sys::GhosttyColorRgb {
    fn from(c: RgbColor) -> Self {
        sys::GhosttyColorRgb {
            r: c.r,
            g: c.g,
            b: c.b,
        }
    }
}

/// Underline style. `None` means "no underline drawn".
///
/// mnml only checks `!= None` today; the other variants exist so the
/// wrapper is forward-compatible.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Default)]
pub enum Underline {
    #[default]
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

impl Underline {
    /// Ghostty stores `underline` on `GhosttyStyle` as a `c_int` whose
    /// value is one of `GHOSTTY_SGR_UNDERLINE_*`. Convert here.
    ///
    /// The `as _` on the wrapping call is deliberate: bindgen picks a
    /// different backing repr for `GhosttySgrUnderline` on Windows
    /// (`c_int`) vs. macOS/Linux (`c_uint`) — C compilers can choose
    /// signed or unsigned when all enum values fit either. Inference
    /// picks the right one.
    fn from_sgr_int(v: std::os::raw::c_int) -> Self {
        // `as _` picks c_uint on macOS/Linux (real cast) and c_int on
        // Windows (identity). Clippy would flag the identity case.
        #[allow(clippy::unnecessary_cast)]
        match sys::GhosttySgrUnderline(v as _) {
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_NONE => Underline::None,
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_SINGLE => Underline::Single,
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_DOUBLE => Underline::Double,
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_CURLY => Underline::Curly,
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_DOTTED => Underline::Dotted,
            sys::GhosttySgrUnderline::GHOSTTY_SGR_UNDERLINE_DASHED => Underline::Dashed,
            _ => Underline::None,
        }
    }
}

/// Cell style — the SGR-derived attributes for one cell.
///
/// mnml consumes: `bold`, `italic`, `inverse`, `underline` (checks
/// `underline != Underline::None`).
#[derive(Debug, Copy, Clone, Default)]
pub struct Style {
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub blink: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strikethrough: bool,
    pub overline: bool,
    pub underline: Underline,
}

impl From<sys::GhosttyStyle> for Style {
    fn from(s: sys::GhosttyStyle) -> Self {
        Style {
            bold: s.bold,
            italic: s.italic,
            faint: s.faint,
            blink: s.blink,
            inverse: s.inverse,
            invisible: s.invisible,
            strikethrough: s.strikethrough,
            overline: s.overline,
            underline: Underline::from_sgr_int(s.underline),
        }
    }
}

impl Style {
    /// Return the default `GhosttyStyle` — all flags off, no colors.
    /// Used to initialize an out-buffer before a `_get()` call.
    pub(crate) fn default_sys() -> sys::GhosttyStyle {
        let mut s = std::mem::MaybeUninit::<sys::GhosttyStyle>::zeroed();
        unsafe {
            let ptr = s.as_mut_ptr();
            (*ptr).size = std::mem::size_of::<sys::GhosttyStyle>();
            sys::ghostty_style_default(ptr);
            s.assume_init()
        }
    }
}
