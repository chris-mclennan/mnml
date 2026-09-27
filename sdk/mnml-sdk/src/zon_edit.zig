//! Editing a ZON file in place — an AST-guided splice, not a serializer
//! round-trip. It lives in the SDK because both sides of mnml write ZON
//! the same way: the host saves `config.zon` from its settings and ZON
//! panes, and an integration saves its own `config.zon` from a pane of
//! its own. One implementation, so a hand-written file survives a save
//! identically wherever the save came from.
//!
//! `persistScalar(path, key_path, literal)` parses the file, walks the
//! struct literals by field name, and replaces the value's byte span. A
//! field that is missing is inserted before its section's `}` with the
//! section's indent; a section that is missing is appended before the
//! top-level `}`. Comments and ordering survive because nothing outside
//! the edited span is touched. An unchanged value is a no-op — no write,
//! no backup.
//!
//! `splice` is the pure core (text in, text out); `persistScalar` wraps
//! it with the read, the backup to `<root>/backups/config.<ts>.zon`
//! (pruned to `max_backups`), and the write.
//!
//! // changed (zon-view): a key of the form `[i]` steps into the i-th
//! element of a list literal (`.workspaces`, `[1]`, `group`), so the
//! ZON view pane can edit a field inside a list element or swap a
//! union's payload in place. `persistText` is the same backup + write
//! for a whole file the pane has already spliced.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const max_backups = 50;
pub const backups_dir = "backups";
const indent_unit = "    ";

pub const SpliceError = error{
    OutOfMemory,
    /// The file does not parse; refusing to guess where to write.
    ParseFailed,
    /// A key on the path names something that is not a `.{ … }`.
    NotAStruct,
    /// A `[i]` key on something that is not a list literal.
    NotAList,
    /// A `[i]` key past the list's end.
    NoSuchElement,
    /// The top level is not a struct literal.
    NoRoot,
    EmptyKeyPath,
};

/// The new text, or null when `key_path` already holds `literal`.
pub fn splice(gpa: Allocator, text: [:0]const u8, key_path: []const []const u8, literal: []const u8) SpliceError!?[]u8 {
    if (key_path.len == 0) return error.EmptyKeyPath;
    var ast = try Ast.parse(gpa, text, .zon);
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) return error.ParseFailed;
    const root = ast.rootDecls()[0];

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const changed = try walk(gpa, scratch.allocator(), ast, root, key_path, literal, &edits);
    if (!changed) return null;
    return try applyEdits(gpa, text, edits.items);
}

const Edit = struct { start: usize, end: usize, text: []const u8 };

fn applyEdits(gpa: Allocator, text: []const u8, edits: []Edit) Allocator.Error![]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    for (edits) |e| {
        try out.appendSlice(gpa, text[pos..e.start]);
        try out.appendSlice(gpa, e.text);
        pos = e.end;
    }
    try out.appendSlice(gpa, text[pos..]);
    return out.toOwnedSlice(gpa);
}

/// Returns whether anything needs to change.
fn walk(gpa: Allocator, arena: Allocator, ast: Ast, node: Ast.Node.Index, keys: []const []const u8, literal: []const u8, edits: *std.ArrayList(Edit)) SpliceError!bool {
    const key = keys[0];
    var buf: [2]Ast.Node.Index = undefined;
    if (isIndexKey(key)) {
        // `[i]`: the i-th element of a list literal.
        const list = ast.fullArrayInit(&buf, node) orelse return error.NotAList;
        const i = std.fmt.parseInt(usize, key[1 .. key.len - 1], 10) catch return error.NoSuchElement;
        if (i >= list.ast.elements.len) return error.NoSuchElement;
        const elem = list.ast.elements[i];
        if (keys.len == 1) return replaceNode(gpa, ast, elem, literal, edits);
        return walk(gpa, arena, ast, elem, keys[1..], literal, edits);
    }
    const init = ast.fullStructInit(&buf, node) orelse return if (node == ast.rootDecls()[0]) error.NoRoot else error.NotAStruct;
    for (init.ast.fields) |field| {
        if (!fieldNameIs(ast, field, key)) continue;
        if (keys.len == 1) return replaceNode(gpa, ast, field, literal, edits);
        return walk(gpa, arena, ast, field, keys[1..], literal, edits);
    }
    try insert(gpa, arena, ast, node, init, keys, literal, edits);
    return true;
}

