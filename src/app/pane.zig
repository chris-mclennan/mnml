//! `Pane` — the open-thing union — and `PaneStore`, the arena that hands
//! out stable `PaneId`s. Editor, the symbol outline, the rendered
//! markdown preview, the cheatsheet, the list panes (cmdline history,
//! quickfix) and the pty today; Request / Diff / Ai are additive
//! variants later.
//!
//! // changed: WAVE3 said `editor: Buffer`; the editor pane also owns
//! its view state, find state, wrap override and syntax cache, so the
//! variant is `EditorPane` with the `Buffer` inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("../core/ids.zig");
const buffer_mod = @import("../editor/buffer.zig");
const editor_view = @import("../ui/editor_view.zig");
const find = @import("find.zig");
const syntax = @import("syntax.zig");
const sticky = @import("sticky.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const image_pane = @import("image_pane.zig");
const cheatsheet = @import("cheatsheet.zig");
const pty_pane = @import("pty_pane.zig");
const git_app = @import("git.zig");
const ai_app = @import("ai.zig");
const sessions_table = @import("sessions_table.zig");
const spend = @import("spend.zig");
const usage_pane = @import("usage_pane.zig");
const grep = @import("grep.zig");
const dap = @import("dap.zig");
const request_pane = @import("request_pane.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const script_pane = @import("script_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const ai_apply = @import("ai_apply.zig");
const tests_pane = @import("tests_pane.zig");
const flaky = @import("flaky.zig");
const requests_pane = @import("requests.zig");
const files_pane = @import("files_pane.zig");
const zon_pane = @import("zon_pane.zig");
const session_changes = @import("session_changes.zig");
const DocStore = @import("doc_store.zig").DocStore;
const accent_color = @import("../ui/accent_color.zig");

pub const PaneId = ids.PaneId;
pub const Buffer = buffer_mod.Buffer;
pub const PtyPane = pty_pane.PtyPane;
pub const RequestPane = request_pane.RequestPane;
pub const WebsocketPane = ws_pane.WebsocketPane;
pub const BrowserPane = browser_pane.BrowserPane;
pub const MountPane = mount_pane.MountPane;
pub const FilesPane = files_pane.FilesPane;
pub const ZonPane = zon_pane.ZonPane;

/// What the file watcher last saw on disk for an editor's file.
pub const DiskStamp = buffer_mod.DiskStamp;

pub const EditorPane = struct {
    buf: Buffer,
    view: editor_view.ViewState = .{},
    find: find.FindState,
    /// Per-pane wrap; null follows the config default.
    wrap: ?bool = null,
    /// The document's syntax state, owned by the app's `DocStore` and
    /// shared with every other pane on the same document; it goes when
    /// the document does, after this pane's buffer has let go.
    syntax: *syntax.Syntax,
    /// Where the visual block started (byte). The app records it when
    /// the handler enters V-BLOCK so `I` / `A` / `c` / `r` know their
    /// rectangle; the editor's own block ops are a later slice.
    block_anchor: ?usize = null,
    /// The location list (vim's per-window quickfix, `src/app/loclist.zig`):
    /// entries own their text and path on the buffer's gpa. `loc_idx` is
    /// the entry the last `:lnext` / `:lprev` landed on, null after a fill.
    loclist: std.ArrayListUnmanaged(ListPane.Entry) = .empty,
    loc_idx: ?usize = null,
    /// `buffer.pin_toggle`: the tab sits at the front of its strip with
    /// a pin glyph and survives close-others / close-right / close-all.
    /// Saved with the session.
    pinned: bool = false,
    /// VS Code's preview tab: a file the user is only glancing at. The
    /// name paints italic and the next glance in this leaf takes the
    /// tab over. A double-click (on the tree row or on the tab), the
    /// first edit, `view.keep_tab`, a pin and a drag all make it a
    /// tab of its own. Never saved with the session — a restored tab
    /// is one the user kept.
    preview: bool = false,
    /// A name for a buffer that is not a file — a frame's text fetched
    /// from a debug adapter (`dyld`start`) — where a pathless pane
    /// would say `[scratch]`. Owned on the buffer's gpa.
    label: ?[]u8 = null,
    /// The sticky context's chain for the last top line / text / parse
    /// (`sticky.headerLines`).
    sticky: sticky.Cache = .{},
    /// The indent step the guides were drawn with and the edit-log seq
    /// it was read at (`render.guideStep`); null until the first frame.
    guide_step: ?struct { seq: u64, step: u8 } = null,
    /// `buffer_change`'s debounce, per pane (`app/idle.zig`): the
    /// document's edit-log head as this pane last saw it (null until the
    /// first tick sees the pane — opening one is not an edit), when it
    /// last moved, and whether the hook still owes this edit.
    change_seen: ?u64 = null,
    change_at_ms: i64 = 0,
    change_pending: bool = false,

    pub fn deinit(self: *EditorPane) void {
        if (self.label) |l| self.buf.gpa.free(l);
        self.sticky.deinit(self.buf.gpa);
        ListPane.freeEntries(self.buf.gpa, self.loclist.items);
        self.loclist.deinit(self.buf.gpa);
        self.find.deinit();
        // Last: the document (and the syntax state with it) may go here.
        self.buf.deinit();
    }
};

pub const OutlinePane = outline.OutlinePane;
pub const MdPreviewPane = md_preview.MdPreviewPane;

/// A read-only list with a cursor: the `:` history (`q:`), the
/// quickfix list (`:cexpr`) and an editor's location list (`:lopen`).
/// Enter acts on the row by `kind`.
pub const ListPane = struct {
    /// // changed (git-more2): `stash_files` (a stash's files, Enter
    /// diffs one) and `git_log` (the worker's command log, Enter
    /// re-runs a read-only command) — both take a `/` filter.
    pub const Kind = enum { cmdline_history, search_history, quickfix, location, stash_files, git_log };
    pub const Entry = struct {
        /// Owned display text.
        text: []u8,
        /// Quickfix: where Enter goes. Workspace-relative, owned.
        path: ?[]u8 = null,
        line: u32 = 0,
        col: u32 = 0,
    };

    gpa: Allocator,
    kind: Kind,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Over the shown rows (`shown`): the entry index when no filter is set.
    cursor: usize = 0,
    scroll: usize = 0,
    /// The `/` filter (`kind.filters()`): a case-insensitive needle over
    /// the text; `filter_mode` while keys go to it.
    filter: std.ArrayListUnmanaged(u8) = .empty,
    filter_mode: bool = false,
    /// `search_history` from `q?`: Enter searches backward.
    reverse: bool = false,

    pub fn deinit(self: *ListPane) void {
        freeEntries(self.gpa, self.entries.items);
        self.entries.deinit(self.gpa);
        self.filter.deinit(self.gpa);
    }

    /// The kinds with a `/` filter.
    pub fn filters(kind: Kind) bool {
        return kind == .stash_files or kind == .git_log;
    }

    /// The entries the filter lets through, as indices (all of them
    /// while the filter is empty).
    pub fn shown(self: *const ListPane, arena: Allocator) Allocator.Error![]u32 {
        var out: std.ArrayListUnmanaged(u32) = .empty;
        for (self.entries.items, 0..) |e, i| {
            if (self.filter.items.len == 0 or std.ascii.indexOfIgnoreCase(e.text, self.filter.items) != null) try out.append(arena, @intCast(i));
        }
        return out.items;
    }

    /// The entry under shown row `row`.
    pub fn entryAt(self: *const ListPane, arena: Allocator, row: usize) Allocator.Error!?*const Entry {
        if (self.filter.items.len == 0) return if (row < self.entries.items.len) &self.entries.items[row] else null;
        const rows = try self.shown(arena);
        if (row >= rows.len) return null;
        return &self.entries.items[rows[row]];
    }

    pub fn shownCount(self: *const ListPane, arena: Allocator) Allocator.Error!usize {
        if (self.filter.items.len == 0) return self.entries.items.len;
        return (try self.shown(arena)).len;
    }

    /// Free what `entries` own (text and path) — for a list held
    /// outside a pane too (an editor's location list).
    pub fn freeEntries(gpa: Allocator, entries: []const Entry) void {
        for (entries) |e| {
            gpa.free(e.text);
            if (e.path) |p| gpa.free(p);
        }
    }

    pub fn title(self: *const ListPane) []const u8 {
        return switch (self.kind) {
            .cmdline_history => "cmdline history",
            .search_history => "search history",
            .quickfix => "Quickfix",
            .location => "Location",
            .stash_files => "stash files",
            .git_log => "git log",
        };
    }
};

pub const Pane = union(enum) {
    editor: EditorPane,
    /// The symbol list beside a source file.
    outline: OutlinePane,
    /// A rendered markdown file; typing on it swaps in the editor.
    md_preview: MdPreviewPane,
    /// An image file, drawn by the terminal over a placeholder.
    image: image_pane.ImagePane,
    cheatsheet: cheatsheet.State,
    list: ListPane,
    /// A shell or a command, painted from the ghostty-vt grid.
    pty: PtyPane,
    /// The git status rows as a pane (the rail's list when the rail is hidden).
    git_status: git_app.StatusPane,
    /// One diff: a file, the worktree, HEAD, the index, a commit.
    diff: git_app.DiffPane,
    /// The commit DAG of one repo.
    git_graph: git_app.GraphPane,
    /// An AI answer: the prompt and what the job streamed back.
    ai: ai_app.AiPane,
    /// The sessions table (one at a time; `sessions.table`).
    sessions_table: sessions_table.TablePane,
    /// The AI spend report (one at a time).
    spend_report: spend.SpendPane,
    /// The Claude / Codex usage pane (one per product).
    ai_usage: usage_pane.UsagePane,
    /// Workspace grep results (`find.grep`).
    grep: grep.GrepPane,
    /// The debugger's console pane (toolbar + output + evaluations).
    debug: dap.DebugPane,
    /// An HTTP request and its response (`http.new`, a `.curl` file).
    request: RequestPane,
    /// A persistent WebSocket connection (`ws.connect`).
    websocket: WebsocketPane,
    /// A Chrome driven over CDP (`browser.open`).
    browser: BrowserPane,
    /// A pane a script renders (`mnml.pane.open`).
    script: script_pane.ScriptPane,
    /// An integration hosted over a mount socket (`mount.open`, a manifest command).
    mount: MountPane,
    /// One integration's detail pane (one at a time).
    integrations: integrations.IntegrationsPane,
    /// An AI proposal reviewed hunk by hunk before it reaches the editor.
    ai_apply: ai_apply.AiApplyPane,
    /// A Playwright run's results (one at a time).
    tests: tests_pane.TestsPane,
    /// The flaky-test dashboard (one at a time).
    flaky: flaky.FlakyPane,
    /// What every integration has been asking an API for, and what it
    /// cost (one at a time).
    requests: requests_pane.RequestsPane,
    /// A directory listing (`files.open`); the trash is one too.
    files: FilesPane,
    /// A `.zon` file as a tree of fields, edited in place (`zon.view`).
    zon: ZonPane,
    /// // changed (sessiondiff): what one AI session changed since it
    /// started — the git status pane's component, scoped
    /// (`sessions.changes`, `app/session_changes.zig`).
    session_changes: session_changes.ChangesPane,

    /// `io` cancels the workers a dashboard pane owns before its arena goes.
    pub fn deinit(self: *Pane, gpa: Allocator, io: std.Io) void {
        switch (self.*) {
            .request => |*r| r.deinit(),
            .websocket => |*w| w.deinit(gpa),
            .browser => |*b| b.deinit(gpa),
            .script => |*s| s.deinit(gpa),
            .mount => |*m| m.deinit(gpa),
            .integrations => |*ip| ip.deinit(gpa),
            .ai_apply => |*a| a.deinit(),
            .tests => |*tp| tp.deinit(gpa, io),
            .flaky => |*fp| fp.deinit(),
            .requests => |*rp| rp.deinit(),
            .files => |*f| f.deinit(),
            .zon => |*z| z.deinit(),
            .session_changes => |*v| v.deinit(gpa),
            .editor => |*e| e.deinit(),
            .outline => |*o| o.deinit(),
            .md_preview => |*m| m.deinit(),
            .image => |*im| im.deinit(),
            .cheatsheet => |*c| c.deinit(),
            .list => |*l| l.deinit(),
            .pty => |*p| p.deinit(gpa),
            .git_status => {},
            .diff => |*d| d.deinit(),
            .git_graph => |*g| g.deinit(),
            .ai => |*a| a.deinit(),
            .sessions_table => |*tp| tp.deinit(),
            .spend_report => |*s| s.deinit(io),
            .ai_usage => {},
            .grep => |*g| g.deinit(io),
            .debug => {},
        }
    }

    /// The tab label: the file's basename, or `[scratch]`. A preview's
    /// tab is the bare filename too — it stands in for the file. A pty's
    /// is its label.
    pub fn title(self: *const Pane) []const u8 {
        switch (self.*) {
            .editor => |*e| return if (e.buf.doc.path) |p| std.fs.path.basename(p) else e.label orelse "[scratch]",
            .outline => |*o| return o.title,
            .md_preview => |*m| return std.fs.path.basename(m.path),
            .image => |*im| return im.tab_title,
            .cheatsheet => return "Cheatsheet",
            .list => |*l| return l.title(),
            .pty => |*p| return p.tabTitle(),
            .git_status => return "git status",
            .diff => |*d| return d.title,
            .git_graph => |*g| return g.name,
            .ai => |*a| return a.title,
            .sessions_table => return "Sessions",
            .spend_report => return "AI spend (24h)",
            .ai_usage => |*u| return u.title(),
            .grep => return "Search",
            .debug => return "Debug",
            .request => |*r| return r.title(),
            .websocket => |*w| return w.title(),
            .browser => |*b| return b.title(),
            .script => |*s| return s.title,
            .mount => |*m| return m.title(),
            .integrations => |*ip| return ip.title(),
            .ai_apply => |*a| return if (a.ide) |d| d.tab_name else "ai.apply",
            .tests => |*tp| return tp.title(),
            .flaky => |*fp| return fp.title(),
            .requests => |*rp| return rp.title(),
            .files => |*f| return f.title(),
            .zon => |*z| return z.title(),
            .session_changes => |*v| return v.title,
        }
    }

    pub fn dirty(self: *const Pane) bool {
        return switch (self.*) {
            .editor => |*e| e.buf.doc.dirty,
            .zon => |*z| z.changed,
            .outline, .md_preview, .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .sessions_table, .spend_report, .ai_usage, .grep, .debug, .request, .websocket, .browser, .script, .mount, .integrations, .ai_apply, .tests, .flaky, .requests, .files, .session_changes => false,
        };
    }

    /// // changed (pane-rail): this pane's rail wears somebody else's
    /// identity colour rather than a slot off the shared ladder — a
    /// mounted integration's app colour, which it already wears on its
    /// chip, its rail row and its tab. It takes no ladder slot, and
    /// `pane_accent.colorOf` paints it from the owner. A git pane is
    /// NOT one of these: it prefers its repo's accent when the
    /// workspace has more than one repo to tell apart, and falls back
    /// to its own slot when there is nothing to tell apart.
    pub fn wearsOwnAccent(self: *const Pane) bool {
        return switch (self.*) {
            .mount => |*m| m.integration != null,
            else => false,
        };
    }

    /// `buffer.pin_toggle` set it: a pinned editor tab.
    pub fn pinned(self: *const Pane) bool {
        return switch (self.*) {
            .editor => |*e| e.pinned,
            else => false,
        };
    }

    /// A preview tab (VS Code's): opened by a glance, painted italic,
    /// and taken over by the next glance in the same leaf. The four
    /// kinds a glance can land on carry the flag; everything else is
    /// always a tab of its own.
    pub fn preview(self: *const Pane) bool {
        return switch (self.*) {
            .editor => |*e| e.preview,
            .md_preview => |*m| m.is_preview,
            .image => |*im| im.is_preview,
            .request => |*r| r.is_preview,
            else => false,
        };
    }

    /// Set (or clear) the preview flag on the kinds that carry one.
    pub fn setPreview(self: *Pane, on: bool) void {
        switch (self.*) {
            .editor => |*e| e.preview = on,
            .md_preview => |*m| m.is_preview = on,
            .image => |*im| im.is_preview = on,
            .request => |*r| r.is_preview = on,
            else => {},
        }
    }

    pub fn asEditor(self: *Pane) ?*EditorPane {
        return switch (self.*) {
            .editor => |*e| e,
            else => null,
        };
    }

    pub fn asOutline(self: *Pane) ?*OutlinePane {
        return switch (self.*) {
            .outline => |*o| o,
            else => null,
        };
    }

    pub fn asMdPreview(self: *Pane) ?*MdPreviewPane {
        return switch (self.*) {
            .md_preview => |*m| m,
            else => null,
        };
    }

    pub fn asRequest(self: *Pane) ?*RequestPane {
        return switch (self.*) {
            .request => |*r| r,
            else => null,
        };
    }

    pub fn asWebsocket(self: *Pane) ?*WebsocketPane {
        return switch (self.*) {
            .websocket => |*w| w,
            else => null,
        };
    }

    pub fn asBrowser(self: *Pane) ?*BrowserPane {
        return switch (self.*) {
            .browser => |*b| b,
            else => null,
        };
    }

    pub fn asMount(self: *Pane) ?*MountPane {
        return switch (self.*) {
            .mount => |*m| m,
            else => null,
        };
    }

    pub fn asFiles(self: *Pane) ?*FilesPane {
        return switch (self.*) {
            .files => |*f| f,
            else => null,
        };
    }

    pub fn asZon(self: *Pane) ?*ZonPane {
        return switch (self.*) {
            .zon => |*z| z,
            else => null,
        };
    }

    pub fn asPty(self: *Pane) ?*PtyPane {
        return switch (self.*) {
            .pty => |*p| p,
            else => null,
        };
    }
};

/// Panes by stable id. Slots freed by `remove` go on a free list and are
/// reused, so ids are dense but never shift under a live overlay.
/// // changed: `Pane.deinit(gpa)` had no io; the agents and spend panes
/// own an `Io.Group` each and must cancel it before their arena goes, so
/// the store carries the io it was made with.
pub const PaneStore = struct {
    gpa: Allocator,
    io: std.Io,
    slots: std.ArrayListUnmanaged(?Pane) = .empty,
    free: std.ArrayListUnmanaged(PaneId) = .empty,
    /// // changed (pane-rail): the accent every pane that is not a pty
    /// wears on its rail, by pane id — a palette name from
    /// `ui/accent_color.zig`, owned here, dropped when the pane closes
    /// so the colour is free for the next one. A pty keeps its own in
    /// `PtyPane.accent_color`, which the SESSIONS surfaces and the
    /// session file already read; `app/pane_accent.zig` is the one
    /// accessor over both.
    accents: std.ArrayListUnmanaged(?[]u8) = .empty,

    pub fn init(gpa: Allocator, io: std.Io) PaneStore {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *PaneStore) void {
        for (self.slots.items) |*slot| if (slot.*) |*p| p.deinit(self.gpa, self.io);
        for (self.accents.items) |a| if (a) |name| self.gpa.free(name);
        self.accents.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
    }

    /// The accent stored for a non-pty pane, a palette name; null when
    /// it has none yet. Read through `app/pane_accent.zig`, never here.
    pub fn accent(self: *const PaneStore, id: PaneId) ?[]const u8 {
        if (id >= self.accents.items.len) return null;
        return self.accents.items[id];
    }

    /// Give a non-pty pane an accent (null clears it). Takes a copy.
    pub fn setAccent(self: *PaneStore, id: PaneId, name: ?[]const u8) Allocator.Error!void {
        if (id >= self.slots.items.len) return;
        const fresh: ?[]u8 = if (name) |n| try self.gpa.dupe(u8, n) else null;
        errdefer if (fresh) |f| self.gpa.free(f);
        while (self.accents.items.len <= id) try self.accents.append(self.gpa, null);
        if (self.accents.items[id]) |old| self.gpa.free(old);
        self.accents.items[id] = fresh;
    }

    /// Takes ownership of `pane`. // changed (pane-rail): the pane also
    /// takes its rail colour here — the one place every kind is opened,
    /// so no caller has to remember to ask for one.
    pub fn add(self: *PaneStore, pane: Pane) Allocator.Error!PaneId {
        const id: PaneId = if (self.free.pop()) |reused| blk: {
            self.slots.items[reused] = pane;
            break :blk reused;
        } else blk: {
            const fresh: PaneId = @intCast(self.slots.items.len);
            try self.slots.append(self.gpa, pane);
            break :blk fresh;
        };
        // The pane is in the store before it is given a colour: the
        // accent table is keyed by id and will not hold one for a slot
        // that does not exist yet.
        try self.assignAccent(id, &self.slots.items[id].?);
        return id;
    }

    /// The rail colour a pane opens with: the first palette name no
    /// live pane is wearing, so two terminals are never the same colour
    /// while both are open (`accent_color.firstFree`). A pane that
    /// already has one — a resumed session's remembered colour — keeps
    /// it, and a pane that wears somebody else's identity (an
    /// integration's app colour, a repo's) takes no ladder slot.
    pub fn assignAccent(self: *PaneStore, id: PaneId, p: *Pane) Allocator.Error!void {
        if (p.wearsOwnAccent()) return;
        const current: ?[]const u8 = if (p.* == .pty) p.pty.accent_color else self.accent(id);
        if (current != null) return;
        const taken = try self.gpa.alloc(?[]const u8, self.slots.items.len);
        defer self.gpa.free(taken);
        var live: usize = 0;
        for (self.slots.items, 0..) |*slot, i| {
            taken[i] = null;
            if (slot.*) |*other| {
                live += 1;
                if (other.wearsOwnAccent()) continue;
                taken[i] = if (other.* == .pty) other.pty.accent_color else self.accent(@intCast(i));
            }
        }
        const name = accent_color.firstFree(taken, live);
        if (p.* == .pty) {
            p.pty.accent_color = try self.gpa.dupe(u8, name);
        } else {
            try self.setAccent(id, name);
        }
    }

    /// The id the next `add` will hand out — for a pane that must know
    /// its own id before it exists (a pty's reader wire).
    pub fn peekId(self: *const PaneStore) PaneId {
        if (self.free.items.len > 0) return self.free.items[self.free.items.len - 1];
        return @intCast(self.slots.items.len);
    }

    pub fn get(self: *PaneStore, id: PaneId) ?*Pane {
        if (id >= self.slots.items.len) return null;
        return if (self.slots.items[id]) |*p| p else null;
    }

    pub fn editor(self: *PaneStore, id: PaneId) ?*EditorPane {
        const p = self.get(id) orelse return null;
        return p.asEditor();
    }

    pub fn pty(self: *PaneStore, id: PaneId) ?*PtyPane {
        const p = self.get(id) orelse return null;
        return p.asPty();
    }

    pub fn remove(self: *PaneStore, id: PaneId) void {
        if (id >= self.slots.items.len) return;
        if (self.slots.items[id]) |*p| {
            p.deinit(self.gpa, self.io);
            self.slots.items[id] = null;
            // The pane's rail colour goes back on the ladder for the
            // next pane to take (`pane_accent.assign`).
            if (id < self.accents.items.len) if (self.accents.items[id]) |a| {
                self.gpa.free(a);
                self.accents.items[id] = null;
            };
            self.free.append(self.gpa, id) catch {};
        }
    }

    /// Live panes.
    pub fn count(self: *const PaneStore) usize {
        return self.slots.items.len - self.free.items.len;
    }

    /// One past the highest id ever handed out.
    pub fn capacity(self: *const PaneStore) usize {
        return self.slots.items.len;
    }

    /// The editor pane whose file is `path`, if open.
    pub fn findPath(self: *PaneStore, path: []const u8) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .editor => |*e| if (e.buf.doc.path) |bp| {
                    if (@import("../core/os_path.zig").samePath(bp, path)) return @intCast(i);
                },
                else => {},
            };
        }
        return null;
    }

    /// Any pane showing `path` — an editor first (it is the one a
    /// glance means when a file has both an editor and a rendered
    /// preview open), then the three view kinds.
    pub fn findShowing(self: *PaneStore, path: []const u8) ?PaneId {
        if (self.findPath(path)) |id| return id;
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .md_preview => |*m| if (@import("../core/os_path.zig").samePath(m.path, path)) return @intCast(i),
                .image => |*im| if (std.mem.eql(u8, im.path, path)) return @intCast(i),
                .request => |*r| if (r.source_path) |sp| {
                    if (std.mem.eql(u8, sp, path)) return @intCast(i);
                },
                else => {},
            };
        }
        return null;
    }

    /// The markdown preview of `path`, if one is open.
    pub fn findPreview(self: *PaneStore, path: []const u8) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .md_preview => |*m| if (@import("../core/os_path.zig").samePath(m.path, path)) return @intCast(i),
                else => {},
            };
        }
        return null;
    }

    /// The image preview tab, if one is open — the next image replaces it.
    /// The markdown tab a glance may take over (`md_preview.open`).
    pub fn findMdGlance(self: *PaneStore) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .md_preview => |*m| if (m.is_preview) return @intCast(i),
                else => {},
            };
        }
        return null;
    }

    pub fn findImagePreview(self: *PaneStore) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .image => |*im| if (im.is_preview) return @intCast(i),
                else => {},
            };
        }
        return null;
    }

    /// The outline pane watching `source`, if one is open.
    pub fn findOutline(self: *PaneStore, source: PaneId) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| switch (p.*) {
                .outline => |*o| if (o.source == source) return @intCast(i),
                else => {},
            };
        }
        return null;
    }

    /// The one pane of `tag` (a singleton pane like the cheatsheet), if open.
    pub fn findKind(self: *PaneStore, tag: std.meta.Tag(Pane)) ?PaneId {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.*) |*p| if (std.meta.activeTag(p.*) == tag) return @intCast(i);
        }
        return null;
    }
};

