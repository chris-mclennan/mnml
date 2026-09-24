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
//! the corpus must be `0`. The runner's own `serve` mocks are held to
//! the same rule: `serve 0`, and the file names the port the runner
//! bound as `${SERVE_PORT}`.
//!
//! The same scan catches the other ways a file reaches past itself to
//! something every other run on the machine shares (`docs/TESTING-
//! hermetic.md`): a `# env:` value under `/tmp`, a header that leans on
//! the runner's `$PWD`, and a `shell` step that looks at, or kills,
//! processes machine-wide (`pkill`, `killall`, `ps -ax`, `pgrep` without
//! `-P`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

/// One offence: the file, the line number, and the line.
pub const Offence = struct {
    file: []const u8,
    line: usize,
    text: []const u8,
    why: Why = .fixed_port,
};

/// What an offending line shares with every other run on the machine.
pub const Why = enum {
    /// `--port N` / `serve N` with N a literal other than 0.
    fixed_port,
    /// A `# env:` value naming a path under `/tmp`.
    shared_tmp,
    /// A `# env:` value built from the runner's `$PWD`.
    runner_pwd,
    /// `pkill` / `killall` / `ps -ax` / `pgrep` without `-P`.
    machine_wide_process,

    pub fn hint(w: Why) []const u8 {
        return switch (w) {
            .fixed_port => "a fixed port — use `--port 0 --url-file <file>` (read back with `# env: JIRA_BASE_URL=@${MNML_E2E_WORKSPACE}/<file>`), or `serve 0` and `${SERVE_PORT}`",
            .shared_tmp => "a path under /tmp that every run shares — put it under ${MNML_E2E_WORKSPACE} or the file's $MNML_DATA_ROOT",
            .runner_pwd => "the runner's $PWD — a shell sets it and an `env -i` run has none; use $MNML_REPO",
            .machine_wide_process => "a machine-wide process lookup or kill — scope it to the file's own process group ($MNML_AGENTS_PGID) or a pid the file wrote",
        };
    }
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
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "# env:")) {
            const value = if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| trimmed[eq + 1 ..] else "";
            if (std.mem.startsWith(u8, value, "/tmp/") or std.mem.indexOf(u8, value, ":/tmp/") != null)
                try out.offences.append(arena, .{ .file = path, .line = n, .text = line, .why = .shared_tmp });
            if (std.mem.indexOf(u8, value, "${PWD}") != null or std.mem.indexOf(u8, value, "$PWD") != null)
                try out.offences.append(arena, .{ .file = path, .line = n, .text = line, .why = .runner_pwd });
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "serve ")) {
            var sw = std.mem.tokenizeAny(u8, trimmed, " \t");
            _ = sw.next();
            const v = std.fmt.parseInt(u32, sw.next() orelse "", 10) catch continue;
            if (v == 0) out.dynamic += 1 else try out.offences.append(arena, .{ .file = path, .line = n, .text = line });
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "shell ") and machineWide(trimmed))
            try out.offences.append(arena, .{ .file = path, .line = n, .text = line, .why = .machine_wide_process });
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

/// A `shell` line that finds or signals processes across the whole
/// machine rather than its own.
fn machineWide(line: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, line, " \t;&|()$`");
    var prev: []const u8 = "";
    while (words.next()) |w| {
        defer prev = w;
        if (std.mem.eql(u8, w, "pkill") or std.mem.eql(u8, w, "killall")) return true;
        if (std.mem.eql(u8, prev, "ps") and w.len > 1 and w[0] == '-' and
            (std.mem.indexOfAny(u8, w[1..], "Aaxe") != null)) return true;
        if (std.mem.eql(u8, prev, "ps") and std.mem.eql(u8, w, "aux")) return true;
        if (std.mem.eql(u8, w, "pgrep") and std.mem.indexOf(u8, line, "pgrep -P") == null and std.mem.indexOf(u8, line, "pgrep -lP") == null) return true;
    }
    return false;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "no .test script reaches a resource another run shares: a fixed port, /tmp, $PWD, machine-wide processes" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const got = try scan(arena, testing.io, build_options.e2e_corpus_dir);

    // The scan is only evidence if it actually read the corpus.
    try testing.expect(got.files > 100);
    try testing.expect(got.dynamic > 0);

    if (got.offences.items.len > 0) {
        for (got.offences.items) |o| {
            std.debug.print("{s}:{d}: {s}\n  {s}\n", .{ o.file, o.line, o.why.hint(), std.mem.trim(u8, o.text, " \t\r") });
        }
        return error.SharedResourceInCorpus;
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
    // `serve 19893` is an offence too now: `serve 0` and `${SERVE_PORT}`.
    try testing.expectEqual(@as(usize, 3), out.offences.items.len);
    try testing.expectEqual(@as(usize, 3), out.offences.items[0].line);
    try testing.expectEqual(@as(usize, 4), out.offences.items[1].line);
    try testing.expectEqual(@as(usize, 5), out.offences.items[2].line);
}

test "the scan names a shared /tmp, the runner's $PWD, and a machine-wide process lookup — and lets their scoped forms through" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var out: Scan = .{};
    try scanText(arena, "x.test",
        \\# env: JIRA_BROKER_SOCKET=/tmp/mnml-e2e-broker-jira.sock
        \\# env: MNML_REPO=${PWD}
        \\# env: HOME=${MNML_E2E_WORKSPACE}/home
        \\serve 0 200 @echo
        \\shell pkill -f -- "--resume e2e0"
        \\shell r=$(ps -axo pid=,command= | grep claude)
        \\shell r=$(ps -o rss= -p $PPID)
        \\shell kill "$(cat fake-jira.pid)"
        \\shell pgrep -lP $$
        \\shell pgrep claude
    , &out);
    try testing.expectEqual(@as(usize, 1), out.dynamic);
    const want = [_]struct { line: usize, why: Why }{
        .{ .line = 1, .why = .shared_tmp },
        .{ .line = 2, .why = .runner_pwd },
        .{ .line = 5, .why = .machine_wide_process },
        .{ .line = 6, .why = .machine_wide_process },
        .{ .line = 10, .why = .machine_wide_process },
    };
    try testing.expectEqual(want.len, out.offences.items.len);
    for (want, out.offences.items) |w, o| {
        try testing.expectEqual(w.line, o.line);
        try testing.expectEqual(w.why, o.why);
    }
}
