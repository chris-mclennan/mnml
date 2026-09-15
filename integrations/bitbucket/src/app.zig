//! The pane's state machine: tabs, selection, filter, detail, the
//! confirms in front of every write, and the prompt a comment is typed
//! into. Everything a key does ends here.
//!
//! The one structural decision worth stating: **the app never performs
//! a side effect itself.** A key that should toast, run an mnml
//! command, open a browser or put something on the clipboard appends an
//! `Effect`; `main.zig` drains the queue after each key and carries it
//! out over the mount. That is what lets the whole keymap — including
//! approve, merge and checkout — be driven in a unit test with no
//! socket, no browser and no clipboard, while the same code path runs
//! for real in the pane.
//!
//! Fetches, by contrast, are synchronous and on the loop. A pane that
//! is waiting for Bitbucket says so on its own footer and on mnml's
//! statusline (a Tier-2 progress effect), and a fan-out over ten repos
//! takes as long as it takes. The alternative — a worker thread — buys
//! nothing while `mount.next` is the thing that blocks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cfg = @import("config.zig");
const api = @import("api.zig");
const model = @import("model.zig");
const view = @import("view.zig");
const links = @import("links.zig");
const gitmod = @import("git.zig");
const j = @import("json.zig");

pub const Effect = union(enum) {
    toast: struct { level: Level, text: []const u8 },
    /// Ask mnml to run a command by id.
    command: []const u8,
    open_url: []const u8,
    copy: []const u8,
    progress_start: struct { id: []const u8, label: []const u8 },
    progress_update: struct { id: []const u8, label: []const u8, percent: u8 },
    progress_end: struct { id: []const u8, ok: bool },
    /// The pane is done; the loop says bye.
    quit,

    pub const Level = enum { info, warn, err };
};

pub const Mode = enum { list, filter, confirm, prompt, help };

/// What a confirm, once accepted, will do.
pub const Pending = enum {
    approve,
    withdraw_approval,
    request_changes,
    withdraw_changes,
    merge,
    checkout,
};

pub const PromptKind = enum { comment };

/// One tab's fetched state. Each owns an arena: a refresh frees the
/// last result wholesale rather than untangling who owns which string.
pub const TabState = struct {
    tab: cfg.Tab,
    arena: std.heap.ArenaAllocator,
    rows: []const view.Row = &.{},
    /// Indices into `rows` that pass the filter.
    visible: []const usize = &.{},
    selected: usize = 0,
    scroll: usize = 0,
    /// Set when the whole tab failed; per-repo failures go in `notes`.
    error_text: []const u8 = "",
    /// "workspace" / "repo" when `mode` could not run and `fallback` did.
    fallback_note: []const u8 = "",
    /// One line per repo that failed, kept so a 403 on one archived
    /// repo is visible rather than silently missing rows.
    notes: []const []const u8 = &.{},
    fetched: bool = false,
    last_fetch_ms: i64 = 0,

    pub fn deinit(self: *TabState) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn focused(self: *const TabState) ?model.Pr {
        if (self.visible.len == 0) return null;
        const i = @min(self.selected, self.visible.len - 1);
        return self.rows[self.visible[i]].pr;
    }
};

