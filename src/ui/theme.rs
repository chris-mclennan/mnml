//! NvChad onedark palette, transcribed verbatim from
//! `NvChad/base46/lua/base46/themes/onedark.lua`.
//!
//! Two palettes — base_30 (UI chrome) + base_16 (tree-sitter highlight groups).
//! All values are RGB triples; use `Color::Rgb(r, g, b)` in ratatui styles.
//! (Multiple themes are a "later" — for now this module *is* the theme.)

use ratatui::style::Color;

// ─── base_30 (UI chrome) ────────────────────────────────────────────
pub const BG: Color = Color::Rgb(0x28, 0x2c, 0x34); // one_bg
pub const BG2: Color = Color::Rgb(0x35, 0x3b, 0x45); // one_bg2 — selected row, hover
pub const BG3: Color = Color::Rgb(0x37, 0x3b, 0x43); // one_bg3
pub const BG_DARK: Color = Color::Rgb(0x1e, 0x22, 0x2a); // black
pub const BG_DARKER: Color = Color::Rgb(0x1b, 0x1f, 0x27); // darker_black
pub const STATUSLINE: Color = Color::Rgb(0x22, 0x26, 0x2e); // statusline_bg
pub const LINE: Color = Color::Rgb(0x31, 0x35, 0x3d); // vertical separator + cursor line
pub const LIGHTBG: Color = Color::Rgb(0x2d, 0x31, 0x39); // light_bg — file-tab body

pub const FG: Color = Color::Rgb(0xab, 0xb2, 0xbf); // white (primary text)
pub const COMMENT: Color = Color::Rgb(0x6f, 0x73, 0x7b); // light_grey / grey_fg2
pub const GREY: Color = Color::Rgb(0x42, 0x46, 0x4e);
pub const GREY_FG: Color = Color::Rgb(0x56, 0x5c, 0x64);

pub const RED: Color = Color::Rgb(0xe0, 0x6c, 0x75);
pub const PINK: Color = Color::Rgb(0xff, 0x75, 0xa0);
pub const GREEN: Color = Color::Rgb(0x98, 0xc3, 0x79);
pub const VIBRANT_GREEN: Color = Color::Rgb(0x7e, 0xca, 0x9c);
pub const YELLOW: Color = Color::Rgb(0xe7, 0xc7, 0x87);
pub const SUN: Color = Color::Rgb(0xeb, 0xcb, 0x8b);
pub const ORANGE: Color = Color::Rgb(0xfc, 0xa2, 0xaa);
pub const BLUE: Color = Color::Rgb(0x61, 0xaf, 0xef);
pub const NORD_BLUE: Color = Color::Rgb(0x81, 0xa1, 0xc1);
pub const TEAL: Color = Color::Rgb(0x51, 0x9a, 0xba);
pub const CYAN: Color = Color::Rgb(0xa3, 0xb8, 0xef);
pub const PURPLE: Color = Color::Rgb(0xde, 0x98, 0xfd);
pub const DARK_PURPLE: Color = Color::Rgb(0xc8, 0x82, 0xe7);

// ─── base_16 (tree-sitter / syntax highlight groups) ────────────────
// Same indices as base16-onedark — names mirror NvChad's `M.base_16` table.
pub const BASE16_00: Color = Color::Rgb(0x1e, 0x22, 0x2a); // editor bg
pub const BASE16_01: Color = Color::Rgb(0x35, 0x3b, 0x45); // currentline / selection bg
pub const BASE16_02: Color = Color::Rgb(0x3e, 0x44, 0x51); // selection
pub const BASE16_03: Color = Color::Rgb(0x54, 0x58, 0x62); // comments / line-numbers
pub const BASE16_04: Color = Color::Rgb(0x56, 0x5c, 0x64); // dark fg
pub const BASE16_05: Color = Color::Rgb(0xab, 0xb2, 0xbf); // default fg
pub const BASE16_06: Color = Color::Rgb(0xb6, 0xbd, 0xca); // light fg
pub const BASE16_07: Color = Color::Rgb(0xc8, 0xcc, 0xd4); // lightest fg
pub const BASE16_08: Color = Color::Rgb(0xe0, 0x6c, 0x75); // variables, identifiers
pub const BASE16_09: Color = Color::Rgb(0xd1, 0x9a, 0x66); // numbers, constants, booleans
pub const BASE16_0A: Color = Color::Rgb(0xe5, 0xc0, 0x7b); // types, classes, attributes
pub const BASE16_0B: Color = Color::Rgb(0x98, 0xc3, 0x79); // strings
pub const BASE16_0C: Color = Color::Rgb(0x56, 0xb6, 0xc2); // constructors, regex escapes
pub const BASE16_0D: Color = Color::Rgb(0x61, 0xaf, 0xef); // function names
pub const BASE16_0E: Color = Color::Rgb(0xc6, 0x78, 0xdd); // keywords (purple)
pub const BASE16_0F: Color = Color::Rgb(0xbe, 0x50, 0x46); // delimiters, brackets, deprecated
