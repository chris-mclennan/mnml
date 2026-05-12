//! Git integration. P0: just the lightweight status snapshot (branch + change
//! counts) for the statusline + tree tint. Later the rich-git track adds diff
//! views, hunk staging, blame, and commit — all in submodules here.

pub mod status;

pub use status::GitStatus;
