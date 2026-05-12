//! Git integration. So far: the lightweight status snapshot (branch + change
//! counts) for the statusline + tree tint, and per-file gutter line-signs from
//! `git diff`. The rich-git track adds diff views, hunk staging, blame, commit.

pub mod diff;
pub mod status;

pub use status::GitStatus;
