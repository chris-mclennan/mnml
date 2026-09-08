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
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const parse = @import("../http/parse.zig");
const client = @import("../http/client.zig");
const env_mod = @import("../http/env.zig");
const history = @import("../http/history.zig");
const mock = @import("../http/mock.zig");
const cookies = @import("../http/cookies.zig");
const bench_mod = @import("../http/bench.zig");
const script_mod = @import("../http/script.zig");
const request_pane = @import("request_pane.zig");
const view = @import("../ui/request_view.zig");
const editor_view = @import("../ui/editor_view.zig");
const Ui = @import("../ui/context.zig");

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
    /// The `{{VAR}}` the quick-fix menu was opened on. Owned.
    quick_fix_var: ?[]u8 = null,
    /// Lines a `.ws` file queued for a pane that is still connecting.
    ws_queue: std.ArrayListUnmanaged(struct { pane: PaneId, text: []u8 }) = .empty,

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
        self.picker_arena.deinit();
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
};

// ─── env ────────────────────────────────────────────────────────────────

/// The active env's name (`dev` when nothing chose one).
pub fn envName(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    const sel = try envSelection(app, arena);
    return sel.name;
}

pub fn envSelection(app: *App, arena: Allocator) Allocator.Error!env_mod.Selection {
    return env_mod.select(arena, app.io, app.workspace, app.http.env_override, app.env.get("MNML_ENV"), app.cfg.http.default_env);
}

/// The active env, loaded. `gpa` may be an arena.
pub fn loadEnv(app: *App, gpa: Allocator) Allocator.Error!env_mod.EnvSet {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const name = (try envName(app, scratch.allocator())) orelse env_mod.fallback_name;
    var set = try env_mod.EnvSet.load(gpa, app.io, app.workspace, name);
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
    const toks = try varTokens(app, rp, a, try envName(app, a));
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
        const rows = try varRows(app, rp, arena, try envName(app, arena));
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
    try app.clipboard.set(name, false);
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

pub fn expandWith(gpa: Allocator, io: Io, req: *const Request, set: *const env_mod.EnvSet) Allocator.Error!Request {
    var out = try req.clone(gpa);
    errdefer out.deinit(gpa);
    const url = try env_mod.expand(gpa, io, req.url, set);
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
    const id = try app.panes.add(.{ .request = rp });
    app.showPane(id);
    return id;
}

pub const OpenOptions = struct {
    /// Absolute. Duped.
    source_path: ?[]const u8 = null,
    block_name: ?[]const u8 = null,
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

/// The request pane already showing `path`'s block `block_name`.
pub fn findSource(app: *App, path: []const u8, block_name: ?[]const u8) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .request => |*rp| if (rp.source_path) |sp| {
            if (!std.mem.eql(u8, sp, path)) continue;
            const same_block = if (block_name) |b| (rp.block_name != null and std.mem.eql(u8, rp.block_name.?, b)) else rp.block_name == null;
            if (same_block) return @intCast(i);
        },
        else => {},
    };
    return null;
}

pub const OpenFileError = CommandError || parse.ParseError || error{ ReadFailed, EmptyFile };

/// Open `path` (absolute) as a request pane on its first block. The
/// error tells `App.openPath` to fall back to an editor.
pub fn openFile(app: *App, path: []const u8, preview: bool) OpenFileError!PaneId {
    if (findSource(app, path, null)) |id| {
        app.showPane(id);
        return id;
    }
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(16 << 20)) catch return error.ReadFailed;
    const list = try parse.blocks(a, text);
    if (list.len == 0) return error.EmptyFile;
    const first = list[0];
    var req = try parse.parse(app.gpa, first.text);
    errdefer req.deinit(app.gpa);
    // The leading block of a multi-block file is addressed as `null`;
    // a `### name` block by its name.
    const id = try openFromRequest(app, req, .{ .source_path = path, .block_name = first.name, .summary = first.summary, .focus_response = false, .preview = preview });
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
    summary: ?[]const u8 = null,
    /// The request pane it came from, when it did.
    pane: ?PaneId = null,
};

