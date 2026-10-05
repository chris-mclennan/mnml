//! Where `std.log` goes (`std_options.logFn` in `main.zig`).
//!
//! Out of the TUI — a CLI subcommand, `test`, `--headless` — it is
//! stderr, as std's default. While the TUI owns the terminal, stderr IS
//! the screen mnml paints: a library's log line (ghostty-vt says
//! `unknown DCS hook` for vim's start-up queries, `unknown CSI m with
//! intermediate` for others) would land over the tree and the panes and
//! stay until those cells change. So `toFile` sends every line to
//! `mnml.log` in the data root instead, and `restore` hands stderr back
//! once the terminal is itself again. A log that cannot be opened is
//! dropped — never the screen.

const std = @import("std");
const repeat = @import("mnml_sdk").zig_compat.repeat;
const Io = std.Io;

pub const file_name = "mnml.log";

var redirected: std.atomic.Value(bool) = .init(false);
/// Written only while `redirected` is false (before `toFile` flips it,
/// after `restore` does), read only under the stderr lock.
var sink: ?Io.File = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!redirected.load(.acquire)) return std.log.defaultLog(level, scope, format, args);
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    // The stderr lock is the one every logging thread already agrees on.
    var lock_buf: [8]u8 = undefined;
    _ = std.debug.lockStderr(&lock_buf);
    defer std.debug.unlockStderr();
    const file = sink orelse return;
    var line: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&line);
    render(&w, level, scope, format, args);
    file.writeStreamingAll(io, w.buffered()) catch {};
}

/// `level(scope): message\n`, what std's default prints, cut short with
/// `…` rather than dropped when it does not fit the line buffer.
fn render(w: *Io.Writer, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const prefix = comptime level.asText() ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")") ++ ": ";
    w.writeAll(prefix) catch {};
    w.print(format, args) catch {
        const tail = "…";
        w.end = @min(w.end, w.buffer.len - tail.len - 1);
        w.writeAll(tail) catch {};
    };
    w.writeByte('\n') catch {};
}

/// From here on every line goes to `<data_root>/mnml.log` (a fresh one
/// each launch), or nowhere when it cannot be made.
pub fn toFile(data_root: []const u8) void {
    const io = std.Options.debug_io;
    sink = open(io, data_root);
    redirected.store(true, .release);
}

fn open(io: Io, data_root: []const u8) ?Io.File {
    if (data_root.len == 0) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ data_root, std.fs.path.sep, file_name }) catch return null;
    Io.Dir.cwd().createDirPath(io, data_root) catch return null;
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch null;
}

/// Stderr again. Called once the terminal is out of the TUI.
pub fn restore() void {
    const io = std.Options.debug_io;
    var lock_buf: [8]u8 = undefined;
    _ = std.debug.lockStderr(&lock_buf);
    redirected.store(false, .release);
    const file = sink;
    sink = null;
    std.debug.unlockStderr();
    if (file) |f| f.close(io);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "while redirected a log line goes to mnml.log in the data root, never stderr; restore closes it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    toFile(root);
    logFn(.warn, .stream, "unknown CSI m with intermediate: {d}", .{37});
    logFn(.info, .default, "plain", .{});
    restore();
    const text = try tmp.dir.readFileAlloc(t.io, file_name, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expectEqualStrings("warning(stream): unknown CSI m with intermediate: 37\ninfo: plain\n", text);
}

test "a line longer than the buffer is cut, not lost" {
    var line: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&line);
    render(&w, .err, .x, "{s}", .{repeat("y", 200)});
    const out = w.buffered();
    try t.expect(std.mem.startsWith(u8, out, "error(x): yyy"));
    try t.expect(std.mem.endsWith(u8, out, "…\n"));
}
