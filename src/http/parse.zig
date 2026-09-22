//! Request text → `Request`. Three shapes come in: a pasted `curl …`
//! command (what every browser's "Copy as cURL" emits), the `.http` /
//! `.rest` request-file format, and multi-block files of either where
//! `### name` lines separate requests. Out again: `toCurl` and
//! `toHttpBlock`, and `splice` — which rewrites one named block of a
//! multi-block file and leaves every other byte alone.
//!
//! Every string a `Request` holds is owned by the allocator it was
//! parsed on; `deinit` frees them. Parse on an arena for a throwaway,
//! on the gpa for a pane that will edit it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const script_mod = @import("script.zig");
const multipart = @import("multipart.zig");

pub const ParseError = error{ NoUrl, UnterminatedQuote, Empty } || Allocator.Error;

pub const Header = struct {
    name: []u8,
    value: []u8,
};

pub const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

pub fn isMethod(word: []const u8) bool {
    for (methods) |m| if (std.ascii.eqlIgnoreCase(word, m)) return true;
    return false;
}

/// The verb after `m` in the cycle order the palette advertises.
pub fn nextMethod(m: []const u8) []const u8 {
    for (methods, 0..) |cand, i| if (std.ascii.eqlIgnoreCase(m, cand)) return methods[(i + 1) % methods.len];
    return methods[0];
}

pub const Request = struct {
    method: []u8,
    url: []u8,
    headers: std.ArrayListUnmanaged(Header) = .empty,
    body: ?[]u8 = null,
    /// `-k` / `--insecure`: the caller may skip certificate checks.
    insecure: bool = false,
    /// The block's `# @…` directive lines (`src/http/script.zig`),
    /// newline-joined, kept verbatim so a write-back preserves them.
    script: ?[]u8 = null,

    pub fn init(gpa: Allocator) Allocator.Error!Request {
        return .{ .method = try gpa.dupe(u8, "GET"), .url = try gpa.dupe(u8, "") };
    }

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.method);
        gpa.free(self.url);
        for (self.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        self.headers.deinit(gpa);
        if (self.body) |b| gpa.free(b);
        if (self.script) |sc| gpa.free(sc);
        self.* = undefined;
    }

    pub fn clone(self: *const Request, gpa: Allocator) Allocator.Error!Request {
        var out: Request = .{ .method = try gpa.dupe(u8, self.method), .url = undefined, .insecure = self.insecure };
        errdefer gpa.free(out.method);
        out.url = try gpa.dupe(u8, self.url);
        errdefer gpa.free(out.url);
        errdefer out.deinitHeaders(gpa);
        for (self.headers.items) |h| try out.addHeader(gpa, h.name, h.value);
        if (self.body) |b| out.body = try gpa.dupe(u8, b);
        errdefer if (out.body) |b| gpa.free(b);
        if (self.script) |sc| out.script = try gpa.dupe(u8, sc);
        return out;
    }

    /// Replace the directive lines; null clears them.
    pub fn setScript(self: *Request, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
        const copy: ?[]u8 = if (text) |t| try gpa.dupe(u8, t) else null;
        if (self.script) |old| gpa.free(old);
        self.script = copy;
    }

    fn deinitHeaders(self: *Request, gpa: Allocator) void {
        for (self.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        self.headers.deinit(gpa);
    }

    pub fn setMethod(self: *Request, gpa: Allocator, m: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, m);
        for (copy) |*c| c.* = std.ascii.toUpper(c.*);
        gpa.free(self.method);
        self.method = copy;
    }

    pub fn setUrl(self: *Request, gpa: Allocator, url: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, url);
        gpa.free(self.url);
        self.url = copy;
    }

    /// `null` clears the body.
    pub fn setBody(self: *Request, gpa: Allocator, body: ?[]const u8) Allocator.Error!void {
        const copy: ?[]u8 = if (body) |b| try gpa.dupe(u8, b) else null;
        if (self.body) |old| gpa.free(old);
        self.body = copy;
    }

    pub fn addHeader(self: *Request, gpa: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        try self.headers.append(gpa, .{ .name = n, .value = v });
    }

    /// Case-insensitive lookup, first match.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn headerIndex(self: *const Request, name: []const u8) ?usize {
        for (self.headers.items, 0..) |h, i| if (std.ascii.eqlIgnoreCase(h.name, name)) return i;
        return null;
    }

    /// Replace the first header of that name in place, else append.
    pub fn setHeader(self: *Request, gpa: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
        if (self.headerIndex(name)) |i| {
            const v = try gpa.dupe(u8, value);
            gpa.free(self.headers.items[i].value);
            self.headers.items[i].value = v;
            return;
        }
        try self.addHeader(gpa, name, value);
    }

    /// Remove every header of that name. Returns how many went.
    pub fn removeHeader(self: *Request, gpa: Allocator, name: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(self.headers.items[i].name, name)) {
                const h = self.headers.orderedRemove(i);
                gpa.free(h.name);
                gpa.free(h.value);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    pub fn clearHeaders(self: *Request, gpa: Allocator) void {
        self.deinitHeaders(gpa);
        self.headers = .empty;
    }

    /// True when nothing has been typed into it: `GET`, no URL, no
    /// headers, no body.
    pub fn isBlank(self: *const Request) bool {
        return std.mem.trim(u8, self.url, " \t").len == 0 and std.ascii.eqlIgnoreCase(self.method, "GET") and
            self.headers.items.len == 0 and (self.body == null or std.mem.trim(u8, self.body.?, " \t\r\n").len == 0);
    }

    /// Everything after `?` up to `#`, or empty.
    pub fn query(self: *const Request) []const u8 {
        const q = std.mem.indexOfScalar(u8, self.url, '?') orelse return "";
        const rest = self.url[q + 1 ..];
        const hash = std.mem.indexOfScalar(u8, rest, '#') orelse rest.len;
        return rest[0..hash];
    }

    /// The URL without its query string (the fragment is kept).
    pub fn urlWithoutQuery(self: *const Request, alloc: Allocator) Allocator.Error![]u8 {
        const q = std.mem.indexOfScalar(u8, self.url, '?') orelse return alloc.dupe(u8, self.url);
        const rest = self.url[q + 1 ..];
        const hash = std.mem.indexOfScalar(u8, rest, '#');
        if (hash) |h| return std.mem.concat(alloc, u8, &.{ self.url[0..q], rest[h..] });
        return alloc.dupe(u8, self.url[0..q]);
    }

    /// Append `key=value` to the query string.
    pub fn addParam(self: *Request, gpa: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        const has_q = std.mem.indexOfScalar(u8, self.url, '?') != null;
        const q = self.query();
        const sep: []const u8 = if (!has_q) "?" else if (q.len == 0) "" else "&";
        // Insert before the fragment.
        const hash = std.mem.indexOfScalar(u8, self.url, '#') orelse self.url.len;
        const out = try std.mem.concat(gpa, u8, &.{ self.url[0..hash], sep, key, "=", value, self.url[hash..] });
        gpa.free(self.url);
        self.url = out;
    }

    /// `-G -d a=1`: the data goes on the query string as written.
    pub fn addParamRaw(self: *Request, gpa: Allocator, raw: []const u8) Allocator.Error!void {
        const has_q = std.mem.indexOfScalar(u8, self.url, '?') != null;
        const sep: []const u8 = if (!has_q) "?" else if (self.query().len == 0) "" else "&";
        const out = try std.mem.concat(gpa, u8, &.{ self.url, sep, raw });
        gpa.free(self.url);
        self.url = out;
    }

    pub const Param = struct { key: []const u8, value: []const u8 };

    /// The query string split into pairs; slices borrow from `url`.
    pub fn params(self: *const Request, alloc: Allocator) Allocator.Error![]Param {
        var out: std.ArrayListUnmanaged(Param) = .empty;
        var it = std.mem.splitScalar(u8, self.query(), '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            try out.append(alloc, .{ .key = if (eq) |e| pair[0..e] else pair, .value = if (eq) |e| pair[e + 1 ..] else "" });
        }
        return out.toOwnedSlice(alloc);
    }
};

// ─── auto-detect ────────────────────────────────────────────────────────

/// Parse a request from text: the `.http` format when the first real
/// line starts with a method, else curl, falling back to `.http`.
pub fn parse(alloc: Allocator, input: []const u8) ParseError!Request {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    var req = if (looksLikeHttpFile(trimmed)) try parseHttp(alloc, trimmed) else parseCurl(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => parseHttp(alloc, trimmed) catch return err,
    };
    errdefer req.deinit(alloc);
    // The `# @…` lines ride along whichever shape the block took. The
    // option lines `parseCurl` made of its flags (`-k` → `@insecure`…)
    // stay unless the text spells that word itself.
    {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        if (script_mod.hasDirectives(trimmed)) for (try script_mod.directiveLines(sa, trimmed)) |l| try lines.append(sa, l);
        if (req.script) |sc| {
            var it = std.mem.splitScalar(u8, sc, '\n');
            while (it.next()) |l| {
                const w = directiveWord(l) orelse continue;
                if (!hasWord(lines.items, w)) try lines.append(sa, try sa.dupe(u8, l));
            }
        }
        try req.setScript(alloc, if (lines.items.len > 0) try std.mem.join(sa, "\n", lines.items) else null);
    }
    if (hasDirective(&req, "@insecure")) req.insecure = true;
    return req;
}

// ─── per-request options ────────────────────────────────────────────────

/// The transport options a block carries as `# @…` directive lines —
/// `@insecure`, `@timeout 5s` (`500ms`, `2m`, a bare number is ms),
/// `@no-redirect` / `@follow-redirects`, `@max-redirects 3`, `@proxy
/// host:port` — which `parseCurl` also makes of `-k`, `--max-time`,
/// `--max-redirs`, `-L` and `-x`, so one store round-trips through
/// `toHttpBlock` and `toCurl`. Unset means the config's default.
pub const Options = struct {
    insecure: bool = false,
    timeout_ms: ?u64 = null,
    follow_redirects: ?bool = null,
    max_redirects: ?u8 = null,
    /// Borrowed from `script`.
    proxy: ?[]const u8 = null,
};

pub const option_words = [_][]const u8{ "@insecure", "@timeout", "@no-redirect", "@follow-redirects", "@max-redirects", "@proxy" };

pub fn isOptionWord(word: []const u8) bool {
    for (option_words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// The directive text of a `# @…` / `// @…` line (`@word rest`), else null.
pub fn directiveText(raw: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, t, "//")) t = t[2..] else if (t.len > 0 and t[0] == '#') t = t[1..] else return null;
    t = std.mem.trim(u8, t, " \t");
    if (t.len < 2 or t[0] != '@') return null;
    return t;
}

/// The `@word` of a directive line.
pub fn directiveWord(raw: []const u8) ?[]const u8 {
    const d = directiveText(raw) orelse return null;
    const sp = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
    return d[0..sp];
}

