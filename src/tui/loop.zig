//! The terminal loop (D3): one wait on the app's event queue, a
//! non-blocking drain, tick, render, `term.render`. Terminal input is a
//! worker like any other — a bridge task turns `Term`'s events into
//! `AppEvent`s and posts them — so the UI thread has exactly one wait,
//! and an idle app sleeps until the next timer or keystroke.
//!
//! Exit 75 is the restart handshake `run.sh` relaunches on.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Term = @import("term.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");
const screen_mod = @import("../ipc/screen.zig");
const build_options = @import("build_options");

pub const Options = struct {
    /// The merged config; the App takes ownership.
    loaded: config.Loaded,
    /// Absolute.
    workspace: []const u8,
    data_root: []const u8 = "",
    /// Files to open at start, workspace-relative or absolute.
    files: []const []const u8 = &.{},
};

/// Run until the app quits. Returns the exit code: 75 for a restart.
pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, opts: Options) !u8 {
    // Term is intrusive (its writer buffers into itself); heap it so it
    // never moves.
    const term = try gpa.create(Term);
    defer gpa.destroy(term);
    try term.init(io, gpa, env, .{});
    defer term.deinit();

    const size = term.screen();
    var app = try App.initWith(gpa, io, .{
        .cfg = opts.loaded.config,
        .loaded = opts.loaded,
        .workspace = opts.workspace,
        .data_root = opts.data_root,
        .cols = size.width,
        .rows = size.height,
    });
    defer app.deinit();
    // `ipc.write_screen`: mirror every frame into `<ws>/.mnml/<ipc>/screen.txt`,
    // the file the headless loop writes, so a script can watch the real
    // terminal session too.
    var screen_dump: ?ipc.Channel = null;
    if (app.cfg.ipc.write_screen) {
        screen_dump = ipc.Channel.init(gpa, io, opts.workspace, .{ .dir_override = env.get("MNML_IPC_DIR"), .subdir = build_options.ipc_subdir }) catch |err| blk: {
            app.toast("ipc.write_screen: cannot open the channel: {s}", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (screen_dump) |*c| c.deinit();
    for (opts.files) |f| {
        const abs = try app.absPath(f);
        _ = app.openPath(abs) catch |err| app.toast("open {s}: {s}", .{ f, @errorName(err) });
    }
    app.hooks.emit(&app, .startup);

    var bridge: Io.Group = .init;
    try bridge.concurrent(io, bridgeTask, .{ term, &app });
    defer bridge.cancel(io);

    var buf: [64]event.AppEvent = undefined;
    while (!app.quit) {
        const timeout: Io.Timeout = if (app.nextDeadlineMs()) |deadline| blk: {
            const ms = @max(deadline - App.nowMs(io), 0);
            break :blk .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } };
        } else .none;
        app.events.wake.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => break,
        };
        app.events.wake.reset();
        while (true) {
            const n = app.events.drain(io, &buf);
            if (n == 0) break;
            for (buf[0..n]) |ev| {
                if (ev == .winsize) term.resize(.{ .rows = ev.winsize.rows, .cols = ev.winsize.cols, .x_pixel = 0, .y_pixel = 0 }) catch {};
                try app.handle(ev);
            }
        }
        try app.tick(App.nowMs(io));
        if (app.needs_render) {
            try app.renderInto(term.screen());
            term.render() catch {};
            if (screen_dump) |*c| c.writeScreen(try screen_mod.toScreenTxt(app.frame.allocator(), term.screen()));
        }
    }
    app.hooks.emit(&app, .exit);
    return if (app.restart) 75 else 0;
}

/// `Term` events → `AppEvent`s, until the group is cancelled.
fn bridgeTask(term: *Term, app: *App) Io.Cancelable!void {
    while (true) {
        const ev = term.next() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        switch (ev) {
            .key_press => |k| if (translateKey(k)) |key| app.events.post(app.io, .{ .key = key }),
            .key_release => {},
            .mouse => |m| app.events.post(app.io, .{ .mouse = translateMouse(m) }),
            .winsize => |ws| app.events.post(app.io, .{ .winsize = .{ .cols = ws.cols, .rows = ws.rows } }),
            .paste => |text| {
                // Term hands the payload to us gpa-owned; the event owns it now.
                app.events.post(app.io, .{ .paste = @constCast(text) });
            },
            .focus_in => app.events.post(app.io, .{ .focus = true }),
            .focus_out => app.events.post(app.io, .{ .focus = false }),
            else => {},
        }
    }
}

