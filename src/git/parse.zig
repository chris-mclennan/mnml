//! Readers for git's porcelain formats, and the one writer (a single-hunk
//! patch). Pure functions over text: no `git`, no `Io`, no `App`. The
//! worker (`client.zig`) runs `git` and hands the bytes here; every slice
//! a parser returns borrows the arena it was given, so a result built on
//! the event payload's arena is adopted whole by the handler.
//!
//! Formats read:
//!   `status --porcelain=v2 -b`      → `Status`
//!   `diff --no-ext-diff -U<n>`      → `[]FileDiff` (unified hunks)
//!   `blame --porcelain`             → `[]BlameLine` (indexed by final line)
//!   `log --format=<fields>`         → `[]Commit`
//!   `for-each-ref --format=<fields>`→ `[]Branch`
//! Written:
//!   `patchForHunk` — what `git apply --cached [-R]` takes to stage,
//!   unstage or discard one hunk on its own.

const std = @import("std");
const remote_mod = @import("remote.zig");
const Allocator = std.mem.Allocator;

// ─── status ─────────────────────────────────────────────────────────────

/// Which list of the rail an entry belongs to. A file with both index
/// and worktree changes (`MM`) is two entries, one per list.
pub const Group = enum {
    staged,
    unstaged,
    untracked,
    conflicted,

    pub fn label(g: Group) []const u8 {
        return switch (g) {
            .staged => "Staged",
            .unstaged => "Changes",
            .untracked => "Untracked",
            .conflicted => "Conflicts",
        };
    }
};

pub const Entry = struct {
    group: Group,
    /// The porcelain letter for this side: `M A D R C T U ?`.
    code: u8,
    /// Repo-relative, unquoted.
    path: []const u8,
    /// The old path of a rename / copy.
    orig: ?[]const u8 = null,
};

pub const Status = struct {
    /// The branch name; null when detached or before the first commit's
    /// branch line is known.
    branch: ?[]const u8 = null,
    detached: bool = false,
    /// `(initial)` before the first commit.
    oid: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    entries: []Entry = &.{},
    staged: u32 = 0,
    unstaged: u32 = 0,
    untracked: u32 = 0,
    conflicted: u32 = 0,

    /// Everything the rail lists.
    pub fn changeCount(s: Status) u32 {
        return s.staged + s.unstaged + s.untracked + s.conflicted;
    }
};

/// `git status --porcelain=v2 -b` → `Status`. Every slice borrows `arena`.
pub fn parseStatus(arena: Allocator, text: []const u8) Allocator.Error!Status {
    var st: Status = .{};
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 2) continue;
        if (line[0] == '#') {
            try parseBranchLine(arena, &st, line);
            continue;
        }
        switch (line[0]) {
            '1', '2' => {
                // `1 XY sub mH mI mW hH hI path` / `2 … Xscore path\torig`
                const nfields: usize = if (line[0] == '1') 8 else 9;
                var it = std.mem.tokenizeScalar(u8, line, ' ');
                var xy: []const u8 = "..";
                var i: usize = 0;
                var rest: []const u8 = "";
                while (i < nfields) : (i += 1) {
                    const tok = it.next() orelse break;
                    if (i == 1) xy = tok;
                    rest = it.rest();
                }
                if (xy.len < 2 or rest.len == 0) continue;
                var path = rest;
                var orig: ?[]const u8 = null;
                if (line[0] == '2') {
                    if (std.mem.indexOfScalar(u8, rest, '\t')) |tab| {
                        path = rest[0..tab];
                        orig = try unquote(arena, rest[tab + 1 ..]);
                    }
                }
                const p = try unquote(arena, path);
                if (xy[0] != '.') {
                    try entries.append(arena, .{ .group = .staged, .code = xy[0], .path = p, .orig = orig });
                    st.staged += 1;
                }
                if (xy[1] != '.') {
                    try entries.append(arena, .{ .group = .unstaged, .code = xy[1], .path = p, .orig = orig });
                    st.unstaged += 1;
                }
            },
            'u' => {
                var it = std.mem.tokenizeScalar(u8, line, ' ');
                var i: usize = 0;
                var rest: []const u8 = "";
                while (i < 10) : (i += 1) {
                    _ = it.next() orelse break;
                    rest = it.rest();
                }
                if (rest.len == 0) continue;
                try entries.append(arena, .{ .group = .conflicted, .code = 'U', .path = try unquote(arena, rest) });
                st.conflicted += 1;
            },
            '?' => {
                try entries.append(arena, .{ .group = .untracked, .code = '?', .path = try unquote(arena, line[2..]) });
                st.untracked += 1;
            },
            else => {},
        }
    }
    st.entries = entries.items;
    return st;
}

fn parseBranchLine(arena: Allocator, st: *Status, line: []const u8) Allocator.Error!void {
    if (std.mem.startsWith(u8, line, "# branch.head ")) {
        const v = line["# branch.head ".len..];
        if (std.mem.eql(u8, v, "(detached)")) {
            st.detached = true;
        } else if (v.len > 0) {
            st.branch = try arena.dupe(u8, v);
        }
    } else if (std.mem.startsWith(u8, line, "# branch.oid ")) {
        const v = line["# branch.oid ".len..];
        if (!std.mem.eql(u8, v, "(initial)")) st.oid = try arena.dupe(u8, v);
    } else if (std.mem.startsWith(u8, line, "# branch.upstream ")) {
        st.upstream = try arena.dupe(u8, line["# branch.upstream ".len..]);
    } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
        var it = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
        while (it.next()) |tok| {
            if (tok.len < 2) continue;
            const n = std.fmt.parseInt(u32, tok[1..], 10) catch 0;
            if (tok[0] == '+') st.ahead = n else if (tok[0] == '-') st.behind = n;
        }
    }
}

/// A porcelain path as git prints it without `-z`: wrapped in quotes and
/// C-escaped (`"weird-\360\237\230\200.txt"`) when it has bytes git
/// will not print raw. Returns the bytes as they are on disk.
pub fn unquote(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return arena.dupe(u8, s);
    const inner = s[1 .. s.len - 1];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c != '\\' or i + 1 >= inner.len) {
            try out.append(arena, c);
            continue;
        }
        const n = inner[i + 1];
        if (n >= '0' and n <= '7' and i + 3 < inner.len and inner[i + 2] >= '0' and inner[i + 2] <= '7' and inner[i + 3] >= '0' and inner[i + 3] <= '7') {
            const v: u32 = (@as(u32, n - '0') << 6) | (@as(u32, inner[i + 2] - '0') << 3) | @as(u32, inner[i + 3] - '0');
            try out.append(arena, @truncate(v));
            i += 3;
            continue;
        }
        const mapped: ?u8 = switch (n) {
            '\\' => '\\',
            '"' => '"',
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            else => null,
        };
        if (mapped) |m| {
            try out.append(arena, m);
            i += 1;
        } else try out.append(arena, c);
    }
    return out.items;
}

