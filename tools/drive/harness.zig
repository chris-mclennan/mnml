//! The two files a harness run is made of: the ghostty config it launches
//! under, and `drive.json`, the record every later verb checks itself
//! against.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ─── the ghostty config ─────────────────────────────────────────────────

/// The name on the harness window. Fixed, and deliberately plain
/// English: the person whose screen it appears on is the one who needs
/// to read it.
pub const window_title = "mnml-drive harness";

/// The floor a `--size` name may reach. 80x24 is the smallest terminal
/// anyone runs, and the corpus's own bottom rung; below it the picker
/// used to panic outright.
pub const min_cols: u16 = 80;
pub const min_rows: u16 = 24;

/// The floor an EXPLICIT `--cols` / `--rows` may reach: ghostty's own
/// (`window-width` 10 columns, `window-height` 4 rows). An explicit size
/// is a script's `# width:` / `# height:` header, and a file that declares
/// a size gets that size — `wheel_context_menu.test` pins 14 rows so its
/// menu overflows the screen; clamped to 24 the whole menu fit, nothing
/// scrolled, and the sweep counted five misses that were the harness's.
pub const explicit_min_cols: u16 = 10;
pub const explicit_min_rows: u16 = 4;

/// `--cols` / `--rows` as given (either may be missing: the other half
/// of the `small` floor), never below ghostty's own floor.
pub fn explicitCells(cols: ?u16, rows: ?u16) Cells {
    return .{
        .cols = @max(cols orelse min_cols, explicit_min_cols),
        .rows = @max(rows orelse min_rows, explicit_min_rows),
    };
}

/// The named sizes. `full` has no number here: it is measured on the
/// machine (the user's own largest ghostty window, or the display).
pub const Cells = struct { cols: u16, rows: u16 };

pub const Named = enum {
    small,
    corpus,
    full,

    pub fn cells(n: Named) ?Cells {
        return switch (n) {
            // The floor. The dock has no labels, the menu bar is `»`.
            .small => .{ .cols = 80, .rows = 24 },
            // Where every `.test` content assertion was written.
            .corpus => .{ .cols = 120, .rows = 40 },
            // Measured, not declared.
            .full => null,
        };
    }
};

/// How many cells fit in a window of `w` x `h` POINTS at the measured
/// cell size. The measurement comes from a real window the harness
/// already opened, so it is the user's own font at the user's own size
/// rather than a guess from a font table.
pub fn cellsFor(w: f64, h: f64, cell_w: f64, cell_h: f64) Cells {
    if (cell_w <= 0 or cell_h <= 0) return .{ .cols = min_cols, .rows = min_rows };
    const c: f64 = @floor(w / cell_w);
    const r: f64 = @floor(h / cell_h);
    return .{
        .cols = @intFromFloat(@min(@max(c, @as(f64, min_cols)), 400)),
        .rows = @intFromFloat(@min(@max(r, @as(f64, min_rows)), 200)),
    };
}

pub const ConfigOptions = struct {
    cols: u16,
    rows: u16,
    /// What the window calls itself. The window is FOUND by owner pid —
    /// the title is for the human who glances at their screen and has to
    /// know at once that this one is not theirs.
    title: []const u8,
    /// Set only when the user's own config names no size — unless
    /// `force_font_size`, which a retry sets: a size that does not fit
    /// on the display is not a preference the harness can honour.
    font_size: ?u16 = null,
    force_font_size: bool = false,
    /// False writes `mouse-reporting = false` (`launch --no-mouse`): the
    /// person's own pointer passing over the harness window no longer
    /// reaches mnml. A window driven through the file channel gets its
    /// clicks and hovers from there, and a pointer that happened to rest
    /// over it put its hover help into every shot — the tour's second
    /// run read `Shortcut` in the info panel where the first read
    /// `Sidebar`. The driver's own mouse verbs need it on.
    mouse_reporting: bool = true,
};

/// Keys the harness must own, whatever the user's config says. A line in
/// the base whose key is one of these is dropped, so the appended
/// override is the only one ghostty sees.
const overridden = [_][]const u8{
    "window-decoration",
    "macos-titlebar-style",
    "window-padding-x",
    "window-padding-y",
    "window-padding-balance",
    "window-width",
    "window-height",
    "window-save-state",
    "title",
    "window-position-x",
    "window-position-y",
    "confirm-close-surface",
    "quit-after-last-window-closed",
    "initial-window",
};

