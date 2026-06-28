//! Pure free-function helpers extracted from `app/mod.rs` (A-5 of the
//! file-split refactor — 2026-06-28). These functions have no `App`
//! access — they take only their explicit arguments. Lifting them
//! here makes them easier to find and lets `mod.rs` shrink toward the
//! "App state + lifecycle" core it should have been all along.
//!
//! Re-exported from `app/mod.rs` via `pub(crate) use util::*;` so call
//! sites in sibling files (which use `use super::*;`) keep working
//! unchanged.

use std::path::Path;

/// True for files mnml renders as Markdown (md/markdown/mdx/mkd).
pub(crate) fn is_markdown_path(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("md" | "markdown" | "mdx" | "mkd")
    )
}

/// True when `path` is the user's home directory (canonicalized). Used
/// by `App::add_workspace_runtime` to detect the empty-state landing
/// and promote the new folder to primary rather than adding as extra.
/// Mirrors the predicate in `ui::tree_view::is_empty_workspace` —
/// keep both in sync.
pub(crate) fn is_home_workspace(path: &Path) -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    let home = std::path::PathBuf::from(home);
    let home_c = std::fs::canonicalize(&home).unwrap_or(home);
    path == home_c
}

/// True when `target` looks like a URL (any scheme mnml's external-
/// open path handles). Conservative — only the schemes listed.
pub(crate) fn is_url_like(target: &str) -> bool {
    const SCHEMES: &[&str] = &[
        "http://",
        "https://",
        "mailto:",
        "ftp://",
        "ftps://",
        "file://",
        "ssh://",
        "git://",
        "data:",
        "javascript:",
    ];
    SCHEMES.iter().any(|s| target.starts_with(s))
}

/// True for files mnml renders as inline images (png/jpg/jpeg/gif/
/// webp/bmp). Case-insensitive on the extension.
pub(crate) fn is_image_extension(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp")
    )
}

/// OS-aware label for "Reveal in `<file browser>`". The underlying
/// `RevealInFinder` `MenuAction` handler shells out to the right
/// system command per OS.
pub(crate) fn reveal_in_files_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(target_os = "windows") {
        "Reveal in Explorer"
    } else {
        "Reveal in file browser"
    }
}

/// `p` made relative to `workspace` (for `git` arguments). Falls
/// back to `p` if it isn't under `workspace`.
pub(crate) fn rel_path(workspace: &Path, p: &Path) -> String {
    p.strip_prefix(workspace)
        .unwrap_or(p)
        .to_string_lossy()
        .into_owned()
}

/// Walk `text` and return every `(row, col_chars, len_chars)` for a
/// whole-word occurrence of `word`. Char columns (not byte) so the
/// renderer's per-cell painter can align without re-decoding UTF-8.
/// Caps at 5000 hits — a hard safeguard against pathological cases
/// (every occurrence of `the` in a novel-sized file).
pub fn collect_whole_word_occurrences(text: &str, word: &str) -> Vec<(usize, usize, usize)> {
    let word_chars: Vec<char> = word.chars().collect();
    if word_chars.is_empty() {
        return Vec::new();
    }
    let wlen = word_chars.len();
    let is_id = |c: char| c.is_alphanumeric() || c == '_';
    let mut out = Vec::new();
    for (row, line) in text.split('\n').enumerate() {
        let chars: Vec<char> = line.chars().collect();
        let n = chars.len();
        if n < wlen {
            continue;
        }
        let mut i = 0;
        while i + wlen <= n {
            if chars[i..i + wlen] == word_chars[..]
                && (i == 0 || !is_id(chars[i - 1]))
                && (i + wlen == n || !is_id(chars[i + wlen]))
            {
                out.push((row, i, wlen));
                if out.len() >= 5000 {
                    return out;
                }
                i += wlen;
            } else {
                i += 1;
            }
        }
    }
    out
}

/// Byte offset → `(line, col_chars)`. Used by find / search / mark
/// flows to convert match positions into editor-cursor coords.
pub(crate) fn byte_to_line_col(text: &str, byte: usize) -> (usize, usize) {
    let cap = byte.min(text.len());
    let line = text[..cap].bytes().filter(|&b| b == b'\n').count();
    let line_start = text[..cap].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let col = text[line_start..cap].chars().count();
    (line, col)
}

/// Synonym of `byte_to_line_col` — kept for the snippet / LSP edit
/// sites that named the line as "row".
pub(crate) fn byte_to_row_col(text: &str, byte: usize) -> (usize, usize) {
    let byte = byte.min(text.len());
    let row = text[..byte].bytes().filter(|&b| b == b'\n').count();
    let line_start = text[..byte].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let col = text[line_start..byte].chars().count();
    (row, col)
}
