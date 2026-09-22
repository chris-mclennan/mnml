//! The request pane's face — the Rust editor's `request_view.rs`, cell
//! for cell against `docs/ui-spec/rust-request-120x40.txt`:
//!
//! ```text
//! ┌ Method ────┐┌ URL ────────────────────────────────────────┐┌ Send ──┐
//! │  GET     ▼ ││ https://httpbin.org/get                     ││ ▶ Send │
//! └────────────┘└─────────────────────────────────────────────┘└────────┘
//! ┌─────────────────────────────────────────────────────[⇔]─[A ▥ ▤]─┐
//! │  Params  Body  Headers  Auth  Vars  Script                      │
//! │          ━━━━                                                   │
//! │ 1                                                               │
//! └─────────────────────────────────────────────────────────────────┘
//! ┌───────────────────────────────────────────── 200 OK  · 2ms · 49 B ┐
//! │  Body  Headers 5  Cookies  Timeline  Tests      wrap   copy   JSON ▼  │
//! │  ━━━━                                                           │
//! │                                                                 │
//! │ 1 {                                                             │
//! └─────────────────────────────────────────────────────────────────┘
//! ┌ AI ─────────────────────────────────────────────────────────────┐
//! │ click here to ask a custom question   · `a` quick debug         │
//! └─────────────────────────────────────────────────────────────────┘
//! ```
//!
//! A blank row, then the top bar of bordered boxes (Method / URL /
//! Send; from 95 cells also Env / Save / Clear / Copy as…; under 44
//! Method and URL alone), then the Request box — its tab strip with a
//! `━` bar under the active tab, the tab's content — and the Response
//! box (its own strip, the status title on its top border once a
//! response is in), stacked, or side by side from 100 cells, and the
//! AI box at the bottom. Paints a plain `Model` the app assembles —
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
const overlay = @import("overlay.zig");
const parse_mod = @import("../http/parse.zig");
const text_field = @import("text_field.zig");
const editor_view = @import("editor_view.zig");
const find_mod = @import("../app/find.zig");
const border = @import("border.zig");
const ids = @import("../core/ids.zig");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;
pub const Caret = text_field.Caret;
pub const PaneId = ids.PaneId;

pub const EditTab = enum {
    params,
    body,
    headers,
    auth,
    vars,
    source,

    /// Rust's strip order.
    pub const all = [_]EditTab{ .params, .body, .headers, .auth, .vars, .source };

    pub fn label(t: EditTab) []const u8 {
        return switch (t) {
            .params => "Params",
            .body => "Body",
            .headers => "Headers",
            .auth => "Auth",
            .vars => "Vars",
            .source => "Script",
        };
    }

    fn index(t: EditTab) usize {
        for (all, 0..) |x, i| if (x == t) return i;
        unreachable;
    }

    pub fn next(t: EditTab) EditTab {
        return all[(t.index() + 1) % all.len];
    }

    pub fn prev(t: EditTab) EditTab {
        return all[(t.index() + all.len - 1) % all.len];
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

/// The inline key / value row being typed on the Params tab.
pub const Draft = struct {
    key: []const u8,
    value: []const u8,
    key_caret: usize,
    value_caret: usize,
    on_value: bool,
};

pub const AuthRow = struct { id: []const u8, label: []const u8, glyph: []const u8 };

pub const auth_rows = [_]AuthRow{
    .{ .id = "set_bearer", .label = "Set Bearer token\u{2026}", .glyph = "+" },
    .{ .id = "set_basic", .label = "Set Basic auth (user:pass)\u{2026}", .glyph = "+" },
    .{ .id = "set_api_key", .label = "Set X-Api-Key\u{2026}", .glyph = "+" },
    .{ .id = "clear", .label = "Clear Authorization", .glyph = "\u{00D7}" },
};

/// The `── Options ──` rows under the auth rows: the block's transport
/// directives, in the settings overlay's row idiom (`▸ label:  [on] /
/// off  *`, the `*` when the block sets it). Hits are `hit_auth_row +
/// auth_rows.len + i`.
pub const OptionRow = struct {
    kind: Kind,
    label: []const u8,
    pub const Kind = enum { verify_tls, timeout, follow_redirects, max_redirects, proxy };
};

pub const option_rows = [_]OptionRow{
    .{ .kind = .verify_tls, .label = "Verify TLS" },
    .{ .kind = .timeout, .label = "Timeout" },
    .{ .kind = .follow_redirects, .label = "Follow redirects" },
    .{ .kind = .max_redirects, .label = "Max redirects" },
    .{ .kind = .proxy, .label = "Proxy" },
};

/// Every row of the Auth tab the cursor can land on.
pub fn authRowCount() usize {
    return auth_rows.len + option_rows.len;
}

/// What a send would use, and which rows the block sets itself (the
/// others show the config default).
pub const OptionsModel = struct {
    insecure: bool = false,
    timeout_ms: ?u64 = null,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    proxy: ?[]const u8 = null,
    set: [option_rows.len]bool = .{false} ** option_rows.len,
};

pub const VarRow = struct { name: []const u8, value: ?[]const u8 };

pub const Timing = struct { wait_ms: u64, receive_ms: u64, total_ms: u64 };

/// A body still arriving: the live counter on the Response header.
pub const StreamInfo = struct { bytes: usize, events: usize, is_sse: bool, elapsed_ms: u64 };

/// A `{{VAR}}` token inside a field's text: painted in the variable
/// role when the active env resolves it, the error role when it does
/// not, and registered as `hit_var_base + id` so a click or a hover
/// finds it.
pub const VarSpan = struct { start: usize, end: usize, resolved: bool, id: u32 };

/// The side-by-side edit view: the right half shows `tab`, `ratio` is
/// the left half's share in percent, `scroll` its own row offset.
pub const SplitModel = struct { tab: EditTab, ratio: u8, scroll: *usize };

/// How the Request and Response blocks share the pane — Rust's
/// `SplitOrientation`: `auto` stacks under 100 cells and goes side by
/// side from there.
pub const Orientation = enum {
    auto,
    vertical,
    horizontal,

    pub const auto_horizontal_threshold: u16 = 100;

    pub fn next(o: Orientation) Orientation {
        return switch (o) {
            .auto => .vertical,
            .vertical => .horizontal,
            .horizontal => .auto,
        };
    }

    pub fn label(o: Orientation) []const u8 {
        return switch (o) {
            .auto => "auto",
            .vertical => "vertical (stacked)",
            .horizontal => "horizontal (side by side)",
        };
    }

    pub fn resolve(o: Orientation, w: u16) Orientation {
        return switch (o) {
            .auto => if (w >= auto_horizontal_threshold) .horizontal else .vertical,
            else => o,
        };
    }
};

pub const ResponseModel = struct {
    status: u16,
    status_text: []const u8,
    headers: []const Pair,
    body: []const u8,
    /// The size the title shows: the body as it came off the wire.
    body_bytes: usize,
    truncated: bool,
    timing: Timing,
    cookies: []const []const u8,
    /// Syntax spans over `body`, sorted, non-overlapping.
    spans: []const editor_view.Span = &.{},
    /// `✓ schema valid` / `✗ 2 schema error(s)` / assertion lines.
    tests: []const []const u8 = &.{},
    /// The request headers as they went out (directives, expansion and
    /// the `http_request` hook applied) — the Timeline tab lists them.
    sent_headers: []const Pair = &.{},
    /// The Headers tab as `name: value` lines — what its search runs
    /// over, drawn from this text so the match offsets line up.
    headers_text: []const u8 = "",
    /// The response search's matches over `body` (the Body tab) or
    /// `headers_text` (Headers), sorted; painted as an editor's are.
    matches: []const find_mod.Range = &.{},
    current_match: ?usize = null,
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
    /// `# @description …` and `# @tags a b`: a row under the URL row
    /// when either is set (item 15).
    description: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// The Body tab's mode (`# @body-type`): the chip on the strip's
    /// right, painted when the tab has the keyboard or the mode is
    /// not `raw`.
    body_type: parse_mod.BodyType = .raw,
    /// The URL's `:name` path segments with their `# @path` values —
    /// the `Path` group above `Query` on the Params tab; the row
    /// cursor runs down both.
    path_params: []const Pair = &.{},
    /// The Headers tab's rows, from its text; `header_value_offs` is each
    /// value's byte offset in that text, so `headers_vars` land in the cell.
    headers: []const Pair = &.{},
    header_value_offs: []const usize = &.{},
    /// `?` on a Headers row: the tip painted under the cursor row.
    header_tip: ?[]const u8 = null,
    draft: ?Draft,
    /// Cursor over the Params / Auth / Vars rows.
    row_cursor: usize,
    /// The current Authorization header's value, if any.
    auth_current: ?[]const u8,
    options: OptionsModel = .{},
    vars: []const VarRow,
    env_name: ?[]const u8,
    /// The env came from a session override (the Env box paints cyan).
    env_override: bool = false,
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
    /// The focused text field is being edited: the caret shows. Off,
    /// the pane is browsed and no caret paints (a draft row keeps its own).
    editing: bool = true,
    source_path: ?[]const u8,
    /// `{{VAR}}` tokens per text field; `id`s index one flat list the
    /// app keeps beside the model.
    url_vars: []const VarSpan = &.{},
    body_vars: []const VarSpan = &.{},
    headers_vars: []const VarSpan = &.{},
    split: ?SplitModel = null,
    orientation: Orientation = .auto,

    /// Never fired: Rust's "not sent yet" placeholder state.
    pub fn idle(m: Model) bool {
        return m.response == null and !m.sending and m.failed == null and m.stream == null;
    }

    /// A URL `{{VAR}}` the env does not resolve (the Env box paints yellow).
    fn urlUnresolved(m: Model) bool {
        for (m.url_vars) |v| if (!v.resolved) return true;
        return false;
    }
};

// ── hit ids ──
pub const hit_tab_base: u32 = 1; // + EditTab index
pub const hit_method: u32 = 10;
pub const hit_url: u32 = 11;
pub const hit_send: u32 = 12;
pub const hit_env: u32 = 13;
pub const hit_wrap: u32 = 14;
pub const hit_split_toggle: u32 = 15;
pub const hit_split_divider: u32 = 16;
pub const hit_resp_tab_base: u32 = 20; // + ResponseTab index
pub const hit_resp_body: u32 = 30;
pub const hit_split_tab_base: u32 = 40; // + EditTab index (the right half's strip)
/// The Request box's `[A ▥ ▤]` chip: the next orientation.
pub const hit_orient: u32 = 50;
/// The AI box, and the response strip's `⚡ AI` chip.
pub const hit_ai: u32 = 51;
pub const hit_ai_chip: u32 = 52;
/// The response strip's `copy` chip and its type chip.
pub const hit_copy: u32 = 53;
pub const hit_type: u32 = 54;
/// The top bar's Save / Clear / Copy as… boxes.
pub const hit_save: u32 = 55;
pub const hit_clear: u32 = 56;
pub const hit_code: u32 = 57;
/// The Body tab's mode chip (`[raw] JSON form multipart`).
pub const hit_body_type: u32 = 58;
pub const hit_param_row: u32 = 100; // + row
pub const hit_auth_row: u32 = 200; // + row
pub const hit_var_row: u32 = 300; // + row
pub const hit_draft_key: u32 = 400;
pub const hit_draft_value: u32 = 401;
pub const hit_content: u32 = 402;
/// The whole edit area under the tab strip — what a divider drag lands on.
pub const hit_edit_area: u32 = 403;
/// The right half's text content: a click there swaps the halves.
pub const hit_split_content: u32 = 404;
/// The Params table's `+ Add row` and the draft row's `✓`.
pub const hit_add_row: u32 = 405;
pub const hit_draft_commit: u32 = 406;
/// A Params row's `✕`.
pub const hit_param_del: u32 = 500; // + row
/// A Headers row, and its `✕`.
pub const hit_header_row: u32 = 600; // + row
pub const hit_header_del: u32 = 700; // + row
pub const hit_path_row: u32 = 800; // + row
pub const hit_var_base: u32 = 1000; // + VarSpan.id

/// The status chip's colours by class (the HTTP panel's recent rows).
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

// ─── layout ─────────────────────────────────────────────────────────────

/// Which boxes the top bar has room for — Rust's `TopBarTier`.
pub const Tier = enum { full, medium, small, none };

const method_w: u16 = 14;
const min_url_w: u16 = 20;
const env_w: u16 = 14;
const send_w: u16 = 10;
const save_w: u16 = 10;
const clear_w: u16 = 11;
const code_w: u16 = 16;
const full_w: u16 = method_w + min_url_w + env_w + send_w + save_w + clear_w + code_w;
const medium_w: u16 = method_w + min_url_w + send_w;
const small_w: u16 = method_w + min_url_w;

pub fn tierFor(w: u16, h: u16) Tier {
    if (h < 3) return .none;
    if (w >= full_w) return .full;
    if (w >= medium_w) return .medium;
    if (w >= small_w) return .small;
    return .none;
}

/// The pane's zones: a blank row (from 8 rows), the top bar, the
/// description row when the block has one (from 12 rows), the two
/// blocks, the AI box — Rust's `draw` geometry.
pub const Zones = struct { top: Rect, desc: ?Rect = null, request: Rect, response: Rect, ai: Rect, tier: Tier };

pub fn zones(area: Rect, m: Model) Zones {
    const pad: u16 = if (area.h >= 8) 1 else 0;
    const top_h: u16 = @min(3, area.h -| pad);
    const desc_h: u16 = if ((m.description != null or m.tags.len > 0) and area.h >= 12) 1 else 0;
    const ai_h: u16 = @min(3, area.h -| pad -| top_h -| desc_h);
    const middle: u16 = area.h -| pad -| top_h -| desc_h -| ai_h;
    const top = Rect.init(area.x, area.y + pad, area.w, top_h);
    const desc: ?Rect = if (desc_h > 0) Rect.init(area.x, area.y + pad + top_h, area.w, 1) else null;
    const ai = Rect.init(area.x, area.y + pad + top_h + desc_h + middle, area.w, ai_h);
    const mid_y = area.y + pad + top_h + desc_h;
    var request: Rect = undefined;
    var response: Rect = undefined;
    switch (m.orientation.resolve(area.w)) {
        .horizontal => {
            const req_w = area.w / 2;
            request = Rect.init(area.x, mid_y, req_w, middle);
            response = Rect.init(area.x + req_w, mid_y, area.w - req_w, middle);
        },
        else => {
            const req_h = @max(middle / 2, @min(6, middle));
            request = Rect.init(area.x, mid_y, area.w, req_h);
            response = Rect.init(area.x, mid_y + req_h, area.w, middle - req_h);
        },
    }
    return .{ .top = top, .desc = desc, .request = request, .response = response, .ai = ai, .tier = tierFor(top.w, top.h) };
}

/// `  ▸ description text     #tag #tag`: the description dim and in
/// italics, the tags in the accent at the row's end.
fn drawDescRow(ui: Ui, r: Rect, m: Model) void {
    const p = ui.theme.palette;
    var x = r.x + 2;
    var tag_w: u16 = 0;
    for (m.tags) |t| tag_w += ui.width(t) + 2;
    const text_end = if (tag_w > 0) r.right() -| (tag_w + 1) else r.right();
    if (m.description) |d| {
        x += ui.putStr(x, r.y, text_end -| x, if (ui.ascii) "> " else "\u{25B8} ", .{ .fg = p.comment, .bg = p.bg_dark });
        _ = ui.putStr(x, r.y, text_end -| x, ui.clipStr(d, text_end -| x), .{ .fg = p.comment, .bg = p.bg_dark, .italic = true });
    }
    if (tag_w == 0) return;
    var tx = r.right() -| tag_w;
    for (m.tags) |t| {
        tx += ui.putStr(tx, r.y, r.right() -| tx, ui.fmt("#{s} ", .{t}), .{ .fg = p.cyan, .bg = p.bg_dark });
        tx += 1;
    }
}

/// Where the Request box's edit content is (under its strip), for the
/// app's divider drag.
pub fn editArea(area: Rect, m: Model) ?Rect {
    const inner = zones(area, m).request.inset(1);
    if (inner.h <= 2 or inner.w == 0) return null;
    return Rect.init(inner.x, inner.y + 2, inner.w, inner.h - 2);
}

// ─── boxes ──────────────────────────────────────────────────────────────

fn frameStyle(ui: Ui) Style {
    const p = ui.theme.palette;
    return .{ .fg = p.bg3, .bg = p.bg_dark };
}

/// Rust's `bordered_plain(title)`: a plain frame in `bg3`, the title
/// ` title ` in the comment colour on the top edge; the inner rect.
fn box(ui: Ui, r: Rect, title: []const u8) Rect {
    const p = ui.theme.palette;
    if (r.isEmpty()) return r.inset(1);
    ui.fill(r, .{ .bg = p.bg_dark });
    const kind: border.Kind = if (ui.ascii) .ascii else .single;
    if (title.len == 0) return border.draw(ui.canvas, r, kind, frameStyle(ui), null);
    const segs = [_]border.Segment{.{ .text = ui.fmt(" {s} ", .{title}), .style = .{ .fg = p.comment, .bg = p.bg_dark } }};
    return border.draw(ui.canvas, r, kind, frameStyle(ui), &segs);
}

/// A one-row box whose text is centred — the Send / Save / Clear /
/// Copy as… boxes.
fn labelBox(ui: Ui, pane: PaneId, r: Rect, title: []const u8, text: []const u8, color: Color, hit: u32) void {
    const p = ui.theme.palette;
    const inner = box(ui, r, title);
    if (inner.isEmpty()) return;
    const w = ui.width(text);
    const x = inner.x + (inner.w -| w) / 2;
    _ = ui.putStr(x, inner.y, inner.right() -| x, text, .{ .fg = color, .bg = p.bg_dark, .bold = true });
    ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit } });
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, m: Model) ?Caret {
    const p = ui.theme.palette;
    ui.fill(area, .{ .bg = p.bg_dark });
    if (area.isEmpty()) return null;
    const z = zones(area, m);
    const url_caret = drawTopBar(ui, pane, z, m);
    if (z.desc) |d| drawDescRow(ui, d, m);
    const edit_caret = drawRequestBox(ui, pane, z.request, m);
    drawResponseBox(ui, pane, z.response, m);
    drawAiBox(ui, pane, z.ai);
    if (!m.focused) return null;
    if (!m.editing and m.draft == null) return null;
    // The URL box's caret wins when both are set (the pane's default
    // focus is the URL).
    return url_caret orelse edit_caret;
}

