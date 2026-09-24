//! Background jobs you can see. A language server starting, a git
//! fetch, a test run, a send, a linter, a search walk, Chrome coming
//! up, a session spawning — each ran on a worker and, until this,
//! finished (or failed, or never finished) where nothing was looking: a
//! linter that exited 2 said nothing, Chrome died under a pane that
//! still read "connected", a test run that ran nothing looked like one
//! that passed.
//!
//! One registry, three surfaces:
//!
//!   - `Registry` — what is running and the last fifty that finished.
//!     `begin` / `progress` / `end`, keyed so the place a job finishes
//!     can name it the way its subsystem already does (a server id, a
//!     pane id, an http job id) without keeping our id around.
//!   - the statusline chip (`chip`): a spinner and a count while
//!     anything runs, the last failure's words dimmed for ten seconds
//!     after, nothing when idle — `ui.jobs_chip` says which.
//!   - the JOBS overlay (`jobs.show`, a click on the chip): the running
//!     jobs with their elapsed time and a Cancel row where the job can
//!     be stopped, then the finished ones with outcome and duration;
//!     Enter opens the pane the job belongs to, or toasts its words.
//!
//! The UI thread owns the registry. A worker never touches it: the
//! subsystems call `begin` where they start a worker and `end` where
//! its result lands, both on the UI thread, and a worker that has
//! something to say on its own posts a `.job` event (`post`), which
//! `handleEvent` applies. Every string the registry keeps is copied
//! onto the gpa — a label built on the frame arena is gone by the next
//! frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Mouse = key_mod.Mouse;
const list_panel = @import("../ui/list_panel.zig");
const jobs_view = @import("../ui/jobs_view.zig");
const sl = @import("../ui/statusline.zig");
const clip = @import("../ui/clip.zig");
const tooltip = @import("../ui/tooltip.zig");
const Ui = @import("../ui/context.zig");
const Config = @import("../config/Config.zig");

pub const ChipMode = Config.JobsChip;

/// What started the job. The word is the overlay's kind column and the
/// chip's prefix on a failure.
pub const Kind = enum {
    lsp,
    git,
    test_run,
    http,
    format,
    lint,
    search,
    browser,
    integration,
    session,

    pub fn word(k: Kind) []const u8 {
        return switch (k) {
            .test_run => "tests",
            else => @tagName(k),
        };
    }
};

pub const JobId = u32;

pub const Status = enum { running, ok, failed, cancelled };

/// How a job ended, with the words that say so (`3 passed`, `exit 2`).
pub const Outcome = struct {
    status: Status = .ok,
    text: ?[]const u8 = null,

    pub fn done(text: ?[]const u8) Outcome {
        return .{ .status = .ok, .text = text };
    }
    pub fn fail(text: []const u8) Outcome {
        return .{ .status = .failed, .text = text };
    }
    pub fn cancel(text: ?[]const u8) Outcome {
        return .{ .status = .cancelled, .text = text };
    }
};

/// Stops the job its subsystem names by `key`. Runs on the UI thread;
/// the subsystem ends the job itself (as cancelled) when it has.
pub const CancelFn = *const fn (app: *App, job_key: u64) void;

pub const Job = struct {
    id: JobId,
    kind: Kind,
    /// The subsystem's own name for it; null for a job nothing looks up.
    key: ?u64 = null,
    /// Owned.
    label: []u8,
    /// Progress while running, the outcome's words after. Owned.
    detail: ?[]u8 = null,
    started_ms: i64,
    ended_ms: i64 = 0,
    status: Status = .running,
    /// The pane Enter opens.
    pane: ?PaneId = null,
    cancel: ?CancelFn = null,

    fn free(j: *Job, gpa: Allocator) void {
        gpa.free(j.label);
        if (j.detail) |d| gpa.free(d);
        j.detail = null;
    }

    pub fn elapsedMs(j: *const Job, now_ms: i64) i64 {
        const stop = if (j.status == .running) now_ms else j.ended_ms;
        return @max(stop - j.started_ms, 0);
    }
};

/// What a caller names when it starts one.
pub const Begin = struct {
    kind: Kind,
    key: ?u64 = null,
    label: []const u8,
    pane: ?PaneId = null,
    cancel: ?CancelFn = null,
    /// A job this one supersedes goes without a trace rather than as
    /// `superseded` — a search that re-runs on every keystroke is one
    /// job, not a list of them.
    drop_superseded: bool = false,
};

/// How many finished jobs the overlay keeps.
pub const finished_cap: usize = 50;
/// How long the chip holds a failure's words.
pub const fail_hold_ms: i64 = 10_000;
pub const label_max: usize = 120;
pub const text_max: usize = 200;

/// `s` cut to at most `max` bytes on a UTF-8 boundary.
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// The first line of `s`, trimmed — a tool's stderr is a paragraph.
pub fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

