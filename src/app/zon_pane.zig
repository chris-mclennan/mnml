//! The ZON view (`Pane.zon`): a `.zon` file as a tree of fields you
//! walk and edit in place, beside the raw text.
//!
//! A `.zon` file's `open` goes to the raw editor; `zon.view` (the
//! ` View as tree ` chip on that tab) opens this pane as a tab in the
//! same leaf, and `zon.source` (its ` Source ` chip, or `e`) goes back —
//! the markdown preview's tab-swap idiom, except both tabs stay.
//!
//! Every edit is the settings splice (`config/persist.splice`) on the
//! pane's working copy of the text: the value's bytes are replaced,
//! nothing else moves, so comments and field order survive. The tree
//! is re-read from the working text after each edit. A field whose
//! literal differs from the one the file had when it was opened paints
//! a `*`; Esc on it puts the opened literal back. `Ctrl+S` writes the
//! working text (`persistText`: a backup, then the file) and reloads
//! the raw editor's tab when one is open. Reordering, adding to and
//! removing from a list rewrite the whole list literal.
//!
//! Which widget a row gets is `config/zon_schema.zig`'s call: the
//! schema's for a known file, the literal's otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const config = @import("../config/root.zig");
const zon_tree = config.zon_tree;
const zon_schema = config.zon_schema;
const persist = config.persist;
const text_field = @import("../ui/text_field.zig");
const watch = @import("watch.zig");

pub const table = .{
    .@"zon.view" = &viewCmd,
    .@"zon.source" = &sourceCmd,
};

/// The bufferline chips: ` View as tree ` on a `.zon` editor,
/// ` Source ` on the tree.
pub const button_view: u32 = 0x7a6f_0001;
pub const button_source: u32 = 0x7a6f_0002;

pub const Field = zon_schema.Field;
pub const Widget = zon_schema.Widget;

/// One visible row: a node, with what the painter needs beside it.
pub const Row = struct {
    node: u32,
    field: Field,
    /// The literal differs from the file's at open.
    modified: bool,
    /// A container that is folded shut.
    collapsed: bool,
    /// `ui.theme` — the breadcrumb and the docs key.
    path: []const u8,
};

pub const EditKind = enum {
    /// A string's contents (unescaped); commits a string literal.
    string,
    /// An int / float; commits the digits as typed, checked.
    number,
    /// Any literal, checked by a parse.
    literal,
    /// A union-shaped struct's one field name.
    name,
    /// A free enum's tag.
    tag,
};

pub const Edit = struct {
    node: u32,
    kind: EditKind,
    buf: text_field.Buf = .empty,
    caret: usize = 0,
    /// The field's selection (`text_field.clickSelect`), to the caret.
    anchor: ?usize = null,
};

pub const Pick = struct {
    node: u32,
    cursor: usize,
};

pub const ZonPane = struct {
    gpa: Allocator,
    /// Owned, absolute.
    path: []u8,
    /// The working text: the file as opened, plus every edit since.
    text: [:0]u8,
    tree: ?zon_tree.Tree = null,
    /// When the working text does not parse (only a fresh open can
    /// do that — every edit is checked first).
    parse_error: ?[]u8 = null,
    schema: zon_schema.Schema = .none,
    /// The literal of every node when the file was opened, by path.
    originals: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Folded containers, by path.
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    /// Per-rebuild memory: the rows and their fields.
    arena: std.heap.ArenaAllocator,
    /// Per-open memory: the docs.
    docs_arena: std.heap.ArenaAllocator,
    docs: ?zon_schema.Docs = null,
    /// The rows as shown, rebuilt after every edit / fold / filter.
    rows: []Row = &.{},
    cursor: usize = 0,
    scroll: usize = 0,
    /// Rows the list showed last frame — paging reads it.
    rows_h: usize = 0,
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    /// The filter's selection (`text_field.clickSelect`), to the caret.
    filter_anchor: ?usize = null,
    filter_focused: bool = false,
    editing: ?Edit = null,
    picker: ?Pick = null,
    /// The working text differs from the file.
    changed: bool = false,
    /// Rebuild `rows` before the next paint.
    stale: bool = true,

    pub fn deinit(self: *ZonPane) void {
        const gpa = self.gpa;
        if (self.tree) |*tr| tr.deinit();
        if (self.parse_error) |e| gpa.free(e);
        var it = self.originals.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        self.originals.deinit(gpa);
        var ct = self.collapsed.keyIterator();
        while (ct.next()) |k| gpa.free(k.*);
        self.collapsed.deinit(gpa);
        self.filter.deinit(gpa);
        if (self.editing) |*e| e.buf.deinit(gpa);
        self.arena.deinit();
        self.docs_arena.deinit();
        gpa.free(self.text);
        gpa.free(self.path);
    }

    pub fn title(self: *const ZonPane) []const u8 {
        return std.fs.path.basename(self.path);
    }

    pub fn node(self: *const ZonPane, idx: u32) *const zon_tree.Node {
        return self.tree.?.get(idx);
    }

    /// The row under the cursor.
    pub fn current(self: *const ZonPane) ?Row {
        if (self.cursor >= self.rows.len) return null;
        return self.rows[self.cursor];
    }

    fn isCollapsed(self: *const ZonPane, path: []const u8) bool {
        return self.collapsed.contains(path);
    }

    /// Re-read the tree from the working text. On a parse failure the
    /// old tree stays and the error is kept for the painter.
    fn reparse(self: *ZonPane) Allocator.Error!void {
        var why: []const u8 = "";
        const fresh = zon_tree.parse(self.gpa, self.text, &why) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => {
                if (self.parse_error) |e| self.gpa.free(e);
                self.parse_error = @constCast(why);
                return self.rebuildRows();
            },
        };
        if (self.tree) |*old| old.deinit();
        self.tree = fresh;
        if (self.parse_error) |e| self.gpa.free(e);
        self.parse_error = null;
        return self.rebuildRows();
    }

    /// Remember every literal as the file has it now — the baseline
    /// the `*` marks and Esc read.
    fn snapshotOriginals(self: *ZonPane) Allocator.Error!void {
        var it = self.originals.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.*);
        }
        self.originals.clearRetainingCapacity();
        const tree = &(self.tree orelse return);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        for (tree.nodes, 0..) |n, i| {
            if (i == 0) continue;
            const p = try tree.pathString(scratch.allocator(), @intCast(i));
            const key = try self.gpa.dupe(u8, p);
            errdefer self.gpa.free(key);
            const val = try self.gpa.dupe(u8, n.text);
            errdefer self.gpa.free(val);
            try self.originals.put(self.gpa, key, val);
        }
        return self.rebuildRows();
    }

    /// Lay the visible rows out: a depth-first walk under the folds,
    /// narrowed by the filter (a match shows with its ancestors, and a
    /// container on the way to one opens).
    pub fn rebuildRows(self: *ZonPane) Allocator.Error!void {
        self.stale = false;
        // The cursor's path outlives the arena reset that frees the rows.
        var keep_buf: [512]u8 = undefined;
        var keep_path: ?[]const u8 = null;
        if (self.current()) |r| if (r.path.len <= keep_buf.len) {
            @memcpy(keep_buf[0..r.path.len], r.path);
            keep_path = keep_buf[0..r.path.len];
        };
        self.rows = &.{};
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        // The docs are per open, not per rebuild: they live on the gpa.
        if (self.docs == null and self.schema == .config) self.docs = try zon_schema.configDocs(self.docs_arena.allocator());
        const tree = &(self.tree orelse return);
        const n = tree.nodes.len;
        const paths = try a.alloc([]const u8, n);
        for (0..n) |i| paths[i] = try tree.pathString(a, @intCast(i));
        // Which nodes pass the filter (a match, or an ancestor of one).
        const shown = try a.alloc(bool, n);
        const filter = self.filter.items;
        if (filter.len == 0) {
            @memset(shown, true);
        } else {
            @memset(shown, false);
            for (0..n) |i| {
                if (i == 0) continue;
                if (std.ascii.indexOfIgnoreCase(paths[i], filter) == null) continue;
                var cur: ?u32 = @intCast(i);
                while (cur) |c| : (cur = tree.nodes[c].parent) shown[c] = true;
            }
        }
        var out: std.ArrayList(Row) = .empty;
        var stack: std.ArrayList(u32) = .empty;
        // Push the root's children in reverse so they pop in order.
        const root_kids = tree.nodes[0].children;
        var k = root_kids.len;
        while (k > 0) {
            k -= 1;
            try stack.append(a, root_kids[k]);
        }
        while (stack.pop()) |idx| {
            if (!shown[idx]) continue;
            const nd = &tree.nodes[idx];
            const key_path = try tree.keyPath(a, idx);
            const field = try zon_schema.fieldFor(a, self.schema, key_path, nd);
            const modified = if (self.originals.get(paths[idx])) |orig| !std.mem.eql(u8, orig, nd.text) else true;
            // A filtered walk opens every container on the way to a match.
            const collapsed = nd.kind.isContainer() and self.isCollapsed(paths[idx]) and filter.len == 0;
            try out.append(a, .{ .node = idx, .field = field, .modified = modified, .collapsed = collapsed, .path = paths[idx] });
            if (nd.kind.isContainer() and !collapsed) {
                var c = nd.children.len;
                while (c > 0) {
                    c -= 1;
                    try stack.append(a, nd.children[c]);
                }
            }
        }
        self.rows = out.items;
        // Keep the cursor on the row it was on.
        if (keep_path) |kp| {
            for (self.rows, 0..) |r, i| if (std.mem.eql(u8, r.path, kp)) {
                self.cursor = i;
                break;
            };
        }
        if (self.cursor >= self.rows.len) self.cursor = self.rows.len -| 1;
    }

    /// The doc line for the focused row: `docs/CONFIG.md`'s comment
    /// for a config key, else the type.
    pub fn docLine(self: *ZonPane, arena: Allocator, row: Row) Allocator.Error![]const u8 {
        if (self.docs) |d| if (d.get(row.path)) |line| return line;
        const f = row.field;
        if (f.widget == .@"enum" or f.widget == .@"union") {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, f.type_name);
            try out.appendSlice(arena, ": ");
            for (f.tags, 0..) |tg, i| {
                if (i > 0) try out.appendSlice(arena, " | ");
                try out.append(arena, '.');
                try out.appendSlice(arena, tg);
            }
            if (f.free_enum) try out.appendSlice(arena, " (from the file — any tag may be typed)");
            return out.items;
        }
        if (f.optional) return try std.fmt.allocPrint(arena, "?{s} — n clears it", .{f.type_name});
        return f.type_name;
    }
};