// ─── diff ───────────────────────────────────────────────────────────────

pub const LineKind = enum { context, add, del, meta };

pub const DiffLine = struct {
    kind: LineKind,
    /// The line without its `+` / `-` / ` ` prefix.
    text: []const u8,
    /// 1-based line numbers on each side; null on the side the line
    /// does not exist on.
    old_no: ?u32 = null,
    new_no: ?u32 = null,
};

pub const Hunk = struct {
    /// The whole `@@ … @@ context` line.
    header: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []DiffLine,

    /// Lines the hunk adds / removes (not context).
    pub fn changed(h: Hunk) u32 {
        var n: u32 = 0;
        for (h.lines) |l| if (l.kind == .add or l.kind == .del) {
            n += 1;
        };
        return n;
    }
};

pub const FileStatus = enum { modified, added, deleted, renamed };

pub const FileDiff = struct {
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    status: FileStatus = .modified,
    binary: bool = false,
    hunks: []Hunk = &.{},

    /// The path the file has now (the old one for a deletion).
    pub fn path(f: FileDiff) []const u8 {
        return f.new_path orelse f.old_path orelse "";
    }
};

pub const HunkRange = struct { old_start: u32, old_count: u32, new_start: u32, new_count: u32 };

/// `@@ -1,3 +1,4 @@ fn main()` → the four numbers. A count left out is 1.
pub fn parseHunkHeader(s: []const u8) ?HunkRange {
    if (!std.mem.startsWith(u8, s, "@@ ")) return null;
    const end = std.mem.indexOf(u8, s[3..], " @@") orelse return null;
    var it = std.mem.tokenizeScalar(u8, s[3 .. 3 + end], ' ');
    const old = it.next() orelse return null;
    const new = it.next() orelse return null;
    if (old.len < 2 or new.len < 2 or old[0] != '-' or new[0] != '+') return null;
    const o = parseRange(old[1..]) orelse return null;
    const n = parseRange(new[1..]) orelse return null;
    return .{ .old_start = o[0], .old_count = o[1], .new_start = n[0], .new_count = n[1] };
}

fn parseRange(s: []const u8) ?[2]u32 {
    if (std.mem.indexOfScalar(u8, s, ',')) |c| {
        const a = std.fmt.parseInt(u32, s[0..c], 10) catch return null;
        const b = std.fmt.parseInt(u32, s[c + 1 ..], 10) catch return null;
        return .{ a, b };
    }
    const a = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ a, 1 };
}

/// A unified diff (any number of files) → `[]FileDiff`. Lines before
/// the first hunk of a file (`index`, mode lines, `Binary files`) shape
/// the file's status; the hunk bodies keep every line with its side
/// numbers so a view can paint a gutter and a stager can cut a patch.
pub fn parseDiff(arena: Allocator, text: []const u8) Allocator.Error![]FileDiff {
    var files: std.ArrayListUnmanaged(FileDiff) = .empty;
    var hunks: std.ArrayListUnmanaged(Hunk) = .empty;
    var lines_buf: std.ArrayListUnmanaged(DiffLine) = .empty;
    var cur: ?FileDiff = null;
    var hunk: ?Hunk = null;
    var old_no: u32 = 0;
    var new_no: u32 = 0;
    // Lines the open hunk still owes on each side; a blank line past
    // both is the end of the text, not a blank context line.
    var old_left: u32 = 0;
    var new_left: u32 = 0;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try closeHunk(arena, &hunks, &lines_buf, &hunk);
            try closeFile(arena, &files, &hunks, &cur);
            cur = .{};
            // `diff --git a/x b/y`: the b-side is the path unless a later
            // `---`/`+++` pair says otherwise.
            if (std.mem.indexOf(u8, line[11..], " b/")) |sp| {
                cur.?.old_path = try arena.dupe(u8, stripPrefix(line[11 .. 11 + sp], "a/"));
                cur.?.new_path = try arena.dupe(u8, line[11 + sp + 3 ..]);
            }
            continue;
        }
        if (hunk == null) {
            if (cur == null) {
                // A diff without the `diff --git` header (a `--no-index`
                // pair, or a patch cut by hand) starts at `---`.
                if (std.mem.startsWith(u8, line, "--- ")) cur = .{} else continue;
            }
            const f = &cur.?;
            if (std.mem.startsWith(u8, line, "--- ")) {
                const p = line[4..];
                f.old_path = if (std.mem.eql(u8, p, "/dev/null")) null else try arena.dupe(u8, stripPrefix(p, "a/"));
                if (f.old_path == null) f.status = .added;
            } else if (std.mem.startsWith(u8, line, "+++ ")) {
                const p = line[4..];
                f.new_path = if (std.mem.eql(u8, p, "/dev/null")) null else try arena.dupe(u8, stripPrefix(p, "b/"));
                if (f.new_path == null) f.status = .deleted;
            } else if (std.mem.startsWith(u8, line, "new file mode")) {
                f.status = .added;
            } else if (std.mem.startsWith(u8, line, "deleted file mode")) {
                f.status = .deleted;
            } else if (std.mem.startsWith(u8, line, "rename from ")) {
                f.status = .renamed;
                f.old_path = try arena.dupe(u8, line["rename from ".len..]);
            } else if (std.mem.startsWith(u8, line, "rename to ")) {
                f.new_path = try arena.dupe(u8, line["rename to ".len..]);
            } else if (std.mem.startsWith(u8, line, "Binary files")) {
                f.binary = true;
            } else if (parseHunkHeader(line)) |r| {
                hunk = .{ .header = try arena.dupe(u8, line), .old_start = r.old_start, .old_count = r.old_count, .new_start = r.new_start, .new_count = r.new_count, .lines = &.{} };
                old_no = r.old_start;
                new_no = r.new_start;
                old_left = r.old_count;
                new_left = r.new_count;
            }
            continue;
        }
        // Inside a hunk.
        if (parseHunkHeader(line)) |r| {
            try closeHunk(arena, &hunks, &lines_buf, &hunk);
            hunk = .{ .header = try arena.dupe(u8, line), .old_start = r.old_start, .old_count = r.old_count, .new_start = r.new_start, .new_count = r.new_count, .lines = &.{} };
            old_no = r.old_start;
            new_no = r.new_start;
            old_left = r.old_count;
            new_left = r.new_count;
            continue;
        }
        if (line.len == 0) {
            if (old_left == 0 and new_left == 0) {
                try closeHunk(arena, &hunks, &lines_buf, &hunk);
                continue;
            }
            // A blank context line: git prints a lone space, but a
            // whitespace-stripped patch may have lost it.
            try lines_buf.append(arena, .{ .kind = .context, .text = "", .old_no = old_no, .new_no = new_no });
            old_no += 1;
            new_no += 1;
            old_left -|= 1;
            new_left -|= 1;
            continue;
        }
        switch (line[0]) {
            '+' => {
                try lines_buf.append(arena, .{ .kind = .add, .text = try arena.dupe(u8, line[1..]), .new_no = new_no });
                new_no += 1;
                new_left -|= 1;
            },
            '-' => {
                try lines_buf.append(arena, .{ .kind = .del, .text = try arena.dupe(u8, line[1..]), .old_no = old_no });
                old_no += 1;
                old_left -|= 1;
            },
            ' ' => {
                try lines_buf.append(arena, .{ .kind = .context, .text = try arena.dupe(u8, line[1..]), .old_no = old_no, .new_no = new_no });
                old_no += 1;
                new_no += 1;
                old_left -|= 1;
                new_left -|= 1;
            },
            '\\' => try lines_buf.append(arena, .{ .kind = .meta, .text = try arena.dupe(u8, line) }),
            else => {
                // Something that is not a hunk line: the hunk ended
                // without a header we recognise (a `diff` variant with an
                // unusual preamble). Close and re-read the line as a preamble.
                try closeHunk(arena, &hunks, &lines_buf, &hunk);
                if (std.mem.startsWith(u8, line, "diff --git ")) {
                    try closeFile(arena, &files, &hunks, &cur);
                    cur = .{};
                    if (std.mem.indexOf(u8, line[11..], " b/")) |sp| {
                        cur.?.old_path = try arena.dupe(u8, stripPrefix(line[11 .. 11 + sp], "a/"));
                        cur.?.new_path = try arena.dupe(u8, line[11 + sp + 3 ..]);
                    }
                }
            },
        }
    }
    try closeHunk(arena, &hunks, &lines_buf, &hunk);
    try closeFile(arena, &files, &hunks, &cur);
    return files.items;
}

