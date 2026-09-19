//! A guard over the corpus itself, rather than over what it drives.
//!
//! A `.test` script that starts a fake server on a port somebody chose
//! works perfectly — alone. Two of them at once do not: a second copy of
//! the corpus, running in another worktree or another CI shard, finds
//! the port taken and the script fails somewhere far from the cause.
//! Both fakes take `--port 0` and write where they landed
//! (`--url-file`), and the panes read that file back
//! (`JIRA_BASE_URL=@<path>`, `BITBUCKET_BASE_URL=@<path>`), so no script
//! needs a number at all.
//!
//! The rule is mechanical, so it is a test: every `--port` argument in
//! the corpus must be `0`. The runner's own `serve <port>` mocks are not
//! in scope — those are in-process servers whose port the script has to
//! name in a URL it writes, and no fake server is behind them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

/// One offence: the file, the line number, and the line.
pub const Offence = struct {
    file: []const u8,
    line: usize,
    text: []const u8,
};

pub const Scan = struct {
    files: usize = 0,
    /// `--port 0` sightings — the proof the scan read the lines it
    /// claims to have read, so an empty offence list means something.
    dynamic: usize = 0,
    offences: std.ArrayListUnmanaged(Offence) = .empty,
};

/// Every `--port N` in `path`'s `.test` files, recursively. Errors are
/// the caller's to fail on: a corpus that cannot be read is not a pass.
pub fn scan(arena: Allocator, io: Io, root: []const u8) !Scan {
    var out: Scan = .{};
    try scanDir(arena, io, root, &out, 0);
    return out;
}

fn scanDir(arena: Allocator, io: Io, dir: []const u8, out: *Scan, depth: u8) !void {
    if (depth > 8) return;
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        const path = try std.fs.path.join(arena, &.{ dir, entry.name });
        if (entry.kind == .directory) {
            try scanDir(arena, io, path, out, depth + 1);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".test")) continue;
        out.files += 1;
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20));
        try scanText(arena, path, text, out);
    }
}

fn scanText(arena: Allocator, path: []const u8, text: []const u8, out: *Scan) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        var want_port = false;
        while (words.next()) |w| {
            if (want_port) {
                want_port = false;
                // `--port "$SOMETHING"` is not a literal, so it is not
                // this guard's business; a number that is not 0 is.
                const v = std.fmt.parseInt(u32, std.mem.trim(u8, w, "\"'"), 10) catch continue;
                if (v == 0) out.dynamic += 1 else try out.offences.append(arena, .{ .file = path, .line = n, .text = line });
                continue;
            }
            // `--port N`, not `--port-file P`.
            if (std.mem.eql(u8, w, "--port")) want_port = true;
            if (std.mem.startsWith(u8, w, "--port=")) {
                const v = std.fmt.parseInt(u32, std.mem.trim(u8, w["--port=".len..], "\"'"), 10) catch continue;
                if (v == 0) out.dynamic += 1 else try out.offences.append(arena, .{ .file = path, .line = n, .text = line });
            }
        }
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "no .test script starts a fake server on a port it chose" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const got = try scan(arena, testing.io, build_options.e2e_corpus_dir);

    // The scan is only evidence if it actually read the corpus.
    try testing.expect(got.files > 100);
    try testing.expect(got.dynamic > 0);

    if (got.offences.items.len > 0) {
        for (got.offences.items) |o| {
            std.debug.print(
                "{s}:{d}: a fake server on a fixed port — use `--port 0 --url-file <file>` and read it back with\n  # env: JIRA_BASE_URL=@${{MNML_E2E_WORKSPACE}}/<file>   (or BITBUCKET_BASE_URL)\n  {s}\n",
                .{ o.file, o.line, std.mem.trim(u8, o.text, " \t\r") },
            );
        }
        return error.FixedPortInCorpus;
    }
}

test "the scan reads a literal port wherever the argument is spelled, and a comment never counts" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var out: Scan = .{};
    try scanText(arena, "x.test",
        \\# shell "$MNML_FAKE_JIRA" --port 18722
        \\shell "$MNML_FAKE_JIRA" --port 0 --url-file jira.url &
        \\shell "$MNML_FAKE_BITBUCKET" --port-file p --port=8080 &
        \\serve 19893 200 "late"
        \\shell "$MNML_FAKE_JIRA" --port 18722 &
    , &out);
    try testing.expectEqual(@as(usize, 1), out.dynamic);
    try testing.expectEqual(@as(usize, 2), out.offences.items.len);
    try testing.expectEqual(@as(usize, 3), out.offences.items[0].line);
    try testing.expectEqual(@as(usize, 5), out.offences.items[1].line);
}
