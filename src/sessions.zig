//! SESSIONS — the AI sessions of this workspace, on the `todos.zig`
//! shape (D8). One row model, `Item`, behind two views: this sidebar
//! section (the cards, scoped to the workspace) and the sessions table
//! (`app/sessions_table.zig`, every row on the machine, grouped by
//! workspace). Three scanners feed it — the Claude Code / Codex
//! transcripts (`app/agents.zig` over `~/.claude/projects` and
//! `~/.codex/sessions`) and, when the API is configured, the cloud runs
//! (`app/cloud_agents.zig`) — from one worker that posts `.sessions =
//! *ScanResult`; the snapshot arena keeps the rows, `handle` adopts the
//! payload (and notices state edges: a session that starts `waiting`
//! toasts once, badges its tab, rings the bell when `ui.session_bell`),
//! a stale generation is dropped.
//!
//! // changed (sessions-merge): the AGENTS dashboard and the CLOUD
//! AGENTS section folded into this model; `waiting` / `done` / `failed`
//! are states; `dirty` is the cwd's `git status` count.
//!
//! // changed (sessions-card): the cards are THIS app's AI pty panes
//! (Rust's `is_ai_session_pane` — a pane whose command is `claude` or
//! `codex`, `pty_pane.productOf`), not the scan's rows. A card is
//! Rust's (`src/ui/sessions_panel.rs`, `TAB_H = 4`), cell for cell:
//! four rows and a blank one — the accent `▌` down its left, the name
//! (an alias the user gave it, else the child's window title with its
//! spinner stripped, else the pane's label) after a pin, then three
//! summary rows that follow the pane: `exited` alone in red once the
//! child is gone; else, at rest with a session id whose transcript the
//! scan lists, the transcript's last exchange as `you: …` / `claude: …`
//! (each clipped to 120 chars); else the pty grid's last content lines
//! — no footer chips, no input prompt, no chrome — so a fresh session
//! reads its banner and a thinking one its live lines; `—` in grey
//! when there is nothing. The sort is Rust's `session_state_priority`
//! (waiting for approval, thinking, idle, exited), the grid walks
//! behind it cached per pane by output generation and 500 ms. Below
//! the cards, `EXTERNAL`: the scan's live sessions of this workspace
//! no pane here owns, at most four, `<branch>  (<short id>)`. Above
//! the cards the panel is the Zig idiom: the caps header with the
//! history, sort and refresh chips, the filter pill, a blank, the green
//! `+ New session` row (a fresh Claude Code session,
//! `ai.claude_code_new`), a blank. Enter focuses the card's pane; the
//! row menu pins, moves, renames, opens the transcript, copies the id,
//! deletes the transcript after a confirm.
//!
//! // changed (card-preview): a banner row is a picture, not a
//! sentence — Claude's orange figure is drawn half from block glyphs
//! and half from cells that carry only a background — so a line read
//! off the grid carries its cells' colours (`CellColor`, `CardLine`)
//! and `paintRow` paints it run by run in them, resolved through
//! `pty_view.colorOf`, the same path `drawPty` takes. A cell whose
//! colour is the terminal's default keeps the card's own ground and
//! muted ink; a row the card synthesized has no cells behind it and
//! paints flat, as it always did.
//!
//! Ended sessions — an exited pane past `ui.session_ended_grace_min`,
//! and the scan's ended transcripts of this workspace — hide behind the
//! header's history chip, which reads their count; a click (or `E`)
//! lists them greyed under an `ENDED` group at the bottom, right-click
//! offers show / hide / clear. One that ended inside the grace window
//! stays put (a card, or an ENDED row) so its toast and worktree offer
//! are not lost. The toggle rides in the session file.
//!
//! The `sort:` chip is SESSIONS' own axis — State (approval-shaped
//! first, then live, tool, idle, ended, newest within) or Manual (the
//! order `J` / `K` build, persisted in the session file with the
//! aliases); pinned sessions lead on either. While the panel is shown
//! it rescans every `refresh_ms`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const App = app_mod.App;
const auto_refresh = @import("app/auto_refresh.zig");
const side = @import("app/side.zig");
const context_menus = @import("app/context_menus.zig");
const Key = app_mod.Key;
const key_mod = @import("core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("core/alloc.zig");
const command = @import("core/command.zig");
const CommandError = command.CommandError;
const event = @import("core/event.zig");
const Rect = @import("ui/rect.zig");
const Ui = @import("ui/context.zig");
const Theme = @import("ui/theme.zig");
const hit = @import("ui/hit.zig");
const list_panel = @import("ui/list_panel.zig");
const todos = @import("todos.zig");
const agents = @import("app/agents.zig");
const cloud_agents = @import("app/cloud_agents.zig");
const sessions_table = @import("app/sessions_table.zig");
const pty_pane_mod = @import("app/pty_pane.zig");
const cli = @import("ai/cli.zig");
const pty_pane = @import("app/pty_pane.zig");
const pty_mod = @import("pty");
const pty_view = @import("ui/pty_view.zig");
const settings = @import("app/settings.zig");
const Config = @import("config/Config.zig");
const accent_color = @import("ui/accent_color.zig");
const session_worktree = @import("app/session_worktree.zig");
const mount_pane_mod = @import("app/mount_pane.zig");

pub const Source = agents.Source;
pub const AgentState = agents.AgentState;
pub const SessionsSort = Config.SessionsSort;

/// Where a session runs.
pub const Where = enum {
    local,
    cloud,

    pub fn label(w: Where) []const u8 {
        return @tagName(w);
    }
};

/// What a cloud row carries beyond the common columns.
pub const CloudInfo = struct {
    ticket: []const u8 = "",
    flow: []const u8 = "",
    /// The runner's own word (`started`, `staged`, `shipped`, …).
    raw_state: []const u8 = "",
    task_arn: ?[]const u8 = null,
    pr_url: ?[]const u8 = null,
};

/// One session — the one row model. Slices borrow from
/// `ScanResult.arena` in flight and from `State.snapshot` once adopted.
pub const Item = struct {
    source: Source,
    where: Where = .local,
    session_id: []const u8,
    /// The workspace label the transcript carries (a basename).
    workspace: []const u8,
    cwd: ?[]const u8,
    model: ?[]const u8 = null,
    transcript_path: []const u8,
    state: AgentState,
    pid: ?u32,
    tokens: u64 = 0,
    cost_usd: f64 = 0,
    /// Unix seconds of the last transcript change.
    last_activity_s: i64,
    last_user_msg: ?[]const u8,
    last_assistant_msg: ?[]const u8,
    current_tool: ?[]const u8 = null,
    pending_tool_uses: usize = 0,
    git_branch: ?[]const u8 = null,
    /// `git status --porcelain` entries in the cwd; null = not asked,
    /// or the cwd is gone or no repository.
    dirty: ?u32 = null,
    cloud: ?CloudInfo = null,

    /// The table groups on this: the cwd, else the workspace label;
    /// every cloud row under the cloud label.
    pub fn groupKey(it: Item) []const u8 {
        if (it.where == .cloud) return it.workspace;
        return it.cwd orelse it.workspace;
    }

    /// The group's row: the cwd's basename, else the label.
    pub fn groupLabel(it: Item) []const u8 {
        if (it.where == .cloud) return it.workspace;
        if (it.cwd) |c| {
            const base = std.fs.path.basename(c);
            if (base.len > 0) return base;
        }
        return it.workspace;
    }

    /// Ended with uncommitted work in its cwd.
    pub fn dirtyEnded(it: Item) bool {
        return it.state.ended() and (it.dirty orelse 0) > 0;
    }
};

/// Every slice of `it` copied onto `arena`.
pub fn dupeItem(arena: Allocator, it: Item) Allocator.Error!Item {
    var out = it;
    out.session_id = try arena.dupe(u8, it.session_id);
    out.workspace = try arena.dupe(u8, it.workspace);
    out.cwd = if (it.cwd) |c| try arena.dupe(u8, c) else null;
    out.model = if (it.model) |m| try arena.dupe(u8, m) else null;
    out.transcript_path = try arena.dupe(u8, it.transcript_path);
    out.last_user_msg = if (it.last_user_msg) |m| try arena.dupe(u8, m) else null;
    out.last_assistant_msg = if (it.last_assistant_msg) |m| try arena.dupe(u8, m) else null;
    out.current_tool = if (it.current_tool) |c| try arena.dupe(u8, c) else null;
    out.git_branch = if (it.git_branch) |b| try arena.dupe(u8, b) else null;
    if (it.cloud) |c| out.cloud = .{
        .ticket = try arena.dupe(u8, c.ticket),
        .flow = try arena.dupe(u8, c.flow),
        .raw_state = try arena.dupe(u8, c.raw_state),
        .task_arn = if (c.task_arn) |a| try arena.dupe(u8, a) else null,
        .pr_url = if (c.pr_url) |u| try arena.dupe(u8, u) else null,
    };
    return out;
}

/// A bare local Claude row for tests (`transcript_path` `/t`).
pub fn testItem(id: []const u8, state: AgentState, at: i64, ws: []const u8, msg: ?[]const u8) Item {
    return .{ .source = .claude, .session_id = id, .workspace = ws, .cwd = null, .transcript_path = "/t", .state = state, .pid = null, .last_activity_s = at, .last_user_msg = msg, .last_assistant_msg = null };
}

/// What `paintRow` sees: the card's view of its pane, resolved on the
/// frame arena — the name (against the aliases), the pin, whether the
/// pane is the active one, the summary rows and the ticket chip. `item`
/// is the scan's row for the pane's session id, or a stand-in.
pub const RowView = struct {
    item: Item,
    /// The pane the card is; null in a painter-only fixture.
    pane: ?app_mod.PaneId = null,
    name: []const u8,
    pinned: bool = false,
    active: bool = false,
    /// `exited` alone, the last exchange, or `—`. A row read off the
    /// pane's grid carries that grid's colours (`CardLine.colors`).
    lines: []const CardLine = &.{},
    kind: Summary = .none,
    ticket: ?[]const u8 = null,
    /// // changed (colors): the accent's palette name — the user's pick
    /// for the session, else its open pane's; null paints the cursor /
    /// active cue.
    color: ?[]const u8 = null,
    /// // changed (sessions-worktree): the session worktree's name — the
    /// `⑂ <name>` tag after the label.
    worktree: ?[]const u8 = null,
};

pub const Summary = enum { exited, none, text };

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    generation: u32,
    /// Wall-clock seconds when the scan ran — the clock `last_activity_s`
    /// is on. `App.now_ms` is the awake clock, so an age or the
    /// hidden-ended rule must not read it (`wallNowS`).
    at_s: i64 = 0,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*ScanResult {
        const r = try gpa.create(ScanResult);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *ScanResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Panel = list_panel.ListPanel(RowView);

pub const table = .{
    .@"sessions.refresh" = &refreshCmd,
    .@"sessions.sort" = &sortCmd,
    .@"sessions.sort_auto" = &sortAutoCmd,
    .@"sessions.sort_manual" = &sortManualCmd,
    .@"sessions.cycle_state" = &cycleStateCmd,
    .@"sessions.open" = &openCmd,
    .@"sessions.open_transcript" = &openTranscriptCmd,
    .@"sessions.rename" = &renameCmd,
    .@"sessions.copy_id" = &copyIdCmd,
    .@"sessions.delete" = &deleteCmd,
    .@"sessions.move_up" = &moveUpCmd,
    .@"sessions.move_down" = &moveDownCmd,
    .@"sessions.move_top" = &moveTopCmd,
    .@"sessions.move_bottom" = &moveBottomCmd,
    .@"sessions.all_workspaces" = &allWorkspacesCmd,
    .@"sessions.pin" = &pinCmd,
    .@"sessions.copy_cwd" = &copyCwdCmd,
    .@"sessions.export" = &exportCmd,
    .@"sessions.kill" = &killCmd,
    .@"sessions.new_menu" = &newMenuCmd,
    .@"sessions.open_worktree_in_tree" = &openWorktreeInTreeCmd,
    .@"sessions.merge_worktree" = &mergeWorktreeCmd,
    .@"sessions.remove_worktree" = &removeWorktreeCmd,
    // sessions-card: the history chip's verbs.
    .@"sessions.toggle_ended" = &toggleEndedCmd,
    .@"sessions.clear_ended" = &clearEndedCmd,
    // The dashboard's ids keep resolving (corpus scripts name them).
    .@"agents.refresh" = &refreshCmd,
    .@"ai.dashboard.open_transcript" = &openTranscriptCmd,
    .@"ai.dashboard.yank_session_id" = &copyIdCmd,
    .@"ai.dashboard.yank_cwd" = &copyCwdCmd,
    .@"ai.dashboard.export_markdown" = &exportCmd,
    .@"ai.dashboard.kill" = &killCmd,
    .@"ai.dashboard.resume_in_pty" = &openCmd,
};

/// A shown panel rescans this often (the dashboard's cadence).
pub const refresh_ms: i64 = 3000;
const double_click_ms: i64 = 500;

pub const Alias = struct { id: []u8, name: []u8 };

/// A card: one of this app's AI pty panes. `session_id` borrows the
/// pane's argv (`--session-id` / `--resume`); `key` is what the pins,
/// the manual order, the aliases and the colours are kept under — the
/// session id, or `pane:<n>` for a pane without one (Codex).
pub const Card = struct {
    pane: app_mod.PaneId,
    session_id: ?[]const u8,
    key: []const u8,
};

/// A row of the ENDED group: an exited pane past the grace window, or
/// the scan's ended transcript (an `items` index).
pub const Ended = union(enum) { pane: app_mod.PaneId, item: u32 };

/// The colours one cell of the pane's grid was painted in. A Claude
/// session's banner is a picture — an orange figure drawn half from
/// block glyphs and half from plain spaces with an orange background —
/// so a line flattened to text loses the spaces entirely and paints the
/// glyphs in one grey. The walk keeps these beside the text and
/// `paintRow` paints the line cell by cell.
///
/// One entry per BYTE of the line, a glyph's bytes all carrying its
/// cell's colours, so every slice the walk takes of a row (the trim,
/// the spinner strip) slices the colours with it.
pub const CellColor = struct {
    fg: pty_mod.grid.Color = .default,
    bg: pty_mod.grid.Color = .default,

    pub fn eql(a: CellColor, b: CellColor) bool {
        return std.meta.eql(a.fg, b.fg) and std.meta.eql(a.bg, b.bg);
    }

    /// Nothing to paint differently: the card's own ground and ink.
    pub fn isPlain(c: CellColor) bool {
        return std.meta.activeTag(c.fg) == .default and std.meta.activeTag(c.bg) == .default;
    }
};

/// One summary row of a card: the text, and — for a row read off the
/// pane's grid — the colours its cells carried. A row the card
/// synthesizes (`exited`, the transcript's exchange, `—`) has no cells
/// behind it, so `colors` is empty and the row paints as flat text.
pub const CardLine = struct {
    text: []const u8,
    colors: []const CellColor = &.{},

    /// The colours are usable only when there is one per byte.
    pub fn colored(self: CardLine) bool {
        return self.colors.len == self.text.len and self.text.len > 0;
    }
};

/// What one grid walk of a pane yields (Rust's `derived_cache`): the
/// last content lines most-recent-first (`summarizeGridLines`), whether
/// Claude / Codex is thinking, the one-line summary the waiting
/// heuristic reads, and the sort priority derived from them. Keyed by
/// `PtyPane.fed_gen`; the priority is re-read every `prio_ttl_ms`.
pub const Derived = struct {
    gen: u64,
    at_ms: i64,
    prio: u8,
    thinking: bool,
    /// Owned by the gpa, most-recent-first, up to `grid_lines_max`.
    /// The card outlives the frame, so the bytes AND the colours are
    /// the cache's own — never the frame arena's, never the grid's.
    lines: []CardLine = &.{},
    summary: ?[]u8 = null,

    fn deinit(self: *Derived, gpa: Allocator) void {
        for (self.lines) |l| {
            gpa.free(l.text);
            gpa.free(l.colors);
        }
        gpa.free(self.lines);
        if (self.summary) |m| gpa.free(m);
        self.* = undefined;
    }
};

/// Rust's 500 ms priority cache and its 2 s transcript cache (the
/// transcript here is the scan's, on its own cadence — `refresh_ms`).
pub const prio_ttl_ms: i64 = 500;
/// Grid lines kept per pane: the card shows three, the tooltip six.
pub const grid_lines_max: usize = 6;
/// EXTERNAL rows painted at most (Rust `external.iter().take(4)`).
pub const external_max: usize = 4;

pub const State = struct {
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    items: []Item = &.{},
    filtered: std.ArrayListUnmanaged(u32) = .empty,
    list: Panel.State = .{},
    sort: SessionsSort = .auto,
    /// Null = every state.
    state_filter: ?AgentState = null,
    /// Every workspace's sessions, not just this one's.
    all_workspaces: bool = false,
    /// Manual order: session ids, first on top. Owned.
    order: std.ArrayListUnmanaged([]u8) = .empty,
    /// Display names by session id. Owned.
    aliases: std.ArrayListUnmanaged(Alias) = .empty,
    /// Pinned session ids, in memory for this launch (as Rust's). Owned.
    pinned: std.ArrayListUnmanaged([]u8) = .empty,
    /// // changed (colors): accent colours by session id (`name` is the
    /// palette name), saved with the session file. Owned.
    colors: std.ArrayListUnmanaged(Alias) = .empty,
    /// // changed (sessions-worktree): the trees mnml made for sessions,
    /// by path, the session id learned from the scan; saved with the
    /// session file (`app/session_worktree.zig`). Owned.
    worktrees: session_worktree.Registry = .{},
    generation: u32 = 0,
    scanning: bool = false,
    scanned_once: bool = false,
    last_scan_ms: i64 = 0,
    last_click: ?struct { idx: u32, at_ms: i64 } = null,
    /// A home directory to scan instead of the loader's `$HOME` —
    /// what a test points at a fixture. Owned.
    home: ?[]u8 = null,
    /// The cloud scanner's settings, duped from the config for the
    /// worker in flight (`refresh` renews them). Owned.
    cloud: ?cloud_agents.Opts = null,
    /// The first adoption has no edges to report.
    adopted_once: bool = false,
    /// The snapshot's wall clock and the awake clock it was adopted at:
    /// `wallNowS` extrapolates the wall clock from the two.
    snapshot_at_s: i64 = 0,
    snapshot_at_ms: i64 = 0,
    /// // changed (sessions-card): the cards, rebuilt by `refilter`
    /// (every frame — a pane can open, exit or close between scans);
    /// `filtered` indexes them. The `pane:<n>` keys live on `keys`.
    cards: std.ArrayListUnmanaged(Card) = .empty,
    keys: std.heap.ArenaAllocator,
    /// EXTERNAL: `items` indices, the scan's live sessions of this
    /// workspace no pane owns, newest first.
    external: std.ArrayListUnmanaged(u32) = .empty,
    /// ENDED: what the group lists this frame.
    ended: std.ArrayListUnmanaged(Ended) = .empty,
    /// How many ended sessions the chip hides.
    hidden_ended: usize = 0,
    /// The chip's toggle — the session file keeps it.
    show_ended: bool = false,
    /// Ended session ids the user cleared, forgotten until the next
    /// launch. Owned.
    cleared: std.ArrayListUnmanaged([]u8) = .empty,
    /// The grid walk per pane (`derive`).
    derived: std.AutoHashMapUnmanaged(app_mod.PaneId, Derived) = .empty,
    /// Counters the tests read: grid walks, and priority evaluations.
    grid_walks: u64 = 0,
    prio_evals: u64 = 0,

    pub fn init(gpa: Allocator, sort: SessionsSort) State {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .sort = sort, .keys = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        self.cards.deinit(gpa);
        self.keys.deinit();
        self.external.deinit(gpa);
        self.ended.deinit(gpa);
        for (self.cleared.items) |id| gpa.free(id);
        self.cleared.deinit(gpa);
        var it = self.derived.valueIterator();
        while (it.next()) |d| d.deinit(gpa);
        self.derived.deinit(gpa);
        for (self.order.items) |id| gpa.free(id);
        self.order.deinit(gpa);
        for (self.aliases.items) |a| {
            gpa.free(a.id);
            gpa.free(a.name);
        }
        self.aliases.deinit(gpa);
        for (self.pinned.items) |id| gpa.free(id);
        self.pinned.deinit(gpa);
        for (self.colors.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
        }
        self.colors.deinit(gpa);
        self.worktrees.deinit(gpa);
        if (self.home) |h| gpa.free(h);
        if (self.cloud) |*c| c.deinit(gpa);
        self.filtered.deinit(gpa);
        self.list.deinit(gpa);
        self.snapshot.deinit();
    }

    /// The card under the cursor.
    pub fn selectedCard(self: *const State) ?Card {
        if (self.list.cursor >= self.filtered.items.len) return null;
        return self.cards.items[self.filtered.items[self.list.cursor]];
    }

    /// The scan's row for `id`.
    pub fn itemOf(self: *const State, id: []const u8) ?Item {
        for (self.items) |it| if (std.mem.eql(u8, it.session_id, id)) return it;
        return null;
    }

    pub fn isCleared(self: *const State, id: []const u8) bool {
        for (self.cleared.items) |c| if (std.mem.eql(u8, c, id)) return true;
        return false;
    }

    pub fn alias(self: *const State, id: []const u8) ?[]const u8 {
        for (self.aliases.items) |a| if (std.mem.eql(u8, a.id, id)) return a.name;
        return null;
    }

    /// Set, replace, or (empty name) drop the alias for `id`.
    pub fn setAlias(self: *State, gpa: Allocator, id: []const u8, name: []const u8) Allocator.Error!void {
        for (self.aliases.items, 0..) |*a, i| if (std.mem.eql(u8, a.id, id)) {
            if (name.len == 0) {
                const gone = self.aliases.orderedRemove(i);
                gpa.free(gone.id);
                gpa.free(gone.name);
                return;
            }
            const fresh = try gpa.dupe(u8, name);
            gpa.free(a.name);
            a.name = fresh;
            return;
        };
        if (name.len == 0) return;
        const id_owned = try gpa.dupe(u8, id);
        errdefer gpa.free(id_owned);
        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        try self.aliases.append(gpa, .{ .id = id_owned, .name = name_owned });
    }

    /// The accent chosen for `id`, a palette name.
    pub fn color(self: *const State, id: []const u8) ?[]const u8 {
        for (self.colors.items) |c| if (std.mem.eql(u8, c.id, id)) return c.name;
        return null;
    }

    /// Set, replace, or (`none` / empty / unknown) drop the colour for `id`.
    pub fn setColor(self: *State, gpa: Allocator, id: []const u8, name: []const u8) Allocator.Error!void {
        const canon = accent_color.canonical(name);
        for (self.colors.items, 0..) |*c, i| if (std.mem.eql(u8, c.id, id)) {
            if (canon == null) {
                const gone = self.colors.orderedRemove(i);
                gpa.free(gone.id);
                gpa.free(gone.name);
                return;
            }
            const fresh = try gpa.dupe(u8, canon.?);
            gpa.free(c.name);
            c.name = fresh;
            return;
        };
        const want = canon orelse return;
        const id_owned = try gpa.dupe(u8, id);
        errdefer gpa.free(id_owned);
        const name_owned = try gpa.dupe(u8, want);
        errdefer gpa.free(name_owned);
        try self.colors.append(gpa, .{ .id = id_owned, .name = name_owned });
    }

    pub fn orderIndex(self: *const State, id: []const u8) ?usize {
        for (self.order.items, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
        return null;
    }

    pub fn isPinned(self: *const State, id: []const u8) bool {
        for (self.pinned.items) |p| if (std.mem.eql(u8, p, id)) return true;
        return false;
    }

    /// Pin, or unpin; the new state.
    pub fn togglePin(self: *State, gpa: Allocator, id: []const u8) Allocator.Error!bool {
        for (self.pinned.items, 0..) |p, i| if (std.mem.eql(u8, p, id)) {
            gpa.free(self.pinned.orderedRemove(i));
            return false;
        };
        const owned = try gpa.dupe(u8, id);
        errdefer gpa.free(owned);
        try self.pinned.append(gpa, owned);
        return true;
    }
};

// ─── the scan worker (D1 + D3) ──────────────────────────────────────────

/// Cancel any scan in flight, bump the generation, start a new one over
/// the home directory. No home (the `.test` runner's apps) is an empty
/// list, not an error.
pub fn refresh(app: *App) CommandError!void {
    const st = &app.sessions;
    st.last_scan_ms = app.now_ms;
    st.scanned_once = true;
    const home = try homeFor(app) orelse {
        st.scanning = false;
        st.snapshot.reset();
        st.items = &.{};
        try refilter(app);
        return;
    };
    st.group.cancel(app.io);
    st.generation +%= 1;
    st.scanning = true;
    app.needs_render = true;
    // The cloud settings the worker reads, renewed while no worker runs.
    if (st.cloud) |*c| c.deinit(app.gpa);
    st.cloud = try cloud_agents.Opts.fromConfig(app.gpa, &app.cfg.cloud_agents, &app.env);
    st.group.concurrent(app.io, scanWorker, .{ &app.events, app.io, app.gpa, home, app.workspace, st.cloud, st.generation }) catch |err| {
        st.scanning = false;
        return app.diag.fail(app.frame.allocator(), "sessions: could not start the scan: {s}", .{@errorName(err)});
    };
}

/// `$HOME` as the config loader saw it, else as the children see it (a
/// `.test` file's `# env:` lines land there; the runner loads no file).
pub fn envHome(app: *const App) ?[]const u8 {
    return app.homeDir() orelse app.env.get("HOME");
}

/// The test override, else `$HOME`. A relative HOME — a `.test` file's
/// `# env: HOME=home` — is under the workspace, and is kept as the
/// override so the worker's slice outlives the frame.
/// // changed (codex-resume): public, because the session file's Codex
/// lookup reads the same `~/.codex` the scan does and must resolve the
/// home the same way — two spellings of "which home" is how a `.test`
/// file quietly reads the developer's real one.
pub fn homeFor(app: *App) Allocator.Error!?[]const u8 {
    const st = &app.sessions;
    if (st.home) |h| return h;
    const h = envHome(app) orelse return null;
    if (std.fs.path.isAbsolute(h)) return h;
    st.home = try std.fs.path.join(app.gpa, &.{ app.workspace, h });
    return st.home.?;
}

fn scanWorker(events: *event.EventQueue, io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, cloud: ?cloud_agents.Opts, generation: u32) Io.Cancelable!void {
    const result = ScanResult.create(gpa, generation) catch {
        postErr(events, io, gpa, "out of memory starting the scan");
        return;
    };
    errdefer result.destroy(gpa);
    scanInto(io, gpa, home, workspace, cloud, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => {
            postErr(events, io, gpa, "out of memory during the scan");
            return;
        },
    };
    events.post(io, .{ .sessions = result });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .sessions, .msg = owned } });
}

