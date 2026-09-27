//! Snippets: a trigger word before the cursor expands into a body with
//! tab stops. The table is keyed by scope (a language key such as `rs`,
//! or `global`) then trigger; `config.snippets` (at launch and on every
//! reload) and the `.test` `snippet` directive feed it.
//!
//! A body is the LSP / VS Code snippet grammar (`parseWith`): `$1` …
//! for the stops, `$0` for where the cursor lands last,
//! `${1:placeholder}` for a stop with default text (selected when
//! reached so typing replaces it) that may nest further stops, a repeat
//! of a number for a mirror that follows the stop, `${1|a,b|}` for a
//! choice, `$TM_FILENAME` and the other variables, `\$` for a literal
//! dollar. After an expansion with more than one stop, or with mirrors,
//! a session is open: Tab goes to the next stop, Shift+Tab back
//! (landing at the end of what was typed there), Esc ends it. Stops
//! track the text through the editor's edit log — an insert before a
//! stop moves it, typing at a stop leaves it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const hl = @import("highlight");

pub const table = .{
    .@"snippet.expand" = &expandCmd,
    .@"snippet.next_placeholder" = &nextCmd,
    .@"snippet.prev_placeholder" = &prevCmd,
    .@"snippet.pick" = &pickCmd,
    .@"snippet.pick_all" = &pickAllCmd,
};

pub const Stop = struct {
    pos: usize,
    /// Length of the default text at `pos`, selected when the stop is
    /// reached for the first time.
    default_len: usize = 0,
    /// Where the cursor was when the stop was left; a return lands here.
    exit: ?usize = null,
    /// Where the stop's text ends: `pos + default_len` at expansion, then
    /// moving with what is typed there — what its mirrors copy.
    end: usize = 0,
    /// Its mirrors, `mirrors[mirror_lo..mirror_hi]` of the parse or the
    /// session.
    mirror_lo: u32 = 0,
    mirror_hi: u32 = 0,
};

/// A repeat of a stop's number (`let ${1:name} = …; use($1)`): it shows
/// whatever is typed at the stop, live.
pub const Mirror = struct { pos: usize, end: usize };

/// The parsed body: the text to insert, the stops as offsets into it —
/// `$1`, `$2`, … in order, then `$0` — and their mirrors.
pub const Parsed = struct {
    text: []u8,
    stops: []Stop,
    mirrors: []Mirror,

    pub fn deinit(p: *Parsed, gpa: Allocator) void {
        gpa.free(p.text);
        gpa.free(p.stops);
        gpa.free(p.mirrors);
    }
};

/// What the snippet variables expand to at the insertion point. A
/// variable with no value (no file, an unknown name) takes its default,
/// or nothing — never the `$NAME` markup.
pub const Vars = struct {
    path: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    /// 0-based line of the insertion point.
    line: usize = 0,
    current_line: []const u8 = "",
    word: []const u8 = "",
    selected: []const u8 = "",
    clipboard: []const u8 = "",
    /// Seconds since the epoch; the date variables read it as UTC. Null
    /// leaves them to their defaults.
    now_s: ?i64 = null,

    /// `name`'s value, formatted into `buf` when it is a number. Null for
    /// a name that is not a variable, or one with no value here.
    pub fn value(v: *const Vars, name: []const u8, buf: []u8) ?[]const u8 {
        const eql = std.mem.eql;
        if (eql(u8, name, "TM_FILENAME")) return if (v.path) |p| std.fs.path.basename(p) else null;
        if (eql(u8, name, "TM_FILENAME_BASE")) {
            const p = v.path orelse return null;
            const base = std.fs.path.basename(p);
            const ext = std.fs.path.extension(base);
            return base[0 .. base.len - ext.len];
        }
        if (eql(u8, name, "TM_FILEPATH")) return v.path;
        if (eql(u8, name, "TM_DIRECTORY")) return if (v.path) |p| std.fs.path.dirname(p) else null;
        if (eql(u8, name, "RELATIVE_FILEPATH")) {
            const p = v.path orelse return null;
            const ws = v.workspace orelse return p;
            if (std.mem.startsWith(u8, p, ws) and p.len > ws.len and std.fs.path.isSep(p[ws.len])) return p[ws.len + 1 ..];
            return p;
        }
        if (eql(u8, name, "WORKSPACE_FOLDER")) return v.workspace;
        if (eql(u8, name, "WORKSPACE_NAME")) return if (v.workspace) |w| std.fs.path.basename(w) else null;
        if (eql(u8, name, "TM_LINE_NUMBER")) return std.fmt.bufPrint(buf, "{d}", .{v.line + 1}) catch null;
        if (eql(u8, name, "TM_LINE_INDEX")) return std.fmt.bufPrint(buf, "{d}", .{v.line}) catch null;
        if (eql(u8, name, "TM_CURRENT_LINE")) return v.current_line;
        if (eql(u8, name, "TM_CURRENT_WORD")) return v.word;
        if (eql(u8, name, "TM_SELECTED_TEXT")) return v.selected;
        if (eql(u8, name, "CLIPBOARD")) return v.clipboard;
        const now = v.now_s orelse return null;
        const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now, 0)) };
        const day = secs.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();
        const ds = secs.getDaySeconds();
        if (eql(u8, name, "CURRENT_YEAR")) return std.fmt.bufPrint(buf, "{d}", .{day.year}) catch null;
        if (eql(u8, name, "CURRENT_YEAR_SHORT")) return std.fmt.bufPrint(buf, "{d:0>2}", .{day.year % 100}) catch null;
        if (eql(u8, name, "CURRENT_MONTH")) return std.fmt.bufPrint(buf, "{d:0>2}", .{md.month.numeric()}) catch null;
        if (eql(u8, name, "CURRENT_DATE")) return std.fmt.bufPrint(buf, "{d:0>2}", .{md.day_index + 1}) catch null;
        if (eql(u8, name, "CURRENT_HOUR")) return std.fmt.bufPrint(buf, "{d:0>2}", .{ds.getHoursIntoDay()}) catch null;
        if (eql(u8, name, "CURRENT_MINUTE")) return std.fmt.bufPrint(buf, "{d:0>2}", .{ds.getMinutesIntoHour()}) catch null;
        if (eql(u8, name, "CURRENT_SECOND")) return std.fmt.bufPrint(buf, "{d:0>2}", .{ds.getSecondsIntoMinute()}) catch null;
        if (eql(u8, name, "CURRENT_SECONDS_UNIX")) return std.fmt.bufPrint(buf, "{d}", .{now}) catch null;
        return null;
    }
};