pub fn isZonPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zon");
}

// ─── open / close / the tab pair ─────────────────────────────────────────

/// The tree tab for `path`, if open.
pub fn findView(app: *App, path: []const u8) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| {
        if (slot.*) |*p| switch (p.*) {
            .zon => |*z| if (std.mem.eql(u8, z.path, path)) return @intCast(i),
            else => {},
        };
    }
    return null;
}

/// Open (or reveal) the tree of `path` as a tab in the focused leaf.
pub fn open(app: *App, path: []const u8) Allocator.Error!PaneId {
    if (findView(app, path)) |id| {
        app.showPane(id);
        return id;
    }
    const gpa = app.gpa;
    const text: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, path, gpa, .limited(config.load.max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try gpa.dupeZ(u8, ".{}\n"),
    };
    errdefer gpa.free(text);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    var pane: ZonPane = .{ .gpa = gpa, .path = owned_path, .text = text, .arena = std.heap.ArenaAllocator.init(gpa), .docs_arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer pane.deinit();
    try pane.reparse();
    if (pane.tree) |*tr| {
        const names = try tr.rootNames(app.frame.allocator());
        pane.schema = zon_schema.detect(path, names);
    }
    try pane.snapshotOriginals();
    const id = try app.panes.add(.{ .zon = pane });
    app.showPane(id);
    app.needs_render = true;
    return id;
}

/// `zon.view`: the tree of the active `.zon` editor, as a tab beside it.
fn viewCmd(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(active) orelse return error.NoActivePane;
    switch (pane.*) {
        .zon => {},
        .editor => |*e| {
            const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "not a .zon file", .{});
            if (!isZonPath(path)) return app.diag.fail(app.frame.allocator(), "not a .zon file", .{});
            if (e.buf.doc.dirty) app.toast("the tree reads the file on disk — save the editor first to see its edits", .{});
            const copy = try app.frame.allocator().dupe(u8, path);
            _ = try open(app, copy);
        },
        else => return app.diag.fail(app.frame.allocator(), "not a .zon file", .{}),
    }
}

/// `zon.source`: the raw editor of the active tree, revealed or opened.
fn sourceCmd(app: *App) CommandError!void {
    const active = app.active orelse return error.NoActivePane;
    const pane = app.panes.get(active) orelse return error.NoActivePane;
    switch (pane.*) {
        .zon => |*z| {
            const path = try app.frame.allocator().dupe(u8, z.path);
            _ = app.openEditor(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
            };
        },
        .editor => {},
        else => return error.NotAnEditor,
    }
}

// ─── edits ───────────────────────────────────────────────────────────────

/// Splice `literal` in at `key_path` of the working text and re-read
/// the tree. A result that does not parse is refused with a toast and
/// the text is left alone.
fn applyLiteral(app: *App, z: *ZonPane, key_path: []const []const u8, literal: []const u8) Allocator.Error!bool {
    const spliced = persist.splice(app.gpa, z.text, key_path, literal) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("zon: cannot edit here ({s})", .{@errorName(err)});
            return false;
        },
    } orelse return false;
    defer app.gpa.free(spliced);
    var why: []const u8 = "";
    var check = zon_tree.parse(app.gpa, try app.frame.allocator().dupeZ(u8, spliced), &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => {
            app.toast("zon: {s}", .{why});
            app.gpa.free(why);
            return false;
        },
    };
    check.deinit();
    const fresh = try app.gpa.dupeZ(u8, spliced);
    app.gpa.free(z.text);
    z.text = fresh;
    z.changed = true;
    try z.reparse();
    app.needs_render = true;
    return true;
}

