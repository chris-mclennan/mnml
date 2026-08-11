//! Curated Info View copy — one entry per hover target.
//!
//! Seed set for Phase 1 alpha: ~10 entries covering the highest-hover
//! chrome + a couple examples per target class. The copy-writer agent
//! (see `.claude/agents/info-view-writer.md`, coming next) walks the
//! full 229 `HoverChip` variants + menu inventory + tree row classes
//! and fills in the remaining ~500 entries against the shape here.
//!
//! Style rules (see `docs/design/info-view-v0.3.md` §Voice guide for
//! the full guide):
//!
//! - Title = noun phrase, never a verb form. `"Vim insert mode"` /
//!   `"Claude Code session"`, not `"You are in insert mode"`.
//! - Body = 2-4 sentences, plain English, no jargon a non-power-user
//!   wouldn't recognise from context.
//! - Shortcuts list the 1-3 chords a user hovering THIS thing would
//!   most want to know. Not every chord that touches the target.
//! - `try_it` is 0-2 palette commands the reader might fire while
//!   hovering — actions, not navigation.

use crate::app::App;
use crate::ui::info_view::{InfoViewCopy, InfoViewTarget, PaletteLink, ShortcutHint};

/// Look up the curated copy for `target`. Returns `None` when nothing
/// matches — caller falls through to the auto-derived placeholder
/// (Phase 1.5) or empty-state copy.
pub fn lookup(_app: &App, target: &InfoViewTarget) -> Option<InfoViewCopy> {
    match target {
        InfoViewTarget::Chip(chip) => chip_copy(*chip),
        InfoViewTarget::TreeRow { label, is_dir } => tree_row_copy(label, *is_dir),
        InfoViewTarget::MenuItem { menu, item } => menu_item_copy(menu, item),
        InfoViewTarget::EditorSymbol { .. } => None,
        InfoViewTarget::None => None,
    }
}

// ── Chrome chips ────────────────────────────────────────────────────