/// Replace `node`'s bytes with `literal`; false when they already match.
fn replaceNode(gpa: Allocator, ast: Ast, node: Ast.Node.Index, literal: []const u8, edits: *std.ArrayList(Edit)) SpliceError!bool {
    const start = ast.tokenStart(ast.firstToken(node));
    const last = ast.lastToken(node);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    if (std.mem.eql(u8, ast.source[start..end], literal)) return false;
    try edits.append(gpa, .{ .start = start, .end = end, .text = literal });
    return true;
}

/// `[i]` — a list element's key. A struct key can never start with `[`.
pub fn isIndexKey(key: []const u8) bool {
    return key.len >= 3 and key[0] == '[' and key[key.len - 1] == ']';
}

/// `.name` or `.@"name"` — the token two back from the field's value.
fn fieldNameIs(ast: Ast, field: Ast.Node.Index, key: []const u8) bool {
    const first = ast.firstToken(field);
    if (first < 2) return false;
    const name = ast.tokenSlice(first - 2);
    if (std.mem.eql(u8, name, key)) return true;
    // `@"…"` — compare the inside with the key as `appendKey` escapes
    // it: a Windows path key (the trust store's) carries `\`.
    if (!(name.len >= 3 and name[0] == '@' and name[1] == '"' and name[name.len - 1] == '"')) return false;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{f}", .{std.zig.fmtString(key)}) catch return std.mem.eql(u8, name[2 .. name.len - 1], key);
    return std.mem.eql(u8, name[2 .. name.len - 1], w.buffered());
}

/// Insert `keys` (one field, or a nested chain of sections) into the
/// struct literal `node`.
fn insert(gpa: Allocator, arena: Allocator, ast: Ast, node: Ast.Node.Index, init: Ast.full.StructInit, keys: []const []const u8, literal: []const u8, edits: *std.ArrayList(Edit)) SpliceError!void {
    const src = ast.source;
    const lbrace = init.ast.lbrace;
    const rbrace = ast.lastToken(node);
    const rbrace_start = ast.tokenStart(rbrace);
    const prev = rbrace - 1;
    const prev_tag = ast.tokenTag(prev);
    const prev_end = ast.tokenStart(prev) + ast.tokenSlice(prev).len;

    if (prev_tag == .l_brace) {
        // `.{}` → open it up on its own lines.
        const outer = lineIndent(src, ast.tokenStart(lbrace));
        const inner = try std.mem.concat(arena, u8, &.{ outer, indent_unit });
        const body = try renderFields(arena, keys, literal, inner);
        const text = try std.mem.concat(arena, u8, &.{ "\n", body, outer });
        try edits.append(gpa, .{ .start = prev_end, .end = rbrace_start, .text = text });
        return;
    }

    // A trailing comma after the last field, unless there is one.
    if (prev_tag != .comma) try edits.append(gpa, .{ .start = prev_end, .end = prev_end, .text = "," });

    const own_line = onOwnLine(src, rbrace_start);
    if (own_line) {
        // The section is laid out one field per line: add ours at the
        // fields' indent, just before the closing brace's line.
        const indent = lineIndent(src, ast.tokenStart(ast.firstToken(init.ast.fields[0])));
        const body = try renderFields(arena, keys, literal, indent);
        const at = lineStart(src, rbrace_start);
        try edits.append(gpa, .{ .start = at, .end = at, .text = body });
    } else {
        // Inline `.{ .a = 1 }` → `.{ .a = 1, .b = 2 }`.
        const body = try renderInline(arena, keys, literal);
        const text = try std.mem.concat(arena, u8, &.{ body, " " });
        try edits.append(gpa, .{ .start = rbrace_start, .end = rbrace_start, .text = text });
    }
}

/// `<indent>.a = .{\n<indent+4>.b = lit,\n<indent>},\n` for a chain, or
/// the single `<indent>.key = lit,\n` line.
fn renderFields(arena: Allocator, keys: []const []const u8, literal: []const u8, indent: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, indent);
    try out.append(arena, '.');
    try appendKey(&out, arena, keys[0]);
    try out.appendSlice(arena, " = ");
    if (keys.len == 1) {
        try out.appendSlice(arena, literal);
        try out.appendSlice(arena, ",\n");
    } else {
        try out.appendSlice(arena, ".{\n");
        const inner = try std.mem.concat(arena, u8, &.{ indent, indent_unit });
        try out.appendSlice(arena, try renderFields(arena, keys[1..], literal, inner));
        try out.appendSlice(arena, indent);
        try out.appendSlice(arena, "},\n");
    }
    return out.toOwnedSlice(arena);
}