fn keyPathOf(app: *App, z: *ZonPane, idx: u32) Allocator.Error![]const []const u8 {
    return z.tree.?.keyPath(app.frame.allocator(), idx);
}

/// The current tag of an enum literal or a union-shaped struct.
fn tagOf(z: *const ZonPane, idx: u32) ?[]const u8 {
    const n = z.node(idx);
    return switch (n.kind) {
        .enum_lit => n.text[1..],
        .@"struct" => if (n.children.len == 1) z.node(n.children[0]).name else null,
        else => null,
    };
}

fn tagIndex(f: Field, tag: ?[]const u8) ?usize {
    const tg = tag orelse return null;
    for (f.tags, 0..) |x, i| if (std.mem.eql(u8, x, tg)) return i;
    return null;
}

/// The literal for tag `i` of an enum / union field.
fn tagLiteral(arena: Allocator, f: Field, i: usize) Allocator.Error![]const u8 {
    if (f.widget == .@"union" and i < f.tag_literals.len) return f.tag_literals[i];
    return std.fmt.allocPrint(arena, ".{s}", .{f.tags[i]});
}

/// `←→` on a row: a bool flips, an enum cycles, a number steps, a
/// container folds / unfolds.
pub fn adjust(app: *App, id: PaneId, delta: i8) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    const arena = app.frame.allocator();
    const n = z.node(row.node);
    const kp = try keyPathOf(app, z, row.node);
    switch (row.field.widget) {
        .bool => _ = try applyLiteral(app, z, kp, if (std.mem.eql(u8, n.text, "true")) "false" else "true"),
        .@"enum", .@"union" => {
            const tags = row.field.tags;
            if (tags.len == 0) return;
            const cur = tagIndex(row.field, tagOf(z, row.node)) orelse 0;
            const next: usize = if (delta > 0) (cur + 1) % tags.len else (cur + tags.len - 1) % tags.len;
            _ = try applyLiteral(app, z, kp, try tagLiteral(arena, row.field, next));
        },
        .int => {
            const v = std.fmt.parseInt(i128, n.text, 0) catch {
                app.toast("zon: {s} is not a plain integer — Enter to type", .{n.text});
                return;
            };
            const stepped = std.math.clamp(v + delta, row.field.int_min, row.field.int_max);
            _ = try applyLiteral(app, z, kp, try std.fmt.allocPrint(arena, "{d}", .{stepped}));
        },
        .float => {
            const v = std.fmt.parseFloat(f64, n.text) catch {
                app.toast("zon: {s} is not a plain number — Enter to type", .{n.text});
                return;
            };
            _ = try applyLiteral(app, z, kp, try floatLiteral(arena, v + @as(f64, @floatFromInt(delta))));
        },
        .@"struct", .list, .union_shaped => try setFold(app, z, row, delta < 0),
        else => {},
    }
}

/// `1.0`, never `1` — a bare integer would change the literal's kind.
fn floatLiteral(arena: Allocator, v: f64) Allocator.Error![]const u8 {
    const s = try std.fmt.allocPrint(arena, "{d}", .{v});
    if (std.mem.indexOfAny(u8, s, ".eEn") != null) return s;
    return std.fmt.allocPrint(arena, "{s}.0", .{s});
}

fn setFold(app: *App, z: *ZonPane, row: Row, fold: bool) Allocator.Error!void {
    if (fold) {
        if (!z.collapsed.contains(row.path)) {
            const key = try z.gpa.dupe(u8, row.path);
            errdefer z.gpa.free(key);
            try z.collapsed.put(z.gpa, key, {});
        }
    } else if (z.collapsed.fetchRemove(row.path)) |kv| z.gpa.free(kv.key);
    try z.rebuildRows();
    app.needs_render = true;
}

fn setAllFolds(app: *App, z: *ZonPane, fold: bool) Allocator.Error!void {
    var it = z.collapsed.keyIterator();
    while (it.next()) |k| z.gpa.free(k.*);
    z.collapsed.clearRetainingCapacity();
    if (fold) {
        const tree = &(z.tree orelse return);
        var scratch = std.heap.ArenaAllocator.init(z.gpa);
        defer scratch.deinit();
        for (tree.nodes, 0..) |n, i| {
            if (i == 0 or !n.kind.isContainer()) continue;
            const p = try z.gpa.dupe(u8, try tree.pathString(scratch.allocator(), @intCast(i)));
            errdefer z.gpa.free(p);
            try z.collapsed.put(z.gpa, p, {});
        }
    }
    z.stale = true;
    app.needs_render = true;
}

/// Enter / Space / a click on the value: the widget's main verb.
pub fn activate(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    const n = z.node(row.node);
    switch (row.field.widget) {
        .bool => try adjust(app, id, 1),
        .@"enum" => {
            if (row.field.free_enum) return startEdit(app, z, row, .tag);
            try openPicker(app, z, row);
        },
        .@"union" => try openPicker(app, z, row),
        .int, .float => try startEdit(app, z, row, .number),
        .string => try startEdit(app, z, row, .string),
        .union_shaped => try startEdit(app, z, row, .name),
        .optional_null => _ = try applyLiteral(app, z, try keyPathOf(app, z, row.node), row.field.default_literal),
        .@"struct", .list => try setFold(app, z, row, !row.collapsed),
        .literal => try startEdit(app, z, row, .literal),
    }
    _ = n;
}

fn openPicker(app: *App, z: *ZonPane, row: Row) Allocator.Error!void {
    if (row.field.tags.len == 0) return;
    z.picker = .{ .node = row.node, .cursor = tagIndex(row.field, tagOf(z, row.node)) orelse 0 };
    app.needs_render = true;
}

/// The picker's choice: the tag's literal at the row.
pub fn pick(app: *App, id: PaneId, choice: usize) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const p = z.picker orelse return;
    z.picker = null;
    const row = z.current() orelse return;
    if (row.node != p.node or choice >= row.field.tags.len) return;
    const literal = try tagLiteral(app.frame.allocator(), row.field, choice);
    // The same tag on a union keeps its payload.
    if (tagIndex(row.field, tagOf(z, row.node)) == choice) return;
    _ = try applyLiteral(app, z, try keyPathOf(app, z, row.node), literal);
}

