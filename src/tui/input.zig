//! Terminal input as a worker: bytes from the tty → `vaxis.Parser` →
//! `std.Io.Queue(vaxis.Event)`. A second task turns SIGWINCH into
//! `.winsize` events through a self-pipe, so the signal handler does one
//! async-signal-safe `write` and never touches a lock (vaxis's own handler
//! takes an `Io.Mutex` inside the signal — we do not use it).
//!
//! Both tasks live in one `Io.Group`; `stop` cancels the group, which makes
//! `Io.Threaded` interrupt the blocked reads. Capability replies from the
//! probe are folded into `*vaxis.Vaxis` by `fold`, which mirrors upstream's
//! `Loop.handleEventGeneric` prong for prong — that function cannot be
//! analyzed under `zig test` on macOS (vaxis 0.6.0's non-Linux `TestTty`
//! has no `resetSignalHandler`), and owning the fold makes it testable.
//!
//! Terminals without mode 2048 (Terminal.app) resize via the pipe; ghostty
//! reports in-band and the pipe path is skipped once vaxis has seen one.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const Io = std.Io;
const posix = std.posix;

pub const Event = vaxis.Event;
pub const Key = vaxis.Key;

const Input = @This();

const queue_len = 256;

io: Io,
gpa: std.mem.Allocator,
vx: *vaxis.Vaxis,
/// Where key bytes come from: stdin when it is a tty, else /dev/tty.
tty: Io.File,
buffer: [queue_len]Event = undefined,
queue: Io.Queue(Event),
group: Io.Group = .init,
cache: vaxis.GraphemeCache = .{},
winch_pipe: [2]posix.fd_t = .{ -1, -1 },
old_winch: ?posix.Sigaction = null,
started: bool = false,

/// The write end of the self-pipe, read by the signal handler.
var winch_fd: std.atomic.Value(posix.fd_t) = .init(-1);

/// Intrusive: the queue points at `self.buffer`, so `self` must not move.
pub fn init(self: *Input, io: Io, gpa: std.mem.Allocator, vx: *vaxis.Vaxis, tty: Io.File) void {
    self.* = .{
        .io = io,
        .gpa = gpa,
        .vx = vx,
        .tty = tty,
        .queue = undefined,
    };
    self.queue = .init(&self.buffer);
}

/// Spawns the reader and the resize task. Call BEFORE `queryTerminal`: the
/// probe blocks on a futex that only the reader wakes (on DA1).
pub fn start(self: *Input) !void {
    if (self.started) return;
    if (std.c.pipe(&self.winch_pipe) != 0) return error.PipeFailed;
    winch_fd.store(self.winch_pipe[1], .release);

    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleWinch },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            else => posix.sigemptyset(),
        },
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.WINCH, &act, &old);
    self.old_winch = old;

    try self.group.concurrent(self.io, readerTask, .{self});
    try self.group.concurrent(self.io, winchTask, .{self});
    self.started = true;
}

