//! The request pane's face: a Request block (method chip + URL row, the
//! six-tab edit strip, the tab's content), a Response block (its own
//! tab strip, the status chip, the body through `editor_view`), and an
//! AI strip at the bottom. Paints a plain `Model` the app assembles —
//! this file never sees `App`, `Buffer` or a request object.
//!
//! Hits are `.script_hit{ pane, id }`; the ids are the `hit_*` consts
//! below, and rows add their index to a base.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const editor_view = @import("editor_view.zig");
const ids = @import("../core/ids.zig");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;
pub const Caret = text_field.Caret;
pub const PaneId = ids.PaneId;

pub const EditTab = enum {
    body,
    headers,
    params,
    auth,
    vars,
    source,

    pub const all = [_]EditTab{ .body, .headers, .params, .auth, .vars, .source };

    pub fn label(t: EditTab) []const u8 {
        return switch (t) {
            .body => "Body",
            .headers => "Headers",
            .params => "Params",
            .auth => "Auth",
            .vars => "Vars",
            .source => "Script",
        };
    }

    pub fn next(t: EditTab) EditTab {
        return all[(@intFromEnum(t) + 1) % all.len];
    }

    pub fn prev(t: EditTab) EditTab {
        return all[(@intFromEnum(t) + all.len - 1) % all.len];
    }

    /// A tab whose content is a text buffer the caret lives in.
    pub fn isText(t: EditTab) bool {
        return t == .body or t == .headers or t == .source;
    }
};

pub const ResponseTab = enum {
    body,
    headers,
    cookies,
    timeline,
    tests,

    pub const all = [_]ResponseTab{ .body, .headers, .cookies, .timeline, .tests };

    pub fn label(t: ResponseTab) []const u8 {
        return switch (t) {
            .body => "Body",
            .headers => "Headers",
            .cookies => "Cookies",
            .timeline => "Timeline",
            .tests => "Tests",
        };
    }

    pub fn next(t: ResponseTab) ResponseTab {
        return all[(@intFromEnum(t) + 1) % all.len];
    }

    pub fn prev(t: ResponseTab) ResponseTab {
        return all[(@intFromEnum(t) + all.len - 1) % all.len];
    }
};

/// Which block the keyboard is in.
pub const Block = enum { request, response };

/// Which field of the request block has the caret.
pub const Field = enum { url, method, content };

pub const Pair = struct { key: []const u8, value: []const u8 };

/// The inline key / value row being typed on the Params or Headers tab.
pub const Draft = struct {
    key: []const u8,
    value: []const u8,
    key_caret: usize,
    value_caret: usize,
    on_value: bool,
};

pub const AuthRow = struct { id: []const u8, label: []const u8, glyph: []const u8 };

pub const auth_rows = [_]AuthRow{
    .{ .id = "set_bearer", .label = "Set Bearer token…", .glyph = "+" },
    .{ .id = "set_basic", .label = "Set Basic auth…", .glyph = "+" },
    .{ .id = "set_api_key", .label = "Set X-Api-Key…", .glyph = "+" },
    .{ .id = "clear", .label = "Clear Authorization", .glyph = "×" },
};

pub const VarRow = struct { name: []const u8, value: ?[]const u8 };

pub const Timing = struct { wait_ms: u64, receive_ms: u64, total_ms: u64 };

/// A body still arriving: the live counter on the Response header.
pub const StreamInfo = struct { bytes: usize, events: usize, is_sse: bool, elapsed_ms: u64 };

pub const ResponseModel = struct {
    status: u16,
    status_text: []const u8,
    headers: []const Pair,
    body: []const u8,
    body_bytes: usize,
    truncated: bool,
    timing: Timing,
    cookies: []const []const u8,
    /// Syntax spans over `body`, sorted, non-overlapping.
    spans: []const editor_view.Span = &.{},
    /// `✓ schema valid` / `✗ 2 schema error(s)` / assertion lines.
    tests: []const []const u8 = &.{},
    footer: ?[]const u8 = null,
};

