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
const filters = @import("filters.zig");
const state_mod = @import("state.zig");

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

pub const Mode = enum { list, filter, help, menu, confirm, picker };

/// The toolbar's chips — one per filter of the two families.
pub const FilterKind = enum {
    status,
    author,
    target,
    show,
    run_by,
    branch,
    ptype,
    pstatus,
    trigger,

    /// The chip's key word, as it paints: ` status: Open + Draft `.
    pub fn word(k: FilterKind) []const u8 {
        return switch (k) {
            .status, .pstatus => "status",
            .author => "author",
            .target => "target",
            .show => "show",
            .run_by => "run by",
            .branch => "branch",
            .ptype => "type",
            .trigger => "trigger",
        };
    }

    /// The Status chip picks several; every other chip picks one.
    pub fn multi(k: FilterKind) bool {
        return k == .status;
    }

    pub fn family(k: FilterKind) cfg.Family {
        return switch (k) {
            .status, .author, .target, .show => .prs,
            .run_by, .branch, .ptype, .pstatus, .trigger => .pipelines,
        };
    }
};

/// One row of a chip's picker (and of its right-click menu): the value
/// as the reader sees it, whether it is on now. Row 0 is the clearing
/// row on every single-select chip (`all` / `any`).
pub const PickItem = struct { label: []const u8, checked: bool = false };

/// A chip's picker, up over the list: the rows the loaded set offers,
/// a typed filter over them, the cursor. The Status picker toggles a
/// row with Space and commits with Enter; the rest commit the row
/// under the cursor.
pub const Picker = struct {
    kind: FilterKind,
    /// Owns `items` and their labels.
    arena: std.heap.ArenaAllocator,
    items: []PickItem = &.{},
    selected: usize = 0,
    query: std.ArrayList(u8) = .empty,

    pub fn deinit(p: *Picker, gpa: Allocator) void {
        p.query.deinit(gpa);
        p.arena.deinit();
        p.* = undefined;
    }

    /// The rows the typed filter keeps, as indices into `items`.
    pub fn visible(p: *const Picker, a: Allocator) Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        for (p.items, 0..) |it, i| {
            if (p.query.items.len == 0 or std.ascii.indexOfIgnoreCase(it.label, p.query.items) != null) try out.append(a, i);
        }
        return out.toOwnedSlice(a);
    }

    /// Move the cursor by `delta` over the visible rows.
    pub fn move(p: *Picker, a: Allocator, delta: isize) Allocator.Error!void {
        const vis = try p.visible(a);
        if (vis.len == 0) return;
        var pos: usize = 0;
        for (vis, 0..) |i, k| if (i == p.selected) {
            pos = k;
        };
        const next = std.math.clamp(@as(isize, @intCast(pos)) + delta, 0, @as(isize, @intCast(vis.len)) - 1);
        p.selected = vis[@intCast(next)];
    }
};

/// A row of a right-click menu: an action of the keymap, or one value
/// of a chip.
pub const MenuItem = union(enum) {
    action: Action,
    pick: struct { kind: FilterKind, idx: usize },
    /// A page that is about to open in the browser, asked first: the
    /// words, and the URL (both on the menu's arena).
    open_url: struct { label: []const u8, url: []const u8 },
    /// Close the menu, do nothing.
    cancel,
};

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

/// What `carryFailedRepos` hands back: the tree to show, the PR count
/// when it changed, and the header's reason ("" when nothing failed).
const Carried = struct { data: tabs.TabData, items: ?usize = null, why: []const u8 = "" };

/// A refetch of a repo tree where some repos failed: each failed repo
/// that had rows last time gets them back (copied onto `a`, the new
/// result's arena), its error label dropped — the failure is said once,
/// in the header, rather than clipped into a STATE cell. A repo that
/// never answered keeps its error row. `why_buf` backs `why`.
/// What the hint row says while the shared bucket file is refusing.
pub const bucket_wait_text = "waiting on the shared rate-limit bucket — this round was skipped, nothing was sent";

/// Is a pull request in `state` one a listing fetched with `loaded`
/// holds?
fn stateLoaded(loaded: filters.ApiStates, state: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(state, "OPEN")) return loaded.open;
    if (std.ascii.eqlIgnoreCase(state, "MERGED")) return loaded.merged;
    if (std.ascii.eqlIgnoreCase(state, "DECLINED") or std.ascii.eqlIgnoreCase(state, "SUPERSEDED")) return loaded.declined;
    return false;
}

/// Put `pr` where the listing has it — same repo, same id — when its
/// state still belongs to the listing. False: it is not there, or no
/// longer belongs, and the caller asks for the listing instead. The
/// rows live on arenas this app owns, so writing one in place is
/// writing its own memory.
pub fn patchPr(ts: *TabState, repo: []const u8, pr: model.PullRequest) bool {
    if (!stateLoaded(ts.loaded_states, pr.state)) return false;
    switch (ts.data) {
        .repo_pr_tree => |repos| for (repos) |r| {
            if (!std.mem.eql(u8, r.slug, repo)) continue;
            for (r.prs, 0..) |old, i| if (old.id == pr.id) {
                @constCast(r.prs)[i] = pr;
                return true;
            };
        },
        .pull_requests => |prs| for (prs, 0..) |old, i| {
            if (old.id != pr.id or !std.mem.eql(u8, old.repoSlug(), repo)) continue;
            @constCast(prs)[i] = pr;
            return true;
        },
        else => {},
    }
    return false;
}

