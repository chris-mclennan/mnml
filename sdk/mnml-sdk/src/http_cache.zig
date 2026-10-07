//! The shared HTTP response cache: Bitbucket and Jira GET responses held
//! on disk, one file per URL, so a second process asking the same
//! question costs nothing. mnml and any other tool on the machine that
//! agrees to the format read and write the same files — the format is a
//! public contract (`docs/SDK.md`, "The shared HTTP response cache"),
//! and `testdata/http_cache_vectors.json` holds the cases every
//! implementation must agree on, vendored verbatim.
//!
//! `<root>/<service>/<sha256 of the canonical URL>.json`, `<root>`
//! being `http-cache/` under the first of `$MNML_SHARED_STATE_DIR`,
//! `$MNML_DATA_ROOT`, `~/.config/mnml` (`cache.sharedDir`, the rule
//! the recent-items cache resolves by):
//!
//! ```
//! {"version":1,"url":"<canonical URL>","key":"acme/widget#45","status":200,
//!  "etag":"\"abc\"","stamp":"2026-10-06T12:00:00Z","fetched_at":1790000000,
//!  "valid_until":0,"body":"…"}
//! ```
//!
//! and `<root>/<service>/changed/<sha256 of the item key>.json`, one
//! item's change stamp: anything that learns the item changed (a write
//! this process made) moves it forward, and every entry for that key
//! fetched before it is stale whatever its `valid_until` says.
//!
//! `decide` is the whole policy: fresh (answer from the body, no
//! request), revalidate (`If-None-Match`), or miss (a plain GET).
//!
//! **A cache is a hint.** Every read, parse and write failure here is
//! silent and costs a request. `$MNML_HTTP_CACHE=0` turns it off for a
//! process; `$MNML_RECENT_ITEMS` does not touch it.
//!
//! mnml writes integer seconds: `fetched_at` rounded DOWN (the time the
//! request left, so a change stamped while it was in flight still makes
//! the entry stale), `changed_at` rounded UP (so an entry another writer
//! fetched in the same second as our write is never taken as after it).
//! Times are read as numbers, integer or decimal.

const std = @import("std");
const cache = @import("cache.zig");
const store_mod = @import("store.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Map = std.process.Environ.Map;

/// The format's version, written as `version`; any other reads as a miss.
pub const format_version = 1;
/// A body over this is not stored.
pub const max_body: usize = 8 * 1024 * 1024;
/// A file over this is not read: an 8 MB body written with every
/// non-ASCII character as `\uXXXX` by another writer fits.
pub const read_limit: usize = 64 * 1024 * 1024;
/// Entries and change stamps older than this by modification time may go.
pub const max_age_secs: i64 = 7 * 86400;
/// How often `maybeGc` sweeps, machine-wide, by `<root>/.gc-at`.
pub const gc_every_secs: i64 = 86400;
/// `0` / `off` / `false` / `no` turns the cache off for a process.
pub const disable_env = "MNML_HTTP_CACHE";
/// The directory under the shared root.
pub const dir_name = "http-cache";

pub const Verdict = enum { fresh, revalidate, miss };

/// One query parameter a caller adds to a URL's own.
pub const Param = struct { name: []const u8, value: []const u8 };

/// One response file. Every slice borrows the allocator `load` read it on.
pub const Entry = struct {
    version: i64 = format_version,
    url: []const u8 = "",
    /// `<workspace>/<repo>#<id>`, `<workspace>/<repo>!<build>`, an issue
    /// key, or empty for a listing.
    key: []const u8 = "",
    status: i64 = 200,
    etag: []const u8 = "",
    /// The server's own last-changed value for `key`, when known.
    stamp: []const u8 = "",
    fetched_at: f64 = 0,
    /// Answer with no request until then; 0 is "always ask first".
    valid_until: f64 = 0,
    body: []const u8 = "",
    content_type: []const u8 = "",
};

// ─── where ──────────────────────────────────────────────────────────────

/// False when `$MNML_HTTP_CACHE` turns the cache off.
pub fn enabled(env: *const Map) bool {
    const v = env.get(disable_env) orelse return true;
    const s = std.mem.trim(u8, v, " \t");
    for ([_][]const u8{ "0", "off", "false", "no" }) |no| {
        if (std.ascii.eqlIgnoreCase(s, no)) return false;
    }
    return true;
}

/// `<shared root>/http-cache`; null with no home at all. Owned.
pub fn rootDir(gpa: Allocator, env: *const Map) Allocator.Error!?[]u8 {
    return cache.sharedDir(gpa, env, dir_name);
}

/// `<root>/<service>/<digest(url)>.json`. Owned.
pub fn entryPath(gpa: Allocator, root: []const u8, service: []const u8, url: []const u8) Allocator.Error![]u8 {
    const name = fileName(url);
    return std.fs.path.join(gpa, &.{ root, service, &name });
}

/// `<root>/<service>/changed/<digest(key)>.json`. Owned.
pub fn changedPath(gpa: Allocator, root: []const u8, service: []const u8, key: []const u8) Allocator.Error![]u8 {
    const name = fileName(key);
    return std.fs.path.join(gpa, &.{ root, service, "changed", &name });
}

/// `<digest(text)>.json` — the file name a canonical URL or a key gets.
pub fn fileName(text: []const u8) [64 + ".json".len]u8 {
    var out: [64 + ".json".len]u8 = undefined;
    const hex = digest(text);
    @memcpy(out[0..64], &hex);
    @memcpy(out[64..], ".json");
    return out;
}

/// The lower-case hex SHA-256 of `text`'s bytes.
pub fn digest(text: []const u8) [64]u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &sum, .{});
    return std.fmt.bytesToHex(sum, .lower);
}

