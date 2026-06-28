//! Per-context key handlers, extracted from `src/tui/mod.rs`
//! (T-3 / T-4 of the file-split refactor — 2026-06-28).
//!
//! Each `handle_*_key` function takes `&mut App` + `KeyEvent` and
//! dispatches the keystroke to the appropriate App method. The
//! handlers are stateless — all state lives on `App` — so moving them
//! between files is a pure mechanical relocation.

pub mod overlay;
pub mod pane;
