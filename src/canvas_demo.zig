//! canvas-demo: the component gallery — every `src/ui` component on a
//! real terminal, one screen at a time. `tab` / `shift+tab` cycle the
//! screens; `ctrl+c` quits from anywhere. The first screen is the
//! original terminal-layer check (Term + input worker + the Canvas
//! primitives); the rest paint the ui components with live state, so
//! what the headless tests assert can be seen in ghostty, Terminal.app,
//! and under `--ascii`.
//!
//! Screens:
//!   1 canvas    word / grapheme wrap with CJK and emoji, the probe line
//!   2 editor    bufferline + editor view (selection, fold, matches,
//!               syntax spans, an extra cursor) + statusline; hjkl move,
//!               v toggles the selection, z toggles the fold
//!   3 panel     ListPanel with 40 rows and its filter (/ j k g G enter,
//!               click the sort chip, hover a row for the kebab)
//!   4 prompt    "Go to line" over the editor; type, enter, ↑ history
//!   5 confirm   "Unsaved changes" with Save / Discard / Cancel
//!   6 which-key the Leader popup
//!   7 picker    a command palette with fuzzy ranking; type to filter
//!   8 find      the find bar docked under the editor, live match count,
//!               plus the toast stack (ctrl+t adds one; click dismisses)
//!
//! The header row shows the last hit under the pointer (the `HitMap`
//! label) so the click targets can be checked by moving the mouse.
//! Flags: `--ascii` (no box drawing, no nerd glyphs), `--no-nerd`, and a
//! screen number to start on.

const std = @import("std");
const vaxis = @import("vaxis");
const Term = @import("tui/term.zig").Term;
const Input = @import("tui/input.zig").Input;
const ui = @import("ui/ui.zig");
const key_mod = @import("core/key.zig");
const panel_mod = @import("core/panel.zig");
const text = @import("ui/text.zig");
const compat = @import("mnml_sdk").zig_compat;

const Io = std.Io;
const Rect = ui.Rect;
const Canvas = ui.Canvas;
const Ui = ui.Ui;
const Theme = ui.Theme;
const Segment = vaxis.Segment;
const Style = vaxis.Style;
const Key = key_mod.Key;
const ListSort = panel_mod.ListSort;

/// A crash inside the alt screen would print its trace where nobody can
/// read it. Term's hook resets the terminal first.
pub const panic = Term.Panic;

// ── the gallery's document ──

const source =
    \\const std = @import("std");
    \\
    \\pub fn main() !void {
    \\    const greeting = "hello, mnml-zig";
    \\    var count: usize = 0;
    \\    while (count < 3) : (count += 1) {
    \\        std.debug.print("{s} {d}\n", .{ greeting, count });
    \\    }
    \\}
    \\
    \\fn helper(x: u32) u32 {
    \\    return x * 2;
    \\}
    \\
    \\test "helper doubles" {
    \\    try std.testing.expectEqual(@as(u32, 4), helper(2));
    \\}
    \\
;

const keywords = [_][]const u8{ "const", "pub", "fn", "var", "while", "return", "test", "try" };

const Screen = enum(u8) {
    canvas,
    editor,
    panel,
    prompt,
    confirm,
    which_key,
    picker,
    find,

    const count = compat.enumFields(Screen).len;

    fn name(s: Screen) []const u8 {
        return switch (s) {
            .canvas => "canvas",
            .editor => "editor view",
            .panel => "list panel",
            .prompt => "prompt",
            .confirm => "confirm",
            .which_key => "which-key",
            .picker => "picker",
            .find => "find bar + toasts",
        };
    }

    fn next(s: Screen) Screen {
        return @enumFromInt((@intFromEnum(s) + 1) % count);
    }

    fn prev(s: Screen) Screen {
        return @enumFromInt((@intFromEnum(s) + count - 1) % count);
    }
};

const Todo = struct { title: []const u8, done: bool };
const Todos = ui.ListPanel(Todo);

