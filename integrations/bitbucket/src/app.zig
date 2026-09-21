//! The pane's state and what a key or a click does to it. Nothing here
//! paints (`screen.zig`) and nothing here talks to the network
//! (`fetch.zig` runs on the worker): the app turns input into changes
//! of state, queues the jobs it needs, commits their results when they
//! land, and queues the effects the loop carries out — a toast, a
//! browser, the clipboard, a statusline segment.
//!
//! The tabs are the reference's: resolved from the config, filtered by
//! `--only` to one family, with a `Mine` tab synthesised for
//! `--only prs-mine` when the config has none. The keys are the
//! reference's (`keymap.zig`). Where the reference persisted a change
//! (`x`, `H`, `s`, `alt+↑↓`) so does this, through `config.save`.
//!
//! Everything the screen paints is derived here on demand: the visible
//! rows of the active tab (`visible`), filtered by the `/` query, the
//! focused row's pull request, the hint row's context.

const std = @import("std");
const sdk = @import("mnml_sdk");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cfg = @import("config.zig");
const model = @import("model.zig");
const tabs = @import("tabs.zig");
const fetch = @import("fetch.zig");
const keymap = @import("keymap.zig");
const hit = @import("hit.zig");
const theme_mod = @import("theme.zig");
const dates = @import("dates.zig");

pub const Action = keymap.Action;
pub const Theme = theme_mod.Theme;

pub const ToastLevel = enum { info, warn, err };

/// What the loop does on the app's behalf after an event.
pub const Effect = union(enum) {
    /// `action` is the offer attached to the message — a label and a
    /// command the host runs or a page it opens
    /// (`sdk.wire.ToastAction`). A message that reports a merge and
    /// then vanishes leaves the reader with no door to the thing it
    /// merged; one that reports a failed refresh leaves them a stale
    /// list and no way back.
    toast: struct { level: ToastLevel, text: []const u8, action: ?sdk.wire.ToastAction = null },
    open_url: []const u8,
    copy: []const u8,
    /// The statusline chip: `󰂨 4(2)`, or the reference's `!` / `…`.
    segment: struct { text: []const u8, tooltip: []const u8 },
    /// Start a Claude Code session with this prompt. The pane never
    /// merges anything itself; this is how a confirmed merge happens.
    dispatch: struct { prompt: []const u8, row_key: []const u8, action: []const u8 },
    /// Bring a session mnml is running to the front.
    focus_session: struct { id: []const u8, cwd: []const u8, prompt_line: []const u8 },
    /// A desktop notification: the merge ended while the pane did not
    /// have the keyboard.
    notify: struct { title: []const u8, text: []const u8, bad: bool },
    quit,
};

pub const Mode = enum { list, filter, help, menu, confirm };

/// What one readiness look found, and the `updated_on` it was true at.
pub const ReadinessEntry = struct { updated_on: []const u8, readiness: sdk.pane.merge.Readiness };

/// The merge confirm that is up: everything it names, owned.
pub const MergeConfirm = struct {
    arena: std.heap.ArenaAllocator,
    row_key: []const u8,
    confirm: sdk.pane.merge.Confirm,
    allowed: []const sdk.pane.merge.Strategy,

    pub fn deinit(c: *MergeConfirm) void {
        c.arena.deinit();
        c.* = undefined;
    }
};

pub const TabState = struct {
    spec: tabs.TabSpec,
    data: tabs.TabData,
    /// Owns `data`; replaced by the next refresh.
    data_arena: ?std.heap.ArenaAllocator = null,
    expanded: tabs.Expanded,
    show_all: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    fetched: bool = false,
    /// Unix seconds the rows on screen last came back — what the
    /// header's `as of 4m ago` reads.
    fetched_at: i64 = 0,
    /// The PR the cursor was on when the refetch started — `ws/repo#id`,
    /// so the cursor can go back on it when the rows are swapped even
    /// though its row moved. Empty when it was not on one.
    keep_key_buf: [256]u8 = undefined,
    keep_key_len: usize = 0,
    loading: bool = false,
    /// The whole fetch failed.
    error_text: []u8 = &.{},
    /// `Open + Draft · 4 repos, 64 PRs`, owned.
    status: []u8 = &.{},
    repos: usize = 0,
    items: usize = 0,
    errored: usize = 0,

    fn deinit(ts: *TabState, gpa: Allocator) void {
        if (ts.data_arena) |*a| a.deinit();
        ts.expanded.deinit();
        gpa.free(ts.error_text);
        gpa.free(ts.status);
        ts.* = undefined;
    }

    fn setText(gpa: Allocator, slot: *[]u8, text: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, text);
        gpa.free(slot.*);
        slot.* = copy;
    }
};

pub const DetailEntry = struct {
    arena: std.heap.ArenaAllocator,
    pr: model.PullRequest,
    comments: []const model.Comment,
    error_text: []const u8 = "",
};

/// One queued `watch_session`, in the wire's own shape.
pub const WatchRequest = struct { key: []const u8, cwd: []const u8, prompt_line: []const u8 };

pub const PrPipelines = struct {
    arena: std.heap.ArenaAllocator,
    pipelines: []const model.Pipeline,
    error_text: []const u8 = "",
    /// The pull request's `updated_on` when these runs were read — the
    /// key that says whether they are still the right ones.
    updated_on: []const u8 = "",
};

/// A right-click menu over a row: the actions that apply to it.
pub const Menu = struct {
    row: usize,
    col: u16,
    y: u16,
    items: []const Action,
    selected: usize = 0,
};

