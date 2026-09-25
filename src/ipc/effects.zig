//! The tier-2 IPC app effects — what a host's `statusline-set-segment`,
//! `statusline-clear-segment`, `set-activity-badge`, `open-pty` and
//! `notify` do once parsed (`command.zig`). The shapes are the Rust
//! host's: a segment is keyed by id and replaced in place; a badge of
//! zero removes its key; `notify` is always an in-app toast (`error`
//! pins to the persistent slot under the source's id) and, in the
//! terminal loop only, a native banner through `osascript` /
//! `notify-send` / PowerShell.
//!
//!   D1  every string a segment or badge holds is gpa-owned by `State`;
//!       `pack` hands the frame a view onto them;
//!   D6  the statusline paints `pack`'s result and registers one
//!       `.statusline_seg = seg_dyn_base + index` hit per segment, the
//!       index being the segment's slot in `State.segments`, so a click
//!       finds its `click_command` without frame-owned state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");
const ipc_command = @import("command.zig");
const sessions_table = @import("../app/sessions_table.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const pty_pane = @import("../app/pty_pane.zig");
const keymap = @import("../core/keymap.zig");
const key_mod = @import("../core/key.zig");

pub const Side = ipc_command.SegmentSide;
pub const Level = ipc_command.ToastLevel;

pub const Segment = struct {
    id: []u8,
    side: Side,
    text: []u8,
    /// A palette name (`cyan`) or `#rrggbb`; the muted colour when null.
    color: ?[]u8,
    /// A command id run on a left click; null paints a passive chip.
    click_command: ?[]u8,
    priority: u8,
    min_width: u16,
    max_width: u16,
    /// The hover text the publisher sent: what this number counts, and
    /// its breakdown. Null falls back to the generic line.
    tooltip: ?[]u8,
    /// The things behind the figure, in the publisher's order — the
    /// hover lists them. Empty leaves the one-line hover.
    items: []Item,

    fn deinit(self: *Segment, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.text);
        if (self.color) |c| gpa.free(c);
        if (self.click_command) |c| gpa.free(c);
        if (self.tooltip) |c| gpa.free(c);
        for (self.items) |*it| it.deinit(gpa);
        gpa.free(self.items);
    }
};

/// One of the things a figure counts: a pull request, a ticket, a
/// pipeline. `text` is what it is, `sub` where it lives or how old it
/// is, `command` what a click on the row runs.
pub const Item = struct {
    text: []u8,
    sub: []u8,
    command: ?[]u8,
    args: [][]u8,

    fn deinit(self: *Item, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.sub);
        if (self.command) |c| gpa.free(c);
        for (self.args) |a| gpa.free(a);
        gpa.free(self.args);
    }
};

/// The activity sections a badge can name, as Rust's `badge_key`
/// spells them. Any other section is stored too — an integration's
/// mount id is its own section — but these are the ones the chrome
/// paints somewhere.
// // changed (sessions-merge): `agents` / `cloud_agents` left with their rail rows.
pub const known_sections = [_][]const u8{ "explorer", "search", "git", "debug", "integrations", "sessions", "http", "notes", "todos", "findings", "scripts" };

pub const State = struct {
    segments: std.ArrayListUnmanaged(Segment) = .empty,
    /// Section → count; a count of zero removes the key.
    badges: std.StringArrayHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (self.segments.items) |*s| s.deinit(gpa);
        self.segments.deinit(gpa);
        for (self.badges.keys()) |k| gpa.free(k);
        self.badges.deinit(gpa);
    }

    /// Set or replace the segment `id`. The slot index is stable while
    /// the segment lives, so a hit registered against it stays right.
    pub fn setSegment(self: *State, gpa: Allocator, s: SegmentSpec) Allocator.Error!void {
        var fresh: Segment = .{
            .id = try gpa.dupe(u8, s.id),
            .side = s.side,
            .text = undefined,
            .color = null,
            .click_command = null,
            .priority = s.priority,
            .min_width = s.min_width,
            .max_width = s.max_width,
            .tooltip = null,
            .items = &.{},
        };
        errdefer fresh.deinit(gpa);
        fresh.text = try gpa.dupe(u8, s.text);
        if (s.color) |c| fresh.color = try gpa.dupe(u8, c);
        if (s.click_command) |c| fresh.click_command = try gpa.dupe(u8, c);
        if (s.tooltip) |c| fresh.tooltip = try gpa.dupe(u8, c);
        fresh.items = try dupeItems(gpa, s.items);
        if (self.find(s.id)) |i| {
            self.segments.items[i].deinit(gpa);
            self.segments.items[i] = fresh;
        } else {
            try self.segments.append(gpa, fresh);
        }
    }

    pub fn clearSegment(self: *State, gpa: Allocator, id: []const u8) bool {
        const i = self.find(id) orelse return false;
        var s = self.segments.orderedRemove(i);
        s.deinit(gpa);
        return true;
    }

    pub fn find(self: *const State, id: []const u8) ?usize {
        for (self.segments.items, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return i;
        return null;
    }

    pub fn setBadge(self: *State, gpa: Allocator, section: []const u8, count: u32) Allocator.Error!void {
        if (count == 0) {
            if (self.badges.fetchSwapRemove(section)) |kv| gpa.free(kv.key);
            return;
        }
        if (self.badges.getPtr(section)) |p| {
            p.* = count;
            return;
        }
        const key = try gpa.dupe(u8, section);
        errdefer gpa.free(key);
        try self.badges.put(gpa, key, count);
    }

    /// Zero when no badge is set.
    pub fn badge(self: *const State, section: []const u8) u32 {
        return self.badges.get(section) orelse 0;
    }

    /// Every badge but `except` (the chrome that paints its own count
    /// for a section passes that section here).
    pub fn badgeTotal(self: *const State, except: ?[]const u8) u32 {
        var n: u32 = 0;
        var it = self.badges.iterator();
        while (it.next()) |kv| {
            if (except) |e| if (std.mem.eql(u8, kv.key_ptr.*, e)) continue;
            n +|= kv.value_ptr.*;
        }
        return n;
    }
};

