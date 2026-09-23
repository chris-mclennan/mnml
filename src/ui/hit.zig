//! HitMap — the frame's click targets, registered by the painter that
//! drew them (D6).
//!
//! A component paints a rect and, in the same statement, tells the map
//! what that rect means. Mouse dispatch is then one `switch` on `at(x, y)`
//! in the app; there is no second bookkeeping structure to clear or keep
//! in step with the paint. Storage is the frame arena: `reset` at the top
//! of a frame, `add` while painting, nothing to free.
//!
//! `at` scans back to front — the last thing painted is the thing on top,
//! so an overlay drawn after the panes wins the click. `writeRectsJson`
//! is the `rects.json` the IPC channel publishes, so a test can click by
//! label instead of by coordinate.

const std = @import("std");
const Rect = @import("rect.zig");
const ids = @import("../core/ids.zig");
const panel = @import("../core/panel.zig");
const activity_bar = @import("activity_bar.zig");
const tree_view = @import("tree_view.zig");
const git_palette = @import("git_palette.zig");
const http_panel = @import("http_panel.zig");
const search_section_view = @import("search_section_view.zig");

const Allocator = std.mem.Allocator;

pub const PaneId = ids.PaneId;
pub const PanelId = panel.PanelId;

/// // changed (sessions-card): `history` is the SESSIONS section's
/// ended-sessions chip (click toggles them in, right-click lists the
/// verbs).
pub const ChipKind = enum { sort, refresh, new, view, history };

/// // changed (sessions-merge): the ids a pane-hosted `ListPanel`
/// registers its parts under (`.script_hit{ pane, id }`): a row is
/// `row_base + idx`, its kebab `kebab_base + idx`, a header chip
/// `chip_base + @intFromEnum(kind)`, the filter pill `filter_id`; a
/// panel's own extra header chips pick ids below `chip_base`.
pub const ListHit = struct {
    pub const chip_base: u32 = 0x100;
    pub const filter_id: u32 = 0x1ff;
    pub const row_base: u32 = 0x1000;
    pub const kebab_base: u32 = 0x8000_0000;

    pub fn chip(kind: ChipKind) u32 {
        return chip_base + @intFromEnum(kind);
    }
    pub fn row(idx: u32) u32 {
        return row_base + idx;
    }
    pub fn kebab(idx: u32) u32 {
        return kebab_base + idx;
    }
    /// The chip an id names, if it is one.
    pub fn chipOf(id: u32) ?ChipKind {
        if (id < chip_base or id >= chip_base + @typeInfo(ChipKind).@"enum".fields.len) return null;
        return @enumFromInt(id - chip_base);
    }
};

/// A chip's target: the panel's own, or — hosted by a pane — the pane's
/// `.script_hit` with the chip's `ListHit` id.
pub fn chipTarget(panel_id: PanelId, kind: ChipKind, pane: ?PaneId) HitTarget {
    if (pane) |id| return .{ .script_hit = .{ .pane = id, .id = ListHit.chip(kind) } };
    return .{ .chip = .{ .panel = panel_id, .kind = kind } };
}

/// The parts of a dock widget (`app/dock.zig`).
/// // changed (panels): `.dock` joins the target set — the widgets
/// register their title / kebab / close / body here like any component.
pub const DockPart = enum { body, title, kebab, close };

/// // changed (launcher-dock): the parts of the LAUNCHER dock
/// (`app/launcher_dock.zig`, a different surface from the widgets
/// above): an item by its index in the strip, or the pin chip at its
/// end.
pub const LauncherDockPart = union(enum) { item: u16, pin };

/// The parts of the sidebar's info view (`ui/info_view.zig`): the kebab
/// on its title row, a `→ label` link row by its index, and the rest,
/// which swallows a press.
pub const InfoPart = union(enum) { body, kebab, try_it: u8 };

pub const Owner = union(enum) {
    pane: PaneId,
    panel: PanelId,
    /// The file tree's list (`ui/tree_view.zig`).
    tree,
    /// // changed (welcome): one of the start surface's lists
    /// (`ui/welcome.zig`).
    welcome: WelcomeList,
};