/// The focused PR's detail, fetched lazily and kept until the focus
/// moves.
pub const Detail = struct {
    arena: std.heap.ArenaAllocator,
    key: Key,
    pr: model.Pr,
    reviewers: []const model.Participant = &.{},
    builds: []const model.BuildStatus = &.{},
    files: []const model.DiffstatEntry = &.{},
    diff: []const u8 = "",
    activity: []const model.Activity = &.{},
    jira_keys: []const links.Key = &.{},
    scroll: usize = 0,
    loading: bool = false,
    error_text: []const u8 = "",

    pub const Key = struct {
        workspace: []const u8,
        repo: []const u8,
        id: i64,

        pub fn eql(a: Key, b: Key) bool {
            return a.id == b.id and std.mem.eql(u8, a.repo, b.repo) and std.mem.eql(u8, a.workspace, b.workspace);
        }
    };

    pub fn deinit(self: *Detail) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    config: cfg.Config,
    client: *api.Client,
    tabs: []TabState,
    active: usize = 0,
    mode: Mode = .list,
    /// The pane's geometry, from the mount's hello / resize.
    cols: u16 = 80,
    rows: u16 = 24,

    /// `/2.0/user`, once. "" until then.
    me_account_id: []const u8 = "",
    me_display_name: []const u8 = "",
    whoami_tried: bool = false,
    whoami_error: []const u8 = "",

    show_detail: bool = false,
    show_diff: bool = true,
    detail: ?Detail = null,

    filter_buf: std.ArrayList(u8) = .empty,
    prompt_buf: std.ArrayList(u8) = .empty,
    prompt_cursor: usize = 0,
    prompt_kind: PromptKind = .comment,
    pending: ?Pending = null,
    pending_detail: []const u8 = "",

    merge_strategy: api.Client.MergeStrategy = .squash,
    close_source_branch: bool = true,

    /// Which Jira key `i` opens next.
    issue_cursor: usize = 0,

    /// mnml's workspace directory — where a checkout would happen.
    workspace_dir: []const u8 = ".",
    jira_installed: bool = false,
    github_installed: bool = false,

    status: []const u8 = "",
    effects: std.ArrayList(Effect) = .empty,
    /// Owns every string the effects point at; reset when the queue is
    /// drained.
    fx_arena: std.heap.ArenaAllocator,
    /// Owns the footer line. Separate from `fx_arena` on purpose: the
    /// loop drains the effects *before* it paints, so a status kept on
    /// the effect arena would be freed a moment before the frame that
    /// was supposed to show it.
    status_arena: std.heap.ArenaAllocator,
    /// Owns `me_*` and `whoami_error`.
    ident_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: Io, config: cfg.Config, client: *api.Client) Allocator.Error!App {
        const tabs = try gpa.alloc(TabState, config.tabs.len);
        for (config.tabs, tabs) |tab, *slot| slot.* = .{ .tab = tab, .arena = std.heap.ArenaAllocator.init(gpa) };
        return .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .client = client,
            .tabs = tabs,
            .fx_arena = std.heap.ArenaAllocator.init(gpa),
            .status_arena = std.heap.ArenaAllocator.init(gpa),
            .ident_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.tabs) |*tab| tab.deinit();
        self.gpa.free(self.tabs);
        if (self.detail) |*d| d.deinit();
        self.filter_buf.deinit(self.gpa);
        self.prompt_buf.deinit(self.gpa);
        self.effects.deinit(self.gpa);
        self.fx_arena.deinit();
        self.status_arena.deinit();
        self.ident_arena.deinit();
        self.* = undefined;
    }

    pub fn activeTab(self: *App) *TabState {
        return &self.tabs[@min(self.active, self.tabs.len - 1)];
    }

    // ─── effects ─────────────────────────────────────────────────────

    fn push(self: *App, e: Effect) void {
        self.effects.append(self.gpa, e) catch {};
    }

    pub fn toast(self: *App, level: Effect.Level, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.fx_arena.allocator(), fmt, args) catch return;
        self.push(.{ .toast = .{ .level = level, .text = text } });
        self.say(fmt, args);
    }

    /// The footer line. One at a time, so the arena is reset each time
    /// rather than grown.
    pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        _ = self.status_arena.reset(.retain_capacity);
        self.status = std.fmt.allocPrint(self.status_arena.allocator(), fmt, args) catch "";
    }

    /// Hand the queue to the caller; it is empty afterwards. The
    /// strings stay valid until the next `resetEffects`.
    pub fn takeEffects(self: *App) []const Effect {
        return self.effects.toOwnedSlice(self.gpa) catch &.{};
    }

    /// Free what the last drain handed out. Called once the caller is
    /// done with the slice.
    pub fn resetEffects(self: *App, taken: []const Effect) void {
        self.gpa.free(taken);
        _ = self.fx_arena.reset(.retain_capacity);
    }

    // ─── keys ────────────────────────────────────────────────────────

    /// One key spec, in mnml's grammar. Returns true when the pane
    /// should keep running.
    pub fn key(self: *App, raw: []const u8) Allocator.Error!bool {
        var buf: [8]u8 = undefined;
        const spec = normalizeSpec(raw, &buf);
        // A mount has no timer: the host only wakes a sibling on input.
        // So `refresh_interval_secs` is checked here, on the way into a
        // list key — a pane left open over lunch re-fetches on the
        // first key rather than showing an hour-old queue. Only in
        // `.list`: a refresh underneath a confirm would move the row it
        // is about.
        if (self.mode == .list) try self.refreshIfStale();
        switch (self.mode) {
            .filter => return self.filterKey(spec),
            .prompt => return self.promptKey(spec),
            .confirm => return self.confirmKey(spec),
            .help => {
                self.mode = .list;
                return true;
            },
            .list => return self.listKey(spec),
        }
    }

    /// Re-fetch the active tab when `refresh_interval_secs` has passed
    /// since it last did. 0 disables it; `r` always works.
    pub fn refreshIfStale(self: *App) Allocator.Error!void {
        const secs = self.config.refresh_interval_secs;
        if (secs == 0) return;
        const tab = self.activeTab();
        if (!tab.fetched) return;
        const age = nowMs(self.io) - tab.last_fetch_ms;
        if (age < @as(i64, secs) * 1000) return;
        try self.refreshActive();
    }

    fn listKey(self: *App, spec: []const u8) Allocator.Error!bool {
        const tab = self.activeTab();
        if (eq(spec, "q")) {
            self.push(.quit);
            return false;
        }
        if (eq(spec, "?")) {
            self.mode = .help;
            return true;
        }
        if (spec.len == 1 and spec[0] >= '1' and spec[0] <= '9') {
            const want = @as(usize, spec[0] - '1');
            if (want < self.tabs.len) try self.switchTab(want);
            return true;
        }
        if (eq(spec, "tab")) {
            try self.switchTab((self.active + 1) % self.tabs.len);
            return true;
        }
        if (eq(spec, "backtab")) {
            try self.switchTab(if (self.active == 0) self.tabs.len - 1 else self.active - 1);
            return true;
        }
        if (eq(spec, "j") or eq(spec, "down")) return self.move(1);
        if (eq(spec, "k") or eq(spec, "up")) return self.move(-1);
        // With the detail open these scroll it; otherwise they page the
        // list. j / k always move the selection, detail or not — losing
        // the ability to walk the list is not worth a second scroll key.
        if (eq(spec, "ctrl+d") or eq(spec, "pagedown")) return self.page(1);
        if (eq(spec, "ctrl+u") or eq(spec, "pageup")) return self.page(-1);
        if (eq(spec, "g") or eq(spec, "home")) return self.moveTo(0);
        if (eq(spec, "G") or eq(spec, "end")) return self.moveTo(if (tab.visible.len == 0) 0 else tab.visible.len - 1);
        if (eq(spec, "/")) {
            self.mode = .filter;
            return true;
        }
        if (eq(spec, "esc")) {
            if (self.filter_buf.items.len > 0) {
                self.filter_buf.clearRetainingCapacity();
                self.applyFilter(tab);
                self.say("filter cleared", .{});
            } else if (self.show_detail) {
                self.show_detail = false;
            }
            return true;
        }
        if (eq(spec, "r")) {
            try self.refreshActive();
            return true;
        }
        if (eq(spec, "d")) {
            self.show_detail = !self.show_detail;
            if (self.show_detail) try self.ensureDetail();
            return true;
        }
        if (eq(spec, "D")) {
            self.show_diff = !self.show_diff;
            return true;
        }
        if (eq(spec, "enter") or eq(spec, "o")) return self.openInBrowser();
        if (eq(spec, "y")) return self.copyUrl();
        if (eq(spec, "Y")) return self.copyBranch();
        if (eq(spec, "i")) return self.openIssue();
        if (eq(spec, "a")) return self.beginVote(.approve);
        if (eq(spec, "A")) return self.beginVote(.withdraw_approval);
        if (eq(spec, "x")) return self.beginVote(.request_changes);
        if (eq(spec, "X")) return self.beginVote(.withdraw_changes);
        if (eq(spec, "m")) return self.beginMerge();
        if (eq(spec, "s")) {
            self.merge_strategy = switch (self.merge_strategy) {
                .squash => .merge_commit,
                .merge_commit => .fast_forward,
                .fast_forward => .squash,
            };
            self.say("merge strategy: {s}", .{self.merge_strategy.label()});
            return true;
        }
        if (eq(spec, "C")) return self.beginCheckout();
        if (eq(spec, "c")) return self.beginComment();
        return true;
    }

    fn filterKey(self: *App, spec: []const u8) Allocator.Error!bool {
        const tab = self.activeTab();
        if (eq(spec, "esc")) {
            self.filter_buf.clearRetainingCapacity();
            self.mode = .list;
            self.applyFilter(tab);
            return true;
        }
        if (eq(spec, "enter")) {
            self.mode = .list;
            return true;
        }
        if (eq(spec, "backspace")) {
            if (self.filter_buf.items.len > 0) _ = self.filter_buf.pop();
            self.applyFilter(tab);
            return true;
        }
        if (eq(spec, "ctrl+u")) {
            self.filter_buf.clearRetainingCapacity();
            self.applyFilter(tab);
            return true;
        }
        if (eq(spec, "space")) {
            try self.filter_buf.append(self.gpa, ' ');
            self.applyFilter(tab);
            return true;
        }
        if (isText(spec)) {
            try self.filter_buf.appendSlice(self.gpa, spec);
            self.applyFilter(tab);
        }
        return true;
    }

    fn promptKey(self: *App, spec: []const u8) Allocator.Error!bool {
        if (eq(spec, "esc")) {
            self.prompt_buf.clearRetainingCapacity();
            self.prompt_cursor = 0;
            self.mode = .list;
            self.say("cancelled", .{});
            return true;
        }
        if (eq(spec, "enter")) {
            self.mode = .list;
            try self.submitPrompt();
            return true;
        }
        if (eq(spec, "left")) {
            self.prompt_cursor -|= 1;
            return true;
        }
        if (eq(spec, "right")) {
            if (self.prompt_cursor < self.prompt_buf.items.len) self.prompt_cursor += 1;
            return true;
        }
        if (eq(spec, "home") or eq(spec, "ctrl+a")) {
            self.prompt_cursor = 0;
            return true;
        }
        if (eq(spec, "end") or eq(spec, "ctrl+e")) {
            self.prompt_cursor = self.prompt_buf.items.len;
            return true;
        }
        if (eq(spec, "backspace")) {
            if (self.prompt_cursor > 0) {
                _ = self.prompt_buf.orderedRemove(self.prompt_cursor - 1);
                self.prompt_cursor -= 1;
            }
            return true;
        }
        if (eq(spec, "delete")) {
            if (self.prompt_cursor < self.prompt_buf.items.len) _ = self.prompt_buf.orderedRemove(self.prompt_cursor);
            return true;
        }
        if (eq(spec, "ctrl+u")) {
            self.prompt_buf.clearRetainingCapacity();
            self.prompt_cursor = 0;
            return true;
        }
        if (eq(spec, "space")) return self.insert(" ");
        if (isText(spec)) return self.insert(spec);
        return true;
    }

    /// Text arriving as a bracketed paste, which is one event however
    /// long it is.
    pub fn paste(self: *App, text: []const u8) Allocator.Error!void {
        switch (self.mode) {
            .prompt => _ = try self.insert(text),
            .filter => {
                try self.filter_buf.appendSlice(self.gpa, text);
                self.applyFilter(self.activeTab());
            },
            else => {},
        }
    }

    fn insert(self: *App, text: []const u8) Allocator.Error!bool {
        try self.prompt_buf.insertSlice(self.gpa, self.prompt_cursor, text);
        self.prompt_cursor += text.len;
        return true;
    }

    fn confirmKey(self: *App, spec: []const u8) Allocator.Error!bool {
        if (eq(spec, "esc") or eq(spec, "n") or eq(spec, "q")) {
            self.pending = null;
            self.mode = .list;
            self.say("cancelled", .{});
            return true;
        }
        if (eq(spec, "y") or eq(spec, "enter")) {
            const what = self.pending orelse {
                self.mode = .list;
                return true;
            };
            self.pending = null;
            self.mode = .list;
            try self.perform(what);
        }
        return true;
    }

    /// A page of whichever surface has the focus.
    fn page(self: *App, direction: i64) bool {
        const step: i64 = @intCast(@max(self.bodyHeight() / 2, 1));
        if (self.show_detail and self.detail != null) {
            const d = &self.detail.?;
            if (direction < 0) d.scroll -|= @intCast(step) else d.scroll += @intCast(step);
            return true;
        }
        return self.move(direction * step);
    }

    fn move(self: *App, delta: i64) bool {
        const tab = self.activeTab();
        if (tab.visible.len == 0) return true;
        const last: i64 = @intCast(tab.visible.len - 1);
        var next: i64 = @as(i64, @intCast(tab.selected)) + delta;
        next = std.math.clamp(next, 0, last);
        return self.moveTo(@intCast(next));
    }

    /// Put the cursor on a visible row — what a click does.
    pub fn select(self: *App, index: usize) bool {
        return self.moveTo(index);
    }

    fn moveTo(self: *App, index: usize) bool {
        const tab = self.activeTab();
        if (tab.visible.len == 0) return true;
        const before = tab.selected;
        tab.selected = @min(index, tab.visible.len - 1);
        tab.scroll = view.scrollFor(tab.selected, self.bodyHeight(), tab.visible.len, tab.scroll);
        if (before != tab.selected) {
            self.issue_cursor = 0;
            if (self.show_detail) self.ensureDetail() catch {};
        }
        return true;
    }

    /// Rows available to the list: the pane minus the tab strip, the
    /// filter line, the column header and the footer.
    pub fn bodyHeight(self: *const App) u16 {
        return self.rows -| 4;
    }

    // ─── the filter ──────────────────────────────────────────────────

    pub fn applyFilter(self: *App, tab: *TabState) void {
        const q = self.filter_buf.items;
        var keep: std.ArrayList(usize) = .empty;
        const a = tab.arena.allocator();
        for (tab.rows, 0..) |row, i| {
            if (q.len == 0 or matches(row.pr, q)) keep.append(a, i) catch {};
        }
        tab.visible = keep.toOwnedSlice(a) catch &.{};
        if (tab.selected >= tab.visible.len) tab.selected = tab.visible.len -| 1;
        tab.scroll = view.scrollFor(tab.selected, self.bodyHeight(), tab.visible.len, tab.scroll);
    }

    /// Case-insensitive, over every column the list paints — a filter
    /// that only looked at the title would not find `#1234`.
    pub fn matches(pr: model.Pr, q: []const u8) bool {
        var idbuf: [16]u8 = undefined;
        const id_text = std.fmt.bufPrint(&idbuf, "#{d}", .{pr.id}) catch "";
        const haystacks = [_][]const u8{
            pr.title,       pr.author, pr.repo_full_name, pr.source_branch,
            pr.dest_branch, pr.state,  id_text,
        };
        for (haystacks) |h| {
            if (std.ascii.indexOfIgnoreCase(h, q) != null) return true;
        }
        return false;
    }

    // ─── actions ─────────────────────────────────────────────────────

    fn focusedKey(self: *App) ?Detail.Key {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return null;
        const ws = if (pr.workspace().len > 0) pr.workspace() else self.config.tabWorkspace(tab.tab);
        const repo = if (pr.repo().len > 0) pr.repo() else tab.tab.repo;
        return .{ .workspace = ws, .repo = repo, .id = pr.id };
    }

    fn openInBrowser(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse {
            self.say("nothing focused", .{});
            return true;
        };
        const a = self.fx_arena.allocator();
        const url = if (pr.html_url.len > 0)
            try a.dupe(u8, pr.html_url)
        else blk: {
            const k = self.focusedKey().?;
            break :blk try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pull-requests/{d}", .{ k.workspace, k.repo, k.id });
        };
        self.push(.{ .open_url = url });
        self.say("opened {s}", .{url});
        return true;
    }

    fn copyUrl(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        const a = self.fx_arena.allocator();
        const url = if (pr.html_url.len > 0) try a.dupe(u8, pr.html_url) else blk: {
            const k = self.focusedKey().?;
            break :blk try std.fmt.allocPrint(a, "https://bitbucket.org/{s}/{s}/pull-requests/{d}", .{ k.workspace, k.repo, k.id });
        };
        self.push(.{ .copy = url });
        self.say("copied the URL", .{});
        return true;
    }

    fn copyBranch(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        if (pr.source_branch.len == 0) {
            self.say("this PR has no source branch", .{});
            return true;
        }
        self.push(.{ .copy = try self.fx_arena.allocator().dupe(u8, pr.source_branch) });
        self.say("copied {s}", .{pr.source_branch});
        return true;
    }

    fn openIssue(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const both = try std.mem.concat(scratch.allocator(), u8, &.{ pr.title, "\n", pr.description });
        const keys = try links.scanKeys(scratch.allocator(), both, self.config.jira.project_keys);
        if (keys.len == 0) {
            self.say("no issue key on this pull request", .{});
            return true;
        }
        const k = keys[self.issue_cursor % keys.len];
        self.issue_cursor = (self.issue_cursor + 1) % keys.len;
        const a = self.fx_arena.allocator();
        switch (try links.jiraTarget(a, self.config.jira, k.text, self.jira_installed)) {
            .command => |id| {
                self.push(.{ .command = try a.dupe(u8, id) });
                self.say("{s} → {s}", .{ k.text, id });
            },
            .url => |u| {
                self.push(.{ .open_url = u });
                self.say("{s} → {s}", .{ k.text, u });
            },
            .unavailable => |why| self.toast(.warn, "{s}: {s}", .{ k.text, why }),
        }
        return true;
    }

    fn beginVote(self: *App, what: Pending) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        if (self.client.rate.max_attempts == 0) {} // keep `self.client` used on every path
        const k = self.focusedKey().?;
        const a = self.fx_arena.allocator();
        const title = switch (what) {
            .approve => "Approve",
            .withdraw_approval => "Withdraw your approval on",
            .request_changes => "Request changes on",
            .withdraw_changes => "Withdraw your change request on",
            else => "Act on",
        };
        self.pending = what;
        self.pending_detail = try std.fmt.allocPrint(a, "{s} {s}/{s}#{d}?", .{ title, k.workspace, k.repo, k.id });
        self.mode = .confirm;
        _ = pr;
        return true;
    }

    fn beginMerge(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        if (!std.mem.eql(u8, pr.state, "OPEN")) {
            self.toast(.warn, "#{d} is {s} — only an OPEN pull request can be merged", .{ pr.id, pr.state });
            return true;
        }
        const k = self.focusedKey().?;
        self.pending = .merge;
        self.pending_detail = try std.fmt.allocPrint(self.fx_arena.allocator(), "Merge {s}/{s}#{d} — strategy: {s} · close source branch: {s} (s cycles the strategy)", .{
            k.workspace,
            k.repo,
            k.id,
            self.merge_strategy.label(),
            if (self.close_source_branch) "yes" else "no",
        });
        self.mode = .confirm;
        return true;
    }

    fn beginCheckout(self: *App) Allocator.Error!bool {
        const tab = self.activeTab();
        const pr = tab.focused() orelse return true;
        const k = self.focusedKey().?;
        const facts = try gitmod.facts(self.gpa, self.io, self.workspace_dir, self.config.mnml.allow_checkout);
        defer self.gpa.free(facts.origin);
        switch (gitmod.check(facts, k.workspace, k.repo)) {
            .refuse => |r| {
                self.toast(.warn, "cannot check out {s}: {s}", .{ pr.source_branch, r.message() });
                return true;
            },
            .go => {},
        }
        self.pending = .checkout;
        self.pending_detail = try std.fmt.allocPrint(self.fx_arena.allocator(), "Check out {s} in {s}?", .{ pr.source_branch, self.workspace_dir });
        self.mode = .confirm;
        return true;
    }

    fn beginComment(self: *App) Allocator.Error!bool {
        if (self.activeTab().focused() == null) return true;
        self.prompt_kind = .comment;
        self.prompt_buf.clearRetainingCapacity();
        self.prompt_cursor = 0;
        self.mode = .prompt;
        return true;
    }

    fn submitPrompt(self: *App) Allocator.Error!void {
        const text = std.mem.trim(u8, self.prompt_buf.items, " \t\r\n");
        if (text.len == 0) {
            self.say("nothing to post", .{});
            return;
        }
        const k = self.focusedKey() orelse return;
        if (self.client.writeRefused()) |why| {
            self.toast(.err, "{s}", .{why});
            return;
        }
        var reply = try self.client.comment(self.gpa, k.workspace, k.repo, k.id, text, "", null);
        defer reply.deinit(self.gpa);
        switch (reply) {
            .ok => {
                self.toast(.info, "commented on {s}/{s}#{d}", .{ k.workspace, k.repo, k.id });
                self.prompt_buf.clearRetainingCapacity();
                self.prompt_cursor = 0;
                self.invalidateDetail();
                if (self.show_detail) try self.ensureDetail();
            },
            .failed => |f| self.reportFailure("comment", f),
        }
    }

    fn perform(self: *App, what: Pending) Allocator.Error!void {
        const k = self.focusedKey() orelse return;
        if (what == .checkout) {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const pr = self.activeTab().focused().?;
            const out = try gitmod.checkout(scratch.allocator(), self.io, self.workspace_dir, pr.source_branch);
            if (out.ok) {
                self.toast(.info, "{s}", .{out.message});
                if (self.config.mnml.after_checkout_command.len > 0) {
                    self.push(.{ .command = try self.fx_arena.allocator().dupe(u8, self.config.mnml.after_checkout_command) });
                }
            } else self.toast(.err, "{s}", .{out.message});
            return;
        }
        if (self.client.writeRefused()) |why| {
            self.toast(.err, "{s}", .{why});
            return;
        }
        var reply = switch (what) {
            .approve => try self.client.approve(self.gpa, k.workspace, k.repo, k.id),
            .withdraw_approval => try self.client.unapprove(self.gpa, k.workspace, k.repo, k.id),
            .request_changes => try self.client.requestChanges(self.gpa, k.workspace, k.repo, k.id),
            .withdraw_changes => try self.client.withdrawChanges(self.gpa, k.workspace, k.repo, k.id),
            .merge => try self.client.merge(self.gpa, k.workspace, k.repo, k.id, self.merge_strategy, self.close_source_branch),
            .checkout => unreachable,
        };
        defer reply.deinit(self.gpa);
        const label = switch (what) {
            .approve => "approved",
            .withdraw_approval => "withdrew your approval on",
            .request_changes => "requested changes on",
            .withdraw_changes => "withdrew your change request on",
            .merge => "merged",
            .checkout => unreachable,
        };
        switch (reply) {
            .ok => {
                self.toast(.info, "{s} {s}/{s}#{d}", .{ label, k.workspace, k.repo, k.id });
                self.invalidateDetail();
                try self.refreshActive();
                if (self.show_detail) try self.ensureDetail();
            },
            .failed => |f| self.reportFailure(label, f),
        }
    }

    fn reportFailure(self: *App, what: []const u8, f: api.Failure) void {
        var buf: [96]u8 = undefined;
        self.toast(.err, "{s} failed: {s} — {s}", .{ what, f.shortLabel(&buf), f.message });
    }

    // ─── fetching ────────────────────────────────────────────────────

    pub fn switchTab(self: *App, index: usize) Allocator.Error!void {
        if (index >= self.tabs.len) return;
        self.active = index;
        const tab = self.activeTab();
        if (!tab.fetched) try self.refreshActive();
        self.applyFilter(tab);
        if (self.show_detail) try self.ensureDetail();
    }

    /// `/2.0/user`, once per run. A tab whose mode needs it and cannot
    /// have it falls back rather than showing an empty list with no
    /// explanation.
    fn ensureIdentity(self: *App) Allocator.Error!bool {
        if (self.me_account_id.len > 0) return true;
        if (self.whoami_tried) return false;
        self.whoami_tried = true;
        var reply = try self.client.whoami(self.gpa);
        defer reply.deinit(self.gpa);
        switch (reply) {
            .ok => |b| {
                var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, b.bytes, .{}) catch {
                    self.whoami_error = "/2.0/user did not answer JSON";
                    return false;
                };
                defer parsed.deinit();
                const a = self.ident_arena.allocator();
                self.me_account_id = try a.dupe(u8, j.str(parsed.value, "account_id"));
                self.me_display_name = try a.dupe(u8, j.str(parsed.value, "display_name"));
                if (self.me_account_id.len == 0) {
                    self.whoami_error = "/2.0/user answered without an account_id — the token needs Account: Read";
                    return false;
                }
                return true;
            },
            .failed => |f| {
                var buf: [96]u8 = undefined;
                self.whoami_error = try std.fmt.allocPrint(self.ident_arena.allocator(), "/2.0/user: {s} — a mine / reviewing tab needs Account: Read", .{f.shortLabel(&buf)});
                return false;
            },
        }
    }

    /// One query in a tab's fan-out.
    const Query = struct {
        workspace: []const u8,
        repo: []const u8,
        state: cfg.State,
        bbql: []const u8,
    };

    pub fn refreshActive(self: *App) Allocator.Error!void {
        const tab = self.activeTab();
        _ = tab.arena.reset(.retain_capacity);
        const a = tab.arena.allocator();
        tab.rows = &.{};
        tab.visible = &.{};
        tab.error_text = "";
        tab.notes = &.{};
        tab.fallback_note = "";
        tab.fetched = true;
        tab.last_fetch_ms = nowMs(self.io);

        var mode = tab.tab.mode;
        if (mode == .mine or mode == .reviewing) {
            if (!try self.ensureIdentity()) {
                switch (tab.tab.fallback) {
                    .none => {
                        tab.error_text = try a.dupe(u8, self.whoami_error);
                        self.applyFilter(tab);
                        return;
                    },
                    .repo => {
                        mode = .repo;
                        tab.fallback_note = "repo";
                    },
                    .workspace => {
                        mode = .workspace;
                        tab.fallback_note = "workspace";
                    },
                }
            }
        }

        const predicate: []const u8 = switch (mode) {
            .mine => try api.authorPredicate(a, self.me_account_id),
            .reviewing => try api.reviewerPredicate(a, self.me_account_id),
            .repo, .workspace => "",
        };
        const bbql = try api.andPredicates(a, predicate, tab.tab.q);

        var queries: std.ArrayList(Query) = .empty;
        const ws = self.config.tabWorkspace(tab.tab);
        switch (mode) {
            .repo => try queries.append(a, .{ .workspace = ws, .repo = tab.tab.repo, .state = tab.tab.state, .bbql = bbql }),
            .mine, .reviewing, .workspace => for (self.config.repos) |slug| {
                if (self.config.isHidden(slug)) continue;
                try queries.append(a, .{ .workspace = ws, .repo = slug, .state = tab.tab.state, .bbql = bbql });
            },
        }

        const progress_label = try std.fmt.allocPrint(self.fx_arena.allocator(), "Bitbucket · {s}", .{tab.tab.name});
        self.push(.{ .progress_start = .{ .id = "bitbucket.refresh", .label = progress_label } });

        var rows: std.ArrayList(view.Row) = .empty;
        var notes: std.ArrayList([]const u8) = .empty;
        for (queries.items, 0..) |q, i| {
            const pct: u8 = @intCast(@min(99, (i * 100) / @max(queries.items.len, 1)));
            self.push(.{ .progress_update = .{ .id = "bitbucket.refresh", .label = q.repo, .percent = pct } });
            var reply = try self.client.listPrs(self.gpa, q.workspace, q.repo, q.state, q.bbql, self.config.page_len);
            defer reply.deinit(self.gpa);
            switch (reply) {
                .failed => |f| {
                    var buf: [96]u8 = undefined;
                    try notes.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ q.repo, f.shortLabel(&buf) }));
                    continue;
                },
                .ok => |b| {
                    var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, b.bytes, .{}) catch {
                        try notes.append(a, try std.fmt.allocPrint(a, "{s}: the response was not JSON", .{q.repo}));
                        continue;
                    };
                    defer parsed.deinit();
                    for (j.array(parsed.value, "values")) |v| {
                        var pr = try model.Pr.fromValue(a, v);
                        pr = try dupePr(a, pr);
                        if (pr.repo_full_name.len == 0) {
                            pr.repo_full_name = try std.fmt.allocPrint(a, "{s}/{s}", .{ q.workspace, q.repo });
                        }
                        try rows.append(a, .{ .pr = pr });
                    }
                },
            }
        }
        self.push(.{ .progress_end = .{ .id = "bitbucket.refresh", .ok = notes.items.len == 0 } });

        const slice = try rows.toOwnedSlice(a);
        // Newest first, across repos: the per-repo responses are each
        // sorted, the merge is not.
        std.mem.sort(view.Row, slice, {}, newerFirst);
        tab.rows = slice;
        tab.notes = try notes.toOwnedSlice(a);
        if (tab.selected >= slice.len) tab.selected = slice.len -| 1;
        self.applyFilter(tab);
        self.say("{s}: {d} pull requests", .{ tab.tab.name, slice.len });
    }

    fn newerFirst(_: void, a: view.Row, b: view.Row) bool {
        return std.mem.order(u8, a.pr.updated_on, b.pr.updated_on) == .gt;
    }

    pub fn invalidateDetail(self: *App) void {
        if (self.detail) |*d| {
            d.deinit();
            self.detail = null;
        }
    }

    /// Fetch the focused PR's detail if it is not already the one
    /// cached. Five requests: the PR, its activity, its diffstat, its
    /// diff and its build statuses.
    pub fn ensureDetail(self: *App) Allocator.Error!void {
        const k = self.focusedKey() orelse {
            self.invalidateDetail();
            return;
        };
        if (self.detail) |d| if (d.key.eql(k) and !d.loading) return;
        self.invalidateDetail();

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();
        var d: Detail = .{
            .arena = arena,
            .key = .{
                .workspace = a.dupe(u8, k.workspace) catch k.workspace,
                .repo = a.dupe(u8, k.repo) catch k.repo,
                .id = k.id,
            },
            .pr = self.activeTab().focused().?,
        };

        var reply = try self.client.prDetail(self.gpa, k.workspace, k.repo, k.id);
        defer reply.deinit(self.gpa);
        switch (reply) {
            .failed => |f| {
                var buf: [96]u8 = undefined;
                d.error_text = std.fmt.allocPrint(a, "detail: {s} — {s}", .{ f.shortLabel(&buf), f.message }) catch "detail failed";
                d.arena = arena;
                self.detail = d;
                return;
            },
            .ok => |b| {
                var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, b.bytes, .{}) catch {
                    d.error_text = "the detail response was not JSON";
                    d.arena = arena;
                    self.detail = d;
                    return;
                };
                defer parsed.deinit();
                d.pr = try dupePr(a, try model.Pr.fromValue(a, parsed.value));
                d.reviewers = try d.pr.reviewerRoster(a);
            },
        }

        const both = try std.mem.concat(a, u8, &.{ d.pr.title, "\n", d.pr.description });
        d.jira_keys = try links.scanKeys(a, both, self.config.jira.project_keys);

        var act = try self.client.activity(self.gpa, k.workspace, k.repo, k.id);
        defer act.deinit(self.gpa);
        if (act == .ok) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, act.ok.bytes, .{}) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                var list: std.ArrayList(model.Activity) = .empty;
                for (j.array(p.value, "values")) |v| {
                    try list.append(a, try dupeActivity(a, model.Activity.fromValue(v)));
                }
                d.activity = try list.toOwnedSlice(a);
            }
        }

        var ds = try self.client.diffstat(self.gpa, k.workspace, k.repo, k.id);
        defer ds.deinit(self.gpa);
        if (ds == .ok) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, ds.ok.bytes, .{}) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                var list: std.ArrayList(model.DiffstatEntry) = .empty;
                for (j.array(p.value, "values")) |v| {
                    const e = model.DiffstatEntry.fromValue(v);
                    try list.append(a, .{
                        .status = try a.dupe(u8, e.status),
                        .path = try a.dupe(u8, e.path),
                        .old_path = try a.dupe(u8, e.old_path),
                        .added = e.added,
                        .removed = e.removed,
                    });
                }
                d.files = try list.toOwnedSlice(a);
            }
        }

        if (self.show_diff) {
            var df = try self.client.diff(self.gpa, k.workspace, k.repo, k.id);
            defer df.deinit(self.gpa);
            if (df == .ok) d.diff = try a.dupe(u8, df.ok.bytes);
        }

        if (d.pr.source_commit.len > 0) {
            var st = try self.client.statuses(self.gpa, k.workspace, k.repo, d.pr.source_commit);
            defer st.deinit(self.gpa);
            if (st == .ok) {
                var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, st.ok.bytes, .{}) catch null;
                if (parsed) |*p| {
                    defer p.deinit();
                    var list: std.ArrayList(model.BuildStatus) = .empty;
                    for (j.array(p.value, "values")) |v| {
                        const b = model.BuildStatus.fromValue(v);
                        try list.append(a, .{
                            .key = try a.dupe(u8, b.key),
                            .name = try a.dupe(u8, b.name),
                            .state = try a.dupe(u8, b.state),
                            .url = try a.dupe(u8, b.url),
                        });
                    }
                    d.builds = try list.toOwnedSlice(a);
                }
            }
        }
        d.arena = arena;
        self.detail = d;
        // The list row shows the worst build state the detail found.
        self.stampBuild(d.builds);
    }

    /// Put the focused row's build glyph on the list, so a red pipeline
    /// is visible without opening the detail.
    fn stampBuild(self: *App, builds: []const model.BuildStatus) void {
        if (builds.len == 0) return;
        const tab = self.activeTab();
        if (tab.visible.len == 0) return;
        const row_index = tab.visible[@min(tab.selected, tab.visible.len - 1)];
        var worst = builds[0];
        for (builds) |b| {
            if (std.ascii.eqlIgnoreCase(b.state, "FAILED")) worst = b;
        }
        const mutable: []view.Row = @constCast(tab.rows);
        mutable[row_index].build = .{
            .key = tab.arena.allocator().dupe(u8, worst.key) catch "",
            .name = tab.arena.allocator().dupe(u8, worst.name) catch "",
            .state = tab.arena.allocator().dupe(u8, worst.state) catch "",
        };
    }
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// A PR parsed off a `std.json.Parsed` points into it; the tab's arena
/// has to own the strings that outlive the parse.
fn dupePr(a: Allocator, pr: model.Pr) Allocator.Error!model.Pr {
    var out = pr;
    out.title = try a.dupe(u8, pr.title);
    out.state = try a.dupe(u8, pr.state);
    out.updated_on = try a.dupe(u8, pr.updated_on);
    out.author = try a.dupe(u8, pr.author);
    out.author_account_id = try a.dupe(u8, pr.author_account_id);
    out.source_branch = try a.dupe(u8, pr.source_branch);
    out.dest_branch = try a.dupe(u8, pr.dest_branch);
    out.repo_full_name = try a.dupe(u8, pr.repo_full_name);
    out.html_url = try a.dupe(u8, pr.html_url);
    out.description = try a.dupe(u8, pr.description);
    out.merge_commit = try a.dupe(u8, pr.merge_commit);
    out.source_commit = try a.dupe(u8, pr.source_commit);
    out.participants = try dupeParticipants(a, pr.participants);
    out.reviewers = try dupeParticipants(a, pr.reviewers);
    return out;
}

