//! Tree-sitter syntax highlighting → per-line colored spans.
//!
//! `highlight_lines(text, ext)` parses `text` with the grammar for `ext`, runs
//! the grammar's highlight queries, and returns, for each editor line, a list of
//! `(start_col_chars, end_col_chars, Color)` spans. The output isn't strictly
//! non-overlapping — outer (larger) captures come before inner (smaller) ones
//! in each line's span list, and the renderer in `ui/editor_view.rs` resolves
//! cell colors with `spans.iter().rev().find(...)` so the innermost span wins.
//!
//! Cached, leaked `'static` per ext (queries are expensive to compile and there
//! are only a handful of grammars).
//!
//! NOTE — session 1 of the tree_sitter_highlight → raw Parser+Query migration.
//! Markdown's two-grammar setup (block + injected `markdown_inline`) and any
//! injection-based highlighting (fenced code blocks, embedded `<style>` / `<script>`)
//! is **not yet wired**. Plain single-grammar files still highlight correctly.
//! Session 2 restores injection support.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use ratatui::style::Color;
use tree_sitter::{Language, Parser, Query, QueryCursor, StreamingIterator};

use crate::ui::theme;

/// One colored run on a single line: `[start_col, end_col)` in **chars**.
pub type ColoredSpan = (usize, usize, Color);

/// The highlight-name vocabulary mnml recognizes. Each capture in a grammar's
/// `highlights.scm` (e.g. `@keyword.return`, `@function.method`) is mapped to
/// the longest entry it equals or has as a `.`-separated prefix.
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
    // markdown (block + inline) captures
    "text",
    "text.emphasis",
    "text.literal",
    "text.reference",
    "text.strong",
    "text.title",
    "text.uri",
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
        "text" => match name {
            "text.title" => theme::cur().base16[0x0d],
            "text.literal" => theme::cur().base16[0x0b],
            "text.uri" | "text.reference" => theme::cur().base16[0x0c],
            _ => theme::cur().base16[0x05],
        },
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

/// A compiled, leaked `'static` per-language config. Building one means
/// loading the grammar + compiling its highlight (and later injection) query;
/// both are expensive, so we keep them around for the process lifetime.
pub struct LangConfig {
    pub language: Language,
    pub highlights_query: Query,
    /// Map from `highlights_query` capture index → index into `HIGHLIGHT_NAMES`
    /// (or `-1` if the capture name doesn't match any entry). Computed once at
    /// config build so the hot path is a single array lookup.
    highlight_map: Vec<i32>,
}

impl LangConfig {
    fn new(language: Language, highlight_src: &str) -> Option<Self> {
        let highlights_query = Query::new(&language, highlight_src).ok()?;
        let highlight_map = build_highlight_map(highlights_query.capture_names());
        Some(LangConfig {
            language,
            highlights_query,
            highlight_map,
        })
    }
}

/// For each capture name, find the longest entry in `HIGHLIGHT_NAMES` it equals
/// or has as a `.`-separated prefix. Tree-sitter convention: a capture named
/// `keyword.return` should pick up `keyword.return`'s color if defined, else
/// fall back to `keyword`'s; a capture named `foo.bar` with no match returns -1.
fn build_highlight_map(capture_names: &[&str]) -> Vec<i32> {
    capture_names
        .iter()
        .map(|cap| {
            let mut best: i32 = -1;
            let mut best_len = 0usize;
            for (i, hn) in HIGHLIGHT_NAMES.iter().enumerate() {
                let matches = *cap == *hn
                    || (cap.len() > hn.len()
                        && cap.as_bytes()[hn.len()] == b'.'
                        && cap.starts_with(hn));
                if matches && hn.len() >= best_len {
                    best = i as i32;
                    best_len = hn.len();
                }
            }
            best
        })
        .collect()
}

/// Highlight `text` for the file extension `ext`. Returns one span list per
/// editor line (`'\n'`-count + 1 lines).
pub fn highlight_lines(text: &str, ext: &str) -> Vec<Vec<ColoredSpan>> {
    let n_lines = text.bytes().filter(|&b| b == b'\n').count() + 1;
    let mut out: Vec<Vec<ColoredSpan>> = vec![Vec::new(); n_lines];
    let Some(cfg) = config_for_ext(ext) else {
        return out;
    };

    let mut parser = Parser::new();
    if parser.set_language(&cfg.language).is_err() {
        return out;
    }
    let Some(tree) = parser.parse(text, None) else {
        return out;
    };

    apply_query_to_spans(text, cfg, &tree, &mut out);
    out
}

