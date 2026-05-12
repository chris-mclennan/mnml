//! Clipboard abstraction: an internal "register" (mirrors vim's unnamed
//! register, with a linewise flag so a line-yank pastes as a whole line) plus a
//! best-effort bridge to the OS clipboard via `arboard`.
//!
//! - `set` writes to both the register and the system clipboard.
//! - `text` reads the system clipboard; if it has changed out from under us
//!   (e.g. you copied something in another app), that text wins and is treated
//!   as charwise. If `arboard` is unavailable, the register is used.

pub struct Clipboard {
    register: String,
    register_linewise: bool,
    /// Linewise-ness of whatever `text()` last returned (kept in sync so
    /// `is_linewise()` is meaningful right after a `text()` call).
    effective_linewise: bool,
    /// Lazily-created system clipboard handle. `None` ⇒ unavailable; we just use the register.
    sys: Option<arboard::Clipboard>,
}

impl Default for Clipboard {
    fn default() -> Self {
        Self::new()
    }
}

impl Clipboard {
    pub fn new() -> Self {
        Clipboard {
            register: String::new(),
            register_linewise: false,
            effective_linewise: false,
            sys: arboard::Clipboard::new().ok(),
        }
    }

    /// A register-only clipboard with no OS bridge — used in tests so they don't
    /// touch (or depend on) the real system clipboard.
    pub fn detached() -> Self {
        Clipboard {
            register: String::new(),
            register_linewise: false,
            effective_linewise: false,
            sys: None,
        }
    }

    /// Set the clipboard. Writes the register *and* (best-effort) the OS clipboard.
    pub fn set(&mut self, text: impl Into<String>, linewise: bool) {
        self.register = text.into();
        self.register_linewise = linewise;
        self.effective_linewise = linewise;
        if let Some(sys) = self.sys.as_mut() {
            let _ = sys.set_text(self.register.clone());
        }
    }

    /// Current clipboard text. Prefers the OS clipboard when it differs from our
    /// register (something else copied); that case is treated as charwise.
    pub fn text(&mut self) -> String {
        if let Some(sys) = self.sys.as_mut()
            && let Ok(t) = sys.get_text()
            && t != self.register
        {
            self.effective_linewise = false;
            return t;
        }
        self.effective_linewise = self.register_linewise;
        self.register.clone()
    }

    /// Linewise-ness of the most recent `text()` (or `set()`).
    pub fn is_linewise(&self) -> bool {
        self.effective_linewise
    }
}
