//! The statusline's chips — everything the app knows that the bottom
//! row shows, built into `ui/statusline.zig` `Seg`s each frame. The
//! component paints the two lanes; this module decides what is in them,
//! in the Rust editor's order, glyphs and colours:
//!
//!   left   mode · host segments · branch · PR · file (glyph, name, `●`)
//!          · diagnostics · enclosing symbol · macro · find
//!   right  host segments · tests · Claude · Codex · coverage · transfer
//!          · LSP · RESTRICTED · WRAP · autosave · size · Ln/Col · Sel ·
//!          stress · bell · clock · workspace · language
//!
//! Every chip registers a `.statusline_seg` hit with an id from here
//! (`SegId`) or from the component's fixed set; `dispatch.mouse` routes
//! them, `discovery.describe` explains them. The mode chip is the one
//! place the editing mode is read for paint (`modeOf`).
//!
//! // changed: the row is Rust mnml's statusline, not the plain
//! `Ln 0/0 Col 0  standard  ○  23:58` the first pass painted. Gone with
//! it: the indent (`⇥ 4`) and encoding (`utf-8`) chips and the
//! input-style chip — the Rust screen has none; the keymap is what the
//! mode chip cycles, and the far-right chip is the language. The
//! now-playing and Sonos clusters are cut. What Zig has that Rust lacks
//! stays: the transfer chip, a Lua script's segments, and the drop rule
//! for a right lane that still does not fit after the left is clipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const Color = Theme.Color;
const sl = @import("../ui/statusline.zig");
const Seg = sl.Seg;
const file_glyph = @import("../ui/file_glyph.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const remote = @import("../git/remote.zig");
const parse = @import("../git/parse.zig");
const lsp = @import("lsp.zig");
const transcript = @import("../ai/transcript.zig");
const coverage = @import("coverage.zig");
const transfers = @import("transfers.zig");
const stress = @import("stress.zig");
const clock_mod = @import("clock.zig");
const tests_pane = @import("tests_pane.zig");
const outline = @import("outline.zig");
const ids = @import("../core/ids.zig");

pub const FocusId = ids.FocusId;

/// The app's hit ids, from `seg_app_base`.
pub const SegId = enum(u32) {
    branch = sl.seg_app_base,
    /// The open PR on this branch (`GH#42`).
    pr,
    /// The error / warning counts after the file name.
    diagnostics,
    /// The enclosing symbol (` › main `).
    symbol,
    /// ` ● rec @q ` while a macro records.
    macro,
    /// ` /query 2/9 ` while a find has matches.
    find,
    /// The test runner's pane, while one is open.
    test_run,
    ai_claude,
    ai_codex,
    coverage,
    transfer,
    /// ` LSP 2 ` — running language servers.
    lsp,
    wrap,
    autosave,
    filesize,
    sel,
    stress,
    bell,
    clock,
    workspace,
    _,

    pub fn of(id: u32) ?SegId {
        if (id < sl.seg_app_base or id > @intFromEnum(SegId.workspace)) return null;
        return @enumFromInt(id);
    }

    pub fn raw(s: SegId) u32 {
        return @intFromEnum(s);
    }
};

/// Anthropic's coral, when the icon table carries no colour.
const claude_brand = Theme.rgb(0xd16d51);
/// Near-black — readable on the coral whatever the theme.
const claude_ink = Theme.rgb(0x1a1a1a);

/// The largest buffer the symbol chip scans per frame without a server.
pub const symbol_scan_max: usize = 64 * 1024;

/// Rust's per-side cap on host segments: a third of the row, at least 20.
pub fn dynamicLaneBudget(width: u16) usize {
    return @max(width / 3, 20);
}

// ─── the mode ────────────────────────────────────────────────────────────

pub const Mode = struct { label: []const u8, kind: sl.ModeKind, vim: bool };

/// Where the keys go under an overlay: the prompt's or the menu's way
/// back, else the active pane (the tree when there is none).
fn focusUnder(app: *const App) FocusId {
    const fallback: FocusId = if (app.active != null) .{ .pane = app.active.? } else .tree;
    return switch (app.focus) {
        .overlay => switch (app.overlay) {
            .prompt => |p| p.return_focus orelse fallback,
            .menu => |m| m.return_focus,
            else => fallback,
        },
        else => app.focus,
    };
}

/// The vim mode when a pane with a buffer has focus; else the context
/// label — TREE, PANEL, EDIT for a writable buffer, VIEW for anything
/// else the pane shows (Rust `mode_chip`).
pub fn modeOf(app: *App) Mode {
    const focus = focusUnder(app);
    const editor = if (focus == .pane) app.activeEditor() else null;
    if (editor) |e| {
        const m = e.buf.input.mode();
        if (m.label()) |label| return .{ .label = label, .kind = switch (m) {
            .normal => .normal,
            .insert => .insert,
            .replace => .replace,
            .visual, .visual_line, .visual_block => .visual,
            .none => unreachable,
        }, .vim = true };
    }
    return switch (focus) {
        .tree => .{ .label = "TREE", .kind = .tree, .vim = false },
        .panel => .{ .label = "PANEL", .kind = .panel, .vim = false },
        .pane, .overlay => if (editor) |e|
            (if (e.buf.doc.read_only) Mode{ .label = "VIEW", .kind = .view, .vim = false } else Mode{ .label = "EDIT", .kind = .edit, .vim = false })
        else
            .{ .label = "VIEW", .kind = .view, .vim = false },
    };
}

// ─── building ────────────────────────────────────────────────────────────

const Lane = std.ArrayListUnmanaged(Seg);

fn push(lane: *Lane, arena: Allocator, seg: Seg) Allocator.Error!void {
    try lane.append(arena, seg);
}

/// Rec.601 luma under 0.5 — white text goes on it.
fn isDark(c: Color) bool {
    return switch (c) {
        .rgb => |v| (0.299 * @as(f32, @floatFromInt(v[0])) + 0.587 * @as(f32, @floatFromInt(v[1])) + 0.114 * @as(f32, @floatFromInt(v[2]))) < 128.0,
        else => false,
    };
}

/// A host segment: its named colour as the ground (the muted colour
/// when it names none), dark or light text for contrast, its slot as
/// the hit.
fn dynSeg(ui: Ui, r: ipc.effects.Rendered) Seg {
    const p = &ui.theme.palette;
    const bg = if (r.color) |c| integrations_view.paletteColor(ui.theme, c) else p.comment;
    const fg = if (isDark(bg)) p.fg else p.bg_darker;
    return Seg.init(ui.fmt(" {s} ", .{r.text}), fg, bg).withHit(sl.seg_dyn_base + r.index);
}

/// The counts the branch chip shows, NvChad style: a file is added,
/// changed or removed once, by the more decisive of its two sides
/// (the staged entry is listed first; an unstaged entry for the same
/// path is the same file).
pub const FileCounts = struct { added: u32 = 0, changed: u32 = 0, removed: u32 = 0, conflicts: u32 = 0 };

pub fn fileCounts(s: parse.Status) FileCounts {
    var out: FileCounts = .{};
    var prev_path: ?[]const u8 = null;
    for (s.entries) |e| {
        defer prev_path = e.path;
        if (prev_path) |pp| if (std.mem.eql(u8, pp, e.path)) continue;
        switch (e.group) {
            .conflicted => out.conflicts += 1,
            .untracked => out.added += 1,
            .staged, .unstaged => switch (e.code) {
                'A' => out.added += 1,
                'D' => out.removed += 1,
                'M', 'R', 'C', 'T' => out.changed += 1,
                else => {},
            },
        }
    }
    return out;
}

/// The forge glyph before the branch name.
fn providerGlyph(p: remote.Provider) []const u8 {
    return switch (p) {
        .github => sl.github_glyph,
        .gitlab => sl.gitlab_glyph,
        .bitbucket => sl.bitbucket_glyph,
        .azure => sl.azure_glyph,
        .other => sl.forge_glyph,
        .none => sl.branch_glyph,
    };
}

fn hostTag(p: remote.Provider) []const u8 {
    return switch (p) {
        .github => "GH#",
        .gitlab => "GL!",
        .bitbucket => "BB#",
        .azure => "AZ#",
        .other, .none => "#",
    };
}

fn branchSeg(app: *App, ui: Ui) Allocator.Error!?Seg {
    const st = &app.git;
    const branch = st.branchLabel() orelse return null;
    const s = st.status.?;
    const p = &ui.theme.palette;
    const nerd = !ui.ascii;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (nerd) try out.print(ui.arena, " {s} {s}", .{ providerGlyph(st.provider), branch }) else try out.print(ui.arena, " {s}", .{branch});
    if (s.ahead > 0) try out.print(ui.arena, "  {s}{d}", .{ if (ui.ascii) "^" else "⇡", s.ahead });
    if (s.behind > 0) try out.print(ui.arena, " {s}{d}", .{ if (ui.ascii) "v" else "⇣", s.behind });
    const c = fileCounts(s);
    if (c.added > 0) try out.print(ui.arena, "  {s} {d}", .{ if (ui.ascii) sl.added_ascii else sl.added_glyph, c.added });
    if (c.changed > 0) try out.print(ui.arena, "  {s} {d}", .{ if (ui.ascii) sl.changed_ascii else sl.changed_glyph, c.changed });
    if (c.removed > 0) try out.print(ui.arena, "  {s} {d}", .{ if (ui.ascii) sl.removed_ascii else sl.removed_glyph, c.removed });
    if (c.conflicts > 0) try out.print(ui.arena, "  {s}{d}", .{ if (ui.ascii) "!" else "⚠", c.conflicts });
    try out.append(ui.arena, ' ');
    return Seg.init(out.items, p.green, p.bg2).withHit(SegId.branch.raw());
}

/// The open PR on the current branch, when the branch rail has fetched one.
pub fn currentPr(app: *const App) ?parse.Pr {
    const branch = app.git.branchLabel() orelse return null;
    for (app.git.rail_prs) |pr| if (std.mem.eql(u8, pr.branch, branch)) return pr;
    return null;
}

/// The icon table's entry for a built-in integration, when it is on.
fn enabledIcon(app: *const App, id: []const u8) ?@import("../config/Config.zig").IntegrationIcon {
    for (app.cfg.ui.integration_icons) |ic| if (std.mem.eql(u8, ic.id, id) and ic.enabled) return ic;
    return null;
}

fn iconColor(ui: Ui, ic: anytype, fallback: Color) Color {
    return if (ic.color.len > 0) integrations_view.paletteColor(ui.theme, ic.color) else fallback;
}

/// Builds the frame's lanes on the frame arena.
pub fn build(app: *App, ui: Ui, area: Rect) Allocator.Error!sl.Info {
    const arena = ui.arena;
    const t = ui.theme;
    const p = &t.palette;
    const nerd = !ui.ascii;
    var left: Lane = .empty;
    var right: Lane = .empty;
    var middle: ?[]const u8 = null;

    // ── mode ──
    const mode = modeOf(app);
    const mode_bg = sl.modeBg(t, mode.kind);
    if (mode.vim and nerd) {
        // NvChad's vim accent: the diamond-V in orange, dark on orange
        // would vanish (REPLACE), so it goes near-black there.
        const glyph_fg = if (Color.eql(mode_bg, p.orange)) p.bg_darker else p.orange;
        try push(&left, arena, Seg.init(" " ++ sl.vim_glyph ++ " ", glyph_fg, mode_bg).strong().withHit(sl.seg_mode));
        try push(&left, arena, Seg.init(ui.fmt("{s} ", .{mode.label}), p.bg_darker, mode_bg).strong().withHit(sl.seg_mode));
    } else {
        try push(&left, arena, Seg.init(ui.fmt(" {s} ", .{mode.label}), p.bg_darker, mode_bg).strong().withHit(sl.seg_mode));
    }

    // ── host segments, left lane ──
    const budget = dynamicLaneBudget(area.w);
    for (try ipc.effects.pack(arena, app.ipc_fx.segments.items, .left, budget, ui.ascii)) |r| try push(&left, arena, dynSeg(ui, r));

    // ── branch, PR ──
    if (try branchSeg(app, ui)) |s| try push(&left, arena, s);
    if (currentPr(app)) |pr| {
        try push(&left, arena, Seg.init(ui.fmt("  {s}{d} ", .{ hostTag(app.git.provider), pr.number }), p.purple, p.bg2).withHit(SegId.pr.raw()));
    }

    // ── file: glyph in its colour, name, dirty dot; then what the file says ──
    const editor = app.activeEditor();
    if (editor) |e| {
        const path = e.buf.doc.path;
        const name = if (path) |pth| std.fs.path.basename(pth) else "[scratch]";
        const icon = file_glyph.forName(name);
        try push(&left, arena, Seg.init(ui.fmt(" {s} ", .{if (nerd) icon.glyph else icon.fallback}), icon.color, p.statusline).withHit(sl.seg_file));
        try push(&left, arena, Seg.init(ui.fmt("{s}{s} ", .{ name, if (e.buf.doc.dirty) " ●" else "" }), p.fg, p.statusline).withHit(sl.seg_file));
        if (path) |pth| {
            var errors: u32 = 0;
            var warnings: u32 = 0;
            for (lsp.diagnosticsFor(app, pth)) |d| switch (d.severity) {
                .err => errors += 1,
                .warning => warnings += 1,
                else => {},
            };
            if (errors > 0) try push(&left, arena, Seg.init(ui.fmt(" {s} {d} ", .{ if (ui.ascii) sl.errors_ascii else sl.errors_glyph, errors }), p.red, p.statusline).withHit(SegId.diagnostics.raw()));
            if (warnings > 0) try push(&left, arena, Seg.init(ui.fmt(" {s} {d} ", .{ if (ui.ascii) "W" else "⚠", warnings }), p.yellow, p.statusline).withHit(SegId.diagnostics.raw()));
            // The enclosing symbol: the last one placed at or above the
            // cursor's line — the server's when it has sent them, else the
            // outline's line scan, kept to files small enough to read
            // every frame (the Rust chip regex-scanned a 13k-line file per
            // frame and paid 45 ms for it).
            const row: u32 = @intCast(e.buf.editor.rowCol().row);
            var pick: ?[]const u8 = null;
            if (app.lsp.symbols.get(pth)) |set| {
                for (set.items) |sym| if (sym.line <= row) {
                    pick = sym.name;
                };
            } else if (e.buf.doc.language) |key| if (e.buf.editor.bytes().len <= symbol_scan_max) {
                for (try outline.fallback(arena, e.buf.editor.bytes(), key)) |sym| if (sym.line <= row) {
                    pick = sym.name;
                };
            };
            if (pick) |sym_name| try push(&left, arena, Seg.init(ui.fmt(" › {s} ", .{ui.clipStr(sym_name, 40)}), p.purple, p.statusline).withHit(SegId.symbol.raw()));
        }
        if (e.buf.recording) |r| try push(&left, arena, Seg.init(ui.fmt(" ● rec @{c} ", .{r.reg}), p.bg_darker, p.red).withHit(SegId.macro.raw()));
        if (e.find.matches.items.len > 0) {
            const q = e.find.query.items;
            const shown = ui.clipStr(q, 24);
            const cur = if (e.find.current) |i| i + 1 else 0;
            try push(&left, arena, Seg.init(ui.fmt(" /{s} {d}/{d} ", .{ shown, cur, e.find.matches.items.len }), p.bg_darker, p.yellow).withHit(SegId.find.raw()));
        }
        if (try e.buf.input.pendingDisplay(arena)) |pend| if (pend.len > 0 and pend[0] != ':') {
            middle = pend;
        };
    } else {
        try push(&left, arena, Seg.init(" [no file] ", p.comment, p.statusline));
    }

    // ── right lane ──
    for (try ipc.effects.pack(arena, app.ipc_fx.segments.items, .right, budget, ui.ascii)) |r| try push(&right, arena, dynSeg(ui, r));
    for (try app.script().segmentTexts(arena, .left)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.comment));
    if (tests_pane.find(app)) |id| if (app.panes.get(id)) |pane| switch (pane.*) {
        .tests => |*tp| try push(&right, arena, Seg.init(ui.fmt(" {s} {s} ", .{ if (ui.ascii) "T" else "\u{1f9ea}", tp.title() }), p.bg_darker, p.yellow).withHit(SegId.test_run.raw())),
        else => {},
    };
    // The AI meters, each while its integration is on. Zig's meter is
    // the local 24h spend (`ai.refresh_usage`); the quota percent the
    // Rust chip showed needs an endpoint this build does not call.
    if (enabledIcon(app, "claude_code")) |ic| {
        const glyph = if (ui.ascii) sl.claude_ascii else sl.claude_glyph;
        var buf: [16]u8 = undefined;
        const text: ?[]const u8 = if (app.ai.meter) |m| switch (app.cfg.ai.claude_meter_mode) {
            .off => null,
            .compact => ui.fmt(" {s} ${d:.2} ", .{ glyph, m.cost_usd }),
            .ticker => ui.fmt(" {s} {s} · ${d:.2} ", .{ glyph, transcript.fmtTokens(&buf, m.tokens), m.cost_usd }),
        } else ui.fmt(" {s} … ", .{glyph});
        if (text) |txt| try push(&right, arena, Seg.init(txt, claude_ink, iconColor(ui, ic, claude_brand)).withHit(SegId.ai_claude.raw()));
    }
    if (enabledIcon(app, "codex")) |_| {
        const glyph = if (ui.ascii) sl.codex_ascii else sl.codex_glyph;
        var buf: [16]u8 = undefined;
        const seg = if (app.ai.meter) |m|
            Seg.init(ui.fmt(" {s} {s} ", .{ glyph, transcript.fmtTokens(&buf, m.tokens) }), p.bg_darker, p.cyan)
        else
            Seg.init(ui.fmt(" {s} … ", .{glyph}), p.comment, p.cyan);
        try push(&right, arena, seg.withHit(SegId.ai_codex.raw()));
    }
    if (coverage.shown(app)) |shown| {
        const glyph = if (ui.ascii) sl.coverage_ascii else if (enabledIcon(app, "acmeco_coverage")) |ic| (if (ic.glyph.len > 0) ic.glyph else sl.coverage_glyph) else sl.coverage_glyph;
        var seg = Seg.init("", p.bg_darker, p.teal).withHit(SegId.coverage.raw());
        var head: std.ArrayListUnmanaged(u8) = .empty;
        try head.print(arena, " {s} ", .{glyph});
        var tail: std.ArrayListUnmanaged(u8) = .empty;
        if (shown.feature) |f| {
            try head.appendSlice(arena, try coverage.pct(arena, "F", f.now));
            const d = try coverage.delta(arena, f);
            seg.accent = .{ .text = d.text, .fg = switch (d.dir) {
                .up => p.green,
                .down => p.red,
                .flat, .none => p.bg_darker,
            } };
            if (shown.code) |c| {
                try tail.print(arena, " · {s}{s}", .{ try coverage.pct(arena, "C", c.now), (try coverage.delta(arena, c)).text });
            }
        } else if (shown.code) |c| {
            try head.appendSlice(arena, try coverage.pct(arena, "C", c.now));
            const d = try coverage.delta(arena, c);
            seg.accent = .{ .text = d.text, .fg = switch (d.dir) {
                .up => p.green,
                .down => p.red,
                .flat, .none => p.bg_darker,
            } };
        }
        try tail.append(arena, ' ');
        seg.text = head.items;
        seg.tail = tail.items;
        try push(&right, arena, seg);
    }
    if (try transfers.chip(app, arena, ui.ascii)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.cyan).withHit(SegId.transfer.raw()));
    var servers: u32 = 0;
    for (app.lsp.servers.items) |s| if (!s.transport.isDead()) {
        servers += 1;
    };
    if (servers > 0) try push(&right, arena, Seg.init(ui.fmt(" LSP {d} ", .{servers}), p.bg_darker, p.blue).withHit(SegId.lsp.raw()));
    if (app.loaded != null and !app.workspace_trusted and app.loaded.?.trust_prompt != null) {
        try push(&right, arena, Seg.init(if (nerd) " " ++ sl.restricted_glyph ++ " RESTRICTED " else " RESTRICTED ", p.bg_darker, p.yellow).withHit(sl.seg_restricted));
    }
    // WRAP: the active editor's own setting when it has one (a click
    // flips that), else the config's.
    const wrap_on = if (editor) |e| (e.wrap orelse app.cfg.ui.wrap) else app.cfg.ui.wrap;
    if (wrap_on) try push(&right, arena, Seg.init(" WRAP ", p.bg_darker, p.purple).withHit(SegId.wrap.raw()));
    if (app.cfg.editor.autosave_secs > 0) {
        try push(&right, arena, Seg.init(ui.fmt(" {s} {d}s ", .{ if (nerd) sl.autosave_glyph else sl.autosave_ascii, app.cfg.editor.autosave_secs }), p.bg_darker, p.green).withHit(SegId.autosave.raw()));
    }
    if (editor) |e| {
        var buf: [16]u8 = undefined;
        try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{sl.formatByteSize(&buf, e.buf.editor.bytes().len)}), p.comment, p.bg2).withHit(SegId.filesize.raw()));
        const pos = e.buf.editor.rowCol();
        try push(&right, arena, Seg.init(ui.fmt(" Ln {d}/{d} Col {d} ", .{ pos.row + 1, e.buf.editor.lineCount(), pos.col + 1 }), p.fg, p.bg2).withHit(sl.seg_position));
        right.items[right.items.len - 1].sticky = true;
        if (e.buf.editor.selection()) |sel| if (sel[1] > sel[0]) {
            const n = std.unicode.utf8CountCodepoints(e.buf.editor.bytes()[sel[0]..sel[1]]) catch sel[1] - sel[0];
            try push(&right, arena, Seg.init(ui.fmt(" Sel {d} ", .{n}), p.bg_darker, p.yellow).withHit(SegId.sel.raw()));
        };
    }
    if (try stress.segment(app, arena, ui.ascii)) |text| {
        const level = if (app.stress.stats()) |s| stress.Meter.level(s.p95_us) else 0;
        const fg = switch (level) {
            0 => p.comment,
            1 => p.green,
            2 => p.yellow,
            3 => p.orange,
            else => p.red,
        };
        try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), fg, p.bg2).withHit(SegId.stress.raw()));
    }
    // The bell is always there; colour carries the level.
    {
        const u = app.messages.unread();
        const glyph = if (ui.ascii) sl.bell_ascii else sl.bell_glyph;
        const seg = if (u.err > 0)
            Seg.init(ui.fmt(" {s} {d} ", .{ glyph, u.err + u.warn }), p.bg_darker, p.red)
        else if (u.warn > 0)
            Seg.init(ui.fmt(" {s} {d} ", .{ glyph, u.warn }), p.bg_darker, p.yellow)
        else
            Seg.init(ui.fmt(" {s} ", .{glyph}), p.comment, p.bg2);
        try push(&right, arena, seg.withHit(SegId.bell.raw()));
    }
    if (try clock_mod.segment(app, arena)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.comment, p.bg2).withHit(SegId.clock.raw()));
    for (try app.script().segmentTexts(arena, .right)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.comment));
    // The workspace — the active repo's name when there are several.
    {
        const ws_name = std.fs.path.basename(app.workspace);
        const label = if (app.git.repos.items.len > 1) (if (app.git.activeRepo()) |r| r.name else ws_name) else ws_name;
        const text = if (nerd) ui.fmt("{s} {s} ", .{ sl.folder_glyph, label }) else ui.fmt(" {s} ", .{label});
        try push(&right, arena, Seg.init(text, p.blue, p.bg3).strong().withHit(SegId.workspace.raw()));
    }
    {
        const lang: []const u8 = if (editor) |e| (e.buf.doc.language orelse "—") else "—";
        try push(&right, arena, Seg.init(ui.fmt("  {s} ", .{lang}), p.bg_darker, p.blue).strong().withHit(sl.seg_language));
    }

    return .{ .left = left.items, .right = right.items, .middle = middle };
}

