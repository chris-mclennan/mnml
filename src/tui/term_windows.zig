//! Term — one terminal session, Windows. The console equivalent of
//! `term_posix.zig`'s raw mode: the input and output console modes are
//! saved and swapped for VT ones (`ENABLE_VIRTUAL_TERMINAL_INPUT` so keys
//! arrive as escape sequences, `ENABLE_VIRTUAL_TERMINAL_PROCESSING` +
//! `DISABLE_NEWLINE_AUTO_RETURN` so our frames are interpreted the way a
//! POSIX terminal interprets them, quick-edit off so the mouse is ours),
//! the output code page is set to UTF-8, and `deinit` — and the panic
//! hook — put all three back. From there on the session is the POSIX
//! one: our own buffered writer on stdout, the input worker, vaxis's
//! probe, alt screen, mouse, bracketed paste.
//!
//! The probe runs unchanged. Windows Terminal answers DA1 and the mode
//! reports it knows; vaxis then skips its feature push on Windows (it
//! hard-sets legacy SGR there), so the kitty keyboard stays off even if
//! it were detected, which matches what the terminals here support.
//!
//! Size comes from `GetConsoleScreenBufferInfo`; a resize raises a
//! `WINDOW_BUFFER_SIZE_EVENT` the input worker folds into `.winsize`
//! (`input_windows.zig`) — mode 2048 in-band reports take over if the
//! terminal has them, exactly as on POSIX.
//!
//! Untested: there is no Windows machine in the loop. Held to "compiles
//! clean for x86_64-windows-gnu"; docs/WINDOWS.md has the checklist.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Input = @import("input_windows.zig");
const caps_mod = @import("caps.zig");
const win32 = @import("win32.zig");

const Io = std.Io;
const windows = std.os.windows;
const ctlseqs = vaxis.ctlseqs;

const Term = @This();

pub const Event = Input.Event;
pub const Winsize = vaxis.Winsize;
pub const Capabilities = caps_mod.Capabilities;
pub const Options = caps_mod.Options;

/// The console state `init` replaces and `deinit` restores.
const Saved = struct {
    in_mode: u32,
    out_mode: u32,
    out_cp: win32.UINT,
};

io: Io,
gpa: std.mem.Allocator,
env: *std.process.Environ.Map,
vx: vaxis.Vaxis,
input: Input,
caps: Capabilities = .{},
/// Key records come from here: stdin when it is a console, else `CONIN$`.
tty_in: Io.File,
opened_conin: bool = false,
/// Frames go here — stdout, so a wrapper can capture it.
out: Io.File.Writer,
out_buf: [16 * 1024]u8 = undefined,
saved: ?Saved = null,
alive: bool = false,

/// The session the panic hook restores. One terminal per process.
var active: ?*Term = null;

