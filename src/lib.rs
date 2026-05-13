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

pub mod ai;
pub mod app;
pub mod browser_pane;
pub mod buffer;
pub mod cdp;
pub mod clipboard;
pub mod command;
pub mod completion;
pub mod config;
pub mod context_menu;
pub mod e2e;
pub mod edit_op;
pub mod editor;
pub mod focus;
pub mod fuzzy;
pub mod git;
pub mod grep_pane;
pub mod headless;
pub mod highlight;
pub mod hover;
pub mod http;
pub mod input;
pub mod ipc;
pub mod layout;
pub mod lsp;
pub mod markdown_outline;
pub mod pane;
pub mod picker;
pub mod playwright;
pub mod prompt;
pub mod pty_pane;
pub mod request_pane;
pub mod signature;
pub mod snippets;
pub mod tree;
pub mod tui;
pub mod ui;
pub mod whichkey;
