//! The file channel asks before it acts (`docs/research/api-design.md`
//! §5.3–§5.7). Any process in a pane can append a line to
//! `<workspace>/.mnml/ipc/command`; under the live terminal loop its
//! `run-command` of anything above `view`, and every `open-pty`, waits
//! for the person at the keyboard.
//!
//! The ask never takes a keystroke: a request raises a warn toast with a
//! `Review` offer, and only a click or `toast.run_action` opens the one
//! confirm box — Allow once · Allow for the session · Deny · Cancel, with
//! Cancel holding the focus. Cancel (or Esc) puts the request back on its
//! toast; nothing answered in `timeout_ms` is denied. A grant "for the
//! session" is for that class, until mnml quits.
//!
//! `config.zon`'s `.api` lets requests through unasked: `allow_commands`
//! by id, and a `clients` row named `file-channel` by class or id.
//!
//! Every decision is a line in `<ipc>/audit.jsonl` (owner-only) and an
//! `{"event":"api",…}` line in `events.jsonl`, written by the loop that
//! owns the channel (`flush`). The command's target is recorded; nothing
//! else from the line is.
//!
//! The headless loop is the test driver and never comes through here:
//! the gate sits in `App.handle`'s `.ipc` arm, which only the terminal
//! loop posts to (`tui/loop.zig` `dispatchIpcLine`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const Effect = command.Effect;
const ipc = @import("../ipc/root.zig");
const Confirm = @import("../ui/confirm.zig");
const api_app = @import("api.zig");

/// The identity the audit records for the file channel.
pub const client = "file-channel";
/// An unanswered request is denied after this long.
pub const timeout_ms: i64 = 120_000;
/// The toast's offer.
pub const toast_label = "Review";
const toast_prefix = "ipc-gate:";

pub const Verb = enum {
    run_command,
    open_pty,
    /// The API socket's `commands.run` (`app/api.zig`).
    api_run,
    /// The API socket's other methods, audited but never held.
    api_open,
    api_read,
    /// The agent face's tools (`app/ide.zig`): audited, never held…
    ide_tool,
    /// …but `saveDocument`, which writes.
    ide_save,

    pub fn word(v: Verb) []const u8 {
        return switch (v) {
            .run_command => "run-command",
            .open_pty => "open-pty",
            .api_run => "commands.run",
            .api_open => "editor.open",
            .api_read => "read",
            .ide_tool => "ide",
            .ide_save => "saveDocument",
        };
    }

    fn runs(v: Verb) bool {
        return v == .run_command or v == .api_run;
    }
};

/// Who asks. The file channel is one caller; over the API socket a
/// process in a pane is that pane (its `MNML_API_TOKEN`), and anything
/// without a token is `unknown`, which may only read.
pub const Caller = union(enum) {
    file_channel,
    pane: u32,
    unknown,

    /// What the audit and `.api.clients` call it: `file-channel`,
    /// `pane:<id>`, `unknown`.
    pub fn name(c: Caller, buf: []u8) []const u8 {
        return switch (c) {
            .file_channel => client,
            .pane => |id| std.fmt.bufPrint(buf, "pane:{d}", .{id}) catch "pane",
            .unknown => "unknown",
        };
    }

    pub fn eql(a: Caller, b: Caller) bool {
        return switch (a) {
            .pane => |x| b == .pane and b.pane == x,
            else => std.meta.activeTag(a) == std.meta.activeTag(b),
        };
    }
};

/// Where an API request's answer goes once the person has decided.
pub const ApiReply = struct {
    conn: u32,
    /// The request's `id`, as JSON. Owned.
    id_json: []u8,
    /// An agent-face connection (`app/ide.zig`), answered in its terms.
    ide: bool = false,
};

/// What `askApi` decided.
pub const Outcome = enum { run, held, refused };

pub const Decision = enum {
    /// A `view` command: nothing to ask.
    free,
    /// `config.zon`'s `.api` names it.
    allowlisted,
    granted_once,
    granted_session,
    denied,
    timed_out,
    /// Waiting on the person (events.jsonl only; the outcome is audited).
    pending,

    pub fn word(d: Decision) []const u8 {
        return switch (d) {
            .free => "free",
            .allowlisted => "allowlisted",
            .granted_once => "granted-once",
            .granted_session => "granted-session",
            .denied => "denied",
            .timed_out => "timed-out",
            .pending => "pending",
        };
    }
};

