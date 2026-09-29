//! The statusline's chips — everything the app knows that the bottom
//! row shows, built into `ui/statusline.zig` `Seg`s each frame. The
//! component paints the two lanes; this module decides what is in them,
//! in the Rust editor's order, glyphs and colours:
//!
//!   left   mode · host segments · branch · PR · file (glyph, name, `●`)
//!          · diagnostics · enclosing symbol · macro · find
//!   right  host segments · tests · jobs · Claude · Codex · coverage ·
//!          now-playing · transfer · LSP · RESTRICTED · WRAP · autosave ·
//!          size · Ln/Col · Sel · stress · bell · clock · workspace ·
//!          language
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
//! mode chip cycles, and the far-right chip is the language. The Sonos
//! cluster is cut; the now-playing cluster is `app/now_playing.zig`'s.
//! What Zig has that Rust lacks stays: the transfer chip and a Lua
//! script's segments. The overflow rule is Rust's (`ui/statusline.zig`).

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const utf8_mod = @import("../core/utf8.zig");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const side = @import("side.zig");
const context_menus = @import("context_menus.zig");
const App = app_mod.App;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const overlay = @import("../ui/overlay.zig");
const Color = Theme.Color;
const sl = @import("../ui/statusline.zig");
const Seg = sl.Seg;
const file_glyph = @import("../ui/file_glyph.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const remote = @import("../git/remote.zig");
const parse = @import("../git/parse.zig");
const lsp = @import("lsp.zig");
const lsp_types = @import("../lsp/types.zig");
const usage_pane = @import("usage_pane.zig");
const ghost_chip = @import("ghost_chip.zig");
const jobs = @import("jobs.zig");
const claude_mark = @import("claude_mark.zig");
const coverage = @import("coverage.zig");
const now_playing = @import("now_playing.zig");
const integration_poll = @import("integration_poll.zig");
const transfers = @import("transfers.zig");
const stress = @import("stress.zig");
const clock_mod = @import("clock.zig");
const tests_pane = @import("tests_pane.zig");
const syntax_mod = @import("syntax.zig");
const outline = @import("outline.zig");
const ids = @import("../core/ids.zig");
const profile_mod = @import("../config/profile.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;

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
    /// The ghost-text chip (` ⠋ 1.8s ` under its mark) — what AI
    /// inline suggestion is doing when there is no ghost to look at
    /// (`app/ghost_chip.zig`, `sl.ghost_glyph`).
    ghost,
    coverage,
    /// The now-playing cluster: the brand mark (idle), play / pause,
    /// skip, and the title.
    np_brand,
    np_play,
    np_next,
    np_track,
    transfer,
    /// ` ⠋ 2 jobs ` while background jobs run, ` ✗ lint: exit 2 ` for
    /// ten seconds after one fails (`app/jobs.zig`, `ui.jobs_chip`).
    jobs,
    /// ` LSP 2 ` — running language servers.
    lsp,
    wrap,
    autosave,
    /// ` highlight off · 12 MB ` — this buffer's tree-sitter is off
    /// (over `editor.highlight_max_bytes`, or switched off by hand).
    /// Reads `highlight on` once the override turned it back on.
    highlight,
    filesize,
    sel,
    stress,
    bell,
    clock,
    workspace,
    /// ` zoom ` — this page is zoomed (`view.toggle_zoom`): one split
    /// fills the body and the rest of the tree is hidden, not gone.
    zoom,
    /// ` dev ` — this is the build being worked on, not the installed
    /// mnml (`MNML_PROFILE=dev`, `src/config/profile.zig`). The stable
    /// profile paints nothing: you are meant to forget it is a choice.
    dev_profile,
    /// ` sandbox ` — a `--sandbox` run: HOME, the config and the state
    /// are a throwaway directory (`src/config/sandbox.zig`). ` sandbox? `
    /// on red when `MNML_SANDBOX` is set but they are not.
    sandbox,
    _,

    pub fn of(id: u32) ?SegId {
        if (id < sl.seg_app_base or id > @intFromEnum(SegId.sandbox)) return null;
        return @enumFromInt(id);
    }

    pub fn raw(s: SegId) u32 {
        return @intFromEnum(s);
    }
};

/// Anthropic's orange, when the icon table carries no colour.
const claude_brand = @import("../ui/brand.zig").claude;
/// Near-black — readable on the coral whatever the theme.
const claude_ink = Theme.rgb(0x1a1a1a);

/// The largest buffer the symbol chip scans per frame without a server.
pub const symbol_scan_max: usize = 64 * 1024;

pub const table = .{
    .@"lsp.status" = &lspStatusCmd,
};

/// Rust's `:LspStatus`, the chip's left click: one toast naming every
/// live server and the root it runs on, relative to the workspace (`.`
/// for the workspace itself); "no servers running" without one.
fn lspStatusCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (app.lsp.servers.items) |s| {
        if (s.transport.isDead()) continue;
        if (out.items.len > 0) try out.appendSlice(arena, " · ");
        var rel: []const u8 = s.root;
        if (std.mem.startsWith(u8, s.root, app.workspace)) {
            rel = std.mem.trimStart(u8, s.root[app.workspace.len..], "/\\");
            if (rel.len == 0) rel = ".";
        }
        try out.print(arena, "{s} ({s})", .{ s.name, rel });
    }
    if (out.items.len == 0) try out.appendSlice(arena, "no servers running");
    // // changed (lsp-defaults): the missing ones, each with its install.
    for (lsp.missingServers(app), 0..) |m, i| {
        try out.appendSlice(arena, if (i == 0) " · missing: " else ", ");
        try out.print(arena, "{s} ({s})", .{ m.cmd, m.hint orelse "not on PATH" });
    }
    app.toast("LSP: {s}", .{out.items});
}

/// The LSP chip's right-click — Rust's rows: the status, then the verbs
/// a user reaches for from the chip.
pub fn openLspChipMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    // // changed (lsp-defaults): after Status, one row per missing
    // server naming it and its install hint (click copies the hint), and
    // an `Install <binary>…` row that runs the hint the way the tools
    // installer does (`runners.installBin`). The menu's arena owns the
    // labels.
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    var list: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    try list.append(arena, .{ .label = "Status", .action = .{ .command = .@"lsp.status" } });
    for (lsp.missingServers(app)) |m| {
        const hint = m.hint orelse "not on PATH";
        try list.append(arena, .{
            .label = try std.fmt.allocPrint(arena, "{s} {s} — {s}", .{ if (app.cfg.ui.ascii_icons) "x" else "✗", m.cmd, hint }),
            .action = .{ .copy_text = hint },
            .separator_before = true,
        });
        try list.append(arena, .{
            .label = try std.fmt.allocPrint(arena, "Install {s}\u{2026}", .{m.cmd}),
            .action = .{ .lsp_install = try arena.dupe(u8, m.cmd) },
        });
    }
    try list.appendSlice(arena, &.{
        .{ .label = "Symbols in file", .action = .{ .command = .@"lsp.symbols" }, .separator_before = lsp.missingServers(app).len > 0 },
        .{ .label = "Symbols in workspace", .action = .{ .command = .@"lsp.workspace_symbols" } },
        .{ .label = "Diagnostics list", .action = .{ .command = .@"lsp.diagnostics" } },
        .{ .label = "Find references", .action = .{ .command = .@"lsp.references" } },
        .{ .label = "Rename symbol", .action = .{ .command = .@"lsp.rename" } },
        .{ .label = "Format file", .action = .{ .command = .@"lsp.format" } },
        .{ .label = "Code actions", .action = .{ .command = .@"lsp.code_action" } },
        .{ .label = "Toggle inlay hints", .action = .{ .command = .@"lsp.inlay_hints_toggle" } },
    });
    const rows = try app.gpa.dupe(command.MenuItem, list.items);
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, "LSP", rows, x, y, mem);
}

/// Rust's per-side cap on host segments: a third of the row, at least 20.
pub fn dynamicLaneBudget(width: u16) usize {
    return @max(width / 3, 20);
}

/// The host segments one lane of a `width`-cell row paints, packed
/// into the lane's budget and measured by `method`, the screen's.
pub fn dynamicLane(app: *const App, arena: Allocator, width: u16, side_: ipc.effects.Side, ascii: bool, method: vaxis.gwidth.Method) Allocator.Error![]ipc.effects.Rendered {
    return ipc.effects.pack(arena, app.ipc_fx.segments.items, side_, dynamicLaneBudget(width), ascii, method);
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
            .confirm => |c| c.return_focus orelse fallback,
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
    // // changed (cmdline-fix): an open `:` line has the keys, so the
    // chip says so. Without it the row could sit there with a caret on
    // it while the chip still read TREE, and nothing on screen said the
    // typing was going to the line.
    //
    // One word for both lines. The app's own `:` (`app/cmdline.zig`)
    // and a buffer's vim `:` are two states, but they paint on the same
    // row in the same colour and neither was named before this; a user
    // cannot tell them apart and has no reason to want to.
    if (app.cmdline != null) return .{ .label = "CMD", .kind = .command, .vim = false };
    if (editor) |e| if (e.buf.input.isCmdlineOpen()) return .{ .label = "CMD", .kind = .command, .vim = true };
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
    // A terminal under vim reads as Neovim's two terminal modes.
    if (focus == .pane and app.input_style == .vim) if (app.active) |id| if (app.panes.pty(id)) |p| {
        return if (p.term_normal) .{ .label = "T-NORMAL", .kind = .normal, .vim = true } else .{ .label = "TERMINAL", .kind = .insert, .vim = true };
    };
    return switch (focus) {
        .tree => .{ .label = "TREE", .kind = .tree, .vim = false },
        // A left-column section is Rust's sidebar: its chip reads TREE.
        .panel => |p| if (side.sideOf(app, side.sectionOfPanel(p)) == .left) .{ .label = "TREE", .kind = .tree, .vim = false } else .{ .label = "PANEL", .kind = .panel, .vim = false },
        // The start surface (`app/welcome.zig`) has the keys.
        .welcome => .{ .label = "START", .kind = .panel, .vim = false },
        // The info view has the keys (`help.focus`).
        .info_view => .{ .label = "HELP", .kind = .panel, .vim = false },
        .pane, .overlay => if (editor) |e|
            (if (e.buf.doc.read_only) Mode{ .label = "VIEW", .kind = .view, .vim = false } else Mode{ .label = "EDIT", .kind = .edit, .vim = false })
        else
            .{ .label = "VIEW", .kind = .view, .vim = false },
    };
}

