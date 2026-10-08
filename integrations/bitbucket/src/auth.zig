//! The token. Bitbucket Cloud takes two kinds and they are **not**
//! interchangeable on the wire:
//!
//!   - an **account** credential — an Atlassian API token (`ATATT…`) or
//!     a Bitbucket app password — goes over
//!     `Authorization: Basic base64(email:token)`. It belongs to a
//!     person, so `/2.0/user` answers with that person.
//!   - an **access token** (`ATCTT…`) — repository, project or
//!     workspace scoped — goes over `Authorization: Bearer <token>`.
//!     It belongs to no person, so `/2.0/user` has nothing to answer
//!     and 401s however good the token is.
//!
//! Send either one the other way round and Bitbucket answers 401 with
//! no hint that the token itself was fine. `kindOf` reads the kind off
//! the token and `authHeader` writes the matching scheme, so neither
//! the caller nor the user has to know which they hold.
//!
//! **The rule: `<config dir>/token` when it is there, else the
//! environment.** The file is mnml's own token. A shell commonly
//! exports the machine-wide variables below for other tools, and
//! Bitbucket counts its rate limit per token — so a pane that took the
//! exported one would spend, and be throttled on, everybody else's
//! budget. Present (and not empty), the file is the token for reads
//! AND for the approve write, whatever the environment holds.
//!
//! With no file, the environment answers, as it always did — with the
//! one exception the paragraph above forces. An access token has no
//! account, so the tabs that filter to *your* pull requests (`mine`,
//! `reviewing`), `--values` and the workspace repo enumeration have
//! nothing to filter by. When an account credential is available too,
//! **reads take the account credential** and `BITBUCKET_ACCESS_TOKEN`
//! stays the approve token. With only an access token — in the file or
//! exported — reads use it; `--check` then reports the workspace it
//! reached instead of a person, and says that the `mine` tabs need
//! `account_id` set in `config.zon`.
//!
//! In full:
//!
//!   1. `<config dir>/token` — one line, `chmod 600`; read and approve.
//!      A file that is there but cannot be read (no permission, a
//!      directory) is an error — never a silent fall through to the
//!      environment, which would spend another tool's token. Only an
//!      absent or empty file falls through.
//!   2. `BITBUCKET_ACCESS_TOKEN` — the approve token whenever it is set
//!   3. `BITBUCKET_API_TOKEN` — an Atlassian API token
//!   4. `BITBUCKET_APP_PASSWORD` — a Bitbucket app password
//!   5. `BITBUCKET_PERSONAL_TOKEN` — either kind, often exported as
//!      `email:token`; only the half after the colon is the token
//!
//! …the variables walked once for an account credential and, failing
//! that, once for anything at all; with no file, the approve token is
//! `BITBUCKET_ACCESS_TOKEN` when set and the read token otherwise. The
//! reference's three variables are kept so a machine already exporting
//! one keeps working.
//!
//! **A token is never printed.** `Source.label` names where it came
//! from and `describe` says how long it is and which scheme it will go
//! out with; the test below holds that line for the whole diagnostic
//! block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const write_env_name = "BITBUCKET_ACCESS_TOKEN";
/// In resolution order, behind the token file. `BITBUCKET_ACCESS_TOKEN`
/// leads — except that the read pass prefers an account credential
/// wherever it finds one, because an access token has no account to
/// filter `mine` by.
pub const env_names = [_][]const u8{ write_env_name, "BITBUCKET_API_TOKEN", "BITBUCKET_APP_PASSWORD", "BITBUCKET_PERSONAL_TOKEN" };
pub const file_name = "token";

/// Bitbucket spells a repository / project / workspace access token
/// with this prefix. Everything else — an Atlassian API token
/// (`ATATT…`), an app password — is an account credential.
pub const access_token_prefix = "ATCTT";

pub const Scheme = enum {
    basic,
    bearer,

    pub fn label(s: Scheme) []const u8 {
        return switch (s) {
            .basic => "Basic base64(email:token)",
            .bearer => "Bearer <token>",
        };
    }
};

pub const Kind = enum {
    /// An Atlassian API token or a Bitbucket app password: a person's
    /// credential, so `/2.0/user` answers.
    account,
    /// `ATCTT…` — repository, project or workspace scoped. No account.
    access_token,

    pub fn scheme(k: Kind) Scheme {
        return switch (k) {
            .account => .basic,
            .access_token => .bearer,
        };
    }

    /// Why that scheme — the half of `--check` that turns a bare
    /// "Bearer" into something a user can act on.
    pub fn why(k: Kind) []const u8 {
        return switch (k) {
            .account => "an account credential (an Atlassian API token or an app password) authenticates as a person",
            .access_token => "an `" ++ access_token_prefix ++ "…` access token is scoped to a repository, a project or a workspace, not to a person",
        };
    }

    /// An access token has no `/2.0/user` to answer with.
    pub fn hasAccount(k: Kind) bool {
        return k == .account;
    }
};