fn startEdit(app: *App, z: *ZonPane, row: Row, kind: EditKind) Allocator.Error!void {
    const n = z.node(row.node);
    var e: Edit = .{ .node = row.node, .kind = kind };
    errdefer e.buf.deinit(z.gpa);
    const seed: []const u8 = switch (kind) {
        .string => std.zig.string_literal.parseAlloc(app.frame.allocator(), n.text) catch n.text,
        .number, .literal => n.text,
        .name => z.node(n.children[0]).name,
        .tag => n.text[1..],
    };
    try e.buf.appendSlice(z.gpa, seed);
    e.caret = e.buf.items.len;
    if (z.editing) |*old| old.buf.deinit(z.gpa);
    z.editing = e;
    app.needs_render = true;
}

/// Enter in the field: check, splice, close. A bad value keeps the
/// field open with a toast.
fn commitEdit(app: *App, z: *ZonPane) Allocator.Error!void {
    var e = z.editing orelse return;
    const arena = app.frame.allocator();
    const typed = e.buf.items;
    const kp = try keyPathOf(app, z, e.node);
    const literal: []const u8 = switch (e.kind) {
        .string => try persist.serializeLiteral(arena, @as([]const u8, typed)),
        .number => blk: {
            const trimmed = std.mem.trim(u8, typed, " \t");
            if (std.fmt.parseInt(i128, trimmed, 0)) |_| break :blk trimmed else |_| {}
            if (std.fmt.parseFloat(f64, trimmed)) |_| break :blk trimmed else |_| {}
            app.toast("zon: `{s}` is not a number", .{trimmed});
            return;
        },
        .literal => std.mem.trim(u8, typed, " \t"),
        .name => blk: {
            const name = std.mem.trim(u8, typed, " \t");
            if (name.len == 0) {
                app.toast("zon: a field needs a name", .{});
                return;
            }
            const payload = z.node(z.node(e.node).children[0]).text;
            break :blk try std.fmt.allocPrint(arena, ".{{ .{s} = {s} }}", .{ try identLiteral(arena, name), payload });
        },
        .tag => blk: {
            const name = std.mem.trim(u8, typed, " \t");
            if (name.len == 0) {
                app.toast("zon: a tag needs a name", .{});
                return;
            }
            break :blk try std.fmt.allocPrint(arena, ".{s}", .{try identLiteral(arena, name)});
        },
    };
    if (literal.len == 0) {
        app.toast("zon: an empty literal", .{});
        return;
    }
    // A refused splice (the text would not parse) keeps the field open.
    const ok = try applyLiteral(app, z, kp, literal);
    const same = !ok and std.mem.eql(u8, z.node(e.node).text, literal);
    if (!ok and !same) return;
    e.buf.deinit(z.gpa);
    z.editing = null;
    app.needs_render = true;
}

/// A bare identifier when it can be one, `@"…"` otherwise.
fn identLiteral(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.zig.isValidId(name)) return name;
    return std.fmt.allocPrint(arena, "@\"{s}\"", .{name});
}

fn cancelEdit(app: *App, z: *ZonPane) void {
    if (z.editing) |*e| e.buf.deinit(z.gpa);
    z.editing = null;
    app.needs_render = true;
}

/// Esc on a modified field: the opened literal comes back. A list
/// element the file did not have is removed.
pub fn revert(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    if (!row.modified) return;
    if (z.originals.get(row.path)) |orig| {
        const copy = try app.frame.allocator().dupe(u8, orig);
        _ = try applyLiteral(app, z, try keyPathOf(app, z, row.node), copy);
        return;
    }
    if (z.node(row.node).isListElement()) return removeElement(app, z, row);
}

// ─── lists ───────────────────────────────────────────────────────────────

/// The list a row belongs to (the row itself, or its parent when the
/// row is an element) and the element's position in it.
fn listOf(z: *const ZonPane, row: Row) ?struct { list: u32, at: ?usize } {
    const n = z.node(row.node);
    if (n.isListElement()) return .{ .list = n.parent.?, .at = n.index.? };
    if (row.field.widget == .list or n.kind == .list) return .{ .list = row.node, .at = null };
    return null;
}

/// Write `elements` over the list at `list_idx`, keeping its layout.
fn writeList(app: *App, z: *ZonPane, list_idx: u32, elements: []const []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const n = z.node(list_idx);
    const multiline = std.mem.indexOfScalar(u8, n.text, '\n') != null;
    const indent: []const u8 = if (n.children.len > 0)
        persist.lineIndent(z.text, z.node(n.children[0]).span.start)
    else
        try std.mem.concat(arena, u8, &.{ persist.lineIndent(z.text, n.span.start), "    " });
    const literal = try persist.listLiteral(arena, elements, multiline, indent);
    _ = try applyLiteral(app, z, try keyPathOf(app, z, list_idx), literal);
}

fn elementTexts(arena: Allocator, z: *const ZonPane, list_idx: u32) Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    for (z.node(list_idx).children) |c| try out.append(arena, z.node(c).text);
    return out;
}

/// `+`: a new element after the row's (at the end on the list row).
/// A schema list gets its element type's default; an unknown one a
/// copy of the last element, so the shape carries.
pub fn addElement(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    const at = listOf(z, row) orelse {
        app.toast("zon: not a list — `+` adds a list element", .{});
        return;
    };
    const arena = app.frame.allocator();
    var elems = try elementTexts(arena, z, at.list);
    const list_row = try keyPathOf(app, z, at.list);
    const list_field = zon_schema.lookup(z.schema, list_row);
    const fresh: []const u8 = if (list_field) |f| f.elem_default else if (elems.items.len > 0) elems.items[elems.items.len - 1] else "\"\"";
    const pos = if (at.at) |i| i + 1 else elems.items.len;
    try elems.insert(arena, pos, fresh);
    const list_path = try z.tree.?.pathString(arena, at.list);
    try writeList(app, z, at.list, elems.items);
    // Land on the new element, unfolded.
    if (z.collapsed.fetchRemove(list_path)) |kv| z.gpa.free(kv.key);
    try z.rebuildRows();
    const want = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ list_path, pos });
    for (z.rows, 0..) |r, i| if (std.mem.eql(u8, r.path, want)) {
        z.cursor = i;
    };
}

fn removeElement(app: *App, z: *ZonPane, row: Row) Allocator.Error!void {
    const at = listOf(z, row) orelse return;
    const i = at.at orelse {
        app.toast("zon: `x` removes a list element — move onto one", .{});
        return;
    };
    const arena = app.frame.allocator();
    var elems = try elementTexts(arena, z, at.list);
    _ = elems.orderedRemove(i);
    try writeList(app, z, at.list, elems.items);
}

/// `x` on an element.
pub fn removeCurrent(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    try removeElement(app, z, row);
}

/// `J` / `K`: the element swaps with its neighbour; the cursor rides.
pub fn moveElement(app: *App, id: PaneId, delta: i8) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    const at = listOf(z, row) orelse return;
    const i = at.at orelse return;
    const arena = app.frame.allocator();
    var elems = try elementTexts(arena, z, at.list);
    const j: usize = if (delta > 0) i + 1 else i -| 1;
    if (j == i or j >= elems.items.len) return;
    std.mem.swap([]const u8, &elems.items[i], &elems.items[j]);
    const list_path = try z.tree.?.pathString(arena, at.list);
    try writeList(app, z, at.list, elems.items);
    try z.rebuildRows();
    const want = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ list_path, j });
    for (z.rows, 0..) |r, k| if (std.mem.eql(u8, r.path, want)) {
        z.cursor = k;
    };
}