// ─── building ────────────────────────────────────────────────────────────

const Lane = std.ArrayListUnmanaged(Seg);

/// The highlight chip's words: whether this buffer is highlighted, and
/// the size the limit was measured against. A narrow row clips it like
/// any other chip.
pub fn highlightChipText(e: *const app_mod.EditorPane, ui: Ui) []const u8 {
    var buf: [24]u8 = undefined;
    const size = syntax_mod.Syntax.sizeLabel(&buf, e.syntax.size_bytes);
    return overlay.hintText(ui, ui.fmt(" highlight {s} · {s} ", .{ if (e.syntax.off) "off" else "on", size }));
}

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
/// the hit. A poll in flight changes nothing on the chip — the hover
/// says "refreshing"; a refresh glyph on the chip read as a button.
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
    const branch = st.headLabel() orelse return null;
    const s = st.status.?;
    const p = &ui.theme.palette;
    const nerd = !ui.ascii;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (nerd) try out.print(ui.arena, " {s} {s}", .{ providerGlyph(st.provider), branch }) else try out.print(ui.arena, " {s}", .{branch});
    // An operation waiting on the user: `main | REBASE 2/5`.
    if (s.in_progress != .none) {
        if (s.total > 0) try out.print(ui.arena, " | {s} {d}/{d}", .{ s.in_progress.label(), s.step, s.total }) else try out.print(ui.arena, " | {s}", .{s.in_progress.label()});
    }
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
    const branch = app.git.branchName() orelse return null;
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

/// A player's colours: black on Spotify green, white on Apple Music
/// red, black on Beatport lime for mixr (and anything else).
fn playerColors(source: now_playing.Source) struct { fg: Color, bg: Color } {
    return switch (source) {
        .spotify => .{ .fg = Theme.rgb(0x000000), .bg = Theme.rgb(0x1db954) },
        .music => .{ .fg = Theme.rgb(0xffffff), .bg = Theme.rgb(0xfa243c) },
        .mixr, .other => .{ .fg = Theme.rgb(0x000000), .bg = Theme.rgb(0xa6e22e) },
    };
}

