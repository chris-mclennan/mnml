//! Colours by role, not by literal. The mount contract gives a sibling
//! the theme's *name* (`hello.theme`, `$MNML_THEME`) and nothing else —
//! the host owns the 95 palettes — so the rule here is the one the SDK
//! actually supports:
//!
//!   * a cell with no colour is the theme's own fg on the theme's own
//!     bg (`sdk.Style{}`), so the pane sits in whatever theme is on;
//!   * everything with meaning is an ANSI index (0–15), which the host
//!     passes to the terminal untouched, so the user's palette — the one
//!     their theme set — decides what "green" looks like;
//!   * only the light/dark split needs the name, because a dim grey that
//!     reads on a dark ground disappears on a light one.
//!
//! `Palette.forTheme` is that one decision; every other colour in the
//! pane comes from here by role so a change lands in one place.

const std = @import("std");
const sdk = @import("mnml_sdk");

pub const Color = sdk.Color;
pub const Style = sdk.Style;

/// ANSI slots, named so a call site reads as a role.
const black: Color = .{ .index = 0 };
const red: Color = .{ .index = 1 };
const green: Color = .{ .index = 2 };
const yellow: Color = .{ .index = 3 };
const blue: Color = .{ .index = 4 };
const magenta: Color = .{ .index = 5 };
const cyan: Color = .{ .index = 6 };
const white: Color = .{ .index = 7 };
const bright_black: Color = .{ .index = 8 };
const bright_red: Color = .{ .index = 9 };
const bright_green: Color = .{ .index = 10 };
const bright_yellow: Color = .{ .index = 11 };
const bright_blue: Color = .{ .index = 12 };
const bright_magenta: Color = .{ .index = 13 };
const bright_cyan: Color = .{ .index = 14 };
const bright_white: Color = .{ .index = 15 };

pub const Palette = struct {
    /// True when the theme's name says it paints on a light ground.
    light: bool,
    /// Section headers, the focused tab, the ticket key.
    accent: Color,
    /// A second accent for the detail pane's field labels.
    label: Color,
    /// Row text that is there but not the point (timestamps, counts).
    muted: Color,
    /// A status in the `new` category (To Do, Backlog).
    todo: Color,
    /// A status in the `indeterminate` category (In Progress, Review).
    doing: Color,
    /// A status in the `done` category.
    done: Color,
    /// A failed refresh, a refused transition.
    err: Color,
    /// A warning line — a partial refresh, a missing token.
    warn: Color,
    /// A confirmed action.
    ok: Color,

    /// The name mnml said hello with. Only the light/dark split is read
    /// from it — an unknown name is treated as dark, which is what all
    /// but a handful of mnml's themes are.
    pub fn forTheme(name: []const u8) Palette {
        return if (isLight(name)) light_palette else dark_palette;
    }

    pub const dark_palette: Palette = .{
        .light = false,
        .accent = bright_cyan,
        .label = bright_blue,
        .muted = bright_black,
        .todo = bright_black,
        .doing = bright_yellow,
        .done = bright_green,
        .err = bright_red,
        .warn = yellow,
        .ok = green,
    };

    pub const light_palette: Palette = .{
        .light = true,
        .accent = blue,
        .label = magenta,
        .muted = bright_black,
        .todo = bright_black,
        .doing = yellow,
        .done = green,
        .err = red,
        .warn = yellow,
        .ok = green,
    };
};

/// mnml's light themes all say so in the file name — `*_light`,
/// `*-light`, `*-latte`, `dayfox`, `rose-pine-dawn`, … — so the split is
/// a name test, and an unknown name is dark.
pub fn isLight(name: []const u8) bool {
    if (name.len == 0) return false;
    var buf: [64]u8 = undefined;
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..n];
    if (std.mem.indexOf(u8, lower, "light") != null) return true;
    if (std.mem.indexOf(u8, lower, "latte") != null) return true;
    if (std.mem.indexOf(u8, lower, "dawn") != null) return true;
    if (std.mem.indexOf(u8, lower, "day") != null) return true;
    for (light_names) |ln| if (std.mem.eql(u8, lower, ln)) return true;
    return false;
}

