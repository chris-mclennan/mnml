//! First-launch wizard — one box, eight sections walked top to bottom:
//! Nerd Font · Keyboard · Input style · Claude Code + Codex · AI billing
//! preference · AI ghost-text · VSCode `code` shim · Integrations. The
//! focused section carries the `▸`; ↑↓ move between sections, 1–8
//! jump, ←→ (h l) change
//! the focused section's answer, y / n answer a yes-no outright, Space
//! runs the section's action (an install) where it has one and cycles
//! the answer where it does not, Enter finishes, Esc is "ask me later".
//!
//! The component paints from a `Model` (every answer as a value) and
//! hands what a key *means* back as an `Outcome`; the app owns the
//! answers and what Enter writes. The Keyboard section is a live
//! checklist rather than a question: the chords it lists tick as they
//! arrive, which is a fact about the terminal, not an answer.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const key_mod = @import("../core/key.zig");

const Style = vaxis.Style;

pub const Key = key_mod.Key;

pub const Section = enum(u8) {
    nerd_font,
    keyboard,
    input_style,
    claude_codex,
    ai_routing,
    ai_ghost_text,
    vscode_shim,
    integrations,

    pub const count = @typeInfo(Section).@"enum".fields.len;

    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .nerd_font => "Nerd Font",
            .keyboard => "Keyboard",
            .input_style => "Input style",
            .claude_codex => "Claude Code + Codex",
            .ai_routing => "AI billing preference",
            .ai_ghost_text => "AI ghost-text",
            .vscode_shim => "VSCode `code` shim",
            .integrations => "Integrations",
        };
    }
};

/// The chords the Keyboard section listens for, in checklist order.
pub const Probe = struct { label: []const u8, purpose: []const u8, key: Key };
pub const probes = [_]Probe{
    .{ .label = "Ctrl+→", .purpose = "word right", .key = .{ .code = .right, .mods = .{ .ctrl = true } } },
    .{ .label = "Ctrl+←", .purpose = "word left", .key = .{ .code = .left, .mods = .{ .ctrl = true } } },
    .{ .label = "Option/Alt+→", .purpose = "word right (macOS Option)", .key = .{ .code = .right, .mods = .{ .alt = true } } },
    .{ .label = "Option/Alt+←", .purpose = "word left (macOS Option)", .key = .{ .code = .left, .mods = .{ .alt = true } } },
};

/// The Keyboard section's Space line — the same words in every
/// terminal, so the dump does not depend on where it was cut; what
/// Space does is the terminal's (`app/key_doctor.zig`).
pub const keyboard_space_hint = "  Space — fix Option-as-Alt: ghostty gets its config written, others the steps.";

pub const Route = enum { auto, sub, api, off };

/// One first-party integration on the Integrations section: a checkbox
/// and what the marketplace says about it.
pub const IntegrationRow = struct {
    label: []const u8,
    checked: bool = false,
    /// The version the install would land; empty when not listed.
    version: []const u8 = "",
    status: Status = .available,

    pub const Status = enum {
        available,
        installed,
        update,
        queued,
        installing,
        /// The marketplace is still fetching its listing.
        checking,
        /// Not in the marketplace this mnml reads (a source build without
        /// the catalogue, or no release for this platform).
        unavailable,

        pub fn text(s: Status, ascii: bool) []const u8 {
            return switch (s) {
                .available => "not installed",
                .installed => if (ascii) "[+ installed]" else "[✓ installed]",
                .update => "update available",
                .queued => "queued",
                .installing => if (ascii) "installing..." else "installing…",
                .checking => if (ascii) "checking..." else "checking…",
                .unavailable => "not offered for this mnml",
            };
        }
    };
};
pub const route_labels = [_][]const u8{ "Auto", "Sub", "API", "Off" };

