//! Tree-sitter syntax highlighting → per-line colored spans.
//!
//! `highlight_lines(text, ext)` parses `text` with the grammar for `ext`, runs
//! the grammar's highlight queries, and returns, for each editor line, a list of
//! `(start_col_chars, end_col_chars, Color)` spans (sorted, non-overlapping at
//! the same nesting depth — innermost wins). Unknown extensions ⇒ a `Vec` of
//! empty `Vec`s (plain text).
//!
//! `HighlightConfiguration`s are expensive to build (they compile the `.scm`
//! queries), so they're cached for the process lifetime — leaked as `'static`,
//! the established pattern (there are only a handful).

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use ratatui::style::Color;
use tree_sitter::Language;
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

use crate::ui::theme;

/// One colored run on a single line: `[start_col, end_col)` in **chars**.
pub type ColoredSpan = (usize, usize, Color);

/// The capture names we recognize. tree-sitter-highlight maps captures (by
/// longest-prefix) to indices into this slice.
const HIGHLIGHT_NAMES: &[&str] = &[
    "attribute",
    "boolean",
    "comment",
    "comment.documentation",
    "constant",
    "constant.builtin",
    "constructor",
    "embedded",
    "escape",
    "function",
    "function.builtin",
    "function.macro",
    "function.method",
    "keyword",
    "keyword.control",
    "keyword.directive",
    "keyword.function",
    "keyword.operator",
    "keyword.return",
    "label",
    "module",
    "namespace",
    "number",
    "operator",
    "property",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "punctuation.special",
    "string",
    "string.escape",
    "string.regexp",
    "string.special",
    "tag",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.member",
    "variable.parameter",
];

fn color_for(idx: usize) -> Color {
    let name = HIGHLIGHT_NAMES.get(idx).copied().unwrap_or("");
    let head = name.split('.').next().unwrap_or(name);
    match head {
        "keyword" => theme::BASE16_0E,
        "string" => match name {
            "string.escape" | "string.special" => theme::BASE16_0C,
            _ => theme::BASE16_0B,
        },
        "comment" => theme::COMMENT,
        "function" => theme::BASE16_0D,
        "constructor" => theme::BASE16_0C,
        "type" => theme::BASE16_0A,
        "number" | "boolean" | "constant" | "escape" => theme::BASE16_09,
        "attribute" | "tag" | "label" => theme::BASE16_0A,
        "module" | "namespace" => theme::BASE16_0A,
        "property" => theme::BASE16_08,
        "variable" => match name {
            "variable.builtin" | "variable.parameter" | "variable.member" => theme::BASE16_08,
            _ => theme::BASE16_05,
        },
        "operator" => theme::BASE16_05,
        "punctuation" => theme::BASE16_0F,
        _ => theme::BASE16_05,
    }
}

/// Highlight `text` for the file extension `ext`. Returns one span list per
/// editor line (`'\n'`-count + 1 lines).
pub fn highlight_lines(text: &str, ext: &str) -> Vec<Vec<ColoredSpan>> {
    let n_lines = text.bytes().filter(|&b| b == b'\n').count() + 1;
    let mut out: Vec<Vec<ColoredSpan>> = vec![Vec::new(); n_lines];
    let Some(cfg) = config_for_ext(ext) else {
        return out;
    };
    let mut hl = Highlighter::new();
    let events: Vec<HighlightEvent> = match hl.highlight(cfg, text.as_bytes(), None, |_| None) {
        Ok(it) => it.filter_map(Result::ok).collect(),
        Err(_) => return out,
    };

    // byte → line index, via the line-start offsets.
    let line_starts: Vec<usize> = std::iter::once(0)
        .chain(
            text.bytes()
                .enumerate()
                .filter(|(_, b)| *b == b'\n')
                .map(|(i, _)| i + 1),
        )
        .collect();
    let line_of = |b: usize| -> usize {
        match line_starts.binary_search(&b) {
            Ok(i) => i,
            Err(i) => i.saturating_sub(1),
        }
    };

    let mut stack: Vec<Color> = Vec::new();
    for ev in events {
        match ev {
            HighlightEvent::HighlightStart(h) => stack.push(color_for(h.0)),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                let Some(&color) = stack.last() else { continue };
                let mut b = start;
                while b < end {
                    let line = line_of(b);
                    if line >= out.len() {
                        break;
                    }
                    // content end of this line (the '\n' position, or EOF for the last line)
                    let content_end = if line + 1 < line_starts.len() {
                        line_starts[line + 1] - 1
                    } else {
                        text.len()
                    };
                    let seg_end = end.min(content_end);
                    let ls = line_starts[line];
                    if seg_end > b && b >= ls {
                        let scol = text[ls..b].chars().count();
                        let ecol = text[ls..seg_end].chars().count();
                        if ecol > scol {
                            out[line].push((scol, ecol, color));
                        }
                    }
                    // advance past this line (including its '\n')
                    let next = if line + 1 < line_starts.len() {
                        line_starts[line + 1]
                    } else {
                        text.len()
                    };
                    b = next.max(b + 1);
                }
            }
        }
    }
    out
}

