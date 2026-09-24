//! Theme — every color the UI layer paints with, as ready-made styles.
//!
//! Components never name a color; they name a role (`theme.selection`,
//! `theme.mode_insert`) and the theme decides. A theme is derived from a
//! palette: NvChad's `base_30` (the chrome) and `base_16` (the syntax
//! slots), as shipped in `themes/*.zon` and imported at comptime through
//! the `themes` module — so `all` is a table in rodata, `byName` is a
//! scan over it, and a palette that does not parse is a build failure.
//!
//! A palette may be partial (upstream leaves slots out); `resolve` fills
//! each role through the same fallback chain mnml 0.2 used, and a missing
//! `base_16` slot takes onedark's, so every bundled theme paints every
//! role. `default` is onedark, the theme the shipped config names.
//!
//! Every chrome style carries a background on purpose: a chip painted
//! over a panel must not inherit the terminal's default bg through a
//! hole. Syntax styles are foreground-only — they sit on the row's ground.

const std = @import("std");
const vaxis = @import("vaxis");
const themes = @import("themes");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;
pub const Source = themes.Source;
pub const Kind = themes.Kind;

const Theme = @This();

name: []const u8,
kind: Kind,
/// The resolved colours, for the few places that want a named colour
/// rather than a role (a brand chip, a diagnostic severity).
palette: Palette,

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
/// Something is blocked on the user — a session that needs you: its
/// tab's mark, its SESSIONS card's, the dock's running mark for its
/// kind. A role of its own so the three stay one colour whatever a
/// theme does to warnings.
attention_fg: Style,
info_fg: Style,
/// The `⋯ folded · N lines hidden` marker.
fold: Style,
/// Rendered whitespace (`ui.show_whitespace`'s `·` and `→`).
whitespace: Style,
/// An indent guide (`editor.indent_guides`): faint, a step above the
/// ground — NvChad's `IblChar`.
indent_guide: Style,
/// The indent guide of the block the cursor is in — NvChad's
/// `IblScopeChar`, brighter than the rest.
indent_guide_active: Style,
/// Tree-sitter capture roles, foreground only.
syntax: Syntax,

/// What a highlight capture paints as. `styleForCapture` in
/// `app/syntax.zig` maps capture-name prefixes onto these.
pub const Syntax = struct {
    comment: Style,
    string: Style,
    keyword: Style,
    function: Style,
    type: Style,
    constructor: Style,
    number: Style,
    constant: Style,
    operator: Style,
    punctuation: Style,
    property: Style,
    attribute: Style,
    variable: Style,
    tag: Style,
    label: Style,
    namespace: Style,
    text: Style,
    escape: Style,
};

/// The palette after every fallback: the 25 named chrome colours mnml
/// 0.2 kept on its `Theme`, plus the sixteen syntax slots.
pub const Palette = struct {
    /// one_bg — secondary panel ground
    bg: Color,
    /// one_bg2 — selected row / hover
    bg2: Color,
    /// one_bg3
    bg3: Color,
    /// black — the editor body
    bg_dark: Color,
    /// darker_black — tree rail, bufferline, overlays
    bg_darker: Color,
    /// statusline_bg
    statusline: Color,
    /// current-line ground and separators
    line: Color,
    /// lightbg — file-tab body
    lightbg: Color,
    /// white — primary text
    fg: Color,
    /// light_grey / grey_fg2
    comment: Color,
    grey: Color,
    grey_fg: Color,
    red: Color,
    pink: Color,
    green: Color,
    vibrant_green: Color,
    yellow: Color,
    sun: Color,
    orange: Color,
    blue: Color,
    nord_blue: Color,
    teal: Color,
    cyan: Color,
    purple: Color,
    dark_purple: Color,
    /// `base00`..`base0F`.
    base16: [16]Color,
};

pub fn rgb(hex: u24) Color {
    return .{ .rgb = .{
        @intCast((hex >> 16) & 0xff),
        @intCast((hex >> 8) & 0xff),
        @intCast(hex & 0xff),
    } };
}

// ─── the palette ─────────────────────────────────────────────────────────

/// The first of `keys` the source sets, else `fallback`.
fn pick(src: Source, comptime keys: []const []const u8, fallback: Color) Color {
    inline for (keys) |k| {
        if (@field(src.base_30, k)) |hex| return rgb(hex);
    }
    return fallback;
}

