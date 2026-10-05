//! The pane's state and every action on it — what is loaded, what is
//! selected, which overlay is up — with no painting in it. `screen.zig`
//! turns an `App` into a frame (and fills the hit map while it does);
//! `key`, `click` and `wheel` here turn what the user did into state.
//! Every fetch is synchronous through the client, the way the reference
//! does it; the loop in `main.zig` paints between them.

const std = @import("std");
const sdk = @import("mnml_sdk");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const model = @import("model.zig");
const recent = @import("recent.zig");
const jira = @import("jira.zig");
const ratelimit = @import("ratelimit.zig");
const bitbucket = @import("bitbucket.zig");
const tree = @import("tree.zig");
const kanban = @import("kanban.zig");
const filters = @import("filters.zig");
const dispatch = @import("dispatch.zig");
const hit = @import("hit.zig");
const keymap = @import("keymap.zig");
const pickers = @import("pickers.zig");
const textedit = @import("textedit.zig");
const varsedit = @import("varsedit.zig");
const os = @import("os.zig");

pub const Issue = model.Issue;
pub const TextEdit = textedit.TextEdit;
pub const Value = std.json.Value;

/// An assignee's presence on a tab, for the avatar cluster.
pub const AssigneeSummary = struct { account_id: []const u8, display_name: []const u8, count: usize };

pub const TabState = struct {
    cfg: config.Tab,
    /// Where this tab sits in the config FILE's `.tabs` list. `--only`
    /// filters the App's list, so its index is not the file's, and the
    /// file's is what a splice path has to name.
    file_idx: usize = 0,
    /// The tab's `{name}` holes, as they stand now. Starts as the
    /// config's and is replaced by a saved vars edit.
    vars: []const config.Var = &.{},
    /// The resolved JQL; replaced by the JQL editor and the tab-version picker.
    jql: []const u8,
    /// Owns the issues; reset on every refresh.
    data: std.heap.ArenaAllocator,
    /// Owns the caches that outlive a refresh.
    meta: std.heap.ArenaAllocator,
    issues: []const Issue = &.{},
    /// A row index on a tree tab, an issue index otherwise.
    selected: usize = 0,
    fetched: bool = false,
    /// Unix seconds the rows on screen last came back — what the
    /// header's `as of 4m ago` reads, and what a delta window is
    /// measured from.
    fetched_at: i64 = 0,
    /// A delta refetch cannot swap the tab's arena: the rows it did
    /// NOT return are still on the old one. So each one keeps its
    /// arena here and the merged `issues` slice points into all of
    /// them; a full refetch frees the lot. Capped at
    /// `max_delta_generations`, past which a refetch is full whatever
    /// was asked for — an unbounded chain is a leak with a nicer name.
    deltas: std.ArrayListUnmanaged(std.heap.ArenaAllocator) = .empty,
    /// The rows' digest after the last refetch landed (`issuesDigest`):
    /// the next one matching it is a poll that found nothing new.
    digest: ?u64 = null,
    last_error: []const u8 = "",
    tree: ?tree.State = null,
    sprints: ?[]const model.Sprint = null,
    selected_sprint: ?u64 = null,
    quick_filters: ?[]const model.QuickFilter = null,
    active_quick_filters: std.ArrayList(u64) = .empty,
    scope: filters.Scope = .all,
    assignees: []const AssigneeSummary = &.{},
    active_assignees: std.StringHashMapUnmanaged(void) = .empty,
    show_jql: bool = false,
    seeded: bool = false,
    boards: ?[]const model.Board = null,
    active_epics: std.StringHashMapUnmanaged(void) = .empty,
    team: []const u8,
    issue_type: []const u8,
    label: []const u8,
    board_id: u64,
    scroll: usize = 0,

    /// Free every delta generation. The base arena is untouched: this
    /// is what a full refetch does before it swaps that one out.
    pub fn dropDeltas(t: *TabState) void {
        for (t.deltas.items) |*d| d.deinit();
        t.deltas.clearRetainingCapacity();
    }

    pub fn shape(t: *const TabState) keymap.TabShape {
        if (t.cfg.isKanban()) return .kanban;
        if (t.cfg.isTree()) return .tree;
        return .flat;
    }

    pub fn issue(t: *const TabState, idx: usize) ?Issue {
        if (idx >= t.issues.len) return null;
        return t.issues[idx];
    }

    fn activeIds(t: *const TabState, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = t.active_assignees.keyIterator();
        while (it.next()) |k| try out.append(arena, k.*);
        return out.toOwnedSlice(arena);
    }

    fn activeEpics(t: *const TabState, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = t.active_epics.keyIterator();
        while (it.next()) |k| try out.append(arena, k.*);
        return out.toOwnedSlice(arena);
    }
};

/// One ticket's linked PRs, fetched beside the search rather than after
/// it — the per-row calls are most of a refetch's wall time and they do
/// not belong on the loop either.
/// Everything a refetch needs, and nothing the loop can change under it
/// while it runs. The client is a copy: it holds no per-call state, and
/// its limiter is the cross-process bucket, which is built to be shared.
/// How many delta refetches may stack on one full one before the next
/// is forced to be full. Each keeps its own arena, so this is the
/// ceiling on how much a tab that is only ever delta-refreshed can
/// hold — and a full refetch is also the only thing that notices a
/// ticket which has dropped OUT of the query, so it is worth making
/// sure one happens.
pub const max_delta_generations: usize = 8;

/// A delta also asks which of the rows on screen moved OUT of the
/// query (`key in (…) AND updated >= <window>`): above this many rows
/// that list is too long a question, and the refetch is whole instead.
pub const max_departure_keys: usize = 200;

/// What a refetch is allowed to be.
pub const RefreshMode = enum {
    /// A delta where one is possible, a full listing otherwise. What
    /// `r`, the interval and a tab switch all ask for.
    delta,
    /// The whole listing, whatever is cached. What `R` asks for, and
    /// what anything that changed the QUERY has to ask for.
    full,
};

pub const RefreshJob = struct {
    idx: usize,
    client: jira.Client,
    /// Owns `jql` and `extra_jql`; freed by whoever runs the job.
    arena: std.heap.ArenaAllocator,
    jql: []const u8,
    board_id: u64,
    extra_jql: ?[]const u8,
    extra_fields: []const []const u8,
    team_field_id: []const u8,
    /// The tab's query WITHOUT the window — what a successful whole
    /// listing is dated under, so a changed question is never answered
    /// with a window onto the old one.
    base_jql: []const u8 = "",
    /// `-15m` when this is a delta window since the last successful
    /// sync, empty when the whole listing is being asked for. Already
    /// spliced into `jql`; kept so the result can say which it was.
    delta_since: []const u8 = "",
    /// On a delta: the keys on screen, so the window can also learn
    /// which of them LEFT the query (closed, reassigned away) — a
    /// window onto the query alone cannot see a ticket that no longer
    /// matches it. On the job's arena.
    shown_keys: []const []const u8 = &.{},
    /// An event feed named these tickets (`sdk.feed`): `jql` asks for
    /// just them within the tab's query, and any not in the answer have
    /// left it. On the job's arena.
    feed_keys: []const []const u8 = &.{},
    /// What the request log calls this fetch — the first load of a tab
    /// and a refetch of one cost the same requests and mean different
    /// things when the log is read back.
    reason: jira.Reason = .pane_open,
    /// Where the shared recent-items cache lives (`src/recent.zig`);
    /// null when it is off. Borrowed from the App, which outlives jobs.
    recent_root: ?[]const u8 = null,
    /// What the cache calls this tab's listing: `tab:<name>`. On the
    /// job's arena.
    listing: []const u8 = "",
    refresh_interval_secs: u32 = 0,
    /// A release tab's project and version: its whole fetch is the
    /// release's `keys` in the cache. On the job's arena.
    release_project: []const u8 = "",
    release_name: []const u8 = "",

    pub fn deinit(j: *RefreshJob) void {
        j.arena.deinit();
    }
};

/// What comes back. The arena owns the JSON the issues slice into, so
/// it becomes the tab's on success and is dropped on failure — the old
/// rows stay on screen either way until this is applied.
pub const RefreshResult = struct {
    idx: usize,
    arena: std.heap.ArenaAllocator,
    issues: []const Issue = &.{},
    /// This was a window, not the whole listing: `issues` is what
    /// MOVED, and what did not is still on the tab.
    delta: bool = false,
    /// The query this asked, window excluded. Owned by `arena`.
    base_jql: []const u8 = "",
    /// On a delta: rows on screen that moved in the window and no
    /// longer match the query. Owned by `arena`.
    departed: []const []const u8 = &.{},
    /// Empty when the search answered.
    error_text: []const u8 = "",
    /// This answered an event feed's keys, not a poll: it says nothing
    /// about whether the listing as a whole moved.
    feed: bool = false,

    pub fn drop(r: RefreshResult) void {
        var arena = r.arena;
        arena.deinit();
    }
};

pub const RefreshSlot = sdk.pane.Slot(RefreshResult);

/// One ticket's linked pull requests, fetched on its own rather than
/// with the search. A tree tab's twenty-five dev-status calls used to
/// happen BEFORE the first paint, which is the minute of `loading…`
/// this exists to end: the search paints, and these arrive behind it,
/// one at a time, in the order the rows are on screen.
pub const PrJob = struct {
    /// Owns `key` and `issue_id`.
    arena: std.heap.ArenaAllocator,
    client: jira.Client,
    key: []const u8,
    issue_id: []const u8,
    /// The ticket's `updated` when the job was made — the stamp the
    /// answer is filed under, so the next run can skip it.
    updated: []const u8,

    pub fn deinit(j: *PrJob) void {
        j.arena.deinit();
    }
};

pub const PrResult = struct {
    /// Owns everything below.
    arena: std.heap.ArenaAllocator,
    key: []const u8 = "",
    updated: []const u8 = "",
    list: []const model.LinkedPr = &.{},
    /// The response verbatim, for the cache. Empty on a failure, which
    /// is never cached: a failure must cost one retry, not a run.
    body: []const u8 = "",

    pub fn drop(r: PrResult) void {
        var arena = r.arena;
        arena.deinit();
    }
};

pub const PrSlot = sdk.pane.Slot(PrResult);

/// A look at one ticket the reader asked for — its detail (`d`) or the
/// transitions a picker offers (`t`) — off the loop. They used to be
/// fetched inline, and on a slow site the pane froze for the whole of
/// it: no spinner, no `?`, nothing to say the key was heard.
pub const LookKind = enum { detail, transitions };

pub const LookJob = struct {
    /// Owns `key`.
    arena: std.heap.ArenaAllocator,
    client: jira.Client,
    kind: LookKind,
    key: []const u8,

    pub fn deinit(j: *LookJob) void {
        j.arena.deinit();
    }
};

pub const LookResult = struct {
    /// Owns everything below; a detail result's becomes the entry's.
    arena: std.heap.ArenaAllocator,
    kind: LookKind,
    key: []const u8 = "",
    detail: model.IssueDetail = .{},
    transitions: []const model.Transition = &.{},
    error_text: []const u8 = "",

    pub fn drop(r: LookResult) void {
        var arena = r.arena;
        arena.deinit();
    }
};

pub const LookSlot = sdk.pane.Slot(LookResult);

pub const Filter = struct { edit: TextEdit, editing: bool };

pub const Comment = struct { key: []const u8, edit: TextEdit, posting: bool = false, error_text: []const u8 = "" };

pub const Modal = struct {
    key: []const u8,
    arena: std.heap.ArenaAllocator,
    data: ?Value = null,
    scroll: u16 = 0,
    error_text: []const u8 = "",
};

pub const Rows = tree.Rows;