/// `render.drawStatusline`: build, then paint.
pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    sl.draw(ui, area, try build(app, ui, area));
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "file counts: a file is added, changed or removed once, by its staged side; untracked is added; conflicts stand apart" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const porcelain = "# branch.head main\n" ++
        "1 A. N... 100644 100644 100644 0000000 1111111 new.zig\n" ++
        "1 AM N... 100644 100644 100644 0000000 1111111 both.zig\n" ++
        "1 .M N... 100644 100644 100644 1111111 1111111 edited.zig\n" ++
        "1 D. N... 100644 000000 000000 1111111 0000000 gone.zig\n" ++
        "2 R. N... 100644 100644 100644 1111111 1111111 R100 moved.zig\told.zig\n" ++
        "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 clash.zig\n" ++
        "? stray.txt\n";
    const s = try parse.parseStatus(arena_state.allocator(), porcelain);
    const c = fileCounts(s);
    try testing.expectEqual(@as(u32, 3), c.added); // new, both (once), stray
    try testing.expectEqual(@as(u32, 2), c.changed); // edited, moved
    try testing.expectEqual(@as(u32, 1), c.removed);
    try testing.expectEqual(@as(u32, 1), c.conflicts);
    try testing.expectEqual(@as(usize, 20), dynamicLaneBudget(30));
    try testing.expectEqual(@as(usize, 40), dynamicLaneBudget(120));
}

