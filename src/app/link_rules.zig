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
//!
//! A `.range` rule (`resolve = .range`) is for a number that names no
//! repo — `Pull request 5505`. Its integration publishes, over IPC
//! (`link-ranges`), which numbers each of its repos is using; group 1
//! of a match is the number, and the repos whose rows of the rule's
//! kind hold it fill `{repo}` (`resolveRange`). One repo: a link. More:
//! a link to the first — the workspace's own repo first — and its menu
//! lists each (`candidates`). None: no link.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const regex = @import("../regex/regex.zig");
const manifest_mod = @import("../bridge/manifest.zig");
const link_span = @import("../ui/link_span.zig");
const integrations = @import("integrations.zig");

pub const Span = link_span.Span;
const ipc_command = @import("../ipc/command.zig");
const remote_mod = @import("../git/remote.zig");

/// A published row's high, plus this: a number created since the
/// integration's last poll still resolves to the repo just under it.
pub const range_slack: u64 = 50;

/// One row of an integration's range table, gpa-owned.
pub const RangeRow = struct { repo: []u8, kind: []u8, low: u64, high: u64 };

/// One repo a `.range` link could mean: the menu's `Open in <repo>`.
pub const Candidate = struct { repo: []const u8, url: []const u8 };

/// One integration's pattern, compiled, with its address template's
/// values bound.
pub const Rule = struct {
    /// The manifest id, gpa-owned.
    owner: []u8,
    re: regex.Regex,
    /// The template, gpa-owned: only `{0}`–`{9}` / `{match}` left
    /// (and `{repo}`, on a `.range` rule).
    url: []u8,
    /// `.range`: the row kind the number is looked up in, gpa-owned;
    /// empty on a literal rule.
    kind: []u8 = &.{},
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
    /// Bumped each time the rules are rebuilt: a cache of its own (a
    /// terminal pane's rows) drops what it found under an older set.
    gen: u32 = 0,
    /// A terminal pane left a line unmatched because it was still
    /// moving (`pty_links.zig`): the next frame should come even with
    /// nothing else to show, so the line links once it stops.
    pending: bool = false,
    /// Each integration's latest range table (`link-ranges`), by
    /// manifest id; keys and rows gpa-owned.
    tables: std.StringHashMapUnmanaged([]RangeRow) = .empty,
    /// A `.range` link that could mean more than one repo: its address
    /// (the first candidate's) → every candidate, for its menu. Filled
    /// as links are found, emptied with the cache; gpa-owned.
    alts: std.StringHashMapUnmanaged([]Candidate) = .empty,
    /// The workspace's own repo (`acme/widget`, off its git remote) —
    /// the candidate a `.range` link opens first. gpa-owned.
    home: []u8 = &.{},
    gpa: Allocator = undefined,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.clearRules(gpa);
        self.rules.deinit(gpa);
        self.notes.deinit(gpa);
        self.clearCache(gpa);
        self.cache.deinit(gpa);
        self.alts.deinit(gpa);
        var it = self.tables.iterator();
        while (it.next()) |e| {
            freeRows(gpa, e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        self.tables.deinit(gpa);
        gpa.free(self.home);
    }

    fn clearRules(self: *State, gpa: Allocator) void {
        for (self.rules.items) |*r| {
            r.re.deinit();
            gpa.free(r.owner);
            gpa.free(r.url);
            gpa.free(r.kind);
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
        var at = self.alts.iterator();
        while (at.next()) |e| {
            freeCandidates(gpa, e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        self.alts.clearRetainingCapacity();
    }

    /// Every repo the link to `url` could mean, the one it opens first;
    /// empty for a link that means one thing.
    pub fn candidates(self: *const State, url: []const u8) []const Candidate {
        return self.alts.get(url) orelse &.{};
    }

    /// Replace integration `owner`'s range table and drop what was
    /// found under the old one.
    pub fn setRanges(self: *State, gpa: Allocator, owner: []const u8, rows: []const ipc_command.LinkRange) Allocator.Error!void {
        const owned = try gpa.alloc(RangeRow, rows.len);
        var n: usize = 0;
        errdefer {
            freeRows(gpa, owned[0..n]);
        }
        for (rows) |r| {
            const repo = try gpa.dupe(u8, r.repo);
            errdefer gpa.free(repo);
            owned[n] = .{ .repo = repo, .kind = try gpa.dupe(u8, r.kind), .low = r.low, .high = r.high };
            n += 1;
        }
        const gop = try self.tables.getOrPut(gpa, owner);
        if (gop.found_existing) {
            freeRows(gpa, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, owner) catch |err| {
                self.tables.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = owned;
        self.clearCache(gpa);
        self.gen +%= 1;
    }

    /// Follow the workspace's remote: a new home repo re-finds every
    /// text, since which candidate opens first may have changed.
    pub fn setHome(self: *State, gpa: Allocator, remote: []const u8) void {
        const path = if (remote_mod.parseRemote(remote)) |r| r.path else "";
        if (std.mem.eql(u8, path, self.home)) return;
        const owned = gpa.dupe(u8, path) catch return;
        gpa.free(self.home);
        self.home = owned;
        if (self.tables.count() > 0) {
            self.clearCache(gpa);
            self.gen +%= 1;
        }
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

fn freeRows(gpa: Allocator, rows: []RangeRow) void {
    for (rows) |r| {
        gpa.free(r.repo);
        gpa.free(r.kind);
    }
    gpa.free(rows);
}

fn freeCandidates(gpa: Allocator, cs: []Candidate) void {
    for (cs) |c| {
        gpa.free(c.repo);
        gpa.free(c.url);
    }
    gpa.free(cs);
}

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
    app.link_rules.setHome(app.gpa, app.git.remote);
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
            if (rule.kind.len > 0) {
                const url = try rangeUrl(st, gpa, rule, text, m) orelse continue;
                errdefer gpa.free(url);
                try out.append(gpa, .{ .start = m.start, .end = m.end, .url = url });
                continue;
            }
            const url = try expand(gpa, rule.url, text, m);
            errdefer gpa.free(url);
            try out.append(gpa, .{ .start = m.start, .end = m.end, .url = url });
        }
    }
    std.mem.sort(Span, out.items, {}, byStart);
    return out.toOwnedSlice(gpa);
}

/// A `.range` match's address: its number's repos (`resolveRange`), the
/// first filling `{repo}`; null when no repo holds it. Several record
/// every candidate under the address, for its menu.
fn rangeUrl(st: *State, gpa: Allocator, rule: *const Rule, text: []const u8, m: regex.Match) Allocator.Error!?[]u8 {
    const g = m.group(1) orelse m.group(0).?;
    const n = std.fmt.parseInt(u64, text[g.start..g.end], 10) catch return null;
    const rows = st.tables.get(rule.owner) orelse return null;
    var pick: [max_candidates]usize = undefined;
    const got = resolveRange(rows, rule.kind, n, st.home, &pick);
    if (got.len == 0) return null;
    const expanded = try expand(gpa, rule.url, text, m);
    defer gpa.free(expanded);
    const first = try std.mem.replaceOwned(u8, gpa, expanded, "{" ++ manifest_mod.manifest.range_repo_var ++ "}", rows[got[0]].repo);
    if (got.len == 1 or st.alts.contains(first)) return first;
    errdefer gpa.free(first);
    const cs = try gpa.alloc(Candidate, got.len);
    var made: usize = 0;
    errdefer freeCandidates(gpa, cs[0..made]);
    for (got) |i| {
        const repo = try gpa.dupe(u8, rows[i].repo);
        errdefer gpa.free(repo);
        cs[made] = .{ .repo = repo, .url = try std.mem.replaceOwned(u8, gpa, expanded, "{" ++ manifest_mod.manifest.range_repo_var ++ "}", rows[i].repo) };
        made += 1;
    }
    const key = try gpa.dupe(u8, first);
    errdefer gpa.free(key);
    try st.alts.put(gpa, key, cs);
    return first;
}

/// At most this many repos for one number; past it the menu would not
/// fit, and a number that many repos share says little anyway.
pub const max_candidates = 8;

/// The rows of `kind` whose `low`..`high` hold `n`, the `home` repo
/// first, then in the table's order; failing any, the rows `n` is at
/// most `range_slack` past the high of (a number made since the poll).
/// Indices into `rows`, in `buf`.
pub fn resolveRange(rows: []const RangeRow, kind: []const u8, n: u64, home: []const u8, buf: *[max_candidates]usize) []const usize {
    var len: usize = 0;
    for ([_]bool{ false, true }) |slack| {
        // The home repo's row first, then the rest in order.
        for ([_]bool{ true, false }) |want_home| for (rows, 0..) |r, i| {
            if (len == buf.len) break;
            if (!std.mem.eql(u8, r.kind, kind)) continue;
            const is_home = home.len > 0 and std.ascii.eqlIgnoreCase(r.repo, home);
            if (is_home != want_home) continue;
            const holds = if (slack) n > r.high and n - r.high <= range_slack else n >= r.low and n <= r.high;
            if (!holds) continue;
            buf[len] = i;
            len += 1;
        };
        if (len > 0) break;
    }
    return buf[0..len];
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
    st.gen +%= 1;
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
    const range = l.resolve == .range;
    const repo_var = manifest_mod.manifest.range_repo_var;
    if (range and l.ranges.len == 0) return .{ .text = "a range link names no `ranges` kind", .warn = true };
    if (range and std.mem.indexOf(u8, url, "{" ++ repo_var ++ "}") == null) return .{ .text = "a range link's url has no {repo}", .warn = true };
    // Bind what the manifest can answer, one `{key}` at a time.
    var guard: usize = 0;
    while (manifest_mod.manifest.unboundLinkVarExcept(url, if (range) repo_var else "")) |name| : (guard += 1) {
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
    const kind = try gpa.dupe(u8, if (range) l.ranges else "");
    errdefer gpa.free(kind);
    try st.rules.append(gpa, .{ .owner = owner, .re = re, .url = owned_url, .kind = kind });
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

/// The link covering byte `col` of `text` — a URL or a declared key —
/// through the cache; null off every link. What a surface that finds
/// its own spot (an editor's cursor, a terminal cell) asks.
pub fn spanAt(app: *App, text: []const u8, col: usize) ?Span {
    for (app.link_rules.spans(app.gpa, text)) |s| {
        if (col >= s.start and col < s.end) return s;
        if (s.start > col) return null;
    }
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

test "a forge's <repo>#<n>: the repo's PR in the workspace bound from the env; a bare #n, a path's and another owner's do not link; <workspace>/<repo>#n does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    // The rule the Bitbucket integration declares, and the one its
    // `--install` adds for a configured workspace (here `acme`).
    var list = [_]integrations.Installed{.{
        .manifest = .{
            .id = "forge",
            .label = "Forge",
            .links = &.{
                .{ .pattern = "(?<![/\\w.-])(acme)/([A-Za-z0-9_.-]+)#(\\d+)", .url = "https://bitbucket.org/{1}/{2}/pull-requests/{3}" },
                .{ .pattern = "(?<![/\\w.-])([A-Za-z0-9_.-]+)#(\\d+)", .url = "https://bitbucket.org/{workspace}/{1}/pull-requests/{2}" },
            },
            .auth = &.{.{ .key = "workspace", .label = "Workspace", .kind = .text, .env_fallback = "FORGE_WORKSPACE" }},
        },
        .path = "",
        .source = .home,
        .binary_found = true,
        .slots = &.{},
    }};
    app.integrations.list = &list;
    defer app.integrations.list = &.{};
    _ = app.env.swapRemove("FORGE_WORKSPACE");
    try rebuild(&app);
    // No workspace yet: the explicit form only.
    try t.expectEqual(@as(usize, 1), app.link_rules.rules.items.len);
    try app.env.put("FORGE_WORKSPACE", "acme");
    try rebuild(&app);
    const text = "see widget#7, acme/widget#42, #9, src/foo#3 and other/widget#5";
    const got = app.link_rules.spans(app.gpa, text);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("widget#7", text[got[0].start..got[0].end]);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/7", got[0].url);
    try t.expectEqualStrings("acme/widget#42", text[got[1].start..got[1].end]);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/42", got[1].url);
}

// ─── a bare number, by the published ranges ────────────────────────────

fn testRangeRule(st: *State, pattern: []const u8, url: []const u8, kind: []const u8) !void {
    try st.rules.append(t.allocator, .{
        .owner = try t.allocator.dupe(u8, "forge"),
        .re = try regex.Regex.compile(pattern, .{ .dialect = .perl }),
        .url = try t.allocator.dupe(u8, url),
        .kind = try t.allocator.dupe(u8, kind),
    });
}

/// The fake forge's table: widget's PRs 5490–7130, gadget's 7120–7166
/// (7120–7130 shared), each one's pipelines elsewhere.
fn testRanges(st: *State) !void {
    try testRangeRule(st, "(?i)\\bpull request #?(\\d+)", "https://bitbucket.org/{repo}/pull-requests/{1}", "pr");
    try testRangeRule(st, "(?i)\\bPR #?(\\d+)", "https://bitbucket.org/{repo}/pull-requests/{1}", "pr");
    try testRangeRule(st, "(?i)\\bpipeline #?(\\d+)", "https://bitbucket.org/{repo}/pipelines/results/{1}", "pipeline");
    try st.setRanges(t.allocator, "forge", &.{
        .{ .repo = "acme/widget", .kind = "pr", .low = 5490, .high = 7130 },
        .{ .repo = "acme/gadget", .kind = "pr", .low = 7120, .high = 7166 },
        .{ .repo = "acme/widget", .kind = "pipeline", .low = 10540, .high = 10554 },
        .{ .repo = "acme/gadget", .kind = "pipeline", .low = 3300, .high = 3321 },
    });
}

test "range: a number one repo's range holds links to that repo's page; its kind's rows only" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRanges(&st);
    const text = "Pull request 5505 announcement";
    const got = st.spans(t.allocator, text);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("Pull request 5505", text[got[0].start..got[0].end]);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/5505", got[0].url);
    // One candidate: the menu has nothing more to list.
    try t.expectEqual(@as(usize, 0), st.candidates(got[0].url).len);
    // `pipeline 3310` is gadget's pipeline, though gadget's PRs are elsewhere.
    const p = st.spans(t.allocator, "see pipeline #3310 fail");
    try t.expectEqual(@as(usize, 1), p.len);
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pipelines/results/3310", p[0].url);
    // A PR's number is not a pipeline's.
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "pipeline 5505").len);
    // Case does not matter; `PR #n` is the same thing.
    const pr = st.spans(t.allocator, "pr #5600 landed");
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/5600", pr[0].url);
}

test "range: a number several repos hold links to the first, and lists each for the menu" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRanges(&st);
    const got = st.spans(t.allocator, "PR 7125 is up");
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/7125", got[0].url);
    const cs = st.candidates(got[0].url);
    try t.expectEqual(@as(usize, 2), cs.len);
    try t.expectEqualStrings("acme/widget", cs[0].repo);
    try t.expectEqualStrings("acme/gadget", cs[1].repo);
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pull-requests/7125", cs[1].url);
}

test "range: a number no repo holds, or one with no table yet, does not link" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRangeRule(&st, "(?i)\\bPR #?(\\d+)", "https://bitbucket.org/{repo}/pull-requests/{1}", "pr");
    // No table published yet.
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "PR 5505").len);
    try st.setRanges(t.allocator, "forge", &.{.{ .repo = "acme/widget", .kind = "pr", .low = 5490, .high = 7130 }});
    // The new table re-finds the same words.
    try t.expectEqual(@as(usize, 1), st.spans(t.allocator, "PR 5505").len);
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "PR 5000").len);
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "PR 9000").len);
    // Another integration's table is not this rule's.
    try st.setRanges(t.allocator, "forge", &.{});
    try st.setRanges(t.allocator, "other", &.{.{ .repo = "acme/widget", .kind = "pr", .low = 1, .high = 9999 }});
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "PR 5505").len);
}