// ─── save / reload ───────────────────────────────────────────────────────

/// `Ctrl+S` / `file.save`: the working text to disk with a backup,
/// the baseline reset, and the raw editor's tab (when open) re-read.
pub fn save(app: *App, id: PaneId) CommandError!void {
    const z = app.panes.get(id).?.asZon() orelse return error.NotAnEditor;
    const arena = app.frame.allocator();
    if (z.parse_error) |e| return app.diag.fail(arena, "zon: not saving a file that does not parse ({s})", .{e});
    const outcome = persist.persistText(app.gpa, app.io, z.path, z.text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "save failed: {s}: {s}", .{ app.relPath(z.path), @errorName(err) }),
    };
    z.changed = false;
    try z.snapshotOriginals();
    if (outcome == .written) {
        app.toast("saved {s}", .{app.relPath(z.path)});
        if (app.panes.findPath(z.path)) |eid| watch.reload(app, eid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => app.toast("zon: the editor tab did not reload: {s}", .{@errorName(err)}),
        };
    }
    app.needs_render = true;
}

/// `r`: the file as it is on disk, unless edits would be lost.
pub fn reload(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    if (z.changed) {
        app.toast("zon: unsaved edits — Ctrl+S keeps them, Esc on a row drops one", .{});
        return;
    }
    const text: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, z.path, app.gpa, .limited(config.load.max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("zon: cannot read {s}", .{app.relPath(z.path)});
            return;
        },
    };
    app.gpa.free(z.text);
    z.text = text;
    try z.reparse();
    try z.snapshotOriginals();
    app.toast("reloaded {s}", .{app.relPath(z.path)});
    app.needs_render = true;
}

// ─── keys ────────────────────────────────────────────────────────────────

fn moveCursor(app: *App, z: *ZonPane, delta: isize) void {
    if (z.rows.len == 0) return;
    const cur: isize = @intCast(z.cursor);
    const max: isize = @intCast(z.rows.len - 1);
    z.cursor = @intCast(std.math.clamp(cur + delta, 0, max));
    z.picker = null;
    app.needs_render = true;
}

