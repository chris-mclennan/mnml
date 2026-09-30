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
const Term = @import("term.zig").Term;
const log_sink = @import("../core/log_sink.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const config = @import("../config/root.zig");
const profile = config.profile;
const ipc = @import("../ipc/root.zig");
const screen_mod = @import("../ipc/screen.zig");
const integrations = @import("../app/integrations.zig");
const build_options = @import("build_options");
const tasks = @import("../app/tasks.zig");
const clipboard_os = @import("../core/clipboard_os.zig");
const image = @import("../image/root.zig");
const marker = @import("marker.zig");
const app_driver = @import("../app/driver.zig");
const pty_pane = @import("../app/pty_pane.zig");
const exit_signal = @import("../core/exit_signal.zig");

/// How often the IPC tail looks at `command`. A wrapper's `stop` /
/// `restart` lands within this; the UI thread's one wait is untouched.
const ipc_poll_ms = 200;

pub const Options = struct {
    /// The merged config; the App takes ownership.
    loaded: config.Loaded,
    /// Absolute.
    workspace: []const u8,
    data_root: []const u8 = "",
    /// Files to open at start, workspace-relative or absolute.
    files: []const []const u8 = &.{},
    /// A line for the first frame — the dev profile's "seeded from …".
    note: ?[]const u8 = null,
};

/// Run until the app quits. Returns the exit code: 75 for a restart.
pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, opts: Options) !u8 {
    // The config is the App's from `App.initWith` on (which frees it on
    // its own failure too); an exit before that — no terminal to take —
    // frees it here.
    var loaded = opts.loaded;
    var handed = false;
    errdefer if (!handed) loaded.deinit();
    // Term is intrusive (its writer buffers into itself); heap it so it
    // never moves.
    const term = try gpa.create(Term);
    defer gpa.destroy(term);
    // From before the terminal is taken until after it is given back,
    // `std.log` writes to `mnml.log`, not over the screen.
    log_sink.toFile(opts.data_root);
    defer log_sink.restore();
    try term.init(io, gpa, env, .{});
    defer term.deinit();
    // The window title names the workspace ("mnml — work"), so several
    // mnml tabs stay telling apart — and `scripts/shot.sh` finds the
    // window by it.
    // The dev profile says so in the title, so the window you are
    // looking at names which mnml it is ("mnml [dev] — work").
    {
        const base = std.fs.path.basename(opts.workspace);
        // A sandbox says so in the title as well as on the statusline.
        const tag = if (config.sandbox.state(env, opts.data_root) != .off) "sandbox" else profile.tag(profile.of(env));
        var title_buf: [256]u8 = undefined;
        const title = if (tag.len > 0)
            std.fmt.bufPrint(&title_buf, "mnml [{s}]{s}{s}", .{ tag, if (base.len > 0) " — " else "", base }) catch "mnml"
        else if (base.len > 0)
            std.fmt.bufPrint(&title_buf, "mnml — {s}", .{base}) catch "mnml"
        else
            "mnml";
        term.setTitle(title) catch {};
    }

    const size = term.screen();
    handed = true;
    var app = try App.initWith(gpa, io, .{
        .cfg = loaded.config,
        .loaded = loaded,
        .workspace = opts.workspace,
        .data_root = opts.data_root,
        .cols = size.width,
        .rows = size.height,
        .env = env,
        .native_notify = true,
        // The one loop with a real terminal cursor to hand a frame's
        // position and shape to.
        .term_cursor = true,
        .live_frames = true,
    });
    defer app.deinit();
    // The one place the App meets a live terminal: `"+` / `"*` get the
    // session's buffered stdout for OSC 52 — the writer `term.render`
    // uses, so the sequence never lands inside a frame — and whatever
    // clipboard tool `$PATH` has. `editor.clipboard` picks between them;
    // `App.initWith` alone leaves the sink `.none` (headless, `.test`).
    app.clipboard.attach(io, term.writer(), clipboard_os.probe(io, env), app.cfg.editor.clipboard);
    // The escapes meant for the terminal itself (a session notification)
    // are this loop's to write.
    app.host_tty = true;
    // The IPC channel at `<ws>/.mnml/<ipc>/`: `command` is tailed for the
    // lifecycle lines `run.sh stop` / `restart` drop (`ipcTask`), and with
    // `ipc.write_screen` every frame is mirrored into `screen.txt` — the
    // file the headless loop writes — so a script can watch the real
    // terminal session too.
    var channel: ?ipc.Channel = null;
    channel = ipc.Channel.init(gpa, io, opts.workspace, .{ .dir_override = env.get("MNML_IPC_DIR"), .subdir = profile.ipcSubdir(profile.of(env)) }) catch |err| blk: {
        app.toast("ipc: cannot open the channel: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (channel) |*c| c.deinit();
    const screen_dump: ?*ipc.Channel = if (app.cfg.ipc.write_screen and channel != null) &channel.? else null;
    // The running-instance marker `run.sh` and `scripts/shot.sh` find
    // this instance by. Removed on a clean exit below — not on a restart,
    // where the wrapper relaunches straight away.
    const marker_path = try marker.path(gpa, env);
    defer gpa.free(marker_path);
    // A `--sandbox` run writes no marker: `run.sh restart` / `stop` and
    // `scripts/shot.sh` mean YOUR instance, and a sandbox must not take
    // the marker from under it.
    const sandboxed = app.sandboxState() != .off;
    if (!sandboxed) marker.write(io, marker_path, opts.workspace) catch |err| app.toast("marker: {s}: {s}", .{ marker_path, @errorName(err) });
    if (opts.note) |n| app.toast("{s}", .{n});
    switch (app.sandboxState()) {
        .off => {},
        // `--demo` says its own piece in `opts.note` (what it set up, and
        // anything it had to skip).
        .on => if (!app.demoActive()) app.toast("sandbox — HOME is {s}; your real config and state are untouched. Removed on exit (--sandbox-keep keeps it).", .{env.get(config.sandbox.env_var) orelse ""}),
        .unsafe => try app.toastPersistent("sandbox-unsafe", "MNML_SANDBOX is set, but HOME or the data root is NOT a throwaway directory — this session can touch your real setup.", .warn),
    }
    // Images: the probe (kitty graphics) and the environment decide the
    // transport once; `.none` leaves the text fallback.
    app.image_transport = image.detect(env, term.caps.kitty_graphics);
    var painter: image.Painter = .{};
    defer painter.deinit(gpa);
    // The typed config's tasks + startup list, from the config the App
    // already owns; the `startup` hook below runs the startup names.
    try tasks.installFromConfig(&app, &app.cfg);
    for (opts.files) |f| {
        const abs = try app.absPath(f);
        _ = app.openPath(abs) catch |err| app.toast("open {s}: {s}", .{ f, @errorName(err) });
    }
    // The manifests' chips, their commands and the statusline poller all
    // come out of this scan, and it used to wait until someone opened
    // the INTEGRATIONS section — so a chip whose whole job is to sit on
    // the statusline was blank until you went looking for it, and the
    // poller that keeps its count live did not exist yet. A directory of
    // small `.zon` files is cheap; being wrong at rest is not.
    //
    // Only here, in the real terminal: a headless run and the corpus
    // scan when they ask to, and their counts are written against that.
    integrations.refresh(&app) catch |err| app.toast("integrations: {s}", .{@errorName(err)});
    // The API brokers this mnml hosts (`app/broker.zig`). Here rather
    // than on the first tick, because an mnml that opens and is left
    // alone never ticks — it parks on the event queue with no deadline
    // — and the pane somebody opens an hour later should find a broker
    // rather than the file bucket. `tick` only re-checks after this.
    @import("../app/broker.zig").sync(&app);
    app.hooks.emit(&app, .startup);
    // After the session restore, so its toast lands on the restored
    // frame; only here, because it reaches GitHub.
    @import("../app/update.zig").startupCheck(&app);
    @import("../app/font_scan.zig").startupFetch(&app);
    // Once, until Enter says the setup is done (after the trust dialog).
    try @import("../app/first_launch.zig").showIfPending(&app);

    var bridge: Io.Group = .init;
    try bridge.concurrent(io, bridgeTask, .{ term, &app });
    if (channel) |*c| try bridge.concurrent(io, ipcTask, .{ c, &app });
    if (exit_signal.wakeFd()) |fd| try bridge.concurrent(io, signalTask, .{ fd, &app });
    defer bridge.cancel(io);

    var buf: [64]event.AppEvent = undefined;
    var last_frame_ms: i64 = 0;
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
        // SIGTERM / SIGHUP / SIGINT: out the way a quit goes — the
        // session saved, the terminal given back — with 128 + signal.
        if (exit_signal.caught()) |sig| {
            app.restart = false;
            app.exit_code = exit_signal.status(sig);
            app.quit = true;
            break;
        }
        var input_seen = false;
        while (true) {
            const n = app.events.drain(io, &buf);
            if (n == 0) break;
            for (buf[0..n]) |ev| {
                // Terminal output waits for `tick`: `pty_pane.tickAll`
                // gives every pane with ringed bytes one bounded pump per
                // pass, after all the input that is here. Pumping per
                // wakeup let a flooding child refill the queue as fast as
                // this loop drained it — keys, clicks and frames waited
                // behind it for seconds.
                if (ev == .pty_readable) continue;
                input_seen = true;
                if (ev == .winsize) term.resize(.{ .rows = ev.winsize.rows, .cols = ev.winsize.cols, .x_pixel = 0, .y_pixel = 0 }) catch {};
                try app.handle(ev);
            }
        }
        try app.tick(App.nowMs(io));
        // A command an integration registered over IPC was invoked: its
        // `plugin-command` line, as the headless loop writes it.
        try app_driver.emitPluginEvents(&app, if (channel) |*c| c else null, app.frame.allocator());
        if (app.bell_pending) {
            app.bell_pending = false;
            term.writeRaw("\x07") catch {};
        }
        if (app.host_out.items.len > 0) {
            term.writeRaw(app.host_out.items) catch {};
            app.host_out.clearRetainingCapacity();
        }
        // While a terminal pane has a backlog the loop does not sleep, and
        // a frame per bounded pump spent the time the flood needed: frames
        // come at most every `flood_frame_ms` then, and at once for input.
        const now_ms = App.nowMs(io);
        const paced = pty_pane.backlog(&app) and !input_seen and now_ms - last_frame_ms < flood_frame_ms;
        if (app.needs_render and !paced) {
            last_frame_ms = now_ms;
            try app.renderInto(term.screen());
            term.render() catch {};
            // The frame's images, over the cells just written.
            painter.paint(gpa, term.writer(), app.image_transport, app.image_paints.items, .{
                .cursor_row = term.vx.state.cursor.row,
                .cursor_col = term.vx.state.cursor.col,
                .cursor_vis = term.vx.screen.cursor_vis,
                .cell_w_px = if (term.vx.screen.width > 0) @as(u32, term.vx.screen.width_pix) / term.vx.screen.width else 0,
                .cell_h_px = if (term.vx.screen.height > 0) @as(u32, term.vx.screen.height_pix) / term.vx.screen.height else 0,
            }) catch {};
            if (screen_dump) |c| {
                const arena = app.frame.allocator();
                c.writeScreen(try screen_mod.toScreenTxt(arena, term.screen()));
                // The same three files the headless loop keeps, so a
                // live session can be read the way a `.test` reads one:
                // who owns the cursor, what is focused, every hit rect.
                // The terminal's own geometry rides along: `statusOf`
                // knows the screen's cols/rows, but only this loop has
                // a terminal to ask how big a cell is in pixels, and
                // `tools/drive/` cannot click a cell without it.
                var st = try app_driver.AppDriver.statusOf(&app, arena);
                st.cell_w_px = if (term.vx.screen.width > 0) @as(u32, term.vx.screen.width_pix) / term.vx.screen.width else 0;
                st.cell_h_px = if (term.vx.screen.height > 0) @as(u32, term.vx.screen.height_pix) / term.vx.screen.height else 0;
                c.writeStatus(try screen_mod.statusJson(arena, st));
                var rects: Io.Writer.Allocating = .init(arena);
                app.hits.writeRectsJson(&rects.writer, app.overlayLabel()) catch return error.OutOfMemory;
                c.writeRects(rects.written());
            }
        }
    }
    app_driver.endSession(&app);
    // The tail stops before the channel's exit line so the two never
    // interleave; the marker outlives a restart for the relaunch.
    bridge.cancel(io);
    if (channel) |*c| c.appendEvent(if (app.restart) "{\"event\":\"exit\",\"restart\":true}" else "{\"event\":\"exit\"}");
    if (!app.restart and !sandboxed) marker.removeIfOurs(gpa, io, marker_path, opts.workspace);
    return if (app.restart) 75 else app.exit_code;
}

/// The frame interval while a terminal pane is working off a backlog.
const flood_frame_ms = 16;

/// Waits on the signal self-pipe (`core/exit_signal.zig`) and wakes the
/// UI thread, which parks on the event queue and would otherwise not
/// look at the signal until the next key or timer. Runs until the group
/// is cancelled.
fn signalTask(fd: std.posix.fd_t, app: *App) Io.Cancelable!void {
    const pipe_r: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var byte: [16]u8 = undefined;
    while (true) {
        _ = pipe_r.readStreaming(app.io, &.{&byte}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        app.events.post(app.io, .timer);
    }
}

/// Tail `<ipc>/command` and post every line as an event. Runs until the
/// group is cancelled.
///
/// It used to take `quit` and `restart` and answer everything else
/// `unsupported`, which quietly broke the thing the SDK promises: an
/// integration's `statusline-set-segment` worked under the headless
/// driver and was refused in the app the user was looking at, so the
/// `󰌃 N` chip never moved live. The tier-2 set travels now, through the
/// same dispatcher (`App.handle`'s `.ipc` arm → `ipc.effects.applyTier2`).
///
/// What is still refused is INPUT — `key`, `type`, `click`, `scroll`,
/// `drag`, `mouse_*`, `hover` — unless `ipc.allow_input` is on. A file
/// on disk typing into someone's editor is a different kind of power
/// from a file moving a number on their statusline. The `unsupported`
/// ack names the switch.
fn ipcTask(ch: *ipc.Channel, app: *App) Io.Cancelable!void {
    const io = app.io;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    while (true) {
        try io.sleep(.fromMilliseconds(ipc_poll_ms), .awake);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const lines = ch.pollLines(arena) catch continue;
        for (lines) |line| dispatchIpcLine(ch, app, arena, line) catch continue;
    }
}

/// One line: refused with a note, or parsed onto its own arena and
/// posted. Factored out of the loop so a test can drive exactly what
/// the live terminal drives.
pub fn dispatchIpcLine(ch: *ipc.Channel, app: *App, arena: std.mem.Allocator, line: []const u8) Allocator.Error!void {
    const io = app.io;
    const ev = event.IpcCommand.create(app.gpa, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (ipc.effects.isInput(&ev.cmd) and !app.cfg.ipc.allow_input) {
        const name = @tagName(ev.cmd);
        ev.destroy();
        const note = screen_mod.jsonEvent(arena, &.{
            .{ "event", "unsupported" },
            .{ "cmd", name },
            .{ "note", "the terminal loop does not take input from the channel; set `.ipc = .{ .allow_input = true }` in config.zon, or drive it headless" },
        }) catch return;
        ch.appendEvent(note);
        return;
    }
    const ack = switch (ev.cmd) {
        .quit => "{\"event\":\"quit\"}",
        .restart => "{\"event\":\"restart\"}",
        else => screen_mod.jsonEvent(arena, &.{ .{ "event", "accepted" }, .{ "cmd", @tagName(ev.cmd) } }) catch "{\"event\":\"accepted\"}",
    };
    ch.appendEvent(ack);
    app.events.post(io, .{ .ipc = ev });
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
        vaxis.Key.tab => .tab,
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
    // `Key.canonical` settles the one spelling a shifted Tab has, so
    // the terminal path and `keymap.parseKeySpec` cannot disagree.
    return (key_mod.Key{ .code = code, .mods = mods }).canonical();
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
    const shifted_tab = translateKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } }).?;
    try t.expect(shifted_tab.code == .backtab);
    try t.expect(!shifted_tab.mods.shift);
    const ctrl_shift_tab = translateKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .ctrl = true, .shift = true } }).?;
    try t.expect(ctrl_shift_tab.code == .backtab and ctrl_shift_tab.mods.ctrl and !ctrl_shift_tab.mods.shift);
    try t.expect(translateKey(.{ .codepoint = vaxis.Key.tab }).?.code == .tab);
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