pub const Axis = enum { v, h };

/// A row of a list panel — shared by `.row` and `.kebab` so one
/// `switch` arm can capture both.
pub const PanelRow = struct { panel: PanelId, idx: u32 };

/// A tab on a leaf's strip, by the leaf's index and the tab's position
/// in it — shared by `.tab` and `.tab_close` so one arm captures both.
pub const TabRef = struct { leaf: u32, idx: u16 };

/// An editor row's gutter, by pane and 0-based line — shared by
/// `.gutter` and `.fold_arrow` so one arm captures both.
pub const GutterRef = struct { pane: PaneId, line: u32 };

/// The start surface's lists (`ui/welcome.zig`), in Tab order.
pub const WelcomeList = enum { workspaces, recent, sessions, shortcuts };

/// A row of the welcome pane (`ui/welcome.zig`): the `idx`-th entry of
/// a list — a workspace, a recent file (newest first), a session that
/// can be resumed, a shortcut — or the Sessions list's `+ New Claude
/// Code session here` row (`new_session`, `idx` 0).
pub const WelcomeRow = struct {
    kind: Kind,
    idx: u16,

    pub const Kind = enum { workspace, recent, session, new_session, shortcut };

    /// The list a row belongs to.
    pub fn list(r: WelcomeRow) WelcomeList {
        return switch (r.kind) {
            .workspace => .workspaces,
            .recent => .recent,
            .session, .new_session => .sessions,
            .shortcut => .shortcuts,
        };
    }
};

