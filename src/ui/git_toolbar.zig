//! The git toolbar — the row of action buttons the Rust editor paints
//! above a diff pane and the git graph (`git_graph_view::draw_git_toolbar`),
//! cell for cell:
//!
//! ```text
//!  󰕌 Undo   󰑎 Redo    Pull    Push    Fetch    Branch    Commit    Stash   󰋚 Reflog
//! ```
//!
//! Each button is ` icon label ` on the chip ground (`bg2`), the icon
//! in the action's accent, the label bold in the foreground; one cell
//! of strip between buttons; the row centred in its area. Buttons drop
//! from the right until the rest fit (one always stays). `Pop` sits
//! after `Stash` only while the repo has a stash to pop. Every button
//! registers `.script_hit{ pane, id = hitId(action) }`; the pane's
//! click prong maps the action to its `git.*` command.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");
const parse = @import("../git/parse.zig");
const compat = @import("mnml_sdk").zig_compat;

const Style = vaxis.Style;
const Color = vaxis.Color;
pub const PaneId = ids.PaneId;

pub const Action = enum(u8) { undo, redo, pull, push, fetch, branch, commit, stash, pop, reflog, refresh, cont, abort, skip };

/// Above the diff view's own controls (`diff_view.special_base` region).
pub const hit_base: u32 = 0xF300_0000;
const action_count: u32 = compat.enumFields(Action).len;

pub fn hitId(a: Action) u32 {
    return hit_base + @intFromEnum(a);
}

pub fn actionOf(id: u32) ?Action {
    if (id < hit_base or id >= hit_base + action_count) return null;
    return @enumFromInt(id - hit_base);
}

/// Rust's `draw_git_toolbar` skips a row narrower than this.
pub const min_width: u16 = 20;
/// Between buttons.
pub const gap: u16 = 1;

const Accent = enum { comment, green, blue, cyan, yellow, purple, orange };

const Spec = struct { label: []const u8, action: Action, ascii: []const u8, glyph: []const u8, accent: Accent };

// Rust's table: label, action, the `--ascii` twin, the codicon / nf-md
// glyph, the accent. `Pop` is spliced in after `Stash` on demand.
const specs = [_]Spec{
    .{ .label = "Undo", .action = .undo, .ascii = "\u{21B6}", .glyph = "\u{F054C}", .accent = .comment },
    .{ .label = "Redo", .action = .redo, .ascii = "\u{21B7}", .glyph = "\u{F044E}", .accent = .comment },
    .{ .label = "Pull", .action = .pull, .ascii = "\u{2193}", .glyph = "\u{EB40}", .accent = .green },
    .{ .label = "Push", .action = .push, .ascii = "\u{2191}", .glyph = "\u{EB41}", .accent = .blue },
    .{ .label = "Fetch", .action = .fetch, .ascii = "\u{21BA}", .glyph = "\u{EC1D}", .accent = .cyan },
    .{ .label = "Branch", .action = .branch, .ascii = "\u{2387}", .glyph = "\u{EC6F}", .accent = .yellow },
    .{ .label = "Commit", .action = .commit, .ascii = "\u{2713}", .glyph = "\u{EAFC}", .accent = .green },
    .{ .label = "Stash", .action = .stash, .ascii = "\u{21A7}", .glyph = "\u{EC26}", .accent = .purple },
    .{ .label = "Reflog", .action = .reflog, .ascii = "\u{21BA}", .glyph = "\u{F02DA}", .accent = .orange },
    .{ .label = "Refresh", .action = .refresh, .ascii = "\u{21BB}", .glyph = "\u{EB37}", .accent = .cyan },
};
const pop_spec: Spec = .{ .label = "Pop", .action = .pop, .ascii = "\u{21A5}", .glyph = "\u{EC28}", .accent = .purple };
// While a rebase / merge / cherry-pick / revert / bisect waits on the
// user the row is the three ways forward, then Refresh. `Skip` only
// where git has a `--skip`.
const progress_specs = [_]Spec{
    .{ .label = "Continue", .action = .cont, .ascii = ">", .glyph = "\u{F040A}", .accent = .green },
    .{ .label = "Abort", .action = .abort, .ascii = "x", .glyph = "\u{F0156}", .accent = .orange },
};
const skip_spec: Spec = .{ .label = "Skip", .action = .skip, .ascii = ">>", .glyph = "\u{F04AD}", .accent = .yellow };