/// A body with no variables to resolve (the tests, the picker detail).
pub fn parse(gpa: Allocator, raw: []const u8) Allocator.Error!Parsed {
    return parseWith(gpa, raw, &.{});
}

/// The LSP / VS Code snippet grammar: `$1` / `${1}` stops, `${1:default}`
/// placeholders whose default may hold further stops and variables,
/// `${1|one,two|}` choices (the first is inserted and selected), repeats
/// of a number as mirrors of its stop, `$NAME` / `${NAME}` /
/// `${NAME:default}` variables (a `${NAME/re/fmt/}` transform is dropped:
/// the value goes in as it is), and `\$`, `\}`, `\\` escapes. Markup that
/// is not well formed is text.
pub fn parseWith(gpa: Allocator, raw: []const u8, vars: *const Vars) Allocator.Error!Parsed {
    var p: Parser = .{ .gpa = gpa, .raw = raw, .vars = vars };
    defer p.occs.deinit(gpa);
    errdefer p.text.deinit(gpa);
    try p.seq(false);
    try p.fillMirrors();
    // Numbers ascending, `$0` last.
    var nums: std.ArrayListUnmanaged(u32) = .empty;
    defer nums.deinit(gpa);
    for (p.occs.items) |o| if (std.mem.indexOfScalar(u32, nums.items, o.n) == null) try nums.append(gpa, o.n);
    std.mem.sort(u32, nums.items, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            if (a == 0) return false;
            if (b == 0) return true;
            return a < b;
        }
    }.lt);
    var stops: std.ArrayListUnmanaged(Stop) = .empty;
    errdefer stops.deinit(gpa);
    var mirrors: std.ArrayListUnmanaged(Mirror) = .empty;
    errdefer mirrors.deinit(gpa);
    for (nums.items) |n| {
        const prim = p.primary(n);
        const o = p.occs.items[prim];
        const lo: u32 = @intCast(mirrors.items.len);
        for (p.occs.items, 0..) |m, mi| if (m.n == n and mi != prim) try mirrors.append(gpa, .{ .pos = m.pos, .end = m.end });
        try stops.append(gpa, .{ .pos = o.pos, .default_len = o.end - o.pos, .end = o.end, .mirror_lo = lo, .mirror_hi = @intCast(mirrors.items.len) });
    }
    return .{ .text = try p.text.toOwnedSlice(gpa), .stops = try stops.toOwnedSlice(gpa), .mirrors = try mirrors.toOwnedSlice(gpa) };
}

const Parser = struct {
    gpa: Allocator,
    raw: []const u8,
    vars: *const Vars,
    i: usize = 0,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// Every stop occurrence, in document order.
    occs: std.ArrayListUnmanaged(Occ) = .empty,

    const Occ = struct { n: u32, pos: usize, end: usize, has_default: bool };

    /// Text and markup up to the end, or — `nested` — up to the `}`
    /// that closes the enclosing placeholder (left for the caller).
    fn seq(p: *Parser, nested: bool) Allocator.Error!void {
        while (p.i < p.raw.len) {
            const c = p.raw[p.i];
            if (c == '\\' and p.i + 1 < p.raw.len and (p.raw[p.i + 1] == '$' or p.raw[p.i + 1] == '}' or p.raw[p.i + 1] == '\\')) {
                try p.text.append(p.gpa, p.raw[p.i + 1]);
                p.i += 2;
                continue;
            }
            if (nested and c == '}') return;
            if (c == '$' and try p.dollar()) continue;
            try p.text.append(p.gpa, c);
            p.i += 1;
        }
    }

    /// The markup at `raw[i] == '$'`; false (nothing consumed) when it
    /// is not markup.
    fn dollar(p: *Parser) Allocator.Error!bool {
        const r = p.raw;
        const at = p.i;
        if (at + 1 >= r.len) return false;
        var buf: [32]u8 = undefined;
        if (std.ascii.isDigit(r[at + 1])) {
            const k = digitsEnd(r, at + 1);
            const n = std.fmt.parseInt(u32, r[at + 1 .. k], 10) catch return false;
            try p.occs.append(p.gpa, .{ .n = n, .pos = p.text.items.len, .end = p.text.items.len, .has_default = false });
            p.i = k;
            return true;
        }
        if (isVarStart(r[at + 1])) {
            const k = varEnd(r, at + 1);
            try p.text.appendSlice(p.gpa, p.vars.value(r[at + 1 .. k], &buf) orelse "");
            p.i = k;
            return true;
        }
        if (r[at + 1] != '{' or at + 2 >= r.len) return false;
        const j = at + 2;
        if (std.ascii.isDigit(r[j])) {
            const k = digitsEnd(r, j);
            if (k >= r.len) return false;
            const n = std.fmt.parseInt(u32, r[j..k], 10) catch return false;
            switch (r[k]) {
                '}' => {
                    try p.occs.append(p.gpa, .{ .n = n, .pos = p.text.items.len, .end = p.text.items.len, .has_default = false });
                    p.i = k + 1;
                    return true;
                },
                ':' => {
                    const idx = p.occs.items.len;
                    try p.occs.append(p.gpa, .{ .n = n, .pos = p.text.items.len, .end = p.text.items.len, .has_default = true });
                    p.i = k + 1;
                    try p.seq(true);
                    if (p.i < r.len) p.i += 1; // the closing `}`
                    p.occs.items[idx].end = p.text.items.len;
                    return true;
                },
                '|' => {
                    const first = choiceFirst(p.gpa, r, k + 1) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NotAChoice => return false,
                    };
                    defer p.gpa.free(first.text);
                    const pos = p.text.items.len;
                    try p.text.appendSlice(p.gpa, first.text);
                    try p.occs.append(p.gpa, .{ .n = n, .pos = pos, .end = p.text.items.len, .has_default = true });
                    p.i = first.next;
                    return true;
                },
                else => return false,
            }
        }
        if (!isVarStart(r[j])) return false;
        const k = varEnd(r, j);
        if (k >= r.len) return false;
        const val = p.vars.value(r[j..k], &buf);
        switch (r[k]) {
            '}' => {
                try p.text.appendSlice(p.gpa, val orelse "");
                p.i = k + 1;
                return true;
            },
            ':' => {
                p.i = k + 1;
                const mark_text = p.text.items.len;
                const mark_occ = p.occs.items.len;
                try p.seq(true);
                if (p.i < r.len) p.i += 1;
                // A variable with a value drops its default, stops and all.
                if (val) |v| {
                    p.text.shrinkRetainingCapacity(mark_text);
                    p.occs.shrinkRetainingCapacity(mark_occ);
                    try p.text.appendSlice(p.gpa, v);
                }
                return true;
            },
            '/' => {
                // `${NAME/regex/format/options}`: past the three parts.
                // The format may hold `${1:/upcase}`: braces nest.
                var q = k + 1;
                var slashes: usize = 1;
                var depth: usize = 0;
                while (q < r.len) : (q += 1) {
                    switch (r[q]) {
                        '\\' => q += 1,
                        '{' => depth += 1,
                        '/' => if (depth == 0) {
                            slashes += 1;
                        },
                        '}' => {
                            if (depth == 0 and slashes >= 3) break;
                            depth -|= 1;
                        },
                        else => {},
                    }
                }
                if (q >= r.len) return false;
                try p.text.appendSlice(p.gpa, val orelse "");
                p.i = q + 1;
                return true;
            },
            else => return false,
        }
    }

    /// The occurrence of `n` the cursor goes to: the first with a
    /// default, else the first.
    fn primary(p: *const Parser, n: u32) usize {
        var first: ?usize = null;
        for (p.occs.items, 0..) |o, i| if (o.n == n) {
            if (o.has_default) return i;
            if (first == null) first = i;
        };
        return first.?;
    }

    /// Every mirror starts out showing its stop's default. A mirror can
    /// sit inside another stop's default, so this runs until nothing
    /// changes (a few rounds at most).
    fn fillMirrors(p: *Parser) Allocator.Error!void {
        var round: usize = 0;
        while (round < 4) : (round += 1) {
            var changed = false;
            for (0..p.occs.items.len) |mi| {
                const m = p.occs.items[mi];
                const prim = p.primary(m.n);
                if (prim == mi) continue;
                const src = p.occs.items[prim];
                const want = try p.gpa.dupe(u8, p.text.items[src.pos..src.end]);
                defer p.gpa.free(want);
                if (std.mem.eql(u8, p.text.items[m.pos..m.end], want)) continue;
                try p.replace(mi, want);
                changed = true;
            }
            if (!changed) return;
        }
    }

    /// Occurrence `mi`'s text becomes `with`; every offset past it moves.
    fn replace(p: *Parser, mi: usize, with: []const u8) Allocator.Error!void {
        const m = p.occs.items[mi];
        try p.text.replaceRange(p.gpa, m.pos, m.end - m.pos, with);
        const new_end = m.pos + with.len;
        for (p.occs.items, 0..) |*o, oi| {
            if (oi == mi) {
                o.end = new_end;
                continue;
            }
            o.pos = shift(o.pos, m.pos, m.end, new_end);
            o.end = shiftEnd(o.end, m.pos, m.end, new_end);
        }
    }
};

