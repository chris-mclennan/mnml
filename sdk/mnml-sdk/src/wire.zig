//! The Bridge v2 wire — what a mounted integration and mnml say to each
//! other over the mount socket. This file is the protocol: the host
//! (`src/bridge/wire.zig`) re-exports it, the SDK client speaks it, and
//! `docs/BRIDGE.md` is written from it.
//!
//! Framing: a 4-byte little-endian length, then that many bytes of
//! UTF-8 JSON. One message per frame; a frame is never larger than
//! `max_message` (16 MiB) — a bigger length is refused before anything
//! is allocated.
//!
//! Encoding — one rule: **every union is externally tagged**,
//! `{"<tag>": payload}`, the shape `std.json` gives a tagged union. A
//! void payload is `{}`:
//!
//!   {"hello":{"protocol":2,"geometry":{"cols":80,"rows":24},…}}
//!   {"input":{"event":{"key":{"spec":"ctrl+p"}}}}
//!   {"frame":{"cells":[[{"symbol":"a","fg":{"index":4}}]]}}
//!   {"goodbye":{}}
//!
//! v1's `RgbOrIndex` was untagged (an array or a bare integer, sniffed
//! by shape); v2's `Color` is `{"rgb":[r,g,b]}` / `{"index":n}` like
//! everything else. `Hello.protocol` names the version so a sibling can
//! refuse a host it does not understand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The protocol this module speaks. `Hello.protocol` carries it.
pub const protocol: u8 = 2;

/// The largest frame either side will read.
pub const max_message: u32 = 16 * 1024 * 1024;

// ─── host → sibling ──────────────────────────────────────────────────────

pub const Geometry = struct { cols: u16, rows: u16 };

/// What the terminal can show. A sibling that paints rgb on a host
/// with `rgb = false` still works — the host folds the colours onto
/// the 256-cube — but it can pick palette indices itself if it cares.
pub const Capabilities = struct {
    rgb: bool = true,
    nerd_font: bool = true,
    ascii: bool = false,
};

/// The host theme's roles, so a sibling can paint in the theme it is
/// mounted in rather than the terminal's palette. Every role is
/// optional: a host that predates it sends none, a theme that leaves a
/// colour to the terminal sends null for that one, and a sibling falls
/// back to a palette index either way (`Style.fg = .{ .index = n }`).
pub const Palette = struct {
    /// Primary text and the editor ground.
    fg: ?Color = null,
    bg: ?Color = null,
    /// Secondary text: hints, counts, placeholders.
    muted: ?Color = null,
    /// Links, group labels, the "look here" colour.
    accent: ?Color = null,
    /// Pane frames and separators.
    border: ?Color = null,
    /// Activity panels' ground, and the row the cursor is on.
    panel_bg: ?Color = null,
    cursor_line: ?Color = null,
    /// A chip at rest, and one that is on (the primary button).
    chip_fg: ?Color = null,
    chip_bg: ?Color = null,
    chip_active_fg: ?Color = null,
    chip_active_bg: ?Color = null,
    /// The named colours a state or a severity wants.
    red: ?Color = null,
    green: ?Color = null,
    yellow: ?Color = null,
    orange: ?Color = null,
    blue: ?Color = null,
    cyan: ?Color = null,
    purple: ?Color = null,
    comment: ?Color = null,
};

/// The first message after connect.
pub const Hello = struct {
    protocol: u8 = protocol,
    geometry: Geometry,
    /// The theme's name (`onedark`), for a sibling that ships palettes.
    theme: []const u8 = "",
    /// Absolute workspace path.
    workspace: []const u8 = "",
    capabilities: Capabilities = .{},
    /// The theme's roles as colours; null from a host that has none.
    palette: ?Palette = null,
};

pub const Button = enum { left, middle, right };