fn accentColor(p: Theme.Palette, a: Accent) Color {
    return switch (a) {
        .comment => p.comment,
        .green => p.green,
        .blue => p.blue,
        .cyan => p.cyan,
        .yellow => p.yellow,
        .purple => p.purple,
        .orange => p.orange,
    };
}

/// ` icon label `: one cell, the icon, one cell, the label, one cell.
fn buttonWidth(ui: Ui, s: Spec) u16 {
    return ui.width(if (ui.ascii) s.ascii else s.glyph) + ui.width(s.label) + 3;
}

pub const Props = struct {
    pane: PaneId,
    has_stash: bool = false,
    /// The operation the repo is in the middle of: the row swaps to
    /// `Continue · Abort · Skip`.
    in_progress: parse.InProgress = .none,
};

/// The buttons in row order for `props`, on the frame arena.
fn buttons(ui: Ui, props: Props) []const Spec {
    var out: std.ArrayListUnmanaged(Spec) = .empty;
    if (props.in_progress != .none) {
        out.appendSlice(ui.arena, &progress_specs) catch return &.{};
        if (props.in_progress.canSkip()) out.append(ui.arena, skip_spec) catch return &.{};
        out.append(ui.arena, specs[specs.len - 1]) catch return &.{};
        return out.items;
    }
    for (specs) |s| {
        out.append(ui.arena, s) catch return &.{};
        if (s.action == .stash and props.has_stash) out.append(ui.arena, pop_spec) catch return &.{};
    }
    return out.items;
}

/// How many of `list` fit in `w` cells with the gaps — at least one.
fn fitCount(ui: Ui, list: []const Spec, w: u16) usize {
    var used: u16 = 0;
    var n: usize = 0;
    for (list, 0..) |s, i| {
        const extra: u16 = if (i > 0) gap else 0;
        if (used + extra + buttonWidth(ui, s) > w) break;
        used += extra + buttonWidth(ui, s);
        n += 1;
    }
    return @max(n, 1);
}

/// Paints the toolbar into `area` (one row) and registers a hit per button.
pub fn draw(ui: Ui, area: Rect, props: Props) void {
    const p = ui.theme.palette;
    const ground: Style = .{ .bg = p.bg_darker };
    ui.fill(area, ground);
    if (area.w < min_width or area.h < 1) return;
    const list = buttons(ui, props);
    const shown = list[0..fitCount(ui, list, area.w)];
    var total: u16 = 0;
    for (shown, 0..) |s, i| total += buttonWidth(ui, s) + @as(u16, if (i > 0) gap else 0);
    var x = area.x + (area.w -| total) / 2;
    const y = area.y;
    for (shown, 0..) |s, i| {
        if (i > 0) x += gap;
        const w = buttonWidth(ui, s);
        if (x + w > area.right()) break;
        const r = Rect.init(x, y, w, 1);
        const base: Style = .{ .fg = p.fg, .bg = p.bg2, .bold = true };
        ui.fill(r, base);
        var cx = x + 1;
        cx += ui.putStr(cx, y, w, if (ui.ascii) s.ascii else s.glyph, .{ .fg = accentColor(p, s.accent), .bg = p.bg2, .bold = true });
        cx += 1;
        _ = ui.putStr(cx, y, area.right() -| cx, s.label, base);
        ui.hit(r, .{ .script_hit = .{ .pane = props.pane, .id = hitId(s.action) } });
        x += w;
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

pub fn glyphOf(a: Action) []const u8 {
    if (a == .pop) return pop_spec.glyph;
    if (a == .skip) return skip_spec.glyph;
    for (progress_specs) |s| if (s.action == a) return s.glyph;
    for (specs) |s| if (s.action == a) return s.glyph;
    unreachable;
}

/// Row 2 of `docs/ui-spec/rust-diff-120x40.txt`, columns 31..120 (89
/// cells): nine buttons, `Refresh` dropped, centred with no lead.
fn specRow(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, " {s} Undo   {s} Redo   {s} Pull   {s} Push   {s} Fetch   {s} Branch   {s} Commit   {s} Stash   {s} Reflog", .{
        glyphOf(.undo), glyphOf(.redo), glyphOf(.pull), glyphOf(.push), glyphOf(.fetch), glyphOf(.branch), glyphOf(.commit), glyphOf(.stash), glyphOf(.reflog),
    });
}

test "the diff spec's toolbar row, cell for cell: nine buttons fit in 89, Refresh drops, every button is a hit" {
    var f = try Fixture.init(89, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .pane = 3 });
    try f.expectRow(0, try specRow(f.arena_state.allocator()));
    try testing.expectEqual(hitId(.undo), f.hits.at(1, 0).?.script_hit.id);
    try testing.expectEqual(hitId(.undo), f.hits.at(7, 0).?.script_hit.id);
    try testing.expect(f.hits.at(8, 0) == null);
    try testing.expectEqual(hitId(.redo), f.hits.at(9, 0).?.script_hit.id);
    try testing.expectEqual(hitId(.reflog), f.hits.at(85, 0).?.script_hit.id);
    try testing.expectEqual(@as(u32, 3), f.hits.at(85, 0).?.script_hit.pane);
    try testing.expectEqual(@as(?Action, .reflog), actionOf(hitId(.reflog)));
    try testing.expectEqual(@as(?Action, null), actionOf(hit_base + action_count));
    try testing.expectEqual(@as(?Action, null), actionOf(7));
    // The chip ground under the label, the accent on the icon, the strip between.
    try testing.expect(f.bgEql(4, 0, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.palette.comment }));
    try testing.expect(f.fgEql(19, 0, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.bgEql(8, 0, .{ .bg = f.theme.palette.bg_darker }));
    try testing.expect(f.style(4, 0).bold);
}

