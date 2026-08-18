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
        comment: rgb(0x80848d),
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

/// code-reviewer S2-3 — AI chip glyph + fallback + color in one
/// place. The same `match kind { "codex" => ("\u{F8B1}", "C", t.cyan),
/// _ => ("\u{F8B0}", "*", t.orange) }` was copy-pasted in bufferline.rs
/// (single-leaf strip) and ui/mod.rs (per-leaf strip painter).
pub fn ai_chip_parts(kind: &str, t: &Theme) -> (&'static str, &'static str, ratatui::style::Color) {
    // Default chip glyphs use the JBM-NF-patched pair (F8B0/F8B1)
    // so the chip renders out-of-the-box. Users who've baked the
    // mnml-owned copies into MnmlSymbols.ttf (via the AI-chip
    // right-click "Bake AI glyphs" item) can flip to F1E00/F1E01
    // — which HAS a tunable `center_frac` — via
    // `[ui] ai_chip_use_mnml_glyphs = true`. This dispatcher
    // reads that flag from the current-theme fallback path so
    // callers don't need to plumb config through.
    // 2026-08-08 — swap `t.orange` for the exact Anthropic Claude
    // brand coral so the split-cluster AI chip matches the tab-glyph
    // color used by `pty_icon` (which also hardcodes this RGB when
    // the pane's integration_id is claude_code).
    match kind {
        "codex" => ("\u{F8B1}", "C", t.cyan),
        _ => (
            "\u{F8B0}",
            "*",
            brand_color_for_builtin("claude_code").unwrap_or(t.orange),
        ),
    }
}

/// 2026-08-08 — single source of truth for the brand color of every
/// first-party built-in integration. Any renderer that draws a chip,
/// row, or tab for a built-in id (`claude_code`, `codex`, `browser`,
/// `http`) MUST consult this first and only fall back to the manifest's
/// `color` field for third-party integrations. Prevents the "split-
/// cluster chip is coral but the installed-list row is blue" class of
/// drift the user reported: the two call sites used to hardcode the
/// color in one place and read the manifest in the other, so a stale
/// manifest / bad hex parse could make them disagree.
///
/// None → not a built-in; caller must fall back to `color_from_slot`
/// on the manifest's color field.
pub fn brand_color_for_builtin(id: &str) -> Option<ratatui::style::Color> {
    use ratatui::style::Color;
    match id {
        // Anthropic Claude brand orange (RGB 209,109,81).
        "claude_code" => Some(Color::Rgb(0xD1, 0x6D, 0x51)),
        // Codex uses the cyan of the current theme — mnml has no
        // published brand for it and matching the theme keeps it
        // readable across themes.
        "codex" => Some(cur().cyan),
        // Browser + http don't have brand colors — first-party but
        // theme-driven. Return None so caller falls through to the
        // manifest color (which those manifests set to "blue").
        _ => None,
    }
}

/// Config-aware variant — called by the callers that have access
/// to `&App.config`. Returns the mnml-owned F1E00/F1E01 pair when
/// the user has flipped `[ui] ai_chip_use_mnml_glyphs = true`,
/// otherwise falls back to the JBM-NF-patched default.
pub fn ai_chip_parts_for(
    kind: &str,
    t: &Theme,
    use_mnml: bool,
) -> (&'static str, &'static str, ratatui::style::Color) {
    if use_mnml {
        match kind {
            "codex" => ("\u{F1E01}", "C", t.cyan),
            _ => (
                "\u{F1E00}",
                "*",
                brand_color_for_builtin("claude_code").unwrap_or(t.orange),
            ),
        }
    } else {
        ai_chip_parts(kind, t)
    }
}

