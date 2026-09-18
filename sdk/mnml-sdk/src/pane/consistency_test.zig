//! The anti-drift test. Two integrations painted the same panel two
//! ways once; the toolkit exists so they cannot again. This file paints
//! the shared elements from BOTH panes' target vocabularies over the
//! same inputs and asserts the cells come out identical — symbol for
//! symbol, colour for colour, modifier for modifier.
//!
//! It lives in the SDK rather than in either integration on purpose:
//! neither pane owns the answer, and a change that moves one of them
//! has to move this file too, which is where somebody notices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("../frame.zig");
const chrome = @import("chrome.zig");
const action_mod = @import("action.zig");
const build_mod = @import("build.zig");
const merge_mod = @import("merge.zig");
const hit = @import("hit.zig");
const theme_mod = @import("theme.zig");

const Frame = frame_mod.Frame;
const Theme = theme_mod.Theme;
const Rect = hit.Rect;
const testing = std.testing;

/// A tracker pane's vocabulary — the Jira pane's shape.
const TrackerTarget = union(enum) {
    row: u32,
    chip: u8,
    tab: u8,
    filter,
    show_more: u32,
    detail,
    detail_close,
    detail_bar,
    hint: u8,
    build: u32,
    action: struct { row: u32, button: u8 },
    merge: u32,
    confirm_ok,
    confirm_cancel,
    confirm_body,
};

/// A forge pane's vocabulary — the Bitbucket pane's shape. A different
/// union, deliberately: the toolkit is generic over it, and the cells
/// must not depend on which one is passed.
const ForgeTarget = union(enum) {
    tab: usize,
    chip: struct { kind: u8 },
    row: usize,
    hint: struct { action: u8 },
    menu_item: usize,
    detail,
    detail_close,
    detail_bar,
    filter,
    show_more: usize,
    sheet,
    build: struct { repo: usize, run: usize },
    action: struct { key: usize, which: u8 },
    merge: struct { repo: usize, idx: usize },
    confirm_ok,
    confirm_cancel,
    confirm_body,
};

fn Rig(comptime Target: type) type {
    return struct {
        const Self = @This();

        f: Frame,
        hits: hit.Map(Target) = .{},
        arena: std.heap.ArenaAllocator,

        fn init(w: u16, h: u16) !Self {
            return .{
                .f = try Frame.init(testing.allocator, w, h),
                .arena = std.heap.ArenaAllocator.init(testing.allocator),
            };
        }

        fn deinit(r: *Self) void {
            r.f.deinit();
            r.hits.deinit(testing.allocator);
            r.arena.deinit();
        }

        fn painter(r: *Self, th: Theme) chrome.Painter(Target) {
            return .{
                .f = &r.f,
                .gpa = testing.allocator,
                .arena = r.arena.allocator(),
                .hits = &r.hits,
                .th = th,
                .ui = .{},
            };
        }
    };
}

/// The theme both sides paint with — every role a distinct colour, so a
/// role swapped for another shows up as a differing cell rather than
/// hiding behind a shared fallback.
fn demoTheme() Theme {
    return Theme.fromHelloBranded(.{
        .fg = .{ .rgb = .{ 200, 200, 200 } },
        .bg = .{ .rgb = .{ 10, 10, 10 } },
        .muted = .{ .rgb = .{ 90, 90, 90 } },
        .accent = .{ .rgb = .{ 97, 175, 239 } },
        .border = .{ .rgb = .{ 60, 60, 60 } },
        .cursor_line = .{ .rgb = .{ 30, 30, 30 } },
        .chip_fg = .{ .rgb = .{ 220, 220, 220 } },
        .chip_bg = .{ .rgb = .{ 45, 45, 45 } },
        .chip_active_fg = .{ .rgb = .{ 5, 5, 5 } },
        .chip_active_bg = .{ .rgb = .{ 152, 195, 121 } },
        .red = .{ .rgb = .{ 224, 108, 117 } },
        .green = .{ .rgb = .{ 152, 195, 121 } },
        .yellow = .{ .rgb = .{ 229, 192, 123 } },
        .orange = .{ .rgb = .{ 209, 154, 102 } },
        .blue = .{ .rgb = .{ 97, 175, 239 } },
        .cyan = .{ .rgb = .{ 86, 182, 194 } },
        .purple = .{ .rgb = .{ 198, 120, 221 } },
        .comment = .{ .rgb = .{ 92, 99, 112 } },
    }, "blue");
}

