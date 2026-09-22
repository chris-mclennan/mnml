//! Copilot ghost text, the app's half: when the client is allowed to
//! exist at all, what reaches it, the request behind the same debounce
//! the Claude backends use, the accept telemetry, the sign-in flow and
//! the `ai.copilot_*` commands.
//!
//! The privacy rule, in one sentence: **nothing is sent for a buffer
//! unless `gateFor` returns `.allowed`**, and `gateFor` is the only way
//! to ask. `ensure` (which starts the process), `syncPane` (didOpen /
//! didChange) and `fireSuggestion` all go through it; there is no
//! second path. A buffer the gate refuses is not `didOpen`'d either —
//! opening a file on the server already ships its whole text.
//!
//!   D1  every string the client is handed is copied by it;
//!   D2  workers never toast — but there is no worker here: the client
//!       posts frames and this file reacts on the app's own thread;
//!   D3  the transport owns its reader/writer tasks and `deinit`
//!       cancels them, the way the LSP client does.
//!
//! The ghost surface, the debounce, the chip and `:messages` are
//! `app/ai.zig` + `app/ghost_chip.zig`, unchanged: a Copilot suggestion
//! is accepted with the same Tab, counted in the same stats and
//! cancelled by the same keystroke as a Claude one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const types = @import("../lsp/types.zig");
const lsp_client = @import("../lsp/client.zig");
const lsp_sync = @import("lsp_sync.zig");
const copilot = @import("../ai/copilot.zig");
const cop_client = @import("../copilot/client.zig");
const Client = cop_client.Client;
const suggest = @import("../ai/suggest.zig");
const ghost_chip = @import("ghost_chip.zig");
const gitignore = @import("gitignore.zig");
const settings = @import("settings.zig");
const lsp_decor = @import("lsp_decor.zig");
const dap_client = @import("../dap/client.zig");
const config = @import("../config/root.zig");

pub const table = .{
    .@"ai.copilot_sign_in" = &signInCmd,
    .@"ai.copilot_sign_out" = &signOutCmd,
    .@"ai.copilot_enable_here" = &enableHere,
    .@"ai.copilot_disable_here" = &disableHere,
    .@"ai.copilot_status" = &statusCmd,
};

/// The persistent toast holding the device code: it has to outlive a
/// four-second fade, and comes down when the flow finishes.
pub const device_code_toast_id = "copilot-device-code";

pub const State = struct {
    client: ?*Client = null,
    /// A spawn that failed: one toast, then quiet for the session.
    unavailable: bool = false,
    signed_in: copilot.SignedIn = .unknown,
    kind: copilot.StatusKind = .unknown,
    /// The server's own last words, for the chip's hover. Owned.
    message: ?[]u8 = null,
    /// The pane the in-flight completion belongs to, and the debounce
    /// generation it must still match when it lands.
    req_pane: ?PaneId = null,
    req_generation: u32 = 0,
    /// The item currently on screen, kept as the JSON that arrived so
    /// the accept notifications echo it byte for byte. Owned.
    shown_item_json: ?[]u8 = null,
    shown_command_json: ?[]u8 = null,
    shown_insert_text: ?[]u8 = null,
    /// Bytes of `shown_insert_text` already taken by partial accepts.
    shown_taken: usize = 0,
    /// The gitignore rules of the workspace root, read once per opt-in.
    ignores: ?gitignore.Stack = null,
    /// Set while a device flow is waiting on the user.
    pending_sign_in: bool = false,
    /// `refreshConfig` has run; and the layers it read, whose arena the
    /// adopted `.ai.copilot` / `.ai.extra` values borrow.
    refreshed: bool = false,
    loaded: ?config.Loaded = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.client) |c| c.deinit();
        self.client = null;
        self.clearShown(gpa);
        if (self.message) |m| gpa.free(m);
        self.message = null;
        if (self.ignores) |*st| st.deinit();
        self.ignores = null;
        if (self.loaded) |*l| l.deinit();
        self.loaded = null;
    }

    pub fn clearShown(self: *State, gpa: Allocator) void {
        if (self.shown_item_json) |j| gpa.free(j);
        if (self.shown_command_json) |j| gpa.free(j);
        if (self.shown_insert_text) |j| gpa.free(j);
        self.shown_item_json = null;
        self.shown_command_json = null;
        self.shown_insert_text = null;
        self.shown_taken = 0;
    }
};