pub const Options = struct {
    /// `--only prs` / `pipelines` / `branches`; null keeps every tab.
    only: ?cfg.Family = null,
    /// `--only prs-mine`: keep the `mode = mine` tabs, or synthesise one.
    mine: bool = false,
    /// `--only prs-awaiting`: open with the awaiting-my-review filter
    /// already on — what the `reviews_pending` chip's click asks for.
    awaiting: bool = false,
    /// `--focus <repo>#<id>`: the pull request to land the cursor on
    /// once the first listing is in. Empty asks for nothing.
    focus: []const u8 = "",
    workspace_dir: []const u8 = ".",
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    config: cfg.Config,
    config_path: []const u8,
    /// The lists a runtime key rewrites (owned copies; `config` is
    /// re-pointed at them before a save).
    hidden: std.ArrayList([]u8) = .empty,
    order: std.ArrayList([]u8) = .empty,
    scope: cfg.Scope,
    /// Bumped when the scope inputs change; the worker's cache key.
    scope_gen: u32 = 1,
    /// The pane's workspace, for links.
    workspace_dir: []const u8,
    tabs: []TabState,
    active: usize = 0,
    /// This process holds the machine's warm lock for Bitbucket
    /// (`mnml_sdk.warm.Lock`), so it is the one that fills the cache
    /// for the tabs nobody is looking at. False: another pane is
    /// already doing it, and a tab that is switched to is fetched then.
    may_warm: bool = true,
    /// `--only` was given: the strip shows only when it still has two.
    only: ?cfg.Family,
    me_account_id: []u8 = &.{},
    me_display_name: []u8 = &.{},
    theme: Theme = .{},
    cols: u16 = 80,
    rows: u16 = 24,
    now_secs: i64 = 0,
    detail_visible: bool = false,
    detail_scroll: usize = 0,
    /// How many lines the detail panel painted last frame, and how many
    /// fit — what turns a press on its scrollbar into a position.
    detail_lines: usize = 0,
    detail_rows: usize = 0,
    details: std.StringHashMapUnmanaged(*DetailEntry) = .empty,
    detail_in_flight: ?[]u8 = null,
    pr_pipelines: std.StringHashMapUnmanaged(*PrPipelines) = .empty,
    filter: std.ArrayList(u8) = .empty,
    filter_caret: usize = 0,
    /// Set by `visible`: the content rows shown, of the rows the tab
    /// has. The header paints `N of M` from them while narrowed.
    filter_shown: usize = 0,
    filter_total: usize = 0,
    mode: Mode = .list,
    menu: ?Menu = null,
    menu_items: [12]Action = undefined,
    help_scroll: usize = 0,
    /// The transient line the hint row shows on the left, owned.
    status: std.ArrayList(u8) = .empty,
    /// Where a wait long enough for a person to notice is left by the
    /// worker thread. `noteWait` turns it into the one line that keeps
    /// `loading…` from being silent.
    wait_notice: ratelimit.Notice = .{},
    effects: std.ArrayList(Effect) = .empty,
    effect_arena: std.heap.ArenaAllocator,
    jobs: std.ArrayList(fetch.Job) = .empty,
    /// The frame's scratch: visible rows, formatted text.
    frame_arena: std.heap.ArenaAllocator,
    hits: hit.HitMap,
    last_refresh_secs: i64 = 0,
    /// The `awaiting:` chip is on: the PR tabs show only what is
    /// waiting on this account's review.
    awaiting_only: bool = false,
    /// May each open pull request merge, keyed `slug#id`. Filled for
    /// the row the cursor lands on, one cached look each.
    readiness: std.StringHashMapUnmanaged(ReadinessEntry) = .empty,
    /// A readiness look already asked for, so moving the cursor back
    /// and forth over a row does not ask twice.
    readiness_in_flight: std.StringHashMapUnmanaged(void) = .empty,
    /// What every row's `[ Merge ]` says now, keyed by the pull
    /// request rather than the row.
    actions: sdk.pane.ActionStore,
    /// Turns the spinner on every button whose session is running.
    spin: usize = 0,
    /// The merge confirm, when one is up.
    merge_confirm: ?MergeConfirm = null,
    /// What the pointer is over, when it is worth saying — the reason a
    /// dim `[ Merge ]` is dim. A fixed buffer: the pointer moves many
    /// times a second and an arena would grow with every move of it.
    hover_buf: [192]u8 = undefined,
    hover_len: usize = 0,
    /// The pane has the keyboard. A session that ends while it does not
    /// is worth a notification.
    focused: bool = true,
    /// How the tab strip marks the tab that is on — the host's
    /// `ui.tab_indicator`, off `hello`.
    tab_indicator: sdk.wire.TabIndicator = .block,
    /// `ui.ascii_icons`, off `hello`. The pane's paint reads it off the
    /// `Ui` it is handed; the statusline chip this app republishes for
    /// itself has no `Ui` to read, so it reads this.
    ascii: bool = false,
    /// Sessions this pane started and wants told about, waiting to go
    /// out over the mount.
    watch_out: std.ArrayListUnmanaged(WatchRequest) = .empty,
    watch_arena: std.heap.ArenaAllocator,
    /// The last statusline values, for the chip.
    values: ?fetch.ValuesResult = null,
    /// The arena those values live on — the result's own, taken off it
    /// rather than let go at the end of `commit`. This figure is not a
    /// number: it carries the tooltip's breakdown and the hover's rows,
    /// and the pane republishes all of it every time it opens one of
    /// those rows. It has to still be there minutes after the listing
    /// landed.
    values_arena: ?std.heap.ArenaAllocator = null,
    values_at_secs: i64 = 0,
    values_requested: bool = false,
    /// Set by `commit` when a refresh landed, so a test can wait on it.
    refreshes_landed: u32 = 0,
    /// The worker's progress, read by the header while a tab loads.
    progress: ?*const fetch.Progress = null,
    /// // changed (focus-row): the pull request a `--focus <repo>#<id>`
    /// asked the cursor to land on, `repo#id` (`prRowKey`'s shape).
    /// It outlives the first paint — the flag is read before any
    /// listing exists — and is cleared the moment it lands or is
    /// answered with `not in this listing`. A forwarded focus
    /// (`focus_item` over the mount, the pane already open) goes
    /// through the same field, so there is one landing, not two.
    focus_key_buf: [256]u8 = undefined,
    focus_key_len: usize = 0,

    pub fn init(gpa: Allocator, io: Io, config: cfg.Config, config_path: []const u8, opts: Options) Allocator.Error!App {
        // `--focus acme/api#12` and `--focus api#12` name the same
        // pull request; the rows are keyed by the short one.
        const focus = shortKey(opts.focus);
        var app: App = .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .config_path = config_path,
            .scope = config.scope,
            .workspace_dir = opts.workspace_dir,
            .awaiting_only = opts.awaiting,
            .focus_key_len = @min(focus.len, 256),
            .tabs = &.{},
            .only = opts.only,
            .effect_arena = std.heap.ArenaAllocator.init(gpa),
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .hits = hit.HitMap.init(gpa),
            .actions = sdk.pane.ActionStore.init(gpa),
            .watch_arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer app.deinit();
        @memcpy(app.focus_key_buf[0..app.focus_key_len], focus[0..app.focus_key_len]);
        for (config.hidden_repos) |h| try app.hidden.append(gpa, try gpa.dupe(u8, h));
        for (config.repo_order) |o| try app.order.append(gpa, try gpa.dupe(u8, o));
        app.syncConfigLists();

        var list: std.ArrayList(TabState) = .empty;
        errdefer {
            for (list.items) |*ts| ts.deinit(gpa);
            list.deinit(gpa);
        }
        for (config.tabs) |tab| {
            if (opts.only) |fam| if (tab.kind.family() != fam) continue;
            if (opts.mine and tab.mode != .mine) continue;
            try list.append(gpa, newTab(gpa, tabs.TabSpec.resolve(config, tab)));
        }
        if (opts.mine and list.items.len == 0) {
            // The reference synthesises a mine-only tree so the chip's
            // click lands on "my" PRs whatever the config has.
            try list.append(gpa, newTab(gpa, .{ .kind = .workspace_open_prs, .name = "Mine", .workspace = config.workspace, .mine_only = true }));
        }
        app.tabs = try list.toOwnedSlice(gpa);
        return app;
    }

    fn newTab(gpa: Allocator, spec: tabs.TabSpec) TabState {
        return .{ .spec = spec, .data = tabs.TabData.emptyFor(spec.kind), .expanded = tabs.Expanded.init(gpa) };
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        for (app.tabs) |*ts| ts.deinit(gpa);
        gpa.free(app.tabs);
        for (app.hidden.items) |h| gpa.free(h);
        app.hidden.deinit(gpa);
        for (app.order.items) |o| gpa.free(o);
        app.order.deinit(gpa);
        gpa.free(app.me_account_id);
        gpa.free(app.me_display_name);
        var dit = app.details.iterator();
        while (dit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            gpa.destroy(e.value_ptr.*);
        }
        app.details.deinit(gpa);
        if (app.detail_in_flight) |k| gpa.free(k);
        var pit = app.pr_pipelines.iterator();
        while (pit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            gpa.destroy(e.value_ptr.*);
        }
        app.pr_pipelines.deinit(gpa);
        var rit = app.readiness.iterator();
        while (rit.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.updated_on);
        }
        app.readiness.deinit(gpa);
        var fit = app.readiness_in_flight.keyIterator();
        while (fit.next()) |k| gpa.free(k.*);
        app.readiness_in_flight.deinit(gpa);
        if (app.merge_confirm) |*c| c.deinit();
        app.actions.deinit();
        app.watch_out.deinit(gpa);
        app.watch_arena.deinit();
        if (app.values_arena) |*a| a.deinit();
        app.filter.deinit(gpa);
        app.status.deinit(gpa);
        app.effects.deinit(gpa);
        app.effect_arena.deinit();
        for (app.jobs.items) |*j| j.deinit();
        app.jobs.deinit(gpa);
        app.frame_arena.deinit();
        app.hits.deinit();
        app.* = undefined;
    }

    /// `config.hidden_repos` / `repo_order` follow the owned lists.
    fn syncConfigLists(app: *App) void {
        app.config.hidden_repos = @ptrCast(app.hidden.items);
        app.config.repo_order = @ptrCast(app.order.items);
        app.config.scope = app.scope;
    }

    // ─── what the loop asks ──────────────────────────────────────────

    pub fn progressDone(app: *const App) u32 {
        return if (app.progress) |p| p.done.load(.acquire) else 0;
    }

    pub fn progressTotal(app: *const App) u32 {
        return if (app.progress) |p| p.total.load(.acquire) else 0;
    }

    pub fn activeTab(app: *App) *TabState {
        return &app.tabs[app.active];
    }

    /// The strip shows when there is more than one tab.
    pub fn showTabStrip(app: *const App) bool {
        return app.tabs.len > 1;
    }

    pub fn family(app: *const App) cfg.Family {
        return app.tabs[app.active].spec.kind.family();
    }

    /// Queue the startup chain: the account, then every tab (the
    /// reference prefetches all of them), then the statusline values.
    pub fn startup(app: *App) Allocator.Error!void {
        if (app.config.account_id.len == 0) try app.enqueue(.whoami);
        // The tab that is on screen is what somebody is waiting for.
        // Every other tab used to be fetched before the first paint
        // too — three tabs of pull requests, of which two nobody had
        // asked to see — so the pane opened at the cost of all of
        // them. The rest are warmed behind the paint, paced, and at a
        // priority that steps aside for anything a reader does.
        for (app.tabs, 0..) |*ts, i| {
            const mine = i == app.active;
            if (!mine and !app.may_warm) continue;
            ts.loading = true;
            try app.enqueueFor(
                .{ .refresh = .{ .tab = i, .spec = ts.spec, .scope = app.scopeInputs(ts.spec.workspace) } },
                if (mine) .pane_open else .warm,
            );
        }
        try app.requestValues();
        app.last_refresh_secs = app.now_secs;
    }

    fn scopeInputs(app: *App, workspace: []const u8) fetch.ScopeInputs {
        app.syncConfigLists();
        return fetch.scopeOf(app.config, workspace, app.scope_gen);
    }

    fn enqueue(app: *App, kind: fetch.Job.Kind) Allocator.Error!void {
        try app.jobs.append(app.gpa, try fetch.makeJob(app.gpa, app.now_secs, kind));
    }

    /// The same, saying what the request log should call it.
    fn enqueueFor(app: *App, kind: fetch.Job.Kind, reason: api.Reason) Allocator.Error!void {
        try app.jobs.append(app.gpa, try fetch.makeJobFor(app.gpa, app.now_secs, kind, reason));
    }

    /// The same, saying whether the caches may answer.
    fn enqueueFull(app: *App, kind: fetch.Job.Kind, full: bool) Allocator.Error!void {
        var job = try fetch.makeJob(app.gpa, app.now_secs, kind);
        job.full = full;
        try app.jobs.append(app.gpa, job);
    }

    /// The jobs queued since the last take; the caller owns them.
    pub fn takeJobs(app: *App) []fetch.Job {
        const out = app.jobs.toOwnedSlice(app.gpa) catch return &.{};
        return out;
    }

    /// The effects queued since the last take; valid until the next
    /// event.
    pub fn takeEffects(app: *App) []const Effect {
        const out = app.effects.toOwnedSlice(app.gpa) catch return &.{};
        return out;
    }

    pub fn freeEffects(app: *App, taken: []const Effect) void {
        app.gpa.free(taken);
        _ = app.effect_arena.reset(.retain_capacity);
    }

    fn effect(app: *App, e: Effect) void {
        app.effects.append(app.gpa, e) catch {};
    }

    fn toast(app: *App, level: ToastLevel, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(app.effect_arena.allocator(), fmt, args) catch return;
        app.effect(.{ .toast = .{ .level = level, .text = text } });
    }

    /// A toast with something to do about it. The strings must outlive
    /// the frame the toast is posted on, so they come off the effect
    /// arena like the text.
    fn toastWithAction(app: *App, level: ToastLevel, action: sdk.wire.ToastAction, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(app.effect_arena.allocator(), fmt, args) catch return;
        app.effect(.{ .toast = .{ .level = level, .text = text, .action = action } });
    }

    /// The offer a failed fetch owes the reader: the list on screen is
    /// stale and nothing on it says so, so the message carries the way
    /// back rather than expecting them to know that `r` is refresh.
    pub const retry_action: sdk.wire.ToastAction = .{ .label = "Retry", .command = "integrations.retry_refresh" };

    /// The reference's status line: kept on the hint row's left and
    /// shown as a toast.
    /// Say something about a wait the reader has been sitting through.
    /// Called once per loop pass, so the line appears WHILE the fetch
    /// is still out; the fetch's own summary replaces it when the rows
    /// arrive.
    pub fn noteWait(app: *App) void {
        const w = app.wait_notice.take() orelse return;
        var buf: [96]u8 = undefined;
        app.setStatus("{s}", .{w.text(&buf)});
    }

    pub fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.status.clearRetainingCapacity();
        const text = std.fmt.allocPrint(app.gpa, fmt, args) catch return;
        defer app.gpa.free(text);
        app.status.appendSlice(app.gpa, text) catch {};
    }

    fn say(app: *App, level: ToastLevel, comptime fmt: []const u8, args: anytype) void {
        app.setStatus(fmt, args);
        app.toast(level, fmt, args);
    }

    /// Every second from the loop: the auto-refresh and the values
    /// cadence, and the spinner on a merge that is running.
    ///
    /// Readiness is deliberately NOT asked for here. Rebuilding the
    /// rows every second to find the one under the cursor is work the
    /// pane does not need to repeat: the cursor only moves when
    /// something moves it, so `select` asks then.
    pub fn tick(app: *App, now_secs: i64) Allocator.Error!void {
        app.now_secs = now_secs;
        if (app.actions.anyRunning()) app.spin +%= 1;
        const every: i64 = app.config.refresh_interval_secs;
        if (every > 0 and now_secs - app.last_refresh_secs >= every and !app.activeTab().loading) {
            try app.refreshActive();
        }
        if (app.values != null and now_secs - app.values_at_secs >= values_every_secs and !app.values_requested) try app.requestValues();
    }

    /// The reference polls the chip every five minutes.
    pub const values_every_secs: i64 = 300;

    /// Ask the worker for the chip's figure again. Public because the
    /// chip's own tests republish it, which is the read that proves the
    /// figure still owns what it lists.
    pub fn requestValues(app: *App) Allocator.Error!void {
        app.values_requested = true;
        try app.enqueue(.{ .values = .{
            .scope = app.scopeInputs(app.config.workspace),
            .stale_after_days = app.config.chip_stale_after_days,
            .excluded_branch_patterns = app.config.chip_excluded_branch_patterns,
        } });
    }

    // ─── the rows ────────────────────────────────────────────────────

    /// The active tab's rows, filtered by the `/` query. On the frame
    /// arena; call once per event. Also records what the header's
    /// `N of M` reads: the content rows kept, of the content rows the
    /// tab would show unfiltered (a repo header and the `Show more (N)`
    /// footer are chrome and count as neither).
    pub fn visible(app: *App, a: Allocator) Allocator.Error!tabs.View {
        const ts = app.activeTab();
        const all = try tabs.visibleRows(a, .{
            .spec = ts.spec,
            .data = ts.data,
            .expanded = &ts.expanded,
            .show_all = ts.show_all,
            .now_secs = app.now_secs,
            .builds = try app.buildsFor(a, ts),
            .awaiting_only = app.awaiting_only,
            .me = app.meId(),
        });
        app.filter_total = countContent(all.rows);
        if (app.filter.items.len == 0) {
            app.filter_shown = app.filter_total;
            return all;
        }
        var kept: std.ArrayList(tabs.VisibleRow) = .empty;
        var cells: usize = 0;
        for (all.rows) |r| {
            if (r == .repo_header or r == .show_more or app.rowMatches(r)) {
                try kept.append(a, r);
                cells += r.height();
            }
        }
        const out: tabs.View = .{ .rows = try kept.toOwnedSlice(a), .cells = cells };
        app.filter_shown = countContent(out.rows);
        return out;
    }

    /// What has been fetched for each expanded pull request, so the
    /// rows know how many build lines to lay out. Only the expanded
    /// ones, which is at most a handful.
    fn buildsFor(app: *App, a: Allocator, ts: *const TabState) Allocator.Error![]const tabs.BuildsOf {
        const repos = switch (ts.data) {
            .repo_pr_tree => |r| r,
            else => return &.{},
        };
        var out: std.ArrayList(tabs.BuildsOf) = .empty;
        for (repos) |r| {
            if (!ts.expanded.hasRepo(r.slug)) continue;
            for (r.prs) |pr| {
                if (!ts.expanded.hasPr(r.slug, pr.id)) continue;
                const e = app.prPipelinesOf(r.slug, pr.id) orelse continue;
                try out.append(a, .{ .slug = r.slug, .id = pr.id, .runs = e.pipelines.len, .failed = e.error_text.len > 0 });
            }
        }
        return out.toOwnedSlice(a);
    }

    fn countContent(rows: []const tabs.VisibleRow) usize {
        var n: usize = 0;
        for (rows) |r| if (r != .repo_header and r != .show_more) {
            n += 1;
        };
        return n;
    }

    /// True while the `/` query is hiding something — what the header's
    /// `N of M` and the hint row's context both key off.
    pub fn narrowed(app: *const App) bool {
        return app.filter.items.len > 0;
    }

    fn rowMatches(app: *App, r: tabs.VisibleRow) bool {
        const q = app.filter.items;
        const ts = app.activeTab();
        var buf: [512]u8 = undefined;
        const text = rowSearchText(ts, r, &buf);
        return std.ascii.indexOfIgnoreCase(text, q) != null;
    }

    /// The words a filter can match on a row.
    pub fn rowSearchText(ts: *const TabState, r: tabs.VisibleRow, buf: []u8) []const u8 {
        return switch (r) {
            .repo_header => |h| switch (ts.data) {
                .repo_pr_tree => |repos| repos[h.repo].slug,
                .repo_tree => |repos| repos[h.repo].slug,
                else => "",
            },
            .pr => |p| blk: {
                const pr = ts.data.repo_pr_tree[p.repo].prs[p.idx];
                break :blk std.fmt.bufPrint(buf, "#{d} {s} {s} {s} {s}", .{ pr.id, pr.title, pr.author, pr.source_branch, pr.state }) catch pr.title;
            },
            // A build line filters on the same words it paints, so a
            // `/FAILED` finds the runs as well as the rows.
            .build => |b| blk: {
                const pr = ts.data.repo_pr_tree[b.repo].prs[b.idx];
                break :blk std.fmt.bufPrint(buf, "#{d} {s} build {d}", .{ pr.id, pr.title, b.run }) catch pr.title;
            },
            .build_note => |b| ts.data.repo_pr_tree[b.repo].prs[b.idx].title,
            .branch => |b| ts.data.repo_tree[b.repo].branches[b.idx].name,
            .show_more => "",
            .flat => |i| switch (ts.data) {
                .pull_requests => |list| std.fmt.bufPrint(buf, "#{d} {s} {s} {s} {s} {s}", .{ list[i].id, list[i].title, list[i].author, list[i].source_branch, list[i].state, list[i].repo_full }) catch list[i].title,
                .pipelines => |list| std.fmt.bufPrint(buf, "#{d} {s} {s} {s}", .{ list[i].build_number, list[i].stateLabel(), list[i].ref_name, list[i].trigger }) catch list[i].ref_name,
                .branches => |list| std.fmt.bufPrint(buf, "{s} {s} {s}", .{ list[i].name, list[i].authorLabel(), list[i].summaryLine() }) catch list[i].name,
                else => "",
            },
        };
    }

    /// The pull request under the cursor, with its repo slug.
    pub fn focusedPr(app: *App, rows: []const tabs.VisibleRow) ?struct { slug: []const u8, pr: model.PullRequest } {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return null;
        return switch (rows[ts.selected]) {
            // A build line belongs to the pull request it hangs under,
            // so the detail and the readiness follow the cursor onto it
            // rather than going blank.
            .pr, .build, .build_note => blk: {
                const ref = tabs.prOf(rows[ts.selected]).?;
                const repos = switch (ts.data) {
                    .repo_pr_tree => |r| r,
                    else => break :blk null,
                };
                if (ref.repo >= repos.len or ref.idx >= repos[ref.repo].prs.len) break :blk null;
                break :blk .{ .slug = repos[ref.repo].slug, .pr = repos[ref.repo].prs[ref.idx] };
            },
            .flat => |i| switch (ts.data) {
                .pull_requests => |list| .{ .slug = list[i].repoSlug(), .pr = list[i] },
                else => null,
            },
            else => null,
        };
    }

    pub fn focusedKey(app: *App, rows: []const tabs.VisibleRow) ?fetch.PrKey {
        const f = app.focusedPr(rows) orelse return null;
        const ws = if (f.pr.workspaceSlug().len > 0) f.pr.workspaceSlug() else app.activeTab().spec.workspace;
        return .{ .workspace = ws, .repo = if (f.pr.repoSlug().len > 0) f.pr.repoSlug() else f.slug, .id = f.pr.id };
    }

    pub fn keyText(buf: []u8, k: fetch.PrKey) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}#{d}", .{ k.workspace, k.repo, k.id }) catch buf[0..0];
    }

    /// The detail cached for the focused PR, if any.
    pub fn focusedDetail(app: *App, rows: []const tabs.VisibleRow) ?*DetailEntry {
        const k = app.focusedKey(rows) orelse return null;
        var buf: [256]u8 = undefined;
        return app.details.get(keyText(&buf, k));
    }

    pub fn detailInFlight(app: *App, rows: []const tabs.VisibleRow) bool {
        const k = app.focusedKey(rows) orelse return false;
        var buf: [256]u8 = undefined;
        const key = keyText(&buf, k);
        return if (app.detail_in_flight) |f| std.mem.eql(u8, f, key) else false;
    }

    /// The pipelines fetched for a merged PR, if any.
    pub fn prPipelinesOf(app: *App, slug: []const u8, id: i64) ?*PrPipelines {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}#{d}", .{ slug, id }) catch return null;
        return app.pr_pipelines.get(key);
    }

    /// What the focused row would open on the web.
    pub fn focusedUrl(app: *App, a: Allocator, rows: []const tabs.VisibleRow) Allocator.Error!?[]const u8 {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return null;
        const ws = ts.spec.workspace;
        return switch (rows[ts.selected]) {
            .repo_header => |h| switch (ts.data) {
                .repo_pr_tree => |repos| try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pull-requests", .{ ws, repos[h.repo].slug }),
                .repo_tree => |repos| try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/branches", .{ ws, repos[h.repo].slug }),
                else => null,
            },
            .pr => |p| blk: {
                const pr = ts.data.repo_pr_tree[p.repo].prs[p.idx];
                var buf: [256]u8 = undefined;
                break :blk try a.dupe(u8, pr.url(&buf, ws, ts.data.repo_pr_tree[p.repo].slug));
            },
            // A build line is a door to that run's page.
            .build => |b| blk: {
                const slug = ts.data.repo_pr_tree[b.repo].slug;
                const pr = ts.data.repo_pr_tree[b.repo].prs[b.idx];
                const runs = app.prPipelinesOf(slug, pr.id) orelse break :blk null;
                if (b.run >= runs.pipelines.len) break :blk null;
                // The toolkit's spelling, so a build line in this pane
                // and one in the tracker pane open the same page from
                // the same function.
                var buf: [256]u8 = undefined;
                break :blk try a.dupe(u8, sdk.pane.build.pageUrl(&buf, ws, slug, runs.pipelines[b.run].build_number));
            },
            // The note where a build line would be opens the pull
            // request's own pipelines page — the place to go and see why.
            .build_note => |b| try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pipelines", .{ ws, ts.data.repo_pr_tree[b.repo].slug }),
            .branch => |b| try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/branch/{s}", .{ ws, ts.data.repo_tree[b.repo].slug, ts.data.repo_tree[b.repo].branches[b.idx].name }),
            .show_more => null,
            .flat => |i| switch (ts.data) {
                .pull_requests => |list| blk: {
                    var buf: [256]u8 = undefined;
                    break :blk try a.dupe(u8, list[i].url(&buf, ws, list[i].repoSlug()));
                },
                .pipelines => |list| blk: {
                    var buf: [256]u8 = undefined;
                    break :blk try a.dupe(u8, sdk.pane.build.pageUrl(&buf, ws, ts.spec.repo, list[i].build_number));
                },
                .branches => |list| try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/branch/{s}", .{ ws, ts.spec.repo, list[i].name }),
                else => null,
            },
        };
    }

    /// The bindings' context for the focused row.
    pub fn keyContext(app: *App, rows: []const tabs.VisibleRow) keymap.Context {
        const ts = app.activeTab();
        const on_row = ts.selected < rows.len and rows[ts.selected] != .show_more;
        return .{ .on_tree = ts.spec.isTree(), .on_row = on_row, .detail_open = app.detail_visible };
    }

    // ─── input ───────────────────────────────────────────────────────

    /// One key from mnml. False means the pane is done.
    pub fn keyPress(app: *App, spec: []const u8) Allocator.Error!bool {
        _ = app.frame_arena.reset(.retain_capacity);
        const a = app.frame_arena.allocator();
        switch (app.mode) {
            .filter => return app.filterKey(spec),
            .confirm => {
                if (std.mem.eql(u8, spec, "enter")) {
                    try app.acceptMergeConfirm();
                } else if (std.mem.eql(u8, spec, "left") or std.mem.eql(u8, spec, "h") or std.mem.eql(u8, spec, "right") or std.mem.eql(u8, spec, "l")) {
                    app.cycleMergeStrategy();
                } else {
                    app.closeMergeConfirm();
                }
                return true;
            },
            .help => {
                if (std.mem.eql(u8, spec, "j") or std.mem.eql(u8, spec, "down")) {
                    app.help_scroll += 1;
                } else if (std.mem.eql(u8, spec, "k") or std.mem.eql(u8, spec, "up")) {
                    app.help_scroll -|= 1;
                } else {
                    app.mode = .list;
                    app.help_scroll = 0;
                }
                return true;
            },
            .menu => return app.menuKey(a, spec),
            .list => {},
        }
        const view = try app.visible(a);
        const action = keymap.lookup(spec, app.keyContext(view.rows)) orelse return true;
        return app.run(a, action, view.rows);
    }

    /// Run an action on the focused row.
    pub fn run(app: *App, a: Allocator, action: Action, rows_in: []const tabs.VisibleRow) Allocator.Error!bool {
        var rows = rows_in;
        const ts = app.activeTab();
        const before = app.focusedKey(rows);
        switch (action) {
            .quit => {
                app.effect(.quit);
                return false;
            },
            .refresh => try app.refreshActive(),
            .refresh_full => try app.refreshActiveMode(true),
            .up => app.move(rows, -1),
            .down => app.move(rows, 1),
            .page_up => app.move(rows, -10),
            .page_down => app.move(rows, 10),
            .home => app.move(rows, -@as(isize, @intCast(rows.len)) - 1),
            .end => app.move(rows, @as(isize, @intCast(rows.len)) + 1),
            .activate => try app.activate(a, rows),
            .expand => try app.expand(a, rows),
            .collapse => try app.collapse(a, rows),
            .expand_all => {
                switch (ts.data) {
                    .repo_pr_tree => |repos| for (repos) |r| try ts.expanded.setRepo(r.slug, true),
                    .repo_tree => |repos| for (repos) |r| try ts.expanded.setRepo(r.slug, true),
                    else => {},
                }
            },
            .collapse_all => {
                ts.expanded.clearRepos();
                ts.selected = 0;
            },
            .hide_repo => try app.hideFocused(rows),
            .unhide_all => try app.unhideAll(),
            .cycle_scope => try app.cycleScope(),
            .reorder_up => try app.reorder(rows, -1),
            .reorder_down => try app.reorder(rows, 1),
            .open_web => {
                if (try app.focusedUrl(app.effect_arena.allocator(), rows)) |url| {
                    app.effect(.{ .open_url = url });
                    app.say(.info, "opened {s}", .{url});
                } else app.say(.warn, "no URL for this row", .{});
            },
            .yank_url => {
                if (try app.focusedUrl(app.effect_arena.allocator(), rows)) |url| {
                    app.effect(.{ .copy = url });
                    app.say(.info, "copied {s}", .{url});
                } else app.say(.warn, "no URL for this row", .{});
            },
            .next_tab, .toggle_merged => try app.switchTab((app.active + 1) % app.tabs.len),
            .prev_tab => try app.switchTab(if (app.active == 0) app.tabs.len - 1 else app.active - 1),
            .tab_1, .tab_2, .tab_3, .tab_4, .tab_5, .tab_6, .tab_7, .tab_8, .tab_9 => {
                const n = action.tabNumber().?;
                if (n < app.tabs.len) try app.switchTab(n);
            },
            .toggle_detail => {
                app.detail_visible = !app.detail_visible;
                app.detail_scroll = 0;
                if (app.detail_visible) try app.ensureDetail(rows);
            },
            .detail_up => app.detail_scroll -|= 4,
            .detail_down => app.detail_scroll += 4,
            .toggle_approval => try app.toggleApproval(rows),
            .toggle_awaiting => try app.toggleAwaiting(),
            .merge_pr => if (app.focusedPr(rows)) |f| try app.pressMerge(f.slug, f.pr),
            .filter => {
                app.mode = .filter;
                app.filter_caret = app.filter.items.len;
            },
            .help => app.mode = .help,
            .escape => {
                if (app.filter.items.len > 0) {
                    app.filter.clearRetainingCapacity();
                    app.filter_caret = 0;
                    ts.selected = 0;
                } else if (app.detail_visible) {
                    app.detail_visible = false;
                }
            },
        }
        // The cursor moved with the detail open: fetch the new PR's.
        if (app.detail_visible) {
            rows = (try app.visible(a)).rows;
            const after = app.focusedKey(rows);
            if (!sameKey(before, after)) {
                app.detail_scroll = 0;
                try app.ensureDetail(rows);
            }
        }
        return true;
    }

    fn sameKey(x: ?fetch.PrKey, y: ?fetch.PrKey) bool {
        if (x == null or y == null) return x == null and y == null;
        return x.?.id == y.?.id and std.mem.eql(u8, x.?.repo, y.?.repo) and std.mem.eql(u8, x.?.workspace, y.?.workspace);
    }

    fn move(app: *App, rows: []const tabs.VisibleRow, delta: isize) void {
        const ts = app.activeTab();
        if (rows.len == 0) {
            ts.selected = 0;
            return;
        }
        const cur: isize = @intCast(@min(ts.selected, rows.len - 1));
        const next = std.math.clamp(cur + delta, 0, @as(isize, @intCast(rows.len)) - 1);
        ts.selected = @intCast(next);
        // The row it landed on gets its one readiness look.
        app.onCursorRow(rows) catch {};
    }

    pub fn select(app: *App, rows: []const tabs.VisibleRow, idx: usize) void {
        if (rows.len == 0) return;
        app.activeTab().selected = @min(idx, rows.len - 1);
        // The row it landed on gets its one readiness look, so the
        // `[ Merge ]` under the cursor can say what it knows.
        app.onCursorRow(rows) catch {};
    }

    /// Enter / space: a repo header toggles, a pull request folds out
    /// to its builds, a build line opens that run's page, the footer
    /// lifts the fold, a flat row opens.
    fn activate(app: *App, a: Allocator, rows: []const tabs.VisibleRow) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return;
        switch (rows[ts.selected]) {
            .repo_header => |h| try ts.expanded.toggleRepo(slugOf(ts, h.repo)),
            .pr => |p| try app.togglePrBuilds(ts.data.repo_pr_tree[p.repo].slug, ts.data.repo_pr_tree[p.repo].prs[p.idx]),
            .branch => {},
            .show_more => ts.show_all = true,
            .build, .build_note, .flat => {
                if (try app.focusedUrl(app.effect_arena.allocator(), rows)) |url| {
                    app.effect(.{ .open_url = url });
                    app.say(.info, "opened {s}", .{url});
                }
            },
        }
        _ = a;
    }

    fn slugOf(ts: *const TabState, repo: usize) []const u8 {
        return switch (ts.data) {
            .repo_pr_tree => |repos| repos[repo].slug,
            .repo_tree => |repos| repos[repo].slug,
            else => "",
        };
    }

    /// Right / l: open the repo, or step into its first child; open a
    /// merged PR's pipeline line.
    fn expand(app: *App, a: Allocator, rows: []const tabs.VisibleRow) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return;
        switch (rows[ts.selected]) {
            .repo_header => |h| {
                const slug = slugOf(ts, h.repo);
                if (!ts.expanded.hasRepo(slug)) {
                    try ts.expanded.setRepo(slug, true);
                } else {
                    const after = try app.visible(a);
                    if (ts.selected + 1 < after.rows.len and after.rows[ts.selected + 1] != .repo_header) ts.selected += 1;
                }
            },
            .pr => |p| {
                const pr = ts.data.repo_pr_tree[p.repo].prs[p.idx];
                if (pr.buildCommit().len > 0 and !p.open) try app.togglePrBuilds(ts.data.repo_pr_tree[p.repo].slug, pr);
            },
            else => {},
        }
    }

    /// Left / h: close the repo, or step up to it; fold a pull
    /// request's builds back in, or step up from one of them.
    fn collapse(app: *App, a: Allocator, rows: []const tabs.VisibleRow) Allocator.Error!void {
        _ = a;
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return;
        switch (rows[ts.selected]) {
            .repo_header => |h| try ts.expanded.setRepo(slugOf(ts, h.repo), false),
            .pr => |p| {
                if (p.open) {
                    try ts.expanded.setPr(ts.data.repo_pr_tree[p.repo].slug, ts.data.repo_pr_tree[p.repo].prs[p.idx].id, false);
                } else if (tabs.headerRowOf(rows, p.repo)) |hr| {
                    try ts.expanded.setRepo(ts.data.repo_pr_tree[p.repo].slug, false);
                    ts.selected = hr;
                }
            },
            // From a build line, `h` folds the pull request it hangs
            // under and puts the cursor back on it.
            .build, .build_note => {
                const pr_ref = tabs.prOf(rows[ts.selected]).?;
                try ts.expanded.setPr(ts.data.repo_pr_tree[pr_ref.repo].slug, ts.data.repo_pr_tree[pr_ref.repo].prs[pr_ref.idx].id, false);
                var i = ts.selected;
                while (i > 0) : (i -= 1) if (rows[i - 1] == .pr) {
                    ts.selected = i - 1;
                    break;
                };
            },
            .branch => |b| if (tabs.headerRowOf(rows, b.repo)) |hr| {
                try ts.expanded.setRepo(ts.data.repo_tree[b.repo].slug, false);
                ts.selected = hr;
            },
            else => {},
        }
    }

    // ─── may it merge? ───────────────────────────────────────────────

    /// The pointer moved. Nothing here changes state; it only leaves
    /// the sentence a dim `[ Merge ]` owes the reader on the hint row,
    /// for one pass.
    pub fn hoverNote(app: *const App) []const u8 {
        return app.hover_buf[0..app.hover_len];
    }

    pub fn hover(app: *App, col: u16, row: u16) void {
        app.hover_len = 0;
        const target = app.hits.at(col, row) orelse return;
        // A button showing only its glyph is the one place the action
        // is not named on screen, so the pointer names it. One cell
        // wide IS the icon form — the rect the paint registered says
        // so, and nothing has to be remembered between frames.
        if (target == .pr_button) {
            const r = app.hits.rectOf(target) orelse return;
            if (r.w != 1) return;
            const word = switch (target.pr_button.which) {
                .open => "Open",
                .merge => sdk.pane.merge.label,
            };
            var wbuf: [96]u8 = undefined;
            const st = app.buttonStateOf(target.pr_button.row, target.pr_button.which);
            app.setHover(sdk.pane.action.hoverText(&wbuf, .icon, st, word));
            return;
        }
        const idx = switch (target) {
            .merge_blocked => |i| i,
            else => return,
        };
        var scratch = std.heap.ArenaAllocator.init(app.gpa);
        defer scratch.deinit();
        const v = app.visible(scratch.allocator()) catch return;
        if (idx >= v.rows.len) return;
        const ref = tabs.prOf(v.rows[idx]) orelse return;
        const repos = switch (app.activeTab().data) {
            .repo_pr_tree => |r| r,
            else => return,
        };
        if (ref.repo >= repos.len or ref.idx >= repos[ref.repo].prs.len) return;
        const pr = repos[ref.repo].prs[ref.idx];
        const r = app.readinessOf(repos[ref.repo].slug, pr);
        var buf: [192]u8 = undefined;
        const note = r.hoverText(&buf);
        app.setHover(note);
    }

    fn setHover(app: *App, note: []const u8) void {
        const n = @min(note.len, app.hover_buf.len);
        @memcpy(app.hover_buf[0..n], note[0..n]);
        app.hover_len = n;
    }

    /// What the button on `row` for `which` is wearing — the state its
    /// last press left, so a one-cell button's hover says `running`
    /// rather than offering a word it is no longer offering.
    fn buttonStateOf(app: *App, row: usize, which: hit.PrButton) sdk.pane.action.State {
        if (which != .merge) return .idle;
        var scratch = std.heap.ArenaAllocator.init(app.gpa);
        defer scratch.deinit();
        const v = app.visible(scratch.allocator()) catch return .idle;
        if (row >= v.rows.len) return .idle;
        const ref = tabs.prOf(v.rows[row]) orelse return .idle;
        const repos = switch (app.activeTab().data) {
            .repo_pr_tree => |r| r,
            else => return .idle,
        };
        if (ref.repo >= repos.len or ref.idx >= repos[ref.repo].prs.len) return .idle;
        var kbuf: [256]u8 = undefined;
        return app.actions.state(App.prRowKey(&kbuf, repos[ref.repo].slug, repos[ref.repo].prs[ref.idx].id), "merge");
    }

    /// The strategies this workspace allows, as the toolkit spells
    /// them. Both enums carry the same three words on purpose, so the
    /// config reads like the API the strategy ends up in.
    pub fn mergeStrategies(app: *App, a: Allocator) Allocator.Error![]const sdk.pane.merge.Strategy {
        const src = app.config.merge_strategies;
        if (src.len == 0) return &.{.merge_commit};
        const out = try a.alloc(sdk.pane.merge.Strategy, src.len);
        for (src, out) |c, *o| o.* = switch (c) {
            .merge_commit => .merge_commit,
            .squash => .squash,
            .fast_forward => .fast_forward,
        };
        return out;
    }

    /// The key both the readiness cache and the `[ Merge ]` button are
    /// filed under: the pull request, never the row.
    pub fn prRowKey(buf: []u8, slug: []const u8, id: i64) []const u8 {
        return std.fmt.bufPrint(buf, "{s}#{d}", .{ slug, id }) catch buf[0..0];
    }

    /// What is known about this pull request's readiness. A pull
    /// request that has moved since the look is unchecked again, which
    /// is the whole point of keying it by `updated_on`.
    pub fn readinessOf(app: *App, slug: []const u8, pr: model.PullRequest) sdk.pane.merge.Readiness {
        var buf: [256]u8 = undefined;
        const key = prRowKey(&buf, slug, pr.id);
        const e = app.readiness.get(key) orelse return .{};
        if (!std.mem.eql(u8, e.updated_on, pr.updated_on)) return .{};
        return e.readiness;
    }

    /// File one readiness look, freeing whatever it replaces. The
    /// commit path and the tests go through here so neither can leak
    /// the key it overwrote.
    pub fn putReadiness(app: *App, key: []const u8, updated_on: []const u8, r: sdk.pane.merge.Readiness) Allocator.Error!void {
        const owned_key = try app.gpa.dupe(u8, key);
        errdefer app.gpa.free(owned_key);
        const owned_stamp = try app.gpa.dupe(u8, updated_on);
        const gop = try app.readiness.getOrPut(app.gpa, owned_key);
        if (gop.found_existing) {
            app.gpa.free(owned_key);
            app.gpa.free(gop.value_ptr.updated_on);
        }
        gop.value_ptr.* = .{ .updated_on = owned_stamp, .readiness = r };
    }

    /// Ask, once, whether this pull request may merge. Only for OPEN
    /// ones, only for the row the reader is actually on, and never
    /// again while it has not moved — so a tab of twenty pull requests
    /// does not fire twenty looks at the bucket on arrival.
    pub fn ensureReadiness(app: *App, slug: []const u8, pr: model.PullRequest) Allocator.Error!void {
        if (!pr.isOpen()) return;
        var buf: [256]u8 = undefined;
        const key = prRowKey(&buf, slug, pr.id);
        if (app.readiness.get(key)) |e| if (std.mem.eql(u8, e.updated_on, pr.updated_on)) return;
        if (app.readiness_in_flight.contains(key)) return;
        const owned = try app.gpa.dupe(u8, key);
        errdefer app.gpa.free(owned);
        try app.readiness_in_flight.put(app.gpa, owned, {});
        // The runs on the source commit, when the row's builds are
        // already open and fresh: the look then never asks for the
        // pipelines list a second time.
        var known: ?bool = null;
        if (app.prPipelinesOf(slug, pr.id)) |runs| {
            if (std.mem.eql(u8, runs.updated_on, pr.updated_on) and runs.error_text.len == 0) {
                known = runs.pipelines.len > 0 and std.ascii.eqlIgnoreCase(runs.pipelines[0].stateLabel(), "SUCCESSFUL");
            }
        }
        const ts = app.activeTab();
        try app.enqueue(.{ .readiness = .{
            .tab = app.active,
            .key = .{ .workspace = ts.spec.workspace, .repo = slug, .id = pr.id },
            .updated_on = pr.updated_on,
            .source_commit = pr.buildCommit(),
            .required = @max(app.config.required_approvals, 1),
            .known_build = known,
        } });
    }

    /// After the cursor moves: the row it landed on gets its one look.
    pub fn onCursorRow(app: *App, rows: []const tabs.VisibleRow) Allocator.Error!void {
        const f = app.focusedPr(rows) orelse return;
        try app.ensureReadiness(f.slug, f.pr);
    }

    /// A press on a row's `[ Merge ]`. A dim button is not a hit, so
    /// reaching here at all means it is ready — except by the keyboard,
    /// which says why instead.
    pub fn pressMerge(app: *App, slug: []const u8, pr: model.PullRequest) Allocator.Error!void {
        var kbuf: [256]u8 = undefined;
        const row_key = prRowKey(&kbuf, slug, pr.id);
        // A button that already started a session opens it rather than
        // starting a second one.
        switch (sdk.pane.action.pressOf(app.actions.state(row_key, "merge"))) {
            .focus_session => return app.focusMergeSession(row_key),
            .dispatch, .retry => {},
        }
        const r = app.readinessOf(slug, pr);
        if (!r.ready()) {
            var rbuf: [192]u8 = undefined;
            app.say(.warn, "{s}", .{r.hoverText(&rbuf)});
            try app.ensureReadiness(slug, pr);
            return;
        }
        try app.openMergeConfirm(slug, pr);
    }

    /// The named confirm: the title, `source → target`, the strategy.
    fn openMergeConfirm(app: *App, slug: []const u8, pr: model.PullRequest) Allocator.Error!void {
        if (app.merge_confirm) |*c| c.deinit();
        // The arena goes into the struct FIRST, and everything is
        // allocated through the handle taken from it THERE: an
        // `ArenaAllocator`'s `allocator()` binds to the address it was
        // taken from, so a local one copied into a field leaks every
        // allocation made before the copy.
        app.merge_confirm = .{
            .arena = std.heap.ArenaAllocator.init(app.gpa),
            .row_key = "",
            .confirm = .{ .title = "", .source = "", .target = "", .strategy = .merge_commit, .url = "" },
            .allowed = &.{},
        };
        const c = &app.merge_confirm.?;
        const a = c.arena.allocator();
        var ubuf: [256]u8 = undefined;
        var kbuf: [256]u8 = undefined;
        c.allowed = try app.mergeStrategies(a);
        c.row_key = try a.dupe(u8, prRowKey(&kbuf, slug, pr.id));
        c.confirm = .{
            .title = try a.dupe(u8, pr.title),
            .source = try a.dupe(u8, pr.source_branch),
            .target = try a.dupe(u8, pr.dest_branch),
            .strategy = if (c.allowed.len > 0) c.allowed[0] else .merge_commit,
            .url = try a.dupe(u8, pr.url(&ubuf, app.activeTab().spec.workspace, slug)),
        };
        app.mode = .confirm;
    }

    pub fn closeMergeConfirm(app: *App) void {
        if (app.merge_confirm) |*c| c.deinit();
        app.merge_confirm = null;
        app.mode = .list;
    }

    /// Confirmed: dispatch the Claude Code session that does the merge,
    /// and start watching it. No pane ever calls the merge API itself —
    /// the one destructive action goes through the thing the user
    /// already supervises.
    pub fn acceptMergeConfirm(app: *App) Allocator.Error!void {
        const c = app.merge_confirm orelse return;
        const a = app.effect_arena.allocator();
        const prompt = try sdk.pane.merge.prompt(a, c.confirm);
        const first = prompt[0 .. std.mem.indexOfScalar(u8, prompt, '\n') orelse prompt.len];
        const row_key = try a.dupe(u8, c.row_key);
        app.effect(.{ .dispatch = .{ .prompt = prompt, .row_key = row_key, .action = "merge" } });
        try app.actions.set(row_key, "merge", .{ .state = .running, .prompt_line = first });
        var wbuf: [320]u8 = undefined;
        const wkey = sdk.pane.actionWatchKey(&wbuf, row_key, "merge");
        const wa = app.watch_arena.allocator();
        try app.watch_out.append(app.gpa, .{
            .key = try wa.dupe(u8, wkey),
            .cwd = try wa.dupe(u8, app.workspace_dir),
            .prompt_line = try wa.dupe(u8, first),
        });
        app.say(.info, "merging {s} through Claude Code ({s})", .{ sdk.pane.merge.shortUrlTail(c.confirm.url), c.confirm.strategy.title() });
        app.closeMergeConfirm();
    }

    /// The strategy the confirm offers, cycled through what the repo
    /// allows.
    pub fn cycleMergeStrategy(app: *App) void {
        const c = &(app.merge_confirm orelse return);
        c.confirm.strategy = c.confirm.strategy.next(c.allowed);
    }

    fn focusMergeSession(app: *App, row_key: []const u8) Allocator.Error!void {
        const e = app.actions.get(row_key, "merge");
        app.effect(.{ .focus_session = .{
            .id = try app.effect_arena.allocator().dupe(u8, e.session),
            .cwd = try app.effect_arena.allocator().dupe(u8, app.workspace_dir),
            .prompt_line = try app.effect_arena.allocator().dupe(u8, e.prompt_line),
        } });
        app.say(.info, "{s}: asked mnml to bring its merge session up", .{row_key});
    }

    /// A `session_state` line from the host: the button it names takes
    /// the host's word. A merge that ENDS while the pane is not focused
    /// is worth a notification — it is the one thing here that changed
    /// a repository.
    pub fn onSessionState(app: *App, key: []const u8, state: sdk.wire.SessionState, session_id: []const u8, detail: []const u8) Allocator.Error!void {
        if (!try app.actions.applyState(key, sdk.pane.actionStateOf(state), session_id, detail)) return;
        const ended = state == .done or state == .failed;
        if (!ended or app.focused) return;
        const pair = sdk.pane.action.splitWatchKey(key) orelse return;
        const a = app.effect_arena.allocator();
        app.effect(.{ .notify = .{
            .title = try std.fmt.allocPrint(a, "Merge {s}", .{if (state == .done) "finished" else "failed"}),
            .text = try std.fmt.allocPrint(a, "{s} \u{2014} {s}", .{ pair.row, if (detail.len > 0) detail else "see the session" }),
            .bad = state == .failed,
        } });
        // A merge that lands takes its own row off the open list, so
        // the message about it is the last place the pull request is
        // named. The offer is the door back to it.
        if (try app.mergedPrUrl(a, pair.row)) |url| {
            app.toastWithAction(
                if (state == .done) .info else .err,
                .{ .label = "Open PR", .url = url },
                "merge {s}: {s}",
                .{ if (state == .done) "finished" else "failed", pair.row },
            );
        }
    }

    /// The web page of the pull request a `<ws>/<repo>#<id>` row key
    /// names, or null when this pane has no such row any more — which
    /// is exactly what a landed merge does to it.
    fn mergedPrUrl(app: *App, a: Allocator, row_key: []const u8) Allocator.Error!?[]const u8 {
        const hash = std.mem.lastIndexOfScalar(u8, row_key, '#') orelse return null;
        const slug = row_key[0..hash];
        const id = row_key[hash + 1 ..];
        const ws = app.activeTab().spec.workspace;
        if (ws.len == 0 or slug.len == 0 or id.len == 0) return null;
        return try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pull-requests/{s}", .{ ws, slug, id });
    }

    /// A pull request's builds: fold them out (fetching the runs on
    /// the commit it is about the first time) or fold them back in.
    ///
    /// The fetch is keyed by the pull request's `updated_on`. Bitbucket
    /// moves it when anything on the PR does, a push included, so a
    /// pull request that has not moved since its runs were read costs
    /// nothing to open again — and one that has is re-read without the
    /// user having to know to ask.
    fn togglePrBuilds(app: *App, slug: []const u8, pr: model.PullRequest) Allocator.Error!void {
        const hash = pr.buildCommit();
        if (hash.len == 0) {
            app.say(.warn, "PR #{d} names no commit to look up builds on", .{pr.id});
            return;
        }
        const ts = app.activeTab();
        if (ts.expanded.hasPr(slug, pr.id)) {
            try ts.expanded.setPr(slug, pr.id, false);
            return;
        }
        try ts.expanded.setPr(slug, pr.id, true);
        if (app.prPipelinesOf(slug, pr.id)) |had| {
            if (std.mem.eql(u8, had.updated_on, pr.updated_on)) return;
            // It moved: the runs on screen are last time's.
            app.dropPrPipelines(slug, pr.id);
        }
        app.setStatus("fetching builds for PR #{d} on {s}…", .{ pr.id, hash[0..@min(hash.len, 7)] });
        try app.enqueue(.{ .pr_pipelines = .{ .tab = app.active, .workspace = ts.spec.workspace, .slug = slug, .id = pr.id, .hash = hash, .updated_on = pr.updated_on } });
    }

    fn dropPrPipelines(app: *App, slug: []const u8, id: i64) void {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}#{d}", .{ slug, id }) catch return;
        if (app.pr_pipelines.fetchRemove(key)) |kv| {
            app.gpa.free(kv.key);
            kv.value.arena.deinit();
            app.gpa.destroy(kv.value);
        }
    }

    // ─── the persisting keys ─────────────────────────────────────────

    fn persist(app: *App) void {
        app.syncConfigLists();
        cfg.save(app.gpa, app.io, app.config_path, app.config) catch {
            app.say(.err, "could not write {s}", .{app.config_path});
        };
    }

    /// `x`: hide the focused repo — off the tree and into `hidden_repos`.
    fn hideFocused(app: *App, rows: []const tabs.VisibleRow) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return;
        const repo = tabs.repoOf(rows[ts.selected]) orelse return;
        const slug = slugOf(ts, repo);
        if (!cfg.contains(@ptrCast(app.hidden.items), slug)) try app.hidden.append(app.gpa, try app.gpa.dupe(u8, slug));
        app.scope_gen += 1;
        app.persist();
        // The row goes now; the next fetch will not bring it back.
        try app.dropRepo(slug);
        try app.refreshWorkspaceTabs();
        app.say(.info, "hid {s} (H to un-hide all)", .{slug});
    }

    /// Remove a repo's row from every tree in place.
    fn dropRepo(app: *App, slug: []const u8) Allocator.Error!void {
        for (app.tabs) |*ts| switch (ts.data) {
            .repo_pr_tree => |repos| {
                var kept: std.ArrayList(model.RepoPrs) = .empty;
                const a = if (ts.data_arena) |*ar| ar.allocator() else app.gpa;
                for (repos) |r| if (!std.mem.eql(u8, r.slug, slug)) try kept.append(a, r);
                ts.data = .{ .repo_pr_tree = try kept.toOwnedSlice(a) };
                if (ts.selected > 0) ts.selected -= 1;
            },
            .repo_tree => |repos| {
                var kept: std.ArrayList(model.RepoPipelines) = .empty;
                const a = if (ts.data_arena) |*ar| ar.allocator() else app.gpa;
                for (repos) |r| if (!std.mem.eql(u8, r.slug, slug)) try kept.append(a, r);
                ts.data = .{ .repo_tree = try kept.toOwnedSlice(a) };
                if (ts.selected > 0) ts.selected -= 1;
            },
            else => {},
        };
    }

    /// `H`: clear `hidden_repos`.
    fn unhideAll(app: *App) Allocator.Error!void {
        const n = app.hidden.items.len;
        if (n == 0) {
            app.say(.info, "nothing hidden", .{});
            return;
        }
        for (app.hidden.items) |h| app.gpa.free(h);
        app.hidden.clearRetainingCapacity();
        app.scope_gen += 1;
        app.persist();
        try app.refreshWorkspaceTabs();
        app.say(.info, "un-hid {d} repo(s)", .{n});
    }

    /// `s`: all → recent → explicit → all (explicit with no list is
    /// skipped, as the config would refuse it).
    fn cycleScope(app: *App) Allocator.Error!void {
        var next = app.scope.next();
        if (next == .explicit and app.config.explicit_repos.len == 0) next = next.next();
        app.scope = next;
        app.scope_gen += 1;
        app.persist();
        try app.refreshWorkspaceTabs();
        app.say(.info, "scope: {s}", .{@tagName(next)});
    }

    /// `alt+↑` / `alt+↓`: move the focused repo in `repo_order` and in
    /// the tree.
    fn reorder(app: *App, rows: []const tabs.VisibleRow, delta: isize) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.selected >= rows.len) return;
        const repo = tabs.repoOf(rows[ts.selected]) orelse return;
        const n = ts.data.len();
        const target_i: isize = @as(isize, @intCast(repo)) + delta;
        if (target_i < 0 or target_i >= @as(isize, @intCast(n))) return;
        const target: usize = @intCast(target_i);
        switch (ts.data) {
            .repo_pr_tree => |repos| std.mem.swap(model.RepoPrs, &@constCast(repos)[repo], &@constCast(repos)[target]),
            .repo_tree => |repos| std.mem.swap(model.RepoPipelines, &@constCast(repos)[repo], &@constCast(repos)[target]),
            else => return,
        }
        // The order list is the tree's order, whole.
        for (app.order.items) |o| app.gpa.free(o);
        app.order.clearRetainingCapacity();
        var i: usize = 0;
        while (i < n) : (i += 1) try app.order.append(app.gpa, try app.gpa.dupe(u8, slugOf(ts, i)));
        app.scope_gen += 1;
        app.persist();
        _ = app.frame_arena.reset(.retain_capacity);
        const after = try app.visible(app.frame_arena.allocator());
        if (tabs.headerRowOf(after.rows, target)) |hr| ts.selected = hr;
    }

    fn refreshWorkspaceTabs(app: *App) Allocator.Error!void {
        for (app.tabs, 0..) |*ts, i| if (ts.spec.kind.isWorkspaceWide()) try app.refreshTab(i);
    }

    // ─── focus one pull request ──────────────────────────────────────

    /// // changed (focus-row): land the cursor on ONE pull request,
    /// `<repo>#<id>` — `--focus` on the argv, or a `focus_item` handed
    /// over the mount when this pane is already the open one. A key
    /// that cannot land yet is remembered and tried again at every
    /// listing that arrives, so the flag may be read long before there
    /// is anything to land on.
    ///
    /// `workspace/repo#id` is accepted too: the hover row and the
    /// detail cache spell the same pull request two ways, and a reader
    /// who types either means the same thing.
    pub fn requestFocus(app: *App, key: []const u8) Allocator.Error!void {
        const want = shortKey(key);
        app.focus_key_len = @min(want.len, app.focus_key_buf.len);
        @memcpy(app.focus_key_buf[0..app.focus_key_len], want[0..app.focus_key_len]);
        // The listing may already be here — a second row of the same
        // hover must move the cursor now, not at the next refresh.
        try app.tryFocus(app.activeTab().fetched);
    }

    /// `acme/api#12` and `api#12` are the same pull request; the tabs
    /// key rows by the second shape.
    fn shortKey(key: []const u8) []const u8 {
        const cut = std.mem.lastIndexOfScalar(u8, key, '/') orelse return key;
        return key[cut + 1 ..];
    }

    /// Try to put the cursor on the pull request `--focus` asked for.
    /// `settle` says this was the answer being waited on: a key that is
    /// in no listing gets told so and is forgotten, rather than lying
    /// in wait for a tab that will never hold it.
    pub fn tryFocus(app: *App, settle: bool) Allocator.Error!void {
        if (app.focus_key_len == 0) return;
        var want_buf: [256]u8 = undefined;
        const want = want_buf[0..app.focus_key_len];
        @memcpy(want, app.focus_key_buf[0..app.focus_key_len]);
        if (try app.landFocus(want)) {
            app.focus_key_len = 0;
            return;
        }
        if (!settle) return;
        app.say(.warn, "not in this listing: {s}", .{want});
        app.focus_key_len = 0;
    }

    /// The tab that holds `want`, the repo it sits under, and the
    /// cursor on its row — or false, and nothing touched.
    fn landFocus(app: *App, want: []const u8) Allocator.Error!bool {
        // The tab in front of the reader first: a pull request that is
        // in two listings is the one already on screen.
        var i: usize = 0;
        while (i <= app.tabs.len) : (i += 1) {
            const idx = if (i == 0) app.active else i - 1;
            if (idx >= app.tabs.len) continue;
            if (i > 0 and idx == app.active) continue;
            const slug = prSlugIn(&app.tabs[idx], want) orelse continue;
            if (idx != app.active) try app.switchTab(idx);
            const ts = app.activeTab();
            // Whatever hides the row, open it: a repo folded shut, the
            // 24-hour `Show more` cut, a `/` query from before.
            try ts.expanded.setRepo(slug, true);
            ts.show_all = true;
            app.filter.clearRetainingCapacity();
            app.filter_caret = 0;
            _ = app.frame_arena.reset(.retain_capacity);
            const rows = (try app.visible(app.frame_arena.allocator())).rows;
            const was = ts.selected;
            for (rows, 0..) |_, r| {
                ts.selected = r;
                const k = app.focusedKey(rows) orelse continue;
                var kb: [256]u8 = undefined;
                if (!std.mem.eql(u8, prRowKey(&kb, k.repo, k.id), want)) continue;
                app.detail_visible = true;
                app.detail_scroll = 0;
                try app.ensureDetail(rows);
                return true;
            }
            // In the data but not in the rows: the awaiting-only
            // filter is the one thing `--focus` will not undo, because
            // undoing it would empty the listing the reader asked for.
            ts.selected = was;
            return false;
        }
        return false;
    }

    /// The repo slug `want` sits under in this tab's data, if it is
    /// there at all. Read off the data rather than the rows, because a
    /// row that is folded away is still a pull request this tab holds.
    fn prSlugIn(ts: *const TabState, want: []const u8) ?[]const u8 {
        if (!ts.fetched) return null;
        var buf: [256]u8 = undefined;
        switch (ts.data) {
            .repo_pr_tree => |repos| for (repos) |rp| {
                for (rp.prs) |pr| if (std.mem.eql(u8, prRowKey(&buf, rp.slug, pr.id), want)) return rp.slug;
            },
            .pull_requests => |list| for (list) |pr| {
                const slug = if (pr.repoSlug().len > 0) pr.repoSlug() else ts.spec.repo;
                if (std.mem.eql(u8, prRowKey(&buf, slug, pr.id), want)) return slug;
            },
            else => {},
        }
        return null;
    }

    // ─── tabs and refresh ────────────────────────────────────────────

    pub fn switchTab(app: *App, idx: usize) Allocator.Error!void {
        if (idx >= app.tabs.len) return;
        app.active = idx;
        app.detail_scroll = 0;
        const ts = app.activeTab();
        if (!ts.fetched and !ts.loading) try app.refreshTab(idx);
    }

    pub fn refreshActive(app: *App) Allocator.Error!void {
        try app.refreshActiveMode(false);
    }

    /// `r` (`full = false`) lets a held `ETag` make the ask cheap: the
    /// server answers 304 and no bytes when nothing has moved. `R`
    /// (`full = true`) asks outright and ignores every cache, which is
    /// how a tag that has somehow gone wrong is cleared.
    pub fn refreshActiveMode(app: *App, full: bool) Allocator.Error!void {
        try app.refreshTabMode(app.active, full);
        app.last_refresh_secs = app.now_secs;
    }

    pub fn refreshTab(app: *App, idx: usize) Allocator.Error!void {
        try app.refreshTabMode(idx, false);
    }

    pub fn refreshTabMode(app: *App, idx: usize, full: bool) Allocator.Error!void {
        const ts = &app.tabs[idx];
        if (ts.loading) return;
        // The cursor survives the swap: remember the PR it is on, since
        // the row it sits on will have moved by the time the new rows
        // land.
        ts.keep_key_len = 0;
        if (idx == app.active) {
            _ = app.frame_arena.reset(.retain_capacity);
            if (app.visible(app.frame_arena.allocator())) |view| {
                if (app.focusedKey(view.rows)) |k| {
                    const txt = keyText(&ts.keep_key_buf, k);
                    ts.keep_key_len = txt.len;
                }
            } else |_| {}
        }
        ts.loading = true;
        app.setStatus("refreshing {s}…", .{ts.spec.name});
        try app.enqueueFull(.{ .refresh = .{ .tab = idx, .spec = ts.spec, .scope = app.scopeInputs(ts.spec.workspace) } }, full);
        if (app.detail_visible) app.invalidateFocusedDetail();
    }

    /// The account the `mine` and `awaiting` filters are about: what
    /// `config.zon` says, else what `/2.0/user` answered.
    pub fn meId(app: *const App) []const u8 {
        return if (app.config.account_id.len > 0) app.config.account_id else app.me_account_id;
    }

    /// How many open pull requests on the active tab are waiting on
    /// this account's review — the `awaiting:` chip's number. Off the
    /// `participants` the listing already carries: no request.
    pub fn awaitingCount(app: *App) usize {
        const ts = app.activeTab();
        const me = app.meId();
        if (me.len == 0) return 0;
        var n: usize = 0;
        switch (ts.data) {
            .repo_pr_tree => |repos| for (repos) |r| {
                for (r.prs) |pr| n += @intFromBool(pr.isOpen() and pr.awaitingApproval(me));
            },
            .pull_requests => |list| for (list) |pr| {
                n += @intFromBool(pr.isOpen() and pr.awaitingApproval(me));
            },
            else => {},
        }
        return n;
    }

    /// The `awaiting:` chip: show only what is waiting on your review,
    /// or everything again. It narrows rows that are already loaded, so
    /// there is nothing to refetch and nothing to pay for.
    pub fn toggleAwaiting(app: *App) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.spec.kind == .workspace_pipelines or ts.spec.kind == .branches or ts.spec.kind == .pipelines) {
            app.say(.warn, "Awaiting-my-review is a pull-request filter", .{});
            return;
        }
        if (app.meId().len == 0) {
            app.say(.warn, "no account to match reviewers against — set `account_id` in config.zon", .{});
            return;
        }
        app.awaiting_only = !app.awaiting_only;
        ts.selected = 0;
        ts.scroll = 0;
        app.say(.info, "{s}: {s}", .{ ts.spec.name, if (app.awaiting_only) "awaiting my approval" else "every pull request" });
    }

    /// The `author:` chip: mine ↔ all on a workspace PR tab.
    pub fn toggleMineOnly(app: *App) Allocator.Error!void {
        const ts = app.activeTab();
        if (!ts.spec.kind.isWorkspaceWide() or ts.spec.kind == .workspace_pipelines) {
            app.say(.warn, "Author filter not supported on this tab", .{});
            return;
        }
        ts.spec.mine_only = !ts.spec.mine_only;
        ts.fetched = false;
        try app.refreshTab(app.active);
        app.say(.info, "{s}: filter → {s}", .{ ts.spec.name, if (ts.spec.mine_only) "Authored by me" else "All" });
    }

    // ─── the detail and approve ──────────────────────────────────────

    fn ensureDetail(app: *App, rows: []const tabs.VisibleRow) Allocator.Error!void {
        const k = app.focusedKey(rows) orelse return;
        var buf: [256]u8 = undefined;
        const key = keyText(&buf, k);
        if (app.details.contains(key)) return;
        if (app.detail_in_flight) |f| if (std.mem.eql(u8, f, key)) return;
        if (app.detail_in_flight) |f| app.gpa.free(f);
        app.detail_in_flight = try app.gpa.dupe(u8, key);
        try app.enqueue(.{ .detail = k });
    }

    fn invalidateFocusedDetail(app: *App) void {
        _ = app.frame_arena.reset(.retain_capacity);
        const rows = (app.visible(app.frame_arena.allocator()) catch return).rows;
        const k = app.focusedKey(rows) orelse return;
        var buf: [256]u8 = undefined;
        const key = keyText(&buf, k);
        if (app.details.fetchRemove(key)) |kv| {
            app.gpa.free(kv.key);
            kv.value.arena.deinit();
            app.gpa.destroy(kv.value);
        }
    }

    /// `a`: approve, or withdraw when the account already did.
    fn toggleApproval(app: *App, rows: []const tabs.VisibleRow) Allocator.Error!void {
        if (!app.detail_visible) return;
        const k = app.focusedKey(rows) orelse return;
        const me = if (app.config.account_id.len > 0) app.config.account_id else app.me_account_id;
        if (me.len == 0) {
            app.say(.warn, "approve needs Account:Read on the token (or `account_id` in config.zon)", .{});
            return;
        }
        const entry = app.focusedDetail(rows) orelse {
            app.say(.warn, "detail not loaded yet — press d", .{});
            return;
        };
        const withdraw = entry.pr.approvedBy(me);
        var buf: [256]u8 = undefined;
        app.setStatus("{s} {s}…", .{ if (withdraw) "unapproving" else "approving", keyText(&buf, k) });
        try app.enqueue(.{ .approve = .{ .key = k, .withdraw = withdraw } });
    }

    // ─── results ─────────────────────────────────────────────────────

    /// A job's result, on the app's thread. Takes the result's arena.
    pub fn commit(app: *App, res: *fetch.Result) Allocator.Error!void {
        var keep_arena = false;
        defer if (!keep_arena) res.arena.deinit();
        switch (res.payload) {
            .whoami => |w| {
                if (w.error_text.len > 0) {
                    app.say(.warn, "{s}", .{w.error_text});
                } else {
                    app.gpa.free(app.me_account_id);
                    app.me_account_id = try app.gpa.dupe(u8, w.account_id);
                    app.gpa.free(app.me_display_name);
                    app.me_display_name = try app.gpa.dupe(u8, w.display_name);
                }
            },
            .readiness => |rr| {
                var kbuf: [256]u8 = undefined;
                const key = prRowKey(&kbuf, rr.key.repo, rr.key.id);
                if (app.readiness_in_flight.fetchRemove(key)) |kv| app.gpa.free(kv.key);
                if (rr.error_text.len > 0) app.setStatus("{s}", .{rr.error_text});
                try app.putReadiness(key, rr.updated_on, rr.readiness);
            },
            .refresh => |r| {
                if (r.tab >= app.tabs.len) return;
                const ts = &app.tabs[r.tab];
                ts.loading = false;
                app.refreshes_landed += 1;
                if (r.data) |data| {
                    if (ts.data_arena) |*old| old.deinit();
                    ts.data_arena = res.arena;
                    keep_arena = true;
                    ts.data = data;
                    ts.fetched = true;
                    ts.fetched_at = app.now_secs;
                    ts.show_all = false;
                    ts.repos = r.repos;
                    ts.items = r.items;
                    ts.errored = r.errored;
                    try TabState.setText(app.gpa, &ts.error_text, "");
                    try TabState.setText(app.gpa, &ts.status, r.status);
                    // The trees open every repo on their first fetch and
                    // keep the user's choices after that.
                    switch (data) {
                        .repo_pr_tree => |repos| {
                            const slugs = try app.frame_arena.allocator().alloc([]const u8, repos.len);
                            for (repos, slugs) |rp, *s| s.* = rp.slug;
                            try ts.expanded.carryOver(slugs);
                        },
                        .repo_tree => |repos| {
                            const slugs = try app.frame_arena.allocator().alloc([]const u8, repos.len);
                            for (repos, slugs) |rp, *s| s.* = rp.slug;
                            try ts.expanded.carryOver(slugs);
                        },
                        else => {},
                    }
                    // A message set after the refresh was queued (`hid api`)
                    // outlives it, as it does in the reference.
                    if (r.tab == app.active and (app.status.items.len == 0 or std.mem.startsWith(u8, app.status.items, "refreshing "))) app.setStatus("{s}", .{r.status});
                    // A refresh that came back with every repo errored
                    // and nothing to show is a failed refresh, whatever
                    // the shape of the answer: the list on screen is
                    // stale and nothing on it says so. It gets the same
                    // offer as one that failed outright.
                    if (r.errored > 0 and r.items == 0) {
                        app.toastWithAction(.err, retry_action, "error: {s}", .{r.status});
                    }
                } else {
                    try TabState.setText(app.gpa, &ts.error_text, r.error_text);
                    try TabState.setText(app.gpa, &ts.status, r.status);
                    app.setStatus("error: {s}", .{r.error_text});
                    app.toastWithAction(.err, retry_action, "error: {s}", .{r.error_text});
                }
                _ = app.frame_arena.reset(.retain_capacity);
                const rows = (try app.visible(app.frame_arena.allocator())).rows;
                if (rows.len == 0) ts.selected = 0 else ts.selected = @min(ts.selected, rows.len - 1);
                // Put the cursor back on the PR it was on. Its row will
                // have moved — a merge, a new PR above it — so the key
                // is what is followed, not the index.
                if (r.tab == app.active and ts.keep_key_len > 0 and rows.len > 0) {
                    const want = ts.keep_key_buf[0..ts.keep_key_len];
                    const was = ts.selected;
                    for (rows, 0..) |_, i| {
                        ts.selected = i;
                        var buf: [256]u8 = undefined;
                        const k = app.focusedKey(rows) orelse continue;
                        if (std.mem.eql(u8, keyText(&buf, k), want)) break;
                    } else ts.selected = was;
                }
                ts.keep_key_len = 0;
                // A `--focus` is answered by the listing it was
                // waiting for: the active tab's, which is the one the
                // reader is looking at.
                try app.tryFocus(r.tab == app.active);
            },
            .detail => |d| {
                var buf: [256]u8 = undefined;
                const key = keyText(&buf, d.key);
                if (app.detail_in_flight) |f| if (std.mem.eql(u8, f, key)) {
                    app.gpa.free(f);
                    app.detail_in_flight = null;
                };
                if (d.pr) |pr| {
                    const entry = try app.gpa.create(DetailEntry);
                    entry.* = .{ .arena = res.arena, .pr = pr, .comments = d.comments };
                    keep_arena = true;
                    if (app.details.fetchRemove(key)) |kv| {
                        app.gpa.free(kv.key);
                        kv.value.arena.deinit();
                        app.gpa.destroy(kv.value);
                    }
                    try app.details.put(app.gpa, try app.gpa.dupe(u8, key), entry);
                } else {
                    app.say(.err, "{s}", .{d.error_text});
                }
            },
            .pr_pipelines => |p| {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}#{d}", .{ p.slug, p.id }) catch return;
                const entry = try app.gpa.create(PrPipelines);
                entry.* = .{ .arena = res.arena, .pipelines = p.pipelines, .error_text = p.error_text, .updated_on = p.updated_on };
                keep_arena = true;
                if (app.pr_pipelines.fetchRemove(key)) |kv| {
                    app.gpa.free(kv.key);
                    kv.value.arena.deinit();
                    app.gpa.destroy(kv.value);
                }
                try app.pr_pipelines.put(app.gpa, try app.gpa.dupe(u8, key), entry);
                if (p.error_text.len > 0) {
                    app.say(.err, "PR #{d} {s}", .{ p.id, p.error_text });
                } else {
                    app.setStatus("PR #{d}: {d} pipeline(s) on merge commit", .{ p.id, p.pipelines.len });
                }
            },
            .approve => |ap| {
                var buf: [256]u8 = undefined;
                const key = keyText(&buf, ap.key);
                if (ap.error_text.len > 0) {
                    app.say(.err, "{s}", .{ap.error_text});
                } else {
                    app.say(.info, "{s} {s}", .{ if (ap.withdrew) "unapproved" else "approved", key });
                    if (app.details.fetchRemove(key)) |kv| {
                        app.gpa.free(kv.key);
                        kv.value.arena.deinit();
                        app.gpa.destroy(kv.value);
                    }
                    if (app.detail_visible) {
                        _ = app.frame_arena.reset(.retain_capacity);
                        const rows = (try app.visible(app.frame_arena.allocator())).rows;
                        try app.ensureDetail(rows);
                    }
                }
            },
            .values => |v| {
                app.values_requested = false;
                app.values_at_secs = app.now_secs;
                // The figure's strings come with it: the arena is taken
                // off the result rather than dropped at the bottom of
                // this function, because `app.values` is read long
                // after — every `.segment` effect republishes the chip
                // out of it, rows and all.
                if (app.values_arena) |*old| old.deinit();
                app.values_arena = res.arena;
                keep_arena = true;
                app.values = v;
                const a = app.effect_arena.allocator();
                const g = app.chipGlyph();
                if (v.error_text.len > 0) {
                    app.effect(.{ .segment = .{ .text = try std.fmt.allocPrint(a, "{s} !", .{g}), .tooltip = try std.fmt.allocPrint(a, "last error: {s}", .{v.error_text}) } });
                } else {
                    app.effect(.{ .segment = .{
                        .text = try std.fmt.allocPrint(a, "{s} {d}({d})", .{ g, v.open_mine, v.unapproved_mine }),
                        .tooltip = chip_tooltip,
                    } });
                }
            },
        }
    }

    /// nf-md-bitbucket, the reference's chip glyph.
    pub const chip_glyph = "\u{f00a8}";
    /// What the chip wears on a terminal with no Nerd Font — the same
    /// two-cell shape, so the figure beside it stays where it was.
    /// `sdk.pane.figure`'s own tests name this twin for the forge pane.
    pub const chip_ascii = "BB";

    /// The chip glyph this pane's host can actually paint.
    pub fn chipGlyph(app: *const App) []const u8 {
        return if (app.ascii) chip_ascii else chip_glyph;
    }
    pub const chip_tooltip = "Open PRs you authored (last 90 days, non-release) — parens = still-needs-review count. Click to open the mine-only PRs tab.";

    // ─── the filter ──────────────────────────────────────────────────

    fn filterKey(app: *App, spec: []const u8) Allocator.Error!bool {
        const f = &app.filter;
        if (std.mem.eql(u8, spec, "esc")) {
            f.clearRetainingCapacity();
            app.filter_caret = 0;
            app.mode = .list;
        } else if (std.mem.eql(u8, spec, "enter")) {
            app.mode = .list;
        } else if (std.mem.eql(u8, spec, "backspace")) {
            if (app.filter_caret > 0) {
                const start = prevBoundary(f.items, app.filter_caret);
                f.replaceRange(app.gpa, start, app.filter_caret - start, &.{}) catch {};
                app.filter_caret = start;
            }
        } else if (std.mem.eql(u8, spec, "delete")) {
            if (app.filter_caret < f.items.len) {
                const end = nextBoundary(f.items, app.filter_caret);
                f.replaceRange(app.gpa, app.filter_caret, end - app.filter_caret, &.{}) catch {};
            }
        } else if (std.mem.eql(u8, spec, "left")) {
            app.filter_caret = prevBoundary(f.items, app.filter_caret);
        } else if (std.mem.eql(u8, spec, "right")) {
            app.filter_caret = nextBoundary(f.items, app.filter_caret);
        } else if (std.mem.eql(u8, spec, "home")) {
            app.filter_caret = 0;
        } else if (std.mem.eql(u8, spec, "end")) {
            app.filter_caret = f.items.len;
        } else if (std.mem.eql(u8, spec, "ctrl+u")) {
            f.clearRetainingCapacity();
            app.filter_caret = 0;
        } else if (std.mem.eql(u8, spec, "space")) {
            try f.insertSlice(app.gpa, app.filter_caret, " ");
            app.filter_caret += 1;
        } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "up")) {
            app.mode = .list;
            return app.keyPress(spec);
        } else if (printable(spec)) {
            try f.insertSlice(app.gpa, app.filter_caret, spec);
            app.filter_caret += spec.len;
        } else if (std.mem.startsWith(u8, spec, "shift+") and spec.len == 7) {
            const up = std.ascii.toUpper(spec[6]);
            try f.insert(app.gpa, app.filter_caret, up);
            app.filter_caret += 1;
        }
        app.activeTab().selected = 0;
        return true;
    }

    /// A bracketed paste lands in the filter when it has the keys.
    pub fn paste(app: *App, text: []const u8) Allocator.Error!void {
        if (app.mode != .filter) return;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(app.gpa);
        for (text) |c| if (c != '\n' and c != '\r') try clean.append(app.gpa, c);
        try app.filter.insertSlice(app.gpa, app.filter_caret, clean.items);
        app.filter_caret += clean.items.len;
    }

    fn printable(spec: []const u8) bool {
        if (spec.len == 0) return false;
        if (std.mem.indexOfScalar(u8, spec, '+') != null and spec.len > 1) return false;
        if (spec.len == 1) return spec[0] >= 0x20 and spec[0] < 0x7f;
        // A multi-byte code point arrives as itself.
        return std.unicode.utf8ValidateSlice(spec) and (std.unicode.utf8CountCodepoints(spec) catch 2) == 1;
    }

    fn prevBoundary(s: []const u8, i: usize) usize {
        var j = i;
        while (j > 0) {
            j -= 1;
            if (s[j] & 0xC0 != 0x80) return j;
        }
        return 0;
    }

    fn nextBoundary(s: []const u8, i: usize) usize {
        var j = i + 1;
        while (j < s.len and s[j] & 0xC0 == 0x80) j += 1;
        return @min(j, s.len);
    }

    // ─── the row menu ────────────────────────────────────────────────

    /// The actions a right-click offers on a row.
    pub fn menuFor(app: *App, rows: []const tabs.VisibleRow, idx: usize) []const Action {
        var n: usize = 0;
        const ts = app.activeTab();
        if (idx >= rows.len) return app.menu_items[0..0];
        const push = struct {
            fn f(items: *[12]Action, count: *usize, a: Action) void {
                if (count.* < items.len) {
                    items[count.*] = a;
                    count.* += 1;
                }
            }
        }.f;
        switch (rows[idx]) {
            .repo_header => {
                push(&app.menu_items, &n, .activate);
                push(&app.menu_items, &n, .open_web);
                push(&app.menu_items, &n, .yank_url);
                push(&app.menu_items, &n, .hide_repo);
                push(&app.menu_items, &n, .reorder_up);
                push(&app.menu_items, &n, .reorder_down);
            },
            .pr => |p| {
                push(&app.menu_items, &n, .toggle_detail);
                push(&app.menu_items, &n, .open_web);
                push(&app.menu_items, &n, .yank_url);
                const pr = ts.data.repo_pr_tree[p.repo].prs[p.idx];
                if (pr.buildCommit().len > 0) push(&app.menu_items, &n, .activate);
                // The inline `[ Merge ]` only fits a wide pane, so the
                // menu carries it at every width.
                if (pr.isOpen()) push(&app.menu_items, &n, .merge_pr);
                if (app.detail_visible) push(&app.menu_items, &n, .toggle_approval);
            },
            // A build line offers its own page and nothing else — the
            // row menu must never fire an action the row cannot do.
            .build, .build_note => {
                push(&app.menu_items, &n, .open_web);
                push(&app.menu_items, &n, .yank_url);
            },
            .branch => {
                push(&app.menu_items, &n, .open_web);
                push(&app.menu_items, &n, .yank_url);
            },
            .show_more => push(&app.menu_items, &n, .activate),
            .flat => {
                if (ts.data == .pull_requests) push(&app.menu_items, &n, .toggle_detail);
                push(&app.menu_items, &n, .open_web);
                push(&app.menu_items, &n, .yank_url);
            },
        }
        return app.menu_items[0..n];
    }

    fn menuKey(app: *App, a: Allocator, spec: []const u8) Allocator.Error!bool {
        var m = app.menu orelse {
            app.mode = .list;
            return true;
        };
        if (std.mem.eql(u8, spec, "esc") or std.mem.eql(u8, spec, "q")) {
            app.menu = null;
            app.mode = .list;
        } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) {
            if (m.selected + 1 < m.items.len) m.selected += 1;
            app.menu = m;
        } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) {
            m.selected -|= 1;
            app.menu = m;
        } else if (std.mem.eql(u8, spec, "enter")) {
            return app.runMenuItem(a, m.selected);
        }
        return true;
    }

    fn runMenuItem(app: *App, a: Allocator, item: usize) Allocator.Error!bool {
        const m = app.menu orelse return true;
        app.menu = null;
        app.mode = .list;
        if (item >= m.items.len) return true;
        const view = try app.visible(a);
        app.select(view.rows, m.row);
        return app.run(a, m.items[item], view.rows);
    }

    // ─── the mouse ───────────────────────────────────────────────────

    pub const Button = enum { left, middle, right };

    /// A click, routed through the hit map the last paint registered.
    pub fn click(app: *App, col: u16, row: u16, button: Button) Allocator.Error!bool {
        _ = app.frame_arena.reset(.retain_capacity);
        const a = app.frame_arena.allocator();
        const target = app.hits.at(col, row);
        if (app.mode == .menu) {
            if (target) |tg| switch (tg) {
                .menu_item => |i| return app.runMenuItem(a, i),
                else => {},
            };
            app.menu = null;
            app.mode = .list;
            return true;
        }
        if (app.mode == .help) {
            // A row of the sheet runs its chord; anywhere else closes.
            if (target) |tg| if (tg == .sheet_row) {
                app.mode = .list;
                const rows = (try app.visible(a)).rows;
                return app.run(a, tg.sheet_row, rows);
            };
            app.mode = .list;
            return true;
        }
        if (app.mode == .filter and (target == null or target.? != .chip)) app.mode = .list;
        const tg = target orelse return true;
        const view = try app.visible(a);
        switch (tg) {
            .tab => |i| try app.switchTab(i),
            .chip => |c| switch (c) {
                .refresh => try app.refreshActive(),
                .help => {
                    app.mode = .help;
                    app.help_scroll = 0;
                },
                .author => try app.toggleMineOnly(),
                .awaiting => try app.toggleAwaiting(),
                .filter => {
                    app.mode = .filter;
                    app.filter_caret = app.filter.items.len;
                },
                .run_pipeline, .schedules, .caches, .usage => try app.openPipelinesPage(c),
            },
            // A dim `[ Merge ]` registers only `merge_blocked`, so a
            // click that lands on one says why rather than doing
            // anything.
            .merge_blocked => |i| {
                app.select(view.rows, i);
                const f = app.focusedPr(view.rows) orelse return true;
                var buf: [192]u8 = undefined;
                app.say(.warn, "{s}", .{app.readinessOf(f.slug, f.pr).hoverText(&buf)});
                try app.ensureReadiness(f.slug, f.pr);
            },
            .pr_button => |b| {
                app.select(view.rows, b.row);
                const f = app.focusedPr(view.rows) orelse return true;
                switch (b.which) {
                    // `[ Open ]` opens the ROW — its builds — not a
                    // browser. The pull request itself is still the
                    // row's Enter and the row menu's "open on the web".
                    .open => try app.togglePrBuilds(f.slug, f.pr),
                    .merge => try app.pressMerge(f.slug, f.pr),
                }
            },
            .confirm_ok => try app.acceptMergeConfirm(),
            .confirm_cancel => app.closeMergeConfirm(),
            .confirm_body => {},
            // A build line is a door, not a row you select: left goes
            // to that run's page — `activate` already knows the way —
            // and right keeps the row menu, so the rest of the tree is
            // still reachable from there.
            .build_line => |i| {
                app.select(view.rows, i);
                if (button == .right) {
                    const items = app.menuFor(view.rows, i);
                    if (items.len > 0) {
                        app.menu = .{ .row = i, .col = col, .y = row, .items = items };
                        app.mode = .menu;
                    }
                } else {
                    try app.activate(a, view.rows);
                }
                if (app.detail_visible) try app.ensureDetail((try app.visible(a)).rows);
            },
            .row => |i| {
                app.select(view.rows, i);
                if (button == .right) {
                    const items = app.menuFor(view.rows, i);
                    if (items.len > 0) {
                        app.menu = .{ .row = i, .col = col, .y = row, .items = items };
                        app.mode = .menu;
                    }
                } else if (i < view.rows.len) {
                    // A click on a tree row is the reference's: select
                    // it and toggle it; a flat row only selects.
                    switch (view.rows[i]) {
                        .repo_header, .show_more => try app.activate(a, view.rows),
                        .pr => |p| {
                            const pr = app.activeTab().data.repo_pr_tree[p.repo].prs[p.idx];
                            if (pr.isMerged() and pr.merge_commit.len > 0) try app.activate(a, view.rows);
                        },
                        else => {},
                    }
                }
                if (app.detail_visible) try app.ensureDetail((try app.visible(a)).rows);
            },
            // The chevron is the row's fold: it selects the row and
            // folds it, whatever kind of row it is and whatever state
            // that row's pull request is in. A click anywhere else on
            // an OPEN pull request only selects — its builds used to be
            // unreachable by the pointer altogether, because the row's
            // own click path folded a merged one and nothing else.
            .chevron => |i| {
                app.select(view.rows, i);
                if (button == .right) {
                    const items = app.menuFor(view.rows, i);
                    if (items.len > 0) {
                        app.menu = .{ .row = i, .col = col, .y = row, .items = items };
                        app.mode = .menu;
                    }
                } else try app.activate(a, view.rows);
                if (app.detail_visible) try app.ensureDetail((try app.visible(a)).rows);
            },
            // A hint entry and a key-sheet row both run exactly what
            // their chord runs: the pointer reaches what the keyboard
            // does, and there is no second table to keep in step.
            .hint, .sheet_row => |action| return app.run(a, action, view.rows),
            .detail_close => app.detail_visible = false,
            // A press or a drag anywhere on the track goes there: the
            // bar is a control, not a decoration.
            .detail_bar => {
                const r = app.hits.rectOf(hit.Target.detail_bar) orelse return true;
                app.detail_scroll = sdk.pane.scrollAt(r, app.detail_lines, app.detail_rows, row);
            },
            .menu_item, .sheet, .detail => {},
        }
        return true;
    }

    /// A wheel notch: the detail scrolls under the pointer, the list
    /// otherwise (three rows a notch, as the reference).
    /// The pointer moved with a button held. Only the detail panel's
    /// scrollbar tracks it: everything else acts on the press, and a
    /// drag that started elsewhere must not move things on its way past.
    pub fn drag(app: *App, col: u16, row: u16) Allocator.Error!void {
        const tg = app.hits.at(col, row) orelse return;
        if (tg != .detail_bar) return;
        const r = app.hits.rectOf(hit.Target.detail_bar) orelse return;
        app.detail_scroll = sdk.pane.scrollAt(r, app.detail_lines, app.detail_rows, row);
    }

    pub fn wheel(app: *App, col: u16, row: u16, dy: i16) Allocator.Error!void {
        _ = app.frame_arena.reset(.retain_capacity);
        const a = app.frame_arena.allocator();
        if (app.mode == .help) {
            if (dy > 0) app.help_scroll -|= 3 else app.help_scroll += 3;
            return;
        }
        if (app.hits.at(col, row)) |tg| switch (tg) {
            .detail, .detail_close, .detail_bar => {
                if (dy > 0) app.detail_scroll -|= 3 else app.detail_scroll += 3;
                return;
            },
            else => {},
        };
        const view = try app.visible(a);
        app.move(view.rows, if (dy > 0) -3 else 3);
        if (app.detail_visible) try app.ensureDetail((try app.visible(a)).rows);
    }

    /// The pipelines family's chips open Bitbucket's pages.
    fn openPipelinesPage(app: *App, c: hit.Chip) Allocator.Error!void {
        const ts = app.activeTab();
        const ws = ts.spec.workspace;
        const a = app.effect_arena.allocator();
        const url: []const u8 = switch (c) {
            .usage => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/workspace/settings/plans-billing/pipelines-minutes", .{ws}),
            .run_pipeline, .schedules, .caches => blk: {
                if (ts.spec.repo.len == 0) {
                    app.say(.warn, "repo-scoped action — switch to a repo tab first", .{});
                    return;
                }
                break :blk switch (c) {
                    .run_pipeline => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pipelines", .{ ws, ts.spec.repo }),
                    .schedules => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/admin/addon/admin/pipelines/schedules", .{ ws, ts.spec.repo }),
                    else => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/admin/addon/admin/pipelines/caches", .{ ws, ts.spec.repo }),
                };
            },
            else => return,
        };
        app.effect(.{ .open_url = url });
        app.say(.info, "opened {s}", .{url});
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const api = @import("api.zig");
const ratelimit = @import("ratelimit.zig");
const listener = @import("../tools/fake_bitbucket/listener.zig");

/// An app on the fake server, with a worker run synchronously: what
/// the loop does across threads, done inline.
pub const Rig = struct {
    srv: *listener.Server,
    client: api.Client,
    progress: fetch.Progress = .{},
    worker: fetch.Worker,
    app: App,
    arena: std.heap.ArenaAllocator,
    config_path: []u8,
    tmp: std.testing.TmpDir,

    pub fn init(config: cfg.Config, opts: Options) !*Rig {
        return initOn(config, opts, t.allocator);
    }

    /// The Rig with the FETCH side — the client, the worker, and every
    /// arena a job or a result makes — on `gpa`. `Scribble` passes one
    /// that poisons what it frees, which is the only way a test can see
    /// a result still pointing at a listing that is over.
    pub fn initOn(config: cfg.Config, opts: Options, gpa: std.mem.Allocator) !*Rig {
        const r = try t.allocator.create(Rig);
        errdefer t.allocator.destroy(r);
        r.tmp = t.tmpDir(.{});
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = pbuf[0..try r.tmp.dir.realPath(t.io, &pbuf)];
        r.config_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
        r.arena = std.heap.ArenaAllocator.init(t.allocator);
        r.srv = try listener.Server.start(t.allocator, t.io, 0);
        const base = try r.srv.baseUrl(t.allocator);
        defer t.allocator.free(base);
        r.client = try api.Client.init(gpa, t.io, base, "me@x.com", "tok", "", .{});
        r.progress = .{};
        r.worker = fetch.Worker.init(gpa, t.io, &r.client, &r.progress, config.account_id, config.workspace);
        r.app = try App.init(t.allocator, t.io, config, r.config_path, opts);
        r.app.now_secs = Io.Timestamp.now(t.io, .real).toSeconds();
        r.app.cols = 120;
        r.app.rows = 40;
        try r.app.startup();
        try r.drain();
        return r;
    }

    pub fn deinit(r: *Rig) void {
        r.app.deinit();
        r.worker.deinit();
        r.client.deinit();
        r.srv.stop();
        r.arena.deinit();
        t.allocator.free(r.config_path);
        r.tmp.cleanup();
        t.allocator.destroy(r);
    }

    /// Run every queued job and commit its result.
    pub fn drain(r: *Rig) !void {
        while (true) {
            const jobs = r.app.takeJobs();
            if (jobs.len == 0) break;
            defer t.allocator.free(jobs);
            for (jobs) |*job| {
                defer job.deinit();
                var res = try r.worker.run(job);
                try r.app.commit(&res);
            }
        }
        const fx = r.app.takeEffects();
        r.app.freeEffects(fx);
    }

    pub fn key(r: *Rig, spec: []const u8) !bool {
        const alive = try r.app.keyPress(spec);
        try r.drain();
        return alive;
    }

    pub fn rows(r: *Rig) ![]const tabs.VisibleRow {
        _ = r.arena.reset(.retain_capacity);
        return (try r.app.visible(r.arena.allocator())).rows;
    }
};

/// The fixture both this file's tests and `main.zig`'s chip tests run
/// on, so the two never drift into testing different panes.
pub const acme: cfg.Config = .{ .email = "me@x.com", .workspace = "acme", .repos = &.{ "api", "web" }, .refresh_interval_secs = 0, .tabs = &cfg.default_tabs };

test "startup prefetches every tab, opens the trees, and the keys walk the rows the way the reference does" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    try t.expectEqual(@as(usize, 3), r.app.tabs.len);
    for (r.app.tabs) |ts| try t.expect(ts.fetched);
    try t.expectEqualStrings("acct-chris", r.app.me_account_id);
    try t.expectEqualStrings("Open + Draft · 2 repos, 3 PRs", r.app.tabs[0].status);
    // Both repos open on the first fetch: api, #1234 (fresh), web, #820, and a footer for #1198 (30 h old).
    var rows = try r.rows();
    try t.expectEqual(@as(usize, 5), rows.len);
    try t.expect(rows[4] == .show_more);
    _ = try r.key("j");
    try t.expectEqual(@as(usize, 1), r.app.tabs[0].selected);
    _ = try r.key("shift+g");
    try t.expectEqual(@as(usize, 4), r.app.tabs[0].selected);
    // Enter on the footer lifts the filter: #1198 appears.
    _ = try r.key("enter");
    rows = try r.rows();
    try t.expectEqual(@as(usize, 5), rows.len);
    try t.expect(rows[4] == .pr);
    // `c` collapses everything; `e` opens it again; `h` on a PR row steps up to its repo.
    _ = try r.key("c");
    try t.expectEqual(@as(usize, 2), (try r.rows()).len);
    _ = try r.key("e");
    _ = try r.key("g");
    _ = try r.key("j");
    _ = try r.key("h");
    rows = try r.rows();
    try t.expectEqual(@as(usize, 0), r.app.tabs[0].selected);
    try t.expect(!r.app.tabs[0].expanded.hasRepo("api"));
    _ = try r.key("l");
    try t.expect(r.app.tabs[0].expanded.hasRepo("api"));
    _ = try r.key("l");
    try t.expectEqual(@as(usize, 1), r.app.tabs[0].selected);
    // `m` goes to Merged, `3` to Pipelines, tab wraps, `1` is back.
    _ = try r.key("m");
    try t.expectEqual(@as(usize, 1), r.app.active);
    _ = try r.key("3");
    try t.expectEqual(@as(usize, 2), r.app.active);
    try t.expectEqual(cfg.Family.pipelines, r.app.family());
    _ = try r.key("tab");
    try t.expectEqual(@as(usize, 0), r.app.active);
    _ = try r.key("backtab");
    try t.expectEqual(@as(usize, 2), r.app.active);
    // The pipelines tree: two repos open, api's four branches under it.
    rows = try r.rows();
    try t.expectEqual(@as(usize, 9), rows.len);
    try t.expect(rows[1] == .branch);
    try t.expect(!(try r.key("q")));
}