/// The temp file a write goes through: `<target>.<pid>.tmp`, in the
/// target's own directory, so the rename over it is atomic and the name
/// is never mistaken for an entry. Owned.
pub fn tempPath(gpa: Allocator, target: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.{d}.tmp", .{ target, cache.pid() });
}

// ─── the canonical URL ──────────────────────────────────────────────────

/// The cache key for a GET of `url` with `params`: scheme and host
/// lower-cased, the default port and the fragment dropped, the path
/// byte for byte, and every query pair (blank values kept) decoded,
/// sorted by name then value, and percent-encoded with only
/// `A-Z a-z 0-9 - . _ ~` left bare. Credentials in the authority are
/// dropped. Owned.
pub fn canonical(gpa: Allocator, url: []const u8, params: []const Param) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parts = split(url);

    var pairs: std.ArrayList(Param) = .empty;
    var it = std.mem.splitScalar(u8, parts.query, '&');
    while (it.next()) |nv| {
        if (nv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, nv, '=');
        const name = if (eq) |i| nv[0..i] else nv;
        const value = if (eq) |i| nv[i + 1 ..] else "";
        try pairs.append(a, .{ .name = try unquote(a, name), .value = try unquote(a, value) });
    }
    for (params) |p| try pairs.append(a, p);
    std.mem.sort(Param, pairs.items, {}, pairLess);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(parts.scheme) catch return error.OutOfMemory;
    for (out.written()) |*c| c.* = std.ascii.toLower(c.*);
    if (parts.has_authority) {
        w.writeAll("://") catch return error.OutOfMemory;
        writeHost(w, parts.scheme, parts.host) catch return error.OutOfMemory;
    } else if (parts.scheme.len > 0) {
        w.writeByte(':') catch return error.OutOfMemory;
    }
    if (parts.has_authority and parts.path.len > 0 and parts.path[0] != '/') w.writeByte('/') catch return error.OutOfMemory;
    w.writeAll(parts.path) catch return error.OutOfMemory;
    for (pairs.items, 0..) |p, i| {
        w.writeByte(if (i == 0) '?' else '&') catch return error.OutOfMemory;
        quote(w, p.name) catch return error.OutOfMemory;
        w.writeByte('=') catch return error.OutOfMemory;
        quote(w, p.value) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const Parts = struct {
    scheme: []const u8 = "",
    has_authority: bool = false,
    /// The authority with any `user@` dropped.
    host: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
};

fn split(url: []const u8) Parts {
    var p: Parts = .{};
    // The fragment never reaches the server, so never the key.
    const no_frag = url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];
    var rest = no_frag;
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        p.scheme = rest[0..i];
        rest = rest[i + 3 ..];
        p.has_authority = true;
        const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
        var auth = rest[0..end];
        if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth = auth[at + 1 ..];
        p.host = auth;
        rest = rest[end..];
    }
    const q = std.mem.indexOfScalar(u8, rest, '?');
    p.path = rest[0 .. q orelse rest.len];
    p.query = if (q) |i| rest[i + 1 ..] else "";
    return p;
}

/// The host lower-cased, with its port unless it is the scheme's default.
fn writeHost(w: *Io.Writer, scheme: []const u8, authority: []const u8) Io.Writer.Error!void {
    // `[::1]:8443`: the port is after the bracket, not after the last colon.
    const colon = if (std.mem.lastIndexOfScalar(u8, authority, ']')) |rb|
        std.mem.indexOfScalarPos(u8, authority, rb, ':')
    else
        std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = authority[0 .. colon orelse authority.len];
    for (host) |c| try w.writeByte(std.ascii.toLower(c));
    const port_text = if (colon) |i| authority[i + 1 ..] else return;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return;
    if (port == 0) return;
    if (port == 443 and std.ascii.eqlIgnoreCase(scheme, "https")) return;
    if (port == 80 and std.ascii.eqlIgnoreCase(scheme, "http")) return;
    try w.print(":{d}", .{port});
}

/// Form decoding: `+` is a space, `%XX` a byte; bytes that do not make
/// UTF-8 become U+FFFD, as the reference decoder does.
fn unquote(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try raw.append(a, ' ');
        } else if (c == '%' and i + 2 < s.len and isHex(s[i + 1]) and isHex(s[i + 2])) {
            try raw.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable);
            i += 2;
        } else {
            try raw.append(a, c);
        }
    }
    if (std.unicode.utf8ValidateSlice(raw.items)) return raw.items;
    // One U+FFFD per maximal subpart (a cut-short sequence is one, not
    // one per byte), which is what the reference decoder emits.
    return std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(raw.items)});
}

fn isHex(c: u8) bool {
    return std.ascii.isHex(c);
}