fn digitsEnd(r: []const u8, from: usize) usize {
    var k = from;
    while (k < r.len and std.ascii.isDigit(r[k])) k += 1;
    return k;
}

fn isVarStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn varEnd(r: []const u8, from: usize) usize {
    var k = from;
    while (k < r.len and (std.ascii.isAlphanumeric(r[k]) or r[k] == '_')) k += 1;
    return k;
}

/// `one,two|}` from `from`: the first option, unescaped (`\,` `\|`
/// `\\`), and where the markup ends.
fn choiceFirst(gpa: Allocator, r: []const u8, from: usize) (Allocator.Error || error{NotAChoice})!struct { text: []u8, next: usize } {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var q = from;
    var in_first = true;
    while (q < r.len) : (q += 1) {
        const c = r[q];
        if (c == '\\' and q + 1 < r.len) {
            q += 1;
            if (in_first) try out.append(gpa, r[q]);
            continue;
        }
        if (c == '|') {
            if (q + 1 < r.len and r[q + 1] == '}') return .{ .text = try out.toOwnedSlice(gpa), .next = q + 2 };
            break;
        }
        if (c == ',') {
            in_first = false;
            continue;
        }
        if (in_first) try out.append(gpa, c);
    }
    return error.NotAChoice;
}

pub const Session = struct {
    pane: PaneId,
    /// Absolute byte positions.
    stops: []Stop,
    /// The stops' mirrors, absolute; a stop's are `mirrors[mirror_lo..mirror_hi]`.
    mirrors: []Mirror = &.{},
    current: usize,
    /// The edit-log seq the stops are current at.
    seen_seq: u64,
};

/// scope → trigger → body, every key and body owned.
const Table = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]u8));

fn freeTable(gpa: Allocator, t: *Table) void {
    var it = t.iterator();
    while (it.next()) |e| {
        var inner = e.value_ptr.*;
        var it2 = inner.iterator();
        while (it2.next()) |x| {
            gpa.free(x.key_ptr.*);
            gpa.free(x.value_ptr.*);
        }
        inner.deinit(gpa);
        gpa.free(e.key_ptr.*);
    }
    t.deinit(gpa);
    t.* = .empty;
}

/// Add (or replace) `trigger` in `scope` of `t`; `scope` is taken as
/// it is (the caller normalized it).
fn put(gpa: Allocator, t: *Table, scope: []const u8, trigger: []const u8, body: []const u8) Allocator.Error!void {
    const gop = try t.getOrPut(gpa, scope);
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, scope) catch |err| {
            t.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = .empty;
    }
    const owned = try gpa.dupe(u8, body);
    errdefer gpa.free(owned);
    const inner = gop.value_ptr;
    if (inner.getEntry(trigger)) |e| {
        gpa.free(e.value_ptr.*);
        e.value_ptr.* = owned;
        return;
    }
    const key = try gpa.dupe(u8, trigger);
    errdefer gpa.free(key);
    try inner.put(gpa, key, owned);
}