/// Everything the box paints, as values.
pub const Model = struct {
    /// null = not answered yet.
    nerd_font_icons: ?bool = null,
    keys_seen: [probes.len]bool = .{false} ** probes.len,
    vim: bool = false,
    claude_installed: bool = false,
    codex_installed: bool = false,
    route_claude: Route = .auto,
    route_codex: Route = .auto,
    /// Which product row ←→ changes inside AI billing.
    ai_row: u1 = 0,
    ghost_text: bool = true,
    /// `code` resolves on PATH.
    code_shim_ok: bool = false,
    /// The Nerd Font install line's short form for this OS, shown once
    /// "boxes" is answered; the OS note under it (empty = none).
    nerd_install: []const u8 = "",
    nerd_note: []const u8 = "",
    /// What Space does on the `code` shim section, in one line.
    code_shim_note: []const u8 = "",
    /// What Space did on the Keyboard section (`key_doctor.fixNote`);
    /// empty until it is pressed.
    keyboard_note: []const u8 = "",
    /// The Integrations section's rows, and which one ←→ / y / n toggle.
    /// `integration_row == integrations.len` is the Private
    /// integrations row under them.
    integrations: []const IntegrationRow = &.{},
    integration_row: u8 = 0,
    /// Under the Private integrations row: what the last add said —
    /// the source's id and count (`ok`), or why it was refused.
    private_note: []const u8 = "",
    private_ok: bool = false,
};

pub const State = struct {
    section: Section = .nerd_font,
    scroll: usize = 0,
};

pub const Outcome = union(enum) {
    consumed,
    /// Esc: ask me later — nothing persists.
    cancel,
    /// Enter: finish and persist the touched answers.
    finish,
    /// ←/→ (h/l) on the focused section.
    adjust: i8,
    /// y / n on a yes-no section.
    answer: bool,
    /// A listed chord arrived while Keyboard is focused.
    probe: usize,
    /// Tab inside AI billing: the other product row.
    other_row,
    /// Space: the focused section's action — an install where the
    /// section has one, else the same as `adjust = 1`.
    action,
};

/// Hit ids: a section header is its index; an answer chip is
/// `chip_base + section * 16 + choice`.
pub const chip_base: u32 = 1 << 12;

pub fn chipHit(s: Section, choice: usize) u32 {
    return chip_base + @as(u32, @intFromEnum(s)) * 16 + @as(u32, @intCast(choice));
}

pub const Hit = union(enum) { section: Section, chip: struct { section: Section, choice: usize } };

pub fn decodeHit(h: u32) ?Hit {
    if (h < chip_base) return if (h < Section.count) .{ .section = @enumFromInt(h) } else null;
    const rel = h - chip_base;
    if (rel / 16 >= Section.count) return null;
    return .{ .chip = .{ .section = @enumFromInt(rel / 16), .choice = rel % 16 } };
}

pub fn handleKey(s: *State, key: Key) Outcome {
    // The keyboard probes come first: a chord in the list is a fact,
    // whatever section is focused it ticks the row.
    for (probes, 0..) |p, i| if (key.code.eql(p.key.code) and key.mods.eql(p.key.mods)) return .{ .probe = i };
    const last = Section.count - 1;
    switch (key.code) {
        .esc => return .cancel,
        .enter => return .finish,
        .up => s.section = @enumFromInt(@intFromEnum(s.section) -| 1),
        .down => s.section = @enumFromInt(@min(@intFromEnum(s.section) + 1, last)),
        .left => return .{ .adjust = -1 },
        .right => return .{ .adjust = 1 },
        .tab => return .other_row,
        .char => |c| {
            if (key.mods.ctrl or key.mods.alt) return .consumed;
            switch (c) {
                'k' => s.section = @enumFromInt(@intFromEnum(s.section) -| 1),
                'j' => s.section = @enumFromInt(@min(@intFromEnum(s.section) + 1, last)),
                'h' => return .{ .adjust = -1 },
                'l' => return .{ .adjust = 1 },
                ' ' => return .action,
                'y' => return .{ .answer = true },
                'n' => return .{ .answer = false },
                '1'...'9' => {
                    const idx: usize = @intCast(c - '1');
                    if (idx < Section.count) s.section = @enumFromInt(idx);
                },
                else => {},
            }
        },
        else => {},
    }
    return .consumed;
}

/// The Integrations section's last row: a private source, through the
/// same prompt as the Marketplace tab's `+ source`.
pub const private_row_text = "Private integrations: a folder or owner/repo — Space adds one";
pub const private_row_text_ascii = "Private integrations: a folder or owner/repo - Space adds one";

/// The Integrations section's key line.
pub const integrations_hint = "  y / → check · Tab next row · Space installs the checked now · Enter too";