pub const App = struct {
    gpa: Allocator,
    io: Io,
    cfg: config.Config,
    family: ?config.Family,
    client: *jira.Client,
    forge: bitbucket.Client,
    /// Where a wait long enough for a person to notice is left by
    /// whichever thread made the request. `noteWait` turns it into the
    /// one line that keeps `loading…` from being silent.
    wait_notice: ratelimit.Notice = .{},
    /// The API budget (`mnml_sdk.budget`) — the Bitbucket pane's same
    /// object: the client writes it on every request, the header's
    /// budget chip and its hover read it. `main` configures it and
    /// points the client at it; unconfigured (a test) it paints `0/h`
    /// and never pauses.
    budget: sdk.Budget = .{},
    /// `$MNML_IPC_DIR`: the channel of the mnml this pane runs inside —
    /// where a dispatched `term` line has to go. Borrowed from the
    /// environment, empty outside a host.
    ipc_dir: []const u8 = "",
    /// `$MNML_OPEN_URL`: whether a URL reaches a browser at all
    /// (`sdk.platform.openUrlRoute`). Borrowed from the environment;
    /// null outside a host.
    open_url_route: ?[]const u8 = null,
    /// The config file this pane was loaded from — where a saved vars
    /// edit is spliced back into. Empty means the editor can still run
    /// but cannot save, and says so.
    cfg_path: []const u8 = "",
    /// Small owned strings: keys in sets, the status, resolved JQLs.
    keys: std.heap.ArenaAllocator,
    tabs: []TabState,
    active: usize = 0,
    status: std.ArrayList(u8) = .empty,
    details_visible: bool = false,
    details_scroll: u16 = 0,
    /// How many lines the detail pane painted last frame, and how many
    /// fit — what turns a press on its scrollbar into a position.
    details_lines: usize = 0,
    details_rows: u16 = 0,
    details: std.StringHashMapUnmanaged(*DetailEntry) = .empty,
    filter: ?Filter = null,
    jql: ?TextEdit = null,
    transition: ?pickers.TransitionPicker = null,
    picker: ?pickers.FieldPicker = null,
    comment: ?Comment = null,
    selection: std.StringHashMapUnmanaged(void) = .empty,
    modal: ?Modal = null,
    vars: ?varsedit.Editor = null,
    help: bool = false,
    help_scroll: usize = 0,
    me: ?model.User = null,
    me_failed: bool = false,
    board_names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    kanban_scroll: [kanban.count]u16 = .{ 0, 0, 0, 0 },
    kanban_expanded: std.StringHashMapUnmanaged(void) = .empty,
    hits: hit.Map = .{},
    cols: u16 = 80,
    rows: u16 = 24,
    last_refresh_ms: i64 = 0,
    /// When to ask again, and what an event feed says changed
    /// (`sdk.feed`). `main` builds it from the config; the default
    /// never polls, which is what a test gets.
    watch: sdk.feed.Watcher = .{ .poll = .init(0, 0) },
    /// The shared recent-items cache's directory (`src/recent.zig`);
    /// null when it is off. Owned by main's arena.
    recent_root: ?[]const u8 = null,
    /// `recent_items.current_release` as mnml handed it down
    /// (`recent.current_release_env`): the release `current` names.
    recent_current_release: []const u8 = "",
    /// Tickets refetched on their own because the feed named them.
    feed_fetches: u32 = 0,
    /// The one refetch in flight, and the group it runs on. With no
    /// group — a test, `--dump` — a refetch runs inline, which is what
    /// makes those two deterministic.
    refresh: RefreshSlot,
    /// One linked-PR fetch at a time, behind the paint.
    prs: PrSlot,
    /// One detail / transitions fetch at a time, off the loop; the
    /// latest ask while one is out waits in `look_next`.
    looks: LookSlot,
    look_next_kind: ?LookKind = null,
    look_next_buf: [64]u8 = undefined,
    look_next_len: usize = 0,
    /// The ticket whose detail is on the wire, for the spinner.
    detail_fetching_buf: [64]u8 = undefined,
    detail_fetching_len: usize = 0,
    /// Tickets whose linked PRs are not known yet, in the order their
    /// rows are on screen. `pumpPrs` takes the front one.
    pr_queue: std.ArrayListUnmanaged([]const u8) = .empty,
    /// What the last run learned, keyed by each ticket's own `updated`
    /// stamp (`mnml_sdk.store`). A ticket that has not moved costs no
    /// request at all, this run or any later one. Null in a test.
    pr_store: ?*sdk.Store = null,
    /// When each tab's listing last came back WHOLE, kept between
    /// runs so a delta window survives a restart. The entry's own
    /// `fetched_at` is the mark (`sdk.warm.SyncMarks`).
    sync_store: ?*sdk.Store = null,
    /// What every row's action button says now, keyed by the ticket or
    /// the PR rather than the row, so a refetch that moves the row keeps
    /// what was pressed on it.
    actions: sdk.pane.ActionStore,
    /// The channel a `[ view ]` press asks the host to focus a session
    /// on. Null outside a host, where the button is not offered.
    ipc: ?*const sdk.Ipc = null,
    /// Sessions this pane started and wants told about, waiting to go
    /// out over the mount; the loop drains them after each pass. The
    /// arena owns their strings for the life of the pane — a watch is
    /// small and there is one per press, so it is never freed
    /// individually.
    watch_out: std.ArrayListUnmanaged(WatchRequest) = .empty,
    watch_arena: std.heap.ArenaAllocator,
    /// Turns the spinner on every button that is mid-dispatch.
    spin: usize = 0,
    /// Wall-clock seconds, when something has pinned them (a test);
    /// zero means read the clock (`nowSecs`).
    now_secs: i64 = 0,
    /// The merge confirm, when one is up.
    merge: ?MergeConfirm = null,
    /// What the pointer is over, when it is worth saying — the reason a
    /// dim `[ Merge ]` is dim. A fixed buffer: the pointer moves many
    /// times a second and an arena would grow with every move of it.
    hover_buf: [192]u8 = undefined,
    hover_len: usize = 0,
    /// The pane has the keyboard. A merge that ends while it does not
    /// is worth a notification.
    focused: bool = true,
    group: ?*Io.Group = null,
    /// The ticket the cursor was on when the in-flight refetch started,
    /// so it can go back on it when the rows are swapped.
    keep_key_buf: [64]u8 = undefined,
    keep_key_len: usize = 0,
    /// // changed (focus-row): the ticket a `--focus ENG-2` asked the
    /// cursor to land on. It outlives the first paint — the flag is
    /// read before any listing exists — and is cleared the moment it
    /// lands or is answered with `not in this listing`. A forwarded
    /// focus (`focus_item` over the mount, this pane already open)
    /// goes through the same field, so there is one landing, not two.
    focus_key_buf: [64]u8 = undefined,
    focus_key_len: usize = 0,
    quit: bool = false,
    /// The count the statusline segment shows; null until a work tab loaded.
    assigned_open: ?usize = null,
    /// Which tab that count was taken off — the listing the chip's
    /// hover rows are built from. An index rather than the slice: a
    /// refetch replaces the tab's arena under it.
    assigned_tab: ?usize = null,
    /// Set when `assigned_open` changed and has not been published.
    segment_dirty: bool = false,
    /// The last thing worth a toast (an action's outcome); the loop drains it.
    toast: std.ArrayList(u8) = .empty,
    toast_pending: bool = false,
    /// The offer attached to the pending toast, when it has one — a
    /// label and either a command the host runs or a page it opens
    /// (`sdk.wire.ToastAction`). Its strings are owned by `toast_act`.
    toast_action: ?sdk.wire.ToastAction = null,
    toast_act_buf: [512]u8 = undefined,

    const DetailEntry = struct { arena: std.heap.ArenaAllocator, detail: model.IssueDetail };

    /// One queued `watch_session`, in the wire's own shape.
    pub const WatchRequest = struct { key: []const u8, cwd: []const u8, prompt_line: []const u8 };

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

    pub fn init(gpa: Allocator, io: Io, cfg: config.Config, family: ?config.Family, client: *jira.Client, forge: bitbucket.Client) Allocator.Error!App {
        var keys = std.heap.ArenaAllocator.init(gpa);
        errdefer keys.deinit();
        // The file indices come along: `--only` drops tabs, so the
        // position in this list is not the position in `.tabs`, and the
        // vars editor writes through the file's.
        var file_idx: std.ArrayList(usize) = .empty;
        var cfg_list: std.ArrayList(config.Tab) = .empty;
        for (cfg.tabs, 0..) |c, i| {
            if (family) |f| {
                const k = c.kind orelse continue;
                if (k.family() != f) continue;
            }
            try cfg_list.append(keys.allocator(), c);
            try file_idx.append(keys.allocator(), i);
        }
        const cfg_tabs = cfg_list.items;
        const tabs = try gpa.alloc(TabState, cfg_tabs.len);
        errdefer gpa.free(tabs);
        for (cfg_tabs, file_idx.items, tabs) |c, fi, *t| {
            t.* = .{
                .cfg = c,
                .file_idx = fi,
                .vars = c.vars,
                .jql = (try c.staticJql(keys.allocator())) orelse "",
                .data = std.heap.ArenaAllocator.init(gpa),
                .meta = std.heap.ArenaAllocator.init(gpa),
                .tree = if (c.isTree() or c.isKanban()) blk: {
                    var st = tree.State.init(gpa);
                    // Reported by me opens on its configured window; it
                    // is the only kind that has one, and the tree's
                    // trailing row is what widens it.
                    if (c.kind == .work_reported) st.window_days = c.reported_window_days;
                    break :blk st;
                } else null,
                .team = c.team,
                .issue_type = c.issue_type,
                .label = c.label,
                .board_id = c.board_id,
            };
        }
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .family = family, .client = client, .forge = forge, .keys = keys, .tabs = tabs, .refresh = try RefreshSlot.init(gpa), .prs = try PrSlot.init(gpa), .looks = try LookSlot.init(gpa), .actions = sdk.pane.ActionStore.init(gpa), .watch_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// `$MNML_IPC_DIR` — the channel of the mnml this pane is running
    /// inside, and the only one that will act on a dispatched `term`
    /// line. Set by the caller right after `init`; empty outside a host.
    pub fn setIpcDir(a: *App, dir: []const u8) void {
        a.ipc_dir = dir;
    }

    /// `$MNML_OPEN_URL`, off the environment right after `init`.
    pub fn setOpenUrlRoute(a: *App, route: ?[]const u8) void {
        a.open_url_route = route;
    }

    /// `--focus ENG-2` off the argv, before anything has loaded. The
    /// key is only remembered here; `tryFocus` lands it at the first
    /// listing that can hold it.
    pub fn setFocusKey(a: *App, key: []const u8) void {
        a.rememberFocus(key);
    }

    /// The group a refetch runs on. Set by the pane loop right after
    /// `init`; left null by a test and by `--dump`, where a refetch runs
    /// inline so the next line sees its result.
    pub fn setGroup(a: *App, group: *Io.Group) void {
        a.group = group;
    }

    /// The Tier-2 channel. A `[ view ]` press goes down it as a
    /// `focus-session` line; without one the button stays on its word.
    pub fn setIpc(a: *App, ipc: *const sdk.Ipc) void {
        a.ipc = ipc;
    }

    /// Close the result queue. The pane calls this BEFORE cancelling the
    /// group: a worker parked on a put into a live queue never sees the
    /// cancel, and the cancel then never returns.
    pub fn closeRefresh(a: *App) void {
        a.refresh.q.close(a.io);
        a.prs.q.close(a.io);
        a.looks.q.close(a.io);
    }

    /// Where a ticket's linked PRs are remembered between runs. Set by
    /// the pane loop right after `init`; left null by a test, which
    /// then simply pays for every one.
    pub fn setPrStore(a: *App, st: *sdk.Store) void {
        a.pr_store = st;
    }

    /// Where each tab's last WHOLE listing is dated. Without it every
    /// refetch is a full one, which is the old behaviour and not
    /// wrong — only dearer.
    pub fn setSyncStore(a: *App, st: *sdk.Store) void {
        a.sync_store = st;
    }

    /// The window a delta refetch of `t` should ask for, or null when
    /// it must ask for everything: nothing synced yet, no store, or
    /// the chain of generations is as long as it may get.
    fn deltaWindow(a: *App, arena: Allocator, t: *const TabState, query: []const u8) Allocator.Error!?[]const u8 {
        if (!t.fetched or t.issues.len == 0) return null;
        if (t.deltas.items.len >= max_delta_generations) return null;
        const store = a.sync_store orelse return null;
        const marks: sdk.warm.SyncMarks = .{ .store = store };
        var buf: [32]u8 = undefined;
        // The query is part of the mark: a version picker, a vars edit
        // or the JQL editor changes the question, and "what moved
        // since" is only ever an answer about the question it was
        // measured for.
        const since = marks.jiraSince(&buf, t.cfg.name, query, a.nowSecs()) orelse return null;
        return try arena.dupe(u8, since);
    }

    /// Say a tab's listing came back whole, so the next delta has a
    /// window to measure from.
    fn markSynced(a: *App, t: *const TabState, query: []const u8, at: i64) void {
        const store = a.sync_store orelse return;
        const marks: sdk.warm.SyncMarks = .{ .store = store };
        marks.mark(t.cfg.name, query, at) catch return;
        store.save();
    }

    /// The config file a vars edit is written back into.
    pub fn setConfigPath(a: *App, path: []const u8) void {
        a.cfg_path = path;
    }

    pub fn deinit(a: *App) void {
        for (a.tabs) |*t| {
            t.dropDeltas();
            t.deltas.deinit(a.gpa);
            t.data.deinit();
            t.meta.deinit();
            if (t.tree) |*tr| tr.deinit();
            t.active_quick_filters.deinit(a.gpa);
            t.active_assignees.deinit(a.gpa);
            t.active_epics.deinit(a.gpa);
        }
        a.gpa.free(a.tabs);
        a.pr_queue.deinit(a.gpa);
        a.status.deinit(a.gpa);
        a.toast.deinit(a.gpa);
        var it = a.details.valueIterator();
        while (it.next()) |e| {
            e.*.arena.deinit();
            a.gpa.destroy(e.*);
        }
        a.details.deinit(a.gpa);
        if (a.filter) |*f| f.edit.deinit();
        if (a.jql) |*j| j.deinit();
        if (a.transition) |*t| t.deinit();
        if (a.picker) |*p| p.deinit();
        if (a.comment) |*c| c.edit.deinit();
        if (a.modal) |*m| m.arena.deinit();
        if (a.vars) |*v| v.deinit();
        if (a.merge) |*m| m.deinit();
        a.selection.deinit(a.gpa);
        a.board_names.deinit(a.gpa);
        a.kanban_expanded.deinit(a.gpa);
        a.hits.deinit(a.gpa);
        a.refresh.deinit(a.io, RefreshResult.drop);
        a.prs.deinit(a.io, PrResult.drop);
        a.looks.deinit(a.io, LookResult.drop);
        a.actions.deinit();
        a.watch_out.deinit(a.gpa);
        a.watch_arena.deinit();
        a.keys.deinit();
        a.* = undefined;
    }

    // ─── small helpers ───────────────────────────────────────────────────

    pub fn keep(a: *App, s: []const u8) Allocator.Error![]const u8 {
        return a.keys.allocator().dupe(u8, s);
    }

    pub fn setStatus(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.status.clearRetainingCapacity();
        a.status.print(a.gpa, fmt, args) catch {};
    }

    /// Say something about a wait the reader has been sitting through.
    /// Called at the top of every loop pass, so the line appears WHILE
    /// the fetch is still out rather than after it lands — and the
    /// fetch's own summary replaces it when the rows arrive.
    pub fn noteWait(a: *App) void {
        const w = a.wait_notice.take() orelse return;
        var buf: [96]u8 = undefined;
        a.setStatus("{s}", .{w.text(&buf)});
    }

    /// A status that is also worth mnml's toast.
    pub fn say(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.setStatus(fmt, args);
        a.toast.clearRetainingCapacity();
        a.toast.print(a.gpa, fmt, args) catch {};
        a.toast_pending = true;
        a.toast_action = null;
    }

    /// The offer a failed fetch owes the reader: the list on screen is
    /// stale and nothing on it says so, so the message carries the way
    /// back rather than expecting them to know that `r` is refresh.
    pub const retry_action: sdk.wire.ToastAction = .{ .label = "Retry", .command = "integrations.retry_refresh" };

    /// A toast with something to DO about it. `url` (when it is one)
    /// is copied into the app's own buffer, so the offer outlives the
    /// arena the caller formatted it on.
    pub fn sayWithAction(a: *App, action: sdk.wire.ToastAction, comptime fmt: []const u8, args: anytype) void {
        a.say(fmt, args);
        if (action.url.len == 0) {
            a.toast_action = action;
            return;
        }
        if (action.url.len > a.toast_act_buf.len) return;
        @memcpy(a.toast_act_buf[0..action.url.len], action.url);
        a.toast_action = .{ .label = action.label, .url = a.toast_act_buf[0..action.url.len] };
    }

    /// `Ctrl+X`, or a click on the budget chip: stop waiting out a
    /// 429's pause. With no pause running the click says the budget's
    /// figures on the hint row instead, so it is never a dead click.
    pub fn cancelWait(a: *App) void {
        if (a.budget.cancelWait()) {
            a.say("stopped waiting out the rate limit — the next request goes when you ask", .{});
            return;
        }
        const s = a.budget.snapshot(a.nowSecs());
        var buf: [48]u8 = undefined;
        a.setStatus("API budget {s} · today {d} · yesterday {d} · 7 days {d}", .{ s.chipWords(&buf), s.today, s.yesterday, s.week });
    }

    /// `Shift+N`: dry run on / off for this session.
    pub fn toggleDryRun(a: *App) void {
        if (a.budget.toggleDry()) {
            a.say("dry run on — nothing is sent; the pane shows what it already holds", .{});
        } else a.say("dry run off — requests go out again", .{});
    }

    pub fn nowMs(a: *App) i64 {
        return Io.Timestamp.now(a.io, .real).toMilliseconds();
    }

    /// Wall-clock seconds — the clock a build line's age is measured
    /// against. A test pins `now_secs` so its ages do not drift with
    /// the day it runs on.
    pub fn nowSecs(a: *App) i64 {
        if (a.now_secs != 0) return a.now_secs;
        return @divFloor(a.nowMs(), 1000);
    }

    pub fn tab(a: *App) *TabState {
        return &a.tabs[a.active];
    }

    pub fn tabConst(a: *const App) *const TabState {
        return &a.tabs[a.active];
    }

    pub fn hasTabs(a: *const App) bool {
        return a.tabs.len > 0;
    }

    pub fn context(a: *const App) keymap.Context {
        const t = a.tabConst();
        return .{ .shape = t.shape(), .fix_versions = t.cfg.isFixVersions(), .editable_jql = t.cfg.isEditableJql(), .detail_open = a.details_visible };
    }

    pub fn isKanban(a: *const App) bool {
        return a.hasTabs() and a.tabConst().cfg.isKanban();
    }

    pub fn isTree(a: *const App) bool {
        return a.hasTabs() and a.tabConst().cfg.isTree();
    }

    /// The tree's team field as the JQL wants it.
    fn teamClause(a: *App, arena: Allocator, base: []const u8, team: []const u8) Allocator.Error![]const u8 {
        if (team.len == 0) return base;
        return jira.withTeam(arena, base, team, a.cfg.team_field_name, a.cfg.team_field_id);
    }

    fn teamFilterClause(a: *App, arena: Allocator, team: []const u8) Allocator.Error![]const u8 {
        const t = try jira.escapeQuotes(arena, team);
        const field = a.cfg.teamField();
        if (field.len > 0) return std.fmt.allocPrint(arena, "(\"{s}\" = \"{s}\" OR component = \"{s}\" OR labels = \"{s}\")", .{ field, t, t, t });
        return std.fmt.allocPrint(arena, "(component = \"{s}\" OR labels = \"{s}\")", .{ t, t });
    }

    // ─── the visible rows ────────────────────────────────────────────────

    pub fn criteria(a: *App, arena: Allocator, t: *const TabState) Allocator.Error!filters.Criteria {
        return .{
            .text = if (a.filter) |f| f.edit.text() else "",
            .assignees = try t.activeIds(arena),
            .epics = try t.activeEpics(arena),
            .issue_type = t.issue_type,
            .label = t.label,
            .team = if (t.cfg.isKanban()) t.team else "",
            .scope = t.scope,
        };
    }

    pub fn mask(a: *App, arena: Allocator, t: *const TabState) Allocator.Error![]const bool {
        return filters.mask(arena, t.issues, try a.criteria(arena, t));
    }

    /// The tree rows of the active tab (null on a kanban / flat tab).
    pub fn treeRows(a: *App, arena: Allocator) Allocator.Error!?Rows {
        const t = a.tab();
        if (!t.cfg.isTree()) return null;
        const st = &(t.tree.?);
        return try tree.computeRows(arena, t.issues, st, t.cfg, a.cfg.release_cut, try a.mask(arena, t));
    }

    /// The issue indices a flat or kanban tab shows, in order.
    pub fn visibleIssues(a: *App, arena: Allocator) Allocator.Error![]const usize {
        const t = a.tab();
        const m = try a.mask(arena, t);
        var out: std.ArrayList(usize) = .empty;
        for (m, 0..) |ok, i| if (ok) try out.append(arena, i);
        return out.toOwnedSlice(arena);
    }

    /// The issues of the tab the statusline figure counts — what the
    /// chip's hover rows are built from, so the publish the pane makes
    /// for itself lists the same tickets a `--values` run would for the
    /// same listing. Empty until that tab has loaded.
    pub fn assignedIssues(a: *const App) []const Issue {
        const i = a.assigned_tab orelse return &.{};
        if (i >= a.tabs.len) return &.{};
        return a.tabs[i].issues;
    }

    pub fn focusedIssueIdx(a: *App, arena: Allocator) Allocator.Error!?usize {
        if (!a.hasTabs()) return null;
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(arena)) orelse return null;
            if (t.selected >= r.rows.len) return null;
            return r.rows[t.selected].issueIdx();
        }
        if (t.selected >= t.issues.len) return null;
        return t.selected;
    }

    pub fn focusedKey(a: *App, arena: Allocator) Allocator.Error!?[]const u8 {
        const idx = (try a.focusedIssueIdx(arena)) orelse return null;
        return a.tab().issues[idx].key;
    }

    pub fn focusedRow(a: *App, arena: Allocator) Allocator.Error!?tree.Row {
        const r = (try a.treeRows(arena)) orelse return null;
        const t = a.tab();
        if (t.selected >= r.rows.len) return null;
        return r.rows[t.selected];
    }

    // ─── the loop's entry points ─────────────────────────────────────────

    pub fn resize(a: *App, cols: u16, rows: u16) void {
        a.cols = cols;
        a.rows = rows;
    }

    /// The auto-refresh, on the reference's cadence.
    pub fn tick(a: *App, now: i64) Allocator.Error!void {
        defer a.budget.setFeed(a.watch.state(now));
        if (!a.hasTabs() or a.last_refresh_ms == 0) return;
        // One refetch at a time: while one is out, the feed's lines
        // stay in its file for the next look.
        if (a.refresh.busy()) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const look = try a.watch.look(scratch.allocator(), now);
        if (look.sweep) {
            // The interval is the commonest refetch of all and the one
            // nobody is watching: a window, like `r`.
            try a.refreshTabMode(a.active, .delta);
            a.last_refresh_ms = now;
            a.watch.started(now);
        } else if (look.changed.len > 0) {
            try a.feedChanged(look.changed);
        }
    }

    /// The reader did something — a key, a click, the wheel, a paste,
    /// the pane taking focus: the poller comes back to its base.
    pub fn touched(a: *App) void {
        a.watch.touch();
    }

    /// The tickets an event feed named: one search for all of them,
    /// inside the active tab's own query, merged in like a window.
    pub fn feedChanged(a: *App, changes: []const sdk.feed.Change) Allocator.Error!void {
        const t = a.tab();
        if (!t.fetched) return;
        // A board is asked through the agile endpoint, whose query is a
        // list of clauses: it is swept whole instead.
        if (t.board_id != 0 or t.deltas.items.len >= max_delta_generations) {
            try a.refreshTabMode(a.active, .full);
            return;
        }
        var job = (try a.prepareRefresh(a.active, .full)) orelse return;
        const ar = job.arena.allocator();
        var q: Io.Writer.Allocating = .init(ar);
        q.writer.print("({s}) AND key in (", .{job.base_jql}) catch return error.OutOfMemory;
        const keys = try ar.alloc([]const u8, changes.len);
        var n: usize = 0;
        for (changes) |c| {
            // A key is letters, digits, `-` and `_`: anything else is
            // not one and is not spliced into a query.
            const ok = c.key.len > 0 and for (c.key) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break false;
            } else true;
            if (!ok) continue;
            if (n > 0) q.writer.writeAll(", ") catch return error.OutOfMemory;
            q.writer.print("\"{s}\"", .{c.key}) catch return error.OutOfMemory;
            keys[n] = try ar.dupe(u8, c.key);
            n += 1;
        }
        if (n == 0) {
            job.deinit();
            return;
        }
        q.writer.writeAll(")") catch return error.OutOfMemory;
        job.jql = q.written();
        job.feed_keys = keys[0..n];
        job.reason = .delta;
        a.feed_fetches += @intCast(n);
        try a.runJob(job);
    }

    /// Fetch the active tab if it has not been.
    pub fn ensureLoaded(a: *App) Allocator.Error!void {
        if (!a.hasTabs()) return;
        if (!a.tab().fetched and a.tab().last_error.len == 0) try a.refreshActive();
    }

    // ─── refreshing ──────────────────────────────────────────────────────

    fn ensureMe(a: *App) Allocator.Error!void {
        if (a.me != null or a.me_failed) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        // This runs on the paint loop: a 429 must not park it in the
        // pause's wait (the chip could not say `paused until` from a
        // loop that is asleep), so this one call answers at once — and
        // a 429 is not a refusal: `me` is asked again on the next fetch.
        var c = a.client.*;
        c.wait_pauses = false;
        switch (jira.myself(&c, scratch.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => {
                a.me_failed = true;
                return;
            },
        }) {
            .ok => |u| a.me = .{ .account_id = try a.keep(u.account_id), .display_name = try a.keep(u.display_name) },
            .failed => |f| if (f.status != 429) {
                a.me_failed = true;
            },
        }
    }

    /// A refetch nobody asked for by name: after a write this pane
    /// made, after a picker, after a filter. Always the whole listing.
    ///
    /// A window cannot notice a ticket that has dropped OUT of the
    /// query, and a write is exactly the thing that drops one out —
    /// reassign a ticket away from yourself and the Assigned tab must
    /// lose it. So only `r` and the interval ask for a window; anything
    /// that might have changed the row SET asks for the listing.
    pub fn refreshActive(a: *App) Allocator.Error!void {
        try a.refreshActiveMode(.full);
    }

    /// The active tab, as a delta where one is possible (`r`, the
    /// interval) or as the whole listing (`R`).
    pub fn refreshActiveMode(a: *App, mode: RefreshMode) Allocator.Error!void {
        if (!a.hasTabs()) return;
        try a.refreshTabMode(a.active, mode);
        a.last_refresh_ms = a.nowMs();
        // A refetch somebody asked for is a poll, and a sign somebody is
        // looking: the poller starts over from its base.
        a.watch.touch();
        a.watch.started(a.last_refresh_ms);
    }

    /// Start a refetch of `idx`. With a group it goes to a worker and
    /// this returns at once — the pane keeps its old rows, its keys and
    /// its repaint while the site is asked. Without one it runs inline.
    pub fn refreshTab(a: *App, idx: usize) Allocator.Error!void {
        try a.refreshTabMode(idx, .full);
    }

    pub fn refreshTabMode(a: *App, idx: usize, mode: RefreshMode) Allocator.Error!void {
        const job = (try a.prepareRefresh(idx, mode)) orelse return;
        try a.runJob(job);
    }

    /// Hand a prepared refetch to a worker, or run it here with no
    /// group.
    fn runJob(a: *App, job_in: RefreshJob) Allocator.Error!void {
        var job = job_in;
        if (a.group) |g| {
            if (!a.refresh.claim()) {
                // One is already in flight; a second would only race it.
                job.deinit();
                return;
            }
            g.concurrent(a.io, refreshWorker, .{ a.io, a.gpa, &a.refresh, job }) catch {
                a.refresh.abandon();
                job.deinit();
                return;
            };
            return;
        }
        var res = runRefresh(job);
        try a.applyRefresh(&res);
        // No group is no loop to spread the linked-PR calls over — a
        // test and `--dump` want the rows the pane reaches a moment
        // later, so they all happen here.
        try a.drainPrQueue();
    }

    /// What a refetch needs, read off the tab before anything can move:
    /// the identity to search as, the query, and where the cursor is.
    /// Null when the tab cannot be searched at all.
    fn prepareRefresh(a: *App, idx: usize, mode: RefreshMode) Allocator.Error!?RefreshJob {
        const t = &a.tabs[idx];
        try a.ensureMe();
        // The reference seeds the assignee filter with "me" once; on its
        // tree tabs the filter is inert, so the seed only lands where it
        // shows (flat and kanban) — here the chips work on trees too.
        if (!t.seeded and (a.me != null or a.me_failed)) {
            if (a.me) |me| if (!t.cfg.isTree() and t.active_assignees.count() == 0 and me.account_id.len > 0) try t.active_assignees.put(a.gpa, me.account_id, {});
            t.seeded = true;
        }
        if (t.jql.len == 0) try a.resolveJql(t);
        // The cursor survives a refetch: remember the ticket it is on.
        a.keep_key_len = 0;
        if (idx == a.active) {
            var pre = std.heap.ArenaAllocator.init(a.gpa);
            defer pre.deinit();
            if (try a.focusedKey(pre.allocator())) |k| if (k.len <= a.keep_key_buf.len) {
                @memcpy(a.keep_key_buf[0..k.len], k);
                a.keep_key_len = k.len;
            };
        }
        var job: RefreshJob = .{
            .idx = idx,
            .client = a.client.*,
            .arena = std.heap.ArenaAllocator.init(a.gpa),
            .jql = "",
            .board_id = t.board_id,
            .extra_jql = null,
            .extra_fields = &.{},
            .team_field_id = a.cfg.team_field_id,
            .reason = if (t.fetched) .refresh else .pane_open,
            .recent_root = a.recent_root,
            .refresh_interval_secs = a.cfg.refresh_interval_secs,
        };
        errdefer job.deinit();
        const arena = job.arena.allocator();
        job.listing = try std.fmt.allocPrint(arena, "tab:{s}", .{t.cfg.name});
        if (t.cfg.isFixVersions()) if (@import("screen.zig").fixVersionOf(t.jql)) |name| {
            job.release_project = try arena.dupe(u8, t.cfg.project);
            job.release_name = try arena.dupe(u8, name);
        };
        // A board tab is fetched through the agile endpoint, whose
        // query is a list of clauses rather than one JQL string — the
        // window would have to be spliced somewhere else, so it is not
        // offered there rather than offered and silently ignored.

        // On the job's arena, not a temporary: the job outlives this
        // frame the moment it goes to a worker.
        if (a.cfg.team_field_id.len > 0) {
            const one = try arena.alloc([]const u8, 1);
            one[0] = a.cfg.team_field_id;
            job.extra_fields = one;
        }
        if (t.board_id != 0) {
            var clauses: std.ArrayList([]const u8) = .empty;
            if (t.team.len > 0) try clauses.append(arena, try a.teamFilterClause(arena, t.team));
            if (t.selected_sprint) |sp| try clauses.append(arena, try std.fmt.allocPrint(arena, "sprint = {d}", .{sp}));
            if (t.quick_filters) |qfs| for (qfs) |qf| {
                for (t.active_quick_filters.items) |id| if (id == qf.id and std.mem.trim(u8, qf.jql, " ").len > 0) {
                    try clauses.append(arena, try std.fmt.allocPrint(arena, "({s})", .{std.mem.trim(u8, qf.jql, " ")}));
                };
            };
            if (clauses.items.len > 0) job.extra_jql = try std.mem.join(arena, " AND ", clauses.items);
        } else {
            const base = try arena.dupe(u8, try a.teamClause(arena, t.jql, t.team));
            // A board tab is fetched through the agile endpoint, whose
            // query is a list of clauses rather than one JQL string, so
            // a window is not offered there rather than offered and
            // silently ignored.
            if (mode == .delta and t.issues.len <= max_departure_keys) {
                if (try a.deltaWindow(arena, t, base)) |since| {
                    job.delta_since = since;
                    job.reason = .delta;
                    const keys = try arena.alloc([]const u8, t.issues.len);
                    for (t.issues, keys) |iss, *k| k.* = try arena.dupe(u8, iss.key);
                    job.shown_keys = keys;
                }
            }
            job.base_jql = base;
            job.jql = try arena.dupe(u8, try jira.withUpdatedSince(arena, base, job.delta_since));
        }
        return job;
    }

    /// The whole of a refetch, on whichever thread runs it: the search,
    /// then one linked-PR call per unresolved ticket on a tree tab. It
    /// touches nothing but its own job and its own arena.
    pub fn runRefresh(job_in: RefreshJob) RefreshResult {
        var job = job_in;
        // The job's arena holds the query and the extra fields, so it is
        // freed only after the last call that reads them.
        defer job.deinit();
        var client = job.client;
        var arena = std.heap.ArenaAllocator.init(job.arena.child_allocator);
        const ar = arena.allocator();
        const answer: jira.Answer([]const Value) = blk: {
            if (job.board_id != 0) {
                break :blk jira.boardIssues(&client, ar, job.board_id, job.extra_jql, job.extra_fields, job.reason) catch
                    jira.Answer([]const Value){ .failed = .{ .status = 0, .message = "the site did not answer" } };
            }
            break :blk jira.search(&client, ar, job.jql, job.extra_fields, job.reason) catch
                jira.Answer([]const Value){ .failed = .{ .status = 0, .message = "the site did not answer" } };
        };
        switch (answer) {
            .failed => |f| {
                recent.failed(job.arena.child_allocator, client.io, job.recent_root);
                const msg = ar.dupe(u8, f.message) catch "out of memory";
                return .{ .idx = job.idx, .arena = arena, .error_text = msg };
            },
            .ok => |vals| {
                var issues = jira.parseIssues(ar, vals, job.team_field_id) catch {
                    return .{ .idx = job.idx, .arena = arena, .error_text = "out of memory" };
                };
                var delta = job.delta_since.len > 0;
                var departed: []const []const u8 = &.{};
                if (job.feed_keys.len > 0) {
                    // The feed's tickets that the tab's query no longer
                    // answers for have left it.
                    var gone: std.ArrayList([]const u8) = .empty;
                    for (job.feed_keys) |k| {
                        const still = for (issues) |iss| {
                            if (std.mem.eql(u8, iss.key, k)) break true;
                        } else false;
                        if (!still) gone.append(ar, ar.dupe(u8, k) catch "") catch {};
                    }
                    const base = ar.dupe(u8, job.base_jql) catch "";
                    _ = recent.publish(job.arena.child_allocator, client.io, job.recent_root, job.listing, false, job.refresh_interval_secs, issues);
                    return .{ .idx = job.idx, .arena = arena, .issues = issues, .delta = true, .base_jql = base, .departed = gone.items, .feed = true };
                }
                if (delta and job.shown_keys.len > 0) {
                    switch (departures(&client, ar, job, issues)) {
                        .ok => |d| departed = d,
                        // The site would not answer the key list (a
                        // ticket on screen was deleted, and Jira refuses
                        // a `key in` naming one): ask for the whole
                        // listing instead, which cannot be wrong.
                        .failed => {
                            const whole = jira.search(&client, ar, job.base_jql, job.extra_fields, job.reason) catch
                                jira.Answer([]const Value){ .failed = .{ .status = 0, .message = "the site did not answer" } };
                            switch (whole) {
                                .failed => |f| return .{ .idx = job.idx, .arena = arena, .error_text = ar.dupe(u8, f.message) catch "out of memory" },
                                .ok => |all| issues = jira.parseIssues(ar, all, job.team_field_id) catch {
                                    return .{ .idx = job.idx, .arena = arena, .error_text = "out of memory" };
                                },
                            }
                            delta = false;
                        },
                    }
                }
                // The linked PRs are NOT fetched here. One dev-status
                // call per unresolved ticket used to happen before the
                // first paint — twenty-five of them on a real tab, each
                // waiting its turn on the bucket, which is the minute
                // of `loading…` this pane was reported for. They are
                // seeded from the cache and queued behind the paint
                // instead (`applyRefresh`, `pumpPrs`).
                const base = ar.dupe(u8, job.base_jql) catch "";
                // The listing as the shared cache's: whole unless this
                // was a window onto it.
                _ = recent.publish(job.arena.child_allocator, client.io, job.recent_root, job.listing, !delta, job.refresh_interval_secs, issues);
                if (!delta and job.release_name.len > 0) _ = recent.publishReleaseKeys(job.arena.child_allocator, client.io, job.recent_root, job.release_project, job.release_name, job.refresh_interval_secs, issues);
                return .{ .idx = job.idx, .arena = arena, .issues = issues, .delta = delta, .base_jql = base, .departed = departed };
            },
        }
    }

    /// The rows on screen that moved in the window and are not in the
    /// window's answer to the query: they left it. One search, keys
    /// only in effect — `key in (…) AND updated >= <window>`.
    fn departures(client: *jira.Client, ar: Allocator, job: RefreshJob, still: []const Issue) union(enum) { ok: []const []const u8, failed } {
        var q: Io.Writer.Allocating = .init(ar);
        q.writer.writeAll("key in (") catch return .failed;
        for (job.shown_keys, 0..) |k, i| {
            if (i > 0) q.writer.writeAll(", ") catch return .failed;
            q.writer.print("\"{s}\"", .{k}) catch return .failed;
        }
        q.writer.writeAll(")") catch return .failed;
        const jql = jira.withUpdatedSince(ar, q.written(), job.delta_since) catch return .failed;
        const answer = jira.search(client, ar, jql, job.extra_fields, job.reason) catch return .failed;
        const vals = switch (answer) {
            .failed => return .failed,
            .ok => |v| v,
        };
        const moved = jira.parseIssues(ar, vals, job.team_field_id) catch return .failed;
        var out: std.ArrayList([]const u8) = .empty;
        for (moved) |m| {
            const kept = for (still) |s_| {
                if (std.mem.eql(u8, s_.key, m.key)) break true;
            } else false;
            if (!kept) out.append(ar, m.key) catch return .failed;
        }
        return .{ .ok = out.items };
    }

    /// The worker task. Everything it needs is in the job; the only
    /// thing it touches of the App's is the slot, which is a channel.
    fn refreshWorker(io: Io, gpa: Allocator, slot: *RefreshSlot, job: RefreshJob) Io.Cancelable!void {
        _ = gpa;
        const res = runRefresh(job);
        slot.finish(io, res) catch |err| {
            // The pane is going away, or this task was cancelled: the
            // result has nowhere to go, so it is freed here rather than
            // leaked, and a cancel is passed on rather than swallowed.
            res.drop();
            if (err == error.Canceled) return error.Canceled;
            return;
        };
    }

    // ─── linked PRs, behind the paint ────────────────────────────────

    /// Auto-expand the unresolved tickets, paint whatever the cache
    /// still stands behind, and queue the rest in screen order.
    ///
    /// The cache is keyed on the ticket's OWN `updated` stamp, which
    /// the search already carried: a ticket that has not moved since
    /// the last run needs no request at all, this run or any later
    /// one. That is what turns a refetch with nothing changed from
    /// twenty-six requests into one.
    fn seedPrs(a: *App, t: *TabState, st: *tree.State) Allocator.Error!void {
        a.pr_queue.clearRetainingCapacity();
        var still_shown: std.ArrayListUnmanaged([]const u8) = .empty;
        defer still_shown.deinit(a.gpa);
        for (t.issues) |iss| {
            if (!iss.isUnresolved()) continue;
            try st.setExpanded(iss.key, true);
            if (iss.id.len == 0) continue;
            try still_shown.append(a.gpa, iss.key);
            if (st.prs(iss.key) != null) continue;
            if (a.pr_store) |store| {
                if (store.fresh(iss.key, iss.updated)) |body| {
                    // A read the store answered: a hit on the budget's
                    // ratio, the way a 304 is on the forge pane's.
                    if (a.applyPrBody(st, iss.key, body)) {
                        a.budget.noteHit();
                        continue;
                    } else |err| if (err == error.OutOfMemory) return err;
                }
            }
            try a.pr_queue.append(a.gpa, try a.keep(iss.key));
        }
        // The file tracks the tickets the tab still shows rather than
        // every ticket ever seen.
        if (a.pr_store) |store| {
            store.retain(still_shown.items);
            store.save();
        }
    }

    /// One cached dev-status answer onto the tree.
    fn applyPrBody(a: *App, st: *tree.State, key: []const u8, body: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const list = try jira.parsePullRequests(scratch.allocator(), body);
        try st.putPrs(key, list);
    }

    /// Start the next queued linked-PR fetch, if the slot is free and
    /// the tab it belongs to is the one on screen. One at a time: the
    /// point is to spend the budget in the order the reader will look,
    /// not to fire twenty-five at once.
    pub fn pumpPrs(a: *App) Allocator.Error!void {
        if (a.pr_queue.items.len == 0 or a.prs.busy()) return;
        const t = a.tab();
        const st = &(t.tree orelse {
            a.pr_queue.clearRetainingCapacity();
            return;
        });
        // Drop anything the tab no longer shows, or already has.
        while (a.pr_queue.items.len > 0) {
            const key = a.pr_queue.items[0];
            const iss = blk: {
                for (t.issues) |i| if (std.mem.eql(u8, i.key, key)) break :blk i;
                break :blk null;
            };
            if (iss == null or st.prs(key) != null) {
                _ = a.pr_queue.orderedRemove(0);
                continue;
            }
            return a.startPrFetch(key, iss.?);
        }
    }

    /// Fetch every queued linked-PR row now, inline — what `--dump`
    /// and a test use, where there is no loop to spread them over.
    pub fn drainPrQueue(a: *App) Allocator.Error!void {
        var guard: usize = 0;
        while (a.pr_queue.items.len > 0 and guard < 1000) : (guard += 1) try a.pumpPrs();
    }

    fn startPrFetch(a: *App, key: []const u8, iss: Issue) Allocator.Error!void {
        var job: PrJob = .{
            .arena = std.heap.ArenaAllocator.init(a.gpa),
            .client = a.client.*,
            .key = "",
            .issue_id = "",
            .updated = "",
        };
        errdefer job.deinit();
        const ar = job.arena.allocator();
        job.key = try ar.dupe(u8, key);
        job.issue_id = try ar.dupe(u8, iss.id);
        job.updated = try ar.dupe(u8, iss.updated);
        _ = a.pr_queue.orderedRemove(0);
        if (a.group) |g| {
            if (!a.prs.claim()) {
                job.deinit();
                return;
            }
            g.concurrent(a.io, prWorker, .{ a.io, &a.prs, job }) catch {
                a.prs.abandon();
                job.deinit();
                return;
            };
            return;
        }
        var res = runPrJob(job);
        try a.applyPrResult(&res);
    }

    /// The whole of one dev-status call, on whichever thread runs it.
    pub fn runPrJob(job_in: PrJob) PrResult {
        var job = job_in;
        defer job.deinit();
        var client = job.client;
        var arena = std.heap.ArenaAllocator.init(job.arena.child_allocator);
        const ar = arena.allocator();
        const key = ar.dupe(u8, job.key) catch "";
        const updated = ar.dupe(u8, job.updated) catch "";
        const raw = jira.pullRequestsRaw(&client, ar, job.issue_id, .refresh) catch
            return .{ .arena = arena, .key = key, .updated = updated };
        const body = raw orelse return .{ .arena = arena, .key = key, .updated = updated };
        const list = jira.parsePullRequests(ar, body) catch &.{};
        return .{ .arena = arena, .key = key, .updated = updated, .list = list, .body = body };
    }

    fn prWorker(io: Io, slot: *PrSlot, job: PrJob) Io.Cancelable!void {
        const res = runPrJob(job);
        slot.finish(io, res) catch |err| {
            res.drop();
            if (err == error.Canceled) return error.Canceled;
            return;
        };
    }

    /// Take a finished linked-PR fetch, if one has landed.
    pub fn drainPrs(a: *App) Allocator.Error!void {
        var res = a.prs.take(a.io) orelse return;
        try a.applyPrResult(&res);
    }

    fn applyPrResult(a: *App, res: *PrResult) Allocator.Error!void {
        defer res.drop();
        const t = a.tab();
        const st = &(t.tree orelse return);
        // The ticket's `loading…` row becomes its PRs, or nothing, and
        // every row under it moves. The result lands behind the paint,
        // after whatever keys came first — an End that reached the
        // `Show older` row a moment ago must still be on it, not on the
        // row that slid into its index or past the end of the list.
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const was = try a.focusedRow(scratch.allocator());
        try st.putPrs(res.key, res.list);
        if (was) |row| try a.keepCursorOn(scratch.allocator(), row);
        // A failure is never cached: it must cost one retry, not a run.
        if (res.body.len > 0 and res.updated.len > 0) {
            if (a.pr_store) |store| {
                try store.put(res.key, res.updated, res.body, Io.Timestamp.now(a.io, .real).toSeconds());
                store.save();
            }
        }
    }

    /// The rows a delta leaves on screen: everything the tab already
    /// had, with the ones that moved replaced in place, and the ones
    /// that are new appended. Order is the old order — a window says
    /// nothing about where a new ticket belongs in the server's sort,
    /// and re-sorting on a guess is worse than the next full refetch
    /// putting it right.
    ///
    /// The slice is built on `arena` (the delta generation's own);
    /// every string in it still lives on whichever arena it came from,
    /// which is why those are kept until a full refetch.
    fn mergeDelta(arena: Allocator, old: []const Issue, moved: []const Issue, departed: []const []const u8) Allocator.Error![]const Issue {
        var out: std.ArrayListUnmanaged(Issue) = .empty;
        try out.ensureTotalCapacity(arena, old.len + moved.len);
        for (old) |o| {
            // Moved out of the query since the last look: gone.
            const left = for (departed) |d| {
                if (std.mem.eql(u8, d, o.key)) break true;
            } else false;
            if (left) continue;
            var replaced = o;
            for (moved) |m| {
                if (m.key.len > 0 and std.mem.eql(u8, m.key, o.key)) replaced = m;
            }
            out.appendAssumeCapacity(replaced);
        }
        for (moved) |m| {
            var seen = false;
            for (old) |o| {
                if (m.key.len > 0 and std.mem.eql(u8, m.key, o.key)) seen = true;
            }
            if (!seen) out.appendAssumeCapacity(m);
        }
        return out.toOwnedSlice(arena);
    }

    /// What a listing is, for telling one poll from the next: every
    /// ticket's key, `updated` stamp, status and summary, in order.
    pub fn issuesDigest(issues: []const Issue) u64 {
        var h = std.hash.Wyhash.init(0);
        for (issues) |iss| {
            h.update(iss.key);
            h.update("\x00");
            h.update(iss.updated);
            h.update("\x00");
            h.update(iss.status);
            h.update("\x00");
            h.update(iss.summary);
            h.update("\x01");
        }
        return h.final();
    }

    /// Take a finished refetch, if one has landed, and apply it.
    pub fn drainRefresh(a: *App) Allocator.Error!void {
        var res = a.refresh.take(a.io) orelse return;
        try a.applyRefresh(&res);
    }

    /// Swap a refetch's rows in. The only place the tab's data changes,
    /// and always on the loop.
    fn applyRefresh(a: *App, res: *RefreshResult) Allocator.Error!void {
        const idx = res.idx;
        if (idx >= a.tabs.len) {
            res.drop();
            return;
        }
        const t = &a.tabs[idx];
        // A dry run over rows already on screen: nothing was sent and
        // nothing failed. The rows, the count, `as of` and the DRY chip
        // stay; the message line says so — the Bitbucket pane's answer to
        // the same refresh. (With nothing fetched yet there is nothing to
        // keep, and the empty tab says why below.)
        if (res.error_text.len > 0 and t.fetched and std.mem.eql(u8, res.error_text, jira.Client.dry_run_message)) {
            a.say("dry run on — nothing sent; the pane keeps what it already shows", .{});
            res.drop();
            return;
        }
        if (res.error_text.len > 0) {
            // The machine's shared bucket skipped this round: nothing
            // was sent, the rows stand, and the next round asks again.
            if (sdk.budget.isBucketRefusal(res.error_text)) {
                a.setStatus("waiting on the shared rate-limit bucket — this round was skipped, nothing was sent", .{});
                res.drop();
                return;
            }
            t.last_error = try std.fmt.allocPrint(t.meta.allocator(), "{s}", .{res.error_text});
            a.sayWithAction(retry_action, "error: {s}", .{res.error_text});
            res.drop();
            return;
        }
        if (res.delta and t.fetched) {
            // A window: what came back is what MOVED, and the rest is
            // still on the arenas already held. Merge by key onto the
            // new arena and keep the old ones alive under it.
            t.issues = try mergeDelta(res.arena.allocator(), t.issues, res.issues, res.departed);
            try t.deltas.append(a.gpa, res.arena);
        } else {
            t.issues = res.issues;
            t.dropDeltas();
            t.data.deinit();
            t.data = res.arena;
            // Only a whole listing dates the tab: a window says nothing
            // about the rows it did not ask about.
            a.markSynced(t, res.base_jql, a.nowSecs());
        }
        t.fetched = true;
        t.fetched_at = a.nowSecs();
        t.last_error = "";
        // The adaptive poller (`sdk.feed`): the same rows back is a
        // quiet poll, different rows a change. A feed's own answer is
        // neither — it only ever asked about what it named.
        const digest = issuesDigest(t.issues);
        if (!res.feed and idx == a.active) a.watch.settled(if (t.digest) |d| d != digest else true);
        t.digest = digest;
        if (res.feed) a.setStatus("{d} {s} changed — updated from the event feed", .{ res.issues.len + res.departed.len, sdk.pane.text.noun(res.issues.len + res.departed.len, "ticket", "tickets") });
        // An action's message outlives the refetch it triggers;
        // an empty status gets the tab's summary.
        if (a.status.items.len == 0) a.setStatus("{s} · {d} {s}", .{ t.cfg.name, t.issues.len, sdk.pane.text.noun(t.issues.len, "issue", "issues") });
        if (t.cfg.kind) |k| if (k.isAssignedOpen()) {
            a.assigned_open = t.issues.len;
            a.assigned_tab = idx;
            a.segment_dirty = true;
        };
        // The reference auto-expands unresolved tickets on tree tabs
        // and shows their linked PRs. What is already known — because
        // the ticket has not moved since the last run — is painted
        // now, for nothing; the rest is queued to arrive behind the
        // paint rather than in front of it.
        if (t.tree) |*st| if (t.cfg.isTree()) try a.seedPrs(t, st);
        if (t.sprints == null and t.board_id != 0) try a.loadSprints(idx);
        try a.aggregateAssignees(t);
        // Put the cursor back on the ticket it was on (its row may have
        // moved), else on the first row.
        if (idx == a.active) {
            const keep_key: ?[]const u8 = if (a.keep_key_len > 0) a.keep_key_buf[0..a.keep_key_len] else null;
            if (t.cfg.isTree()) {
                t.selected = 0;
                if (keep_key) |k| {
                    var post = std.heap.ArenaAllocator.init(a.gpa);
                    defer post.deinit();
                    if (try a.treeRows(post.allocator())) |r| if (tree.rowOfKey(r.rows, t.issues, k)) |ri| {
                        t.selected = ri;
                    };
                }
            } else {
                t.selected = 0;
                if (keep_key) |k| for (t.issues, 0..) |iss, i| if (std.mem.eql(u8, iss.key, k)) {
                    t.selected = i;
                };
                try a.clampCursor();
            }
        }
        // A `--focus` is answered by the listing it was waiting for:
        // the active tab's, which is the one the reader is looking at.
        try a.tryFocus(idx == a.active);
    }

    /// `--prefetch`'s JSON (`{"generated_at":…,"tabs":[{"name":…,"issues":[…]}]}`)
    /// into the tabs it names, so the first paint has tickets before any
    /// fetch; returns how many tabs took it.
    pub fn hydrate(a: *App, src: []const u8) Allocator.Error!usize {
        var n: usize = 0;
        for (a.tabs, 0..) |*t, idx| {
            var next = std.heap.ArenaAllocator.init(a.gpa);
            errdefer next.deinit();
            const arena = next.allocator();
            const doc = std.json.parseFromSliceLeaky(Value, arena, src, .{}) catch {
                next.deinit();
                return n;
            };
            const tabs_v = switch (doc) {
                .object => |o| o.get("tabs") orelse {
                    next.deinit();
                    return n;
                },
                else => {
                    next.deinit();
                    return n;
                },
            };
            const list = switch (tabs_v) {
                .array => |arr| arr.items,
                else => &.{},
            };
            var took = false;
            for (list) |tv| {
                const name = switch (tv) {
                    .object => |o| if (o.get("name")) |nv| (if (nv == .string) nv.string else "") else "",
                    else => "",
                };
                if (!std.mem.eql(u8, name, t.cfg.name)) continue;
                const issues_v = tv.object.get("issues") orelse continue;
                const vals = switch (issues_v) {
                    .array => |arr| arr.items,
                    else => continue,
                };
                t.issues = try jira.parseIssues(arena, vals, a.cfg.team_field_id);
                t.data.deinit();
                t.data = next;
                t.fetched = true;
                t.last_error = "";
                took = true;
                n += 1;
                if (t.cfg.kind) |k| if (k.isAssignedOpen()) {
                    a.assigned_open = t.issues.len;
                    a.assigned_tab = idx;
                    a.segment_dirty = true;
                };
                if (t.tree) |*st| if (t.cfg.isTree()) {
                    for (t.issues) |iss| if (iss.isUnresolved()) try st.setExpanded(iss.key, true);
                };
                try a.aggregateAssignees(t);
                break;
            }
            if (!took) next.deinit();
        }
        return n;
    }

    fn resolveJql(a: *App, t: *TabState) Allocator.Error!void {
        const mode = t.cfg.mode orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const versions = switch (jira.projectVersions(a.client, arena, t.cfg.project) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer([]const model.Version){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |v| v,
            .failed => |f| {
                recent.releasesFailed(a.gpa, a.io, a.recent_root);
                t.jql = "issuekey = ''";
                t.last_error = try std.fmt.allocPrint(t.meta.allocator(), "fetching unreleased versions: {s}", .{f.message});
                return;
            },
        };
        _ = recent.publishReleases(a.gpa, a.io, a.recent_root, t.cfg.project, versions, a.recent_current_release, a.cfg.refresh_interval_secs);
        const open = try jira.unreleasedVersions(arena, versions, t.cfg.version_name_contains);
        const picked = jira.pickVersion(open, mode) orelse {
            t.jql = "issuekey = ''";
            t.last_error = try t.meta.allocator().dupe(u8, "no unreleased versions match (check version_name_contains)");
            return;
        };
        t.jql = try a.keep(try jira.fixVersionJql(arena, t.cfg.project, picked.name, t.cfg.component));
    }

    fn loadSprints(a: *App, idx: usize) Allocator.Error!void {
        const t = &a.tabs[idx];
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (jira.sprintsForBoard(a.client, scratch.allocator(), t.board_id) catch return) {
            .ok => |list| {
                const copy = try t.meta.allocator().alloc(model.Sprint, list.len);
                for (list, copy) |src, *dst| dst.* = .{
                    .id = src.id,
                    .name = try t.meta.allocator().dupe(u8, src.name),
                    .state = try t.meta.allocator().dupe(u8, src.state),
                    .start_date = try t.meta.allocator().dupe(u8, src.start_date),
                    .end_date = try t.meta.allocator().dupe(u8, src.end_date),
                    .complete_date = try t.meta.allocator().dupe(u8, src.complete_date),
                };
                t.sprints = copy;
            },
            .failed => {},
        }
    }

    fn aggregateAssignees(a: *App, t: *TabState) Allocator.Error!void {
        const me_id = if (a.me) |m| m.account_id else "";
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        var list: std.ArrayList(AssigneeSummary) = .empty;
        for (t.issues) |iss| {
            const u = iss.assignee orelse continue;
            if (u.account_id.len == 0 or std.mem.eql(u8, u.account_id, me_id)) continue;
            var found = false;
            for (list.items) |*s| if (std.mem.eql(u8, s.account_id, u.account_id)) {
                s.count += 1;
                found = true;
            };
            if (!found) try list.append(scratch.allocator(), .{ .account_id = u.account_id, .display_name = u.display_name, .count = 1 });
        }
        std.mem.sort(AssigneeSummary, list.items, {}, struct {
            fn lt(_: void, x: AssigneeSummary, y: AssigneeSummary) bool {
                if (x.count != y.count) return x.count > y.count;
                return std.mem.order(u8, x.display_name, y.display_name) == .lt;
            }
        }.lt);
        const out = try t.meta.allocator().alloc(AssigneeSummary, list.items.len);
        for (list.items, out) |src, *dst| dst.* = .{
            .account_id = try t.meta.allocator().dupe(u8, src.account_id),
            .display_name = try t.meta.allocator().dupe(u8, src.display_name),
            .count = src.count,
        };
        t.assignees = out;
    }

    /// Fetch and cache a ticket's linked PRs once.
    pub fn ensurePrs(a: *App, idx: usize, key: []const u8) Allocator.Error!void {
        const t = &a.tabs[idx];
        const st = &(t.tree orelse return);
        if (st.prs(key) != null) return;
        var issue_id: []const u8 = "";
        for (t.issues) |iss| if (std.mem.eql(u8, iss.key, key)) {
            issue_id = iss.id;
        };
        if (issue_id.len == 0) {
            a.setStatus("{s}: no numeric id", .{key});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (jira.pullRequests(a.client, scratch.allocator(), issue_id, .detail) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => {
                a.setStatus("{s}: linked-PR fetch failed", .{key});
                return;
            },
        }) {
            .ok => |list| {
                try st.putPrs(key, list);
                a.setStatus("{s}: {d} linked PR(s)", .{ key, list.len });
            },
            .failed => |f| a.setStatus("{s}: linked-PR fetch failed: {s}", .{ key, f.message }),
        }
    }

    /// The builds under one pull-request row. Cached against the pull
    /// request's own `updated_on`: while the PR has not moved, the runs
    /// on screen are still the right ones and the pipelines list is not
    /// asked for again. `force` is what `r` on the row means — go and
    /// look anyway.
    pub fn ensurePipelines(a: *App, key: []const u8, pr: model.LinkedPr) Allocator.Error!void {
        return a.loadPipelines(key, pr, false);
    }

    pub fn loadPipelines(a: *App, key: []const u8, pr: model.LinkedPr, force: bool) Allocator.Error!void {
        const t = a.tab();
        const st = &(t.tree orelse return);
        const have = st.pipelines(key, pr.id) != null or st.pipelineError(key, pr.id) != null;
        if (have and !force) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.setStatus("fetching builds for {s} {s}…", .{ key, pr.id });
        const known = if (st.pipelineMeta(key, pr.id)) |m| m.updated_on else "";
        a.forge.reason = .builds;
        switch (try a.forge.pipelinesForPrUrl(scratch.allocator(), pr.url, known)) {
            .ok => |runs| {
                try st.putPipelines(key, pr.id, runs.pipelines);
                try st.putPipelineMeta(key, pr.id, .{ .updated_on = runs.updated_on, .commit = runs.commit, .on_merge = runs.on_merge });
                a.setStatus("{s} {s}: {d} build(s) on {s} {s}", .{
                    key,
                    pr.id,
                    runs.pipelines.len,
                    if (runs.on_merge) "merge commit" else "branch head",
                    runs.commit[0..@min(runs.commit.len, 7)],
                });
            },
            // One request, not two: nothing on the pull request has
            // moved, so the runs already on screen still stand.
            .unchanged => a.setStatus("{s} {s}: unchanged since the last look", .{ key, pr.id }),
            .failed => |why| {
                try st.putPipelineError(key, pr.id, why);
                a.setStatus("{s} {s} build lookup: {s}", .{ key, pr.id, why });
            },
        }
    }

    // ─── the detail ──────────────────────────────────────────────────────

    pub fn detailOf(a: *App, key: []const u8) ?model.IssueDetail {
        const e = a.details.get(key) orelse return null;
        return e.detail;
    }

    pub fn ensureDetail(a: *App, key: []const u8) Allocator.Error!void {
        if (a.details.contains(key)) return;
        // With a loop to come back to, off it: the panel paints its
        // spinner and every key still answers while the site thinks.
        if (a.group != null) return a.startLook(.detail, key);
        const e = try a.gpa.create(DetailEntry);
        e.* = .{ .arena = std.heap.ArenaAllocator.init(a.gpa), .detail = .{} };
        switch (jira.issueDetail(a.client, e.arena.allocator(), key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(model.IssueDetail){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |d| e.detail = d,
            .failed => |f| {
                e.detail.error_text = try e.arena.allocator().dupe(u8, f.message);
                a.setStatus("detail fetch failed for {s}: {s}", .{ key, f.message });
            },
        }
        try a.details.put(a.gpa, try a.keep(key), e);
    }

    /// Is `key`'s detail on the wire right now?
    pub fn detailFetching(a: *const App, key: []const u8) bool {
        return a.detail_fetching_len > 0 and std.mem.eql(u8, a.detail_fetching_buf[0..a.detail_fetching_len], key);
    }

    /// Start a look, or — with one already out — remember it as the next
    /// (the latest ask wins: a cursor run down the list wants the row it
    /// stopped on, not every row it passed).
    fn startLook(a: *App, kind: LookKind, key: []const u8) Allocator.Error!void {
        const g = a.group orelse return;
        if (key.len > a.look_next_buf.len) return;
        if (kind == .detail and a.detailFetching(key)) return;
        if (!a.looks.claim()) {
            @memcpy(a.look_next_buf[0..key.len], key);
            a.look_next_len = key.len;
            a.look_next_kind = kind;
            return;
        }
        var job: LookJob = .{ .arena = std.heap.ArenaAllocator.init(a.gpa), .client = a.client.*, .kind = kind, .key = "" };
        job.key = job.arena.allocator().dupe(u8, key) catch {
            a.looks.abandon();
            job.deinit();
            return error.OutOfMemory;
        };
        if (kind == .detail) {
            @memcpy(a.detail_fetching_buf[0..key.len], key);
            a.detail_fetching_len = key.len;
        }
        g.concurrent(a.io, lookWorker, .{ a.io, &a.looks, job }) catch {
            a.looks.abandon();
            a.detail_fetching_len = 0;
            job.deinit();
        };
    }

    /// The whole of one look, on whichever thread runs it.
    pub fn runLook(job_in: LookJob) LookResult {
        var job = job_in;
        defer job.deinit();
        var client = job.client;
        var arena = std.heap.ArenaAllocator.init(job.arena.child_allocator);
        const ar = arena.allocator();
        var res: LookResult = .{ .arena = undefined, .kind = job.kind, .key = ar.dupe(u8, job.key) catch "" };
        switch (job.kind) {
            .detail => switch (jira.issueDetail(&client, ar, job.key) catch jira.Answer(model.IssueDetail){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |d| res.detail = d,
                .failed => |f| res.error_text = ar.dupe(u8, f.message) catch "out of memory",
            },
            .transitions => switch (jira.transitions(&client, ar, job.key) catch jira.Answer([]const model.Transition){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |l| res.transitions = l,
                .failed => |f| res.error_text = ar.dupe(u8, f.message) catch "out of memory",
            },
        }
        res.arena = arena;
        return res;
    }

    fn lookWorker(io: Io, slot: *LookSlot, job: LookJob) Io.Cancelable!void {
        const res = runLook(job);
        slot.finish(io, res) catch |err| {
            res.drop();
            if (err == error.Canceled) return error.Canceled;
            return;
        };
    }

    /// Take a finished look, if one has landed, and start the one that
    /// waited behind it.
    pub fn drainLooks(a: *App) Allocator.Error!void {
        if (a.looks.take(a.io)) |res_in| {
            var res = res_in;
            var owned = false;
            defer if (!owned) res.drop();
            switch (res.kind) {
                .detail => {
                    if (a.detailFetching(res.key)) a.detail_fetching_len = 0;
                    if (!a.details.contains(res.key)) {
                        const e = try a.gpa.create(DetailEntry);
                        e.* = .{ .arena = res.arena, .detail = res.detail };
                        owned = true;
                        if (res.error_text.len > 0) {
                            e.detail.error_text = res.error_text;
                            a.setStatus("detail fetch failed for {s}: {s}", .{ res.key, res.error_text });
                        }
                        try a.details.put(a.gpa, try a.keep(res.key), e);
                    }
                },
                .transitions => if (a.transition) |*p| {
                    if (p.transitions == null and std.mem.eql(u8, p.key, res.key)) {
                        if (res.error_text.len > 0) try p.fail(res.error_text) else try p.setTransitions(res.transitions);
                        // What was typed ahead of the list, in order.
                        if (p.pending_jump) |j| p.jump(j);
                        if (p.pending_commit and p.current() != null) try a.commitTransition();
                    }
                },
            }
        } else if (a.looks.lost) {
            a.detail_fetching_len = 0;
        }
        if (!a.looks.busy()) {
            if (a.look_next_kind) |kind| {
                a.look_next_kind = null;
                var kbuf: [64]u8 = undefined;
                const n = a.look_next_len;
                @memcpy(kbuf[0..n], a.look_next_buf[0..n]);
                // Still wanted? A detail for a row still focused with the
                // panel open; transitions for the picker still up.
                const want = switch (kind) {
                    .detail => a.details_visible and !a.details.contains(kbuf[0..n]),
                    .transitions => if (a.transition) |*p| p.transitions == null and std.mem.eql(u8, p.key, kbuf[0..n]) else false,
                };
                if (want) try a.startLook(kind, kbuf[0..n]);
            }
        }
    }

    pub fn invalidateDetail(a: *App, key: []const u8) void {
        if (a.details.fetchRemove(key)) |kv| {
            kv.value.arena.deinit();
            a.gpa.destroy(kv.value);
        }
    }

    fn ensureFocusedDetail(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        try a.ensureDetail(key);
    }

    pub fn toggleDetails(a: *App) Allocator.Error!void {
        // A board has four columns across the pane and no room for a
        // 40%-wide side panel, so the kanban paint skips it — and `d`
        // was a key the hint row advertised on every family that did
        // nothing at all on one of them. It opens the modal there, the
        // same one `D` opens: the ticket, in the space there is.
        if (a.hasTabs() and a.tab().cfg.isKanban()) {
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            if (try a.focusedKey(scratch.allocator())) |k| try a.openModal(k);
            return;
        }
        a.details_visible = !a.details_visible;
        a.details_scroll = 0;
        if (a.details_visible) try a.ensureFocusedDetail();
    }

    // ─── navigation ──────────────────────────────────────────────────────

    fn afterMove(a: *App) Allocator.Error!void {
        if (a.details_visible) {
            a.details_scroll = 0;
            try a.ensureFocusedDetail();
        }
    }

    pub fn move(a: *App, delta: i64) Allocator.Error!void {
        if (!a.hasTabs()) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(arena)) orelse return;
            if (r.rows.len == 0) return;
            const cur: i64 = @intCast(t.selected);
            t.selected = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(r.rows.len)) - 1));
        } else {
            const vis = try a.visibleIssues(arena);
            if (vis.len == 0) return;
            var pos: i64 = 0;
            for (vis, 0..) |i, k| if (i == t.selected) {
                pos = @intCast(k);
            };
            const np: usize = @intCast(std.math.clamp(pos + delta, 0, @as(i64, @intCast(vis.len)) - 1));
            t.selected = vis[np];
        }
        try a.afterMove();
    }

    pub fn moveHome(a: *App) Allocator.Error!void {
        try a.move(-std.math.maxInt(i32));
    }

    pub fn moveEnd(a: *App) Allocator.Error!void {
        try a.move(std.math.maxInt(i32));
    }

    /// Keep the tree cursor inside the row list after a fold or a filter.
    fn clampCursor(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(scratch.allocator())) orelse return;
            if (r.rows.len == 0) t.selected = 0 else if (t.selected >= r.rows.len) t.selected = r.rows.len - 1;
        } else {
            const vis = try a.visibleIssues(scratch.allocator());
            if (vis.len == 0) return;
            for (vis) |i| if (i == t.selected) return;
            t.selected = vis[0];
        }
    }

    pub fn switchTab(a: *App, idx: usize) Allocator.Error!void {
        if (idx >= a.tabs.len) return;
        a.active = idx;
        if (!a.tabs[idx].fetched and a.tabs[idx].last_error.len == 0) {
            a.setStatus("loading {s}…", .{a.tabs[idx].cfg.name});
            try a.refreshActive();
        }
        try a.afterMove();
    }

    pub fn nextTab(a: *App) Allocator.Error!void {
        if (a.tabs.len == 0) return;
        try a.switchTab((a.active + 1) % a.tabs.len);
    }

    pub fn prevTab(a: *App) Allocator.Error!void {
        if (a.tabs.len == 0) return;
        try a.switchTab(if (a.active == 0) a.tabs.len - 1 else a.active - 1);
    }

    // ─── focus one ticket ────────────────────────────────────────────

    /// // changed (focus-row): land the cursor on ONE ticket, `ENG-2` —
    /// `--focus` on the argv, or a `focus_item` handed over the mount
    /// when this pane is already the open one. A key that cannot land
    /// yet is remembered and tried again at every listing that
    /// arrives, so the flag may be read long before there is anything
    /// to land on.
    pub fn requestFocus(a: *App, key: []const u8) Allocator.Error!void {
        a.rememberFocus(key);
        // The listing may already be here — a second row of the same
        // hover must move the cursor now, not at the next refetch.
        try a.tryFocus(a.hasTabs() and a.tabConst().fetched);
    }

    /// `eng-2` and `ENG-2` name the same ticket; Jira spells its keys
    /// in upper case, so that is the shape the rest of this works in.
    fn rememberFocus(a: *App, key: []const u8) void {
        a.focus_key_len = @min(key.len, a.focus_key_buf.len);
        for (key[0..a.focus_key_len], 0..) |c, i| a.focus_key_buf[i] = std.ascii.toUpper(c);
    }

    /// Try to put the cursor on the ticket `--focus` asked for.
    /// `settle` says this was the answer being waited on: a key that is
    /// in no listing gets told so and is forgotten, rather than lying
    /// in wait for a tab that will never hold it.
    pub fn tryFocus(a: *App, settle: bool) Allocator.Error!void {
        if (a.focus_key_len == 0) return;
        var want_buf: [64]u8 = undefined;
        const want = want_buf[0..a.focus_key_len];
        @memcpy(want, a.focus_key_buf[0..a.focus_key_len]);
        if (try a.landFocus(want)) {
            a.focus_key_len = 0;
            return;
        }
        if (!settle) return;
        a.say("not in this listing: {s}", .{want});
        a.focus_key_len = 0;
    }

    /// The tab that holds `want`, the section it sits in opened, and
    /// the cursor on its row — or false, and nothing touched.
    fn landFocus(a: *App, want: []const u8) Allocator.Error!bool {
        // The tab in front of the reader first: a ticket that is in two
        // listings is the one already on screen.
        var i: usize = 0;
        while (i <= a.tabs.len) : (i += 1) {
            const idx = if (i == 0) a.active else i - 1;
            if (idx >= a.tabs.len) continue;
            if (i > 0 and idx == a.active) continue;
            // Only a tab whose listing is in. Switching to one that has
            // not fetched starts a refetch, and the landing would then
            // be running inside the thing that calls it.
            if (!a.tabs[idx].fetched) continue;
            const issue_idx = keyIndex(&a.tabs[idx], want) orelse continue;
            if (idx != a.active) try a.switchTab(idx);
            const t = a.tab();
            // Whatever hides the row, lift it: a `/` query from before,
            // and the section the ticket sits in folded shut.
            try a.closeFilter(false);
            if (t.cfg.isTree()) if (t.tree) |*st| {
                const place = tree.groupOf(t.issues[issue_idx], st, t.cfg, a.cfg.release_cut);
                try st.setGroup(place.status, false);
            };
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            const arena = scratch.allocator();
            const was = t.selected;
            if (t.cfg.isTree()) {
                const r = (try a.treeRows(arena)) orelse return false;
                t.selected = rowOfIssue(r.rows, issue_idx) orelse {
                    // In the data but not in the rows: an assignee, an
                    // epic or a scope chip the reader turned on is the
                    // one thing `--focus` will not undo, because undoing
                    // it would empty the listing they asked for.
                    t.selected = was;
                    return false;
                };
            } else {
                const m = try a.mask(arena, t);
                if (issue_idx >= m.len or !m[issue_idx]) {
                    t.selected = was;
                    return false;
                }
                t.selected = issue_idx;
            }
            // And the panel beside the list opens on it, not on
            // whatever the cursor happened to start on. A board has no
            // room for one, so there it is only the cursor that moves.
            if (!t.cfg.isKanban()) {
                a.details_visible = true;
                a.details_scroll = 0;
                try a.ensureFocusedDetail();
            }
            return true;
        }
        return false;
    }

    /// Where `want` sits in this tab's issues, if it is there at all.
    /// Read off the issues rather than the rows, because a ticket in a
    /// folded section is still one this tab holds.
    fn keyIndex(t: *const TabState, want: []const u8) ?usize {
        for (t.issues, 0..) |iss, i| if (std.ascii.eqlIgnoreCase(iss.key, want)) return i;
        return null;
    }

    /// Put the tree cursor back on `row` after the rows were rebuilt
    /// around it: the same row where it is still listed, else the row of
    /// the ticket it hung from, else the nearest row that exists.
    fn keepCursorOn(a: *App, arena: Allocator, row: tree.Row) Allocator.Error!void {
        const r = (try a.treeRows(arena)) orelse return;
        const t = a.tab();
        if (r.rows.len == 0) {
            t.selected = 0;
            return;
        }
        for (r.rows, 0..) |now, i| if (now.same(row)) {
            t.selected = i;
            return;
        };
        if (row.issueIdx()) |ii| if (rowOfIssue(r.rows, ii)) |ri| {
            t.selected = ri;
            return;
        };
        t.selected = @min(t.selected, r.rows.len - 1);
    }

    /// The row a ticket is painted on, by its place in the issues —
    /// the key has already been matched once and its case need not
    /// survive the second look.
    fn rowOfIssue(rows: []const tree.Row, issue_idx: usize) ?usize {
        for (rows, 0..) |r, i| if (r == .ticket and r.ticket.issue_idx == issue_idx) return i;
        return null;
    }

    // ─── the tree ────────────────────────────────────────────────────────

    /// Enter / Space / a row click on a tree tab.
    pub fn treeActivate(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse {
            try a.openBrowser();
            return;
        };
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| try st.toggleGroup(g.status),
            .ticket => |tk| {
                const key = t.issues[tk.issue_idx].key;
                if (st.isExpanded(key)) {
                    try st.setExpanded(key, false);
                } else {
                    try st.setExpanded(key, true);
                    try a.ensurePrs(a.active, key);
                }
            },
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                if (st.prs(key)) |prs| if (p.pr_idx < prs.len and prs[p.pr_idx].url.len > 0) try a.openUrl(prs[p.pr_idx].url);
            },
            // A build line is a door to that run's page.
            .pipeline => |pl| try a.openBuild(pl),
            .show_more => |s| try st.showAll(t.issues[s.issue_idx].key),
            .show_older => |s| try a.widenWindow(s.next),
            else => {},
        }
        try a.clampCursor();
    }

    /// One step out of the Reported-by-me window: 14 days, then 30,
    /// then 90, then none at all. The new window goes into the tab's
    /// JQL and the tab is refetched the ordinary way — the same broker,
    /// the same bucket, the same cache as `r` — so widening costs one
    /// search and nothing else. No count query: what a step brings back
    /// IS the count.
    fn widenWindow(a: *App, next: u16) Allocator.Error!void {
        const t = a.tab();
        if (t.tree) |*st| st.window_days = next;
        t.jql = try config.reportedJql(a.keys.allocator(), next);
        var buf: [16]u8 = undefined;
        a.say("reported: {s}", .{config.windowLabel(&buf, next)});
        try a.refreshActiveMode(.full);
    }

    /// The run a build line stands for, in the browser. Bitbucket
    /// spells it `…/<ws>/<repo>/pipelines/results/<number>`; the
    /// workspace and the repo come off the pull request's own URL.
    fn openBuild(a: *App, pl: @FieldType(tree.Row, "pipeline")) Allocator.Error!void {
        const t = a.tab();
        const st = &(t.tree orelse return);
        const key = t.issues[pl.issue_idx].key;
        const prs = st.prs(key) orelse return;
        if (pl.pr_idx >= prs.len) return;
        const pr = prs[pl.pr_idx];
        const list = st.pipelines(key, pr.id) orelse return;
        if (pl.pipeline_idx >= list.len) return;
        const ref = bitbucket.parsePrUrl(pr.url) orelse {
            a.setStatus("no build page: {s} is not a bitbucket PR URL", .{pr.id});
            return;
        };
        var buf: [256]u8 = undefined;
        const url = sdk.pane.build.pageUrl(&buf, ref.workspace, ref.repo, list[pl.pipeline_idx].build_number);
        if (url.len > 0) try a.openUrl(url);
    }

    // ─── may it merge? ───────────────────────────────────────────────

    /// What is known about this pull request's readiness. One that has
    /// moved since the look is unchecked again.
    pub fn readinessOf(a: *App, key: []const u8, pr: model.LinkedPr) sdk.pane.merge.Readiness {
        const t = a.tabConst();
        const st = &(t.tree orelse return .{});
        const e = @constCast(st).readinessOf(key, pr.id) orelse return .{};
        return e.readiness;
    }

    /// Ask, once, whether this pull request may merge — for the row the
    /// reader is actually on, and never again while the PR has not
    /// moved. The row's own builds pay for the pipeline half when they
    /// are already open and fresh.
    pub fn ensureReadiness(a: *App, key: []const u8, pr: model.LinkedPr) Allocator.Error!void {
        if (!pr.isOpen() or pr.url.len == 0) return;
        const t = a.tab();
        const st = &(t.tree orelse return);
        const known: []const u8 = if (st.readinessOf(key, pr.id)) |e| e.updated_on else "";
        var known_build: ?bool = null;
        if (st.pipelineMeta(key, pr.id)) |m| if (known.len == 0 or std.mem.eql(u8, m.updated_on, known)) {
            if (st.pipelines(key, pr.id)) |runs| {
                known_build = runs.len > 0 and std.ascii.eqlIgnoreCase(runs[0].stateLabel(), "SUCCESSFUL");
            }
        };
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.forge.reason = .readiness;
        switch (try a.forge.readinessForPrUrl(scratch.allocator(), pr.url, known, @max(a.cfg.required_approvals, 1), known_build)) {
            .ok => |got| try st.putReadiness(key, pr.id, .{ .updated_on = got.updated_on, .readiness = got.readiness }),
            // It has not moved: what is on screen still stands.
            .unchanged => {},
            .failed => |why| a.setStatus("{s} {s}: {s}", .{ key, pr.id, why }),
        }
    }

    /// The pull request under the cursor, when the cursor is on one.
    pub fn focusedPrRow(a: *App, arena: Allocator) Allocator.Error!?struct { key: []const u8, pr: model.LinkedPr } {
        const row = (try a.focusedRow(arena)) orelse return null;
        const p = switch (row) {
            .pr => |x| x,
            else => return null,
        };
        const t = a.tab();
        const key = t.issues[p.issue_idx].key;
        const prs = (t.tree orelse return null).prs(key) orelse return null;
        if (p.pr_idx >= prs.len) return null;
        return .{ .key = key, .pr = prs[p.pr_idx] };
    }

    /// A press on a row's `[ Merge ]`.
    pub fn pressMerge(a: *App, key: []const u8, pr: model.LinkedPr) Allocator.Error!void {
        var kbuf: [256]u8 = undefined;
        const row_key = std.fmt.bufPrint(&kbuf, "{s}\u{0}{s}", .{ key, pr.id }) catch return;
        switch (sdk.pane.action.pressOf(a.actions.state(row_key, "merge"))) {
            .focus_session => return a.focusSessionFor(row_key, "merge"),
            .dispatch, .retry => {},
        }
        // Only when nothing is known: a press must not re-ask for a
        // judgment the row already carries.
        if (!a.readinessOf(key, pr).checked) try a.ensureReadiness(key, pr);
        const r = a.readinessOf(key, pr);
        if (!r.ready()) {
            var rbuf: [192]u8 = undefined;
            a.say("{s}", .{r.hoverText(&rbuf)});
            return;
        }
        if (a.merge) |*m| m.deinit();
        // The arena goes into the struct FIRST, and everything is
        // allocated through the handle taken from it THERE: an
        // `ArenaAllocator`'s `allocator()` binds to the address it was
        // taken from, so a local one copied into a field leaks every
        // allocation made before the copy.
        a.merge = .{
            .arena = std.heap.ArenaAllocator.init(a.gpa),
            .row_key = "",
            .confirm = .{ .title = "", .source = "", .target = "", .strategy = .merge_commit, .url = "" },
            .allowed = &.{},
        };
        const m = &a.merge.?;
        const ar = m.arena.allocator();
        m.allowed = try ar.dupe(sdk.pane.merge.Strategy, &.{ .merge_commit, .squash, .fast_forward });
        m.row_key = try ar.dupe(u8, row_key);
        m.confirm = .{
            .title = try ar.dupe(u8, if (pr.name.len > 0) pr.name else pr.url),
            .source = try ar.dupe(u8, if (pr.source_branch.len > 0) pr.source_branch else "?"),
            .target = try ar.dupe(u8, if (pr.dest_branch.len > 0) pr.dest_branch else "?"),
            .strategy = m.allowed[0],
            .url = try ar.dupe(u8, pr.url),
        };
    }

    pub fn closeMerge(a: *App) void {
        if (a.merge) |*m| m.deinit();
        a.merge = null;
    }

    pub fn cycleMergeStrategy(a: *App) void {
        const m = &(a.merge orelse return);
        m.confirm.strategy = m.confirm.strategy.next(m.allowed);
    }

    /// Confirmed: the merge runs as a Claude Code session, like every
    /// other action this pane dispatches — the pane never calls the
    /// merge API itself.
    pub fn acceptMerge(a: *App) Allocator.Error!void {
        const m = a.merge orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const prompt = try sdk.pane.merge.prompt(arena, m.confirm);
        const first = prompt[0 .. std.mem.indexOfScalar(u8, prompt, '\n') orelse prompt.len];
        const paths = try dispatch.workspacePaths(arena, a.io, a.cfg.dispatch_workspace, a.ipc_dir);
        const row_key = try arena.dupe(u8, m.row_key);
        const out = try dispatch.firePrompt(arena, a.io, "merge", prompt, paths);
        a.say("{s}", .{out.text});
        if (out.fired) {
            try a.actions.set(row_key, "merge", .{ .state = .running, .prompt_line = first });
            try a.watchSession(row_key, "merge", first);
        } else {
            try a.actions.set(row_key, "merge", .{ .state = .failed, .detail = out.text });
        }
        a.closeMerge();
    }

    /// The pointer moved. Leaves the sentence a dim `[ Merge ]` owes
    /// the reader, for one pass.
    pub fn hoverNote(a: *const App) []const u8 {
        return a.hover_buf[0..a.hover_len];
    }

    /// What the element under the pointer is and does — for the host's
    /// info view (`Mount.hover`). The toolkit's chrome reads the same as
    /// in every pane (`sdk.pane.help.common`); the Jira chips, the
    /// ticket buttons and the pickers say their own words. `buf` backs
    /// a title that names a key or a ticket.
    /// The ticket a row or card under the pointer stands for, for the
    /// host (`sdk.wire.RowRef`): what lets a right-click there carry
    /// other integrations' menu rows for a ticket. Null off a ticket.
    pub fn rowRefAt(a: *App, arena: Allocator, col: u16, row: u16) Allocator.Error!?sdk.wire.RowRef {
        if (!a.hasTabs()) return null;
        const target = a.hits.at(col, row) orelse return null;
        const t = a.tab();
        const idx: usize = switch (target) {
            .card => |i| i,
            .row => |i| if (t.cfg.isTree()) blk: {
                const r = (try a.treeRows(arena)) orelse return null;
                if (i >= r.rows.len) return null;
                break :blk switch (r.rows[i]) {
                    .ticket => |tk| tk.issue_idx,
                    else => return null,
                };
            } else i,
            else => return null,
        };
        if (idx >= t.issues.len) return null;
        const is = t.issues[idx];
        return .{ .kind = "ticket", .id = is.key, .key = is.key, .state = is.status };
    }

    pub fn helpAt(a: *App, col: u16, row: u16, buf: []u8) sdk.pane.help.Help {
        const H = sdk.pane.help;
        const target = a.hits.at(col, row) orelse return .{ .title = "" };
        return switch (target) {
            .row, .card => if (a.hasTabs() and a.tab().cfg.isKanban())
                .{ .title = "Card", .body = "A ticket on the board. Click selects it; > expands it; t transitions it, a assigns it, d opens it in full." }
            else
                H.common(.tree_row),
            .chevron, .card_chevron => H.common(.chevron),
            .show_more => .{ .title = "Show all PRs", .body = "This ticket has more linked pull requests than the three shown. Click (or Enter) lists every one." },
            .show_older => .{ .title = "Show older", .body = "Widens this tab's date window one step — two weeks, 30 days, 90 days, all time. One refetch per step." },
            .build_line => H.common(.build_line),
            .pr_button => |b| switch (b.which) {
                .open => H.common(.open_button),
                .review => H.common(.review_button),
                .merge => H.common(.merge_button),
            },
            .merge_blocked => .{ .title = H.common(.merge_blocked).title, .body = if (a.hover_len > 0) a.hoverNote() else H.common(.merge_blocked).body },
            .confirm_ok => H.common(.confirm_ok),
            .confirm_cancel => H.common(.confirm_cancel),
            .confirm_body => .{ .title = "Merge confirm", .body = "The pull request, its source and target, and the strategy. Enter merges through Claude Code; Esc cancels." },
            .action => .{ .title = "Ticket action", .body = "Dispatches a Claude Code session for this ticket — implement, fix, triage or review. The button turns while it runs and becomes `view` when it ends." },
            .tab => H.common(.tab),
            .chip => |c| if (c == .budget) H.budget(buf, a.budget.snapshot(a.nowSecs())) else chipHelp(c),
            .avatar => .{ .title = "Assignee", .body = "One person on the board. Click shows only their cards; click again to show everyone's." },
            .filter => H.common(.filter),
            .column => .{ .title = "Board column", .body = "A status column of the board. The wheel scrolls it." },
            .picker_row, .picker_body => H.common(.picker_row),
            .modal_close => H.common(.detail_close),
            .modal_body => .{ .title = "Ticket", .body = "The ticket in full: its fields, description and comments. The wheel scrolls it; Esc closes it." },
            .vars_row, .vars_body => .{ .title = "Tab vars", .body = "The values this tab's JQL is built from. Enter edits one, a adds, d removes; s saves them into config.zon, Esc cancels." },
            .vars_save => .{ .title = "Save the vars", .body = "Writes the vars into config.zon, keeping every comment, and refetches the tab." },
            .vars_close => .{ .title = "Close", .body = "Closes the vars editor without saving." },
            .jql_text, .jql_body => .{ .title = "JQL", .body = "This tab's query. Edit it and press Enter to run it; Esc cancels." },
            .help_body => H.common(.key_sheet),
            .detail => H.common(.detail),
            .detail_close => H.common(.detail_close),
            .detail_bar, .list_bar => H.common(.scrollbar),
            .hint, .help_row => |which| blk: {
                const b = keymap.bindingOf(which) orelse break :blk H.common(.key_sheet);
                var kb: [24]u8 = undefined;
                break :blk H.key(buf, keymap.displayKey(&kb, b.keys[0]), b.label);
            },
            .comment => .{ .title = "Comment", .body = "Type the comment; Enter posts it to the ticket, Esc drops it." },
        };
    }

    fn chipHelp(c: hit.Chip) sdk.pane.help.Help {
        const H = sdk.pane.help;
        return switch (c) {
            .refresh => H.common(.refresh),
            .help => H.common(.keys_chip),
            .basic => .{ .title = "Basic", .body = "Filter the tab with the chips beside it rather than typed JQL." },
            .jql => .{ .title = "JQL", .body = "Show this tab's query and edit it; Enter runs the edited query. Key: J." },
            .vars => .{ .title = "Tab vars", .body = "The values this tab's JQL is built from (a project, versions). Click edits them. Key: J." },
            .search => .{ .title = "Search", .body = "Narrows the rows to the ones whose key or summary matches what is typed. Key: /." },
            .assignee => .{ .title = "assignee:", .body = "Whose tickets show. Click opens a picker of the people on the tab — pick several; me is the account the token belongs to." },
            .type => .{ .title = "type:", .body = "Which issue types show — Bug, Story, Task … Click opens the picker." },
            .status => .{ .title = "status:", .body = "Which statuses show. Click opens the picker; All shows every one." },
            .fixv_pill => .{ .title = "Fix version", .body = "The release this tab is looking at. Click switches it. Key: f (V on Work)." },
            .fixv_remove => .{ .title = "Clear the fix version", .body = "Stops narrowing the tab to one release." },
            .board => .{ .title = "Board", .body = "The Jira board this tab reads its sprint from." },
            .sprint => .{ .title = "Sprint", .body = "Which sprint the board shows. Click picks another." },
            .version => .{ .title = "Version", .body = "Narrows the board to one fix version." },
            .epic => .{ .title = "Epic", .body = "Narrows the board to the tickets under one epic." },
            .label => .{ .title = "Label", .body = "Narrows the board to tickets carrying one label." },
            .quick_filters => .{ .title = "Quick filters", .body = "The board's own quick filters from Jira. Click toggles them." },
            .unassigned => .{ .title = "Unassigned", .body = "Shows only the cards nobody is assigned to." },
            .overflow => .{ .title = "More chips", .body = "The chips that did not fit the toolbar at this width." },
            .settings => .{ .title = "Settings", .body = "This integration's settings." },
            // `helpAt` answers the budget chip itself: its body is the
            // live budget, which this table has no app to read.
            .budget => .{ .title = "API budget" },
        };
    }

    pub fn hover(a: *App, col: u16, row: u16) Allocator.Error!void {
        a.hover_len = 0;
        const target = a.hits.at(col, row) orelse return;
        // A button showing only its glyph is the one place the action
        // is not named on screen, so the pointer names it. One cell
        // wide IS the icon form — the rect the paint registered says
        // so, and nothing has to be remembered between frames.
        switch (target) {
            .pr_button => |b| {
                const r = a.hits.rectOf(target) orelse return;
                if (r.w != 1) return;
                const word = switch (b.which) {
                    .open => "Open",
                    .review => "Review",
                    .merge => sdk.pane.merge.label,
                };
                var wbuf: [96]u8 = undefined;
                a.setHover(sdk.pane.action.hoverText(&wbuf, .icon, .idle, word));
                return;
            },
            .action => |ab| {
                const r = a.hits.rectOf(target) orelse return;
                if (r.w != 1) return;
                const t2 = a.tab();
                if (ab.issue >= t2.issues.len) return;
                const iss = t2.issues[ab.issue];
                const set = dispatch.buttonsForTicket(iss);
                if (ab.button >= set.len) return;
                const b = set[ab.button];
                var wbuf: [96]u8 = undefined;
                a.setHover(sdk.pane.action.hoverText(&wbuf, .icon, a.actions.state(iss.key, b.kind()), std.mem.trim(u8, b.label(), "[] ")));
                return;
            },
            else => {},
        }
        const idx = switch (target) {
            .merge_blocked => |i| i,
            else => return,
        };
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const r = (try a.treeRows(scratch.allocator())) orelse return;
        if (idx >= r.rows.len) return;
        const pr_ref = switch (r.rows[idx]) {
            .pr => |p| p,
            else => return,
        };
        const t = a.tab();
        const key = t.issues[pr_ref.issue_idx].key;
        const prs = (t.tree.?).prs(key) orelse return;
        if (pr_ref.pr_idx >= prs.len) return;
        var buf: [192]u8 = undefined;
        a.setHover(a.readinessOf(key, prs[pr_ref.pr_idx]).hoverText(&buf));
    }

    fn setHover(a: *App, note: []const u8) void {
        const n = @min(note.len, a.hover_buf.len);
        @memcpy(a.hover_buf[0..n], note[0..n]);
        a.hover_len = n;
    }

    /// The confirm's keys while it is up: Enter merges, ←→ picks the
    /// strategy, anything else cancels.
    fn mergeKey(a: *App, spec: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, spec, "enter")) {
            try a.acceptMerge();
        } else if (std.mem.eql(u8, spec, "left") or std.mem.eql(u8, spec, "h") or std.mem.eql(u8, spec, "right") or std.mem.eql(u8, spec, "l")) {
            a.cycleMergeStrategy();
        } else {
            a.closeMerge();
        }
    }

    /// Fold a pull request's builds in or out, fetching them the first
    /// time. What `[ Open ]` and the row's chevron both do.
    pub fn togglePrBuilds(a: *App, key: []const u8, pr: model.LinkedPr) Allocator.Error!void {
        const t = a.tab();
        const st = &(t.tree orelse return);
        if (pr.url.len == 0) {
            a.setStatus("{s}: this PR has no URL to look up builds on", .{pr.id});
            return;
        }
        if (st.isPrExpanded(key, pr.id)) {
            try st.setPrExpanded(key, pr.id, false);
        } else {
            try st.setPrExpanded(key, pr.id, true);
            try a.ensurePipelines(key, pr);
        }
        try a.clampCursor();
    }

    pub fn treeExpand(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| if (!g.expanded) try st.setGroup(g.status, false),
            .ticket => |tk| {
                const key = t.issues[tk.issue_idx].key;
                if (!st.isExpanded(key)) {
                    try st.setExpanded(key, true);
                    try a.ensurePrs(a.active, key);
                }
            },
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                const prs = st.prs(key) orelse return;
                if (p.pr_idx >= prs.len) return;
                const pr = prs[p.pr_idx];
                if (pr.url.len == 0) return;
                if (!st.isPrExpanded(key, pr.id)) {
                    try st.setPrExpanded(key, pr.id, true);
                    try a.ensurePipelines(key, pr);
                }
            },
            else => {},
        }
    }

    /// `E`: every group open, the cursor on the row it was on. The
    /// tickets and PRs keep the folds they had.
    pub fn treeExpandAll(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const before = (try a.focusedRow(sa)) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        if (st.collapsed_groups.count() == 0) return;
        const group: ?[]const u8 = if (before == .group) try sa.dupe(u8, before.group.status) else null;
        const issue = before.issueIdx();
        st.collapsed_groups.clearRetainingCapacity();
        const after = (try a.treeRows(sa)).?;
        for (after.rows, 0..) |r, i| {
            const same = if (group) |g| (r == .group and std.mem.eql(u8, r.group.status, g)) else (r == .ticket and issue != null and r.ticket.issue_idx == issue.?);
            if (same) {
                t.selected = i;
                break;
            }
        }
        try a.clampCursor();
    }

    /// `C`: every group shut, the cursor on the group it was inside.
    pub fn treeCollapseAll(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const rows = (try a.treeRows(sa)) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        var home: ?[]const u8 = null;
        for (rows.rows, 0..) |r, i| {
            if (i > t.selected) break;
            if (r == .group) home = try sa.dupe(u8, r.group.status);
        }
        for (rows.rows) |r| if (r == .group) try st.setGroup(r.group.status, true);
        const after = (try a.treeRows(sa)).?;
        t.selected = 0;
        if (home) |h| for (after.rows, 0..) |r, i| {
            if (r == .group and std.mem.eql(u8, r.group.status, h)) {
                t.selected = i;
                break;
            }
        };
        try a.clampCursor();
    }

    pub fn treeCollapse(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| if (g.expanded) try st.setGroup(g.status, true),
            .ticket => |tk| try st.setExpanded(t.issues[tk.issue_idx].key, false),
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                if (st.prs(key)) |prs| if (p.pr_idx < prs.len) {
                    const pr = prs[p.pr_idx];
                    if (st.isPrExpanded(key, pr.id)) {
                        try st.setPrExpanded(key, pr.id, false);
                        return;
                    }
                };
                try st.setExpanded(key, false);
            },
            .pr_loading => |x| try st.setExpanded(t.issues[x.issue_idx].key, false),
            .show_more => |x| try st.setExpanded(t.issues[x.issue_idx].key, false),
            // The widen row belongs to no ticket: there is nothing
            // under it to close.
            .show_older => {},
            .pipeline_loading, .pipeline_empty, .pipeline_error => |x| {
                const k = t.issues[x.issue_idx].key;
                if (st.prs(k)) |prs| if (x.pr_idx < prs.len) try st.setPrExpanded(k, prs[x.pr_idx].id, false);
            },
            .pipeline => |x| {
                const k = t.issues[x.issue_idx].key;
                if (st.prs(k)) |prs| if (x.pr_idx < prs.len) try st.setPrExpanded(k, prs[x.pr_idx].id, false);
            },
        }
        try a.clampCursor();
    }

    // ─── the browser ─────────────────────────────────────────────────────

    pub fn openUrl(a: *App, url: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (os.open(a.io, scratch.allocator(), a.cfg.open_command, a.open_url_route, url)) {
            .ok => a.say("opened {s}", .{url}),
            .failed => |why| a.say("open failed: {s}", .{why}),
        }
    }

    pub fn openBrowser(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        try a.openUrl(try model.issueUrl(scratch.allocator(), a.cfg.jira_url, key));
    }

    // ─── the filter and the JQL editor ───────────────────────────────────

    pub fn openFilter(a: *App) Allocator.Error!void {
        if (a.filter) |*f| {
            f.editing = true;
            return;
        }
        a.filter = .{ .edit = TextEdit.init(a.gpa), .editing = true };
    }

    pub fn closeFilter(a: *App, commit: bool) Allocator.Error!void {
        var f = a.filter orelse return;
        if (commit and std.mem.trim(u8, f.edit.text(), " ").len > 0) {
            f.editing = false;
            a.filter = f;
        } else {
            f.edit.deinit();
            a.filter = null;
        }
        try a.clampCursor();
    }

    pub fn openJql(a: *App) Allocator.Error!void {
        if (a.jql != null or !a.hasTabs()) return;
        var e = TextEdit.init(a.gpa);
        try e.set(a.tab().jql);
        a.jql = e;
        a.tab().show_jql = true;
    }

    pub fn closeJql(a: *App, commit: bool) Allocator.Error!void {
        var e = a.jql orelse return;
        defer e.deinit();
        a.jql = null;
        if (!commit) return;
        const t = a.tab();
        t.jql = try a.keep(std.mem.trim(u8, e.text(), " "));
        t.fetched = false;
        try a.refreshActive();
    }

    // ─── selection ───────────────────────────────────────────────────────

    pub fn toggleSelection(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        if (a.selection.remove(key)) return;
        try a.selection.put(a.gpa, try a.keep(key), {});
    }

    pub fn clearSelection(a: *App) void {
        a.selection.clearRetainingCapacity();
    }

    pub fn isSelected(a: *const App, key: []const u8) bool {
        return a.selection.contains(key);
    }

    /// The keys an action runs on: the selection, else the focused row.
    pub fn bulkKeys(a: *App, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (a.selection.count() > 0) {
            var it = a.selection.keyIterator();
            while (it.next()) |k| try out.append(arena, k.*);
            std.mem.sort([]const u8, out.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.lt);
        } else if (try a.focusedKey(arena)) |k| try out.append(arena, k);
        return out.toOwnedSlice(arena);
    }

    // ─── the transition picker ───────────────────────────────────────────

    pub fn openTransition(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        var p = try pickers.TransitionPicker.init(a.gpa, key);
        p.targets = if (a.selection.count() > 0) a.selection.count() else 1;
        if (a.group != null) {
            // Up at once with `loading…`; the list lands on a later tick.
            if (a.transition) |*old| old.deinit();
            a.transition = p;
            return a.startLook(.transitions, key);
        }
        switch (jira.transitions(a.client, scratch.allocator(), key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer([]const model.Transition){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |list| try p.setTransitions(list),
            .failed => |f| try p.fail(f.message),
        }
        a.transition = p;
    }

    pub fn closeTransition(a: *App) void {
        if (a.transition) |*p| p.deinit();
        a.transition = null;
    }

    pub fn commitTransition(a: *App) Allocator.Error!void {
        const p = &(a.transition orelse return);
        const chosen = p.current() orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const to_name = if (chosen.to_name.len > 0) chosen.to_name else chosen.name;
        if (a.selection.count() == 0) {
            // The key is the PICKER's — duped onto the arena its own
            // `deinit` frees. `closeTransition` below IS that deinit,
            // and the ticket is named again after it, so what is held
            // here is a copy on the scratch, not the picker's bytes.
            const key = try arena.dupe(u8, p.key);
            switch (jira.doTransition(a.client, arena, key, chosen.id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => {
                    // The words are the picker's; say them before it goes.
                    a.say("{s} → {s}", .{ key, to_name });
                    a.closeTransition();
                    a.invalidateDetail(key);
                    try a.refreshActive();
                    if (a.details_visible) try a.ensureFocusedDetail();
                },
                .failed => |f| try p.fail(f.message),
            }
            return;
        }
        // Bulk: match by name on every selected ticket, skip the ones without it.
        const keys = try a.bulkKeys(arena);
        var ok: usize = 0;
        var skipped: std.ArrayList([]const u8) = .empty;
        var errors: std.ArrayList([]const u8) = .empty;
        for (keys) |key| {
            const list = switch (jira.transitions(a.client, arena, key) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.Transition){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |l| l,
                .failed => |f| {
                    try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message }));
                    continue;
                },
            };
            var id: ?[]const u8 = null;
            for (list) |t| if (std.ascii.eqlIgnoreCase(t.name, chosen.name)) {
                id = t.id;
            };
            const tid = id orelse {
                try skipped.append(arena, key);
                continue;
            };
            switch (jira.doTransition(a.client, arena, key, tid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => {
                    ok += 1;
                    a.invalidateDetail(key);
                },
                .failed => |f| try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message })),
            }
        }
        if (errors.items.len == 0) {
            if (skipped.items.len > 0) {
                a.say("{d} ticket(s) → {s} · skipped {d}: {s}", .{ ok, to_name, skipped.items.len, try std.mem.join(arena, ", ", skipped.items) });
            } else a.say("{d} ticket(s) → {s}", .{ ok, to_name });
            a.closeTransition();
            a.clearSelection();
        } else {
            try p.fail(try std.fmt.allocPrint(arena, "{d} ok · {d} skipped · {d} failed — {s}", .{ ok, skipped.items.len, errors.items.len, try std.mem.join(arena, " / ", errors.items) }));
        }
        try a.refreshActive();
        if (a.details_visible) try a.ensureFocusedDetail();
    }

    // ─── the field pickers ───────────────────────────────────────────────

    fn startPicker(a: *App, kind: pickers.Kind) Allocator.Error!*pickers.FieldPicker {
        a.closePicker();
        a.picker = pickers.FieldPicker.init(a.gpa, kind);
        const p = &(a.picker.?);
        p.targets = if (a.selection.count() > 0) a.selection.count() else 1;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        if (try a.focusedKey(scratch.allocator())) |k| p.focused_key = try p.arena().dupe(u8, k);
        return p;
    }

    pub fn closePicker(a: *App) void {
        if (a.picker) |*p| p.deinit();
        a.picker = null;
    }

    fn failPicker(a: *App, p: *pickers.FieldPicker, err: jira.CallError) Allocator.Error!void {
        _ = a;
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => try p.fail("the site did not answer"),
        }
    }

    pub fn openAssignee(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        const project = model.projectOf(key) orelse {
            a.setStatus("can't derive project from {s}", .{key});
            return;
        };
        const p = try a.startPicker(.assignee);
        switch (jira.assignableUsers(a.client, arena, project) catch |err| return a.failPicker(p, err)) {
            .ok => |users| {
                var items: std.ArrayList(pickers.Item) = .empty;
                try items.append(arena, .{ .id = "", .label = "— Unassign —" });
                for (users) |u| try items.append(arena, .{ .id = u.account_id, .label = u.display_name });
                try p.setItems(items.items);
            },
            .failed => |f| try p.fail(f.message),
        }
    }

    fn versionItems(a: *App, arena: Allocator, project: []const u8, clear_row: ?[]const u8) Allocator.Error!jira.Answer([]const pickers.Item) {
        switch (jira.projectVersions(a.client, arena, project) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => return .{ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .failed => |f| {
                recent.releasesFailed(a.gpa, a.io, a.recent_root);
                return .{ .failed = f };
            },
            .ok => |all| {
                _ = recent.publishReleases(a.gpa, a.io, a.recent_root, project, all, a.recent_current_release, a.cfg.refresh_interval_secs);
                var items: std.ArrayList(pickers.Item) = .empty;
                if (clear_row) |c| try items.append(arena, .{ .id = "", .label = c });
                for (try jira.pickerVersions(arena, all)) |v| {
                    const label = if (v.released) try std.fmt.allocPrint(arena, "{s} (released)", .{v.name}) else v.name;
                    try items.append(arena, .{ .id = v.name, .label = label });
                }
                return .{ .ok = try items.toOwnedSlice(arena) };
            },
        }
    }

    pub fn openFixVersion(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        const project = model.projectOf(key) orelse return;
        const p = try a.startPicker(.fix_version);
        switch (try a.versionItems(arena, project, "— Clear fixVersion —")) {
            .ok => |items| try p.setItems(items),
            .failed => |f| try p.fail(f.message),
        }
    }

    pub fn openTabFixVersion(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.project.len == 0) {
            a.setStatus("V: tab has no `project`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const p = try a.startPicker(.tab_fix_version);
        switch (try a.versionItems(scratch.allocator(), t.cfg.project, null)) {
            .ok => |items| try p.setItems(items),
            .failed => |f| try p.fail(f.message),
        }
    }

    /// The distinct values of a field over the tab's tickets, sorted.
    fn distinct(a: *App, arena: Allocator, comptime pick: fn (Issue, *std.ArrayList([]const u8), Allocator) Allocator.Error!void) Allocator.Error![]const []const u8 {
        var seen: std.ArrayList([]const u8) = .empty;
        for (a.tab().issues) |iss| {
            var vals: std.ArrayList([]const u8) = .empty;
            try pick(iss, &vals, arena);
            for (vals.items) |v| {
                if (std.mem.trim(u8, v, " ").len == 0) continue;
                var dup = false;
                for (seen.items) |s| if (std.mem.eql(u8, s, v)) {
                    dup = true;
                };
                if (!dup) try seen.append(arena, v);
            }
        }
        std.mem.sort([]const u8, seen.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        return seen.toOwnedSlice(arena);
    }

    fn pickTeam(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        for (iss.components) |c| try out.append(arena, c);
        for (iss.labels) |l| try out.append(arena, l);
        if (iss.team.len > 0) try out.append(arena, iss.team);
    }

    fn pickType(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        try out.append(arena, iss.issuetype);
    }

    fn pickLabel(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        for (iss.labels) |l| try out.append(arena, l);
    }

    fn openLocalPicker(a: *App, kind: pickers.Kind, clear_row: []const u8, comptime pick: fn (Issue, *std.ArrayList([]const u8), Allocator) Allocator.Error!void) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const values = try a.distinct(arena, pick);
        const p = try a.startPicker(kind);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = clear_row });
        for (values) |v| try items.append(arena, .{ .id = v, .label = v });
        try p.setItems(items.items);
    }

    pub fn openTeam(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.team, "— Clear team —", pickTeam);
    }

    pub fn openIssueType(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.issue_type, "— Clear type —", pickType);
    }

    pub fn openLabel(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.label, "— Clear label —", pickLabel);
    }

    pub fn openActions(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const idx = (try a.focusedIssueIdx(arena)) orelse return;
        const iss = a.tab().issues[idx];
        const buttons = dispatch.buttonsForTicket(iss);
        if (buttons.len == 0) {
            a.setStatus(". actions: no ticket-level actions for {s} ({s} · {s})", .{ iss.key, if (iss.issuetype.len > 0) iss.issuetype else "?", if (iss.status.len > 0) iss.status else "?" });
            return;
        }
        const p = try a.startPicker(.action);
        var items: std.ArrayList(pickers.Item) = .empty;
        for (buttons) |b| try items.append(arena, .{ .id = b.kind(), .label = b.label() });
        try p.setItems(items.items);
    }

    pub fn openSprint(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("sprint picker: this tab has no `board_id`", .{});
            return;
        }
        if (t.sprints == null) try a.loadSprints(a.active);
        const list = t.sprints orelse &.{};
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const sorted = try model.Sprint.sortForPicker(arena, list, 5);
        if (sorted.len == 0) {
            a.setStatus("sprint picker: this board has no sprints", .{});
            return;
        }
        const p = try a.startPicker(.sprint);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Board default (active sprint) —" });
        for (sorted) |s| {
            const tag = if (std.ascii.eqlIgnoreCase(s.state, "active")) "active" else if (std.ascii.eqlIgnoreCase(s.state, "future")) "future" else "closed";
            try items.append(arena, .{ .id = try std.fmt.allocPrint(arena, "{d}", .{s.id}), .label = try std.fmt.allocPrint(arena, "{s}  [{s}]", .{ s.name, tag }) });
        }
        try p.setItems(items.items);
        if (t.selected_sprint) |id| p.selectId(try std.fmt.allocPrint(arena, "{d}", .{id}));
    }

    pub fn openQuickFilters(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("quick filters: this tab has no `board_id`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        if (t.quick_filters == null) {
            switch (jira.quickFilters(a.client, arena, t.board_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.QuickFilter){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |list| {
                    const copy = try t.meta.allocator().alloc(model.QuickFilter, list.len);
                    for (list, copy) |src, *dst| dst.* = .{ .id = src.id, .name = try t.meta.allocator().dupe(u8, src.name), .jql = try t.meta.allocator().dupe(u8, src.jql) };
                    t.quick_filters = copy;
                },
                .failed => |f| {
                    const p = try a.startPicker(.quick_filter);
                    try p.fail(f.message);
                    return;
                },
            }
        }
        const qfs = t.quick_filters.?;
        if (qfs.len == 0) {
            a.setStatus("quick filters: this board defines none", .{});
            return;
        }
        const p = try a.startPicker(.quick_filter);
        var items: std.ArrayList(pickers.Item) = .empty;
        var seed: std.ArrayList([]const u8) = .empty;
        for (qfs) |q| {
            const id = try std.fmt.allocPrint(arena, "{d}", .{q.id});
            try items.append(arena, .{ .id = id, .label = q.name });
            for (t.active_quick_filters.items) |x| if (x == q.id) try seed.append(arena, id);
        }
        try p.setItems(items.items);
        try p.seedMulti(seed.items);
    }

    pub fn openBoard(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.project.len == 0) {
            a.setStatus("board picker: this tab has no `project`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        if (t.boards == null) {
            switch (jira.boardsForProject(a.client, arena, t.cfg.project) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.Board){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |list| {
                    const copy = try t.meta.allocator().alloc(model.Board, list.len);
                    for (list, copy) |src, *dst| dst.* = .{ .id = src.id, .name = try t.meta.allocator().dupe(u8, src.name), .kind = try t.meta.allocator().dupe(u8, src.kind) };
                    t.boards = copy;
                },
                .failed => |f| {
                    const p = try a.startPicker(.board);
                    try p.fail(f.message);
                    return;
                },
            }
        }
        const boards = t.boards.?;
        if (boards.len == 0) {
            a.setStatus("board picker: project {s} has no visible boards", .{t.cfg.project});
            return;
        }
        const p = try a.startPicker(.board);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Board default —" });
        for (boards) |b| {
            const label = if (b.kind.len > 0) try std.fmt.allocPrint(arena, "{s}  [{s}]", .{ b.name, b.kind }) else b.name;
            try items.append(arena, .{ .id = try std.fmt.allocPrint(arena, "{d}", .{b.id}), .label = label });
        }
        try p.setItems(items.items);
        if (t.board_id != 0) p.selectId(try std.fmt.allocPrint(arena, "{d}", .{t.board_id}));
    }

    pub fn openEpic(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.issues.len == 0) {
            a.setStatus("Epic filter: no issues on this tab yet — refresh first", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var items: std.ArrayList(pickers.Item) = .empty;
        for (t.issues) |iss| {
            const key = iss.epicKey() orelse continue;
            var dup = false;
            for (items.items) |it| if (std.mem.eql(u8, it.id, key)) {
                dup = true;
            };
            if (dup) continue;
            const label = if (iss.parent_summary.len > 0) try std.fmt.allocPrint(arena, "{s}  {s}", .{ key, iss.parent_summary }) else key;
            try items.append(arena, .{ .id = key, .label = label });
        }
        if (items.items.len == 0) {
            a.setStatus("Epic filter: no epics found on current issues", .{});
            return;
        }
        std.mem.sort(pickers.Item, items.items, {}, struct {
            fn lt(_: void, x: pickers.Item, y: pickers.Item) bool {
                return std.mem.order(u8, x.id, y.id) == .lt;
            }
        }.lt);
        const p = try a.startPicker(.epic);
        try p.setItems(items.items);
        try p.seedMulti(try t.activeEpics(arena));
    }

    /// The avatar cluster's overflow / the Assignee chip: every assignee
    /// seen on the tab, Me and Unassigned first.
    pub fn openAssignees(a: *App) Allocator.Error!void {
        const t = a.tab();
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const p = try a.startPicker(.assignees);
        var items: std.ArrayList(pickers.Item) = .empty;
        if (a.me) |me| if (me.account_id.len > 0) try items.append(arena, .{ .id = me.account_id, .label = "— Me (Current User) —" });
        try items.append(arena, .{ .id = model.unassigned_sentinel, .label = "— Unassigned —" });
        for (t.assignees) |s| try items.append(arena, .{ .id = s.account_id, .label = try std.fmt.allocPrint(arena, "{s}  ({d})", .{ s.display_name, s.count }) });
        try p.setItems(items.items);
        try p.seedMulti(try t.activeIds(arena));
    }

    fn resetSet(a: *App, set: *std.StringHashMapUnmanaged(void), ids: []const []const u8) Allocator.Error!void {
        set.clearRetainingCapacity();
        for (ids) |id| try set.put(a.gpa, try a.keep(id), {});
    }

    /// Enter in a field picker.
    pub fn commitPicker(a: *App) Allocator.Error!void {
        const p = &(a.picker orelse return);
        if (!p.loaded) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const t = a.tab();
        switch (p.kind) {
            .team => {
                const it = p.current() orelse return;
                t.team = try a.keep(it.id);
                a.say("team filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.refreshActive();
            },
            .issue_type => {
                const it = p.current() orelse return;
                t.issue_type = try a.keep(it.id);
                a.say("type filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.clampCursor();
            },
            .label => {
                const it = p.current() orelse return;
                t.label = try a.keep(it.id);
                a.say("label filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.clampCursor();
            },
            .tab_fix_version => {
                const it = p.current() orelse return;
                if (t.cfg.project.len == 0) {
                    a.closePicker();
                    return;
                }
                t.jql = try a.keep(try jira.fixVersionJql(arena, t.cfg.project, it.id, ""));
                a.say("tab view: fixVersion = {s}", .{it.id});
                a.closePicker();
                try a.refreshActive();
            },
            .action => {
                const it = p.current() orelse return;
                const kind = try arena.dupe(u8, it.id);
                a.closePicker();
                try a.dispatchTicket(kind);
            },
            .sprint => {
                const it = p.current() orelse return;
                t.selected_sprint = if (it.id.len == 0) null else std.fmt.parseInt(u64, it.id, 10) catch null;
                a.kanban_scroll = .{ 0, 0, 0, 0 };
                a.closePicker();
                if (t.selected_sprint) |id| a.say("sprint: pinned to {d}", .{id}) else a.say("sprint: back to board default (active)", .{});
                try a.refreshActive();
            },
            .quick_filter => {
                const ids = try p.checked(arena);
                t.active_quick_filters.clearRetainingCapacity();
                for (ids) |id| try t.active_quick_filters.append(a.gpa, std.fmt.parseInt(u64, id, 10) catch continue);
                a.closePicker();
                if (t.active_quick_filters.items.len == 0) a.say("quick filters: cleared", .{}) else a.say("quick filters: {d} active", .{t.active_quick_filters.items.len});
                try a.refreshActive();
            },
            .assignees => {
                const ids = try p.checked(arena);
                try a.resetSet(&t.active_assignees, ids);
                a.closePicker();
                if (ids.len == 0) a.say("assignees: all", .{}) else a.say("assignees: {d} active", .{ids.len});
                try a.clampCursor();
            },
            .board => {
                const it = p.current() orelse return;
                t.board_id = if (it.id.len == 0) 0 else std.fmt.parseInt(u64, it.id, 10) catch 0;
                t.sprints = null;
                t.quick_filters = null;
                t.selected_sprint = null;
                t.active_quick_filters.clearRetainingCapacity();
                a.kanban_scroll = .{ 0, 0, 0, 0 };
                a.closePicker();
                if (t.board_id != 0) a.say("board: switched to {d}", .{t.board_id}) else a.say("board: back to default (synthetic JQL)", .{});
                try a.refreshActive();
            },
            .epic => {
                const ids = try p.checked(arena);
                try a.resetSet(&t.active_epics, ids);
                a.closePicker();
                if (ids.len == 0) a.say("epic filter: cleared", .{}) else a.say("epic filter: {d} active", .{ids.len});
                try a.clampCursor();
            },
            .assignee, .fix_version => {
                const it = p.current() orelse return;
                const keys = try a.bulkKeys(arena);
                if (keys.len == 0) return;
                var ok: usize = 0;
                var errors: std.ArrayList([]const u8) = .empty;
                const id = try arena.dupe(u8, it.id);
                const label = try arena.dupe(u8, it.label);
                const kind = p.kind;
                for (keys) |key| {
                    const answer = (if (kind == .assignee) jira.setAssignee(a.client, arena, key, id) else jira.setFixVersion(a.client, arena, key, id)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
                    };
                    switch (answer) {
                        .ok => {
                            ok += 1;
                            a.invalidateDetail(key);
                        },
                        .failed => |f| try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message })),
                    }
                }
                if (errors.items.len == 0) {
                    a.closePicker();
                    a.say("{d} ticket(s) · {s} = {s}", .{ ok, if (kind == .assignee) "assignee" else "fixVersion", label });
                    a.clearSelection();
                } else {
                    try p.fail(try std.fmt.allocPrint(arena, "{d} ok · {d} failed — {s}", .{ ok, errors.items.len, try std.mem.join(arena, " / ", errors.items) }));
                }
                try a.refreshActive();
                if (a.details_visible) try a.ensureFocusedDetail();
            },
        }
    }

    /// A click on an avatar / the `[?]` chip: toggle one id.
    pub fn toggleAssignee(a: *App, id: []const u8) Allocator.Error!void {
        const t = a.tab();
        if (t.active_assignees.remove(id)) {
            try a.clampCursor();
            return;
        }
        try t.active_assignees.put(a.gpa, try a.keep(id), {});
        try a.clampCursor();
    }

    /// The Status chip: All → Unresolved → Resolved → All.
    pub fn cycleScope(a: *App) Allocator.Error!void {
        const t = a.tab();
        t.scope = t.scope.cycle();
        try a.clampCursor();
    }

    /// The fixVersion pill's ⓧ: drop the clause and refetch.
    pub fn removeFixVersionClause(a: *App) Allocator.Error!void {
        const t = a.tab();
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        t.jql = try a.keep(try stripFixVersion(scratch.allocator(), t.jql));
        t.fetched = false;
        try a.refreshActive();
    }

    // ─── comments and watching ───────────────────────────────────────────

    pub fn openComment(a: *App) Allocator.Error!void {
        if (!a.details_visible) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        a.closeComment();
        a.comment = .{ .key = try a.keep(key), .edit = TextEdit.init(a.gpa) };
    }

    pub fn closeComment(a: *App) void {
        if (a.comment) |*c| c.edit.deinit();
        a.comment = null;
    }

    pub fn submitComment(a: *App) Allocator.Error!void {
        const c = &(a.comment orelse return);
        if (std.mem.trim(u8, c.edit.text(), " \n").len == 0 or c.posting) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        c.posting = true;
        c.error_text = "";
        switch (jira.addComment(a.client, scratch.allocator(), c.key, c.edit.text()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => {
                const key = c.key;
                a.closeComment();
                a.say("commented on {s}", .{key});
                a.invalidateDetail(key);
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .failed => |f| {
                c.posting = false;
                c.error_text = try a.keep(f.message);
            },
        }
    }

    pub fn toggleWatch(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        try a.ensureDetail(key);
        const was = if (a.detailOf(key)) |d| d.watching else false;
        const answer = blk: {
            if (was) {
                try a.ensureMe();
                const me = a.me orelse {
                    a.say("can't unwatch — the account id is unknown (/myself failed)", .{});
                    return;
                };
                break :blk jira.unwatch(a.client, arena, key, me.account_id);
            }
            break :blk jira.watch(a.client, arena, key);
        } catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        };
        switch (answer) {
            .ok => {
                a.say("{s} {s}", .{ if (was) "unwatched" else "watched", key });
                a.invalidateDetail(key);
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .failed => |f| a.say("watch toggle failed for {s}: {s}", .{ key, f.message }),
        }
    }

    // ─── the dispatch queue ──────────────────────────────────────────────

    fn isoNow(a: *App, buf: *[24]u8) []const u8 {
        const secs: u64 = @intCast(@max(@divTrunc(a.nowMs(), 1000), 0));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
    }

    pub fn dispatchTicket(a: *App, kind: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const idx = (try a.focusedIssueIdx(arena)) orelse {
            a.setStatus("no ticket under cursor", .{});
            return;
        };
        const iss = a.tab().issues[idx];
        var buf: [24]u8 = undefined;
        const d = dispatch.Dispatch.forTicket(kind, iss, try model.issueUrl(arena, a.cfg.jira_url, iss.key), a.isoNow(&buf));
        const paths = try dispatch.workspacePaths(arena, a.io, a.cfg.dispatch_workspace, a.ipc_dir);
        try a.fireAndRecord(arena, iss.key, kind, d, paths);
    }

    /// Fire a dispatch and leave the outcome on the row's button: a
    /// spinner that turns for as long as the session runs, or a red
    /// cross carrying the reason into the hint row.
    ///
    /// The button starts on `running` rather than `view` because that
    /// is what it is — a session was started and has not ended. What
    /// happens to it after is the host's to say: the watch queued here
    /// goes out on the next pass and `session_state` lines come back.
    fn fireAndRecord(a: *App, arena: Allocator, row_key: []const u8, action: []const u8, d: dispatch.Dispatch, paths: dispatch.Paths) Allocator.Error!void {
        const out = try dispatch.fireOutcome(arena, a.io, d, paths);
        a.say("{s}", .{out.text});
        if (out.fired) {
            // What the pane can say about the session it started: the
            // directory it runs in and the first line of its prompt.
            const prompt = try d.prompt(arena);
            const first = prompt[0 .. std.mem.indexOfScalar(u8, prompt, '\n') orelse prompt.len];
            try a.actions.set(row_key, action, .{ .state = .running, .prompt_line = try arena.dupe(u8, first) });
            try a.watchSession(row_key, action, first);
        } else {
            try a.actions.set(row_key, action, .{ .state = .failed, .detail = out.text });
        }
    }

    /// Queue a `watch_session` for the button that just dispatched. The
    /// pane loop sends it over the mount; the host matches the session
    /// the same way `focus-session` does and answers on every edge.
    fn watchSession(a: *App, row_key: []const u8, action: []const u8, prompt_line: []const u8) Allocator.Error!void {
        var buf: [320]u8 = undefined;
        const key = sdk.pane.actionWatchKey(&buf, row_key, action);
        if (key.len == 0) return;
        const arena = a.watch_arena.allocator();
        try a.watch_out.append(a.gpa, .{
            .key = try arena.dupe(u8, key),
            .cwd = try arena.dupe(u8, a.cfg.dispatch_workspace),
            .prompt_line = try arena.dupe(u8, prompt_line),
        });
    }

    /// A `session_state` line from the host: the button it names takes
    /// the host's word for what its session is doing.
    pub fn onSessionState(a: *App, key: []const u8, state: sdk.wire.SessionState, session_id: []const u8, detail: []const u8) Allocator.Error!void {
        if (!try a.actions.applyState(key, sdk.pane.actionStateOf(state), session_id, detail)) return;
        // A merge that ENDS while the pane does not have the keyboard
        // is worth telling the user about: it is the one thing here
        // that changed a repository.
        const ended = state == .done or state == .failed;
        if (!ended or a.focused) return;
        const pair = sdk.pane.action.splitWatchKey(key) orelse return;
        if (!std.mem.eql(u8, pair.action, "merge")) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        // A merge that lands takes its pull request off the row it was
        // under, so the message about it is the last place that pull
        // request is named. The offer is the door back to it — over the
        // MOUNT, so it does not wait on a file channel the pane may not
        // have.
        if (try a.mergedPrUrl(arena, pair.row)) |url| {
            a.sayWithAction(.{ .label = "Open PR", .url = url }, "merge {s}: {s}", .{ if (state == .done) "finished" else "failed", pair.row });
        }
        const ipc = a.ipc orelse return;
        const title = try std.fmt.allocPrint(arena, "Merge {s}", .{if (state == .done) "finished" else "failed"});
        const body = try std.fmt.allocPrint(arena, "{s} \u{2014} {s}", .{ pair.row, if (detail.len > 0) detail else "see the session" });
        ipc.notify(title, body, if (state == .failed) .@"error" else .info, state == .failed) catch {};
    }

    /// The web page of the pull request a `<ticket key>\x00<pr id>` row
    /// key names, or null when the pane no longer holds it — which is
    /// exactly what a landed merge does to it.
    fn mergedPrUrl(a: *App, arena: Allocator, row_key: []const u8) Allocator.Error!?[]const u8 {
        const nul = std.mem.indexOfScalar(u8, row_key, 0) orelse return null;
        const key = row_key[0..nul];
        const pr_id = row_key[nul + 1 ..];
        const t = a.tab();
        const st = &(t.tree orelse return null);
        const prs = st.prs(key) orelse return null;
        for (prs) |pr| if (std.mem.eql(u8, pr.id, pr_id) and pr.url.len > 0) {
            return try arena.dupe(u8, pr.url);
        };
        return null;
    }

    /// A press on a button whose session is live or finished: ask the
    /// host to bring it to the front. The host's own id when it has
    /// given one, else the two names a dispatched `term` line carries.
    pub fn focusSessionFor(a: *App, row_key: []const u8, action: []const u8) Allocator.Error!void {
        const e = a.actions.get(row_key, action);
        const ipc = a.ipc orelse {
            a.setStatus("view: no mnml channel to focus a session on", .{});
            return;
        };
        ipc.focusSession(.{ .id = e.session, .cwd = a.cfg.dispatch_workspace, .prompt_line = e.prompt_line }) catch |err| {
            a.say("view failed: {s}", .{@errorName(err)});
            return;
        };
        a.say("{s} {s}: asked mnml to focus its session", .{ row_key, action });
    }

    pub fn dispatchReview(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const row = (try a.focusedRow(arena)) orelse {
            a.setStatus("no PR under cursor", .{});
            return;
        };
        const p = switch (row) {
            .pr => |p| p,
            else => {
                a.setStatus("no PR under cursor", .{});
                return;
            },
        };
        const t = a.tab();
        const iss = t.issues[p.issue_idx];
        const prs = t.tree.?.prs(iss.key) orelse return;
        if (p.pr_idx >= prs.len or prs[p.pr_idx].url.len == 0) {
            a.setStatus("PR has no URL", .{});
            return;
        }
        // The PR row's `[ Review ]` starts a session like every other
        // button, so it remembers the press like every other button:
        // keyed by the PR's row key, not the ticket's, or a ticket with
        // two pull requests would carry one button's state on both.
        const row_key = try prRowKey(arena, iss.key, prs[p.pr_idx].id);
        switch (sdk.pane.action.pressOf(a.actions.state(row_key, "review"))) {
            .focus_session => return a.focusSessionFor(row_key, "review"),
            .dispatch, .retry => {},
        }
        var buf: [24]u8 = undefined;
        const d = dispatch.Dispatch.forPr(iss, try model.issueUrl(arena, a.cfg.jira_url, iss.key), prs[p.pr_idx].url, a.isoNow(&buf));
        const paths = try dispatch.workspacePaths(arena, a.io, a.cfg.dispatch_workspace, a.ipc_dir);
        try a.fireAndRecord(arena, row_key, "review", d, paths);
    }

    /// `<ticket key><NUL><pr id>` — the key a pull-request row's
    /// buttons are remembered under, so a refetch that moves the row
    /// brings them along. `pressMerge` spells it into a stack buffer;
    /// this is the same name on an arena, for a caller that needs it to
    /// outlive one.
    pub fn prRowKey(arena: Allocator, key: []const u8, pr_id: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}\u{0}{s}", .{ key, pr_id });
    }

    // ─── the vars editor ─────────────────────────────────────────────────

    /// `E` on a `jql_editable` tab. The JQL stays where the user wrote
    /// it; what this edits is the list of things it interpolates.
    pub fn openVars(a: *App) Allocator.Error!void {
        if (!a.hasTabs()) return;
        const t = a.tab();
        if (!t.cfg.isEditableJql()) {
            a.setStatus("E: this tab has no vars (it is not a `jql_editable` tab)", .{});
            return;
        }
        if (t.vars.len == 0) {
            a.setStatus("E: `{s}` has no `.vars` to edit — add some beside its `.jql`", .{t.cfg.name});
            return;
        }
        a.closeVars();
        a.vars = try varsedit.Editor.init(a.gpa, a.active, t.file_idx, t.cfg.name, t.vars);
    }

    pub fn closeVars(a: *App) void {
        if (a.vars) |*v| v.deinit();
        a.vars = null;
    }

    /// Write every var back into the config file, one splice per var so
    /// only those spans move and every comment around them survives,
    /// then re-expand the tab's JQL and refetch.
    pub fn saveVars(a: *App) Allocator.Error!void {
        const e = &(a.vars orelse return);
        if (a.cfg_path.len == 0) {
            e.error_text = "no config file to save into";
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var idx_buf: [24]u8 = undefined;
        const tab_key = std.fmt.bufPrint(&idx_buf, "[{d}]", .{e.file_idx}) catch "[0]";
        var wrote: usize = 0;
        for (0..e.boxes.items.len) |vi| {
            const one = (try e.literalFor(arena, vi)) orelse continue;
            var var_buf: [24]u8 = undefined;
            const var_key = std.fmt.bufPrint(&var_buf, "[{d}]", .{vi}) catch continue;
            const path = [_][]const u8{ "tabs", tab_key, "vars", var_key, one.key };
            const outcome = sdk.zon_edit.persistScalar(a.gpa, a.io, a.cfg_path, &path, one.literal) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    e.error_text = try a.keep(try std.fmt.allocPrint(arena, "{s}: {s}", .{ e.boxes.items[vi].name, @errorName(err) }));
                    return;
                },
            };
            if (outcome == .written) wrote += 1;
        }
        // The tab picks the change up without a reload: its JQL is the
        // user's own text with the new values interpolated. Everything
        // the editor knows is read out BEFORE `closeVars` frees it —
        // the lines below used to reach back into it afterwards.
        const tab_idx = e.tab_idx;
        const t = &a.tabs[tab_idx];
        t.vars = try dupeVars(a.keys.allocator(), try e.asVars(arena));
        var edited = t.cfg;
        edited.vars = t.vars;
        t.jql = (try edited.staticJql(a.keys.allocator())) orelse t.jql;
        t.cfg = edited;
        const name = t.cfg.name;
        a.closeVars();
        if (wrote == 0) a.say("{s}: vars unchanged", .{name}) else a.say("{s}: {d} var(s) saved to {s}", .{ name, wrote, a.cfg_path });
        if (tab_idx == a.active) {
            t.fetched = false;
            try a.refreshActive();
        }
    }

    // ─── the detail modal ────────────────────────────────────────────────

    pub fn openModal(a: *App, key: []const u8) Allocator.Error!void {
        a.closeModal();
        // The arena goes into the field FIRST, and the allocator is
        // taken from where it will LIVE. An `ArenaAllocator`'s
        // `allocator()` binds to the address it was taken from, and a
        // `std.json.Value` is not plain data — every object and array
        // inside it keeps that handle — so a handle taken from a local
        // and then copied into `a.modal` points at a dead stack slot.
        a.modal = .{ .key = try a.keep(key), .arena = std.heap.ArenaAllocator.init(a.gpa) };
        const m = &a.modal.?;
        var fields: std.ArrayList([]const u8) = .empty;
        const arena = m.arena.allocator();
        for (a.cfg.detail_modal.fields) |spec| try fields.append(arena, a.cfg.detail_modal.resolveId(spec));
        for ([_][]const u8{ "summary", "status", "issuetype", "priority", "assignee", "reporter", "labels", "components", "fixVersions", "parent", "description", "customfield_10020" }) |baked| {
            var dup = false;
            for (fields.items) |f| if (std.mem.eql(u8, f, baked)) {
                dup = true;
            };
            if (!dup) try fields.append(arena, baked);
        }
        switch (jira.issueFull(a.client, arena, key, fields.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(Value){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |v| m.data = v,
            .failed => |f| m.error_text = try arena.dupe(u8, f.message),
        }
    }

    pub fn closeModal(a: *App) void {
        if (a.modal) |*m| m.arena.deinit();
        a.modal = null;
    }

    pub fn modalScroll(a: *App, delta: i32) void {
        const m = &(a.modal orelse return);
        const cur: i32 = m.scroll;
        m.scroll = @intCast(@max(cur + delta, 0));
    }

    // ─── the kanban ──────────────────────────────────────────────────────

    pub fn toggleCard(a: *App, key: []const u8) Allocator.Error!void {
        if (a.kanban_expanded.remove(key)) return;
        try a.kanban_expanded.put(a.gpa, try a.keep(key), {});
    }

    pub fn isCardExpanded(a: *const App, key: []const u8) bool {
        return a.kanban_expanded.contains(key);
    }

    pub fn scrollColumn(a: *App, col: usize, delta: i32) void {
        if (col >= kanban.count) return;
        const cur: i32 = a.kanban_scroll[col];
        a.kanban_scroll[col] = @intCast(@max(cur + delta, 0));
    }

    pub fn boardName(a: *App, id: u64) Allocator.Error![]const u8 {
        if (a.board_names.get(id)) |n| return n;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const name: []const u8 = switch (jira.board(a.client, scratch.allocator(), id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(model.Board){ .failed = .{ .status = 0, .message = "" } },
        }) {
            .ok => |b| try a.keep(b.name),
            .failed => try std.fmt.allocPrint(a.keys.allocator(), "{d}", .{id}),
        };
        try a.board_names.put(a.gpa, id, name);
        return name;
    }

    pub fn openBoardSettings(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("board settings: this tab has no `board_id`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const url = if (t.cfg.project.len > 0)
            try std.fmt.allocPrint(scratch.allocator(), "{s}/jira/software/c/projects/{s}/boards/{d}?config=filter", .{ a.cfg.jira_url, t.cfg.project, t.board_id })
        else
            try std.fmt.allocPrint(scratch.allocator(), "{s}/secure/RapidBoard.jspa?rapidView={d}&config=filter", .{ a.cfg.jira_url, t.board_id });
        try a.openUrl(url);
    }

    // ─── keys ────────────────────────────────────────────────────────────

    /// One key from the host. Returns false when nothing took it.
    pub fn onKey(a: *App, spec: []const u8) Allocator.Error!bool {
        a.touched();
        // The confirm owns the keyboard while it is up: it is the only
        // overlay behind which something irreversible is waiting.
        if (a.merge != null) {
            try a.mergeKey(spec);
            return true;
        }
        if (a.help) {
            // The family's one sheet grammar (`sdk.pane.keysheet.key`).
            if (sdk.pane.keysheet.scroll(&a.help_scroll, sdk.pane.keysheet.key(spec))) a.help = false;
            return true;
        }
        if (a.modal != null) {
            if (std.mem.eql(u8, spec, "esc") or std.mem.eql(u8, spec, "q")) a.closeModal() else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) a.modalScroll(2) else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) a.modalScroll(-2) else if (std.mem.eql(u8, spec, "pagedown")) a.modalScroll(10) else if (std.mem.eql(u8, spec, "pageup")) a.modalScroll(-10);
            return true;
        }
        if (a.vars) |*v| {
            if (v.edit != null) {
                // Typing a value: the line editor owns every key but
                // Enter (commit) and Esc (drop this one edit).
                if (std.mem.eql(u8, spec, "esc")) {
                    v.cancelEdit();
                } else if (std.mem.eql(u8, spec, "enter")) {
                    try v.commitEdit();
                } else _ = try v.edit.?.key(spec);
                return true;
            }
            if (std.mem.eql(u8, spec, "esc") or std.mem.eql(u8, spec, "q")) {
                a.closeVars();
            } else if (std.mem.eql(u8, spec, "ctrl+s") or std.mem.eql(u8, spec, "s")) {
                // `s` as well as Ctrl+S: Ctrl+S is the host's own save
                // chord, and a mounted pane cannot count on seeing it.
                try a.saveVars();
            } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) {
                v.move(-1);
            } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) {
                v.move(1);
            } else if (std.mem.eql(u8, spec, "enter") or std.mem.eql(u8, spec, "e")) {
                try v.beginEdit();
            } else if (std.mem.eql(u8, spec, "a")) {
                try v.addValue();
            } else if (std.mem.eql(u8, spec, "d") or std.mem.eql(u8, spec, "x") or std.mem.eql(u8, spec, "delete")) {
                try v.removeValue();
            }
            return true;
        }
        if (a.comment) |*c| {
            if (std.mem.eql(u8, spec, "esc")) {
                a.closeComment();
            } else if (std.mem.eql(u8, spec, "ctrl+s")) {
                try a.submitComment();
            } else if (std.mem.eql(u8, spec, "enter")) {
                // Enter is a newline; Enter on an empty last line sends,
                // since a host keeps Ctrl+S for itself.
                if (c.posting) return true;
                const t = c.edit.text();
                if (t.len > 0 and t[t.len - 1] == '\n' and c.edit.cursor == t.len) {
                    c.edit.buf.items.len = std.mem.trimEnd(u8, t, "\n").len;
                    c.edit.cursor = c.edit.buf.items.len;
                    try a.submitComment();
                } else try c.edit.insert("\n");
            } else if (!c.posting) _ = try c.edit.key(spec);
            return true;
        }
        if (a.picker) |*p| {
            if (std.mem.eql(u8, spec, "esc")) {
                a.closePicker();
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.commitPicker();
            } else if (std.mem.eql(u8, spec, "up")) {
                try p.move(-1);
            } else if (std.mem.eql(u8, spec, "down")) {
                try p.move(1);
            } else if (std.mem.eql(u8, spec, "backspace")) {
                try p.backspace();
            } else if (std.mem.eql(u8, spec, "space") and p.kind.multi()) {
                try p.toggleSelected();
            } else if (std.mem.eql(u8, spec, "space")) {
                try p.insert(" ");
            } else if (TextEdit.printable(spec)) |s| try p.insert(s);
            return true;
        }
        if (a.transition) |*p| {
            if (p.transitions == null and !std.mem.eql(u8, spec, "esc")) {
                // The list is still on the wire: what is typed now is
                // held and played when it lands, so `t 3 ⏎` typed
                // ahead of a slow site still moves the ticket.
                if (std.mem.eql(u8, spec, "enter")) {
                    p.pending_commit = true;
                } else if (keymap.tabDigit(spec)) |d| p.pending_jump = d;
                return true;
            }
            if (std.mem.eql(u8, spec, "esc")) {
                a.closeTransition();
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.commitTransition();
            } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) {
                p.move(-1);
            } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) {
                p.move(1);
            } else if (keymap.tabDigit(spec)) |d| p.jump(d);
            return true;
        }
        if (a.filter) |*f| if (f.editing) {
            if (std.mem.eql(u8, spec, "esc")) {
                try a.closeFilter(false);
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.closeFilter(true);
            } else if (try f.edit.key(spec)) {
                try a.clampCursor();
            }
            return true;
        };
        if (a.jql) |*e| {
            if (std.mem.eql(u8, spec, "esc")) {
                try a.closeJql(false);
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.closeJql(true);
            } else _ = try e.key(spec);
            return true;
        }
        if (!a.hasTabs()) {
            if (std.mem.eql(u8, spec, "q") or std.mem.eql(u8, spec, "esc")) a.quit = true;
            return true;
        }
        const action = keymap.resolve(spec, a.context()) orelse return false;
        a.status.clearRetainingCapacity();
        try a.act(action, spec);
        return true;
    }

    pub fn act(a: *App, action: keymap.Action, spec: []const u8) Allocator.Error!void {
        switch (action) {
            .quit => a.quit = true,
            .cancel_wait => a.cancelWait(),
            .toggle_dry_run => a.toggleDryRun(),
            .escape => {
                if (a.selection.count() > 0) {
                    a.clearSelection();
                } else if (a.filter != null) {
                    try a.closeFilter(false);
                } else if (a.details_visible) {
                    try a.toggleDetails();
                } else a.quit = true;
            },
            .refresh, .refresh_full => {
                if (a.details_visible) {
                    var scratch = std.heap.ArenaAllocator.init(a.gpa);
                    defer scratch.deinit();
                    if (try a.focusedKey(scratch.allocator())) |k| a.invalidateDetail(k);
                }
                // `r` asks only about what has moved since the last
                // whole listing; `R` asks for the listing again, which
                // is also the only thing that notices a ticket that
                // has dropped out of the query.
                try a.refreshActiveMode(if (action == .refresh_full) .full else .delta);
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .up => try a.move(-1),
            .down => try a.move(1),
            .page_up => try a.move(-10),
            .page_down => try a.move(10),
            .home => try a.moveHome(),
            .end => try a.moveEnd(),
            .open_browser => try a.openBrowser(),
            .next_tab => try a.nextTab(),
            .prev_tab => try a.prevTab(),
            .switch_tab => if (keymap.tabDigit(spec)) |d| try a.switchTab(d),
            .toggle_details => try a.toggleDetails(),
            .detail_scroll_up => a.details_scroll -|= 4,
            .detail_scroll_down => a.details_scroll +|= 4,
            .filter => try a.openFilter(),
            .jql_editor => try a.openJql(),
            .vars_editor => try a.openVars(),
            .transition => try a.openTransition(),
            .watch => try a.toggleWatch(),
            .comment => try a.openComment(),
            .toggle_select => try a.toggleSelection(),
            .assignee => try a.openAssignee(),
            .fix_version => try a.openFixVersion(),
            .tab_fix_version => try a.openTabFixVersion(),
            .team => try a.openTeam(),
            .action_picker => try a.openActions(),
            .tree_activate => try a.treeActivate(),
            .tree_expand => try a.treeExpand(),
            .tree_collapse => try a.treeCollapse(),
            .tree_expand_all => try a.treeExpandAll(),
            .tree_collapse_all => try a.treeCollapseAll(),
            .dispatch_implement => try a.dispatchTicket("implement"),
            .dispatch_fix => try a.dispatchTicket("fix"),
            .dispatch_triage => try a.dispatchTicket("triage"),
            .dispatch_review => try a.dispatchReview(),
            .merge_pr => {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedPrRow(scratch.allocator())) |f| try a.pressMerge(f.key, f.pr) else a.setStatus("no PR under cursor", .{});
            },
            .detail_modal => {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedKey(scratch.allocator())) |k| try a.openModal(k);
            },
            .card_expand => {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedKey(scratch.allocator())) |k| try a.toggleCard(k);
            },
            .help => {
                a.help = true;
                a.help_scroll = 0;
            },
        }
    }

    pub fn paste(a: *App, text_in: []const u8) Allocator.Error!void {
        a.touched();
        if (a.vars) |*v| {
            if (v.edit) |*t| try t.insert(text_in);
            return;
        }
        if (a.jql) |*e| try e.insert(text_in) else if (a.comment) |*c| try c.edit.insert(text_in) else if (a.filter) |*f| {
            if (f.editing) try f.edit.insert(text_in);
        } else if (a.picker) |*p| try p.insert(text_in);
    }

    // ─── the mouse ───────────────────────────────────────────────────────

    /// A press, routed by the hit map the last paint filled.
    pub fn click(a: *App, col: u16, row: u16, right: bool) Allocator.Error!void {
        a.touched();
        const target = a.hits.at(col, row);
        if (a.help) {
            a.help = false;
            // A row of the sheet runs its chord on the way out; anywhere
            // else on the sheet just closes it.
            if (target) |tg| if (tg == .help_row) {
                var kb: [16]u8 = undefined;
                const b = keymap.bindingOf(tg.help_row);
                try a.act(tg.help_row, if (b) |bb| keymap.displayKey(&kb, bb.keys[0]) else "");
            };
            return;
        }
        if (a.jql != null) {
            switch (target orelse hit.Target.jql_body) {
                .jql_text => |t| {
                    const r = a.hits.rectOf(target.?) orelse return;
                    a.jql.?.setCursorCodepoints(@as(usize, t.row) * a.jqlWrapWidth() + (col -| r.x));
                },
                .jql_body => {},
                else => try a.closeJql(false),
            }
            return;
        }
        if (a.picker != null) {
            switch (target orelse hit.Target.picker_body) {
                .picker_row => |i| {
                    a.picker.?.selected = i;
                    try a.commitPicker();
                },
                .picker_body => {},
                else => a.closePicker(),
            }
            return;
        }
        if (a.transition != null) {
            switch (target orelse hit.Target.picker_body) {
                .picker_row => |i| {
                    a.transition.?.jump(i);
                    try a.commitTransition();
                },
                .picker_body => {},
                else => a.closeTransition(),
            }
            return;
        }
        if (a.modal != null) {
            switch (target orelse hit.Target.modal_close) {
                .modal_body => {},
                else => a.closeModal(),
            }
            return;
        }
        if (a.vars) |*v| {
            switch (target orelse hit.Target.vars_close) {
                .vars_row => |i| {
                    if (v.edit != null) try v.commitEdit();
                    v.cursor = i;
                    try v.beginEdit();
                },
                .vars_save => try a.saveVars(),
                .vars_body => {},
                else => a.closeVars(),
            }
            return;
        }
        if (a.merge != null) {
            switch (target orelse .confirm_body) {
                .confirm_ok => try a.acceptMerge(),
                .confirm_cancel => a.closeMerge(),
                .confirm_body => {},
                else => a.closeMerge(),
            }
            return;
        }
        if (a.comment != null) return;
        const tg = target orelse return;
        switch (tg) {
            .row => |i| try a.clickRow(i, right),
            .chevron => |i| try a.clickChevron(i),
            // A build line is a door, not a row you select: the click
            // opens that run's page, the same as the forge pane's.
            .build_line => |i| try a.clickBuildLine(i, right),
            .show_more => |i| {
                a.tab().selected = i;
                try a.treeActivate();
            },
            .show_older => |i| {
                a.tab().selected = i;
                try a.treeActivate();
            },
            .pr_button => |b| try a.clickPrButton(b.row, b.which),
            // A dim `[ Merge ]` is not a `pr_button`: a click on one
            // says which condition fails rather than doing anything.
            .merge_blocked => |i| {
                a.tab().selected = i;
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedPrRow(scratch.allocator())) |f| {
                    try a.ensureReadiness(f.key, f.pr);
                    var buf: [192]u8 = undefined;
                    a.say("{s}", .{a.readinessOf(f.key, f.pr).hoverText(&buf)});
                }
            },
            .confirm_ok => try a.acceptMerge(),
            .confirm_cancel => a.closeMerge(),
            .confirm_body => {},
            .action => |x| {
                const iss = a.tab().issue(x.issue) orelse return;
                const buttons = dispatch.buttonsForTicket(iss);
                if (x.button >= buttons.len) return;
                const kind = buttons[x.button].kind();
                try a.selectIssue(x.issue);
                // What the press means is what the button says: a word
                // dispatches, a `[ view ]` focuses what it started.
                switch (sdk.pane.action.pressOf(a.actions.state(iss.key, kind))) {
                    .focus_session => try a.focusSessionFor(iss.key, kind),
                    .dispatch, .retry => try a.dispatchTicket(kind),
                }
            },
            .tab => |i| try a.switchTab(i),
            .chip => |c| try a.clickChip(c),
            .avatar => |i| {
                const t = a.tab();
                if (i < t.assignees.len) try a.toggleAssignee(t.assignees[i].account_id);
            },
            .filter => try a.openFilter(),
            .card => |i| {
                try a.selectIssue(i);
                if (right) {
                    try a.toggleCard(a.tab().issues[i].key);
                } else try a.openModal(a.tab().issues[i].key);
            },
            .card_chevron => |i| {
                try a.selectIssue(i);
                try a.toggleCard(a.tab().issues[i].key);
            },
            // A `key label` on the hint row, and a row of the key sheet,
            // run exactly what the key runs — the pointer reaches
            // everything the keyboard does.
            .hint, .help_row => |action| {
                var kb: [16]u8 = undefined;
                const b = keymap.bindingOf(action);
                try a.act(action, if (b) |bb| keymap.displayKey(&kb, bb.keys[0]) else "");
            },
            .detail_close => if (a.details_visible) try a.toggleDetails(),
            // A press or a drag anywhere on the track goes there: the
            // bar is a control, not a decoration.
            .detail_bar => {
                const r = a.hits.rectOf(hit.Target.detail_bar) orelse return;
                a.details_scroll = @intCast(sdk.pane.scrollAt(r, a.details_lines, a.details_rows, row));
            },
            .list_bar => try a.listBarTo(row),
            .column, .detail, .comment, .help_body, .picker_row, .picker_body, .modal_close, .modal_body, .jql_text, .jql_body => {},
            // Only reachable while the overlay is up, and that branch
            // returns above.
            .vars_row, .vars_save, .vars_close, .vars_body => {},
        }
    }

    fn selectIssue(a: *App, idx: usize) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.isTree()) {
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            const r = (try a.treeRows(scratch.allocator())) orelse return;
            if (idx < t.issues.len) if (tree.rowOfKey(r.rows, t.issues, t.issues[idx].key)) |ri| {
                t.selected = ri;
            };
        } else t.selected = idx;
        try a.afterMove();
    }

    fn clickRow(a: *App, i: u32, right: bool) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.isTree()) {
            t.selected = i;
            try a.afterMove();
            if (right) try a.treeActivate();
            return;
        }
        t.selected = i;
        try a.afterMove();
        if (right) try a.toggleSelection();
    }

    /// A press on a row's `\u{25b8}` / `\u{25be}`. A fold, never the row's
    /// Enter: on a group and a ticket the two happen to agree, but on a
    /// merged PR row Enter opens the PR in the browser — so routing the
    /// chevron through `treeActivate` made the one chevron that has
    /// something to reveal (the post-merge pipelines) launch a browser
    /// instead of expanding, which reads as "the mouse cannot fold".
    /// A press on a build line. Left goes to the run's page — the only
    /// thing the line stands for; right selects it, so the row menu and
    /// the keyboard still reach the rest of the tree from there.
    fn clickBuildLine(a: *App, i: u32, right: bool) Allocator.Error!void {
        const t = a.tab();
        t.selected = i;
        try a.afterMove();
        if (right) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const r = (try a.treeRows(scratch.allocator())) orelse return;
        if (i >= r.rows.len) return;
        switch (r.rows[i]) {
            .pipeline => |pl| try a.openBuild(pl),
            else => {},
        }
    }

    fn clickChevron(a: *App, i: u32) Allocator.Error!void {
        const t = a.tab();
        if (!t.cfg.isTree()) return;
        t.selected = i;
        try a.afterMove();
        try a.treeToggleFold();
    }

    /// Expand what is closed, close what is open — for whatever row the
    /// cursor is on. The chevron's action, and nothing else's.
    pub fn treeToggleFold(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group, .ticket, .show_more, .show_older => try a.treeActivate(),
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                const prs = st.prs(key) orelse return;
                if (p.pr_idx >= prs.len) return;
                const pr = prs[p.pr_idx];
                if (pr.url.len == 0) return;
                if (st.isPrExpanded(key, pr.id)) {
                    try st.setPrExpanded(key, pr.id, false);
                } else {
                    try st.setPrExpanded(key, pr.id, true);
                    try a.ensurePipelines(key, pr);
                }
                try a.clampCursor();
            },
            else => try a.treeCollapse(),
        }
    }

    fn clickPrButton(a: *App, row: u32, which: hit.PrButton) Allocator.Error!void {
        const t = a.tab();
        t.selected = row;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const r = (try a.focusedRow(scratch.allocator())) orelse return;
        const p = switch (r) {
            .pr => |p| p,
            else => return,
        };
        const key = t.issues[p.issue_idx].key;
        const prs = t.tree.?.prs(key) orelse return;
        if (p.pr_idx >= prs.len) return;
        switch (which) {
            .review => try a.dispatchReview(),
            // `[ Open ]` opens the ROW, not a browser: its builds fold
            // out under it. The PR itself is still one Enter away (and
            // the row menu's "open in browser"), which is where a link
            // belongs — a chip labelled Open that threw the reader into
            // a browser had no way back.
            .open => try a.togglePrBuilds(t.issues[p.issue_idx].key, prs[p.pr_idx]),
            .merge => try a.pressMerge(t.issues[p.issue_idx].key, prs[p.pr_idx]),
        }
    }

    pub fn clickChip(a: *App, c: hit.Chip) Allocator.Error!void {
        switch (c) {
            .refresh => try a.act(.refresh, "r"),
            .budget => a.cancelWait(),
            .help => try a.act(.help, "?"),
            .basic => {
                a.tab().show_jql = false;
                if (a.jql != null) try a.closeJql(false);
            },
            .jql => try a.openJql(),
            .vars => try a.openVars(),
            .search => try a.openFilter(),
            .assignee, .overflow => try a.openAssignees(),
            .type => try a.openIssueType(),
            .status => try a.cycleScope(),
            .fixv_pill, .version => try a.openTabFixVersion(),
            .fixv_remove => try a.removeFixVersionClause(),
            .board => try a.openBoard(),
            .sprint => try a.openSprint(),
            .epic => try a.openEpic(),
            .label => try a.openLabel(),
            .quick_filters => try a.openQuickFilters(),
            .unassigned => try a.toggleAssignee(model.unassigned_sentinel),
            .settings => try a.openBoardSettings(),
        }
    }

    /// A wheel notch; positive is up.
    /// The pointer moved with a button held. Only the detail panel's
    /// scrollbar tracks it: everything else on the pane acts on the
    /// press, and a drag that started elsewhere must not move things
    /// under the pointer on its way past.
    pub fn drag(a: *App, col: u16, row: u16) Allocator.Error!void {
        switch (a.hits.at(col, row) orelse return) {
            .detail_bar => {
                const r = a.hits.rectOf(hit.Target.detail_bar) orelse return;
                a.details_scroll = @intCast(sdk.pane.scrollAt(r, a.details_lines, a.details_rows, row));
            },
            .list_bar => try a.listBarTo(row),
            else => {},
        }
    }

    /// A press or a drag on the list's scrollbar: the row the pointer
    /// is over becomes the window's first row, and the cursor comes
    /// with it so the keys carry on from where the eye is.
    fn listBarTo(a: *App, row: u16) Allocator.Error!void {
        const r = a.hits.rectOf(hit.Target.list_bar) orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const rows = (try a.treeRows(scratch.allocator())) orelse return;
        const t = a.tab();
        t.scroll = sdk.pane.scrollAt(r, rows.rows.len, r.h, row);
        if (t.selected < t.scroll) t.selected = t.scroll;
        if (t.selected >= t.scroll + r.h) t.selected = t.scroll + r.h - 1;
        if (t.selected >= rows.rows.len) t.selected = rows.rows.len -| 1;
        try a.afterMove();
    }

    pub fn wheel(a: *App, col: u16, row: u16, dy: i16) Allocator.Error!void {
        a.touched();
        const steps: i32 = if (dy > 0) -3 else 3;
        if (a.modal != null) {
            a.modalScroll(steps);
            return;
        }
        if (a.help) {
            if (steps > 0) a.help_scroll += 3 else a.help_scroll -|= 3;
            return;
        }
        if (a.vars) |*v| {
            v.move(steps);
            return;
        }
        switch (a.hits.at(col, row) orelse hit.Target.help_body) {
            .column => |c| a.scrollColumn(c, steps),
            .detail, .detail_close, .detail_bar => {
                if (steps > 0) a.details_scroll +|= 3 else a.details_scroll -|= 3;
            },
            // The wheel over the list's bar moves the list, not the bar.
            .list_bar => try a.move(steps),
            .picker_row, .picker_body => if (a.picker) |*p| try p.move(steps) else if (a.transition) |*t| t.move(steps),
            else => try a.move(steps),
        }
    }

    /// The JQL editor's wrap width, shared with the painter.
    pub fn jqlWrapWidth(a: *const App) usize {
        const w: usize = @max(@min(a.cols -| 8, 200), 20);
        return @max(w -| 2, 1);
    }
};

