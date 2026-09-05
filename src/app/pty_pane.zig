//! `Pane.pty`: a child process on a pty, its ghostty-vt terminal, and the
//! grid the frame paints from. The session's reader thread rings bytes
//! and wakes the UI through `Wire` — a non-blocking post of
//! `.pty_readable{pane}` plus the queue's wake event — and `onReadable`
//! pumps exactly that pane. `tickAll` is the safety net: a pane whose
//! wakeup was lost (queue full) or whose child died without EOF (a
//! grandchild holding the slave) is caught on the next tick.
//!
//! Keys are encoded here (`encodeKey`): legacy xterm bytes by default,
//! kitty `CSI u` once the child has pushed a kitty keyboard flag set.
//! The chord chain in `dispatch.zig` decides which modified chords the
//! app keeps; everything that reaches `feedKey` goes to the child.
//!
//! The pty module picks its backend by target (openpty / fork on POSIX,
//! ConPTY on Windows); this file never names either.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Mouse = key_mod.Mouse;
const layout_mod = @import("layout.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

/// Every target has a pty backend now (openpty on POSIX, ConPTY on
/// Windows — `src/pty/root.zig`); the flag stays for the callers that
/// grew up gating on it.
pub const supported = true;
const pty = @import("pty");

pub const Session = pty.Session;
pub const Grid = pty.Grid;

/// How the child ended.
pub const Exit = union(enum) {
    code: u8,
    signal: u32,

    pub fn ok(self: Exit) bool {
        return self == .code and self.code == 0;
    }
};

/// What opened the pane — the statusline and `test.rerun` read it.
pub const Kind = enum { shell, command, runner, task };

/// Where a new pane lands relative to the active one.
pub const Placement = enum { below, right, above, left, tab };

pub const OpenOptions = struct {
    /// Empty → the user's login shell. Otherwise run as given (a bare
    /// name resolves on PATH).
    argv: []const []const u8 = &.{},
    /// Absolute; the workspace when null.
    cwd: ?[]const u8 = null,
    /// The tab label; the command line (or the shell's name) when null.
    label: ?[]const u8 = null,
    placement: Placement = .below,
    kind: Kind = .shell,
};

/// The reader thread's way into the app: posts `.pty_readable{pane}`
/// without blocking (a full queue drops the post — `tickAll` covers it)
/// and sets the loop's wake event. Heap-allocated per pane and freed
/// after `Session.deinit`, which is when the callback is disarmed.
const Wire = struct {
    events: *event.EventQueue,
    io: Io,
    pane: PaneId,

    fn readable(ctx: ?*anyopaque) void {
        const w: *Wire = @ptrCast(@alignCast(ctx.?));
        _ = w.events.q.put(w.io, &.{.{ .pty_readable = w.pane }}, 0) catch 0;
        w.events.wake.set(w.io);
    }
};

pub const PtyPane = struct {
    session: if (supported) *Session else void,
    grid: Grid = .{},
    wire: *Wire,
    /// The tab label. Owned.
    label: []u8,
    /// The command line, owned, for `term.restart`; empty = the shell.
    argv: [][]u8,
    cwd: ?[]u8,
    kind: Kind,
    exit: ?Exit = null,
    /// The grid size the session was last fitted to.
    cols: u16,
    rows: u16,

    pub fn deinit(self: *PtyPane, gpa: Allocator) void {
        if (supported) {
            self.session.deinit();
            self.grid.deinit(gpa);
        }
        gpa.destroy(self.wire);
        gpa.free(self.label);
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        if (self.cwd) |c| gpa.free(c);
    }

    /// Drain the ring into the terminal and notice an exit. The frame
    /// after this repaints the pane.
    pub fn pump(self: *PtyPane, app: *App) void {
        if (!supported) return;
        const fed = self.session.pump();
        if (self.exit == null) self.exit = exitOf(self.session.exited());
        if (fed or self.exit != null) app.needs_render = true;
    }

    fn exitOf(e: ?pty.session.Exit) ?Exit {
        const x = e orelse return null;
        return switch (x) {
            .code => |c| .{ .code = c },
            .signal => |s| .{ .signal = s },
        };
    }

    /// Resize the pty and the terminal to the rect the layout gave the
    /// pane. Cheap when unchanged.
    pub fn fit(self: *PtyPane, cols: u16, rows: u16) void {
        if (!supported) return;
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        self.session.resize(cols, rows) catch return;
        self.cols = cols;
        self.rows = rows;
    }

    pub fn write(self: *PtyPane, bytes: []const u8) void {
        if (!supported) return;
        if (self.exit != null) return;
        // Typing brings the live screen back.
        self.session.terminal().scrollViewport(.bottom);
        self.session.write(bytes);
    }

    pub fn scrollBy(self: *PtyPane, delta: isize) void {
        if (!supported) return;
        self.session.terminal().scrollViewport(.{ .delta = delta });
    }

    pub fn scrollTo(self: *PtyPane, where: enum { top, bottom }) void {
        if (!supported) return;
        self.session.terminal().scrollViewport(switch (where) {
            .top => .top,
            .bottom => .bottom,
        });
    }

    /// What the child has asked the terminal for — the encoders read it.
    pub fn encoding(self: *const PtyPane) Encoding {
        if (!supported) return .{};
        const term = &self.session.term;
        const kitty = term.screens.active.kitty_keyboard.current();
        return .{
            .kitty = kitty.disambiguate or kitty.report_all,
            .cursor_keys_app = term.modes.get(.cursor_keys),
            .bracketed_paste = term.modes.get(.bracketed_paste),
            .mouse = switch (term.flags.mouse_event) {
                .none => .none,
                .x10 => .x10,
                .normal => .normal,
                .button => .button,
                .any => .any,
            },
            .mouse_sgr = term.flags.mouse_format == .sgr or term.flags.mouse_format == .sgr_pixels,
        };
    }

    /// The child's title (OSC 0/2), if it set one.
    pub fn childTitle(self: *const PtyPane) ?[]const u8 {
        if (!supported) return null;
        return self.session.term.getTitle();
    }
};

// ─── open / close ───────────────────────────────────────────────────────

/// Spawn and show a pty pane. The new pane becomes active.
pub fn open(app: *App, opts: OpenOptions) CommandError!PaneId {
    if (!supported) return error.Unsupported;
    const gpa = app.gpa;
    const argv = try gpa.alloc([]u8, opts.argv.len);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |a| gpa.free(a);
        gpa.free(argv);
    }
    for (opts.argv) |a| {
        argv[filled] = try gpa.dupe(u8, a);
        filled += 1;
    }
    const label = try labelFor(app, opts);
    errdefer gpa.free(label);
    const cwd: ?[]u8 = if (opts.cwd) |c| try gpa.dupe(u8, c) else null;
    errdefer if (cwd) |c| gpa.free(c);

    const size = initialSize(app, opts.placement);
    const id = app.panes.peekId();
    const wire = try gpa.create(Wire);
    errdefer gpa.destroy(wire);
    wire.* = .{ .events = &app.events, .io = app.io, .pane = id };

    const session = pty.Session.spawn(gpa, app.io, .{
        .cols = size.cols,
        .rows = size.rows,
        .env = &app.env,
        .argv = if (argv.len == 0) null else @ptrCast(argv),
        .cwd = cwd orelse app.workspace,
        .notify = .{ .ctx = wire, .fn_ptr = &Wire.readable },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return app.diag.fail(app.frame.allocator(), "{s}: {s}", .{ label, @errorName(err) }),
    };
    errdefer session.deinit();

    const got = try app.panes.add(.{ .pty = .{
        .session = session,
        .wire = wire,
        .label = label,
        .argv = argv,
        .cwd = cwd,
        .kind = opts.kind,
        .cols = size.cols,
        .rows = size.rows,
    } });
    std.debug.assert(got == id);
    place(app, id, opts.placement) catch |err| {
        app.panes.remove(id);
        return err;
    };
    app.needs_render = true;
    return id;
}

fn labelFor(app: *App, opts: OpenOptions) Allocator.Error![]u8 {
    const gpa = app.gpa;
    if (opts.label) |l| return gpa.dupe(u8, l);
    if (opts.argv.len == 0) {
        // The same choice the session makes: `$SHELL` on POSIX, `%COMSPEC%`
        // on Windows (where `$SHELL`, if set at all, is Git Bash's fiction).
        const shell = if (pty.is_windows) pty.win_cmdline.defaultShell(&app.env) else app.env.get("SHELL") orelse "sh";
        return gpa.dupe(u8, std.fs.path.basename(shell));
    }
    return std.mem.join(gpa, " ", opts.argv);
}

/// A guess at the pane's size before the first frame lays it out; the
/// frame corrects it and the child gets one SIGWINCH.
fn initialSize(app: *App, placement: Placement) struct { cols: u16, rows: u16 } {
    const body_w = app.screen.width -| (if (app.tree.visible) app.tree.width + 1 else 0);
    const body_h = app.screen.height -| 2;
    const cols: u16 = switch (placement) {
        .right, .left => body_w / 2,
        else => body_w,
    };
    const rows: u16 = switch (placement) {
        .below, .above => body_h / 2,
        else => body_h,
    };
    return .{ .cols = @max(cols, 2), .rows = @max(rows, 1) };
}

/// Put `id` where `placement` says. With no active leaf it simply
/// becomes the only one.
fn place(app: *App, id: PaneId, placement: Placement) Allocator.Error!void {
    const layout = app.layouts.current();
    const anchor: ?PaneId = if (app.active) |a| (if (layout.leafOf(a) != null) a else null) else null;
    if (anchor == null or placement == .tab) {
        app.showPane(id);
        return;
    }
    const dir: layout_mod.SplitDir = switch (placement) {
        .below, .above => .vertical,
        .right, .left => .horizontal,
        .tab => unreachable,
    };
    const new_leaf = (try layout.split(anchor.?, dir, id)) orelse {
        app.showPane(id);
        return;
    };
    if (placement == .above or placement == .left) {
        // `split` puts the new leaf second; swap the halves.
        const parent = parentSplit(layout, new_leaf) orelse return app.setActive(id);
        const s = &layout.node(parent).split;
        std.mem.swap(layout_mod.NodeId, &s.first, &s.second);
    }
    app.setActive(id);
}

fn parentSplit(layout: *layout_mod.Layout, child: layout_mod.NodeId) ?layout_mod.NodeId {
    for (layout.nodes.items, 0..) |n, i| switch (n) {
        .split => |s| if (s.first == child or s.second == child) return @intCast(i),
        else => {},
    };
    return null;
}

/// Replace the child with a fresh one running the same command line.
pub fn restart(app: *App, id: PaneId) CommandError!void {
    if (!supported) return error.Unsupported;
    const pane = app.panes.get(id) orelse return error.NoActivePane;
    const p = switch (pane.*) {
        .pty => |*p| p,
        else => return error.NotAnEditor,
    };
    const fresh = pty.Session.spawn(app.gpa, app.io, .{
        .cols = p.cols,
        .rows = p.rows,
        .env = &app.env,
        .argv = if (p.argv.len == 0) null else @ptrCast(p.argv),
        .cwd = p.cwd orelse app.workspace,
        .notify = .{ .ctx = p.wire, .fn_ptr = &Wire.readable },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return app.diag.fail(app.frame.allocator(), "{s}: {s}", .{ p.label, @errorName(err) }),
    };
    p.session.deinit();
    p.grid.deinit(app.gpa);
    p.grid = .{};
    p.session = fresh;
    p.exit = null;
    app.needs_render = true;
}

// ─── the event side ─────────────────────────────────────────────────────

/// `.pty_readable{id}` landed: pump that pane.
pub fn onReadable(app: *App, id: PaneId) void {
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .pty => |*p| p.pump(app),
        else => {},
    }
}

/// Every tick: a pane with ringed bytes whose wakeup was dropped, and a
/// child that died without closing the pty, are both picked up here.
pub fn tickAll(app: *App) void {
    if (!supported) return;
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| {
            if (p.exit != null) continue;
            if (p.session.shared.ring.len() > 0 or p.session.eof()) {
                p.pump(app);
            } else if (p.session.exited()) |e| {
                p.exit = PtyPane.exitOf(e);
                app.needs_render = true;
            }
        },
        else => {},
    };
}

