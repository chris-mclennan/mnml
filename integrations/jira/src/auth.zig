//! Where the Jira API token comes from, and what happens when it does
//! not come from anywhere.
//!
//! The Rust tracker reads exactly one file. The brief for this one asks
//! for "the token from env or a file the user names", so the order is:
//!
//!   1. `jira.token_file` in `config.zon`, if the key is set
//!   2. `$<jira.token_env>` (default `JIRA_API_TOKEN`)
//!   3. `<data root>/integrations/jira/token`, the default file
//!
//! and a `Missing` is a first-class result, not an error string: the
//! pane paints it, naming the file to write and the page to get a token
//! from.
//!
//! Two rules carried over verbatim from the Rust app because they were
//! bought with a user's afternoon:
//!
//!   * **Strip surrounding quotes.** Atlassian's copy button hands out
//!     `"ATATT3x…"`; a quoted token authenticates as a *corrupted* token,
//!     which Jira answers with `200` and zero results rather than `401`.
//!     A user cannot debug that.
//!   * **Never preflight `/myself`.** A scoped token routinely lacks
//!     `read:me` while being perfectly able to search, so a `/myself`
//!     failure must degrade one feature (who "me" is), never the pane.
//!
//! The token value is never printed. `describe` reports its length and
//! where it came from, which is all a diagnostic needs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const default_env = "JIRA_API_TOKEN";
pub const token_file_name = "token";
pub const token_page = "https://id.atlassian.com/manage-profile/security/api-tokens";
pub const max_token_bytes = 16 * 1024;

pub const Source = enum {
    /// `jira.token_file`.
    config_file,
    /// `$<jira.token_env>`.
    environment,
    /// `<data root>/integrations/jira/token`.
    default_file,
    /// `~/.config/mnml-tracker-jira/token`, the reference's.
    legacy_file,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .config_file => "the file config.zon names",
            .environment => "the environment",
            .default_file => "the default token file",
            .legacy_file => "the reference tracker's token file",
        };
    }
};

pub const Reason = enum {
    /// Nothing anywhere: no env value, no file.
    nowhere,
    /// The file is there and holds nothing but whitespace (or quotes).
    empty_file,
    /// The variable is set to the empty string.
    empty_env,
    /// The file is there and could not be read.
    unreadable,
};

pub const Missing = struct {
    reason: Reason,
    /// The file that was looked at (or would be written), owned by the
    /// caller's arena.
    path: []const u8,
    /// The variable that was looked at.
    env_name: []const u8,
};

pub const Token = struct {
    value: []const u8,
    source: Source,
    path: []const u8 = "",
};

pub const Result = union(enum) {
    ok: Token,
    missing: Missing,
};

pub const Opts = struct {
    /// `jira.token_file`, `~` still unexpanded. Empty = not set.
    config_path: []const u8 = "",
    /// `jira.token_env`. Empty falls back to `JIRA_API_TOKEN`.
    env_name: []const u8 = "",
    /// mnml's data root, for the default file.
    data_root: ?[]const u8 = null,
};

/// `<data root>/integrations/jira/token`, owned.
pub fn defaultTokenPath(arena: Allocator, data_root: ?[]const u8) Allocator.Error![]const u8 {
    const root = data_root orelse return token_file_name;
    if (root.len == 0) return token_file_name;
    return std.fs.path.join(arena, &.{ root, "integrations", "jira", token_file_name });
}

/// `~/x` → `$HOME/x`. Anything else is returned as it came in.
pub fn expandHome(arena: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, "~")) return path;
    const h = home orelse return path;
    if (h.len == 0) return path;
    if (path.len == 1) return h;
    if (path[1] != '/' and path[1] != '\\') return path;
    return std.fs.path.join(arena, &.{ h, path[2..] });
}

/// Atlassian's copy button includes the quotes. Strip them, and the
/// whitespace either side of them.
pub fn clean(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    while (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    }
    return s;
}

