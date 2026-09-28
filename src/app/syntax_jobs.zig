//! Parsing off the UI thread. A document large enough that a parse is
//! felt (`Syntax.worker_min_bytes`) is never parsed by the frame that
//! paints it: the frame hands a worker an immutable copy of the text
//! (and, for a reparse, a copy of the kept tree — `ts_tree_copy` shares
//! the nodes) and goes on painting with what it has — the kept tree,
//! told of every edit since, or nothing yet for a file just opened.
//! The worker posts `.syntax = *Result`; `handle` adopts the tree, tells
//! it of the edits made while it was being parsed, and asks for another
//! pass if there were any.
//!
//! One job per document at a time. A parse is not abandoned because the
//! text moved on — it is finished, caught up with `ts_tree_edit`, and
//! followed by a (much cheaper) incremental one — so typing through an
//! eight-second first parse still ends with a tree eight seconds in.
//! It IS abandoned when what it was parsing is gone: the document
//! closed, the grammar changed, the edit log lost track.
//!
//! D3: the worker is a task in `State.group`; `error.Canceled` ends it
//! and is propagated, never swallowed. The worker owns its job — text,
//! tree copy, parser — until it posts, and frees all of it itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const highlight = @import("highlight");
const ts = highlight.ts;
const table = highlight.table;
const event = @import("../core/event.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const syntax_mod = @import("syntax.zig");
const Syntax = syntax_mod.Syntax;
const Document = @import("../editor/editor.zig").Document;
const mem_report = @import("../core/mem_report.zig");

/// Shared by the document's `Syntax` and the worker: the way to tell a
/// parse that nobody wants its tree any more. Two holders, freed by the
/// second to let go.
pub const Ticket = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(2),

    pub fn release(t: *Ticket, gpa: Allocator) void {
        if (t.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(t);
    }
};

/// What the worker posts. `tree` is null when the parse was abandoned or
/// could not run. Owned by the event; `handle` adopts the tree.
pub const Result = struct {
    id: u64,
    tree: ?*ts.Tree,

    pub fn destroy(r: *Result, gpa: Allocator) void {
        if (r.tree) |t| t.deinit();
        gpa.destroy(r);
    }
};

pub const State = struct {
    group: Io.Group = .init,
    next_id: u64 = 1,
    /// Jobs handed to a worker since the app started — what a test
    /// reads to show that a motion started none.
    started: u64 = 0,

    pub fn deinit(self: *State, io: Io) void {
        self.group.cancel(io);
    }
};

const Job = struct {
    id: u64,
    entry: usize,
    text: []u8,
    old: ?*ts.Tree,
    ticket: *Ticket,
    io: Io,
    /// Made by `start`, so the worker has nothing to allocate and always
    /// has something to post. Null once posted.
    result: ?*Result,

    fn destroy(j: *Job, gpa: Allocator) void {
        if (j.result) |r| r.destroy(gpa);
        if (j.old) |t| t.deinit();
        gpa.free(j.text);
        j.ticket.release(gpa);
        gpa.destroy(j);
    }

    fn keepGoing(p: ?*anyopaque) bool {
        const j: *Job = @ptrCast(@alignCast(p.?));
        if (j.ticket.cancel.load(.acquire)) return false;
        // The group being cancelled (the app is going) ends it too; the
        // cancel is re-armed for the worker to report.
        j.io.checkCancel() catch {
            j.io.recancel();
            return false;
        };
        return true;
    }
};

/// Hand `s`'s document to a worker: the text as it is now, and the kept
/// tree (already told of every edit) when there is one. False when the
/// job could not be started — the caller parses inline instead.
pub fn start(app: *App, s: *Syntax, doc: *const Document) bool {
    std.debug.assert(s.pending == null);
    const entry = s.hl.root orelse return false;
    const gpa = app.gpa;
    const text = gpa.dupe(u8, doc.bytes()) catch return false;
    const ticket = gpa.create(Ticket) catch {
        gpa.free(text);
        return false;
    };
    ticket.* = .{};
    const job = gpa.create(Job) catch {
        gpa.free(text);
        gpa.destroy(ticket);
        return false;
    };
    const st = &app.syntax_jobs;
    const result = gpa.create(Result) catch {
        gpa.free(text);
        gpa.destroy(ticket);
        gpa.destroy(job);
        return false;
    };
    result.* = .{ .id = st.next_id, .tree = null };
    job.* = .{ .id = st.next_id, .entry = entry, .text = text, .old = if (s.hl.tree) |t| t.copy() else null, .ticket = ticket, .io = app.io, .result = result };
    st.group.concurrent(app.io, worker, .{ app.events, app.io, gpa, job }) catch {
        ticket.refs.store(1, .release);
        job.destroy(gpa);
        return false;
    };
    st.next_id += 1;
    st.started += 1;
    mem_report.Tally.bump(&mem_report.tally.jobs_started);
    s.pending = .{ .id = job.id, .base_seq = s.seen_seq, .ticket = ticket };
    return true;
}

fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *Job) Io.Cancelable!void {
    defer job.destroy(gpa);
    const result = job.result.?;
    if (ts.Parser.init()) |parser| {
        defer parser.deinit();
        if (parser.setLanguage(table.entries[job.entry].language())) |_| {
            result.tree = parser.parseCancelable(job.old, job.text, job, Job.keepGoing);
        } else |_| {}
    } else |_| {}
    // A cancelled group: say so, as every task in it does (`job.destroy`
    // frees the result with the rest).
    try io.checkCancel();
    job.result = null;
    mem_report.Tally.bump(&mem_report.tally.jobs_posted);
    events.post(io, .{ .syntax = result });
}