// ─── input ──────────────────────────────────────────────────────────────

/// Chords a terminal owns outright: job control and readline's clear.
/// The chord chain never sees these while a pty pane is focused.
pub fn childOwned(k: Key) bool {
    if (!k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const c = switch (k.code) {
        .char => |c| c,
        else => return false,
    };
    return c == 'c' or c == 'd' or c == 'z' or c == 'l';
}

/// A key for the child. Shift+PageUp/PageDown/Home/End scroll the
/// scrollback instead of being sent.
pub fn feedKey(app: *App, p: *PtyPane, k: Key) void {
    const rows: isize = @intCast(@max(app.pane_rows, 2));
    if (k.mods.shift and !k.mods.ctrl and !k.mods.alt) switch (k.code) {
        .page_up => return p.scrollBy(-(rows - 1)),
        .page_down => return p.scrollBy(rows - 1),
        .home => return p.scrollTo(.top),
        .end => return p.scrollTo(.bottom),
        else => {},
    };
    var buf: [16]u8 = undefined;
    const bytes = encodeKey(k, p.encoding(), &buf);
    if (bytes.len > 0) p.write(bytes);
}

/// Paste: bracketed when the child asked for it, else the text with
/// newlines as carriage returns (what a keyboard would have sent).
pub fn paste(app: *App, p: *PtyPane, text: []const u8) Allocator.Error!void {
    const enc = p.encoding();
    if (enc.bracketed_paste) {
        const wrapped = try std.mem.concat(app.frame.allocator(), u8, &.{ "\x1b[200~", text, "\x1b[201~" });
        p.write(wrapped);
        return;
    }
    const copy = try app.frame.allocator().dupe(u8, text);
    for (copy) |*c| if (c.* == '\n') {
        c.* = '\r';
    };
    p.write(copy);
}

/// A mouse event inside the pane's rect: a report to the child when it
/// tracks the mouse, else the wheel scrolls the scrollback.
pub fn mouse(app: *App, p: *PtyPane, m: Mouse, origin: struct { x: u16, y: u16 }) void {
    const enc = p.encoding();
    if (enc.mouse == .none) {
        switch (m.kind) {
            .scroll_up => p.scrollBy(-3),
            .scroll_down => p.scrollBy(3),
            else => {},
        }
        app.needs_render = true;
        return;
    }
    var buf: [32]u8 = undefined;
    const bytes = encodeMouse(m, m.x -| origin.x, m.y -| origin.y, enc, &buf);
    if (bytes.len > 0) p.write(bytes);
}

// ─── encoders ───────────────────────────────────────────────────────────

pub const MouseMode = enum { none, x10, normal, button, any };

/// What the child has switched on; both encoders read it.
pub const Encoding = struct {
    /// Kitty keyboard protocol (disambiguate or report-all) is active.
    kitty: bool = false,
    /// DECCKM: arrows as `ESC O A` instead of `CSI A`.
    cursor_keys_app: bool = false,
    bracketed_paste: bool = false,
    mouse: MouseMode = .none,
    /// SGR (1006) reports; else the X10 byte form.
    mouse_sgr: bool = false,
};

fn modParam(m: key_mod.Mods) u8 {
    var v: u8 = 1;
    if (m.shift) v += 1;
    if (m.alt) v += 2;
    if (m.ctrl) v += 4;
    if (m.super) v += 8;
    return v;
}

/// The bytes a terminal sends for `k`. Empty for keys with no encoding.
pub fn encodeKey(k: Key, enc: Encoding, buf: *[16]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    encodeKeyInto(&w, k, enc) catch return buf[0..0];
    return w.buffered();
}

fn encodeKeyInto(w: *Io.Writer, k: Key, enc: Encoding) Io.Writer.Error!void {
    const mods = k.mods;
    const modified = mods.ctrl or mods.alt or mods.super;
    const mp = modParam(mods);
    switch (k.code) {
        .char => |c| {
            if (enc.kitty and modified) {
                // Kitty: the unshifted codepoint carries the modifiers.
                const lower: u21 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
                const shift_of_upper = c >= 'A' and c <= 'Z';
                var m = mods;
                if (shift_of_upper) m.shift = true;
                return w.print("\x1b[{d};{d}u", .{ lower, modParam(m) });
            }
            if (mods.alt) try w.writeByte(0x1b);
            if (mods.ctrl) {
                const lower: u21 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
                const ctl: ?u8 = switch (lower) {
                    'a'...'z' => @intCast(lower - 'a' + 1),
                    ' ', '@' => 0,
                    '[' => 0x1b,
                    '\\' => 0x1c,
                    ']' => 0x1d,
                    '^' => 0x1e,
                    '_', '?' => 0x1f,
                    else => null,
                };
                if (ctl) |b| return w.writeByte(b);
            }
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &utf8) catch return;
            try w.writeAll(utf8[0..n]);
        },
        .enter => {
            if (enc.kitty and mp != 1) return w.print("\x1b[13;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte('\r');
        },
        .tab => {
            if (enc.kitty and mp != 1) return w.print("\x1b[9;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte('\t');
        },
        .backtab => {
            if (enc.kitty) return w.writeAll("\x1b[9;2u");
            try w.writeAll("\x1b[Z");
        },
        .backspace => {
            if (enc.kitty and mp != 1) return w.print("\x1b[127;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte(0x7f);
        },
        .esc => {
            if (enc.kitty) return if (mp != 1) w.print("\x1b[27;{d}u", .{mp}) else w.writeAll("\x1b[27u");
            try w.writeByte(0x1b);
        },
        .up, .down, .right, .left, .home, .end => {
            const final: u8 = switch (k.code) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                .end => 'F',
                else => unreachable,
            };
            if (mp != 1) return w.print("\x1b[1;{d}{c}", .{ mp, final });
            if (enc.cursor_keys_app) return w.print("\x1bO{c}", .{final});
            try w.print("\x1b[{c}", .{final});
        },
        .insert, .delete, .page_up, .page_down => {
            const n: u8 = switch (k.code) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                .page_down => 6,
                else => unreachable,
            };
            if (mp != 1) return w.print("\x1b[{d};{d}~", .{ n, mp });
            try w.print("\x1b[{d}~", .{n});
        },
        .f => |n| switch (n) {
            1...4 => {
                const final: u8 = 'P' + (n - 1);
                if (mp != 1) return w.print("\x1b[1;{d}{c}", .{ mp, final });
                try w.print("\x1bO{c}", .{final});
            },
            5...12 => {
                const code: u8 = switch (n) {
                    5 => 15,
                    6 => 17,
                    7 => 18,
                    8 => 19,
                    9 => 20,
                    10 => 21,
                    11 => 23,
                    12 => 24,
                    else => unreachable,
                };
                if (mp != 1) return w.print("\x1b[{d};{d}~", .{ code, mp });
                try w.print("\x1b[{d}~", .{code});
            },
            else => {},
        },
    }
}

/// A mouse report for a cell-relative event. `x`/`y` are 0-based cells
/// inside the pane. Empty when the mode does not report this event.
pub fn encodeMouse(m: Mouse, x: u16, y: u16, enc: Encoding, buf: *[32]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    encodeMouseInto(&w, m, x, y, enc) catch return buf[0..0];
    return w.buffered();
}

fn encodeMouseInto(w: *Io.Writer, m: Mouse, x: u16, y: u16, enc: Encoding) Io.Writer.Error!void {
    var btn: u32 = switch (m.kind) {
        .scroll_up => 64,
        .scroll_down => 65,
        else => switch (m.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .none => 3,
        },
    };
    switch (m.kind) {
        .drag => {
            if (enc.mouse != .button and enc.mouse != .any) return;
            btn += 32;
        },
        .motion => {
            if (enc.mouse != .any) return;
            btn += 32;
        },
        .release => if (enc.mouse == .x10) return,
        .press, .scroll_up, .scroll_down => {},
    }
    if (enc.mouse != .x10) {
        if (m.mods.shift) btn += 4;
        if (m.mods.alt) btn += 8;
        if (m.mods.ctrl) btn += 16;
    }
    if (enc.mouse_sgr) {
        const final: u8 = if (m.kind == .release) 'm' else 'M';
        return w.print("\x1b[<{d};{d};{d}{c}", .{ btn, x + 1, y + 1, final });
    }
    // X10 bytes: 32 + value, cells 1-based, clamped to what fits a byte.
    const b: u8 = @intCast(32 + (if (m.kind == .release) 3 else btn));
    try w.writeAll("\x1b[M");
    try w.writeByte(b);
    try w.writeByte(@intCast(@min(32 + x + 1, 255)));
    try w.writeByte(@intCast(@min(32 + y + 1, 255)));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn encoded(k: Key, e: Encoding) []const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    return encodeKey(k, e, &S.buf);
}

test "legacy key encoding: text, control bytes, alt prefix, arrows with and without modifiers" {
    try t.expectEqualStrings("a", encoded(Key.char('a'), .{}));
    try t.expectEqualStrings("é", encoded(Key.char('é'), .{}));
    try t.expectEqualStrings("\x03", encoded(Key.ctrl('c'), .{}));
    try t.expectEqualStrings("\x1b", encoded(Key.ctrl('['), .{}));
    try t.expectEqualStrings("\x00", encoded(Key.ctrl(' '), .{}));
    try t.expectEqualStrings("\x1bb", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true } }, .{}));
    try t.expectEqualStrings("\x1b\x02", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true, .ctrl = true } }, .{}));
    try t.expectEqualStrings("\r", encoded(Key.named(.enter), .{}));
    try t.expectEqualStrings("\x7f", encoded(Key.named(.backspace), .{}));
    try t.expectEqualStrings("\x1b[Z", encoded(Key.named(.backtab), .{}));
    try t.expectEqualStrings("\x1b", encoded(Key.named(.esc), .{}));
    try t.expectEqualStrings("\x1b[A", encoded(Key.named(.up), .{}));
    try t.expectEqualStrings("\x1bOA", encoded(Key.named(.up), .{ .cursor_keys_app = true }));
    try t.expectEqualStrings("\x1b[1;5C", encoded(.{ .code = .right, .mods = .{ .ctrl = true } }, .{}));
    try t.expectEqualStrings("\x1b[1;2H", encoded(.{ .code = .home, .mods = .{ .shift = true } }, .{}));
    try t.expectEqualStrings("\x1b[3~", encoded(Key.named(.delete), .{}));
    try t.expectEqualStrings("\x1b[5;3~", encoded(.{ .code = .page_up, .mods = .{ .alt = true } }, .{}));
    try t.expectEqualStrings("\x1bOP", encoded(Key.named(.{ .f = 1 }), .{}));
    try t.expectEqualStrings("\x1b[15~", encoded(Key.named(.{ .f = 5 }), .{}));
    try t.expectEqualStrings("\x1b[24;5~", encoded(.{ .code = .{ .f = 12 }, .mods = .{ .ctrl = true } }, .{}));
    try t.expectEqualStrings("", encoded(Key.named(.{ .f = 13 }), .{}));
}