/// UTF-8 as `%XX`, upper-case, with only the unreserved set bare.
fn quote(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

/// By name, then value. Byte order of UTF-8 is code-point order.
fn pairLess(_: void, x: Param, y: Param) bool {
    return switch (std.mem.order(u8, x.name, y.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, x.value, y.value) == .lt,
    };
}

// ─── the item a URL is about ────────────────────────────────────────────

/// `<workspace>/<repo>#<id>` for a pull request and everything under it,
/// `<workspace>/<repo>!<build number>` for a pipeline run, else empty —
/// workspace and repo lower-cased. Read off the URL's path, never its
/// query. Owned.
pub fn itemKey(gpa: Allocator, url: []const u8) Allocator.Error![]u8 {
    const path = split(url).path;
    for ([_]struct { seg: []const u8, mark: u8 }{
        .{ .seg = "pullrequests", .mark = '#' },
        .{ .seg = "pipelines", .mark = '!' },
    }) |kind| {
        const prefix = "/2.0/repositories/";
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, path, from, prefix)) |at| : (from = at + 1) {
            const rest = path[at + prefix.len ..];
            var segs = std.mem.splitScalar(u8, rest, '/');
            const ws = segs.next() orelse continue;
            const repo = segs.next() orelse continue;
            const what = segs.next() orelse continue;
            const id = segs.next() orelse continue;
            if (ws.len == 0 or repo.len == 0 or id.len == 0) continue;
            if (!std.mem.eql(u8, what, kind.seg)) continue;
            if (!allDigits(id)) continue;
            const out = try std.fmt.allocPrint(gpa, "{s}/{s}{c}{s}", .{ ws, repo, kind.mark, id });
            for (out[0 .. ws.len + 1 + repo.len]) |*c| c.* = std.ascii.toLower(c.*);
            return out;
        }
    }
    return gpa.dupe(u8, "");
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len > 0;
}

// ─── what may be held ───────────────────────────────────────────────────

/// Whether a Bitbucket canonical URL's answer is the same whichever
/// credential asks, and so may go where every token on the machine
/// reads it: under `/2.0/repositories/` only, and never with a `role=`
/// parameter (`?role=member` lists what the caller can see). A `role`
/// inside another parameter's value, such as a `q=` search, is held.
/// `canon` is `canonical`'s output, so every query name is in one form.
pub fn bitbucketShareable(canon: []const u8) bool {
    const parts = split(canon);
    if (!std.mem.startsWith(u8, parts.path, "/2.0/repositories/")) return false;
    var it = std.mem.splitScalar(u8, parts.query, '&');
    while (it.next()) |pair| if (std.mem.startsWith(u8, pair, "role=")) return false;
    return true;
}

// ─── deciding ───────────────────────────────────────────────────────────

/// fresh, revalidate or miss, in the contract's order:
///
/// 1. no entry, or `version` not 1: miss;
/// 2. `changed_at` after `fetched_at`: revalidate with an `etag`, else miss;
/// 3. the caller's `stamp` and the entry's both non-empty: equal is
///    fresh, different is revalidate with an `etag`, else miss;
/// 4. `now < valid_until`: fresh;
/// 5. an `etag`: revalidate; otherwise miss.
pub fn decide(entry: ?Entry, now: f64, changed_at: f64, stamp: []const u8) Verdict {
    const e = entry orelse return .miss;
    if (e.version != format_version) return .miss;
    const stale: Verdict = if (e.etag.len > 0) .revalidate else .miss;
    if (changed_at != 0 and changed_at > e.fetched_at) return stale;
    if (stamp.len > 0 and e.stamp.len > 0) return if (std.mem.eql(u8, stamp, e.stamp)) .fresh else stale;
    if (now < e.valid_until) return .fresh;
    return stale;
}

// ─── reading ────────────────────────────────────────────────────────────

/// The entry for canonical `url`, or null: none, unreadable, another
/// version, or a file that names another URL (a digest collision is
/// not an answer). On `a`.
pub fn load(a: Allocator, io: Io, root: []const u8, service: []const u8, url: []const u8) ?Entry {
    const path = entryPath(a, root, service, url) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(read_limit)) catch return null;
    const e = parseEntry(a, text) orelse return null;
    if (e.version != format_version or !std.mem.eql(u8, e.url, url)) return null;
    return e;
}

/// A response file's text as an `Entry`, whatever its version — `decide`
/// is what turns another version into a miss. Null when it is not a
/// JSON object or a field has the wrong type. On `a`.
pub fn parseEntry(a: Allocator, text: []const u8) ?Entry {
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch return null;
    return entryFromValue(v);
}

/// An `Entry` off a parsed JSON value (`parseEntry`, and the vectors).
pub fn entryFromValue(v: Value) ?Entry {
    if (v != .object) return null;
    const o = v.object;
    return .{
        .version = int(o, "version") orelse -1,
        .url = str(o, "url") orelse return null,
        .key = str(o, "key") orelse return null,
        .status = int(o, "status") orelse 200,
        .etag = str(o, "etag") orelse return null,
        .stamp = str(o, "stamp") orelse return null,
        .fetched_at = num(o, "fetched_at") orelse return null,
        .valid_until = num(o, "valid_until") orelse return null,
        .body = str(o, "body") orelse return null,
        .content_type = str(o, "content_type") orelse return null,
    };
}