/// code-reviewer S2-2 — resolve a config color-slot name to a
/// theme color. The same `match name { "orange" => t.orange, ... }`
/// pattern was duplicated in 7+ files (paint_integration_chips_in_gap,
/// integration-detail panel, compact + expanded rail chip rows,
/// the dead `bufferline::launcher_color`, integration_edit_overlay,
/// sessions_panel, completion). Single source of truth here.
pub fn color_from_slot(name: &str, t: &Theme) -> ratatui::style::Color {
    match name {
        "orange" => t.orange,
        "cyan" => t.cyan,
        "blue" => t.blue,
        "green" => t.green,
        "yellow" => t.yellow,
        "purple" => t.purple,
        "red" => t.red,
        "teal" => t.teal,
        // 2026-08-06 — magenta + pink now distinct from purple so
        // AWS integration icons (codebuild/eventbridge/cloudwatch,
        // all originally the same "purple family") render as three
        // visibly different tints matching AWS's brand hexes.
        // magenta = bright fuchsia (Color::Magenta), pink = a
        // deliberately hotter/redder shade for AWS analytics
        // family (#E7157B territory).
        "magenta" => ratatui::style::Color::Magenta,
        "pink" => ratatui::style::Color::Rgb(0xE7, 0x15, 0x7B),
        "fg" => t.fg,
        "comment" => t.comment,
        "bg" => t.bg,
        "bg2" => t.bg2,
        "white" => ratatui::style::Color::White,
        "black" => ratatui::style::Color::Black,
        // 2026-08-08 — accept `#RRGGBB` literals so a chip can carry an
        // exact brand color without needing a new theme slot. Used by
        // claude_code's `#D97757` (Anthropic Claude brand orange), which
        // wasn't hitting the exact hue via the shared `orange` slot.
        // Silent fallback to bg2 on parse failure (same shape as
        // unknown-slot handling above).
        // Reviewer 2026-08-08 — `hex.len()` counts BYTES, but the
        // `[1..3]`/`[3..5]`/`[5..7]` slices assume single-byte ASCII.
        // A crafted 7-byte string with a multi-byte UTF-8 char straddling
        // a cut point (e.g. `"#12中4"`) would panic on `is_char_boundary`
        // — user-editable via the sibling TOML, called every frame from
        // the render thread. Use `get(..)` (returns None on non-boundary)
        // + `is_ascii_hexdigit` gate for defence-in-depth.
        hex if hex.starts_with('#') && hex.len() == 7 => {
            let parse = |s: Option<&str>| {
                s.filter(|s| s.chars().all(|c| c.is_ascii_hexdigit()))
                    .and_then(|s| u8::from_str_radix(s, 16).ok())
            };
            match (
                parse(hex.get(1..3)),
                parse(hex.get(3..5)),
                parse(hex.get(5..7)),
            ) {
                (Some(r), Some(g), Some(b)) => ratatui::style::Color::Rgb(r, g, b),
                _ => t.bg2,
            }
        }
        _ => t.bg2,
    }
}

/// Switch the active theme by name. Returns the theme on success, `None` if the
/// name is unknown (the active theme is left unchanged).
pub fn set(name: &str) -> Option<Theme> {
    let t = lookup(name)?;
    *active().write().expect("theme lock poisoned") = t;
    Some(t)
}

