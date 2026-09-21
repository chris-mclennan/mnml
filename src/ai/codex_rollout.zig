//! Which Codex session a Codex pane is running.
//!
//! Claude Code is told its session id — mnml generates one and puts
//! `--session-id <uuid>` on the command line, so the pane knows its
//! transcript from the first frame. Codex has no such flag: `codex`
//! picks its own id and writes it down in the rollout it opens, at
//! `~/.codex/sessions/YYYY/MM/DD/rollout-<local ts>-<uuid>.jsonl`. So
//! the id can only be learned AFTER the child is running, by reading
//! the rollouts back.
//!
//! The match is a heuristic, and a deliberately narrow one. A rollout
//! is this pane's when its `session_meta` says the same `cwd` the pane
//! runs in AND the session started at or after the pane did. If
//! exactly one rollout answers to that, it is the pane's session; if
//! two do — a second Codex started in the same directory while this
//! one was still finding its feet — the answer is NONE, and the pane
//! comes back dormant. `codex resume --last` is never the fallback:
//! "the newest session on this machine" is not "this pane's session",
//! and resuming a stranger's conversation is worse than restoring
//! nothing.
//!
//! What that costs honestly: two Codex panes opened back-to-back in
//! one directory can only ever identify the younger one (the older
//! one's window contains both). `session.zig` caches a match on the
//! pane the moment it is unambiguous, which is what makes the common
//! case — open one pane, work in it, quit — resolve. And both clocks
//! are read to the second, so a session that began inside the same
//! second as the pane counts as "at or after" it — which is the
//! direction that keeps a pane's OWN session from being missed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ScanError = Io.Cancelable || Allocator.Error;

/// Bytes of a rollout's first line that are read. `session_meta` puts
/// the timestamp, the id and the cwd in the first few hundred bytes,
/// well ahead of the `base_instructions` blob that makes the line tens
/// of kilobytes long.
pub const head_cap: usize = 8 * 1024;

/// A rollout name is `rollout-<timestamp>-<uuid>.jsonl`.
pub const name_prefix = "rollout-";
pub const name_suffix = ".jsonl";

/// What the first line of a rollout says about its session.
pub const Header = struct {
    /// The directory `codex` was started in.
    cwd: []const u8,
    /// When the session began, in epoch seconds (the line's ISO-8601
    /// UTC timestamp — NOT the local time in the file name).
    started_s: i64,
};

/// The session id a rollout file name carries: the last 36 characters
/// of the stem, when they are shaped like a UUID.
pub fn sessionIdOfName(basename: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, basename, name_prefix)) return null;
    if (!std.mem.endsWith(u8, basename, name_suffix)) return null;
    const stem = basename[0 .. basename.len - name_suffix.len];
    if (stem.len < 36) return null;
    const id = stem[stem.len - 36 ..];
    if (!looksLikeUuid(id)) return null;
    return id;
}

/// `8-4-4-4-12` hex. Codex writes v7 ids, so the version nibble is not
/// pinned — only the shape, which is what keeps a stray file name out.
fn looksLikeUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const hyphen = i == 8 or i == 13 or i == 18 or i == 23;
        if (hyphen) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// The `cwd` and the start time out of a rollout's first line.
///
/// Deliberately not a JSON parse: the line carries Codex's whole system
/// prompt and runs to tens of kilobytes, and only its head is read. The
/// two fields wanted are string values in the first few hundred bytes.
pub fn parseHeader(line: []const u8) ?Header {
    const cwd = jsonString(line, "\"cwd\":\"") orelse return null;
    if (cwd.len == 0) return null;
    const ts = jsonString(line, "\"timestamp\":\"") orelse return null;
    return .{ .cwd = cwd, .started_s = parseIso8601(ts) orelse return null };
}

/// The value after the first `key` in `text`, up to the closing quote.
/// An escape inside the value gives up rather than guessing: a path
/// with a `"` or a `\` in it is not one this match is willing to be
/// wrong about.
fn jsonString(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const value = rest[0..end];
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return null;
    return value;
}

/// `YYYY-MM-DDTHH:MM:SS[.sss]Z` → epoch seconds. Anything else is null;
/// a timestamp that cannot be read is a rollout that cannot be dated,
/// and an undated rollout never matches.
pub fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    if (s[s.len - 1] != 'Z') return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    const days = civilToDays(year, month, day);
    return days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Hinnant's
/// `days_from_civil`).
fn civilToDays(y_in: i32, m: u8, d: u8) i64 {
    const y: i64 = @as(i64, y_in) - @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, m) + 9, 12); // March = 0
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, d) - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The head of a rollout's first line, on `gpa`.
fn readFirstLine(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, head_cap);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    var slice = buf[0..n];
    if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| slice = slice[0..nl];
    if (slice.len == buf.len) return buf;
    const out = try gpa.dupe(u8, slice);
    gpa.free(buf);
    return out;
}

