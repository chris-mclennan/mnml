//! The HTTP long tail: envs (pick / edit / add / delete), the history
//! and captured-traffic pickers, HAR and Postman import, the cookie
//! jar, JWT and bearer helpers, SSE parsing of a response, auth presets
//! and the Auth tab's prompts, schema validation, fan-out across envs,
//! bench, chains. Every picker and prompt these open comes back
//! through `acceptPicker` / `acceptPrompt`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Prompt = app_mod.Prompt;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");
const http = @import("http.zig");
const request_pane = @import("request_pane.zig");
const RequestPane = request_pane.RequestPane;
const parse = @import("../http/parse.zig");
const client = @import("../http/client.zig");
const env_mod = @import("../http/env.zig");
const history = @import("../http/history.zig");
const mock = @import("../http/mock.zig");
const cookies = @import("../http/cookies.zig");
const jwt = @import("../http/jwt.zig");
const sse = @import("../http/sse.zig");
const schema = @import("../http/schema.zig");
const script_mod = @import("../http/script.zig");
const import_mod = @import("../http/import.zig");
const captured = @import("../http/captured.zig");
const chain_mod = @import("../http/chain.zig");
const bench_mod = @import("../http/bench.zig");
const sources = @import("../http/sources.zig");
const hooks = @import("../core/hooks.zig");
const jobs = @import("jobs.zig");

pub const table = .{
    .@"http.edit_env" = &editEnvCmd,
    .@"http.pick_env" = &pickEnvCmd,
    .@"http.reset_env" = &resetEnvCmd,
    .@"http.delete_env_key" = &deleteEnvKeyCmd,
    .@"http.new_env" = &newEnvCmd,
    .@"http.set_env_var_value" = &setEnvVarValueCmd,
    .@"http.jump_to_env_var" = &jumpToEnvVarCmd,
    .@"http.history" = &historyCmd,
    .@"http.history_global" = &historyGlobalCmd,
    .@"http.clear_recent" = &clearRecentCmd,
    .@"http.view_captured" = &viewCapturedCmd,
    .@"http.clear_captured" = &clearCapturedCmd,
    .@"http.import_har" = &importHarCmd,
    .@"http.import_postman" = &importPostmanCmd,
    .@"http.fan_envs" = &fanEnvsCmd,
    .@"http.run_chain" = &runChainCmd,
    .@"http.new_chain" = &newChainCmd,
    .@"http.new_collection" = &newCollectionCmd,
    .@"http.new_request" = &newRequestCmd,
    .@"http.revalidate_schema" = &revalidateSchemaCmd,
    .@"http.show_schema_errors" = &showSchemaErrorsCmd,
    .@"http.bench" = &benchCmd,
    .@"http.insert_header" = &insertHeaderCmd,
    .@"http.lookup" = &lookupCmd,
    .@"http.send_streaming" = &sendStreamingCmd,
    .@"http.sync" = &syncCmd,
    .@"http.sync_check" = &syncCheckCmd,
    .@"http.toggle_sync_normalize" = &toggleSyncNormalizeCmd,
    .@"http.copy_ai_prompt" = &copyAiPromptCmd,
    .@"http.ai_build" = &aiNotYet,
    .@"http.ai_debug" = &aiNotYet,
    .@"sse.parse_active_response" = &sseParseCmd,
    .@"jwt.decode" = &jwtDecodeCmd,
    .@"auth.extract_bearer" = &extractBearerCmd,
    .@"auth.save_preset" = &authSavePresetCmd,
    .@"auth.apply_preset" = &authApplyPresetCmd,
    .@"cookies.show" = &cookiesShowCmd,
    .@"cookies.delete" = &cookiesDeleteCmd,
    .@"cookies.clear" = &cookiesClearCmd,
    .@"cookies.persist" = &cookiesPersistCmd,
    .@"cookies.normalize_clipboard" = &cookiesNormalizeCmd,
};

pub const AuthKind = enum { bearer, basic, api_key };

// ─── the jar ────────────────────────────────────────────────────────────

pub fn jar(app: *App) Allocator.Error!*cookies.Jar {
    if (app.http.jar == null) app.http.jar = try cookies.Jar.load(app.gpa, app.io, app.workspace);
    return &app.http.jar.?;
}

/// The `Cookie` header the jar has for `url`'s host, on `arena`.
pub fn cookieHeaderFor(app: *App, arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    const host = cookies.hostOf(url) orelse return null;
    const j = try jar(app);
    const secure = std.ascii.startsWithIgnoreCase(std.mem.trim(u8, url, " \t"), "https://");
    return j.cookieHeaderFor(arena, host, cookies.pathOf(url), secure, cookies.nowMs(app.io));
}

fn saveJar(app: *App) void {
    const j = jar(app) catch return;
    const path = j.save(app.gpa, app.io, app.workspace) catch return;
    app.gpa.free(path);
}

// ─── after a response ───────────────────────────────────────────────────

/// Cookies into the jar (keyed by the host that answered), the schema
/// sidecar checked, the Tests tab filled.
pub fn afterResponse(app: *App, id: PaneId, rp: *RequestPane) Allocator.Error!void {
    const resp = rp.response() orelse return;
    // A redirect hop's cookies belong to the host that set them, the
    // final response's to the host it came from.
    var jarred = false;
    const now = cookies.nowMs(app.io);
    for (resp.hop_cookies) |c| {
        try (try jar(app)).recordSetCookie(c.host, c.path, c.value, now);
        jarred = true;
    }
    if (cookies.hostOf(resp.final_url)) |host| {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const set = try resp.setCookies(arena.allocator());
        for (set) |c| try (try jar(app)).recordSetCookie(host, cookies.pathOf(resp.final_url), c, now);
        jarred = jarred or set.len > 0;
    }
    if (jarred) saveJar(app);
    rp.clearTests();
    try validateSchema(app, rp, false);
    try runScript(app, rp);
    try emitResponseHook(app, id, rp);
}

// ─── the http_request / http_response hooks ─────────────────────────────
// Order, before a send: the block's `@set-*` directives, the `{{VAR}}`
// expansion, then `http_request` — a subscriber sees the wire form and
// what it returns goes out as-is (no further expansion). After a
// response: cookies into the jar, the schema sidecar, `@assert` /
// `@capture`, then `http_response` — so a Lua subscriber can read a
// variable a capture just wrote, and `mnml.http.set_var` lands after the
// captures. Only a request pane's sends fire them (not chains, fan-out,
// bench or the CLI); a replayed mock fires `http_response` too.

/// `http_request` on the expanded request about to go out; the
/// subscribers' rewrite is applied to `req` in place. The pane keeps
/// the final headers for its Timeline tab.
pub fn beforeSend(app: *App, id: PaneId, rp: *RequestPane, req: *parse.Request, env_name: ?[]const u8) Allocator.Error!void {
    if (app.hooks.count(.http_request) > 0) {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const hs = try a.alloc(hooks.HttpHeader, req.headers.items.len);
        for (req.headers.items, 0..) |h, i| hs[i] = .{ .name = h.name, .value = h.value };
        var rw = hooks.HttpRewrite.init(app.gpa);
        defer rw.deinit();
        app.http.hook = .request;
        defer app.http.hook = .none;
        app.hooks.emit(app, .{ .http_request = .{ .pane = id, .method = req.method, .url = req.url, .headers = hs, .body = req.body, .env = env_name, .rewrite = &rw } });
        try applyRewrite(app.gpa, req, &rw);
    }
    try rp.setSentHeaders(req.headers.items);
}

fn applyRewrite(gpa: Allocator, req: *parse.Request, rw: *const hooks.HttpRewrite) Allocator.Error!void {
    if (rw.method) |m| try req.setMethod(gpa, m);
    if (rw.url) |u| try req.setUrl(gpa, u);
    if (rw.headers) |hs| {
        req.clearHeaders(gpa);
        for (hs.items) |h| try req.addHeader(gpa, h.name, h.value);
    }
    if (rw.clear_body) try req.setBody(gpa, null) else if (rw.body) |b| try req.setBody(gpa, b);
}

/// The `http_response` payload for `resp`: the body cut at
/// `hooks.http_body_cap` (flagged), the headers as borrowed pairs.
pub fn responseHookArgs(arena: Allocator, pane: PaneId, resp: *const client.Response) Allocator.Error!hooks.HttpResponseArgs {
    const hs = try arena.alloc(hooks.HttpHeader, resp.headers.len);
    for (resp.headers, 0..) |h, i| hs[i] = .{ .name = h.name, .value = h.value };
    const cut = resp.body.len > hooks.http_body_cap;
    return .{
        .pane = pane,
        .status = resp.status,
        .headers = hs,
        .body = if (cut) resp.body[0..hooks.http_body_cap] else resp.body,
        .body_truncated = cut or resp.truncated,
        .timing_ms = resp.timing.total_ms,
    };
}

/// `http_response` for the pane's Done response, then any send a
/// subscriber asked for through `mnml.http.send`.
fn emitResponseHook(app: *App, id: PaneId, rp: *RequestPane) Allocator.Error!void {
    if (app.hooks.count(.http_response) == 0) return;
    const resp = rp.response() orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const args = try responseHookArgs(arena.allocator(), id, resp);
    app.http.hook = .response;
    app.http.resend_pane = null;
    app.hooks.emit(app, .{ .http_response = args });
    app.http.hook = .none;
    if (app.http.resend_pane) |again| {
        app.http.resend_pane = null;
        http.fire(app, again) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
        };
    }
}

