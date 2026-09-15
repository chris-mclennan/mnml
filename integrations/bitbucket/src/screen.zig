//! One function: turn the `App` into a frame. Kept apart from both
//! `app.zig` (which knows what is true) and `view.zig` (which knows
//! what a line reads like) so the layout decisions — where the detail
//! goes, what an overlay covers — live in one place with their own
//! tests.
//!
//! The pane is four bands: the tab strip, the filter line, the body,
//! and the footer. The body is the list, or the list beside the detail
//! when there is room for both, or the detail alone when there is not.
//! An overlay — the confirm, the comment prompt, the key help — is
//! painted over the bottom of the body rather than replacing it, so you
//! can still see the pull request you are about to merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const app_mod = @import("app.zig");
const view = @import("view.zig");
const App = app_mod.App;

/// The narrowest pane that gets the list and the detail side by side.
pub const split_min_cols: u16 = 100;
/// The list's share when they are side by side.
pub const list_share_pct: u16 = 55;

pub fn paint(arena: Allocator, f: *sdk.Frame, a: *App) Allocator.Error!void {
    f.clear(.{});
    a.cols = f.cols;
    a.rows = f.rows;
    if (f.rows == 0 or f.cols == 0) return;

    const tab = a.activeTab();

    // ── the tab strip ────────────────────────────────────────────────
    const infos = try arena.alloc(view.TabInfo, a.tabs.len);
    for (a.tabs, infos) |*ts, *slot| slot.* = .{
        .name = ts.tab.name,
        .count = if (ts.fetched) ts.visible.len else null,
        .fallback_note = ts.fallback_note,
    };
    _ = f.text(0, 0, f.cols, try view.tabStrip(arena, infos, a.active), view.Tone.header.style());

    // ── the filter line ──────────────────────────────────────────────
    if (f.rows > 1) {
        const line = try view.filterLine(arena, .{
            .query = a.filter_buf.items,
            .editing = a.mode == .filter,
            .matched = tab.visible.len,
            .total = tab.rows.len,
        });
        _ = f.text(0, 1, f.cols, line, view.Tone.dim.style());
    }

    // ── the body ─────────────────────────────────────────────────────
    const body_top: u16 = 2;
    const body_height = f.rows -| body_top -| 1;
    if (body_height > 0) {
        const split = a.show_detail and f.cols >= split_min_cols;
        const list_w: u16 = if (split) @max(30, (f.cols * list_share_pct) / 100) else f.cols;
        if (!a.show_detail or split) {
            try paintList(arena, f, a, tab, .{ .x = 0, .y = body_top, .width = list_w, .height = body_height });
        }
        if (a.show_detail) {
            const x: u16 = if (split) list_w + 1 else 0;
            const w: u16 = if (split) f.cols -| (list_w + 1) else f.cols;
            try paintDetail(arena, f, a, .{ .x = x, .y = body_top, .width = w, .height = body_height });
            if (split) {
                var y: u16 = body_top;
                while (y < body_top + body_height) : (y += 1) f.put(list_w, y, "│", view.Tone.dim.style());
            }
        }
        try paintOverlay(arena, f, a, .{ .x = 0, .y = body_top, .width = f.cols, .height = body_height });
    }

    // ── the footer ───────────────────────────────────────────────────
    if (f.rows > 2) {
        const text = if (a.status.len > 0) a.status else footer_keys;
        _ = f.text(0, f.rows - 1, f.cols, text, view.Tone.dim.style());
    }
}

pub const footer_keys = "enter open · y url · Y branch · d detail · a approve · x changes · c comment · m merge · C checkout · i issue · r refresh · ? keys · q quit";