fn hasWord(lines: []const []const u8, word: []const u8) bool {
    for (lines) |l| if (directiveWord(l)) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

pub fn hasDirective(req: *const Request, word: []const u8) bool {
    const sc = req.script orelse return false;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |l| if (directiveWord(l)) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// The options the block's directives (and `insecure`) spell.
pub fn options(req: *const Request) Options {
    var out: Options = .{ .insecure = req.insecure };
    const sc = req.script orelse return out;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        const sp = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
        const word = d[0..sp];
        const rest = std.mem.trim(u8, d[sp..], " \t");
        if (std.mem.eql(u8, word, "@insecure")) {
            out.insecure = true;
        } else if (std.mem.eql(u8, word, "@timeout")) {
            if (parseDuration(rest)) |ms| out.timeout_ms = ms;
        } else if (std.mem.eql(u8, word, "@no-redirect")) {
            out.follow_redirects = false;
        } else if (std.mem.eql(u8, word, "@follow-redirects")) {
            out.follow_redirects = true;
        } else if (std.mem.eql(u8, word, "@max-redirects")) {
            if (std.fmt.parseInt(u8, rest, 10)) |n| out.max_redirects = n else |_| {}
        } else if (std.mem.eql(u8, word, "@proxy")) {
            if (rest.len > 0) out.proxy = rest;
        }
    }
    return out;
}

/// `5s`, `500ms`, `2m`, `1h`, `2.5s`; a bare number is milliseconds.
pub fn parseDuration(text: []const u8) ?u64 {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return null;
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.')) : (end += 1) {}
    if (end == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..end]) catch return null;
    if (!(num >= 0) or num > 1e12) return null;
    const unit = std.mem.trim(u8, s[end..], " \t");
    const scale: f64 = if (unit.len == 0 or std.mem.eql(u8, unit, "ms")) 1 else if (std.mem.eql(u8, unit, "s")) 1000 else if (std.mem.eql(u8, unit, "m")) 60_000 else if (std.mem.eql(u8, unit, "h")) 3_600_000 else return null;
    return @intFromFloat(@round(num * scale));
}

/// `5000` → `5s`, `2500` → `2.5s`, `300` → `300ms`, `120000` → `2m`.
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    if (ms >= 60_000 and ms % 60_000 == 0) return std.fmt.bufPrint(buf, "{d}m", .{ms / 60_000}) catch buf[0..0];
    if (ms >= 1000 and ms % 1000 == 0) return std.fmt.bufPrint(buf, "{d}s", .{ms / 1000}) catch buf[0..0];
    if (ms >= 1000 and ms % 100 == 0) return std.fmt.bufPrint(buf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch buf[0..0];
}

/// Set (or with `value == null` remove) the `# @word …` line of the
/// script; other lines keep their order. An empty value writes the bare
/// word. Keeps `insecure` in step for `@insecure`.
pub fn setDirective(req: *Request, gpa: Allocator, word: []const u8, value: ?[]const u8) Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var replaced = false;
    if (req.script) |sc| {
        var it = std.mem.splitScalar(u8, sc, '\n');
        while (it.next()) |l| {
            const w = directiveWord(l);
            if (w != null and std.mem.eql(u8, w.?, word)) {
                if (value != null and !replaced) {
                    try lines.append(a, try directiveLine(a, word, value.?));
                    replaced = true;
                }
                continue;
            }
            if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
            try lines.append(a, l);
        }
    }
    if (value != null and !replaced) try lines.append(a, try directiveLine(a, word, value.?));
    try req.setScript(gpa, if (lines.items.len > 0) try std.mem.join(a, "\n", lines.items) else null);
    if (std.mem.eql(u8, word, "@insecure")) req.insecure = value != null;
}

fn directiveLine(a: Allocator, word: []const u8, value: []const u8) Allocator.Error![]const u8 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return std.mem.concat(a, u8, &.{ "# ", word });
    return std.mem.concat(a, u8, &.{ "# ", word, " ", v });
}

// ─── description + tags ─────────────────────────────────────────────────

/// The block's `# @description …` text, if any (item 15).
pub fn description(req: *const Request) ?[]const u8 {
    const sc = req.script orelse return null;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        if (!std.mem.startsWith(u8, d, "@description")) continue;
        const rest = std.mem.trim(u8, d["@description".len..], " \t");
        return if (rest.len > 0) rest else null;
    }
    return null;
}

/// The block's `# @tags a b c` words (also comma-separated), in order.
pub fn tags(arena: Allocator, req: *const Request) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const sc = req.script orelse return out.items;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        if (!std.mem.startsWith(u8, d, "@tags") and !std.mem.startsWith(u8, d, "@tag ")) continue;
        const rest = d[(if (std.mem.startsWith(u8, d, "@tags")) "@tags".len else "@tag".len)..];
        var words = std.mem.tokenizeAny(u8, rest, " \t,");
        while (words.next()) |w| {
            const t = if (w.len > 0 and w[0] == '#') w[1..] else w;
            if (t.len > 0 and !hasString(out.items, t)) try out.append(arena, t);
        }
    }
    return out.items;
}

/// Set (or with null remove) the `# @description` line.
pub fn setDescription(req: *Request, gpa: Allocator, text: ?[]const u8) Allocator.Error!void {
    const t = if (text) |x| std.mem.trim(u8, x, " \t") else "";
    try setDirective(req, gpa, "@description", if (t.len == 0) null else t);
}

/// Set (or with an empty text remove) the `# @tags` line.
pub fn setTags(req: *Request, gpa: Allocator, text: []const u8) Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var words: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |w| {
        const t = if (w.len > 0 and w[0] == '#') w[1..] else w;
        if (t.len > 0) try words.append(scratch.allocator(), t);
    }
    try setDirective(req, gpa, "@tags", if (words.items.len == 0) null else try std.mem.join(scratch.allocator(), " ", words.items));
}

// ─── body type ──────────────────────────────────────────────────────────

/// How the Body tab goes on the wire (item 11): as typed; JSON
/// (formatted on send when `http.auto_format_body`, `Content-Type`
/// added); the rows as `application/x-www-form-urlencoded`; the rows
/// as `multipart/form-data`, a `name = @path` row a file part. Kept in
/// the block as `# @body-type multipart`.
pub const BodyType = enum {
    raw,
    json,
    form,
    multipart,

    pub const all = [_]BodyType{ .raw, .json, .form, .multipart };

    /// The directive's word.
    pub fn word(t: BodyType) []const u8 {
        return switch (t) {
            .raw => "raw",
            .json => "json",
            .form => "form-urlencoded",
            .multipart => "multipart",
        };
    }

    /// The chip's text.
    pub fn label(t: BodyType) []const u8 {
        return switch (t) {
            .raw => "raw",
            .json => "JSON",
            .form => "form",
            .multipart => "multipart",
        };
    }

    pub fn next(t: BodyType) BodyType {
        return all[(@as(usize, @intFromEnum(t)) + 1) % all.len];
    }

    /// `form`, `form-urlencoded`, `urlencoded`, `multipart`,
    /// `multipart/form-data`, `json`, `raw` — else null.
    pub fn fromWord(w: []const u8) ?BodyType {
        const t = std.mem.trim(u8, w, " \t");
        if (std.ascii.eqlIgnoreCase(t, "raw")) return .raw;
        if (std.ascii.eqlIgnoreCase(t, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(t, "form") or std.ascii.eqlIgnoreCase(t, "form-urlencoded") or std.ascii.eqlIgnoreCase(t, "urlencoded")) return .form;
        if (std.ascii.startsWithIgnoreCase(t, "multipart")) return .multipart;
        return null;
    }
};

/// The block's `# @body-type` (raw when it has none).
pub fn bodyType(req: *const Request) BodyType {
    const sc = req.script orelse return .raw;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        if (!std.mem.startsWith(u8, d, "@body-type")) continue;
        return BodyType.fromWord(d["@body-type".len..]) orelse .raw;
    }
    return .raw;
}

/// Set the `# @body-type` line; `raw` removes it.
pub fn setBodyType(req: *Request, gpa: Allocator, t: BodyType) Allocator.Error!void {
    try setDirective(req, gpa, "@body-type", if (t == .raw) null else t.word());
}

// ─── path params ────────────────────────────────────────────────────────

/// A `:name` segment of the URL's path with the value the block's
/// `# @path name=value` line gives it (empty when none does).
pub const PathParam = struct { name: []const u8, value: []const u8 };

/// The path of `url`: from the first `/` after the scheme's host (or
/// the first `/` at all) up to the query or the fragment.
pub fn pathPart(url: []const u8) []const u8 {
    var start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |s| start = s + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, start, '/') orelse return "";
    const rest = url[slash..];
    const end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    return rest[0..end];
}

/// The `:name` segments of the path — `/users/:id/posts/:post_id` — in
/// order, each once. A `:` right after a `/` starts one; `::` is a
/// literal colon and starts none; the host's `:8080` follows no `/`.
/// The names borrow `url`.
pub fn pathParamNames(arena: Allocator, url: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const path = pathPart(url);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != ':') continue;
        if (i + 1 < path.len and path[i + 1] == ':') {
            i += 1;
            continue;
        }
        if (i == 0 or path[i - 1] != '/') continue;
        const start = i + 1;
        var end = start;
        while (end < path.len and (std.ascii.isAlphanumeric(path[end]) or path[end] == '_')) : (end += 1) {}
        if (end == start) continue;
        const name = path[start..end];
        if (!hasString(out.items, name)) try out.append(arena, name);
        i = end - 1;
    }
    return out.items;
}

fn hasString(list: []const []const u8, s: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, s)) return true;
    return false;
}

/// `url` with every `:name` of its path replaced by its value in
/// `values` (a name with none stays as written) and every `::` made
/// `:`. The query and the fragment pass through untouched. Owned.
pub fn substitutePath(alloc: Allocator, url: []const u8, values: []const PathParam) Allocator.Error![]u8 {
    const path = pathPart(url);
    if (path.len == 0) return alloc.dupe(u8, url);
    const path_off = @intFromPtr(path.ptr) - @intFromPtr(url.ptr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, url[0..path_off]);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (c == ':') {
            if (i + 1 < path.len and path[i + 1] == ':') {
                try out.append(alloc, ':');
                i += 1;
                continue;
            }
            if (i > 0 and path[i - 1] == '/') {
                var end = i + 1;
                while (end < path.len and (std.ascii.isAlphanumeric(path[end]) or path[end] == '_')) : (end += 1) {}
                if (end > i + 1) {
                    const name = path[i + 1 .. end];
                    var found: ?[]const u8 = null;
                    for (values) |v| if (std.mem.eql(u8, v.name, name) and v.value.len > 0) {
                        found = v.value;
                        break;
                    };
                    try out.appendSlice(alloc, found orelse path[i..end]);
                    i = end - 1;
                    continue;
                }
            }
        }
        try out.append(alloc, c);
    }
    try out.appendSlice(alloc, url[path_off + path.len ..]);
    return out.toOwnedSlice(alloc);
}

