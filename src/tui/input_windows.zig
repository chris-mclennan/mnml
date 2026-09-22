//! Terminal input as a worker, Windows: console input records → bytes →
//! `vaxis.Parser` → `std.Io.Queue(vaxis.Event)`, the same queue and the
//! same fold the POSIX worker feeds (`input_common.zig`).
//!
//! With `ENABLE_VIRTUAL_TERMINAL_INPUT` on (see `term_windows.zig`) the
//! console hands keys over as VT sequences — one `KEY_EVENT_RECORD` per
//! UTF-16 unit, `ESC [ A` for an arrow, `CSI u` chords where the terminal
//! knows them, SGR mouse reports once mouse mode is set — so the records
//! are only ever a byte stream with extra framing, and the parser that
//! reads a POSIX tty reads them too. `ReadConsoleInputW` is used rather
//! than `ReadFile` because it is the only way to see the two things that
//! are not bytes: the `WINDOW_BUFFER_SIZE_EVENT` a resize raises (the
//! SIGWINCH of this platform) and, on a console that does not translate
//! the mouse, the native `MOUSE_EVENT_RECORD`s.
//!
//! One `std.Thread`, not an `Io.Group` task: `Io.Threaded` cancels a
//! blocked read with `NtCancelSynchronousIoFile`, which does not reach a
//! wait on a console handle. A console input handle is itself waitable
//! (signaled while records are pending), so the thread waits on it and
//! on a stop event together and `stop` joins it deterministically.
//!
//! Untested end to end: there is no Windows machine in the loop, and the
//! thread and the console calls are held to "compiles clean for
//! x86_64-windows-gnu". The record fold — key records to bytes, surrogate
//! pairs, the native mouse — is pure and its tests run on every host;
//! the two places the fold would otherwise touch the console are gated
//! on the target so the tests analyze here.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const common = @import("input_common.zig");
const win32 = @import("win32.zig");

const Io = std.Io;
const windows = std.os.windows;

pub const Event = common.Event;
pub const Key = common.Key;
pub const keyName = common.keyName;
pub const writeKeyName = common.writeKeyName;

const Input = @This();

io: Io,
gpa: std.mem.Allocator,
vx: *vaxis.Vaxis,
/// The console input handle: stdin when it is a console, else `CONIN$`.
tty: Io.File,
/// The console output handle — sizes come from the screen buffer.
out: Io.File,
buffer: [common.queue_len]Event = undefined,
queue: Io.Queue(Event),
cache: vaxis.GraphemeCache = .{},
/// How this terminal spells a shifted function key when it does not use
/// xterm's modifier parameter (`legacy_fkeys.zig`); the terminal sets it
/// from `$TERM_PROGRAM` / `$TERM` before `start`.
fkeys: common.legacy_fkeys.Style = .xterm,
/// A bracketed paste being collected (`input_common.fold`): the bytes
/// between the terminal's paste fences, delivered as one `.paste`.
paste: common.PasteBuffer = .{},
/// Manual-reset event `stop` sets so the reader leaves its wait.
stop_event: ?win32.HANDLE = null,
thread: ?std.Thread = null,
started: bool = false,

/// Intrusive: the queue points at `self.buffer`, so `self` must not move.
pub fn init(self: *Input, io: Io, gpa: std.mem.Allocator, vx: *vaxis.Vaxis, tty: Io.File) void {
    self.* = .{
        .io = io,
        .gpa = gpa,
        .vx = vx,
        .tty = tty,
        .out = .stdout(),
        .queue = undefined,
    };
    self.queue = .init(&self.buffer);
}

/// Spawns the reader. Call BEFORE `queryTerminal`: the probe blocks on a
/// futex that only the reader wakes (on DA1).
pub fn start(self: *Input) !void {
    if (self.started) return;
    const ev = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;
    errdefer windows.CloseHandle(ev);
    self.stop_event = ev;
    self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerMain, .{self});
    self.started = true;
}

