//! Current-line blame (`editor.line_blame`, GitLens's opt-in): dim text
//! at the end of the cursor's line — `  author · 3d ago · summary` —
//! from `git blame -L n,n --porcelain` for that line.
//!
//! Git runs on the repo's worker (`client.Job.blame_line`), never on the
//! UI thread: the ask goes out when the cursor has rested
//! (`idle.cursor_idle_ms`), one at a time, and the answer lands as a
//! `.git` event (`handle`). Answers are cached per (file, text version,
//! HEAD, line) — the text version is the document's edit-log head, so
//! an edit drops what was cached for the file (`dropStale`) and a
//! commit (a new HEAD) asks again. Nothing paints while the buffer has
//! unsaved changes (git blames the file on disk, whose lines are not
//! the buffer's) or for a line git calls not committed yet.
//!
//! The text is a `Doc.virtual_text` entry, painted by the same path an
//! inlay hint takes. It registers `.script_hit{pane, hit_id}`: a click
//! opens the commit in the graph (`git.graph`, the cursor on that sha),
//! and the pointer on it reads the commit in the info view.
//!
//! Every string the cache keeps is its own, on the gpa: an entry
//! outlives the worker's result arena and every frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const client = @import("../git/client.zig");
const parse = @import("../git/parse.zig");
const git = @import("git.zig");
const editor_view = @import("../ui/editor_view.zig");
const Theme = @import("../ui/theme.zig");

/// The `.script_hit` id the blame text registers in its editor pane.
/// Outside the ranges the pane's other script hits use (`{{VAR}}` spans
/// from `editor_view.var_hit_base`, code lenses from
/// `lsp_decor.lens_hit_base`, the debug toolbar's and the conflict
/// blocks' own ids).
pub const hit_id: u32 = 0x424C_4D00;

/// How many lines' answers are kept, oldest dropped first.
const max_entries = 64;

pub const Entry = struct {
    path: []u8,
    /// 0-based.
    line: u32,
    /// The document's edit-log head the ask was made at.
    seq: u64,
    /// HEAD's oid when asked; empty when the status had not said.
    head: []u8,
    /// Empty when git had no answer (an untracked file): cached too, so
    /// the next rest on the line does not ask again.
    sha: []u8,
    author: []u8,
    summary: []u8,
    time: i64,

    fn deinit(e: Entry, gpa: Allocator) void {
        gpa.free(e.path);
        gpa.free(e.head);
        gpa.free(e.sha);
        gpa.free(e.author);
        gpa.free(e.summary);
    }

    fn answered(e: Entry) bool {
        if (e.sha.len == 0) return false;
        for (e.sha) |c| if (c != '0') return true;
        return false;
    }
};

/// The one ask in flight.
const Pending = struct { path: []u8, line: u32, seq: u64, head: []u8 };

pub const State = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    pending: ?Pending = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (self.entries.items) |e| e.deinit(gpa);
        self.entries.deinit(gpa);
        if (self.pending) |p| freePending(gpa, p);
    }
};

fn freePending(gpa: Allocator, p: Pending) void {
    gpa.free(p.path);
    gpa.free(p.head);
}

/// HEAD's oid for `repo`, when the status snapshot is that repo's.
fn headOf(app: *App, repo: *const client.Repo) []const u8 {
    const st = &app.git;
    if (st.status_repo != repo.id) return "";
    const s = st.status orelse return "";
    return s.oid orelse "";
}

