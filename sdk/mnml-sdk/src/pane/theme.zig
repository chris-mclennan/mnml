//! The pane's colours, in mnml's roles. `hello.palette` carries the host
//! theme's roles; a host that sends none (an older mnml, a theme that
//! leaves a role to the terminal) falls back to the 16-colour palette, so
//! a pane reads the same either way — just less native.
//!
//! **Never an ANSI index in a painter.** A pane that writes
//! `.{ .index = 6 }` picks the terminal's teal and ignores the theme it
//! is mounted in; every colour a pane paints comes from here.

const std = @import("std");
const wire = @import("../wire.zig");
const frame = @import("../frame.zig");

pub const Style = frame.Style;
pub const Color = wire.Color;

pub const Theme = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    muted: Color = .{ .index = 8 },
    accent: Color = .{ .index = 6 },
    border: Color = .{ .index = 8 },
    panel_bg: ?Color = null,
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
    /// The integration's own colour — the manifest chip's, resolved
    /// once at hello time. The left gutter stripe paints in it.
    brand: Color = .{ .index = 6 },

    pub fn fromHello(p: ?wire.Palette) Theme {
        var th: Theme = .{};
        const pal = p orelse return th;
        th.fg = pal.fg;
        th.bg = pal.bg;
        if (pal.muted) |c| th.muted = c;
        if (pal.accent) |c| th.accent = c;
        if (pal.border) |c| th.border = c;
        if (pal.panel_bg) |c| th.panel_bg = c;
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
        th.brand = th.accent;
        return th;
    }

    /// The same, with the integration's manifest chip colour resolved
    /// into `brand`: `"blue"`, `"magenta"`, `"#D97757"`. An unknown
    /// name leaves the accent, the way the host's chip rail reads it.
    pub fn fromHelloBranded(p: ?wire.Palette, chip_color: []const u8) Theme {
        var th = fromHello(p);
        th.brand = th.slot(chip_color);
        return th;
    }

    /// A manifest colour slot — a role name, or a `#RRGGBB` literal.
    pub fn slot(th: Theme, name: []const u8) Color {
        if (name.len == 7 and name[0] == '#') {
            const r = std.fmt.parseInt(u8, name[1..3], 16) catch return th.accent;
            const g = std.fmt.parseInt(u8, name[3..5], 16) catch return th.accent;
            const b = std.fmt.parseInt(u8, name[5..7], 16) catch return th.accent;
            return .{ .rgb = .{ r, g, b } };
        }
        if (std.mem.eql(u8, name, "red")) return th.red;
        if (std.mem.eql(u8, name, "orange")) return th.orange;
        if (std.mem.eql(u8, name, "yellow")) return th.yellow;
        if (std.mem.eql(u8, name, "green")) return th.green;
        if (std.mem.eql(u8, name, "blue")) return th.blue;
        if (std.mem.eql(u8, name, "cyan") or std.mem.eql(u8, name, "teal")) return th.cyan;
        if (std.mem.eql(u8, name, "purple") or std.mem.eql(u8, name, "magenta") or std.mem.eql(u8, name, "pink")) return th.purple;
        if (std.mem.eql(u8, name, "comment")) return th.comment;
        if (std.mem.eql(u8, name, "fg")) return th.fg orelse th.accent;
        return th.accent;
    }

    // ─── the roles a painter asks for ────────────────────────────────

    pub fn text(th: Theme) Style {
        return .{ .fg = th.fg };
    }

    /// The bright foreground a key, an id or a `Show more (N)` uses.
    pub fn bright(th: Theme) Style {
        return .{ .fg = th.fg, .mods = .{ .bold = true } };
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

    pub fn accentPlain(th: Theme) Style {
        return .{ .fg = th.accent };
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

    /// The gutter stripe on the cursor's row, and on every other one.
    pub fn gutterOn(th: Theme) Style {
        return .{ .fg = th.brand, .mods = .{ .bold = true } };
    }

    pub fn gutterOff(th: Theme) Style {
        return .{ .fg = th.brand, .mods = .{ .dim = true } };
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

    /// A pull request's state. One mapping for every pane that shows a
    /// PR: green open, purple merged, red declined, grey superseded.
    pub fn prState(th: Theme, state: []const u8) Style {
        if (std.ascii.eqlIgnoreCase(state, "OPEN")) return .{ .fg = th.green };
        if (std.ascii.eqlIgnoreCase(state, "MERGED")) return .{ .fg = th.purple };
        if (std.ascii.eqlIgnoreCase(state, "DECLINED")) return .{ .fg = th.red };
        if (std.ascii.eqlIgnoreCase(state, "SUPERSEDED")) return .{ .fg = th.muted };
        return .{ .fg = th.fg };
    }

    /// A pipeline result / state's colour.
    pub fn pipelineState(th: Theme, state: []const u8) Style {
        if (std.ascii.eqlIgnoreCase(state, "SUCCESSFUL") or std.ascii.eqlIgnoreCase(state, "SUCCEED") or std.ascii.eqlIgnoreCase(state, "PASSED")) return .{ .fg = th.green };
        if (std.ascii.eqlIgnoreCase(state, "FAILED") or std.ascii.eqlIgnoreCase(state, "ERROR")) return .{ .fg = th.red };
        if (std.ascii.eqlIgnoreCase(state, "IN_PROGRESS") or std.ascii.eqlIgnoreCase(state, "PENDING") or std.ascii.eqlIgnoreCase(state, "RUNNING")) return .{ .fg = th.yellow };
        if (std.ascii.eqlIgnoreCase(state, "STOPPED") or std.ascii.eqlIgnoreCase(state, "HALTED")) return .{ .fg = th.muted };
        if (std.ascii.eqlIgnoreCase(state, "COMPLETED")) return .{ .fg = th.fg };
        return .{ .fg = th.muted };
    }

    /// A tracker status, by its category: `done` green, an in-flight
    /// `indeterminate` blue, anything still to start grey.
    pub fn ticketStatus(th: Theme, category: []const u8) Style {
        if (std.ascii.eqlIgnoreCase(category, "done")) return .{ .fg = th.green };
        if (std.ascii.eqlIgnoreCase(category, "indeterminate")) return .{ .fg = th.blue };
        return .{ .fg = th.muted, .mods = .{ .dim = true } };
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

    /// An overlay's ground — a menu, the key sheet, a picker.
    pub fn overlayBg(th: Theme) Style {
        return .{ .fg = th.fg, .bg = th.cursor_line };
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a hello without a palette paints with indices; one with it paints the theme" {
    const plain = Theme.fromHello(null);
    try testing.expectEqual(Color{ .index = 6 }, plain.accent);
    try testing.expect(plain.fg == null);
    const themed = Theme.fromHello(.{ .accent = .{ .rgb = .{ 97, 175, 239 } }, .fg = .{ .rgb = .{ 1, 2, 3 } } });
    try testing.expectEqual(Color{ .rgb = .{ 97, 175, 239 } }, themed.accent);
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, themed.fg.?);
    try testing.expectEqual(Color{ .index = 8 }, themed.muted);
    try testing.expectEqual(themed.green, themed.prState("open").fg.?);
    try testing.expectEqual(themed.purple, themed.prState("MERGED").fg.?);
    try testing.expectEqual(themed.red, themed.pipelineState("FAILED").fg.?);
    try testing.expectEqual(themed.green, themed.ticketStatus("done").fg.?);
    try testing.expectEqual(themed.blue, themed.ticketStatus("indeterminate").fg.?);
}

test "the manifest chip colour becomes the pane's brand: a role name, a hex literal, or the accent" {
    const pal: wire.Palette = .{ .blue = .{ .rgb = .{ 1, 2, 3 } }, .purple = .{ .rgb = .{ 4, 5, 6 } }, .green = .{ .rgb = .{ 7, 8, 9 } }, .accent = .{ .rgb = .{ 9, 9, 9 } } };
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, Theme.fromHelloBranded(pal, "blue").brand);
    try testing.expectEqual(Color{ .rgb = .{ 4, 5, 6 } }, Theme.fromHelloBranded(pal, "magenta").brand);
    try testing.expectEqual(Color{ .rgb = .{ 7, 8, 9 } }, Theme.fromHelloBranded(pal, "green").brand);
    try testing.expectEqual(Color{ .rgb = .{ 0xD9, 0x77, 0x57 } }, Theme.fromHelloBranded(pal, "#D97757").brand);
    try testing.expectEqual(Color{ .rgb = .{ 9, 9, 9 } }, Theme.fromHelloBranded(pal, "not-a-colour").brand);
    // No palette at all: the brand still resolves, off the fallbacks.
    try testing.expectEqual(Color{ .index = 4 }, Theme.fromHelloBranded(null, "blue").brand);
}