/// When `key` last changed as far as anything on this machine knows;
/// 0 when nothing does.
pub fn changedAt(a: Allocator, io: Io, root: []const u8, service: []const u8, key: []const u8) f64 {
    if (key.len == 0) return 0;
    const path = changedPath(a, root, service, key) catch return 0;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return 0;
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch return 0;
    if (v != .object) return 0;
    if ((int(v.object, "version") orelse -1) != format_version) return 0;
    return num(v.object, "changed_at") orelse 0;
}

/// A string field; "" when absent or null, null when another type.
fn str(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        .null => "",
        else => null,
    };
}

/// A number field, integer or decimal; 0 when absent or null, null
/// when it is not a number.
fn num(o: ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        .null => 0,
        else => null,
    };
}

/// A whole number; `1.0` counts as 1.
fn int(o: ObjectMap, key: []const u8) ?i64 {
    const f = num(o, key) orelse return null;
    if (o.get(key) == null) return null;
    if (@floor(f) != f or !std.math.isFinite(f)) return null;
    return std.math.lossyCast(i64, f);
}

// ─── writing ────────────────────────────────────────────────────────────

pub const StoreOptions = struct {
    /// The canonical URL (`canonical`).
    url: []const u8,
    body: []const u8,
    etag: []const u8 = "",
    key: []const u8 = "",
    stamp: []const u8 = "",
    content_type: []const u8 = "",
    /// When the request was SENT, whole seconds rounded down (`sentAt`).
    now: i64,
    /// Answer with no request for this long; 0 writes `valid_until: 0`,
    /// "always ask first" — mnml's own policy.
    ttl_secs: i64 = 0,
};

/// Hold a 200 body for `opts.url`. True when it was written. A body over
/// `max_body` is not.
pub fn store(a: Allocator, io: Io, root: []const u8, service: []const u8, opts: StoreOptions) bool {
    if (opts.body.len > max_body) return false;
    const ok = write(a, io, root, service, .{
        .url = opts.url,
        .key = opts.key,
        .etag = opts.etag,
        .stamp = opts.stamp,
        .fetched_at = @floatFromInt(opts.now),
        .valid_until = if (opts.ttl_secs > 0) @floatFromInt(opts.now + opts.ttl_secs) else 0,
        .body = opts.body,
        .content_type = opts.content_type,
    });
    if (ok) _ = maybeGc(a, io, root, opts.now);
    return ok;
}

/// A 304 said `entry` is still current: `fetched_at` and `valid_until`
/// move forward to `now` (+ `ttl_secs`); `etag`, `stamp` and `body` stay.
pub fn confirm(a: Allocator, io: Io, root: []const u8, service: []const u8, entry: Entry, now: i64, ttl_secs: i64) bool {
    var e = entry;
    e.version = format_version;
    e.fetched_at = @floatFromInt(now);
    e.valid_until = if (ttl_secs > 0) @floatFromInt(now + ttl_secs) else 0;
    return write(a, io, root, service, e);
}

/// `key` changed at `when`: every entry for it fetched before then is
/// stale. Only ever forward — a stamp already at or past `when` stays.
/// True when the stamp is at least `when` afterwards.
pub fn markChanged(a: Allocator, io: Io, root: []const u8, service: []const u8, key: []const u8, when: i64) bool {
    if (key.len == 0) return false;
    if (changedAt(a, io, root, service, key) >= @as(f64, @floatFromInt(when))) return true;
    const path = changedPath(a, root, service, key) catch return false;
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print("{{\"version\":{d},\"key\":", .{format_version}) catch return false;
    store_mod.writeJsonString(w, key) catch return false;
    w.print(",\"changed_at\":{d}}}\n", .{when}) catch return false;
    return writeFile(a, io, path, out.written());
}

fn write(a: Allocator, io: Io, root: []const u8, service: []const u8, e: Entry) bool {
    const path = entryPath(a, root, service, e.url) catch return false;
    var out: Io.Writer.Allocating = .init(a);
    render(&out.writer, e) catch return false;
    return writeFile(a, io, path, out.written());
}

/// One entry as the contract's JSON. Times go out as integers when they
/// are whole, which is everything mnml itself writes.
pub fn render(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.print("{{\"version\":{d},\"url\":", .{format_version});
    try store_mod.writeJsonString(w, e.url);
    try w.writeAll(",\"key\":");
    try store_mod.writeJsonString(w, e.key);
    try w.writeAll(",\"status\":200,\"etag\":");
    try store_mod.writeJsonString(w, e.etag);
    try w.writeAll(",\"stamp\":");
    try store_mod.writeJsonString(w, e.stamp);
    try w.writeAll(",\"fetched_at\":");
    try writeTime(w, e.fetched_at);
    try w.writeAll(",\"valid_until\":");
    try writeTime(w, e.valid_until);
    if (e.content_type.len > 0) {
        try w.writeAll(",\"content_type\":");
        try store_mod.writeJsonString(w, e.content_type);
    }
    try w.writeAll(",\"body\":");
    try store_mod.writeJsonString(w, e.body);
    try w.writeAll("}\n");
}

fn writeTime(w: *Io.Writer, x: f64) Io.Writer.Error!void {
    if (std.math.isFinite(x) and @floor(x) == x and @abs(x) < 9.0e15) {
        try w.print("{d}", .{@as(i64, @intFromFloat(x))});
    } else if (std.math.isFinite(x)) {
        try w.print("{d}", .{x});
    } else {
        try w.writeAll("0");
    }
}

