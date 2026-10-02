//! Search across session transcripts (`ai.search_sessions`, "Search
//! sessions…"): a prompt for the words, then every transcript the
//! SESSIONS scan knows for this workspace — Claude Code's JSONL under
//! `~/.claude/projects/…`, Codex's rollouts under `~/.codex/sessions/…`
//! (`Item.transcript_path`, the same files the cards and the ENDED rows
//! read) — searched on a worker, and the hits in a picker:
//! `name · date · the matching line`. Enter goes to the session the
//! way the needs-input toast does (`session_attention.focus`): its pane
//! when one here runs it, else its row in the sessions table.
//!
//! The match is on what was SAID — the text of the user's and the
//! agent's messages and the tools' output — not on the JSON around it,
//! so `"type"` does not match every line. Bounded: a transcript is read
//! up to `max_file_bytes` from its head, at most `max_per_session` hits
//! come from one session and `max_hits` in all; the toast says when a
//! cap cut the list.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const sessions = @import("../sessions.zig");
const transcript = @import("../ai/transcript.zig");
const localtime = @import("../core/localtime.zig");
const cmd_picker = @import("cmd_picker.zig");
const session_attention = @import("session_attention.zig");

pub const table = .{
    .@"ai.search_sessions" = &searchCmd,
};

pub const max_hits: usize = 300;
pub const max_per_session: usize = 40;
pub const max_file_bytes: usize = 32 << 20;
/// The matching line as the row shows it, at most this many bytes.
pub const snippet_cap: usize = 160;

/// One transcript to read: what the row names it by.
pub const Source = struct {
    session_id: []const u8,
    name: []const u8,
    path: []const u8,
    /// The transcript's last change, for a line with no timestamp.
    at_s: i64,
};

pub const Hit = struct {
    /// Index into `Result.sources`.
    source: u32,
    /// The JSONL line the match is on, 1-based.
    line: u32,
    /// `YYYY-MM-DD HH:MM`, the line's own time when it carries one.
    date: []const u8,
    text: []const u8,
};

/// A run: built on the UI thread (the sources, the query), filled on
/// the worker (the hits), adopted or freed by `handle`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    generation: u32,
    query: []const u8 = "",
    sources: []Source = &.{},
    hits: []Hit = &.{},
    /// A cap cut the list.
    truncated: bool = false,
    /// Transcripts that could not be read.
    unreadable: u32 = 0,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const State = struct {
    group: Io.Group = .init,
    generation: u32 = 0,
    running: bool = false,
    /// The hits the open picker lists (its accept reads them). Owned.
    last: ?*Result = null,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.last) |r| r.destroy(gpa);
        self.last = null;
    }
};

/// `ai.search_sessions`: the prompt.
fn searchCmd(app: *App) CommandError!void {
    try openPrompt(app);
}

pub fn openPrompt(app: *App) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Search sessions");
    state.placeholder = "words any session said — every transcript of this workspace";
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .session_search } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's accept.
pub fn acceptQuery(app: *App, text: []const u8) Allocator.Error!void {
    const q = std.mem.trim(u8, text, " \t");
    if (q.len == 0) return;
    run(app, q) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| {
            app.toast("{s}", .{m});
            app.diag.clear();
        },
    };
}

