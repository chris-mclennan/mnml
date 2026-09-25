//! One line of the `command` channel: a JSON object with a required `cmd`
//! and whichever other fields that command reads. Every field is optional
//! on the wire so a host can send `{"cmd":"snapshot"}` bare and
//! `{"cmd":"click","col":5,"row":3}` without a schema per command.
//!
//! A line that is not JSON, has no `cmd`, names an unknown `cmd`, or lacks a
//! field its `cmd` needs is `.unknown` with the raw line — never dropped, so
//! the host sees an `unknown` ack and can fix its script.

const std = @import("std");
const Allocator = std.mem.Allocator;
const key = @import("../core/key.zig");

/// The wire shape. Missing fields take their defaults; a field of the
/// wrong JSON type fails the whole line (as serde does).
pub const Raw = struct {
    cmd: []const u8,
    path: ?[]const u8 = null,
    key: ?[]const u8 = null,
    /// `run-command` / `register-command`: the command id.
    id: ?[]const u8 = null,
    /// `register-command`: palette title.
    title: ?[]const u8 = null,
    /// `register-command`: which-key / palette group (default `plugin`).
    group: ?[]const u8 = null,
    /// `register-command`: keyspecs to bind.
    keys: []const []const u8 = &.{},
    /// `type` / `toast` / `expect_screen` / `ghost` / `notify` body / …
    text: ?[]const u8 = null,
    /// Mouse commands: cell coordinates on the virtual screen.
    col: ?Num(u16) = null,
    row: ?Num(u16) = null,
    /// `click`: `left` (default) / `middle` / `right`, or the first letter.
    button: ?[]const u8 = null,
    /// `scroll`: wheel ticks; positive scrolls up. Default 1.
    dy: ?Num(i32) = null,
    /// `click`: comma-separated `ctrl` / `alt` / `shift` / `super`.
    mods: ?[]const u8 = null,
    /// `expect_screen`: `contains` (default) or `lacks`.
    expect: ?[]const u8 = null,
    /// `wait_ms`.
    ms: ?Num(u64) = null,
    /// `drag`: press point; `col`/`row` hold the release point.
    from_col: ?Num(u16) = null,
    from_row: ?Num(u16) = null,
    /// `open-pty`: argv.
    command: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// `focus-session`: the first line of the prompt the session was
    /// started with.
    prompt_line: ?[]const u8 = null,
    /// `set-activity-badge`.
    section: ?[]const u8 = null,
    count: ?Num(u32) = null,
    /// `toast` / `notify`: `info` (default) / `warn` / `error`.
    level: ?[]const u8 = null,
    /// `statusline-set-segment`.
    side: ?[]const u8 = null,
    color: ?[]const u8 = null,
    click_command: ?[]const u8 = null,
    priority: ?Num(u8) = null,
    min_width: ?Num(u16) = null,
    max_width: ?Num(u16) = null,
    /// `statusline-set-segment`: the hover text.
    tooltip: ?[]const u8 = null,
    /// `statusline-set-segment`: the things behind the figure, for the
    /// hover to list. A row with no `text` is skipped rather than
    /// failing the line — one malformed item must not cost the chip.
    items: []const RawItem = &.{},
    /// `notify`.
    sound: ?bool = null,
    source: ?[]const u8 = null,
};