pub const Request = struct {
    id: u32,
    verb: Verb,
    effect: Effect,
    /// The command id, or the argv joined by spaces: what the box shows
    /// verbatim and the audit records.
    target: []u8,
    /// `open-pty`'s own argv and cwd, to run it once allowed.
    argv: [][]u8 = &.{},
    cwd: ?[]u8 = null,
    raised_ms: i64,
    caller: Caller = .file_channel,
    /// An API request: the connection waiting on the answer.
    reply: ?ApiReply = null,

    fn deinit(r: Request, gpa: Allocator) void {
        if (r.reply) |a| gpa.free(a.id_json);
        gpa.free(r.target);
        for (r.argv) |a| gpa.free(a);
        gpa.free(r.argv);
        if (r.cwd) |c| gpa.free(c);
    }
};

pub const State = struct {
    pending: std.ArrayListUnmanaged(Request) = .empty,
    /// The classes the person allowed the file channel for this run.
    granted: std.EnumSet(Effect) = .initEmpty(),
    next_id: u32 = 1,
    /// Lines the loop writes: to `audit.jsonl` and to `events.jsonl`.
    audit: std.ArrayListUnmanaged([]u8) = .empty,
    events: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.pending.items) |r| r.deinit(gpa);
        s.pending.deinit(gpa);
        for (s.audit.items) |l| gpa.free(l);
        s.audit.deinit(gpa);
        for (s.events.items) |l| gpa.free(l);
        s.events.deinit(gpa);
    }

    fn find(s: *State, id: u32) ?usize {
        for (s.pending.items, 0..) |r, i| if (r.id == id) return i;
        return null;
    }
};

/// Whether `cmd`, read from the file channel by the terminal loop, runs
/// now. False when it is held for the person (or answered already).
pub fn check(app: *App, cmd: *const ipc.Command) Allocator.Error!bool {
    switch (cmd.*) {
        .run_command => |id| {
            // An unknown id is told so by the dispatcher.
            const ref = command.resolve(app, id) orelse return true;
            return try decide(app, .file_channel, .run_command, command.effect(ref), id, &.{}, null, null) == .run;
        },
        .open_pty => |p| {
            if (p.command.len == 0) return true;
            const target = try std.mem.join(app.frame.allocator(), " ", p.command);
            return try decide(app, .file_channel, .open_pty, .exec, target, p.command, p.cwd, null) == .run;
        },
        else => return true,
    }
}

/// The API socket's `commands.run` of `target` (class `effect`) from
/// `caller`: run now, held for the person (answered on `conn` later), or
/// refused — an `unknown` caller only reads.
pub fn askApi(app: *App, caller: Caller, conn: u32, id_json: []const u8, target: []const u8, effect: Effect) Allocator.Error!Outcome {
    if (caller == .unknown) {
        try logAs(app, caller, .api_run, effect, target, .denied, "policy");
        return .refused;
    }
    const owned = try app.gpa.dupe(u8, id_json);
    errdefer app.gpa.free(owned);
    const out = try decide(app, caller, .api_run, effect, target, &.{}, null, .{ .conn = conn, .id_json = owned });
    if (out != .held) app.gpa.free(owned);
    return out;
}

/// The agent face's `saveDocument` of `path` from `caller`: write class,
/// so run now, held for the person (answered on `conn`), or refused.
pub fn askIde(app: *App, caller: Caller, conn: u32, id_json: []const u8, path: []const u8) Allocator.Error!Outcome {
    const owned = try app.gpa.dupe(u8, id_json);
    errdefer app.gpa.free(owned);
    const out = try decide(app, caller, .ide_save, .write, path, &.{}, null, .{ .conn = conn, .id_json = owned, .ide = true });
    if (out != .held) app.gpa.free(owned);
    return out;
}

/// An API method that is never held — a read, or `editor.open` — on the
/// audit trail all the same.
pub fn logApi(app: *App, caller: Caller, verb: Verb, effect: Effect, target: []const u8, refused: bool) Allocator.Error!void {
    try logAs(app, caller, verb, effect, target, if (refused) .denied else .free, if (refused) "policy" else null);
}