/// The now-playing cluster, after the coverage chip: the transport
/// (`[pause] [next] [title]`) with a track loaded, else the idle pair
/// (`[brand] [play]`) in the preferred player's colours. Under
/// `--ascii` a one-cell breather follows, as Rust adds one where no
/// arrow separates two coloured chips.
fn pushNowPlaying(app: *App, ui: Ui, right: *Lane) Allocator.Error!void {
    const arena = ui.arena;
    const p = &ui.theme.palette;
    const st = &app.now_playing;
    const loaded: ?now_playing.Track = if (st.current) |t| (if (t.hasTrack()) t else null) else null;
    if (loaded) |t| {
        const c = playerColors(t.source);
        const glyph = if (t.playing) (if (ui.ascii) sl.np_pause_ascii else sl.np_pause_glyph) else (if (ui.ascii) sl.np_play_ascii else sl.np_play_glyph);
        try push(right, arena, Seg.init(ui.fmt(" {s} ", .{glyph}), c.fg, c.bg).withHit(SegId.np_play.raw()));
        try push(right, arena, Seg.init(ui.fmt("{s} ", .{if (ui.ascii) sl.np_next_ascii else sl.np_next_glyph}), c.fg, c.bg).withHit(SegId.np_next.raw()));
        const raw = try now_playing.rawLabel(arena, &t);
        const shown = try now_playing.shownLabel(arena, raw, app.cfg.ui.now_playing_marquee, st.marquee_offset);
        try push(right, arena, Seg.init(ui.fmt("{s} ", .{shown}), c.fg, c.bg).withHit(SegId.np_track.raw()));
    } else {
        const source = now_playing.Source.ofPreferred(app.cfg.ui.preferred_music_app);
        const c = playerColors(source);
        const brand = switch (source) {
            .spotify => if (ui.ascii) sl.spotify_ascii else sl.spotify_glyph,
            .music => if (ui.ascii) sl.apple_ascii else sl.apple_glyph,
            .mixr, .other => if (ui.ascii) sl.cluster_brand_ascii else sl.cluster_brand_glyph,
        };
        try push(right, arena, Seg.init(ui.fmt(" {s} ", .{brand}), c.fg, c.bg).withHit(SegId.np_brand.raw()));
        try push(right, arena, Seg.init(ui.fmt("{s} ", .{if (ui.ascii) sl.cluster_play_ascii else sl.cluster_play_glyph}), c.fg, c.bg).withHit(SegId.np_play.raw()));
    }
    if (ui.ascii) try push(right, arena, Seg.init(" ", p.fg, p.statusline));
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

    // ── the zoom ──
    // Beside the mode, in the mode's own colour: one split has the
    // page, and the rest of the tree is waiting to come back. The click
    // brings it back.
    if (app.zoomedPane() != null) {
        try push(&left, arena, Seg.init(" zoom ", p.bg_darker, mode_bg).strong().withHit(SegId.zoom.raw()));
    }

    // ── the profile ──
    // Which mnml this is, next to the mode, where the eye already
    // goes. Nothing at all in the stable profile.
    if (profile_mod.tag(app.profile()).len > 0) {
        try push(&left, arena, Seg.init(ui.fmt(" {s} ", .{profile_mod.tag(app.profile())}), p.bg_darker, p.orange).strong().withHit(SegId.dev_profile.raw()));
    }

    // ── the sandbox ──
    // Beside the profile: this is not your real setup. Red, with a `?`,
    // when the variable says sandbox and the home or data root says
    // otherwise — the chip never promises a safety it cannot see.
    switch (app.sandboxState()) {
        .off => {},
        .on => try push(&left, arena, Seg.init(" sandbox ", p.bg_darker, p.yellow).strong().withHit(SegId.sandbox.raw())),
        .unsafe => try push(&left, arena, Seg.init(" sandbox? ", p.bg_darker, p.red).strong().withHit(SegId.sandbox.raw())),
    }

    // ── host segments, left lane ──
    // A segment with no text yet (a count the poller has not filled in) paints nothing — an empty chevron is noise.
    for (try dynamicLane(app, arena, area.w, .left, ui.ascii, ui.canvas.widthMethod())) |r| if (r.text.len > 0) try push(&left, arena, dynSeg(ui, r));

    // ── branch, PR ──
    if (try branchSeg(app, ui)) |s| try push(&left, arena, s);
    if (currentPr(app)) |pr| {
        try push(&left, arena, Seg.init(ui.fmt("  {s}{d} ", .{ hostTag(app.git.provider), pr.number }), p.purple, p.bg2).withHit(SegId.pr.raw()));
    }

    // ── file: glyph in its colour, name, dirty dot; then what the file says ──
    const editor = app.activeEditor();
    if (editor) |e| {
        const path = e.buf.doc.path;
        const name = if (path) |pth| std.fs.path.basename(pth) else e.label orelse "[scratch]";
        const icon = file_glyph.forName(name);
        try push(&left, arena, Seg.init(ui.fmt(" {s} ", .{if (nerd) icon.glyph else icon.fallback}), icon.color, p.statusline).withHit(sl.seg_file));
        try push(&left, arena, Seg.init(ui.fmt("{s}{s}{s} ", .{ name, if (e.buf.doc.dirty) " ●" else "", if (e.buf.doc.deleted) " (deleted)" else "" }), p.fg, p.statusline).withHit(sl.seg_file));
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
            // The enclosing symbol — the server's when it has sent
            // them (`enclosingSymbol`), else the last one the outline's
            // line scan places at or above the cursor's line, kept to
            // files small enough to read every frame (the Rust chip
            // regex-scanned a 13k-line file per frame and paid 45 ms
            // for it).
            const row: u32 = @intCast(e.buf.editor.rowCol().row);
            var pick: ?[]const u8 = null;
            if (lsp.symbolsFor(app, pth)) |syms| {
                pick = enclosingSymbol(syms, row);
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
    for (try dynamicLane(app, arena, area.w, .right, ui.ascii, ui.canvas.widthMethod())) |r| if (r.text.len > 0) try push(&right, arena, dynSeg(ui, r));
    for (try app.luaStates(arena)) |lua| for (try lua.segmentTexts(arena, .left)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.comment));
    if (tests_pane.find(app)) |id| if (app.panes.get(id)) |pane| switch (pane.*) {
        .tests => |*tp| try push(&right, arena, Seg.init(ui.fmt(" {s} {s} ", .{ if (ui.ascii) "T" else "\u{1f9ea}", tp.title() }), p.bg_darker, p.yellow).withHit(SegId.test_run.raw())),
        else => {},
    };
    // Background jobs: a spinner and a count while any runs, the last
    // failure's words dimmed for ten seconds after, nothing idle — the
    // states a worker used to finish in without a word (`app/jobs.zig`).
    if (try jobs.chipFor(app, arena, ui.ascii)) |c| {
        const fg = switch (c.tone) {
            .busy => p.cyan,
            .failed, .idle => p.comment,
        };
        var seg = Seg.init(c.text, fg, p.bg2).withHit(SegId.jobs.raw());
        seg.short = c.short;
        try push(&right, arena, seg);
    }
    // The AI meters, each while its integration is on: the quota the
    // usage reader holds (`app/usage_pane.zig`, the same snapshots the
    // usage pane shows) — Claude's session / weekly percent, near-black
    // on the brand coral whatever the tier; Codex's tokens today.
    if (enabledIcon(app, "claude_code")) |ic| {
        // The mark `ui.claude_mark` names, not a codepoint of this
        // file's own (`app/claude_mark.zig`).
        const glyph = claude_mark.glyph(app, ui.ascii);
        const parts = try usage_pane.claudeChipParts(app, arena, glyph);
        var seg = Seg.init(parts.head, claude_ink, iconColor(ui, ic, claude_brand)).withHit(SegId.ai_claude.raw());
        if (parts.accent.len > 0 or parts.tail.len > 0) {
            seg.accent = .{ .text = parts.accent, .fg = claude_ink, .underline = parts.underline };
            // The worst account in warning / critical: its colour on ink.
            if (parts.tier) |tier| {
                seg.accent.?.fg = if (tier == .hot) ui.theme.palette.red else ui.theme.palette.yellow;
                seg.accent.?.bg = claude_ink;
            }
            seg.tail = parts.tail;
        }
        try push(&right, arena, seg);
    }
    if (enabledIcon(app, "codex")) |_| {
        const glyph = if (ui.ascii) sl.codex_ascii else sl.codex_glyph;
        const chip = try usage_pane.codexChip(app, arena, glyph);
        const seg = Seg.init(chip.text, if (chip.has_data) p.bg_darker else p.comment, p.cyan);
        try push(&right, arena, seg.withHit(SegId.ai_codex.raw()));
    }
    // Ghost text, beside the two AI meters: nothing while it is idle
    // or while a suggestion is on screen, and a chip for every moment
    // in between — the ones that used to look identical to "off".
    if (try ghost_chip.chipText(arena, ghost_chip.phase(app), ghost_chip.elapsedMs(app), app.now_ms, ui.ascii)) |text| {
        try push(&right, arena, Seg.init(text, p.comment, p.bg2).withHit(SegId.ghost.raw()));
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
    try pushNowPlaying(app, ui, &right);
    if (try transfers.chip(app, arena, ui.ascii)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.cyan).withHit(SegId.transfer.raw()));
    var servers: u32 = 0;
    for (app.lsp.servers.items) |s| if (!s.transport.isDead()) {
        servers += 1;
    };
    // // changed (lsp-defaults): a server met this session that is not
    // installed marks the chip with a `?` — a muted run after the live
    // count (` LSP 1? `), or the whole chip muted when nothing runs
    // (` LSP? `). The count and the names are the click (`lsp.status`)
    // and the menu: the width rule (`lane_gap`, four cells between the
    // lanes) leaves ` LSP ?2 ` no room on the 120-column spec row once
    // the file is dirty, and ` · 2 missing ` none at all.
    const missing = lsp.missingServers(app).len > 0;
    if (servers > 0) {
        var seg = Seg.init(ui.fmt(" LSP {d}", .{servers}), p.bg_darker, p.blue).withHit(SegId.lsp.raw());
        if (missing) seg.accent = .{ .text = "?", .fg = p.bg2 };
        seg.tail = " ";
        try push(&right, arena, seg);
    } else if (missing) {
        try push(&right, arena, Seg.init(" LSP? ", p.comment, p.bg2).withHit(SegId.lsp.raw()));
    }
    // The buffer is over `editor.lsp_max_bytes`, so it was given no
    // server at all. The ceiling is never silent: the toast fired once
    // when the file opened, and this says so for as long as it is up.
    if (editor) |e| if (lsp.limitFor(app, e)) |lim| {
        var size_buf: [24]u8 = undefined;
        const txt = ui.fmt(" LSP off · {s} ", .{syntax_mod.Syntax.sizeLabel(&size_buf, lim.size_bytes)});
        try push(&right, arena, Seg.init(txt, p.comment, p.bg2).withHit(SegId.lsp.raw()));
    };
    // RESTRICTED: the workspace's exec-bearing settings are stripped
    // until trusted — or its whole `.mnml/config.toml` is 0.2's and not
    // read at all (`App.workspace_toml`); the click says which.
    const stripped = app.loaded != null and !app.workspace_trusted and app.loaded.?.trust_prompt != null;
    if (stripped or app.workspace_toml != null) {
        try push(&right, arena, Seg.init(if (nerd) " " ++ sl.restricted_glyph ++ " RESTRICTED " else " RESTRICTED ", p.bg_darker, p.yellow).withHit(sl.seg_restricted));
    }
    // WRAP: the active editor's own setting when it has one (a click
    // flips that), else the config's.
    const wrap_on = if (editor) |e| (e.wrap orelse app.cfg.ui.wrap) else app.cfg.ui.wrap;
    if (wrap_on) try push(&right, arena, Seg.init(" WRAP ", p.bg_darker, p.purple).withHit(SegId.wrap.raw()));
    if (app.cfg.editor.autosave_secs > 0) {
        try push(&right, arena, Seg.init(ui.fmt(" {s} {d}s ", .{ if (nerd) sl.autosave_glyph else sl.autosave_ascii, app.cfg.editor.autosave_secs }), p.bg_darker, p.green).withHit(SegId.autosave.raw()));
    }
    // The size ceiling is opt-in and never silent: while a buffer it
    // skipped (or one switched off by hand) is up, the row says so, and
    // the chip is the click that turns it on.
    if (editor) |e| if (e.syntax.showsChip()) {
        try push(&right, arena, Seg.init(highlightChipText(e, ui), p.comment, p.bg2).withHit(SegId.highlight.raw()));
    };
    if (editor) |e| {
        var buf: [16]u8 = undefined;
        try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{sl.formatByteSize(&buf, e.buf.editor.bytes().len)}), p.comment, p.bg2).withHit(SegId.filesize.raw()));
        const pos = e.buf.editor.rowCol();
        try push(&right, arena, Seg.init(ui.fmt(" Ln {d}/{d} Col {d} ", .{ pos.row + 1, e.buf.editor.lineCount(), pos.col + 1 }), p.fg, p.bg2).withHit(sl.seg_position));
        if (e.buf.selectedSpan()) |sel| if (sel[1] > sel[0]) {
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
    for (try app.luaStates(arena)) |lua| for (try lua.segmentTexts(arena, .right)) |text| try push(&right, arena, Seg.init(ui.fmt(" {s} ", .{text}), p.bg_darker, p.comment));
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

/// The symbol the ` › name ` chip names for a caret on `row`: the
/// INNERMOST container whose range holds the row — the function around
/// a `local`, not the local; nothing at all past the last closing
/// brace. It used to be the last symbol that STARTED before the caret,
/// whatever its kind and wherever it ended, which inside any function
/// that declares a variable named the variable. A server that gives
/// every symbol one line (no ranges to hold anything) gets the old
/// rule, kept to containers.
pub fn enclosingSymbol(syms: []const lsp_types.Symbol, row: u32) ?[]const u8 {
    var best: ?lsp_types.Symbol = null;
    var spans = false;
    for (syms) |sym| {
        if (!sym.isContainer()) continue;
        if (sym.end_line > sym.line) spans = true;
        if (!sym.holds(row)) continue;
        if (best) |b| {
            const inner = sym.line > b.line or (sym.line == b.line and sym.end_line < b.end_line);
            if (!inner) continue;
        }
        best = sym;
    }
    if (best) |b| return b.name;
    if (spans) return null;
    var last: ?[]const u8 = null;
    for (syms) |sym| if (sym.isContainer() and sym.line <= row) {
        last = sym.name;
    };
    return last;
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

test "the mode chip names the open line — CMD for the app's and for a buffer's" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    // The app's own line, from tree focus: the chip was TREE and the
    // line had no name on the row at all.
    app.focus = .tree;
    app.tree.visible = true;
    try testing.expectEqualStrings("TREE", modeOf(&app).label);
    cmdline_mod.open(&app);
    const m = modeOf(&app);
    try testing.expectEqualStrings("CMD", m.label);
    try testing.expectEqual(sl.ModeKind.command, m.kind);
    cmdline_mod.close(&app);
    try testing.expectEqualStrings("TREE", modeOf(&app).label);

    // The same word for a buffer's vim `:` — one line, one word, and
    // the vim glyph still leads it as every vim mode's chip does.
    app.focus = .{ .pane = app.active.? };
    try app.setInputStyle(.vim);
    try testing.expectEqualStrings("NORMAL", modeOf(&app).label);
    try dispatch.key(&app, Key.char(':'));
    const v = modeOf(&app);
    try testing.expectEqualStrings("CMD", v.label);
    try testing.expect(v.vim);
    try dispatch.key(&app, Key.named(.esc));
    try testing.expectEqualStrings("NORMAL", modeOf(&app).label);
}

test "SegId.of covers the app's ids and nothing else" {
    try testing.expectEqual(SegId.branch, SegId.of(sl.seg_app_base).?);
    try testing.expectEqual(SegId.workspace, SegId.of(SegId.workspace.raw()).?);
    try testing.expectEqual(SegId.dev_profile, SegId.of(SegId.dev_profile.raw()).?);
    try testing.expectEqual(SegId.sandbox, SegId.of(SegId.sandbox.raw()).?);
    try testing.expect(SegId.of(sl.seg_mode) == null);
    // `sandbox` is the last one; one past it is nobody's.
    try testing.expect(SegId.of(SegId.sandbox.raw() + 1) == null);
    try testing.expect(SegId.of(sl.seg_dyn_base) == null);
}

test "a --sandbox run paints ` sandbox ` beside the mode, a `?` on red when the home or data root is not throwaway; the click names them; the session is not autosaved" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    // No MNML_SANDBOX: no chip, and the session autosaves as ever.
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "sandbox") == null);
    @import("session.zig").onStartup(&b.app, .{ .startup = {} });
    try testing.expect(b.app.session.autosave);

    // The sandbox the re-exec builds: HOME under the temp root, the data
    // root (the Bench's `root`) inside HOME.
    const home = std.fs.path.dirname(b.root).?;
    try b.app.env.put("TMPDIR", std.fs.path.dirname(home).?);
    try b.app.env.put("HOME", home);
    try b.app.env.put("MNML_SANDBOX", home);
    try testing.expectEqual(@import("../config/sandbox.zig").State.on, b.app.sandboxState());
    const row = try b.row(38);
    const at = std.mem.indexOf(u8, row, " sandbox ") orelse return error.NoChip;
    // Beside the mode chip, left of the branch.
    try testing.expect(at < 20);
    try testing.expect(std.mem.indexOf(u8, row, "sandbox?") == null);
    try testing.expect(b.colOf(38, SegId.sandbox.raw()) != null);
    try testing.expect((try discovery.describe(&b.app, b.app.frame.allocator(), .{ .statusline_seg = SegId.sandbox.raw() })) != null);
    try b.click(38, SegId.sandbox.raw(), .left);
    try testing.expect(std.mem.startsWith(u8, b.app.lastToast().?, "sandbox — HOME "));
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, b.root) != null);
    // A sandbox neither restores nor autosaves the workspace's session.
    @import("session.zig").onStartup(&b.app, .{ .startup = {} });
    try testing.expect(!b.app.session.autosave);

    // The variable without the isolation: the chip warns instead.
    try b.app.env.put("HOME", "/Users/dev");
    try testing.expectEqual(@import("../config/sandbox.zig").State.unsafe, b.app.sandboxState());
    const warn = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, warn, " sandbox? ") != null);
    try b.click(38, SegId.sandbox.raw(), .left);
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, "NOT isolated") != null);
}

