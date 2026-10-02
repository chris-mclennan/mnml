//! What turns text into links: plain `http(s)://` URLs, and the key
//! shapes the installed integrations declare in their manifests'
//! `links[]` (`sdk.manifest.Link`). mnml itself knows no project key,
//! company or product — a key links only because an integration said
//! what it looks like and where it goes.
//!
//! The rule set is built from the manifests when they are read
//! (`rebuild`, from `integrations.refresh` — startup, an install, a
//! refresh), never per frame. A text's links are cached by the text
//! itself, so a card repainting the same words runs no regex; a text
//! not painted for a frame leaves the cache at the next sweep.
//!
//! Precedence: URLs first, then every rule in the order the
//! INTEGRATIONS section lists the integrations (by label), each
//! manifest's links in its own order. The first to claim a stretch of
//! text keeps it, so a key inside a URL stays part of the URL and a key
//! two integrations both match opens the first one's address.
//!
//! A template's `{<key>}` is bound when the rules are built: by the
//! integration's own `--install` (the Jira integration writes its site
//! in), else from the manifest's `settings[]` value of that key, else
//! from the environment variable its `auth[]` field of that key names
//! (`env_fallback`). A rule with a value still missing is not in force
//! (`notes` says which), and one whose address would not be `http(s)`
//! is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const regex = @import("../regex/regex.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const link_span = @import("../ui/link_span.zig");
const integrations = @import("integrations.zig");

pub const Span = link_span.Span;

/// One integration's pattern, compiled, with its address template's
/// values bound.
pub const Rule = struct {
    /// The manifest id, gpa-owned.
    owner: []u8,
    re: regex.Regex,
    /// The template, gpa-owned: only `{0}`–`{9}` / `{match}` left.
    url: []u8,
};

const Entry = struct {
    /// gpa-owned, each `url` too.
    spans: []Span,
    /// The frame that last asked.
    stamp: u32,
};

/// The cache is swept once it holds this many texts.
pub const cache_max: usize = 512;

pub const State = struct {
    rules: std.ArrayListUnmanaged(Rule) = .empty,
    /// Why a declared link is not in force, one line each, gpa-owned.
    notes: std.ArrayListUnmanaged([]u8) = .empty,
    /// Text (gpa-owned key) → its spans.
    cache: std.StringHashMapUnmanaged(Entry) = .empty,
    stamp: u32 = 0,
    gpa: Allocator = undefined,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.clearRules(gpa);
        self.rules.deinit(gpa);
        self.notes.deinit(gpa);
        self.clearCache(gpa);
        self.cache.deinit(gpa);
    }

    fn clearRules(self: *State, gpa: Allocator) void {
        for (self.rules.items) |*r| {
            r.re.deinit();
            gpa.free(r.owner);
            gpa.free(r.url);
        }
        self.rules.clearRetainingCapacity();
        for (self.notes.items) |n| gpa.free(n);
        self.notes.clearRetainingCapacity();
    }

    fn clearCache(self: *State, gpa: Allocator) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            freeSpans(gpa, e.value_ptr.spans);
            gpa.free(e.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }

    /// The top of a frame: a new stamp, and — once the cache is full —
    /// out with every text the last frame did not paint.
    pub fn beginFrame(self: *State, gpa: Allocator) void {
        self.stamp +%= 1;
        if (self.cache.count() < cache_max) return;
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(gpa);
        var it = self.cache.iterator();
        while (it.next()) |e| if (e.value_ptr.stamp +% 1 != self.stamp) stale.append(gpa, e.key_ptr.*) catch break;
        for (stale.items) |k| {
            const kv = self.cache.fetchRemove(k) orelse continue;
            freeSpans(gpa, kv.value.spans);
            gpa.free(kv.key);
        }
    }

    /// The links in `text`, sorted, from the cache or found now. An
    /// out-of-memory answer is "no links": the text still paints.
    pub fn spans(self: *State, gpa: Allocator, text: []const u8) []const Span {
        if (self.cache.getPtr(text)) |e| {
            e.stamp = self.stamp;
            return e.spans;
        }
        const found = find(self, gpa, text) catch return &.{};
        const key = gpa.dupe(u8, text) catch {
            freeSpans(gpa, found);
            return &.{};
        };
        self.cache.put(gpa, key, .{ .spans = found, .stamp = self.stamp }) catch {
            gpa.free(key);
            freeSpans(gpa, found);
            return &.{};
        };
        return found;
    }
};

fn freeSpans(gpa: Allocator, spans: []Span) void {
    for (spans) |s| gpa.free(s.url);
    gpa.free(spans);
}