/// The grants `caller` holds for this run: the file channel's until
/// mnml quits, a pane's while the pane lives (`app/api.zig`).
fn grants(app: *App, caller: Caller) Allocator.Error!?*std.EnumSet(Effect) {
    return switch (caller) {
        .file_channel => &app.ipc_gate.granted,
        .pane => |id| blk: {
            const gop = try app.api.grants.getOrPut(app.gpa, id);
            if (!gop.found_existing) gop.value_ptr.* = .initEmpty();
            break :blk gop.value_ptr;
        },
        .unknown => null,
    };
}

fn decide(app: *App, caller: Caller, verb: Verb, effect: Effect, target: []const u8, argv: []const []const u8, cwd: ?[]const u8, reply: ?ApiReply) Allocator.Error!Outcome {
    if (effect == .view) {
        try logAs(app, caller, verb, effect, target, .free, null);
        return .run;
    }
    if (allowlisted(app, caller, verb, effect, target)) {
        try logAs(app, caller, verb, effect, target, .allowlisted, "config");
        return .run;
    }
    const held = try grants(app, caller) orelse {
        try logAs(app, caller, verb, effect, target, .denied, "policy");
        return .refused;
    };
    if (held.contains(effect)) {
        try logAs(app, caller, verb, effect, target, .granted_session, "session");
        return .run;
    }
    const gpa = app.gpa;
    var req: Request = .{
        .id = app.ipc_gate.next_id,
        .verb = verb,
        .effect = effect,
        .target = try gpa.dupe(u8, target),
        .raised_ms = app.now_ms,
        .caller = caller,
    };
    errdefer req.deinit(gpa);
    if (argv.len > 0) {
        req.argv = try gpa.alloc([]u8, argv.len);
        @memset(req.argv, &.{});
        for (argv, 0..) |a, i| req.argv[i] = try gpa.dupe(u8, a);
    }
    if (cwd) |c| req.cwd = try gpa.dupe(u8, c);
    // Set last: `req.deinit` on the way out of an error frees the
    // caller's copy, which is the caller's to free then.
    req.reply = reply;
    try app.ipc_gate.pending.append(gpa, req);
    app.ipc_gate.next_id += 1;
    try logAs(app, caller, verb, effect, target, .pending, null);
    try raiseToast(app, req);
    return .held;
}

fn allowlisted(app: *const App, caller: Caller, verb: Verb, effect: Effect, target: []const u8) bool {
    const api = app.cfg.api;
    if (verb.runs()) for (api.allow_commands) |id| if (std.mem.eql(u8, id, target)) return true;
    var buf: [32]u8 = undefined;
    const who = caller.name(&buf);
    for (api.clients) |c| {
        if (!std.mem.eql(u8, c.name, who)) continue;
        for (c.allow) |e| if (e == effect) return true;
        if (verb.runs()) for (c.commands) |id| if (std.mem.eql(u8, id, target)) return true;
    }
    return false;
}

fn toastId(buf: []u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, toast_prefix ++ "{d}", .{id}) catch toast_prefix;
}

/// What the toast says: who asks, for what, in which class.
pub fn askText(arena: Allocator, r: Request) Allocator.Error![]u8 {
    return askTextFor(arena, r, "");
}

/// `askText`, with the asking pane's title for an API request:
/// `pane 4 · claude asks to run git.commit (write)`.
pub fn askTextFor(arena: Allocator, r: Request, pane_title: []const u8) Allocator.Error![]u8 {
    return switch (r.verb) {
        .run_command => std.fmt.allocPrint(arena, "a program wants to run {s} ({s}) through the file channel", .{ r.target, @tagName(r.effect) }),
        .open_pty => std.fmt.allocPrint(arena, "a program wants to open a terminal running `{s}` through the file channel", .{r.target}),
        else => switch (r.caller) {
            .pane => |id| if (r.verb == .ide_save)
                std.fmt.allocPrint(arena, "pane {d} · {s} asks to save {s} ({s})", .{ id, pane_title, r.target, @tagName(r.effect) })
            else
                std.fmt.allocPrint(arena, "pane {d} · {s} asks to run {s} ({s})", .{ id, pane_title, r.target, @tagName(r.effect) }),
            else => std.fmt.allocPrint(arena, "a program asks to run {s} ({s}) over the API", .{ r.target, @tagName(r.effect) }),
        },
    };
}

fn paneTitle(app: *App, caller: Caller) []const u8 {
    return switch (caller) {
        .pane => |id| if (app.panes.get(id)) |p| p.title() else "a closed pane",
        else => "",
    };
}