fn stripPrefix(s: []const u8, p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, p)) s[p.len..] else s;
}

fn closeHunk(arena: Allocator, hunks: *std.ArrayListUnmanaged(Hunk), lines: *std.ArrayListUnmanaged(DiffLine), hunk: *?Hunk) Allocator.Error!void {
    const h = &(hunk.* orelse return);
    h.lines = try arena.dupe(DiffLine, lines.items);
    lines.clearRetainingCapacity();
    try hunks.append(arena, h.*);
    hunk.* = null;
}

fn closeFile(arena: Allocator, files: *std.ArrayListUnmanaged(FileDiff), hunks: *std.ArrayListUnmanaged(Hunk), cur: *?FileDiff) Allocator.Error!void {
    const f = &(cur.* orelse return);
    f.hunks = try arena.dupe(Hunk, hunks.items);
    hunks.clearRetainingCapacity();
    try files.append(arena, f.*);
    cur.* = null;
}

/// The patch `git apply` takes for one hunk of `f` on its own: the two
/// path lines and the hunk verbatim. `--cached` stages it, `--cached -R`
/// unstages it, a bare `-R` discards it from the worktree. Context lines
/// are kept so the hunk still applies when its neighbours have moved.
pub fn patchForHunk(arena: Allocator, f: FileDiff, hunk_idx: usize) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const h = f.hunks[hunk_idx];
    const new_p = f.new_path orelse f.old_path orelse "";
    const old_p = f.old_path orelse new_p;
    try out.print(arena, "diff --git a/{s} b/{s}\n", .{ old_p, new_p });
    if (f.old_path == null) try out.appendSlice(arena, "new file mode 100644\n");
    if (f.new_path == null) try out.appendSlice(arena, "deleted file mode 100644\n");
    if (f.old_path) |p| try out.print(arena, "--- a/{s}\n", .{p}) else try out.appendSlice(arena, "--- /dev/null\n");
    if (f.new_path) |p| try out.print(arena, "+++ b/{s}\n", .{p}) else try out.appendSlice(arena, "+++ /dev/null\n");
    // The counts are recomputed from the lines kept: the header git
    // printed is right, but a caller may hand a trimmed hunk one day.
    var oc: u32 = 0;
    var nc: u32 = 0;
    for (h.lines) |l| switch (l.kind) {
        .context => {
            oc += 1;
            nc += 1;
        },
        .add => nc += 1,
        .del => oc += 1,
        .meta => {},
    };
    try out.print(arena, "@@ -{d},{d} +{d},{d} @@\n", .{ h.old_start, oc, h.new_start, nc });
    for (h.lines) |l| {
        switch (l.kind) {
            .context => try out.append(arena, ' '),
            .add => try out.append(arena, '+'),
            .del => try out.append(arena, '-'),
            .meta => {},
        }
        try out.appendSlice(arena, l.text);
        try out.append(arena, '\n');
    }
    return out.items;
}

// ─── gutter marks ───────────────────────────────────────────────────────

pub const MarkKind = enum { added, modified, deleted };

/// A changed line for the editor gutter. `line` is 0-based in the
/// worktree file; a `deleted` mark sits on the line after the removed
/// run.
pub const GutterMark = struct { line: u32, kind: MarkKind };

/// Marks for one file from its hunks (against HEAD). A run of removed
/// lines followed by added ones is a modification of the added lines;
/// removed lines with nothing added mark the next line as `deleted`.
pub fn gutterMarks(arena: Allocator, f: FileDiff) Allocator.Error![]GutterMark {
    var out: std.ArrayListUnmanaged(GutterMark) = .empty;
    for (f.hunks) |h| {
        var pending_del: u32 = 0;
        var new_no: u32 = h.new_start;
        for (h.lines) |l| switch (l.kind) {
            .del => pending_del += 1,
            .add => {
                try out.append(arena, .{ .line = new_no -| 1, .kind = if (pending_del > 0) .modified else .added });
                if (pending_del > 0) pending_del -= 1;
                new_no += 1;
            },
            .context => {
                if (pending_del > 0) try out.append(arena, .{ .line = new_no -| 1, .kind = .deleted });
                pending_del = 0;
                new_no += 1;
            },
            .meta => {},
        };
        if (pending_del > 0) try out.append(arena, .{ .line = new_no -| 1, .kind = .deleted });
    }
    return out.items;
}

// ─── blame ──────────────────────────────────────────────────────────────