/// The light themes in `themes/` whose names do not say so.
const light_names = [_][]const u8{
    "blossom",
    "gruvbox_light",
    "mellow",
    "one_light",
    "paper",
    "solarized_light",
    "tokyonight_day",
};

/// The status categories Jira sorts every workflow status into
/// (`statusCategory.key` on the wire).
pub const StatusCategory = enum {
    new,
    indeterminate,
    done,
    unknown,

    pub fn fromKey(key: []const u8) StatusCategory {
        if (std.mem.eql(u8, key, "new")) return .new;
        if (std.mem.eql(u8, key, "indeterminate")) return .indeterminate;
        if (std.mem.eql(u8, key, "done")) return .done;
        return .unknown;
    }
};

pub fn statusColor(p: Palette, cat: StatusCategory) Color {
    return switch (cat) {
        .new => p.todo,
        .indeterminate => p.doing,
        .done => p.done,
        .unknown => p.muted,
    };
}

/// Jira's priority names, brightest first. An unknown one is muted.
pub fn priorityColor(p: Palette, name: []const u8) Color {
    if (eqIgnoreCase(name, "highest") or eqIgnoreCase(name, "blocker")) return p.err;
    if (eqIgnoreCase(name, "high") or eqIgnoreCase(name, "critical")) return p.warn;
    if (eqIgnoreCase(name, "medium") or eqIgnoreCase(name, "major")) return p.label;
    return p.muted;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The base style of a row: the theme's own fg on its own bg.
pub const base: Style = .{};

pub fn fg(c: Color) Style {
    return .{ .fg = c };
}

pub fn fgBold(c: Color) Style {
    return .{ .fg = c, .mods = .{ .bold = true } };
}

pub fn dim(p: Palette) Style {
    return .{ .fg = p.muted };
}

/// The selected row: reverse video, so it tracks the theme's own
/// foreground and background without the pane guessing either.
pub const selected: Style = .{ .mods = .{ .reverse = true } };

/// The selected row when the pane does not have the keyboard.
pub fn selectedUnfocused(p: Palette) Style {
    return .{ .fg = p.accent, .mods = .{ .bold = true } };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the light/dark split reads the theme name mnml said hello with" {
    try testing.expect(isLight("catppuccin-latte"));
    try testing.expect(isLight("ayu_light"));
    try testing.expect(isLight("everforest_light"));
    try testing.expect(isLight("rose-pine-dawn"));
    try testing.expect(isLight("tokyonight_day"));
    try testing.expect(isLight("one_light"));
    try testing.expect(!isLight("onedark"));
    try testing.expect(!isLight("catppuccin"));
    try testing.expect(!isLight(""));
    try testing.expect(!isLight("gruvbox"));
    try testing.expect(Palette.forTheme("onedark").accent.index == 14);
    try testing.expect(Palette.forTheme("ayu_light").light);
}

test "status categories map to the three role colours; an unknown one is muted" {
    const p = Palette.dark_palette;
    try testing.expectEqual(StatusCategory.new, StatusCategory.fromKey("new"));
    try testing.expectEqual(StatusCategory.indeterminate, StatusCategory.fromKey("indeterminate"));
    try testing.expectEqual(StatusCategory.done, StatusCategory.fromKey("done"));
    try testing.expectEqual(StatusCategory.unknown, StatusCategory.fromKey("wat"));
    try testing.expectEqual(p.doing, statusColor(p, .indeterminate));
    try testing.expectEqual(p.done, statusColor(p, .done));
    try testing.expectEqual(p.muted, statusColor(p, .unknown));
}

test "priorities darken from Highest down; an unknown name is muted" {
    const p = Palette.dark_palette;
    try testing.expectEqual(p.err, priorityColor(p, "Highest"));
    try testing.expectEqual(p.warn, priorityColor(p, "high"));
    try testing.expectEqual(p.label, priorityColor(p, "Medium"));
    try testing.expectEqual(p.muted, priorityColor(p, "Trivial"));
}
