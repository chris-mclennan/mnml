//! The token. Bitbucket Cloud authenticates an Atlassian scoped API
//! token and a Bitbucket app password the same way —
//! `Authorization: Basic base64(email:token)` — so what separates
//! them is the scope you granted and the rate-limit bucket they draw
//! from, not the request.
//!
//! **The rule: `BITBUCKET_ACCESS_TOKEN` when it is set, else the token
//! file.** Set it and it is the token — every read and the one write
//! (`a`, approve) — so there is one variable to export and one thing
//! to revoke. Unset, the token comes from `<config dir>/token`.
//!
//! In full, first hit wins, the reference's three variables kept
//! between them so a machine already exporting one keeps working:
//!
//!   1. `BITBUCKET_ACCESS_TOKEN` — the one to use
//!   2. `BITBUCKET_API_TOKEN` — an Atlassian API token
//!   3. `BITBUCKET_APP_PASSWORD` — a Bitbucket app password
//!   4. `BITBUCKET_PERSONAL_TOKEN` — either kind, often exported as
//!      `email:token`; only the half after the colon is the token
//!   5. `<config dir>/token` — one line, `chmod 600`
//!
//! The approve token is `BITBUCKET_ACCESS_TOKEN` when set and the read
//! token otherwise, which under the rule above is the same token: a
//! read-only machine simply never has a write to send.
//!
//! **A token is never printed.** `Source.label` names where it came
//! from and `describe` says how long it is; the test below holds that
//! line for the whole diagnostic block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const write_env_name = "BITBUCKET_ACCESS_TOKEN";
/// In resolution order. `BITBUCKET_ACCESS_TOKEN` leads: set, it is the
/// token, and the file below is what answers when it is not.
pub const env_names = [_][]const u8{ write_env_name, "BITBUCKET_API_TOKEN", "BITBUCKET_APP_PASSWORD", "BITBUCKET_PERSONAL_TOKEN" };
pub const file_name = "token";

pub const Source = union(enum) {
    env: []const u8,
    file: []const u8,
    /// The approve token fell back to the read token.
    same_as_read,
    none,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .env => |name| name,
            .file => |p| p,
            .same_as_read => "the read token",
            .none => "not set",
        };
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
};

/// Everything after the first colon — an `email:token` export is
/// common and only the token half is the secret.
pub fn stripEmailPrefix(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, ':') orelse return s;
    return s[i + 1 ..];
}

/// Resolve the token (and the approve token). `config_dir` holds
/// `config.zon` and, optionally, `token`.
pub fn resolve(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config_dir: []const u8) Allocator.Error!Tokens {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var out: Tokens = .{ .arena = undefined };
    for (env_names) |name| {
        if (fromEnv(env, name)) |v| {
            out.read = try a.dupe(u8, v);
            out.read_source = .{ .env = name };
            break;
        }
    }
    if (out.read.len == 0) {
        if (readTokenFile(a, io, config_dir)) |pair| {
            out.read = pair.token;
            out.read_source = .{ .file = pair.path };
        } else |_| {}
    }
    if (fromEnv(env, write_env_name)) |v| {
        out.write = try a.dupe(u8, v);
        out.write_source = .{ .env = write_env_name };
    } else if (out.read.len > 0) {
        out.write = out.read;
        out.write_source = .same_as_read;
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

fn readTokenFile(a: Allocator, io: Io, dir: []const u8) !FilePair {
    const p = try std.fs.path.join(a, &.{ dir, file_name });
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

/// The lines `--check` / `--diag` print: where each token came from
/// and how long it is. Never a byte of the token itself.
pub fn describe(gpa: Allocator, tk: *const Tokens) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print("token source: {s}", .{tk.read_source.label()}) catch return error.OutOfMemory;
    if (tk.hasRead()) w.print(" (loaded, {d} chars, not shown)", .{tk.read.len}) catch return error.OutOfMemory;
    w.print("\napprove token: {s}", .{tk.write_source.label()}) catch return error.OutOfMemory;
    if (tk.write_source == .env) w.print(" ({d} chars, not shown)", .{tk.write.len}) catch return error.OutOfMemory;
    w.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "BITBUCKET_ACCESS_TOKEN is the token when it is set, and the file is the token when it is not" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "from-the-file\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // Unset: the file.
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("from-the-file", tk.read);
        try t.expect(std.mem.endsWith(u8, tk.read_source.label(), "token"));
        try t.expectEqualStrings("from-the-file", tk.write);
        try t.expectEqual(Source.same_as_read, tk.write_source);
    }
    // Set: it wins over the file and over every reference variable,
    // and it is the approve token too.
    try env.put("BITBUCKET_API_TOKEN", "api-tok");
    try env.put("BITBUCKET_APP_PASSWORD", "app-pw");
    try env.put("BITBUCKET_PERSONAL_TOKEN", "me@x.com:legacy");
    try env.put("BITBUCKET_ACCESS_TOKEN", "access-tok");
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("access-tok", tk.read);
        try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.read_source.label());
        try t.expectEqualStrings("access-tok", tk.write);
        try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.write_source.label());
    }
    // Empty is not set.
    try env.put("BITBUCKET_ACCESS_TOKEN", "");
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expectEqualStrings("api-tok", tk.read);
}