const ScanError = Io.Cancelable || Allocator.Error;

/// The three scanners into `r.items` on `r.arena`: the local
/// transcripts, the cloud runs when configured, then one `git status`
/// per distinct cwd. Every session is kept; `refilter` narrows to the
/// workspace, so the toggle needs no rescan.
pub fn scanInto(io: Io, gpa: Allocator, home: []const u8, workspace: []const u8, cloud: ?cloud_agents.Opts, r: *ScanResult) ScanError!void {
    _ = workspace;
    const arena = r.arena.allocator();
    var rows: std.ArrayListUnmanaged(Item) = .empty;
    try agents.scanInto(io, gpa, arena, home, &rows);
    if (cloud) |c| try cloud_agents.scanInto(io, gpa, arena, c, &rows);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    try agents.dirtyScan(io, gpa, arena, rows.items, now);
    r.items = rows.items;
    r.at_s = now;
}

// ─── the event handler (D1) ─────────────────────────────────────────────

pub fn handle(app: *App, result: *ScanResult) Allocator.Error!void {
    const st = &app.sessions;
    defer result.destroy(app.gpa);
    if (result.generation != st.generation) return;
    st.scanning = false;
    const frame = app.frame.allocator();
    const keep: ?[]const u8 = if (st.selectedCard()) |c| try frame.dupe(u8, c.key) else null;
    try sessions_table.noteSelection(app);
    // The edges: what each session was, before the old snapshot goes.
    const edges = try stateEdges(frame, st.items, result.items);
    st.snapshot.reset();
    st.items = &.{};
    st.snapshot_at_s = result.at_s;
    st.snapshot_at_ms = app.now_ms;
    const arena = st.snapshot.allocator();
    const items = try arena.alloc(Item, result.items.len);
    for (result.items, 0..) |it, i| items[i] = try dupeItem(arena, it);
    st.items = items;
    // A session listed on one of the worktrees takes the tree's row.
    for (st.items) |it| _ = try st.worktrees.learn(app.gpa, it.session_id, it.cwd);
    try refilter(app);
    // The selection follows its card across a rescan.
    if (keep) |key| selectKey(app, key);
    if (st.adopted_once) try announceEdges(app, edges);
    st.adopted_once = true;
    try sessions_table.onSnapshot(app);
    // A mounted pane that dispatched a session hears what it is doing:
    // its `[ Triage ]` turns a spinner while it runs, says so when it
    // stops to ask something, and becomes `[ view ]` when it ends.
    mount_pane_mod.notifySessionWatches(app);
    app.needs_render = true;
}

pub const Edge = struct { session_id: []const u8, from: AgentState, to: AgentState };

/// The sessions whose state changed between two listings (a session
/// new to the listing is no edge). Slices borrow `new`.
pub fn stateEdges(arena: Allocator, old: []const Item, new: []const Item) Allocator.Error![]Edge {
    var out: std.ArrayListUnmanaged(Edge) = .empty;
    for (new) |n| for (old) |o| if (std.mem.eql(u8, o.session_id, n.session_id)) {
        if (o.state != n.state) try out.append(arena, .{ .session_id = n.session_id, .from = o.state, .to = n.state });
        break;
    };
    return out.items;
}

/// Once per edge: a session that starts `waiting` toasts (warn), badges
/// its pty tab and rings the bell under `ui.session_bell`; one that
/// `failed` toasts (err). The other edges are quiet — the rows show them.
fn announceEdges(app: *App, edges: []const Edge) Allocator.Error!void {
    for (edges) |e| {
        const it = findItem(app, e.session_id) orelse continue;
        switch (e.to) {
            .waiting => {
                try app.toastLevel(.warn, "session needs input: {s}", .{displayName(app, it)});
                if (ptyPaneOf(app, e.session_id)) |id| if (app.panes.get(id)) |pane| if (pane.* == .pty) {
                    pane.pty.attention = true;
                };
                if (app.cfg.ui.session_bell) app.bell_pending = true;
            },
            .failed => try app.toastLevel(.err, "session failed: {s}", .{displayName(app, it)}),
            else => {},
        }
        if (e.to.ended() and !e.from.ended()) try announceWorktreeEnded(app, it);
    }
}

/// A session that ends with its worktree still there says so once:
/// the commits waiting on the branch, and where the verbs are.
fn announceWorktreeEnded(app: *App, it: Item) Allocator.Error!void {
    const e = worktreeOf(app, it) orelse return;
    if (!session_worktree.exists(app.io, e.path)) return;
    const arena = app.frame.allocator();
    const name = try arena.dupe(u8, e.name);
    const n = session_worktree.commitsAhead(app, arena, e.repo, e.branch) catch null;
    if (n) |count| {
        try app.toastLevel(.warn, "session {s} ended — its worktree {s} has {d} commit{s}: merge / remove / keep (row menu)", .{ displayName(app, it), name, count, if (count == 1) "" else "s" });
    } else {
        try app.toastLevel(.warn, "session {s} ended — its worktree {s} is still there: merge / remove / keep (row menu)", .{ displayName(app, it), name });
    }
}

/// The worktree mnml made for this session, if any: by its id, else
/// by its cwd (`app/session_worktree.zig`).
pub fn worktreeOf(app: *App, it: Item) ?*const session_worktree.Entry {
    if (it.where == .cloud) return null;
    return app.sessions.worktrees.of(it.session_id, it.cwd);
}

/// Wall-clock seconds now, the clock `Item.last_activity_s` is on: the
/// snapshot's, moved on by the awake clock since. `App.now_ms` alone is
/// the awake clock — seconds since boot — and reads every session as
/// `now` (// changed: the table's age column and hidden-ended rule
/// compared the two clocks and hid nothing).
pub fn wallNowS(app: *App) i64 {
    const st = &app.sessions;
    return st.snapshot_at_s + @divFloor(app.now_ms - st.snapshot_at_ms, 1000);
}

pub fn findItem(app: *App, session_id: []const u8) ?Item {
    for (app.sessions.items) |it| if (std.mem.eql(u8, it.session_id, session_id)) return it;
    return null;
}

/// Rust's `session_state_priority`: 0 = action needed (the pane's
/// summary mentions an approval), 1 = thinking, 2 = idle, 3 = exited,
/// 4 = no such pane.
pub fn priority(app: *App, pid: app_mod.PaneId) u8 {
    const p = app.panes.pty(pid) orelse return 4;
    if (p.exit != null) return 3;
    const d = derive(app, pid) orelse return 4;
    return d.prio;
}

/// The card's state for the `f` filter and the stand-in row: the exit
/// (ok → `done`, else `failed`), else the priority's state.
pub fn cardState(app: *App, card: Card) AgentState {
    const p = app.panes.pty(card.pane) orelse return .done;
    if (p.exit) |e| return if (e.ok()) .done else .failed;
    return switch (priority(app, card.pane)) {
        0 => .waiting,
        1 => .streaming,
        else => .idle,
    };
}

/// // changed (sessions-card): the cards are this app's AI panes; the
/// scan's rows sort into EXTERNAL (live, this workspace's, unowned) or
/// ENDED (hidden behind the chip past the grace window). Then the
/// state filter and the `/` text narrow the cards, pinned cards lead,
/// and the axis orders: State (the priority), or the manual list (keys
/// not on it follow, by pane order).
pub fn refilter(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    const gpa = app.gpa;
    st.cards.clearRetainingCapacity();
    _ = st.keys.reset(.retain_capacity);
    st.external.clearRetainingCapacity();
    st.ended.clearRetainingCapacity();
    st.filtered.clearRetainingCapacity();
    st.hidden_ended = 0;
    const grace_ms: i64 = @as(i64, app.cfg.ui.session_ended_grace_min) * 60_000;
    // Every AI pane: a card, or — exited past the grace — an ENDED row
    // or a hidden one. Every pane's id counts as owned either way.
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer owned.deinit(gpa);
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| {
            if (pty_pane.productOf(app, p) == null) continue;
            const pid: app_mod.PaneId = @intCast(i);
            const sid = p.sessionId();
            if (sid) |id| try owned.append(gpa, id);
            if (p.exit != null) {
                const since = app.now_ms - (p.exited_at_ms orelse app.now_ms);
                if (since > grace_ms) {
                    if (st.show_ended) try st.ended.append(gpa, .{ .pane = pid }) else st.hidden_ended += 1;
                    continue;
                }
            }
            const key = sid orelse try std.fmt.allocPrint(st.keys.allocator(), "pane:{d}", .{pid});
            try st.cards.append(gpa, .{ .pane = pid, .session_id = sid, .key = key });
        },
        else => {},
    };
    // Prune the derived cache of panes that are gone.
    var gone: std.ArrayListUnmanaged(app_mod.PaneId) = .empty;
    defer gone.deinit(gpa);
    var dit = st.derived.iterator();
    while (dit.next()) |e| if (app.panes.pty(e.key_ptr.*) == null) try gone.append(gpa, e.key_ptr.*);
    for (gone.items) |pid| if (st.derived.fetchRemove(pid)) |kv| {
        var d = kv.value;
        d.deinit(gpa);
    };
    // The scan's rows.
    const q = st.list.filterText();
    const ws_name = std.fs.path.basename(app.workspace);
    const now_s = wallNowS(app);
    const grace_s: i64 = @as(i64, app.cfg.ui.session_ended_grace_min) * 60;
    for (st.items, 0..) |it, i| {
        if (st.isCleared(it.session_id)) continue;
        if (!st.all_workspaces and !inWorkspaceOrTree(app, it, app.workspace, ws_name)) continue;
        var is_owned = false;
        for (owned.items) |id| if (std.mem.eql(u8, id, it.session_id)) {
            is_owned = true;
            break;
        };
        if (is_owned) continue;
        if (st.state_filter) |sf| if (it.state != sf) continue;
        if (q.len > 0 and !matches(app, it, q)) continue;
        if (it.state.ended()) {
            const within = now_s - it.last_activity_s <= grace_s;
            if (within or st.show_ended) try st.ended.append(gpa, .{ .item = @intCast(i) }) else st.hidden_ended += 1;
        } else try st.external.append(gpa, @intCast(i));
    }
    // The cards through the filters.
    for (st.cards.items, 0..) |c, i| {
        if (st.state_filter) |sf| if (cardState(app, c) != sf) continue;
        if (q.len > 0 and !cardMatches(app, c, q)) continue;
        try st.filtered.append(gpa, @intCast(i));
    }
    const Ctx = struct {
        app: *App,
        fn lt(ctx: @This(), a: u32, b: u32) bool {
            const st_ = &ctx.app.sessions;
            const ca = st_.cards.items[a];
            const cb = st_.cards.items[b];
            const pa = st_.isPinned(ca.key);
            const pb = st_.isPinned(cb.key);
            if (pa != pb) return pa;
            switch (st_.sort) {
                .auto => {
                    const ra = priority(ctx.app, ca.pane);
                    const rb = priority(ctx.app, cb.pane);
                    if (ra != rb) return ra < rb;
                },
                .manual => {
                    const oa = st_.orderIndex(ca.key);
                    const ob = st_.orderIndex(cb.key);
                    if (oa != null and ob != null) return oa.? < ob.?;
                    if (oa != null) return true;
                    if (ob != null) return false;
                },
            }
            return ca.pane < cb.pane;
        }
    };
    std.mem.sort(u32, st.filtered.items, Ctx{ .app = app }, Ctx.lt);
    if (st.list.cursor >= st.filtered.items.len) st.list.cursor = st.filtered.items.len -| 1;
}

/// Put the cursor on the card keyed `key`, when it is listed.
pub fn selectKey(app: *App, key: []const u8) void {
    const st = &app.sessions;
    for (st.filtered.items, 0..) |idx, vi| if (std.mem.eql(u8, st.cards.items[idx].key, key)) {
        st.list.cursor = vi;
        return;
    };
}

/// Rust's `session_matches_filter`: the display name, the label, the
/// branch, the cwd's basename, the ticket — and the session id.
fn cardMatches(app: *App, c: Card, q: []const u8) bool {
    const p = app.panes.pty(c.pane) orelse return false;
    if (todos.containsIgnoreCase(cardName(app, c), q)) return true;
    if (todos.containsIgnoreCase(p.label, q)) return true;
    if (cardBranch(app, c)) |b| if (todos.containsIgnoreCase(b, q)) return true;
    if (todos.containsIgnoreCase(std.fs.path.basename(cardCwd(app, p)), q)) return true;
    if (c.session_id) |sid| if (todos.containsIgnoreCase(sid, q)) return true;
    if (detectTicket(app.cfg.ui.ticket_prefixes, &.{ cardName(app, c), cardBranch(app, c) orelse "", p.label })) |tk| if (todos.containsIgnoreCase(tk, q)) return true;
    return false;
}

/// The pane's cwd — the workspace when it was opened with none (what
/// the pty ran in).
pub fn cardCwd(app: *App, p: *const pty_pane.PtyPane) []const u8 {
    return p.cwd orelse app.workspace;
}

/// The card's branch: the transcript's, else the worktree's.
pub fn cardBranch(app: *App, c: Card) ?[]const u8 {
    if (c.session_id) |sid| if (app.sessions.itemOf(sid)) |it| if (it.git_branch) |b| if (b.len > 0) return b;
    if (cardWorktree(app, c)) |e| return e.branch;
    return null;
}

/// The worktree mnml made for the card's session, if any.
pub fn cardWorktree(app: *App, c: Card) ?*const session_worktree.Entry {
    const p = app.panes.pty(c.pane) orelse return null;
    return app.sessions.worktrees.of(c.session_id orelse c.key, p.cwd);
}

/// Rust's `tab_label_with_prefixes` for the card: the alias the user
/// gave the session, else the child's window title with Claude's
/// spinner glyph stripped off the front, else the pane's label.
pub fn cardName(app: *App, c: Card) []const u8 {
    if (app.sessions.alias(c.key)) |a| return a;
    const p = app.panes.pty(c.pane) orelse return c.key;
    if (p.childTitle()) |t| {
        const clean = stripLeadingSpinner(t);
        if (clean.len > 0) return clean;
    }
    return p.label;
}

/// The scan's row for the card, or a stand-in carrying what the pane
/// knows (no transcript, no pid): what the row commands act on.
pub fn cardItem(app: *App, c: Card) Item {
    if (c.session_id) |sid| if (app.sessions.itemOf(sid)) |it| return it;
    const p = app.panes.pty(c.pane);
    const cwd: ?[]const u8 = if (p) |pp| cardCwd(app, pp) else null;
    return .{
        .source = if (p) |pp| (if (pty_pane.productOf(app, pp) == .codex) .codex else .claude) else .claude,
        .session_id = c.key,
        .workspace = if (cwd) |cw| std.fs.path.basename(cw) else std.fs.path.basename(app.workspace),
        .cwd = cwd,
        .transcript_path = "",
        .state = cardState(app, c),
        .pid = null,
        .last_activity_s = wallNowS(app),
        .last_user_msg = null,
        .last_assistant_msg = null,
    };
}

fn inWorkspace(it: Item, workspace: []const u8, ws_name: []const u8) bool {
    if (it.cwd) |c| if (std.mem.startsWith(u8, c, workspace)) return true;
    return std.mem.eql(u8, it.workspace, ws_name);
}

/// `inWorkspace`, or on a worktree mnml made for a session here.
fn inWorkspaceOrTree(app: *App, it: Item, workspace: []const u8, ws_name: []const u8) bool {
    if (inWorkspace(it, workspace, ws_name)) return true;
    return worktreeOf(app, it) != null;
}

fn matches(app: *App, it: Item, q: []const u8) bool {
    if (app.sessions.alias(it.session_id)) |a| if (todos.containsIgnoreCase(a, q)) return true;
    if (it.last_user_msg) |m| if (todos.containsIgnoreCase(m, q)) return true;
    return todos.containsIgnoreCase(it.session_id, q) or todos.containsIgnoreCase(it.workspace, q) or
        todos.containsIgnoreCase(it.source.label(), q) or todos.containsIgnoreCase(it.state.label(), q) or
        todos.containsIgnoreCase(it.where.label(), q);
}