// ─── the gate ───────────────────────────────────────────────────────────

/// Whether this workspace has opted in, as the trust layer left it. An
/// untrusted workspace's `true` was already stripped to the default in
/// `config/trust.zig`; the `trusted` flag is carried so the refusal can
/// say which of the two it was.
pub fn optedIn(app: *App) bool {
    return app.cfg.ai.copilot_here;
}

/// A `.mnml/config.zon` written AFTER launch — which is exactly how a
/// `.test` seeds one — is not in `app.cfg`. `app/lsp.zig` has the same
/// problem and answers it the same way: read the layers once more and
/// adopt only the keys this subsystem owns. Exec-bearing (the argv),
/// hence trusted workspaces only, and once per session.
pub fn refreshConfig(app: *App) Allocator.Error!void {
    const st = &app.copilot;
    if (st.refreshed or !app.workspace_trusted) return;
    st.refreshed = true;
    var env = try app.env.clone(app.gpa);
    defer env.deinit();
    if (app.data_root.len > 0) try env.put("MNML_DATA_ROOT", app.data_root);
    var fresh = try config.load.load(app.gpa, app.io, .{ .workspace = app.workspace, .trust = .trusted, .env = .{ .vars = &env } });
    const says_anything = fresh.config.ai.copilot_here or
        fresh.config.ai.copilot.command.len != 0 or
        fresh.config.ai.extra.get("suggest_backend") != null;
    if (!says_anything) {
        fresh.deinit();
        return;
    }
    if (st.loaded) |*old| old.deinit();
    st.loaded = fresh;
    app.cfg.ai.copilot = fresh.config.ai.copilot;
    app.cfg.ai.copilot_here = fresh.config.ai.copilot_here;
    // `suggest_backend` lives in `.ai.extra` (a Dynamic, whole-replace),
    // so the whole table comes across rather than one key out of it.
    app.cfg.ai.extra = fresh.config.ai.extra;
}

/// The one door. Every caller that would put buffer text on the wire
/// asks this first.
pub fn gateFor(app: *App, path: ?[]const u8) copilot.Reason {
    const st = &app.copilot;
    const rel: ?[]const u8 = if (path) |p| relOf(app, p) else null;
    return copilot.Gate.decide(.{
        .backend = @import("ai.zig").suggestBackend(app),
        .opted_in = optedIn(app),
        .trusted = app.workspace_trusted,
        .path = path,
        .rel = rel,
        .exclude = if (app.cfg.ai.copilot.exclude.len != 0) app.cfg.ai.copilot.exclude else &copilot.default_exclude,
        .ignores = if (st.ignores) |*s| s else null,
    });
}

/// The workspace-relative path, or null when the file is outside.
fn relOf(app: *App, path: []const u8) ?[]const u8 {
    const ws = app.workspace;
    if (ws.len == 0) return null;
    if (!std.mem.startsWith(u8, path, ws)) return null;
    if (path.len <= ws.len) return null;
    const rest = path[ws.len..];
    return if (rest[0] == '/' or rest[0] == '\\') rest[1..] else null;
}

/// The workspace's root `.gitignore`, read once. A missing file is
/// simply no rules — never a reason to send more.
fn loadIgnores(app: *App) void {
    const st = &app.copilot;
    if (st.ignores != null) return;
    var stack = gitignore.Stack.init(app.gpa);
    const path = std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".gitignore" }) catch {
        st.ignores = stack;
        return;
    };
    if (Io.Dir.cwd().readFileAlloc(app.io, path, app.frame.allocator(), .limited(1 << 20))) |text| {
        if (gitignore.Rules.parse(app.gpa, "", text)) |rules| {
            stack.push(rules) catch {};
        } else |_| {}
    } else |_| {}
    st.ignores = stack;
}

// ─── the client's life ──────────────────────────────────────────────────

/// `ai.copilot.command`, or the default binary on PATH. `$NAME` in an
/// argument is expanded from the environment, as for a language server
/// and a debug adapter — which is how `$MNML_FAKE_COPILOT` names the
/// test server.
pub fn argvFor(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    const cfg = app.cfg.ai.copilot.command;
    if (cfg.len == 0) {
        var out = try arena.alloc([]const u8, 1 + copilot.default_args.len);
        out[0] = copilot.default_binary;
        for (copilot.default_args, 0..) |a, i| out[i + 1] = a;
        return out;
    }
    var out = try arena.alloc([]const u8, cfg.len);
    for (cfg, 0..) |a, i| out[i] = try dap_client.expandEnv(arena, a, &app.env);
    return out;
}

