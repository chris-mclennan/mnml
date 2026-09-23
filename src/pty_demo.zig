//! pty-demo: a login shell inside a ghostty-vt Terminal, painted onto the
//! real terminal with plain ANSI. The Phase-0 (c) proving ground — it
//! exists to run `ls --color`, `vim`, and `top`, and to survive a window
//! resize, nothing more. There is no UI library here on purpose: the point
//! is to exercise pty → ring → Terminal → RenderState end-to-end.
//!
//! Event loop: one poll(2) over stdin and a self-pipe. The pty reader
//! thread signals "ring became readable" by writing a byte to the pipe
//! (that is the `Notify` hook; in the app it will be the event queue).
//! SIGWINCH's handler writes a different byte. poll() in std retries on
//! EINTR, so a signal alone would never wake the loop — hence the pipe.
//!
//! Keys: everything is forwarded to the shell verbatim; Ctrl-Q quits.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const pty = @import("pty");

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;

const IOCGWINSZ: c_int = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => 0x40087468,
    else => @intCast(c.T.IOCGWINSZ),
};

/// The self-pipe. Global because the SIGWINCH handler has no context.
var wake_pipe: [2]posix.fd_t = .{ -1, -1 };

const wake_readable: u8 = 'r';
const wake_winch: u8 = 'w';

fn wakeWrite(byte: u8) void {
    _ = c.write(wake_pipe[1], &[_]u8{byte}, 1);
}

fn onReadable(_: ?*anyopaque) void {
    wakeWrite(wake_readable);
}

fn onWinch(_: c.SIG) callconv(.c) void {
    wakeWrite(wake_winch);
}

fn hostSize() struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = undefined;
    if (c.ioctl(stdout_fd, IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col > 0 and ws.row > 0)
        return .{ .cols = ws.col, .rows = ws.row };
    return .{ .cols = 80, .rows = 24 };
}

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = c.write(stdout_fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (c.errno(rc) == .INTR) continue;
            return;
        }
        off += @intCast(rc);
    }
}

fn setNonBlocking(fd: posix.fd_t) void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return;
    const nb: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = c.fcntl(fd, posix.F.SETFL, flags | nb);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    if (c.isatty(stdin_fd) == 0 or c.isatty(stdout_fd) == 0) {
        std.debug.print("pty-demo needs a terminal on stdin and stdout\n", .{});
        return error.NotATty;
    }

    // ── self-pipe + SIGWINCH ──
    if (c.pipe(&wake_pipe) != 0) return error.PipeFailed;
    setNonBlocking(wake_pipe[0]);
    setNonBlocking(wake_pipe[1]);
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &sa, null);

    // ── raw mode + alt screen ──
    const saved = try posix.tcgetattr(stdin_fd);
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.oflag.OPOST = false;
    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer posix.tcsetattr(stdin_fd, .FLUSH, saved) catch {};
    writeAll("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
    defer writeAll("\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?1049l");

    // ── the session ──
    var size = hostSize();
    const argv = try collectArgs(gpa, init);
    defer if (argv) |a| gpa.free(a);
    const session = try pty.Session.spawn(gpa, io, .{
        .cols = size.cols,
        .rows = size.rows,
        .env = init.environ_map,
        .argv = argv,
        .notify = .{ .fn_ptr = onReadable },
    });
    defer session.deinit();

    var grid: pty.Grid = .{};
    defer grid.deinit(gpa);
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();

    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = wake_pipe[0], .events = posix.POLL.IN, .revents = 0 },
    };
    var input: [4096]u8 = undefined;
    var full_repaint = true;
    var exit_report: ?pty.session.Exit = null;
    defer if (exit_report) |exit| switch (exit) {
        .code => |code| std.debug.print("pty-demo: child exited with code {d}\n", .{code}),
        .signal => |sig| std.debug.print("pty-demo: child killed by signal {d}\n", .{sig}),
    };

    while (true) {
        // A 16 ms floor coalesces bursts into frames; a 250 ms ceiling
        // makes sure a missed edge never freezes the screen.
        _ = try posix.poll(&fds, 250);

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(stdin_fd, &input) catch 0;
            if (n == 0) break;
            const bytes = input[0..n];
            if (std.mem.indexOfScalar(u8, bytes, 0x11) != null) break; // Ctrl-Q
            session.write(bytes);
        }
        if (fds[1].revents & posix.POLL.IN != 0) {
            var drain: [64]u8 = undefined;
            var winch = false;
            while (true) {
                const n = posix.read(wake_pipe[0], &drain) catch 0;
                if (n == 0) break;
                if (std.mem.indexOfScalar(u8, drain[0..n], wake_winch) != null) winch = true;
            }
            if (winch) {
                const now = hostSize();
                if (now.cols != size.cols or now.rows != size.rows) {
                    size = now;
                    try session.resize(size.cols, size.rows);
                    writeAll("\x1b[H\x1b[2J");
                    full_repaint = true;
                }
            }
        }

        _ = session.pump();
        if (session.exited()) |exit| {
            exit_report = exit;
            break;
        }

        try grid.update(gpa, session.terminal());
        if (grid.dirty() or full_repaint) {
            frame.clearRetainingCapacity();
            try paint(&frame.writer, &grid, full_repaint);
            writeAll(frame.written());
            grid.markClean();
            full_repaint = false;
        }
    }
}