pub const BlameLine = struct {
    /// Full sha; all zeros for a line not committed yet.
    sha: []const u8,
    author: []const u8,
    /// Unix seconds; 0 when unknown.
    time: i64 = 0,
    summary: []const u8 = "",

    pub fn isUncommitted(b: BlameLine) bool {
        for (b.sha) |c| if (c != '0') return false;
        return true;
    }

    pub fn short(b: BlameLine) []const u8 {
        return b.sha[0..@min(7, b.sha.len)];
    }
};

/// `git blame --porcelain` → one entry per file line, in order. The
/// metadata of a commit appears once, on its first group; later groups
/// name the sha only, so entries are resolved through a sha→meta map.
pub fn parseBlame(arena: Allocator, text: []const u8) Allocator.Error![]BlameLine {
    const Meta = struct { author: []const u8, time: i64, summary: []const u8 };
    var meta: std.StringHashMapUnmanaged(Meta) = .empty;
    defer meta.deinit(arena);
    var out: std.ArrayListUnmanaged(BlameLine) = .empty;
    var cur_sha: ?[]const u8 = null;
    var cur_final: u32 = 0;
    var author: []const u8 = "";
    var time: i64 = 0;
    var summary: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '\t') {
            const sha = cur_sha orelse continue;
            if (author.len > 0 and !meta.contains(sha)) try meta.put(arena, sha, .{ .author = author, .time = time, .summary = summary });
            const m = meta.get(sha) orelse Meta{ .author = "", .time = 0, .summary = "" };
            // Final line numbers arrive in order for a plain blame, but
            // pad defensively so `out[final-1]` is always this line.
            while (out.items.len < cur_final) try out.append(arena, .{ .sha = sha, .author = m.author, .time = m.time, .summary = m.summary });
            if (cur_final >= 1) out.items[cur_final - 1] = .{ .sha = sha, .author = m.author, .time = m.time, .summary = m.summary };
            cur_sha = null;
            author = "";
            time = 0;
            summary = "";
            continue;
        }
        if (isShaHeader(line)) {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            cur_sha = try arena.dupe(u8, it.next().?);
            _ = it.next(); // original line
            cur_final = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, line, "author ")) {
            author = try arena.dupe(u8, line["author ".len..]);
        } else if (std.mem.startsWith(u8, line, "author-time ")) {
            time = std.fmt.parseInt(i64, line["author-time ".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            summary = try arena.dupe(u8, line["summary ".len..]);
        }
    }
    return out.items;
}

fn isShaHeader(line: []const u8) bool {
    if (line.len < 42) return false;
    for (line[0..40]) |c| if (!std.ascii.isHex(c)) return false;
    return line[40] == ' ' and std.ascii.isDigit(line[41]);
}

// ─── log ────────────────────────────────────────────────────────────────

/// The `--format` the worker passes; fields are split on `\x1f`,
/// records on `\x1e`.
pub const log_format = "%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e";

pub const Commit = struct {
    hash: []const u8,
    parents: []const []const u8,
    author: []const u8,
    /// Unix seconds.
    time: i64,
    /// `HEAD -> main, origin/main, tag: v1` as git prints it; empty when none.
    refs: []const u8,
    subject: []const u8,

    pub fn short(c: Commit) []const u8 {
        return c.hash[0..@min(7, c.hash.len)];
    }
};

pub fn parseLog(arena: Allocator, text: []const u8) Allocator.Error![]Commit {
    var out: std.ArrayListUnmanaged(Commit) = .empty;
    var recs = std.mem.splitScalar(u8, text, '\x1e');
    while (recs.next()) |rec_raw| {
        const rec = std.mem.trim(u8, rec_raw, "\r\n");
        if (rec.len == 0) continue;
        var f = std.mem.splitScalar(u8, rec, '\x1f');
        const hash = f.next() orelse continue;
        const parents_s = f.next() orelse "";
        const author = f.next() orelse "";
        const time_s = f.next() orelse "0";
        const refs = f.next() orelse "";
        const subject = f.next() orelse "";
        var parents: std.ArrayListUnmanaged([]const u8) = .empty;
        var pit = std.mem.tokenizeScalar(u8, parents_s, ' ');
        while (pit.next()) |p| try parents.append(arena, try arena.dupe(u8, p));
        try out.append(arena, .{
            .hash = try arena.dupe(u8, hash),
            .parents = parents.items,
            .author = try arena.dupe(u8, author),
            .time = std.fmt.parseInt(i64, time_s, 10) catch 0,
            .refs = try arena.dupe(u8, refs),
            .subject = try arena.dupe(u8, subject),
        });
    }
    return out.items;
}

// ─── branches ───────────────────────────────────────────────────────────

/// `for-each-ref` spells a hex escape `%1f` (two digits right after the
/// `%`); `%x1f` is `log`'s spelling and comes out literally here.
pub const ref_format = "%(refname:short)%1f%(committerdate:unix)%1f%(HEAD)%1f%(upstream:short)%1f%(objectname:short)%1f%(upstream:track,nobracket)";

pub const Branch = struct {
    name: []const u8,
    /// Last commit, unix seconds.
    time: i64,
    current: bool,
    remote: bool,
    upstream: []const u8 = "",
    sha: []const u8 = "",
    /// Against the upstream (`%(upstream:track)`); both 0 without one.
    ahead: u32 = 0,
    behind: u32 = 0,
    /// The upstream is gone (`[gone]`).
    gone: bool = false,
};

/// `ahead 2, behind 1` / `ahead 3` / `gone` / `` as `for-each-ref`
/// prints `%(upstream:track,nobracket)`.
pub const Track = struct { ahead: u32 = 0, behind: u32 = 0, gone: bool = false };

pub fn parseTrack(track: []const u8) Track {
    var out: Track = .{};
    if (std.mem.eql(u8, std.mem.trim(u8, track, " "), "gone")) {
        out.gone = true;
        return out;
    }
    var it = std.mem.splitScalar(u8, track, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, t, "ahead ")) {
            out.ahead = std.fmt.parseInt(u32, t["ahead ".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "behind ")) {
            out.behind = std.fmt.parseInt(u32, t["behind ".len..], 10) catch 0;
        }
    }
    return out;
}