/// Start a run for `query` over the transcripts the scan knows — this
/// workspace's, or every workspace's under the section's toggle — on
/// a worker; an earlier run still going is dropped.
pub fn run(app: *App, query: []const u8) CommandError!void {
    const st = &app.session_search;
    const gpa = app.gpa;
    st.group.cancel(app.io);
    st.generation +%= 1;
    const r = try Result.create(gpa, st.generation);
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    r.query = try arena.dupe(u8, query);
    var srcs: std.ArrayListUnmanaged(Source) = .empty;
    const ws_name = std.fs.path.basename(app.workspace);
    for (app.sessions.items) |it| {
        if (it.where != .local or it.transcript_path.len == 0) continue;
        if (!app.sessions.all_workspaces and !sessions.isHere(app, it, ws_name)) continue;
        try srcs.append(arena, .{
            .session_id = try arena.dupe(u8, it.session_id),
            .name = try arena.dupe(u8, sessions.itemName(app, it)),
            .path = try arena.dupe(u8, it.transcript_path),
            .at_s = it.last_activity_s,
        });
    }
    if (srcs.items.len == 0) {
        r.destroy(gpa);
        return app.diag.fail(app.frame.allocator(), "no session transcripts here to search{s}", .{if (app.sessions.scanned_once) "" else " yet — the sessions scan has not run"});
    }
    r.sources = srcs.items;
    st.running = true;
    st.group.concurrent(app.io, worker, .{ app.events, app.io, gpa, r }) catch |err| {
        st.running = false;
        r.destroy(gpa);
        return app.diag.fail(app.frame.allocator(), "search sessions: could not start: {s}", .{@errorName(err)});
    };
    app.toastReplace("session_search", "searching {d} session transcript{s} for “{s}”…", .{ srcs.items.len, if (srcs.items.len == 1) "" else "s", query });
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, r: *Result) Io.Cancelable!void {
    searchInto(io, gpa, r) catch |err| switch (err) {
        error.Canceled => {
            r.destroy(gpa);
            return error.Canceled;
        },
        error.OutOfMemory => r.truncated = true,
    };
    events.post(io, .{ .session_search = r });
}

const SearchError = Io.Cancelable || Allocator.Error;

/// Every source of `r`, its hits onto `r.arena`. Synchronous — the
/// worker's body, and what a test calls directly.
pub fn searchInto(io: Io, gpa: Allocator, r: *Result) SearchError!void {
    const arena = r.arena.allocator();
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    defer r.hits = hits.items;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    for (r.sources, 0..) |src, si| {
        try io.checkCancel();
        if (hits.items.len >= max_hits) {
            r.truncated = true;
            break;
        }
        const text = transcript.readHead(gpa, io, Io.Dir.cwd(), src.path, max_file_bytes) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                r.unreadable += 1;
                continue;
            },
        };
        defer gpa.free(text);
        var per: usize = 0;
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            // The cheap test first: a line whose bytes do not hold the
            // words cannot hold them once decoded (a query with a
            // character JSON escapes is decoded every time).
            if (!needsDecode(r.query) and std.ascii.indexOfIgnoreCase(raw, r.query) == null) continue;
            _ = scratch.reset(.retain_capacity);
            const found = try matchLine(scratch.allocator(), raw, r.query) orelse continue;
            if (per >= max_per_session or hits.items.len >= max_hits) {
                r.truncated = true;
                break;
            }
            per += 1;
            try hits.append(arena, .{
                .source = @intCast(si),
                .line = line_no,
                .date = try arena.dupe(u8, found.date orelse fmtDate(scratch.allocator(), src.at_s)),
                .text = try arena.dupe(u8, found.text),
            });
        }
    }
}

/// A query JSON would escape: `"`, `\`, a control byte, or past ASCII
/// (a transcript may carry it as `\u…`).
fn needsDecode(q: []const u8) bool {
    for (q) |c| if (c == '"' or c == '\\' or c < 0x20 or c >= 0x80) return true;
    return false;
}

const Found = struct { text: []const u8, date: ?[]const u8 };

/// The message text a JSONL line carries, searched for `query`: the
/// first line of it that holds the words, trimmed and cut to
/// `snippet_cap` around them. Null when the words are only in the JSON
/// around the text, or the line is not JSON.
pub fn matchLine(arena: Allocator, raw: []const u8, query: []const u8) Allocator.Error!?Found {
    const line = std.mem.trim(u8, raw, " \r\t");
    if (line.len == 0) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectText(arena, v, &texts, 0);
    for (texts.items) |t| {
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |l| {
            const at = std.ascii.indexOfIgnoreCase(l, query) orelse continue;
            return .{ .text = snippet(std.mem.trim(u8, l, " \t\r"), at, query.len), .date = dateOf(arena, v) };
        }
    }
    return null;
}

