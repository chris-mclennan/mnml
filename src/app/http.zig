//! The HTTP subsystem's state and its spine: opening a request pane
//! (blank, from a file, from a parsed request), firing a send on a
//! worker in `State.group`, adopting the `.http` event, the env the
//! request expands against, writing the pane back into its source
//! file, and the core `http.*` runners. The long tail — envs, history,
//! captured traffic, imports, cookies, JWT, SSE, chains, bench — is
//! `cmd_http.zig`.
//!
//! D1: a `client.JobResult` is owned by the event; `handle` moves the
//! response into the pane or drops the box. D3: every worker runs in
//! `State.group`; `deinit` cancels before anything it borrows goes.

const std = @import("std");
const repeat = @import("mnml_sdk").zig_compat.repeat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const parse = @import("../http/parse.zig");
const multipart = @import("../http/multipart.zig");
const body_mod = @import("../http/body.zig");
const client = @import("../http/client.zig");
const env_mod = @import("../http/env.zig");
const history = @import("../http/history.zig");
const mock = @import("../http/mock.zig");
const cookies = @import("../http/cookies.zig");
const bench_mod = @import("../http/bench.zig");
const script_mod = @import("../http/script.zig");
const request_pane = @import("request_pane.zig");
const view = @import("../ui/request_view.zig");
const Prompt = app_mod.Prompt;
const fuzzy = @import("../ui/fuzzy.zig");
const completion_view = @import("../ui/completion_view.zig");
const Key = @import("../core/key.zig").Key;
const editor_view = @import("../ui/editor_view.zig");
const Ui = @import("../ui/context.zig");
const jobs = @import("jobs.zig");

/// The JOBS list's keys for the http work that is not one send: they
/// sit above every job id `nextJob` hands out.
pub const chain_job_key: u64 = std.math.maxInt(u64);
pub const sync_job_key: u64 = std.math.maxInt(u64) - 1;
pub const bench_job_key: u64 = std.math.maxInt(u64) - 2;

pub const Request = parse.Request;
pub const Response = client.Response;
pub const RequestPane = request_pane.RequestPane;
pub const JobResult = client.JobResult;

/// In-flight state of a `fan_envs` run: one job per env, one toast at
/// the end.
pub const Fan = struct {
    total: usize,
    done: usize = 0,
    ok: usize = 0,
    started_ms: i64,
    /// `env: status (ms)` per job, owned.
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    /// The clipboard table, owned.
    table: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Fan, gpa: Allocator) void {
        for (self.lines.items) |l| gpa.free(l);
        self.lines.deinit(gpa);
        self.table.deinit(gpa);
    }
};

/// In-flight state of an `http.bench` run.
pub const Bench = struct {
    total: usize,
    started_ms: i64,
    url: []u8 = &.{},
    samples: std.ArrayListUnmanaged(bench_mod.Sample) = .empty,
    errors: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Bench, gpa: Allocator) void {
        gpa.free(self.url);
        self.samples.deinit(gpa);
        for (self.errors.items) |e| gpa.free(e);
        self.errors.deinit(gpa);
    }
};

/// A send that may stream owns its `Io.Group`, so `http.cancel` can
/// interrupt that one read without touching the other workers.
pub const JobHandle = struct {
    group: Io.Group = .init,
    pane: ?PaneId,
};

pub const State = struct {
    group: Io.Group = .init,
    /// Per-job groups of the sends in flight, by job id.
    handles: std.AutoArrayHashMapUnmanaged(u64, *JobHandle) = .empty,
    next_job: u64 = 1,
    /// `http.pick_env`'s session choice. Owned.
    env_override: ?[]u8 = null,
    /// Rows behind the history / captured pickers, on their own arena
    /// so a pick can read the row it names.
    picker_arena: std.heap.ArenaAllocator,
    history_rows: []history.Row = &.{},
    captured_curls: []const []const u8 = &.{},
    /// The env var an edit-value prompt is for. Owned.
    pending_env_key: ?[]u8 = null,
    fan: ?Fan = null,
    bench: ?Bench = null,
    /// The cookie jar, loaded on first use.
    jar: ?cookies.Jar = null,
    /// A picker title built at open time (the state borrows it). Owned.
    picker_title: ?[]u8 = null,
    /// The request pane a lookup fired; its response feeds the item picker.
    lookup_pane: ?PaneId = null,
    chain_running: bool = false,
    sync_running: bool = false,
    auto_format_body: bool = true,
    sync_normalize: bool = false,
    /// Panes whose send is in flight, for the spinner.
    sending: u32 = 0,
    /// `http.send_streaming`: the next `fire` streams whatever comes.
    force_stream: bool = false,
    /// Which HTTP hook is being emitted, for `mnml.http.send`'s rules.
    hook: enum { none, request, response } = .none,
    /// A send `mnml.http.send` asked for from inside `http_response`;
    /// fired once the hook returns.
    resend_pane: ?PaneId = null,
    /// The workspace's header usage, for the Headers tab's completion;
    /// rebuilt after `header_scan_ttl_ms`.
    header_scan: ?*HeaderScan = null,
    /// The `{{VAR}}` the quick-fix menu was opened on. Owned.
    quick_fix_var: ?[]u8 = null,
    /// Lines a `.ws` file queued for a pane that is still connecting.
    ws_queue: std.ArrayListUnmanaged(struct { pane: PaneId, text: []u8 }) = .empty,
    /// The `{{` completion popup over a request field, while it is open.
    completion: ?VarCompletion = null,
    /// The env files' stamp at the last tick (`env_mod.digest`); a move
    /// reloads the ENVS section and says so.
    env_watch: EnvWatch = .{},
    /// The request picker's rows (`http_ops.findCmd`), on `picker_arena`.
    find_rows: []const @import("http_ops.zig").FindRow = &.{},
    /// What `http.move_request`'s folder picker moves. Owned.
    move_target: ?@import("http_ops.zig").Target = null,

    pub fn init(gpa: Allocator) State {
        return .{ .picker_arena = .init(gpa) };
    }

    /// Cancels every worker and waits — they borrow `app.events`.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        for (self.handles.values()) |h| {
            h.group.cancel(io);
            gpa.destroy(h);
        }
        self.handles.deinit(gpa);
        if (self.env_override) |e| gpa.free(e);
        if (self.quick_fix_var) |v| gpa.free(v);
        if (self.pending_env_key) |k| gpa.free(k);
        if (self.fan) |*f| f.deinit(gpa);
        if (self.bench) |*b| b.deinit(gpa);
        if (self.jar) |*j| j.deinit();
        if (self.picker_title) |t| gpa.free(t);
        for (self.ws_queue.items) |q| gpa.free(q.text);
        self.ws_queue.deinit(gpa);
        if (self.completion) |*c| c.arena.deinit();
        if (self.move_target) |t| t.deinit(gpa);
        self.picker_arena.deinit();
        if (self.header_scan) |hs| hs.destroy(gpa);
    }

    pub fn nextJob(self: *State) u64 {
        const id = self.next_job;
        self.next_job += 1;
        return id;
    }
};

// ─── the command table ──────────────────────────────────────────────────

pub const table = .{
    .@"http.send" = &sendCmd,
    .@"http.new" = &newCmd,
    .@"http.cycle_method" = &cycleMethodCmd,
    .@"http.set_method.get" = &setGet,
    .@"http.set_method.post" = &setPost,
    .@"http.set_method.put" = &setPut,
    .@"http.set_method.patch" = &setPatch,
    .@"http.set_method.delete" = &setDelete,
    .@"http.set_method.head" = &setHead,
    .@"http.set_method.options" = &setOptions,
    .@"http.toggle_view" = &toggleViewCmd,
    .@"http.view_source" = &viewSourceCmd,
    .@"http.next_block" = &nextBlockCmd,
    .@"http.prev_block" = &prevBlockCmd,
    .@"http.copy_curl" = &copyCurlCmd,
    .@"http.paste_curl" = &pasteCurlCmd,
    .@"http.paste_source" = &pasteSourceCmd,
    .@"http.format_body" = &formatBodyCmd,
    .@"http.params_add" = &paramsAddCmd,
    .@"http.params_clear" = &paramsClearCmd,
    .@"http.replay_mock" = &replayMockCmd,
    .@"http.save_mock" = &saveMockCmd,
    .@"http.diff_last_two" = &diffLastTwoCmd,
    .@"http.save" = &saveCmd,
    .@"http.copy_response_body" = &copyResponseBodyCmd,
    .@"http.copy_response_headers" = &copyResponseHeadersCmd,
    .@"http.copy_response_cookies" = &copyResponseCookiesCmd,
    .@"http.copy_response_timeline" = &copyResponseTimelineCmd,
    .@"http.copy_response_tests" = &copyResponseTestsCmd,
    .@"http.toggle_response_wrap" = &toggleWrapCmd,
    .@"http.toggle_auto_format_body" = &toggleAutoFormatCmd,
    .@"http.field_copy" = &fieldCopyCmd,
    .@"http.field_paste" = &fieldPasteCmd,
    .@"http.field_cut" = &fieldCutCmd,
    .@"http.field_select_all" = &fieldSelectAllCmd,
    .@"http.abort" = &abortCmd,
    .@"http.cancel" = &cancelCmd,
    .@"http.regenerate_body" = &regenerateBodyCmd,
    .@"http.copy_as" = &copyAsCmd,
    .@"http.generate_code" = &copyAsCmd,
    .@"http.toggle_edit_split" = &toggleEditSplitCmd,
    .@"http.toggle_split_orientation" = &toggleSplitOrientationCmd,
    .@"http.quick_fix" = &quickFixCmd,
    .@"http.define_var" = &defineVarCmd,
    .@"http.inline_var" = &inlineVarCmd,
    .@"http.copy_var_name" = &copyVarNameCmd,
    .@"http.refresh" = &refreshCmd,
    .@"http.save_response" = &saveResponseCmd,
    .@"http.toggle_insecure" = &toggleInsecureCmd,
    .@"http.set_timeout" = &setTimeoutCmd,
    .@"http.toggle_follow_redirects" = &toggleFollowRedirectsCmd,
    .@"http.set_max_redirects" = &setMaxRedirectsCmd,
    .@"http.set_proxy" = &setProxyCmd,
    .@"http.complete_var" = &completeVarCmd,
    .@"http.set_path_param" = &setPathParamCmd,
    .@"http.cycle_body_type" = &cycleBodyTypeCmd,
    .@"http.body_type_raw" = &bodyTypeRawCmd,
    .@"http.body_type_json" = &bodyTypeJsonCmd,
    .@"http.body_type_form" = &bodyTypeFormCmd,
    .@"http.body_type_multipart" = &bodyTypeMultipartCmd,
    .@"http.set_description" = &setDescriptionCmd,
    .@"http.set_tags" = &setTagsCmd,
};

// ─── the `{{` completion ────────────────────────────────────────────────
//
// Typing `{{` in the URL, a header value, a param cell or the body
// opens the LSP completion popup (`ui/completion_view.zig`) with the
// active env's names, the `$` built-ins and the block's `@capture`
// names; each row shows the resolved value dimmed (a secret masked, a
// built-in as a fresh sample). What is typed after `{{` filters;
// Enter / Tab insert `name}}`; Esc, a `}` or a space closes it.

pub const VarCompletion = struct {
    pane: PaneId,
    field: request_pane.CompletionField,
    /// The byte after `{{`; the word typed since is `text[start..caret]`.
    start: usize,
    arena: std.heap.ArenaAllocator,
    items: []const Item,
    selected: usize = 0,
    scroll: usize = 0,
    /// Opened by `http.complete_var` with no `{{` before the caret: the
    /// accept writes the braces too.
    bare: bool = false,

    pub const Item = struct { name: []const u8, kind: []const u8, detail: []const u8 };
};

const dynamic_names = [_][]const u8{ "uuid", "guid", "timestamp", "epochMs", "randomInt", "isoTimestamp", "date" };

/// The rows: the env file's names, the built-ins, the block's captures.
fn buildVarItems(app: *App, rp: *RequestPane, arena: Allocator) Allocator.Error![]const VarCompletion.Item {
    var out: std.ArrayListUnmanaged(VarCompletion.Item) = .empty;
    var set = try loadEnv(app, arena);
    for (set.vars.keys()) |name| {
        const value = set.vars.get(name) orelse continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, name), .kind = "env", .detail = try arena.dupe(u8, env_mod.masked(name, value, &set)) });
    }
    for (dynamic_names) |name| {
        const sample = (try env_mod.dynamicVar(arena, app.io, name)) orelse "";
        try out.append(arena, .{ .name = try std.fmt.allocPrint(arena, "${s}", .{name}), .kind = "built-in", .detail = sample });
    }
    const script = try script_mod.parse(arena, rp.request.script orelse "");
    for (script.captures) |c| {
        var seen = false;
        for (out.items) |it| if (std.mem.eql(u8, it.name, c.name)) {
            seen = true;
            break;
        };
        if (seen) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, c.name), .kind = "capture", .detail = if (set.get(c.name)) |v| try arena.dupe(u8, env_mod.masked(c.name, v, &set)) else "(set by the response)" });
    }
    return out.items;
}

pub fn closeVarCompletion(app: *App) void {
    if (app.http.completion) |*c| c.arena.deinit();
    app.http.completion = null;
    app.needs_render = true;
}

fn openVarCompletion(app: *App, id: PaneId, rp: *RequestPane, field: request_pane.CompletionField, start: usize, bare: bool) Allocator.Error!void {
    closeVarCompletion(app);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    errdefer arena.deinit();
    const items = try buildVarItems(app, rp, arena.allocator());
    if (items.len == 0) {
        arena.deinit();
        app.toast("no variables in the env — {{{{ }}}} completes env names, $ built-ins and @capture names", .{});
        return;
    }
    // The Headers table's own name / value popup yields to this one.
    rp.closeCompletion();
    app.http.completion = .{ .pane = id, .field = field, .start = start, .arena = arena, .items = items, .bare = bare };
    app.needs_render = true;
}

/// After an edit in a request field: a `{{` just typed opens the
/// popup; an open popup follows the word or closes when the caret left it.
pub fn afterFieldEdit(app: *App, id: PaneId, rp: *RequestPane) Allocator.Error!void {
    const f = rp.completionBuf() orelse return closeVarCompletion(app);
    const text = f.buf.items;
    const caret = @min(f.caret.*, text.len);
    if (app.http.completion) |*c| if (c.pane == id) {
        if (c.field != f.field or caret < c.start) return closeVarCompletion(app);
        const word = text[c.start..caret];
        if (std.mem.indexOfAny(u8, word, "}{ \t\n") != null) return closeVarCompletion(app);
        c.selected = 0;
        return;
    };
    if (caret >= 2 and std.mem.eql(u8, text[caret - 2 .. caret], "{{")) try openVarCompletion(app, id, rp, f.field, caret, false);
}