test "kitty key encoding: CSI u for modified and ambiguous keys, plain text stays text" {
    const k: Encoding = .{ .kitty = true };
    try t.expectEqualStrings("a", encoded(Key.char('a'), k));
    try t.expectEqualStrings("A", encoded(Key.char('A'), k));
    try t.expectEqualStrings("\x1b[99;5u", encoded(Key.ctrl('c'), k));
    try t.expectEqualStrings("\x1b[99;6u", encoded(Key.ctrl('C'), k));
    try t.expectEqualStrings("\x1b[98;3u", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true } }, k));
    try t.expectEqualStrings("\x1b[27u", encoded(Key.named(.esc), k));
    try t.expectEqualStrings("\x1b[27;5u", encoded(.{ .code = .esc, .mods = .{ .ctrl = true } }, k));
    try t.expectEqualStrings("\r", encoded(Key.named(.enter), k));
    try t.expectEqualStrings("\x1b[13;2u", encoded(.{ .code = .enter, .mods = .{ .shift = true } }, k));
    try t.expectEqualStrings("\x1b[9;2u", encoded(Key.named(.backtab), k));
    try t.expectEqualStrings("\x1b[127;3u", encoded(.{ .code = .backspace, .mods = .{ .alt = true } }, k));
    try t.expectEqualStrings("\x1b[B", encoded(Key.named(.down), k));
    try t.expectEqualStrings("\x1b[1;5B", encoded(.{ .code = .down, .mods = .{ .ctrl = true } }, k));
}