/// The repo that holds `abs`: the deepest known root it sits under,
/// else the active repo the way every git command finds one (which
/// discovers again when there is none yet — a repo made after launch).
fn repoOf(app: *App, abs: []const u8) Allocator.Error!?*client.Repo {
    if (!app.git.discovered) try git.discover(app);
    var best: ?*client.Repo = null;
    for (app.git.repos.items) |r| {
        const under = std.mem.startsWith(u8, abs, r.path) and abs.len > r.path.len and abs[r.path.len] == '/';
        if (under and (best == null or r.path.len > best.?.path.len)) best = r;
    }
    if (best) |b| return b;
    return git.requireRepo(app) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn find(st: *const State, path: []const u8, line: u32, seq: u64, head: []const u8) ?*const Entry {
    for (st.entries.items) |*e| {
        if (e.line == line and e.seq == seq and std.mem.eql(u8, e.path, path) and std.mem.eql(u8, e.head, head)) return e;
    }
    return null;
}

/// The cached answer for `e`'s cursor line, when there is a current one.
fn current(app: *App, e: *EditorPane) Allocator.Error!?*const Entry {
    const path = e.buf.doc.path orelse return null;
    if (e.buf.doc.dirty) return null;
    const repo = (try repoOf(app, path)) orelse return null;
    return find(&app.git.line_blame, path, @intCast(e.buf.editor.currentLine()), e.buf.doc.edits.head(), headOf(app, repo));
}

/// Ask for `pane`'s cursor line unless it is cached, asked, or not
/// something git can answer. The worker's job owns the path it is
/// handed.
pub fn request(app: *App, pane: PaneId) CommandError!void {
    if (!app.cfg.editor.line_blame) return;
    const st = &app.git.line_blame;
    if (st.pending != null) return;
    const e = app.panes.editor(pane) orelse return;
    const path = e.buf.doc.path orelse return;
    if (e.buf.doc.dirty) return;
    const repo = (try repoOf(app, path)) orelse return;
    const line: u32 = @intCast(e.buf.editor.currentLine());
    const seq = e.buf.doc.edits.head();
    const head = headOf(app, repo);
    if (find(st, path, line, seq, head) != null) return;
    const gpa = app.gpa;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const owned_head = try gpa.dupe(u8, head);
    errdefer gpa.free(owned_head);
    const rel = try gpa.dupe(u8, git.relToRepo(repo, path));
    const p: Pending = .{ .path = owned_path, .line = line, .seq = seq, .head = owned_head };
    st.pending = p;
    // `submit` frees the job (and `rel` with it) when it cannot queue it.
    git.submit(app, repo, .{ .blame_line = .{ .path = rel, .line = line + 1 } }) catch |err| {
        st.pending = null;
        return err;
    };
}

/// `idle.tick`'s cursor rest: the line the cursor stopped on.
pub fn onCursorIdle(app: *App, pane: PaneId) void {
    request(app, pane) catch {};
}

/// An edit to `pane`'s document: what was cached for its file answers
/// for text that is gone.
pub fn dropStale(app: *App, pane: PaneId) void {
    const e = app.panes.editor(pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const seq = e.buf.doc.edits.head();
    const st = &app.git.line_blame;
    var i: usize = 0;
    while (i < st.entries.items.len) {
        const en = st.entries.items[i];
        if (en.seq != seq and std.mem.eql(u8, en.path, path)) {
            en.deinit(app.gpa);
            _ = st.entries.orderedRemove(i);
        } else i += 1;
    }
}

/// The worker's answer. It is cached against what the ask was made
/// at, then the active pane's cursor line is asked for if the cursor
/// moved on while git ran.
pub fn handle(app: *App, repo: *client.Repo, path: []const u8, line: u32, blame: ?parse.BlameLine) Allocator.Error!void {
    const st = &app.git.line_blame;
    const gpa = app.gpa;
    const p = st.pending orelse return;
    st.pending = null;
    if (p.line + 1 != line or !std.mem.eql(u8, git.relToRepo(repo, p.path), path)) {
        freePending(gpa, p);
        return;
    }
    errdefer freePending(gpa, p);
    const b: parse.BlameLine = blame orelse .{ .sha = "", .author = "" };
    const sha = try gpa.dupe(u8, b.sha);
    errdefer gpa.free(sha);
    const author = try gpa.dupe(u8, b.author);
    errdefer gpa.free(author);
    const summary = try gpa.dupe(u8, b.summary);
    errdefer gpa.free(summary);
    try st.entries.ensureUnusedCapacity(gpa, 1);
    if (st.entries.items.len >= max_entries) st.entries.orderedRemove(0).deinit(gpa);
    st.entries.appendAssumeCapacity(.{ .path = p.path, .line = p.line, .seq = p.seq, .head = p.head, .sha = sha, .author = author, .summary = summary, .time = b.time });
    app.needs_render = true;
    if (app.active) |a| request(app, a) catch {};
}

/// `  author · 3d ago · summary` at the end of `e`'s cursor line, when
/// `pane` is the active editor and git has answered for that line.
pub fn virtualTextFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]const editor_view.VirtualText {
    if (!app.cfg.editor.line_blame or app.active != pane) return &.{};
    const en = (try current(app, e)) orelse return &.{};
    if (!en.answered()) return &.{};
    var age_buf: [16]u8 = undefined;
    const age = parse.relativeAge(&age_buf, en.time, git.nowUnix(app));
    const text = if (age.len > 0)
        try std.fmt.allocPrint(arena, "  {s} · {s} ago · {s}", .{ en.author, age, en.summary })
    else
        try std.fmt.allocPrint(arena, "  {s} · {s}", .{ en.author, en.summary });
    var style = theme.muted;
    style.dim = true;
    const out = try arena.alloc(editor_view.VirtualText, 1);
    out[0] = .{ .byte = e.buf.editor.lineEnd(e.buf.editor.currentLine()), .text = text, .style = style, .hit = hit_id };
    return out;
}

/// A press on the blame text: the commit, in the graph.
pub fn click(app: *App, pane: PaneId) CommandError!void {
    const e = app.panes.editor(pane) orelse return;
    const en = (try current(app, e)) orelse return;
    if (!en.answered()) return;
    try git.openCommitInGraph(app, en.sha);
}

/// `git.toggle_line_blame`: on asks for the cursor's line at once.
pub fn toggle(app: *App) CommandError!void {
    app.cfg.editor.line_blame = !app.cfg.editor.line_blame;
    app.toast("line blame {s}", .{if (app.cfg.editor.line_blame) "on" else "off"});
    app.needs_render = true;
    if (app.cfg.editor.line_blame) if (app.active) |a| try request(app, a);
}

/// The info view's words for the pointer on the blame text.
pub fn hoverTitle(app: *App, arena: Allocator, pane: PaneId) Allocator.Error!?[]const u8 {
    const e = app.panes.editor(pane) orelse return null;
    const en = (try current(app, e)) orelse return null;
    if (!en.answered()) return null;
    return try std.fmt.allocPrint(arena, "Blame: {s} {s}", .{ en.sha[0..@min(7, en.sha.len)], en.summary });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "an entry with no sha or an all-zero one is not an answer" {
    const e: Entry = .{ .path = @constCast("p"), .line = 0, .seq = 0, .head = @constCast(""), .sha = @constCast(""), .author = @constCast(""), .summary = @constCast(""), .time = 0 };
    try testing.expect(!e.answered());
    var z = e;
    z.sha = @constCast("0000000000000000000000000000000000000000");
    try testing.expect(!z.answered());
    z.sha = @constCast("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678");
    try testing.expect(z.answered());
}