/// Cancels both tasks (interrupting their blocked reads) and restores the
/// SIGWINCH disposition. Safe to call twice.
pub fn stop(self: *Input) void {
    if (!self.started) return;
    self.started = false;
    self.group.cancel(self.io);
    if (self.old_winch) |*old| posix.sigaction(posix.SIG.WINCH, old, null);
    winch_fd.store(-1, .release);
    for (self.winch_pipe) |fd| {
        if (fd >= 0) (Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(self.io);
    }
    self.winch_pipe = .{ -1, -1 };
}

/// Called by `handleEventGeneric` for every event it decides to deliver.
pub fn postEvent(self: *Input, event: Event) !void {
    try self.queue.putOne(self.io, event);
}

/// Blocks for the next event.
pub fn next(self: *Input) (Io.QueueClosedError || Io.Cancelable)!Event {
    return self.queue.getOne(self.io);
}

/// Drains whatever is queued without blocking. Returns the count.
pub fn drain(self: *Input, buf: []Event) (Io.QueueClosedError || Io.Cancelable)!usize {
    return self.queue.get(self.io, buf, 0);
}

pub fn getWinsize(self: *Input) !vaxis.Winsize {
    return winsizeOf(self.tty.handle);
}

pub fn winsizeOf(fd: posix.fd_t) !vaxis.Winsize {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return error.IoctlError;
    return .{ .rows = ws.row, .cols = ws.col, .x_pixel = ws.xpixel, .y_pixel = ws.ypixel };
}

fn handleWinch(_: posix.SIG) callconv(.c) void {
    const fd = winch_fd.load(.acquire);
    if (fd < 0) return;
    _ = std.c.write(fd, "w", 1);
}

fn readerTask(self: *Input) Io.Cancelable!void {
    // The initial size, like vaxis's loop, so the app can allocate its screen.
    if (self.getWinsize()) |ws| {
        self.postEvent(.{ .winsize = ws }) catch |err| return mapQueueErr(err);
    } else |_| {}

    var parser: vaxis.Parser = .{};
    var buf: [1024]u8 = undefined;
    var carry: usize = 0;
    while (true) {
        const n = self.tty.readStreaming(self.io, &.{buf[carry..]}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        if (n == 0) return;
        const total = carry + n;
        var pos: usize = 0;
        while (pos < total) {
            const result = parser.parse(buf[pos..total], self.gpa) catch {
                // Unparseable garbage: drop one byte and carry on.
                pos += 1;
                continue;
            };
            if (result.n == 0) {
                // Incomplete sequence: keep the tail for the next read.
                std.mem.copyForwards(u8, buf[0 .. total - pos], buf[pos..total]);
                carry = total - pos;
                break;
            }
            pos += result.n;
            const event = result.event orelse continue;
            self.fold(event) catch |err| return mapQueueErr(err);
        } else {
            carry = 0;
        }
    }
}

/// One parsed event: capability replies update `vx`, everything else is
/// posted. `key.text` points into the parser's read buffer, so it is
/// copied into the grapheme ring before the event leaves this thread.
fn fold(self: *Input, event: Event) !void {
    const vx = self.vx;
    switch (event) {
        .key_press => |key| {
            // The explicit-width / scaled-text probes end in a cursor
            // position report, which parses as shift+F3 / alt+F3 while the
            // queries are outstanding (column 2 or 3 ⇒ the OSC 66 moved
            // the cursor). Never deliver those as keys.
            if (key.codepoint == Key.f3 and !vx.queries_done.load(.unordered)) {
                if (key.mods.shift) {
                    vx.caps.explicit_width = true;
                    vx.caps.unicode = .unicode;
                    vx.screen.width_method = .unicode;
                    return;
                }
                if (key.mods.alt) {
                    vx.caps.scaled_text = true;
                    return;
                }
            }
            try self.postEvent(.{ .key_press = self.cacheText(key) });
        },
        .key_release => |key| try self.postEvent(.{ .key_release = self.cacheText(key) }),
        .mouse => |mouse| try self.postEvent(.{ .mouse = vx.translateMouse(mouse) }),
        .mouse_leave, .focus_in, .focus_out, .paste_start, .paste_end => try self.postEvent(event),
        // Owned by the event; the consumer frees it.
        .paste => try self.postEvent(event),
        .color_report, .color_scheme => try self.postEvent(event),
        .cap_kitty_keyboard => vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => vx.caps.kitty_graphics = true,
        .cap_rgb => vx.caps.rgb = true,
        .cap_unicode => {
            vx.caps.unicode = .unicode;
            vx.screen.width_method = .unicode;
        },
        .cap_sgr_pixels => vx.caps.sgr_pixels = true,
        .cap_color_scheme_updates => vx.caps.color_scheme_updates = true,
        .cap_multi_cursor => vx.caps.multi_cursor = true,
        .cap_da1 => {
            // The probe's last reply: wake `queryTerminal`.
            vx.queries_done.store(true, .unordered);
            Io.futexWake(self.io, std.atomic.Value(u32), &vx.query_futex, 10);
        },
        .winsize => |ws| {
            // Mode 2048 report. From here on the SIGWINCH path is skipped.
            vx.state.in_band_resize = true;
            try self.postEvent(.{ .winsize = ws });
        },
    }
}

fn cacheText(self: *Input, key: Key) Key {
    var out = key;
    if (key.text) |text| out.text = self.cache.put(text);
    return out;
}

fn winchTask(self: *Input) Io.Cancelable!void {
    const pipe_r: Io.File = .{ .handle = self.winch_pipe[0], .flags = .{ .nonblocking = false } };
    var byte: [16]u8 = undefined;
    while (true) {
        _ = pipe_r.readStreaming(self.io, &.{&byte}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        // Once the terminal reports sizes in-band the signal is redundant.
        if (self.vx.state.in_band_resize) continue;
        const ws = self.getWinsize() catch continue;
        self.postEvent(.{ .winsize = ws }) catch |err| return mapQueueErr(err);
    }
}

fn mapQueueErr(err: anyerror) Io.Cancelable!void {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => {},
    };
}

// ── key naming (for status lines, tests, and the .test runner's key specs) ──

const named = [_]struct { cp: u21, name: []const u8 }{
    .{ .cp = Key.escape, .name = "esc" },
    .{ .cp = Key.enter, .name = "enter" },
    .{ .cp = Key.tab, .name = "tab" },
    .{ .cp = Key.backspace, .name = "backspace" },
    .{ .cp = Key.space, .name = "space" },
    .{ .cp = Key.insert, .name = "insert" },
    .{ .cp = Key.delete, .name = "delete" },
    .{ .cp = Key.left, .name = "left" },
    .{ .cp = Key.right, .name = "right" },
    .{ .cp = Key.up, .name = "up" },
    .{ .cp = Key.down, .name = "down" },
    .{ .cp = Key.page_up, .name = "pageup" },
    .{ .cp = Key.page_down, .name = "pagedown" },
    .{ .cp = Key.home, .name = "home" },
    .{ .cp = Key.end, .name = "end" },
    .{ .cp = Key.f1, .name = "f1" },
    .{ .cp = Key.f2, .name = "f2" },
    .{ .cp = Key.f3, .name = "f3" },
    .{ .cp = Key.f4, .name = "f4" },
    .{ .cp = Key.f5, .name = "f5" },
    .{ .cp = Key.f6, .name = "f6" },
    .{ .cp = Key.f7, .name = "f7" },
    .{ .cp = Key.f8, .name = "f8" },
    .{ .cp = Key.f9, .name = "f9" },
    .{ .cp = Key.f10, .name = "f10" },
    .{ .cp = Key.f11, .name = "f11" },
    .{ .cp = Key.f12, .name = "f12" },
    .{ .cp = Key.kp_enter, .name = "kpenter" },
};

/// `ctrl+shift+a`, `alt+enter`, `f5`, `漢` — mnml's key-spec grammar.
/// Modifier-only presses (kitty reports them) come out as `ctrl` etc.
pub fn keyName(key: Key, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    writeKeyName(&w, key) catch {};
    return w.buffered();
}

pub fn writeKeyName(w: *Io.Writer, key: Key) Io.Writer.Error!void {
    var wrote_mod = false;
    const mods = [_]struct { on: bool, name: []const u8 }{
        .{ .on = key.mods.ctrl, .name = "ctrl" },
        .{ .on = key.mods.alt, .name = "alt" },
        .{ .on = key.mods.shift, .name = "shift" },
        .{ .on = key.mods.super, .name = "super" },
        .{ .on = key.mods.hyper, .name = "hyper" },
        .{ .on = key.mods.meta, .name = "meta" },
    };
    for (mods) |m| {
        if (!m.on) continue;
        if (wrote_mod) try w.writeByte('+');
        try w.writeAll(m.name);
        wrote_mod = true;
    }
    if (key.isModifier()) return;
    if (wrote_mod) try w.writeByte('+');
    for (named) |n| {
        if (n.cp == key.codepoint) return w.writeAll(n.name);
    }
    if (key.codepoint < 0x20) {
        // Legacy control byte: ctrl+<letter>, unless kitty already told us.
        if (!key.mods.ctrl) try w.writeAll("ctrl+");
        return w.writeByte(@intCast(key.codepoint + 0x60));
    }
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(key.codepoint, &utf8) catch return w.writeByte('?');
    try w.writeAll(utf8[0..n]);
}

// ── tests ──

const testing = std.testing;

fn expectName(expected: []const u8, key: Key) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, keyName(key, &buf));
}