// ─── the row against the spec ────────────────────────────────────────────

const git_app = @import("git.zig");
const client = @import("../git/client.zig");
const screen_mod = @import("../ipc/screen.zig");
const discovery = @import("discovery.zig");
const dispatch = @import("dispatch.zig");
const cmdline_mod = @import("cmdline.zig");
const Config = @import("../config/Config.zig");
const Key = app_mod.Key;

/// The Rust editor's screen at 120×40 on the fixture (`docs/ui-spec/`).
const spec_120x40 = @embedFile("ui_spec_rust_120x40");
/// The idle now-playing cluster as the Rust row carries it: the arrow,
/// the mnml-baked Beatport mark, nf-md-play_box_outline — six cells.
const idle_cluster = sl.pl_left_nerd ++ " " ++ sl.cluster_brand_glyph ++ " " ++ sl.cluster_play_glyph ++ " ";
/// The Rust editor's screen at 80×24 on the fixture.
const spec_80x24 = @embedFile("ui_spec_rust_80x24");
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
        try tmp.dir.createDirPath(testing.io, "feature-coverage/_trends");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "feature-coverage/_trends/trends.json", .data = trends });
        const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
        errdefer testing.allocator.free(ws);
        var cfg: Config = .{};
        cfg.ui.wrap = true;
        cfg.ui.clock = true;
        cfg.ui.coverage_chip_mode = .feature;
        // The Rust rows these compare against dock the tree at any width
        // and keep the keys in it (their mode chip reads TREE); the
        // width rule would hide it at 80 columns and hand the keys on.
        cfg.ui.sidebar_auto_below = 0;
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

    /// Put the pointer on chip `id` as a real motion report (which is
    /// what wakes the hover surfaces), then paint. Returns the chip's
    /// first column.
    fn rowHover(b: *Bench, y: u16, id: u32) !?u16 {
        _ = try b.row(y);
        const x = b.colOf(y, id) orelse return null;
        try b.app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .motion, .button = .left } });
        _ = try b.row(y);
        return x;
    }

    /// The first cell whose hit is row `idx` of a tip's list.
    fn tipRowAt(b: *Bench, idx: u16) ?struct { x: u16, y: u16, hit: @import("../ui/hit.zig").HitTarget } {
        var y: u16 = 0;
        while (y < b.app.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < b.app.screen.width) : (x += 1) if (b.app.hits.at(x, y)) |h| if (h == .tip_row and h.tip_row.idx == idx) {
                return .{ .x = x, .y = y, .hit = h };
            };
        }
        return null;
    }
};

fn specRow(text: []const u8, y: usize) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) if (i == y) return line;
    return "";
}

/// The 80×24 spec's statusline with the fixture's coverage reading and
/// the spec's clock: the Rust machine read `C 74% ±0.0` at 09:36 when
/// that dump was taken.
fn spec80Row(arena: Allocator) ![]const u8 {
    const row = specRow(spec_80x24, 22);
    const cov = try std.mem.replaceOwned(u8, arena, row, "C 74% ±0.0", "F 57% ▲1.0");
    return std.mem.replaceOwned(u8, arena, cov, "09:36", spec_clock);
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

test "row 38 at 120×40 is the Rust spec's, cell for cell, but the clock" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    const expected = specRow(spec_120x40, 38);
    const actual = try b.row(38);
    try testing.expectEqualStrings(trimRight(expected), trimRight(try normaliseClock(b.app.frame.allocator(), expected, actual)));
    try testing.expect(std.mem.indexOf(u8, actual, idle_cluster) != null);
    // The colours the dump cannot carry: TREE dark on blue, the branch
    // green on bg2, the delta green on teal, the idle cluster black on
    // Beatport lime, the workspace bold blue.
    const p = &b.app.theme.palette;
    const brand = std.mem.indexOf(u8, expected, sl.cluster_brand_glyph).?;
    const brand_col: u16 = @intCast(try std.unicode.utf8CountCodepoints(expected[0..brand]));
    try testing.expect(Color.eql(b.cell(brand_col, 38).bg, Theme.rgb(0xa6e22e)));
    try testing.expect(Color.eql(b.cell(brand_col, 38).fg, Theme.rgb(0)));
    try testing.expectEqual(SegId.np_brand.raw(), b.app.hits.at(brand_col, 38).?.statusline_seg);
    try testing.expectEqual(SegId.np_play.raw(), b.app.hits.at(brand_col + 2, 38).?.statusline_seg);
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
    // // changed (lsp-defaults): `package.json` now has a default server
    // (`json`); with nothing on PATH the miss is quiet — the bell stays
    // idle (a toast here was what kept the row out of the table), and
    // the chip says ` LSP? ` in the muted colours where Rust, with no
    // json row, has no chip: seven cells out of the file chip's padding,
    // which leaves the dirty ` ● ` its `lane_gap` below.
    try b.app.env.put("PATH", "");
    _ = try b.app.openPath(path);
    // The Rust row on the same fixture with `package.json` open
    // (`tools/ui-diff.sh`, 2026-09-06), plus the missing-server chip.
    const expected = " EDIT " ++ sl.pl_right_nerd ++ " " ++ sl.branch_glyph ++ " main  " ++ sl.added_glyph ++ " 1 " ++ sl.pl_right_nerd ++ " " ++ npm_glyph ++ " package.json" ++ " " ** 6 ++
        sl.pl_left_nerd ++ " " ++ sl.coverage_glyph ++ " F 57% ▲1.0 " ++ idle_cluster ++ sl.pl_left_nerd ++ " LSP? " ++ sl.pl_left_nerd ++ " WRAP " ++ sl.pl_left_nerd ++ " 3B  Ln 1/1 Col 1  " ++ sl.bell_glyph ++ "  " ++ spec_clock ++ " " ++ sl.pl_left_nerd ++ sl.folder_glyph ++ " ws " ++ sl.pl_left_nerd ++ "  json";
    const actual = try b.row(38);
    try testing.expectEqualStrings(expected, trimRight(try normaliseClock(b.app.frame.allocator(), expected, actual)));
    try testing.expectEqual(@as(u32, 0), b.app.messages.unread().warn);
    try testing.expect(b.app.lastToast() == null or std.mem.indexOf(u8, b.app.lastToast().?, "not installed") == null);
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

test "at 80 columns the row is the Rust 80×24 spec's: the branch clips to `main …`; a long name clips instead, and first" {
    var b = try Bench.init(80, 24);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    // Rust at 80×24 (`docs/ui-spec/rust-80x24.txt`) clips the branch to
    // `main …` to fit the cluster: the row is that dump, cell for cell.
    const row = try b.row(22);
    const expected = try spec80Row(b.app.frame.allocator());
    try testing.expectEqualStrings(trimRight(expected), trimRight(try normaliseClock(b.app.frame.allocator(), expected, row)));
    try testing.expect(std.mem.startsWith(u8, row, " TREE " ++ sl.pl_right_nerd ++ " " ++ sl.branch_glyph ++ " main …" ++ sl.pl_right_nerd ++ " [no file]"));
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
    // The right lane is wider than what three cells of name leave: it
    // runs on from the name and the edge cuts it — the clock is the last
    // chip to show, the workspace and the language are past the edge,
    // as Rust's one line of spans would be cut.
    try testing.expect(b.colOf(22, sl.seg_language) == null);
    try testing.expect(b.colOf(22, SegId.workspace.raw()) == null);
    try testing.expect(b.colOf(22, SegId.bell.raw()) != null);
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
    const expected = [_]u32{ sl.seg_mode, sl.seg_file, sl.seg_position, sl.seg_language, SegId.branch.raw(), SegId.coverage.raw(), SegId.np_brand.raw(), SegId.np_play.raw(), SegId.wrap.raw(), SegId.filesize.raw(), SegId.bell.raw(), SegId.clock.raw(), SegId.workspace.raw() };
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
    // The idle cluster: the brand opens the preferred player (`mixr.show`,
    // cut in this build — its toast says so), the play chip starts one
    // (`mixr.play_now`, the same); the right button is the player menu.
    try b.click(38, SegId.np_brand.raw(), .left);
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, "cut") != null);
    try b.click(38, SegId.np_play.raw(), .left);
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, "cut") != null);
    try b.click(38, SegId.np_play.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try testing.expectEqualStrings("mixr", b.app.overlay.menu.title);
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

    // The publisher's own words are the hover: a count is worth little
    // without what it counts.
    // A manifest's segment is keyed `<integration>.<segment>`, which is
    // how the poller knows whose chip it is.
    _ = b.app.ipc_fx.clearSegment(testing.allocator, "jira");
    try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "jira_work.assigned", .text = "TE-1", .side = .left, .priority = 5, .max_width = 8, .tooltip = "Jira · 7 open items — 4 In Progress" });
    const hover = (try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = sl.seg_dyn_base })).?;
    try testing.expectEqualStrings("Jira · 7 open items — 4 In Progress", hover.title);

    // A poll in flight puts `⟳` on that integration's chip, so a chip
    // that has gone quiet is visibly being asked rather than stale.
    const job = try testing.allocator.create(integration_poll.Job);
    job.* = .{
        .integration_id = try testing.allocator.dupe(u8, "jira_work"),
        .source_id = try testing.allocator.dupe(u8, "v"),
        .argv = &.{},
        .cwd = try testing.allocator.dupe(u8, "."),
        .env = std.process.Environ.Map.init(testing.allocator),
        .interval_secs = 300,
        .stagger_secs = 0,
    };
    try b.app.integration_poll.jobs.append(b.app.gpa, job);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), integration_poll.busy_glyph) == null);
    job.shared.in_flight.store(true, .release);
    b.app.needs_render = true;
    // A poll in flight leaves the chip as it was: no glyph, the count still there…
    try testing.expect(std.mem.indexOf(u8, try b.row(38), integration_poll.busy_glyph) == null);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " TE-1 ") != null);
    // …and the hover says so, and offers the way to ask again by hand.
    const busy_hover = (try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = sl.seg_dyn_base })).?;
    try testing.expect(std.mem.indexOf(u8, busy_hover.detail orelse "", "refreshing") != null);
    try testing.expect(std.mem.indexOf(u8, busy_hover.detail orelse "", "Refresh now") != null);
    // A segment with no text yet paints nothing at all: the row is the same with it as without.
    const row_before = try arena_state.allocator().dupe(u8, try b.row(38));
    try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "jira_work.qa", .text = "", .side = .left, .priority = 4, .max_width = 8, .color = "magenta" });
    b.app.needs_render = true;
    try testing.expectEqualStrings(row_before, try b.row(38));
}