/// The block's `@assert` / `@capture` lines against the Done response:
/// one Tests row each, a summary toast, captures written into the
/// active env.
fn runScript(app: *App, rp: *RequestPane) Allocator.Error!void {
    const resp = rp.response() orelse return;
    const text = rp.request.script orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try script_mod.parse(a, text);
    if (s.asserts.len == 0 and s.captures.len == 0) return;
    var passed: usize = 0;
    var failed: usize = 0;
    for (try script_mod.runAsserts(a, s, resp.status, resp.headers, resp.body)) |r| {
        if (r.ok) {
            passed += 1;
            try rp.addTest("✓ {s}", .{r.label});
        } else {
            failed += 1;
            if (r.detail.len > 0) try rp.addTest("✗ {s} — {s}", .{ r.label, r.detail }) else try rp.addTest("✗ {s}", .{r.label});
        }
    }
    for (try script_mod.runCaptures(a, s, resp.status, resp.headers, resp.body)) |c| {
        if (c.value) |v| {
            try rp.addTest("↳ {s} = {s}", .{ c.name, std.mem.sliceTo(v, '\n') });
            try writeEnvVar(app, c.name, v);
        } else try rp.addTest("✗ capture {s}: nothing at its source", .{c.name});
    }
    if (s.asserts.len > 0) {
        if (failed == 0) app.toast("tests: {d} passed", .{passed}) else try app.toastLevel(.err, "tests: {d} passed, {d} failed", .{ passed, failed });
    }
}

/// Run the sidecar validation into `rp.tests`; `announce` toasts.
fn validateSchema(app: *App, rp: *RequestPane, announce: bool) Allocator.Error!void {
    const resp = rp.response() orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const source = rp.source_path orelse {
        if (announce) app.toast("schema: this pane has no source file to find a sidecar beside", .{});
        return;
    };
    const sidecar = (try schema.resolveSidecar(a, app.io, source)) orelse {
        if (announce) app.toast("schema: no <name>.schema.json beside {s}", .{app.relPath(source)});
        return;
    };
    const result = try schema.validateFile(a, app.io, resp.body, sidecar);
    // Replace any earlier schema lines.
    var i: usize = 0;
    while (i < rp.tests.items.len) {
        if (std.mem.indexOf(u8, rp.tests.items[i], "schema") != null) {
            app.gpa.free(rp.tests.orderedRemove(i));
        } else i += 1;
    }
    const summary = try result.summary(a);
    try rp.tests.insert(app.gpa, 0, try app.gpa.dupe(u8, summary));
    for (result.errors) |e| try rp.addTest("  {s}", .{e});
    if (announce) switch (result.status) {
        .valid => app.toast("✓ schema re-validated: valid", .{}),
        .invalid => app.toast("✗ schema re-validated: {d} error(s)", .{result.errors.len}),
        else => app.toast("schema re-validated: {s}", .{summary}),
    };
}

fn revalidateSchemaCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    if (rp.response() == null) return app.diag.fail(app.frame.allocator(), "schema: no Done response on this pane", .{});
    try validateSchema(app, rp, true);
}

fn showSchemaErrorsCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    if (rp.tests.items.len == 0) return app.diag.fail(app.frame.allocator(), "schema: nothing validated yet", .{});
    const text = try std.mem.join(app.frame.allocator(), "\n", rp.tests.items);
    const id = try app.openScratch();
    const e = app.panes.editor(id).?;
    e.buf.editor.setText(text) catch return error.OutOfMemory;
    e.buf.markSaved() catch return error.OutOfMemory;
}

/// What a finished send tells history, whether it landed whole or
/// streamed in.
pub const HistoryFacts = struct { method: []const u8, url: []const u8, status: ?u16, elapsed_ms: u64 };

/// One history line per finished send.
pub fn recordHistory(app: *App, r: HistoryFacts, rp: *RequestPane) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The pane's headers are the raw (unexpanded) ones; the job's url is expanded.
    var hs: std.ArrayListUnmanaged(parse.Header) = .empty;
    for (rp.request.headers.items) |h| {
        const shown = history.headerValueForHistory(h.name, h.value, h.value);
        try hs.append(a, .{ .name = h.name, .value = @constCast(shown) });
    }
    const global = if (app.data_root.len > 0) try std.fs.path.join(a, &.{ app.data_root, "history-global.jsonl" }) else null;
    const resp = rp.response();
    try history.append(app.gpa, app.io, app.workspace, global, .{
        .method = r.method,
        .url = r.url,
        .status = r.status orelse (if (resp) |x| x.status else null),
        .duration_ms = r.elapsed_ms,
        .body_bytes = if (resp) |x| x.body.len else null,
        .err = if (rp.state == .failed) rp.state.failed else null,
        .headers = hs.items,
        .request_body = rp.request.body,
        // The URL as written and the env it resolved against: a re-fire
        // resolves ALL of it against that env, never an expanded URL
        // with another env's headers.
        .url_template = rp.request.url,
        .env = rp.sent_env,
    });
}

// ─── envs ───────────────────────────────────────────────────────────────

fn activeEnvName(app: *App, arena: Allocator) Allocator.Error!env_mod.Selection {
    return http.envSelection(app, arena);
}

/// `Env vars · <name>.env`: `+ Add new variable…` first, then every key
/// with its value as the detail.
fn editEnvCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sel = try activeEnvName(app, a);
    var set = try env_mod.EnvSet.load(a, app.io, app.workspace, sel.name);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    try labels.append(gpa, try gpa.dupe(u8, "+ Add new variable…"));
    try details.append(gpa, try gpa.dupe(u8, ""));
    // Sorted keys read better than file order.
    const keys = try a.dupe([]const u8, set.vars.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (keys) |k| {
        try labels.append(gpa, try gpa.dupe(u8, k));
        const v = set.get(k) orelse "";
        try details.append(gpa, try gpa.dupe(u8, if (v.len > 48) v[0..46] else v));
    }
    const title = try std.fmt.allocPrint(gpa, "Env vars · {s}.env", .{sel.name});
    errdefer gpa.free(title);
    if (app.http.picker_title) |t| gpa.free(t);
    app.http.picker_title = title;
    try cmd_picker.openPickerWith(app, title, .http_env_vars, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

pub fn pickEnvCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const names = try env_mod.listNames(arena.allocator(), app.io, app.workspace);
    if (names.len == 0) return app.diag.fail(app.frame.allocator(), "http.pick_env: no env files in .mnml/env or .rqst/env (:http.new_env creates one)", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (names) |n| try labels.append(gpa, try gpa.dupe(u8, n));
    try cmd_picker.openPicker(app, "Pick env", .http_env_pick, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn resetEnvCmd(app: *App) CommandError!void {
    if (app.http.env_override) |e| app.gpa.free(e);
    app.http.env_override = null;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const sel = try activeEnvName(app, arena.allocator());
    app.toast("env: override cleared — active is {s}", .{sel.name});
}

fn deleteEnvKeyCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sel = try activeEnvName(app, a);
    var set = try env_mod.EnvSet.load(a, app.io, app.workspace, sel.name);
    if (set.vars.count() == 0) return app.diag.fail(app.frame.allocator(), "env: {s}.env has no keys", .{sel.name});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (set.vars.keys()) |k| try labels.append(gpa, try gpa.dupe(u8, k));
    const title = try std.fmt.allocPrint(gpa, "Delete env var · {s}.env", .{sel.name});
    errdefer gpa.free(title);
    if (app.http.picker_title) |t| gpa.free(t);
    app.http.picker_title = title;
    try cmd_picker.openPicker(app, title, .http_env_delete, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn newEnvCmd(app: *App) CommandError!void {
    try openPrompt(app, "New env name (writes .mnml/env/<name>.env)", .http_new_env);
}

pub fn openEnvValuePrompt(app: *App, key: []const u8, current: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const owned_key = try gpa.dupe(u8, key);
    errdefer gpa.free(owned_key);
    const title = try std.fmt.allocPrint(gpa, "Value for {s}:", .{key});
    errdefer gpa.free(title);
    var state = Prompt.init(gpa, title);
    errdefer Prompt.deinit(&state, gpa);
    try state.setText(gpa, current);
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .http_env_edit_value = owned_key }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn setEnvVarValueCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    try http.varRowAction(app, rp, rp.row_cursor);
    if (app.overlay != .prompt) return app.diag.fail(app.frame.allocator(), "set_env_var_value: no {{VAR}} reference on the active pane", .{});
}

fn jumpToEnvVarCmd(app: *App) CommandError!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // A `{{VAR}}` in hand (the quick-fix menu, the caret, the Vars row)
    // lands on its line; otherwise the file opens as it is.
    if (http.takeQuickFix(app)) |v| {
        defer app.gpa.free(v);
        return http.jumpToVarDef(app, try a.dupe(u8, v));
    }
    if (http.activeRequest(app)) |rp| if (try rp.varAtCaret(a)) |name| return http.jumpToVarDef(app, name);
    const sel = try activeEnvName(app, a);
    for ([_][]const u8{ ".mnml", ".rqst" }) |sub| {
        const path = try env_mod.envPath(a, app.workspace, sub, sel.name);
        Io.Dir.cwd().access(app.io, path, .{}) catch continue;
        const copy = try app.frame.allocator().dupe(u8, path);
        _ = app.openEditor(copy) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return app.diag.fail(app.frame.allocator(), "env: cannot open {s}", .{app.relPath(path)}),
        };
        return;
    }
    return app.diag.fail(app.frame.allocator(), "env: no {s}.env in .mnml/env or .rqst/env", .{sel.name});
}

/// Write `key=value` into the active env (the file that holds the key,
/// else `.mnml/env/<name>.env`); a refused write says why in a toast.
fn writeEnvVar(app: *App, key: []const u8, value: []const u8) Allocator.Error!void {
    setEnvVar(app, key, value) catch |err| switch (err) {
        error.InvalidValue => app.toast("env: a value cannot contain newlines", .{}),
        error.InvalidKey => app.toast("env: key must be [A-Za-z0-9_]", .{}),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => app.toast("env: write failed: {s}", .{app.diag.msg orelse "?"}),
    };
}

pub const EnvWriteError = Allocator.Error || error{ InvalidKey, InvalidValue, WriteFailed };

/// `writeEnvVar` for a caller that wants the refusal back
/// (`mnml.http.set_var`): the file is written and toasted, or the
/// error names what was wrong.
pub fn setEnvVar(app: *App, key: []const u8, value: []const u8) EnvWriteError!void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const sel = try activeEnvName(app, arena.allocator());
    if (sel.is_fallback) app.toast("env: no active env — using dev.env (set `[http] default_env` or MNML_ENV)", .{});
    const up = env_mod.upsert(app.gpa, app.io, app.workspace, sel.name, key, value) catch |err| switch (err) {
        error.InvalidValue, error.InvalidKey, error.OutOfMemory => |e| return e,
        else => {
            app.diag.fail(app.frame.allocator(), "{s}", .{@errorName(err)}) catch {};
            return error.WriteFailed;
        },
    };
    defer app.gpa.free(up.path);
    http.restampEnvWatch(app);
    app.toast("env: wrote {s}={s} → {s}", .{ key, value, app.relPath(up.path) });
    app.needs_render = true;
}

// ─── history / captured ─────────────────────────────────────────────────

fn openHistoryPicker(app: *App, path: []const u8, title: []const u8, global: bool) CommandError!void {
    const gpa = app.gpa;
    _ = app.http.picker_arena.reset(.retain_capacity);
    app.http.captured_curls = &.{};
    const a = app.http.picker_arena.allocator();
    const rows = try history.tail(a, app.io, path, 100);
    if (rows.len == 0) return app.diag.fail(app.frame.allocator(), "{s}: no history yet at {s}", .{ if (global) "http.history_global" else "http.history", app.relPath(path) });
    // Newest first: the picker's row i is rows[len-1-i].
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        const r = rows[i];
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.method, history.shortUrl(r.url) }));
        const ws_prefix: []const u8 = if (global) (r.workspace orelse "?") else "";
        const sep: []const u8 = if (global) " · " else "";
        const detail = if (r.status) |s| (if (r.duration_ms) |d| try std.fmt.allocPrint(gpa, "{s}{s}{d} · {d}ms", .{ ws_prefix, sep, s, d }) else try std.fmt.allocPrint(gpa, "{s}{s}{d}", .{ ws_prefix, sep, s })) else (if (r.duration_ms) |d| try std.fmt.allocPrint(gpa, "{s}{s}FAILED · {d}ms", .{ ws_prefix, sep, d }) else try std.fmt.allocPrint(gpa, "{s}{s}FAILED", .{ ws_prefix, sep }));
        try details.append(gpa, detail);
    }
    app.http.history_rows = rows;
    try cmd_picker.openPickerWith(app, title, .http_history, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

fn historyCmd(app: *App) CommandError!void {
    const path = try history.historyPath(app.frame.allocator(), app.workspace);
    return openHistoryPicker(app, path, "HTTP history", false);
}

fn historyGlobalCmd(app: *App) CommandError!void {
    if (app.data_root.len == 0) return app.diag.fail(app.frame.allocator(), "http.history_global: no data root (HOME unset)", .{});
    const path = try std.fs.path.join(app.frame.allocator(), &.{ app.data_root, "history-global.jsonl" });
    return openHistoryPicker(app, path, "HTTP history · all workspaces", true);
}

fn clearRecentCmd(app: *App) CommandError!void {
    const path = try history.historyPath(app.frame.allocator(), app.workspace);
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "" }) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return app.diag.fail(app.frame.allocator(), "clear_recent: {s}", .{@errorName(err)}),
    };
    app.toast("http: history cleared", .{});
}