/// The pane's keys. True when taken; a chord the pane does not know
/// falls through to the keymap.
pub fn handleKey(app: *App, id: PaneId, k: Key) Allocator.Error!bool {
    const pane = app.panes.get(id) orelse return false;
    const z = pane.asZon() orelse return false;
    if (z.stale) try z.rebuildRows();
    // The one chord that is the pane's in every profile.
    if (k.mods.ctrl and !k.mods.alt and !k.mods.super and k.code == .char and k.code.char == 's') {
        save(app, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
        };
        return true;
    }
    if (z.editing != null) return editKey(app, z, k);
    if (z.picker != null) return pickerKey(app, id, z, k);
    if (z.filter_focused) return filterKey(app, z, k);
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const page: isize = @intCast(@max(z.rows_h, 1));
    switch (k.code) {
        .down => moveCursor(app, z, 1),
        .up => moveCursor(app, z, -1),
        .page_down => moveCursor(app, z, page),
        .page_up => moveCursor(app, z, -page),
        .home => moveCursor(app, z, -@as(isize, @intCast(z.cursor))),
        .end => moveCursor(app, z, @intCast(z.rows.len)),
        .left => try adjust(app, id, -1),
        .right => try adjust(app, id, 1),
        .enter => try activate(app, id),
        .esc => {
            if (z.current()) |r| if (r.modified) {
                try revert(app, id);
                return true;
            };
            if (z.filter.items.len > 0) {
                z.filter.clearRetainingCapacity();
                z.filter_caret = 0;
                z.filter_anchor = null;
                z.stale = true;
                app.needs_render = true;
                return true;
            }
            return false;
        },
        .char => |c| switch (c) {
            'j' => moveCursor(app, z, 1),
            'k' => moveCursor(app, z, -1),
            'g' => moveCursor(app, z, -@as(isize, @intCast(z.cursor))),
            'G' => moveCursor(app, z, @intCast(z.rows.len)),
            'h' => try adjust(app, id, -1),
            'l' => try adjust(app, id, 1),
            ' ' => try activate(app, id),
            '+' => try addElement(app, id),
            'x' => try removeCurrent(app, id),
            'J' => try moveElement(app, id, 1),
            'K' => try moveElement(app, id, -1),
            'n' => try clearOptional(app, id),
            'E' => try setAllFolds(app, z, false),
            'C' => try setAllFolds(app, z, true),
            'e' => sourceCmd(app) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            },
            'r' => try reload(app, id),
            '/' => {
                z.filter_focused = true;
                app.needs_render = true;
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

/// `n`: an optional field back to `null`.
fn clearOptional(app: *App, id: PaneId) Allocator.Error!void {
    const z = app.panes.get(id).?.asZon() orelse return;
    const row = z.current() orelse return;
    if (!row.field.optional or z.node(row.node).kind == .null) return;
    _ = try applyLiteral(app, z, try keyPathOf(app, z, row.node), "null");
}

fn editKey(app: *App, z: *ZonPane, k: Key) Allocator.Error!bool {
    const e = &z.editing.?;
    switch (k.code) {
        .esc => cancelEdit(app, z),
        .enter => try commitEdit(app, z),
        else => switch (try text_field.editKey(&e.buf, &e.caret, &e.anchor, z.gpa, k)) {
            .ignored => return false,
            .moved, .changed => app.needs_render = true,
        },
    }
    return true;
}

fn pickerKey(app: *App, id: PaneId, z: *ZonPane, k: Key) Allocator.Error!bool {
    const p = &z.picker.?;
    const row = z.current() orelse {
        z.picker = null;
        return true;
    };
    const n = row.field.tags.len;
    switch (k.code) {
        .esc => z.picker = null,
        .enter => try pick(app, id, p.cursor),
        .down => p.cursor = (p.cursor + 1) % @max(n, 1),
        .up => p.cursor = (p.cursor + n -| 1) % @max(n, 1),
        .char => |c| switch (c) {
            'j' => p.cursor = (p.cursor + 1) % @max(n, 1),
            'k' => p.cursor = (p.cursor + n -| 1) % @max(n, 1),
            ' ' => try pick(app, id, p.cursor),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// Type-to-narrow: the filter takes every key while it has focus.
fn filterKey(app: *App, z: *ZonPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => {
            if (z.filter.items.len > 0) {
                z.filter.clearRetainingCapacity();
                z.filter_caret = 0;
                z.filter_anchor = null;
                z.stale = true;
            } else z.filter_focused = false;
        },
        .enter, .down, .up => {
            z.filter_focused = false;
            if (k.code == .down) moveCursor(app, z, 1);
            if (k.code == .up) moveCursor(app, z, -1);
        },
        else => switch (try text_field.editKey(&z.filter, &z.filter_caret, &z.filter_anchor, z.gpa, k)) {
            .ignored => return false,
            .moved => {},
            .changed => {
                z.stale = true;
                z.cursor = 0;
            },
        },
    }
    app.needs_render = true;
    return true;
}

/// A paste lands in the open field or the filter.
pub fn paste(app: *App, z: *ZonPane, text: []const u8) Allocator.Error!void {
    if (z.editing) |*e| {
        try text_field.insertSel(&e.buf, &e.caret, &e.anchor, z.gpa, text);
    } else if (z.filter_focused) {
        try text_field.insertSel(&z.filter, &z.filter_caret, &z.filter_anchor, z.gpa, text);
        z.stale = true;
    } else return;
    app.needs_render = true;
}

// ─── mouse ───────────────────────────────────────────────────────────────

pub const Hit = struct {
    pub const row_limit: u32 = 0x1000_0000;
    /// `option_base + row * option_stride + i`: option `i` of a row.
    pub const option_base: u32 = 0x1000_0000;
    pub const option_stride: u32 = 64;
    pub const dec_base: u32 = 0x2000_0000;
    pub const inc_base: u32 = 0x2100_0000;
    /// The value cell: the row's main verb.
    pub const value_base: u32 = 0x2200_0000;
    pub const del_base: u32 = 0x2300_0000;
    pub const add_base: u32 = 0x2400_0000;
    pub const crumb_base: u32 = 0x3000_0000;
    pub const body: u32 = 0x4000_0000;
    pub const filter: u32 = 0x4000_0001;
    /// The open text field over a value cell: a press stays in it.
    pub const field: u32 = 0x4000_0002;
    pub const pick_base: u32 = 0x5000_0000;

    pub const Kind = union(enum) {
        row: usize,
        option: struct { row: usize, index: usize },
        dec: usize,
        inc: usize,
        value: usize,
        del: usize,
        add: usize,
        crumb: usize,
        body,
        filter,
        field,
        pick: usize,
    };

    pub fn decode(id: u32) Kind {
        if (id < row_limit) return .{ .row = id };
        if (id < dec_base) {
            const rel = id - option_base;
            return .{ .option = .{ .row = rel / option_stride, .index = rel % option_stride } };
        }
        if (id < inc_base) return .{ .dec = id - dec_base };
        if (id < value_base) return .{ .inc = id - inc_base };
        if (id < del_base) return .{ .value = id - value_base };
        if (id < add_base) return .{ .del = id - del_base };
        if (id < crumb_base) return .{ .add = id - add_base };
        if (id < body) return .{ .crumb = id - crumb_base };
        if (id == body) return .body;
        if (id == filter) return .filter;
        if (id == field) return .field;
        return .{ .pick = id - pick_base };
    }
};

pub const Mouse = key_mod.Mouse;

/// A press on one of the pane's targets. Left on a row focuses it; on
/// its value cell, chip or arrow it acts. Right on a row focuses it
/// and, for an enum / union, lists the choices.
pub fn click(app: *App, id: PaneId, z: *ZonPane, hit: u32, m: Mouse) Allocator.Error!void {
    if (z.stale) try z.rebuildRows();
    const right = m.button == .right;
    const focusRow = struct {
        fn f(zz: *ZonPane, row: usize) bool {
            if (row >= zz.rows.len) return false;
            zz.cursor = row;
            zz.picker = null;
            return true;
        }
    }.f;
    // A press in the open field keeps editing: it moves the caret or
    // selects (`dispatch.fieldPress`). Anywhere else ends the edit.
    if (Hit.decode(hit) == .field) return;
    if (z.editing != null) cancelEdit(app, z);
    z.filter_focused = false;
    switch (Hit.decode(hit)) {
        .row => |r| {
            if (!focusRow(z, r)) return;
            if (right) switch (z.rows[r].field.widget) {
                .@"enum", .@"union" => try openPicker(app, z, z.rows[r]),
                .bool => try adjust(app, id, 1),
                else => {},
            };
        },
        .value => |r| {
            if (!focusRow(z, r)) return;
            if (right) return click(app, id, z, @intCast(r), m);
            try activate(app, id);
        },
        .option => |o| {
            if (!focusRow(z, o.row)) return;
            const row = z.rows[o.row];
            switch (row.field.widget) {
                .bool => {
                    const want_true = o.index == 0;
                    if (std.mem.eql(u8, z.node(row.node).text, "true") != want_true) try adjust(app, id, 1);
                },
                .@"enum", .@"union" => {
                    if (o.index >= row.field.tags.len) return;
                    if (tagIndex(row.field, tagOf(z, row.node)) == o.index) return;
                    _ = try applyLiteral(app, z, try keyPathOf(app, z, row.node), try tagLiteral(app.frame.allocator(), row.field, o.index));
                },
                else => {},
            }
        },
        .dec => |r| if (focusRow(z, r)) try adjust(app, id, -1),
        .inc => |r| if (focusRow(z, r)) try adjust(app, id, 1),
        .del => |r| if (focusRow(z, r)) try removeCurrent(app, id),
        .add => |r| if (focusRow(z, r)) try addElement(app, id),
        .crumb => |i| {
            // The i-th ancestor of the focused row (0 = the file itself).
            const row = z.current() orelse return;
            var chain: std.ArrayList(u32) = .empty;
            var cur: ?u32 = row.node;
            while (cur) |c| : (cur = z.node(c).parent) {
                if (z.node(c).parent == null) break;
                try chain.append(app.frame.allocator(), c);
            }
            // chain is leaf-first; crumb 1 is the outermost.
            if (i == 0 or i > chain.items.len) return;
            const target = chain.items[chain.items.len - i];
            for (z.rows, 0..) |rr, k| if (rr.node == target) {
                z.cursor = k;
            };
        },
        .filter => z.filter_focused = true,
        .body, .field => {},
        .pick => |i| if (!right) try pick(app, id, i),
    }
    app.needs_render = true;
}

pub fn wheel(app: *App, z: *ZonPane, down: bool, n: usize) void {
    const max = z.rows.len -| @max(z.rows_h, 1);
    z.scroll = if (down) @min(z.scroll + n, max) else z.scroll -| n;
    app.needs_render = true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,
    path: []u8,

    fn init(name: []const u8, data: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDirPath(testing.io, ".mnml");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 100, .rows = 24 });
        errdefer app.deinit();
        app.tree.visible = false;
        const path = try std.fs.path.join(testing.allocator, &.{ root, name });
        return .{ .tmp = tmp, .root = root, .app = app, .path = path };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.path);
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn zon(f: *Fixture) *ZonPane {
        return f.app.panes.get(f.app.active.?).?.asZon().?;
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return screen_mod.toTestText(testing.allocator, &f.app.screen);
    }

    fn key(f: *Fixture, k: Key) !void {
        try f.app.handle(.{ .key = k });
    }

    fn disk(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
    }

    /// Put the cursor on the row whose path is `path`.
    fn goto(f: *Fixture, path: []const u8) !void {
        const z = f.zon();
        if (z.stale) try z.rebuildRows();
        for (z.rows, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) {
            z.cursor = i;
            return;
        };
        return error.NoSuchRow;
    }
};

const config_fixture =
    \\// my config
    \\.{
    \\    .editor = .{
    \\        .input_style = .standard, // the profile
    \\        .tab_width = 4,
    \\        .breadcrumb = true,
    \\    },
    \\    .ui = .{
    \\        .theme = "onedark",
    \\        .md_preview_engine = .builtin,
    \\        .todo_keywords = .{ "TODO", "FIXME" },
    \\    },
    \\    .startup = .{ .default_workspace = null },
    \\    .workspaces = .{
    \\        .{ .name = "a", .path = "/a" },
    \\        .{ .name = "b", .path = "/b" },
    \\    },
    \\}
    \\
;

test "zon.view opens the tree beside the editor; both tabs stay; zon.source goes back" {
    var f = try Fixture.init(".mnml/config.zon", config_fixture);
    defer f.deinit();
    const eid = try f.app.openPath(f.path);
    try testing.expect(f.app.panes.get(eid).?.* == .editor);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const vid = f.app.active.?;
    try testing.expect(vid != eid);
    try testing.expect(f.app.panes.get(vid).?.* == .zon);
    try testing.expectEqual(@as(usize, 2), f.app.panes.count());
    const z = f.zon();
    try testing.expectEqual(zon_schema.Schema.config, z.schema);
    const text = try f.screen();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "input_style") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[standard]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Source") != null);
    // back to the editor: the same tab, not a third
    try command.run(&f.app, .{ .static = .@"zon.source" });
    try testing.expectEqual(eid, f.app.active.?);
    try testing.expectEqual(@as(usize, 2), f.app.panes.count());
    // and the editor's chip / command leads back to the same tree
    try command.run(&f.app, .{ .static = .@"zon.view" });
    try testing.expectEqual(vid, f.app.active.?);
    try testing.expectEqual(@as(usize, 2), f.app.panes.count());
}

test "a bool toggles, an enum cycles and picks, a number steps, a string edits inline — each a splice that keeps the comment" {
    var f = try Fixture.init(".mnml/config.zon", config_fixture);
    defer f.deinit();
    _ = try f.app.openPath(f.path);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const z = f.zon();
    // bool
    try f.goto("editor.breadcrumb");
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".breadcrumb = false,") != null);
    try testing.expect(z.changed);
    try testing.expect(z.current().?.modified);
    try testing.expect(f.app.panes.get(f.app.active.?).?.* == .zon);
    try testing.expect(f.app.panes.get(f.app.active.?).?.dirty());
    // enum: → cycles, Enter opens the picker, j + Enter picks
    try f.goto("editor.input_style");
    try f.key(Key.named(.right));
    try testing.expect(std.mem.indexOf(u8, z.text, ".input_style = .vim, // the profile") != null);
    try f.key(Key.named(.enter));
    try testing.expect(z.picker != null);
    const shown = try f.screen();
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "standard") != null);
    try f.key(Key.char('j'));
    try f.key(Key.named(.enter));
    try testing.expect(z.picker == null);
    try testing.expect(std.mem.indexOf(u8, z.text, ".input_style = .standard, // the profile") != null);
    try testing.expect(!z.current().?.modified);
    // int: ← steps down, Enter types
    try f.goto("editor.tab_width");
    try f.key(Key.named(.left));
    try testing.expect(std.mem.indexOf(u8, z.text, ".tab_width = 3,") != null);
    try f.key(Key.named(.enter));
    try testing.expect(z.editing != null);
    try f.key(Key.named(.backspace));
    try f.key(Key.char('8'));
    try f.key(Key.named(.enter));
    try testing.expect(z.editing == null);
    try testing.expect(std.mem.indexOf(u8, z.text, ".tab_width = 8,") != null);
    // a bad number keeps the field open
    try f.key(Key.named(.enter));
    try f.key(Key.char('x'));
    try f.key(Key.named(.enter));
    try testing.expect(z.editing != null);
    try f.key(Key.named(.esc));
    try testing.expect(z.editing == null);
    try testing.expect(std.mem.indexOf(u8, z.text, ".tab_width = 8,") != null);
    // string: the field seeds with the unescaped text; arrows and typing work
    try f.goto("ui.theme");
    try f.key(Key.named(.enter));
    try testing.expectEqualStrings("onedark", z.editing.?.buf.items);
    try f.key(Key.named(.home));
    try f.key(Key.char('x'));
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".theme = \"xonedark\",") != null);
    // Esc on the modified row reverts it
    try f.key(Key.named(.esc));
    try testing.expect(std.mem.indexOf(u8, z.text, ".theme = \"onedark\",") != null);
    try testing.expect(!z.current().?.modified);
    // the comment at the top and the one after the enum survived it all
    try testing.expect(std.mem.startsWith(u8, z.text, "// my config\n"));
    try testing.expect(std.mem.indexOf(u8, z.text, "// the profile") != null);
}

