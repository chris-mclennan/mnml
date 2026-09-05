//! Statusline — the bottom row. Left: the mode chip, the file (with `●`
//! when dirty), a pending chord, the macro-recording chip. Right: the
//! position ` Ln {line}/{total} Col {col} ` (exact — the gate asserts
//! `"Ln 3"`), ` Sel N ` while a selection exists, the caller's extra
//! segments, and the input style.
//!
//! Right-hand segments are dropped from the outside in when the row is
//! too narrow; the position chip goes last. The left side is clipped
//! rather than dropped: the mode and the file name are what the eye
//! looks for.
//!
//! // changed: every chip registers a `.statusline_seg` hit — the mode
//! chip, the file name and the position chip (`seg_mode` / `seg_file` /
//! `seg_position`), and each right-hand segment with the id its
//! builder gave it (`Seg.id`), so the app can route a click on the
//! branch, the diagnostics, the bell, the stress bar… without the
//! component knowing what any of them mean. The `RESTRICTED` chip
//! (`Info.restricted`) says the workspace's exec-bearing config is off.
//! // changed (ipc-tier2): `Info.dyn_left` / `dyn_right` are a host's
//! `statusline-set-segment` chips — each with its own colour and a
//! `.statusline_seg = seg_dyn_base + index` hit. The left lane ends
//! the left cluster; the right lane is the innermost of the right
//! cluster after the selection chip, so it drops before the position.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Style = vaxis.Style;

pub const ModeKind = enum { none, normal, insert, visual, replace, edit };

pub const seg_mode: u32 = 0;
pub const seg_file: u32 = 1;
pub const seg_position: u32 = 2;
/// The input-style chip (`vim` / `standard`), always last.
pub const seg_input_style: u32 = 3;
/// `RESTRICTED` — the workspace's exec-bearing config is stripped.
pub const seg_restricted: u32 = 4;
/// Ids the app's builders use for the right-hand segments; anything
/// at or above `seg_app_base` (and below `seg_dyn_base`) is the app's
/// to define.
pub const seg_app_base: u32 = 16;
/// `seg_dyn_base + i` is `Info.dyn_*[…].index` — the host segment's slot.
pub const seg_dyn_base: u32 = 0x100;

/// A host-set segment (`ipc/effects.zig`'s `Rendered`, resolved).
pub const DynSeg = struct {
    text: []const u8,
    /// The chip's foreground; the muted colour when null.
    fg: ?vaxis.Color = null,
    /// The hit payload minus `seg_dyn_base`.
    index: u32,
};

/// One right-aligned segment: its text, the hit it registers (null
/// registers nothing — a script's segment), and an optional style.
pub const Seg = struct {
    text: []const u8,
    id: ?u32 = null,
    /// Null paints muted on the statusline ground.
    style: ?Style = null,
    /// A low-priority segment sits outside the input-style chip and is
    /// dropped before it when the row is narrow (the indent and
    /// encoding chips, the idle bell).
    low: bool = false,
};

pub const Info = struct {
    /// "NORMAL" / "INSERT" / "REPLACE" / "VISUAL" / "V-LINE" / "V-BLOCK",
    /// or "EDIT" for the standard handler; null hides the chip.
    mode_label: ?[]const u8,
    mode_kind: ModeKind,
    file: ?[]const u8,
    dirty: bool,
    /// 1-based.
    line: u32,
    col: u32,
    total_lines: u32,
    /// "vim" | "standard"
    input_style: []const u8,
    /// Renders ` Sel N `.
    selection_chars: ?usize = null,
    /// A vim pending chord, e.g. `"a` or `2d`.
    pending: ?[]const u8 = null,
    /// ` ● rec @q `
    macro_recording: ?u8 = null,
    /// Extra right-aligned segments, painted before the input style.
    right: []const Seg = &.{},
    /// Paint the `RESTRICTED` chip after the file name.
    restricted: bool = false,
    /// Host segments: the left lane after the pending chord, the
    /// right lane innermost of the right cluster.
    dyn_left: []const DynSeg = &.{},
    dyn_right: []const DynSeg = &.{},
};

