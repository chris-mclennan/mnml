//! Headless: the same App, driven from the file-IPC channel instead of a
//! terminal. Each turn of the loop is tick → expire chords → draw → dump
//! (`screen.txt`, `status.json`, `rects.json`) → apply every complete
//! `command` line → sleep 40 ms when nothing arrived. `screen.txt` is the
//! only view a host has, so it is written every frame regardless of any
//! `write_screen` preference.
//!
//! Every command is acknowledged with one events.jsonl line named after
//! it; the values are strings (see ipc/screen.zig). The ack table is the
//! one mnml 0.2 hosts already parse.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const ipc = @import("ipc/root.zig");
const screen_mod = @import("ipc/screen.zig");
const driver_mod = @import("e2e/driver.zig");
const keymap = @import("core/keymap.zig");
const input = @import("core/key.zig");
const exit_signal = @import("core/exit_signal.zig");

pub const Driver = driver_mod.Driver;
pub const Size = struct { cols: u16, rows: u16 };
pub const default_size: Size = .{ .cols = 120, .rows = 40 };

/// `MNML_COLS` / `MNML_ROWS`: a number of at least 10, else the default.
pub fn sizeFromEnv(cols: ?[]const u8, rows: ?[]const u8) Size {
    return .{ .cols = dim(cols, default_size.cols), .rows = dim(rows, default_size.rows) };
}

fn dim(s: ?[]const u8, default: u16) u16 {
    const v = std.fmt.parseInt(u16, s orelse return default, 10) catch return default;
    return if (v >= 10) v else default;
}

pub const Options = struct {
    size: Size = default_size,
    ipc: ipc.channel.InitOptions = .{},
    /// Idle sleep between polls of the command file.
    poll_ms: u64 = 40,
    /// Sleep slice inside `wait_ms`.
    wait_slice_ms: u64 = 40,
};

/// How a run ended.
pub const End = enum { quit, restart, signal };

/// Run until `quit`, a restart, or SIGTERM / SIGINT / SIGHUP
/// (`core/exit_signal.zig`) — each leaves through the exit hook and a
/// last dump; a signal's exit line says `reason: signal`.
pub fn run(gpa: Allocator, io: Io, driver: Driver, workspace: []const u8, opts: Options) !End {
    var ch = try ipc.Channel.init(gpa, io, workspace, opts.ipc);
    defer ch.deinit();
    {
        var a: Io.Writer.Allocating = .init(gpa);
        defer a.deinit();
        try a.writer.print("{{\"event\":\"start\",\"mode\":\"headless\",\"cols\":{d},\"rows\":{d},\"ipc\":", .{ opts.size.cols, opts.size.rows });
        try screen_mod.jsonStr(&a.writer, ch.dirPath());
        try a.writer.writeByte('}');
        ch.appendEvent(a.written());
    }
    exit_signal.install();

    var loop: Loop = .{ .gpa = gpa, .io = io, .driver = driver, .ch = &ch, .workspace = workspace, .opts = opts };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        if (exit_signal.caught() != null) break;
        try loop.frame(arena);
        if (loop.quit) break;
        const any = try loop.drainCommands(arena);
        try loop.drainPluginEvents(arena);
        if (!any) io.sleep(.fromMilliseconds(@intCast(opts.poll_ms)), .awake) catch {};
    }

    // The exit hook, as the terminal loop runs it — then a final dump
    // so the host sees the end state, whatever the hook left.
    driver.shutdown();
    _ = arena_state.reset(.retain_capacity);
    try loop.frame(arena_state.allocator());
    if (exit_signal.caught()) |sig| {
        var buf: [96]u8 = undefined;
        ch.appendEvent(std.fmt.bufPrint(&buf, "{{\"event\":\"exit\",\"reason\":\"signal\",\"signal\":\"{d}\"}}", .{sig}) catch "{\"event\":\"exit\",\"reason\":\"signal\"}");
        return .signal;
    }
    ch.appendEvent(if (loop.restart) "{\"event\":\"exit\",\"restart\":true}" else "{\"event\":\"exit\"}");
    return if (loop.restart) .restart else .quit;
}