fn viewCapturedCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    _ = app.http.picker_arena.reset(.retain_capacity);
    app.http.history_rows = &.{};
    const a = app.http.picker_arena.allocator();
    const rows = try captured.load(a, app.io, app.workspace);
    if (rows.len == 0) {
        const path = try captured.logPath(app.frame.allocator(), app.workspace);
        return app.diag.fail(app.frame.allocator(), "http.view_captured: nothing captured yet at {s}", .{app.relPath(path)});
    }
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    var curls: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rows) |r| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.method, history.shortUrl(r.url) }));
        try details.append(gpa, if (r.body) |b| try std.fmt.allocPrint(gpa, "(body: {d} bytes)", .{b.len}) else try gpa.dupe(u8, ""));
        var req = try captured.toRequest(a, r);
        try curls.append(a, try parse.toCurl(a, &req));
    }
    app.http.captured_curls = curls.items;
    try cmd_picker.openPickerWith(app, "Captured requests", .http_captured, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

fn clearCapturedCmd(app: *App) CommandError!void {
    const path = try captured.logPath(app.frame.allocator(), app.workspace);
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "" }) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return app.diag.fail(app.frame.allocator(), "clear_captured: {s}", .{@errorName(err)}),
    };
    app.toast("http: captured log cleared", .{});
}

// ─── imports ────────────────────────────────────────────────────────────

fn writeStubs(app: *App, imported: import_mod.Import) CommandError!usize {
    const arena = app.frame.allocator();
    const dir = try std.fs.path.join(arena, &.{ app.workspace, ".rqst", "captured", imported.dir });
    Io.Dir.cwd().createDirPath(app.io, dir) catch |err| return app.diag.fail(arena, "import: mkdir {s}: {s}", .{ app.relPath(dir), @errorName(err) });
    var n: usize = 0;
    for (imported.stubs) |s| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.curl", .{ dir, s.name });
        const text = try std.fmt.allocPrint(arena, "{s}\n", .{s.curl});
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = text }) catch continue;
        n += 1;
    }
    return n;
}

fn importHarCmd(app: *App) CommandError!void {
    const raw = app.clipboard.text();
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return app.diag.fail(app.frame.allocator(), "http.import_har: clipboard is empty", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const imported = import_mod.har(arena.allocator(), raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotJson => return app.diag.fail(app.frame.allocator(), "har: not valid JSON", .{}),
        else => return app.diag.fail(app.frame.allocator(), "har: missing log.entries (not a HAR file?)", .{}),
    };
    const n = try writeStubs(app, imported);
    app.toast("har: wrote {d} curls → .rqst/captured/{s}/", .{ n, imported.dir });
}

fn importPostmanCmd(app: *App) CommandError!void {
    const raw = app.clipboard.text();
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return app.diag.fail(app.frame.allocator(), "http.import_postman: clipboard is empty", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const imported = import_mod.postman(arena.allocator(), raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotJson => return app.diag.fail(app.frame.allocator(), "postman: not valid JSON", .{}),
        else => return app.diag.fail(app.frame.allocator(), "postman: no item[] (not a v2.1 collection?)", .{}),
    };
    const n = try writeStubs(app, imported);
    // The collection's variables become an env of their own, picked
    // like any other; an existing file is the user's and is kept.
    var env_note: []const u8 = "";
    if (imported.vars.len > 0) {
        const fa = app.frame.allocator();
        const env_path = try std.fs.path.join(fa, &.{ app.workspace, ".mnml", "env", try std.fmt.allocPrint(fa, "{s}.env", .{imported.dir}) });
        if (Io.Dir.cwd().access(app.io, env_path, .{})) |_| {
            env_note = try std.fmt.allocPrint(fa, " · {s}.env exists, kept", .{imported.dir});
        } else |_| {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            for (imported.vars) |v| if (env_mod.isValidName(v.key)) try text.print(fa, "{s}={s}\n", .{ v.key, v.value });
            if (std.fs.path.dirname(env_path)) |d| Io.Dir.cwd().createDirPath(app.io, d) catch {};
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = env_path, .data = text.items }) catch {};
            env_note = try std.fmt.allocPrint(fa, " · {d} variables → env {s}", .{ imported.vars.len, imported.dir });
        }
    }
    const auth_note: []const u8 = if (imported.unimported_auth > 0) try std.fmt.allocPrint(app.frame.allocator(), " · {d} with an auth type not imported", .{imported.unimported_auth}) else "";
    app.toast("postman: wrote {d} curls → .rqst/captured/{s}/{s}{s}", .{ n, imported.dir, env_note, auth_note });
}

// ─── fan out ────────────────────────────────────────────────────────────