/// A routed user event. Coordinates are pane-relative cells.
pub const InputEvent = union(enum) {
    /// One key in mnml's spec grammar: `down`, `ctrl+p`, `shift+f5`, `a`.
    key: struct { spec: []const u8 },
    click: struct { col: u16, row: u16, button: Button = .left },
    /// A wheel notch; positive `dy` scrolls up.
    scroll: struct { col: u16, row: u16, dy: i16 },
    /// The pointer moved over the pane. `dragging` says a button was
    /// held while it moved — what turns a press on a scrollbar into a
    /// drag along it. A host that predates the field sends nothing and
    /// every hover reads as a plain move.
    hover: struct { col: u16, row: u16, dragging: bool = false },
    paste: struct { text: []const u8 },
};

/// What a session a pane started is doing now. The host derives it
/// from the same scan the SESSIONS panel reads (`src/app/agents.zig`);
/// the four a button can wear are all a pane needs.
pub const SessionState = enum { running, waiting, done, failed };

/// How a pane names a session it started, and how the host matches it:
/// the host's own id when the pane was given one, else the working
/// directory and the first line of the prompt together — which is all
/// a dispatched `term` line can actually carry. Same rule as the
/// `focus-session` IPC verb, deliberately: a button that can focus a
/// session must be able to watch the same one.
pub const SessionSelector = struct {
    id: []const u8 = "",
    cwd: []const u8 = "",
    prompt_line: []const u8 = "",
};

pub const HostMessage = union(enum) {
    hello: Hello,
    resize: struct { geometry: Geometry },
    input: struct { event: InputEvent },
    /// The pane gained (true) or lost the keyboard.
    focus: bool,
    /// A session the pane asked to watch changed state. `key` is the
    /// pane's own name for the button that started it, echoed back
    /// from the `watch_session` that asked. Sent on the edge only —
    /// once when the host first matches a session, and again whenever
    /// its state moves — so a pane can paint a live spinner rather
    /// than guessing that `[ view ]` still means "running".
    session_state: struct {
        key: []const u8,
        state: SessionState,
        /// The host's id for the matched session, once there is one.
        session_id: []const u8 = "",
        /// The session's last output line — what a failed button puts
        /// on the hint row.
        detail: []const u8 = "",
    },
    /// The host is going away; the sibling should exit.
    goodbye,
};

// ─── sibling → host ──────────────────────────────────────────────────────

pub const Color = union(enum) {
    /// 0–255: 0–7 ANSI, 8–15 bright, 16–231 the 6×6×6 cube, 232–255 grey.
    index: u8,
    rgb: [3]u8,

    /// `std.json` would write a `[3]u8` as a three-byte string; the
    /// wire wants `[r,g,b]`. The parser accepts the array as is.
    pub fn jsonStringify(c: Color, jw: anytype) !void {
        try jw.beginObject();
        switch (c) {
            .index => |i| {
                try jw.objectField("index");
                try jw.write(i);
            },
            .rgb => |v| {
                try jw.objectField("rgb");
                try jw.beginArray();
                for (v) |ch| try jw.write(ch);
                try jw.endArray();
            },
        }
        try jw.endObject();
    }
};

/// Text attributes. On the wire this is one integer — the bit layout
/// is ratatui's `Modifier`, so a v1 sibling's numbers still mean the
/// same thing: bold 1, dim 2, italic 4, underline 8, slow_blink 16,
/// rapid_blink 32, reverse 64, hidden 128, strikethrough 256.
pub const Mods = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    slow_blink: bool = false,
    rapid_blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    _pad: u7 = 0,

    pub const none: Mods = .{};

    pub fn bits(m: Mods) u16 {
        return @bitCast(m);
    }

    pub fn fromBits(v: u16) Mods {
        return @bitCast(v);
    }

    pub fn jsonStringify(m: Mods, jw: anytype) !void {
        try jw.write(m.bits());
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Mods {
        return fromBits(try std.json.innerParse(u16, allocator, source, options));
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: std.json.Value, options: std.json.ParseOptions) !Mods {
        return fromBits(try std.json.innerParseFromValue(u16, allocator, source, options));
    }
};