pub const SegmentSpec = struct {
    id: []const u8,
    side: Side = .right,
    text: []const u8,
    color: ?[]const u8 = null,
    click_command: ?[]const u8 = null,
    priority: u8 = 100,
    min_width: u16 = 4,
    max_width: u16 = 30,
    /// The hover text: what the number counts, and its breakdown.
    tooltip: ?[]const u8 = null,
    /// The things behind the figure, for the hover to list.
    items: []const ipc_command.SegmentItem = &.{},
};

/// The rows, gpa-owned. Partway through, every row already taken is
/// freed — a half-built list must not reach a `Segment`.
fn dupeItems(gpa: Allocator, src: []const ipc_command.SegmentItem) Allocator.Error![]Item {
    if (src.len == 0) return &.{};
    var out = try gpa.alloc(Item, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |*it| it.deinit(gpa);
        gpa.free(out);
    }
    while (n < src.len) : (n += 1) {
        const it = src[n];
        out[n] = .{ .text = undefined, .sub = undefined, .command = null, .args = &.{} };
        out[n].text = try gpa.dupe(u8, it.text);
        errdefer gpa.free(out[n].text);
        out[n].sub = try gpa.dupe(u8, it.sub);
        errdefer gpa.free(out[n].sub);
        if (it.command) |c| out[n].command = try gpa.dupe(u8, c);
        errdefer if (out[n].command) |c| gpa.free(c);
        const args = try gpa.alloc([]u8, it.args.len);
        var m: usize = 0;
        errdefer {
            for (args[0..m]) |a| gpa.free(a);
            gpa.free(args);
        }
        while (m < it.args.len) : (m += 1) args[m] = try gpa.dupe(u8, it.args[m]);
        out[n].args = args;
    }
    return out;
}

/// One segment as the statusline paints it. `text` is on the frame
/// arena when it was truncated, else a view into `State`.
pub const Rendered = struct {
    /// The slot in `State.segments` — the hit id's payload.
    index: u32,
    /// The segment's own id, borrowed. `<integration>.<segment>` for a
    /// manifest's chip, which is how the poller finds the one it is
    /// refreshing.
    id: []const u8,
    text: []const u8,
    color: ?[]const u8,
    clickable: bool,
};

pub const ellipsis_unicode = "…";
pub const ellipsis_ascii = "...";

/// The hybrid pack Rust's statusline does: by priority (high first,
/// ties in registration order), each segment takes the smaller of
/// its natural width and `max_width` while the budget allows, is
/// truncated to what is left when that is at least `min_width` (or
/// its whole natural width, when shorter), and is dropped otherwise.
/// Widths are in codepoints; the terminal's columns are close enough
/// for a chip.
pub fn pack(arena: Allocator, segments: []const Segment, side: Side, budget: usize, ascii: bool) Allocator.Error![]Rendered {
    var order: std.ArrayListUnmanaged(u32) = .empty;
    for (segments, 0..) |s, i| if (s.side == side) try order.append(arena, @intCast(i));
    const Ctx = struct {
        segs: []const Segment,
        fn lt(ctx: @This(), a: u32, b: u32) bool {
            const pa = ctx.segs[a].priority;
            const pb = ctx.segs[b].priority;
            if (pa != pb) return pa > pb;
            return a < b;
        }
    };
    std.mem.sort(u32, order.items, Ctx{ .segs = segments }, Ctx.lt);
    var out: std.ArrayListUnmanaged(Rendered) = .empty;
    var left = budget;
    for (order.items) |i| {
        const s = segments[i];
        const natural = std.unicode.utf8CountCodepoints(s.text) catch s.text.len;
        // Two cells of padding are the chip's own (` text `).
        const desired = @min(natural, @as(usize, s.max_width));
        const need = @min(natural, @as(usize, s.min_width));
        if (left < need + 2) continue;
        const take = @min(desired, left - 2);
        const text: []const u8 = if (take >= natural) s.text else try truncate(arena, s.text, take, ascii);
        try out.append(arena, .{ .index = i, .id = s.id, .text = text, .color = s.color, .clickable = s.click_command != null });
        left -= take + 2;
    }
    return out.toOwnedSlice(arena);
}

/// The first `width` codepoints with the ellipsis in the last slot.
fn truncate(arena: Allocator, text: []const u8, width: usize, ascii: bool) Allocator.Error![]const u8 {
    const ell: []const u8 = if (ascii) ellipsis_ascii else ellipsis_unicode;
    const ell_w: usize = if (ascii) 3 else 1;
    if (width <= ell_w) return ell[0..@min(ell.len, width)];
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var kept: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (kept + ell_w >= width) break;
        end += cp.len;
        kept += 1;
    }
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..end], ell });
}