fn paintList(arena: Allocator, f: *sdk.Frame, a: *App, tab: *app_mod.TabState, box: view.Box) Allocator.Error!void {
    if (tab.error_text.len > 0) {
        const lines = [_]view.Line{
            .{ .text = tab.tab.name, .tone = .header },
            .{ .text = "" },
            .{ .text = tab.error_text, .tone = .bad },
            .{ .text = "" },
            .{ .text = "r retries · see the README's Auth section", .tone = .dim },
        };
        view.paintLines(f, &lines, box, 0, null);
        return;
    }
    const rows = try arena.alloc(view.Row, tab.visible.len);
    for (tab.visible, rows) |i, *slot| slot.* = tab.rows[i];
    const lines = try view.listLines(arena, .{
        .rows = rows,
        .selected = tab.selected,
        .cols = box.width,
        .show_repo = tab.tab.mode != .repo,
        .me_account_id = a.me_account_id,
        .empty_message = if (!tab.fetched) "loading…" else emptyMessage(tab),
    });
    // Line 0 is the column header and does not scroll; the rows do.
    if (lines.len > 0) view.paintLines(f, lines[0..1], .{ .x = box.x, .y = box.y, .width = box.width, .height = 1 }, 0, null);
    const body: view.Box = .{ .x = box.x, .y = box.y + 1, .width = box.width, .height = box.height -| 1 };
    if (lines.len > 1) view.paintLines(f, lines[1..], body, tab.scroll, if (tab.visible.len == 0) null else tab.selected);

    // The per-repo failures sit under the rows rather than replacing
    // them: a 403 on one archived repo must be visible, not fatal.
    if (tab.notes.len > 0 and box.height > 2) {
        var y = box.y + box.height -| @as(u16, @intCast(@min(tab.notes.len, 3)));
        for (tab.notes[0..@min(tab.notes.len, 3)]) |note| {
            f.fill(box.x, y, box.width, 1, .{});
            _ = f.text(box.x, y, box.width, try std.fmt.allocPrint(arena, "! {s}", .{note}), view.Tone.warn.style());
            y += 1;
        }
    }
}

fn emptyMessage(tab: *app_mod.TabState) []const u8 {
    return switch (tab.tab.mode) {
        .mine => "No open pull requests you opened.",
        .reviewing => "Nothing waiting on your review.",
        .repo, .workspace => "No pull requests here.",
    };
}

fn paintDetail(arena: Allocator, f: *sdk.Frame, a: *App, box: view.Box) Allocator.Error!void {
    const d = a.detail orelse {
        const lines = [_]view.Line{.{ .text = "(nothing focused)", .tone = .dim }};
        view.paintLines(f, &lines, box, 0, null);
        return;
    };
    if (d.error_text.len > 0) {
        const lines = [_]view.Line{
            .{ .text = "detail", .tone = .section },
            .{ .text = "" },
            .{ .text = d.error_text, .tone = .bad },
        };
        view.paintLines(f, &lines, box, 0, null);
        return;
    }
    const lines = try view.detailLines(arena, .{
        .pr = d.pr,
        .workspace = d.key.workspace,
        .repo = d.key.repo,
        .reviewers = d.reviewers,
        .builds = d.builds,
        .files = d.files,
        .diff = d.diff,
        .activity = d.activity,
        .jira_keys = d.jira_keys,
        .me_account_id = a.me_account_id,
        .cols = box.width,
        .show_diff = a.show_diff,
        .loading = d.loading,
    });
    const max_scroll = lines.len -| box.height;
    if (a.detail) |*live| live.scroll = @min(live.scroll, max_scroll);
    view.paintLines(f, lines, box, if (a.detail) |live| live.scroll else 0, null);
}

fn paintOverlay(arena: Allocator, f: *sdk.Frame, a: *App, box: view.Box) Allocator.Error!void {
    const lines: []const view.Line = switch (a.mode) {
        .confirm => try view.confirmLines(arena, .{ .title = a.pending_detail, .detail = "" }),
        .prompt => blk: {
            var out: std.ArrayList(view.Line) = .empty;
            try out.append(arena, .{ .text = "comment", .tone = .section });
            const before = a.prompt_buf.items[0..a.prompt_cursor];
            const after = a.prompt_buf.items[a.prompt_cursor..];
            try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "> {s}▏{s}", .{ before, after }), .tone = .normal });
            try out.append(arena, .{ .text = "enter post · esc cancel · ←→ move · ctrl+u clear", .tone = .dim });
            break :blk try out.toOwnedSlice(arena);
        },
        .help => help_lines,
        else => return,
    };
    if (lines.len == 0) return;
    const h: u16 = @intCast(@min(lines.len + 2, box.height));
    const top = box.y + box.height -| h;
    var y = top;
    while (y < top + h) : (y += 1) f.fill(box.x, y, box.width, 1, view.Tone.dim.style());
    view.paintLines(f, lines, .{ .x = box.x + 1, .y = top + 1, .width = box.width -| 2, .height = h -| 1 }, 0, null);
}

