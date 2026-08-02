//! Error type + `GhosttyResult` → `Result` mapping.

use libghostty_vt_sys as sys;

/// Errors returned by the C API's `GhosttyResult` codes.
///
/// The variants mirror the C constants exactly. `NoValue` is not always
/// an error at the call site (e.g. `title()` returning "not set") — the
/// wrapper methods that convert `NoValue` to `Option::None` do so
/// explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    OutOfMemory,
    InvalidValue,
    OutOfSpace,
    NoValue,
    /// Any negative code we don't recognize (forward-compat).
    Unknown(i32),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::OutOfMemory => write!(f, "libghostty-vt: out of memory"),
            Error::InvalidValue => write!(f, "libghostty-vt: invalid value"),
            Error::OutOfSpace => write!(f, "libghostty-vt: out of space"),
            Error::NoValue => write!(f, "libghostty-vt: no value"),
            Error::Unknown(code) => write!(f, "libghostty-vt: unknown error {code}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<sys::GhosttyResult> for Error {
    fn from(r: sys::GhosttyResult) -> Self {
        match r {
            sys::GhosttyResult::GHOSTTY_OUT_OF_MEMORY => Error::OutOfMemory,
            sys::GhosttyResult::GHOSTTY_INVALID_VALUE => Error::InvalidValue,
            sys::GhosttyResult::GHOSTTY_OUT_OF_SPACE => Error::OutOfSpace,
            sys::GhosttyResult::GHOSTTY_NO_VALUE => Error::NoValue,
            other => Error::Unknown(other.0),
        }
    }
}

/// Convert a `GhosttyResult` to `Result<(), Error>`; `SUCCESS` is `Ok(())`.
#[inline]
pub(crate) fn check(r: sys::GhosttyResult) -> Result<(), Error> {
    if r == sys::GhosttyResult::GHOSTTY_SUCCESS {
        Ok(())
    } else {
        Err(r.into())
    }
}
