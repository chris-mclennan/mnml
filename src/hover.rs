//! The LSP hover popup state — a small scrollable box of the language server's
//! hover docs, shown near the cursor after `lsp.hover`. Built from the raw
//! (markdown-ish) hover text with a light cleanup pass + hard-wrap; rendered by
//! [`crate::ui::hover`], scrolled/dismissed in `tui.rs`.

/// Max content width (chars) of the hover box; longer lines word-wrap to this.
pub const MAX_WIDTH: usize = 72;

pub struct HoverPopup {
    /// Display lines — markdown fences dropped, headings/quote markers stripped,
    /// blank runs collapsed, then word-wrapped to [`MAX_WIDTH`].
    pub lines: Vec<String>,
    /// Top visible line.
    pub scroll: usize,
}

impl HoverPopup {
    /// Build from the server's hover text (often markdown). `None` if it's empty
    /// after cleanup (caller should toast "nothing" instead).
    pub fn from_text(text: &str) -> Option<HoverPopup> {
        let mut cleaned: Vec<String> = Vec::new();
        let mut blank_run = 0usize;
        for raw in text.lines() {
            let line = raw.trim_end();
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") {
                continue; // code-fence delimiter — keep the contents, drop the fence
            }
            if trimmed.is_empty() {
                blank_run += 1;
                if blank_run > 1 || cleaned.is_empty() {
                    continue;
                }
                cleaned.push(String::new());
                continue;
            }
            blank_run = 0;
            let l = if trimmed.starts_with('#') {
                trimmed.trim_start_matches('#').trim_start().to_string()
            } else if let Some(rest) = trimmed.strip_prefix("> ") {
                rest.to_string()
            } else {
                line.to_string()
            };
            cleaned.push(l);
        }
        while cleaned.last().is_some_and(String::is_empty) {
            cleaned.pop();
        }
        if cleaned.is_empty() {
            return None;
        }
        let mut lines: Vec<String> = Vec::new();
        for line in &cleaned {
            if line.chars().count() <= MAX_WIDTH {
                lines.push(line.clone());
            } else {
                lines.extend(wrap(line, MAX_WIDTH));
            }
        }
        Some(HoverPopup { lines, scroll: 0 })
    }

    /// Build a popup directly from plain-text lines — no markdown cleanup,
    /// no header stripping. Used by [`crate::app::App::peek_git_change_at_cursor`]
    /// where the content is a diff hunk and the leading `+` / `-` / ` ` are
    /// load-bearing. Long lines word-wrap to [`MAX_WIDTH`].
    pub fn from_lines(input: Vec<String>) -> Option<HoverPopup> {
        if input.is_empty() {
            return None;
        }
        let mut lines: Vec<String> = Vec::new();
        for line in input {
            if line.chars().count() <= MAX_WIDTH {
                lines.push(line);
            } else {
                lines.extend(wrap(&line, MAX_WIDTH));
            }
        }
        Some(HoverPopup { lines, scroll: 0 })
    }

    /// Width of the widest line (capped at [`MAX_WIDTH`]).
    pub fn width(&self) -> usize {
        self.lines
            .iter()
            .map(|l| l.chars().count())
            .max()
            .unwrap_or(0)
            .min(MAX_WIDTH)
    }

    pub fn scroll_by(&mut self, delta: isize) {
        let max = self.lines.len().saturating_sub(1) as isize;
        self.scroll = (self.scroll as isize + delta).clamp(0, max) as usize;
    }
}

/// Greedy word-wrap to `width` columns; a single word longer than `width` is
/// hard-split.
fn wrap(s: &str, width: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    for word in s.split_whitespace() {
        if cur.is_empty() {
            cur = word.to_string();
        } else if cur.chars().count() + 1 + word.chars().count() <= width {
            cur.push(' ');
            cur.push_str(word);
        } else {
            out.push(std::mem::take(&mut cur));
            cur = word.to_string();
        }
        while cur.chars().count() > width {
            let head: String = cur.chars().take(width).collect();
            cur = cur.chars().skip(width).collect();
            out.push(head);
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_fences_and_headings() {
        let h = HoverPopup::from_text("```rust\nfn foo() -> u32\n```\n\n# Docs\n\nDoes a thing.")
            .unwrap();
        assert_eq!(
            h.lines,
            vec!["fn foo() -> u32", "", "Docs", "", "Does a thing."]
        );
    }

    #[test]
    fn empty_after_cleanup_is_none() {
        assert!(HoverPopup::from_text("```\n```\n\n").is_none());
        assert!(HoverPopup::from_text("").is_none());
    }

    #[test]
    fn long_lines_wrap() {
        let long = "word ".repeat(40);
        let h = HoverPopup::from_text(&long).unwrap();
        assert!(h.lines.len() > 1);
        assert!(h.lines.iter().all(|l| l.chars().count() <= MAX_WIDTH));
    }

    #[test]
    fn scroll_clamps() {
        let mut h = HoverPopup::from_text("a\nb\nc").unwrap();
        h.scroll_by(-3);
        assert_eq!(h.scroll, 0);
        h.scroll_by(99);
        assert_eq!(h.scroll, 2);
    }
}