pub const HitTarget = union(enum) {
    pane: PaneId,
    divider: u32,
    tab: TabRef,
    /// The badge cells of a tab (`bufferline.zig`): the same leaf /
    /// index as the `.tab` it sits on; a press closes that pane.
    tab_close: TabRef,
    /// A segment of an editor's breadcrumb row (`editor_view.zig`):
    /// the `idx`-th path component; a press opens a Files pane at the
    /// directory it names (the file's own segment: its parent).
    breadcrumb: struct { pane: PaneId, idx: u16 },
    row: PanelRow,
    kebab: PanelRow,
    chip: struct { panel: PanelId, kind: ChipKind },
    filter_input: PanelId,
    scrollbar: struct { owner: Owner, axis: Axis },
    button: u32,
    link: struct { url: []const u8 },
    menu_item: struct { menu: u32, idx: u16 },
    statusline_seg: u32,
    /// // changed (statusline-hover): a row of the hover tooltip's
    /// list — one of the things the figure counts. `seg` is the
    /// statusline segment the tip came from (so the tip survives the
    /// pointer moving onto it), `idx` the row. A press runs what the
    /// row names. `x` / `y` are the cell the tip was anchored at, so
    /// the box does not walk away from under a pointer that moved onto
    /// one of its own rows.
    tip_row: struct { seg: u32, idx: u16, x: u16, y: u16 },
    /// A file tree entry, by its row index in the app's tree.
    tree_node: u32,
    /// A workspace section's header row (`ui/tree_view.zig`): 0 the
    /// primary, i + 1 the i-th extra root. A press folds the section.
    tree_root: u8,
    /// right-click: the tree's empty rows below the last item
    /// (`ui/tree_view.zig`), by the root they belong to. A press focuses
    /// the tree; a right press opens that root's workspace menu (Rust:
    /// the empty Explorer space opens the workspace header's menu).
    tree_empty: u8,
    /// A chip on the primary header, or the `Add workspace` row.
    tree_chip: tree_view.Chip,
    /// The sidebar's info view.
    info_view: InfoPart,
    script_hit: struct { pane: PaneId, id: u32 },
    /// A visible editor cell; `line` is the 0-based document line and
    /// `col` the byte offset of the grapheme under the cell within that
    /// line (the line's length for cells past its end).
    editor_cell: struct { pane: PaneId, line: u32, col: u32 },
    /// The gutter of an editor row (`editor_view.zig`), registered over
    /// the row's `.editor_cell` so it wins: a breakpoint's home.
    gutter: GutterRef,
    /// The fold chevron in an editor row's sign cell (`editor_view.zig`),
    /// registered over that row's `.gutter` so it wins the one cell it
    /// covers: a press toggles the fold on that line.
    fold_arrow: GutterRef,
    overlay_item: u32,
    dock: struct { id: u32, part: DockPart },
    /// // changed (launcher-dock): an item of the launcher dock, or its
    /// pin chip (`ui/launcher_dock_view.zig`).
    launcher_dock: LauncherDockPart,
    /// A row of the activity bar (`ui/activity_bar.zig`): a section's
    /// icon, or the settings gear at the bottom.
    rail: activity_bar.Part,
    welcome: WelcomeRow,
    /// The LSP hover / signature box (`ui/hover_view.zig`): the wheel
    /// scrolls its lines two at a time, a press puts it away.
    hover_popup,
    /// The git palette's repo pill and branch row (`ui/git_palette.zig`);
    /// its list rows are `.row{ .git }`.
    git_palette: git_palette.Part,
    /// The HTTP section's own targets (`ui/http_panel.zig`): a section
    /// header's chip, a link row, the ` + ` on a collection folder row;
    /// its list rows are `.row{ .http }`.
    http: http_panel.Part,
    /// The `↑ Update` chip of a FONTS row (`ui/fonts_section.zig`), by
    /// the row's index into the scanned families.
    font_update: u16,
    /// The AI grid's open slot (`app/ai_grid.zig`), by its layout
    /// node: the `+ Add Claude Code` card; a press opens the next
    /// session there.
    ai_placeholder: u32,
    /// One of the SEARCH section's header flags — `Aa` / `\b` / `.*`
    /// (`ui/search_section_view.zig`); a press toggles it and reruns.
    search_chip: search_section_view.Flag,

    /// `@tagName` plus the payload, colon-separated: `row:todos:3`,
    /// `editor_cell:0:12:4`, `scrollbar:panel:notes:v`.
    pub fn writeLabel(t: HitTarget, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(@tagName(t));
        switch (t) {
            .pane, .divider, .button, .statusline_seg, .tree_node, .overlay_item => |n| try w.print(":{d}", .{n}),
            .tree_root, .tree_empty => |n| try w.print(":{d}", .{n}),
            .hover_popup => {},
            .font_update, .ai_placeholder => |n| try w.print(":{d}", .{n}),
            .search_chip => |f| try w.print(":{s}", .{@tagName(f)}),
            .tree_chip => |c| try w.print(":{s}", .{@tagName(c)}),
            .info_view => |p| switch (p) {
                .try_it => |i| try w.print(":try_it:{d}", .{i}),
                else => try w.print(":{s}", .{@tagName(p)}),
            },
            .tip_row => |v| try w.print(":{d}:{d}", .{ v.seg, v.idx }),
            .tab, .tab_close => |v| try w.print(":{d}:{d}", .{ v.leaf, v.idx }),
            .breadcrumb => |v| try w.print(":{d}:{d}", .{ v.pane, v.idx }),
            .row, .kebab => |v| try w.print(":{s}:{d}", .{ @tagName(v.panel), v.idx }),
            .chip => |v| try w.print(":{s}:{s}", .{ @tagName(v.panel), @tagName(v.kind) }),
            .filter_input => |p| try w.print(":{s}", .{@tagName(p)}),
            .scrollbar => |v| {
                switch (v.owner) {
                    .pane => |id| try w.print(":pane:{d}", .{id}),
                    .panel => |p| try w.print(":panel:{s}", .{@tagName(p)}),
                    .tree => try w.writeAll(":tree"),
                    .welcome => |l| try w.print(":welcome:{s}", .{@tagName(l)}),
                }
                try w.print(":{s}", .{@tagName(v.axis)});
            },
            .link => |v| try w.print(":{s}", .{v.url}),
            .menu_item => |v| try w.print(":{d}:{d}", .{ v.menu, v.idx }),
            .script_hit => |v| try w.print(":{d}:{d}", .{ v.pane, v.id }),
            .editor_cell => |v| try w.print(":{d}:{d}:{d}", .{ v.pane, v.line, v.col }),
            .gutter, .fold_arrow => |v| try w.print(":{d}:{d}", .{ v.pane, v.line }),
            .dock => |v| try w.print(":{d}:{s}", .{ v.id, @tagName(v.part) }),
            .launcher_dock => |v| switch (v) {
                .item => |i| try w.print(":item:{d}", .{i}),
                .pin => try w.writeAll(":pin"),
            },
            .rail => |v| switch (v) {
                .section => |s| try w.print(":{s}", .{@tagName(s)}),
                .gear => try w.writeAll(":gear"),
                .pin => |i| try w.print(":pin:{d}", .{i}),
                .script => |i| try w.print(":script:{d}", .{i}),
            },
            .welcome => |v| try w.print(":{s}:{d}", .{ @tagName(v.kind), v.idx }),
            .git_palette => |v| try w.print(":{s}", .{@tagName(v)}),
            .http => |v| switch (v) {
                .chip => |c| try w.print(":chip:{s}:{s}", .{ @tagName(c.section), @tagName(c.kind) }),
                .link => |l| try w.print(":link:{s}", .{@tagName(l)}),
                .folder_new => |i| try w.print(":folder_new:{d}", .{i}),
            },
        }
    }
};