test "pane store: stable ids, free-list reuse, path lookup" {
    const gpa = std.testing.allocator;
    const docs = try DocStore.create(gpa);
    defer docs.destroy();
    var store = PaneStore.init(gpa, std.testing.io);
    defer store.deinit();
    const mk = struct {
        fn pane(g: Allocator, ds: *DocStore, path: []const u8) !Pane {
            var buf = try Buffer.init(g, "x", .standard, .{});
            errdefer buf.deinit();
            try buf.setPath(path);
            const entry = try ds.adopt(buf.doc);
            return .{ .editor = .{ .buf = buf, .find = find.FindState.init(g), .syntax = &entry.syntax } };
        }
    };
    try std.testing.expectEqual(@as(PaneId, 0), store.peekId());
    const a = try store.add(try mk.pane(gpa, docs, "/ws/a.txt"));
    const b = try store.add(try mk.pane(gpa, docs, "/ws/b.txt"));
    try std.testing.expectEqual(@as(PaneId, 0), a);
    try std.testing.expectEqual(@as(PaneId, 1), b);
    try std.testing.expectEqualStrings("b.txt", store.get(b).?.title());
    try std.testing.expectEqual(a, store.findPath("/ws/a.txt").?);
    store.remove(a);
    try std.testing.expect(store.get(a) == null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(a, store.peekId());
    const c = try store.add(try mk.pane(gpa, docs, "/ws/c.txt"));
    try std.testing.expectEqual(a, c);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}
