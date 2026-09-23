//! What a session changed — the set behind `sessions.changes`. Pure
//! functions over git's text and a clock: no `git`, no `App`. The
//! worker (`client.zig`, the `session_changes` job) runs the three
//! commands and hands their bytes here; every slice a function returns
//! borrows the arena it was given, so the set built on the result's
//! arena is adopted whole by the handler.
//!
//! A session's base is three facts taken when its pane starts: the wall
//! clock in milliseconds, the repo's `HEAD` (empty on an unborn branch)
//! and the paths `git status --porcelain -z -uall` called dirty then.
//! A file is in the set when
//!
//!   * **mtime** — it is dirty now, or in a commit since the base, and
//!     its mtime is after the start;
//!   * **git** — it is dirty now and was not dirty at the start, or it
//!     appears in `git log <base>..HEAD --name-status`;
//!
//! and `both` (the default of `ui.session_changes`) takes either. The
//! mtime rule is what catches a file that was already dirty and that the
//! session edited again; the git rule is what catches a deletion (no
//! mtime) and an edit made in the first millisecond. The candidates are
//! only ever the dirty paths and the committed ones — the working tree is
//! never walked, so a clean file the session wrote back byte for byte is
//! not in the set, and neither is anything git ignores.
//!
//! Formats read:
//!   `status --porcelain -z -uall`          → `[]Porcelain`
//!   `log --name-status --format= base..HEAD` → the committed paths
//!   `diff --numstat --no-renames`          → `[]NumStat`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `ui.session_changes`: which rule decides (see the file comment).
pub const Mode = enum { mtime, git, both };

/// git's empty tree — the base of a diff for a session that started on
/// an unborn branch.
pub const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// One `status --porcelain -z` record: the index letter `x`, the
/// worktree letter `y` (`??` for untracked), the path (the NEW path of a
/// rename).
pub const Porcelain = struct { path: []const u8, x: u8, y: u8 };

/// Records are `XY <path>\0`; a rename or a copy is followed by one more
/// record, its old path, which is skipped.
pub fn parsePorcelainZ(arena: Allocator, text: []const u8) Allocator.Error![]Porcelain {
    var out: std.ArrayListUnmanaged(Porcelain) = .empty;
    var it = std.mem.splitScalar(u8, text, 0);
    while (it.next()) |rec| {
        if (rec.len < 4 or rec[2] != ' ') continue;
        try out.append(arena, .{ .path = rec[3..], .x = rec[0], .y = rec[1] });
        if (rec[0] == 'R' or rec[0] == 'C') _ = it.next();
    }
    return out.items;
}

/// The paths of `entries`, once each, sorted — what the base records.
pub fn dirtyPaths(arena: Allocator, entries: []const Porcelain) Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (entries) |e| try names.append(arena, e.path);
    return sortUnique(names.items);
}

/// Non-empty lines, once each, sorted: `log --name-only --format=`.
pub fn parseNames(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        try names.append(arena, line);
    }
    return sortUnique(names.items);
}

/// A path a commit since the base touched, with the letter the NEWEST
/// of them gave it (`A M D T`).
pub const Named = struct { path: []const u8, letter: u8 };

/// `log --name-status --format=`: `L\tpath` lines, newest commit first;
/// a path once, with its first (newest) letter, sorted by path.
pub fn parseNameStatus(arena: Allocator, text: []const u8) Allocator.Error![]const Named {
    var out: std.ArrayListUnmanaged(Named) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
        if (tab == 0 or tab + 1 >= line.len) continue;
        try out.append(arena, .{ .path = line[tab + 1 ..], .letter = line[0] });
    }
    // Stable, so of two equal paths the newest (the earlier line) leads.
    std.mem.sort(Named, out.items, {}, struct {
        fn lt(_: void, a: Named, b: Named) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    var n: usize = 0;
    for (out.items) |e| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1].path, e.path)) continue;
        out.items[n] = e;
        n += 1;
    }
    return out.items[0..n];
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortUnique(items: [][]const u8) []const []const u8 {
    std.mem.sort([]const u8, items, {}, lessThan);
    var n: usize = 0;
    for (items) |s| {
        if (n > 0 and std.mem.eql(u8, items[n - 1], s)) continue;
        items[n] = s;
        n += 1;
    }
    return items[0..n];
}