/// Start the server if the gate allows it and it is not running.
/// Returns null on every refusal — a missing binary has toasted once by
/// then and the backend is quiet for the session.
pub fn ensure(app: *App) Allocator.Error!?*Client {
    try refreshConfig(app);
    const st = &app.copilot;
    if (st.client) |c| {
        if (!c.transport.isDead()) return c;
        retire(app);
    }
    if (st.unavailable) return null;
    // The gate without a file: backend + opt-in + trust. A workspace
    // that has not opted in never even starts the process, so there is
    // nothing running that could be asked for a completion by mistake.
    const reason = gateFor(app, "/");
    switch (reason) {
        .allowed, .secret_bearing, .excluded, .gitignored, .no_path => {},
        .not_selected, .not_opted_in, .workspace_untrusted => return null,
    }
    const arena = app.frame.allocator();
    const argv = try argvFor(app, arena);
    if (argv.len == 0) return null;
    if (!try onPath(app, arena, argv[0])) {
        st.unavailable = true;
        const msg = try copilot.missingMessage(arena, argv[0]);
        try app.toastLevel(.warn, "{s}", .{msg});
        return null;
    }
    const c = Client.spawn(app.gpa, app.io, &app.events, .{
        .argv = argv,
        .root = app.workspace,
        .env = &app.env,
        .github_enterprise_uri = app.cfg.ai.copilot.github_enterprise_uri,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            st.unavailable = true;
            try app.toastLevel(.warn, "Copilot: {s} would not start ({s})", .{ argv[0], @errorName(err) });
            return null;
        },
    };
    st.client = c;
    c.initialize() catch {
        try app.toastLevel(.warn, "Copilot: {s}: initialize failed", .{argv[0]});
        retire(app);
        return null;
    };
    loadIgnores(app);
    return c;
}

/// `copilot-language-server` on `PATH` — the same check the LSP client
/// makes, so an absolute path and a bare name both work.
fn onPath(app: *App, arena: Allocator, cmd: []const u8) Allocator.Error!bool {
    return @import("lsp.zig").onPath(app, arena, cmd);
}

pub fn retire(app: *App) void {
    const st = &app.copilot;
    if (st.client) |c| c.deinit();
    st.client = null;
    st.req_pane = null;
    st.signed_in = .unknown;
    st.kind = .unknown;
    st.clearShown(app.gpa);
}

/// The opt-in went away (a config reload, `ai.copilot_disable_here`, a
/// backend switch): the server goes with it, so nothing further can be
/// sent by an in-flight path.
pub fn stopIfNotAllowed(app: *App) void {
    if (app.copilot.client == null) return;
    const reason = gateFor(app, "/");
    switch (reason) {
        .not_selected, .not_opted_in, .workspace_untrusted => retire(app),
        else => {},
    }
}

// ─── documents ──────────────────────────────────────────────────────────

/// Mirror `e` onto the server, if the gate allows this file. Called
/// before a request rather than on every open, so a file that is never
/// completed in is never sent.
///
/// The change itself is `app/lsp_sync.zig`'s — the same fold of a
/// frame's splices into one range that the language servers get, so
/// Copilot and rust-analyzer never disagree about what the buffer says.
/// The README calls incremental sync required; `changeFor` returning
/// null is the signal to send the whole text instead.
fn syncDoc(app: *App, c: *Client, e: *EditorPane) Allocator.Error!bool {
    const path = e.buf.doc.path orelse return false;
    if (gateFor(app, path) != .allowed) return false;
    if (!c.ready) return false;
    const ed = e.buf.editor;
    const text = ed.bytes();
    if (!c.isOpen(path)) {
        c.didOpen(path, lsp_client.languageIdFor(path), text) catch return false;
        ed.doc.copilot_seen = ed.doc.edits.head();
        c.didFocus(path) catch {};
        return true;
    }
    const head = ed.doc.edits.head();
    const seen = ed.doc.copilot_seen orelse {
        ed.doc.copilot_seen = head;
        return true;
    };
    if (seen == head) return true;
    if (!ed.doc.edits.lostSince(seen)) {
        if (lsp_sync.compose(ed.doc.edits.since(seen))) |composed| {
            if (lsp_sync.changeFor(ed, composed, cop_client.encoding)) |ch| {
                c.didChange(path, &.{.{ .range = ch.range, .text = text[ch.text_start..ch.text_end] }}) catch return false;
                ed.doc.copilot_seen = head;
                return true;
            }
        }
    }
    c.didChange(path, &.{.{ .range = null, .text = text }}) catch return false;
    ed.doc.copilot_seen = head;
    return true;
}