fn renderInline(arena: Allocator, keys: []const []const u8, literal: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '.');
    try appendKey(&out, arena, keys[0]);
    try out.appendSlice(arena, " = ");
    if (keys.len == 1) {
        try out.appendSlice(arena, literal);
    } else {
        try out.appendSlice(arena, ".{ ");
        try out.appendSlice(arena, try renderInline(arena, keys[1..], literal));
        try out.appendSlice(arena, " }");
    }
    return out.toOwnedSlice(arena);
}

/// Bare identifier when it can be, `@"…"` otherwise (`ctrl+p`, `space f f`).
fn appendKey(out: *std.ArrayList(u8), arena: Allocator, key: []const u8) Allocator.Error!void {
    if (std.zig.isValidId(key)) return out.appendSlice(arena, key);
    // Escaped: a key is any string (a Windows path's `\` included).
    try out.print(arena, "@\"{f}\"", .{std.zig.fmtString(key)});
}

pub fn lineStart(src: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, src[0..pos], '\n')) |nl| nl + 1 else 0;
}

pub fn lineIndent(src: []const u8, pos: usize) []const u8 {
    const start = lineStart(src, pos);
    var end = start;
    while (end < src.len and (src[end] == ' ' or src[end] == '\t')) end += 1;
    return src[start..end];
}

fn onOwnLine(src: []const u8, pos: usize) bool {
    return lineIndent(src, pos).len == pos - lineStart(src, pos);
}

// ─── the literal ─────────────────────────────────────────────────────────

/// `value` as ZON source, for `persistScalar`'s `literal`: `.vim`,
/// `"onedark"`, `true`, `30`, `.{ .custom = "glow" }`.
pub fn serializeLiteral(arena: Allocator, value: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(value, .{}, &out.writer) catch return error.OutOfMemory;
    // std wraps a container with more than two fields onto lines; a
    // scalar slot wants one line, so fold each newline + indent to a space.
    const raw = out.written();
    var folded: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\n') {
            try folded.append(arena, raw[i]);
            continue;
        }
        try folded.append(arena, ' ');
        while (i + 1 < raw.len and raw[i + 1] == ' ') i += 1;
    }
    return folded.toOwnedSlice(arena);
}

/// A list literal from its elements' bytes — what a reorder, an add or
/// a remove writes over the whole list. `multiline` lays one element
/// per line at `indent` (the closing brace one indent unit out), else
/// `.{ a, b }`. Comments that sat between the old elements do not
/// come along: the elements are the only bytes kept.
pub fn listLiteral(arena: Allocator, elements: []const []const u8, multiline: bool, indent: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (elements.len == 0) {
        try out.appendSlice(arena, ".{}");
        return out.toOwnedSlice(arena);
    }
    if (!multiline) {
        try out.appendSlice(arena, ".{ ");
        for (elements, 0..) |e, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, e);
        }
        try out.appendSlice(arena, " }");
        return out.toOwnedSlice(arena);
    }
    const outer = if (indent.len >= indent_unit.len) indent[0 .. indent.len - indent_unit.len] else "";
    try out.appendSlice(arena, ".{\n");
    for (elements) |e| {
        try out.appendSlice(arena, indent);
        try out.appendSlice(arena, e);
        try out.appendSlice(arena, ",\n");
    }
    try out.appendSlice(arena, outer);
    try out.append(arena, '}');
    return out.toOwnedSlice(arena);
}

// ─── the file ────────────────────────────────────────────────────────────

pub const Outcome = enum { unchanged, written };

pub const PersistError = SpliceError || error{ ReadFailed, WriteFailed };

/// See the module doc. `path` may be relative to the cwd or absolute.
pub fn persistScalar(gpa: Allocator, io: Io, path: []const u8, key_path: []const []const u8, literal: []const u8) PersistError!Outcome {
    const cwd = Io.Dir.cwd();
    var existed = true;
    const text: [:0]u8 = cwd.readFileAllocOptions(io, path, gpa, .limited(16 * 1024 * 1024), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => blk: {
            existed = false;
            break :blk try gpa.dupeZ(u8, ".{}\n");
        },
        else => return error.ReadFailed,
    };
    defer gpa.free(text);

    const new_text = (try splice(gpa, text, key_path, literal)) orelse return .unchanged;
    defer gpa.free(new_text);
    try writeBacked(gpa, io, path, if (existed) text else null, new_text);
    return .written;
}

