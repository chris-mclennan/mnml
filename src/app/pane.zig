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
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const image_pane = @import("image_pane.zig");
const cheatsheet = @import("cheatsheet.zig");
const pty_pane = @import("pty_pane.zig");
const git_app = @import("git.zig");
const ai_app = @import("ai.zig");
const agents = @import("agents.zig");
const spend = @import("spend.zig");
const grep = @import("grep.zig");
const dap = @import("dap.zig");
const request_pane = @import("request_pane.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const script_pane = @import("script_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const marketplace = @import("marketplace.zig");
const ai_apply = @import("ai_apply.zig");
const tests_pane = @import("tests_pane.zig");
const flaky = @import("flaky.zig");
const files_pane = @import("files_pane.zig");

pub const PaneId = ids.PaneId;
pub const Buffer = buffer_mod.Buffer;
pub const PtyPane = pty_pane.PtyPane;
pub const RequestPane = request_pane.RequestPane;
pub const WebsocketPane = ws_pane.WebsocketPane;
pub const BrowserPane = browser_pane.BrowserPane;
pub const MountPane = mount_pane.MountPane;
pub const FilesPane = files_pane.FilesPane;

/// What the file watcher last saw on disk for an editor's file.
pub const DiskStamp = struct { mtime_ns: i128, size: u64 };

pub const EditorPane = struct {
    buf: Buffer,
    view: editor_view.ViewState = .{},
    find: find.FindState,
    /// Per-pane wrap; null follows the config default.
    wrap: ?bool = null,
    syntax: syntax.Syntax,
    /// Set by every path that mutates the text; the syntax cache
    /// re-parses once `syntax.idle_ms` have passed since the frame that
    /// first saw it (`hl_since_ms`), so a burst of typing costs one parse.
    hl_dirty: bool = true,
    hl_since_ms: ?i64 = null,
    /// Where the visual block started (byte). The app records it when
    /// the handler enters V-BLOCK so `I` / `A` / `c` / `r` know their
    /// rectangle; the editor's own block ops are a later slice.
    block_anchor: ?usize = null,
    /// The file's mtime + size when it was last read or written; the
    /// watcher compares against it every 2 s. Null for a scratch buffer.
    disk: ?DiskStamp = null,
    /// The location list (vim's per-window quickfix, `src/app/loclist.zig`):
    /// entries own their text and path on the buffer's gpa. `loc_idx` is
    /// the entry the last `:lnext` / `:lprev` landed on, null after a fill.
    loclist: std.ArrayListUnmanaged(ListPane.Entry) = .empty,
    loc_idx: ?usize = null,

    pub fn deinit(self: *EditorPane) void {
        ListPane.freeEntries(self.buf.gpa, self.loclist.items);
        self.loclist.deinit(self.buf.gpa);
        self.buf.deinit();
        self.find.deinit();
        self.syntax.deinit();
    }
};

pub const OutlinePane = outline.OutlinePane;
pub const MdPreviewPane = md_preview.MdPreviewPane;

/// A read-only list with a cursor: the `:` history (`q:`), the
/// quickfix list (`:cexpr`) and an editor's location list (`:lopen`).
/// Enter acts on the row by `kind`.
pub const ListPane = struct {
    pub const Kind = enum { cmdline_history, quickfix, location };
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
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *ListPane) void {
        freeEntries(self.gpa, self.entries.items);
        self.entries.deinit(self.gpa);
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
            .quickfix => "Quickfix",
            .location => "Location",
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
    /// The Claude Agents dashboard (one at a time).
    claude_agents: agents.AgentsPane,
    /// The AI spend report (one at a time).
    spend_report: spend.SpendPane,
    /// Workspace grep results (`find.grep`).
    grep: grep.GrepPane,
    /// The debugger: call stack, variables + watches, output.
    debug: dap.DebugPane,
    /// The debugger's REPL.
    dap_repl: dap.DapReplPane,
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
    /// The installed integrations (one at a time).
    integrations: integrations.IntegrationsPane,
    /// What can be installed (one at a time).
    marketplace: marketplace.MarketplacePane,
    /// An AI proposal reviewed hunk by hunk before it reaches the editor.
    ai_apply: ai_apply.AiApplyPane,
    /// A Playwright run's results (one at a time).
    tests: tests_pane.TestsPane,
    /// The flaky-test dashboard (one at a time).
    flaky: flaky.FlakyPane,
    /// A directory listing (`files.open`); the trash is one too.
    files: FilesPane,

    /// `io` cancels the workers a dashboard pane owns before its arena goes.
    pub fn deinit(self: *Pane, gpa: Allocator, io: std.Io) void {
        switch (self.*) {
            .request => |*r| r.deinit(),
            .websocket => |*w| w.deinit(gpa),
            .browser => |*b| b.deinit(gpa),
            .script => |*s| s.deinit(gpa),
            .mount => |*m| m.deinit(gpa),
            .integrations, .marketplace => {},
            .ai_apply => |*a| a.deinit(),
            .tests => |*tp| tp.deinit(gpa, io),
            .flaky => |*fp| fp.deinit(),
            .files => |*f| f.deinit(),
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
            .claude_agents => |*a| a.deinit(io),
            .spend_report => |*s| s.deinit(io),
            .grep => |*g| g.deinit(io),
            .debug => {},
            .dap_repl => |*r| r.deinit(),
        }
    }

    /// The tab label: the file's basename, or `[scratch]`. A preview's
    /// tab is the bare filename too — it stands in for the file. A pty's
    /// is its label.
    pub fn title(self: *const Pane) []const u8 {
        switch (self.*) {
            .editor => |*e| return if (e.buf.path) |p| std.fs.path.basename(p) else "[scratch]",
            .outline => |*o| return o.title,
            .md_preview => |*m| return std.fs.path.basename(m.path),
            .image => |*im| return im.tab_title,
            .cheatsheet => return "Cheatsheet",
            .list => |*l| return l.title(),
            .pty => |*p| return p.label,
            .git_status => return "git status",
            .diff => |*d| return d.title,
            .git_graph => return "git graph",
            .ai => |*a| return a.title,
            .claude_agents => return "Claude Agents",
            .spend_report => return "AI spend (24h)",
            .grep => return "Search",
            .debug => return "Debug",
            .dap_repl => return "DAP REPL",
            .request => |*r| return r.title(),
            .websocket => |*w| return w.title(),
            .browser => |*b| return b.title(),
            .script => |*s| return s.title,
            .mount => |*m| return m.title(),
            .integrations => return "Integrations",
            .marketplace => return "Marketplace",
            .ai_apply => return "ai.apply",
            .tests => |*tp| return tp.title(),
            .flaky => |*fp| return fp.title(),
            .files => |*f| return f.title(),
        }
    }

    pub fn dirty(self: *const Pane) bool {
        return switch (self.*) {
            .editor => |*e| e.buf.dirty,
            .outline, .md_preview, .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .grep, .debug, .dap_repl, .request, .websocket, .browser, .script, .mount, .integrations, .marketplace, .ai_apply, .tests, .flaky, .files => false,
        };
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

    pub fn init(gpa: Allocator, io: std.Io) PaneStore {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *PaneStore) void {
        for (self.slots.items) |*slot| if (slot.*) |*p| p.deinit(self.gpa, self.io);
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
    }

    /// Takes ownership of `pane`.
    pub fn add(self: *PaneStore, pane: Pane) Allocator.Error!PaneId {
        if (self.free.pop()) |id| {
            self.slots.items[id] = pane;
            return id;
        }
        const id: PaneId = @intCast(self.slots.items.len);
        try self.slots.append(self.gpa, pane);
        return id;
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
                .editor => |*e| if (e.buf.path) |bp| {
                    if (std.mem.eql(u8, bp, path)) return @intCast(i);
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
                .md_preview => |*m| if (std.mem.eql(u8, m.path, path)) return @intCast(i),
                else => {},
            };
        }
        return null;
    }

    /// The image preview tab, if one is open — the next image replaces it.
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
    var store = PaneStore.init(gpa, std.testing.io);
    defer store.deinit();
    const mk = struct {
        fn pane(g: Allocator, path: []const u8) !Pane {
            var buf = try Buffer.init(g, "x", .standard, .{});
            errdefer buf.deinit();
            try buf.setPath(path);
            return .{ .editor = .{ .buf = buf, .find = find.FindState.init(g), .syntax = syntax.Syntax.init(g) } };
        }
    };
    try std.testing.expectEqual(@as(PaneId, 0), store.peekId());
    const a = try store.add(try mk.pane(gpa, "/ws/a.txt"));
    const b = try store.add(try mk.pane(gpa, "/ws/b.txt"));
    try std.testing.expectEqual(@as(PaneId, 0), a);
    try std.testing.expectEqual(@as(PaneId, 1), b);
    try std.testing.expectEqualStrings("b.txt", store.get(b).?.title());
    try std.testing.expectEqual(a, store.findPath("/ws/a.txt").?);
    store.remove(a);
    try std.testing.expect(store.get(a) == null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(a, store.peekId());
    const c = try store.add(try mk.pane(gpa, "/ws/c.txt"));
    try std.testing.expectEqual(a, c);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}
