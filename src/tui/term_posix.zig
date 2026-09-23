//! Term — one terminal session, POSIX. Raw mode on the input tty, our
//! own buffered writer on stdout, the input worker, the capability probe,
//! and the modes we turn on (alt screen, mouse, bracketed paste, kitty
//! keyboard). `deinit` puts every one of them back on every path, and a
//! panic hook (`Panic`) does the same before the trace prints.
//!
//! vaxis owns the cell store and the diff (`vx.screen`, `vx.render`); we
//! drive it on `*std.Io.Writer` rather than through its Tty/Loop so the
//! event queue, the signal handling and the output fd are ours. What we
//! detected lands in `caps`, a `Capabilities` we own: vaxis 0.6.0 never
//! sets `caps.rgb`, so truecolor is decided from the environment
//! (`caps.zig`, shared with the Windows session).
//!
//! Order matters in `init`: the input worker starts BEFORE the probe,
//! because `queryTerminal` blocks on a futex that only the reader wakes
//! (on the DA1 reply). The alt screen is entered before the probe too, so
//! the cursor-position queries scribble on a screen we are about to clear.
//!
//! termios + `/dev/tty`; the Windows console is `term_windows.zig`, the
//! same surface over console modes. `term.zig` picks one at comptime.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Input = @import("input_posix.zig");
const caps_mod = @import("caps.zig");

const Io = std.Io;
const posix = std.posix;
const ctlseqs = vaxis.ctlseqs;

const Term = @This();

pub const Event = Input.Event;
pub const Winsize = vaxis.Winsize;
pub const Capabilities = caps_mod.Capabilities;
pub const Options = caps_mod.Options;

io: Io,
gpa: std.mem.Allocator,
env: *std.process.Environ.Map,
vx: vaxis.Vaxis,
input: Input,
caps: Capabilities = .{},
/// Key bytes come from here: stdin when it is a tty, else `/dev/tty`.
tty_in: Io.File,
opened_dev_tty: bool = false,
/// Frames go here — stdout, never `/dev/tty`, so a wrapper can capture it.
out: Io.File.Writer,
out_buf: [16 * 1024]u8 = undefined,
saved_termios: ?posix.termios = null,
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
    if (!try tty_in.isTty(io)) {
        tty_in = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        opened = true;
    }
    errdefer if (opened) closeTty(tty_in, io);

    self.* = .{
        .io = io,
        .gpa = gpa,
        .env = env,
        .vx = undefined,
        .input = undefined,
        .tty_in = tty_in,
        .opened_dev_tty = opened,
        .out = undefined,
    };
    self.out = .initStreaming(stdout, io, &self.out_buf);
    const w = self.writer();

    // Raw mode first: the probe's replies must not echo.
    self.saved_termios = try vaxis.tty.PosixTty.makeRaw(tty_in.handle);
    errdefer self.restoreTermios();

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

    // Blocks until DA1 or the timeout; on return `enableDetectedFeatures`
    // has already pushed kitty flags / mode 2027 for what was detected.
    if (!opts.kitty_keyboard) self.vx.caps.kitty_keyboard = false;
    self.vx.queryTerminal(w, .fromMilliseconds(opts.query_timeout_ms)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
    if (!opts.kitty_keyboard and self.vx.state.kitty_keyboard) {
        try w.writeAll(ctlseqs.csi_u_pop);
        self.vx.state.kitty_keyboard = false;
    }
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

    // Cell coordinates, never pixels. ghostty (and kitty, WezTerm)
    // answer the DECRQM 1016 probe, and vaxis would then ask for pixel
    // reports and map them through the winsize's pixel dimensions — a
    // mapping the parser never gets (our reader hands it bare reports),
    // so every click landed nowhere. The Rust editor took cells from
    // crossterm; a terminal IDE has no use for sub-cell positions.
    self.vx.caps.sgr_pixels = false;
    if (opts.mouse) try self.vx.setMouseMode(w, true);
    if (opts.bracketed_paste) try self.vx.setBracketedPaste(w, true);

    const ws = try self.input.getWinsize();
    try self.vx.resize(gpa, w, ws);
    self.vx.screen.width_method = self.caps.unicode;
}

/// Restores every mode, the main screen and the termios. Safe on every
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
    self.restoreTermios();
    if (self.opened_dev_tty) closeTty(self.tty_in, self.io);
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

fn restoreTermios(self: *Term) void {
    const saved = self.saved_termios orelse return;
    self.saved_termios = null;
    posix.tcsetattr(self.tty_in.handle, .FLUSH, saved) catch {};
}

fn closeTty(file: Io.File, io: Io) void {
    // Closing /dev/tty can block indefinitely on macOS; the process is
    // exiting anyway, so let the kernel reap it there.
    if (builtin.os.tag == .macos) return;
    file.close(io);
}

// ── panic hook ──

/// Root modules that hold a `Term` declare `pub const panic = Term.Panic;`
/// so a crash prints its trace on a readable terminal, not inside the alt
/// screen with the mouse still reporting.
pub const Panic = std.debug.FullPanic(panicHandler);

pub fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    recover();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Puts the terminal back with unbuffered writes — the session's writer
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
    writeRawFd(1, reset);
    if (t.saved_termios) |saved| posix.tcsetattr(t.tty_in.handle, .FLUSH, saved) catch {};
}

fn writeRawFd(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return;
        }
        off += @intCast(rc);
    }
}

// ── tests ──

const testing = std.testing;

test "Term.init refuses a non-tty stdout instead of half-configuring one" {
    // Under `zig build test` stdout is a pipe. Nothing must be touched:
    // no raw mode, no signal handler, no alt screen on the parent tty.
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const t = try testing.allocator.create(Term);
    defer testing.allocator.destroy(t);
    if (try Io.File.stdout().isTty(testing.io)) return error.SkipZigTest;
    try testing.expectError(error.NotATty, t.init(testing.io, testing.allocator, &env, .{}));
    try testing.expect(active == null);
}
