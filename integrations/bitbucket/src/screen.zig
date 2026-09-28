//! One function: turn the `App` into a frame, registering every click
//! target in the same statement as the cells it covers. The pane is
//! mnml's own panel shape, so it looks native inside mnml-zig rather
//! than like a transplanted table:
//!
//!   row 0   the caps header — `BITBUCKET PRS  (4 repos · 64 PRs)`, what
//!           the fetch is doing while one is out (`⠋ fetching… 2/13 repos`,
//!           `queued behind 3 requests`, `fetch failed: …`) and,
//!           right-anchored, the chips: the pipelines pages (the pipelines
//!           family), the refresh glyph — the spinner while busy — and `?`
//!   row 1   the tab strip, when the launch kept more than one tab —
//!           `1 Open + Draft (47)  2 Merged (32)  3 Pipelines (18)`
//!   row 2   the toolbar — the web bar's filters as ` key: value ` chips,
//!           `status: Open + Draft  author: all  target: any  show: all`
//!           on a PR tab, `run by · branch · type · status · trigger` on a
//!           pipelines tab; wrapping to a second row when they must
//!   row 3   the filter pill — `󰍉 / filter`
//!   row 4   the column header
//!   rows    the list: the `▌` marker on the cursor's row, the reference's
//!           columns, a merged PR's pipeline sub-line, the show-more footer,
//!           a scrollbar when the list is longer than the pane; with `d`, the
//!           detail beside it (or over it below 100 columns)
//!   last    the hint row — the status on the left, and on the right the
//!           keys that apply to the focused row, generated from the one
//!           keymap table so nothing here can drift from what a key does
//!
//! Overlays paint last, so they win the click: a row's or a chip's
//! right-click menu, a chip's picker, and the `?` key sheet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const chrome = sdk.pane.chrome;
const app_mod = @import("app.zig");
const tabs = @import("tabs.zig");
const view = @import("view.zig");
const keymap = @import("keymap.zig");
const hit = @import("hit.zig");
const cfg = @import("config.zig");
const theme_mod = @import("theme.zig");

const App = app_mod.App;
const Style = sdk.Style;
const Theme = theme_mod.Theme;

/// The narrowest pane that gets the list and the detail side by side.
pub const split_min_cols: u16 = 100;
/// The list's share when they are side by side (the reference's 55/45).
pub const list_share_pct: u16 = 55;

pub const marker = "▌";

pub const Box = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Chrome = sdk.pane.Painter(hit.Target);

/// A rectangle on the frame with the hit map alongside.
const Painter = struct {
    f: *sdk.Frame,
    app: *App,
    th: Theme,
    nerd: bool,
    /// The shared pane chrome — the gutter, the detail panel's `\u{d7}`
    /// and scrollbar, the clickable hint row. Both official integrations
    /// paint these from the same code.
    c: Chrome,

    fn text(p: *Painter, x: u16, y: u16, max_w: u16, s: []const u8, style: Style) u16 {
        return p.f.text(x, y, max_w, s, style);
    }

    fn fill(p: *Painter, b: Box, style: Style) void {
        p.f.fill(b.x, b.y, b.w, b.h, style);
    }

    fn target(p: *Painter, x: u16, y: u16, w: u16, tg: hit.Target) void {
        p.app.hits.add(.{ .x = x, .y = y, .w = w, .h = 1 }, tg);
    }

    fn width(s: []const u8) u16 {
        var n: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| n += if (sdk.frame.isWide(cp)) 2 else 1;
        return n;
    }
};

pub fn paint(arena: Allocator, f: *sdk.Frame, app: *App, nerd_font: bool) Allocator.Error!void {
    f.clear(.{ .fg = app.theme.fg, .bg = app.theme.bg });
    app.cols = f.cols;
    app.rows = f.rows;
    app.hits.reset();
    if (f.rows == 0 or f.cols == 0) return;
    var p: Painter = .{
        .f = f,
        .app = app,
        .th = app.theme,
        .nerd = nerd_font,
        .c = .{ .f = f, .gpa = app.hits.gpa, .arena = arena, .hits = &app.hits.inner, .th = app.theme, .ui = .{ .nerd = nerd_font, .ascii = !nerd_font, .tab_indicator = app.tab_indicator } },
    };
    // The app-colour stripe down column 0 — the pane's identity, from
    // the toolkit. Painted under everything: a row that puts its own
    // marker there still wins the cell.
    p.c.gutter(.{ .x = 0, .y = 0, .w = 1, .h = f.rows -| 1 }, null);
    // The header's `N of M` is derived from the rows, and the header
    // paints first: resolve them once here so it reads this frame's
    // numbers rather than the last one's.
    _ = try app.visible(arena);
    var y: u16 = 0;
    try paintHeader(arena, &p, y);
    y += 1;
    if (app.showTabStrip() and y < f.rows) {
        y += try paintTabStrip(arena, &p, y);
    }
    const hint_y = f.rows - 1;
    // The toolbar may take two rows; it never takes the pill's or the
    // body's last one.
    if (y + 3 < hint_y) {
        y += try paintToolbar(arena, &p, y, if (y + 5 < hint_y) 2 else 1);
    }
    if (y < f.rows) {
        try paintFilter(&p, y);
        y += 1;
    }
    if (y < hint_y) {
        const body: Box = .{ .x = 0, .y = y, .w = f.cols, .h = hint_y - y };
        try paintBody(arena, &p, body);
    }
    try paintHintRow(arena, &p, hint_y);
    if (app.mode == .menu) try paintMenu(arena, &p);
    if (app.mode == .picker) try paintPicker(arena, &p);
    if (app.mode == .help) try paintSheet(arena, &p);
    if (app.mode == .confirm) try paintMergeConfirm(&p);
}

// ─── the header ──────────────────────────────────────────────────────────

fn familyLabel(app: *App) []const u8 {
    return switch (app.family()) {
        .prs => "BITBUCKET PRS",
        .pipelines => "BITBUCKET PIPELINES",
        .branches => "BITBUCKET BRANCHES",
    };
}

/// What the header says when the chips or the query hide every row.
fn nothingMatches(kind: cfg.Kind) []const u8 {
    return switch (kind.family()) {
        .prs => "no pull requests match",
        .pipelines => "no pipelines match",
        .branches => "no branches match",
    };
}

/// The pipelines pages' chips on their narrow rung (`Chip.icon`): the
/// header drops to these before it gives up the repo count. Codicons,
/// the refresh chip's font; each with its `--ascii` twin.
pub const run_nerd = "\u{eb2c}"; // cod-play
pub const run_ascii = ">";
pub const schedules_nerd = "\u{eab0}"; // cod-calendar
pub const schedules_ascii = "@";
pub const caches_nerd = "\u{eace}"; // cod-database
pub const caches_ascii = "#";
pub const usage_nerd = "\u{eb03}"; // cod-graph
pub const usage_ascii = "%";

fn paintHeader(arena: Allocator, p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    const ts = app.activeTab();
    const label = familyLabel(app);
    // What the fetch is doing — the live phase the worker left behind
    // (queued behind N on the broker, waiting on the file bucket, on
    // the wire), the repo count of a first load, the reason the last
    // one failed. One wording, the toolkit's, on both families.
    const fetch = app.fetchState();
    const busy = fetch.busy();
    // The subtitle: the reference's status count, dim.
    var sub: []const u8 = "";
    if (!ts.fetched and busy) {
        // Nothing to count yet: the line is the fetch alone —
        // `⠋ fetching… 2/13 repos`.
        sub = p.c.fetchSub(fetch, app.now_ms);
    } else {
        if (ts.fetched and app.filter_shown == 0 and app.filter_total > 0 and app.narrowed()) {
            // The chips or the query hid every row: say so, rather than
            // leave `(0 of 3)` to explain an empty list.
            sub = try std.fmt.allocPrint(arena, "  {s}", .{nothingMatches(ts.spec.kind)});
        } else if (app.narrowed()) {
            // Narrowed: the count says how much of the tab is hidden, the
            // way the sibling integrations' caps headers do.
            sub = try std.fmt.allocPrint(arena, "  ({d} of {d})", .{ app.filter_shown, app.filter_total });
        } else if (ts.fetched) {
            sub = switch (ts.data) {
                .repo_pr_tree => try std.fmt.allocPrint(arena, "  ({d} {s} · {d} {s})", .{ ts.repos, sdk.pane.text.noun(ts.repos, "repo", "repos"), ts.items, sdk.pane.text.noun(ts.items, "PR", "PRs") }),
                .repo_tree => try std.fmt.allocPrint(arena, "  ({d} {s})", .{ ts.repos, sdk.pane.text.noun(ts.repos, "repo", "repos") }),
                .pull_requests => try std.fmt.allocPrint(arena, "  ({d} {s})", .{ ts.items, sdk.pane.text.noun(ts.items, "PR", "PRs") }),
                .pipelines => try std.fmt.allocPrint(arena, "  ({d} {s})", .{ ts.items, sdk.pane.text.noun(ts.items, "pipeline", "pipelines") }),
                .branches => try std.fmt.allocPrint(arena, "  ({d} {s})", .{ ts.items, sdk.pane.text.noun(ts.items, "branch", "branches") }),
            };
        }
        // A refetch over rows that are already there keeps the count
        // and says what the fetch is doing beside it, rather than
        // replacing what is on screen with `loading…`: the rows below
        // are last time's, and they stay readable while the new ones
        // are fetched. A failure sits in the same place.
        if (busy or fetch == .failed) {
            sub = try std.fmt.allocPrint(arena, "{s}{s}", .{ sub, p.c.fetchSub(fetch, app.now_ms) });
        }
    }
    // The chips, laid right to left by the toolkit, each dropped whole
    // when it would cross the title, each a hit registered with its
    // cells. `?` first, so it lands at the very end — it is the one
    // chip that applies on every family and in every state. The
    // refresh chip is the spinner while a fetch is out, where the
    // host's own panels turn theirs.
    var chips: [8]Chrome.ChipSpec = undefined;
    var n: usize = 0;
    chips[n] = .{ .text = chrome.help_chip_text, .target = .{ .chip = .help } };
    n += 1;
    chips[n] = .{ .text = p.c.refreshOrBusyChipText(busy, app.now_ms), .target = .{ .chip = .refresh } };
    n += 1;
    // The API budget, beside refresh — the same chip in the same place
    // on the tracker pane (`sdk.pane.chrome.budgetChip`).
    chips[n] = p.c.budgetChip(app.budget.snapshot(app.now_secs), .{ .chip = .budget });
    n += 1;
    switch (app.family()) {
        .prs => {},
        .pipelines => {
            const nerd = p.nerd;
            chips[n] = .{ .text = " usage ", .target = .{ .chip = .usage }, .active = false, .icon = if (nerd) " " ++ usage_nerd ++ " " else " " ++ usage_ascii ++ " " };
            n += 1;
            // The three repo pages act on the repo under the cursor (or
            // the tab's own); with none, they are not offered at all.
            if (app.pipelinesRepo((try app.visible(arena)).rows) == null) {
                _ = try p.c.capsHeader(1, y, label, sub, ts.fetched_at, app.now_secs, chips[0..n]);
                return;
            }
            chips[n] = .{ .text = " caches ", .target = .{ .chip = .caches }, .active = false, .icon = if (nerd) " " ++ caches_nerd ++ " " else " " ++ caches_ascii ++ " " };
            n += 1;
            chips[n] = .{ .text = " schedules ", .target = .{ .chip = .schedules }, .active = false, .icon = if (nerd) " " ++ schedules_nerd ++ " " else " " ++ schedules_ascii ++ " " };
            n += 1;
            chips[n] = .{ .text = " run pipeline ", .target = .{ .chip = .run_pipeline }, .active = false, .icon = if (nerd) " " ++ run_nerd ++ " " else " " ++ run_ascii ++ " " };
            n += 1;
        },
        .branches => {},
    }
    // The whole row from the toolkit: the title and its count, the
    // `as of …` line in the same words and ink the tracker pane wears,
    // and the ladder — laid so the two runs cannot land on each other.
    _ = try p.c.capsHeader(1, y, label, sub, ts.fetched_at, app.now_secs, chips[0..n]);
}