pub const Model = struct {
    method: []const u8,
    url: []const u8,
    url_caret: usize,
    block: Block,
    field: Field,
    edit_tab: EditTab,
    body: []const u8,
    body_caret: usize,
    headers_text: []const u8,
    headers_caret: usize,
    source: []const u8,
    source_caret: usize,
    params: []const Pair,
    draft: ?Draft,
    /// Cursor over the Params / Auth / Vars rows.
    row_cursor: usize,
    /// The current Authorization header's value, if any.
    auth_current: ?[]const u8,
    vars: []const VarRow,
    env_name: ?[]const u8,
    /// Scroll of the text tabs' content (rows).
    edit_scroll: *usize,
    sending: bool,
    failed: ?[]const u8,
    response: ?ResponseModel,
    /// Set while the response is streaming in; `response` then holds
    /// the head and the body so far.
    stream: ?StreamInfo = null,
    /// `GET https://…` as actually sent.
    sent_line: ?[]const u8,
    response_tab: ResponseTab,
    resp_view: *editor_view.ViewState,
    body_wrap: bool,
    focused: bool,
    source_path: ?[]const u8,
    ai_hint: []const u8 = "ask Claude about this request — lands in Phase 7",
};

// ── hit ids ──
pub const hit_tab_base: u32 = 1; // + EditTab index
pub const hit_method: u32 = 10;
pub const hit_url: u32 = 11;
pub const hit_send: u32 = 12;
pub const hit_env: u32 = 13;
pub const hit_wrap: u32 = 14;
pub const hit_resp_tab_base: u32 = 20; // + ResponseTab index
pub const hit_resp_body: u32 = 30;
pub const hit_param_row: u32 = 100; // + row
pub const hit_auth_row: u32 = 200; // + row
pub const hit_var_row: u32 = 300; // + row
pub const hit_draft_key: u32 = 400;
pub const hit_draft_value: u32 = 401;
pub const hit_content: u32 = 402;

pub const ai_rows: u16 = 2;
pub const min_request_rows: u16 = 5;

/// The status chip's colours by class.
pub fn statusStyle(t: *const Theme, status: u16) Style {
    const ink: Color = .{ .rgb = .{ 0x1e, 0x22, 0x27 } };
    const bg: Color = switch (status / 100) {
        2 => .{ .rgb = .{ 0x98, 0xc3, 0x79 } },
        3 => t.info_fg.fg,
        4 => t.warn_fg.fg,
        5 => t.error_fg.fg,
        else => t.muted.fg,
    };
    return .{ .fg = ink, .bg = bg, .bold = true };
}

/// How the pane splits: the request block, the response block, the AI
/// strip. The request block takes what its content needs up to 45 %.
pub const Zones = struct { request: Rect, response: Rect, ai: Rect };

pub fn zones(area: Rect, m: Model) Zones {
    var rest = area;
    var ai = Rect.empty;
    if (rest.h >= min_request_rows + ai_rows + 3) {
        const s = rest.splitBottom(ai_rows);
        ai = s.rest;
        rest = s.top;
    }
    const content_rows: u16 = switch (m.edit_tab) {
        .body => @intCast(@min(std.mem.count(u8, m.body, "\n") + 2, 12)),
        .headers => @intCast(@min(std.mem.count(u8, m.headers_text, "\n") + 2, 12)),
        .source => @intCast(@min(std.mem.count(u8, m.source, "\n") + 2, 12)),
        .params => @intCast(@min(m.params.len + 2, 12)),
        .auth => 6,
        .vars => @intCast(@min(m.vars.len + 2, 12)),
    };
    const want: u16 = 3 + @max(content_rows, 3); // header + tabs + content
    const cap: u16 = @max(rest.h * 45 / 100, min_request_rows);
    const req_h: u16 = @min(@min(want, cap), rest.h);
    const s = rest.splitTop(req_h);
    return .{ .request = s.top, .response = s.rest, .ai = ai };
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, m: Model) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return null;
    const z = zones(area, m);
    var caret: ?Caret = null;
    if (drawRequest(ui, pane, z.request, m)) |c| caret = c;
    drawResponse(ui, pane, z.response, m);
    drawAi(ui, z.ai, m);
    return if (m.focused) caret else null;
}