pub const title = "First-launch setup";
pub const hint_text = "[↑↓] section · [←→] choose · [Space] install · [Enter] Finish · [Esc] Ask me later";
pub const hint_text_ascii = "[up/dn] section - [lt/rt] choose - [Space] install - [Enter] Finish - [Esc] Ask me later";
pub const max_width: u16 = 92;

const Line = struct {
    text: []const u8,
    style: Style,
    hit: ?u32 = null,
};

fn radio(ui: Ui, on: bool, label: []const u8) []const u8 {
    return ui.fmt("  {s} {s}", .{ if (on) (if (ui.ascii) "(*)" else "(•)") else "( )", label });
}

pub const badge_installed = "[✓ installed]";
pub const badge_installed_ascii = "[+ installed]";
pub const badge_missing = "[ not installed — Space to install ]";
pub const badge_missing_ascii = "[ not installed - Space to install ]";

/// A note under a row, one line per `\n`; nothing for an empty note.
fn noteLines(ui: Ui, lines: *std.ArrayListUnmanaged(Line), note: []const u8, style: Style) !void {
    if (note.len == 0) return;
    var it = std.mem.splitScalar(u8, note, '\n');
    while (it.next()) |l| try lines.append(ui.arena, .{ .text = ui.fmt("  {s}", .{l}), .style = style });
}

/// `  <label>                  [✓ installed]` — Rust's badge row.
fn badge(ui: Ui, label: []const u8, on: bool) []const u8 {
    const b = if (on) (if (ui.ascii) badge_installed_ascii else badge_installed) else (if (ui.ascii) badge_missing_ascii else badge_missing);
    return ui.fmt("  {s:<30}{s}", .{ label, b });
}