fn dynStyle(t: *const Theme, s: DynSeg, bg: vaxis.Color) Style {
    return Theme.onBg(if (s.fg) |c| Style{ .fg = c } else t.muted, bg);
}

pub fn modeStyle(t: *const Theme, kind: ModeKind) Style {
    return switch (kind) {
        .none, .edit => t.mode_edit,
        .normal => t.mode_normal,
        .insert => t.mode_insert,
        .visual => t.mode_visual,
        .replace => t.mode_replace,
    };
}

/// The exact position chip text.
pub fn positionText(ui: Ui, info: Info) []const u8 {
    return ui.fmt(" Ln {d}/{d} Col {d} ", .{ info.line, info.total_lines, info.col });
}

pub fn draw(ui: Ui, area: Rect, info: Info) void {
    const t = ui.theme;
    ui.fill(area, t.statusline);
    if (area.isEmpty()) return;
    const y = area.y;
    const right_edge = area.right();
    const base_bg = t.statusline.bg;

    // ── left ──
    var x = area.x;
    if (info.mode_label) |label| {
        const chip = ui.fmt(" {s} ", .{label});
        const w = ui.putStr(x, y, right_edge - x, chip, modeStyle(t, info.mode_kind));
        ui.hit(Rect.init(x, y, w, 1), .{ .statusline_seg = seg_mode });
        x += w;
    }
    if (info.file) |file| {
        const name = if (info.dirty) ui.fmt(" {s} ● ", .{file}) else ui.fmt(" {s} ", .{file});
        const w = ui.putStr(x, y, right_edge - x, name, t.statusline);
        ui.hit(Rect.init(x, y, w, 1), .{ .statusline_seg = seg_file });
        x += w;
    }
    if (info.macro_recording) |reg| {
        const chip = ui.fmt(" ● rec @{c} ", .{reg});
        x += ui.putStr(x, y, right_edge - x, chip, Theme.onBg(t.error_fg, base_bg));
    }
    if (info.pending) |p| {
        if (p.len > 0) {
            const chip = ui.fmt(" {s} ", .{p});
            x += ui.putStr(x, y, right_edge - x, chip, Theme.onBg(t.warn_fg, base_bg));
        }
    }
    if (info.restricted) {
        var st = Theme.onBg(t.warn_fg, base_bg);
        st.bold = true;
        const w = ui.putStr(x, y, right_edge - x, " RESTRICTED ", st);
        ui.hit(Rect.init(x, y, w, 1), .{ .statusline_seg = seg_restricted });
        x += w;
    }
    for (info.dyn_left) |d| {
        const chip = ui.fmt(" {s} ", .{d.text});
        const w = ui.putStr(x, y, right_edge - x, chip, dynStyle(t, d, base_bg));
        ui.hit(Rect.init(x, y, w, 1), .{ .statusline_seg = seg_dyn_base + d.index });
        x += w;
    }
    const left_end = x;

    // ── right: collect, then paint what fits from the inside out ──
    const Painted = struct { text: []const u8, style: Style, id: ?u32 };
    var segs: std.ArrayListUnmanaged(Painted) = .empty;
    // Innermost (painted furthest left, dropped last) first.
    segs.append(ui.arena, .{ .text = positionText(ui, info), .style = t.statusline, .id = seg_position }) catch return;
    if (info.selection_chars) |n| {
        segs.append(ui.arena, .{ .text = ui.fmt(" Sel {d} ", .{n}), .style = Theme.onBg(t.warn_fg, base_bg), .id = null }) catch return;
    }
    for (info.dyn_right) |d| {
        segs.append(ui.arena, .{ .text = ui.fmt(" {s} ", .{d.text}), .style = dynStyle(t, d, base_bg), .id = seg_dyn_base + d.index }) catch return;
    }
    for (info.right) |r| if (!r.low) {
        segs.append(ui.arena, .{ .text = ui.fmt(" {s} ", .{r.text}), .style = r.style orelse Theme.onBg(t.muted, base_bg), .id = r.id }) catch return;
    };
    segs.append(ui.arena, .{ .text = ui.fmt(" {s} ", .{info.input_style}), .style = Theme.onBg(t.chip, base_bg), .id = seg_input_style }) catch return;
    for (info.right) |r| if (r.low) {
        segs.append(ui.arena, .{ .text = ui.fmt(" {s} ", .{r.text}), .style = r.style orelse Theme.onBg(t.muted, base_bg), .id = r.id }) catch return;
    };

    // Budget from the right edge; a segment that does not fit beside the
    // left side is dropped, and so is everything outside it.
    var avail: u16 = right_edge -| left_end;
    var keep: usize = 0;
    var used: u16 = 0;
    for (segs.items) |s| {
        const w = ui.width(s.text);
        if (used + w > avail) break;
        used += w;
        keep += 1;
    }
    avail = right_edge - used;
    var rx = avail;
    for (segs.items[0..keep]) |s| {
        const w = ui.putStr(rx, y, right_edge - rx, s.text, s.style);
        if (s.id) |id| ui.hit(Rect.init(rx, y, w, 1), .{ .statusline_seg = id });
        rx += w;
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn sample() Info {
    return .{
        .mode_label = "NORMAL",
        .mode_kind = .normal,
        .file = "notes.txt",
        .dirty = false,
        .line = 3,
        .col = 7,
        .total_lines = 12,
        .input_style = "vim",
    };
}

test "the position chip is exact and the mode chip carries its color" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), sample());
    try f.expectRow(0, " NORMAL  notes.txt                       Ln 3/12 Col 7  vim");
    try f.expectContains(" Ln 3/12 Col 7 ");
    try testing.expectEqual(seg_mode, f.hits.at(3, 0).?.statusline_seg);
    try testing.expectEqual(seg_file, f.hits.at(12, 0).?.statusline_seg);
    try testing.expectEqual(seg_position, f.hits.at(45, 0).?.statusline_seg);
    try testing.expectEqual(seg_input_style, f.hits.at(57, 0).?.statusline_seg);
    try testing.expect(f.hits.at(25, 0) == null);
    try testing.expect(f.bgEql(1, 0, f.theme.mode_normal));
    try testing.expect(f.bgEql(9, 0, f.theme.statusline));
    var i = sample();
    i.mode_kind = .insert;
    i.mode_label = "INSERT";
    draw(f.ui(), f.full(), i);
    try testing.expect(f.bgEql(1, 0, f.theme.mode_insert));
    i.mode_kind = .visual;
    i.mode_label = "V-BLOCK";
    draw(f.ui(), f.full(), i);
    try testing.expect(f.bgEql(1, 0, f.theme.mode_visual));
    try f.expectContains("V-BLOCK");
    i.mode_kind = .edit;
    i.mode_label = "EDIT";
    i.input_style = "standard";
    draw(f.ui(), f.full(), i);
    try testing.expect(f.bgEql(1, 0, f.theme.mode_edit));
    try f.expectContains(" standard");
}