/// One row of a segment's hover list, as it arrives.
pub const RawItem = struct {
    text: ?[]const u8 = null,
    sub: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

/// One row of a segment's hover list, kept: what it is, what to say
/// about it on the right, and what a click on it runs.
pub const SegmentItem = struct {
    text: []const u8,
    sub: []const u8 = "",
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

/// An integer that must arrive as a bare JSON number. `std.json` would also
/// accept `"5"` and `5.0`; the Rust host rejects both, so this does too.
pub fn Num(comptime T: type) type {
    return struct {
        v: T,

        pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer switch (token) {
                .allocated_number, .allocated_string => |s| allocator.free(s),
                else => {},
            };
            const slice = switch (token) {
                inline .number, .allocated_number => |s| s,
                else => return error.UnexpectedToken,
            };
            return .{ .v = std.fmt.parseInt(T, slice, 10) catch return error.InvalidNumber };
        }
    };
}

fn val(comptime T: type, n: ?Num(T)) ?T {
    return if (n) |x| x.v else null;
}

pub const ToastLevel = enum { info, warn, @"error" };
pub const ProgressStatus = enum { success, failed, cancelled };
pub const SegmentSide = enum { left, right };

pub const MouseAt = struct {
    col: u16,
    row: u16,
    button: key.MouseButton = .left,
    mods: key.Mods = .{},
};

pub const At = struct { col: u16, row: u16 };

pub const Command = union(enum) {
    /// A path, workspace-relative or absolute.
    open: []const u8,
    /// A key spec — one chord, a whitespace chain, or a vim run like `gg`.
    key: []const u8,
    type: []const u8,
    run_command: []const u8,
    register_command: struct {
        id: []const u8,
        title: []const u8,
        group: []const u8,
        keys: []const []const u8,
    },
    click: MouseAt,
    hover: At,
    scroll: struct { col: u16, row: u16, dy: i32 },
    drag: struct { from_col: u16, from_row: u16, col: u16, row: u16 },
    mouse_down: MouseAt,
    mouse_move: At,
    mouse_up: MouseAt,
    wait_ms: u64,
    expect_screen: struct { text: []const u8, contains: bool },
    snapshot,
    toast: struct { text: []const u8, level: ToastLevel },
    toast_persistent: struct { id: []const u8, text: []const u8, level: ToastLevel },
    toast_dismiss: []const u8,
    progress_start: struct { id: []const u8, label: []const u8 },
    progress_update: struct { id: []const u8, label: ?[]const u8, percent: ?u8 },
    progress_end: struct { id: []const u8, status: ProgressStatus },
    statusline_set_segment: struct {
        id: []const u8,
        side: SegmentSide,
        text: []const u8,
        color: ?[]const u8,
        click_command: ?[]const u8,
        priority: u8,
        min_width: u16,
        max_width: u16,
        /// The hover text — what the chip's number means, and its
        /// breakdown. The Rust host's line has no such key (its
        /// tooltips are static, on the manifest), so this is mnml-zig's
        /// own: a count worth publishing every five minutes is worth
        /// saying what it counts.
        tooltip: ?[]const u8,
        /// The things the figure counts, in the publisher's order —
        /// the hover lists them under the tooltip line. Empty leaves
        /// the one-line hover an older integration sends.
        items: []const SegmentItem,
    },
    statusline_clear_segment: []const u8,
    notify: struct {
        title: []const u8,
        body: []const u8,
        level: ToastLevel,
        sound: bool,
        source: ?[]const u8,
    },
    open_pty: struct { cwd: ?[]const u8, command: []const []const u8 },
    set_activity_badge: struct { section: []const u8, count: u32 },
    /// `focus-session`: bring a session mnml is running to the front.
    /// A pane that dispatched one names it by the host's id when it was
    /// given one, else by the directory it runs in and the first line
    /// of the prompt it was started with — which is all a dispatched
    /// `term` line can actually say about it.
    focus_session: struct { id: ?[]const u8, cwd: ?[]const u8, prompt_line: ?[]const u8 },
    dump_rects,
    ghost: []const u8,
    /// `ex`: an ex command line, as `:` would run it (`bd!`) — the
    /// `.test` step of the same name, for a host driving a live window.
    ex: []const u8,
    quit,
    restart,
    /// The raw line, for the `unknown` ack.
    unknown: []const u8,
};

/// Parse one line. Every slice in the result lives in `arena`.
pub fn parse(arena: Allocator, line: []const u8) Allocator.Error!Command {
    const raw = std.json.parseFromSliceLeaky(Raw, arena, line, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .unknown = try arena.dupe(u8, line) },
    };
    return (try fromRaw(arena, raw)) orelse .{ .unknown = try arena.dupe(u8, line) };
}