/// The block's `# @path name=value` lines, in order. Borrow `script`.
pub fn pathParams(arena: Allocator, req: *const Request) Allocator.Error![]PathParam {
    var out: std.ArrayListUnmanaged(PathParam) = .empty;
    const sc = req.script orelse return out.items;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        if (!std.mem.startsWith(u8, d, "@path")) continue;
        const rest = std.mem.trim(u8, d["@path".len..], " \t");
        if (rest.len == d.len - "@path".len and rest.len > 0) continue; // `@pathological`
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const name = std.mem.trim(u8, rest[0..eq], " \t");
        if (name.len == 0) continue;
        try out.append(arena, .{ .name = name, .value = std.mem.trim(u8, rest[eq + 1 ..], " \t") });
    }
    return out.items;
}

/// The value of `:name` (from `@path`), if the block sets one.
pub fn pathParamValue(req: *const Request, name: []const u8) ?[]const u8 {
    const sc = req.script orelse return null;
    var it = std.mem.splitScalar(u8, sc, '\n');
    while (it.next()) |raw| {
        const d = directiveText(raw) orelse continue;
        if (!std.mem.startsWith(u8, d, "@path ")) continue;
        const rest = std.mem.trim(u8, d["@path ".len..], " \t");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, rest[0..eq], " \t"), name)) return std.mem.trim(u8, rest[eq + 1 ..], " \t");
    }
    return null;
}

/// Set (or with null remove) the `# @path name=value` line; the other
/// names' lines stay where they are.
pub fn setPathParam(req: *Request, gpa: Allocator, name: []const u8, value: ?[]const u8) Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var replaced = false;
    const fresh: ?[]const u8 = if (value) |v| try std.fmt.allocPrint(a, "# @path {s}={s}", .{ name, std.mem.trim(u8, v, " \t") }) else null;
    if (req.script) |sc| {
        var it = std.mem.splitScalar(u8, sc, '\n');
        while (it.next()) |l| {
            if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
            const mine = blk: {
                const d = directiveText(l) orelse break :blk false;
                if (!std.mem.startsWith(u8, d, "@path ")) break :blk false;
                const rest = std.mem.trim(u8, d["@path ".len..], " \t");
                const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break :blk false;
                break :blk std.mem.eql(u8, std.mem.trim(u8, rest[0..eq], " \t"), name);
            };
            if (mine) {
                if (fresh != null and !replaced) {
                    try lines.append(a, fresh.?);
                    replaced = true;
                }
                continue;
            }
            try lines.append(a, l);
        }
    }
    if (fresh != null and !replaced) try lines.append(a, fresh.?);
    try req.setScript(gpa, if (lines.items.len > 0) try std.mem.join(a, "\n", lines.items) else null);
}

pub fn looksLikeHttpFile(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "//")) continue;
        const sp = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
        return isMethod(t[0..sp]);
    }
    return false;
}

/// `.http` / `.rest` / `.curl` by extension.
pub fn isRequestPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".http") or std.ascii.eqlIgnoreCase(ext, ".rest") or std.ascii.eqlIgnoreCase(ext, ".curl");
}

// ─── curl ───────────────────────────────────────────────────────────────

/// A pasted curl command. The leading `curl` is optional; a response a
/// tool appended after the command is dropped; `\`-newlines join.
pub fn parseCurl(alloc: Allocator, input: []const u8) ParseError!Request {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const isolated = try isolateCurl(a, trimmed);
    const joined = try stripContinuations(a, isolated);
    const tokens = try tokenize(a, joined);
    if (tokens.len == 0) return error.Empty;
    var i: usize = if (std.ascii.eqlIgnoreCase(tokens[0], "curl")) 1 else 0;

    var req = try Request.init(alloc);
    errdefer req.deinit(alloc);
    var method: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var cookies: std.ArrayListUnmanaged([]const u8) = .empty;
    var form: std.ArrayListUnmanaged([2][]const u8) = .empty;
    var urlenc: std.ArrayListUnmanaged([]const u8) = .empty;
    var get_flag = false;
    var timeout_ms: ?u64 = null;
    var follow: ?bool = null;
    var max_redirs: ?u8 = null;
    var proxy: ?[]const u8 = null;

    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        const next: ?[]const u8 = if (i + 1 < tokens.len) tokens[i + 1] else null;
        if (eqAny(t, &.{ "-X", "--request" })) {
            if (next) |v| {
                method = v;
                i += 1;
            }
        } else if (eqAny(t, &.{ "-H", "--header" })) {
            if (next) |v| {
                if (splitHeader(v)) |kv| try req.addHeader(alloc, kv[0], kv[1]);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-d", "--data", "--data-raw", "--data-binary", "--data-ascii" })) {
            if (next) |v| {
                body = v;
                i += 1;
            }
        } else if (std.mem.eql(u8, t, "--data-urlencode")) {
            if (next) |v| {
                try urlenc.append(a, v);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-b", "--cookie" })) {
            if (next) |v| {
                try cookies.append(a, v);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-A", "--user-agent" })) {
            if (next) |v| {
                try req.addHeader(alloc, "user-agent", v);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-e", "--referer" })) {
            if (next) |v| {
                try req.addHeader(alloc, "referer", v);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-u", "--user" })) {
            if (next) |v| {
                const enc = std.base64.standard.Encoder;
                const buf = try a.alloc(u8, enc.calcSize(v.len));
                const encoded = enc.encode(buf, v);
                const value = try std.mem.concat(a, u8, &.{ "Basic ", encoded });
                try req.addHeader(alloc, "authorization", value);
                i += 1;
            }
        } else if (eqAny(t, &.{ "-F", "--form", "--form-string" })) {
            if (next) |v| {
                if (std.mem.indexOfScalar(u8, v, '=')) |eq| try form.append(a, .{ v[0..eq], v[eq + 1 ..] });
                i += 1;
            }
        } else if (std.mem.eql(u8, t, "--url")) {
            if (next) |v| {
                if (url == null) url = v;
                i += 1;
            }
        } else if (eqAny(t, &.{ "-k", "--insecure" })) {
            req.insecure = true;
        } else if (eqAny(t, &.{ "-G", "--get" })) {
            get_flag = true;
        } else if (eqAny(t, &.{ "-L", "--location" })) {
            follow = true;
        } else if (eqAny(t, &.{ "-m", "--max-time" })) {
            if (next) |v| {
                // curl's seconds, fractions allowed.
                if (std.fmt.parseFloat(f64, v)) |secs| {
                    if (secs >= 0 and secs < 1e9) timeout_ms = @intFromFloat(@round(secs * 1000));
                } else |_| {}
                i += 1;
            }
        } else if (std.mem.eql(u8, t, "--max-redirs")) {
            if (next) |v| {
                if (std.fmt.parseInt(i32, v, 10)) |n| {
                    if (n <= 0) follow = false else max_redirs = @intCast(@min(n, 255));
                } else |_| {}
                i += 1;
            }
        } else if (eqAny(t, &.{ "-x", "--proxy" })) {
            if (next) |v| {
                proxy = v;
                i += 1;
            }
        } else if (eqAny(t, &.{ "--compressed", "--silent", "-s", "--fail", "-f", "-i", "--include", "-#", "--progress-bar", "-v", "--verbose", "-S", "--show-error" })) {
            // no-ops for the request itself
        } else if (eqAny(t, &.{ "-o", "--output", "--connect-timeout", "-w", "--write-out", "--retry", "--cacert", "--cert", "--key", "-c", "--cookie-jar", "--resolve" })) {
            // flags with a value that do not shape the request
            if (next != null) i += 1;
        } else if (t.len > 1 and t[0] == '-') {
            // an unknown flag: keep going
        } else if (url == null) {
            url = t;
        }
    }
    const u = url orelse return error.NoUrl;
    try req.setUrl(alloc, u);
    // The transport flags become the block's directive lines.
    if (req.insecure) try setDirective(&req, alloc, "@insecure", "");
    if (timeout_ms) |ms| {
        var dbuf: [32]u8 = undefined;
        try setDirective(&req, alloc, "@timeout", formatDuration(&dbuf, ms));
    }
    if (follow) |f| try setDirective(&req, alloc, if (f) "@follow-redirects" else "@no-redirect", "");
    if (max_redirs) |n| {
        var nbuf: [8]u8 = undefined;
        try setDirective(&req, alloc, "@max-redirects", std.fmt.bufPrint(&nbuf, "{d}", .{n}) catch "");
    }
    if (proxy) |p| try setDirective(&req, alloc, "@proxy", p);
    if (cookies.items.len > 0) {
        const joined_cookies = try std.mem.join(a, "; ", cookies.items);
        try req.addHeader(alloc, "cookie", joined_cookies);
    }
    // `-F` / `--data-urlencode`: the rows land on the Body tab as
    // `name = value` lines (a `@file` kept as one) and the block says
    // `# @body-type`; the bytes are made at send time.
    if (form.items.len > 0 and body == null) {
        var rows: std.ArrayListUnmanaged(multipart.Row) = .empty;
        for (form.items) |part| try rows.append(a, if (part[1].len > 1 and part[1][0] == '@') .{ .name = part[0], .value = part[1][1..], .file = part[1][1..] } else .{ .name = part[0], .value = part[1] });
        body = try multipart.renderRows(a, rows.items);
        try setDirective(&req, alloc, "@body-type", BodyType.multipart.word());
    } else if (urlenc.items.len > 0 and body == null and !get_flag) {
        var rows: std.ArrayListUnmanaged(multipart.Row) = .empty;
        for (urlenc.items) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            try rows.append(a, .{ .name = kv[0..eq], .value = kv[eq + 1 ..] });
        }
        body = try multipart.renderRows(a, rows.items);
        try setDirective(&req, alloc, "@body-type", BodyType.form.word());
    } else if (urlenc.items.len > 0 and get_flag) {
        for (urlenc.items) |kv| try req.addParamRaw(alloc, kv);
    }
    if (body) |b| {
        if (get_flag) {
            try req.addParamRaw(alloc, b);
        } else {
            try req.setBody(alloc, b);
        }
    }
    const m = method orelse (if (req.body != null) "POST" else "GET");
    try req.setMethod(alloc, m);
    dedupeHeaders(&req, alloc);
    return req;
}

fn eqAny(t: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, t, l)) return true;
    return false;
}

fn splitHeader(s: []const u8) ?[2][]const u8 {
    const idx = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const k = std.mem.trim(u8, s[0..idx], " \t");
    if (k.len == 0) return null;
    return .{ k, std.mem.trim(u8, s[idx + 1 ..], " \t") };
}

/// curl's rule: the last `-H` for a name wins, at the first position.
fn dedupeHeaders(req: *Request, gpa: Allocator) void {
    var i: usize = 0;
    while (i < req.headers.items.len) : (i += 1) {
        var j = i + 1;
        while (j < req.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(req.headers.items[i].name, req.headers.items[j].name)) {
                const later = req.headers.orderedRemove(j);
                gpa.free(req.headers.items[i].name);
                gpa.free(req.headers.items[i].value);
                req.headers.items[i] = later;
            } else j += 1;
        }
    }
}