pub const Registry = struct {
    running: std.ArrayListUnmanaged(Job) = .empty,
    /// Oldest first; `finished_cap` at most.
    finished: std.ArrayListUnmanaged(Job) = .empty,
    next_id: JobId = 1,
    /// The failure the chip is holding, until `fail_until_ms`.
    last_failure: ?JobId = null,
    fail_until_ms: i64 = 0,

    pub fn deinit(r: *Registry, gpa: Allocator) void {
        for (r.running.items) |*j| j.free(gpa);
        for (r.finished.items) |*j| j.free(gpa);
        r.running.deinit(gpa);
        r.finished.deinit(gpa);
        r.* = .{};
    }

    /// Start a job. A running job with the same kind and key is the one
    /// this replaces — a re-run, a second send from the same pane — and
    /// is ended as superseded first, so the list never shows two.
    pub fn begin(r: *Registry, gpa: Allocator, now_ms: i64, o: Begin) Allocator.Error!JobId {
        if (o.key) |k| if (r.findKeyed(o.kind, k)) |old| {
            if (o.drop_superseded) r.drop(gpa, old) else try r.end(gpa, now_ms, old, Outcome.cancel("superseded"));
        };
        const label = try gpa.dupe(u8, cut(o.label, label_max));
        errdefer gpa.free(label);
        const id = r.next_id;
        try r.running.append(gpa, .{ .id = id, .kind = o.kind, .key = o.key, .label = label, .started_ms = now_ms, .pane = o.pane, .cancel = o.cancel });
        r.next_id +%= 1;
        if (r.next_id == 0) r.next_id = 1;
        return id;
    }

    fn runningIndex(r: *const Registry, id: JobId) ?usize {
        for (r.running.items, 0..) |j, i| if (j.id == id) return i;
        return null;
    }

    /// Forget a running job without recording it.
    pub fn drop(r: *Registry, gpa: Allocator, id: JobId) void {
        const i = r.runningIndex(id) orelse return;
        var j = r.running.orderedRemove(i);
        j.free(gpa);
    }

    pub fn findKeyed(r: *const Registry, kind: Kind, job_key: u64) ?JobId {
        for (r.running.items) |j| if (j.kind == kind and j.key != null and j.key.? == job_key) return j.id;
        return null;
    }

    pub fn get(r: *Registry, id: JobId) ?*Job {
        for (r.running.items) |*j| if (j.id == id) return j;
        for (r.finished.items) |*j| if (j.id == id) return j;
        return null;
    }

    /// Replace a running job's progress words. A job that has ended
    /// keeps its outcome.
    pub fn progress(r: *Registry, gpa: Allocator, id: JobId, text: []const u8) Allocator.Error!void {
        const i = r.runningIndex(id) orelse return;
        const copy = try gpa.dupe(u8, cut(text, text_max));
        const j = &r.running.items[i];
        if (j.detail) |d| gpa.free(d);
        j.detail = copy;
    }

    /// Finish a running job; a second end of the same job does nothing.
    /// The words are copied — on OOM the job still ends, without them.
    pub fn end(r: *Registry, gpa: Allocator, now_ms: i64, id: JobId, o: Outcome) Allocator.Error!void {
        const i = r.runningIndex(id) orelse return;
        var j = r.running.orderedRemove(i);
        j.status = if (o.status == .running) .ok else o.status;
        j.ended_ms = @max(now_ms, j.started_ms);
        // No words of its own: the last progress stands.
        if (o.text) |words| {
            if (j.detail) |d| gpa.free(d);
            j.detail = gpa.dupe(u8, cut(firstLine(words), text_max)) catch null;
        }
        if (r.finished.items.len >= finished_cap) {
            var old = r.finished.orderedRemove(0);
            if (r.last_failure == old.id) r.last_failure = null;
            old.free(gpa);
        }
        r.finished.append(gpa, j) catch |err| {
            j.free(gpa);
            return err;
        };
        if (j.status == .failed) {
            r.last_failure = j.id;
            r.fail_until_ms = now_ms + fail_hold_ms;
        }
    }

    /// A job that started and ended in one call (a formatter run on the
    /// UI thread, a spawn that failed on the spot).
    pub fn record(r: *Registry, gpa: Allocator, started_ms: i64, ended_ms: i64, o: Begin, out: Outcome) Allocator.Error!void {
        var b = o;
        b.key = null;
        const id = try r.begin(gpa, started_ms, b);
        try r.end(gpa, ended_ms, id, out);
    }

    /// The failure the chip is still holding at `now_ms`.
    pub fn heldFailure(r: *Registry, now_ms: i64) ?*const Job {
        const id = r.last_failure orelse return null;
        if (now_ms >= r.fail_until_ms) return null;
        const j = r.get(id) orelse return null;
        return if (j.status == .failed) j else null;
    }

    pub fn dismissFailure(r: *Registry) void {
        r.last_failure = null;
        r.fail_until_ms = 0;
    }
};