const Loop = struct {
    gpa: Allocator,
    io: Io,
    driver: Driver,
    ch: *ipc.Channel,
    workspace: []const u8,
    opts: Options,
    quit: bool = false,
    restart: bool = false,
    /// A `mouse_down` without its `mouse_up` yet: `mouse_move` is a drag.
    button_held: bool = false,

    /// tick → expire chords → draw → dump.
    fn frame(self: *Loop, arena: Allocator) !void {
        const d = self.driver;
        try d.tick();
        try d.expireChords();
        try d.render();
        try self.dump(arena);
    }

    fn dump(self: *Loop, arena: Allocator) !void {
        const d = self.driver;
        const screen_txt = try screen_mod.toScreenTxt(arena, d.screen());
        self.ch.writeScreen(screen_txt);
        const status = try d.status(arena);
        self.quit = status.quit;
        const status_json = try screen_mod.statusJson(arena, status);
        self.ch.writeStatus(status_json);
        self.ch.writeRects(try d.rectsJson(arena));
    }

    fn drainCommands(self: *Loop, arena: Allocator) !bool {
        const cmds = try self.ch.poll(arena);
        for (cmds) |*cmd| {
            const ack = try self.apply(arena, cmd);
            self.ch.appendEvent(ack);
            // A snapshot paints and dumps now, so a same-batch expect_screen
            // reads current state instead of the previous frame's file.
            if (cmd.* == .snapshot) {
                try self.driver.render();
                try self.dump(arena);
            }
        }
        return cmds.len > 0;
    }

    /// `plugin-command` lines for every plugin-registered id invoked
    /// since the last turn, so the integration that owns it can react.
    fn drainPluginEvents(self: *Loop, arena: Allocator) !void {
        for (try self.driver.pluginInvocations(arena)) |id| {
            self.ch.appendEvent(try screen_mod.pluginCommandEvent(arena, id));
        }
    }

    fn ev(arena: Allocator, pairs: []const screen_mod.Pair) Allocator.Error![]u8 {
        return screen_mod.jsonEvent(arena, pairs);
    }

    fn num(arena: Allocator, v: anytype) Allocator.Error![]u8 {
        return std.fmt.allocPrint(arena, "{d}", .{v});
    }

    /// Apply one command and return its ack line.
    fn apply(self: *Loop, arena: Allocator, cmd: *const ipc.Command) ![]u8 {
        const d = self.driver;
        switch (cmd.*) {
            .open => |p| {
                const path = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ self.workspace, p });
                d.open(path) catch {};
                return ev(arena, &.{ .{ "event", "open" }, .{ "path", path } });
            },
            .key => |spec| {
                if (try self.dispatchKeySpec(arena, spec)) return ev(arena, &.{ .{ "event", "key" }, .{ "key", spec } });
                return ev(arena, &.{ .{ "event", "key_unparsed" }, .{ "key", spec } });
            },
            .type => |text| {
                d.typeText(text) catch {};
                return ev(arena, &.{ .{ "event", "type" }, .{ "text", text } });
            },
            .run_command => |id| {
                const ok = if (d.command(id)) true else |_| false;
                return ev(arena, &.{ .{ "event", "command_run" }, .{ "id", id }, .{ "ok", if (ok) "true" else "false" } });
            },
            .register_command => |r| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "command_registered" }, .{ "id", r.id }, .{ "title", r.title } });
            },
            .click => |c| {
                d.click(c.col, c.row, c.button, c.mods) catch {};
                return ev(arena, &.{ .{ "event", "click" }, .{ "button", buttonName(c.button) }, .{ "col", try num(arena, c.col) }, .{ "row", try num(arena, c.row) } });
            },
            .hover => |h| {
                d.mouse(.{ .x = h.col, .y = h.row, .kind = .motion }) catch {};
                return ev(arena, &.{ .{ "event", "hover" }, .{ "col", try num(arena, h.col) }, .{ "row", try num(arena, h.row) } });
            },
            .drag => |g| {
                const steps = d.drag(g.from_col, g.from_row, g.col, g.row) catch 0;
                return ev(arena, &.{
                    .{ "event", "drag" },
                    .{ "from", try std.fmt.allocPrint(arena, "{d},{d}", .{ g.from_col, g.from_row }) },
                    .{ "to", try std.fmt.allocPrint(arena, "{d},{d}", .{ g.col, g.row }) },
                    .{ "steps", try num(arena, steps) },
                });
            },
            .mouse_down => |m| {
                self.button_held = true;
                d.mouse(.{ .x = m.col, .y = m.row, .kind = .press, .button = m.button, .mods = m.mods }) catch {};
                return ev(arena, &.{ .{ "event", "mouse_down" }, .{ "col", try num(arena, m.col) }, .{ "row", try num(arena, m.row) } });
            },
            .mouse_move => |m| {
                d.mouse(.{ .x = m.col, .y = m.row, .kind = if (self.button_held) .drag else .motion, .button = if (self.button_held) .left else .none }) catch {};
                return ev(arena, &.{ .{ "event", "mouse_move" }, .{ "col", try num(arena, m.col) }, .{ "row", try num(arena, m.row) } });
            },
            .mouse_up => |m| {
                self.button_held = false;
                d.mouse(.{ .x = m.col, .y = m.row, .kind = .release, .button = m.button, .mods = m.mods }) catch {};
                return ev(arena, &.{ .{ "event", "mouse_up" }, .{ "col", try num(arena, m.col) }, .{ "row", try num(arena, m.row) } });
            },
            .wait_ms => |ms| {
                // Sleep in slices, expiring chord chains as time passes, so
                // a pending prefix times out the way it would for a user.
                const deadline = nowMs(self.io) + @as(i64, @intCast(ms));
                while (nowMs(self.io) < deadline) {
                    const remaining: u64 = @intCast(@max(deadline - nowMs(self.io), 0));
                    self.io.sleep(.fromMilliseconds(@intCast(@min(remaining, self.opts.wait_slice_ms))), .awake) catch {};
                    d.expireChords() catch {};
                }
                return ev(arena, &.{ .{ "event", "wait_ms" }, .{ "ms", try num(arena, ms) } });
            },
            .expect_screen => |e| {
                const path = try std.fs.path.join(arena, &.{ self.ch.dirPath(), "screen.txt" });
                const screen = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch "";
                const found = std.mem.indexOf(u8, screen, e.text) != null;
                const ok = if (e.contains) found else !found;
                return ev(arena, &.{
                    .{ "event", "expect_screen" },
                    .{ "mode", if (e.contains) "contains" else "lacks" },
                    .{ "text", e.text },
                    .{ "ok", if (ok) "true" else "false" },
                });
            },
            .scroll => |s| {
                // `dy` events, each dispatched before the next arrives
                // (a tick flushes the batch), as the Rust host applies
                // them — so a fast spin asked for by a host accelerates
                // as one would at the terminal.
                const kind: input.MouseKind = if (s.dy >= 0) .scroll_up else .scroll_down;
                var n: u32 = @abs(s.dy);
                while (n > 0) : (n -= 1) {
                    d.mouse(.{ .x = s.col, .y = s.row, .kind = kind }) catch {};
                    d.tick() catch {};
                }
                return ev(arena, &.{ .{ "event", "scroll" }, .{ "col", try num(arena, s.col) }, .{ "row", try num(arena, s.row) }, .{ "dy", try num(arena, s.dy) } });
            },
            .snapshot => return ev(arena, &.{.{ "event", "snapshot" }}),
            .toast => |toast| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "toast" }, .{ "text", toast.text }, .{ "level", @tagName(toast.level) } });
            },
            .toast_persistent => |toast| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "toast_persistent" }, .{ "id", toast.id }, .{ "text", toast.text } });
            },
            .toast_dismiss => |id| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "toast_dismiss" }, .{ "id", id } });
            },
            .progress_start => |p| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "progress_start" }, .{ "id", p.id }, .{ "label", p.label } });
            },
            .progress_update => |p| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "progress_update" }, .{ "id", p.id } });
            },
            .progress_end => |p| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "progress_end" }, .{ "id", p.id }, .{ "status", @tagName(p.status) } });
            },
            .statusline_set_segment => |s| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "statusline_set_segment" }, .{ "id", s.id }, .{ "text", s.text } });
            },
            .statusline_clear_segment => |id| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "statusline_clear_segment" }, .{ "id", id } });
            },
            .notify => |n| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "notify" }, .{ "title", n.title }, .{ "body", n.body } });
            },
            .focus_session => |f| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "focus_session" }, .{ "cwd", f.cwd orelse "" }, .{ "prompt_line", f.prompt_line orelse "" } });
            },
            .open_pty => |p| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "open_pty" }, .{ "exe", p.command[0] } });
            },
            .set_activity_badge => |b| {
                d.ipcCommand(cmd) catch {};
                return ev(arena, &.{ .{ "event", "set_activity_badge" }, .{ "section", b.section }, .{ "count", try num(arena, b.count) } });
            },
            .dump_rects => return ev(arena, &.{.{ "event", "dump_rects" }}),
            .ghost => |text| {
                const applied = if (d.ghost(text)) true else |_| false;
                return ev(arena, &.{ .{ "event", "ghost" }, .{ "applied", if (applied) "true" else "false" }, .{ "text", text } });
            },
            .ex => |line| {
                const ok = if (d.ex(line)) true else |_| false;
                return ev(arena, &.{ .{ "event", "ex" }, .{ "line", line }, .{ "ok", if (ok) "true" else "false" } });
            },
            .quit => {
                d.requestQuit(false);
                self.quit = true;
                return ev(arena, &.{.{ "event", "quit" }});
            },
            .restart => {
                d.requestQuit(true);
                self.quit = true;
                self.restart = true;
                return ev(arena, &.{.{ "event", "restart" }});
            },
            .unknown => |raw| return ev(arena, &.{ .{ "event", "unknown" }, .{ "raw", raw } }),
        }
    }

    /// A key spec is one chord, a whitespace-separated chain (`ctrl+w h`),
    /// or a run of single chars (`gg`, `2j`) when the whole thing is not a
    /// chord and could plausibly be a vim chain. Three or more letters
    /// with no modifier (`hom`, `esx`) read as a misspelled named key and
    /// stay unparsed rather than typing wrong keystrokes. Every token
    /// must parse for any to be dispatched.
    fn dispatchKeySpec(self: *Loop, arena: Allocator, spec: []const u8) !bool {
        const keys = try ipc.effects.keySpecKeys(arena, spec) orelse return false;
        for (keys) |k| self.driver.key(k) catch {};
        return true;
    }
};