/// The whole file to `<path>.<pid>.tmp`, then a rename over `path`
/// (`cache.writeVia`, the recent-items cache's atomic write). No lock:
/// one file is one entry, and the last writer wins with a whole one.
fn writeFile(a: Allocator, io: Io, path: []const u8, text: []const u8) bool {
    if (std.fs.path.dirname(path)) |dir| cache.makeDir(io, dir);
    const tmp = tempPath(a, path) catch return false;
    return cache.writeVia(io, tmp, path, text);
}

// ─── the clock ──────────────────────────────────────────────────────────

/// Now in whole seconds, rounded down — a request's `fetched_at`.
pub fn sentAt(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

/// Now in whole seconds, rounded up — a write's `changed_at`.
pub fn changedNow(io: Io) i64 {
    const ms = Io.Timestamp.now(io, .real).toMilliseconds();
    return @divFloor(ms + 999, 1000);
}

// ─── collecting ─────────────────────────────────────────────────────────

/// Delete every entry, change stamp and abandoned temp file under `root`
/// whose modification time is more than `max_age` seconds before `now`.
/// How many went.
pub fn gc(a: Allocator, io: Io, root: []const u8, max_age: i64, now: i64) usize {
    var gone: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |svc| {
        if (svc.kind != .directory) continue;
        const sub = std.fs.path.join(a, &.{ root, svc.name }) catch continue;
        gone += sweep(a, io, sub, max_age, now);
        const changed = std.fs.path.join(a, &.{ sub, "changed" }) catch continue;
        gone += sweep(a, io, changed, max_age, now);
    }
    return gone;
}

fn sweep(a: Allocator, io: Io, path: []const u8, max_age: i64, now: i64) usize {
    _ = a;
    var gone: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |f| {
        if (f.kind != .file) continue;
        if (!std.mem.endsWith(u8, f.name, ".json") and !std.mem.endsWith(u8, f.name, ".tmp")) continue;
        const st = dir.statFile(io, f.name, .{}) catch continue;
        if (now - st.mtime.toSeconds() <= max_age) continue;
        dir.deleteFile(io, f.name) catch continue;
        gone += 1;
    }
    return gone;
}

/// `gc` at most once a day per machine, from whichever process stores
/// first after `<root>/.gc-at` is a day old. How many went.
pub fn maybeGc(a: Allocator, io: Io, root: []const u8, now: i64) usize {
    const marker = std.fs.path.join(a, &.{ root, ".gc-at" }) catch return 0;
    if (Io.Dir.cwd().statFile(io, marker, .{})) |st| {
        if (now - st.mtime.toSeconds() < gc_every_secs) return 0;
    } else |_| {}
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{now}) catch return 0;
    cache.makeDir(io, root);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = text }) catch return 0;
    return gc(a, io, root, max_age_secs, now);
}

// ─── a handle ───────────────────────────────────────────────────────────

/// One service's cache, as a client holds it: the root and the service
/// name, everything else per call. Copyable; `root` is borrowed.
pub const Dir = struct {
    /// `<shared root>/http-cache`.
    root: []const u8,
    /// `bitbucket` or `jira`.
    service: []const u8,

    /// The service's cache under the environment's root; null when
    /// `$MNML_HTTP_CACHE` turns it off or there is no home. `root` is
    /// owned by `gpa` — free it with `deinit`.
    pub fn fromEnv(gpa: Allocator, env: *const Map, service: []const u8) Allocator.Error!?Dir {
        if (!enabled(env)) return null;
        const root = (try rootDir(gpa, env)) orelse return null;
        return .{ .root = root, .service = service };
    }

    pub fn deinit(d: Dir, gpa: Allocator) void {
        gpa.free(d.root);
    }

    pub fn load(d: Dir, a: Allocator, io: Io, url: []const u8) ?Entry {
        return http_cache.load(a, io, d.root, d.service, url);
    }

    pub fn changedAt(d: Dir, a: Allocator, io: Io, key: []const u8) f64 {
        return http_cache.changedAt(a, io, d.root, d.service, key);
    }

    pub fn store(d: Dir, a: Allocator, io: Io, opts: StoreOptions) bool {
        return http_cache.store(a, io, d.root, d.service, opts);
    }

    pub fn confirm(d: Dir, a: Allocator, io: Io, entry: Entry, now: i64) bool {
        return http_cache.confirm(a, io, d.root, d.service, entry, now, 0);
    }

    pub fn markChanged(d: Dir, a: Allocator, io: Io, key: []const u8, when: i64) bool {
        return http_cache.markChanged(a, io, d.root, d.service, key, when);
    }
};

const http_cache = @This();

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const vectors_json = @embedFile("testdata/http_cache_vectors.json");

fn vectors(a: Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, a, vectors_json, .{});
}

/// A vector's `params` object as `Param`s: a list is one pair per
/// element, a number is its text.
fn vectorParams(a: Allocator, v: Value) ![]Param {
    var out: std.ArrayList(Param) = .empty;
    if (v != .object) return out.items;
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const items: []const Value = if (kv.value_ptr.* == .array) kv.value_ptr.array.items else &.{kv.value_ptr.*};
        for (items) |x| try out.append(a, .{ .name = kv.key_ptr.*, .value = switch (x) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
            .number_string => |s| s,
            .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
            .bool => |b| if (b) "True" else "False",
            else => "",
        } });
    }
    return out.items;
}