test "SegId.of covers the app's ids and nothing else" {
    try testing.expectEqual(SegId.branch, SegId.of(sl.seg_app_base).?);
    try testing.expectEqual(SegId.workspace, SegId.of(SegId.workspace.raw()).?);
    try testing.expect(SegId.of(sl.seg_mode) == null);
    try testing.expect(SegId.of(SegId.workspace.raw() + 1) == null);
    try testing.expect(SegId.of(sl.seg_dyn_base) == null);
}

// ─── the row against the spec ────────────────────────────────────────────

const command = @import("../core/command.zig");
const git_app = @import("git.zig");
const client = @import("../git/client.zig");
const screen_mod = @import("../ipc/screen.zig");
const discovery = @import("discovery.zig");
const Config = @import("../config/Config.zig");
const Key = app_mod.Key;

/// The Rust editor's screen at 120×40 on the fixture (`docs/ui-spec/`).
const spec_120x40 = @embedFile("ui_spec_rust_120x40");
/// The cut now-playing cluster as the Rust row carries it: the arrow,
/// the mnml-baked Beatport mark, nf-md-play_box_outline — six cells.
const cut_cluster = sl.pl_left_nerd ++ " " ++ sl.cluster_brand_glyph ++ " " ++ sl.cluster_play_glyph ++ " ";
/// nf-dev-npm — `package.json`'s glyph (`ui/file_glyph.zig`).
const npm_glyph = "\u{e71e}";
const npm_ascii = "n";
/// The spec's clock.
const spec_clock = "23:58";