test "a union swaps its tag and its payload widget; an optional sets and clears; a list adds, reorders and removes" {
    var f = try Fixture.init(".mnml/config.zon", config_fixture);
    defer f.deinit();
    _ = try f.app.openPath(f.path);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const z = f.zon();
    // union: the picker lists the tags; custom takes a string payload
    try f.goto("ui.md_preview_engine");
    try testing.expectEqual(Widget.@"union", z.current().?.field.widget);
    try f.key(Key.named(.enter));
    try f.key(Key.char('G'));
    try f.key(Key.char('j'));
    try f.key(Key.char('j'));
    try f.key(Key.char('j'));
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".md_preview_engine = .{ .custom = \"\" },") != null);
    try z.rebuildRows();
    try f.goto("ui.md_preview_engine.custom");
    try testing.expectEqual(Widget.string, z.current().?.field.widget);
    try f.key(Key.named(.enter));
    try f.key(Key.char('g'));
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".md_preview_engine = .{ .custom = \"g\" },") != null);
    // back to a bare tag by ←
    try f.goto("ui.md_preview_engine");
    try f.key(Key.named(.left));
    try testing.expect(std.mem.indexOf(u8, z.text, ".md_preview_engine = .pandoc,") != null);
    // optional: set… writes the default, n clears it
    try f.goto("startup.default_workspace");
    try testing.expectEqual(Widget.optional_null, z.current().?.field.widget);
    try f.key(Key.char(' '));
    try testing.expect(std.mem.indexOf(u8, z.text, ".default_workspace = \"\" }") != null);
    try testing.expectEqual(Widget.string, z.current().?.field.widget);
    try f.key(Key.char('n'));
    try testing.expect(std.mem.indexOf(u8, z.text, ".default_workspace = null }") != null);
    // list of strings: + after the first, J moves it down, x removes it
    try f.goto("ui.todo_keywords[0]");
    try f.key(Key.char('+'));
    try testing.expect(std.mem.indexOf(u8, z.text, ".todo_keywords = .{ \"TODO\", \"\", \"FIXME\" },") != null);
    try testing.expectEqualStrings("ui.todo_keywords[1]", z.current().?.path);
    try f.key(Key.char('J'));
    try testing.expect(std.mem.indexOf(u8, z.text, ".todo_keywords = .{ \"TODO\", \"FIXME\", \"\" },") != null);
    try testing.expectEqualStrings("ui.todo_keywords[2]", z.current().?.path);
    try f.key(Key.char('x'));
    try testing.expect(std.mem.indexOf(u8, z.text, ".todo_keywords = .{ \"TODO\", \"FIXME\" },") != null);
    // list of structs, laid out one per line: + keeps the layout, the
    // new element is the schema's default struct
    try f.goto("workspaces");
    try f.key(Key.char('+'));
    try testing.expect(std.mem.indexOf(u8, z.text, "        .{ .name = \"b\", .path = \"/b\" },\n        .{},\n    },") != null);
    try testing.expectEqualStrings("workspaces[2]", z.current().?.path);
    // Esc on the element the file did not have removes it
    try f.key(Key.named(.esc));
    try testing.expect(std.mem.indexOf(u8, z.text, ".{},") == null);
    try testing.expect(std.mem.indexOf(u8, z.text, "        .{ .name = \"b\", .path = \"/b\" },\n    },") != null);
}

