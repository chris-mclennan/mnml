//! `mnml-fake-bitbucket` — a deterministic Bitbucket Cloud on the
//! loopback, so the pane can be driven end to end with no network, no
//! account and no token that matters. The workspace it serves is in
//! `server.zig`.
//!
//!   mnml-fake-bitbucket                       port 0 (the OS picks), URL on stdout
//!   mnml-fake-bitbucket --port 8765           a fixed port
//!   mnml-fake-bitbucket --url-file bb.url     also write the URL there, once listening
//!   mnml-fake-bitbucket --lifetime-secs 60    exit after a minute, whatever happens
//!   mnml-fake-bitbucket --parent-pid 1234     exit when 1234 is gone
//!   mnml-fake-bitbucket --rate-limit-first 2  429 the first two requests
//!   mnml-fake-bitbucket --retry-after 8       …with `Retry-After: 8` (0: none)
//!   mnml-fake-bitbucket --rate-limit-limit 1000 --rate-limit-remaining 900
//!                                             `X-RateLimit-*` on every answer
//!   mnml-fake-bitbucket --log-file bb.jsonl   a JSON line per request served
//!   mnml-fake-bitbucket --delay-ms 3000       hold every reply three seconds
//!   mnml-fake-bitbucket --gzip                gzip an answer whose request offered gzip
//!   mnml-fake-bitbucket --gzip-always         gzip every answer, whatever was offered
//!
//! The lifetime is what makes it safe in a test script: a run that
//! fails half way still leaves nothing behind. The pane reaches it
//! through `BITBUCKET_BASE_URL` — literally, or as `@<path>` naming the
//! `--url-file`.

const std = @import("std");
const Io = std.Io;
const listener = @import("listener.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var port: u16 = 0;
    var url_file: ?[]const u8 = null;
    var lifetime_secs: u64 = 0;
    var parent_pid: i32 = 0;
    var rate_limit_first: u32 = 0;
    var log_file: ?[]const u8 = null;
    var extra_prs: u32 = 0;
    var link_ranges = false;
    var delay_ms: u32 = 0;
    var gzip: @import("server.zig").Gzip = .off;
    var retry_after: ?u32 = null;
    var budget_limit: u32 = 0;
    var budget_remaining: ?u32 = null;

    var i: usize = 1;
    var out_buf: [512]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &out_w.interface;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--url-file") and i + 1 < args.len) {
            i += 1;
            url_file = args[i];
        } else if (std.mem.eql(u8, a, "--link-ranges")) {
            link_ranges = true;
        } else if (std.mem.eql(u8, a, "--extra-prs") and i + 1 < args.len) {
            i += 1;
            extra_prs = std.fmt.parseInt(u32, args[i], 10) catch 0;
            // The tracker's fake spells the deadline `--life-secs`; a
            // test script should not have to remember which is which.
        } else if ((std.mem.eql(u8, a, "--lifetime-secs") or std.mem.eql(u8, a, "--life-secs")) and i + 1 < args.len) {
            i += 1;
            lifetime_secs = std.fmt.parseInt(u64, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--parent-pid") and i + 1 < args.len) {
            i += 1;
            parent_pid = std.fmt.parseInt(i32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate-limit-first") and i + 1 < args.len) {
            i += 1;
            rate_limit_first = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--retry-after") and i + 1 < args.len) {
            i += 1;
            retry_after = std.fmt.parseInt(u32, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, a, "--rate-limit-limit") and i + 1 < args.len) {
            i += 1;
            budget_limit = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate-limit-remaining") and i + 1 < args.len) {
            i += 1;
            budget_remaining = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--log-file") and i + 1 < args.len) {
            i += 1;
            log_file = args[i];
        } else if (std.mem.eql(u8, a, "--gzip")) {
            gzip = .when_asked;
        } else if (std.mem.eql(u8, a, "--gzip-always")) {
            gzip = .always;
        } else if (std.mem.eql(u8, a, "--delay-ms") and i + 1 < args.len) {
            i += 1;
            delay_ms = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else {
            try stdout.print("mnml-fake-bitbucket: unknown argument `{s}`\n\n{s}", .{ a, usage });
            try stdout.flush();
            return 2;
        }
    }

    const srv = listener.Server.start(gpa, io, port) catch |err| {
        try stdout.print("mnml-fake-bitbucket: could not listen: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return 1;
    };
    defer srv.stop();
    if (rate_limit_first > 0) srv.rateLimitNext(rate_limit_first);
    if (retry_after) |ra| srv.retryAfter(ra);
    if (budget_limit > 0) srv.budgetHeaders(budget_limit, budget_remaining orelse budget_limit);
    if (extra_prs > 0) srv.setExtraPrs(extra_prs);
    if (link_ranges) srv.setLinkRanges(true);
    srv.delay_ms = delay_ms;
    srv.gzipAnswers(gzip);
    // A fresh log per run: the measurement is one tab load's worth, not
    // everything this file has ever seen.
    if (log_file) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "" }) catch {};
        srv.log_path = p;
    }

    const base = try srv.baseUrl(gpa);
    defer gpa.free(base);
    if (url_file) |p| {
        if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = base }) catch |err| {
            try stdout.print("mnml-fake-bitbucket: could not write {s}: {s}\n", .{ p, @errorName(err) });
            try stdout.flush();
            return 1;
        };
    }
    try stdout.print("{s}\n", .{base});
    try stdout.flush();

    // The deadline, and the other way a run ends: a server whose starter
    // is gone is an orphan holding a port, so it goes too — that is what
    // a killed test run leaves behind otherwise.
    var left: u64 = if (lifetime_secs == 0) std.math.maxInt(u64) else lifetime_secs;
    while (left > 0) : (left -= 1) {
        io.sleep(.fromMilliseconds(1000), .awake) catch break;
        if (orphaned(parent_pid)) break;
    }
    return 0;
}

