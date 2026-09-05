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
    // The `# @…` lines ride along whichever shape the block took.
    if (script_mod.hasDirectives(trimmed)) {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const lines = try script_mod.directiveLines(scratch.allocator(), trimmed);
        try req.setScript(alloc, try std.mem.join(scratch.allocator(), "\n", lines));
    }
    return req;
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
    var get_flag = false;

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
        } else if (eqAny(t, &.{ "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode" })) {
            if (next) |v| {
                body = v;
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
        } else if (eqAny(t, &.{ "--compressed", "--location", "-L", "--silent", "-s", "--fail", "-f", "-i", "--include", "-#", "--progress-bar", "-v", "--verbose", "-S", "--show-error" })) {
            // no-ops for the request itself
        } else if (eqAny(t, &.{ "-o", "--output", "-m", "--max-time", "--connect-timeout", "-w", "--write-out", "--retry", "-x", "--proxy", "--cacert", "--cert", "--key", "-c", "--cookie-jar", "--resolve" })) {
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
    if (cookies.items.len > 0) {
        const joined_cookies = try std.mem.join(a, "; ", cookies.items);
        try req.addHeader(alloc, "cookie", joined_cookies);
    }
    if (form.items.len > 0 and body == null) {
        const boundary = "----mnmlBoundary7f3a9c1e";
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (form.items) |part| {
            try out.appendSlice(a, "--");
            try out.appendSlice(a, boundary);
            try out.appendSlice(a, "\r\nContent-Disposition: form-data; name=\"");
            try out.appendSlice(a, part[0]);
            try out.appendSlice(a, "\"\r\n\r\n");
            try out.appendSlice(a, part[1]);
            try out.appendSlice(a, "\r\n");
        }
        try out.appendSlice(a, "--");
        try out.appendSlice(a, boundary);
        try out.appendSlice(a, "--\r\n");
        body = out.items;
        const ct = try std.mem.concat(a, u8, &.{ "multipart/form-data; boundary=", boundary });
        if (req.header("content-type") == null) try req.addHeader(alloc, "content-type", ct);
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
/// blank line, the body. `@name` / `# @directive` lines are skipped.
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
        const body = std.mem.trimEnd(u8, text[bs..], " \t\r\n");
        if (body.len > 0) try req.setBody(alloc, body);
    };
    return req;
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
        try out.append(arena, .{ .name = r.name, .start_line = r.start, .end_line = r.end, .text = text, .summary = firstComment(text) });
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
    if (req.body) |b| {
        try out.appendSlice(a, " \\\n  --data-raw '");
        try out.appendSlice(a, try escapeSingle(a, b));
        try out.append(a, '\'');
    }
    if (req.insecure) try out.appendSlice(a, " -k");
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

/// Replace the block named `name` (null = the leading, separator-less
/// block) of a multi-block file with `new_block`. Null when the file has
/// fewer than two blocks or no such block — the caller overwrites or
/// refuses.
pub fn splice(a: Allocator, existing: []const u8, name: ?[]const u8, new_block: []const u8) Allocator.Error!?[]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const list = try blocks(sa, existing);
    if (list.len < 2) return null;
    var target: ?Block = null;
    for (list) |b| {
        const hit = if (name) |want| (b.name != null and std.mem.eql(u8, b.name.?, want)) else b.name == null;
        if (hit) {
            target = b;
            break;
        }
    }
    const t = target orelse return null;
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
    if (end + 1 < lines.items.len) try out.appendSlice(sa, lines.items[end + 1 ..]);
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

test "curl: embedded single quote via concatenation; -F multipart" {
    var req = try parseCurl(testing.allocator, "curl 'https://x/it'\\''s' -F name=@nofile -F 'k=v w'");
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("https://x/it's", req.url);
    try testing.expect(std.mem.indexOf(u8, req.body.?, "name=\"k\"\r\n\r\nv w") != null);
    try testing.expect(std.mem.startsWith(u8, req.header("content-type").?, "multipart/form-data; boundary="));
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

test "splice rewrites one block and keeps the others byte for byte" {
    const src = "### one\nGET https://example.com/one\n\n### two\nPOST https://example.com/two\nContent-Type: application/json\n\n{\"a\": 1}\n\n### three\nGET https://example.com/three\n";
    const out = (try splice(testing.allocator, src, "two", "### two\nPUT https://example.com/two-EDITED\n")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "### one\nGET https://example.com/one\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\n### three\nGET https://example.com/three\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PUT https://example.com/two-EDITED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "two\nContent-Type") == null);
    // the leading block keeps its blank separator
    const lead = "GET https://x/lead\n\n### one\nGET https://x/one\n";
    const out2 = (try splice(testing.allocator, lead, null, "GET https://x/lead2\n")).?;
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("GET https://x/lead2\n\n### one\nGET https://x/one\n", out2);
    try testing.expect((try splice(testing.allocator, "GET https://x/only\n", null, "x")) == null);
    try testing.expect((try splice(testing.allocator, src, "nope", "x")) == null);
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