/// One cell. `symbol` is a whole grapheme; an empty symbol is a wide
/// glyph's tail (or "leave this cell alone" in a dirty row) and paints
/// nothing. Absent colours are the theme's.
pub const Cell = struct {
    symbol: []const u8 = " ",
    fg: ?Color = null,
    bg: ?Color = null,
    mods: Mods = .{},

    /// Only what differs from the default goes on the wire — a frame is
    /// mostly blanks, and `{"symbol":" "}` is a fifth the bytes.
    pub fn jsonStringify(c: Cell, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("symbol");
        try jw.write(c.symbol);
        if (c.fg) |fg| {
            try jw.objectField("fg");
            try jw.write(fg);
        }
        if (c.bg) |bg| {
            try jw.objectField("bg");
            try jw.write(bg);
        }
        if (c.mods.bits() != 0) {
            try jw.objectField("mods");
            try jw.write(c.mods);
        }
        try jw.endObject();
    }
};

/// One row of a dirty frame: `y` is the row, `cells` its full width.
pub const Row = struct { y: u16, cells: []const Cell };

pub const ToastLevel = enum { info, warn, @"error" };

pub const Cursor = struct { x: u16, y: u16 };

pub const SiblingMessage = union(enum) {
    /// A whole screen, `geometry.rows` rows of `geometry.cols` cells.
    /// Short rows are right-padded by the host.
    frame: struct { cells: []const []const Cell },
    /// Only the rows that changed since the last frame.
    frame_dirty: struct { rows: []const Row },
    /// The tab label.
    title: []const u8,
    /// Where the terminal cursor goes while the pane has focus; null hides it.
    cursor: ?Cursor,
    /// Run a command by id (a built-in, or one the sibling registered).
    command: struct { id: []const u8 },
    toast: struct { level: ToastLevel = .info, text: []const u8 },
    /// "I just started this session; keep me posted." The host answers
    /// with `session_state` lines carrying the same `key` back. A
    /// second watch under a key replaces the first, so a button that
    /// is pressed again follows the newer session.
    watch_session: struct { key: []const u8, selector: SessionSelector },
    /// A clean exit.
    bye,
};

// ─── framing ─────────────────────────────────────────────────────────────

pub const ReadError = error{
    /// The length prefix names more than `max_message` bytes.
    TooLarge,
    /// The stream ended inside a frame.
    Truncated,
    ReadFailed,
} || Allocator.Error;

/// One frame's body, gpa-owned. Null on a clean end of stream (no bytes
/// after the last frame); `Truncated` when the stream ends mid-frame.
pub fn readMessage(gpa: Allocator, r: *Io.Reader) ReadError!?[]u8 {
    _ = r.peek(1) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    const len_bytes = r.takeArray(4) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.ReadFailed,
    };
    const len = std.mem.readInt(u32, len_bytes, .little);
    if (len > max_message) return error.TooLarge;
    const body = try gpa.alloc(u8, len);
    errdefer gpa.free(body);
    r.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.ReadFailed,
    };
    return body;
}

/// One frame out: the length, the body, a flush.
pub fn writeMessage(w: *Io.Writer, body: []const u8) Io.Writer.Error!void {
    std.debug.assert(body.len <= max_message);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(body.len), .little);
    try w.writeAll(&len_bytes);
    try w.writeAll(body);
    try w.flush();
}

/// A message as its JSON body, gpa-owned.
pub fn encode(gpa: Allocator, msg: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, msg, .{ .emit_null_optional_fields = false });
}

pub const DecodeError = error{BadMessage} || Allocator.Error;

/// A body as a message. Every slice in the result lives on `arena`
/// (nothing points into `body`); unknown fields are ignored so a newer
/// peer can add fields without breaking an older one.
pub fn decode(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadMessage,
    };
}

/// Encode + frame in one call.
pub fn send(gpa: Allocator, w: *Io.Writer, msg: anytype) (Allocator.Error || Io.Writer.Error)!void {
    const body = try encode(gpa, msg);
    defer gpa.free(body);
    try writeMessage(w, body);
}