// ─── notify ─────────────────────────────────────────────────────────────

pub const Os = enum { macos, linux, windows, other };

pub fn hostOs() Os {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .other,
    };
}

/// The native notifier's argv for `os`: `osascript -e 'display
/// notification …'`, `notify-send -u <urgency> title body`, or a
/// PowerShell toast through the WinRT `ToastNotificationManager`.
/// Null when the platform has none — the toast already fired.
pub fn nativeArgv(arena: Allocator, os: Os, title: []const u8, body: []const u8, level: Level, sound: bool) Allocator.Error!?[]const []const u8 {
    switch (os) {
        .macos => {
            const script = try std.fmt.allocPrint(arena, "display notification \"{s}\" with title \"{s}\"{s}", .{
                try appleEscape(arena, body),
                try appleEscape(arena, title),
                if (sound) " sound name \"default\"" else "",
            });
            const argv = try arena.alloc([]const u8, 3);
            argv[0] = "osascript";
            argv[1] = "-e";
            argv[2] = script;
            return argv;
        },
        .linux => {
            const argv = try arena.alloc([]const u8, 5);
            argv[0] = "notify-send";
            argv[1] = "-u";
            argv[2] = switch (level) {
                .info => "normal",
                .warn => "normal",
                .@"error" => "critical",
            };
            argv[3] = title;
            argv[4] = body;
            return argv;
        },
        .windows => {
            const script = try std.fmt.allocPrint(arena,
                \\[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); $n = $t.GetElementsByTagName('text'); $n.Item(0).AppendChild($t.CreateTextNode('{s}')) > $null; $n.Item(1).AppendChild($t.CreateTextNode('{s}')) > $null; {s}[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('mnml').Show([Windows.UI.Notifications.ToastNotification]::new($t))
            , .{ try psEscape(arena, title), try psEscape(arena, body), if (sound) "" else "$t.SelectSingleNode('/toast').SetAttribute('duration', 'short'); $a = $t.CreateElement('audio'); $a.SetAttribute('silent', 'true') > $null; $t.SelectSingleNode('/toast').AppendChild($a) > $null; " });
            const argv = try arena.alloc([]const u8, 4);
            argv[0] = "powershell";
            argv[1] = "-NoProfile";
            argv[2] = "-Command";
            argv[3] = script;
            return argv;
        },
        .other => return null,
    }
}

/// AppleScript string escaping: `\` and `"`.
fn appleEscape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\\' or c == '"') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// PowerShell single-quoted string escaping: `'` doubles.
fn psEscape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\'') try out.append(arena, '\'');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// Run the notifier on a detached thread; the argv is copied so the
/// caller's arena may go. A missing binary is silent — the toast is
/// the guaranteed half.
fn spawnNative(gpa: Allocator, io: Io, argv: []const []const u8) void {
    const copy = dupeArgv(gpa, argv) catch return;
    const th = std.Thread.spawn(.{}, nativeThread, .{ gpa, io, copy }) catch {
        freeArgv(gpa, copy);
        return;
    };
    th.detach();
}

fn nativeThread(gpa: Allocator, io: Io, argv: []const []const u8) void {
    defer freeArgv(gpa, argv);
    const result = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn dupeArgv(gpa: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, argv.len);
    var n: usize = 0;
    errdefer freeArgv(gpa, out[0..n]);
    for (argv) |a| {
        out[n] = try gpa.dupe(u8, a);
        n += 1;
    }
    return out;
}

