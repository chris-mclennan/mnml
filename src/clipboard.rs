//! Clipboard abstraction with vim-style named registers.
//!
//! - The default (unnamed) register doubles as the system clipboard via
//!   `arboard`, and also auto-mirrors into `"0` on every yank (vim convention:
//!   `"0` is "last yank"). The "last yank" mirror happens only when the op
//!   was a yank — `EditOp::YankLine`/`YankSelection`/`YankBlock` flag that
//!   via `set_last_yank` rather than via `set()`. Other ops (delete, cut)
//!   still write to the unnamed register but skip `"0`.
//! - `"a`-`"z` named registers (lowercase only — vim's uppercase-append form
//!   is a follow-up); writes go via `pending_register`, set by the input
//!   handler before the op runs.
//! - `"+` mirrors the system clipboard (same as the default — explicit form).
//! - `"_` blackhole — `set` is a no-op; `text` returns `""`.
//! - Any non-recognized `pending_register` char ⇒ unnamed register (safe
//!   fallback so a stray `"X` doesn't surprise the user).

use std::collections::HashMap;

pub struct Clipboard {
    register: String,
    register_linewise: bool,
    /// Linewise-ness of whatever `text()` last returned (kept in sync so
    /// `is_linewise()` is meaningful right after a `text()` call).
    effective_linewise: bool,
    /// Lazily-created system clipboard handle. `None` ⇒ unavailable; we just use the register.
    sys: Option<arboard::Clipboard>,
    /// Vim named registers — `a`-`z` (lowercase). Each entry is
    /// `(text, linewise)`. `'0'` is also stored here on each yank.
    named: HashMap<char, (String, bool)>,
    /// Register hint for the *next* clipboard op (set / text). Set by
    /// `EditOp::SetRegisterHint` which the vim handler emits before
    /// yank/paste/delete. Consumed (reset) on the first set/text call.
    pending_register: Option<char>,
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
            named: HashMap::new(),
            pending_register: None,
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
            named: HashMap::new(),
            pending_register: None,
        }
    }

    /// Vim `"<reg>` prefix — the next set/text call routes through this
    /// register. Consumed on the next op. `None` clears any prior hint.
    pub fn set_pending_register(&mut self, reg: Option<char>) {
        self.pending_register = reg;
    }

    /// Set the clipboard. Writes the register *and* (best-effort) the OS
    /// clipboard. Honors `pending_register` if set:
    /// - `'_'` ⇒ blackhole (no-op, but resets pending)
    /// - `'+'` ⇒ system clipboard (same as unnamed)
    /// - `'a'..='z'` ⇒ named register; system clipboard *not* touched
    /// - other ⇒ unnamed (safe fallback)
    pub fn set(&mut self, text: impl Into<String>, linewise: bool) {
        let text: String = text.into();
        let reg = self.pending_register.take();
        match reg {
            Some('_') => { /* blackhole — drop */ }
            Some(c) if c.is_ascii_alphabetic() && c.is_ascii_lowercase() => {
                self.named.insert(c, (text, linewise));
            }
            Some('0') => {
                self.named.insert('0', (text, linewise));
            }
            // '+' and None ⇒ unnamed + system clipboard
            _ => {
                self.register = text;
                self.register_linewise = linewise;
                self.effective_linewise = linewise;
                if let Some(sys) = self.sys.as_mut() {
                    let _ = sys.set_text(self.register.clone());
                }
            }
        }
    }

    /// Yank-flavored set: writes the same way `set` does AND mirrors into
    /// `"0` (vim's "last yank" register) when the op went to the unnamed
    /// register. Called by the editor's yank ops.
    pub fn set_yank(&mut self, text: impl Into<String>, linewise: bool) {
        let text: String = text.into();
        let reg = self.pending_register;
        self.set(text.clone(), linewise);
        // Mirror into "0 only when the explicit register wasn't named —
        // i.e., when the yank went to the unnamed register.
        if matches!(reg, None | Some('+')) {
            self.named.insert('0', (text, linewise));
        }
    }

    /// Current clipboard text. Prefers the OS clipboard when it differs from
    /// our register (something else copied); that case is treated as charwise.
    /// Honors `pending_register` if set.
    pub fn text(&mut self) -> String {
        let reg = self.pending_register.take();
        match reg {
            Some('_') => {
                self.effective_linewise = false;
                String::new()
            }
            Some(c) if c.is_ascii_alphabetic() && c.is_ascii_lowercase() => {
                if let Some((t, linewise)) = self.named.get(&c) {
                    self.effective_linewise = *linewise;
                    return t.clone();
                }
                self.effective_linewise = false;
                String::new()
            }
            Some('0') => {
                if let Some((t, linewise)) = self.named.get(&'0') {
                    self.effective_linewise = *linewise;
                    return t.clone();
                }
                self.effective_linewise = false;
                String::new()
            }
            // '+' and None ⇒ system / unnamed
            _ => {
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
        }
    }

    /// Linewise-ness of the most recent `text()` (or `set()`).
    pub fn is_linewise(&self) -> bool {
        self.effective_linewise
    }

    /// Read-only snapshot of the named registers (`a`-`z`, `0`). Used by
    /// `:reg` / `:registers` for the display dump.
    pub fn named_registers(&self) -> &HashMap<char, (String, bool)> {
        &self.named
    }
}