fn carryFailedRepos(a: Allocator, old: tabs.TabData, fresh: tabs.TabData, why_buf: []u8) Allocator.Error!Carried {
    switch (fresh) {
        .repo_pr_tree => |rows| {
            const prev: []const model.RepoPrs = if (old == .repo_pr_tree) old.repo_pr_tree else &.{};
            var failed: usize = 0;
            var first: model.RepoPrs = .{ .slug = "" };
            for (rows) |r| if (r.error_label.len > 0) {
                if (failed == 0) first = r;
                failed += 1;
            };
            if (failed == 0) return .{ .data = fresh };
            const out = try a.alloc(model.RepoPrs, rows.len);
            var items: usize = 0;
            for (rows, out) |r, *o| {
                o.* = r;
                if (r.error_label.len > 0) for (prev) |pr| if (pr.error_label.len == 0 and std.mem.eql(u8, pr.slug, r.slug)) {
                    o.* = try sdk.pane.work.dupeDeep(model.RepoPrs, a, pr);
                    break;
                };
                items += o.prs.len;
            }
            return .{ .data = .{ .repo_pr_tree = out }, .items = items, .why = sdk.pane.work.partialFailureText(why_buf, failed, rows.len, "repos", first.slug, first.error_label) };
        },
        .repo_tree => |rows| {
            const prev: []const model.RepoPipelines = if (old == .repo_tree) old.repo_tree else &.{};
            var failed: usize = 0;
            var first: model.RepoPipelines = .{ .slug = "" };
            for (rows) |r| if (r.error_label.len > 0) {
                if (failed == 0) first = r;
                failed += 1;
            };
            if (failed == 0) return .{ .data = fresh };
            const out = try a.alloc(model.RepoPipelines, rows.len);
            for (rows, out) |r, *o| {
                o.* = r;
                if (r.error_label.len > 0) for (prev) |pr| if (pr.error_label.len == 0 and std.mem.eql(u8, pr.slug, r.slug)) {
                    o.* = try sdk.pane.work.dupeDeep(model.RepoPipelines, a, pr);
                    break;
                };
            }
            return .{ .data = .{ .repo_tree = out }, .why = sdk.pane.work.partialFailureText(why_buf, failed, rows.len, "repos", first.slug, first.error_label) };
        },
        else => return .{ .data = fresh },
    }
}

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
    /// The toolbar's chips for this tab. Its strings are owned
    /// (`setFilterText`); the struct is copied into a `VisibleCtx`
    /// every frame, which borrows them.
    filters: filters.Filters = .{},
    /// The API states the rows on screen were fetched with — what a
    /// Status change is compared against to decide whether it costs a
    /// fetch (`ApiStates.covers`).
    loaded_states: filters.ApiStates = .{},
    /// The last listing's digest (`fetch.RefreshResult.digest`): the
    /// next one matching it is a poll that found nothing new.
    digest: ?u64 = null,
    /// Arenas holding pull requests an event feed replaced in place;
    /// they go when the data they were patched into does.
    patches: std.ArrayListUnmanaged(std.heap.ArenaAllocator) = .empty,

    fn dropPatches(ts: *TabState, gpa: Allocator) void {
        for (ts.patches.items) |*a| a.deinit();
        ts.patches.clearAndFree(gpa);
    }

    fn deinit(ts: *TabState, gpa: Allocator) void {
        ts.dropPatches(gpa);
        if (ts.data_arena) |*a| a.deinit();
        ts.expanded.deinit();
        gpa.free(ts.error_text);
        gpa.free(ts.status);
        ts.freeFilterTexts(gpa);
        ts.* = undefined;
    }

    fn freeFilterTexts(ts: *TabState, gpa: Allocator) void {
        if (ts.filters.author == .named) gpa.free(ts.filters.author.named);
        gpa.free(ts.filters.target);
        gpa.free(ts.filters.run_by);
        gpa.free(ts.filters.branch);
        gpa.free(ts.filters.ptype);
        gpa.free(ts.filters.pstatus);
        gpa.free(ts.filters.trigger);
    }

    /// Take `f` as this tab's filters, copying every string it borrows.
    fn adoptFilters(ts: *TabState, gpa: Allocator, f: filters.Filters) Allocator.Error!void {
        var owned = f;
        owned.author = switch (f.author) {
            .named => |n| .{ .named = try gpa.dupe(u8, n) },
            else => f.author,
        };
        owned.target = try gpa.dupe(u8, f.target);
        owned.run_by = try gpa.dupe(u8, f.run_by);
        owned.branch = try gpa.dupe(u8, f.branch);
        owned.ptype = try gpa.dupe(u8, f.ptype);
        owned.pstatus = try gpa.dupe(u8, f.pstatus);
        owned.trigger = try gpa.dupe(u8, f.trigger);
        ts.freeFilterTexts(gpa);
        ts.filters = owned;
    }

    pub fn setText(gpa: Allocator, slot: *[]u8, text: []const u8) Allocator.Error!void {
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

/// A right-click menu over a row (the actions that apply to it) or over
/// a chip (every value it can take, the live one ticked).
pub const Menu = struct {
    /// The row the menu is about; unused by a chip's menu.
    row: usize = 0,
    col: u16,
    y: u16,
    items: []const MenuItem,
    selected: usize = 0,
    /// A chip's menu carries the values its rows name, for the paint.
    values: []const PickItem = &.{},
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
    /// The open menu's rows live here: a row menu's actions, a chip
    /// menu's values. Reset when a menu opens.
    menu_arena: std.heap.ArenaAllocator,
    /// A chip's picker, while one is up.
    picker: ?Picker = null,
    help_scroll: usize = 0,
    /// The wall clock in milliseconds, for the spinner's frame. Set by
    /// the loop before every paint; 0 in a test, which is frame 0.
    now_ms: i64 = 0,
    /// The transient line the hint row shows on the left, owned.
    status: std.ArrayList(u8) = .empty,
    /// Where a wait long enough for a person to notice is left by the
    /// worker thread. `noteWait` turns it into the one line that keeps
    /// `loading…` from being silent.
    wait_notice: ratelimit.Notice = .{},
    /// The API budget (`mnml_sdk.budget`): the client writes it on
    /// every request, the header's budget chip and its hover read it.
    /// `main` configures it and points the client at it; unconfigured
    /// (a test) it paints `0/h` and never pauses.
    budget: sdk.Budget = .{},
    effects: std.ArrayList(Effect) = .empty,
    effect_arena: std.heap.ArenaAllocator,
    jobs: std.ArrayList(fetch.Job) = .empty,
    /// The frame's scratch: visible rows, formatted text.
    frame_arena: std.heap.ArenaAllocator,
    hits: hit.HitMap,
    last_refresh_secs: i64 = 0,
    /// When to ask again, and what an event feed says changed
    /// (`sdk.feed`): the adaptive poller, and the JSONL file when one
    /// is configured. `main` builds it from the config; the default
    /// polls never, which is what a test gets.
    watch: sdk.feed.Watcher = .{ .poll = .init(0, 0) },
    /// Pull requests fetched one at a time because the feed named them.
    feed_fetches: u32 = 0,
    /// Those fetches still out, keyed `ws/repo#id`: a pull request the
    /// feed names again (or names another way — `api#12` and
    /// `acme/api#12` are one) before its answer lands is not asked for
    /// twice.
    feed_in_flight: std.StringHashMapUnmanaged(void) = .empty,
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
            .focus_key_len = @min(focus.len, 256),
            .tabs = &.{},
            .only = opts.only,
            .effect_arena = std.heap.ArenaAllocator.init(gpa),
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .menu_arena = std.heap.ArenaAllocator.init(gpa),
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
        try app.loadFilterState(opts);
        return app;
    }

    fn newTab(gpa: Allocator, spec: tabs.TabSpec) TabState {
        return .{
            .spec = spec,
            .data = tabs.TabData.emptyFor(spec.kind),
            .expanded = tabs.Expanded.init(gpa),
            .filters = filters.Filters.defaultFor(spec.kind, spec.state, spec.mine_only),
            .loaded_states = spec.apiStates(),
        };
    }

    /// `<config dir>/state.zon`: what the toolbar's chips were set to
    /// last time, per tab by name. Applied over the kinds' defaults;
    /// `--only prs-mine` / `prs-awaiting` then set what they asked for
    /// on top, since a launch flag is an ask made now.
    fn loadFilterState(app: *App, opts: Options) Allocator.Error!void {
        const gpa = app.gpa;
        const path = try state_mod.pathBeside(gpa, app.config_path);
        defer gpa.free(path);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const saved = state_mod.load(arena.allocator(), app.io, path);
        for (app.tabs) |*ts| {
            var f = ts.filters;
            if (saved.entryFor(ts.spec.name)) |e| {
                f = e.toFilters();
                // A per-tab file cannot turn a kind into another: a
                // saved Merged on a pipelines tab is noise.
                if (ts.spec.kind.family() != .prs) f.status = ts.filters.status;
            }
            if (opts.mine) f.author = .me;
            if (opts.awaiting and ts.spec.kind.family() == .prs) f.show = .awaiting;
            try ts.adoptFilters(gpa, f);
            ts.spec.mine_only = f.author == .me and ts.spec.kind.isWorkspaceWide();
            ts.spec.states = f.status.apiStates();
            ts.loaded_states = f.status.apiStates();
        }
    }

    /// Write every tab's chips to `state.zon`. Best effort, said once.
    fn persistFilters(app: *App) void {
        const gpa = app.gpa;
        const path = state_mod.pathBeside(gpa, app.config_path) catch return;
        defer gpa.free(path);
        const entries = gpa.alloc(state_mod.Entry, app.tabs.len) catch return;
        defer gpa.free(entries);
        for (app.tabs, entries) |*ts, *e| e.* = state_mod.Entry.fromFilters(ts.spec.name, ts.filters);
        state_mod.save(gpa, app.io, path, .{ .tabs = entries }) catch {
            app.say(.err, "could not write {s}", .{path});
        };
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        var ffit = app.feed_in_flight.keyIterator();
        while (ffit.next()) |k| gpa.free(k.*);
        app.feed_in_flight.deinit(gpa);
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
        if (app.picker) |*p| p.deinit(gpa);
        app.menu_arena.deinit();
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
        app.watch.started(app.now_secs * 1000);
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

    /// `Ctrl+X`, or a click on the budget chip: stop waiting out a
    /// 429's pause. With no pause running the click says the budget's
    /// figures on the hint row instead, so it is never a dead click.
    pub fn cancelWait(app: *App) void {
        if (app.budget.cancelWait()) {
            app.say(.info, "stopped waiting out the rate limit — the next request goes when you ask", .{});
            return;
        }
        const s = app.budget.snapshot(app.now_secs);
        var buf: [48]u8 = undefined;
        app.setStatus("API budget {s} · today {d} · yesterday {d} · 7 days {d}", .{ s.chipWords(&buf), s.today, s.yesterday, s.week });
    }

    /// `Shift+N`: dry run on / off for this session.
    pub fn toggleDryRun(app: *App) void {
        if (app.budget.toggleDry()) {
            app.say(.info, "dry run on — nothing is sent; the pane shows what it already holds", .{});
        } else app.say(.info, "dry run off — requests go out again", .{});
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
        // The poller and the event feed (`sdk.feed`). Nothing is asked
        // while the tab is already loading: the feed's lines stay in its
        // file until the pane can act on them.
        const now_ms = now_secs * 1000;
        if (!app.activeTab().loading) {
            _ = app.frame_arena.reset(.retain_capacity);
            const look = try app.watch.look(app.frame_arena.allocator(), now_ms);
            if (look.sweep) {
                try app.refreshTabMode(app.active, false);
                app.last_refresh_secs = now_secs;
                app.watch.started(now_ms);
            } else if (look.changed.len > 0) {
                try app.feedChanged(look.changed);
            }
        }
        app.budget.setFeed(app.watch.state(now_ms));
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
        const builds = try app.buildsFor(a, ts);
        // `M` of the header's `N of M` is what the tab would show with
        // its chips on their defaults: a chip is a narrowing like the
        // `/` query, and the count owes the reader the same honesty.
        if (app.chipsNarrowed()) {
            const whole = try tabs.visibleRows(a, .{
                .spec = ts.spec,
                .data = ts.data,
                .expanded = &ts.expanded,
                .show_all = ts.show_all,
                .now_secs = app.now_secs,
                .builds = builds,
                .filters = filters.Filters.defaultFor(ts.spec.kind, ts.spec.state, ts.spec.mine_only),
                .me = app.meId(),
            });
            app.filter_total = countContent(whole.rows);
        }
        const all = try tabs.visibleRows(a, .{
            .spec = ts.spec,
            .data = ts.data,
            .expanded = &ts.expanded,
            .show_all = ts.show_all,
            .now_secs = app.now_secs,
            .builds = builds,
            .filters = ts.filters,
            .me = app.meId(),
        });
        if (!app.chipsNarrowed()) app.filter_total = countContent(all.rows);
        if (app.filter.items.len == 0) {
            app.filter_shown = countContent(all.rows);
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

    /// True while the `/` query or a chip is hiding something — what
    /// the header's `N of M` and the hint row's context both key off.
    pub fn narrowed(app: *App) bool {
        return app.filter.items.len > 0 or app.chipsNarrowed();
    }

    /// Is any chip of the active tab off its kind's default?
    pub fn chipsNarrowed(app: *App) bool {
        const ts = app.activeTab();
        return switch (ts.spec.kind.family()) {
            .prs => ts.filters.prNarrowedFrom(filters.Filters.defaultFor(ts.spec.kind, ts.spec.state, ts.spec.mine_only)),
            .pipelines => ts.filters.pipelinesNarrowed(),
            .branches => false,
        };
    }

    /// Is any tab's fetch in flight? The loop animates the spinner
    /// while one is.
    pub fn anyLoading(app: *const App) bool {
        for (app.tabs) |*ts| if (ts.loading) return true;
        return false;
    }

    /// What the active tab's fetch is doing, for the header: the live
    /// phase the worker left in `wait_notice` while a request is out —
    /// queued behind N on the broker, waiting on the file bucket, on
    /// the wire — the repo count of a first load, the reason the last
    /// one failed, or nothing.
    pub fn fetchState(app: *App) sdk.pane.chrome.Fetch {
        const ts = app.activeTab();
        if (ts.loading) {
            const live = app.wait_notice.live();
            return switch (live.phase) {
                .queued => .{ .queued = live.behind },
                .waiting => .waiting,
                .idle, .sending => .{ .fetching = .{ .done = if (ts.fetched) 0 else app.progressDone(), .total = if (ts.fetched) 0 else app.progressTotal() } },
            };
        }
        if (ts.error_text.len > 0) return .{ .failed = ts.error_text };
        return .idle;
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
        return .{ .on_tree = ts.spec.isTree(), .on_row = on_row, .detail_open = app.detail_visible, .family = ts.spec.kind.family() };
    }

    // ─── input ───────────────────────────────────────────────────────

    /// One key from mnml. False means the pane is done.
    pub fn keyPress(app: *App, spec: []const u8) Allocator.Error!bool {
        app.touched();
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
                // The family's one sheet grammar (`sdk.pane.keysheet.key`):
                // Esc / ? / q close, j / k and the page keys scroll, and
                // any other key is ignored rather than closing the sheet.
                if (sdk.pane.keysheet.scroll(&app.help_scroll, sdk.pane.keysheet.key(spec))) {
                    app.mode = .list;
                    app.help_scroll = 0;
                }
                return true;
            },
            .menu => return app.menuKey(a, spec),
            .picker => return app.pickerKey(a, spec),
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
            .cycle_show => try app.cycleShow(),
            .filter_status => try app.openPicker(.status),
            .filter_author => try app.openPicker(.author),
            .filter_target => try app.openPicker(.target),
            .filter_run_by => try app.openPicker(.run_by),
            .filter_branch => try app.openPicker(.branch),
            .filter_type => try app.openPicker(.ptype),
            .filter_pstatus => try app.openPicker(.pstatus),
            .filter_trigger => try app.openPicker(.trigger),
            .merge_pr => if (app.focusedPr(rows)) |f| try app.pressMerge(f.slug, f.pr),
            .filter => {
                app.mode = .filter;
                app.filter_caret = app.filter.items.len;
            },
            .help => app.mode = .help,
            .cancel_wait => app.cancelWait(),
            .toggle_dry_run => app.toggleDryRun(),
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

    /// What the element under the pointer is and does — for the host's
    /// info view (`Mount.hover`). The toolkit's chrome reads the same as
    /// in every pane (`sdk.pane.help.common`); the forge's own chips and
    /// pages say their own words. `buf` backs a title that names a key.
    pub fn helpAt(app: *App, col: u16, row: u16, buf: []u8) sdk.pane.help.Help {
        const H = sdk.pane.help;
        const target = app.hits.at(col, row) orelse return .{ .title = "" };
        return switch (target) {
            .tab => H.common(.tab),
            .chip => |c| switch (c) {
                .refresh => H.common(.refresh),
                .help => H.common(.keys_chip),
                .filter => H.common(.filter),
                .status => .{ .title = "status:", .body = "Which pull requests show — Open, Draft, Merged, Declined; pick several. Right-click lists them with the live ones ticked. Key: S." },
                .author => .{ .title = "author:", .body = "Whose pull requests show — everyone, me, or one person seen on the tab. Key: U." },
                .target => .{ .title = "target:", .body = "Only the pull requests into one branch. Key: T." },
                .show => .{ .title = "show:", .body = "all → reviewing (I am a reviewer) → awaiting me (my review is still due). A click cycles; nothing is fetched. Key: A." },
                .run_by => .{ .title = "run by:", .body = "Only the pipelines one person started. Key: U." },
                .branch => .{ .title = "branch:", .body = "Only one branch's pipelines. Key: B." },
                .ptype => .{ .title = "type:", .body = "Which kind of pipeline — branch, pull request, custom, tag. Key: P." },
                .pstatus => .{ .title = "status:", .body = "Which results show — successful, failed, in progress, stopped. Key: S." },
                .trigger => .{ .title = "trigger:", .body = "How a run was started — a push, a schedule, by hand. Key: T." },
                .run_pipeline => .{ .title = "run pipeline", .body = "Opens the pipelines page of the repo under the cursor, where a run is started, in the browser." },
                .schedules => .{ .title = "schedules", .body = "Opens the pipeline schedules of the repo under the cursor in the browser." },
                .caches => .{ .title = "caches", .body = "Opens the pipeline caches of the repo under the cursor in the browser." },
                .usage => .{ .title = "usage", .body = "The workspace's pipeline-minutes page. Asks before it opens the browser." },
                .budget => H.budget(buf, app.budget.snapshot(app.now_secs)),
            },
            .row => H.common(if (app.activeTab().spec.isTree()) .tree_row else .list_row),
            .build_line => H.common(.build_line),
            .chevron => H.common(.chevron),
            .pr_button => |b| switch (b.which) {
                .open => H.common(.open_button),
                .merge => H.common(.merge_button),
            },
            .merge_blocked => .{ .title = H.common(.merge_blocked).title, .body = if (app.hover_len > 0) app.hoverNote() else H.common(.merge_blocked).body },
            .confirm_ok => H.common(.confirm_ok),
            .confirm_cancel => H.common(.confirm_cancel),
            .confirm_body => .{ .title = "Merge confirm", .body = "The pull request, its source and target, and the strategy. Enter merges through Claude Code; Esc cancels." },
            .hint, .sheet_row => |which| blk: {
                const b = keymap.bindingOf(which) orelse break :blk H.common(.key_sheet);
                break :blk H.key(buf, keymap.keyLabel(b.keys[0]), b.title);
            },
            .menu_item => H.common(.menu_item),
            .picker_row, .picker_body => H.common(.picker_row),
            .detail => H.common(.detail),
            .detail_close => H.common(.detail_close),
            .detail_bar => H.common(.scrollbar),
            .sheet => H.common(.key_sheet),
        };
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
        // A refresh somebody asked for is a poll, and a sign somebody
        // is looking: the poller starts over from its base.
        app.watch.touch();
        app.watch.started(app.now_secs * 1000);
    }

    /// The reader did something — a key, a click, the wheel, a paste,
    /// the pane taking focus: the poller comes back to its base.
    pub fn touched(app: *App) void {
        app.watch.touch();
    }

    /// The pull requests an event feed named. On the tab on screen,
    /// each is asked for once, alone, and its row replaced in place.
    pub fn feedChanged(app: *App, changes: []const sdk.feed.Change) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.spec.kind.family() != .prs) return;
        for (changes) |c| {
            const key = parseFeedKey(c.key, ts.spec.workspace, app.config.workspace) orelse continue;
            // The detail the reader may have open for it is stale now.
            var kb: [256]u8 = undefined;
            const kt = keyText(&kb, key);
            if (app.feed_in_flight.contains(kt)) continue;
            if (app.details.fetchRemove(kt)) |kv| {
                app.gpa.free(kv.key);
                kv.value.arena.deinit();
                app.gpa.destroy(kv.value);
            }
            try app.feed_in_flight.put(app.gpa, try app.gpa.dupe(u8, kt), {});
            try app.enqueueFor(.{ .pr_changed = .{ .tab = app.active, .key = key } }, .delta);
            app.feed_fetches += 1;
        }
    }

    /// `api#12` or `acme/api#12`, as a pull request's key. The workspace
    /// is the tab's, else the config's, when the line names none.
    pub fn parseFeedKey(key: []const u8, tab_workspace: []const u8, default_workspace: []const u8) ?fetch.PrKey {
        const hash = std.mem.lastIndexOfScalar(u8, key, '#') orelse return null;
        const id = std.fmt.parseInt(i64, key[hash + 1 ..], 10) catch return null;
        if (id <= 0) return null;
        const left = key[0..hash];
        const slash = std.mem.lastIndexOfScalar(u8, left, '/');
        const repo = if (slash) |i| left[i + 1 ..] else left;
        const ws = if (slash) |i| left[0..i] else if (tab_workspace.len > 0) tab_workspace else default_workspace;
        if (repo.len == 0 or ws.len == 0) return null;
        return .{ .workspace = ws, .repo = repo, .id = id };
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

    // ─── the toolbar's chips ─────────────────────────────────────────

    /// The `show:` chip: all → reviewing → awaiting me → all. It
    /// narrows rows that are already loaded (`participants` come with
    /// the listing), so there is nothing to refetch and nothing to pay.
    pub fn cycleShow(app: *App) Allocator.Error!void {
        const ts = app.activeTab();
        try app.setShow(ts.filters.show.next());
    }

    pub fn setShow(app: *App, want: filters.Show) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.spec.kind.family() != .prs) {
            app.say(.warn, "show: is a pull-request filter", .{});
            return;
        }
        if (want != .all and app.meId().len == 0) {
            app.say(.warn, "no account to match reviewers against — set `account_id` in config.zon", .{});
            return;
        }
        ts.filters.show = want;
        ts.selected = 0;
        ts.scroll = 0;
        app.persistFilters();
        app.say(.info, "{s}: {s}", .{ ts.spec.name, want.sentence() });
    }

    /// The `status:` chip's set. Client-side over the loaded rows
    /// unless it names an API state the listing was not fetched with
    /// (Merged on an open listing, say) — then ONE refetch, through the
    /// ordinary refresh path, with the states joined in one request.
    pub fn setStatusSet(app: *App, want: filters.PrStatus) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.spec.kind.family() != .prs) return;
        ts.filters.status = want;
        ts.selected = 0;
        ts.scroll = 0;
        app.persistFilters();
        var buf: [64]u8 = undefined;
        const wanted = want.apiStates();
        // The spec follows the chip whether or not this change fetches:
        // the next refetch, whatever asks for it, lists what the chip
        // wants and no more.
        ts.spec.states = wanted;
        if (!ts.loaded_states.covers(wanted)) {
            try app.refreshTab(app.active);
            app.say(.info, "{s}: status → {s} (fetching)", .{ ts.spec.name, want.label(&buf) });
        } else {
            app.say(.info, "{s}: status → {s}", .{ ts.spec.name, want.label(&buf) });
        }
    }

    /// The `author:` chip. `me` is the pane's mine-only fetch (the
    /// account's pull requests across the workspace, whatever the
    /// page held), so going to or from it is the one change here that
    /// refetches; a name seen in the set, or `all` from a name, is a
    /// predicate over the rows already there.
    pub fn setAuthor(app: *App, want: filters.Author) Allocator.Error!void {
        const ts = app.activeTab();
        if (ts.spec.kind.family() != .prs) return;
        if (want == .me and app.meId().len == 0) {
            app.say(.warn, "author: me needs Account:Read on the token (or `account_id` in config.zon)", .{});
            return;
        }
        const was_mine = ts.spec.mine_only;
        var f = ts.filters;
        f.author = want;
        try ts.adoptFilters(app.gpa, f);
        ts.selected = 0;
        ts.scroll = 0;
        app.persistFilters();
        const now_mine = want == .me and ts.spec.kind.isWorkspaceWide();
        const label = ts.filters.author.label(app.me_display_name);
        if (now_mine != was_mine) {
            ts.spec.mine_only = now_mine;
            ts.fetched = false;
            try app.refreshTab(app.active);
            app.say(.info, "{s}: author → {s} (fetching)", .{ ts.spec.name, label });
        } else {
            app.say(.info, "{s}: author → {s}", .{ ts.spec.name, label });
        }
    }

    /// One of the text-valued chips: Target branch, and the pipelines
    /// family's five. "" clears. Always client-side.
    pub fn setTextFilter(app: *App, kind: FilterKind, value: []const u8) Allocator.Error!void {
        const ts = app.activeTab();
        var f = ts.filters;
        switch (kind) {
            .target => f.target = value,
            .run_by => f.run_by = value,
            .branch => f.branch = value,
            .ptype => f.ptype = value,
            .pstatus => f.pstatus = value,
            .trigger => f.trigger = value,
            .status, .author, .show => return,
        }
        try ts.adoptFilters(app.gpa, f);
        ts.selected = 0;
        ts.scroll = 0;
        app.persistFilters();
        app.say(.info, "{s}: {s} → {s}", .{ ts.spec.name, kind.word(), if (value.len > 0) value else "any" });
    }

    /// The chip's text on the toolbar, on the frame arena.
    pub fn chipLabel(app: *App, a: Allocator, kind: FilterKind) Allocator.Error![]const u8 {
        const ts = app.activeTab();
        const f = ts.filters;
        var buf: [64]u8 = undefined;
        const value: []const u8 = switch (kind) {
            .status => f.status.label(&buf),
            .author => f.author.label(app.me_display_name),
            .target => if (f.target.len > 0) f.target else "any",
            .show => if (f.show == .awaiting) try std.fmt.allocPrint(a, "awaiting me ({d})", .{app.awaitingCount()}) else f.show.label(),
            .run_by => if (f.run_by.len > 0) f.run_by else "any",
            .branch => if (f.branch.len > 0) f.branch else "any",
            .ptype => if (f.ptype.len > 0) f.ptype else "any",
            .pstatus => if (f.pstatus.len > 0) f.pstatus else "any",
            .trigger => if (f.trigger.len > 0) f.trigger else "any",
        };
        return std.fmt.allocPrint(a, " {s}: {s} ", .{ kind.word(), value });
    }

    /// Is the chip off its default — painted active?
    pub fn chipActive(app: *App, kind: FilterKind) bool {
        const ts = app.activeTab();
        const f = ts.filters;
        return switch (kind) {
            .status => !f.status.eql(filters.PrStatus.defaultFor(ts.spec.kind, ts.spec.state)),
            .author => f.author != .all,
            .target => f.target.len > 0,
            .show => f.show != .all,
            .run_by => f.run_by.len > 0,
            .branch => f.branch.len > 0,
            .ptype => f.ptype.len > 0,
            .pstatus => f.pstatus.len > 0,
            .trigger => f.trigger.len > 0,
        };
    }

    /// The chips the active tab's family paints, in the web bar's order.
    pub fn chipKinds(app: *App) []const FilterKind {
        return switch (app.family()) {
            .prs => &.{ .status, .author, .target, .show },
            .pipelines => &.{ .run_by, .branch, .ptype, .pstatus, .trigger },
            .branches => &.{},
        };
    }

    /// The values a chip can take right now, off the loaded set: the
    /// clearing row first on a single-select chip, then every distinct
    /// value seen, sorted. On `a`.
    pub fn pickValues(app: *App, a: Allocator, kind: FilterKind) Allocator.Error![]PickItem {
        const ts = app.activeTab();
        const f = ts.filters;
        var out: std.ArrayList(PickItem) = .empty;
        switch (kind) {
            .status => {
                for (filters.PrStatus.all) |w| try out.append(a, .{ .label = filters.PrStatus.wordOf(w), .checked = f.status.has(w) });
            },
            .show => {
                for (filters.Show.cycle) |sh| try out.append(a, .{ .label = sh.label(), .checked = f.show == sh });
            },
            .author => {
                try out.append(a, .{ .label = "all", .checked = f.author == .all });
                try out.append(a, .{ .label = if (app.me_display_name.len > 0) try std.fmt.allocPrint(a, "me ({s})", .{app.me_display_name}) else "me", .checked = f.author == .me });
                var seen: filters.Seen = .{ .arena = a };
                switch (ts.data) {
                    .repo_pr_tree => |repos| for (repos) |r| {
                        for (r.prs) |pr| try seen.add(pr.author);
                    },
                    .pull_requests => |list| for (list) |pr| try seen.add(pr.author),
                    else => {},
                }
                for (seen.sorted()) |name| try out.append(a, .{ .label = name, .checked = f.author == .named and std.mem.eql(u8, f.author.named, name) });
            },
            .target => {
                try out.append(a, .{ .label = "any", .checked = f.target.len == 0 });
                var seen: filters.Seen = .{ .arena = a };
                switch (ts.data) {
                    .repo_pr_tree => |repos| for (repos) |r| {
                        for (r.prs) |pr| try seen.add(pr.dest_branch);
                    },
                    .pull_requests => |list| for (list) |pr| try seen.add(pr.dest_branch),
                    else => {},
                }
                for (seen.sorted()) |name| try out.append(a, .{ .label = name, .checked = std.mem.eql(u8, f.target, name) });
            },
            .run_by, .branch, .ptype, .pstatus, .trigger => {
                const current: []const u8 = switch (kind) {
                    .run_by => f.run_by,
                    .branch => f.branch,
                    .ptype => f.ptype,
                    .pstatus => f.pstatus,
                    else => f.trigger,
                };
                try out.append(a, .{ .label = "any", .checked = current.len == 0 });
                var seen: filters.Seen = .{ .arena = a };
                switch (ts.data) {
                    .repo_tree => |repos| for (repos) |r| {
                        for (r.branches) |b| {
                            if (kind == .branch) try seen.add(b.name);
                            if (b.latest) |pl| try seen.add(runFact(pl, kind));
                        }
                    },
                    .pipelines => |list| for (list) |pl| try seen.add(runFact(pl, kind)),
                    else => {},
                }
                for (seen.sorted()) |v| try out.append(a, .{ .label = v, .checked = std.ascii.eqlIgnoreCase(current, v) });
            },
        }
        return out.toOwnedSlice(a);
    }

    /// The one fact of a run a pipelines chip is about.
    fn runFact(pl: model.Pipeline, kind: FilterKind) []const u8 {
        return switch (kind) {
            .run_by => pl.creator,
            .branch => pl.ref_name,
            .ptype => pl.typeLabel(),
            .pstatus => pl.stateLabel(),
            .trigger => pl.trigger,
            else => "",
        };
    }

    /// Apply row `idx` of `kind`'s values: toggle it on the Status
    /// chip, take it on every other.
    pub fn applyPick(app: *App, kind: FilterKind, idx: usize) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(app.gpa);
        defer scratch.deinit();
        const items = try app.pickValues(scratch.allocator(), kind);
        if (idx >= items.len) return;
        const label = items[idx].label;
        switch (kind) {
            .status => {
                var want = app.activeTab().filters.status;
                want.toggle(filters.PrStatus.all[idx]);
                try app.setStatusSet(want);
            },
            .show => try app.setShow(filters.Show.cycle[idx]),
            .author => try app.setAuthor(if (idx == 0) .all else if (idx == 1) .me else .{ .named = label }),
            .target, .run_by, .branch, .ptype, .pstatus, .trigger => try app.setTextFilter(kind, if (idx == 0) "" else label),
        }
    }

    // ─── a chip's picker ─────────────────────────────────────────────

    /// Open `kind`'s picker over the list: the values the loaded set
    /// offers, the cursor on the live one.
    pub fn openPicker(app: *App, kind: FilterKind) Allocator.Error!void {
        if (kind.family() != app.family()) return;
        app.closePicker();
        var pk: Picker = .{ .kind = kind, .arena = std.heap.ArenaAllocator.init(app.gpa) };
        errdefer pk.arena.deinit();
        pk.items = try app.pickValues(pk.arena.allocator(), kind);
        for (pk.items, 0..) |it, i| if (it.checked) {
            pk.selected = i;
            break;
        };
        app.picker = pk;
        app.mode = .picker;
    }

    pub fn closePicker(app: *App) void {
        if (app.picker) |*p| p.deinit(app.gpa);
        app.picker = null;
        if (app.mode == .picker) app.mode = .list;
    }

    fn pickerKey(app: *App, a: Allocator, spec: []const u8) Allocator.Error!bool {
        const pk = &(app.picker orelse {
            app.mode = .list;
            return true;
        });
        if (std.mem.eql(u8, spec, "esc")) {
            app.closePicker();
        } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "ctrl+n")) {
            try pk.move(a, 1);
        } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "ctrl+p")) {
            try pk.move(a, -1);
        } else if (std.mem.eql(u8, spec, "space") and pk.kind.multi()) {
            try app.togglePickerRow();
        } else if (std.mem.eql(u8, spec, "enter")) {
            try app.commitPicker();
        } else if (std.mem.eql(u8, spec, "backspace")) {
            if (pk.query.items.len > 0) {
                const cut = prevBoundary(pk.query.items, pk.query.items.len);
                pk.query.shrinkRetainingCapacity(cut);
            }
        } else if (blk: {
            var cbuf: [1]u8 = undefined;
            break :blk typedChar(spec, &cbuf);
        }) |ch| {
            try pk.query.appendSlice(app.gpa, ch);
            // The cursor follows the narrowing onto a row that is
            // still there.
            const vis = try pk.visible(a);
            if (vis.len > 0) {
                var on = false;
                for (vis) |i| if (i == pk.selected) {
                    on = true;
                };
                if (!on) pk.selected = vis[0];
            }
        }
        return true;
    }

    /// Space on the Status picker: the row under the cursor flips,
    /// the list narrows at once, the picker stays up.
    fn togglePickerRow(app: *App) Allocator.Error!void {
        const pk = &(app.picker orelse return);
        const kind = pk.kind;
        const idx = pk.selected;
        try app.applyPick(kind, idx);
        // Re-read the ticks off the live filters; the picker's rows
        // are the same set in the same order.
        if (app.picker) |*p| if (idx < p.items.len) {
            p.items[idx].checked = !p.items[idx].checked;
        };
    }

    /// Enter: take the row under the cursor (a multi-select picker
    /// has already applied its toggles) and close.
    pub fn commitPicker(app: *App) Allocator.Error!void {
        const pk = &(app.picker orelse return);
        const kind = pk.kind;
        const idx = pk.selected;
        const multi = kind.multi();
        app.closePicker();
        if (!multi) try app.applyPick(kind, idx);
    }

    /// The right-click menu on a chip: every value, the live one(s)
    /// ticked, a click on a row applying it the way the picker would.
    fn openChipMenu(app: *App, kind: FilterKind, col: u16, y: u16) Allocator.Error!void {
        _ = app.menu_arena.reset(.retain_capacity);
        const a = app.menu_arena.allocator();
        const values = try app.pickValues(a, kind);
        // A menu is a short list; a long set of authors has the picker.
        const n = @min(values.len, 12);
        const items = try a.alloc(MenuItem, n);
        for (items, 0..) |*it, i| it.* = .{ .pick = .{ .kind = kind, .idx = i } };
        var selected: usize = 0;
        for (values[0..n], 0..) |v, i| if (v.checked) {
            selected = i;
            break;
        };
        app.menu = .{ .col = col, .y = y, .items = items, .values = values[0..n], .selected = selected };
        app.mode = .menu;
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
                    if (sdk.budget.isBucketRefusal(w.error_text)) {
                        app.setStatus("{s}", .{bucket_wait_text});
                    } else app.say(.warn, "{s}", .{w.error_text});
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
                // The adaptive poller (`sdk.feed`): the same listing
                // back is a quiet poll, a different one a change. A
                // round the shared bucket skipped is neither.
                if (!r.refused and r.data != null) {
                    const changed = if (ts.digest) |d| d != r.digest else true;
                    ts.digest = r.digest;
                    if (r.tab == app.active) app.watch.settled(changed);
                }
                if (r.data) |fresh| {
                    // A repo whose fetch failed this time keeps the rows
                    // it had: they are still the last thing the server
                    // said about it, and an empty list would read as "no
                    // PRs". Copied onto the new arena — the old one goes.
                    var why_buf: [160]u8 = undefined;
                    const carried = try carryFailedRepos(res.arena.allocator(), ts.data, fresh, &why_buf);
                    const data = carried.data;
                    if (ts.data_arena) |*old| old.deinit();
                    ts.dropPatches(app.gpa);
                    ts.data_arena = res.arena;
                    keep_arena = true;
                    ts.data = data;
                    ts.fetched = true;
                    // `as of` is the last time EVERY repo answered; a
                    // partial failure does not make the rows fresh.
                    // A dry run answered from what was held: nothing
                    // new came off the wire, so the rows are as old as
                    // they were.
                    if (ts.fetched_at == 0 or (r.errored == 0 and !app.budget.isDry())) ts.fetched_at = app.now_secs;
                    ts.show_all = false;
                    ts.repos = r.repos;
                    ts.items = if (carried.items) |n| n else r.items;
                    ts.errored = r.errored;
                    ts.loaded_states = r.states;
                    // Any repo that failed is a failed fetch, in the
                    // header, in the toolkit's words — the pane beside
                    // this one says `fetch failed: …` for the same thing.
                    var some_buf: [48]u8 = undefined;
                    const why = if (carried.why.len > 0) carried.why else if (r.errored > 0) (std.fmt.bufPrint(&some_buf, "{d} repo{s} did not answer", .{ r.errored, if (r.errored == 1) "" else "s" }) catch "some repos did not answer") else "";
                    try TabState.setText(app.gpa, &ts.error_text, why);
                    // The status line follows: the fetch's own count
                    // would say `0 PRs` over rows that are on screen.
                    const status = if (why.len > 0) try std.fmt.allocPrint(app.frame_arena.allocator(), "{s} · fetch failed: {s}", .{ ts.spec.name, why }) else r.status;
                    try TabState.setText(app.gpa, &ts.status, status);
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
                    if (r.tab == app.active and (app.status.items.len == 0 or std.mem.startsWith(u8, app.status.items, "refreshing "))) app.setStatus("{s}", .{ts.status});
                    // A refresh that came back with every repo errored
                    // and nothing to show is a failed refresh, whatever
                    // the shape of the answer: the list on screen is
                    // stale and nothing on it says so. It gets the same
                    // offer as one that failed outright.
                    if (r.refused) {
                        // Not a failure: the machine's shared bucket
                        // is empty, so this round was skipped and the
                        // next one asks again.
                        app.setStatus("{s}", .{bucket_wait_text});
                    } else if (r.errored > 0 and r.items == 0) {
                        app.toastWithAction(.err, retry_action, "error: {s}", .{ts.status});
                    }
                } else if (r.refused) {
                    app.setStatus("{s}", .{bucket_wait_text});
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
            .pr_changed => |c| {
                var kb: [256]u8 = undefined;
                if (app.feed_in_flight.fetchRemove(keyText(&kb, c.key))) |kv| app.gpa.free(kv.key);
                if (c.tab >= app.tabs.len) return;
                const ts = &app.tabs[c.tab];
                const pr = c.pr orelse {
                    if (c.refused) {
                        app.setStatus("{s}", .{bucket_wait_text});
                    } else app.setStatus("{s}", .{c.error_text});
                    return;
                };
                // A listing already on its way will carry it.
                if (ts.loading) return;
                if (patchPr(ts, c.key.repo, pr)) {
                    try ts.patches.append(app.gpa, res.arena);
                    keep_arena = true;
                    app.setStatus("{s}#{d} changed — updated from the event feed", .{ c.key.repo, c.key.id });
                } else {
                    // New to this listing, or gone out of it: the
                    // listing is asked again, conditionally.
                    try app.refreshTab(c.tab);
                }
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
        app.touched();
        if (app.mode != .filter) return;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(app.gpa);
        for (text) |c| if (c != '\n' and c != '\r') try clean.append(app.gpa, c);
        try app.filter.insertSlice(app.gpa, app.filter_caret, clean.items);
        app.filter_caret += clean.items.len;
    }

    /// The character a key spec types, if it types one: a printable
    /// spec as itself, and `shift+f` — how mnml spells a capital — as
    /// `F`. Null for a chord that types nothing.
    fn typedChar(spec: []const u8, buf: *[1]u8) ?[]const u8 {
        if (printable(spec)) return spec;
        if (std.mem.startsWith(u8, spec, "shift+") and spec.len == 7 and std.ascii.isLower(spec[6])) {
            buf[0] = std.ascii.toUpper(spec[6]);
            return buf[0..1];
        }
        return null;
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
    pub fn menuFor(app: *App, rows: []const tabs.VisibleRow, idx: usize) []const MenuItem {
        _ = app.menu_arena.reset(.retain_capacity);
        const a = app.menu_arena.allocator();
        var list: std.ArrayList(MenuItem) = .empty;
        const ts = app.activeTab();
        if (idx >= rows.len) return &.{};
        const push = struct {
            fn f(arena: Allocator, items: *std.ArrayList(MenuItem), act: Action) void {
                items.append(arena, .{ .action = act }) catch {};
            }
        }.f;
        switch (rows[idx]) {
            .repo_header => {
                push(a, &list, .activate);
                push(a, &list, .open_web);
                push(a, &list, .yank_url);
                push(a, &list, .hide_repo);
                push(a, &list, .reorder_up);
                push(a, &list, .reorder_down);
            },
            .pr => |p| {
                push(a, &list, .toggle_detail);
                push(a, &list, .open_web);
                push(a, &list, .yank_url);
                const pr = ts.data.repo_pr_tree[p.repo].prs[p.idx];
                if (pr.buildCommit().len > 0) push(a, &list, .activate);
                // The inline `[ Merge ]` only fits a wide pane, so the
                // menu carries it at every width.
                if (pr.isOpen()) push(a, &list, .merge_pr);
                if (app.detail_visible) push(a, &list, .toggle_approval);
            },
            // A build line offers its own page and nothing else — the
            // row menu must never fire an action the row cannot do.
            .build, .build_note => {
                push(a, &list, .open_web);
                push(a, &list, .yank_url);
            },
            .branch => {
                push(a, &list, .open_web);
                push(a, &list, .yank_url);
            },
            .show_more => push(a, &list, .activate),
            .flat => {
                if (ts.data == .pull_requests) push(a, &list, .toggle_detail);
                push(a, &list, .open_web);
                push(a, &list, .yank_url);
            },
        }
        return list.toOwnedSlice(a) catch &.{};
    }

    /// The actions of a row menu, for a test that reads them.
    pub fn menuActions(app: *App, a: Allocator) Allocator.Error![]const Action {
        const m = app.menu orelse return &.{};
        var out: std.ArrayList(Action) = .empty;
        for (m.items) |it| switch (it) {
            .action => |act| try out.append(a, act),
            .pick, .open_url, .cancel => {},
        };
        return out.toOwnedSlice(a);
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
        switch (m.items[item]) {
            .action => |act| {
                const view = try app.visible(a);
                app.select(view.rows, m.row);
                return app.run(a, act, view.rows);
            },
            .pick => |pk| {
                try app.applyPick(pk.kind, pk.idx);
                return true;
            },
            .open_url => |o| {
                const url = try app.effect_arena.allocator().dupe(u8, o.url);
                app.effect(.{ .open_url = url });
                app.say(.info, "opened {s}", .{url});
                return true;
            },
            .cancel => return true,
        }
    }

    // ─── the mouse ───────────────────────────────────────────────────

    pub const Button = enum { left, middle, right };

    /// A click, routed through the hit map the last paint registered.
    pub fn click(app: *App, col: u16, row: u16, button: Button) Allocator.Error!bool {
        app.touched();
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
        if (app.mode == .picker) {
            // A row of the picker takes it; the box is inert; anywhere
            // else closes it, the way the tracker pane's pickers do.
            if (target) |tg| switch (tg) {
                .picker_row => |i| {
                    if (app.picker) |*pk| pk.selected = i;
                    if (app.picker.?.kind.multi()) try app.togglePickerRow() else try app.commitPicker();
                    return true;
                },
                .picker_body => return true,
                else => {},
            };
            app.closePicker();
            return true;
        }
        if (app.mode == .filter and (target == null or target.? != .chip)) app.mode = .list;
        const tg = target orelse return true;
        const view = try app.visible(a);
        switch (tg) {
            .tab => |i| try app.switchTab(i),
            .chip => |c| switch (c) {
                .refresh => try app.refreshActive(),
                .budget => app.cancelWait(),
                .help => {
                    app.mode = .help;
                    app.help_scroll = 0;
                },
                // The toolbar's chips: a right click lists every
                // value with the live one ticked; a left click opens
                // the chip's picker — except `show`, three values a
                // click cycles the way the host's `sort:` chip does.
                .status, .author, .target, .show, .run_by, .branch, .ptype, .pstatus, .trigger => {
                    const kind: FilterKind = switch (c) {
                        .status => .status,
                        .author => .author,
                        .target => .target,
                        .show => .show,
                        .run_by => .run_by,
                        .branch => .branch,
                        .ptype => .ptype,
                        .pstatus => .pstatus,
                        else => .trigger,
                    };
                    if (button == .right) {
                        try app.openChipMenu(kind, col, row);
                    } else if (kind == .show) {
                        try app.cycleShow();
                    } else try app.openPicker(kind);
                },
                .filter => {
                    app.mode = .filter;
                    app.filter_caret = app.filter.items.len;
                },
                .run_pipeline, .schedules, .caches, .usage => try app.openPipelinesPage(c, col, row),
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
            .menu_item, .sheet, .detail, .picker_row, .picker_body => {},
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
        app.touched();
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

    /// The repo a pipelines chip acts on: the tab's own, or the one
    /// under the cursor on the workspace tree (its header or any branch
    /// under it). Null when neither names one — the chips are not
    /// offered then (`screen.zig`).
    pub fn pipelinesRepo(app: *App, rows: []const tabs.VisibleRow) ?[]const u8 {
        const ts = app.activeTab();
        if (ts.spec.repo.len > 0) return ts.spec.repo;
        if (ts.data != .repo_tree or ts.selected >= rows.len) return null;
        const i = switch (rows[ts.selected]) {
            .repo_header => |h| h.repo,
            .branch => |b| b.repo,
            else => return null,
        };
        const repos = ts.data.repo_tree;
        return if (i < repos.len) repos[i].slug else null;
    }

    /// The pipelines family's chips open Bitbucket's pages: the three
    /// repo pages on the repo the cursor is on, and the workspace's
    /// usage page after asking — a click on a header chip should not
    /// be enough to throw a browser window up unasked.
    fn openPipelinesPage(app: *App, c: hit.Chip, col: u16, y: u16) Allocator.Error!void {
        const ts = app.activeTab();
        const ws = ts.spec.workspace;
        const a = app.effect_arena.allocator();
        switch (c) {
            .usage => {
                _ = app.menu_arena.reset(.retain_capacity);
                const ma = app.menu_arena.allocator();
                const url = try std.fmt.allocPrint(ma, "https://bitbucket.org/{s}/workspace/settings/plans-billing/pipelines-minutes", .{ws});
                const items = try ma.alloc(MenuItem, 2);
                items[0] = .{ .open_url = .{ .label = "open the pipeline-minutes usage page in the browser", .url = url } };
                items[1] = .cancel;
                app.menu = .{ .col = col, .y = y, .items = items };
                app.mode = .menu;
                return;
            },
            .run_pipeline, .schedules, .caches => {
                _ = app.frame_arena.reset(.retain_capacity);
                const rows = (try app.visible(app.frame_arena.allocator())).rows;
                const repo = app.pipelinesRepo(rows) orelse {
                    app.say(.warn, "put the cursor on a repo (or one of its branches) first", .{});
                    return;
                };
                const url = switch (c) {
                    .run_pipeline => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pipelines", .{ ws, repo }),
                    .schedules => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/admin/addon/admin/pipelines/schedules", .{ ws, repo }),
                    else => try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/admin/addon/admin/pipelines/caches", .{ ws, repo }),
                };
                app.effect(.{ .open_url = url });
                app.say(.info, "opened {s}", .{url});
            },
            else => {},
        }
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

test "a refetch that fails keeps the rows it had, says `fetch failed`, and keeps `as of` on the last success" {
    // hunt/findings-2026-09-23/integ-bb-refresh-failure-wipes-rows.md: a
    // 5xx (or the server gone) replaced every PR with nothing, `(0)`,
    // a clipped `network er` per repo and a fresh `as of`.
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    const ts = &r.app.tabs[0];
    const Probe = struct {
        fn prsOf(tab: *const TabState, slug: []const u8) usize {
            for (tab.data.repo_pr_tree) |rp| if (std.mem.eql(u8, rp.slug, slug)) return rp.prs.len;
            return 0;
        }
    };
    const api_prs = Probe.prsOf(ts, "api");
    const web_prs = Probe.prsOf(ts, "web");
    try t.expect(api_prs > 0 and web_prs > 0);
    const items = ts.items;
    const stamp = ts.fetched_at;

    // Every repo 500s.
    r.app.now_secs += 600;
    r.srv.failPaths("");
    try r.app.refreshTab(0);
    try r.drain();
    try t.expectEqual(api_prs, Probe.prsOf(ts, "api"));
    try t.expectEqual(web_prs, Probe.prsOf(ts, "web"));
    try t.expectEqual(items, ts.items);
    try t.expectEqual(stamp, ts.fetched_at);
    for (ts.data.repo_pr_tree) |rp| try t.expectEqualStrings("", rp.error_label);
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("fetch failed: HTTP 500", sdk.pane.chrome.fetchText(&buf, r.app.fetchState(), false));

    // One repo 500s: the other is fresh, the failed one keeps its rows,
    // and the header names it.
    r.srv.failPaths("/web/");
    try r.app.refreshTab(0);
    try r.drain();
    try t.expectEqual(web_prs, Probe.prsOf(ts, "web"));
    try t.expectEqualStrings("fetch failed: web: HTTP 500", sdk.pane.chrome.fetchText(&buf, r.app.fetchState(), false));
    try t.expectEqual(stamp, ts.fetched_at);

    // Back up: the failure clears and the stamp moves.
    r.srv.failPaths(null);
    try r.app.refreshTab(0);
    try r.drain();
    try t.expect(r.app.fetchState() == .idle);
    try t.expectEqual(r.app.now_secs, ts.fetched_at);
}

test "the pipelines chips act on the cursor's repo, and `usage` asks before it opens the browser" {
    // hunt/findings-2026-09-23/integ-bb-pipelines-dead-actions.md: `run
    // pipeline`, `schedules` and `caches` said "switch to a repo tab
    // first" on the workspace tree (a pane with no other tab), and
    // `usage` opened the browser on one click.
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    _ = try r.key("3");
    try t.expectEqual(cfg.Family.pipelines, r.app.family());
    const Urls = struct {
        fn opened(app: *App, out: []u8) []const u8 {
            const fx = app.takeEffects();
            defer app.freeEffects(fx);
            for (fx) |e| if (e == .open_url) {
                const n = @min(out.len, e.open_url.len);
                @memcpy(out[0..n], e.open_url[0..n]);
                return out[0..n];
            };
            return "";
        }
    };
    var buf: [256]u8 = undefined;
    // The cursor on `api`'s header: every repo page is api's.
    r.app.tabs[r.app.active].selected = 0;
    try r.app.openPipelinesPage(.run_pipeline, 0, 0);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/pipelines", Urls.opened(&r.app, &buf));
    // On one of api's branches: still api.
    r.app.tabs[r.app.active].selected = 1;
    try r.app.openPipelinesPage(.schedules, 0, 0);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/admin/addon/admin/pipelines/schedules", Urls.opened(&r.app, &buf));
    try r.app.openPipelinesPage(.caches, 0, 0);
    try t.expectEqualStrings("https://bitbucket.org/acme/api/admin/addon/admin/pipelines/caches", Urls.opened(&r.app, &buf));

    // `usage` asks: a menu, nothing opened yet.
    try r.app.openPipelinesPage(.usage, 10, 2);
    try t.expectEqual(Mode.menu, r.app.mode);
    try t.expectEqualStrings("", Urls.opened(&r.app, &buf));
    // Cancel opens nothing.
    _ = try r.app.runMenuItem(r.arena.allocator(), 1);
    try t.expectEqualStrings("", Urls.opened(&r.app, &buf));
    // Asked again and confirmed: the page.
    try r.app.openPipelinesPage(.usage, 10, 2);
    _ = try r.app.runMenuItem(r.arena.allocator(), 0);
    try t.expectEqualStrings("https://bitbucket.org/acme/workspace/settings/plans-billing/pipelines-minutes", Urls.opened(&r.app, &buf));
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

test "the show chip: reviewing, then awaiting me, count and filter what is waiting on MY review, off the rows already loaded" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    // #1198 (Dana's, me a reviewer, no vote) is the one waiting on me;
    // my own two are not, and #1234's reviewers are other people.
    try t.expectEqual(@as(usize, 1), r.app.awaitingCount());

    const served = r.srv.state.served;
    _ = try r.key("esc"); // nothing open; just a keystroke that changes nothing
    // `A` walks all → reviewing → awaiting me → all, the web's
    // dropdown; each is a predicate over rows already there: not one
    // request.
    _ = try r.key("shift+a");
    try t.expectEqual(filters.Show.reviewing, r.app.activeTab().filters.show);
    _ = try r.key("shift+a");
    try t.expectEqual(filters.Show.awaiting, r.app.activeTab().filters.show);
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

    _ = try r.key("shift+a");
    try t.expectEqual(filters.Show.all, r.app.activeTab().filters.show);
    rows = try r.rows();
    prs = 0;
    for (rows) |row| prs += @intFromBool(row == .pr);
    try t.expect(prs > 1);
    // The choice is in the state file, per tab by name.
    try r.app.setShow(.reviewing);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const state_path = try state_mod.pathBeside(t.allocator, r.config_path);
    defer t.allocator.free(state_path);
    const saved = state_mod.load(arena.allocator(), t.io, state_path);
    try t.expectEqual(filters.Show.reviewing, saved.entryFor("Open + Draft").?.show);

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

test "a click selects the row it lands on, a right-click opens its menu, the author chip opens its picker and `me` refetches" {
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
    try t.expectEqual(MenuItem{ .action = .toggle_detail }, r.app.menu.?.items[0]);
    _ = try r.key("esc");
    try t.expectEqual(Mode.list, r.app.mode);
    _ = try r.app.click(35, 1, .left);
    try t.expectEqual(@as(usize, 1), r.app.active);
    _ = try r.app.click(31, 1, .left);
    // The author chip opens its picker: all, me, then every author the
    // loaded set names, sorted — no request to build it.
    const served = r.srv.state.served;
    _ = try r.app.click(105, 0, .left);
    try t.expectEqual(Mode.picker, r.app.mode);
    const pk = &r.app.picker.?;
    try t.expectEqual(FilterKind.author, pk.kind);
    try t.expectEqualStrings("all", pk.items[0].label);
    try t.expect(pk.items[0].checked);
    try t.expectEqualStrings("me (Chris M)", pk.items[1].label);
    try t.expectEqualStrings("Dana R", pk.items[2].label);
    try t.expectEqualStrings("Sam K", pk.items[3].label);
    try t.expectEqual(@as(u32, 0), r.srv.state.served - served);
    // A name is a predicate over the rows there: still no request.
    _ = try r.key("down");
    _ = try r.key("down");
    _ = try r.key("enter");
    try r.drain();
    try t.expectEqual(Mode.list, r.app.mode);
    try t.expect(r.app.tabs[1].filters.author == .named);
    try t.expectEqualStrings("Dana R", r.app.tabs[1].filters.author.named);
    try t.expectEqual(@as(u32, 0), r.srv.state.served - served);
    try t.expectEqualStrings("Merged: author → Dana R", r.app.status.items);
    // `me` is the mine-only fetch: the one author value that costs a
    // request, and says so.
    try r.app.setAuthor(.me);
    try t.expectEqualStrings("Merged: author → Chris M (fetching)", r.app.status.items);
    try r.drain();
    try t.expect(r.app.tabs[1].spec.mine_only);
    try t.expect(r.srv.state.served > served);
    try r.app.setAuthor(.all);
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

test "a dry-run refresh answered from the held tags keeps `as of`: the rows are as old as they were" {
    // Round-7 hunt: with dry run on, `r` answered every GET from the
    // ETag store — rows right, nothing on the wire — and stamped the
    // tab fresh ("as of 2s ago").
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const store_path = try std.fs.path.join(t.allocator, &.{ dir, "etags.json" });
    defer t.allocator.free(store_path);
    var etags = try sdk.Store.openAt(t.allocator, t.io, store_path);
    defer etags.deinit();
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    r.client.etags = &etags;
    r.app.budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    r.client.budget = &r.app.budget;
    // A live refresh files every listing under its tag.
    try r.app.refreshTab(0);
    try r.drain();
    const ts = &r.app.tabs[0];
    const stamp = ts.fetched_at;
    const items = ts.items;
    try t.expect(stamp > 0 and items > 0);
    _ = try r.key("shift+n");
    const served = r.srv.snapshot().served;
    r.app.now_secs += 600;
    try r.app.refreshTab(0);
    try r.drain();
    try t.expectEqual(served, r.srv.snapshot().served);
    try t.expectEqual(items, ts.items);
    try t.expectEqual(@as(usize, 0), ts.errored);
    try t.expectEqual(stamp, ts.fetched_at);
}

test "Shift+N turns dry run on and a refresh then sends nothing; Ctrl+X stops a rate-limit pause" {
    const r = try Rig.init(acme, .{});
    defer r.deinit();
    r.app.budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    r.client.budget = &r.app.budget;
    _ = try r.key("shift+n");
    try t.expect(r.app.budget.isDry());
    try t.expect(std.mem.indexOf(u8, r.app.status.items, "dry run on") != null);
    const served = r.srv.snapshot().served;
    _ = try r.key("r");
    try t.expectEqual(served, r.srv.snapshot().served);
    _ = try r.key("shift+n");
    try t.expect(!r.app.budget.isDry());

    _ = r.app.budget.throttled(1, 60);
    try t.expect(r.app.budget.snapshot(r.app.now_secs).paused_until > 0);
    _ = try r.key("ctrl+x");
    try t.expectEqual(@as(i64, 0), r.app.budget.snapshot(r.app.now_secs).paused_until);
    try t.expect(std.mem.indexOf(u8, r.app.status.items, "stopped waiting") != null);
}

test "a feed key reads as a pull request in either spelling, and nothing else does" {
    const k = App.parseFeedKey("api#1234", "", "acme").?;
    try t.expectEqualStrings("acme", k.workspace);
    try t.expectEqualStrings("api", k.repo);
    try t.expectEqual(@as(i64, 1234), k.id);
    const w = App.parseFeedKey("other/web#7", "acme", "acme").?;
    try t.expectEqualStrings("other", w.workspace);
    try t.expectEqualStrings("web", w.repo);
    try t.expectEqualStrings("tabws", App.parseFeedKey("api#1", "tabws", "acme").?.workspace);
    try t.expect(App.parseFeedKey("api", "", "acme") == null);
    try t.expect(App.parseFeedKey("api#x", "", "acme") == null);
    try t.expect(App.parseFeedKey("#12", "", "acme") == null);
    try t.expect(App.parseFeedKey("api#0", "", "acme") == null);
}

test "a changed pull request replaces its row in place while its state still belongs to the listing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prs = try a.alloc(model.PullRequest, 2);
    prs[0] = .{ .id = 1, .title = "one", .state = "OPEN" };
    prs[1] = .{ .id = 2, .title = "two", .state = "OPEN" };
    const repos = try a.alloc(model.RepoPrs, 1);
    repos[0] = .{ .slug = "api", .prs = prs };
    var ts: TabState = .{
        .spec = .{ .kind = .workspace_open_prs, .name = "Open", .workspace = "acme" },
        .data = .{ .repo_pr_tree = repos },
        .expanded = tabs.Expanded.init(t.allocator),
        .loaded_states = .{ .open = true },
    };
    defer ts.expanded.deinit();
    try t.expect(patchPr(&ts, "api", .{ .id = 2, .title = "two, again", .state = "OPEN" }));
    try t.expectEqualStrings("two, again", ts.data.repo_pr_tree[0].prs[1].title);
    // Merged since: it no longer belongs to an open listing.
    try t.expect(!patchPr(&ts, "api", .{ .id = 1, .title = "one", .state = "MERGED" }));
    try t.expectEqualStrings("one", ts.data.repo_pr_tree[0].prs[0].title);
    // Not in this listing at all.
    try t.expect(!patchPr(&ts, "api", .{ .id = 9, .title = "new", .state = "OPEN" }));
    try t.expect(!patchPr(&ts, "web", .{ .id = 2, .title = "x", .state = "OPEN" }));
}