fn freeArgv(gpa: Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

// ─── apply ──────────────────────────────────────────────────────────────

pub const Notify = struct {
    title: []const u8,
    body: []const u8,
    level: Level = .info,
    sound: bool = false,
    source: ?[]const u8 = null,
    /// The in-app toast. A caller that has toasted already (a session's
    /// edge) says no.
    toast: bool = true,
    /// Through the terminal mnml runs in rather than a spawned notifier:
    /// OSC 777 / OSC 9 (`terminalEscapes`), then the bell under `sound`,
    /// out through `App.hostWrite`. The terminal owns the notification —
    /// it knows whether its window is in front, and it clicks back to
    /// the right tab.
    terminal: bool = false,
};

/// Which desktop-notification escape a terminal reads: OSC 777
/// (`ESC ] 777 ; notify ; title ; body BEL`) for ghostty and WezTerm,
/// OSC 9 (`ESC ] 9 ; text BEL`) for iTerm2, both where `$TERM_PROGRAM`
/// says nothing we know — a terminal ignores the OSC it does not speak,
/// and one that speaks both would show the same notification twice.
pub const TermNotify = enum { osc777, osc9, both };

pub fn termNotifyFor(term_program: ?[]const u8) TermNotify {
    const tp = term_program orelse return .both;
    if (std.ascii.eqlIgnoreCase(tp, "ghostty") or std.ascii.eqlIgnoreCase(tp, "WezTerm")) return .osc777;
    if (std.ascii.eqlIgnoreCase(tp, "iTerm.app")) return .osc9;
    return .both;
}

/// A field's text as an OSC can carry it: a control byte would end or
/// corrupt the sequence and becomes a space; `;` would end the field in
/// OSC 777 and becomes `,`; cut at `max` bytes on a UTF-8 boundary.
pub fn oscText(arena: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    const out = try arena.alloc(u8, end);
    for (s[0..end], out) |c, *o| o.* = if (c < 0x20 or c == 0x7f) ' ' else if (c == ';') ',' else c;
    return out;
}

/// The notification escapes for `kind`, on `arena`, in the order they
/// are written.
pub fn terminalEscapes(arena: Allocator, kind: TermNotify, title: []const u8, body: []const u8) Allocator.Error![]const []const u8 {
    const head = try oscText(arena, title, 120);
    const text = try oscText(arena, body, 240);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (kind != .osc9) try out.append(arena, try std.fmt.allocPrint(arena, "\x1b]777;notify;{s};{s}\x07", .{ head, text }));
    if (kind != .osc777) try out.append(arena, try std.fmt.allocPrint(arena, "\x1b]9;{s}: {s}\x07", .{ head, text }));
    return out.items;
}

/// The in-app half unless the caller has toasted already; then the
/// terminal's escapes (`terminal`), or the native half when
/// `app.native_notify` (the terminal loop sets it — headless and the
/// tests never spawn).
pub fn notify(app: *App, n: Notify) Allocator.Error!void {
    if (n.toast) {
        if (n.level == .@"error") {
            const id = n.source orelse try std.fmt.allocPrint(app.frame.allocator(), "notify:{s}", .{n.title});
            const text = try std.fmt.allocPrint(app.frame.allocator(), "{s}: {s}", .{ n.title, n.body });
            try app.toastPersistent(id, text, .err);
        } else {
            try app.toastLevel(switch (n.level) {
                .info => .info,
                .warn => .warn,
                .@"error" => .err,
            }, "{s}: {s}", .{ n.title, n.body });
        }
    }
    if (n.terminal) {
        const arena = app.frame.allocator();
        for (try terminalEscapes(arena, termNotifyFor(app.env.get("TERM_PROGRAM")), n.title, n.body)) |e| try app.hostWrite(e);
        if (n.sound) try app.hostWrite("\x07");
        return;
    }
    if (!app.native_notify) return;
    const argv = try nativeArgv(app.frame.allocator(), hostOs(), n.title, n.body, n.level, n.sound) orelse return;
    spawnNative(app.gpa, app.io, argv);
}

pub const OpenPty = struct { cwd: ?[]const u8, command: []const []const u8 };

/// `open-pty`: `command[0]` in a pane below, labelled by its basename,
/// at `cwd` (the workspace when absent). Unsupported platforms toast.
pub fn openPty(app: *App, p: OpenPty) Allocator.Error!void {
    if (p.command.len == 0) return;
    const label = std.fs.path.basename(p.command[0]);
    _ = pty_pane.open(app, .{ .argv = p.command, .cwd = p.cwd, .label = label, .placement = .below, .kind = .command }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("open-pty: {s}", .{m}) else app.toast("open-pty: {s}", .{@errorName(err)});
            app.diag.clear();
        },
    };
}

/// Whether a command drives INPUT — a key, a click, typing. These are
/// the headless driver's, and at a live terminal they are refused
/// unless `ipc.allow_input` says otherwise: a file on disk typing into
/// someone's editor is a different kind of power from a file moving a
/// number on their statusline.
pub fn isInput(cmd: *const ipc_command.Command) bool {
    return switch (cmd.*) {
        .key, .type, .click, .hover, .scroll, .drag, .mouse_down, .mouse_move, .mouse_up => true,
        // The driver verbs that act as the person would: opening a file,
        // seeding a suggestion, running an ex line.
        .open, .ghost, .ex => true,
        else => false,
    };
}

/// A key spec as a host writes it — one chord (`ctrl+p`), a whitespace
/// chain (`ctrl+w h`), or a run of single chars (`gg`, `2j`) when the
/// whole thing is not a chord and could plausibly be a vim chain. Three
/// or more letters with no modifier (`hom`, `esx`) read as a misspelled
/// named key and stay unparsed rather than typing wrong keystrokes.
/// Null unless every token parses: half a chain is not dispatched.
///
/// The headless loop and the terminal loop both read a `key` line
/// through this, so a spec cannot mean one thing to the driver an agent
/// tests with and another to the window a person looks at.
pub fn keySpecKeys(arena: Allocator, spec: []const u8) Allocator.Error!?[]const key_mod.Key {
    const chars = std.unicode.utf8CountCodepoints(spec) catch spec.len;
    const has_ws = std.mem.indexOfAny(u8, spec, " \t\r\n") != null;
    var all_alpha = true;
    for (spec) |c| if (!std.ascii.isAlphabetic(c)) {
        all_alpha = false;
        break;
    };
    const looks_like_typo = chars >= 3 and all_alpha;
    const per_char = !has_ws and std.mem.indexOfScalar(u8, spec, '+') == null and keymap.parseKeySpec(spec) == null and chars >= 2 and !looks_like_typo;

    var keys: std.ArrayList(key_mod.Key) = .empty;
    if (per_char) {
        var it = (std.unicode.Utf8View.init(spec) catch return null).iterator();
        while (it.nextCodepointSlice()) |g| {
            try keys.append(arena, keymap.parseKeySpec(g) orelse return null);
        }
    } else {
        var it = std.mem.tokenizeAny(u8, spec, " \t\r\n");
        while (it.next()) |tok| try keys.append(arena, keymap.parseKeySpec(tok) orelse return null);
    }
    if (keys.items.len == 0) return null;
    return keys.items;
}