/// `req` is on the gpa; the paths borrow `arena`.
pub fn parseActive(app: *App, arena: Allocator) CommandError!Active {
    const gpa = app.gpa;
    if (activeRequest(app)) |rp| {
        try rp.commit();
        return .{ .req = try rp.request.clone(gpa), .source_path = rp.source_path, .block_name = rp.block_name, .summary = rp.summary, .pane = app.active };
    }
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "http: no active .http/.curl/.rest editor or Request pane", .{});
    const path = e.buf.doc.path;
    const text = e.buf.editor.bytes();
    if (path != null and !parse.isRequestPath(path.?) and !parse.looksLikeHttpFile(text) and std.mem.indexOf(u8, text, "curl") == null) {
        return app.diag.fail(app.frame.allocator(), "http: {s} is not a .http/.curl/.rest file", .{app.relPath(path.?)});
    }
    const list = try parse.blocks(arena, text);
    const line = e.buf.editor.currentLine();
    const block = parse.blockAtLine(list, line) orelse return app.diag.fail(app.frame.allocator(), "http: the buffer has no request", .{});
    const req = parse.parse(gpa, block.text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Empty => return app.diag.fail(app.frame.allocator(), "http: the block under the cursor is empty", .{}),
        error.NoUrl => return app.diag.fail(app.frame.allocator(), "http: no URL in the block under the cursor", .{}),
        error.UnterminatedQuote => return app.diag.fail(app.frame.allocator(), "http: unterminated quote in the curl command", .{}),
    };
    return .{ .req = req, .source_path = if (path) |p| try arena.dupe(u8, p) else null, .block_name = block.name, .summary = block.summary };
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
    events: *event.EventQueue,
    io: Io,
    gpa: Allocator,

    fn destroy(self: *Job, gpa: Allocator) void {
        self.req.deinit(gpa);
        if (self.label) |l| gpa.free(l);
        if (self.cookie) |c| gpa.free(c);
        gpa.destroy(self);
    }
};

pub const SpawnOptions = struct {
    label: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    stream: StreamMode = .never,
};

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
    job.* = .{ .id = app.http.nextJob(), .pane = pane, .kind = kind, .req = incoming, .stream = opts.stream, .events = &app.events, .io = app.io, .gpa = gpa };
    incoming = undefined;
    if (opts.label) |l| job.label = try gpa.dupe(u8, l);
    errdefer if (job.label) |l| gpa.free(l);
    if (opts.cookie) |c| job.cookie = try gpa.dupe(u8, c);
    errdefer if (job.cookie) |c| gpa.free(c);
    const id = job.id;
    if (opts.stream == .never) {
        app.http.group.concurrent(app.io, worker, .{job}) catch |err| {
            return app.diag.fail(app.frame.allocator(), "http: could not start the send: {s}", .{@errorName(err)});
        };
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
    return id;
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
    var outcome = client.send(gpa, io, &job.req, .{ .cookie = job.cookie, .stream = sink }) catch {
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
    var set = try loadEnv(app, a);
    set.process = &app.env;
    // Pre-request directives land on a copy: the editable fields stay
    // as written, the wire sees the `@set-*` values.
    var staged = try rp.request.clone(a);
    const script = try script_mod.parse(a, rp.request.script orelse "");
    try script_mod.applyPre(a, &staged, &set, script);
    const missing = try env_mod.unresolved(a, staged.url, &set);
    if (missing.len > 0) app.toast("http: unresolved {{{{{s}}}}} — env: {s}", .{ missing[0], set.name orelse "?" });
    const expanded = try expandWith(app.gpa, app.io, &staged, &set);
    try rp.setSentLine(expanded.method, expanded.url);
    const cookie = try @import("cmd_http.zig").cookieHeaderFor(app, a, expanded.url);
    const mode: StreamMode = if (app.http.force_stream) .always else .auto;
    app.http.force_stream = false;
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
            const facts: cmd_http.HistoryFacts = .{ .method = rp.request.method, .url = try app.frame.allocator().dupe(u8, rp.request.url), .status = st.head.status, .elapsed_ms = d.timing.total_ms };
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
    const was_streaming = rp.state == .streaming;
    const got: usize = if (rp.streaming()) |st| st.body.items.len else 0;
    try rp.setFailed(if (was_streaming) "canceled mid-stream" else "canceled");
    app.http.sending -|= 1;
    if (was_streaming) app.toast("http.cancel: stopped after {d} bytes", .{got}) else app.toast("http.cancel: stopped", .{});
}

/// D1: the result is ours to adopt or destroy. A job no pane is waiting
/// on any more (the pane re-fired, or closed) is dropped whole.
pub fn handle(app: *App, r: *JobResult) Allocator.Error!void {
    defer r.destroy(app.gpa);
    app.needs_render = true;
    switch (r.kind) {
        .send => {
            releaseHandle(app, r.job);
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
        if (try parse.splice(gpa, text, rp.block_name, block_text)) |fresh| {
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
        else => {},
    }
}

/// Pretty-print the body as JSON in place.
pub fn formatBody(app: *App, rp: *RequestPane) CommandError!void {
    const gpa = app.gpa;
    const body = std.mem.trim(u8, rp.body.items, " \t\r\n");
    if (body.len == 0) return app.diag.fail(app.frame.allocator(), "body: empty", .{});
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return app.diag.fail(app.frame.allocator(), "body: not JSON", .{});
    defer parsed.deinit();
    const pretty = std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
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
    if (active.source_path) |p| if (findSource(app, p, active.block_name)) |id| {
        const rp = app.panes.get(id).?.asRequest().?;
        try rp.load(req);
        req = undefined;
        rp.edited = false;
        app.showPane(id);
        rp.block = .response;
        return fire(app, id);
    };
    const id = try openFromRequest(app, req, .{ .source_path = active.source_path, .block_name = active.block_name, .summary = active.summary, .focus_response = true });
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
    try app.clipboard.set(curl, false);
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
    try app.clipboard.set(resp.body, false);
    app.toast("copied response body ({d} bytes)", .{resp.body.len});
}

fn copyResponseHeadersCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const text = try parse.headersToText(app.frame.allocator(), resp.headers);
    try app.clipboard.set(text, false);
    app.toast("copied {d} response header(s)", .{resp.headers.len});
}

fn copyResponseCookiesCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const set = try resp.setCookies(app.frame.allocator());
    const text = try std.mem.join(app.frame.allocator(), "\n", set);
    try app.clipboard.set(text, false);
    app.toast("copied {d} Set-Cookie header(s)", .{set.len});
}

fn copyResponseTimelineCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "no response yet", .{});
    const text = try std.fmt.allocPrint(app.frame.allocator(), "wait {d}ms · receive {d}ms · total {d}ms", .{ resp.timing.wait_ms, resp.timing.receive_ms, resp.timing.total_ms });
    try app.clipboard.set(text, false);
    app.toast("copied timeline: {s}", .{text});
}