/// Free a tree that has been replaced, off the UI thread: the nodes it
/// does not share with its successor are its alone to free, and at 100 MB
/// that is tens of milliseconds. On this thread only if no task can start.
fn dispose(app: *App, old: *ts.Tree) void {
    mem_report.Tally.bump(&mem_report.tally.disposals_asked);
    app.syntax_jobs.group.concurrent(app.io, disposer, .{old}) catch {
        old.deinit();
        mem_report.Tally.bump(&mem_report.tally.disposals_done);
    };
}

fn disposer(old: *ts.Tree) Io.Cancelable!void {
    old.deinit();
    mem_report.Tally.bump(&mem_report.tally.disposals_done);
}

/// A parse came back. Adopt its tree if its document still wants it.
pub fn handle(app: *App, r: *Result) void {
    defer r.destroy(app.gpa);
    for (app.docs.entries.items) |e| {
        const s = &e.syntax;
        const p = s.pending orelse continue;
        if (p.id != r.id) continue;
        s.pending = null;
        p.ticket.release(app.gpa);
        const edits = &e.doc.edits;
        const tree = r.tree orelse {
            // Could not parse (out of memory): the gate tries again.
            s.dirty = true;
            mem_report.Tally.bump(&mem_report.tally.results_dropped);
            return;
        };
        if (edits.lostSince(p.base_seq)) {
            s.dirty = true;
            mem_report.Tally.bump(&mem_report.tally.results_dropped);
            return;
        }
        r.tree = null;
        mem_report.Tally.bump(&mem_report.tally.results_adopted);
        if (s.hl.swap(tree)) |old| dispose(app, old);
        // What was typed while it parsed: the tree is told, as the one it
        // replaces was.
        for (edits.since(p.base_seq)) |sp| s.hl.edit(syntax_mod.inputEdit(sp));
        s.seen_seq = edits.head();
        s.parsed_seq = p.base_seq;
        if (!s.isCurrent()) {
            s.dirty = true;
            s.since_ms = null;
        }
        app.needs_render = true;
        return;
    }
    // Nobody is waiting for it (the document closed): `destroy` frees it.
    mem_report.Tally.bump(&mem_report.tally.results_dropped);
}

// ── tests ──

const testing = std.testing;
const keymap = @import("../core/keymap.zig");
const command = @import("../core/command.zig");

/// A Rust text past the worker threshold.
fn bigRust(gpa: Allocator) ![]u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(gpa);
    var i: usize = 0;
    while (text.items.len <= Syntax.worker_min_bytes + 64 * 1024) : (i += 1) {
        const line = try std.fmt.allocPrint(gpa, "pub fn f{d}(x: u32) -> u32 {{\n    let needle = x + {d};\n    needle\n}}\n\n", .{ i, i });
        defer gpa.free(line);
        try text.appendSlice(gpa, line);
    }
    return text.toOwnedSlice(gpa);
}

/// Pump events until `s` has no job pending (or give up after 60 s).
fn awaitParse(app: *App, s: *Syntax) !void {
    var waited: usize = 0;
    while (s.pending != null) : (waited += 1) {
        if (waited > 12_000) return error.ParseNeverLanded;
        app.io.sleep(.fromMilliseconds(5), .awake) catch {};
        try app.pumpEvents();
    }
}

fn openBig(app: *App, text: []const u8) !*app_mod.EditorPane {
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/big.rs");
    e.syntax.setLanguage("/tmp/big.rs", "");
    try e.buf.editor.setText(text);
    e.buf.editor.setCursor(0);
    e.syntax.dirty = true;
    return e;
}