fn contains(sorted: []const []const u8, path: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sorted[mid], path)) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

/// One `diff --numstat` line. A binary file counts nothing.
pub const NumStat = struct { path: []const u8, added: u32, deleted: u32 };

pub fn parseNumstat(arena: Allocator, text: []const u8) Allocator.Error![]NumStat {
    var out: std.ArrayListUnmanaged(NumStat) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var cols = std.mem.splitScalar(u8, line, '\t');
        const a = cols.next() orelse continue;
        const d = cols.next() orelse continue;
        const p = cols.rest();
        if (p.len == 0) continue;
        try out.append(arena, .{
            .path = p,
            .added = std.fmt.parseInt(u32, a, 10) catch 0,
            .deleted = std.fmt.parseInt(u32, d, 10) catch 0,
        });
    }
    return out.items;
}

/// A file of the set. `x` / `y` are its porcelain letters NOW (`' '`
/// when it is clean — a file only in a commit); `uncommitted` and
/// `committed` say which of the view's groups it is in, and may both be
/// true (committed, then edited again).
pub const File = struct {
    path: []const u8,
    x: u8 = ' ',
    y: u8 = ' ',
    uncommitted: bool = false,
    committed: bool = false,
    /// The newest commit's letter for it, `' '` when it is in none.
    c: u8 = ' ',
    added: u32 = 0,
    deleted: u32 = 0,

    /// In the index (`git.status_view`'s Staged section).
    pub fn staged(f: File) bool {
        return f.uncommitted and f.x != ' ' and f.x != '?';
    }

    /// In the worktree (the Unstaged section) — an untracked file is.
    pub fn unstaged(f: File) bool {
        return f.uncommitted and (f.y != ' ' or f.x == '?');
    }
};

pub const Set = struct {
    /// Sorted by path.
    files: []File = &.{},
    added: u64 = 0,
    deleted: u64 = 0,

    pub fn count(s: Set) usize {
        return s.files.len;
    }

    pub fn find(s: Set, path: []const u8) ?*File {
        for (s.files) |*f| if (std.mem.eql(u8, f.path, path)) return f;
        return null;
    }
};

/// A file's mtime in wall-clock milliseconds, null when it is gone. The
/// worker's is a `stat` under the repo root; a test's is a table.
pub const MtimeFn = struct {
    ctx: *const anyopaque,
    f: *const fn (ctx: *const anyopaque, path: []const u8) ?i64,

    pub fn of(m: MtimeFn, path: []const u8) ?i64 {
        return m.f(m.ctx, path);
    }
};

pub const Input = struct {
    mode: Mode,
    /// The session's start, wall-clock milliseconds.
    since_ms: i64,
    /// Sorted, as `dirtyPaths` returns them.
    dirty_at_start: []const []const u8,
    status: []const Porcelain,
    /// Sorted, as `parseNameStatus` returns them.
    committed: []const Named,
    mtime: MtimeFn,
};

fn after(in: Input, path: []const u8) bool {
    const m = in.mtime.of(path) orelse return false;
    return m > in.since_ms;
}