/// onedark's `base_16`, the fill for a slot a palette leaves out.
const onedark_base16 = [16]u24{
    0x1e222a, 0x353b45, 0x3e4451, 0x545862, 0x565c64, 0xabb2bf, 0xb6bdca, 0xc8ccd4,
    0xe06c75, 0xd19a66, 0xe5c07b, 0x98c379, 0x56b6c2, 0x61afef, 0xc678dd, 0xbe5046,
};
const onedark_fg = rgb(0xabb2bf);
const onedark_bg_dark = rgb(0x1e222a);

/// Resolve every role through its fallback chain (the chains mnml 0.2's
/// `theme.rs` used, kept verbatim so a partial upstream palette lands on
/// the same colours it did there).
pub fn resolve(src: Source) Palette {
    const white = pick(src, &.{"white"}, onedark_fg);
    const black = pick(src, &.{"black"}, onedark_bg_dark);
    var base16: [16]Color = undefined;
    inline for (std.meta.fields(themes.Base16), 0..) |f, i| {
        base16[i] = rgb(@field(src.base_16, f.name) orelse onedark_base16[i]);
    }
    return .{
        .bg = pick(src, &.{ "one_bg", "black" }, black),
        .bg2 = pick(src, &.{ "one_bg2", "one_bg" }, black),
        .bg3 = pick(src, &.{ "one_bg3", "one_bg2" }, black),
        .bg_dark = black,
        .bg_darker = pick(src, &.{"darker_black"}, black),
        .statusline = pick(src, &.{ "statusline_bg", "black2" }, black),
        .line = pick(src, &.{ "line", "one_bg3" }, black),
        .lightbg = pick(src, &.{ "lightbg", "one_bg" }, black),
        .fg = white,
        .comment = pick(src, &.{ "light_grey", "grey_fg2", "grey_fg", "grey" }, white),
        .grey = pick(src, &.{ "grey", "grey_fg" }, white),
        .grey_fg = pick(src, &.{ "grey_fg", "grey" }, white),
        .red = pick(src, &.{"red"}, white),
        .pink = pick(src, &.{ "pink", "baby_pink" }, white),
        .green = pick(src, &.{"green"}, white),
        .vibrant_green = pick(src, &.{ "vibrant_green", "green" }, white),
        .yellow = pick(src, &.{"yellow"}, white),
        .sun = pick(src, &.{ "sun", "yellow" }, white),
        .orange = pick(src, &.{"orange"}, white),
        .blue = pick(src, &.{"blue"}, white),
        .nord_blue = pick(src, &.{ "nord_blue", "blue" }, white),
        .teal = pick(src, &.{"teal"}, white),
        .cyan = pick(src, &.{ "cyan", "blue" }, white),
        .purple = pick(src, &.{"purple"}, white),
        .dark_purple = pick(src, &.{ "dark_purple", "purple" }, white),
        .base16 = base16,
    };
}

// ─── the styles ──────────────────────────────────────────────────────────

fn on(fg: Color, bg: Color) Style {
    return .{ .fg = fg, .bg = bg };
}

fn bold(fg: Color, bg: Color) Style {
    return .{ .fg = fg, .bg = bg, .bold = true };
}

fn fgOnly(fg: Color) Style {
    return .{ .fg = fg };
}