pub const State = struct {
    reg: Registry = .{},
    /// Keys handed to jobs whose subsystem has no id of its own (a
    /// lint run, a chain).
    next_key: u64 = 1,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.reg.deinit(gpa);
    }
};

// ─── the App's calls ────────────────────────────────────────────────────

pub fn begin(app: *App, o: Begin) Allocator.Error!JobId {
    app.needs_render = true;
    return app.jobs.reg.begin(app.gpa, app.now_ms, o);
}

/// A key no other job of `kind` has — for a subsystem with no id to
/// key on.
pub fn freshKey(app: *App) u64 {
    const k = app.jobs.next_key;
    app.jobs.next_key +%= 1;
    return k;
}

pub fn running(app: *const App, kind: Kind, job_key: u64) bool {
    return app.jobs.reg.findKeyed(kind, job_key) != null;
}

/// Progress words for the job `kind`/`key` names; nothing when none runs.
pub fn progress(app: *App, kind: Kind, job_key: u64, text: []const u8) void {
    const id = app.jobs.reg.findKeyed(kind, job_key) orelse return;
    app.jobs.reg.progress(app.gpa, id, text) catch {};
    app.needs_render = true;
}

pub fn endJob(app: *App, id: JobId, o: Outcome) void {
    app.jobs.reg.end(app.gpa, app.now_ms, id, o) catch {};
    app.needs_render = true;
}

/// End the job `kind`/`key` names, if one is running.
pub fn endKeyed(app: *App, kind: Kind, job_key: u64, o: Outcome) void {
    const id = app.jobs.reg.findKeyed(kind, job_key) orelse return;
    endJob(app, id, o);
}

/// Forget the job `kind`/`key` names, if one is running — work that was
/// withdrawn rather than finished (a search whose query was cleared).
pub fn dropKeyed(app: *App, kind: Kind, job_key: u64) void {
    const id = app.jobs.reg.findKeyed(kind, job_key) orelse return;
    app.jobs.reg.drop(app.gpa, id);
    app.needs_render = true;
}

/// A pane closed: a job still running for it is over (its worker went
/// with the pane), and a finished one no longer has a pane to open —
/// the id may be handed to the next pane that opens.
pub fn onPaneClosed(app: *App, id: PaneId) void {
    const reg = &app.jobs.reg;
    var i: usize = 0;
    while (i < reg.running.items.len) {
        const j = reg.running.items[i];
        if (j.pane != null and j.pane.? == id) {
            // `end` takes it off `running` on every path, OOM included.
            reg.end(app.gpa, app.now_ms, j.id, Outcome.cancel("its pane closed")) catch {};
        } else i += 1;
    }
    for (reg.finished.items) |*j| if (j.pane != null and j.pane.? == id) {
        j.pane = null;
    };
    app.needs_render = true;
}

/// A job that is over by the time anyone could look (`Registry.record`).
/// `took_ms` is how long it ran, measured by the caller.
pub fn record(app: *App, o: Begin, took_ms: i64, out: Outcome) void {
    app.jobs.reg.record(app.gpa, app.now_ms, app.now_ms + @max(took_ms, 0), o, out) catch {};
    app.needs_render = true;
}

// ─── the `.job` event: a worker's own words ─────────────────────────────

/// What a worker posts. The strings are the event's (gpa); the handler
/// frees them with the box.
pub const Event = struct {
    kind: Kind,
    key: u64,
    status: Status,
    text: ?[]u8 = null,

    pub fn destroy(self: *Event, gpa: Allocator) void {
        if (self.text) |t| gpa.free(t);
        gpa.destroy(self);
    }
};

/// Post from a worker: `.running` starts the job (its text the label)
/// when none runs under the key, and replaces its progress words when
/// one does; anything else ends it. A failure to allocate drops the message — the
/// subsystem's own result still arrives and ends the job there.
pub fn post(events: *event.EventQueue, io: Io, gpa: Allocator, kind: Kind, job_key: u64, status: Status, text: ?[]const u8) void {
    const ev = gpa.create(Event) catch return;
    ev.* = .{ .kind = kind, .key = job_key, .status = status };
    if (text) |words| ev.text = gpa.dupe(u8, cut(words, text_max)) catch null;
    events.post(io, .{ .job = ev });
}

pub fn handleEvent(app: *App, ev: *Event) void {
    defer ev.destroy(app.gpa);
    switch (ev.status) {
        .running => if (running(app, ev.kind, ev.key)) {
            progress(app, ev.kind, ev.key, ev.text orelse "");
        } else {
            _ = begin(app, .{ .kind = ev.kind, .key = ev.key, .label = ev.text orelse ev.kind.word() }) catch {};
        },
        else => endKeyed(app, ev.kind, ev.key, .{ .status = ev.status, .text = ev.text }),
    }
}