// ─── wide glyphs in a host chip ──────────────────────────────────────────

test "a host chip with a wide glyph: the cells the pack plans are the cells painted and the cells the hit covers, at 80 and 120" {
    // The pack used to count codepoints: `漢字 2` is 4 codepoints and 6
    // cells, so a chip it charged 6 painted 8, the lane ran past its
    // budget, and a click aimed where the plan put the next chip landed
    // on this one.
    for ([_]u16{ 80, 120 }) |w| {
        var b = try Bench.init(w, 24);
        defer b.deinit();
        try b.onMain("# branch.head main\n");
        // Room on the row: the clock and WRAP off, so at 80 the lanes
        // fit whole and the right one is anchored to the edge rather
        // than cut by it.
        b.app.cfg.ui.clock = false;
        b.app.cfg.ui.wrap = false;
        const y: u16 = 22;
        try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "bitbucket_prs.reviews_pending", .text = "\u{6f22}\u{5b57} 2", .side = .right, .priority = 60, .color = "magenta" });
        // At 80 the row has room for one host chip a side before the
        // narrow rule cuts the right lane at the edge; at 120, for more.
        if (w >= 120) try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "t.bell", .text = "\u{1f514} 3", .side = .right, .priority = 50, .color = "yellow" });
        // Cut by its max_width: the cut is cells too, and never tears a glyph.
        if (w >= 120) try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "t.cut", .text = "\u{6f22}\u{5b57}\u{6f22}\u{5b57}\u{6f22}\u{5b57}", .side = .right, .priority = 40, .max_width = 7, .color = "cyan" });
        try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "jira_work.assigned", .text = "\u{5b57} 1", .side = .left, .priority = 60, .color = "blue" });
        _ = try b.row(y);
        const arena = b.app.frame.allocator();
        const method = b.app.screen.width_method;
        for ([_]ipc.effects.Side{ .left, .right }) |lane| {
            var planned: usize = 0;
            var chips: usize = 0;
            for (try dynamicLane(&b.app, arena, w, lane, false, method)) |r| {
                if (r.text.len == 0) continue;
                chips += 1;
                planned += r.cells;
                const id = sl.seg_dyn_base + r.index;
                // The hit: one contiguous run of cells.
                const x0 = b.colOf(y, id) orelse return error.ChipNotOnRow;
                var hit_w: u16 = 0;
                while (x0 + hit_w < w) : (hit_w += 1) {
                    const h = b.app.hits.at(x0 + hit_w, y) orelse break;
                    if (!(h == .statusline_seg and h.statusline_seg == id)) break;
                }
                // The paint: what the screen holds under the hit, glyph by glyph.
                var painted: std.ArrayList(u8) = .empty;
                var x = x0;
                while (x < x0 + hit_w) {
                    const c = b.app.screen.readCell(x, y).?;
                    try painted.appendSlice(arena, c.char.grapheme);
                    x += @max(c.char.width, 1);
                }
                const want = try std.fmt.allocPrint(arena, " {s} ", .{r.text});
                try testing.expectEqualStrings(want, painted.items);
                try testing.expectEqual(x0 + hit_w, x);
                try testing.expectEqual(utf8_mod.width(want, method), hit_w);
                try testing.expectEqual(r.cells, hit_w);
            }
            try testing.expect(chips > 0);
            try testing.expect(planned <= dynamicLaneBudget(w));
        }
        // The right-aligned block still ends on the row's last cell: the
        // language chip, last on the lane, is there and ends at the edge.
        const lang = b.colOf(y, sl.seg_language) orelse return error.LanguageChipCut;
        var end = lang;
        while (end < w and b.app.hits.at(end, y) != null and b.app.hits.at(end, y).? == .statusline_seg and b.app.hits.at(end, y).?.statusline_seg == sl.seg_language) end += 1;
        try testing.expectEqual(w, end);
    }
}

/// Row `y`'s statusline hits, one per cell (0 for none), for comparing
/// two rows' layouts cell for cell.
fn hitRow(b: *Bench, arena: Allocator, y: u16) ![]u32 {
    const out = try arena.alloc(u32, b.app.screen.width);
    for (out, 0..) |*o, x| o.* = if (b.app.hits.at(@intCast(x), y)) |h| (if (h == .statusline_seg) h.statusline_seg + 1 else 0) else 0;
    return out;
}

test "hunt3: three host chips with `界界` lay out exactly as the same chips with `abcd`, the same four cells, at 80x24" {
    // hunt3-statusline-wide-segments-push-chips-offscreen: the pack
    // counted each `界` as one cell, admitted a third chip the row had
    // no room for, and the workspace chip was cut to `ws-`.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var layouts: [2][]u32 = undefined;
    var rows: [2][]const u8 = undefined;
    for ([_][]const u8{ "abcd", "\u{754c}\u{754c}" }, 0..) |mid, k| {
        var b = try Bench.init(80, 24);
        defer b.deinit();
        for ([_]struct { []const u8, []const u8, u8 }{ .{ "seg1", "S1", 10 }, .{ "seg2", "S2", 20 }, .{ "seg3", "S3", 30 } }, 0..) |seg, n| {
            const text = try std.fmt.allocPrint(arena, "{s} {s} {d}{d}", .{ seg[1], mid, n + 1, n + 1 });
            try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = seg[0], .text = text, .side = .right, .priority = seg[2] });
        }
        rows[k] = try arena.dupe(u8, try b.row(22));
        layouts[k] = try hitRow(&b, arena, 22);
        // S1 does not fit beside S2 and S3 in either run.
        try testing.expect(b.colOf(22, sl.seg_dyn_base + 0) == null);
    }
    try testing.expectEqualSlices(u32, layouts[0], layouts[1]);
    // The wide run's text is the control's with each `abcd` now `界界`.
    try testing.expect(std.mem.indexOf(u8, rows[1], "S3 \u{754c}") != null);
}

test "hunt3: a host chip cut to one cell paints the ellipsis whole, never half of its bytes" {
    // hunt3-statusline-one-cell-segment-paints-replacement-char.
    for ([_]bool{ false, true }) |ascii| {
        var b = try Bench.init(120, 40);
        defer b.deinit();
        b.app.cfg.ui.ascii_icons = ascii;
        try b.app.ipc_fx.setSegment(testing.allocator, .{ .id = "tiny", .side = .right, .text = "abcdef", .priority = 90, .max_width = 1 });
        const row = try b.row(38);
        try testing.expect(std.unicode.utf8ValidateSlice(row));
        try testing.expect(std.mem.indexOf(u8, row, "\u{fffd}") == null);
        const x = b.colOf(38, sl.seg_dyn_base) orelse return error.ChipNotOnRow;
        const want: []const u8 = if (ascii) "." else "\u{2026}";
        try testing.expectEqualStrings(want, b.app.screen.readCell(x + 1, 38).?.char.grapheme);
    }
}

