//! `Pane.request` — the editable request and its last response. The
//! request is kept as text buffers the caret lives in (URL, body, the
//! `Name: value` headers text, the Script tab's raw source) and a
//! `parse.Request` they are committed into before a send, a save or a
//! copy. The response, when one has landed, is a `client.Response`
//! plus a syntax cache for its body.
//!
//! Keys land here first (`handleKey`); the Request block edits fields,
//! the Response block scrolls. `model` hands `ui/request_view` a plain
//! view of all of it on the frame arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const text_field = @import("../ui/text_field.zig");
const editor_view = @import("../ui/editor_view.zig");
const view = @import("../ui/request_view.zig");
const parse = @import("../http/parse.zig");
const client = @import("../http/client.zig");
const env_mod = @import("../http/env.zig");
const syntax = @import("syntax.zig");
const editor_mod = @import("../editor/editor.zig");
const http = @import("http.zig");

pub const Request = parse.Request;
pub const Response = client.Response;
pub const EditTab = view.EditTab;
pub const ResponseTab = view.ResponseTab;
pub const Block = view.Block;
pub const Field = view.Field;
pub const Orientation = view.Orientation;
const Buf = std.ArrayListUnmanaged(u8);

/// A send whose body is still arriving: the head has landed, `body`
/// grows with every `.sse` chunk, and the Response block paints it as
/// it comes. `finish` turns it into the Done response.
pub const Streaming = struct {
    job: u64,
    /// Status, headers, final url; `body` is empty until `finish`.
    head: Response,
    body: std.ArrayListUnmanaged(u8) = .empty,
    is_sse: bool,
    chunked: bool,
    /// Complete SSE events so far (blank-line delimited).
    events: usize = 0,
    started_ms: i64,

    pub fn deinit(self: *Streaming, gpa: Allocator) void {
        self.head.deinit(gpa);
        self.body.deinit(gpa);
    }
};

pub const RunState = union(enum) {
    idle,
    /// The job id the worker will answer with.
    sending: u64,
    /// The head is in; the body is arriving.
    streaming: Streaming,
    done: Response,
    /// Owned transport error.
    failed: []u8,

    pub fn deinit(self: *RunState, gpa: Allocator) void {
        switch (self.*) {
            .done => |*r| r.deinit(gpa),
            .streaming => |*st| st.deinit(gpa),
            .failed => |e| gpa.free(e),
            .idle, .sending => {},
        }
        self.* = .idle;
    }

    /// The job in flight, sending or streaming.
    pub fn job(self: *const RunState) ?u64 {
        return switch (self.*) {
            .sending => |j| j,
            .streaming => |st| st.job,
            else => null,
        };
    }
};

pub const Draft = struct {
    key: Buf = .empty,
    value: Buf = .empty,
    key_caret: usize = 0,
    value_caret: usize = 0,
    on_value: bool = false,

    pub fn deinit(self: *Draft, gpa: Allocator) void {
        self.key.deinit(gpa);
        self.value.deinit(gpa);
    }
};