const cols: u16 = 60;
const rows: u16 = 24;

/// The clock every build line's age is measured against, so the two
/// sides say the same thing rather than the same *shape*.
const build_now: i64 = 1_789_500_000;

const demo_run: build_mod.Run = .{
    .state = "SUCCESSFUL",
    .branch = "chris/fix-login",
    .created_on = "2026-09-15T15:20:00+00:00",
    .number = 412,
};

/// Ready, and blocked on the first condition a reader should fix. Both
/// are painted, because "dim" only means something next to the one
/// that is not.
const ready_pr: merge_mod.Readiness = .{
    .approvals = 2,
    .required = 2,
    .conflicts = false,
    .build_green = true,
    .checked = true,
};
const blocked_pr: merge_mod.Readiness = .{
    .approvals = 1,
    .required = 2,
    .conflicts = false,
    .build_green = true,
    .checked = true,
};

/// A ready `[ Merge ]` takes its hit; a blocked one paints and does
/// not, so a stray click cannot merge anything.
fn paintMergeRow(comptime Target: type, p: *chrome.Painter(Target), y: u16, ready_target: Target, blocked_target: Target) void {
    var buf: [16]u8 = undefined;
    const cap = merge_mod.caption(&buf);
    const w = chrome.width(cap);
    _ = p.put(1, y, w, cap, merge_mod.styleOf(p.th, ready_pr));
    if (merge_mod.isPressable(ready_pr)) p.mark(.{ .x = 1, .y = y, .w = w, .h = 1 }, ready_target) catch {};
    _ = p.put(1 + w + 1, y, w, cap, merge_mod.styleOf(p.th, blocked_pr));
    if (merge_mod.isPressable(blocked_pr)) p.mark(.{ .x = 1 + w + 1, .y = y, .w = w, .h = 1 }, blocked_target) catch {};
    // The reason the dim one is dim, where a hover puts it.
    var rbuf: [160]u8 = undefined;
    _ = p.putFit(1 + 2 * (w + 1), y, cols -| (1 + 2 * (w + 1)), blocked_pr.hoverText(&rbuf), p.th.mutedText());
}

const demo_confirm: merge_mod.Confirm = .{
    .title = "Fix the login redirect",
    .source = "chris/fix-login",
    .target = "main",
    .strategy = .squash,
    .url = "https://bitbucket.org/acme/api/pull-requests/1234",
};

fn paintConfirm(comptime Target: type, p: *chrome.Painter(Target), ok: Target, cancel: Target, body: Target) !void {
    var hbuf: [96]u8 = undefined;
    var bbuf: [96]u8 = undefined;
    var sbuf: [96]u8 = undefined;
    try p.confirmBox(
        .{ .x = 2, .y = 16, .w = cols - 4, .h = 7 },
        demo_confirm.heading(&hbuf),
        &.{ demo_confirm.title, demo_confirm.branchLine(&bbuf), demo_confirm.strategyLine(&sbuf) },
        " Merge ",
        ok,
        " Cancel ",
        cancel,
        body,
    );
}

/// The five states an action button wears, painted side by side so a
/// change to any one of them shows up as a differing cell rather than
/// hiding behind the four that did not move.
const action_states = [_]action_mod.State{ .idle, .running, .waiting, .view, .failed };

fn paintActionRow(comptime Target: type, p: *chrome.Painter(Target), y: u16, targets: [5]Target) void {
    var x: u16 = 1;
    for (action_states, targets) |st, target| {
        var buf: [32]u8 = undefined;
        const cap = action_mod.caption(&buf, st, "Merge", 2, false);
        const w = chrome.width(cap);
        _ = p.put(x, y, w, cap, action_mod.styleOf(p.th, st));
        p.mark(.{ .x = x, .y = y, .w = w, .h = 1 }, target) catch {};
        x += w + 1;
    }
}