// ─── the narrow rule, at four widths ─────────────────────────────────────

test "the narrow rule at 120 / 100 / 80 / 60 columns: the gap shrinks, then the branch clips to `main …`, then to `…` and the edge cuts the right lane" {
    const spec = specRow(spec_120x40, 38);
    // The gap is the first run of four spaces: a chip holds at most two.
    const gap = std.mem.indexOf(u8, spec, "    ").?;
    var after_gap = gap;
    while (after_gap < spec.len and spec[after_gap] == ' ') after_gap += 1;
    const spec_left = spec[0..gap];
    const spec_right = trimRight(spec[after_gap..]);
    const porcelain = "# branch.head main\n? stray.txt\n";
    // 120 is the spec (the row test above). 100: the same chips, twenty
    // cells of gap fewer — the Rust row at 100×40 (`tools/ui-diff.sh`,
    // 2026-09-07) on the fixture reads exactly so.
    {
        var b = try Bench.init(100, 40);
        defer b.deinit();
        try b.onMain(porcelain);
        b.app.focus = .tree;
        const row = try b.row(38);
        const lw = try std.unicode.utf8CountCodepoints(spec_left);
        // The dump is right-trimmed: the language chip's last cell is a
        // space it does not carry.
        const rw = 1 + try std.unicode.utf8CountCodepoints(spec_right);
        const spaces = " " ** 100;
        const expected_row = try std.fmt.allocPrint(b.app.frame.allocator(), "{s}{s}{s}", .{ spec_left, spaces[0 .. 100 - lw - rw], spec_right });
        try testing.expectEqualStrings(expected_row, trimRight(try normaliseClock(b.app.frame.allocator(), expected_row, row)));
        try testing.expect(std.mem.indexOf(u8, row, " main  " ++ sl.added_glyph ++ " 1 ") != null);
        try testing.expectEqual(sl.seg_language, b.app.hits.at(98, 38).?.statusline_seg);
    }
    // 80: the Rust 80×24 dump — the branch gives up its counts, `main …`.
    {
        var b = try Bench.init(80, 24);
        defer b.deinit();
        try b.onMain(porcelain);
        b.app.focus = .tree;
        const row = try b.row(22);
        const expected = try spec80Row(b.app.frame.allocator());
        try testing.expectEqualStrings(trimRight(expected), trimRight(try normaliseClock(b.app.frame.allocator(), expected, row)));
        const dots = std.mem.indexOf(u8, row, "…").?;
        try testing.expectEqual(@as(usize, 15), try std.unicode.utf8CountCodepoints(row[0..dots]));
        try testing.expectEqual(sl.seg_language, b.app.hits.at(78, 22).?.statusline_seg);
    }
    // 60: the Rust row at 60×24 (`tools/ui-diff.sh`, 2026-09-07): the
    // branch is its glyph and `…`, the lanes touch, the row ends in the
    // clock — the workspace and the language are past the edge.
    {
        var b = try Bench.init(60, 24);
        defer b.deinit();
        try b.onMain(porcelain);
        b.app.focus = .tree;
        const row = try b.row(22);
        const expected = " TREE " ++ sl.pl_right_nerd ++ " " ++ sl.branch_glyph ++ "…" ++ sl.pl_right_nerd ++ " [no file] " ++ sl.pl_left_nerd ++ " " ++ sl.coverage_glyph ++ " F 57% ▲1.0 " ++ idle_cluster ++ sl.pl_left_nerd ++ " WRAP " ++ sl.pl_left_nerd ++ " " ++ sl.bell_glyph ++ "  " ++ spec_clock;
        try testing.expectEqualStrings(expected, trimRight(try normaliseClock(b.app.frame.allocator(), expected, row)));
        const dots = std.mem.indexOf(u8, row, "…").?;
        try testing.expectEqual(@as(usize, 9), try std.unicode.utf8CountCodepoints(row[0..dots]));
        try testing.expect(b.colOf(22, SegId.workspace.raw()) == null);
        try testing.expect(b.colOf(22, sl.seg_language) == null);
        try testing.expectEqual(SegId.clock.raw(), b.app.hits.at(58, 22).?.statusline_seg);
    }
}

// ─── the LSP chip ────────────────────────────────────────────────────────

test "the LSP chip: ` LSP 1 ` on blue between the cluster and WRAP while a server lives; click names it, right-click is the LSP menu; gone with the server" {
    // A real Server over a fake language server (`lsp.TestRig`), the
    // one the LSP tests use; the chip reads `app.lsp.servers` only.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.tree.visible = false;
    // No server: no chip; the status command says so.
    _ = try b.row(38);
    try testing.expect(b.colOf(38, SegId.lsp.raw()) == null);
    try command.run(&b.app, .{ .static = .@"lsp.status" });
    try testing.expectEqualStrings("LSP: no servers running", b.app.lastToast().?);
    var rig: lsp.TestRig = .{};
    try rig.start(&b.app);
    const row = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, row, idle_cluster ++ sl.pl_left_nerd ++ " LSP 1 " ++ sl.pl_left_nerd ++ " WRAP ") != null);
    const x = b.colOf(38, SegId.lsp.raw()).?;
    const p = &b.app.theme.palette;
    try testing.expect(Color.eql(b.cell(x + 1, 38).bg, p.blue));
    try testing.expect(Color.eql(b.cell(x + 1, 38).fg, p.bg_darker));
    try testing.expectEqual(SegId.lsp.raw(), b.app.hits.at(x + 6, 38).?.statusline_seg);
    // Left: the servers and their roots. The rig's root is `/tmp`, not
    // under the workspace, so it reads as it is.
    try b.click(38, SegId.lsp.raw(), .left);
    try testing.expectEqualStrings("LSP: typescript (/tmp)", b.app.lastToast().?);
    // Right: the LSP menu, Rust's nine rows, every id a real command.
    try b.click(38, SegId.lsp.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    try testing.expectEqualStrings("LSP", b.app.overlay.menu.title);
    try testing.expectEqual(@as(usize, 9), b.app.overlay.menu.items.len);
    try testing.expectEqualStrings("Status", b.app.overlay.menu.items[0].label);
    for (b.app.overlay.menu.items) |item| try testing.expect(command.by_name.get(command.name(item.action.command)) != null);
    try b.key(Key.named(.esc));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect((try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = SegId.lsp.raw() })) != null);
    // A root under the workspace reads relative to it (the server owns
    // its root: swap a borrowed one in and back before it is retired).
    const old_root = rig.server.root;
    const under = try std.fmt.allocPrint(testing.allocator, "{s}/crates/core", .{b.ws});
    defer testing.allocator.free(under);
    rig.server.root = under;
    try command.run(&b.app, .{ .static = .@"lsp.status" });
    try testing.expectEqualStrings("LSP: typescript (crates/core)", b.app.lastToast().?);
    rig.server.root = old_root;
    // Retired: the chip goes.
    try rig.stop(&b.app);
    _ = try b.row(38);
    try testing.expect(b.colOf(38, SegId.lsp.raw()) == null);
}

// // changed (lsp-defaults): the chip's missing form.
test "the LSP chip with a missing default server: ` LSP? ` muted with none running, ` LSP 1? ` beside a live count; the status names the install; the menu lists it and Install… opens the tools box" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.tree.visible = false;
    try b.app.env.put("PATH", "");
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/package.json", .data = "{}\n" });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "package.json" });
    defer testing.allocator.free(path);
    const bell_before = b.app.messages.unread();
    _ = try b.app.openPath(path);
    const row = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, row, idle_cluster ++ sl.pl_left_nerd ++ " LSP? " ++ sl.pl_left_nerd ++ " WRAP ") != null);
    try testing.expectEqual(bell_before.warn, b.app.messages.unread().warn);
    const x = b.colOf(38, SegId.lsp.raw()).?;
    const p = &b.app.theme.palette;
    // Muted: the idle bell's colours, not the live chip's blue.
    try testing.expect(Color.eql(b.cell(x + 1, 38).bg, p.bg2));
    try testing.expect(Color.eql(b.cell(x + 1, 38).fg, p.comment));
    try testing.expectEqual(SegId.lsp.raw(), b.app.hits.at(x + 5, 38).?.statusline_seg);
    // Left: the status toast names the binary and its install.
    try b.click(38, SegId.lsp.raw(), .left);
    try testing.expectEqualStrings("LSP: no servers running · missing: vscode-json-language-server (npm i -g vscode-langservers-extracted)", b.app.lastToast().?);
    // Right: Status, the missing row (click copies the hint), Install…, then the eight verbs.
    try b.click(38, SegId.lsp.raw(), .right);
    try testing.expect(b.app.overlay == .menu);
    const items = b.app.overlay.menu.items;
    try testing.expectEqual(@as(usize, 11), items.len);
    try testing.expectEqualStrings("Status", items[0].label);
    try testing.expectEqualStrings("✗ vscode-json-language-server — npm i -g vscode-langservers-extracted", items[1].label);
    try testing.expect(items[1].action == .copy_text);
    try testing.expectEqualStrings("Install vscode-json-language-server…", items[2].label);
    try testing.expect(items[2].action == .lsp_install);
    try testing.expectEqualStrings("vscode-json-language-server", items[2].action.lsp_install);
    try testing.expectEqualStrings("Symbols in file", items[3].label);
    try testing.expect(items[3].separator_before);
    // Install…: the tools installer's box, naming the binary and the line.
    try dispatch.runMenuActionForTest(&b.app, items[2].action);
    try testing.expect(b.app.overlay == .confirm);
    try testing.expectEqualStrings("Missing tool", b.app.overlay.confirm.state.title);
    try testing.expect(std.mem.indexOf(u8, b.app.overlay.confirm.message, "npm i -g vscode-langservers-extracted") != null);
    try b.key(Key.named(.esc));
    // A live server beside the miss: the blue chip carries the count as
    // a muted run.
    var rig: lsp.TestRig = .{};
    try rig.start(&b.app);
    const row2 = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, row2, sl.pl_left_nerd ++ " LSP 1? " ++ sl.pl_left_nerd ++ " WRAP ") != null);
    const x2 = b.colOf(38, SegId.lsp.raw()).?;
    try testing.expect(Color.eql(b.cell(x2 + 1, 38).bg, p.blue));
    try testing.expect(Color.eql(b.cell(x2 + 1, 38).fg, p.bg_darker));
    try testing.expect(Color.eql(b.cell(x2 + 6, 38).fg, p.bg2)); // the `?`, muted
    try rig.stop(&b.app);
}