/// Keep the command: from the first line starting with `curl`, through
/// quotes and `\` continuations, up to the first line that ends it.
fn isolateCurl(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try lines.append(a, l);
    var start: usize = 0;
    for (lines.items, 0..) |l, i| if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), "curl")) {
        start = i;
        break;
    };
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var open: ?u8 = null;
    for (lines.items[start..]) |line| {
        const trimmed_end = std.mem.trimEnd(u8, line, " \t\r");
        const continues = trimmed_end.len > 0 and trimmed_end[trimmed_end.len - 1] == '\\';
        const visible = if (continues) trimmed_end[0 .. trimmed_end.len - 1] else trimmed_end;
        const was_in_quote = open != null;
        open = scanQuoteState(visible, open);
        try out.append(a, line);
        if (!continues and open == null and (was_in_quote or std.mem.trim(u8, visible, " \t").len > 0)) break;
    }
    return std.mem.join(a, "\n", out.items);
}

fn scanQuoteState(line: []const u8, open_in: ?u8) ?u8 {
    var open = open_in;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (open == null) {
            if (c == '\'' or c == '"') open = c;
        } else if (open.? == '\'') {
            if (c == '\'') open = null;
        } else {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') open = null;
        }
    }
    return open;
}

fn stripContinuations(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '\n' or s[i + 1] == '\r')) {
            out.appendAssumeCapacity(' ');
            i += 2;
            if (i < s.len and s[i] == '\n') i += 1;
            continue;
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.items;
}

/// Bash-style word splitting: `'…'` literal, `"…"` with `\"` `\\` `\$`
/// `` \` `` escapes, `$'…'` C strings, `\x` outside quotes, adjacent
/// segments concatenated.
pub fn tokenize(a: Allocator, s: []const u8) ParseError![]const []const u8 {
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    var in_token = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        i += 1;
        switch (c) {
            ' ', '\t', '\n', '\r' => if (in_token) {
                try tokens.append(a, try cur.toOwnedSlice(a));
                in_token = false;
            },
            '\'' => {
                in_token = true;
                while (true) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    const ch = s[i];
                    i += 1;
                    if (ch == '\'') break;
                    try cur.append(a, ch);
                }
            },
            '"' => {
                in_token = true;
                while (true) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    const ch = s[i];
                    i += 1;
                    if (ch == '"') break;
                    if (ch == '\\' and i < s.len) {
                        const n = s[i];
                        if (n == '"' or n == '\\' or n == '$' or n == '`' or n == '\n') {
                            try cur.append(a, n);
                            i += 1;
                        } else try cur.append(a, '\\');
                        continue;
                    }
                    try cur.append(a, ch);
                }
            },
            '\\' => {
                in_token = true;
                if (i < s.len) {
                    try cur.append(a, s[i]);
                    i += 1;
                }
            },
            '$' => {
                in_token = true;
                if (i < s.len and s[i] == '\'') {
                    i += 1;
                    while (true) {
                        if (i >= s.len) return error.UnterminatedQuote;
                        const ch = s[i];
                        i += 1;
                        if (ch == '\'') break;
                        if (ch != '\\') {
                            try cur.append(a, ch);
                            continue;
                        }
                        if (i >= s.len) return error.UnterminatedQuote;
                        const e = s[i];
                        i += 1;
                        switch (e) {
                            'n' => try cur.append(a, '\n'),
                            't' => try cur.append(a, '\t'),
                            'r' => try cur.append(a, '\r'),
                            '\\' => try cur.append(a, '\\'),
                            '\'' => try cur.append(a, '\''),
                            '"' => try cur.append(a, '"'),
                            '0' => try cur.append(a, 0),
                            'a' => try cur.append(a, 0x07),
                            'b' => try cur.append(a, 0x08),
                            'f' => try cur.append(a, 0x0c),
                            'v' => try cur.append(a, 0x0b),
                            'e', 'E' => try cur.append(a, 0x1b),
                            'u', 'x' => {
                                const max: usize = if (e == 'u') 4 else 2;
                                var n: usize = 0;
                                var cp: u21 = 0;
                                while (n < max and i < s.len and std.ascii.isHex(s[i])) : (n += 1) {
                                    cp = cp * 16 + @as(u21, std.fmt.charToDigit(s[i], 16) catch 0);
                                    i += 1;
                                }
                                var buf: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(cp, &buf) catch 0;
                                try cur.appendSlice(a, buf[0..len]);
                            },
                            else => {
                                try cur.append(a, '\\');
                                try cur.append(a, e);
                            },
                        }
                    }
                } else try cur.append(a, '$');
            },
            else => {
                in_token = true;
                try cur.append(a, c);
            },
        }
    }
    if (in_token) try tokens.append(a, try cur.toOwnedSlice(a));
    return tokens.items;
}

// ─── .http / .rest ──────────────────────────────────────────────────────

/// One request block: comments, `[METHOD] url [HTTP/x]`, headers, a
/// blank line, the body. `# @directive` / `// @directive` lines are
/// directives wherever they sit — before the request line, among the
/// headers, or after the body — and never body bytes (`parse` gathers
/// them into `script`). A plain `#` / `//` line after the body boundary
/// is body, as in Rust mnml: a text body may carry one on purpose.
pub fn parseHttp(alloc: Allocator, input: []const u8) ParseError!Request {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) return error.Empty;
    var req = try Request.init(alloc);
    errdefer req.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_request_line = false;
    var in_headers = false;
    var body_start: ?usize = null;
    var offset: usize = 0;
    while (lines.next()) |raw| {
        const line_off = offset;
        offset += raw.len + 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trim(u8, line, " \t");
        if (body_start != null) {
            // Past the boundary: the bytes are the body's, except the
            // directive lines; those are cut out below.
            continue;
        }
        if (!seen_request_line) {
            if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "###")) continue;
            var parts = std.mem.tokenizeAny(u8, t, " \t");
            const first = parts.next() orelse continue;
            if (isMethod(first)) {
                try req.setMethod(alloc, first);
                const rest = parts.next() orelse return error.NoUrl;
                try req.setUrl(alloc, rest);
            } else {
                try req.setUrl(alloc, first);
            }
            seen_request_line = true;
            in_headers = true;
            continue;
        }
        if (in_headers) {
            if (t.len == 0) {
                in_headers = false;
                body_start = offset;
                continue;
            }
            if (t[0] == '#' or std.mem.startsWith(u8, t, "//")) continue;
            if (splitHeader(t)) |kv| {
                try req.addHeader(alloc, kv[0], kv[1]);
                continue;
            }
            // Not a header: the body starts here (lenient).
            in_headers = false;
            body_start = line_off;
        }
    }
    if (!seen_request_line) return error.NoUrl;
    if (body_start) |bs| if (bs < text.len) {
        const body = try bodyWithoutDirectives(alloc, text[bs..]);
        defer alloc.free(body);
        const trimmed = std.mem.trimEnd(u8, body, " \t\r\n");
        if (trimmed.len > 0) try req.setBody(alloc, trimmed);
    };
    return req;
}

/// The body region with its `# @…` / `// @…` lines removed and every
/// other byte kept (a CR stays with its line). Owned by the caller.
fn bodyWithoutDirectives(alloc: Allocator, region: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, region, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (script_mod.isDirectiveLine(raw)) continue;
        if (!first) try out.append(alloc, '\n');
        first = false;
        try out.appendSlice(alloc, raw);
    }
    return out.toOwnedSlice(alloc);
}

// ─── multi-block files ──────────────────────────────────────────────────

pub const Block = struct {
    /// Text after `###`, trimmed; null for the leading block that has
    /// no separator; empty for a bare `###`.
    name: ?[]const u8,
    /// 0-based inclusive line range in the source, separator included.
    start_line: usize,
    end_line: usize,
    /// The request text without the separator line (borrowed from the
    /// input).
    text: []const u8,
    /// The first `# …` comment's text, for a tab label.
    summary: ?[]const u8,
    /// Its position in `blocks`' result — the block's identity. Two
    /// bare `###` blocks share the name `""`, and two `### get` blocks
    /// share `get`, so a name alone cannot say which one a pane is on.
    index: u32 = 0,

    /// Whether this block came after a `###` line.
    pub fn hasSeparator(b: Block) bool {
        return b.name != null;
    }
};

/// Every non-empty block of a `.http` / `.curl` file, in order.
pub fn blocks(arena: Allocator, input: []const u8) Allocator.Error![]Block {
    var out: std.ArrayListUnmanaged(Block) = .empty;
    var starts: std.ArrayListUnmanaged(usize) = .empty; // byte offset of each line
    var i: usize = 0;
    try starts.append(arena, 0);
    while (i < input.len) : (i += 1) if (input[i] == '\n') try starts.append(arena, i + 1);
    const line_count = starts.items.len;
    const lineAt = struct {
        fn f(src: []const u8, st: []const usize, n: usize) []const u8 {
            const s = st[n];
            const e = if (n + 1 < st.len) st[n + 1] - 1 else src.len;
            return std.mem.trimEnd(u8, src[s..@max(s, e)], "\r");
        }
    }.f;
    var seps: std.ArrayListUnmanaged(usize) = .empty;
    for (0..line_count) |n| if (std.mem.startsWith(u8, std.mem.trimStart(u8, lineAt(input, starts.items, n), " \t"), "###")) try seps.append(arena, n);
    const Range = struct { start: usize, end: usize, name: ?[]const u8 };
    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    if (seps.items.len == 0) {
        try ranges.append(arena, .{ .start = 0, .end = line_count -| 1, .name = null });
    } else {
        if (seps.items[0] > 0) try ranges.append(arena, .{ .start = 0, .end = seps.items[0] - 1, .name = null });
        for (seps.items, 0..) |sep, idx| {
            const end = if (idx + 1 < seps.items.len) seps.items[idx + 1] - 1 else line_count -| 1;
            const sep_line = std.mem.trimStart(u8, lineAt(input, starts.items, sep), " \t");
            try ranges.append(arena, .{ .start = sep, .end = end, .name = std.mem.trim(u8, sep_line[3..], " \t") });
        }
    }
    for (ranges.items) |r| {
        const body_first = if (r.name != null) r.start + 1 else r.start;
        if (body_first > r.end and r.name != null) continue;
        const from = starts.items[@min(body_first, line_count - 1)];
        const to = if (r.end + 1 < line_count) starts.items[r.end + 1] -| 1 else input.len;
        const text = if (body_first > r.end) "" else input[from..@max(from, to)];
        if (!hasRealContent(text)) continue;
        try out.append(arena, .{ .name = r.name, .start_line = r.start, .end_line = r.end, .text = text, .summary = firstComment(text), .index = @intCast(out.items.len) });
    }
    return out.items;
}

fn hasRealContent(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "//")) continue;
        return true;
    }
    return false;
}