test "a large document is parsed by a worker, never by a frame: it paints plain, the tree lands, an edit made meanwhile is told to it and a second pass catches up" {
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    const text = try bigRust(gpa);
    defer gpa.free(text);
    const e = try openBig(&app, text);
    const ed = e.buf.editor;
    app.now_ms = 1000;
    try app.render();
    try testing.expect(e.syntax.pending == null and e.syntax.hl.tree == null);
    app.now_ms = 1000 + syntax_mod.idle_ms;
    try app.render();
    // The gate opened: a worker has the text, the frame parsed nothing.
    try testing.expect(e.syntax.pending != null);
    try testing.expectEqual(@as(u64, 1), app.syntax_jobs.started);
    try testing.expectEqual(@as(u64, 0), e.syntax.hl.parses);
    try testing.expect(e.syntax.hl.tree == null);
    try testing.expect(!e.syntax.dirty);
    // Nothing to wake for: the result wakes the loop.
    try testing.expect(app.nextDeadlineMs() == null or app.nextDeadlineMs().? > app.now_ms);
    // Type while it parses.
    try ed.splice(0, 0, "struct Early;\n");
    e.syntax.dirty = true;
    app.now_ms += 1;
    try app.render();
    try testing.expectEqual(@as(u64, 1), app.syntax_jobs.started);
    try awaitParse(&app, e.syntax);
    // The tree of the text as it was handed over, told of the edit since.
    try testing.expect(e.syntax.hl.tree != null);
    try testing.expect(e.syntax.hl.stale);
    try testing.expect(e.syntax.dirty and !e.syntax.isCurrent());
    // The gate again: a second, incremental pass on the worker.
    app.now_ms += 10;
    try app.render();
    app.now_ms += syntax_mod.idle_ms;
    try app.render();
    try testing.expectEqual(@as(u64, 2), app.syntax_jobs.started);
    try awaitParse(&app, e.syntax);
    try testing.expect(e.syntax.isCurrent() and !e.syntax.hl.stale);
    try testing.expectEqual(@as(u64, 0), e.syntax.hl.parses);
    // And what it paints is what a from-scratch parse of the text paints.
    try app.render();
    const lo = ed.lineStart(0);
    const hi = ed.lineEnd(40);
    const got = try gpa.dupe(highlight.engine.Span, try e.syntax.hl.spansIn(ed.bytes(), lo, hi));
    defer gpa.free(got);
    var fresh = highlight.Highlighter.init(gpa);
    defer fresh.deinit();
    fresh.setLanguage(e.syntax.hl.root);
    fresh.parse(ed.bytes());
    const want = try fresh.spansIn(ed.bytes(), lo, hi);
    try testing.expect(want.len > 20);
    try testing.expectEqualSlices(highlight.engine.Span, want, got);
    // `struct` at byte 0 is a keyword only if the second pass saw it.
    try testing.expectEqual(highlight.Role.keyword, got[0].role);
}

test "G, gg, page-down and a search on a large document start no parse and build no window wider than a viewport's" {
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const text = try bigRust(gpa);
    defer gpa.free(text);
    const e = try openBig(&app, text);
    app.now_ms = 1000;
    try app.render();
    app.now_ms += syntax_mod.idle_ms;
    try app.render();
    try awaitParse(&app, e.syntax);
    try app.render();
    try testing.expect(e.syntax.isCurrent());
    const hl = &e.syntax.hl;
    const jobs_before = app.syntax_jobs.started;
    hl.widest_window = 0;
    const built_before = hl.windows_built;
    const steps = [_][]const u8{ "G", "g", "g", "ctrl+f", "ctrl+f", "/", "n", "e", "e", "d", "l", "e", "enter", "n", "G" };
    for (steps) |spec| {
        try app.handle(.{ .key = keymap.parseKeySpec(spec).? });
        app.now_ms += 5;
        try app.tick(app.now_ms);
        try app.render();
    }
    // The cursor really went places.
    try testing.expect(e.buf.editor.currentLine() > 1000);
    try testing.expectEqual(jobs_before, app.syntax_jobs.started);
    try testing.expectEqual(@as(u64, 0), hl.parses);
    try testing.expect(e.syntax.pending == null and e.syntax.isCurrent());
    // Windows were built where the view went — each a viewport and its
    // margins, none the file.
    try testing.expect(hl.windows_built > built_before);
    try testing.expect(hl.widest_window <= 64 * 1024);
    try testing.expect(hl.widest_window < text.len / 8);
    // And none of them ran into the query cursor's match cap.
    try testing.expectEqual(@as(u64, 0), hl.drops);
}