test "the reference's variables still resolve, under ACCESS_TOKEN, and email:token keeps only the token" {
    try t.expectEqualStrings("ATATT-abc", stripEmailPrefix("me@example.com:ATATT-abc"));
    try t.expectEqualStrings("ATATT-abc", stripEmailPrefix("ATATT-abc"));
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_PERSONAL_TOKEN", "me@x.com:legacy");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("legacy", tk.read);
        try t.expectEqualStrings("BITBUCKET_PERSONAL_TOKEN", tk.read_source.label());
        try t.expectEqualStrings("legacy", tk.write);
        try t.expectEqual(Source.same_as_read, tk.write_source);
    }
    try env.put("BITBUCKET_APP_PASSWORD", "app-pw");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("app-pw", tk.read);
        try t.expectEqualStrings("app-pw", tk.write);
    }
    try env.put("BITBUCKET_API_TOKEN", "api-tok");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("api-tok", tk.read);
        try t.expectEqualStrings("BITBUCKET_API_TOKEN", tk.read_source.label());
    }
    // And above all three, the rule's own variable.
    try env.put("BITBUCKET_ACCESS_TOKEN", "access-tok");
    var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
    defer tk.deinit();
    try t.expectEqualStrings("access-tok", tk.read);
    try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.read_source.label());
}

test "the token file is read when the environment is empty, and an empty file is not a token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "  file-token\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("file-token", tk.read);
        try t.expect(std.mem.endsWith(u8, tk.read_source.label(), "token"));
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "\n" });
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expect(!tk.hasRead());
    try t.expectEqualStrings("not set", tk.read_source.label());
}

test "the Basic header is the base64 of email:token" {
    const h = try basicHeader(t.allocator, "me@example.com", "s3cret");
    defer t.allocator.free(h);
    try t.expectEqualStrings("Basic bWVAZXhhbXBsZS5jb206czNjcmV0", h);
}

test "the diagnostic block names the source and the length and never the token" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATATT-access-secret-value");
    var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
    defer tk.deinit();
    const text = try describe(t.allocator, &tk);
    defer t.allocator.free(text);
    // `--check` prints this block: the variable it came from, how long
    // it is, and not one byte of it.
    try t.expect(std.mem.indexOf(u8, text, "token source: BITBUCKET_ACCESS_TOKEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "25 chars, not shown") != null);
    try t.expect(std.mem.indexOf(u8, text, "approve token: BITBUCKET_ACCESS_TOKEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "secret") == null);

    // From the file, `--check` names the file and its length, and the
    // approve token says it is the same one.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "ATATT-file-secret-value\n" });
    var bare = std.process.Environ.Map.init(t.allocator);
    defer bare.deinit();
    var ftk = try resolve(t.allocator, t.io, &bare, dir);
    defer ftk.deinit();
    const ftext = try describe(t.allocator, &ftk);
    defer t.allocator.free(ftext);
    try t.expect(std.mem.indexOf(u8, ftext, "/token") != null);
    try t.expect(std.mem.indexOf(u8, ftext, "23 chars, not shown") != null);
    try t.expect(std.mem.indexOf(u8, ftext, "approve token: the read token") != null);
    try t.expect(std.mem.indexOf(u8, ftext, "secret") == null);
}