pub const RequestPane = struct {
    gpa: Allocator,
    /// The committed request: method, headers, body. `url` is the buffer.
    request: Request,
    url: Buf = .empty,
    url_caret: usize = 0,
    body: Buf = .empty,
    body_caret: usize = 0,
    headers_text: Buf = .empty,
    headers_caret: usize = 0,
    source: Buf = .empty,
    source_caret: usize = 0,
    /// The file it came from (absolute, owned); null for a scratch.
    source_path: ?[]u8 = null,
    /// The `### name` it came from; `""` for a bare `###`; null for a
    /// single-block file or the leading block.
    block_name: ?[]u8 = null,
    /// A leading `# …` comment, shown as the tab label.
    summary: ?[]u8 = null,
    /// `METHOD  url` for the tab; rebuilt when either changes.
    title_buf: []u8,
    state: RunState = .idle,
    /// The Done response before the current one (`http.diff_last_two`).
    prev: ?Response = null,
    /// `METHOD url` as last sent (post-expansion). Owned.
    sent_line: ?[]u8 = null,
    /// Result lines for the Tests tab (schema, assertions). Owned.
    tests: std.ArrayListUnmanaged([]u8) = .empty,
    block: Block = .request,
    edit_tab: EditTab = .body,
    field: Field = .url,
    draft: ?Draft = null,
    row_cursor: usize = 0,
    edit_scroll: usize = 0,
    response_tab: ResponseTab = .body,
    resp_view: editor_view.ViewState = .{},
    /// The response body as an editor, for the highlighter.
    resp_editor: ?editor_mod.Editor = null,
    resp_syntax: syntax.Syntax,
    body_wrap: bool = false,
    /// Edited since it was loaded or saved.
    edited: bool = false,
    /// Opened by browsing (a single click); replaced by the next browse.
    is_preview: bool = false,
    /// The side-by-side edit view: on, the right half's tab, the left
    /// half's share in percent, the right half's scroll. Pane state, so
    /// each request keeps its own arrangement.
    split: bool = false,
    split_tab: EditTab = .vars,
    split_ratio: u8 = 50,
    split_scroll: usize = 0,
    /// A press on the split divider; the next drags resize it.
    dragging_divider: bool = false,
    /// The edit area at the last draw — what a divider drag measures.
    edit_area: ?Rect = null,
    orientation: Orientation = .auto,

    pub fn init(gpa: Allocator) Allocator.Error!RequestPane {
        var req = try Request.init(gpa);
        errdefer req.deinit(gpa);
        const title_buf = try gpa.dupe(u8, "new request");
        return .{ .gpa = gpa, .request = req, .title_buf = title_buf, .resp_syntax = syntax.Syntax.init(gpa) };
    }

    pub fn deinit(self: *RequestPane) void {
        const gpa = self.gpa;
        self.request.deinit(gpa);
        self.url.deinit(gpa);
        self.body.deinit(gpa);
        self.headers_text.deinit(gpa);
        self.source.deinit(gpa);
        if (self.source_path) |p| gpa.free(p);
        if (self.block_name) |b| gpa.free(b);
        if (self.summary) |s| gpa.free(s);
        gpa.free(self.title_buf);
        self.state.deinit(gpa);
        if (self.prev) |*p| p.deinit(gpa);
        if (self.sent_line) |s| gpa.free(s);
        for (self.tests.items) |t| gpa.free(t);
        self.tests.deinit(gpa);
        if (self.draft) |*d| d.deinit(gpa);
        if (self.resp_editor) |*e| e.deinit();
        self.resp_syntax.deinit();
    }

    /// Take `req` (ownership moves) as the pane's request; the buffers
    /// follow. Method casing is normalised.
    pub fn load(self: *RequestPane, req: Request) Allocator_Error!void {
        const gpa = self.gpa;
        var incoming = req;
        errdefer incoming.deinit(gpa);
        try self.url.replaceRange(gpa, 0, self.url.items.len, incoming.url);
        self.url_caret = self.url.items.len;
        try self.body.replaceRange(gpa, 0, self.body.items.len, incoming.body orelse "");
        self.body_caret = self.body.items.len;
        const ht = try parse.headersToText(gpa, incoming.headers.items);
        defer gpa.free(ht);
        try self.headers_text.replaceRange(gpa, 0, self.headers_text.items.len, ht);
        self.headers_caret = self.headers_text.items.len;
        self.request.deinit(gpa);
        self.request = incoming;
        incoming = undefined;
        try self.request.setMethod(gpa, self.request.method);
        try self.refreshTitle();
    }

    const Allocator_Error = Allocator.Error;

    /// Push the buffers into `request` (url, headers, body).
    pub fn commit(self: *RequestPane) Allocator.Error!void {
        const gpa = self.gpa;
        try self.request.setUrl(gpa, std.mem.trim(u8, self.url.items, " \t\r\n"));
        try parse.setHeadersFromText(&self.request, gpa, self.headers_text.items);
        const body = std.mem.trimEnd(u8, self.body.items, "\r\n");
        try self.request.setBody(gpa, if (std.mem.trim(u8, body, " \t\r\n").len == 0) null else body);
        try self.refreshTitle();
    }

    /// The buffers follow `request.headers` (after a programmatic edit).
    pub fn syncHeadersText(self: *RequestPane) Allocator.Error!void {
        const ht = try parse.headersToText(self.gpa, self.request.headers.items);
        defer self.gpa.free(ht);
        try self.headers_text.replaceRange(self.gpa, 0, self.headers_text.items.len, ht);
        self.headers_caret = self.headers_text.items.len;
    }

    pub fn refreshTitle(self: *RequestPane) Allocator.Error!void {
        const gpa = self.gpa;
        const url = std.mem.trim(u8, self.url.items, " \t");
        const fresh = if (self.summary) |s|
            try std.fmt.allocPrint(gpa, "{s}  {s}", .{ self.request.method, s })
        else if (url.len == 0)
            try gpa.dupe(u8, "new request")
        else
            try std.fmt.allocPrint(gpa, "{s}  {s}", .{ self.request.method, url });
        gpa.free(self.title_buf);
        self.title_buf = fresh;
    }

    pub fn title(self: *const RequestPane) []const u8 {
        return self.title_buf;
    }

    pub fn setMethod(self: *RequestPane, m: []const u8) Allocator.Error!void {
        try self.request.setMethod(self.gpa, m);
        self.edited = true;
        try self.refreshTitle();
    }

    pub fn cycleMethod(self: *RequestPane) Allocator.Error!void {
        try self.setMethod(parse.nextMethod(self.request.method));
    }

    pub fn response(self: *RequestPane) ?*Response {
        return switch (self.state) {
            .done => |*r| r,
            else => null,
        };
    }

    pub fn isSending(self: *const RequestPane) bool {
        return self.state == .sending or self.state == .streaming;
    }

    pub fn streaming(self: *RequestPane) ?*Streaming {
        return switch (self.state) {
            .streaming => |*st| st,
            else => null,
        };
    }

    /// The head landed for `job`: the pane shows it and follows the body.
    pub fn beginStream(self: *RequestPane, job: u64, head: Response, is_sse: bool, chunked: bool, now_ms: i64) void {
        self.keepAsPrev();
        self.state = .{ .streaming = .{ .job = job, .head = head, .is_sse = is_sse, .chunked = chunked, .started_ms = now_ms } };
        self.resp_view = .{};
        self.response_tab = .body;
        self.block = .response;
    }

    /// A run of body bytes; the view follows the tail.
    pub fn appendStream(self: *RequestPane, bytes: []const u8) Allocator.Error!void {
        const st = self.streaming() orelse return;
        try st.body.appendSlice(self.gpa, bytes);
        if (st.is_sse) st.events = countSseEvents(st.body.items);
        self.resp_view.scroll_line = std.math.maxInt(u32) / 2;
    }

    /// The stream ended: the accumulated body becomes the Done response.
    pub fn finishStream(self: *RequestPane, timing: client.Timing, truncated: bool) Allocator.Error!void {
        const st = self.streaming() orelse return;
        var resp = st.head;
        resp.body = try st.body.toOwnedSlice(self.gpa);
        resp.timing = timing;
        resp.truncated = truncated;
        self.state = .idle;
        try self.setResponse(resp);
        self.resp_view.scroll_line = 0;
    }

    /// A response landed (from the wire or a mock). The previous Done
    /// response is kept for the diff; the body goes through the
    /// highlighter.
    pub fn setResponse(self: *RequestPane, resp: Response) Allocator.Error!void {
        self.keepAsPrev();
        self.state = .{ .done = resp };
        self.resp_view = .{};
        self.response_tab = .body;
        try self.highlightResponse();
        self.block = .response;
    }

    /// A Done response becomes `prev` (for the diff); any other state
    /// is dropped. The state is `.idle` afterwards.
    pub fn keepAsPrev(self: *RequestPane) void {
        const gpa = self.gpa;
        if (self.state == .done) {
            if (self.prev) |*p| p.deinit(gpa);
            self.prev = self.state.done;
            self.state = .idle;
        } else self.state.deinit(gpa);
    }

    pub fn setFailed(self: *RequestPane, msg: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, msg);
        self.state.deinit(self.gpa);
        self.state = .{ .failed = copy };
        self.block = .response;
    }

    pub fn setSentLine(self: *RequestPane, method: []const u8, url: []const u8) Allocator.Error!void {
        const line = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ method, url });
        if (self.sent_line) |s| self.gpa.free(s);
        self.sent_line = line;
    }

    pub fn clearTests(self: *RequestPane) void {
        for (self.tests.items) |t| self.gpa.free(t);
        self.tests.clearRetainingCapacity();
    }

    pub fn addTest(self: *RequestPane, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const line = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(line);
        try self.tests.append(self.gpa, line);
    }

    /// Bodies up to this size get tree-sitter spans.
    const highlight_cap: usize = 1024 * 1024;

    fn highlightResponse(self: *RequestPane) Allocator.Error!void {
        const resp = self.response() orelse return;
        if (self.resp_editor) |*e| e.deinit();
        self.resp_editor = null;
        self.resp_syntax.deinit();
        self.resp_syntax = syntax.Syntax.init(self.gpa);
        if (resp.body.len == 0 or resp.body.len > highlight_cap) return;
        const pseudo: []const u8 = switch (resp.kind()) {
            .json => "response.json",
            .html => "response.html",
            .xml => "response.xml",
            .text => return,
        };
        var ed = try editor_mod.Editor.init(self.gpa, resp.body);
        errdefer ed.deinit();
        self.resp_syntax.setLanguage(pseudo, resp.body);
        if (!self.resp_syntax.hasLanguage()) {
            ed.deinit();
            return;
        }
        try self.resp_syntax.refresh(&ed);
        self.resp_editor = ed;
    }

    /// Spans for the body viewer, on the frame arena.
    pub fn responseSpans(self: *RequestPane, arena: Allocator, theme: *const @import("../ui/theme.zig")) Allocator.Error![]editor_view.Span {
        const ed = &(self.resp_editor orelse return &.{});
        return self.resp_syntax.styledSpans(arena, theme, 0, ed.len());
    }

    /// The buffer of the focused text field, for editing keys.
    fn activeBuf(self: *RequestPane) ?struct { buf: *Buf, caret: *usize } {
        return switch (self.field) {
            .url => .{ .buf = &self.url, .caret = &self.url_caret },
            .method => null,
            .content => switch (self.edit_tab) {
                .body => .{ .buf = &self.body, .caret = &self.body_caret },
                .headers => .{ .buf = &self.headers_text, .caret = &self.headers_caret },
                .source => .{ .buf = &self.source, .caret = &self.source_caret },
                .params, .auth, .vars => null,
            },
        };
    }

    /// Enter the request block on `tab`; the caret lands in its content.
    /// In the split, bringing the right half's tab to the left swaps the
    /// halves so both stay visible.
    pub fn showTab(self: *RequestPane, tab: EditTab) void {
        if (self.split and tab == self.split_tab and tab != self.edit_tab) self.split_tab = self.edit_tab;
        self.edit_tab = tab;
        self.block = .request;
        self.field = .content;
        self.row_cursor = 0;
        self.edit_scroll = 0;
    }

    /// `http.toggle_edit_split`: a second half showing another tab.
    pub fn toggleSplit(self: *RequestPane) void {
        self.split = !self.split;
        if (self.split and self.split_tab == self.edit_tab) self.split_tab = if (self.edit_tab == .vars) .body else .vars;
        self.split_scroll = 0;
    }

    /// The text of the focused field and the `{{VAR}}` under its caret.
    pub fn varAtCaret(self: *RequestPane, arena: Allocator) Allocator.Error!?[]const u8 {
        const f = self.activeBuf() orelse return null;
        const at = @min(f.caret.*, f.buf.items.len);
        for (try env_mod.tokens(arena, f.buf.items)) |tok| if (at >= tok.start and at <= tok.end) return tok.name;
        return null;
    }

    /// Replace every `{{name}}` in the three text fields with `value`.
    pub fn inlineVar(self: *RequestPane, name: []const u8, value: []const u8) Allocator.Error!usize {
        var n: usize = 0;
        const bufs = [_]*Buf{ &self.url, &self.headers_text, &self.body };
        for (bufs) |b| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const toks = try env_mod.tokens(arena.allocator(), b.items);
            var i = toks.len;
            while (i > 0) {
                i -= 1;
                if (!std.mem.eql(u8, toks[i].name, name)) continue;
                try b.replaceRange(self.gpa, toks[i].start, toks[i].end - toks[i].start, value);
                n += 1;
            }
        }
        if (n > 0) {
            self.url_caret = @min(self.url_caret, self.url.items.len);
            self.body_caret = @min(self.body_caret, self.body.items.len);
            self.headers_caret = @min(self.headers_caret, self.headers_text.items.len);
            self.edited = true;
            try self.commit();
        }
        return n;
    }

    /// Enter the Request block on the URL (a `Tab` from the response).
    pub fn focusUrl(self: *RequestPane) void {
        self.block = .request;
        self.field = .url;
        self.url_caret = self.url.items.len;
    }

    pub fn startDraft(self: *RequestPane) Allocator.Error!void {
        if (self.draft) |*d| d.deinit(self.gpa);
        self.draft = .{};
        self.edit_tab = .params;
        self.block = .request;
        self.field = .content;
    }

    pub fn cancelDraft(self: *RequestPane) void {
        if (self.draft) |*d| d.deinit(self.gpa);
        self.draft = null;
    }

    /// The draft becomes `?key=value` on the URL.
    pub fn commitDraft(self: *RequestPane) Allocator.Error!bool {
        const d = &(self.draft orelse return false);
        const key = std.mem.trim(u8, d.key.items, " \t");
        if (key.len == 0) {
            self.cancelDraft();
            return false;
        }
        try self.commit();
        try self.request.addParam(self.gpa, key, std.mem.trim(u8, d.value.items, " \t"));
        try self.url.replaceRange(self.gpa, 0, self.url.items.len, self.request.url);
        self.url_caret = self.url.items.len;
        self.cancelDraft();
        self.edited = true;
        try self.refreshTitle();
        return true;
    }

    /// Drop the query parameter at `idx`.
    pub fn removeParam(self: *RequestPane, idx: usize) Allocator.Error!void {
        try self.commit();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ps = try self.request.params(a);
        if (idx >= ps.len) return;
        const base = try self.request.urlWithoutQuery(a);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const hash = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        try out.appendSlice(a, base[0..hash]);
        var first = true;
        for (ps, 0..) |p, i| {
            if (i == idx) continue;
            try out.appendSlice(a, if (first) "?" else "&");
            first = false;
            try out.appendSlice(a, p.key);
            try out.append(a, '=');
            try out.appendSlice(a, p.value);
        }
        try out.appendSlice(a, base[hash..]);
        try self.url.replaceRange(self.gpa, 0, self.url.items.len, out.items);
        self.url_caret = @min(self.url_caret, self.url.items.len);
        try self.commit();
        self.edited = true;
    }
};

