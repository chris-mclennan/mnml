//! The theme engine. A [`Theme`] is two palettes — `base16` (tree-sitter /
//! syntax groups, indices `0x00..=0x0f`) plus a set of named UI-chrome colors
//! (NvChad's `base_30`). The active theme lives behind an `RwLock`; `cur()`
//! reads it (cheap — it's `Copy`), `set(name)` swaps it. `[ui] theme = "…"`
//! picks one at launch; the `theme.pick` command / `:set theme=…` switch at
//! runtime (and re-run syntax highlighting so cached colors refresh).
//!
//! Themes come from `themes/*.toml` — `[base_30]` (UI chrome) + `[base_16]`
//! (syntax) colour tables (the NvChad base46 schema, converted from upstream),
//! parsed at first use (`build.rs` enumerates the dir → `THEME_SOURCES`).
//! `onedark` is the default and is also kept hardcoded here as the seed / a
//! fallback if the bundled file is unavailable. Drop a `.toml` in `themes/` in
//! the same shape to add one.

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

// ── the bundled themes ────────────────────────────────────────────────
// `build.rs` emits `THEME_SOURCES: &[(&str, &str)]` — (name, file contents) for
// every `themes/*.toml`. Each is `[base_30]` / `[base_16]` colour tables (the
// NvChad base46 schema, converted from upstream); we parse them at first use.
include!(concat!(env!("OUT_DIR"), "/theme_sources.rs"));

fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let s = s.trim().strip_prefix('#')?;
    let h = |x: &str| u8::from_str_radix(x, 16).ok();
    match s.len() {
        6 => Some([h(&s[0..2])?, h(&s[2..4])?, h(&s[4..6])?]),
        3 => {
            let d = |i: usize| h(&s[i..i + 1]).map(|v| v * 17);
            Some([d(0)?, d(1)?, d(2)?])
        }
        _ => None,
    }
}

/// The on-disk theme format: `[base_30]` (UI chrome, NvChad's named colours) and
/// `[base_16]` (`base00`..`base0F`, the syntax palette). `name`/`type` optional.
#[derive(serde::Deserialize)]
struct RawTheme {
    #[serde(default)]
    base_30: std::collections::HashMap<String, String>,
    #[serde(default)]
    base_16: std::collections::HashMap<String, String>,
}

/// Parse one theme file into a [`Theme`]. `None` if it doesn't parse or has no
/// `[base_30]`; missing individual colours fall back sensibly (a missing
/// `[base_16]` slot falls back to onedark's value for that slot).
fn parse_theme(name: &'static str, src: &str) -> Option<Theme> {
    let raw: RawTheme = toml::from_str(src).ok()?;
    if raw.base_30.is_empty() {
        return None;
    }
    let col = |k: &str| raw.base_30.get(k).and_then(|s| parse_hex(s));
    let rgb_of = |[r, g, b]: [u8; 3]| Color::Rgb(r, g, b);
    let pick = |keys: &[&str], default: Color| {
        keys.iter()
            .find_map(|k| col(k))
            .map(rgb_of)
            .unwrap_or(default)
    };
    let od = onedark();
    let white = pick(&["white"], od.fg);
    let black = pick(&["black"], od.bg_dark);
    let mut base16 = od.base16;
    for (i, slot) in base16.iter_mut().enumerate() {
        if let Some(rgb) = raw
            .base_16
            .get(&format!("base{i:02X}"))
            .or_else(|| raw.base_16.get(&format!("base{i:02x}")))
            .and_then(|s| parse_hex(s))
        {
            *slot = rgb_of(rgb);
        }
    }
    Some(Theme {
        name,
        bg: pick(&["one_bg", "black"], black),
        bg2: pick(&["one_bg2", "one_bg"], black),
        bg3: pick(&["one_bg3", "one_bg2"], black),
        bg_dark: black,
        bg_darker: pick(&["darker_black"], black),
        statusline: pick(&["statusline_bg", "black2"], black),
        line: pick(&["line", "one_bg3"], black),
        lightbg: pick(&["lightbg", "one_bg"], black),
        fg: white,
        comment: pick(&["light_grey", "grey_fg2", "grey_fg", "grey"], white),
        grey: pick(&["grey", "grey_fg"], white),
        grey_fg: pick(&["grey_fg", "grey"], white),
        red: pick(&["red"], white),
        pink: pick(&["pink", "baby_pink"], white),
        green: pick(&["green"], white),
        vibrant_green: pick(&["vibrant_green", "green"], white),
        yellow: pick(&["yellow"], white),
        sun: pick(&["sun", "yellow"], white),
        orange: pick(&["orange"], white),
        blue: pick(&["blue"], white),
        nord_blue: pick(&["nord_blue", "blue"], white),
        teal: pick(&["teal"], white),
        cyan: pick(&["cyan", "blue"], white),
        purple: pick(&["purple"], white),
        dark_purple: pick(&["dark_purple", "purple"], white),
        base16,
    })
}