/// A workspace named `ws` under a temp dir, with a `.git` and a
/// feature-coverage trends file that reads `F 57% ▲1.0` — the fixture
/// the Rust spec was dumped on, as far as the statusline can see it.
/// The config is the fixture's: wrap on, the clock on, the feature
/// coverage number.
const Bench = struct {
    tmp: testing.TmpDir,
    root: []u8,
    ws: []u8,
    app: App,

    const trends =
        \\{"apps":[{"series":[
        \\ {"date":"2026-08-25","ui":56,"api":56,"features":1},
        \\ {"date":"2026-09-01","ui":57,"api":57,"features":1}]}]}
    ;

    fn init(cols: u16, rows: u16) !Bench {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDirPath(testing.io, "ws/.git");
        try tmp.dir.createDirPath(testing.io, ".tattle-claude-artifacts/feature-coverage/_trends");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = ".tattle-claude-artifacts/feature-coverage/_trends/trends.json", .data = trends });
        const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
        errdefer testing.allocator.free(ws);
        var cfg: Config = .{};
        cfg.ui.wrap = true;
        cfg.ui.clock = true;
        cfg.ui.coverage_chip_mode = .feature;
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cfg = cfg, .cols = cols, .rows = rows });
        errdefer app.deinit();
        // The developer's own coverage must not paint into the row.
        try app.env.put("MNML_ARTIFACTS_HOME", root);
        return .{ .tmp = tmp, .root = root, .ws = ws, .app = app };
    }

    fn deinit(b: *Bench) void {
        b.app.deinit();
        testing.allocator.free(b.ws);
        testing.allocator.free(b.root);
        b.tmp.cleanup();
    }

    /// The branch chip's data without a git binary: `main`, one
    /// untracked file — what the fixture's repo shows.
    fn onMain(b: *Bench, porcelain: []const u8) !void {
        try git_app.discover(&b.app);
        const id = b.app.git.activeRepo().?.id;
        const r = try client.Result.create(testing.allocator, id);
        r.payload = .{ .status = .{ .status = try parse.parseStatus(r.arena.allocator(), porcelain), .signs = &.{} } };
        b.app.git.status_pending = true;
        try git_app.handle(&b.app, r);
    }

    /// A frame, then row `y` of the screen on the frame arena.
    fn row(b: *Bench, y: usize) ![]const u8 {
        try b.app.render();
        const text = try screen_mod.toTestText(b.app.frame.allocator(), &b.app.screen);
        var it = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) if (i == y) return line;
        return "";
    }

    fn cell(b: *Bench, x: u16, y: u16) @import("vaxis").Style {
        return b.app.screen.readCell(x, y).?.style;
    }

    /// The first column on row `y` whose hit is statusline chip `id`.
    fn colOf(b: *Bench, y: u16, id: u32) ?u16 {
        var x: u16 = 0;
        while (x < b.app.screen.width) : (x += 1) if (b.app.hits.at(x, y)) |h| if (h == .statusline_seg and h.statusline_seg == id) return x;
        return null;
    }

    /// A frame, then a click on chip `id`.
    fn click(b: *Bench, y: u16, id: u32, button: anytype) !void {
        _ = try b.row(y);
        const x = b.colOf(y, id) orelse return error.ChipNotOnRow;
        try b.app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = button } });
    }

    fn key(b: *Bench, k: Key) !void {
        try b.app.handle(.{ .key = k });
    }
};