pub const HitMap = struct {
    pub const Entry = struct { rect: Rect, target: HitTarget };

    items: std.ArrayListUnmanaged(Entry) = .empty,

    /// Frame start. The entries lived on the frame arena, which the app
    /// resets; the list only forgets them.
    pub fn reset(h: *HitMap) void {
        h.items = .empty;
    }

    /// Registers `t` for `r`. Empty rects are skipped: they cannot be
    /// clicked and would only pad `rects.json`.
    pub fn add(h: *HitMap, arena: Allocator, r: Rect, t: HitTarget) Allocator.Error!void {
        if (r.isEmpty()) return;
        try h.items.append(arena, .{ .rect = r, .target = t });
    }

    /// Back to front: the last thing painted wins.
    pub fn at(h: *const HitMap, x: u16, y: u16) ?HitTarget {
        return if (h.entryAt(x, y)) |e| e.target else null;
    }

    /// Like `at`, with the rect — for callers that need the cell's
    /// offset inside its target (a scrollbar drag, a divider).
    pub fn entryAt(h: *const HitMap, x: u16, y: u16) ?Entry {
        var i = h.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = h.items.items[i];
            if (e.rect.contains(x, y)) return e;
        }
        return null;
    }

    /// `[{"label":"row:todos:3","x":1,"y":4,"w":28,"h":1},…]` in paint
    /// order — the `rects.json` shape the IPC channel publishes. Every
    /// registered hit is listed, the overlays' rows included: an
    /// `.overlay_item` is labelled with `overlay` — the open overlay's
    /// name (`picker:3`, `palette:0`, `settings:12`) — when the caller
    /// gives one, so a dump says which box a row belongs to rather than
    /// the generic `overlay_item:3` (a hunt read that as the overlays
    /// being missing from the file).
    pub fn writeRectsJson(h: *const HitMap, w: *std.Io.Writer, overlay: ?[]const u8) std.Io.Writer.Error!void {
        try w.writeByte('[');
        for (h.items.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"label\":\"");
            var lw: LabelWriter = .{ .out = w };
            if (overlay != null and e.target == .overlay_item) {
                try lw.writer.print("{s}:{d}", .{ overlay.?, e.target.overlay_item });
            } else try e.target.writeLabel(&lw.writer);
            try lw.writer.flush();
            try w.print("\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ e.rect.x, e.rect.y, e.rect.w, e.rect.h });
        }
        try w.writeByte(']');
    }
};