/// The strings under `text` / `content` keys, anywhere in the record —
/// Claude's `message.content` (a string, or blocks with `text`, a tool
/// result's `content`), Codex's `payload.content[].text`. A system
/// reminder the CLI injected is not something said.
fn collectText(arena: Allocator, v: std.json.Value, out: *std.ArrayListUnmanaged([]const u8), depth: u8) Allocator.Error!void {
    if (depth > 8) return;
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const val = e.value_ptr.*;
                if (val == .string and (std.mem.eql(u8, k, "text") or std.mem.eql(u8, k, "content"))) {
                    if (!std.mem.startsWith(u8, val.string, "<system-reminder>")) try out.append(arena, val.string);
                } else if (val == .object or val == .array) try collectText(arena, val, out, depth + 1);
            }
        },
        .array => |a| for (a.items) |x| try collectText(arena, x, out, depth + 1),
        else => {},
    }
}

/// `line` cut to `snippet_cap` bytes around the match at `at`, on code
/// point boundaries, with an ellipsis where it was cut.
fn snippet(line: []const u8, at_in: usize, qlen: usize) []const u8 {
    if (line.len <= snippet_cap) return line;
    const at = @min(at_in, line.len);
    var start: usize = if (at > snippet_cap / 3) at - snippet_cap / 3 else 0;
    var end: usize = @min(line.len, start + snippet_cap);
    if (end < at + qlen) end = @min(line.len, at + qlen);
    while (start > 0 and (line[start] & 0xC0) == 0x80) start -= 1;
    while (end < line.len and (line[end] & 0xC0) == 0x80) end += 1;
    return line[start..end];
}

/// The record's own `timestamp` (`2026-09-30T14:02:11.123Z`) as
/// `2026-09-30 14:02` (UTC, as written).
fn dateOf(arena: Allocator, v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const ts = v.object.get("timestamp") orelse return null;
    if (ts != .string or ts.string.len < 16 or ts.string[10] != 'T') return null;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ ts.string[0..10], ts.string[11..16] }) catch null;
}