/// `git for-each-ref --format=<ref_format> refs/heads refs/remotes`.
/// A remote's `HEAD` pointer (`origin/HEAD`) is dropped.
pub fn parseBranches(arena: Allocator, text: []const u8) Allocator.Error![]Branch {
    var out: std.ArrayListUnmanaged(Branch) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\x1f');
        const name = f.next() orelse continue;
        const time_s = f.next() orelse "0";
        const head = f.next() orelse "";
        const upstream = f.next() orelse "";
        const sha = f.next() orelse "";
        const track = parseTrack(f.next() orelse "");
        if (std.mem.endsWith(u8, name, "/HEAD")) continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .time = std.fmt.parseInt(i64, time_s, 10) catch 0,
            .current = std.mem.eql(u8, head, "*"),
            .remote = std.mem.indexOfScalar(u8, name, '/') != null and !std.mem.eql(u8, head, "*") and isRemoteName(name),
            .upstream = try arena.dupe(u8, upstream),
            .sha = try arena.dupe(u8, sha),
            .ahead = track.ahead,
            .behind = track.behind,
            .gone = track.gone,
        });
    }
    return out.items;
}

/// `for-each-ref` shortens `refs/remotes/origin/x` to `origin/x` and
/// `refs/heads/feature/x` to `feature/x` alike; the worker asks for the
/// two ref spaces in two calls so it can tell them apart, and marks
/// remote rows itself. This is the fallback when it did not.
fn isRemoteName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "origin/") or std.mem.startsWith(u8, name, "upstream/");
}

// ─── pull requests (gh) ─────────────────────────────────────────────────

/// One open PR from `gh pr list --json number,title,headRefName,url`.
pub const Pr = struct {
    number: u32,
    title: []const u8,
    branch: []const u8,
    url: []const u8,
};

pub fn parsePrs(arena: Allocator, json: []const u8) Allocator.Error![]Pr {
    var out: std.ArrayListUnmanaged(Pr) = .empty;
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json, .{}) catch return out.items;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return out.items,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const number: u32 = if (obj.get("number")) |n| switch (n) {
            .integer => |i| if (i >= 0) @intCast(i) else 0,
            else => 0,
        } else 0;
        try out.append(arena, .{
            .number = number,
            .title = try arena.dupe(u8, jsonString(obj.get("title"))),
            .branch = try arena.dupe(u8, jsonString(obj.get("headRefName"))),
            .url = try arena.dupe(u8, jsonString(obj.get("url"))),
        });
    }
    return out.items;
}

fn jsonString(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

// ─── worktrees ──────────────────────────────────────────────────────────

/// One entry of `git worktree list --porcelain`. The first entry is
/// the repository's own directory (`main`); `dirty` is what the worker
/// found running `status --porcelain` inside the tree.
pub const Worktree = struct {
    path: []const u8,
    /// The short branch name; empty when detached or bare.
    branch: []const u8 = "",
    head: []const u8 = "",
    detached: bool = false,
    bare: bool = false,
    /// `git worktree lock`ed, with the note it was given, if any.
    locked: bool = false,
    lock_reason: []const u8 = "",
    main: bool = false,
    dirty: bool = false,

    /// The branch, or `(detached)` / `(bare)`.
    pub fn label(w: Worktree) []const u8 {
        if (w.branch.len > 0) return w.branch;
        return if (w.bare) "(bare)" else "(detached)";
    }
};

/// `worktree <path>` / `HEAD <sha>` / `branch refs/heads/x` or
/// `detached` / `bare` / `locked [reason]` / `prunable …`, a blank
/// line between entries.
pub fn parseWorktrees(arena: Allocator, text: []const u8) Allocator.Error![]Worktree {
    var out: std.ArrayListUnmanaged(Worktree) = .empty;
    var cur: ?Worktree = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (cur) |c| try out.append(arena, c);
            cur = .{ .path = try arena.dupe(u8, line["worktree ".len..]), .main = out.items.len == 0 };
        } else if (cur == null) {
            continue;
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            cur.?.head = try arena.dupe(u8, line["HEAD ".len..]);
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            const b = line["branch ".len..];
            cur.?.branch = try arena.dupe(u8, if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else b);
        } else if (std.mem.eql(u8, line, "detached")) {
            cur.?.detached = true;
        } else if (std.mem.eql(u8, line, "bare")) {
            cur.?.bare = true;
        } else if (std.mem.eql(u8, line, "locked") or std.mem.startsWith(u8, line, "locked ")) {
            cur.?.locked = true;
            if (line.len > "locked ".len) cur.?.lock_reason = try arena.dupe(u8, line["locked ".len..]);
        } else if (line.len == 0) {
            try out.append(arena, cur.?);
            cur = null;
        }
    }
    if (cur) |c| try out.append(arena, c);
    return out.items;
}

// ─── stashes ────────────────────────────────────────────────────────────

/// One line of `git stash list --format=%h%x1f%gd%x1f%s`.
pub const Stash = struct {
    /// The stash commit's short sha.
    sha: []const u8,
    /// `stash@{N}` — what `apply` / `pop` / `drop` name.
    ref: []const u8,
    /// `%s`: `On main: note` or `WIP on main: abc123 subject`.
    message: []const u8,
};

pub fn parseStashes(arena: Allocator, text: []const u8) Allocator.Error![]Stash {
    var out: std.ArrayListUnmanaged(Stash) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\x1f');
        const sha = f.next() orelse continue;
        const ref = f.next() orelse continue;
        try out.append(arena, .{
            .sha = try arena.dupe(u8, sha),
            .ref = try arena.dupe(u8, ref),
            .message = try arena.dupe(u8, f.rest()),
        });
    }
    return out.items;
}

// ─── tags ───────────────────────────────────────────────────────────────

/// `for-each-ref` over `refs/tags`, newest first: the name, the tag
/// object's sha and the commit it peels to (empty for a lightweight
/// tag, whose object IS the commit).
pub const tag_format = "%(refname:short)%1f%(objectname:short)%1f%(*objectname:short)";

pub const Tag = struct {
    name: []const u8,
    /// The commit the tag points at — the peeled sha when annotated.
    sha: []const u8,
    annotated: bool,
};

pub fn parseTags(arena: Allocator, text: []const u8) Allocator.Error![]Tag {
    var out: std.ArrayListUnmanaged(Tag) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\x1f');
        const name = f.next() orelse continue;
        const object = f.next() orelse "";
        const peeled = f.next() orelse "";
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .sha = try arena.dupe(u8, if (peeled.len > 0) peeled else object),
            .annotated = peeled.len > 0,
        });
    }
    return out.items;
}

// ─── remotes ────────────────────────────────────────────────────────────

/// One remote from `git remote -v` (its fetch line) and the forge its
/// URL names.
pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    provider: remote_mod.Provider,
};