/// A row's words, in the three foreground roles a pane's rows are
/// painted in — none of which names a background of its own. A ground
/// the words punch a hole back through is the bug this exists to catch,
/// and it is invisible to a comparison that paints rows empty.
fn paintRowWords(comptime Target: type, p: *chrome.Painter(Target), y: u16) void {
    _ = p.put(2, y, 10, "ENG-1234", p.th.bright());
    _ = p.put(12, y, 20, "Fix the login redirect", p.th.text());
    _ = p.put(40, y, 12, "2026-09-15", p.th.dimText());
}

/// Every shared element, once, at fixed coordinates.
fn paintTracker(r: *Rig(TrackerTarget)) !void {
    var p = r.painter(demoTheme());
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = rows - 1 }, 5);
    const x = p.capsTitle(1, 0, "PANE", "  (2 of 9)");
    _ = try p.rightChips(0, x, &.{
        .{ .text = " ? ", .target = .{ .chip = 0 } },
        .{ .text = p.refreshChipText(), .target = .{ .chip = 1 } },
    });
    _ = try p.tabStrip(1, 1, &.{
        .{ .label = " 1 First (3) ", .target = .{ .tab = 0 }, .active = true },
        .{ .label = " 2 Second (4) ", .target = .{ .tab = 1 } },
    });
    try p.filterPill(.{ .x = 1, .y = 3, .w = cols - 2, .h = 1 }, "vouch", 5, true, .filter);
    try p.rowGround(.{ .x = 0, .y = 4, .w = cols, .h = 1 }, false, .{ .row = 0 });
    paintRowWords(TrackerTarget, &p, 4);
    try p.rowGround(.{ .x = 0, .y = 5, .w = cols, .h = 2 }, true, .{ .row = 1 });
    paintRowWords(TrackerTarget, &p, 5);
    paintRowWords(TrackerTarget, &p, 6);
    try p.showMoreRow(.{ .x = 0, .y = 7, .w = cols, .h = 1 }, 12, 7, .{ .show_more = 1 });
    try p.detailPanel(.{ .x = 40, .y = 8, .w = 20, .h = 3 }, .detail, .detail_close);
    try p.scrollbar(.{ .x = 59, .y = 9, .w = 1, .h = 2 }, 30, 6, 2, .detail_bar);
    try p.buildRow(.{ .x = 0, .y = 11, .w = cols, .h = 1 }, 6, demo_run, build_now, .{ .build = 0 });
    p.buildNote(.{ .x = 0, .y = 12, .w = cols, .h = 1 }, 6, "no build ran on abc1234", false);
    paintActionRow(TrackerTarget, &p, 13, .{
        .{ .action = .{ .row = 0, .button = 0 } },
        .{ .action = .{ .row = 0, .button = 1 } },
        .{ .action = .{ .row = 0, .button = 2 } },
        .{ .action = .{ .row = 0, .button = 3 } },
        .{ .action = .{ .row = 0, .button = 4 } },
    });
    paintMergeRow(TrackerTarget, &p, 14, .{ .merge = 0 }, .{ .merge = 1 });
    try paintConfirm(TrackerTarget, &p, .confirm_ok, .confirm_cancel, .confirm_body);
    try p.hintRow(rows - 1, "ENG-2", &.{
        .{ .key = "d", .title = "detail", .target = .{ .hint = 0 } },
        .{ .key = "q", .title = "quit", .target = .{ .hint = 1 } },
    });
}

