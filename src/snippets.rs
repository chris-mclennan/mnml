//! Text snippets — short triggers expand into longer canned text.
//!
//! Config lives under `[snippets.<scope>]` where `<scope>` is either a file
//! extension (`rs`, `py`, `ts`, …) or the literal `global` (always available).
//! Each entry is `<trigger> = "<expansion>"`. A single literal `$0` marker in
//! the expansion picks where the cursor lands after insertion; without one the
//! cursor is at the end. `$1` … `$9` are tab-stop **placeholders** — after
//! insertion the cursor lands at `$1`, then Tab cycles to `$2`, `$3`, … and
//! finally to `$0` (or the end of the inserted text). Multi-line expansions
//! use `\n` (or a TOML triple-quote string).
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

/// In-flight tab-stop cycle for a snippet that was just inserted. `stops`
/// holds the absolute byte offsets (within the buffer's text, not the
/// snippet's text) of every placeholder that came in (`$1`..`$9` then `$0`
/// when present), in tab-stop order; `current` is the index the cursor
/// currently sits at. Tab advances `current`; Shift-Tab walks it back. When
/// `current == stops.len()` the session ends.
///
/// `last_text_len` records the buffer's text length at the moment the cursor
/// was placed at `stops[current]`. On the next transition the stops at
/// indices > `current` get shifted by `current_text_len - last_text_len` so
/// chars typed at the active placeholder push the later positions along by
/// the right amount. Stops at indices < `current` are not touched (they sit
/// earlier in the file and aren't disturbed by edits at the cursor).
///
/// Limitation: Shift-Tab to a previously-visited stop puts the cursor at
/// that stop's original position, *not* at the end of whatever the user
/// typed there. Re-typing or backspacing is the user's recovery; tracking
/// per-stop ranges would let us land at the end instead and is a follow-up.
#[derive(Debug, Clone)]
pub struct SnippetSession {
    /// Pane the session belongs to. If the active pane drifts away from this
    /// one the session is dropped (no cross-pane continuation).
    pub pane_id: usize,
    /// All placeholders in tab-stop order, as absolute byte offsets.
    pub stops: Vec<usize>,
    /// Index into `stops` the cursor sits at. Always `< stops.len()`.
    pub current: usize,
    /// Buffer text length when the cursor was placed at `stops[current]`.
    pub last_text_len: usize,
}

/// One snippet entry as it lives on `App` (placeholder markers pre-parsed
/// into byte offsets within `text` so the caller doesn't have to re-scan).
#[derive(Debug, Clone)]
pub struct Snippet {
    pub trigger: String,
    pub text: String,
    /// Byte offset into `text` where the cursor should land after insert
    /// (the `$0` marker, or `text.len()` when absent).
    pub cursor_offset: usize,
    /// Byte offsets of `$1` … `$9` placeholders, **in tab-stop order**
    /// (`$1` first, then `$2`, …; gaps are tolerated — only the markers that
    /// actually appear are listed). Each is a position within `text`.
    /// Cursor lands here in sequence as the user presses Tab.
    pub placeholders: Vec<usize>,
    /// `"rs"` / `"py"` / … / `"global"` — for the picker's detail column.
    pub scope: String,
}

impl Snippet {
    /// Parse the raw `(trigger, expansion)` pair. A single occurrence of each
    /// `$0` … `$9` marker is stripped out and its position recorded. Further
    /// occurrences of the same marker are left as literal text.
    pub fn parse(trigger: impl Into<String>, raw: &str, scope: impl Into<String>) -> Snippet {
        let trigger = trigger.into();
        let scope = scope.into();
        // Walk the input once, peeling out the *first* occurrence of each
        // `$N` (N = 0..=9) and recording its byte offset in the cleaned text.
        let mut text = String::with_capacity(raw.len());
        let mut found: [Option<usize>; 10] = [None; 10];
        let bytes = raw.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            // Recognize `$<digit>` as a marker (ASCII only — both bytes), but
            // only the first time we see each digit. Subsequent matches fall
            // through to the literal-copy path below.
            if bytes[i] == b'$' && i + 1 < bytes.len() {
                let c = bytes[i + 1];
                if c.is_ascii_digit() {
                    let n = (c - b'0') as usize;
                    if found[n].is_none() {
                        found[n] = Some(text.len());
                        i += 2;
                        continue;
                    }
                }
            }
            // Literal char — copy a full UTF-8 codepoint (1–4 bytes) so we
            // don't shred multi-byte sequences.
            let ch_len = utf8_char_len(bytes[i]);
            // Safe: `i + ch_len` is on a char boundary because `raw` is valid UTF-8.
            text.push_str(&raw[i..i + ch_len]);
            i += ch_len;
        }
        let cursor_offset = found[0].unwrap_or(text.len());
        let placeholders: Vec<usize> = (1..=9).filter_map(|n| found[n]).collect();
        Snippet {
            trigger,
            text,
            cursor_offset,
            placeholders,
            scope,
        }
    }
}

/// Length in bytes of the UTF-8 codepoint that starts at `b` (the leading
/// byte). Standard 0xxx/110x/1110/1111 lookahead. Continuation bytes
/// (`0x80..=0xBF`) can't be a leading byte on a valid `&str`, but we
/// saturate to 1 there to keep the loop honest.
fn utf8_char_len(b: u8) -> usize {
    if b < 0xC0 {
        1
    } else if b < 0xE0 {
        2
    } else if b < 0xF0 {
        3
    } else {
        4
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
    fn snippet_parse_placeholders_in_order() {
        let s = Snippet::parse("for", "for $1 in $2 {\n    $0\n}", "rs");
        assert_eq!(s.text, "for  in  {\n    \n}");
        // $1 lands after "for ", $2 after "for  in ".
        assert_eq!(s.placeholders, vec![4, 8]);
        // $0 sits where the marker was — between the indent and the closing newline.
        assert_eq!(&s.text[..s.cursor_offset], "for  in  {\n    ");
    }

    #[test]
    fn snippet_parse_placeholder_gaps_tolerated() {
        // $1 + $3 only — $2 missing. Order is by tab index, not by appearance.
        let s = Snippet::parse("g", "[$3]($1)", "global");
        assert_eq!(s.text, "[]()");
        // $1 first (after "[]("), then $3 (after "[").
        assert_eq!(s.placeholders, vec![3, 1]);
        // No $0 ⇒ cursor at end.
        assert_eq!(s.cursor_offset, s.text.len());
    }

    #[test]
    fn snippet_parse_repeated_placeholder_only_first_stripped() {
        let s = Snippet::parse("d", "$1 + $1", "rs");
        // Only the first $1 becomes a placeholder; the second stays as literal text.
        assert_eq!(s.text, " + $1");
        assert_eq!(s.placeholders, vec![0]);
    }

    #[test]
    fn snippet_parse_preserves_utf8() {
        // Multi-byte chars before/after a marker — make sure the marker offset
        // is the *byte* offset and the surrounding text isn't corrupted.
        let s = Snippet::parse("e", "→ $1 ←", "global");
        assert_eq!(s.text, "→  ←");
        // "→" is 3 bytes + a space = byte offset 4.
        assert_eq!(s.placeholders, vec![4]);
    }

    #[test]
    fn snippet_parse_lone_dollar_is_literal() {
        let s = Snippet::parse("p", "price: $a", "global");
        assert_eq!(s.text, "price: $a");
        assert!(s.placeholders.is_empty());
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