// ─── the tab strip ───────────────────────────────────────────────────────

/// The strip, from the toolkit — the same two rows the tracker pane
/// paints, so the active tab is underlined the same way in both.
/// Returns the rows it used.
fn paintTabStrip(arena: Allocator, p: *Painter, y: u16) Allocator.Error!u16 {
    const app = p.app;
    var list: std.ArrayList(Chrome.TabSpec) = .empty;
    for (app.tabs, 0..) |*ts, i| {
        const count = if (ts.fetched) try std.fmt.allocPrint(arena, " {d} {s} ({d}) ", .{ i + 1, ts.spec.name, tabCount(ts) }) else try std.fmt.allocPrint(arena, " {d} {s} ", .{ i + 1, ts.spec.name });
        try list.append(arena, .{ .label = count, .target = .{ .tab = i }, .active = i == app.active });
    }
    return p.c.tabStrip(1, y, list.items);
}

/// The reference's tab count: the rows a tree shows, the items of a list.
fn tabCount(ts: *const app_mod.TabState) usize {
    return switch (ts.data) {
        .repo_pr_tree => ts.items,
        .repo_tree => ts.repos,
        else => ts.items,
    };
}

// ─── the toolbar ─────────────────────────────────────────────────────────

/// The web bar's filters as the toolkit's ` key: value ` chips, left to
/// right under the strip, wrapping to a second row when the pane is
/// too narrow for one — the tracker pane's toolbar geometry, so the
/// two families' filters sit in the same place. A chip off its default
/// wears the active ink. Returns the rows used.
fn paintToolbar(arena: Allocator, p: *Painter, y: u16, max_rows: u16) Allocator.Error!u16 {
    const app = p.app;
    const kinds = app.chipKinds();
    if (kinds.len == 0) return 0;
    const chips = try arena.alloc(Chrome.ChipSpec, kinds.len);
    for (kinds, chips) |k, *c| c.* = .{ .text = try app.chipLabel(arena, k), .target = .{ .chip = chipOf(k) }, .active = app.chipActive(k) };
    return p.c.toolbarRow(1, y, p.f.cols -| 1, max_rows, chips);
}

fn chipOf(k: app_mod.FilterKind) hit.Chip {
    return switch (k) {
        .status => .status,
        .author => .author,
        .target => .target,
        .show => .show,
        .run_by => .run_by,
        .branch => .branch,
        .ptype => .ptype,
        .pstatus => .pstatus,
        .trigger => .trigger,
    };
}

// ─── the filter pill ─────────────────────────────────────────────────────

fn paintFilter(p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    if (p.f.cols < 6) return;
    // The pill is the toolkit's, so the glyph, the placeholder, the
    // caret and the hit are the same ones the Jira pane paints.
    try p.c.filterPill(
        .{ .x = 1, .y = y, .w = p.f.cols - 2, .h = 1 },
        app.filter.items,
        app.filter_caret,
        app.mode == .filter,
        .{ .chip = .filter },
    );
}

// ─── the body ────────────────────────────────────────────────────────────

fn paintBody(arena: Allocator, p: *Painter, body: Box) Allocator.Error!void {
    const app = p.app;
    const split = app.detail_visible and body.w >= split_min_cols;
    const list_w: u16 = if (split) @max(30, (body.w * list_share_pct) / 100) else body.w;
    if (!app.detail_visible or split) {
        try paintList(arena, p, .{ .x = body.x, .y = body.y, .w = list_w, .h = body.h });
    }
    if (app.detail_visible) {
        const x: u16 = if (split) body.x + list_w + 1 else body.x;
        const w: u16 = if (split) body.w -| (list_w + 1) else body.w;
        if (split) p.c.vrule(body.x + list_w, body.y, body.h, .{ .fg = p.th.border });
        try paintDetail(arena, p, .{ .x = x, .y = body.y, .w = w, .h = body.h });
    }
}

/// No row on the tab carries anything the server said: never fetched,
/// an empty list, or a tree whose every repo is an error row.
fn nothingToShow(ts: *const app_mod.TabState) bool {
    if (!ts.fetched) return true;
    return switch (ts.data) {
        .repo_pr_tree => |repos| for (repos) |r| {
            if (r.error_label.len == 0) break false;
        } else true,
        .repo_tree => |repos| for (repos) |r| {
            if (r.error_label.len == 0) break false;
        } else true,
        else => ts.data.len() == 0,
    };
}

fn paintList(arena: Allocator, p: *Painter, box: Box) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const ts = app.activeTab();
    if (box.h == 0 or box.w < 4) return;
    // A tab that failed with nothing to show paints the reason instead
    // of an empty list. One that failed over rows it already had keeps
    // them: the header says `fetch failed: …`, and the rows are still
    // the last thing the server said.
    if (ts.error_text.len > 0 and nothingToShow(ts)) {
        _ = p.text(box.x + 2, box.y, box.w -| 2, ts.spec.name, th.label());
        if (box.h > 2) _ = p.text(box.x + 2, box.y + 2, box.w -| 2, ts.error_text, th.bad());
        if (box.h > 4) _ = p.text(box.x + 2, box.y + 4, box.w -| 2, "r retries · see the README's Auth section", th.mutedText());
        return;
    }
    const inner_w = box.w -| 2; // the marker column and a cell of air
    const cols = try view.fit(arena, view.tableOf(ts.data), inner_w -| 1);
    // The toolkit's column header — the one every table in the family
    // wears, so this pane's and a private pane's cannot drift apart.
    _ = sdk.pane.columns.header(p.f, box.x + 2, box.y, inner_w -| 1, cols, view.gap, th);
    if (box.h < 2) return;
    const list: Box = .{ .x = box.x, .y = box.y + 1, .w = box.w, .h = box.h - 1 };
    const v = try app.visible(arena);
    if (v.rows.len == 0) {
        const msg: []const u8 = if (ts.loading) "loading…" else if (!ts.fetched) "not fetched yet — r" else if (app.filter.items.len > 0) "No matches — esc clears" else emptyMessage(ts.spec.kind);
        _ = p.text(list.x + 2, list.y, list.w -| 2, msg, th.mutedText());
        return;
    }
    // The scroll window follows the cursor over cells, not rows — a
    // merged PR opened to its pipeline is two cells tall.
    if (ts.selected >= v.rows.len) ts.selected = v.rows.len - 1;
    const needs_bar = v.cells > list.h;
    const text_w = if (needs_bar) list.w -| 2 else list.w;
    var first = ts.scroll;
    if (first > ts.selected) first = ts.selected;
    // Push the window down until the cursor's cells fit.
    while (true) {
        var used: usize = 0;
        var i = first;
        while (i <= ts.selected) : (i += 1) used += v.rows[i].height();
        if (used <= list.h or first >= ts.selected) break;
        first += 1;
    }
    // Never leave blank rows under a full list.
    while (first > 0) {
        var used: usize = 0;
        var i = first - 1;
        while (i < v.rows.len) : (i += 1) {
            used += v.rows[i].height();
            if (used > list.h) break;
        }
        if (used > list.h) break;
        first -= 1;
    }
    ts.scroll = first;
    var y = list.y;
    var idx = first;
    while (idx < v.rows.len and y < list.y + list.h) : (idx += 1) {
        const row = v.rows[idx];
        const selected = idx == ts.selected;
        const h = row.height();
        // The toolkit's row ground: the fill, the app-colour stripe in
        // column 0 (bright on the cursor's row) and the row's own hit,
        // in one statement — the same one the Jira tree paints.
        try p.c.rowGround(.{ .x = list.x, .y = y, .w = text_w, .h = @min(h, list.y + list.h - y) }, selected, .{ .row = idx });
        // The fold row is the toolkit's `\u{22ef}  Show more (N)`, laid
        // where the last column starts — the same row, from the same
        // function, as the tracker pane's.
        if (row == .show_more) {
            try p.c.showMoreRow(
                .{ .x = list.x, .y = y, .w = text_w, .h = 1 },
                view.lastColumnX(cols, list.x + 2),
                row.show_more.hidden,
                .{ .row = idx },
            );
            y += h;
            continue;
        }
        const spans = try view.rowSpans(arena, .{ .app = app, .ts = ts, .cols = cols, .th = th, .row = row, .selected = selected, .ascii = !p.nerd });
        // The buttons take their cells off the row's right end BEFORE
        // the words are painted, so a title is shortened rather than
        // painted over.
        // The buttons come out of the LAST column's width, so a row
        // never trades its title for them.
        const plan = rowButtonPlan(p, if (cols.len > 0) cols[cols.len - 1].w else 0, row);
        const bw = plan.w;
        paintSpans(p, list.x + 2, y, text_w -| 2 -| bw, spans);
        // The chevron at the head of a tree row is its own target, so
        // a click THERE folds the row and a click anywhere else on it
        // selects, the way the tracker pane's tree already works. A
        // pull request with no commit to look builds up on paints no
        // chevron and registers none.
        // A build line is a door to that run's page, and the door is
        // the whole line: `sdk.pane.buildHit` decides the cells, so
        // this pane's table cell and the tracker pane's free row
        // register the same rect. Registered AFTER the row ground, so
        // the map's last-painted-wins rule puts the door over it.
        if (row == .build) {
            const door = sdk.pane.buildHit(.{ .x = list.x, .y = y, .w = text_w, .h = 1 }, list.x + text_w);
            p.target(door.x, door.y, door.w, .{ .build_line = idx });
        }
        if (chevronX(p, list.x, row)) |cx| p.target(cx, y, 1, .{ .chevron = idx });
        if (bw > 0) try paintRowButtons(p, list.x, y, text_w, bw, plan.form, idx, row);
        y += h;
    }
    if (needs_bar) try p.c.scrollbar(.{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h }, v.cells, cellsBefore(v.rows, first), list.h, null);
}