test "`--focus` lands the cursor on that pull request, lifts what was hiding it, and opens its detail" {
    // #1198 is 30 hours old, so the workspace tab folds it behind
    // `Show more (1)` — the row the flag asks for is one nothing but a
    // key press would otherwise reach.
    const r = try Rig.init(acme, .{ .focus = "api#1198" });
    defer r.deinit();
    const ts = &r.app.tabs[0];
    try t.expect(ts.show_all);
    const rows = try r.rows();
    const k = r.app.focusedKey(rows) orelse return error.NoCursor;
    var kb: [256]u8 = undefined;
    try t.expectEqualStrings("api#1198", App.prRowKey(&kb, k.repo, k.id));
    // And the panel beside the list is open on it, not on whatever the
    // cursor happened to start on.
    try t.expect(r.app.detail_visible);
    // Consumed: a later refetch does not drag the cursor back.
    try t.expectEqual(@as(usize, 0), r.app.focus_key_len);
}

test "`--focus` takes the long spelling too, and a key in no listing says so and leaves the cursor alone" {
    const r = try Rig.init(acme, .{ .focus = "acme/api#1234" });
    defer r.deinit();
    var rows = try r.rows();
    var kb: [256]u8 = undefined;
    const k = r.app.focusedKey(rows) orelse return error.NoCursor;
    try t.expectEqualStrings("api#1234", App.prRowKey(&kb, k.repo, k.id));

    // A second ask — what a `focus_item` off the hover hands a pane
    // that is already open — moves the cursor where it points.
    try r.app.requestFocus("web#820");
    rows = try r.rows();
    const k2 = r.app.focusedKey(rows) orelse return error.NoCursor;
    try t.expectEqualStrings("web#820", App.prRowKey(&kb, k2.repo, k2.id));

    // And one that names nothing this pane holds is answered, not
    // silently ignored — the cursor stays where the reader left it.
    const before = r.app.activeTab().selected;
    try r.app.requestFocus("api#999999");
    try t.expectEqualStrings("not in this listing: api#999999", r.app.status.items);
    try t.expectEqual(before, r.app.activeTab().selected);
    try t.expectEqual(@as(usize, 0), r.app.focus_key_len);
}