pub const help_lines = &[_]view.Line{
    .{ .text = "keys", .tone = .section },
    .{ .text = "1-9 / tab / shift+tab   switch tab" },
    .{ .text = "j k ↑ ↓ g G             move · ctrl+d ctrl+u page (or scroll the detail)" },
    .{ .text = "enter o                 open in a browser" },
    .{ .text = "y Y                     copy the URL · copy the branch" },
    .{ .text = "d D                     detail · fold the diff" },
    .{ .text = "a A                     approve · withdraw the approval" },
    .{ .text = "x X                     request changes · withdraw the request" },
    .{ .text = "c                       comment" },
    .{ .text = "m s                     merge · cycle the merge strategy" },
    .{ .text = "C                       check the branch out in the workspace" },
    .{ .text = "i                       open the next issue key" },
    .{ .text = "/ esc                   filter · clear" },
    .{ .text = "r q                     refresh · quit" },
    .{ .text = "", .tone = .dim },
    .{ .text = "any key closes this", .tone = .dim },
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const cfg = @import("config.zig");
const api = @import("api.zig");
const listener = @import("../tools/fake_bitbucket/listener.zig");

const Screen = struct {
    srv: *listener.Server,
    client: api.Client,
    app: App,
    frame: sdk.Frame,
    arena: std.heap.ArenaAllocator,

    fn init(cols: u16, rows: u16, tabs: []const cfg.Tab) !*Screen {
        const s = try t.allocator.create(Screen);
        s.arena = std.heap.ArenaAllocator.init(t.allocator);
        s.srv = try listener.Server.start(t.allocator, t.io, 0);
        const base = try s.srv.baseUrl(t.allocator);
        defer t.allocator.free(base);
        s.client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "read", "write", .{ .min_interval_ms = 0 });
        s.app = try App.init(t.allocator, t.io, .{
            .email = "me@x.com",
            .workspace = "acme",
            .repos = &.{ "api", "web" },
            .tabs = tabs,
            .jira = .{ .enabled = true, .base_url = "https://acme.atlassian.net", .project_keys = &.{"TE"} },
        }, &s.client);
        s.frame = try sdk.Frame.init(t.allocator, cols, rows);
        try s.app.switchTab(0);
        return s;
    }

    fn deinit(s: *Screen) void {
        s.frame.deinit();
        s.app.deinit();
        s.client.deinit();
        s.srv.stop();
        s.arena.deinit();
        t.allocator.destroy(s);
    }

    fn draw(s: *Screen) ![]const u8 {
        _ = s.arena.reset(.retain_capacity);
        try paint(s.arena.allocator(), &s.frame, &s.app);
        var out: std.Io.Writer.Allocating = .init(s.arena.allocator());
        var y: u16 = 0;
        while (y < s.frame.rows) : (y += 1) {
            if (y > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
            out.writer.writeAll(try view.rowText(s.arena.allocator(), &s.frame, y)) catch return error.OutOfMemory;
        }
        return out.written();
    }
};

test "the pane paints a tab strip, a filter line, the list and a footer" {
    const s = try Screen.init(120, 24, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "▸1 api (2)") != null);
    try t.expect(std.mem.indexOf(u8, text, "/ filter · r refresh") != null);
    try t.expect(std.mem.indexOf(u8, text, "PR") != null);
    try t.expect(std.mem.indexOf(u8, text, "#1234") != null);
    try t.expect(std.mem.indexOf(u8, text, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, text, "#1198") != null);
    // A repo tab does not spend a column saying which repo it is.
    try t.expect(std.mem.indexOf(u8, text, "REPO") == null);
    // The footer carries the status the refresh set.
    try t.expect(std.mem.indexOf(u8, text, "api: 2 pull requests") != null);
}

test "a mine tab does show the repo column, because its rows come from several" {
    const s = try Screen.init(120, 24, &.{.{ .name = "Mine", .mode = .mine }});
    defer s.deinit();
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "REPO") != null);
    try t.expect(std.mem.indexOf(u8, text, "api ") != null);
    try t.expect(std.mem.indexOf(u8, text, "web ") != null);
}