/// Where the chevron of a tree row sits, or null when the row has
/// none. The spans start at `list.x + 2`; a repo header's chevron is
/// the first cell of its first cell, a pull request's is two in.
fn chevronX(p: *Painter, list_x: u16, row: tabs.VisibleRow) ?u16 {
    const app = p.app;
    return switch (row) {
        .repo_header => list_x + 2,
        .pr => |pr_ref| blk: {
            const repos = switch (app.activeTab().data) {
                .repo_pr_tree => |r| r,
                else => break :blk null,
            };
            if (pr_ref.repo >= repos.len or pr_ref.idx >= repos[pr_ref.repo].prs.len) break :blk null;
            if (repos[pr_ref.repo].prs[pr_ref.idx].buildCommit().len == 0) break :blk null;
            break :blk list_x + 4;
        },
        else => null,
    };
}

/// `[󰏌 Open] [󰊢 Merge]` at the right end of EVERY pull-request row.
///
/// `[ Merge ]` is dim and registers NO `pr_button` target until the
/// pull request may actually merge — only `merge_blocked`, which a
/// hover reads for its reason and a click answers with the same
/// sentence. A button that is always pressable teaches nothing.
/// The specs one row's buttons are built from, and the state each
/// wears. Empty for a row that has no buttons at all.
fn rowButtonSpecs(p: *Painter, row: tabs.VisibleRow, out: *[2]sdk.pane.action.Spec) []sdk.pane.action.Spec {
    const app = p.app;
    if (row != .pr) return out[0..0];
    const repos = switch (app.activeTab().data) {
        .repo_pr_tree => |r| r,
        else => return out[0..0],
    };
    if (row.pr.repo >= repos.len or row.pr.idx >= repos[row.pr.repo].prs.len) return out[0..0];
    const pr = repos[row.pr.repo].prs[row.pr.idx];
    out[0] = .{ .word = "Open" };
    // A merged or declined pull request has nothing to merge.
    if (!pr.isOpen()) return out[0..1];
    var kbuf: [256]u8 = undefined;
    const row_key = app_mod.App.prRowKey(&kbuf, repos[row.pr.repo].slug, pr.id);
    out[1] = .{ .word = sdk.pane.merge.label, .state = app.actions.state(row_key, "merge") };
    return out[0..2];
}

/// What one row's buttons will take, and the form they will wear.
///
/// The buttons are on EVERY pull-request row now, and `title_w`
/// decides only how much of themselves they show. This pane used to
/// put them on the cursor's row alone and only above ~135 columns —
/// so at 80 and 120 the one row that could act was the one row that
/// could not, and `M` was the only way to merge anything.
fn rowButtonPlan(p: *Painter, title_w: u16, row: tabs.VisibleRow) struct { form: sdk.pane.action.Form, w: u16 } {
    var buf: [2]sdk.pane.action.Spec = undefined;
    const specs = rowButtonSpecs(p, row, &buf);
    if (specs.len == 0) return .{ .form = .icon, .w = 0 };
    const form = sdk.pane.action.formFor(specs, title_w, sdk.pane.action.text_floor, p.app.spin, !p.nerd);
    return .{ .form = form, .w = sdk.pane.action.runWidth(specs, form, p.app.spin, !p.nerd) + 1 };
}

fn paintRowButtons(p: *Painter, x0: u16, y: u16, w: u16, bw: u16, form: sdk.pane.action.Form, idx: usize, row: tabs.VisibleRow) Allocator.Error!void {
    const app = p.app;
    var buf: [2]sdk.pane.action.Spec = undefined;
    const specs = rowButtonSpecs(p, row, &buf);
    if (specs.len == 0) return;
    const repos = app.activeTab().data.repo_pr_tree;
    const slug = repos[row.pr.repo].slug;
    const pr = repos[row.pr.repo].prs[row.pr.idx];

    var list: [2]sdk.pane.chrome.ActionChip(hit.Target) = undefined;
    for (specs, 0..) |sp, i| {
        const is_merge = i == 1;
        if (!is_merge) {
            list[i] = .{ .word = sp.word, .target = .{ .pr_button = .{ .row = idx, .which = .open } } };
            continue;
        }
        if (sp.state != .idle) {
            // Once a merge session exists the button follows IT: the
            // spinner, the `⏸`, the `[ view ]`, the `✗` — readiness has
            // had its say.
            list[i] = .{ .word = sp.word, .state = sp.state, .target = .{ .pr_button = .{ .row = idx, .which = .merge } } };
            continue;
        }
        const r = app.readinessOf(slug, pr);
        list[i] = .{
            .word = sp.word,
            .chip = sdk.pane.merge.chipOf(p.th, r),
            .target = if (sdk.pane.merge.isPressable(r)) .{ .pr_button = .{ .row = idx, .which = .merge } } else .{ .merge_blocked = idx },
        };
    }
    _ = try p.c.actionChips(x0 + w -| bw + 1, y, form, app.spin, list[0..specs.len]);
}

fn cellsBefore(rows: []const tabs.VisibleRow, first: usize) usize {
    var n: usize = 0;
    for (rows[0..@min(first, rows.len)]) |r| n += r.height();
    return n;
}

fn emptyMessage(kind: cfg.Kind) []const u8 {
    return switch (kind) {
        .pull_requests, .workspace_open_prs, .workspace_merged_prs => "(no PRs match this tab)",
        .pipelines => "(no pipelines have run on this repo)",
        .branches => "(no branches in this repo)",
        .workspace_pipelines => "(no repos in scope)",
    };
}

/// Spans left to right; a span with `w` pads or clips to it.
fn paintSpans(p: *Painter, x0: u16, y: u16, max_w: u16, spans: []const view.Span) void {
    var x = x0;
    const end = x0 + max_w;
    for (spans) |s| {
        if (x >= end) break;
        const room = end - x;
        if (s.w == 0) {
            x += p.text(x, y, room, s.text, s.style);
        } else {
            const w = @min(s.w, room);
            p.fill(.{ .x = x, .y = y, .w = w, .h = 1 }, s.style);
            _ = p.text(x, y, w, s.text, s.style);
            x += w;
        }
    }
}

/// The merge confirm: what it is about, in its own words.
fn paintMergeConfirm(p: *Painter) Allocator.Error!void {
    const c = p.app.merge_confirm orelse return;
    const w: u16 = @min(p.f.cols -| 6, 72);
    const h: u16 = 8;
    if (p.f.cols < 24 or p.f.rows < h + 2) return;
    const box: sdk.pane.Rect = .{
        .x = (p.f.cols -| w) / 2,
        .y = (p.f.rows -| h) / 2,
        .w = w,
        .h = h,
    };
    var hbuf: [160]u8 = undefined;
    var bbuf: [160]u8 = undefined;
    var sbuf: [160]u8 = undefined;
    try p.c.confirmBox(
        box,
        c.confirm.heading(&hbuf),
        &.{
            c.confirm.title,
            c.confirm.branchLine(&bbuf),
            c.confirm.strategyLine(&sbuf),
            "merged by a Claude Code session, not by this pane",
        },
        " Merge ",
        .confirm_ok,
        " Cancel ",
        .confirm_cancel,
        .confirm_body,
    );
}

// ─── the detail ──────────────────────────────────────────────────────────

fn paintDetail(arena: Allocator, p: *Painter, box: Box) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    if (box.w < 6 or box.h == 0) return;
    // The panel's own door for the pointer: the body takes the wheel,
    // the `\u{d7}` in the corner closes it (Esc still does too).
    try p.c.detailPanel(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, .detail, .detail_close);
    const inner_x = box.x + 1;
    const inner_w = box.w -| 2;
    const rows = (try app.visible(arena)).rows;
    const key = app.focusedKey(rows) orelse {
        _ = p.text(inner_x, box.y, inner_w, "(no PR focused)", th.mutedText());
        return;
    };
    var kbuf: [256]u8 = undefined;
    const title = App.keyText(&kbuf, key);
    const entry = app.focusedDetail(rows) orelse {
        _ = p.text(inner_x, box.y, inner_w, title, th.accentText());
        const msg: []const u8 = if (app.detailInFlight(rows)) "loading detail…" else "(no detail cached — press d to refresh)";
        if (box.h > 1) _ = p.text(inner_x, box.y + 1, inner_w, msg, th.mutedText());
        return;
    };
    const me = if (app.config.account_id.len > 0) app.config.account_id else app.me_account_id;
    const lines = try view.detailLines(arena, entry, title, me, inner_w, th);
    const max_scroll = lines.len -| box.h;
    if (app.detail_scroll > max_scroll) app.detail_scroll = max_scroll;
    var y = box.y;
    var i = app.detail_scroll;
    while (i < lines.len and y < box.y + box.h) : (i += 1) {
        paintSpans(p, inner_x, y, inner_w, lines[i].spans);
        y += 1;
    }
    app.detail_lines = lines.len;
    app.detail_rows = box.h;
    // A scrollbar that means something: the thumb says where you are,
    // and a press or a drag on the track goes there.
    if (lines.len > box.h) try p.c.scrollbar(.{ .x = box.x + box.w - 1, .y = box.y + 1, .w = 1, .h = box.h -| 1 }, lines.len, app.detail_scroll, box.h, .detail_bar);
}

// ─── the hint row ─────────────────────────────────────────────────────────

/// What the hint row says when a mode owns the keyboard: the keys that
/// mode answers to, not the list's. The list's own row comes from the
/// keymap table below.
fn modeHint(app: *App) ?[]const u8 {
    return switch (app.mode) {
        .list => null,
        .filter => "type to filter · Enter commit · Esc clear · Ctrl+U wipe · ↑↓ leave",
        .menu => "↑↓ / j k move · Enter run · Esc close",
        .picker => if (app.picker) |pk| (if (pk.kind.multi()) "type to filter · ↑↓ move · Space toggle · Enter close · Esc cancel" else "type to filter · ↑↓ move · Enter pick · Esc cancel") else null,
        .help => sdk.pane.keysheet.footer,
        .confirm => "Enter merge through Claude Code · ←→ strategy · Esc cancel",
    };
}