/// The alias, else the last prompt, else the id's first eight characters.
pub fn displayName(app: *App, it: Item) []const u8 {
    if (app.sessions.alias(it.session_id)) |a| return a;
    if (it.last_user_msg) |m| {
        const line = std.mem.trim(u8, m, " \t\r\n");
        if (line.len > 0) return line;
    }
    return it.session_id[0..@min(it.session_id.len, 8)];
}

pub fn setSort(app: *App, sort: SessionsSort) Allocator.Error!void {
    app.sessions.sort = sort;
    try refilter(app);
    app.needs_render = true;
}

/// Whether a view of the rows is on screen and wants the cadence: the
/// section shown with auto-refresh on, or a table pane not paused.
pub fn wantsScan(app: *const App) bool {
    if (side.isShown(app, .sessions) and auto_refresh.on(app, .sessions)) return true;
    return sessions_table.wantsScan(app);
}

/// Every tick: a shown view rescans on the cadence.
pub fn tick(app: *App, now: i64) void {
    const st = &app.sessions;
    if (st.scanning or !st.scanned_once or !wantsScan(app)) return;
    if (now - st.last_scan_ms < refresh_ms) return;
    refresh(app) catch {};
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.sessions;
    if (!st.scanned_once or !wantsScan(app)) return null;
    if (st.scanning) return app.now_ms + 80;
    return st.last_scan_ms + refresh_ms;
}

// ─── commands (D2, D5) ──────────────────────────────────────────────────

fn refreshCmd(app: *App) CommandError!void {
    return refresh(app);
}

/// The chip's click: the other axis, persisted as `ui.sessions_sort`.
fn sortCmd(app: *App) CommandError!void {
    return applySort(app, switch (app.sessions.sort) {
        .auto => .manual,
        .manual => .auto,
    });
}

fn sortAutoCmd(app: *App) CommandError!void {
    return applySort(app, .auto);
}

fn sortManualCmd(app: *App) CommandError!void {
    return applySort(app, .manual);
}

fn applySort(app: *App, sort: SessionsSort) CommandError!void {
    try setSort(app, sort);
    app.cfg.ui.sessions_sort = sort;
    _ = try settings.persist(app, .workspace, &.{ "ui", "sessions_sort" }, sort);
    app.toast("sessions: {s}", .{sortLabel(sort)});
}

pub fn sortLabel(s: SessionsSort) []const u8 {
    return switch (s) {
        .auto => "State",
        .manual => "Manual",
    };
}

pub const sort_widest: usize = 6;

/// `f`: the state filter cycles every → waiting → live → tool → idle
/// → failed → done → every. The table has its own filter.
fn cycleStateCmd(app: *App) CommandError!void {
    if (sessions_table.focused(app)) |tp| return sessions_table.cycleState(app, tp);
    const st = &app.sessions;
    st.state_filter = AgentState.next(st.state_filter);
    try refilter(app);
    app.needs_render = true;
}

/// The row a session command acts on: the table's cursor when the
/// table pane has the keys, else the section's card (its scan row, or
/// the stand-in).
pub fn current(app: *App) ?Item {
    if (sessions_table.focused(app)) |tp| return tp.selectedItem(app);
    const c = app.sessions.selectedCard() orelse return null;
    return cardItem(app, c);
}

/// The section's card under the cursor, when the section has the keys.
pub fn currentCard(app: *App) ?Card {
    if (sessions_table.focused(app) != null) return null;
    return app.sessions.selectedCard();
}

/// The key a section command pins / orders / renames under: the card's,
/// else the table row's session id.
fn currentKey(app: *App) ?[]const u8 {
    if (currentCard(app)) |c| return c.key;
    return if (current(app)) |it| it.session_id else null;
}

fn currentOrFail(app: *App) CommandError!Item {
    return current(app) orelse app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
}

/// `w`: this workspace's sessions, or every workspace's.
fn allWorkspacesCmd(app: *App) CommandError!void {
    app.sessions.all_workspaces = !app.sessions.all_workspaces;
    try refilter(app);
    app.needs_render = true;
    app.toast("sessions: {s}", .{if (app.sessions.all_workspaces) "every workspace" else "this workspace"});
}

/// `p` / the menu's first row: pin or unpin the selected session;
/// pinned sessions lead the list on either axis. In memory, as Rust's.
fn pinCmd(app: *App) CommandError!void {
    const st = &app.sessions;
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const name = try arena.dupe(u8, displayName(app, it));
    const id = try arena.dupe(u8, currentKey(app) orelse it.session_id);
    const pinned = try st.togglePin(app.gpa, id);
    try refilter(app);
    selectKey(app, id);
    try sessions_table.onSnapshot(app);
    app.needs_render = true;
    app.toast("{s} {s}", .{ if (pinned) "pinned" else "unpinned", name });
}

/// The `+ New session` row (Enter, a click) and `sessions.new_menu`:
/// the choices — a local session, a batch of them, a cloud run — as a
/// menu under the row.
/// // changed (sessions-merge): was `ai.claude_code_new` outright; the
/// cloud wizards are choices here now.
fn newCmd(app: *App) CommandError!void {
    const at = newRowAnchor(app);
    return openNewMenu(app, at.x, at.y);
}

fn newMenuCmd(app: *App) CommandError!void {
    return newCmd(app);
}

/// Where the New row painted last frame, else the top-left.
fn newRowAnchor(app: *App) struct { x: u16, y: u16 } {
    for (app.hits.items.items) |h| switch (h.target) {
        .chip => |c| if (c.panel == .sessions and c.kind == .new) return .{ .x = h.rect.x, .y = h.rect.y + 1 },
        .script_hit => |sh| if (sh.id == hit.ListHit.chip(.new)) {
            if (app.panes.get(sh.pane)) |p| if (p.* == .sessions_table) return .{ .x = h.rect.x, .y = h.rect.y + 1 };
        },
        else => {},
    };
    return .{ .x = 0, .y = 1 };
}

/// Enter / double-click / the menu's Resume row: the section's card
/// focuses its pane (Rust's click on a session tab); the table resumes
/// the session in a pty pane to the right, in its own cwd. A cloud row
/// opens its run.
fn openCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (currentCard(app)) |c| {
        if (app.panes.get(c.pane) == null) return app.diag.fail(arena, "sessions: the pane is gone", .{});
        app.showPane(c.pane);
        app.focus = .{ .pane = c.pane };
        app.needs_render = true;
        return;
    }
    const it = try currentOrFail(app);
    if (it.where == .cloud) return cloud_agents.openRun(app, it);
    const argv: []const []const u8 = switch (it.source) {
        .claude => try cli.claudeResumeArgv(arena, try arena.dupe(u8, it.session_id)),
        .codex => &.{cli.codex_binary},
    };
    const cwd: ?[]const u8 = if (it.cwd) |c| try arena.dupe(u8, c) else null;
    // The session's chosen colour follows it into the pane.
    _ = try pty_pane.open(app, .{ .argv = argv, .cwd = cwd, .label = it.source.label(), .placement = .right, .kind = .command, .accent_color = app.sessions.color(it.session_id) });
}

// ─── the accent (colors) ────────────────────────────────────────────────

/// The palette name a session's surfaces paint: the user's pick for the
/// id first, else its open pane's accent (a new session's auto slot);
/// null when neither.
pub fn colorNameOf(app: *App, sid: []const u8) ?[]const u8 {
    if (app.sessions.color(sid)) |c| return c;
    const pid = ptyPaneOf(app, sid) orelse return null;
    const p = app.panes.pty(pid) orelse return null;
    return p.accent_color;
}

/// The `Color: …` rows of a session's menu (Rust's
/// `session_color_menu_items_with_active`): one per palette entry in
/// the palette's order, then `Color: Auto`, the current one checked.
/// On `arena` — the menu's own.
pub fn colorMenuRows(arena: Allocator, target: command.SessionColorAct, active: ?[]const u8) Allocator.Error![]command.MenuItem {
    const rows = try arena.alloc(command.MenuItem, accent_color.palette.len + 1);
    for (accent_color.palette, 0..) |name, i| rows[i] = .{
        .label = accent_color.label(name),
        .action = .{ .session_color = .{ .target = target.target, .name = name } },
        .checked = if (active) |c| std.mem.eql(u8, c, name) else false,
    };
    rows[accent_color.palette.len] = .{
        .label = accent_color.label(accent_color.none),
        .action = .{ .session_color = .{ .target = target.target, .name = accent_color.none } },
        .checked = active == null,
        .separator_before = true,
    };
    return rows;
}

/// A `Color: …` row was chosen: the SESSIONS row under the cursor keeps
/// the colour by its id and its open pane takes it; a pane takes it,
/// and its session id keeps it when the command names one.
pub fn setColorAction(app: *App, a: command.SessionColorAct) Allocator.Error!void {
    switch (a.target) {
        .row => {
            if (currentCard(app)) |c| {
                try app.sessions.setColor(app.gpa, c.key, a.name);
                try pty_pane.setAccent(app, c.pane, a.name);
            } else {
                const it = current(app) orelse return;
                try app.sessions.setColor(app.gpa, it.session_id, a.name);
                if (ptyPaneOf(app, it.session_id)) |pid| try pty_pane.setAccent(app, pid, a.name);
            }
        },
        .pane => |pid| {
            try pty_pane.setAccent(app, pid, a.name);
            const p = app.panes.pty(pid) orelse return;
            for (app.sessions.items) |it| for (p.argv) |arg| if (std.mem.eql(u8, arg, it.session_id)) {
                try app.sessions.setColor(app.gpa, it.session_id, a.name);
            };
        },
    }
    app.needs_render = true;
}

/// The transcript itself, in an editor.
fn openTranscriptCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    if (it.where == .cloud) return cloud_agents.tailLog(app, it);
    if (it.transcript_path.len == 0) return app.diag.fail(arena, "sessions: {s} has no transcript yet", .{displayName(app, it)});
    const path = try arena.dupe(u8, it.transcript_path);
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open transcript: {s}", .{@errorName(err)}),
    };
}

/// A prompt seeded with the current name; empty resets to the default.
fn renameCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    const key = currentKey(app) orelse it.session_id;
    const id = try app.gpa.dupe(u8, key);
    errdefer app.gpa.free(id);
    const seed = try app.frame.allocator().dupe(u8, app.sessions.alias(key) orelse "");
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Rename session (empty = reset to default)"), .purpose = .{ .sessions_rename = id } } };
    app.overlay.prompt.state.setText(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The rename prompt's accept.
pub fn acceptRename(app: *App, id: []const u8, text: []const u8) Allocator.Error!void {
    try app.sessions.setAlias(app.gpa, id, std.mem.trim(u8, text, " \t\r\n"));
    try refilter(app);
    try sessions_table.onSnapshot(app);
    app.needs_render = true;
}

/// The row menu's *Open worktree in tree*: the tree joins the file
/// tree as a workspace root and its repo becomes the active one
/// (`git_palette.openWorktree`).
fn openWorktreeInTreeCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    const e = worktreeOf(app, it) orelse return app.diag.fail(app.frame.allocator(), "sessions: {s} has no worktree", .{displayName(app, it)});
    const arena = app.frame.allocator();
    return @import("app/git_palette.zig").openWorktree(app, .{ .path = try arena.dupe(u8, e.path), .branch = try arena.dupe(u8, e.branch) });
}

/// *Merge into <branch>…*: a named confirm, then `session_worktree.merge`.
fn mergeWorktreeCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    const e = worktreeOf(app, it) orelse return app.diag.fail(app.frame.allocator(), "sessions: {s} has no worktree", .{displayName(app, it)});
    return session_worktree.confirmMerge(app, e.*);
}

/// *Remove worktree…*: a named confirm, then `session_worktree.remove`
/// (a second confirm forces past an unmerged branch).
fn removeWorktreeCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    const e = worktreeOf(app, it) orelse return app.diag.fail(app.frame.allocator(), "sessions: {s} has no worktree", .{displayName(app, it)});
    return session_worktree.confirmRemove(app, e.*, false);
}

fn copyIdCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const text = try arena.dupe(u8, it.session_id);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// `c`: the session's working directory to the clipboard.
fn copyCwdCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    const cwd = it.cwd orelse return app.diag.fail(arena, "sessions: the session has no cwd", .{});
    const text = try arena.dupe(u8, cwd);
    try app.clipboard.setYank(text, false);
    app.toast("copied {s}", .{text});
}

/// `e`: the transcript as markdown under `.mnml/claude-exports/`,
/// opened in an editor.
fn exportCmd(app: *App) CommandError!void {
    const it = try currentOrFail(app);
    if (it.where == .cloud) return app.diag.fail(app.frame.allocator(), "sessions: a cloud run has no transcript to export — tail its log", .{});
    if (it.transcript_path.len == 0) return app.diag.fail(app.frame.allocator(), "sessions: {s} has no transcript yet", .{displayName(app, it)});
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, it.transcript_path, gpa, .limited(64 * 1024 * 1024)) catch |err| return app.diag.fail(arena, "read {s}: {s}", .{ it.transcript_path, @errorName(err) });
    defer gpa.free(text);
    const md = try agents.transcriptMarkdown(arena, it, text);
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "claude-exports" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    const short = it.session_id[0..@min(8, it.session_id.len)];
    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{d}.md", .{ dir, short, app.now_ms });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = md }) catch |err| return app.diag.fail(arena, "write {s}: {s}", .{ path, @errorName(err) });
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    app.toast("exported {s}", .{app.relPath(path)});
}

/// `K`: SIGTERM the current session — or, from the table, every ticked
/// one — after a confirm. A cloud row cancels its run instead.
fn killCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var pids: std.ArrayListUnmanaged(u32) = .empty;
    if (sessions_table.focused(app)) |tp| {
        if (tp.multi.count() > 0) {
            for (app.sessions.items) |r| if (r.pid) |pid| if (tp.multi.contains(r.session_id)) try pids.append(arena, pid);
        }
    }
    if (pids.items.len == 0) {
        const it = try currentOrFail(app);
        if (it.where == .cloud) return cloud_agents.cancelRun(app, it);
        if (it.pid) |pid| try pids.append(arena, pid);
    }
    if (pids.items.len == 0) return app.diag.fail(arena, "sessions: nothing to kill (no live process)", .{});
    const owned = try app.gpa.dupe(u32, pids.items);
    errdefer app.gpa.free(owned);
    const msg = try std.fmt.allocPrint(app.gpa, "  SIGTERM {d} session{s}?", .{ owned.len, if (owned.len == 1) "" else "s" });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Kill sessions", .message = msg, .choices = &kill_choices },
        .purpose = .{ .kill_pids = owned },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const kill_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'k', .label = "Kill" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's yes: `kill -TERM` each pid, the ticks cleared, a rescan.
pub fn killAccept(app: *App, pids: []const u32) Allocator.Error!void {
    var n: usize = 0;
    for (pids) |pid| {
        const arg = try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{pid});
        const result = std.process.run(app.gpa, app.io, .{ .argv = &.{ "kill", "-TERM", arg } }) catch continue;
        app.gpa.free(result.stdout);
        app.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) n += 1;
    }
    app.toast("sent SIGTERM to {d} of {d}", .{ n, pids.len });
    sessions_table.clearAllMulti(app);
    refresh(app) catch {};
}

/// Delete the transcript after a confirm. A live session is refused:
/// its process would keep writing to a file that is gone.
fn deleteCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const it = try currentOrFail(app);
    if (it.where == .cloud) return app.diag.fail(arena, "sessions: a cloud run has no transcript here — cancel it instead", .{});
    if (it.transcript_path.len == 0) return app.diag.fail(arena, "sessions: {s} has no transcript yet", .{displayName(app, it)});
    if (it.pid != null) return app.diag.fail(arena, "sessions: {s} is running — end it first", .{displayName(app, it)});
    if (currentCard(app)) |c| if (app.panes.pty(c.pane)) |p| if (p.exit == null) return app.diag.fail(arena, "sessions: {s} is running — end it first", .{displayName(app, it)});
    const path = try app.gpa.dupe(u8, it.transcript_path);
    errdefer app.gpa.free(path);
    const msg = try std.fmt.allocPrint(app.gpa, "  Delete the transcript of {s}?", .{displayName(app, it)});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Delete session", .message = msg, .choices = &delete_choices },
        .purpose = .{ .delete_session = path },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's accept: the file goes, the alias and the manual slot
/// with it, and the panel rescans.
pub fn acceptDelete(app: *App, path: []const u8) Allocator.Error!void {
    Io.Dir.cwd().deleteFile(app.io, path) catch |err| {
        app.toast("delete {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    const st = &app.sessions;
    for (st.items) |it| if (std.mem.eql(u8, it.transcript_path, path)) {
        try st.setAlias(app.gpa, it.session_id, "");
        if (st.orderIndex(it.session_id)) |i| app.gpa.free(st.order.orderedRemove(i));
        break;
    };
    app.toast("deleted {s}", .{std.fs.path.basename(path)});
    refresh(app) catch {};
}

/// `E` / the history chip's click: list the ended sessions under
/// ENDED, or hide them again; the toggle rides in the session file.
fn toggleEndedCmd(app: *App) CommandError!void {
    if (sessions_table.focused(app) != null) return command.run(app, .{ .static = .@"sessions.show_ended" });
    const st = &app.sessions;
    st.show_ended = !st.show_ended;
    try refilter(app);
    app.needs_render = true;
    app.toast("sessions: ended {s}", .{if (st.show_ended) "shown" else "hidden"});
}

/// The chip menu's *Clear ended*: the ended rows of the scan are
/// forgotten until the next launch, and the exited panes past the
/// grace window close.
fn clearEndedCmd(app: *App) CommandError!void {
    const st = &app.sessions;
    const arena = app.frame.allocator();
    var n: usize = 0;
    const ws_name = std.fs.path.basename(app.workspace);
    for (st.items) |it| {
        if (!it.state.ended() or st.isCleared(it.session_id)) continue;
        if (!st.all_workspaces and !inWorkspaceOrTree(app, it, app.workspace, ws_name)) continue;
        if (ptyPaneOf(app, it.session_id) != null) continue;
        const owned = try app.gpa.dupe(u8, it.session_id);
        errdefer app.gpa.free(owned);
        try st.cleared.append(app.gpa, owned);
        n += 1;
    }
    // Exited panes past the grace: closed, as their card would have been.
    const grace_ms: i64 = @as(i64, app.cfg.ui.session_ended_grace_min) * 60_000;
    var doomed: std.ArrayListUnmanaged(app_mod.PaneId) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| if (p.exit != null and pty_pane.productOf(app, p) != null and app.now_ms - (p.exited_at_ms orelse app.now_ms) > grace_ms) try doomed.append(arena, @intCast(i)),
        else => {},
    };
    for (doomed.items) |pid| {
        try app.forceClosePane(pid);
        n += 1;
    }
    try refilter(app);
    app.needs_render = true;
    app.toast("sessions: cleared {d} ended", .{n});
}

/// `J` / `K`: move the selected row in the manual order. The visible
/// order is adopted as the manual list first, so the first move from
/// the State axis keeps everything else where it was.
fn moveUpCmd(app: *App) CommandError!void {
    return moveBy(app, -1);
}

fn moveDownCmd(app: *App) CommandError!void {
    return moveBy(app, 1);
}

fn moveBy(app: *App, delta: i32) CommandError!void {
    const st = &app.sessions;
    if (st.filtered.items.len == 0) return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    try adoptVisibleOrder(app);
    const cur: i32 = @intCast(st.list.cursor);
    const target = cur + delta;
    if (target < 0 or target >= @as(i32, @intCast(st.filtered.items.len))) return;
    const a = st.cards.items[st.filtered.items[@intCast(cur)]].key;
    const b = st.cards.items[st.filtered.items[@intCast(target)]].key;
    const ia = st.orderIndex(a).?;
    const ib = st.orderIndex(b).?;
    std.mem.swap([]u8, &st.order.items[ia], &st.order.items[ib]);
    try adoptManualAxis(app);
    try refilter(app);
    st.list.cursor = @intCast(target);
    app.needs_render = true;
}

/// The row menu's Move to top / Move to bottom (Rust's
/// `SessionMoveToTop` / `SessionMoveToBottom`): the selected row leads,
/// or ends, the manual order — pins still lead the list.
fn moveTopCmd(app: *App) CommandError!void {
    return moveTo(app, .top);
}

fn moveBottomCmd(app: *App) CommandError!void {
    return moveTo(app, .bottom);
}

fn moveTo(app: *App, end: enum { top, bottom }) CommandError!void {
    const st = &app.sessions;
    if (st.filtered.items.len == 0) return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    try adoptVisibleOrder(app);
    const id = st.cards.items[st.filtered.items[st.list.cursor]].key;
    const owned = st.order.orderedRemove(st.orderIndex(id).?);
    errdefer app.gpa.free(owned);
    switch (end) {
        .top => try st.order.insert(app.gpa, 0, owned),
        .bottom => try st.order.append(app.gpa, owned),
    }
    try adoptManualAxis(app);
    try refilter(app);
    selectKey(app, owned);
    app.needs_render = true;
}

/// A move lands on the manual axis; the switch persists like the chip's.
fn adoptManualAxis(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    if (st.sort == .manual) return;
    st.sort = .manual;
    app.cfg.ui.sessions_sort = .manual;
    _ = try settings.persist(app, .workspace, &.{ "ui", "sessions_sort" }, SessionsSort.manual);
}

/// Every visible id joins the manual list, in the order shown, after
/// what is already on it.
fn adoptVisibleOrder(app: *App) Allocator.Error!void {
    const st = &app.sessions;
    for (st.filtered.items) |idx| {
        const id = st.cards.items[idx].key;
        if (st.orderIndex(id) != null) continue;
        const owned = try app.gpa.dupe(u8, id);
        errdefer app.gpa.free(owned);
        try st.order.append(app.gpa, owned);
    }
}

// ─── keys ───────────────────────────────────────────────────────────────

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.sessions;
    switch (try Panel.handleKey(&st.list, app.gpa, k)) {
        .consumed => return true,
        .filter_changed => {
            try refilter(app);
            return true;
        },
        .activate => |i| {
            st.list.cursor = i;
            runToast(app, openCmd(app));
            return true;
        },
        .new_activate => {
            runToast(app, newCmd(app));
            return true;
        },
        .ignored => {},
    }
    if (st.list.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'r' => runToast(app, refresh(app)),
                's' => runToast(app, sortCmd(app)),
                'p' => runToast(app, pinCmd(app)),
                'f' => runToast(app, cycleStateCmd(app)),
                'w' => runToast(app, allWorkspacesCmd(app)),
                'o' => runToast(app, openTranscriptCmd(app)),
                'R' => runToast(app, renameCmd(app)),
                'y' => runToast(app, copyIdCmd(app)),
                'c' => runToast(app, copyCwdCmd(app)),
                'e' => runToast(app, exportCmd(app)),
                'S' => runToast(app, killCmd(app)),
                't' => runToast(app, sessions_table.openCmd(app)),
                'x' => runToast(app, deleteCmd(app)),
                'J' => runToast(app, moveDownCmd(app)),
                'K' => runToast(app, moveUpCmd(app)),
                'E' => runToast(app, toggleEndedCmd(app)),
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("sessions: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.sessions;
    switch (m.kind) {
        .press => {
            if (idx >= st.filtered.items.len) return;
            focusPanel(app);
            st.list.cursor = idx;
            if (m.button == .right) return openRowMenu(app, m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, openCmd(app));
            }
        },
        else => {},
    }
}

/// The wheel over the list: `rows` rows (the batch, budgeted and
/// clamped by `dispatch.panelWheel`); the window follows the cursor.
pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.sessions;
    const total = st.filtered.items.len;
    st.list.cursor = if (down) @min(st.list.cursor + rows, total -| 1) else st.list.cursor -| rows;
    app.needs_render = true;
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or idx >= app.sessions.filtered.items.len) return;
    focusPanel(app);
    app.sessions.list.cursor = idx;
    try openRowMenu(app, m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, sortCmd(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .sessions, m.x, m.y) else runToast(app, refresh(app)),
        .new => try openNewMenu(app, m.x, m.y + 1),
        .view => runToast(app, sessions_table.openCmd(app)),
        .history => if (m.button == .right) try openHistoryMenu(app, m.x, m.y) else runToast(app, toggleEndedCmd(app)),
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.sessions.list.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.sessions;
    const total = st.filtered.items.len;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.list.cursor = @min(off * total / bar.h, total - 1);
        },
        else => {},
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .sessions };
    app.needs_render = true;
}

