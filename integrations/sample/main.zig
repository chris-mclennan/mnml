//! mnml-sample — the sample integration, written on `mnml-sdk`. A small
//! live screen: a counter, the theme mnml said hello with, and a row
//! that answers keys and clicks. `q` says bye; mnml's goodbye ends it.
//!
//!   mnml-sample --install     write the manifest (then `integrations.refresh`)
//!   mnml-sample --uninstall   delete it
//!   mnml-sample --version
//!   mnml-sample               connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! The manifest is `manifest.zon` beside this file, `@import`ed so the
//! binary and the Dev tab read one definition. mnml's own tests spawn
//! this binary through a real socket, so the layout is part of the
//! contract: row 0 the header, `counter_row` the counter, `click_row`
//! the row a click bumps, the last row the footer.

const std = @import("std");
const sdk = @import("mnml_sdk");

pub const spec: sdk.Manifest = @import("manifest.zon");
pub const counter_row: u16 = 2;
pub const click_row: u16 = 4;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;

    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--install")) {
            const path = sdk.manifest.write(gpa, io, env, spec) catch |err| {
                try stderr.print("mnml-sample: could not write the manifest: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return 1;
            };
            defer gpa.free(path);
            try stderr.print("mnml-sample: wrote {s}\n", .{path});
            try stderr.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--uninstall")) {
            const went = sdk.manifest.remove(gpa, io, env, spec.id) catch |err| {
                try stderr.print("mnml-sample: could not remove the manifest: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return 1;
            };
            try stderr.print("mnml-sample: {s}\n", .{if (went) "removed the manifest" else "nothing to remove"});
            try stderr.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            try stderr.print("mnml-sample {s} (bridge protocol {d})\n", .{ spec.version, sdk.protocol });
            try stderr.flush();
            return 0;
        }
    }

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => {
            try stderr.print("mnml-sample is an mnml integration: open it from mnml (sample.open) or run `mnml-sample --install`\n", .{});
            try stderr.flush();
            return 2;
        },
        else => return err,
    };
    defer mount.destroy();

    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    var state: State = .{
        .theme = mount.hello.theme,
        .mood = env.get("MNML_SETTING_MOOD") orelse "calm",
    };
    try mount.setTitle("sample");
    paint(&frame, &state);
    try mount.send(&frame);

    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        switch (msg) {
            .hello => {},
            .focus => |f| state.focused = f,
            .goodbye => break,
            .resize => |r| try frame.resize(r.geometry.cols, r.geometry.rows),
            .input => |in| switch (in.event) {
                .key => |k| {
                    state.events += 1;
                    if (std.mem.eql(u8, k.spec, "q")) {
                        mount.bye();
                        break;
                    } else if (std.mem.eql(u8, k.spec, "up") or std.mem.eql(u8, k.spec, "k") or std.mem.eql(u8, k.spec, "+") or std.mem.eql(u8, k.spec, "space") or std.mem.eql(u8, k.spec, "enter")) {
                        state.counter += 1;
                    } else if (std.mem.eql(u8, k.spec, "down") or std.mem.eql(u8, k.spec, "j") or std.mem.eql(u8, k.spec, "-")) {
                        state.counter -|= 1;
                    } else if (std.mem.eql(u8, k.spec, "r")) {
                        state.counter = 0;
                    } else if (std.mem.eql(u8, k.spec, "h")) {
                        try mount.toast(.info, "hello from the sample");
                    }
                },
                .click => |c| {
                    state.events += 1;
                    state.last_click = .{ .col = c.col, .row = c.row };
                    if (c.row == click_row) state.counter += 1;
                    if (c.row == counter_row and c.button == .right) state.counter = 0;
                },
                .scroll => |s| {
                    state.events += 1;
                    if (s.dy > 0) state.counter += 1 else state.counter -|= 1;
                },
                .hover, .paste => {},
            },
        }
        paint(&frame, &state);
        try mount.send(&frame);
    }
    return 0;
}

const State = struct {
    theme: []const u8,
    mood: []const u8,
    counter: u32 = 0,
    events: u32 = 0,
    focused: bool = true,
    last_click: ?struct { col: u16, row: u16 } = null,
};

fn paint(f: *sdk.Frame, st: *const State) void {
    const accent: sdk.Style = .{ .fg = .{ .index = 6 }, .mods = .{ .bold = true } };
    const muted: sdk.Style = .{ .mods = .{ .dim = true } };
    var buf: [160]u8 = undefined;
    f.clear(.none);
    // Row 0: the header — the label, the theme mnml told us, the setting.
    const used = f.text(1, 0, f.cols, "SAMPLE", accent);
    const head = std.fmt.bufPrint(&buf, " · theme {s} · mood {s} · {d}×{d}", .{ st.theme, st.mood, f.cols, f.rows }) catch "";
    _ = f.text(1 + used, 0, f.cols -| (1 + used), head, muted);
    if (f.rows > counter_row) {
        const line = std.fmt.bufPrint(&buf, "counter: {d}", .{st.counter}) catch "";
        _ = f.text(1, counter_row, f.cols -| 1, line, .bold);
        const tail = std.fmt.bufPrint(&buf, "   events: {d}", .{st.events}) catch "";
        _ = f.text(1 + 10 + digits(st.counter), counter_row, f.cols -| 12, tail, muted);
    }
    if (f.rows > click_row) {
        const style: sdk.Style = if (st.focused) .reverse else .bold;
        f.fill(0, click_row, f.cols, 1, style);
        _ = f.text(1, click_row, f.cols -| 1, "▸ click here, or ↑ ↓ / j k / space to count", style);
    }
    if (f.rows > 1) {
        const footer = if (st.last_click) |c|
            std.fmt.bufPrint(&buf, "r reset · h toast · q quit · last click {d},{d}", .{ c.col, c.row }) catch ""
        else
            "r reset · h toast · q quit";
        _ = f.text(1, f.rows - 1, f.cols -| 1, footer, muted);
    }
}

fn digits(n: u32) u16 {
    var d: u16 = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

test "the manifest names the pane command first, with a chip, a segment, a setting and a context-menu row" {
    try std.testing.expectEqualStrings("sample", spec.id);
    try std.testing.expectEqualStrings("mnml-sample", spec.binary);
    try std.testing.expectEqualStrings("sample.open", spec.commands[0].id);
    try std.testing.expect(spec.commands[0].ex == null);
    try std.testing.expect(spec.commands[1].ex != null);
    try std.testing.expect(spec.chip != null);
    try std.testing.expectEqual(@as(usize, 1), spec.statusline.len);
    try std.testing.expectEqual(@as(usize, 1), spec.context_menu.len);
    try std.testing.expectEqualStrings("mood", spec.settings[0].key);
    try sdk.manifest.validateId(spec.id);
}

test "the manifest renders and parses back to the same shape" {
    const text = try sdk.manifest.render(std.testing.allocator, spec);
    defer std.testing.allocator.free(text);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const z = try arena_state.allocator().dupeZ(u8, text);
    const back = try std.zon.parse.fromSliceAlloc(sdk.Manifest, arena_state.allocator(), z, null, .{ .free_on_error = false });
    try std.testing.expectEqualStrings(spec.id, back.id);
    try std.testing.expectEqualStrings(spec.commands[1].ex.?, back.commands[1].ex.?);
    try std.testing.expectEqualStrings("chip", back.statusline[0].id);
    try std.testing.expectEqualStrings("tree.file", back.context_menu[0].target);
}