test "a refetch keeps the old rows on screen and puts the cursor back on the PR it was on, not the row index" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    const ts = &r.app.tabs[0];
    // Sit on a PR and remember which one it is.
    _ = try r.key("j");
    var rows = try r.rows();
    const before = r.app.focusedKey(rows).?;
    var kbuf: [256]u8 = undefined;
    const want = try t.allocator.dupe(u8, App.keyText(&kbuf, before));
    defer t.allocator.free(want);

    // Start a refetch without running it: the rows on screen are still
    // the old ones, the tab still reads as fetched, and the header says
    // it is refreshing rather than replacing them with `loading…`.
    try r.app.refreshTab(0);
    try t.expect(ts.loading);
    try t.expect(ts.fetched);
    try t.expectEqual(rows.len, (try r.rows()).len);
    try t.expect(ts.keep_key_len > 0);
    try t.expectEqualStrings(want, ts.keep_key_buf[0..ts.keep_key_len]);
    // The cursor moves while the fetch is out; the key is what decides
    // where it lands, not where it happens to be now.
    ts.selected = 0;

    try r.drain();
    try t.expect(!ts.loading);
    rows = try r.rows();
    const after = r.app.focusedKey(rows).?;
    var abuf: [256]u8 = undefined;
    try t.expectEqualStrings(want, App.keyText(&abuf, after));
    // And the remembered key is cleared, so the next refetch reads the
    // cursor fresh.
    try t.expectEqual(@as(usize, 0), ts.keep_key_len);
}

