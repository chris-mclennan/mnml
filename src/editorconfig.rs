//! Minimal `.editorconfig` reader. Walks up from the buffer's directory
//! looking for `.editorconfig` files, parses the simple INI format, and
//! returns the merged settings for a file path.
//!
//! What we honor:
//! - `tab_width` / `indent_size` ⇒ Buffer's `editor.tab_width` (closer first
//!   wins; `indent_size` falls back to `tab_width` when missing)
//! - `insert_final_newline` ⇒ `ensure_trailing_newline`
//! - `trim_trailing_whitespace` ⇒ `trim_trailing_ws_on_save`
//! - `root = true` ⇒ stop walking up
//!
//! What we don't (yet):
//! - `indent_style = tab` — we always use spaces (mnml doesn't track tabs vs
//!   spaces yet beyond the width)
//! - `end_of_line` — line endings are LF-only for now
//! - `charset` — UTF-8 only
//! - Brace expansion `{js,ts}` in section globs — only `*.<ext>`, exact name,
//!   and `*` are matched. `[*.{js,ts}]` falls back to no-match (skip).
//!
//! Re-read on every `Buffer::open` (cheap — typical .editorconfig is <1KB
//! and we touch at most 4-5 dirs walking up).

use std::path::Path;

/// What .editorconfig says about one file.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct EditorConfig {
    pub tab_width: Option<usize>,
    pub insert_final_newline: Option<bool>,
    pub trim_trailing_whitespace: Option<bool>,
}

/// Resolve the merged .editorconfig for `file_path` by walking up to (and
/// including) `workspace`. Closer-to-file settings win. A file with
/// `root = true` stops the walk.
pub fn resolve_for(file_path: &Path, workspace: &Path) -> EditorConfig {
    let mut out = EditorConfig::default();
    // Collect the chain of .editorconfig files from the file's directory
    // upward, stopping at workspace (or at the first one with `root = true`).
    let mut configs: Vec<(std::path::PathBuf, String)> = Vec::new();
    let mut cur = file_path.parent();
    while let Some(dir) = cur {
        let ec_path = dir.join(".editorconfig");
        if let Ok(text) = std::fs::read_to_string(&ec_path) {
            let is_root = parse_root_flag(&text);
            configs.push((dir.to_path_buf(), text));
            if is_root {
                break;
            }
        }
        if dir == workspace || dir.parent().is_none() {
            break;
        }
        cur = dir.parent();
    }
    // Apply far-to-near so closer overrides farther.
    for (dir, text) in configs.iter().rev() {
        let merged = parse_for_path(text, file_path, dir);
        if merged.tab_width.is_some() {
            out.tab_width = merged.tab_width;
        }
        if merged.insert_final_newline.is_some() {
            out.insert_final_newline = merged.insert_final_newline;
        }
        if merged.trim_trailing_whitespace.is_some() {
            out.trim_trailing_whitespace = merged.trim_trailing_whitespace;
        }
    }
    out
}

/// Parse a single .editorconfig text + return what its matching sections
/// say about `file_path`. `config_dir` is the directory the .editorconfig
/// lives in (used as the anchor for relative globs).
fn parse_for_path(text: &str, file_path: &Path, config_dir: &Path) -> EditorConfig {
    let mut out = EditorConfig::default();
    let mut current_pattern: Option<String> = None;
    let mut current_matches = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[')
            && let Some(pattern) = rest.strip_suffix(']')
        {
            current_pattern = Some(pattern.to_string());
            current_matches = matches_pattern(pattern, file_path, config_dir);
            continue;
        }
        // `key = value`
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let key = k.trim().to_lowercase();
        let val = v.trim();
        // Top-of-file `root = true` is handled separately; skip it here.
        if current_pattern.is_none() {
            continue;
        }
        if !current_matches {
            continue;
        }
        match key.as_str() {
            "tab_width" | "indent_size" => {
                if let Ok(n) = val.parse::<usize>() {
                    out.tab_width = Some(n);
                }
            }
            "insert_final_newline" => {
                out.insert_final_newline = Some(val.eq_ignore_ascii_case("true"));
            }
            "trim_trailing_whitespace" => {
                out.trim_trailing_whitespace = Some(val.eq_ignore_ascii_case("true"));
            }
            _ => {}
        }
    }
    out
}

/// True when the file at the top of the .editorconfig has `root = true`
/// (case-insensitive). Stops further upward walking.
fn parse_root_flag(text: &str) -> bool {
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') {
            // Section starts ⇒ done with the preamble.
            return false;
        }
        if let Some((k, v)) = line.split_once('=')
            && k.trim().eq_ignore_ascii_case("root")
            && v.trim().eq_ignore_ascii_case("true")
        {
            return true;
        }
    }
    false
}