/// The rows that match the word typed so far, best first (indices).
pub fn visibleVarCompletions(app: *App, rp: *RequestPane, arena: Allocator) Allocator.Error![]u32 {
    const c = &(app.http.completion orelse return &.{});
    const f = rp.completionBuf() orelse return &.{};
    const text = f.buf.items;
    const caret = @min(f.caret.*, text.len);
    const word = if (caret >= c.start) text[c.start..caret] else "";
    const Scored = struct { idx: u32, score: u32 };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    for (c.items, 0..) |it, i| {
        const score: u32 = if (word.len == 0) fuzzy.base else (fuzzy.score(word, it.name) orelse continue);
        try scored.append(arena, .{ .idx = @intCast(i), .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);
    const out = try arena.alloc(u32, scored.items.len);
    for (scored.items, 0..) |sc, i| out[i] = sc.idx;
    return out;
}

/// A popup key: navigation, accept, dismiss. False lets the field
/// edit the key, after which `afterFieldEdit` re-filters.
pub fn varCompletionKey(app: *App, rp: *RequestPane, k: Key) Allocator.Error!bool {
    const c = &(app.http.completion orelse return false);
    const vis = try visibleVarCompletions(app, rp, app.frame.allocator());
    const n = vis.len;
    const ctrl = k.mods.ctrl and !k.mods.alt;
    switch (k.code) {
        .down => c.selected = @min(c.selected + 1, n -| 1),
        .up => c.selected -|= 1,
        .page_down => c.selected = @min(c.selected + completion_view.max_rows, n -| 1),
        .page_up => c.selected -|= completion_view.max_rows,
        .esc => closeVarCompletion(app),
        .tab, .enter => {
            if (n == 0) {
                closeVarCompletion(app);
                return false;
            }
            try acceptVarCompletion(app, rp, vis[@min(c.selected, n - 1)]);
        },
        .char => |ch| if (ctrl and (ch == 'n' or ch == 'j')) {
            c.selected = @min(c.selected + 1, n -| 1);
        } else if (ctrl and (ch == 'p' or ch == 'k')) {
            c.selected -|= 1;
        } else if (ctrl and ch == 'e') {
            closeVarCompletion(app);
        } else return false,
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// Insert item `idx` as `name}}` over the word typed so far (the
/// braces too when the popup was summoned bare); a `}}` already after
/// the caret is not doubled.
pub fn acceptVarCompletion(app: *App, rp: *RequestPane, idx: u32) Allocator.Error!void {
    const c = &(app.http.completion orelse return);
    defer closeVarCompletion(app);
    if (idx >= c.items.len) return;
    const f = rp.completionBuf() orelse return;
    const gpa = app.gpa;
    const text = f.buf.items;
    const caret = @min(f.caret.*, text.len);
    if (caret < c.start) return;
    const name = c.items[idx].name;
    const closes = !std.mem.startsWith(u8, text[caret..], "}}");
    const insert = try std.fmt.allocPrint(app.frame.allocator(), "{s}{s}{s}", .{ if (c.bare) "{{" else "", name, if (closes) "}}" else "" });
    try f.buf.replaceRange(gpa, c.start, caret - c.start, insert);
    f.caret.* = c.start + insert.len;
    if (!closes) f.caret.* += 2;
    rp.edited = true;
    if (f.field == .url) try rp.commit();
    app.needs_render = true;
}

/// A click on popup row `i` (index into the visible list).
pub fn clickVarCompletion(app: *App, i: usize) Allocator.Error!void {
    const c = &(app.http.completion orelse return);
    const rp = (app.panes.get(c.pane) orelse return).asRequest() orelse return closeVarCompletion(app);
    const vis = try visibleVarCompletions(app, rp, app.frame.allocator());
    if (i >= vis.len) return;
    try acceptVarCompletion(app, rp, vis[i]);
}

/// The popup, drawn after the pane at the field's caret.
pub fn drawVarCompletion(app: *App, ui: Ui, id: PaneId, rp: *RequestPane, area: @import("../ui/rect.zig"), caret: ?@import("../ui/text_field.zig").Caret) Allocator.Error!void {
    const c = &(app.http.completion orelse return);
    if (c.pane != id) return;
    if (app.active != id or app.focus != .pane or rp.block != .request) return closeVarCompletion(app);
    const vis = try visibleVarCompletions(app, rp, ui.arena);
    if (vis.len == 0) return closeVarCompletion(app);
    if (c.selected >= vis.len) c.selected = vis.len - 1;
    const rows = try ui.arena.alloc(completion_view.Row, vis.len);
    for (vis, 0..) |idx, i| {
        const it = c.items[idx];
        rows[i] = .{ .label = it.name, .kind = it.kind, .detail = it.detail };
    }
    const anchor: ?editor_view.Cursor = if (caret) |cc| .{ .x = cc.x, .y = cc.y } else null;
    completion_view.draw(ui, area, anchor, &c.scroll, .{ .rows = rows, .selected = c.selected, .doc = null });
}

/// `http.complete_var`: the popup at the caret of the focused field —
/// after a `{{` as the typing would open it, else bare (the accept
/// writes the braces).
fn completeVarCmd(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const rp = try requireRequest(app);
    const f = rp.completionBuf() orelse return app.diag.fail(app.frame.allocator(), "http: put the caret in the URL, a header, a param or the body first", .{});
    const text = f.buf.items;
    const caret = @min(f.caret.*, text.len);
    // Inside a `{{word` already: complete that word.
    if (std.mem.lastIndexOf(u8, text[0..caret], "{{")) |open| {
        const word = text[open + 2 .. caret];
        if (std.mem.indexOfAny(u8, word, "}{ \t\n") == null) return openVarCompletion(app, id, rp, f.field, open + 2, false);
    }
    try openVarCompletion(app, id, rp, f.field, caret, true);
}

// ─── env ────────────────────────────────────────────────────────────────

/// The env file watch: the stamp the last tick saw, and whether one has
/// looked yet (the first look sets the baseline without a word).
pub const EnvWatch = struct {
    digest: u64 = 0,
    seen: bool = false,
};

/// The 80 ms tick's poll (item 7): the active env's files and the
/// `.mnml/env/` listing are stamped by mtime + size; a change since
/// the last tick rescans the HTTP panel (the ENVS `●`, the counts) and
/// toasts `env: dev reloaded` once. The var tips and the Vars tab
/// read the file at paint time, so they follow on their own.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    _ = now;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const name = (try envName(app, a)) orelse env_mod.fallback_name;
    const stamp = env_mod.digest(app.io, app.workspace, name);
    const w = &app.http.env_watch;
    if (!w.seen) {
        w.seen = true;
        w.digest = stamp;
        return;
    }
    if (stamp == w.digest) return;
    w.digest = stamp;
    if (app.http_panel.scanned_once) try @import("http_panel.zig").refresh(app);
    // A session pick whose file was just deleted is let go, out loud.
    if (app.http.env_override) |o| if (!env_mod.exists(app.io, app.workspace, o)) {
        app.toast("env: {s}.env is gone \u{2014} the pick is dropped", .{o});
        app.gpa.free(o);
        app.http.env_override = null;
        app.needs_render = true;
        return;
    };
    if (try envName(app, a)) |n| app.toast("env: {s} reloaded", .{n}) else app.toast("env: no env file \u{2014} none is active", .{});
    app.needs_render = true;
}

/// mnml wrote an env file itself (a `@capture`, an env prompt, a new
/// env): the watch takes the new stamp without a word, so only an
/// edit from outside reads as a reload.
pub fn restampEnvWatch(app: *App) void {
    const w = &app.http.env_watch;
    if (!w.seen) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const name = (envName(app, arena.allocator()) catch return) orelse env_mod.fallback_name;
    w.digest = env_mod.digest(app.io, app.workspace, name);
}

/// The active env's name: the first selection (`envSelection`'s
/// order) whose file is on disk — `dev` only when `dev.env` is. Null
/// when the workspace has no env file at all, so nothing — the Env
/// chip, a send, the Vars tab — claims one that is not there. A
/// selection whose file is gone is dropped here, wherever it was kept:
/// the session pick (`State.env_override`, in memory), `[http]
/// default_env` in the config, `default_env=` in `<ws>/.rqst/config`,
/// or `$MNML_ENV`.
pub fn envName(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    const sel = (try env_mod.selectExisting(arena, app.io, app.workspace, app.http.env_override, app.env.get("MNML_ENV"), app.cfg.http.default_env)) orelse return null;
    return sel.name;
}

/// The env a WRITE lands in (a new key, an edited value): the selection
/// as named, `dev` when nothing chose one, whether or not its file
/// exists yet — the write creates it.
pub fn envSelection(app: *App, arena: Allocator) Allocator.Error!env_mod.Selection {
    return env_mod.select(arena, app.io, app.workspace, app.http.env_override, app.env.get("MNML_ENV"), app.cfg.http.default_env);
}

/// The env `rp` resolves against: its pin (a history re-fire, the env
/// the history line recorded) while that env's file exists, else the
/// active one.
pub fn paneEnvName(app: *App, rp: *const RequestPane, arena: Allocator) Allocator.Error!?[]const u8 {
    if (livePin(app, rp)) |p| return p;
    return envName(app, arena);
}

fn livePin(app: *App, rp: *const RequestPane) ?[]const u8 {
    const pin = rp.env_pin orelse return null;
    return if (env_mod.exists(app.io, app.workspace, pin)) pin else null;
}

/// `loadEnv` for `rp`: its pinned env when it has one.
pub fn loadEnvFor(app: *App, gpa: Allocator, rp: *const RequestPane) Allocator.Error!env_mod.EnvSet {
    const pin = livePin(app, rp) orelse return loadEnv(app, gpa);
    var set = try env_mod.EnvSet.load(gpa, app.io, app.workspace, pin);
    set.process = &app.env;
    return set;
}

/// The active env, loaded. `gpa` may be an arena. With no env file
/// the set is empty and unnamed; the process environment still answers.
pub fn loadEnv(app: *App, gpa: Allocator) Allocator.Error!env_mod.EnvSet {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    var set = if (try envName(app, scratch.allocator())) |name| try env_mod.EnvSet.load(gpa, app.io, app.workspace, name) else env_mod.EnvSet.empty(gpa);
    set.process = &app.env;
    return set;
}

/// Every `{{VAR}}` the pane references, with its resolved value.
pub fn varRows(app: *App, rp: *RequestPane, arena: Allocator, env_name: ?[]const u8) Allocator.Error![]view.VarRow {
    var out: std.ArrayListUnmanaged(view.VarRow) = .empty;
    var set = try env_mod.EnvSet.load(arena, app.io, app.workspace, env_name orelse env_mod.fallback_name);
    set.process = &app.env;
    const sources = [_][]const u8{ rp.url.items, rp.headers_text.items, rp.body.items };
    for (sources) |src| {
        for (try env_mod.tokens(arena, src)) |tok| {
            if (tok.name.len == 0 or tok.name[0] == '$') continue;
            var seen = false;
            for (out.items) |o| if (std.mem.eql(u8, o.name, tok.name)) {
                seen = true;
                break;
            };
            if (seen) continue;
            try out.append(arena, .{ .name = tok.name, .value = set.get(tok.name) });
        }
    }
    return out.items;
}

/// One `{{VAR}}` occurrence in a pane's text, with what a hover shows.
pub const VarToken = struct {
    name: []const u8,
    /// The value as the tip shows it — masked for a secret; null when
    /// the env lacks it.
    shown: ?[]const u8,
    resolved: bool,
    /// A `{{$uuid}}`-style built-in: resolved, never "define in env".
    dynamic: bool,
};

/// Every `{{VAR}}` of the URL / body / headers as view spans, with the
/// flat list their ids index. On `arena`.
pub const VarTokens = struct {
    all: []const VarToken,
    url: []const view.VarSpan,
    body: []const view.VarSpan,
    headers: []const view.VarSpan,
};

pub fn varTokens(app: *App, rp: *RequestPane, arena: Allocator, env_name: ?[]const u8) Allocator.Error!VarTokens {
    var set = try env_mod.EnvSet.load(arena, app.io, app.workspace, env_name orelse env_mod.fallback_name);
    set.process = &app.env;
    var all: std.ArrayListUnmanaged(VarToken) = .empty;
    var spans: [3][]const view.VarSpan = undefined;
    const sources = [_][]const u8{ rp.url.items, rp.body.items, rp.headers_text.items };
    for (sources, 0..) |src, si| {
        var list: std.ArrayListUnmanaged(view.VarSpan) = .empty;
        for (try env_mod.tokens(arena, src)) |tok| {
            if (tok.name.len == 0) continue;
            const dynamic = tok.name[0] == '$';
            const value: ?[]const u8 = if (dynamic) "(built-in)" else set.get(tok.name);
            const id: u32 = @intCast(all.items.len);
            try all.append(arena, .{
                .name = tok.name,
                .shown = if (value) |v| (if (dynamic) v else env_mod.masked(tok.name, v, &set)) else null,
                .resolved = value != null,
                .dynamic = dynamic,
            });
            try list.append(arena, .{ .start = tok.start, .end = tok.end, .resolved = value != null, .id = id });
        }
        spans[si] = list.items;
    }
    return .{ .all = all.items, .url = spans[0], .body = spans[1], .headers = spans[2] };
}

/// The `{{VAR}}` hit under the pointer, if any — a `.script_hit` of
/// `pane` with an id at or past `base`, scanned back to front.
pub fn hoveredVar(ui: Ui, pane: PaneId, base: u32) ?struct { idx: usize, rect: @import("../ui/rect.zig") } {
    const h = ui.hover orelse return null;
    var i = ui.hits.items.items.len;
    while (i > 0) {
        i -= 1;
        const e = ui.hits.items.items[i];
        if (!e.rect.contains(h.x, h.y)) continue;
        switch (e.target) {
            .script_hit => |sh| if (sh.pane == pane and sh.id >= base) return .{ .idx = sh.id - base, .rect = e.rect },
            else => {},
        }
        return null;
    }
    return null;
}

/// A press on a `{{VAR}}` in a request pane: left jumps to its line in
/// the env file, right opens the quick-fix menu.
pub fn varClick(app: *App, id: PaneId, rp: *RequestPane, idx: usize, m: @import("../core/key.zig").Mouse) Allocator.Error!void {
    _ = id;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try varTokens(app, rp, a, try paneEnvName(app, rp, a));
    if (idx >= toks.all.len) return;
    const tok = toks.all[idx];
    if (m.button == .right) return openQuickFixMenu(app, tok.name, tok.dynamic, m.x, m.y);
    if (tok.dynamic) {
        app.toast("{{{{{s}}}}} is a built-in", .{tok.name});
        return;
    }
    jumpToVarDef(app, tok.name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
    };
}

/// Open the active env file on the line that defines `name`, or at its
/// end when the name is missing (the file is created under `.mnml/env`
/// then) so the definition can be typed straight away.
pub fn jumpToVarDef(app: *App, name: []const u8) CommandError!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sel = try envSelection(app, a);
    var target: ?[]const u8 = null;
    var line: ?usize = null;
    for ([_][]const u8{ ".mnml", ".rqst" }) |sub| {
        const path = try env_mod.envPath(a, app.workspace, sub, sel.name);
        const text = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(1 << 20)) catch continue;
        if (target == null) target = path;
        if (env_mod.lineOfKey(text, name)) |n| {
            target = path;
            line = n;
            break;
        }
    }
    const path = target orelse blk: {
        const fresh = try env_mod.envPath(a, app.workspace, ".mnml", sel.name);
        if (std.fs.path.dirname(fresh)) |d| Io.Dir.cwd().createDirPath(app.io, d) catch {};
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = fresh, .data = "" }) catch return app.diag.fail(app.frame.allocator(), "env: cannot create {s}", .{app.relPath(fresh)});
        restampEnvWatch(app);
        break :blk fresh;
    };
    const copy = try app.frame.allocator().dupe(u8, path);
    _ = app.openEditor(copy) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "env: cannot open {s}", .{app.relPath(path)}),
    };
    const e = app.activeEditor() orelse return;
    if (line) |n| {
        e.buf.editor.placeCursor(n, 0);
    } else {
        const last = e.buf.editor.lineCount() -| 1;
        e.buf.editor.placeCursor(last, std.math.maxInt(u32) / 2);
        app.toast("{{{{{s}}}}} is not defined in {s} — append it here", .{ name, app.relPath(path) });
    }
    app.needs_render = true;
}

/// Take the quick-fix menu's `{{VAR}}` out of the state: the caller
/// owns it now.
pub fn takeQuickFix(app: *App) ?[]u8 {
    const v = app.http.quick_fix_var;
    app.http.quick_fix_var = null;
    return v;
}

/// A menu is closing without one of its rows running (Esc, a click
/// elsewhere): the `{{VAR}}` it was opened on must not outlive it, or
/// the next caret-based var command would act on the wrong token.
pub fn overlayClosing(app: *App) void {
    if (app.overlay != .menu) return;
    if (takeQuickFix(app)) |v| app.gpa.free(v);
}

fn setQuickFixVar(app: *App, name: []const u8) Allocator.Error!void {
    const copy = try app.gpa.dupe(u8, name);
    if (app.http.quick_fix_var) |old| app.gpa.free(old);
    app.http.quick_fix_var = copy;
}

/// The quick-fix rows for `{{name}}`. A built-in has nothing to define.
pub fn openQuickFixMenu(app: *App, name: []const u8, dynamic: bool, x: u16, y: u16) Allocator.Error!void {
    try setQuickFixVar(app, name);
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    if (!dynamic) {
        try rows.append(app.gpa, .{ .label = "Define in env…", .action = .{ .command = .@"http.define_var" } });
        try rows.append(app.gpa, .{ .label = "Jump to definition", .action = .{ .command = .@"http.jump_to_env_var" } });
    }
    try rows.append(app.gpa, .{ .label = "Pick env…", .action = .{ .command = .@"http.pick_env" }, .separator_before = !dynamic });
    try rows.append(app.gpa, .{ .label = "Inline value", .action = .{ .command = .@"http.inline_var" } });
    try rows.append(app.gpa, .{ .label = "Copy variable name", .action = .{ .command = .@"http.copy_var_name" }, .separator_before = true });
    const title = try std.fmt.allocPrint(app.frame.allocator(), "{{{{{s}}}}}", .{name});
    try app.openMenu(title, try rows.toOwnedSlice(app.gpa), x, y);
}

/// The `{{VAR}}` a var command acts on: the quick-fix menu's, else the
/// one under the caret of the active request pane, else the Vars row.
/// Always a copy on `arena` — a command that edits the field must not
/// hold a slice of it.
fn currentVar(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (takeQuickFix(app)) |v| {
        defer app.gpa.free(v);
        return try arena.dupe(u8, v);
    }
    const rp = activeRequest(app) orelse {
        if (app.activeEditor()) |e| return if (try editorVarAtCursor(e, arena)) |n| try arena.dupe(u8, n) else null;
        return null;
    };
    if (try rp.varAtCaret(arena)) |n| return try arena.dupe(u8, n);
    if (rp.edit_tab == .vars) {
        const rows = try varRows(app, rp, arena, try paneEnvName(app, rp, arena));
        if (rp.row_cursor < rows.len) return try arena.dupe(u8, rows[rp.row_cursor].name);
    }
    return null;
}

fn quickFixCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const name = (try currentVar(app, arena)) orelse return app.diag.fail(arena, "quick_fix: no {{{{VAR}}}} under the caret", .{});
    const pos: editor_view.Cursor = app.cursor_pos orelse .{ .x = 0, .y = 0 };
    try openQuickFixMenu(app, name, name.len > 0 and name[0] == '$', pos.x, pos.y + 1);
}

fn defineVarCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const name = (try currentVar(app, arena)) orelse return app.diag.fail(arena, "define_var: no {{{{VAR}}}} under the caret", .{});
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    var set = try loadEnv(app, scratch.allocator());
    defer set.deinit();
    try @import("cmd_http.zig").openEnvValuePrompt(app, name, set.get(name) orelse "");
}

fn inlineVarCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const name = (try currentVar(app, arena)) orelse return app.diag.fail(arena, "inline_var: no {{{{VAR}}}} under the caret", .{});
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    var set = try loadEnv(app, scratch.allocator());
    defer set.deinit();
    const pattern = try std.fmt.allocPrint(scratch.allocator(), "{{{{{s}}}}}", .{name});
    const value = try env_mod.expand(scratch.allocator(), app.io, pattern, &set);
    if (std.mem.eql(u8, value, pattern)) return app.diag.fail(arena, "inline_var: {{{{{s}}}}} is not defined in the active env", .{name});
    if (activeRequest(app)) |rp| {
        const n = try rp.inlineVar(name, value);
        app.toast("inlined {{{{{s}}}}} × {d}", .{ name, n });
        return;
    }
    const e = try app.requireEditor();
    const text = e.buf.editor.bytes();
    const fresh = try env_mod.expand(scratch.allocator(), app.io, text, &set);
    e.buf.editor.setText(fresh) catch return error.OutOfMemory;
    e.syntax.dirty = true;
    app.toast("inlined the {{{{VAR}}}}s of the buffer", .{});
}

fn copyVarNameCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const name = (try currentVar(app, arena)) orelse return app.diag.fail(arena, "copy_var_name: no {{{{VAR}}}} under the caret", .{});
    try app.clipboard.copy(name);
    app.toast("copied {s}", .{name});
}

// ─── the same tokens in an editor holding a request file ────────────────

/// The `{{VAR}}` spans of an editor buffer holding a `.http` / `.curl`
/// / `.rest` file, for the editor view's hook; empty for anything else.
pub fn editorVarSpans(app: *App, arena: Allocator, e: *app_mod.EditorPane) Allocator.Error![]editor_view.VarSpan {
    if (!isRequestBuffer(e)) return &.{};
    var set = try loadEnv(app, arena);
    var out: std.ArrayListUnmanaged(editor_view.VarSpan) = .empty;
    for (try env_mod.tokens(arena, e.buf.editor.bytes()), 0..) |tok, i| {
        if (tok.name.len == 0) continue;
        const resolved = tok.name[0] == '$' or set.get(tok.name) != null;
        try out.append(arena, .{ .start = tok.start, .end = tok.end, .resolved = resolved, .id = @intCast(i) });
    }
    return out.items;
}

pub fn isRequestBuffer(e: *app_mod.EditorPane) bool {
    if (e.buf.doc.path) |p| return parse.isRequestPath(p);
    return parse.looksLikeHttpFile(e.buf.editor.bytes());
}

fn editorVarAtCursor(e: *app_mod.EditorPane, arena: Allocator) Allocator.Error!?[]const u8 {
    if (!isRequestBuffer(e)) return null;
    const at = e.buf.editor.cursor;
    for (try env_mod.tokens(arena, e.buf.editor.bytes())) |tok| if (at >= tok.start and at <= tok.end) return tok.name;
    return null;
}

/// `gd` on a `{{VAR}}` in a request file: to its definition. False when
/// the cursor is not on one — the caller carries on with the LSP.
pub fn jumpVarAtCursor(app: *App) CommandError!bool {
    const e = app.activeEditor() orelse return false;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const name = (try editorVarAtCursor(e, arena.allocator())) orelse return false;
    if (name[0] == '$') {
        app.toast("{{{{{s}}}}} is a built-in", .{name});
        return true;
    }
    try jumpToVarDef(app, name);
    return true;
}

/// A press on a `{{VAR}}` span in an editor (the view registered it as
/// `editor_view.var_hit_base + i`).
pub fn editorVarClick(app: *App, id: PaneId, e: *app_mod.EditorPane, hit_id: u32, m: @import("../core/key.zig").Mouse) Allocator.Error!void {
    _ = id;
    if (m.kind != .press or hit_id < editor_view.var_hit_base) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const toks = try env_mod.tokens(arena.allocator(), e.buf.editor.bytes());
    const i = hit_id - editor_view.var_hit_base;
    if (i >= toks.len) return;
    const name = toks[i].name;
    const dynamic = name.len > 0 and name[0] == '$';
    if (m.button == .right) return openQuickFixMenu(app, name, dynamic, m.x, m.y);
    if (dynamic) {
        app.toast("{{{{{s}}}}} is a built-in", .{name});
        return;
    }
    jumpToVarDef(app, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
    };
}

/// The tip for a hovered `{{VAR}}` span in an editor, after the view
/// painted (it registered the hits).
pub fn drawEditorVarTip(app: *App, ui: Ui, id: PaneId, e: *app_mod.EditorPane, area: @import("../ui/rect.zig")) Allocator.Error!void {
    const hv = hoveredVar(ui, id, editor_view.var_hit_base) orelse return;
    const toks = try env_mod.tokens(ui.arena, e.buf.editor.bytes());
    if (hv.idx >= toks.len) return;
    const name = toks[hv.idx].name;
    var set = try loadEnv(app, ui.arena);
    const value: ?[]const u8 = if (name.len > 0 and name[0] == '$') "(built-in)" else if (set.get(name)) |v| env_mod.masked(name, v, &set) else null;
    view.drawVarTip(ui, area, hv.rect, name, value, set.name);
}

pub fn varCount(app: *App, rp: *RequestPane) Allocator.Error!usize {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const name = try envName(app, arena.allocator());
    return (try varRows(app, rp, arena.allocator(), name)).len;
}