/// One-shot detect: does the OS report a dark appearance preference?
/// macOS via `defaults read -g AppleInterfaceStyle` (returns "Dark"
/// when dark; exits non-zero when light — no key exists for light).
/// Linux via `gsettings get org.gnome.desktop.interface color-scheme`
/// which returns `'prefer-dark'` or `'prefer-light'`. Windows via
/// the `HKCU\...\AppsUseLightTheme` reg key (0 = dark).
///
/// Fail-open to `false` (light) on any parse/exec error — safer to
/// stay on the config default than to guess wrong. Task #1007.
pub fn detect_system_dark() -> bool {
    use std::process::Command;

    #[cfg(target_os = "macos")]
    {
        Command::new("defaults")
            .args(["read", "-g", "AppleInterfaceStyle"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .eq_ignore_ascii_case("Dark")
            })
            .unwrap_or(false)
    }

    #[cfg(target_os = "linux")]
    {
        // Try GNOME (gsettings) first, then KDE (kreadconfig6 →
        // kreadconfig5 fallback for older Plasma). Both are best-
        // effort; other DEs (Sway, Hyprland, xfce4) fall through
        // to light. Reviewer flag 2026-08-18: bare GNOME check
        // was misleading on KDE.
        let gnome = Command::new("gsettings")
            .args(["get", "org.gnome.desktop.interface", "color-scheme"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .to_ascii_lowercase()
                    .contains("dark")
            });
        if let Some(dark) = gnome {
            return dark;
        }
        for bin in ["kreadconfig6", "kreadconfig5"] {
            let kde = Command::new(bin)
                .args(["--group", "General", "--key", "ColorScheme"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .to_ascii_lowercase()
                        .contains("dark")
                });
            if let Some(dark) = kde {
                return dark;
            }
        }
        false
    }

    #[cfg(target_os = "windows")]
    {
        // AppsUseLightTheme = 0x0 → dark, 0x1 → light.
        Command::new("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "/v",
                "AppsUseLightTheme",
            ])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("0x0"))
            .unwrap_or(false)
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        false
    }
}

/// Path to the canonical "current theme" file — `~/.config/mnml/current-theme.toml`
/// (respecting `$XDG_CONFIG_HOME`). This is the family's single source of truth:
/// [`write_current`] keeps it in sync with mnml's active theme, and every sibling
/// (mixr, the `mnml-*` integrations) reads it to follow mnml's colours.
pub fn current_theme_path() -> Option<std::path::PathBuf> {
    if crate::data_root::data_root_kind() == crate::data_root::DataRootKind::Portable {
        return Some(crate::data_root::data_root().join("current-theme.toml"));
    }
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return Some(
            std::path::PathBuf::from(xdg)
                .join("mnml")
                .join("current-theme.toml"),
        );
    }
    std::env::var_os("HOME").map(|h| {
        std::path::PathBuf::from(h)
            .join(".config")
            .join("mnml")
            .join("current-theme.toml")
    })
}

/// `#rrggbb` for a theme colour. Theme colours are always `Color::Rgb`; any other
/// variant (shouldn't occur) renders as black so the file stays valid.
fn hex(c: Color) -> String {
    match c {
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        _ => "#000000".to_string(),
    }
}

/// Serialise `t` to the `[base_30]` + `[base_16]` TOML shape mnml itself parses
/// ([`parse_theme`]). The key names match the NvChad base_30 schema so any
/// consumer — mnml's own parser, a sibling's `theme.rs` — reads the colours
/// it expects. `comment` (the dim role) is emitted under both `light_grey`
/// and `grey_fg2` so loaders keying off either find it.
pub fn to_toml(t: &Theme) -> String {
    let mut s = String::with_capacity(1024);
    s.push_str(
        "# Written by mnml — the resolved active theme. Family apps (mixr,\n\
         # mnml-* siblings) read this to follow mnml's colours. Regenerated on\n\
         # launch and on every theme switch; do not hand-edit.\n",
    );
    s.push_str(&format!("name = \"{}\"\n\n[base_30]\n", t.name));
    let row = |s: &mut String, k: &str, c: Color| s.push_str(&format!("{k} = \"{}\"\n", hex(c)));
    row(&mut s, "white", t.fg);
    row(&mut s, "black", t.bg_dark);
    row(&mut s, "darker_black", t.bg_darker);
    row(&mut s, "black2", t.statusline);
    row(&mut s, "one_bg", t.bg);
    row(&mut s, "one_bg2", t.bg2);
    row(&mut s, "one_bg3", t.bg3);
    row(&mut s, "statusline_bg", t.statusline);
    row(&mut s, "line", t.line);
    row(&mut s, "lightbg", t.lightbg);
    row(&mut s, "light_grey", t.comment);
    row(&mut s, "grey_fg2", t.comment);
    row(&mut s, "grey", t.grey);
    row(&mut s, "grey_fg", t.grey_fg);
    row(&mut s, "red", t.red);
    row(&mut s, "pink", t.pink);
    row(&mut s, "green", t.green);
    row(&mut s, "vibrant_green", t.vibrant_green);
    row(&mut s, "yellow", t.yellow);
    row(&mut s, "sun", t.sun);
    row(&mut s, "orange", t.orange);
    row(&mut s, "blue", t.blue);
    row(&mut s, "nord_blue", t.nord_blue);
    row(&mut s, "teal", t.teal);
    row(&mut s, "cyan", t.cyan);
    row(&mut s, "purple", t.purple);
    row(&mut s, "dark_purple", t.dark_purple);
    s.push_str("\n[base_16]\n");
    for (i, c) in t.base16.iter().enumerate() {
        s.push_str(&format!("base{i:02X} = \"{}\"\n", hex(*c)));
    }
    s
}

