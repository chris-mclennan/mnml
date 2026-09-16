//! The pane's colours, in mnml's roles. `hello.palette` carries the
//! host theme's roles; a host that sends none (an older mnml, a theme
//! that leaves a role to the terminal) falls back to the 16-colour
//! palette, so the pane reads the same either way — just less native.

const std = @import("std");
const sdk = @import("mnml_sdk");

pub const Style = sdk.Style;
pub const Color = sdk.Color;

pub const Theme = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    muted: Color = .{ .index = 8 },
    accent: Color = .{ .index = 6 },
    border: Color = .{ .index = 8 },
    cursor_line: Color = .{ .index = 0 },
    chip_fg: ?Color = null,
    chip_bg: Color = .{ .index = 8 },
    chip_active_fg: Color = .{ .index = 0 },
    chip_active_bg: Color = .{ .index = 6 },
    red: Color = .{ .index = 1 },
    green: Color = .{ .index = 2 },
    yellow: Color = .{ .index = 3 },
    orange: Color = .{ .index = 3 },
    blue: Color = .{ .index = 4 },
    cyan: Color = .{ .index = 6 },
    purple: Color = .{ .index = 5 },
    comment: Color = .{ .index = 8 },

    pub fn fromHello(p: ?sdk.wire.Palette) Theme {
        var th: Theme = .{};
        const pal = p orelse return th;
        th.fg = pal.fg;
        th.bg = pal.bg;
        if (pal.muted) |c| th.muted = c;
        if (pal.accent) |c| th.accent = c;
        if (pal.border) |c| th.border = c;
        if (pal.cursor_line) |c| th.cursor_line = c;
        if (pal.chip_fg) |c| th.chip_fg = c;
        if (pal.chip_bg) |c| th.chip_bg = c;
        if (pal.chip_active_fg) |c| th.chip_active_fg = c;
        if (pal.chip_active_bg) |c| th.chip_active_bg = c;
        if (pal.red) |c| th.red = c;
        if (pal.green) |c| th.green = c;
        if (pal.yellow) |c| th.yellow = c;
        if (pal.orange) |c| th.orange = c;
        if (pal.blue) |c| th.blue = c;
        if (pal.cyan) |c| th.cyan = c;
        if (pal.purple) |c| th.purple = c;
        if (pal.comment) |c| th.comment = c;
        return th;
    }

    // ─── the roles a painter asks for ────────────────────────────────

    pub fn text(th: Theme) Style {
        return .{ .fg = th.fg };
    }

    pub fn mutedText(th: Theme) Style {
        return .{ .fg = th.muted };
    }

    pub fn dimText(th: Theme) Style {
        return .{ .fg = th.muted, .mods = .{ .dim = true } };
    }

    /// The caps title of a panel header.
    pub fn label(th: Theme) Style {
        return .{ .fg = th.muted, .mods = .{ .bold = true } };
    }

    pub fn accentText(th: Theme) Style {
        return .{ .fg = th.accent, .mods = .{ .bold = true } };
    }

    /// A chip that is a button: dark text on the accent.
    pub fn chipActive(th: Theme) Style {
        return .{ .fg = th.chip_active_fg, .bg = th.chip_active_bg, .mods = .{ .bold = true } };
    }

    /// A chip at rest.
    pub fn chip(th: Theme) Style {
        return .{ .fg = th.chip_fg orelse th.fg, .bg = th.chip_bg };
    }

    /// The filter pill while it has the keys: the ground stays, the
    /// text brightens.
    pub fn chipActiveSoft(th: Theme) Style {
        return .{ .fg = th.fg, .bg = th.chip_bg };
    }

    /// The refresh glyph: the accent on the ground.
    pub fn refresh(th: Theme) Style {
        return .{ .fg = th.chip_active_bg };
    }

    /// The row the cursor is on.
    pub fn cursorRow(th: Theme) Style {
        return .{ .fg = th.fg, .bg = th.cursor_line };
    }

    pub fn onCursor(th: Theme, s: Style) Style {
        var out = s;
        out.bg = th.cursor_line;
        return out;
    }

    pub fn marker(th: Theme) Style {
        return .{ .fg = th.accent, .bg = th.cursor_line, .mods = .{ .bold = true } };
    }

    pub fn tabActive(th: Theme) Style {
        return th.chipActive();
    }

    pub fn tabInactive(th: Theme) Style {
        return .{ .fg = th.muted };
    }

    /// A PR state's colour.
    pub fn prState(th: Theme, state: []const u8) Style {
        if (std.ascii.eqlIgnoreCase(state, "OPEN")) return .{ .fg = th.green };
        if (std.ascii.eqlIgnoreCase(state, "MERGED")) return .{ .fg = th.purple };
        if (std.ascii.eqlIgnoreCase(state, "DECLINED")) return .{ .fg = th.red };
        if (std.ascii.eqlIgnoreCase(state, "SUPERSEDED")) return .{ .fg = th.muted };
        return .{ .fg = th.fg };
    }

    /// A pipeline result / state's colour.
    pub fn pipelineState(th: Theme, state: []const u8) Style {
        if (std.mem.eql(u8, state, "SUCCESSFUL") or std.mem.eql(u8, state, "SUCCEED") or std.mem.eql(u8, state, "PASSED")) return .{ .fg = th.green };
        if (std.mem.eql(u8, state, "FAILED") or std.mem.eql(u8, state, "ERROR")) return .{ .fg = th.red };
        if (std.mem.eql(u8, state, "IN_PROGRESS") or std.mem.eql(u8, state, "PENDING") or std.mem.eql(u8, state, "RUNNING")) return .{ .fg = th.yellow };
        if (std.mem.eql(u8, state, "STOPPED") or std.mem.eql(u8, state, "HALTED")) return .{ .fg = th.muted };
        if (std.mem.eql(u8, state, "COMPLETED")) return .{ .fg = th.fg };
        return .{ .fg = th.muted };
    }

    pub fn good(th: Theme) Style {
        return .{ .fg = th.green };
    }

    pub fn bad(th: Theme) Style {
        return .{ .fg = th.red };
    }

    pub fn warn(th: Theme) Style {
        return .{ .fg = th.yellow };
    }

    pub fn number(th: Theme) Style {
        return .{ .fg = th.yellow };
    }

    pub fn section(th: Theme) Style {
        return .{ .fg = th.purple, .mods = .{ .bold = true } };
    }

    pub fn overlayBorder(th: Theme) Style {
        return .{ .fg = th.border };
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a hello without a palette paints with indices; one with it paints the theme" {
    const plain = Theme.fromHello(null);
    try t.expectEqual(Color{ .index = 6 }, plain.accent);
    try t.expect(plain.fg == null);
    const themed = Theme.fromHello(.{ .accent = .{ .rgb = .{ 97, 175, 239 } }, .fg = .{ .rgb = .{ 1, 2, 3 } } });
    try t.expectEqual(Color{ .rgb = .{ 97, 175, 239 } }, themed.accent);
    try t.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, themed.fg.?);
    // A role the theme left out keeps its index fallback.
    try t.expectEqual(Color{ .index = 8 }, themed.muted);
    try t.expectEqual(themed.green, themed.prState("open").fg.?);
    try t.expectEqual(themed.red, themed.pipelineState("FAILED").fg.?);
}