// ─── the top bar ────────────────────────────────────────────────────────

/// `[Method][URL][Env][Send][Save][Clear][Copy as…]` across the top,
/// fewer boxes as the pane narrows.
fn drawTopBar(ui: Ui, pane: PaneId, z: Zones, m: Model) ?Caret {
    const p = ui.theme.palette;
    const r = z.top;
    if (z.tier == .none) return null;
    const y = r.y;
    var caret: ?Caret = null;
    const method_r = Rect.init(r.x, y, method_w, r.h);
    const tail: u16 = switch (z.tier) {
        .full => env_w + send_w + save_w + clear_w + code_w,
        .medium => send_w,
        .small, .none => 0,
    };
    const url_w = r.w -| method_w -| tail;
    const url_r = Rect.init(r.x + method_w, y, url_w, r.h);
    // Method: the verb as a chip in its colour, a `▼` at the right.
    {
        const inner = box(ui, method_r, "Method");
        if (!inner.isEmpty()) {
            const chip = ui.fmt(" {s} ", .{m.method});
            var x = inner.x + 1;
            x += ui.putStr(x, inner.y, inner.right() -| x, chip, .{ .fg = p.bg_dark, .bg = methodColor(p, m.method), .bold = true });
            if (inner.right() >= 2) _ = ui.putStr(inner.right() - 2, inner.y, 1, "\u{25BC}", .{ .fg = p.comment, .bg = p.bg_dark });
            ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit_method } });
        }
    }
    // URL: the text one cell in, its `{{VAR}}`s in their colours.
    {
        const inner = box(ui, url_r, "URL");
        if (!inner.isEmpty() and inner.w > 1) {
            const field = Rect.init(inner.x + 1, inner.y, inner.w - 1, 1);
            const focused = m.focused and m.block == .request and m.field == .url;
            const style: Style = .{ .fg = p.fg, .bg = p.bg_dark };
            ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit_url } });
            if (m.url.len == 0) {
                _ = ui.putStr(field.x, field.y, field.w, "Enter request URL", .{ .fg = p.comment, .bg = p.bg_dark, .italic = true });
                if (focused) caret = .{ .x = field.x, .y = field.y };
            } else {
                if (text_field.draw(ui, field, m.url, m.url_caret, .{ .style = style, .placeholder = "", .focused = focused })) |c| caret = c;
                paintVarsOnField(ui, pane, field, m.url, if (focused) m.url_caret else 0, m.url_vars, p.bg_dark);
            }
        }
    }
    if (z.tier == .small) return caret;
    var x = url_r.right();
    if (z.tier == .full) {
        // Env: the name, `▾`; yellow with an unresolved URL var, cyan
        // under a session override.
        const inner = box(ui, Rect.init(x, y, env_w, r.h), "Env");
        if (!inner.isEmpty()) {
            const name = m.env_name orelse "none";
            const short = if (ui.width(name) > 6) ui.fmt("{s}\u{2026}", .{ui.clipStr(name, 5)}) else name;
            const text = ui.fmt(" {s} \u{25BE} ", .{short});
            const color = if (m.urlUnresolved()) p.yellow else if (m.env_name == null) p.comment else if (m.env_override) p.cyan else p.fg;
            const w = ui.width(text);
            const tx = inner.x + (inner.w -| w) / 2;
            _ = ui.putStr(tx, inner.y, inner.right() -| tx, text, .{ .fg = color, .bg = p.bg_dark, .bold = true });
            ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit_env } });
        }
        x += env_w;
    }
    // Send: `▶ Send` — green when there is a URL, dim without one,
    // `⟳  Abort` in yellow while a send is out.
    {
        const url_empty = std.mem.trim(u8, m.url, " \t").len == 0;
        const text: []const u8 = if (m.sending or m.stream != null) " \u{27F3}  Abort " else if (ui.ascii) " > Send " else " \u{25B6} Send ";
        const color = if (m.sending) p.yellow else if (m.stream != null) p.cyan else if (url_empty) p.comment else p.green;
        labelBox(ui, pane, Rect.init(x, y, send_w, r.h), "Send", text, color, hit_send);
        x += send_w;
    }
    if (z.tier == .full) {
        const url_empty = std.mem.trim(u8, m.url, " \t").len == 0;
        labelBox(ui, pane, Rect.init(x, y, save_w, r.h), "Save", " \u{2398} Save ", if (url_empty) p.comment else p.blue, hit_save);
        x += save_w;
        labelBox(ui, pane, Rect.init(x, y, clear_w, r.h), "Clear", " \u{2715} Clear ", p.orange, hit_clear);
        x += clear_w;
        labelBox(ui, pane, Rect.init(x, y, code_w, r.h), "Copy as\u{2026}", " </> Copy as\u{2026} ", p.purple, hit_code);
    }
    return caret;
}

/// The method's colour — Rust's `method_color`: GET green, POST orange,
/// PUT blue, PATCH cyan, DELETE red, HEAD yellow, OPTIONS purple.
pub fn methodColor(p: Theme.Palette, m: []const u8) Color {
    const Row = struct { name: []const u8, color: Color };
    const rows = [_]Row{
        .{ .name = "GET", .color = p.green },      .{ .name = "POST", .color = p.orange }, .{ .name = "PUT", .color = p.blue },
        .{ .name = "PATCH", .color = p.cyan },     .{ .name = "DELETE", .color = p.red },  .{ .name = "HEAD", .color = p.yellow },
        .{ .name = "OPTIONS", .color = p.purple },
    };
    for (rows) |r| if (std.ascii.eqlIgnoreCase(r.name, m)) return r.color;
    return p.blue;
}

// ─── the Request box ────────────────────────────────────────────────────

fn drawRequestBox(ui: Ui, pane: PaneId, r: Rect, m: Model) ?Caret {
    const p = ui.theme.palette;
    if (r.isEmpty()) return null;
    const inner = box(ui, r, "");
    // The chips on the top border: `[A ▥ ▤]` two cells in from the
    // corner, `[⇔]` one cell left of it.
    if (r.w >= 7 + 4) {
        const ox = r.right() - 7 - 2;
        const bracket: Style = .{ .fg = p.bg3, .bg = p.bg_dark };
        const on: Style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true };
        const off: Style = .{ .fg = p.comment, .bg = p.bg_dark };
        const ground: Style = .{ .bg = p.bg_dark };
        var x = ox;
        x += ui.putStr(x, r.y, 1, "[", bracket);
        x += ui.putStr(x, r.y, 1, "A", if (m.orientation == .auto) on else off);
        x += ui.putStr(x, r.y, 1, " ", ground);
        x += ui.putStr(x, r.y, 1, if (ui.ascii) "-" else "\u{25A5}", if (m.orientation == .vertical) on else off);
        x += ui.putStr(x, r.y, 1, " ", ground);
        x += ui.putStr(x, r.y, 1, if (ui.ascii) "|" else "\u{25A4}", if (m.orientation == .horizontal) on else off);
        _ = ui.putStr(x, r.y, 1, "]", bracket);
        ui.hit(Rect.init(ox, r.y, 7, 1), .{ .script_hit = .{ .pane = pane, .id = hit_orient } });
        if (ox > r.x + 4) {
            const sx = ox - 3 - 1;
            _ = ui.putStr(sx, r.y, 1, "[", bracket);
            _ = ui.putStr(sx + 1, r.y, 1, if (ui.ascii) "=" else "\u{21D4}", if (m.split != null) on else off);
            _ = ui.putStr(sx + 2, r.y, 1, "]", bracket);
            ui.hit(Rect.init(sx, r.y, 3, 1), .{ .script_hit = .{ .pane = pane, .id = hit_split_toggle } });
        }
    }
    if (inner.isEmpty()) return null;
    ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit_edit_area } });
    const focused = m.focused and m.block == .request and m.field == .content;
    const split = m.split orelse return drawEdit(ui, pane, inner, m.edit_tab, m, focused, m.edit_scroll, false);
    // Side by side from 49 cells: each half its own strip.
    const min_side: u16 = 24;
    if (inner.w <= min_side * 2) return drawEdit(ui, pane, inner, m.edit_tab, m, focused, m.edit_scroll, false);
    const raw: u16 = @intCast(@as(u32, inner.w) * std.math.clamp(split.ratio, 10, 90) / 100);
    const left_w: u16 = @min(@max(raw, min_side), inner.w - min_side - 1);
    const left = Rect.init(inner.x, inner.y, left_w, inner.h);
    const divider = Rect.init(inner.x + left_w, inner.y, 1, inner.h);
    const right = Rect.init(inner.x + left_w + 1, inner.y, inner.w - left_w - 1, inner.h);
    const caret = drawEdit(ui, pane, left, m.edit_tab, m, focused, m.edit_scroll, false);
    ui.vrule(divider.x, divider.y, divider.h, .{ .fg = p.bg3, .bg = p.bg_dark });
    ui.hit(divider, .{ .script_hit = .{ .pane = pane, .id = hit_split_divider } });
    _ = drawEdit(ui, pane, right, split.tab, m, false, split.scroll, true);
    return caret;
}