/// Wakes the reader out of its wait and joins it. Safe to call twice.
pub fn stop(self: *Input) void {
    if (!self.started) return;
    self.started = false;
    const stop_event = self.stop_event.?;
    _ = win32.SetEvent(stop_event);
    if (self.thread) |th| th.join();
    self.thread = null;
    windows.CloseHandle(stop_event);
    self.stop_event = null;
    self.paste.deinit(self.gpa);
}

/// Called by the fold for every event it decides to deliver. Never
/// blocks indefinitely: a full queue means the UI thread is behind, and
/// a `stop` in that state must still be able to join us — so the wait
/// is a series of short ones that also watch the stop event.
pub fn postEvent(self: *Input, event: Event) !void {
    while (true) {
        if (try self.queue.put(self.io, &.{event}, 0) == 1) return;
        // A POSIX host only reaches this from the tests, where the queue
        // never fills; the wait below is the console's and does not link
        // there.
        if (comptime builtin.os.tag != .windows) return error.Canceled;
        const stop_event = self.stop_event orelse {
            win32.Sleep(1);
            continue;
        };
        if (win32.WaitForSingleObject(stop_event, 1) == win32.WAIT_OBJECT_0) return error.Canceled;
    }
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
    return winsizeOf(self.out);
}

/// The visible window of the screen buffer behind `out`. The buffer
/// itself is usually taller (scrollback); `srWindow` is what the user
/// sees, inclusive on both ends.
pub fn winsizeOf(out: Io.File) !vaxis.Winsize {
    // The tests' resize record on a POSIX host: no console to ask.
    if (comptime builtin.os.tag != .windows) return error.NotAConsole;
    var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (win32.GetConsoleScreenBufferInfo(out.handle, &info) == .FALSE) return error.NotAConsole;
    return winsizeOfInfo(info);
}

pub fn winsizeOfInfo(info: win32.CONSOLE_SCREEN_BUFFER_INFO) vaxis.Winsize {
    const w = info.srWindow;
    const cols: i32 = @as(i32, w.Right) - @as(i32, w.Left) + 1;
    const rows: i32 = @as(i32, w.Bottom) - @as(i32, w.Top) + 1;
    return .{
        .cols = @intCast(@max(cols, 0)),
        .rows = @intCast(@max(rows, 0)),
        .x_pixel = 0,
        .y_pixel = 0,
    };
}

// ── the reader thread ──

fn readerMain(self: *Input) void {
    // The initial size, like vaxis's loop, so the app can allocate its screen.
    if (self.getWinsize()) |ws| {
        self.postEvent(.{ .winsize = ws }) catch return;
    } else |_| {}

    var fold: RecordFold = .{ .in = self };
    var records: [64]win32.INPUT_RECORD = undefined;
    // Stop first: when both are signaled the lowest index wins.
    const handles = [_]win32.HANDLE{ self.stop_event.?, self.tty.handle };
    while (true) {
        switch (win32.WaitForMultipleObjects(handles.len, &handles, .FALSE, win32.INFINITE)) {
            win32.WAIT_OBJECT_0 => return,
            win32.WAIT_OBJECT_0 + 1 => {},
            // A failed wait: the console is gone.
            else => return,
        }
        // At least one record is pending, so this returns what is there
        // (up to the buffer) without blocking.
        var got: win32.DWORD = 0;
        if (win32.ReadConsoleInputW(self.tty.handle, &records, records.len, &got) == .FALSE) return;
        for (records[0..got]) |*rec| fold.record(rec) catch return;
        fold.flush() catch return;
    }
}

