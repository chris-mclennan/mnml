//! Form bodies (item 11): the Body tab holds `name = value` rows — or
//! `name = @path/to/file` for a file part, the path relative to the
//! source file's directory — and the block's `# @body-type multipart`
//! / `form-urlencoded` says how they go on the wire. `encode` writes
//! `multipart/form-data` with the boundary it is given (the send makes
//! a fresh one; the tests a fixed one); `urlencode` writes
//! `application/x-www-form-urlencoded`. `resolve` reads the file parts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One line of the Body tab in a form mode: `name = value`, or
/// `name = @path` (the value is the path, `file` set).
pub const Row = struct {
    name: []const u8,
    value: []const u8,
    file: ?[]const u8 = null,
};

/// The rows of `text`: `name = value` / `name=value` / `name: value`
/// per line; blanks and `#` lines are skipped; a value starting with
/// `@` names a file. Borrows `text`.
pub fn parseRows(arena: Allocator, text: []const u8) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const sep = if (eq != null and (colon == null or eq.? < colon.?)) eq.? else colon orelse line.len;
        const name = std.mem.trim(u8, line[0..sep], " \t");
        if (name.len == 0) continue;
        const value = if (sep < line.len) std.mem.trim(u8, line[sep + 1 ..], " \t") else "";
        if (value.len > 1 and value[0] == '@') {
            try out.append(arena, .{ .name = name, .value = value[1..], .file = value[1..] });
        } else {
            try out.append(arena, .{ .name = name, .value = value });
        }
    }
    return out.items;
}

/// The rows the other way: `name = value` per line, `@path` for a file.
pub fn renderRows(alloc: Allocator, rows: []const Row) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows) |r| {
        try out.appendSlice(alloc, r.name);
        try out.appendSlice(alloc, " = ");
        if (r.file != null) try out.append(alloc, '@');
        try out.appendSlice(alloc, r.value);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// A part ready for the wire: a field, or a file with its name and type.
pub const Part = struct {
    name: []const u8,
    data: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub const ResolveError = Allocator.Error || error{FileNotFound};

/// The rows as parts: a file row's bytes read from `base_dir/<path>`
/// (an absolute path as is), its name the file's basename, its type
/// guessed from the extension. A missing file is `error.FileNotFound`;
/// `missing` names it for the message.
pub fn resolve(arena: Allocator, io: Io, rows: []const Row, base_dir: []const u8, missing: *?[]const u8) ResolveError![]Part {
    var out: std.ArrayListUnmanaged(Part) = .empty;
    for (rows) |r| {
        if (r.file) |rel| {
            const path = if (std.fs.path.isAbsolute(rel)) try arena.dupe(u8, rel) else try std.fs.path.join(arena, &.{ base_dir, rel });
            const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    missing.* = rel;
                    return error.FileNotFound;
                },
            };
            try out.append(arena, .{ .name = r.name, .data = data, .filename = std.fs.path.basename(rel), .content_type = guessType(rel) });
        } else {
            try out.append(arena, .{ .name = r.name, .data = r.value });
        }
    }
    return out.items;
}

/// The media type a file part carries, by extension.
pub fn guessType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const Row2 = struct { ext: []const u8, mime: []const u8 };
    const table = [_]Row2{
        .{ .ext = ".json", .mime = "application/json" }, .{ .ext = ".txt", .mime = "text/plain" },      .{ .ext = ".csv", .mime = "text/csv" },
        .{ .ext = ".html", .mime = "text/html" },        .{ .ext = ".xml", .mime = "application/xml" }, .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },        .{ .ext = ".jpeg", .mime = "image/jpeg" },     .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".pdf", .mime = "application/pdf" },   .{ .ext = ".zip", .mime = "application/zip" }, .{ .ext = ".md", .mime = "text/markdown" },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t.ext)) return t.mime;
    return "application/octet-stream";
}

/// `multipart/form-data` with `boundary`: one part per row, CRLF
/// framing, the closing `--boundary--`. Owned.
pub fn encode(alloc: Allocator, parts: []const Part, boundary: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (parts) |p| {
        try out.appendSlice(alloc, "--");
        try out.appendSlice(alloc, boundary);
        try out.appendSlice(alloc, "\r\nContent-Disposition: form-data; name=\"");
        try appendQuoted(alloc, &out, p.name);
        try out.append(alloc, '"');
        if (p.filename) |f| {
            try out.appendSlice(alloc, "; filename=\"");
            try appendQuoted(alloc, &out, f);
            try out.append(alloc, '"');
        }
        try out.appendSlice(alloc, "\r\n");
        if (p.content_type) |ct| {
            try out.appendSlice(alloc, "Content-Type: ");
            try out.appendSlice(alloc, ct);
            try out.appendSlice(alloc, "\r\n");
        }
        try out.appendSlice(alloc, "\r\n");
        try out.appendSlice(alloc, p.data);
        try out.appendSlice(alloc, "\r\n");
    }
    try out.appendSlice(alloc, "--");
    try out.appendSlice(alloc, boundary);
    try out.appendSlice(alloc, "--\r\n");
    return out.toOwnedSlice(alloc);
}