fn fanEnvsCmd(app: *App) CommandError!void {
    if (app.http.fan != null) return app.diag.fail(app.frame.allocator(), "http.fan_envs already running", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var active = http.parseActive(app, a) catch return app.diag.fail(app.frame.allocator(), "http.fan_envs: no active .http/.curl/.rest editor", .{});
    defer active.req.deinit(app.gpa);
    const names = try env_mod.listNames(a, app.io, app.workspace);
    if (names.len == 0) return app.diag.fail(app.frame.allocator(), "http.fan_envs: no env files found in .mnml/env or .rqst/env", .{});
    app.http.fan = .{ .total = names.len, .started_ms = app.now_ms };
    errdefer {
        app.http.fan.?.deinit(app.gpa);
        app.http.fan = null;
    }
    try app.http.fan.?.table.appendSlice(app.gpa, "env\tstatus\tms\n");
    for (names) |name| {
        var set = try env_mod.EnvSet.load(a, app.io, app.workspace, name);
        set.process = &app.env;
        const expanded = try http.expandWith(app.gpa, app.io, &active.req, &set);
        _ = try http.spawn(app, null, .fan_env, expanded, name, null);
    }
    app.toast("fan_envs: firing {d} env(s)…", .{names.len});
}

pub fn onFanResult(app: *App, r: *client.JobResult) Allocator.Error!void {
    const gpa = app.gpa;
    const fan = &(app.http.fan orelse return);
    const name = r.label orelse "?";
    const line = switch (r.outcome) {
        .ok => |resp| blk: {
            if (resp.status >= 200 and resp.status < 300) fan.ok += 1;
            try appendFmt(gpa, &fan.table, "{s}\t{d}\t{d}\n", .{ name, resp.status, r.elapsed_ms });
            break :blk try std.fmt.allocPrint(gpa, "{s}: {d} ({d}ms)", .{ name, resp.status, r.elapsed_ms });
        },
        .err => |e| blk: {
            try appendFmt(gpa, &fan.table, "{s}\tERR\t{s}\n", .{ name, e });
            break :blk try std.fmt.allocPrint(gpa, "{s}: ERR ({s})", .{ name, e });
        },
        .moved => try gpa.dupe(u8, name),
    };
    try fan.lines.append(gpa, line);
    fan.done += 1;
    if (fan.done < fan.total) return;
    const summary = try std.mem.join(app.frame.allocator(), " · ", fan.lines.items);
    try app.clipboard.set(fan.table.items, false);
    app.toast("fan_envs: {d}/{d} OK in {d}ms · {s} · (full table → clipboard)", .{ fan.ok, fan.total, app.now_ms - fan.started_ms, summary });
    fan.deinit(gpa);
    app.http.fan = null;
}

// ─── bench / chain / lookup results ─────────────────────────────────────

fn benchCmd(app: *App) CommandError!void {
    if (app.http.bench != null) return app.diag.fail(app.frame.allocator(), "http.bench already running", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var active = try http.parseActive(app, arena.allocator());
    defer active.req.deinit(app.gpa);
    const expanded = try http.expand(app, app.gpa, &active.req);
    var owned = expanded;
    errdefer owned.deinit(app.gpa);
    const n: u32 = 10;
    const conc: u32 = 10;
    app.http.bench = .{ .total = n, .started_ms = app.now_ms };
    const url_copy = try app.gpa.dupe(u8, owned.url);
    app.http.bench.?.url = url_copy;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const copy = try owned.clone(app.gpa);
        _ = try http.spawn(app, null, .bench, copy, null, null);
    }
    owned.deinit(app.gpa);
    _ = try jobs.begin(app, .{ .kind = .http, .key = http.bench_job_key, .label = try std.fmt.allocPrint(app.frame.allocator(), "bench {s} ×{d}", .{ url_copy, n }) });
    app.toast("http.bench: firing {d}× ({d} concurrent)…", .{ n, conc });
}

pub fn onJobResult(app: *App, r: *client.JobResult) Allocator.Error!void {
    const gpa = app.gpa;
    switch (r.kind) {
        .bench => {
            const b = &(app.http.bench orelse return);
            switch (r.outcome) {
                .ok => |resp| try b.samples.append(gpa, .{ .ms = r.elapsed_ms, .status = resp.status }),
                .err => |e| {
                    if (b.errors.items.len < 3) try b.errors.append(gpa, try gpa.dupe(u8, e));
                    try b.samples.append(gpa, .{ .ms = r.elapsed_ms, .status = 0 });
                },
                .moved => {},
            }
            jobs.progress(app, .http, http.bench_job_key, try std.fmt.allocPrint(app.frame.allocator(), "{d}/{d}", .{ b.samples.items.len, b.total }));
            if (b.samples.items.len < b.total) return;
            const report = try bench_mod.report(app.frame.allocator(), b.url, b.samples.items, b.errors.items, @intCast(@max(app.now_ms - b.started_ms, 0)));
            try app.clipboard.set(report, false);
            const stats = bench_mod.stats(b.samples.items);
            app.toast("bench: {d}× · p50 {d}ms · p95 {d}ms · max {d}ms · {d} ok · (full trace → clipboard)", .{ b.total, stats.p50, stats.p95, stats.max, stats.ok });
            const words = try std.fmt.allocPrint(app.frame.allocator(), "{d} of {d} ok · p50 {d}ms", .{ stats.ok, b.total, stats.p50 });
            jobs.endKeyed(app, .http, http.bench_job_key, if (stats.ok < b.total) jobs.Outcome.fail(words) else jobs.Outcome.done(words));
            b.deinit(gpa);
            app.http.bench = null;
        },
        .chain, .lookup => {
            if (r.kind == .chain) {
                const key = if (std.mem.eql(u8, r.method, "CHAIN")) http.chain_job_key else http.sync_job_key;
                jobs.endKeyed(app, .http, key, switch (r.outcome) {
                    .err => |e| jobs.Outcome.fail(e),
                    else => .{},
                });
            }
            app.http.chain_running = false;
            app.http.sync_running = false;
            if (r.label) |trace| {
                const id = try app.openScratch();
                const e = app.panes.editor(id).?;
                e.buf.editor.setText(trace) catch return error.OutOfMemory;
                e.buf.markSaved() catch return error.OutOfMemory;
            }
            switch (r.outcome) {
                .err => |e| app.toast("{s}: {s}", .{ r.method, e }),
                else => app.toast("{s}: done", .{r.method}),
            }
        },
        else => {},
    }
}

fn chainsDir(app: *App, arena: Allocator) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ app.workspace, ".mnml", "chains" });
}

fn runChainCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try chainsDir(app, a);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    if (Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".chain.json")) continue;
            try names.append(a, try a.dupe(u8, e.name[0 .. e.name.len - ".chain.json".len]));
        }
    } else |_| {}
    if (names.items.len == 0) return app.diag.fail(app.frame.allocator(), "http.run_chain: no chains at {s}", .{dir_path});
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (names.items) |n| {
        try labels.append(gpa, try gpa.dupe(u8, n));
        const path = try std.fmt.allocPrint(a, "{s}/{s}.chain.json", .{ dir_path, n });
        const text = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(1 << 20)) catch "";
        const steps = chain_mod.parse(a, text) catch null;
        try details.append(gpa, if (steps) |s| try std.fmt.allocPrint(gpa, "{d} step(s)", .{s.steps.len}) else try gpa.dupe(u8, "(unparseable)"));
    }
    try cmd_picker.openPickerWith(app, "Run chain", .http_chains, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

pub fn runChainNamed(app: *App, name: []const u8) CommandError!void {
    if (app.http.chain_running) return app.diag.fail(app.frame.allocator(), "http.run_chain: a chain is already running", .{});
    const arena = app.frame.allocator();
    const dir_path = try chainsDir(app, arena);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.chain.json", .{ dir_path, name });
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const sel = try activeEnvName(app, scratch.allocator());
    const env_name = try app.gpa.dupe(u8, sel.name);
    errdefer app.gpa.free(env_name);
    const path_owned = try app.gpa.dupe(u8, path);
    errdefer app.gpa.free(path_owned);
    const ws = try app.gpa.dupe(u8, app.workspace);
    errdefer app.gpa.free(ws);
    app.http.chain_running = true;
    app.http.group.concurrent(app.io, chainWorker, .{ &app.events, app.io, app.gpa, path_owned, ws, env_name }) catch |err| {
        app.http.chain_running = false;
        return app.diag.fail(arena, "http.run_chain: could not start: {s}", .{@errorName(err)});
    };
    _ = try jobs.begin(app, .{ .kind = .http, .key = http.chain_job_key, .label = try std.fmt.allocPrint(arena, "chain {s}", .{name}) });
    app.toast("chain: running {s}…", .{name});
}

fn chainWorker(events: *@import("../core/event.zig").EventQueue, io: Io, gpa: Allocator, path: []u8, workspace: []u8, env_name: []u8) Io.Cancelable!void {
    defer gpa.free(path);
    defer gpa.free(workspace);
    defer gpa.free(env_name);
    var out = chain_mod.run(gpa, io, path, workspace, env_name) catch |err| {
        const msg = gpa.dupe(u8, @errorName(err)) catch return;
        events.post(io, .{ .err = .{ .source = .http, .msg = msg } });
        return;
    };
    defer out.deinit(gpa);
    const r = client.JobResult.create(gpa, 0, null, .chain, "CHAIN", path, if (out.ok) .moved else .{ .err = gpa.dupe(u8, out.err orelse "failed") catch return }) catch return;
    r.label = gpa.dupe(u8, out.trace) catch null;
    events.post(io, .{ .http = r });
}

/// `http.sync` / `http.sync_check` on a worker; the trace opens as a scratch.
fn startSync(app: *App, check_only: bool) CommandError!void {
    if (app.http.sync_running) return app.diag.fail(app.frame.allocator(), "{s} already running", .{if (check_only) "http.sync_check" else "http.sync"});
    const ws = try app.gpa.dupe(u8, app.workspace);
    errdefer app.gpa.free(ws);
    app.http.sync_running = true;
    app.http.group.concurrent(app.io, syncWorker, .{ &app.events, app.io, app.gpa, ws, check_only, app.http.sync_normalize }) catch |err| {
        app.http.sync_running = false;
        return app.diag.fail(app.frame.allocator(), "http.sync: could not start: {s}", .{@errorName(err)});
    };
    _ = try jobs.begin(app, .{ .kind = .http, .key = http.sync_job_key, .label = if (check_only) "sources sync (check)" else "sources sync" });
    app.toast("{s}: running…", .{if (check_only) "http.sync_check" else "http.sync"});
}

fn syncWorker(events: *@import("../core/event.zig").EventQueue, io: Io, gpa: Allocator, ws: []u8, check_only: bool, normalize: bool) Io.Cancelable!void {
    defer gpa.free(ws);
    const label: []const u8 = if (check_only) "http.sync_check" else "http.sync";
    const trace = (if (check_only) sources.check(gpa, io, ws, normalize) else sources.sync(gpa, io, ws, normalize)) catch |err| {
        const msg = gpa.dupe(u8, switch (err) {
            error.NoSourcesFile => "no sources.json at .mnml/ or .rqst/ (list swagger sources there)",
            error.NoSources => "sources.json is empty",
            else => @errorName(err),
        }) catch return;
        const r = client.JobResult.create(gpa, 0, null, .chain, label, ws, .{ .err = msg }) catch return;
        events.post(io, .{ .http = r });
        return;
    };
    const r = client.JobResult.create(gpa, 0, null, .chain, label, ws, .moved) catch {
        gpa.free(trace);
        return;
    };
    r.label = trace;
    events.post(io, .{ .http = r });
}

fn syncCmd(app: *App) CommandError!void {
    return startSync(app, false);
}

fn syncCheckCmd(app: *App) CommandError!void {
    return startSync(app, true);
}

fn toggleSyncNormalizeCmd(app: *App) CommandError!void {
    app.http.sync_normalize = !app.http.sync_normalize;
    app.toast("sync normalize: {s} ({{{{$isoTimestamp}}}} / {{{{$uuid}}}} substitution)", .{if (app.http.sync_normalize) "on" else "off"});
}

fn newChainCmd(app: *App) CommandError!void {
    try openPrompt(app, "New chain name (writes .mnml/chains/<name>.chain.json)", .http_new_chain);
}

fn newCollectionCmd(app: *App) CommandError!void {
    try openPrompt(app, "New collection name (creates .mnml/collections/<name>/)", .http_new_collection);
}

fn newRequestCmd(app: *App) CommandError!void {
    try openPrompt(app, "New request path (e.g. requests/users.http)", .http_new_request);
}

fn lookupCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try std.fs.path.join(a, &.{ app.workspace, ".rqst", "lookups" });
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    if (Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |e| {
            if (e.kind != .file or !parse.isRequestPath(e.name)) continue;
            try labels.append(gpa, try gpa.dupe(u8, e.name));
        }
    } else |_| {}
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "http.lookup: no .curl files in .rqst/lookups/", .{});
    try cmd_picker.openPicker(app, "Lookup file", .http_lookup_file, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn sendStreamingCmd(app: *App) CommandError!void {
    // `fire` streams an event-stream or chunked body on its own; this
    // asks for the progressive reader whatever the server says.
    app.http.force_stream = true;
    errdefer app.http.force_stream = false;
    try command.run(app, .{ .static = .@"http.send" });
    app.http.force_stream = false;
}

fn copyAiPromptCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    try rp.commit();
    const arena = app.frame.allocator();
    const curl = try parse.toCurl(arena, &rp.request);
    const status_line: []const u8 = if (rp.response()) |r| try std.fmt.allocPrint(arena, "{d} {s}\n\n{s}", .{ r.status, r.status_text, r.body[0..@min(r.body.len, 4000)] }) else if (rp.state == .failed) rp.state.failed else "(not sent yet)";
    const text = try std.fmt.allocPrint(arena, "Debug this HTTP request. It is failing and I need to know why.\n\n```\n{s}\n```\n\nResponse:\n\n```\n{s}\n```\n", .{ curl, status_line });
    try app.clipboard.set(text, false);
    app.toast("copied an AI debug prompt ({d} bytes)", .{text.len});
}