const Gallery = struct {
    gpa: std.mem.Allocator,
    screen: Screen = .canvas,
    theme: Theme = Theme.default,
    hits: ui.HitMap = .{},
    hover: ?struct { x: u16, y: u16 } = null,
    ascii: bool = false,
    nerd_font: bool = true,
    /// The last hit under the pointer, for the header.
    last_hit: [96]u8 = undefined,
    last_hit_len: usize = 0,
    note: [128]u8 = undefined,
    note_len: usize = 0,

    // canvas screen
    last_key: ?vaxis.Key = null,
    keys: u32 = 0,
    resizes: u32 = 0,
    paste_bytes: usize = 0,
    focused: bool = true,

    // editor
    view: ui.editor_view.ViewState = .{},
    cursor: usize,
    anchor: ?usize,
    fold_open: bool = false,
    active_tab: u16 = 0,

    // panel
    todos: [40]Todo = undefined,
    panel: Todos.State = .{},
    sort: ListSort = .newest,

    // overlays
    prompt: ui.prompt.State,
    confirm: ui.confirm.State,
    picker: ui.picker.State,
    find: ui.find_bar.State = .{},
    find_current: usize = 0,
    toasts: std.ArrayListUnmanaged(ui.Toast) = .empty,

    fn init(gpa: std.mem.Allocator) Gallery {
        var g: Gallery = .{
            .gpa = gpa,
            .cursor = 0,
            .anchor = null,
            .prompt = ui.prompt.init(gpa, "Go to line"),
            .confirm = .{ .title = "Unsaved changes", .message = "gallery.zig has unsaved changes.", .choices = &close_choices },
            .picker = .{ .title = "Commands", .total = commands.len },
        };
        // Select the greeting literal on line 3.
        const lit = std.mem.indexOf(u8, source, "\"hello").?;
        g.anchor = lit;
        g.cursor = lit + "\"hello, mnml-zig\"".len;
        for (&g.todos, 0..) |*t, i| t.* = .{ .title = todo_titles[i % todo_titles.len], .done = i % 3 == 0 };
        g.prompt.placeholder = "line number";
        g.find.show_replace = true;
        return g;
    }

    fn deinit(g: *Gallery) void {
        g.panel.deinit(g.gpa);
        ui.prompt.deinit(&g.prompt, g.gpa);
        g.picker.deinit(g.gpa);
        g.find.deinit(g.gpa);
        g.toasts.deinit(g.gpa);
    }

    fn setNote(g: *Gallery, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&g.note, f, args) catch return;
        g.note_len = s.len;
    }

    fn noteText(g: *const Gallery) []const u8 {
        return g.note[0..g.note_len];
    }

    fn toast(g: *Gallery, txt: []const u8, level: ui.toast.Level) void {
        g.toasts.insert(g.gpa, 0, .{ .text = txt, .level = level }) catch {};
        if (g.toasts.items.len > 8) _ = g.toasts.pop();
    }
};

const close_choices = [_]ui.confirm.Choice{ .{ .key = 's', .label = "Save" }, .{ .key = 'd', .label = "Discard" }, .{ .key = 'c', .label = "Cancel" } };

const todo_titles = [_][]const u8{
    "wire the picker to the command registry",
    "fold markers in the gutter",
    "kitty keyboard fallback table",
    "ascii border kind for Terminal.app",
    "hit map rects.json in the IPC channel",
    "statusline segments from integrations",
    "which-key for the vim g prefix",
    "toast stack click-to-dismiss",
    "list panel kebab menu",
    "filter pill placeholder copy",
    "scrollbar drag routing",
    "bufferline overflow arrows",
    "編集ビューの全角テスト",
};

const commands = [_]ui.picker.Item{
    .{ .label = "Open file", .detail = "picker.files", .hint = "ctrl+p" },
    .{ .label = "Command palette", .detail = "picker.commands", .hint = "ctrl+shift+p" },
    .{ .label = "Buffers", .detail = "picker.buffers" },
    .{ .label = "Save", .detail = "file.save", .hint = "ctrl+s" },
    .{ .label = "Save all", .detail = "file.save_all" },
    .{ .label = "Close buffer", .detail = "buffer.close", .hint = "ctrl+w" },
    .{ .label = "Reopen closed buffer", .detail = "buffer.reopen" },
    .{ .label = "Find", .detail = "find.find", .hint = "ctrl+f" },
    .{ .label = "Find next", .detail = "find.next", .hint = "f3" },
    .{ .label = "Find previous", .detail = "find.prev", .hint = "shift+f3" },
    .{ .label = "Replace", .detail = "find.replace", .hint = "ctrl+h" },
    .{ .label = "Go to line", .detail = "editor.goto_line", .hint = "ctrl+g" },
    .{ .label = "Toggle fold", .detail = "editor.toggle_fold" },
    .{ .label = "Unfold all", .detail = "editor.unfold_all" },
    .{ .label = "Add cursor below", .detail = "editor.add_cursor_below" },
    .{ .label = "Add cursor at next word", .detail = "editor.add_cursor_at_next_word", .hint = "ctrl+d" },
    .{ .label = "Toggle wrap", .detail = "view.toggle_wrap" },
    .{ .label = "Use vim keys", .detail = "editor.use_vim" },
    .{ .label = "Use standard keys", .detail = "editor.use_standard" },
    .{ .label = "Split right", .detail = "split.right" },
    .{ .label = "Split down", .detail = "split.down" },
    .{ .label = "Git status", .detail = "git.status" },
    .{ .label = "Git commit", .detail = "git.commit" },
    .{ .label = "Git blame", .detail = "git.blame" },
    .{ .label = "HTTP: send request", .detail = "http.send", .hint = "ctrl+enter" },
    .{ .label = "HTTP: send as a Server-Sent Events stream", .detail = "http.send_streaming" },
    .{ .label = "Toggle hover-help", .detail = "view.toggle_hover_help" },
    .{ .label = "Help", .detail = "view.help", .hint = "f1" },
    .{ .label = "Settings", .detail = "app.settings" },
    .{ .label = "Quit", .detail = "app.quit", .hint = "ctrl+q" },
};