/// `vars` copied onto `arena` — the App's `keys` arena outlives the
/// scratch the editor rendered them on.
fn dupeVars(arena: Allocator, vars: []const config.Var) Allocator.Error![]const config.Var {
    const out = try arena.alloc(config.Var, vars.len);
    for (vars, out) |src, *dst| {
        const vals = try arena.alloc([]const u8, src.values.len);
        for (src.values, vals) |v, *d| d.* = try arena.dupe(u8, v);
        dst.* = .{ .name = try arena.dupe(u8, src.name), .value = try arena.dupe(u8, src.value), .values = vals };
    }
    return out;
}

/// The reference's `strip_fix_version`: drop `fixVersion = "…"` and the
/// connector beside it.
pub fn stripFixVersion(arena: Allocator, jql: []const u8) Allocator.Error![]const u8 {
    var lower: [4096]u8 = undefined;
    const n = @min(jql.len, lower.len);
    for (jql[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const start = std.mem.indexOf(u8, lower[0..n], "fixversion") orelse return jql;
    const after = jql[start + "fixversion".len ..];
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return jql;
    const after_eq = after[eq + 1 ..];
    const q1 = std.mem.indexOfScalar(u8, after_eq, '"') orelse return jql;
    const rest = after_eq[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return jql;
    const clause_end = start + "fixversion".len + eq + 1 + q1 + 1 + q2 + 1;
    var before = std.mem.trimEnd(u8, jql[0..start], " ");
    var tail = std.mem.trimStart(u8, jql[clause_end..], " ");
    if (std.ascii.endsWithIgnoreCase(before, " and") or std.ascii.endsWithIgnoreCase(before, " or")) {
        before = std.mem.trimEnd(u8, before[0..std.mem.lastIndexOfScalar(u8, before, ' ').?], " ");
    } else if (std.ascii.startsWithIgnoreCase(tail, "and ") or std.ascii.startsWithIgnoreCase(tail, "or ")) {
        tail = std.mem.trimStart(u8, tail[std.mem.indexOfScalar(u8, tail, ' ').?..], " ");
    }
    if (before.len == 0) return tail;
    if (tail.len == 0) return before;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ before, tail });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const auth = @import("auth.zig");

test "stripFixVersion drops the clause and its connector" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("project = ENG ORDER BY rank", try stripFixVersion(a.allocator(), "project = ENG AND fixVersion = \"2.7.0\" ORDER BY rank"));
    try testing.expectEqualStrings("ORDER BY rank", try stripFixVersion(a.allocator(), "fixVersion = \"1\" AND ORDER BY rank"));
    try testing.expectEqualStrings("a = 1", try stripFixVersion(a.allocator(), "a = 1"));
}

/// A pane against the fake server behind a real socket.
pub const Harness = struct {
    lb: jira.Loopback,
    store: *jira.fake.Store,
    server: *Io.net.Server,
    group: Io.Group = .init,
    /// Set by `stop` before it cancels, so the watchdog does not read
    /// the accept loop's cancel as the fake giving up.
    stopping: std.atomic.Value(bool) = .init(false),
    client: *jira.Client,
    app: App,
    base: []const u8,
    /// `<base>/2.0` — where the forge corner of the fake lives.
    forge_base: []const u8,

    pub fn start(cfg_in: config.Config, family: ?config.Family) !*Harness {
        return startOn(cfg_in, family, testing.allocator);
    }

    /// The Harness with the FETCH side on `gpa` — the client, the forge
    /// client, and the App, which is where every job and every result
    /// arena is made (`startRefresh`, `startPrFetch`). `Scribble` passes
    /// one that poisons what it frees, which is the only way a test can
    /// see a pane still pointing at a listing that is over.
    pub fn startOn(cfg_in: config.Config, family: ?config.Family, gpa: Allocator) !*Harness {
        const io = testing.io;
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.store = try testing.allocator.create(jira.fake.Store);
        h.store.* = try jira.fake.Store.init(testing.allocator);
        h.server = try testing.allocator.create(Io.net.Server);
        var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        h.server.* = try addr.listen(io, .{ .reuse_address = true });
        h.lb = .{ .store = h.store, .server = h.server };
        h.group = .init;
        h.stopping = .init(false);
        try h.group.concurrent(io, jira.Loopback.serve, .{ io, &h.lb });
        h.base = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{h.server.socket.address.getPort()});
        // The forge lives under `/2.0` on Bitbucket and on the fake, so
        // the pane's forge calls must carry it here too — without it
        // every one of them landed on the Jira half of the fake and
        // came back 401, which is why nothing ever exercised them.
        h.forge_base = try std.fmt.allocPrint(testing.allocator, "{s}/2.0", .{h.base});
        const authorization = try auth.basicHeader(testing.allocator, "fake@acme.com", "fake-token");
        defer testing.allocator.free(authorization);
        h.client = try testing.allocator.create(jira.Client);
        h.client.* = jira.Client.init(gpa, io, h.base, try testing.allocator.dupe(u8, authorization), .v3);
        var cfg = cfg_in;
        cfg.jira_url = h.base;
        cfg.email = "fake@acme.com";
        cfg.refresh_interval_secs = 0;
        cfg.bitbucket_api_url = h.forge_base;
        h.app = try App.init(gpa, io, cfg, family, h.client, .{ .gpa = gpa, .io = io, .base_url = h.forge_base, .token = "fake-forge" });
        h.app.resize(120, 40);
        try h.group.concurrent(io, watch, .{ io, h });
        return h;
    }

    /// What is on the wire, for the watchdog's message. Read from the
    /// watchdog's thread while the test runs: a best-effort picture.
    fn parked(h: *Harness) Parked {
        return .{ .h = h };
    }

    const Parked = struct {
        h: *Harness,
        pub fn format(p: Parked, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const lb = &p.h.lb;
            const a = &p.h.app;
            try w.print("fake Jira: {t}, {d} connections taken, {d} dropped by a client that hung up; pane workers in flight: detail/transitions look {}, refetch {}, PR fetch {}", .{
                lb.phase.load(.acquire),
                lb.served.load(.monotonic),
                lb.dropped.load(.monotonic),
                @atomicLoad(bool, &a.looks.running, .monotonic),
                @atomicLoad(bool, &a.refresh.running, .monotonic),
                @atomicLoad(bool, &a.prs.running, .monotonic),
            });
        }
    };

    pub fn stop(h: *Harness) void {
        // Cancelled, not asked over the wire: a `/__done` request is one
        // more read that parks forever if the fake is not answering, and
        // a teardown must not depend on the thing it is tearing down.
        h.stopping.store(true, .release);
        h.group.cancel(testing.io);
        h.app.deinit();
        testing.allocator.free(h.client.authorization);
        testing.allocator.destroy(h.client);
        h.server.deinit(testing.io);
        testing.allocator.destroy(h.server);
        h.store.deinit();
        testing.allocator.destroy(h.store);
        testing.allocator.free(h.base);
        testing.allocator.free(h.forge_base);
        testing.allocator.destroy(h);
    }
};