/// A palette → the roles. Pure, so it runs at comptime for the bundled
/// table and at runtime for a `--theme-dir` file alike.
pub fn derive(src: Source) Theme {
    const p = resolve(src);
    const b16 = p.base16;
    return .{
        .name = src.name,
        .kind = src.kind,
        .palette = p,
        .bg = on(p.fg, p.bg_dark),
        .fg = on(p.fg, p.bg_dark),
        .muted = on(p.comment, p.bg_dark),
        .accent = on(p.blue, p.bg_dark),
        .border = on(p.line, p.bg_dark),
        // NvChad's `LineNr = { fg = colors.grey }` (base46
        // integrations/defaults.lua) — not base_16's `base03`, which in
        // most palettes is a background shade: on onenord_light it is
        // 1.01:1 against the ground, invisible.
        .gutter = on(p.grey, p.bg_dark),
        .cursor_line = on(p.fg, p.line),
        .selection = on(p.fg, b16[2]),
        .match = on(p.fg, p.grey),
        .current_match = bold(p.bg_dark, p.yellow),
        .statusline = on(p.fg, p.statusline),
        .bufferline = on(p.grey_fg, p.bg_darker),
        .tab_active = bold(p.fg, p.bg_dark),
        .tab_inactive = on(p.grey_fg, p.bg_darker),
        .tab_dirty = on(p.orange, p.bg_darker),
        .mode_normal = bold(p.bg_dark, p.red),
        .mode_insert = bold(p.bg_dark, p.green),
        .mode_visual = bold(p.bg_dark, p.purple),
        .mode_replace = bold(p.bg_dark, p.orange),
        .mode_edit = bold(p.bg_dark, p.green),
        .panel_bg = on(p.fg, p.bg_darker),
        .chip = on(p.fg, p.bg2),
        .chip_active = bold(p.bg_dark, p.cyan),
        .overlay_bg = on(p.fg, p.bg2),
        .overlay_border = on(p.fg, p.bg2),
        .overlay_title = bold(p.comment, p.bg2),
        .error_fg = on(p.red, p.bg_dark),
        .warn_fg = on(p.yellow, p.bg_dark),
        .attention_fg = bold(p.yellow, p.bg_dark),
        .info_fg = on(p.blue, p.bg_dark),
        .fold = .{ .fg = p.comment, .bg = p.bg_dark, .italic = true },
        .whitespace = on(p.grey, p.bg_dark),
        .indent_guide = on(p.bg3, p.bg_dark),
        .indent_guide_active = on(p.grey_fg, p.bg_dark),
        // base16 roles: 05 default fg, 08 variables, 09
        // numbers / constants, 0A types, 0B strings, 0C escapes /
        // constructors, 0D functions, 0E keywords, 0F punctuation.
        .syntax = .{
            // NvChad's `Comment = { fg = colors.light_grey }`, not
            // `base03` (see the gutter above) — the palette's `comment`.
            .comment = .{ .fg = p.comment, .italic = true },
            .string = fgOnly(b16[0xB]),
            .keyword = fgOnly(b16[0xE]),
            .function = fgOnly(b16[0xD]),
            .type = fgOnly(b16[0xA]),
            .constructor = fgOnly(b16[0xC]),
            .number = fgOnly(b16[9]),
            .constant = fgOnly(b16[9]),
            .operator = fgOnly(b16[5]),
            .punctuation = fgOnly(b16[0xF]),
            .property = fgOnly(b16[8]),
            .attribute = fgOnly(b16[0xA]),
            .variable = fgOnly(b16[8]),
            .tag = fgOnly(b16[8]),
            .label = fgOnly(b16[0xC]),
            .namespace = fgOnly(b16[0xA]),
            .text = fgOnly(b16[5]),
            .escape = fgOnly(b16[0xC]),
        },
    };
}

// ─── the table ───────────────────────────────────────────────────────────

/// Every bundled theme, derived at comptime, in `themes/root.zig` order
/// (alphabetical by file).
pub const all: [themes.all.len]Theme = blk: {
    @setEvalBranchQuota(200_000);
    var out: [themes.all.len]Theme = undefined;
    for (themes.all, 0..) |src, i| out[i] = derive(src);
    break :blk out;
};

pub const default_name = "onedark";

/// Case-insensitive, whitespace-trimmed lookup.
pub fn byName(name: []const u8) ?*const Theme {
    const want = std.mem.trim(u8, name, " \t\r\n");
    for (&all) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, want)) return t;
    }
    return null;
}

/// The first theme of `kind` whose name is not `except` — what
/// `theme.toggle` reaches for when `ui.theme_toggle` is unset.
pub fn firstOfKind(kind: Kind, except: []const u8) ?*const Theme {
    for (&all) |*t| {
        if (t.kind == kind and !std.ascii.eqlIgnoreCase(t.name, except)) return t;
    }
    return null;
}

/// The shipped default: onedark, which `Config{}` names.
pub const default: Theme = blk: {
    @setEvalBranchQuota(200_000);
    for (all) |t| if (std.mem.eql(u8, t.name, default_name)) break :blk t;
    @compileError("themes/: no " ++ default_name ++ ".zon — the default theme is not bundled");
};

/// onedark's named colours, for the tests and demos that want a known
/// colour without naming a role.
pub const onedark = struct {
    pub const one_bg = default.palette.bg;
    pub const one_bg2 = default.palette.bg2;
    pub const black = default.palette.bg_dark;
    pub const darker_black = default.palette.bg_darker;
    pub const statusline_bg = default.palette.statusline;
    pub const line = default.palette.line;
    pub const white = default.palette.fg;
    pub const comment = default.palette.comment;
    pub const grey = default.palette.grey;
    pub const grey_fg = default.palette.grey_fg;
    pub const red = default.palette.red;
    pub const green = default.palette.green;
    pub const yellow = default.palette.yellow;
    pub const orange = default.palette.orange;
    pub const blue = default.palette.blue;
    pub const cyan = default.palette.cyan;
    pub const purple = default.palette.purple;
};