/// The strip and one tab's content into `r` — Rust's `draw_edit`.
/// `secondary` is the split's right half: no caret, its strip on the
/// `hit_split_tab_base` ids, its text area on `hit_split_content`.
fn drawEdit(ui: Ui, pane: PaneId, r: Rect, tab: EditTab, m: Model, focused: bool, scroll: *usize, secondary: bool) ?Caret {
    const p = ui.theme.palette;
    if (r.isEmpty()) return null;
    // Row 0 the labels from column 2, two cells apart; row 1 the `━`
    // under the active one.
    var x = r.x + 2;
    for (EditTab.all, 0..) |t, i| {
        const label = t.label();
        const w = ui.width(label);
        if (x + w > r.right()) break;
        const cur = t == tab;
        _ = ui.putStr(x, r.y, w, label, if (cur) .{ .fg = p.fg, .bg = p.bg_dark, .bold = true } else .{ .fg = p.comment, .bg = p.bg_dark });
        if (cur and r.h > 1) {
            var k: u16 = 0;
            while (k < w) : (k += 1) _ = ui.putStr(x + k, r.y + 1, 1, if (ui.ascii) "=" else "\u{2501}", .{ .fg = p.yellow, .bg = p.bg_dark, .bold = true }); // chrome-audit: allow — the active tab's underline (a heavy bar, not a rule); core has no tab-strip component
        }
        ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = (if (secondary) hit_split_tab_base else hit_tab_base) + @as(u32, @intCast(i)) } });
        x += w + 2;
    }
    // The Body tab's mode chip at the strip's right edge — the settings
    // idiom, the current mode bracketed — when the tab has the keyboard
    // or the mode is anything but raw (so the default screen is Rust's).
    if (tab == .body and !secondary and (focused or m.body_type != .raw)) drawBodyTypeChip(ui, pane, r, x, m.body_type);
    if (r.h <= 2) return null;
    const content = Rect.init(r.x, r.y + 2, r.w, r.h - 2);
    const content_hit = if (secondary) hit_split_content else hit_content;
    switch (tab) {
        .body => {
            const c = drawBody(ui, pane, content, m, focused, scroll, content_hit);
            drawSendState(ui, content, m, linesOf(m.body) -| scroll.*);
            return c;
        },
        .headers => {
            // The same table Params paints, over the tab's `Name: value`
            // lines; the `{{VAR}}` spans land in the value cells.
            const t = drawKvTable(ui, pane, content, m.headers, if (secondary) null else m.draft, .{
                .kind = .headers,
                .row_hit = hit_header_row,
                .del_hit = hit_header_del,
                .add = !secondary,
                .cursor = m.row_cursor,
                .focused = focused,
                .value_offs = m.header_value_offs,
                .vars = m.headers_vars,
                .tip = if (secondary) null else m.header_tip,
            });
            drawSendState(ui, content, m, t.rows);
            return if (focused) t.caret else null;
        },
        .source => {
            _ = ui.putStr(content.x, content.y, content.w, "    Source \u{2014} type / paste curl or .http here \u{00B7} :http.paste_source (Ctrl+Enter)", dim(p));
            if (content.h <= 2) return null;
            const c = drawTextLines(ui, pane, Rect.init(content.x, content.y + 2, content.w, content.h - 2), m.source, m.source_caret, focused, scroll, "(empty \u{2014} paste here, or Ctrl+Shift+V to read clipboard)", &.{}, content_hit);
            drawSendState(ui, content, m, 2 + (if (m.source.len == 0) 1 else linesOf(m.source) -| scroll.*));
            return c;
        },
        .params => {
            if (m.path_params.len == 0) {
                _ = drawKvTable(ui, pane, content, m.params, if (secondary) null else m.draft, .{ .kind = .params, .row_hit = hit_param_row, .del_hit = hit_param_del, .add = !secondary, .cursor = m.row_cursor, .focused = focused });
                return null;
            }
            // Two groups: `Path` — the URL's `:name` segments, a value
            // each from `# @path` — over `Query`; the cursor runs down
            // both, the path rows first.
            const n_path = m.path_params.len;
            const group: Style = .{ .fg = p.comment, .bg = p.bg_dark, .bold = true };
            var y = content.y;
            if (y < content.bottom()) _ = ui.putStr(content.x + 2, y, content.w -| 2, "Path", group);
            y += 1;
            const pt = drawKvTable(ui, pane, Rect.init(content.x, y, content.w, content.bottom() -| y), m.path_params, null, .{ .kind = .path, .row_hit = hit_path_row, .del_hit = null, .add = false, .cursor = if (m.row_cursor < n_path) m.row_cursor else n_path + 1000, .focused = focused });
            y += pt.rows;
            if (y < content.bottom()) _ = ui.putStr(content.x + 2, y, content.w -| 2, "Query", group);
            y += 1;
            _ = drawKvTable(ui, pane, Rect.init(content.x, y, content.w, content.bottom() -| y), m.params, if (secondary) null else m.draft, .{ .kind = .params, .row_hit = hit_param_row, .del_hit = hit_param_del, .add = !secondary, .cursor = m.row_cursor -| n_path, .focused = focused and m.row_cursor >= n_path });
            return null;
        },
        .auth => {
            drawAuth(ui, pane, content, m, focused);
            return null;
        },
        .vars => {
            drawVars(ui, pane, content, m, focused);
            return null;
        },
    }
}

/// `[raw] JSON form multipart` right-aligned on the strip row from
/// `x_min`, one hit for the lot: a click cycles, a right-click lists.
fn drawBodyTypeChip(ui: Ui, pane: PaneId, r: Rect, x_min: u16, cur: parse_mod.BodyType) void {
    const p = ui.theme.palette;
    var w: u16 = 0;
    for (parse_mod.BodyType.all) |t| w += ui.width(t.label()) + 2;
    if (r.right() < x_min + w + 1) return;
    const x0 = r.right() - w - 1;
    var x = x0;
    for (parse_mod.BodyType.all) |t| {
        const on = t == cur;
        x += ui.putStr(x, r.y, r.right() -| x, if (on) "[" else " ", .{ .fg = p.bg3, .bg = p.bg_dark });
        x += ui.putStr(x, r.y, r.right() -| x, t.label(), if (on) .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true } else dim(p));
        x += ui.putStr(x, r.y, r.right() -| x, if (on) "]" else " ", .{ .fg = p.bg3, .bg = p.bg_dark });
    }
    ui.hit(Rect.init(x0, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_body_type } });
}

fn dim(p: Theme.Palette) Style {
    return .{ .fg = p.comment, .bg = p.bg_dark };
}

fn linesOf(text: []const u8) usize {
    return std.mem.count(u8, text, "\n") + 1;
}

/// Rust `draw_edit`'s tail: a blank row under the tab's `used` rows,
/// then the send's state — `⟳  sending…` in yellow, `▶ streaming · N
/// events received` in cyan, `✗ last send: <error>` in red. Nothing
/// while idle or once a response is in (its box says it all).
fn drawSendState(ui: Ui, content: Rect, m: Model, used: usize) void {
    const p = ui.theme.palette;
    const y = content.y + @as(u16, @intCast(@min(used, content.h))) + 1;
    if (y >= content.bottom()) return;
    if (m.failed) |e| {
        _ = ui.putStr(content.x, y, content.w, ui.fmt("  \u{2717} last send: {s}", .{e}), .{ .fg = p.red, .bg = p.bg_dark });
    } else if (m.stream) |st| {
        _ = ui.putStr(content.x, y, content.w, ui.fmt("  \u{25B6} streaming \u{00B7} {d} events received", .{st.events}), .{ .fg = p.cyan, .bg = p.bg_dark });
    } else if (m.sending) {
        _ = ui.putStr(content.x, y, content.w, "  \u{27F3}  sending\u{2026}", .{ .fg = p.yellow, .bg = p.bg_dark });
    }
}

/// The Body tab: a ` N ` gutter per line, the text in the grey
/// foreground, `{{VAR}}`s in their colours; an empty body is a ` 1 `
/// row with the caret after it.
fn drawBody(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool, scroll: *usize, content_hit: u32) ?Caret {
    const p = ui.theme.palette;
    if (r.isEmpty()) return null;
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = content_hit } });
    if (m.body.len == 0) {
        _ = ui.putStr(r.x, r.y, r.w, " 1 ", dim(p));
        return if (focused) .{ .x = r.x + 3, .y = r.y } else null;
    }
    const total = std.mem.count(u8, m.body, "\n") + 1;
    const gw: u16 = digitsOf(total) + 2;
    return drawTextArea(ui, pane, r, m.body, m.body_caret, focused, scroll, m.body_vars, gw, .{ .fg = p.grey_fg, .bg = p.bg_dark }, true);
}

/// ` N ` with the number right-aligned to `digits` — Rust's
/// `format!(" {:>width$} ", n)`.
fn gutterText(ui: Ui, n: usize, digits: u16) []const u8 {
    var tmp: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "";
    const pad: usize = @as(usize, digits) -| num.len;
    const buf = ui.arena.alloc(u8, pad + num.len + 2) catch return " ";
    @memset(buf, ' ');
    @memcpy(buf[1 + pad .. 1 + pad + num.len], num);
    return buf;
}

fn digitsOf(n: usize) u16 {
    var v = n;
    var d: u16 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// The Headers / Script tabs: lines four cells in, no gutter.
fn drawTextLines(ui: Ui, pane: PaneId, r: Rect, text: []const u8, caret: usize, focused: bool, scroll: *usize, placeholder: []const u8, vars: []const VarSpan, content_hit: u32) ?Caret {
    const p = ui.theme.palette;
    if (r.isEmpty()) return null;
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = content_hit } });
    if (text.len == 0) {
        _ = ui.putStr(r.x, r.y, r.w, ui.fmt("    {s}", .{placeholder}), dim(p));
        return if (focused) .{ .x = r.x + 4, .y = r.y } else null;
    }
    return drawTextArea(ui, pane, r, text, caret, focused, scroll, vars, 4, .{ .fg = p.fg, .bg = p.bg_dark }, false);
}

/// A multi-line buffer: rows from `scroll`, the caret's row kept on
/// screen, each line after `indent` cells (a ` N ` gutter when
/// `numbered`). Returns the caret cell when focused.
fn drawTextArea(ui: Ui, pane: PaneId, r: Rect, text: []const u8, caret: usize, focused: bool, scroll: *usize, vars: []const VarSpan, indent: u16, style: Style, numbered: bool) ?Caret {
    const p = ui.theme.palette;
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
    var line_off: usize = 0;
    while (it.next()) |line| : ({
        line_no += 1;
        line_off += line.len + 1;
    }) {
        if (line_no < scroll.*) continue;
        if (y >= r.h) break;
        const row = r.row(y);
        if (numbered) _ = ui.putStr(row.x, row.y, indent, gutterText(ui, line_no + 1, indent -| 2), dim(p));
        const lx = row.x + indent;
        const lw = row.w -| indent;
        if (line_no == caret_line) {
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
            _ = ui.putStr(lx, row.y, lw, ui.clipStr(shown, lw), style);
            paintVarsOnLine(ui, pane, lx, row.y, lw, line, line.len - shown.len, line_off, vars, p.bg_dark);
            if (focused) out = .{ .x = lx + @min(cx, lw -| 1), .y = row.y };
        } else {
            _ = ui.putStr(lx, row.y, lw, ui.clipStr(line, lw), style);
            paintVarsOnLine(ui, pane, lx, row.y, lw, line, 0, line_off, vars, p.bg_dark);
        }
        y += 1;
    }
    return out;
}

// ─── the key / value table ──────────────────────────────────────────────

const KvKind = enum { params, headers, vars, path };

const KvOpts = struct {
    kind: KvKind,
    row_hit: u32,
    del_hit: ?u32,
    add: bool,
    cursor: usize,
    focused: bool,
    /// Headers: each row's value offset into the tab's text, so `vars`
    /// (byte spans over that text) paint inside the value cells.
    value_offs: []const usize = &.{},
    vars: []const VarSpan = &.{},
    /// A one-row tip under the cursor row (`?` on a header).
    tip: ?[]const u8 = null,
};

/// What the table painted: its rows, and the draft cell's caret (the
/// Headers table only — the completion popup anchors on it).
const KvPainted = struct { rows: u16, caret: ?Caret = null };