pub const State = struct {
    gpa: Allocator,
    /// What lookups and the picker read: the config's snippets with the
    /// seeded ones over them. Scopes are normalized (`normalizeScope`).
    scopes: Table = .empty,
    /// The snippets added at run time (`seed`: the `.test` `snippet`
    /// directive), kept apart so a config reload, which rebuilds
    /// `scopes`, lays them back on top.
    seeded: Table = .empty,
    session: ?Session = null,
    /// A mirror is being rewritten: the edit it makes moves the stops
    /// but does not sync the mirrors again.
    syncing: bool = false,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        freeTable(self.gpa, &self.scopes);
        freeTable(self.gpa, &self.seeded);
        self.endSession();
    }

    /// Add (or replace) `trigger` in `scope`. It outlives a config reload.
    pub fn seed(self: *State, scope: []const u8, trigger: []const u8, body: []const u8) Allocator.Error!void {
        var buf: [max_scope]u8 = undefined;
        const s = normalizeScope(scope, &buf);
        try put(self.gpa, &self.seeded, s, trigger, body);
        try put(self.gpa, &self.scopes, s, trigger, body);
    }

    /// The config's `snippets` section (`scope → trigger → body`)
    /// becomes the table, replacing what an earlier config put there;
    /// the seeded snippets go back on top. Called when the config is
    /// loaded and on every reload.
    pub fn absorbConfig(self: *State, snippets: anytype) Allocator.Error!void {
        freeTable(self.gpa, &self.scopes);
        var buf: [max_scope]u8 = undefined;
        for (snippets.keys()) |scope| {
            const inner = snippets.get(scope) orelse continue;
            const s = normalizeScope(scope, &buf);
            for (inner.keys()) |trigger| try put(self.gpa, &self.scopes, s, trigger, inner.get(trigger).?);
        }
        var it = self.seeded.iterator();
        while (it.next()) |e| {
            var it2 = e.value_ptr.iterator();
            while (it2.next()) |x| try put(self.gpa, &self.scopes, e.key_ptr.*, x.key_ptr.*, x.value_ptr.*);
        }
    }

    /// `scope` first, then the scope it extends (`tsx` → `ts`), then `global`.
    pub fn lookup(self: *const State, scope: []const u8, trigger: []const u8) ?[]const u8 {
        if (self.scopes.get(scope)) |inner| if (inner.get(trigger)) |b| return b;
        if (parentScope(scope)) |p| if (self.scopes.get(p)) |inner| if (inner.get(trigger)) |b| return b;
        if (self.scopes.get("global")) |inner| if (inner.get(trigger)) |b| return b;
        return null;
    }

    pub fn count(self: *const State) usize {
        var n: usize = 0;
        var it = self.scopes.valueIterator();
        while (it.next()) |inner| n += inner.count();
        return n;
    }

    pub fn endSession(self: *State) void {
        if (self.session) |s| {
            self.gpa.free(s.stops);
            self.gpa.free(s.mirrors);
        }
        self.session = null;
    }
};

/// The longest scope name kept as written; longer ones are cut.
const max_scope = 32;

/// A scope as the config or a `.test` writes it → the key a file's
/// scope is compared with. A language name or an extension becomes the
/// language's key — `.rust` and `.rs` are both `rs`, `.yml` is `yaml`,
/// `.typescript` is `ts` — so the config's scopes and `scopeFor` agree.
/// `global`, and a name mnml-zig has no grammar for, stay as written,
/// lower-cased.
pub fn normalizeScope(raw: []const u8, buf: []u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "global")) return "global";
    if (hl.table.keyForLanguageName(raw)) |k| return k;
    const n = @min(raw.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], raw[0..n]);
    if (hl.table.keyForExtension(lower)) |k| return k;
    return lower;
}

/// The scope a scope's snippets also apply in: TSX files take the
/// TypeScript snippets, JSX files the JavaScript ones.
pub fn parentScope(scope: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, scope, "tsx")) return "ts";
    if (std.mem.eql(u8, scope, "jsx")) return "js";
    return null;
}

/// The snippet scope of a file: its language's key (`rs`, `yaml`, `sh`
/// for a `.zshrc` or a bash shebang), else its extension lower-cased,
/// else `global`. `text` supplies the shebang.
pub fn scopeFor(path: ?[]const u8, text: []const u8, buf: []u8) []const u8 {
    if (hl.detect.keyFor(path, text)) |k| return k;
    const p = path orelse return "global";
    const ext = std.fs.path.extension(p);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "global";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

/// The identifier run ending at `cursor`: `(start, word)`.
pub fn wordBefore(text: []const u8, cursor: usize) struct { start: usize, word: []const u8 } {
    const cur = @min(cursor, text.len);
    var start = cur;
    while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '_')) start -= 1;
    return .{ .start = start, .word = text[start..cur] };
}

/// Expand the trigger before the cursor in `e`. Returns false (and
/// toasts) when nothing matches.
pub fn expand(app: *App, pane_id: PaneId, e: *EditorPane) Allocator.Error!bool {
    const ed = e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    var scope_buf: [32]u8 = undefined;
    const scope = scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf);
    const body = (if (w.word.len > 0) app.snippets.lookup(scope, w.word) else null) orelse {
        app.toast("no snippet matches \"{s}\"", .{w.word});
        return false;
    };
    try insertBody(app, pane_id, e, w.start, ed.cursor, body);
    return true;
}

/// The variables' values for a body replacing `[start, cursor)` in `e`.
fn varsFor(app: *App, e: *EditorPane, start: usize, cursor: usize) Vars {
    const ed = e.buf.editor;
    const bytes = ed.bytes();
    const row = ed.lineOfByte(start);
    const sel: []const u8 = if (ed.anchor) |a| bytes[@min(a, ed.cursor)..@min(@max(a, ed.cursor), bytes.len)] else "";
    return .{
        .path = e.buf.doc.path,
        .workspace = if (app.workspace.len > 0) app.workspace else null,
        .line = row,
        .current_line = bytes[ed.lineStart(row)..ed.lineEnd(row)],
        .word = wordBefore(bytes, cursor).word,
        .selected = sel,
        .clipboard = app.clipboard.text(),
        .now_s = std.Io.Timestamp.now(app.io, .real).toSeconds(),
    };
}

/// `body` replaces `[start, cursor)` and its stops open a session — the
/// tail of a trigger expansion, the whole of a picker insert, and a
/// language server's snippet completion.
pub fn insertBody(app: *App, pane_id: PaneId, e: *EditorPane, start: usize, cursor: usize, body: []const u8) Allocator.Error!void {
    const ed = e.buf.editor;
    const vars = varsFor(app, e, start, cursor);
    var parsed = try parseWith(app.gpa, body, &vars);
    defer parsed.deinit(app.gpa);
    app.snippets.endSession();
    // Every line after the first carries the indent of the line the
    // snippet lands on, as in Neovim and VS Code: a body expanded
    // inside a block stays inside it. The stops move with their lines.
    const indent = ed.leadingIndent(ed.lineOfByte(start), start);
    const text = try indentBody(app.frame.allocator(), parsed.text, indent, parsed.stops, parsed.mirrors);
    try app.splice(e, start, cursor, text);
    // Land on the first stop (or the end of the body).
    const first: ?Stop = if (parsed.stops.len > 0) parsed.stops[0] else null;
    const land = start + (if (first) |f| f.pos else parsed.text.len);
    ed.anchor = null;
    ed.setCursor(@min(land, ed.len()));
    if (first) |f| if (f.default_len > 0) {
        ed.anchor = land;
        ed.setCursor(@min(land + f.default_len, ed.len()));
    };
    // A session for more than one stop, or for one whose mirrors
    // follow what is typed there.
    if (parsed.stops.len > 1 or parsed.mirrors.len > 0) {
        const stops = try app.gpa.alloc(Stop, parsed.stops.len);
        errdefer app.gpa.free(stops);
        for (parsed.stops, 0..) |s, i| {
            stops[i] = s;
            stops[i].pos = start + s.pos;
            stops[i].end = start + s.end;
            stops[i].exit = if (i == 0 and s.default_len > 0) start + s.pos + s.default_len else null;
        }
        const mirrors = try app.gpa.alloc(Mirror, parsed.mirrors.len);
        for (parsed.mirrors, 0..) |m, i| mirrors[i] = .{ .pos = start + m.pos, .end = start + m.end };
        app.snippets.session = .{ .pane = pane_id, .stops = stops, .mirrors = mirrors, .current = 0, .seen_seq = ed.doc.edits.head() };
    }
    app.needs_render = true;
}

