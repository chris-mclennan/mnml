//! The design-language conformance suite — one call a pane's own test
//! file makes, which mounts the pane at the family's two sizes (120×40
//! and 80×24), each with and without `--ascii`, and asserts every rule
//! the family checks individually. A rule added here reaches every pane
//! that calls it at its next test run — the in-repo integrations, and
//! every external one.
//!
//! The pane hands over a `Probe`: a type that mounts it on its own
//! fixture and says where its furniture is.
//!
//! ```zig
//! const Probe = struct {
//!     pub const Target = hit.Target;
//!     // … the pane's own fixture state …
//!     pub fn init(gpa: Allocator, size: sdk.testing.Size) !Probe { … }
//!     pub fn deinit(p: *Probe) void { … }
//!     pub fn paint(p: *Probe, arena: Allocator) !sdk.testing.Painted(Target) { … }
//! };
//! test "the design language" { try sdk.testing.conformance(Probe); }
//! ```
//!
//! The rules, each a named error printed with the size it failed at:
//!
//!   title         the caps title is painted at its cell, in `label()`
//!   ladder        the header ladder ends in refresh then `?`, on the
//!                 chip ground (a pane that declares a ladder)
//!   gutter        the app-colour stripe runs its full height, in the
//!                 gutter's ink, the `|` twin under `--ascii`
//!   scrollbar     a list whose bar column shows any of the bar shows a
//!                 thumb over a track; and a list the probe declares
//!                 must outrun its body at one of the sizes, so the bar
//!                 is exercised at all
//!   statusline    every segment obeys the figure rule
//!   ascii twin    under `--ascii` no cell holds a Private Use Area
//!                 codepoint — every Nerd Font glyph has its twin
//!   hits          every hit lies on the frame: nothing clickable off
//!                 the screen
//!
//! A field the pane leaves null (no ladder, no list, no segments) is a
//! rule it says does not apply; `title` and `gutter` apply to every pane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("frame.zig");
const pane = @import("pane.zig");
const expect = pane.expect;
const chrome = pane.chrome;

pub const Frame = frame_mod.Frame;
pub const Theme = pane.Theme;
pub const Rect = pane.Rect;

/// One mount: the frame's size and whether the host said `--ascii`.
pub const Size = struct {
    cols: u16,
    rows: u16,
    ascii: bool = false,
};

/// The mounts every pane is held to.
pub const sizes = [_]Size{
    .{ .cols = 120, .rows = 40 },
    .{ .cols = 120, .rows = 40, .ascii = true },
    .{ .cols = 80, .rows = 24 },
    .{ .cols = 80, .rows = 24, .ascii = true },
};

/// What a pane painted, and where its furniture is.
pub fn Painted(comptime Target: type) type {
    return struct {
        frame: *const Frame,
        hits: *const pane.HitMap(Target),
        theme: Theme,
        /// The caps title: its first cell and its words.
        title: struct { x: u16 = 1, y: u16 = 0, text: []const u8 },
        /// The row the header ladder (refresh, `?`) sits on; null for a
        /// pane that has none.
        ladder_y: ?u16 = null,
        /// The gutter stripe: its column, first row and height.
        gutter: struct { x: u16 = 0, y0: u16 = 0, h: u16 },
        /// The list body and the column its scrollbar takes; null for a
        /// pane with no scrolling list.
        list: ?struct { bar_x: u16, y0: u16, h: u16 } = null,
        /// The statusline segments' text as this fixture would publish
        /// them (under this mount's `ascii`).
        statusline: []const []const u8 = &.{},
    };
}

pub const Error = expect.Error || error{
    TitleMissing,
    AsciiTwinMissing,
    HitOffScreen,
    ListNeverOutruns,
};

/// Mount `Probe` at every size in `sizes` and hold it to every rule.
pub fn conformance(comptime Probe: type) !void {
    const gpa = std.testing.allocator;
    var saw_list = false;
    var saw_bar = false;
    for (sizes) |size| {
        var probe = try Probe.init(gpa, size);
        defer probe.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const got = try probe.paint(arena_state.allocator());
        if (got.list != null) saw_list = true;
        const bar = check(Probe.Target, got, size) catch |err| {
            std.debug.print("conformance: {s} at {d}x{d}{s}\n", .{ @errorName(err), size.cols, size.rows, if (size.ascii) " --ascii" else "" });
            return err;
        };
        saw_bar = saw_bar or bar;
    }
    if (saw_list and !saw_bar) {
        std.debug.print("conformance: ListNeverOutruns — the probe declares a list, but at none of the sizes did it outrun its body; give the fixture more rows\n", .{});
        return Error.ListNeverOutruns;
    }
}

