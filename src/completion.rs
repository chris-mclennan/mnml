//! The as-you-type LSP completion popup — a small floating list anchored at the
//! cursor that filters live as you keep typing. Populated from one
//! `textDocument/completion` reply (the auto-trigger in `tui.rs`, or `Ctrl+Space`
//! / `lsp.completion`); thereafter [`CompletionPopup::refilter`] narrows the held
//! list locally against the growing identifier prefix — no re-request per
//! keystroke. Navigation / accept / dismiss keys are handled in `tui.rs`; drawing
//! lives in `ui/completion.rs`.

use std::path::PathBuf;

use crate::fuzzy::fuzzy_match;

/// One candidate from the language server.
#[derive(Debug, Clone)]
pub struct CompletionItem {
    /// What's shown in the list (and fuzzy-matched against).
    pub label: String,
    /// What's inserted on accept (replacing the prefix left of the cursor).
    pub insert: String,
    /// A dim right-hand hint (a type, a module path, …) — may be empty.
    pub detail: String,
}

#[derive(Debug)]
pub struct CompletionPopup {
    /// The file this popup belongs to (dropped if the active editor changes).
    pub path: PathBuf,
    /// Every candidate the server returned (capped at the call site).
    all: Vec<CompletionItem>,
    /// Indices into `all`, best-match-first, that match the current `prefix`.
    filtered: Vec<usize>,
    /// Index into `filtered` — the highlighted row.
    pub selected: usize,
    /// Top of the visible window into `filtered` (vertical scroll).
    pub scroll: usize,
    /// The identifier prefix immediately left of the cursor (drives `filtered`).
    pub prefix: String,
}

impl CompletionPopup {
    pub fn new(path: PathBuf, items: Vec<CompletionItem>, prefix: &str) -> Self {
        let mut p = CompletionPopup {
            path,
            all: items,
            filtered: Vec::new(),
            selected: 0,
            scroll: 0,
            prefix: String::new(),
        };
        p.refilter(prefix);
        p
    }

    /// Rebuild `filtered` for a new prefix. Returns `false` if nothing matches
    /// (the caller should drop the popup).
    pub fn refilter(&mut self, prefix: &str) -> bool {
        self.prefix = prefix.to_string();
        if prefix.is_empty() {
            self.filtered = (0..self.all.len()).collect();
        } else {
            let mut scored: Vec<(i64, usize)> = self
                .all
                .iter()
                .enumerate()
                .filter_map(|(i, it)| fuzzy_match(prefix, &it.label).map(|(s, _)| (s, i)))
                .collect();
            scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
            self.filtered = scored.into_iter().map(|(_, i)| i).collect();
        }
        self.selected = 0;
        self.scroll = 0;
        !self.filtered.is_empty()
    }

    pub fn len(&self) -> usize {
        self.filtered.len()
    }

    pub fn is_empty(&self) -> bool {
        self.filtered.is_empty()
    }

    /// Move the selection by `delta` rows (clamped to the list).
    pub fn move_by(&mut self, delta: isize) {
        if self.filtered.is_empty() {
            self.selected = 0;
            return;
        }
        let max = self.filtered.len() as isize - 1;
        self.selected = (self.selected as isize + delta).clamp(0, max) as usize;
    }

    pub fn current(&self) -> Option<&CompletionItem> {
        self.filtered.get(self.selected).map(|&i| &self.all[i])
    }

    /// `(row_index, item)` for every currently-matching candidate, best first.
    pub fn rows(&self) -> impl Iterator<Item = (usize, &CompletionItem)> {
        self.filtered
            .iter()
            .enumerate()
            .map(move |(row, &i)| (row, &self.all[i]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn item(label: &str) -> CompletionItem {
        CompletionItem {
            label: label.into(),
            insert: label.into(),
            detail: String::new(),
        }
    }

    #[test]
    fn refilter_narrows_and_clears() {
        let mut p = CompletionPopup::new(
            PathBuf::from("x.rs"),
            vec![item("push"), item("pop"), item("push_str"), item("len")],
            "p",
        );
        // "p" matches push, pop, push_str (not len).
        assert_eq!(p.len(), 3);
        assert!(p.refilter("pus"));
        assert_eq!(p.len(), 2);
        assert!(!p.refilter("zzz"));
        assert!(p.is_empty());
        // back to a matching prefix
        assert!(p.refilter(""));
        assert_eq!(p.len(), 4);
    }

    #[test]
    fn move_by_clamps() {
        let mut p = CompletionPopup::new(PathBuf::from("x"), vec![item("a"), item("b")], "");
        p.move_by(-1);
        assert_eq!(p.selected, 0);
        p.move_by(5);
        assert_eq!(p.selected, 1);
        assert_eq!(p.current().unwrap().label, "b");
    }
}