/// `origin<TAB>git@host:o/r.git (fetch)` lines; the push lines are
/// skipped so each remote lists once.
pub fn parseRemotes(arena: Allocator, text: []const u8) Allocator.Error![]Remote {
    var out: std.ArrayListUnmanaged(Remote) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        var rest = line[tab + 1 ..];
        if (std.mem.endsWith(u8, rest, " (push)")) continue;
        if (std.mem.endsWith(u8, rest, " (fetch)")) rest = rest[0 .. rest.len - " (fetch)".len];
        var dup = false;
        for (out.items) |r| if (std.mem.eql(u8, r.name, name)) {
            dup = true;
        };
        if (dup) continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .url = try arena.dupe(u8, rest),
            .provider = remote_mod.providerOf(rest),
        });
    }
    return out.items;
}

// ─── a commit's files ───────────────────────────────────────────────────

/// One line of `git diff-tree --name-status`: the letter and the path
/// (the new path of a rename).
pub const DetailFile = struct { status: u8, path: []const u8 };

pub fn parseNameStatus(arena: Allocator, text: []const u8) Allocator.Error![]DetailFile {
    var out: std.ArrayListUnmanaged(DetailFile) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const code = f.next() orelse continue;
        var path = f.next() orelse continue;
        // `R100\told\tnew`: the new path is the last field.
        if (f.next()) |newer| path = newer;
        try out.append(arena, .{ .status = if (code.len > 0) code[0] else '?', .path = try arena.dupe(u8, unquotePath(path)) });
    }
    return out.items;
}

fn unquotePath(p: []const u8) []const u8 {
    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') return p[1 .. p.len - 1];
    return p;
}

// ─── relative age ───────────────────────────────────────────────────────

/// `3m`, `2h`, `5d`, `3w`, `4mo`, `2y` — the blame gutter's age column.
pub fn relativeAge(buf: []u8, then: i64, now: i64) []const u8 {
    if (then <= 0) return "";
    const d = @max(now - then, 0);
    const r = if (d < 60)
        std.fmt.bufPrint(buf, "{d}s", .{d})
    else if (d < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(d, 60)})
    else if (d < 86_400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(d, 3600)})
    else if (d < 7 * 86_400)
        std.fmt.bufPrint(buf, "{d}d", .{@divFloor(d, 86_400)})
    else if (d < 30 * 86_400)
        std.fmt.bufPrint(buf, "{d}w", .{@divFloor(d, 7 * 86_400)})
    else if (d < 365 * 86_400)
        std.fmt.bufPrint(buf, "{d}mo", .{@divFloor(d, 30 * 86_400)})
    else
        std.fmt.bufPrint(buf, "{d}y", .{@divFloor(d, 365 * 86_400)});
    return r catch "";
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn arenaOf(a: *std.heap.ArenaAllocator) Allocator {
    return a.allocator();
}

test "status v2: branch header, ahead/behind, staged+unstaged split, rename, untracked, conflict, quoted path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const text =
        "# branch.oid 0123abcd\n" ++
        "# branch.head main\n" ++
        "# branch.upstream origin/main\n" ++
        "# branch.ab +2 -1\n" ++
        "1 M. N... 100644 100644 100644 aaaa bbbb src/staged.zig\n" ++
        "1 .M N... 100644 100644 100644 aaaa bbbb src/dirty.zig\n" ++
        "1 MM N... 100644 100644 100644 aaaa bbbb src/both.zig\n" ++
        "1 A. N... 000000 100644 100644 0000 bbbb \"sp ace \\303\\251.txt\"\n" ++
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 new.txt\told.txt\n" ++
        "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc merge.txt\n" ++
        "? junk.log\n" ++
        "! ignored.o\n";
    const st = try parseStatus(arenaOf(&a), text);
    try testing.expectEqualStrings("main", st.branch.?);
    try testing.expectEqualStrings("origin/main", st.upstream.?);
    try testing.expectEqual(@as(u32, 2), st.ahead);
    try testing.expectEqual(@as(u32, 1), st.behind);
    try testing.expectEqual(@as(u32, 4), st.staged); // staged, both, sp ace, new.txt
    try testing.expectEqual(@as(u32, 2), st.unstaged); // dirty, both
    try testing.expectEqual(@as(u32, 1), st.untracked);
    try testing.expectEqual(@as(u32, 1), st.conflicted);
    try testing.expectEqual(@as(u32, 8), st.changeCount());
    try testing.expectEqual(@as(usize, 8), st.entries.len);
    try testing.expectEqual(Group.staged, st.entries[0].group);
    try testing.expectEqual(@as(u8, 'M'), st.entries[0].code);
    try testing.expectEqualStrings("src/staged.zig", st.entries[0].path);
    try testing.expectEqual(Group.unstaged, st.entries[1].group);
    try testing.expectEqual(Group.staged, st.entries[2].group);
    try testing.expectEqual(Group.unstaged, st.entries[3].group);
    try testing.expectEqualStrings("src/both.zig", st.entries[3].path);
    try testing.expectEqualStrings("sp ace é.txt", st.entries[4].path);
    try testing.expectEqual(@as(u8, 'R'), st.entries[5].code);
    try testing.expectEqualStrings("new.txt", st.entries[5].path);
    try testing.expectEqualStrings("old.txt", st.entries[5].orig.?);
    try testing.expectEqual(Group.conflicted, st.entries[6].group);
    try testing.expectEqual(Group.untracked, st.entries[7].group);
    try testing.expectEqualStrings("junk.log", st.entries[7].path);
}

test "status v2: detached HEAD and an initial repo" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const st = try parseStatus(arenaOf(&a), "# branch.oid (initial)\n# branch.head (detached)\n");
    try testing.expect(st.branch == null);
    try testing.expect(st.detached);
    try testing.expect(st.oid == null);
    try testing.expectEqual(@as(u32, 0), st.changeCount());
    const empty = try parseStatus(arenaOf(&a), "");
    try testing.expect(empty.branch == null);
}

test "unquote decodes octal + C escapes and passes plain paths through" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("weird-😀.txt", try unquote(arenaOf(&a), "\"weird-\\360\\237\\230\\200.txt\""));
    try testing.expectEqualStrings("a\tb", try unquote(arenaOf(&a), "\"a\\tb\""));
    try testing.expectEqualStrings("a\\b", try unquote(arenaOf(&a), "\"a\\\\b\""));
    try testing.expectEqualStrings("plain/path.txt", try unquote(arenaOf(&a), "plain/path.txt"));
}

const sample_diff =
    "diff --git a/src/a.zig b/src/a.zig\n" ++
    "index 1111111..2222222 100644\n" ++
    "--- a/src/a.zig\n" ++
    "+++ b/src/a.zig\n" ++
    "@@ -1,4 +1,5 @@\n" ++
    " const std = @import(\"std\");\n" ++
    "-fn alpha() {}\n" ++
    "+fn beta() {}\n" ++
    "+fn gamma() {}\n" ++
    " \n" ++
    " const x = 1;\n" ++
    "@@ -10,2 +11,1 @@ fn tail()\n" ++
    "-    gone\n" ++
    " }\n" ++
    "diff --git a/new.txt b/new.txt\n" ++
    "new file mode 100644\n" ++
    "index 0000000..3333333\n" ++
    "--- /dev/null\n" ++
    "+++ b/new.txt\n" ++
    "@@ -0,0 +1 @@\n" ++
    "+hello\n" ++
    "\\ No newline at end of file\n";