pub fn kindOf(token: []const u8) Kind {
    return if (std.mem.startsWith(u8, token, access_token_prefix)) .access_token else .account;
}

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
    /// Non-empty when `<config dir>/token` is there but is no token:
    /// it cannot be read. The
    /// environment is then NOT consulted — owned by `arena`.
    file_problem: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Tokens) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasRead(self: *const Tokens) bool {
        return self.read.len > 0;
    }

    pub fn readKind(self: *const Tokens) Kind {
        return kindOf(self.read);
    }

    pub fn writeKind(self: *const Tokens) Kind {
        return kindOf(self.write);
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
    // The file first, and whole: mnml's own token, for reads and for
    // the approve write. An exported variable is some other tool's
    // token, and Bitbucket's budget is per token.
    switch (try readTokenFile(a, io, config_dir)) {
        .token => |pair| {
            out.read = pair.token;
            out.read_source = .{ .file = pair.path };
            out.write = pair.token;
            out.write_source = .same_as_read;
            out.arena = arena;
            return out;
        },
        // There, and no token: say so, and do not reach for an
        // exported one — that is the budget the file exists to keep
        // out of.
        .problem => |pair| {
            out.read_source = .{ .file = pair.path };
            out.file_problem = pair.token;
            out.arena = arena;
            return out;
        },
        .absent => {},
    }
    // No file. Two passes over the environment. The first takes only
    // an account credential, because reads want an account to filter
    // `mine` / `reviewing` by and an access token has none. The second
    // takes whatever is there, so a machine exporting nothing but
    // `BITBUCKET_ACCESS_TOKEN` still reads — over Bearer, with the
    // workspace standing in for the account.
    for ([_]bool{ true, false }) |account_only| {
        for (env_names) |name| {
            if (fromEnv(env, name)) |v| {
                if (account_only and kindOf(v) != .account) continue;
                out.read = try a.dupe(u8, v);
                out.read_source = .{ .env = name };
                break;
            }
        }
        if (out.read.len > 0) break;
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

const FileRead = union(enum) {
    /// No file, or nothing but blank lines in it: the environment answers.
    absent,
    token: FilePair,
    /// There, and not a token; `.token` is the reason, for `--check`
    /// and the pane's setup screen.
    problem: FilePair,
};

fn readTokenFile(a: Allocator, io: Io, dir: []const u8) Allocator.Error!FileRead {
    const p = try std.fs.path.join(a, &.{ dir, file_name });
    const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .problem = .{ .path = p, .token = try std.fmt.allocPrint(a, "token file exists but cannot be read: {s} ({s})", .{ p, @errorName(e) }) } },
    };
    const token = stripEmailPrefix(std.mem.trim(u8, text, " \t\r\n"));
    if (token.len == 0) return .absent;
    return .{ .token = .{ .token = token, .path = p } };
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

/// `Bearer <token>`, owned.
pub fn bearerHeader(gpa: Allocator, token: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
}

/// The `Authorization` header this token goes out with — the scheme
/// picked off the token's own kind, so a caller never has to know
/// which of the two it holds.
pub fn authHeader(gpa: Allocator, email: []const u8, token: []const u8) Allocator.Error![]u8 {
    return switch (kindOf(token).scheme()) {
        .basic => basicHeader(gpa, email, token),
        .bearer => bearerHeader(gpa, token),
    };
}

/// The lines `--check` / `--diag` print: where each token came from
/// and how long it is. Never a byte of the token itself.
pub fn describe(gpa: Allocator, tk: *const Tokens) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    if (tk.file_problem.len > 0) {
        w.print("token source: {s}\n", .{tk.file_problem}) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
    w.print("token source: {s}", .{tk.read_source.label()}) catch return error.OutOfMemory;
    if (tk.hasRead()) w.print(" (loaded, {d} chars, not shown)", .{tk.read.len}) catch return error.OutOfMemory;
    if (tk.hasRead()) {
        const k = tk.readKind();
        w.print("\nauth scheme: {s} — {s}", .{ k.scheme().label(), k.why() }) catch return error.OutOfMemory;
    }
    w.print("\napprove token: {s}", .{tk.write_source.label()}) catch return error.OutOfMemory;
    if (tk.write_source == .env) w.print(" ({d} chars, not shown)", .{tk.write.len}) catch return error.OutOfMemory;
    if (tk.write.len > 0 and tk.writeKind() != tk.readKind()) {
        w.print(" · {s}", .{tk.writeKind().scheme().label()}) catch return error.OutOfMemory;
    }
    w.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Whether `--check` must say `account_id` is missing before it asks
/// anything: the token file holds an access token — which has no
/// account — and `config.zon` names none.
pub fn needsAccountId(tk: *const Tokens, account_id: []const u8) bool {
    return tk.read_source == .file and tk.readKind() == .access_token and account_id.len == 0;
}

/// `--check`'s line for `needsAccountId`, naming the config to edit.
/// Owned.
pub fn accountIdHint(gpa: Allocator, config_path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "note: set `account_id` in {s} — the token file holds an access token, which has no account, and the `mine` / `reviewing` tabs need one\n", .{config_path});
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the token file is the token — reads and approve — over every variable; with no file the environment answers in its old order" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "ATCTTfile-fake-0001\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // Every variable a shell might export for other tools.
    try env.put("BITBUCKET_API_TOKEN", "ATATTenv-api-fake");
    try env.put("BITBUCKET_APP_PASSWORD", "env-app-pw-fake");
    try env.put("BITBUCKET_PERSONAL_TOKEN", "me@x.com:ATATTenv-personal-fake");
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATCTTenv-access-fake");
    // Present: the file, for reads AND the approve write — even though
    // it is an access token and an account credential is exported.
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("ATCTTfile-fake-0001", tk.read);
        try t.expect(tk.read_source == .file);
        try t.expect(std.mem.endsWith(u8, tk.read_source.label(), "token"));
        try t.expectEqualStrings("ATCTTfile-fake-0001", tk.write);
        try t.expectEqual(Source.same_as_read, tk.write_source);
        try t.expectEqual(Kind.access_token, tk.readKind());
    }
    // Absent: the environment, unchanged — an account credential for
    // reads, BITBUCKET_ACCESS_TOKEN the approve token.
    try tmp.dir.deleteFile(t.io, "token");
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expectEqualStrings("ATATTenv-api-fake", tk.read);
        try t.expectEqualStrings("BITBUCKET_API_TOKEN", tk.read_source.label());
        try t.expectEqualStrings("ATCTTenv-access-fake", tk.write);
        try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.write_source.label());
    }
    // An empty variable is not set.
    try env.put("BITBUCKET_ACCESS_TOKEN", "");
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expectEqualStrings("ATATTenv-api-fake", tk.read);
    try t.expectEqual(Source.same_as_read, tk.write_source);
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
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expect(!tk.hasRead());
        try t.expectEqualStrings("not set", tk.read_source.label());
    }
    // An empty file is no file: the environment still answers.
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATCTTenv-access-fake");
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expectEqualStrings("ATCTTenv-access-fake", tk.read);
    try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.read_source.label());
}