/// The INPUT set at a live terminal — `key`, `type`, `click`, `hover`,
/// `scroll`, `drag`, `mouse_*` — plus `open`, `ghost` and `ex`, the
/// driver verbs a script leans on. The terminal loop only posts these
/// when `ipc.allow_input` is on (`tui/loop.zig`); here they become the
/// same `App.handle` events a keyboard and a mouse produce, so a host
/// driving the real window through the channel sees what a person
/// would, without the window ever taking the keyboard.
///
/// It used to be missing: the loop acknowledged the line `accepted`
/// and the App's `.ipc` arm, which only knew the tier-2 set, answered
/// "not in this build". The ack was true and nothing moved.
///
/// False for a command this is not.
pub fn applyInput(app: *App, arena: Allocator, cmd: *const ipc_command.Command) Allocator.Error!bool {
    switch (cmd.*) {
        .key => |spec| {
            const keys = try keySpecKeys(arena, spec) orelse {
                app.toast("ipc key: cannot read `{s}`", .{spec});
                return true;
            };
            for (keys) |k| try app.handle(.{ .key = k });
        },
        .type => |text| {
            var it = (std.unicode.Utf8View.init(text) catch return true).iterator();
            while (it.nextCodepoint()) |c| {
                try app.handle(.{ .key = if (c == '\n') key_mod.Key.named(.enter) else key_mod.Key.char(c) });
            }
        },
        .click => |c| {
            try app.handle(.{ .mouse = .{ .x = c.col, .y = c.row, .kind = .press, .button = c.button, .mods = c.mods } });
            try app.handle(.{ .mouse = .{ .x = c.col, .y = c.row, .kind = .release, .button = c.button, .mods = c.mods } });
        },
        .hover => |h| try app.handle(.{ .mouse = .{ .x = h.col, .y = h.row, .kind = .motion } }),
        .mouse_down => |m| {
            app.ipc_button_held = true;
            try app.handle(.{ .mouse = .{ .x = m.col, .y = m.row, .kind = .press, .button = m.button, .mods = m.mods } });
        },
        .mouse_move => |m| try app.handle(.{ .mouse = .{
            .x = m.col,
            .y = m.row,
            .kind = if (app.ipc_button_held) .drag else .motion,
            .button = if (app.ipc_button_held) .left else .none,
        } }),
        .mouse_up => |m| {
            app.ipc_button_held = false;
            try app.handle(.{ .mouse = .{ .x = m.col, .y = m.row, .kind = .release, .button = m.button, .mods = m.mods } });
        },
        .drag => |g| {
            try app.handle(.{ .mouse = .{ .x = g.from_col, .y = g.from_row, .kind = .press, .button = .left } });
            const dx = if (g.col > g.from_col) g.col - g.from_col else g.from_col - g.col;
            const dy = if (g.row > g.from_row) g.row - g.from_row else g.from_row - g.row;
            const steps: u16 = @max(dx, dy);
            var s: u16 = 1;
            while (s <= steps) : (s += 1) {
                const f: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
                try app.handle(.{ .mouse = .{ .x = lerpCell(g.from_col, g.col, f), .y = lerpCell(g.from_row, g.row, f), .kind = .drag, .button = .left } });
            }
            try app.handle(.{ .mouse = .{ .x = g.col, .y = g.row, .kind = .release, .button = .left } });
        },
        .scroll => |sc| {
            // One deliberate notch per `dy`, each landed before the next,
            // as the headless loop applies them.
            const kind: key_mod.MouseKind = if (sc.dy >= 0) .scroll_up else .scroll_down;
            var n: u32 = @abs(sc.dy);
            while (n > 0) : (n -= 1) {
                app.accel.endGesture();
                try app.handle(.{ .mouse = .{ .x = sc.col, .y = sc.row, .kind = kind } });
                try app.flushWheel();
            }
        },
        .open => |p| {
            const path = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ app.workspace, p });
            _ = app.openPath(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => app.toast("open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
            };
        },
        .ghost => |text| {
            const e = app.activeEditor() orelse {
                app.toast("ipc ghost: the active pane is not an editor", .{});
                return true;
            };
            try e.buf.editor.setGhostSuggestion(text);
        },
        .ex => |line| try @import("../app/dispatch.zig").runExLine(app, line),
        else => return false,
    }
    app.needs_render = true;
    return true;
}

fn lerpCell(from: u16, to: u16, f: f32) u16 {
    const a: f32 = @floatFromInt(from);
    const b: f32 = @floatFromInt(to);
    return @intFromFloat(@round(a + (b - a) * f));
}

