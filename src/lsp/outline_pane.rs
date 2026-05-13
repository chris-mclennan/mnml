//! `Pane::Outline` — a persistent companion to the [`crate::picker`]-based
//! `lsp.symbols` picker. Same data (`textDocument/documentSymbol`), but the
//! pane stays open as a side panel so you can scan structure while editing.
//!
//! State is just the symbol list + a target file (the editor the outline was
//! opened from). `r` re-fires `document_symbol` and refreshes; `Enter` jumps
//! the *target* editor to the chosen symbol; Esc → tree.

use std::path::PathBuf;

use crate::fuzzy::fuzzy_match;

use super::DocumentSymbol;

pub struct OutlinePane {
    /// Workspace-relative-ish path that owns this outline; the file we re-
    /// fire `documentSymbol` against on `r` and where `Enter` jumps to.
    pub target: PathBuf,
    pub items: Vec<DocumentSymbol>,
    /// Selection — index into the **filtered** view ([`Self::visible_indices`]).
    pub selected: usize,
    /// Top rendered row, in filtered-view coordinates.
    pub scroll: usize,
    /// Optional fuzzy filter — narrows the visible list. Empty ⇒ show all.
    pub query: String,
    /// When true, key presses build up [`Self::query`] instead of navigating
    /// (typical type-to-filter UX). Enter / Esc exit; Esc also clears.
    pub filter_mode: bool,
}

impl OutlinePane {
    pub fn new(target: PathBuf, items: Vec<DocumentSymbol>) -> Self {
        OutlinePane {
            target,
            items,
            selected: 0,
            scroll: 0,
            query: String::new(),
            filter_mode: false,
        }
    }

    /// Indices into [`Self::items`] that pass the current fuzzy filter, in the
    /// same order as the underlying list (so nesting depth stays readable).
    /// Empty `query` returns every index.
    pub fn visible_indices(&self) -> Vec<usize> {
        if self.query.is_empty() {
            return (0..self.items.len()).collect();
        }
        self.items
            .iter()
            .enumerate()
            .filter_map(|(i, s)| fuzzy_match(&self.query, &s.name).map(|_| i))
            .collect()
    }

    /// The selected `DocumentSymbol` (resolves through the filter).
    pub fn selected_filtered_item(&self) -> Option<&DocumentSymbol> {
        let v = self.visible_indices();
        v.get(self.selected).and_then(|&i| self.items.get(i))
    }

    /// Append `c` to the live filter query, snap the selection back to the
    /// top (the previous filtered position likely no longer makes sense).
    pub fn filter_push(&mut self, c: char) {
        self.query.push(c);
        self.selected = 0;
        self.scroll = 0;
    }

    /// Pop one char off the live filter query. When the query empties, the
    /// pane stays in filter mode (Backspace at empty is a no-op — Esc / Enter
    /// exit).
    pub fn filter_pop(&mut self) {
        self.query.pop();
        self.selected = 0;
        self.scroll = 0;
    }

    /// Clear the filter + exit filter mode.
    pub fn filter_clear_and_exit(&mut self) {
        self.query.clear();
        self.filter_mode = false;
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn tab_title(&self) -> String {
        let name = self
            .target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("outline")
            .to_string();
        let n = self.items.len();
        if n == 0 {
            format!("{name} ⌥")
        } else {
            format!("{name} ⌥{n}")
        }
    }

    pub fn clamp(&mut self) {
        let n = self.visible_indices().len();
        if n == 0 {
            self.selected = 0;
        } else if self.selected >= n {
            self.selected = n - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        let n = self.visible_indices().len() as isize;
        if n == 0 {
            return;
        }
        self.selected = (self.selected as isize + delta).clamp(0, n - 1) as usize;
    }

    /// Selected item — resolves through the filter. Kept under the old name
    /// for callers; `selected_filtered_item` is the more descriptive alias.
    pub fn selected_item(&self) -> Option<&DocumentSymbol> {
        self.selected_filtered_item()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sym(name: &str, kind: &'static str, line: u32, depth: u32) -> DocumentSymbol {
        DocumentSymbol {
            name: name.into(),
            kind,
            line,
            character: 0,
            depth,
        }
    }

    #[test]
    fn tab_title_includes_count_and_filename() {
        let p = OutlinePane::new(
            PathBuf::from("/ws/src/main.rs"),
            vec![sym("main", "fn", 0, 0), sym("Foo", "struct", 5, 0)],
        );
        assert_eq!(p.tab_title(), "main.rs ⌥2");
        let empty = OutlinePane::new(PathBuf::from("/ws/src/main.rs"), Vec::new());
        assert_eq!(empty.tab_title(), "main.rs ⌥");
    }

    #[test]
    fn move_selection_clamps() {
        let mut p = OutlinePane::new(
            PathBuf::from("/x"),
            vec![sym("a", "fn", 0, 0), sym("b", "fn", 1, 0)],
        );
        p.move_selection(-5);
        assert_eq!(p.selected, 0);
        p.move_selection(99);
        assert_eq!(p.selected, 1);
    }

    #[test]
    fn filter_narrows_visible_indices() {
        let mut p = OutlinePane::new(
            PathBuf::from("/x"),
            vec![
                sym("alpha", "fn", 0, 0),
                sym("beta", "fn", 1, 0),
                sym("alphabet", "fn", 2, 0),
            ],
        );
        assert_eq!(p.visible_indices().len(), 3);
        p.filter_push('a');
        p.filter_push('l');
        let v = p.visible_indices();
        assert_eq!(v.len(), 2);
        assert_eq!(p.items[v[0]].name, "alpha");
        assert_eq!(p.items[v[1]].name, "alphabet");
        p.filter_clear_and_exit();
        assert_eq!(p.query, "");
        assert!(!p.filter_mode);
        assert_eq!(p.visible_indices().len(), 3);
    }

    #[test]
    fn move_selection_respects_filter() {
        let mut p = OutlinePane::new(
            PathBuf::from("/x"),
            vec![
                sym("alpha", "fn", 0, 0),
                sym("zeta", "fn", 1, 0),
                sym("alphabet", "fn", 2, 0),
            ],
        );
        // "al" is in alpha and alphabet (in order) but not in zeta.
        p.filter_push('a');
        p.filter_push('l');
        assert_eq!(p.visible_indices().len(), 2);
        p.move_selection(99);
        // Selection clamps to the *filtered* size, not the full items list.
        assert_eq!(p.selected, 1);
        assert_eq!(p.selected_item().unwrap().name, "alphabet");
    }
}