test "mouse reports: SGR press/release/drag/wheel, modes gate motion, x10 bytes" {
    var buf: [32]u8 = undefined;
    const sgr_any: Encoding = .{ .mouse = .any, .mouse_sgr = true };
    try t.expectEqualStrings("\x1b[<0;5;3M", encodeMouse(.{ .x = 4, .y = 2, .kind = .press, .button = .left }, 4, 2, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<0;5;3m", encodeMouse(.{ .x = 4, .y = 2, .kind = .release, .button = .left }, 4, 2, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<32;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<35;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<64;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .scroll_up }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<18;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .press, .button = .right, .mods = .{ .ctrl = true } }, 0, 0, sgr_any, &buf));
    // Normal mode: presses only, no motion.
    const sgr_normal: Encoding = .{ .mouse = .normal, .mouse_sgr = true };
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_normal, &buf));
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_normal, &buf));
    // Button mode reports drags, not bare motion.
    const sgr_button: Encoding = .{ .mouse = .button, .mouse_sgr = true };
    try t.expectEqualStrings("\x1b[<32;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_button, &buf));
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_button, &buf));
    // X10 byte form.
    const x10: Encoding = .{ .mouse = .normal };
    try t.expectEqualStrings("\x1b[M\x20\x21\x21", encodeMouse(.{ .x = 0, .y = 0, .kind = .press, .button = .left }, 0, 0, x10, &buf));
    try t.expectEqualStrings("\x1b[M\x23\x21\x21", encodeMouse(.{ .x = 0, .y = 0, .kind = .release, .button = .left }, 0, 0, x10, &buf));
}