fn paintHintRow(arena: Allocator, p: *Painter, y: u16) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    if (modeHint(app)) |line| {
        const status = app.status.items;
        var x: u16 = 1;
        if (status.len > 0) x += p.text(x, y, p.f.cols / 2, status, th.mutedText()) + 2;
        const w = Painter.width(line);
        const at: u16 = if (p.f.cols -| w > x) p.f.cols -| w else x;
        _ = p.text(at, y, p.f.cols -| at, line, th.dimText());
        return;
    }
    const rows = (try app.visible(arena)).rows;
    // A dim `[ Merge ]` owes the reader a reason, and the hint row is
    // where it goes: the pointer is already there.
    if (app.hoverNote().len > 0) {
        _ = p.text(1, y, p.f.cols -| 2, app.hoverNote(), th.warn());
        return;
    }
    const ctx = app.keyContext(rows);
    const hs = try view.hints(arena, ctx);
    // The toolkit's row: the status on the left, `key title` entries
    // on the right each a hit that runs its chord, entries shed from
    // the front so the ones that always apply survive a narrow pane,
    // and a chord the pane passes twice said once.
    //
    // It was hand-rolled here — the same loop, the same arithmetic,
    // one copy per pane — which is exactly the drift the toolkit
    // exists to prevent.
    const entries = try arena.alloc(Chrome.HintSpec, hs.len);
    for (hs, entries) |h, *e| e.* = .{ .key = h.key, .title = h.title, .target = .{ .hint = h.action } };
    try p.c.hintRow(y, app.status.items, entries);
}

// ─── overlays ────────────────────────────────────────────────────────────

/// The tick a chip's menu puts on its live value — the host's `sort:`
/// menu's, so the two read the same.
pub const tick_glyph = "\u{2713}";
pub const tick_ascii = "*";

fn paintMenu(arena: Allocator, p: *Painter) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const m = app.menu orelse return;
    const tick: []const u8 = if (p.nerd) tick_glyph else tick_ascii;
    var w: u16 = 0;
    for (m.items, 0..) |it, i| switch (it) {
        .action => |a| {
            const b = keymap.bindingOf(a) orelse continue;
            w = @max(w, Painter.width(b.title) + Painter.width(keymap.keyLabel(b.keys[0])) + 5);
        },
        .pick => w = @max(w, Painter.width(if (i < m.values.len) m.values[i].label else "") + 4),
        .open_url => |o| w = @max(w, Painter.width(o.label) + 2),
        .cancel => w = @max(w, Painter.width("cancel") + 2),
    };
    const h: u16 = @intCast(m.items.len + 2);
    const x: u16 = if (m.col + w + 2 <= p.f.cols) m.col else p.f.cols -| (w + 2);
    const y: u16 = if (m.y + 1 + h <= p.f.rows) m.y + 1 else m.y -| h;
    const box: Box = .{ .x = x, .y = y, .w = w + 2, .h = h };
    p.fill(box, .{ .fg = th.fg, .bg = th.cursor_line });
    paintFrame(p, box, th.overlayBorder());
    for (m.items, 0..) |it, i| {
        const row_y = y + 1 + @as(u16, @intCast(i));
        const selected = i == m.selected;
        const style: Style = if (selected) th.chipActive() else .{ .fg = th.fg, .bg = th.cursor_line };
        p.fill(.{ .x = x + 1, .y = row_y, .w = w, .h = 1 }, style);
        switch (it) {
            .action => |a| {
                const b = keymap.bindingOf(a) orelse continue;
                const line = try std.fmt.allocPrint(arena, " {s}", .{b.title});
                _ = p.text(x + 1, row_y, w, line, style);
                const key = keymap.keyLabel(b.keys[0]);
                _ = p.text(x + 1 + w -| (Painter.width(key) + 1), row_y, Painter.width(key), key, .{ .fg = if (selected) style.fg else th.muted, .bg = style.bg });
            },
            // A chip's value: the tick on the live one(s), a blank of
            // the same width on the rest so the words line up.
            .pick => {
                const v: app_mod.PickItem = if (i < m.values.len) m.values[i] else .{ .label = "" };
                const line = try std.fmt.allocPrint(arena, " {s} {s}", .{ if (v.checked) tick else " ", v.label });
                _ = p.text(x + 1, row_y, w, line, style);
            },
            .open_url => |o| _ = p.text(x + 1, row_y, w, try std.fmt.allocPrint(arena, " {s}", .{o.label}), style),
            .cancel => _ = p.text(x + 1, row_y, w, " cancel", style),
        }
        p.app.hits.add(.{ .x = x, .y = row_y, .w = w + 2, .h = 1 }, .{ .menu_item = i });
    }
}

/// A chip's picker over the list: the tracker pane's picker shape — a
/// centred box titled with the chip's word, a typed filter on its
/// first line, the rows on the toolkit's row ground, `[x]` on a
/// multi-select's rows and a tick on a single-select's live one.
fn paintPicker(arena: Allocator, p: *Painter) Allocator.Error!void {
    const app = p.app;
    const th = p.th;
    const pk = &(app.picker orelse return);
    const w: u16 = @min(p.f.cols -| 2, 60);
    const h: u16 = @min(p.f.rows -| 2, 18);
    if (w < 16 or h < 6) return;
    const x = (p.f.cols - w) / 2;
    const y = (p.f.rows - h) / 2;
    const box: Box = .{ .x = x, .y = y, .w = w, .h = h };
    p.fill(box, .{ .fg = th.fg, .bg = th.cursor_line });
    paintFrame(p, box, th.overlayBorder());
    const title = try std.fmt.allocPrint(arena, " {s} ", .{pk.kind.word()});
    _ = p.text(x + 2, y, w -| 4, title, .{ .fg = th.accent, .bg = th.cursor_line, .mods = .{ .bold = true } });
    p.app.hits.add(.{ .x = x, .y = y, .w = w, .h = h }, .picker_body);
    const ix = x + 2;
    const iw = w -| 4;
    // The filter line: the search glyph, the query, a caret.
    var fx = ix;
    fx += p.text(fx, y + 1, iw, if (p.nerd) chrome.search_nerd else chrome.search_ascii, .{ .fg = th.accent, .bg = th.cursor_line }) + 1;
    if (pk.query.items.len > 0) {
        fx += p.text(fx, y + 1, iw -| (fx - ix), pk.query.items, .{ .fg = th.fg, .bg = th.cursor_line });
    } else {
        fx += p.text(fx, y + 1, iw -| (fx - ix), if (p.nerd) chrome.placeholder_focused else chrome.placeholder_focused_ascii, .{ .fg = th.muted, .bg = th.cursor_line });
    }
    _ = p.text(fx, y + 1, 1, chrome.caret_glyph, .{ .fg = th.accent, .bg = th.cursor_line });
    const vis = try pk.visible(arena);
    const list_y = y + 3;
    const list_h: usize = h -| 5;
    var pos: usize = 0;
    for (vis, 0..) |i, k| if (i == pk.selected) {
        pos = k;
    };
    const start = if (pos >= list_h) pos + 1 - list_h else 0;
    const tick: []const u8 = if (p.nerd) tick_glyph else tick_ascii;
    var k = start;
    var ry = list_y;
    while (k < vis.len and ry < list_y + list_h) : ({
        k += 1;
        ry += 1;
    }) {
        const it = pk.items[vis[k]];
        const is_cur = vis[k] == pk.selected;
        try p.c.rowGround(.{ .x = x + 1, .y = ry, .w = w -| 2, .h = 1 }, is_cur, .{ .picker_row = vis[k] });
        var rx = ix + 1;
        if (pk.kind.multi()) {
            rx += p.text(rx, ry, 4, if (it.checked) "[x] " else "[ ] ", if (it.checked) .{ .fg = th.accent, .bg = if (is_cur) th.cursor_line else null } else .{ .fg = th.muted, .bg = if (is_cur) th.cursor_line else null });
        } else {
            rx += p.text(rx, ry, 2, if (it.checked) tick else " ", .{ .fg = th.accent, .bg = if (is_cur) th.cursor_line else null }) + 1;
        }
        _ = p.text(rx, ry, iw -| (rx - ix), it.label, .{ .fg = th.fg, .bg = if (is_cur) th.cursor_line else null, .mods = .{ .bold = is_cur } });
    }
    if (vis.len == 0) _ = p.text(ix, list_y, iw, "nothing matches", .{ .fg = th.muted, .bg = th.cursor_line });
}

/// The toolkit's frame (`+-+` under `--ascii`, which this pane's own
/// copy never had).
fn paintFrame(p: *Painter, b: Box, style: Style) void {
    p.c.frameBox(.{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, style);
}

/// The key sheet: the family's one component
/// (`sdk.pane.chrome.Painter.keySheet`), fed the bindings that apply
/// here, by section — the same sheet the Jira pane opens.
fn paintSheet(arena: Allocator, p: *Painter) Allocator.Error!void {
    const app = p.app;
    const shown = try app.visible(arena);
    const ctx = app.keyContext(shown.rows);
    var rows: std.ArrayList(Chrome.SheetRowSpec) = .empty;
    for (keymap.sections) |sec| {
        var any = false;
        var tabs_row = false;
        for (&keymap.table) |b| {
            if (!std.mem.eql(u8, b.section, sec) or !ctx.allows(b.scope)) continue;
            if (!any) try rows.append(arena, .{ .section = sec });
            any = true;
            // `1`…`9` is one row, as the Jira sheet has it.
            if (b.action.tabNumber() != null) {
                if (tabs_row) continue;
                tabs_row = true;
                try rows.append(arena, .{ .chord = "1-9", .label = "tab by number" });
                continue;
            }
            // A row of the sheet runs what its chord runs: reading
            // the keys and using them are the same gesture.
            try rows.append(arena, .{ .chord = try sdk.pane.keysheet.chords(arena, b.keys), .label = b.title, .target = .{ .sheet_row = b.action } });
        }
    }
    try p.c.keySheet(rows.items, &app.help_scroll, .sheet);
}

// ─── the text of a frame, for the tests ──────────────────────────────────

/// Row `y` as text, a wide glyph's tail skipped.
pub fn rowText(arena: Allocator, f: *sdk.Frame, y: u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var x: u16 = 0;
    while (x < f.cols) : (x += 1) {
        const s = f.slots[@as(usize, y) * f.cols + x].symbol();
        if (s.len == 0) continue;
        try out.appendSlice(arena, s);
    }
    return std.mem.trimEnd(u8, try out.toOwnedSlice(arena), " ");
}

pub fn screenText(arena: Allocator, f: *sdk.Frame) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var y: u16 = 0;
    while (y < f.rows) : (y += 1) {
        if (y > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, try rowText(arena, f, y));
    }
    return out.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const Rig = app_mod.Rig;

const acme: cfg.Config = .{ .email = "me@x.com", .workspace = "acme", .repos = &.{ "api", "web" }, .refresh_interval_secs = 0, .tabs = &cfg.default_tabs };

/// The tree's chevrons, as every other tree on the screen folds.
const open_ch = chrome.open_glyph;
const closed_ch = chrome.closed_glyph;

const Screen = struct {
    rig: *Rig,
    frame: sdk.Frame,
    arena: std.heap.ArenaAllocator,

    fn init(cols: u16, rows: u16, config: cfg.Config, opts: app_mod.Options) !*Screen {
        const s = try t.allocator.create(Screen);
        s.rig = try Rig.init(config, opts);
        s.frame = try sdk.Frame.init(t.allocator, cols, rows);
        s.arena = std.heap.ArenaAllocator.init(t.allocator);
        return s;
    }

    fn deinit(s: *Screen) void {
        s.frame.deinit();
        s.rig.deinit();
        s.arena.deinit();
        t.allocator.destroy(s);
    }

    fn draw(s: *Screen) ![]const u8 {
        _ = s.arena.reset(.retain_capacity);
        try paint(s.arena.allocator(), &s.frame, &s.rig.app, true);
        return screenText(s.arena.allocator(), &s.frame);
    }

    fn key(s: *Screen, spec: []const u8) !void {
        _ = try s.rig.key(spec);
    }

    fn click(s: *Screen, col: u16, row: u16, button: App.Button) !void {
        _ = try s.rig.app.click(col, row, button);
        try s.rig.drain();
    }

    fn rowOf(s: *Screen, text: []const u8) !u16 {
        const scr = try s.draw();
        var it = std.mem.splitScalar(u8, scr, '\n');
        var y: u16 = 0;
        while (it.next()) |line| : (y += 1) if (std.mem.indexOf(u8, line, text) != null) return y;
        std.debug.print("no row contains `{s}`:\n{s}\n", .{ text, scr });
        return error.NoSuchRow;
    }
};

fn has(scr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, scr, needle) != null;
}