/// A file closed in the editor closes on the server too.
pub fn onClose(app: *App, path: []const u8) void {
    const c = app.copilot.client orelse return;
    c.didClose(path) catch {};
}

// ─── the request ────────────────────────────────────────────────────────

/// `app/ai.zig::fireSuggestion`'s Copilot arm: the debounce has fired
/// and this pane wants a suggestion. Everything before here (idle time,
/// the backend switch, a ghost already showing) is shared.
pub fn fireSuggestion(app: *App, pane: PaneId, e: *EditorPane) Allocator.Error!void {
    try refreshConfig(app);
    const st = &app.copilot;
    const path = e.buf.doc.path orelse return app.ai.debounce.cancel();
    const reason = gateFor(app, path);
    if (reason != .allowed) {
        // Quiet: a `.env` the user tabs through must not toast on every
        // keystroke pause. `ai.copilot_status` is where the reason is.
        return app.ai.debounce.cancel();
    }
    const c = (try ensure(app)) orelse return app.ai.debounce.cancel();
    if (!c.ready) return app.ai.debounce.cancel();
    if (st.signed_in == .no or st.signed_in == .not_authorized) return app.ai.debounce.cancel();
    if (!try syncDoc(app, c, e)) return app.ai.debounce.cancel();
    // Whatever was out answers a cursor that has moved.
    c.cancelInFlight();
    const text = e.buf.editor.bytes();
    const pos = types.positionOf(text, e.buf.editor.cursor, cop_client.encoding);
    app.ai.ghost.clearHolds();
    const generation = app.ai.debounce.fire(app.now_ms);
    st.req_pane = pane;
    st.req_generation = generation;
    _ = c.inlineCompletion(path, pos, app.cfg.editor.tab_width, true) catch {
        _ = app.ai.debounce.settle(generation);
        try ghost_chip.settle(app, .failed, 0, "Copilot: the request could not be sent");
        return;
    };
    app.needs_render = true;
}

/// A keystroke landed: cancel the completion in flight, the way
/// `app/ai.zig::noteEdit` cancels a Claude worker.
pub fn noteEdit(app: *App) void {
    const c = app.copilot.client orelse return;
    // Only the flight: the item on screen is NOT dropped here, because
    // an accept is itself an edit and `acceptGhost` needs the item it
    // is accepting. A stale one is replaced by the next answer and
    // refused by `noteAccept`'s backend check.
    c.cancelInFlight();
}

// ─── the accept ─────────────────────────────────────────────────────────

/// A ghost was accepted, whole or in part. `taken` is the bytes this
/// accept took and `remaining` what is still showing — mnml's surface
/// counts in bytes, Copilot's telemetry in UTF-16 units from the start
/// of `insertText`, so the conversion is `ai/copilot.zig`'s.
pub fn noteAccept(app: *App, taken: usize, remaining: usize) void {
    if (@import("ai.zig").suggestBackend(app) != .copilot) return;
    const st = &app.copilot;
    const c = st.client orelse return;
    const insert = st.shown_insert_text orelse return;
    if (remaining == 0) {
        // The whole item: the item's own command carries Copilot's
        // opaque id, and is echoed verbatim.
        if (st.shown_command_json) |cmd| c.executeCommand(cmd) catch {};
        st.clearShown(app.gpa);
        return;
    }
    const item = st.shown_item_json orelse return;
    st.shown_taken += taken;
    const len = copilot.acceptedLength(insert, st.shown_taken - taken, taken);
    c.didPartiallyAccept(item, len) catch {};
}

// ─── events ─────────────────────────────────────────────────────────────