fn aiNotYet(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "the Claude integration lands in Phase 7 — :http.copy_ai_prompt copies a prompt meanwhile", .{});
}

// ─── SSE / JWT / bearer ─────────────────────────────────────────────────

fn sseParseCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    const resp = rp.response() orelse return app.diag.fail(app.frame.allocator(), "sse.parse: no active Request pane with a Done response", .{});
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const events = try sse.parseAll(arena.allocator(), resp.body);
    if (events.len == 0) return app.diag.fail(app.frame.allocator(), "sse.parse: body has no SSE events (no blank-line-delimited data blocks)", .{});
    const first = events[0];
    const preview = if (first.data.len > 40) try std.fmt.allocPrint(arena.allocator(), "{s}…", .{first.data[0..38]}) else first.data;
    const label = if (first.name.len == 0) "" else try std.fmt.allocPrint(arena.allocator(), " [{s}]", .{first.name});
    app.toast("sse: {d} event(s){s} · first: {s}", .{ events.len, label, preview });
}

fn jwtDecodeCmd(app: *App) CommandError!void {
    const token = app.clipboard.text();
    if (std.mem.trim(u8, token, " \t\r\n").len == 0) return app.diag.fail(app.frame.allocator(), "jwt.decode: clipboard is empty", .{});
    var claims = jwt.decode(app.gpa, token) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotAJwt => return app.diag.fail(app.frame.allocator(), "jwt.decode: not a valid JWT (3 dot-separated segments)", .{}),
        error.BadBase64 => return app.diag.fail(app.frame.allocator(), "jwt.decode: segments are not base64url", .{}),
        error.NotJson => return app.diag.fail(app.frame.allocator(), "jwt.decode: the claims segment is not JSON", .{}),
    };
    defer claims.deinit(app.gpa);
    const arena = app.frame.allocator();
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    if (claims.sub) |s| try parts.append(arena, try std.fmt.allocPrint(arena, "sub={s}", .{s}));
    if (claims.email) |s| try parts.append(arena, try std.fmt.allocPrint(arena, "email={s}", .{s}));
    if (claims.exp) |e| {
        const c = env_mod.civilFromUnix(e);
        try parts.append(arena, try std.fmt.allocPrint(arena, "exp={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(@max(c.year, 0))), c.month, c.day, c.hour, c.minute }));
    }
    const now_s: i64 = @intCast(@divFloor(Io.Timestamp.now(app.io, .real).toNanoseconds(), std.time.ns_per_s));
    if (claims.isExpired(now_s)) try parts.append(arena, "EXPIRED");
    if (parts.items.len == 0) {
        app.toast("jwt.decode: (token has no standard claims)", .{});
        return;
    }
    app.toast("jwt: {s}", .{try std.mem.join(arena, " · ", parts.items)});
}

fn extractBearerCmd(app: *App) CommandError!void {
    const text = app.clipboard.text();
    const token = jwt.extractBearer(text) orelse return app.diag.fail(app.frame.allocator(), "auth.extract_bearer: no bearer token in the clipboard", .{});
    const copy = try app.frame.allocator().dupe(u8, token);
    try app.clipboard.set(copy, false);
    app.toast("auth: extracted bearer token ({d} chars) → clipboard", .{copy.len});
}

// ─── auth ───────────────────────────────────────────────────────────────

pub fn openAuthPrompt(app: *App, kind: AuthKind) Allocator.Error!void {
    const title: []const u8 = switch (kind) {
        .bearer => "Bearer token:",
        .basic => "Basic auth (user:password):",
        .api_key => "X-Api-Key value:",
    };
    try openPrompt(app, title, .{ .http_auth_value = kind });
}

fn applyAuth(app: *App, kind: AuthKind, text: []const u8) Allocator.Error!void {
    const rp = http.activeRequest(app) orelse {
        app.toast("auth: no active Request pane", .{});
        return;
    };
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return;
    try rp.commit();
    switch (kind) {
        .bearer => {
            const v = try std.fmt.allocPrint(app.frame.allocator(), "Bearer {s}", .{value});
            try rp.request.setHeader(app.gpa, "Authorization", v);
        },
        .basic => {
            const enc = std.base64.standard.Encoder;
            const buf = try app.frame.allocator().alloc(u8, enc.calcSize(value.len));
            const v = try std.fmt.allocPrint(app.frame.allocator(), "Basic {s}", .{enc.encode(buf, value)});
            try rp.request.setHeader(app.gpa, "Authorization", v);
        },
        .api_key => try rp.request.setHeader(app.gpa, "X-Api-Key", value),
    }
    try rp.syncHeadersText();
    rp.edited = true;
    app.toast("auth: set {s}", .{switch (kind) {
        .bearer => "Bearer token",
        .basic => "Basic auth",
        .api_key => "X-Api-Key",
    }});
}

fn authDir(app: *App, arena: Allocator) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ app.workspace, ".mnml", "auth" });
}

fn authSavePresetCmd(app: *App) CommandError!void {
    const rp = try http.requireRequest(app);
    try rp.commit();
    if (rp.request.header("authorization") == null) return app.diag.fail(app.frame.allocator(), "auth: active Request has no Authorization header", .{});
    try openPrompt(app, "Preset name (filename stem):", .auth_preset_name);
}

fn savePreset(app: *App, name_in: []const u8) Allocator.Error!void {
    const name = std.mem.trim(u8, name_in, " \t");
    if (name.len == 0) {
        app.toast("auth: preset name can't be empty", .{});
        return;
    }
    const rp = http.activeRequest(app) orelse return;
    const value = rp.request.header("authorization") orelse return;
    const arena = app.frame.allocator();
    const safe = try arena.dupe(u8, name);
    for (safe) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_')) {
        c.* = '_';
    };
    const dir = try authDir(app, arena);
    Io.Dir.cwd().createDirPath(app.io, dir) catch |err| {
        app.toast("auth: mkdir: {s}", .{@errorName(err)});
        return;
    };
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ dir, safe });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = value }) catch |err| {
        app.toast("auth: write failed: {s}", .{@errorName(err)});
        return;
    };
    app.toast("auth: saved → {s}", .{app.relPath(path)});
}