/// Run `cfg`'s highlight query over `tree`, append per-line spans to `out`.
/// Factored out so injection logic (session 2) can re-use it for inner trees.
fn apply_query_to_spans(
    text: &str,
    cfg: &LangConfig,
    tree: &tree_sitter::Tree,
    out: &mut [Vec<ColoredSpan>],
) {
    let bytes = text.as_bytes();
    let mut cursor = QueryCursor::new();
    let mut iter = cursor.captures(&cfg.highlights_query, tree.root_node(), bytes);

    // Collect (start_byte, end_byte, color, pattern_idx) for every relevant capture.
    // Skipping captures whose name doesn't map into HIGHLIGHT_NAMES at query-build
    // time keeps this loop tight.
    let mut caps: Vec<(usize, usize, Color, u32)> = Vec::new();
    while let Some(item) = iter.next() {
        let qmatch = &item.0;
        let cap_idx_in_match = item.1;
        let cap = qmatch.captures[cap_idx_in_match];
        let cap_idx = cap.index as usize;
        let hn_idx = cfg.highlight_map.get(cap_idx).copied().unwrap_or(-1);
        if hn_idx < 0 {
            continue;
        }
        let start = cap.node.start_byte();
        let end = cap.node.end_byte();
        if end <= start {
            continue;
        }
        let color = color_for(hn_idx as usize);
        caps.push((start, end, color, qmatch.pattern_index as u32));
    }

    // Innermost wins: emit smaller ranges *later* so the renderer's
    // `spans.iter().rev().find(...)` picks them first. Sort by range size
    // descending; pattern-index ascending so a later .scm pattern (which by
    // tree-sitter convention overrides earlier ones at the same node) ends up
    // later in the Vec too.
    caps.sort_by(|a, b| {
        let alen = a.1.saturating_sub(a.0);
        let blen = b.1.saturating_sub(b.0);
        blen.cmp(&alen).then(a.3.cmp(&b.3))
    });

    // Build `line_starts` once, reuse for every capture's byte→line walk.
    let line_starts: Vec<usize> = std::iter::once(0)
        .chain(
            bytes
                .iter()
                .enumerate()
                .filter(|&(_, &b)| b == b'\n')
                .map(|(i, _)| i + 1),
        )
        .collect();
    let line_of = |b: usize| -> usize {
        match line_starts.binary_search(&b) {
            Ok(i) => i,
            Err(i) => i.saturating_sub(1),
        }
    };

    for &(start, end, color, _) in &caps {
        let mut b = start;
        while b < end {
            let line = line_of(b);
            if line >= out.len() {
                break;
            }
            let content_end = if line + 1 < line_starts.len() {
                line_starts[line + 1] - 1
            } else {
                bytes.len()
            };
            let seg_end = end.min(content_end);
            let ls = line_starts[line];
            if seg_end > b && b >= ls {
                // Byte offsets → char columns. Slicing `text` (not `bytes`)
                // is char-boundary-safe because tree-sitter only ever returns
                // node boundaries that *are* char boundaries.
                let scol = text[ls..b].chars().count();
                let ecol = text[ls..seg_end].chars().count();
                if ecol > scol {
                    out[line].push((scol, ecol, color));
                }
            }
            let next = if line + 1 < line_starts.len() {
                line_starts[line + 1]
            } else {
                bytes.len()
            };
            b = next.max(b + 1);
        }
    }
}

fn config_for_ext(ext: &str) -> Option<&'static LangConfig> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<&'static LangConfig>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = cache.lock().ok()?;
    if let Some(c) = g.get(ext) {
        return *c;
    }
    let built: Option<&'static LangConfig> = build_config(ext).map(|c| &*Box::leak(Box::new(c)));
    g.insert(ext.to_string(), built);
    built
}

