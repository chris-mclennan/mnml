//! The one reading of a `$<SERVICE>_BASE_URL` override — the switch a
//! test uses to point an integration at a fake server, shared so every
//! integration fails the same way when the switch is broken.
//!
//! The value is a URL, or `@<path>` naming a file that holds one: a
//! fake server started with `--port 0 --url-file <path>` writes the
//! address it was actually given there, so a script never picks a port
//! and two runs never collide. The file appears once the socket is
//! listening, and a script may start the server and the pane in either
//! order, so a missing or empty file is waited out for a while.
//!
//! What the wait ends in is the point of this module. An override that
//! names a file which never arrives means "the fake did not start" —
//! and the answer to that is **no server at all**, never the one the
//! override was there to avoid. Falling back to the config's URL or to
//! the service's production API would turn a broken test double into
//! authenticated requests against a real account (with whatever token
//! the shell exports). So an unreadable `@<path>` is `.unreadable`,
//! carrying the sentence the pane's setup screen shows, and the caller
//! refuses to build a client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What the environment says about the base URL.
pub const Override = union(enum) {
    /// Not set (or blank): the config's URL stands.
    unset,
    /// The URL to use, trimmed, trailing `/` kept as written. On the
    /// allocator the caller passed.
    url: []u8,
    /// `@<path>` whose file never held a URL within the wait. The
    /// sentence to show, on the allocator the caller passed. The
    /// caller makes NO request.
    unreadable: []u8,

    pub fn deinit(o: Override, gpa: Allocator) void {
        switch (o) {
            .unset => {},
            .url, .unreadable => |s| gpa.free(s),
        }
    }
};

pub const Options = struct {
    /// How long a missing or empty `@<path>` is waited for.
    wait_ms: u32 = 5000,
    /// How often it is looked at in that time.
    poll_ms: u32 = 100,
};

/// Read `$<name>` from `env`. `.url` and `.unreadable` are owned by
/// `gpa`; free them with `Override.deinit`.
pub fn fromEnv(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8, opts: Options) Allocator.Error!Override {
    const raw = env.get(name) orelse return .unset;
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0) return .unset;
    if (v[0] != '@') return .{ .url = try gpa.dupe(u8, v) };
    const path = v[1..];
    if (path.len == 0) return .{ .unreadable = try std.fmt.allocPrint(gpa, "${s} is \"@\" with no file after it — no server is asked (fix the override, or unset it)", .{name}) };
    const poll = @max(opts.poll_ms, 1);
    var waited: u32 = 0;
    while (true) {
        if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |text| {
            defer gpa.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) return .{ .url = try gpa.dupe(u8, trimmed) };
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        if (waited >= opts.wait_ms) break;
        io.sleep(.fromMilliseconds(poll), .awake) catch {};
        waited += poll;
    }
    return .{ .unreadable = try std.fmt.allocPrint(
        gpa,
        "${s}=@{s}: that file is missing or empty (waited {d} ms) — the fake server did not start? No server is asked, not even the configured one.",
        .{ name, path, opts.wait_ms },
    ) };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "unset and blank leave the config standing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{})) == .unset);
    try env.put("X_BASE_URL", "  \n");
    try testing.expect((try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{})) == .unset);
}

test "a literal is taken as written, trimmed" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("X_BASE_URL", " http://127.0.0.1:1234/ ");
    const o = try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{});
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings("http://127.0.0.1:1234/", o.url);
}

test "@<path> reads the file the fake server wrote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.url", .data = "http://127.0.0.1:54321\n" });
    const at = try std.fmt.allocPrint(testing.allocator, "@{s}/x.url", .{root});
    defer testing.allocator.free(at);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("X_BASE_URL", at);
    const o = try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{ .wait_ms = 0 });
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings("http://127.0.0.1:54321", o.url);
}

test "@<path> that never appears, or stays empty, is unreadable — never a fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    const missing = try std.fmt.allocPrint(testing.allocator, "@{s}/never.url", .{root});
    defer testing.allocator.free(missing);
    try env.put("X_BASE_URL", missing);
    const a = try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{ .wait_ms = 30, .poll_ms = 10 });
    defer a.deinit(testing.allocator);
    try testing.expect(a == .unreadable);
    try testing.expect(std.mem.indexOf(u8, a.unreadable, "never.url") != null);
    try testing.expect(std.mem.indexOf(u8, a.unreadable, "No server is asked") != null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.url", .data = " \n" });
    const empty = try std.fmt.allocPrint(testing.allocator, "@{s}/empty.url", .{root});
    defer testing.allocator.free(empty);
    try env.put("X_BASE_URL", empty);
    const b = try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{ .wait_ms = 0 });
    defer b.deinit(testing.allocator);
    try testing.expect(b == .unreadable);

    try env.put("X_BASE_URL", "@");
    const c = try fromEnv(testing.allocator, testing.io, &env, "X_BASE_URL", .{ .wait_ms = 0 });
    defer c.deinit(testing.allocator);
    try testing.expect(c == .unreadable);
}