/// Rust's row menu leads with Pin, Move up / down / to top / to bottom,
/// the Auto sort tick, Rename…; the transcript rows are this module's.
/// The section's and the table's rows share it (`sessions_table` calls
/// it with `.table`; the table has no manual order, so no move rows).
/// A cloud row is titled by its run (Rust's `workspace · runId`) and
/// offers the run's links: CloudWatch when the account, region and log
/// group are configured, the PR when the record names one.
/// // right-click (#11, #15): the to-top / to-bottom / Auto sort rows
/// and the two links. Rust's colour rows tint a pty pane's card; these
/// rows are transcripts with no colour model, so there are none.
pub fn openRowMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    return openRowMenuFor(app, .section, x, y);
}

pub const MenuHost = enum { section, table };

pub fn openRowMenuFor(app: *App, host: MenuHost, x: u16, y: u16) Allocator.Error!void {
    const it = current(app);
    const card = if (host == .section) currentCard(app) else null;
    const pinned = if (currentKey(app)) |k| app.sessions.isPinned(k) else false;
    const cloud = if (it) |i| i.where == .cloud else false;
    const live = if (card) |c| (if (app.panes.pty(c.pane)) |p| p.exit == null else false) else if (it) |i| i.pid != null else false;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    try items.append(app.gpa, .{ .label = if (pinned) "Unpin" else "Pin", .action = .{ .command = .@"sessions.pin" } });
    if (host == .section) {
        try items.append(app.gpa, .{ .label = "Move up", .action = .{ .command = .@"sessions.move_up" } });
        try items.append(app.gpa, .{ .label = "Move down", .action = .{ .command = .@"sessions.move_down" } });
        try items.append(app.gpa, .{ .label = "Move to top", .action = .{ .command = .@"sessions.move_top" } });
        try items.append(app.gpa, .{ .label = "Move to bottom", .action = .{ .command = .@"sessions.move_bottom" } });
        try items.append(app.gpa, .{ .label = "Auto sort", .action = .{ .command = .@"sessions.sort_auto" }, .checked = app.sessions.sort == .auto });
    }
    try items.append(app.gpa, .{ .label = "Rename…", .action = .{ .command = .@"sessions.rename" } });
    // colors: the accent, as Rust's rail row menu offers it.
    if (it) |i| if (i.where != .cloud) try items.append(app.gpa, .{
        .label = "Color",
        .action = .none,
        .submenu = try colorMenuRows(arena, .{ .target = .row, .name = accent_color.none }, if (card) |c| cardColor(app, c) else colorNameOf(app, i.session_id)),
    });
    var title: []const u8 = "Session";
    if (cloud) {
        const i = it.?;
        title = try std.fmt.allocPrint(arena, "{s} · {s}", .{ i.workspace, i.session_id });
        try items.append(app.gpa, .{ .label = "Open run", .action = .{ .command = .@"sessions.cloud_open" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Tail log", .action = .{ .command = .@"sessions.cloud_tail" } });
        try items.append(app.gpa, .{ .label = "Copy run id", .action = .{ .command = .@"sessions.copy_id" } });
        const cfg = &app.cfg.cloud_agents;
        if (try cloud_agents.cloudwatchUrl(arena, cloud_agents.regionOf(cfg, &app.env), cfg.account_id, cfg.log_group, i.session_id)) |url| {
            try items.append(app.gpa, .{ .label = "Open CloudWatch in browser", .action = .{ .open_url = url }, .separator_before = true });
        }
        if (i.cloud) |c| if (c.pr_url) |pr| {
            try items.append(app.gpa, .{ .label = "Open PR", .action = .{ .open_url = try arena.dupe(u8, pr) } });
        };
        try items.append(app.gpa, .{ .label = "Cancel run…", .action = .{ .command = .@"sessions.cloud_cancel" }, .separator_before = true });
    } else {
        try items.append(app.gpa, .{ .label = if (card != null) "Focus session" else "Resume in a terminal", .action = .{ .command = .@"sessions.open" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Open transcript", .action = .{ .command = .@"sessions.open_transcript" } });
        try items.append(app.gpa, .{ .label = "Copy session id", .action = .{ .command = .@"sessions.copy_id" } });
        try items.append(app.gpa, .{ .label = "Copy working directory", .action = .{ .command = .@"sessions.copy_cwd" } });
        try items.append(app.gpa, .{ .label = "Export as markdown…", .action = .{ .command = .@"sessions.export" } });
        // sessions-worktree: the tree's verbs, when the session has one.
        if (it) |i| if (worktreeOf(app, i)) |e| {
            try items.append(app.gpa, .{ .label = "Open worktree in tree", .action = .{ .command = .@"sessions.open_worktree_in_tree" }, .separator_before = true });
            const into = session_worktree.currentBranch(app, arena, e.repo) catch "HEAD";
            try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Merge into {s}…", .{into}), .action = .{ .command = .@"sessions.merge_worktree" } });
            try items.append(app.gpa, .{ .label = "Remove worktree…", .action = .{ .command = .@"sessions.remove_worktree" } });
        };
        if (live and (it == null or it.?.pid != null)) try items.append(app.gpa, .{ .label = "Kill session…", .action = .{ .command = .@"sessions.kill" }, .separator_before = true });
        try items.append(app.gpa, .{ .label = "Delete transcript…", .action = .{ .command = .@"sessions.delete" }, .separator_before = !live });
    }
    if (host == .section) try items.append(app.gpa, .{ .label = "Open as a table", .action = .{ .command = .@"sessions.table" }, .separator_before = true });
    const owned = try items.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, title, owned, x, y, mem);
}

/// The `+ New session` menu: a local session, a batch (Rust's ×2 / ×4
/// / ×8), and — the cloud wizards' new home — a cloud run by ticket or
/// through the wizard. The cloud rows say when the API is not
/// configured rather than hide.
pub fn openNewMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const cloud_ok = cloud_agents.configured(&app.cfg.cloud_agents, &app.env);
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "New local session", .action = .{ .command = .@"ai.claude_code_new" } },
        .{ .label = "New session in a worktree…", .action = .{ .command = .@"ai.new_session_worktree" } },
        .{ .label = "Open ×2", .action = .{ .command = .@"ai.claude_code_new_x2" } },
        .{ .label = "Open ×4", .action = .{ .command = .@"ai.claude_code_new_x4" } },
        .{ .label = "Open ×8", .action = .{ .command = .@"ai.claude_code_new_x8" } },
        .{ .label = if (cloud_ok) "New cloud run…" else "New cloud run… (not configured)", .action = .{ .command = .@"cloud_agents.new_run" }, .separator_before = true },
        .{ .label = if (cloud_ok) "New cloud run (wizard)…" else "New cloud run (wizard)… (not configured)", .action = .{ .command = .@"cloud_agents.new_run_wizard" } },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("New session", items, x, y);
}

/// The history chip's right-click: show / hide the ended sessions, or
/// clear them.
fn openHistoryMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.sessions;
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Show ended", .action = .{ .command = .@"sessions.toggle_ended" }, .checked = st.show_ended },
        .{ .label = "Hide ended", .action = .{ .command = .@"sessions.toggle_ended" }, .checked = !st.show_ended },
        .{ .label = "Clear ended", .action = .{ .command = .@"sessions.clear_ended" }, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Ended sessions", items, x, y);
}

/// SESSIONS' own axis: the two modes name their commands directly.
fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "State", .action = .{ .command = .@"sessions.sort_auto" }, .checked = app.sessions.sort == .auto },
        .{ .label = "Manual", .action = .{ .command = .@"sessions.sort_manual" }, .checked = app.sessions.sort == .manual },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

/// Rust's card: four rows and a blank one (`sessions_panel.rs`, `TAB_H`).
pub const card_h: u16 = 4;
pub const card_gap: u16 = 1;
pub const new_label = "+ New session";
/// The menu's first row — what Rust's chip runs outright.
pub const new_command: command.CommandId = .@"ai.claude_code_new";
/// A transcript line on the card is clipped here (Rust's
/// `transcript_summary_lines`: `chars().take(120)`).
pub const transcript_line_max: usize = 120;
/// The history chip: nf-md-history, `H` in ASCII.
pub const history_glyph = "\u{F02DA}";
pub const history_ascii = "H";

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.sessions;
    if (!st.scanned_once and !st.scanning) refresh(app) catch {};
    // A pane can open, exit or close between scans: the rows are
    // rebuilt every frame (the grid walks behind the sort are cached).
    try refilter(app);
    const rows = try ui.arena.alloc(RowView, st.filtered.items.len);
    for (st.filtered.items, 0..) |idx, i| rows[i] = try cardView(app, ui.arena, st.cards.items[idx]);
    const total = st.cards.items.len;
    const narrowed = st.list.filterText().len > 0 or st.state_filter != null;
    const subtitle = if (!narrowed)
        ui.fmt(" ({d})", .{total})
    else if (st.state_filter) |sf|
        ui.fmt(" ({d} of {d} · {s})", .{ rows.len, total, sf.label() })
    else
        ui.fmt(" ({d} of {d})", .{ rows.len, total });
    const empty: list_panel.EmptyState = if (narrowed)
        .{ .message = "No matches — Esc clears" }
    else
        .{ .message = "No sessions yet." };
    // The history chip reads what it hides; shown, it is lit.
    var chips: [1]@import("ui/header.zig").ExtraChip = undefined;
    var n_chips: usize = 0;
    if (st.hidden_ended > 0 or st.show_ended) {
        chips[0] = .{
            .text = ui.fmt(" {s} {d} ", .{ if (ui.ascii) history_ascii else history_glyph, st.hidden_ended }),
            .id = 0,
            .kind = .history,
            // Hidden: the refresh chip's quiet style; shown: lit like the mode chip.
            .style = if (st.show_ended) null else @import("ui/chip.zig").refreshStyle(ui.theme, ui.theme.panel_bg.bg),
        };
        n_chips = 1;
    }
    // Room under the cards for EXTERNAL / ENDED: what they need, at
    // most a third of the panel (a full page of cards keeps the rest).
    const ext_n: u16 = @intCast(@min(st.external.items.len, external_max));
    const ended_n: u16 = @intCast(@min(st.ended.items.len, 64));
    var needed: u16 = 0;
    if (ext_n > 0) needed += 1 + ext_n + 1;
    if (ended_n > 0) needed += 1 + ended_n;
    const reserve: u16 = @min(needed, area.h / 3);
    const caret = Panel.draw(&st.list, ui, area, .{
        .panel = .sessions,
        .label = "SESSIONS",
        .subtitle = subtitle,
        .sort_chip = sortLabel(st.sort),
        .sort_widest = sort_widest,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = empty,
        .new_label = new_label,
        .row_h = card_h,
        .row_gap = card_gap,
        .own_marker = true,
        .extra_chips = chips[0..n_chips],
        .reserve_bottom = reserve,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    try drawFooter(app, ui, area, st.list.end_y);
    if (st.scanning) list_panel.paintSpinner(ui, area, "SESSIONS", app.now_ms);
}

/// Rust's EXTERNAL block, then Zig's ENDED: a dim caps header at
/// `x + 1`, rows at `x + 2` — `<branch>  (<short id>)` for an external
/// session (a `—` for no branch), `<name>  (<short id>)` greyed for an
/// ended one — a row of padding after EXTERNAL. Painted only when the
/// header and a row fit; never a click target (the table is).
fn drawFooter(app: *App, ui: Ui, area: Rect, y0: u16) Allocator.Error!void {
    const st = &app.sessions;
    const t = ui.theme;
    const bg = t.panel_bg;
    var dim = Theme.withFg(bg, t.palette.comment);
    dim.dim = true;
    const grey = Theme.withFg(bg, t.palette.grey);
    const bottom = area.bottom();
    var y = y0;
    if (st.external.items.len > 0 and y + 2 < bottom) {
        _ = ui.putStr(area.x + 1, y, area.w -| 1, "EXTERNAL", dim);
        y += 1;
        for (st.external.items[0..@min(st.external.items.len, external_max)]) |idx| {
            if (y >= bottom) break;
            const it = st.items[idx];
            const branch = if (it.git_branch) |b| (if (b.len > 0) b else "—") else "—";
            const label = ui.fmt("  {s}  ({s})", .{ branch, it.session_id[0..@min(8, it.session_id.len)] });
            _ = ui.putStr(area.x, y, area.w, ui.clipStr(label, area.w), dim);
            y += 1;
        }
        y += 1;
    }
    if (st.ended.items.len > 0 and y + 1 < bottom) {
        _ = ui.putStr(area.x + 1, y, area.w -| 1, "ENDED", dim);
        y += 1;
        for (st.ended.items) |e| {
            if (y >= bottom) break;
            const label = switch (e) {
                .pane => |pid| blk: {
                    const c: Card = .{ .pane = pid, .session_id = if (app.panes.pty(pid)) |p| p.sessionId() else null, .key = "" };
                    const name = cardName(app, c);
                    const id = c.session_id orelse ui.fmt("pane {d}", .{pid});
                    break :blk ui.fmt("  {s}  ({s})", .{ name, id[0..@min(8, id.len)] });
                },
                .item => |idx| blk: {
                    const it = st.items[idx];
                    break :blk ui.fmt("  {s}  ({s})", .{ displayName(app, it), it.session_id[0..@min(8, it.session_id.len)] });
                },
            };
            _ = ui.putStr(area.x, y, area.w, ui.clipStr(label, area.w), grey);
            y += 1;
        }
    }
}

/// The card's view of its pane, on the frame arena. The summary rows
/// are Rust's `session_lines_for_card`: `exited` alone once the child
/// is gone; else, at rest with a transcript, `you: …` / `claude: …`;
/// else the grid's last content lines in reading order; else `—`.
pub fn cardView(app: *App, arena: Allocator, c: Card) Allocator.Error!RowView {
    const st = &app.sessions;
    const p = app.panes.pty(c.pane);
    const row_item = cardItem(app, c);
    const name = try arena.dupe(u8, cardName(app, c));
    var lines: std.ArrayListUnmanaged(CardLine) = .empty;
    var kind: Summary = .text;
    if (p == null or p.?.exit != null) {
        kind = .exited;
        try lines.append(arena, .{ .text = "exited" });
    } else {
        const d = derive(app, c.pane);
        const thinking = if (d) |dd| dd.thinking else false;
        if (!thinking) if (c.session_id) |sid| if (st.itemOf(sid)) |it| {
            if (it.last_user_msg) |m| if (try collapseWs(arena, m)) |cw| try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "you: {s}", .{clipChars(cw, transcript_line_max)}) });
            if (it.last_assistant_msg) |m| if (try collapseWs(arena, m)) |cw| try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "claude: {s}", .{clipChars(cw, transcript_line_max)}) });
        };
        if (lines.items.len == 0) if (d) |dd| {
            // Most-recent-first in the cache; the card reads top-down.
            var k = @min(dd.lines.len, 3);
            while (k > 0) {
                k -= 1;
                try lines.append(arena, .{
                    .text = try arena.dupe(u8, dd.lines[k].text),
                    .colors = try arena.dupe(CellColor, dd.lines[k].colors),
                });
            }
        };
        if (lines.items.len == 0) {
            kind = .none;
            try lines.append(arena, .{ .text = "—" });
        }
    }
    const aliased = st.alias(c.key) != null;
    const label: []const u8 = if (p) |pp| pp.label else "";
    return .{
        .item = row_item,
        .pane = c.pane,
        .name = name,
        .pinned = st.isPinned(c.key),
        .active = app.active == c.pane,
        .lines = lines.items,
        .kind = kind,
        .ticket = if (aliased) null else detectTicket(app.cfg.ui.ticket_prefixes, &.{ name, cardBranch(app, c) orelse "", label }),
        .color = cardColor(app, c),
        .worktree = if (cardWorktree(app, c)) |e| try arena.dupe(u8, e.name) else null,
    };
}

/// The accent the card paints: the user's pick for its key, else the
/// pane's own (a new session's auto slot).
pub fn cardColor(app: *App, c: Card) ?[]const u8 {
    if (app.sessions.color(c.key)) |name| return name;
    const p = app.panes.pty(c.pane) orelse return null;
    return p.accent_color;
}

/// The hover tip over card `idx` of the list (Rust's
/// `HoverChip::SessionsTab`): the name, then `⎇ branch`, `⌂ cwd`, a
/// blank, and what the pane shows — the transcript's exchange at rest,
/// else up to six grid lines in reading order.
pub fn hoverTip(app: *App, arena: Allocator, idx: u32) Allocator.Error!?@import("ui/tooltip.zig").Tip {
    const st = &app.sessions;
    if (idx >= st.filtered.items.len) return null;
    const c = st.cards.items[st.filtered.items[idx]];
    const p = app.panes.pty(c.pane) orelse return null;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    if (cardBranch(app, c)) |b| try lines.append(arena, try std.fmt.allocPrint(arena, "⎇ {s}", .{b}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "⌂ {s}", .{cardCwd(app, p)}));
    var content: std.ArrayListUnmanaged([]const u8) = .empty;
    if (p.exit != null) {
        try content.append(arena, "exited");
    } else {
        const d = derive(app, c.pane);
        const thinking = if (d) |dd| dd.thinking else false;
        if (!thinking) if (c.session_id) |sid| if (st.itemOf(sid)) |it| {
            if (it.last_user_msg) |m| if (try collapseWs(arena, m)) |cw| try content.append(arena, try std.fmt.allocPrint(arena, "you: {s}", .{clipChars(cw, transcript_line_max)}));
            if (it.last_assistant_msg) |m| if (try collapseWs(arena, m)) |cw| try content.append(arena, try std.fmt.allocPrint(arena, "claude: {s}", .{clipChars(cw, transcript_line_max)}));
        };
        if (content.items.len == 0) if (d) |dd| {
            // The tip is flat muted text (`tooltip.Tip`): the colours
            // are the card's affordance, not the popup's.
            var k = dd.lines.len;
            while (k > 0) {
                k -= 1;
                try content.append(arena, try arena.dupe(u8, dd.lines[k].text));
            }
        };
    }
    if (content.items.len > 0) {
        if (lines.items.len > 0) try lines.append(arena, "");
        try lines.appendSlice(arena, content.items);
    }
    return .{
        .title = try arena.dupe(u8, cardName(app, c)),
        .detail = "click: focus session · right-click: row menu",
        .lines = lines.items,
    };
}

/// The first `max` codepoints of `s`.
pub fn clipChars(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n == max) return s[0..i];
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += len;
        n += 1;
    }
    return s;
}