test "the detail follows the cursor, and `a` approves then withdraws on the fake server" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    _ = try r.key("j");
    _ = try r.key("d");
    try t.expect(r.app.detail_visible);
    var rows = try r.rows();
    const d = r.app.focusedDetail(rows).?;
    try t.expectEqual(@as(i64, 1234), d.pr.id);
    try t.expectEqual(@as(usize, 3), d.comments.len);
    // #1234 is mine and Dana approved it; I have not.
    try t.expect(!d.pr.approvedBy("acct-chris"));
    _ = try r.key("a");
    try t.expectEqual(server.State.Vote.approved, r.srv.snapshot().voteFor(1234));
    rows = try r.rows();
    try t.expect(r.app.focusedDetail(rows).?.pr.approvedBy("acct-chris"));
    try t.expect(std.mem.startsWith(u8, r.app.status.items, "approved acme/api#1234"));
    _ = try r.key("a");
    try t.expectEqual(server.State.Vote.none, r.srv.snapshot().voteFor(1234));
    // Moving to web's #820 fetches that detail.
    _ = try r.key("j");
    _ = try r.key("j");
    rows = try r.rows();
    try t.expectEqual(@as(i64, 820), r.app.focusedDetail(rows).?.pr.id);
    // Without the detail open `a` is not bound.
    _ = try r.key("d");
    try t.expect(!r.app.detail_visible);
    _ = try r.key("a");
    try t.expectEqual(server.State.Vote.none, r.srv.snapshot().voteFor(820));
}