const leader_entries = [_]ui.which_key.Entry{
    .{ .key = "f", .label = "find", .is_group = true },
    .{ .key = "g", .label = "git", .is_group = true },
    .{ .key = "s", .label = "split", .is_group = true },
    .{ .key = "t", .label = "themes", .is_group = true },
    .{ .key = "e", .label = "explorer" },
    .{ .key = "x", .label = "close buffer" },
    .{ .key = "/", .label = "comment" },
    .{ .key = "ch", .label = "cheatsheet" },
    .{ .key = "wK", .label = "which-key" },
    .{ .key = "ra", .label = "rename" },
    .{ .key = "ca", .label = "code action" },
    .{ .key = "fm", .label = "format" },
};

// ── palette for the canvas screen (rgb on purpose: Terminal.app must fold these) ──

const bg: Style = .{ .bg = .{ .rgb = .{ 0x1e, 0x1e, 0x2e } }, .fg = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } } };
const frame_a: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0x89, 0xb4, 0xfa } } };
const frame_b: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } } };
const title_style: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } }, .bold = true };
const accent: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } } };
const dim: Style = .{ .bg = bg.bg, .fg = .{ .rgb = .{ 0x6c, 0x70, 0x86 } } };
const status_style: Style = .{ .bg = .{ .rgb = .{ 0x31, 0x32, 0x44 } }, .fg = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } } };
const status_key: Style = .{ .bg = status_style.bg, .fg = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } }, .bold = true };

const paragraph = [_]Segment{
    .{ .text = "mnml-zig", .style = .{ .bg = bg.bg, .fg = bg.fg, .bold = true } },
    .{ .text = " paints through a clipped Canvas into vaxis's cell store. Word wrap keeps whole words together: ", .style = bg },
    .{ .text = "日本語のテキストは各文字が二セル幅", .style = accent },
    .{ .text = " and 中文也一样, mixed with emoji ", .style = bg },
    .{ .text = "🦊 🐍 🚀", .style = bg },
    .{ .text = ", a ZWJ family 👨‍👩‍👧, flags 🇯🇵 🇳🇿, and a combining mark: e\u{0301}. ", .style = bg },
    .{ .text = "Every wide glyph owns a real space tail, so nothing smears into the border on the right.", .style = bg },
    .{ .text = "\n\nA second paragraph after two newlines — the layout honours them.", .style = dim },
};

const long_tokens = [_]Segment{
    .{ .text = "Grapheme wrap breaks anywhere a word would not: ", .style = bg },
    .{ .text = "Supercalifragilisticexpialidocious_Donaudampfschifffahrtsgesellschaftskapitän_", .style = accent },
    .{ .text = "https://example.com/a/very/long/path/with/no/spaces?that=forces&a=grapheme&wrap=true ", .style = bg },
    .{ .text = "漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字", .style = frame_b },
    .{ .text = " 🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀🦊🐍🚀", .style = bg },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var gallery = Gallery.init(gpa);
    defer gallery.deinit();
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const args = try init.minimal.args.toSlice(arena_state.allocator());
        for (args[1..]) |a| {
            if (std.mem.eql(u8, a, "--ascii")) {
                gallery.ascii = true;
                gallery.nerd_font = false;
            } else if (std.mem.eql(u8, a, "--no-nerd")) {
                gallery.nerd_font = false;
            } else if (std.fmt.parseInt(u8, a, 10)) |n| {
                if (n >= 1 and n <= Screen.count) gallery.screen = @enumFromInt(n - 1);
            } else |_| {}
        }
    }
    gallery.toast("mark 'a set", .info);
    gallery.toast("no mark 'z", .warn);
    gallery.toast("save failed: EACCES", .err);

    const term = try gpa.create(Term);
    defer gpa.destroy(term);
    term.init(io, gpa, init.environ_map, .{}) catch |err| switch (err) {
        error.NotATty => {
            std.debug.print("canvas-demo needs a terminal on stdout\n", .{});
            return err;
        },
        else => return err,
    };
    defer term.deinit();
    try term.setTitle("mnml-zig gallery");

    // Cells hold grapheme slices, not copies: every string painted this
    // frame must outlive `render`. The frame arena is that lifetime.
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();

    try draw(term, &gallery, frame.allocator());
    try term.render();

    var pending: [64]Term.Event = undefined;
    while (true) {
        const first = term.next() catch break;
        var quit = handle(term, &gallery, first) catch break;
        // A burst (paste, mouse motion, key repeat) is one frame.
        const n = term.drain(&pending) catch break;
        for (pending[0..n]) |ev| {
            if (handle(term, &gallery, ev) catch true) quit = true;
        }
        if (quit) break;
        _ = frame.reset(.retain_capacity);
        try draw(term, &gallery, frame.allocator());
        try term.render();
    }
}

// ── keys ──

/// vaxis's key to the trunk's `Key`. Private-use codepoints we do not
/// name (media keys, modifiers alone) are dropped.
fn toKey(k: vaxis.Key) ?Key {
    const mods: key_mod.Mods = .{ .ctrl = k.mods.ctrl, .shift = k.mods.shift, .alt = k.mods.alt, .super = k.mods.super };
    const code: key_mod.KeyCode = switch (k.codepoint) {
        vaxis.Key.enter, vaxis.Key.kp_enter => .enter,
        vaxis.Key.tab => if (k.mods.shift) .backtab else .tab,
        vaxis.Key.escape => .esc,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.delete => .delete,
        vaxis.Key.insert => .insert,
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.f1...vaxis.Key.f12 => .{ .f = @intCast(k.codepoint - vaxis.Key.f1 + 1) },
        else => |cp| blk: {
            if (cp >= 0xE000 and cp <= 0xF8FF) return null;
            break :blk .{ .char = k.shifted_codepoint orelse cp };
        },
    };
    return .{ .code = code, .mods = mods };
}

