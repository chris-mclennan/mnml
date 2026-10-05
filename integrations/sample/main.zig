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
//!
//! The chrome is the toolkit's (`sdk.pane`): the caps header, the
//! app-colour gutter, the row ground and the clickable hint row. Copy
//! `paint` below into a new integration and the pane looks like mnml
//! rather than like a table someone transplanted. See the README.

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
        // The manifest's own chip colour becomes the pane's brand, so
        // the gutter stripe is this integration's colour on the rail.
        .th = sdk.pane.Theme.fromHelloBranded(mount.hello.palette, if (spec.chip) |c| c.color else ""),
        // What the host can draw: its Nerd Font, or the `--ascii` twins.
        .ui = .{ .nerd = mount.hello.capabilities.nerd_font, .ascii = mount.hello.capabilities.ascii },
    };
    defer state.hits.deinit(gpa);
    try mount.setTitle(spec.label);

    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();
    paint(gpa, msg_arena.allocator(), &frame, &state);
    try mount.send(&frame);

    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        switch (msg) {
            .hello, .session_state, .focus_item => {},
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
                    // One lookup on the toolkit's map: a click lands on
                    // what the eye sees, including the hint row.
                    switch (state.hits.at(c.col, c.row) orelse .counter) {
                        // The header runs the pane's own published
                        // command, through the host: it focuses this
                        // pane, the one it would open.
                        .title => try mount.command("sample.open"),
                        .click_row => state.counter += 1,
                        .counter => if (c.button == .right) {
                            state.counter = 0;
                        },
                        .reset => state.counter = 0,
                        .toast => try mount.toast(.info, "hello from the sample"),
                        .quit => {
                            mount.bye();
                            return 0;
                        },
                    }
                },
                .scroll => |s| {
                    state.events += 1;
                    if (s.dy > 0) state.counter += 1 else state.counter -|= 1;
                },
                // Name the element under the pointer for the host's
                // info view; `hoverHelp` sends only on a change.
                .hover => |h| try mount.hoverHelp(helpAt(&state, h.col, h.row)),
                .paste => {},
            },
        }
        paint(gpa, msg_arena.allocator(), &frame, &state);
        try mount.send(&frame);
    }
    return 0;
}

/// What a click can land on. The toolkit's hit map is generic over this,
/// so the pane keeps its own vocabulary.
pub const Target = union(enum) { title, counter, click_row, reset, toast, quit };

/// What the info view says about each element. The header's click
/// runs a command, so its entry names it (`Help.runs`) and the host
/// ends the entry with that command's chord — the one place a pane
/// says "this click is that command".
fn helpAt(st: *const State, col: u16, row: u16) sdk.pane.help.Help {
    const H = sdk.pane.help;
    const tg = st.hits.at(col, row) orelse return .{ .title = "" };
    return switch (tg) {
        .title => (H.Help{ .title = "Sample pane", .body = "The sample integration's counter. Click runs Sample: open, which focuses this pane." }).runs("sample.open"),
        .counter => .{ .title = "Counter", .body = "How many times the pane was counted up, and every input it saw. Right-click sets it back to 0." },
        .click_row => .{ .title = "Count row", .body = "Click counts up by one; so do up, k, + and space." },
        .reset => .{ .title = "r — reset", .body = "Click runs what the key runs: the counter back to 0." },
        .toast => .{ .title = "h — toast", .body = "Click runs what the key runs: a toast from the pane." },
        .quit => .{ .title = "q — quit", .body = "Click runs what the key runs: the pane says bye and closes." },
    };
}

const State = struct {
    theme: []const u8,
    mood: []const u8,
    /// The host theme's roles, with this integration's manifest chip
    /// colour as its brand — what the gutter stripe paints in.
    th: sdk.pane.Theme = .{},
    ui: sdk.pane.Ui = .{},
    counter: u32 = 0,
    events: u32 = 0,
    focused: bool = true,
    hits: sdk.pane.HitMap(Target) = .{},
    last_click: ?struct { col: u16, row: u16 } = null,
};