/// Every section the vectors file carries, and how each one runs. A
/// section not named here fails the test by name, so a re-vendor that
/// adds one cannot pass by being skipped.
const vector_sections = [_]struct { name: []const u8, run: *const fn (Allocator, []const Value) anyerror!void }{
    .{ .name = "canonical", .run = runCanonical },
    .{ .name = "item_key", .run = runItemKey },
    .{ .name = "decide", .run = runDecide },
    .{ .name = "bitbucket_never_held", .run = runNeverHeld },
};

test "the shared vectors: every section runs, and none is unknown" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try vectors(a);
    var it = doc.object.iterator();
    var ran: usize = 0;
    sections: while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (std.mem.eql(u8, name, "version")) {
            if (kv.value_ptr.* != .integer or kv.value_ptr.integer != format_version) {
                std.debug.print("vectors: version is not {d}\n", .{format_version});
                return error.TestUnexpectedResult;
            }
            continue;
        }
        for (vector_sections) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            if (kv.value_ptr.* != .array or kv.value_ptr.array.items.len == 0) {
                std.debug.print("vectors: section \"{s}\" has no cases\n", .{name});
                return error.TestUnexpectedResult;
            }
            try s.run(a, kv.value_ptr.array.items);
            ran += 1;
            continue :sections;
        }
        std.debug.print("vectors: unknown section \"{s}\" — teach the test to run it\n", .{name});
        return error.TestUnexpectedResult;
    }
    try t.expectEqual(vector_sections.len, ran);
}

fn runCanonical(a: Allocator, cases: []const Value) !void {
    for (cases) |c| {
        const o = c.object;
        const url = o.get("url").?.string;
        const got = try canonical(a, url, try vectorParams(a, o.get("params").?));
        const name = fileName(got);
        const want = o.get("canonical").?.string;
        if (!std.mem.eql(u8, want, got) or !std.mem.eql(u8, o.get("file").?.string, &name)) {
            std.debug.print("canonical case \"{s}\": want {s} ({s}), got {s} ({s})\n", .{ url, want, o.get("file").?.string, got, &name });
            return error.TestExpectedEqual;
        }
    }
}

fn runItemKey(a: Allocator, cases: []const Value) !void {
    for (cases) |c| {
        const url = c.object.get("url").?.string;
        const want = c.object.get("key").?.string;
        const got = try itemKey(a, url);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("item_key case \"{s}\": want \"{s}\", got \"{s}\"\n", .{ url, want, got });
            return error.TestExpectedEqual;
        }
    }
}

fn runDecide(_: Allocator, cases: []const Value) !void {
    for (cases) |c| {
        const o = c.object;
        const entry: ?Entry = if (o.get("entry").? == .null) null else entryFromValue(o.get("entry").?).?;
        const now = num(o, "now").?;
        const changed = num(o, "changed_at").?;
        const want = std.meta.stringToEnum(Verdict, o.get("expect").?.string).?;
        const got = decide(entry, now, changed, o.get("stamp").?.string);
        if (got != want) {
            std.debug.print("decide case \"{s}\": want {s}, got {s}\n", .{ o.get("name").?.string, @tagName(want), @tagName(got) });
            return error.TestExpectedEqual;
        }
    }
}

/// Run through `canonical` first, as every caller does.
fn runNeverHeld(a: Allocator, cases: []const Value) !void {
    for (cases) |c| {
        const url = c.object.get("url").?.string;
        const want_never = c.object.get("never_held").?.bool;
        const held = bitbucketShareable(try canonical(a, url, &.{}));
        if (held == want_never) {
            std.debug.print("bitbucket_never_held case \"{s}\": want never_held={}, got {}\n", .{ url, want_never, !held });
            return error.TestExpectedEqual;
        }
    }
}

test "canonical: bytes that are not UTF-8 become one U+FFFD per broken sequence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A cut-short three-byte sequence is one replacement; a cut-short
    // four-byte one is one; an encoded surrogate is three.
    try t.expectEqualStrings("https://example.org/p?q=%EF%BF%BDa", try canonical(a, "https://example.org/p?q=%E2%82a", &.{}));
    try t.expectEqualStrings("https://example.org/p?r=%EF%BF%BD", try canonical(a, "https://example.org/p?r=%F0%9F%98", &.{}));
    try t.expectEqualStrings("https://example.org/p?s=%EF%BF%BD%EF%BF%BD%EF%BF%BD", try canonical(a, "https://example.org/p?s=%ED%A0%80", &.{}));
}

test "canonical: credentials, a blank query, a lone name, plus as space, a broken escape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("https://example.org/p", try canonical(a, "HTTPS://user:pw@Example.ORG/p?", &.{}));
    try t.expectEqualStrings("http://example.org/p?a=&b=a%20b", try canonical(a, "http://example.org:80/p?b=a+b&a", &.{}));
    try t.expectEqualStrings("https://example.org/p?x=%25zz", try canonical(a, "https://example.org/p?x=%zz", &.{}));
    try t.expectEqualStrings("https://example.org?q=1", try canonical(a, "https://example.org?q=1", &.{}));
    // The path is byte for byte: its case and its escapes stay.
    try t.expectEqualStrings("https://example.org/A%2fB", try canonical(a, "https://example.org/A%2fB", &.{}));
}