fn buttonName(b: input.MouseButton) []const u8 {
    return switch (b) {
        .left => "Left",
        .right => "Right",
        .middle => "Middle",
        .none => "Left",
    };
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "sizeFromEnv: numbers of at least 10, else the 120×40 default" {
    try t.expectEqual(default_size, sizeFromEnv(null, null));
    try t.expectEqual(Size{ .cols = 60, .rows = 12 }, sizeFromEnv("60", "12"));
    try t.expectEqual(Size{ .cols = 120, .rows = 40 }, sizeFromEnv("9", "abc"));
    try t.expectEqual(Size{ .cols = 10, .rows = 40 }, sizeFromEnv("10", ""));
}

const Feeder = struct {
    io: Io,
    path: []const u8,
    lines: []const u8,
    delay_ms: u64,

    fn run(self: *Feeder) void {
        self.io.sleep(.fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        ipc.channel.appendSecret(self.io, self.path, self.lines) catch {};
    }
};

test "the loop dumps every frame, acks every command byte-for-byte, and exits on quit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "hello.txt", .data = "Hello, mnml!\n" });

    const stub = try t.allocator.create(driver_mod.Stub);
    stub.* = try driver_mod.Stub.init(t.allocator, 20, 3);
    stub.text = "Hello, mnml!\nrow two  ";
    stub.title = "hello.txt";
    stub.dirty_flag = false;
    stub.known_commands = &.{"file.save"};
    stub.plugin_pending = &.{"p.a"};
    defer stub.driver().deinit();

    const cmd_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc-zig", "command" });
    defer t.allocator.free(cmd_path);
    var feeder: Feeder = .{ .io = t.io, .path = cmd_path, .delay_ms = 150, .lines =
        \\{"cmd":"open","path":"hello.txt"}
        \\{"cmd":"type","text":"AB"}
        \\{"cmd":"click","col":5,"row":2,"button":"right"}
        \\{"cmd":"expect_screen","text":"Hello"}
        \\{"cmd":"expect_screen","text":"zzz","expect":"lacks"}
        \\{"cmd":"nope"}
        \\not json
        \\{"cmd":"scroll","col":3,"row":2,"dy":-2}
        \\{"cmd":"drag","from_col":1,"from_row":1,"col":6,"row":2}
        \\{"cmd":"run-command","id":"nope.nope"}
        \\{"cmd":"run-command","id":"file.save"}
        \\{"cmd":"register-command","id":"p.a"}
        \\{"cmd":"wait_ms","ms":30}
        \\{"cmd":"ghost","text":"x + y"}
        \\{"cmd":"key","key":"esc"}
        \\{"cmd":"key","key":"ctrl+w h"}
        \\{"cmd":"key","key":"gg"}
        \\{"cmd":"key","key":"hom"}
        \\{"cmd":"hover","col":2,"row":2}
        \\{"cmd":"mouse_down","col":1,"row":1}
        \\{"cmd":"mouse_move","col":2,"row":1}
        \\{"cmd":"mouse_up","col":2,"row":1}
        \\{"cmd":"toast","text":"hi","level":"warn"}
        \\{"cmd":"progress-end","id":"p","text":"fail"}
        \\{"cmd":"set-activity-badge","section":"sessions","count":3}
        \\{"cmd":"open-pty","command":["ls","-la"]}
        \\{"cmd":"notify","text":"body"}
        \\{"cmd":"snapshot"}
        \\{"cmd":"dump-rects"}
        \\{"cmd":"quit"}
        \\
    };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    const restart = try run(t.allocator, t.io, stub.driver(), ws, .{ .size = .{ .cols = 20, .rows = 3 }, .ipc = .{ .subdir = "ipc-zig" } });
    th.join();
    try t.expect(!restart);

    const events = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/events.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(events);
    // The two paths as the events carry them: joined natively (`\` on
    // Windows) and JSON-escaped.
    const ipc_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc-zig" });
    defer t.allocator.free(ipc_path);
    const hello_path = try std.fs.path.join(t.allocator, &.{ ws, "hello.txt" });
    defer t.allocator.free(hello_path);
    const expected = try std.fmt.allocPrint(t.allocator,
        \\{{"event":"start","mode":"headless","cols":20,"rows":3,"ipc":{f}}}
        \\{{"event":"plugin-command","id":"p.a"}}
        \\{{"event":"open","path":{f}}}
        \\{{"event":"type","text":"AB"}}
        \\{{"event":"click","button":"Right","col":"5","row":"2"}}
        \\{{"event":"expect_screen","mode":"contains","text":"Hello","ok":"true"}}
        \\{{"event":"expect_screen","mode":"lacks","text":"zzz","ok":"true"}}
        \\{{"event":"unknown","raw":"{{\"cmd\":\"nope\"}}"}}
        \\{{"event":"unknown","raw":"not json"}}
        \\{{"event":"scroll","col":"3","row":"2","dy":"-2"}}
        \\{{"event":"drag","from":"1,1","to":"6,2","steps":"5"}}
        \\{{"event":"command_run","id":"nope.nope","ok":"false"}}
        \\{{"event":"command_run","id":"file.save","ok":"true"}}
        \\{{"event":"command_registered","id":"p.a","title":"p.a"}}
        \\{{"event":"wait_ms","ms":"30"}}
        \\{{"event":"ghost","applied":"true","text":"x + y"}}
        \\{{"event":"key","key":"esc"}}
        \\{{"event":"key","key":"ctrl+w h"}}
        \\{{"event":"key","key":"gg"}}
        \\{{"event":"key_unparsed","key":"hom"}}
        \\{{"event":"hover","col":"2","row":"2"}}
        \\{{"event":"mouse_down","col":"1","row":"1"}}
        \\{{"event":"mouse_move","col":"2","row":"1"}}
        \\{{"event":"mouse_up","col":"2","row":"1"}}
        \\{{"event":"toast","text":"hi","level":"warn"}}
        \\{{"event":"progress_end","id":"p","status":"failed"}}
        \\{{"event":"set_activity_badge","section":"sessions","count":"3"}}
        \\{{"event":"open_pty","exe":"ls"}}
        \\{{"event":"notify","title":"mnml","body":"body"}}
        \\{{"event":"snapshot"}}
        \\{{"event":"dump_rects"}}
        \\{{"event":"quit"}}
        \\{{"event":"exit"}}
        \\
    , .{ std.json.fmt(ipc_path, .{}), std.json.fmt(hello_path, .{}) });
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, events);

    const screen = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/screen.txt", t.allocator, .unlimited);
    defer t.allocator.free(screen);
    try t.expectEqualStrings("Hello, mnml!\nrow two\n\n", screen);
    const status = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/status.json", t.allocator, .unlimited);
    defer t.allocator.free(status);
    // `cursorShape` is `hidden` because the screen is 20x3: the bar, the
    // strip, the statusline and the `:` line leave the editor no rows,
    // so no surface has a caret to give.
    try t.expectEqualStrings(
        "{\"focus\":\"pane\",\"activePane\":0,\"activeFile\":\"hello.txt\",\"cursor\":{\"line\":1,\"col\":1},\"mode\":\"none\",\"treeCursor\":0,\"treeSelection\":\"\",\"treeVisible\":true,\"rightPanelVisible\":false,\"rightPanelPanes\":[],\"rightPanelActiveIdx\":0,\"panes\":[{\"title\":\"hello.txt\",\"dirty\":false,\"preview\":false}],\"quit\":true,\"cursorShape\":\"hidden\",\"cmdline\":false,\"ghost\":\"idle\",\"cols\":20,\"rows\":3,\"cellWidthPx\":0,\"cellHeightPx\":0,\"settings\":null,\"hostEscapes\":[],\"toasts\":0}",
        status,
    );
    const rects = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/rects.json", t.allocator, .unlimited);
    defer t.allocator.free(rects);
    try t.expectEqualStrings("[]\n", rects);

    // The driver saw the keys the chain rules produce: esc, ctrl+w, h, g, g — and never `hom`.
    const calls = try stub.callsJoined(t.allocator);
    defer t.allocator.free(calls);
    try t.expect(std.mem.indexOf(u8, calls, "key esc\nkey ctrl+w\nkey h\nkey g\nkey g\n") != null);
    try t.expect(std.mem.indexOf(u8, calls, "key h\nkey o\nkey m") == null);
    // mouse_move while a button is held is a drag; after mouse_up it is not.
    try t.expect(std.mem.indexOf(u8, calls, "mouse press left 1,1\nmouse drag left 2,1\nmouse release left 2,1") != null);
    try t.expect(std.mem.indexOf(u8, calls, "mouse motion none 2,2") != null);
}