/// Rust's `strip_leading_spinner_chars`: everything before the first
/// character that could start a title — a letter, a digit, an opening
/// bracket or quote — goes, and the whitespace after it.
pub fn stripLeadingSpinner(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch 0;
        const starts = (cp < 0x80 and (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '(' or cp == '[' or cp == '<' or cp == '"' or cp == '\'')) or
            (cp >= 0x80 and cp != 0xA0 and !isSpinnerCp(cp) and cp != 0x2026);
        if (starts) break;
        i += len;
    }
    return std.mem.trimStart(u8, s[i..], " \t");
}

/// Claude Code's spinner set (`is_claude_thinking`).
fn isSpinnerCp(cp: u21) bool {
    return switch (cp) {
        '·', '✢', '✳', '✱', '✶', '✻', '✽', '❋', '✦', '✧', '⋆', '✿', '✺', '✷', '✸', '✹', '❉', '❅', '◐', '◓', '◑', '◒' => true,
        0xF1E10...0xF1E14 => true,
        else => false,
    };
}

// ─── the grid walk (Rust `pty_pane.rs` summarize_grid_lines) ────────────

/// The per-pane derived state, walked afresh when the pane fed new
/// bytes since (`PtyPane.fed_gen`), its priority re-read after
/// `prio_ttl_ms`. Null for a pane that is gone.
pub fn derive(app: *App, pid: app_mod.PaneId) ?*const Derived {
    const st = &app.sessions;
    const p = app.panes.pty(pid) orelse return null;
    if (!pty_pane.supported) return null;
    const gen = p.fed_gen;
    const gop = st.derived.getOrPut(app.gpa, pid) catch return null;
    if (gop.found_existing and gop.value_ptr.gen == gen) {
        if (app.now_ms - gop.value_ptr.at_ms >= prio_ttl_ms) {
            gop.value_ptr.prio = prioOf(gop.value_ptr.*);
            gop.value_ptr.at_ms = app.now_ms;
            st.prio_evals += 1;
        }
        return gop.value_ptr;
    }
    if (p.session) |session| p.grid.update(app.gpa, session.terminal()) catch {};
    st.grid_walks += 1;
    var fresh = walkGrid(app.gpa, &p.grid) catch {
        if (!gop.found_existing) _ = st.derived.remove(pid);
        return null;
    };
    fresh.gen = gen;
    fresh.at_ms = app.now_ms;
    fresh.prio = prioOf(fresh);
    st.prio_evals += 1;
    if (gop.found_existing) gop.value_ptr.deinit(app.gpa);
    gop.value_ptr.* = fresh;
    return gop.value_ptr;
}

/// Rust's priority off the walk: an approval prompt in the summary is
/// 0, thinking 1, else 2.
fn prioOf(d: Derived) u8 {
    if (d.summary) |m| {
        var buf: [256]u8 = undefined;
        const lower = std.ascii.lowerString(buf[0..@min(m.len, buf.len)], m[0..@min(m.len, buf.len)]);
        if (std.mem.indexOf(u8, lower, "approval") != null or std.mem.indexOf(u8, lower, "do you want") != null) return 0;
    }
    if (d.thinking) return 1;
    return 2;
}

/// One row of the grid as text (`row_to_string`: an empty cell is a
/// space), the colours each byte of that text was painted in, and
/// whether it reads dim (`is_dim_row`).
const GridRow = struct { text: []const u8, colors: []const CellColor, dim: bool };

/// The grid's rows, top to bottom, on `arena`.
fn gridRows(arena: Allocator, grid: *const pty_pane.Grid) Allocator.Error![]GridRow {
    const rows = try arena.alloc(GridRow, grid.rows());
    const def = grid.foreground();
    const default_bright: u32 = @as(u32, def.r) + def.g + def.b;
    const threshold = (default_bright * 3) / 5;
    var y: u16 = 0;
    while (y < grid.rows()) : (y += 1) {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        var colors: std.ArrayListUnmanaged(CellColor) = .empty;
        var total: u32 = 0;
        var dim: u32 = 0;
        var x: u16 = 0;
        while (x < grid.cols()) : (x += 1) {
            const cell = grid.cell(x, y);
            if (cell.wide == .spacer_tail) continue;
            // The cell's own colours, one copy per byte it contributes —
            // an erased cell keeps its background, which is half of what
            // draws Claude's banner figure.
            const paint: CellColor = .{ .fg = cell.fg, .bg = cell.bg };
            const before = text.items.len;
            if (cell.isEmpty()) {
                try text.append(arena, ' ');
                try colors.append(arena, paint);
                continue;
            }
            var buf: [4]u8 = undefined;
            if (cell.grapheme.len > 0) {
                for (cell.grapheme) |cp| {
                    const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                    try text.appendSlice(arena, buf[0..n]);
                }
            } else {
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try text.appendSlice(arena, buf[0..n]);
            }
            try colors.appendNTimes(arena, paint, text.items.len - before);
            if (cell.cp == ' ') continue;
            total += 1;
            const rgb: ?pty_mod.grid.Color.Rgb = switch (cell.fg) {
                .default => null,
                .palette => |i| grid.palette(i),
                .rgb => |v| v,
            };
            if (cell.faint) {
                dim += 1;
            } else if (rgb) |c| {
                const b: u32 = @as(u32, c.r) + c.g + c.b;
                if (default_bright != 0 and b < threshold) dim += 1;
            }
        }
        rows[y] = .{ .text = text.items, .colors = colors.items, .dim = total >= 4 and dim * 5 >= total * 3 };
    }
    return rows;
}

/// The walk: thinking, the one-line summary, the content lines.
fn walkGrid(gpa: Allocator, grid: *const pty_pane.Grid) Allocator.Error!Derived {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const rows = try gridRows(arena, grid);
    const lines = try summarizeGridLines(arena, rows, grid_lines_max);
    const owned = try gpa.alloc(CardLine, lines.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |l| {
            gpa.free(l.text);
            gpa.free(l.colors);
        }
        gpa.free(owned);
    }
    for (lines) |l| {
        const text = try gpa.dupe(u8, l.text);
        errdefer gpa.free(text);
        owned[filled] = .{ .text = text, .colors = try gpa.dupe(CellColor, l.colors) };
        filled += 1;
    }
    const summary: ?[]u8 = if (summarizeGrid(rows)) |m| try gpa.dupe(u8, m) else null;
    return .{
        .gen = 0,
        .at_ms = 0,
        .prio = 2,
        .thinking = isClaudeThinking(rows) or detectCodexThinking(rows),
        .lines = owned,
        .summary = summary,
    };
}

/// The text the walk chose, back as a card line carrying the colours
/// its cells were painted in. `s` is a subslice of `row.text`, so the
/// colours are the same span — widened first back over any blank beside
/// it that carries a background: the trim reads those as padding, but
/// in a banner row they are the figure. Which line a row yields is
/// decided on the trimmed text, exactly as before; only what is painted
/// grows.
fn lineOf(row: GridRow, s: []const u8) CardLine {
    if (s.len == 0 or row.colors.len != row.text.len) return .{ .text = s };
    const at = @intFromPtr(s.ptr) -% @intFromPtr(row.text.ptr);
    if (at > row.text.len or at + s.len > row.text.len) return .{ .text = s };
    var start = at;
    var end = at + s.len;
    while (start > 0 and isBlankByte(row.text[start - 1]) and !row.colors[start - 1].isPlain()) start -= 1;
    while (end < row.text.len and isBlankByte(row.text[end]) and !row.colors[end].isPlain()) end += 1;
    return .{ .text = row.text[start..end], .colors = row.colors[start..end] };
}

fn isBlankByte(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Rust's `summarize_grid_lines`: bottom-up, skipping blank rows,
/// chrome, footer chips, the input prompt and `Worked for Ns`; the dim
/// rows first (Claude Code's summary above the composer), then the
/// plain ones; no row twice, no line equal to the one before it; at
/// most `max`. Most-recent-first within each pass. Each line carries
/// the colours of the cells it came from (`lineOf`).
pub fn summarizeGridLines(arena: Allocator, rows: []const GridRow, max: usize) Allocator.Error![]const CardLine {
    var out: std.ArrayListUnmanaged(CardLine) = .empty;
    if (max == 0) return out.items;
    var dim_hits: std.ArrayListUnmanaged(CardLine) = .empty;
    var plain_hits: std.ArrayListUnmanaged(CardLine) = .empty;
    var y = rows.len;
    while (y > 0) {
        y -= 1;
        const trimmed = std.mem.trim(u8, rows[y].text, " \t");
        if (trimmed.len == 0 or isChromeLine(trimmed) or isFooterChip(trimmed) or isInputPrompt(trimmed) or isWorkedCompletion(trimmed)) continue;
        const cleaned = std.mem.trim(u8, stripLeadingSpinner(trimmed), " \t");
        if ((std.unicode.utf8CountCodepoints(cleaned) catch cleaned.len) < 3) continue;
        const line = lineOf(rows[y], cleaned);
        if (rows[y].dim) try dim_hits.append(arena, line) else try plain_hits.append(arena, line);
    }
    for ([_][]const CardLine{ dim_hits.items, plain_hits.items }) |pass| for (pass) |line| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].text, line.text)) continue;
        try out.append(arena, line);
        if (out.items.len >= max) return out.items;
    };
    return out.items;
}

/// Rust's `summarize_grid`: Claude's activity line, else the first
/// content line from the bottom.
fn summarizeGrid(rows: []const GridRow) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    var y = rows.len;
    while (y > 0) {
        y -= 1;
        const trimmed = std.mem.trim(u8, rows[y].text, " \t");
        if (trimmed.len == 0 or isChromeLine(trimmed) or isFooterChip(trimmed) or isInputPrompt(trimmed)) continue;
        const cleaned = std.mem.trim(u8, stripLeadingSpinner(trimmed), " \t");
        if (looksLikeActivityLine(trimmed) and cleaned.len > 0) return cleaned;
        if (fallback == null and (std.unicode.utf8CountCodepoints(cleaned) catch cleaned.len) >= 3) fallback = cleaned;
    }
    return fallback;
}

/// A row that is one repeated non-alphanumeric character (a border,
/// a separator).
pub fn isChromeLine(s: []const u8) bool {
    if (s.len == 0) return true;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const first = s[0..@min(len, s.len)];
    const cp = std.unicode.utf8Decode(first) catch return false;
    if (cp < 0x80 and std.ascii.isAlphanumeric(@intCast(cp))) return false;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], first)) {
            i += first.len;
        } else if (s[i] == ' ' or s[i] == '\t') {
            i += 1;
        } else return false;
    }
    return true;
}

/// Claude Code's persistent footer chips (`is_footer_chip`).
pub fn isFooterChip(s: []const u8) bool {
    var buf: [512]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(s.len, buf.len)], s[0..@min(s.len, buf.len)]);
    const markers = [_][]const u8{
        "auto mode",                       "manual mode",                     "plan mode",                       "shift+tab to cycle", "shift+tab to change",
        "for agents",                      "for approval",                    "for planning",                    "for accept",         "for accept edits",
        "for tools",                       "for interrupt",                   "esc to interrupt",                "esc to close",       "esc to cancel",
        "tab to amend",                    "for compact",                     "context left until auto-compact", "context left",       "shortcuts",
        "mcp server needs authentication", "mcp servers need authentication", "run /mcp",
    };
    for (markers) |m| if (std.mem.indexOf(u8, lower, m) != null) return true;
    return false;
}

/// The composer prompt row: `>`, `)` or `❯` first.
pub fn isInputPrompt(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '>' or s[0] == ')' or std.mem.startsWith(u8, s, "❯");
}

/// `<spinner> Worked for Ns` — the completion chip, not context.
pub fn isWorkedCompletion(s: []const u8) bool {
    const cleaned = std.mem.trim(u8, stripLeadingSpinner(s), " \t");
    if (!std.mem.startsWith(u8, cleaned, "Worked for ") and !std.mem.startsWith(u8, cleaned, "worked for ")) return false;
    return (std.unicode.utf8CountCodepoints(cleaned) catch cleaned.len) < 30;
}

/// `<glyph> Verb…`, or a short line ending in ` for Ns`.
fn looksLikeActivityLine(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "…") != null or std.mem.indexOf(u8, s, "...") != null) return true;
    if ((std.unicode.utf8CountCodepoints(s) catch s.len) > 60) return false;
    if (std.mem.indexOf(u8, s, " for ")) |at| {
        var i = at + 5;
        var digits: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
        if (digits > 0 and i < s.len and (s[i] == 's' or s[i] == 'm' or s[i] == 'h')) return true;
    }
    return false;
}

/// Rust's `is_claude_thinking`: a row carrying an ellipsis whose first
/// non-blank character is one of Claude Code's spinner glyphs.
pub fn isClaudeThinking(rows: []const GridRow) bool {
    var y = rows.len;
    while (y > 0) {
        y -= 1;
        const line = rows[y].text;
        if (std.mem.indexOf(u8, line, "…") == null and std.mem.indexOf(u8, line, "...") == null) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const len = std.unicode.utf8ByteSequenceLength(trimmed[0]) catch 1;
        if (len > trimmed.len) continue;
        const cp = std.unicode.utf8Decode(trimmed[0..len]) catch continue;
        if (cp == '·' or cp == '✢' or cp == '✳' or cp == '✱' or cp == '✶' or cp == '✻' or cp == '✽' or cp == '❋') return true;
    }
    return false;
}

/// Rust's `detect_codex_thinking`: `•` in one of the bottom four rows
/// with `Working` or an elapsed-time token (`12s`, `1m`).
pub fn detectCodexThinking(rows: []const GridRow) bool {
    const start = rows.len -| 4;
    for (rows[start..]) |r| {
        const line = r.text;
        if (std.mem.indexOf(u8, line, "•") == null) continue;
        if (std.mem.indexOf(u8, line, "Working") != null) return true;
        var i: usize = 0;
        while (i < line.len) {
            if (!std.ascii.isDigit(line[i])) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
            if (j - i <= 3 and j < line.len and (line[j] == 's' or line[j] == 'm' or line[j] == 'h')) return true;
            i = j;
        }
    }
    return false;
}

/// The `⑂ <name>` tag a session worktree paints after the row's label;
/// `wt:<name>` in ASCII.
pub fn worktreeTag(arena: Allocator, name: []const u8, ascii: bool) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ if (ascii) "wt:" else "\u{2442} ", name });
}

/// Newlines and runs of whitespace collapsed to one space, as Rust keeps
/// a row readable in a narrow card; null when nothing is left.
fn collapseWs(arena: Allocator, s: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, w);
    }
    return if (out.items.len == 0) null else out.items;
}

/// The pty pane hosting this session — its argv names the id.
pub fn ptyPaneOf(app: *App, sid: []const u8) ?app_mod.PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| for (p.argv) |arg| {
            if (std.mem.eql(u8, arg, sid)) return @intCast(i);
        },
        else => {},
    };
    return null;
}

/// Rust's `detect_ticket`: the first `<prefix><digits>` in `candidates`
/// for the configured `[ui] ticket_prefixes`, the prefix matched without
/// case; null when there are no prefixes.
pub fn detectTicket(prefixes: []const []const u8, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |cand| {
        if (cand.len == 0) continue;
        for (prefixes) |p| {
            if (p.len == 0) continue;
            var from: usize = 0;
            while (std.ascii.indexOfIgnoreCasePos(cand, from, p)) |start| {
                const after = start + p.len;
                var end = after;
                while (end < cand.len and std.ascii.isDigit(cand[end])) : (end += 1) {}
                if (end > after) return cand[start..end];
                from = after;
            }
        }
    }
    return null;
}

/// Rust's card, cell for cell (`sessions_panel.rs`): the accent `▌` down
/// `x + 1` — the session's chosen colour first (`RowView.color`), else
/// cyan on the cursor's card while the panel has focus, green on the
/// card whose pty pane is the active one, else the ground — then at `x + 3`
/// the name after a pin `󰐃 ` (bold when active, clipped hard at the
/// edge), and up to three summary rows clipped to `width − 6` with `…`,
/// the first with ` · TICKET` when one was detected. No bell, no ports.
fn paintRow(ui: Ui, r: Rect, row: RowView, selected: bool) void {
    const t = ui.theme;
    const bg = t.panel_bg;
    if (r.w < 3 or r.h == 0) return;
    const focused = ui.isFocused(.{ .panel = .sessions });
    const chosen: ?vaxis.Color = if (row.color) |c| accent_color.resolve(c, t) else null;
    const accent = chosen orelse if (selected and focused) t.palette.cyan else if (row.active) t.palette.green else bg.bg;
    const bar = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    var y: u16 = 0;
    while (y < r.h) : (y += 1) _ = ui.putStr(r.x + 1, r.y + y, 1, bar, Theme.withFg(bg, accent));
    const end = r.right();
    var x = r.x + 2;
    x += ui.putStr(x, r.y, end -| x, " ", bg);
    if (row.pinned) x += ui.putStr(x, r.y, end -| x, if (ui.ascii) "📌 " else "\u{F0403} ", Theme.withFg(bg, t.palette.orange));
    var name_style = Theme.withFg(bg, t.fg.fg);
    name_style.bold = row.active;
    x += ui.putStr(x, r.y, end -| x, row.name, name_style);
    if (row.worktree) |wt| {
        const tag = worktreeTag(ui.arena, wt, ui.ascii) catch "";
        x += ui.putStr(x, r.y, end -| x, " ", bg);
        _ = ui.putStr(x, r.y, end -| x, tag, Theme.withFg(bg, t.palette.cyan));
    }
    const max_cells: u16 = @max(4, r.w -| 6);
    const color = switch (row.kind) {
        .exited => t.palette.red,
        .none => t.palette.grey,
        .text => t.muted.fg,
    };
    for (row.lines, 0..) |line, i| {
        if (i >= 3 or i + 1 >= r.h) break;
        const yy = r.y + 1 + @as(u16, @intCast(i));
        var xx = r.x + 2;
        xx += ui.putStr(xx, yy, end -| xx, " ", bg);
        xx += paintLine(ui, xx, yy, end, max_cells, line, bg, color);
        if (i == 0) if (row.ticket) |tk| {
            xx += ui.putStr(xx, yy, end -| xx, " · ", Theme.withFg(bg, t.muted.fg));
            _ = ui.putStr(xx, yy, end -| xx, tk, Theme.withFg(bg, t.palette.cyan));
        };
    }
}

/// One summary row of a card, painted, returning the cells used. A row
/// the card synthesized (`exited`, the exchange, `—`) is flat text in
/// `ink`, as it always was. A row read off the pane's grid is painted
/// run by run in the colours its cells carried: the card's own ground
/// where the source background is the terminal default, the source
/// background where it is set — which is what draws the orange figure
/// of Claude's banner, half of it plain spaces. Colours resolve through
/// the same path `drawPty` takes (`pty_view.colorOf`), so the card's
/// orange is the pane's orange. The last run to reach the card's edge
/// carries the ellipsis.
fn paintLine(ui: Ui, x0: u16, y: u16, end: u16, max_cells: u16, line: CardLine, ground: vaxis.Style, ink: vaxis.Color) u16 {
    if (!line.colored()) return ui.putStr(x0, y, end -| x0, ui.clipStr(line.text, max_cells), Theme.withFg(ground, ink));
    var used: u16 = 0;
    var i: usize = 0;
    while (i < line.text.len and used < max_cells) {
        var j = i + 1;
        while (j < line.text.len and line.colors[j].eql(line.colors[i])) j += 1;
        const room = @min(max_cells - used, end -| (x0 + used));
        if (room == 0) break;
        var style = ground;
        style.fg = pty_view.colorOf(line.colors[i].fg, ink);
        style.bg = pty_view.colorOf(line.colors[i].bg, ground.bg);
        const painted = ui.putStr(x0 + used, y, room, ui.clipStr(line.text[i..j], room), style);
        if (painted == 0) break;
        used += painted;
        i = j;
    }
    return used;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const transcript = @import("ai/transcript.zig");
const session_file = @import("app/session.zig");

/// The fake `claude` the card tests run: what it prints is what the
/// pane's grid holds. Its session id picks the act — `exit-*` exits at
/// once, `think-*` paints Claude's spinner row, `ask-*` an approval
/// prompt, anything else the startup banner — and every other act stays
/// up. `--session-id` / `--resume` are read the way the CLI reads them.
const fake_claude =
    \\#!/bin/sh
    \\sid=""
    \\while [ $# -gt 0 ]; do case "$1" in --session-id|--resume) sid=$2; shift 2;; *) shift;; esac; done
    \\case "$sid" in
    \\  exit-*) exit 0 ;;
    \\  fail-*) exit 3 ;;
    \\  think-*) printf 'Claude Code v9 (fake)\n\342\234\273 Thinking\342\200\246\n'; sleep 30 ;;
    \\  ask-*) printf 'Do you want to proceed?\n'; sleep 30 ;;
    \\  *) printf 'Claude Code v9 (fake)\nOpus 5 (fake) \302\267 Claude Max\n~/Projects/fake\n'; sleep 30 ;;
    \\esac
    \\