/// `text` with `indent` after every `\n`; each stop's and mirror's
/// offsets move by the indent of the lines before them. `stops` and
/// `mirrors` are updated in place.
fn indentBody(arena: Allocator, text: []const u8, indent: []const u8, stops: []Stop, mirrors: []Mirror) Allocator.Error![]u8 {
    if (indent.len == 0 or std.mem.indexOfScalar(u8, text, '\n') == null) return arena.dupe(u8, text);
    const at = struct {
        fn f(t: []const u8, n: usize, off: usize) usize {
            return off + n * std.mem.count(u8, t[0..off], "\n");
        }
    }.f;
    for (stops) |*st| {
        const e = at(text, indent.len, st.end);
        st.pos = at(text, indent.len, st.pos);
        st.default_len = e - st.pos;
        st.end = e;
    }
    for (mirrors) |*m| {
        m.pos = at(text, indent.len, m.pos);
        m.end = at(text, indent.len, m.end);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |c| {
        try out.append(arena, c);
        if (c == '\n') try out.appendSlice(arena, indent);
    }
    return out.toOwnedSlice(arena);
}

// ── the picker ──

/// `snippet.pick`: the active file's scope (and `global`);
/// `snippet.pick_all`: every scope. One row per snippet — the trigger,
/// its scope as the hint, the body on one line as the detail — and
/// Enter inserts the body at the cursor.
fn pickCmd(app: *App) CommandError!void {
    return openPicker(app, false);
}

fn pickAllCmd(app: *App) CommandError!void {
    return openPicker(app, true);
}

fn openPicker(app: *App, all: bool) CommandError!void {
    const e = try app.requireEditor();
    var scope_buf: [32]u8 = undefined;
    const scope = scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf);
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    // Scopes sorted, then triggers sorted: the list reads the same each time.
    var scopes: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.snippets.scopes.keyIterator();
    while (it.next()) |k| {
        const parent = parentScope(scope) orelse "";
        if (!all and !std.mem.eql(u8, k.*, scope) and !std.mem.eql(u8, k.*, parent) and !std.mem.eql(u8, k.*, "global")) continue;
        try scopes.append(arena, k.*);
    }
    std.mem.sort([]const u8, scopes.items, {}, lessStr);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    var hints: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        for (hints.items) |h| gpa.free(h);
        hints.deinit(gpa);
    }
    for (scopes.items) |sc| {
        const inner = app.snippets.scopes.get(sc) orelse continue;
        var triggers: std.ArrayListUnmanaged([]const u8) = .empty;
        var tit = inner.keyIterator();
        while (tit.next()) |k| try triggers.append(arena, k.*);
        std.mem.sort([]const u8, triggers.items, {}, lessStr);
        for (triggers.items) |trig| {
            try labels.append(gpa, try gpa.dupe(u8, trig));
            try details.append(gpa, try oneLine(gpa, inner.get(trig).?));
            try hints.append(gpa, try gpa.dupe(u8, sc));
        }
    }
    if (labels.items.len == 0) {
        if (all) return app.diag.fail(arena, "no snippets configured (config `.snippets`)", .{});
        return app.diag.fail(arena, "no snippets for scope {s} (config `.snippets`)", .{scope});
    }
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.openPickerWith(app, if (all) "Snippets (every scope)" else "Snippets", .snippets, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try hints.toOwnedSlice(gpa));
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The body on one line: newlines become ` ↵ `, at most 60 cells.
fn oneLine(gpa: Allocator, body: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.appendSlice(gpa, " ↵ ");
        first = false;
        try out.appendSlice(gpa, std.mem.trim(u8, line, " \t"));
        if (out.items.len > 60) {
            out.shrinkRetainingCapacity(60);
            try out.appendSlice(gpa, "…");
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The picker's Enter: `trigger` of `scope` at the cursor.
pub fn pickerAccept(app: *App, trigger: []const u8, scope: []const u8) Allocator.Error!void {
    const id = app.active orelse return;
    const e = app.panes.editor(id) orelse return;
    const inner = app.snippets.scopes.get(scope) orelse return;
    const body = inner.get(trigger) orelse return;
    // A selection is replaced — and is `$TM_SELECTED_TEXT` in the body.
    const ed = e.buf.editor;
    const lo = if (ed.anchor) |a| @min(a, ed.cursor) else ed.cursor;
    const hi = if (ed.anchor) |a| @max(a, ed.cursor) else ed.cursor;
    try insertBody(app, id, e, lo, hi, body);
}

/// Move to the next (`dir = 1`) or previous stop. Forward past the last
/// stop ends the session; backward at the first stays.
pub fn step(app: *App, dir: i8) void {
    const sess = if (app.snippets.session) |*s| s else return;
    const e = app.panes.editor(sess.pane) orelse return app.snippets.endSession();
    if (app.active != sess.pane) return app.snippets.endSession();
    const ed = e.buf.editor;
    afterEdit(app, sess.pane, e);
    sess.stops[sess.current].exit = ed.cursor;
    const next: i64 = @as(i64, @intCast(sess.current)) + dir;
    if (next >= @as(i64, @intCast(sess.stops.len))) return app.snippets.endSession();
    if (next < 0) return;
    const idx: usize = @intCast(next);
    const s = sess.stops[idx];
    ed.anchor = null;
    if (s.exit) |x| {
        ed.setCursor(@min(x, ed.len()));
    } else if (s.end > s.pos) {
        // The stop's text as it stands (a mirror or a nested stop may
        // have changed it since the expansion) is selected.
        ed.anchor = @min(s.pos, ed.len());
        ed.setCursor(@min(s.end, ed.len()));
        sess.stops[idx].exit = @min(s.end, ed.len());
    } else {
        ed.setCursor(@min(s.pos, ed.len()));
    }
    sess.current = idx;
    app.needs_render = true;
}

/// Fold the pane's edits since the session last looked into the stops.
/// A stop strictly after an edit moves with the text; one at the edit
/// (typing at the stop) stays; one inside a deleted range clamps to it.
pub fn afterEdit(app: *App, pane_id: PaneId, e: *EditorPane) void {
    const sess = if (app.snippets.session) |*s| s else return;
    if (sess.pane != pane_id) return;
    const ed = e.buf.editor;
    if (ed.doc.edits.replacedSince(sess.seen_seq)) return app.snippets.endSession();
    for (ed.doc.edits.since(sess.seen_seq)) |sp| {
        // What is typed at the end of the stop being filled is its text,
        // and so of every stop around it; a stop elsewhere does not
        // swallow typing that merely touches its end, nor does a mirror
        // (it changes only by being synced).
        const cur = sess.stops[@min(sess.current, sess.stops.len - 1)];
        for (sess.stops) |*s| {
            const holds_cur = !app.snippets.syncing and s.pos <= cur.pos and cur.pos <= s.end;
            s.pos = shift(s.pos, sp.start, sp.old_end, sp.new_end);
            const end = if (holds_cur) shiftEnd(s.end, sp.start, sp.old_end, sp.new_end) else shift(s.end, sp.start, sp.old_end, sp.new_end);
            s.end = @max(s.pos, end);
            if (s.exit) |x| s.exit = shift(x, sp.start, sp.old_end, sp.new_end);
        }
        for (sess.mirrors) |*m| {
            m.pos = shift(m.pos, sp.start, sp.old_end, sp.new_end);
            m.end = @max(m.pos, shift(m.end, sp.start, sp.old_end, sp.new_end));
        }
    }
    sess.seen_seq = ed.doc.edits.head();
    if (!app.snippets.syncing) syncMirrors(app, e);
}

/// Every mirror shows its stop's text: one that differs is rewritten,
/// the cursor and the selection staying where the typing left them.
fn syncMirrors(app: *App, e: *EditorPane) void {
    app.snippets.syncing = true;
    defer app.snippets.syncing = false;
    const ed = e.buf.editor;
    const arena = app.frame.allocator();
    var si: usize = 0;
    while (si < (if (app.snippets.session) |s| s.stops.len else 0)) : (si += 1) {
        var mi = app.snippets.session.?.stops[si].mirror_lo;
        while (mi < app.snippets.session.?.stops[si].mirror_hi) : (mi += 1) {
            const sess = &(app.snippets.session orelse return);
            const st = sess.stops[si];
            const m = sess.mirrors[mi];
            const bytes = ed.bytes();
            if (st.end > bytes.len or m.end > bytes.len) return;
            if (std.mem.eql(u8, bytes[st.pos..st.end], bytes[m.pos..m.end])) continue;
            const want = arena.dupe(u8, bytes[st.pos..st.end]) catch return;
            const cursor = ed.cursor;
            const anchor = ed.anchor;
            app.splice(e, m.pos, m.end, want) catch return;
            const new_end = m.pos + want.len;
            ed.anchor = if (anchor) |a| shift(a, m.pos, m.end, new_end) else null;
            ed.setCursor(@min(shift(cursor, m.pos, m.end, new_end), ed.len()));
        }
    }
}

/// Where an offset lands after `[start, old_end)` became
/// `[start, new_end)`: before it stays, after it moves, inside it
/// clamps to the start. A stop's start: typing AT it stays.
fn shift(pos: usize, start: usize, old_end: usize, new_end: usize) usize {
    if (pos <= start) return pos;
    if (pos >= old_end) return pos - old_end + new_end;
    return start;
}

/// `shift` for the END of a range: an edit reaching it — typing at the
/// end of what a stop holds, or replacing all of it — carries it along.
fn shiftEnd(pos: usize, start: usize, old_end: usize, new_end: usize) usize {
    if (pos < start) return pos;
    if (pos >= old_end) return pos - old_end + new_end;
    return new_end;
}

/// Tab / Shift+Tab / Esc while a session is open on `pane_id`, and Tab
/// on a trigger word when none is. Returns true when the key was taken.
pub fn interceptKey(app: *App, pane_id: PaneId, e: *EditorPane, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    if (app.snippets.session) |s| if (s.pane == pane_id) {
        switch (k.code) {
            .tab => {
                if (k.mods.shift) step(app, -1) else step(app, 1);
                return true;
            },
            .backtab => {
                step(app, -1);
                return true;
            },
            .esc => app.snippets.endSession(),
            else => {},
        }
    };
    if (k.code != .tab or k.mods.shift) return false;
    const mode = e.buf.input.mode();
    if (mode != .insert and mode != .none) return false;
    if (app.snippets.count() == 0) return false;
    const ed = e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    if (w.word.len == 0) return false;
    var scope_buf: [32]u8 = undefined;
    if (app.snippets.lookup(scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf), w.word) == null) return false;
    return expand(app, pane_id, e);
}

fn expandCmd(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const e = try app.requireEditor();
    _ = try expand(app, id, e);
}

fn nextCmd(app: *App) CommandError!void {
    if (app.snippets.session == null) return app.diag.fail(app.frame.allocator(), "no snippet session", .{});
    step(app, 1);
}

fn prevCmd(app: *App) CommandError!void {
    if (app.snippets.session == null) return app.diag.fail(app.frame.allocator(), "no snippet session", .{});
    step(app, -1);
}

// ── tests ──

const testing = std.testing;

test "parse: bare, braced and defaulted stops, $0 last, escapes; a repeat is a mirror showing the default" {
    var p = try parse(testing.allocator, "for $1 in ${2:items} {\n    $0\n}\\$x ${1} $2");
    defer p.deinit(testing.allocator);
    // The repeated `${1}` mirrors an empty stop; the repeated `$2` shows `items`.
    try testing.expectEqualStrings("for  in items {\n    \n}$x  items", p.text);
    try testing.expectEqual(@as(usize, 3), p.stops.len);
    try testing.expectEqual(@as(usize, 4), p.stops[0].pos);
    try testing.expectEqual(@as(usize, 8), p.stops[1].pos);
    try testing.expectEqual(@as(usize, 5), p.stops[1].default_len);
    try testing.expectEqual(@as(usize, 20), p.stops[2].pos);
    try testing.expectEqual(@as(usize, 2), p.mirrors.len);
    try testing.expectEqual(@as(u32, 1), p.stops[0].mirror_hi - p.stops[0].mirror_lo);
    const m2 = p.mirrors[p.stops[1].mirror_lo];
    try testing.expectEqualStrings("items", p.text[m2.pos..m2.end]);
    var none = try parse(testing.allocator, "plain");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.stops.len);
}

