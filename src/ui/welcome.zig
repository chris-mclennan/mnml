//! The welcome pane — the editor area when no pane is open: the `mnml`
//! logo, the workspace and its branch, the recent files, the shortcut
//! list and the version line, every row centred on the pane.
//!
//! The rows are a ladder the pane's height climbs. Under six rows
//! nothing is painted but the ground. From six the word `mnml` stands
//! in for the logo, which needs nineteen rows (its five plus the
//! fourteen the rest of the ladder takes). Recent files join when
//! twelve rows remain past the head, up to eight of them, each one
//! a row the pane can spare. The whole stack sits at `(h - rows) / 2`
//! from the top; a stack taller than the pane is clipped at the
//! bottom, never scrolled.
//!
//! Every row is centred on its own painted width, so the shortcut
//! chords do not line up in a column: `  ^P     find file` is one
//! string, centred. A recent row and a shortcut row each register a
//! `.welcome` hit hugging the painted text — the empty gutter either
//! side reads as untargetable, and is.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const hit_mod = @import("hit.zig");

const Style = vaxis.Style;

pub const Shortcut = struct {
    /// Already in its display spelling: `^P`, `SPC`, `F1`.
    chord: []const u8,
    label: []const u8,
};

pub const Props = struct {
    /// The workspace directory's name.
    workspace: []const u8,
    /// The checked-out branch; null outside a repository.
    branch: ?[]const u8 = null,
    /// Files changed on the branch — `· 3 changed files` after it.
    changed: u32 = 0,
    /// Workspace-relative, newest first.
    recent: []const []const u8 = &.{},
    shortcuts: []const Shortcut = &.{},
    /// Goes after `mnml ` on the last row.
    version: []const u8,
};

/// figlet "Standard" with full kerning: each letter at its native
/// width, a two-cell gutter between them so m / n / m / l read apart.
/// The `l` is one row taller than m / n — row 0 carries only its top
/// serif; the m / n / m underscores live on row 1.
pub const logo = [_][]const u8{
    "                                 _ ",
    " _ __ ___    _ __    _ __ ___   | |",
    "| '_ ` _ \\  | '_ \\  | '_ ` _ \\  | |",
    "| | | | | | | | | | | | | | | | | |",
    "|_| |_| |_| |_| |_| |_| |_| |_| |_|",
};

pub const underline = "──────────────";
const underline_ascii = "--------------";

/// Rows the ladder takes past the logo: blank, workspace, blank,
/// Shortcuts header, underline, six chords, blank, version — the
/// branch row and the recent block come on top.
const rows_after_logo: u16 = 14;
const min_rows: u16 = 6;
/// A recent block needs its header, underline and blank plus the ten
/// rows of shortcuts below it before the first path fits.
const recent_room: u16 = 12;
const max_recent: u16 = 8;

/// A row of the stack before it is centred.
const Row = struct {
    segs: []const Seg = &.{},
    hit: ?hit_mod.WelcomeRow = null,
    /// A path too wide for the pane ends in an ellipsis; every other
    /// row (the logo) clips at the edge.
    ellipsis: bool = false,
};
const Seg = struct { text: []const u8, style: Style };