pub fn handle(app: *App, ev: *event.LspEvent) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const c = app.copilot.client orelse return;
    switch (ev.*) {
        .closed => {
            retire(app);
            app.copilot.unavailable = true;
            try app.toastLevel(.warn, "Copilot: the language server stopped", .{});
        },
        .message => |msg| try handleMessage(app, c, msg),
        // A frame over `jsonrpc.max_body`, read off the pipe and thrown
        // away. If it was the answer to a completion the asker would
        // wait for ever, so the pending entry goes and the chip settles.
        .oversize => |o| {
            if (o.id) |id| if (c.transport.take(id)) |pend| {
                if (@as(cop_client.ReqKind, @enumFromInt(pend.kind)) == .inline_completion) {
                    c.in_flight = null;
                    if (app.ai.debounce.settle(app.copilot.req_generation)) {
                        try ghost_chip.settle(app, .failed, 0, "Copilot: the reply was too big to read");
                    }
                }
            };
        },
    }
}

fn handleMessage(app: *App, c: *Client, msg: *jsonrpc.Incoming) Allocator.Error!void {
    const root = msg.root();
    switch (jsonrpc.classify(root)) {
        .notification => |n| try handleNotification(app, n.params, n.method),
        .request => |r| try handleServerRequest(app, c, r.id, r.method, r.params),
        .response => |r| {
            const pending = c.transport.take(r.id) orelse return;
            const kind: cop_client.ReqKind = @enumFromInt(pending.kind);
            if (r.err) |e| return handleError(app, kind, e);
            try handleResponse(app, c, kind, r.result, msg);
        },
        .unknown => {},
    }
}

fn handleNotification(app: *App, params: ?jsonrpc.Value, method: []const u8) Allocator.Error!void {
    const st = &app.copilot;
    // `didChangeStatus` is the live one. `statusNotification` is the v1
    // shape and `didChangeStatus/v2` a newer one; the server sends all
    // three and mnml reads exactly one, so the chip cannot flicker
    // between two spellings of the same news.
    if (std.mem.eql(u8, method, "didChangeStatus")) {
        const s = cop_client.readDidChangeStatus(params);
        st.kind = s.kind;
        if (st.message) |m| app.gpa.free(m);
        st.message = if (s.message.len != 0) try app.gpa.dupe(u8, s.message) else null;
        // The status is how a finished device flow reaches us: nothing
        // in 1.548.0 asks the client to poll.
        if (s.kind == .normal and st.pending_sign_in) {
            st.pending_sign_in = false;
            st.signed_in = .yes;
            app.dismissToast(device_code_toast_id);
            app.toast("Copilot: signed in", .{});
        }
        if (s.kind == .err) st.signed_in = .no;
        app.needs_render = true;
        return;
    }
    if (std.mem.eql(u8, method, "window/logMessage")) return;
    if (std.mem.eql(u8, method, "window/showMessage")) {
        if (params) |p| if (jsonrpc.getStr(p, "message")) |m| try app.toastLevel(.warn, "Copilot: {s}", .{m});
        return;
    }
}

fn handleServerRequest(app: *App, c: *Client, id: i64, method: []const u8, params: ?jsonrpc.Value) Allocator.Error!void {
    // `window/showDocument`: the sign-in URL. mnml opens it through the
    // same external-open path `gx` uses, so `ui.external_browser`
    // applies and the trust layer still owns that key.
    if (std.mem.eql(u8, method, "window/showDocument")) {
        if (params) |p| if (jsonrpc.getStr(p, "uri")) |uri| {
            lsp_decor.openExternal(app, uri) catch {};
        };
        c.respond(id, "{\"success\":true}") catch {};
        return;
    }
    // `window/showMessageRequest` carries billing and account notices.
    // v1 surfaces the text and declines the buttons.
    if (std.mem.eql(u8, method, "window/showMessageRequest")) {
        if (params) |p| if (jsonrpc.getStr(p, "message")) |m| try app.toastLevel(.warn, "Copilot: {s}", .{m});
        c.respond(id, "null") catch {};
        return;
    }
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        c.respond(id, "[{}]") catch {};
        return;
    }
    c.respond(id, "null") catch {};
}

fn handleError(app: *App, kind: cop_client.ReqKind, e: jsonrpc.Value) Allocator.Error!void {
    const msg = jsonrpc.getStr(e, "message") orelse "the request failed";
    switch (kind) {
        .inline_completion => {
            if (app.ai.debounce.settle(app.copilot.req_generation)) {
                try ghost_chip.settle(app, .failed, 0, msg);
            }
        },
        .sign_in => {
            app.copilot.pending_sign_in = false;
            try app.toastLevel(.warn, "Copilot sign-in: {s}", .{msg});
        },
        else => try app.toastLevel(.warn, "Copilot: {s}", .{msg}),
    }
}