fn fromRaw(arena: Allocator, raw: Raw) Allocator.Error!?Command {
    const Kind = enum {
        open,
        key,
        type,
        @"run-command",
        @"register-command",
        click,
        hover,
        scroll,
        drag,
        mouse_down,
        mouse_move,
        mouse_up,
        wait_ms,
        expect_screen,
        snapshot,
        toast,
        @"toast-persistent",
        @"toast-dismiss",
        @"progress-start",
        @"progress-update",
        @"progress-end",
        @"statusline-set-segment",
        @"statusline-clear-segment",
        notify,
        @"open-pty",
        @"set-activity-badge",
        @"focus-session",
        @"dump-rects",
        ghost,
        ex,
        quit,
        restart,
    };
    const kind = std.meta.stringToEnum(Kind, raw.cmd) orelse return null;
    return switch (kind) {
        .open => .{ .open = raw.path orelse return null },
        .key => .{ .key = raw.key orelse return null },
        .type => .{ .type = raw.text orelse return null },
        .@"run-command" => .{ .run_command = raw.id orelse return null },
        .@"register-command" => blk: {
            const id = raw.id orelse return null;
            break :blk .{ .register_command = .{
                .id = id,
                .title = raw.title orelse id,
                .group = raw.group orelse "plugin",
                .keys = raw.keys,
            } };
        },
        .click => .{ .click = mouseAt(raw) orelse return null },
        .hover => .{ .hover = at(raw) orelse return null },
        .scroll => blk: {
            const p = at(raw) orelse return null;
            break :blk .{ .scroll = .{ .col = p.col, .row = p.row, .dy = val(i32, raw.dy) orelse 1 } };
        },
        .drag => .{ .drag = .{
            .from_col = val(u16, raw.from_col) orelse return null,
            .from_row = val(u16, raw.from_row) orelse return null,
            .col = val(u16, raw.col) orelse return null,
            .row = val(u16, raw.row) orelse return null,
        } },
        .mouse_down => .{ .mouse_down = mouseAt(raw) orelse return null },
        .mouse_move => .{ .mouse_move = at(raw) orelse return null },
        .mouse_up => .{ .mouse_up = mouseAt(raw) orelse return null },
        .wait_ms => .{ .wait_ms = val(u64, raw.ms) orelse return null },
        .expect_screen => .{ .expect_screen = .{
            .text = raw.text orelse return null,
            .contains = !(raw.expect != null and std.mem.eql(u8, raw.expect.?, "lacks")),
        } },
        .snapshot => .snapshot,
        .toast => .{ .toast = .{ .text = raw.text orelse return null, .level = toastLevel(raw.level) } },
        .@"toast-persistent" => .{ .toast_persistent = .{
            .id = raw.id orelse return null,
            .text = raw.text orelse return null,
            .level = toastLevel(raw.level),
        } },
        .@"toast-dismiss" => .{ .toast_dismiss = raw.id orelse return null },
        .@"progress-start" => .{ .progress_start = .{ .id = raw.id orelse return null, .label = raw.text orelse return null } },
        .@"progress-update" => .{ .progress_update = .{
            .id = raw.id orelse return null,
            .label = raw.text,
            .percent = if (val(u32, raw.count)) |c| @intCast(@min(c, 100)) else null,
        } },
        .@"progress-end" => .{ .progress_end = .{ .id = raw.id orelse return null, .status = progressStatus(raw.text) } },
        .@"statusline-set-segment" => .{ .statusline_set_segment = .{
            .id = raw.id orelse return null,
            .side = segmentSide(raw.side),
            .text = raw.text orelse return null,
            .color = raw.color,
            .click_command = raw.click_command,
            .priority = val(u8, raw.priority) orelse 100,
            .min_width = val(u16, raw.min_width) orelse 4,
            .max_width = val(u16, raw.max_width) orelse 30,
            .tooltip = raw.tooltip,
            .items = try segmentItems(arena, raw.items),
        } },
        .@"statusline-clear-segment" => .{ .statusline_clear_segment = raw.id orelse return null },
        .notify => .{ .notify = .{
            .title = raw.title orelse "mnml",
            .body = raw.text orelse return null,
            .level = toastLevel(raw.level),
            .sound = raw.sound orelse false,
            .source = raw.source,
        } },
        .@"open-pty" => if (raw.command.len == 0) null else .{ .open_pty = .{ .cwd = raw.cwd, .command = raw.command } },
        .@"set-activity-badge" => .{ .set_activity_badge = .{
            .section = raw.section orelse return null,
            .count = val(u32, raw.count) orelse return null,
        } },
        // Nothing to go on is not a focus: refuse it rather than
        // raising whichever session happens to be first.
        .@"focus-session" => if (raw.id == null and raw.cwd == null and raw.prompt_line == null) null else .{ .focus_session = .{
            .id = raw.id,
            .cwd = raw.cwd,
            .prompt_line = raw.prompt_line,
        } },
        .@"dump-rects" => .dump_rects,
        // An empty ghost would be a silent no-op — easy to miss in a script.
        .ghost => if (raw.text) |s| (if (s.len == 0) null else .{ .ghost = s }) else null,
        .ex => if (raw.text) |s| (if (s.len == 0) null else .{ .ex = s }) else null,
        .quit => .quit,
        .restart => .restart,
    };
}

