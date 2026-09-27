//! The cheatsheet pane: every chord of the active keymap profile, by
//! command group, in a read-only `Pane`. `/` filters across chord, id
//! and title; `C` collapses the focused section; `X` collapses all —
//! unless everything is already collapsed, in which case it expands
//! all (so `C` then `X` collapses the rest instead of undoing the one).
//! A filter ignores collapse: the user is searching, everything is in
//! scope, and a section with no match under a filter is dropped rather
//! than left as an empty header. Enter runs the row's command.
//!
//! Rows register `.script_hit{pane, id}` — a row index, or a section
//! index with `header_bit` set — so a click selects or toggles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const keymap = @import("../core/keymap.zig");
const Key = @import("../core/key.zig").Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");

pub const table = .{
    .@"view.cheatsheet" = &open,
};

pub const header_bit: u32 = 0x8000_0000;

pub const Row = struct {
    chord: []const u8,
    id: []const u8,
    title: []const u8,
    cmd: command.CommandId,
};

pub const Section = struct {
    group: []const u8,
    rows: []Row,
};

pub const State = struct {
    gpa: Allocator,
    sections: []Section,
    /// Chord strings are built at open time (canonical spelling).
    chords: std.ArrayListUnmanaged([]u8) = .empty,
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    query: std.ArrayListUnmanaged(u8) = .empty,
    filtering: bool = false,
    selected: usize = 0,
    scroll: usize = 0,

    pub fn init(gpa: Allocator, profile: keymap.Profile) Allocator.Error!State {
        var st: State = .{ .gpa = gpa, .sections = &.{} };
        errdefer st.deinit();
        // Group order: first appearance in the spec table.
        var groups: std.ArrayListUnmanaged([]const u8) = .empty;
        defer groups.deinit(gpa);
        var rows: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Row)) = .empty;
        defer {
            for (rows.items) |*r| r.deinit(gpa);
            rows.deinit(gpa);
        }
        var i: usize = 0;
        while (i < command.count) : (i += 1) {
            const id: command.CommandId = @enumFromInt(i);
            const spec = command.spec(id);
            const own = switch (profile) {
                .vim => spec.keys.vim,
                .standard => spec.keys.standard,
            };
            // The vim handler's own chords (`Ctrl-W w`) are listed too.
            const handler: []const []const u8 = if (profile == .vim) spec.keys.vim_handler else &.{};
            if (spec.keys.both.len == 0 and own.len == 0 and handler.len == 0) continue;
            var gi: usize = groups.items.len;
            for (groups.items, 0..) |g, k| if (std.mem.eql(u8, g, spec.group)) {
                gi = k;
            };
            if (gi == groups.items.len) {
                try groups.append(gpa, spec.group);
                try rows.append(gpa, .empty);
            }
            inline for (.{ spec.keys.both, own, handler }) |list| {
                for (list) |k| {
                    var buf: [64]u8 = undefined;
                    const canon = keymap.normalizeSpec(k, &buf) orelse k;
                    const chord = try gpa.dupe(u8, canon);
                    errdefer gpa.free(chord);
                    try st.chords.append(gpa, chord);
                    try rows.items[gi].append(gpa, .{ .chord = chord, .id = command.name(id), .title = spec.title, .cmd = id });
                }
            }
        }
        const sections = try gpa.alloc(Section, groups.items.len);
        var filled: usize = 0;
        errdefer {
            for (sections[0..filled]) |s| gpa.free(s.rows);
            gpa.free(sections);
        }
        for (groups.items, 0..) |g, k| {
            sections[k] = .{ .group = g, .rows = try rows.items[k].toOwnedSlice(gpa) };
            filled += 1;
        }
        st.sections = sections;
        return st;
    }

    pub fn deinit(self: *State) void {
        for (self.sections) |s| self.gpa.free(s.rows);
        self.gpa.free(self.sections);
        for (self.chords.items) |c| self.gpa.free(c);
        self.chords.deinit(self.gpa);
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.collapsed.deinit(self.gpa);
        self.query.deinit(self.gpa);
    }

    pub fn isCollapsed(self: *const State, group: []const u8) bool {
        return self.collapsed.contains(group);
    }

    pub fn setCollapsed(self: *State, group: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (self.collapsed.contains(group)) return;
            const key = try self.gpa.dupe(u8, group);
            errdefer self.gpa.free(key);
            try self.collapsed.put(self.gpa, key, {});
        } else if (self.collapsed.fetchRemove(group)) |kv| self.gpa.free(kv.key);
    }

    pub fn allCollapsed(self: *const State) bool {
        for (self.sections) |s| if (!self.isCollapsed(s.group)) return false;
        return self.sections.len > 0;
    }

    fn matches(self: *const State, r: Row) bool {
        const q = self.query.items;
        if (q.len == 0) return true;
        return containsFold(r.chord, q) or containsFold(r.id, q) or containsFold(r.title, q);
    }

    /// What the pane shows: with no filter, every section (a collapsed
    /// one with no rows); with a filter, every section with a matching
    /// row, collapse ignored.
    pub fn visible(self: *const State, arena: Allocator) Allocator.Error![]Section {
        var out: std.ArrayListUnmanaged(Section) = .empty;
        const filter_active = self.query.items.len > 0;
        for (self.sections) |s| {
            if (!filter_active and self.isCollapsed(s.group)) {
                try out.append(arena, .{ .group = s.group, .rows = &.{} });
                continue;
            }
            if (!filter_active) {
                try out.append(arena, s);
                continue;
            }
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            for (s.rows) |r| if (self.matches(r)) try rows.append(arena, r);
            if (rows.items.len > 0) try out.append(arena, .{ .group = s.group, .rows = rows.items });
        }
        return out.items;
    }

    /// The group the selected row sits in.
    pub fn selectedGroup(self: *const State, arena: Allocator) Allocator.Error!?[]const u8 {
        var idx: usize = 0;
        for (try self.visible(arena)) |s| {
            if (s.rows.len == 0) continue;
            if (self.selected < idx + s.rows.len) return s.group;
            idx += s.rows.len;
        }
        // Everything collapsed: the first section is "focused".
        if (self.sections.len > 0) return self.sections[0].group;
        return null;
    }

    pub fn rowCount(self: *const State, arena: Allocator) Allocator.Error!usize {
        var n: usize = 0;
        for (try self.visible(arena)) |s| n += s.rows.len;
        return n;
    }

    pub fn selectedRow(self: *const State, arena: Allocator) Allocator.Error!?Row {
        var idx: usize = 0;
        for (try self.visible(arena)) |s| {
            if (self.selected < idx + s.rows.len) return s.rows[self.selected - idx];
            idx += s.rows.len;
        }
        return null;
    }
};

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// `view.cheatsheet`: open (or reveal) the one cheatsheet pane.
fn open(app: *App) CommandError!void {
    if (app.panes.findKind(.cheatsheet)) |id| {
        app.showPane(id);
        return;
    }
    var st = try State.init(app.gpa, App.profileOf(app.input_style));
    errdefer st.deinit();
    const id = try app.panes.add(.{ .cheatsheet = st });
    app.showPane(id);
}