fn config_for_ext(ext: &str) -> Option<&'static HighlightConfiguration> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<&'static HighlightConfiguration>>>> =
        OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = cache.lock().ok()?;
    if let Some(c) = g.get(ext) {
        return *c;
    }
    let built: Option<&'static HighlightConfiguration> =
        build_config(ext).map(|c| &*Box::leak(Box::new(c)));
    g.insert(ext.to_string(), built);
    built
}

fn build_config(ext: &str) -> Option<HighlightConfiguration> {
    // (language, name, highlights, injections, locals). Per-grammar quirks live here.
    let (lang, name, hl_q, inj_q, loc_q): (Language, &str, &str, &str, &str) = match ext {
        "rs" => (
            tree_sitter_rust::LANGUAGE.into(),
            "rust",
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            tree_sitter_rust::INJECTIONS_QUERY,
            "",
        ),
        "js" | "cjs" | "mjs" | "jsx" => (
            tree_sitter_javascript::LANGUAGE.into(),
            "javascript",
            tree_sitter_javascript::HIGHLIGHT_QUERY,
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_javascript::LOCALS_QUERY,
        ),
        "py" => (
            tree_sitter_python::LANGUAGE.into(),
            "python",
            tree_sitter_python::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        "json" => (
            tree_sitter_json::LANGUAGE.into(),
            "json",
            tree_sitter_json::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        "go" => (
            tree_sitter_go::LANGUAGE.into(),
            "go",
            tree_sitter_go::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        "toml" => (
            tree_sitter_toml_ng::LANGUAGE.into(),
            "toml",
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        _ => return None,
    };
    let mut cfg = HighlightConfiguration::new(lang, name, hl_q, inj_q, loc_q).ok()?;
    cfg.configure(HIGHLIGHT_NAMES);
    Some(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_keywords_and_strings_get_colored() {
        let src = "fn main() {\n    let s = \"hi\";\n}\n";
        let lines = highlight_lines(src, "rs");
        assert_eq!(lines.len(), 4); // 3 '\n' + 1
        // line 0 has `fn` (a keyword) → some span
        assert!(!lines[0].is_empty(), "line 0 should have spans");
        // line 1 has the string "hi"
        assert!(
            lines[1].iter().any(|&(_, _, c)| c == theme::BASE16_0B),
            "string should be green: {:?}",
            lines[1]
        );
    }

    #[test]
    fn unknown_ext_is_plain() {
        let lines = highlight_lines("hello\nworld\n", "xyz");
        assert_eq!(lines.len(), 3);
        assert!(lines.iter().all(|l| l.is_empty()));
    }

    #[test]
    fn json_parses() {
        let lines = highlight_lines("{\n  \"a\": 1\n}\n", "json");
        assert_eq!(lines.len(), 4);
        assert!(
            lines[1].iter().any(|&(_, _, c)| c == theme::BASE16_09),
            "number should be orange: {:?}",
            lines[1]
        );
    }
}