fn drawRequest(ui: Ui, pane: PaneId, r: Rect, m: Model) ?Caret {
    const t = ui.theme;
    if (r.h == 0) return null;
    const active_block = m.focused and m.block == .request;
    var caret: ?Caret = null;

    // ── row 0: method chip · URL · Send ──
    const row0 = r.row(0);
    ui.fill(row0, t.bg);
    var x = row0.x + 1;
    const method_label = ui.fmt(" {s} ", .{m.method});
    const mw = ui.width(method_label);
    const method_style: Style = if (active_block and m.field == .method) Theme.onBg(t.chip_active, t.chip_active.bg) else t.chip;
    var ms = method_style;
    ms.bold = true;
    _ = ui.putStr(x, row0.y, mw, method_label, ms);
    ui.hit(Rect.init(x, row0.y, mw, 1), .{ .script_hit = .{ .pane = pane, .id = hit_method } });
    x += mw + 1;
    const send_label: []const u8 = if (m.sending) " ⋯ " else if (ui.ascii) " Send " else " Send ⏎ ";
    const sw = ui.width(send_label);
    const url_w = row0.right() -| (x + sw + 2);
    const url_rect = Rect.init(x, row0.y, url_w, 1);
    const url_focused = active_block and m.field == .url;
    const url_style = if (url_focused) Theme.onBg(t.fg, t.cursor_line.bg) else t.fg;
    if (text_field.draw(ui, url_rect, m.url, m.url_caret, .{ .style = url_style, .placeholder = "https://… (press Ctrl+Enter to send)", .focused = url_focused })) |c| caret = c;
    ui.hit(url_rect, .{ .script_hit = .{ .pane = pane, .id = hit_url } });
    if (row0.w > sw + mw + 6) {
        const sx = row0.right() - sw - 1;
        const send_style = Theme.onBg(t.accent, t.chip.bg);
        _ = ui.putStr(sx, row0.y, sw, send_label, send_style);
        ui.hit(Rect.init(sx, row0.y, sw, 1), .{ .script_hit = .{ .pane = pane, .id = hit_send } });
    }
    if (r.h == 1) return caret;

    // ── row 1: the edit tab strip + env chip ──
    const row1 = r.row(1);
    ui.fill(row1, t.bg);
    x = row1.x + 1;
    for (EditTab.all, 0..) |tab, i| {
        const active = tab == m.edit_tab;
        const label = if (active) ui.fmt("[{s}]", .{tab.label()}) else ui.fmt(" {s} ", .{tab.label()});
        const w = ui.width(label);
        if (x + w > row1.right()) break;
        var st = if (active) t.accent else t.muted;
        if (active) st.bold = true;
        _ = ui.putStr(x, row1.y, w, label, st);
        ui.hit(Rect.init(x, row1.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_tab_base + @as(u32, @intCast(i)) } });
        x += w + 1;
    }
    if (m.env_name) |env| {
        const chip = ui.fmt(" env: {s} ", .{env});
        const cw = ui.width(chip);
        if (row1.right() > x + cw + 1) {
            const cx = row1.right() - cw - 1;
            _ = ui.putStr(cx, row1.y, cw, chip, t.chip);
            ui.hit(Rect.init(cx, row1.y, cw, 1), .{ .script_hit = .{ .pane = pane, .id = hit_env } });
        }
    }
    if (r.h == 2) return caret;

    // ── rows 2..: the tab's content ──
    const content = Rect.init(r.x, r.y + 2, r.w, r.h - 2);
    const content_focused = active_block and m.field == .content;
    switch (m.edit_tab) {
        .body => if (drawTextArea(ui, pane, content, m.body, m.body_caret, content_focused, m.edit_scroll, "(request body — type here, Ctrl+Enter sends)")) |c| {
            caret = c;
        },
        .headers => if (drawTextArea(ui, pane, content, m.headers_text, m.headers_caret, content_focused, m.edit_scroll, "(Name: value per line)")) |c| {
            caret = c;
        },
        .source => {
            _ = ui.putStr(content.x + 1, content.y, content.w -| 2, ui.clipStr("Source — type / paste curl or .http here · :http.paste_source (Ctrl+Enter)", content.w -| 2), t.muted);
            if (content.h > 1) {
                const inner = Rect.init(content.x, content.y + 1, content.w, content.h - 1);
                if (drawTextArea(ui, pane, inner, m.source, m.source_caret, content_focused, m.edit_scroll, "")) |c| caret = c;
            }
        },
        .params => if (drawParams(ui, pane, content, m, content_focused)) |c| {
            caret = c;
        },
        .auth => drawAuth(ui, pane, content, m, content_focused),
        .vars => drawVars(ui, pane, content, m, content_focused),
    }
    return caret;
}