/// All themes (parsed once). `onedark` is guaranteed present (the hardcoded copy
/// is the fallback if the bundled file is missing or unparseable).
fn themes() -> &'static [Theme] {
    static THEMES: OnceLock<Vec<Theme>> = OnceLock::new();
    THEMES.get_or_init(|| {
        let mut v: Vec<Theme> = THEME_SOURCES
            .iter()
            .filter_map(|&(name, src)| parse_theme(name, src))
            .collect();
        if !v.iter().any(|t| t.name == "onedark") {
            v.insert(0, onedark());
        }
        v
    })
}

/// Look a theme up by name (case-insensitive). `None` if unknown.
pub fn lookup(name: &str) -> Option<Theme> {
    let name = name.trim();
    themes()
        .iter()
        .find(|t| t.name.eq_ignore_ascii_case(name))
        .copied()
}

/// All theme names, for the picker (sorted).
pub fn names() -> Vec<&'static str> {
    themes().iter().map(|t| t.name).collect()
}

fn active() -> &'static RwLock<Theme> {
    static ACTIVE: OnceLock<RwLock<Theme>> = OnceLock::new();
    ACTIVE.get_or_init(|| RwLock::new(lookup("onedark").unwrap_or_else(onedark)))
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
    fn bundled_themes_load() {
        // build.rs bundles all of NvChad's base46 schemes (~90+).
        let all = names();
        assert!(
            all.len() > 50,
            "expected the bundled themes, got {}",
            all.len()
        );
        assert!(all.contains(&"onedark"));
        assert!(all.contains(&"gruvbox"));
        assert!(all.contains(&"catppuccin"));
        assert!(lookup("ONEDARK").is_some()); // case-insensitive
        assert!(lookup("nope").is_none());
        assert_eq!(onedark().base16.len(), 16);
    }

    #[test]
    fn parse_theme_extracts_colours() {
        let src = r##"
            name = "demo"
            type = "dark"
            [base_30]
            white = "#abcdef"
            black = "#111213"
            one_bg = "#222324"
            blue = "#3456ef"
            [base_16]
            base00 = "#010203"
            base0E = "#c678dd"
        "##;
        let t = parse_theme("demo", src).unwrap();
        assert_eq!(t.fg, Color::Rgb(0xab, 0xcd, 0xef));
        assert_eq!(t.bg_dark, Color::Rgb(0x11, 0x12, 0x13));
        assert_eq!(t.bg, Color::Rgb(0x22, 0x23, 0x24));
        assert_eq!(t.blue, Color::Rgb(0x34, 0x56, 0xef));
        assert_eq!(t.base16[0x00], Color::Rgb(0x01, 0x02, 0x03));
        assert_eq!(t.base16[0x0e], Color::Rgb(0xc6, 0x78, 0xdd));
        // a missing colour falls back (no `red` → onedark's fg, here `#abcdef`)
        assert_eq!(t.red, Color::Rgb(0xab, 0xcd, 0xef));
        // no [base_30] → not a usable theme
        assert!(parse_theme("x", "name = \"x\"").is_none());
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