/// Enter on a Vars row: the value prompt for that name.
pub fn varRowAction(app: *App, rp: *RequestPane, row: usize) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const name = try envName(app, arena.allocator());
    const rows = try varRows(app, rp, arena.allocator(), name);
    if (row >= rows.len) return;
    try @import("cmd_http.zig").openEnvValuePrompt(app, rows[row].name, rows[row].value orelse "");
}

/// `req` with every `{{VAR}}` expanded against the active env.
pub fn expand(app: *App, gpa: Allocator, req: *const Request) Allocator.Error!Request {
    var set = try loadEnv(app, gpa);
    defer set.deinit();
    return expandWith(gpa, app.io, req, &set);
}

/// The `:name` path segments take their `# @path` values first (`::`
/// becomes `:`); a value may hold a `{{VAR}}`, which the expansion
/// resolves next.
pub fn expandWith(gpa: Allocator, io: Io, req: *const Request, set: *const env_mod.EnvSet) Allocator.Error!Request {
    var out = try req.clone(gpa);
    errdefer out.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const with_path = try parse.substitutePath(scratch.allocator(), req.url, try parse.pathParams(scratch.allocator(), req));
    const url = try env_mod.expand(gpa, io, with_path, set);
    gpa.free(out.url);
    out.url = url;
    for (out.headers.items) |*h| {
        const v = try env_mod.expand(gpa, io, h.value, set);
        gpa.free(h.value);
        h.value = v;
    }
    if (out.body) |b| {
        const nb = try env_mod.expand(gpa, io, b, set);
        gpa.free(b);
        out.body = nb;
    }
    return out;
}

/// Every name `req` templates that `set` cannot resolve, deduplicated:
/// the URL after its `# @path` values land (a value may name a var),
/// each header value, the body (its form / multipart rows included —
/// they are body text until the encoder runs) — exactly what
/// `expandWith` expands. A name an env value names counts too
/// (`BASE=http://{{HOST}}` with no HOST).
pub fn unresolvedIn(arena: Allocator, req: *const Request, set: *const env_mod.EnvSet) Allocator.Error![]const []const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    const url = try parse.substitutePath(arena, req.url, try parse.pathParams(arena, req));
    for (try env_mod.unresolved(arena, url, set)) |m| try seen.put(arena, m, {});
    for (req.headers.items) |h| for (try env_mod.unresolved(arena, h.value, set)) |m| try seen.put(arena, m, {});
    if (req.body) |b| for (try env_mod.unresolved(arena, b, set)) |m| try seen.put(arena, m, {});
    return seen.keys();
}

// ─── panes ──────────────────────────────────────────────────────────────

pub fn activeRequest(app: *App) ?*RequestPane {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .request => |*rp| rp,
        else => null,
    };
}

pub fn requireRequest(app: *App) CommandError!*RequestPane {
    return activeRequest(app) orelse app.diag.fail(app.frame.allocator(), "no active Request pane (:http.new opens one)", .{});
}

/// A blank pane, shown and focused, the caret on the URL.
pub fn openBlank(app: *App) CommandError!PaneId {
    var rp = try RequestPane.init(app.gpa);
    errdefer rp.deinit();
    rp.block = .request;
    rp.field = .url;
    rp.editing = true;
    const id = try app.panes.add(.{ .request = rp });
    app.showPane(id);
    return id;
}

pub const OpenOptions = struct {
    /// Absolute. Duped.
    source_path: ?[]const u8 = null,
    block_name: ?[]const u8 = null,
    block_index: ?u32 = null,
    summary: ?[]const u8 = null,
    /// The keyboard starts in the Response block (a send from a file).
    focus_response: bool = false,
    preview: bool = false,
};

/// A pane holding `req` (ownership moves), shown and focused.
pub fn openFromRequest(app: *App, req: Request, opts: OpenOptions) CommandError!PaneId {
    const gpa = app.gpa;
    var incoming = req;
    errdefer incoming.deinit(gpa);
    var rp = try RequestPane.init(gpa);
    errdefer rp.deinit();
    if (opts.source_path) |p| rp.source_path = try gpa.dupe(u8, p);
    if (opts.block_name) |b| rp.block_name = try gpa.dupe(u8, b);
    rp.block_index = opts.block_index;
    if (opts.summary) |s| rp.summary = try gpa.dupe(u8, s);
    try rp.load(incoming);
    incoming = undefined;
    rp.is_preview = opts.preview;
    if (opts.focus_response) {
        rp.block = .response;
    } else {
        rp.block = .request;
        rp.field = .url;
    }
    // A browse replaces the previous preview pane instead of stacking tabs.
    if (opts.preview) if (findPreview(app)) |old| {
        if (app.panes.get(old)) |p| p.deinit(gpa, app.io);
        app.panes.slots.items[old] = .{ .request = rp };
        app.showPane(old);
        return old;
    };
    const id = try app.panes.add(.{ .request = rp });
    app.showPane(id);
    return id;
}

fn findPreview(app: *App) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.is_preview and !rp.edited) return @intCast(i),
        else => {},
    };
    return null;
}

/// The request pane already showing `path`'s block `index` (named
/// `block_name`). The position is the identity: two bare `###` blocks
/// share the name `""`, and keying on it put block two into block one's
/// pane — whose save then rewrote block one.
pub fn findSource(app: *App, path: []const u8, index: ?u32, block_name: ?[]const u8) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.source_path) |sp| {
            if (!@import("../core/os_path.zig").samePath(sp, path)) continue;
            if ((rp.block_index orelse 0) != (index orelse 0)) continue;
            const same_name = if (block_name) |b| (rp.block_name != null and std.mem.eql(u8, rp.block_name.?, b)) else rp.block_name == null;
            if (same_name) return @intCast(i);
        },
        else => {},
    };
    return null;
}

pub const OpenFileError = CommandError || parse.ParseError || error{ ReadFailed, EmptyFile };

/// Open `path` (absolute) as a request pane on its first block. The
/// error tells `App.openPath` to fall back to an editor.
pub fn openFile(app: *App, path: []const u8, preview: bool) OpenFileError!PaneId {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(16 << 20)) catch return error.ReadFailed;
    const list = try parse.blocks(a, text);
    if (list.len == 0) return error.EmptyFile;
    const first = list[0];
    if (findSource(app, path, 0, first.name)) |id| {
        app.showPane(id);
        return id;
    }
    var req = try parse.parse(app.gpa, first.text);
    errdefer req.deinit(app.gpa);
    // The leading block of a multi-block file is addressed as `null`;
    // a `### name` block by its name.
    const id = try openFromRequest(app, req, .{ .source_path = path, .block_name = first.name, .block_index = 0, .summary = first.summary, .focus_response = false, .preview = preview });
    req = undefined;
    if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        rp.edited = false;
    };
    try app.noteRecent(path);
    return id;
}

/// Open block `idx` (its index in `parse.blocks` of the file's text)
/// of `path` as a request pane — the pane already on it when there is
/// one. The error tells the caller what went wrong.
pub fn openFileBlock(app: *App, path: []const u8, idx: u32) OpenFileError!PaneId {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(16 << 20)) catch return error.ReadFailed;
    const list = try parse.blocks(a, text);
    if (idx >= list.len) return error.EmptyFile;
    const b = list[idx];
    if (findSource(app, path, idx, b.name)) |id| {
        app.showPane(id);
        return id;
    }
    var req = try parse.parse(app.gpa, b.text);
    errdefer req.deinit(app.gpa);
    const id = try openFromRequest(app, req, .{ .source_path = path, .block_name = b.name, .block_index = idx, .summary = b.summary });
    req = undefined;
    if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        rp.edited = false;
    };
    try app.noteRecent(path);
    return id;
}

/// What `http.send` fires from: the block under the cursor of a request
/// file in an editor, or the active request pane's own request.
pub const Active = struct {
    req: Request,
    source_path: ?[]const u8 = null,
    block_name: ?[]const u8 = null,
    block_index: ?u32 = null,
    summary: ?[]const u8 = null,
    /// The request pane it came from, when it did.
    pane: ?PaneId = null,
};

/// `req` is on the gpa; the paths borrow `arena`.
pub fn parseActive(app: *App, arena: Allocator) CommandError!Active {
    const gpa = app.gpa;
    if (activeRequest(app)) |rp| {
        try rp.commit();
        return .{ .req = try rp.request.clone(gpa), .source_path = rp.source_path, .block_name = rp.block_name, .block_index = rp.block_index, .summary = rp.summary, .pane = app.active };
    }
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "http: no active .http/.curl/.rest editor or Request pane", .{});
    const path = e.buf.doc.path;
    const text = e.buf.editor.bytes();
    if (path != null and !parse.isRequestPath(path.?) and !parse.looksLikeHttpFile(text) and std.mem.indexOf(u8, text, "curl") == null) {
        return app.diag.fail(app.frame.allocator(), "http: {s} is not a .http/.curl/.rest file", .{app.relPath(path.?)});
    }
    const list = try parse.blocks(arena, text);
    const line = e.buf.editor.currentLine();
    if (list.len == 0) return app.diag.fail(app.frame.allocator(), "http: the buffer has no request", .{});
    const block = parse.blockAtLine(list, line) orelse return app.diag.fail(app.frame.allocator(), "http: the block under the cursor is empty", .{});
    const req = parse.parse(gpa, block.text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Empty => return app.diag.fail(app.frame.allocator(), "http: the block under the cursor is empty", .{}),
        error.NoUrl => return app.diag.fail(app.frame.allocator(), "http: no URL in the block under the cursor", .{}),
        error.UnterminatedQuote => return app.diag.fail(app.frame.allocator(), "http: unterminated quote in the curl command", .{}),
    };
    return .{ .req = req, .source_path = if (path) |p| try arena.dupe(u8, p) else null, .block_name = block.name, .block_index = block.index, .summary = block.summary };
}

// ─── the send ───────────────────────────────────────────────────────────

/// Whether a send hands its body over as it arrives: `auto` streams
/// an event-stream or a chunked body, `always` streams whatever comes
/// (`http.send_streaming`), `never` is the fan-out / bench / chain shape.
pub const StreamMode = enum { never, auto, always };

const Job = struct {
    id: u64,
    pane: ?PaneId,
    kind: client.JobKind,
    req: Request,
    label: ?[]u8 = null,
    cookie: ?[]u8 = null,
    stream: StreamMode = .never,
    /// Set once the head went out as `.sse`; the end goes the same way.
    streamed: bool = false,
    /// The config's transport defaults with the request's directives
    /// over them; `proxy` points at `proxy_owned`.
    transport: client.Transport = .{},
    proxy_owned: ?[]u8 = null,
    events: *event.EventQueue,
    io: Io,
    gpa: Allocator,

    fn destroy(self: *Job, gpa: Allocator) void {
        self.req.deinit(gpa);
        if (self.label) |l| gpa.free(l);
        if (self.cookie) |c| gpa.free(c);
        if (self.proxy_owned) |p| gpa.free(p);
        gpa.destroy(self);
    }
};

pub const SpawnOptions = struct {
    label: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    stream: StreamMode = .never,
    /// The transport defaults; null takes the config's (`transportDefaults`).
    transport: ?client.Transport = null,
};

/// The config's transport defaults — what a send gets when its block
/// says nothing (`.http.insecure` / `timeout_ms` / `follow_redirects` /
/// `max_redirects` / `proxy` in `docs/CONFIG.md`).
pub fn transportDefaults(app: *App) client.Transport {
    const c = app.cfg.http;
    return .{
        .insecure = c.insecure,
        .timeout_ms = if (c.timeout_ms) |ms| @as(u64, ms) else null,
        .follow_redirects = c.follow_redirects,
        .max_redirects = c.max_redirects,
        .proxy = if (c.proxy) |p| (if (std.mem.trim(u8, p, " \t").len > 0) p else null) else null,
    };
}

/// Start a worker for `req` (ownership moves). Returns the job id.
pub fn spawn(app: *App, pane: ?PaneId, kind: client.JobKind, req: Request, label: ?[]const u8, cookie: ?[]const u8) CommandError!u64 {
    return spawnWith(app, pane, kind, req, .{ .label = label, .cookie = cookie });
}

pub fn spawnWith(app: *App, pane: ?PaneId, kind: client.JobKind, req: Request, opts: SpawnOptions) CommandError!u64 {
    const gpa = app.gpa;
    var incoming = req;
    errdefer incoming.deinit(gpa);
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{ .id = app.http.nextJob(), .pane = pane, .kind = kind, .req = incoming, .stream = opts.stream, .events = app.events, .io = app.io, .gpa = gpa };
    incoming = undefined;
    if (opts.label) |l| job.label = try gpa.dupe(u8, l);
    errdefer if (job.label) |l| gpa.free(l);
    if (opts.cookie) |c| job.cookie = try gpa.dupe(u8, c);
    errdefer if (job.cookie) |c| gpa.free(c);
    // The request's directives over the defaults, resolved here so the
    // worker never reads the config; the proxy string is the job's.
    job.transport = client.Transport.fromRequest(&job.req, opts.transport orelse transportDefaults(app));
    if (job.transport.proxy) |p| {
        job.proxy_owned = try gpa.dupe(u8, p);
        job.transport.proxy = job.proxy_owned;
    }
    errdefer if (job.proxy_owned) |p| gpa.free(p);
    const id = job.id;
    // One send is one job; a bench's ten and a fan-out's are the bench's
    // and the fan-out's own business (`cmd_http.zig`).
    const label: ?[]const u8 = if (kind == .send) try std.fmt.allocPrint(app.frame.allocator(), "{s} {s}", .{ job.req.method, job.req.url }) else null;
    if (opts.stream == .never) {
        app.http.group.concurrent(app.io, worker, .{job}) catch |err| {
            return app.diag.fail(app.frame.allocator(), "http: could not start the send: {s}", .{@errorName(err)});
        };
        if (label) |l| _ = try jobs.begin(app, .{ .kind = .http, .key = id, .label = l, .pane = pane });
        return id;
    }
    const own = try gpa.create(JobHandle);
    errdefer gpa.destroy(own);
    own.* = .{ .pane = pane };
    try app.http.handles.put(gpa, id, own);
    errdefer _ = app.http.handles.swapRemove(id);
    own.group.concurrent(app.io, worker, .{job}) catch |err| {
        return app.diag.fail(app.frame.allocator(), "http: could not start the send: {s}", .{@errorName(err)});
    };
    if (label) |l| _ = try jobs.begin(app, .{ .kind = .http, .key = id, .label = l, .pane = pane, .cancel = &cancelSend });
    return id;
}

/// The JOBS list's Cancel on a send with a handle of its own (`http.cancel`'s
/// path, by job id rather than by the active pane).
fn cancelSend(app: *App, job: u64) void {
    const own = app.http.handles.get(job) orelse {
        app.toast("http: this send cannot be interrupted on its own — :http.abort stops every worker", .{});
        return;
    };
    own.group.cancel(app.io);
    _ = app.http.handles.swapRemove(job);
    app.gpa.destroy(own);
    app.http.sending -|= 1;
    // As `http.cancel`: a stream keeps what arrived, sealed as truncated.
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asRequest()) |rp| if (rp.state.job() == job) {
        if (rp.streaming()) |st| {
            const elapsed: u64 = @intCast(@max(app.now_ms - st.started_ms, 0));
            rp.finishStream(.{ .total_ms = elapsed, .receive_ms = elapsed }, true) catch {};
        } else rp.setFailed("canceled") catch {};
    };
    jobs.endKeyed(app, .http, job, jobs.Outcome.cancel(null));
    app.needs_render = true;
}

/// Drop the per-job group once its worker has posted its last event.
/// `cancel` on a finished group only releases its resources.
fn releaseHandle(app: *App, job: u64) void {
    const h = app.http.handles.get(job) orelse return;
    _ = app.http.handles.swapRemove(job);
    h.group.cancel(app.io);
    app.gpa.destroy(h);
}

/// D1: the job is the worker's until it has posted; the result is the
/// event's from there. Workers never toast (D2).
fn worker(job: *Job) Io.Cancelable!void {
    const gpa = job.gpa;
    const io = job.io;
    const events = job.events;
    defer job.destroy(gpa);
    const started = App.nowMs(io);
    const sink: ?client.Stream = if (job.stream == .never) null else .{ .ctx = job, .onHead = onStreamHead, .onBytes = onStreamBytes, .onDone = onStreamDone };
    var outcome = client.send(gpa, io, &job.req, .{ .cookie = job.cookie, .stream = sink, .transport = job.transport }) catch {
        postErr(events, io, gpa, "out of memory during the send");
        return;
    };
    if (job.streamed) {
        // The head went out as `.sse`; the end went out from `onDone`,
        // so only a failure after the head is left to report.
        switch (outcome) {
            .moved => {},
            .err => |e| {
                const chunk = client.StreamChunk.create(gpa, job.id, job.pane, .{ .err = e }) catch {
                    gpa.free(e);
                    postErr(events, io, gpa, "out of memory finishing the stream");
                    return;
                };
                events.post(io, .{ .sse = chunk });
            },
            .ok => outcome.deinit(gpa),
        }
        return;
    }
    const r = JobResult.create(gpa, job.id, job.pane, job.kind, job.req.method, job.req.url, outcome) catch {
        outcome.deinit(gpa);
        postErr(events, io, gpa, "out of memory finishing the send");
        return;
    };
    r.elapsed_ms = @intCast(@max(App.nowMs(io) - started, 0));
    if (job.label) |l| {
        r.label = l;
        job.label = null;
    }
    events.post(io, .{ .http = r });
}

/// The sink's head: decide, copy the head onto the gpa, post it.
fn onStreamHead(ctx: *anyopaque, head: client.HeadInfo) bool {
    const job: *Job = @ptrCast(@alignCast(ctx));
    const want = switch (job.stream) {
        .never => false,
        .always => true,
        .auto => head.is_sse or head.chunked,
    };
    if (!want) return false;
    const gpa = job.gpa;
    const status_text = gpa.dupe(u8, head.status_text) catch return false;
    errdefer gpa.free(status_text);
    const headers = gpa.alloc(client.Header, head.headers.len) catch return false;
    var filled: usize = 0;
    errdefer {
        for (headers[0..filled]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(headers);
    }
    for (head.headers) |h| {
        headers[filled].name = gpa.dupe(u8, h.name) catch return false;
        errdefer gpa.free(headers[filled].name);
        headers[filled].value = gpa.dupe(u8, h.value) catch return false;
        filled += 1;
    }
    const hop_cookies = client.cloneHopCookies(gpa, head.hop_cookies) catch return false;
    errdefer client.freeHopCookies(gpa, hop_cookies);
    const chunk = client.StreamChunk.create(gpa, job.id, job.pane, .{ .head = .{ .status = head.status, .status_text = status_text, .headers = headers, .is_sse = head.is_sse, .chunked = head.chunked, .hop_cookies = hop_cookies } }) catch return false;
    job.streamed = true;
    job.events.post(job.io, .{ .sse = chunk });
    return true;
}

fn onStreamDone(ctx: *anyopaque, end: client.StreamEnd) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    const chunk = client.StreamChunk.create(job.gpa, job.id, job.pane, .{ .done = .{ .timing = end.timing, .bytes = end.bytes, .truncated = end.truncated } }) catch return;
    job.events.post(job.io, .{ .sse = chunk });
}

fn onStreamBytes(ctx: *anyopaque, bytes: []const u8) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    const gpa = job.gpa;
    const copy = gpa.dupe(u8, bytes) catch return;
    const chunk = client.StreamChunk.create(gpa, job.id, job.pane, .{ .bytes = copy }) catch {
        gpa.free(copy);
        return;
    };
    job.events.post(job.io, .{ .sse = chunk });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .http, .msg = owned } });
}