/// A multi-line buffer: rows from `scroll`, the caret's row kept on
/// screen. Returns the caret cell when focused.
fn drawTextArea(ui: Ui, pane: PaneId, r: Rect, text: []const u8, caret: usize, focused: bool, scroll: *usize, placeholder: []const u8) ?Caret {
    const t = ui.theme;
    if (r.isEmpty()) return null;
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = hit_content } });
    if (text.len == 0) {
        _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(placeholder, r.w -| 1), t.muted);
        return if (focused) .{ .x = r.x + 1, .y = r.y } else null;
    }
    // Line of the caret.
    const at = @min(caret, text.len);
    var caret_line: usize = 0;
    var line_start: usize = 0;
    for (text[0..at], 0..) |c, i| if (c == '\n') {
        caret_line += 1;
        line_start = i + 1;
    };
    const rows: usize = r.h;
    if (caret_line < scroll.*) scroll.* = caret_line;
    if (caret_line >= scroll.* + rows) scroll.* = caret_line + 1 - rows;
    var out: ?Caret = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var y: u16 = 0;
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < scroll.*) continue;
        if (y >= r.h) break;
        const row = r.row(y);
        const lx = row.x + 1;
        const lw = row.w -| 1;
        if (line_no == caret_line) {
            if (focused) ui.fill(row, t.cursor_line);
            const col_bytes = at - line_start;
            const before = line[0..@min(col_bytes, line.len)];
            const cw = ui.width(before);
            // Scroll the line left when the caret is past the width.
            var shown = line;
            var cx = cw;
            if (cw >= lw and lw > 0) {
                var drop: usize = 0;
                var dropped_w: u16 = 0;
                while (cx >= lw and drop < before.len) {
                    const step = text_field.nextCp(before, drop) - drop;
                    dropped_w += ui.width(before[drop .. drop + step]);
                    drop += step;
                    cx = cw - dropped_w;
                }
                shown = line[drop..];
            }
            _ = ui.putStr(lx, row.y, lw, ui.clipStr(shown, lw), if (focused) Theme.onBg(t.fg, t.cursor_line.bg) else t.fg);
            if (focused) out = .{ .x = lx + @min(cx, lw -| 1), .y = row.y };
        } else {
            _ = ui.putStr(lx, row.y, lw, ui.clipStr(line, lw), t.fg);
        }
        y += 1;
    }
    return out;
}

