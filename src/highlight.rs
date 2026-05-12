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
        "keyword" => theme::cur().base16[0x0e],
        "string" => match name {
            "string.escape" | "string.special" => theme::cur().base16[0x0c],
            _ => theme::cur().base16[0x0b],
        },
        "comment" => theme::cur().comment,
        "function" => theme::cur().base16[0x0d],
        "constructor" => theme::cur().base16[0x0c],
        "type" => theme::cur().base16[0x0a],
        "number" | "boolean" | "constant" | "escape" => theme::cur().base16[0x09],
        "attribute" | "tag" | "label" => theme::cur().base16[0x0a],
        "module" | "namespace" => theme::cur().base16[0x0a],
        "property" => theme::cur().base16[0x08],
        "variable" => match name {
            "variable.builtin" | "variable.parameter" | "variable.member" => {
                theme::cur().base16[0x08]
            }
            _ => theme::cur().base16[0x05],
        },
        "operator" => theme::cur().base16[0x05],
        "punctuation" => theme::cur().base16[0x0f],
        _ => theme::cur().base16[0x05],
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
        "ts" | "cts" | "mts" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            "typescript",
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            "",
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            "tsx",
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            "",
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        "css" | "scss" => (
            tree_sitter_css::LANGUAGE.into(),
            "css",
            tree_sitter_css::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        "html" | "htm" => (
            tree_sitter_html::LANGUAGE.into(),
            "html",
            tree_sitter_html::HIGHLIGHTS_QUERY,
            tree_sitter_html::INJECTIONS_QUERY,
            "",
        ),
        "sh" | "bash" | "zsh" => (
            tree_sitter_bash::LANGUAGE.into(),
            "bash",
            tree_sitter_bash::HIGHLIGHT_QUERY,
            "",
            "",
        ),
        // Markdown's inline grammar lives behind injections, which we don't resolve
        // yet — so this colors block structure (headings, fences, lists, quotes).
        "md" | "markdown" => (
            tree_sitter_md::LANGUAGE.into(),
            "markdown",
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
            tree_sitter_md::INJECTION_QUERY_BLOCK,
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
        // line 0 has `fn` (a keyword) → some span over its first chars
        assert!(
            lines[0].iter().any(|&(s, e, _)| s == 0 && e >= 2),
            "expected a span over `fn`: {:?}",
            lines[0]
        );
        // line 1 (`    let s = "hi";`) — the string literal "hi" sits at cols 12..16
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 12 && e >= 14),
            "expected a span covering the string literal: {:?}",
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
        // line 1 is `  "a": 1` — expect spans covering the `"a"` key (cols 2..5)
        // and the `1` value (col 7). (Colours come from the active theme; we only
        // check that highlighting *happened*, not which shade.)
        let lines = highlight_lines("{\n  \"a\": 1\n}\n", "json");
        assert_eq!(lines.len(), 4);
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 2 && e >= 4),
            "expected a span over the key: {:?}",
            lines[1]
        );
        assert!(
            lines[1].iter().any(|&(s, e, _)| s <= 7 && e >= 8),
            "expected a span over the number: {:?}",
            lines[1]
        );
    }

    #[test]
    fn extra_grammars_load_and_color_something() {
        // Each grammar's queries must compile (`HighlightConfiguration::new` ok)
        // and produce at least one span on a representative line.
        let cases: &[(&str, &str)] = &[
            ("ts", "const x: number = 1;\n"),
            ("tsx", "const C = () => <div>{x}</div>;\n"),
            ("css", "a { color: red; }\n"),
            ("sh", "echo \"hi\" && ls -la\n"),
            ("html", "<div class=\"x\">hi</div>\n"),
            ("md", "# Heading\n\n- item\n"),
        ];
        for &(ext, src) in cases {
            let lines = highlight_lines(src, ext);
            assert!(
                !lines.is_empty() && lines.iter().any(|l| !l.is_empty()),
                "{ext}: expected some highlight spans, got {lines:?}"
            );
        }
    }
}