/// Ten lines of toolkit and the pane is in mnml's chrome.
fn paint(gpa: std.mem.Allocator, arena: std.mem.Allocator, f: *sdk.Frame, st: *State) void {
    st.hits.reset();
    f.clear(.{ .fg = st.th.fg, .bg = st.th.bg });
    var p: sdk.pane.Painter(Target) = .{ .f = f, .gpa = gpa, .arena = arena, .hits = &st.hits, .th = st.th, .ui = st.ui };
    // The app-colour stripe down column 0, under everything else.
    p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = f.rows -| 1 }, click_row);
    // Row 0: the caps header — the label and, dim beside it, the theme
    // mnml told us about, the setting and the geometry.
    const sub = p.fmt(" \u{b7} theme {s} \u{b7} mood {s} \u{b7} {d}\u{d7}{d}", .{ st.theme, st.mood, f.cols, f.rows });
    _ = p.capsTitle(1, 0, "SAMPLE", sub);
    p.mark(.{ .x = 1, .y = 0, .w = f.cols -| 1, .h = 1 }, .title) catch {};
    if (f.rows > counter_row) {
        const line = p.fmt("counter: {d}", .{st.counter});
        const used = p.put(1, counter_row, f.cols -| 1, line, st.th.bright());
        _ = p.put(1 + used, counter_row, f.cols -| (1 + used), p.fmt("   events: {d}", .{st.events}), st.th.dimText());
        p.mark(.{ .x = 0, .y = counter_row, .w = f.cols, .h = 1 }, .counter) catch {};
    }
    if (f.rows > click_row) {
        // The row the cursor is on: the toolkit's ground plus gutter.
        p.rowGround(.{ .x = 0, .y = click_row, .w = f.cols, .h = 1 }, st.focused, .click_row) catch {};
        _ = p.put(2, click_row, f.cols -| 2, if (st.ui.ascii) "click here, or up down / j k / space to count" else "click here, or \u{2191} \u{2193} / j k / space to count", st.th.cursorRow());
    }
    if (f.rows > 1) {
        // The hint row: every `key label` a hit that runs it.
        const hints = [_]sdk.pane.Painter(Target).HintSpec{
            .{ .key = "r", .title = "reset", .target = .reset },
            .{ .key = "h", .title = "toast", .target = .toast },
            .{ .key = "q", .title = "quit", .target = .quit },
        };
        const status = if (st.last_click) |c| p.fmt("last click {d},{d}", .{ c.col, c.row }) else "";
        p.hintRow(f.rows - 1, status, &hints) catch {};
    }
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

test "the header's hover names the command its click runs; the counter's names none" {
    var r = try Probe.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try r.paint(arena.allocator());
    const head = helpAt(&r.st, 3, 0);
    try std.testing.expectEqualStrings("Sample pane", head.title);
    try std.testing.expectEqualStrings("sample.open", head.command.?);
    try std.testing.expectEqual(@as(?[]const u8, null), helpAt(&r.st, 3, counter_row).command);
}

const paintPane = paint;
const PaneTarget = Target;

/// The pane on its fixture, for the SDK's design-language suite.
const Probe = struct {
    pub const Target = PaneTarget;
    f: sdk.Frame,
    st: State,

    pub fn init(gpa: std.mem.Allocator, size: sdk.testing.Size) !Probe {
        return .{
            .f = try sdk.Frame.init(gpa, size.cols, size.rows),
            .st = .{
                .theme = "onedark",
                .mood = "calm",
                .th = sdk.pane.Theme.fromHelloBranded(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } } }, "teal"),
                .ui = .{ .ascii = size.ascii },
                .counter = 3,
            },
        };
    }

    pub fn deinit(p: *Probe) void {
        p.st.hits.deinit(std.testing.allocator);
        p.f.deinit();
    }

    pub fn paint(p: *Probe, arena: std.mem.Allocator) !sdk.testing.Painted(PaneTarget) {
        paintPane(std.testing.allocator, arena, &p.f, &p.st);
        // No header ladder, no scrolling list and no live statusline
        // figure: the sample has none of the three, so those rules say
        // nothing here. Its manifest segment is a label, not a figure.
        return .{
            .frame = &p.f,
            .hits = &p.st.hits,
            .theme = p.st.th,
            .title = .{ .text = "SAMPLE" },
            .gutter = .{ .h = p.f.rows - 1 },
        };
    }
};

test "the design language: the SDK's conformance suite at 120x40 and 80x24, with and without --ascii" {
    try sdk.testing.conformance(Probe);
}