test "parseDiff: files, hunks, line kinds and side numbers; a new file has no old path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parseDiff(arenaOf(&a), sample_diff);
    try testing.expectEqual(@as(usize, 2), files.len);
    const f = files[0];
    try testing.expectEqualStrings("src/a.zig", f.path());
    try testing.expectEqual(FileStatus.modified, f.status);
    try testing.expectEqual(@as(usize, 2), f.hunks.len);
    const h = f.hunks[0];
    try testing.expectEqual(@as(u32, 1), h.old_start);
    try testing.expectEqual(@as(u32, 4), h.old_count);
    try testing.expectEqual(@as(u32, 5), h.new_count);
    try testing.expectEqual(@as(usize, 6), h.lines.len);
    try testing.expectEqual(LineKind.context, h.lines[0].kind);
    try testing.expectEqual(LineKind.del, h.lines[1].kind);
    try testing.expectEqualStrings("fn alpha() {}", h.lines[1].text);
    try testing.expectEqual(@as(u32, 2), h.lines[1].old_no.?);
    try testing.expect(h.lines[1].new_no == null);
    try testing.expectEqual(LineKind.add, h.lines[2].kind);
    try testing.expectEqual(@as(u32, 2), h.lines[2].new_no.?);
    try testing.expectEqual(@as(u32, 3), h.lines[3].new_no.?);
    try testing.expectEqual(@as(u32, 4), h.lines[4].new_no.?);
    try testing.expectEqual(@as(u32, 3), h.lines[4].old_no.?);
    try testing.expectEqual(@as(u32, 3), h.changed());
    try testing.expectEqualStrings("@@ -10,2 +11,1 @@ fn tail()", f.hunks[1].header);
    const n = files[1];
    try testing.expectEqual(FileStatus.added, n.status);
    try testing.expect(n.old_path == null);
    try testing.expectEqualStrings("new.txt", n.new_path.?);
    try testing.expectEqual(@as(usize, 2), n.hunks[0].lines.len);
    try testing.expectEqual(LineKind.meta, n.hunks[0].lines[1].kind);
    try testing.expect(parseHunkHeader("@@ -1 +1,2 @@").?.old_count == 1);
    try testing.expect(parseHunkHeader("not a header") == null);
}

test "patchForHunk writes one hunk with recounted ranges and the /dev/null side" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parseDiff(arenaOf(&a), sample_diff);
    const p = try patchForHunk(arenaOf(&a), files[0], 1);
    try testing.expectEqualStrings(
        "diff --git a/src/a.zig b/src/a.zig\n--- a/src/a.zig\n+++ b/src/a.zig\n@@ -10,2 +11,1 @@\n-    gone\n }\n",
        p,
    );
    const q = try patchForHunk(arenaOf(&a), files[1], 0);
    try testing.expect(std.mem.indexOf(u8, q, "new file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+hello\n") != null);
}

test "gutterMarks: added, modified (del then add) and deleted (del with nothing added)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parseDiff(arenaOf(&a), sample_diff);
    const marks = try gutterMarks(arenaOf(&a), files[0]);
    // hunk 1: line 2 modified (alpha→beta), line 3 added (gamma); hunk 2: `gone` removed before new line 11 → deleted mark on line 11.
    try testing.expectEqual(@as(usize, 3), marks.len);
    try testing.expectEqual(MarkKind.modified, marks[0].kind);
    try testing.expectEqual(@as(u32, 1), marks[0].line);
    try testing.expectEqual(MarkKind.added, marks[1].kind);
    try testing.expectEqual(@as(u32, 2), marks[1].line);
    try testing.expectEqual(MarkKind.deleted, marks[2].kind);
    try testing.expectEqual(@as(u32, 10), marks[2].line);
}

test "parseBlame: metadata once per commit, later groups resolve through the sha, uncommitted lines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
    const text =
        sha ++ " 1 1 2\n" ++
        "author alice\n" ++
        "author-mail <a@x>\n" ++
        "author-time 1700000000\n" ++
        "author-tz +0000\n" ++
        "committer alice\n" ++
        "summary initial\n" ++
        "filename code.rs\n" ++
        "\tfn main() {}\n" ++
        sha ++ " 2 2\n" ++
        "\tfn two() {}\n" ++
        "0000000000000000000000000000000000000000 3 3 1\n" ++
        "author Not Committed Yet\n" ++
        "author-time 0\n" ++
        "summary Version of code.rs from code.rs\n" ++
        "\tfn three() {}\n";
    const lines = try parseBlame(arenaOf(&a), text);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("alice", lines[0].author);
    try testing.expectEqualStrings("alice", lines[1].author);
    try testing.expectEqual(@as(i64, 1700000000), lines[1].time);
    try testing.expectEqualStrings("a1b2c3d", lines[1].short());
    try testing.expect(lines[2].isUncommitted());
    try testing.expect(!lines[0].isUncommitted());
    try testing.expectEqualStrings("initial", lines[0].summary);
}

test "parseLog splits records and fields, parents by space" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const text = "aaa\x1fbbb ccc\x1falice\x1f1700000000\x1fHEAD -> main, tag: v1\x1fMerge it\x1e\nbbb\x1f\x1fbob\x1f1600000000\x1f\x1finitial\x1e\n";
    const cs = try parseLog(arenaOf(&a), text);
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqualStrings("aaa", cs[0].hash);
    try testing.expectEqual(@as(usize, 2), cs[0].parents.len);
    try testing.expectEqualStrings("ccc", cs[0].parents[1]);
    try testing.expectEqualStrings("HEAD -> main, tag: v1", cs[0].refs);
    try testing.expectEqualStrings("Merge it", cs[0].subject);
    try testing.expectEqual(@as(usize, 0), cs[1].parents.len);
    try testing.expectEqualStrings("bob", cs[1].author);
    try testing.expectEqual(@as(i64, 1600000000), cs[1].time);
}

