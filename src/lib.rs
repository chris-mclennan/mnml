//! mnml — a NvChad-style terminal IDE.
//!
//! Crate layout (P0 — the editor-shell skeleton; later tracks add modules):
//!   - `editor` / `edit_op` / `clipboard` — the text-editing core (operations, not keys).
//!   - `input`                            — the pluggable input layer (vim / standard keymaps).
//!   - `buffer` / `pane` / `layout` / `focus` / `app` — the open-thing + window state.
//!   - `command` / `config`               — the command registry + TOML config.
//!   - `tree` / `git`                     — the file-tree rail + git status.
//!   - `ui`                               — the (backend-agnostic) render path + theme + icons.
//!   - `tui` / `headless` / `ipc`         — the terminal event loop, the virtual-screen loop, the file-IPC channel.
//!
//! See `.local/PLAN.md` for the full design + roadmap.

pub mod app;
pub mod buffer;
pub mod clipboard;
pub mod command;
pub mod config;
pub mod edit_op;
pub mod editor;
pub mod focus;
pub mod fuzzy;
pub mod git;
pub mod headless;
pub mod input;
pub mod ipc;
pub mod layout;
pub mod pane;
pub mod picker;
pub mod tree;
pub mod tui;
pub mod ui;