fn keyOf(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return std.mem.trim(u8, trimmed[0..eq], " \t");
}

/// The harness config: the user's own ghostty config VERBATIM, minus the
/// handful of keys the harness has to own, plus the overrides.
///
/// The font lines are the point. mnml's glyphs come from a Nerd-Font
/// primary plus a `font-codepoint-map` onto MnmlSymbols; a harness that
/// invented its own font setup would photograph a screen the user has
/// never seen, and every glyph finding out of it would be about the
/// harness. Reading their config means what a hunter sees is what the
/// user sees.
///
/// `base` is the text of `~/.config/ghostty/config`, or "" when there is
/// none.
pub fn renderConfig(gpa: Allocator, base: []const u8, opts: ConfigOptions) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // An Allocating writer only ever fails for want of memory.
    renderInto(&out.writer, base, opts) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn renderInto(w: *Io.Writer, base: []const u8, opts: ConfigOptions) Io.Writer.Error!void {
    try w.writeAll("# Written by mnml-drive. Dev-only; never shipped.\n");
    try w.writeAll("# Everything above the rule is your own ~/.config/ghostty/config,\n");
    try w.writeAll("# so the harness window renders the way your terminal does.\n");
    var has_font_size = false;
    var it = std.mem.splitScalar(u8, base, '\n');
    while (it.next()) |line| {
        if (keyOf(line)) |k| {
            if (std.mem.eql(u8, k, "font-size")) {
                has_font_size = true;
                // A forced size must be the only one in the file, or
                // ghostty takes the user's and the retry changes nothing.
                if (opts.force_font_size) continue;
            }
            var owned = false;
            for (overridden) |o| {
                if (std.mem.eql(u8, k, o)) owned = true;
            }
            if (!opts.mouse_reporting and std.mem.eql(u8, k, "mouse-reporting")) owned = true;
            if (owned) continue;
        }
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try w.writeAll(trimmed);
        try w.writeByte('\n');
    }

    try w.writeAll("\n# ── mnml-drive overrides ─────────────────────────────\n");
    // No chrome, no padding: the window's own top-left corner is then
    // cell (0,0), and cell → pixel is one multiply with no fudge for a
    // titlebar whose height varies with the macOS version.
    try w.writeAll("window-decoration = false\n");
    try w.writeAll("macos-titlebar-style = hidden\n");
    try w.writeAll("window-padding-x = 0\n");
    try w.writeAll("window-padding-y = 0\n");
    try w.writeAll("window-padding-balance = false\n");
    try w.print("window-width = {d}\n", .{opts.cols});
    try w.print("window-height = {d}\n", .{opts.rows});
    // A restored session would reopen the developer's own tabs into the
    // harness window, and a close prompt would wedge `quit`.
    try w.writeAll("window-save-state = never\n");
    try w.writeAll("confirm-close-surface = false\n");
    // Top-left, so the harness lands somewhere predictable instead of
    // cascading over whatever the developer has open.
    try w.writeAll("window-position-x = 0\n");
    try w.writeAll("window-position-y = 0\n");
    try w.print("title = {s}\n", .{opts.title});
    if (!opts.mouse_reporting) try w.writeAll("mouse-reporting = false\n");
    if (!has_font_size or opts.force_font_size) {
        if (opts.font_size) |pt| try w.print("font-size = {d}\n", .{pt});
    }
}

/// mnml's own config for a harness root. Two keys, both load-bearing:
///
///   `ipc.write_screen`          the live terminal loop only writes
///                               screen.txt / status.json / rects.json
///                               with this on, and those dumps are the
///                               only way the harness reads the app back.
///   `ui.first_launch_complete`  a fresh data root IS a first launch, and
///                               `app/first_launch.zig` opens the setup
///                               wizard over the whole screen. The `.test`
///                               runner never meets it (it does not run
///                               the startup hook); the real terminal
///                               does, and the first harness window ever
///                               shown to a user was that wizard, clipped.
pub const mnml_config = ".{ .ipc = .{ .write_screen = true }, .ui = .{ .first_launch_complete = true } }\n";