test "parseBranches marks the current one, keeps upstream, drops origin/HEAD" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const text = "main\x1f1700000000\x1f*\x1forigin/main\x1fabc1234\nfeature/x\x1f1600000000\x1f \x1f\x1fdef5678\norigin/HEAD\x1f1\x1f \x1f\x1f\norigin/main\x1f1700000000\x1f \x1f\x1fabc1234\n";
    const bs = try parseBranches(arenaOf(&a), text);
    try testing.expectEqual(@as(usize, 3), bs.len);
    try testing.expect(bs[0].current);
    try testing.expectEqualStrings("origin/main", bs[0].upstream);
    try testing.expect(!bs[1].current);
    try testing.expect(!bs[1].remote);
    try testing.expect(bs[2].remote);
}

test "relativeAge buckets" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("30s", relativeAge(&buf, 1000, 1030));
    try testing.expectEqualStrings("5m", relativeAge(&buf, 1000, 1300));
    try testing.expectEqualStrings("2h", relativeAge(&buf, 1, 7201));
    try testing.expectEqualStrings("3d", relativeAge(&buf, 1, 1 + 3 * 86_400));
    try testing.expectEqualStrings("2w", relativeAge(&buf, 1, 1 + 15 * 86_400));
    try testing.expectEqualStrings("4mo", relativeAge(&buf, 1, 1 + 125 * 86_400));
    try testing.expectEqualStrings("2y", relativeAge(&buf, 1, 1 + 800 * 86_400));
    // Unknown time (an uncommitted blame line) paints nothing.
    try testing.expectEqualStrings("", relativeAge(&buf, 0, 5));
}

test "parseTrack reads ahead / behind / gone; a branch line carries them" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = parseTrack("ahead 2, behind 1");
    try testing.expectEqual(@as(u32, 2), t.ahead);
    try testing.expectEqual(@as(u32, 1), t.behind);
    try testing.expect(!t.gone);
    try testing.expect(parseTrack("gone").gone);
    try testing.expectEqual(@as(u32, 0), parseTrack("").ahead);
    const bs = try parseBranches(a.allocator(), "main\x1f10\x1f*\x1forigin/main\x1fabc\x1fahead 3\n");
    try testing.expectEqual(@as(u32, 3), bs[0].ahead);
    try testing.expectEqual(@as(u32, 0), bs[0].behind);
}

test "parsePrs reads gh's JSON" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const prs = try parsePrs(a.allocator(), "[{\"number\":12,\"title\":\"Fix it\",\"headRefName\":\"fix/it\",\"url\":\"https://x/pull/12\"}]");
    try testing.expectEqual(@as(usize, 1), prs.len);
    try testing.expectEqual(@as(u32, 12), prs[0].number);
    try testing.expectEqualStrings("fix/it", prs[0].branch);
    try testing.expectEqual(@as(usize, 0), (try parsePrs(a.allocator(), "not json")).len);
}

test "parseNameStatus keeps the rename's new path and unquotes" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parseNameStatus(a.allocator(), "M\tsrc/a.zig\nR090\told.zig\tnew.zig\nA\t\"sp ace.txt\"\n");
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqual(@as(u8, 'M'), files[0].status);
    try testing.expectEqualStrings("new.zig", files[1].path);
    try testing.expectEqual(@as(u8, 'R'), files[1].status);
    try testing.expectEqualStrings("sp ace.txt", files[2].path);
}

test "parseWorktrees: the first entry is main; a locked one keeps its reason; detached and bare entries have no branch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const text = "worktree /r/ws\nHEAD aaaa\nbranch refs/heads/main\n\nworktree /r/wt-fix\nHEAD bbbb\nbranch refs/heads/fix\nlocked keep me\n\nworktree /r/wt-det\nHEAD cccc\ndetached\nlocked\n\nworktree /r/bare\nbare\n";
    const ws = try parseWorktrees(a.allocator(), text);
    try testing.expectEqual(@as(usize, 4), ws.len);
    try testing.expect(ws[0].main);
    try testing.expectEqualStrings("/r/ws", ws[0].path);
    try testing.expectEqualStrings("main", ws[0].branch);
    try testing.expect(!ws[0].locked);
    try testing.expect(!ws[1].main);
    try testing.expect(ws[1].locked);
    try testing.expectEqualStrings("keep me", ws[1].lock_reason);
    try testing.expectEqualStrings("fix", ws[1].label());
    try testing.expect(ws[2].detached and ws[2].locked);
    try testing.expectEqualStrings("", ws[2].lock_reason);
    try testing.expectEqualStrings("(detached)", ws[2].label());
    try testing.expect(ws[3].bare);
    try testing.expectEqualStrings("(bare)", ws[3].label());
    try testing.expect(!ws[0].dirty);
    // No trailing blank line: the last entry still lands.
    const one = try parseWorktrees(a.allocator(), "worktree /x\nHEAD 1\nbranch refs/heads/b");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("b", one[0].branch);
}

test "parseStashes: sha, ref and the message with its own separators kept" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ss = try parseStashes(a.allocator(), "ab12cd3\x1fstash@{0}\x1fOn main: wip thing\n9f8e7d6\x1fstash@{1}\x1fWIP on fix: 1234567 subject\n");
    try testing.expectEqual(@as(usize, 2), ss.len);
    try testing.expectEqualStrings("ab12cd3", ss[0].sha);
    try testing.expectEqualStrings("stash@{0}", ss[0].ref);
    try testing.expectEqualStrings("On main: wip thing", ss[0].message);
    try testing.expectEqualStrings("stash@{1}", ss[1].ref);
    try testing.expectEqual(@as(usize, 0), (try parseStashes(a.allocator(), "")).len);
}

test "parseTags: an annotated tag peels to its commit, a lightweight one is its own object" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ts = try parseTags(a.allocator(), "v2.0\x1ftag0bj\x1fc0mm1t\nv1.0\x1fl1ght\x1f\n");
    try testing.expectEqual(@as(usize, 2), ts.len);
    try testing.expectEqualStrings("v2.0", ts[0].name);
    try testing.expectEqualStrings("c0mm1t", ts[0].sha);
    try testing.expect(ts[0].annotated);
    try testing.expectEqualStrings("l1ght", ts[1].sha);
    try testing.expect(!ts[1].annotated);
}

test "parseRemotes: one row per remote from the fetch lines, the forge read off the URL" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const rs = try parseRemotes(a.allocator(), "origin\tgit@github.com:me/thing.git (fetch)\norigin\tgit@github.com:me/thing.git (push)\nmirror\thttps://code.example.org/me/thing (fetch)\nmirror\thttps://code.example.org/me/thing (push)\n");
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqualStrings("origin", rs[0].name);
    try testing.expectEqualStrings("git@github.com:me/thing.git", rs[0].url);
    try testing.expectEqual(remote_mod.Provider.github, rs[0].provider);
    try testing.expectEqualStrings("mirror", rs[1].name);
    try testing.expectEqual(remote_mod.Provider.other, rs[1].provider);
}