test "Ctrl+S writes the working text with the comments intact and reloads the editor tab; r re-reads the disk" {
    var f = try Fixture.init(".mnml/config.zon", config_fixture);
    defer f.deinit();
    const eid = try f.app.openPath(f.path);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const z = f.zon();
    try f.goto("editor.breadcrumb");
    try f.key(Key.named(.enter));
    const before = try f.disk(".mnml/config.zon");
    defer testing.allocator.free(before);
    try testing.expect(std.mem.indexOf(u8, before, ".breadcrumb = true,") != null);
    try f.key(Key.ctrl('s'));
    const after = try f.disk(".mnml/config.zon");
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, ".breadcrumb = false,") != null);
    try testing.expect(std.mem.indexOf(u8, after, "// the profile") != null);
    try testing.expect(std.mem.startsWith(u8, after, "// my config\n"));
    try testing.expect(!z.changed);
    try testing.expect(!z.current().?.modified);
    // the editor tab shows the written text, clean
    const e = f.app.panes.editor(eid).?;
    try testing.expect(std.mem.indexOf(u8, e.buf.editor.bytes(), ".breadcrumb = false,") != null);
    try testing.expect(!e.buf.doc.dirty);
    // a backup was made beside the file
    try f.tmp.dir.access(testing.io, ".mnml/backups", .{});
    // r with no edits re-reads what is on disk
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .editor = .{ .tab_width = 9 } }\n" });
    try f.key(Key.char('r'));
    try testing.expect(std.mem.indexOf(u8, z.text, ".tab_width = 9") != null);
    // file.save on the pane is the same write
    try f.goto("editor.tab_width");
    try f.key(Key.named(.right));
    try command.run(&f.app, .{ .static = .@"file.save" });
    const third = try f.disk(".mnml/config.zon");
    defer testing.allocator.free(third);
    try testing.expect(std.mem.indexOf(u8, third, ".tab_width = 10") != null);
}

test "an unknown file infers its widgets: a one-choice enum types a tag, a one-field struct renames its field; the filter narrows by path" {
    var f = try Fixture.init("thing.zon",
        \\.{
        \\    .mode = .fast,
        \\    .engine = .{ .custom = "glow" },
        \\    .deep = .{ .inner = .{ .flag = true } },
        \\}
        \\
    );
    defer f.deinit();
    _ = try f.app.openPath(f.path);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const z = f.zon();
    try testing.expectEqual(zon_schema.Schema.none, z.schema);
    try f.goto("mode");
    try testing.expect(z.current().?.field.free_enum);
    try f.key(Key.named(.enter));
    try testing.expectEqualStrings("fast", z.editing.?.buf.items);
    try f.key(Key.ctrl('u'));
    try f.key(Key.char('s'));
    try f.key(Key.char('l'));
    try f.key(Key.char('o'));
    try f.key(Key.char('w'));
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".mode = .slow,") != null);
    try f.goto("engine");
    try testing.expectEqual(Widget.union_shaped, z.current().?.field.widget);
    try f.key(Key.named(.enter));
    try testing.expectEqualStrings("custom", z.editing.?.buf.items);
    try f.key(Key.ctrl('u'));
    try f.key(Key.char('g'));
    try f.key(Key.char('l'));
    try f.key(Key.char('o'));
    try f.key(Key.char('w'));
    try f.key(Key.named(.enter));
    try testing.expect(std.mem.indexOf(u8, z.text, ".engine = .{ .glow = \"glow\" },") != null);
    // the filter: / focuses, typing narrows to the path, ancestors stay
    try f.key(Key.char('/'));
    try testing.expect(z.filter_focused);
    try f.key(Key.char('f'));
    try f.key(Key.char('l'));
    try f.key(Key.char('a'));
    try z.rebuildRows();
    try testing.expectEqual(@as(usize, 3), z.rows.len);
    try testing.expectEqualStrings("deep", z.rows[0].path);
    try testing.expectEqualStrings("deep.inner.flag", z.rows[2].path);
    const shown = try f.screen();
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "fla") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "engine") == null);
    try f.key(Key.named(.esc));
    try z.rebuildRows();
    try testing.expectEqual(@as(usize, 6), z.rows.len);
    try testing.expect(z.filter_focused);
    try f.key(Key.named(.esc));
    try testing.expect(!z.filter_focused);
    // folds: C shuts every container, l opens the one under the cursor
    try f.key(Key.char('C'));
    try z.rebuildRows();
    try testing.expectEqual(@as(usize, 3), z.rows.len);
    try f.goto("deep");
    try f.key(Key.char('l'));
    try z.rebuildRows();
    try testing.expectEqual(@as(usize, 4), z.rows.len);
    try f.key(Key.char('E'));
    try z.rebuildRows();
    try testing.expectEqual(@as(usize, 6), z.rows.len);
}

test "a file that does not parse opens with the error and never writes" {
    var f = try Fixture.init("bad.zon", ".{ .a = \n");
    defer f.deinit();
    _ = try f.app.openPath(f.path);
    try command.run(&f.app, .{ .static = .@"zon.view" });
    const z = f.zon();
    try testing.expect(z.parse_error != null);
    const shown = try f.screen();
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "does not parse") != null);
    try f.key(Key.ctrl('s'));
    const disk = try f.disk("bad.zon");
    defer testing.allocator.free(disk);
    try testing.expectEqualStrings(".{ .a = \n", disk);
}