/// The keys the harness copies out of the developer's own
/// `config.zon`, and nothing else.
///
/// A hunter looking at the harness should be looking at the LAYOUT the
/// developer looks at — a left column at their width, tabs with their
/// indicator — or half of what they report is about a layout nobody
/// uses. Two keys, both pure appearance. Nothing that names a token, a
/// path, an integration or a host goes anywhere near the harness: the
/// harness runs scripts, and a script that could read a credential out
/// of the config it was launched under is a credential in a screenshot.
pub const copied_keys = [_][]const u8{ "tree_width", "tab_indicator" };

/// `mnml_config` with the copied keys folded into its `.ui` block.
/// `user` is the text of the developer's `config.zon`, or "" when there
/// is none.
pub fn mnmlConfigFrom(gpa: Allocator, user: []const u8) Allocator.Error![]u8 {
    return mnmlConfigWith(gpa, user, .{});
}

pub const MnmlOptions = struct {
    /// `ipc.allow_input`: the channel may drive keys, typing and the
    /// mouse (`--allow-input`). The way a script drives the window
    /// WITHOUT taking the keyboard — `key` / `type` need the harness to
    /// be the active app, a line in the channel does not.
    allow_input: bool = false,
};

pub fn mnmlConfigWith(gpa: Allocator, user: []const u8, opts: MnmlOptions) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    writeMnmlConfig(w, user, opts) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeMnmlConfig(w: *Io.Writer, user: []const u8, opts: MnmlOptions) Io.Writer.Error!void {
    try w.writeAll(if (opts.allow_input)
        ".{ .ipc = .{ .write_screen = true, .allow_input = true }, .ui = .{ .first_launch_complete = true"
    else
        ".{ .ipc = .{ .write_screen = true }, .ui = .{ .first_launch_complete = true");
    for (copied_keys) |key| {
        if (uiValue(user, key)) |v| try w.print(", .{s} = {s}", .{ key, v });
    }
    try w.writeAll(" } }\n");
}

/// The value of `.<key> = …` in a `config.zon`, as written. A hand-rolled
/// scan rather than a ZON parse because this tool must not link the
/// config loader (and through it the app); the keys it looks for are a
/// number and an enum literal, both of which end at the comma.
fn uiValue(text: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, ".{s} = ", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    // Only a key at the start of its line; `.foo_tree_width = 1` is not
    // `.tree_width`.
    if (at > 0) {
        const before = text[at - 1];
        if (before != '\n' and before != ' ' and before != '\t' and before != '{') return null;
    }
    const rest = text[at + needle.len ..];
    var n: usize = 0;
    while (n < rest.len and rest[n] != ',' and rest[n] != '\n' and rest[n] != '}') n += 1;
    const v = std.mem.trim(u8, rest[0..n], " \t\r");
    if (v.len == 0 or v.len > 40) return null;
    // Numbers and enum literals only — never a string, a path or a list.
    for (v) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return null;
    }
    return v;
}

// ─── drive.json ─────────────────────────────────────────────────────────

/// What `launch` records and every other verb re-checks itself against.
/// Bounds are screen POINTS; `cell_w`/`cell_h` are points too, derived
/// from the window and the grid rather than believed from a font setting.
pub const Record = struct {
    pid: i32,
    window_id: u32,
    title: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    cols: u16,
    rows: u16,
    workspace: []const u8,
    data_root: []const u8,
    ipc_dir: []const u8,

    pub fn cellW(self: Record) f64 {
        return if (self.cols > 0) self.w / @as(f64, @floatFromInt(self.cols)) else 0;
    }
    pub fn cellH(self: Record) f64 {
        return if (self.rows > 0) self.h / @as(f64, @floatFromInt(self.rows)) else 0;
    }

    /// The centre of cell (x, y) in screen points — where a click lands.
    /// The centre and not the corner: a cell edge is shared with its
    /// neighbour, and half a point of rounding the wrong way is a click
    /// on the column next door.
    pub fn cellCentre(self: Record, cx: u16, cy: u16) struct { x: f64, y: f64 } {
        return .{
            .x = self.x + (@as(f64, @floatFromInt(cx)) + 0.5) * self.cellW(),
            .y = self.y + (@as(f64, @floatFromInt(cy)) + 0.5) * self.cellH(),
        };
    }
};

