//! The wire body a block's `# @body-type` asks for — one encoder for
//! every path that sends a request: the request pane, `mnml-zig run`,
//! the chain runner. `json` is pretty-printed when asked and typed
//! `application/json`; `form-urlencoded` encodes the `name = value`
//! rows; `multipart` encodes them with a fresh boundary, reading a
//! `name = @path` row relative to `base_dir`. A `Content-Type` the
//! request already carries is kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const multipart = @import("multipart.zig");

pub const Options = struct {
    /// `http.auto_format_body`: re-indent a JSON body on the way out.
    format_json: bool = true,
    /// The directory a multipart `@path` row is read from.
    base_dir: []const u8 = ".",
    /// A fixed boundary (the tests); a fresh one otherwise.
    boundary: ?[]const u8 = null,
};

pub const Error = Allocator.Error || error{FileNotFound};

/// Rewrite `req`'s body (its fields on `gpa`) for the wire. On
/// `error.FileNotFound`, `missing` names the multipart file.
pub fn encode(gpa: Allocator, io: Io, req: *parse.Request, opts: Options, missing: *?[]const u8) Error!void {
    const kind = parse.bodyType(req);
    if (kind == .raw) return;
    const body = req.body orelse return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (kind) {
        .raw => {},
        .json => {
            if (opts.format_json) {
                if (std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})) |v| {
                    const pretty = std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
                    try req.setBody(gpa, pretty);
                } else |_| {}
            }
            if (req.header("content-type") == null) try req.addHeader(gpa, "Content-Type", "application/json");
        },
        .form => {
            const rows = try multipart.parseRows(a, body);
            try req.setBody(gpa, try multipart.urlencode(a, rows));
            if (req.header("content-type") == null) try req.addHeader(gpa, "Content-Type", multipart.form_content_type);
        },
        .multipart => {
            const rows = try multipart.parseRows(a, body);
            var miss: ?[]const u8 = null;
            const parts = multipart.resolve(a, io, rows, opts.base_dir, &miss) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => {
                    missing.* = if (miss) |m| try gpa.dupe(u8, m) else null;
                    return error.FileNotFound;
                },
            };
            var bbuf: [multipart.boundary_len]u8 = undefined;
            const boundary = opts.boundary orelse multipart.makeBoundary(&bbuf, io);
            try req.setBody(gpa, try multipart.encode(a, parts, boundary));
            if (req.header("content-type") == null) try req.addHeader(gpa, "Content-Type", try multipart.contentType(a, boundary));
        },
    }
}

const testing = std.testing;

test "encode: form rows urlencode with their content-type; multipart gets a boundary; raw is untouched" {
    var req = try parse.parse(testing.allocator, "# @body-type form-urlencoded\nPOST http://h/echo\n\nname = alice\ncity = new york\n");
    defer req.deinit(testing.allocator);
    var missing: ?[]const u8 = null;
    try encode(testing.allocator, testing.io, &req, .{}, &missing);
    try testing.expectEqualStrings("name=alice&city=new+york", req.body.?);
    try testing.expectEqualStrings(multipart.form_content_type, req.header("content-type").?);

    var mp = try parse.parse(testing.allocator, "# @body-type multipart\nPOST http://h/up\n\nname = alice\n");
    defer mp.deinit(testing.allocator);
    try encode(testing.allocator, testing.io, &mp, .{ .boundary = "BOUND" }, &missing);
    try testing.expect(std.mem.indexOf(u8, mp.body.?, "--BOUND\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nalice\r\n") != null);
    try testing.expect(std.mem.startsWith(u8, mp.header("content-type").?, "multipart/form-data; boundary=BOUND"));

    var raw = try parse.parse(testing.allocator, "POST http://h/echo\n\nname = alice\n");
    defer raw.deinit(testing.allocator);
    try encode(testing.allocator, testing.io, &raw, .{}, &missing);
    try testing.expectEqualStrings("name = alice", std.mem.trimEnd(u8, raw.body.?, "\n"));
    try testing.expect(raw.header("content-type") == null);
}