/// The Codex session a pane started in `cwd` at `after_s` is running,
/// or null when the answer is not unique.
///
/// Walks `<home>/.codex/sessions` and keeps a rollout only when its
/// `session_meta` names the same `cwd` and dates the session at or
/// after `after_s`. One survivor is the answer; none or several is
/// null. The returned id is on `arena`.
pub fn discover(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    home: []const u8,
    cwd: []const u8,
    after_s: i64,
) ScanError!?[]const u8 {
    if (home.len == 0 or cwd.len == 0) return null;
    const sessions_dir = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    var root = Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var walker = root.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();
    var found: ?[]const u8 = null;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const id = sessionIdOfName(entry.basename) orelse continue;
        try io.checkCancel();
        // A session that started after the pane cannot have stopped
        // writing before it: the cheap stat rules out the years of
        // rollouts this walk would otherwise read the head of.
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (st.mtime.toSeconds() < after_s) continue;
        const line = readFirstLine(gpa, io, entry.dir, entry.basename) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(line);
        const h = parseHeader(line) orelse continue;
        if (h.started_s < after_s) continue;
        if (!std.mem.eql(u8, h.cwd, cwd)) continue;
        // A second candidate is the end of it: resuming the wrong
        // conversation is worse than restoring nothing.
        if (found != null) return null;
        found = try arena.dupe(u8, id);
    }
    return found;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "sessionIdOfName takes the uuid off a rollout name and nothing else" {
    try t.expectEqualStrings(
        "019f734c-7c17-7a32-b461-2c5f79710797",
        sessionIdOfName("rollout-2026-07-17T23-37-00-019f734c-7c17-7a32-b461-2c5f79710797.jsonl").?,
    );
    try t.expect(sessionIdOfName("rollout-2026-07-17T23-37-00.jsonl") == null);
    try t.expect(sessionIdOfName("notes.jsonl") == null);
    try t.expect(sessionIdOfName("rollout-019f734c-7c17-7a32-b461-2c5f79710797.txt") == null);
    // The shape is checked, so a 36-character tail that is not a uuid
    // does not become a session id.
    try t.expect(sessionIdOfName("rollout-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.jsonl") == null);
}

test "parseHeader reads the cwd and dates the session off the line's UTC timestamp" {
    const line =
        \\{"timestamp":"2026-07-18T03:37:32.781Z","type":"session_meta","payload":{"id":"019f734c-7c17-7a32-b461-2c5f79710797","timestamp":"2026-07-18T03:37:00.183Z","cwd":"/w/app","cli_version":"0.146.0"}}
    ;
    const h = parseHeader(line).?;
    try t.expectEqualStrings("/w/app", h.cwd);
    // 2026-07-18T03:37:32Z.
    try t.expectEqual(@as(i64, 1_784_345_852), h.started_s);
}

test "parseIso8601 on the epoch, a leap day and the shapes it refuses" {
    try t.expectEqual(@as(i64, 0), parseIso8601("1970-01-01T00:00:00Z").?);
    try t.expectEqual(@as(i64, 951_782_400), parseIso8601("2000-02-29T00:00:00Z").?);
    try t.expectEqual(@as(i64, 1_767_225_600), parseIso8601("2026-01-01T00:00:00Z").?);
    try t.expectEqual(@as(i64, 1_767_225_600), parseIso8601("2026-01-01T00:00:00.000Z").?);
    // Local time is not a timestamp this will read: an undated rollout
    // never matches, which is the safe direction.
    try t.expect(parseIso8601("2026-01-01T00:00:00") == null);
    try t.expect(parseIso8601("2026-01-01 00:00:00Z") == null);
    try t.expect(parseIso8601("nope") == null);
}

/// One rollout's first line: the shape `session_meta` has, cut down to
/// the two fields the match reads.
fn metaLine(arena: Allocator, id: []const u8, cwd: []const u8, iso: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"timestamp\":\"{s}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{s}\",\"cwd\":\"{s}\",\"cli_version\":\"0.146.0\"}}}}\n",
        .{ iso, id, cwd },
    );
}

test "discover: the one rollout of this cwd started after the pane is the pane's; two is none, and a stranger's cwd is not a match" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try std.fs.path.join(arena, &.{ root, "home" });

    const mine = "aaaaaaaa-0000-4000-8000-000000000001";
    const elsewhere = "bbbbbbbb-0000-4000-8000-000000000002";
    const older = "cccccccc-0000-4000-8000-000000000003";
    const later = "dddddddd-0000-4000-8000-000000000004";
    const after_s = parseIso8601("2026-09-04T10:00:00Z").?;

    const dir = "home/.codex/sessions/2026/09/04";
    try tmp.dir.createDirPath(t.io, dir);
    const seed = struct {
        fn one(d: Io.Dir, a: Allocator, sub: []const u8, id: []const u8, cwd: []const u8, iso: []const u8) !void {
            const name = try std.fmt.allocPrint(a, "{s}/rollout-2026-09-04T10-00-00-{s}.jsonl", .{ sub, id });
            try d.writeFile(t.io, .{ .sub_path = name, .data = try metaLine(a, id, cwd, iso) });
        }
    }.one;
    try seed(tmp.dir, arena, dir, mine, "/w/app", "2026-09-04T10:00:01Z");
    // A session of the same minute in another directory.
    try seed(tmp.dir, arena, dir, elsewhere, "/w/other", "2026-09-04T10:00:05Z");
    // A session of this directory that was already running.
    try seed(tmp.dir, arena, dir, older, "/w/app", "2026-09-04T09:59:00Z");
    // Not a rollout at all.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "home/.codex/sessions/2026/09/04/notes.txt", .data = "hi\n" });

    try t.expectEqualStrings(mine, (try discover(t.allocator, t.io, arena, home, "/w/app", after_s)).?);
    // The other directory's session is found by asking for it, which is
    // the evidence that the cwd is what separates them.
    try t.expectEqualStrings(elsewhere, (try discover(t.allocator, t.io, arena, home, "/w/other", after_s)).?);
    // A directory nothing ran in is no match, and so is a home with no
    // `.codex` under it at all.
    try t.expect((try discover(t.allocator, t.io, arena, home, "/w/nothing", after_s)) == null);
    try t.expect((try discover(t.allocator, t.io, arena, root, "/w/app", after_s)) == null);

    // A SECOND session of this directory inside the window and the
    // answer is no longer unique — so it is no answer. Never `--last`.
    try seed(tmp.dir, arena, dir, later, "/w/app", "2026-09-04T10:00:09Z");
    try t.expect((try discover(t.allocator, t.io, arena, home, "/w/app", after_s)) == null);
}
