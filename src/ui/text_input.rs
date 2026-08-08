//! Shared common-text-key routing. 2026-08-08 — user asked "common
//! Ctrl/Cmd commands should work anywhere I can type". This module
//! captures the shortcut set every text-input surface in mnml
//! should honor and hands each surface a single routing call so
//! they stay consistent as new surfaces get added.
//!
//! Two shapes of text-input exist across mnml:
//!
//! * **Full-cursor** — a `String` with a byte cursor: prompt overlay,
//!   integration edit fields, glyph builder fields, settings text
//!   edit, request-pane fields. All the motion + kill shortcuts
//!   apply.
//! * **Append-only** — a fuzzy-filter `String` where the caret is
//!   implicitly at the end: pickers, sidebar filters (tree, HTTP,
//!   integrations, todos/notes/sessions, help/settings overlay
//!   filters), the `:` cmdline, browser dev-panel filters, etc.
//!   Motion shortcuts are no-ops; kill shortcuts (Ctrl+U /
//!   Ctrl+W) still make sense.
//!
//! The two shapes share this module's helpers rather than
//! diverging per-surface — historically every append-only filter
//! learned Ctrl+U + Ctrl+W separately (or not at all), and every
//! full-cursor surface learned Ctrl+K + Alt+←/→ separately (or not
//! at all). Now they route through one place.
//!
//! Shortcut set (macOS Cmd+X usually arrives as a bracketed-paste
//! `Event::Paste` for Cmd+V, otherwise as a Ctrl-modified key on
//! Linux terminals — this module handles the Ctrl path):
//!
//! | Key                       | Op                          |
//! |---------------------------|-----------------------------|
//! | Home / Ctrl+A             | move to line start          |
//! | End / Ctrl+E              | move to line end            |
//! | Left / Right              | move one char               |
//! | Alt+← / Ctrl+←            | move one word left          |
//! | Alt+→ / Ctrl+→            | move one word right         |
//! | Backspace                 | delete char before caret    |
//! | Delete                    | delete char at caret        |
//! | Ctrl+W / Alt+Backspace    | delete word before caret    |
//! | Ctrl+U / Cmd+Backspace    | delete to line start        |
//! | Ctrl+K                    | delete to line end          |
//! | Ctrl+V                    | paste clipboard             |
//! | PageUp / PageDown         | multi-line scroll           |

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::clipboard::Clipboard;

/// Did `handle_common_text_key` dispatch the key, or should the
/// caller keep matching?
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextKeyResult {
    Handled,
    NotHandled,
}

/// Pluggable text-input operations. Callers set only the ops their
/// surface supports; missing ops make the corresponding shortcut
/// fall through as `NotHandled`.
///
/// State is stored as one `&mut S` and every op is a bare `fn`
/// pointer taking `&mut S`, which sidesteps the closure-capture /
/// borrow-splitting problem you'd hit with `Option<&mut dyn
/// FnMut(...)>`. Each surface writes closures that just call
/// methods on `S` (see `handle_prompt_key` for a call site).
pub struct TextOps<'a, S: ?Sized> {
    pub state: &'a mut S,
    pub insert_str: Option<fn(&mut S, &str)>,
    pub backspace: Option<fn(&mut S)>,
    pub delete_forward: Option<fn(&mut S)>,
    pub delete_word_back: Option<fn(&mut S)>,
    pub delete_to_start: Option<fn(&mut S)>,
    pub delete_to_end: Option<fn(&mut S)>,
    pub move_left: Option<fn(&mut S)>,
    pub move_right: Option<fn(&mut S)>,
    pub move_word_left: Option<fn(&mut S)>,
    pub move_word_right: Option<fn(&mut S)>,
    pub move_home: Option<fn(&mut S)>,
    pub move_end: Option<fn(&mut S)>,
    pub page_up: Option<fn(&mut S)>,
    pub page_down: Option<fn(&mut S)>,
}

impl<'a, S: ?Sized> TextOps<'a, S> {
    pub fn new(state: &'a mut S) -> Self {
        Self {
            state,
            insert_str: None,
            backspace: None,
            delete_forward: None,
            delete_word_back: None,
            delete_to_start: None,
            delete_to_end: None,
            move_left: None,
            move_right: None,
            move_word_left: None,
            move_word_right: None,
            move_home: None,
            move_end: None,
            page_up: None,
            page_down: None,
        }
    }
}