test "the persisting keys rewrite config.zon: hide, un-hide, scope, reorder" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    _ = try r.app.keyPress("x");
    try t.expectEqualStrings("hid api (H to un-hide all)", r.app.status.items);
    try r.drain();
    try t.expectEqual(@as(usize, 1), r.app.hidden.items.len);
    var text = try Io.Dir.cwd().readFileAlloc(t.io, r.config_path, t.allocator, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, text, ".hidden_repos = .{\"api\"}") != null or std.mem.indexOf(u8, text, ".hidden_repos = .{ \"api\" }") != null);
    t.allocator.free(text);
    // The tree refetched without api.
    try t.expectEqual(@as(usize, 1), r.app.tabs[0].data.repo_pr_tree.len);
    try t.expectEqualStrings("web", r.app.tabs[0].data.repo_pr_tree[0].slug);
    _ = try r.app.keyPress("shift+h");
    try t.expectEqualStrings("un-hid 1 repo(s)", r.app.status.items);
    try r.drain();
    try t.expectEqual(@as(usize, 2), r.app.tabs[0].data.repo_pr_tree.len);
    _ = try r.key("shift+h");
    try t.expectEqualStrings("nothing hidden", r.app.status.items);
    // recent → (explicit skipped: no list) → all → recent.
    _ = try r.app.keyPress("s");
    try t.expectEqualStrings("scope: all", r.app.status.items);
    try t.expectEqual(cfg.Scope.all, r.app.scope);
    try r.drain();
    _ = try r.app.keyPress("s");
    try t.expectEqualStrings("scope: recent", r.app.status.items);
    try r.drain();
    // alt+down on api moves it under web and writes the order.
    _ = try r.key("g");
    _ = try r.key("alt+down");
    try t.expectEqualStrings("web", r.app.tabs[0].data.repo_pr_tree[0].slug);
    try t.expectEqualStrings("web", r.app.order.items[0]);
    text = try Io.Dir.cwd().readFileAlloc(t.io, r.config_path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".repo_order") != null);
    // The cursor followed the repo.
    const rows = try r.rows();
    try t.expect(rows[r.app.tabs[0].selected] == .repo_header);
    try t.expectEqual(@as(usize, 1), rows[r.app.tabs[0].selected].repo_header.repo);
}