test "the pane paints the header, the strip, the pill, the reference's columns, the rows and the hint row" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    const scr = try s.draw();
    try t.expect(has(scr, "BITBUCKET PRS"));
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(has(scr, " 1 Open + Draft (3) "));
    try t.expect(has(scr, " 2 Merged (2) "));
    try t.expect(has(scr, " 3 Pipelines (2)"));
    try t.expect(has(scr, "/ filter"));
    try t.expect(has(scr, "REPO / #PR"));
    try t.expect(has(scr, "STATE"));
    try t.expect(has(scr, "AUTHOR"));
    try t.expect(has(scr, "BRANCH"));
    try t.expect(has(scr, "UPDATED"));
    try t.expect(has(scr, "TITLE"));
    try t.expect(has(scr, "▌ " ++ open_ch ++ " api"));
    // The reference's `▾` / `▸` triangles are gone: the rows fold with
    // the toolkit's chevron, the one the host's file tree and the
    // tracker pane's tree wear.
    try t.expect(!has(scr, "▾"));
    try t.expect(!has(scr, "▸"));
    try t.expect(has(scr, "2 PRs"));
    // `web` has one: the noun agrees with it
    // (hunt/findings-2026-09-23/integ-bb-one-prs.md).
    try t.expect(has(scr, "1 PR "));
    try t.expect(!has(scr, "1 PRs"));
    try t.expect(has(scr, "#1234"));
    try t.expect(has(scr, "Fix the login redir"));
    try t.expect(has(scr, "chris/fix-login"));
    try t.expect(has(scr, "Show more (1)"));
    // The web bar, as a toolbar row under the strip: Status, Author,
    // Target branch, the Reviewing / All selector — every one a chip
    // with its live value, every one a hit.
    try t.expect(has(scr, " status: Open + Draft "));
    try t.expect(has(scr, " author: all "));
    try t.expect(has(scr, " target: any "));
    try t.expect(has(scr, " show: all"));
    for ([_]hit.Chip{ .status, .author, .target, .show }) |c| try t.expect(s.rig.app.hits.rectOf(.{ .chip = c }) != null);
    // The caps header is the TOOLKIT's, not a copy of it: the title in
    // `label()` and the ladder ending in the refresh chip then `?`,
    // both on the chip ground. Asserted through `sdk.pane.expect`, the
    // same function the tracker pane's own suite calls, so the two
    // families cannot drift into checking two different things.
    try sdk.pane.expect.capsTitleInk(&s.frame, s.rig.app.theme, 1, 0, "BITBUCKET PRS");
    // And the app-colour stripe runs the whole height of the pane —
    // the same assertion the tracker pane's own suite makes of its
    // board, where the kanban columns used to paint over it.
    try sdk.pane.expect.gutterFullHeight(&s.frame, s.rig.app.theme, 0, 0, s.frame.rows - 1, false);
    try sdk.pane.expect.headerLadderTail(&s.frame, s.rig.app.theme, 0, true, false);
    try t.expect(has(scr, "Open + Draft · 2 repos, 3 PRs"));
    try t.expect(has(scr, "Enter expand"));
    try t.expect(has(scr, "q quit"));
    // The reference painted four chips that did nothing when clicked
    // (`filter not wired yet (round-1 visual)`); the pane cut them.
    // They are back, and they work: the pipelines family's bar is the
    // web's — Run by, Branch, Pipeline type, Status, Trigger type.
    try s.key("3");
    const pipelines = try s.draw();
    try t.expect(has(pipelines, " run by: any "));
    try t.expect(has(pipelines, " branch: any "));
    try t.expect(has(pipelines, " type: any "));
    try t.expect(has(pipelines, " status: any "));
    try t.expect(has(pipelines, " trigger: any"));
    for ([_]hit.Chip{ .run_by, .branch, .ptype, .pstatus, .trigger }) |c| try t.expect(s.rig.app.hits.rectOf(.{ .chip = c }) != null);
    try t.expect(has(pipelines, "REPO / BRANCH"));
    // A PR chip is not on a pipelines tab, and the other way round.
    try t.expect(!has(pipelines, "show:"));
    try t.expect(s.rig.app.hits.rectOf(.{ .chip = .show }) == null);
}

test "an open PR's chevron folds its builds under the mouse" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    const y = try s.rowOf("Fix the login redir");
    // The chevron is its own target, four cells in from the gutter.
    const at = s.rig.app.hits.at(4, y) orelse return error.NoChevron;
    try t.expect(at == .chevron);
    // A click on the row's WORDS only selects it: the builds stay
    // folded, so the pointer cannot lose a row by brushing it.
    try s.click(40, y, .left);
    var scr = try s.draw();
    try t.expect(has(scr, closed_ch ++ " #1234"));
    try t.expect(!has(scr, "fetching builds"));
    // A click on the chevron folds them out. It used to do nothing at
    // all on an open pull request: the click path folded a MERGED one
    // and nothing else, while the row painted a chevron either way.
    try s.click(4, y, .left);
    scr = try s.draw();
    try t.expect(has(scr, open_ch ++ " #1234"));
    // …and again folds them back.
    try s.click(4, y, .left);
    scr = try s.draw();
    try t.expect(has(scr, closed_ch ++ " #1234"));
}

test "the fold row is one phrase: the ellipsis is punctuation and only its words are bright" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    const y = try s.rowOf("Show more (1)");
    // `⋯  Show more (N)` — the ellipsis dim, two cells of air, the
    // words in the bright foreground a key wears, and the three of
    // them next to one another. Asserted through `sdk.pane.expect`,
    // the same function the tracker pane's own suite calls: this row
    // used to be laid by the table here and by `showMoreRow` there,
    // which put the ellipsis in two different places.
    try sdk.pane.expect.foldRow(&s.frame, s.rig.app.theme, y, false);
    // And it is one press: the whole row is the row's own hit.
    try t.expect(s.rig.app.hits.at(4, y).? == .row);
}

test "a click on a row selects that row and toggles a header; the strip switches tabs; the hints fire" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    const y_1234 = try s.rowOf("OPEN       Chris M");
    try s.click(10, y_1234, .left);
    try t.expectEqual(@as(usize, 1), s.rig.app.tabs[0].selected);
    var scr = try s.draw();
    // The cursor's marker, the row's own chevron (every PR has builds
    // to fold out now), then its number.
    try t.expect(has(scr, "▌   " ++ closed_ch ++ " #1234"));
    const y_api = try s.rowOf(open_ch ++ " api");
    try s.click(3, y_api, .left);
    scr = try s.draw();
    try t.expect(has(scr, closed_ch ++ " api"));
    // The header keeps its preview of #1234; the PR row itself is gone.
    try t.expect(has(scr, "#1234 · Fix the login"));
    try t.expect(!has(scr, "Fix the login redir"));
    // The strip.
    const hit_tab = s.rig.app.hits.rectOf(.{ .tab = 1 }).?;
    try s.click(hit_tab.x + 2, hit_tab.y, .left);
    try t.expectEqual(@as(usize, 1), s.rig.app.active);
    scr = try s.draw();
    try t.expect(has(scr, "MERGED"));
    try t.expect(has(scr, "#1100"));
    // A hint word is a key: `q` quits.
    _ = try s.draw();
    const hint_q = s.rig.app.hits.rectOf(.{ .hint = .quit }).?;
    try t.expect(!(try s.rig.app.click(hint_q.x, hint_q.y, .left)));
}

test "a PR folds out to its builds under enter, one row per run, and the detail paints beside the list" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    try s.key("2");
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, closed_ch ++ " #1100"));
    try s.key("enter");
    scr = try s.draw();
    try t.expect(has(scr, open_ch ++ " #1100"));
    // The toolkit's build line, the same one the Jira pane paints:
    // state, branch, age, number.
    try t.expect(has(scr, "\u{2713} SUCCESSFUL \u{b7} main \u{b7} "));
    try t.expect(has(scr, "\u{b7} #412"));
    try s.key("d");
    scr = try s.draw();
    try t.expect(has(scr, "acme/api#1100"));
    try t.expect(has(scr, "MERGED · sam/drop-exporter → main"));
    try t.expect(has(scr, "author: Sam K"));
    try t.expect(has(scr, "✓ you approved · 1 total"));
    try t.expect(has(scr, "(no description)"));
    try t.expect(has(scr, "comments (0, most-recent first):"));
    try t.expect(has(scr, "│"));
    // Below 100 columns the detail takes the body.
    const narrow = try Screen.init(80, 24, acme, .{});
    defer narrow.deinit();
    try narrow.key("j");
    try narrow.key("d");
    const nscr = try narrow.draw();
    try t.expect(has(nscr, "acme/api#1234"));
    try t.expect(has(nscr, "○ not approved · 1 total"));
    // A comment's body, wrapped into the narrow panel. (Dana's "Nice
    // catch" is the oldest of the three and now sits one row below the
    // fold — the tab strip's rule costs the body a row.)
    try t.expect(has(nscr, "withQuery needs to escape"));
    try t.expect(!has(nscr, "REPO / #PR"));
}