/// Route a raw `KeyEvent` through the common text-input shortcuts.
/// Returns `Handled` when the key matched one of the shortcuts AND
/// the surface supplied the corresponding op; `NotHandled` in every
/// other case (including "key matched but op is None" — the caller
/// should keep looking).
///
/// `paste_text` is the clipboard content the caller has already
/// read (typically via [`crate::clipboard::Clipboard::text`]) —
/// pre-fetching is the caller's responsibility because the helper
/// otherwise couldn't borrow both the app-wide clipboard AND the
/// surface's mutable state at once. Callers who don't want to
/// support paste can pass `None`. See [`clipboard_text_if_paste`]
/// for the "fetch iff the key IS Ctrl+V/Cmd+V" pattern.
///
/// This deliberately does NOT handle `KeyCode::Char(c)` insertion,
/// `Enter`, `Esc`, `Tab`, or arrow keys without a modifier — those
/// have surface-specific meaning (e.g. Enter = submit, Esc = close,
/// arrow = focus cycle) and stay under the caller's control.
pub fn handle_common_text_key<S: ?Sized>(
    key: KeyEvent,
    paste_text: Option<&str>,
    ops: TextOps<'_, S>,
) -> TextKeyResult {
    let m = key.modifiers;
    let ctrl = m.contains(KeyModifiers::CONTROL);
    let alt = m.contains(KeyModifiers::ALT);
    let shift = m.contains(KeyModifiers::SHIFT);
    // Cmd on macOS surfaces as SUPER when raw. Cmd+V normally arrives
    // as bracketed paste (Event::Paste) upstream — this branch mostly
    // covers Linux Ctrl+V + terminals that don't translate SUPER.
    let sup = m.contains(KeyModifiers::SUPER);

    // --- Clipboard paste (Ctrl+V / Cmd+V). Prefer this before other
    // Ctrl+letter branches so a paste never misroutes as motion.
    if (ctrl || sup) && !alt && matches!(key.code, KeyCode::Char('v' | 'V')) {
        if let (Some(f), Some(text)) = (ops.insert_str, paste_text) {
            let trimmed = text.trim_end_matches('\n');
            if !trimmed.is_empty() {
                f(ops.state, trimmed);
            }
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }

    // --- Deletion.
    if matches!(key.code, KeyCode::Backspace) {
        // Cmd+Backspace on macOS = kill to line start (Emacs/readline
        // Ctrl+U equivalent). Alt+Backspace = kill previous word.
        if sup
            && !ctrl
            && let Some(f) = ops.delete_to_start
        {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        if (alt || ctrl)
            && let Some(f) = ops.delete_word_back
        {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        // Plain Backspace.
        if let Some(f) = ops.backspace {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::Delete) {
        if let Some(f) = ops.delete_forward {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if ctrl && !alt && matches!(key.code, KeyCode::Char('w' | 'W')) {
        if let Some(f) = ops.delete_word_back {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if ctrl && !alt && matches!(key.code, KeyCode::Char('u' | 'U')) {
        if let Some(f) = ops.delete_to_start {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if ctrl && !alt && matches!(key.code, KeyCode::Char('k' | 'K')) {
        if let Some(f) = ops.delete_to_end {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }

    // --- Motion. Ctrl+A / Ctrl+E for line start/end; Home/End same.
    if ctrl && !alt && matches!(key.code, KeyCode::Char('a' | 'A')) {
        if let Some(f) = ops.move_home {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if ctrl && !alt && matches!(key.code, KeyCode::Char('e' | 'E')) {
        if let Some(f) = ops.move_end {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::Home) && !ctrl && !alt {
        if let Some(f) = ops.move_home {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::End) && !ctrl && !alt {
        if let Some(f) = ops.move_end {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }

    // Word-wise motion: Alt+← / Alt+→ (mac idiom); Ctrl+← / Ctrl+→
    // (Windows / Linux idiom). Shift-variants are selection-extend
    // in editors — not applicable to single-line prompts, but we
    // still route them so the caret moves for prompts that don't
    // model selection.
    let _ = shift;
    if matches!(key.code, KeyCode::Left) && (ctrl || alt) {
        if let Some(f) = ops.move_word_left {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::Right) && (ctrl || alt) {
        if let Some(f) = ops.move_word_right {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::Left) && !ctrl && !alt {
        if let Some(f) = ops.move_left {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::Right) && !ctrl && !alt {
        if let Some(f) = ops.move_right {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }

    // --- Paging (multi-line inputs only).
    if matches!(key.code, KeyCode::PageUp) && !ctrl && !alt {
        if let Some(f) = ops.page_up {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }
    if matches!(key.code, KeyCode::PageDown) && !ctrl && !alt {
        if let Some(f) = ops.page_down {
            f(ops.state);
            return TextKeyResult::Handled;
        }
        return TextKeyResult::NotHandled;
    }

    TextKeyResult::NotHandled
}

/// Read `clipboard.text()` iff `key` is Ctrl+V / Cmd+V, else
/// return `None`. Lets callers avoid a system-clipboard read on
/// every keystroke while still passing the pre-fetched paste
/// content into [`handle_common_text_key`].
pub fn clipboard_text_if_paste(key: KeyEvent, clipboard: &mut Clipboard) -> Option<String> {
    let m = key.modifiers;
    let ctrl = m.contains(KeyModifiers::CONTROL);
    let sup = m.contains(KeyModifiers::SUPER);
    let alt = m.contains(KeyModifiers::ALT);
    if (ctrl || sup) && !alt && matches!(key.code, KeyCode::Char('v' | 'V')) {
        Some(clipboard.text())
    } else {
        None
    }
}

/// Convenience for the many append-only filter surfaces (pickers,
/// sidebar filters, the `:` cmdline). Handles Backspace, Ctrl+U
/// (clear), Ctrl+W (word back), Ctrl+H (backspace alias), and
/// Ctrl+V paste when `clipboard` is supplied. Ignores motion,
/// forward-delete, and Ctrl+K — none of those apply to
/// append-only inputs.
///
/// `buf` is the raw filter string; newlines / control chars in
/// pasted text are stripped so the single-line invariant is
/// preserved.
pub fn handle_filter_shortcut(
    key: KeyEvent,
    buf: &mut String,
    clipboard: Option<&mut Clipboard>,
) -> TextKeyResult {
    let m = key.modifiers;
    let ctrl = m.contains(KeyModifiers::CONTROL);
    let alt = m.contains(KeyModifiers::ALT);
    let sup = m.contains(KeyModifiers::SUPER);
    match key.code {
        KeyCode::Backspace if sup && !ctrl => {
            buf.clear();
            TextKeyResult::Handled
        }
        KeyCode::Backspace if alt || ctrl => {
            delete_word_back_in_string(buf);
            TextKeyResult::Handled
        }
        KeyCode::Backspace => {
            buf.pop();
            TextKeyResult::Handled
        }
        KeyCode::Char('h' | 'H') if ctrl => {
            buf.pop();
            TextKeyResult::Handled
        }
        KeyCode::Char('u' | 'U') if ctrl => {
            buf.clear();
            TextKeyResult::Handled
        }
        KeyCode::Char('w' | 'W') if ctrl => {
            delete_word_back_in_string(buf);
            TextKeyResult::Handled
        }
        KeyCode::Char('v' | 'V') if (ctrl || sup) && !alt => {
            if let Some(clip) = clipboard {
                let text = clip.text();
                for c in text.chars() {
                    if c != '\n' && c != '\r' && (c as u32) >= 0x20 {
                        buf.push(c);
                    }
                }
                TextKeyResult::Handled
            } else {
                TextKeyResult::NotHandled
            }
        }
        _ => TextKeyResult::NotHandled,
    }
}

/// Kill the trailing whitespace-run and preceding word from `buf`.
/// Shared helper for surfaces whose Ctrl+W impl was previously
/// missing (grep filter, tree filter, etc.) — mirrors the
/// character class the editor's Ctrl+W uses so the behavior reads
/// the same across the app.
pub fn delete_word_back_in_string(buf: &mut String) {
    let bytes = buf.as_bytes();
    let mut end = bytes.len();
    // Skip trailing whitespace.
    while end > 0 {
        let start = prev_char_boundary(buf, end);
        if buf[start..end]
            .chars()
            .next()
            .is_some_and(|c| c.is_whitespace())
        {
            end = start;
        } else {
            break;
        }
    }
    // Then skip the word run (non-whitespace).
    while end > 0 {
        let start = prev_char_boundary(buf, end);
        if buf[start..end]
            .chars()
            .next()
            .is_some_and(|c| !c.is_whitespace())
        {
            end = start;
        } else {
            break;
        }
    }
    buf.truncate(end);
}

fn prev_char_boundary(s: &str, mut i: usize) -> usize {
    if i == 0 {
        return 0;
    }
    i -= 1;
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    // --- TextOps / handle_common_text_key

    struct Buf {
        s: String,
        cur: usize,
        pasted: bool,
    }

    fn ops_for(b: &mut Buf) -> TextOps<'_, Buf> {
        let mut o = TextOps::new(b);
        o.insert_str = Some(|b, s| {
            b.s.insert_str(b.cur, s);
            b.cur += s.len();
            b.pasted = true;
        });
        o.backspace = Some(|b| {
            if b.cur > 0 {
                b.cur -= 1;
                b.s.remove(b.cur);
            }
        });
        o.delete_forward = Some(|b| {
            if b.cur < b.s.len() {
                b.s.remove(b.cur);
            }
        });
        o.delete_word_back = Some(|b| {
            let head = &b.s[..b.cur];
            let cut = head
                .trim_end_matches(char::is_whitespace)
                .rfind(char::is_whitespace)
                .map(|i| i + 1)
                .unwrap_or(0);
            b.s.replace_range(cut..b.cur, "");
            b.cur = cut;
        });
        o.delete_to_start = Some(|b| {
            b.s.replace_range(..b.cur, "");
            b.cur = 0;
        });
        o.delete_to_end = Some(|b| {
            b.s.truncate(b.cur);
        });
        o.move_left = Some(|b| {
            if b.cur > 0 {
                b.cur -= 1;
            }
        });
        o.move_right = Some(|b| {
            if b.cur < b.s.len() {
                b.cur += 1;
            }
        });
        o.move_home = Some(|b| b.cur = 0);
        o.move_end = Some(|b| b.cur = b.s.len());
        o
    }

    fn dispatch(b: &mut Buf, k: KeyEvent) -> TextKeyResult {
        handle_common_text_key(k, None, ops_for(b))
    }

    #[test]
    fn ctrl_a_moves_home() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 3,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Char('a'), KeyModifiers::CONTROL)),
            TextKeyResult::Handled
        );
        assert_eq!(b.cur, 0);
    }

    #[test]
    fn ctrl_e_moves_end() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 0,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Char('e'), KeyModifiers::CONTROL)),
            TextKeyResult::Handled
        );
        assert_eq!(b.cur, 3);
    }

    #[test]
    fn ctrl_u_kills_to_start() {
        let mut b = Buf {
            s: "foo bar baz".into(),
            cur: 7,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Char('u'), KeyModifiers::CONTROL)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, " baz");
        assert_eq!(b.cur, 0);
    }

    #[test]
    fn ctrl_k_kills_to_end() {
        let mut b = Buf {
            s: "foo bar baz".into(),
            cur: 3,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Char('k'), KeyModifiers::CONTROL)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "foo");
        assert_eq!(b.cur, 3);
    }

    #[test]
    fn ctrl_w_kills_word() {
        let mut b = Buf {
            s: "foo bar baz".into(),
            cur: 7,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Char('w'), KeyModifiers::CONTROL)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "foo  baz");
        assert_eq!(b.cur, 4);
    }

    #[test]
    fn alt_backspace_kills_word() {
        let mut b = Buf {
            s: "one two".into(),
            cur: 7,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Backspace, KeyModifiers::ALT)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "one ");
        assert_eq!(b.cur, 4);
    }

    #[test]
    fn cmd_backspace_kills_to_start() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 3,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Backspace, KeyModifiers::SUPER)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "");
        assert_eq!(b.cur, 0);
    }

    #[test]
    fn plain_backspace_deletes_one_char() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 3,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Backspace, KeyModifiers::NONE)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "ab");
        assert_eq!(b.cur, 2);
    }

    #[test]
    fn delete_removes_char_at_caret() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 1,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Delete, KeyModifiers::NONE)),
            TextKeyResult::Handled
        );
        assert_eq!(b.s, "ac");
        assert_eq!(b.cur, 1);
    }

    #[test]
    fn home_end_agree() {
        let mut b = Buf {
            s: "abc".into(),
            cur: 2,
            pasted: false,
        };
        assert_eq!(
            dispatch(&mut b, key(KeyCode::Home, KeyModifiers::NONE)),
            TextKeyResult::Handled
        );
        assert_eq!(b.cur, 0);
        assert_eq!(
            dispatch(&mut b, key(KeyCode::End, KeyModifiers::NONE)),
            TextKeyResult::Handled
        );
        assert_eq!(b.cur, 3);
    }

    #[test]
    fn ctrl_v_inserts_paste_text() {
        let mut b = Buf {
            s: "".into(),
            cur: 0,
            pasted: false,
        };
        let r = handle_common_text_key(
            key(KeyCode::Char('v'), KeyModifiers::CONTROL),
            Some("pasted"),
            ops_for(&mut b),
        );
        assert_eq!(r, TextKeyResult::Handled);
        assert_eq!(b.s, "pasted");
        assert!(b.pasted);
    }

    #[test]
    fn ctrl_v_without_paste_text_falls_through() {
        // Ctrl+V but the caller supplied no paste text — the helper
        // treats it as unsupported (NotHandled) so callers can
        // fall back to other Ctrl+V bindings if desired.
        let mut b = Buf {
            s: "".into(),
            cur: 0,
            pasted: false,
        };
        let r = handle_common_text_key(
            key(KeyCode::Char('v'), KeyModifiers::CONTROL),
            None,
            ops_for(&mut b),
        );
        assert_eq!(r, TextKeyResult::NotHandled);
    }

    #[test]
    fn clipboard_text_if_paste_only_fires_on_paste_key() {
        let mut clip = Clipboard::detached();
        clip.set("hi", false);
        assert!(
            clipboard_text_if_paste(key(KeyCode::Char('v'), KeyModifiers::CONTROL), &mut clip)
                .is_some()
        );
        assert!(
            clipboard_text_if_paste(key(KeyCode::Char('V'), KeyModifiers::SUPER), &mut clip)
                .is_some()
        );
        assert!(
            clipboard_text_if_paste(key(KeyCode::Char('v'), KeyModifiers::NONE), &mut clip)
                .is_none()
        );
        assert!(
            clipboard_text_if_paste(key(KeyCode::Char('a'), KeyModifiers::CONTROL), &mut clip)
                .is_none()
        );
    }

    #[test]
    fn missing_op_falls_through() {
        let mut b = Buf {
            s: "".into(),
            cur: 0,
            pasted: false,
        };
        let ops = TextOps::new(&mut b);
        // No move_word_left op.
        let r = handle_common_text_key(key(KeyCode::Left, KeyModifiers::ALT), None, ops);
        assert_eq!(r, TextKeyResult::NotHandled);
    }

    #[test]
    fn irrelevant_keys_report_not_handled() {
        let mut b = Buf {
            s: "".into(),
            cur: 0,
            pasted: false,
        };
        let r = dispatch(&mut b, key(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(r, TextKeyResult::NotHandled);
        let r = dispatch(&mut b, key(KeyCode::Char('x'), KeyModifiers::NONE));
        assert_eq!(r, TextKeyResult::NotHandled);
    }

    // --- append-only helper

    #[test]
    fn filter_ctrl_u_clears() {
        let mut s = String::from("hello");
        let r =
            handle_filter_shortcut(key(KeyCode::Char('u'), KeyModifiers::CONTROL), &mut s, None);
        assert_eq!(r, TextKeyResult::Handled);
        assert!(s.is_empty());
    }

    #[test]
    fn filter_ctrl_w_kills_word() {
        let mut s = String::from("foo bar");
        let r =
            handle_filter_shortcut(key(KeyCode::Char('w'), KeyModifiers::CONTROL), &mut s, None);
        assert_eq!(r, TextKeyResult::Handled);
        assert_eq!(s, "foo ");
    }

    #[test]
    fn filter_backspace_pops() {
        let mut s = String::from("abc");
        let r = handle_filter_shortcut(key(KeyCode::Backspace, KeyModifiers::NONE), &mut s, None);
        assert_eq!(r, TextKeyResult::Handled);
        assert_eq!(s, "ab");
    }

    #[test]
    fn filter_paste_strips_newlines() {
        let mut s = String::new();
        let mut clip = Clipboard::detached();
        clip.set("one\ntwo\r\nthree", false);
        let r = handle_filter_shortcut(
            key(KeyCode::Char('v'), KeyModifiers::CONTROL),
            &mut s,
            Some(&mut clip),
        );
        assert_eq!(r, TextKeyResult::Handled);
        assert_eq!(s, "onetwothree");
    }

    #[test]
    fn filter_irrelevant_falls_through() {
        let mut s = String::from("abc");
        let r = handle_filter_shortcut(key(KeyCode::Char('x'), KeyModifiers::NONE), &mut s, None);
        assert_eq!(r, TextKeyResult::NotHandled);
        assert_eq!(s, "abc");
    }

    #[test]
    fn word_back_helper_multibyte_safe() {
        let mut s = String::from("héllo wörld");
        delete_word_back_in_string(&mut s);
        assert_eq!(s, "héllo ");
    }
}