test "`--only` keeps one family; `--only prs-mine` synthesises a Mine tab; the strip shows only with two tabs" {
    const p = try Rig.init(acme, .{ .only = .pipelines });
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.app.tabs.len);
    try t.expect(!p.app.showTabStrip());
    const prs = try Rig.init(acme, .{ .only = .prs });
    defer prs.deinit();
    try t.expectEqual(@as(usize, 2), prs.app.tabs.len);
    try t.expect(prs.app.showTabStrip());
    const mine = try Rig.init(acme, .{ .only = .prs, .mine = true });
    defer mine.deinit();
    try t.expectEqual(@as(usize, 1), mine.app.tabs.len);
    try t.expectEqualStrings("Mine", mine.app.tabs[0].spec.name);
    try t.expect(mine.app.tabs[0].spec.mine_only);
    // Two repos with my PRs, one each; a merged peek would need a
    // stateless tab.
    try t.expectEqual(@as(usize, 2), mine.app.tabs[0].data.repo_pr_tree.len);
}

test "the filter narrows the rows and esc clears it; the statusline values land as a segment effect" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    _ = try r.key("/");
    try t.expectEqual(Mode.filter, r.app.mode);
    for ("empty") |c| _ = try r.key(&[_]u8{c});
    _ = try r.key("enter");
    try t.expectEqualStrings("empty", r.app.filter.items);
    // Headers stay; only web's #820 "Redesign the empty state" matches (#1198 is behind the footer anyway).
    var rows = try r.rows();
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expect(rows[3] == .show_more or rows[3] == .pr);
    _ = try r.key("esc");
    rows = try r.rows();
    try t.expectEqual(@as(usize, 5), rows.len);
    // The values chip: my two open PRs, one still unapproved.
    try t.expectEqual(@as(usize, 2), r.app.values.?.open_mine);
    try t.expectEqual(@as(usize, 1), r.app.values.?.unapproved_mine);
}