// ─── keys ───────────────────────────────────────────────────────────────

/// True when the pane took the key. Chords with ctrl / alt that are not
/// the pane's own fall through to the chord chain.
pub fn handleKey(app: *App, id: PaneId, rp: *RequestPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const gpa = app.gpa;
    // Pane-wide chords.
    if (k.mods.ctrl and !k.mods.alt) switch (k.code) {
        .enter => {
            if (rp.block == .request and rp.field == .content and rp.edit_tab == .source and rp.source.items.len > 0) {
                http.pasteSourceInto(app, id, rp) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                return true;
            }
            http.fire(app, id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
            return true;
        },
        .char => |c| switch (c) {
            ']' => {
                rp.showTab(rp.edit_tab.next());
                return true;
            },
            '[' => {
                rp.showTab(rp.edit_tab.prev());
                return true;
            },
            '1'...'6' => {
                rp.showTab(EditTab.all[c - '1']);
                return true;
            },
            's' => {
                http.saveToSource(app) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
                };
                return true;
            },
            else => {},
        },
        else => {},
    };
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    // A params draft owns Tab (key → value) and Enter (commit).
    if (rp.draft != null and rp.block == .request and (k.code == .tab or k.code == .backtab or k.code == .enter)) return paramsKey(app, rp, k);
    switch (k.code) {
        .tab => {
            if (rp.block == .response) rp.focusUrl() else rp.block = .response;
            return true;
        },
        .backtab => {
            if (rp.block == .response) {
                rp.focusUrl();
                return true;
            }
            rp.field = switch (rp.field) {
                .url => .method,
                .method => .content,
                .content => .url,
            };
            return true;
        },
        .esc => {
            if (rp.draft != null) {
                rp.cancelDraft();
                return true;
            }
            return false;
        },
        else => {},
    }
    if (rp.block == .response) return responseKey(app, rp, k);

    // ── the request block ──
    switch (rp.field) {
        .method => {
            if (k.code == .enter or k.typed() == ' ') {
                try rp.cycleMethod();
                app.toast("method: {s}", .{rp.request.method});
                return true;
            }
            if (k.code == .down or k.code == .up) {
                rp.field = .url;
                return true;
            }
            return false;
        },
        .url => {
            if (k.code == .enter) {
                http.fire(app, id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
                };
                return true;
            }
            if (k.code == .down) {
                rp.field = .content;
                return true;
            }
            const edit = try text_field.handleKey(&rp.url, &rp.url_caret, gpa, k);
            if (edit == .changed) {
                rp.edited = true;
                try rp.commit();
            }
            return edit != .ignored;
        },
        .content => {},
    }
    switch (rp.edit_tab) {
        .body, .headers, .source => {
            const f = rp.activeBuf().?;
            if (k.code == .enter) {
                try text_field.insert(f.buf, f.caret, gpa, "\n");
                rp.edited = true;
                return true;
            }
            if (k.code == .up or k.code == .down) {
                if (k.code == .up and lineOf(f.buf.items, f.caret.*) == 0) {
                    rp.field = .url;
                    return true;
                }
                moveLine(f.buf.items, f.caret, k.code == .down);
                return true;
            }
            const edit = try text_field.handleKey(f.buf, f.caret, gpa, k);
            if (edit == .changed) rp.edited = true;
            return edit != .ignored;
        },
        .params => return paramsKey(app, rp, k),
        .auth => {
            switch (k.code) {
                .up => rp.row_cursor -|= 1,
                .down => rp.row_cursor = @min(rp.row_cursor + 1, view.auth_rows.len - 1),
                .enter => try http.authRowAction(app, id, rp, rp.row_cursor),
                .char => |c| switch (c) {
                    'k' => rp.row_cursor -|= 1,
                    'j' => rp.row_cursor = @min(rp.row_cursor + 1, view.auth_rows.len - 1),
                    else => return false,
                },
                else => return false,
            }
            return true;
        },
        .vars => {
            const n = try http.varCount(app, rp);
            switch (k.code) {
                .up => rp.row_cursor -|= 1,
                .down => rp.row_cursor = @min(rp.row_cursor + 1, n -| 1),
                .enter => try http.varRowAction(app, rp, rp.row_cursor),
                .char => |c| switch (c) {
                    'k' => rp.row_cursor -|= 1,
                    'j' => rp.row_cursor = @min(rp.row_cursor + 1, n -| 1),
                    else => return false,
                },
                else => return false,
            }
            return true;
        },
    }
}