;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,
    /// `<root>/bin/claude` once `fakeClaude` wrote it.
    claude: ?[]u8 = null,

    fn init(cols: u16, rows: u16) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = cols, .rows = rows });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        if (f.claude) |c| testing.allocator.free(c);
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// A fixture home with one Claude and one Codex transcript, pointed
    /// at by `State.home`.
    fn seedHome(f: *Fixture) !void {
        try f.tmp.dir.createDirPath(testing.io, "home/.claude/projects/-Users-me-Projects-mnml");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/projects/-Users-me-Projects-mnml/aaaaaaaa-0000-4000-8000-000000000001.jsonl", .data = transcript.claude_fixture });
        try f.tmp.dir.createDirPath(testing.io, "home/.codex/sessions/2026/09/04");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.codex/sessions/2026/09/04/rollout-2026-09-04T10-00-00-bbbbbbbb-0000-4000-8000-000000000002.jsonl", .data = transcript.codex_fixture });
        f.app.sessions.home = try std.fs.path.join(testing.allocator, &.{ f.root, "home" });
    }

    /// The fake `claude` on disk, executable.
    fn fakeClaude(f: *Fixture) !void {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        try f.tmp.dir.createDirPath(testing.io, "bin");
        const path = try std.fs.path.join(testing.allocator, &.{ f.root, "bin", "claude" });
        errdefer testing.allocator.free(path);
        const perms: Io.File.Permissions = .fromMode(0o755);
        const file = try Io.Dir.cwd().createFile(testing.io, path, .{ .truncate = true, .permissions = perms });
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, fake_claude);
        try file.setPermissions(testing.io, perms);
        f.claude = path;
    }

    /// A pane running the fake under `sid` — a card.
    fn openCard(f: *Fixture, sid: []const u8) !app_mod.PaneId {
        return pty_pane.open(&f.app, .{ .argv = &.{ f.claude.?, "--session-id", sid }, .label = "claude", .kind = .command, .placement = .tab });
    }

    /// Ticks until `needle` is on the fake's grid — the pane need not be
    /// on screen — or `ms` pass.
    fn waitGrid(f: *Fixture, pid: app_mod.PaneId, needle: []const u8, ms: u32) !bool {
        var waited: u32 = 0;
        while (waited <= ms) : (waited += 10) {
            try f.app.tick(App.nowMs(testing.io));
            const p = f.app.panes.pty(pid) orelse return false;
            p.fed_gen +%= 1; // a walk afresh, whatever the cache holds
            if (derive(&f.app, pid)) |d| for (d.lines) |l| if (std.mem.indexOf(u8, l.text, needle) != null) return true;
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    /// Ticks until the pane's child has exited, or `ms` pass.
    fn waitExit(f: *Fixture, pid: app_mod.PaneId, ms: u32) !bool {
        var waited: u32 = 0;
        while (waited <= ms) : (waited += 10) {
            try f.app.tick(App.nowMs(testing.io));
            const p = f.app.panes.pty(pid) orelse return false;
            if (p.exit != null) return true;
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    /// The section on the right, `w` wide, shown and focused.
    fn showSection(f: *Fixture, w: u16) !void {
        f.app.tree.visible = false;
        f.app.side.of.set(.sessions, .right);
        f.app.side.right_width = w;
        try command.run(&f.app, .{ .static = .@"view.activity_sessions" });
        focusPanel(&f.app);
    }

    /// A listing adopted as the snapshot; the real home is never scanned.
    fn adopt(f: *Fixture, items: []const Item) !void {
        const r = try ScanResult.create(testing.allocator, 1);
        const copy = try r.arena.allocator().alloc(Item, items.len);
        for (items, 0..) |it, i| copy[i] = try dupeItem(r.arena.allocator(), it);
        r.items = copy;
        r.at_s = Io.Timestamp.now(testing.io, .real).toSeconds();
        f.app.sessions.generation = 1;
        try handle(&f.app, r);
        f.app.sessions.scanned_once = true;
    }

    fn settle(f: *Fixture, max: usize) !void {
        var i: usize = 0;
        while (f.app.sessions.scanning and i < max) : (i += 1) {
            try f.app.tick(App.nowMs(testing.io));
            if (f.app.sessions.scanning) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn screen(f: *Fixture) ![]u8 {
        try f.app.render();
        return @import("ipc/screen.zig").toTestText(testing.allocator, &f.app.screen);
    }

    fn cardAt(f: *Fixture, vi: usize) Card {
        return f.app.sessions.cards.items[f.app.sessions.filtered.items[vi]];
    }
};

const item = testItem;

/// `testItem` rooted in the fixture's workspace, so the section scopes it in.
fn wsItem(f: *Fixture, id: []const u8, state: AgentState, at: i64, msg: ?[]const u8) Item {
    var it = item(id, state, at, std.fs.path.basename(f.root), msg);
    it.cwd = f.root;
    it.git_branch = "main";
    return it;
}

test "the cards are this app's AI panes: a fresh one reads its banner off the grid, one at rest its transcript's exchange, an exited one `exited`; the scan's rows go under EXTERNAL and ENDED, the chip counts the hidden" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const now = Io.Timestamp.now(testing.io, .real).toSeconds();
    const sid_rest = "5e551011-0000-4000-8000-0000000000aa";
    const rest = try f.openCard(sid_rest);
    const fresh = try f.openCard("fresh-1");
    const gone = try f.openCard("exit-1");
    var rest_it = wsItem(&f, sid_rest, .idle, now, "fix  the\n tests");
    rest_it.last_assistant_msg = "On it.\nRunning them now.";
    try f.adopt(&.{
        rest_it,
        wsItem(&f, "ext-live-0000-4000-8000-000000000001", .streaming, now, "elsewhere"),
        wsItem(&f, "old-done-0000-4000-8000-000000000001", .done, now - 3600, "old"),
        wsItem(&f, "just-end-0000-4000-8000-000000000001", .done, now - 60, "just ended"),
    });
    try testing.expect(try f.waitGrid(fresh, "Claude Code v9", 5000));
    try testing.expect(try f.waitGrid(rest, "Claude Code v9", 5000));
    try testing.expect(try f.waitExit(gone, 5000));
    try f.showSection(40);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    const st = &app.sessions;
    // Three cards, in Rust's priority: the two idle ones by pane, the exited last.
    try testing.expectEqual(@as(usize, 3), st.cards.items.len);
    try testing.expectEqual(@as(usize, 3), st.filtered.items.len);
    try testing.expectEqual(rest, f.cardAt(0).pane);
    try testing.expectEqual(fresh, f.cardAt(1).pane);
    try testing.expectEqual(gone, f.cardAt(2).pane);
    try testing.expect(std.mem.indexOf(u8, txt, "SESSIONS (3)") != null);
    // At rest with a transcript: the exchange, whitespace collapsed.
    try testing.expect(std.mem.indexOf(u8, txt, "you: fix the tests") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "claude: On it. Running them now.") != null);
    // No transcript: the grid's lines, in reading order.
    try testing.expect(std.mem.indexOf(u8, txt, "Claude Code v9 (fake)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Opus 5 (fake) · Claude Max") != null);
    // (`~/` is no title start — Rust's strip drops it too.)
    try testing.expect(std.mem.indexOf(u8, txt, "Projects/fake") != null);
    const v_fresh = try cardView(app, app.frame.allocator(), f.cardAt(1));
    try testing.expectEqual(Summary.text, v_fresh.kind);
    try testing.expectEqual(@as(usize, 3), v_fresh.lines.len);
    try testing.expectEqualStrings("Claude Code v9 (fake)", v_fresh.lines[0].text);
    // The child gone: `exited` alone, red.
    const v_gone = try cardView(app, app.frame.allocator(), f.cardAt(2));
    try testing.expectEqual(Summary.exited, v_gone.kind);
    try testing.expectEqualStrings("exited", v_gone.lines[0].text);
    try testing.expect(std.mem.indexOf(u8, txt, "exited") != null);
    // The owned transcript is no EXTERNAL row; the live unowned one is;
    // the ended ones: the fresh one listed under ENDED, the old one hidden.
    try testing.expectEqual(@as(usize, 1), st.external.items.len);
    try testing.expect(std.mem.indexOf(u8, txt, "EXTERNAL") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  main  (ext-live)") != null);
    try testing.expectEqual(@as(usize, 1), st.ended.items.len);
    try testing.expectEqual(@as(usize, 1), st.hidden_ended);
    try testing.expect(std.mem.indexOf(u8, txt, "ENDED") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "just ended  (just-end)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(old-done)") == null);
    try testing.expect(std.mem.indexOf(u8, txt, " " ++ history_glyph ++ " 1 ") != null);
    // The stand-in row for a card the scan has not listed carries the
    // pane's cwd and no transcript; the listed one is the scan's.
    const stand_in = cardItem(app, f.cardAt(1));
    try testing.expectEqualStrings("fresh-1", stand_in.session_id);
    try testing.expectEqual(@as(usize, 0), stand_in.transcript_path.len);
    try testing.expectEqualStrings(f.root, stand_in.cwd.?);
    try testing.expectEqualStrings("/t", cardItem(app, f.cardAt(0)).transcript_path);
    // Enter focuses the card's pane; the transcript rows refuse the stand-in.
    st.list.cursor = 1;
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqual(fresh, app.active.?);
    focusPanel(app);
    try testing.expectError(error.Failed, command.run(app, .{ .static = .@"sessions.open_transcript" }));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "no transcript yet") != null);
    app.diag.clear();
    // The tooltip: the name, the cwd, a blank, then what the card shows.
    const tip = (try hoverTip(app, app.frame.allocator(), 0)).?;
    try testing.expectEqualStrings("claude", tip.title);
    try testing.expect(tip.lines.len >= 4);
    try testing.expectEqualStrings("⎇ main", tip.lines[0]);
    try testing.expect(std.mem.startsWith(u8, tip.lines[1], "⌂ "));
    try testing.expectEqualStrings("", tip.lines[2]);
    try testing.expectEqualStrings("you: fix the tests", tip.lines[3]);
    const tip_fresh = (try hoverTip(app, app.frame.allocator(), 1)).?;
    try testing.expectEqualStrings("Claude Code v9 (fake)", tip_fresh.lines[2]);
    try testing.expectEqualStrings("exited", (try hoverTip(app, app.frame.allocator(), 2)).?.lines[2]);
    try testing.expect((try hoverTip(app, app.frame.allocator(), 9)) == null);
}

test "the caches: a frame walks a pane's grid once per output generation, the priority is re-read after 500 ms, and no frame starts a scan" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const st = &app.sessions;
    const pid = try f.openCard("plain-1");
    try f.adopt(&.{});
    try testing.expect(try f.waitGrid(pid, "Claude Code v9", 5000));
    const walks = st.grid_walks;
    const evals = st.prio_evals;
    const gen = st.generation;
    try f.showSection(30);
    // Two frames, the same output: no walk, no evaluation, no scan.
    try app.render();
    try app.render();
    try testing.expectEqual(walks, st.grid_walks);
    try testing.expectEqual(evals, st.prio_evals);
    try testing.expectEqual(gen, st.generation);
    try testing.expectEqual(@as(u8, 2), priority(app, pid));
    // 500 ms on: the priority is read again off the cached walk.
    app.now_ms += prio_ttl_ms + 1;
    try app.render();
    try testing.expectEqual(walks, st.grid_walks);
    try testing.expectEqual(evals + 1, st.prio_evals);
    // New output: one walk.
    app.panes.pty(pid).?.fed_gen +%= 1;
    try app.render();
    try app.render();
    try testing.expectEqual(walks + 1, st.grid_walks);
    // A pane that closes leaves the cache.
    try app.forceClosePane(pid);
    try app.render();
    try testing.expectEqual(@as(usize, 0), st.derived.count());
}

test "the sort is Rust's priority: an approval prompt first, then thinking, idle, exited; pins lead; Manual follows the order list then the pane order" {
    var f = try Fixture.init(80, 24);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const st = &app.sessions;
    const plain = try f.openCard("plain-1");
    const gone = try f.openCard("exit-1");
    const think = try f.openCard("think-1");
    const ask = try f.openCard("ask-1");
    try f.adopt(&.{});
    try testing.expect(try f.waitGrid(plain, "Claude Code v9", 5000));
    try testing.expect(try f.waitGrid(think, "Thinking", 5000));
    try testing.expect(try f.waitGrid(ask, "Do you want", 5000));
    try testing.expect(try f.waitExit(gone, 5000));
    try testing.expectEqual(@as(u8, 0), priority(app, ask));
    try testing.expectEqual(@as(u8, 1), priority(app, think));
    try testing.expectEqual(@as(u8, 2), priority(app, plain));
    try testing.expectEqual(@as(u8, 3), priority(app, gone));
    try testing.expectEqual(@as(u8, 4), priority(app, 999));
    try testing.expect(derive(app, think).?.thinking);
    try testing.expect(!derive(app, plain).?.thinking);
    try refilter(app);
    try testing.expectEqual(ask, f.cardAt(0).pane);
    try testing.expectEqual(think, f.cardAt(1).pane);
    try testing.expectEqual(plain, f.cardAt(2).pane);
    try testing.expectEqual(gone, f.cardAt(3).pane);
    try testing.expectEqual(AgentState.waiting, cardState(app, f.cardAt(0)));
    try testing.expectEqual(AgentState.streaming, cardState(app, f.cardAt(1)));
    try testing.expectEqual(AgentState.idle, cardState(app, f.cardAt(2)));
    try testing.expectEqual(AgentState.done, cardState(app, f.cardAt(3)));
    // The state filter narrows the cards by that state.
    st.state_filter = .streaming;
    try refilter(app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqual(think, f.cardAt(0).pane);
    st.state_filter = null;
    // A pin leads; on the manual axis the order list leads, the rest by pane.
    _ = try st.togglePin(testing.allocator, "exit-1");
    try refilter(app);
    try testing.expectEqual(gone, f.cardAt(0).pane);
    try testing.expectEqual(ask, f.cardAt(1).pane);
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "think-1"));
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "ask-1"));
    try setSort(app, .manual);
    try testing.expectEqual(gone, f.cardAt(0).pane);
    try testing.expectEqual(think, f.cardAt(1).pane);
    try testing.expectEqual(ask, f.cardAt(2).pane);
    try testing.expectEqual(plain, f.cardAt(3).pane);
    try setSort(app, .auto);
    // The text filter reads the name, the id and the cwd's basename.
    try st.list.filter.appendSlice(testing.allocator, "ASK-");
    try refilter(app);
    try testing.expectEqual(@as(usize, 1), st.filtered.items.len);
    try testing.expectEqual(ask, f.cardAt(0).pane);
    st.list.filter.clearRetainingCapacity();
    try st.list.filter.appendSlice(testing.allocator, std.fs.path.basename(f.root));
    try refilter(app);
    try testing.expectEqual(@as(usize, 4), st.filtered.items.len);
    st.list.filter.clearRetainingCapacity();
}

test "EXTERNAL lists the scan's live unowned sessions of this workspace, four at most on screen; w widens it to every workspace" {
    var f = try Fixture.init(80, 30);
    defer f.deinit();
    const app = &f.app;
    const st = &app.sessions;
    const now = Io.Timestamp.now(testing.io, .real).toSeconds();
    var mem = std.heap.ArenaAllocator.init(testing.allocator);
    defer mem.deinit();
    var items: [7]Item = undefined;
    for (0..6) |i| {
        const id = try std.fmt.allocPrint(mem.allocator(), "ext-{d}xxx-0000-4000-8000-000000000001", .{i});
        items[i] = wsItem(&f, id, .streaming, now - @as(i64, @intCast(i)), "x");
    }
    items[6] = item("elsewhere-0000", .streaming, now, "other", "y");
    try f.adopt(&items);
    try f.showSection(40);
    try testing.expectEqual(@as(usize, 6), st.external.items.len);
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "No sessions yet.") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "EXTERNAL") != null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, txt, "  main  (ext-"));
    try testing.expect(std.mem.indexOf(u8, txt, "(ext-0xxx)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(ext-3xxx)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(ext-4xxx)") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "(elsewher)") == null);
    try app.handle(.{ .key = Key.char('w') });
    try testing.expect(st.all_workspaces);
    try testing.expectEqual(@as(usize, 7), st.external.items.len);
    // A no-branch row reads `—`.
    try app.handle(.{ .key = Key.char('w') });
    items[0].git_branch = null;
    try f.adopt(&items);
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "  —  (ext-0xxx)") != null);
}

test "the history chip: it counts the ended past the grace window, E and the click list them under ENDED and light the chip, the toggle rides in session.zon, the menu clears them" {
    var f = try Fixture.init(80, 30);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const st = &app.sessions;
    const now = Io.Timestamp.now(testing.io, .real).toSeconds();
    const gone = try f.openCard("exit-1");
    try testing.expect(try f.waitExit(gone, 5000));
    try f.adopt(&.{
        wsItem(&f, "old-done-0000-4000-8000-000000000001", .done, now - 3600, "old one"),
        wsItem(&f, "old-fail-0000-4000-8000-000000000001", .failed, now - 7200, "old two"),
        wsItem(&f, "just-end-0000-4000-8000-000000000001", .done, now - 60, "just ended"),
    });
    try f.showSection(40);
    // Inside the grace: the fresh row listed, the exited pane a card, two hidden.
    var txt = try f.screen();
    try testing.expectEqual(@as(usize, 2), st.hidden_ended);
    try testing.expectEqual(@as(usize, 1), st.ended.items.len);
    try testing.expectEqual(@as(usize, 1), st.cards.items.len);
    try testing.expect(std.mem.indexOf(u8, txt, " " ++ history_glyph ++ " 2 ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "just ended") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "old one") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "exited") != null);
    testing.allocator.free(txt);
    // The chip's cell is not lit while hidden.
    var chip_rect: ?Rect = null;
    for (app.hits.items.items) |h| switch (h.target) {
        .chip => |c| if (c.panel == .sessions and c.kind == .history) {
            chip_rect = h.rect;
        },
        else => {},
    };
    try testing.expect(chip_rect != null);
    try testing.expect(!vaxis.Color.eql(app.screen.readCell(chip_rect.?.x + 1, chip_rect.?.y).?.style.bg, app.theme.chip_active.bg));
    // E: every ended row listed, the chip lit and still counting.
    try app.handle(.{ .key = Key.char('E') });
    try testing.expect(st.show_ended);
    txt = try f.screen();
    try testing.expectEqual(@as(usize, 3), st.ended.items.len);
    try testing.expect(std.mem.indexOf(u8, txt, "old one  (old-done)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "old two  (old-fail)") != null);
    try testing.expect(vaxis.Color.eql(app.screen.readCell(chip_rect.?.x + 1, chip_rect.?.y).?.style.bg, app.theme.chip_active.bg));
    testing.allocator.free(txt);
    // The toggle is saved with the session and comes back.
    try session_file.save(app);
    const zon = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/session.zon", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(zon);
    try testing.expect(std.mem.indexOf(u8, zon, ".sessions_show_ended = true") != null);
    {
        var app2 = try App.initWith(testing.allocator, testing.io, .{ .workspace = f.root, .cols = 80, .rows = 30 });
        defer app2.deinit();
        try testing.expect(!app2.sessions.show_ended);
        try session_file.restore(&app2);
        try testing.expect(app2.sessions.show_ended);
    }
    // The chip's click hides them again; its right-click is the menu.
    try app.handle(.{ .mouse = .{ .x = chip_rect.?.x + 1, .y = chip_rect.?.y, .kind = .press, .button = .left } });
    try testing.expect(!st.show_ended);
    try app.handle(.{ .mouse = .{ .x = chip_rect.?.x + 1, .y = chip_rect.?.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqual(@as(usize, 3), app.overlay.menu.items.len);
    try testing.expectEqualStrings("Show ended", app.overlay.menu.items[0].label);
    try testing.expect(!app.overlay.menu.items[0].checked and app.overlay.menu.items[1].checked);
    try testing.expectEqual(command.CommandId.@"sessions.clear_ended", app.overlay.menu.items[2].action.command);
    try app.handle(.{ .key = Key.named(.esc) });
    // A zero grace hides the fresh row and the exited pane's card too.
    app.cfg.ui.session_ended_grace_min = 0;
    app.now_ms += 1;
    try refilter(app);
    try testing.expectEqual(@as(usize, 4), st.hidden_ended);
    try testing.expectEqual(@as(usize, 0), st.ended.items.len);
    try testing.expectEqual(@as(usize, 0), st.cards.items.len);
    // Clear: the scan's ended rows are forgotten, the exited pane closes.
    try command.run(app, .{ .static = .@"sessions.clear_ended" });
    try testing.expectEqual(@as(usize, 3), st.cleared.items.len);
    try testing.expect(app.panes.get(gone) == null);
    try testing.expectEqual(@as(usize, 0), st.hidden_ended);
    txt = try f.screen();
    try testing.expect(std.mem.indexOf(u8, txt, history_glyph) == null);
    testing.allocator.free(txt);
    // A cleared id stays cleared across a rescan.
    try f.adopt(&.{wsItem(&f, "old-done-0000-4000-8000-000000000001", .done, now - 3600, "old one")});
    try testing.expectEqual(@as(usize, 0), st.hidden_ended);
}

test "the grid walk: chrome, footer chips, the prompt and `Worked for` skipped; dim rows first; Claude's and Codex's thinking rows" {
    var term: pty_mod.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 40, .rows = 8 });
    defer term.deinit(testing.allocator);
    var vs = term.vtStream();
    defer vs.deinit();
    vs.nextSlice("Claude Code v9\r\n────────\r\n\x1b[2mDrafted the notes\x1b[0m\r\n✻ Worked for 3s\r\nauto mode on (shift+tab to cycle)\r\n> \r\n");
    var grid: pty_mod.Grid = .{};
    defer grid.deinit(testing.allocator);
    try grid.update(testing.allocator, &term);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try gridRows(arena, &grid);
    try testing.expectEqual(@as(usize, 8), rows.len);
    try testing.expect(rows[2].dim);
    try testing.expect(!rows[0].dim);
    const lines = try summarizeGridLines(arena, rows, 6);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("Drafted the notes", lines[0].text);
    try testing.expectEqualStrings("Claude Code v9", lines[1].text);
    try testing.expect(!isClaudeThinking(rows));
    try testing.expect(!detectCodexThinking(rows));
    // The one-liner is Rust's `summarize_grid`: the activity-shaped
    // `Worked for 3s` wins over the dim row (its priority reads it).
    try testing.expectEqualStrings("Worked for 3s", summarizeGrid(rows).?);
    // The predicates.
    try testing.expect(isChromeLine("────────"));
    try testing.expect(isChromeLine("- - - -"));
    try testing.expect(!isChromeLine("a───"));
    try testing.expect(isFooterChip("Esc to cancel · Tab to amend"));
    try testing.expect(isFooterChip("Context left until auto-compact: 43%"));
    try testing.expect(!isFooterChip("Running the suite"));
    try testing.expect(isInputPrompt("> hello") and isInputPrompt("❯ ") and !isInputPrompt("hello"));
    try testing.expect(isWorkedCompletion("✻ Worked for 30s") and !isWorkedCompletion("Worked for the last five years at"));
    try testing.expectEqualStrings("Thinking…", stripLeadingSpinner("✻ Thinking…"));
    try testing.expectEqualStrings("fix the tests", stripLeadingSpinner("✳ fix the tests"));
    try testing.expectEqualStrings("(1) a", stripLeadingSpinner("· (1) a"));
    try testing.expectEqualStrings("héllo", clipChars("héllo wörld", 5));
    // Claude thinking: a spinner row with an ellipsis. Codex: `•` with a time.
    var t2: pty_mod.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 40, .rows = 4 });
    defer t2.deinit(testing.allocator);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice("hello\r\n✻ Sautéing… (12s)\r\n");
    var g2: pty_mod.Grid = .{};
    defer g2.deinit(testing.allocator);
    try g2.update(testing.allocator, &t2);
    const rows2 = try gridRows(arena, &g2);
    try testing.expect(isClaudeThinking(rows2));
    try testing.expectEqualStrings("Sautéing… (12s)", summarizeGrid(rows2).?);
    var t3: pty_mod.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 40, .rows = 4 });
    defer t3.deinit(testing.allocator);
    var s3 = t3.vtStream();
    defer s3.deinit();
    s3.nextSlice("• Working (1m 32s)\r\n");
    var g3: pty_mod.Grid = .{};
    defer g3.deinit(testing.allocator);
    try g3.update(testing.allocator, &t3);
    try testing.expect(detectCodexThinking(try gridRows(arena, &g3)));
    try testing.expect(!isClaudeThinking(try gridRows(arena, &g3)));
    // A thinking pane reads its grid, not the transcript: the walk's
    // priority is 1, and an approval prompt beats it.
    try testing.expectEqual(@as(u8, 1), prioOf(.{ .gen = 0, .at_ms = 0, .prio = 0, .thinking = true, .summary = null }));
    var ask = try testing.allocator.dupe(u8, "Do you want to proceed?");
    defer testing.allocator.free(ask);
    try testing.expectEqual(@as(u8, 0), prioOf(.{ .gen = 0, .at_ms = 0, .prio = 0, .thinking = true, .summary = ask[0..] }));
    try testing.expectEqual(@as(u8, 2), prioOf(.{ .gen = 0, .at_ms = 0, .prio = 0, .thinking = false, .summary = null }));
}

test "scanInto over a fixture home lists the dashboard's sessions in this module's shape" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.seedHome();
    const r = try ScanResult.create(testing.allocator, 1);
    defer r.destroy(testing.allocator);
    try scanInto(testing.io, testing.allocator, f.app.sessions.home.?, f.root, null, r);
    try testing.expectEqual(@as(usize, 2), r.items.len);
    var claude_seen = false;
    for (r.items) |it| if (it.source == .claude) {
        claude_seen = true;
        try testing.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000001", it.session_id);
        try testing.expectEqualStrings("mnml", it.workspace);
        try testing.expect(std.mem.endsWith(u8, it.transcript_path, ".jsonl"));
        try testing.expectEqual(AgentState.done, it.state);
        try testing.expectEqualStrings("/Users/me/Projects/mnml", it.groupKey());
        try testing.expectEqualStrings("mnml", it.groupLabel());
    };
    try testing.expect(claude_seen);
}