/// How long one Harness may live before its watchdog calls the test a
/// hang. A Harness test is milliseconds; a loaded CI box a few seconds.
pub const harness_deadline_ms: u32 = 120_000;

/// The Harness's watchdog. Every request a Harness test makes — the
/// test thread's own and every pane worker's — blocks on a read with
/// no deadline, so a fake that stops answering is a hang, not a
/// failure: 53 minutes of one, once. This turns both shapes of it into
/// a red test that names what is parked: the accept loop ending while
/// the test still runs (at once — every later request would park), and
/// the test outliving `harness_deadline_ms`.
fn watch(io: Io, h: *Harness) Io.Cancelable!void {
    var waited: u32 = 0;
    while (true) : (waited += 20) {
        try io.sleep(.fromMilliseconds(20), .awake);
        if (h.stopping.load(.acquire)) return;
        const phase = h.lb.phase.load(.acquire);
        if (phase == .done or phase == .canceled)
            std.debug.panic("jira Harness: the fake Jira's accept loop ended ({t}) with the test still running — every request from here parks forever in the listen backlog. {f}", .{ phase, h.parked() });
        if (waited >= harness_deadline_ms)
            std.debug.panic("jira Harness: the test is still running after {d} s — something is parked on a request. {f}", .{ harness_deadline_ms / 1000, h.parked() });
    }
}