pub fn draw(ui: Ui, area: Rect, p: Props) void {
    const t = ui.theme;
    const pal = t.palette;
    ui.fill(area, t.bg);
    if (area.h < min_rows or area.w == 0) return;

    const dim = Style{ .fg = pal.comment, .bg = pal.bg_dark };
    const key = Style{ .fg = pal.yellow, .bg = pal.bg_dark, .bold = true };
    const logo_style = Style{ .fg = pal.blue, .bg = pal.bg_dark, .bold = true };
    const header = Style{ .fg = pal.purple, .bg = pal.bg_dark, .bold = true };
    const path = Style{ .fg = pal.fg, .bg = pal.bg_dark };
    const branch_style = Style{ .fg = pal.green, .bg = pal.bg_dark, .bold = true };
    const rule: []const u8 = if (ui.ascii) underline_ascii else underline;

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    const a = ui.arena;
    const show_logo = area.h >= logo.len + rows_after_logo;
    if (show_logo) {
        for (logo) |line| push(&rows, a, .{ .segs = seg1(a, line, logo_style) });
        push(&rows, a, .{});
    } else {
        push(&rows, a, .{ .segs = seg1(a, "mnml", logo_style) });
    }
    push(&rows, a, .{ .segs = seg1(a, ui.fmt("workspace · {s}", .{p.workspace}), path) });
    if (p.branch) |b| {
        const segs: []Seg = a.alloc(Seg, if (p.changed > 0) 3 else 2) catch &.{};
        if (segs.len > 0) {
            segs[0] = .{ .text = "on ", .style = dim };
            segs[1] = .{ .text = b, .style = branch_style };
            if (segs.len == 3) segs[2] = .{ .text = ui.fmt(" · {d} changed file{s}", .{ p.changed, if (p.changed == 1) "" else "s" }), .style = dim };
        }
        push(&rows, a, .{ .segs = segs });
    }
    push(&rows, a, .{});

    if (p.recent.len > 0 and area.h >= rows.items.len + recent_room) {
        push(&rows, a, .{ .segs = seg1(a, "Recent Files", header) });
        push(&rows, a, .{ .segs = seg1(a, rule, dim) });
        const room: usize = area.h - rows.items.len - 10;
        const n = @min(p.recent.len, @min(room, max_recent));
        for (p.recent[0..n], 0..) |rel, i| {
            push(&rows, a, .{ .segs = seg1(a, ui.fmt("  {s}", .{rel}), path), .hit = .{ .kind = .recent, .idx = @intCast(i) }, .ellipsis = true });
        }
        push(&rows, a, .{});
    }

    push(&rows, a, .{ .segs = seg1(a, "Shortcuts", header) });
    push(&rows, a, .{ .segs = seg1(a, rule, dim) });
    for (p.shortcuts, 0..) |s, i| {
        const segs: []Seg = a.alloc(Seg, 2) catch &.{};
        if (segs.len == 2) {
            segs[0] = .{ .text = ui.fmt("  {s}     ", .{s.chord}), .style = key };
            segs[1] = .{ .text = s.label, .style = dim };
        }
        push(&rows, a, .{ .segs = segs, .hit = .{ .kind = .shortcut, .idx = @intCast(i) } });
    }
    push(&rows, a, .{});
    push(&rows, a, .{ .segs = seg1(a, ui.fmt("mnml {s}", .{p.version}), dim) });

    const n: u16 = @intCast(@min(rows.items.len, std.math.maxInt(u16)));
    const top = area.y + (area.h -| n) / 2;
    for (rows.items, 0..) |row, i| {
        const y = top + @as(u16, @intCast(i));
        if (y >= area.bottom()) break;
        var line_w: u16 = 0;
        for (row.segs) |s| line_w +|= ui.width(s.text);
        // A row wider than the pane starts at its left edge and clips.
        const inset = (area.w -| line_w) / 2;
        var x = area.x + inset;
        const right = area.right();
        for (row.segs) |s| {
            if (x >= right) break;
            const room = right - x;
            const text = if (!row.ellipsis or ui.fitsIn(s.text, room)) s.text else ui.clipStr(s.text, room);
            x += ui.putStr(x, y, room, text, s.style);
        }
        if (row.hit) |h| ui.hit(Rect.init(area.x + inset, y, @min(line_w, area.w), 1), .{ .welcome = h });
    }
}

fn push(rows: *std.ArrayListUnmanaged(Row), a: std.mem.Allocator, row: Row) void {
    // OOM drops the row: the frame is painted from whatever fit.
    rows.append(a, row) catch {};
}