fn drawParams(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool) ?Caret {
    const t = ui.theme;
    if (r.isEmpty()) return null;
    var caret: ?Caret = null;
    const key_w: u16 = @min(@max(r.w / 3, 8), 32);
    var y: u16 = 0;
    for (m.params, 0..) |p, i| {
        if (y >= r.h) break;
        const row = r.row(y);
        const sel = focused and m.draft == null and i == m.row_cursor;
        if (sel) ui.fill(row, t.cursor_line);
        const bg = if (sel) t.cursor_line.bg else t.bg.bg;
        _ = ui.putStr(row.x + 1, row.y, key_w, ui.clipStr(p.key, key_w), Theme.onBg(t.accent, bg));
        _ = ui.putStr(row.x + 1 + key_w + 1, row.y, row.w -| (key_w + 3), ui.clipStr(p.value, row.w -| (key_w + 3)), Theme.onBg(t.fg, bg));
        ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_param_row + @as(u32, @intCast(i)) } });
        y += 1;
    }
    if (y < r.h) {
        const row = r.row(y);
        if (m.draft) |d| {
            ui.fill(row, t.cursor_line);
            const key_rect = Rect.init(row.x + 1, row.y, key_w, 1);
            const val_rect = Rect.init(row.x + 1 + key_w + 1, row.y, row.w -| (key_w + 3), 1);
            const key_focused = focused and !d.on_value;
            const val_focused = focused and d.on_value;
            if (text_field.draw(ui, key_rect, d.key, d.key_caret, .{ .style = Theme.onBg(t.accent, t.cursor_line.bg), .placeholder = "(name)", .focused = key_focused })) |c| caret = c;
            if (text_field.draw(ui, val_rect, d.value, d.value_caret, .{ .style = Theme.onBg(t.fg, t.cursor_line.bg), .placeholder = "(value)", .focused = val_focused })) |c| caret = c;
            ui.hit(key_rect, .{ .script_hit = .{ .pane = pane, .id = hit_draft_key } });
            ui.hit(val_rect, .{ .script_hit = .{ .pane = pane, .id = hit_draft_value } });
        } else {
            const label = if (m.params.len == 0) "+ Add new parameter… (a)   ·   the URL has no query string" else "+ Add new parameter… (a)   ·   d deletes the row";
            _ = ui.putStr(row.x + 1, row.y, row.w -| 1, ui.clipStr(label, row.w -| 1), t.muted);
            ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_draft_key } });
        }
    }
    return caret;
}

fn drawAuth(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool) void {
    const t = ui.theme;
    if (r.isEmpty()) return;
    const cur = m.auth_current orelse "(none)";
    const shown = if (cur.len > 60) ui.fmt("{s}…", .{cur[0..58]}) else cur;
    _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(ui.fmt("Current:  {s}", .{shown}), r.w -| 1), t.muted);
    var y: u16 = 1;
    for (auth_rows, 0..) |row_def, i| {
        if (y >= r.h) break;
        const row = r.row(y);
        const sel = focused and i == m.row_cursor;
        if (sel) ui.fill(row, t.cursor_line);
        const bg = if (sel) t.cursor_line.bg else t.bg.bg;
        _ = ui.putStr(row.x + 1, row.y, 2, row_def.glyph, Theme.onBg(t.accent, bg));
        _ = ui.putStr(row.x + 3, row.y, row.w -| 3, ui.clipStr(row_def.label, row.w -| 3), Theme.onBg(t.fg, bg));
        ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_auth_row + @as(u32, @intCast(i)) } });
        y += 1;
    }
}

fn drawVars(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool) void {
    const t = ui.theme;
    if (r.isEmpty()) return;
    if (m.vars.len == 0) {
        _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr("no {{VAR}} references in this request", r.w -| 1), t.muted);
        return;
    }
    const key_w: u16 = @min(@max(r.w / 3, 8), 32);
    var y: u16 = 0;
    for (m.vars, 0..) |v, i| {
        if (y >= r.h) break;
        const row = r.row(y);
        const sel = focused and i == m.row_cursor;
        if (sel) ui.fill(row, t.cursor_line);
        const bg = if (sel) t.cursor_line.bg else t.bg.bg;
        _ = ui.putStr(row.x + 1, row.y, key_w, ui.clipStr(ui.fmt("{{{{{s}}}}}", .{v.name}), key_w), Theme.onBg(if (v.value != null) t.info_fg else t.error_fg, bg));
        const value = v.value orelse "not defined in active env";
        _ = ui.putStr(row.x + 1 + key_w + 1, row.y, row.w -| (key_w + 3), ui.clipStr(value, row.w -| (key_w + 3)), Theme.onBg(if (v.value != null) t.fg else t.muted, bg));
        ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_var_row + @as(u32, @intCast(i)) } });
        y += 1;
    }
}