test "the ghostty line for Shift+Cmd+←/→ (`docs/CONFIG.md`): `CSI 1;8C` / `CSI 1;8D` read as ctrl+alt+shift+→/←, the standard profile's split walk" {
    const keymap = @import("../core/keymap.zig");
    const command = @import("../core/command.zig");
    var km = try keymap.Keymap.build(t.allocator, .standard, .{});
    defer km.deinit();
    // Kitty's protocol keeps the legacy `CSI 1;<mods>` form for the
    // arrows, so the bytes are the same with or without it; 8 is
    // 1 + shift 1 + alt 2 + ctrl 4.
    const Case = struct { bytes: []const u8, spec: []const u8, id: command.CommandId };
    for ([_]Case{
        .{ .bytes = "\x1b[1;8C", .spec = "ctrl+alt+shift+right", .id = .@"view.focus_next_split" },
        .{ .bytes = "\x1b[1;8D", .spec = "ctrl+alt+shift+left", .id = .@"view.focus_prev_split" },
    }) |c| {
        var parser: vaxis.Parser = .{};
        const r = try parser.parse(c.bytes, null);
        try t.expectEqual(c.bytes.len, r.n);
        const k = translateKey(r.event.?.key_press).?;
        const want = keymap.parseKeySpec(c.spec).?;
        try t.expect(k.code.eql(want.code) and k.mods.eql(want.mods));
        const res = km.resolveSeq(&.{key_mod.Chord.of(k)});
        try t.expect(res == .run);
        try t.expectEqual(c.id, res.run.static);
    }
}

