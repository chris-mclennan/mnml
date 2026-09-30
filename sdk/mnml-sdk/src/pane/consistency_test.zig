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
const budget_mod = @import("../budget.zig");

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

/// The theme every side paints with — every role a distinct colour, so
/// a role swapped for another shows up as a differing cell rather than
/// hiding behind a shared fallback. `chip_color` is the family's own
/// manifest chip colour, which is what `brand` resolves from.
fn themeOf(chip_color: []const u8) Theme {
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
    }, chip_color);
}

fn demoTheme() Theme {
    return themeOf("blue");
}

/// The five families every official integration ships, each with the
/// chip colour its manifest names and the target vocabulary its pane
/// paints through. The toolkit is generic over the vocabulary and
/// takes the brand off `hello`, so the chrome they share has to come
/// out identical from all five — and the parts that are SUPPOSED to
/// differ are only the ones that carry the brand.
const Vocab = enum { tracker, forge };
const Family = struct { name: []const u8, chip_color: []const u8, vocab: Vocab };
const families = [_]Family{
    .{ .name = "Jira Work", .chip_color = "blue", .vocab = .tracker },
    .{ .name = "Jira Fix Versions", .chip_color = "green", .vocab = .tracker },
    .{ .name = "Jira Boards", .chip_color = "magenta", .vocab = .tracker },
    .{ .name = "Bitbucket PRs", .chip_color = "blue", .vocab = .forge },
    .{ .name = "Bitbucket Pipelines", .chip_color = "green", .vocab = .forge },
};

const cols: u16 = 60;
const rows: u16 = 24;

/// The clock every build line's age is measured against, so the two
/// sides say the same thing rather than the same *shape*.
const build_now: i64 = 1_789_500_000;

const demo_run: build_mod.Run = .{
    .state = "SUCCESSFUL",
    .branch = "bug/fix-login",
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
    _ = p.actionChip(1, y, w, cap, merge_mod.chipOf(p.th, ready_pr));
    if (merge_mod.isPressable(ready_pr)) p.mark(.{ .x = 1, .y = y, .w = w, .h = 1 }, ready_target) catch {};
    _ = p.actionChip(1 + w + 1, y, w, cap, merge_mod.chipOf(p.th, blocked_pr));
    if (merge_mod.isPressable(blocked_pr)) p.mark(.{ .x = 1 + w + 1, .y = y, .w = w, .h = 1 }, blocked_target) catch {};
    // The reason the dim one is dim, where a hover puts it.
    var rbuf: [160]u8 = undefined;
    _ = p.putFit(1 + 2 * (w + 1), y, cols -| (1 + 2 * (w + 1)), blocked_pr.hoverText(&rbuf), p.th.mutedText());
}

const demo_confirm: merge_mod.Confirm = .{
    .title = "Fix the login redirect",
    .source = "bug/fix-login",
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
        _ = p.actionChip(x, y, w, cap, action_mod.chipOf(p.th, st, .final));
        p.mark(.{ .x = x, .y = y, .w = w, .h = 1 }, target) catch {};
        x += w + 1;
    }
}

/// One button of each family, side by side, so a family painted in
/// another's colour shows up as a differing cell.
const kind_words = [_][]const u8{ "[ Open ]", "[ Review ]", "[ Triage ]", "[ Merge ]" };