// ─── the chip ───────────────────────────────────────────────────────────

pub const Tone = enum { busy, failed, idle };
/// `short`: the chip's form when the statusline is out of room — the
/// mark and the count or the kind (` ⠋ 2 `, ` ✗ tests `).
pub const Chip = struct { text: []const u8, tone: Tone, short: ?[]const u8 = null };

/// The widest a failure's words get on the chip.
pub const chip_text_max: usize = 28;

/// `s` in at most `max` codepoints, the ellipsis on the cut.
fn clipText(arena: Allocator, s: []const u8, max: usize, ascii: bool) Allocator.Error![]const u8 {
    var it = (std.unicode.Utf8View.init(s) catch return s).iterator();
    var n: usize = 0;
    var upto: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (n == max) return std.fmt.allocPrint(arena, "{s}{s}", .{ s[0..upto], clip.ellipsisText(ascii) });
        n += 1;
        upto += cp.len;
    }
    return s;
}

/// The chip's text, already padded the way a `Seg` wants it, or null
/// when this mode and this moment paint nothing.
/// `owned_elsewhere`: the kind whose failure another chip already
/// states in full (the tests chip, for a test run) — the jobs chip then
/// names the kind and leaves the words to it, so one failure is not
/// said three times on the bottom rows.
pub fn chip(arena: Allocator, reg: *Registry, now_ms: i64, ascii: bool, mode: ChipMode, owned_elsewhere: ?Kind) Allocator.Error!?Chip {
    if (mode == .hidden) return null;
    const n = reg.running.items.len;
    if (n > 0) {
        const spin = list_panel.spinnerFrame(now_ms, ascii);
        return .{
            .text = try std.fmt.allocPrint(arena, " {s} {d} {s} ", .{ spin, n, if (n == 1) "job" else "jobs" }),
            .tone = .busy,
            .short = try std.fmt.allocPrint(arena, " {s} {d} ", .{ spin, n }),
        };
    }
    if (reg.heldFailure(now_ms)) |j| {
        const words = j.detail orelse j.label;
        const mark = if (ascii) jobs_view.failed_ascii else jobs_view.failed_glyph;
        const short = try std.fmt.allocPrint(arena, " {s} {s} ", .{ mark, j.kind.word() });
        if (owned_elsewhere != null and owned_elsewhere.? == j.kind) return .{ .text = short, .tone = .failed };
        return .{
            .text = try std.fmt.allocPrint(arena, " {s} {s}: {s} ", .{ mark, j.kind.word(), try clipText(arena, words, chip_text_max, ascii) }),
            .tone = .failed,
            .short = short,
        };
    }
    if (mode == .always) return .{ .text = " jobs ", .tone = .idle };
    return null;
}

pub fn chipFor(app: *App, arena: Allocator, ascii: bool) Allocator.Error!?Chip {
    // The tests chip states a test run's result in full while its pane
    // is open.
    const owned: ?Kind = if (@import("tests_pane.zig").find(app) != null) .test_run else null;
    return chip(arena, &app.jobs.reg, app.now_ms, ascii, app.cfg.ui.jobs_chip, owned);
}

/// `2.3s`, `1m05s`, `2h03m` — one reading a person takes in at a glance.
pub fn durText(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    const v: u64 = @intCast(@max(ms, 0));
    if (v < 60_000) return std.fmt.allocPrint(arena, "{d}.{d}s", .{ v / 1000, (v % 1000) / 100 });
    const s = v / 1000;
    if (s < 3600) return std.fmt.allocPrint(arena, "{d}m{d:0>2}s", .{ s / 60, s % 60 });
    return std.fmt.allocPrint(arena, "{d}h{d:0>2}m", .{ s / 3600, (s % 3600) / 60 });
}

/// The chip's hover: what is running, or what failed and when.
pub fn tip(app: *App, arena: Allocator) Allocator.Error!tooltip.Tip {
    const reg = &app.jobs.reg;
    var rows: std.ArrayListUnmanaged(tooltip.Row) = .empty;
    for (reg.running.items) |*j| try rows.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "{s} {s}", .{ j.kind.word(), j.label }),
        .sub = try durText(arena, j.elapsedMs(app.now_ms)),
    });
    const n = reg.running.items.len;
    if (n > 0) return .{
        .title = try std.fmt.allocPrint(arena, "Background jobs — {d} running", .{n}),
        .detail = "click: the jobs list",
        .rows = rows.items,
    };
    if (reg.heldFailure(app.now_ms)) |j| return .{
        .title = try std.fmt.allocPrint(arena, "Background jobs — {s} failed", .{j.kind.word()}),
        .detail = try std.fmt.allocPrint(arena, "{s} · {s} · click: the jobs list", .{ j.label, j.detail orelse "failed" }),
    };
    return .{ .title = "Background jobs", .detail = "nothing running · click: the jobs list" };
}

// ─── the overlay ────────────────────────────────────────────────────────