/// A writer that JSON-escapes what passes through it (a link's url may
/// carry a quote or a backslash).
const LabelWriter = struct {
    out: *std.Io.Writer,
    buf: [64]u8 = undefined,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LabelWriter = @alignCast(@fieldParentPtr("writer", w));
        var n: usize = 0;
        for (data, 0..) |chunk, i| {
            const reps: usize = if (i == data.len - 1) splat else 1;
            for (0..reps) |_| try self.escape(chunk);
            n += chunk.len * reps;
        }
        return n;
    }

    fn escape(self: *LabelWriter, s: []const u8) std.Io.Writer.Error!void {
        for (s) |c| switch (c) {
            '"' => try self.out.writeAll("\\\""),
            '\\' => try self.out.writeAll("\\\\"),
            '\n' => try self.out.writeAll("\\n"),
            '\r' => try self.out.writeAll("\\r"),
            '\t' => try self.out.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try self.out.print("\\u{x:0>4}", .{c}),
            else => try self.out.writeByte(c),
        };
    }
};

// ── tests ──

const testing = std.testing;

test "at scans back to front so the last painted target wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: HitMap = .{};
    try h.add(arena, Rect.init(0, 0, 10, 10), .{ .pane = 1 });
    try h.add(arena, Rect.init(2, 2, 3, 3), .{ .row = .{ .panel = .todos, .idx = 3 } });
    try h.add(arena, Rect.init(3, 3, 1, 1), .{ .overlay_item = 7 });

    try testing.expectEqual(@as(u32, 1), h.at(0, 0).?.pane);
    try testing.expectEqual(@as(u32, 3), h.at(2, 2).?.row.idx);
    try testing.expectEqual(@as(u32, 7), h.at(3, 3).?.overlay_item);
    try testing.expect(h.at(10, 10) == null);
    try testing.expect(h.entryAt(4, 4).?.rect.eql(Rect.init(2, 2, 3, 3)));
    h.reset();
    try testing.expect(h.at(0, 0) == null);
}

test "empty rects are not registered" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var h: HitMap = .{};
    try h.add(arena_state.allocator(), Rect.init(5, 5, 0, 1), .{ .button = 1 });
    try testing.expectEqual(@as(usize, 0), h.items.items.len);
}

