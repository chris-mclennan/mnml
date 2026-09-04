//! `Pane` — the open-thing union — and `PaneStore`, the arena that hands
//! out stable `PaneId`s. Editor, the cheatsheet and the list panes
//! (cmdline history, quickfix) today; Pty / Request / Diff / Ai are
//! additive variants later.
//!
//! // changed: WAVE3 said `editor: Buffer`; the editor pane also owns
//! its view state, find state, wrap override and syntax cache, so the
//! variant is `EditorPane` with the `Buffer` inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("../core/ids.zig");
const buffer_mod = @import("../editor/buffer.zig");
const editor_view = @import("../ui/editor_view.zig");
const find = @import("find.zig");
const syntax = @import("syntax.zig");
const cheatsheet = @import("cheatsheet.zig");

pub const PaneId = ids.PaneId;
pub const Buffer = buffer_mod.Buffer;

pub const EditorPane = struct {
    buf: Buffer,
    view: editor_view.ViewState = .{},
    find: find.FindState,
    /// Per-pane wrap; null follows the config default.
    wrap: ?bool = null,
    syntax: syntax.Syntax,
    /// Set by every path that mutates the text; the syntax cache
    /// re-parses on the next render.
    hl_dirty: bool = true,
    /// Where the visual block started (byte). The app records it when
    /// the handler enters V-BLOCK so `I` / `A` / `c` / `r` know their
    /// rectangle; the editor's own block ops are a later slice.
    block_anchor: ?usize = null,

    pub fn deinit(self: *EditorPane) void {
        self.buf.deinit();
        self.find.deinit();
        self.syntax.deinit();
    }
};

/// A read-only list with a cursor: the `:` history (`q:`) and the
/// quickfix list (`:cexpr`). Enter acts on the row by `kind`.
pub const ListPane = struct {
    pub const Kind = enum { cmdline_history, quickfix };
    pub const Entry = struct {
        /// Owned display text.
        text: []u8,
        /// Quickfix: where Enter goes. Workspace-relative, owned.
        path: ?[]u8 = null,
        line: u32 = 0,
        col: u32 = 0,
    };

    gpa: Allocator,
    kind: Kind,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *ListPane) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.text);
            if (e.path) |p| self.gpa.free(p);
        }
        self.entries.deinit(self.gpa);
    }

    pub fn title(self: *const ListPane) []const u8 {
        return switch (self.kind) {
            .cmdline_history => "cmdline history",
            .quickfix => "Quickfix",
        };
    }
};

pub const Pane = union(enum) {
    editor: EditorPane,
    cheatsheet: cheatsheet.State,
    list: ListPane,

    pub fn deinit(self: *Pane) void {
        switch (self.*) {
            .editor => |*e| e.deinit(),
            .cheatsheet => |*c| c.deinit(),
            .list => |*l| l.deinit(),
        }
    }

    /// The tab label: the file's basename, or `[scratch]`.
    pub fn title(self: *const Pane) []const u8 {
        switch (self.*) {
            .editor => |*e| return if (e.buf.path) |p| std.fs.path.basename(p) else "[scratch]",
            .cheatsheet => return "Cheatsheet",
            .list => |*l| return l.title(),
        }
    }

    pub fn dirty(self: *const Pane) bool {
        return switch (self.*) {
            .editor => |*e| e.buf.dirty,
            .cheatsheet, .list => false,
        };
    }

    pub fn asEditor(self: *Pane) ?*EditorPane {
        return switch (self.*) {
            .editor => |*e| e,
            else => null,
        };
    }
};

/// Panes by stable id. Slots freed by `remove` go on a free list and are
/// reused, so ids are dense but never shift under a live overlay.
pub const PaneStore = struct {
    gpa: Allocator,
    slots: std.ArrayListUnmanaged(?Pane) = .empty,
    free: std.ArrayListUnmanaged(PaneId) = .empty,

    pub fn init(gpa: Allocator) PaneStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *PaneStore) void {
        for (self.slots.items) |*slot| if (slot.*) |*p| p.deinit();
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
    }

    /// Takes ownership of `pane`.
    pub fn add(self: *PaneStore, pane: Pane) Allocator.Error!PaneId {
        if (self.free.pop()) |id| {
            self.slots.items[id] = pane;
            return id;
        }
        const id: PaneId = @intCast(self.slots.items.len);
        try self.slots.append(self.gpa, pane);
        return id;
    }

    pub fn get(self: *PaneStore, id: PaneId) ?*Pane {
        if (id >= self.slots.items.len) return null;
        return if (self.slots.items[id]) |*p| p else null;
    }

    pub fn editor(self: *PaneStore, id: PaneId) ?*EditorPane {
        const p = self.get(id) orelse return null;
        return p.asEditor();
    }

    pub fn remove(self: *PaneStore, id: PaneId) void {
        if (id >= self.slots.items.len) return;
        if (self.slots.items[id]) |*p| {
            p.deinit();
            self.slots.items[id] = null;
            self.free.append(self.gpa, id) catch {};
        }
    }

    /// Live panes.
    pub fn count(self: *const PaneStore) usize {
        return self.slots.items.len - self.free.items.len;
    }

    /// One past the highest id ever handed out.
    pub fn capacity(self: *const PaneStore) usize {
        return self.slots.items.len;
    }

    /// The editor pane whose file is `path`, if open.
    pub fn findPath(self: *PaneStore, path: []const u8) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .editor => |*e| if (e.buf.path) |bp| {
                    if (std.mem.eql(u8, bp, path)) return @intCast(i);
                },
                else => {},
            };
        }
        return null;
    }

    /// The one pane of `tag` (a singleton pane like the cheatsheet), if open.
    pub fn findKind(self: *PaneStore, tag: std.meta.Tag(Pane)) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| if (std.meta.activeTag(p.*) == tag) return @intCast(i);
        }
        return null;
    }
};

test "pane store: stable ids, free-list reuse, path lookup" {
    const gpa = std.testing.allocator;
    var store = PaneStore.init(gpa);
    defer store.deinit();
    const mk = struct {
        fn pane(g: Allocator, path: []const u8) !Pane {
            var buf = try Buffer.init(g, "x", .standard, .{});
            errdefer buf.deinit();
            try buf.setPath(path);
            return .{ .editor = .{ .buf = buf, .find = find.FindState.init(g), .syntax = syntax.Syntax.init(g) } };
        }
    };
    const a = try store.add(try mk.pane(gpa, "/ws/a.txt"));
    const b = try store.add(try mk.pane(gpa, "/ws/b.txt"));
    try std.testing.expectEqual(@as(PaneId, 0), a);
    try std.testing.expectEqual(@as(PaneId, 1), b);
    try std.testing.expectEqualStrings("b.txt", store.get(b).?.title());
    try std.testing.expectEqual(a, store.findPath("/ws/a.txt").?);
    store.remove(a);
    try std.testing.expect(store.get(a) == null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    const c = try store.add(try mk.pane(gpa, "/ws/c.txt"));
    try std.testing.expectEqual(a, c);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}
