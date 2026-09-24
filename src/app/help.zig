//! The help overlay's rows (`ui/help_overlay.zig` paints them) — Rust's
//! `build_help`: the mode chips and the stress meter first, then every
//! command of the registry under its group, in registry order, with
//! the chords the active keymap binds to it (sorted, joined by ` · `).
//! `view.help` (F1) toggles the box; the keys, the wheel and a click
//! on a header route here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const help_ui = @import("../ui/help_overlay.zig");

pub const Row = help_ui.Row;

const modes = [_][2][]const u8{
    .{ "NORMAL", "vim normal mode (red)" },
    .{ "INSERT", "vim/standard editable (green)" },
    .{ "VISUAL", "vim visual — charwise (purple)" },
    .{ "V-LINE", "vim visual — linewise (purple)" },
    .{ "V-BLOCK", "vim visual — block/column (purple)" },
    .{ "REPLACE", "vim replace mode (orange)" },
    .{ "TREE", "file tree focused (blue)" },
    .{ "VIEW", "read-only pane focused (cyan)" },
    .{ "EDIT", "standard mode editing (green)" },
    .{ "PANEL", "right side panel focused (cyan)" },
};

const stress = [_][2][]const u8{
    .{ "0-20", "1 block, green — idle / smooth (hidden at exactly 0)" },
    .{ "20-40", "2 blocks, yellow — slight load" },
    .{ "40-70", "3 blocks, orange — noticeable slowdown" },
    .{ "70-100", "4 blocks, red — mnml is stressed" },
    .{ "chip location", "top-right cluster + bottom-right statusline (twin bars)" },
    .{ "right-click", "reset window · copy summary · toast the numbers" },
};

/// The rows, on `arena`.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]const Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    try out.append(arena, .{ .section = "modes" });
    for (modes) |m| try out.append(arena, .{ .binding = .{ .keys = m[0], .title = m[1] } });
    try out.append(arena, .{ .section = "stress meter" });
    for (stress) |m| try out.append(arena, .{ .binding = .{ .keys = m[0], .title = m[1] } });
    // The keymap reversed: command → its chord specs, sorted.
    var by_cmd = std.AutoHashMapUnmanaged(command.CommandId, std.ArrayListUnmanaged([]const u8)).empty;
    var it = app.keymap.map.iterator();
    while (it.next()) |e| {
        const id = switch (e.value_ptr.*) {
            .static => |id| id,
            .named => continue,
        };
        const spec = try seqSpec(arena, e.key_ptr.*);
        const gop = try by_cmd.getOrPut(arena, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, spec);
    }
    var last_group: []const u8 = "";
    var i: usize = 0;
    while (i < command.count) : (i += 1) {
        const id: command.CommandId = @enumFromInt(i);
        const group = command.group(id);
        if (!std.mem.eql(u8, group, last_group)) {
            try out.append(arena, .{ .section = group });
            last_group = group;
        }
        const keys: []const u8 = if (by_cmd.getPtr(id)) |list| blk: {
            std.mem.sort([]const u8, list.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            break :blk try std.mem.join(arena, " · ", list.items);
        } else "";
        try out.append(arena, .{ .binding = .{ .keys = keys, .title = command.title(id) } });
    }
    return out.items;
}

/// The section names, for `c` / `e`.
pub fn sections(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try rows(app, arena)) |r| if (r == .section) try out.append(arena, r.section);
    return out.items;
}

/// A keymap key (the packed chord sequence) as its spec: `ctrl+k g c`.
fn seqSpec(arena: Allocator, packed_key: []const u8) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const n = packed_key.len / @sizeOf(u64);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = std.mem.bytesToValue(u64, packed_key[i * 8 ..][0..8]);
        if (i > 0) aw.writer.writeAll(" ") catch return error.OutOfMemory;
        key_mod.Chord.unpack(v).format(&aw.writer) catch return error.OutOfMemory;
    }
    return aw.written();
}

pub fn toggle(app: *App) void {
    if (app.overlay == .help) {
        app.overlay.deinit(app.gpa);
        app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    } else {
        app.overlay.deinit(app.gpa);
        app.overlay = .{ .help = .{} };
        app.focus = .overlay;
    }
    app.needs_render = true;
}

pub fn key(app: *App, k: key_mod.Key) Allocator.Error!void {
    const s = &app.overlay.help;
    const secs = try sections(app, app.frame.allocator());
    switch (try help_ui.handleKey(s, app.gpa, k, secs)) {
        .consumed => {},
        .close => toggle(app),
    }
    app.needs_render = true;
}

/// A click on a header row (`.overlay_item(i)`, `i` into the rows).
pub fn click(app: *App, i: usize) Allocator.Error!void {
    const all = try rows(app, app.frame.allocator());
    if (i >= all.len or all[i] != .section) return;
    try app.overlay.help.toggle(app.gpa, all[i].section);
    app.needs_render = true;
}

pub fn wheel(app: *App, delta: isize) void {
    app.overlay.help.scrollBy(delta);
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = key_mod.Key;

test "the rows are Rust's build_help: modes, the stress meter, then every group with its bound chords" {
    var app = try App.initWith(t.allocator, t.io, .{});
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const all = try rows(&app, arena_state.allocator());
    try t.expectEqualStrings("modes", all[0].section);
    try t.expectEqualStrings("NORMAL", all[1].binding.keys);
    try t.expectEqualStrings("stress meter", all[11].section);
    try t.expectEqualStrings("app", all[18].section);
    try t.expectEqualStrings("ctrl+q", all[19].binding.keys);
    try t.expectEqualStrings("Quit mnml", all[19].binding.title);
    try t.expectEqualStrings("", all[20].binding.keys);
    // A chord chain reads as its spec; the sections are the groups in order.
    var seen_chain = false;
    var seen_view = false;
    for (all) |r| switch (r) {
        .binding => |b| if (std.mem.eql(u8, b.title, command.title(.@"git.blame_toggle"))) {
            // The standard profile's own chord, then its which-key row.
            try t.expectEqualStrings("ctrl+k b · space g b", b.keys);
            seen_chain = true;
        },
        .section => |s| if (std.mem.eql(u8, s, "view")) {
            seen_view = true;
        },
    };
    try t.expect(seen_chain and seen_view);
}

test "F1 toggles the help; Esc closes it; a header click folds" {
    var app = try App.initWith(t.allocator, t.io, .{});
    defer app.deinit();
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .help);
    try app.render();
    try app.handle(.{ .key = Key.char('j') });
    try t.expectEqual(@as(usize, 1), app.overlay.help.scroll);
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .none);
    try command.run(&app, .{ .static = .@"view.help" });
    try t.expect(app.overlay == .help);
    try click(&app, 0);
    try t.expect(app.overlay.help.isCollapsed("modes"));
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
}
