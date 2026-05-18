//! Cheap, regex-based outline extraction for languages without an LSP
//! attached (or while one is starting up). Identifies function / class /
//! struct / module definitions and emits them as `DocumentSymbol`s the
//! existing outline pane already knows how to render.
//!
//! Languages covered: `rs` `py` `js` `jsx` `ts` `tsx` `go` `rb` `c` `cpp`.
//! Anything else returns an empty list (callers can fall through to the
//! markdown extractor or just show "(no symbols)").
//!
//! Patterns are intentionally conservative — they target the common case
//! and skip clever things (decorators, generics, comma-separated `let`s,
//! macro-defined functions). Tree-sitter `tags.scm` queries would be more
//! accurate; this exists because it ships in 50 lines instead of 500.

use crate::lsp::DocumentSymbol;
use regex::Regex;
use std::sync::OnceLock;

/// Public entry — `(text, ext)` → flat list of symbols with approximate
/// depth derived from leading whitespace. Lines are 0-based; the outline
/// pane handles display.
///
/// Depth heuristic: each leading tab = one depth level, plus
/// `leading_spaces / 4` (best-guess indent width; configurable indent
/// detection would be nicer but this matches the common case for
/// rust / js / ts / py / rb / c / go where conventional indentation is
/// 2 or 4 spaces / 1 tab per scope). Sufficient for nested-method
/// rendering under classes / structs / impls.
pub fn extract_symbols(text: &str, ext: &str) -> Vec<DocumentSymbol> {
    let patterns = patterns_for(ext);
    if patterns.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<DocumentSymbol> = Vec::new();
    for (line_no, line) in text.lines().enumerate() {
        for (re, kind) in patterns {
            if let Some(cap) = re.captures(line)
                && let Some(name) = cap.get(1)
            {
                out.push(DocumentSymbol {
                    name: name.as_str().to_string(),
                    kind,
                    line: line_no as u32,
                    character: line[..name.start()].chars().count() as u32,
                    depth: indent_depth(line),
                });
                break; // one match per line
            }
        }
    }
    out
}

/// Count leading-indent depth: each `\t` = 1, each 4 leading spaces = 1.
/// Mixed indents (rare) sum both. Capped at 8 so a wildly-indented line
/// doesn't push the outline column past the panel width.
fn indent_depth(line: &str) -> u32 {
    let mut tabs = 0u32;
    let mut spaces = 0u32;
    for ch in line.chars() {
        match ch {
            '\t' => tabs += 1,
            ' ' => spaces += 1,
            _ => break,
        }
    }
    (tabs + spaces / 4).min(8)
}

/// Per-language pattern list (regex + symbol kind label). Cached behind
/// `OnceLock` so the regexes compile once.
fn patterns_for(ext: &str) -> &'static [(Regex, &'static str)] {
    match ext {
        "rs" => rust_patterns(),
        "py" => python_patterns(),
        "js" | "jsx" | "mjs" | "cjs" => js_patterns(),
        "ts" | "tsx" => ts_patterns(),
        "go" => go_patterns(),
        "rb" => ruby_patterns(),
        "c" | "h" => c_patterns(),
        "cpp" | "cc" | "hpp" | "cxx" => cpp_patterns(),
        _ => &[],
    }
}

macro_rules! patterns {
    ($cell:ident, [ $( ($pat:expr, $kind:expr) ),* $(,)? ]) => {{
        static $cell: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
        $cell.get_or_init(|| {
            vec![
                $(
                    (Regex::new($pat).expect("static regex compiles"), $kind),
                )*
            ]
        }).as_slice()
    }};
}

fn rust_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        RUST,
        [
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)",
                "fn"
            ),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)",
                "struct"
            ),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)",
                "enum"
            ),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?trait\s+([A-Za-z_][A-Za-z0-9_]*)",
                "trait"
            ),
            (r"^\s*impl(?:<[^>]*>)?\s+([A-Za-z_][A-Za-z0-9_]*)", "impl"),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?mod\s+([A-Za-z_][A-Za-z0-9_]*)",
                "mod"
            ),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)",
                "type"
            ),
            (
                r"^\s*(?:pub(?:\([^)]+\))?\s+)?const\s+([A-Z_][A-Z0-9_]*)",
                "const"
            ),
        ]
    )
}

fn python_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        PYTHON,
        [
            (r"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)", "fn"),
            (r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)", "class"),
        ]
    )
}

fn js_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        JS,
        [
            (
                r"^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)",
                "fn"
            ),
            (
                r"^\s*(?:export\s+(?:default\s+)?)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)",
                "class"
            ),
            (
                r"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>)",
                "fn"
            ),
        ]
    )
}

fn ts_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        TS,
        [
            (
                r"^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)",
                "fn"
            ),
            (
                r"^\s*(?:export\s+(?:default\s+)?)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)",
                "class"
            ),
            (
                r"^\s*(?:export\s+(?:default\s+)?)?interface\s+([A-Za-z_$][A-Za-z0-9_$]*)",
                "interface"
            ),
            (
                r"^\s*(?:export\s+(?:default\s+)?)?type\s+([A-Za-z_$][A-Za-z0-9_$]*)",
                "type"
            ),
            (
                r"^\s*(?:export\s+(?:default\s+)?)?enum\s+([A-Za-z_$][A-Za-z0-9_$]*)",
                "enum"
            ),
            (
                r"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*[:=]\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>)",
                "fn"
            ),
        ]
    )
}