fn seg1(a: std.mem.Allocator, text: []const u8, style: Style) []const Seg {
    const s = a.alloc(Seg, 1) catch return &.{};
    s[0] = .{ .text = text, .style = style };
    return s;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const standard = [_]Shortcut{
    .{ .chord = "^P", .label = "find file" },
    .{ .chord = "^R", .label = "recent files" },
    .{ .chord = "^K", .label = "which-key menu" },
    .{ .chord = "^N", .label = "new file" },
    .{ .chord = "^B", .label = "toggle tree" },
    .{ .chord = "^Q", .label = "quit" },
};

/// Rows 2–37 of `docs/ui-spec/rust-120x40.txt` from column 31: the
/// Rust editor's welcome pane on the `ws` fixture at 120×40, with
/// its version row rewritten to the form this build paints.
const spec_89x36 = [_][]const u8{
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "                                                            _",
    "                            _ __ ___    _ __    _ __ ___   | |",
    "                           | '_ ` _ \\  | '_ \\  | '_ ` _ \\  | |",
    "                           | | | | | | | | | | | | | | | | | |",
    "                           |_| |_| |_| |_| |_| |_| |_| |_| |_|",
    "",
    "                                     workspace · ws",
    "                                         on main",
    "",
    "                                        Shortcuts",
    "                                     ──────────────",
    "                                     ^P     find file",
    "                                    ^R     recent files",
    "                                   ^K     which-key menu",
    "                                      ^N     new file",
    "                                    ^B     toggle tree",
    "                                        ^Q     quit",
    "",
    "                                 mnml 0.2.21 · 9d5049b52",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
};

test "welcome: 89×36: the pane matches the Rust dump row for row" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .shortcuts = &standard, .version = "0.2.21 · 9d5049b52" });
    try f.expectRows(&spec_89x36);
    // The logo is the accent blue in bold, the headers purple, the branch
    // green, the chords yellow, the version row muted.
    const pal = f.theme.palette;
    try testing.expect(f.fgEql(60, 8, .{ .fg = pal.blue }) and f.style(60, 8).bold);
    try testing.expect(f.fgEql(40, 17, .{ .fg = pal.purple }));
    try testing.expect(f.fgEql(44, 15, .{ .fg = pal.green }) and f.fgEql(41, 15, .{ .fg = pal.comment }));
    try testing.expect(f.fgEql(37, 19, .{ .fg = pal.yellow }) and f.fgEql(44, 19, .{ .fg = pal.comment }));
    try testing.expect(f.fgEql(33, 26, .{ .fg = pal.comment }));
    try testing.expect(f.bgEql(0, 0, .{ .bg = pal.bg_dark }) and f.bgEql(88, 35, .{ .bg = pal.bg_dark }));
    // Each shortcut row's hit hugs its painted text.
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 0 }, f.hits.at(37, 19).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 5 }, f.hits.at(40, 24).?.welcome);
    // The hit takes in the two-cell lead, as the painted text does.
    try testing.expect(f.hits.at(34, 19) == null);
    try testing.expect(f.hits.at(10, 24) == null);
}

test "welcome: outside a repo the branch row is gone and the stack re-centres" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    // 18 rows on 36: top is 9.
    try expectCentred(&f, 9, logo[0]);
    try expectCentred(&f, 15, "workspace · ws");
    try f.expectRow(16, "");
    try expectCentred(&f, 17, "Shortcuts");
    try expectCentred(&f, 26, "mnml 0.3.0");
    try f.expectRow(27, "");
}

test "welcome: the ladder: twelve rows keep the word, eight rows clip the tail, five rows paint nothing" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .shortcuts = &standard, .version = "0.3.0" });
    // 13 rows of stack on 12: top is 0, the version row falls off.
    try expectCentred(&f, 0, "mnml");
    try expectCentred(&f, 1, "workspace · ws");
    try expectCentred(&f, 2, "on main");
    try f.expectRow(3, "");
    try expectCentred(&f, 4, "Shortcuts");
    try expectCentred(&f, 5, underline);
    try expectCentred(&f, 6, "  ^P     find file");
    try expectCentred(&f, 7, "  ^R     recent files");
    try expectCentred(&f, 8, "  ^K     which-key menu");
    try expectCentred(&f, 9, "  ^N     new file");
    try expectCentred(&f, 10, "  ^B     toggle tree");
    try expectCentred(&f, 11, "  ^Q     quit");
    try f.expectLacks("mnml 0.3.0");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 5 }, f.hits.at(26, 11).?.welcome);

    var g = try Fixture.init(60, 8);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    try expectCentred(&g, 0, "mnml");
    try expectCentred(&g, 1, "workspace · ws");
    try g.expectRow(2, "");
    try expectCentred(&g, 3, "Shortcuts");
    try expectCentred(&g, 4, underline);
    try expectCentred(&g, 5, "  ^P     find file");
    try expectCentred(&g, 6, "  ^R     recent files");
    try expectCentred(&g, 7, "  ^K     which-key menu");
    try g.expectLacks("new file");

    var h = try Fixture.init(60, 5);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .workspace = "ws", .shortcuts = &standard, .version = "0.3.0" });
    try h.expectRows(&.{ "", "", "", "", "" });
    try testing.expect(h.bgEql(0, 0, .{ .bg = h.theme.palette.bg_dark }));
}

test "welcome: the chord column is whatever the profile says: vim's leader rows" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const vim = [_]Shortcut{
        .{ .chord = "^P", .label = "find file" },
        .{ .chord = "SPC", .label = "which-key menu" },
        .{ .chord = "^N", .label = "toggle tree" },
        .{ .chord = "^Q", .label = "quit" },
    };
    draw(f.ui(), f.full(), .{ .workspace = "ws", .shortcuts = &vim, .version = "0.3.0" });
    // 10 rows on 12: top is 1.
    try expectCentred(&f, 4, underline);
    try expectCentred(&f, 5, "  ^P     find file");
    try expectCentred(&f, 6, "  SPC     which-key menu");
    try expectCentred(&f, 7, "  ^N     toggle tree");
    try expectCentred(&f, 8, "  ^Q     quit");
    try expectCentred(&f, 10, "mnml 0.3.0");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .shortcut, .idx = 2 }, f.hits.at(24, 7).?.welcome);
}

