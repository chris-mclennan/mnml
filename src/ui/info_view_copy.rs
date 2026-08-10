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
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+B", "Focus branch picker")],
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
        // src: src/ui/bufferline.rs::draw_new_tab
        BufferlineNewTab => Some(InfoViewCopy {
            title: "New tab".into(),
            body: "Opens a new empty editor buffer in a fresh tab. Same effect as \
                   `Ctrl+T` or the palette's `tab.new`."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+T", "New tab")],
            try_it: vec![PaletteLink::new("tab.new", "New tab")],
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
            try_it: vec![PaletteLink::new(
                "ai.agents_dashboard",
                "Open the dashboard",
            )],
            ..Default::default()
        }),
        // src: src/ui/request_view.rs::draw_http_toolbar
        HttpToolbarChip(_) => Some(InfoViewCopy {
            title: "HTTP-panel toolbar chip".into(),
            body: "Filter / sort / refresh controls for the HTTP left-panel \
                   section. Click for actions; right-click for a fuller menu."
                .into(),
            try_it: vec![PaletteLink::new("http.refresh", "Refresh HTTP list")],
            ..Default::default()
        }),
        // src: src/ui/request_view.rs::draw_http_section_headers
        HttpSectionChip(_) => Some(InfoViewCopy {
            title: "HTTP section header".into(),
            body: "One of the FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS / \
                   COLLECTIONS section headers. Click to collapse / expand."
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
    let (lang, body): (&str, &str) = match label.rsplit('.').next()? {
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
        ("File", i) if i == "Save" || i.contains("Save ") && !i.contains("all") => {
            Some(InfoViewCopy {
                title: "File → Save".into(),
                body: "Writes the active buffer to disk. Untitled buffers prompt \
                       for a path first."
                    .into(),
                shortcuts: vec![ShortcutHint::new("Ctrl+S", "Save")],
                try_it: vec![PaletteLink::new("file.save", "Save now")],
                ..Default::default()
            })
        }
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
        ("Edit", "Undo") => Some(InfoViewCopy {
            title: "Edit → Undo".into(),
            body: "Reverts the last edit in the active buffer. Vim's `u`. \
                   `:earlier 5m` walks the history back by wall-clock time."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Z", "Undo")],
            ..Default::default()
        }),
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
        _ => None,
    }
}