/// Fire the pane's request: commit the fields, expand `{{VAR}}`, add
/// the jar's cookies, hand the worker a copy.
pub fn fire(app: *App, id: PaneId) CommandError!void {
    const rp = app.panes.get(id).?.asRequest() orelse return error.NotAnEditor;
    try rp.commit();
    if (std.mem.trim(u8, rp.request.url, " \t").len == 0) return app.diag.fail(app.frame.allocator(), "http: the request has no URL", .{});
    if (rp.state == .sending) return app.diag.fail(app.frame.allocator(), "http: a send is already in flight", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var set = try loadEnvFor(app, a, rp);
    set.process = &app.env;
    if (rp.sent_env) |old| app.gpa.free(old);
    rp.sent_env = if (set.name) |n| try app.gpa.dupe(u8, n) else null;
    // Pre-request directives land on a copy: the editable fields stay
    // as written, the wire sees the `@set-*` values.
    var staged = try rp.request.clone(a);
    const script = try script_mod.parse(a, rp.request.script orelse "");
    try script_mod.applyPre(a, &staged, &set, script);
    // A `{{VAR}}` nothing defines never reaches the wire: the literal
    // braces would go out as written (`GET {{jira}}/…` fails in the URL
    // parser as `InvalidFormat`, a header leaks the template). The pane
    // says which names and where to define them, and does not send.
    const missing = try unresolvedIn(a, &staged, &set);
    if (missing.len > 0) {
        const msg = try env_mod.unresolvedMessage(a, missing, set.name);
        try rp.setRefused(msg);
        app.toast("http: {s}", .{msg});
        app.needs_render = true;
        return;
    }
    var expanded = try expandWith(app.gpa, app.io, &staged, &set);
    var handed = false;
    errdefer if (!handed) expanded.deinit(app.gpa);
    // The Body tab's mode makes the wire body (JSON formatted, the
    // rows encoded, the file parts read) after the expansion, so a
    // `{{VAR}}` in a row resolves first; then the `http_request` hook
    // (its rewrite lands on `expanded`; `cmd_http.zig` documents the
    // order).
    try applyBodyType(app, rp, &expanded);
    try @import("cmd_http.zig").beforeSend(app, id, rp, &expanded, set.name);
    try rp.setSentLine(expanded.method, expanded.url);
    const cookie = try @import("cmd_http.zig").cookieHeaderFor(app, a, expanded.url);
    const mode: StreamMode = if (app.http.force_stream) .always else .auto;
    app.http.force_stream = false;
    handed = true;
    const job = try spawnWith(app, id, .send, expanded, .{ .cookie = cookie, .stream = mode });
    rp.keepAsPrev();
    rp.state = .{ .sending = job };
    rp.moved_since_send = false;
    app.http.sending += 1;
    app.needs_render = true;
}

/// D1: a `.sse` chunk is ours to adopt or destroy. The head opens the
/// stream on its pane, bytes append, `done` seals it into the Done
/// response and runs everything a finished send runs.
pub fn handleStream(app: *App, c: *client.StreamChunk) Allocator.Error!void {
    defer c.destroy(app.gpa);
    app.needs_render = true;
    // The job ends with the stream, whether or not a pane still waits.
    switch (c.kind) {
        .done => jobs.endKeyed(app, .http, c.job, jobs.Outcome.done("streamed")),
        .err => |msg| jobs.endKeyed(app, .http, c.job, jobs.Outcome.fail(msg)),
        .head, .bytes => {},
    }
    const id = c.pane orelse return;
    const rp = (app.panes.get(id) orelse return).asRequest() orelse return;
    const cmd_http = @import("cmd_http.zig");
    switch (c.kind) {
        .head => |*h| {
            if (rp.state != .sending or rp.state.sending != c.job) return;
            var head: Response = .{ .status = h.status, .status_text = h.status_text, .final_url = try app.gpa.dupe(u8, rp.request.url), .headers = h.headers, .body = &.{}, .hop_cookies = h.hop_cookies };
            // Adopted: the box must not free them.
            c.kind = .{ .done = .{ .timing = .{}, .bytes = 0, .truncated = false } };
            errdefer head.deinit(app.gpa);
            rp.beginStream(c.job, head, h.is_sse, h.chunked, app.now_ms);
        },
        .bytes => |b| {
            if (rp.state.job() != c.job or rp.state != .streaming) return;
            try rp.appendStream(b);
        },
        .done => |d| {
            if (rp.state.job() != c.job or rp.state != .streaming) return;
            app.http.sending -|= 1;
            releaseHandle(app, c.job);
            const st = rp.streaming().?;
            // The URL as sent (expanded), as the whole-body path records it.
            const sent_url: []const u8 = if (rp.sent_line) |l| (if (std.mem.indexOfScalar(u8, l, ' ')) |sp| l[sp + 1 ..] else l) else rp.request.url;
            const facts: cmd_http.HistoryFacts = .{ .method = rp.request.method, .url = try app.frame.allocator().dupe(u8, sent_url), .status = st.head.status, .elapsed_ms = d.timing.total_ms };
            try rp.finishStream(d.timing, d.truncated);
            try cmd_http.afterResponse(app, id, rp);
            cmd_http.recordHistory(app, facts, rp) catch {};
        },
        .err => |msg| {
            if (rp.state.job() != c.job) return;
            app.http.sending -|= 1;
            releaseHandle(app, c.job);
            try rp.setFailed(msg);
        },
    }
}

/// `http.cancel`: interrupt the active pane's send, streaming or not.
fn cancelCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const job = rp.state.job() orelse return app.diag.fail(app.frame.allocator(), "http.cancel: nothing in flight on this pane", .{});
    const own = app.http.handles.get(job) orelse return app.diag.fail(app.frame.allocator(), "http.cancel: this send cannot be interrupted on its own — :http.abort stops every worker", .{});
    own.group.cancel(app.io);
    _ = app.http.handles.swapRemove(job);
    app.gpa.destroy(own);
    jobs.endKeyed(app, .http, job, jobs.Outcome.cancel(null));
    app.http.sending -|= 1;
    // A stream stopped by hand keeps what arrived: it seals into the
    // response, marked truncated, as the server closing it would.
    if (rp.streaming()) |st| {
        const got = st.body.items.len;
        const elapsed: u64 = @intCast(@max(app.now_ms - st.started_ms, 0));
        try rp.finishStream(.{ .total_ms = elapsed, .receive_ms = elapsed }, true);
        app.toast("http.cancel: stopped after {d} bytes \u{00B7} what arrived is kept", .{got});
        return;
    }
    try rp.setFailed("canceled");
    app.toast("http.cancel: stopped", .{});
}

/// D1: the result is ours to adopt or destroy. A job no pane is waiting
/// on any more (the pane re-fired, or closed) is dropped whole.
pub fn handle(app: *App, r: *JobResult) Allocator.Error!void {
    defer r.destroy(app.gpa);
    app.needs_render = true;
    switch (r.kind) {
        .send => {
            releaseHandle(app, r.job);
            // The job ends here whatever the pane does with the answer.
            switch (r.outcome) {
                .ok => |resp| jobs.endKeyed(app, .http, r.job, jobs.Outcome.done(try std.fmt.allocPrint(app.frame.allocator(), "{d} · {d}ms", .{ resp.status, r.elapsed_ms }))),
                .err => |msg| jobs.endKeyed(app, .http, r.job, jobs.Outcome.fail(msg)),
                .moved => jobs.endKeyed(app, .http, r.job, .{}),
            }
            const id = r.pane orelse return;
            const rp = (app.panes.get(id) orelse return).asRequest() orelse return;
            if (rp.state != .sending or rp.state.sending != r.job) return;
            app.http.sending -|= 1;
            const cmd_http = @import("cmd_http.zig");
            switch (r.outcome) {
                .ok => {
                    const resp = r.outcome.take().?;
                    try rp.setResponse(resp);
                    try cmd_http.afterResponse(app, id, rp);
                },
                .err => |msg| try rp.setFailed(msg),
                .moved => {},
            }
            cmd_http.recordHistory(app, .{ .method = r.method, .url = r.url, .status = r.status(), .elapsed_ms = r.elapsed_ms }, rp) catch {};
        },
        .fan_env => try @import("cmd_http.zig").onFanResult(app, r),
        .bench, .lookup, .chain => try @import("cmd_http.zig").onJobResult(app, r),
    }
}

/// The `.err` event's cleanup: a send that never produced a result.
pub fn onWorkerError(app: *App) void {
    _ = app;
}

// ─── save ───────────────────────────────────────────────────────────────

/// Write the active pane back into its source: a multi-block `.http` /
/// `.rest` gets just its block spliced; anything else is overwritten
/// with the request as a curl one-liner. A scratch pane prompts for a
/// path.
pub fn saveToSource(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const rp = try requireRequest(app);
    try rp.commit();
    const path = rp.source_path orelse {
        try @import("cmd_http.zig").openSaveAsPrompt(app);
        return;
    };
    const rel = app.relPath(path);
    const ext = std.fs.path.extension(path);
    const is_http = std.ascii.eqlIgnoreCase(ext, ".http") or std.ascii.eqlIgnoreCase(ext, ".rest");
    const existing = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(16 << 20)) catch null;
    if (existing) |text| {
        const block_text = if (is_http) try parse.toHttpBlock(arena, &rp.request, rp.block_name) else blk: {
            const curl = try parse.toCurl(arena, &rp.request);
            break :blk if (rp.block_name) |n| try std.fmt.allocPrint(arena, "### {s}\n{s}\n", .{ n, curl }) else try std.fmt.allocPrint(arena, "{s}\n", .{curl});
        };
        const spliced = parse.splice(gpa, text, rp.block_index, rp.block_name, block_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Writing the whole file here would drop every other block.
            error.NoSuchBlock => return app.diag.fail(arena, "save: the pane's block is not in {s} any more (Save As writes it elsewhere)", .{rel}),
        };
        if (spliced) |fresh| {
            defer gpa.free(fresh);
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = fresh }) catch |err| return app.diag.fail(arena, "save failed: {s}: {s}", .{ rel, @errorName(err) });
            rp.edited = false;
            app.toast("saved block → {s}", .{rel});
            return;
        }
    }
    const whole = if (is_http) try parse.toHttpBlock(arena, &rp.request, null) else try std.fmt.allocPrint(arena, "{s}\n", .{try parse.toCurl(arena, &rp.request)});
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = whole }) catch |err| return app.diag.fail(arena, "save failed: {s}: {s}", .{ rel, @errorName(err) });
    rp.edited = false;
    app.toast("saved request → {s}", .{rel});
}

// ─── field helpers ──────────────────────────────────────────────────────

/// Parse the Script tab's text into the structured fields.
pub fn pasteSourceInto(app: *App, id: PaneId, rp: *RequestPane) CommandError!void {
    _ = id;
    const text = std.mem.trim(u8, rp.source.items, " \t\r\n");
    if (text.len == 0) return app.diag.fail(app.frame.allocator(), "paste_source: the Script tab is empty", .{});
    const req = parse.parse(app.gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "paste_source: {s}", .{@errorName(err)}),
    };
    try rp.load(req);
    rp.source.clearRetainingCapacity();
    rp.source_caret = 0;
    rp.edited = true;
    rp.showTab(.body);
    if (app.http.auto_format_body) formatBody(app, rp) catch {};
    app.toast("source: parsed → {s} {s}", .{ rp.request.method, rp.request.url });
}

/// Load `text` (curl / .http) into the pane, replacing what it holds.
pub fn loadText(app: *App, rp: *RequestPane, text: []const u8) CommandError!void {
    const req = parse.parse(app.gpa, std.mem.trim(u8, text, " \t\r\n")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Empty => return app.diag.fail(app.frame.allocator(), "paste: nothing to parse", .{}),
        error.NoUrl => return app.diag.fail(app.frame.allocator(), "paste: no URL found in request", .{}),
        error.UnterminatedQuote => return app.diag.fail(app.frame.allocator(), "paste: unterminated quote in curl command", .{}),
    };
    try rp.load(req);
    if (rp.prev) |*p| p.deinit(app.gpa);
    rp.prev = null;
    rp.edited = true;
    rp.block = .request;
    rp.field = .url;
    if (app.http.auto_format_body) formatBody(app, rp) catch {};
}

/// Enter on an Auth row.
pub fn authRowAction(app: *App, id: PaneId, rp: *RequestPane, row: usize) Allocator.Error!void {
    _ = id;
    const cmd_http = @import("cmd_http.zig");
    switch (row) {
        0 => try cmd_http.openAuthPrompt(app, .bearer),
        1 => try cmd_http.openAuthPrompt(app, .basic),
        2 => try cmd_http.openAuthPrompt(app, .api_key),
        3 => {
            try rp.commit();
            _ = rp.request.removeHeader(app.gpa, "authorization");
            _ = rp.request.removeHeader(app.gpa, "x-api-key");
            try rp.syncHeadersText();
            rp.edited = true;
            app.toast("auth: cleared Authorization", .{});
        },
        else => if (row >= view.auth_rows.len and row < view.authRowCount()) switch (view.option_rows[row - view.auth_rows.len].kind) {
            // Enter on a toggle flips it; on a value row it prompts.
            .verify_tls, .follow_redirects => try authRowAdjust(app, rp, row, 1),
            .timeout => try openOptionPrompt(app, rp, .timeout),
            .max_redirects => try openOptionPrompt(app, rp, .max_redirects),
            .proxy => try openOptionPrompt(app, rp, .proxy),
        },
    }
}

// ─── the Options rows ───────────────────────────────────────────────────
//
// The Auth tab's `── Options ──` rows edit the block's own directive
// lines (`# @insecure`, `# @timeout`, `# @no-redirect`, `# @max-redirects`,
// `# @proxy`); a row the block does not set shows the config's default
// and no `*`. `←` `→` / `h` `l` flip a toggle or step the cap and the
// timeout; Enter prompts for a value; `r` puts the row back on the
// config default (removes the line).

pub const OptionKind = enum { timeout, max_redirects, proxy };

/// The rows' model: what the send would use, and which rows the block
/// sets itself.
pub fn optionsModel(app: *App, rp: *RequestPane) view.OptionsModel {
    const o = parse.options(&rp.request);
    const t = client.Transport.fromRequest(&rp.request, transportDefaults(app));
    return .{
        .insecure = t.insecure,
        .timeout_ms = t.timeout_ms,
        .follow_redirects = t.follow_redirects,
        .max_redirects = t.max_redirects,
        .proxy = t.proxy,
        .set = .{ o.insecure, o.timeout_ms != null, o.follow_redirects != null, o.max_redirects != null, o.proxy != null },
    };
}

/// `←` / `→` on an Options row.
pub fn authRowAdjust(app: *App, rp: *RequestPane, row: usize, delta: i32) Allocator.Error!void {
    if (row < view.auth_rows.len or row >= view.authRowCount()) return;
    const gpa = app.gpa;
    const before = optionsModel(app, rp);
    switch (view.option_rows[row - view.auth_rows.len].kind) {
        .verify_tls => {
            // Verify on means no `@insecure` line — unless the config
            // skips verification, where the line cannot say "verify".
            const want_insecure = !before.insecure;
            if (!want_insecure and app.cfg.http.insecure) {
                app.toast("options: .http.insecure = true in the config — verification is off for every send", .{});
                return;
            }
            try parse.setDirective(&rp.request, gpa, "@insecure", if (want_insecure) "" else null);
            app.toast("options: verify TLS {s} for this request", .{if (want_insecure) "off" else "on"});
        },
        .follow_redirects => {
            const want = !before.follow_redirects;
            // The line that differs from the config; none when it agrees.
            const cfg = app.cfg.http.follow_redirects;
            try parse.setDirective(&rp.request, gpa, "@no-redirect", if (!want and cfg) "" else null);
            try parse.setDirective(&rp.request, gpa, "@follow-redirects", if (want and !cfg) "" else null);
            app.toast("options: follow redirects {s}", .{if (want) "on" else "off"});
        },
        .max_redirects => {
            const cur: i32 = before.max_redirects;
            const next: u8 = @intCast(std.math.clamp(cur + delta, 0, 50));
            var buf: [8]u8 = undefined;
            try parse.setDirective(&rp.request, gpa, "@max-redirects", std.fmt.bufPrint(&buf, "{d}", .{next}) catch "");
            app.toast("options: max redirects {d}", .{next});
        },
        .timeout => {
            // A second per step; below one second the line goes.
            const cur: i64 = @intCast(before.timeout_ms orelse 0);
            const next: i64 = cur + @as(i64, delta) * 1000;
            if (next <= 0) {
                try parse.setDirective(&rp.request, gpa, "@timeout", null);
                app.toast("options: timeout {s}", .{if (transportDefaults(app).timeout_ms) |_| "back to the config default" else "off"});
            } else {
                var buf: [32]u8 = undefined;
                try parse.setDirective(&rp.request, gpa, "@timeout", parse.formatDuration(&buf, @intCast(next)));
                app.toast("options: timeout {s}", .{parse.formatDuration(&buf, @intCast(next))});
            }
        },
        .proxy => try openOptionPrompt(app, rp, .proxy),
    }
    rp.edited = true;
    app.needs_render = true;
}

/// `r` on an Options row: the block's line goes, the config decides.
pub fn authRowReset(app: *App, rp: *RequestPane, row: usize) Allocator.Error!void {
    if (row < view.auth_rows.len or row >= view.authRowCount()) return;
    const gpa = app.gpa;
    const r = view.option_rows[row - view.auth_rows.len];
    switch (r.kind) {
        .verify_tls => try parse.setDirective(&rp.request, gpa, "@insecure", null),
        .timeout => try parse.setDirective(&rp.request, gpa, "@timeout", null),
        .follow_redirects => {
            try parse.setDirective(&rp.request, gpa, "@no-redirect", null);
            try parse.setDirective(&rp.request, gpa, "@follow-redirects", null);
        },
        .max_redirects => try parse.setDirective(&rp.request, gpa, "@max-redirects", null),
        .proxy => try parse.setDirective(&rp.request, gpa, "@proxy", null),
    }
    rp.edited = true;
    app.toast("options: {s} follows the config", .{r.label});
    app.needs_render = true;
}

/// The value prompt of a row, seeded with what the block says.
pub fn openOptionPrompt(app: *App, rp: *RequestPane, kind: OptionKind) Allocator.Error!void {
    const gpa = app.gpa;
    const o = parse.options(&rp.request);
    var buf: [64]u8 = undefined;
    const title: []const u8, const current: []const u8 = switch (kind) {
        .timeout => .{ "Timeout (5s, 500ms, 2m \u{00b7} empty = config default):", if (o.timeout_ms) |ms| parse.formatDuration(&buf, ms) else "" },
        .max_redirects => .{ "Max redirects (0\u{2013}50 \u{00b7} empty = config default):", if (o.max_redirects) |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch "" else "" },
        .proxy => .{ "Proxy (host:port, user:pass@host:port \u{00b7} empty = config default):", o.proxy orelse "" },
    };
    var state = Prompt.init(gpa, title);
    errdefer Prompt.deinit(&state, gpa);
    try state.setText(gpa, current);
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .http_option = kind } } };
    app.focus = .overlay;
    app.needs_render = true;
}

// ─── the body type ──────────────────────────────────────────────────────

/// `req`'s body as the block's `# @body-type` says (item 11): JSON is
/// pretty-printed when `http.auto_format_body` and typed
/// `application/json`; `form-urlencoded` encodes the `name = value`
/// rows; `multipart` encodes them with a fresh boundary, a `@path` row
/// read relative to the source file's directory (the workspace for a
/// scratch). A `Content-Type` the request already carries is kept.
pub fn applyBodyType(app: *App, rp: *RequestPane, req: *Request) CommandError!void {
    const base = if (rp.source_path) |p| (std.fs.path.dirname(p) orelse app.workspace) else app.workspace;
    var missing: ?[]const u8 = null;
    defer if (missing) |m| app.gpa.free(m);
    body_mod.encode(app.gpa, app.io, req, .{ .format_json = app.http.auto_format_body, .base_dir = base }, &missing) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return app.diag.fail(app.frame.allocator(), "multipart: no file at {s} (relative to {s})", .{ missing orelse "?", app.relPath(base) }),
    };
}

/// The chip's pick: the block's line follows, and a toast names it.
pub fn setBodyType(app: *App, rp: *RequestPane, t: parse.BodyType) Allocator.Error!void {
    try parse.setBodyType(&rp.request, app.gpa, t);
    rp.edited = true;
    app.toast("body: {s}", .{t.label()});
    app.needs_render = true;
}

