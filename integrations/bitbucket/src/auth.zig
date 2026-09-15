//! Two tokens, one wire format. Bitbucket Cloud authenticates an
//! Atlassian scoped API token and a Bitbucket app password the same
//! way — `Authorization: Basic base64(email:token)` — so what separates
//! them is the scope you granted and the rate-limit bucket they draw
//! from, not the request.
//!
//! The pane resolves **two**, the way the employer's convention splits
//! them: a read token for the lists and the detail, and a write token
//! for approve / request-changes / comment / merge. A read-only token
//! is the one you leave exported in a shell rc; a write token is the
//! one you would rather a stray `--values` poll never hold.
//!
//! Read  (first hit wins): `BITBUCKET_API_TOKEN` → `BITBUCKET_APP_PASSWORD`
//!       → `BITBUCKET_PERSONAL_TOKEN` → `<config dir>/token`.
//! Write (first hit wins): `BITBUCKET_ACCESS_TOKEN` → `BITBUCKET_WRITE_TOKEN`
//!       → `<config dir>/token.write` → the read token, marked as
//!       borrowed. `BITBUCKET_REQUIRE_WRITE_TOKEN=1` turns that last
//!       step off, so a write with no write token refuses instead.
//!
//! `BITBUCKET_PERSONAL_TOKEN` is often exported as `email:token`; only
//! the part after the colon is the token.
//!
//! **A token is never printed.** `Source.label` names where it came
//! from and `describe` says how long it is; neither ever holds bytes of
//! the secret, and the test below proves it of the whole diagnostic
//! block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const read_env_names = [_][]const u8{ "BITBUCKET_API_TOKEN", "BITBUCKET_APP_PASSWORD", "BITBUCKET_PERSONAL_TOKEN" };
pub const write_env_names = [_][]const u8{ "BITBUCKET_ACCESS_TOKEN", "BITBUCKET_WRITE_TOKEN" };
pub const read_file_name = "token";
pub const write_file_name = "token.write";

pub const Source = union(enum) {
    env: []const u8,
    file: []const u8,
    /// The write side fell back to the read token.
    borrowed_read,
    none,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .env => |name| name,
            .file => |p| p,
            .borrowed_read => "the read token (no write token set)",
            .none => "not set",
        };
    }

    pub fn found(s: Source) bool {
        return s != .none;
    }
};

pub const Tokens = struct {
    /// Owned by `arena`.
    read: []const u8 = "",
    write: []const u8 = "",
    read_source: Source = .none,
    write_source: Source = .none,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Tokens) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasRead(self: *const Tokens) bool {
        return self.read.len > 0;
    }

    pub fn hasWrite(self: *const Tokens) bool {
        return self.write.len > 0;
    }

    /// Why a write cannot go out, or null when one can.
    pub fn writeRefusal(self: *const Tokens) ?[]const u8 {
        if (self.hasWrite()) return null;
        if (self.read_source.found())
            return "no write token: set BITBUCKET_ACCESS_TOKEN (or drop one in token.write)";
        return "no Bitbucket token at all: set BITBUCKET_API_TOKEN, or see the README";
    }
};

/// Everything after the first colon — an `email:token` export is common
/// and only the token half is the secret. A bare token has no colon and
/// comes back unchanged.
pub fn stripEmailPrefix(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, ':') orelse return s;
    return s[i + 1 ..];
}

/// Resolve both tokens. `config_dir` is where `token` / `token.write`
/// would be — the folder holding `config.zon`.
pub fn resolve(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config_dir: []const u8) Allocator.Error!Tokens {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var out: Tokens = .{ .arena = undefined };

    for (read_env_names) |name| {
        if (fromEnv(env, name)) |v| {
            out.read = try a.dupe(u8, v);
            out.read_source = .{ .env = name };
            break;
        }
    }
    if (out.read.len == 0) {
        if (readTokenFile(a, io, config_dir, read_file_name)) |pair| {
            out.read = pair.token;
            out.read_source = .{ .file = pair.path };
        } else |_| {}
    }

    for (write_env_names) |name| {
        if (fromEnv(env, name)) |v| {
            out.write = try a.dupe(u8, v);
            out.write_source = .{ .env = name };
            break;
        }
    }
    if (out.write.len == 0) {
        if (readTokenFile(a, io, config_dir, write_file_name)) |pair| {
            out.write = pair.token;
            out.write_source = .{ .file = pair.path };
        } else |_| {}
    }
    const require = std.mem.eql(u8, env.get("BITBUCKET_REQUIRE_WRITE_TOKEN") orelse "0", "1");
    if (out.write.len == 0 and out.read.len > 0 and !require) {
        out.write = out.read;
        out.write_source = .borrowed_read;
    }
    out.arena = arena;
    return out;
}

fn fromEnv(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const raw = env.get(name) orelse return null;
    const v = stripEmailPrefix(std.mem.trim(u8, raw, " \t\r\n"));
    return if (v.len == 0) null else v;
}

const FilePair = struct { token: []const u8, path: []const u8 };

fn readTokenFile(a: Allocator, io: Io, dir: []const u8, name: []const u8) !FilePair {
    const p = try std.fs.path.join(a, &.{ dir, name });
    const text = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 * 1024));
    const token = stripEmailPrefix(std.mem.trim(u8, text, " \t\r\n"));
    if (token.len == 0) return error.Empty;
    return .{ .token = token, .path = p };
}