/// Best-effort .editorconfig glob match. Supports:
/// - `*` ⇒ any chars except `/`
/// - `**` ⇒ any chars (including `/`)
/// - `?` ⇒ exactly one char
/// - `{a,b,c}` ⇒ brace expansion (alternatives) — handles nested groups
///   and multi-group patterns like `{a,b}-{c,d}` ⇒ `a-c`, `a-d`, `b-c`, `b-d`
/// - `[abc]` / `[a-z]` / `[!abc]` ⇒ char classes (negation via `!` or `^`)
/// - Exact filename / extension matches
/// - Patterns starting with `/` are anchored to `config_dir`; others match
///   the basename / any suffix path.
fn matches_pattern(pattern: &str, file_path: &Path, config_dir: &Path) -> bool {
    let target: String = if pattern.starts_with('/') {
        // Anchored to config_dir.
        let rel = file_path.strip_prefix(config_dir).unwrap_or(file_path);
        rel.to_string_lossy().into_owned()
    } else {
        // Match against the file name (most common case for `*.rs`).
        file_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    };
    let pat = pattern.strip_prefix('/').unwrap_or(pattern);
    // Brace expansion: `*.{js,ts}` ⇒ try `*.js` and `*.ts` against target.
    let alternatives = expand_braces(pat);
    alternatives.iter().any(|alt| glob_match(alt, &target))
}

/// Expand `{a,b,c}` groups in `pattern` into the full set of alternatives.
/// Handles multi-group patterns (`{a,b}{c,d}` ⇒ 4 results) and nested
/// braces (`{a,{b,c}}` ⇒ `a`, `b`, `c`). Patterns without braces return
/// a single-element vec.
fn expand_braces(pattern: &str) -> Vec<String> {
    // Find the first `{` that has a matching `}` (depth-aware).
    let bytes = pattern.as_bytes();
    let Some(start) = bytes.iter().position(|&b| b == b'{') else {
        return vec![pattern.to_string()];
    };
    // Walk forward maintaining brace depth to find the matching `}`.
    let mut depth = 0i32;
    let mut end = None;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        match b {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(i);
                    break;
                }
            }
            _ => {}
        }
    }
    let Some(end) = end else {
        // Unmatched `{` — treat literally.
        return vec![pattern.to_string()];
    };
    let before = &pattern[..start];
    let inside = &pattern[start + 1..end];
    let after = &pattern[end + 1..];
    // Split `inside` on top-level commas (commas inside nested braces
    // belong to the inner group, not ours).
    let mut alts: Vec<&str> = Vec::new();
    let inside_bytes = inside.as_bytes();
    let mut d = 0i32;
    let mut last = 0usize;
    for (i, &b) in inside_bytes.iter().enumerate() {
        match b {
            b'{' => d += 1,
            b'}' => d -= 1,
            b',' if d == 0 => {
                alts.push(&inside[last..i]);
                last = i + 1;
            }
            _ => {}
        }
    }
    alts.push(&inside[last..]);
    // For each alternative, recursively expand the combined `before + alt +
    // after` so nested groups + later groups get handled.
    let mut out = Vec::new();
    for alt in alts {
        let combined = format!("{before}{alt}{after}");
        out.extend(expand_braces(&combined));
    }
    out
}

fn glob_match(pat: &str, s: &str) -> bool {
    // Simple glob: `**` ⇒ any (incl `/`); `*` ⇒ any non-`/`; `?` ⇒ one char;
    // `[abc]` / `[a-z]` / `[!abc]` ⇒ char class (negation via `!` or `^`).
    fn go(pat: &[u8], s: &[u8]) -> bool {
        let (mut pi, mut si) = (0usize, 0usize);
        let (mut star_pi, mut star_si) = (None::<usize>, 0usize);
        let mut star_double = false;
        while si < s.len() {
            if pi < pat.len() && pat[pi] == b'*' {
                if pi + 1 < pat.len() && pat[pi + 1] == b'*' {
                    star_pi = Some(pi);
                    star_double = true;
                    pi += 2;
                } else {
                    star_pi = Some(pi);
                    star_double = false;
                    pi += 1;
                }
                star_si = si;
                continue;
            }
            // Char class — `[abc]` / `[a-z]` / `[!abc]`.
            if pi < pat.len() && pat[pi] == b'[' {
                // Find the closing `]`. Treat `[` literally if unmatched.
                let class_end = pat[pi + 1..].iter().position(|&b| b == b']');
                if let Some(rel_end) = class_end {
                    let end = pi + 1 + rel_end;
                    let class_body = &pat[pi + 1..end];
                    if matches_char_class(class_body, s[si]) {
                        pi = end + 1;
                        si += 1;
                        continue;
                    }
                    // Class fails — fall through to backtrack/fail logic.
                    if let Some(spi) = star_pi {
                        pi = spi + (if star_double { 2 } else { 1 });
                        star_si += 1;
                        if !star_double && s[star_si - 1] == b'/' {
                            return false;
                        }
                        si = star_si;
                        continue;
                    }
                    return false;
                }
                // No closing bracket — treat `[` literally.
            }
            if pi < pat.len() && (pat[pi] == b'?' || pat[pi] == s[si]) {
                pi += 1;
                si += 1;
                continue;
            }
            if let Some(spi) = star_pi {
                pi = spi + (if star_double { 2 } else { 1 });
                star_si += 1;
                if !star_double && s[star_si - 1] == b'/' {
                    // Single `*` doesn't cross `/`.
                    return false;
                }
                si = star_si;
                continue;
            }
            return false;
        }
        while pi < pat.len() && pat[pi] == b'*' {
            pi += 1;
        }
        pi == pat.len()
    }
    go(pat.as_bytes(), s.as_bytes())
}