fn expectLabel(expected: []const u8, t: HitTarget) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.writeLabel(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "labels are the tag plus the payload" {
    try expectLabel("pane:4", .{ .pane = 4 });
    try expectLabel("tab:0:2", .{ .tab = .{ .leaf = 0, .idx = 2 } });
    try expectLabel("tab_close:0:2", .{ .tab_close = .{ .leaf = 0, .idx = 2 } });
    try expectLabel("breadcrumb:3:1", .{ .breadcrumb = .{ .pane = 3, .idx = 1 } });
    try expectLabel("row:todos:3", .{ .row = .{ .panel = .todos, .idx = 3 } });
    try expectLabel("kebab:notes:0", .{ .kebab = .{ .panel = .notes, .idx = 0 } });
    try expectLabel("chip:findings:sort", .{ .chip = .{ .panel = .findings, .kind = .sort } });
    try expectLabel("filter_input:sessions", .{ .filter_input = .sessions });
    try expectLabel("scrollbar:pane:2:v", .{ .scrollbar = .{ .owner = .{ .pane = 2 }, .axis = .v } });
    try expectLabel("scrollbar:panel:todos:h", .{ .scrollbar = .{ .owner = .{ .panel = .todos }, .axis = .h } });
    try expectLabel("link:https://x.y/z", .{ .link = .{ .url = "https://x.y/z" } });
    try expectLabel("menu_item:1:5", .{ .menu_item = .{ .menu = 1, .idx = 5 } });
    try expectLabel("script_hit:3:9", .{ .script_hit = .{ .pane = 3, .id = 9 } });
    try expectLabel("editor_cell:0:12:4", .{ .editor_cell = .{ .pane = 0, .line = 12, .col = 4 } });
    try expectLabel("gutter:0:12", .{ .gutter = .{ .pane = 0, .line = 12 } });
    try expectLabel("fold_arrow:0:12", .{ .fold_arrow = .{ .pane = 0, .line = 12 } });
    try expectLabel("overlay_item:2", .{ .overlay_item = 2 });
    try expectLabel("statusline_seg:1", .{ .statusline_seg = 1 });
    try expectLabel("tree_node:8", .{ .tree_node = 8 });
    try expectLabel("divider:0", .{ .divider = 0 });
    try expectLabel("button:6", .{ .button = 6 });
    try expectLabel("rail:explorer", .{ .rail = .{ .section = .explorer } });
    try expectLabel("rail:sessions", .{ .rail = .{ .section = .sessions } });
    try expectLabel("rail:gear", .{ .rail = .gear });
    try expectLabel("rail:pin:2", .{ .rail = .{ .pin = 2 } });
    try expectLabel("launcher_dock:item:3", .{ .launcher_dock = .{ .item = 3 } });
    try expectLabel("launcher_dock:pin", .{ .launcher_dock = .pin });
    try expectLabel("git_palette:repo", .{ .git_palette = .repo });
    try expectLabel("git_palette:repo_next", .{ .git_palette = .repo_next });
    try expectLabel("http:chip:recent:clear", .{ .http = .{ .chip = .{ .section = .recent, .kind = .clear } } });
    try expectLabel("http:link:paste_curl", .{ .http = .{ .link = .paste_curl } });
    try expectLabel("http:folder_new:2", .{ .http = .{ .folder_new = 2 } });
    try expectLabel("tree_root:0", .{ .tree_root = 0 });
    try expectLabel("tree_chip:new_file", .{ .tree_chip = .new_file });
    try expectLabel("info_view:kebab", .{ .info_view = .kebab });
    try expectLabel("info_view:try_it:2", .{ .info_view = .{ .try_it = 2 } });
    try expectLabel("scrollbar:tree:v", .{ .scrollbar = .{ .owner = .tree, .axis = .v } });
}

test "rects.json shape, with a url that needs escaping" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: HitMap = .{};
    try h.add(arena, Rect.init(1, 4, 28, 1), .{ .row = .{ .panel = .todos, .idx = 3 } });
    try h.add(arena, Rect.init(0, 0, 5, 1), .{ .link = .{ .url = "a\"b\\c" } });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try h.writeRectsJson(&aw.writer, null);
    try testing.expectEqualStrings(
        "[{\"label\":\"row:todos:3\",\"x\":1,\"y\":4,\"w\":28,\"h\":1}," ++
            "{\"label\":\"link:a\\\"b\\\\c\",\"x\":0,\"y\":0,\"w\":5,\"h\":1}]",
        aw.written(),
    );

    // It parses back as JSON with the label intact.
    const parsed = try std.json.parseFromSlice([]const struct { label: []const u8, x: u16, y: u16, w: u16, h: u16 }, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expectEqualStrings("link:a\"b\\c", parsed.value[1].label);

    var empty: HitMap = .{};
    var ew: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ew.deinit();
    try empty.writeRectsJson(&ew.writer, null);
    try testing.expectEqualStrings("[]", ew.written());
}

test "rects.json names an overlay's rows after the overlay when one is open" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: HitMap = .{};
    try h.add(arena, Rect.init(0, 0, 5, 1), .{ .pane = 1 });
    try h.add(arena, Rect.init(2, 2, 20, 1), .{ .overlay_item = 3 });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try h.writeRectsJson(&aw.writer, "picker");
    try testing.expectEqualStrings(
        "[{\"label\":\"pane:1\",\"x\":0,\"y\":0,\"w\":5,\"h\":1}," ++
            "{\"label\":\"picker:3\",\"x\":2,\"y\":2,\"w\":20,\"h\":1}]",
        aw.written(),
    );
    // No overlay: the generic label.
    var bw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bw.deinit();
    try h.writeRectsJson(&bw.writer, null);
    try testing.expect(std.mem.indexOf(u8, bw.written(), "\"overlay_item:3\"") != null);
}
