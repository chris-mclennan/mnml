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
/// - Exact filename / extension matches
/// - Patterns starting with `/` are anchored to `config_dir`; others match
///   the basename / any suffix path.
///
/// Doesn't yet handle `{a,b}` brace expansion or `[abc]` char classes —
/// patterns containing those return `false`. Most .editorconfig files in
/// the wild are simple enough that this covers >90% of usage.
fn matches_pattern(pattern: &str, file_path: &Path, config_dir: &Path) -> bool {
    if pattern.contains('{') || pattern.contains('[') {
        // Brace expansion / char classes — TODO.
        return false;
    }
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
    glob_match(pat, &target)
}

fn glob_match(pat: &str, s: &str) -> bool {
    // Simple glob: `**` ⇒ any (incl `/`); `*` ⇒ any non-`/`; `?` ⇒ one char.
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
    fn brace_expansion_skipped_safely() {
        let text = "[*.{js,ts}]\nindent_size = 2";
        let cfg = parse_for_path(
            text,
            std::path::Path::new("/tmp/main.ts"),
            std::path::Path::new("/tmp"),
        );
        // Brace pattern fails to match — settings empty. Better than
        // applying `tab_width = 2` to the wrong files.
        assert_eq!(cfg.tab_width, None);
    }
}