pub const work_tabs = [_]config.Tab{
    .{ .name = "Assigned", .kind = .work_assigned },
    .{ .name = "Recently Done", .kind = .work_recently_done },
};

pub const fixv_tabs = [_]config.Tab{
    .{ .name = "Current Release", .kind = .fix_version_tree, .project = "ENG", .mode = .current_release, .status_order = &.{ "Testing", "In PR Review", "In Progress", "To Do", "Done" }, .bumps = .{ .pr_approved = "Testing", .no_open_prs = "Testing", .release_cut = &.{.{ .status = "Done", .target = "top" }} } },
};

/// A Work family with the three kinds the pane ships: the open-work
/// count, what you filed, and an editable-JQL tab with two holes.
pub const editable_tabs = [_]config.Tab{
    .{ .name = "My open work items", .kind = .work_open },
    .{ .name = "Reported by me", .kind = .work_reported },
    .{
        .name = "QA Actionable now",
        .kind = .jql_editable,
        .jql = "project = {project} AND fixVersion in ({versions}) ORDER BY updated DESC",
        .vars = &.{
            .{ .name = "project", .value = "ENG" },
            .{ .name = "versions", .values = &.{ "2.4.0", "2.3.0" } },
        },
    },
};

pub const board_tabs = [_]config.Tab{
    .{ .name = "Sprint", .kind = .board_active_sprint, .project = "ENG", .board_id = 7 },
    .{ .name = "Backlog", .kind = .board_backlog, .project = "ENG" },
};

