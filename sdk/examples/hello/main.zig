//! mnml-hello — the sample integration. A list you can move through
//! with the keys or the mouse; Enter (or a click on the selected row)
//! asks mnml to run `hello.pick`; `q` says bye.
//!
//!   mnml-hello --install   write the manifest (then `integrations.refresh`)
//!   mnml-hello             connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! mnml's host integration test spawns this binary through a real
//! socket and asserts on the frame it paints, so its layout is part of
//! the test: row 0 is the header, rows 2.. the items, the last row the
//! footer.

const std = @import("std");
const sdk = @import("mnml_sdk");

const version = "0.1.0";
const items = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon" };
pub const first_row: u16 = 2;
const Hover = struct { col: u16, row: u16 };

const spec: sdk.Manifest = .{
    .id = "hello",
    .label = "Hello",
    .description = "The mnml-sdk sample: a list that answers keys and clicks",
    .version = version,
    .binary = "mnml-hello",
    .category = "sample",
    .chip = .{ .glyph = "\u{f0e7}", .fallback = "H", .color = "cyan", .tooltip = "Hello (sample integration)" },
    .commands = &.{
        .{ .id = "hello.open", .title = "Hello: open the sample pane", .keys = &.{"ctrl+k h"} },
        .{ .id = "hello.open_pty", .title = "Hello: open as a terminal pane", .ex = "term mnml-hello --pty" },
    },
    .settings = &.{.{ .key = "greeting", .label = "Greeting", .options = &.{ "HELLO", "HOWDY", "HEY" }, .default = "HELLO" }},
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;

    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--install")) {
            const path = sdk.manifest.write(gpa, io, env, spec) catch |err| {
                try stderr.print("mnml-hello: could not write the manifest: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return 1;
            };
            defer gpa.free(path);
            try stderr.print("mnml-hello: wrote {s}\n", .{path});
            try stderr.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            try stderr.print("mnml-hello {s} (bridge protocol {d})\n", .{ version, sdk.protocol });
            try stderr.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--pty")) {
            try stderr.print("mnml-hello: running as a plain terminal pane (no mount socket)\n", .{});
            try stderr.flush();
            return 0;
        }
    }

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => {
            try stderr.print("mnml-hello is an mnml integration: open it from mnml (`mount.open`) or run `mnml-hello --install`\n", .{});
            try stderr.flush();
            return 2;
        },
        else => return err,
    };
    defer mount.destroy();

    // Tier 2, when mnml told us where its channel is: the command Enter fires.
    if (try sdk.Ipc.fromEnv(gpa, io, env)) |*ipc_const| {
        var ipc = ipc_const.*;
        defer ipc.deinit();
        ipc.registerCommand("hello.pick", "Hello: the picked row", "integrations", &.{}) catch {};
    }
    const greeting = env.get("MNML_SETTING_GREETING") orelse "HELLO";

    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    var cursor: usize = 0;
    var picks: u32 = 0;
    var last_hover: ?Hover = null;
    try mount.setTitle("hello");
    paint(&frame, mount.hello, greeting, cursor, picks, last_hover);
    try mount.send(&frame);

    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        switch (msg) {
            // A pane that starts no sessions is told about none.
            .hello, .focus, .session_state, .focus_item => {},
            .goodbye => break,
            .resize => |r| try frame.resize(r.geometry.cols, r.geometry.rows),
            .input => |in| switch (in.event) {
                .key => |k| {
                    if (std.mem.eql(u8, k.spec, "down") or std.mem.eql(u8, k.spec, "j")) {
                        cursor = @min(cursor + 1, items.len - 1);
                    } else if (std.mem.eql(u8, k.spec, "up") or std.mem.eql(u8, k.spec, "k")) {
                        cursor -|= 1;
                    } else if (std.mem.eql(u8, k.spec, "enter")) {
                        picks += 1;
                        try mount.command("hello.pick");
                    } else if (std.mem.eql(u8, k.spec, "q")) {
                        mount.bye();
                        break;
                    }
                },
                .click => |c| {
                    if (c.row >= first_row and c.row - first_row < items.len) {
                        const idx: usize = c.row - first_row;
                        if (idx == cursor) {
                            picks += 1;
                            try mount.command("hello.pick");
                        } else cursor = idx;
                    }
                },
                .scroll => |s| cursor = if (s.dy > 0) cursor -| 1 else @min(cursor + 1, items.len - 1),
                .hover => |h| last_hover = .{ .col = h.col, .row = h.row },
                .paste => {},
            },
        }
        paint(&frame, mount.hello, greeting, cursor, picks, last_hover);
        try mount.send(&frame);
    }
    return 0;
}

fn paint(f: *sdk.Frame, hello: sdk.wire.Hello, greeting: []const u8, cursor: usize, picks: u32, hover: ?Hover) void {
    const accent: sdk.Style = .{ .fg = .{ .index = 6 }, .mods = .{ .bold = true } };
    const muted: sdk.Style = .{ .mods = .{ .dim = true } };
    f.clear(.none);
    var buf: [128]u8 = undefined;
    const used = f.text(1, 0, f.cols, greeting, accent);
    const head = std.fmt.bufPrint(&buf, " · {d}×{d} · {s}", .{ f.cols, f.rows, hello.theme }) catch "";
    _ = f.text(1 + used, 0, f.cols, head, muted);
    for (items, 0..) |name, i| {
        const y: u16 = first_row + @as(u16, @intCast(i));
        if (y + 1 >= f.rows) break;
        const selected = i == cursor;
        const style: sdk.Style = if (selected) .{ .mods = .{ .reverse = true } } else .none;
        if (selected) f.fill(0, y, f.cols, 1, style);
        _ = f.text(1, y, f.cols, if (selected) "▸ " else "  ", style);
        _ = f.text(3, y, f.cols, name, style);
    }
    if (f.rows > 1) {
        const footer = if (hover) |h|
            std.fmt.bufPrint(&buf, "↑↓ move · enter pick · q quit · picks: {d} · hover {d},{d}", .{ picks, h.col, h.row }) catch ""
        else
            std.fmt.bufPrint(&buf, "↑↓ move · enter pick · q quit · picks: {d}", .{picks}) catch "";
        _ = f.text(1, f.rows - 1, f.cols, footer, muted);
    }
}