test "readiness is one cached look per open PR, and a blocked Merge says which condition fails" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nothing looked at: the button is dim and says exactly that,
    // rather than claiming a blocker nobody checked.
    const ts = r.app.activeTab();
    const pr = ts.data.repo_pr_tree[0].prs[0]; // acme/api#1234, OPEN
    try t.expectEqual(@as(i64, 1234), pr.id);
    var buf: [192]u8 = undefined;
    try t.expect(!r.app.readinessOf("api", pr).ready());
    try t.expectEqualStrings("Merge: not checked yet \u{2014} open the row to look", r.app.readinessOf("api", pr).hoverText(&buf));

    const before = r.srv.state.served;
    try r.app.ensureReadiness("api", pr);
    try r.drain();
    // The detail, the diffstat, the comments, the pipelines: one look,
    // and it is the only look this pull request costs until it moves.
    const spent = r.srv.state.served - before;
    try t.expect(spent > 0 and spent <= 4);
    try r.app.ensureReadiness("api", pr);
    try r.drain();
    try t.expectEqual(spent, r.srv.state.served - before);

    // #1234 has one task open and a FAILED deploy build, and Sam asked
    // for changes — the earliest unmet condition is the one named.
    const got = r.app.readinessOf("api", pr);
    try t.expect(got.checked);
    try t.expect(!got.ready());
    try t.expect(got.changes_requested);
    try t.expectEqualStrings("Merge: a reviewer asked for changes", got.hoverText(&buf));
    try t.expectEqual(@as(usize, 1), got.open_tasks);
    // It still applies cleanly: the diffstat came back 2xx.
    try t.expect(!got.conflicts);

    // A pull request that has moved is unchecked again — that is what
    // keying the look by `updated_on` is for.
    var moved = pr;
    moved.updated_on = "2099-01-01T00:00:00+00:00";
    try t.expect(!r.app.readinessOf("api", moved).checked);

    // #820 on web conflicts, and says so.
    const web = ts.data.repo_pr_tree[1].prs[0];
    try t.expectEqual(@as(i64, 820), web.id);
    try r.app.ensureReadiness("web", web);
    try r.drain();
    try t.expect(r.app.readinessOf("web", web).conflicts);

    // A press on a blocked button starts nothing and says why.
    try r.app.pressMerge("api", pr);
    try t.expect(r.app.merge_confirm == null);
    try t.expect(std.mem.indexOf(u8, r.app.status.items, "asked for changes") != null);
    try t.expectEqual(sdk.pane.ActionState.idle, r.app.actions.state("api#1234", "merge"));
    _ = a;
}

test "a ready PR opens a named confirm, and confirming dispatches a Claude Code session rather than merging" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    const ts = r.app.activeTab();
    const pr = ts.data.repo_pr_tree[0].prs[0];
    const merged_before = r.srv.state.merged_count;

    // Stand the readiness up as clean: what this asserts is what the
    // pane does once it IS ready, not the judgment itself.
    try r.app.putReadiness("api#1234", pr.updated_on, .{ .approvals = 1, .required = 1, .conflicts = false, .build_green = true, .checked = true });
    try t.expect(r.app.readinessOf("api", pr).ready());

    try r.app.pressMerge("api", pr);
    try t.expectEqual(Mode.confirm, r.app.mode);
    const c = r.app.merge_confirm.?;
    // Named: the title, the branches, the strategy.
    try t.expectEqualStrings("Fix the login redirect", c.confirm.title);
    try t.expectEqualStrings("chris/fix-login", c.confirm.source);
    try t.expectEqualStrings("main", c.confirm.target);
    try t.expectEqual(sdk.pane.merge.Strategy.merge_commit, c.confirm.strategy);
    // The strategy cycles through what the workspace allows.
    r.app.cycleMergeStrategy();
    try t.expectEqual(sdk.pane.merge.Strategy.squash, r.app.merge_confirm.?.confirm.strategy);

    try r.app.acceptMergeConfirm();
    try t.expectEqual(Mode.list, r.app.mode);
    // The button follows the session from here.
    try t.expectEqual(sdk.pane.ActionState.running, r.app.actions.state("api#1234", "merge"));
    // …and a watch went out under the button's own key.
    try t.expectEqual(@as(usize, 1), r.app.watch_out.items.len);
    var kbuf: [320]u8 = undefined;
    try t.expectEqualStrings(sdk.pane.actionWatchKey(&kbuf, "api#1234", "merge"), r.app.watch_out.items[0].key);

    const fx = r.app.takeEffects();
    defer r.app.freeEffects(fx);
    var dispatched: ?[]const u8 = null;
    for (fx) |e| switch (e) {
        .dispatch => |d| dispatched = d.prompt,
        else => {},
    };
    const prompt = dispatched orelse return error.NoDispatch;
    try t.expect(std.mem.indexOf(u8, prompt, "https://bitbucket.org/acme/api/pull-requests/1234") != null);
    try t.expect(std.mem.indexOf(u8, prompt, "merge_strategy: squash") != null);
    try t.expect(std.mem.indexOf(u8, prompt, "$BITBUCKET_ACCESS_TOKEN") != null);
    // THE POINT: the pane merged nothing. The fake server saw no write.
    try t.expectEqual(merged_before, r.srv.state.merged_count);
    try t.expect(!r.srv.state.last_auth_was_write);

    // The host's word moves the button, and an end while the pane does
    // not have the keyboard is worth telling the user about.
    r.app.focused = false;
    try r.app.onSessionState(sdk.pane.actionWatchKey(&kbuf, "api#1234", "merge"), .done, "sid-9", "merged acme/api/pull-requests/1234 as squash");
    try t.expectEqual(sdk.pane.ActionState.view, r.app.actions.state("api#1234", "merge"));
    const fx2 = r.app.takeEffects();
    defer r.app.freeEffects(fx2);
    var notified = false;
    for (fx2) |e| switch (e) {
        .notify => |n| {
            notified = true;
            try t.expect(std.mem.indexOf(u8, n.text, "api#1234") != null);
            try t.expect(!n.bad);
        },
        else => {},
    };
    try t.expect(notified);
    // …and so is the toast: a merge that lands takes its own row off
    // the open list, so the message about it is the LAST place that
    // pull request is named. The offer is the door back to it
    // (`wire.ToastAction`), and it is a url rather than a command
    // because the page is not mnml's to run.
    var offered = false;
    for (fx2) |e| switch (e) {
        .toast => |x| if (x.action) |act| {
            offered = true;
            try t.expectEqualStrings("Open PR", act.label);
            try t.expectEqualStrings("https://bitbucket.org/acme/api/pull-requests/1234", act.url);
            try t.expectEqualStrings("", act.command);
            try t.expect(act.isValid());
        },
        else => {},
    };
    try t.expect(offered);

    // Focused, the same edge is not worth a notification: the reader
    // is looking at it.
    r.app.focused = true;
    try r.app.onSessionState(sdk.pane.actionWatchKey(&kbuf, "api#1234", "merge"), .failed, "sid-9", "refused: it conflicts");
    const fx3 = r.app.takeEffects();
    defer r.app.freeEffects(fx3);
    for (fx3) |e| try t.expect(e != .notify);
    try t.expectEqual(sdk.pane.ActionState.failed, r.app.actions.state("api#1234", "merge"));
}

test "the awaiting chip counts and filters what is waiting on MY review, off the rows already loaded" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    // #1198 (Dana's, me a reviewer, no vote) is the one waiting on me;
    // my own two are not, and #1234's reviewers are other people.
    try t.expectEqual(@as(usize, 1), r.app.awaitingCount());

    const served = r.srv.state.served;
    _ = try r.key("esc"); // nothing open; just a keystroke that changes nothing
    try r.app.toggleAwaiting();
    try t.expect(r.app.awaiting_only);
    // The filter narrows rows that are already there: not one request.
    try t.expectEqual(@as(u32, 0), r.srv.state.served - served);
    var rows = try r.rows();
    var prs: usize = 0;
    for (rows) |row| prs += @intFromBool(row == .pr);
    try t.expectEqual(@as(usize, 1), prs);
    for (rows) |row| if (row == .pr) {
        const pr = r.app.activeTab().data.repo_pr_tree[row.pr.repo].prs[row.pr.idx];
        try t.expectEqual(@as(i64, 1198), pr.id);
    };
    // …and nothing is hidden behind a fold row that the chip is
    // deliberately keeping out.
    for (rows) |row| try t.expect(row != .show_more);

    try r.app.toggleAwaiting();
    try t.expect(!r.app.awaiting_only);
    rows = try r.rows();
    prs = 0;
    for (rows) |row| prs += @intFromBool(row == .pr);
    try t.expect(prs > 1);

    // The statusline's third figure is the same question, counted out
    // of the same listing the other two come from.
    try t.expectEqual(@as(usize, 1), r.app.values.?.reviews_pending);
    try t.expectEqual(@as(usize, 2), r.app.values.?.open_mine);
    // And each figure's tooltip names what is behind it.
    try t.expectEqual(@as(usize, 2), r.app.values.?.open_items.len);
    try t.expectEqual(@as(usize, 1), r.app.values.?.awaiting_items.len);
    try t.expectEqualStrings("Bump the client timeout to 30s", r.app.values.?.awaiting_items[0].text);
    // The row says where it lives — a title with no repo behind it
    // still sends the reader into the pane to find out which one.
    try t.expectEqualStrings("acme/api", r.app.values.?.awaiting_items[0].sub);
}

/// The scribbling allocator lives in the SDK now, so a third
/// integration inherits it rather than copying it: `sdk.testing`.
const Scribble = sdk.testing.Scribble;

test "the chip keeps its own copy of the rows: nothing it lists points into a finished listing" {
    var scribble: Scribble = .{ .child = t.allocator };
    // Every HTTP body, every job arena and every result arena on an
    // allocator that poisons what it frees.
    const r = try Rig.initOn(acme, .{}, scribble.allocator());
    defer r.deinit();

    // The listings are over: each repo's response body went back to the
    // allocator inside `values`, and the job that carried the figure has
    // been committed. Everything either of those lent out is 0xAA now.
    const v = r.app.values.?;
    try t.expectEqual(@as(usize, 2), v.open_items.len);
    try t.expectEqualStrings("Fix the login redirect", v.open_items[0].text);
    try t.expectEqualStrings("acme/api · approved", v.open_items[0].sub);
    try t.expectEqualStrings("api#1234", v.open_items[0].key);
    try t.expectEqualStrings("Redesign the empty state", v.open_items[1].text);
    try t.expectEqualStrings("Bump the client timeout to 30s", v.awaiting_items[0].text);

    // And the chip republishes the SAME rows the pane opens one of —
    // the `.segment` effect reads this figure minutes after it landed,
    // which is the moment the reader is certainly looking at it.
    try r.app.requestValues();
    try r.drain();
    try t.expectEqualStrings("Fix the login redirect", r.app.values.?.open_items[0].text);
}

test "a click selects the row it lands on, a right-click opens its menu, the author chip toggles mine-only" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    // The hit map is the painter's; stand in for one frame here.
    r.app.hits.reset();
    r.app.hits.add(.{ .x = 0, .y = 4, .w = 120, .h = 1 }, .{ .row = 0 });
    r.app.hits.add(.{ .x = 0, .y = 5, .w = 120, .h = 1 }, .{ .row = 1 });
    r.app.hits.add(.{ .x = 0, .y = 6, .w = 120, .h = 1 }, .{ .row = 2 });
    r.app.hits.add(.{ .x = 100, .y = 0, .w = 12, .h = 1 }, .{ .chip = .author });
    r.app.hits.add(.{ .x = 30, .y = 1, .w = 10, .h = 1 }, .{ .tab = 1 });
    _ = try r.app.click(5, 5, .left);
    try t.expectEqual(@as(usize, 1), r.app.tabs[0].selected);
    // A click on the repo header toggles it, as the reference does.
    _ = try r.app.click(5, 4, .left);
    try t.expect(!r.app.tabs[0].expanded.hasRepo("api"));
    _ = try r.app.click(5, 4, .left);
    try t.expect(r.app.tabs[0].expanded.hasRepo("api"));
    _ = try r.app.click(5, 5, .right);
    try t.expectEqual(Mode.menu, r.app.mode);
    try t.expectEqual(Action.toggle_detail, r.app.menu.?.items[0]);
    _ = try r.key("esc");
    try t.expectEqual(Mode.list, r.app.mode);
    _ = try r.app.click(35, 1, .left);
    try t.expectEqual(@as(usize, 1), r.app.active);
    _ = try r.app.click(31, 1, .left);
    _ = try r.app.click(105, 0, .left);
    try t.expectEqualStrings("Merged: filter → Authored by me", r.app.status.items);
    try r.drain();
    try t.expect(r.app.tabs[1].spec.mine_only);
    _ = try r.app.click(105, 0, .left);
    try r.drain();
    try t.expect(!r.app.tabs[1].spec.mine_only);
}

const server = @import("../tools/fake_bitbucket/server.zig");

test "the pane opens on the tab somebody is looking at; the rest are warmed behind the paint" {
    var app = try App.init(t.allocator, t.io, .{ .workspace = "acme", .account_id = "acct-chris", .tabs = &.{
        .{ .name = "Open + Draft", .kind = .workspace_open_prs },
        .{ .name = "Merged", .kind = .workspace_merged_prs },
        .{ .name = "Pipelines", .kind = .workspace_pipelines },
    } }, "/nowhere/config.zon", .{});
    defer app.deinit();
    try app.startup();
    const jobs = app.takeJobs();
    defer {
        for (jobs) |*j| {
            var job = j.*;
            job.deinit();
        }
        t.allocator.free(jobs);
    }
    // One `pane_open` — the tab on screen — and the other two behind
    // it as `warm`, which is what makes them give way to a click.
    var pane_open: usize = 0;
    var warm: usize = 0;
    for (jobs) |j| switch (j.reasonOf()) {
        .pane_open => pane_open += 1,
        .warm => warm += 1,
        else => {},
    };
    try t.expectEqual(@as(usize, 1), pane_open);
    try t.expectEqual(@as(usize, 2), warm);
}

test "a pane that does not hold the machine's warm lock fetches only its own tab" {
    var app = try App.init(t.allocator, t.io, .{ .workspace = "acme", .account_id = "acct-chris", .tabs = &.{
        .{ .name = "Open + Draft", .kind = .workspace_open_prs },
        .{ .name = "Merged", .kind = .workspace_merged_prs },
        .{ .name = "Pipelines", .kind = .workspace_pipelines },
    } }, "/nowhere/config.zon", .{});
    defer app.deinit();
    // Another process is already warming this service's cache. Warming
    // it a second time is the same answer at twice the price.
    app.may_warm = false;
    try app.startup();
    const jobs = app.takeJobs();
    defer {
        for (jobs) |*j| {
            var job = j.*;
            job.deinit();
        }
        t.allocator.free(jobs);
    }
    var refreshes: usize = 0;
    for (jobs) |j| switch (j.kind) {
        .refresh => refreshes += 1,
        else => {},
    };
    try t.expectEqual(@as(usize, 1), refreshes);
}
