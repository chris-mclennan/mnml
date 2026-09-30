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
const ghost_chip = @import("ghost_chip.zig");
const jobs_app = @import("jobs.zig");
const syntax = @import("syntax.zig");
const toast_mod = @import("../ui/toast.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const render = @import("render.zig");
const md_preview = @import("md_preview.zig");
const integrations = @import("integrations.zig");
const command = @import("../core/command.zig");
const activity_bar = @import("activity_bar.zig");
const lsp_app = @import("lsp.zig");
const lsp_types = @import("../lsp/types.zig");
const tree_mod = @import("tree.zig");
const git_toolbar = @import("../ui/git_toolbar.zig");
const overlay = @import("../ui/overlay.zig");

pub const Tip = tooltip.Tip;
pub const Row = tooltip.Row;

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
        .divider => |id| if (id == render.info_divider_id)
            .{ .title = "Info panel's edge", .detail = "drag to give the info panel more rows or fewer · double-click: the default height" }
        else
            .{ .title = "Divider", .detail = "drag to resize" },
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
        // // changed (launcher-dock): the strip's own copy — the side
        // edges paint no label, so the tip is where the name lives.
        .launcher_dock => |part| try @import("launcher_dock.zig").describe(app, arena, part),
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
        .row => |pr| if (pr.panel == .sessions and try @import("../sessions.zig").hoverTip(app, arena, pr.idx) != null)
            (try @import("../sessions.zig").hoverTip(app, arena, pr.idx)).?
        else if (pr.panel == .git and try @import("git_palette.zig").hoverTip(app, arena, pr.idx) != null)
            (try @import("git_palette.zig").hoverTip(app, arena, pr.idx)).?
        else
            .{
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
            .history => .{ .title = "Ended sessions", .detail = "click shows / hides the ended sessions · right-click: show, hide, clear" },
        },
        .filter_input => |p| if (p == .search) .{
            .title = "SEARCH query",
            .detail = "type the query · Enter runs it · Esc clears",
        } else .{
            .title = try f.fmt(arena, "{s} filter", .{upper(arena, @tagName(p))}),
            .detail = "type to narrow the rows · Esc clears",
        },
        .search_chip => |flag| .{
            .title = switch (flag) {
                .case_sensitive => "Aa — case-sensitive",
                .whole_word => "\\b — whole word",
                .regex => ".* — regex",
            },
            .detail = "click toggles the flag and runs the query again",
        },
        .scrollbar => .{ .title = "Scrollbar", .detail = "drag the thumb · wheel scrolls" },
        .hover_popup => .{ .title = "Hover", .detail = "wheel scrolls two lines · click closes" },
        .ai_placeholder => .{ .title = "Add Claude Code", .detail = "click opens the next session in this slot" },
        .session_changes => .{ .title = "What this session changed", .detail = "click opens its files since it started" },
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
        // The pointer moved onto the tip's own list: the tip is the
        // segment's, unchanged — anything else would make the rows
        // flicker away as the pointer reached them.
        .tip_row => |r| try describeSegment(app, arena, r.seg),
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
        .tree_root_dot => |root| .{
            .title = if (app.tree.active_root == root) "Active workspace" else "Workspace",
            .detail = "click makes this the active workspace · right-click: the workspace menu",
        },
        .tree_empty => .{ .title = "Workspace", .detail = "click focuses the tree · right-click: the workspace menu" },
        .tree_chip => |c| .{
            .title = c.label(app.tree.isFullyCollapsed()),
            .detail = try f.fmt(arena, "click runs {s}", .{command.name(tree_mod.chipCommand(c))}),
        },
        .http => |part| switch (part) {
            // Rust's `info_view_copy.rs` words for the HTTP section's chips.
            .chip => |c| switch (c.kind) {
                .filter => .{ .title = "HTTP section mini-button", .detail = "Filter for ONE section of the HTTP panel — click puts the keys in the filter. The header row beside it collapses the whole section." },
                .refresh => .{ .title = "HTTP: refresh list", .detail = "Rescan collections / files / envs / captured / mocks and rebuild the HTTP panel. Same as the palette command http.refresh." },
                .capture => .{ .title = "HTTP: start capture", .detail = "Launch the browser pane and start capturing its network log into CAPTURED (http.capture_start)." },
                .clear => switch (c.section) {
                    .recent => .{ .title = "HTTP: clear recent", .detail = "Truncate .rqst/history.jsonl — every RECENT row goes (http.clear_recent)." },
                    .captured => .{ .title = "HTTP: clear captured", .detail = "Truncate the captured log — every CAPTURED row goes (http.clear_captured)." },
                    .cookies => .{ .title = "Cookies: clear jar", .detail = "Empty the cookie jar (cookies.clear)." },
                    else => .{ .title = "HTTP section mini-button", .detail = "Clear the panel filter for this section." },
                },
                .new => switch (c.section) {
                    .envs => .{ .title = "HTTP: new env", .detail = "Create a new .env in .mnml/env/ (http.new_env)." },
                    else => .{ .title = "HTTP: new collection", .detail = "Create a new request collection under .mnml/collections/ (http.new_collection)." },
                },
            },
            .link => |l| switch (l) {
                .new_request => .{ .title = "New HTTP request", .detail = "Opens a blank Request pane as a new tab (http.new)." },
                .paste_curl => .{ .title = "Paste curl", .detail = "Paste a curl command from the clipboard into a Request pane (http.paste_curl)." },
                .import => .{ .title = "Import", .detail = "Import a Postman collection or a HAR file from the clipboard." },
                .new_env => .{ .title = "HTTP: new env", .detail = "Create a new .env in .mnml/env/ (http.new_env)." },
                .new_chain => .{ .title = "HTTP: new chain", .detail = "Create a new .chain.json in .mnml/chains/ (http.new_chain)." },
                .new_collection => .{ .title = "HTTP: new collection", .detail = "Create a new request collection under .mnml/collections/ (http.new_collection)." },
            },
            .folder_new => .{ .title = "New request in collection", .detail = "Opens a blank Request pane whose Ctrl+S lands as req-N.http inside this collection's folder — the fastest way to add a request without leaving the HTTP panel." },
        },
        .font_update => .{ .title = "Update font", .detail = "click: the Homebrew command that brings this Nerd Font family to the latest release, in a terminal pane below" },
        .git_palette => |part| switch (part) {
            .repo => .{ .title = "Repo", .detail = "click: the repos menu — switch repo, All repos (every open repo's rows at once; git.palette_all), reopen a closed one, add a workspace · right-click: the repo's colour" },
            .repo_prev => .{ .title = "Previous repo", .detail = "click: the previous repo in discovery order, wrapping ([)" },
            .repo_next => .{ .title = "Next repo", .detail = "click: the next repo in discovery order, wrapping (])" },
        },
        .info_view => |part| switch (part) {
            .kebab => .{ .title = "Sidebar menu", .detail = "click: turn the info panel off" },
            .pin => .{ .title = "Pin the entry", .detail = "click: hold what the panel shows wherever the pointer goes · again to unpin (help.pin_toggle)" },
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
        .fold_arrow => |g| .{
            .title = try f.fmt(arena, "Line {d} fold", .{g.line + 1}),
            .detail = "click toggles the fold on this line",
        },
        .overlay_item => .{ .title = "Overlay item", .detail = "click chooses it" },
        .rail => |part| try activity_bar.describeIn(app, arena, part),
        .welcome => |row| switch (row.kind) {
            .workspace => .{ .title = "Recent workspace", .detail = "click shows it in the tree" },
            .recent => .{ .title = "Recent file", .detail = "click opens it" },
            .session => .{ .title = "Session", .detail = "click resumes it" },
            .new_session => .{ .title = "New Claude Code session", .detail = "click starts one here" },
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
    if (id == @import("zon_pane.zig").button_view) return .{ .title = "View the ZON as a tree", .detail = "opens the field tree beside the text (zon.view)" };
    if (id == @import("zon_pane.zig").button_source) return .{ .title = "Back to the ZON source", .detail = "reveals the raw editor tab (zon.source)" };
    if (id == toast_mod.undo_button) return .{
        .title = if (app.undo_chip) |u| try std.fmt.allocPrint(arena, "Undo: {s}", .{u.label}) else "Undo",
        .detail = "click puts it back · right-click drops the offer",
    };
    if (id >= toast_mod.button_base) return .{ .title = "Toast", .detail = "click dismisses · right-click: dismiss / copy / dismiss all" };
    // // changed (bottom-row): the row under the statusline.
    if (id == @intFromEnum(render.Button.cmdline_bar)) return .{ .title = "Command line", .detail = "click opens the `:` line (Ctrl+;)" };
    if (id == @intFromEnum(render.Button.cmdline_inflight)) return .{ .title = "Work in flight", .detail = "click aborts every in-flight send (http.abort)" };
    if (id == @intFromEnum(render.Button.cmdline_mention)) return .{ .title = "The pane this message names", .detail = "click reveals it" };
    // // changed (edge-grip): the `⋯` / `⋮` handle at the middle of a
    // hidden slide-in's edge (`ui/edge_grip.zig`). The words say what
    // the handle is for, since the glyph alone cannot.
    if (id == @intFromEnum(render.Button.edge_grip_menu_bar)) return .{
        .title = "The menu bar hides here",
        .detail = "rest here to bring the words back \u{b7} click keeps them (view.menu_bar_pin) \u{b7} right-click: the bar's modes",
    };
    if (id == @intFromEnum(render.Button.edge_grip_sidebar_left) or id == @intFromEnum(render.Button.edge_grip_sidebar_right)) return .{
        .title = "The side column hides here",
        .detail = "rest here to slide it in \u{b7} click docks it for this session (view.sidebar_pin) \u{b7} right-click: the column's modes",
    };
    if (id == @intFromEnum(render.Button.session_prev)) return .{ .title = "Previous session", .detail = "click: the session before this one in the ring, on whichever page holds it (ai.focus_prev_session)" };
    if (id == @intFromEnum(render.Button.session_next)) return .{ .title = "Next session", .detail = "click: the session after this one in the ring, on whichever page holds it (ai.focus_next_session)" };
    if (id == @intFromEnum(render.Button.edge_grip_dock)) return .{
        .title = "The launcher dock hides here",
        .detail = "rest here to bring the strip up \u{b7} click keeps it (view.dock_pin) \u{b7} right-click: its mode, edge and settings",
    };
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

/// A diagnostic's message up to its first newline — a row is a row.
fn firstLine(msg: []const u8) []const u8 {
    return msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len];
}

/// What a figure's hover lists, capped at `statusline.hover_items`
/// with the rest counted. `row_seg` is null when nothing is listed, so
/// a tip with no rows registers no hits at all.
pub const Listed = struct {
    rows: []const Row = &.{},
    more: usize = 0,
    row_seg: ?u32 = null,
};

/// `rows`, capped. `total` is how many there really are when the
/// caller had more than it handed over (an integration sends the first
/// few of a longer list); 0 means `rows.len` is the whole of it.
pub fn capped(app: *const App, seg: u32, rows: []const Row, total: usize) Listed {
    const cap: usize = app.cfg.statusline.hover_items;
    if (cap == 0 or rows.len == 0) return .{};
    const shown = @min(rows.len, cap);
    const whole = @max(total, rows.len);
    return .{ .rows = rows[0..shown], .more = whole - shown, .row_seg = seg };
}

/// A host segment's rows, from what it already knows. The `total` is
/// the real count behind the figure, which is often larger than the
/// rows the caller could cheaply build.
fn segmentRows(app: *App, arena: Allocator, items: []const @import("../ipc/effects.zig").Item, seg: u32) Allocator.Error!Listed {
    if (items.len == 0) return .{};
    var rows = try arena.alloc(Row, items.len);
    for (items, 0..) |it, i| rows[i] = .{
        .text = it.text,
        .sub = it.sub,
        .command = if (it.command) |c| c else null,
        .args = @ptrCast(it.args),
    };
    return capped(app, seg, rows, 0);
}

fn describeSegment(app: *App, arena: Allocator, seg: u32) Allocator.Error!?Tip {
    switch (seg) {
        statusline.seg_mode => return .{
            .title = try std.fmt.allocPrint(arena, "Mode — {s} keymap", .{@tagName(app.input_style)}),
            .detail = "click: toggle vim ⇄ standard · right-click: keymap menu",
        },
        statusline.seg_file => return .{ .title = "File", .detail = "the open file, ● when unsaved · right-click: copy the path / close the buffer" },
        statusline.seg_position => return .{ .title = "Position", .detail = "click: go to line" },
        statusline.seg_language => return .{ .title = "Language", .detail = "the file's language, by name, extension or shebang · click says how" },
        statusline.seg_restricted => return if (app.workspace_toml != null and (app.loaded == null or app.loaded.?.trust_prompt == null)) .{
            .title = "RESTRICTED — this workspace's .mnml/config.toml is mnml 0.2's and is not read",
            .detail = "run `mnml export-config-zon --out .mnml/config.zon` (0.2.22) in the workspace to convert it · click says so (workspace.review_trust)",
        } else .{
            .title = "RESTRICTED — this workspace's exec-bearing settings are off",
            .detail = "click reviews what it wants to run (workspace.review_trust)",
        },
        else => {},
    }
    if (seg >= statusline.seg_dyn_base) {
        // The publisher's own words when it sent any — a count is worth
        // little without what it counts.
        const slot = seg - statusline.seg_dyn_base;
        const segs = app.ipc_fx.segments.items;
        if (slot < segs.len) {
            const polled = app.integration_poll.jobForSegment(segs[slot].id) != null;
            const busy = polled and app.integration_poll.segmentBusy(segs[slot].id);
            const detail: []const u8 = if (busy) "refreshing… · click runs the segment's command · right-click: Refresh now" else if (polled) "click runs the segment's command · right-click: Refresh now" else "click runs the segment's command";
            const listed = try segmentRows(app, arena, segs[slot].items, seg);
            if (segs[slot].tooltip) |tip| {
                // The publisher's hover text is one line per newline:
                // the first is the title, the rest sit under the
                // detail (the shared bucket's own two lines).
                var it = std.mem.splitScalar(u8, tip, '\n');
                const head = try arena.dupe(u8, it.first());
                var rest: std.ArrayListUnmanaged([]const u8) = .empty;
                while (it.next()) |l| try rest.append(arena, try arena.dupe(u8, l));
                return .{
                    .title = head,
                    .detail = detail,
                    .lines = rest.items,
                    .rows = listed.rows,
                    .more = listed.more,
                    .row_seg = listed.row_seg,
                };
            }
            if (polled or listed.rows.len > 0) return .{
                .title = "Integration segment",
                .detail = detail,
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        }
        return .{ .title = "Integration segment", .detail = "click runs the segment's command" };
    }
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
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            if (app.git.status) |st| for (st.entries) |en| try rows.append(arena, .{
                .text = try arena.dupe(u8, en.path),
                .sub = try std.fmt.allocPrint(arena, "{c}", .{en.code}),
                .command = "git.status_pane",
            });
            const listed = capped(app, seg, rows.items, 0);
            break :blk .{
                .title = try std.fmt.allocPrint(arena, "Branch {s}", .{app.git.headLabel() orelse "?"}),
                .detail = detail.items,
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .pr => .{ .title = "Pull request on this branch", .detail = "click opens it in the browser" },
        .diagnostics => blk: {
            // What the count counts: the problems themselves, worst
            // first, each at its line.
            const e = app.activeEditor() orelse break :blk .{ .title = "Diagnostics in this file", .detail = "click: the panel · right-click: next / previous / filter" };
            const pth = e.buf.doc.path orelse break :blk .{ .title = "Diagnostics in this file", .detail = "click: the panel · right-click: next / previous / filter" };
            const diags = lsp_app.diagnosticsFor(app, pth);
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            for ([_]lsp_types.Severity{ .err, .warning }) |want| {
                for (diags) |d| if (d.severity == want) try rows.append(arena, .{
                    .text = try std.fmt.allocPrint(arena, "{s}", .{firstLine(d.message)}),
                    .sub = try std.fmt.allocPrint(arena, "{s} {d}", .{ d.severity.label(), d.range.start.line + 1 }),
                    .command = "lsp.diagnostics",
                });
            }
            const listed = capped(app, seg, rows.items, 0);
            break :blk .{
                .title = "Diagnostics in this file",
                .detail = "click: the panel · right-click: next / previous / filter",
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .symbol => .{ .title = "Enclosing symbol", .detail = "click: the outline pane" },
        .macro => .{ .title = "Recording a macro", .detail = "click stops it (q)" },
        .find => .{ .title = "Find", .detail = "the query and the match under the cursor · click reopens the find bar" },
        .test_run => .{ .title = "Test run", .detail = "click focuses the tests pane" },
        .ai_claude => blk: {
            // Every watched account: its two percents and next reset.
            const lines = try @import("usage_pane.zig").chipTipLines(app, arena);
            const rows = try arena.alloc(Row, lines.len);
            for (lines, 0..) |l, i| rows[i] = .{ .text = l.text, .sub = l.sub, .command = "ai.claude_usage" };
            const listed = capped(app, seg, rows, 0);
            break :blk .{
                .title = "Claude — usage",
                .detail = "the session and weekly windows of every watched account · click: the usage pane · right-click: what the chip shows",
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .ai_codex => .{ .title = "Codex — usage", .detail = "tokens today · click: the usage pane · right-click: what the chip shows" },
        .np_brand => .{ .title = try std.fmt.allocPrint(arena, "Music — {s}", .{@tagName(app.cfg.ui.preferred_music_app)}), .detail = "click opens the player · right-click: the player menu" },
        .np_play => .{ .title = "Play / pause", .detail = "click starts or pauses the player · right-click: the player menu" },
        .np_next => .{ .title = "Next track", .detail = "click skips ahead · right-click: the player menu" },
        .np_track => .{ .title = "Now playing", .detail = "the track and its player · click opens the player · right-click: the player menu" },
        .ghost => try ghost_chip.tip(app, arena),
        .jobs => try jobs_app.tip(app, arena),
        .coverage => .{ .title = "Coverage", .detail = "feature (F) and code (C) coverage from the trends files, with the move since last week / last commit · click toasts both · right-click picks the mode" },
        .transfer => blk: {
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            for (app.transfers.jobs.items) |job| try rows.append(arena, .{
                .text = try std.fmt.allocPrint(arena, "{s} → {s}", .{ @tagName(job.kind), std.fs.path.basename(job.dest) }),
                .sub = try std.fmt.allocPrint(arena, "{d}%", .{job.percent()}),
            });
            const listed = capped(app, seg, rows.items, 0);
            break :blk .{
                .title = "File transfers",
                .detail = "progress of the running copies · right-click: cancel all",
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .lsp => blk: {
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            for (app.lsp.servers.items) |srv| if (!srv.transport.isDead()) try rows.append(arena, .{
                .text = try arena.dupe(u8, srv.name),
                .sub = try std.fmt.allocPrint(arena, "{s}", .{std.fs.path.basename(srv.root)}),
                .command = "lsp.status",
            });
            const listed = capped(app, seg, rows.items, 0);
            break :blk .{
                .title = "Language servers running",
                .detail = "click: which servers, on which roots · right-click: the LSP menu",
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .wrap => .{ .title = "WRAP — long lines wrap", .detail = "click turns wrapping off" },
        .autosave => .{ .title = try std.fmt.allocPrint(arena, "Autosave every {d}s", .{app.cfg.editor.autosave_secs}), .detail = "`.editor.autosave_secs` sets it" },
        .highlight => blk: {
            const e = app.activeEditor() orelse break :blk null;
            var size_buf: [24]u8 = undefined;
            var limit_buf: [24]u8 = undefined;
            const size = syntax.Syntax.sizeLabel(&size_buf, e.syntax.size_bytes);
            const head = if (e.syntax.off)
                try std.fmt.allocPrint(arena, "Highlighting off for this file ({s})", .{size})
            else
                try std.fmt.allocPrint(arena, "Highlighting on for this file ({s})", .{size});
            const detail = if (e.syntax.over_limit)
                try std.fmt.allocPrint(arena, "over `editor.highlight_max_bytes` ({s}) · click toggles it for this buffer only (editor.highlight_toggle_file)", .{syntax.Syntax.sizeLabel(&limit_buf, e.syntax.limit_bytes)})
            else
                "switched off by hand · click toggles it for this buffer only (editor.highlight_toggle_file) · `editor.highlight_max_bytes` is the config key";
            break :blk .{ .title = head, .detail = detail };
        },
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
            // What the number counts: the unread warnings and errors
            // themselves, newest first. The infos the log also holds
            // are not what the bell counts, so they are not listed.
            const log = app.messages.items.items;
            const from = @min(app.messages.read_upto, log.len);
            var rows: std.ArrayListUnmanaged(Row) = .empty;
            var i = log.len;
            while (i > from) {
                i -= 1;
                if (log[i].level == .info) continue;
                try rows.append(arena, .{
                    .text = try arena.dupe(u8, firstLine(log[i].text)),
                    .sub = if (log[i].level == .err) "error" else "warning",
                    .command = "messages.show",
                });
            }
            const listed = capped(app, seg, rows.items, 0);
            break :blk .{
                .title = if (u.err + u.warn == 0) "Messages — nothing unread" else try std.fmt.allocPrint(arena, "Messages — {d} unread ({d} errors)", .{ u.err + u.warn, u.err }),
                .detail = "click: the history · right-click: clear",
                .rows = listed.rows,
                .more = listed.more,
                .row_seg = listed.row_seg,
            };
        },
        .clock => .{ .title = "Clock", .detail = "local time (a Z is UTC) · click: local ⇄ UTC · right-click: local / UTC / hide" },
        .workspace => .{ .title = "Workspace", .detail = "click: switch workspace (or the active repo, with several)" },
        .zoom => .{ .title = "zoom", .detail = "one split fills this tab page; the others are hidden, not closed · click: restore the layout" },
        .dev_profile => .{ .title = "dev profile", .detail = "this is the build being worked on, not the installed mnml · click says where its data root is" },
        .sandbox => switch (app.sandboxState()) {
            .unsafe => .{ .title = "sandbox — NOT isolated", .detail = "MNML_SANDBOX is set, but HOME or the data root is not a throwaway directory · click says which" },
            else => .{ .title = "sandbox", .detail = "a --sandbox run: HOME, the config and the state are a throwaway directory · click says where" },
        },
        .sessions => .{ .title = "Sessions", .detail = "the Claude Code / Codex panes open, and the focused one's place · click: the sessions section" },
        .session_prev => .{ .title = "Previous session", .detail = "click: the session before this one, on whichever page holds it" },
        .session_next => .{ .title = "Next session", .detail = "click: the session after this one, on whichever page holds it" },
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
    // A pointer that has walked onto the tip's own list keeps the box
    // where it was: anchoring on the pointer again would slide the row
    // out from under it, one cell per frame.
    const anchor: struct { x: u16, y: u16 } = if (app.hits.at(h.x, h.y)) |under|
        (if (under == .tip_row) .{ .x = under.tip_row.x, .y = under.tip_row.y } else .{ .x = h.x, .y = h.y })
    else
        .{ .x = h.x, .y = h.y };
    tooltip.draw(ui, screen, anchor.x, anchor.y, tip);
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
            .split_dividers => target == .divider and target.divider != render.tree_divider_id and target.divider != render.right_divider_id and target.divider != render.info_divider_id,
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 24 });
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 24, .cfg = .{ .ui = .{ .hover_tooltip = true } } });
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