/// Find the token. Everything returned lives on `arena`.
pub fn resolve(arena: Allocator, io: Io, env: *const std.process.Environ.Map, opts: Opts) Allocator.Error!Result {
    const env_name = if (opts.env_name.len > 0) opts.env_name else default_env;
    const home = env.get("HOME") orelse env.get("USERPROFILE");

    // 1. The file the config names, if it names one.
    if (opts.config_path.len > 0) {
        const path = try expandHome(arena, opts.config_path, home);
        switch (try readToken(arena, io, path)) {
            .ok => |v| return .{ .ok = .{ .value = v, .source = .config_file, .path = path } },
            .empty => return .{ .missing = .{ .reason = .empty_file, .path = path, .env_name = env_name } },
            .gone => return .{ .missing = .{ .reason = .nowhere, .path = path, .env_name = env_name } },
            .unreadable => return .{ .missing = .{ .reason = .unreadable, .path = path, .env_name = env_name } },
        }
    }

    const default_path = try defaultTokenPath(arena, opts.data_root);

    // 2. The environment.
    if (env.get(env_name)) |raw| {
        const v = clean(raw);
        if (v.len > 0) return .{ .ok = .{ .value = try arena.dupe(u8, v), .source = .environment } };
        return .{ .missing = .{ .reason = .empty_env, .path = default_path, .env_name = env_name } };
    }

    // 3. The default file.
    switch (try readToken(arena, io, default_path)) {
        .ok => |v| return .{ .ok = .{ .value = v, .source = .default_file, .path = default_path } },
        .empty => return .{ .missing = .{ .reason = .empty_file, .path = default_path, .env_name = env_name } },
        .gone => {},
        .unreadable => return .{ .missing = .{ .reason = .unreadable, .path = default_path, .env_name = env_name } },
    }
    // 4. The reference tracker's file, so a token already on the box works.
    if (home) |h| {
        const legacy = try std.fs.path.join(arena, &.{ h, ".config", "mnml-tracker-jira", token_file_name });
        switch (try readToken(arena, io, legacy)) {
            .ok => |v| return .{ .ok = .{ .value = v, .source = .legacy_file, .path = legacy } },
            else => {},
        }
    }
    return .{ .missing = .{ .reason = .nowhere, .path = default_path, .env_name = env_name } };
}

const Read = union(enum) { ok: []const u8, empty, gone, unreadable };

fn readToken(arena: Allocator, io: Io, path: []const u8) Allocator.Error!Read {
    const raw = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_token_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .gone,
        else => return .unreadable,
    };
    const v = clean(raw);
    if (v.len == 0) return .empty;
    return .{ .ok = v };
}

/// What the pane paints instead of a ticket list. Four lines: what is
/// wrong, where a token comes from, where to put it, and how to reload.
pub fn explain(arena: Allocator, m: Missing) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const head: []const u8 = switch (m.reason) {
        .nowhere => "No Jira API token.",
        .empty_file => try std.fmt.allocPrint(arena, "The token file is empty: {s}", .{m.path}),
        .empty_env => try std.fmt.allocPrint(arena, "${s} is set to the empty string.", .{m.env_name}),
        .unreadable => try std.fmt.allocPrint(arena, "The token file could not be read: {s}", .{m.path}),
    };
    try out.append(arena, head);
    try out.append(arena, "");
    try out.append(arena, try std.fmt.allocPrint(arena, "Make one at {s}", .{token_page}));
    try out.append(arena, try std.fmt.allocPrint(arena, "then either export ${s}=…", .{m.env_name}));
    try out.append(arena, try std.fmt.allocPrint(arena, "or save it (chmod 600) to {s}", .{m.path}));
    try out.append(arena, "");
    try out.append(arena, "Then press r to try again.");
    return out.toOwnedSlice(arena);
}

/// The `Authorization: Basic …` value for `email:token`, owned.
pub fn basicHeader(arena: Allocator, email: []const u8, token: []const u8) Allocator.Error![]u8 {
    const pair = try std.fmt.allocPrint(arena, "{s}:{s}", .{ email, token });
    defer arena.free(pair);
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, "Basic ".len + enc.calcSize(pair.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], pair);
    return out;
}