pub fn writeRecord(gpa: Allocator, r: Record) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.print(
        "{{\"pid\":{d},\"windowId\":{d},\"title\":\"{s}\",\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}," ++
            "\"cols\":{d},\"rows\":{d},\"cellW\":{d:.4},\"cellH\":{d:.4}," ++
            "\"workspace\":\"{s}\",\"dataRoot\":\"{s}\",\"ipcDir\":\"{s}\"}}\n",
        .{ r.pid, r.window_id, r.title, r.x, r.y, r.w, r.h, r.cols, r.rows, r.cellW(), r.cellH(), r.workspace, r.data_root, r.ipc_dir },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const ParseError = error{ Malformed, OutOfMemory };

/// Read a record back. Hand-rolled to match `writeRecord`'s fixed key
/// order, the way `ipc/screen.zig` hand-rolls `status.json`: these bytes
/// are a contract with `scripts/shot.sh`, which greps them.
pub fn readRecord(gpa: Allocator, text: []const u8) ParseError!Record {
    var r: Record = .{
        .pid = 0,
        .window_id = 0,
        .title = "",
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .cols = 0,
        .rows = 0,
        .workspace = "",
        .data_root = "",
        .ipc_dir = "",
    };
    r.pid = @intCast(try intField(text, "pid"));
    r.window_id = @intCast(try intField(text, "windowId"));
    r.cols = @intCast(try intField(text, "cols"));
    r.rows = @intCast(try intField(text, "rows"));
    r.x = try floatField(text, "x");
    r.y = try floatField(text, "y");
    r.w = try floatField(text, "w");
    r.h = try floatField(text, "h");
    r.title = try gpa.dupe(u8, try strField(text, "title"));
    errdefer gpa.free(r.title);
    r.workspace = try gpa.dupe(u8, try strField(text, "workspace"));
    errdefer gpa.free(r.workspace);
    r.data_root = try gpa.dupe(u8, try strField(text, "dataRoot"));
    errdefer gpa.free(r.data_root);
    r.ipc_dir = try gpa.dupe(u8, try strField(text, "ipcDir"));
    return r;
}

pub fn freeRecord(gpa: Allocator, r: Record) void {
    gpa.free(r.title);
    gpa.free(r.workspace);
    gpa.free(r.data_root);
    gpa.free(r.ipc_dir);
}

fn valueOf(text: []const u8, key: []const u8) error{Malformed}![]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return error.Malformed;
    const at = std.mem.indexOf(u8, text, needle) orelse return error.Malformed;
    return text[at + needle.len ..];
}

fn intField(text: []const u8, key: []const u8) error{Malformed}!i64 {
    const rest = try valueOf(text, key);
    var n: usize = 0;
    if (n < rest.len and rest[n] == '-') n += 1;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return error.Malformed;
    return std.fmt.parseInt(i64, rest[0..n], 10) catch error.Malformed;
}

fn floatField(text: []const u8, key: []const u8) error{Malformed}!f64 {
    const rest = try valueOf(text, key);
    var n: usize = 0;
    if (n < rest.len and rest[n] == '-') n += 1;
    while (n < rest.len and (std.ascii.isDigit(rest[n]) or rest[n] == '.')) n += 1;
    if (n == 0) return error.Malformed;
    return std.fmt.parseFloat(f64, rest[0..n]) catch error.Malformed;
}