pub const table = .{
    .@"jobs.show" = &showCmd,
};

fn showCmd(app: *App) CommandError!void {
    try show(app);
}

/// Open the JOBS overlay. Looking at the list is reading the failure,
/// so the chip stops holding it.
pub fn show(app: *App) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .jobs = .{} };
    app.focus = .overlay;
    app.jobs.reg.dismissFailure();
    app.needs_render = true;
}

fn close(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

fn markOf(ascii: bool, status: Status, now_ms: i64) []const u8 {
    return switch (status) {
        .running => list_panel.spinnerFrame(now_ms, ascii),
        .ok => if (ascii) jobs_view.ok_ascii else jobs_view.ok_glyph,
        .failed => if (ascii) jobs_view.failed_ascii else jobs_view.failed_glyph,
        .cancelled => if (ascii) jobs_view.cancelled_ascii else jobs_view.cancelled_glyph,
    };
}

fn toneOf(status: Status) jobs_view.Tone {
    return switch (status) {
        .running => .accent,
        .ok => .ok,
        .failed => .failed,
        .cancelled => .muted,
    };
}

fn jobRow(arena: Allocator, j: *const Job, now_ms: i64, ascii: bool) Allocator.Error!jobs_view.Row {
    return .{
        .kind = if (j.status == .running) .running else .finished,
        .id = j.id,
        .mark = markOf(ascii, j.status, now_ms),
        .tone = toneOf(j.status),
        .what = j.kind.word(),
        .label = j.label,
        .detail = j.detail orelse (if (j.status == .cancelled) "cancelled" else ""),
        .right = try durText(arena, j.elapsedMs(now_ms)),
    };
}

/// The overlay's rows, in paint order: RUNNING with a Cancel row under
/// each job that can be stopped, then FINISHED newest first.
pub fn buildRows(reg: *Registry, arena: Allocator, now_ms: i64, ascii: bool) Allocator.Error![]jobs_view.Row {
    var out: std.ArrayListUnmanaged(jobs_view.Row) = .empty;
    if (reg.running.items.len > 0) {
        try out.append(arena, .{ .kind = .section, .label = try std.fmt.allocPrint(arena, "RUNNING ({d})", .{reg.running.items.len}) });
        for (reg.running.items) |*j| {
            try out.append(arena, try jobRow(arena, j, now_ms, ascii));
            if (j.cancel != null) try out.append(arena, .{ .kind = .cancel, .id = j.id });
        }
    }
    if (reg.finished.items.len > 0) {
        try out.append(arena, .{ .kind = .section, .label = try std.fmt.allocPrint(arena, "FINISHED ({d})", .{reg.finished.items.len}) });
        var i = reg.finished.items.len;
        while (i > 0) : (i -= 1) try out.append(arena, try jobRow(arena, &reg.finished.items[i - 1], now_ms, ascii));
    }
    return out.items;
}

fn subtitle(arena: Allocator, reg: *const Registry) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "({d} running · {d} finished)", .{ reg.running.items.len, reg.finished.items.len });
}

pub fn drawOverlay(app: *App, ui: Ui, st: *jobs_view.Panel.State) Allocator.Error!void {
    const list = try buildRows(&app.jobs.reg, ui.arena, app.now_ms, ui.ascii);
    jobs_view.draw(ui, ui.canvas.full(), st, list, try subtitle(ui.arena, &app.jobs.reg));
}

/// Stop the job with `id` through its subsystem.
pub fn cancelJob(app: *App, id: JobId) void {
    const j = app.jobs.reg.get(id) orelse return;
    if (j.status != .running) return;
    const f = j.cancel orelse {
        app.toast("{s}: this job cannot be stopped from here", .{j.kind.word()});
        return;
    };
    const k = j.key orelse 0;
    f(app, k);
    // The subsystem ends its own job; one that could not says so by
    // leaving it running, and the list shows it.
    app.needs_render = true;
}

/// Enter / a click on row `idx`: a Cancel row stops its job; a job row
/// opens its pane, or says its words in a toast when it has none.
pub fn activate(app: *App, idx: usize) Allocator.Error!void {
    const list = try buildRows(&app.jobs.reg, app.frame.allocator(), app.now_ms, app.cfg.ui.ascii_icons);
    if (idx >= list.len) return;
    const row = list[idx];
    switch (row.kind) {
        .section => {},
        .cancel => cancelJob(app, row.id),
        .running, .finished => {
            const j = app.jobs.reg.get(row.id) orelse return;
            if (j.pane) |pane| if (app.panes.get(pane) != null) {
                close(app);
                app.showPane(pane);
                return;
            };
            const status: []const u8 = switch (j.status) {
                .running => "running",
                .ok => "ok",
                .failed => "failed",
                .cancelled => "cancelled",
            };
            if (j.detail) |d| {
                app.toast("{s}: {s} — {s}: {s}", .{ j.kind.word(), j.label, status, d });
            } else app.toast("{s}: {s} — {s}", .{ j.kind.word(), j.label, status });
        },
    }
}