/// Read + decode in one call. Null at a clean end of stream.
pub fn receive(comptime T: type, gpa: Allocator, arena: Allocator, r: *Io.Reader) (ReadError || DecodeError)!?T {
    const body = (try readMessage(gpa, r)) orelse return null;
    defer gpa.free(body);
    return try decode(T, arena, body);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn roundTrip(comptime T: type, arena: Allocator, msg: T) !T {
    const body = try encode(testing.allocator, msg);
    defer testing.allocator.free(body);
    return decode(T, arena, body);
}

test "every host message round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hello = try roundTrip(HostMessage, arena, .{ .hello = .{
        .geometry = .{ .cols = 80, .rows = 24 },
        .theme = "onedark",
        .workspace = "/ws",
        .capabilities = .{ .rgb = false, .ascii = true },
    } });
    try testing.expectEqual(@as(u8, 2), hello.hello.protocol);
    try testing.expectEqual(@as(u16, 80), hello.hello.geometry.cols);
    try testing.expectEqualStrings("onedark", hello.hello.theme);
    try testing.expectEqualStrings("/ws", hello.hello.workspace);
    try testing.expect(!hello.hello.capabilities.rgb);
    try testing.expect(hello.hello.capabilities.ascii);
    try testing.expect(hello.hello.capabilities.nerd_font);

    const resize = try roundTrip(HostMessage, arena, .{ .resize = .{ .geometry = .{ .cols = 10, .rows = 3 } } });
    try testing.expectEqual(@as(u16, 3), resize.resize.geometry.rows);

    const key = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .key = .{ .spec = "ctrl+shift+p" } } } });
    try testing.expectEqualStrings("ctrl+shift+p", key.input.event.key.spec);
    const click = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .click = .{ .col = 3, .row = 4, .button = .right } } } });
    try testing.expectEqual(Button.right, click.input.event.click.button);
    const scroll = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .scroll = .{ .col = 0, .row = 0, .dy = -3 } } } });
    try testing.expectEqual(@as(i16, -3), scroll.input.event.scroll.dy);
    const hover = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .hover = .{ .col = 7, .row = 1 } } } });
    try testing.expectEqual(@as(u16, 7), hover.input.event.hover.col);
    try testing.expect(!hover.input.event.hover.dragging);
    const drag = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .hover = .{ .col = 7, .row = 1, .dragging = true } } } });
    try testing.expect(drag.input.event.hover.dragging);
    const paste = try roundTrip(HostMessage, arena, .{ .input = .{ .event = .{ .paste = .{ .text = "a\nb\"c" } } } });
    try testing.expectEqualStrings("a\nb\"c", paste.input.event.paste.text);

    const focus = try roundTrip(HostMessage, arena, .{ .focus = false });
    try testing.expect(!focus.focus);
    const ss = try roundTrip(HostMessage, arena, .{ .session_state = .{ .key = "ENG-2\u{1f}triage", .state = .waiting, .session_id = "abc-123", .detail = "Do you want to proceed?" } });
    try testing.expectEqualStrings("ENG-2\u{1f}triage", ss.session_state.key);
    try testing.expectEqual(SessionState.waiting, ss.session_state.state);
    try testing.expectEqualStrings("abc-123", ss.session_state.session_id);
    try testing.expectEqualStrings("Do you want to proceed?", ss.session_state.detail);
    // The two optional halves default away, so a host that matched by
    // cwd alone still round-trips.
    const bare = try roundTrip(HostMessage, arena, .{ .session_state = .{ .key = "k", .state = .done } });
    try testing.expectEqualStrings("", bare.session_state.session_id);
    try testing.expectEqualStrings("", bare.session_state.detail);
    const bye = try roundTrip(HostMessage, arena, .goodbye);
    try testing.expect(bye == .goodbye);
}