test "range: the workspace's own repo opens first" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRanges(&st);
    st.setHome(t.allocator, "git@bitbucket.org:acme/gadget.git");
    const got = st.spans(t.allocator, "PR 7125 is up");
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pull-requests/7125", got[0].url);
    const cs = st.candidates(got[0].url);
    try t.expectEqual(@as(usize, 2), cs.len);
    try t.expectEqualStrings("acme/gadget", cs[0].repo);
    try t.expectEqualStrings("acme/widget", cs[1].repo);
    // Home only orders: a number only widget holds is still widget's.
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/5505", st.spans(t.allocator, "PR 5505")[0].url);
}

test "range: just past a high is that repo's (a number made since the poll); a range that holds it outright wins" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try testRanges(&st);
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pull-requests/7200", st.spans(t.allocator, "PR 7200")[0].url);
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pull-requests/7216", st.spans(t.allocator, "PR 7216")[0].url);
    try t.expectEqual(@as(usize, 0), st.spans(t.allocator, "PR 7217").len);
    // 7140 is within gadget outright and within widget's slack: gadget.
    const got = st.spans(t.allocator, "PR 7140");
    try t.expectEqualStrings("https://bitbucket.org/acme/gadget/pull-requests/7140", got[0].url);
    try t.expectEqual(@as(usize, 0), st.candidates(got[0].url).len);
}