test "Work: E / C open and shut every group, the cursor staying on the group it was in — the Bitbucket pane's pair" {
    // hunt/findings-2026-09-23/integ-tree-nav-convention.md
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var steps: usize = 0;
    while (steps < 20) : (steps += 1) {
        if (try a.focusedKey(ar)) |k| if (std.mem.eql(u8, k, "ENG-1")) break;
        _ = try a.onKey("j");
    }
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(ar)).?);
    _ = try a.onKey("shift+c");
    const shut = (try a.treeRows(ar)).?;
    try testing.expectEqual(@as(usize, 3), shut.rows.len);
    for (shut.rows) |r| try testing.expect(r == .group and !r.group.expanded);
    try testing.expectEqualStrings("In Progress", (try a.focusedRow(ar)).?.group.status);
    _ = try a.onKey("shift+e");
    const open = (try a.treeRows(ar)).?;
    try testing.expect(open.rows.len > 3);
    for (open.rows) |r| if (r == .group) try testing.expect(r.group.expanded);
    try testing.expectEqualStrings("In Progress", (try a.focusedRow(ar)).?.group.status);
    // J, not E, is the JQL editor now.
    _ = try a.onKey("shift+j");
    try testing.expect(a.jql != null);
}

test "Work: the assigned tab loads the three tickets, auto-expands them with their PRs, and the tree keys fold and move" {
    const h = try Harness.start(.{ .tabs = &work_tabs, .team_field_id = "customfield_10056" }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    try testing.expectEqual(@as(?usize, 3), a.assigned_open);
    try testing.expect(a.segment_dirty);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try a.treeRows(arena.allocator())).?;
    // No bumps on the Work tabs: the default order puts In PR Review
    // first, ENG-2 auto-expanded with its two PRs under it.
    try testing.expectEqualStrings("In PR Review", r.rows[0].group.status);
    try testing.expect(!r.rows[1].ticket.bumped);
    try testing.expect(r.rows[2] == .pr and r.rows[3] == .pr);
    // The linked PRs now arrive with the search rather than after it, so
    // the status a refetch leaves is the tab's summary.
    try testing.expectEqualStrings("Assigned · 3 issues", a.status.items);
    // The focused row starts on the first group; j reaches the ticket.
    _ = try a.onKey("j");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);
    // h folds the ticket, l opens it again; the cursor stays on ENG-2.
    _ = try a.onKey("h");
    const folded = (try a.treeRows(arena.allocator())).?;
    try testing.expect(folded.rows[2] != .pr);
    _ = try a.onKey("l");
    try testing.expect((try a.treeRows(arena.allocator())).?.rows[2] == .pr);
    // A refetch keeps the cursor on the same ticket.
    _ = try a.onKey("r");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);
    // Tab switches; the second tab loads on arrival.
    _ = try a.onKey("tab");
    try testing.expectEqual(@as(usize, 1), a.active);
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-12", a.tab().issues[0].key);
    _ = try a.onKey("1");
    try testing.expectEqual(@as(usize, 0), a.active);
}