fn dupeParticipants(a: Allocator, list: []const model.Participant) Allocator.Error![]const model.Participant {
    const out = try a.alloc(model.Participant, list.len);
    for (list, out) |p, *slot| slot.* = .{
        .display_name = try a.dupe(u8, p.display_name),
        .account_id = try a.dupe(u8, p.account_id),
        .role = try a.dupe(u8, p.role),
        .approval = p.approval,
    };
    return out;
}

fn dupeActivity(a: Allocator, act: model.Activity) Allocator.Error!model.Activity {
    var out = act;
    out.author = try a.dupe(u8, act.author);
    out.created_on = try a.dupe(u8, act.created_on);
    out.text = try a.dupe(u8, act.text);
    out.inline_path = try a.dupe(u8, act.inline_path);
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// mnml folds an uppercase letter into `shift+<lower>` before it reaches
/// a mount (`core/key.zig`'s `Chord.of`), and reports a back-tab as
/// `backtab` rather than `shift+tab`. The keymap above is written the
/// way a user says it — `D`, `shift+tab` — so both spellings are folded
/// back here, once, rather than doubled at twenty comparisons.
pub fn normalizeSpec(raw: []const u8, buf: *[8]u8) []const u8 {
    if (std.mem.eql(u8, raw, "shift+tab")) return "backtab";
    if (!std.mem.startsWith(u8, raw, "shift+")) return raw;
    const rest = raw["shift+".len..];
    if (rest.len == 1 and rest[0] >= 'a' and rest[0] <= 'z') {
        buf[0] = rest[0] - ('a' - 'A');
        return buf[0..1];
    }
    // `shift+/` is a `?` on a US layout, and `?` is the help key; every
    // other punctuation arrives unshifted, so this is the one pair
    // worth folding rather than a whole layout table.
    if (std.mem.eql(u8, rest, "/")) return "?";
    return raw;
}

/// A key spec that is one printable character is text; `ctrl+x` and
/// `enter` are not.
fn isText(spec: []const u8) bool {
    if (spec.len == 0 or spec.len > 4) return false;
    if (std.mem.indexOfScalar(u8, spec, '+') != null) return false;
    if (spec.len == 1) return spec[0] >= 0x20 and spec[0] != 0x7f;
    // A multi-byte code point typed directly.
    return spec[0] >= 0x80;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const listener = @import("../tools/fake_bitbucket/listener.zig");

const Harness = struct {
    srv: *listener.Server,
    client: api.Client,
    app: App,
    arena: std.heap.ArenaAllocator,

    fn init(tabs: []const cfg.Tab) !*Harness {
        const h = try t.allocator.create(Harness);
        h.arena = std.heap.ArenaAllocator.init(t.allocator);
        h.srv = try listener.Server.start(t.allocator, t.io, 0);
        const base = try h.srv.baseUrl(t.allocator);
        defer t.allocator.free(base);
        h.client = try api.Client.init(t.allocator, t.io, base, "me@example.com", "read-tok", "write-tok", .{ .min_interval_ms = 0 });
        const config: cfg.Config = .{
            .email = "me@example.com",
            .workspace = "acme",
            .repos = &.{ "api", "web" },
            .tabs = tabs,
            .jira = .{ .enabled = true, .base_url = "https://acme.atlassian.net", .project_keys = &.{"TE"} },
        };
        h.app = try App.init(t.allocator, t.io, config, &h.client);
        h.app.rows = 40;
        h.app.cols = 120;
        return h;
    }

    fn deinit(h: *Harness) void {
        h.app.deinit();
        h.client.deinit();
        h.srv.stop();
        h.arena.deinit();
        t.allocator.destroy(h);
    }

    /// Run a key and drop whatever it queued, keeping the strings alive
    /// on the harness arena so a test can look at them.
    fn key(h: *Harness, spec: []const u8) !bool {
        return h.app.key(spec);
    }

    fn effects(h: *Harness) []const Effect {
        return h.app.effects.items;
    }

    fn sawToast(h: *Harness, needle: []const u8) bool {
        for (h.effects()) |e| switch (e) {
            .toast => |x| if (std.mem.indexOf(u8, x.text, needle) != null) return true,
            else => {},
        };
        return false;
    }

    fn sawCopy(h: *Harness, needle: []const u8) bool {
        for (h.effects()) |e| switch (e) {
            .copy => |x| if (std.mem.indexOf(u8, x, needle) != null) return true,
            else => {},
        };
        return false;
    }

    fn sawUrl(h: *Harness, needle: []const u8) bool {
        for (h.effects()) |e| switch (e) {
            .open_url => |x| if (std.mem.indexOf(u8, x, needle) != null) return true,
            else => {},
        };
        return false;
    }

    fn sawCommand(h: *Harness, id: []const u8) bool {
        for (h.effects()) |e| switch (e) {
            .command => |x| if (std.mem.eql(u8, x, id)) return true,
            else => {},
        };
        return false;
    }
};

test "a repo tab lists that repo's open PRs, newest first" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    const tab = h.app.activeTab();
    try t.expectEqual(@as(usize, 2), tab.rows.len);
    try t.expectEqual(@as(usize, 2), tab.visible.len);
    // #1234's updated_on is later than #1198's, so it leads.
    try t.expectEqual(@as(i64, 1234), tab.rows[0].pr.id);
    try t.expectEqualStrings("acme/api", tab.rows[0].pr.repo_full_name);
    try t.expectEqualStrings("", tab.error_text);
    try t.expectEqual(@as(usize, 0), tab.notes.len);
}

test "a mine tab resolves the account and fans out over the configured repos" {
    const h = try Harness.init(&.{.{ .name = "Mine", .mode = .mine }});
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expectEqualStrings("acct-chris", h.app.me_account_id);
    const tab = h.app.activeTab();
    // Two repos, two PRs authored by the account (api#1234 and web#820).
    try t.expectEqual(@as(usize, 2), tab.rows.len);
    var ids: [2]i64 = undefined;
    for (tab.rows, 0..) |row, i| ids[i] = row.pr.id;
    try t.expect((ids[0] == 1234 and ids[1] == 820) or (ids[0] == 820 and ids[1] == 1234));
}

test "a reviewing tab asks for the PRs the account reviews, not the ones it wrote" {
    const h = try Harness.init(&.{.{ .name = "Review queue", .mode = .reviewing }});
    defer h.deinit();
    try h.app.switchTab(0);
    const tab = h.app.activeTab();
    try t.expectEqual(@as(usize, 1), tab.rows.len);
    try t.expectEqual(@as(i64, 1198), tab.rows[0].pr.id);
}

test "a mine tab with no Account: Read falls back the way the tab asked, and says which" {
    // A token that reads pull requests but not the account: exactly
    // what a Bitbucket app password without Account: Read does.
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "read-tok", .{ .min_interval_ms = 0 });
    defer client.deinit();

    srv.denyUser(true);

    // `.none`: the tab is empty and explains itself.
    {
        var app = try App.init(t.allocator, t.io, .{
            .email = "a@b.c",
            .workspace = "acme",
            .repos = &.{"api"},
            .tabs = &.{.{ .name = "Mine", .mode = .mine, .fallback = .none }},
        }, &client);
        defer app.deinit();
        try app.switchTab(0);
        try t.expectEqual(@as(usize, 0), app.activeTab().rows.len);
        try t.expect(std.mem.indexOf(u8, app.activeTab().error_text, "Account: Read") != null);
        try t.expectEqualStrings("", app.activeTab().fallback_note);
    }
    // `.workspace`: the same tab shows every open PR instead, and the
    // tab strip says so.
    {
        var app = try App.init(t.allocator, t.io, .{
            .email = "a@b.c",
            .workspace = "acme",
            .repos = &.{"api"},
            .tabs = &.{.{ .name = "Mine", .mode = .mine, .fallback = .workspace }},
        }, &client);
        defer app.deinit();
        try app.switchTab(0);
        try t.expectEqualStrings("workspace", app.activeTab().fallback_note);
        try t.expectEqual(@as(usize, 2), app.activeTab().rows.len);
        try t.expectEqualStrings("", app.activeTab().error_text);
    }
}