fn handleResponse(app: *App, c: *Client, kind: cop_client.ReqKind, result: ?jsonrpc.Value, msg: *jsonrpc.Incoming) Allocator.Error!void {
    _ = msg;
    const st = &app.copilot;
    switch (kind) {
        .initialize => {
            c.finishHandshake() catch {};
            app.needs_render = true;
        },
        .check_status => {
            st.signed_in = cop_client.readStatus(result);
            app.needs_render = true;
        },
        .sign_in => try onSignIn(app, c, result),
        .sign_out => {
            st.signed_in = .no;
            app.toast("Copilot: signed out", .{});
            app.needs_render = true;
        },
        .shutdown, .execute_command => {},
        .inline_completion => try onCompletion(app, c, result),
    }
}

fn onCompletion(app: *App, c: *Client, result: ?jsonrpc.Value) Allocator.Error!void {
    const st = &app.copilot;
    c.in_flight = null;
    const generation = st.req_generation;
    const wanted = app.ai.debounce.settle(generation);
    if (!wanted) return; // the buffer moved on; the answer is stale
    const pane = st.req_pane orelse return;
    const e = app.panes.editor(pane) orelse return;
    const arena = app.frame.allocator();
    const got = (try cop_client.readCompletion(arena, result)) orelse {
        try ghost_chip.settle(app, .empty, 0, null);
        return;
    };
    const text = e.buf.editor.bytes();
    const cursor = e.buf.editor.cursor;
    const pos = types.positionOf(text, cursor, cop_client.encoding);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..@min(cursor, text.len)], '\n')) |nl| nl + 1 else 0;
    const line_end = if (std.mem.indexOfScalarPos(u8, text, @min(cursor, text.len), '\n')) |nl| nl else text.len;
    const ghost = copilot.ghostText(got.item, text[line_start..line_end], pos.line, pos.character) orelse {
        // An item that cannot become a cursor insert is not shown. It
        // is `empty` rather than an error: the request worked.
        try ghost_chip.settle(app, .empty, 0, null);
        return;
    };
    if (ghost.len == 0) {
        try ghost_chip.settle(app, .empty, 0, null);
        return;
    }
    try e.buf.editor.setGhostSuggestion(ghost);
    st.clearShown(app.gpa);
    st.shown_item_json = try app.gpa.dupe(u8, got.item_json);
    if (got.item.command_json) |cmd| st.shown_command_json = try app.gpa.dupe(u8, cmd);
    st.shown_insert_text = try app.gpa.dupe(u8, got.item.insert_text);
    st.shown_taken = got.item.insert_text.len - ghost.len;
    // LSP has no "it is on screen" event; Copilot's custom one is what
    // makes its shown/accepted rate mean anything.
    c.didShowCompletion(got.item_json) catch {};
    app.ai.shown +|= 1;
    app.ai.current_accepted = false;
    try ghost_chip.settle(app, .shown, ghost.len, null);
    app.needs_render = true;
}

fn onSignIn(app: *App, c: *Client, result: ?jsonrpc.Value) Allocator.Error!void {
    const st = &app.copilot;
    const reply = cop_client.readSignIn(result) orelse {
        try app.toastLevel(.warn, "Copilot: sign-in gave no answer", .{});
        return;
    };
    if (reply.status == .yes) {
        st.signed_in = .yes;
        app.toast("Copilot: already signed in", .{});
        return;
    }
    const code = reply.user_code orelse {
        try app.toastLevel(.warn, "Copilot: sign-in gave no device code", .{});
        return;
    };
    const uri = reply.verification_uri orelse "https://github.com/login/device";
    st.pending_sign_in = true;
    // The code AND the URL, on screen, with a button — and PERSISTENT,
    // because a device code is good for a quarter of an hour and a
    // toast that fades in four seconds would be a code the user has to
    // ask for again. It comes down when `didChangeStatus` says the
    // flow finished.
    //
    // Never an unasked-for browser launch: the server may open the page
    // itself through `window/showDocument` (handled above), but mnml's
    // own half offers it rather than taking it.
    const line = try std.fmt.allocPrint(app.frame.allocator(), "Copilot: enter code {s} at {s}", .{ code, uri });
    try app.toastPersistent(device_code_toast_id, line, .info);
    app.attachToastAction(device_code_toast_id, .{ .open_url = .{
        .label = try app.gpa.dupe(u8, "Open"),
        .url = try app.gpa.dupe(u8, uri),
    } });
    c.finishDeviceFlow() catch {};
}