test "shift: after moves, at stays, inside a deletion clamps" {
    try testing.expectEqual(@as(usize, 12), shift(10, 5, 5, 7));
    try testing.expectEqual(@as(usize, 5), shift(5, 5, 5, 7));
    try testing.expectEqual(@as(usize, 3), shift(3, 5, 5, 7));
    try testing.expectEqual(@as(usize, 6), shift(10, 5, 9, 5));
    try testing.expectEqual(@as(usize, 5), shift(7, 5, 9, 5));
}

test "table: scope then global, replace on re-seed, config absorb" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.seed("rs", "fn", "fn $1() {}");
    try st.seed("global", "ts", "2026");
    try st.seed("rs", "fn", "fn name() {}");
    try testing.expectEqualStrings("fn name() {}", st.lookup("rs", "fn").?);
    try testing.expectEqualStrings("2026", st.lookup("rs", "ts").?);
    try testing.expectEqualStrings("2026", st.lookup("md", "ts").?);
    try testing.expect(st.lookup("md", "fn") == null);
    try testing.expectEqual(@as(usize, 2), st.count());
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("rs", scopeFor("/x/a.RS", "", &buf));
    try testing.expectEqualStrings("global", scopeFor(null, "", &buf));
    const w = wordBefore("let forr", 8);
    try testing.expectEqualStrings("forr", w.word);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "expansion places the cursor at $1, tab walks the stops, backtab returns to the typed end" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    try app.snippets.seed("global", "forr", "for $1 in $2 {\n    $0\n}");
    const id = try app.openScratch();
    const e = app.activeEditor().?;
    for ("forr") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expectEqualStrings("for  in  {\n    \n}", e.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 4), e.buf.editor.cursor);
    try testing.expect(app.snippets.session != null);
    try app.handle(.{ .key = Key.char('i') });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqual(@as(usize, 9), e.buf.editor.cursor);
    for ("items") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expectEqualStrings("for i in items {\n    \n}", e.buf.editor.bytes());
    try app.handle(.{ .key = Key.named(.backtab) });
    try testing.expectEqual(@as(usize, 5), e.buf.editor.cursor);
    for ("_var") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.tab) });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqual(@as(usize, 25), e.buf.editor.cursor); // the $0 indent
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expect(app.snippets.session == null);
    try testing.expectEqualStrings("for i_var in items {\n    \n}", e.buf.editor.bytes());
    // A trigger with no match toasts and leaves the text alone.
    for (" todo") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "no snippet matches") != null);
    _ = id;
}

