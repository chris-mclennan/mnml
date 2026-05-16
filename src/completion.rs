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
    /// Hover-style documentation for the candidate (MarkupContent or plain
    /// string from the server). May start empty if the server only sends
    /// docs lazily via `completionItem/resolve`; the App populates it
    /// when the resolve reply lands.
    pub documentation: String,
    /// Server's original item JSON, kept so we can round-trip the exact
    /// payload back on `completionItem/resolve`. `None` for synthetic items
    /// (e.g. mnml's buffer keyword-completion path) — those never resolve.
    pub raw: Option<serde_json::Value>,
    /// `true` once a `completionItem/resolve` request has been sent for this
    /// item. Prevents the popup from spamming the server when the user
    /// jumps back and forth.
    pub resolved: bool,
    /// `true` when the server marked this item with `insertTextFormat == 2`
    /// (LSP snippet). `insert` then contains LSP snippet syntax
    /// (`$1` / `${1:default}` / `$0`) instead of literal text, and the
    /// accept path expands it through mnml's snippet placeholder machinery.
    pub is_snippet: bool,
    /// LSP `CompletionItemKind` (1..=25 — 1=Text, 3=Function, 6=Method,
    /// 7=Class, 10=Property, 13=Enum, etc.). 0 ⇒ unknown / not provided.
    /// Drives the kind-glyph + color prefix on each popup row.
    pub kind: u8,
}

/// Map an LSP CompletionItemKind enum value to (glyph, theme color name).
/// The names match what's painted in `ui/completion.rs`.
pub fn kind_glyph(kind: u8) -> (&'static str, &'static str) {
    match kind {
        2 => ("ƒ", "blue"),    // Method
        3 => ("fn", "blue"),   // Function
        4 => ("⊕", "purple"),  // Constructor
        5 => ("◆", "cyan"),    // Field
        6 => ("◆", "cyan"),    // Variable
        7 => ("◇", "yellow"),  // Class
        8 => ("◇", "yellow"),  // Interface
        9 => ("◈", "green"),   // Module
        10 => ("●", "cyan"),   // Property
        11 => ("u", "orange"), // Unit
        12 => ("=", "purple"), // Value
        13 => ("∈", "yellow"), // Enum
        14 => ("⌘", "purple"), // Keyword
        15 => ("✂", "teal"),   // Snippet
        16 => ("◧", "orange"), // Color
        17 => ("≡", "fg"),     // File
        18 => ("⇒", "purple"), // Reference
        19 => ("📁", "fg"),    // Folder
        20 => ("⊡", "yellow"), // EnumMember
        21 => ("π", "orange"), // Constant
        22 => ("⊞", "yellow"), // Struct
        23 => ("⚡", "red"),   // Event
        24 => ("•", "purple"), // Operator
        25 => ("T", "cyan"),   // TypeParameter
        1 => ("a", "fg"),      // Text
        _ => (" ", "comment"), // Unknown
    }
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

    /// Set the highlighted row to `idx` (clamped to the list). Used by the
    /// mouse handler to align selection with the clicked row before accept.
    pub fn set_selected(&mut self, idx: usize) {
        if self.filtered.is_empty() {
            self.selected = 0;
        } else {
            self.selected = idx.min(self.filtered.len() - 1);
        }
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

    /// Index into [`Self::all`] of the currently-selected item (`None`
    /// when the filter is empty). Used by the resolve plumbing to mutate
    /// the underlying item without going through the filtered view.
    pub fn current_index_mut(&self) -> Option<usize> {
        self.filtered.get(self.selected).copied()
    }

    /// Mutable handle to an item by its index into [`Self::all`].
    pub fn item_at_mut(&mut self, idx: usize) -> &mut CompletionItem {
        &mut self.all[idx]
    }

    /// Find an item by label (linear scan). Used by the
    /// `completionItem/resolve` reply path to merge fields back without
    /// having to remember which row was requested.
    pub fn item_index_by_label(&self, label: &str) -> Option<usize> {
        self.all.iter().position(|it| it.label == label)
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
            documentation: String::new(),
            raw: None,
            resolved: false,
            is_snippet: false,
            kind: 0,
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