/// The overlay's keys: the panel's own (j/k, the arrows, g/G, the page
/// keys, Enter), `c` / `x` / Delete cancel the job under the cursor,
/// Esc / `q` close.
pub fn handleKey(app: *App, st: *jobs_view.Panel.State, k: Key) Allocator.Error!void {
    if (k.code == .esc or (k.typed() orelse 0) == 'q') return close(app);
    const c = k.typed() orelse 0;
    if (c == 'c' or c == 'x' or k.code == .delete) {
        const list = try buildRows(&app.jobs.reg, app.frame.allocator(), app.now_ms, app.cfg.ui.ascii_icons);
        if (st.cursor < list.len and list[st.cursor].id != 0) cancelJob(app, list[st.cursor].id);
        return;
    }
    switch (try jobs_view.Panel.handleKey(st, app.gpa, k)) {
        .activate => |i| try activate(app, i),
        .ignored, .consumed, .filter_changed, .new_activate => {},
    }
    app.needs_render = true;
}

/// A press on row `idx` puts the cursor there and runs it.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (app.overlay != .jobs or m.kind != .press or m.button != .left) return;
    app.overlay.jobs.cursor = idx;
    try activate(app, idx);
}

pub fn wheel(app: *App, down: bool, n: usize) void {
    if (app.overlay != .jobs) return;
    const st = &app.overlay.jobs;
    if (down) st.cursor = @min(st.cursor + n, st.total -| 1) else st.cursor -|= n;
    app.needs_render = true;
}

/// A press or drag on the list's bar: the cursor lands at the
/// pointer's fraction of the track.
pub fn scrollbarMouse(app: *App, track: @import("../ui/rect.zig"), m: Mouse) void {
    if (app.overlay != .jobs or track.h == 0) return;
    const st = &app.overlay.jobs;
    if (st.total == 0) return;
    const off: usize = m.y -| track.y;
    st.cursor = @min(off * st.total / track.h, st.total - 1);
    app.needs_render = true;
}

// ─── the clock ──────────────────────────────────────────────────────────

/// A spinner is turning, or a held failure is due to go.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const reg = &app.jobs.reg;
    const shown = app.cfg.ui.jobs_chip != .hidden or app.overlay == .jobs;
    if (!shown) return null;
    if (reg.running.items.len > 0) return app.now_ms + list_panel.spinner_step_ms;
    if (reg.last_failure != null and reg.fail_until_ms > app.now_ms) return reg.fail_until_ms;
    return null;
}

pub fn tick(app: *App, now: i64) void {
    const reg = &app.jobs.reg;
    if (reg.running.items.len > 0 and (app.cfg.ui.jobs_chip != .hidden or app.overlay == .jobs)) app.needs_render = true;
    if (reg.last_failure != null and reg.fail_until_ms != 0 and now >= reg.fail_until_ms) {
        reg.dismissFailure();
        app.needs_render = true;
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "registry: begin, progress, end; a second end is a no-op; the words are copies" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    var label_buf = "fetch origin".*;
    const id = try r.begin(gpa, 100, .{ .kind = .git, .key = 7, .label = &label_buf });
    // The caller's buffer can go: the registry kept its own.
    @memset(&label_buf, 'x');
    try testing.expectEqualStrings("fetch origin", r.get(id).?.label);
    try testing.expectEqual(id, r.findKeyed(.git, 7).?);
    try testing.expect(r.findKeyed(.lsp, 7) == null);
    try r.progress(gpa, id, "3/10");
    try testing.expectEqualStrings("3/10", r.get(id).?.detail.?);
    try r.end(gpa, 2400, id, Outcome.done("fetched"));
    try testing.expectEqual(@as(usize, 0), r.running.items.len);
    const j = r.get(id).?;
    try testing.expectEqual(Status.ok, j.status);
    try testing.expectEqualStrings("fetched", j.detail.?);
    try testing.expectEqual(@as(i64, 2300), j.elapsedMs(99_999));
    try r.end(gpa, 3000, id, Outcome.fail("again"));
    try testing.expectEqual(Status.ok, r.get(id).?.status);
    try testing.expectEqual(@as(usize, 1), r.finished.items.len);
    // Progress on a finished job changes nothing.
    try r.progress(gpa, id, "late");
    try testing.expectEqualStrings("fetched", r.get(id).?.detail.?);
}

test "registry: the same kind and key supersedes the running job" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    const a = try r.begin(gpa, 0, .{ .kind = .test_run, .key = 3, .label = "dotnet test" });
    const b = try r.begin(gpa, 50, .{ .kind = .test_run, .key = 3, .label = "dotnet test" });
    try testing.expect(a != b);
    try testing.expectEqual(@as(usize, 1), r.running.items.len);
    try testing.expectEqual(Status.cancelled, r.get(a).?.status);
    try testing.expectEqualStrings("superseded", r.get(a).?.detail.?);
    // A different key is a different job.
    _ = try r.begin(gpa, 60, .{ .kind = .test_run, .key = 4, .label = "npx playwright test" });
    try testing.expectEqual(@as(usize, 2), r.running.items.len);
    // A search re-run leaves no trace of the one it replaced.
    const s1 = try r.begin(gpa, 70, .{ .kind = .search, .key = 1, .label = "search fo", .drop_superseded = true });
    _ = try r.begin(gpa, 80, .{ .kind = .search, .key = 1, .label = "search foo", .drop_superseded = true });
    try testing.expect(r.get(s1) == null);
    try testing.expectEqual(@as(usize, 1), r.finished.items.len);
    try testing.expectEqual(@as(usize, 3), r.running.items.len);
}