/// Write `t` to [`current_theme_path`] so the family can follow mnml's colours.
/// Best-effort: creates `~/.config/mnml/` if needed and swallows I/O errors (an
/// unwritable config dir must not crash the editor). Call at startup and after
/// every theme switch.
pub fn write_current(t: &Theme) {
    let Some(path) = current_theme_path() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = crate::app::backup::write_toml_with_backup(&path, &to_toml(t), "theme");
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
    fn to_toml_round_trips_through_the_parser() {
        // The canonical file mnml writes must read back identically through
        // its own parser — that's the contract every sibling relies on.
        let src = onedark();
        let toml = to_toml(&src);
        let back = parse_theme("onedark", &toml).expect("written theme re-parses");
        assert_eq!(back.fg, src.fg);
        assert_eq!(back.bg, src.bg);
        assert_eq!(back.bg_dark, src.bg_dark);
        assert_eq!(back.bg_darker, src.bg_darker);
        // The dim role survives — emitted as light_grey, read back as comment.
        assert_eq!(back.comment, src.comment);
        assert_eq!(back.blue, src.blue);
        assert_eq!(back.red, src.red);
        assert_eq!(back.base16, src.base16);
    }

    // Reviewer 2026-08-08 — repro that used to panic:
    // multi-byte UTF-8 chars in a 7-byte "#hex" string straddled a
    // slice cut point (`hex[1..3]`) and killed the render thread.
    // Regression guard: parser must fall back silently, not panic.
    #[test]
    fn color_from_slot_multibyte_hex_falls_back_without_panic() {
        let t = *active().read().unwrap();
        // "#12中4" — 3 ASCII + 3-byte U+4E2D + 1 ASCII = 7 bytes,
        // but `[1..3]` cuts through the middle of the CJK char.
        let c = color_from_slot("#12\u{4E2D}4", &t);
        assert_eq!(c, t.bg2, "non-ASCII hex must fall back to bg2");
        // Reviewer 2026-08-08: cover a straddle at the `[3..5]` cut.
        // "#123é7" — 4 ASCII + 2-byte é (U+00E9) + 1 ASCII = 7 bytes;
        // slicing at byte 4 would split `é` mid-codepoint.
        let c2 = color_from_slot("#123\u{00E9}7", &t);
        assert_eq!(c2, t.bg2);
        // Trailing non-ASCII. "#1234é" — 5 ASCII + 2-byte é = 7 bytes.
        // Both `[5..7]` boundaries are valid here (é starts at 5,
        // ends at 7), so `get()` returns Some("é") whole; the
        // fallback path here is the `is_ascii_hexdigit` filter, not
        // the char-boundary guard. Still a useful regression case —
        // a rewrite that dropped the hexdigit filter would accept `é`
        // as garbage or panic in `from_str_radix`.
        let c3 = color_from_slot("#1234\u{00E9}", &t);
        assert_eq!(c3, t.bg2);
        // Sanity: valid hex still parses correctly.
        let c4 = color_from_slot("#D16D51", &t);
        assert_eq!(
            c4,
            ratatui::style::Color::Rgb(0xD1, 0x6D, 0x51),
            "valid hex must still parse"
        );
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