fn go_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        GO,
        [
            (r"^func(?:\s+\([^)]+\))?\s+([A-Za-z_][A-Za-z0-9_]*)", "fn"),
            (r"^type\s+([A-Za-z_][A-Za-z0-9_]*)", "type"),
        ]
    )
}

fn ruby_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        RUBY,
        [
            (r"^\s*def\s+(?:self\.)?([A-Za-z_][A-Za-z0-9_]*[!?=]?)", "fn"),
            (r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)", "class"),
            (r"^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)", "module"),
        ]
    )
}

fn c_patterns() -> &'static [(Regex, &'static str)] {
    // C is hard without a real parser. Match `<type> <name>(`-like shapes
    // at column 0. Skips static & inline since they're often mis-parsed.
    patterns!(
        C,
        [
            (
                r"^[A-Za-z_][A-Za-z_0-9*\s]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                "fn"
            ),
            (
                r"^\s*typedef\s+(?:struct|enum|union)?\s*[A-Za-z_0-9\s{}]*\b([A-Za-z_][A-Za-z0-9_]*)\s*;",
                "type"
            ),
        ]
    )
}

fn cpp_patterns() -> &'static [(Regex, &'static str)] {
    patterns!(
        CPP,
        [
            (
                r"^[A-Za-z_][A-Za-z_0-9:*<>\s,&]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                "fn"
            ),
            (r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)", "class"),
            (r"^\s*struct\s+([A-Za-z_][A-Za-z0-9_]*)", "struct"),
            (r"^\s*namespace\s+([A-Za-z_][A-Za-z0-9_]*)", "namespace"),
        ]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_extracts_fn_struct_enum_impl() {
        let src = "\
pub fn outer() {}
struct S {}
enum E { A, B }
impl S {
    pub fn method(&self) {}
    async fn other(&self) {}
}
trait T {}
mod inner {}
const MAX_N: usize = 10;
";
        let s = extract_symbols(src, "rs");
        let names: Vec<&str> = s.iter().map(|x| x.name.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "outer", "S", "E", "S", "method", "other", "T", "inner", "MAX_N"
            ]
        );
        let kinds: Vec<&'static str> = s.iter().map(|x| x.kind).collect();
        assert_eq!(
            kinds,
            vec![
                "fn", "struct", "enum", "impl", "fn", "fn", "trait", "mod", "const"
            ]
        );
    }

    #[test]
    fn python_extracts_def_and_class() {
        let src = "\
def top():
    pass

class Foo:
    def method(self):
        pass

    async def amethod(self):
        pass
";
        let s = extract_symbols(src, "py");
        let names: Vec<&str> = s.iter().map(|x| x.name.as_str()).collect();
        assert_eq!(names, vec!["top", "Foo", "method", "amethod"]);
    }

    #[test]
    fn ts_extracts_function_class_interface_type() {
        let src = "\
export function hello() {}
class Box {}
export interface Shape {}
type Aliased = string;
const arrow = () => 42;
";
        let s = extract_symbols(src, "ts");
        let names: Vec<&str> = s.iter().map(|x| x.name.as_str()).collect();
        assert_eq!(names, vec!["hello", "Box", "Shape", "Aliased", "arrow"]);
    }

    #[test]
    fn go_extracts_func_and_type() {
        let src = "\
func Foo() {}
func (s *Bar) Method() {}
type Baz struct{}
";
        let s = extract_symbols(src, "go");
        let names: Vec<&str> = s.iter().map(|x| x.name.as_str()).collect();
        assert_eq!(names, vec!["Foo", "Method", "Baz"]);
    }

    #[test]
    fn unknown_ext_returns_empty() {
        let s = extract_symbols("anything goes here", "xyz");
        assert!(s.is_empty());
    }

    #[test]
    fn indent_depth_counts_tabs_and_spaces() {
        assert_eq!(indent_depth("no_indent"), 0);
        assert_eq!(indent_depth("    four_spaces"), 1);
        assert_eq!(indent_depth("        eight_spaces"), 2);
        assert_eq!(indent_depth("\tone_tab"), 1);
        assert_eq!(indent_depth("\t\t\tthree_tabs"), 3);
        // Mixed: 1 tab + 4 spaces = depth 2.
        assert_eq!(indent_depth("\t    mixed"), 2);
        // Partial groups under 4 spaces don't bump.
        assert_eq!(indent_depth("  two_spaces"), 0);
    }

    #[test]
    fn rust_impl_methods_get_depth_1() {
        // Conventional 4-space rust indent: methods inside `impl` get depth 1
        // so the outline pane indents them under the impl header.
        let src = "\
impl S {
    pub fn method(&self) {}
    async fn other(&self) {}
}
";
        let s = extract_symbols(src, "rs");
        // First symbol is the impl header at depth 0; next two are methods at depth 1.
        assert_eq!(s[0].name, "S");
        assert_eq!(s[0].depth, 0);
        assert_eq!(s[1].name, "method");
        assert_eq!(s[1].depth, 1);
        assert_eq!(s[2].name, "other");
        assert_eq!(s[2].depth, 1);
    }

    #[test]
    fn python_class_methods_get_depth_1() {
        let src = "\
class Foo:
    def method(self):
        pass

    async def amethod(self):
        pass
";
        let s = extract_symbols(src, "py");
        // class at depth 0; both methods at depth 1.
        assert_eq!(s[0].name, "Foo");
        assert_eq!(s[0].depth, 0);
        assert_eq!(s[1].name, "method");
        assert_eq!(s[1].depth, 1);
        assert_eq!(s[2].name, "amethod");
        assert_eq!(s[2].depth, 1);
    }
}
