//! `mnml-fake-bitbucket` — a deterministic Bitbucket Cloud on the
//! loopback, so the pane can be driven end to end with no network, no
//! account and no token that matters. The workspace it serves is in
//! `server.zig`.
//!
//!   mnml-fake-bitbucket                       port 0 (the OS picks), URL on stdout
//!   mnml-fake-bitbucket --port 8765           a fixed port
//!   mnml-fake-bitbucket --url-file bb.url     also write the URL there, once listening
//!   mnml-fake-bitbucket --lifetime-secs 60    exit after a minute, whatever happens
//!   mnml-fake-bitbucket --rate-limit-first 2  429 the first two requests
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
    var rate_limit_first: u32 = 0;

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
        } else if (std.mem.eql(u8, a, "--lifetime-secs") and i + 1 < args.len) {
            i += 1;
            lifetime_secs = std.fmt.parseInt(u64, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate-limit-first") and i + 1 < args.len) {
            i += 1;
            rate_limit_first = std.fmt.parseInt(u32, args[i], 10) catch 0;
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

    if (lifetime_secs == 0) {
        // No lifetime: serve until the process is killed.
        while (true) io.sleep(.fromMilliseconds(1000), .awake) catch break;
    } else {
        var left = lifetime_secs;
        while (left > 0) : (left -= 1) io.sleep(.fromMilliseconds(1000), .awake) catch break;
    }
    return 0;
}

const usage =
    \\mnml-fake-bitbucket — a deterministic Bitbucket Cloud on the loopback.
    \\
    \\  --port N              listen here (default 0: the OS picks)
    \\  --url-file PATH       write the base URL there once listening
    \\  --lifetime-secs N     exit after N seconds (default: never)
    \\  --rate-limit-first N  answer the first N requests with 429
    \\
    \\Point the integration at it with BITBUCKET_BASE_URL=<url>, or
    \\BITBUCKET_BASE_URL=@<path> to read the --url-file.
    \\
;

test {
    _ = listener;
    _ = @import("server.zig");
}
