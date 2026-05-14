//! Git integration: the lightweight status snapshot (branch / ahead-behind /
//! change counts) for the statusline + tree tint (`status`), per-file gutter
//! line-signs and the diff pane with hunk stage/unstage (`diff`), per-line blame
//! for the gutter blame mode (`blame`), and `git commit` from inside the IDE
//! (`commit`).

pub mod blame;
pub mod branch;
pub mod commit;
pub mod diff;
pub mod graph;
pub mod log;
pub mod rail;
pub mod stage;
pub mod stash;
pub mod status;

pub use status::GitStatus;