fn strField(text: []const u8, key: []const u8) error{Malformed}![]const u8 {
    const rest = try valueOf(text, key);
    if (rest.len == 0 or rest[0] != '"') return error.Malformed;
    const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.Malformed;
    return rest[1..end];
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "renderConfig keeps the user's font setup verbatim and appends the harness overrides" {
    // The exact shape of a recommended mnml ghostty config.
    const base =
        "font-family = JetBrainsMono Nerd Font\n" ++
        "# a comment the user wrote\n" ++
        "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n";
    const got = try renderConfig(t.allocator, base, .{ .cols = 120, .rows = 40, .title = window_title, .font_size = 13 });
    defer t.allocator.free(got);

    try t.expect(std.mem.indexOf(u8, got, "font-family = JetBrainsMono Nerd Font\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n") != null);
    // Exactly one font-family: a second would silently win and the
    // window would render in a font the user has never looked at.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, got, "font-family"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, got, "font-codepoint-map"));

    for ([_][]const u8{
        "window-decoration = false",
        "window-padding-x = 0",
        "window-padding-y = 0",
        "window-width = 120",
        "window-height = 40",
        "title = mnml-drive harness",
        "window-position-x = 0",
        "confirm-close-surface = false",
    }) |line| {
        try t.expect(std.mem.indexOf(u8, got, line) != null);
    }
    // The user set no size, so the harness supplies one.
    try t.expect(std.mem.indexOf(u8, got, "font-size = 13\n") != null);
}

test "renderConfig: the user's font-size wins, and a config that fights an override loses" {
    const base =
        "font-family = Menlo\n" ++
        "font-size = 18\n" ++
        "window-decoration = true\n" ++
        "window-padding-x = 6\n" ++
        "title = the user's own title\n";
    const got = try renderConfig(t.allocator, base, .{ .cols = 80, .rows = 24, .title = window_title, .font_size = 13 });
    defer t.allocator.free(got);
    // Theirs, not ours.
    try t.expect(std.mem.indexOf(u8, got, "font-size = 18") != null);
    try t.expect(std.mem.indexOf(u8, got, "font-size = 13") == null);
    // Ours, not theirs — and only once, so ghostty cannot pick the
    // wrong one.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, got, "window-decoration"));
    try t.expect(std.mem.indexOf(u8, got, "window-decoration = false") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, got, "window-padding-x"));
    try t.expect(std.mem.indexOf(u8, got, "window-padding-x = 0") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, got, "title ="));
    try t.expect(std.mem.indexOf(u8, got, "title = mnml-drive harness") != null);
    try t.expect(std.mem.indexOf(u8, got, "the user's own title") == null);
}

test "renderConfig with no user config at all still produces a usable harness config" {
    const got = try renderConfig(t.allocator, "", .{ .cols = 80, .rows = 24, .title = window_title, .font_size = 13 });
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "window-width = 80") != null);
    try t.expect(std.mem.indexOf(u8, got, "font-size = 13") != null);
    try t.expect(std.mem.indexOf(u8, got, "font-family") == null);
}

test "drive.json round-trips, and a cell's centre is the middle of the cell" {
    const r: Record = .{
        .pid = 4321,
        .window_id = 90210,
        .title = "mnml-drive-4321",
        .x = 100,
        .y = 200,
        .w = 1200,
        .h = 840,
        .cols = 120,
        .rows = 40,
        .workspace = "/tmp/ws",
        .data_root = "/tmp/dr",
        .ipc_dir = "/tmp/ws/.mnml/ipc-zig",
    };
    const text = try writeRecord(t.allocator, r);
    defer t.allocator.free(text);
    const back = try readRecord(t.allocator, text);
    defer freeRecord(t.allocator, back);
    try t.expectEqual(r.pid, back.pid);
    try t.expectEqual(r.window_id, back.window_id);
    try t.expectEqual(r.cols, back.cols);
    try t.expectEqual(r.rows, back.rows);
    try t.expectEqual(r.x, back.x);
    try t.expectEqual(r.h, back.h);
    try t.expectEqualStrings(r.title, back.title);
    try t.expectEqualStrings(r.workspace, back.workspace);
    try t.expectEqualStrings(r.ipc_dir, back.ipc_dir);

    // 1200 points over 120 columns is 10 points a cell; cell 0's centre
    // is half a cell in from the window's own left edge.
    try t.expectEqual(@as(f64, 10), back.cellW());
    try t.expectEqual(@as(f64, 21), back.cellH());
    const c0 = back.cellCentre(0, 0);
    try t.expectEqual(@as(f64, 105), c0.x);
    try t.expectEqual(@as(f64, 210.5), c0.y);
    const c = back.cellCentre(10, 2);
    try t.expectEqual(@as(f64, 205), c.x);
    try t.expectEqual(@as(f64, 252.5), c.y);
}