/// Turns input records into what the queue wants: key records become
/// UTF-8 bytes for the parser, the rest become events directly. Bytes
/// are flushed through the parser before any direct event is posted, so
/// order is kept.
pub const RecordFold = struct {
    in: *Input,
    parser: vaxis.Parser = .{},
    bytes: [4096]u8 = undefined,
    /// Bytes waiting for the parser (a carried incomplete sequence, then
    /// this batch's keys).
    fill: usize = 0,
    /// The first half of a surrogate pair, awaiting its second record.
    high_surrogate: ?u16 = null,
    /// Buttons down as of the last mouse record, to tell a release from
    /// a press.
    mouse_buttons: u16 = 0,

    pub fn record(self: *RecordFold, rec: *const win32.INPUT_RECORD) !void {
        switch (rec.EventType) {
            win32.INPUT_RECORD.KEY_EVENT => try self.key(rec.Event.KeyEvent),
            win32.INPUT_RECORD.WINDOW_BUFFER_SIZE_EVENT => {
                // The record's own size is the buffer's, not the
                // window's; ask for the window. Mode 2048, if the
                // terminal has it, already covered this.
                if (self.in.vx.state.in_band_resize) return;
                try self.flush();
                const ws = self.in.getWinsize() catch return;
                try self.in.postEvent(.{ .winsize = ws });
            },
            win32.INPUT_RECORD.MOUSE_EVENT => {
                const m = self.mouse(rec.Event.MouseEvent) orelse return;
                try self.flush();
                try common.fold(self.in, .{ .mouse = m });
            },
            // Focus records are "used internally and should be ignored"
            // (the SDK); a terminal that reports focus does so with CSI
            // I / CSI O through the key path. Menu records are nothing.
            else => {},
        }
    }

    /// Parse everything accumulated; what is left is a carried tail.
    pub fn flush(self: *RecordFold) !void {
        self.fill = try common.parse(self.in, &self.parser, &self.bytes, self.fill);
    }

    /// A key-down record's UTF-16 unit, as UTF-8, `wRepeatCount` times.
    /// Key-ups carry the same character and are dropped; a unit of zero
    /// is a modifier alone.
    fn key(self: *RecordFold, k: win32.KEY_EVENT_RECORD) !void {
        if (k.bKeyDown == .FALSE) return;
        const cp = self.codepoint(k.uChar.UnicodeChar) orelse return;
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        var repeat: usize = @max(k.wRepeatCount, 1);
        while (repeat > 0) : (repeat -= 1) {
            if (self.bytes.len - self.fill < n) try self.flush();
            @memcpy(self.bytes[self.fill..][0..n], utf8[0..n]);
            self.fill += n;
        }
    }

    /// One UTF-16 unit → a code point, pairing surrogates across records.
    /// Null while waiting for the second half, or for a unit that is
    /// nothing on its own.
    pub fn codepoint(self: *RecordFold, unit: u16) ?u21 {
        if (unit == 0) return null;
        if (self.high_surrogate) |high| {
            self.high_surrogate = null;
            if (std.unicode.utf16IsLowSurrogate(unit)) {
                return std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch null;
            }
            // An orphaned high half: drop it and read this unit afresh.
        }
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return null;
        }
        if (std.unicode.utf16IsLowSurrogate(unit)) return null;
        return unit;
    }

    /// A native mouse record — what a console that does not translate
    /// the mouse into SGR reports delivers. Windows Terminal translates
    /// once mouse mode is set, and then these never arrive.
    pub fn mouse(self: *RecordFold, m: win32.MOUSE_EVENT_RECORD) ?vaxis.Mouse {
        const buttons: u16 = @truncate(m.dwButtonState);
        const changed = self.mouse_buttons ^ buttons;
        self.mouse_buttons = buttons;
        const moved = m.dwEventFlags & win32.MOUSE_MOVED != 0;
        var kind: vaxis.Mouse.Type = .press;
        const button: vaxis.Mouse.Button = switch (changed) {
            0 => blk: {
                if (m.dwEventFlags & win32.MOUSE_WHEELED != 0) {
                    // The high word is a signed wheel delta.
                    const delta: i16 = @bitCast(@as(u16, @truncate(m.dwButtonState >> 16)));
                    break :blk if (delta > 0) .wheel_up else .wheel_down;
                }
                if (!moved) return null;
                if (buttons == 0) {
                    kind = .motion;
                    break :blk .none;
                }
                kind = .drag;
                break :blk heldButton(buttons);
            },
            win32.FROM_LEFT_1ST_BUTTON_PRESSED => blk: {
                if (buttons & changed == 0) kind = .release;
                break :blk .left;
            },
            win32.RIGHTMOST_BUTTON_PRESSED => blk: {
                if (buttons & changed == 0) kind = .release;
                break :blk .right;
            },
            win32.FROM_LEFT_2ND_BUTTON_PRESSED => blk: {
                if (buttons & changed == 0) kind = .release;
                break :blk .middle;
            },
            // Two buttons changing in one record, or a button we do not
            // name: nothing sensible to report.
            else => return null,
        };
        const s = m.dwControlKeyState;
        return .{
            .col = m.dwMousePosition.X,
            .row = m.dwMousePosition.Y,
            .button = button,
            .mods = .{
                .shift = s & win32.SHIFT_PRESSED != 0,
                .alt = s & (win32.LEFT_ALT_PRESSED | win32.RIGHT_ALT_PRESSED) != 0,
                .ctrl = s & (win32.LEFT_CTRL_PRESSED | win32.RIGHT_CTRL_PRESSED) != 0,
            },
            .type = kind,
        };
    }

    fn heldButton(buttons: u16) vaxis.Mouse.Button {
        if (buttons & win32.FROM_LEFT_1ST_BUTTON_PRESSED != 0) return .left;
        if (buttons & win32.RIGHTMOST_BUTTON_PRESSED != 0) return .right;
        return .middle;
    }
};