/// Paint the box, scrolled so the focused section shows. Registers a
/// hit per section header and per answer chip.
pub fn draw(ui: Ui, area: Rect, s: *State, m: Model) void {
    const t = ui.theme;
    const bg = t.overlay_bg.bg;
    const body = Theme.onBg(t.fg, bg);
    const muted = Theme.onBg(t.muted, bg);
    const good = Theme.withFg(t.overlay_bg, t.mode_insert.bg);

    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var section_start: [Section.count]usize = undefined;
    inline for (comptime std.enums.values(Section)) |sec| {
        const focused = s.section == sec;
        section_start[@intFromEnum(sec)] = lines.items.len;
        const head_style = if (focused) Theme.onBg(t.accent, bg) else muted;
        const rule = if (ui.ascii) "--" else "──";
        const marker = if (focused) (if (ui.ascii) "> " else "▸ ") else "  ";
        lines.append(ui.arena, .{ .text = ui.fmt("{s}{s} {d} · {s} {s}", .{ marker, rule, @intFromEnum(sec) + 1, sec.title(), rule }), .style = head_style, .hit = @intFromEnum(sec) }) catch return;
        switch (sec) {
            .nerd_font => {
                lines.append(ui.arena, .{ .text = if (ui.ascii) "  Sample glyphs:   >   [f]   [x]   *" else "  Sample glyphs:   ▸   󰈙   󰅖   ●", .style = body }) catch return;
                lines.append(ui.arena, .{ .text = radio(ui, m.nerd_font_icons == true, "Render as icons — Nerd Font detected"), .style = body, .hit = chipHit(sec, 1) }) catch return;
                lines.append(ui.arena, .{ .text = radio(ui, m.nerd_font_icons == false, "Render as boxes — no Nerd Font"), .style = body, .hit = chipHit(sec, 0) }) catch return;
                if (m.nerd_font_icons == false) {
                    const act = if (focused) Theme.onBg(t.accent, bg) else body;
                    lines.append(ui.arena, .{ .text = "  Space — install Symbols Nerd Font Mono for this OS:", .style = act, .hit = chipHit(sec, 2) }) catch return;
                    lines.append(ui.arena, .{ .text = ui.fmt("    {s}", .{m.nerd_install}), .style = act, .hit = chipHit(sec, 2) }) catch return;
                    noteLines(ui, &lines, m.nerd_note, muted) catch return;
                }
            },
            .keyboard => {
                for (probes, 0..) |p, i| {
                    const seen = m.keys_seen[i];
                    const mark = if (seen) (if (ui.ascii) "+" else "✓") else "·";
                    lines.append(ui.arena, .{ .text = ui.fmt("  {s}  {s:<14}  {s}", .{ mark, p.label, p.purpose }), .style = if (seen) good else muted }) catch return;
                }
                lines.append(ui.arena, .{ .text = "  Press each chord; a tick means it reached mnml.", .style = muted }) catch return;
                lines.append(ui.arena, .{ .text = keyboard_space_hint, .style = muted }) catch return;
                noteLines(ui, &lines, m.keyboard_note, good) catch return;
            },
            .input_style => {
                lines.append(ui.arena, .{ .text = radio(ui, !m.vim, "standard — VS Code keys, modeless"), .style = body, .hit = chipHit(sec, 0) }) catch return;
                lines.append(ui.arena, .{ .text = radio(ui, m.vim, "vim — Neovim + NvChad chords"), .style = body, .hit = chipHit(sec, 1) }) catch return;
            },
            .claude_codex => {
                lines.append(ui.arena, .{ .text = badge(ui, "Claude Code CLI (`claude`)", m.claude_installed), .style = if (m.claude_installed) good else body, .hit = chipHit(sec, 0) }) catch return;
                lines.append(ui.arena, .{ .text = badge(ui, "Codex CLI (`codex`)", m.codex_installed), .style = if (m.codex_installed) good else body, .hit = chipHit(sec, 1) }) catch return;
                lines.append(ui.arena, .{ .text = "  Space runs the missing one's installer in a pane.", .style = muted }) catch return;
                lines.append(ui.arena, .{ .text = "  The chip in the top-right appears when the CLI is found.", .style = muted }) catch return;
            },
            .ai_routing => {
                lines.append(ui.arena, .{ .text = routeRow(ui, "Claude Code:", m.route_claude, focused and m.ai_row == 0), .style = body, .hit = chipHit(sec, 0) }) catch return;
                lines.append(ui.arena, .{ .text = routeRow(ui, "Codex:", m.route_codex, focused and m.ai_row == 1), .style = body, .hit = chipHit(sec, 1) }) catch return;
                lines.append(ui.arena, .{ .text = "  Auto follows your login · Sub: the subscription · API: the key · Tab switches rows", .style = muted }) catch return;
            },
            .ai_ghost_text => {
                lines.append(ui.arena, .{ .text = radio(ui, m.ghost_text, "On — inline suggestions as you type"), .style = body, .hit = chipHit(sec, 1) }) catch return;
                lines.append(ui.arena, .{ .text = radio(ui, !m.ghost_text, "Off"), .style = body, .hit = chipHit(sec, 0) }) catch return;
            },
            .vscode_shim => {
                lines.append(ui.arena, .{ .text = badge(ui, "`code` on PATH", m.code_shim_ok), .style = if (m.code_shim_ok) good else body, .hit = chipHit(sec, 0) }) catch return;
                noteLines(ui, &lines, m.code_shim_note, muted) catch return;
            },
            .integrations => {
                for (m.integrations, 0..) |row, i| {
                    const here = focused and m.integration_row == i;
                    const mark = if (here) (if (ui.ascii) "> " else "▸ ") else "  ";
                    const box = if (row.checked) "[x]" else "[ ]";
                    const text = ui.fmt("  {s}{s} {s:<12}{s:<8}  {s}", .{ mark, box, row.label, row.version, row.status.text(ui.ascii) });
                    const style = if (row.status == .installed) good else body;
                    lines.append(ui.arena, .{ .text = text, .style = style, .hit = chipHit(sec, i) }) catch return;
                }
                {
                    const here = focused and m.integration_row == m.integrations.len;
                    const mark = if (here) (if (ui.ascii) "> " else "▸ ") else "  ";
                    const text = ui.fmt("  {s}{s}", .{ mark, if (ui.ascii) private_row_text_ascii else private_row_text });
                    lines.append(ui.arena, .{ .text = text, .style = if (here) Theme.onBg(t.accent, bg) else body, .hit = chipHit(sec, m.integrations.len) }) catch return;
                    if (m.private_note.len > 0) noteLines(ui, &lines, ui.fmt("    {s}", .{m.private_note}), if (m.private_ok) good else muted) catch return;
                }
                lines.append(ui.arena, .{ .text = integrations_hint, .style = muted }) catch return;
                lines.append(ui.arena, .{ .text = "  Nothing checked, nothing installed. More in INTEGRATIONS → Marketplace.", .style = muted }) catch return;
            },
        }
        lines.append(ui.arena, .{ .text = "", .style = body }) catch return;
    }

    var widest: u16 = ui.width(hint_text) + 2;
    for (lines.items) |l| widest = @max(widest, ui.width(l.text) + 2);
    const w = @min(@min(max_width, widest + 2), area.w -| 2);
    const want_h: u16 = @intCast(@min(@as(usize, area.h), lines.items.len + 3));
    const inner = overlay.box(ui, area, w, want_h, title, .center);
    if (inner.isEmpty() or inner.h < 3) return;

    // Scroll so the focused section's header and body are visible.
    const list_h: usize = inner.h - 1;
    const start = section_start[@intFromEnum(s.section)];
    const end: usize = if (@intFromEnum(s.section) + 1 < Section.count) section_start[@intFromEnum(s.section) + 1] else lines.items.len;
    if (start < s.scroll) s.scroll = start;
    if (end > s.scroll + list_h) s.scroll = end -| list_h;
    if (start < s.scroll) s.scroll = start;

    var y: u16 = inner.y;
    var idx = s.scroll;
    while (idx < lines.items.len and y < inner.y + @as(u16, @intCast(list_h))) : ({
        idx += 1;
        y += 1;
    }) {
        const l = lines.items[idx];
        const r = Rect.init(inner.x, y, inner.w, 1);
        _ = ui.putStr(r.x, y, r.w, ui.clipStr(l.text, r.w), l.style);
        if (l.hit) |h| ui.hit(r, .{ .overlay_item = h });
    }
    const foot = inner.row(inner.h - 1);
    var hint_style = muted;
    hint_style.dim = false;
    const hint = if (ui.ascii) hint_text_ascii else hint_text;
    _ = ui.putStr(foot.x + 1, foot.y, foot.w -| 2, ui.clipStr(hint, foot.w -| 2), hint_style);
}