test "readRecord refuses a truncated or scrambled file rather than guessing" {
    try t.expectError(error.Malformed, readRecord(t.allocator, "{\"pid\":12}"));
    try t.expectError(error.Malformed, readRecord(t.allocator, ""));
    try t.expectError(error.Malformed, readRecord(t.allocator, "not json at all"));
}

test "a retry forces its font size to be the only one in the file" {
    // The first attempt honours the user's 18 pt. When 120x40 at 18 pt
    // does not fit the display, the retry's size has to be the only
    // font-size line, or ghostty takes the user's and nothing changes.
    const base = "font-family = Menlo\nfont-size = 18\n";
    const forced = try renderConfig(t.allocator, base, .{ .cols = 120, .rows = 40, .title = window_title, .font_size = 9, .force_font_size = true });
    defer t.allocator.free(forced);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, forced, "font-size"));
    try t.expect(std.mem.indexOf(u8, forced, "font-size = 9") != null);
    try t.expect(std.mem.indexOf(u8, forced, "font-size = 18") == null);
    // The font FAMILY is still theirs — only the size was not a
    // preference the harness could honour.
    try t.expect(std.mem.indexOf(u8, forced, "font-family = Menlo") != null);
}

test "the harness root's mnml config turns the dumps on and the first-launch wizard off" {
    // Both halves have bitten: without write_screen there is nothing to
    // read the app back from, and without first_launch_complete the very
    // first thing a harness window shows is the setup wizard — which is
    // exactly what the first user to see this tool got.
    try t.expect(std.mem.indexOf(u8, mnml_config, ".write_screen = true") != null);
    try t.expect(std.mem.indexOf(u8, mnml_config, ".first_launch_complete = true") != null);
    // And it has to be a config mnml will actually parse: one anonymous
    // struct literal, newline-terminated.
    try t.expect(std.mem.startsWith(u8, mnml_config, ".{"));
    try t.expect(std.mem.endsWith(u8, mnml_config, "}\n"));
}

test "--allow-input turns the channel's input on, and only when asked" {
    const off = try mnmlConfigWith(t.allocator, "", .{});
    defer t.allocator.free(off);
    try t.expect(std.mem.indexOf(u8, off, "allow_input") == null);
    const on = try mnmlConfigWith(t.allocator, ".{ .ui = .{ .tree_width = 34 } }", .{ .allow_input = true });
    defer t.allocator.free(on);
    try t.expect(std.mem.indexOf(u8, on, ".ipc = .{ .write_screen = true, .allow_input = true }") != null);
    // The copied layout key still lands, beside the switch.
    try t.expect(std.mem.indexOf(u8, on, ".tree_width = 34") != null);
    try t.expect(std.mem.endsWith(u8, on, "} }\n"));
}

test "--no-mouse turns ghostty's mouse reporting off, and wins over the user's line" {
    const conf = try renderConfig(t.allocator, "font-family = X\nmouse-reporting = true\n", .{ .cols = 80, .rows = 24, .title = "t", .mouse_reporting = false });
    defer t.allocator.free(conf);
    try t.expect(std.mem.indexOf(u8, conf, "mouse-reporting = true") == null);
    try t.expect(std.mem.indexOf(u8, conf, "mouse-reporting = false\n") != null);
    try t.expect(std.mem.indexOf(u8, conf, "font-family = X") != null);
    const on = try renderConfig(t.allocator, "", .{ .cols = 80, .rows = 24, .title = "t" });
    defer t.allocator.free(on);
    try t.expect(std.mem.indexOf(u8, on, "mouse-reporting") == null);
}

test "an explicit size is taken below the named floor, down to ghostty's own" {
    try t.expectEqual(Cells{ .cols = 120, .rows = 14 }, explicitCells(120, 14));
    try t.expectEqual(Cells{ .cols = 60, .rows = min_rows }, explicitCells(60, null));
    try t.expectEqual(Cells{ .cols = min_cols, .rows = 30 }, explicitCells(null, 30));
    try t.expectEqual(Cells{ .cols = explicit_min_cols, .rows = explicit_min_rows }, explicitCells(1, 1));
}

