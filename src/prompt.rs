//! The single-line text-input overlay — "type a string, press Enter". A sibling
//! of the fuzzy [`Picker`](crate::picker) for the cases where there's no list to
//! filter, just free text (the commit message, …). `App` owns an `Option<Prompt>`
//! and maps the accepted text back to an action by [`PromptKind`].

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptKind {
    /// Accept ⇒ `git commit -m <input>`.
    GitCommit,
    /// Accept ⇒ `claude -p <input>`, answer in a `Pane::Ai`.
    AiAsk,
    /// Accept ⇒ `git checkout -b <input>`.
    NewBranch,
    /// Accept ⇒ `textDocument/rename` with the typed name (LSP).
    LspRename,
}

#[derive(Debug)]
pub struct Prompt {
    pub kind: PromptKind,
    pub title: String,
    pub input: String,
    /// Caret position, a byte index into `input` (always on a char boundary).
    pub cursor: usize,
}

impl Prompt {
    pub fn new(kind: PromptKind, title: impl Into<String>) -> Self {
        Prompt {
            kind,
            title: title.into(),
            input: String::new(),
            cursor: 0,
        }
    }

    /// Like [`Self::new`] but with the input field pre-filled (caret at the end) —
    /// e.g. an AI-suggested commit message you can then edit before confirming.
    pub fn seeded(kind: PromptKind, title: impl Into<String>, input: impl Into<String>) -> Self {
        let input = input.into();
        let cursor = input.len();
        Prompt {
            kind,
            title: title.into(),
            input,
            cursor,
        }
    }

    pub fn insert_char(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        self.input.replace_range(prev..self.cursor, "");
        self.cursor = prev;
    }

    /// Delete the word (and trailing run of spaces) before the caret — Ctrl+W.
    pub fn delete_word(&mut self) {
        let head = &self.input[..self.cursor];
        let trimmed = head.trim_end_matches(' ');
        let cut = trimmed
            .char_indices()
            .rev()
            .find(|&(_, c)| c == ' ')
            .map(|(i, _)| i + 1)
            .unwrap_or(0);
        self.input.replace_range(cut..self.cursor, "");
        self.cursor = cut;
    }

    pub fn move_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    pub fn move_right(&mut self) {
        if self.cursor >= self.input.len() {
            return;
        }
        let step = self.input[self.cursor..]
            .chars()
            .next()
            .map(char::len_utf8)
            .unwrap_or(0);
        self.cursor += step;
    }

    pub fn move_home(&mut self) {
        self.cursor = 0;
    }
    pub fn move_end(&mut self) {
        self.cursor = self.input.len();
    }

    /// Caret column for rendering (chars before the cursor).
    pub fn caret_col(&self) -> usize {
        self.input[..self.cursor].chars().count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_and_caret() {
        let mut p = Prompt::new(PromptKind::GitCommit, "Commit");
        for c in "fix the bug".chars() {
            p.insert_char(c);
        }
        assert_eq!(p.input, "fix the bug");
        assert_eq!(p.caret_col(), 11);
        p.delete_word();
        assert_eq!(p.input, "fix the ");
        p.backspace();
        assert_eq!(p.input, "fix the");
        p.move_home();
        p.move_right();
        p.insert_char('!');
        assert_eq!(p.input, "f!ix the");
    }

    #[test]
    fn utf8_safe() {
        let mut p = Prompt::new(PromptKind::GitCommit, "x");
        for c in "héllo→".chars() {
            p.insert_char(c);
        }
        p.backspace();
        assert_eq!(p.input, "héllo");
        p.move_left();
        p.backspace();
        assert_eq!(p.input, "hélo");
    }
}