/// `  ▸ Claude Code:   [Sub]  API   Off   Auto` — the chosen route
/// bracketed, the focused row marked.
fn routeRow(ui: Ui, label: []const u8, route: Route, focused: bool) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ui.arena, if (focused) (if (ui.ascii) "  > " else "  ▸ ") else "    ") catch return label;
    out.appendSlice(ui.arena, label) catch return label;
    var pad: usize = 14 -| label.len;
    while (pad > 0) : (pad -= 1) out.append(ui.arena, ' ') catch return label;
    for (route_labels, 0..) |rl, i| {
        const on = i == @intFromEnum(route);
        out.print(ui.arena, "{s}{s}{s}  ", .{ if (on) "[" else " ", rl, if (on) "]" else " " }) catch return label;
    }
    return out.items;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the eight sections paint in order with their answers; the focused one carries the marker" {
    var f = try Fixture.init(100, 40);
    defer f.deinit();
    var s: State = .{};
    var m: Model = .{ .nerd_font_icons = true, .vim = true, .route_claude = .sub, .code_shim_ok = true, .nerd_install = "brew install --cask font-symbols-only-nerd-font", .code_shim_note = "Space links the bundle's `code`." };
    m.keys_seen[0] = true;
    draw(f.ui(), f.full(), &s, m);
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, " First-launch setup ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "▸ ── 1 · Nerd Font ──") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Sample glyphs") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(•) Render as icons") != null);
    try testing.expect(std.mem.indexOf(u8, text, "( ) Render as boxes") != null);
    try testing.expect(std.mem.indexOf(u8, text, "✓  Ctrl+→") != null);
    try testing.expect(std.mem.indexOf(u8, text, "·  Option/Alt+→") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(•) vim") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Claude Code CLI (`claude`)    [ not installed — Space to install ]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "`code` on PATH                [✓ installed]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "chip in the top-right appears when the CLI is found") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Space links the bundle's") != null);
    // "icons" answered: no install row
    try testing.expect(std.mem.indexOf(u8, text, "Space — install Symbols") == null);
    try testing.expect(std.mem.indexOf(u8, text, "AI billing preference") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Claude Code:   Auto   [Sub]   API    Off") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Ask me later") != null);
    // section headers and chips are click targets
    var saw_section = false;
    var saw_chip = false;
    for (f.hits.items.items) |h| if (decodeHit(h.target.overlay_item)) |hit| switch (hit) {
        .section => |sec| saw_section = saw_section or sec == .keyboard,
        .chip => |c| saw_chip = saw_chip or (c.section == .input_style and c.choice == 1),
    };
    try testing.expect(saw_section and saw_chip);
    // "boxes" answered: the install row with this OS's line, a click target
    m.nerd_font_icons = false;
    m.nerd_note = "macOS 26: the cask is the path that registers.";
    var g = try Fixture.init(100, 40);
    defer g.deinit();
    draw(g.ui(), g.full(), &s, m);
    const text2 = try g.text();
    try testing.expect(std.mem.indexOf(u8, text2, "Space — install Symbols Nerd Font Mono for this OS:") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "    brew install --cask font-symbols-only-nerd-font") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "macOS 26: the cask") != null);
    var saw_install = false;
    for (g.hits.items.items) |h| if (decodeHit(h.target.overlay_item)) |hit| switch (hit) {
        .chip => |c| saw_install = saw_install or (c.section == .nerd_font and c.choice == 2),
        else => {},
    };
    try testing.expect(saw_install);
}