/// Blank-line-delimited events with at least one `data:` line.
pub fn countSseEvents(body: []const u8) usize {
    var n: usize = 0;
    var has_data = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) {
            if (has_data) n += 1;
            has_data = false;
        } else if (std.mem.startsWith(u8, l, "data")) has_data = true;
    }
    return n;
}

fn lineOf(text: []const u8, at: usize) usize {
    var n: usize = 0;
    for (text[0..@min(at, text.len)]) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

/// Move the caret one line up or down, keeping the column.
fn moveLine(text: []const u8, caret: *usize, down: bool) void {
    const at = @min(caret.*, text.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
    const col = at - line_start;
    if (down) {
        const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return;
        const next_start = nl + 1;
        const next_end = std.mem.indexOfScalarPos(u8, text, next_start, '\n') orelse text.len;
        caret.* = @min(next_start + col, next_end);
    } else {
        if (line_start == 0) return;
        const prev_end = line_start - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, text[0..prev_end], '\n')) |i| i + 1 else 0;
        caret.* = @min(prev_start + col, prev_end);
    }
}

fn paramsKey(app: *App, rp: *RequestPane, k: Key) Allocator.Error!bool {
    const gpa = app.gpa;
    if (rp.draft) |*d| {
        switch (k.code) {
            .tab => {
                d.on_value = !d.on_value;
                return true;
            },
            .enter => {
                if (!d.on_value and d.value.items.len == 0 and d.key.items.len > 0) {
                    d.on_value = true;
                    return true;
                }
                if (try rp.commitDraft()) app.toast("params: added", .{});
                return true;
            },
            else => {},
        }
        const buf = if (d.on_value) &d.value else &d.key;
        const caret = if (d.on_value) &d.value_caret else &d.key_caret;
        const edit = try text_field.handleKey(buf, caret, gpa, k);
        return edit != .ignored;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ps = try rp.request.params(arena.allocator());
    switch (k.code) {
        .up => {
            if (rp.row_cursor == 0) rp.field = .url else rp.row_cursor -= 1;
        },
        .down => rp.row_cursor = @min(rp.row_cursor + 1, ps.len -| 1),
        .enter => try rp.startDraft(),
        .delete, .backspace => if (ps.len > 0) {
            try rp.removeParam(@min(rp.row_cursor, ps.len - 1));
            rp.row_cursor = @min(rp.row_cursor, ps.len -| 2);
        },
        .char => |c| switch (c) {
            'a', '+' => try rp.startDraft(),
            'd' => if (ps.len > 0) {
                try rp.removeParam(@min(rp.row_cursor, ps.len - 1));
                rp.row_cursor = @min(rp.row_cursor, ps.len -| 2);
            },
            'k' => rp.row_cursor -|= 1,
            'j' => rp.row_cursor = @min(rp.row_cursor + 1, ps.len -| 1),
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn responseKey(app: *App, rp: *RequestPane, k: Key) Allocator.Error!bool {
    const rows = @max(app.pane_rows, 1);
    switch (k.code) {
        .up => rp.resp_view.scroll_line -|= 1,
        .down => rp.resp_view.scroll_line += 1,
        .page_up => rp.resp_view.scroll_line -|= @intCast(rows),
        .page_down => rp.resp_view.scroll_line += @intCast(rows),
        .home => rp.resp_view.scroll_line = 0,
        .end => rp.resp_view.scroll_line = std.math.maxInt(u32) / 2,
        .left => rp.response_tab = rp.response_tab.prev(),
        .right => rp.response_tab = rp.response_tab.next(),
        .char => |c| switch (c) {
            'k' => rp.resp_view.scroll_line -|= 1,
            'j' => rp.resp_view.scroll_line += 1,
            'g' => rp.resp_view.scroll_line = 0,
            'G' => rp.resp_view.scroll_line = std.math.maxInt(u32) / 2,
            'h', '[' => rp.response_tab = rp.response_tab.prev(),
            'l', ']' => rp.response_tab = rp.response_tab.next(),
            'w' => rp.body_wrap = !rp.body_wrap,
            'r' => {
                http.fire(app, app.active.?) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
                };
            },
            else => return false,
        },
        else => return false,
    }
    clampScroll(rp);
    return true;
}

fn clampScroll(rp: *RequestPane) void {
    const body: []const u8 = if (rp.response()) |r| r.body else if (rp.streaming()) |st| st.body.items else "";
    const total: u32 = @intCast(std.mem.count(u8, body, "\n") + 1);
    if (rp.resp_view.scroll_line >= total) rp.resp_view.scroll_line = total -| 1;
}

/// The wheel over the pane scrolls whichever block is under it — the
/// response body, or the text tab's rows.
pub fn scrollBy(rp: *RequestPane, delta: i32) void {
    if (delta < 0) {
        rp.resp_view.scroll_line -|= @intCast(-delta);
    } else rp.resp_view.scroll_line += @intCast(delta);
    clampScroll(rp);
}

/// Bracketed paste: into the focused field.
pub fn paste(app: *App, rp: *RequestPane, text: []const u8) Allocator.Error!void {
    if (rp.block != .request) return;
    if (rp.draft) |*d| {
        const buf = if (d.on_value) &d.value else &d.key;
        const caret = if (d.on_value) &d.value_caret else &d.key_caret;
        try text_field.insert(buf, caret, app.gpa, text);
        return;
    }
    const f = rp.activeBuf() orelse return;
    // A single-line field takes the first line only.
    const chunk = if (rp.field == .url) (std.mem.sliceTo(text, '\n')) else text;
    try text_field.insert(f.buf, f.caret, app.gpa, std.mem.trimEnd(u8, chunk, "\r"));
    rp.edited = true;
    if (rp.field == .url) try rp.commit();
    app.needs_render = true;
}

// ─── mouse ──────────────────────────────────────────────────────────────

/// A press on one of the view's hits.
pub fn click(app: *App, id: PaneId, rp: *RequestPane, hit_id: u32, m: Mouse, hit_rect: ?Rect) Allocator.Error!void {
    app.needs_render = true;
    // A divider drag: the press armed it, every drag inside the edit
    // area moves it, the release ends it.
    if (rp.dragging_divider) {
        if (m.kind == .release) {
            rp.dragging_divider = false;
            return;
        }
        if (m.kind == .drag) {
            if (rp.edit_area) |area| if (area.w > 0) {
                const ratio: u32 = @as(u32, m.x -| area.x) * 100 / area.w;
                rp.split_ratio = @intCast(std.math.clamp(ratio, 10, 90));
            };
            return;
        }
    }
    if (m.kind != .press) return;
    if (hit_id >= view.hit_var_base) return http.varClick(app, id, rp, hit_id - view.hit_var_base, m);
    if (hit_id >= view.hit_tab_base and hit_id < view.hit_tab_base + EditTab.all.len) {
        rp.showTab(EditTab.all[hit_id - view.hit_tab_base]);
        return;
    }
    if (hit_id >= view.hit_split_tab_base and hit_id < view.hit_split_tab_base + EditTab.all.len) {
        const tab = EditTab.all[hit_id - view.hit_split_tab_base];
        if (tab == rp.edit_tab) rp.edit_tab = rp.split_tab;
        rp.split_tab = tab;
        rp.split_scroll = 0;
        return;
    }
    switch (hit_id) {
        view.hit_split_toggle => {
            rp.toggleSplit();
            return;
        },
        view.hit_split_divider => {
            if (m.button == .left) rp.dragging_divider = true;
            return;
        },
        view.hit_split_content => {
            rp.showTab(rp.split_tab);
            return;
        },
        view.hit_edit_area => {
            rp.block = .request;
            // The edit area's own field: the tab being edited.
            if (m.button == .right) try @import("context_menus.zig").openRequestFieldMenu(app, if (rp.edit_tab == .headers) .headers else .body, m.x, m.y);
            return;
        },
        else => {},
    }
    if (hit_id >= view.hit_resp_tab_base and hit_id < view.hit_resp_tab_base + ResponseTab.all.len) {
        rp.response_tab = ResponseTab.all[hit_id - view.hit_resp_tab_base];
        rp.block = .response;
        return;
    }
    if (hit_id >= view.hit_param_row and hit_id < view.hit_param_row + 100) {
        rp.showTab(.params);
        rp.row_cursor = hit_id - view.hit_param_row;
        return;
    }
    if (hit_id >= view.hit_auth_row and hit_id < view.hit_auth_row + 100) {
        rp.showTab(.auth);
        rp.row_cursor = hit_id - view.hit_auth_row;
        try http.authRowAction(app, id, rp, rp.row_cursor);
        return;
    }
    if (hit_id >= view.hit_var_row and hit_id < view.hit_var_row + 100) {
        rp.showTab(.vars);
        rp.row_cursor = hit_id - view.hit_var_row;
        return;
    }
    switch (hit_id) {
        view.hit_method => {
            rp.block = .request;
            rp.field = .method;
            if (m.button == .left) {
                try rp.cycleMethod();
                app.toast("method: {s}", .{rp.request.method});
            }
        },
        view.hit_url => {
            rp.block = .request;
            rp.field = .url;
            if (m.button == .right) {
                try @import("context_menus.zig").openRequestFieldMenu(app, .url, m.x, m.y);
                return;
            }
            if (hit_rect) |r| {
                const col: usize = m.x -| r.x;
                rp.url_caret = byteAtCol(rp.url.items, col);
            }
        },
        view.hit_send => http.fire(app, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
        },
        view.hit_env => @import("cmd_http.zig").pickEnvCmd(app) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        view.hit_wrap => rp.body_wrap = !rp.body_wrap,
        view.hit_resp_body => {
            rp.block = .response;
            if (m.button == .right) try @import("context_menus.zig").openRequestFieldMenu(app, .response, m.x, m.y);
        },
        view.hit_draft_key, view.hit_draft_value => {
            if (rp.draft == null) try rp.startDraft();
            rp.draft.?.on_value = hit_id == view.hit_draft_value;
        },
        view.hit_content => {
            rp.block = .request;
            rp.field = .content;
            if (m.button == .right) try @import("context_menus.zig").openRequestFieldMenu(app, if (rp.edit_tab == .headers) .headers else .body, m.x, m.y);
        },
        else => {},
    }
}

fn byteAtCol(text: []const u8, col: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < text.len and c < col) : (c += 1) i = text_field.nextCp(text, i);
    return i;
}

// ─── the frame ──────────────────────────────────────────────────────────

/// Assemble the view's model on the frame arena and paint.
pub fn draw(app: *App, ui: Ui, id: PaneId, rp: *RequestPane, area: Rect) Allocator.Error!void {
    const arena = ui.arena;
    const focused = app.active == id and app.focus == .pane;
    var params_list: std.ArrayListUnmanaged(view.Pair) = .empty;
    {
        // Params read the URL buffer live, not the committed request.
        var tmp = try Request.init(arena);
        try tmp.setUrl(arena, rp.url.items);
        for (try tmp.params(arena)) |p| try params_list.append(arena, .{ .key = p.key, .value = p.value });
    }
    const draft: ?view.Draft = if (rp.draft) |d| .{ .key = d.key.items, .value = d.value.items, .key_caret = d.key_caret, .value_caret = d.value_caret, .on_value = d.on_value } else null;
    const auth_current: ?[]const u8 = blk: {
        var lines = std.mem.splitScalar(u8, rp.headers_text.items, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trim(u8, l, " \t\r");
            if (std.ascii.startsWithIgnoreCase(t, "authorization:")) break :blk std.mem.trim(u8, t["authorization:".len..], " \t");
        }
        break :blk null;
    };
    const env_name = try http.envName(app, arena);
    const vars = try http.varRows(app, rp, arena, env_name);
    const toks = try http.varTokens(app, rp, arena, env_name);
    var resp_model: ?view.ResponseModel = null;
    var stream_info: ?view.StreamInfo = null;
    if (rp.streaming()) |st| {
        const r = &st.head;
        const hs = try arena.alloc(view.Pair, r.headers.len);
        for (r.headers, 0..) |h, i| hs[i] = .{ .key = h.name, .value = h.value };
        stream_info = .{ .bytes = st.body.items.len, .events = st.events, .is_sse = st.is_sse, .elapsed_ms = @intCast(@max(app.now_ms - st.started_ms, 0)) };
        resp_model = .{
            .status = r.status,
            .status_text = r.status_text,
            .headers = hs,
            .body = st.body.items,
            .body_bytes = st.body.items.len,
            .truncated = false,
            .timing = .{ .wait_ms = 0, .receive_ms = 0, .total_ms = 0 },
            .cookies = try r.setCookies(arena),
        };
    }
    if (rp.response()) |r| {
        const hs = try arena.alloc(view.Pair, r.headers.len);
        for (r.headers, 0..) |h, i| hs[i] = .{ .key = h.name, .value = h.value };
        const tests = try arena.alloc([]const u8, rp.tests.items.len);
        for (rp.tests.items, 0..) |t, i| tests[i] = t;
        resp_model = .{
            .status = r.status,
            .status_text = r.status_text,
            .headers = hs,
            .body = r.body,
            .body_bytes = r.body.len,
            .truncated = r.truncated,
            .timing = .{ .wait_ms = r.timing.wait_ms, .receive_ms = r.timing.receive_ms, .total_ms = r.timing.total_ms },
            .cookies = try r.setCookies(arena),
            .spans = try rp.responseSpans(arena, &app.theme),
            .tests = tests,
            .footer = if (rp.tests.items.len > 0) rp.tests.items[0] else null,
        };
    }
    const m: view.Model = .{
        .method = rp.request.method,
        .url = rp.url.items,
        .url_caret = rp.url_caret,
        .block = rp.block,
        .field = rp.field,
        .edit_tab = rp.edit_tab,
        .body = rp.body.items,
        .body_caret = rp.body_caret,
        .headers_text = rp.headers_text.items,
        .headers_caret = rp.headers_caret,
        .source = rp.source.items,
        .source_caret = rp.source_caret,
        .params = params_list.items,
        .draft = draft,
        .row_cursor = rp.row_cursor,
        .auth_current = auth_current,
        .vars = vars,
        .env_name = env_name,
        .edit_scroll = &rp.edit_scroll,
        .sending = rp.isSending(),
        .failed = if (rp.state == .failed) rp.state.failed else null,
        .response = resp_model,
        .stream = stream_info,
        .sent_line = rp.sent_line,
        .response_tab = rp.response_tab,
        .resp_view = &rp.resp_view,
        .body_wrap = rp.body_wrap,
        .focused = focused,
        .source_path = rp.source_path,
        .url_vars = toks.url,
        .body_vars = toks.body,
        .headers_vars = toks.headers,
        .split = if (rp.split) .{ .tab = rp.split_tab, .ratio = rp.split_ratio, .scroll = &rp.split_scroll } else null,
        .orientation = rp.orientation,
    };
    const caret = view.draw(ui, id, area, m);
    const z = view.zones(area, m);
    rp.edit_area = if (z.request.h > 2) Rect.init(z.request.x, z.request.y + 2, z.request.w, z.request.h - 2) else null;
    if (app.active == id) {
        app.pane_rows = @max(area.h, 1);
        app.pane_cols = @max(area.w, 1);
        if (focused) if (caret) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        };
    }
    // A hovered `{{VAR}}` shows its value.
    if (http.hoveredVar(ui, id, view.hit_var_base)) |hv| if (hv.idx < toks.all.len) {
        const tok = toks.all[hv.idx];
        view.drawVarTip(ui, area, hv.rect, tok.name, tok.shown, env_name);
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "load / commit round-trip; the title follows method and url; params draft commits to the URL" {
    var rp = try RequestPane.init(testing.allocator);
    defer rp.deinit();
    try testing.expectEqualStrings("new request", rp.title());
    var req = try parse.parse(testing.allocator, "curl -X POST 'https://x/a?k=1' -H 'A: 1' --data-raw '{}'");
    try rp.load(req);
    req = undefined;
    try testing.expectEqualStrings("POST  https://x/a?k=1", rp.title());
    try testing.expectEqualStrings("A: 1\n", rp.headers_text.items);
    try testing.expectEqualStrings("{}", rp.body.items);
    try rp.headers_text.appendSlice(testing.allocator, "B: 2\n");
    try rp.commit();
    try testing.expectEqualStrings("2", rp.request.header("b").?);
    try rp.startDraft();
    try rp.draft.?.key.appendSlice(testing.allocator, "userid");
    try rp.draft.?.value.appendSlice(testing.allocator, "42");
    try testing.expect(try rp.commitDraft());
    try testing.expectEqualStrings("https://x/a?k=1&userid=42", rp.url.items);
    try rp.removeParam(0);
    try testing.expectEqualStrings("https://x/a?userid=42", rp.url.items);
    try rp.cycleMethod();
    try testing.expectEqualStrings("PUT", rp.request.method);
    try testing.expect(std.mem.startsWith(u8, rp.title(), "PUT  "));
}

test "moveLine keeps the column and stops at the edges" {
    const text = "abc\nde\nfghij";
    var caret: usize = 2; // 'c'
    moveLine(text, &caret, true);
    try testing.expectEqual(@as(usize, 6), caret); // end of "de"
    moveLine(text, &caret, true);
    try testing.expectEqual(@as(usize, 9), caret); // "fg|hij" col 2
    moveLine(text, &caret, true);
    try testing.expectEqual(@as(usize, 9), caret);
    moveLine(text, &caret, false);
    try testing.expectEqual(@as(usize, 6), caret);
    moveLine(text, &caret, false);
    try testing.expectEqual(@as(usize, 2), caret);
    moveLine(text, &caret, false);
    try testing.expectEqual(@as(usize, 2), caret);
}

test "split: toggling picks a second tab; showing the right tab swaps the halves; the pair survives off and on" {
    var rp = try RequestPane.init(testing.allocator);
    defer rp.deinit();
    var req = try parse.parse(testing.allocator, "curl 'https://{{HOST}}/a' -H 'A: {{T}}'");
    try rp.load(req);
    req = undefined;
    rp.edit_tab = .body;
    try testing.expect(!rp.split);
    rp.toggleSplit();
    try testing.expect(rp.split and rp.split_tab == .vars);
    // Bringing the right half's tab to the left swaps the halves.
    rp.showTab(.vars);
    try testing.expect(rp.edit_tab == .vars and rp.split_tab == .body);
    // Any other tab on the left leaves the right half alone.
    rp.showTab(.headers);
    try testing.expect(rp.edit_tab == .headers and rp.split_tab == .body);
    rp.toggleSplit();
    try testing.expect(!rp.split);
    // Off and on again keeps the pair as long as the halves differ.
    rp.toggleSplit();
    try testing.expect(rp.split and rp.split_tab == .body);
    rp.split_ratio = 30;
    try testing.expectEqual(@as(u8, 30), rp.split_ratio);
}

test "varAtCaret finds the token under the URL caret; inlineVar replaces every occurrence across the fields" {
    var rp = try RequestPane.init(testing.allocator);
    defer rp.deinit();
    var req = try parse.parse(testing.allocator, "curl 'https://{{HOST}}/a' -H 'A: {{T}}'");
    try rp.load(req);
    req = undefined;
    // The var under the URL caret; none past its end.
    rp.field = .url;
    rp.url_caret = 9;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("HOST", (try rp.varAtCaret(arena.allocator())).?);
    rp.url_caret = 16;
    try testing.expectEqualStrings("HOST", (try rp.varAtCaret(arena.allocator())).?);
    rp.url_caret = 17;
    try testing.expect((try rp.varAtCaret(arena.allocator())) == null);
    // Inlining replaces every occurrence across the three fields and commits.
    try testing.expectEqual(@as(usize, 1), try rp.inlineVar("HOST", "x.test"));
    try testing.expectEqualStrings("https://x.test/a", rp.url.items);
    try testing.expectEqual(@as(usize, 1), try rp.inlineVar("T", "1"));
    try testing.expectEqualStrings("A: 1\n", rp.headers_text.items);
    try testing.expectEqualStrings("1", rp.request.header("a").?);
    try testing.expectEqual(@as(usize, 0), try rp.inlineVar("NOPE", "z"));
    try testing.expect(rp.edited);
}