/// Write `new_text` over `path` with the same backup `persistScalar`
/// makes — for a caller that spliced the text itself (the ZON view
/// pane's save). Unchanged bytes are a no-op.
pub fn persistText(gpa: Allocator, io: Io, path: []const u8, new_text: []const u8) PersistError!Outcome {
    const cwd = Io.Dir.cwd();
    const old: ?[]u8 = cwd.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => null,
        else => return error.ReadFailed,
    };
    defer if (old) |o| gpa.free(o);
    if (old) |o| if (std.mem.eql(u8, o, new_text)) return .unchanged;
    try writeBacked(gpa, io, path, old, new_text);
    return .written;
}

/// The backup (of `prev`, when the file existed) and the write.
fn writeBacked(gpa: Allocator, io: Io, path: []const u8, prev: ?[]const u8, new_text: []const u8) PersistError!void {
    const cwd = Io.Dir.cwd();
    const dir = std.fs.path.dirname(path) orelse ".";
    if (prev) |p| backup(gpa, io, dir, p) catch {}; // best effort: a lost backup must not block a save
    cwd.createDirPath(io, dir) catch return error.WriteFailed;
    cwd.writeFile(io, .{ .sub_path = path, .data = new_text }) catch return error.WriteFailed;
}

fn backup(gpa: Allocator, io: Io, root: []const u8, text: []const u8) !void {
    const dir_path = try std.fs.path.join(gpa, &.{ root, backups_dir });
    defer gpa.free(dir_path);
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);

    var stamp: [17]u8 = undefined;
    formatStamp(&stamp, Io.Timestamp.now(io, .real).toSeconds());
    const name = try backupName(gpa, io, dir, &stamp);
    defer gpa.free(name);
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
    try prune(gpa, io, dir);
}

/// `config.<stamp>-<NNNN>.zon`, the first `NNNN` from 0000 not yet in
/// `dir`. The stamp is by the second and a Settings row held under →
/// writes several times a second: named by the stamp alone, each write
/// replaced the one before it, and the backup of the file as it was
/// before the session — the one a user wants back — was the first to
/// go. The counter is fixed-width, so names still sort by time.
fn backupName(gpa: Allocator, io: Io, dir: Io.Dir, stamp: *const [17]u8) ![]u8 {
    var seq: u16 = 0;
    while (seq < 10_000) : (seq += 1) {
        const name = try std.fmt.allocPrint(gpa, "config.{s}-{d:0>4}.zon", .{ stamp, seq });
        if (dir.access(io, name, .{})) |_| {
            gpa.free(name);
        } else |_| return name;
    }
    return error.PathAlreadyExists;
}

/// Keep the newest `max_backups` files named `config.*.zon`. Names sort
/// chronologically because the stamp does.
pub fn prune(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "config.") or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len <= max_backups) return;
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items[0 .. names.items.len - max_backups]) |old| dir.deleteFile(io, old) catch {};
}

/// `YYYY-MM-DD-HHMMSS`, UTC.
pub fn formatStamp(out: *[17]u8, epoch_secs: i64) void {
    const secs: u64 = @intCast(@max(epoch_secs, 0));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    _ = std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const fixture: [:0]const u8 =
    \\// mnml config — hand-written, keep my comments
    \\.{
    \\    .editor = .{
    \\        .tab_width = 4, // four is fine
    \\        .input_style = .standard,
    \\    },
    \\    // the look
    \\    .ui = .{
    \\        .theme = "onedark",
    \\        .tree_width = 30 // no trailing comma, and a comment
    \\    },
    \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
    \\    .session = .{},
    \\}
    \\
;

fn expectSplice(key_path: []const []const u8, literal: []const u8, want: []const u8) !void {
    const got = (try splice(t.allocator, fixture, key_path, literal)) orelse return error.TestExpectedChange;
    defer t.allocator.free(got);
    try t.expectEqualStrings(want, got);
}

test "replacing a scalar keeps comments and order" {
    try expectSplice(&.{ "editor", "tab_width" }, "2",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 2, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30 // no trailing comma, and a comment
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
        \\    .session = .{},
        \\}
        \\
    );
}