/// Rust's `render_kv_table`: `┌──┬──┬───┐`, a Name / Value header, one
/// row per pair with a red `✕`, the draft row with a `✓`, `+ Add row`
/// under it.
fn drawKvTable(ui: Ui, pane: PaneId, r: Rect, data: []const Pair, draft: ?Draft, o: KvOpts) KvPainted {
    const p = ui.theme.palette;
    if (r.isEmpty()) return .{ .rows = 0 };
    const kind = o.kind;
    const row_hit = o.row_hit;
    const del_hit = o.del_hit;
    const add = o.add;
    const cursor = o.cursor;
    const focused = o.focused;
    var out: KvPainted = .{ .rows = 0 };
    const table_w: u16 = std.math.clamp(r.w -| 2 -| 3, 20, 100);
    const x_col_w: u16 = 3;
    const inner_w: u16 = table_w -| x_col_w -| 4;
    const name_w: u16 = @max(inner_w * 35 / 100, 8);
    const value_w: u16 = inner_w -| name_w;
    const line: Style = .{ .fg = p.bg3, .bg = p.bg_dark };
    const ascii = ui.ascii;
    var ry: u16 = 0;
    const Ctx = struct {
        ui: Ui,
        r: Rect,
        name_w: u16,
        value_w: u16,
        x_col_w: u16,
        line: Style,
        ascii: bool,

        /// One cell at `x`, clipped to the area (Rust's rows overflow
        /// their box by a cell and ratatui cuts them there).
        fn put(c: @This(), x: u16, y: u16, s: []const u8, style: Style) u16 {
            if (x >= c.r.right()) return 0;
            return c.ui.putStr(x, y, c.r.right() - x, s, style);
        }

        fn rule(c: @This(), y: u16, left: []const u8, sep: []const u8, right: []const u8) void {
            if (y >= c.r.h) return;
            const row = c.r.row(y);
            var x = row.x + 2;
            const h = border.ruleGlyph(.h, c.ascii);
            x += c.put(x, row.y, if (c.ascii) "+" else left, c.line);
            x = c.dashes(x, row.y, c.name_w + 2, h);
            x += c.put(x, row.y, if (c.ascii) "+" else sep, c.line);
            x = c.dashes(x, row.y, c.value_w + 2, h);
            x += c.put(x, row.y, if (c.ascii) "+" else sep, c.line);
            x = c.dashes(x, row.y, c.x_col_w, h);
            _ = c.put(x, row.y, if (c.ascii) "+" else right, c.line);
        }

        fn dashes(c: @This(), x0: u16, y: u16, n: u16, h: []const u8) u16 {
            var x = x0;
            var k: u16 = 0;
            while (k < n) : (k += 1) x += c.put(x, y, h, c.line);
            return x;
        }

        /// `  │ key │ value │ x │`; the cells' x for the caller's hits.
        fn cells(c: @This(), y: u16, key: []const u8, key_style: Style, value: []const u8, value_style: Style, xg: []const u8, x_style: Style) struct { key_x: u16, value_x: u16, x_x: u16 } {
            const rr = c.r.row(y);
            const v = border.ruleGlyph(.v, c.ascii);
            var x = rr.x + 2;
            x += c.put(x, rr.y, v, c.line);
            x += 1;
            const key_x = x;
            _ = c.put(x, rr.y, c.ui.clipStr(key, c.name_w), key_style);
            x += c.name_w + 1;
            x += c.put(x, rr.y, v, c.line);
            x += 1;
            const value_x = x;
            _ = c.put(x, rr.y, c.ui.clipStr(value, c.value_w), value_style);
            x += c.value_w + 1;
            x += c.put(x, rr.y, v, c.line);
            const x_x = x;
            x += c.put(x, rr.y, xg, x_style);
            _ = c.put(x, rr.y, v, c.line);
            return .{ .key_x = key_x, .value_x = value_x, .x_x = x_x };
        }
    };
    const c: Ctx = .{ .ui = ui, .r = r, .name_w = name_w, .value_w = value_w, .x_col_w = x_col_w, .line = line, .ascii = ascii };
    c.rule(ry, "\u{250C}", "\u{252C}", "\u{2510}"); // chrome-audit: allow — a table's junctions (md_view's shape); the runs are border.ruleGlyph
    ry += 1;
    if (ry < r.h) {
        const hdr: Style = .{ .fg = p.comment, .bg = p.bg_dark, .bold = true };
        _ = c.cells(ry, "Name", hdr, "Value", hdr, "   ", .{ .bg = p.bg_dark });
    }
    ry += 1;
    c.rule(ry, "\u{251C}", "\u{253C}", "\u{2524}"); // chrome-audit: allow — as above
    ry += 1;
    const key_color = switch (kind) {
        .params => p.fg,
        .headers, .vars => p.cyan,
        .path => p.purple,
    };
    for (data, 0..) |pair, i| {
        if (ry >= r.h) break;
        const sel = focused and draft == null and i == cursor;
        const key_style: Style = .{ .fg = if (sel) p.cyan else key_color, .bg = p.bg_dark, .bold = true };
        const unset = pair.value.len == 0 and (kind == .vars or kind == .path);
        const value_style: Style = .{ .fg = if (unset) p.comment else p.fg, .bg = p.bg_dark };
        const shown_value = if (pair.value.len == 0 and kind == .path) "(unset \u{2014} Enter sets it)" else pair.value;
        const cells = c.cells(ry, pair.key, key_style, shown_value, value_style, if (del_hit != null) " \u{2715} " else "   ", .{ .fg = p.red, .bg = p.bg_dark });
        const rr = r.row(ry);
        ui.hit(Rect.init(rr.x, rr.y, table_w + 2, 1), .{ .script_hit = .{ .pane = pane, .id = row_hit + @as(u32, @intCast(i)) } });
        if (del_hit) |d| ui.hit(Rect.init(cells.x_x, rr.y, x_col_w, 1), .{ .script_hit = .{ .pane = pane, .id = d + @as(u32, @intCast(i)) } });
        // The value cell's `{{VAR}}`s: the spans are over the whole text,
        // this cell starts at the row's value offset.
        if (i < o.value_offs.len and o.vars.len > 0 and cells.value_x < r.right()) {
            const vw: u16 = @min(value_w, r.right() - cells.value_x);
            paintVarsOnLine(ui, pane, cells.value_x, rr.y, vw, pair.value, 0, o.value_offs[i], o.vars, p.bg_dark);
        }
        ry += 1;
        if (i + 1 < data.len or draft != null) {
            c.rule(ry, "\u{251C}", "\u{253C}", "\u{2524}"); // chrome-audit: allow — as above
            ry += 1;
        }
    }
    if (draft) |d| if (ry < r.h) {
        const mark: []const u8 = if (ascii) "|" else "\u{258F}";
        const key_display = if (d.key.len == 0 and !d.on_value) mark else if (d.key.len == 0) "(name)" else if (!d.on_value) ui.fmt("{s}{s}", .{ d.key, mark }) else d.key;
        const val_display = if (d.value.len == 0 and d.on_value) mark else if (d.value.len == 0) "(value)" else if (d.on_value) ui.fmt("{s}{s}", .{ d.value, mark }) else d.value;
        const active: Style = .{ .fg = p.yellow, .bg = p.bg_dark, .bold = true };
        const ready = std.mem.trim(u8, d.key, " ").len > 0 and std.mem.trim(u8, d.value, " ").len > 0;
        const cells = c.cells(ry, key_display, if (d.on_value) dim(p) else active, val_display, if (d.on_value) active else dim(p), if (ascii) " v " else " \u{2713} ", .{ .fg = if (ready) p.green else p.comment, .bg = p.bg_dark, .bold = true });
        const rr = r.row(ry);
        ui.hit(Rect.init(cells.key_x, rr.y, name_w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_draft_key } });
        ui.hit(Rect.init(cells.value_x, rr.y, value_w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_draft_value } });
        ui.hit(Rect.init(cells.x_x, rr.y, x_col_w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_draft_commit } });
        if (kind == .headers and focused) {
            // The mark's cell: where the popup hangs from.
            const cx = if (d.on_value) cells.value_x + @min(ui.width(d.value), value_w -| 1) else cells.key_x + @min(ui.width(d.key), name_w -| 1);
            out.caret = .{ .x = @min(cx, r.right() -| 1), .y = rr.y };
        }
        ry += 1;
    };
    c.rule(ry, "\u{2514}", "\u{2534}", "\u{2518}"); // chrome-audit: allow — as above
    ry += 1;
    if (ry < r.h) {
        const rr = r.row(ry);
        if (draft == null) {
            if (add) {
                _ = ui.putStr(rr.x + 2, rr.y, rr.w -| 2, "+ Add row", .{ .fg = p.green, .bg = p.bg_dark, .bold = true });
                ui.hit(rr, .{ .script_hit = .{ .pane = pane, .id = hit_add_row } });
            }
        } else {
            _ = ui.putStr(rr.x, rr.y, rr.w, overlay.hintText(ui, "    (Tab \u{00B7} `:`  \u{00B7}  Enter \u{2192} add + new row  \u{00B7}  Shift+Enter \u{2192} done  \u{00B7}  Esc \u{2192} cancel)"), dim(p));
        }
        ry += 1;
    }
    if (o.tip) |tip| if (data.len > 0 and draft == null) {
        // Under the cursor row: the header row, the rule, then two rows
        // per pair (its cells and the rule after it).
        const at: usize = @min(cursor, data.len - 1);
        const row_y: usize = 3 + at * 2;
        if (row_y + 1 < r.h) drawTip(ui, r, Rect.init(r.x + 2, r.y + @as(u16, @intCast(row_y)), 1, 1), tip);
    };
    out.rows = ry;
    return out;
}

/// A one-row tip under `anchor` (above when there is no room), clipped
/// to `screen` — the `?` description of a header, the hover copy.
pub fn drawTip(ui: Ui, screen: Rect, anchor: Rect, text: []const u8) void {
    const t = ui.theme;
    const w: u16 = @min(ui.width(text), screen.w);
    if (w == 0) return;
    var x = anchor.x;
    if (x + w > screen.right()) x = screen.right() -| w;
    if (x < screen.x) x = screen.x;
    const y: u16 = if (anchor.bottom() < screen.bottom()) anchor.bottom() else anchor.y -| 1;
    const style = Theme.onBg(t.fg, t.chip.bg);
    ui.fill(Rect.init(x, y, w, 1), style);
    _ = ui.putStr(x, y, w, ui.clipStr(text, w), style);
}

/// The Auth tab as a list of rows — the current header, the four auth
/// actions, `── Options ──` and its five rows, a hint — scrolled
/// through `m.edit_scroll` so the cursor's row is always on screen (the
/// request box is a handful of rows tall at the default size).
fn drawAuth(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool) void {
    const p = ui.theme.palette;
    if (r.isEmpty()) return;
    const cur = m.auth_current;
    const summary: []const u8 = if (cur) |v|
        (if (std.mem.startsWith(u8, v, "Bearer ")) ui.fmt("Bearer \u{00B7} {s}", .{ui.clipStr(v[7..], 20)}) else if (std.mem.startsWith(u8, v, "Basic ")) "Basic \u{00B7} (base64 user:pass)" else if (v.len > 24) ui.fmt("{s}\u{2026}", .{v[0..22]}) else v)
    else
        "(no Authorization header \u{2014} request will be unauthenticated)";
    // Virtual rows: 0 current, 1 blank, 2.. auth rows, blank, section,
    // option rows, hint.
    const auth_first: usize = 2;
    const section_row: usize = auth_first + auth_rows.len + 1;
    const opt_first: usize = section_row + 1;
    const total: usize = opt_first + option_rows.len + 1;
    const cursor_row: usize = if (m.row_cursor < auth_rows.len) auth_first + m.row_cursor else opt_first + @min(m.row_cursor - auth_rows.len, option_rows.len - 1);
    const h: usize = r.h;
    var scroll = m.edit_scroll.*;
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + h) scroll = cursor_row + 1 - h;
    scroll = @min(scroll, total -| h);
    m.edit_scroll.* = scroll;
    var label_w: u16 = 0;
    for (option_rows) |row_def| label_w = @max(label_w, ui.width(row_def.label));
    const o = m.options;
    var dbuf: [32]u8 = undefined;
    var vi: usize = scroll;
    while (vi < total and vi - scroll < h) : (vi += 1) {
        const row = r.row(@intCast(vi - scroll));
        if (vi == 0) {
            var x = r.x;
            x += ui.putStr(x, row.y, row.w, "    Current:  ", dim(p));
            _ = ui.putStr(x, row.y, row.right() -| x, summary, .{ .fg = if (cur != null) p.cyan else p.comment, .bg = p.bg_dark, .bold = true });
        } else if (vi >= auth_first and vi < auth_first + auth_rows.len) {
            const i = vi - auth_first;
            const row_def = auth_rows[i];
            const sel = focused and i == m.row_cursor;
            const bg = if (sel) p.cyan else p.bg_dark;
            const fg = if (sel) p.bg_dark else if (std.mem.eql(u8, row_def.id, "clear")) p.red else p.fg;
            ui.fill(row, .{ .bg = bg });
            _ = ui.putStr(row.x + 2, row.y, row.w -| 2, ui.fmt("{s} {s}", .{ row_def.glyph, row_def.label }), .{ .fg = fg, .bg = bg, .bold = true });
            ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_auth_row + @as(u32, @intCast(i)) } });
        } else if (vi == section_row) {
            const rule = if (ui.ascii) "--" else "\u{2500}\u{2500}";
            _ = ui.putStr(r.x + 2, row.y, r.w -| 2, ui.fmt("{s} Options {s}", .{ rule, rule }), dim(p));
        } else if (vi >= opt_first and vi < opt_first + option_rows.len) {
            const i = vi - opt_first;
            const row_def = option_rows[i];
            const idx = auth_rows.len + i;
            const sel = focused and idx == m.row_cursor;
            const bg = if (sel) p.cyan else p.bg_dark;
            const fg = if (sel) p.bg_dark else p.fg;
            const muted: Style = .{ .fg = if (sel) p.bg_dark else p.comment, .bg = bg };
            const active: Style = .{ .fg = if (sel) p.bg_dark else p.cyan, .bg = bg, .bold = true };
            ui.fill(row, .{ .bg = bg });
            var x = row.x + 2;
            x += ui.putStr(x, row.y, row.right() -| x, if (sel) (if (ui.ascii) "> " else "\u{25B8} ") else "  ", .{ .fg = fg, .bg = bg, .bold = true });
            const label = ui.fmt("{s}:", .{row_def.label});
            x += ui.putStr(x, row.y, row.right() -| x, label, .{ .fg = fg, .bg = bg, .bold = true });
            x += (label_w + 3) -| ui.width(label);
            switch (row_def.kind) {
                .verify_tls => x += drawToggle(ui, x, row, !o.insecure, active, muted),
                .follow_redirects => x += drawToggle(ui, x, row, o.follow_redirects, active, muted),
                .max_redirects => {
                    x += ui.putStr(x, row.y, row.right() -| x, if (ui.ascii) "< " else "\u{2039} ", muted);
                    x += ui.putStr(x, row.y, row.right() -| x, ui.fmt("[{d}]", .{o.max_redirects}), active);
                    x += ui.putStr(x, row.y, row.right() -| x, if (ui.ascii) " >" else " \u{203A}", muted);
                },
                .timeout => {
                    const text = if (o.timeout_ms) |ms| ui.fmt("[{s}]", .{@import("../http/parse.zig").formatDuration(&dbuf, ms)}) else "[none]";
                    x += ui.putStr(x, row.y, row.right() -| x, text, active);
                    x += ui.putStr(x, row.y, row.right() -| x, "  Enter to set", muted);
                },
                .proxy => {
                    const text = if (o.proxy) |px| ui.fmt("[{s}]", .{ui.clipStr(px, 40)}) else "[none]";
                    x += ui.putStr(x, row.y, row.right() -| x, text, active);
                    x += ui.putStr(x, row.y, row.right() -| x, "  Enter to set", muted);
                },
            }
            if (o.set[i]) _ = ui.putStr(x + 1, row.y, row.right() -| (x + 1), "*", .{ .fg = if (sel) p.bg_dark else p.yellow, .bg = bg, .bold = true });
            ui.hit(row, .{ .script_hit = .{ .pane = pane, .id = hit_auth_row + @as(u32, @intCast(idx)) } });
        } else if (vi == total - 1) {
            _ = ui.putStr(r.x + 4, row.y, r.w -| 4, overlay.hintText(ui, "(\u{2190}\u{2192} toggle / step \u{00B7} Enter set \u{00B7} r config default \u{00B7} * set by this request)"), dim(p));
        }
    }
}

/// `[on] / off` or `on / [off]`; returns the cells used.
fn drawToggle(ui: Ui, x0: u16, row: Rect, on: bool, active: Style, muted: Style) u16 {
    var x = x0;
    x += ui.putStr(x, row.y, row.right() -| x, if (on) "[on]" else "on", if (on) active else muted);
    x += ui.putStr(x, row.y, row.right() -| x, " / ", muted);
    x += ui.putStr(x, row.y, row.right() -| x, if (on) "off" else "[off]", if (on) muted else active);
    return x - x0;
}

fn drawVars(ui: Ui, pane: PaneId, r: Rect, m: Model, focused: bool) void {
    const p = ui.theme.palette;
    if (r.isEmpty()) return;
    var x = r.x;
    x += ui.putStr(x, r.y, r.w, "    env: ", dim(p));
    x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s}.env", .{m.env_name orelse "dev"}), .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true });
    _ = ui.putStr(x, r.y, r.right() -| x, overlay.hintText(ui, "   \u{00B7} click cell to edit \u{00B7} Tab commits \u{00B7} Esc cancels"), dim(p));
    if (r.h <= 2) return;
    const rows = ui.arena.alloc(Pair, m.vars.len) catch return;
    for (m.vars, 0..) |v, i| rows[i] = .{ .key = v.name, .value = v.value orelse "" };
    _ = drawKvTable(ui, pane, Rect.init(r.x, r.y + 2, r.w, r.h - 2), rows, null, .{ .kind = .vars, .row_hit = hit_var_row, .del_hit = null, .add = false, .cursor = m.row_cursor, .focused = focused });
}

// ─── vars ───────────────────────────────────────────────────────────────

/// The style a `{{VAR}}` paints in: cyan when the env has it, red
/// when it does not — bold either way.
pub fn varStyle(t: *const Theme, resolved: bool, bg: Color) Style {
    const p = t.palette;
    return .{ .fg = if (resolved) p.cyan else p.red, .bg = bg, .bold = true };
}

/// Overpaint the `{{VAR}}` tokens of one painted line: `line` is the
/// text as it was laid out from `x` after `drop` leading bytes were
/// scrolled off, `line_off` its byte offset in the field.
fn paintVarsOnLine(ui: Ui, pane: PaneId, x: u16, y: u16, max_w: u16, line: []const u8, drop: usize, line_off: usize, vars: []const VarSpan, bg: Color) void {
    for (vars) |v| {
        if (v.end <= line_off or v.start >= line_off + line.len) continue;
        const s = @max(v.start, line_off) - line_off;
        const e = @min(v.end, line_off + line.len) - line_off;
        if (e <= drop) continue;
        const from = @max(s, drop);
        const col = ui.width(line[drop..from]);
        if (col >= max_w) continue;
        const w = @min(ui.width(line[from..e]), max_w - col);
        if (w == 0) continue;
        const rx = x + col;
        _ = ui.putStr(rx, y, w, ui.clipStr(line[from..e], w), varStyle(ui.theme, v.resolved, bg));
        ui.hit(Rect.init(rx, y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_var_base + v.id } });
    }
}