test "restart is reported through the exit line and the return value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const stub = try t.allocator.create(driver_mod.Stub);
    stub.* = try driver_mod.Stub.init(t.allocator, 12, 2);
    defer stub.driver().deinit();
    const cmd_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc", "command" });
    defer t.allocator.free(cmd_path);
    var feeder: Feeder = .{ .io = t.io, .path = cmd_path, .delay_ms = 120, .lines = "{\"cmd\":\"restart\"}\n" };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    const restart = try run(t.allocator, t.io, stub.driver(), ws, .{ .size = .{ .cols = 12, .rows = 2 } });
    th.join();
    try t.expect(restart);
    try t.expect(stub.restart);
    const events = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc/events.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(events);
    try t.expect(std.mem.endsWith(u8, events, "{\"event\":\"restart\"}\n{\"event\":\"exit\",\"restart\":true}\n"));
}

test "tier-2 golden: the Rust event shapes for segments, badges, notify and open-pty, through the real App" {
    const app_driver = @import("app/driver.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const data_root = try std.fs.path.join(t.allocator, &.{ ws, "data" });
    defer t.allocator.free(data_root);

    const drv = try app_driver.AppDriver.create(t.allocator, t.io, .{ .workspace = ws, .data_root = data_root, .cols = 100, .rows = 12 }, null);
    defer drv.driver().deinit();

    const cmd_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc-zig", "command" });
    defer t.allocator.free(cmd_path);
    var feeder: Feeder = .{ .io = t.io, .path = cmd_path, .delay_ms = 150, .lines = @embedFile("ipc/golden/tier2.commands.jsonl") };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    const restart = try run(t.allocator, t.io, drv.driver(), ws, .{ .size = .{ .cols = 100, .rows = 12 }, .ipc = .{ .subdir = "ipc-zig" } });
    th.join();
    try t.expect(!restart);

    // The state the commands left behind: one segment (`ci` cleared), the
    // badge, a pinned-nothing (warn is ephemeral), no notifier spawned.
    const app = &drv.app;
    try t.expectEqual(@as(usize, 1), app.ipc_fx.segments.items.len);
    try t.expectEqualStrings("jira", app.ipc_fx.segments.items[0].id);
    try t.expectEqual(@as(u32, 3), app.ipc_fx.badge("sessions"));
    try t.expectEqual(@as(u32, 0), app.ipc_fx.badge("todos"));
    try t.expect(!app.native_notify);
    var saw_pty = false;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| saw_pty = saw_pty or std.mem.eql(u8, pt.label, "ls"),
        else => {},
    };
    // The golden opens `ls` at cwd `.`, not `/tmp`: a Windows runner has
    // no `\tmp` unless an earlier step made one, and the spawn failed
    // with DIRECTORY there.
    try t.expect(saw_pty);
    // The segment is on the statusline of the last frame (the loop frames
    // after the batch, so an in-band `expect_screen` would run too early).
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "  JIRA 3 ") != null);

    // The acks, minus the start and exit lines the loop adds, are the
    // Rust host's `json_event` shapes byte for byte.
    const events = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/events.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(events);
    const first_nl = std.mem.indexOfScalar(u8, events, '\n').?;
    const body = events[first_nl + 1 ..];
    const exit_at = std.mem.lastIndexOf(u8, body, "{\"event\":\"exit\"}").?;
    try t.expectEqualStrings(@embedFile("ipc/golden/tier2.events.jsonl"), body[0..exit_at]);
}