/// Unix seconds as a local `YYYY-MM-DD HH:MM`.
fn fmtDate(arena: Allocator, secs: i64) []const u8 {
    const local = secs + localtime.offset(secs);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(local, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}

/// A run landed: a stale one is dropped; otherwise the hits open in a
/// picker (or a toast says there were none).
pub fn handle(app: *App, r: *Result) Allocator.Error!void {
    const st = &app.session_search;
    if (r.generation != st.generation) {
        r.destroy(app.gpa);
        return;
    }
    st.running = false;
    app.dismissToast("session_search");
    if (st.last) |old| old.destroy(app.gpa);
    st.last = r;
    if (r.hits.len == 0) {
        app.toast("no session transcript here mentions “{s}” ({d} searched)", .{ r.query, r.sources.len });
        return;
    }
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (r.hits) |h| {
        const src = r.sources[h.source];
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} · {s} · {s}", .{ src.name, h.date, h.text }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "line {d}", .{h.line}));
    }
    const title = try std.fmt.allocPrint(app.frame.allocator(), "Sessions mentioning “{s}” — {d}{s}", .{ r.query, r.hits.len, if (r.truncated) "+" else "" });
    cmd_picker.openPickerWith(app, title, .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    app.overlay.picker.on_accept = &accept;
    if (r.truncated) app.toast("search sessions: the list was capped — narrow the words for the rest", .{});
}

/// Enter on a hit: the session it is in (`session_attention.focus`).
/// A pty pane is the CLI's own screen, so the pane comes forward but
/// cannot be scrolled to the line; the row's detail names the line.
fn accept(app: *App, idx: usize, _: []const u8) Allocator.Error!void {
    const r = app.session_search.last orelse return;
    if (idx >= r.hits.len) return;
    const sid = try app.frame.allocator().dupe(u8, r.sources[r.hits[idx].source].session_id);
    session_attention.focus(app, null, sid) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const demo = @import("../config/demo.zig");
const sessions_table = @import("sessions_table.zig");
const Key = @import("../core/key.zig").Key;

test "matchLine finds what was said, not the JSON around it: a user string, an assistant block, a Codex payload; a system reminder and a key name do not match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const user = (try matchLine(a, "{\"type\":\"user\",\"timestamp\":\"2026-09-30T14:02:11.000Z\",\"message\":{\"role\":\"user\",\"content\":\"first line\\nplease Fix the parser\"}}", "fix the")).?;
    try testing.expectEqualStrings("please Fix the parser", user.text);
    try testing.expectEqualStrings("2026-09-30 14:02", user.date.?);
    const asst = (try matchLine(a, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Added max() and a test\"}]}}", "max()")).?;
    try testing.expectEqualStrings("Added max() and a test", asst.text);
    try testing.expect(asst.date == null);
    const codex = (try matchLine(a, "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"rename the flag\"}]}}", "flag")).?;
    try testing.expectEqualStrings("rename the flag", codex.text);
    try testing.expect(try matchLine(a, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}", "assistant") == null);
    try testing.expect(try matchLine(a, "{\"type\":\"user\",\"message\":{\"content\":\"<system-reminder>secret words</system-reminder>\"}}", "secret") == null);
    try testing.expect(try matchLine(a, "not json at all secret", "secret") == null);
    // A long line is cut around the match.
    const long = try std.fmt.allocPrint(a, "{{\"text\":\"{s}needle{s}\"}}", .{ "a" ** 300, "b" ** 300 });
    const cut = (try matchLine(a, long, "needle")).?;
    try testing.expect(cut.text.len <= snippet_cap + 6);
    try testing.expect(std.mem.indexOf(u8, cut.text, "needle") != null);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    /// A workspace with the demo's three planted transcripts in a home
    /// of its own, scanned.
    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDirPath(testing.io, "ws");
        const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
        defer testing.allocator.free(ws);
        const home = try std.fs.path.join(testing.allocator, &.{ root, "home" });
        errdefer testing.allocator.free(home);
        try demo.plantSessions(testing.allocator, testing.io, home, ws);
        var f: Fixture = .{ .tmp = tmp, .root = root, .app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .cols = 160, .rows = 40 }) };
        f.app.sessions.home = home;
        try sessions.refresh(&f.app);
        try f.until(struct {
            fn done(a: *App) bool {
                return !a.sessions.scanning;
            }
        }.done);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn until(f: *Fixture, cond: *const fn (*App) bool) !void {
        var i: usize = 0;
        while (!cond(&f.app)) : (i += 1) {
            if (i > 1000) return error.Timeout;
            try f.app.tick(App.nowMs(testing.io));
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn search(f: *Fixture, q: []const u8) !void {
        try openPrompt(&f.app);
        try f.app.handle(.{ .paste = try testing.allocator.dupe(u8, q) });
        try f.app.handle(.{ .key = Key.named(.enter) });
        try f.until(struct {
            fn done(a: *App) bool {
                return !a.session_search.running;
            }
        }.done);
    }
};

test "Search sessions over the demo's three planted transcripts: the hits list name · date · line, newest session's first; Enter selects the session's row in the table" {
    var f = try Fixture.init();
    defer f.deinit();
    const app = &f.app;
    try testing.expectEqual(@as(usize, 3), app.sessions.items.len);
    // "changelog": the ask and the reply of one session.
    try f.search("changelog");
    try testing.expect(app.overlay == .picker);
    const labels = app.overlay.picker.labels;
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expect(std.mem.endsWith(u8, labels[0], " · write the 0.1.0 changelog entry"));
    try testing.expect(std.mem.endsWith(u8, labels[1], " · Drafted CHANGELOG.md from the last five commits."));
    try testing.expect(std.mem.indexOf(u8, labels[0], " · 20") != null); // the date
    try testing.expectEqualStrings("line 1", app.overlay.picker.details[0]);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("a71e0b44-2c93-4f5d-8e1a-0b7c3d9e2f48", sessions_table.focused(app).?.selectedItem(app).?.session_id);
    // Words no session said: a toast, no picker.
    try f.search("zebra crossing");
    try testing.expect(app.overlay != .picker);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "mentions") != null);
}