fn build_config(ext: &str) -> Option<LangConfig> {
    let (lang, hl_q): (Language, &str) = match ext {
        "rs" => (
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY,
        ),
        "js" | "cjs" | "mjs" | "jsx" => (
            tree_sitter_javascript::LANGUAGE.into(),
            tree_sitter_javascript::HIGHLIGHT_QUERY,
        ),
        "py" => (
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY,
        ),
        "json" => (
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY,
        ),
        "go" => (
            tree_sitter_go::LANGUAGE.into(),
            tree_sitter_go::HIGHLIGHTS_QUERY,
        ),
        "toml" => (
            tree_sitter_toml_ng::LANGUAGE.into(),
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
        ),
        "ts" | "cts" | "mts" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
        ),
        "css" | "scss" => (
            tree_sitter_css::LANGUAGE.into(),
            tree_sitter_css::HIGHLIGHTS_QUERY,
        ),
        "html" | "htm" => (
            tree_sitter_html::LANGUAGE.into(),
            tree_sitter_html::HIGHLIGHTS_QUERY,
        ),
        "sh" | "bash" | "zsh" => (
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY,
        ),
        // Markdown is two grammars: the block structure (headings/fences/lists)
        // and the inline grammar (emphasis, inline code, links) injected via
        // `INJECTION_QUERY_BLOCK`. Session 2 wires the inline injection back up.
        "md" | "markdown" => (
            tree_sitter_md::LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
        ),
        "markdown_inline" => (
            tree_sitter_md::INLINE_LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
        ),
        "c" | "h" => (
            tree_sitter_c::LANGUAGE.into(),
            tree_sitter_c::HIGHLIGHT_QUERY,
        ),
        "cpp" | "cc" | "cxx" | "hpp" | "hh" | "hxx" => (
            tree_sitter_cpp::LANGUAGE.into(),
            tree_sitter_cpp::HIGHLIGHT_QUERY,
        ),
        "rb" | "rake" | "gemspec" => (
            tree_sitter_ruby::LANGUAGE.into(),
            tree_sitter_ruby::HIGHLIGHTS_QUERY,
        ),
        "java" => (
            tree_sitter_java::LANGUAGE.into(),
            tree_sitter_java::HIGHLIGHTS_QUERY,
        ),
        "cs" => (
            tree_sitter_c_sharp::LANGUAGE.into(),
            tree_sitter_c_sharp::HIGHLIGHTS_QUERY,
        ),
        "lua" => (
            tree_sitter_lua::LANGUAGE.into(),
            tree_sitter_lua::HIGHLIGHTS_QUERY,
        ),
        "yaml" | "yml" => (
            tree_sitter_yaml::LANGUAGE.into(),
            tree_sitter_yaml::HIGHLIGHTS_QUERY,
        ),
        "scala" | "sc" | "sbt" => (
            tree_sitter_scala::LANGUAGE.into(),
            tree_sitter_scala::HIGHLIGHTS_QUERY,
        ),
        "ex" | "exs" => (
            tree_sitter_elixir::LANGUAGE.into(),
            tree_sitter_elixir::HIGHLIGHTS_QUERY,
        ),
        "hs" => (
            tree_sitter_haskell::LANGUAGE.into(),
            tree_sitter_haskell::HIGHLIGHTS_QUERY,
        ),
        "php" | "php3" | "php4" | "php5" | "phtml" => (
            tree_sitter_php::LANGUAGE_PHP.into(),
            tree_sitter_php::HIGHLIGHTS_QUERY,
        ),
        "swift" => (
            tree_sitter_swift::LANGUAGE.into(),
            tree_sitter_swift::HIGHLIGHTS_QUERY,
        ),
        "zig" => (
            tree_sitter_zig::LANGUAGE.into(),
            tree_sitter_zig::HIGHLIGHTS_QUERY,
        ),
        "nix" => (
            tree_sitter_nix::LANGUAGE.into(),
            tree_sitter_nix::HIGHLIGHTS_QUERY,
        ),
        "ocaml" | "ml" => (
            tree_sitter_ocaml::LANGUAGE_OCAML.into(),
            tree_sitter_ocaml::HIGHLIGHTS_QUERY,
        ),
        "mli" => (
            tree_sitter_ocaml::LANGUAGE_OCAML_INTERFACE.into(),
            tree_sitter_ocaml::HIGHLIGHTS_QUERY,
        ),
        "dart" => (
            tree_sitter_dart::LANGUAGE.into(),
            tree_sitter_dart::HIGHLIGHTS_QUERY,
        ),
        "sql" | "psql" | "mysql" => (
            tree_sitter_sequel::LANGUAGE.into(),
            tree_sitter_sequel::HIGHLIGHTS_QUERY,
        ),
        "mk" | "make" | "makefile" => (
            tree_sitter_make::LANGUAGE.into(),
            tree_sitter_make::HIGHLIGHTS_QUERY,
        ),
        "kt" | "kts" => (
            tree_sitter_kotlin_sg::LANGUAGE.into(),
            tree_sitter_kotlin_sg::HIGHLIGHTS_QUERY,
        ),
        "regex" => (
            tree_sitter_regex::LANGUAGE.into(),
            tree_sitter_regex::HIGHLIGHTS_QUERY,
        ),
        _ => return None,
    };
    LangConfig::new(lang, hl_q)
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
    fn kotlin_parses() {
        let src = "fun main() { println(\"hi\") }\n";
        let lines = highlight_lines(src, "kt");
        assert!(!lines.is_empty());
        assert!(
            !lines[0].is_empty(),
            "expected kotlin highlighter to emit at least one span: {:?}",
            lines[0]
        );
    }

    #[test]
    fn json_parses() {
        // line 1 is `  "a": 1` — expect spans covering the key (cols 2..5) and value (col 7).
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
    #[ignore = "session 2: markdown injection re-wiring restores fenced-code highlighting"]
    fn markdown_injects_fenced_code() {
        let src = "# Title\n\n```rust\nfn x() {}\n```\n";
        let lines = highlight_lines(src, "md");
        assert_eq!(lines.len(), 6);
        assert!(
            lines[0].iter().any(|&(s, e, _)| s <= 2 && e >= 4),
            "expected the heading text to be colored: {:?}",
            lines[0]
        );
        assert!(
            lines[3].iter().any(|&(s, e, _)| s == 0 && e >= 2),
            "expected the fenced Rust code to be highlighted: {:?}",
            lines[3]
        );
    }

    #[test]
    fn markdown_block_still_highlights() {
        // Block-level features (headings, fences as delimiters) still work
        // without inline injection; restored in session 2.
        let src = "# Title\n\n- item\n";
        let lines = highlight_lines(src, "md");
        assert_eq!(lines.len(), 4);
        assert!(
            lines.iter().any(|l| !l.is_empty()),
            "expected the markdown block grammar to emit some spans"
        );
    }

    #[test]
    fn extra_grammars_load_and_color_something() {
        let cases: &[(&str, &str)] = &[
            ("ts", "const x: number = 1;\n"),
            ("tsx", "const C = () => <div>{x}</div>;\n"),
            ("css", "a { color: red; }\n"),
            ("sh", "echo \"hi\" && ls -la\n"),
            ("html", "<div class=\"x\">hi</div>\n"),
            ("md", "# Heading\n\n- item\n"),
            ("c", "int main(void) { return 0; }\n"),
            ("cpp", "auto f() -> int { return 42; }\n"),
            ("rb", "def hi(name) = puts \"hi #{name}\"\n"),
            ("java", "class A { void f() { return; } }\n"),
            ("cs", "class A { void F() { return; } }\n"),
            ("lua", "local function f(x) return x + 1 end\n"),
            ("yaml", "name: value\nlist:\n  - one\n"),
            ("scala", "object A { def f(x: Int): Int = x + 1 }\n"),
            (
                "ex",
                "defmodule A do\n  def hi(name), do: IO.puts(name)\nend\n",
            ),
            ("hs", "main :: IO ()\nmain = putStrLn \"hi\"\n"),
            ("php", "<?php function hi($name) { echo \"hi $name\"; }\n"),
            (
                "swift",
                "func hi(_ name: String) -> String { return \"hi \\(name)\" }\n",
            ),
            ("mk", "CC = clang\nall: build\nbuild:\n\t$(CC) main.c\n"),
            (
                "zig",
                "const std = @import(\"std\");\npub fn main() void {}\n",
            ),
            ("nix", "{ pkgs ? import <nixpkgs> {} }: pkgs.hello\n"),
            ("ocaml", "let hi name = print_endline (\"hi \" ^ name)\n"),
            (
                "dart",
                "void main() {\n  print('hi');\n  var x = 1 + 2;\n}\n",
            ),
            (
                "sql",
                "SELECT id, name FROM users WHERE active = TRUE LIMIT 10;\n",
            ),
        ];
        for &(ext, src) in cases {
            let lines = highlight_lines(src, ext);
            assert!(
                !lines.is_empty() && lines.iter().any(|l| !l.is_empty()),
                "{ext}: expected some highlight spans, got {lines:?}"
            );
        }
    }

    #[test]
    fn highlight_map_picks_longest_prefix() {
        // Synthetic capture-name list: verify the matching logic directly.
        let caps: &[&str] = &[
            "keyword",         // exact match
            "keyword.return",  // exact match, longer than "keyword"
            "keyword.foo.bar", // prefix-match "keyword" (no "keyword.foo")
            "made.up",         // no match
            "string.escape",   // exact (longer than "string")
        ];
        let map = build_highlight_map(caps);
        let idx_of = |name: &str| HIGHLIGHT_NAMES.iter().position(|n| *n == name);
        assert_eq!(map[0], idx_of("keyword").unwrap() as i32);
        assert_eq!(map[1], idx_of("keyword.return").unwrap() as i32);
        assert_eq!(map[2], idx_of("keyword").unwrap() as i32);
        assert_eq!(map[3], -1);
        assert_eq!(map[4], idx_of("string.escape").unwrap() as i32);
    }
}