test "registry: a failure is held ten seconds; fifty finished at most, oldest dropped" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    const id = try r.begin(gpa, 0, .{ .kind = .lint, .label = "shellcheck run.sh" });
    try r.end(gpa, 1000, id, Outcome.fail("exit 2: SC1000\nmore lines"));
    // Only the first line is kept.
    try testing.expectEqualStrings("exit 2: SC1000", r.get(id).?.detail.?);
    try testing.expectEqual(id, r.heldFailure(1000 + fail_hold_ms - 1).?.id);
    try testing.expect(r.heldFailure(1000 + fail_hold_ms) == null);
    r.dismissFailure();
    try testing.expect(r.heldFailure(1001) == null);
    var i: usize = 0;
    while (i < finished_cap + 5) : (i += 1) {
        const n = try r.begin(gpa, 0, .{ .kind = .http, .label = "GET /" });
        try r.end(gpa, 1, n, .{});
    }
    try testing.expectEqual(finished_cap, r.finished.items.len);
    // The lint failure was the oldest; it is gone, and so is its hold.
    try testing.expect(r.get(id) == null);
    try testing.expect(r.last_failure == null);
}

test "registry: record is a begin and an end at once; long labels are cut on a boundary" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    try r.record(gpa, 10, 25, .{ .kind = .format, .key = 99, .label = "prettier a.ts" }, Outcome.fail("prettier failed"));
    try testing.expectEqual(@as(usize, 0), r.running.items.len);
    try testing.expectEqual(@as(i64, 15), r.finished.items[0].elapsedMs(0));
    const long = "é" ** 100;
    const id = try r.begin(gpa, 0, .{ .kind = .search, .label = long });
    const got = r.get(id).?.label;
    try testing.expect(got.len <= label_max);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "chip: spinner and count while running, the failure dimmed after, nothing idle unless always" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: Registry = .{};
    defer r.deinit(gpa);
    try testing.expect(try chip(a, &r, 0, false, .auto, null) == null);
    try testing.expectEqualStrings(" jobs ", (try chip(a, &r, 0, false, .always, null)).?.text);
    const one = try r.begin(gpa, 0, .{ .kind = .lsp, .key = 1, .label = "fake" });
    try testing.expectEqualStrings(" ⠋ 1 job ", (try chip(a, &r, 0, false, .auto, null)).?.text);
    const two = try r.begin(gpa, 0, .{ .kind = .git, .label = "fetch" });
    const busy = (try chip(a, &r, 0, false, .auto, null)).?;
    try testing.expectEqualStrings(" ⠋ 2 jobs ", busy.text);
    try testing.expectEqual(Tone.busy, busy.tone);
    try testing.expectEqualStrings(" | 2 jobs ", (try chip(a, &r, 0, true, .auto, null)).?.text);
    try testing.expect(try chip(a, &r, 0, false, .hidden, null) == null);
    try r.end(gpa, 100, one, .{});
    try r.end(gpa, 200, two, Outcome.fail("the remote hung up unexpectedly during the fetch"));
    const failed = (try chip(a, &r, 300, false, .auto, null)).?;
    try testing.expectEqual(Tone.failed, failed.tone);
    try testing.expectEqualStrings(" ✗ git: the remote hung up unexpecte… ", failed.text);
    try testing.expectEqualStrings(" x git: the remote hung up unexpecte... ", (try chip(a, &r, 300, true, .auto, null)).?.text);
    // Past the hold the chip goes; `always` keeps its idle face.
    try testing.expect(try chip(a, &r, 200 + fail_hold_ms, false, .auto, null) == null);
    try testing.expectEqualStrings(" jobs ", (try chip(a, &r, 200 + fail_hold_ms, false, .always, null)).?.text);
}