test "a narrow row keeps what fits and centres it; Pop joins after Stash with a stash; ASCII twins; under 20 cells nothing paints" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .pane = 1 });
    // Undo (8) + Redo (8) + Pull (8) + Push (8) + 3 gaps = 35; lead 2.
    try f.expectRow(0, try std.fmt.allocPrint(f.arena_state.allocator(), "   {s} Undo   {s} Redo   {s} Pull   {s} Push", .{ glyphOf(.undo), glyphOf(.redo), glyphOf(.pull), glyphOf(.push) }));
    try testing.expectEqual(hitId(.push), f.hits.at(36, 0).?.script_hit.id);
    try testing.expect(f.hits.at(1, 0) == null);
    var g = try Fixture.init(120, 1);
    defer g.deinit();
    g.ascii = true;
    draw(g.ui(), g.full(), .{ .pane = 1, .has_stash = true });
    try g.expectContains(" \u{21A7} Stash   \u{21A5} Pop   \u{21BA} Reflog   \u{21BB} Refresh");
    try testing.expect(g.hits.at(0, 0) == null);
    var found = false;
    for (g.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.id == hitId(.pop)) {
        found = true;
    };
    try testing.expect(found);
    var h = try Fixture.init(19, 1);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .pane = 1 });
    try h.expectRow(0, "");
    try testing.expectEqual(@as(usize, 0), h.hits.items.items.len);
}

test "mid-operation the row is Continue · Abort · Skip · Refresh; a merge has no Skip; every button is a hit" {
    var f = try Fixture.init(89, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .pane = 3, .has_stash = true, .in_progress = .rebase });
    try f.expectRow(0, try std.fmt.allocPrint(f.arena_state.allocator(), "                        {s} Continue   {s} Abort   {s} Skip   {s} Refresh", .{ glyphOf(.cont), glyphOf(.abort), glyphOf(.skip), glyphOf(.refresh) }));
    var seen_cont = false;
    var seen_skip = false;
    var seen_stash = false;
    for (f.hits.items.items) |h| if (h.target == .script_hit) {
        if (h.target.script_hit.id == hitId(.cont)) seen_cont = true;
        if (h.target.script_hit.id == hitId(.skip)) seen_skip = true;
        if (h.target.script_hit.id == hitId(.stash)) seen_stash = true;
    };
    try testing.expect(seen_cont and seen_skip and !seen_stash);
    try testing.expectEqual(@as(?Action, .skip), actionOf(hitId(.skip)));
    var g = try Fixture.init(89, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .pane = 3, .in_progress = .merge });
    try g.expectContains(" Continue ");
    try g.expectContains(" Abort ");
    try g.expectLacks(" Skip ");
}