fn handle(term: *Term, g: *Gallery, ev: Term.Event) !bool {
    switch (ev) {
        .key_press => |vk| {
            if (vk.matches('c', .{ .ctrl = true })) return true;
            g.last_key = vk;
            g.keys += 1;
            const key = toKey(vk) orelse return false;
            if (key.code == .tab and !key.mods.ctrl and !key.mods.alt) {
                g.screen = g.screen.next();
                g.note_len = 0;
                return false;
            }
            if (key.code == .backtab) {
                g.screen = g.screen.prev();
                g.note_len = 0;
                return false;
            }
            try handleScreenKey(g, key);
        },
        .winsize => |ws| {
            try term.resize(ws);
            g.resizes += 1;
        },
        .mouse => |m| {
            const x: u16 = @intCast(@max(0, m.col));
            const y: u16 = @intCast(@max(0, m.row));
            g.hover = .{ .x = x, .y = y };
            if (g.hits.at(x, y)) |target| {
                var w: Io.Writer = .fixed(&g.last_hit);
                target.writeLabel(&w) catch {};
                g.last_hit_len = w.buffered().len;
                if (m.type == .press and m.button == .left) try handleClick(g, target);
            } else {
                g.last_hit_len = 0;
            }
        },
        .paste => |bytes| {
            g.paste_bytes = bytes.len;
            switch (g.screen) {
                .prompt => try ui.prompt.paste(&g.prompt, g.gpa, bytes),
                .picker => try ui.picker.paste(&g.picker, g.gpa, bytes),
                .find => try ui.find_bar.paste(&g.find, g.gpa, bytes),
                .panel => if (g.panel.filter_focused) try ui.text_field.insert(&g.panel.filter, &g.panel.filter_caret, g.gpa, bytes),
                else => {},
            }
            term.freeEvent(ev);
        },
        .focus_in => g.focused = true,
        .focus_out => g.focused = false,
        else => {},
    }
    return false;
}

fn handleScreenKey(g: *Gallery, key: Key) !void {
    switch (g.screen) {
        .canvas => {},
        .editor => handleEditorKey(g, key),
        .panel => {
            const out = try Todos.handleKey(&g.panel, g.gpa, key);
            switch (out) {
                .new_activate => {},
                .activate => |i| g.setNote("activated row {d}", .{i}),
                .filter_changed => g.setNote("filter: {s}", .{g.panel.filterText()}),
                .ignored => if (key.code == .char and key.code.char == 'q') {
                    g.setNote("q is not bound here; ctrl+c quits", .{});
                },
                .consumed => {},
            }
        },
        .prompt => switch (try ui.prompt.handleKey(&g.prompt, g.gpa, key)) {
            .submit => {
                g.setNote("submitted: {s}", .{g.prompt.text()});
                try g.prompt.setText(g.gpa, "");
            },
            .cancel => {
                g.setNote("prompt cancelled", .{});
                try g.prompt.setText(g.gpa, "");
            },
            .consumed => {},
        },
        .confirm => switch (ui.confirm.handleKey(&g.confirm, key)) {
            .choose => |i| g.setNote("chose {s}", .{g.confirm.choices[i].label}),
            .cancel => g.setNote("cancelled (esc)", .{}),
            .consumed => {},
        },
        .which_key => if (key.code == .esc) g.setNote("esc closes the popup", .{}),
        .picker => {
            const order = try ui.picker.rank(g.gpa, g.picker.queryText(), &commands, .{});
            defer g.gpa.free(order);
            switch (try ui.picker.handleKey(&g.picker, g.gpa, key, order.len)) {
                .toggle => {},
                .accept => |i| g.setNote("accepted: {s}", .{commands[order[i]].label}),
                .cancel => g.setNote("picker cancelled", .{}),
                .changed, .consumed, .ignored => {},
            }
        },
        .find => {
            if (key.code == .char and key.code.char == 't' and key.mods.ctrl) {
                g.toast("a fresh toast", .info);
                return;
            }
            const out = try ui.find_bar.handleKey(&g.find, g.gpa, key);
            const total = countMatches(g);
            switch (out) {
                .next, .submit => if (total > 0) {
                    g.find_current = (g.find_current + 1) % total;
                },
                .prev => if (total > 0) {
                    g.find_current = (g.find_current + total - 1) % total;
                },
                .changed => g.find_current = 0,
                .history_prev, .history_next => {},
                .cancel => g.setNote("find cancelled (esc)", .{}),
                .replace_one => g.setNote("replace one: {s} → {s}", .{ g.find.queryText(), g.find.replaceText() }),
                .replace_all => g.setNote("replace all: {s} → {s}", .{ g.find.queryText(), g.find.replaceText() }),
                .toggle_regex => g.setNote("regex: {}", .{g.find.regex}),
                .toggle_case => g.setNote("match case: {}", .{g.find.match_case}),
                .toggle_word => g.setNote("whole word: {}", .{g.find.whole_word}),
                .focus_toggle => g.setNote("focus: {s}", .{@tagName(g.find.focus)}),
                .consumed, .ignored => {},
            }
        },
    }
}

