//! Key-spec parsing — turn strings like `"ctrl+shift+p"`, `"enter"`, `"down"`,
//! `"a"` into `crossterm::event::KeyEvent`s. Used by the IPC channel (so e2e
//! scripts can send keys by name) and, later, by the config-driven keymap
//! resolver for `[keys.*]`.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// Parse a key spec. Modifiers (`ctrl+`, `shift+`, `alt+`) may prefix in any
/// order; the final token is a named key or a single character. Returns `None`
/// for anything unrecognized.
pub fn parse_key_spec(spec: &str) -> Option<KeyEvent> {
    let spec = spec.trim();
    if spec.is_empty() {
        return None;
    }
    let mut mods = KeyModifiers::NONE;
    let mut rest = spec;
    loop {
        let lower = rest.to_ascii_lowercase();
        if let Some(r) = lower
            .strip_prefix("ctrl+")
            .or_else(|| lower.strip_prefix("c-"))
        {
            mods |= KeyModifiers::CONTROL;
            rest = &rest[rest.len() - r.len()..];
        } else if let Some(r) = lower
            .strip_prefix("shift+")
            .or_else(|| lower.strip_prefix("s-"))
        {
            mods |= KeyModifiers::SHIFT;
            rest = &rest[rest.len() - r.len()..];
        } else if let Some(r) = lower
            .strip_prefix("alt+")
            .or_else(|| lower.strip_prefix("a-"))
            .or_else(|| lower.strip_prefix("meta+"))
        {
            mods |= KeyModifiers::ALT;
            rest = &rest[rest.len() - r.len()..];
        } else {
            break;
        }
    }
    let code = key_code(rest)?;
    Some(KeyEvent::new(code, mods))
}

fn key_code(token: &str) -> Option<KeyCode> {
    let t = token.to_ascii_lowercase();
    Some(match t.as_str() {
        "enter" | "return" | "cr" => KeyCode::Enter,
        "tab" => KeyCode::Tab,
        "backtab" => KeyCode::BackTab,
        "esc" | "escape" => KeyCode::Esc,
        "space" => KeyCode::Char(' '),
        "backspace" | "bs" => KeyCode::Backspace,
        "delete" | "del" => KeyCode::Delete,
        "insert" | "ins" => KeyCode::Insert,
        "up" => KeyCode::Up,
        "down" => KeyCode::Down,
        "left" => KeyCode::Left,
        "right" => KeyCode::Right,
        "home" => KeyCode::Home,
        "end" => KeyCode::End,
        "pageup" | "pgup" => KeyCode::PageUp,
        "pagedown" | "pgdn" | "pgdown" => KeyCode::PageDown,
        "f1" => KeyCode::F(1),
        "f2" => KeyCode::F(2),
        "f3" => KeyCode::F(3),
        "f4" => KeyCode::F(4),
        "f5" => KeyCode::F(5),
        "f6" => KeyCode::F(6),
        "f7" => KeyCode::F(7),
        "f8" => KeyCode::F(8),
        "f9" => KeyCode::F(9),
        "f10" => KeyCode::F(10),
        "f11" => KeyCode::F(11),
        "f12" => KeyCode::F(12),
        _ => {
            let mut chars = token.chars();
            let c = chars.next()?;
            if chars.next().is_some() {
                return None; // multi-char and not a known name
            }
            KeyCode::Char(c)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_modified_and_named() {
        let e = parse_key_spec("ctrl+q").unwrap();
        assert_eq!(e.code, KeyCode::Char('q'));
        assert!(e.modifiers.contains(KeyModifiers::CONTROL));
        assert_eq!(parse_key_spec("enter").unwrap().code, KeyCode::Enter);
        assert_eq!(parse_key_spec("down").unwrap().code, KeyCode::Down);
        let e = parse_key_spec("ctrl+shift+p").unwrap();
        assert!(
            e.modifiers.contains(KeyModifiers::CONTROL)
                && e.modifiers.contains(KeyModifiers::SHIFT)
        );
        assert_eq!(parse_key_spec("a").unwrap().code, KeyCode::Char('a'));
        assert!(parse_key_spec("nope-not-a-key").is_none());
    }
}