test "the detail sits beside the list on a wide pane and replaces it on a narrow one" {
    const wide = try Screen.init(160, 30, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer wide.deinit();
    _ = try wide.app.key("d");
    const wide_text = try wide.draw();
    // Both surfaces, and the rule between them.
    try t.expect(std.mem.indexOf(u8, wide_text, "acme/api#1234") != null);
    try t.expect(std.mem.indexOf(u8, wide_text, "#1198") != null);
    try t.expect(std.mem.indexOf(u8, wide_text, "│") != null);

    const narrow = try Screen.init(80, 24, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer narrow.deinit();
    _ = try narrow.app.key("d");
    const narrow_text = try narrow.draw();
    try t.expect(std.mem.indexOf(u8, narrow_text, "acme/api#1234") != null);
    try t.expect(std.mem.indexOf(u8, narrow_text, "│") == null);
    // The list is gone; only the detail is on the body.
    try t.expect(std.mem.indexOf(u8, narrow_text, "Bump the client timeout") == null);
}

test "the detail's own sections are on the screen, not just in the line builder" {
    const s = try Screen.init(160, 40, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    _ = try s.app.key("d");
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "reviewers") != null);
    try t.expect(std.mem.indexOf(u8, text, "Dana R") != null);
    try t.expect(std.mem.indexOf(u8, text, "builds") != null);
    try t.expect(std.mem.indexOf(u8, text, "Pipeline #412") != null);
    try t.expect(std.mem.indexOf(u8, text, "files (2)") != null);
    try t.expect(std.mem.indexOf(u8, text, "issues: [1] ENG-4210") != null);
}

test "a confirm covers the bottom of the body and leaves the list visible above it" {
    const s = try Screen.init(120, 24, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    _ = try s.app.key("m");
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "Merge acme/api#1234") != null);
    try t.expect(std.mem.indexOf(u8, text, "strategy: squash") != null);
    try t.expect(std.mem.indexOf(u8, text, "y confirm · esc cancel") != null);
    // The row it is about is still on screen.
    try t.expect(std.mem.indexOf(u8, text, "Fix the login redirect") != null);
}

test "the comment prompt shows the caret where the cursor actually is" {
    const s = try Screen.init(120, 24, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    _ = try s.app.key("c");
    for ("abc") |ch| _ = try s.app.key(&[_]u8{ch});
    _ = try s.app.key("left");
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "> ab▏c") != null);
    try t.expect(std.mem.indexOf(u8, text, "enter post · esc cancel") != null);
}

test "the key help lists every action the footer advertises" {
    const s = try Screen.init(120, 30, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    _ = try s.app.key("?");
    const text = try s.draw();
    for ([_][]const u8{ "switch tab", "open in a browser", "approve", "request changes", "comment", "merge", "check the branch out", "filter" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("the key help does not mention `{s}`\n", .{needle});
            return error.MissingKeyHelp;
        }
    }
}

test "a tab that failed paints the reason instead of an empty list" {
    const s = try Screen.init(120, 24, &.{.{ .name = "Mine", .mode = .mine, .fallback = .none }});
    defer s.deinit();
    // The first fetch already resolved the account; take the token's
    // Account: Read away and ask again, which is what an expired or
    // re-scoped token looks like from the pane.
    s.srv.denyUser(true);
    s.app.me_account_id = "";
    s.app.whoami_tried = false;
    try s.app.refreshActive();
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "Account: Read") != null);
    try t.expect(std.mem.indexOf(u8, text, "r retries") != null);
}

test "a per-repo failure shows under the rows it did not stop" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "tok", "tok", .{ .min_interval_ms = 0 });
    defer client.deinit();
    var a = try App.init(t.allocator, t.io, .{
        .email = "me@x.com",
        .workspace = "acme",
        .repos = &.{ "api", "ghost" },
        .tabs = &.{.{ .name = "All", .mode = .workspace }},
    }, &client);
    defer a.deinit();
    var frame = try sdk.Frame.init(t.allocator, 120, 24);
    defer frame.deinit();
    try a.switchTab(0);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try paint(arena.allocator(), &frame, &a);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var y: u16 = 0;
    while (y < frame.rows) : (y += 1) {
        out.writer.writeAll(try view.rowText(arena.allocator(), &frame, y)) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    try t.expect(std.mem.indexOf(u8, out.written(), "! ghost: no such repo") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "Fix the login redirect") != null);
}

test "the pane paints at every size the gate runs, and at one below them" {
    for ([_][2]u16{ .{ 30, 10 }, .{ 80, 24 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        const s = try Screen.init(size[0], size[1], &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
        defer s.deinit();
        _ = try s.draw();
        _ = try s.app.key("d");
        _ = try s.draw();
        _ = try s.app.key("m");
        _ = try s.draw();
        _ = try s.app.key("esc");
        _ = try s.app.key("?");
        _ = try s.draw();
    }
}

test "a one-row pane paints its tab strip and nothing else, rather than reaching past the frame" {
    const s = try Screen.init(20, 1, &.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer s.deinit();
    const text = try s.draw();
    try t.expect(std.mem.indexOf(u8, text, "1 api") != null);
    try t.expect(std.mem.indexOf(u8, text, "\n") == null);
}