/// right-click on the chip: the four modes, the current one checked.
pub fn openBodyTypeMenu(app: *App, rp: *RequestPane, x: u16, y: u16) Allocator.Error!void {
    const cur = parse.bodyType(&rp.request);
    const M = command.MenuItem;
    const items = try app.gpa.dupe(M, &.{
        .{ .label = "raw \u{2014} as typed", .action = .{ .command = .@"http.body_type_raw" }, .checked = cur == .raw },
        .{ .label = "JSON \u{2014} formatted on send, application/json", .action = .{ .command = .@"http.body_type_json" }, .checked = cur == .json },
        .{ .label = "form \u{2014} name = value rows, x-www-form-urlencoded", .action = .{ .command = .@"http.body_type_form" }, .checked = cur == .form },
        .{ .label = "multipart \u{2014} rows and name = @file parts, multipart/form-data", .action = .{ .command = .@"http.body_type_multipart" }, .checked = cur == .multipart },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Body type", items, x, y);
}

/// The Response strip's ` TYPE ▼ ` chip: the format follows the
/// content-type (the menu's title says so); the rows are what can be
/// done with the body.
pub fn openResponseBodyMenu(app: *App, rp: *RequestPane, x: u16, y: u16) Allocator.Error!void {
    if (rp.response() == null) {
        app.toast("no response yet", .{});
        return;
    }
    const M = command.MenuItem;
    const items = try app.gpa.dupe(M, &.{
        .{ .label = "Copy body", .action = .{ .command = .@"http.copy_response_body" } },
        .{ .label = "Save body to a file\u{2026}", .action = .{ .command = .@"http.save_response" } },
        .{ .label = "Save as mock", .action = .{ .command = .@"http.save_mock" } },
        .{ .label = "Wrap long lines", .action = .{ .command = .@"http.toggle_response_wrap" }, .checked = rp.body_wrap, .separator_before = true },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Body \u{00B7} format follows the content-type", items, x, y);
}

fn cycleBodyTypeCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try setBodyType(app, rp, parse.bodyType(&rp.request).next());
}

fn bodyTypeRawCmd(app: *App) CommandError!void {
    try setBodyType(app, try requireRequest(app), .raw);
}

fn bodyTypeJsonCmd(app: *App) CommandError!void {
    try setBodyType(app, try requireRequest(app), .json);
}

fn bodyTypeFormCmd(app: *App) CommandError!void {
    try setBodyType(app, try requireRequest(app), .form);
}

fn bodyTypeMultipartCmd(app: *App) CommandError!void {
    try setBodyType(app, try requireRequest(app), .multipart);
}

// ─── description + tags (item 15) ───────────────────────────────────────

fn openMetaPrompt(app: *App, rp: *RequestPane, purpose: app_mod.PromptPurpose, title: []const u8, current: []const u8) Allocator.Error!void {
    _ = rp;
    const gpa = app.gpa;
    var state = Prompt.init(gpa, title);
    errdefer Prompt.deinit(&state, gpa);
    try state.setText(gpa, current);
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `http.set_description`: the `# @description` line, seeded; empty removes it.
fn setDescriptionCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try openMetaPrompt(app, rp, .http_description, "Description (# @description \u{2026} \u{00b7} empty clears):", parse.description(&rp.request) orelse "");
}

/// `http.set_tags`: the `# @tags` line, seeded with the words; empty removes it.
fn setTagsCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const words = try parse.tags(arena.allocator(), &rp.request);
    try openMetaPrompt(app, rp, .http_tags, "Tags, space-separated (# @tags a b \u{00b7} empty clears):", try std.mem.join(arena.allocator(), " ", words));
}

pub fn applyDescriptionPrompt(app: *App, text: []const u8) Allocator.Error!void {
    const rp = activeRequest(app) orelse return;
    try parse.setDescription(&rp.request, app.gpa, text);
    rp.edited = true;
    app.toast("description: {s}", .{if (parse.description(&rp.request)) |d| d else "cleared"});
    app.needs_render = true;
}

pub fn applyTagsPrompt(app: *App, text: []const u8) Allocator.Error!void {
    const rp = activeRequest(app) orelse return;
    try parse.setTags(&rp.request, app.gpa, text);
    rp.edited = true;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const words = try parse.tags(arena.allocator(), &rp.request);
    if (words.len == 0) app.toast("tags: cleared", .{}) else app.toast("tags: {s}", .{try @import("http_ops.zig").tagsText(arena.allocator(), words)});
    app.needs_render = true;
}

// ─── path params ────────────────────────────────────────────────────────

/// The value prompt for the `:name` segment, seeded with the block's
/// `# @path name=value` (item 10).
pub fn openPathParamPrompt(app: *App, rp: *RequestPane, name: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    const title = try std.fmt.allocPrint(gpa, "Value for :{s} (# @path {s}=\u{2026} \u{00b7} empty clears):", .{ name, name });
    errdefer gpa.free(title);
    var state = Prompt.init(gpa, title);
    errdefer Prompt.deinit(&state, gpa);
    try state.seed(gpa, parse.pathParamValue(&rp.request, name) orelse "");
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .http_path_param = owned }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's answer: the line is set, or removed by an empty text.
pub fn applyPathParamPrompt(app: *App, name: []const u8, text: []const u8) Allocator.Error!void {
    const rp = activeRequest(app) orelse {
        app.toast("path: no active Request pane", .{});
        return;
    };
    const value = std.mem.trim(u8, text, " \t");
    try parse.setPathParam(&rp.request, app.gpa, name, if (value.len == 0) null else value);
    rp.edited = true;
    if (value.len == 0) app.toast("path: :{s} cleared", .{name}) else app.toast("path: :{s} = {s}", .{ name, value });
    app.needs_render = true;
}

/// `http.set_path_param`: the prompt for the Params tab's path row, or
/// the URL's first `:name`.
fn setPathParamCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const names = try parse.pathParamNames(arena.allocator(), rp.url.items);
    if (names.len == 0) return app.diag.fail(app.frame.allocator(), "path: the URL has no :name segments", .{});
    const at = if (rp.edit_tab == .params and rp.row_cursor < names.len) rp.row_cursor else 0;
    try openPathParamPrompt(app, rp, names[at]);
}

/// The prompt's answer: an empty text removes the line.
pub fn applyOptionPrompt(app: *App, kind: OptionKind, text: []const u8) Allocator.Error!void {
    const rp = activeRequest(app) orelse {
        app.toast("options: no active Request pane", .{});
        return;
    };
    const gpa = app.gpa;
    const value = std.mem.trim(u8, text, " \t\r\n");
    switch (kind) {
        .timeout => {
            if (value.len == 0) {
                try parse.setDirective(&rp.request, gpa, "@timeout", null);
            } else if (parse.parseDuration(value)) |ms| {
                var buf: [32]u8 = undefined;
                try parse.setDirective(&rp.request, gpa, "@timeout", parse.formatDuration(&buf, ms));
            } else {
                app.toast("options: \"{s}\" is not a duration (5s, 500ms, 2m)", .{value});
                return;
            }
        },
        .max_redirects => {
            if (value.len == 0) {
                try parse.setDirective(&rp.request, gpa, "@max-redirects", null);
            } else if (std.fmt.parseInt(u8, value, 10)) |n| {
                var buf: [8]u8 = undefined;
                try parse.setDirective(&rp.request, gpa, "@max-redirects", std.fmt.bufPrint(&buf, "{d}", .{@min(n, 50)}) catch "");
            } else |_| {
                app.toast("options: \"{s}\" is not a count (0\u{2013}50)", .{value});
                return;
            }
        },
        .proxy => {
            if (value.len == 0) {
                try parse.setDirective(&rp.request, gpa, "@proxy", null);
            } else {
                var scratch = std.heap.ArenaAllocator.init(gpa);
                defer scratch.deinit();
                _ = @import("../http/insecure.zig").parseProxy(scratch.allocator(), value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnsupportedProxy => {
                        app.toast("options: only http proxies (host:port) are supported", .{});
                        return;
                    },
                    error.InvalidProxy => {
                        app.toast("options: \"{s}\" is not host:port", .{value});
                        return;
                    },
                };
                try parse.setDirective(&rp.request, gpa, "@proxy", value);
            }
        },
    }
    rp.edited = true;
    app.toast("options: {s} {s}", .{ switch (kind) {
        .timeout => "timeout",
        .max_redirects => "max redirects",
        .proxy => "proxy",
    }, if (value.len == 0) "follows the config" else value });
    app.needs_render = true;
}

fn optionRowIndex(kind: view.OptionRow.Kind) usize {
    for (view.option_rows, 0..) |r, i| if (r.kind == kind) return view.auth_rows.len + i;
    unreachable;
}

fn toggleInsecureCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try authRowAdjust(app, rp, optionRowIndex(.verify_tls), 1);
}

fn setTimeoutCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try openOptionPrompt(app, rp, .timeout);
}

fn toggleFollowRedirectsCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try authRowAdjust(app, rp, optionRowIndex(.follow_redirects), 1);
}

fn setMaxRedirectsCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try openOptionPrompt(app, rp, .max_redirects);
}

fn setProxyCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try openOptionPrompt(app, rp, .proxy);
}

/// Pretty-print the body as JSON in place.
pub fn formatBody(app: *App, rp: *RequestPane) CommandError!void {
    const gpa = app.gpa;
    const body = std.mem.trim(u8, rp.body.items, " \t\r\n");
    if (body.len == 0) return app.diag.fail(app.frame.allocator(), "body: empty", .{});
    // Re-indented token by token: the numbers keep the digits typed.
    const pretty = (try @import("../http/json_pretty.zig").pretty(gpa, body)) orelse return app.diag.fail(app.frame.allocator(), "body: not JSON", .{});
    defer gpa.free(pretty);
    try rp.body.replaceRange(gpa, 0, rp.body.items.len, pretty);
    rp.body_caret = @min(rp.body_caret, rp.body.items.len);
    try rp.commit();
    rp.edited = true;
}

// ─── runners ────────────────────────────────────────────────────────────

fn sendCmd(app: *App) CommandError!void {
    if (activeRequest(app) != null) return fire(app, app.active.?);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const active = try parseActive(app, arena.allocator());
    var req = active.req;
    errdefer req.deinit(app.gpa);
    // A pane already on this block re-fires; otherwise a new one opens
    // beside the source.
    if (active.source_path) |p| if (findSource(app, p, active.block_index, active.block_name)) |id| {
        const rp = app.panes.get(id).?.asRequest().?;
        try rp.load(req);
        req = undefined;
        rp.edited = false;
        app.showPane(id);
        rp.block = .response;
        return fire(app, id);
    };
    const id = try openFromRequest(app, req, .{ .source_path = active.source_path, .block_name = active.block_name, .block_index = active.block_index, .summary = active.summary, .focus_response = true });
    req = undefined;
    if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        rp.edited = false;
    };
    return fire(app, id);
}

fn newCmd(app: *App) CommandError!void {
    _ = try openBlank(app);
}

fn cycleMethodCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try rp.cycleMethod();
    app.toast("method: {s}", .{rp.request.method});
}

fn setMethod(app: *App, m: []const u8) CommandError!void {
    const rp = try requireRequest(app);
    try rp.setMethod(m);
    app.toast("method: {s}", .{rp.request.method});
}
fn setGet(app: *App) CommandError!void {
    return setMethod(app, "GET");
}
fn setPost(app: *App) CommandError!void {
    return setMethod(app, "POST");
}
fn setPut(app: *App) CommandError!void {
    return setMethod(app, "PUT");
}
fn setPatch(app: *App) CommandError!void {
    return setMethod(app, "PATCH");
}
fn setDelete(app: *App) CommandError!void {
    return setMethod(app, "DELETE");
}
fn setHead(app: *App) CommandError!void {
    return setMethod(app, "HEAD");
}
fn setOptions(app: *App) CommandError!void {
    return setMethod(app, "OPTIONS");
}

fn toggleViewCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    if (rp.block == .response) rp.focusUrl() else rp.block = .response;
}

fn viewSourceCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const path = rp.source_path orelse return app.diag.fail(app.frame.allocator(), "view_source: this request has no source file (scratch pane)", .{});
    const copy = try app.frame.allocator().dupe(u8, path);
    _ = app.openEditor(copy) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "view_source: {s}", .{@errorName(err)}),
    };
}

/// Move the editor's cursor to the next / previous `###` block.
fn stepBlock(app: *App, forward: bool) CommandError!void {
    if (activeRequest(app)) |rp| {
        // From a pane: open its source and step from its block.
        const path = rp.source_path orelse return app.diag.fail(app.frame.allocator(), "next_block: scratch pane has no source", .{});
        const copy = try app.frame.allocator().dupe(u8, path);
        _ = app.openEditor(copy) catch return app.diag.fail(app.frame.allocator(), "next_block: cannot open {s}", .{app.relPath(path)});
    }
    const e = try app.requireEditor();
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const list = try parse.blocks(arena.allocator(), e.buf.editor.bytes());
    if (list.len < 2) return app.diag.fail(app.frame.allocator(), "{s}: the file has one block", .{if (forward) "next_block" else "prev_block"});
    const line = e.buf.editor.currentLine();
    var target: ?usize = null;
    if (forward) {
        for (list) |b| if (b.start_line > line) {
            target = b.start_line;
            break;
        };
        if (target == null) target = list[0].start_line;
    } else {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (list[i].start_line < line) {
                target = list[i].start_line;
                break;
            }
        }
        if (target == null) target = list[list.len - 1].start_line;
    }
    e.buf.editor.placeCursor(target.?, 0);
    app.needs_render = true;
}

fn nextBlockCmd(app: *App) CommandError!void {
    return stepBlock(app, true);
}

fn prevBlockCmd(app: *App) CommandError!void {
    return stepBlock(app, false);
}

fn copyCurlCmd(app: *App) CommandError!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var active = try parseActive(app, arena.allocator());
    defer active.req.deinit(app.gpa);
    const curl = try parse.toCurl(arena.allocator(), &active.req);
    try app.clipboard.copy(curl);
    app.toast("copied as curl ({d} bytes)", .{curl.len});
}

fn pasteCurlCmd(app: *App) CommandError!void {
    const text = app.clipboard.text();
    var rp = activeRequest(app);
    if (rp == null) {
        const id = try openBlank(app);
        rp = app.panes.get(id).?.asRequest();
    }
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        if (rp.?.source.items.len > 0) return pasteSourceInto(app, app.active.?, rp.?);
        return app.diag.fail(app.frame.allocator(), "paste_curl: clipboard is empty", .{});
    }
    try loadText(app, rp.?, text);
    app.toast("pasted curl → {s} {s}", .{ rp.?.request.method, rp.?.request.url });
}

fn pasteSourceCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    return pasteSourceInto(app, app.active.?, rp);
}

fn formatBodyCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try formatBody(app, rp);
    app.toast("body: formatted as JSON", .{});
}

fn paramsAddCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try rp.startDraft();
}

fn paramsClearCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try rp.commit();
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const n = (try rp.request.params(arena.allocator())).len;
    const bare = try rp.request.urlWithoutQuery(arena.allocator());
    try rp.url.replaceRange(app.gpa, 0, rp.url.items.len, bare);
    rp.url_caret = @min(rp.url_caret, rp.url.items.len);
    rp.url_anchor = null;
    try rp.commit();
    rp.edited = true;
    rp.row_cursor = 0;
    app.toast("params: cleared {d}", .{n});
}

fn replayMockCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const arena = app.frame.allocator();
    const source = rp.source_path orelse return app.diag.fail(arena, "replay_mock: this pane has no source file", .{});
    const path = try mock.sidecarPath(arena, source);
    return @import("cmd_http.zig").replayMockFrom(app, rp, path);
}

fn saveMockCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const arena = app.frame.allocator();
    const source = rp.source_path orelse return app.diag.fail(arena, "save_mock: this pane has no source file", .{});
    const resp = rp.response() orelse return app.diag.fail(arena, "save_mock: no Done response to freeze", .{});
    const path = try mock.sidecarPath(arena, source);
    mock.save(app.gpa, app.io, path, resp.status, resp.status_text, resp.headers, resp.body) catch |err| return app.diag.fail(arena, "save_mock: {s}", .{@errorName(err)});
    app.toast("mock: saved → {s}", .{app.relPath(path)});
}

fn diffLastTwoCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const cur = rp.response();
    if (cur == null or rp.prev == null) return app.diag.fail(app.frame.allocator(), "http.diff: need at least 2 successful sends to diff", .{});
    const prev = &rp.prev.?;
    const gpa = app.gpa;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("# HTTP diff — last two responses\n\nstatus: {d} {s} → {d} {s}\nelapsed: {d}ms → {d}ms\n\n## headers\n\n", .{ prev.status, prev.status_text, cur.?.status, cur.?.status_text, prev.timing.total_ms, cur.?.timing.total_ms }) catch return error.OutOfMemory;
    for (prev.headers) |h| {
        const still = cur.?.header(h.name);
        if (still != null and std.mem.eql(u8, still.?, h.value)) {
            w.print("  {s}: {s}\n", .{ h.name, h.value }) catch return error.OutOfMemory;
        } else w.print("- {s}: {s}\n", .{ h.name, h.value }) catch return error.OutOfMemory;
    }
    for (cur.?.headers) |h| {
        const was = prev.header(h.name);
        if (was == null or !std.mem.eql(u8, was.?, h.value)) w.print("+ {s}: {s}\n", .{ h.name, h.value }) catch return error.OutOfMemory;
    }
    w.print("\n## body\n\n", .{}) catch return error.OutOfMemory;
    var pl = std.mem.splitScalar(u8, prev.body, '\n');
    var cl = std.mem.splitScalar(u8, cur.?.body, '\n');
    while (true) {
        const a = pl.next();
        const b = cl.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) {
            w.print("  {s}\n", .{a.?}) catch return error.OutOfMemory;
            continue;
        }
        if (a) |x| w.print("- {s}\n", .{x}) catch return error.OutOfMemory;
        if (b) |y| w.print("+ {s}\n", .{y}) catch return error.OutOfMemory;
    }
    const id = try app.openScratch();
    const e = app.panes.editor(id).?;
    e.buf.editor.setText(aw.written()) catch return error.OutOfMemory;
    e.buf.markSaved() catch return error.OutOfMemory;
    e.syntax.dirty = true;
    app.toast("http.diff: {d} → {d}", .{ prev.status, cur.?.status });
}

fn saveCmd(app: *App) CommandError!void {
    return saveToSource(app);
}

fn copyResponseBodyCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    try app.clipboard.copy(resp.body);
    app.toast("copied response body ({d} bytes)", .{resp.body.len});
}

fn copyResponseHeadersCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const text = try parse.headersToText(app.frame.allocator(), resp.headers);
    try app.clipboard.copy(text);
    app.toast("copied {d} response header(s)", .{resp.headers.len});
}

fn copyResponseCookiesCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const set = try resp.setCookies(app.frame.allocator());
    const text = try std.mem.join(app.frame.allocator(), "\n", set);
    try app.clipboard.copy(text);
    app.toast("copied {d} Set-Cookie header(s)", .{set.len});
}

fn copyResponseTimelineCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const text = try std.fmt.allocPrint(app.frame.allocator(), "wait {d}ms · receive {d}ms · total {d}ms", .{ resp.timing.wait_ms, resp.timing.receive_ms, resp.timing.total_ms });
    try app.clipboard.copy(text);
    app.toast("copied timeline: {s}", .{text});
}

fn copyResponseTestsCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const text = try std.mem.join(app.frame.allocator(), "\n", rp.tests.items);
    try app.clipboard.copy(text);
    app.toast("copied {d} test line(s)", .{rp.tests.items.len});
}

fn toggleWrapCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    rp.body_wrap = !rp.body_wrap;
    app.toast("response wrap: {s}", .{if (rp.body_wrap) "on" else "off"});
}

fn toggleAutoFormatCmd(app: *App) CommandError!void {
    app.http.auto_format_body = !app.http.auto_format_body;
    app.toast("auto-format body: {s}", .{if (app.http.auto_format_body) "on" else "off"});
}

