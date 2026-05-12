//! Clipboard abstraction. P0 has just the internal "register" (mirrors vim's
//! unnamed register) plus a `linewise` flag so a line-yank pastes as a whole
//! line later. The `arboard` system-clipboard bridge is wired in P1.

#[derive(Debug, Default, Clone)]
pub struct Clipboard {
    text: String,
    /// True when the content was yanked linewise (vim `yy`/`dd`) — affects how `PasteAfter`/`PasteBefore` behave.
    linewise: bool,
}

impl Clipboard {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&mut self, text: impl Into<String>, linewise: bool) {
        self.text = text.into();
        self.linewise = linewise;
    }

    pub fn get(&self) -> &str {
        &self.text
    }

    pub fn is_linewise(&self) -> bool {
        self.linewise
    }
}