/// The whole tier-2 set an integration is promised: the toast family,
/// progress, `register-command`, `run-command`, and the segment / badge
/// / notify / pty family `apply` owns. One dispatcher — the headless
/// driver and the terminal loop both come through here, so a command
/// cannot work in a `.test` and be refused in the real app, which is
/// exactly what used to happen.
///
/// False for a command this is not: the input set (`isInput`), `open`,
/// and the script-runner verbs the headless driver keeps to itself.
pub fn applyTier2(app: *App, cmd: *const ipc_command.Command) Allocator.Error!bool {
    switch (cmd.*) {
        .toast => |tst| try app.toastLevel(toastLevel(tst.level), "{s}", .{tst.text}),
        .toast_persistent => |tst| try app.toastPersistent(tst.id, tst.text, toastLevel(tst.level)),
        .toast_dismiss => |id| app.dismissToast(id),
        .register_command => |r| {
            _ = app.dyn_commands.register(.{ .id = r.id, .title = r.title, .group = r.group, .keys = r.keys, .owner = .ipc }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ShadowsBuiltin => {
                    app.toast("register-command: {s} shadows a built-in", .{r.id});
                    return true;
                },
            };
            for (r.keys) |k| try app.keymap.bindNow(k, r.id);
        },
        .run_command => |id| {
            const cmd_mod = @import("../core/command.zig");
            const ref = cmd_mod.resolve(app, id) orelse {
                app.toast("run-command: no such command `{s}`", .{id});
                return true;
            };
            cmd_mod.run(app, ref) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .progress_start => |pr| try app.toastPersistent(pr.id, pr.label, .info),
        .progress_update => |pr| if (pr.label) |label| try app.toastPersistent(pr.id, label, .info),
        .progress_end => |pr| app.dismissToast(pr.id),
        else => return apply(app, cmd),
    }
    app.needs_render = true;
    return true;
}

fn toastLevel(l: ipc_command.ToastLevel) @import("../app.zig").ToastLevel {
    return switch (l) {
        .info => .info,
        .warn => .warn,
        .@"error" => .err,
    };
}

/// Every tier-2 effect; the driver routes the toast family itself.
/// Returns false for a command this module does not own.
pub fn apply(app: *App, cmd: *const ipc_command.Command) Allocator.Error!bool {
    switch (cmd.*) {
        .statusline_set_segment => |s| try app.ipc_fx.setSegment(app.gpa, .{
            .id = s.id,
            .side = s.side,
            .text = s.text,
            .color = s.color,
            .click_command = s.click_command,
            .priority = s.priority,
            .min_width = s.min_width,
            .max_width = s.max_width,
            .tooltip = s.tooltip,
            .items = s.items,
        }),
        .statusline_clear_segment => |id| _ = app.ipc_fx.clearSegment(app.gpa, id),
        .set_activity_badge => |b| try app.ipc_fx.setBadge(app.gpa, b.section, b.count),
        .notify => |n| try notify(app, .{ .title = n.title, .body = n.body, .level = n.level, .sound = n.sound, .source = n.source }),
        .open_pty => |p| try openPty(app, .{ .cwd = p.cwd, .command = p.command }),
        .focus_session => |f| _ = sessions_table.focusSession(app, .{
            .id = f.id,
            .cwd = f.cwd,
            .prompt_line = f.prompt_line,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A click on a packed segment: its `click_command`, when it has one.
pub fn clickSegment(app: *App, index: u32) Allocator.Error!void {
    if (index >= app.ipc_fx.segments.items.len) return;
    const id = app.ipc_fx.segments.items[index].click_command orelse return;
    const command = @import("../core/command.zig");
    command.runNamed(app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}: {s}", .{ id, @errorName(err) });
            app.diag.clear();
        },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "segments: set replaces in place, clear removes, badges drop at zero" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    try st.setSegment(t.allocator, .{ .id = "a", .text = "one" });
    try st.setSegment(t.allocator, .{ .id = "b", .text = "two", .side = .left, .color = "red", .click_command = "file.save", .priority = 200 });
    try st.setSegment(t.allocator, .{ .id = "a", .text = "uno", .max_width = 5 });
    try t.expectEqual(@as(usize, 2), st.segments.items.len);
    try t.expectEqual(@as(?usize, 0), st.find("a"));
    try t.expectEqualStrings("uno", st.segments.items[0].text);
    try t.expectEqual(@as(u16, 5), st.segments.items[0].max_width);
    try t.expectEqualStrings("red", st.segments.items[1].color.?);
    try t.expectEqualStrings("file.save", st.segments.items[1].click_command.?);
    // The rows are copied, not borrowed: the publisher's arena is gone
    // by the time a hover paints them.
    {
        var text = [_]u8{ 'P', 'R', ' ', '1' };
        var sub = [_]u8{ 'a', 'p', 'i' };
        var arg = [_]u8{'x'};
        var args = [_][]const u8{&arg};
        try st.setSegment(t.allocator, .{ .id = "a", .text = "uno", .items = &.{
            .{ .text = &text, .sub = &sub, .command = "bb.open", .args = &args },
        } });
        text[0] = '!';
        sub[0] = '!';
        arg[0] = '!';
        try t.expectEqual(@as(usize, 1), st.segments.items[0].items.len);
        try t.expectEqualStrings("PR 1", st.segments.items[0].items[0].text);
        try t.expectEqualStrings("api", st.segments.items[0].items[0].sub);
        try t.expectEqualStrings("bb.open", st.segments.items[0].items[0].command.?);
        try t.expectEqualStrings("x", st.segments.items[0].items[0].args[0]);
        // A later set with no rows drops the old ones rather than
        // leaving a figure's hover listing last week's pull requests.
        try st.setSegment(t.allocator, .{ .id = "a", .text = "uno", .max_width = 5 });
        try t.expectEqual(@as(usize, 0), st.segments.items[0].items.len);
    }
    try t.expect(st.clearSegment(t.allocator, "a"));
    try t.expect(!st.clearSegment(t.allocator, "a"));
    try t.expectEqualStrings("b", st.segments.items[0].id);

    for (known_sections) |s| try st.setBadge(t.allocator, s, 3);
    try t.expectEqual(@as(usize, known_sections.len), st.badges.count());
    try t.expectEqual(@as(u32, 3), st.badge("sessions"));
    try t.expectEqual(@as(u32, 3 * (known_sections.len - 1)), st.badgeTotal("git"));
    try st.setBadge(t.allocator, "git", 7);
    try t.expectEqual(@as(u32, 7), st.badge("git"));
    try st.setBadge(t.allocator, "git", 0);
    try t.expectEqual(@as(u32, 0), st.badge("git"));
    try t.expectEqual(@as(usize, known_sections.len - 1), st.badges.count());
    try st.setBadge(t.allocator, "my-mount", 1);
    try t.expectEqual(@as(u32, 1), st.badge("my-mount"));
}

test "pack: priority order, max_width truncation, min_width drop" {
    var st: State = .{};
    defer st.deinit(t.allocator);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try st.setSegment(t.allocator, .{ .id = "nice", .text = "nice to have", .priority = 50 });
    try st.setSegment(t.allocator, .{ .id = "must", .text = "always shown", .priority = 200, .max_width = 6 });
    try st.setSegment(t.allocator, .{ .id = "norm", .text = "normal", .min_width = 4 });
    try st.setSegment(t.allocator, .{ .id = "lefty", .text = "L", .side = .left, .click_command = "app.quit" });
    // Plenty of room: 200, 100, 50 — `must` truncated to its max_width.
    const wide = try pack(a, st.segments.items, .right, 100, false);
    try t.expectEqual(@as(usize, 3), wide.len);
    try t.expectEqual(@as(u32, 1), wide[0].index);
    try t.expectEqualStrings("alway…", wide[0].text);
    try t.expectEqualStrings("normal", wide[1].text);
    try t.expectEqualStrings("nice to have", wide[2].text);
    try t.expect(!wide[0].clickable);
    // 8 + 8 cells: `must` (6+2), `normal` (6+2); nothing left for `nice`.
    const tight = try pack(a, st.segments.items, .right, 16, false);
    try t.expectEqual(@as(usize, 2), tight.len);
    try t.expectEqualStrings("normal", tight[1].text);
    // 8 + 6: `normal` truncated to 4 (its min_width) with the ellipsis.
    const tighter = try pack(a, st.segments.items, .right, 14, false);
    try t.expectEqual(@as(usize, 2), tighter.len);
    try t.expectEqualStrings("nor…", tighter[1].text);
    // Under `--ascii` the ellipsis is three dots.
    const asc = try pack(a, st.segments.items, .right, 14, true);
    try t.expectEqualStrings("n...", asc[1].text);
    // Below min_width + padding it is dropped, and the room goes to the next.
    const drop = try pack(a, st.segments.items, .right, 12, false);
    try t.expectEqual(@as(usize, 1), drop.len);
    // The left side is its own lane.
    const l = try pack(a, st.segments.items, .left, 100, false);
    try t.expectEqual(@as(usize, 1), l.len);
    try t.expectEqual(@as(u32, 3), l[0].index);
    try t.expect(l[0].clickable);
}

test "nativeArgv: osascript / notify-send / powershell shapes; other has none" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mac = (try nativeArgv(a, .macos, "Ti\"tle", "bo\\dy", .info, true)).?;
    try t.expectEqualStrings("osascript", mac[0]);
    try t.expectEqualStrings("display notification \"bo\\\\dy\" with title \"Ti\\\"tle\" sound name \"default\"", mac[2]);
    const mac_quiet = (try nativeArgv(a, .macos, "T", "B", .info, false)).?;
    try t.expect(std.mem.indexOf(u8, mac_quiet[2], "sound") == null);
    const lin = (try nativeArgv(a, .linux, "T", "B", .@"error", false)).?;
    try t.expectEqualStrings("notify-send", lin[0]);
    try t.expectEqualStrings("critical", lin[2]);
    try t.expectEqualStrings("T", lin[3]);
    try t.expectEqualStrings("B", lin[4]);
    try t.expectEqualStrings("normal", (try nativeArgv(a, .linux, "T", "B", .warn, false)).?[2]);
    const win = (try nativeArgv(a, .windows, "It's", "B", .info, false)).?;
    try t.expectEqualStrings("powershell", win[0]);
    try t.expect(std.mem.indexOf(u8, win[3], "'It''s'") != null);
    try t.expect(std.mem.indexOf(u8, win[3], "silent") != null);
    try t.expect(std.mem.indexOf(u8, (try nativeArgv(a, .windows, "T", "B", .info, true)).?[3], "silent") == null);
    try t.expectEqual(@as(?[]const []const u8, null), try nativeArgv(a, .other, "T", "B", .info, false));
}

test "terminal notifications: OSC 777 for ghostty and WezTerm, OSC 9 for iTerm2, both elsewhere; a field cannot end the sequence" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqual(TermNotify.osc777, termNotifyFor("ghostty"));
    try t.expectEqual(TermNotify.osc777, termNotifyFor("WezTerm"));
    try t.expectEqual(TermNotify.osc9, termNotifyFor("iTerm.app"));
    try t.expectEqual(TermNotify.both, termNotifyFor("Apple_Terminal"));
    try t.expectEqual(TermNotify.both, termNotifyFor(null));
    const both = try terminalEscapes(a, .both, "mnml — needs you", "fix the tests");
    try t.expectEqual(@as(usize, 2), both.len);
    try t.expectEqualStrings("\x1b]777;notify;mnml — needs you;fix the tests\x07", both[0]);
    try t.expectEqualStrings("\x1b]9;mnml — needs you: fix the tests\x07", both[1]);
    try t.expectEqual(@as(usize, 1), (try terminalEscapes(a, .osc777, "T", "B")).len);
    try t.expectEqualStrings("\x1b]9;T: B\x07", (try terminalEscapes(a, .osc9, "T", "B"))[0]);
    // A `;`, a BEL, an ESC in a name: none of them reach the terminal raw.
    const hostile = try terminalEscapes(a, .osc777, "a;b", "x\x07y\x1b]0;z");
    try t.expectEqualStrings("\x1b]777;notify;a,b;x y ]0,z\x07", hostile[0]);
    // A long body is cut on a UTF-8 boundary.
    try t.expectEqualStrings("ab", try oscText(a, "ab—cd", 3));
    try t.expectEqualStrings("ab—", try oscText(a, "ab—cd", 5));
}

test "notify through the terminal: the escapes go to App.hostWrite, the bell after them under `sound`; no toast when the caller has one" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
    defer app.deinit();
    try app.env.put("TERM_PROGRAM", "ghostty");
    const toasts = app.toasts.items.len;
    try notify(&app, .{ .title = "mnml — needs you", .body = "claude", .level = .warn, .sound = true, .toast = false, .terminal = true });
    try t.expectEqual(toasts, app.toasts.items.len);
    try t.expectEqual(@as(usize, 2), app.host_log.items.len);
    try t.expectEqualStrings("\x1b]777;notify;mnml — needs you;claude\x07", app.host_log.items[0]);
    try t.expectEqualStrings("\x07", app.host_log.items[1]);
    // No terminal loop: nothing queued for one.
    try t.expectEqual(@as(usize, 0), app.host_out.items.len);
    // With one, the same bytes queue for it; the log keeps the newest.
    app.host_tty = true;
    try notify(&app, .{ .title = "T", .body = "B", .terminal = true, .toast = false });
    try t.expectEqualStrings("\x1b]777;notify;T;B\x07", app.host_out.items);
    var i: usize = 0;
    while (i < App.host_log_max + 3) : (i += 1) try app.hostWrite("x");
    try t.expectEqual(App.host_log_max, app.host_log.items.len);
}

test "apply: the five tier-2 commands land in App state; notify toasts, error pins" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lines = [_][]const u8{
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"jira\",\"text\":\"JIRA 3\",\"side\":\"left\",\"color\":\"cyan\",\"click_command\":\"app.quit\",\"priority\":150,\"min_width\":3,\"max_width\":12}",
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"ci\",\"text\":\"CI green\"}",
        "{\"cmd\":\"set-activity-badge\",\"section\":\"sessions\",\"count\":3}",
        "{\"cmd\":\"set-activity-badge\",\"section\":\"git\",\"count\":2}",
        "{\"cmd\":\"notify\",\"text\":\"done\",\"title\":\"build\"}",
        "{\"cmd\":\"notify\",\"text\":\"boom\",\"title\":\"build\",\"level\":\"error\",\"source\":\"ci\"}",
        "{\"cmd\":\"statusline-clear-segment\",\"id\":\"ci\"}",
        "{\"cmd\":\"set-activity-badge\",\"section\":\"git\",\"count\":0}",
    };
    for (lines) |line| {
        const cmd = try ipc_command.parse(a, line);
        try t.expect(try apply(&app, &cmd));
    }
    try t.expect(!try apply(&app, &.snapshot));
    try t.expectEqual(@as(usize, 1), app.ipc_fx.segments.items.len);
    const seg = app.ipc_fx.segments.items[0];
    try t.expectEqualStrings("jira", seg.id);
    try t.expectEqual(Side.left, seg.side);
    try t.expectEqualStrings("cyan", seg.color.?);
    try t.expectEqualStrings("app.quit", seg.click_command.?);
    try t.expectEqual(@as(u8, 150), seg.priority);
    try t.expectEqual(@as(u16, 3), seg.min_width);
    try t.expectEqual(@as(u16, 12), seg.max_width);
    try t.expectEqual(@as(u32, 3), app.ipc_fx.badge("sessions"));
    try t.expectEqual(@as(u32, 0), app.ipc_fx.badge("git"));
    // Two toasts: the info one expires, the error one is pinned under `ci`.
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    try t.expectEqualStrings("build: done", app.toasts.items[0].text);
    try t.expect(app.toasts.items[0].id == null);
    try t.expectEqualStrings("build: boom", app.toasts.items[1].text);
    try t.expectEqualStrings("ci", app.toasts.items[1].id.?);
    try t.expectEqual(app_mod.ToastLevel.err, app.toasts.items[1].level);
    // A click on the segment runs its command. `app.quit` raises its
    // box first (`ui.confirm_quit`), so the `q` on it is the quit.
    try clickSegment(&app, 0);
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.char('q') });
    try t.expect(app.quit);
}