test "a repo that fails leaves a note and does not blank the rest of the tab" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "tok", "tok", .{ .min_interval_ms = 0 });
    defer client.deinit();
    var app = try App.init(t.allocator, t.io, .{
        .email = "a@b.c",
        .workspace = "acme",
        // `ghost` is not in the fake workspace: a 404 on one of three.
        .repos = &.{ "api", "ghost", "web" },
        .tabs = &.{.{ .name = "All", .mode = .workspace }},
    }, &client);
    defer app.deinit();
    try app.switchTab(0);
    const tab = app.activeTab();
    try t.expectEqual(@as(usize, 3), tab.rows.len); // api's two + web's one
    try t.expectEqual(@as(usize, 1), tab.notes.len);
    try t.expect(std.mem.indexOf(u8, tab.notes[0], "ghost") != null);
    try t.expect(std.mem.indexOf(u8, tab.notes[0], "no such repo") != null);
}

test "moving the selection, paging and the g / G ends" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expectEqual(@as(usize, 0), h.app.activeTab().selected);
    _ = try h.key("j");
    try t.expectEqual(@as(usize, 1), h.app.activeTab().selected);
    _ = try h.key("j"); // clamped at the end
    try t.expectEqual(@as(usize, 1), h.app.activeTab().selected);
    _ = try h.key("g");
    try t.expectEqual(@as(usize, 0), h.app.activeTab().selected);
    _ = try h.key("G");
    try t.expectEqual(@as(usize, 1), h.app.activeTab().selected);
    _ = try h.key("k");
    try t.expectEqual(@as(usize, 0), h.app.activeTab().selected);
    _ = try h.key("up"); // clamped at the top
    try t.expectEqual(@as(usize, 0), h.app.activeTab().selected);
}