fn scratchRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(t.io, buf)];
}

test "store, load, confirm: a 304 moves the clock and keeps the tag, the stamp and the body" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try scratchRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try canonical(a, "https://api.bitbucket.org/2.0/repositories/acme/widget/pullrequests/45", &.{});
    const body = "{\"title\":\"Robin's \\\"fix\\\"\",\"x\":\"\x01\tcaf\u{e9}\"}";
    try t.expect(load(a, t.io, root, "bitbucket", url) == null);
    try t.expect(store(a, t.io, root, "bitbucket", .{
        .url = url,
        .body = body,
        .etag = "\"e1\"",
        .key = try itemKey(a, url),
        .stamp = "2026-10-06T12:00:00Z",
        .content_type = "application/json",
        .now = 1000,
    }));
    const e = load(a, t.io, root, "bitbucket", url).?;
    try t.expectEqualStrings(body, e.body);
    try t.expectEqualStrings("\"e1\"", e.etag);
    try t.expectEqualStrings("acme/widget#45", e.key);
    try t.expectEqualStrings("2026-10-06T12:00:00Z", e.stamp);
    try t.expectEqualStrings("application/json", e.content_type);
    try t.expectEqual(@as(f64, 1000), e.fetched_at);
    try t.expectEqual(@as(f64, 0), e.valid_until);
    try t.expectEqual(Verdict.revalidate, decide(e, 1001, 0, ""));
    try t.expectEqual(Verdict.fresh, decide(e, 1001, 0, "2026-10-06T12:00:00Z"));

    try t.expect(confirm(a, t.io, root, "bitbucket", e, 2000, 60));
    const c = load(a, t.io, root, "bitbucket", url).?;
    try t.expectEqual(@as(f64, 2000), c.fetched_at);
    try t.expectEqual(@as(f64, 2060), c.valid_until);
    try t.expectEqualStrings(body, c.body);
    try t.expectEqualStrings("\"e1\"", c.etag);
    try t.expectEqualStrings("2026-10-06T12:00:00Z", c.stamp);

    // mnml writes integers, and the file names the field set exactly.
    const path = try entryPath(a, root, "bitbucket", url);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .limited(1 << 20));
    try t.expect(std.mem.indexOf(u8, text, "\"fetched_at\":2000,") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"status\":200") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"version\":1") != null);
    // Another writer's floats and an unknown field read the same.
    const fleet = "{\"version\": 1, \"url\": \"U\", \"key\": \"\", \"status\": 200, \"etag\": \"\", \"stamp\": \"\", \"fetched_at\": 1000.25, \"valid_until\": 1060.5, \"content_type\": \"\", \"extra\": [1], \"body\": \"[]\"}";
    const f = parseEntry(a, fleet).?;
    try t.expectEqual(@as(f64, 1060.5), f.valid_until);
    try t.expectEqual(Verdict.fresh, decide(f, 1060, 0, ""));
    // A body over the cap is not stored; nonsense on disk is a miss.
    const big = try a.alloc(u8, max_body + 1);
    @memset(big, 'x');
    try t.expect(!store(a, t.io, root, "bitbucket", .{ .url = "https://example.org/big", .body = big, .now = 1 }));
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "{not json" });
    try t.expect(load(a, t.io, root, "bitbucket", url) == null);
}

test "a write goes through <target>.<pid>.tmp and a rename: no temp file is left, and none is ever read as an entry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try scratchRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://example.org/x";
    const target = try entryPath(a, root, "jira", url);
    const tmp_name = try tempPath(a, target);
    // The temp file sits beside the target — the rename is atomic only
    // within one directory — and is never the target's own name.
    try t.expectEqualStrings(std.fs.path.dirname(target).?, std.fs.path.dirname(tmp_name).?);
    try t.expect(std.mem.endsWith(u8, tmp_name, ".tmp"));
    try t.expect(!std.mem.eql(u8, tmp_name, target));
    try t.expect(std.mem.startsWith(u8, tmp_name, target));

    // An abandoned temp file of another process's, half written: the
    // reader takes the entry, never the temp.
    try t.expect(store(a, t.io, root, "jira", .{ .url = url, .body = "old", .now = 10 }));
    const torn = try std.fmt.allocPrint(a, "{s}.99999.tmp", .{target});
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = torn, .data = "{\"version\":1,\"url\":\"https://exa" });
    try t.expectEqualStrings("old", load(a, t.io, root, "jira", url).?.body);
    try t.expect(store(a, t.io, root, "jira", .{ .url = url, .body = "new", .now = 11 }));
    try t.expectEqualStrings("new", load(a, t.io, root, "jira", url).?.body);

    // Our own temp file is gone after each write: the directory holds
    // the entry and the other process's leftover, nothing of ours.
    var dir = try Io.Dir.cwd().openDir(t.io, std.fs.path.dirname(target).?, .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(t.io)) |e| {
        if (e.kind != .file) continue;
        n += 1;
        try t.expect(std.mem.endsWith(u8, e.name, ".json") or std.mem.endsWith(u8, e.name, ".99999.tmp"));
    }
    try t.expectEqual(@as(usize, 2), n);
}