test "welcome: recent files sit between the branch and the shortcuts, each row a hit, capped by the room" {
    var f = try Fixture.init(89, 36);
    defer f.deinit();
    const recent = [_][]const u8{ "src/main.rs", "README.md", "package.json" };
    draw(f.ui(), f.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    // 19 + 3 + 3 = 25 rows: top is 5.
    try expectCentred(&f, 5, logo[0]);
    try expectCentred(&f, 12, "on main");
    try f.expectRow(13, "");
    try expectCentred(&f, 14, "Recent Files");
    try expectCentred(&f, 15, underline);
    try expectCentred(&f, 16, "  src/main.rs");
    try expectCentred(&f, 17, "  README.md");
    try expectCentred(&f, 18, "  package.json");
    try f.expectRow(19, "");
    try expectCentred(&f, 20, "Shortcuts");
    try expectCentred(&f, 29, "mnml 0.3.0");
    // "  src/main.rs" is 13 wide: inset 38, the hit spans 38..50.
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(38, 16).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(50, 16).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 2 }, f.hits.at(44, 18).?.welcome);
    try testing.expect(f.hits.at(37, 16) == null);
    try testing.expect(f.hits.at(51, 16) == null);
    try testing.expect(f.hits.at(44, 15) == null);

    // Twelve recent files on 36 rows: 36 - 12 head rows - 10 below = 8, the cap.
    var many: [12][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = if (i % 2 == 0) "a.txt" else "b.txt";
    var g = try Fixture.init(89, 36);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .workspace = "ws", .branch = "main", .recent = &many, .shortcuts = &standard, .version = "0.3.0" });
    // 19 + 3 + 8 = 30 rows: top is 3.
    try expectCentred(&g, 3, logo[0]);
    try expectCentred(&g, 12, "Recent Files");
    try expectCentred(&g, 14, "  a.txt");
    try expectCentred(&g, 21, "  b.txt");
    try g.expectRow(22, "");
    try expectCentred(&g, 23, "Shortcuts");
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 7 }, g.hits.at(42, 21).?.welcome);
    try testing.expect(g.hits.at(42, 22) == null);
    // Below 21 rows (nine of head plus twelve) there is no recent block;
    // at 22 the first path fits (22 - 11 - 10 = 1).
    var h = try Fixture.init(89, 20);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    try h.expectLacks("Recent Files");
    try h.expectContains("Shortcuts");
    var k = try Fixture.init(89, 22);
    defer k.deinit();
    draw(k.ui(), k.full(), .{ .workspace = "ws", .branch = "main", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    try k.expectContains("Recent Files");
    try k.expectContains("  src/main.rs");
    try k.expectLacks("README.md");
}

test "welcome: a narrow pane: a wide path ends in an ellipsis and stays one hit, the logo clips bare" {
    var f = try Fixture.init(30, 36);
    defer f.deinit();
    const recent = [_][]const u8{"a/very/long/path/that/does/not/fit/in/thirty/cells.zig"};
    draw(f.ui(), f.full(), .{ .workspace = "ws", .recent = &recent, .shortcuts = &standard, .version = "0.3.0" });
    var buf: [256]u8 = undefined;
    // 22 rows on 36: top is 7; the path row is the tenth.
    const r = f.row(17, &buf);
    try testing.expect(std.mem.startsWith(u8, r, "  a/very/long/path"));
    try testing.expect(std.mem.endsWith(u8, r, "…"));
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(0, 17).?.welcome);
    try testing.expectEqual(hit_mod.WelcomeRow{ .kind = .recent, .idx = 0 }, f.hits.at(29, 17).?.welcome);
    try f.expectRow(11, "|_| |_| |_| |_| |_| |_| |_| |_");
}

/// `text` centred on the fixture's width the way the pane centres a
/// row: `(w - width) / 2` cells of inset.
fn expectCentred(f: *Fixture, y: u16, text: []const u8) !void {
    var buf: [512]u8 = undefined;
    const tw: usize = std.unicode.utf8CountCodepoints(text) catch text.len;
    const inset = (@as(usize, f.screen.width) - tw) / 2;
    @memset(buf[0..inset], ' ');
    @memcpy(buf[inset .. inset + text.len], text);
    // The row reader trims the trailing blank (the logo's top row has one).
    try f.expectRow(y, std.mem.trimEnd(u8, buf[0 .. inset + text.len], " "));
}