fn raiseToast(app: *App, r: Request) Allocator.Error!void {
    var buf: [32]u8 = undefined;
    const id = toastId(&buf, r.id);
    try app.toastPersistent(id, try askTextFor(app.frame.allocator(), r, paneTitle(app, r.caller)), .warn);
    const label = try app.gpa.dupe(u8, toast_label);
    app.attachToastAction(id, .{ .ipc_review = .{ .label = label, .request = r.id } });
}

fn dismissToast(app: *App, id: u32) void {
    var buf: [32]u8 = undefined;
    app.dismissToast(toastId(&buf, id));
}

/// Whether hover target `id` is a toast this gate raised, or its button.
pub fn isGateToast(app: *const App, id: u32) bool {
    const toast_ui = @import("../ui/toast.zig");
    if (id < toast_ui.button_base) return false;
    const i = if (id >= toast_ui.close_base) id - toast_ui.close_base else if (id >= toast_ui.action_base) id - toast_ui.action_base else id - toast_ui.button_base;
    if (i >= app.toasts.items.len) return false;
    const a = app.toasts.items[app.toasts.items.len - 1 - i].action orelse return false;
    return a == .ipc_review;
}

pub const choices_by_effect = std.EnumArray(Effect, [4]Confirm.Choice).init(.{
    .view = choices("view"),
    .edit = choices("edit"),
    .write = choices("write"),
    .exec = choices("exec"),
});

fn choices(comptime class: []const u8) [4]Confirm.Choice {
    return .{
        .{ .key = 'a', .label = "Allow once" },
        .{ .key = 'f', .label = "Allow " ++ class ++ " for the session" },
        .{ .key = 'd', .label = "Deny" },
        .{ .key = 'c', .label = "Cancel" },
    };
}

/// `Review`: the confirm box for request `id`. A request already
/// answered (or timed out) says so.
pub fn review(app: *App, id: u32) Allocator.Error!void {
    const i = app.ipc_gate.find(id) orelse {
        app.toast("that request was already answered", .{});
        return;
    };
    const r = app.ipc_gate.pending.items[i];
    const what = try std.fmt.allocPrint(app.frame.allocator(), "{s} {s}", .{ r.verb.word(), r.target });
    const from = switch (r.caller) {
        .pane => |pid| try std.fmt.allocPrint(app.frame.allocator(), "Asked over the API by pane {d} · {s}.", .{ pid, paneTitle(app, r.caller) }),
        else => "Written to .mnml/ipc/command by a program in a pane.",
    };
    const msg = try std.fmt.allocPrint(app.gpa, "{s}\nclass: {s}. {s}", .{ what, @tagName(r.effect), from });
    errdefer app.gpa.free(msg);
    const cs = choices_by_effect.getPtrConst(r.effect);
    const back: ?app_mod.FocusId = if (app.overlay == .none) app.focus else null;
    app.overlay.deinit(app.gpa);
    app.overlay = .{
        .confirm = .{
            // Cancel holds the focus: Enter on a box nobody meant to raise
            // leaves the request waiting, it does not let it through.
            .state = .{ .title = if (r.caller == .pane) "A pane asks" else "The file channel asks", .message = msg, .choices = cs, .selected = cs.len - 1 },
            .purpose = .{ .ipc_grant = id },
            .message = msg,
            .return_focus = back,
        },
    };
    app.focus = .overlay;
}

/// The box's answer. 0 allow once · 1 allow the class for the session ·
/// 2 deny · 3 cancel (back on its toast).
pub fn answer(app: *App, id: u32, choice: usize) Allocator.Error!void {
    const i = app.ipc_gate.find(id) orelse return;
    switch (choice) {
        0 => try release(app, i, .granted_once, "user"),
        1 => {
            const effect = app.ipc_gate.pending.items[i].effect;
            const caller = app.ipc_gate.pending.items[i].caller;
            if (try grants(app, caller)) |g| g.insert(effect);
            try release(app, i, .granted_session, "user");
            // The rest of the same class from the same caller waiting
            // behind it goes too.
            var j: usize = 0;
            while (j < app.ipc_gate.pending.items.len) {
                const other = app.ipc_gate.pending.items[j];
                if (other.effect == effect and other.caller.eql(caller)) {
                    try release(app, j, .granted_session, "session");
                } else j += 1;
            }
        },
        2 => try deny(app, i, .denied, "user"),
        else => try raiseToast(app, app.ipc_gate.pending.items[i]),
    }
}