/// The style a highlighter role paints with. The text modifiers
/// (strong / emphasis / title / uri) are the base slot plus an SGR
/// attribute, so a theme never has to list them.
pub fn roleStyle(t: *const Theme, role: anytype) Style {
    return switch (role) {
        .none, .default => t.fg,
        .comment => t.syntax.comment,
        .variable => t.syntax.variable,
        .constant => t.syntax.constant,
        .type => t.syntax.type,
        .string => t.syntax.string,
        .special => t.syntax.escape,
        .function => t.syntax.function,
        .keyword => t.syntax.keyword,
        .punctuation => t.syntax.punctuation,
        .strong => blk: {
            var s = t.fg;
            s.bold = true;
            break :blk s;
        },
        .emphasis => blk: {
            var s = t.fg;
            s.italic = true;
            break :blk s;
        },
        .title => blk: {
            var s = t.syntax.function;
            s.bold = true;
            break :blk s;
        },
        .uri => blk: {
            var s = t.syntax.escape;
            s.ul_style = .single;
            break :blk s;
        },
    };
}

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

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "every bundled theme derives with rgb in every chrome role" {
    try testing.expect(all.len >= 94);
    for (&all) |*t| {
        try testing.expect(t.name.len > 0);
        inline for (std.meta.fields(Theme)) |f| {
            if (f.type == Style) {
                const s: Style = @field(t, f.name);
                try testing.expect(s.bg == .rgb);
                try testing.expect(s.fg == .rgb);
            }
        }
        inline for (std.meta.fields(Syntax)) |f| {
            try testing.expect(@field(t.syntax, f.name).fg == .rgb);
        }
    }
}

test "default is onedark and matches the seed values mnml 0.2 hardcoded" {
    try testing.expectEqualStrings("onedark", default.name);
    try testing.expect(default.kind == .dark);
    try testing.expect(Color.eql(default.palette.bg_dark, rgb(0x1e222a)));
    try testing.expect(Color.eql(default.palette.fg, rgb(0xabb2bf)));
    try testing.expect(Color.eql(default.palette.comment, rgb(0x80848d)));
    try testing.expect(Color.eql(default.palette.base16[0xE], rgb(0xc678dd)));
    try testing.expect(Color.eql(default.selection.bg, rgb(0x3e4451)));
    // NvChad's LineNr and Comment: `grey` and `light_grey`.
    try testing.expect(Color.eql(default.gutter.fg, rgb(0x42464e)));
    try testing.expect(Color.eql(default.syntax.comment.fg, rgb(0x80848d)));
}

test "byName is case-insensitive and trims; unknown is null" {
    try testing.expectEqualStrings("onedark", byName("OneDark").?.name);
    try testing.expectEqualStrings("gruvbox", byName("  gruvbox ").?.name);
    try testing.expectEqualStrings("catppuccin-latte", byName("Catppuccin-Latte").?.name);
    try testing.expect(byName("catppuccin-latte").?.kind == .light);
    try testing.expect(byName("no-such-theme") == null);
    try testing.expect(firstOfKind(.light, "onedark").?.kind == .light);
    try testing.expect(!std.mem.eql(u8, firstOfKind(.dark, "aquarium").?.name, "aquarium"));
}

test "a partial palette resolves through the fallback chains" {
    // Only `black` and `white`, one syntax slot: everything else chains
    // down to those two, and the other fifteen slots are onedark's.
    const src: Source = .{
        .name = "bare",
        .kind = .dark,
        .base_30 = .{ .black = 0x101010, .white = 0xf0f0f0, .blue = 0x0000ff, .grey = 0x404040 },
        .base_16 = .{ .base0B = 0x00ff00 },
    };
    const p = resolve(src);
    try testing.expect(Color.eql(p.bg, rgb(0x101010))); // one_bg → black
    try testing.expect(Color.eql(p.bg2, rgb(0x101010))); // one_bg2 → one_bg → black
    try testing.expect(Color.eql(p.statusline, rgb(0x101010))); // statusline_bg → black2 → black
    try testing.expect(Color.eql(p.comment, rgb(0x404040))); // light_grey → grey_fg2 → grey_fg → grey
    try testing.expect(Color.eql(p.grey_fg, rgb(0x404040))); // grey_fg → grey
    try testing.expect(Color.eql(p.red, rgb(0xf0f0f0))); // red → white
    try testing.expect(Color.eql(p.cyan, rgb(0x0000ff))); // cyan → blue
    try testing.expect(Color.eql(p.nord_blue, rgb(0x0000ff)));
    try testing.expect(Color.eql(p.base16[0xB], rgb(0x00ff00)));
    try testing.expect(Color.eql(p.base16[0xE], rgb(0xc678dd))); // onedark's keyword slot
    const t = derive(src);
    try testing.expect(Color.eql(t.syntax.string.fg, rgb(0x00ff00)));
    try testing.expect(Color.eql(t.bg.bg, rgb(0x101010)));
}