fn specRow(text: []const u8, y: usize) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) if (i == y) return line;
    return "";
}

/// The Rust row less the cut cluster: its six cells join the gap
/// between the lanes.
fn lessCluster(arena: Allocator, row: []const u8) ![]const u8 {
    const cut = std.mem.indexOf(u8, row, cut_cluster) orelse return error.NoClusterInSpec;
    const first = std.mem.indexOf(u8, row, sl.pl_left_nerd).?;
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ row[0..first], " " ** 6, row[first..cut], row[cut + cut_cluster.len ..] });
}

/// `actual` with its clock cells rewritten to the spec's, so the two
/// rows compare cell for cell; the clock must sit where the spec's does.
fn normaliseClock(arena: Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, expected, spec_clock) orelse return error.NoClockInSpec;
    if (actual.len < at + spec_clock.len) return error.RowTooShort;
    const got = actual[at .. at + spec_clock.len];
    for (got, 0..) |c, i| if (if (i == 2) c != ':' else !std.ascii.isDigit(c)) return error.NoClockWhereTheSpecHasOne;
    const out = try arena.dupe(u8, actual);
    @memcpy(out[at .. at + spec_clock.len], spec_clock);
    return out;
}

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " ");
}

test "row 38 at 120×40 is the Rust spec's, cell for cell, less the cut cluster and the clock" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    const expected = try lessCluster(b.app.frame.allocator(), specRow(spec_120x40, 38));
    const actual = try b.row(38);
    try testing.expectEqualStrings(trimRight(expected), trimRight(try normaliseClock(b.app.frame.allocator(), expected, actual)));
    // The colours the dump cannot carry: TREE dark on blue, the branch
    // green on bg2, the delta green on teal, the workspace bold blue.
    const p = &b.app.theme.palette;
    try testing.expect(Color.eql(b.cell(1, 38).bg, p.blue));
    try testing.expect(Color.eql(b.cell(1, 38).fg, p.bg_darker));
    try testing.expect(b.cell(1, 38).bold);
    try testing.expect(Color.eql(b.cell(9, 38).fg, p.green));
    try testing.expect(Color.eql(b.cell(9, 38).bg, p.bg2));
    const delta = std.mem.indexOf(u8, expected, "▲").?;
    const delta_col = try std.unicode.utf8CountCodepoints(expected[0..delta]);
    try testing.expect(Color.eql(b.cell(@intCast(delta_col), 38).fg, p.green));
    try testing.expect(Color.eql(b.cell(@intCast(delta_col), 38).bg, p.teal));
    try testing.expect(Color.eql(b.cell(112, 38).fg, p.blue));
    try testing.expect(b.cell(112, 38).bold);
    // Every chip on the row is a hit, and the gap is not.
    try testing.expectEqual(sl.seg_mode, b.app.hits.at(1, 38).?.statusline_seg);
    try testing.expectEqual(SegId.branch.raw(), b.app.hits.at(9, 38).?.statusline_seg);
    try testing.expect(b.app.hits.at(50, 38) == null);
    try testing.expectEqual(SegId.coverage.raw(), b.app.hits.at(@intCast(delta_col), 38).?.statusline_seg);
    try testing.expectEqual(sl.seg_language, b.app.hits.at(118, 38).?.statusline_seg);
}