test "the scheme comes off the token's kind: an ATCTT access token is a Bearer, everything else is Basic" {
    try t.expectEqual(Kind.access_token, kindOf("ATCTTxxxxx"));
    try t.expectEqual(Kind.account, kindOf("ATATTxxxxx"));
    try t.expectEqual(Kind.account, kindOf("an-app-password"));
    try t.expectEqual(Scheme.bearer, Kind.access_token.scheme());
    try t.expectEqual(Scheme.basic, Kind.account.scheme());
    try t.expect(!Kind.access_token.hasAccount());
    try t.expect(Kind.account.hasAccount());

    const bearer = try authHeader(t.allocator, "me@example.com", "ATCTTaccess");
    defer t.allocator.free(bearer);
    try t.expectEqualStrings("Bearer ATCTTaccess", bearer);
    // The email is not even in the header — an access token has no
    // account for it to name.
    try t.expect(std.mem.indexOf(u8, bearer, "me@example.com") == null);

    const basic = try authHeader(t.allocator, "me@example.com", "s3cret");
    defer t.allocator.free(basic);
    try t.expectEqualStrings("Basic bWVAZXhhbXBsZS5jb206czNjcmV0", basic);
}

test "reads take an account credential when there is one, and BITBUCKET_ACCESS_TOKEN stays the approve token" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // The machine that reported the 401: an access token exported as
    // BITBUCKET_ACCESS_TOKEN, an account token as
    // BITBUCKET_PERSONAL_TOKEN in `email:token` form.
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATCTTaccess");
    try env.put("BITBUCKET_PERSONAL_TOKEN", "me@x.com:ATATTaccount");
    {
        var tk = try resolve(t.allocator, t.io, &env, "/nonexistent");
        defer tk.deinit();
        try t.expectEqualStrings("ATATTaccount", tk.read);
        try t.expectEqualStrings("BITBUCKET_PERSONAL_TOKEN", tk.read_source.label());
        try t.expectEqual(Kind.account, tk.readKind());
        try t.expectEqualStrings("ATCTTaccess", tk.write);
        try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", tk.write_source.label());
        try t.expectEqual(Kind.access_token, tk.writeKind());
    }
    // With only the access token exported, reads use it — over Bearer.
    var only = std.process.Environ.Map.init(t.allocator);
    defer only.deinit();
    try only.put("BITBUCKET_ACCESS_TOKEN", "ATCTTaccess");
    var tk = try resolve(t.allocator, t.io, &only, "/nonexistent");
    defer tk.deinit();
    try t.expectEqualStrings("ATCTTaccess", tk.read);
    try t.expectEqual(Kind.access_token, tk.readKind());
}