fn drawResponse(ui: Ui, pane: PaneId, r: Rect, m: Model) void {
    const t = ui.theme;
    if (r.isEmpty()) return;
    ui.fill(r, t.bg);
    const active_block = m.focused and m.block == .response;
    // ── header: tab strip + status chip ──
    const head = r.row(0);
    ui.fill(head, t.panel_bg);
    var x = head.x + 1;
    for (ResponseTab.all, 0..) |tab, i| {
        const active = tab == m.response_tab;
        const label = if (active) ui.fmt("[{s}]", .{tab.label()}) else ui.fmt(" {s} ", .{tab.label()});
        const w = ui.width(label);
        if (x + w > head.right()) break;
        var st = Theme.onBg(if (active) t.accent else t.muted, t.panel_bg.bg);
        if (active and active_block) st.bold = true;
        _ = ui.putStr(x, head.y, w, label, st);
        ui.hit(Rect.init(x, head.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_resp_tab_base + @as(u32, @intCast(i)) } });
        x += w + 1;
    }
    var right = head.right() -| 1;
    if (m.response) |resp| {
        const chip = ui.fmt(" {d} ", .{resp.status});
        const cw = ui.width(chip);
        const meta = if (m.stream) |st|
            (if (st.is_sse) ui.fmt(" streaming · {d} event(s) · {s} · {d} ms ", .{ st.events, fmtBytes(ui, st.bytes), st.elapsed_ms }) else ui.fmt(" streaming · {s} received · {d} ms ", .{ fmtBytes(ui, st.bytes), st.elapsed_ms }))
        else
            ui.fmt(" {s} · {d} ms · {s}{s} ", .{ resp.status_text, resp.timing.total_ms, fmtBytes(ui, resp.body_bytes), if (resp.truncated) " (truncated)" else "" });
        const metaw = ui.width(meta);
        if (right > x + cw + metaw + 6) {
            right = ui.putStrRight(right, head.y, metaw, meta, Theme.onBg(if (m.stream != null) t.warn_fg else t.muted, t.panel_bg.bg));
            const cx = right -| cw;
            _ = ui.putStr(cx, head.y, cw, chip, statusStyle(t, resp.status));
            right = cx -| 1;
        } else if (right > x + cw + 2) {
            const cx = right -| cw;
            _ = ui.putStr(cx, head.y, cw, chip, statusStyle(t, resp.status));
            right = cx -| 1;
        }
        const wrap_chip: []const u8 = if (m.body_wrap) " wrap ✓ " else " wrap ";
        const ww = ui.width(wrap_chip);
        if (right > x + ww + 2) {
            const wx = right -| ww;
            _ = ui.putStr(wx, head.y, ww, wrap_chip, Theme.onBg(if (m.body_wrap) t.accent else t.muted, t.panel_bg.bg));
            ui.hit(Rect.init(wx, head.y, ww, 1), .{ .script_hit = .{ .pane = pane, .id = hit_wrap } });
        }
    } else if (m.sending) {
        const label = " sending… ";
        _ = ui.putStrRight(right, head.y, ui.width(label), label, Theme.onBg(t.warn_fg, t.panel_bg.bg));
    } else if (m.failed != null) {
        const label = " failed ";
        _ = ui.putStrRight(right, head.y, ui.width(label), label, .{ .fg = .{ .rgb = .{ 0x1e, 0x22, 0x27 } }, .bg = t.error_fg.fg, .bold = true });
    }
    if (r.h == 1) return;
    const body_area = Rect.init(r.x, r.y + 1, r.w, r.h - 1);
    ui.hit(body_area, .{ .script_hit = .{ .pane = pane, .id = hit_resp_body } });

    if (m.response == null) {
        var y: u16 = body_area.y;
        if (m.sent_line) |line| {
            _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(line, body_area.w -| 1), t.muted);
            y += 1;
        }
        if (m.failed) |msg| {
            if (y < body_area.bottom()) _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(ui.fmt("✗ {s}", .{msg}), body_area.w -| 1), t.error_fg);
            return;
        }
        const hint: []const u8 = if (m.sending) "sending…" else "no response yet — press Ctrl+Enter (or the Send chip) to send";
        const hw = @min(ui.width(hint), body_area.w -| 2);
        const hy = body_area.y + body_area.h / 2;
        _ = ui.putStr(body_area.x + (body_area.w -| hw) / 2, hy, hw, ui.clipStr(hint, hw), t.muted);
        return;
    }
    const resp = m.response.?;
    switch (m.response_tab) {
        .body => {
            const doc: editor_view.Doc = .{
                .text = resp.body,
                .cursor = 0,
                .anchor = null,
                .spans = resp.spans,
                .wrap = m.body_wrap,
                .tab_width = 4,
                .line_numbers = false,
                .focused = false,
                .scrollbar = true,
            };
            m.resp_view.pinAt(0);
            var text_rect = body_area;
            if (resp.footer) |f| if (text_rect.h >= 3) {
                const s = text_rect.splitBottom(1);
                text_rect = s.top;
                _ = ui.putStr(s.rest.x + 1, s.rest.y, s.rest.w -| 1, ui.clipStr(f, s.rest.w -| 1), t.muted);
            };
            _ = editor_view.draw(ui, pane, text_rect, m.resp_view, doc);
        },
        .headers => {
            var y: u16 = body_area.y;
            if (m.sent_line) |line| {
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(line, body_area.w -| 1), t.muted);
                y += 1;
            }
            const first = m.resp_view.scroll_line;
            for (resp.headers, 0..) |h, i| {
                if (i < first) continue;
                if (y >= body_area.bottom()) break;
                const kx = body_area.x + 1;
                const kw = ui.putStr(kx, y, body_area.w -| 1, ui.fmt("{s}: ", .{h.key}), t.accent);
                _ = ui.putStr(kx + kw, y, body_area.w -| (1 + kw), ui.clipStr(h.value, body_area.w -| (1 + kw)), t.fg);
                y += 1;
            }
        },
        .cookies => {
            var y: u16 = body_area.y;
            if (resp.cookies.len == 0) {
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, "no Set-Cookie headers in this response", t.muted);
                return;
            }
            for (resp.cookies) |c| {
                if (y >= body_area.bottom()) break;
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(c, body_area.w -| 1), t.fg);
                y += 1;
            }
        },
        .timeline => {
            const lines = [_][]const u8{
                ui.fmt("wait     {d} ms   (send → first byte of the head)", .{resp.timing.wait_ms}),
                ui.fmt("receive  {d} ms   (head → body complete)", .{resp.timing.receive_ms}),
                ui.fmt("total    {d} ms", .{resp.timing.total_ms}),
                ui.fmt("size     {s}", .{fmtBytes(ui, resp.body_bytes)}),
            };
            var y: u16 = body_area.y;
            for (lines) |l| {
                if (y >= body_area.bottom()) break;
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(l, body_area.w -| 1), t.fg);
                y += 1;
            }
        },
        .tests => {
            var y: u16 = body_area.y;
            if (resp.tests.len == 0) {
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr("no assertions — add `# @assert status == 200` lines, or a sibling <name>.schema.json", body_area.w -| 1), t.muted);
                return;
            }
            for (resp.tests) |line| {
                if (y >= body_area.bottom()) break;
                const style = if (std.mem.startsWith(u8, line, "✓")) t.info_fg else if (std.mem.startsWith(u8, line, "✗")) t.error_fg else t.fg;
                _ = ui.putStr(body_area.x + 1, y, body_area.w -| 1, ui.clipStr(line, body_area.w -| 1), style);
                y += 1;
            }
        },
    }
}