test "translateMouse: wheel buttons become scroll kinds, coordinates clamp at zero" {
    const up = translateMouse(.{ .col = 3, .row = 4, .button = .wheel_up, .mods = .{}, .type = .press });
    try t.expect(up.kind == .scroll_up);
    try t.expectEqual(@as(u16, 3), up.x);
    const drag = translateMouse(.{ .col = -1, .row = 2, .button = .left, .mods = .{ .ctrl = true }, .type = .drag });
    try t.expect(drag.kind == .drag and drag.button == .left and drag.mods.ctrl);
    try t.expectEqual(@as(u16, 0), drag.x);
}

test "the live loop takes the tier-2 set and refuses input: a segment lands, a key is answered with the switch that would allow it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 80, .rows = 24 });
    defer app.deinit();
    var ch = try ipc.Channel.init(t.allocator, t.io, ws, .{});
    defer ch.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What an integration publishes. Before this landed the loop
    // answered `unsupported` and the chip never moved.
    try dispatchIpcLine(&ch, &app, arena, "{\"cmd\":\"statusline-set-segment\",\"id\":\"jira_work.assigned\",\"text\":\"JIRA 7\",\"color\":\"#1B5DCF\"}");
    var buf: [8]event.AppEvent = undefined;
    var n = app.events.drain(t.io, &buf);
    try t.expectEqual(@as(usize, 1), n);
    try app.handle(buf[0]);
    try t.expectEqual(@as(usize, 1), app.ipc_fx.segments.items.len);
    try t.expectEqualStrings("jira_work.assigned", app.ipc_fx.segments.items[0].id);
    try t.expectEqualStrings("JIRA 7", app.ipc_fx.segments.items[0].text);

    // A second publish replaces it in place — the poller's next run.
    try dispatchIpcLine(&ch, &app, arena, "{\"cmd\":\"statusline-set-segment\",\"id\":\"jira_work.assigned\",\"text\":\"JIRA 9\"}");
    n = app.events.drain(t.io, &buf);
    try t.expectEqual(@as(usize, 1), n);
    try app.handle(buf[0]);
    try t.expectEqual(@as(usize, 1), app.ipc_fx.segments.items.len);
    try t.expectEqualStrings("JIRA 9", app.ipc_fx.segments.items[0].text);

    // A toast and a badge come through the same arm.
    try dispatchIpcLine(&ch, &app, arena, "{\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":4}");
    n = app.events.drain(t.io, &buf);
    try app.handle(buf[0]);
    try t.expectEqual(@as(u32, 4), app.ipc_fx.badge("integrations"));

    // Input is refused, and the ack says what would allow it.
    try dispatchIpcLine(&ch, &app, arena, "{\"cmd\":\"key\",\"key\":\"ctrl+p\"}");
    try t.expectEqual(@as(usize, 0), app.events.drain(t.io, &buf));
    const events_path = try std.fs.path.join(arena, &.{ ch.dirPath(), "events.jsonl" });
    const log = try std.Io.Dir.cwd().readFileAlloc(t.io, events_path, arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, log, "\"unsupported\"") != null);
    try t.expect(std.mem.indexOf(u8, log, "allow_input") != null);
    // …and the tier-2 lines were acknowledged as taken, not refused.
    try t.expect(std.mem.indexOf(u8, log, "\"accepted\"") != null);

    // With the switch on, the same line is taken.
    app.cfg.ipc.allow_input = true;
    try dispatchIpcLine(&ch, &app, arena, "{\"cmd\":\"key\",\"key\":\"ctrl+p\"}");
    n = app.events.drain(t.io, &buf);
    try t.expectEqual(@as(usize, 1), n);
    buf[0].ipc.destroy();
}