test "childOwned: ctrl+c/d/z/l only" {
    try t.expect(childOwned(Key.ctrl('c')));
    try t.expect(childOwned(Key.ctrl('l')));
    try t.expect(!childOwned(Key.ctrl('p')));
    try t.expect(!childOwned(Key.char('c')));
    try t.expect(!childOwned(.{ .code = .{ .char = 'c' }, .mods = .{ .ctrl = true, .alt = true } }));
}

// ─── the pane end to end ───────────────────────────────────────────────

const screen_mod = @import("../ipc/screen.zig");

/// Tick + render until `needle` is on screen or `ms` elapse.
pub fn tickUntilScreen(app: *App, needle: []const u8, ms: u32) !bool {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        try app.render();
        const txt = try screen_mod.toTestText(app.gpa, &app.screen);
        defer app.gpa.free(txt);
        if (std.mem.indexOf(u8, txt, needle) != null) return true;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a scripted child's coloured line reaches the cells, the exit is noticed, a key then closes the pane" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try open(&app, .{
        .argv = &.{ "/bin/sh", "-c", "printf '\\033[32mgreen\\033[0m plain\\n'; exit 4" },
        .label = "script",
        .kind = .command,
    });
    try t.expectEqual(id, app.active.?);
    try t.expectEqualStrings("script", app.panes.get(id).?.title());
    try t.expect(try tickUntilScreen(&app, "green plain", 5000));
    // The "g" of "green" carries palette 2; "plain" does not.
    var found = false;
    var y: u16 = 0;
    while (y < 12 and !found) : (y += 1) {
        var x: u16 = 0;
        while (x < 60) : (x += 1) {
            const cell = app.screen.readCell(x, y) orelse continue;
            if (std.mem.eql(u8, cell.char.grapheme, "g")) {
                try t.expectEqual(@as(u8, 2), cell.style.fg.index);
                const p = app.screen.readCell(x + 6, y).?;
                try t.expectEqualStrings("p", p.char.grapheme);
                try t.expect(p.style.fg != .index);
                found = true;
                break;
            }
        }
    }
    try t.expect(found);
    try t.expect(try tickUntilScreen(&app, "[exited 4]", 5000));
    try t.expectEqual(Exit{ .code = 4 }, app.panes.pty(id).?.exit.?);
    // Any plain key closes an exited pane.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.panes.get(id) == null);
    try t.expect(app.active == null);
}

test "keys reach the child: typed text and ctrl+d end a cat that echoes back" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo; cat | tr a-z A-Z" }, .label = "cat" });
    // Give the shell a beat to set up the tty, then type.
    app.io.sleep(.fromMilliseconds(200), .awake) catch {};
    for ("shout") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(try tickUntilScreen(&app, "SHOUT", 5000));
    try app.handle(.{ .key = Key.ctrl('d') });
    try t.expect(try tickUntilScreen(&app, "[exited 0]", 5000));
    try t.expect(app.panes.pty(id).?.exit.?.ok());
}

test "paste is bracketed only when the child asked; a newline becomes a carriage return otherwise" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    // The child switches bracketed paste on, then dumps what it reads as octal.
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty raw -echo; printf '\\033[?2004h'; dd bs=1 count=12 2>/dev/null | od -An -c" }, .label = "od" });
    app.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try app.tick(App.nowMs(app.io));
    try t.expect(app.panes.pty(id).?.encoding().bracketed_paste);
    const text = try app.gpa.dupe(u8, "ab");
    try app.handle(.{ .paste = text });
    try t.expect(try tickUntilScreen(&app, "2   0   0   ~   a   b", 5000));
}
