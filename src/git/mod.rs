//! Git integration: the lightweight status snapshot (branch / ahead-behind /
//! change counts) for the statusline + tree tint, per-file gutter line-signs and
//! the diff pane (`diff`), and per-line blame for the gutter blame mode
//! (`blame`). Still to come: commit from inside the IDE.

pub mod blame;
pub mod diff;
pub mod status;

pub use status::GitStatus;