test "an unchanged value is a no-op" {
    try t.expect((try splice(t.allocator, fixture, &.{ "editor", "tab_width" }, "4")) == null);
    try t.expect((try splice(t.allocator, fixture, &.{ "ui", "theme" }, "\"onedark\"")) == null);
}

test "a missing field is inserted at the section's indent, adding the comma after a comment line" {
    try expectSplice(&.{ "ui", "line_numbers" }, "false",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 4, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30, // no trailing comma, and a comment
        \\        .line_numbers = false,
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
        \\    .session = .{},
        \\}
        \\
    );
}

test "a missing section is appended before the top-level brace" {
    try expectSplice(&.{ "ipc", "write_screen" }, "true",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 4, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30 // no trailing comma, and a comment
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
        \\    .session = .{},
        \\    .ipc = .{
        \\        .write_screen = true,
        \\    },
        \\}
        \\
    );
}

test "an empty section opens up; an inline one stays inline; quoted keys match and render" {
    try expectSplice(&.{ "session", "restore" }, "false",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 4, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30 // no trailing comma, and a comment
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
        \\    .session = .{
        \\        .restore = false,
        \\    },
        \\}
        \\
    );
    try expectSplice(&.{ "keys", "global", "ctrl+p" }, "\"none\"",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 4, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30 // no trailing comma, and a comment
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "none" } },
        \\    .session = .{},
        \\}
        \\
    );
    try expectSplice(&.{ "keys", "global", "space f f" }, "\"picker.files\"",
        \\// mnml config — hand-written, keep my comments
        \\.{
        \\    .editor = .{
        \\        .tab_width = 4, // four is fine
        \\        .input_style = .standard,
        \\    },
        \\    // the look
        \\    .ui = .{
        \\        .theme = "onedark",
        \\        .tree_width = 30 // no trailing comma, and a comment
        \\    },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files", .@"space f f" = "picker.files" } },
        \\    .session = .{},
        \\}
        \\
    );
}

test "a fresh file grows from .{} and deep paths nest" {
    const got = (try splice(t.allocator, ".{}\n", &.{ "keys", "vim", "g d" }, "\"lsp.definition\"")).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\.{
        \\    .keys = .{
        \\        .vim = .{
        \\            .@"g d" = "lsp.definition",
        \\        },
        \\    },
        \\}
        \\
    , got);
}

const list_fixture: [:0]const u8 =
    \\.{
    \\    // where I work
    \\    .workspaces = .{
    \\        .{ .name = "a", .path = "/a" },
    \\        .{ .name = "b", .path = "/b", .group = "g" }, // b
    \\    },
    \\    .ui = .{ .todo_keywords = .{ "TODO", "FIXME" }, .md_preview_engine = .{ .custom = "glow" } },
    \\}
    \\
;

test "a [i] key steps into a list element; a field inside it splices in place" {
    const got = (try splice(t.allocator, list_fixture, &.{ "workspaces", "[1]", "group" }, "\"work\"")).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\.{
        \\    // where I work
        \\    .workspaces = .{
        \\        .{ .name = "a", .path = "/a" },
        \\        .{ .name = "b", .path = "/b", .group = "work" }, // b
        \\    },
        \\    .ui = .{ .todo_keywords = .{ "TODO", "FIXME" }, .md_preview_engine = .{ .custom = "glow" } },
        \\}
        \\
    , got);
    // a missing field inside an element is inserted there
    const added = (try splice(t.allocator, list_fixture, &.{ "workspaces", "[0]", "group" }, "\"g\"")).?;
    defer t.allocator.free(added);
    try t.expect(std.mem.indexOf(u8, added, ".{ .name = \"a\", .path = \"/a\", .group = \"g\" },") != null);
    // a whole element, and a whole string element
    const elem = (try splice(t.allocator, list_fixture, &.{ "ui", "todo_keywords", "[0]" }, "\"XXX\"")).?;
    defer t.allocator.free(elem);
    try t.expect(std.mem.indexOf(u8, elem, ".todo_keywords = .{ \"XXX\", \"FIXME\" }") != null);
    try t.expect((try splice(t.allocator, list_fixture, &.{ "ui", "todo_keywords", "[1]" }, "\"FIXME\"")) == null);
    // a union's payload swaps in place: the whole union literal is the value
    const swapped = (try splice(t.allocator, list_fixture, &.{ "ui", "md_preview_engine" }, ".glow")).?;
    defer t.allocator.free(swapped);
    try t.expect(std.mem.indexOf(u8, swapped, ".md_preview_engine = .glow }") != null);
    try t.expect(std.mem.indexOf(u8, swapped, "// where I work") != null);
    // the errors
    try t.expectError(error.NoSuchElement, splice(t.allocator, list_fixture, &.{ "workspaces", "[2]", "group" }, "1"));
    try t.expectError(error.NotAList, splice(t.allocator, list_fixture, &.{ "ui", "[0]" }, "1"));
    try t.expectError(error.NotAStruct, splice(t.allocator, list_fixture, &.{ "workspaces", "name" }, "1"));
}

