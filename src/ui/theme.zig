//! Theme — every color the UI layer paints with, as ready-made styles.
//!
//! Components never name a color; they name a role (`theme.selection`,
//! `theme.mode_insert`) and the theme decides. `default` is a dark theme
//! built from NvChad's onedark palette (the same seed the Rust mnml
//! ships), in rgb; the Canvas folds rgb onto the 256-color cube when the
//! terminal has no truecolor, so a theme never has to think about it.
//!
//! Every style carries a background on purpose: a chip painted over a
//! panel must not inherit the terminal's default bg through a hole.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

const Theme = @This();

/// Editor body: text on the darkest ground.
bg: Style,
/// Primary text.
fg: Style,
/// Secondary text: hints, counts, placeholders.
muted: Style,
/// Links, group labels, the "look here" color.
accent: Style,
/// Pane frames and separators.
border: Style,
/// Line numbers.
gutter: Style,
/// Background of the row the cursor is on.
cursor_line: Style,
/// Selected text.
selection: Style,
/// A find match.
match: Style,
/// The find match the cursor is on.
current_match: Style,
/// The bottom row.
statusline: Style,
/// The tab strip's ground.
bufferline: Style,
tab_active: Style,
tab_inactive: Style,
/// The `●` on a tab with unsaved changes.
tab_dirty: Style,
mode_normal: Style,
mode_insert: Style,
mode_visual: Style,
mode_replace: Style,
/// The standard (modeless) handler's chip.
mode_edit: Style,
/// Activity panels: TODOS, NOTES, …
panel_bg: Style,
/// A chip at rest (filter pill, inactive button).
chip: Style,
/// A chip that is on / the primary button / the focused choice.
chip_active: Style,
/// Overlay boxes: prompt, picker, confirm, which-key.
overlay_bg: Style,
overlay_border: Style,
overlay_title: Style,
error_fg: Style,
warn_fg: Style,
info_fg: Style,
/// The `⋯ folded · N lines hidden` marker.
fold: Style,
/// Rendered whitespace / indent guides.
whitespace: Style,

pub fn rgb(hex: u24) Color {
    return .{ .rgb = .{
        @intCast((hex >> 16) & 0xff),
        @intCast((hex >> 8) & 0xff),
        @intCast(hex & 0xff),
    } };
}

/// NvChad onedark, base_30 + base_16 — the values the Rust mnml keeps
/// hardcoded as its seed theme.
pub const onedark = struct {
    pub const one_bg = rgb(0x282c34);
    pub const one_bg2 = rgb(0x353b45);
    pub const one_bg3 = rgb(0x373b43);
    pub const black = rgb(0x1e222a);
    pub const darker_black = rgb(0x1b1f27);
    pub const statusline_bg = rgb(0x22262e);
    pub const line = rgb(0x31353d);
    pub const light_bg = rgb(0x2d3139);
    pub const white = rgb(0xabb2bf);
    pub const comment = rgb(0x80848d);
    pub const grey = rgb(0x42464e);
    pub const grey_fg = rgb(0x565c64);
    pub const red = rgb(0xe06c75);
    pub const green = rgb(0x98c379);
    pub const yellow = rgb(0xe7c787);
    pub const orange = rgb(0xfca2aa);
    pub const blue = rgb(0x61afef);
    pub const cyan = rgb(0xa3b8ef);
    pub const purple = rgb(0xde98fd);
    pub const base02 = rgb(0x3e4451);
    pub const base03 = rgb(0x545862);
};

fn on(fg: Color, bg: Color) Style {
    return .{ .fg = fg, .bg = bg };
}

fn bold(fg: Color, bg: Color) Style {
    return .{ .fg = fg, .bg = bg, .bold = true };
}

pub const default: Theme = blk: {
    const p = onedark;
    break :blk .{
        .bg = on(p.white, p.black),
        .fg = on(p.white, p.black),
        .muted = on(p.comment, p.black),
        .accent = on(p.blue, p.black),
        .border = on(p.line, p.black),
        .gutter = on(p.base03, p.black),
        .cursor_line = on(p.white, p.line),
        .selection = on(p.white, p.base02),
        .match = on(p.white, rgb(0x4d4a30)),
        .current_match = bold(p.black, p.yellow),
        .statusline = on(p.white, p.statusline_bg),
        .bufferline = on(p.grey_fg, p.darker_black),
        .tab_active = bold(p.white, p.black),
        .tab_inactive = on(p.grey_fg, p.darker_black),
        .tab_dirty = on(p.orange, p.darker_black),
        .mode_normal = bold(p.black, p.red),
        .mode_insert = bold(p.black, p.green),
        .mode_visual = bold(p.black, p.purple),
        .mode_replace = bold(p.black, p.orange),
        .mode_edit = bold(p.black, p.green),
        .panel_bg = on(p.white, p.darker_black),
        .chip = on(p.white, p.one_bg2),
        .chip_active = bold(p.black, p.cyan),
        .overlay_bg = on(p.white, p.one_bg2),
        .overlay_border = on(p.white, p.one_bg2),
        .overlay_title = bold(p.comment, p.one_bg2),
        .error_fg = on(p.red, p.black),
        .warn_fg = on(p.yellow, p.black),
        .info_fg = on(p.blue, p.black),
        .fold = .{ .fg = p.comment, .bg = p.black, .italic = true },
        .whitespace = on(p.grey, p.black),
    };
};

/// `base` with its background replaced — a chip's text color on the
/// row's ground, a mode color on the statusline.
pub fn onBg(base: Style, bg: Color) Style {
    var out = base;
    out.bg = bg;
    return out;
}

/// `base` with its foreground replaced.
pub fn withFg(base: Style, fg: Color) Style {
    var out = base;
    out.fg = fg;
    return out;
}

test "default theme is rgb throughout and every style has a background" {
    inline for (std.meta.fields(Theme)) |f| {
        const s: Style = @field(default, f.name);
        try std.testing.expect(s.bg == .rgb);
        try std.testing.expect(s.fg == .rgb);
    }
}

test "rgb unpacks channels" {
    const c = rgb(0x61afef);
    try std.testing.expectEqual(@as(u8, 0x61), c.rgb[0]);
    try std.testing.expectEqual(@as(u8, 0xaf), c.rgb[1]);
    try std.testing.expectEqual(@as(u8, 0xef), c.rgb[2]);
}

test "onBg and withFg replace one channel" {
    const s = onBg(default.mode_insert, onedark.statusline_bg);
    try std.testing.expect(s.bold);
    try std.testing.expect(Color.eql(s.bg, onedark.statusline_bg));
    try std.testing.expect(Color.eql(s.fg, default.mode_insert.fg));
    const t = withFg(default.chip, onedark.red);
    try std.testing.expect(Color.eql(t.fg, onedark.red));
    try std.testing.expect(Color.eql(t.bg, default.chip.bg));
}