fn firstComment(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0) continue;
        if (t[0] == '#') {
            const c = std.mem.trim(u8, t[1..], " \t");
            if (c.len == 0 or c[0] == '@') return null;
            return c;
        }
        return null;
    }
    return null;
}

/// The block holding `line` (0-based), else the first block.
pub fn blockAtLine(list: []const Block, line: usize) ?Block {
    for (list) |b| if (line >= b.start_line and line <= b.end_line) return b;
    if (list.len > 0) return list[0];
    return null;
}

// ─── block edits (item 8) ───────────────────────────────────────────────

/// The lines of `text`, split on `\n`, on `a`.
fn linesOf(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, l);
    return out.items;
}

/// The name a duplicate takes: `name-copy`, `name-copy-2`, … — the
/// first not already a block name in `list`.
pub fn copyName(a: Allocator, list: []const Block, base: ?[]const u8) Allocator.Error![]const u8 {
    const stem = if (base) |b| (if (b.len > 0) b else "copy") else "copy";
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const cand = if (n == 0) try std.mem.concat(a, u8, &.{ stem, "-copy" }) else try std.fmt.allocPrint(a, "{s}-copy-{d}", .{ stem, n + 1 });
        var taken = false;
        for (list) |b| if (b.name) |bn| if (std.mem.eql(u8, bn, cand)) {
            taken = true;
        };
        if (!taken) return cand;
    }
    return try std.mem.concat(a, u8, &.{ stem, "-copy" });
}

/// `text` with block `idx`'s `###` line renamed — a leading block
/// without one gets a `### name` line put before it. Null when there
/// is no such block. Owned.
pub fn renameBlock(alloc: Allocator, text: []const u8, idx: usize, new_name: []const u8) Allocator.Error!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const list = try blocks(a, text);
    if (idx >= list.len) return null;
    const b = list[idx];
    const lines = try linesOf(a, text);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const sep = try std.mem.concat(a, u8, &.{ "### ", std.mem.trim(u8, new_name, " \t") });
    if (b.name == null) {
        try out.appendSlice(a, lines[0..b.start_line]);
        try out.append(a, sep);
        try out.appendSlice(a, lines[b.start_line..]);
    } else {
        try out.appendSlice(a, lines[0..b.start_line]);
        try out.append(a, sep);
        try out.appendSlice(a, lines[b.start_line + 1 ..]);
    }
    return try std.mem.join(alloc, "\n", out.items);
}

/// `text` with a copy of block `idx` put right after it as
/// `### <name>-copy` (a blank line between). Null when there is no
/// such block. Owned.
pub fn duplicateBlock(alloc: Allocator, text: []const u8, idx: usize) Allocator.Error!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const list = try blocks(a, text);
    if (idx >= list.len) return null;
    const b = list[idx];
    const lines = try linesOf(a, text);
    const body_first = if (b.name != null) b.start_line + 1 else b.start_line;
    const last = @min(b.end_line, lines.len - 1);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.appendSlice(a, lines[0 .. last + 1]);
    if (std.mem.trim(u8, lines[last], " \t\r").len > 0) try out.append(a, "");
    try out.append(a, try std.mem.concat(a, u8, &.{ "### ", try copyName(a, list, b.name) }));
    // The block's own lines, less a trailing blank (one is put back).
    var body_last = last;
    while (body_last > body_first and std.mem.trim(u8, lines[body_last], " \t\r").len == 0) body_last -= 1;
    try out.appendSlice(a, lines[body_first .. body_last + 1]);
    if (last + 1 < lines.len) {
        try out.append(a, "");
        try out.appendSlice(a, lines[last + 1 ..]);
    } else try out.append(a, "");
    return try std.mem.join(alloc, "\n", out.items);
}

/// `text` without block `idx` (its `###` line included); the other
/// blocks keep their bytes. Null when there is no such block. Owned.
pub fn deleteBlock(alloc: Allocator, text: []const u8, idx: usize) Allocator.Error!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const list = try blocks(a, text);
    if (idx >= list.len) return null;
    const b = list[idx];
    const lines = try linesOf(a, text);
    const last = @min(b.end_line, lines.len - 1);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.appendSlice(a, lines[0..b.start_line]);
    if (last + 1 < lines.len) try out.appendSlice(a, lines[last + 1 ..]);
    // A file left with only blank lines is empty.
    var any = false;
    for (out.items) |l| if (std.mem.trim(u8, l, " \t\r").len > 0) {
        any = true;
    };
    if (!any) return try alloc.dupe(u8, "");
    return try std.mem.join(alloc, "\n", out.items);
}

/// Block `idx` as a block of its own: its `### name` line (one is
/// made for a nameless leading block) and its lines, ending in one
/// newline — what a move appends to the target file. Null when there
/// is no such block. Owned.
pub fn extractBlock(alloc: Allocator, text: []const u8, idx: usize) Allocator.Error!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const list = try blocks(a, text);
    if (idx >= list.len) return null;
    const b = list[idx];
    const lines = try linesOf(a, text);
    const body_first = if (b.name != null) b.start_line + 1 else b.start_line;
    var last = @min(b.end_line, lines.len - 1);
    while (last > body_first and std.mem.trim(u8, lines[last], " \t\r").len == 0) last -= 1;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(a, if (b.name) |n| (if (n.len > 0) try std.mem.concat(a, u8, &.{ "### ", n }) else "###") else "### moved");
    try out.appendSlice(a, lines[body_first .. last + 1]);
    try out.append(a, "");
    return try std.mem.join(alloc, "\n", out.items);
}

fn sameName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The index in `blocks(text)` of the block named `name` (null = the
/// leading nameless one).
pub fn blockIndex(list: []const Block, name: ?[]const u8) ?usize {
    for (list, 0..) |b, i| if (sameName(b.name, name)) return i;
    return null;
}

/// Which block of `list` a pane on block `index` named `name` is on:
/// that position while the block there still has that name; else the
/// one block of that name when the name is unique; else null. A name
/// shared by two blocks (two bare `###`) never resolves by name — a
/// guess there would rewrite a different request.
pub fn resolveBlock(list: []const Block, index: ?u32, name: ?[]const u8) ?usize {
    if (index) |i| if (i < list.len and sameName(list[i].name, name)) return i;
    var found: ?usize = null;
    for (list, 0..) |b, i| if (sameName(b.name, name)) {
        if (found != null) return null;
        found = i;
    };
    return found;
}

// ─── serialisation ──────────────────────────────────────────────────────

fn escapeSingle(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    return out.items;
}

/// `curl 'url' -X M \` + one `-H` per line + `--data-raw`. Round-trips
/// through `parseCurl`.
pub fn toCurl(gpa: Allocator, req: *const Request) Allocator.Error![]u8 {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (req.script) |sc| {
        try out.appendSlice(a, sc);
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "curl '");
    try out.appendSlice(a, try escapeSingle(a, req.url));
    try out.append(a, '\'');
    const is_get = std.ascii.eqlIgnoreCase(req.method, "GET");
    const implied_post = std.ascii.eqlIgnoreCase(req.method, "POST") and req.body != null;
    if (!is_get and !implied_post) {
        try out.appendSlice(a, " -X ");
        try out.appendSlice(a, req.method);
    }
    for (req.headers.items) |h| {
        try out.appendSlice(a, " \\\n  -H '");
        try out.appendSlice(a, h.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, try escapeSingle(a, h.value));
        try out.append(a, '\'');
    }
    if (req.body) |b| switch (bodyType(req)) {
        .multipart => for (try multipart.parseRows(a, b)) |row| {
            try out.appendSlice(a, " \\\n  -F '");
            try out.appendSlice(a, try escapeSingle(a, row.name));
            try out.append(a, '=');
            if (row.file != null) try out.append(a, '@');
            try out.appendSlice(a, try escapeSingle(a, row.value));
            try out.append(a, '\'');
        },
        .form => for (try multipart.parseRows(a, b)) |row| {
            try out.appendSlice(a, " \\\n  --data-urlencode '");
            try out.appendSlice(a, try escapeSingle(a, row.name));
            try out.append(a, '=');
            try out.appendSlice(a, try escapeSingle(a, row.value));
            try out.append(a, '\'');
        },
        .raw, .json => {
            try out.appendSlice(a, " \\\n  --data-raw '");
            try out.appendSlice(a, try escapeSingle(a, b));
            try out.append(a, '\'');
        },
    };
    if (req.insecure) try out.appendSlice(a, " -k");
    const o = options(req);
    if (o.timeout_ms) |ms| {
        // curl's `--max-time` is seconds; keep the fraction when there is one.
        if (ms % 1000 == 0) try out.print(a, " --max-time {d}", .{ms / 1000}) else try out.print(a, " --max-time {d}.{d:0>3}", .{ ms / 1000, ms % 1000 });
    }
    if (o.follow_redirects) |f| try out.appendSlice(a, if (f) " -L" else " --max-redirs 0");
    if (o.max_redirects) |n| if (o.follow_redirects != false) try out.print(a, " --max-redirs {d}", .{n});
    if (o.proxy) |p| {
        try out.appendSlice(a, " -x '");
        try out.appendSlice(a, try escapeSingle(a, p));
        try out.append(a, '\'');
    }
    return gpa.dupe(u8, out.items);
}

/// `### name` (when given), the request line, headers, blank, body.
pub fn toHttpBlock(a: Allocator, req: *const Request, name: ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (name) |n| {
        try out.appendSlice(a, if (n.len == 0) "###\n" else "### ");
        if (n.len > 0) {
            try out.appendSlice(a, n);
            try out.append(a, '\n');
        }
    }
    if (req.script) |sc| {
        try out.appendSlice(a, sc);
        try out.append(a, '\n');
    }
    // A `-k` that never became a line (a request built by hand).
    if (req.insecure and !hasDirective(req, "@insecure")) try out.appendSlice(a, "# @insecure\n");
    try out.appendSlice(a, req.method);
    try out.append(a, ' ');
    try out.appendSlice(a, req.url);
    try out.append(a, '\n');
    for (req.headers.items) |h| {
        try out.appendSlice(a, h.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, h.value);
        try out.append(a, '\n');
    }
    if (req.body) |b| {
        try out.append(a, '\n');
        try out.appendSlice(a, b);
        if (b.len == 0 or b[b.len - 1] != '\n') try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

pub const SpliceError = Allocator.Error || error{NoSuchBlock};

/// Replace block `index` (named `name`; see `resolveBlock`) of a
/// multi-block file with `new_block`. Null when the file has fewer than
/// two blocks and the pane is on its only one — the caller overwrites.
/// `error.NoSuchBlock` when the block cannot be told apart any more:
/// the caller refuses rather than write over a different request.
pub fn splice(a: Allocator, existing: []const u8, index: ?u32, name: ?[]const u8, new_block: []const u8) SpliceError!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const list = try blocks(sa, existing);
    if (list.len < 2) {
        if ((index orelse 0) != 0) return error.NoSuchBlock;
        return null;
    }
    const t = list[resolveBlock(list, index, name) orelse return error.NoSuchBlock];
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |l| try lines.append(sa, l);
    const last = lines.items.len -| 1;
    const end = @min(t.end_line, last);
    const replacement = std.mem.trimEnd(u8, new_block, "\n");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.appendSlice(sa, lines.items[0..t.start_line]);
    var rit = std.mem.splitScalar(u8, replacement, '\n');
    while (rit.next()) |l| try out.append(sa, l);
    // The blank line that separated this block from the next `###`
    // was absorbed into its range; put it back.
    const removed_blank = std.mem.trim(u8, lines.items[end], " \t\r").len == 0;
    const next_is_sep = end + 1 < lines.items.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[end + 1], " \t"), "###");
    if (removed_blank and next_is_sep) try out.append(sa, "");
    // The last block's range runs to the file's end, its final newline
    // included; a save keeps the newline the file ended in.
    if (end + 1 < lines.items.len) {
        try out.appendSlice(sa, lines.items[end + 1 ..]);
    } else if (std.mem.endsWith(u8, existing, "\n")) try out.append(sa, "");
    return try std.mem.join(a, "\n", out.items);
}