/// `Basic base64(email:token)`, owned.
pub fn basicHeader(gpa: Allocator, email: []const u8, token: []const u8) Allocator.Error![]u8 {
    const pair = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ email, token });
    defer gpa.free(pair);
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, 6 + enc.calcSize(pair.len));
    @memcpy(out[0..6], "Basic ");
    _ = enc.encode(out[6..], pair);
    return out;
}

/// One line per token for `--check` / `--diag`: where it came from and
/// how long it is. Never a byte of the token itself.
pub fn describe(gpa: Allocator, tk: *const Tokens) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print("read token:  {s}", .{tk.read_source.label()}) catch return error.OutOfMemory;
    if (tk.hasRead()) w.print(" ({d} chars, not shown)", .{tk.read.len}) catch return error.OutOfMemory;
    w.writeAll("\nwrite token: ") catch return error.OutOfMemory;
    w.writeAll(tk.write_source.label()) catch return error.OutOfMemory;
    if (tk.hasWrite() and tk.write_source != .borrowed_read) {
        w.print(" ({d} chars, not shown)", .{tk.write.len}) catch return error.OutOfMemory;
    }
    w.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "an email:token export yields only the token; a bare token passes through" {
    try t.expectEqualStrings("ATATT-abc", stripEmailPrefix("me@example.com:ATATT-abc"));
    try t.expectEqualStrings("ATATT-abc", stripEmailPrefix("ATATT-abc"));
    try t.expectEqualStrings("", stripEmailPrefix("me@example.com:"));
}

test "read resolves API token first, then app password, then the legacy combined form" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_PERSONAL_TOKEN", "me@x.com:legacy");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("legacy", tk.read);
        try t.expectEqualStrings("BITBUCKET_PERSONAL_TOKEN", tk.read_source.label());
    }
    try env.put("BITBUCKET_APP_PASSWORD", "app-pw");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("app-pw", tk.read);
    }
    try env.put("BITBUCKET_API_TOKEN", "api-tok");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("api-tok", tk.read);
        try t.expectEqualStrings("BITBUCKET_API_TOKEN", tk.read_source.label());
        // With no write token the write side borrows the read one.
        try t.expectEqualStrings("api-tok", tk.write);
        try t.expectEqual(Source.borrowed_read, tk.write_source);
        try t.expect(tk.writeRefusal() == null);
    }
}

test "the write token is its own resolution, and REQUIRE_WRITE_TOKEN refuses the borrow" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_API_TOKEN", "read-tok");
    try env.put("BITBUCKET_ACCESS_TOKEN", "write-tok");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("read-tok", tk.read);
        try t.expectEqualStrings("write-tok", tk.write);
        try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.write_source.label());
    }
    // No write token + REQUIRE_WRITE_TOKEN: the write side stays unset
    // and says what to do about it.
    var strict = std.process.Environ.Map.init(t.allocator);
    defer strict.deinit();
    try strict.put("BITBUCKET_API_TOKEN", "read-tok");
    try strict.put("BITBUCKET_REQUIRE_WRITE_TOKEN", "1");
    var tk = try resolve(t.allocator, t.io, &strict, "/nonexistent");
    defer tk.deinit();
    try t.expect(tk.hasRead());
    try t.expect(!tk.hasWrite());
    try t.expect(std.mem.indexOf(u8, tk.writeRefusal().?, "BITBUCKET_ACCESS_TOKEN") != null);
}

test "no token anywhere: both sides are unset and the refusal points at the README" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
    defer tk.deinit();
    try t.expect(!tk.hasRead());
    try t.expect(!tk.hasWrite());
    try t.expectEqualStrings("not set", tk.read_source.label());
    try t.expect(std.mem.indexOf(u8, tk.writeRefusal().?, "README") != null);
}

test "the token files are read when the environment is empty, and an empty file is not a token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "  file-read-token\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token.write", .data = "me@x.com:file-write-token\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("file-read-token", tk.read);
        try t.expectEqualStrings("file-write-token", tk.write);
        try t.expect(std.mem.endsWith(u8, tk.read_source.label(), "token"));
        try t.expect(std.mem.endsWith(u8, tk.write_source.label(), "token.write"));
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "\n" });
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expect(!tk.hasRead());
}

test "the Basic header is the base64 of email:token" {
    const h = try basicHeader(t.allocator, "me@example.com", "s3cret");
    defer t.allocator.free(h);
    try t.expectEqualStrings("Basic bWVAZXhhbXBsZS5jb206czNjcmV0", h);
}

test "the diagnostic block names the source and the length and never the token" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_API_TOKEN", "ATATT-super-secret-value");
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATATT-write-secret-value");
    var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
    defer tk.deinit();
    const text = try describe(t.allocator, &tk);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "BITBUCKET_API_TOKEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "BITBUCKET_ACCESS_TOKEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "24 chars, not shown") != null);
    // The secret itself is nowhere in it — not whole, not in part.
    try t.expect(std.mem.indexOf(u8, text, "ATATT-super-secret-value") == null);
    try t.expect(std.mem.indexOf(u8, text, "ATATT-write-secret-value") == null);
    try t.expect(std.mem.indexOf(u8, text, "secret") == null);
}
