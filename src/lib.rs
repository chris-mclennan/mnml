// The LSP client builds a deeply-nested `serde_json::json!` literal for
// `initialize` capabilities; the macro can recurse past the default 128
// frames. 256 is comfortable.
#![recursion_limit = "256"]

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
pub mod azdevops;
pub mod bitbucket;
pub mod blit;
pub mod browser_pane;
pub mod buffer;
pub mod cdp;
pub mod cheatsheet;
pub mod clipboard;
pub mod command;
pub mod completion;
pub mod config;
pub mod context_menu;
pub mod dap;
pub mod e2e;
pub mod edit_op;
pub mod editor;
pub mod editorconfig;
pub mod flash;
pub mod focus;
pub mod formatter;
pub mod fuzzy;
pub mod git;
pub mod github;
pub mod gitlab;
pub mod grep_pane;
pub mod headless;
pub mod highlight;
pub mod hover;
pub mod http;
pub mod image;
pub mod input;
pub mod ipc;
pub mod layout;
pub mod linter;
pub mod lsp;
pub mod markdown_outline;
pub mod pane;
pub mod picker;
pub mod playwright;
pub mod prompt;
pub mod pty_pane;
pub mod regex_outline;
pub mod request_pane;
pub mod signature;
pub mod snippets;
#[cfg(feature = "private")]
pub mod private;
pub mod tools;
pub mod tree;
pub mod tui;
pub mod ui;
pub mod whichkey;

/// One clickable action inside the `Pane::GitGraph` WIP detail panel.
/// Click on a "Stage All" button ⇒ `StageAll`; click on a file row's
/// `[+]` ⇒ `StageFile(path)`. The corresponding rect lives on
/// `app.rects.wip_buttons` — the renderer pushes one entry per
/// painted button; `tui::dispatch_mouse` matches the click + fires
/// the action via `App::run_wip_action`.
#[derive(Debug, Clone)]
pub enum WipAction {
    /// `git add -A` (or equivalent) — stage every change at once.
    StageAll,
    /// `git reset` — unstage every staged file.
    UnstageAll,
    /// `git add <path>` — stage one file.
    StageFile(std::path::PathBuf),
    /// `git restore --staged <path>` — unstage one file.
    UnstageFile(std::path::PathBuf),
    /// Open the modal commit-message prompt (same as the `c` chord on
    /// the WIP row). Click the `Commit` button in the WIP detail's
    /// commit section.
    OpenCommitPrompt,
    /// Trigger AI commit-message generation (same as the `C` chord on
    /// the WIP row). Click the `AI Message` button in the WIP detail's
    /// commit section.
    RequestAiCommitMessage,
}
