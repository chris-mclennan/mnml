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
//! See `CLAUDE.md` for the full design.

pub mod ai;
pub mod app;
// `mod aws` was split out to the standalone mnml-aws-codebuild
// binary in 2026-06.
// `mod azdevops` was split out to the standalone mnml-forge-azdevops
// binary in 2026-06.
pub mod blit;
pub(crate) mod browser_pane;
pub(crate) mod buffer;
pub(crate) mod cdp;
pub(crate) mod cheatsheet;
pub(crate) mod clipboard;
pub(crate) mod command;
pub(crate) mod completion;
pub mod config;
pub(crate) mod context_menu;
pub(crate) mod dap;
pub mod e2e;
pub mod edit_op;
pub(crate) mod editor;
pub(crate) mod editorconfig;
pub mod family_catalog;
pub mod family_offer;
pub(crate) mod flash;
pub(crate) mod focus;
pub(crate) mod formatter;
pub(crate) mod fuzzy;
pub(crate) mod git;
// `mod github` was split out to the standalone mnml-forge-github
// binary in 2026-06.
// `mod gitlab` was split out to the standalone mnml-forge-gitlab
// binary in 2026-06.
pub(crate) mod grep_pane;
pub mod headless;
pub mod highlight;
pub(crate) mod hover;
pub mod http;
pub(crate) mod image;
pub(crate) mod input;
pub(crate) mod integration_detect;
pub mod ipc;
pub(crate) mod layout;
pub(crate) mod linter;
pub(crate) mod lsp;
pub(crate) mod markdown_outline;
pub(crate) mod mixr_host;
pub(crate) mod now_playing;
pub(crate) mod pane;
pub(crate) mod pane_host;
pub(crate) mod picker;
// `mod pipeline_log` was removed after the 2026-06 SCM split — no
// in-tree host populates it any more.
pub(crate) mod playwright;
pub(crate) mod prompt;
pub(crate) mod pty_pane;
pub(crate) mod regex_outline;
pub(crate) mod request_pane;
pub(crate) mod scm;
pub(crate) mod shell_prompt;
pub(crate) mod signature;
pub(crate) mod snippets;
pub(crate) mod tools;
pub(crate) mod tree;
pub mod tui;
pub mod ui;
pub mod update_apply;
pub mod update_check;
pub(crate) mod whichkey;

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
    /// Undo the last commit — `git reset --soft HEAD~1` (keeps the
    /// changes staged; never touches the working tree). The undone
    /// commit's hash is captured so `Redo` can re-point HEAD back.
    Undo,
    /// Re-apply the most recently undone commit — `git reset --soft`
    /// to the captured hash. No-op when the undo stack is empty.
    Redo,
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
    /// A bufferline tab (carries the pane id). Tooltip shows the full path
    /// + dirty state — `display_name()` is workspace-relative + truncated.
    BufferlineTab(crate::layout::PaneId),
    /// A diff toolbar chip (Hunk / Inline / Split / Wrap / Close).
    DiffToolbar(DiffToolbarAction),
    /// A fold-collapsed chip (`⋯ N hidden`) — tooltip explains click to expand.
    FoldChip,
    /// A code-lens chip (`⚡ <title>`) — tooltip shows the full title in case
    /// the rendered chip got truncated.
    CodeLensChip,
    StatuslineLsp,
    StatuslineWrap,
    StatuslineAutosave,
    StatuslineFilesize,
    StatuslineLnCol,
    /// Bufferline launcher-icon — the `usize` indexes
    /// `App.config.ui.launcher_icons`. Built-in defaults are
    /// `0 = Claude`, `1 = Codex`; users can replace / append via
    /// `[[ui.launcher_icon]]` in their config.
    LauncherIcon(usize),
    /// File-tree toolbar icon row at the top of the rail. The
    /// `&'static str` is the command id (e.g. `"file.new_folder"`)
    /// stored alongside the rect in `app.rects.tree_icon_buttons`.
    TreeIcon(&'static str),
    /// The primary workspace header (`> WORKSPACE-NAME`) — tooltip
    /// reveals the absolute path so the user can confirm which
    /// directory mnml actually opened in.
    WorkspaceHeader,
    /// An extra workspace header from `[[workspaces]]` — the `usize`
    /// indexes `App.extra_workspaces`.
    ExtraWorkspaceHeader(usize),
    /// One icon in the rail's INTEGRATIONS section — `usize` indexes
    /// `App.config.ui.integration_icons`.
    IntegrationIcon(usize),
    /// The bufferline `+` chip that opens a new tab. Discovered via
    /// the mouse-hunt finding "bufferline + new-tab has no tooltip"
    /// (2026-06-07 chrome hunt #288).
    BufferlineNewTab,
    /// The bufferline `●━` theme-toggle pill (handle-left / handle-
    /// right depending on whether `theme_toggle` is at the primary
    /// or secondary theme).
    BufferlineThemeToggle,
    /// The `×` / `●` close badge inside a bufferline tab. Carries
    /// the same PaneId as the tab — the tooltip mentions whether a
    /// click would save (dirty) or close (clean), matching the
    /// dirty-dot-doubles-as-save semantic that landed on the right-
    /// click menu in this batch.
    BufferlineTabClose(crate::layout::PaneId),
    /// The window-level close (top-right of the bufferline strip).
    /// Closes the whole mnml process via `app.quit`.
    BufferlineWindowClose,
}

/// One row in the F1 click-discovery overlay. Each variant maps to a list
/// of on-screen rects that the renderer flashes when the user clicks the
/// row in the panel. See `ui::discovery` + `App::discovery_flash`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryCategory {
    StatuslineMode,
    StatuslineBranch,
    StatuslineWorkspace,
    StatuslineClock,
    BufferlineTabs,
    RailGitHeader,
    EditorGutter,
    DiffToolbar,
    FoldChips,
    CodeLensChips,
    SplitDividers,
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