/// The box closed unanswered (Esc): the request goes back on its toast.
pub fn overlayClosing(app: *App) void {
    if (app.overlay != .confirm) return;
    switch (app.overlay.confirm.purpose) {
        .ipc_grant => |id| if (app.ipc_gate.find(id)) |i| raiseToast(app, app.ipc_gate.pending.items[i]) catch {},
        else => {},
    }
}

fn take(app: *App, i: usize) Request {
    const r = app.ipc_gate.pending.orderedRemove(i);
    dismissToast(app, r.id);
    return r;
}

fn release(app: *App, i: usize, decision: Decision, by: []const u8) Allocator.Error!void {
    const r = take(app, i);
    defer r.deinit(app.gpa);
    try logAs(app, r.caller, r.verb, r.effect, r.target, decision, by);
    switch (r.verb) {
        .ide_save, .ide_tool => if (r.reply) |a| try @import("ide.zig").saveAndReply(app, a, r.target),
        .run_command, .api_run, .api_open, .api_read => {
            const ref = command.resolve(app, r.target) orelse {
                if (r.reply) |a| try api_app.replyError(app, a.conn, a.id_json, api_app.err_no_such, "no such command") else app.toast("run-command: no such command `{s}`", .{r.target});
                return;
            };
            if (r.reply) |a| {
                try api_app.runAndReply(app, a.conn, a.id_json, ref);
            } else command.run(app, ref) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .open_pty => {
            const argv = try app.frame.allocator().alloc([]const u8, r.argv.len);
            for (r.argv, 0..) |a, k| argv[k] = try app.frame.allocator().dupe(u8, a);
            const cwd: ?[]const u8 = if (r.cwd) |c| try app.frame.allocator().dupe(u8, c) else null;
            try ipc.effects.openPty(app, .{ .cwd = cwd, .command = argv });
        },
    }
    app.needs_render = true;
}

fn deny(app: *App, i: usize, decision: Decision, by: []const u8) Allocator.Error!void {
    const r = take(app, i);
    defer r.deinit(app.gpa);
    try logAs(app, r.caller, r.verb, r.effect, r.target, decision, by);
    const why = if (decision == .timed_out) "nobody answered in time" else "the user said no";
    if (r.reply) |a| if (a.ide) try @import("ide.zig").replyToolError(app, a.conn, a.id_json, why) else try api_app.replyError(app, a.conn, a.id_json, api_app.err_denied, why);
    // A box still up for it goes with it.
    if (app.overlay == .confirm) switch (app.overlay.confirm.purpose) {
        .ipc_grant => |id| if (id == r.id) {
            const back = app.overlay.confirm.return_focus;
            app.overlay.deinit(app.gpa);
            app.overlay = .none;
            app.focus = back orelse if (app.active) |a| .{ .pane = a } else .tree;
        },
        else => {},
    };
    app.toast("denied: {s} {s}", .{ r.verb.word(), r.target });
}

/// `caller` is gone (its pane closed): what it was waiting on is denied.
pub fn dropCaller(app: *App, caller: Caller) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.ipc_gate.pending.items.len) {
        if (app.ipc_gate.pending.items[i].caller.eql(caller)) {
            try deny(app, i, .denied, "closed");
        } else i += 1;
    }
}

/// Connection `conn` hung up: its requests are withdrawn, unanswered.
pub fn dropConn(app: *App, conn: u32) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.ipc_gate.pending.items.len) {
        const a = app.ipc_gate.pending.items[i].reply orelse {
            i += 1;
            continue;
        };
        if (a.conn != conn) {
            i += 1;
            continue;
        }
        const r = take(app, i);
        defer r.deinit(app.gpa);
        try logAs(app, r.caller, r.verb, r.effect, r.target, .denied, "disconnect");
    }
}

/// Deny what has waited `timeout_ms`.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.ipc_gate.pending.items.len) {
        if (now - app.ipc_gate.pending.items[i].raised_ms >= timeout_ms) {
            try deny(app, i, .timed_out, "timeout");
        } else i += 1;
    }
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    var next: ?i64 = null;
    for (app.ipc_gate.pending.items) |r| next = @min(next orelse std.math.maxInt(i64), r.raised_ms + timeout_ms);
    return next;
}