test "with a file open the row gains the file chip, the size and Ln/Col, and the language, as the Rust row does" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/package.json", .data = "{}\n" });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "package.json" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    // The Rust row on the same fixture with `package.json` open
    // (`tools/ui-diff.sh`, 2026-09-06), less the cluster.
    const expected = " EDIT " ++ sl.pl_right_nerd ++ " " ++ sl.branch_glyph ++ " main  " ++ sl.added_glyph ++ " 1 " ++ sl.pl_right_nerd ++ " " ++ npm_glyph ++ " package.json" ++ " " ** 19 ++
        sl.pl_left_nerd ++ " " ++ sl.coverage_glyph ++ " F 57% ▲1.0 " ++ sl.pl_left_nerd ++ " WRAP " ++ sl.pl_left_nerd ++ " 3B  Ln 1/1 Col 1  " ++ sl.bell_glyph ++ "  " ++ spec_clock ++ " " ++ sl.pl_left_nerd ++ sl.folder_glyph ++ " ws " ++ sl.pl_left_nerd ++ "  json";
    const actual = try b.row(38);
    try testing.expectEqualStrings(expected, trimRight(try normaliseClock(b.app.frame.allocator(), expected, actual)));
    // The glyph paints in the file type's colour; a dirty buffer shows ●.
    try testing.expect(Color.eql(b.cell(22, 38).fg, Theme.rgb(0xe8274b)));
    try b.key(Key.char('x'));
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " package.json ● ") != null);
    // A markdown file opens as a preview, not an editor: VIEW and no file
    // chip — the Rust row says the same.
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/README.md", .data = "# hi\n" });
    const md = try std.fs.path.join(testing.allocator, &.{ b.ws, "README.md" });
    defer testing.allocator.free(md);
    _ = try b.app.openPath(md);
    const view = try b.row(38);
    try testing.expect(std.mem.startsWith(u8, view, " VIEW " ++ sl.pl_right_nerd));
    try testing.expect(std.mem.indexOf(u8, view, " [no file] ") != null);
    try testing.expect(std.mem.indexOf(u8, view, "Ln ") == null);
}