const FieldRef = struct { buf: *std.ArrayListUnmanaged(u8), caret: *usize, name: []const u8 };

fn focusedField(app: *App) CommandError!FieldRef {
    const rp = try requireRequest(app);
    return switch (rp.field) {
        .url => .{ .buf = &rp.url, .caret = &rp.url_caret, .name = "URL" },
        .method => app.diag.fail(app.frame.allocator(), "the Method chip has no text field", .{}),
        .content => switch (rp.edit_tab) {
            .body => .{ .buf = &rp.body, .caret = &rp.body_caret, .name = "Body" },
            .headers => .{ .buf = &rp.headers_text, .caret = &rp.headers_caret, .name = "Headers" },
            .source => .{ .buf = &rp.source, .caret = &rp.source_caret, .name = "Source" },
            else => app.diag.fail(app.frame.allocator(), "the {s} tab has no text field", .{rp.edit_tab.label()}),
        },
    };
}

fn fieldCopyCmd(app: *App) CommandError!void {
    const f = try focusedField(app);
    try app.clipboard.copy(f.buf.items);
    app.toast("copied {s} ({d} bytes)", .{ f.name, f.buf.items.len });
}

fn fieldCutCmd(app: *App) CommandError!void {
    const f = try focusedField(app);
    try app.clipboard.copy(f.buf.items);
    f.buf.clearRetainingCapacity();
    f.caret.* = 0;
    const rp = activeRequest(app).?;
    rp.edited = true;
    try rp.commit();
    app.toast("cut {s}", .{f.name});
}

fn fieldPasteCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try request_pane.paste(app, rp, app.clipboard.text());
}

fn fieldSelectAllCmd(app: *App) CommandError!void {
    const f = try focusedField(app);
    f.caret.* = f.buf.items.len;
    try app.clipboard.copy(f.buf.items);
    app.toast("copied {s}", .{f.name});
}

fn abortCmd(app: *App) CommandError!void {
    app.http.group.cancel(app.io);
    app.http.group = .init;
    for (app.http.handles.values()) |h| {
        h.group.cancel(app.io);
        app.gpa.destroy(h);
    }
    app.http.handles.clearRetainingCapacity();
    var n: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.isSending()) {
            try rp.setFailed("aborted");
            n += 1;
        },
        else => {},
    };
    app.http.sending = 0;
    if (app.http.bench) |*b| b.deinit(app.gpa);
    app.http.bench = null;
    app.http.chain_running = false;
    if (app.http.fan) |*f| f.deinit(app.gpa);
    app.http.fan = null;
    app.toast("http.abort: cancelled {d} in-flight send(s)", .{n});
}

fn regenerateBodyCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    try rp.commit();
    const body = rp.request.body orelse return app.diag.fail(app.frame.allocator(), "regenerate_body: the request has no body", .{});
    var set = env_mod.EnvSet.empty(app.gpa);
    defer set.deinit();
    const fresh = try env_mod.expand(app.gpa, app.io, body, &set);
    defer app.gpa.free(fresh);
    try rp.body.replaceRange(app.gpa, 0, rp.body.items.len, fresh);
    try rp.commit();
    app.toast("body: dynamic values regenerated", .{});
}

fn copyAsCmd(app: *App) CommandError!void {
    return @import("cmd_http.zig").copyAsPicker(app);
}

fn toggleEditSplitCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    rp.toggleSplit();
    if (rp.split) app.toast("edit split: {s} | {s}", .{ rp.edit_tab.label(), rp.split_tab.label() }) else app.toast("edit split: off", .{});
}

fn toggleSplitOrientationCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    rp.orientation = rp.orientation.next();
    app.toast("request / response: {s}", .{rp.orientation.label()});
}

fn refreshCmd(app: *App) CommandError!void {
    _ = app.http.picker_arena.reset(.retain_capacity);
    app.http.history_rows = &.{};
    app.http.captured_curls = &.{};
    try @import("http_panel.zig").refresh(app);
    app.needs_render = true;
    app.toast("http: rescanned", .{});
}

fn saveResponseCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    _ = rp.response() orelse return app.diag.fail(app.frame.allocator(), "save_response: no response yet", .{});
    return @import("cmd_http.zig").openSaveResponsePrompt(app);
}

// ─── Headers tab completion ─────────────────────────────────────────────
// The name column completes from what the last response suggests, the
// names this workspace's `.http` files use, then the bundled table
// (`http/header_table.zig`); the value column from the response's own
// values, the workspace's values for that name, the table's, and the
// env's `{{VAR}}`s. Each source is tagged so the popup says where a row
// came from.

const header_table = @import("../http/header_table.zig");

pub const HeaderCandidate = struct {
    label: []const u8,
    /// `response`, `response ← ETag`, `workspace ×3`, `env`, `` for the table.
    kind: []const u8,
    /// The popup's footer and the `?` tip.
    doc: ?[]const u8,
};

/// A name or value with how often the workspace's files use it.
pub const Counted = struct { text: []const u8, count: u32 };

/// One header name's values across the workspace.
pub const NameValues = struct { name: []const u8, values: []const Counted };

pub const header_scan_ttl_ms: i64 = 5000;
const header_scan_file_cap: usize = 1 << 20;

/// The workspace's header usage: names by frequency, values per name.
pub const HeaderScan = struct {
    arena: std.heap.ArenaAllocator,
    at_ms: i64,
    names: []const Counted = &.{},
    values: []const NameValues = &.{},

    fn destroy(self: *HeaderScan, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn valuesFor(self: *const HeaderScan, name: []const u8) []const Counted {
        for (self.values) |nv| if (std.ascii.eqlIgnoreCase(nv.name, name)) return nv.values;
        return &.{};
    }
};

fn bumpCounted(arena: Allocator, list: *std.ArrayListUnmanaged(Counted), text: []const u8) Allocator.Error!void {
    for (list.items) |*c| if (std.ascii.eqlIgnoreCase(c.text, text)) {
        c.count += 1;
        return;
    };
    try list.append(arena, .{ .text = try arena.dupe(u8, text), .count = 1 });
}

fn sortCounted(list: []Counted) void {
    std.mem.sort(Counted, list, {}, struct {
        fn lt(_: void, a: Counted, b: Counted) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.ascii.lessThanIgnoreCase(a.text, b.text);
        }
    }.lt);
}

/// The scan, fresh within the TTL. Every request file the HTTP panel
/// lists (the same capped workspace walk), each block parsed.
pub fn headerScan(app: *App) Allocator.Error!*const HeaderScan {
    if (app.http.header_scan) |hs| if (app.now_ms - hs.at_ms < header_scan_ttl_ms) return hs;
    const panel = @import("http_panel.zig");
    if (!app.http_panel.scanned_once) try panel.refresh(app);
    const gpa = app.gpa;
    const fresh = try gpa.create(HeaderScan);
    errdefer gpa.destroy(fresh);
    fresh.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .at_ms = app.now_ms };
    errdefer fresh.arena.deinit();
    const a = fresh.arena.allocator();
    var names: std.ArrayListUnmanaged(Counted) = .empty;
    var per_name: std.ArrayListUnmanaged(struct { name: []const u8, values: std.ArrayListUnmanaged(Counted) }) = .empty;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    for (app.http_panel.files) |rel| {
        _ = scratch.reset(.retain_capacity);
        const sa = scratch.allocator();
        const abs = try std.fs.path.join(sa, &.{ app.workspace, rel });
        const text = Io.Dir.cwd().readFileAlloc(app.io, abs, sa, .limited(header_scan_file_cap)) catch continue;
        for (try parse.blocks(sa, text)) |b| {
            var req = parse.parse(sa, b.text) catch continue;
            defer req.deinit(sa);
            for (req.headers.items) |h| {
                try bumpCounted(a, &names, h.name);
                var slot: ?usize = null;
                for (per_name.items, 0..) |pn, i| if (std.ascii.eqlIgnoreCase(pn.name, h.name)) {
                    slot = i;
                    break;
                };
                if (slot == null) {
                    try per_name.append(a, .{ .name = try a.dupe(u8, h.name), .values = .empty });
                    slot = per_name.items.len - 1;
                }
                try bumpCounted(a, &per_name.items[slot.?].values, h.value);
            }
        }
    }
    sortCounted(names.items);
    const values = try a.alloc(NameValues, per_name.items.len);
    for (per_name.items, 0..) |*pn, i| {
        sortCounted(pn.values.items);
        values[i] = .{ .name = pn.name, .values = pn.values.items };
    }
    fresh.names = names.items;
    fresh.values = values;
    if (app.http.header_scan) |old| old.destroy(gpa);
    app.http.header_scan = fresh;
    return fresh;
}

/// The response the completion reads: the Done one, else the previous.
fn lastResponse(rp: *RequestPane) ?*const client.Response {
    if (rp.response()) |r| return r;
    if (rp.prev) |*p| return p;
    return null;
}

fn hasCandidate(list: []const HeaderCandidate, label: []const u8) bool {
    for (list) |c| if (std.ascii.eqlIgnoreCase(c.label, label)) return true;
    return false;
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// The name column's rows, in priority order: the request headers the
/// last response's headers call for (`ETag` → `If-None-Match`), the
/// response's own names, the workspace's names most-used first, then
/// the table. Names already on the tab are left out, except the row
/// being edited (`editing`).
pub fn headerNameCandidates(app: *App, rp: *RequestPane, arena: Allocator, present: []const []const u8, editing: ?[]const u8) Allocator.Error![]HeaderCandidate {
    var out: std.ArrayListUnmanaged(HeaderCandidate) = .empty;
    const skip = struct {
        fn f(list: []const HeaderCandidate, on_tab: []const []const u8, edit: ?[]const u8, name: []const u8) bool {
            if (hasCandidate(list, name)) return true;
            if (edit) |e| if (std.ascii.eqlIgnoreCase(e, name)) return false;
            return hasName(on_tab, name);
        }
    }.f;
    if (lastResponse(rp)) |resp| {
        for (resp.headers) |h| if (header_table.suggestedRequestHeader(h.name)) |want| {
            if (skip(out.items, present, editing, want)) continue;
            try out.append(arena, .{ .label = want, .kind = try std.fmt.allocPrint(arena, "response \u{2190} {s}", .{h.name}), .doc = if (header_table.find(want)) |e| e.doc else null });
        };
        for (resp.headers) |h| {
            if (skip(out.items, present, editing, h.name)) continue;
            try out.append(arena, .{ .label = try arena.dupe(u8, h.name), .kind = "response", .doc = if (header_table.find(h.name)) |e| e.doc else null });
        }
    }
    const scan = try headerScan(app);
    for (scan.names) |n| {
        if (skip(out.items, present, editing, n.text)) continue;
        try out.append(arena, .{ .label = n.text, .kind = try std.fmt.allocPrint(arena, "workspace \u{00D7}{d}", .{n.count}), .doc = if (header_table.find(n.text)) |e| e.doc else null });
    }
    for (&header_table.entries) |*e| {
        if (skip(out.items, present, editing, e.name)) continue;
        try out.append(arena, .{ .label = e.name, .kind = "", .doc = e.doc });
    }
    return out.items;
}

/// The value column's rows for `name`: the last response's answer (the
/// paired header's value, the same name's value, a `Set-Cookie`'s
/// `name=value` for `Cookie`), the workspace's values for the name, the
/// table's, then the env's `{{VAR}}`s.
pub fn headerValueCandidates(app: *App, rp: *RequestPane, arena: Allocator, name: []const u8) Allocator.Error![]HeaderCandidate {
    var out: std.ArrayListUnmanaged(HeaderCandidate) = .empty;
    const doc: ?[]const u8 = if (header_table.find(name)) |e| e.doc else null;
    if (lastResponse(rp)) |resp| {
        if (std.ascii.eqlIgnoreCase(name, "cookie")) {
            for (resp.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
                const nv = std.mem.trim(u8, std.mem.sliceTo(h.value, ';'), " ");
                if (nv.len == 0 or hasCandidate(out.items, nv)) continue;
                try out.append(arena, .{ .label = try arena.dupe(u8, nv), .kind = "response \u{2190} Set-Cookie", .doc = doc });
            };
        }
        if (header_table.pairedResponseHeader(name)) |paired| for (resp.headers) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, paired) or hasCandidate(out.items, h.value)) continue;
            try out.append(arena, .{ .label = try arena.dupe(u8, h.value), .kind = try std.fmt.allocPrint(arena, "response \u{2190} {s}", .{h.name}), .doc = doc });
        };
        for (resp.headers) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, name) or hasCandidate(out.items, h.value)) continue;
            try out.append(arena, .{ .label = try arena.dupe(u8, h.value), .kind = "response", .doc = doc });
        }
    }
    const scan = try headerScan(app);
    for (scan.valuesFor(name)) |v| {
        if (hasCandidate(out.items, v.text)) continue;
        try out.append(arena, .{ .label = v.text, .kind = try std.fmt.allocPrint(arena, "workspace \u{00D7}{d}", .{v.count}), .doc = doc });
    }
    if (header_table.find(name)) |e| for (e.values) |v| {
        if (hasCandidate(out.items, v)) continue;
        try out.append(arena, .{ .label = v, .kind = "", .doc = doc });
    };
    var set = try loadEnv(app, arena);
    defer set.deinit();
    for (set.vars.keys()) |k| {
        const label = try std.fmt.allocPrint(arena, "{{{{{s}}}}}", .{k});
        if (hasCandidate(out.items, label)) continue;
        try out.append(arena, .{ .label = label, .kind = "env", .doc = doc });
    }
    return out.items;
}

/// The one-line description the `?` tip and a hover show for `name`.
pub fn headerDoc(name: []const u8) ?[]const u8 {
    return if (header_table.find(name)) |e| e.doc else null;
}

/// The hit of `pane` under the pointer whose id is in
/// `[base, base + count)`, scanned back to front like `hoveredVar`.
pub fn hoveredHitIn(ui: Ui, pane: PaneId, base: u32, count: u32) ?struct { idx: usize, rect: @import("../ui/rect.zig") } {
    const h = ui.hover orelse return null;
    var i = ui.hits.items.items.len;
    while (i > 0) {
        i -= 1;
        const e = ui.hits.items.items[i];
        if (!e.rect.contains(h.x, h.y)) continue;
        switch (e.target) {
            .script_hit => |sh| if (sh.pane == pane and sh.id >= base and sh.id < base + count) return .{ .idx = sh.id - base, .rect = e.rect },
            else => {},
        }
        return null;
    }
    return null;
}

/// The rect a `.script_hit` of `pane` with `id` was registered at.
pub fn hitRectOf(ui: Ui, pane: PaneId, id: u32) ?@import("../ui/rect.zig") {
    for (ui.hits.items.items) |e| switch (e.target) {
        .script_hit => |sh| if (sh.pane == pane and sh.id == id) return e.rect,
        else => {},
    };
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "a .curl file opens as a request pane; http.new opens a blank one; the fields commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.curl", .data = "# List users\ncurl 'https://x/users' -H 'Accept: application/json'\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "a.curl" });
    defer testing.allocator.free(path);
    const id = try app.openPath(path);
    const rp = app.panes.get(id).?.asRequest().?;
    try testing.expectEqualStrings("GET  List users", rp.title());
    try testing.expectEqualStrings("https://x/users", rp.url.items);
    try testing.expectEqualStrings("Accept: application/json\n", rp.headers_text.items);
    // The same file opens the same pane.
    try testing.expectEqual(id, try app.openPath(path));
    try command.run(&app, .{ .static = .@"http.new" });
    const blank = activeRequest(&app).?;
    try testing.expectEqualStrings("GET  new request", blank.title());
    try testing.expect(blank.block == .request and blank.field == .url);
    try command.run(&app, .{ .static = .@"http.set_method.post" });
    try testing.expectEqualStrings("method: POST", app.lastToast().?);
    try command.run(&app, .{ .static = .@"http.cycle_method" });
    try testing.expectEqualStrings("PUT", blank.request.method);
    try testing.expectEqual(@as(usize, 2), app.panes.count());
}

test "send: a mock server answers; the response lands on the pane and history records it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 201, .status_text = "Created", .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .body = "{\"id\":7}" });
    defer server.stop(testing.io);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/make", .{server.port});
    defer testing.allocator.free(url);
    try rp.url.appendSlice(testing.allocator, url);
    try rp.body.appendSlice(testing.allocator, "{\"a\":1}");
    try rp.setMethod("post");
    try command.run(&app, .{ .static = .@"http.send" });
    try testing.expect(rp.state == .sending);
    var waited: usize = 0;
    while (rp.state == .sending and waited < 200) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(rp.state == .done);
    try testing.expectEqual(@as(u16, 201), rp.response().?.status);
    try testing.expectEqualStrings("{\"id\":7}", rp.response().?.body);
    try testing.expect(std.mem.startsWith(u8, rp.sent_line.?, "POST http://127.0.0.1:"));
    try testing.expect(rp.resp_editor != null);
    const hist = try tmp.dir.readFileAlloc(testing.io, ".rqst/history.jsonl", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(hist);
    try testing.expect(std.mem.indexOf(u8, hist, "\"status\":201") != null);
    // A second send keeps the first as `prev` for the diff.
    try command.run(&app, .{ .static = .@"http.send" });
    waited = 0;
    while (rp.state == .sending and waited < 200) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(rp.prev != null);
    try command.run(&app, .{ .static = .@"http.diff_last_two" });
    try testing.expect(std.mem.startsWith(u8, app.activeBuffer().?.editor.bytes(), "# HTTP diff"));
}

test "send: a failure landing while the user tabbed back into the request leaves the edit alone" {
    // The race tests/e2e/http_multi_block_writeback.test only hits under
    // load: the worker's failure used to move the focus block to the
    // response whenever it arrived, so a Tab into the URL followed by
    // typing lost the typed text to the response block. Here the order
    // is forced: send → Tab twice during the send (request → response →
    // request) → the failure is pumped by tick → the block must still be
    // the request. Without a user move, the failure shows itself.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    // Port 1 refuses: the worker reports a failure, asynchronously.
    try rp.url.appendSlice(testing.allocator, "http://127.0.0.1:1/refused");
    try command.run(&app, .{ .static = .@"http.send" });
    try testing.expect(rp.state == .sending);
    try testing.expect(!rp.moved_since_send);
    _ = try request_pane.handleKey(&app, id, rp, Key.named(.tab));
    try testing.expect(rp.block == .response);
    _ = try request_pane.handleKey(&app, id, rp, Key.named(.tab));
    try testing.expect(rp.block == .request and rp.moved_since_send);
    var waited: usize = 0;
    while (rp.state == .sending and waited < 300) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(rp.state == .failed);
    try testing.expect(rp.block == .request);
    // The control: the next send, untouched, jumps to the response.
    try command.run(&app, .{ .static = .@"http.send" });
    try testing.expect(!rp.moved_since_send);
    waited = 0;
    while (rp.state == .sending and waited < 300) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(rp.state == .failed);
    try testing.expect(rp.block == .response);
}