test "no bundled palette leans on onedark's base_16: every slot is its own" {
    // The conversion once dropped the slots base46 writes as
    // `M.base_30.<key>` references; 20 palettes then painted onedark's
    // dark syntax — nano-light's selected text sat on #3e4451, 1.01:1.
    @setEvalBranchQuota(100_000);
    inline for (themes.all) |src| {
        inline for (std.meta.fields(themes.Base16)) |f| {
            if (@field(src.base_16, f.name) == null) {
                std.debug.print("theme {s}: base_16.{s} is missing\n", .{ src.name, f.name });
                return error.TestUnexpectedResult;
            }
        }
    }
    // nano-light's keyword is its own `white`, not onedark's purple.
    try testing.expect(Color.eql(byName("nano-light").?.syntax.keyword.fg, rgb(0x37474f)));
    try testing.expect(Color.eql(byName("nano-light").?.selection.bg, rgb(0xebebeb)));
    // catppuccin-latte's upstream typo was folded onto vibrant_green.
    try testing.expect(!Color.eql(byName("catppuccin-latte").?.palette.vibrant_green, byName("catppuccin-latte").?.palette.green));
}

/// WCAG 2 relative luminance of an sRGB colour.
fn luminance(c: Color) f64 {
    var out: f64 = 0;
    const weights = [3]f64{ 0.2126, 0.7152, 0.0722 };
    for (c.rgb, weights) |ch, w| {
        const v = @as(f64, @floatFromInt(ch)) / 255.0;
        const lin = if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        out += w * lin;
    }
    return out;
}

/// WCAG 2 contrast ratio, 1.0 (none) to 21.0.
fn contrast(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "every bundled theme keeps comments, line numbers and selected text readable" {
    // The floors, and why:
    //   comment    2.0:1 — dim by design (NvChad's light_grey), but text
    //              a reader has to be able to read; every bundled
    //              palette clears it (the lowest, material-lighter, is
    //              2.01), and base03 — the old choice — failed it in 66.
    //   selection  2.0:1 — the same text, on the selection ground.
    //   line nr    1.5:1 — NvChad paints LineNr in `grey`, a step dimmer
    //              than comments on purpose: chrome, not content. The
    //              lowest upstream grey is ayu_light's 1.52; the failure
    //              this exists to catch is base03's 1.01, invisible.
    var failures: usize = 0;
    for (&all) |*t| {
        const ground = t.fg.bg;
        const checks = [_]struct { what: []const u8, ratio: f64, floor: f64 }{
            .{ .what = "comment", .ratio = contrast(t.syntax.comment.fg, ground), .floor = 2.0 },
            .{ .what = "selection", .ratio = contrast(t.selection.fg, t.selection.bg), .floor = 2.0 },
            .{ .what = "line number", .ratio = contrast(t.gutter.fg, t.gutter.bg), .floor = 1.5 },
        };
        for (checks) |c| if (c.ratio < c.floor) {
            std.debug.print("theme {s}: {s} contrast {d:.2}:1 is under {d:.1}:1\n", .{ t.name, c.what, c.ratio, c.floor });
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "rgb unpacks channels" {
    const c = rgb(0x61afef);
    try testing.expectEqual(@as(u8, 0x61), c.rgb[0]);
    try testing.expectEqual(@as(u8, 0xaf), c.rgb[1]);
    try testing.expectEqual(@as(u8, 0xef), c.rgb[2]);
}

test "onBg and withFg replace one channel" {
    const s = onBg(default.mode_insert, onedark.statusline_bg);
    try testing.expect(s.bold);
    try testing.expect(Color.eql(s.bg, onedark.statusline_bg));
    try testing.expect(Color.eql(s.fg, default.mode_insert.fg));
    const t = withFg(default.chip, onedark.red);
    try testing.expect(Color.eql(t.fg, onedark.red));
    try testing.expect(Color.eql(t.bg, default.chip.bg));
}
