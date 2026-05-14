//! Key-spec parsing + the config-driven keymap resolver.
//!
//! `parse_key_spec` turns strings like `"ctrl+shift+p"`, `"enter"`, `"down"`,
//! `"a"` into `crossterm::event::KeyEvent`s (used by the IPC channel so e2e
//! scripts can send keys by name).
//!
//! [`Keymap`] is the *one table* app-level chords resolve through: built from
//! every [`crate::command::Command`]'s default `keys` and then overlaid with the
//! user's `[keys.global]` / `[keys.<input_style>]` config. `tui.rs`/`headless.rs`
//! call `App::keymap.resolve(key)` instead of a hardcoded `match`. Adding or
//! re-binding a chord = one row here or in config, nowhere else.

use std::collections::HashMap;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;

/// A normalized (code, modifiers) pair — the hashable lookup key. Normalization:
/// an uppercase `Char` is lowered and `SHIFT` made explicit, so `"P"` and
/// `"shift+p"` (and however a given terminal reports them) all collapse to the
/// same chord. The `kind`/`state` of a `KeyEvent` are dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Chord {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

impl Chord {
    pub fn of(ev: &KeyEvent) -> Chord {
        let mut mods = ev.modifiers;
        let code = match ev.code {
            KeyCode::Char(c) if c.is_ascii_uppercase() => {
                mods |= KeyModifiers::SHIFT;
                KeyCode::Char(c.to_ascii_lowercase())
            }
            other => other,
        };
        // Crossterm sometimes leaves SHIFT set on a `Char` even when the char is
        // already the shifted form on legacy terminals; the lowercasing above keeps
        // it consistent. We *don't* strip SHIFT otherwise (Ctrl+Shift+P needs it).
        Chord { code, mods }
    }
}

/// The resolved binding table. `resolve` is the hot path (one hashmap lookup per
/// unconsumed key event).
#[derive(Debug, Clone, Default)]
pub struct Keymap {
    map: HashMap<Chord, String>,
}

impl Keymap {
    /// Defaults from the command registry, then `[keys.global]`, then
    /// `[keys.<input_style>]` (so a mode can override a shared chord). A config
    /// value of `""` / `"none"` / `"unbound"` removes whatever was bound there.
    pub fn build(cfg: &Config) -> Keymap {
        let mut km = Keymap::default();
        for cmd in crate::command::registry().all() {
            for spec in cmd.keys {
                if let Some(ev) = parse_key_spec(spec) {
                    km.map.insert(Chord::of(&ev), cmd.id.to_string());
                }
            }
        }
        // Vim mode reserves a couple of chords the global keymap would
        // otherwise swallow before the buffer's input handler ever sees
        // them: `Ctrl+W` (window/split prefix) and `Ctrl+G` (file info).
        // Standard mode keeps them as `buffer.close` / `editor.goto_line`.
        // We remove them here, BEFORE applying user `[keys.*]` overlays so
        // the user can still bind them in `[keys.vim]` if desired.
        if cfg.editor.input_style == "vim" {
            for spec in ["ctrl+w", "ctrl+g"] {
                if let Some(ev) = parse_key_spec(spec) {
                    km.map.remove(&Chord::of(&ev));
                }
            }
        }
        for section in ["global", cfg.editor.input_style.as_str()] {
            if let Some(table) = cfg.keys.get(section) {
                for (key, id) in table {
                    let Some(ev) = parse_key_spec(key) else {
                        eprintln!("mnml: [keys.{section}] bad key spec {key:?} — ignored");
                        continue;
                    };
                    let chord = Chord::of(&ev);
                    let id = id.trim();
                    if id.is_empty() || id == "none" || id == "unbound" {
                        km.map.remove(&chord);
                    } else {
                        km.map.insert(chord, id.to_string());
                    }
                }
            }
        }
        km
    }

    /// The command id bound to this key event, if any.
    pub fn resolve(&self, ev: &KeyEvent) -> Option<&str> {
        self.map.get(&Chord::of(ev)).map(String::as_str)
    }

    /// Bind one keyspec → command id (used for plugin-registered commands). A
    /// keyspec that doesn't parse is ignored. Overwrites any existing binding.
    pub fn bind(&mut self, spec: &str, id: &str) {
        if let Some(ev) = parse_key_spec(spec) {
            self.map.insert(Chord::of(&ev), id.to_string());
        }
    }
}

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

    #[test]
    fn chord_normalizes_uppercase_char() {
        // `"P"` typed and `"shift+p"` typed must collapse to the same chord.
        let a = Chord::of(&KeyEvent::new(KeyCode::Char('P'), KeyModifiers::NONE));
        let b = Chord::of(&KeyEvent::new(KeyCode::Char('p'), KeyModifiers::SHIFT));
        assert_eq!(a, b);
        assert_eq!(a.code, KeyCode::Char('p'));
        assert!(a.mods.contains(KeyModifiers::SHIFT));
    }

    #[test]
    fn default_keymap_has_builtin_chords() {
        let km = Keymap::build(&Config::default());
        let ev = |s: &str| parse_key_spec(s).unwrap();
        assert_eq!(km.resolve(&ev("ctrl+q")), Some("app.quit"));
        assert_eq!(km.resolve(&ev("ctrl+p")), Some("picker.files"));
        assert_eq!(km.resolve(&ev("f1")), Some("palette"));
        assert_eq!(km.resolve(&ev("ctrl+shift+p")), Some("palette"));
        assert_eq!(km.resolve(&ev("ctrl+b")), Some("view.toggle_tree"));
        assert_eq!(km.resolve(&ev("ctrl+z")), None);
    }

    #[test]
    fn config_overlays_and_unbinds() {
        let mut cfg = Config::default();
        let mut global = std::collections::BTreeMap::new();
        global.insert("ctrl+;".to_string(), "palette".to_string()); // add
        global.insert("ctrl+p".to_string(), "none".to_string()); // unbind
        global.insert("ctrl+b".to_string(), "tree.refresh".to_string()); // rebind
        cfg.keys.insert("global".to_string(), global);
        let km = Keymap::build(&cfg);
        let ev = |s: &str| parse_key_spec(s).unwrap();
        assert_eq!(km.resolve(&ev("ctrl+;")), Some("palette"));
        assert_eq!(km.resolve(&ev("ctrl+p")), None);
        assert_eq!(km.resolve(&ev("ctrl+b")), Some("tree.refresh"));
        // a default that wasn't touched still resolves
        assert_eq!(km.resolve(&ev("f1")), Some("palette"));
    }

    #[test]
    fn input_style_section_overrides_global() {
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        cfg.keys.insert(
            "global".to_string(),
            std::collections::BTreeMap::from([("ctrl+g".to_string(), "app.quit".to_string())]),
        );
        cfg.keys.insert(
            "vim".to_string(),
            std::collections::BTreeMap::from([("ctrl+g".to_string(), "tree.refresh".to_string())]),
        );
        let km = Keymap::build(&cfg);
        assert_eq!(
            km.resolve(&parse_key_spec("ctrl+g").unwrap()),
            Some("tree.refresh")
        );
    }
}