/// Every rule, on one painted frame. True when the list's bar showed.
pub fn check(comptime Target: type, got: Painted(Target), size: Size) Error!bool {
    const f = got.frame;
    const th = got.theme;
    // title
    if (!rowHasText(f, got.title.y, got.title.x, got.title.text)) return Error.TitleMissing;
    try expect.capsTitleInk(f, th, got.title.x, got.title.y, got.title.text);
    // ladder
    if (got.ladder_y) |y| try expect.headerLadderTail(f, th, y, !size.ascii, size.ascii);
    // gutter
    try expect.gutterFullHeight(f, th, got.gutter.x, got.gutter.y0, got.gutter.h, size.ascii);
    // scrollbar
    var bar = false;
    if (got.list) |l| {
        var y = l.y0;
        while (y < l.y0 + l.h and y < f.rows) : (y += 1) {
            const sym = f.slots[@as(usize, y) * f.cols + l.bar_x].symbol();
            if (std.mem.eql(u8, sym, chrome.scroll_track) or std.mem.eql(u8, sym, chrome.scroll_thumb)) bar = true;
        }
        if (bar) try expect.listScrollbar(f, l.bar_x, l.y0, l.h);
    }
    // statusline
    for (got.statusline) |s| try expect.statuslineFigure(s);
    // ascii twin
    if (size.ascii) for (f.slots) |slot| {
        var it = std.unicode.Utf8View.initUnchecked(slot.symbol()).iterator();
        while (it.nextCodepoint()) |cp| if (privateUse(cp)) return Error.AsciiTwinMissing;
    };
    // hits
    for (got.hits.items.items) |e| {
        if (e.rect.right() > f.cols or e.rect.bottom() > f.rows) return Error.HitOffScreen;
    }
    return bar;
}

/// A Nerd Font glyph lives in the Private Use Areas.
pub fn privateUse(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000;
}

fn rowHasText(f: *const Frame, y: u16, x0: u16, text: []const u8) bool {
    if (y >= f.rows) return false;
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |g| : (x += 1) {
        if (x >= f.cols) return false;
        if (!std.mem.eql(u8, f.slots[@as(usize, y) * f.cols + x].symbol(), g)) return false;
    }
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// A pane made of nothing but the toolkit: title, ladder, gutter, a
/// list of 30 rows with its bar, a hint row, a segment.
const ToyProbe = struct {
    pub const Target = union(enum) { row: u16, refresh, help, quit };
    f: Frame,
    hits: pane.HitMap(Target) = .{},
    size: Size,
    /// A break to plant, for the tests that prove a rule bites.
    fault: enum { none, accent_title, no_gutter, nerd_in_ascii, hit_off, no_bar, two_figures } = .none,
    var planted: @FieldType(ToyProbe, "fault") = .none;

    pub fn init(gpa: Allocator, size: Size) !ToyProbe {
        return .{ .f = try Frame.init(gpa, size.cols, size.rows), .size = size, .fault = planted };
    }
    pub fn deinit(p: *ToyProbe) void {
        p.hits.deinit(testing.allocator);
        p.f.deinit();
    }
    pub fn paint(p: *ToyProbe, arena: Allocator) !Painted(Target) {
        const th = Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } }, .chip_bg = .{ .rgb = .{ 7, 8, 9 } } });
        var c: pane.Painter(Target) = .{ .f = &p.f, .gpa = testing.allocator, .arena = arena, .hits = &p.hits, .th = th, .ui = .{ .ascii = p.size.ascii } };
        const rows = p.f.rows;
        if (p.fault != .no_gutter) c.gutter(.{ .x = 0, .y = 0, .w = 1, .h = rows - 1 }, 2);
        const x = if (p.fault == .accent_title) blk: {
            _ = p.f.text(1, 0, 10, "TOY", th.accentText());
            break :blk @as(u16, 4);
        } else c.capsTitle(1, 0, "TOY", "  (30)");
        _ = try c.rightChips(0, x, &.{
            .{ .text = chrome.help_chip_text, .target = .help },
            .{ .text = c.refreshChipText(), .target = .refresh },
        });
        const body: u16 = rows - 2;
        const list_rows: usize = 30;
        var i: u16 = 0;
        while (i < body and i < list_rows) : (i += 1) {
            try c.rowGround(.{ .x = 0, .y = 1 + i, .w = p.f.cols - 1, .h = 1 }, i == 1, .{ .row = i });
            _ = c.put(2, 1 + i, 20, c.fmt("row {d}", .{i}), th.text());
        }
        if (p.fault != .no_bar and list_rows > body) try c.scrollbar(.{ .x = p.f.cols - 1, .y = 1, .w = 1, .h = body }, list_rows, 0, body, null);
        if (p.fault == .nerd_in_ascii) _ = p.f.text(5, 1, 1, "\u{f0a7}", th.text());
        try c.hintRow(rows - 1, "", &.{.{ .key = "q", .title = "quit", .target = .quit }});
        if (p.fault == .hit_off) try p.hits.add(testing.allocator, .{ .x = p.f.cols - 2, .y = 0, .w = 5, .h = 1 }, .quit);
        return .{
            .frame = &p.f,
            .hits = &p.hits,
            .theme = th,
            .title = .{ .text = "TOY" },
            .ladder_y = 0,
            .gutter = .{ .h = rows - 1 },
            .list = .{ .bar_x = p.f.cols - 1, .y0 = 1, .h = body },
            .statusline = if (p.fault == .two_figures) &.{"T 3 4"} else &.{"T 30"},
        };
    }
};

test "a pane made of the toolkit passes every rule at every size" {
    ToyProbe.planted = .none;
    try conformance(ToyProbe);
}

test "each rule bites: a planted fault fails the suite with its own error" {
    const cases = .{
        .{ .accent_title, Error.TitleInk },
        .{ .no_gutter, Error.GutterBroken },
        .{ .nerd_in_ascii, Error.AsciiTwinMissing },
        .{ .hit_off, Error.HitOffScreen },
        .{ .no_bar, Error.ListNeverOutruns },
        .{ .two_figures, Error.FigureTwo },
    };
    inline for (cases) |c| {
        ToyProbe.planted = c[0];
        defer ToyProbe.planted = .none;
        try testing.expectError(c[1], conformance(ToyProbe));
    }
}