test "cellsFor turns measured points into a cell count, floored and clamped" {
    // 960 points of window at 8-point cells is 120 columns exactly; the
    // remainder is dropped rather than rounded, because a half column is
    // a column ghostty will not draw.
    const a = cellsFor(960, 680, 8, 17);
    try t.expectEqual(@as(u16, 120), a.cols);
    try t.expectEqual(@as(u16, 40), a.rows);
    const b = cellsFor(967, 690, 8, 17);
    try t.expectEqual(@as(u16, 120), b.cols);
    try t.expectEqual(@as(u16, 40), b.rows);
    // A tiny window still gets the floor: the harness would rather show
    // a window bigger than asked than one the picker panics in.
    const tiny = cellsFor(100, 100, 8, 17);
    try t.expectEqual(min_cols, tiny.cols);
    try t.expectEqual(min_rows, tiny.rows);
    // And a measurement that never arrived is the floor too, never a
    // divide by zero.
    const nothing = cellsFor(960, 680, 0, 0);
    try t.expectEqual(min_cols, nothing.cols);
    try t.expectEqual(min_rows, nothing.rows);
}

test "the named sizes are the two the corpus already sweeps, and `full` is measured" {
    try t.expectEqual(@as(u16, 80), Named.small.cells().?.cols);
    try t.expectEqual(@as(u16, 24), Named.small.cells().?.rows);
    try t.expectEqual(@as(u16, 120), Named.corpus.cells().?.cols);
    try t.expectEqual(@as(u16, 40), Named.corpus.cells().?.rows);
    // `full` deliberately has no number: on one machine it is the user's
    // own window, on another the display, and a constant would be wrong
    // on both.
    try t.expect(Named.full.cells() == null);
}

test "the harness copies the developer's layout keys and nothing else" {
    // A config with the two keys the harness wants, next to several it
    // must not touch.
    const user =
        \\.{
        \\    .ui = .{
        \\        .tree_width = 46,
        \\        .tab_indicator = .quarter_track,
        \\    },
        \\    .ai = .{ .api_key = "sk-not-a-real-key" },
        \\    .integrations = .{ .dir = "/home/me/secrets" },
        \\}
    ;
    const got = try mnmlConfigFrom(t.allocator, user);
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, ".tree_width = 46") != null);
    try t.expect(std.mem.indexOf(u8, got, ".tab_indicator = .quarter_track") != null);
    // The harness's own two keys survive the merge.
    try t.expect(std.mem.indexOf(u8, got, ".write_screen = true") != null);
    try t.expect(std.mem.indexOf(u8, got, ".first_launch_complete = true") != null);
    // Nothing else crosses. A script runs under this config, and a
    // credential in a config a script can read is a credential in a
    // screenshot.
    try t.expect(std.mem.indexOf(u8, got, "api_key") == null);
    try t.expect(std.mem.indexOf(u8, got, "sk-") == null);
    try t.expect(std.mem.indexOf(u8, got, "secrets") == null);
    try t.expect(std.mem.indexOf(u8, got, "integrations") == null);
}

test "a developer with no config, or with only one of the keys, still gets a valid one" {
    const none = try mnmlConfigFrom(t.allocator, "");
    defer t.allocator.free(none);
    try t.expectEqualStrings(mnml_config, none);

    const partial = try mnmlConfigFrom(t.allocator, ".{ .ui = .{ .tree_width = 52 } }");
    defer t.allocator.free(partial);
    try t.expect(std.mem.indexOf(u8, partial, ".tree_width = 52") != null);
    try t.expect(std.mem.indexOf(u8, partial, "tab_indicator") == null);
    try t.expect(std.mem.endsWith(u8, partial, "} }\n"));

    // A value that is not a bare number or enum literal is refused
    // rather than pasted into a config mnml then fails to parse.
    const stringy = try mnmlConfigFrom(t.allocator, ".{ .ui = .{ .tree_width = \"wide\" } }");
    defer t.allocator.free(stringy);
    try t.expect(std.mem.indexOf(u8, stringy, "wide") == null);
}