fn logAs(app: *App, caller: Caller, verb: Verb, effect: Effect, target: []const u8, decision: Decision, by: ?[]const u8) Allocator.Error!void {
    const gpa = app.gpa;
    var a: std.Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    const w = &a.writer;
    var buf: [32]u8 = undefined;
    writeLine(w, app.now_ms, caller.name(&buf), verb, effect, target, decision, by) catch return error.OutOfMemory;
    const body = a.written();
    // `body` is `{…}`: the event line is the same with its tag first.
    const ev = try std.fmt.allocPrint(gpa, "{{\"event\":\"api\",{s}", .{body[1..]});
    errdefer gpa.free(ev);
    if (decision != .pending) {
        const line = try gpa.dupe(u8, body);
        errdefer gpa.free(line);
        try app.ipc_gate.audit.append(gpa, line);
    }
    try app.ipc_gate.events.append(gpa, ev);
}

fn writeLine(w: *std.Io.Writer, ts: i64, who: []const u8, verb: Verb, effect: Effect, target: []const u8, decision: Decision, by: ?[]const u8) std.Io.Writer.Error!void {
    try w.print("{{\"ts\":{d},\"client\":\"{s}\",\"method\":\"{s}\",\"target\":", .{ ts, who, verb.word() });
    try std.json.Stringify.encodeJsonString(target, .{}, w);
    try w.print(",\"class\":\"{s}\",\"decision\":\"{s}\"", .{ @tagName(effect), decision.word() });
    if (by) |b| try w.print(",\"by\":\"{s}\"", .{b});
    try w.writeAll("}");
}

/// The loop's turn: the audit lines into `<ipc>/audit.jsonl`, the event
/// lines into `events.jsonl`. With no channel they are dropped, so the
/// lists never outgrow a turn.
pub fn flush(app: *App, ch: ?*ipc.Channel, arena: Allocator) void {
    const s = &app.ipc_gate;
    defer {
        for (s.audit.items) |l| app.gpa.free(l);
        s.audit.clearRetainingCapacity();
        for (s.events.items) |l| app.gpa.free(l);
        s.events.clearRetainingCapacity();
    }
    const c = ch orelse return;
    if (s.audit.items.len > 0) {
        if (std.fs.path.join(arena, &.{ c.dir, "audit.jsonl" })) |path| {
            for (s.audit.items) |l| ipc.channel.appendSecret(c.io, path, l) catch {};
        } else |_| {}
    }
    for (s.events.items) |l| c.appendEvent(l);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const event = @import("../core/event.zig");

const Fixture = struct {
    tmp: t.TmpDir,
    app: App,

    fn init(self: *Fixture) !void {
        self.tmp = t.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const ws = pbuf[0..try self.tmp.dir.realPath(t.io, &pbuf)];
        self.app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 100, .rows = 30 });
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.tmp.cleanup();
    }

    /// A line as the terminal loop delivers it: through `App.handle`'s
    /// `.ipc` arm.
    fn line(self: *Fixture, text: []const u8) !void {
        try self.app.handle(.{ .ipc = try event.IpcCommand.create(t.allocator, text) });
    }

    fn panes(self: *Fixture) usize {
        var n: usize = 0;
        for (self.app.panes.slots.items) |s| n += @intFromBool(s != null);
        return n;
    }

    fn lastEvent(self: *Fixture) []const u8 {
        const ev = self.app.ipc_gate.events.items;
        return if (ev.len == 0) "" else ev[ev.len - 1];
    }

    fn hasToastOffer(self: *Fixture) bool {
        for (self.app.toasts.items) |tst| if (tst.action) |a| if (a == .ipc_review) return true;
        return false;
    }
};

const scratch_line = "{\"cmd\":\"run-command\",\"id\":\"scratch.new\"}";
const pty_line = "{\"cmd\":\"open-pty\",\"command\":[\"htop\",\"-d\",\"5\"]}";

test "the commands' classes: a view command, an edit one, a write one, an exec one, and a runtime one" {
    try t.expectEqual(Effect.view, command.effect(.{ .static = .@"toast.dismiss_all" }));
    try t.expectEqual(Effect.edit, command.effect(.{ .static = .@"scratch.new" }));
    try t.expectEqual(Effect.write, command.effect(.{ .static = .@"file.save" }));
    try t.expectEqual(Effect.exec, command.effect(.{ .static = .@"toast.run_action" }));
    try t.expectEqual(Effect.exec, command.effect(.{ .dyn = 0 }));
}