test "keys: sections walk with ↓/j and 1-8; answers, probes, finish and cancel come back as outcomes" {
    var s: State = .{};
    try testing.expect(handleKey(&s, Key.named(.down)) == .consumed);
    try testing.expect(s.section == .keyboard);
    try testing.expectEqual(@as(usize, 2), handleKey(&s, .{ .code = .right, .mods = .{ .alt = true } }).probe);
    _ = handleKey(&s, Key.char('j'));
    try testing.expect(s.section == .input_style);
    try testing.expectEqual(@as(i8, 1), handleKey(&s, Key.named(.right)).adjust);
    try testing.expect(handleKey(&s, Key.char('y')).answer);
    _ = handleKey(&s, Key.char('7'));
    try testing.expect(s.section == .vscode_shim);
    _ = handleKey(&s, Key.named(.down));
    try testing.expect(s.section == .integrations);
    _ = handleKey(&s, Key.named(.down));
    try testing.expect(s.section == .integrations);
    _ = handleKey(&s, Key.char('8'));
    try testing.expect(s.section == .integrations);
    _ = handleKey(&s, Key.char('1'));
    try testing.expect(s.section == .nerd_font);
    _ = handleKey(&s, Key.named(.up));
    try testing.expect(s.section == .nerd_font);
    try testing.expect(handleKey(&s, Key.named(.tab)) == .other_row);
    try testing.expect(handleKey(&s, Key.char(' ')) == .action);
    try testing.expect(handleKey(&s, Key.named(.enter)) == .finish);
    try testing.expect(handleKey(&s, Key.named(.esc)) == .cancel);
}

test "the Integrations section: a checkbox per first-party integration, its version and status, the focused row marked, each a click target" {
    var f = try Fixture.init(100, 60);
    defer f.deinit();
    var s: State = .{ .section = .integrations };
    const rows = [_]IntegrationRow{
        .{ .label = "Jira", .checked = true, .version = "0.2.0", .status = .available },
        .{ .label = "Bitbucket", .version = "0.2.0", .status = .installed },
    };
    draw(f.ui(), f.full(), &s, .{ .integrations = &rows, .integration_row = 1 });
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ ── 8 · Integrations ──") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  [x] Jira        0.2.0     not installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "▸ [ ] Bitbucket   0.2.0     [✓ installed]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Space installs the checked now") != null);
    // The Private integrations row under the first-party ones, a click
    // target of its own; no note until a source is added.
    try testing.expect(std.mem.indexOf(u8, text, "    Private integrations: a folder or owner/repo — Space adds one") != null);
    var hits: usize = 0;
    for (f.hits.items.items) |h| if (decodeHit(h.target.overlay_item)) |hit| switch (hit) {
        .chip => |c| {
            if (c.section == .integrations) hits += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), hits);
    // Focused and added: the row is marked, the note under it.
    var g = try Fixture.init(100, 60);
    defer g.deinit();
    draw(g.ui(), g.full(), &s, .{ .integrations = &rows, .integration_row = 2, .private_note = "added acme: 3 integrations found", .private_ok = true });
    const text2 = try g.text();
    try testing.expect(std.mem.indexOf(u8, text2, "▸ Private integrations") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "      added acme: 3 integrations found") != null);
}