test "markChanged only moves forward, and a change after the fetch makes the entry stale" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try scratchRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(f64, 0), changedAt(a, t.io, root, "bitbucket", "acme/widget#45"));
    try t.expect(markChanged(a, t.io, root, "bitbucket", "acme/widget#45", 2000));
    try t.expectEqual(@as(f64, 2000), changedAt(a, t.io, root, "bitbucket", "acme/widget#45"));
    // Backwards is a no-op that still says the stamp is at least that.
    try t.expect(markChanged(a, t.io, root, "bitbucket", "acme/widget#45", 1500));
    try t.expectEqual(@as(f64, 2000), changedAt(a, t.io, root, "bitbucket", "acme/widget#45"));
    try t.expect(markChanged(a, t.io, root, "bitbucket", "acme/widget#45", 2500));
    try t.expectEqual(@as(f64, 2500), changedAt(a, t.io, root, "bitbucket", "acme/widget#45"));
    try t.expect(!markChanged(a, t.io, root, "bitbucket", "", 3000));
    // The file is the contract's shape, under changed/.
    const p = try changedPath(a, root, "bitbucket", "acme/widget#45");
    try t.expect(std.mem.indexOf(u8, p, "changed") != null);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, a, .limited(4096));
    try t.expectEqualStrings("{\"version\":1,\"key\":\"acme/widget#45\",\"changed_at\":2500}\n", text);

    const url = "https://api.bitbucket.org/2.0/repositories/acme/widget/pullrequests/45";
    try t.expect(store(a, t.io, root, "bitbucket", .{ .url = url, .body = "{}", .etag = "\"t\"", .key = "acme/widget#45", .now = 2400, .ttl_secs = 600 }));
    const e = load(a, t.io, root, "bitbucket", url).?;
    try t.expectEqual(Verdict.revalidate, decide(e, 2401, changedAt(a, t.io, root, "bitbucket", e.key), ""));
    try t.expectEqual(Verdict.fresh, decide(e, 2401, 0, ""));
}

test "gc removes what is a week old, keeps the rest, and runs at most once a day" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try scratchRoot(&tmp, &pbuf);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(store(a, t.io, root, "bitbucket", .{ .url = "https://example.org/old", .body = "o", .now = 1 }));
    try t.expect(store(a, t.io, root, "jira", .{ .url = "https://example.org/new", .body = "n", .now = 1 }));
    try t.expect(markChanged(a, t.io, root, "bitbucket", "acme/widget#1", 1));
    // Age the old entry and the stamp by their modification time.
    const now = Io.Timestamp.now(t.io, .real).toSeconds();
    const old_ts: Io.Timestamp = .fromNanoseconds(@as(i96, now - 8 * 86400) * std.time.ns_per_s);
    for ([_][]const u8{ try entryPath(a, root, "bitbucket", "https://example.org/old"), try changedPath(a, root, "bitbucket", "acme/widget#1") }) |p| {
        const f = try Io.Dir.cwd().openFile(t.io, p, .{ .mode = .read_write });
        defer f.close(t.io);
        try f.setTimestamps(t.io, .{ .modify_timestamp = .{ .new = old_ts } });
    }
    try t.expectEqual(@as(usize, 2), gc(a, t.io, root, max_age_secs, now));
    try t.expect(load(a, t.io, root, "bitbucket", "https://example.org/old") == null);
    try t.expectEqualStrings("n", load(a, t.io, root, "jira", "https://example.org/new").?.body);
    try t.expectEqual(@as(f64, 0), changedAt(a, t.io, root, "bitbucket", "acme/widget#1"));
    // The store above already wrote `.gc-at`: a sweep within the day is
    // skipped, one a day later runs.
    try t.expectEqual(@as(usize, 0), maybeGc(a, t.io, root, now));
    try t.expectEqual(@as(usize, 0), maybeGc(a, t.io, root, now + gc_every_secs + 5));
}

test "enabled: MNML_HTTP_CACHE turns it off; MNML_RECENT_ITEMS does not" {
    var env = Map.init(t.allocator);
    defer env.deinit();
    try t.expect(enabled(&env));
    try env.put("MNML_RECENT_ITEMS", "0");
    try t.expect(enabled(&env));
    try env.put(disable_env, "0");
    try t.expect(!enabled(&env));
    try env.put(disable_env, "Off");
    try t.expect(!enabled(&env));
    try env.put(disable_env, "1");
    try t.expect(enabled(&env));
    try env.put("HOME", "/nonexistent-home");
    try env.put("MNML_DATA_ROOT", "/data");
    const d1 = (try Dir.fromEnv(t.allocator, &env, "jira")).?;
    defer d1.deinit(t.allocator);
    const want1 = try std.fs.path.join(t.allocator, &.{ "/data", dir_name });
    defer t.allocator.free(want1);
    try t.expectEqualStrings(want1, d1.root);
    try env.put("MNML_SHARED_STATE_DIR", "/shared");
    const d2 = (try Dir.fromEnv(t.allocator, &env, "jira")).?;
    defer d2.deinit(t.allocator);
    const want2 = try std.fs.path.join(t.allocator, &.{ "/shared", dir_name });
    defer t.allocator.free(want2);
    try t.expectEqualStrings(want2, d2.root);
    try env.put(disable_env, "no");
    try t.expect((try Dir.fromEnv(t.allocator, &env, "jira")) == null);
}
