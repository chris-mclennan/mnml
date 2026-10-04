//! The review pane's paint (`app/ai_apply.zig` — `ai.apply`, and Claude
//! Code's `openDiff`): one header row naming who proposed the change,
//! the file and the tally (`2 of 3 hunks accepted`), the keys, and an
//! ` Accept all ` chip at the right end; then the git diff pane's own
//! renderer (`diff_view.zig`) — its Hunk / Inline / Split toolbar and
//! rows, `Doc.review` badging each hunk accepted or skipped. Every row
//! and chip registers a `.script_hit{ pane, id }` so a click reaches
//! the app.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const overlay = @import("overlay.zig");
const diff_view = @import("diff_view.zig");
const ids = @import("../core/ids.zig");

const PaneId = ids.PaneId;

/// The header's ` Accept all `; above the rows, clear of `diff_view`'s ids.
pub const accept_all_id: u32 = diff_view.special_base + 0x30;

pub const Props = struct {
    /// Who proposed it: `Claude Code` for an `openDiff`, else `ai.apply`.
    source: []const u8,
    file: []const u8,
    accepted: usize,
    total: usize,
    doc: diff_view.Doc,
};

pub const hint = "space toggle \u{b7} Y accept all \u{b7} enter apply \u{b7} t view \u{b7} esc reject";

const accept_all = " Accept all ";

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *diff_view.State, p: Props) diff_view.Painted {
    const pal = ui.theme.palette;
    ui.fill(area, .{ .bg = pal.bg_dark });
    if (area.isEmpty()) return .{};
    const s = area.splitTop(1);
    const r = s.top;
    ui.fill(r, .{ .bg = pal.bg_darker });
    const head = overlay.hintText(ui, ui.fmt(" {s} \u{2192} {s}   {d} of {d} hunk{s} accepted   ", .{ p.source, p.file, p.accepted, p.total, if (p.total == 1) "" else "s" }));
    // The chip when the tally still fits beside it; the keys clip short of it.
    var end = r.right();
    const cw = ui.width(accept_all);
    if (p.total > 0 and r.w >= ui.width(head) + cw + 1) {
        const cx = r.right() - cw - 1;
        _ = ui.putStr(cx, r.y, cw, accept_all, .{ .fg = pal.bg_dark, .bg = pal.green, .bold = true });
        ui.hit(Rect.init(cx, r.y, cw, 1), .{ .script_hit = .{ .pane = pane, .id = accept_all_id } });
        end = cx -| 1;
    }
    var x = r.x;
    x += ui.putStr(x, r.y, end -| x, head, .{ .fg = pal.cyan, .bg = pal.bg_darker, .bold = true });
    _ = ui.putStr(x, r.y, end -| x, overlay.hintText(ui, hint), .{ .fg = pal.comment, .bg = pal.bg_darker });
    if (s.rest.isEmpty()) return .{};
    if (p.total == 0) {
        _ = ui.putStr(s.rest.x + 2, s.rest.y, s.rest.w -| 2, "The proposal matches the editor \u{2014} nothing to apply.", .{ .fg = pal.comment, .bg = pal.bg_dark });
        return .{};
    }
    return diff_view.draw(ui, pane, s.rest, view, p.doc);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");
const parse = @import("../git/parse.zig");

test "the review pane: a header with the tally and Accept all, then the diff view's split with badges and no git toolbar" {
    var f = try Fixture.init(110, 9);
    defer f.deinit();
    const a = f.arena_state.allocator();
    var lines0 = [_]parse.DiffLine{
        .{ .kind = .context, .text = "same", .old_no = 1, .new_no = 1 },
        .{ .kind = .del, .text = "gone", .old_no = 2 },
        .{ .kind = .add, .text = "fresh", .new_no = 2 },
    };
    var lines1 = [_]parse.DiffLine{
        .{ .kind = .del, .text = "tail", .old_no = 3 },
    };
    var hunks = [_]parse.Hunk{
        .{ .header = "@@ -1,2 +1,2 @@", .old_start = 1, .old_count = 2, .new_start = 1, .new_count = 2, .lines = &lines0 },
        .{ .header = "@@ -3,1 +3,0 @@", .old_start = 3, .old_count = 1, .new_start = 3, .new_count = 0, .lines = &lines1 },
    };
    const files = [_]parse.FileDiff{.{ .new_path = "src/a.zig", .hunks = &hunks }};
    const split = try diff_view.pairs(a, &files);
    const shown = try diff_view.filterSplitRows(a, &files, split, "");
    var view: diff_view.State = .{};
    const review = [_]bool{ true, false };
    _ = draw(f.ui(), 4, f.full(), &view, .{
        .source = "Claude Code",
        .file = "src/a.zig",
        .accepted = 1,
        .total = 2,
        .doc = .{ .files = &files, .rows = &.{}, .shown = &.{}, .split_rows = split, .split_shown = shown, .mode = .split, .cursor = 0, .focused = true, .actions = .none, .git_toolbar = false, .review = &review },
    });
    try f.expectContains(" Claude Code \u{2192} src/a.zig   1 of 2 hunks accepted   space toggle \u{b7} Y accept all");
    try f.expectContains("Accept all");
    try testing.expectEqual(accept_all_id, f.hits.at(110 - 3, 0).?.script_hit.id);
    // No git toolbar: the diff toolbar is the second row.
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(1, &buf), " Hunk   Inline   Split ") != null);
    try f.expectContains("@@ -1,2 +1,2 @@  [\u{2713} accept]  src/a.zig");
    try f.expectContains("@@ -3,1 +3,0 @@  [  skip  ]  src/a.zig");
    // Old on the left, new on the right of one row.
    const pair = f.row(4, &buf);
    try testing.expect(std.mem.indexOf(u8, pair, "gone").? < std.mem.indexOf(u8, pair, "fresh").?);
}