fn handleEditorKey(g: *Gallery, key: Key) void {
    switch (key.code) {
        .left => g.cursor -|= 1,
        .right => g.cursor = @min(g.cursor + 1, source.len),
        .up => g.cursor = lineStep(g.cursor, -1),
        .down => g.cursor = lineStep(g.cursor, 1),
        .char => |c| switch (c) {
            'h' => g.cursor -|= 1,
            'l' => g.cursor = @min(g.cursor + 1, source.len),
            'k' => g.cursor = lineStep(g.cursor, -1),
            'j' => g.cursor = lineStep(g.cursor, 1),
            'v' => g.anchor = if (g.anchor == null) g.cursor else null,
            'z' => g.fold_open = !g.fold_open,
            'g' => g.cursor = 0,
            'G' => g.cursor = source.len - 1,
            else => {},
        },
        .esc => g.anchor = null,
        else => {},
    }
}

fn lineStep(cursor: usize, dir: i2) usize {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..cursor], '\n')) |p| p + 1 else 0;
    const col = cursor - line_start;
    if (dir < 0) {
        if (line_start == 0) return cursor;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0 .. line_start - 1], '\n')) |p| p + 1 else 0;
        return @min(prev_start + col, line_start - 1);
    }
    const line_end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse return cursor;
    const next_end = std.mem.indexOfScalarPos(u8, source, line_end + 1, '\n') orelse source.len;
    return @min(line_end + 1 + col, next_end);
}

fn handleClick(g: *Gallery, target: ui.HitTarget) !void {
    switch (target) {
        .chip => |c| switch (c.kind) {
            .sort => {
                g.sort = g.sort.next();
                g.setNote("sort: {s}", .{g.sort.label()});
            },
            .refresh => g.setNote("refresh clicked", .{}),
            else => {},
        },
        .row => |r| {
            g.panel.cursor = r.idx;
            g.setNote("row {d} selected", .{r.idx});
        },
        .kebab => |r| g.setNote("kebab on row {d}", .{r.idx}),
        .filter_input => {
            g.panel.filter_focused = true;
            g.setNote("filter focused", .{});
        },
        .tab => |tb| {
            g.active_tab = tb.idx;
            g.setNote("tab {d}", .{tb.idx});
        },
        .editor_cell => |c| {
            const lines = try ui.editor_view.Lines.build(g.gpa, source);
            defer g.gpa.free(lines.starts);
            g.cursor = @min(lines.start(c.line) + c.col, source.len);
        },
        .overlay_item => |i| switch (g.screen) {
            .confirm => g.setNote("clicked {s}", .{g.confirm.choices[@min(i, 2)].label}),
            .picker => {
                g.picker.cursor = i;
                g.setNote("picker row {d}", .{i});
            },
            .find => if (i == ui.find_bar.hit_regex) {
                g.find.regex = !g.find.regex;
            } else if (i == ui.find_bar.hit_case) {
                g.find.match_case = !g.find.match_case;
            } else if (i == ui.find_bar.hit_replace) {
                g.find.focus = .replace;
            } else if (i == ui.find_bar.hit_query) {
                g.find.focus = .query;
            },
            else => {},
        },
        .button => |b| if (b >= ui.toast.button_base) {
            const idx: usize = b - ui.toast.button_base;
            if (idx < g.toasts.items.len) _ = g.toasts.orderedRemove(idx);
        },
        .scrollbar => |sb| g.setNote("scrollbar {s}", .{@tagName(sb.axis)}),
        else => {},
    }
}

// ── the document's derived views ──

fn findMatches(arena: std.mem.Allocator, needle: []const u8, match_case: bool) ![]const ui.editor_view.Range {
    var out: std.ArrayListUnmanaged(ui.editor_view.Range) = .empty;
    if (needle.len == 0) return out.items;
    var i: usize = 0;
    while (i + needle.len <= source.len) : (i += 1) {
        const hay = source[i .. i + needle.len];
        const hit = if (match_case) std.mem.eql(u8, hay, needle) else std.ascii.eqlIgnoreCase(hay, needle);
        if (hit) {
            try out.append(arena, .{ .start = i, .end = i + needle.len });
            i += needle.len - 1;
        }
    }
    return out.items;
}

fn countMatches(g: *Gallery) usize {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const m = findMatches(fba.allocator(), g.find.queryText(), g.find.match_case) catch return 0;
    return m.len;
}