/// The set, sorted by path. Totals start at zero (`applyNumstat`).
pub fn compute(arena: Allocator, in: Input) Allocator.Error!Set {
    const use_mtime = in.mode != .git;
    const use_git = in.mode != .mtime;
    var files: std.ArrayListUnmanaged(File) = .empty;
    for (in.status) |e| {
        const take = (use_git and !contains(in.dirty_at_start, e.path)) or (use_mtime and after(in, e.path));
        if (!take) continue;
        // A path with both an index and a worktree letter is one record.
        try files.append(arena, .{ .path = e.path, .x = e.x, .y = e.y, .uncommitted = true });
    }
    for (in.committed) |named| {
        const p = named.path;
        const take = use_git or (use_mtime and after(in, p));
        if (!take) continue;
        var found = false;
        for (files.items) |*f| if (std.mem.eql(u8, f.path, p)) {
            f.committed = true;
            f.c = named.letter;
            found = true;
        };
        if (!found) try files.append(arena, .{ .path = p, .committed = true, .c = named.letter });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn lt(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return .{ .files = files.items };
}

/// Each file's `+a −d` and the totals, from `diff --numstat` against the
/// base; `extra` is what the worker counted for the untracked files
/// (every line an addition).
pub fn applyNumstat(set: *Set, stats: []const NumStat, extra: []const NumStat) void {
    set.added = 0;
    set.deleted = 0;
    for (&[_][]const NumStat{ stats, extra }) |list| for (list) |s| if (set.find(s.path)) |f| {
        f.added += s.added;
        f.deleted += s.deleted;
    };
    for (set.files) |f| {
        set.added += f.added;
        set.deleted += f.deleted;
    }
}

/// `n` newlines, plus one for a last line without its newline — how
/// many lines an untracked file adds.
pub fn lineCount(text: []const u8) u32 {
    var n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    if (text.len > 0 and text[text.len - 1] != '\n') n += 1;
    return n;
}

/// Another session's set, for the overlap marker.
pub const Other = struct {
    /// The session's repo root, absolute: a path is the same file only
    /// under the same root (a worktree is a different checkout).
    root: []const u8,
    title: []const u8,
    set: Set,
};

/// For each file of `mine`, the title of the first OTHER session whose
/// set holds the same file, else null — two sessions on one file is the
/// thing the view has to say.
pub fn overlaps(arena: Allocator, root: []const u8, mine: Set, others: []const Other) Allocator.Error![]?[]const u8 {
    const out = try arena.alloc(?[]const u8, mine.files.len);
    for (mine.files, out) |f, *o| {
        o.* = null;
        for (others) |other| {
            if (!std.mem.eql(u8, other.root, root)) continue;
            if (other.set.find(f.path) != null) {
                o.* = other.title;
                break;
            }
        }
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Table = struct {
    entries: []const struct { []const u8, i64 },

    fn of(ctx: *const anyopaque, path: []const u8) ?i64 {
        const t: *const Table = @ptrCast(@alignCast(ctx));
        for (t.entries) |e| if (std.mem.eql(u8, e[0], path)) return e[1];
        return null;
    }

    fn fnOf(t: *const Table) MtimeFn {
        return .{ .ctx = t, .f = &of };
    }
};

test "parsePorcelainZ reads -z records and skips a rename's old path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The rename's old path is shaped like a record (`XY path`) on
    // purpose: only the skip keeps it out.
    const es = try parsePorcelainZ(a, " M a.txt\x00R  new.txt\x00ab old.txt\x00?? dir/n.txt\x00MM both.zig\x00");
    try testing.expectEqual(@as(usize, 4), es.len);
    try testing.expectEqualStrings("a.txt", es[0].path);
    try testing.expectEqual(@as(u8, ' '), es[0].x);
    try testing.expectEqual(@as(u8, 'M'), es[0].y);
    try testing.expectEqualStrings("new.txt", es[1].path);
    try testing.expectEqualStrings("dir/n.txt", es[2].path);
    try testing.expectEqual(@as(u8, '?'), es[2].x);
    try testing.expectEqualStrings("both.zig", es[3].path);
    const d = try dirtyPaths(a, es);
    try testing.expectEqual(@as(usize, 4), d.len);
    try testing.expectEqualStrings("a.txt", d[0]);
    try testing.expectEqualStrings("new.txt", d[3]);
    const names = try parseNames(a, "b.txt\n\na.txt\nb.txt\n");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a.txt", names[0]);
    const cs = try parseNameStatus(a, "M\tb.txt\nA\ta.txt\n\nA\tb.txt\n");
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqualStrings("a.txt", cs[0].path);
    try testing.expectEqual(@as(u8, 'M'), cs[1].letter);
    const ns = try parseNumstat(a, "3\t1\ta.txt\n-\t-\tbin.png\n");
    try testing.expectEqual(@as(usize, 2), ns.len);
    try testing.expectEqual(@as(u32, 3), ns[0].added);
    try testing.expectEqual(@as(u32, 0), ns[1].added);
    try testing.expectEqual(@as(u32, 2), lineCount("a\nb"));
    try testing.expectEqual(@as(u32, 2), lineCount("a\nb\n"));
    try testing.expectEqual(@as(u32, 0), lineCount(""));
}

test "compute: a file dirty before the start is out unless touched since; a new dirty one and a committed one are in; the three modes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const since: i64 = 1_000_000;
    const status = [_]Porcelain{
        .{ .path = "old.txt", .x = ' ', .y = 'M' }, // dirty before, untouched
        .{ .path = "pre.txt", .x = ' ', .y = 'M' }, // dirty before, touched since
        .{ .path = "new.txt", .x = '?', .y = '?' }, // new since
        .{ .path = "gone.txt", .x = ' ', .y = 'D' }, // deleted since: no mtime
    };
    const t: Table = .{ .entries = &.{ .{ "old.txt", since - 5000 }, .{ "pre.txt", since + 10 }, .{ "new.txt", since + 20 }, .{ "c.txt", since + 30 }, .{ "stale.txt", since - 1 } } };
    const in: Input = .{
        .mode = .both,
        .since_ms = since,
        .dirty_at_start = &.{ "old.txt", "pre.txt" },
        .status = &status,
        .committed = &.{ .{ .path = "c.txt", .letter = 'A' }, .{ .path = "stale.txt", .letter = 'M' } },
        .mtime = t.fnOf(),
    };
    const both = try compute(a, in);
    try testing.expectEqual(@as(usize, 5), both.count());
    try testing.expect(both.find("old.txt") == null);
    try testing.expect(both.find("pre.txt").?.uncommitted);
    try testing.expect(both.find("new.txt").?.unstaged());
    try testing.expect(!both.find("new.txt").?.staged());
    try testing.expect(both.find("gone.txt") != null);
    try testing.expect(both.find("c.txt").?.committed);
    try testing.expectEqual(@as(u8, 'A'), both.find("c.txt").?.c);
    try testing.expect(!both.find("c.txt").?.uncommitted);
    // Sorted by path.
    try testing.expectEqualStrings("c.txt", both.files[0].path);

    var git_in = in;
    git_in.mode = .git;
    const g = try compute(a, git_in);
    try testing.expect(g.find("pre.txt") == null);
    try testing.expect(g.find("gone.txt") != null);
    try testing.expect(g.find("stale.txt") != null);

    var mt_in = in;
    mt_in.mode = .mtime;
    const m = try compute(a, mt_in);
    try testing.expect(m.find("pre.txt") != null);
    try testing.expect(m.find("gone.txt") == null);
    try testing.expect(m.find("stale.txt") == null);
    try testing.expect(m.find("c.txt") != null);
}

test "applyNumstat totals the tracked diff and the untracked lines; overlaps name the other session on the same root only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var files = [_]File{ .{ .path = "a.txt", .uncommitted = true, .y = 'M' }, .{ .path = "n.txt", .uncommitted = true, .x = '?', .y = '?' } };
    var set: Set = .{ .files = &files };
    applyNumstat(&set, &.{ .{ .path = "a.txt", .added = 3, .deleted = 2 }, .{ .path = "zzz", .added = 9, .deleted = 9 } }, &.{.{ .path = "n.txt", .added = 4, .deleted = 0 }});
    try testing.expectEqual(@as(u64, 7), set.added);
    try testing.expectEqual(@as(u64, 2), set.deleted);
    var theirs_files = [_]File{.{ .path = "n.txt", .committed = true }};
    const theirs: Set = .{ .files = &theirs_files };
    const o = try overlaps(a, "/r", set, &.{ .{ .root = "/elsewhere", .title = "wt", .set = theirs }, .{ .root = "/r", .title = "fix tests", .set = theirs } });
    try testing.expect(o[0] == null);
    try testing.expectEqualStrings("fix tests", o[1].?);
}