/// `C` toggles the focused section; `X` collapses all, or expands all
/// when nothing is left to collapse. Returns true when the key was taken.
pub fn handleKey(app: *App, st: *State, k: Key) Allocator.Error!bool {
    const arena = app.frame.allocator();
    if (st.filtering) {
        switch (k.code) {
            .esc => {
                st.filtering = false;
                st.query.clearRetainingCapacity();
                st.selected = 0;
            },
            .enter => st.filtering = false,
            .backspace => {
                _ = st.query.pop();
                st.selected = 0;
            },
            .char => |c| if (k.typed()) |ch| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &buf) catch return true;
                try st.query.appendSlice(st.gpa, buf[0..n]);
                st.selected = 0;
                _ = c;
            } else return false,
            else => return false,
        }
        app.needs_render = true;
        return true;
    }
    const n = try st.rowCount(arena);
    switch (k.code) {
        .esc => {
            if (st.query.items.len > 0) {
                st.query.clearRetainingCapacity();
                st.selected = 0;
            } else if (app.active) |id| try app.closePane(id, false);
        },
        .down => st.selected = @min(st.selected + 1, n -| 1),
        .up => st.selected -|= 1,
        .home => st.selected = 0,
        .end => st.selected = n -| 1,
        .page_down => st.selected = @min(st.selected + 20, n -| 1),
        .page_up => st.selected -|= 20,
        .enter => if (try st.selectedRow(arena)) |r| {
            command.run(app, .{ .static = r.cmd }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .char => |c| switch (c) {
            'j' => st.selected = @min(st.selected + 1, n -| 1),
            'k' => st.selected -|= 1,
            'g' => st.selected = 0,
            'G' => st.selected = n -| 1,
            '/' => st.filtering = true,
            'C' => if (try st.selectedGroup(arena)) |g| try st.setCollapsed(g, !st.isCollapsed(g)),
            'X' => {
                const expand = st.allCollapsed();
                for (st.sections) |s| try st.setCollapsed(s.group, !expand);
                st.selected = 0;
            },
            else => return false,
        },
        else => return false,
    }
    if (st.selected >= try st.rowCount(arena)) st.selected = (try st.rowCount(arena)) -| 1;
    app.needs_render = true;
    return true;
}

/// A click on a row selects it (a second click runs it); a click on a
/// section header toggles its collapse.
pub fn click(app: *App, st: *State, id: u32) Allocator.Error!void {
    if (id & header_bit != 0) {
        const si = id & ~header_bit;
        if (si < st.sections.len) {
            const g = st.sections[si].group;
            try st.setCollapsed(g, !st.isCollapsed(g));
        }
    } else {
        if (st.selected == id) {
            _ = try handleKey(app, st, Key.named(.enter));
        } else st.selected = id;
    }
    app.needs_render = true;
}

pub fn draw(app: *App, st: *State, ui: Ui, pane: PaneId, area: Rect) Allocator.Error!void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const header = if (st.filtering)
        ui.fmt(" Cheatsheet · /{s}▏ · esc clears · enter applies ", .{st.query.items})
    else if (st.query.items.len > 0)
        ui.fmt(" Cheatsheet · filter: {s} · / to edit · esc clears ", .{st.query.items})
    else if (app.input_style == .vim)
        " Cheatsheet · / filter · j/k · C collapse · X all · Esc → back "
    else
        // The standard profile moves with the arrows; `j/k` is a vim
        // user's hint.
        " Cheatsheet · / filter · ↑↓ · C collapse · X all · Esc → back ";
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(header, area.w), Theme.onBg(th.accent, th.bg.bg));
    if (area.h < 2) return;
    const list = area.splitTop(1).rest;
    const sections = try st.visible(ui.arena);
    // Lines: a header per section, then its rows.
    const Line = union(enum) { header: struct { si: usize, group: []const u8, n: usize, collapsed: bool }, row: struct { idx: usize, row: Row }, blank };
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var row_idx: usize = 0;
    var selected_line: usize = 0;
    for (sections) |s| {
        var si: usize = 0;
        for (st.sections, 0..) |orig, k| if (std.mem.eql(u8, orig.group, s.group)) {
            si = k;
        };
        const collapsed = st.query.items.len == 0 and st.isCollapsed(s.group);
        try lines.append(ui.arena, .{ .header = .{ .si = si, .group = s.group, .n = if (collapsed) st.sections[si].rows.len else s.rows.len, .collapsed = collapsed } });
        for (s.rows) |r| {
            if (row_idx == st.selected) selected_line = lines.items.len;
            try lines.append(ui.arena, .{ .row = .{ .idx = row_idx, .row = r } });
            row_idx += 1;
        }
    }
    if (row_idx == 0 and st.query.items.len > 0) {
        _ = ui.putStr(list.x + 2, list.y, list.w -| 2, "no matches", Theme.onBg(th.muted, th.bg.bg));
        return;
    }
    const rows: usize = list.h;
    if (selected_line < st.scroll) st.scroll = selected_line;
    if (selected_line >= st.scroll + rows) st.scroll = selected_line + 1 - rows;
    var y: u16 = 0;
    var i = st.scroll;
    while (i < lines.items.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        switch (lines.items[i]) {
            .header => |h| {
                const text = if (h.collapsed)
                    ui.fmt(" {s} ({d} · collapsed)", .{ h.group, h.n })
                else
                    ui.fmt(" {s} ({d})", .{ h.group, h.n });
                ui.fill(r, th.panel_bg);
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(text, r.w), Theme.onBg(if (h.collapsed) th.muted else th.accent, th.panel_bg.bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = header_bit | @as(u32, @intCast(h.si)) } });
            },
            .row => |rw| {
                const sel = rw.idx == st.selected and app.active == pane;
                const bg = if (sel) th.cursor_line.bg else th.bg.bg;
                if (sel) ui.fill(r, th.cursor_line);
                var x = r.x + 2;
                x += ui.putStr(x, r.y, 18, rw.row.chord, Theme.onBg(th.accent, bg));
                x = @max(x, r.x + 20);
                // The id keeps its whole width at the right edge and the
                // title is clipped short of it, two cells apart — never
                // one running into the other (`…every workspace
                // sectionview.toggle_hidde`). Too narrow for both: the
                // title alone.
                const room = r.right() -| x;
                const id_w = ui.width(rw.row.id);
                const with_id = room >= id_w + 2 + 12;
                const title_w: u16 = if (with_id) room -| (id_w + 3) else room -| 2;
                _ = ui.putStr(x, r.y, title_w, ui.clipStr(rw.row.title, title_w), Theme.onBg(th.fg, bg));
                if (with_id) _ = ui.putStrRight(r.right() -| 1, r.y, id_w, rw.row.id, Theme.onBg(th.muted, bg));
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(rw.idx) } });
            },
            .blank => {},
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "cheatsheet: C collapses the focused section, X collapses the rest; a filter ignores collapse and drops empty sections" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.cheatsheet" });
    const id = app.active.?;
    const st = &app.panes.get(id).?.cheatsheet;
    try t.expect(st.sections.len > 3);
    const arena = app.frame.allocator();
    const total = try st.rowCount(arena);
    try t.expect(total > 20);
    try t.expect(try handleKey(&app, st, Key.char('C')));
    try t.expectEqual(@as(usize, 1), st.collapsed.count());
    // X with one section collapsed collapses everything (does not undo the one).
    try t.expect(try handleKey(&app, st, Key.char('X')));
    try t.expect(st.allCollapsed());
    try t.expectEqual(@as(usize, 0), try st.rowCount(arena));
    // X again expands everything.
    try t.expect(try handleKey(&app, st, Key.char('X')));
    try t.expectEqual(total, try st.rowCount(arena));
    // A filter reaches into collapsed sections and drops the rest.
    try t.expect(try handleKey(&app, st, Key.char('X')));
    try t.expect(try handleKey(&app, st, Key.char('/')));
    for ("app.quit") |c| try t.expect(try handleKey(&app, st, Key.char(c)));
    try t.expectEqual(@as(usize, 1), try st.rowCount(arena));
    try t.expectEqualStrings("app.quit", (try st.selectedRow(arena)).?.id);
    const vis = try st.visible(arena);
    try t.expectEqual(@as(usize, 1), vis.len);
    try t.expect(try handleKey(&app, st, Key.named(.esc)));
    try t.expectEqual(@as(usize, 0), st.query.items.len);
    // Second open reveals the same pane.
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.cheatsheet" });
    try t.expectEqual(id, app.active.?);
    try t.expectEqual(@as(usize, 2), app.panes.count());
    try app.render();
}

test "cheatsheet: the split walk's pair in each profile — vim the handler's Ctrl-W w / W, standard ctrl+alt+shift+→ / ←" {
    const Want = struct { profile: keymap.Profile, next: []const u8, prev: []const u8 };
    for ([_]Want{
        .{ .profile = .vim, .next = "ctrl+w w", .prev = "ctrl+w W" },
        .{ .profile = .standard, .next = "ctrl+alt+shift+right", .prev = "ctrl+alt+shift+left" },
    }) |w| {
        var st = try State.init(t.allocator, w.profile);
        defer st.deinit();
        var next: ?[]const u8 = null;
        var prev: ?[]const u8 = null;
        for (st.sections) |s| for (s.rows) |r| switch (r.cmd) {
            .@"view.focus_next_split" => next = r.chord,
            .@"view.focus_prev_split" => prev = r.chord,
            else => {},
        };
        try t.expectEqualStrings(w.next, next.?);
        try t.expectEqualStrings(w.prev, prev.?);
    }
}