test "keyName: plain, modified, named and legacy control keys" {
    try expectName("a", .{ .codepoint = 'a' });
    try expectName("漢", .{ .codepoint = 0x6f22 });
    try expectName("ctrl+a", .{ .codepoint = 'a', .mods = .{ .ctrl = true } });
    try expectName("ctrl+shift+a", .{ .codepoint = 'a', .mods = .{ .ctrl = true, .shift = true } });
    try expectName("alt+enter", .{ .codepoint = Key.enter, .mods = .{ .alt = true } });
    try expectName("esc", .{ .codepoint = Key.escape });
    try expectName("f5", .{ .codepoint = Key.f5 });
    try expectName("shift+tab", .{ .codepoint = Key.tab, .mods = .{ .shift = true } });
    // Legacy \x01 with no kitty modifiers still reads as ctrl+a.
    try expectName("ctrl+a", .{ .codepoint = 0x01 });
    // ...and a kitty-reported ctrl+a does not double the prefix.
    try expectName("ctrl+a", .{ .codepoint = 0x01, .mods = .{ .ctrl = true } });
    try expectName("ctrl+space", .{ .codepoint = Key.space, .mods = .{ .ctrl = true } });
}

test "keyName: caps/num lock are not spelled; lone modifiers are" {
    try expectName("a", .{ .codepoint = 'a', .mods = .{ .caps_lock = true, .num_lock = true } });
    try expectName("ctrl", .{ .codepoint = Key.left_control, .mods = .{ .ctrl = true } });
}

