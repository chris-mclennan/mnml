//! Discoverability: what every click target is, in words — and the
//! click-discovery panel.
//!
//! `describe` turns a `HitTarget` — the frame's own record of what it
//! painted — into a one-line title and a detail line. Two things read
//! it: the hover tooltip near the pointer (`ui.hover_tooltip`) and the
//! info view at the bottom of the left rail (`ui.hover_help`,
//! `app/info_view.zig`, for the targets it has no copy of its own for).
//!
//! `view.discovery` opens the panel the Rust editor has: a modal box a
//! third of the way down listing its eleven click-target families, each
//! with a green `[n]` count of the rects on screen right now (`[ ]` for
//! none) and what a click there does; a click on a row flashes the
//! matching rects yellow for two seconds; F1 / Esc / a click elsewhere
//! close it. The counts come from the hit map of the frame under the
//! box.
//!
//! The hover surfaces only wake on real pointer motion (`App.hover_live`,
//! set by a `.motion` / `.drag` report and cleared by a press), so a
//! scripted click never grows a box under itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const hit_mod = @import("../ui/hit.zig");
const HitTarget = hit_mod.HitTarget;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const tooltip = @import("../ui/tooltip.zig");
const statusline = @import("../ui/statusline.zig");
const statusline_app = @import("statusline.zig");
const toast_mod = @import("../ui/toast.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const render = @import("render.zig");
const md_preview = @import("md_preview.zig");
const integrations = @import("integrations.zig");
const command = @import("../core/command.zig");
const activity_bar = @import("activity_bar.zig");
const tree_mod = @import("tree.zig");
const git_toolbar = @import("../ui/git_toolbar.zig");
const overlay = @import("../ui/overlay.zig");

pub const Tip = tooltip.Tip;

/// The words for `target`, or null for a target with nothing to say.
pub fn describe(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?Tip {
    const f = struct {
        fn fmt(a: Allocator, comptime s: []const u8, args: anytype) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(a, s, args);
        }
    };
    return switch (target) {
        .pane => |id| .{
            .title = try f.fmt(arena, "Pane: {s}", .{if (app.panes.get(id)) |p| p.title() else "?"}),
            .detail = "click focuses · right-click: the pane's menu",
        },
        .divider => .{ .title = "Divider", .detail = "drag to resize" },
        .tab_close => .{ .title = "Close tab", .detail = "click closes this pane" },
        .breadcrumb => |bc| blk: {
            const e = app.panes.editor(bc.pane) orelse break :blk null;
            const path = e.buf.doc.path orelse break :blk null;
            const names = try render.breadcrumbNames(app, arena, path);
            if (bc.idx >= names.len) break :blk null;
            break :blk .{
                .title = try f.fmt(arena, "Breadcrumb: {s}", .{names[bc.idx]}),
                .detail = "click opens a Files pane at this directory",
            };
        },
        .dock => |d| .{
            .title = try f.fmt(arena, "Dock widget {d}", .{d.id}),
            .detail = "click focuses · drag the header moves it · right-click: widget menu",
        },
        .tab => |tb| blk: {
            const layout = app.layouts.current();
            const lid = (try layout.leafAt(arena, tb.leaf)) orelse break :blk null;
            const leaf = layout.leaf(lid) orelse break :blk null;
            if (tb.idx >= leaf.tabs.items.len) break :blk null;
            const p = app.panes.get(leaf.tabs.items[tb.idx]) orelse break :blk null;
            break :blk .{
                .title = try f.fmt(arena, "Tab: {s}{s}", .{ p.title(), if (p.dirty()) " (unsaved)" else "" }),
                .detail = "click shows · middle-click closes · right-click: tab menu · drag to move",
            };
        },
        .row => |pr| .{
            .title = try f.fmt(arena, "{s} row {d}", .{ upper(arena, @tagName(pr.panel)), pr.idx + 1 }),
            .detail = "click selects · double-click / Enter opens · right-click: row menu",
        },
        .kebab => |pr| .{
            .title = try f.fmt(arena, "{s} row menu", .{upper(arena, @tagName(pr.panel))}),
            .detail = "click opens the row's actions",
        },
        .chip => |c| switch (c.kind) {
            .sort => .{ .title = "sort: chip", .detail = "click cycles the order · right-click lists every mode" },
            .refresh => .{ .title = "Refresh", .detail = "click rescans the panel" },
            .new => .{ .title = "New", .detail = "click creates an item in this panel" },
            .view => .{ .title = "view: chip", .detail = "click cycles the row style" },
        },
        .filter_input => |p| .{
            .title = try f.fmt(arena, "{s} filter", .{upper(arena, @tagName(p))}),
            .detail = "type to narrow the rows · Esc clears",
        },
        .scrollbar => .{ .title = "Scrollbar", .detail = "drag the thumb · wheel scrolls" },
        .button => |id| try describeButton(app, arena, id),
        .link => |l| .{ .title = try f.fmt(arena, "Link: {s}", .{l.url}), .detail = "click opens it" },
        .menu_item => |mi| blk: {
            if (app.overlay != .menu) break :blk .{ .title = "Menu row", .detail = null };
            const m = &app.overlay.menu;
            const items = if (mi.menu == 1 or mi.menu == 3) (if (m.sub) |s| s.items else break :blk null) else m.items;
            if (mi.idx >= items.len) break :blk null;
            const it = items[mi.idx];
            break :blk .{
                .title = try f.fmt(arena, "Menu: {s}", .{it.label}),
                .detail = switch (it.action) {
                    .command => |cmd| command.name(cmd),
                    else => if (it.submenu.len > 0) "opens more rows" else null,
                },
            };
        },
        .statusline_seg => |seg| try describeSegment(app, arena, seg),
        .tree_node => |idx| blk: {
            if (idx >= app.tree.rows.items.len) break :blk null;
            const row = app.tree.rows.items[idx];
            break :blk .{
                .title = try f.fmt(arena, "{s}{s}", .{ row.rel, if (row.is_dir) "/" else "" }),
                .detail = if (row.is_dir) "click expands · right-click: folder menu" else "click opens · right-click: file menu · drag to move",
            };
        },
        .tree_root => |root| .{
            .title = if (root == 0) try f.fmt(arena, "Workspace: {s}", .{app.workspace}) else if (root - 1 < app.tree.roots.items.len) try f.fmt(arena, "Workspace: {s}", .{app.tree.roots.items[root - 1].path}) else "Workspace",
            .detail = if (root == 0) "click folds the tree · alt-click folds or opens every directory" else "click opens or folds this workspace's tree",
        },
        .tree_chip => |c| .{
            .title = c.label(app.tree.isFullyCollapsed()),
            .detail = try f.fmt(arena, "click runs {s}", .{command.name(tree_mod.chipCommand(c))}),
        },
        .git_palette => |part| switch (part) {
            .repo => .{ .title = "Repo", .detail = "click: switch repo · reopen a closed one · add a workspace" },
            .branch => .{ .title = "Branch", .detail = "click opens the checkout picker" },
        },
        .info_view => |part| switch (part) {
            .kebab => .{ .title = "Sidebar menu", .detail = "click: turn the info panel off" },
            .try_it => .{ .title = "Try it", .detail = "click runs the command the panel names" },
            .body => .{ .title = "Info panel", .detail = "what the pointer or the focus is on · wheel scrolls · Settings → UI hides it" },
        },
        .script_hit => |sh| .{
            .title = try f.fmt(arena, "{s} item", .{if (app.panes.get(sh.pane)) |p| @tagName(std.meta.activeTag(p.*)) else "pane"}),
            .detail = "click selects · click again acts",
        },
        // While the debugger is stopped, the word under the pointer shows
        // its value (the variables the last stop fetched, no round trip).
        .editor_cell => |cell| blk: {
            if (try @import("dap.zig").hoverValue(app, arena, cell.pane, cell.line, cell.col)) |tip| break :blk tip;
            break :blk .{
                .title = try f.fmt(arena, "Line {d}", .{cell.line + 1}),
                .detail = "click places the cursor · drag selects · right-click: editor menu",
            };
        },
        .gutter => |g| .{
            .title = try f.fmt(arena, "Line {d} gutter", .{g.line + 1}),
            .detail = "click the sign cell: toggle breakpoint · right-click: breakpoint menu",
        },
        .overlay_item => .{ .title = "Overlay item", .detail = "click chooses it" },
        .rail => |part| activity_bar.describe(part),
        .welcome => |row| switch (row.kind) {
            .recent => .{ .title = "Recent file", .detail = "click opens it" },
            .shortcut => .{ .title = "Shortcut", .detail = "click runs it" },
        },
    };
}

fn upper(arena: Allocator, s: []const u8) []const u8 {
    const out = arena.dupe(u8, s) catch return s;
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn describeButton(app: *App, arena: Allocator, id: u32) Allocator.Error!?Tip {
    if (id == md_preview.button_edit) return .{ .title = "Edit the markdown", .detail = "swaps the raw editor in (markdown.edit_raw)" };
    if (id == md_preview.button_preview) return .{ .title = "Preview the markdown", .detail = "opens the rendered preview (markdown.preview)" };
    if (id == toast_mod.undo_button) return .{
        .title = if (app.undo_chip) |u| try std.fmt.allocPrint(arena, "Undo: {s}", .{u.label}) else "Undo",
        .detail = "click puts it back · right-click drops the offer",
    };
    if (id >= toast_mod.button_base) return .{ .title = "Toast", .detail = "click dismisses · right-click: dismiss / copy / dismiss all" };
    if (id >= integrations_view.chip_base and id < integrations_view.chip_base + integrations_view.max_chips) {
        const list = try integrations.chips(app, arena);
        const i = id - integrations_view.chip_base;
        if (i < list.len) return .{
            .title = try std.fmt.allocPrint(arena, "{s}{s}", .{ list[i].tooltip, if (list[i].enabled) "" else " (disabled)" }),
            .detail = "click runs it · right-click: its menu",
        };
        return null;
    }
    if (render.Button.newTabLeaf(id) != null) return .{ .title = "+ New tab", .detail = "click opens a scratch buffer · right-click: the + menu (New / Open / Panels / Tools / Integrations)" };
    // The chrome row's words and buttons, the strip's split buttons.
    return @import("menu_bar.zig").describeButton(app, arena, id);
}

fn describeSegment(app: *App, arena: Allocator, seg: u32) Allocator.Error!?Tip {
    switch (seg) {
        statusline.seg_mode => return .{
            .title = try std.fmt.allocPrint(arena, "Mode — {s} keymap", .{@tagName(app.input_style)}),
            .detail = "click: toggle vim ⇄ standard · right-click: keymap menu",
        },
        statusline.seg_file => return .{ .title = "File", .detail = "the open file, ● when unsaved · right-click: copy the path / close the buffer" },
        statusline.seg_position => return .{ .title = "Position", .detail = "click: go to line" },
        statusline.seg_language => return .{ .title = "Language", .detail = "the file's language, by extension · click says so" },
        statusline.seg_restricted => return .{
            .title = "RESTRICTED — this workspace's exec-bearing settings are off",
            .detail = "click reviews what it wants to run (workspace.review_trust)",
        },
        else => {},
    }
    if (seg >= statusline.seg_dyn_base) return .{ .title = "Integration segment", .detail = "click runs the segment's command" };
    const id = statusline_app.SegId.of(seg) orelse return null;
    return switch (id) {
        .branch => blk: {
            var detail: std.ArrayListUnmanaged(u8) = .empty;
            try detail.appendSlice(arena, "click: status pane · right-click: git menu");
            if (app.git.status) |st| {
                if (st.ahead > 0) try detail.print(arena, " · ⇡{d} ahead", .{st.ahead});
                if (st.behind > 0) try detail.print(arena, " · ⇣{d} behind", .{st.behind});
                const c = statusline_app.fileCounts(st);
                if (c.added > 0) try detail.print(arena, " · {d} added", .{c.added});
                if (c.changed > 0) try detail.print(arena, " · {d} changed", .{c.changed});
                if (c.removed > 0) try detail.print(arena, " · {d} removed", .{c.removed});
                if (c.conflicts > 0) try detail.print(arena, " · {d} in conflict", .{c.conflicts});
            }
            break :blk .{ .title = try std.fmt.allocPrint(arena, "Branch {s}", .{app.git.branchLabel() orelse "?"}), .detail = detail.items };
        },
        .pr => .{ .title = "Pull request on this branch", .detail = "click opens it in the browser" },
        .diagnostics => .{ .title = "Diagnostics in this file", .detail = "click: the panel · right-click: next / previous / filter" },
        .symbol => .{ .title = "Enclosing symbol", .detail = "click: the outline pane" },
        .macro => .{ .title = "Recording a macro", .detail = "click stops it (q)" },
        .find => .{ .title = "Find", .detail = "the query and the match under the cursor · click reopens the find bar" },
        .test_run => .{ .title = "Test run", .detail = "click focuses the tests pane" },
        .ai_claude => .{ .title = "Claude — 24h spend", .detail = "click: today's report" },
        .ai_codex => .{ .title = "Codex — 24h spend", .detail = "click: today's report" },
        .coverage => .{ .title = "Coverage", .detail = "feature (F) and code (C) coverage from the trends files, with the move since last week / last commit · click toasts both · right-click picks the mode" },
        .transfer => .{ .title = "File transfers", .detail = "progress of the running copies · right-click: cancel all" },
        .lsp => .{ .title = "Language servers running", .detail = "click: the symbols in this file" },
        .wrap => .{ .title = "WRAP — long lines wrap", .detail = "click turns wrapping off" },
        .autosave => .{ .title = try std.fmt.allocPrint(arena, "Autosave every {d}s", .{app.cfg.editor.autosave_secs}), .detail = "`[editor] autosave_secs` sets it" },
        .filesize => .{ .title = "File size", .detail = "the buffer's bytes in memory · click: bytes and lines" },
        .sel => .{ .title = "Selection", .detail = "characters selected" },
        .stress => blk: {
            const st = app.stress.stats() orelse break :blk .{ .title = "Frame time", .detail = "no frames sampled yet" };
            break :blk .{
                .title = try std.fmt.allocPrint(arena, "Frame time — p50 {d}.{d}ms · p95 {d}.{d}ms · max {d}.{d}ms · n={d}", .{
                    st.p50_us / 1000, (st.p50_us % 1000) / 100,
                    st.p95_us / 1000, (st.p95_us % 1000) / 100,
                    st.max_us / 1000, (st.max_us % 1000) / 100,
                    st.count,
                }),
                .detail = "click toasts the numbers · right-click: copy / reset / hide",
            };
        },
        .bell => blk: {
            const u = app.messages.unread();
            break :blk .{
                .title = if (u.err + u.warn == 0) "Messages — nothing unread" else try std.fmt.allocPrint(arena, "Messages — {d} unread ({d} errors)", .{ u.err + u.warn, u.err }),
                .detail = "click: the history · right-click: clear",
            };
        },
        .clock => .{ .title = "Clock", .detail = "local time (a Z is UTC) · click: local ⇄ UTC · right-click: local / UTC / hide" },
        .workspace => .{ .title = "Workspace", .detail = "click: switch workspace (or the active repo, with several)" },
        _ => null,
    };
}

// ─── the hover surfaces ─────────────────────────────────────────────────

/// The tip under the pointer, from the frame that is being painted (its
/// hits are complete by the time this runs). Null unless the pointer
/// really moved there.
pub fn hoverTip(app: *App, arena: Allocator) Allocator.Error!?Tip {
    if (!app.hover_live) return null;
    const h = app.hover orelse return null;
    const target = app.hits.at(h.x, h.y) orelse return null;
    return describe(app, arena, target);
}

/// The popup (`ui.hover_tooltip`), after everything else.
pub fn drawTooltip(app: *App, ui: Ui, screen: Rect) Allocator.Error!void {
    if (!app.cfg.ui.hover_tooltip or app.overlay == .info or app.overlay == .discovery) return;
    const h = app.hover orelse return;
    const tip = (try hoverTip(app, ui.arena)) orelse return;
    tooltip.draw(ui, screen, h.x, h.y, tip);
}

// ─── the F1 overlay ─────────────────────────────────────────────────────

/// Every hit the frame registered, tinted and labelled; a title row on
/// top says what a click will do now.
/// Rust's `DiscoveryCategory`, in the panel's row order.
pub const Category = enum(u8) {
    statusline_mode,
    statusline_branch,
    statusline_workspace,
    statusline_clock,
    bufferline_tabs,
    rail_git_header,
    editor_gutter,
    diff_toolbar,
    fold_chips,
    code_lens_chips,
    split_dividers,

    pub const count = @typeInfo(Category).@"enum".fields.len;

    pub fn label(c: Category) []const u8 {
        return switch (c) {
            .statusline_mode => "Mode chip",
            .statusline_branch => "Branch chip",
            .statusline_workspace => "Workspace chip",
            .statusline_clock => "Clock chip",
            .bufferline_tabs => "Bufferline tabs",
            .rail_git_header => "> GIT rail header",
            .editor_gutter => "Editor gutter",
            .diff_toolbar => "Diff toolbar",
            .fold_chips => "Fold chips (⋯)",
            .code_lens_chips => "Code-lens chips (⚡)",
            .split_dividers => "Split dividers",
        };
    }

    pub fn detail(c: Category) []const u8 {
        return switch (c) {
            .statusline_mode => "click: toggle vim/standard · right-click: input menu",
            .statusline_branch => "click: commit graph · right-click: git ops menu",
            .statusline_workspace => "click: switch repo · right-click: workspace menu",
            .statusline_clock => "click: local↔UTC · right-click: clock menu",
            .bufferline_tabs => "click: focus · middle: close · right-click: tab menu",
            .rail_git_header => "Fetch / Pull / Push / Stage all / Commit / Graph",
            .editor_gutter => "right-click line: breakpoint / goto def / refs / blame…",
            .diff_toolbar => "Hunk / Inline / Split / Wrap / Close chips",
            .fold_chips => "click to expand the folded block",
            .code_lens_chips => "click to run the lens command",
            .split_dividers => "hover turns yellow · drag to resize",
        };
    }

    /// Whether `target` belongs to the family. The GIT rail header,
    /// the gutter, the fold and code-lens chips register no hit of
    /// their own here, so those rows count nothing.
    pub fn owns(c: Category, target: HitTarget) bool {
        const SegId = statusline_app.SegId;
        return switch (c) {
            .statusline_mode => target == .statusline_seg and target.statusline_seg == statusline.seg_mode,
            .statusline_branch => target == .statusline_seg and target.statusline_seg == SegId.branch.raw(),
            .statusline_workspace => target == .statusline_seg and target.statusline_seg == SegId.workspace.raw(),
            .statusline_clock => target == .statusline_seg and target.statusline_seg == SegId.clock.raw(),
            .bufferline_tabs => target == .tab,
            .diff_toolbar => target == .script_hit and target.script_hit.id >= git_toolbar.hit_base and target.script_hit.id < git_toolbar.hit_base + 0x100_0000,
            // The sidebar's and the right panel's dividers are chrome, not splits.
            .split_dividers => target == .divider and target.divider != render.tree_divider_id and target.divider != render.right_divider_id,
            .editor_gutter => target == .gutter,
            .rail_git_header, .fold_chips, .code_lens_chips => false,
        };
    }
};

pub const flash_ms: i64 = 2000;

/// A row's flash: the family and when it ends (`App.discovery_flash`).
pub const Flash = struct { cat: Category, until_ms: i64 };

pub const title = " Click Discovery — F1 / Esc to close · click row to flash ";
pub const legend = " green count = visible now · click row to flash rects ";

/// The rects on screen for `cat`, from the frame's hit map.
fn countOf(app: *App, cat: Category) usize {
    var n: usize = 0;
    for (app.hits.items.items) |e| if (cat.owns(e.target)) {
        n += 1;
    };
    return n;
}

/// Rust's `discovery::draw` — the panel, then the flash on top. Every
/// row registers `.overlay_item(i)` with its category's index.
pub fn drawOverlay(app: *App, ui: Ui, screen: Rect) void {
    const th = ui.theme;
    // The counts are of the frame under the box: read before the
    // panel's own hits join the map.
    var counts: [Category.count]usize = undefined;
    inline for (@typeInfo(Category).@"enum".fields, 0..) |f, i| counts[i] = countOf(app, @enumFromInt(f.value));
    var inner_w: u16 = 0;
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const c: Category = @enumFromInt(f.value);
        inner_w = @max(inner_w, ui.width(c.label()) + 2 + ui.width(c.detail()) + 6);
    }
    inner_w = @max(inner_w, ui.width(title) + 4);
    const w: u16 = @min(inner_w + 4, screen.w);
    const h: u16 = @min(@as(u16, Category.count) + 4, screen.h);
    const inner = overlay.boxLook(ui, screen, w, h, std.mem.trim(u8, title, " "), .third, .modal);
    if (inner.isEmpty()) return;
    const bg = th.overlay_bg.bg;
    const flash: ?Category = if (app.discovery_flash) |f| (if (app.now_ms < f.until_ms) f.cat else null) else null;
    var live_count = Theme.onBg(th.chip_active, th.info_fg.fg);
    live_count.bold = true;
    var flash_count = Theme.onBg(th.chip_active, th.warn_fg.fg);
    flash_count.bold = true;
    const dead_count = Theme.onBg(th.muted, th.chip.bg);
    inline for (@typeInfo(Category).@"enum".fields, 0..) |f, i| {
        if (i < inner.h -| 1) {
            const c: Category = @enumFromInt(f.value);
            const r = inner.row(@intCast(i));
            const live = counts[i] > 0;
            const flashing = flash != null and flash.? == c;
            const chip = if (live) ui.fmt("[{d}]", .{counts[i]}) else "[ ]";
            var x = r.x + 1;
            x += ui.putStr(x, r.y, r.right() -| x, chip, if (flashing) flash_count else if (live) live_count else dead_count);
            x += 2;
            var label_style = if (flashing) Theme.onBg(th.warn_fg, bg) else if (live) Theme.onBg(th.fg, bg) else Theme.onBg(th.muted, bg);
            label_style.bold = flashing or live;
            label_style.ul_style = if (flashing) .single else .off;
            x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(c.label(), r.right() -| x), label_style);
            x += 2;
            var detail_style = Theme.onBg(th.muted, bg);
            if (!live) detail_style.dim = true;
            _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(c.detail(), r.right() -| x), detail_style);
            ui.hit(r, .{ .overlay_item = @intCast(i) });
        }
    }
    if (inner.h > Category.count) {
        const lr = inner.row(Category.count);
        var legend_style = Theme.onBg(th.muted, bg);
        legend_style.italic = true;
        _ = ui.putStr(lr.x, lr.y, lr.w, ui.clipStr(legend, lr.w), legend_style);
    }
    if (flash) |cat| drawFlash(app, ui, cat);
}