fn syntaxSpans(arena: std.mem.Allocator, t: *const Theme) ![]const ui.editor_view.Span {
    var out: std.ArrayListUnmanaged(ui.editor_view.Span) = .empty;
    const kw_style: Style = .{ .fg = Theme.onedark.purple, .bg = t.bg.bg };
    const str_style: Style = .{ .fg = Theme.onedark.green, .bg = t.bg.bg };
    const builtin_style: Style = .{ .fg = Theme.onedark.cyan, .bg = t.bg.bg };
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, source, i + 1, '"') orelse source.len - 1;
            try out.append(arena, .{ .start = i, .end = end + 1, .style = str_style });
            i = end + 1;
            continue;
        }
        if (c == '@') {
            var j = i + 1;
            while (j < source.len and std.ascii.isAlphanumeric(source[j])) j += 1;
            try out.append(arena, .{ .start = i, .end = j, .style = builtin_style });
            i = j;
            continue;
        }
        if (std.ascii.isAlphabetic(c) and (i == 0 or !std.ascii.isAlphanumeric(source[i - 1]))) {
            var j = i;
            while (j < source.len and std.ascii.isAlphanumeric(source[j])) j += 1;
            const word = source[i..j];
            for (keywords) |kw| if (std.mem.eql(u8, word, kw)) {
                try out.append(arena, .{ .start = i, .end = j, .style = kw_style });
                break;
            };
            i = j;
            continue;
        }
        i += 1;
    }
    return out.items;
}

// ── painting ──

fn draw(term: *Term, g: *Gallery, arena: std.mem.Allocator) !void {
    const screen = term.screen();
    screen.cursor_vis = false;
    g.hits.reset();
    const c = Canvas.init(screen, .{ .quantize = term.quantize() });
    const t = &g.theme;
    const uictx: Ui = .{
        .canvas = c,
        .hits = &g.hits,
        .theme = t,
        .arena = arena,
        .focus = switch (g.screen) {
            .panel => .{ .panel = .todos },
            .prompt, .confirm, .which_key, .picker => .overlay,
            else => .{ .pane = 0 },
        },
        .hover = if (g.hover) |h| .{ .x = h.x, .y = h.y } else null,
        .ascii = g.ascii,
        .nerd_font = g.nerd_font,
    };
    const full = c.full();
    c.fill(full, t.bg);

    const header = full.splitTop(1);
    drawHeader(uictx, header.top, g);
    const body = header.rest;

    var caret: ?ui.Caret = null;
    switch (g.screen) {
        .canvas => try drawCanvasScreen(c, body, g, term, arena),
        .editor => caret = try drawEditor(uictx, body, g, null, .{ .current = null, .total = 0 }),
        .panel => {
            const split = body.splitLeft(30);
            _ = try drawEditor(uictx, split.rest, g, null, .{ .current = null, .total = 0 });
            const rows = filteredTodos(g, arena);
            caret = Todos.draw(&g.panel, uictx, split.left, .{
                .panel = .todos,
                .label = "TODOS",
                .subtitle = if (g.panel.filterText().len > 0) uictx.fmt(" ({d} of {d})", .{ rows.len, g.todos.len }) else null,
                .sort_chip = g.sort.label(),
                .sort_widest = ListSort.widest_label,
                .rows = rows,
                .paintRow = paintTodo,
                .has_kebab = true,
                .empty = .{ .message = "No todos match", .hint = "esc clears the filter" },
            });
        },
        .prompt => {
            _ = try drawEditor(uictx, body, g, null, .{ .current = null, .total = 0 });
            caret = ui.prompt.draw(uictx, body, &g.prompt);
        },
        .confirm => {
            _ = try drawEditor(uictx, body, g, null, .{ .current = null, .total = 0 });
            ui.confirm.draw(uictx, body, &g.confirm);
        },
        .which_key => {
            _ = try drawEditor(uictx, body, g, null, .{ .current = null, .total = 0 });
            ui.which_key.draw(uictx, body, "Leader", &leader_entries);
        },
        .picker => {
            _ = try drawEditor(uictx, body, g, null, .{ .current = null, .total = 0 });
            const order = try ui.picker.rank(arena, g.picker.queryText(), &commands, .{});
            const items = try ui.picker.gather(arena, &commands, order);
            caret = ui.picker.draw(uictx, body, &g.picker, items);
        },
        .find => {
            const matches = try findMatches(arena, g.find.queryText(), g.find.match_case);
            if (g.find_current >= matches.len) g.find_current = 0;
            const info: ui.find_bar.Info = .{ .current = if (matches.len > 0) g.find_current else null, .total = matches.len };
            caret = try drawEditor(uictx, body, g, matches, info);
            // Above the statusline and the two find rows.
            ui.toast.draw(uictx, body.splitBottom(3).top, g.toasts.items);
        },
    }
    if (caret) |cr| {
        screen.cursor_vis = true;
        screen.cursor = .{ .row = cr.y, .col = cr.x };
    }
}

fn drawHeader(uictx: Ui, r: Rect, g: *Gallery) void {
    const t = uictx.theme;
    uictx.fill(r, t.bufferline);
    const idx = @intFromEnum(g.screen) + 1;
    const left = uictx.fmt(" mnml-zig gallery  {d}/{d} {s}  ·  tab next · shift+tab back · ctrl+c quit", .{ idx, Screen.count, g.screen.name() });
    var x = r.x + uictx.putStr(r.x, r.y, r.w, left, Theme.onBg(t.fg, t.bufferline.bg));
    if (g.noteText().len > 0) {
        x += uictx.putStr(x, r.y, r.right() -| x, uictx.fmt("  ·  {s}", .{g.noteText()}), Theme.onBg(t.warn_fg, t.bufferline.bg));
    }
    const right = if (g.last_hit_len > 0) uictx.fmt(" hit: {s} ", .{g.last_hit[0..g.last_hit_len]}) else " hit: — ";
    _ = uictx.putStrRight(r.right(), r.y, r.right() -| x, right, Theme.onBg(t.muted, t.bufferline.bg));
}