fn chip_copy(chip: crate::HoverChip) -> Option<InfoViewCopy> {
    use crate::HoverChip::*;
    match chip {
        StatuslineMode => Some(InfoViewCopy {
            title: "Editor mode indicator".into(),
            body: "The current input handler's mode — NORMAL / INSERT / VISUAL / \
                   REPLACE for vim, or blank in standard mode. Also shows the \
                   focus scope when it's not on an editor pane (TREE / RIGHT / \
                   BOTTOM)."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Esc", "Leave the current mode (vim)"),
                ShortcutHint::new("Ctrl+E", "Cycle keyboard focus across panels"),
            ],
            try_it: vec![PaletteLink::new(
                "editor.toggle_keymap",
                "Swap vim ↔ standard input",
            )],
            ..Default::default()
        }),
        StatuslineBranch => Some(InfoViewCopy {
            title: "Active git branch".into(),
            body: "The branch checked out in the active repo, with unpushed / \
                   uncommitted counts appended. Click to open the branch picker."
                .into(),
            aside: Some(
                "In a multi-repo workspace, this tracks whichever repo owns the \
                 active pane's file."
                    .into(),
            ),
            // Drift fix (2026-08-11): `Ctrl+Shift+B` is bound to
            // `view.toggle_right_panel`, not the branch picker.
            // `git.branch_menu` has no chord — click-only for now.
            try_it: vec![PaletteLink::new("git.branch_menu", "Switch branch")],
            ..Default::default()
        }),
        StatuslineWrap => Some(InfoViewCopy {
            title: "Line-wrap toggle".into(),
            body: "Visual-wraps long lines at the pane's right edge. When on, \
                   horizontal scroll is forced to 0. Click to toggle; the setting \
                   persists across restarts."
                .into(),
            shortcuts: vec![ShortcutHint::new(":set wrap", "Turn wrap on")],
            try_it: vec![PaletteLink::new("view.toggle_wrap", "Toggle line wrap")],
            ..Default::default()
        }),
        StatuslineAiClaude => Some(InfoViewCopy {
            title: "Claude usage meter".into(),
            body: "Current 5-hour window's Claude quota (percent used, reset time). \
                   Hover to see the full breakdown as a rich tooltip. Click to pin \
                   the panel open."
                .into(),
            shortcuts: vec![ShortcutHint::new("Esc", "Dismiss pinned panel")],
            try_it: vec![
                PaletteLink::new("ai.usage", "Open the AI usage panel"),
                PaletteLink::new("ai.link_claude_token", "Re-link Claude token"),
            ],
            ..Default::default()
        }),
        StatuslineAiCodex => Some(InfoViewCopy {
            title: "Codex activity indicator".into(),
            body: "Live count of active Codex sessions. Click to open the agents \
                   dashboard filtered to Codex."
                .into(),
            try_it: vec![PaletteLink::new("ai.dashboard", "Open agents dashboard")],
            ..Default::default()
        }),
        StatuslineWorkspace => Some(InfoViewCopy {
            title: "Active workspace".into(),
            body: "The root folder mnml is scoped to. When multiple workspaces are \
                   open, this shows the one containing the active pane's file."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+O", "Switch workspace")],
            try_it: vec![PaletteLink::new(
                "view.switch_workspace",
                "Open workspace picker",
            )],
            ..Default::default()
        }),
        StatuslineClock => Some(InfoViewCopy {
            title: "Wall clock".into(),
            body: "Local time (or UTC if the trailing Z is showing). Click to \
                   toggle local ↔ UTC. Rendered from the render loop, so it lags \
                   at most one render tick."
                .into(),
            try_it: vec![PaletteLink::new("clock.menu", "Toggle UTC / hide clock")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_stress_meter
        StatuslineStress => Some(InfoViewCopy {
            title: "Render stress meter".into(),
            body: "4-block bar that fills as p95 frame render time climbs. \
                   Full bar means mnml is spending more than one frame per redraw \
                   — usually a giant buffer or a hot LSP. Hover for the numbers."
                .into(),
            aside: Some("Twin of the meter in the top-right cluster.".into()),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_stress_meter (top-right variant)
        PaletteStress => Some(InfoViewCopy {
            title: "Render stress meter".into(),
            body: "Mirror of the statusline stress meter, in the top-right \
                   chrome cluster. Fills as p95 frame time climbs. Hover for \
                   the raw numbers."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_lsp_chip
        StatuslineLsp => Some(InfoViewCopy {
            title: "LSP status".into(),
            body: "Diagnostics count for the active buffer's LSP server — \
                   errors and warnings only. Click to open the diagnostics pane."
                .into(),
            try_it: vec![PaletteLink::new("lsp.diagnostics", "Open diagnostics")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_autosave_chip
        StatuslineAutosave => Some(InfoViewCopy {
            title: "Autosave indicator".into(),
            body: "On when `[editor] autosave_secs` is nonzero. The delay writes \
                   dirty buffers to disk N seconds after the last keystroke."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_lncol_chip
        StatuslineLnCol => Some(InfoViewCopy {
            title: "Cursor position".into(),
            body: "Line and column of the cursor in the active buffer. Click to \
                   jump to a specific line via the palette."
                .into(),
            try_it: vec![PaletteLink::new("editor.goto_line", "Go to line…")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_filesize_chip
        StatuslineFilesize => Some(InfoViewCopy {
            title: "Buffer size".into(),
            body: "Byte count of the active buffer. Grows red when the file is \
                   large enough that highlight / LSP passes measurably lag."
                .into(),
            ..Default::default()
        }),
        // ── Statusline (fill batch 2026-08-11) ──────────────────────
        // src: src/ui/tooltip.rs::HoverChip::StatuslineFile,
        //      src/app/dispatch.rs (hit-test), src/tui/mouse/down_left.rs
        StatuslineFile => Some(InfoViewCopy {
            title: "Active file chip".into(),
            body: "Shows the active buffer's file name with a dirty dot when there \
                   are unsaved edits. Click to reveal it in the file tree; right- \
                   click for the buffer context menu."
                .into(),
            try_it: vec![PaletteLink::new("view.reveal_active", "Reveal in tree")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineDiagnostics
        StatuslineDiagnostics => Some(InfoViewCopy {
            title: "Diagnostics summary".into(),
            body: "Rolls the active buffer's LSP errors and warnings into one \
                   chip. Click to open the diagnostics panel and step through \
                   each one."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+M", "Open diagnostics")],
            try_it: vec![PaletteLink::new("lsp.diagnostics", "Open diagnostics")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineLanguage
        StatuslineLanguage => Some(InfoViewCopy {
            title: "Detected language".into(),
            body: "Names the language mnml picked for the active buffer, inferred \
                   from the file extension. This drives which syntax grammar and \
                   LSP server get attached — click for a toast confirming the \
                   source."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineSymbol
        StatuslineSymbol => Some(InfoViewCopy {
            title: "Enclosing-symbol crumb".into(),
            body: "Names the function, struct, or class that contains the \
                   cursor's current line — computed from a lightweight regex \
                   outline, not full LSP. Click to open the outline pane."
                .into(),
            try_it: vec![PaletteLink::new("outline.show", "Open outline")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslinePr
        StatuslinePr => Some(InfoViewCopy {
            title: "Pull request badge".into(),
            body: "Shows the open PR for the branch checked out in the active \
                   repo — host tag plus PR number. Click opens it in your \
                   browser."
                .into(),
            aside: Some("Only visible when the active branch has an open PR.".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMacroRec
        StatuslineMacroRec => Some(InfoViewCopy {
            title: "Macro-recording indicator".into(),
            body: "Appears while a vim macro is recording, naming the register \
                   it's recording into. Click stops the recording — the same \
                   effect as pressing `q`."
                .into(),
            try_it: vec![PaletteLink::new("vim.macro_toggle", "Stop recording")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineFind
        StatuslineFind => Some(InfoViewCopy {
            title: "Active find query".into(),
            body: "Shows the current in-buffer search term plus match position \
                   (N/M). Click reopens the find prompt so you can change the \
                   query."
                .into(),
            shortcuts: vec![ShortcutHint::new("n / N", "Next / previous match")],
            try_it: vec![PaletteLink::new("find.find", "Reopen find")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineSel
        StatuslineSel => Some(InfoViewCopy {
            title: "Selection size".into(),
            body: "Live char / byte / line count of the active selection. \
                   Updates as you extend or shrink it — a quick way to confirm \
                   exactly what a visual-mode yank or delete will touch."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineProgress
        StatuslineProgress => Some(InfoViewCopy {
            title: "LSP progress indicator".into(),
            body: "Surfaces the active language server's `$/progress` \
                   notifications — indexing, building, analyzing. Disappears \
                   once the server reports the task complete."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineBgTasks
        StatuslineBgTasks => Some(InfoViewCopy {
            title: "Background tasks".into(),
            body: "Count of tasks mnml is running off the main thread right now \
                   — LSP indexing, git fetches, HTTP sends, and similar async \
                   work. The spinner keeps it visibly alive so a busy workspace \
                   doesn't look frozen."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineAi
        StatuslineAi => Some(InfoViewCopy {
            title: "Inline suggestion pending".into(),
            body: "Shows while an AI inline-completion request is in flight for \
                   the active buffer. Clears automatically the moment the \
                   suggestion — or a timeout — lands."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineNowPlaying
        StatuslineNowPlaying => Some(InfoViewCopy {
            title: "Now-playing chip".into(),
            body: "Names the current track from mixr, Apple Music, or Spotify — \
                   whichever source is active. Click brings that source forward \
                   (or opens mixr when idle); right-click for a source menu."
                .into(),
            try_it: vec![PaletteLink::new("mixr.show", "Open mixr")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMixrPlay
        StatuslineMixrPlay => Some(InfoViewCopy {
            title: "Play / pause chip".into(),
            body: "Toggles playback for whichever source is currently active — \
                   pauses mixr over IPC, or sends an AppleScript playpause to \
                   Music / Spotify. Hidden entirely when nothing is playing."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMixrFfwd
        StatuslineMixrFfwd => Some(InfoViewCopy {
            title: "Skip chip".into(),
            body: "Advances playback — teleports to just before the next \
                   mix-out in mixr, or fires the next-track AppleScript command \
                   for Music / Spotify."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineTestChip
        StatuslineTestChip => Some(InfoViewCopy {
            title: "Test-run status".into(),
            body: "Appears once you've launched a test run this session — \
                   cargo / npm / pytest / go / Playwright — and stays until that \
                   pane closes. Click to jump straight to the test-output pane."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_new_tab
        // Drift fix (2026-08-11): `tab.new` opens a new TAB PAGE (a
        // vim-style workspace of splits), not a new empty buffer —
        // and its chord is `Ctrl+K n`, not `Ctrl+T` (reserved to
        // avoid colliding with VS Code's Ctrl+T workspace-symbols).
        BufferlineNewTab => Some(InfoViewCopy {
            title: "New tab page".into(),
            body: "Opens a fresh tab page — a new vim-style workspace of splits, \
                   separate from the buffers open on the current one. Switch \
                   between tab pages with `gt` / `gT`."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K n", "New tab page")],
            try_it: vec![PaletteLink::new("tab.new", "New tab page")],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_theme_toggle
        BufferlineThemeToggle => Some(InfoViewCopy {
            title: "Theme swap".into(),
            body: "Swaps between `[ui] theme` and `[ui] theme_toggle`. Right-click \
                   for the full theme list; left-click cycles the pair."
                .into(),
            try_it: vec![
                PaletteLink::new("theme.toggle", "Swap themes"),
                PaletteLink::new("theme.pick", "Pick a theme…"),
            ],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_tab — one row per open buffer/pane
        BufferlineTab(_) => Some(InfoViewCopy {
            title: "Bufferline tab".into(),
            body: "One tab per open pane. Click to focus; middle-click closes; \
                   drag to reorder. Dirty buffers show a `•` before the label."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Ctrl+PgUp/PgDn", "Prev / next buffer"),
                ShortcutHint::new("Ctrl+W", "Close active buffer"),
            ],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_tab_close
        BufferlineTabClose(_) => Some(InfoViewCopy {
            title: "Close tab".into(),
            body: "Closes this specific buffer. If it's dirty, mnml prompts \
                   before discarding. `Ctrl+Shift+T` reopens the last closed tab."
                .into(),
            try_it: vec![PaletteLink::new("tab.reopen", "Reopen last closed")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs — top-row integration chip
        IntegrationIcon(_) => Some(InfoViewCopy {
            title: "Integration chip".into(),
            body: "A sibling integration in the top-row palette bar (browser, \
                   Slack, etc.). Left-click to open its pane; right-click for \
                   remove / disable / configure."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_marketplace",
                "Marketplace…",
            )],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs::draw_search_chip
        PaletteSearchChip => Some(InfoViewCopy {
            title: "Command palette".into(),
            body: "The universal palette — every command mnml knows, searchable \
                   by name or id. Click to open; `Ctrl+Shift+P` also opens it."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+P", "Open palette")],
            try_it: vec![PaletteLink::new("palette", "Open now")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs — sidebar/right-panel toggle chips
        PaletteSidebarButton => Some(InfoViewCopy {
            title: "Sidebar toggle".into(),
            body: "Shows / hides the left panel (files, git, integrations, \
                   agents, HTTP, findings)."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+B", "Toggle sidebar")],
            try_it: vec![PaletteLink::new("view.toggle_tree", "Toggle now")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs
        PaletteRightPanelButton => Some(InfoViewCopy {
            title: "Right panel toggle".into(),
            body: "Shows / hides the right panel — hosts outline, diagnostics, \
                   or whatever route is currently pinned there."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+B", "Toggle")],
            try_it: vec![PaletteLink::new("view.toggle_right_panel", "Toggle now")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar back arrow
        PaletteBackButton => Some(InfoViewCopy {
            title: "Back (previous buffer)".into(),
            body: "Jumps to the previous buffer in MRU order — same as \
                   `Ctrl+PageUp`. Mirrors browser back/forward muscle memory \
                   for the bufferline."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageUp", "Previous buffer")],
            try_it: vec![PaletteLink::new("buffer.prev", "Go back")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar forward arrow
        PaletteForwardButton => Some(InfoViewCopy {
            title: "Forward (next buffer)".into(),
            body: "Jumps to the next buffer in MRU order — same as \
                   `Ctrl+PageDown`. Only does something once Back has moved you \
                   backward."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageDown", "Next buffer")],
            try_it: vec![PaletteLink::new("buffer.next", "Go forward")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar dropdown chevron
        PaletteDropdownButton => Some(InfoViewCopy {
            title: "Recent files dropdown".into(),
            body: "Opens the recent-files picker — every buffer touched this \
                   session, most-recent first. Same list as `Ctrl+R`, reachable \
                   by mouse."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+R", "Recent files")],
            try_it: vec![PaletteLink::new("picker.recent", "Open recent files")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar `+` chip
        PaletteAddIntegration => Some(InfoViewCopy {
            title: "Add integration".into(),
            body: "Opens the integrations Marketplace so you can enable a \
                   sibling tool (browser, Slack, AWS, …) as a chip in this bar. \
                   Right-click any installed chip later to disable or remove it."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_marketplace",
                "Open Marketplace",
            )],
            ..Default::default()
        }),
        // src: src/app/mod.rs::set_pending_undo / commit_pending_undo (#20)
        PendingUndoChip => Some(InfoViewCopy {
            title: "Pending-undo chip".into(),
            body: "Appears for 10 seconds after a destructive action mnml can \
                   reverse — closing a dirty tab, deleting a file, restoring an \
                   overwritten request. Click it (or the chord) to undo before \
                   it expires; the label names exactly what will be restored."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+Z", "Commit the pending undo")],
            ..Default::default()
        }),
        // src: src/ui/menu_bar.rs::draw_word — File/Edit/View/…/Help
        MenuBarWord(_) => Some(InfoViewCopy {
            title: "Menu bar word".into(),
            body: "Click to open its dropdown; hover to peek at the next one. \
                   Alt+<letter> from anywhere opens the same menu by keyboard."
                .into(),
            shortcuts: vec![ShortcutHint::new("Alt+<letter>", "Open by keyboard")],
            ..Default::default()
        }),
        // src: src/ui/activity_bar.rs — one row per section
        ActivityBarIcon(_) => Some(InfoViewCopy {
            title: "Activity-bar section".into(),
            body: "One of the sections that shares the left panel — Files, Git, \
                   Integrations, Agents, HTTP, Findings. Click to switch."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/activity_bar.rs::draw_gear
        ActivityBarGear => Some(InfoViewCopy {
            title: "Settings gear".into(),
            body: "Opens the mnml settings overlay — a scrollable list of every \
                   config key with inline pickers for each value."
                .into(),
            try_it: vec![PaletteLink::new("file.open_settings", "Open settings")],
            ..Default::default()
        }),
        // src: src/ui/claude_agents_view.rs::draw_topbar_chip
        AgentsPanelChip(_) => Some(InfoViewCopy {
            title: "Agents-dashboard filter chip".into(),
            body: "Filters the agents dashboard by source, workspace, or state. \
                   Click to toggle; the currently-active filters render bold."
                .into(),
            // Drift fix (2026-08-11): "ai.agents_dashboard" doesn't
            // resolve — the real id is "ai.dashboard" (matches the
            // StatuslineAiCodex entry above).
            try_it: vec![PaletteLink::new("ai.dashboard", "Open the dashboard")],
            ..Default::default()
        }),
        // src: src/ui/http_panel.rs L75-86 — top toolbar row has
        // exactly 2 chips: refresh + collapse-all. R12 api-workflow
        // SEV-3 correction: R11's rewrite overclaimed 4 actions
        // (search / new-request / collapse-all / refresh) and
        // pointed try_it at `http.new_request`, which has no button
        // in this cluster. Now index-aware.
        HttpToolbarChip(0) => Some(InfoViewCopy {
            title: "HTTP: refresh list".into(),
            body: "Rescan collections / files / envs / captured / mocks and rebuild \
                   the HTTP-panel caches. Same as the palette command."
                .into(),
            try_it: vec![PaletteLink::new("http.refresh", "Refresh HTTP list")],
            ..Default::default()
        }),
        HttpToolbarChip(1) => Some(InfoViewCopy {
            title: "HTTP: collapse / expand all sections".into(),
            body: "Fold every HTTP-panel section (FILES / RECENT / CAPTURED / ENVS / \
                   CHAINS / MOCKS / COLLECTIONS) closed, or expand them all when \
                   collapsed. Individual section headers still toggle one at a time."
                .into(),
            try_it: vec![PaletteLink::new(
                "http.toggle_collapse_all",
                "Toggle collapse-all",
            )],
            ..Default::default()
        }),
        HttpToolbarChip(_) => None,
        // src: src/ui/http_panel.rs — per-section mini icon-button
        // row (Filter / Refresh / Clear / New, one row per FILES /
        // RECENT / CAPTURED / etc. section). NOT the header row —
        // that has its own rects at `http_panel_section_headers`.
        // R11 api-workflow SEV-2 correction: was describing the
        // header/collapse behavior which lives elsewhere.
        HttpSectionChip(_) => Some(InfoViewCopy {
            title: "HTTP section mini-button".into(),
            body: "Filter / refresh / clear / new button for ONE section of the \
                   HTTP panel (FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS / \
                   COLLECTIONS). The header row above collapses the whole section."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs — top-right git toolbar cluster
        GitToolbarChip(_) => Some(InfoViewCopy {
            title: "Git toolbar chip".into(),
            body: "One-click git action — fetch, pull, push, stage-all, commit. \
                   Same actions live in `> GIT` rail headers and the palette."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/editor_view.rs — gutter fold indicator
        FoldChip => Some(InfoViewCopy {
            title: "Fold chip".into(),
            body: "Marks a foldable region in the gutter. Click to toggle open / \
                   closed; `za` in vim, `Ctrl+Shift+[` in standard."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("za", "Toggle fold (vim)"),
                ShortcutHint::new("Ctrl+Shift+[/]", "Fold / unfold (standard)"),
            ],
            try_it: vec![PaletteLink::new("editor.toggle_fold", "Toggle at cursor")],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_window_close
        BufferlineWindowClose => Some(InfoViewCopy {
            title: "Close window".into(),
            body: "Closes the mnml instance. If any buffer is dirty, mnml \
                   prompts before quitting; `Ctrl+Q` is the same action."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Q", "Quit")],
            try_it: vec![PaletteLink::new("app.quit", "Quit mnml")],
            ..Default::default()
        }),
        _ => None,
    }
}

// ── Tree rows ────────────────────────────────────────────────────────

fn tree_row_copy(label: &str, is_dir: bool) -> Option<InfoViewCopy> {
    if is_dir {
        return Some(InfoViewCopy {
            title: format!("{label}/"),
            body: "Directory. Enter or click to expand; walk the tree with arrows \
                   or j/k. Right-click for rename / cut / copy / new file."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Enter", "Expand / collapse"),
                ShortcutHint::new("E / C", "Expand-all / collapse-all recursively"),
            ],
            ..Default::default()
        });
    }
    // Language-specific file rows — the copy dictionary can fan out
    // per extension. Seed with the ones most Rust / TS / Python devs
    // hover daily; the writer agent adds the rest.
    // Case-insensitive extension match. `rsplit('.').next()` on a
    // dot-less filename like `Dockerfile` returns the WHOLE filename
    // capitalized — before we lowercased here, `"Dockerfile"` never
    // hit the `"dockerfile"` arm. R10 multilang SEV-2.
    let ext = label.rsplit('.').next()?.to_ascii_lowercase();
    // R10 multilang SEV-3 — `.d.ts` declaration files got the plain
    // TypeScript copy. Check the double-ext BEFORE falling to the
    // last-segment match.
    if label.to_ascii_lowercase().ends_with(".d.ts") {
        return Some(InfoViewCopy {
            title: format!("{label} — TypeScript declarations"),
            body: "`.d.ts` — TypeScript type declarations. No runtime code; \
                   describes the shape of a JS module for tsserver to consume. \
                   Editing here changes types, not behavior."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Enter", "Open in the active pane"),
                ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
            ],
            ..Default::default()
        });
    }
    // Filename-keyed rows — checked BEFORE the extension fall-through
    // so a file mnml's tree renderer icons by whole filename
    // (`src/ui/icons.rs::filename_icon`) gets copy that matches, not
    // the generic extension blurb (`package.json` deserves npm-manifest
    // copy, not generic "JSON data"). 2026-08-11 fill batch.
    if let Some(copy) = filename_row_copy(label) {
        return Some(copy);
    }
    let (lang, body): (&str, &str) = match ext.as_str() {
        "rs" => (
            "Rust source",
            "Compiled with cargo. Hover a symbol in the buffer for LSP info \
             (once the LSP has warmed up).",
        ),
        "ts" | "tsx" => (
            "TypeScript source",
            "TypeScript / TSX. LSP fires once tsserver is up — takes a few \
             seconds on first open of the workspace.",
        ),
        "py" => (
            "Python source",
            "Python. LSP via pyright once mnml detects a Python interpreter.",
        ),
        "md" | "mdx" => (
            "Markdown",
            "Rendered inline by default when `[ui] render_markdown = true`. \
             `:e path.md` opens the raw editor instead.",
        ),
        "toml" => (
            "TOML config",
            "TOML config file. No LSP; syntax-only highlighting.",
        ),
        "json" => (
            "JSON data",
            "JSON file. Syntax-only highlighting; use a `.http` or `.curl` file \
             to send this as a request body.",
        ),
        "go" => (
            "Go source",
            "Go. LSP fires once gopls is on PATH; module boundary comes from \
             the nearest `go.mod`.",
        ),
        "sh" | "bash" | "zsh" => (
            "Shell script",
            "POSIX / bash / zsh script. No LSP by default; `:!chmod +x` on a new \
             script makes it executable.",
        ),
        "yaml" | "yml" => (
            "YAML config",
            "YAML config file. Indentation-sensitive — mnml paints trailing \
             whitespace red when `[ui] highlight_trailing_ws` is on.",
        ),
        "js" | "jsx" => (
            "JavaScript",
            "JavaScript / JSX. tsserver handles both TS and JS when it warms up, \
             so LSP hover works even without types.",
        ),
        "html" | "htm" => (
            "HTML markup",
            "HTML. No LSP; syntax-only highlighting. Pair with a `.http` file \
             next to it if this is a request-body template.",
        ),
        "css" | "scss" | "sass" => (
            "Stylesheet",
            "CSS / SCSS / SASS. Syntax-only highlighting; no LSP.",
        ),
        "sql" => (
            "SQL",
            "SQL script. Syntax-only highlighting; no linter. Run against a live \
             connection through your usual client — mnml doesn't execute.",
        ),
        "dockerfile" => (
            "Dockerfile",
            "Dockerfile. Syntax-only highlighting. `:!docker build .` from the \
             cmdline works if docker is on PATH.",
        ),
        // ── Top-20 tree-row languages (fill batch 2026-08-11) ────────
        // src: src/ui/icons.rs::extension_icon — grouped to match the
        // renderer's icon groupings so copy and icon stay 1:1.
        "vue" => (
            "Vue single-file component",
            "Vue 3 SFC — `<template>` / `<script>` / `<style>` blocks in one \
             file. Syntax-only highlighting; no dedicated LSP yet.",
        ),
        "svelte" => (
            "Svelte component",
            "Svelte single-file component — markup, script, and scoped styles \
             together. Syntax-only highlighting; no LSP.",
        ),
        "c" => (
            "C source",
            "C source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "cpp" => (
            "C++ source",
            "C++ source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "h" | "hpp" => (
            "C/C++ header",
            "Declarations only, no implementation. Syntax-only highlighting; \
             no LSP.",
        ),
        "java" => (
            "Java source",
            "Java source file. Syntax-only highlighting; no LSP (jdtls isn't \
             wired in yet).",
        ),
        "kt" => (
            "Kotlin source",
            "Kotlin source file. Syntax-only highlighting; no LSP.",
        ),
        "swift" => (
            "Swift source",
            "Swift source file. Syntax-only highlighting; no LSP.",
        ),
        "cs" => (
            "C# source",
            "C# source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "csproj" => (
            "MSBuild project file",
            "References, target framework, and package refs for a .NET \
             project. XML under the hood; syntax-only highlighting.",
        ),
        "sln" => (
            "Visual Studio solution",
            "Groups one or more `.csproj` projects for Visual Studio or \
             `dotnet build`. Plain-text format; syntax-only highlighting.",
        ),
        "cshtml" => (
            "Razor page",
            "ASP.NET Razor page — HTML markup with embedded C# `@` blocks. \
             Syntax-only highlighting.",
        ),
        "razor" => (
            "Razor component",
            "Blazor Razor component — HTML markup with embedded C#. \
             Syntax-only highlighting.",
        ),
        "fs" => (
            "F# source",
            "F# source file. Syntax-only highlighting; no LSP.",
        ),
        "xml" => (
            "XML data",
            "XML markup. Syntax-only highlighting; no schema validation.",
        ),
        "svg" => (
            "SVG image",
            "Scalable vector graphic — technically XML, but mnml treats it as \
             an image. No inline preview; open it in a browser to see it \
             rendered.",
        ),
        "png" | "jpg" | "jpeg" | "gif" | "webp" => (
            "Image",
            "Raster image. mnml doesn't render pixels inline here — open it \
             in a browser or image viewer to see it.",
        ),
        "http" | "curl" | "rest" | "request" => (
            "HTTP request file",
            "mnml's own request format — method, URL, headers, and body in \
             one file. Opening it launches the Request pane UI instead of a \
             plain-text editor.",
        ),
        _ => return None,
    };
    Some(InfoViewCopy {
        title: format!("{label} — {lang}"),
        body: body.into(),
        shortcuts: vec![
            ShortcutHint::new("Enter", "Open in the active pane"),
            ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
        ],
        ..Default::default()
    })
}

/// Copy for tree rows keyed by their WHOLE filename rather than
/// extension — mirrors `src/ui/icons.rs::filename_icon`'s match set.
/// Checked before the extension fall-through in `tree_row_copy` so
/// `package.json` reads as an npm manifest, not generic "JSON data".
/// Case-insensitive on the filename (matches the icon lookup).
fn filename_row_copy(label: &str) -> Option<InfoViewCopy> {
    let (lang, body): (&str, &str) = match label.to_ascii_lowercase().as_str() {
        "package.json" => (
            "npm manifest",
            "Declares this package's dependencies, scripts, and metadata for \
             npm / pnpm / yarn. Syntax-only highlighting; no schema \
             validation. `npm run <script>` from a terminal pane runs \
             anything listed under `scripts`.",
        ),
        "dockerfile" => (
            "Dockerfile",
            "Defines how `docker build` assembles an image — base layer, \
             copied files, entrypoint. Syntax-only highlighting. \
             `:!docker build .` from the cmdline works if docker is on PATH.",
        ),
        ".env" => (
            "Environment variables",
            "Untracked key=value pairs the process reads at startup. This is \
             separate from mnml's own `{{VAR}}` substitution, which reads \
             `.mnml/env/<name>.env` in Request panes. Treat this file as \
             secrets — keep it out of git.",
        ),
        "makefile" => (
            "Build recipes",
            "Defines named targets (`make build`, `make test`, …) as shell \
             recipes. Tab-indentation is significant — a space where a tab \
             is expected is the #1 Makefile syntax error. No LSP; \
             syntax-only highlighting.",
        ),
        _ => return None,
    };
    Some(InfoViewCopy {
        title: format!("{label} — {lang}"),
        body: body.into(),
        shortcuts: vec![
            ShortcutHint::new("Enter", "Open in the active pane"),
            ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
        ],
        ..Default::default()
    })
}

// ── Menu-bar items ───────────────────────────────────────────────────

fn menu_item_copy(menu: &str, item: &str) -> Option<InfoViewCopy> {
    match (menu, item) {
        ("View", i) if i.contains("wrap") || i.contains("Wrap") => Some(InfoViewCopy {
            title: "View → Toggle line wrap".into(),
            body: "Turns visual line-wrapping on/off for editor panes. Persists to \
                   `[ui] wrap` in your user config."
                .into(),
            try_it: vec![PaletteLink::new("view.toggle_wrap", "Toggle now")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Go to definition") => Some(InfoViewCopy {
            title: "Go → Go to definition".into(),
            body: "Jumps the cursor to where the symbol under the cursor is \
                   defined. Uses the active pane's LSP; falls back to a plain-text \
                   grep if no LSP is up."
                .into(),
            shortcuts: vec![ShortcutHint::new("gd", "Vim shortcut")],
            try_it: vec![
                PaletteLink::new("lsp.goto_definition", "Go to"),
                PaletteLink::new("lsp.peek_definition_overlay", "Peek instead"),
            ],
            ..Default::default()
        }),
        // src: src/menu_bar.rs — File menu
        ("File", i) if i.contains("New file") => Some(InfoViewCopy {
            title: "File → New file".into(),
            body: "Opens an untitled buffer in a fresh tab. Save it with `Ctrl+S` \
                   — mnml prompts for a path on first save."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+N", "New file")],
            try_it: vec![PaletteLink::new("file.new", "New file")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Open") && !i.contains("recent") => Some(InfoViewCopy {
            title: "File → Open…".into(),
            body: "Opens the file picker over the workspace. Type to fuzzy-match; \
                   Enter opens in the active pane, `Ctrl+Enter` opens in a split."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+P", "Open picker")],
            try_it: vec![PaletteLink::new("picker.files", "Open picker")],
            ..Default::default()
        }),
        // Drift fix (2026-08-11): menu labels carry a glyph prefix
        // (`"\u{F0193}  Save"`), so `i == "Save"` never matched and
        // `i.contains("Save ")` only matched "Save all" (which the
        // old guard then excluded) — this arm was dead code. Anchor
        // on the leading space instead so it survives the glyph.
        ("File", i) if i.contains(" Save") && !i.contains("all") => Some(InfoViewCopy {
            title: "File → Save".into(),
            body: "Writes the active buffer to disk. Untitled buffers prompt \
                       for a path first."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+S", "Save")],
            try_it: vec![PaletteLink::new("file.save", "Save now")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Save all") => Some(InfoViewCopy {
            title: "File → Save all".into(),
            body: "Writes every dirty buffer to disk in one pass. Untitled \
                   buffers get skipped (they'd need a path prompt each)."
                .into(),
            try_it: vec![PaletteLink::new("file.save_all", "Save all")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Quit") => Some(InfoViewCopy {
            title: "File → Quit".into(),
            body: "Closes mnml. If any buffer is dirty, mnml prompts before \
                   discarding — `:qa!` force-quits without prompt."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Q", "Quit")],
            try_it: vec![PaletteLink::new("app.quit", "Quit")],
            ..Default::default()
        }),
        // src: src/menu_bar.rs — Edit menu
        ("Edit", i) if i.contains("Find") && !i.contains("Replace") => Some(InfoViewCopy {
            title: "Edit → Find".into(),
            body: "Opens the find bar over the active buffer. Type to search; \
                   `n` / `N` step forward / back; Esc closes."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+F", "Find")],
            try_it: vec![PaletteLink::new("find.find", "Find in buffer")],
            ..Default::default()
        }),
        ("Edit", i) if i.contains("Replace") => Some(InfoViewCopy {
            title: "Edit → Replace".into(),
            body: "Opens the find + replace bar. Type the pattern, Tab to the \
                   replacement, Enter fires; `Ctrl+Alt+Enter` replaces all."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+H", "Replace")],
            ..Default::default()
        }),
        // Drift fix (2026-08-11): removed the `("Edit", "Undo")` arm
        // — the Edit menu has no Undo item (src/menu_bar.rs:207-224,
        // only Find/Replace variants). `editor.undo` exists as a
        // command but isn't on this menu; the arm never fired.
        // src: src/menu_bar.rs — View menu
        ("View", i) if i.contains("left panel") || i.contains("file tree") => Some(InfoViewCopy {
            title: "View → Toggle left panel".into(),
            body: "Shows / hides the left panel — files, git, integrations, \
                       agents, HTTP, findings all live there."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+B", "Toggle sidebar")],
            try_it: vec![PaletteLink::new("view.toggle_tree", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("bottom panel") => Some(InfoViewCopy {
            title: "View → Toggle bottom panel".into(),
            body: "Shows / hides the docked bottom-pane host. Pane content and \
                   height persist between toggles."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+J", "Toggle")],
            try_it: vec![PaletteLink::new("view.toggle_bottom_panel", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("hover-help") || i.contains("Hover") => Some(InfoViewCopy {
            title: "View → Toggle hover-help".into(),
            body: "Shows / hides this Info View — the panel at the bottom \
                       of the left rail. Setting persists across restarts."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.toggle_hover_help",
                "Hide this panel",
            )],
            ..Default::default()
        }),
        // src: src/menu_bar.rs — Window menu (fill batch 2026-08-11)
        ("Window", i) if i.contains("Reopen closed tab") => Some(InfoViewCopy {
            title: "Window → Reopen closed tab".into(),
            body: "Restores the most-recently-closed buffer, exactly where you \
                   left it. Repeatable — keep firing it to walk back further."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+T", "Reopen closed tab")],
            try_it: vec![PaletteLink::new("buffer.reopen", "Reopen")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Close other tabs") => Some(InfoViewCopy {
            title: "Window → Close other tabs".into(),
            body: "Closes every pane except the active one. Unsaved-changes \
                   guards still apply per-buffer, so a dirty tab prompts before \
                   it's discarded."
                .into(),
            try_it: vec![PaletteLink::new("view.close_others", "Close others")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Pin / unpin tab") => Some(InfoViewCopy {
            title: "Window → Pin / unpin tab".into(),
            body: "Pins the active tab so it sticks to the front of the \
                   bufferline instead of scrolling out of view. Pinned tabs \
                   also survive `Close other tabs`."
                .into(),
            try_it: vec![PaletteLink::new("buffer.pin_toggle", "Toggle pin")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Split right") => Some(InfoViewCopy {
            title: "Window → Split right".into(),
            body: "Splits the active pane side by side, opening the same \
                   buffer in both halves so you can scroll them independently."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+\\", "Split right")],
            try_it: vec![PaletteLink::new("view.split_right", "Split right")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Split down") => Some(InfoViewCopy {
            title: "Window → Split down".into(),
            body: "Splits the active pane top and bottom, opening the same \
                   buffer in both halves so you can scroll them independently."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+\\", "Split down")],
            try_it: vec![PaletteLink::new("view.split_down", "Split down")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Close split") => Some(InfoViewCopy {
            title: "Window → Close split".into(),
            body: "Closes the active split (or the active buffer, if there's \
                   only one split left) and hands its space to the remaining \
                   panes."
                .into(),
            try_it: vec![PaletteLink::new("view.close_split", "Close split")],
            ..Default::default()
        }),
        // "Equalize splits" — must not also catch "Auto-equalize on
        // split / close (toggle)" below; that item's label doesn't
        // contain this exact phrase.
        ("Window", i) if i.contains("Equalize splits") => Some(InfoViewCopy {
            title: "Window → Equalize splits".into(),
            body: "Resizes every split in the current tab page back to equal \
                   size in one shot. Same as vim's `Ctrl+W =`."
                .into(),
            try_it: vec![PaletteLink::new("view.equalize_splits", "Equalize")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Auto-equalize") => Some(InfoViewCopy {
            title: "Window → Auto-equalize splits (toggle)".into(),
            body: "When on, mnml automatically re-equalizes every split's size \
                   each time you split or close a pane, instead of leaving the \
                   ratio wherever it landed."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.toggle_auto_equalize_splits",
                "Toggle",
            )],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Merge splits into tabs") => Some(InfoViewCopy {
            title: "Window → Merge splits into tabs".into(),
            body: "Collapses the whole split tree in the current tab page into \
                   one leaf, keeping every pane as a tab there instead. \
                   Reversible with Spread tabs into splits."
                .into(),
            try_it: vec![PaletteLink::new("layout.merge_to_tabs", "Merge to tabs")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Spread tabs into splits") => Some(InfoViewCopy {
            title: "Window → Spread tabs into splits".into(),
            body: "Lays every tab in the active leaf out into its own split, \
                   using the same auto-tile heuristic as AI grid layout. \
                   Reversible with Merge splits into tabs."
                .into(),
            try_it: vec![PaletteLink::new(
                "layout.spread_to_splits",
                "Spread to splits",
            )],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Grow split width") => Some(InfoViewCopy {
            title: "Window → Grow split width".into(),
            body: "Widens the active split at its neighbors' expense. Same as \
                   vim's `Ctrl+W >`; repeatable."
                .into(),
            try_it: vec![PaletteLink::new("view.split_grow_width", "Grow width")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Grow split height") => Some(InfoViewCopy {
            title: "Window → Grow split height".into(),
            body: "Grows the active split's height at its neighbors' expense. \
                   Same as vim's `Ctrl+W +`; repeatable."
                .into(),
            try_it: vec![PaletteLink::new("view.split_grow_height", "Grow height")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split left") => Some(InfoViewCopy {
            title: "Window → Focus split left".into(),
            body: "Moves keyboard focus to the split immediately to the left \
                   of the active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Left", "Focus left")],
            try_it: vec![PaletteLink::new("view.focus_left", "Focus left")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split right") => Some(InfoViewCopy {
            title: "Window → Focus split right".into(),
            body: "Moves keyboard focus to the split immediately to the right \
                   of the active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Right", "Focus right")],
            try_it: vec![PaletteLink::new("view.focus_right", "Focus right")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split up") => Some(InfoViewCopy {
            title: "Window → Focus split up".into(),
            body: "Moves keyboard focus to the split immediately above the \
                   active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Up", "Focus up")],
            try_it: vec![PaletteLink::new("view.focus_up", "Focus up")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split down") => Some(InfoViewCopy {
            title: "Window → Focus split down".into(),
            body: "Moves keyboard focus to the split immediately below the \
                   active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Down", "Focus down")],
            try_it: vec![PaletteLink::new("view.focus_down", "Focus down")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("AI layout: Grid") => Some(InfoViewCopy {
            title: "Window → AI layout: Grid".into(),
            body: "Switches open Claude / Codex sessions to an auto-tiled grid \
                   of splits (up to 8) instead of stacking them as tabs in one \
                   leaf."
                .into(),
            try_it: vec![PaletteLink::new("view.ai_layout_grid", "Switch to grid")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("AI layout: Tabs") => Some(InfoViewCopy {
            title: "Window → AI layout: Tabs".into(),
            body: "Switches open Claude / Codex sessions to append as tabs in \
                   the active leaf instead of tiling each one into its own \
                   split."
                .into(),
            try_it: vec![PaletteLink::new("view.ai_layout_tabs", "Switch to tabs")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Restart mnml") => Some(InfoViewCopy {
            title: "Window → Restart mnml".into(),
            body: "Rebuilds and relaunches mnml via `run.sh`'s restart loop, \
                   re-reading source + config from disk. Prompts first if any \
                   buffer is dirty."
                .into(),
            try_it: vec![PaletteLink::new("app.restart", "Restart now")],
            ..Default::default()
        }),
        _ => None,
    }
}
