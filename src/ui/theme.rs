//! The theme engine. A [`Theme`] is two palettes — `base16` (tree-sitter /
//! syntax groups, indices `0x00..=0x0f`) plus a set of named UI-chrome colors
//! (NvChad's `base_30`). The active theme lives behind an `RwLock`; `cur()`
//! reads it (cheap — it's `Copy`), `set(name)` swaps it. `[ui] theme = "…"`
//! picks one at launch; the `theme.pick` command switches at runtime (and
//! re-runs syntax highlighting so cached colors refresh).
//!
//! Built-in themes: `onedark` (the default — transcribed verbatim from
//! `NvChad/base46`), `gruvbox`, `catppuccin`. More are just another entry in
//! [`THEMES`].

use std::sync::{OnceLock, RwLock};

use ratatui::style::Color;

/// A complete colour scheme. `Copy`, so `cur()` hands one back by value.
#[derive(Debug, Clone, Copy)]
pub struct Theme {
    pub name: &'static str,
    // ── UI chrome (NvChad base_30 subset) ──
    pub bg: Color,         // one_bg — secondary panel bg
    pub bg2: Color,        // one_bg2 — selected row / hover
    pub bg3: Color,        // one_bg3
    pub bg_dark: Color,    // black — the editor body
    pub bg_darker: Color,  // darker_black — tree rail, bufferline, overlays
    pub statusline: Color, // statusline_bg
    pub line: Color,       // current-line bg + vertical separators
    pub lightbg: Color,    // light_bg — file-tab body
    pub fg: Color,         // white — primary text
    pub comment: Color,    // light_grey / grey_fg2
    pub grey: Color,
    pub grey_fg: Color,
    pub red: Color,
    pub pink: Color,
    pub green: Color,
    pub vibrant_green: Color,
    pub yellow: Color,
    pub sun: Color,
    pub orange: Color,
    pub blue: Color,
    pub nord_blue: Color,
    pub teal: Color,
    pub cyan: Color,
    pub purple: Color,
    pub dark_purple: Color,
    // ── base_16 (syntax) — indices 0x00..=0x0f ──
    pub base16: [Color; 16],
}

const fn rgb(hex: u32) -> Color {
    Color::Rgb(
        ((hex >> 16) & 0xff) as u8,
        ((hex >> 8) & 0xff) as u8,
        (hex & 0xff) as u8,
    )
}

/// NvChad **onedark** — the default; values verbatim from `base46/themes/onedark.lua`.
pub const fn onedark() -> Theme {
    Theme {
        name: "onedark",
        bg: rgb(0x282c34),
        bg2: rgb(0x353b45),
        bg3: rgb(0x373b43),
        bg_dark: rgb(0x1e222a),
        bg_darker: rgb(0x1b1f27),
        statusline: rgb(0x22262e),
        line: rgb(0x31353d),
        lightbg: rgb(0x2d3139),
        fg: rgb(0xabb2bf),
        comment: rgb(0x6f737b),
        grey: rgb(0x42464e),
        grey_fg: rgb(0x565c64),
        red: rgb(0xe06c75),
        pink: rgb(0xff75a0),
        green: rgb(0x98c379),
        vibrant_green: rgb(0x7eca9c),
        yellow: rgb(0xe7c787),
        sun: rgb(0xebcb8b),
        orange: rgb(0xfca2aa),
        blue: rgb(0x61afef),
        nord_blue: rgb(0x81a1c1),
        teal: rgb(0x519aba),
        cyan: rgb(0xa3b8ef),
        purple: rgb(0xde98fd),
        dark_purple: rgb(0xc882e7),
        base16: [
            rgb(0x1e222a), // 00 editor bg
            rgb(0x353b45), // 01 currentline / selection bg
            rgb(0x3e4451), // 02 selection
            rgb(0x545862), // 03 comments / line numbers
            rgb(0x565c64), // 04 dark fg
            rgb(0xabb2bf), // 05 default fg
            rgb(0xb6bdca), // 06 light fg
            rgb(0xc8ccd4), // 07 lightest fg
            rgb(0xe06c75), // 08 variables / identifiers
            rgb(0xd19a66), // 09 numbers / constants / booleans
            rgb(0xe5c07b), // 0A types / classes / attributes
            rgb(0x98c379), // 0B strings
            rgb(0x56b6c2), // 0C constructors / regex escapes
            rgb(0x61afef), // 0D function names
            rgb(0xc678dd), // 0E keywords
            rgb(0xbe5046), // 0F delimiters / brackets / deprecated
        ],
    }
}