fn paintForge(r: *Rig(ForgeTarget)) !void {
    var p = r.painter(demoTheme());
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = rows - 1 }, 5);
    const x = p.capsTitle(1, 0, "PANE", "  (2 of 9)");
    _ = try p.rightChips(0, x, &.{
        .{ .text = " ? ", .target = .{ .chip = .{ .kind = 0 } } },
        .{ .text = p.refreshChipText(), .target = .{ .chip = .{ .kind = 1 } } },
    });
    _ = try p.tabStrip(1, 1, &.{
        .{ .label = " 1 First (3) ", .target = .{ .tab = 0 }, .active = true },
        .{ .label = " 2 Second (4) ", .target = .{ .tab = 1 } },
    });
    try p.filterPill(.{ .x = 1, .y = 3, .w = cols - 2, .h = 1 }, "vouch", 5, true, .filter);
    try p.rowGround(.{ .x = 0, .y = 4, .w = cols, .h = 1 }, false, .{ .row = 0 });
    paintRowWords(ForgeTarget, &p, 4);
    try p.rowGround(.{ .x = 0, .y = 5, .w = cols, .h = 2 }, true, .{ .row = 1 });
    paintRowWords(ForgeTarget, &p, 5);
    paintRowWords(ForgeTarget, &p, 6);
    try p.showMoreRow(.{ .x = 0, .y = 7, .w = cols, .h = 1 }, 12, 7, .{ .show_more = 1 });
    try p.detailPanel(.{ .x = 40, .y = 8, .w = 20, .h = 3 }, .detail, .detail_close);
    try p.scrollbar(.{ .x = 59, .y = 9, .w = 1, .h = 2 }, 30, 6, 2, .detail_bar);
    try p.buildRow(.{ .x = 0, .y = 11, .w = cols, .h = 1 }, 6, demo_run, build_now, .{ .build = .{ .repo = 0, .run = 0 } });
    p.buildNote(.{ .x = 0, .y = 12, .w = cols, .h = 1 }, 6, "no build ran on abc1234", false);
    paintActionRow(ForgeTarget, &p, 13, .{
        .{ .action = .{ .key = 0, .which = 0 } },
        .{ .action = .{ .key = 0, .which = 1 } },
        .{ .action = .{ .key = 0, .which = 2 } },
        .{ .action = .{ .key = 0, .which = 3 } },
        .{ .action = .{ .key = 0, .which = 4 } },
    });
    paintMergeRow(ForgeTarget, &p, 14, .{ .merge = .{ .repo = 0, .idx = 0 } }, .{ .merge = .{ .repo = 0, .idx = 1 } });
    try paintConfirm(ForgeTarget, &p, .confirm_ok, .confirm_cancel, .confirm_body);
    try p.hintRow(rows - 1, "ENG-2", &.{
        .{ .key = "d", .title = "detail", .target = .{ .hint = .{ .action = 0 } } },
        .{ .key = "q", .title = "quit", .target = .{ .hint = .{ .action = 1 } } },
    });
}

test "the shared chrome paints identically from both panes' vocabularies" {
    var tracker = try Rig(TrackerTarget).init(cols, rows);
    defer tracker.deinit();
    var forge = try Rig(ForgeTarget).init(cols, rows);
    defer forge.deinit();
    try paintTracker(&tracker);
    try paintForge(&forge);

    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const i = @as(usize, y) * cols + x;
            const a = &tracker.f.slots[i];
            const b = &forge.f.slots[i];
            if (!std.mem.eql(u8, a.symbol(), b.symbol()) or
                !std.meta.eql(a.style.fg, b.style.fg) or
                !std.meta.eql(a.style.bg, b.style.bg) or
                a.style.mods.bits() != b.style.mods.bits())
            {
                std.debug.print(
                    "the two panes differ at {d},{d}: `{s}` {any}/{any}/{d} vs `{s}` {any}/{any}/{d}\n",
                    .{ x, y, a.symbol(), a.style.fg, a.style.bg, a.style.mods.bits(), b.symbol(), b.style.fg, b.style.bg, b.style.mods.bits() },
                );
                return error.ChromeDrifted;
            }
        }
    }
}