fn drawAi(ui: Ui, r: Rect, m: Model) void {
    const t = ui.theme;
    if (r.isEmpty()) return;
    const head = r.row(0);
    ui.fill(head, t.panel_bg);
    _ = ui.putStr(head.x + 1, head.y, head.w -| 1, " AI ", Theme.onBg(t.accent, t.panel_bg.bg));
    if (r.h > 1) {
        const row = r.row(1);
        _ = ui.putStr(row.x + 1, row.y, row.w -| 1, ui.clipStr(m.ai_hint, row.w -| 1), t.muted);
    }
}

pub fn fmtBytes(ui: Ui, n: usize) []const u8 {
    if (n < 1024) return ui.fmt("{d} B", .{n});
    if (n < 1024 * 1024) return ui.fmt("{d}.{d} KB", .{ n / 1024, (n % 1024) * 10 / 1024 });
    return ui.fmt("{d}.{d} MB", .{ n / (1024 * 1024), (n % (1024 * 1024)) * 10 / (1024 * 1024) });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @import("test_fixture.zig");

test "tabs cycle both ways and the labels are the six the strip paints" {
    try testing.expectEqual(EditTab.headers, EditTab.body.next());
    try testing.expectEqual(EditTab.body, EditTab.source.next());
    try testing.expectEqual(EditTab.source, EditTab.body.prev());
    try testing.expectEqualStrings("Script", EditTab.source.label());
    try testing.expectEqual(ResponseTab.tests, ResponseTab.body.prev());
    try testing.expect(EditTab.source.isText() and !EditTab.params.isText());
}

test "draw: method chip, tabs, status chip and the AI strip land; hits registered" {
    var fx = try fixture.init(100, 30);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    const resp: ResponseModel = .{
        .status = 418,
        .status_text = "I'm a teapot",
        .headers = &.{.{ .key = "content-type", .value = "text/plain" }},
        .body = "teapot",
        .body_bytes = 6,
        .truncated = false,
        .timing = .{ .wait_ms = 1, .receive_ms = 2, .total_ms = 3 },
        .cookies = &.{},
    };
    const m: Model = .{
        .method = "POST",
        .url = "https://x/y",
        .url_caret = 3,
        .block = .request,
        .field = .url,
        .edit_tab = .params,
        .body = "",
        .body_caret = 0,
        .headers_text = "",
        .headers_caret = 0,
        .source = "",
        .source_caret = 0,
        .params = &.{.{ .key = "a", .value = "1" }},
        .draft = .{ .key = "", .value = "", .key_caret = 0, .value_caret = 0, .on_value = false },
        .row_cursor = 0,
        .auth_current = null,
        .vars = &.{},
        .env_name = "dev",
        .edit_scroll = &scroll,
        .sending = false,
        .failed = null,
        .response = resp,
        .sent_line = "POST https://x/y",
        .response_tab = .body,
        .resp_view = &view,
        .body_wrap = false,
        .focused = true,
        .source_path = null,
    };
    const ui = fx.ui();
    const caret = draw(ui, 3, ui.canvas.full(), m);
    try testing.expect(caret != null);
    const txt = try fx.text();
    try testing.expect(std.mem.indexOf(u8, txt, " POST ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Params]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(value)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "env: dev") != null);
    try testing.expect(std.mem.indexOf(u8, txt, " 418 ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "teapot") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\n  AI") != null);
    // the Send chip and the Headers tab are hits
    var found_send = false;
    var found_tab = false;
    for (fx.hits.items.items) |h| switch (h.target) {
        .script_hit => |s| {
            if (s.id == hit_send) found_send = true;
            if (s.id == hit_tab_base + 1) found_tab = true;
        },
        else => {},
    };
    try testing.expect(found_send and found_tab);
}
