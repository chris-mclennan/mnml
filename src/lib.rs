// The LSP client builds a deeply-nested `serde_json::json!` literal for
// `initialize` capabilities; the macro can recurse past the default 128
// frames. 256 is comfortable.
#![recursion_limit = "256"]
// `doc_lazy_continuation`: mnml's doc comments deliberately use aligned,
// non-indented continuation lines for module / keymap lists (see the crate
// docs below) — that house style is intentional, not a lint to chase.
// `type_complexity`: the UI layer carries some genuinely complex closure /
// tuple types (render callbacks, rect registries) where a `type` alias would
// hurt readability more than help.
#![allow(clippy::doc_lazy_continuation, clippy::type_complexity)]

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
// Port-back helpers from the retired `rqst` app (2026-06-19).
// `jwt`: claims-only JWT decoder; `auth`: bearer-token extraction
// from clipboard text; `cookies`: small cookie-jar helpers; `sse`:
// minimal Server-Sent Events parser (Anthropic/OpenAI streams).
pub mod auth;
pub mod cookie_jar;
pub mod cookies;
pub mod jwt;
pub mod sse;
pub mod websocket;
// `mod aws` was split out to the standalone mnml-aws-codebuild
// binary in 2026-06.
// `mod azdevops` was split out to the standalone mnml-forge-azdevops
// binary in 2026-06.
pub(crate) mod browser_pane;
pub(crate) mod buffer;
pub(crate) mod cdp;
pub(crate) mod cheatsheet;
pub(crate) mod claude_agents;
pub(crate) mod clipboard;
pub(crate) mod command;
pub(crate) mod completion;
pub mod config;
pub(crate) mod context_menu;
pub(crate) mod dap;
pub mod e2e;
pub(crate) mod ecs_runner;
pub(crate) mod ecs_runner_trigger;
pub mod edit_op;
pub(crate) mod editor;
pub(crate) mod editorconfig;
pub mod family_catalog;
pub(crate) mod flash;
pub(crate) mod focus;
pub(crate) mod formatter;
pub(crate) mod fuzzy;
pub(crate) mod git;
pub mod glyph_builder;
pub mod icon_catalog;
pub(crate) mod peek_overlay;
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
pub mod integration_manifest;
pub mod ipc;
pub(crate) mod layout;
pub(crate) mod linter;
pub(crate) mod lsp;
pub(crate) mod markdown_outline;
pub(crate) mod now_playing;
pub(crate) mod pane;
pub(crate) mod picker;
// `mod pipeline_log` was removed after the 2026-06 SCM split — no
// in-tree host populates it any more.
pub(crate) mod anthropic_api;
pub(crate) mod cloud_agent_run;
pub mod dock;
pub mod menu_bar;
pub(crate) mod mount;
pub(crate) mod mount_manifest;
pub(crate) mod new_cloud_agent_wizard;
pub(crate) mod new_cloud_run_wizard;
pub(crate) mod playwright;
pub(crate) mod prompt;
pub(crate) mod pty_pane;
pub(crate) mod regex_outline;
pub(crate) mod request_pane;
pub(crate) mod scm;
pub(crate) mod shell_prompt;
pub(crate) mod sibling_install;
pub(crate) mod signature;
pub(crate) mod snippets;
pub(crate) mod tools;
pub(crate) mod tree;
pub mod tui;
pub mod ui;
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
    /// Open the reflog picker — recovery surface for "I just rebased
    /// and lost a commit" flows.
    Reflog,
    /// `git fetch --all --prune` across every configured repo, then
    /// refresh the rail's branch / worktree / PR lists.
    RefreshRepos,
    /// Cycle the active repo when the workspace has multiple
    /// `[[workspaces]]` or detected git roots. Fires the
    /// `git.next_repo` palette command.
    SwitchRepo,
    /// Toggle the per-line blame gutter (`git.blame_toggle`).
    BlameToggle,
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
    /// 2026-06-21 — Claude Agents dashboard topbar chip. Carries
    /// the chip kind so the tooltip text can describe what each
    /// click cycles. Rect is stored in
    /// `app.rects.claude_agents_topbar_chips`.
    ClaudeAgentsTopbarChip(crate::ui::TopbarChipKind),
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
    /// A session-tab in the Sessions activity panel — Pty (Claude Code /
    /// Codex / shell) session. Tooltip shows a preview of the last few
    /// messages for Claude sessions; falls back to profile info for
    /// shells / Codex. (#12)
    SessionsTab(crate::layout::PaneId),
    /// Activity bar icon (left rail). Tooltip names the section.
    /// vscode-mouse-2026-06-10 SEV-3 #2.
    ActivityBarIcon(crate::app::ActivitySection),
    /// `♪ <track>` statusline now-playing chip. Tooltip names the
    /// source (mixr file / macOS Music / Spotify) + full track when
    /// the chip text is truncated.
    /// vscode-mouse-2026-06-10 SEV-3 #3.
    StatuslineNowPlaying,
    /// Palette-bar back-arrow chip (previous buffer in MRU order).
    /// vscode-mouse-2026-06-10 SEV-3 #4.
    PaletteBackButton,
    /// Palette-bar forward-arrow chip (next buffer in MRU order).
    PaletteForwardButton,
    /// Palette-bar dropdown chevron (opens the recents picker).
    PaletteDropdownButton,
    /// The H/V split-editor button at the right end of a tab strip
    /// (bufferline OR per-leaf strip). `SplitDir::Horizontal` → the
    /// side-by-side button; `SplitDir::Vertical` → the stacked button.
    SplitStripButton(crate::layout::SplitDir),
    /// The terminal-launch button at the right end of a tab strip
    /// (immediately left of the H/V buttons). Click opens a new
    /// shell in a split.
    SplitStripTermButton,
    /// AI launcher button at the right end of a per-leaf tab
    /// strip — opens Claude / Codex in a split.
    SplitStripAiButton,
    /// Palette-bar sidebar toggle (codicon layout-sidebar-left/off)
    /// — click fires view.toggle_tree (Ctrl+B).
    PaletteSidebarButton,
    /// Palette-bar right-panel toggle (mirror of sidebar). Click
    /// fires view.toggle_right_panel.
    PaletteRightPanelButton,
    /// A tab chip on the right-panel tab strip — carries the
    /// pane id of the hosted tab so the tooltip can show the
    /// full label and the pane's tab_title (e.g. file path /
    /// problem counts). v3 right-panel polish.
    RightPanelTab(crate::layout::PaneId),
    /// The `×` close button on the right-panel tab strip. Closes
    /// the active tab on click; tooltip explains which tab.
    RightPanelClose,
    /// Palette-bar search chip — the workspace name + magnifier.
    /// Click fires the command palette.
    PaletteSearchChip,
    /// Palette-bar `+` chip — opens integrations.add discovery.
    PaletteAddIntegration,
    /// Per-leaf split tab strip tab chip (`(rect, leaf_active,
    /// tab_pane)`). Stores the tab pane id for tooltip lookup
    /// (file path, dirty state, etc.).
    SplitTabChip(crate::layout::PaneId),
    /// Per-leaf split tab strip close badge.
    SplitTabClose(crate::layout::PaneId),
    /// Agents-panel header chip — type encodes which one (New
    /// session, from PR, or view toggle).
    AgentsPanelChip(AgentsPanelChipKind),
    /// Cloud Agents `+ New Cloud Run` button.
    CloudAgentsNewRunButton,
    /// Cloud Agent Run detail pane: auto-refresh interval cycler.
    CloudRunAutoRefresh,
    /// Cloud Agent Run detail pane: manual refresh chip.
    CloudRunRefresh,
    /// Activity-bar gear icon — opens settings menu.
    ActivityBarGear,
    /// Dock kebab (⋮) menu trigger.
    DockKebab,
    /// Dock empty-state `+ dock` chip.
    DockEmptyChip,
    /// Statusline play / pause chip (mixr controls).
    StatuslineMixrPlay,
    /// Statusline fast-forward chip (mixr controls).
    StatuslineMixrFfwd,
    /// Statusline test-runner chip — click focuses test output.
    StatuslineTestChip,
    /// qa-feature 2026-06-30 — a specific cell in the GitGraph
    /// pane's lane column. `pane_id` locates the pane;
    /// `commit_idx` is the index into the pane's `commits` vec
    /// (excluding the WIP virtual row); `lane_idx` is the column
    /// within the graph. Tooltip walks newer commits in the same
    /// lane to find the closest branch ref and displays it.
    GitGraphLane {
        pane_id: usize,
        commit_idx: usize,
        lane_idx: usize,
    },
    /// qa-feature 2026-07-01 — hover on a commit's subject cell
    /// in the GitGraph pane. Tooltip shows the full commit
    /// subject (unclipped) + author name. Useful when the pane
    /// is narrow enough that the subject truncates with `…`.
    GitGraphCommitMsg {
        pane_id: usize,
        commit_idx: usize,
    },
    /// #21 v5 — hover on one of the Request pane's top-bar
    /// chips (Method / Env / Send / Save / Clear / Code).
    /// Tooltip explains what the click does + notes right-
    /// click for the kebab menu.
    RequestTopBarChip(RequestTopBarChip),
    /// #21 v7 — hover on the `[▥ ▤]` split-orientation toggle
    /// chip on a Request pane. Tooltip names the current
    /// orientation + the alternative.
    RequestSplitToggle,
    /// #21 v8 — hover on the response bar's `copy` chip.
    RequestResponseCopy,
    /// #21 v8 — hover on the response bar's `wrap` chip.
    RequestResponseWrap,
    /// #21 v8 — hover on the response bar's `{ } Format` chip.
    RequestResponseFormat,
    /// #21 v9 — hover on the pending-undo chip. Tooltip explains
    /// the keyboard shortcut + shows what will be undone.
    PendingUndoChip,
    /// #21 v10 — hover on the inline `+` new-request chip on the
    /// bufferline (visible when at least one Request pane is
    /// open). Tooltip distinguishes it from the far-right `+`
    /// new-tab-page button.
    BufferlineNewRequest,
    /// #polish 2026-07-06 — hover on any scrollbar. Tooltip
    /// explains the click / drag behavior once (users often
    /// don't know the whole track is clickable).
    ScrollbarThumb,
}

/// Which top-bar chip on the Request pane was hovered. Kept
/// isolated from `HoverChip` for easier future extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestTopBarChip {
    Method,
    Env,
    Send,
    Save,
    Clear,
    Code,
}

/// Which Agents-panel header chip a `HoverChip::AgentsPanelChip`
/// references. Used by `tooltip::describe` to render the right
/// label without expanding the parent enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentsPanelChipKind {
    /// `+ New session` — opens a single Claude Code session.
    NewSession,
    /// `+ from PR` — opens the multi-PR wizard.
    FromPr,
    /// View toggle (workspace / status grouping).
    ViewToggle,
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
