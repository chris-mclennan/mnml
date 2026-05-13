//! Text snippets — short triggers expand into longer canned text.
//!
//! Config lives under `[snippets.<scope>]` where `<scope>` is either a file
//! extension (`rs`, `py`, `ts`, …) or the literal `global` (always available).
//! Each entry is `<trigger> = "<expansion>"`. A single literal `$0` marker in
//! the expansion picks where the cursor lands after insertion; without one the
//! cursor is at the end. Multi-line expansions use `\n` (or a TOML triple-quote
//! string).
//!
//! Example:
//! ```toml
//! [snippets.rs]
//! fn = "fn name() {\n    $0\n}"
//! todo = "// TODO: $0"
//!
//! [snippets.global]
//! ts = "2026-05-13"
//! ```
//!
//! Two ways to expand:
//! - `snippet.expand` (`Ctrl+J`) — replaces the identifier prefix immediately
//!   left of the cursor with the matching trigger's expansion. If no trigger
//!   matches, toasts and bails.
//! - `snippet.pick` (`<leader>i s`) — fuzzy picker over every snippet available
//!   for the active buffer; accept inserts the expansion at the cursor (no
//!   trigger text to consume).

use std::collections::BTreeMap;

/// One snippet entry as it lives on `App` (the `$0` marker pre-parsed into a
/// byte offset within `text` so the caller doesn't have to scan again).
#[derive(Debug, Clone)]
pub struct Snippet {
    pub trigger: String,
    pub text: String,
    /// Byte offset into `text` where the cursor should land after insert.
    /// `text.len()` when no `$0` marker was present.
    pub cursor_offset: usize,
    /// `"rs"` / `"py"` / … / `"global"` — for the picker's detail column.
    pub scope: String,
}

impl Snippet {
    /// Parse the raw `(trigger, expansion)` pair. A single `$0` is stripped
    /// out and its position becomes `cursor_offset`; further `$0`s (if any)
    /// are left in the text untouched (treated as literal).
    pub fn parse(trigger: impl Into<String>, raw: &str, scope: impl Into<String>) -> Snippet {
        let trigger = trigger.into();
        let scope = scope.into();
        match raw.find("$0") {
            Some(at) => {
                let mut text = String::with_capacity(raw.len() - 2);
                text.push_str(&raw[..at]);
                text.push_str(&raw[at + 2..]);
                Snippet {
                    trigger,
                    text,
                    cursor_offset: at,
                    scope,
                }
            }
            None => {
                let text = raw.to_string();
                let cursor_offset = text.len();
                Snippet {
                    trigger,
                    text,
                    cursor_offset,
                    scope,
                }
            }
        }
    }
}

/// Build the list of snippets available for `ext` (the active buffer's file
/// extension, or `None` for scratch buffers). The `"global"` scope is always
/// included. Order: extension matches first, then `global`. Triggers within a
/// scope come out in TOML's lexicographic key order (BTreeMap).
pub fn snippets_for(
    table: &BTreeMap<String, BTreeMap<String, String>>,
    ext: Option<&str>,
) -> Vec<Snippet> {
    let mut out: Vec<Snippet> = Vec::new();
    if let Some(ext) = ext
        && let Some(map) = table.get(ext)
    {
        for (k, v) in map {
            out.push(Snippet::parse(k, v, ext));
        }
    }
    if let Some(map) = table.get("global") {
        for (k, v) in map {
            // Don't shadow an extension-scoped trigger with the global one.
            if out.iter().any(|s| s.trigger == *k) {
                continue;
            }
            out.push(Snippet::parse(k, v, "global"));
        }
    }
    out
}

/// Find the snippet whose `trigger` exactly matches `word` (or `None`).
pub fn find_by_trigger<'a>(snippets: &'a [Snippet], word: &str) -> Option<&'a Snippet> {
    snippets.iter().find(|s| s.trigger == word)
}