test "snippet.pick lists the file's scope and global sorted, pick_all every scope; Enter inserts the body at the cursor" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/x.rs");
    // Nothing configured explains itself.
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"snippet.pick" }));
    try testing.expectEqualStrings("no snippets for scope rs (config `.snippets`)", app.lastToast().?);
    try app.snippets.seed("global", "todo", "// TODO: $1");
    try app.snippets.seed("rs", "fn", "fn $1() {\n    $0\n}");
    try app.snippets.seed("rs", "derive", "#[derive($1)]");
    try app.snippets.seed("py", "main", "if __name__ == '__main__':\n    $0");
    try command.run(&app, .{ .static = .@"snippet.pick" });
    try testing.expect(app.overlay == .picker);
    try testing.expectEqual(app_mod.PickerKind.snippets, app.overlay.picker.kind);
    const p = &app.overlay.picker;
    try testing.expectEqual(@as(usize, 3), p.labels.len);
    try testing.expectEqualStrings("todo", p.labels[0]);
    try testing.expectEqualStrings("derive", p.labels[1]);
    try testing.expectEqualStrings("fn", p.labels[2]);
    try testing.expectEqualStrings("rs", p.hints[2]);
    try testing.expectEqualStrings("fn $1() { ↵ $0 ↵ }", p.details[2]);
    // Enter on `fn` (the filtered index of the third row).
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.accept(&app, 2);
    try testing.expect(app.overlay == .none);
    try testing.expectEqualStrings("fn () {\n    \n}", e.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 3), e.buf.editor.cursor);
    try testing.expect(app.snippets.session != null);
    try command.run(&app, .{ .static = .@"snippet.pick_all" });
    try testing.expectEqual(@as(usize, 4), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("main", app.overlay.picker.labels[1]);
    try testing.expectEqualStrings("py", app.overlay.picker.hints[1]);
    app.overlay.deinit(app.gpa);
}

test "snippet: a body expanded on an indented line carries the indent onto its later lines, stops and all" {
    var stops = [_]Stop{ .{ .pos = 4, .end = 4 }, .{ .pos = 8, .end = 8 }, .{ .pos = 15, .end = 15 } };
    // `for $1 in $2 {\n    $0\n}` parsed: stops at 4, 8 and 15.
    const out = try indentBody(testing.allocator, "for  in  {\n    \n}", "    ", &stops, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("for  in  {\n        \n    }", out);
    try testing.expectEqual(@as(usize, 4), stops[0].pos);
    try testing.expectEqual(@as(usize, 8), stops[1].pos);
    try testing.expectEqual(@as(usize, 19), stops[2].pos);
}

test "config: `.snippets` in the home config.zon fills the table at launch, by language name or extension, and a reload replaces it with seeds kept" {
    const t = std.testing;
    const config = @import("../config/root.zig");
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.createDirPath(t.io, "ws");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/config.zon", .data =
        \\.{ .snippets = .{
        \\    .rust = .{ .fnrs = "fn $1() {}" },
        \\    .yml = .{ .job = "job: $1" },
        \\    .ts = .{ .ifc = "interface $1 {}" },
        \\    .global = .{ .todo = "// TODO: $1" },
        \\} }
    });
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    try vars.put("MNML_DATA_ROOT", data);
    var loaded = try config.load.load(t.allocator, t.io, .{ .workspace = ws, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .cols = 60, .rows = 12 });
    loaded = undefined; // the app owns it now
    defer app.deinit();
    app.tree.visible = false;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("rs", scopeFor("/w/main.rs", "", &buf));
    try t.expectEqualStrings("fn $1() {}", app.snippets.lookup("rs", "fnrs").?);
    try t.expectEqualStrings("job: $1", app.snippets.lookup(scopeFor("/w/ci.yaml", "", &buf), "job").?);
    try t.expectEqualStrings("interface $1 {}", app.snippets.lookup(scopeFor("/w/App.tsx", "", &buf), "ifc").?);
    try t.expectEqualStrings("// TODO: $1", app.snippets.lookup("rs", "todo").?);
    // Typed in a buffer: the trigger expands.
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/w/main.rs");
    for ("fnrs") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try t.expectEqualStrings("fn () {}", e.buf.editor.bytes());
    app.snippets.endSession();
    // A seed (the `.test` directive) survives the reload; the reload
    // takes the file as it is now.
    try app.snippets.seed("rs", "seeded", "x");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/config.zon", .data = ".{ .snippets = .{ .rs = .{ .main = \"fn main() {}\" } } }" });
    try app.reloadConfig(.ask);
    try t.expect(app.snippets.lookup("rs", "fnrs") == null);
    try t.expect(app.snippets.lookup("rs", "todo") == null);
    try t.expectEqualStrings("fn main() {}", app.snippets.lookup("rs", "main").?);
    try t.expectEqualStrings("x", app.snippets.lookup("rs", "seeded").?);
    try t.expectEqual(@as(usize, 2), app.snippets.count());
}