test "at 80 columns the row keeps every chip once the cluster is cut; a long name clips, and clips first" {
    var b = try Bench.init(80, 24);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    // Rust at 80×24 (`docs/ui-spec/rust-80x24.txt`) clips the branch to
    // `main …` to fit the cluster; without it the counts fit.
    const row = try b.row(22);
    try testing.expect(std.mem.startsWith(u8, row, " TREE " ++ sl.pl_right_nerd ++ " " ++ sl.branch_glyph ++ " main  " ++ sl.added_glyph ++ " 1 " ++ sl.pl_right_nerd ++ " [no file]"));
    try testing.expect(std.mem.endsWith(u8, trimRight(row), sl.folder_glyph ++ " ws " ++ sl.pl_left_nerd ++ "  —"));
    // A file whose name is longer than the room: the name gives way,
    // the branch keeps its counts, the right lane keeps every chip.
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/a-file-with-a-very-long-name-indeed.txt", .data = "x\n" });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "a-file-with-a-very-long-name-indeed.txt" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    const long = try b.row(22);
    try testing.expect(std.mem.indexOf(u8, long, sl.added_glyph ++ " 1 ") != null);
    try testing.expect(std.mem.indexOf(u8, long, "…") != null);
    try testing.expect(std.mem.indexOf(u8, long, "-indeed.txt") == null);
    try testing.expect(std.mem.indexOf(u8, long, " Ln 1/") != null);
    try testing.expect(std.mem.endsWith(u8, trimRight(long), sl.pl_left_nerd ++ "  txt"));
}

// ─── every chip: a hit, a description, an action ─────────────────────────

test "every chip on the row registers its hit, has words, and its click does what the words say" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/notes.txt", .data = "hello world\n" });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "notes.txt" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    _ = try b.row(38);
    // The set of chips on the row, by hit id.
    var seen = std.AutoHashMap(u32, void).init(testing.allocator);
    defer seen.deinit();
    var x: u16 = 0;
    while (x < 120) : (x += 1) if (b.app.hits.at(x, 38)) |h| if (h == .statusline_seg) try seen.put(h.statusline_seg, {});
    const expected = [_]u32{ sl.seg_mode, sl.seg_file, sl.seg_position, sl.seg_language, SegId.branch.raw(), SegId.coverage.raw(), SegId.wrap.raw(), SegId.filesize.raw(), SegId.bell.raw(), SegId.clock.raw(), SegId.workspace.raw() };
    try testing.expectEqual(expected.len, seen.count());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (expected) |id| {
        try testing.expect(seen.contains(id));
        // `discovery.describe` has words for each.
        try testing.expect((try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = id })) != null);
    }
    // The position chip: the go-to-line prompt.
    try b.click(38, sl.seg_position, .left);
    try testing.expect(b.app.overlay == .prompt);
    try b.key(Key.named(.esc));
    try testing.expect(b.app.overlay == .none);
    // The mode chip toggles the keymap, both ways.
    const style = b.app.input_style;
    try b.click(38, sl.seg_mode, .left);
    try testing.expect(b.app.input_style != style);
    try b.click(38, sl.seg_mode, .left);
    try testing.expectEqual(style, b.app.input_style);
    // Right: the keymap menu.
    try b.click(38, sl.seg_mode, .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // The language chip says what the file is.
    try b.click(38, sl.seg_language, .left);
    try testing.expectEqualStrings("language: txt (via file extension)", b.app.lastToast().?);
    // The size chip: bytes and lines.
    try b.click(38, SegId.filesize.raw(), .left);
    try testing.expect(std.mem.startsWith(u8, b.app.lastToast().?, "notes.txt: 12 bytes"));
    // The coverage chip toasts both numbers; right-click picks the mode.
    try b.click(38, SegId.coverage.raw(), .left);
    try testing.expect(std.mem.startsWith(u8, b.app.lastToast().?, "coverage: features 57%"));
    try b.click(38, SegId.coverage.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // The clock flips local ⇄ UTC; right-click is its menu.
    try b.click(38, SegId.clock.raw(), .left);
    try testing.expectEqual(clock_mod.Mode.utc, b.app.clock.mode);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "Z ") != null);
    try b.click(38, SegId.clock.raw(), .left);
    try testing.expectEqual(clock_mod.Mode.local, b.app.clock.mode);
    try b.click(38, SegId.clock.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // The bell opens the message history; right-click its menu.
    try b.click(38, SegId.bell.raw(), .left);
    try testing.expect(b.app.overlay == .picker);
    try b.key(Key.named(.esc));
    try b.click(38, SegId.bell.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // The workspace chip: the workspace picker — with one workspace
    // open and one repo, the command says so instead.
    try b.click(38, SegId.workspace.raw(), .left);
    try testing.expect(b.app.overlay == .none);
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, "one workspace open") != null);
    // The branch chip's right-click is the git menu.
    try b.click(38, SegId.branch.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // The file chip: nothing on the left button (as in Rust), the
    // Buffer menu on the right.
    const toasts_before = b.app.toasts.items.len;
    try b.click(38, sl.seg_file, .left);
    try testing.expect(b.app.overlay == .none);
    try testing.expectEqual(toasts_before, b.app.toasts.items.len);
    try b.click(38, sl.seg_file, .right);
    try testing.expect(b.app.overlay == .menu);
    try b.key(Key.named(.esc));
    // WRAP turns wrapping off for this editor — and leaves the row.
    try b.click(38, SegId.wrap.raw(), .left);
    try testing.expectEqualStrings("wrap off", b.app.lastToast().?);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " WRAP ") == null);
    try testing.expect(b.colOf(38, SegId.wrap.raw()) == null);
    // A host's segment on the left lane is a hit too, at its slot.
    try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "jira", .text = "TE-1", .side = .left, .priority = 5, .max_width = 8, .color = "yellow", .click_command = "view.toggle_wrap" });
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " TE-1 ") != null);
    try testing.expect(b.colOf(38, sl.seg_dyn_base) != null);
    try testing.expect((try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = sl.seg_dyn_base })) != null);
}