/// `Key: Value` per line, with a trailing newline so a caret placed at
/// the end lands on a fresh line.
pub fn headersToText(a: Allocator, headers: []const Header) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (headers) |h| {
        try out.appendSlice(a, h.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, h.value);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// The inverse: every `Key: Value` line; blanks and `#` lines skipped.
pub fn setHeadersFromText(req: *Request, gpa: Allocator, text: []const u8) Allocator.Error!void {
    var fresh: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (fresh.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        fresh.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const kv = splitHeader(t) orelse continue;
        const n = try gpa.dupe(u8, kv[0]);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, kv[1]);
        errdefer gpa.free(v);
        try fresh.append(gpa, .{ .name = n, .value = v });
    }
    req.clearHeaders(gpa);
    req.headers = fresh;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "curl: chrome GET with headers, cookies, user-agent" {
    var req = try parseCurl(testing.allocator,
        \\curl 'https://x.com/a?b=1' \
        \\  -H 'accept: */*' \
        \\  -H 'Accept: text/html' \
        \\  -b 'sid=1' -b 'k=v' \
        \\  -A 'mnml' --compressed
    );
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("https://x.com/a?b=1", req.url);
    // last -H for a name wins, at the first position
    try testing.expectEqualStrings("text/html", req.headers.items[0].value);
    try testing.expectEqualStrings("Accept", req.headers.items[0].name);
    try testing.expectEqualStrings("mnml", req.header("User-Agent").?);
    try testing.expectEqualStrings("sid=1; k=v", req.header("cookie").?);
    try testing.expect(req.body == null);
}

test "curl: --data-raw implies POST; -X wins; -u makes Basic; $'…' decodes; -k" {
    var req = try parseCurl(testing.allocator, "curl -X PUT 'https://x/b' --data-raw $'{\"p\":\"a\\u0021\"}' -u me:pw -k");
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("PUT", req.method);
    try testing.expectEqualStrings("{\"p\":\"a!\"}", req.body.?);
    try testing.expectEqualStrings("Basic bWU6cHc=", req.header("authorization").?);
    try testing.expect(req.insecure);
    var post = try parseCurl(testing.allocator, "curl https://x/c -d 'a=1'");
    defer post.deinit(testing.allocator);
    try testing.expectEqualStrings("POST", post.method);
    try testing.expectEqualStrings("a=1", post.body.?);
}

test "curl: a response appended after the command is dropped; no url errors; unterminated quote errors" {
    var req = try parseCurl(testing.allocator, "curl 'https://x/y' -H 'a: b'\n{\"resp\": true}\n");
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("https://x/y", req.url);
    try testing.expectError(error.NoUrl, parseCurl(testing.allocator, "curl -H 'a: b'"));
    try testing.expectError(error.UnterminatedQuote, parseCurl(testing.allocator, "curl 'https://x"));
    try testing.expectError(error.Empty, parse(testing.allocator, "   \n"));
}

test "curl: embedded single quote via concatenation; -F lands as multipart rows, --data-urlencode as form rows; both round-trip through toCurl" {
    var req = try parseCurl(testing.allocator, "curl 'https://x/it'\\''s' -F name=@nofile -F 'k=v w'");
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("https://x/it's", req.url);
    try testing.expectEqualStrings("name = @nofile\nk = v w\n", req.body.?);
    try testing.expectEqual(BodyType.multipart, bodyType(&req));
    try testing.expect(req.header("content-type") == null);
    try testing.expectEqualStrings("POST", req.method);
    const curl = try toCurl(testing.allocator, &req);
    defer testing.allocator.free(curl);
    try testing.expectEqualStrings("# @body-type multipart\ncurl 'https://x/it'\\''s' \\\n  -F 'name=@nofile' \\\n  -F 'k=v w'", curl);
    var form = try parse(testing.allocator, "curl https://x/f --data-urlencode 'a=1 2' --data-urlencode b=x");
    defer form.deinit(testing.allocator);
    try testing.expectEqual(BodyType.form, bodyType(&form));
    try testing.expectEqualStrings("a = 1 2\nb = x\n", form.body.?);
    const fcurl = try toCurl(testing.allocator, &form);
    defer testing.allocator.free(fcurl);
    try testing.expect(std.mem.endsWith(u8, fcurl, "--data-urlencode 'a=1 2' \\\n  --data-urlencode 'b=x'"));
    var back = try parse(testing.allocator, fcurl);
    defer back.deinit(testing.allocator);
    try testing.expectEqualStrings(form.body.?, back.body.?);
    // `-G --data-urlencode` is the query string, as curl sends it.
    var get = try parseCurl(testing.allocator, "curl -G https://x/g --data-urlencode q=1");
    defer get.deinit(testing.allocator);
    try testing.expectEqualStrings("https://x/g?q=1", get.url);
    try testing.expect(get.body == null);
    // The block form: the directive, the rows, the chip's cycle.
    var blk = try parse(testing.allocator, "# @body-type multipart\nPOST https://x/up\n\nname = alice\nfile = @data.txt\n");
    defer blk.deinit(testing.allocator);
    try testing.expectEqual(BodyType.multipart, bodyType(&blk));
    try setBodyType(&blk, testing.allocator, .json);
    try testing.expectEqualStrings("# @body-type json", blk.script.?);
    try setBodyType(&blk, testing.allocator, .raw);
    try testing.expect(blk.script == null);
    try testing.expectEqual(BodyType.json, BodyType.multipart.next().next());
    try testing.expectEqual(BodyType.form, BodyType.fromWord("urlencoded").?);
    try testing.expect(BodyType.fromWord("nope") == null);
}

test ".http: method line, headers, body; bare url is GET; comments skipped" {
    var req = try parseHttp(testing.allocator, "# note\nPOST https://x.com/b HTTP/1.1\nContent-Type: application/json\n\n{\"a\":1}\n");
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("https://x.com/b", req.url);
    try testing.expectEqualStrings("application/json", req.header("content-type").?);
    try testing.expectEqualStrings("{\"a\":1}", req.body.?);
    var bare = try parse(testing.allocator, "https://x.com/z\n");
    defer bare.deinit(testing.allocator);
    try testing.expectEqualStrings("GET", bare.method);
    try testing.expectEqualStrings("https://x.com/z", bare.url);
}

test "parse dispatches: http-shaped text goes to the .http parser, else curl" {
    var c = try parse(testing.allocator, "curl 'https://x.com/a' -H 'accept: */*'");
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("https://x.com/a", c.url);
    var h = try parse(testing.allocator, "POST https://x.com/b\nContent-Type: application/json\n\n{\"a\":1}");
    defer h.deinit(testing.allocator);
    try testing.expectEqualStrings("POST", h.method);
    try testing.expectEqualStrings("{\"a\":1}", h.body.?);
    // `curl <word>` treats the word as a URL, as curl itself does.
    var n = try parse(testing.allocator, "nonsense");
    defer n.deinit(testing.allocator);
    try testing.expectEqualStrings("nonsense", n.url);
}

test "blocks: separators, names, line ranges, the leading unnamed block, the cursor lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "GET https://x/lead\n\n### one\nGET https://x/one\n\n###\nPOST https://x/two\n\n{}\n\n### empty\n# only a comment\n";
    const list = try blocks(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expect(list[0].name == null);
    try testing.expectEqual(@as(usize, 0), list[0].start_line);
    try testing.expectEqual(@as(usize, 1), list[0].end_line);
    try testing.expectEqualStrings("one", list[1].name.?);
    try testing.expectEqual(@as(usize, 2), list[1].start_line);
    try testing.expectEqual(@as(usize, 4), list[1].end_line);
    try testing.expectEqualStrings("", list[2].name.?);
    try testing.expectEqual(@as(usize, 5), list[2].start_line);
    try testing.expectEqualStrings("two", std.mem.trim(u8, blockAtLine(list, 7).?.text, "\n")[15..18]);
    try testing.expectEqualStrings("one", blockAtLine(list, 3).?.name.?);
    try testing.expect(blockAtLine(list, 99).?.name == null);
    try testing.expectEqual(@as(u32, 2), list[2].index);
    // a .curl multi-block file
    const curls = try blocks(arena.allocator(), "curl 'http://a/1'\n\n### GetB\ncurl 'http://a/2'\n");
    try testing.expectEqual(@as(usize, 2), curls.len);
    var second = try parse(testing.allocator, curls[1].text);
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings("http://a/2", second.url);
}

test "toCurl round-trips through parseCurl; toHttpBlock names the block" {
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setMethod(testing.allocator, "patch");
    try req.setUrl(testing.allocator, "https://x/it's");
    try req.addHeader(testing.allocator, "Authorization", "Bearer tok");
    try req.setBody(testing.allocator, "{\"a\":'q'}");
    const curl = try toCurl(testing.allocator, &req);
    defer testing.allocator.free(curl);
    try testing.expectEqualStrings("curl 'https://x/it'\\''s' -X PATCH \\\n  -H 'Authorization: Bearer tok' \\\n  --data-raw '{\"a\":'\\''q'\\''}'", curl);
    var back = try parseCurl(testing.allocator, curl);
    defer back.deinit(testing.allocator);
    try testing.expectEqualStrings(req.url, back.url);
    try testing.expectEqualStrings("PATCH", back.method);
    try testing.expectEqualStrings(req.body.?, back.body.?);
    const block = try toHttpBlock(testing.allocator, &req, "two");
    defer testing.allocator.free(block);
    try testing.expectEqualStrings("### two\nPATCH https://x/it's\nAuthorization: Bearer tok\n\n{\"a\":'q'}\n", block);
}

test "two bare ### blocks are told apart by position: splice rewrites the one asked for" {
    const src = "###\nGET http://h/items?n=first\n\n###\nGET http://h/items?n=second\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try blocks(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), list.len);
    // Same name, different blocks: the name alone resolves to neither.
    try testing.expect(resolveBlock(list, null, "") == null);
    try testing.expectEqual(@as(?usize, 1), resolveBlock(list, 1, ""));
    const out = (try splice(testing.allocator, src, 1, "", "###\nGET http://h/items?n=second&edited=1\n")).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("###\nGET http://h/items?n=first\n\n###\nGET http://h/items?n=second&edited=1\n", out);
    // A position that no longer holds a block of that name, with the
    // name shared: refused, never a guess.
    try testing.expectError(error.NoSuchBlock, splice(testing.allocator, src, 5, "", "x"));
    // A unique name still follows its block when the position moved.
    const named = "### a\nGET http://h/a\n\n### b\nGET http://h/b\n";
    const moved = (try splice(testing.allocator, named, 0, "b", "### b\nGET http://h/b2\n")).?;
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.indexOf(u8, moved, "GET http://h/a\n") != null);
    try testing.expect(std.mem.indexOf(u8, moved, "GET http://h/b2") != null);
}