fn appendQuoted(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "%22"),
        '\r', '\n' => try out.append(alloc, ' '),
        else => try out.append(alloc, c),
    };
}

/// `multipart/form-data; boundary=…`.
pub fn contentType(alloc: Allocator, boundary: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(alloc, u8, &.{ "multipart/form-data; boundary=", boundary });
}

pub const boundary_len: usize = "----mnmlBoundary".len + 24;

/// A fresh boundary: `----mnmlBoundary` and 24 hex digits.
pub fn makeBoundary(buf: *[boundary_len]u8, io: Io) []const u8 {
    var bytes: [12]u8 = undefined;
    io.random(&bytes);
    const prefix = "----mnmlBoundary";
    @memcpy(buf[0..prefix.len], prefix);
    _ = std.fmt.bufPrint(buf[prefix.len..], "{x}", .{&bytes}) catch unreachable;
    return buf[0..];
}

/// `application/x-www-form-urlencoded`: `k=v&k2=v2`, both sides
/// percent-encoded, a space as `+`. A file row sends its path as text.
pub fn urlencode(alloc: Allocator, rows: []const Row) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows, 0..) |r, i| {
        if (i > 0) try out.append(alloc, '&');
        try appendEncoded(alloc, &out, r.name);
        try out.append(alloc, '=');
        try appendEncoded(alloc, &out, r.value);
    }
    return out.toOwnedSlice(alloc);
}

pub const form_content_type = "application/x-www-form-urlencoded";

fn appendEncoded(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else if (c == ' ') {
            try out.append(alloc, '+');
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(alloc, &hex);
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "rows: `=`, `:` and `@file` lines parse; render round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try parseRows(arena.allocator(), "name = alice\n# a comment\n\nfile=@docs/a.png\nnote: hi there\n= nope\n");
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("alice", rows[0].value);
    try testing.expect(rows[0].file == null);
    try testing.expectEqualStrings("docs/a.png", rows[1].file.?);
    try testing.expectEqualStrings("hi there", rows[2].value);
    const text = try renderRows(testing.allocator, rows);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("name = alice\nfile = @docs/a.png\nnote = hi there\n", text);
}

test "encode with a fixed boundary: the bytes, byte for byte; urlencode escapes; the types" {
    const parts = [_]Part{
        .{ .name = "name", .data = "alice" },
        .{ .name = "file", .data = "hello\n", .filename = "a.txt", .content_type = "text/plain" },
    };
    const body = try encode(testing.allocator, &parts, "----mnmlBoundaryTEST");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("------mnmlBoundaryTEST\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nalice\r\n" ++
        "------mnmlBoundaryTEST\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\n\r\n" ++
        "------mnmlBoundaryTEST--\r\n", body);
    const ct = try contentType(testing.allocator, "----mnmlBoundaryTEST");
    defer testing.allocator.free(ct);
    try testing.expectEqualStrings("multipart/form-data; boundary=----mnmlBoundaryTEST", ct);
    const enc = try urlencode(testing.allocator, &.{ .{ .name = "a b", .value = "1&2=3" }, .{ .name = "ü", .value = "~ok" } });
    defer testing.allocator.free(enc);
    try testing.expectEqualStrings("a+b=1%262%3D3&%C3%BC=~ok", enc);
    try testing.expectEqualStrings("image/png", guessType("x/y.PNG"));
    try testing.expectEqualStrings("application/octet-stream", guessType("blob"));
    var buf: [boundary_len]u8 = undefined;
    const b = makeBoundary(&buf, testing.io);
    try testing.expectEqual(boundary_len, b.len);
    try testing.expect(std.mem.startsWith(u8, b, "----mnmlBoundary"));
}

test "resolve: a file row reads relative to the base dir and names the missing one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const base = pbuf[0..n];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.json", .data = "{}" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var missing: ?[]const u8 = null;
    const parts = try resolve(arena.allocator(), testing.io, &.{ .{ .name = "f", .value = "data.json", .file = "data.json" }, .{ .name = "k", .value = "v" } }, base, &missing);
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("{}", parts[0].data);
    try testing.expectEqualStrings("data.json", parts[0].filename.?);
    try testing.expectEqualStrings("application/json", parts[0].content_type.?);
    try testing.expect(parts[1].filename == null);
    try testing.expectError(error.FileNotFound, resolve(arena.allocator(), testing.io, &.{.{ .name = "f", .value = "nope.bin", .file = "nope.bin" }}, base, &missing));
    try testing.expectEqualStrings("nope.bin", missing.?);
}