test "a PR row's buttons are always there: words at 140, glyphs at 80, hit = paint" {
    // Wide: the glyph AND the word, each a hit the width of the cells
    // it painted.
    {
        const s = try Screen.init(140, 24, acme, .{});
        defer s.deinit();
        try s.key("j");
        _ = try s.draw();
        try sdk.pane.expect.actionRun(hit.Target, &s.frame, &s.rig.app.hits.inner, s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .open } }).?.y, &.{
            .{ .pr_button = .{ .row = 1, .which = .open } },
            .{ .merge_blocked = 1 },
        }, .icon_label);
    }
    // Narrow: the SAME buttons, one cell each. This pane used to drop
    // them whole below ~135 columns — on the CURSOR's row, the one row
    // that can act — so at the two sizes the corpus runs at they were
    // never available at all.
    {
        const s = try Screen.init(80, 24, acme, .{});
        defer s.deinit();
        try s.key("j");
        _ = try s.draw();
        const r = s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .open } }).?;
        try sdk.pane.expect.actionRun(hit.Target, &s.frame, &s.rig.app.hits.inner, r.y, &.{
            .{ .pr_button = .{ .row = 1, .which = .open } },
            .{ .merge_blocked = 1 },
        }, .icon);
        // And the pointer names what the glyph cannot.
        s.rig.app.hover(r.x, r.y);
        try t.expectEqualStrings("Open", s.rig.app.hoverNote());
    }
}

test "every PR row carries its buttons, the Merge is dim, and hovering it says why" {
    // Wide enough for the words. Below that the run reduces to its
    // glyphs — it is never dropped, which is what this pane used to do
    // below ~135 columns, on the one row that could act.
    const s = try Screen.init(200, 40, acme, .{});
    defer s.deinit();
    // The cursor onto #1234.
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, "[\u{f03cc} Open] [\u{f062d} Merge]"));
    // EVERY open pull request carries them now, not just the cursor's:
    // the acme fake has two, and the second is merged, so it has an
    // `Open` and no `Merge`.
    try t.expect(std.mem.count(u8, scr, "[\u{f062d} Merge]") >= 1);
    try t.expect(std.mem.count(u8, scr, "[\u{f03cc} Open]") >= 2);

    // Landing on the row took its one readiness look, and #1234 is
    // blocked: the button registers `merge_blocked` rather than a
    // `pr_button`, so a stray click cannot merge anything.
    const at = s.rig.app.hits.rectOf(.{ .merge_blocked = 1 }).?;
    try t.expect(s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .merge } }) == null);
    // …and the pointer resting on it puts the reason on the hint row.
    // Sam asked for changes on #1234, which outranks every other
    // condition.
    s.rig.app.hover(at.x + 2, at.y);
    scr = try s.draw();
    try t.expect(has(scr, "Merge: a reviewer asked for changes"));

    // Judged and blocked: the reason names the condition and its count.
    const ts = s.rig.app.activeTab();
    const pr = ts.data.repo_pr_tree[0].prs[0];
    try s.rig.app.putReadiness("api#1234", pr.updated_on, .{ .approvals = 1, .required = 2, .conflicts = false, .build_green = true, .checked = true });
    s.rig.app.hover(at.x + 2, at.y);
    scr = try s.draw();
    try t.expect(has(scr, "Merge: 1 of 2 approvals"));

    // Ready: the button becomes a real target, and the pointer moving
    // off it takes the sentence away with it.
    try s.rig.app.putReadiness("api#1234", pr.updated_on, .{ .approvals = 2, .required = 2, .conflicts = false, .build_green = true, .checked = true });
    scr = try s.draw();
    try t.expect(s.rig.app.hits.rectOf(.{ .pr_button = .{ .row = 1, .which = .merge } }) != null);
    s.rig.app.hover(0, 0);
    scr = try s.draw();
    try t.expect(!has(scr, "Merge: "));

    // Confirming it names the pull request rather than asking "are you
    // sure?" about nothing in particular.
    try s.rig.app.pressMerge("api", pr);
    scr = try s.draw();
    try t.expect(has(scr, "Merge acme/api/pull-requests/1234"));
    try t.expect(has(scr, "Fix the login redir"));
    try t.expect(has(scr, "chris/fix-login \u{2192} main"));
    try t.expect(has(scr, "strategy: merge commit"));
    try t.expect(has(scr, "merged by a Claude Code session, not by this pane"));
    try t.expect(has(scr, " Merge "));
    try t.expect(has(scr, " Cancel "));
    // Esc takes it away without doing anything.
    try s.key("esc");
    scr = try s.draw();
    try t.expect(!has(scr, "Merge acme/api/pull-requests/1234"));
}

test "the show chip cycles all → reviewing → awaiting me, says its count, narrows the tab, and the header says so" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    var scr = try s.draw();
    try t.expect(has(scr, " show: all"));
    try t.expect(has(scr, "(2 repos \u{b7} 3 PRs)"));
    try t.expect(has(scr, "#1234"));

    // `A` is the same door the chip is — a chip nobody can reach from
    // the keyboard is half a feature. (mnml spells it `shift+a`.)
    // Reviewing: what I am a reviewer on, voted or not — #1198 only
    // (#1100 is merged, off the open tab; my own two are not mine to
    // review).
    try s.key("shift+a");
    scr = try s.draw();
    try t.expect(has(scr, " show: reviewing"));
    // `N of M` the way the `/` filter says it: of the rows the tab
    // shows unnarrowed (two — the day-old #1198 sits behind the fold).
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "#1198"));
    try t.expect(!has(scr, "Fix the login redir"));
    // Awaiting me: the chip carries its count, and the header still
    // says how much of the tab is hidden.
    try s.key("shift+a");
    scr = try s.draw();
    try t.expect(has(scr, " show: awaiting me (1)"));
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "#1198"));
    // …and it is 30 hours old, so the 24-hour window the tree usually
    // folds it behind is lifted rather than hiding the very thing the
    // chip is for.
    try t.expect(!has(scr, "Show more"));

    // A click on the chip cycles it round to all — three values, so it
    // cycles the way the host's `sort:` chip does.
    const chip = s.rig.app.hits.rectOf(.{ .chip = .show }).?;
    try s.click(chip.x + 1, chip.y, .left);
    scr = try s.draw();
    try t.expect(has(scr, " show: all"));
    try t.expect(has(scr, "(2 repos \u{b7} 3 PRs)"));
    try t.expect(has(scr, "Fix the login redir"));

    // A right click lists every value with the live one ticked, and a
    // row of that menu applies it.
    try s.click(chip.x + 1, chip.y, .right);
    scr = try s.draw();
    try t.expectEqual(app_mod.Mode.menu, s.rig.app.mode);
    try t.expect(has(scr, tick_glyph ++ " all"));
    try t.expect(has(scr, "  reviewing"));
    try t.expect(has(scr, "  awaiting me"));
    const row = s.rig.app.hits.rectOf(.{ .menu_item = 2 }).?;
    try s.click(row.x + 2, row.y, .left);
    scr = try s.draw();
    try t.expectEqual(app_mod.Mode.list, s.rig.app.mode);
    try t.expect(has(scr, " show: awaiting me (1)"));
}

test "an OPEN PR folds out to the builds on its branch head; a second open costs nothing while it has not moved" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    // The cursor onto #1234, the open pull request the account authored.
    try s.key("j");
    var scr = try s.draw();
    try t.expect(has(scr, closed_ch ++ " #1234"));
    const served = s.rig.srv.state.served;
    try s.key("enter");
    try s.rig.drain();
    scr = try s.draw();
    try t.expect(has(scr, open_ch ++ " #1234"));
    // One run on `chris/fix-login`'s head, in the toolkit's words.
    try t.expect(has(scr, "\u{23f5} IN_PROGRESS \u{b7} chris/fix-login \u{b7} "));
    try t.expect(has(scr, "\u{b7} #413"));
    // One request paid for it: the repo's pipelines list.
    try t.expectEqual(@as(u32, 1), s.rig.srv.state.served - served);

    // Fold shut and open again: nothing is asked for, because the pull
    // request has not moved since the runs were read.
    try s.key("enter");
    try s.rig.drain();
    try s.key("enter");
    try s.rig.drain();
    try t.expectEqual(@as(u32, 1), s.rig.srv.state.served - served);
    scr = try s.draw();
    try t.expect(has(scr, "\u{b7} #413"));

    // The build line is a door: Enter on it opens that run's page.
    const rows = try s.rig.rows();
    var build_row: ?usize = null;
    for (rows, 0..) |r, i| if (r == .build) {
        build_row = i;
        break;
    };
    s.rig.app.tabs[0].selected = build_row.?;
    // Straight at the app: the rig's own `key` drains the effects,
    // and the effect IS what this asserts.
    _ = try s.rig.app.keyPress("enter");
    const fx = s.rig.app.takeEffects();
    defer s.rig.app.freeEffects(fx);
    // The page, and the toast that says which page.
    try t.expectEqual(@as(usize, 2), fx.len);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pipelines/results/413", fx[0].open_url);

    // And so is a CLICK on it. This pane's build line is a table cell
    // rather than a free row, so it fell through to the generic row
    // hit and a click only selected — the line read as a link and
    // behaved as one nowhere. `sdk.pane.buildHit` is the door both
    // panes register and `sdk.pane.expect.buildLineHit` the assertion
    // both suites call: the WHOLE line, indent and trailing air
    // included, not just the cells the caption fills.
    _ = try s.draw();
    const by = s.rig.app.hits.rectOf(.{ .build_line = build_row.? }).?;
    try sdk.pane.expect.buildLineHit(hit.Target, &s.rig.app.hits.inner, by.y, by.x, by.right(), .{ .build_line = build_row.? });
    _ = try s.rig.app.click(by.x + 1, by.y, .left);
    const fx2 = s.rig.app.takeEffects();
    defer s.rig.app.freeEffects(fx2);
    try t.expect(fx2.len > 0);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pipelines/results/413", fx2[0].open_url);
}

test "the pipelines tree paints the reference's columns and glyphs; the pipelines chips are on the header" {
    const s = try Screen.init(120, 40, acme, .{ .only = .pipelines });
    defer s.deinit();
    const scr = try s.draw();
    try t.expect(has(scr, "BITBUCKET PIPELINES"));
    try t.expect(!has(scr, " 1 Pipelines"));
    try t.expect(has(scr, "REPO / BRANCH"));
    try t.expect(has(scr, "BUILD"));
    try t.expect(has(scr, "RESULT"));
    try t.expect(has(scr, open_ch ++ " api"));
    try t.expect(has(scr, "4 branches"));
    try t.expect(has(scr, "main"));
    try t.expect(has(scr, "COMPLETED"));
    try t.expect(has(scr, "#412"));
    try t.expect(has(scr, "✓ SUCCESSFUL"));
    try t.expect(has(scr, "✗ FAILED"));
    try t.expect(has(scr, "IN_PROGRESS"));
    try t.expect(has(scr, "run pipeline"));
    try t.expect(has(scr, "usage"));
    try t.expect(s.rig.app.hits.rectOf(.{ .chip = .usage }) != null);
    // The hint row offers only what does something here: no PR detail,
    // no approve, no open↔merged (integ-bb-pipelines-dead-actions).
    const hint = try rowText(s.arena.allocator(), &s.frame, 39);
    try t.expect(!has(hint, "d detail"));
    try t.expect(!has(hint, "approve"));
    try t.expect(!has(hint, "merged"));
    try t.expect(has(hint, "r refresh"));
}