test "rebuild: a range link keeps {repo} for the match, binds the rest, and is refused without a kind or a {repo}" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    var list = [_]integrations.Installed{.{
        .manifest = .{
            .id = "forge",
            .label = "Forge",
            .links = &.{
                .{ .pattern = "(?i)\\bPR #?(\\d+)", .url = "https://bitbucket.org/{repo}/pull-requests/{1}", .resolve = .range, .ranges = "pr" },
                .{ .pattern = "(?i)\\bpipeline (\\d+)", .url = "https://bitbucket.org/{repo}/pipelines/{1}", .resolve = .range },
                .{ .pattern = "(?i)\\bbuild (\\d+)", .url = "https://bitbucket.org/x/{1}", .resolve = .range, .ranges = "build" },
            },
        },
        .path = "",
        .source = .home,
        .binary_found = true,
        .slots = &.{},
    }};
    app.integrations.list = &list;
    defer app.integrations.list = &.{};
    try rebuild(&app);
    try t.expectEqual(@as(usize, 1), app.link_rules.rules.items.len);
    try t.expectEqual(@as(usize, 2), app.link_rules.notes.items.len);
    try app.link_rules.setRanges(app.gpa, "forge", &.{.{ .repo = "acme/widget", .kind = "pr", .low = 5490, .high = 5512 }});
    const got = app.link_rules.spans(app.gpa, "Pull request 1 and PR 5505");
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/5505", got[0].url);
    // A rebuild keeps the table: it is the integration's, not the manifest's.
    try rebuild(&app);
    try t.expectEqual(@as(usize, 1), app.link_rules.spans(app.gpa, "PR 5505").len);
}