/// The frame's finder (`Ui.links`).
pub fn finder(app: *App) link_span.Finder {
    return .{ .ctx = app, .find = findFor };
}

fn findFor(ctx: *anyopaque, text: []const u8) []const Span {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.link_rules.spans(app.gpa, text);
}

/// Every link in `text`, gpa-owned: URLs, then the rules in order, each
/// keeping only what nothing before it claimed.
pub fn find(st: *State, gpa: Allocator, text: []const u8) Allocator.Error![]Span {
    var out: std.ArrayListUnmanaged(Span) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s.url);
        out.deinit(gpa);
    }
    var from: usize = 0;
    while (link_span.nextUrl(text, from)) |r| : (from = r.end) {
        const url = text[r.start..r.end];
        if (!link_span.openable(url)) continue;
        try out.append(gpa, .{ .start = r.start, .end = r.end, .url = try gpa.dupe(u8, url) });
    }
    for (st.rules.items) |*rule| {
        var at: usize = 0;
        while (at <= text.len) {
            const m = rule.re.find(text, at) orelse break;
            at = if (m.end > m.start) m.end else m.end + 1;
            if (m.end == m.start) continue;
            if (!standsAlone(text, m.start, m.end)) continue;
            if (overlaps(out.items, m.start, m.end)) continue;
            const url = try expand(gpa, rule.url, text, m);
            errdefer gpa.free(url);
            try out.append(gpa, .{ .start = m.start, .end = m.end, .url = url });
        }
    }
    std.mem.sort(Span, out.items, {}, byStart);
    return out.toOwnedSlice(gpa);
}

fn byStart(_: void, a: Span, b: Span) bool {
    return a.start < b.start;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// A match is a word of its own: no letter, digit or `_` either side.
pub fn standsAlone(text: []const u8, start: usize, end: usize) bool {
    if (start > 0 and isWordByte(text[start - 1])) return false;
    if (end < text.len and isWordByte(text[end])) return false;
    return true;
}

fn overlaps(spans: []const Span, start: usize, end: usize) bool {
    for (spans) |s| if (start < s.end and s.start < end) return true;
    return false;
}

/// The template with the match in it: `{0}` / `{match}` the whole of
/// it, `{1}`–`{9}` its groups (a group that took no part is empty),
/// each percent-encoded where a URL needs it.
pub fn expand(gpa: Allocator, template: []const u8, text: []const u8, m: regex.Match) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |close| {
            const name = template[i + 1 .. close];
            const group: ?usize = if (std.mem.eql(u8, name, "match"))
                0
            else if (name.len == 1 and std.ascii.isDigit(name[0]))
                name[0] - '0'
            else
                null;
            if (group) |g| {
                if (m.group(g)) |r| try encodeInto(gpa, &out, text[r.start..r.end]);
                i = close + 1;
                continue;
            }
        };
        try out.append(gpa, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn encodeInto(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try out.append(gpa, c),
        else => {
            var buf: [3]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable);
        },
    };
}

// ─── building the set ───────────────────────────────────────────────────

/// Rebuild the rules from the installed manifests and drop the cache.
/// A pattern that does not compile is a warning toast; a value still
/// missing is a note (the integration is not set up yet, which is not
/// a fault).
pub fn rebuild(app: *App) Allocator.Error!void {
    const st = &app.link_rules;
    const gpa = app.gpa;
    st.clearRules(gpa);
    st.clearCache(gpa);
    for (app.integrations.list) |*inst| {
        if (!inst.enabled()) continue;
        const m = inst.manifest;
        for (m.links, 0..) |l, k| {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const why = try addRule(st, gpa, arena, app, m, l);
            if (why) |w| {
                const line = try std.fmt.allocPrint(gpa, "{s}: links[{d}]: {s}", .{ m.id, k, w.text });
                errdefer gpa.free(line);
                if (w.warn) try app.toastLevel(.warn, "integrations: {s}", .{line});
                try st.notes.append(gpa, line);
            }
        }
    }
}

const Why = struct { text: []const u8, warn: bool };

