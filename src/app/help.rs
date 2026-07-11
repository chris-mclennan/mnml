//! Help overlay — auto-generated from the command registry + keymap.
//!
//! `view.help` (bound to `?` by default) opens a scrollable overlay
//! listing every command grouped by its `Command.group`, with the
//! currently-bound chord(s) on each row. The keymap drives the
//! displayed chord, so user `[keys.*]` overrides appear here without
//! the help text needing to be hand-maintained.
//!
//! State is just `scroll: usize`. Esc / `?` close it.
//!
//! The renderer lives at `src/ui/help_overlay.rs`.

use crate::command::registry;
use crate::input::keymap::Keymap;

/// `None` on `App.help_overlay` ⇒ overlay closed.
#[derive(Debug, Clone, Default)]
pub struct HelpOverlayState {
    /// First visible line in the rendered list. Bounded by the
    /// renderer when paging.
    pub scroll: usize,
    /// Section names currently collapsed (don't render their
    /// binding rows). Default: empty = all expanded. Per-session.
    pub collapsed: std::collections::HashSet<String>,
    /// #polish 2026-07-06 — case-insensitive substring filter over
    /// binding titles + chord strings + section names. Empty ⇒ show
    /// everything.
    pub query: String,
    /// `/` in the overlay focuses the input; typing appends; Esc
    /// clears + unfocuses. Mirrors the picker/settings filter idiom.
    pub filter_focused: bool,
}

/// One row in the help overlay — either a section header or a binding.
#[derive(Debug, Clone)]
pub enum HelpRow {
    Section(&'static str),
    Binding { keys: String, title: &'static str },
}

/// Build the displayed rows by walking the command registry, grouping
/// by `Command.group`, and resolving each command's currently-bound
/// chord(s) from `keymap`. Commands with no binding are still listed
/// (with an empty `keys` field) — they're reachable through the
/// palette / ex-commands.
pub fn build_help(keymap: &Keymap) -> Vec<HelpRow> {
    // Reverse the keymap: command id → list of chord-specs.
    let mut bindings: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    for (seq, id) in keymap.iter() {
        bindings
            .entry(id.to_string())
            .or_default()
            .push(crate::input::keymap::chord_seq_to_spec(seq));
    }
    for chords in bindings.values_mut() {
        chords.sort();
    }

    // design-critic round-3 finding #7 2026-07-11 — mode-chip
    // legend is only reachable via mouse hover. Prepend a "modes"
    // section so the ? overlay documents the color coding
    // + chip labels.
    let mut rows: Vec<HelpRow> = Vec::new();
    rows.push(HelpRow::Section("modes"));
    for (chip, meaning) in [
        ("NORMAL", "vim normal mode (red)"),
        ("INSERT", "vim/standard editable (green)"),
        ("VISUAL", "vim visual — charwise (purple)"),
        ("V-LINE", "vim visual — linewise (purple)"),
        ("V-BLOCK", "vim visual — block/column (purple)"),
        ("REPLACE", "vim replace mode (orange)"),
        ("TREE", "file tree focused (blue)"),
        ("VIEW", "read-only pane focused (cyan)"),
        ("EDIT", "standard mode editing (green)"),
        ("PANEL", "right side panel focused (cyan)"),
    ] {
        rows.push(HelpRow::Binding {
            keys: chip.to_string(),
            title: meaning,
        });
    }

    // Stable section order — the registry yields commands in source
    // order so the same group's commands cluster naturally. We just
    // emit a section header the first time a new group appears.
    let mut last_group: &str = "";
    for cmd in registry().all() {
        if cmd.group != last_group {
            rows.push(HelpRow::Section(cmd.group));
            last_group = cmd.group;
        }
        let keys = bindings
            .get(cmd.id)
            .map(|v| v.join(" · "))
            .unwrap_or_default();
        rows.push(HelpRow::Binding {
            keys,
            title: cmd.title,
        });
    }
    rows
}

impl crate::app::App {
    pub fn open_help_overlay(&mut self) {
        self.help_overlay = Some(HelpOverlayState::default());
    }

    pub fn close_help_overlay(&mut self) {
        self.help_overlay = None;
    }

    pub fn toggle_help_overlay(&mut self) {
        if self.help_overlay.is_some() {
            self.close_help_overlay();
        } else {
            self.open_help_overlay();
        }
    }

    pub fn help_scroll(&mut self, delta: isize) {
        if let Some(state) = self.help_overlay.as_mut() {
            let new = (state.scroll as isize + delta).max(0) as usize;
            state.scroll = new;
        }
    }

    /// Toggle the collapsed state of a help section by name. Used
    /// by the renderer's click handler.
    pub fn toggle_help_section(&mut self, name: &str) {
        if let Some(state) = self.help_overlay.as_mut() {
            if state.collapsed.contains(name) {
                state.collapsed.remove(name);
            } else {
                state.collapsed.insert(name.to_string());
            }
            // Reset scroll so the user doesn't lose their place when
            // the layout shifts.
            state.scroll = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    #[test]
    fn build_help_emits_section_headers_and_bindings() {
        let cfg = Config::default();
        let km = Keymap::build(&cfg);
        let rows = build_help(&km);
        // At least one section + one binding row.
        let sections = rows
            .iter()
            .filter(|r| matches!(r, HelpRow::Section(_)))
            .count();
        let bindings = rows
            .iter()
            .filter(|r| matches!(r, HelpRow::Binding { .. }))
            .count();
        assert!(sections > 0, "expected at least one section header");
        assert!(
            bindings > 10,
            "expected the command registry to be substantial"
        );
    }

    #[test]
    fn bindings_include_at_least_one_chord_for_keymapped_commands() {
        let cfg = Config::default();
        let km = Keymap::build(&cfg);
        let rows = build_help(&km);
        // Find any binding row whose `id` has a default key in the registry.
        let any_with_key = rows.iter().any(|r| match r {
            HelpRow::Binding { keys, .. } => !keys.is_empty(),
            _ => false,
        });
        assert!(
            any_with_key,
            "expected at least one binding row to have a chord"
        );
    }
}