test "listLiteral renders the two layouts" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings(".{}", try listLiteral(a, &.{}, true, "    "));
    try t.expectEqualStrings(".{ \"a\", \"b\" }", try listLiteral(a, &.{ "\"a\"", "\"b\"" }, false, ""));
    try t.expectEqualStrings(".{\n        1,\n        .{ .x = 2 },\n    }", try listLiteral(a, &.{ "1", ".{ .x = 2 }" }, true, "        "));
}

test "persistText writes with a backup and no-ops on the same bytes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "x.zon" });
    defer t.allocator.free(path);
    try t.expectEqual(Outcome.written, try persistText(t.allocator, t.io, path, ".{ .a = 1 }\n"));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "backups", .{}));
    try t.expectEqual(Outcome.unchanged, try persistText(t.allocator, t.io, path, ".{ .a = 1 }\n"));
    try t.expectEqual(Outcome.written, try persistText(t.allocator, t.io, path, ".{ .a = 2 }\n"));
    try tmp.dir.access(t.io, "backups", .{});
    const now = try tmp.dir.readFileAlloc(t.io, "x.zon", t.allocator, .unlimited);
    defer t.allocator.free(now);
    try t.expectEqualStrings(".{ .a = 2 }\n", now);
}

test "refuses to write into a file it cannot parse or a non-struct" {
    try t.expectError(error.ParseFailed, splice(t.allocator, ".{ .a = ", &.{"a"}, "1"));
    try t.expectError(error.NotAStruct, splice(t.allocator, ".{ .editor = 5 }", &.{ "editor", "tab_width" }, "1"));
    try t.expectError(error.NoRoot, splice(t.allocator, "5", &.{"a"}, "1"));
    try t.expectError(error.EmptyKeyPath, splice(t.allocator, ".{}", &.{}, "1"));
}

test "serializeLiteral spells the scalar forms" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The shapes a config slot actually holds — an enum, a string, a
    // bool, a number, and a union whose payload is a string. The host's
    // own `Config` is not in scope here (the SDK is under it), so the
    // two enums stand in for `InputStyle` and `MdEngine`.
    const InputStyle = enum { vim, standard };
    const MdEngine = union(enum) { builtin, glow, custom: []const u8 };
    try t.expectEqualStrings(".vim", try serializeLiteral(a, InputStyle.vim));
    try t.expectEqualStrings("\"onedark\"", try serializeLiteral(a, @as([]const u8, "onedark")));
    try t.expectEqualStrings("true", try serializeLiteral(a, true));
    try t.expectEqualStrings("30", try serializeLiteral(a, @as(u16, 30)));
    try t.expectEqualStrings(".glow", try serializeLiteral(a, MdEngine.glow));
    try t.expectEqualStrings(".{ .custom = \"glow -s\" }", try serializeLiteral(a, MdEngine{ .custom = "glow -s" }));
}

test "formatStamp is YYYY-MM-DD-HHMMSS" {
    var buf: [17]u8 = undefined;
    formatStamp(&buf, 0);
    try t.expectEqualStrings("1970-01-01-000000", &buf);
    formatStamp(&buf, 1_756_944_000); // 2025-09-04 00:00:00 UTC
    try t.expectEqualStrings("2025-09-04-000000", &buf);
}