// ─── the mode chip, per profile ──────────────────────────────────────────

test "the mode chip: the standard profile's context labels, the vim profile's modes with the glyph, each on its ground" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/notes.txt", .data = "hello world\n" });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "notes.txt" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    const t = &b.app.theme;
    const p = &t.palette;
    // Standard: EDIT on green, no glyph; the hit covers the six cells.
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " EDIT " ++ sl.pl_right_nerd));
    try testing.expect(Color.eql(b.cell(1, 38).bg, t.mode_edit.bg));
    try testing.expectEqual(sl.seg_mode, b.app.hits.at(0, 38).?.statusline_seg);
    try testing.expectEqual(sl.seg_mode, b.app.hits.at(5, 38).?.statusline_seg);
    try testing.expect(b.app.hits.at(6, 38) == null or b.app.hits.at(6, 38).? != .statusline_seg);
    // Vim: the diamond-V in orange, then the label, one pill on the mode's ground.
    try command.run(&b.app, .{ .static = .@"editor.toggle_keymap" });
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " " ++ sl.vim_glyph ++ " NORMAL " ++ sl.pl_right_nerd));
    try testing.expect(Color.eql(b.cell(1, 38).fg, p.orange));
    try testing.expect(Color.eql(b.cell(1, 38).bg, t.mode_normal.bg));
    try testing.expect(Color.eql(b.cell(5, 38).bg, t.mode_normal.bg));
    try testing.expectEqual(sl.seg_mode, b.app.hits.at(1, 38).?.statusline_seg);
    try testing.expectEqual(sl.seg_mode, b.app.hits.at(8, 38).?.statusline_seg);
    try b.key(Key.char('i'));
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " " ++ sl.vim_glyph ++ " INSERT "));
    try testing.expect(Color.eql(b.cell(5, 38).bg, t.mode_insert.bg));
    try b.key(Key.named(.esc));
    try b.key(Key.char('v'));
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " " ++ sl.vim_glyph ++ " VISUAL "));
    try testing.expect(Color.eql(b.cell(5, 38).bg, t.mode_visual.bg));
    try b.key(Key.named(.esc));
    try b.key(Key.char('V'));
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " " ++ sl.vim_glyph ++ " V-LINE "));
    try b.key(Key.named(.esc));
    // REPLACE is on orange: the glyph goes near-black rather than vanish.
    try b.key(Key.char('R'));
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " " ++ sl.vim_glyph ++ " REPLACE "));
    try testing.expect(Color.eql(b.cell(1, 38).fg, p.bg_darker));
    try testing.expect(Color.eql(b.cell(1, 38).bg, t.mode_replace.bg));
    try b.key(Key.named(.esc));
    // A pending chord sits in the gap between the lanes.
    try b.key(Key.char('d'));
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "   d   ") != null);
    try b.key(Key.named(.esc));
    // Back to standard: VIEW on cyan for a read-only buffer, TREE on
    // blue when the tree has the keys.
    try command.run(&b.app, .{ .static = .@"editor.toggle_keymap" });
    b.app.activeEditor().?.buf.doc.read_only = true;
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " VIEW " ++ sl.pl_right_nerd));
    try testing.expect(Color.eql(b.cell(1, 38).bg, p.cyan));
    b.app.focus = .tree;
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " TREE " ++ sl.pl_right_nerd));
    try testing.expect(Color.eql(b.cell(1, 38).bg, p.blue));
    // `--ascii`: the label alone, no glyph, no arrow.
    b.app.focus = .{ .pane = b.app.active.? };
    try command.run(&b.app, .{ .static = .@"editor.toggle_keymap" });
    b.app.cfg.ui.ascii_icons = true;
    try testing.expect(std.mem.startsWith(u8, try b.row(38), " NORMAL  "));
}