// ─── the coverage chip on fixed inputs ───────────────────────────────────

test "the coverage chip's text and width on fixed inputs are Rust's: ` <glyph> F 57% ▲1.0 `, 14 cells; the code half after ` · `" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    // The fixture's file says F 57% ▲1.0; pin the numbers instead.
    coverage.ensureLoaded(&b.app);
    b.app.coverage.feature = 57.0;
    b.app.coverage.feature_prev = 56.0;
    b.app.coverage.code = 74.2;
    b.app.coverage.code_prev = 74.21;
    const ui = b.app.frameUi();
    var info = try build(&b.app, ui, Rect.init(0, 38, 120, 1));
    const chip = blk: {
        for (info.right) |sg| if (sg.hit == SegId.coverage.raw()) break :blk sg;
        return error.NoCoverageChip;
    };
    try testing.expectEqualStrings(" " ++ sl.coverage_glyph ++ " F 57%", chip.text);
    try testing.expectEqualStrings(" ▲1.0", chip.accent.?.text);
    try testing.expectEqualStrings(" ", chip.tail);
    try testing.expectEqual(@as(u16, 14), ui.width(chip.text) + ui.width(chip.accent.?.text) + ui.width(chip.tail));
    // `both`: the code reading after ` · `, its own delta — 27 cells.
    b.app.cfg.ui.coverage_chip_mode = .both;
    info = try build(&b.app, ui, Rect.init(0, 38, 120, 1));
    for (info.right) |sg| if (sg.hit == SegId.coverage.raw()) {
        try testing.expectEqualStrings(" · C 74% ±0.0 ", sg.tail);
        try testing.expectEqual(@as(u16, 27), ui.width(sg.text) + ui.width(sg.accent.?.text) + ui.width(sg.tail));
    };
    // `code`: `C 74% ±0.0` in the chip's own ink (a flat delta is not tinted).
    b.app.cfg.ui.coverage_chip_mode = .code;
    info = try build(&b.app, ui, Rect.init(0, 38, 120, 1));
    for (info.right) |sg| if (sg.hit == SegId.coverage.raw()) {
        try testing.expectEqualStrings(" " ++ sl.coverage_glyph ++ " C 74%", sg.text);
        try testing.expectEqualStrings(" ±0.0", sg.accent.?.text);
        try testing.expect(Color.eql(sg.accent.?.fg, b.app.theme.palette.bg_darker));
    };
}

// ─── the now-playing cluster ─────────────────────────────────────────────

const now_playing_mod = @import("now_playing.zig");

test "the now-playing cluster: the idle pair in the preferred player's colours; the transport with a track; the override and the marquee" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    try b.onMain("# branch.head main\n? stray.txt\n");
    b.app.focus = .tree;
    _ = &b.app.theme.palette;
    // Idle, mixr preferred: the Beatport mark and the play box on lime.
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " F 57% ▲1.0 " ++ idle_cluster ++ sl.pl_left_nerd ++ " WRAP ") != null);
    // Music preferred: the apple on Apple Music red, white on it.
    try command.run(&b.app, .{ .static = .@"mixr.set_preferred_music" });
    try testing.expectEqual(Config.MusicApp.music, b.app.cfg.ui.preferred_music_app);
    const apple = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, apple, sl.pl_left_nerd ++ " " ++ sl.apple_glyph ++ " " ++ sl.cluster_play_glyph ++ " ") != null);
    const ax = b.colOf(38, SegId.np_brand.raw()).?;
    try testing.expect(Color.eql(b.cell(ax + 1, 38).bg, Theme.rgb(0xfa243c)));
    try testing.expect(Color.eql(b.cell(ax + 1, 38).fg, Theme.rgb(0xffffff)));
    // Spotify preferred: its mark on Spotify green.
    try command.run(&b.app, .{ .static = .@"mixr.set_preferred_spotify" });
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " " ++ sl.spotify_glyph ++ " " ++ sl.cluster_play_glyph ++ " ") != null);
    try testing.expect(Color.eql(b.cell(b.colOf(38, SegId.np_brand.raw()).? + 1, 38).bg, Theme.rgb(0x1db954)));
    try command.run(&b.app, .{ .static = .@"mixr.set_preferred_mixr" });
    // The override, read on the first tick: a Spotify track playing —
    // pause, skip, `artist - title`, on the track's player's colours,
    // each chip its own hit; the idle pair is gone.
    try b.app.env.put("MNML_NOW_PLAYING", "Karma Police|playing|spotify|Radiohead");
    now_playing_mod.tick(&b.app, 1000);
    try testing.expect(b.app.now_playing.overridden);
    const live = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, live, " F 57% ▲1.0 " ++ sl.pl_left_nerd ++ " " ++ sl.np_pause_glyph ++ " " ++ sl.np_next_glyph ++ " Radiohead - Karma Police " ++ sl.pl_left_nerd ++ " WRAP ") != null);
    try testing.expect(b.colOf(38, SegId.np_brand.raw()) == null);
    const px = b.colOf(38, SegId.np_play.raw()).?;
    try testing.expect(Color.eql(b.cell(px + 1, 38).bg, Theme.rgb(0x1db954)));
    try testing.expectEqual(SegId.np_next.raw(), b.app.hits.at(px + 3, 38).?.statusline_seg);
    try testing.expectEqual(SegId.np_track.raw(), b.app.hits.at(px + 6, 38).?.statusline_seg);
    // Paused: the play glyph. A long title is cut at 28 with an ellipsis.
    b.app.now_playing.current = now_playing_mod.parseOverride("A Title Long Enough To Overflow The Chip|paused|music|An Artist With A Long Name");
    const paused = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, paused, " " ++ sl.np_play_glyph ++ " " ++ sl.np_next_glyph ++ " An Artist With A Long Name -… ") != null);
    try testing.expect(Color.eql(b.cell(b.colOf(38, SegId.np_track.raw()).?, 38).bg, Theme.rgb(0xfa243c)));
    // The marquee: the window slides a cell per step and asks for the frame.
    b.app.cfg.ui.now_playing_marquee = true;
    b.app.now_playing.marquee_next_ms = 0;
    now_playing_mod.tick(&b.app, 2000);
    try testing.expectEqual(@as(?i64, 2300), now_playing_mod.nextDeadlineMs(&b.app));
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " n Artist With A Long Name - ") != null);
    now_playing_mod.tick(&b.app, 2300);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " Artist With A Long Name - A") != null);
    // Copy the title; an empty override is the idle form again.
    try command.run(&b.app, .{ .static = .@"mixr.copy_track" });
    try testing.expect(std.mem.startsWith(u8, b.app.lastToast().?, "copied: An Artist With A Long Name - A Title"));
    b.app.now_playing.current = now_playing_mod.parseOverride("");
    try testing.expect(std.mem.indexOf(u8, try b.row(38), idle_cluster) != null);
    // `--ascii`: the twins, and a breather cell after the cluster.
    b.app.cfg.ui.ascii_icons = true;
    try testing.expect(std.mem.indexOf(u8, try b.row(38), " F 57% ▲1.0  B >   WRAP ") != null);
    // The bell's hit test read the row: the cluster registers words too.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for ([_]u32{ SegId.np_brand.raw(), SegId.np_play.raw(), SegId.np_next.raw(), SegId.np_track.raw() }) |id| {
        try testing.expect((try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = id })) != null);
    }
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

test "the highlight chip: absent by default, there with the size once a buffer's highlighting is off, and the click turns it back on" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    const text = "fn hello() -> u32 {\n    let x: u32 = 42;\n    x\n}\n";
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/code.rs", .data = text });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "code.rs" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    // A file under the limit (there is none by default): no chip.
    const row_pre = try b.row(38);
    try testing.expect(b.colOf(38, SegId.highlight.raw()) == null);
    try testing.expect(std.mem.indexOf(u8, row_pre, "highlight ") == null);
    // Switched off by hand: the chip says so, with the buffer's size.
    try command.run(&b.app, .{ .static = .@"editor.highlight_toggle_file" });
    const row_off = try b.row(38);
    try testing.expect(std.mem.indexOf(u8, row_off, "highlight off · 49 B") != null);
    try testing.expect(b.colOf(38, SegId.highlight.raw()) != null);
    // The hover names the config key and the command.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const tip = (try discovery.describe(&b.app, arena_state.allocator(), .{ .statusline_seg = SegId.highlight.raw() })).?;
    try testing.expect(std.mem.indexOf(u8, tip.title, "Highlighting off for this file") != null);
    try testing.expect(std.mem.indexOf(u8, tip.detail.?, "editor.highlight_max_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, tip.detail.?, "editor.highlight_toggle_file") != null);
    // One click turns it back on — and the chip goes with the reason.
    try b.click(38, SegId.highlight.raw(), .left);
    try testing.expect(!b.app.activeEditor().?.syntax.off);
    try testing.expect(std.mem.indexOf(u8, b.app.lastToast().?, "highlighting on for code.rs") != null);
    // The hits are the last frame's: paint one more, then the chip is gone.
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "highlight ") == null);
    try testing.expect(b.colOf(38, SegId.highlight.raw()) == null);
}