test "the filter narrows the list across every column, and esc puts it back" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expectEqual(@as(usize, 2), h.app.activeTab().visible.len);
    _ = try h.key("/");
    try t.expectEqual(Mode.filter, h.app.mode);
    for ("login") |c| _ = try h.key(&[_]u8{c});
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    try t.expectEqual(@as(i64, 1234), h.app.activeTab().focused().?.id);
    // A filter on the id, and on the author, and on the branch.
    _ = try h.key("ctrl+u");
    for ("1198") |c| _ = try h.key(&[_]u8{c});
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    _ = try h.key("ctrl+u");
    for ("dana") |c| _ = try h.key(&[_]u8{c});
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    // Enter keeps it; esc from the list clears it.
    _ = try h.key("enter");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    _ = try h.key("esc");
    try t.expectEqual(@as(usize, 2), h.app.activeTab().visible.len);
    // A filter that matches nothing leaves nothing focused rather than
    // pointing at a row that is not there.
    _ = try h.key("/");
    for ("zzz") |c| _ = try h.key(&[_]u8{c});
    try t.expectEqual(@as(usize, 0), h.app.activeTab().visible.len);
    try t.expect(h.app.activeTab().focused() == null);
    // And no action on an empty list is a crash.
    _ = try h.key("esc");
    _ = try h.key("enter");
}