test "dirty, selection, macro and pending chips" {
    var f = try Fixture.init(70, 1);
    defer f.deinit();
    var i = sample();
    i.dirty = true;
    i.selection_chars = 12;
    i.macro_recording = 'q';
    i.pending = "2d";
    draw(f.ui(), f.full(), i);
    try f.expectContains(" notes.txt ● ");
    try f.expectContains(" ● rec @q ");
    try f.expectContains(" 2d ");
    try f.expectContains(" Sel 12 ");
    try f.expectContains("Sel ");
    try f.expectLacks("Sel 5 ");
    i.selection_chars = null;
    draw(f.ui(), f.full(), i);
    try f.expectLacks("Sel ");
}

test "no mode chip when the label is null; extra right segments appear before the input style" {
    var f = try Fixture.init(70, 1);
    defer f.deinit();
    var i = sample();
    i.mode_label = null;
    i.mode_kind = .none;
    i.right = &.{ .{ .text = "utf-8", .id = seg_app_base + 1 }, .{ .text = "LF" } };
    draw(f.ui(), f.full(), i);
    try f.expectRow(0, " notes.txt                              Ln 3/12 Col 7  utf-8  LF  vim");
    // The segment with an id is a hit; the one without registers nothing.
    try testing.expectEqual(seg_app_base + 1, f.hits.at(56, 0).?.statusline_seg);
    try testing.expect(f.hits.at(63, 0) == null);
    // A low-priority segment sits outside the input style and drops first.
    i.right = &.{ .{ .text = "utf-8", .low = true }, .{ .text = "LF" } };
    draw(f.ui(), f.full(), i);
    try f.expectRow(0, " notes.txt                              Ln 3/12 Col 7  LF  vim  utf-8");
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), i);
    try g.expectRow(0, " notes.txt       Ln 3/12 Col 7  LF  vim");
}