test "rows: RUNNING with a Cancel row where there is a way to stop, then FINISHED newest first" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: Registry = .{};
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), (try buildRows(&r, a, 0, false)).len);
    const Stop = struct {
        fn f(_: *App, _: u64) void {}
    };
    const first = try r.begin(gpa, 0, .{ .kind = .http, .label = "GET /a" });
    try r.end(gpa, 1200, first, Outcome.done("200"));
    const second = try r.begin(gpa, 0, .{ .kind = .lint, .label = "shellcheck" });
    try r.end(gpa, 400, second, Outcome.fail("exit 2"));
    _ = try r.begin(gpa, 1000, .{ .kind = .test_run, .key = 1, .label = "dotnet test", .cancel = &Stop.f });
    _ = try r.begin(gpa, 1000, .{ .kind = .lsp, .key = 1, .label = "fake" });
    const got = try buildRows(&r, a, 3500, false);
    try testing.expectEqual(@as(usize, 7), got.len);
    try testing.expectEqualStrings("RUNNING (2)", got[0].label);
    try testing.expectEqual(jobs_view.Row.Kind.running, got[1].kind);
    try testing.expectEqualStrings("tests", got[1].what);
    try testing.expectEqualStrings("2.5s", got[1].right);
    try testing.expectEqual(jobs_view.Row.Kind.cancel, got[2].kind);
    try testing.expectEqual(got[1].id, got[2].id);
    // The language server has no way to stop from here: no Cancel row.
    try testing.expectEqualStrings("lsp", got[3].what);
    try testing.expectEqualStrings("FINISHED (2)", got[4].label);
    try testing.expectEqualStrings("shellcheck", got[5].label);
    try testing.expectEqualStrings("exit 2", got[5].detail);
    try testing.expectEqual(jobs_view.Tone.failed, got[5].tone);
    try testing.expectEqualStrings("GET /a", got[6].label);
    try testing.expectEqualStrings("1.2s", got[6].right);
}

test "durText: seconds with a decimal, then minutes, then hours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("0.0s", try durText(a, -5));
    try testing.expectEqualStrings("2.3s", try durText(a, 2345));
    try testing.expectEqualStrings("1m05s", try durText(a, 65_000));
    try testing.expectEqualStrings("2h03m", try durText(a, (2 * 3600 + 3 * 60) * 1000));
}

test "the .job event: progress from a worker, then its end, through the queue" {
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    // A worker can start its own job: the text is the label.
    post(app.events, app.io, gpa, .integration, 7, .running, "mnml-jira --values");
    try app.pumpEvents();
    try testing.expect(running(&app, .integration, 7));
    post(app.events, app.io, gpa, .integration, 7, .ok, "published");
    try app.pumpEvents();
    try testing.expect(!running(&app, .integration, 7));
    const id = try begin(&app, .{ .kind = .lint, .key = 42, .label = "shellcheck a.sh" });
    post(app.events, app.io, gpa, .lint, 42, .running, "running");
    try app.pumpEvents();
    try testing.expectEqualStrings("running", app.jobs.reg.get(id).?.detail.?);
    post(app.events, app.io, gpa, .lint, 42, .failed, "exit 2");
    try app.pumpEvents();
    try testing.expectEqual(Status.failed, app.jobs.reg.get(id).?.status);
    // An end for a job nobody is running is dropped whole, leak-free.
    post(app.events, app.io, gpa, .lint, 43, .ok, "late");
    try app.pumpEvents();
}

test "the overlay: jobs.show opens it, Enter on a job toasts its words, c cancels through the subsystem, Esc closes" {
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const Stop = struct {
        var called: u64 = 0;
        fn f(a: *App, k: u64) void {
            called = k;
            endKeyed(a, .test_run, k, Outcome.cancel(null));
        }
    };
    const done = try begin(&app, .{ .kind = .git, .label = "fetch" });
    endJob(&app, done, Outcome.fail("could not read from remote"));
    _ = try begin(&app, .{ .kind = .test_run, .key = 5, .label = "dotnet test", .cancel = &Stop.f });
    try command.run(&app, .{ .static = .@"jobs.show" });
    try testing.expect(app.overlay == .jobs);
    // Opening the list is reading the failure: the chip lets it go.
    try testing.expect(app.jobs.reg.heldFailure(app.now_ms) == null);
    try app.render();
    // Rows: RUNNING, the run, its Cancel, FINISHED, the fetch.
    app.overlay.jobs.cursor = 1;
    try app.handle(.{ .key = Key.char('c') });
    try testing.expectEqual(@as(u64, 5), Stop.called);
    try testing.expectEqual(@as(usize, 0), app.jobs.reg.running.items.len);
    try app.render();
    // Now: FINISHED, the cancelled run, the fetch.
    app.overlay.jobs.cursor = 2;
    try app.handle(.{ .key = .{ .code = .enter } });
    try testing.expect(app.toasts.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, app.toasts.items[app.toasts.items.len - 1].text, "could not read from remote") != null);
    try app.handle(.{ .key = .{ .code = .esc } });
    try testing.expect(app.overlay == .none);
}