/// Intrusive, like `Input`: the writer buffers into `self.out_buf` and the
/// queue into `self.input.buffer`, so `self` must not move afterwards.
pub fn init(self: *Term, io: Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, opts: Options) !void {
    const stdout: Io.File = .stdout();
    if (!try stdout.isTty(io)) return error.NotATty;

    var tty_in: Io.File = .stdin();
    var opened = false;
    if (win32.consoleMode(tty_in.handle) == null) {
        // stdin is a pipe or a file: the console's own input device.
        const h = win32.CreateFileW(
            std.unicode.wtf8ToWtf16LeStringLiteral("CONIN$"),
            win32.GENERIC_READ | win32.GENERIC_WRITE,
            win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
            null,
            win32.OPEN_EXISTING,
            0,
            null,
        );
        if (h == win32.INVALID_HANDLE_VALUE) return error.NotATty;
        tty_in = .{ .handle = h, .flags = .{ .nonblocking = false } };
        opened = true;
    }
    errdefer if (opened) windows.CloseHandle(tty_in.handle);

    self.* = .{
        .io = io,
        .gpa = gpa,
        .env = env,
        .vx = undefined,
        .input = undefined,
        .tty_in = tty_in,
        .opened_conin = opened,
        .out = undefined,
    };
    self.out = .initStreaming(stdout, io, &self.out_buf);
    const w = self.writer();

    // Raw mode first: the probe's replies must not echo.
    try self.enterRaw(stdout.handle);
    errdefer self.restoreConsole(stdout.handle);

    self.vx = try vaxis.init(io, gpa, env, .{ .kitty_keyboard_flags = opts.kitty_flags });
    errdefer self.vx.deinit(gpa, w);

    self.input.init(io, gpa, &self.vx, tty_in);
    self.input.fkeys = @import("legacy_fkeys.zig").styleFor(env.get("TERM_PROGRAM"), env.get("TERM"));
    try self.input.start();
    errdefer self.input.stop();

    active = self;
    self.alive = true;
    errdefer active = null;

    if (opts.alt_screen) try self.vx.enterAltScreen(w);
    try w.writeAll(ctlseqs.hide_cursor);
    try w.flush();

    // Blocks until DA1 or the timeout. On Windows vaxis pushes nothing
    // afterwards (no kitty flags, no mode 2027) and picks legacy SGR.
    if (!opts.kitty_keyboard) self.vx.caps.kitty_keyboard = false;
    self.vx.queryTerminal(w, .fromMilliseconds(opts.query_timeout_ms)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
    caps_mod.applyTerminalQuirks(&self.vx.caps, env);
    if (caps_mod.legacySgr(env, self.vx.state.kitty_keyboard)) self.vx.sgr = .legacy;

    self.caps = .{
        .kitty_keyboard = self.vx.state.kitty_keyboard,
        .kitty_graphics = self.vx.caps.kitty_graphics,
        .rgb = opts.rgb orelse caps_mod.detectRgb(env),
        .unicode = self.vx.caps.unicode,
        .sgr_pixels = self.vx.caps.sgr_pixels,
        .in_band_resize = self.vx.state.in_band_resize,
        .explicit_width = self.vx.caps.explicit_width,
    };

    if (opts.mouse) try self.vx.setMouseMode(w, true);
    if (opts.bracketed_paste) try self.vx.setBracketedPaste(w, true);

    const ws = try self.input.getWinsize();
    try self.vx.resize(gpa, w, ws);
    self.vx.screen.width_method = self.caps.unicode;
}

/// Restores every mode, the main screen and the console. Safe on every
/// path `init` can fail from, and idempotent.
pub fn deinit(self: *Term) void {
    if (!self.alive) return;
    self.alive = false;
    active = null;
    self.input.stop();
    self.freeQueued();
    self.vx.deinit(self.gpa, self.writer());
    // The probe turns mode 2048 on blind; vaxis only turns it off if a
    // report came back. Reset it regardless — a no-op where unsupported.
    self.writeRaw(ctlseqs.in_band_resize_reset) catch {};
    self.restoreConsole(Io.File.stdout().handle);
    if (self.opened_conin) windows.CloseHandle(self.tty_in.handle);
}

/// Our buffered stdout. Anything written here is emitted on the next
/// `flush` / `render`; use `writeRaw` for one-off sequences.
pub fn writer(self: *Term) *Io.Writer {
    return &self.out.interface;
}

/// The cell store to paint into (`Canvas.init(term.screen(), …)`).
pub fn screen(self: *Term) *vaxis.Screen {
    return &self.vx.screen;
}

/// True when rgb styles should be folded to the 256-cube at paint time.
pub fn quantize(self: *const Term) bool {
    return !self.caps.rgb;
}

/// Diffs `screen()` against the last frame and writes the difference.
pub fn render(self: *Term) !void {
    try self.vx.render(self.writer());
}

/// Full repaint on the next `render`.
pub fn refresh(self: *Term) void {
    self.vx.queueRefresh();
}

/// Reallocates the screen for `ws` and clears the terminal. Call from the
/// `.winsize` handler.
pub fn resize(self: *Term, ws: Winsize) !void {
    const s = &self.vx.screen;
    if (s.width == ws.cols and s.height == ws.rows and s.width_pix == ws.x_pixel and s.height_pix == ws.y_pixel) return;
    try self.vx.resize(self.gpa, self.writer(), ws);
    self.vx.screen.width_method = self.caps.unicode;
}

/// Escape hatch for image protocols and anything vaxis's diff cannot
/// express: bytes go out verbatim, now. The next `render` does not know
/// they happened, so pair with `refresh` when they touched cells.
pub fn writeRaw(self: *Term, bytes: []const u8) !void {
    const w = self.writer();
    try w.writeAll(bytes);
    try w.flush();
}

pub fn setTitle(self: *Term, title: []const u8) !void {
    try self.vx.setTitle(self.writer(), title);
}

/// Blocks for the next input event. A `.paste` payload is gpa-owned by
/// the caller once returned.
pub fn next(self: *Term) (Io.QueueClosedError || Io.Cancelable)!Event {
    return self.input.next();
}

/// Non-blocking drain into `buf`; returns the count.
pub fn drain(self: *Term, buf: []Event) (Io.QueueClosedError || Io.Cancelable)!usize {
    return self.input.drain(buf);
}

/// Frees a `.paste` payload; a no-op for every other event.
pub fn freeEvent(self: *Term, ev: Event) void {
    switch (ev) {
        .paste => |text| self.gpa.free(text),
        else => {},
    }
}

fn freeQueued(self: *Term) void {
    var buf: [32]Event = undefined;
    while (true) {
        const n = self.input.drain(&buf) catch return;
        if (n == 0) return;
        for (buf[0..n]) |ev| self.freeEvent(ev);
    }
}

// ── console modes ──

/// Save the console's modes and code page, then switch to VT in and out.
/// Fails on a console that predates VT support (conhost before Windows
/// 10 1809): there is nothing to fall back to, the frames would print
/// as text.
fn enterRaw(self: *Term, stdout: win32.HANDLE) !void {
    const in_mode = win32.consoleMode(self.tty_in.handle) orelse return error.NotATty;
    const out_mode = win32.consoleMode(stdout) orelse return error.NotATty;
    self.saved = .{ .in_mode = in_mode, .out_mode = out_mode, .out_cp = win32.GetConsoleOutputCP() };
    if (win32.SetConsoleMode(self.tty_in.handle, @bitCast(rawInputMode(@bitCast(in_mode)))) == .FALSE) return error.NoVirtualTerminal;
    if (win32.SetConsoleMode(stdout, @bitCast(rawOutputMode(@bitCast(out_mode)))) == .FALSE) return error.NoVirtualTerminal;
    // The frames are UTF-8; without this the console decodes them as
    // the OEM code page and every box-drawing glyph becomes mojibake.
    _ = win32.SetConsoleOutputCP(win32.utf8_codepage);
}

fn restoreConsole(self: *Term, stdout: win32.HANDLE) void {
    const saved = self.saved orelse return;
    self.saved = null;
    _ = win32.SetConsoleMode(self.tty_in.handle, saved.in_mode);
    _ = win32.SetConsoleMode(stdout, saved.out_mode);
    _ = win32.SetConsoleOutputCP(saved.out_cp);
}

/// The input mode for a session: no line editing or echo, no ctrl-C
/// signal, quick-edit off (it swallows the mouse), and window, mouse and
/// VT records on. Everything else the console had stays.
pub fn rawInputMode(mode: win32.InputMode) win32.InputMode {
    var raw = mode;
    raw.processed_input = false;
    raw.line_input = false;
    raw.echo_input = false;
    raw.quick_edit_mode = false;
    raw.extended_flags = true;
    raw.window_input = true;
    raw.mouse_input = true;
    raw.virtual_terminal_input = true;
    return raw;
}

/// The output mode: VT processing on, the last-column newline off, the
/// LVB attributes on for reverse and underline. Wrap stays as it was.
pub fn rawOutputMode(mode: win32.OutputMode) win32.OutputMode {
    var raw = mode;
    raw.processed_output = true;
    raw.virtual_terminal_processing = true;
    raw.disable_newline_auto_return = true;
    raw.lvb_grid_worldwide = true;
    return raw;
}

// ── panic hook ──

/// Root modules that hold a `Term` declare `pub const panic = Term.Panic;`
/// so a crash prints its trace on a readable console, not inside the alt
/// screen with the mouse still reporting and VT input still on.
pub const Panic = std.debug.FullPanic(panicHandler);

pub fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    recover();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Puts the console back with unbuffered writes — the session's writer
/// may be mid-frame when we get here. Only for the panic path.
pub fn recover() void {
    const t = active orelse return;
    active = null;
    const reset = ctlseqs.csi_u_pop ++
        ctlseqs.mouse_reset ++
        ctlseqs.bp_reset ++
        ctlseqs.in_band_resize_reset ++
        ctlseqs.unicode_reset ++
        ctlseqs.sgr_reset ++
        ctlseqs.show_cursor ++
        ctlseqs.rmcup;
    const stdout = Io.File.stdout().handle;
    win32.writeAll(stdout, reset);
    t.restoreConsole(stdout);
}

// ── tests ──

const testing = std.testing;

test "rawInputMode: VT input on, line editing and quick-edit off, the rest kept" {
    const before: win32.InputMode = .{ .processed_input = true, .line_input = true, .echo_input = true, .quick_edit_mode = true, .insert_mode = true, .auto_position = true };
    const raw = rawInputMode(before);
    try testing.expect(raw.virtual_terminal_input and raw.window_input and raw.mouse_input and raw.extended_flags);
    try testing.expect(!raw.processed_input and !raw.line_input and !raw.echo_input and !raw.quick_edit_mode);
    // Modes we have no opinion on survive the round trip.
    try testing.expect(raw.insert_mode and raw.auto_position);
}

test "rawOutputMode: VT processing on, newline auto-return off, wrap untouched" {
    const wrapping: win32.OutputMode = .{ .processed_output = true, .wrap_at_eol_output = true };
    const raw = rawOutputMode(wrapping);
    try testing.expect(raw.virtual_terminal_processing and raw.disable_newline_auto_return and raw.lvb_grid_worldwide and raw.processed_output);
    try testing.expect(raw.wrap_at_eol_output);
    try testing.expect(!rawOutputMode(.{}).wrap_at_eol_output);
    // The flag values are the SDK's.
    try testing.expectEqual(@as(u32, 0x0004), @as(u32, @bitCast(win32.OutputMode{ .virtual_terminal_processing = true })));
    try testing.expectEqual(@as(u32, 0x0008), @as(u32, @bitCast(win32.OutputMode{ .disable_newline_auto_return = true })));
    try testing.expectEqual(@as(u32, 0x0200), @as(u32, @bitCast(win32.InputMode{ .virtual_terminal_input = true })));
    try testing.expectEqual(@as(u32, 0x0040), @as(u32, @bitCast(win32.InputMode{ .quick_edit_mode = true })));
}

test "Term.init refuses a non-tty stdout instead of half-configuring one" {
    // Under `zig build test` stdout is a pipe. Nothing must be touched:
    // no console mode, no code page, no alt screen on the parent console.
    // The mode tests above run everywhere; this one needs the console.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const t = try testing.allocator.create(Term);
    defer testing.allocator.destroy(t);
    if (try Io.File.stdout().isTty(testing.io)) return error.SkipZigTest;
    try testing.expectError(error.NotATty, t.init(testing.io, testing.allocator, &env, .{}));
    try testing.expect(active == null);
}