test "the RESTRICTED chip follows the file name and is a hit" {
    var f = try Fixture.init(70, 1);
    defer f.deinit();
    var i = sample();
    i.restricted = true;
    draw(f.ui(), f.full(), i);
    try f.expectContains(" notes.txt  RESTRICTED ");
    try testing.expectEqual(seg_restricted, f.hits.at(22, 0).?.statusline_seg);
    try testing.expect(f.fgEql(22, 0, f.theme.warn_fg));
    i.restricted = false;
    draw(f.ui(), f.full(), i);
    try f.expectLacks("RESTRICTED");
}

test "host segments: the left lane ends the left cluster, the right lane sits inside, each with its colour and hit" {
    var f = try Fixture.init(80, 1);
    defer f.deinit();
    var i = sample();
    i.right = &.{.{ .text = "utf-8" }};
    i.dyn_left = &.{.{ .text = "JIRA 3", .fg = f.theme.palette.cyan, .index = 4 }};
    i.dyn_right = &.{ .{ .text = "CI ok", .index = 0 }, .{ .text = "q", .index = 9 } };
    draw(f.ui(), f.full(), i);
    // 27 cells of left cluster, 37 of right: the position chip starts at 43.
    try f.expectRow(0, " NORMAL  notes.txt  JIRA 3                  Ln 3/12 Col 7  CI ok  q  utf-8  vim");
    try testing.expectEqual(seg_dyn_base + 4, f.hits.at(21, 0).?.statusline_seg);
    try testing.expectEqual(seg_dyn_base + 0, f.hits.at(63, 0).?.statusline_seg);
    try testing.expectEqual(seg_dyn_base + 9, f.hits.at(66, 0).?.statusline_seg);
    try testing.expectEqual(seg_position, f.hits.at(50, 0).?.statusline_seg);
    try testing.expect(f.fgEql(21, 0, Style{ .fg = f.theme.palette.cyan }));
    try testing.expect(f.fgEql(63, 0, f.theme.muted));
    // Narrow: the right lane drops before the position chip does.
    var g = try Fixture.init(45, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), i);
    try g.expectRow(0, " NORMAL  notes.txt  JIRA 3     Ln 3/12 Col 7");
}

test "right segments drop from the outside in when the row is narrow" {
    var f = try Fixture.init(34, 1);
    defer f.deinit();
    var i = sample();
    i.right = &.{.{ .text = "utf-8" }};
    draw(f.ui(), f.full(), i);
    // 34 cells: " NORMAL " (8) + " notes.txt " (11) = 19; the position
    // chip (15) fits exactly, nothing else does.
    try f.expectRow(0, " NORMAL  notes.txt  Ln 3/12 Col 7");
    try f.expectLacks("vim");
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), i);
    try g.expectRow(0, " NORMAL  not");
    draw(g.ui(), Rect.empty, i);
}