/// How many cells `text_field.draw` scrolls a one-row field so the
/// caret stays inside `w` — the same walk, so an overpaint lines up.
pub fn fieldScroll(ui: Ui, text: []const u8, caret: usize, w: u16) u32 {
    if (w == 0) return 0;
    var caret_col: u32 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    var widths: std.ArrayListUnmanaged(u32) = .empty;
    const c = @min(caret, text.len);
    while (it.next()) |g| {
        const cw: u32 = @min(ui.canvas.cellWidth(g.bytes(text)), 2);
        if (cw == 0) continue;
        widths.append(ui.arena, cw) catch return 0;
        if (g.start < c) caret_col += cw;
    }
    var skipped: u32 = 0;
    var first: usize = 0;
    while (caret_col - skipped >= w and first < widths.items.len) : (first += 1) skipped += widths.items[first];
    return skipped;
}

/// The `{{VAR}}` tokens over a one-row `text_field`.
fn paintVarsOnField(ui: Ui, pane: PaneId, r: Rect, text: []const u8, caret: usize, vars: []const VarSpan, bg: Color) void {
    if (r.isEmpty() or vars.len == 0) return;
    const skipped = fieldScroll(ui, text, caret, r.w);
    for (vars) |v| {
        if (v.end > text.len or v.start >= v.end) continue;
        const col: u32 = ui.width(text[0..v.start]);
        const w_full: u32 = ui.width(text[v.start..v.end]);
        if (col + w_full <= skipped) continue;
        const vis_start = @max(col, skipped) - skipped;
        if (vis_start >= r.w) continue;
        // Bytes hidden at the token's left edge, when the scroll cut it.
        var from = v.start;
        var hidden: u32 = 0;
        while (col + hidden < skipped and from < v.end) {
            const step = text_field.nextCp(text, from) - from;
            hidden += ui.width(text[from .. from + step]);
            from += step;
        }
        const w: u16 = @intCast(@min(ui.width(text[from..v.end]), r.w - vis_start));
        if (w == 0) continue;
        const rx: u16 = r.x + @as(u16, @intCast(vis_start));
        _ = ui.putStr(rx, r.y, w, ui.clipStr(text[from..v.end], w), varStyle(ui.theme, v.resolved, bg));
        ui.hit(Rect.init(rx, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_var_base + v.id } });
    }
}

/// A one-row tip for a hovered `{{VAR}}`: its value, or that the env
/// lacks it. Painted just under `anchor` (above when there is no room),
/// clipped to `screen`.
pub fn drawVarTip(ui: Ui, screen: Rect, anchor: Rect, name: []const u8, value: ?[]const u8, env_name: ?[]const u8) void {
    const t = ui.theme;
    const text = if (value) |v|
        ui.fmt(" {{{{{s}}}}} = {s} ", .{ name, std.mem.sliceTo(v, '\n') })
    else
        ui.fmt(" {{{{{s}}}}} \u{2014} not defined in env {s} ", .{ name, env_name orelse "?" });
    const w: u16 = @min(ui.width(text), screen.w);
    if (w == 0) return;
    var x = anchor.x;
    if (x + w > screen.right()) x = screen.right() -| w;
    if (x < screen.x) x = screen.x;
    const y: u16 = if (anchor.bottom() < screen.bottom()) anchor.bottom() else anchor.y -| 1;
    const style = Theme.onBg(if (value != null) t.fg else t.error_fg, t.chip.bg);
    ui.fill(Rect.init(x, y, w, 1), style);
    _ = ui.putStr(x, y, w, ui.clipStr(text, w), style);
}

// ─── the Response box ───────────────────────────────────────────────────

/// The response's type label for the strip's chip — Rust's
/// `detect_response_content_type`: the content-type header first, the
/// body's first character after that, `—` with no response.
pub fn typeLabel(m: Model) []const u8 {
    const r = m.response orelse return "\u{2014}";
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.key, "content-type")) {
        const v = h.value;
        const has = struct {
            fn f(hay: []const u8, needle: []const u8) bool {
                return std.ascii.indexOfIgnoreCase(hay, needle) != null;
            }
        }.f;
        if (has(v, "json")) return "JSON";
        if (has(v, "html")) return "HTML";
        if (has(v, "xml")) return "XML";
        if (has(v, "javascript") or has(v, "ecmascript")) return "JS";
        if (has(v, "css")) return "CSS";
        if (std.ascii.startsWithIgnoreCase(v, "image/")) return "IMAGE";
        if (std.ascii.startsWithIgnoreCase(v, "video/")) return "VIDEO";
        if (std.ascii.startsWithIgnoreCase(v, "audio/")) return "AUDIO";
        if (has(v, "pdf")) return "PDF";
        if (has(v, "octet-stream") or has(v, "zip") or has(v, "gzip") or has(v, "tar") or has(v, "protobuf") or has(v, "msgpack")) return "BINARY";
        if (has(v, "plain") or has(v, "text/")) return "TEXT";
    };
    const head = std.mem.trimStart(u8, r.body, " \t\r\n");
    if (head.len == 0) return "TEXT";
    return switch (head[0]) {
        '{', '[' => "JSON",
        '<' => "XML",
        else => "TEXT",
    };
}

/// Rust's `is_response_failure`: a non-2xx, a failed send, or a pane
/// that never fired.
fn isFailure(m: Model) bool {
    if (m.failed != null or m.idle()) return true;
    if (m.response) |r| return r.status < 200 or r.status >= 300;
    return false;
}

fn drawResponseBox(ui: Ui, pane: PaneId, r: Rect, m: Model) void {
    const p = ui.theme.palette;
    if (r.isEmpty()) return;
    const inner = box(ui, r, "");
    drawStatusTitle(ui, r, m);
    if (inner.isEmpty()) return;
    var content = inner;
    if (inner.h >= 3) {
        drawResponseStrip(ui, pane, inner, m);
        content = Rect.init(inner.x, inner.y + 2, inner.w, inner.h - 2);
    }
    ui.hit(content, .{ .script_hit = .{ .pane = pane, .id = hit_resp_body } });
    // The rows, then the window `resp_view.scroll_line` picks.
    const lines = responseRows(ui, content.w, m);
    const max_scroll = lines.len -| content.h;
    if (m.resp_view.scroll_line > max_scroll) m.resp_view.scroll_line = @intCast(max_scroll);
    const first: usize = m.resp_view.scroll_line;
    var y: u16 = 0;
    var i = first;
    while (i < lines.len and y < content.h) : ({
        i += 1;
        y += 1;
    }) {
        const row = content.row(y);
        var x = row.x;
        for (lines[i].segs) |seg| {
            if (x >= row.right()) break;
            x += ui.putStr(x, row.y, row.right() -| x, seg.text, seg.style);
        }
    }
    _ = p;
}

/// ` 200 OK  · 2ms · 49 B ` right-aligned on the box's top edge —
/// Rust's `response_status_title`; sending, streaming and a failure
/// have their own; a pane that never fired shows none.
fn drawStatusTitle(ui: Ui, r: Rect, m: Model) void {
    const p = ui.theme.palette;
    if (r.w < 4) return;
    const ground: Color = p.bg_dark;
    var segs: std.ArrayListUnmanaged(vaxis.Segment) = .empty;
    if (m.sending) {
        segs.append(ui.arena, .{ .text = " \u{27F3} sending\u{2026} ", .style = .{ .fg = p.yellow, .bg = ground, .bold = true } }) catch return;
    } else if (m.stream) |st| {
        segs.append(ui.arena, .{ .text = ui.fmt(" \u{25B6} streaming \u{00B7} {d} events ", .{st.events}), .style = .{ .fg = p.cyan, .bg = ground, .bold = true } }) catch return;
    } else if (m.failed != null) {
        segs.append(ui.arena, .{ .text = " \u{2717} failed ", .style = .{ .fg = p.red, .bg = ground, .bold = true } }) catch return;
    } else if (m.response) |resp| {
        const color = switch (resp.status / 100) {
            2 => p.green,
            3 => p.yellow,
            4 => p.orange,
            5 => p.red,
            else => p.bg3,
        };
        const sep: vaxis.Segment = .{ .text = " \u{00B7} ", .style = .{ .fg = p.comment, .bg = ground } };
        segs.append(ui.arena, .{ .text = ui.fmt(" {d} {s} ", .{ resp.status, resp.status_text }), .style = .{ .fg = color, .bg = ground, .bold = true } }) catch return;
        segs.append(ui.arena, sep) catch return;
        segs.append(ui.arena, .{ .text = ui.fmt("{d}ms", .{resp.timing.total_ms}), .style = .{ .fg = p.comment, .bg = ground } }) catch return;
        segs.append(ui.arena, sep) catch return;
        segs.append(ui.arena, .{ .text = ui.fmt("{s} ", .{humanBytes(ui, resp.body_bytes)}), .style = .{ .fg = p.comment, .bg = ground } }) catch return;
    } else return;
    var total: u16 = 0;
    for (segs.items) |s| total += ui.width(s.text);
    if (total + 2 > r.w) return;
    var x = r.right() - 1 - total;
    for (segs.items) |s| x += ui.putStr(x, r.y, r.right() -| x, s.text, s.style);
}

/// Rust's `human_bytes`: `999 B`, `1.2 KB`, `1.2 MB`.
pub fn humanBytes(ui: Ui, n: usize) []const u8 {
    if (n < 1024) return ui.fmt("{d} B", .{n});
    if (n < 1024 * 1024) return ui.fmt("{d:.1} KB", .{@as(f64, @floatFromInt(n)) / 1024.0});
    return ui.fmt("{d:.1} MB", .{@as(f64, @floatFromInt(n)) / (1024.0 * 1024.0)});
}

/// `  Body  Headers N  Cookies N  Timeline  Tests` with the `━` under
/// the active tab on the row below, and the chips from the right:
/// ` TYPE ▼ `, ` copy `, ` wrap `, and ` ⚡ AI ` when the response is
/// a failure — Rust's `paint_response_tab_strip`.
fn drawResponseStrip(ui: Ui, pane: PaneId, inner: Rect, m: Model) void {
    const p = ui.theme.palette;
    const label_y = inner.y;
    const bar_y = inner.y + 1;
    var x = inner.x + 2;
    for (ResponseTab.all, 0..) |t, i| {
        var label = t.label();
        if (m.response) |resp| {
            if (t == .headers and resp.headers.len > 0) label = ui.fmt("Headers {d}", .{resp.headers.len});
            if (t == .cookies and resp.cookies.len > 0) label = ui.fmt("Cookies {d}", .{resp.cookies.len});
        }
        const w = ui.width(label);
        if (x + w > inner.right()) break;
        const cur = t == m.response_tab;
        _ = ui.putStr(x, label_y, w, label, if (cur) .{ .fg = p.fg, .bg = p.bg_dark, .bold = true } else dim(p));
        if (cur) {
            var k: u16 = 0;
            while (k < w) : (k += 1) _ = ui.putStr(x + k, bar_y, 1, if (ui.ascii) "=" else "\u{2501}", .{ .fg = p.yellow, .bg = p.bg_dark, .bold = true }); // chrome-audit: allow — as above
        }
        ui.hit(Rect.init(x, label_y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hit_resp_tab_base + @as(u32, @intCast(i)) } });
        x += w + 2;
    }
    // Where the labels end: a chip never paints over them. On a strip
    // too narrow for both, the chips go first, from the left of their
    // row inward (Rust's `fit_row`: the row compacts before it clips),
    // so a 47-cell pane keeps `Body … Tests` whole and drops ` — ▼ `.
    const labels_end = x -| 2;
    // The chips, right to left, one cell of strip between.
    var right_edge = inner.right() - 1;
    const Chip = struct { text: []const u8, style: Style, id: u32 };
    const type_text = ui.fmt(" {s} \u{25BC} ", .{typeLabel(m)});
    const chips = [_]Chip{
        .{ .text = type_text, .style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true }, .id = hit_type },
        .{ .text = " copy ", .style = dim(p), .id = hit_copy },
        .{ .text = " wrap ", .style = if (m.body_wrap) .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true } else dim(p), .id = hit_wrap },
        .{ .text = if (ui.ascii) " * AI " else " \u{26A1} AI ", .style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true }, .id = hit_ai_chip },
    };
    for (chips, 0..) |c, i| {
        if (i == 3 and !isFailure(m)) break;
        // Rust sizes a chip by its characters, so the wide `⚡` spills a
        // cell into the gap; the same count keeps the columns.
        const w: u16 = @intCast(std.unicode.utf8CountCodepoints(c.text) catch c.text.len);
        if (right_edge <= inner.x + w + 2) break;
        const cx = right_edge - w;
        if (cx < labels_end + 1) break;
        _ = ui.putStr(cx, label_y, w, c.text, c.style);
        ui.hit(Rect.init(cx, label_y, w, 1), .{ .script_hit = .{ .pane = pane, .id = c.id } });
        right_edge = cx - 1;
    }
}

const Seg = vaxis.Segment;
const Line = struct { segs: []const Seg };

fn plain(ui: Ui, text: []const u8, style: Style) Line {
    const segs = ui.arena.alloc(Seg, 1) catch return .{ .segs = &.{} };
    segs[0] = .{ .text = text, .style = style };
    return .{ .segs = segs };
}

fn lineOf(ui: Ui, parts: []const Seg) Line {
    return .{ .segs = ui.arena.dupe(Seg, parts) catch &.{} };
}