fn authApplyPresetCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try authDir(app, a);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    if (Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".txt")) continue;
            try labels.append(gpa, try gpa.dupe(u8, e.name[0 .. e.name.len - ".txt".len]));
            const text = dir.readFileAlloc(app.io, e.name, a, .limited(4096)) catch "";
            const first = std.mem.sliceTo(text, '\n');
            try details.append(gpa, try gpa.dupe(u8, if (first.len > 48) first[0..46] else first));
        }
    } else |_| {}
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "auth: no presets in {s} (save with :auth.save_preset)", .{app.relPath(dir_path)});
    try cmd_picker.openPickerWith(app, "Auth presets", .auth_presets, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

fn applyPreset(app: *App, name: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const dir = try authDir(app, arena);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ dir, name });
    const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(64 << 10)) catch |err| {
        app.toast("auth: read {s}: {s}", .{ app.relPath(path), @errorName(err) });
        return;
    };
    const value = std.mem.trimEnd(u8, text, " \t\r\n");
    const rp = http.activeRequest(app) orelse {
        app.toast("auth: no active Request pane", .{});
        return;
    };
    try rp.commit();
    try rp.request.setHeader(app.gpa, "Authorization", value);
    try rp.syncHeadersText();
    rp.edited = true;
    app.toast("auth: applied {s}", .{name});
}

// ─── cookies ────────────────────────────────────────────────────────────

fn cookieLabels(app: *App, labels: *std.ArrayListUnmanaged([]u8)) Allocator.Error!usize {
    const j = try jar(app);
    const es = try j.entries(app.frame.allocator());
    for (es) |e| {
        const preview = if (e.value.len > 32) e.value[0..30] else e.value;
        try labels.append(app.gpa, try std.fmt.allocPrint(app.gpa, "{s}  ·  {s}  ·  {s}", .{ e.host, e.name, preview }));
    }
    return es.len;
}