test "writes in the same second each keep their own backup, in order, and the first holds the original" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "config.zon" });
    defer t.allocator.free(path);
    const original = "// hand-tuned: keep 40\n.{\n    .ui = .{\n        .tree_width = 40,\n    },\n}\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.zon", .data = original });
    // Three writes back to back — well inside one second.
    for ([_][]const u8{ "41", "42", "43" }) |v| {
        try t.expectEqual(Outcome.written, try persistScalar(t.allocator, t.io, path, &.{ "ui", "tree_width" }, v));
    }
    var backups = try tmp.dir.openDir(t.io, "backups", .{ .iterate = true });
    defer backups.close(t.io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |x| t.allocator.free(x);
        names.deinit(t.allocator);
    }
    var it = backups.iterate();
    while (try it.next(t.io)) |e| try names.append(t.allocator, try t.allocator.dupe(u8, e.name));
    try t.expectEqual(@as(usize, 3), names.items.len);
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    // The oldest by name is the file before the first write.
    const first = try backups.readFileAlloc(t.io, names.items[0], t.allocator, .unlimited);
    defer t.allocator.free(first);
    try t.expectEqualStrings(original, first);
    const last = try backups.readFileAlloc(t.io, names.items[2], t.allocator, .unlimited);
    defer t.allocator.free(last);
    try t.expect(std.mem.indexOf(u8, last, ".tree_width = 42") != null);
}

test "persistScalar writes, backs up, no-ops, and prunes to max_backups" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    const path = try std.fs.path.join(t.allocator, &.{ root, "config.zon" });
    defer t.allocator.free(path);

    // a new file: created, no backup (nothing to back up)
    try t.expectEqual(Outcome.written, try persistScalar(t.allocator, t.io, path, &.{ "editor", "tab_width" }, "2"));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "backups", .{}));
    const first = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(first);
    try t.expectEqualStrings(".{\n    .editor = .{\n        .tab_width = 2,\n    },\n}\n", first);

    // unchanged → no write, no backup
    try t.expectEqual(Outcome.unchanged, try persistScalar(t.allocator, t.io, path, &.{ "editor", "tab_width" }, "2"));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "backups", .{}));

    // 52 stale backups + one real write → pruned to 50, newest kept
    try tmp.dir.createDirPath(t.io, "backups");
    var i: usize = 0;
    while (i < max_backups + 2) : (i += 1) {
        const name = try std.fmt.allocPrint(t.allocator, "backups/config.2000-01-01-{d:0>6}.zon", .{i});
        defer t.allocator.free(name);
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "old" });
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "backups/notes.txt", .data = "not a backup" });
    try t.expectEqual(Outcome.written, try persistScalar(t.allocator, t.io, path, &.{ "editor", "tab_width" }, "8"));

    var backups = try tmp.dir.openDir(t.io, "backups", .{ .iterate = true });
    defer backups.close(t.io);
    var count: usize = 0;
    var saw_notes = false;
    var newest: [64]u8 = undefined;
    var newest_len: usize = 0;
    var it = backups.iterate();
    while (try it.next(t.io)) |e| {
        if (std.mem.eql(u8, e.name, "notes.txt")) {
            saw_notes = true;
            continue;
        }
        count += 1;
        if (newest_len == 0 or std.mem.order(u8, e.name, newest[0..newest_len]) == .gt) {
            @memcpy(newest[0..e.name.len], e.name);
            newest_len = e.name.len;
        }
    }
    try t.expectEqual(@as(usize, max_backups), count);
    try t.expect(saw_notes);
    // the backup holds the PREVIOUS text and is the newest by name
    try t.expect(std.mem.startsWith(u8, newest[0..newest_len], "config.20"));
    try t.expect(!std.mem.startsWith(u8, newest[0..newest_len], "config.2000-"));
    const saved = try backups.readFileAlloc(t.io, newest[0..newest_len], t.allocator, .unlimited);
    defer t.allocator.free(saved);
    try t.expectEqualStrings(first, saved);
}

test "a key with a backslash is written escaped and found again: a Windows path as the trust store keys it" {
    const key = "D:\\a\\ws";
    const first = (try splice(t.allocator, ".{}\n", &.{key}, "\"00ff\"")) orelse return error.TestExpectedChange;
    defer t.allocator.free(first);
    try t.expect(std.mem.indexOf(u8, first, ".@\"D:\\\\a\\\\ws\" = \"00ff\"") != null);
    const first_z = try t.allocator.dupeZ(u8, first);
    defer t.allocator.free(first_z);
    // The same key again replaces the value in place, not a second field.
    const second = (try splice(t.allocator, first_z, &.{key}, "\"0aaa\"")) orelse return error.TestExpectedChange;
    defer t.allocator.free(second);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, second, "@\""));
    try t.expect(std.mem.indexOf(u8, second, "\"0aaa\"") != null);
}