test "with allow_input the live loop's input lines MOVE the App: a key opens the picker, open + type edit a file, a click lands" {
    // The ack said `accepted` and the App's `.ipc` arm answered "not in
    // this build": a host driving the real window through the channel
    // saw nothing happen. Each line below must change App state, not
    // just be posted.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\n" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 80, .rows = 24 });
    defer app.deinit();
    app.cfg.ipc.allow_input = true;
    var ch = try ipc.Channel.init(t.allocator, t.io, ws, .{});
    defer ch.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [8]event.AppEvent = undefined;

    const Feed = struct {
        fn line(c: *ipc.Channel, a: *App, ar: std.mem.Allocator, b: []event.AppEvent, text: []const u8) !void {
            try dispatchIpcLine(c, a, ar, text);
            const n = a.events.drain(t.io, b);
            try t.expectEqual(@as(usize, 1), n);
            try a.handle(b[0]);
            try a.render();
        }
    };

    try t.expect(app.overlay == .none);
    try Feed.line(&ch, &app, arena, &buf, "{\"cmd\":\"key\",\"key\":\"ctrl+p\"}");
    try t.expect(app.overlay != .none);
    try Feed.line(&ch, &app, arena, &buf, "{\"cmd\":\"key\",\"key\":\"esc\"}");
    try t.expect(app.overlay == .none);

    try Feed.line(&ch, &app, arena, &buf, "{\"cmd\":\"open\",\"path\":\"a.txt\"}");
    try t.expect(app.activeEditor() != null);
    try Feed.line(&ch, &app, arena, &buf, "{\"cmd\":\"type\",\"text\":\"zz\"}");
    try t.expect(std.mem.indexOf(u8, app.activeEditor().?.buf.editor.bytes(), "zz") != null);

    // A right-click on the editor opens its context menu: the mouse
    // path, not only the keyboard one.
    try Feed.line(&ch, &app, arena, &buf, "{\"cmd\":\"click\",\"col\":50,\"row\":5,\"button\":\"right\"}");
    try t.expect(app.overlay == .menu);

    // Nothing here was answered "not in this build".
    for (app.toasts.items) |ts| try t.expect(std.mem.indexOf(u8, ts.text, "not in this build") == null);
}

test "no terminal to take: the run refuses with NotATty and frees the config it was handed" {
    // Only where stdout is not a terminal — `zig build unit` hands the
    // test binary a pipe; run by hand in a terminal this would take it.
    if (try std.Io.File.stdout().isTty(t.io)) return error.SkipZigTest;
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, ".mnml");
    // A workspace layer, so the loader's arena holds strings of its own.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .ui = .{ .theme = \"onedark\" } }" });
    const loaded = try config.load.load(t.allocator, t.io, .{ .workspace = ws, .env = .{ .vars = &vars } });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // The testing allocator fails the test on anything left behind.
    try t.expectError(error.NotATty, run(t.allocator, t.io, &env, .{ .loaded = loaded, .workspace = ws }));
}
