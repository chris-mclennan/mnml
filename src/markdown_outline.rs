//! Outline extraction for markdown — heading lines (`#` / `##` / `###` …)
//! turned into [`crate::lsp::DocumentSymbol`] entries so the outline pane
//! works on `.md` files without needing a markdown language server.
//!
//! Recognises ATX-style headings (`# heading text`, up to 6 `#`) at line
//! start (optionally preceded by whitespace, like Setext or list items
//! aren't handled — keep this minimal). The `depth` field on the resulting
//! `DocumentSymbol` is `heading_level - 1` so the outline pane indents
//! `##` under `#` etc.
//!
//! Headings inside fenced code blocks (``` … ```` ``` ` ``` ```) are
//! skipped so `# heading` example code doesn't pollute the outline.

use crate::lsp::DocumentSymbol;

pub fn extract_headings(text: &str) -> Vec<DocumentSymbol> {
    let mut out = Vec::new();
    let mut in_fence = false;
    let mut fence_marker: Option<&str> = None;
    for (line_idx, raw) in text.lines().enumerate() {
        let trimmed = raw.trim_start();
        // Toggle fenced-code state on ```/~~~ runs of 3+ matching chars.
        if let Some(marker) = fence_open_marker(trimmed) {
            if in_fence {
                if fence_marker == Some(marker) {
                    in_fence = false;
                    fence_marker = None;
                }
            } else {
                in_fence = true;
                fence_marker = Some(marker);
            }
            continue;
        }
        if in_fence {
            continue;
        }
        let Some((level, name)) = parse_atx_heading(trimmed) else {
            continue;
        };
        let depth = level.saturating_sub(1);
        out.push(DocumentSymbol {
            name,
            kind: heading_kind(level),
            line: line_idx as u32,
            character: 0,
            depth: depth as u32,
        });
    }
    out
}

/// `### text` ⇒ `Some((3, "text"))`. Trailing `#`s are stripped (ATX closing).
/// Empty heading text ⇒ `None`.
fn parse_atx_heading(line: &str) -> Option<(usize, String)> {
    let mut chars = line.chars();
    let mut level = 0usize;
    for c in chars.by_ref() {
        if c == '#' {
            level += 1;
            if level > 6 {
                return None;
            }
        } else if level > 0 && c == ' ' {
            break;
        } else {
            return None;
        }
    }
    if level == 0 {
        return None;
    }
    let rest: String = chars.collect();
    let name = rest.trim().trim_end_matches('#').trim_end().to_string();
    if name.is_empty() {
        None
    } else {
        Some((level, name))
    }
}

/// Returns the marker (``` ``` ``` or `~~~`) if `line` opens/closes a fenced
/// code block — a run of 3+ identical fence chars, optionally followed by an
/// info string.
fn fence_open_marker(line: &str) -> Option<&'static str> {
    if line.starts_with("```") {
        Some("```")
    } else if line.starts_with("~~~") {
        Some("~~~")
    } else {
        None
    }
}

fn heading_kind(level: usize) -> &'static str {
    match level {
        1 => "h1",
        2 => "h2",
        3 => "h3",
        4 => "h4",
        5 => "h5",
        _ => "h6",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_levels_and_lines() {
        let md = "\
# Top
some text
## Middle
text
### Deep
not a heading
####### too deep
# Bottom
";
        let syms = extract_headings(md);
        let names: Vec<_> = syms.iter().map(|s| (&*s.name, s.line, s.depth)).collect();
        assert_eq!(
            names,
            vec![
                ("Top", 0, 0),
                ("Middle", 2, 1),
                ("Deep", 4, 2),
                ("Bottom", 7, 0),
            ]
        );
    }

    #[test]
    fn ignores_headings_inside_fences() {
        let md = "\
# Real
```
# fake
```
## Also Real
~~~
## also fake
~~~
### Trailing
";
        let names: Vec<_> = extract_headings(md)
            .iter()
            .map(|s| s.name.clone())
            .collect();
        assert_eq!(names, vec!["Real", "Also Real", "Trailing"]);
    }

    #[test]
    fn handles_atx_closing_hashes() {
        let md = "## My Section ##\n# Top #\n";
        let names: Vec<_> = extract_headings(md)
            .iter()
            .map(|s| s.name.clone())
            .collect();
        assert_eq!(names, vec!["My Section", "Top"]);
    }

    #[test]
    fn rejects_non_headings() {
        let md = "#nospace\n hash mid-line # not a heading\n\nplain text\n";
        assert!(extract_headings(md).is_empty());
    }

    #[test]
    fn empty_heading_skipped() {
        assert!(extract_headings("##\n\n##   \n").is_empty());
    }
}