test "the live loop: a view command from the file channel runs, unasked, and is audited as free" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.toast("something", .{});
    try t.expect(f.app.toasts.items.len > 0);
    try f.line("{\"cmd\":\"run-command\",\"id\":\"toast.dismiss_all\"}");
    // Ran: the toast is due to go on the next tick.
    try t.expect(f.app.toasts.items[0].expires_ms < f.app.now_ms);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    try t.expect(std.mem.indexOf(u8, f.app.ipc_gate.audit.items[0], "\"decision\":\"free\"") != null);
}

test "the live loop: an edit command waits on a toast, Review opens the one confirm box, Allow once runs it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    try f.line(scratch_line);
    // Held: nothing ran, the request is on a toast, and no box took the
    // keyboard.
    try t.expectEqual(before, f.panes());
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
    try t.expect(f.hasToastOffer());
    try t.expect(f.app.overlay == .none);
    // Its button and body carry their own hover entry.
    try t.expect(isGateToast(&f.app, @import("../ui/toast.zig").action_base));
    try t.expect(isGateToast(&f.app, @import("../ui/toast.zig").button_base));
    try t.expect(std.mem.indexOf(u8, f.lastEvent(), "\"decision\":\"pending\"") != null);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.audit.items.len);

    // The toast's offer, as a click or `toast.run_action` takes it.
    try command.run(&f.app, .{ .static = .@"toast.run_action" });
    try t.expect(f.app.overlay == .confirm);
    const c = f.app.overlay.confirm;
    try t.expect(c.purpose == .ipc_grant);
    try t.expectEqual(c.state.choices.len - 1, c.state.selected); // Cancel holds the focus
    try t.expect(std.mem.indexOf(u8, c.message, "run-command scratch.new") != null);
    try t.expectEqualStrings("Allow edit for the session", c.state.choices[1].label);

    try f.app.handle(.{ .key = .char('a') });
    try t.expect(f.app.overlay == .none);
    try t.expectEqual(before + 1, f.panes());
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    try t.expect(!f.hasToastOffer());
    try t.expect(std.mem.indexOf(u8, f.app.ipc_gate.audit.items[0], "\"decision\":\"granted-once\",\"by\":\"user\"") != null);
    // Once is once: the next one asks again.
    try f.line(scratch_line);
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
}

test "the live loop: open-pty asks, and Deny leaves no terminal, toasts it, and audits who said no" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    try f.line(pty_line);
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
    const r = f.app.ipc_gate.pending.items[0];
    try t.expectEqual(Verb.open_pty, r.verb);
    try t.expectEqual(Effect.exec, r.effect);
    try t.expectEqualStrings("htop -d 5", r.target);
    try review(&f.app, r.id);
    try f.app.handle(.{ .key = .char('d') });
    try t.expectEqual(before, f.panes());
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    const a = f.app.ipc_gate.audit.items[0];
    try t.expect(std.mem.indexOf(u8, a, "\"method\":\"open-pty\",\"target\":\"htop -d 5\",\"class\":\"exec\",\"decision\":\"denied\",\"by\":\"user\"") != null);
}

test "the live loop: Cancel and Esc put the request back on its toast; nothing runs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    try f.line(scratch_line);
    const id = f.app.ipc_gate.pending.items[0].id;
    try command.run(&f.app, .{ .static = .@"toast.run_action" });
    try t.expect(!f.hasToastOffer()); // the box holds it now
    try f.app.handle(.{ .key = .named(.enter) }); // Enter on the focused Cancel
    try t.expect(f.app.overlay == .none);
    try t.expect(f.hasToastOffer());
    // The toast's offer again (it leaves the screen as the box opens),
    // and Esc this time.
    try command.run(&f.app, .{ .static = .@"toast.run_action" });
    try t.expect(!f.hasToastOffer());
    try t.expect(f.app.overlay == .confirm and f.app.overlay.confirm.purpose.ipc_grant == id);
    try f.app.handle(.{ .key = .named(.esc) });
    try t.expect(f.app.overlay == .none);
    try t.expect(f.hasToastOffer());
    try t.expectEqual(before, f.panes());
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
}

