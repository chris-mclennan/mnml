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
                "view.toggle_input_style",
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
            try_it: vec![PaletteLink::new("git.branch_picker", "Switch branch")],
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
            try_it: vec![PaletteLink::new(
                "ai.agents_dashboard",
                "Open agents dashboard",
            )],
            ..Default::default()
        }),
        StatuslineWorkspace => Some(InfoViewCopy {
            title: "Active workspace".into(),
            body: "The root folder mnml is scoped to. When multiple workspaces are \
                   open, this shows the one containing the active pane's file."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+W", "Switch workspace")],
            try_it: vec![PaletteLink::new(
                "view.workspace_switcher",
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
            try_it: vec![PaletteLink::new("view.toggle_clock_utc", "Toggle UTC")],
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
        _ => None,
    }
}