// ── tests ──

const testing = std.testing;

fn keyDown(unit: u16, repeat: u16) win32.INPUT_RECORD {
    return .{ .EventType = win32.INPUT_RECORD.KEY_EVENT, .Event = .{ .KeyEvent = .{
        .bKeyDown = .TRUE,
        .wRepeatCount = repeat,
        .wVirtualKeyCode = 0,
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = unit },
        .dwControlKeyState = 0,
    } } };
}

fn keyUp(unit: u16) win32.INPUT_RECORD {
    var rec = keyDown(unit, 1);
    rec.Event.KeyEvent.bKeyDown = .FALSE;
    return rec;
}

fn testFold(vx: *vaxis.Vaxis, in: *Input) RecordFold {
    in.init(testing.io, testing.allocator, vx, .stdin());
    return .{ .in = in };
}

test "records: VT sequences split across key records reach the parser as one stream" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    vx.queries_done.store(true, .unordered);
    const in = try testing.allocator.create(Input);
    defer testing.allocator.destroy(in);
    var fold = testFold(&vx, in);

    // "a", then ESC [ A one unit per record (an arrow under VT input),
    // then a key-up for "a" that must not echo, then a modifier alone.
    for (&[_]win32.INPUT_RECORD{ keyDown('a', 1), keyDown(0x1b, 1), keyDown('[', 1), keyDown('A', 1), keyUp('a'), keyDown(0, 1) }) |*rec| try fold.record(rec);
    try fold.flush();

    var out: [8]Event = undefined;
    const n = try in.drain(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u21, 'a'), out[0].key_press.codepoint);
    try testing.expectEqual(@as(u21, Key.up), out[1].key_press.codepoint);
}

test "records: a repeat count repeats the key; a surrogate pair is one code point" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    defer vx.deinit(testing.allocator, &sink.writer);
    vx.queries_done.store(true, .unordered);
    const in = try testing.allocator.create(Input);
    defer testing.allocator.destroy(in);
    var fold = testFold(&vx, in);

    // 🦎 is U+1F98E: D83E DD8E as two records.
    for (&[_]win32.INPUT_RECORD{ keyDown('x', 3), keyDown(0xD83E, 1), keyDown(0xDD8E, 1) }) |*rec| try fold.record(rec);
    try fold.flush();

    var out: [8]Event = undefined;
    const n = try in.drain(&out);
    try testing.expectEqual(@as(usize, 4), n);
    for (out[0..3]) |ev| try testing.expectEqual(@as(u21, 'x'), ev.key_press.codepoint);
    try testing.expectEqual(@as(u21, 0x1F98E), out[3].key_press.codepoint);
    try testing.expectEqualStrings("🦎", out[3].key_press.text.?);
}