/// The identifier prefix (`[A-Za-z0-9_]*`) immediately left of `cursor` in
/// `text`. Returns `(prefix_start_byte, prefix_str)`. Empty when the cursor
/// isn't preceded by an identifier char.
pub fn word_before_cursor(text: &str, cursor: usize) -> (usize, String) {
    let cur = cursor.min(text.len());
    let mut start = cur;
    while start > 0 {
        // step one char boundary back
        let mut i = start - 1;
        while i > 0 && !text.is_char_boundary(i) {
            i -= 1;
        }
        let ch = text[i..start].chars().next().unwrap_or(' ');
        if ch.is_alphanumeric() || ch == '_' {
            start = i;
        } else {
            break;
        }
    }
    if start == cur {
        return (cur, String::new());
    }
    (start, text[start..cur].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(triggers: &[(&str, &str)]) -> BTreeMap<String, BTreeMap<String, String>> {
        let mut all = BTreeMap::new();
        let mut rs = BTreeMap::new();
        for (k, v) in triggers {
            rs.insert((*k).to_string(), (*v).to_string());
        }
        all.insert("rs".to_string(), rs);
        all
    }

    #[test]
    fn snippet_parse_no_marker() {
        let s = Snippet::parse("todo", "// TODO: ", "rs");
        assert_eq!(s.text, "// TODO: ");
        assert_eq!(s.cursor_offset, s.text.len());
    }

    #[test]
    fn snippet_parse_with_marker() {
        let s = Snippet::parse("fn", "fn name() {\n    $0\n}", "rs");
        assert_eq!(s.text, "fn name() {\n    \n}");
        // Cursor sits where the `$0` was — between the indent and the
        // closing newline.
        assert_eq!(&s.text[..s.cursor_offset], "fn name() {\n    ");
    }

    #[test]
    fn snippet_parse_only_first_marker_consumed() {
        let s = Snippet::parse("dup", "a$0b$0c", "global");
        assert_eq!(s.text, "ab$0c");
        assert_eq!(&s.text[..s.cursor_offset], "a");
    }

    #[test]
    fn word_before_cursor_basic() {
        let (start, w) = word_before_cursor("let fn", 6);
        assert_eq!(w, "fn");
        assert_eq!(start, 4);
    }

    #[test]
    fn word_before_cursor_at_line_start() {
        let (start, w) = word_before_cursor("hello", 0);
        assert_eq!(w, "");
        assert_eq!(start, 0);
    }

    #[test]
    fn word_before_cursor_punct() {
        let (_, w) = word_before_cursor("foo.bar", 7);
        assert_eq!(w, "bar");
    }

    #[test]
    fn word_before_cursor_underscores_and_digits() {
        let (_, w) = word_before_cursor("a_42", 4);
        assert_eq!(w, "a_42");
    }

    #[test]
    fn snippets_for_ext_first_then_global() {
        let mut all = t(&[("fn", "fn x() {}")]);
        let mut global = BTreeMap::new();
        global.insert("ts".to_string(), "2026-01-01".to_string());
        all.insert("global".to_string(), global);
        let list = snippets_for(&all, Some("rs"));
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].trigger, "fn");
        assert_eq!(list[0].scope, "rs");
        assert_eq!(list[1].trigger, "ts");
        assert_eq!(list[1].scope, "global");
    }

    #[test]
    fn snippets_for_ext_shadows_global_trigger() {
        let mut all = t(&[("ts", "(rs-version)")]);
        let mut global = BTreeMap::new();
        global.insert("ts".to_string(), "(global-version)".to_string());
        all.insert("global".to_string(), global);
        let list = snippets_for(&all, Some("rs"));
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].text, "(rs-version)");
        assert_eq!(list[0].scope, "rs");
    }

    #[test]
    fn snippets_for_unknown_ext_returns_global_only() {
        let mut all = t(&[]);
        let mut global = BTreeMap::new();
        global.insert("h".to_string(), "hello".to_string());
        all.insert("global".to_string(), global);
        let list = snippets_for(&all, Some("md"));
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].scope, "global");
    }

    #[test]
    fn snippets_for_no_ext() {
        let mut all = t(&[("fn", "fn x() {}")]);
        let mut global = BTreeMap::new();
        global.insert("h".to_string(), "hello".to_string());
        all.insert("global".to_string(), global);
        let list = snippets_for(&all, None);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].scope, "global");
    }

    #[test]
    fn find_by_trigger_finds_exact() {
        let all = t(&[("fn", "fn name() {}"), ("for", "for x in y {}")]);
        let list = snippets_for(&all, Some("rs"));
        assert!(find_by_trigger(&list, "fn").is_some());
        assert!(find_by_trigger(&list, "fo").is_none());
    }
}
