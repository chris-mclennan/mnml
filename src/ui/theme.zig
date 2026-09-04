//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The theme: every named style the chrome and the editor view paint with.

const color = @import("color.zig");
pub const Style = color.Style;
pub const Color = color.Color;

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .rgb = .{ r, g, b } };
}

pub const Theme = struct {
    bg: Style,
    fg: Style,
    muted: Style,
    accent: Style,
    border: Style,
    gutter: Style,
    cursor_line: Style,
    selection: Style,
    match: Style,
    current_match: Style,
    statusline: Style,
    bufferline: Style,
    tab_active: Style,
    tab_inactive: Style,
    tab_dirty: Style,
    mode_normal: Style,
    mode_insert: Style,
    mode_visual: Style,
    mode_replace: Style,
    mode_edit: Style,
    panel_bg: Style,
    chip: Style,
    chip_active: Style,
    overlay_bg: Style,
    overlay_border: Style,
    overlay_title: Style,
    error_fg: Style,
    warn_fg: Style,
    info_fg: Style,
    fold: Style,
    whitespace: Style,

    pub const default: Theme = blk: {
        const base_bg = rgb(0x1e, 0x1e, 0x2e);
        const base_fg = rgb(0xcd, 0xd6, 0xf4);
        const bar_bg = rgb(0x31, 0x32, 0x44);
        break :blk .{
            .bg = .{ .bg = base_bg, .fg = base_fg },
            .fg = .{ .bg = base_bg, .fg = base_fg },
            .muted = .{ .bg = base_bg, .fg = rgb(0x6c, 0x70, 0x86) },
            .accent = .{ .bg = base_bg, .fg = rgb(0x89, 0xb4, 0xfa) },
            .border = .{ .bg = base_bg, .fg = rgb(0x45, 0x47, 0x5a) },
            .gutter = .{ .bg = base_bg, .fg = rgb(0x6c, 0x70, 0x86) },
            .cursor_line = .{ .bg = rgb(0x2a, 0x2b, 0x3c), .fg = base_fg },
            .selection = .{ .bg = rgb(0x45, 0x47, 0x5a), .fg = base_fg },
            .match = .{ .bg = rgb(0x5a, 0x4a, 0x2a), .fg = base_fg },
            .current_match = .{ .bg = rgb(0xf9, 0xe2, 0xaf), .fg = base_bg },
            .statusline = .{ .bg = bar_bg, .fg = base_fg },
            .bufferline = .{ .bg = rgb(0x18, 0x18, 0x25), .fg = rgb(0x6c, 0x70, 0x86) },
            .tab_active = .{ .bg = base_bg, .fg = base_fg, .bold = true },
            .tab_inactive = .{ .bg = rgb(0x18, 0x18, 0x25), .fg = rgb(0x6c, 0x70, 0x86) },
            .tab_dirty = .{ .bg = base_bg, .fg = rgb(0xf9, 0xe2, 0xaf) },
            .mode_normal = .{ .bg = rgb(0x89, 0xb4, 0xfa), .fg = base_bg, .bold = true },
            .mode_insert = .{ .bg = rgb(0xa6, 0xe3, 0xa1), .fg = base_bg, .bold = true },
            .mode_visual = .{ .bg = rgb(0xcb, 0xa6, 0xf7), .fg = base_bg, .bold = true },
            .mode_replace = .{ .bg = rgb(0xf3, 0x8b, 0xa8), .fg = base_bg, .bold = true },
            .mode_edit = .{ .bg = rgb(0x94, 0xe2, 0xd5), .fg = base_bg, .bold = true },
            .panel_bg = .{ .bg = rgb(0x18, 0x18, 0x25), .fg = base_fg },
            .chip = .{ .bg = bar_bg, .fg = base_fg },
            .chip_active = .{ .bg = rgb(0x89, 0xb4, 0xfa), .fg = base_bg },
            .overlay_bg = .{ .bg = rgb(0x24, 0x24, 0x36), .fg = base_fg },
            .overlay_border = .{ .bg = rgb(0x24, 0x24, 0x36), .fg = rgb(0x89, 0xb4, 0xfa) },
            .overlay_title = .{ .bg = rgb(0x24, 0x24, 0x36), .fg = rgb(0xf9, 0xe2, 0xaf), .bold = true },
            .error_fg = .{ .bg = base_bg, .fg = rgb(0xf3, 0x8b, 0xa8) },
            .warn_fg = .{ .bg = base_bg, .fg = rgb(0xf9, 0xe2, 0xaf) },
            .info_fg = .{ .bg = base_bg, .fg = rgb(0x89, 0xb4, 0xfa) },
            .fold = .{ .bg = base_bg, .fg = rgb(0x6c, 0x70, 0x86), .italic = true },
            .whitespace = .{ .bg = base_bg, .fg = rgb(0x45, 0x47, 0x5a) },
        };
    };
};