test "headless: a card owning a scanned transcript reads it; w widens ENDED; J adopts the visible order and flips to Manual; the menus name real ids; rename lands as an alias on the card; delete waits for the exit" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.fakeClaude();
    try f.seedHome();
    const app = &f.app;
    const st = &app.sessions;
    // The fixture transcript is another workspace's; a card here owns it.
    const sid = "aaaaaaaa-0000-4000-8000-000000000001";
    const owner = try f.openCard(sid);
    const other = try f.openCard("plain-2");
    try f.showSection(56);
    try app.render();
    try f.settle(2000);
    try testing.expect(try f.waitGrid(other, "Claude Code v9", 5000));
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "SESSIONS (2)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "sort: State") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "+ New session") != null);
    // The owned transcript is the card's exchange; the Codex fixture is
    // another workspace's, so nothing under EXTERNAL / ENDED until w.
    try testing.expect(std.mem.indexOf(u8, txt, "you: fix the build") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "claude: (tool_use: Edit)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "EXTERNAL") == null);
    try testing.expectEqualStrings("/Users/me/Projects/mnml", cardItem(app, .{ .pane = owner, .session_id = sid, .key = sid }).cwd.?);
    try app.handle(.{ .key = Key.char('w') });
    try testing.expect(st.all_workspaces);
    try testing.expectEqual(@as(usize, 2), st.cards.items.len);
    // J moves the top card down: the visible order becomes the manual list.
    const first = f.cardAt(0).key;
    try app.handle(.{ .key = Key.char('J') });
    try testing.expectEqual(SessionsSort.manual, st.sort);
    try testing.expectEqual(SessionsSort.manual, app.cfg.ui.sessions_sort);
    try testing.expectEqualStrings(first, f.cardAt(1).key);
    try testing.expectEqual(@as(usize, 1), st.list.cursor);
    try testing.expectEqual(@as(usize, 2), st.order.items.len);
    // The chip toggles back to State and persists.
    try app.handle(.{ .key = Key.char('s') });
    try testing.expectEqual(SessionsSort.auto, st.sort);
    const cfg = try f.tmp.dir.readFileAlloc(testing.io, ".mnml/config.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "sessions_sort") != null);
    // Menus.
    try app.render();
    var row0: ?Rect = null;
    var sort_chip: ?Rect = null;
    for (app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.panel == .sessions and r.idx == 0) {
            row0 = h.rect;
        },
        .chip => |c| if (c.panel == .sessions and c.kind == .sort) {
            sort_chip = h.rect;
        },
        else => {},
    };
    try testing.expect(row0 != null and sort_chip != null);
    try testing.expectEqual(card_h, row0.?.h);
    try app.handle(.{ .mouse = .{ .x = row0.?.x + 1, .y = row0.?.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    // Pin, four moves, Auto sort, Rename…, Color, Focus, transcript,
    // id, cwd, export, Kill (a live pane the scan paired), Delete, table.
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    defer labels.deinit(testing.allocator);
    for (app.overlay.menu.items) |mi| try labels.append(testing.allocator, mi.label);
    try testing.expectEqualStrings("Pin", labels.items[0]);
    try testing.expectEqualStrings("Auto sort", labels.items[5]);
    try testing.expectEqualStrings("Rename…", labels.items[6]);
    try testing.expectEqualStrings("Color", labels.items[7]);
    try testing.expectEqualStrings("Focus session", labels.items[8]);
    try testing.expectEqualStrings("Open as a table", labels.items[labels.items.len - 1]);
    for (labels.items) |l| try testing.expect(!std.mem.eql(u8, l, "Resume in a terminal"));
    var color_rows: usize = 0;
    for (app.overlay.menu.items) |it| {
        if (it.submenu.len > 0) {
            try testing.expectEqual(accent_color.palette.len + 1, it.submenu.len);
            color_rows += 1;
        } else try testing.expect(it.action == .command);
    }
    try testing.expectEqual(@as(usize, 1), color_rows);
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .mouse = .{ .x = sort_chip.?.x + 1, .y = sort_chip.?.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqual(@as(usize, 2), app.overlay.menu.items.len);
    try testing.expect(app.overlay.menu.items[0].checked);
    try app.handle(.{ .key = Key.named(.esc) });
    // Rename through the prompt: the alias lands on the card's key and
    // shows on the card and in the table row.
    selectKey(app, sid);
    try app.handle(.{ .key = Key.char('R') });
    try testing.expect(app.overlay == .prompt);
    for ("nightly build") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("nightly build", st.alias(sid).?);
    focusPanel(app);
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "nightly build") != null);
    try testing.expectEqualStrings("nightly build", displayName(app, cardItem(app, f.cardAt(st.list.cursor))));
    // Delete is refused while the pane runs; once the child is gone the
    // confirm deletes the transcript and the rescan drops the row.
    selectKey(app, sid);
    try testing.expectError(error.Failed, command.run(app, .{ .static = .@"sessions.delete" }));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "is running") != null);
    app.diag.clear();
    try app.forceClosePane(owner);
    // The pane gone, the transcript is unowned and ended — inside the
    // grace, an ENDED row (the table deletes those); the card is gone.
    try command.run(app, .{ .static = .@"sessions.refresh" });
    try f.settle(2000);
    try app.render();
    try testing.expect(st.itemOf(sid) != null);
    try testing.expectEqual(@as(usize, 1), st.cards.items.len);
    // (Under `w` the Codex fixture joins it — or EXTERNAL, when a real
    // codex process on this machine claims it.)
    try testing.expect(st.ended.items.len >= 1);
    const txt3 = try f.screen();
    defer testing.allocator.free(txt3);
    try testing.expect(std.mem.indexOf(u8, txt3, "ENDED") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "nightly build  (aaaaaaaa)") != null);
}

test "tick rescans a shown panel on the cadence and leaves a hidden one alone" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.seedHome();
    const st = &f.app.sessions;
    st.scanned_once = true;
    st.last_scan_ms = 0;
    tick(&f.app, refresh_ms + 1); // hidden: nothing
    try testing.expectEqual(@as(u32, 0), st.generation);
    side.place(&f.app, .sessions, false);
    f.app.now_ms = refresh_ms - 1;
    tick(&f.app, refresh_ms - 1);
    try testing.expectEqual(@as(u32, 0), st.generation);
    f.app.now_ms = refresh_ms + 1;
    tick(&f.app, refresh_ms + 1);
    try testing.expectEqual(@as(u32, 1), st.generation);
    try testing.expect(nextDeadlineMs(&f.app) != null);
    try f.settle(2000);
}

// ─── the card against the spec ──────────────────────────────────────────

const UiFixture = @import("ui/test_fixture.zig");
const spec_120x40 = @embedFile("ui_spec_rust_sessions_120x40");

/// Screen row `y` of the Rust dump, the sidebar's 26 cells between the
/// rail's `│` and the divider's, trailing spaces trimmed.
fn specRow(y: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, spec_120x40, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) if (i == y) {
        const bar = "│"; // chrome-audit: allow — reads the Rust dump, paints nothing
        const first = std.mem.indexOf(u8, line, bar).? + bar.len;
        const second = std.mem.indexOfPos(u8, line, first, bar).?;
        return std.mem.trimEnd(u8, line[first..second], " ");
    };
    unreachable;
}

fn cardProps(rows: []const RowView) Panel.Props {
    return .{
        .panel = .sessions,
        .label = "SESSIONS",
        .subtitle = " (3)",
        .sort_chip = sortLabel(.auto),
        .sort_widest = sort_widest,
        .rows = rows,
        .paintRow = paintRow,
        .has_kebab = true,
        .empty = .{ .message = "No sessions yet." },
        .new_label = new_label,
        .row_h = card_h,
        .row_gap = card_gap,
        .own_marker = true,
    };
}

/// The three cards of `rust-sessions-120x40.txt`, as `cardView` builds them.
fn specCards() [3]RowView {
    return .{
        .{ .item = item("5e551011-0000-4000-8000-000000000003", .done, 1, "ws", "write the release notes for 0.3"), .name = "write the release notes for 0.3", .pinned = true, .lines = &.{.{ .text = "exited" }}, .kind = .exited },
        .{ .item = item("5e551011-0000-4000-8000-000000000001", .streaming, 3, "ws", "fix the failing tests in src/main.rs"), .name = "fix the failing tests in src/main.rs", .lines = &.{ .{ .text = "you: fix the failing tests in src/main.rs" }, .{ .text = "claude: Running the suite first to see which ones fail." } }, .kind = .text },
        .{ .item = item("5e551011-0000-4000-8000-000000000002", .idle, 2, "ws", "add a --json flag to the CLI"), .name = "release train", .lines = &.{ .{ .text = "you: add a --json flag to the CLI" }, .{ .text = "claude: Added the flag and a test for it. Anything else?" } }, .kind = .text },
    };
}

test "a banner row keeps its cells' colours through the walk, and the card paints them: the bg-coloured space paints that background, the glyph that foreground, the rest the card's own" {
    // A banner row the shape Claude Code's is: a space that is only a
    // background, a block glyph that is only a foreground, two cells
    // erased under that background (a cell with no codepoint at all —
    // the other half of how the figure is drawn), then text.
    const orange: pty_mod.grid.Color.Rgb = .{ .r = 215, .g = 119, .b = 87 };
    var term: pty_mod.vt.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 40, .rows = 4 });
    defer term.deinit(testing.allocator);
    var vs = term.vtStream();
    defer vs.deinit();
    vs.nextSlice("\x1b[48;2;215;119;87m \x1b[0m\x1b[38;2;215;119;87m\u{2588}\x1b[0m" ++
        "\x1b[48;2;215;119;87m\x1b[2X\x1b[2C\x1b[0m Claude Code v9\r\n");
    var grid: pty_mod.Grid = .{};
    defer grid.deinit(testing.allocator);
    try grid.update(testing.allocator, &term);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try summarizeGridLines(arena, try gridRows(arena, &grid), 6);
    try testing.expectEqual(@as(usize, 1), lines.len);
    // The trim would drop the leading space — in a banner row that space
    // IS the figure, so a coloured one is kept (`lineOf`).
    try testing.expectEqualStrings(" \u{2588}   Claude Code v9", lines[0].text);
    try testing.expect(lines[0].colored());
    try testing.expectEqual(pty_mod.grid.Color{ .rgb = orange }, lines[0].colors[0].bg);
    try testing.expectEqual(pty_mod.grid.Color.default, lines[0].colors[0].fg);
    // The glyph is three bytes, each carrying its cell's foreground.
    try testing.expectEqual(pty_mod.grid.Color{ .rgb = orange }, lines[0].colors[1].fg);
    try testing.expectEqual(pty_mod.grid.Color{ .rgb = orange }, lines[0].colors[3].fg);
    try testing.expectEqual(pty_mod.grid.Color.default, lines[0].colors[3].bg);
    // The erased cells: no codepoint, a background — the space the card
    // used to drop on the floor.
    try testing.expectEqual(pty_mod.grid.Color{ .rgb = orange }, lines[0].colors[4].bg);
    try testing.expectEqual(pty_mod.grid.Color{ .rgb = orange }, lines[0].colors[5].bg);
    try testing.expect(lines[0].colors[6].isPlain());
    try testing.expect(lines[0].colors[lines[0].colors.len - 1].isPlain());

    // Painted: the space is that background, the glyph that foreground,
    // and the plain text the card's own muted ink on the panel ground.
    var f = try UiFixture.init(40, 6);
    defer f.deinit();
    const row: RowView = .{
        .item = item("5e551011-0000-4000-8000-000000000004", .streaming, 1, "ws", "claude"),
        .name = "claude",
        .lines = lines[0..1],
        .kind = .text,
    };
    paintRow(f.ui(), Rect.init(0, 0, 40, 4), row, false);
    try f.expectRow(1, " \u{258C}  \u{2588}   Claude Code v9");
    const vx_orange: vaxis.Color = .{ .rgb = .{ 215, 119, 87 } };
    try testing.expect(vaxis.Color.eql(f.style(3, 1).bg, vx_orange));
    try testing.expect(vaxis.Color.eql(f.style(3, 1).fg, f.theme.muted.fg));
    try testing.expect(vaxis.Color.eql(f.style(4, 1).fg, vx_orange));
    try testing.expect(vaxis.Color.eql(f.style(4, 1).bg, f.theme.panel_bg.bg));
    try testing.expect(vaxis.Color.eql(f.style(5, 1).bg, vx_orange));
    try testing.expect(vaxis.Color.eql(f.style(6, 1).bg, vx_orange));
    try testing.expect(vaxis.Color.eql(f.style(8, 1).fg, f.theme.muted.fg));
    try testing.expect(vaxis.Color.eql(f.style(8, 1).bg, f.theme.panel_bg.bg));
    // A line the card synthesized has no cells behind it: flat text.
    var g = try UiFixture.init(40, 6);
    defer g.deinit();
    var plain = row;
    plain.lines = &.{.{ .text = "exited" }};
    plain.kind = .exited;
    paintRow(g.ui(), Rect.init(0, 0, 40, 4), plain, false);
    try g.expectRow(1, " \u{258C} exited");
    try testing.expect(vaxis.Color.eql(g.style(3, 1).fg, g.theme.palette.red));
    try testing.expect(vaxis.Color.eql(g.style(3, 1).bg, g.theme.panel_bg.bg));
}

test "the card at 26 cells is Rust's, cell for cell: rows 3–18 of rust-sessions-120x40.txt, the top block per the user above them" {
    var f = try UiFixture.init(26, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    const rows = specCards();
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    // The top block: the header, the pill, a blank, the New row, a blank.
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "");
    try f.expectRow(3, "  + New session");
    try f.expectRow(4, "");
    // Rust's rows 3–18 land on the same screen rows: the chip row, the
    // blank, the pinned ended card, the live card, the renamed idle card.
    var buf: [256]u8 = undefined;
    var y: u16 = 3;
    while (y <= 18) : (y += 1) try testing.expectEqualStrings(specRow(y), f.row(y, &buf));
    // Hits: the New chip alone on its row, the blanks take none, a card's
    // hit covers its four rows and the gap none.
    try testing.expectEqual(hit.ChipKind.new, f.hits.at(3, 3).?.chip.kind);
    try testing.expect(f.hits.at(5, 2) == null);
    try testing.expect(f.hits.at(5, 4) == null);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 5).?.row.idx);
    try testing.expectEqual(@as(u32, 0), f.hits.at(20, 8).?.row.idx);
    try testing.expect(f.hits.at(5, 9) == null);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 10).?.row.idx);
    try testing.expectEqual(@as(u32, 2), f.hits.at(5, 15).?.row.idx);
    try testing.expectEqual(hit.PanelId.sessions, f.hits.at(10, 1).?.filter_input);
    // The selected card keeps the ground; its accent is the cursor's
    // cyan only while the panel has focus (the fixture focuses a pane).
    try testing.expect(f.bgEql(10, 5, f.theme.panel_bg));
    try testing.expect(vaxis.Color.eql(f.style(1, 5).fg, f.theme.panel_bg.bg));
    try testing.expect(vaxis.Color.eql(f.style(3, 5).fg, f.theme.palette.orange));
    try testing.expect(vaxis.Color.eql(f.style(3, 6).fg, f.theme.palette.red));
    try testing.expect(vaxis.Color.eql(f.style(3, 11).fg, f.theme.muted.fg));
    // The history chip at the shipped width: the icon rung of the sort
    // chip and the count both fit; the chip is the panel's own target.
    f.hits.reset();
    const chips = [_]@import("ui/header.zig").ExtraChip{.{ .text = " " ++ history_glyph ++ " 3 ", .id = 0, .kind = .history }};
    var p = cardProps(&rows);
    p.extra_chips = &chips;
    _ = Panel.draw(&st, f.ui(), f.full(), p);
    // The count gave way to the chip (the ladder's rule 2).
    try f.expectRow(0, " SESSIONS     " ++ history_glyph ++ " 3   \u{f0dc}   \u{eb37}");
    try f.expectLacks("(3)");
    try testing.expectEqual(hit.ChipKind.history, f.hits.at(15, 0).?.chip.kind);
    try testing.expectEqual(hit.PanelId.sessions, f.hits.at(15, 0).?.chip.panel);
}