test "every sibling message round-trips; colours are externally tagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const row0 = [_]Cell{
        .{ .symbol = "a", .fg = .{ .rgb = .{ 255, 0, 10 } }, .mods = .{ .bold = true, .underline = true } },
        .{ .symbol = "漢", .bg = .{ .index = 4 } },
        .{ .symbol = "" },
    };
    const row1 = [_]Cell{.{}};
    const rows = [_][]const Cell{ &row0, &row1 };
    const frame = try roundTrip(SiblingMessage, arena, .{ .frame = .{ .cells = &rows } });
    try testing.expectEqual(@as(usize, 2), frame.frame.cells.len);
    try testing.expectEqualStrings("a", frame.frame.cells[0][0].symbol);
    try testing.expectEqual(Color{ .rgb = .{ 255, 0, 10 } }, frame.frame.cells[0][0].fg.?);
    try testing.expect(frame.frame.cells[0][0].bg == null);
    try testing.expect(frame.frame.cells[0][0].mods.bold);
    try testing.expect(frame.frame.cells[0][0].mods.underline);
    try testing.expect(!frame.frame.cells[0][0].mods.italic);
    try testing.expectEqualStrings("漢", frame.frame.cells[0][1].symbol);
    try testing.expectEqual(Color{ .index = 4 }, frame.frame.cells[0][1].bg.?);
    try testing.expectEqualStrings("", frame.frame.cells[0][2].symbol);
    try testing.expectEqualStrings(" ", frame.frame.cells[1][0].symbol);
    try testing.expectEqual(@as(u16, 0), frame.frame.cells[1][0].mods.bits());

    const dirty_rows = [_]Row{.{ .y = 5, .cells = &row1 }};
    const dirty = try roundTrip(SiblingMessage, arena, .{ .frame_dirty = .{ .rows = &dirty_rows } });
    try testing.expectEqual(@as(u16, 5), dirty.frame_dirty.rows[0].y);

    const title = try roundTrip(SiblingMessage, arena, .{ .title = "Jira · TE-12" });
    try testing.expectEqualStrings("Jira · TE-12", title.title);
    const cursor = try roundTrip(SiblingMessage, arena, .{ .cursor = .{ .x = 1, .y = 2 } });
    try testing.expectEqual(@as(u16, 2), cursor.cursor.?.y);
    const no_cursor = try roundTrip(SiblingMessage, arena, .{ .cursor = null });
    try testing.expect(no_cursor.cursor == null);
    const cmd = try roundTrip(SiblingMessage, arena, .{ .command = .{ .id = "file.save" } });
    try testing.expectEqualStrings("file.save", cmd.command.id);
    const toast = try roundTrip(SiblingMessage, arena, .{ .toast = .{ .level = .warn, .text = "hmm" } });
    try testing.expectEqual(ToastLevel.warn, toast.toast.level);
    const watch = try roundTrip(SiblingMessage, arena, .{ .watch_session = .{ .key = "acme/api#7\u{1f}merge", .selector = .{ .cwd = "/ws", .prompt_line = "/agents:developer ENG-2" } } });
    try testing.expectEqualStrings("acme/api#7\u{1f}merge", watch.watch_session.key);
    try testing.expectEqualStrings("/ws", watch.watch_session.selector.cwd);
    try testing.expectEqualStrings("/agents:developer ENG-2", watch.watch_session.selector.prompt_line);
    try testing.expectEqualStrings("", watch.watch_session.selector.id);
    const bye = try roundTrip(SiblingMessage, arena, .bye);
    try testing.expect(bye == .bye);
}