test "codepoint: an orphaned high surrogate is dropped, a lone low one too" {
    var fold: RecordFold = .{ .in = undefined };
    try testing.expectEqual(@as(?u21, null), fold.codepoint(0xD83E));
    // A plain unit after a dangling high half: the half is forgotten.
    try testing.expectEqual(@as(?u21, 'q'), fold.codepoint('q'));
    try testing.expectEqual(@as(?u21, null), fold.codepoint(0xDD8E));
    try testing.expectEqual(@as(?u21, null), fold.codepoint(0));
    try testing.expectEqual(@as(?u21, 0x6f22), fold.codepoint(0x6f22));
}

test "mouse: press, drag, release and wheel from native records" {
    var fold: RecordFold = .{ .in = undefined };
    const at: win32.COORD = .{ .X = 7, .Y = 3 };
    const press = fold.mouse(.{ .dwMousePosition = at, .dwButtonState = 1, .dwControlKeyState = win32.SHIFT_PRESSED, .dwEventFlags = 0 }).?;
    try testing.expect(press.type == .press and press.button == .left and press.mods.shift);
    try testing.expectEqual(@as(i16, 7), press.col);
    const drag = fold.mouse(.{ .dwMousePosition = .{ .X = 8, .Y = 3 }, .dwButtonState = 1, .dwControlKeyState = 0, .dwEventFlags = win32.MOUSE_MOVED }).?;
    try testing.expect(drag.type == .drag and drag.button == .left);
    const release = fold.mouse(.{ .dwMousePosition = at, .dwButtonState = 0, .dwControlKeyState = 0, .dwEventFlags = 0 }).?;
    try testing.expect(release.type == .release and release.button == .left);
    const motion = fold.mouse(.{ .dwMousePosition = at, .dwButtonState = 0, .dwControlKeyState = 0, .dwEventFlags = win32.MOUSE_MOVED }).?;
    try testing.expect(motion.type == .motion and motion.button == .none);
    // A wheel delta of -120 in the high word.
    const down = fold.mouse(.{ .dwMousePosition = at, .dwButtonState = @as(u32, @as(u16, @bitCast(@as(i16, -120)))) << 16, .dwControlKeyState = 0, .dwEventFlags = win32.MOUSE_WHEELED }).?;
    try testing.expect(down.button == .wheel_down);
    // Nothing changed and nothing moved: nothing to say.
    try testing.expectEqual(@as(?vaxis.Mouse, null), fold.mouse(.{ .dwMousePosition = at, .dwButtonState = 0, .dwControlKeyState = 0, .dwEventFlags = 0 }));
    const right = fold.mouse(.{ .dwMousePosition = at, .dwButtonState = 2, .dwControlKeyState = win32.LEFT_CTRL_PRESSED, .dwEventFlags = 0 }).?;
    try testing.expect(right.type == .press and right.button == .right and right.mods.ctrl);
}

test "winsizeOfInfo: the window rectangle is inclusive on both ends" {
    const ws = winsizeOfInfo(.{
        .dwSize = .{ .X = 120, .Y = 9001 },
        .dwCursorPosition = .{ .X = 0, .Y = 0 },
        .wAttributes = 0,
        .srWindow = .{ .Left = 0, .Top = 8971, .Right = 119, .Bottom = 9000 },
        .dwMaximumWindowSize = .{ .X = 120, .Y = 30 },
    });
    try testing.expectEqual(@as(u16, 120), ws.cols);
    try testing.expectEqual(@as(u16, 30), ws.rows);
}