/// **gruvbox** (dark) — approximated from the gruvbox-dark-hard palette.
pub const fn gruvbox() -> Theme {
    Theme {
        name: "gruvbox",
        bg: rgb(0x32302f),
        bg2: rgb(0x3c3836),
        bg3: rgb(0x504945),
        bg_dark: rgb(0x282828),
        bg_darker: rgb(0x1d2021),
        statusline: rgb(0x32302f),
        line: rgb(0x3c3836),
        lightbg: rgb(0x32302f),
        fg: rgb(0xebdbb2),
        comment: rgb(0x928374),
        grey: rgb(0x504945),
        grey_fg: rgb(0x665c54),
        red: rgb(0xfb4934),
        pink: rgb(0xd3869b),
        green: rgb(0xb8bb26),
        vibrant_green: rgb(0x98971a),
        yellow: rgb(0xfabd2f),
        sun: rgb(0xd79921),
        orange: rgb(0xfe8019),
        blue: rgb(0x83a598),
        nord_blue: rgb(0x83a598),
        teal: rgb(0x689d6a),
        cyan: rgb(0x8ec07c),
        purple: rgb(0xd3869b),
        dark_purple: rgb(0xb16286),
        base16: [
            rgb(0x282828), // 00
            rgb(0x3c3836), // 01
            rgb(0x504945), // 02
            rgb(0x665c54), // 03 comments
            rgb(0x7c6f64), // 04
            rgb(0xebdbb2), // 05 fg
            rgb(0xd5c4a1), // 06
            rgb(0xfbf1c7), // 07
            rgb(0xfb4934), // 08 variables
            rgb(0xd65d0e), // 09 numbers
            rgb(0xfabd2f), // 0A types
            rgb(0xb8bb26), // 0B strings
            rgb(0x8ec07c), // 0C
            rgb(0x83a598), // 0D functions
            rgb(0xd3869b), // 0E keywords
            rgb(0xd65d0e), // 0F delimiters
        ],
    }
}

/// **catppuccin** (mocha) — approximated from the Catppuccin Mocha palette.
pub const fn catppuccin() -> Theme {
    Theme {
        name: "catppuccin",
        bg: rgb(0x292c3c),
        bg2: rgb(0x313244),
        bg3: rgb(0x45475a),
        bg_dark: rgb(0x1e1e2e),
        bg_darker: rgb(0x181825),
        statusline: rgb(0x232337),
        line: rgb(0x313244),
        lightbg: rgb(0x292c3c),
        fg: rgb(0xcdd6f4),
        comment: rgb(0x7f849c),
        grey: rgb(0x45475a),
        grey_fg: rgb(0x6c7086),
        red: rgb(0xf38ba8),
        pink: rgb(0xf5c2e7),
        green: rgb(0xa6e3a1),
        vibrant_green: rgb(0x94e2d5),
        yellow: rgb(0xf9e2af),
        sun: rgb(0xf9e2af),
        orange: rgb(0xfab387),
        blue: rgb(0x89b4fa),
        nord_blue: rgb(0x74c7ec),
        teal: rgb(0x94e2d5),
        cyan: rgb(0x89dceb),
        purple: rgb(0xcba6f7),
        dark_purple: rgb(0xb4befe),
        base16: [
            rgb(0x1e1e2e), // 00
            rgb(0x313244), // 01
            rgb(0x45475a), // 02
            rgb(0x585b70), // 03 comments
            rgb(0x6c7086), // 04
            rgb(0xcdd6f4), // 05 fg
            rgb(0xbac2de), // 06
            rgb(0xa6adc8), // 07
            rgb(0xf38ba8), // 08 variables
            rgb(0xfab387), // 09 numbers
            rgb(0xf9e2af), // 0A types
            rgb(0xa6e3a1), // 0B strings
            rgb(0x94e2d5), // 0C
            rgb(0x89b4fa), // 0D functions
            rgb(0xcba6f7), // 0E keywords
            rgb(0xf5c2e7), // 0F delimiters
        ],
    }
}

/// One registry entry: a name and a builder.
type ThemeEntry = (&'static str, fn() -> Theme);

/// The registry of built-in themes (`onedark` first = the default).
pub const THEMES: &[ThemeEntry] = &[
    ("onedark", onedark),
    ("gruvbox", gruvbox),
    ("catppuccin", catppuccin),
];

/// Look a theme up by name (case-insensitive). `None` if unknown.
pub fn lookup(name: &str) -> Option<Theme> {
    THEMES
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(name.trim()))
        .map(|(_, f)| f())
}

/// Built-in theme names, for the picker.
pub fn names() -> Vec<&'static str> {
    THEMES.iter().map(|(n, _)| *n).collect()
}

fn active() -> &'static RwLock<Theme> {
    static ACTIVE: OnceLock<RwLock<Theme>> = OnceLock::new();
    ACTIVE.get_or_init(|| RwLock::new(onedark()))
}

/// The current theme (a cheap `Copy`).
pub fn cur() -> Theme {
    *active().read().expect("theme lock poisoned")
}

/// Switch the active theme by name. Returns the theme on success, `None` if the
/// name is unknown (the active theme is left unchanged).
pub fn set(name: &str) -> Option<Theme> {
    let t = lookup(name)?;
    *active().write().expect("theme lock poisoned") = t;
    Some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_unpacks() {
        assert_eq!(rgb(0x1e222a), Color::Rgb(0x1e, 0x22, 0x2a));
    }

    #[test]
    fn registry_and_lookup() {
        assert_eq!(onedark().name, "onedark");
        assert!(lookup("ONEDARK").is_some());
        assert!(lookup("nope").is_none());
        assert!(names().contains(&"gruvbox"));
        assert_eq!(onedark().base16.len(), 16);
    }

    #[test]
    fn set_and_cur_roundtrip() {
        let restore = cur().name;
        assert!(set("gruvbox").is_some());
        assert_eq!(cur().name, "gruvbox");
        assert!(set("does-not-exist").is_none());
        assert_eq!(cur().name, "gruvbox"); // unchanged
        set(restore); // be polite to other tests sharing the process
    }
}