fn filteredTodos(g: *Gallery, arena: std.mem.Allocator) []const Todo {
    const q = g.panel.filterText();
    var out: std.ArrayListUnmanaged(Todo) = .empty;
    for (g.todos) |todo| {
        if (q.len == 0 or ui.fuzzy.score(q, todo.title) != null) out.append(arena, todo) catch return out.items;
    }
    switch (g.sort) {
        .newest => {},
        .oldest => std.mem.reverse(Todo, out.items),
        .name => std.mem.sort(Todo, out.items, {}, struct {
            fn less(_: void, a: Todo, b: Todo) bool {
                return std.mem.lessThan(u8, a.title, b.title);
            }
        }.less),
        .name_desc => std.mem.sort(Todo, out.items, {}, struct {
            fn less(_: void, a: Todo, b: Todo) bool {
                return std.mem.lessThan(u8, b.title, a.title);
            }
        }.less),
    }
    return out.items;
}

fn paintTodo(uictx: Ui, r: Rect, row: Todo, selected: bool) void {
    const t = uictx.theme;
    const style = ui.list_panel.rowStyle(t, selected);
    const box = if (uictx.ascii or !uictx.nerd_font) (if (row.done) "[x] " else "[ ] ") else (if (row.done) "\u{f14a} " else "\u{f0c8} ");
    const x = r.x + uictx.putStr(r.x, r.y, r.w, box, Theme.withFg(style, if (row.done) t.accent.fg else t.muted.fg));
    var s = style;
    if (row.done) s.strikethrough = true;
    _ = uictx.putStr(x, r.y, r.right() -| x, uictx.clipStr(row.title, r.right() -| x), s);
}

/// Bufferline, the editor view, the statusline, and the find bar when
/// `matches` is given. Returns the caret: the find bar's when it is
/// up, else the editor's cursor.
fn drawEditor(uictx: Ui, area: Rect, g: *Gallery, matches: ?[]const ui.editor_view.Range, info: ui.find_bar.Info) !?ui.Caret {
    const t = uictx.theme;
    const tabs = area.splitTop(1);
    const tab_list = [_]ui.bufferline.Tab{
        .{ .id = 0, .title = "gallery.zig", .dirty = true, .active = g.active_tab == 0 },
        .{ .id = 1, .title = "README.md", .dirty = false, .active = g.active_tab == 1 },
        .{ .id = 2, .title = "build.zig", .dirty = false, .active = g.active_tab == 2 },
    };
    _ = ui.bufferline.draw(uictx, tabs.top, &tab_list, .{});

    const status = tabs.rest.splitBottom(1);
    var pane = status.top;
    var caret: ?ui.Caret = null;
    if (matches != null) {
        const bar = pane.splitBottom(if (g.find.show_replace) 2 else 1);
        pane = bar.top;
        caret = ui.find_bar.draw(uictx, bar.rest, &g.find, info);
    }

    const folds = [_]ui.editor_view.Fold{.{ .first_line = 5, .last_line = 7 }};
    const lines = try ui.editor_view.Lines.build(uictx.arena, source);
    const cur_line = lines.lineOf(g.cursor);
    const cur_col = g.cursor - lines.start(cur_line);
    const extra = [_]usize{lines.start(11) + 4};
    const doc: ui.editor_view.Doc = .{
        .text = source,
        .cursor = g.cursor,
        .anchor = g.anchor,
        .extra_cursors = &extra,
        .folds = if (g.fold_open) &.{} else &folds,
        .spans = try syntaxSpans(uictx.arena, t),
        .matches = matches orelse &.{},
        .current_match = if (matches != null and info.total > 0) info.current else null,
        .wrap = false,
        .tab_width = 4,
        .focused = uictx.focus == .pane,
    };
    const cursor_cell = ui.editor_view.draw(uictx, 0, pane, &g.view, doc);
    if (caret == null and g.screen == .editor) {
        if (cursor_cell) |cc| caret = .{ .x = cc.x, .y = cc.y };
    }

    const sel: ?usize = if (g.anchor) |a| (if (a > g.cursor) a - g.cursor else g.cursor - a) else null;
    const P = &uictx.theme.palette;
    const Seg = ui.statusline.Seg;
    const mode_bg = ui.statusline.modeBg(uictx.theme, if (g.anchor != null) .visual else .normal);
    const left = [_]Seg{
        Seg.init(if (uictx.ascii) " V " else " \u{e7c5} ", P.orange, mode_bg).strong().withHit(ui.statusline.seg_mode),
        Seg.init(if (g.anchor != null) "VISUAL " else "NORMAL ", P.bg_darker, mode_bg).strong().withHit(ui.statusline.seg_mode),
        Seg.init(if (uictx.ascii) " z " else " \u{e6a9} ", ui.Theme.rgb(0xf7a41d), P.statusline).withHit(ui.statusline.seg_file),
        Seg.init("gallery.zig ● ", P.fg, P.statusline).withHit(ui.statusline.seg_file),
    };
    var right: std.ArrayListUnmanaged(Seg) = .empty;
    try right.append(uictx.arena, Seg.init(uictx.fmt(" Ln {d}/{d} Col {d} ", .{ cur_line + 1, lines.count(), cur_col + 1 }), P.fg, P.bg2).withHit(ui.statusline.seg_position));
    if (sel) |n| try right.append(uictx.arena, Seg.init(uictx.fmt(" Sel {d} ", .{n}), P.bg_darker, P.yellow));
    try right.append(uictx.arena, Seg.init(if (uictx.ascii) " ! " else " \u{f0f3} ", P.comment, P.bg2));
    try right.append(uictx.arena, Seg.init(if (uictx.ascii) " gallery " else "\u{f07b} gallery ", P.blue, P.bg3).strong());
    try right.append(uictx.arena, Seg.init("  zig ", P.bg_darker, P.blue).strong().withHit(ui.statusline.seg_language));
    ui.statusline.draw(uictx, status.rest, .{
        .left = &left,
        .right = right.items,
        .middle = if (g.screen == .which_key) "space" else null,
    });
    return caret;
}