/// The Response content as rows — Rust's `draw_response`.
fn responseRows(ui: Ui, w: u16, m: Model) []const Line {
    const p = ui.theme.palette;
    var out: std.ArrayListUnmanaged(Line) = .empty;
    const body_style: Style = .{ .fg = p.fg, .bg = p.bg_dark };
    const push = struct {
        fn f(o: *std.ArrayListUnmanaged(Line), a: Allocator, l: Line) void {
            o.append(a, l) catch {};
        }
    }.f;
    if (m.sending) {
        push(&out, ui.arena, plain(ui, "  \u{27F3}  sending\u{2026}", .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true }));
        return out.items;
    }
    if (m.stream) |_| if (m.response) |resp| {
        push(&out, ui.arena, plain(ui, ui.fmt("  \u{25B6} streaming \u{00B7} {d} {s}", .{ resp.status, resp.status_text }), .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true }));
        push(&out, ui.arena, plain(ui, "", body_style));
        var it = std.mem.splitScalar(u8, resp.body, '\n');
        while (it.next()) |l| push(&out, ui.arena, plain(ui, l, body_style));
        return out.items;
    };
    if (m.failed) |e| {
        push(&out, ui.arena, plain(ui, ui.fmt("  \u{2717} {s}", .{e}), .{ .fg = p.red, .bg = p.bg_dark, .bold = true }));
        return out.items;
    }
    const resp = m.response orelse {
        push(&out, ui.arena, plain(ui, "  not sent yet \u{00B7} press `r` to fire", dim(p)));
        return out.items;
    };
    switch (m.response_tab) {
        .headers => if (resp.headers_text.len == 0) {
            for (resp.headers) |h| push(&out, ui.arena, lineOf(ui, &.{
                .{ .text = "  ", .style = body_style },
                .{ .text = h.key, .style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true } },
                .{ .text = ": ", .style = dim(p) },
                .{ .text = h.value, .style = body_style },
            }));
        } else {
            // From the joined text, so a search match's offsets land on
            // the right cells.
            var it = std.mem.splitScalar(u8, resp.headers_text, '\n');
            var off: usize = 0;
            while (it.next()) |l| : (off += l.len + 1) {
                if (l.len == 0) continue;
                const colon = std.mem.indexOf(u8, l, ": ") orelse l.len;
                const line = lineOf(ui, &.{
                    .{ .text = "  ", .style = body_style },
                    .{ .text = l[0..colon], .style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true } },
                    .{ .text = l[colon..@min(colon + 2, l.len)], .style = dim(p) },
                    .{ .text = l[@min(colon + 2, l.len)..], .style = body_style },
                });
                push(&out, ui.arena, overlayMatches(ui, line, l, off, resp.matches, resp.current_match));
            }
        },
        .cookies => {
            if (resp.cookies.len == 0) {
                push(&out, ui.arena, plain(ui, "  (no cookies set by this response)", dim(p)));
            } else for (resp.cookies) |c| {
                // `name=value; attrs`: the name cyan, the value, the
                // attributes dim on the row below.
                const semi = std.mem.indexOfScalar(u8, c, ';') orelse c.len;
                const nv = c[0..semi];
                const eq = std.mem.indexOfScalar(u8, nv, '=') orelse nv.len;
                push(&out, ui.arena, lineOf(ui, &.{
                    .{ .text = "  ", .style = body_style },
                    .{ .text = nv[0..eq], .style = .{ .fg = p.cyan, .bg = p.bg_dark, .bold = true } },
                    .{ .text = " = ", .style = dim(p) },
                    .{ .text = if (eq < nv.len) nv[eq + 1 ..] else "", .style = body_style },
                }));
                if (semi < c.len) push(&out, ui.arena, plain(ui, ui.fmt("    {s}", .{std.mem.trim(u8, c[semi + 1 ..], " ")}), dim(p)));
                push(&out, ui.arena, plain(ui, "", body_style));
            }
        },
        .timeline => {
            const max = @max(@max(resp.timing.wait_ms, resp.timing.receive_ms), 1);
            const bar_w: u64 = 40;
            const label_style: Style = .{ .fg = p.comment, .bg = p.bg_dark, .bold = true };
            push(&out, ui.arena, lineOf(ui, &.{ .{ .text = "  Wait     ", .style = label_style }, .{ .text = "(connect + TLS + send + headers received)", .style = dim(p) } }));
            push(&out, ui.arena, timelineBar(ui, resp.timing.wait_ms, max, bar_w, p.blue));
            push(&out, ui.arena, plain(ui, "", body_style));
            push(&out, ui.arena, lineOf(ui, &.{ .{ .text = "  Receive  ", .style = label_style }, .{ .text = "(body read)", .style = dim(p) } }));
            push(&out, ui.arena, timelineBar(ui, resp.timing.receive_ms, max, bar_w, p.green));
            push(&out, ui.arena, plain(ui, "", body_style));
            push(&out, ui.arena, plain(ui, ui.fmt("  Total    {d} ms", .{resp.timing.total_ms}), .{ .fg = p.fg, .bg = p.bg_dark, .bold = true }));
            // What went out: the line as sent and the wire headers, after
            // the directives, the expansion and the `http_request` hook.
            push(&out, ui.arena, plain(ui, "", body_style));
            push(&out, ui.arena, lineOf(ui, &.{ .{ .text = "  Sent     ", .style = label_style }, .{ .text = "(after directives, {{VAR}} expansion and hooks)", .style = dim(p) } }));
            if (m.sent_line) |l| push(&out, ui.arena, plain(ui, ui.fmt("    {s}", .{l}), body_style));
            for (resp.sent_headers) |h| push(&out, ui.arena, lineOf(ui, &.{ .{ .text = ui.fmt("    {s}: ", .{h.key}), .style = .{ .fg = p.cyan, .bg = p.bg_dark } }, .{ .text = h.value, .style = body_style } }));
        },
        .tests => {
            if (resp.tests.len == 0) {
                push(&out, ui.arena, plain(ui, "  (no assertions in this request)", dim(p)));
            } else for (resp.tests) |t| push(&out, ui.arena, testLine(ui, t));
        },
        .body => {
            // A blank row, then the body with a ` N ` gutter and its
            // syntax spans; `wrap` continues a long line under a blank
            // gutter.
            push(&out, ui.arena, plain(ui, "", body_style));
            var total: usize = 1;
            for (resp.body) |c| if (c == '\n') {
                total += 1;
            };
            if (resp.body.len > 0 and resp.body[resp.body.len - 1] == '\n') total -= 1;
            const gw: u16 = digitsOf(@max(total, 1)) + 2;
            const wrap_w: ?usize = if (m.body_wrap) @max(w -| 2, 20) else null;
            var it = std.mem.splitScalar(u8, resp.body, '\n');
            var n: usize = 0;
            var off: usize = 0;
            while (it.next()) |l| : (off += l.len + 1) {
                if (off >= resp.body.len and l.len == 0) break;
                n += 1;
                const gutter: Seg = .{ .text = gutterText(ui, n, gw - 2), .style = dim(p) };
                const blank: Seg = .{ .text = ui.fmt("{s: <[1]}", .{ "", gw }), .style = body_style };
                if (wrap_w) |ww| if (ui.width(l) > ww) {
                    var rest = l;
                    var first = true;
                    while (rest.len > 0) {
                        const cut = cutAt(ui, rest, @intCast(ww));
                        const piece = lineOf(ui, &.{ if (first) gutter else blank, .{ .text = rest[0..cut], .style = body_style } });
                        push(&out, ui.arena, overlayMatches(ui, piece, l, off, resp.matches, resp.current_match));
                        rest = rest[cut..];
                        first = false;
                    }
                    continue;
                };
                push(&out, ui.arena, overlayMatches(ui, spanLine(ui, gutter, l, off, resp.spans, body_style), l, off, resp.matches, resp.current_match));
            }
            if (resp.tests.len > 0) {
                push(&out, ui.arena, plain(ui, "", body_style));
                for (resp.tests) |t| push(&out, ui.arena, testLine(ui, t));
            }
        },
    }
    return out.items;
}

fn testLine(ui: Ui, t: []const u8) Line {
    const p = ui.theme.palette;
    const ok = std.mem.startsWith(u8, t, "\u{2713}");
    const bad = std.mem.startsWith(u8, t, "\u{2717}");
    return plain(ui, ui.fmt("  {s}", .{t}), .{ .fg = if (ok) p.green else if (bad) p.red else p.fg, .bg = p.bg_dark, .bold = bad });
}

fn timelineBar(ui: Ui, ms: u64, max: u64, bar_w: u64, color: Color) Line {
    const p = ui.theme.palette;
    const filled: usize = @intCast(ms * bar_w / max);
    const empty: usize = @intCast(bar_w - @min(bar_w, ms * bar_w / max));
    var full: std.ArrayListUnmanaged(u8) = .empty;
    var rest: std.ArrayListUnmanaged(u8) = .empty;
    for (0..filled) |_| full.appendSlice(ui.arena, if (ui.ascii) "#" else "\u{2588}") catch {};
    for (0..empty) |_| rest.appendSlice(ui.arena, if (ui.ascii) "." else "\u{2591}") catch {};
    return lineOf(ui, &.{
        .{ .text = "  ", .style = .{ .bg = p.bg_dark } },
        .{ .text = full.items, .style = .{ .fg = color, .bg = p.bg_dark } },
        .{ .text = rest.items, .style = .{ .fg = p.bg3, .bg = p.bg_dark } },
        .{ .text = ui.fmt("  {d} ms", .{ms}), .style = dim(p) },
    });
}

/// The search's matches over one drawn line: every segment whose text
/// is a slice of `src` (the line at `src_off` in the searched text) is
/// split where a match crosses it; the matched piece takes the theme's
/// `match` ground, the current one `current_match` — what
/// `editor_view` paints. Segments from elsewhere (the gutter) pass.
fn overlayMatches(ui: Ui, line: Line, src: []const u8, src_off: usize, matches: []const find_mod.Range, current: ?usize) Line {
    if (matches.len == 0) return line;
    const t = ui.theme;
    const line_end = src_off + src.len;
    // Nothing of this line is matched: keep it as it is.
    var any = false;
    for (matches) |m| if (m.end > src_off and m.start < line_end + 1) {
        any = true;
        break;
    };
    if (!any) return line;
    var segs: std.ArrayListUnmanaged(Seg) = .empty;
    const base = @intFromPtr(src.ptr);
    for (line.segs) |seg| {
        const sp = @intFromPtr(seg.text.ptr);
        if (seg.text.len == 0 or sp < base or sp + seg.text.len > base + src.len) {
            segs.append(ui.arena, seg) catch return line;
            continue;
        }
        const seg_off = src_off + (sp - base);
        const seg_end = seg_off + seg.text.len;
        var at = seg_off;
        for (matches, 0..) |m, i| {
            if (m.end <= at or m.start >= seg_end) continue;
            const s = @max(m.start, at);
            const e = @min(m.end, seg_end);
            if (s > at) segs.append(ui.arena, .{ .text = seg.text[at - seg_off .. s - seg_off], .style = seg.style }) catch return line;
            var st = seg.style;
            if (current != null and current.? == i) {
                st.bg = t.current_match.bg;
                st.fg = t.current_match.fg;
            } else st.bg = t.match.bg;
            segs.append(ui.arena, .{ .text = seg.text[s - seg_off .. e - seg_off], .style = st }) catch return line;
            at = e;
        }
        if (at < seg_end) segs.append(ui.arena, .{ .text = seg.text[at - seg_off ..], .style = seg.style }) catch return line;
    }
    return .{ .segs = segs.items };
}

/// One body line split at the syntax spans that cover it.
fn spanLine(ui: Ui, gutter: Seg, l: []const u8, off: usize, spans: []const editor_view.Span, base: Style) Line {
    var segs: std.ArrayListUnmanaged(Seg) = .empty;
    segs.append(ui.arena, gutter) catch return .{ .segs = &.{} };
    var at: usize = 0;
    const end = off + l.len;
    for (spans) |sp| {
        if (sp.end <= off + at or sp.start >= end) continue;
        const s = @max(sp.start, off) - off;
        const e = @min(sp.end, end) - off;
        if (s > at) segs.append(ui.arena, .{ .text = l[at..s], .style = base }) catch break;
        var st = sp.style;
        st.bg = base.bg;
        segs.append(ui.arena, .{ .text = l[s..e], .style = st }) catch break;
        at = e;
    }
    if (at < l.len) segs.append(ui.arena, .{ .text = l[at..], .style = base }) catch {};
    return .{ .segs = segs.items };
}

/// The byte length of the longest prefix of `s` that fits `w` cells.
fn cutAt(ui: Ui, s: []const u8, w: u16) usize {
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const cw: u16 = @intCast(ui.canvas.cellWidth(g.bytes(s)));
        if (used + cw > w) return if (g.start == 0) g.len else g.start;
        used += cw;
    }
    return s.len;
}

// ─── the AI box ─────────────────────────────────────────────────────────

fn drawAiBox(ui: Ui, pane: PaneId, r: Rect) void {
    const p = ui.theme.palette;
    if (r.isEmpty()) return;
    const inner = box(ui, r, "AI");
    if (inner.isEmpty()) return;
    var x = inner.x + 1;
    x += ui.putStr(x, inner.y, inner.right() -| x, "click here to ask a custom question", dim(p));
    _ = ui.putStr(x, inner.y, inner.right() -| x, "   \u{00B7} `a` quick debug", dim(p));
    ui.hit(inner, .{ .script_hit = .{ .pane = pane, .id = hit_ai } });
}

