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
    /// True once the unnamed register has been written by an in-mnml
    /// op (yank / delete / set / push_delete). Before that, `p` may
    /// fall back to the OS clipboard (cold-start paste-from-browser).
    /// After that, mnml's register is authoritative — an explicit `Y`
    /// on an empty line yields empty, not stale browser text. R10
    /// nvchad-user SEV-3 (2026-08-22).
    register_owned: bool,
    /// Exactly what mnml last pushed to the OS clipboard, so a later
    /// read can distinguish "nobody has touched it since" from "another
    /// app copied something". `None` means we never pushed, or the push
    /// failed — in which case we cannot detect an external change.
    last_pushed_to_os: Option<String>,
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
            register_owned: false,
            last_pushed_to_os: None,
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
            register_owned: false,
            last_pushed_to_os: None,
        }
    }

    /// Vim `"<reg>` prefix — the next set/text call routes through this
    /// register. Consumed on the next op. `None` clears any prior hint.
    pub fn set_pending_register(&mut self, reg: Option<char>) {
        self.pending_register = reg;
    }

    /// Delete-flavored set: writes to the unnamed register (and system
    /// clipboard) AND pushes onto vim's `"1`-`"9` delete-history ring
    /// (most-recent-first; `"1` is shifted to `"2`, etc., dropping the
    /// oldest beyond `"9`). When a named register is pending, the delete
    /// only goes to that register and the history is unchanged (vim
    /// convention — explicit named-register deletes don't pollute "1-"9).
    pub fn push_delete(&mut self, text: impl Into<String>, linewise: bool) {
        let text: String = text.into();
        let reg = self.pending_register;
        // Set goes through the normal pipeline (honors pending_register).
        self.set(text.clone(), linewise);
        if matches!(reg, None | Some('+')) {
            // Shift "1..="8 → "2..="9, drop "9, write text → "1.
            for i in (1..=8).rev() {
                let from = char::from_digit(i as u32, 10).unwrap();
                let to = char::from_digit((i + 1) as u32, 10).unwrap();
                if let Some(v) = self.named.remove(&from) {
                    self.named.insert(to, v);
                }
            }
            self.named.insert('1', (text, linewise));
        }
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
            // nvchad-user SEV-2 2026-07-11: uppercase register letter
            // `"A`..`"Z` = same slot as `"a`..`"z` but APPEND on write
            // instead of overwrite. Vim canonical for accumulating a
            // chain of yanks under one register handle. Linewise flag
            // follows the LAST written yank (vim convention).
            Some(c) if c.is_ascii_alphabetic() && c.is_ascii_uppercase() => {
                let slot = c.to_ascii_lowercase();
                let existing = self.named.remove(&slot);
                let merged = match existing {
                    Some((prev, _)) => format!("{prev}{text}"),
                    None => text,
                };
                self.named.insert(slot, (merged, linewise));
            }
            Some('0') => {
                self.named.insert('0', (text, linewise));
            }
            // '+' and None ⇒ unnamed + system clipboard
            _ => {
                self.register = text;
                self.register_linewise = linewise;
                self.effective_linewise = linewise;
                self.register_owned = true;
                let pushed = self.register.clone();
                self.last_pushed_to_os = match self.sys.as_mut() {
                    Some(sys) => sys.set_text(pushed.clone()).ok().map(|()| pushed),
                    None => None,
                };
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
            // `"a`-`"z` AND `"A`-`"Z` — both address the same slot for
            // reads (uppercase-append only affects writes). Normalize
            // to lowercase before the map lookup.
            Some(c) if c.is_ascii_alphabetic() => {
                let slot = c.to_ascii_lowercase();
                if let Some((t, linewise)) = self.named.get(&slot) {
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
            Some(c) if c.is_ascii_digit() && c != '0' => {
                // "1-"9 — delete history.
                if let Some((t, linewise)) = self.named.get(&c) {
                    self.effective_linewise = *linewise;
                    return t.clone();
                }
                self.effective_linewise = false;
                String::new()
            }
            // '+' — explicit system-clipboard read. Always defers
            // to the OS, ignoring the in-mnml register.
            Some('+') => {
                if let Some(sys) = self.sys.as_mut()
                    && let Ok(t) = sys.get_text()
                {
                    self.effective_linewise = false;
                    return t;
                }
                self.effective_linewise = false;
                String::new()
            }
            // None ⇒ unnamed. Two paths:
            //   (a) `register_owned == false` — no in-mnml op has
            //       written the register yet. Cold-start paste-
            //       from-browser: fall back to the OS clipboard.
            //   (b) `register_owned == true` — mnml owns the
            //       register. Return it as-is. R10 nvchad-user
            //       SEV-3 (2026-08-22) — was: "OS clipboard wins
            //       when it differs", which silently pasted stale
            //       browser text after an explicit `Y` on an
            //       empty line cleared the register to "".
            _ => {
                let os_text = self.sys.as_mut().and_then(|s| s.get_text().ok());
                if let Some(t) = os_text
                    && Self::os_clipboard_wins(
                        self.register_owned,
                        self.last_pushed_to_os.as_deref(),
                        &t,
                    )
                {
                    self.effective_linewise = false;
                    return t;
                }
                self.effective_linewise = self.register_linewise;
                self.register.clone()
            }
        }
    }

    /// Does the OS clipboard win over mnml's unnamed register?
    ///
    /// Latching on "mnml has written the register" alone is not enough:
    /// it makes the register authoritative for the rest of the session,
    /// so copying in another app never reaches mnml again. Comparing the
    /// OS text against what we ourselves last pushed distinguishes the
    /// two cases the latch conflated.
    fn os_clipboard_wins(register_owned: bool, last_pushed: Option<&str>, os_text: &str) -> bool {
        match (register_owned, last_pushed) {
            // Cold start — no in-mnml op has written the register, so a
            // paste should pick up whatever the user copied elsewhere.
            (false, _) => true,
            // We pushed, and the OS still holds exactly that: nothing
            // external happened, so our register is authoritative. This
            // is the R10 case — `Y` on an empty line yields empty, not
            // stale browser text.
            (true, Some(ours)) => ours != os_text,
            // We own the register but could not push (no OS bridge, or
            // the push failed), so we cannot detect an external change.
            // Trust mnml — the user just yanked here.
            (true, None) => false,
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

#[cfg(test)]
mod tests {
    use super::*;

    // These exercise the decision in isolation, so nothing here touches
    // (or depends on) the real system clipboard.

    /// Cold start: no in-mnml op has written the register yet, so a
    /// paste picks up whatever the user copied in another app.
    #[test]
    fn os_wins_before_mnml_has_written_the_register() {
        assert!(Clipboard::os_clipboard_wins(false, None, "from browser"));
        assert!(Clipboard::os_clipboard_wins(
            false,
            Some("stale"),
            "from browser"
        ));
    }

    /// The R10 case that motivated the original latch: `Y` on an empty
    /// line sets the register to "", we push "", and the OS still holds
    /// "". Our register must win, or the user pastes stale browser text.
    #[test]
    fn register_wins_when_os_still_holds_what_we_pushed() {
        assert!(!Clipboard::os_clipboard_wins(true, Some(""), ""));
        assert!(!Clipboard::os_clipboard_wins(
            true,
            Some("yanked"),
            "yanked"
        ));
    }

    /// The regression the latch introduced: once mnml owned the
    /// register, copying in another app was ignored for the rest of the
    /// session. A differing OS clipboard means someone else wrote it.
    #[test]
    fn os_wins_after_an_external_copy() {
        assert!(Clipboard::os_clipboard_wins(
            true,
            Some("yanked in mnml"),
            "copied in browser"
        ));
    }

    /// No OS bridge, or the push failed — we cannot detect an external
    /// change, so trust the register the user just yanked into.
    #[test]
    fn register_wins_when_we_could_not_push() {
        assert!(!Clipboard::os_clipboard_wins(true, None, "anything"));
    }

    /// End-to-end on a detached clipboard: with no OS bridge, set/text
    /// round-trips the register and never consults the OS.
    #[test]
    fn detached_clipboard_round_trips_the_register() {
        let mut c = Clipboard::detached();
        c.set("hello".to_string(), false);
        assert_eq!(c.text(), "hello");
        c.set(String::new(), false);
        assert_eq!(c.text(), "", "an explicit empty yank must yield empty");
    }
}
