//! The write path: an AST-guided splice, not a serializer round-trip.
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
    var buf: [2]Ast.Node.Index = undefined;
    const init = ast.fullStructInit(&buf, node) orelse return if (node == ast.rootDecls()[0]) error.NoRoot else error.NotAStruct;
    const key = keys[0];
    for (init.ast.fields) |field| {
        if (!fieldNameIs(ast, field, key)) continue;
        if (keys.len == 1) {
            const start = ast.tokenStart(ast.firstToken(field));
            const last = ast.lastToken(field);
            const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
            if (std.mem.eql(u8, ast.source[start..end], literal)) return false;
            try edits.append(gpa, .{ .start = start, .end = end, .text = literal });
            return true;
        }
        return walk(gpa, arena, ast, field, keys[1..], literal, edits);
    }
    try insert(gpa, arena, ast, node, init, keys, literal, edits);
    return true;
}

/// `.name` or `.@"name"` — the token two back from the field's value.
fn fieldNameIs(ast: Ast, field: Ast.Node.Index, key: []const u8) bool {
    const first = ast.firstToken(field);
    if (first < 2) return false;
    const name = ast.tokenSlice(first - 2);
    if (std.mem.eql(u8, name, key)) return true;
    // `@"…"` — compare the inside; escapes in a key are not a thing.
    return name.len >= 3 and name[0] == '@' and name[1] == '"' and name[name.len - 1] == '"' and std.mem.eql(u8, name[2 .. name.len - 1], key);
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
    try out.appendSlice(arena, "@\"");
    try out.appendSlice(arena, key);
    try out.append(arena, '"');
}

fn lineStart(src: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, src[0..pos], '\n')) |nl| nl + 1 else 0;
}

fn lineIndent(src: []const u8, pos: usize) []const u8 {
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

    const dir = std.fs.path.dirname(path) orelse ".";
    if (existed) backup(gpa, io, dir, text) catch {}; // best effort: a lost backup must not block a save
    cwd.createDirPath(io, dir) catch return error.WriteFailed;
    cwd.writeFile(io, .{ .sub_path = path, .data = new_text }) catch return error.WriteFailed;
    return .written;
}

fn backup(gpa: Allocator, io: Io, root: []const u8, text: []const u8) !void {
    const dir_path = try std.fs.path.join(gpa, &.{ root, backups_dir });
    defer gpa.free(dir_path);
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);

    var stamp: [17]u8 = undefined;
    formatStamp(&stamp, Io.Timestamp.now(io, .real).toSeconds());
    const name = try std.fmt.allocPrint(gpa, "config.{s}.zon", .{stamp});
    defer gpa.free(name);
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
    try prune(gpa, io, dir);
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
    const Config = @import("Config.zig");
    try t.expectEqualStrings(".vim", try serializeLiteral(a, Config.InputStyle.vim));
    try t.expectEqualStrings("\"onedark\"", try serializeLiteral(a, @as([]const u8, "onedark")));
    try t.expectEqualStrings("true", try serializeLiteral(a, true));
    try t.expectEqualStrings("30", try serializeLiteral(a, @as(u16, 30)));
    try t.expectEqualStrings(".glow", try serializeLiteral(a, Config.MdEngine.glow));
    try t.expectEqualStrings(".{ .custom = \"glow -s\" }", try serializeLiteral(a, Config.MdEngine{ .custom = "glow -s" }));
}

test "formatStamp is YYYY-MM-DD-HHMMSS" {
    var buf: [17]u8 = undefined;
    formatStamp(&buf, 0);
    try t.expectEqualStrings("1970-01-01-000000", &buf);
    formatStamp(&buf, 1_756_944_000); // 2025-09-04 00:00:00 UTC
    try t.expectEqualStrings("2025-09-04-000000", &buf);
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
