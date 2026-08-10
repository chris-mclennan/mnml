//! Info View — the Ableton-style rich hover panel at the bottom of the
//! left panel. See `docs/design/info-view-v0.3.md` for the full design.
//!
//! Phase 1 framework — data model + describe fn + fallback ladder +
//! empty-state copy. The rich rendering pass (chord glyphs, `:cmd.id`
//! hyperlinks, `[[topic]]` doc links, `try_it` chips) is Phase 1.5.
//! For now `InfoViewCopy` exposes [`InfoViewCopy::to_flat_pair`] so
//! the existing `hover_help::draw` can consume Info View entries via
//! its current `(String, Option<String>)` feed while the model + copy
//! dictionary land.
//!
//! Copy lives in `info_view_copy.rs`, one function per entry, ordered
//! by section (chrome / menu bar / statusline / tree / integrations).
//! Add entries there; `describe_info_view` picks them up automatically
//! via the target-classifier match at the bottom of this file.

use crate::app::App;

/// Rich description of whatever the reader is asking about. Fields
/// mirror Ableton Live's Info View shape.
///
/// Note on the empty-state defaults: constructing an `InfoViewCopy`
/// with just `title` + `body` is the common case. Everything else
/// defaults to empty — no shortcuts, no `try_it`, no docs link.
#[derive(Debug, Clone, Default)]
pub struct InfoViewCopy {
    /// Title-bar text — the TOPIC. Rendered on its own row, bold,
    /// distinct bg. 40-70 chars ideal. Noun-phrase, never a
    /// paraphrase of the label (e.g. "Claude Code session", not
    /// "Session row").
    pub title: String,

    /// 2-4 sentence prose body. Word-wrapped. Empty string when the
    /// title is self-explanatory.
    pub body: String,

    /// Optional single-sentence caveat, rendered in italics after
    /// the body. "This is the default." / "Only visible when N ≥ 2."
    pub aside: Option<String>,

    /// Keyboard-shortcut hints. Rendered as `[Chord] Label` rows.
    /// Only list chords relevant to the hovered target — a tree row
    /// shows tree-nav chords, not HTTP chords.
    pub shortcuts: Vec<ShortcutHint>,

    /// `Try it →` links rendered as underlined clickable text at the
    /// bottom. Clicking fires the palette command. 0-3 entries.
    /// Distinct from `shortcuts` — `try_it` is for actions the
    /// reader might want to take RIGHT NOW while hovering.
    pub try_it: Vec<PaletteLink>,

    /// Optional docs link — opens the corresponding manual page.
    /// e.g. `"https://mnml.sh/manual/hover-help"`.
    pub docs: Option<String>,
}

impl InfoViewCopy {
    /// Convenience: title + body only, no chords / try_it / docs.
    pub fn simple(title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            body: body.into(),
            ..Default::default()
        }
    }

    /// Legacy adaptor — flattens rich fields to the
    /// `(primary, secondary)` tuple `hover_help::draw` currently
    /// expects. `primary = title`, `secondary = body + aside + first
    /// couple of shortcuts joined`. Delete when Phase 1.5 lands the
    /// rich renderer.
    pub fn to_flat_pair(&self) -> (String, Option<String>) {
        let mut secondary = self.body.clone();
        if let Some(a) = &self.aside {
            if !secondary.is_empty() {
                secondary.push_str("  ");
            }
            secondary.push_str(a);
        }
        for s in self.shortcuts.iter().take(2) {
            if !secondary.is_empty() {
                secondary.push_str("  ");
            }
            secondary.push_str(&format!("[{}] {}", s.chord, s.label));
        }
        let secondary = if secondary.is_empty() {
            None
        } else {
            Some(secondary)
        };
        (self.title.clone(), secondary)
    }
}

#[derive(Debug, Clone)]
pub struct ShortcutHint {
    /// Human-readable chord — `"Ctrl+Alt+Drag"`, `"Ctrl+↑"`,
    /// `"double-click"`. Rendered in bracket-wrapped accent style.
    pub chord: String,