fn testInput(vx: *vaxis.Vaxis) !*Input {
    const in = try testing.allocator.create(Input);
    in.init(testing.io, testing.allocator, vx, .stdin());
    return in;
}

test "fold: capability replies land in vaxis, DA1 ends the probe, keys are posted" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    const in = try testInput(&vx);
    defer testing.allocator.destroy(in);

    vx.queries_done.store(false, .unordered);
    try in.fold(.cap_kitty_keyboard);
    try in.fold(.cap_kitty_graphics);
    try in.fold(.cap_sgr_pixels);
    try in.fold(.cap_unicode);
    // shift+F3 while probing is the explicit-width reply, not a key.
    try in.fold(.{ .key_press = .{ .codepoint = Key.f3, .mods = .{ .shift = true } } });
    try in.fold(.{ .winsize = .{ .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0 } });
    try in.fold(.cap_da1);

    try testing.expect(vx.caps.kitty_keyboard);
    try testing.expect(vx.caps.kitty_graphics);
    try testing.expect(vx.caps.sgr_pixels);
    try testing.expect(vx.caps.explicit_width);
    try testing.expectEqual(vaxis.gwidth.Method.unicode, vx.caps.unicode);
    try testing.expect(vx.state.in_band_resize);
    try testing.expect(vx.queries_done.load(.unordered));

    // After the probe, shift+F3 is an ordinary key.
    try in.fold(.{ .key_press = .{ .codepoint = Key.f3, .mods = .{ .shift = true } } });
    try in.fold(.{ .key_press = .{ .codepoint = 'a', .text = "a" } });

    var buf: [8]Event = undefined;
    const n = try in.drain(&buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 20), buf[0].winsize.cols);
    try testing.expectEqual(@as(u21, Key.f3), buf[1].key_press.codepoint);
    try testing.expectEqualStrings("a", buf[2].key_press.text.?);
}

test "parser distinguishes chords the legacy encoding folds together" {
    // Kitty encodes ctrl+i and tab differently; legacy sends 0x09 for both.
    var parser: vaxis.Parser = .{};
    const tab = try parser.parse("\t", null);
    try testing.expectEqual(@as(u21, Key.tab), tab.event.?.key_press.codepoint);
    const ctrl_i = try parser.parse("\x1b[105;5u", null);
    try testing.expectEqual(@as(u21, 'i'), ctrl_i.event.?.key_press.codepoint);
    try testing.expect(ctrl_i.event.?.key_press.mods.ctrl);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("tab", keyName(tab.event.?.key_press, &buf));
    try testing.expectEqualStrings("ctrl+i", keyName(ctrl_i.event.?.key_press, &buf));
    // A lone ESC (input.len == 1) is the escape key, not an alt prefix.
    const esc = try parser.parse("\x1b", null);
    try testing.expectEqual(@as(u21, Key.escape), esc.event.?.key_press.codepoint);
}