test "backspace and a paste both reach the filter" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("/");
    for ("loginX") |c| _ = try h.key(&[_]u8{c});
    try t.expectEqual(@as(usize, 0), h.app.activeTab().visible.len);
    _ = try h.key("backspace");
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    _ = try h.key("ctrl+u");
    try h.app.paste("timeout");
    try t.expectEqual(@as(usize, 1), h.app.activeTab().visible.len);
    try t.expectEqual(@as(i64, 1198), h.app.activeTab().focused().?.id);
}

test "enter opens the PR in a browser, y copies its URL and Y its branch" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("enter");
    try t.expect(h.sawUrl("bitbucket.org/acme/api/pull-requests/1234"));
    _ = try h.key("y");
    try t.expect(h.sawCopy("pull-requests/1234"));
    _ = try h.key("Y");
    try t.expect(h.sawCopy("chris/fix-login"));
}

test "i sends a Jira key to the browser when no jira integration is installed, and cycles the keys" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("i");
    try t.expect(h.sawUrl("https://acme.atlassian.net/browse/ENG-4210"));
    // With the sibling installed, the same key runs its command instead.
    h.app.jira_installed = true;
    _ = try h.key("i");
    try t.expect(h.sawCommand("jira.open"));
    // A PR with no key says so rather than opening nothing.
    _ = try h.key("j");
    _ = try h.key("i");
    try t.expect(std.mem.indexOf(u8, h.app.status, "no issue key") != null);
}