    /// Short label — what the chord does in this context.
    pub label: String,
}

impl ShortcutHint {
    pub fn new(chord: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            chord: chord.into(),
            label: label.into(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct PaletteLink {
    /// Palette command id — e.g. `"view.toggle_hover_help"`. Fired
    /// via `crate::command::run` on click.
    pub command_id: String,

    /// Clickable label — e.g. `"Hide this panel"`.
    pub label: String,
}

impl PaletteLink {
    pub fn new(command_id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            command_id: command_id.into(),
            label: label.into(),
        }
    }
}

/// Every class of thing the Info View can describe. Populated by the
/// existing hover / focus tracking — nothing changes about how mnml
/// DETECTS hover, only about what it SAYS.
///
/// Phase 1 covers `Chip` + `TreeRow` + `MenuItem` + `None`.
/// `EditorSymbol` lands in Phase 2 (LSP hover pipe).
#[derive(Debug, Clone)]
pub enum InfoViewTarget {
    /// Chrome chip (palette search, sidebar toggle, statusline mode,
    /// integration icon, etc.). Anchored by the `HoverChip` enum in
    /// `src/ui/tooltip.rs`.
    Chip(crate::HoverChip),

    /// Left-panel tree row — files, git, integrations, agents.
    /// Variant carries just the label so the copy fn can dispatch on
    /// extension / kind without pulling the whole `TreeRow` type in.
    TreeRow { label: String, is_dir: bool },

    /// Menu-bar row — `menu` = top-level word ("File" / "Edit" / …),
    /// `item` = the item text ("Save all" / "Toggle wrap" / …).
    MenuItem { menu: String, item: String },

    /// Editor-buffer symbol under cursor (LSP hover, Phase 2).
    #[allow(dead_code)]
    EditorSymbol { pane: usize, sym: String },

    /// Nothing under hover — empty-state copy.
    None,
}

/// Look up the copy for `target`, walking the fallback ladder:
///
///   1. Curated entry in `info_view_copy.rs` matching this target.
///   2. Auto-derived placeholder from source docstrings / palette
///      titles (Phase 1.5).
///   3. Empty-state copy (`empty_state_copy`) — never falls to
///      "raw id · state" noise.
pub fn describe_info_view(app: &App, target: InfoViewTarget) -> InfoViewCopy {
    if let Some(copy) = crate::ui::info_view_copy::lookup(app, &target) {
        return copy;
    }
    // Phase 1.5 will add auto-derived placeholder here.
    empty_state_copy(app)
}

/// Copy for "nothing under hover" — explains what the panel is, how
/// to hide it, and one interesting thing to try. Varies mildly by
/// focus so the reader is never staring at the same paragraph.
pub fn empty_state_copy(app: &App) -> InfoViewCopy {
    let (title, body) = match app.focus {
        crate::focus::Focus::Tree => (
            "Left panel",
            "Files, git, integrations, agents. Arrows or j/k walk rows; \
             Enter opens the selection.",
        ),
        crate::focus::Focus::RightPanel => (
            "Right panel",
            "Currently hosting outline / diagnostics / whatever you routed \
             here. Arrows walk rows; Enter jumps to the source.",
        ),
        crate::focus::Focus::BottomPanel => (
            "Bottom panel",
            "Docked pane host. Arrows walk rows; Ctrl+Shift+J hides.",
        ),
        crate::focus::Focus::Pane => (
            "Info view",
            "Hover a chip, tree row, menu item, or tab to see what it does. \
             This box replaces guessing.",
        ),
    };
    InfoViewCopy {
        title: title.into(),
        body: body.into(),
        shortcuts: vec![ShortcutHint::new(
            "Ctrl+Shift+P",
            "Open the command palette",
        )],
        try_it: vec![PaletteLink::new(
            "view.toggle_hover_help",
            "Hide this panel",
        )],
        ..Default::default()
    }
}