test "`--focus` lands the cursor on that ticket and opens its detail, whatever case it was asked for in" {
    const h = try Harness.start(.{ .tabs = &work_tabs, .team_field_id = "customfield_10056" }, .work);
    defer h.stop();
    const a = &h.app;
    // The flag is read before there is any listing to land in, which is
    // the whole reason it is remembered rather than applied.
    a.setFocusKey("eng-5");
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ENG-5", (try a.focusedKey(arena.allocator())).?);
    // And the panel beside the list is open on it, not on whatever the
    // cursor happened to start on — which is the first group's row.
    try testing.expect(a.details_visible);
    // Consumed: a later refetch does not drag the cursor back off the
    // row the reader moved it to.
    try testing.expectEqual(@as(usize, 0), a.focus_key_len);
    const rows = (try a.treeRows(arena.allocator())).?.rows;
    a.tab().selected = tree.rowOfKey(rows, a.tab().issues, "ENG-1").?;
    _ = try a.onKey("r");
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(arena.allocator())).?);
}

test "a forwarded focus opens the section that was folded shut, drops the filter hiding the row, and says so when the key is in no listing" {
    const h = try Harness.start(.{ .tabs = &work_tabs, .team_field_id = "customfield_10056" }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Two things hide ENG-5: its section folded shut, and a `/` query
    // from before that matches only ENG-1.
    try a.tab().tree.?.setGroup("To Do", true);
    try a.openFilter();
    if (a.filter) |*f| try f.edit.set("Checkout");
    try a.closeFilter(true);
    try testing.expect(tree.rowOfKey((try a.treeRows(arena.allocator())).?.rows, a.tab().issues, "ENG-5") == null);

    // The press on the hover row, handed to a pane that is already up.
    try a.requestFocus("ENG-5");
    try testing.expectEqualStrings("ENG-5", (try a.focusedKey(arena.allocator())).?);
    try testing.expect(a.filter == null);
    try testing.expect(!a.tab().tree.?.isCollapsed("To Do"));

    // A second row moves the cursor again rather than waiting for a
    // refetch that is not coming.
    try a.requestFocus("ENG-2");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);

    // And one that names nothing this pane holds is answered, not
    // silently ignored — the cursor stays where the reader left it.
    const before = a.tab().selected;
    try a.requestFocus("ENG-4242");
    try testing.expectEqualStrings("not in this listing: ENG-4242", a.status.items);
    try testing.expectEqual(before, a.tab().selected);
    try testing.expectEqual(@as(usize, 0), a.focus_key_len);
}

test "every PR row folds out to its builds — an open one on its branch head — and the second look costs one request, not two" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const st = &(a.tab().tree.?);
    const prs = st.prs("ENG-2").?;
    try testing.expectEqual(@as(usize, 2), prs.len);
    // #2023 merged, #2044 open — and it is the OPEN one that used to
    // answer "PR not merged — no merge commit" and show nothing.
    try testing.expect(prs[0].isMerged());
    try testing.expect(prs[1].isOpen());

    const before = h.store.requests;
    try a.togglePrBuilds("ENG-2", prs[1]);
    // The PR detail, then the pipelines list: two requests the first time.
    try testing.expectEqual(@as(usize, 2), h.store.requests - before);
    const runs = st.pipelines("ENG-2", prs[1].id).?;
    // Both runs on the branch head, newest first; nothing from the
    // other branches in the same repo.
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqual(@as(i64, 414), runs[0].build_number);
    try testing.expectEqual(@as(i64, 413), runs[1].build_number);
    try testing.expectEqualStrings("feat/trim", runs[0].branch);
    const meta = st.pipelineMeta("ENG-2", prs[1].id).?;
    try testing.expect(!meta.on_merge);
    try testing.expect(meta.updated_on.len > 0);

    // Fold shut, fold open: nothing is asked for again.
    try a.togglePrBuilds("ENG-2", prs[1]);
    try a.togglePrBuilds("ENG-2", prs[1]);
    try testing.expectEqual(@as(usize, 2), h.store.requests - before);
    // A deliberate re-look costs ONE request: the PR has not moved, so
    // the pipelines list is not asked for at all.
    try a.loadPipelines("ENG-2", prs[1], true);
    try testing.expectEqual(@as(usize, 3), h.store.requests - before);
    try testing.expect(std.mem.indexOf(u8, a.status.items, "unchanged") != null);

    // The merged one still folds out to what landed.
    try a.togglePrBuilds("ENG-2", prs[0]);
    const merged_runs = st.pipelines("ENG-2", prs[0].id).?;
    try testing.expectEqual(@as(usize, 1), merged_runs.len);
    try testing.expectEqual(@as(i64, 412), merged_runs[0].build_number);
    try testing.expect(st.pipelineMeta("ENG-2", prs[0].id).?.on_merge);

    // The rows: a build line per run under its PR.
    const rows = (try a.treeRows(ar)).?.rows;
    var builds: usize = 0;
    for (rows) |row| builds += @intFromBool(row == .pipeline);
    try testing.expectEqual(@as(usize, 3), builds);

    // And the line itself is the toolkit's, so both panes read alike.
    a.now_secs = sdk.pane.build.parseEpoch(runs[0].created_on).? + 3600;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("\u{23f5} IN_PROGRESS \u{b7} feat/trim \u{b7} 1h \u{b7} #414", sdk.pane.build.caption(&buf, .{
        .state = runs[0].stateLabel(),
        .branch = runs[0].branch,
        .created_on = runs[0].created_on,
        .number = runs[0].build_number,
    }, a.nowSecs(), false));
}

test "a PR row's Merge is dim until the pull request may merge, and says which condition fails" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const st = &(a.tab().tree.?);
    const prs = st.prs("ENG-2").?;
    const open_pr = prs[1]; // #2044, OPEN
    try testing.expect(open_pr.isOpen());

    // Nothing looked at: dim, and it says exactly that rather than
    // claiming a blocker nobody checked.
    var buf: [192]u8 = undefined;
    try testing.expect(!a.readinessOf("ENG-2", open_pr).ready());
    try testing.expectEqualStrings("Merge: not checked yet \u{2014} open the row to look", a.readinessOf("ENG-2", open_pr).hoverText(&buf));

    const before = h.store.requests;
    try a.ensureReadiness("ENG-2", open_pr);
    const spent = h.store.requests - before;
    // The detail, the diffstat, the comments, the pipelines.
    try testing.expectEqual(@as(usize, 4), spent);
    const got = a.readinessOf("ENG-2", open_pr);
    try testing.expect(got.checked);
    // The fake's #2044 has two open tasks and one unanswered comment,
    // and its newest run is IN_PROGRESS — the earliest unmet condition
    // is the one named.
    try testing.expect(!got.ready());
    try testing.expectEqualStrings("Merge: 0 of 1 approvals", got.hoverText(&buf));

    // A second look while it has not moved costs ONE request — the PR
    // detail, which is what says it has not moved.
    try a.ensureReadiness("ENG-2", open_pr);
    try testing.expectEqual(spent + 1, h.store.requests - before);

    // A press on a dim button starts nothing and says why.
    try a.pressMerge("ENG-2", open_pr);
    try testing.expect(a.merge == null);
    try testing.expect(std.mem.indexOf(u8, a.status.items, "approvals") != null);
}

test "a ready PR opens the named confirm, and confirming dispatches a Claude Code session" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, ".mnml/" ++ dispatch.ipc_subdir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/" ++ dispatch.ipc_subdir ++ "/command", .data = "" });
    const h = try Harness.start(.{ .tabs = &work_tabs, .dispatch_workspace = root }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const st = &(a.tab().tree.?);
    const pr = st.prs("ENG-2").?[1];

    // Stand the judgment up as clean: what this asserts is what the
    // pane does once it IS ready.
    try st.putReadiness("ENG-2", pr.id, .{
        .updated_on = "2026-01-01T00:00:00+00:00",
        .readiness = .{ .approvals = 1, .required = 1, .conflicts = false, .build_green = true, .checked = true },
    });
    try testing.expect(a.readinessOf("ENG-2", pr).ready());

    try a.pressMerge("ENG-2", pr);
    const m = a.merge.?;
    try testing.expectEqualStrings("Follow-up: trim the whitespace", m.confirm.title);
    try testing.expectEqualStrings("feat/trim", m.confirm.source);
    try testing.expectEqualStrings("main", m.confirm.target);
    try testing.expectEqual(sdk.pane.merge.Strategy.merge_commit, m.confirm.strategy);
    a.cycleMergeStrategy();
    try testing.expectEqual(sdk.pane.merge.Strategy.squash, a.merge.?.confirm.strategy);

    try a.acceptMerge();
    try testing.expect(a.merge == null);
    var kbuf: [256]u8 = undefined;
    const row_key = try std.fmt.bufPrint(&kbuf, "ENG-2\u{0}{s}", .{pr.id});
    try testing.expectEqual(sdk.pane.ActionState.running, a.actions.state(row_key, "merge"));
    try testing.expectEqual(@as(usize, 1), a.watch_out.items.len);

    // What was written is a `term` line seeding Claude Code with the
    // prompt — the pane merged nothing itself.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try tmp.dir.readFileAlloc(testing.io, ".mnml/" ++ dispatch.ipc_subdir ++ "/command", arena.allocator(), .unlimited);
    try testing.expect(std.mem.indexOf(u8, line, "\"cmd\":\"term\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "/agents:merge-pr https://bitbucket.org/acme/checkout/pull-requests/2044") != null);
    try testing.expect(std.mem.indexOf(u8, line, "merge_strategy: squash") != null);
    try testing.expect(std.mem.indexOf(u8, line, "$BITBUCKET_ACCESS_TOKEN") != null);
}

test "Work: the filter narrows the tree (unlike the reference), the scope chip cycles, and Esc unwinds without quitting early" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("/");
    try testing.expect(a.filter.?.editing);
    for ("voucher") |c| _ = try a.onKey(&[_]u8{c});
    _ = try a.onKey("enter");
    try testing.expect(!a.filter.?.editing);
    const r = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqual(@as(usize, 1), r.ticket_count);
    try testing.expectEqualStrings("ENG-5", a.tab().issues[r.rows[1].ticket.issue_idx].key);
    _ = try a.onKey("esc");
    try testing.expect(a.filter == null);
    try testing.expect(!a.quit);
    try a.cycleScope();
    try testing.expectEqual(filters.Scope.unresolved, a.tab().scope);
    try a.cycleScope();
    try testing.expectEqual(@as(usize, 0), (try a.treeRows(arena.allocator())).?.ticket_count);
    try a.cycleScope();
    try testing.expectEqual(filters.Scope.all, a.tab().scope);
    _ = try a.onKey("d");
    try testing.expect(a.details_visible);
    _ = try a.onKey("esc");
    try testing.expect(!a.details_visible and !a.quit);
    _ = try a.onKey("esc");
    try testing.expect(a.quit);
}

test "Work: the transition picker moves a ticket; the bulk selection transitions by name and skips" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("j");
    _ = try a.onKey("t");
    try testing.expect(a.transition != null);
    try testing.expectEqual(@as(usize, 4), a.transition.?.transitions.?.len);
    _ = try a.onKey("esc");
    try testing.expect(a.transition == null);
    // Select ENG-2 and ENG-5 (S on a tree tab), then move both to Testing.
    _ = try a.onKey("shift+s");
    try testing.expect(a.isSelected("ENG-2"));
    try a.moveEnd();
    try a.moveHome();
    // Find ENG-5's row.
    const r = (try a.treeRows(arena.allocator())).?;
    a.tab().selected = tree.rowOfKey(r.rows, a.tab().issues, "ENG-5").?;
    _ = try a.onKey("shift+s");
    try testing.expectEqual(@as(usize, 2), a.selection.count());
    _ = try a.onKey("t");
    try testing.expectEqual(@as(usize, 2), a.transition.?.targets);
    // Jump to "Ready to test" (Testing) and commit.
    for (a.transition.?.transitions.?, 0..) |t, i| if (std.mem.eql(u8, t.to_name, "Testing")) a.transition.?.jump(i);
    _ = try a.onKey("enter");
    try testing.expect(a.transition == null);
    try testing.expectEqualStrings("Testing", h.store.find("ENG-2").?.status);
    try testing.expectEqualStrings("Testing", h.store.find("ENG-5").?.status);
    try testing.expectEqual(@as(usize, 0), a.selection.count());
    try testing.expect(std.mem.startsWith(u8, a.status.items, "2 ticket(s) → Testing"));
}

test "a single transition invalidates the detail of the ticket it moved, after the picker that carried the key is gone" {
    // `commitTransition` held `p.key` — a slice on the picker's OWN
    // arena — across `closeTransition`, which is that arena's `deinit`,
    // and then hashed it in `invalidateDetail`. On a scribbling
    // allocator the key is 0xAA by then, so the lookup matches nothing
    // and the STALE detail survives the move that made it stale.
    var scribble: sdk.testing.Scribble = .{ .child = testing.allocator };
    const h = try Harness.startOn(.{ .tabs = &work_tabs }, .work, scribble.allocator());
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try a.treeRows(arena.allocator())).?;
    a.tab().selected = tree.rowOfKey(r.rows, a.tab().issues, "ENG-2").?;

    // Open the panel so the ticket's detail is cached, then close it
    // again. The entry stays — that is the point of the cache — and
    // with the panel shut nothing re-fetches behind the transition, so
    // what the assertion sees is the invalidation itself.
    _ = try a.onKey("d");
    try testing.expect(a.details.contains("ENG-2"));
    _ = try a.onKey("d");
    try testing.expect(!a.details_visible);
    try testing.expect(a.details.contains("ENG-2"));

    _ = try a.onKey("t");
    try testing.expect(a.transition != null);
    for (a.transition.?.transitions.?, 0..) |tr, i| if (std.mem.eql(u8, tr.to_name, "Testing")) a.transition.?.jump(i);
    _ = try a.onKey("enter");
    try testing.expect(a.transition == null);

    // The move landed…
    try testing.expectEqualStrings("Testing", h.store.find("ENG-2").?.status);
    // …it was named with the ticket it was about…
    try testing.expect(std.mem.indexOf(u8, a.status.items, "ENG-2") != null);
    // …and the detail that is now out of date is GONE. This is the
    // assertion the freed key defeats: `fetchRemove` on 0xAA bytes
    // matches nothing and leaves the stale entry in place.
    try testing.expect(!a.details.contains("ENG-2"));
}

test "Work: the assignee picker assigns, the fixVersion picker sets, watching toggles, a comment posts" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    _ = try a.onKey("j");
    _ = try a.onKey("a");
    try testing.expectEqual(pickers.Kind.assignee, a.picker.?.kind);
    try testing.expectEqualStrings("— Unassign —", a.picker.?.items[0].label);
    for ("lin") |c| _ = try a.onKey(&[_]u8{c});
    _ = try a.onKey("enter");
    try testing.expect(a.picker == null);
    try testing.expectEqualStrings(jira.fake.account_lin, h.store.find("ENG-2").?.assignee);
    // ENG-2 is Lin's now, so the assigned tab dropped it; the cursor is
    // back on the first group and j lands on ENG-1.
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    _ = try a.onKey("j");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(arena.allocator())).?);
    _ = try a.onKey("f");
    try testing.expectEqual(pickers.Kind.fix_version, a.picker.?.kind);
    a.picker.?.selectId("2.5.0");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("2.5.0", h.store.find("ENG-1").?.fix_version);
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(arena.allocator())).?);
    // Watching toggles against the site's list.
    const before = h.store.find("ENG-1").?.watchers.items.len;
    try a.ensureDetail("ENG-1");
    const was = a.detailOf("ENG-1").?.watching;
    _ = try a.onKey("w");
    try testing.expectEqual(if (was) before - 1 else before + 1, h.store.find("ENG-1").?.watchers.items.len);
    try a.ensureDetail("ENG-1");
    try testing.expectEqual(!was, a.detailOf("ENG-1").?.watching);
    _ = try a.onKey("w");
    try testing.expectEqual(before, h.store.find("ENG-1").?.watchers.items.len);
    // A comment needs the detail pane.
    const comments = h.store.find("ENG-1").?.comments.items.len;
    _ = try a.onKey("c");
    try testing.expect(a.comment == null);
    _ = try a.onKey("d");
    _ = try a.onKey("c");
    try testing.expect(a.comment != null);
    for ("on it") |c| _ = try a.onKey(if (c == ' ') "space" else &[_]u8{c});
    // Enter is a newline; a second Enter on the empty line sends.
    _ = try a.onKey("enter");
    try testing.expect(a.comment != null);
    _ = try a.onKey("enter");
    try testing.expect(a.comment == null);
    try testing.expectEqual(comments + 1, h.store.find("ENG-1").?.comments.items.len);
    const d = a.detailOf("ENG-1").?;
    try testing.expect(std.mem.indexOf(u8, d.comments[d.comments.len - 1].body, "on it") != null);
}

test "a row's action button keeps what its press left, by ticket, across a refetch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const h = try Harness.start(.{ .tabs = &work_tabs, .dispatch_workspace = root }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Nothing pressed: every button is on its own word.
    try testing.expectEqual(sdk.pane.ActionState.idle, a.actions.state("ENG-5", "triage"));
    // With nowhere to dispatch to, the press leaves a cross and the
    // reason on the button rather than a status that scrolls away.
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    // Copied: `focusedKey` borrows from the tab's data arena, which the
    // refetch below replaces.
    const key = try arena.allocator().dupe(u8, (try a.focusedKey(arena.allocator())).?);
    try a.dispatchTicket("triage");
    try testing.expectEqual(sdk.pane.ActionState.failed, a.actions.state(key, "triage"));
    try testing.expect(std.mem.indexOf(u8, a.actions.get(key, "triage").detail, "nothing to dispatch to") != null);

    // With both channels there, the press starts a session and the
    // button becomes the door to it.
    try tmp.dir.createDirPath(testing.io, ".claude");
    try tmp.dir.createDirPath(testing.io, ".mnml/" ++ dispatch.ipc_subdir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/" ++ dispatch.ipc_subdir ++ "/command", .data = "" });
    try a.dispatchTicket("triage");
    // A session was STARTED, not finished: the button turns a spinner
    // and waits for the host to say what happened to it.
    try testing.expectEqual(sdk.pane.ActionState.running, a.actions.state(key, "triage"));
    // What it remembers is the prompt's first line — all a `term` line
    // can say about the session it started.
    try testing.expect(std.mem.startsWith(u8, a.actions.get(key, "triage").prompt_line, "/agents:developer "));
    // …and the same two names go out as a `watch_session`, so the host
    // can find the session it just started.
    try testing.expectEqual(@as(usize, 1), a.watch_out.items.len);
    var kbuf: [320]u8 = undefined;
    try testing.expectEqualStrings(sdk.pane.actionWatchKey(&kbuf, key, "triage"), a.watch_out.items[0].key);
    try testing.expectEqualStrings(root, a.watch_out.items[0].cwd);
    try testing.expect(std.mem.startsWith(u8, a.watch_out.items[0].prompt_line, "/agents:developer "));
    // A second action on the same ticket is its own button.
    try testing.expectEqual(sdk.pane.ActionState.idle, a.actions.state(key, "fix"));

    // The host's word moves it: the session stops to ask something,
    // then ends. The question lands where the reason for a failure
    // does — on the button, for the hint row.
    const watch_key = try arena.allocator().dupe(u8, a.watch_out.items[0].key);
    try a.onSessionState(watch_key, .waiting, "sid-77", "Do you want me to run the migration?");
    try testing.expectEqual(sdk.pane.ActionState.waiting, a.actions.state(key, "triage"));
    try testing.expectEqualStrings("Do you want me to run the migration?", a.actions.get(key, "triage").detail);
    try a.onSessionState(watch_key, .done, "sid-77", "");
    try testing.expectEqual(sdk.pane.ActionState.view, a.actions.state(key, "triage"));
    try testing.expectEqualStrings("sid-77", a.actions.get(key, "triage").session);
    // A line for a button this pane does not have changes nothing.
    try a.onSessionState(sdk.pane.actionWatchKey(&kbuf, "ENG-999", "triage"), .failed, "", "boom");
    try testing.expectEqual(sdk.pane.ActionState.idle, a.actions.state("ENG-999", "triage"));

    // A refetch moves the rows; the button follows its ticket.
    try a.refreshActive();
    try testing.expectEqual(sdk.pane.ActionState.view, a.actions.state(key, "triage"));
    // And a press on it now asks for the session rather than dispatching
    // again — without a channel it says so instead of pretending.
    try a.focusSessionFor(key, "triage");
    try testing.expect(std.mem.indexOf(u8, a.status.items, "no mnml channel") != null);
}

test "on a board, d opens the modal the hint row promises rather than nothing" {
    const h = try Harness.start(.{ .tabs = &board_tabs }, .boards);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expect(a.tab().cfg.isKanban());
    // The kanban paint has no side panel to give up four columns for,
    // so `details_visible` was flipped and nothing appeared.
    _ = try a.onKey("d");
    try testing.expect(!a.details_visible);
    try testing.expect(a.modal != null);
    // …and the tree families still get the side panel.
    _ = try a.onKey("esc");
    _ = try a.onKey("2");
    _ = try a.onKey("d");
    if (a.tab().cfg.isKanban()) return;
    try testing.expect(a.details_visible);
}

test "a PR row's Review button remembers its press, keyed by the pull request" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, ".claude");
    try tmp.dir.createDirPath(testing.io, ".mnml/" ++ dispatch.ipc_subdir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/" ++ dispatch.ipc_subdir ++ "/command", .data = "" });
    const h = try Harness.start(.{ .tabs = &work_tabs, .dispatch_workspace = root }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Onto the first linked-PR row — the ones that carry
    // `[ Open ] [ Review ] [ Merge ]`.
    var steps: usize = 0;
    const p = while (steps < 40) : (steps += 1) {
        if (try a.focusedRow(ar)) |row| switch (row) {
            .pr => |pr| break pr,
            else => {},
        };
        _ = try a.onKey("j");
    } else return error.NoPrRow;
    const iss_key = try ar.dupe(u8, a.tab().issues[p.issue_idx].key);
    const pr_id = try ar.dupe(u8, a.tab().tree.?.prs(iss_key).?[p.pr_idx].id);
    const row_key = try App.prRowKey(ar, iss_key, pr_id);

    // The press dispatched and left nothing behind: the status said so
    // for a moment and the button went back to looking un-pressed.
    try testing.expectEqual(sdk.pane.ActionState.idle, a.actions.state(row_key, "review"));
    try a.dispatchReview();
    try testing.expectEqual(sdk.pane.ActionState.running, a.actions.state(row_key, "review"));
    try testing.expect(std.mem.startsWith(u8, a.actions.get(row_key, "review").prompt_line, "/agents:reviewer "));
    // The key is the PULL REQUEST's, not the ticket's: a ticket with
    // two pull requests must not wear one button's state on both.
    try testing.expectEqual(sdk.pane.ActionState.idle, a.actions.state(iss_key, "review"));
    // …and the host is asked to watch it, like every other button.
    var kbuf: [320]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), a.watch_out.items.len);
    try testing.expectEqualStrings(sdk.pane.actionWatchKey(&kbuf, row_key, "review"), a.watch_out.items[0].key);

    // A second press does not fork a second session: it asks for the
    // one that is running.
    try a.dispatchReview();
    try testing.expectEqual(@as(usize, 1), a.watch_out.items.len);
    try testing.expect(std.mem.indexOf(u8, a.status.items, "no mnml channel") != null or std.mem.indexOf(u8, a.status.items, "focus") != null);

    // The host's word moves it, and the button becomes the door.
    const watch_key = try ar.dupe(u8, a.watch_out.items[0].key);
    try a.onSessionState(watch_key, .done, "sid-9", "");
    try testing.expectEqual(sdk.pane.ActionState.view, a.actions.state(row_key, "review"));
}

test "a merge that ends offers the door back to the pull request it merged" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const t0 = a.tab();
    try t0.tree.?.setExpanded("ENG-2", true);
    try t0.tree.?.putPrs("ENG-2", &.{.{ .id = "#1", .status = "OPEN", .url = "https://bitbucket.org/acme/api/pull-requests/1" }});

    var kbuf: [256]u8 = undefined;
    const row_key = try std.fmt.bufPrint(&kbuf, "ENG-2\u{0}#1", .{});
    try a.actions.set(row_key, "merge", .{ .state = .running, .prompt_line = "merge #1" });
    var wbuf: [320]u8 = undefined;
    const watch_key = sdk.pane.actionWatchKey(&wbuf, row_key, "merge");

    // Not focused, so the end is worth telling the user about. A merge
    // that lands takes its pull request off the row it was under, so
    // the message about it is the LAST place it is named — the offer
    // is the door back to it (`wire.ToastAction`).
    a.focused = false;
    try a.onSessionState(watch_key, .done, "sid-9", "merged");
    try testing.expect(a.toast_pending);
    const act = a.toast_action orelse return error.NoToastAction;
    try testing.expectEqualStrings("Open PR", act.label);
    try testing.expectEqualStrings("https://bitbucket.org/acme/api/pull-requests/1", act.url);
    try testing.expectEqualStrings("", act.command);
    try testing.expect(act.isValid());

    // A plain `say` clears the offer: it belongs to the message it was
    // attached to, not to the pane.
    a.say("something else", .{});
    try testing.expect(a.toast_action == null);

    // And a failed fetch offers the way back rather than expecting the
    // reader to know that `r` is refresh.
    a.sayWithAction(App.retry_action, "error: {s}", .{"503"});
    const retry = a.toast_action orelse return error.NoToastAction;
    try testing.expectEqualStrings("Retry", retry.label);
    try testing.expectEqualStrings("integrations.retry_refresh", retry.command);
    try testing.expect(retry.isValid());
}