/// Anything after `pty-demo` on the command line is the program to run;
/// with nothing there the session picks the login shell.
fn collectArgs(gpa: std.mem.Allocator, init: std.process.Init) !?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it: std.process.Args.Iterator = .init(init.minimal.args);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |a| try list.append(gpa, a);
    if (list.items.len == 0) {
        list.deinit(gpa);
        return null;
    }
    return try list.toOwnedSlice(gpa);
}

// ── painter ─────────────────────────────────────────────────────────

const Pen = struct {
    fg: pty.grid.Color = .default,
    bg: pty.grid.Color = .default,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    underline: pty.grid.Underline = .none,

    fn fromCell(cell: pty.grid.Cell) Pen {
        return .{
            .fg = cell.fg,
            .bg = cell.bg,
            .bold = cell.bold,
            .italic = cell.italic,
            .faint = cell.faint,
            .inverse = cell.inverse,
            .strikethrough = cell.strikethrough,
            .underline = cell.underline,
        };
    }

    fn eql(a: Pen, b: Pen) bool {
        return std.meta.eql(a, b);
    }
};

fn paint(w: *std.Io.Writer, grid: *const pty.Grid, all: bool) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l"); // synchronized update, hide cursor while drawing
    var y: u16 = 0;
    while (y < grid.rows()) : (y += 1) {
        if (!all and !grid.rowDirty(y)) continue;
        try w.print("\x1b[{d};1H\x1b[0m", .{y + 1});
        var pen: Pen = .{};
        var x: u16 = 0;
        while (x < grid.cols()) : (x += 1) {
            const cell = grid.cell(x, y);
            if (cell.wide == .spacer_tail) continue; // the wide glyph covers it
            const want = Pen.fromCell(cell);
            if (!want.eql(pen)) {
                try writeSgr(w, want);
                pen = want;
            }
            if (cell.grapheme.len > 0) {
                try writeCp(w, cell.cp);
                for (cell.grapheme) |cp| try writeCp(w, cp);
            } else if (cell.cp == 0) {
                try w.writeByte(' ');
            } else {
                try writeCp(w, cell.cp);
            }
        }
        try w.writeAll("\x1b[0m\x1b[K");
    }
    if (grid.cursor()) |cur| {
        const x = if (cur.wide_tail and cur.x > 0) cur.x - 1 else cur.x;
        const shape: u8 = switch (cur.shape) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        };
        try w.print("\x1b[{d};{d}H\x1b[{d} q\x1b[?25h", .{ cur.y + 1, x + 1, shape });
    }
    try w.writeAll("\x1b[?2026l");
}

fn writeCp(w: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try w.writeByte('?');
        return;
    };
    try w.writeAll(buf[0..n]);
}

fn writeSgr(w: *std.Io.Writer, p: Pen) !void {
    try w.writeAll("\x1b[0");
    if (p.bold) try w.writeAll(";1");
    if (p.faint) try w.writeAll(";2");
    if (p.italic) try w.writeAll(";3");
    switch (p.underline) {
        .none => {},
        .single => try w.writeAll(";4"),
        .double => try w.writeAll(";4:2"),
        .curly => try w.writeAll(";4:3"),
        .dotted => try w.writeAll(";4:4"),
        .dashed => try w.writeAll(";4:5"),
    }
    if (p.inverse) try w.writeAll(";7");
    if (p.strikethrough) try w.writeAll(";9");
    try writeColor(w, p.fg, 30);
    try writeColor(w, p.bg, 40);
    try w.writeByte('m');
}

/// `base` is 30 for foreground, 40 for background.
fn writeColor(w: *std.Io.Writer, color: pty.grid.Color, base: u8) !void {
    switch (color) {
        .default => try w.print(";{d}", .{base + 9}),
        .palette => |i| if (i < 8) {
            try w.print(";{d}", .{base + i});
        } else if (i < 16) {
            try w.print(";{d}", .{base + 60 + (i - 8)});
        } else {
            try w.print(";{d};5;{d}", .{ base + 8, i });
        },
        .rgb => |v| try w.print(";{d};2;{d};{d};{d}", .{ base + 8, v.r, v.g, v.b }),
    }
}