test "the elements the panes share are actually on the screen, so the comparison has something to compare" {
    var r = try Rig(TrackerTarget).init(cols, rows);
    defer r.deinit();
    try paintTracker(&r);
    const arena = r.arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const s = r.f.slots[@as(usize, y) * cols + x].symbol();
            if (s.len > 0) try text.appendSlice(arena, s);
        }
        try text.append(arena, '\n');
    }
    const scr = text.items;
    try testing.expect(std.mem.indexOf(u8, scr, "PANE") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "(2 of 9)") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "1 First (3)") != null);
    // The default indicator: the block under the tab that is on. The
    // heavy rule belongs to `rule`, which is not the default, so it is
    // nowhere on this screen. (The light one is: box frames use it.)
    try testing.expect(std.mem.indexOf(u8, scr, chrome.tab_block) != null);
    try testing.expect(std.mem.indexOf(u8, scr, chrome.tab_rule_active) == null);
    try testing.expect(std.mem.indexOf(u8, scr, "vouch") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "Show more (7)") != null);
    try testing.expect(std.mem.indexOf(u8, scr, chrome.close_glyph) != null);
    try testing.expect(std.mem.indexOf(u8, scr, chrome.gutter_glyph) != null);
    try testing.expect(std.mem.indexOf(u8, scr, "q quit") != null);
    // The build line: state, branch, age, number, in that order.
    try testing.expect(std.mem.indexOf(u8, scr, "\u{2713} SUCCESSFUL \u{b7} chris/fix-login \u{b7} 4h \u{b7} #412") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "no build ran on abc1234") != null);
    // Every action state, including the two the host's word supplies.
    try testing.expect(std.mem.indexOf(u8, scr, "[ Merge ]") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "[ \u{2819} ]") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "[ \u{23f8} ]") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "[ view ]") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "[ \u{2717} ]") != null);
    // The Merge button, and the reason the dim one is dim.
    try testing.expect(std.mem.indexOf(u8, scr, "[ Merge ]") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "Merge: 1 of 2 approvals") != null);
    // The confirm names the pull request rather than asking "are you
    // sure?" about nothing in particular.
    try testing.expect(std.mem.indexOf(u8, scr, "Merge acme/api/pull-requests/1234") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "chris/fix-login \u{2192} main") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "strategy: squash") != null);
    try testing.expect(std.mem.indexOf(u8, scr, "Cancel") != null);
    // And every one of them answers a click.
    try testing.expect(r.hits.rectOf(.filter) != null);
    try testing.expect(r.hits.rectOf(.{ .show_more = 1 }) != null);
    try testing.expect(r.hits.rectOf(.detail_close) != null);
    try testing.expect(r.hits.rectOf(.detail_bar) != null);
    try testing.expect(r.hits.rectOf(.{ .hint = 1 }) != null);
    try testing.expect(r.hits.rectOf(.{ .tab = 1 }) != null);
    try testing.expect(r.hits.rectOf(.{ .build = 0 }) != null);
    try testing.expect(r.hits.rectOf(.{ .action = .{ .row = 0, .button = 2 } }) != null);
    try testing.expect(r.hits.rectOf(.confirm_ok) != null);
    try testing.expect(r.hits.rectOf(.confirm_cancel) != null);
    // The ready Merge answers a click; the blocked one is not there at
    // all, which is what keeps a stray click from merging anything.
    try testing.expect(r.hits.rectOf(.{ .merge = 0 }) != null);
    try testing.expect(r.hits.rectOf(.{ .merge = 1 }) == null);
}

test "the cursor row carries the cursor-line ground edge to edge, in both panes, under its own words" {
    var tracker = try Rig(TrackerTarget).init(cols, rows);
    defer tracker.deinit();
    var forge = try Rig(ForgeTarget).init(cols, rows);
    defer forge.deinit();
    try paintTracker(&tracker);
    try paintForge(&forge);
    const cursor_line = demoTheme().cursor_line;
    // Row 4 is a row at rest, rows 5 and 6 are the two lines of the row
    // under the cursor; all three carry the same words.
    for ([_]*Frame{ &tracker.f, &forge.f }, [_][]const u8{ "tracker", "forge" }) |f, who| {
        for ([_]u16{ 5, 6 }) |y| {
            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                const got = f.slots[@as(usize, y) * cols + x].style.bg;
                if (got == null or !std.meta.eql(got.?, cursor_line)) {
                    std.debug.print("{s}: the cursor row breaks at {d},{d} — `{s}` on {any}, wanted {any}\n", .{ who, x, y, f.slots[@as(usize, y) * cols + x].symbol(), got, cursor_line });
                    return error.CursorRowNotFilled;
                }
            }
        }
        // …and a row at rest is not banded anywhere along it, or the
        // cursor would have nothing to stand out from.
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const got = f.slots[@as(usize, 4) * cols + x].style.bg;
            if (got != null and std.meta.eql(got.?, cursor_line)) {
                std.debug.print("{s}: a row at rest is banded at {d},4\n", .{ who, x });
                return error.RestingRowFilled;
            }
        }
    }
}