test "a quit runs the exit hook, as the terminal loop does" {
    // The terminal loop emitted `exit` after its last frame; this loop
    // never did, so a script's shutdown work silently did not happen
    // under --headless, IPC or anything driven through them.
    const app_driver = @import("app/driver.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const data_root = try std.fs.path.join(t.allocator, &.{ ws, "data" });
    defer t.allocator.free(data_root);

    const drv = try app_driver.AppDriver.create(t.allocator, t.io, .{ .workspace = ws, .data_root = data_root, .cols = 40, .rows = 6 }, null);
    defer drv.driver().deinit();
    try drv.app.script().runString("EXITS = 0; mnml.on('exit', function() EXITS = EXITS + 1 end)");

    const cmd_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc-zig", "command" });
    defer t.allocator.free(cmd_path);
    var feeder: Feeder = .{ .io = t.io, .path = cmd_path, .delay_ms = 120, .lines = "{\"cmd\":\"quit\"}\n" };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    const restart = try run(t.allocator, t.io, drv.driver(), ws, .{ .size = .{ .cols = 40, .rows = 6 }, .ipc = .{ .subdir = "ipc-zig" } });
    th.join();
    try t.expect(!restart);
    try drv.app.script().runString("assert(EXITS == 1, 'exit hook ran ' .. EXITS .. ' times')");
}

test "an IPC run-command of a script command that errors acks ok:false" {
    // The driver swallowed the script's error, so the host was told
    // `ok:true` while the user saw an error toast.
    const app_driver = @import("app/driver.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const data_root = try std.fs.path.join(t.allocator, &.{ ws, "data" });
    defer t.allocator.free(data_root);

    const drv = try app_driver.AppDriver.create(t.allocator, t.io, .{ .workspace = ws, .data_root = data_root, .cols = 40, .rows = 6 }, null);
    defer drv.driver().deinit();
    try drv.app.script().runString(
        \\mnml.command{ id = 'err', run = function() error('BOOM') end }
        \\mnml.command{ id = 'fine', run = function() end }
    );

    const cmd_path = try std.fs.path.join(t.allocator, &.{ ws, ".mnml", "ipc-zig", "command" });
    defer t.allocator.free(cmd_path);
    var feeder: Feeder = .{ .io = t.io, .path = cmd_path, .delay_ms = 120, .lines =
        \\{"cmd":"run-command","id":"user.err"}
        \\{"cmd":"run-command","id":"user.fine"}
        \\{"cmd":"quit"}
        \\
    };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    _ = try run(t.allocator, t.io, drv.driver(), ws, .{ .size = .{ .cols = 40, .rows = 6 }, .ipc = .{ .subdir = "ipc-zig" } });
    th.join();
    const events = try tmp.dir.readFileAlloc(t.io, ".mnml/ipc-zig/events.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(events);
    try t.expect(std.mem.indexOf(u8, events, "{\"event\":\"command_run\",\"id\":\"user.err\",\"ok\":\"false\"}") != null);
    try t.expect(std.mem.indexOf(u8, events, "{\"event\":\"command_run\",\"id\":\"user.fine\",\"ok\":\"true\"}") != null);
}