test "the highlight chip stays, reading `on`, while the file is over the limit" {
    var b = try Bench.init(120, 40);
    defer b.deinit();
    b.app.cfg.editor.highlight_max_bytes = 1024;
    var big: [4096]u8 = undefined;
    @memset(&big, 'a');
    try b.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/wide.rs", .data = &big });
    const path = try std.fs.path.join(testing.allocator, &.{ b.ws, "wide.rs" });
    defer testing.allocator.free(path);
    _ = try b.app.openPath(path);
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "highlight off · 4 KB") != null);
    try command.run(&b.app, .{ .static = .@"editor.highlight_this_file" });
    // Over the limit either way: the chip reports the state, not the limit.
    try testing.expect(std.mem.indexOf(u8, try b.row(38), "highlight on · 4 KB") != null);
}

test "the bell's hover lists the unread warnings and errors, newest first, and the read ones are gone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var b = try Bench.init(120, 40);
    defer b.deinit();
    b.app.cfg.ui.hover_tooltip = true;
    try b.app.toastLevel(.info, "saved src/main.zig", .{});
    try b.app.toastLevel(.warn, "no formatter for .fk", .{});
    try b.app.toastLevel(.err, "lsp: fake exited with 1\nrestarting", .{});

    const tip = (try discovery.describe(&b.app, arena, .{ .statusline_seg = SegId.bell.raw() })).?;
    // Newest first, and the info the log also holds is not what the
    // bell counts — so it is not one of the rows.
    try testing.expectEqual(@as(usize, 2), tip.rows.len);
    // A multi-line toast is one row: the message up to its newline.
    try testing.expectEqualStrings("lsp: fake exited with 1", tip.rows[0].text);
    try testing.expectEqualStrings("error", tip.rows[0].sub);
    try testing.expectEqualStrings("no formatter for .fk", tip.rows[1].text);
    try testing.expectEqualStrings("warning", tip.rows[1].sub);

    // The box paints them, and a press on one opens the history.
    _ = (try b.rowHover(38, SegId.bell.raw())).?;
    try testing.expect(std.mem.indexOf(u8, try screen_mod.toTestText(arena, &b.app.screen), "no formatter for .fk") != null);
    const first = b.tipRowAt(0) orelse return error.NoTipRow;
    try b.app.handle(.{ .mouse = .{ .x = first.x, .y = first.y, .kind = .press, .button = .left } });
    try testing.expect(b.app.overlay == .picker);
    try dispatch.key(&b.app, Key.named(.esc));

    // Reading them empties both the figure and its list: a bell with
    // nothing unread lists nothing rather than last week's warnings.
    b.app.messages.markRead();
    const read = (try discovery.describe(&b.app, arena, .{ .statusline_seg = SegId.bell.raw() })).?;
    try testing.expectEqual(@as(usize, 0), read.rows.len);
    try testing.expect(read.row_seg == null);
}

test "a figure's hover lists what it counts, the pointer can walk onto the list, and a row runs its command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var b = try Bench.init(120, 40);
    defer b.deinit();
    b.app.cfg.ui.hover_tooltip = true;
    try b.app.ipc_fx.setSegment(testing.allocator, .{
        .id = "bitbucket_prs.prs_mine",
        .text = "PR 3(2)",
        .side = .left,
        .priority = 5,
        .max_width = 12,
        .tooltip = "Bitbucket \u{b7} 3 open pull requests you authored\nbucket: 40 of 60",
        .items = &.{
            .{ .text = "Fix the login redirect", .sub = "acme/api \u{b7} unapproved", .command = "view.toggle_wrap" },
            .{ .text = "Redesign the empty state", .sub = "acme/web \u{b7} approved", .command = "view.toggle_wrap" },
        },
    });
    const tip = (try discovery.describe(&b.app, arena, .{ .statusline_seg = sl.seg_dyn_base })).?;
    // The publisher's first line is the title; the bucket line it put
    // after a newline is a row of its own, not a run-on.
    try testing.expectEqualStrings("Bitbucket \u{b7} 3 open pull requests you authored", tip.title);
    try testing.expectEqual(@as(usize, 1), tip.lines.len);
    try testing.expectEqualStrings("bucket: 40 of 60", tip.lines[0]);
    try testing.expectEqual(@as(usize, 2), tip.rows.len);
    try testing.expectEqualStrings("Fix the login redirect", tip.rows[0].text);
    try testing.expectEqualStrings("acme/api \u{b7} unapproved", tip.rows[0].sub);
    try testing.expectEqual(@as(?u32, sl.seg_dyn_base), tip.row_seg);

    // `statusline.hover_items` is the cap, and what it cuts is counted.
    b.app.cfg.statusline.hover_items = 1;
    const one = (try discovery.describe(&b.app, arena, .{ .statusline_seg = sl.seg_dyn_base })).?;
    try testing.expectEqual(@as(usize, 1), one.rows.len);
    try testing.expectEqual(@as(usize, 1), one.more);
    // 0 leaves the chip the one-line hover every integration had.
    b.app.cfg.statusline.hover_items = 0;
    const none = (try discovery.describe(&b.app, arena, .{ .statusline_seg = sl.seg_dyn_base })).?;
    try testing.expectEqual(@as(usize, 0), none.rows.len);
    try testing.expect(none.row_seg == null);
    b.app.cfg.statusline.hover_items = 8;

    // The box paints over the row, and every row of it is a hit that
    // remembers where the box was anchored.
    const chip_x = (try b.rowHover(38, sl.seg_dyn_base)).?;
    try testing.expect(std.mem.indexOf(u8, try screen_mod.toTestText(arena, &b.app.screen), "Fix the login redirect") != null);
    const second = b.tipRowAt(1) orelse return error.NoTipRow;
    try testing.expectEqual(chip_x, second.hit.tip_row.x);
    try testing.expectEqual(@as(u16, 38), second.hit.tip_row.y);

    // The pointer moves onto that row: the tip is still the segment's,
    // so the list does not flicker away as the pointer reaches it.
    const same = (try discovery.describe(&b.app, arena, second.hit)).?;
    try testing.expectEqualStrings(tip.title, same.title);

    // And a press on the row runs what the row names.
    const was = b.app.cfg.ui.wrap;
    try b.app.handle(.{ .mouse = .{ .x = second.x, .y = second.y, .kind = .press, .button = .left } });
    try testing.expectEqualStrings(if (was) "wrap off" else "wrap on", b.app.lastToast().?);
    // A row that names no command is a label: nothing runs, no toast.
    try b.app.ipc_fx.setSegment(testing.allocator, .{
        .id = "bitbucket_prs.prs_mine",
        .text = "PR 3(2)",
        .side = .left,
        .priority = 5,
        .max_width = 12,
        .items = &.{.{ .text = "Fix the login redirect" }},
    });
    _ = (try b.rowHover(38, sl.seg_dyn_base)).?;
    const label = b.tipRowAt(0) orelse return error.NoTipRow;
    const toasts = b.app.toasts.items.len;
    try b.app.handle(.{ .mouse = .{ .x = label.x, .y = label.y, .kind = .press, .button = .left } });
    try testing.expectEqual(toasts, b.app.toasts.items.len);
}

test "enclosingSymbol: the innermost container holding the row, never a variable, nothing past the last brace" {
    const S = lsp_types.Symbol;
    // bash-language-server's shape for deploy.sh: functions with full
    // ranges, `local`s as variables inside them.
    const syms = [_]S{
        .{ .name = "usage", .kind = 12, .line = 22, .character = 0, .end_line = 30, .depth = 0 },
        .{ .name = "deploy_one", .kind = 12, .line = 46, .character = 0, .end_line = 62, .depth = 0 },
        .{ .name = "attempt", .kind = 13, .line = 47, .character = 8, .end_line = 47, .depth = 0 },
        .{ .name = "main", .kind = 12, .line = 64, .character = 0, .end_line = 87, .depth = 0 },
        .{ .name = "RETRIES", .kind = 13, .line = 69, .character = 4, .end_line = 69, .depth = 0 },
        .{ .name = "TMPFILE", .kind = 13, .line = 79, .character = 0, .end_line = 79, .depth = 0 },
    };
    try testing.expectEqualStrings("usage", enclosingSymbol(&syms, 24).?);
    try testing.expectEqualStrings("deploy_one", enclosingSymbol(&syms, 61).?);
    try testing.expectEqualStrings("main", enclosingSymbol(&syms, 74).?);
    try testing.expect(enclosingSymbol(&syms, 88) == null);
    try testing.expect(enclosingSymbol(&syms, 40) == null);
    // Nested containers: the inner one.
    const nested = [_]S{
        .{ .name = "Outer", .kind = 5, .line = 0, .character = 0, .end_line = 20, .depth = 0 },
        .{ .name = "inner", .kind = 6, .line = 5, .character = 4, .end_line = 9, .depth = 1 },
    };
    try testing.expectEqualStrings("inner", enclosingSymbol(&nested, 7).?);
    try testing.expectEqualStrings("Outer", enclosingSymbol(&nested, 12).?);
    // A server that gives one line per symbol: the last container at or
    // above the row, as before.
    const flat = [_]S{
        .{ .name = "foo", .kind = 12, .line = 0, .character = 3, .end_line = 0, .depth = 0 },
        .{ .name = "bar", .kind = 12, .line = 4, .character = 3, .end_line = 4, .depth = 0 },
    };
    try testing.expectEqualStrings("foo", enclosingSymbol(&flat, 2).?);
    try testing.expectEqualStrings("bar", enclosingSymbol(&flat, 9).?);
}