/// vaxis key → trunk key. Text keys use the shifted codepoint (`P`
/// stays `P`); a legacy control byte reads as `ctrl+<letter>`; the
/// modifier-only presses kitty reports are dropped.
pub fn translateKey(k: vaxis.Key) ?key_mod.Key {
    if (k.isModifier()) return null;
    var mods: key_mod.Mods = .{ .ctrl = k.mods.ctrl, .shift = k.mods.shift, .alt = k.mods.alt, .super = k.mods.super or k.mods.meta or k.mods.hyper };
    const code: key_mod.KeyCode = switch (k.codepoint) {
        vaxis.Key.escape => .esc,
        vaxis.Key.enter, vaxis.Key.kp_enter => .enter,
        vaxis.Key.tab => if (mods.shift) blk: {
            mods.shift = false;
            break :blk .backtab;
        } else .tab,
        vaxis.Key.backspace, 0x08 => .backspace,
        vaxis.Key.delete => .delete,
        vaxis.Key.insert => .insert,
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.f1...vaxis.Key.f12 => .{ .f = @intCast(k.codepoint - vaxis.Key.f1 + 1) },
        else => blk: {
            if (k.codepoint < 0x20) {
                // Legacy terminal: ^A..^Z arrive as 0x01..0x1a with no mods.
                mods.ctrl = true;
                break :blk .{ .char = k.codepoint + 0x60 };
            }
            if (!mods.ctrl and !mods.alt and !mods.super) {
                if (k.shifted_codepoint) |sc| {
                    mods.shift = false;
                    break :blk .{ .char = sc };
                }
                if (k.text) |text| {
                    const cp = std.unicode.utf8Decode(text[0..@min(text.len, std.unicode.utf8ByteSequenceLength(text[0]) catch 1)]) catch k.codepoint;
                    mods.shift = false;
                    break :blk .{ .char = cp };
                }
            }
            break :blk .{ .char = k.codepoint };
        },
    };
    return .{ .code = code, .mods = mods };
}

pub fn translateMouse(m: vaxis.Mouse) key_mod.Mouse {
    const kind: key_mod.MouseKind = switch (m.button) {
        .wheel_up => .scroll_up,
        .wheel_down => .scroll_down,
        else => switch (m.type) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            .motion => .motion,
        },
    };
    const button: key_mod.MouseButton = switch (m.button) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        else => .none,
    };
    return .{
        .x = @intCast(@max(m.col, 0)),
        .y = @intCast(@max(m.row, 0)),
        .kind = kind,
        .button = button,
        .mods = .{ .ctrl = m.mods.ctrl, .shift = m.mods.shift, .alt = m.mods.alt },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "translateKey: named keys, shifted text, legacy control bytes, kitty chords" {
    try t.expect(translateKey(.{ .codepoint = vaxis.Key.escape }).?.code == .esc);
    try t.expect(translateKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } }).?.code == .backtab);
    const p = translateKey(.{ .codepoint = 'p', .shifted_codepoint = 'P', .text = "P", .mods = .{ .shift = true } }).?;
    try t.expectEqual(@as(u21, 'P'), p.code.char);
    try t.expect(!p.mods.shift);
    const ctrl_a = translateKey(.{ .codepoint = 0x01 }).?;
    try t.expectEqual(@as(u21, 'a'), ctrl_a.code.char);
    try t.expect(ctrl_a.mods.ctrl);
    const csp = translateKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true, .shift = true } }).?;
    try t.expect(csp.mods.ctrl and csp.mods.shift);
    try t.expectEqual(@as(u8, 5), translateKey(.{ .codepoint = vaxis.Key.f5 }).?.code.f);
    try t.expect(translateKey(.{ .codepoint = vaxis.Key.left_shift, .mods = .{ .shift = true } }) == null);
}

test "translateMouse: wheel buttons become scroll kinds, coordinates clamp at zero" {
    const up = translateMouse(.{ .col = 3, .row = 4, .button = .wheel_up, .mods = .{}, .type = .press });
    try t.expect(up.kind == .scroll_up);
    try t.expectEqual(@as(u16, 3), up.x);
    const drag = translateMouse(.{ .col = -1, .row = 2, .button = .left, .mods = .{ .ctrl = true }, .type = .drag });
    try t.expect(drag.kind == .drag and drag.button == .left and drag.mods.ctrl);
    try t.expectEqual(@as(u16, 0), drag.x);
}