test "the live loop: nothing answered is denied at the timeout, and a box still up for it closes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    f.app.now_ms = 1000;
    try f.line(scratch_line);
    try t.expectEqual(@as(?i64, 1000 + timeout_ms), nextDeadlineMs(&f.app));
    try review(&f.app, f.app.ipc_gate.pending.items[0].id);
    try tick(&f.app, 1000 + timeout_ms - 1);
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
    try tick(&f.app, 1000 + timeout_ms);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    try t.expect(f.app.overlay == .none);
    try t.expect(!f.hasToastOffer());
    try t.expectEqual(before, f.panes());
    try t.expectEqual(@as(?i64, null), nextDeadlineMs(&f.app));
    try t.expect(std.mem.indexOf(u8, f.app.ipc_gate.audit.items[0], "\"decision\":\"timed-out\",\"by\":\"timeout\"") != null);
}

test "the live loop: Allow for the session lets that class through until mnml quits — and only that class" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    try f.line(scratch_line);
    try f.line(scratch_line);
    try t.expectEqual(@as(usize, 2), f.app.ipc_gate.pending.items.len);
    try review(&f.app, f.app.ipc_gate.pending.items[0].id);
    try f.app.handle(.{ .key = .char('f') });
    // Both ran: the one answered and the one of its class behind it.
    try t.expectEqual(before + 2, f.panes());
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    // The next one goes straight through…
    try f.line(scratch_line);
    try t.expectEqual(before + 3, f.panes());
    try t.expect(std.mem.indexOf(u8, f.lastEvent(), "\"decision\":\"granted-session\",\"by\":\"session\"") != null);
    // …but an exec request still asks.
    try f.line(pty_line);
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
}

test "the live loop: config.zon's .api lets a command through by id, and the file-channel row by class" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    f.app.cfg.api.allow_commands = &.{"scratch.new"};
    try f.line(scratch_line);
    try t.expectEqual(before + 1, f.panes());
    try t.expect(std.mem.indexOf(u8, f.lastEvent(), "\"decision\":\"allowlisted\",\"by\":\"config\"") != null);
    f.app.cfg.api.allow_commands = &.{};
    // A row for another client is not this one.
    f.app.cfg.api.clients = &.{.{ .name = "pre-commit", .allow = &.{.edit} }};
    try f.line(scratch_line);
    try t.expectEqual(@as(usize, 1), f.app.ipc_gate.pending.items.len);
    f.app.cfg.api.clients = &.{.{ .name = client, .allow = &.{.edit} }};
    try f.line(scratch_line);
    try t.expectEqual(before + 2, f.panes());
    f.app.cfg.api.clients = &.{.{ .name = client, .commands = &.{"scratch.new"} }};
    try f.line(scratch_line);
    try t.expectEqual(before + 3, f.panes());
    f.app.cfg.api.clients = &.{};
}

test "the headless driver's dispatcher is not gated: the .test runner's run-command runs as it always has" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = f.panes();
    // `AppDriver.vIpcCommand` is exactly this call.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const cmd = try ipc.command.parse(arena_state.allocator(), scratch_line);
    try t.expect(try ipc.effects.applyTier2(&f.app, &cmd));
    try t.expectEqual(before + 1, f.panes());
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.pending.items.len);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.events.items.len);
}

test "flush: the decisions land in <ipc>/audit.jsonl and as api lines in events.jsonl; with no channel they are dropped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var ch = try ipc.Channel.init(t.allocator, t.io, f.app.workspace, .{});
    defer ch.deinit();
    f.app.now_ms = 42;
    try f.line(scratch_line);
    try review(&f.app, f.app.ipc_gate.pending.items[0].id);
    try f.app.handle(.{ .key = .char('d') });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    flush(&f.app, &ch, arena);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.audit.items.len);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.events.items.len);
    const audit = try std.Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ ch.dir, "audit.jsonl" }), arena, .limited(1 << 16));
    try t.expectEqualStrings("{\"ts\":42,\"client\":\"file-channel\",\"method\":\"run-command\",\"target\":\"scratch.new\",\"class\":\"edit\",\"decision\":\"denied\",\"by\":\"user\"}\n", audit);
    const events = try std.Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ ch.dir, "events.jsonl" }), arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, events, "{\"event\":\"api\",\"ts\":42,\"client\":\"file-channel\",\"method\":\"run-command\",\"target\":\"scratch.new\",\"class\":\"edit\",\"decision\":\"pending\"}") != null);
    try t.expect(std.mem.indexOf(u8, events, "\"decision\":\"denied\",\"by\":\"user\"") != null);

    try f.line(scratch_line);
    flush(&f.app, null, arena);
    try t.expectEqual(@as(usize, 0), f.app.ipc_gate.events.items.len);
}