fn cookiesShowCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    const total = try cookieLabels(app, &labels);
    if (total == 0) try labels.append(gpa, try gpa.dupe(u8, "(jar is empty — :http.send accumulates from Set-Cookie)"));
    const title = try std.fmt.allocPrint(gpa, "Cookies ({d} total)", .{total});
    errdefer gpa.free(title);
    if (app.http.picker_title) |t| gpa.free(t);
    app.http.picker_title = title;
    try cmd_picker.openPicker(app, title, .cookies_show, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn cookiesDeleteCmd(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    const total = try cookieLabels(app, &labels);
    if (total == 0) return app.diag.fail(app.frame.allocator(), "cookies: jar is empty", .{});
    const title = try std.fmt.allocPrint(gpa, "Delete cookie ({d} total)", .{total});
    errdefer gpa.free(title);
    if (app.http.picker_title) |t| gpa.free(t);
    app.http.picker_title = title;
    try cmd_picker.openPicker(app, title, .cookies_delete, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn cookiesClearCmd(app: *App) CommandError!void {
    const j = try jar(app);
    const prev = j.total();
    j.clear();
    saveJar(app);
    app.toast("cookies: cleared {d} entries", .{prev});
}

fn cookiesPersistCmd(app: *App) CommandError!void {
    const j = try jar(app);
    const path = j.save(app.gpa, app.io, app.workspace) catch |err| return app.diag.fail(app.frame.allocator(), "cookies: write failed: {s}", .{@errorName(err)});
    defer app.gpa.free(path);
    app.toast("cookies: {d} entries → {s}", .{ j.total(), app.relPath(path) });
}

fn cookiesNormalizeCmd(app: *App) CommandError!void {
    const raw = app.clipboard.text();
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return app.diag.fail(app.frame.allocator(), "cookies.normalize: clipboard is empty", .{});
    const out = try cookies.normalize(app.gpa, raw);
    defer app.gpa.free(out);
    if (out.len == 0) return app.diag.fail(app.frame.allocator(), "cookies.normalize: no name=value pairs found", .{});
    try app.clipboard.set(out, false);
    app.toast("cookies: {s}", .{if (out.len > 120) out[0..118] else out});
}

// ─── headers picker / copy-as ───────────────────────────────────────────

const common_headers = [_][]const u8{ "Accept: application/json", "Content-Type: application/json", "Authorization: Bearer ", "X-Api-Key: ", "Accept: */*", "Content-Type: application/x-www-form-urlencoded", "User-Agent: mnml", "Cache-Control: no-cache", "Accept-Encoding: gzip, deflate", "Cookie: " };

fn insertHeaderCmd(app: *App) CommandError!void {
    _ = try http.requireRequest(app);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (common_headers) |h| try labels.append(gpa, try gpa.dupe(u8, h));
    try cmd_picker.openPicker(app, "Insert header", .http_insert_header, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

const code_targets = [_][]const u8{ "curl", "Python (requests)", "JavaScript (fetch)", "Go (net/http)", "wget", "HTTPie" };

pub fn copyAsPicker(app: *App) CommandError!void {
    _ = try http.requireRequest(app);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (code_targets) |t| try labels.append(gpa, try gpa.dupe(u8, t));
    try cmd_picker.openPicker(app, "Copy request as", .http_copy_as, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn copyAs(app: *App, idx: usize) Allocator.Error!void {
    const rp = http.activeRequest(app) orelse return;
    try rp.commit();
    const a = app.frame.allocator();
    const req = &rp.request;
    const text: []const u8 = switch (idx) {
        0 => try parse.toCurl(a, req),
        1 => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try out.appendSlice(a, "import requests\n\nheaders = {\n");
            for (req.headers.items) |h| try appendFmt(a, &out, "    \"{s}\": \"{s}\",\n", .{ h.name, h.value });
            try out.appendSlice(a, "}\n\n");
            const m = try std.ascii.allocLowerString(a, req.method);
            if (req.body) |b| {
                try appendFmt(a, &out, "data = \"\"\"{s}\"\"\"\n\nresponse = requests.{s}(\"{s}\", headers=headers, data=data)\n", .{ b, m, req.url });
            } else try appendFmt(a, &out, "response = requests.{s}(\"{s}\", headers=headers)\n", .{ m, req.url });
            try out.appendSlice(a, "print(response.status_code, response.text)\n");
            break :blk out.items;
        },
        2 => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try appendFmt(a, &out, "const res = await fetch(\"{s}\", {{\n  method: \"{s}\",\n  headers: {{\n", .{ req.url, req.method });
            for (req.headers.items) |h| try appendFmt(a, &out, "    \"{s}\": \"{s}\",\n", .{ h.name, h.value });
            try out.appendSlice(a, "  },\n");
            if (req.body) |b| try appendFmt(a, &out, "  body: {s},\n", .{try std.json.Stringify.valueAlloc(a, b, .{})});
            try out.appendSlice(a, "});\nconsole.log(res.status, await res.text());\n");
            break :blk out.items;
        },
        3 => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try out.appendSlice(a, "package main\n\nimport (\n\t\"fmt\"\n\t\"io\"\n\t\"net/http\"\n\t\"strings\"\n)\n\nfunc main() {\n");
            if (req.body) |b| try appendFmt(a, &out, "\tbody := strings.NewReader({s})\n\treq, _ := http.NewRequest(\"{s}\", \"{s}\", body)\n", .{ try std.json.Stringify.valueAlloc(a, b, .{}), req.method, req.url }) else try appendFmt(a, &out, "\treq, _ := http.NewRequest(\"{s}\", \"{s}\", nil)\n", .{ req.method, req.url });
            for (req.headers.items) |h| try appendFmt(a, &out, "\treq.Header.Set(\"{s}\", \"{s}\")\n", .{ h.name, h.value });
            try out.appendSlice(a, "\tres, err := http.DefaultClient.Do(req)\n\tif err != nil {\n\t\tpanic(err)\n\t}\n\tdefer res.Body.Close()\n\tb, _ := io.ReadAll(res.Body)\n\tfmt.Println(res.StatusCode, string(b))\n}\n");
            break :blk out.items;
        },
        4 => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try appendFmt(a, &out, "wget --method={s}", .{req.method});
            for (req.headers.items) |h| try appendFmt(a, &out, " \\\n  --header='{s}: {s}'", .{ h.name, h.value });
            if (req.body) |b| try appendFmt(a, &out, " \\\n  --body-data='{s}'", .{b});
            try appendFmt(a, &out, " \\\n  -O - '{s}'", .{req.url});
            break :blk out.items;
        },
        else => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try appendFmt(a, &out, "http {s} '{s}'", .{ req.method, req.url });
            for (req.headers.items) |h| try appendFmt(a, &out, " \\\n  '{s}:{s}'", .{ h.name, h.value });
            if (req.body) |b| try appendFmt(a, &out, " \\\n  --raw '{s}'", .{b});
            break :blk out.items;
        },
    };
    try app.clipboard.set(text, false);
    app.toast("copied as {s} ({d} bytes)", .{ code_targets[@min(idx, code_targets.len - 1)], text.len });
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try list.appendSlice(a, s);
}

// ─── prompts ────────────────────────────────────────────────────────────

fn openPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, title), .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn openSaveAsPrompt(app: *App) Allocator.Error!void {
    try openPrompt(app, "Save request as (workspace-relative path):", .http_save_as);
}

pub fn openSaveResponsePrompt(app: *App) Allocator.Error!void {
    try openPrompt(app, "Save response body to:", .http_save_response);
}

pub fn replayMockFrom(app: *App, rp: *RequestPane, path: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    var m = mock.load(app.gpa, app.io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return app.diag.fail(arena, "replay_mock: no mock at {s} (:http.save_mock writes one)", .{app.relPath(path)}),
        else => return app.diag.fail(arena, "replay_mock: {s}: {s}", .{ app.relPath(path), @errorName(err) }),
    };
    defer m.deinit(app.gpa);
    const gpa = app.gpa;
    const hs = try gpa.alloc(parse.Header, m.headers.len);
    var filled: usize = 0;
    errdefer {
        for (hs[0..filled]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(hs);
    }
    for (m.headers) |h| {
        hs[filled].name = try gpa.dupe(u8, h.name);
        errdefer gpa.free(hs[filled].name);
        hs[filled].value = try gpa.dupe(u8, h.value);
        filled += 1;
    }
    const resp: client.Response = .{
        .status = m.status,
        .status_text = try gpa.dupe(u8, m.status_text),
        .final_url = try gpa.dupe(u8, rp.request.url),
        .headers = hs,
        .body = try gpa.dupe(u8, m.body),
    };
    try rp.setSentLine(rp.request.method, rp.request.url);
    try rp.setResponse(resp);
    rp.clearTests();
    try rp.addTest("mock: replayed from {s}", .{app.relPath(path)});
    try validateSchema(app, rp, false);
    app.toast("mock: replayed {d} {s} from {s}", .{ m.status, m.status_text, app.relPath(path) });
    if (app.active) |id| try emitResponseHook(app, id, rp);
}

/// A picker opened here was accepted. `i` indexes the labels.
pub fn acceptPicker(app: *App, kind: app_mod.PickerKind, i: usize, label: []const u8) Allocator.Error!void {
    switch (kind) {
        .http_env_vars => {
            if (i == 0) return openPrompt(app, "KEY=VALUE for new env var:", .http_env_add_key);
            var arena = std.heap.ArenaAllocator.init(app.gpa);
            defer arena.deinit();
            const sel = try activeEnvName(app, arena.allocator());
            var set = try env_mod.EnvSet.load(arena.allocator(), app.io, app.workspace, sel.name);
            try openEnvValuePrompt(app, label, set.get(label) orelse "");
        },
        .http_env_delete => {
            var arena = std.heap.ArenaAllocator.init(app.gpa);
            defer arena.deinit();
            const sel = try activeEnvName(app, arena.allocator());
            const gone = env_mod.deleteKey(app.gpa, app.io, app.workspace, sel.name, label) catch false;
            http.restampEnvWatch(app);
            app.toast("env: {s} {s}", .{ label, if (gone) "deleted" else "not found" });
        },
        .http_env_pick => {
            if (app.http.env_override) |e| app.gpa.free(e);
            app.http.env_override = try app.gpa.dupe(u8, label);
            // An explicit pick is for every pane, a re-fired one too.
            for (app.panes.slots.items) |*slot| if (slot.*) |*pane| if (pane.asRequest()) |rp| if (rp.env_pin) |pin| {
                app.gpa.free(pin);
                rp.env_pin = null;
            };
            app.toast("env: {s} (session override — :http.reset_env clears)", .{label});
        },
        .http_history => {
            const rows = app.http.history_rows;
            if (rows.len == 0) return;
            const idx = rows.len - 1 - @min(i, rows.len - 1);
            const row = rows[idx];
            const req = try history.rowToRequest(app.gpa, row);
            const id = http.openFromRequest(app, req, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            if (row.env) |env_name| if (row.url_template != null) if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
                rp.env_pin = try app.gpa.dupe(u8, env_name);
                app.toast("history: resolves against env {s}, the one it was sent with", .{env_name});
            };
        },
        .http_captured => {
            const curls = app.http.captured_curls;
            if (i >= curls.len) return;
            const req = parse.parse(app.gpa, curls[i]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            _ = http.openFromRequest(app, req, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .http_chains => runChainNamed(app, label) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
        },
        .auth_presets => try applyPreset(app, label),
        .cookies_show => {
            if (std.mem.startsWith(u8, label, "(jar is empty")) return;
            // `host  ·  name  ·  value` → copy `name=value`.
            var parts = std.mem.splitSequence(u8, label, "  ·  ");
            const host = parts.next() orelse return;
            const name = parts.next() orelse return;
            const j = try jar(app);
            const value = j.valueOf(host, name) orelse return;
            const text = try std.fmt.allocPrint(app.frame.allocator(), "{s}={s}", .{ name, value });
            try app.clipboard.set(text, false);
            app.toast("cookies: copied {s}", .{text});
        },
        .cookies_delete => {
            var parts = std.mem.splitSequence(u8, label, "  ·  ");
            const host = parts.next() orelse return;
            const name = parts.next() orelse return;
            const j = try jar(app);
            const gone = j.remove(host, name);
            saveJar(app);
            app.toast("cookies: {s} {s}", .{ name, if (gone) "deleted" else "not found" });
        },
        .http_insert_header => {
            const rp = http.activeRequest(app) orelse return;
            if (rp.headers_text.items.len > 0 and rp.headers_text.items[rp.headers_text.items.len - 1] != '\n') try rp.headers_text.append(app.gpa, '\n');
            try rp.headers_text.appendSlice(app.gpa, label);
            try rp.headers_text.append(app.gpa, '\n');
            rp.headers_caret = rp.headers_text.items.len - 1;
            rp.showTab(.headers);
            rp.headers_caret = rp.headers_text.items.len - 1;
            try rp.commit();
            rp.edited = true;
        },
        .http_copy_as => try copyAs(app, i),
        .http_find_request => try @import("http_ops.zig").acceptFind(app, i),
        .http_move_target => try @import("http_ops.zig").acceptMove(app, label),
        .http_lookup_file => {
            const arena = app.frame.allocator();
            const path = try std.fs.path.join(arena, &.{ app.workspace, ".rqst", "lookups", label });
            const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 20)) catch return;
            const req = parse.parse(app.gpa, text) catch return;
            const id = http.openFromRequest(app, req, .{ .source_path = path, .focus_response = true }) catch return;
            app.http.lookup_pane = id;
            http.fire(app, id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            app.toast("lookup: firing request…", .{});
        },
        .http_lookup_item => {
            const owned = try app.gpa.dupe(u8, label);
            if (app.http.pending_env_key) |k| app.gpa.free(k);
            app.http.pending_env_key = owned;
            try openPrompt(app, "Env var name:", .http_lookup_var);
        },
        else => {},
    }
}

/// The lookup response landed: pick an item out of the JSON array.
pub fn offerLookupItems(app: *App, rp: *RequestPane) Allocator.Error!void {
    const resp = rp.response() orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{}) catch return;
    const items: []const std.json.Value = switch (v) {
        .array => |arr| arr.items,
        .object => |o| blk: {
            var it = o.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .array) break :blk e.value_ptr.array.items;
            break :blk &.{};
        },
        else => &.{},
    };
    if (items.len == 0) {
        app.toast("lookup: the response has no array to pick from", .{});
        return;
    }
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (items) |item| {
        var id_text: []const u8 = "?";
        var name_text: []const u8 = "";
        if (item == .object) {
            if (item.object.get("id")) |x| id_text = try std.json.Stringify.valueAlloc(a, x, .{});
            for ([_][]const u8{ "name", "title", "email", "username", "label" }) |k| if (item.object.get(k)) |x| if (x == .string) {
                name_text = x.string;
                break;
            };
        } else id_text = try std.json.Stringify.valueAlloc(a, item, .{});
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}", .{ std.mem.trim(u8, id_text, "\""), name_text }));
    }
    cmd_picker.openPicker(app, "Lookup item", .http_lookup_item, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// A prompt opened here was submitted.
pub fn acceptPrompt(app: *App, purpose: app_mod.PromptPurpose, text: []const u8) Allocator.Error!void {
    switch (purpose) {
        .http_env_add_key => {
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
                app.toast("env: input must be KEY=VALUE", .{});
                return;
            };
            const key = std.mem.trim(u8, text[0..eq], " \t");
            if (key.len == 0) {
                app.toast("env: key can't be empty", .{});
                return;
            }
            try writeEnvVar(app, key, std.mem.trim(u8, text[eq + 1 ..], " \t"));
        },
        .http_env_edit_value => |key| try writeEnvVar(app, key, text),
        .http_auth_value => |kind| try applyAuth(app, kind, text),
        .http_option => |kind| try http.applyOptionPrompt(app, kind, text),
        .http_path_param => |name| try http.applyPathParamPrompt(app, name, text),
        .auth_preset_name => try savePreset(app, text),
        .http_save_as => {
            const rel = std.mem.trim(u8, text, " \t");
            if (rel.len == 0) return;
            const rp = http.activeRequest(app) orelse return;
            const abs = try app.absPath(rel);
            if (rp.source_path) |p| app.gpa.free(p);
            rp.source_path = try app.gpa.dupe(u8, abs);
            http.saveToSource(app) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
        },
        .http_save_response => {
            const rel = std.mem.trim(u8, text, " \t");
            if (rel.len == 0) return;
            const rp = http.activeRequest(app) orelse return;
            const resp = rp.response() orelse return;
            const abs = try app.absPath(rel);
            if (std.fs.path.dirname(abs)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = resp.body }) catch |err| {
                app.toast("save_response: {s}", .{@errorName(err)});
                return;
            };
            app.toast("saved response body → {s} ({d} bytes)", .{ rel, resp.body.len });
        },
        .http_new_env => {
            const name = std.mem.trim(u8, text, " \t");
            if (name.len == 0) return;
            const path = try env_mod.envPath(app.frame.allocator(), app.workspace, ".mnml", name);
            if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
            const stub = try std.fmt.allocPrint(app.frame.allocator(), "# {s} env — one KEY=VALUE per line\n", .{name});
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = stub }) catch |err| {
                app.toast("new_env: {s}", .{@errorName(err)});
                return;
            };
            if (app.http.env_override) |e| app.gpa.free(e);
            app.http.env_override = try app.gpa.dupe(u8, name);
            http.restampEnvWatch(app);
            _ = app.openEditor(path) catch {};
            app.toast("env: created {s} (now active)", .{app.relPath(path)});
        },
        .http_new_chain => {
            const name = std.mem.trim(u8, text, " \t");
            if (name.len == 0) return;
            const dir = try chainsDir(app, app.frame.allocator());
            Io.Dir.cwd().createDirPath(app.io, dir) catch {};
            const path = try std.fmt.allocPrint(app.frame.allocator(), "{s}/{s}.chain.json", .{ dir, name });
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "[\n  { \"request\": \"auth/login.curl\", \"extract\": { \"TOKEN\": \"$.access_token\" } },\n  { \"request\": \"users/list.curl\" }\n]\n" }) catch |err| {
                app.toast("new_chain: {s}", .{@errorName(err)});
                return;
            };
            _ = app.openEditor(path) catch {};
        },
        .http_new_collection => {
            const name = std.mem.trim(u8, text, " \t/");
            if (name.len == 0) return;
            const dir = try std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".mnml", "collections", name });
            Io.Dir.cwd().createDirPath(app.io, dir) catch |err| {
                app.toast("new_collection: {s}", .{@errorName(err)});
                return;
            };
            app.toast("collection: created {s}/", .{app.relPath(dir)});
        },
        .http_new_request => {
            const rel = std.mem.trim(u8, text, " \t");
            if (rel.len == 0) return;
            const abs = try app.absPath(rel);
            if (std.fs.path.dirname(abs)) |parent| Io.Dir.cwd().createDirPath(app.io, parent) catch {};
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = "GET https://example.com/\n" }) catch |err| {
                app.toast("new_request: {s}", .{@errorName(err)});
                return;
            };
            _ = app.openPath(abs) catch {};
        },
        .http_lookup_var => {
            const name = std.mem.trim(u8, text, " \t");
            const item = app.http.pending_env_key orelse return;
            defer {
                app.gpa.free(item);
                app.http.pending_env_key = null;
            }
            if (name.len == 0) return;
            const id_text = std.mem.sliceTo(item, ' ');
            try writeEnvVar(app, name, id_text);
        },
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