test "the pipelines header at 80x24: the chips drop to their icons and the repo count stays whole; at 120x40 they say their words" {
    // At 80 columns the four page chips' words pushed the count under
    // the ladder and it clipped mid-word: `BITBUCKET PIPELINES  (2 re`.
    {
        const s = try Screen.init(80, 24, acme, .{ .only = .pipelines });
        defer s.deinit();
        const scr = try s.draw();
        const head = scr[0 .. std.mem.indexOfScalar(u8, scr, '\n') orelse scr.len];
        try t.expect(has(head, "BITBUCKET PIPELINES  (2 repos)"));
        try t.expect(!has(head, "run pipeline"));
        try t.expect(!has(head, "schedules"));
        try t.expect(has(head, run_nerd));
        try t.expect(has(head, schedules_nerd));
        try t.expect(has(head, caches_nerd));
        try t.expect(has(head, usage_nerd));
        // Every page is still a door: one hit per chip, three cells
        // each, right of the count.
        for ([_]hit.Chip{ .run_pipeline, .schedules, .caches, .usage, .refresh, .help }) |c| {
            const r = s.rig.app.hits.rectOf(.{ .chip = c }).?;
            try t.expectEqual(@as(u16, 0), r.y);
            try t.expectEqual(@as(u16, 3), r.w);
            try t.expect(r.x > 1 + sdk.pane.text.width("BITBUCKET PIPELINES  (2 repos)"));
        }
        // The filter chips fold onto the rows under the header rather
        // than clip: every one is on screen.
        for ([_][]const u8{ "run by:", "branch:", "type:", "status:", "trigger:" }) |w| try t.expect(has(scr, w));
    }
    {
        const s = try Screen.init(120, 40, acme, .{ .only = .pipelines });
        defer s.deinit();
        const scr = try s.draw();
        const head = scr[0 .. std.mem.indexOfScalar(u8, scr, '\n') orelse scr.len];
        try t.expect(has(head, "BITBUCKET PIPELINES  (2 repos)"));
        for ([_][]const u8{ " run pipeline ", " schedules ", " caches ", " usage " }) |w| try t.expect(has(head, w));
        try t.expect(!has(head, run_nerd));
    }
}

test "the key sheet, the row menu and the filter paint as overlays that take the click" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    // The header's `?` chip is the sheet's door for the pointer — the
    // one the tracker pane has always had and this one did not, so the
    // only way in was the hint row's `? keys`, which is the first entry
    // a narrow pane drops.
    _ = try s.draw();
    try s.click(s.frame.cols - 3, 0, .left);
    try t.expectEqual(app_mod.Mode.help, s.rig.app.mode);
    try s.key("esc");
    try s.key("?");
    var scr = try s.draw();
    try t.expect(has(scr, " Keys "));
    try t.expect(has(scr, "── tree ──"));
    try t.expect(has(scr, "hide this repo (persists)"));
    try t.expect(has(scr, "the pull request's detail"));
    // Only the keys that apply here: `a` wants the detail open.
    try t.expect(!has(scr, "approve / withdraw the approval"));
    try t.expect(has(scr, "j/k scroll · Esc close"));
    // A press on the sheet off its rows (its top edge) closes it and
    // runs nothing; a press on a row runs that row's key.
    const sheet = s.rig.app.hits.inner.rectOf(.sheet).?;
    try s.click(sheet.x + 1, sheet.y, .left);
    try t.expectEqual(app_mod.Mode.list, s.rig.app.mode);
    _ = try s.draw();
    const y_1234 = try s.rowOf("OPEN       Chris M");
    try s.click(10, y_1234, .right);
    scr = try s.draw();
    try t.expect(has(scr, "the pull request's detail"));
    try t.expect(has(scr, "open on the web"));
    const item = s.rig.app.hits.rectOf(.{ .menu_item = 1 }).?;
    try s.click(item.x + 2, item.y, .left);
    try t.expect(std.mem.startsWith(u8, s.rig.app.status.items, "opened https://bitbucket.org/acme/api/pull-requests/1234"));
    try s.key("/");
    for ("login") |c| try s.key(&[_]u8{c});
    scr = try s.draw();
    try t.expect(has(scr, "login▏"));
    try t.expect(has(scr, "Fix the login redir"));
    try t.expect(!has(scr, "Redesign the empty"));
}

test "the header says what a fetch is doing: queued behind N, waiting, fetching, failed, nothing matches — and the refresh chip turns the ring" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    const app = &s.rig.app;
    // The refresh chip's glyph, read off the cell its hit registered
    // — the chip is ` <glyph> `, so the glyph is one cell in.
    const chipGlyph = struct {
        fn f(scr_: *Screen) []const u8 {
            const r = scr_.rig.app.hits.rectOf(.{ .chip = .refresh }) orelse return "";
            return scr_.frame.slots[@as(usize, r.y) * scr_.frame.cols + r.x + 1].symbol();
        }
    }.f;
    // At rest: the count, the age, the refresh glyph, no fetch line.
    var scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(has(scr, "as of"));
    try t.expect(!has(scr, "fetching"));
    try t.expectEqualStrings(chrome.refresh_nerd, chipGlyph(s));

    // A refetch over rows already there: the count stays, the fetch
    // line joins it, and the refresh chip is the spinner's frame for
    // this clock — the host's ring at the host's step.
    app.tabs[0].loading = true;
    app.now_ms = 160;
    app.wait_notice.setPhase(.sending, 0);
    scr = try s.draw();
    // The count, then the fetch, then the age the toolkit lays after
    // the subtitle: `(2 repos · 3 PRs)  ⠹ fetching…  as of 0s ago`.
    try t.expect(has(scr, "(2 repos · 3 PRs)  \u{2839} fetching\u{2026}"));
    try t.expect(has(scr, "as of"));
    try t.expectEqualStrings("\u{2839}", chipGlyph(s));
    try t.expect(!has(scr, chrome.refresh_nerd));
    try t.expect(has(scr, "#1234"));
    // Queued behind the broker: the number the reader was missing —
    // and the ring has turned a step with the clock.
    app.wait_notice.setPhase(.queued, 3);
    app.now_ms = 240;
    scr = try s.draw();
    try t.expect(has(scr, "\u{2838} queued behind 3 requests"));
    try t.expectEqualStrings("\u{2838}", chipGlyph(s));
    try t.expect(!has(scr, "fetching"));
    // Held on the file bucket, with no broker to say how many.
    app.wait_notice.setPhase(.waiting, 0);
    scr = try s.draw();
    try t.expect(has(scr, "waiting for the API budget"));
    // A first load counts the repos as they land and has no count of
    // its own to keep.
    app.wait_notice.setPhase(.sending, 0);
    app.tabs[0].fetched = false;
    app.now_ms = 160;
    scr = try s.draw();
    try t.expect(has(scr, "BITBUCKET PRS  \u{2839} fetching\u{2026}"));
    try t.expect(!has(scr, "(2 repos"));
    app.tabs[0].fetched = true;
    // Landed: the line is gone and the glyph is back.
    app.tabs[0].loading = false;
    app.wait_notice.setPhase(.idle, 0);
    scr = try s.draw();
    try t.expect(!has(scr, "fetching"));
    try t.expectEqualStrings(chrome.refresh_nerd, chipGlyph(s));
    // A failure sits in the same place, in words, with no spinner.
    try app_mod.TabState.setText(app.gpa, &app.tabs[0].error_text, "401 auth failed");
    scr = try s.draw();
    try t.expect(has(scr, "fetch failed: 401 auth failed"));
    try t.expect(!has(scr, "\u{2839}"));
    // …over the rows it had, which stay: the failure is the header's,
    // not a panel painted where the list was.
    try t.expect(has(scr, "#1234"));
    try t.expect(!has(scr, "r retries"));
    try app_mod.TabState.setText(app.gpa, &app.tabs[0].error_text, "");
    // The chips hid every row: the header names that rather than
    // counting to zero.
    try app.setTextFilter(.target, "nobody/merges/here");
    scr = try s.draw();
    try t.expect(has(scr, "no pull requests match"));
    try t.expect(!has(scr, "(0 of"));
    try app.setTextFilter(.target, "");
    scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
}

test "the pane paints at every size the gate runs, and at one below them" {
    for ([_][2]u16{ .{ 30, 10 }, .{ 80, 24 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        const s = try Screen.init(size[0], size[1], acme, .{});
        defer s.deinit();
        _ = try s.draw();
        try s.key("d");
        _ = try s.draw();
        try s.key("?");
        _ = try s.draw();
        try s.key("esc");
        try s.key("3");
        _ = try s.draw();
    }
}

test "a list longer than its body carries the toolkit's scrollbar, the same one the tracker pane paints" {
    // A body short enough that the two repos' rows outrun it.
    const s = try Screen.init(80, 9, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    try sdk.pane.expect.listScrollbar(&s.frame, s.frame.cols - 1, 0, s.frame.rows);
}

test "the `/` filter: the header reads N of M while narrowed and the hint row changes with the mode" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    // Unnarrowed the header carries the tab's own count and the hint
    // row is the keymap's.
    var scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    // No `N of M`: the tab is not narrowed. (`as of …`, the freshness
    // the header now wears, carries an "of" of its own — hence the
    // closing bracket in the needle rather than a bare " of ".)
    try t.expect(!has(scr, " of 3)"));
    try t.expect(has(scr, "q quit"));

    // `/` opens the pill and hands the keyboard to the filter: the row
    // says what the filter answers to, not what the list does.
    try s.key("/");
    scr = try s.draw();
    try t.expect(has(scr, "type to filter"));
    try t.expect(has(scr, "Enter commit"));
    try t.expect(has(scr, "Esc clear"));
    try t.expect(!has(scr, "q quit"));

    // Typing narrows live — before Enter commits anything.
    for ("empty") |c| try s.key(&[_]u8{c});
    scr = try s.draw();
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "Redesign the empty"));
    // #1234 is gone as a row — the api header still previews it, which
    // is why the row count, not the title, is what proves the narrowing.
    try t.expectEqual(@as(usize, 1), s.rig.app.filter_shown);
    try t.expectEqual(@as(usize, 2), s.rig.app.filter_total);

    // Enter commits: the query stays, the narrowed count stays, the
    // hint row goes back to the list's keys.
    try s.key("enter");
    scr = try s.draw();
    try t.expect(has(scr, "(1 of 2)"));
    try t.expect(has(scr, "empty"));
    try t.expect(has(scr, "q quit"));
    try t.expect(!has(scr, "type to filter"));

    // Esc clears and leaves.
    try s.key("esc");
    scr = try s.draw();
    try t.expect(has(scr, "(2 repos · 3 PRs)"));
    try t.expect(!has(scr, " of 2)"));

    // The menu and the sheet own the row the same way.
    try s.key("j");
    try s.click(6, try s.rowOf("#1234"), .right);
    scr = try s.draw();
    try t.expect(has(scr, "Enter run"));
    try s.key("esc");
    try s.key("?");
    scr = try s.draw();
    try t.expect(has(scr, "scroll"));
}