test "save: a multi-block .http writes back one block; a scratch prompts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const src = "### one\nGET https://example.com/one\n\n### two\nPOST https://example.com/two\nContent-Type: application/json\n\n{\"a\": 1}\n\n### three\nGET https://example.com/three\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "r.http", .data = src });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "r.http" });
    defer testing.allocator.free(path);
    _ = try app.openEditor(path);
    app.activeEditor().?.buf.editor.placeCursor(5, 0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var active = try parseActive(&app, arena.allocator());
    try testing.expectEqualStrings("two", active.block_name.?);
    const id = try openFromRequest(&app, active.req, .{ .source_path = active.source_path, .block_name = active.block_name });
    active.req = undefined;
    const rp = app.panes.get(id).?.asRequest().?;
    try rp.url.appendSlice(testing.allocator, " EDIT");
    try saveToSource(&app);
    const out = try tmp.dir.readFileAlloc(testing.io, "r.http", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "### one\nGET https://example.com/one\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### three\nGET https://example.com/three\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "POST https://example.com/two EDIT\nContent-Type: application/json\n\n{\"a\": 1}\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "curl '") == null);
    // params
    try command.run(&app, .{ .static = .@"http.params_add" });
    try testing.expect(rp.draft != null and rp.edit_tab == .params);
    try rp.draft.?.key.appendSlice(testing.allocator, "k");
    try rp.draft.?.value.appendSlice(testing.allocator, "v");
    try testing.expect(try rp.commitDraft());
    try testing.expect(std.mem.endsWith(u8, rp.url.items, "two EDIT?k=v"));
    try command.run(&app, .{ .static = .@"http.params_clear" });
    try testing.expectEqualStrings("params: cleared 1", app.lastToast().?);
    try command.run(&app, .{ .static = .@"http.copy_curl" });
    try testing.expect(std.mem.startsWith(u8, app.clipboard.text(), "curl 'https://example.com/two EDIT'"));
}

test "save: two bare ### blocks each keep their own pane, and saving block two leaves block one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const src = "###\nGET http://127.0.0.1:9/items?n=first\n\n###\nGET http://127.0.0.1:9/items?n=second\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bare.http", .data = src });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "bare.http" });
    defer testing.allocator.free(path);
    const first = try openFileBlock(&app, path, 0);
    const second = try openFileBlock(&app, path, 1);
    // Both are named "" — the position keeps them apart.
    try testing.expect(first != second);
    try testing.expectEqual(@as(?PaneId, second), findSource(&app, path, 1, ""));
    try testing.expectEqual(@as(?PaneId, first), findSource(&app, path, 0, ""));
    // The editor's cursor on block two finds block two.
    _ = try app.openEditor(path);
    app.activeEditor().?.buf.editor.placeCursor(4, 0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var active = try parseActive(&app, arena.allocator());
    defer active.req.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), active.block_index);
    app.showPane(second);
    const rp = app.panes.get(second).?.asRequest().?;
    try rp.url.appendSlice(testing.allocator, "&edited=1");
    try saveToSource(&app);
    const out = try tmp.dir.readFileAlloc(testing.io, "bare.http", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("###\nGET http://127.0.0.1:9/items?n=first\n\n###\nGET http://127.0.0.1:9/items?n=second&edited=1\n", out);
}

test "send: the cursor on a comment-only block is refused, not block one fired" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.http", .data = "### one\nDELETE http://127.0.0.1:9/items/1\n\n### notes\n# a comment, no request yet\n\n### two\nGET http://127.0.0.1:9/items\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "c.http" });
    defer testing.allocator.free(path);
    _ = try app.openEditor(path);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 3, 4 }) |line| {
        app.activeEditor().?.buf.editor.placeCursor(line, 0);
        try testing.expectError(error.Failed, parseActive(&app, arena.allocator()));
        try testing.expectEqualStrings("http: the block under the cursor is empty", app.diag.msg.?);
        app.diag.clear();
    }
    app.activeEditor().?.buf.editor.placeCursor(7, 0);
    var active = try parseActive(&app, arena.allocator());
    defer active.req.deinit(testing.allocator);
    try testing.expectEqualStrings("two", active.block_name.?);
}

fn pumpUntil(app: *App, rp: *RequestPane, comptime pred: fn (*RequestPane) bool, max_ticks: usize) !void {
    var waited: usize = 0;
    while (!pred(rp) and waited < max_ticks) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
}

test "stream: an event-stream lands event by event, live, then seals into the Done response" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const chunks = [_][]const u8{ "event: a\ndata: one\n\n", "data: two\n\n", "event: c\ndata: three\n\n" };
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }}, .chunks = &chunks, .chunk_delay_ms = 400 });
    // 400 ms between events: "the second is visible before the third
    // exists" needs a tick to land between two chunks, and at 60 ms a
    // slow macOS runner's stall let two land in one tick (events went
    // 1 → 3). The waits below are tick counts (≥ 10 ms each), well past it.
    defer server.stop(testing.io);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/events", .{server.port});
    defer testing.allocator.free(url);
    try rp.url.appendSlice(testing.allocator, url);
    try command.run(&app, .{ .static = .@"http.send" });
    try testing.expect(rp.state == .sending);
    // The head arrives first: the pane is streaming with an empty body.
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state != .sending;
        }
    }.f, 300);
    try testing.expect(rp.state == .streaming);
    try testing.expect(rp.streaming().?.is_sse);
    try testing.expectEqual(@as(u16, 200), rp.streaming().?.head.status);
    // Events land one at a time — the second is visible before the third exists.
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state != .streaming or p.streaming().?.events >= 2;
        }
    }.f, 300);
    try testing.expect(rp.state == .streaming);
    try testing.expectEqual(@as(usize, 2), rp.streaming().?.events);
    // And the SCREEN shows them while the stream is open — not a
    // `sending…` spinner over events that have already arrived.
    {
        try app.render();
        const txt = try @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
        defer testing.allocator.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "sending\u{2026}") == null);
        try testing.expect(std.mem.indexOf(u8, txt, "streaming \u{00B7} 2 events") != null);
        try testing.expect(std.mem.indexOf(u8, txt, "data: two") != null);
    }
    try testing.expect(std.mem.indexOf(u8, rp.streaming().?.body.items, "data: two") != null);
    try testing.expect(std.mem.indexOf(u8, rp.streaming().?.body.items, "three") == null);
    try testing.expectEqual(@as(u32, 1), app.http.sending);
    // The socket closes: the stream seals into a Done response with the whole body.
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .done or p.state == .failed;
        }
    }.f, 300);
    try testing.expect(rp.state == .done);
    try testing.expectEqualStrings("event: a\ndata: one\n\ndata: two\n\nevent: c\ndata: three\n\n", rp.response().?.body);
    try testing.expectEqual(@as(usize, 0), app.http.handles.count());
    try testing.expectEqual(@as(u32, 0), app.http.sending);
    try command.run(&app, .{ .static = .@"sse.parse_active_response" });
    try testing.expect(std.mem.startsWith(u8, app.lastToast().?, "sse: 3 event(s)"));
    const hist = try tmp.dir.readFileAlloc(testing.io, ".rqst/history.jsonl", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(hist);
    try testing.expect(std.mem.indexOf(u8, hist, "\"status\":200") != null);
}

test "history: a re-fire resolves the URL and the headers against the env it was sent with; an env pick moves both" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .status_text = "OK", .body = "ok" });
    defer server.stop(testing.io);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    const dev = try std.fmt.allocPrint(testing.allocator, "BASE=http://127.0.0.1:{d}/dev\nTOKEN=dev-token\n", .{server.port});
    defer testing.allocator.free(dev);
    const stg = try std.fmt.allocPrint(testing.allocator, "BASE=http://127.0.0.1:{d}/stg\nTOKEN=staging-token\n", .{server.port});
    defer testing.allocator.free(stg);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = dev });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/staging.env", .data = stg });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.http", .data = "GET {{BASE}}/me\nAuthorization: Bearer {{TOKEN}}\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "a.http" });
    defer testing.allocator.free(path);
    const first = try openFile(&app, path, false);
    try fire(&app, first);
    const done = struct {
        fn f(p: *RequestPane) bool {
            return p.state == .done or p.state == .failed;
        }
    }.f;
    try pumpUntil(&app, app.panes.get(first).?.asRequest().?, done, 300);
    try testing.expect(std.mem.startsWith(u8, server.lastRequest(), "GET /dev/me "));
    // Staging becomes the active env; the dev entry is re-fired.
    const cmd_http = @import("cmd_http.zig");
    try cmd_http.acceptPicker(&app, .http_env_pick, 0, "staging");
    try command.run(&app, .{ .static = .@"http.history" });
    try cmd_http.acceptPicker(&app, .http_history, 0, "");
    const again = app.active.?;
    try testing.expect(again != first);
    const rp = app.panes.get(again).?.asRequest().?;
    try testing.expectEqualStrings("dev", rp.env_pin.?);
    try fire(&app, again);
    try pumpUntil(&app, rp, done, 300);
    // One env for all of it: dev's host AND dev's token.
    try testing.expect(std.mem.startsWith(u8, server.lastRequest(), "GET /dev/me "));
    try testing.expect(std.ascii.findIgnoreCase(server.lastRequest(), "authorization: Bearer dev-token\r\n") != null);
    // An explicit pick moves the whole request to the new env.
    try cmd_http.acceptPicker(&app, .http_env_pick, 0, "staging");
    try testing.expect(rp.env_pin == null);
    try fire(&app, again);
    try pumpUntil(&app, rp, done, 300);
    try testing.expect(std.mem.startsWith(u8, server.lastRequest(), "GET /stg/me "));
    try testing.expect(std.ascii.findIgnoreCase(server.lastRequest(), "authorization: Bearer staging-token\r\n") != null);
}

test "the Response strip's type chip opens the body menu, not a toast" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    try openResponseBodyMenu(&app, rp, 10, 10);
    try testing.expect(app.overlay != .menu);
    try testing.expectEqualStrings("no response yet", app.lastToast().?);
    const gpa = testing.allocator;
    try rp.setResponse(.{ .status = 200, .status_text = try gpa.dupe(u8, "OK"), .final_url = try gpa.dupe(u8, "http://x/"), .headers = &.{}, .body = try gpa.dupe(u8, "{}") });
    // A press on the chip is what opens it.
    try @import("request_pane.zig").click(&app, id, rp, @import("../ui/request_view.zig").hit_type, .{ .x = 10, .y = 10, .kind = .press, .button = .left });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqual(@as(usize, 4), app.overlay.menu.items.len);
    try testing.expectEqual(command.CommandId.@"http.copy_response_body", app.overlay.menu.items[0].action.command);
    try testing.expectEqual(command.CommandId.@"http.toggle_response_wrap", app.overlay.menu.items[3].action.command);
}

test "stream: an event that shares a packet with the head shows before the server writes again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const chunks = [_][]const u8{ "id: 1\ndata: first-event\n\n", "data: second\n\n" };
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }}, .chunks = &chunks, .chunk_delay_ms = 3000, .first_with_head = true });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/events", .{server.port});
    defer testing.allocator.free(url);
    try rp.url.appendSlice(testing.allocator, url);
    try command.run(&app, .{ .static = .@"http.send" });
    // Well inside the server's 3 s pause before the second event.
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state != .sending and (p.state != .streaming or p.streaming().?.events >= 1);
        }
    }.f, 100);
    try testing.expect(rp.state == .streaming);
    try testing.expectEqual(@as(usize, 1), rp.streaming().?.events);
    try testing.expect(std.mem.indexOf(u8, rp.streaming().?.body.items, "first-event") != null);
    try command.run(&app, .{ .static = .@"http.cancel" });
    server.stop(testing.io);
}

test "stream: http.cancel stops a stream where it is; a chunked body of any type streams with a byte count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const chunks = [_][]const u8{ "data: first\n\n", "data: never\n\n" };
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }}, .chunks = &chunks, .chunk_delay_ms = 400 });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{server.port});
    defer testing.allocator.free(url);
    try rp.url.appendSlice(testing.allocator, url);
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .streaming and p.streaming().?.events >= 1;
        }
    }.f, 300);
    try testing.expect(rp.state == .streaming);
    // The server is parked on its 400 ms sleep; the cancel must not wait for it.
    const before = App.nowMs(app.io);
    try command.run(&app, .{ .static = .@"http.cancel" });
    try testing.expect(App.nowMs(app.io) - before < 300);
    // What arrived before the cancel is kept, marked truncated.
    try testing.expect(rp.state == .done);
    try testing.expectEqualStrings("data: first\n\n", rp.response().?.body);
    try testing.expect(rp.response().?.truncated);
    try testing.expectEqual(@as(usize, 0), app.http.handles.count());
    try testing.expectEqual(@as(u32, 0), app.http.sending);
    // A late chunk for the dead job is dropped, not appended.
    try app.tick(App.nowMs(app.io));
    try testing.expectEqualStrings("data: first\n\n", rp.response().?.body);
    server.stop(testing.io);

    // Chunked framing on a plain body streams too, counting bytes.
    const parts = [_][]const u8{ "{\"a\":", "1}" };
    var server2 = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .chunks = &parts, .chunked = true, .chunk_delay_ms = 400 });
    // 400 ms, not 30: the pane has to be seen mid-stream, and a slow
    // runner's stall at 30 ms saw the stream already sealed.
    defer server2.stop(testing.io);
    const url2 = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/chunked", .{server2.port});
    defer testing.allocator.free(url2);
    rp.url.clearRetainingCapacity();
    try rp.url.appendSlice(testing.allocator, url2);
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .streaming and p.streaming().?.body.items.len > 0;
        }
    }.f, 300);
    try testing.expect(rp.state == .streaming);
    try testing.expect(!rp.streaming().?.is_sse and rp.streaming().?.chunked);
    try testing.expectEqual(@as(usize, 5), rp.streaming().?.body.items.len);
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .done or p.state == .failed;
        }
    }.f, 300);
    try testing.expect(rp.state == .done);
    try testing.expectEqualStrings("{\"a\":1}", rp.response().?.body);
    try testing.expect(rp.resp_editor != null);
    // `http.cancel` with nothing in flight says so.
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"http.cancel" }));
}

test "directives: @set-* reach the wire, @assert rows land on the Tests tab, @capture persists into the env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "x-request-id", .value = "req-7" } }, .body = "{\"id\":7,\"name\":\"Ada\"}" });
    defer server.stop(testing.io);
    const src = try std.fmt.allocPrint(testing.allocator,
        \\# @set-var PROBE = yes
        \\# @set-header X-Probe = {{{{PROBE}}}}
        \\# @set-cookie session = abc
        \\# @assert status == 200
        \\# @assert body.id == 7
        \\# @assert header.content-type ~ /json/
        \\# @assert body.name == Grace
        \\# @capture USER_ID = body.id
        \\# @capture TRACE = header x-request-id
        \\GET http://127.0.0.1:{d}/users/7
        \\
    , .{server.port});
    defer testing.allocator.free(src);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "u.http", .data = src });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "u.http" });
    defer testing.allocator.free(path);
    const id = try app.openPath(path);
    const rp = app.panes.get(id).?.asRequest().?;
    try testing.expect(rp.request.script != null);
    try testing.expect(std.mem.indexOf(u8, rp.request.script.?, "@capture USER_ID = body.id") != null);
    // The pane's own fields stay as written: no X-Probe in the Headers tab.
    try testing.expect(std.mem.indexOf(u8, rp.headers_text.items, "X-Probe") == null);
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .done or p.state == .failed;
        }
    }.f, 300);
    try testing.expect(rp.state == .done);
    const seen = server.lastRequest();
    try testing.expect(std.ascii.findIgnoreCase(seen, "x-probe: yes\r\n") != null);
    try testing.expect(std.ascii.findIgnoreCase(seen, "cookie: session=abc\r\n") != null);
    // Tests tab: three passes, one failure with the value it saw, two captures.
    var passes: usize = 0;
    var fails: usize = 0;
    for (rp.tests.items) |line| {
        if (std.mem.startsWith(u8, line, "✓")) passes += 1;
        if (std.mem.startsWith(u8, line, "✗")) fails += 1;
    }
    try testing.expectEqual(@as(usize, 3), passes);
    try testing.expectEqual(@as(usize, 1), fails);
    var found_fail = false;
    var found_capture = false;
    for (rp.tests.items) |line| {
        if (std.mem.eql(u8, line, "✗ body.name == Grace — got Ada")) found_fail = true;
        if (std.mem.eql(u8, line, "↳ TRACE = req-7")) found_capture = true;
    }
    try testing.expect(found_fail and found_capture);
    try testing.expectEqualStrings("tests: 3 passed, 1 failed", app.lastToast().?);
    // Captures were written into the active env file.
    const env_text = try tmp.dir.readFileAlloc(testing.io, ".mnml/env/dev.env", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(env_text);
    try testing.expect(std.mem.indexOf(u8, env_text, "USER_ID=7\n") != null);
    try testing.expect(std.mem.indexOf(u8, env_text, "TRACE=req-7\n") != null);
    // A write-back keeps the directive lines above the request line.
    try rp.url.appendSlice(testing.allocator, "?x=1");
    try saveToSource(&app);
    const out = try tmp.dir.readFileAlloc(testing.io, "u.http", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "# @set-var PROBE = yes\n"));
    try testing.expect(std.mem.indexOf(u8, out, "# @capture TRACE = header x-request-id\nGET http://127.0.0.1:") != null);
}

test "send: a GET with trailing directives sends no body, and a 302's Set-Cookie lands in the jar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    const final: mock.Canned = .{ .status = 200, .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .body = "{\"cookies\":{}}" };
    var server = try mock.Server.start(testing.allocator, testing.io, .{
        .status = 302,
        .status_text = "Found",
        .headers = &.{ .{ .name = "set-cookie", .value = "session=abc123; Path=/" }, .{ .name = "set-cookie", .value = "user=chris" }, .{ .name = "location", .value = "/cookies" } },
        .next = &final,
    });
    defer server.stop(testing.io);
    // The documented shape: the directives after the blank line.
    const src = try std.fmt.allocPrint(testing.allocator,
        \\### get-json
        \\GET http://127.0.0.1:{d}/cookies/set?session=abc123
        \\Accept: application/json
        \\
        \\# @assert status == 200
        \\# @capture origin = body.cookies
        \\
    , .{server.port});
    defer testing.allocator.free(src);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.http", .data = src });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "c.http" });
    defer testing.allocator.free(path);
    const id = try app.openPath(path);
    const rp = app.panes.get(id).?.asRequest().?;
    try testing.expect(rp.request.body == null);
    try testing.expectEqual(@as(usize, 0), rp.body.items.len);
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntil(&app, rp, struct {
        fn f(p: *RequestPane) bool {
            return p.state == .done or p.state == .failed;
        }
    }.f, 300);
    try testing.expect(rp.state == .done);
    try testing.expectEqual(@as(u16, 200), rp.response().?.status);
    // The wire saw a plain GET: no body, no length, no directive text.
    const seen = server.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "GET /cookies HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen, "@assert") == null);
    try testing.expect(std.ascii.findIgnoreCase(seen, "content-length:") == null);
    try testing.expect(std.ascii.findIgnoreCase(seen, "cookie: session=abc123; user=chris\r\n") != null);
    // The hop's cookies are in the jar, keyed by the host that set them.
    const j = try @import("cmd_http.zig").jar(&app);
    try testing.expectEqual(@as(usize, 2), j.total());
    const line = (try j.cookieHeaderFor(testing.allocator, "127.0.0.1", "/cookies", false, 0)).?;
    defer testing.allocator.free(line);
    // `user` came with no Path from `/cookies/set`: its default path is
    // `/cookies` (RFC 6265 §5.1.4), so it rides first there — and not to `/`.
    try testing.expectEqualStrings("user=chris; session=abc123", line);
    const saved = try tmp.dir.readFileAlloc(testing.io, ".mnml/cookies.json", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "abc123") != null);
    // The directive rows ran against the final response.
    var ok_row = false;
    for (rp.tests.items) |line_| if (std.mem.eql(u8, line_, "✓ status == 200")) {
        ok_row = true;
    };
    try testing.expect(ok_row);
}