/// Match a single byte against an editorconfig char class body (the bytes
/// between `[` and `]`). Supports `[abc]`, `[a-z]`, and `[!abc]` / `[^abc]`
/// negation. Ranges + literals can be mixed (`[a-z0-9_]`).
fn matches_char_class(class: &[u8], c: u8) -> bool {
    let (negated, body) = match class.first() {
        Some(&b'!') | Some(&b'^') => (true, &class[1..]),
        _ => (false, class),
    };
    let mut i = 0;
    let mut matched = false;
    while i < body.len() {
        if i + 2 < body.len() && body[i + 1] == b'-' {
            // Range `a-z`.
            if c >= body[i] && c <= body[i + 2] {
                matched = true;
            }
            i += 3;
        } else {
            if c == body[i] {
                matched = true;
            }
            i += 1;
        }
    }
    if negated { !matched } else { matched }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_matches_extension() {
        assert!(glob_match("*.rs", "main.rs"));
        assert!(glob_match("*.rs", "lib.rs"));
        assert!(!glob_match("*.rs", "main.py"));
    }

    #[test]
    fn glob_handles_double_star() {
        assert!(glob_match("**/*.rs", "src/main.rs"));
        assert!(glob_match("**", "anything/here.txt"));
    }

    #[test]
    fn glob_question_mark() {
        assert!(glob_match("?.rs", "a.rs"));
        assert!(!glob_match("?.rs", "ab.rs"));
    }

    #[test]
    fn parses_root_flag() {
        assert!(parse_root_flag("root = true\n[*]"));
        assert!(parse_root_flag("# header\nroot=TRUE"));
        assert!(!parse_root_flag("[*]\nroot = true"));
    }

    #[test]
    fn merges_simple_section() {
        let text = "root = true\n[*.rs]\nindent_size = 4\ninsert_final_newline = true";
        let cfg = parse_for_path(
            text,
            std::path::Path::new("/tmp/wsroot/main.rs"),
            std::path::Path::new("/tmp/wsroot"),
        );
        assert_eq!(cfg.tab_width, Some(4));
        assert_eq!(cfg.insert_final_newline, Some(true));
    }

    #[test]
    fn brace_expansion_matches_each_alt() {
        let text = "[*.{js,ts,jsx,tsx}]\nindent_size = 2";
        for fname in ["main.js", "main.ts", "main.jsx", "main.tsx"] {
            let cfg = parse_for_path(
                text,
                std::path::Path::new(&format!("/tmp/{fname}")),
                std::path::Path::new("/tmp"),
            );
            assert_eq!(cfg.tab_width, Some(2), "{fname} should match brace group");
        }
        // Non-matching extension still no-op.
        let cfg = parse_for_path(
            text,
            std::path::Path::new("/tmp/main.rs"),
            std::path::Path::new("/tmp"),
        );
        assert_eq!(cfg.tab_width, None);
    }

    #[test]
    fn expand_braces_handles_nested_and_multi_group() {
        // Single group.
        let mut v = expand_braces("*.{js,ts}");
        v.sort();
        assert_eq!(v, vec!["*.js".to_string(), "*.ts".to_string()]);
        // Nested.
        let mut v = expand_braces("{a,{b,c}}");
        v.sort();
        assert_eq!(v, vec!["a".to_string(), "b".to_string(), "c".to_string()]);
        // Multi-group → cartesian product.
        let mut v = expand_braces("{a,b}-{c,d}");
        v.sort();
        assert_eq!(
            v,
            vec![
                "a-c".to_string(),
                "a-d".to_string(),
                "b-c".to_string(),
                "b-d".to_string(),
            ]
        );
        // No braces ⇒ single-element passthrough.
        assert_eq!(expand_braces("*.rs"), vec!["*.rs".to_string()]);
    }

    #[test]
    fn glob_char_class_matches() {
        assert!(glob_match("[abc].rs", "a.rs"));
        assert!(glob_match("[abc].rs", "c.rs"));
        assert!(!glob_match("[abc].rs", "d.rs"));
        // Ranges.
        assert!(glob_match("[a-z]*.rs", "main.rs"));
        assert!(!glob_match("[A-Z]*.rs", "main.rs"));
        // Negation.
        assert!(glob_match("[!abc].rs", "d.rs"));
        assert!(!glob_match("[!abc].rs", "a.rs"));
        assert!(glob_match("[^abc].rs", "d.rs"));
    }
}