fn copyResponseTestsCmd(app: *App) CommandError!void {
    const rp = try requireRequest(app);
    const text = try std.mem.join(app.frame.allocator(), "\n", rp.tests.items);
    try app.clipboard.set(text, false);
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
    try app.clipboard.set(f.buf.items, false);
    app.toast("copied {s} ({d} bytes)", .{ f.name, f.buf.items.len });
}

fn fieldCutCmd(app: *App) CommandError!void {
    const f = try focusedField(app);
    try app.clipboard.set(f.buf.items, false);
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
    try app.clipboard.set(f.buf.items, false);
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
    const Key = @import("../core/key.zig").Key;
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
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }}, .chunks = &chunks, .chunk_delay_ms = 60 });
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
    try testing.expect(rp.state == .failed);
    try testing.expectEqualStrings("canceled mid-stream", rp.state.failed);
    try testing.expectEqual(@as(usize, 0), app.http.handles.count());
    try testing.expectEqual(@as(u32, 0), app.http.sending);
    // A late chunk for the dead job is dropped, not appended.
    try app.tick(App.nowMs(app.io));
    try testing.expect(rp.state == .failed);
    server.stop(testing.io);

    // Chunked framing on a plain body streams too, counting bytes.
    const parts = [_][]const u8{ "{\"a\":", "1}" };
    var server2 = try mock.Server.start(testing.allocator, testing.io, .{ .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .chunks = &parts, .chunked = true, .chunk_delay_ms = 30 });
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
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "x-probe: yes\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "cookie: session=abc\r\n") != null);
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
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "content-length:") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "cookie: session=abc123; user=chris\r\n") != null);
    // The hop's cookies are in the jar, keyed by the host that set them.
    const j = try @import("cmd_http.zig").jar(&app);
    try testing.expectEqual(@as(usize, 2), j.total());
    const line = (try j.cookieHeaderFor(testing.allocator, "127.0.0.1")).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("session=abc123; user=chris", line);
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