test "the JSON shape is the documented one" {
    const gpa = testing.allocator;
    const hello = try encode(gpa, HostMessage{ .hello = .{ .geometry = .{ .cols = 8, .rows = 2 } } });
    defer gpa.free(hello);
    try testing.expectEqualStrings("{\"hello\":{\"protocol\":2,\"geometry\":{\"cols\":8,\"rows\":2},\"theme\":\"\",\"workspace\":\"\",\"capabilities\":{\"rgb\":true,\"nerd_font\":true,\"ascii\":false}}}", hello);
    const bye = try encode(gpa, @as(SiblingMessage, .bye));
    defer gpa.free(bye);
    try testing.expectEqualStrings("{\"bye\":{}}", bye);
    const cell = try encode(gpa, Cell{ .symbol = "x", .fg = .{ .rgb = .{ 1, 2, 3 } }, .bg = .{ .index = 9 }, .mods = .{ .reverse = true } });
    defer gpa.free(cell);
    try testing.expectEqualStrings("{\"symbol\":\"x\",\"fg\":{\"rgb\":[1,2,3]},\"bg\":{\"index\":9},\"mods\":64}", cell);
    const blank = try encode(gpa, Cell{});
    defer gpa.free(blank);
    try testing.expectEqualStrings("{\"symbol\":\" \"}", blank);
    // Unknown fields inside a payload (a newer peer) are ignored; the
    // envelope itself is exactly one tag. A bare integer where v1 put
    // an index is refused — the tag is the contract.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const newer = try decode(SiblingMessage, arena, "{\"toast\":{\"text\":\"t\",\"_future\":1}}");
    try testing.expectEqualStrings("t", newer.toast.text);
    try testing.expectError(error.BadMessage, decode(SiblingMessage, arena, "{\"title\":\"t\",\"bye\":{}}"));
    try testing.expectError(error.BadMessage, decode(SiblingMessage, arena, "{\"frame\":{\"cells\":[[{\"symbol\":\"a\",\"fg\":4}]]}}"));
    try testing.expectError(error.BadMessage, decode(HostMessage, arena, "{\"nope\":{}}"));
    try testing.expectError(error.BadMessage, decode(HostMessage, arena, "not json"));
}

test "framing: a stream of frames reads back in order; EOF, truncation and oversize are told apart" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const bodies = [_][]const u8{ "{\"bye\":{}}", "", "{\"title\":\"x\"}" };
    for (bodies) |b| try writeMessage(&out.writer, b);
    var r: Io.Reader = .fixed(out.written());
    for (bodies) |want| {
        const got = (try readMessage(gpa, &r)).?;
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
    try testing.expect((try readMessage(gpa, &r)) == null);
    try testing.expect((try readMessage(gpa, &r)) == null);

    // Cut inside the length, inside the body.
    const all = out.written();
    var cut1: Io.Reader = .fixed(all[0..2]);
    try testing.expectError(error.Truncated, readMessage(gpa, &cut1));
    var cut2: Io.Reader = .fixed(all[0..7]);
    try testing.expectError(error.Truncated, readMessage(gpa, &cut2));
    // A 100 MiB length is refused before any allocation.
    var big: [8]u8 = undefined;
    std.mem.writeInt(u32, big[0..4], 100 * 1024 * 1024, .little);
    @memcpy(big[4..], "junk");
    var r_big: Io.Reader = .fixed(&big);
    try testing.expectError(error.TooLarge, readMessage(gpa, &r_big));
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var r_body: Io.Reader = .fixed(all);
    try testing.expectError(error.OutOfMemory, readMessage(failing.allocator(), &r_body));
}

test "framing fuzz: random bodies of random lengths survive a round trip; random garbage never panics" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var lens: [64]usize = undefined;
    for (&lens) |*l| {
        l.* = rand.uintLessThan(usize, 300);
        const body = try gpa.alloc(u8, l.*);
        defer gpa.free(body);
        rand.bytes(body);
        try writeMessage(&out.writer, body);
    }
    var r: Io.Reader = .fixed(out.written());
    for (lens) |l| {
        const got = (try readMessage(gpa, &r)).?;
        defer gpa.free(got);
        try testing.expectEqual(l, got.len);
    }
    try testing.expect((try readMessage(gpa, &r)) == null);
    // Garbage in: every outcome is an error or a body, never a crash.
    var junk: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const n = rand.uintLessThan(usize, junk.len);
        rand.bytes(junk[0..n]);
        var jr: Io.Reader = .fixed(junk[0..n]);
        while (true) {
            const got = readMessage(gpa, &jr) catch break;
            const body = got orelse break;
            defer gpa.free(body);
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            _ = decode(HostMessage, arena_state.allocator(), body) catch {};
        }
    }
}
