//! Browseable cheatsheet pane (NvCheatsheet analogue). Walks the live
//! `Keymap` + command registry and renders one row per `chord → command`
//! grouped by `Command::group`. `/` filters; ↑/↓ navigate; the pane is
//! read-only. Sibling to `:Maps`/`:Keys` (which toasts).

use std::collections::BTreeMap;

/// One row in the cheatsheet — a single chord binding.
#[derive(Debug, Clone)]
pub struct CheatsheetRow {
    pub chord: String,
    pub command_id: String,
    pub title: String,
}

/// One section in the cheatsheet — every chord whose target command shares
/// this group label.
#[derive(Debug, Clone)]
pub struct CheatsheetSection {
    pub group: String,
    pub rows: Vec<CheatsheetRow>,
}

#[derive(Debug, Clone, Default)]
pub struct CheatsheetPane {
    pub sections: Vec<CheatsheetSection>,
    /// Cursor row in the *flattened* row list (headers excluded — there's
    /// no useful action for selecting a header).
    pub selected: usize,
    pub scroll: usize,
    /// `/`-filter narrowing.
    pub query: String,
    pub filter_mode: bool,
    /// Group labels currently collapsed. When a group is collapsed
    /// its rows don't render and don't count toward `selected` /
    /// flattened-row math. `z` toggles the current row's group;
    /// `Z` collapses everything.
    pub collapsed: std::collections::HashSet<String>,
}

impl CheatsheetPane {
    /// Build a fresh cheatsheet from the active keymap + command registry.
    /// Sections are populated from chord bindings first; a trailing
    /// "(unbound)" group lists every registered command WITHOUT a
    /// chord so the pane functions as a discoverable command catalog
    /// (not just a chord reference).
    pub fn build(keymap: &crate::input::keymap::Keymap) -> Self {
        let reg = crate::command::registry();
        let mut grouped: BTreeMap<String, Vec<CheatsheetRow>> = BTreeMap::new();
        let mut bound_ids: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for (seq, id) in keymap.iter() {
            bound_ids.insert(id);
            let (group, title) = match reg.get(id) {
                Some(c) => (c.group.to_string(), c.title.to_string()),
                None => ("(unknown)".to_string(), id.to_string()),
            };
            grouped.entry(group).or_default().push(CheatsheetRow {
                chord: crate::input::keymap::chord_seq_to_spec(seq),
                command_id: id.to_string(),
                title,
            });
        }
        // 2026-06-21 multilang SEV-3: also add leader-chord bindings
        // from the whichkey trie. Was: leader chords (`<leader>Lct`
        // = `cargo.test` etc.) were dispatched by `whichkey.rs`
        // separately from the `Keymap` and didn't appear in
        // `keymap.iter()`, so all leader-only commands fell into
        // `(unbound)` — bloating it AND lying to the user about what
        // they could chord-reach.
        for (chord_path, id) in crate::whichkey::enumerate_leaves() {
            // String id-owned: stash in bound_ids via a leaked &'static
            // is overkill; track owned in a parallel set.
            if reg.get(id).is_some() {
                let owned: &'static str = id;
                bound_ids.insert(owned);
            }
            let (group, title) = match reg.get(id) {
                Some(c) => (c.group.to_string(), c.title.to_string()),
                None => continue,
            };
            grouped.entry(group).or_default().push(CheatsheetRow {
                chord: chord_path,
                command_id: id.to_string(),
                title,
            });
        }
        let mut sections: Vec<CheatsheetSection> = grouped
            .into_iter()
            .map(|(group, mut rows)| {
                rows.sort_by(|a, b| a.chord.cmp(&b.chord));
                CheatsheetSection { group, rows }
            })
            .collect();
        // Unbound section — every registered command not in the keymap.
        // 2026-06-20 — cheatsheet now doubles as a discoverable command
        // catalog (~300+ palette commands; many lack chords).
        let unbound: Vec<CheatsheetRow> = reg
            .all()
            .iter()
            .filter(|c| !bound_ids.contains(c.id))
            .map(|c| CheatsheetRow {
                chord: "·".to_string(),
                command_id: c.id.to_string(),
                title: c.title.to_string(),
            })
            .collect();
        if !unbound.is_empty() {
            let mut rows = unbound;
            rows.sort_by(|a, b| a.command_id.cmp(&b.command_id));
            sections.push(CheatsheetSection {
                group: "(unbound)".to_string(),
                rows,
            });
        }
        CheatsheetPane {
            sections,
            selected: 0,
            scroll: 0,
            query: String::new(),
            filter_mode: false,
            collapsed: std::collections::HashSet::new(),
        }
    }

    /// Total number of selectable (non-header) rows in the current filtered
    /// view. Used by the mouse click handler to clamp `selected`.
    pub fn visible_rows_len(&self) -> usize {
        self.visible_sections().iter().map(|s| s.rows.len()).sum()
    }

    /// Return the sections filtered by the current `/` query. Sections with
    /// no matching rows are omitted entirely; rows inside a kept section
    /// match against chord OR id OR title (case-insensitive substring).
    pub fn visible_sections(&self) -> Vec<CheatsheetSection> {
        // 2026-06-21 lsp-cheat-test SEV-2: was checking collapsed
        // BEFORE applying the filter, so `/save` couldn't surface
        // matches that lived inside a collapsed section AND
        // collapsed headers persisted with zero hits. Now: when a
        // text filter is active, ignore collapse — the user is
        // searching and they want everything in scope.
        let q = self.query.to_lowercase();
        let filter_active = !q.is_empty();
        self.sections
            .iter()
            .filter_map(|sec| {
                // Collapsed sections (no active filter) keep their
                // header but contribute zero rows.
                if !filter_active && self.collapsed.contains(&sec.group) {
                    return Some(CheatsheetSection {
                        group: sec.group.clone(),
                        rows: Vec::new(),
                    });
                }
                let rows: Vec<_> = if !filter_active {
                    sec.rows.clone()
                } else {
                    sec.rows
                        .iter()
                        .filter(|r| {
                            r.chord.to_lowercase().contains(&q)
                                || r.command_id.to_lowercase().contains(&q)
                                || r.title.to_lowercase().contains(&q)
                        })
                        .cloned()
                        .collect()
                };
                if rows.is_empty() && filter_active {
                    None
                } else {
                    Some(CheatsheetSection {
                        group: sec.group.clone(),
                        rows,
                    })
                }
            })
            .collect()
    }