test "a refetch on the group keeps the old rows, the keys and the cursor, and lands on a later tick" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    // Put the cursor on a ticket, then refetch on a worker.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("j");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);

    var group: Io.Group = .init;
    a.setGroup(&group);
    defer {
        // The queue closes before the group is cancelled, the way the
        // pane's own shutdown does it.
        a.closeRefresh();
        group.cancel(testing.io);
        a.group = null;
    }
    try a.refreshActive();
    try testing.expect(a.refresh.busy());
    // The rows on screen are still the old ones, and the keys still work.
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    try testing.expect(a.tab().fetched);
    _ = try a.onKey("d");
    try testing.expect(a.details_visible);
    _ = try a.onKey("d");
    // A second refresh while one is in flight is refused rather than raced.
    try a.refreshActive();
    try testing.expect(a.refresh.busy());

    // It lands on a later tick, with the cursor back on its ticket.
    var spins: usize = 0;
    while (a.refresh.busy() and spins < 2000) : (spins += 1) {
        try a.drainRefresh();
        if (!a.refresh.busy()) break;
        testing.io.sleep(.fromMilliseconds(2), .awake) catch break;
    }
    try testing.expect(!a.refresh.busy());
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);
    // The PRs came with the search: the tree has them without another call.
    try testing.expect(a.tab().tree.?.prs("ENG-2") != null);
}

const reported_tabs = [_]config.Tab{.{ .name = "Reported by me", .kind = .work_reported }};

test "an End pressed before a ticket's linked PRs land is still on the last row once they have" {
    // The pane's order of events: the listing paints with a `loading…`
    // row under each open ticket, the PR fetches run on workers behind
    // the paint, and a key can arrive before any of them is drained.
    // Each result then takes its ticket's loading row away, and every
    // row below moves up one.
    const h = try Harness.start(.{ .tabs = &reported_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    var group: Io.Group = .init;
    a.setGroup(&group);
    defer {
        a.closeRefresh();
        group.cancel(testing.io);
        a.group = null;
    }
    try a.refreshActive();
    var spins: usize = 0;
    while (a.refresh.busy() and spins < 2000) : (spins += 1) {
        try a.drainRefresh();
        if (!a.refresh.busy()) break;
        testing.io.sleep(.fromMilliseconds(2), .awake) catch break;
    }
    try testing.expect(!a.refresh.busy());
    try a.pumpPrs();
    try testing.expect(a.prs.busy());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const before = (try a.treeRows(ar)).?;
    var loading: usize = 0;
    for (before.rows) |r| if (r == .pr_loading) {
        loading += 1;
    };
    try testing.expect(loading >= 2);
    try testing.expect(before.rows[before.rows.len - 1] == .show_older);

    _ = try a.onKey("end");
    try testing.expect((try a.focusedRow(ar)).? == .show_older);

    // Every fetch lands after the key, one at a time.
    spins = 0;
    while ((a.prs.busy() or a.pr_queue.items.len > 0) and spins < 5000) : (spins += 1) {
        try a.drainPrs();
        try a.pumpPrs();
        testing.io.sleep(.fromMilliseconds(1), .awake) catch break;
    }
    try testing.expect(!a.prs.busy() and a.pr_queue.items.len == 0);
    const after = (try a.treeRows(ar)).?;
    try testing.expect(after.rows.len < before.rows.len);
    const focused = try a.focusedRow(ar);
    try testing.expect(focused != null and focused.? == .show_older);
    try testing.expectEqual(after.rows.len - 1, a.tab().selected);
}

test "a refetch that fails keeps the rows it had, says `fetch failed`, and keeps `as of` on the last success" {
    // The rule the Bitbucket pane now follows too
    // (hunt/findings-2026-09-23/integ-bb-refresh-failure-wipes-rows.md):
    // one behaviour for one situation, in the toolkit's words.
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const n = a.tab().issues.len;
    try testing.expect(n > 0);
    const stamp = a.tab().fetched_at;
    h.store.fail_with = 500;
    defer h.store.fail_with = null;
    _ = try a.onKey("shift+r");
    try testing.expectEqual(n, a.tab().issues.len);
    try testing.expectEqual(stamp, a.tab().fetched_at);
    // The header's reason, which `screen.zig` hands `fetchText`.
    try testing.expect(a.tab().last_error.len > 0);
}

test "`d` and `t` fetch off the loop: the keys answer at once, the detail and the transitions land on a later tick" {
    // hunt/findings-2026-09-23/integ-jira-detail-blocks-pane.md: on a slow
    // site `d` froze the pane — no spinner, no `?` — until the answer.
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("j");
    const key = try arena.allocator().dupe(u8, (try a.focusedKey(arena.allocator())).?);

    var group: Io.Group = .init;
    a.setGroup(&group);
    defer {
        a.closeRefresh();
        group.cancel(testing.io);
        a.group = null;
    }
    // `d` returns before the site has answered: the panel is open, the
    // ticket's detail is on the wire (the spinner's cue), and `?` is
    // heard straight away.
    _ = try a.onKey("d");
    try testing.expect(a.details_visible);
    try testing.expect(a.detailOf(key) == null);
    try testing.expect(a.detailFetching(key));
    _ = try a.onKey("?");
    try testing.expect(a.help);
    _ = try a.onKey("esc");
    var spins: usize = 0;
    while (a.detailOf(key) == null and spins < 2000) : (spins += 1) {
        try a.drainLooks();
        testing.io.sleep(.fromMilliseconds(2), .awake) catch break;
    }
    try testing.expect(a.detailOf(key) != null);
    try testing.expect(!a.detailFetching(key));

    // `t`: the picker is up at once with `loading…`, its list lands later.
    _ = try a.onKey("t");
    try testing.expect(a.transition != null);
    try testing.expect(a.transition.?.transitions == null);
    spins = 0;
    while (a.transition.?.transitions == null and spins < 2000) : (spins += 1) {
        try a.drainLooks();
        testing.io.sleep(.fromMilliseconds(2), .awake) catch break;
    }
    try testing.expect(a.transition.?.transitions.?.len > 0);
    a.closeTransition();

    // Typed ahead of the list — `t 1 ⏎` — it still moves the ticket
    // once the list lands.
    const moves_before = h.store.requests;
    _ = try a.onKey("t");
    _ = try a.onKey("1");
    _ = try a.onKey("enter");
    try testing.expect(a.transition != null);
    spins = 0;
    while (a.transition != null and spins < 2000) : (spins += 1) {
        try a.drainLooks();
        testing.io.sleep(.fromMilliseconds(2), .awake) catch break;
    }
    try testing.expect(a.transition == null);
    try testing.expect(h.store.requests - moves_before >= 2);
}

test "a client that hangs up mid-request does not stop the fake: the next request is still answered" {
    // What a test's teardown does to a pane worker still on the wire:
    // `group.cancel` lands between its connect and its answer, and the
    // socket closes with the request unsent or half sent. The Loopback
    // ended its whole accept loop on that, the test's next request sat
    // unaccepted in the backlog, and a ReleaseSafe suite hung for 53
    // minutes. With the old loop this is the Harness watchdog's panic
    // (the accept loop ended with the test still running), not a hang.
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const io = testing.io;
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(h.server.socket.address.getPort()) };
    // Nothing sent at all.
    (try addr.connect(io, .{ .mode = .stream })).close(io);
    // Half a request line.
    {
        const s = try addr.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [64]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.writeAll("GET /rest/api/3/my");
        try w.interface.flush();
    }
    try h.app.ensureLoaded();
    try testing.expect(h.app.tab().issues.len > 0);
    try testing.expectEqual(@as(u32, 2), h.lb.dropped.load(.monotonic));
}

test "a look cancelled at every point of its request, 400 times over, leaves the fake answering" {
    // The teardown shape that hung the suite, made to happen on purpose:
    // each round starts a detail look and cancels it a few microseconds
    // later than the last, so across the rounds the cancel lands before
    // the connect, in it, mid-request and mid-answer. Some of those
    // leave the fake a connection that hangs up (`lb.dropped`); every
    // one of them must leave it taking the next.
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    a.looks.deinit(a.io, LookResult.drop);
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        a.looks = try LookSlot.init(a.gpa);
        var group: Io.Group = .init;
        a.setGroup(&group);
        a.detail_fetching_len = 0;
        try a.startLook(.detail, "ENG-2");
        testing.io.sleep(.fromMicroseconds(@intCast(i * 5)), .awake) catch {};
        a.closeRefresh();
        group.cancel(testing.io);
        a.looks.deinit(a.io, LookResult.drop);
        a.group = null;
    }
    a.looks = try LookSlot.init(a.gpa);
    // Inline now (no group): the test thread's own request, answered.
    try a.refreshActive();
    try testing.expect(a.tab().issues.len > 0);
}

test "the Work family's three kinds: open work counts for the chip, reported is the reporter query, the editable tab interpolates its vars" {
    const h = try Harness.start(.{ .tabs = &editable_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    // `work_open` is the same query as `work_assigned` under the name it
    // reads as, and it is what the statusline chip counts.
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    try testing.expectEqual(@as(?usize, 3), a.assigned_open);
    try testing.expect(std.mem.indexOf(u8, a.tab().jql, "assignee = currentUser()") != null);
    try testing.expectEqual(@as(usize, 3), a.tabs.len);
    // The file indices survive `--only`: all three are work tabs here.
    try testing.expectEqual(@as(usize, 2), a.tabs[2].file_idx);

    try a.switchTab(1);
    try testing.expect(std.mem.indexOf(u8, a.tab().jql, "reporter = currentUser()") != null);

    // The editable tab's JQL is the user's, with the holes filled.
    try a.switchTab(2);
    try testing.expectEqualStrings(
        "project = ENG AND fixVersion in (\"2.4.0\", \"2.3.0\") ORDER BY updated DESC",
        a.tab().jql,
    );
}

test "J on an editable tab edits the vars, saves them into the config file's own spans, and the JQL follows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const cfg_path = try std.fs.path.join(testing.allocator, &.{ root, "config.zon" });
    defer testing.allocator.free(cfg_path);
    // A hand-written file, comments and all — what a save must not eat.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.zon", .data =
        \\// my jira config — keep my comments
        \\.{
        \\    .jira_url = "https://x",
        \\    .email = "me@acme.com",
        \\    .tabs = .{
        \\        .{ .name = "My open work items", .kind = .work_open },
        \\        .{ .name = "Reported by me", .kind = .work_reported },
        \\        .{
        \\            // the one that changes every release
        \\            .name = "QA Actionable now",
        \\            .kind = .jql_editable,
        \\            .jql = "project = {project} AND fixVersion in ({versions}) ORDER BY updated DESC",
        \\            .vars = .{
        \\                .{ .name = "project", .value = "ENG" },
        \\                .{ .name = "versions", .values = .{ "2.4.0", "2.3.0" } },
        \\            },
        \\        },
        \\    },
        \\}
        \\
    });

    const h = try Harness.start(.{ .tabs = &editable_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    a.setConfigPath(cfg_path);
    try a.ensureLoaded();
    try a.switchTab(2);

    // J opens the editor on the vars, not on the JQL.
    _ = try a.onKey("shift+j");
    try testing.expect(a.vars != null);
    try testing.expect(a.jql == null);
    const e = &(a.vars.?);
    // project, ENG, versions, 2.4.0, 2.3.0, + add
    try testing.expectEqual(@as(usize, 6), e.rows.items.len);

    // Add a version: `a` lands on the add line and types into it.
    e.cursor = 3;
    _ = try a.onKey("a");
    try testing.expect(a.vars.?.edit != null);
    for ("3.0.0") |c| _ = try a.onKey(if (c == '.') "." else &[_]u8{c});
    _ = try a.onKey("enter");
    try testing.expectEqual(@as(usize, 3), a.vars.?.boxes.items[1].values.items.len);

    // Remove the first one.
    a.vars.?.cursor = 3;
    _ = try a.onKey("d");
    try testing.expectEqual(@as(usize, 2), a.vars.?.boxes.items[1].values.items.len);

    // s (and Ctrl+S) writes it back and closes.
    _ = try a.onKey("s");
    try testing.expect(a.vars == null);
    const after = try tmp.dir.readFileAlloc(testing.io, "config.zon", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, ".values = .{ \"2.3.0\", \"3.0.0\" }") != null);
    try testing.expect(std.mem.indexOf(u8, after, "2.4.0") == null);
    // Both comments survived, and so did everything the edit did not name.
    try testing.expect(std.mem.indexOf(u8, after, "// my jira config — keep my comments") != null);
    try testing.expect(std.mem.indexOf(u8, after, "// the one that changes every release") != null);
    try testing.expect(std.mem.indexOf(u8, after, ".value = \"ENG\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "{project}") != null);

    // And the live tab is already running the new query.
    try testing.expectEqualStrings(
        "project = ENG AND fixVersion in (\"2.3.0\", \"3.0.0\") ORDER BY updated DESC",
        a.tab().jql,
    );
    try testing.expect(std.mem.indexOf(u8, a.status.items, "var(s) saved") != null);
    // The save refetched the tab it edited — the count is the new
    // query's, not the old one's. (This is what reading the editor
    // after closing it used to skip.)
    try testing.expect(a.tab().fetched);

    // Esc on a tab without vars says so rather than opening an empty box.
    try a.switchTab(0);
    _ = try a.onKey("shift+j");
    try testing.expect(a.vars == null);
    try testing.expect(a.jql != null);
    _ = try a.onKey("esc");
}

test "Fix Versions: the release resolves to 2.4.0, status_order and bumps group the tree, f switches the release, F assigns" {
    const h = try Harness.start(.{ .tabs = &fixv_tabs }, .fix_versions);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqualStrings("project = ENG AND fixVersion = \"2.4.0\" ORDER BY rank", a.tab().jql);
    try testing.expectEqual(@as(usize, 8), a.tab().issues.len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqualStrings("Testing", r.rows[0].group.status);
    // ENG-6 (Testing) and ENG-2 (bumped from In PR Review) share the
    // group — the tree is not narrowed to "me" the way a flat tab is.
    try testing.expectEqual(@as(usize, 2), r.rows[0].group.count);
    try testing.expect(r.rows[1].ticket.bumped);
    try testing.expectEqual(@as(usize, 0), a.tab().active_assignees.count());
    _ = try a.onKey("f");
    try testing.expectEqual(pickers.Kind.tab_fix_version, a.picker.?.kind);
    a.picker.?.selectId("2.3.0");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("project = ENG AND fixVersion = \"2.3.0\" ORDER BY rank", a.tab().jql);
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    _ = try a.onKey("j");
    _ = try a.onKey("shift+f");
    try testing.expectEqual(pickers.Kind.fix_version, a.picker.?.kind);
    _ = try a.onKey("esc");
    // Dispatch on a fresh workspace: nothing to write into, and it says so.
    _ = try a.onKey("shift+i");
    try testing.expect(std.mem.indexOf(u8, a.status.items, "nothing to dispatch to") != null);
    // The release-cut flag bumps Done to the top.
    a.cfg.release_cut = true;
    a.picker = null;
    a.tab().jql = "project = ENG AND fixVersion = \"2.4.0\" ORDER BY rank";
    try a.refreshActive();
    const cut = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqualStrings(tree.top_sentinel, cut.rows[0].group.status);
}

test "Boards: the sprint loads from the board, the cursor is a card, the pickers open, and the backlog is the second tab" {
    const h = try Harness.start(.{ .tabs = &board_tabs, .team_field_id = "customfield_10056" }, .boards);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 9), a.tab().issues.len);
    // The reference seeds the assignee filter with me.
    try testing.expect(a.tab().active_assignees.contains(jira.fake.account_me));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 3), (try a.visibleIssues(arena.allocator())).len);
    try a.toggleAssignee(jira.fake.account_me);
    try testing.expectEqual(@as(usize, 9), (try a.visibleIssues(arena.allocator())).len);
    try testing.expectEqualStrings("Checkout board", try a.boardName(7));
    try testing.expect(a.tab().sprints != null);
    try testing.expectEqual(@as(usize, 5), a.tab().assignees.len);
    _ = try a.onKey("shift+.");
    try testing.expect(a.isCardExpanded("ENG-1"));
    try a.openSprint();
    try testing.expectEqual(pickers.Kind.sprint, a.picker.?.kind);
    try testing.expectEqualStrings("Sprint 4  [active]", a.picker.?.items[1].label);
    _ = try a.onKey("esc");
    try a.openEpic();
    try testing.expectEqual(pickers.Kind.epic, a.picker.?.kind);
    try testing.expectEqualStrings("ENG-1", a.picker.?.items[0].id);
    _ = try a.onKey("esc");
    try a.openQuickFilters();
    try testing.expectEqual(pickers.Kind.quick_filter, a.picker.?.kind);
    _ = try a.onKey("space");
    _ = try a.onKey("enter");
    try testing.expectEqual(@as(usize, 1), a.tab().active_quick_filters.items.len);
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    try a.openBoard();
    try testing.expectEqualStrings("Checkout board  [scrum]", a.picker.?.items[1].label);
    _ = try a.onKey("esc");
    _ = try a.onKey("shift+t");
    try testing.expectEqual(pickers.Kind.team, a.picker.?.kind);
    _ = try a.onKey("esc");
    _ = try a.onKey("shift+d");
    try testing.expect(a.modal != null and a.modal.?.data != null);
    _ = try a.onKey("esc");
    _ = try a.onKey("2");
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-10", a.tab().issues[0].key);
}

test "the dispatch queue writes the reference's line into the configured workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, ".claude");
    const h = try Harness.start(.{ .tabs = &fixv_tabs, .dispatch_workspace = root }, .fix_versions);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Row 1 is ENG-2 (bumped into Testing, still In PR Review): Review.
    _ = try a.onKey("j");
    _ = try a.onKey(".");
    try testing.expectEqual(pickers.Kind.action, a.picker.?.kind);
    try testing.expectEqualStrings("[ Review ]", a.picker.?.items[0].label);
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("review → queue", a.status.items);
    // Row 2 is ENG-6 (Testing, a Task): Test.
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    try testing.expectEqualStrings("ENG-6", (try a.focusedKey(arena.allocator())).?);
    _ = try a.onKey(".");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("test → queue", a.status.items);
    const q = try tmp.dir.readFileAlloc(testing.io, ".claude/queue.jsonl", arena.allocator(), .unlimited);
    try testing.expect(std.mem.indexOf(u8, q, "\"kind\":\"review\",\"issue_key\":\"ENG-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, q, "\"kind\":\"test\",\"issue_key\":\"ENG-6\"") != null);
}

test "a ticket that has not moved costs no dev-status call, this run or the next" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const cache_path = try std.fs.path.join(testing.allocator, &.{ dir, "dev-status.json" });
    defer testing.allocator.free(cache_path);

    // The first run: the search, then one dev-status per unresolved
    // ticket — behind the paint rather than in front of it, which is
    // what `pr_queue` is, and cached under each ticket's `updated`.
    {
        const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
        defer h.stop();
        var cache = try sdk.Store.openAt(testing.allocator, testing.io, cache_path);
        defer cache.deinit();
        h.app.setPrStore(&cache);
        const before = h.store.requests;
        try h.app.ensureLoaded();
        const spent = h.store.requests - before;
        // /myself, the search, and one dev-status for each of the three
        // unresolved tickets.
        try testing.expectEqual(@as(usize, 5), spent);
        try testing.expectEqual(@as(usize, 0), h.app.pr_queue.items.len);
        // The rows are on screen, off the wire.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = (try h.app.treeRows(arena.allocator())).?;
        try testing.expect(r.rows[2] == .pr and r.rows[3] == .pr);
        // And three tickets are now remembered, each under the stamp
        // the search already carried.
        try testing.expectEqual(@as(usize, 3), cache.entries.items.len);
        try testing.expect(cache.get("ENG-2").?.stamp.len > 0);
    }

    // The next run, against the same unchanged Jira: the search still
    // costs one request, and the linked PRs cost NONE — which is the
    // difference between a Work tab that opens and one that spends a
    // minute of the machine's budget doing it again.
    {
        const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
        defer h.stop();
        var cache = try sdk.Store.openAt(testing.allocator, testing.io, cache_path);
        defer cache.deinit();
        try testing.expectEqual(@as(usize, 3), cache.entries.items.len);
        h.app.setPrStore(&cache);
        h.app.budget.configure(testing.io, .{ .label = "Jira", .service = "jira" });
        h.client.budget = &h.app.budget;
        const before = h.store.requests;
        try h.app.ensureLoaded();
        // /myself and the search. Nothing else.
        try testing.expectEqual(@as(usize, 2), h.store.requests - before);
        try testing.expectEqual(@as(usize, 0), h.app.pr_queue.items.len);
        try testing.expectEqual(@as(u32, 3), cache.hits);
        // And the budget's ratio says so: three reads the store answered,
        // two that carried a body (/myself and the search).
        const snap = h.app.budget.snapshot(h.app.nowSecs());
        try testing.expectEqual(@as(u32, 3), snap.hits);
        try testing.expectEqual(@as(u32, 2), snap.misses);
        // The rows are the same rows, painted off the cache.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = (try h.app.treeRows(arena.allocator())).?;
        try testing.expect(r.rows[2] == .pr and r.rows[3] == .pr);
        // A refetch with nothing changed costs the search and no more.
        const mid = h.store.requests;
        _ = try h.app.onKey("r");
        try testing.expectEqual(@as(usize, 1), h.store.requests - mid);
    }

    // A ticket the site has since moved is asked about again: the
    // cache is keyed on the SERVER's stamp, not on our own clock.
    {
        const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
        defer h.stop();
        var cache = try sdk.Store.openAt(testing.allocator, testing.io, cache_path);
        defer cache.deinit();
        h.app.setPrStore(&cache);
        h.store.find("ENG-2").?.updated = "2026-09-20T10:00:00.000+0000";
        const before = h.store.requests;
        try h.app.ensureLoaded();
        // /myself, the search, and ENG-2's dev-status — only ENG-2's.
        try testing.expectEqual(@as(usize, 3), h.store.requests - before);
    }
}

test "`r` asks only about what has moved since the last whole listing — and which rows LEFT the query; `R` asks for the listing again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const sync_path = try std.fs.path.join(testing.allocator, &.{ dir, "sync.json" });
    defer testing.allocator.free(sync_path);

    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    var sync = try sdk.Store.openAt(testing.allocator, testing.io, sync_path);
    defer sync.deinit();
    a.setSyncStore(&sync);

    // The first load is the whole listing — there is no window to ask
    // for yet — and it dates the tab.
    try a.ensureLoaded();
    const all = a.tab().issues.len;
    try testing.expect(all > 0);
    try testing.expect(a.tab().fetched_at > 0);
    try testing.expectEqual(@as(usize, 0), a.tab().deltas.items.len);

    // Nothing has moved. `r` is a window — two searches: what moved in
    // the query, and which rows on screen moved out of it — both come
    // back empty, and the rows on screen are the rows that were on
    // screen.
    var before = h.store.requests;
    _ = try a.onKey("r");
    try testing.expectEqual(@as(usize, 2), h.store.requests - before);
    try testing.expectEqual(all, a.tab().issues.len);
    try testing.expectEqual(@as(usize, 1), a.tab().deltas.items.len);

    // Move two tickets behind the pane's back, the way a colleague
    // would. The window now names exactly those two, and they are
    // merged into the rows rather than replacing them.
    h.store.issues.items[0].moved = true;
    h.store.issues.items[0].status = "Done";
    h.store.issues.items[1].moved = true;
    before = h.store.requests;
    _ = try a.onKey("r");
    try testing.expectEqual(@as(usize, 2), h.store.requests - before);
    try testing.expectEqual(all, a.tab().issues.len);
    try testing.expectEqual(@as(usize, 2), a.tab().deltas.items.len);
    var done: usize = 0;
    for (a.tab().issues) |iss| {
        if (std.mem.eql(u8, iss.key, h.store.issues.items[0].key)) {
            try testing.expectEqualStrings("Done", iss.status);
            done += 1;
        }
    }
    // Merged in place: one row, not a duplicate beside the old one.
    try testing.expectEqual(@as(usize, 1), done);

    // A teammate closes a ticket on this tab
    // (hunt/findings-2026-09-23/integ-jira-r-keeps-closed-ticket.md): it
    // no longer matches the query, so the window onto the query cannot
    // see it — the second search can, and `r` drops it.
    const gone = a.tab().issues[0].key;
    const fake_issue = h.store.find(gone).?;
    fake_issue.status = "Done";
    fake_issue.category = "done";
    fake_issue.moved = true;
    _ = try a.onKey("r");
    try testing.expectEqual(all - 1, a.tab().issues.len);
    for (a.tab().issues) |iss| try testing.expect(!std.mem.eql(u8, iss.key, fake_issue.key));

    // A ticket on screen is deleted: Jira refuses a `key in` naming it,
    // so the window cannot be trusted and `r` asks for the whole
    // listing instead — which does not have it either.
    const deleted = a.tab().issues[0].key;
    for (h.store.issues.items, 0..) |iss, i| if (std.mem.eql(u8, iss.key, deleted)) {
        var dead = h.store.issues.orderedRemove(i);
        dead.comments.deinit(h.store.gpa);
        dead.watchers.deinit(h.store.gpa);
        break;
    };
    _ = try a.onKey("r");
    try testing.expectEqual(all - 2, a.tab().issues.len);
    try testing.expectEqual(@as(usize, 0), a.tab().deltas.items.len);

    // `R` throws the generations away and asks for the listing again.
    before = h.store.requests;
    _ = try a.onKey("shift+r");
    try testing.expectEqual(@as(usize, 1), h.store.requests - before);
    try testing.expectEqual(@as(usize, 0), a.tab().deltas.items.len);
}

test "a delta window survives a restart, and the chain of them is bounded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const sync_path = try std.fs.path.join(testing.allocator, &.{ dir, "sync.json" });
    defer testing.allocator.free(sync_path);

    {
        const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
        defer h.stop();
        var sync = try sdk.Store.openAt(testing.allocator, testing.io, sync_path);
        defer sync.deinit();
        h.app.setSyncStore(&sync);
        try h.app.ensureLoaded();
        // A whole listing dates the tab on disk, not only in memory.
        try testing.expect(sync.stale("Assigned").?.fetched_at > 0);
    }
    {
        // A second run reads that mark back, so its FIRST refetch is a
        // window rather than the whole listing again.
        const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
        defer h.stop();
        var sync = try sdk.Store.openAt(testing.allocator, testing.io, sync_path);
        defer sync.deinit();
        h.app.setSyncStore(&sync);
        try h.app.ensureLoaded();
        const all = h.app.tab().issues.len;
        // A chain of windows is bounded: past `max_delta_generations`
        // the next one is full whatever was asked for, so a tab that is
        // only ever delta-refreshed does not grow without end — and
        // something eventually notices a ticket that dropped OUT.
        var i: usize = 0;
        while (i < max_delta_generations + 2) : (i += 1) _ = try h.app.onKey("r");
        try testing.expect(h.app.tab().deltas.items.len <= max_delta_generations);
        try testing.expectEqual(all, h.app.tab().issues.len);
    }
}

test "Shift+N turns dry run on and a refresh then sends nothing; Ctrl+X stops a rate-limit pause" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    h.app.budget.configure(testing.io, .{ .label = "Jira", .service = "jira" });
    h.client.budget = &h.app.budget;
    try h.app.ensureLoaded();
    _ = try h.app.onKey("shift+n");
    try testing.expect(h.app.budget.isDry());
    try testing.expect(std.mem.indexOf(u8, h.app.status.items, "dry run on") != null);
    const before = h.store.requests;
    const shown = h.app.tab().issues.len;
    try testing.expect(shown > 0);
    _ = try h.app.onKey("r");
    try h.app.ensureLoaded();
    try testing.expectEqual(before, h.store.requests);
    // Nothing failed: the rows stay, no error is kept for the header,
    // and the message line says nothing was sent.
    try testing.expectEqual(shown, h.app.tab().issues.len);
    try testing.expectEqualStrings("", h.app.tab().last_error);
    try testing.expect(std.mem.indexOf(u8, h.app.status.items, "nothing sent") != null);
    try testing.expect(std.mem.indexOf(u8, h.app.status.items, "error") == null);
    _ = try h.app.onKey("shift+n");
    try testing.expect(!h.app.budget.isDry());

    _ = h.app.budget.throttled(1, 60);
    try testing.expect(h.app.budget.snapshot(h.app.nowSecs()).paused_until > 0);
    _ = try h.app.onKey("ctrl+x");
    try testing.expectEqual(@as(i64, 0), h.app.budget.snapshot(h.app.nowSecs()).paused_until);
    try testing.expect(std.mem.indexOf(u8, h.app.status.items, "stopped waiting") != null);
}

test "a listing's digest moves with a ticket's status, stamp, summary or membership, and nothing else" {
    const one = [_]Issue{ .{ .key = "ENG-1", .updated = "u1", .status = "To Do", .summary = "a" }, .{ .key = "ENG-2", .updated = "u2", .status = "Done", .summary = "b" } };
    const same = one;
    var moved = one;
    moved[0].status = "In Progress";
    var restamped = one;
    restamped[1].updated = "u3";
    try testing.expectEqual(App.issuesDigest(&one), App.issuesDigest(&same));
    try testing.expect(App.issuesDigest(&one) != App.issuesDigest(&moved));
    try testing.expect(App.issuesDigest(&one) != App.issuesDigest(&restamped));
    try testing.expect(App.issuesDigest(&one) != App.issuesDigest(one[0..1]));
}