// ── the original canvas screen ──

fn drawCanvasScreen(c: Canvas, body_in: Rect, g: *Gallery, term: *Term, arena: std.mem.Allocator) !void {
    c.fill(body_in, bg);
    const bottom = body_in.splitBottom(2);
    const body = bottom.top;

    var left: Rect = undefined;
    var right: Rect = undefined;
    if (body.w >= 80) {
        const v = body.splitLeft(body.w * 3 / 5);
        left = v.left;
        right = v.rest;
    } else {
        const h = body.splitTop(body.h / 2);
        left = h.top;
        right = h.rest;
    }
    try drawBox(c, left, frame_a, " Word wrap · ASCII / CJK / emoji ", &paragraph, .word, arena, g.ascii);
    try drawBox(c, right, frame_b, " Grapheme wrap · long tokens ", &long_tokens, .grapheme, arena, g.ascii);
    try drawStatus(c, bottom.rest, term, g, arena);
}

fn drawBox(c: Canvas, r: Rect, frame: Style, title: []const u8, segs: []const Segment, wrap: text.Wrap, arena: std.mem.Allocator, ascii: bool) !void {
    const tt = [_]Segment{.{ .text = title, .style = title_style }};
    const inner = c.border(r, if (ascii) .ascii else .rounded, frame, &tt);
    if (inner.isEmpty()) return;
    const pad = inner.inset(1);
    if (pad.isEmpty()) return;
    const text_area = pad.splitBottom(1);
    const rows = c.text(text_area.top, segs, .{ .wrap = wrap, .trim = true });
    const need = c.measure(segs, text_area.top.w, .{ .wrap = wrap, .trim = true });
    const footer = try std.fmt.allocPrint(arena, "rows {d}/{d} at {d} cols", .{ rows, need, text_area.top.w });
    _ = c.text(text_area.rest, &.{.{ .text = footer, .style = dim }}, .{ .alignment = .right });
}

fn drawStatus(c: Canvas, r: Rect, term: *Term, g: *const Gallery, arena: std.mem.Allocator) !void {
    c.fill(r, status_style);
    const rows = r.splitTop(1);

    var cw: Io.Writer.Allocating = .init(arena);
    try cw.writer.writeAll(" ");
    try term.caps.write(&cw.writer);
    try cw.writer.print("  {d}x{d} resizes={d}{s}", .{
        term.screen().width,
        term.screen().height,
        g.resizes,
        if (g.focused) "" else "  (unfocused)",
    });
    _ = c.text(rows.top, &.{.{ .text = cw.written(), .style = status_style }}, .{});

    var kw_alloc: Io.Writer.Allocating = .init(arena);
    const kw = &kw_alloc.writer;
    if (g.last_key) |key| {
        try kw.print(" key #{d}: ", .{g.keys});
        const name_start = kw_alloc.written().len;
        try Input.writeKeyName(kw, key);
        const name_end = kw_alloc.written().len;
        try kw.print("  cp=U+{X:0>4}", .{key.codepoint});
        if (key.shifted_codepoint) |s| try kw.print(" shifted=U+{X:0>4}", .{s});
        if (key.text) |tx| try kw.print(" text=\"{s}\"", .{tx});
        if (g.paste_bytes > 0) try kw.print("  paste={d}B", .{g.paste_bytes});
        if (g.hover) |h| try kw.print("  mouse=({d},{d})", .{ h.x, h.y });
        const line = kw_alloc.written();
        _ = c.text(rows.rest, &.{
            .{ .text = line[0..name_start], .style = status_style },
            .{ .text = line[name_start..name_end], .style = status_key },
            .{ .text = line[name_end..], .style = status_style },
        }, .{});
    } else {
        try kw.writeAll(" key: (none yet) — try ctrl+p, then ctrl+shift+p, alt+enter, shift+tab");
        _ = c.text(rows.rest, &.{.{ .text = kw_alloc.written(), .style = status_style }}, .{});
    }
}