/// True when the process named by `--parent-pid` is gone. Signal 0 is
/// the POSIX liveness probe: it delivers nothing and answers ESRCH when
/// there is nobody there.
fn orphaned(parent_pid: i32) bool {
    if (parent_pid <= 0) return false;
    if (@import("builtin").os.tag == .windows) return false;
    const rc = std.c.kill(parent_pid, @enumFromInt(0));
    return rc != 0 and std.c._errno().* == @intFromEnum(std.c.E.SRCH);
}

const usage =
    \\mnml-fake-bitbucket — a deterministic Bitbucket Cloud on the loopback.
    \\
    \\  --port N              listen here (default 0: the OS picks)
    \\  --url-file PATH       write the base URL there once listening
    \\  --lifetime-secs N     exit after N seconds (default: never; --life-secs also works)
    \\  --link-ranges         PRs and pipelines numbered in a range per repo (bare-number links)
    \\  --extra-prs N         N more generated OPEN pull requests on acme/api
    \\  --parent-pid N        exit when that process is gone (an orphan holds a port)
    \\  --rate-limit-first N  answer the first N requests with 429
    \\  --retry-after N       the Retry-After those 429s carry (default 1; 0 sends none)
    \\  --rate-limit-limit N  send X-RateLimit-Limit/-Remaining/-NearLimit on every answer
    \\  --rate-limit-remaining N  where -Remaining starts (default: the limit); it drops one per request
    \\  --log-file PATH       append one JSON line per request served
    \\  --delay-ms N          hold every reply N ms (catch a pane mid-fetch)
    \\  --gzip                gzip an answer whose request's Accept-Encoding offers gzip
    \\  --gzip-always         gzip every answer, whatever the request offered (a proxy's habit)
    \\
    \\Point the integration at it with BITBUCKET_BASE_URL=<url>, or
    \\BITBUCKET_BASE_URL=@<path> to read the --url-file.
    \\
;

test {
    _ = listener;
    _ = @import("server.zig");
}