test "approve is confirmed first, then goes out on the write token and shows up on the server" {
    const h = try Harness.init(&.{.{ .name = "Review queue", .mode = .reviewing }});
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expectEqual(@as(i64, 1198), h.app.activeTab().focused().?.id);

    _ = try h.key("a");
    try t.expectEqual(Mode.confirm, h.app.mode);
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "Approve acme/api#1198?") != null);
    // Escaping the confirm changes nothing on the server.
    _ = try h.key("esc");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expectEqual(@as(@TypeOf(h.srv.snapshot().votes[0]), .none), h.srv.snapshot().voteFor(1198));

    _ = try h.key("a");
    _ = try h.key("y");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expectEqual(@as(@TypeOf(h.srv.snapshot().votes[0]), .approved), h.srv.snapshot().voteFor(1198));
    try t.expect(h.sawToast("approved acme/api#1198"));
}

test "request changes and the two withdrawals are the same shape" {
    const h = try Harness.init(&.{.{ .name = "Review queue", .mode = .reviewing }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("x");
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "Request changes on") != null);
    _ = try h.key("y");
    try t.expectEqual(@as(@TypeOf(h.srv.snapshot().votes[0]), .changes_requested), h.srv.snapshot().voteFor(1198));
    _ = try h.key("X");
    _ = try h.key("y");
    try t.expectEqual(@as(@TypeOf(h.srv.snapshot().votes[0]), .none), h.srv.snapshot().voteFor(1198));
}

test "the merge confirm names the strategy, s cycles it, and a non-open PR is refused outright" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("m");
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "Merge acme/api#1234") != null);
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "strategy: squash") != null);
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "close source branch: yes") != null);
    _ = try h.key("esc");
    _ = try h.key("s");
    try t.expect(std.mem.indexOf(u8, h.app.status, "merge commit") != null);
    _ = try h.key("m");
    try t.expect(std.mem.indexOf(u8, h.app.pending_detail, "strategy: merge commit") != null);
    _ = try h.key("y");
    try t.expect(h.srv.snapshot().isMerged(1234));
    try t.expect(h.sawToast("merged acme/api#1234"));
    // The refresh after the merge moved it out of the OPEN tab.
    try t.expectEqual(@as(usize, 1), h.app.activeTab().rows.len);

    // A MERGED PR cannot be merged again, and the pane says why before
    // asking for a confirm it would only have to take back.
    const merged = try Harness.init(&.{.{ .name = "merged", .mode = .repo, .repo = "api", .state = .MERGED }});
    defer merged.deinit();
    try merged.app.switchTab(0);
    _ = try merged.key("m");
    try t.expectEqual(Mode.list, merged.app.mode);
    try t.expect(merged.sawToast("only an OPEN pull request can be merged"));
}

test "c opens a prompt with a full text field, and enter posts the comment" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("c");
    try t.expectEqual(Mode.prompt, h.app.mode);
    for ("shp t") |ch| _ = try h.key(if (ch == ' ') "space" else &[_]u8{ch});
    // The field is not append-only: move left, insert, delete forward.
    _ = try h.key("home");
    _ = try h.key("right");
    _ = try h.key("right");
    _ = try h.key("i");
    try t.expectEqualStrings("ship t", h.app.prompt_buf.items);
    _ = try h.key("end");
    try h.app.paste("his");
    try t.expectEqualStrings("ship this", h.app.prompt_buf.items);
    _ = try h.key("backspace");
    try t.expectEqualStrings("ship thi", h.app.prompt_buf.items);
    _ = try h.key("left");
    _ = try h.key("delete");
    try t.expectEqualStrings("ship th", h.app.prompt_buf.items);

    _ = try h.key("enter");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expectEqual(@as(usize, 1), h.srv.snapshot().comment_count);
    try t.expectEqualStrings("ship th", h.srv.snapshot().comments[0].text);
    try t.expect(h.sawToast("commented on acme/api#1234"));
}

test "esc abandons the comment and posts nothing; an empty comment posts nothing either" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("c");
    for ("nope") |ch| _ = try h.key(&[_]u8{ch});
    _ = try h.key("esc");
    try t.expectEqual(@as(usize, 0), h.srv.snapshot().comment_count);
    _ = try h.key("c");
    _ = try h.key("space");
    _ = try h.key("enter");
    try t.expectEqual(@as(usize, 0), h.srv.snapshot().comment_count);
    try t.expect(std.mem.indexOf(u8, h.app.status, "nothing to post") != null);
}

