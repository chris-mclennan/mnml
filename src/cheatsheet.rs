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
}

impl CheatsheetPane {
    /// Build a fresh cheatsheet from the active keymap + command registry.
    pub fn build(keymap: &crate::input::keymap::Keymap) -> Self {
        let reg = crate::command::registry();
        let mut grouped: BTreeMap<String, Vec<CheatsheetRow>> = BTreeMap::new();
        for (chord, id) in keymap.iter() {
            let (group, title) = match reg.get(id) {
                Some(c) => (c.group.to_string(), c.title.to_string()),
                None => ("(unknown)".to_string(), id.to_string()),
            };
            grouped.entry(group).or_default().push(CheatsheetRow {
                chord: chord.to_spec(),
                command_id: id.to_string(),
                title,
            });
        }
        let sections: Vec<CheatsheetSection> = grouped
            .into_iter()
            .map(|(group, mut rows)| {
                rows.sort_by(|a, b| a.chord.cmp(&b.chord));
                CheatsheetSection { group, rows }
            })
            .collect();
        CheatsheetPane {
            sections,
            selected: 0,
            scroll: 0,
            query: String::new(),
            filter_mode: false,
        }
    }

    /// Return the sections filtered by the current `/` query. Sections with
    /// no matching rows are omitted entirely; rows inside a kept section
    /// match against chord OR id OR title (case-insensitive substring).
    pub fn visible_sections(&self) -> Vec<CheatsheetSection> {
        if self.query.is_empty() {
            return self.sections.clone();
        }
        let q = self.query.to_lowercase();
        self.sections
            .iter()
            .filter_map(|sec| {
                let rows: Vec<_> = sec
                    .rows
                    .iter()
                    .filter(|r| {
                        r.chord.to_lowercase().contains(&q)
                            || r.command_id.to_lowercase().contains(&q)
                            || r.title.to_lowercase().contains(&q)
                    })
                    .cloned()
                    .collect();
                if rows.is_empty() {
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