/// Right-click the row the painter registered at `i` — through the
/// real hit map, so a row whose rectangle is wrong or missing fails
/// here rather than passing on a hand-built map.
fn rightClickRow(s: *Screen, i: usize) !void {
    _ = try s.draw();
    const r = s.rig.app.hits.rectOf(.{ .row = i }) orelse return error.NoHitForRow;
    try s.click(r.x + 2, r.y, .right);
}

fn menuItems(s: *Screen) []const app_mod.Action {
    _ = s.arena.reset(.retain_capacity);
    return s.rig.app.menuActions(s.arena.allocator()) catch &.{};
}

test "a right-click offers the actions of the row kind under it — every kind, off the painted hit map" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    var rows = try s.rig.rows();

    // The tree is api(#1234), web(#820), `Show more (1)`.
    try t.expect(rows[0] == .repo_header);
    try t.expect(rows[1] == .pr);
    try t.expect(rows[rows.len - 1] == .show_more);

    // A repo row: fold it, open it, copy it, hide it, move it.
    try rightClickRow(s, 0);
    try t.expectEqual(app_mod.Mode.menu, s.rig.app.mode);
    try t.expectEqual(@as(usize, 0), s.rig.app.menu.?.row);
    try t.expectEqualSlices(app_mod.Action, &.{ .activate, .open_web, .yank_url, .hide_repo, .reorder_up, .reorder_down }, menuItems(s));
    try s.key("esc");

    // A PR row: its detail, its page, its URL, and Enter — which folds
    // out its builds, on an open pull request as much as a merged one.
    // No approve: the reference binds `a` only with the detail open, so
    // the menu cannot offer it either.
    try rightClickRow(s, 1);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate, .merge_pr }, menuItems(s));
    try t.expectEqual(@as(usize, 1), s.rig.app.tabs[0].selected);
    try s.key("esc");

    // The same row with the detail open gains the one write.
    try s.key("d");
    try rightClickRow(s, 1);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate, .merge_pr, .toggle_approval }, menuItems(s));
    try s.key("esc");
    try s.key("d");

    // The `Show more (N)` footer lifts the window and nothing else.
    try rightClickRow(s, rows.len - 1);
    try t.expectEqualSlices(app_mod.Action, &.{.activate}, menuItems(s));
    try s.key("esc");

    // A merged PR folds out to the runs on what landed — the same
    // Enter, a different commit.
    try s.key("m");
    rows = try s.rig.rows();
    var merged: ?usize = null;
    for (rows, 0..) |r, i| if (r == .pr) {
        merged = i;
        break;
    };
    try rightClickRow(s, merged.?);
    try t.expectEqualSlices(app_mod.Action, &.{ .toggle_detail, .open_web, .yank_url, .activate }, menuItems(s));
    try s.key("esc");

    // A branch row on the pipelines tree: the run's page and its URL.
    try s.key("3");
    rows = try s.rig.rows();
    var branch: ?usize = null;
    for (rows, 0..) |r, i| if (r == .branch) {
        branch = i;
        break;
    };
    try rightClickRow(s, branch.?);
    try t.expectEqualSlices(app_mod.Action, &.{ .open_web, .yank_url }, menuItems(s));
    try t.expectEqual(branch.?, s.rig.app.tabs[2].selected);
    try s.key("esc");
    try t.expectEqual(app_mod.Mode.list, s.rig.app.mode);
}

/// The theme a colour test paints in: a `cursor_line` that is nothing
/// else on the screen, so "this cell is on the cursor row" is a fact
/// and not a coincidence.
fn bandedTheme() theme_mod.Theme {
    return theme_mod.Theme.fromHelloBranded(.{
        .fg = .{ .rgb = .{ 200, 200, 200 } },
        .bg = .{ .rgb = .{ 10, 10, 10 } },
        .muted = .{ .rgb = .{ 90, 90, 90 } },
        .accent = .{ .rgb = .{ 97, 175, 239 } },
        .cursor_line = .{ .rgb = .{ 44, 50, 60 } },
        .chip_bg = .{ .rgb = .{ 45, 45, 45 } },
        .chip_active_bg = .{ .rgb = .{ 152, 195, 121 } },
    }, "blue");
}

fn bgAt(f: *const sdk.Frame, x: u16, y: u16) ?sdk.Color {
    return f.slots[@as(usize, y) * f.cols + x].style.bg;
}

/// Every cell of `y` between `x0` and `x1` carries `want` as its
/// ground, bar the ones in `allow` — a chip on a row brings its own,
/// and that is the one thing that may sit on top of the band.
fn expectBand(f: *const sdk.Frame, y: u16, x0: u16, x1: u16, want: sdk.Color, allow: []const sdk.Color) !void {
    var x = x0;
    while (x < x1) : (x += 1) {
        const got = bgAt(f, x, y);
        if (got != null and std.meta.eql(got.?, want)) continue;
        if (got != null) {
            var ok = false;
            for (allow) |c| ok = ok or std.meta.eql(got.?, c);
            if (ok) continue;
        }
        std.debug.print("row {d} breaks at column {d}: `{s}` on {any}, wanted {any}\n", .{ y, x, f.slots[@as(usize, y) * f.cols + x].symbol(), got, want });
        return error.RowNotBanded;
    }
}

fn expectNoBand(f: *const sdk.Frame, y: u16, x0: u16, x1: u16, want: sdk.Color) !void {
    var x = x0;
    while (x < x1) : (x += 1) {
        const got = bgAt(f, x, y);
        if (got != null and std.meta.eql(got.?, want)) {
            std.debug.print("row {d} is banded at column {d}, and should not be\n", .{ y, x });
            return error.RowBanded;
        }
    }
}

test "the cursor row is a filled band across the whole row, and no row at rest is" {
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    const th = bandedTheme();
    s.rig.app.theme = th;
    const band = th.cursor_line;
    // A cursor row's `[ Open ]` / `[ Merge ]` chips paint on their own
    // ground; everything else on the row belongs to the band.
    const chip_grounds = [_]sdk.Color{ th.chip_bg, th.chip_active_bg };
    _ = try s.draw();
    const first = s.rig.app.hits.inner.rectOf(hit.Target{ .row = 0 }).?;
    try expectBand(&s.frame, first.y, first.x, first.x + first.w, band, &chip_grounds);
    const second = s.rig.app.hits.inner.rectOf(hit.Target{ .row = 1 }).?;
    try expectNoBand(&s.frame, second.y, second.x, second.x + second.w, band);
    // The band moves with the cursor rather than staying on row 0.
    try s.key("j");
    _ = try s.draw();
    try expectNoBand(&s.frame, first.y, first.x, first.x + first.w, band);
    const now = s.rig.app.hits.inner.rectOf(hit.Target{ .row = 1 }).?;
    try expectBand(&s.frame, now.y, now.x, now.x + now.w, band, &chip_grounds);
}

test "hover help names each element: a chip, a row, a hint entry, the refresh chip — never one generic blurb" {
    // hunt/findings-2026-09-23/integ-hover-help-generic.md
    const s = try Screen.init(120, 40, acme, .{});
    defer s.deinit();
    _ = try s.draw();
    const app = &s.rig.app;
    var buf: [96]u8 = undefined;
    const Probe = struct {
        fn at(a: *App, t_: hit.Target, b: []u8) ![]const u8 {
            const r = a.hits.rectOf(t_) orelse return error.NotPainted;
            return a.helpAt(r.x, r.y, b).title;
        }
    };
    try t.expectEqualStrings("status:", try Probe.at(app, .{ .chip = .status }, &buf));
    try t.expectEqualStrings("author:", try Probe.at(app, .{ .chip = .author }, &buf));
    try t.expectEqualStrings("Refresh", try Probe.at(app, .{ .chip = .refresh }, &buf));
    // The budget chip is in the header and says what it is.
    try t.expectEqualStrings("API budget", try Probe.at(app, .{ .chip = .budget }, &buf));
    try t.expectEqualStrings("Row", try Probe.at(app, .{ .row = 1 }, &buf));
    try t.expectEqualStrings("r — refresh this tab", try Probe.at(app, .{ .hint = .refresh }, &buf));
    // Nothing under the pointer: an empty title, which clears the view.
    try t.expectEqualStrings("", app.helpAt(0, 60, &buf).title);
}

test "the column header is the toolkit's, cell for cell what this pane painted before it moved into the SDK" {
    // The span painter this pane used for its header until
    // `sdk.pane.columns.header` took it over, kept here as the oracle.
    const Legacy = struct {
        fn paintHeader(f: *sdk.Frame, x0: u16, y: u16, max_w: u16, cols: []const view.Col, th: view.Theme) void {
            const style: Style = .{ .fg = th.muted, .mods = .{ .bold = true } };
            var x = x0;
            const end = x0 + max_w;
            for (cols, 0..) |c, i| {
                const spans = [_]struct { text: []const u8, w: u16 }{ .{ .text = " ", .w = view.gap }, .{ .text = c.name, .w = c.w } };
                for (spans[(if (i > 0) 0 else 1)..]) |sp| {
                    if (x >= end) return;
                    const room = end - x;
                    if (sp.w == 0) {
                        x += f.text(x, y, room, sp.text, style);
                    } else {
                        const w = @min(sp.w, room);
                        f.fill(x, y, w, 1, style);
                        _ = f.text(x, y, w, sp.text, style);
                        x += w;
                    }
                }
            }
        }
    };
    const th = view.Theme.fromHello(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .muted = .{ .rgb = .{ 4, 5, 6 } }, .bg = .{ .rgb = .{ 7, 8, 9 } } });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_]view.Table{ .pr_tree, .pipelines_tree, .pr_flat, .pipelines_flat, .branches_flat }) |table| {
        for ([_]u16{ 20, 43, 60, 80, 120, 200 }) |w| {
            const cols = try view.fit(arena.allocator(), table, w -| 3);
            var a = try sdk.Frame.init(t.allocator, w, 1);
            defer a.deinit();
            var b = try sdk.Frame.init(t.allocator, w, 1);
            defer b.deinit();
            a.clear(.{ .bg = th.bg });
            b.clear(.{ .bg = th.bg });
            Legacy.paintHeader(&a, 2, 0, w -| 3, cols, th);
            _ = sdk.pane.columns.header(&b, 2, 0, w -| 3, cols, view.gap, th);
            for (a.slots, b.slots) |x, y| {
                try t.expectEqualStrings(x.symbol(), y.symbol());
                try t.expect(std.meta.eql(x.style, y.style));
            }
        }
    }
}