test "an account token in the file is the approve token too: an exported access token is someone else's" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "ATATTfrom-the-file\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_ACCESS_TOKEN", "ATCTTaccess");
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expectEqualStrings("ATATTfrom-the-file", tk.read);
    try t.expect(std.mem.endsWith(u8, tk.read_source.label(), "token"));
    try t.expectEqualStrings("ATATTfrom-the-file", tk.write);
    try t.expectEqual(Source.same_as_read, tk.write_source);
    try t.expect(!needsAccountId(&tk, ""));
}

test "an access token in the file with no account_id is what --check warns about, and nothing else is" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "ATCTTfile-fake-0002\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expect(needsAccountId(&tk, ""));
    try t.expect(!needsAccountId(&tk, "{fake-account}"));
    const hint = try accountIdHint(t.allocator, "/cfg/config.zon");
    defer t.allocator.free(hint);
    try t.expectEqualStrings("note: set `account_id` in /cfg/config.zon — the token file holds an access token, which has no account, and the `mine` / `reviewing` tabs need one\n", hint);
    // An exported access token is not the token file's case.
    var exported = std.process.Environ.Map.init(t.allocator);
    defer exported.deinit();
    try exported.put("BITBUCKET_ACCESS_TOKEN", "ATCTTenv-access-fake");
    var etk = try resolve(t.allocator, t.io, &exported, "/nonexistent");
    defer etk.deinit();
    try t.expect(!needsAccountId(&etk, ""));
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
    try t.expect(sdk_testing.pathContains(ftext, "/token"));
    try t.expect(std.mem.indexOf(u8, ftext, "23 chars, not shown") != null);
    try t.expect(std.mem.indexOf(u8, ftext, "approve token: the read token") != null);
    try t.expect(std.mem.indexOf(u8, ftext, "secret") == null);
}

test "a token file that is there and cannot be read is an error, never a fall-through to an exported token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_PERSONAL_TOKEN", "x@acme.example:ATATTfakeEnvPersonal05");

    // A directory named `token`.
    try tmp.dir.createDirPath(t.io, "token");
    {
        var tk = try resolve(t.allocator, t.io, &env, dir);
        defer tk.deinit();
        try t.expect(!tk.hasRead());
        try t.expect(std.mem.indexOf(u8, tk.file_problem, "token file exists but cannot be read") != null);
        try t.expect(sdk_testing.pathContains(tk.file_problem, "/token"));
        try t.expect(tk.read_source == .file);
        const text = try describe(t.allocator, &tk);
        defer t.allocator.free(text);
        try t.expect(std.mem.startsWith(u8, text, "token source: token file exists but cannot be read"));
        try t.expect(std.mem.indexOf(u8, text, "BITBUCKET_PERSONAL_TOKEN") == null);
        try t.expect(std.mem.indexOf(u8, text, "Personal05") == null);
    }
    try tmp.dir.deleteDir(t.io, "token");

    // Mode 000. Windows has no such mode, and root reads it anyway.
    if (@import("builtin").os.tag == .windows) return;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "token", .data = "ATCTTfakeAccess0000000000000001\n" });
    try tmp.dir.setFilePermissions(t.io, "token", @enumFromInt(0), .{});
    defer tmp.dir.setFilePermissions(t.io, "token", @enumFromInt(0o600), .{}) catch {};
    if (tmp.dir.readFileAlloc(t.io, "token", t.allocator, .limited(64))) |bytes| {
        t.allocator.free(bytes);
        return error.SkipZigTest; // running as root
    } else |_| {}
    var tk = try resolve(t.allocator, t.io, &env, dir);
    defer tk.deinit();
    try t.expect(!tk.hasRead());
    try t.expect(std.mem.indexOf(u8, tk.file_problem, "token file exists but cannot be read") != null);
    try t.expect(std.mem.indexOf(u8, tk.file_problem, "AccessDenied") != null or std.mem.indexOf(u8, tk.file_problem, "PermissionDenied") != null);
    try t.expectEqualStrings("", tk.write);
}