fn at(raw: Raw) ?At {
    return .{ .col = val(u16, raw.col) orelse return null, .row = val(u16, raw.row) orelse return null };
}

fn mouseAt(raw: Raw) ?MouseAt {
    const p = at(raw) orelse return null;
    return .{ .col = p.col, .row = p.row, .button = mouseButton(raw.button), .mods = parseMods(raw.mods) };
}

/// `left` / `middle` / `right`, or the first letter; anything else is left.
pub fn mouseButton(s: ?[]const u8) key.MouseButton {
    const v = s orelse return .left;
    if (eqlLower(v, "middle") or eqlLower(v, "m")) return .middle;
    if (eqlLower(v, "right") or eqlLower(v, "r")) return .right;
    return .left;
}

/// Comma-separated modifier names; unknown names are dropped.
/// The rows a `statusline-set-segment` carried, kept in order. A row
/// with no `text` is dropped — there is nothing to paint for it and
/// dropping one row is cheaper than losing the chip. The wire cap is
/// the host's guard against a publisher that sends a thousand; what
/// the hover actually shows is `statusline.hover_items`.
pub const max_segment_items: usize = 24;

fn segmentItems(arena: Allocator, raw: []const RawItem) Allocator.Error![]const SegmentItem {
    if (raw.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(SegmentItem) = .empty;
    for (raw) |it| {
        if (out.items.len == max_segment_items) break;
        const text = it.text orelse continue;
        if (text.len == 0) continue;
        try out.append(arena, .{
            .text = text,
            .sub = it.sub orelse "",
            .command = it.command,
            .args = it.args,
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn parseMods(s: ?[]const u8) key.Mods {
    var out: key.Mods = .{};
    var it = std.mem.splitScalar(u8, s orelse return out, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t\r\n");
        if (eqlLower(tok, "ctrl") or eqlLower(tok, "control")) out.ctrl = true;
        if (eqlLower(tok, "alt") or eqlLower(tok, "option")) out.alt = true;
        if (eqlLower(tok, "shift")) out.shift = true;
        if (eqlLower(tok, "super") or eqlLower(tok, "cmd") or eqlLower(tok, "meta")) out.super = true;
    }
    return out;
}

pub fn toastLevel(s: ?[]const u8) ToastLevel {
    const v = s orelse return .info;
    if (eqlLower(v, "warn") or eqlLower(v, "warning")) return .warn;
    if (eqlLower(v, "error") or eqlLower(v, "err")) return .@"error";
    return .info;
}

pub fn progressStatus(s: ?[]const u8) ProgressStatus {
    const v = s orelse return .success;
    if (eqlLower(v, "failed") or eqlLower(v, "fail") or eqlLower(v, "error")) return .failed;
    if (eqlLower(v, "cancelled") or eqlLower(v, "canceled")) return .cancelled;
    return .success;
}

pub fn segmentSide(s: ?[]const u8) SegmentSide {
    const v = s orelse return .right;
    return if (eqlLower(v, "left")) .left else .right;
}

fn eqlLower(a: []const u8, lower: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, lower);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn parseT(arena: Allocator, line: []const u8) !Command {
    return parse(arena, line);
}

test "the command table: every cmd resolves to its variant" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expectEqualStrings("hello.txt", (try parseT(a, "{\"cmd\":\"open\",\"path\":\"hello.txt\"}")).open);
    try t.expectEqualStrings("ctrl+w h", (try parseT(a, "{\"cmd\":\"key\",\"key\":\"ctrl+w h\"}")).key);
    try t.expectEqualStrings("AB", (try parseT(a, "{\"cmd\":\"type\",\"text\":\"AB\"}")).type);
    try t.expectEqualStrings("file.save", (try parseT(a, "{\"cmd\":\"run-command\",\"id\":\"file.save\"}")).run_command);

    const reg = (try parseT(a, "{\"cmd\":\"register-command\",\"id\":\"p.a\"}")).register_command;
    try t.expectEqualStrings("p.a", reg.title); // title defaults to the id
    try t.expectEqualStrings("plugin", reg.group);
    try t.expectEqual(@as(usize, 0), reg.keys.len);
    const reg2 = (try parseT(a, "{\"cmd\":\"register-command\",\"id\":\"p.b\",\"title\":\"B\",\"group\":\"g\",\"keys\":[\"ctrl+b\",\"f5\"]}")).register_command;
    try t.expectEqualStrings("B", reg2.title);
    try t.expectEqualStrings("f5", reg2.keys[1]);

    const click = (try parseT(a, "{\"cmd\":\"click\",\"col\":5,\"row\":3,\"button\":\"right\",\"mods\":\"ctrl, Shift\"}")).click;
    try t.expectEqual(key.MouseButton.right, click.button);
    try t.expect(click.mods.ctrl and click.mods.shift and !click.mods.alt);
    try t.expectEqual(key.MouseButton.middle, (try parseT(a, "{\"cmd\":\"click\",\"col\":0,\"row\":0,\"button\":\"M\"}")).click.button);
    try t.expectEqual(key.MouseButton.left, (try parseT(a, "{\"cmd\":\"click\",\"col\":0,\"row\":0,\"button\":\"bogus\"}")).click.button);

    try t.expectEqual(@as(u16, 2), (try parseT(a, "{\"cmd\":\"hover\",\"col\":2,\"row\":9}")).hover.col);
    const sc = (try parseT(a, "{\"cmd\":\"scroll\",\"col\":3,\"row\":3,\"dy\":-2}")).scroll;
    try t.expectEqual(@as(i32, -2), sc.dy);
    try t.expectEqual(@as(i32, 1), (try parseT(a, "{\"cmd\":\"scroll\",\"col\":3,\"row\":3}")).scroll.dy);
    const dr = (try parseT(a, "{\"cmd\":\"drag\",\"from_col\":1,\"from_row\":3,\"col\":6,\"row\":5}")).drag;
    try t.expectEqual(@as(u16, 6), dr.col);
    try t.expectEqual(key.MouseButton.left, (try parseT(a, "{\"cmd\":\"mouse_down\",\"col\":1,\"row\":1}")).mouse_down.button);
    try t.expectEqual(@as(u16, 1), (try parseT(a, "{\"cmd\":\"mouse_move\",\"col\":1,\"row\":2}")).mouse_move.col);
    try t.expectEqual(@as(u16, 2), (try parseT(a, "{\"cmd\":\"mouse_up\",\"col\":1,\"row\":2}")).mouse_up.row);
    try t.expectEqual(@as(u64, 30), (try parseT(a, "{\"cmd\":\"wait_ms\",\"ms\":30}")).wait_ms);

    const es = (try parseT(a, "{\"cmd\":\"expect_screen\",\"text\":\"Hello\"}")).expect_screen;
    try t.expect(es.contains);
    try t.expect(!(try parseT(a, "{\"cmd\":\"expect_screen\",\"text\":\"zzz\",\"expect\":\"lacks\"}")).expect_screen.contains);
    try t.expect((try parseT(a, "{\"cmd\":\"expect_screen\",\"text\":\"x\",\"expect\":\"other\"}")).expect_screen.contains);

    try t.expectEqual(Command.snapshot, try parseT(a, "{\"cmd\":\"snapshot\"}"));
    try t.expectEqual(ToastLevel.warn, (try parseT(a, "{\"cmd\":\"toast\",\"text\":\"hi\",\"level\":\"warn\"}")).toast.level);
    try t.expectEqual(ToastLevel.@"error", (try parseT(a, "{\"cmd\":\"toast-persistent\",\"id\":\"i\",\"text\":\"x\",\"level\":\"err\"}")).toast_persistent.level);
    try t.expectEqualStrings("i", (try parseT(a, "{\"cmd\":\"toast-dismiss\",\"id\":\"i\"}")).toast_dismiss);
    try t.expectEqualStrings("Loading", (try parseT(a, "{\"cmd\":\"progress-start\",\"id\":\"p\",\"text\":\"Loading\"}")).progress_start.label);
    const pu = (try parseT(a, "{\"cmd\":\"progress-update\",\"id\":\"p\",\"count\":250}")).progress_update;
    try t.expectEqual(@as(?u8, 100), pu.percent); // clamped
    try t.expectEqual(@as(?[]const u8, null), pu.label);
    try t.expectEqual(ProgressStatus.cancelled, (try parseT(a, "{\"cmd\":\"progress-end\",\"id\":\"p\",\"text\":\"canceled\"}")).progress_end.status);
    try t.expectEqual(ProgressStatus.success, (try parseT(a, "{\"cmd\":\"progress-end\",\"id\":\"p\"}")).progress_end.status);

    const seg = (try parseT(a, "{\"cmd\":\"statusline-set-segment\",\"id\":\"s\",\"text\":\"T\",\"side\":\"LEFT\"}")).statusline_set_segment;
    try t.expectEqual(SegmentSide.left, seg.side);
    try t.expectEqual(@as(u8, 100), seg.priority);
    try t.expectEqual(@as(u16, 4), seg.min_width);
    try t.expectEqual(@as(u16, 30), seg.max_width);
    try t.expectEqual(@as(?[]const u8, null), seg.color);
    try t.expectEqualStrings("s", (try parseT(a, "{\"cmd\":\"statusline-clear-segment\",\"id\":\"s\"}")).statusline_clear_segment);
    // A segment with nothing behind it lists nothing: the line an
    // older integration sends is unchanged.
    try t.expectEqual(@as(usize, 0), seg.items.len);

    const n = (try parseT(a, "{\"cmd\":\"notify\",\"text\":\"body\"}")).notify;
    try t.expectEqualStrings("mnml", n.title);
    try t.expect(!n.sound);
    const n2 = (try parseT(a, "{\"cmd\":\"notify\",\"text\":\"b\",\"title\":\"T\",\"sound\":true,\"source\":\"jira\"}")).notify;
    try t.expect(n2.sound);
    try t.expectEqualStrings("jira", n2.source.?);

    const pty = (try parseT(a, "{\"cmd\":\"open-pty\",\"command\":[\"ls\",\"-la\"],\"cwd\":\"/tmp\"}")).open_pty;
    try t.expectEqualStrings("-la", pty.command[1]);
    try t.expectEqualStrings("/tmp", pty.cwd.?);
    // `focus-session`: the host's id when a pane has one, else the two
    // things a dispatched `term` line can actually say about a session.
    const f = (try parseT(a, "{\"cmd\":\"focus-session\",\"cwd\":\"/w\",\"prompt_line\":\"/agents:developer ENG-2\"}")).focus_session;
    try t.expectEqualStrings("/w", f.cwd.?);
    try t.expectEqualStrings("/agents:developer ENG-2", f.prompt_line.?);
    try t.expect(f.id == null);
    const fid = (try parseT(a, "{\"cmd\":\"focus-session\",\"id\":\"abc\"}")).focus_session;
    try t.expectEqualStrings("abc", fid.id.?);
    const badge = (try parseT(a, "{\"cmd\":\"set-activity-badge\",\"section\":\"agents\",\"count\":3}")).set_activity_badge;
    try t.expectEqual(@as(u32, 3), badge.count);
    try t.expectEqual(Command.dump_rects, try parseT(a, "{\"cmd\":\"dump-rects\"}"));
    try t.expectEqualStrings("x + y", (try parseT(a, "{\"cmd\":\"ghost\",\"text\":\"x + y\"}")).ghost);
    try t.expectEqual(Command.quit, try parseT(a, "{\"cmd\":\"quit\"}"));
    try t.expectEqual(Command.restart, try parseT(a, "{\"cmd\":\"restart\"}"));
}

test "malformed and incomplete lines are unknown, carrying the raw line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][]const u8{
        "not json",
        "{\"cmd\":\"nope\"}",
        "{\"path\":\"x\"}", // no cmd
        "{\"cmd\":\"open\"}", // open without path
        "{\"cmd\":\"click\",\"col\":5}", // click without row
        "{\"cmd\":\"click\",\"col\":\"5\",\"row\":3}", // wrong type
        "{\"cmd\":\"drag\",\"from_col\":1,\"col\":6,\"row\":5}",
        "{\"cmd\":\"open-pty\",\"command\":[]}",
        "{\"cmd\":\"ghost\",\"text\":\"\"}",
        "{\"cmd\":\"set-activity-badge\",\"section\":\"agents\"}",
        // Nothing to go on is not a focus.
        "{\"cmd\":\"focus-session\"}",
        "{\"cmd\":\"wait_ms\"}",
        "{\"cmd\":\"register-command\",\"keys\":[\"a\"]}",
    };
    for (cases) |line| {
        const c = try parseT(a, line);
        if (c != .unknown) {
            std.debug.print("expected unknown, got .{s} for: {s}\n", .{ @tagName(c), line });
            return error.TestUnexpectedResult;
        }
        try t.expectEqualStrings(line, c.unknown);
    }
    // Numeric strings and floats are not integers on this wire.
    try t.expect((try parseT(a, "{\"cmd\":\"wait_ms\",\"ms\":\"30\"}")) == .unknown);
    try t.expect((try parseT(a, "{\"cmd\":\"wait_ms\",\"ms\":30.0}")) == .unknown);
    try t.expect((try parseT(a, "{\"cmd\":\"click\",\"col\":-1,\"row\":3}")) == .unknown);
}

test "unknown JSON fields are ignored rather than rejected" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const c = try parseT(arena_state.allocator(), "{\"cmd\":\"quit\",\"future_field\":1}");
    try t.expectEqual(Command.quit, c);
}

test "parseMods and mouseButton accept the documented spellings" {
    const m = parseMods("Control,option, SHIFT,cmd,bogus");
    try t.expect(m.ctrl and m.alt and m.shift and m.super);
    try t.expect(!parseMods(null).ctrl);
    try t.expectEqual(key.MouseButton.right, mouseButton("R"));
    try t.expectEqual(key.MouseButton.left, mouseButton(null));
}

test "a segment's items: kept in order, a row with no text skipped, the wire capped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line =
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"s\",\"text\":\"T\",\"items\":[" ++
        "{\"text\":\"Fix the login redirect\",\"sub\":\"acme/api\",\"command\":\"bb.open\",\"args\":[\"--focus\",\"acme/api#1\"]}," ++
        "{\"sub\":\"no text at all\"}," ++
        "{\"text\":\"\"}," ++
        "{\"text\":\"Bump the client timeout\"}]}";
    const seg = (try parseT(a, line)).statusline_set_segment;
    try t.expectEqual(@as(usize, 2), seg.items.len);
    try t.expectEqualStrings("Fix the login redirect", seg.items[0].text);
    try t.expectEqualStrings("acme/api", seg.items[0].sub);
    try t.expectEqualStrings("bb.open", seg.items[0].command.?);
    try t.expectEqualStrings("--focus", seg.items[0].args[0]);
    // A row that only said where it lives is dropped, not the line.
    try t.expectEqualStrings("Bump the client timeout", seg.items[1].text);
    try t.expectEqualStrings("", seg.items[1].sub);
    try t.expect(seg.items[1].command == null);

    // Far more than the wire keeps: the first `max_segment_items` land
    // and the rest go, rather than a publisher sizing the host's heap.
    var many: std.Io.Writer.Allocating = .init(a);
    try many.writer.writeAll("{\"cmd\":\"statusline-set-segment\",\"id\":\"s\",\"text\":\"T\",\"items\":[");
    for (0..max_segment_items + 10) |i| try many.writer.print("{s}{{\"text\":\"row {d}\"}}", .{ if (i == 0) "" else ",", i });
    try many.writer.writeAll("]}");
    const big = (try parseT(a, many.written())).statusline_set_segment;
    try t.expectEqual(max_segment_items, big.items.len);
    try t.expectEqualStrings("row 0", big.items[0].text);

    // A malformed `items` (not an array of objects) fails the line the
    // way any wrong-typed field does — `.unknown`, never a crash.
    try t.expect((try parseT(a, "{\"cmd\":\"statusline-set-segment\",\"id\":\"s\",\"text\":\"T\",\"items\":\"nope\"}")) == .unknown);
}