test "vars: tokens classify against the env, a secret masks in the tip, the jump lands on the key's line or at the end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.createDirPath(testing.io, ".rqst");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/config", .data = "default_env=dev\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "HOST=https://dev.example\n# @secret TOKEN\nTOKEN=abc123\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "api.http", .data = "GET {{HOST}}/x/{{MISSING}}?id={{$uuid}}\nAuthorization: Bearer {{TOKEN}}\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "api.http" });
    defer testing.allocator.free(path);
    _ = try app.openPath(path);
    const rp = activeRequest(&app).?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try varTokens(&app, rp, a, try envName(&app, a));
    try testing.expectEqual(@as(usize, 4), toks.all.len);
    try testing.expectEqual(@as(usize, 3), toks.url.len);
    try testing.expectEqual(@as(usize, 1), toks.headers.len);
    try testing.expectEqual(@as(usize, 0), toks.body.len);
    const host = toks.all[toks.url[0].id];
    try testing.expectEqualStrings("HOST", host.name);
    try testing.expect(host.resolved and !host.dynamic);
    try testing.expectEqualStrings("https://dev.example", host.shown.?);
    const missing = toks.all[toks.url[1].id];
    try testing.expectEqualStrings("MISSING", missing.name);
    try testing.expect(!missing.resolved and missing.shown == null and !toks.url[1].resolved);
    const uuid = toks.all[toks.url[2].id];
    try testing.expect(uuid.dynamic and uuid.resolved);
    try testing.expectEqualStrings("(built-in)", uuid.shown.?);
    const token = toks.all[toks.headers[0].id];
    try testing.expectEqualStrings("TOKEN", token.name);
    try testing.expect(token.resolved);
    try testing.expectEqualStrings("••••••••", token.shown.?);
    // The spans sit on the tokens' bytes.
    try testing.expectEqualStrings("{{HOST}}", rp.url.items[toks.url[0].start..toks.url[0].end]);

    // The jump: a defined key lands on its line, an undefined one at
    // the end of the file with a hint.
    try jumpToVarDef(&app, "TOKEN");
    const e = app.activeEditor().?;
    try testing.expect(std.mem.endsWith(u8, e.buf.doc.path.?, ".mnml/env/dev.env"));
    try testing.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try jumpToVarDef(&app, "NOPE");
    try testing.expectEqual(e.buf.editor.lineCount() - 1, app.activeEditor().?.buf.editor.currentLine());
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "not defined") != null);
    // `gd` in that editor is not on a request file: it does nothing here.
    try testing.expect(!try jumpVarAtCursor(&app));
}

test "completion: `{{` lists the env's names (a secret masked), the built-ins and the block's captures; typing filters; Enter inserts name}}; bare summon writes the braces" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.createDirPath(testing.io, ".rqst");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/config", .data = "default_env=dev\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "HOST=https://dev.example\n# @secret TOKEN\nTOKEN=abc123\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "api.http", .data = "GET https://x/\n\n# @capture ID = body.id\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "api.http" });
    defer testing.allocator.free(path);
    _ = try app.openPath(path);
    const id = app.active.?;
    const rp = activeRequest(&app).?;
    rp.focusUrl();
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    try testing.expect(app.http.completion == null);
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    const c = &(app.http.completion orelse return error.TestExpectedPopup);
    try testing.expect(c.field == .url and c.start == "https://x/{{".len and !c.bare);
    const find = struct {
        fn f(items: []const VarCompletion.Item, name: []const u8) ?VarCompletion.Item {
            for (items) |it| if (std.mem.eql(u8, it.name, name)) return it;
            return null;
        }
    }.f;
    const host = find(c.items, "HOST") orelse return error.TestExpectedRow;
    try testing.expectEqualStrings("env", host.kind);
    try testing.expectEqualStrings("https://dev.example", host.detail);
    const token = find(c.items, "TOKEN") orelse return error.TestExpectedRow;
    try testing.expectEqualStrings(repeat("\u{2022}", 8), token.detail);
    const uuid = find(c.items, "$uuid") orelse return error.TestExpectedRow;
    try testing.expectEqualStrings("built-in", uuid.kind);
    try testing.expectEqual(@as(usize, 36), uuid.detail.len);
    const cap = find(c.items, "ID") orelse return error.TestExpectedRow;
    try testing.expectEqualStrings("capture", cap.kind);
    try testing.expectEqualStrings("(set by the response)", cap.detail);
    // Typing filters the rows; Enter inserts the name and the braces.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(c.items.len, (try visibleVarCompletions(&app, rp, a)).len);
    _ = try request_pane.handleKey(&app, id, rp, Key.char('H'));
    _ = try request_pane.handleKey(&app, id, rp, Key.char('O'));
    const vis = try visibleVarCompletions(&app, rp, a);
    try testing.expectEqual(@as(usize, 1), vis.len);
    try testing.expectEqualStrings("HOST", c.items[vis[0]].name);
    try testing.expect(try request_pane.handleKey(&app, id, rp, .{ .code = .enter }));
    try testing.expect(app.http.completion == null);
    try testing.expectEqualStrings("https://x/{{HOST}}", rp.url.items);
    try testing.expectEqual(rp.url.items.len, rp.url_caret);
    try testing.expectEqualStrings("https://x/{{HOST}}", rp.request.url);
    // A `}` typed after the word closes the popup; Esc does too.
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    try testing.expect(app.http.completion != null);
    _ = try request_pane.handleKey(&app, id, rp, Key.char('}'));
    try testing.expect(app.http.completion == null);
    _ = try request_pane.handleKey(&app, id, rp, .{ .code = .backspace });
    _ = try request_pane.handleKey(&app, id, rp, .{ .code = .backspace });
    _ = try request_pane.handleKey(&app, id, rp, .{ .code = .backspace });
    try testing.expectEqualStrings("https://x/{{HOST}}", rp.url.items);
    // Summoned bare, the accept writes `{{name}}` whole.
    try command.run(&app, .{ .static = .@"http.complete_var" });
    const bare = &(app.http.completion orelse return error.TestExpectedPopup);
    try testing.expect(bare.bare);
    var host_idx: u32 = 0;
    for (bare.items, 0..) |it, i| if (std.mem.eql(u8, it.name, "HOST")) {
        host_idx = @intCast(i);
    };
    try acceptVarCompletion(&app, rp, host_idx);
    try testing.expectEqualStrings("https://x/{{HOST}}{{HOST}}", rp.url.items);
    // The params draft completes too.
    try rp.startDraft();
    rp.draft.?.on_value = true;
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    _ = try request_pane.handleKey(&app, id, rp, Key.char('{'));
    try testing.expect(app.http.completion != null and app.http.completion.?.field == .draft_value);
    try testing.expect(try request_pane.handleKey(&app, id, rp, .{ .code = .esc }));
    try testing.expect(app.http.completion == null and rp.draft != null);
}

test "vars: the editor hook paints a request buffer's tokens and gd on one jumps to the env file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "HOST=h\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "req.http", .data = "GET {{HOST}}/a/{{NOPE}}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.txt", .data = "{{HOST}}\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "req.http" });
    defer testing.allocator.free(path);
    _ = try app.openEditor(path);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e = app.activeEditor().?;
    const spans = try editorVarSpans(&app, arena.allocator(), e);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expect(spans[0].resolved and !spans[1].resolved);
    try testing.expectEqual(@as(usize, 4), spans[0].start);
    // Not a request file: no spans, no jump.
    const plain = try std.fs.path.join(testing.allocator, &.{ root, "plain.txt" });
    defer testing.allocator.free(plain);
    _ = try app.openEditor(plain);
    try testing.expectEqual(@as(usize, 0), (try editorVarSpans(&app, arena.allocator(), app.activeEditor().?)).len);
    try testing.expect(!try jumpVarAtCursor(&app));
    // Back on the request file, the cursor on {{HOST}}: gd lands on HOST's line.
    _ = try app.openEditor(path);
    app.activeEditor().?.buf.editor.placeCursor(0, 6);
    try testing.expect(try jumpVarAtCursor(&app));
    try testing.expect(std.mem.endsWith(u8, app.activeEditor().?.buf.doc.path.?, "dev.env"));
    try testing.expectEqual(@as(usize, 0), app.activeEditor().?.buf.editor.currentLine());
}

test "Headers completion: names from the last response first (a paired header, then its own), the workspace's next, then the table; values likewise, the env's vars last" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "api");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "api/a.http", .data = "GET https://x/a\nX-Team: alpha\nAccept: text/csv\n\n###\nGET https://x/b\nX-Team: alpha\nX-Team: beta\n" });
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "TOKEN=abc\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No response yet: the workspace's names lead, most used first, then the table.
    const cold = try headerNameCandidates(&app, rp, a, &.{}, null);
    try testing.expectEqualStrings("X-Team", cold[0].label);
    try testing.expectEqualStrings("workspace \u{00D7}3", cold[0].kind);
    try testing.expectEqualStrings("Accept", cold[1].label);
    try testing.expectEqualStrings("workspace \u{00D7}1", cold[1].kind);
    try testing.expectEqualStrings("Accept-Charset", cold[2].label);
    try testing.expectEqualStrings("", cold[2].kind);
    try testing.expect(cold[2].doc != null);
    // A response: what it calls for first (ETag → If-None-Match, Content-Type → Accept),
    // then its own names, then the workspace's, then the table's.
    const mk = struct {
        fn h(gpa: Allocator, n: []const u8, v: []const u8) !client.Header {
            return .{ .name = try gpa.dupe(u8, n), .value = try gpa.dupe(u8, v) };
        }
    };
    const gpa = testing.allocator;
    const hs = try gpa.alloc(client.Header, 4);
    hs[0] = try mk.h(gpa, "ETag", "\"abc\"");
    hs[1] = try mk.h(gpa, "Server", "mock");
    hs[2] = try mk.h(gpa, "Content-Type", "application/json");
    hs[3] = try mk.h(gpa, "Set-Cookie", "sid=1; Path=/");
    try rp.setResponse(.{ .status = 200, .status_text = try gpa.dupe(u8, "OK"), .final_url = try gpa.dupe(u8, "http://x/"), .headers = hs, .body = try gpa.dupe(u8, "{}") });
    const warm = try headerNameCandidates(&app, rp, a, &.{}, null);
    try testing.expectEqualStrings("If-None-Match", warm[0].label);
    try testing.expectEqualStrings("response \u{2190} ETag", warm[0].kind);
    try testing.expectEqualStrings("Accept", warm[1].label);
    try testing.expectEqualStrings("response \u{2190} Content-Type", warm[1].kind);
    try testing.expectEqualStrings("ETag", warm[2].label);
    try testing.expectEqualStrings("response", warm[2].kind);
    try testing.expectEqualStrings("Server", warm[3].label);
    try testing.expectEqualStrings("Content-Type", warm[4].label);
    try testing.expectEqualStrings("Set-Cookie", warm[5].label);
    try testing.expectEqualStrings("X-Team", warm[6].label);
    try testing.expectEqualStrings("workspace \u{00D7}3", warm[6].kind);
    try testing.expectEqualStrings("Accept-Charset", warm[7].label);
    // Names already on the tab are left out — except the row being edited.
    const present = [_][]const u8{ "content-type", "X-Team" };
    const trimmed = try headerNameCandidates(&app, rp, a, &present, "X-Team");
    for (trimmed) |c| try testing.expect(!std.ascii.eqlIgnoreCase(c.label, "Content-Type"));
    try testing.expectEqualStrings("X-Team", trimmed[5].label);
    // Values: the paired response header's value, then the workspace's,
    // the table's, the env's `{{VAR}}`s.
    const inm = try headerValueCandidates(&app, rp, a, "If-None-Match");
    try testing.expectEqualStrings("\"abc\"", inm[0].label);
    try testing.expectEqualStrings("response \u{2190} ETag", inm[0].kind);
    try testing.expectEqualStrings("*", inm[1].label);
    try testing.expectEqualStrings("{{TOKEN}}", inm[inm.len - 1].label);
    try testing.expectEqualStrings("env", inm[inm.len - 1].kind);
    const accept = try headerValueCandidates(&app, rp, a, "accept");
    try testing.expectEqualStrings("application/json", accept[0].label);
    try testing.expectEqualStrings("response \u{2190} Content-Type", accept[0].kind);
    try testing.expectEqualStrings("text/csv", accept[1].label);
    try testing.expectEqualStrings("workspace \u{00D7}1", accept[1].kind);
    try testing.expectEqualStrings("*/*", accept[2].label); // application/json deduped from the table
    try testing.expect(accept[0].doc != null);
    const cookie = try headerValueCandidates(&app, rp, a, "Cookie");
    try testing.expectEqualStrings("sid=1", cookie[0].label);
    try testing.expectEqualStrings("response \u{2190} Set-Cookie", cookie[0].kind);
    const team = try headerValueCandidates(&app, rp, a, "x-team");
    try testing.expectEqualStrings("alpha", team[0].label);
    try testing.expectEqualStrings("workspace \u{00D7}2", team[0].kind);
    try testing.expectEqualStrings("beta", team[1].label);
    try testing.expectEqualStrings("{{TOKEN}}", team[2].label);
    // The description the `?` tip and the hover copy show.
    try testing.expect(std.mem.startsWith(u8, headerDoc("content-type").?, "The media type"));
    try testing.expect(headerDoc("X-Team") == null);
}

test "env reload: the first tick is silent, an edit toasts once and rescans the panel, a quiet tick says nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "HOST=one\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    try @import("http_panel.zig").refresh(&app);
    try testing.expectEqual(@as(usize, 1), app.http_panel.envs.len);
    try tick(&app, 1);
    try testing.expect(app.lastToast() == null);
    try tick(&app, 2);
    try testing.expect(app.lastToast() == null);
    // The edit lands: one toast, the panel rescanned (a new env shows up).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "HOST=two\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/prod.env", .data = "HOST=p\n" });
    try tick(&app, 3);
    try testing.expectEqualStrings("env: dev reloaded", app.lastToast().?);
    try testing.expectEqual(@as(usize, 2), app.http_panel.envs.len);
    const n = app.toasts.items.len;
    try tick(&app, 4);
    try testing.expectEqual(n, app.toasts.items.len);
    // mnml's own write (a @capture, the env prompts) is not a reload.
    try @import("cmd_http.zig").setEnvVar(&app, "MINE", "1");
    try tick(&app, 5);
    try testing.expect(std.mem.startsWith(u8, app.lastToast().?, "env: wrote MINE=1"));
    // The pane's Vars rows read the new value.
    try command.run(&app, .{ .static = .@"http.new" });
    const rp = activeRequest(&app).?;
    try rp.url.appendSlice(testing.allocator, "https://{{HOST}}/");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try varRows(&app, rp, arena.allocator(), "dev");
    try testing.expectEqualStrings("two", rows[0].value.?);
}

test "description and tags: the prompts write the directives, the block keeps them, the pane's model carries them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 100, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"http.new" });
    const rp = activeRequest(&app).?;
    try command.run(&app, .{ .static = .@"http.set_description" });
    try testing.expect(app.overlay == .prompt);
    try app.overlay.prompt.state.setText(testing.allocator, "List the users");
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("description: List the users", app.lastToast().?);
    try command.run(&app, .{ .static = .@"http.set_tags" });
    try app.overlay.prompt.state.setText(testing.allocator, "users, smoke");
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("tags: #users #smoke", app.lastToast().?);
    try testing.expectEqualStrings("# @description List the users\n# @tags users smoke", rp.request.script.?);
    try rp.url.appendSlice(testing.allocator, "https://x/users");
    try rp.commit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const block = try parse.toHttpBlock(arena.allocator(), &rp.request, "users");
    try testing.expectEqualStrings("### users\n# @description List the users\n# @tags users smoke\nGET https://x/users\n", block);
    // The pane paints the row.
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{25B8} List the users") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "#users  #smoke") != null);
    // The prompt seeded with the current tags; an empty answer clears.
    try command.run(&app, .{ .static = .@"http.set_tags" });
    try testing.expectEqualStrings("users smoke", app.overlay.prompt.state.text());
    try app.overlay.prompt.state.setText(testing.allocator, "");
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("tags: cleared", app.lastToast().?);
    try testing.expectEqualStrings("# @description List the users", rp.request.script.?);
}

test "send: an unresolved {{VAR}} is refused before the wire, naming it and where to define it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    // The user's report: no env file at all, a Jira call templated on one.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "me.http", .data = "GET {{jira}}/rest/api/3/myself\n" });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ root, "me.http" });
    defer testing.allocator.free(path);
    const id = try openFile(&app, path, false);
    const rp = app.panes.get(id).?.asRequest().?;
    try fire(&app, id);
    try testing.expect(rp.state == .failed and rp.refused);
    try testing.expectEqualStrings("unresolved {{jira}} \u{2014} no env defines it; add it to .mnml/env/<env>.env or pick an env", rp.state.failed);
    try testing.expectEqual(@as(u32, 0), app.http.sending);
    try testing.expectEqual(@as(usize, 0), app.http.handles.count());
    try testing.expect(std.mem.endsWith(u8, app.toasts.items[app.toasts.items.len - 1].text, rp.state.failed));
    // A header and a `# @path` value template too; an env that defines
    // the URL's name but not theirs names only theirs.
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "jira=http://127.0.0.1:9\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.http", .data = "# @path id = {{ISSUE}}\nGET {{jira}}/issue/:id\nAuthorization: Bearer {{TOKEN}}\n" });
    const two = try std.fs.path.join(testing.allocator, &.{ root, "two.http" });
    defer testing.allocator.free(two);
    const id2 = try openFile(&app, two, false);
    const rp2 = app.panes.get(id2).?.asRequest().?;
    try fire(&app, id2);
    try testing.expect(rp2.state == .failed and rp2.refused);
    try testing.expectEqualStrings("unresolved {{ISSUE}} {{TOKEN}} \u{2014} not defined in env dev; add them to .mnml/env/dev.env or pick an env", rp2.state.failed);
    try testing.expectEqual(@as(u32, 0), app.http.sending);
}

test "env chip: no env file claims no env; a pick whose file is gone is dropped; the picker offers + New env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try envName(&app, a)) == null);
    // A write still has somewhere to go: `dev`, which it creates.
    try testing.expectEqualStrings("dev", (try envSelection(&app, a)).name);
    const set = try loadEnv(&app, a);
    try testing.expect(set.name == null);
    // The chip's picker: `+ New env…` even with nothing to pick, and
    // picking it opens the new-env prompt.
    const cmd_http = @import("cmd_http.zig");
    try cmd_http.pickEnvCmd(&app);
    try testing.expect(app.overlay == .picker);
    const labels = app.overlay.picker.labels;
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings(cmd_http.new_env_row, labels[0]);
    try cmd_http.acceptPicker(&app, .http_env_pick, 0, cmd_http.new_env_row);
    try testing.expect(app.overlay == .prompt);
    try testing.expect(app.http.env_override == null);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // Files present: the chip shows the pick, as before.
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/staging.env", .data = "A=1\n" });
    try cmd_http.acceptPicker(&app, .http_env_pick, 0, "staging");
    try testing.expectEqualStrings("staging", (try envName(&app, a)).?);
    // The file goes: the env watch lets the pick go and the chip stops claiming it.
    try tick(&app, 0);
    try tmp.dir.deleteFile(testing.io, ".mnml/env/staging.env");
    try testing.expect((try envName(&app, a)) == null);
    try tick(&app, 0);
    try testing.expect(app.http.env_override == null);
}

test "response bar: a press at the foot of the shared bar's track lands the Response view on the body's end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    const id = try openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{");
    var k: usize = 1;
    while (k < 43) : (k += 1) try body.print(testing.allocator, "\n  \"k{d}\": {d},", .{ k, k });
    try body.appendSlice(testing.allocator, "\n}");
    const g = testing.allocator;
    try rp.setResponse(.{ .status = 200, .status_text = try g.dupe(u8, "OK"), .final_url = try g.dupe(u8, "http://x/"), .headers = try g.alloc(client.Header, 0), .body = try g.dupe(u8, body.items) });
    try app.render();
    // The bar the frame painted is the one the pane recorded.
    var track: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |h| if (h.target == .scrollbar) {
        const sb = h.target.scrollbar;
        if (sb.owner == .pane and sb.owner.pane == id and h.rect.x == rp.resp_bar.x and h.rect.y == rp.resp_bar.y) track = h.rect;
    };
    try testing.expect(rp.resp_bar.shown);
    try testing.expect(track != null);
    try testing.expectEqual(@as(u32, 0), rp.resp_view.scroll_line);
    const dispatch = @import("dispatch.zig");
    try dispatch.mouse(&app, .{ .x = track.?.x, .y = track.?.bottom() - 1, .kind = .press, .button = .left }, 1);
    try dispatch.mouse(&app, .{ .x = track.?.x, .y = track.?.bottom() - 1, .kind = .release, .button = .left }, 1);
    try testing.expectEqual(@as(u32, @intCast(rp.resp_bar.total - rp.resp_bar.h)), rp.resp_view.scroll_line);
    try dispatch.mouse(&app, .{ .x = track.?.x, .y = track.?.y, .kind = .press, .button = .left }, 1);
    try testing.expectEqual(@as(u32, 0), rp.resp_view.scroll_line);
}