test "splice rewrites one block and keeps the others byte for byte" {
    const src = "### one\nGET https://example.com/one\n\n### two\nPOST https://example.com/two\nContent-Type: application/json\n\n{\"a\": 1}\n\n### three\nGET https://example.com/three\n";
    const out = (try splice(testing.allocator, src, 1, "two", "### two\nPUT https://example.com/two-EDITED\n")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "### one\nGET https://example.com/one\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\n### three\nGET https://example.com/three\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PUT https://example.com/two-EDITED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "two\nContent-Type") == null);
    // the leading block keeps its blank separator
    const lead = "GET https://x/lead\n\n### one\nGET https://x/one\n";
    const out2 = (try splice(testing.allocator, lead, 0, null, "GET https://x/lead2\n")).?;
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("GET https://x/lead2\n\n### one\nGET https://x/one\n", out2);
    try testing.expect((try splice(testing.allocator, "GET https://x/only\n", 0, null, "x")) == null);
    try testing.expectError(error.NoSuchBlock, splice(testing.allocator, src, 7, "nope", "x"));
}

test "params: add, list, clear; headers text round-trip; blank detection" {
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try testing.expect(req.isBlank());
    try req.setUrl(testing.allocator, "https://e.com/api#frag");
    try req.addParam(testing.allocator, "a", "1");
    try req.addParam(testing.allocator, "b", "2");
    try testing.expectEqualStrings("https://e.com/api?a=1&b=2#frag", req.url);
    const ps = try req.params(testing.allocator);
    defer testing.allocator.free(ps);
    try testing.expectEqual(@as(usize, 2), ps.len);
    try testing.expectEqualStrings("b", ps[1].key);
    const bare = try req.urlWithoutQuery(testing.allocator);
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("https://e.com/api#frag", bare);
    try setHeadersFromText(&req, testing.allocator, "A: 1\n\n# c\nB:2\n");
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try testing.expectEqualStrings("2", req.header("b").?);
    const text = try headersToText(testing.allocator, req.headers.items);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("A: 1\nB: 2\n", text);
    try req.setHeader(testing.allocator, "a", "9");
    try testing.expectEqualStrings("9", req.headers.items[0].value);
    try testing.expectEqual(@as(usize, 1), req.removeHeader(testing.allocator, "A"));
    try testing.expect(!req.isBlank());
    try testing.expect(isRequestPath("/x/y.CURL") and isRequestPath("a.http") and !isRequestPath("a.txt"));
    try testing.expectEqualStrings("POST", nextMethod("get"));
    try testing.expectEqualStrings("GET", nextMethod("OPTIONS"));
}

test "directives after the body boundary are script, never body: a GET keeps no body" {
    // The documented shape: `# @assert` / `# @capture` after the blank
    // line that ends the headers. The lines are directives wherever
    // they sit in the block; the wire body must not carry them.
    var req = try parse(testing.allocator,
        \\### get-json
        \\GET https://x/get
        \\Accept: application/json
        \\
        \\# @assert status == 200
        \\# @capture origin = body.origin
        \\
    );
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expect(req.body == null);
    try testing.expectEqualStrings("# @assert status == 200\n# @capture origin = body.origin", req.script.?);
}

test "directives after a POST body: the body is byte-identical to the JSON, the directives are script" {
    const json = "{\n  \"hello\": \"world\",\n  \"token\": \"{{$uuid}}\"\n}";
    const src = "POST https://x/post\nContent-Type: application/json\n\n" ++ json ++ "\n\n# @assert status == 200\n// @capture origin = body.json.hello\n";
    var req = try parse(testing.allocator, src);
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings(json, req.body.?);
    try testing.expectEqualStrings("# @assert status == 200\n// @capture origin = body.json.hello", req.script.?);
    // A plain comment after the boundary is body (Rust's rule: every
    // line past the blank goes to the body verbatim); a `# @` line is
    // not, wherever it sits.
    var mixed = try parse(testing.allocator, "POST https://x/p\n\n# @assert status == 201\nline one\n# not a directive\nline two\n# @capture ID = body.id\n");
    defer mixed.deinit(testing.allocator);
    try testing.expectEqualStrings("line one\n# not a directive\nline two", mixed.body.?);
    try testing.expectEqualStrings("# @assert status == 201\n# @capture ID = body.id", mixed.script.?);
    // A body made only of directives is no body.
    var only = try parse(testing.allocator, "DELETE https://x/d\n\n# @assert status == 204\n");
    defer only.deinit(testing.allocator);
    try testing.expect(only.body == null);
    // CRLF source: the body keeps its bytes, the directives still go.
    var crlf = try parse(testing.allocator, "POST https://x/p\r\nA: 1\r\n\r\n{\"a\":1}\r\n# @assert status == 200\r\n");
    defer crlf.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"a\":1}", crlf.body.?);
    try testing.expect(crlf.script != null);
}

test "parseHttp never fails hard on a malformed block: thirty shapes" {
    // Every one either parses or returns a ParseError; none may panic.
    const cases = [_][]const u8{
        "# @assert status == 200",
        "# @assert status == 200\nGET https://x",
        "GET https://x\n# @assert status == 200\nAccept: */*\n\nbody",
        "GET https://x\n\n# only\n# comments\n",
        "GET https://x\n\n// @capture A = body.a\n// @assert body contains x",
        "GET https://x\nContent-Length: 12\n",
        "GET https://x\nContent-Length: 12\n\n",
        "HEAD https://x\n\nignored body\n",
        "OPTIONS https://x\n\n# @set-header X = 1\n",
        "POST https://x\n\n### mid ### line\n",
        "POST https://x\n\n{\"a\": \"###\"}\n",
        "POST https://x\r\nA: 1\r\n\r\n\r\n\r\n",
        "POST https://x\r\n\r\n#\r\n# @\r\n#@assert\r\n",
        "GET https://x\n\n\n\n\n",
        "GET\n",
        "GET \n\n# @assert status == 200\n",
        "https://x\n# @assert status == 200",
        "https://x\n\n# @assert status == 200\n",
        "PATCH https://x HTTP/1.1\nA: b: c\n\n# @capture X = body\n",
        "PUT https://x\nA\n\n# @assert status == 200\n",
        "TRACE https://x\n\n#@assert status == 200\n",
        "CONNECT https://x\n\n# @assert\n",
        "GET https://x\n:\n\n# @assert status == 200\n",
        "GET https://x\n\n\t# @assert status == 200\n",
        "GET https://x\n\n  // @capture A = header x\n\n\n",
        "GET https://x\n\n#\n//\n#@\n//@\n",
        "GET https://x\n\n\x00\x01\x02\n# @assert status == 200\n",
        "GET https://x\n\n# @assert status == 200\nafter directive\n",
        "POST https://x\n\n{\n# @assert status == 200\n}\n",
        "\n\n\n### name\n\n# @assert status == 200\nGET https://x\n\n\n",
    };
    try testing.expectEqual(@as(usize, 30), cases.len);
    for (cases) |c| {
        var req = parse(testing.allocator, c) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer req.deinit(testing.allocator);
        // Whatever landed, no directive line is in the body.
        if (req.body) |b| {
            var lines = std.mem.splitScalar(u8, b, '\n');
            while (lines.next()) |l| try testing.expect(!script_mod.isDirectiveLine(l));
        }
    }
}

fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var req = parse(testing.allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer req.deinit(testing.allocator);
    if (req.body) |b| {
        var lines = std.mem.splitScalar(u8, b, '\n');
        while (lines.next()) |l| try testing.expect(!script_mod.isDirectiveLine(l));
    }
}

test "fuzz: any bytes through parse; no directive line survives into a body" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{ "GET https://x\n\n# @assert status == 200\n", "POST https://x\n\n{}\n# @capture A = body.a\n" } });
}

test "options: directive lines and curl flags are one store; block ↔ curl ↔ block round-trips every option" {
    const gpa = testing.allocator;
    var a = try parse(gpa, "# @insecure\n# @timeout 2.5s\n# @no-redirect\n# @proxy 10.0.0.1:3128\nGET https://x/a\n");
    defer a.deinit(gpa);
    const o = options(&a);
    try testing.expect(o.insecure and a.insecure);
    try testing.expectEqual(@as(?u64, 2500), o.timeout_ms);
    try testing.expectEqual(@as(?bool, false), o.follow_redirects);
    try testing.expectEqualStrings("10.0.0.1:3128", o.proxy.?);
    const curl = try toCurl(gpa, &a);
    defer gpa.free(curl);
    try testing.expect(std.mem.indexOf(u8, curl, " -k") != null);
    try testing.expect(std.mem.indexOf(u8, curl, " --max-time 2.500") != null);
    try testing.expect(std.mem.indexOf(u8, curl, " --max-redirs 0") != null);
    try testing.expect(std.mem.indexOf(u8, curl, " -x '10.0.0.1:3128'") != null);
    // Back through the curl parser: the same options, each line once.
    var b = try parse(gpa, curl);
    defer b.deinit(gpa);
    const ob = options(&b);
    try testing.expect(ob.insecure);
    try testing.expectEqual(@as(?u64, 2500), ob.timeout_ms);
    try testing.expectEqual(@as(?bool, false), ob.follow_redirects);
    try testing.expectEqualStrings("10.0.0.1:3128", ob.proxy.?);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.script.?, "@insecure"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.script.?, "@timeout"));
    const block = try toHttpBlock(gpa, &b, null);
    defer gpa.free(block);
    try testing.expectEqualStrings("# @insecure\n# @timeout 2.5s\n# @no-redirect\n# @proxy 10.0.0.1:3128\nGET https://x/a\n", block);
    // A pasted curl with the flags alone: the lines are made for it.
    var c = try parse(gpa, "curl -L --max-time 5 --max-redirs 3 -x 'http://me:pw@p:1' 'http://y'");
    defer c.deinit(gpa);
    const oc = options(&c);
    try testing.expectEqual(@as(?bool, true), oc.follow_redirects);
    try testing.expectEqual(@as(?u8, 3), oc.max_redirects);
    try testing.expectEqual(@as(?u64, 5000), oc.timeout_ms);
    try testing.expectEqualStrings("http://me:pw@p:1", oc.proxy.?);
    try testing.expect(!oc.insecure);
    const c_curl = try toCurl(gpa, &c);
    defer gpa.free(c_curl);
    try testing.expect(std.mem.indexOf(u8, c_curl, " -L --max-redirs 3") != null);
    try testing.expect(std.mem.indexOf(u8, c_curl, " --max-time 5 ") != null or std.mem.endsWith(u8, c_curl, "--max-time 5 -L --max-redirs 3 -x 'http://me:pw@p:1'"));
    const c_block = try toHttpBlock(gpa, &c, "named");
    defer gpa.free(c_block);
    try testing.expect(std.mem.startsWith(u8, c_block, "### named\n# @timeout 5s\n# @follow-redirects\n# @max-redirects 3\n# @proxy http://me:pw@p:1\nGET http://y\n"));
    // `--max-redirs 0` is `@no-redirect`; a request with nothing set writes no line and no flag.
    var d = try parse(gpa, "curl --max-redirs 0 http://z");
    defer d.deinit(gpa);
    try testing.expectEqual(@as(?bool, false), options(&d).follow_redirects);
    var e = try parse(gpa, "GET http://z\n");
    defer e.deinit(gpa);
    try testing.expect(e.script == null);
    const e_curl = try toCurl(gpa, &e);
    defer gpa.free(e_curl);
    try testing.expectEqualStrings("curl 'http://z'", e_curl);
    // The other directives stay untouched beside the option lines.
    var f = try parse(gpa, "# @assert status == 200\n# @timeout 1s\nGET http://z\n");
    defer f.deinit(gpa);
    try testing.expectEqualStrings("# @assert status == 200\n# @timeout 1s", f.script.?);
    try testing.expectEqual(@as(?u64, 1000), options(&f).timeout_ms);
}