test "the card at 30 and 34 cells: the name clips hard at the edge, the summary keeps width − 6 with the ellipsis" {
    const rows = specCards();
    var f = try UiFixture.init(30, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    try f.expectRow(5, " \u{258c} \u{F0403} write the release notes f");
    try f.expectRow(10, " \u{258c} fix the failing tests in sr");
    try f.expectRow(11, " \u{258c} you: fix the failing te…");
    try f.expectRow(12, " \u{258c} claude: Running the sui…");
    var g = try UiFixture.init(34, 20);
    defer g.deinit();
    _ = Panel.draw(&st, g.ui(), g.full(), cardProps(&rows));
    try g.expectRow(10, " \u{258c} fix the failing tests in src/ma");
    try g.expectRow(11, " \u{258c} you: fix the failing tests …");
    try g.expectRow(17, " \u{258c} claude: Added the flag and …");
    // Narrow: nothing off-screen, and a card too narrow for a name is bare.
    var h = try UiFixture.init(3, 12);
    defer h.deinit();
    _ = Panel.draw(&st, h.ui(), h.full(), cardProps(&rows));
    for (h.hits.items.items) |e| try testing.expect(h.full().intersect(e.rect).eql(e.rect));
    // A footer reserve leaves rows under the list: two cards fit in 20
    // rows with none (12 + 1 gap = 13 of 15), one with a third reserved.
    var i = try UiFixture.init(30, 20);
    defer i.deinit();
    var p = cardProps(&rows);
    _ = Panel.draw(&st, i.ui(), i.full(), p);
    try testing.expectEqual(@as(usize, 3), st.visible);
    // 15 rows under the top block: 7 reserved leave 8, one card (its
    // stride 5); the footer starts after the card's gap row.
    p.reserve_bottom = 7;
    _ = Panel.draw(&st, i.ui(), i.full(), p);
    try testing.expectEqual(@as(usize, 1), st.visible);
    try testing.expectEqual(@as(u16, 10), st.end_y);
}

test "the summary rows: the ticket chip from ui.ticket_prefixes, hidden by an alias; the pin; the colour off the pane" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const arena = app.frame.allocator();
    const pid = try f.openCard("plain-9");
    try f.adopt(&.{});
    try testing.expect(try f.waitGrid(pid, "Claude Code v9", 5000));
    try refilter(app);
    const c = f.cardAt(0);
    try testing.expectEqualStrings("plain-9", c.key);
    // The ticket: the prefix without case, digits required, the first hit.
    try testing.expect(detectTicket(&.{}, &.{"ABC-9"}) == null);
    try testing.expectEqualStrings("ABC-1234", detectTicket(&.{ "TKT-", "ABC-" }, &.{"Review ABC-1234 and abc-5"}).?);
    try testing.expectEqualStrings("abc-5", detectTicket(&.{"ABC-"}, &.{ "", "ABC-foo abc-5" }).?);
    try testing.expect(detectTicket(&.{"ABC-"}, &.{"ABC-foo"}) == null);
    app.cfg.ui.ticket_prefixes = &.{"ABC-"};
    try app.sessions.setAlias(testing.allocator, "plain-9", "review ABC-77 today");
    var v = try cardView(app, arena, c);
    try testing.expectEqualStrings("review ABC-77 today", v.name);
    // An alias hides the chip (Rust: `display_name.is_none()`).
    try testing.expect(v.ticket == null);
    try app.sessions.setAlias(testing.allocator, "plain-9", "");
    v = try cardView(app, arena, c);
    try testing.expectEqualStrings("claude", v.name);
    try testing.expect(v.ticket == null);
    // The pane just opened is the active one.
    try testing.expect(!v.pinned and v.active);
    // The auto slot is the card's colour; a pick overrides it.
    try testing.expectEqualStrings("green", v.color.?);
    try app.sessions.setColor(testing.allocator, "plain-9", "pink");
    v = try cardView(app, arena, c);
    try testing.expectEqualStrings("pink", v.color.?);
    _ = try app.sessions.togglePin(testing.allocator, "plain-9");
    try testing.expect((try cardView(app, arena, c)).pinned);
    try testing.expectEqual(pid, c.pane);
}

test "pins lead the list on either axis; p toggles and follows the card; the row menu leads with Pin / Unpin; the New chip's right click is the batch menu" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const st = &app.sessions;
    const live = try f.openCard("plain-1");
    const idle = try f.openCard("plain-2");
    const gone = try f.openCard("exit-3");
    try f.adopt(&.{});
    try testing.expect(try f.waitGrid(live, "Claude Code v9", 5000));
    try testing.expect(try f.waitGrid(idle, "Claude Code v9", 5000));
    try testing.expect(try f.waitExit(gone, 5000));
    try f.showSection(40);
    try refilter(app);
    try testing.expectEqual(live, f.cardAt(0).pane);
    try testing.expectEqual(gone, f.cardAt(2).pane);
    // p on the exited card pins it to the top and keeps it selected.
    st.list.cursor = 2;
    try app.handle(.{ .key = Key.char('p') });
    try testing.expect(st.isPinned("exit-3"));
    try testing.expectEqual(gone, f.cardAt(0).pane);
    try testing.expectEqual(@as(usize, 0), st.list.cursor);
    try testing.expectEqual(live, f.cardAt(1).pane);
    // On the manual axis too, ahead of the order list.
    try st.order.append(testing.allocator, try testing.allocator.dupe(u8, "plain-2"));
    try setSort(app, .manual);
    try testing.expectEqual(gone, f.cardAt(0).pane);
    try testing.expectEqual(idle, f.cardAt(1).pane);
    try setSort(app, .auto);
    // The card shows the pin; the menu offers Unpin first, Pin on another.
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F0403} claude") != null);
    var row0: ?Rect = null;
    var new_chip: ?Rect = null;
    for (app.hits.items.items) |h| switch (h.target) {
        .row => |pr| if (pr.panel == .sessions and pr.idx == 0) {
            row0 = h.rect;
        },
        .chip => |c| if (c.panel == .sessions and c.kind == .new) {
            new_chip = h.rect;
        },
        else => {},
    };
    try testing.expect(row0 != null and new_chip != null);
    try testing.expectEqual(card_h, row0.?.h);
    try app.handle(.{ .mouse = .{ .x = row0.?.x + 3, .y = row0.?.y + 2, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Unpin", app.overlay.menu.items[0].label);
    try testing.expectEqual(command.CommandId.@"sessions.pin", app.overlay.menu.items[0].action.command);
    try testing.expectEqualStrings("Move up", app.overlay.menu.items[1].label);
    try testing.expectEqualStrings("Move to bottom", app.overlay.menu.items[4].label);
    try testing.expect(app.overlay.menu.items[5].checked);
    try testing.expectEqualStrings("Rename…", app.overlay.menu.items[6].label);
    // An exited card offers no Kill row; the separator sits on Delete.
    for (app.overlay.menu.items) |mi| try testing.expect(!std.mem.eql(u8, mi.label, "Kill session…"));
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(!st.isPinned("exit-3"));
    try testing.expectEqual(live, f.cardAt(0).pane);
    try app.render();
    try app.handle(.{ .mouse = .{ .x = row0.?.x + 3, .y = row0.?.y, .kind = .press, .button = .right } });
    try testing.expectEqualStrings("Pin", app.overlay.menu.items[0].label);
    try app.handle(.{ .key = Key.named(.esc) });
    // The New row's click — either button — is the choice menu: Rust's
    // command first, the batch rows, then the cloud wizards (naming
    // their missing config here).
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new", new_command);
    try app.handle(.{ .mouse = .{ .x = new_chip.?.x + 1, .y = new_chip.?.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqual(@as(usize, 7), app.overlay.menu.items.len);
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new", app.overlay.menu.items[0].action.command);
    try testing.expectEqual(command.CommandId.@"ai.new_session_worktree", app.overlay.menu.items[1].action.command);
    try testing.expectEqualStrings("New session in a worktree…", app.overlay.menu.items[1].label);
    try testing.expectEqual(command.CommandId.@"ai.claude_code_new_x8", app.overlay.menu.items[4].action.command);
    try testing.expectEqual(command.CommandId.@"cloud_agents.new_run", app.overlay.menu.items[5].action.command);
    try testing.expect(std.mem.indexOf(u8, app.overlay.menu.items[5].label, "not configured") != null);
    try testing.expectEqual(command.CommandId.@"cloud_agents.new_run_wizard", app.overlay.menu.items[6].action.command);
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .mouse = .{ .x = new_chip.?.x + 1, .y = new_chip.?.y, .kind = .press, .button = .left } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqual(@as(usize, 7), app.overlay.menu.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
}

test "Move to top / bottom lead or end the manual order under the pins; a cloud row's menu (from the table) is titled by its run and links CloudWatch and the PR when configured" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    const st = &app.sessions;
    const live = try f.openCard("plain-1");
    const idle = try f.openCard("plain-2");
    const gone = try f.openCard("exit-3");
    var run = item("run-1", .streaming, 40, "cloud", "TE-1");
    run.where = .cloud;
    run.cloud = .{ .ticket = "TE-1", .pr_url = "https://example.test/pr/1" };
    try f.adopt(&.{run});
    try testing.expect(try f.waitGrid(live, "Claude Code v9", 5000));
    try testing.expect(try f.waitGrid(idle, "Claude Code v9", 5000));
    try testing.expect(try f.waitExit(gone, 5000));
    try f.showSection(40);
    try refilter(app);
    try testing.expectEqual(live, f.cardAt(0).pane);
    try testing.expectEqual(gone, f.cardAt(2).pane);
    // The exited card to the top: the axis flips to Manual and the card
    // stays selected; then to the bottom.
    st.list.cursor = 2;
    try command.run(app, .{ .static = .@"sessions.move_top" });
    try testing.expectEqual(SessionsSort.manual, st.sort);
    try testing.expectEqual(gone, f.cardAt(0).pane);
    try testing.expectEqual(@as(usize, 0), st.list.cursor);
    try command.run(app, .{ .static = .@"sessions.move_bottom" });
    try testing.expectEqual(gone, f.cardAt(2).pane);
    try testing.expectEqual(@as(usize, 2), st.list.cursor);
    try testing.expectEqual(live, f.cardAt(0).pane);
    // A pin still leads: idle pinned, then live to the top sits under it.
    _ = try st.togglePin(testing.allocator, "plain-2");
    try refilter(app);
    st.list.cursor = 1;
    try testing.expectEqual(live, f.cardAt(1).pane);
    try command.run(app, .{ .static = .@"sessions.move_top" });
    try testing.expectEqual(idle, f.cardAt(0).pane);
    try testing.expectEqual(live, f.cardAt(1).pane);
    // The menu's Auto sort row is unticked on the manual axis.
    try openRowMenuFor(app, .section, 0, 0);
    try testing.expectEqualStrings("Auto sort", app.overlay.menu.items[5].label);
    try testing.expect(!app.overlay.menu.items[5].checked);
    try testing.expectEqual(command.CommandId.@"sessions.sort_auto", app.overlay.menu.items[5].action.command);
    try app.handle(.{ .key = Key.named(.esc) });
    // The cloud row is no card; under `w` it is an EXTERNAL row, and its
    // menu comes from the table, titled by the run, with the PR link and
    // — unconfigured — no CloudWatch row.
    try app.handle(.{ .key = Key.char('w') });
    try testing.expectEqual(@as(usize, 1), st.external.items.len);
    try command.run(app, .{ .static = .@"sessions.table" });
    const tid = sessions_table.find(app).?;
    const tp = sessions_table.get(app, tid).?;
    try sessions_table.onSnapshot(app);
    for (tp.visible.items, 0..) |e, vi| if (e == .item and app.sessions.items[e.item].where == .cloud) {
        tp.list.cursor = vi;
    };
    try testing.expect(sessions_table.focused(app) != null);
    try testing.expectEqualStrings("run-1", current(app).?.session_id);
    try openRowMenuFor(app, .table, 0, 0);
    try testing.expectEqualStrings("cloud · run-1", app.overlay.menu.title);
    var saw_pr = false;
    var saw_cw = false;
    for (app.overlay.menu.items) |mi| {
        if (std.mem.eql(u8, mi.label, "Open PR")) {
            saw_pr = true;
            try testing.expectEqualStrings("https://example.test/pr/1", mi.action.open_url);
        }
        if (std.mem.eql(u8, mi.label, "Open CloudWatch in browser")) saw_cw = true;
        try testing.expect(!std.mem.eql(u8, mi.label, "Resume in a terminal"));
    }
    try testing.expect(saw_pr and !saw_cw);
    try app.handle(.{ .key = Key.named(.esc) });
    // Configured, the CloudWatch row names the run's query.
    app.cfg.cloud_agents.region = "eu-west-1";
    app.cfg.cloud_agents.account_id = "123456789012";
    app.cfg.cloud_agents.log_group = "/ecs/runner";
    try openRowMenuFor(app, .table, 0, 0);
    saw_cw = false;
    for (app.overlay.menu.items) |mi| if (std.mem.eql(u8, mi.label, "Open CloudWatch in browser")) {
        saw_cw = true;
        try testing.expect(std.mem.startsWith(u8, mi.action.open_url, "https://eu-west-1.console.aws.amazon.com/cloudwatch/"));
        try testing.expect(std.mem.indexOf(u8, mi.action.open_url, "run-1") != null);
        try testing.expect(std.mem.endsWith(u8, mi.action.open_url, "?account=123456789012"));
    };
    try testing.expect(saw_cw);
    try app.handle(.{ .key = Key.named(.esc) });
}

test "a session on one of the workspace's worktrees: the card and the table row carry the ⑂ tag (wt: in ASCII), the row menu offers the tree's verbs, its EXTERNAL twin counts as this workspace's" {
    var f = try Fixture.init(120, 30);
    defer f.deinit();
    try f.fakeClaude();
    const app = &f.app;
    app.tree.visible = false;
    // A tree the workspace's path is no prefix of (an override root), so
    // only the registry can make it this workspace's.
    const wt = try std.fs.path.join(testing.allocator, &.{ std.fs.path.dirname(f.root).?, "x-worktrees", "feat" });
    defer testing.allocator.free(wt);
    try testing.expect(!std.mem.startsWith(u8, wt, f.root));
    try Io.Dir.cwd().createDirPath(testing.io, wt);
    try app.sessions.worktrees.add(testing.allocator, wt, "feat", "feat", f.root, null);
    // The card's pane runs in the tree; the scan lists its transcript
    // there, and another tree session no pane owns.
    const tree_pid = try pty_pane.open(app, .{ .argv = &.{ f.claude.?, "--session-id", "tree-1" }, .cwd = wt, .label = "claude", .kind = .command, .placement = .tab });
    var tree_it = item("tree-1", .streaming, 30, "feat", "ship it");
    tree_it.cwd = wt;
    var tree_other = item("tree-2", .streaming, 20, "feat", "elsewhere in the tree");
    tree_other.cwd = wt;
    try f.adopt(&.{ tree_it, tree_other });
    try testing.expect(try f.waitGrid(tree_pid, "Claude Code v9", 5000));
    // The scan paired the tree with its session; the unowned tree row is
    // this workspace's EXTERNAL row without `w`.
    try testing.expectEqualStrings("tree-1", app.sessions.worktrees.byPath(wt).?.session_id.?);
    try testing.expect(!app.sessions.all_workspaces);
    try refilter(app);
    try testing.expectEqual(@as(usize, 1), app.sessions.cards.items.len);
    try testing.expectEqual(@as(usize, 1), app.sessions.external.items.len);
    const c = f.cardAt(0);
    try testing.expect(cardWorktree(app, c) != null);
    try testing.expectEqualStrings("feat", cardBranch(app, c).?);
    try command.run(app, .{ .static = .@"view.activity_sessions" });
    const txt = try f.screen();
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "claude \u{2442} feat") != null);
    // The table row too.
    try command.run(app, .{ .static = .@"sessions.table" });
    try sessions_table.onSnapshot(app);
    const txt2 = try f.screen();
    defer testing.allocator.free(txt2);
    try testing.expect(std.mem.indexOf(u8, txt2, "live ship it \u{2442} feat") != null);
    // ASCII: the wt: twin, in both.
    app.cfg.ui.ascii_icons = true;
    const txt3 = try f.screen();
    defer testing.allocator.free(txt3);
    try testing.expect(std.mem.indexOf(u8, txt3, "live ship it wt:feat") != null);
    try testing.expect(std.mem.indexOf(u8, txt3, "\u{2442}") == null);
    app.cfg.ui.ascii_icons = false;
    // The row menu on the tree's card has the three verbs.
    focusPanel(app);
    app.sessions.list.cursor = 0;
    try testing.expectEqualStrings("tree-1", current(app).?.session_id);
    try openRowMenuFor(app, .section, 0, 0);
    var saw_open = false;
    var saw_merge = false;
    var saw_remove = false;
    for (app.overlay.menu.items) |mi| {
        if (std.mem.eql(u8, mi.label, "Open worktree in tree")) saw_open = true;
        if (std.mem.startsWith(u8, mi.label, "Merge into ")) saw_merge = true;
        if (std.mem.eql(u8, mi.label, "Remove worktree…")) saw_remove = true;
    }
    try testing.expect(saw_open and saw_merge and saw_remove);
    try f.app.handle(.{ .key = Key.named(.esc) });
}

test "state edges: the first listing is no edge; live → waiting toasts once (warn) and rings the bell only under ui.session_bell; the same listing again is quiet; failed toasts err" {
    var f = try Fixture.init(100, 24);
    defer f.deinit();
    const msgs = &f.app.messages.items;
    const listing = struct {
        fn post(fx: *Fixture, a: AgentState, b: AgentState) !void {
            try fx.adopt(&.{
                item("a", a, 30, std.fs.path.basename(fx.root), "approve?"),
                item("b", b, 20, std.fs.path.basename(fx.root), "ship it"),
            });
        }
    };
    const before = msgs.items.len;
    // A session that is already waiting when first listed is no edge.
    try listing.post(&f, .waiting, .streaming);
    try testing.expectEqual(before, msgs.items.len);
    try testing.expect(!f.app.bell_pending);
    // b goes waiting: one warn toast naming it; the bell is off by default.
    try listing.post(&f, .waiting, .waiting);
    try testing.expectEqual(before + 1, msgs.items.len);
    try testing.expectEqualStrings("session needs input: ship it", msgs.items[msgs.items.len - 1].text);
    try testing.expectEqual(app_mod.ToastLevel.warn, msgs.items[msgs.items.len - 1].level);
    try testing.expect(!f.app.bell_pending);
    // The same listing on the next tick: nothing new.
    try listing.post(&f, .waiting, .waiting);
    try listing.post(&f, .waiting, .waiting);
    try testing.expectEqual(before + 1, msgs.items.len);
    // Quiet edges say nothing; a → failed toasts err; b back to waiting
    // rings the bell once the config asks.
    try listing.post(&f, .streaming, .idle);
    try testing.expectEqual(before + 1, msgs.items.len);
    f.app.cfg.ui.session_bell = true;
    try listing.post(&f, .failed, .waiting);
    try testing.expectEqual(before + 3, msgs.items.len);
    try testing.expectEqualStrings("session failed: approve?", msgs.items[msgs.items.len - 2].text);
    try testing.expectEqual(app_mod.ToastLevel.err, msgs.items[msgs.items.len - 2].level);
    try testing.expect(f.app.bell_pending);
}

test "a relative HOME is under the workspace: what a .test file seeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    var vars = std.process.Environ.Map.init(testing.allocator);
    defer vars.deinit();
    try vars.put("HOME", "home");
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 80, .rows = 20, .env = &vars });
    defer app.deinit();
    const home = (try homeFor(&app)).?;
    try testing.expect(std.fs.path.isAbsolute(home));
    try testing.expectEqualStrings("home", std.fs.path.basename(home));
    try testing.expect(std.mem.startsWith(u8, home, root));
    try testing.expectEqualStrings(home, app.sessions.home.?);
}

test "colors: a card's `▌` takes the session's chosen colour over the cursor and active cues; the row menu's Color rows resolve" {
    var f = try UiFixture.init(26, 20);
    defer f.deinit();
    var st: Panel.State = .{};
    defer st.deinit(testing.allocator);
    var rows = specCards();
    rows[1].color = "blue";
    rows[1].active = true;
    rows[2].color = "bogus";
    _ = Panel.draw(&st, f.ui(), f.full(), cardProps(&rows));
    // Card 0 (no colour, not active, the cursor's while a pane has
    // focus): the ground. Card 1: blue, though active. Card 2: an
    // unknown name is no colour.
    try testing.expect(vaxis.Color.eql(f.style(1, 5).fg, f.theme.panel_bg.bg));
    try testing.expect(vaxis.Color.eql(f.style(1, 10).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(1, 13).fg, f.theme.palette.blue));
    try testing.expect(vaxis.Color.eql(f.style(1, 15).fg, f.theme.panel_bg.bg));
    // The rows a menu shows: the palette in order, then Auto, one checked.
    var mem = std.heap.ArenaAllocator.init(testing.allocator);
    defer mem.deinit();
    const items = try colorMenuRows(mem.allocator(), .{ .target = .row, .name = "" }, "yellow");
    try testing.expectEqual(accent_color.palette.len + 1, items.len);
    try testing.expectEqualStrings("Color: Green", items[0].label);
    try testing.expect(items[2].checked and !items[0].checked and !items[items.len - 1].checked);
    try testing.expectEqualStrings("Color: Auto", items[items.len - 1].label);
    try testing.expectEqualStrings(accent_color.none, items[items.len - 1].action.session_color.name);
}

test "colors: the state keeps a colour per session id — set, replace, none drops, unknown drops" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    const st = &f.app.sessions;
    try st.setColor(testing.allocator, "s1", "green");
    try st.setColor(testing.allocator, "s2", "pink");
    try testing.expectEqualStrings("green", st.color("s1").?);
    try testing.expectEqualStrings("pink", st.color("s2").?);
    try st.setColor(testing.allocator, "s1", "red");
    try testing.expectEqualStrings("red", st.color("s1").?);
    try st.setColor(testing.allocator, "s2", accent_color.none);
    try testing.expect(st.color("s2") == null);
    try st.setColor(testing.allocator, "s3", "mauve");
    try testing.expect(st.color("s3") == null);
    try testing.expectEqual(@as(usize, 1), st.colors.items.len);
    try testing.expectEqualStrings("red", colorNameOf(&f.app, "s1").?);
    try testing.expect(colorNameOf(&f.app, "s2") == null);
}
