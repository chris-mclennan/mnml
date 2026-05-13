//! `Pane::Outline` — a persistent companion to the [`crate::picker`]-based
//! `lsp.symbols` picker. Same data (`textDocument/documentSymbol`), but the
//! pane stays open as a side panel so you can scan structure while editing.
//!
//! State is just the symbol list + a target file (the editor the outline was
//! opened from). `r` re-fires `document_symbol` and refreshes; `Enter` jumps
//! the *target* editor to the chosen symbol; Esc → tree.

use std::path::PathBuf;

use super::DocumentSymbol;

pub struct OutlinePane {
    /// Workspace-relative-ish path that owns this outline; the file we re-
    /// fire `documentSymbol` against on `r` and where `Enter` jumps to.
    pub target: PathBuf,
    pub items: Vec<DocumentSymbol>,
    pub selected: usize,
    /// Top rendered row.
    pub scroll: usize,
}

impl OutlinePane {
    pub fn new(target: PathBuf, items: Vec<DocumentSymbol>) -> Self {
        OutlinePane {
            target,
            items,
            selected: 0,
            scroll: 0,
        }
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
        if self.items.is_empty() {
            self.selected = 0;
        } else if self.selected >= self.items.len() {
            self.selected = self.items.len() - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        if self.items.is_empty() {
            return;
        }
        let n = self.items.len() as isize;
        self.selected = (self.selected as isize + delta).clamp(0, n - 1) as usize;
    }

    pub fn selected_item(&self) -> Option<&DocumentSymbol> {
        self.items.get(self.selected)
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
}