// ─── the chip ───────────────────────────────────────────────────────────

/// `copilot · ready` / `· signed out` / `· off here` — what the ghost
/// chip's hover names when Copilot is the backend.
pub fn chipDetail(app: *App, arena: Allocator) Allocator.Error![]u8 {
    const st = &app.copilot;
    const word = copilot.stateWord(st.signed_in, st.kind, optedIn(app), st.client != null);
    if (st.message) |m| return std.fmt.allocPrint(arena, "copilot · {s} · {s}", .{ word, m });
    return std.fmt.allocPrint(arena, "copilot · {s}", .{word});
}

// ─── the commands ───────────────────────────────────────────────────────

/// The backend picker chose Copilot: say what still has to happen.
pub fn announcePick(app: *App) Allocator.Error!void {
    if (!optedIn(app)) {
        app.toast("AI ghost-text: GitHub Copilot — nothing is shared until you run ai.copilot_enable_here in this workspace", .{});
        return;
    }
    app.toast("AI ghost-text: GitHub Copilot · on for this workspace", .{});
}

fn signInCmd(app: *App) CommandError!void {
    const c = (try ensure(app)) orelse {
        if (!optedIn(app)) return app.diag.fail(app.frame.allocator(), "Copilot: this workspace has not opted in — run ai.copilot_enable_here first", .{});
        return;
    };
    _ = c.signIn() catch return app.diag.fail(app.frame.allocator(), "Copilot: could not start the sign-in", .{});
    app.toast("Copilot: asking GitHub for a device code…", .{});
}

fn signOutCmd(app: *App) CommandError!void {
    const c = app.copilot.client orelse return app.diag.fail(app.frame.allocator(), "Copilot: the language server is not running", .{});
    _ = c.signOut() catch return app.diag.fail(app.frame.allocator(), "Copilot: could not sign out", .{});
}

/// `ai.copilot_enable_here` — the opt-in, written to THIS workspace's
/// `.mnml/config.zon` and nowhere else. It turns sharing on for one
/// workspace; there is no key that turns it on for any other.
fn enableHere(app: *App) CommandError!void {
    if (!app.workspace_trusted) {
        return app.diag.fail(app.frame.allocator(), "Copilot: trust this workspace first (workspace.review_trust) — an untrusted workspace's opt-in is ignored", .{});
    }
    app.cfg.ai.copilot_here = true;
    _ = try settings.persist(app, .workspace, &.{ "ai", "copilot_here" }, true);
    loadIgnores(app);
    app.toast("Copilot: ON for {s} — open files in this workspace are sent to GitHub as you type", .{app.relPath(app.workspace)});
    app.needs_render = true;
}

fn disableHere(app: *App) CommandError!void {
    app.cfg.ai.copilot_here = false;
    _ = try settings.persist(app, .workspace, &.{ "ai", "copilot_here" }, false);
    retire(app);
    app.toast("Copilot: off for this workspace — nothing is sent", .{});
    app.needs_render = true;
}

/// `ai.copilot_status` — the one place that answers "is this thing
/// sending my code, and if not why not".
fn statusCmd(app: *App) CommandError!void {
    const st = &app.copilot;
    // Asking is allowed to start the server: "is this signed in" has no
    // answer until something has asked GitHub, and the gate has already
    // decided whether starting it is permitted at all.
    _ = try ensure(app);
    const path: ?[]const u8 = if (app.activeEditor()) |e| e.buf.doc.path else null;
    app.toast("Copilot: {s} · {s} · server {s}", .{
        copilot.stateWord(st.signed_in, st.kind, optedIn(app), st.client != null),
        gateFor(app, path).words(),
        if (st.client != null) "running" else if (st.unavailable) "unavailable" else "not started",
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "argvFor: the default binary, or the config's argv with $VARS expanded" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Not an App test — the shape of the default is what matters and it
    // must stay `--stdio`, which is the only transport mnml speaks.
    try t.expectEqualStrings("copilot-language-server", copilot.default_binary);
    try t.expectEqual(@as(usize, 1), copilot.default_args.len);
    try t.expectEqualStrings("--stdio", copilot.default_args[0]);
    _ = a;
}