/// A yellow band over every rect of the flashing family — over the
/// panel too, as Rust paints it last.
fn drawFlash(app: *App, ui: Ui, cat: Category) void {
    const th = ui.theme;
    var band = Theme.onBg(th.chip_active, th.warn_fg.fg);
    band.bold = true;
    // The hit map grows as the panel paints; the flash reads the
    // targets that were there before it.
    for (app.hits.items.items) |e| if (cat.owns(e.target) and !e.rect.isEmpty()) ui.fill(e.rect, band);
}

/// A press on row `i` of the panel: flash its family for two seconds.
pub fn flashRow(app: *App, i: usize) void {
    if (i >= Category.count) return;
    app.discovery_flash = .{ .cat = @enumFromInt(i), .until_ms = app.now_ms + flash_ms };
    app.needs_render = true;
}

/// The flash's end, from `App.tick`.
pub fn tick(app: *App, now: i64) void {
    if (app.discovery_flash) |f| if (now >= f.until_ms) {
        app.discovery_flash = null;
        app.needs_render = true;
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "describe: every hit kind has words; the statusline ids each say what a click does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    try app.render();
    const arena = app.frame.allocator();
    const Tag = std.meta.Tag(HitTarget);
    var seen = std.enums.EnumSet(Tag).initEmpty();
    for (app.hits.items.items) |e| {
        const tip = try describe(&app, arena, e.target);
        try t.expect(tip != null);
        seen.insert(std.meta.activeTag(e.target));
    }
    try t.expect(seen.contains(.tab) and seen.contains(.statusline_seg) and seen.contains(.button) and seen.contains(.editor_cell) and seen.contains(.pane));
    const mode = (try describe(&app, arena, .{ .statusline_seg = statusline.seg_mode })).?;
    try t.expect(std.mem.indexOf(u8, mode.title, "standard") != null);
    try t.expect(std.mem.indexOf(u8, mode.detail.?, "toggle vim") != null);
    const restricted = (try describe(&app, arena, .{ .statusline_seg = statusline.seg_restricted })).?;
    try t.expect(std.mem.indexOf(u8, restricted.detail.?, "review_trust") != null);
    const wrap = (try describe(&app, arena, .{ .statusline_seg = statusline_app.SegId.wrap.raw() })).?;
    try t.expect(std.mem.indexOf(u8, wrap.title, "WRAP") != null);
    const stress = (try describe(&app, arena, .{ .statusline_seg = statusline_app.SegId.stress.raw() })).?;
    try t.expect(std.mem.indexOf(u8, stress.title, "p95") != null);
    const tab = (try describe(&app, arena, .{ .tab = .{ .leaf = 0, .idx = 0 } })).?;
    try t.expect(std.mem.indexOf(u8, tab.title, "[scratch]") != null);
    try t.expect((try describe(&app, arena, .{ .tab = .{ .leaf = 0, .idx = 9 } })) == null);
    _ = id;
    const plus = (try describe(&app, arena, .{ .button = render.Button.newTab(0) })).?;
    try t.expect(std.mem.indexOf(u8, plus.detail.?, "Panels") != null);
}

test "view.discovery: Rust's panel — the families with their counts, a row press flashes, F1 / Esc / a press elsewhere close" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .help);
    try app.handle(.{ .key = Key.named(.esc) });
    try command.run(&app, .{ .static = .@"view.discovery" });
    try t.expect(app.overlay == .discovery);
    const text = try screenText(&app);
    defer t.allocator.free(text);
    // The statusline's four chips are on screen: [1] each; no tabs: [ ].
    try t.expect(std.mem.indexOf(u8, text, "┌ Click Discovery — F1 / Esc to close · click row to flash ─") != null);
    try t.expect(std.mem.indexOf(u8, text, "[1]  Mode chip  click: toggle vim/standard · right-click: input menu") != null);
    try t.expect(std.mem.indexOf(u8, text, "[1]  Clock chip  click: local↔UTC · right-click: clock menu") != null);
    try t.expect(std.mem.indexOf(u8, text, "[ ]  Bufferline tabs  click: focus · middle: close · right-click: tab menu") != null);
    try t.expect(std.mem.indexOf(u8, text, "[ ]  Split dividers  hover turns yellow · drag to resize") != null);
    try t.expect(std.mem.indexOf(u8, text, "green count = visible now · click row to flash rects") != null);
    // The rows are hits by category; a press flashes for two seconds.
    // h 15, a third down: y 8; row 0 on 9.
    try t.expectEqual(@as(u32, 0), app.hits.at(40, 9).?.overlay_item);
    try app.handle(.{ .mouse = .{ .x = 40, .y = 9, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .discovery);
    try t.expect(app.discovery_flash != null);
    try t.expect(app.discovery_flash.?.cat == .statusline_mode);
    try app.render();
    try app.tick(app.now_ms + flash_ms + 1);
    try t.expect(app.discovery_flash == null);
    // F1 closes; so does a press off the panel.
    try app.handle(.{ .key = Key.named(.{ .f = 1 }) });
    try t.expect(app.overlay == .none);
    try command.run(&app, .{ .static = .@"view.discovery" });
    try app.render();
    try app.handle(.{ .mouse = .{ .x = 60, .y = 2, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
}

test "hover: the popup and the rail's info box wake on motion over a chip, and only on motion" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24, .cfg = .{ .ui = .{ .hover_tooltip = true } } });
    defer app.deinit();
    _ = try app.openScratch();
    try app.render();
    var mode_rect: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .statusline_seg and e.target.statusline_seg == statusline.seg_mode) {
        mode_rect = e.rect;
    };
    // A press there is not a hover.
    try app.handle(.{ .mouse = .{ .x = mode_rect.?.x, .y = mode_rect.?.y, .kind = .press, .button = .middle } });
    const pressed = try screenText(&app);
    defer t.allocator.free(pressed);
    try t.expect(std.mem.indexOf(u8, pressed, "toggle vim") == null);
    // Motion is.
    try app.handle(.{ .mouse = .{ .x = mode_rect.?.x, .y = mode_rect.?.y, .kind = .motion } });
    try t.expect(app.hover_live);
    const hovered = try screenText(&app);
    defer t.allocator.free(hovered);
    try t.expect(std.mem.indexOf(u8, hovered, "toggle vim") != null);
    // The rail's box carries the same words (ui.hover_help is on by default).
    try t.expect(std.mem.indexOf(u8, hovered, "Mode") != null);
    // Off the chip: nothing.
    try app.handle(.{ .mouse = .{ .x = 50, .y = 5, .kind = .motion } });
    const away = try screenText(&app);
    defer t.allocator.free(away);
    try t.expect(std.mem.indexOf(u8, away, "toggle vim") == null);
}