test "options: setDirective replaces, adds, removes; durations parse and print both ways" {
    const gpa = testing.allocator;
    var req = try parse(gpa, "# @assert status == 200\nGET http://z\n");
    defer req.deinit(gpa);
    try setDirective(&req, gpa, "@timeout", "5s");
    try testing.expectEqualStrings("# @assert status == 200\n# @timeout 5s", req.script.?);
    try setDirective(&req, gpa, "@timeout", "250ms");
    try testing.expectEqualStrings("# @assert status == 200\n# @timeout 250ms", req.script.?);
    try setDirective(&req, gpa, "@insecure", "");
    try testing.expect(req.insecure);
    try testing.expectEqualStrings("# @assert status == 200\n# @timeout 250ms\n# @insecure", req.script.?);
    try setDirective(&req, gpa, "@insecure", null);
    try testing.expect(!req.insecure);
    try setDirective(&req, gpa, "@timeout", null);
    try testing.expectEqualStrings("# @assert status == 200", req.script.?);
    try setDirective(&req, gpa, "@assert", null);
    try testing.expect(req.script == null);
    try setDirective(&req, gpa, "@proxy", "h:1");
    try testing.expectEqualStrings("# @proxy h:1", req.script.?);
    try testing.expectEqual(@as(?u64, 5000), parseDuration("5s"));
    try testing.expectEqual(@as(?u64, 2500), parseDuration("2.5s"));
    try testing.expectEqual(@as(?u64, 300), parseDuration("300ms"));
    try testing.expectEqual(@as(?u64, 120_000), parseDuration("2m"));
    try testing.expectEqual(@as(?u64, 750), parseDuration("750"));
    try testing.expectEqual(@as(?u64, null), parseDuration("soon"));
    try testing.expectEqual(@as(?u64, null), parseDuration("5 fortnights"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("5s", formatDuration(&buf, 5000));
    try testing.expectEqualStrings("2.5s", formatDuration(&buf, 2500));
    try testing.expectEqualStrings("300ms", formatDuration(&buf, 300));
    try testing.expectEqualStrings("2m", formatDuration(&buf, 120_000));
    try testing.expectEqualStrings("1234ms", formatDuration(&buf, 1234));
}

test "path params: `:name` after a slash only, `::` escapes, the port and the query are not params; substitution and the @path lines round-trip" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const names = try pathParamNames(a, "http://h:8080/users/:id/posts/:post_id/::literal/:id?q=:x#:frag");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("id", names[0]);
    try testing.expectEqualStrings("post_id", names[1]);
    try testing.expectEqual(@as(usize, 0), (try pathParamNames(a, "http://h:8080")).len);
    try testing.expectEqual(@as(usize, 1), (try pathParamNames(a, "{{BASE}}/a/:b")).len);
    const out = try substitutePath(gpa, "http://h:8080/users/:id/posts/:post_id/::literal/:id?q=:x", &.{ .{ .name = "id", .value = "42" }, .{ .name = "post_id", .value = "" } });
    defer gpa.free(out);
    try testing.expectEqualStrings("http://h:8080/users/42/posts/:post_id/:literal/42?q=:x", out);
    const untouched = try substitutePath(gpa, "http://h/plain", &.{});
    defer gpa.free(untouched);
    try testing.expectEqualStrings("http://h/plain", untouched);
    // The directive lines: parse, set, replace, remove; the URL keeps `:id`.
    var req = try parse(gpa, "# @path id=42\n# @assert status == 200\nGET https://x/users/:id\n");
    defer req.deinit(gpa);
    try testing.expectEqualStrings("https://x/users/:id", req.url);
    const pp = try pathParams(a, &req);
    try testing.expectEqual(@as(usize, 1), pp.len);
    try testing.expectEqualStrings("42", pp[0].value);
    try testing.expectEqualStrings("42", pathParamValue(&req, "id").?);
    try setPathParam(&req, gpa, "id", "7");
    try setPathParam(&req, gpa, "other", "x y");
    try testing.expectEqualStrings("# @path id=7\n# @assert status == 200\n# @path other=x y", req.script.?);
    try setPathParam(&req, gpa, "id", null);
    try testing.expectEqualStrings("# @assert status == 200\n# @path other=x y", req.script.?);
    try testing.expect(pathParamValue(&req, "id") == null);
    const block = try toHttpBlock(gpa, &req, null);
    defer gpa.free(block);
    try testing.expectEqualStrings("# @assert status == 200\n# @path other=x y\nGET https://x/users/:id\n", block);
    const curl = try toCurl(gpa, &req);
    defer gpa.free(curl);
    try testing.expect(std.mem.indexOf(u8, curl, "# @path other=x y\ncurl 'https://x/users/:id'") != null);
    var back = try parse(gpa, curl);
    defer back.deinit(gpa);
    try testing.expectEqualStrings("x y", pathParamValue(&back, "other").?);
}

test "block edits: rename (a nameless leading block gains its line), duplicate as name-copy, delete keeps the rest byte for byte, extract makes a block of its own" {
    const gpa = testing.allocator;
    const src = "GET https://x/lead\n\n### one\n# @tags a\nGET https://x/one\n\n### two\nPOST https://x/two\n\n{}\n";
    const renamed = (try renameBlock(gpa, src, 1, "uno")).?;
    defer gpa.free(renamed);
    try testing.expectEqualStrings("GET https://x/lead\n\n### uno\n# @tags a\nGET https://x/one\n\n### two\nPOST https://x/two\n\n{}\n", renamed);
    const lead = (try renameBlock(gpa, src, 0, "lead")).?;
    defer gpa.free(lead);
    try testing.expect(std.mem.startsWith(u8, lead, "### lead\nGET https://x/lead\n\n### one\n"));
    try testing.expect((try renameBlock(gpa, src, 9, "x")) == null);
    const dup = (try duplicateBlock(gpa, src, 1)).?;
    defer gpa.free(dup);
    try testing.expectEqualStrings("GET https://x/lead\n\n### one\n# @tags a\nGET https://x/one\n\n### one-copy\n# @tags a\nGET https://x/one\n\n### two\nPOST https://x/two\n\n{}\n", dup);
    // The copy of the last block lands at the end; a second copy counts up.
    const dup_last = (try duplicateBlock(gpa, src, 2)).?;
    defer gpa.free(dup_last);
    try testing.expect(std.mem.endsWith(u8, dup_last, "### two\nPOST https://x/two\n\n{}\n\n### two-copy\nPOST https://x/two\n\n{}\n"));
    const dup_again = (try duplicateBlock(gpa, dup, 1)).?;
    defer gpa.free(dup_again);
    try testing.expect(std.mem.indexOf(u8, dup_again, "### one-copy-2\n") != null);
    const del = (try deleteBlock(gpa, src, 1)).?;
    defer gpa.free(del);
    try testing.expectEqualStrings("GET https://x/lead\n\n### two\nPOST https://x/two\n\n{}\n", del);
    const del_lead = (try deleteBlock(gpa, src, 0)).?;
    defer gpa.free(del_lead);
    try testing.expectEqualStrings("### one\n# @tags a\nGET https://x/one\n\n### two\nPOST https://x/two\n\n{}\n", del_lead);
    const gone = (try deleteBlock(gpa, "### only\nGET https://x\n", 0)).?;
    defer gpa.free(gone);
    try testing.expectEqualStrings("", gone);
    const ext = (try extractBlock(gpa, src, 2)).?;
    defer gpa.free(ext);
    try testing.expectEqualStrings("### two\nPOST https://x/two\n\n{}\n", ext);
    const ext_lead = (try extractBlock(gpa, src, 0)).?;
    defer gpa.free(ext_lead);
    try testing.expectEqualStrings("### moved\nGET https://x/lead\n", ext_lead);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = try blocks(arena.allocator(), src);
    try testing.expectEqual(@as(?usize, 2), blockIndex(list, "two"));
    try testing.expectEqual(@as(?usize, 0), blockIndex(list, null));
    try testing.expect(blockIndex(list, "nope") == null);
}

test "description and tags: the directives read, set, replace and remove; the block keeps them" {
    const gpa = testing.allocator;
    var req = try parse(gpa, "# @description List the users, paged\n# @tags users, smoke #v2\nGET https://x/users\n");
    defer req.deinit(gpa);
    try testing.expectEqualStrings("List the users, paged", description(&req).?);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const t = try tags(arena.allocator(), &req);
    try testing.expectEqual(@as(usize, 3), t.len);
    try testing.expectEqualStrings("users", t[0]);
    try testing.expectEqualStrings("v2", t[2]);
    try setTags(&req, gpa, "a b");
    try setDescription(&req, gpa, "  Changed ");
    try testing.expectEqualStrings("# @description Changed\n# @tags a b", req.script.?);
    try setTags(&req, gpa, "");
    try setDescription(&req, gpa, null);
    try testing.expect(req.script == null);
    try testing.expect(description(&req) == null);
    try testing.expectEqual(@as(usize, 0), (try tags(arena.allocator(), &req)).len);
}
