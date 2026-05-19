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

/// One clickable button in the `Pane::GitGraph` top toolbar.
/// The toolbar's `(rect, pane_id, action)` entries land on
/// `app.rects.git_toolbar_buttons`; the mouse handler matches the
/// rect + fires via `App::run_git_toolbar_action`.
#[derive(Debug, Clone, Copy)]
pub enum GitToolbarAction {
    /// `git pull --ff-only`
    Pull,
    /// `git push` (auto `--set-upstream` on first push)
    Push,
    /// `git fetch --all --prune`
    Fetch,
    /// Open the branch picker (`git.checkout`)
    BranchPicker,
    /// Open the commit-message prompt (`git.commit`)
    Commit,
    /// Open the stash-push prompt (`git.stash`)
    Stash,
    /// `git stash pop` of the most-recent stash
    StashPop,
    /// Spawn a shell pty pane (`term.shell`)
    Terminal,
    /// Open the reflog picker — recovery surface for "I just rebased
    /// and lost a commit" flows.
    Reflog,
}

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
    /// commit section. When the WIP detail's inline textarea is
    /// available, the result fills the textarea instead of opening
    /// the modal `PromptKind::GitCommit` prompt.
    RequestAiCommitMessage,
    /// Wipe the inline commit-message textarea in the WIP detail.
    /// Click the `Clear` button next to `Commit` / `AI Message`.
    ClearCommitDraft,
}

/// One clickable action on the `Pane::Diff` top toolbar. The
/// corresponding rect lives on `app.rects.diff_toolbar_buttons`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffToolbarAction {
    /// Switch the diff to inline (unified) rendering.
    ViewInline,
    /// Switch to per-hunk collapsed rendering.
    ViewHunk,
    /// Switch to Splitumn side-by-side rendering.
    ViewSplit,
    /// Toggle line-wrap.
    ToggleWrap,
    /// Close the diff view — clears the embedded diff when shown
    /// inside a `Pane::GitGraph`, or closes the pane when standalone
    /// `Pane::Diff`. Bound to the `[×]` chip on the toolbar so the
    /// gesture is discoverable.
    Close,
}

/// Clickable chips painted on the right side of the `> GIT` rail header
/// row — one-click access to common git ops without expanding the section
/// or memorizing keyboard chords. Rects are registered on
/// `app.rects.rail_git_header_buttons`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitRailHeaderAction {
    /// Fetch from origin.
    Fetch,
    /// `git pull --ff-only`.
    Pull,
    /// `git push` (refuses without an upstream + falls back to set-upstream).
    Push,
    /// Stage every change (`git add -A` against the active repo).
    StageAll,
    /// Open the commit prompt (existing `git.commit`).
    Commit,
    /// Open the commit graph (existing `git.graph`).
    Graph,
}

/// Which clickable chip the mouse is currently hovering over. Drives the
/// 500ms-delayed tooltip overlay shown next to the chip — see
/// `App.hover_chip` + `ui::tooltip` + `HOVER_TOOLTIP_DELAY_MS`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoverChip {
    /// Statusline mode chip (EDIT / VIEW / TREE / INSERT / NORMAL / …).
    StatuslineMode,
    /// Statusline git-branch chip ( main +N …).
    StatuslineBranch,
    /// Statusline workspace / active-repo chip ( name).
    StatuslineWorkspace,
    /// Statusline clock chip (HH:MM or HH:MMZ).
    StatuslineClock,
    /// A `> GIT` rail-header chip (one per action enum).
    RailHeaderChip(GitRailHeaderAction),
}

/// One clickable per-hunk action chip in the Hunk view's header
/// row. The corresponding rect lives on
/// `app.rects.diff_hunk_buttons`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffHunkAction {
    /// Apply this hunk to the index (`git apply --cached`).
    Stage,
    /// Reverse-apply this hunk against the index (`git apply
    /// --cached --reverse`).
    Unstage,
    /// Reverse-apply this hunk against the working tree —
    /// destructive, prompts for confirmation in the dispatcher.
    Discard,
}