fn pumpUntilSettled(app: *App, rp: *RequestPane, max_ticks: usize) !void {
    var waited: usize = 0;
    while ((rp.state == .sending or rp.state == .streaming) and waited < max_ticks) : (waited += 1) {
        try app.tick(App.nowMs(app.io));
        try Io.sleep(app.io, .fromMilliseconds(10), .awake);
    }
}

const HookProbe = struct {
    var tests_at_response: usize = 0;
    var responses: u32 = 0;
    fn onResponse(app: *App, args: hooks.HookArgs) void {
        responses += 1;
        const rp = (app.panes.get(args.http_response.pane) orelse return).asRequest() orelse return;
        tests_at_response = rp.tests.items.len;
    }
};

test "hooks: http_request rewrites the wire after the directives; http_response fires after the captures; set_var round-trips to the env file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "x-request-id", .value = "req-7" } }, .body = "{\"id\":7}" });
    defer server.stop(testing.io);
    const src = try std.fmt.allocPrint(testing.allocator,
        \\# @set-header X-Probe = yes
        \\# @capture TRACE = header x-request-id
        \\GET http://127.0.0.1:{d}/users/7
        \\Accept: application/json
        \\
    , .{server.port});
    defer testing.allocator.free(src);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "u.http", .data = src });
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    HookProbe.tests_at_response = 0;
    HookProbe.responses = 0;
    try app.hooks.subscribe(.http_response, .{ .zig = &HookProbe.onResponse });
    const lua = app.script();
    lua.runString(
        \\log = {}
        \\mnml.on("http_request", function(a)
        \\  log[#log + 1] = "req " .. a.method .. " " .. (a.headers["X-Probe"] or "-") .. " " .. (a.headers["Accept"] or "-") .. " env=" .. tostring(a.env) .. " body=" .. tostring(a.body)
        \\  a.headers["X-Hook"] = "lua"
        \\  a.url = a.url .. "?hooked=1"
        \\  a.method = "post"
        \\  a.body = "from-lua"
        \\  return a
        \\end)
        \\mnml.on("http_response", function(a)
        \\  log[#log + 1] = "resp " .. a.status .. " " .. a.headers["x-request-id"] .. " " .. a.body .. " " .. tostring(a.body_truncated) .. " " .. a.hook
        \\  assert(type(a.timing_ms) == "number")
        \\  assert(mnml.http.set_var("HOOK_STATUS", tostring(a.status)))
        \\  local ok, why = mnml.http.set_var("bad key", "x")
        \\  assert(not ok and why:find("A%-Za%-z0%-9_"), tostring(why))
        \\  local ok2, why2 = mnml.http.set_var("NL", "a\nb")
        \\  assert(not ok2 and why2:find("newline"), tostring(why2))
        \\end)
    ) catch |err| {
        std.debug.print("lua: {s}\n", .{lua.last_error orelse "?"});
        return err;
    };
    const path = try std.fs.path.join(testing.allocator, &.{ root, "u.http" });
    defer testing.allocator.free(path);
    const id = try app.openPath(path);
    const rp = app.panes.get(id).?.asRequest().?;
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntilSettled(&app, rp, 300);
    try testing.expect(rp.state == .done);
    // The wire: the hook's method, url, header and body, over the
    // directive's header (which the hook saw — directives run first).
    const seen = server.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "POST /users/7?hooked=1 HTTP/1.1\r\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "x-hook: lua\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "x-probe: yes\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, seen, "\r\n\r\nfrom-lua"));
    try testing.expect(std.mem.startsWith(u8, rp.sent_line.?, "POST http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, rp.sent_line.?, "/users/7?hooked=1"));
    var sent_hook = false;
    for (rp.sent_headers.items) |h| if (std.mem.eql(u8, h.name, "X-Hook") and std.mem.eql(u8, h.value, "lua")) {
        sent_hook = true;
    };
    try testing.expect(sent_hook);
    // The pane's own fields stay as written.
    try testing.expectEqualStrings("GET", rp.request.method);
    try testing.expect(std.mem.indexOf(u8, rp.headers_text.items, "X-Hook") == null);
    // The payloads, in order; the response hook came after the capture
    // row landed (Zig subscribers run before Lua's, same emit).
    try lua.runString(
        \\assert(#log == 2, #log)
        \\assert(log[1] == "req GET yes application/json env=dev body=nil", log[1])
        \\assert(log[2] == 'resp 200 req-7 {"id":7} false http_response', log[2])
    );
    try testing.expectEqual(@as(u32, 1), HookProbe.responses);
    try testing.expect(HookProbe.tests_at_response > 0);
    const env_text = try tmp.dir.readFileAlloc(testing.io, ".mnml/env/dev.env", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(env_text);
    try testing.expect(std.mem.indexOf(u8, env_text, "TRACE=req-7\n") != null);
    try testing.expect(std.mem.indexOf(u8, env_text, "HOOK_STATUS=200\n") != null);
    try testing.expect(std.mem.indexOf(u8, env_text, "bad key") == null);
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "hooks: mnml.http.send inside http_response re-fires once the hook returns; inside http_request it is refused; body = false drops the body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp, testing.allocator);
    defer testing.allocator.free(root);
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .body = "ok" });
    defer server.stop(testing.io);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    defer app.deinit();
    const lua = app.script();
    try lua.runString(
        \\sends = 0
        \\mnml.on("http_request", function(a)
        \\  local ok, why = pcall(mnml.http.send)
        \\  assert(not ok and tostring(why):find("http_request"), tostring(why))
        \\  return { body = false }
        \\end)
        \\mnml.on("http_response", function(a)
        \\  sends = sends + 1
        \\  if sends == 1 then assert(mnml.http.send()) end
        \\end)
    );
    const id = try http.openBlank(&app);
    const rp = app.panes.get(id).?.asRequest().?;
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/x", .{server.port});
    defer testing.allocator.free(url);
    try rp.url.appendSlice(testing.allocator, url);
    try rp.body.appendSlice(testing.allocator, "{\"a\":1}");
    try rp.setMethod("post");
    try command.run(&app, .{ .static = .@"http.send" });
    try pumpUntilSettled(&app, rp, 300);
    // The first response's hook re-fired: a second send is in flight or done.
    try pumpUntilSettled(&app, rp, 300);
    try testing.expect(rp.state == .done);
    try testing.expectEqual(@as(u32, 2), server.served.load(.acquire));
    try lua.runString("assert(sends == 2, sends)");
    // `body = false`: no body went out even though the pane has one.
    const seen = server.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "POST /x HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, seen, "\r\n\r\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "content-length: 7") == null);
    try testing.expectEqualStrings("{\"a\":1}", rp.body.items);
    try testing.expectEqual(@as(i32, 0), lua.L.getTop());
}

test "hooks: a response body past 1 MB reaches the hook cut there with body_truncated; a smaller one whole" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, hooks.http_body_cap + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var hs = [_]client.Header{.{ .name = @constCast("content-type"), .value = @constCast("text/plain") }};
    var resp: client.Response = .{ .status = 200, .status_text = @constCast("OK"), .final_url = @constCast("http://x/"), .headers = &hs, .body = big, .timing = .{ .total_ms = 12 } };
    const cut = try responseHookArgs(a, 3, &resp);
    try testing.expectEqual(hooks.http_body_cap, cut.body.len);
    try testing.expect(cut.body_truncated);
    try testing.expectEqual(@as(u64, 12), cut.timing_ms);
    try testing.expectEqual(@as(u32, 3), cut.pane);
    try testing.expectEqualStrings("content-type", cut.headers[0].name);
    resp.body = big[0..hooks.http_body_cap];
    const whole = try responseHookArgs(a, 3, &resp);
    try testing.expectEqual(hooks.http_body_cap, whole.body.len);
    try testing.expect(!whole.body_truncated);
    // The wire's own cut (`client.max_body`) is reported the same way.
    resp.body = big[0..10];
    resp.truncated = true;
    try testing.expect((try responseHookArgs(a, 3, &resp)).body_truncated);
}