pub fn fmtBytes(ui: Ui, n: usize) []const u8 {
    return humanBytes(ui, n);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @import("test_fixture.zig");

fn baseModel(scroll: *usize, view: *editor_view.ViewState) Model {
    return .{
        .method = "GET",
        .url = "https://httpbin.org/get",
        .url_caret = 0,
        .block = .request,
        .field = .url,
        .edit_tab = .body,
        .body = "",
        .body_caret = 0,
        .headers_text = "Accept: application/json\n",
        .headers_caret = 0,
        .source = "",
        .source_caret = 0,
        .params = &.{},
        .draft = null,
        .row_cursor = 0,
        .auth_current = null,
        .vars = &.{},
        .env_name = null,
        .edit_scroll = scroll,
        .sending = false,
        .failed = null,
        .response = null,
        .sent_line = null,
        .response_tab = .body,
        .resp_view = view,
        .body_wrap = false,
        .focused = true,
        .source_path = null,
    };
}

test "tabs cycle both ways in Rust's order; the labels are the six the strip paints" {
    try testing.expectEqual(EditTab.body, EditTab.params.next());
    try testing.expectEqual(EditTab.headers, EditTab.body.next());
    try testing.expectEqual(EditTab.params, EditTab.source.next());
    try testing.expectEqual(EditTab.source, EditTab.params.prev());
    try testing.expectEqualStrings("Script", EditTab.source.label());
    try testing.expectEqual(ResponseTab.tests, ResponseTab.body.prev());
    try testing.expect(EditTab.source.isText() and !EditTab.params.isText());
    try testing.expectEqual(Orientation.vertical, Orientation.auto.resolve(89));
    try testing.expectEqual(Orientation.horizontal, Orientation.auto.resolve(120));
    try testing.expectEqual(Tier.medium, tierFor(89, 3));
    try testing.expectEqual(Tier.full, tierFor(120, 3));
    try testing.expectEqual(Tier.small, tierFor(40, 3));
}

test "the spec's request pane, cell for cell: the top bar, the Request box with its strip and chips, the idle Response box, the AI box; the hits" {
    // `docs/ui-spec/rust-request-120x40.txt` columns 31..120, rows 2..37
    // (row 38 is the statusline, 39 the message line).
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    const m = baseModel(&scroll, &view);
    const ui = fx.ui();
    const caret = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(0, "");
    try fx.expectRow(1, "\u{250C} Method \u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\u{250C} URL " ++ "\u{2500}" ** 58 ++ "\u{2510}\u{250C} Send \u{2500}\u{2500}\u{2510}");
    try fx.expectRow(2, "\u{2502}  GET     \u{25BC} \u{2502}\u{2502} https://httpbin.org/get" ++ " " ** 39 ++ "\u{2502}\u{2502} \u{25B6} Send \u{2502}");
    try fx.expectRow(3, "\u{2514}" ++ "\u{2500}" ** 12 ++ "\u{2518}\u{2514}" ++ "\u{2500}" ** 63 ++ "\u{2518}\u{2514}" ++ "\u{2500}" ** 8 ++ "\u{2518}");
    try fx.expectRow(4, "\u{250C}" ++ "\u{2500}" ** 75 ++ "[\u{21D4}]\u{2500}[A \u{25A5} \u{25A4}]\u{2500}\u{2510}");
    try fx.expectRow(5, "\u{2502}  Params  Body  Headers  Auth  Vars  Script" ++ " " ** 44 ++ "\u{2502}");
    try fx.expectRow(6, "\u{2502}          \u{2501}\u{2501}\u{2501}\u{2501}" ++ " " ** 73 ++ "\u{2502}");
    try fx.expectRow(7, "\u{2502} 1" ++ " " ** 85 ++ "\u{2502}");
    try fx.expectRow(17, "\u{2514}" ++ "\u{2500}" ** 87 ++ "\u{2518}");
    try fx.expectRow(18, "\u{250C}" ++ "\u{2500}" ** 87 ++ "\u{2510}");
    // The fixture's row reader prints the wide `⚡` once (the headless
    // dump shows its second cell as a space).
    try fx.expectRow(19, "\u{2502}  Body  Headers  Cookies  Timeline  Tests                    \u{26A1} AI  wrap   copy   \u{2014} \u{25BC}  \u{2502}");
    try fx.expectRow(20, "\u{2502}  \u{2501}\u{2501}\u{2501}\u{2501}" ++ " " ** 81 ++ "\u{2502}");
    try fx.expectRow(21, "\u{2502}  not sent yet \u{00B7} press `r` to fire" ++ " " ** 53 ++ "\u{2502}");
    try fx.expectRow(32, "\u{2514}" ++ "\u{2500}" ** 87 ++ "\u{2518}");
    try fx.expectRow(33, "\u{250C} AI " ++ "\u{2500}" ** 83 ++ "\u{2510}");
    try fx.expectRow(34, "\u{2502} click here to ask a custom question   \u{00B7} `a` quick debug" ++ " " ** 31 ++ "\u{2502}");
    try fx.expectRow(35, "\u{2514}" ++ "\u{2500}" ** 87 ++ "\u{2518}");
    // The caret sits at the URL's start; the hits.
    try testing.expectEqual(@as(u16, 16), caret.?.x);
    try testing.expectEqual(@as(u16, 2), caret.?.y);
    try testing.expectEqual(hit_method, fx.hits.at(3, 2).?.script_hit.id);
    try testing.expectEqual(hit_url, fx.hits.at(30, 2).?.script_hit.id);
    try testing.expectEqual(hit_send, fx.hits.at(83, 2).?.script_hit.id);
    try testing.expectEqual(hit_split_toggle, fx.hits.at(77, 4).?.script_hit.id);
    try testing.expectEqual(hit_orient, fx.hits.at(82, 4).?.script_hit.id);
    try testing.expectEqual(hit_tab_base + 1, fx.hits.at(11, 5).?.script_hit.id);
    try testing.expectEqual(hit_tab_base + 5, fx.hits.at(38, 5).?.script_hit.id);
    try testing.expectEqual(hit_content, fx.hits.at(20, 8).?.script_hit.id);
    try testing.expectEqual(hit_resp_tab_base + 3, fx.hits.at(30, 19).?.script_hit.id);
    try testing.expectEqual(hit_ai_chip, fx.hits.at(64, 19).?.script_hit.id);
    try testing.expectEqual(hit_wrap, fx.hits.at(71, 19).?.script_hit.id);
    try testing.expectEqual(hit_copy, fx.hits.at(78, 19).?.script_hit.id);
    try testing.expectEqual(hit_type, fx.hits.at(84, 19).?.script_hit.id);
    try testing.expectEqual(hit_resp_body, fx.hits.at(30, 25).?.script_hit.id);
    try testing.expectEqual(hit_ai, fx.hits.at(10, 34).?.script_hit.id);
    // Colours: the method chip on green, the active tab bold, the bar
    // yellow, the send green.
    try testing.expect(fx.bgEql(3, 2, .{ .bg = fx.theme.palette.green }));
    try testing.expect(fx.style(11, 5).bold);
    try testing.expect(!fx.style(3, 5).bold);
    try testing.expect(fx.fgEql(11, 6, .{ .fg = fx.theme.palette.yellow }));
    try testing.expect(fx.fgEql(80, 2, .{ .fg = fx.theme.palette.green }));
}

test "after a send: the status title on the Response border, the Headers count, no AI chip on a 2xx, the gutter rows; wrap and scroll" {
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    const headers = [_]Pair{ .{ .key = "Content-Type", .value = "application/json" }, .{ .key = "Content-Length", .value = "49" }, .{ .key = "Server", .value = "x" }, .{ .key = "Date", .value = "y" }, .{ .key = "Last-Modified", .value = "z" } };
    m.response = .{
        .status = 200,
        .status_text = "OK",
        .headers = &headers,
        .body = "{\n  \"ok\": true,\n  \"items\": [\n    1,\n    2,\n    3\n  ],\n  \"name\": \"mnml\"\n}",
        .body_bytes = 49,
        .truncated = false,
        .timing = .{ .wait_ms = 1, .receive_ms = 1, .total_ms = 2 },
        .cookies = &.{},
    };
    m.block = .response;
    m.field = .content;
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(18, "\u{250C}" ++ "\u{2500}" ** 65 ++ " 200 OK  \u{00B7} 2ms \u{00B7} 49 B \u{2510}");
    try fx.expectRow(19, "\u{2502}  Body  Headers 5  Cookies  Timeline  Tests                      wrap   copy   JSON \u{25BC}  \u{2502}");
    try fx.expectRow(21, "\u{2502}" ++ " " ** 87 ++ "\u{2502}");
    try fx.expectRow(22, "\u{2502} 1 {" ++ " " ** 83 ++ "\u{2502}");
    try fx.expectRow(23, "\u{2502} 2   \"ok\": true," ++ " " ** 71 ++ "\u{2502}");
    try fx.expectRow(30, "\u{2502} 9 }" ++ " " ** 83 ++ "\u{2502}");
    try testing.expect(fx.fgEql(70, 18, .{ .fg = fx.theme.palette.green }));
    // The Headers tab lists `key: value`.
    m.response_tab = .headers;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(21, "\u{2502}  Content-Type: application/json" ++ " " ** 55 ++ "\u{2502}");
    // Scrolling a long body: twenty lines, the window from the third
    // row; the gutter is right-aligned to two digits.
    m.response_tab = .body;
    m.response.?.body = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nl16\nl17\nl18\nl19\nl20";
    view.scroll_line = 2;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(21, "\u{2502}  2 l2" ++ " " ** 81 ++ "\u{2502}");
    try fx.expectRow(29, "\u{2502} 10 l10" ++ " " ** 80 ++ "\u{2502}");
    // Past the end the window is pulled back.
    view.scroll_line = 40;
    _ = draw(ui, 3, ui.canvas.full(), m);
    // Twenty-one rows in an eleven-row window.
    try testing.expectEqual(@as(u32, 10), view.scroll_line);
    // Wrap: a body line past the width continues under a blank gutter
    // (the first chunk is a cell wider than the box, as Rust's, and is
    // clipped at the border).
    view.scroll_line = 0;
    m.body_wrap = true;
    m.response.?.body = "a" ** 100;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(22, "\u{2502} 1 " ++ "a" ** 84 ++ "\u{2502}");
    try fx.expectRow(23, "\u{2502}   " ++ "a" ** 15 ++ " " ** 69 ++ "\u{2502}");
    // A failure: the title and the AI chip.
    m.response = null;
    m.failed = "connection refused";
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(18, "\u{250C}" ++ "\u{2500}" ** 77 ++ " \u{2717} failed \u{2510}");
    try fx.expectRow(21, "\u{2502}  \u{2717} connection refused" ++ " " ** 65 ++ "\u{2502}");
    // Rust `draw_edit`'s tail under the request body: a blank row, then
    // the failure in red; while sending, the spinner line.
    try fx.expectRow(8, "\u{2502}" ++ " " ** 87 ++ "\u{2502}");
    try fx.expectRow(9, "\u{2502}  \u{2717} last send: connection refused" ++ " " ** 54 ++ "\u{2502}");
    try testing.expect(fx.fgEql(4, 9, .{ .fg = fx.theme.palette.red }));
    m.failed = null;
    m.sending = true;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(9, "\u{2502}  \u{27F3}  sending\u{2026}" ++ " " ** 74 ++ "\u{2502}");
    m.sending = false;
    try testing.expectEqual(hit_ai_chip, fx.hits.at(64, 19).?.script_hit.id);
}

test "response search: matches paint the match ground on the body and the headers, the current one its own; a wrapped line keeps them" {
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    const headers = [_]Pair{ .{ .key = "Content-Type", .value = "application/json" }, .{ .key = "Content-Length", .value = "49" } };
    const body = "{\n  \"ok\": true,\n  \"name\": \"ok ok\"\n}";
    // `ok` at 5, 27 and 30.
    const body_matches = [_]find_mod.Range{ .{ .start = 5, .end = 7 }, .{ .start = 27, .end = 29 }, .{ .start = 30, .end = 32 } };
    m.response = .{
        .status = 200,
        .status_text = "OK",
        .headers = &headers,
        .body = body,
        .body_bytes = body.len,
        .truncated = false,
        .timing = .{ .wait_ms = 1, .receive_ms = 1, .total_ms = 2 },
        .cookies = &.{},
        .headers_text = "Content-Type: application/json\nContent-Length: 49\n",
        .matches = &body_matches,
        .current_match = 1,
    };
    m.block = .response;
    m.field = .content;
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(23, "\u{2502} 2   \"ok\": true," ++ " " ** 71 ++ "\u{2502}");
    // Row 23 is line 2: `│ 2   "ok": true,` — the `o` at x 7.
    try testing.expect(!fx.bgEql(6, 23, fx.theme.match));
    try testing.expect(fx.bgEql(7, 23, fx.theme.match));
    try testing.expect(fx.bgEql(8, 23, fx.theme.match));
    try testing.expect(!fx.bgEql(9, 23, fx.theme.match));
    // Line 3 holds the current match (the first `ok`) and a plain one.
    try fx.expectRow(24, "\u{2502} 3   \"name\": \"ok ok\"" ++ " " ** 67 ++ "\u{2502}");
    try testing.expect(fx.bgEql(15, 24, fx.theme.current_match));
    try testing.expect(fx.fgEql(15, 24, fx.theme.current_match));
    try testing.expect(fx.bgEql(18, 24, fx.theme.match));
    try testing.expect(!fx.bgEql(17, 24, fx.theme.match));
    // The Headers tab, from the joined text: `json` at 26 in line 1.
    m.response_tab = .headers;
    const header_matches = [_]find_mod.Range{.{ .start = 26, .end = 30 }};
    m.response.?.matches = &header_matches;
    m.response.?.current_match = null;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(21, "\u{2502}  Content-Type: application/json" ++ " " ** 55 ++ "\u{2502}");
    try testing.expect(fx.bgEql(29, 21, fx.theme.match));
    try testing.expect(fx.bgEql(32, 21, fx.theme.match));
    try testing.expect(!fx.bgEql(28, 21, fx.theme.match));
    try testing.expect(!fx.bgEql(33, 21, fx.theme.match));
    // Wrapped: a long line's second chunk keeps a match that falls in it.
    m.response_tab = .body;
    m.body_wrap = true;
    m.response.?.body = "a" ** 90 ++ "zz" ++ "a" ** 5;
    const wrap_matches = [_]find_mod.Range{.{ .start = 90, .end = 92 }};
    m.response.?.matches = &wrap_matches;
    _ = draw(ui, 3, ui.canvas.full(), m);
    // (The first chunk is 85 cells, clipped at the border, as Rust's.)
    try fx.expectRow(23, "\u{2502}   " ++ "a" ** 5 ++ "zz" ++ "a" ** 5 ++ " " ** 72 ++ "\u{2502}");
    try testing.expect(fx.bgEql(9, 23, fx.theme.match));
    try testing.expect(fx.bgEql(10, 23, fx.theme.match));
    try testing.expect(!fx.bgEql(8, 23, fx.theme.match));
    try testing.expect(!fx.bgEql(11, 23, fx.theme.match));
}

test "the Params table, the draft row and Add row; the split halves; a wide pane goes side by side with the full top bar" {
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var split_scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    m.edit_tab = .params;
    m.field = .content;
    m.params = &.{.{ .key = "a", .value = "1" }};
    m.url_vars = &.{.{ .start = 8, .end = 15, .resolved = true, .id = 0 }};
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    // table_w = clamp(87 - 5, 20, 100) = 82; name 26, value 49.
    try fx.expectRow(6, "\u{2502}  \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}" ++ " " ** 79 ++ "\u{2502}");
    // Rust's table is a cell wider than the box (its own right edge is
    // clipped away), so the last column is the box border.
    try fx.expectRow(7, "\u{2502}  \u{250C}" ++ "\u{2500}" ** 28 ++ "\u{252C}" ++ "\u{2500}" ** 51 ++ "\u{252C}\u{2500}\u{2500}\u{2500}\u{2502}");
    try fx.expectRow(8, "\u{2502}  \u{2502} Name" ++ " " ** 22 ++ " \u{2502} Value" ++ " " ** 44 ++ " \u{2502}   \u{2502}");
    try fx.expectRow(10, "\u{2502}  \u{2502} a" ++ " " ** 25 ++ " \u{2502} 1" ++ " " ** 48 ++ " \u{2502} \u{2715} \u{2502}");
    try fx.expectRow(11, "\u{2502}  \u{2514}" ++ "\u{2500}" ** 28 ++ "\u{2534}" ++ "\u{2500}" ** 51 ++ "\u{2534}\u{2500}\u{2500}\u{2500}\u{2502}");
    try fx.expectRow(12, "\u{2502}  + Add row" ++ " " ** 76 ++ "\u{2502}");
    try testing.expectEqual(hit_param_row, fx.hits.at(10, 10).?.script_hit.id);
    try testing.expectEqual(hit_param_del, fx.hits.at(85, 10).?.script_hit.id);
    try testing.expectEqual(hit_add_row, fx.hits.at(5, 12).?.script_hit.id);
    try testing.expectEqual(hit_var_base, fx.hits.at(24, 2).?.script_hit.id);
    // The draft row: the caret mark in the name, `✓` dim until both
    // cells hold text.
    m.draft = .{ .key = "", .value = "", .key_caret = 0, .value_caret = 0, .on_value = false };
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(12, "\u{2502}  \u{2502} \u{258F}" ++ " " ** 25 ++ " \u{2502} (value)" ++ " " ** 42 ++ " \u{2502} \u{2713} \u{2502}");
    try testing.expectEqual(hit_draft_commit, fx.hits.at(85, 12).?.script_hit.id);
    try testing.expectEqual(hit_draft_value, fx.hits.at(40, 12).?.script_hit.id);
    try testing.expect(fx.fgEql(85, 12, .{ .fg = fx.theme.palette.comment }));
    // The split: both halves carry a strip, the divider is a hit.
    m.draft = null;
    m.split = .{ .tab = .vars, .ratio = 50, .scroll = &split_scroll };
    _ = draw(ui, 3, ui.canvas.full(), m);
    const txt = try fx.text();
    // The 43-cell left half holds the strip exactly; the divider follows.
    try testing.expect(std.mem.indexOf(u8, txt, "Params  Body  Headers  Auth  Vars  Script\u{2502}  Params  Body") != null);
    try testing.expectEqual(hit_split_divider, fx.hits.at(44, 8).?.script_hit.id);
    try testing.expectEqual(hit_split_tab_base + 4, fx.hits.at(78, 5).?.script_hit.id);
    try testing.expect(fx.fgEql(77, 4, .{ .fg = fx.theme.palette.cyan }));
    // 120 cells: the full top bar, the blocks side by side.
    var wide = try fixture.init(120, 40);
    defer wide.deinit();
    m.split = null;
    m.env_name = "dev";
    const wui = wide.ui();
    _ = draw(wui, 3, wui.canvas.full(), m);
    try wide.expectRow(1, "\u{250C} Method \u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\u{250C} URL " ++ "\u{2500}" ** 38 ++ "\u{2510}\u{250C} Env \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\u{250C} Send \u{2500}\u{2500}\u{2510}\u{250C} Save \u{2500}\u{2500}\u{2510}\u{250C} Clear \u{2500}\u{2500}\u{2510}\u{250C} Copy as\u{2026} \u{2500}\u{2500}\u{2500}\u{2500}\u{2510}");
    try wide.expectRow(2, "\u{2502}  GET     \u{25BC} \u{2502}\u{2502} https://httpbin.org/get" ++ " " ** 19 ++ "\u{2502}\u{2502}   dev \u{25BE}    \u{2502}\u{2502} \u{25B6} Send \u{2502}\u{2502} \u{2398} Save \u{2502}\u{2502} \u{2715} Clear \u{2502}\u{2502} </> Copy as\u{2026} \u{2502}");
    try testing.expectEqual(hit_env, wide.hits.at(60, 2).?.script_hit.id);
    // Method 0..13, URL 14..58, Env 59..72, Send 73..82, Save 83..92,
    // Clear 93..103, Copy as… 104..119.
    try testing.expectEqual(hit_send, wide.hits.at(77, 2).?.script_hit.id);
    try testing.expectEqual(hit_save, wide.hits.at(86, 2).?.script_hit.id);
    try testing.expectEqual(hit_clear, wide.hits.at(96, 2).?.script_hit.id);
    try testing.expectEqual(hit_code, wide.hits.at(108, 2).?.script_hit.id);
    const wt = try wide.text();
    try testing.expect(std.mem.indexOf(u8, wt, "\u{2510}\u{250C}" ++ "\u{2500}" ** 3) != null);
    try testing.expect(std.mem.indexOf(u8, wt, "not sent yet") != null);
    const z = zones(wui.canvas.full(), m);
    try testing.expectEqual(@as(u16, 60), z.request.w);
    try testing.expectEqual(@as(u16, 60), z.response.x);
}

test "the var tip lands under its anchor" {
    var fx = try fixture.init(60, 6);
    defer fx.deinit();
    const ui = fx.ui();
    drawVarTip(ui, ui.canvas.full(), Rect.init(10, 1, 8, 1), "HOST", "https://dev", "dev");
    const txt = try fx.text();
    try testing.expect(std.mem.indexOf(u8, txt, "{{HOST}} = https://dev") != null);
    drawVarTip(ui, ui.canvas.full(), Rect.init(10, 1, 8, 1), "NOPE", null, "dev");
    const txt2 = try fx.text();
    try testing.expect(std.mem.indexOf(u8, txt2, "{{NOPE}} \u{2014} not defined in env dev") != null);
}

test "the Headers table: rows in cells with their `{{VAR}}` spans, the draft's caret for the popup, the `?` tip under the cursor row" {
    var fx = try fixture.init(70, 14);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    m.field = .content;
    m.edit_tab = .headers;
    m.headers_text = "Accept: application/json\nAuthorization: Bearer {{TOKEN}}\n";
    const rows = [_]Pair{ .{ .key = "Accept", .value = "application/json" }, .{ .key = "Authorization", .value = "Bearer {{TOKEN}}" } };
    m.headers = &rows;
    m.header_value_offs = &.{ 8, 40 };
    m.headers_vars = &.{.{ .start = 47, .end = 56, .resolved = true, .id = 0 }};
    m.row_cursor = 1;
    m.header_tip = " Authorization \u{2014} Credentials for the resource ";
    const r = Rect.init(0, 0, 70, 14);
    const t = drawKvTable(fx.ui(), 0, r, &rows, null, .{ .kind = .headers, .row_hit = hit_header_row, .del_hit = hit_header_del, .add = true, .cursor = 1, .focused = true, .value_offs = m.header_value_offs, .vars = m.headers_vars, .tip = m.header_tip });
    try testing.expect(t.caret == null);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, fx.row(3, &buf), "\u{2502} Accept") != null);
    try testing.expect(std.mem.indexOf(u8, fx.row(3, &buf), "\u{2502} application/json") != null);
    try testing.expect(std.mem.indexOf(u8, fx.row(5, &buf), "Bearer {{TOKEN}}") != null);
    // The span is a hit (`hit_var_base + id`) inside the value cell; the
    // rows and their ✕ are hits too.
    try testing.expect(fx.hits.at(45, 5) != null);
    var var_hit = false;
    for (fx.hits.items.items) |e| switch (e.target) {
        .script_hit => |sh| if (sh.id == hit_var_base) {
            var_hit = true;
            try testing.expectEqual(@as(u16, 5), e.rect.y);
        },
        else => {},
    };
    try testing.expect(var_hit);
    try testing.expectEqual(hit_header_row + 1, fx.hits.at(4, 5).?.script_hit.id);
    // The tip hangs under the cursor row (row 5 → row 6).
    try testing.expect(std.mem.indexOf(u8, fx.row(6, &buf), "Authorization \u{2014} Credentials") != null);
    // A draft: the caret sits at the mark's cell, for the popup.
    var fx2 = try fixture.init(70, 14);
    defer fx2.deinit();
    const d: Draft = .{ .key = "Conte", .value = "", .key_caret = 5, .value_caret = 0, .on_value = false };
    const t2 = drawKvTable(fx2.ui(), 0, r, &rows, d, .{ .kind = .headers, .row_hit = hit_header_row, .del_hit = hit_header_del, .add = true, .cursor = 0, .focused = true });
    try testing.expect(t2.caret != null);
    try testing.expectEqual(@as(u16, 7), t2.caret.?.y);
    try testing.expect(std.mem.indexOf(u8, fx2.row(7, &buf), "Conte\u{258F}") != null);
    try testing.expectEqual(@as(u16, 4 + 5), t2.caret.?.x);
    // Params never returns one.
    const t3 = drawKvTable(fx2.ui(), 0, r, &rows, d, .{ .kind = .params, .row_hit = hit_param_row, .del_hit = hit_param_del, .add = true, .cursor = 0, .focused = true });
    try testing.expect(t3.caret == null);
}