fn addRule(st: *State, gpa: Allocator, arena: Allocator, app: *App, m: manifest_mod.Manifest, l: manifest_mod.manifest.Link) Allocator.Error!?Why {
    if (l.pattern.len == 0) return .{ .text = "an empty pattern", .warn = true };
    var url = std.mem.trim(u8, l.url, " \t");
    // Bind what the manifest can answer, one `{key}` at a time.
    var guard: usize = 0;
    while (manifest_mod.manifest.unboundLinkVar(url)) |name| : (guard += 1) {
        if (guard > 16) break;
        const value = varValue(app, m, name) orelse return .{
            .text = try std.fmt.allocPrint(arena, "{{{s}}} has no value — set it up (or `{s}`), then refresh", .{ name, envHint(m, name) orelse "reinstall the integration" }),
            .warn = false,
        };
        url = try manifest_mod.manifest.bindLinkVar(arena, url, name, std.mem.trimEnd(u8, value, "/"));
    }
    if (!link_span.openable(url)) return .{ .text = try std.fmt.allocPrint(arena, "`{s}` is not an http(s) address", .{url}), .warn = true };
    var re = regex.Regex.compile(l.pattern, .{ .dialect = .perl }) catch |err| return .{
        .text = try std.fmt.allocPrint(arena, "pattern `{s}`: {s}", .{ l.pattern, @errorName(err) }),
        .warn = true,
    };
    errdefer re.deinit();
    const owner = try gpa.dupe(u8, m.id);
    errdefer gpa.free(owner);
    const owned_url = try gpa.dupe(u8, url);
    errdefer gpa.free(owned_url);
    try st.rules.append(gpa, .{ .owner = owner, .re = re, .url = owned_url });
    return null;
}

/// `{name}`'s value: the manifest's setting of that key, else the
/// environment variable its auth field of that key falls back to.
fn varValue(app: *App, m: manifest_mod.Manifest, name: []const u8) ?[]const u8 {
    for (m.settings) |s| if (std.mem.eql(u8, s.key, name)) {
        const v = integrations.settingValue(app, m.id, s);
        if (v.len > 0) return v;
    };
    for (m.auth) |a| if (std.mem.eql(u8, a.key, name)) {
        const env = a.env_fallback orelse continue;
        const v = app.env.get(env) orelse continue;
        if (std.mem.trim(u8, v, " \t").len > 0) return std.mem.trim(u8, v, " \t");
    };
    return null;
}

fn envHint(m: manifest_mod.Manifest, name: []const u8) ?[]const u8 {
    for (m.auth) |a| if (std.mem.eql(u8, a.key, name)) if (a.env_fallback) |e| return e;
    return null;
}

// ─── a session's links, for its menu ────────────────────────────────────

/// One link a card shows: the words it is on and where it goes.
pub const Found = struct { text: []const u8, url: []const u8 };

/// Every distinct address in `texts`, first seen first, at most `max`,
/// on `arena` — the rows a session's menu lists (`Open ENG-123`).
pub fn collect(app: *App, arena: Allocator, texts: []const []const u8, max: usize) Allocator.Error![]Found {
    var out: std.ArrayListUnmanaged(Found) = .empty;
    for (texts) |text| {
        if (text.len == 0) continue;
        for (app.link_rules.spans(app.gpa, text)) |s| {
            if (out.items.len >= max) return out.items;
            var seen = false;
            for (out.items) |f| if (std.mem.eql(u8, f.url, s.url)) {
                seen = true;
            };
            if (seen) continue;
            try out.append(arena, .{ .text = try arena.dupe(u8, text[s.start..s.end]), .url = try arena.dupe(u8, s.url) });
        }
    }
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn testRule(st: *State, owner: []const u8, pattern: []const u8, url: []const u8) !void {
    try st.rules.append(t.allocator, .{
        .owner = try t.allocator.dupe(u8, owner),
        .re = try regex.Regex.compile(pattern, .{ .dialect = .perl }),
        .url = try t.allocator.dupe(u8, url),
    });
}

test "find: URLs alone when no rule is declared; a declared key links, whole words only; URLs win; the first rule wins" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    const text = "see https://example.com/x and ENG-123, not abcENG-9 or ENG-12a";
    // No integration declares a pattern: only the URL.
    {
        const got = try find(&st, t.allocator, text);
        defer freeSpans(t.allocator, got);
        try t.expectEqual(@as(usize, 1), got.len);
        try t.expectEqualStrings("https://example.com/x", got[0].url);
    }
    try testRule(&st, "acme", "[A-Z][A-Z0-9]+-\\d+", "https://acme.example/browse/{0}");
    try testRule(&st, "other", "ENG-\\d+", "https://other.example/{match}");
    const got = try find(&st, t.allocator, text);
    defer freeSpans(t.allocator, got);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("ENG-123", text[got[1].start..got[1].end]);
    // Both rules match `ENG-123`; the first declared keeps it.
    try t.expectEqualStrings("https://acme.example/browse/ENG-123", got[1].url);
    // A key inside a URL is the URL's.
    const in_url = try find(&st, t.allocator, "https://x.example/browse/ENG-7 done");
    defer freeSpans(t.allocator, in_url);
    try t.expectEqual(@as(usize, 1), in_url.len);
    try t.expectEqualStrings("https://x.example/browse/ENG-7", in_url[0].url);
    // A scheme that is not http(s) is not a link.
    const ftp = try find(&st, t.allocator, "ftp://files.example/a");
    defer freeSpans(t.allocator, ftp);
    try t.expectEqual(@as(usize, 0), ftp.len);
}