fn paintKindRow(comptime Target: type, p: *chrome.Painter(Target), y: u16) void {
    var x: u16 = 1;
    for (kind_words) |w| {
        const cells = chrome.width(w);
        _ = p.actionChip(x, y, cells, w, action_mod.chipOf(p.th, .idle, action_mod.kindOf(w)));
        x += cells + 1;
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
/// A budget 70 % spent — the warning tier, so the chip's own ink is on
/// the screen being compared rather than the rest colour every chip has.
const demo_budget: budget_mod.Snapshot = .{ .label = "API", .limit = 1000, .remaining = 300 };

fn paintTracker(r: *Rig(TrackerTarget), th: Theme) !void {
    var p = r.painter(th);
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = rows - 1 }, 5);
    const x = p.capsTitle(1, 0, "PANE", "  (2 of 9)");
    _ = try p.rightChips(0, x, &.{
        .{ .text = " ? ", .target = .{ .chip = 0 } },
        .{ .text = p.refreshChipText(), .target = .{ .chip = 1 } },
        p.budgetChip(demo_budget, .{ .chip = 2 }),
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
    paintKindRow(TrackerTarget, &p, 15);
    try paintConfirm(TrackerTarget, &p, .confirm_ok, .confirm_cancel, .confirm_body);
    try p.hintRow(rows - 1, "ENG-2", &.{
        .{ .key = "d", .title = "detail", .target = .{ .hint = 0 } },
        .{ .key = "q", .title = "quit", .target = .{ .hint = 1 } },
    });
}

fn paintForge(r: *Rig(ForgeTarget), th: Theme) !void {
    var p = r.painter(th);
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = rows - 1 }, 5);
    const x = p.capsTitle(1, 0, "PANE", "  (2 of 9)");
    _ = try p.rightChips(0, x, &.{
        .{ .text = " ? ", .target = .{ .chip = .{ .kind = 0 } } },
        .{ .text = p.refreshChipText(), .target = .{ .chip = .{ .kind = 1 } } },
        p.budgetChip(demo_budget, .{ .chip = .{ .kind = 2 } }),
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
    paintKindRow(ForgeTarget, &p, 15);
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
    try paintTracker(&tracker, demoTheme());
    try paintForge(&forge, demoTheme());

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

/// One family painted into whichever rig its pane's vocabulary needs,
/// then flattened to a plain grid so the five can be compared without
/// caring which union they came from.
const Painted = struct {
    slots: []frame_mod.Slot,

    fn of(f: Family) !Painted {
        const th = themeOf(f.chip_color);
        const out = try testing.allocator.alloc(frame_mod.Slot, @as(usize, cols) * rows);
        errdefer testing.allocator.free(out);
        switch (f.vocab) {
            .tracker => {
                var r = try Rig(TrackerTarget).init(cols, rows);
                defer r.deinit();
                try paintTracker(&r, th);
                @memcpy(out, r.f.slots);
            },
            .forge => {
                var r = try Rig(ForgeTarget).init(cols, rows);
                defer r.deinit();
                try paintForge(&r, th);
                @memcpy(out, r.f.slots);
            },
        }
        return .{ .slots = out };
    }

    fn deinit(p: *Painted) void {
        testing.allocator.free(p.slots);
    }
};

fn sameColor(a: theme_mod.Color, b: theme_mod.Color) bool {
    return switch (a) {
        .index => |i| b == .index and b.index == i,
        .rgb => |v| b == .rgb and std.mem.eql(u8, &v, &b.rgb),
    };
}

/// A family's OWN colour — the one thing about the chrome that is
/// allowed to differ between two of them. It is the gutter stripe, the
/// active tab's label and the mark under it, and nothing else.
fn brandOf(f: Family) theme_mod.Color {
    return themeOf(f.chip_color).brand;
}

test "all five families paint the shared chrome identically, and differ only where the brand is" {
    var painted: [families.len]Painted = undefined;
    var made: usize = 0;
    defer for (painted[0..made]) |*pp| pp.deinit();
    for (&painted, families) |*slot, f| {
        slot.* = try Painted.of(f);
        made += 1;
    }
    const first = families[0];
    for (painted[1..], families[1..]) |other, f| {
        const brands_differ = !sameColor(brandOf(first), brandOf(f));
        var differed: usize = 0;
        var i: usize = 0;
        while (i < painted[0].slots.len) : (i += 1) {
            const a = &painted[0].slots[i];
            const b = &other.slots[i];
            const x = i % cols;
            const y = i / cols;
            if (!std.mem.eql(u8, a.symbol(), b.symbol())) {
                std.debug.print("{s} vs {s} at {d},{d}: `{s}` vs `{s}`\n", .{ first.name, f.name, x, y, a.symbol(), b.symbol() });
                return error.SymbolDrifted;
            }
            if (a.style.mods.bits() != b.style.mods.bits() or !std.meta.eql(a.style.bg, b.style.bg)) {
                std.debug.print("{s} vs {s} at {d},{d}: `{s}` ground {any}/{d} vs {any}/{d}\n", .{ first.name, f.name, x, y, a.symbol(), a.style.bg, a.style.mods.bits(), b.style.bg, b.style.mods.bits() });
                return error.ChromeDrifted;
            }
            if (std.meta.eql(a.style.fg, b.style.fg)) continue;
            differed += 1;
            // A cell that differs has to be each family's own brand on
            // its own side. Anything else is a role that has leaked a
            // family colour, or a family colour that has leaked into a
            // role — the two ways five panes stop looking like one app.
            const a_brand = a.style.fg != null and sameColor(a.style.fg.?, brandOf(first));
            const b_brand = b.style.fg != null and sameColor(b.style.fg.?, brandOf(f));
            if (!a_brand or !b_brand) {
                std.debug.print("{s} vs {s} at {d},{d}: `{s}` in {any} vs {any} — not each family's brand\n", .{ first.name, f.name, x, y, a.symbol(), a.style.fg, b.style.fg });
                return error.BrandLeaked;
            }
        }
        // …and when the two families DO wear different colours, the
        // brand has to be somewhere on the screen, or this comparison
        // is passing because nothing is painted in it.
        if (brands_differ and differed == 0) {
            std.debug.print("{s} vs {s}: different brands, identical screens — nothing paints in the brand\n", .{ first.name, f.name });
            return error.BrandNowhere;
        }
        if (!brands_differ and differed != 0) {
            std.debug.print("{s} vs {s}: same brand, {d} cells differ\n", .{ first.name, f.name, differed });
            return error.ChromeDrifted;
        }
    }
}

test "every family keeps its four button families four different colours" {
    for (families) |f| {
        const th = themeOf(f.chip_color);
        const roles = [_]theme_mod.Color{
            action_mod.roleColor(th, .navigation),
            action_mod.roleColor(th, .review),
            action_mod.roleColor(th, .dispatch),
            action_mod.roleColor(th, .final),
        };
        for (roles, 0..) |x, i| for (roles[0..i]) |y| {
            if (std.meta.eql(x, y)) {
                std.debug.print("{s}: two button families paint in {any}\n", .{ f.name, x });
                return error.ButtonColoursCollide;
            }
        };
    }
}

test "the elements the panes share are actually on the screen, so the comparison has something to compare" {
    var r = try Rig(TrackerTarget).init(cols, rows);
    defer r.deinit();
    try paintTracker(&r, demoTheme());
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
    try testing.expect(std.mem.indexOf(u8, scr, "\u{2713} SUCCESSFUL \u{b7} bug/fix-login \u{b7} 4h \u{b7} #412") != null);
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
    try testing.expect(std.mem.indexOf(u8, scr, "bug/fix-login \u{2192} main") != null);
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
    try paintTracker(&tracker, demoTheme());
    try paintForge(&forge, demoTheme());
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

test "a button's brackets stay muted and its word carries its family's colour" {
    var r = try Rig(TrackerTarget).init(cols, rows);
    defer r.deinit();
    var p = r.painter(demoTheme());
    const th = demoTheme();
    // Four words, four families, painted side by side on one row the
    // way a PR row paints them.
    const words = [_][]const u8{ "[ Open ]", "[ Review ]", "[ Triage ]", "[ Merge ]" };
    var x: u16 = 0;
    for (words) |w| {
        const kind = action_mod.kindOf(w);
        x += p.actionChip(x, 0, cols -| x, w, action_mod.chipOf(th, .idle, kind)) + 1;
    }
    // `[` and `]` are punctuation: muted, every time, whatever the
    // word between them is.
    var seen: usize = 0;
    var i: u16 = 0;
    while (i < cols) : (i += 1) {
        const slot = &r.f.slots[i];
        if (std.mem.eql(u8, slot.symbol(), "[") or std.mem.eql(u8, slot.symbol(), "]")) {
            seen += 1;
            try testing.expectEqual(th.muted, slot.style.fg.?);
        }
    }
    try testing.expectEqual(@as(usize, 8), seen);
    // The words themselves: one colour each, and no two the same.
    const at = struct {
        fn ink(rig: *Rig(TrackerTarget), needle: []const u8, row: u16) ?frame_mod.Style {
            var col: u16 = 0;
            while (col < cols) : (col += 1) {
                if (std.mem.eql(u8, rig.f.slots[@as(usize, row) * cols + col].symbol(), needle)) {
                    return rig.f.slots[@as(usize, row) * cols + col].style;
                }
            }
            return null;
        }
    };
    const open = at.ink(&r, "O", 0).?;
    const review = at.ink(&r, "R", 0).?;
    const triage = at.ink(&r, "T", 0).?;
    const merge = at.ink(&r, "M", 0).?;
    try testing.expectEqual(th.muted, open.fg.?);
    try testing.expectEqual(th.blue, review.fg.?);
    try testing.expectEqual(th.green, merge.fg.?);
    // The demo theme's brand is its blue, which `review` already has,
    // so the dispatch steps to purple rather than repeating it.
    try testing.expectEqual(th.purple, triage.fg.?);
    // None of them paints a ground of its own: a button on the
    // cursor's row keeps that row's fill.
    for ([_]frame_mod.Style{ open, review, triage, merge }) |st| try testing.expect(st.bg == null);
}

test "the hint row says a chord once, however many times the pane passes it" {
    var r = try Rig(TrackerTarget).init(cols, rows);
    defer r.deinit();
    var p = r.painter(demoTheme());
    // A pane whose bindings already carry `? keys` and which appends
    // its own gets one entry, not `? keys · ? keys`.
    try p.hintRow(0, "", &.{
        .{ .key = "r", .title = "refresh", .target = .{ .hint = 0 } },
        .{ .key = "?", .title = "keys", .target = .{ .hint = 1 } },
        .{ .key = "?", .title = "keys", .target = .{ .hint = 1 } },
    });
    const arena = r.arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    var x: u16 = 0;
    while (x < cols) : (x += 1) try text.appendSlice(arena, r.f.slots[x].symbol());
    const row = text.items;
    try testing.expect(std.mem.indexOf(u8, row, "? keys") != null);
    const first = std.mem.indexOf(u8, row, "? keys").?;
    try testing.expect(std.mem.indexOf(u8, row[first + 6 ..], "? keys") == null);
    try testing.expect(std.mem.indexOf(u8, row, "r refresh") != null);
}

test "the budget chip is the same chip in the same place on both panes, in the tier's ink" {
    var tracker = try Rig(TrackerTarget).init(cols, rows);
    defer tracker.deinit();
    var forge = try Rig(ForgeTarget).init(cols, rows);
    defer forge.deinit();
    try paintTracker(&tracker, demoTheme());
    try paintForge(&forge, demoTheme());
    const th = demoTheme();
    for ([_]*Frame{ &tracker.f, &forge.f }) |f| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(testing.allocator);
        for (f.slots[0..cols]) |*sl| try line.appendSlice(testing.allocator, sl.symbol());
        if (std.mem.indexOf(u8, line.items, "300/1000") == null) return error.BudgetChipMissing;
    }
    // Same cells, same ink, both panes: the whole header row.
    var x: u16 = 0;
    var yellow: usize = 0;
    while (x < cols) : (x += 1) {
        const a = &tracker.f.slots[x];
        const b = &forge.f.slots[x];
        try testing.expectEqualStrings(a.symbol(), b.symbol());
        try testing.expect(std.meta.eql(a.style.fg, b.style.fg));
        if (a.style.fg) |fg| if (sameColor(fg, th.yellow) and a.style.bg != null) {
            yellow += 1;
        };
    }
    // ` ~ 300/1000 ` in the warning's yellow on the chip ground.
    try testing.expect(yellow >= "300/1000".len);
}