test "grammar: a nested placeholder is text inside its parent's default, a stop of its own" {
    var p = try parse(testing.allocator, "f(${1:a, ${2:b}});");
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("f(a, b);", p.text);
    try testing.expectEqual(@as(usize, 2), p.stops.len);
    try testing.expectEqualStrings("a, b", p.text[p.stops[0].pos..p.stops[0].end]);
    try testing.expectEqual(@as(usize, 4), p.stops[0].default_len);
    try testing.expectEqualStrings("b", p.text[p.stops[1].pos..p.stops[1].end]);
    // Three deep, with a variable inside.
    var d = try parseWith(testing.allocator, "${1:x ${2:y ${3:$TM_FILENAME}}}", &.{ .path = "/w/a.rs" });
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("x y a.rs", d.text);
    try testing.expectEqualStrings("a.rs", d.text[d.stops[2].pos..d.stops[2].end]);
}

test "grammar: a choice inserts its first option, selected; escaped commas and bars stay in it" {
    var p = try parse(testing.allocator, "x = ${1|red,green|};");
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("x = red;", p.text);
    try testing.expectEqual(@as(usize, 3), p.stops[0].default_len);
    var q = try parse(testing.allocator, "${1|a\\,b\\|c,d|} ${2|x|}");
    defer q.deinit(testing.allocator);
    try testing.expectEqualStrings("a,b|c x", q.text);
    // Not a choice (no `|}`): text.
    var r = try parse(testing.allocator, "${1|oops");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("${1|oops", r.text);
}

test "grammar: variables expand, a default stands in for one with no value, a transform is dropped, nothing leaks as markup" {
    const vars: Vars = .{ .path = "/w/src/main.rs", .workspace = "/w", .line = 4, .current_line = "let x", .word = "x", .selected = "sel", .clipboard = "clip", .now_s = 1_790_000_000 };
    var p = try parseWith(testing.allocator, "// $TM_FILENAME ${TM_FILENAME_BASE} $TM_DIRECTORY ${RELATIVE_FILEPATH} L${TM_LINE_NUMBER}/${TM_LINE_INDEX} $TM_CURRENT_WORD $TM_SELECTED_TEXT $CLIPBOARD $WORKSPACE_NAME", &vars);
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("// main.rs main /w/src src/main.rs L5/4 x sel clip w", p.text);
    var d = try parseWith(testing.allocator, "$CURRENT_YEAR-$CURRENT_MONTH-$CURRENT_DATE $CURRENT_HOUR:$CURRENT_MINUTE:$CURRENT_SECOND $CURRENT_YEAR_SHORT", &vars);
    defer d.deinit(testing.allocator);
    // 1_790_000_000 is 2026-09-21 14:13:20 UTC.
    try testing.expectEqualStrings("2026-09-21 14:13:20 26", d.text);
    // No file: the default, else nothing; an unknown name likewise.
    var n = try parse(testing.allocator, "[${TM_FILENAME:untitled}] [$TM_FILENAME] [${NOPE:dflt ${1:stop}}] [$NOPE]");
    defer n.deinit(testing.allocator);
    try testing.expectEqualStrings("[untitled] [] [dflt stop] []", n.text);
    try testing.expectEqual(@as(usize, 1), n.stops.len);
    // A variable with a value drops its default, stops included.
    var v = try parseWith(testing.allocator, "${TM_FILENAME:${1:x}}", &vars);
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("main.rs", v.text);
    try testing.expectEqual(@as(usize, 0), v.stops.len);
    var t = try parseWith(testing.allocator, "${TM_FILENAME/(.*)\\.rs/${1:/upcase}/g}!", &vars);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("main.rs!", t.text);
    var e = try parse(testing.allocator, "cost \\$5 $1;");
    defer e.deinit(testing.allocator);
    try testing.expectEqualStrings("cost $5 ;", e.text);
}

test "mirrors follow the stop live; Tab through a nested placeholder types into the inner stop" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    try app.snippets.seed("global", "lt", "let ${1:name} = 1; use_$1($1);");
    try app.snippets.seed("global", "ff", "f(${1:a, ${2:b}});");
    try app.snippets.seed("global", "ch", "x = ${1|red,green|};");
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    for ("lt") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expectEqualStrings("let name = 1; use_name(name);", e.buf.editor.bytes());
    for ("count") |c| {
        try app.handle(.{ .key = Key.char(c) });
    }
    try testing.expectEqualStrings("let count = 1; use_count(count);", e.buf.editor.bytes());
    // The cursor stayed at the end of what was typed at the stop.
    try testing.expectEqual(@as(usize, 9), e.buf.editor.cursor);
    try app.handle(.{ .key = Key.named(.backspace) });
    try testing.expectEqualStrings("let coun = 1; use_coun(coun);", e.buf.editor.bytes());
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.snippets.session == null);
    // Nested: Tab from the outer default to the inner one, type over it.
    try e.buf.editor.setText("");
    app.snippets.endSession();
    for ("ff") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expectEqualStrings("f(a, b);", e.buf.editor.bytes());
    try app.handle(.{ .key = Key.named(.tab) });
    try app.handle(.{ .key = Key.char('Q') });
    try testing.expectEqualStrings("f(a, Q);", e.buf.editor.bytes());
    // A choice: the first option, selected — typing replaces it.
    try e.buf.editor.setText("");
    app.snippets.endSession();
    for ("ch") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expectEqualStrings("x = red;", e.buf.editor.bytes());
    try testing.expectEqual(@as(?usize, 4), e.buf.editor.anchor);
    try testing.expectEqual(@as(usize, 7), e.buf.editor.cursor);
}