/// A diagnostic line that never carries the secret.
pub fn describe(arena: Allocator, r: Result) Allocator.Error![]u8 {
    return switch (r) {
        .ok => |t| if (t.path.len > 0)
            std.fmt.allocPrint(arena, "token: {d} chars, from {s} ({s})", .{ t.value.len, t.source.label(), t.path })
        else
            std.fmt.allocPrint(arena, "token: {d} chars, from {s}", .{ t.value.len, t.source.label() }),
        .missing => |m| std.fmt.allocPrint(arena, "token: MISSING ({s}); looked at ${s} and {s}", .{ @tagName(m.reason), m.env_name, m.path }),
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "clean strips whitespace and the quotes Atlassian's copy button adds" {
    try testing.expectEqualStrings("ATATT3x", clean("  ATATT3x \n"));
    try testing.expectEqualStrings("ATATT3x", clean("\"ATATT3x\""));
    try testing.expectEqualStrings("ATATT3x", clean("'ATATT3x'"));
    try testing.expectEqualStrings("ATATT3x", clean(" \" ATATT3x \" "));
    // Only a matched pair goes; a quote inside the token stays.
    try testing.expectEqualStrings("AT\"ATT", clean("AT\"ATT"));
    try testing.expectEqualStrings("\"ab", clean("\"ab"));
    try testing.expectEqualStrings("", clean("  \"\"  "));
}

test "the environment wins over the default file, and a named file wins over both" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/jira/token", .data = "\"from-the-default-file\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "named.txt", .data = "  from-the-named-file  " });

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // Only the default file.
    const a1 = try resolve(arena, testing.io, &env, .{ .data_root = root });
    try testing.expectEqual(Source.default_file, a1.ok.source);
    try testing.expectEqualStrings("from-the-default-file", a1.ok.value);

    // The environment beats it.
    try env.put("JIRA_API_TOKEN", "from-the-env");
    const a2 = try resolve(arena, testing.io, &env, .{ .data_root = root });
    try testing.expectEqual(Source.environment, a2.ok.source);
    try testing.expectEqualStrings("from-the-env", a2.ok.value);

    // A custom variable name is honoured; the default one is then ignored.
    try env.put("ACME_TOKEN", "from-acme");
    const a3 = try resolve(arena, testing.io, &env, .{ .data_root = root, .env_name = "ACME_TOKEN" });
    try testing.expectEqualStrings("from-acme", a3.ok.value);

    // The config's file beats the environment.
    const named = try std.fs.path.join(arena, &.{ root, "named.txt" });
    const a4 = try resolve(arena, testing.io, &env, .{ .data_root = root, .config_path = named });
    try testing.expectEqual(Source.config_file, a4.ok.source);
    try testing.expectEqualStrings("from-the-named-file", a4.ok.value);
}

test "every refusal path names what to do, and none of them carries the token" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // Nothing anywhere.
    const nowhere = try resolve(arena, testing.io, &env, .{ .data_root = root });
    try testing.expectEqual(Reason.nowhere, nowhere.missing.reason);
    try testing.expect(sdk_testing.pathEndsWith(nowhere.missing.path, "integrations/jira/token"));
    const lines = try explain(arena, nowhere.missing);
    try testing.expectEqualStrings("No Jira API token.", lines[0]);
    try testing.expect(std.mem.indexOf(u8, lines[2], "id.atlassian.com") != null);
    try testing.expect(std.mem.indexOf(u8, lines[3], "JIRA_API_TOKEN") != null);

    // A variable set to nothing is its own reason — the user meant to
    // set it and the shell ate the value.
    try env.put("JIRA_API_TOKEN", "");
    const empty_env = try resolve(arena, testing.io, &env, .{ .data_root = root });
    try testing.expectEqual(Reason.empty_env, empty_env.missing.reason);

    // A file of quotes and whitespace is empty, not a token.
    try tmp.dir.createDirPath(testing.io, "integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/jira/token", .data = " \"\" \n" });
    var bare = std.process.Environ.Map.init(testing.allocator);
    defer bare.deinit();
    const empty_file = try resolve(arena, testing.io, &bare, .{ .data_root = root });
    try testing.expectEqual(Reason.empty_file, empty_file.missing.reason);

    // A named file that is not there refuses at that path, and does not
    // silently fall through to the environment.
    try env.put("JIRA_API_TOKEN", "from-the-env");
    const gone = try resolve(arena, testing.io, &env, .{ .data_root = root, .config_path = "/nowhere/token" });
    try testing.expectEqual(Reason.nowhere, gone.missing.reason);
    try testing.expectEqualStrings("/nowhere/token", gone.missing.path);

    const d = try describe(arena, gone);
    try testing.expect(std.mem.indexOf(u8, d, "MISSING") != null);
    try testing.expect(std.mem.indexOf(u8, d, "from-the-env") == null);
}

test "describe reports a length and a source, never the secret" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const d = try describe(a.allocator(), .{ .ok = .{ .value = "sup3r-s3cret", .source = .environment } });
    try testing.expectEqualStrings("token: 12 chars, from the environment", d);
    try testing.expect(std.mem.indexOf(u8, d, "sup3r") == null);
}

test "basicHeader is what Jira's HTTP Basic wants" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // `me@x.com:tok` base64-encodes to this.
    try testing.expectEqualStrings("Basic bWVAeC5jb206dG9r", try basicHeader(a.allocator(), "me@x.com", "tok"));
}

test "~ expands against HOME and nothing else does" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try sdk_testing.expectPath("/h/x/token", try expandHome(arena, "~/x/token", "/h"));
    try testing.expectEqualStrings("/h", try expandHome(arena, "~", "/h"));
    try testing.expectEqualStrings("~other/x", try expandHome(arena, "~other/x", "/h"));
    try testing.expectEqualStrings("~/x", try expandHome(arena, "~/x", null));
    try testing.expectEqualStrings("/abs/x", try expandHome(arena, "/abs/x", "/h"));
}