test "expand: the match and its groups go in percent-encoded; the cache answers a second ask without a search" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRule(&st, "acme", "([a-z]+)#(\\d+)", "https://git.example/{1}/pull/{2}?q={0}");
    const a = st.spans(t.allocator, "api#12 is up");
    try t.expectEqual(@as(usize, 1), a.len);
    try t.expectEqualStrings("https://git.example/api/pull/12?q=api%2312", a[0].url);
    // The same words again: the same slice, out of the cache.
    const b = st.spans(t.allocator, "api#12 is up");
    try t.expectEqual(a.ptr, b.ptr);
    try t.expectEqual(@as(u32, 1), st.cache.count());
    // A frame that does not paint it, once the cache is full, lets it go.
    st.beginFrame(t.allocator);
    st.beginFrame(t.allocator);
    try t.expectEqual(@as(u32, 1), st.cache.count()); // under cache_max: kept
}

test "rebuild: none installed links URLs only; two integrations, the first by the section's order wins; a value from the auth field's env var; a missing one is a note; a non-http address is refused" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    try rebuild(&app);
    try t.expectEqual(@as(usize, 0), app.link_rules.rules.items.len);
    const bare = app.link_rules.spans(app.gpa, "ENG-1 at https://example.com/x");
    try t.expectEqual(@as(usize, 1), bare.len);
    try t.expectEqualStrings("https://example.com/x", bare[0].url);
    var list = [_]integrations.Installed{
        .{ .manifest = .{ .id = "acme", .label = "Acme", .links = &.{.{ .pattern = "[A-Z]+-[0-9]+", .url = "https://acme.example/browse/{0}" }} }, .path = "", .source = .home, .binary_found = true, .slots = &.{} },
        .{
            .manifest = .{
                .id = "beta",
                .label = "Beta",
                .links = &.{
                    .{ .pattern = "ENG-[0-9]+", .url = "https://beta.example/{0}" },
                    .{ .pattern = "X[0-9]+", .url = "{site_url}/x/{0}" },
                    .{ .pattern = "Y[0-9]+", .url = "file:///{0}" },
                },
                .auth = &.{.{ .key = "site_url", .label = "Site", .kind = .url, .env_fallback = "BETA_SITE" }},
            },
            .path = "",
            .source = .home,
            .binary_found = true,
            .slots = &.{},
        },
    };
    app.integrations.list = &list;
    defer app.integrations.list = &.{};
    try rebuild(&app);
    // acme's, beta's ENG; beta's X waits for its site, its Y is refused.
    try t.expectEqual(@as(usize, 2), app.link_rules.rules.items.len);
    try t.expectEqual(@as(usize, 2), app.link_rules.notes.items.len);
    try t.expect(std.mem.indexOf(u8, app.link_rules.notes.items[0], "{site_url} has no value") != null);
    try t.expect(std.mem.indexOf(u8, app.link_rules.notes.items[0], "BETA_SITE") != null);
    try t.expect(std.mem.indexOf(u8, app.link_rules.notes.items[1], "not an http(s) address") != null);
    // Both match `ENG-5`: acme is listed first, so acme's page.
    const two = app.link_rules.spans(app.gpa, "see ENG-5");
    try t.expectEqual(@as(usize, 1), two.len);
    try t.expectEqualStrings("https://acme.example/browse/ENG-5", two[0].url);
    // The site arrives through the env var the auth field names; a
    // trailing slash does not double.
    try app.env.put("BETA_SITE", "https://beta.example/");
    try rebuild(&app);
    try t.expectEqual(@as(usize, 3), app.link_rules.rules.items.len);
    const x = app.link_rules.spans(app.gpa, "X42");
    try t.expectEqual(@as(usize, 1), x.len);
    try t.expectEqualStrings("https://beta.example/x/X42", x[0].url);
    // A disabled integration declares nothing.
    list[0].manifest.chip = .{ .enabled = false };
    try rebuild(&app);
    try t.expectEqualStrings("https://beta.example/ENG-5", app.link_rules.spans(app.gpa, "ENG-5")[0].url);
}