test "the detail fetches the PR, its reviewers, its builds, its diffstat, its diff and its threads" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("d");
    try t.expect(h.app.show_detail);
    const d = h.app.detail.?;
    try t.expectEqual(@as(i64, 1234), d.pr.id);
    try t.expectEqual(@as(usize, 2), d.reviewers.len);
    try t.expectEqual(@as(usize, 2), d.builds.len);
    try t.expectEqual(@as(usize, 2), d.files.len);
    try t.expect(std.mem.startsWith(u8, d.diff, "diff --git"));
    // Three comments plus two votes in the stream.
    try t.expect(d.activity.len >= 3);
    try t.expectEqual(@as(usize, 1), d.jira_keys.len);
    try t.expectEqualStrings("ENG-4210", d.jira_keys[0].text);
    // The list row picked up the failed build.
    try t.expectEqualStrings("FAILED", h.app.activeTab().rows[0].build.?.state);

    // Moving the selection re-fetches for the newly focused PR.
    _ = try h.key("j");
    try t.expectEqual(@as(i64, 1198), h.app.detail.?.pr.id);
    // D folds the diff away without dropping the detail.
    _ = try h.key("D");
    try t.expect(!h.app.show_diff);
    // d closes it.
    _ = try h.key("d");
    try t.expect(!h.app.show_detail);
}

test "a detail that fails to fetch keeps the pane alive and says what went wrong" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    // Point the client at a dead port so the detail's fetch fails.
    h.client.gpa.free(h.client.base_url);
    h.client.base_url = try t.allocator.dupe(u8, "http://127.0.0.1:1/2.0");
    _ = try h.key("d");
    try t.expect(h.app.detail != null);
    try t.expect(std.mem.indexOf(u8, h.app.detail.?.error_text, "network error") != null);
}

test "a write with no token at all is refused before a request goes out" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    // A read token but no write token, with the borrow turned off.
    var client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{ .min_interval_ms = 0 });
    defer client.deinit();
    client.write_refusal = "no write token: set BITBUCKET_ACCESS_TOKEN";
    var app = try App.init(t.allocator, t.io, .{
        .email = "a@b.c",
        .workspace = "acme",
        .repos = &.{"api"},
        .tabs = &.{.{ .name = "api", .mode = .repo, .repo = "api" }},
    }, &client);
    defer app.deinit();
    try app.switchTab(0);
    const before = client.sent;
    _ = try app.key("a");
    _ = try app.key("y");
    try t.expectEqual(before, client.sent);
    try t.expect(std.mem.indexOf(u8, app.status, "BITBUCKET_ACCESS_TOKEN") != null);
    try t.expectEqual(@as(@TypeOf(srv.snapshot().votes[0]), .none), srv.snapshot().voteFor(1234));
}

test "checkout refuses when the workspace is not a clone of the PR's repo, and never asks to confirm" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    h.app.workspace_dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    // The scratch dir is inside this checkout, so git answers about
    // mnml-zig — which is not acme/api either way.
    _ = try h.key("C");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expect(h.sawToast("cannot check out chris/fix-login"));
    // And with checkout switched off in config, the refusal names that.
    h.app.config.mnml.allow_checkout = false;
    _ = try h.key("C");
    try t.expect(h.sawToast("allow_checkout"));
}

test "tabs switch by number and by Tab, and each fetches once" {
    const h = try Harness.init(&.{
        .{ .name = "Mine", .mode = .mine },
        .{ .name = "Review queue", .mode = .reviewing },
        .{ .name = "api", .mode = .repo, .repo = "api" },
    });
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expect(h.app.tabs[0].fetched);
    try t.expect(!h.app.tabs[1].fetched);
    _ = try h.key("2");
    try t.expectEqual(@as(usize, 1), h.app.active);
    try t.expect(h.app.tabs[1].fetched);
    const fetched_at = h.app.tabs[1].last_fetch_ms;
    _ = try h.key("1");
    _ = try h.key("2");
    try t.expectEqual(fetched_at, h.app.tabs[1].last_fetch_ms); // not re-fetched
    _ = try h.key("tab");
    try t.expectEqual(@as(usize, 2), h.app.active);
    _ = try h.key("tab");
    try t.expectEqual(@as(usize, 0), h.app.active);
    _ = try h.key("shift+tab");
    try t.expectEqual(@as(usize, 2), h.app.active);
    // A number past the end does nothing rather than panicking.
    _ = try h.key("9");
    try t.expectEqual(@as(usize, 2), h.app.active);
    // r re-fetches the active tab.
    _ = try h.key("r");
    try t.expect(h.app.tabs[2].fetched);
}

test "a stale tab re-fetches on the next key, and a fresh one does not" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    h.app.config.refresh_interval_secs = 300;
    try h.app.switchTab(0);
    const first = h.app.activeTab().last_fetch_ms;
    _ = try h.key("j");
    try t.expectEqual(first, h.app.activeTab().last_fetch_ms);
    // Pretend the pane has been open for an hour.
    h.app.activeTab().last_fetch_ms -= 3600 * 1000;
    _ = try h.key("k");
    try t.expect(h.app.activeTab().last_fetch_ms > first - 3600 * 1000);
    // 0 turns it off: an ancient tab stays put until `r`.
    h.app.config.refresh_interval_secs = 0;
    h.app.activeTab().last_fetch_ms = 0;
    _ = try h.key("j");
    try t.expectEqual(@as(i64, 0), h.app.activeTab().last_fetch_ms);
    _ = try h.key("r");
    try t.expect(h.app.activeTab().last_fetch_ms > 0);
}

test "a refresh brackets itself with a progress effect mnml can paint" {
    const h = try Harness.init(&.{.{ .name = "Mine", .mode = .mine }});
    defer h.deinit();
    try h.app.switchTab(0);
    var started = false;
    var ended = false;
    var updates: usize = 0;
    for (h.effects()) |e| switch (e) {
        .progress_start => |x| {
            started = std.mem.indexOf(u8, x.label, "Mine") != null;
        },
        .progress_update => updates += 1,
        .progress_end => |x| ended = x.ok,
        else => {},
    };
    try t.expect(started);
    try t.expect(ended);
    try t.expectEqual(@as(usize, 2), updates); // one per repo
}

test "q quits and ? opens the key help, which any key closes" {
    const h = try Harness.init(&.{.{ .name = "api", .mode = .repo, .repo = "api" }});
    defer h.deinit();
    try h.app.switchTab(0);
    _ = try h.key("?");
    try t.expectEqual(Mode.help, h.app.mode);
    _ = try h.key("j");
    try t.expectEqual(Mode.list, h.app.mode);
    try t.expect(!try h.key("q"));
    var saw_quit = false;
    for (h.effects()) |e| if (e == .quit) {
        saw_quit = true;
    };
    try t.expect(saw_quit);
}

test "an uppercase letter arrives as shift+<lower>, and a back-tab as backtab" {
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("D", normalizeSpec("shift+d", &buf));
    try t.expectEqualStrings("A", normalizeSpec("shift+a", &buf));
    try t.expectEqualStrings("?", normalizeSpec("shift+/", &buf));
    try t.expectEqualStrings("backtab", normalizeSpec("shift+tab", &buf));
    try t.expectEqualStrings("backtab", normalizeSpec("backtab", &buf));
    // Anything else is left exactly as it arrived.
    try t.expectEqualStrings("d", normalizeSpec("d", &buf));
    try t.expectEqualStrings("ctrl+shift+p", normalizeSpec("ctrl+shift+p", &buf));
    try t.expectEqualStrings("shift+f5", normalizeSpec("shift+f5", &buf));
}

test "the shifted spelling of a key does what the plain one does" {
    const h = try Harness.init(&.{
        .{ .name = "api", .mode = .repo, .repo = "api" },
        .{ .name = "web", .mode = .repo, .repo = "web" },
    });
    defer h.deinit();
    try h.app.switchTab(0);
    try t.expect(h.app.show_diff);
    _ = try h.key("shift+d");
    try t.expect(!h.app.show_diff);
    _ = try h.key("tab");
    try t.expectEqual(@as(usize, 1), h.app.active);
    _ = try h.key("shift+tab");
    try t.expectEqual(@as(usize, 0), h.app.active);
    _ = try h.key("shift+/");
    try t.expectEqual(Mode.help, h.app.mode);
}

test "a key spec is text only when it is one printable character" {
    try t.expect(isText("a"));
    try t.expect(isText("Z"));
    try t.expect(isText("/"));
    try t.expect(isText("é"));
    try t.expect(!isText("ctrl+u"));
    try t.expect(!isText("enter"));
    try t.expect(!isText("esc"));
    try t.expect(!isText(""));
}