    /// Group of the currently-selected row, derived by walking
    /// flattened rows. Used by `z` to toggle the right section.
    pub fn selected_group(&self) -> Option<String> {
        let mut idx = 0usize;
        for sec in self.visible_sections() {
            if sec.rows.is_empty() {
                continue;
            }
            if self.selected < idx + sec.rows.len() {
                return Some(sec.group);
            }
            idx += sec.rows.len();
        }
        None
    }

    /// Toggle the focused row's section in the collapsed set.
    /// 2026-06-21 lsp-cheat-test SEV-3 cheatsheet-Z-resets-selection:
    /// was dropping the user back to the top on every z / Z.
    /// Now clamps `selected` to the new visible-row count instead.
    pub fn toggle_collapsed_at_selection(&mut self) {
        if let Some(group) = self.selected_group() {
            if self.collapsed.contains(&group) {
                self.collapsed.remove(&group);
            } else {
                self.collapsed.insert(group);
            }
            self.clamp_selection();
        }
    }

    /// Collapse every section. `Z` chord.
    pub fn collapse_all(&mut self) {
        self.collapsed = self.sections.iter().map(|s| s.group.clone()).collect();
        self.clamp_selection();
    }

    /// Expand every section.
    pub fn expand_all(&mut self) {
        self.collapsed.clear();
        self.clamp_selection();
    }

    /// Re-clamp `selected` after the visible-row count changes
    /// (collapse / expand toggles). Preserves position when
    /// possible; falls back to the last valid row.
    fn clamp_selection(&mut self) {
        let n = self.visible_row_count();
        if n == 0 {
            self.selected = 0;
            self.scroll = 0;
            return;
        }
        if self.selected >= n {
            self.selected = n - 1;
        }
    }

    /// Count of selectable (non-header) rows across the visible sections.
    pub fn visible_row_count(&self) -> usize {
        self.visible_sections().iter().map(|s| s.rows.len()).sum()
    }

    pub fn move_down(&mut self) {
        let n = self.visible_row_count();
        if n == 0 {
            return;
        }
        self.selected = (self.selected + 1).min(n - 1);
    }

    pub fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }

    pub fn page_down(&mut self, page: usize) {
        let n = self.visible_row_count();
        if n == 0 {
            return;
        }
        self.selected = (self.selected + page).min(n - 1);
    }

    pub fn page_up(&mut self, page: usize) {
        self.selected = self.selected.saturating_sub(page);
    }

    pub fn jump_top(&mut self) {
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn jump_bottom(&mut self) {
        let n = self.visible_row_count();
        if n > 0 {
            self.selected = n - 1;
        }
    }

    /// The `command_id` at the currently-selected row, if any.
    pub fn selected_command_id(&self) -> Option<String> {
        let mut i = 0usize;
        for sec in self.visible_sections() {
            for row in sec.rows {
                if i == self.selected {
                    return Some(row.command_id);
                }
                i += 1;
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    #[test]
    fn cheatsheet_has_at_least_one_section() {
        let km = crate::input::keymap::Keymap::build(&Config::default());
        let cs = CheatsheetPane::build(&km);
        assert!(
            !cs.sections.is_empty(),
            "expected at least one cheatsheet section"
        );
    }

    #[test]
    fn unbound_section_lists_palette_only_commands() {
        let km = crate::input::keymap::Keymap::build(&Config::default());
        let cs = CheatsheetPane::build(&km);
        // The "(unbound)" section must exist (mnml ships hundreds of
        // palette-only commands).
        let sec = cs
            .sections
            .iter()
            .find(|s| s.group == "(unbound)")
            .expect("expected an (unbound) section in the cheatsheet");
        assert!(!sec.rows.is_empty(), "(unbound) section is empty");
        // Spot-check a couple of palette-only commands (no default chord).
        let ids: std::collections::HashSet<&str> =
            sec.rows.iter().map(|r| r.command_id.as_str()).collect();
        assert!(
            ids.contains("http.history_global"),
            ":http.history_global should appear in (unbound)"
        );
        assert!(
            ids.contains("http.ai_build"),
            ":http.ai_build should appear in (unbound)"
        );
    }

    #[test]
    fn cheatsheet_filter_narrows_by_chord_or_id_or_title() {
        let km = crate::input::keymap::Keymap::build(&Config::default());
        let mut cs = CheatsheetPane::build(&km);
        cs.query = "save".to_string();
        let v = cs.visible_sections();
        // At least one row whose id or title contains "save".
        assert!(
            v.iter()
                .flat_map(|s| &s.rows)
                .any(|r| r.command_id.to_lowercase().contains("save")
                    || r.title.to_lowercase().contains("save")),
            "expected at least one row matching 'save'"
        );
    }

    #[test]
    fn cheatsheet_selected_command_id_walks_visible_rows() {
        let km = crate::input::keymap::Keymap::build(&Config::default());
        let cs = CheatsheetPane::build(&km);
        if cs.visible_row_count() > 0 {
            assert!(cs.selected_command_id().is_some());
        }
    }
}