test "the Params tab with path params: the Path group over Query, the unset value's words, the path rows' hits; without any the query table alone" {
    // Tall enough for both groups: the Path group is eight rows.
    var fx = try fixture.init(89, 50);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    m.edit_tab = .params;
    m.field = .content;
    m.url = "https://x/users/:id/posts/:post_id";
    m.params = &.{.{ .key = "a", .value = "1" }};
    m.path_params = &.{ .{ .key = "id", .value = "42" }, .{ .key = "post_id", .value = "" } };
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    const txt = try fx.text();
    try testing.expect(std.mem.indexOf(u8, txt, "  Path") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "  Query") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{2502} id ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{2502} 42 ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "(unset \u{2014} Enter sets it)") != null);
    // Row 7 is `Path`, 8 the top rule, 9 the header, 10 the rule, 11 `id`, 12 rule, 13 `post_id`.
    try testing.expectEqual(hit_path_row, fx.hits.at(10, 11).?.script_hit.id);
    try testing.expectEqual(hit_path_row + 1, fx.hits.at(10, 13).?.script_hit.id);
    // The cursor rests on the first path row (cyan); the second is purple.
    try testing.expect(fx.fgEql(6, 11, .{ .fg = fx.theme.palette.cyan }));
    try testing.expect(fx.fgEql(6, 13, .{ .fg = fx.theme.palette.purple }));
    // The query table follows; its first row is a hit of its own.
    const q_row = std.mem.indexOf(u8, txt, "\u{2502} a ").?;
    const q_y: u16 = @intCast(std.mem.count(u8, txt[0..q_row], "\n"));
    try testing.expectEqual(hit_param_row, fx.hits.at(10, q_y).?.script_hit.id);
    // The cursor on the second path row: it is the cyan one, the query row is not.
    m.row_cursor = 1;
    _ = draw(ui, 3, ui.canvas.full(), m);
    try testing.expect(fx.fgEql(6, 13, .{ .fg = fx.theme.palette.cyan }));
    try testing.expect(fx.fgEql(6, 11, .{ .fg = fx.theme.palette.purple }));
    try testing.expect(!fx.fgEql(6, q_y, .{ .fg = fx.theme.palette.cyan }));
}

test "the body-type chip: absent on the default screen, on the strip once the tab has the keyboard, the mode bracketed, one hit" {
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    const before = try fx.text();
    try testing.expect(std.mem.indexOf(u8, before, "[raw]") == null);
    m.field = .content;
    _ = draw(ui, 3, ui.canvas.full(), m);
    const focused = try fx.text();
    try testing.expect(std.mem.indexOf(u8, focused, "[raw] JSON  form  multipart") != null);
    // The chip's hit spans the four words on the strip row (row 4).
    const at = std.mem.indexOf(u8, focused, "[raw]").?;
    const row_start = std.mem.lastIndexOfScalar(u8, focused[0..at], '\n').? + 1;
    const y: u16 = @intCast(std.mem.count(u8, focused[0..at], "\n"));
    const x: u16 = @intCast(try std.unicode.utf8CountCodepoints(focused[row_start..at]));
    try testing.expectEqual(hit_body_type, fx.hits.at(x + 1, y).?.script_hit.id);
    try testing.expectEqual(hit_body_type, fx.hits.at(x + 20, y).?.script_hit.id);
    // A non-raw mode shows without the keyboard.
    m.field = .url;
    m.body_type = .multipart;
    _ = draw(ui, 3, ui.canvas.full(), m);
    const multi = try fx.text();
    try testing.expect(std.mem.indexOf(u8, multi, " raw  JSON  form [multipart]") != null);
}

test "the description row: under the top bar when the block has a description or tags, absent otherwise; the blocks move down a row" {
    var fx = try fixture.init(89, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    const ui = fx.ui();
    const bare = zones(ui.canvas.full(), m);
    try testing.expect(bare.desc == null);
    m.description = "List the users, paged";
    m.tags = &.{ "users", "smoke" };
    const z = zones(ui.canvas.full(), m);
    try testing.expectEqual(@as(u16, 4), z.desc.?.y);
    try testing.expectEqual(bare.request.y + 1, z.request.y);
    try testing.expectEqual(bare.ai.y, z.ai.y);
    try testing.expectEqual(bare.request.h + bare.response.h - 1, z.request.h + z.response.h);
    _ = draw(ui, 3, ui.canvas.full(), m);
    try fx.expectRow(4, "  \u{25B8} List the users, paged" ++ " " ** 50 ++ "#users  #smoke");
    try testing.expect(fx.fgEql(76, 4, .{ .fg = fx.theme.palette.cyan }));
    // Tags alone still take the row; a short pane drops it.
    m.description = null;
    _ = draw(ui, 3, ui.canvas.full(), m);
    const txt = try fx.text();
    try testing.expect(std.mem.indexOf(u8, txt, "#users  #smoke") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "List the users") == null);
    try testing.expect(zones(Rect.init(0, 0, 89, 11), m).desc == null);
}

test "a narrow response strip keeps its labels whole and drops the chips that would paint over them" {
    // The hunt's 80×24 pane: 47 cells. The five labels take 41 of the
    // 45 inside the border; no chip fits after them.
    var fx = try fixture.init(47, 36);
    defer fx.deinit();
    var view: editor_view.ViewState = .{};
    var scroll: usize = 0;
    var m = baseModel(&scroll, &view);
    m.failed = "not sent yet";
    const ui = fx.ui();
    _ = draw(ui, 3, ui.canvas.full(), m);
    var found = false;
    var y: u16 = 0;
    while (y < 36) : (y += 1) {
        var buf: [256]u8 = undefined;
        const row = fx.row(y, &buf);
        if (std.mem.indexOf(u8, row, "Cookies") == null) continue;
        found = true;
        try testing.expect(std.mem.indexOf(u8, row, "Body  Headers  Cookies  Timeline  Tests") != null);
        try testing.expect(std.mem.indexOf(u8, row, "\u{25BC}") == null);
        try testing.expect(std.mem.indexOf(u8, row, "AI") == null);
        try testing.expect(std.mem.indexOf(u8, row, "wrap") == null);
    }
    try testing.expect(found);
    // Wider: the chips come back from the right as room allows — the
    // type chip first, then copy, wrap, and the ⚡ AI chip last.
    var wide = try fixture.init(66, 36);
    defer wide.deinit();
    const wui = wide.ui();
    _ = draw(wui, 3, wui.canvas.full(), m);
    y = 0;
    while (y < 36) : (y += 1) {
        var buf: [256]u8 = undefined;
        const row = wide.row(y, &buf);
        if (std.mem.indexOf(u8, row, "Cookies") == null) continue;
        try testing.expect(std.mem.indexOf(u8, row, "Body  Headers  Cookies  Timeline  Tests") != null);
        try testing.expect(std.mem.indexOf(u8, row, "\u{2014} \u{25BC}") != null);
        try testing.expect(std.mem.indexOf(u8, row, "copy") != null);
        try testing.expect(std.mem.indexOf(u8, row, "AI") == null);
    }
}
