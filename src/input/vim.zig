//! The modal (vim) handler: a mode machine (normal / insert / replace /
//! visual / visual-line / visual-block / cmdline), counts, a pending
//! operator with its prefix state, registers, and the `:` line with
//! history. It emits `EditOp`s; it never sees the buffer.
//!
//! Chords the later vim slices own are marked `TODO(vim-slice: …)` and
//! answer `.consumed` (they took a keystroke) or `.ignored`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("mod.zig");
const Key = input.Key;
const KeyCode = input.KeyCode;
const EditOp = input.EditOp;
const EditCtx = input.EditCtx;
const InputResult = input.InputResult;
const AppCommand = input.AppCommand;
const CommandId = input.CommandId;
const ops = input.ops;
const repeated = input.repeated;
const surround = @import("../editor/surround.zig");

pub const VimMode = enum { normal, insert, replace, visual, visual_line, visual_block };

pub const PendingOp = enum {
    delete,
    change,
    yank,
    indent,
    outdent,
    reflow,
    lower,
    upper,
    toggle_case,
    comment,
    surround_add,
    @"align",
    filter,

    fn glyph(op: PendingOp) []const u8 {
        return switch (op) {
            .delete => "d",
            .change => "c",
            .yank => "y",
            .indent => ">",
            .outdent => "<",
            .reflow => "gq",
            .lower => "gu",
            .upper => "gU",
            .toggle_case => "g~",
            .comment => "gc",
            .surround_add => "ys",
            .@"align" => "gA",
            .filter => "!",
        };
    }
};

pub const Prefix = union(enum) {
    none,
    g,
    gc,
    gq,
    z,
    z_fold,
    replace,
    block_replace_char,
    mark_set,
    mark_jump_line,
    mark_jump_exact,
    text_object_inner,
    text_object_around,
    find_char: struct { forward: bool, before: bool },
    window,
    bracket_open,
    bracket_close,
    register,
    macro_record_target,
    macro_replay_target,
    surround_delete,
    surround_change: u21,
    surround_add_char_wait,
    flash1,
    flash2: u21,
    align_char_wait,
};

pub const ex_history_max = 100;

/// What a `:` line asks for, as far as the handler can tell without the
/// app. The app's ex interpreter runs it; this only lets a caller route
/// the common file verbs early.
pub const ExKind = enum { write, quit, write_quit, edit, substitute, other };

pub fn classifyEx(line_in: []const u8) ExKind {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0) return .other;
    // Strip a leading range (`%`, `'<,'>`, `1,5`).
    var i: usize = 0;
    while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '%' or line[i] == ',' or line[i] == '\'' or line[i] == '<' or line[i] == '>' or line[i] == '.' or line[i] == '$')) i += 1;
    const cmd = line[i..];
    if (cmd.len == 0) return .other;
    if (cmd[0] == 's' and (cmd.len == 1 or cmd[1] == '/' or cmd[1] == '#' or cmd[1] == '|' or std.mem.startsWith(u8, cmd, "substitute") or std.mem.startsWith(u8, cmd, "s "))) return .substitute;
    var j: usize = 0;
    while (j < cmd.len and (std.ascii.isAlphabetic(cmd[j]) or cmd[j] == '!')) j += 1;
    const verb = cmd[0..j];
    const table = .{
        .{ "w", .write },        .{ "write", .write },      .{ "w!", .write },        .{ "wa", .write },
        .{ "wall", .write },     .{ "q", .quit },           .{ "q!", .quit },         .{ "quit", .quit },
        .{ "quit!", .quit },     .{ "qa", .quit },          .{ "qa!", .quit },        .{ "qall", .quit },
        .{ "wq", .write_quit },  .{ "wq!", .write_quit },   .{ "x", .write_quit },    .{ "xit", .write_quit },
        .{ "wqa", .write_quit }, .{ "wqall", .write_quit }, .{ "xall", .write_quit }, .{ "e", .edit },
        .{ "e!", .edit },        .{ "edit", .edit },        .{ "ed", .edit },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, verb, entry[0])) return entry[1];
    }
    return .other;
}

pub const Vim = struct {
    gpa: Allocator,
    vmode: VimMode = .normal,
    /// The count being typed (`12` in `12dd`). Null ⇒ 1.
    count: ?u32 = null,
    op: ?PendingOp = null,
    prefix: Prefix = .none,
    cmdline: std.ArrayList(u8) = .empty,
    cmdline_open: bool = false,
    /// Byte offset of the caret within `cmdline`.
    cmdline_cursor: usize = 0,
    tab_width: usize,
    text_width: usize,
    use_tabs: bool,
    /// Last `f`/`F`/`t`/`T` so `;` and `,` can re-fire it.
    last_find_char: ?struct { ch: u21, forward: bool, before: bool } = null,
    /// `n` / `N` are relative to the last search's direction.
    last_search_backward: bool = false,
    /// `"x` — sticks for exactly one register-touching op.
    pending_register: ?u21 = null,
    insert_waiting_for_register: bool = false,
    insert_literal_next: bool = false,
    /// Mirror of the buffer's macro state: decides what `q` does.
    is_recording_macro: bool = false,
    /// Insert `Ctrl+O`: one normal command, then back to insert.
    insert_oneshot_normal: bool = false,
    /// Oldest first, capped at `ex_history_max`. Entries gpa-owned.
    ex_history: std.ArrayList([]u8) = .empty,
    ex_history_cursor: ?usize = null,
    ex_history_typing: ?[]u8 = null,
    cmdline_pending_ctrl_r: bool = false,
    /// A visual text object just set the selection to its exact range —
    /// the next operator must not widen it. Any other visual key clears it.
    visual_exact: bool = false,

    pub fn init(gpa: Allocator, cfg: input.Config) Vim {
        return .{ .gpa = gpa, .tab_width = @max(cfg.tab_width, 1), .text_width = @max(cfg.text_width, 8), .use_tabs = cfg.use_tabs };
    }

    pub fn configure(self: *Vim, cfg: input.Config) void {
        self.tab_width = @max(cfg.tab_width, 1);
        self.text_width = @max(cfg.text_width, 8);
        self.use_tabs = cfg.use_tabs;
    }

    /// What Tab types in insert / replace: one `\t` or a tab stop of spaces.
    fn tabText(self: *const Vim, arena: Allocator) Allocator.Error![]const u8 {
        return if (self.use_tabs) "\t" else try spaces(arena, self.tab_width);
    }

    pub fn deinit(self: *Vim) void {
        self.cmdline.deinit(self.gpa);
        for (self.ex_history.items) |e| self.gpa.free(e);
        self.ex_history.deinit(self.gpa);
        if (self.ex_history_typing) |t| self.gpa.free(t);
    }

    // ─── trait surface ───

    pub fn name(_: *const Vim) []const u8 {
        return "vim";
    }

    pub fn mode(self: *const Vim) input.EditingMode {
        return switch (self.vmode) {
            .normal => .normal,
            .insert => .insert,
            .replace => .replace,
            .visual => .visual,
            .visual_line => .visual_line,
            .visual_block => .visual_block,
        };
    }

    pub fn isCmdlineOpen(self: *const Vim) bool {
        return self.cmdline_open;
    }

    pub fn isOpPending(self: *const Vim) bool {
        return self.op != null or self.prefix != .none;
    }

    pub fn onBlur(self: *Vim) void {
        self.enterNormal();
    }

    pub fn requestInsertMode(self: *Vim) void {
        self.enterInsert();
    }

    pub fn requestVisualMode(self: *Vim) void {
        self.vmode = .visual;
        self.prefix = .none;
    }

    pub fn cmdlineGet(self: *const Vim) ?[]const u8 {
        return if (self.cmdline_open) self.cmdline.items else null;
    }

    pub fn cmdlineSet(self: *Vim, text: ?[]const u8) Allocator.Error!void {
        self.cmdline.clearRetainingCapacity();
        if (text) |t| {
            try self.cmdline.appendSlice(self.gpa, t);
            self.cmdline_open = true;
            self.cmdline_cursor = t.len;
        } else {
            self.cmdline_open = false;
            self.cmdline_cursor = 0;
        }
    }

    pub fn cmdlineCaret(self: *const Vim) ?usize {
        return if (self.cmdline_open) @min(self.cmdline_cursor, self.cmdline.items.len) else null;
    }

    pub fn setCmdlineCaret(self: *Vim, byte: usize) void {
        if (self.cmdline_open) self.cmdline_cursor = @min(byte, self.cmdline.items.len);
    }

    pub fn setExHistory(self: *Vim, entries: []const []const u8) Allocator.Error!void {
        for (self.ex_history.items) |e| self.gpa.free(e);
        self.ex_history.clearRetainingCapacity();
        const skip = entries.len -| ex_history_max;
        for (entries[skip..]) |e| {
            const copy = try self.gpa.dupe(u8, e);
            errdefer self.gpa.free(copy);
            try self.ex_history.append(self.gpa, copy);
        }
    }

    pub fn exHistory(self: *const Vim) []const []const u8 {
        return self.ex_history.items;
    }

    /// `:line▏rest`, or the pending register / count / operator / prefix.
    pub fn pendingDisplay(self: *const Vim, arena: Allocator) Allocator.Error!?[]const u8 {
        var s = std.ArrayList(u8).empty;
        if (self.cmdline_open) {
            const cur = @min(self.cmdline_cursor, self.cmdline.items.len);
            try s.append(arena, ':');
            try s.appendSlice(arena, self.cmdline.items[0..cur]);
            try s.appendSlice(arena, "\u{258f}");
            try s.appendSlice(arena, self.cmdline.items[cur..]);
            return s.items;
        }
        if (self.pending_register) |r| {
            try s.append(arena, '"');
            try appendChar(&s, arena, r);
        }
        if (self.count) |n| try s.print(arena, "{d}", .{n});
        if (self.op) |op| try s.appendSlice(arena, op.glyph());
        const p: []const u8 = switch (self.prefix) {
            .none => "",
            .g => "g",
            .gc => "gc",
            .gq => "gq",
            .z => "Z",
            .z_fold => "z",
            .replace => "r",
            .block_replace_char => "r",
            .mark_set => "m",
            .mark_jump_line => "'",
            .mark_jump_exact => "`",
            .text_object_inner => "i",
            .text_object_around => "a",
            .find_char => |f| if (f.forward) (if (f.before) "t" else "f") else (if (f.before) "T" else "F"),
            .window => "^W",
            .bracket_open => "[",
            .bracket_close => "]",
            .register => "\"",
            .macro_record_target => "q",
            .macro_replay_target => "@",
            .surround_delete => "ds",
            .surround_change => "cs",
            .surround_add_char_wait => "ys",
            .flash1 => "s",
            .flash2 => "s?",
            .align_char_wait => "gA",
        };
        try s.appendSlice(arena, p);
        return if (s.items.len == 0) null else s.items;
    }

    pub fn operatorMenuHint(self: *const Vim) ?input.MenuHint {
        return switch (self.prefix) {
            .g => .{ .prefix = "g", .items = &.{
                .{ .key = 'g', .label = "buffer start" },             .{ .key = 'd', .label = "definition" },                 .{ .key = 'r', .label = "references" },
                .{ .key = 'v', .label = "reselect" },                 .{ .key = 'J', .label = "join (no space)" },            .{ .key = 'u', .label = "lowercase", .group = true },
                .{ .key = 'U', .label = "uppercase", .group = true }, .{ .key = '~', .label = "toggle case", .group = true }, .{ .key = 'c', .label = "comment", .group = true },
            } },
            .z_fold => .{ .prefix = "z", .items = &.{
                .{ .key = 'a', .label = "toggle fold" }, .{ .key = 'o', .label = "open fold" }, .{ .key = 'c', .label = "close fold" },
                .{ .key = 'R', .label = "open all" },    .{ .key = 'M', .label = "close all" }, .{ .key = 'z', .label = "center" },
            } },
            .window => .{ .prefix = "ctrl+w", .items = &.{
                .{ .key = 's', .label = "split down" },  .{ .key = 'v', .label = "split right" }, .{ .key = 'w', .label = "next split" },
                .{ .key = 'q', .label = "close split" }, .{ .key = 'o', .label = "only" },        .{ .key = 'H', .label = "move far left" },
                .{ .key = 'J', .label = "move bottom" }, .{ .key = 'K', .label = "move top" },    .{ .key = 'L', .label = "move far right" },
                .{ .key = 'r', .label = "rotate" },      .{ .key = '=', .label = "equalize" },    .{ .key = 'n', .label = "new scratch" },
            } },
            else => null,
        };
    }

    // ─── state helpers ───

    fn resetPending(self: *Vim) void {
        self.count = null;
        self.op = null;
        self.prefix = .none;
    }

    fn count1(self: *const Vim) u32 {
        return @max(self.count orelse 1, 1);
    }

    fn enterInsert(self: *Vim) void {
        self.vmode = .insert;
        self.resetPending();
    }

    fn enterNormal(self: *Vim) void {
        self.vmode = .normal;
        self.resetPending();
        self.cmdline_open = false;
        self.cmdline.clearRetainingCapacity();
        self.cmdline_cursor = 0;
    }

    fn openCmdline(self: *Vim, seed: []const u8) Allocator.Error!void {
        self.cmdline.clearRetainingCapacity();
        try self.cmdline.appendSlice(self.gpa, seed);
        self.cmdline_open = true;
        self.cmdline_cursor = seed.len;
        self.cmdline_pending_ctrl_r = false;
    }

    fn pushDigit(self: *Vim, d: u32) void {
        const cur = self.count orelse 0;
        self.count = cur *| 10 +| d;
    }

    fn runCmd(id: CommandId) InputResult {
        return .{ .app = .{ .run_command = id } };
    }

    // ─── key tables ───

    fn motion(code: KeyCode) ?EditOp {
        return switch (code) {
            .char => |c| switch (c) {
                'h' => .move_left,
                'l' => .move_right,
                'j' => .move_down,
                'k' => .move_up,
                'w' => .move_word_right,
                'b' => .move_word_left,
                'e' => .move_word_end,
                'W' => .move_big_word_right,
                'B' => .move_big_word_left,
                'E' => .move_big_word_end,
                '0' => .move_line_start,
                '^', '_' => .move_line_first_non_ws,
                '$' => .move_line_last_char,
                '+' => .move_down_first_non_ws,
                '-' => .move_up_first_non_ws,
                'G' => .move_buffer_end,
                '{' => .{ .move_paragraph = .{ .forward = false } },
                '}' => .{ .move_paragraph = .{ .forward = true } },
                '(' => .{ .move_sentence = .{ .forward = false } },
                ')' => .{ .move_sentence = .{ .forward = true } },
                else => null,
            },
            .left => .move_left,
            .right => .move_right,
            .down => .move_down,
            .up => .move_up,
            .home => .move_line_start,
            .end => .move_line_last_char,
            .enter => .move_down_first_non_ws,
            .page_up => .page_up,
            .page_down => .page_down,
            else => null,
        };
    }

    fn modifiedMotion(key: Key) ?EditOp {
        const m = key.mods;
        return switch (key.code) {
            .left => if (m.super) .move_line_first_non_ws else if (m.ctrl or m.alt or m.shift) .move_word_left else null,
            .right => if (m.super) .move_line_last_char else if (m.ctrl or m.alt or m.shift) .move_word_right else null,
            .up => if (m.shift) .page_up else null,
            .down => if (m.shift) .page_down else null,
            .home => if (m.ctrl or m.super) .move_buffer_start else null,
            .end => if (m.ctrl or m.super) .move_buffer_end else null,
            else => null,
        };
    }

    fn charOf(key: Key) ?u21 {
        return switch (key.code) {
            .char => |c| c,
            else => null,
        };
    }

    fn isCtrlChar(key: Key, c: u21) bool {
        if (!key.mods.ctrl) return false;
        const k = charOf(key) orelse return false;
        return k == c or (k < 0x80 and std.ascii.toLower(@intCast(k)) == c);
    }

    // ─── dispatch ───

    pub fn handleKey(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        if (self.cmdline_open) return self.handleCmdline(key, arena);
        const result = switch (self.vmode) {
            .insert => try self.handleInsert(key, arena),
            .replace => try self.handleReplace(key, arena),
            .normal => try self.handleNormal(key, ctx, arena),
            .visual, .visual_line => try self.handleVisual(key, ctx, arena),
            .visual_block => try self.handleVisualBlock(key, arena),
        };
        // A pending `"x` routes the next register-touching op list.
        if (result == .ops and self.pending_register != null) {
            var touches = false;
            for (result.ops) |o| {
                if (o.touchesClipboard()) touches = true;
            }
            if (touches) {
                const reg = self.pending_register;
                self.pending_register = null;
                const list = try arena.alloc(EditOp, result.ops.len + 1);
                list[0] = .{ .set_register_hint = reg };
                @memcpy(list[1..], result.ops);
                return .{ .ops = list };
            }
        }
        if (self.insert_oneshot_normal and self.vmode == .normal and self.op == null and self.prefix == .none) {
            const consumed_more = result != .consumed or !isCtrlChar(key, 'o');
            if (consumed_more) {
                self.insert_oneshot_normal = false;
                self.vmode = .insert;
            }
        }
        return result;
    }

    // ─── cmdline ───

    fn handleCmdline(self: *Vim, key: Key, arena: Allocator) Allocator.Error!InputResult {
        const gpa = self.gpa;
        const line = &self.cmdline;
        const cur = @min(self.cmdline_cursor, line.items.len);
        if (self.cmdline_pending_ctrl_r) {
            self.cmdline_pending_ctrl_r = false;
            if (isCtrlChar(key, 'w')) return .{ .app = .{ .cmdline_insert_cursor_word = false } };
            if (isCtrlChar(key, 'a')) return .{ .app = .{ .cmdline_insert_cursor_word = true } };
        }
        if (isCtrlChar(key, 'r')) {
            self.cmdline_pending_ctrl_r = true;
            return .consumed;
        }
        if (isCtrlChar(key, 'w')) {
            var end = cur;
            while (end > 0 and std.ascii.isWhitespace(line.items[end - 1])) end -= 1;
            var start = end;
            while (start > 0 and !std.ascii.isWhitespace(line.items[start - 1])) start -= 1;
            line.replaceRangeAssumeCapacity(start, cur - start, &.{});
            self.cmdline_cursor = start;
            return .consumed;
        }
        if (isCtrlChar(key, 'u')) {
            line.clearRetainingCapacity();
            self.cmdline_cursor = 0;
            return .consumed;
        }
        if (isCtrlChar(key, 'a') or isCtrlChar(key, 'b')) {
            self.cmdline_cursor = 0;
            return .consumed;
        }
        if (isCtrlChar(key, 'e')) {
            self.cmdline_cursor = line.items.len;
            return .consumed;
        }
        if (isCtrlChar(key, 'v')) return .{ .app = .cmdline_paste_from_clipboard };
        switch (key.code) {
            .tab => return .{ .app = .cmdline_tab_complete },
            .backtab => return .{ .app = .{ .cmdline_popup_move = -1 } },
            .esc => {
                self.closeCmdline();
                return .consumed;
            },
            .enter => {
                if (line.items.len == 0) {
                    self.closeCmdline();
                    return .consumed;
                }
                const text = try arena.dupe(u8, line.items);
                try self.pushHistory(line.items);
                self.closeCmdline();
                return .{ .app = .{ .ex_command = text } };
            },
            .up => {
                if (self.ex_history.items.len == 0) return .{ .app = .{ .cmdline_popup_move = -1 } };
                if (self.ex_history_cursor == null) {
                    if (self.ex_history_typing) |t| gpa.free(t);
                    self.ex_history_typing = try gpa.dupe(u8, line.items);
                    self.ex_history_cursor = self.ex_history.items.len;
                }
                const idx = self.ex_history_cursor.? -| 1;
                self.ex_history_cursor = idx;
                try self.setLine(self.ex_history.items[idx]);
                return .consumed;
            },
            .down => {
                const curh = self.ex_history_cursor orelse return .{ .app = .{ .cmdline_popup_move = 1 } };
                const next = curh + 1;
                if (next >= self.ex_history.items.len) {
                    const typing = self.ex_history_typing orelse "";
                    try self.setLine(typing);
                    if (self.ex_history_typing) |t| gpa.free(t);
                    self.ex_history_typing = null;
                    self.ex_history_cursor = null;
                } else {
                    self.ex_history_cursor = next;
                    try self.setLine(self.ex_history.items[next]);
                }
                return .consumed;
            },
            .left => {
                self.cmdline_cursor = prevBoundary(line.items, cur);
                return .consumed;
            },
            .right => {
                self.cmdline_cursor = nextBoundary(line.items, cur);
                return .consumed;
            },
            .home => {
                self.cmdline_cursor = 0;
                return .consumed;
            },
            .end => {
                self.cmdline_cursor = line.items.len;
                return .consumed;
            },
            .backspace => {
                if (cur == 0) {
                    if (line.items.len == 0) self.closeCmdline();
                    return .consumed;
                }
                const prev = prevBoundary(line.items, cur);
                line.replaceRangeAssumeCapacity(prev, cur - prev, &.{});
                self.cmdline_cursor = prev;
                self.stopHistoryWalk();
                return .consumed;
            },
            .delete => {
                if (cur < line.items.len) {
                    const next = nextBoundary(line.items, cur);
                    line.replaceRangeAssumeCapacity(cur, next - cur, &.{});
                    self.stopHistoryWalk();
                }
                return .consumed;
            },
            .char => |c| {
                if (key.mods.ctrl or key.mods.alt or key.mods.super) return .consumed;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return .consumed;
                try line.insertSlice(gpa, cur, buf[0..n]);
                self.cmdline_cursor = cur + n;
                self.stopHistoryWalk();
                return .consumed;
            },
            else => return .consumed,
        }
    }

    fn closeCmdline(self: *Vim) void {
        self.cmdline_open = false;
        self.cmdline.clearRetainingCapacity();
        self.cmdline_cursor = 0;
        self.stopHistoryWalk();
    }

    fn stopHistoryWalk(self: *Vim) void {
        self.ex_history_cursor = null;
        if (self.ex_history_typing) |t| self.gpa.free(t);
        self.ex_history_typing = null;
    }

    fn setLine(self: *Vim, text: []const u8) Allocator.Error!void {
        // `text` may alias a history entry; copy through a temp.
        const tmp = try self.gpa.dupe(u8, text);
        defer self.gpa.free(tmp);
        self.cmdline.clearRetainingCapacity();
        try self.cmdline.appendSlice(self.gpa, tmp);
        self.cmdline_cursor = tmp.len;
    }

    fn pushHistory(self: *Vim, line: []const u8) Allocator.Error!void {
        if (self.ex_history.items.len > 0 and std.mem.eql(u8, self.ex_history.items[self.ex_history.items.len - 1], line)) return;
        const copy = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(copy);
        try self.ex_history.append(self.gpa, copy);
        while (self.ex_history.items.len > ex_history_max) self.gpa.free(self.ex_history.orderedRemove(0));
    }

    // ─── insert / replace ───

    fn handleInsert(self: *Vim, key: Key, arena: Allocator) Allocator.Error!InputResult {
        const ctrl = key.mods.ctrl;
        if (self.insert_literal_next) {
            self.insert_literal_next = false;
            return switch (key.code) {
                .char => |c| ops(arena, &.{.{ .insert_char = c }}),
                .tab => ops(arena, &.{.{ .insert_char = '\t' }}),
                .enter => ops(arena, &.{.{ .insert_char = '\n' }}),
                else => .consumed,
            };
        }
        if (modifiedMotion(key)) |m| return ops(arena, &.{m});
        if (self.insert_waiting_for_register) {
            self.insert_waiting_for_register = false;
            if (charOf(key)) |c| {
                if (ctrl and c == 'w') return runCmd(.@"editor.insert_word_under_cursor");
                if (ctrl and c == 'a') return runCmd(.@"editor.insert_bigword_under_cursor");
                switch (c) {
                    '%' => return runCmd(.@"editor.insert_current_filename"),
                    '#' => return runCmd(.@"editor.insert_alt_filename"),
                    '/' => return runCmd(.@"editor.insert_last_search"),
                    ':' => return runCmd(.@"editor.insert_last_cmdline"),
                    '.' => return runCmd(.@"editor.insert_last_inserted"),
                    else => {},
                }
                const valid = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '+' or c == '*' or c == '_' or c == '-' or c == '"';
                if (valid) return ops(arena, &.{ .{ .set_register_hint = c }, .paste });
            }
            return .consumed;
        }
        if (ctrl) {
            const c = charOf(key) orelse return .ignored;
            switch (std.ascii.toLower(@intCast(@min(c, 0x7F)))) {
                'r' => {
                    self.insert_waiting_for_register = true;
                    return .consumed;
                },
                'o' => {
                    self.vmode = .normal;
                    self.insert_oneshot_normal = true;
                    return .consumed;
                },
                'n' => return runCmd(.@"editor.keyword_complete"),
                'p' => return runCmd(.@"editor.keyword_complete_back"),
                'f' => return runCmd(.@"picker.files"),
                'y' => return ops(arena, &.{.{ .insert_char_from_line = .{ .above = true } }}),
                'e' => return ops(arena, &.{.{ .insert_char_from_line = .{ .above = false } }}),
                'c' => {
                    self.enterNormal();
                    return .consumed;
                },
                '[' => {
                    self.enterNormal();
                    return ops(arena, &.{.move_left});
                },
                'w' => return ops(arena, &.{.delete_word_left}),
                'u' => return ops(arena, &.{.delete_to_line_start}),
                'h' => return ops(arena, &.{.backspace}),
                't' => return ops(arena, &.{.indent}),
                'd' => return ops(arena, &.{.outdent}),
                'v', 'q' => {
                    self.insert_literal_next = true;
                    return .consumed;
                },
                'j' => return ops(arena, &.{.insert_newline}),
                else => return .ignored,
            }
        }
        return switch (key.code) {
            .esc => blk: {
                self.enterNormal();
                break :blk ops(arena, &.{.move_left});
            },
            .char => |c| if (key.mods.alt or key.mods.super) .ignored else ops(arena, &.{.{ .insert_char = c }}),
            .enter => ops(arena, &.{.insert_newline}),
            .tab => ops(arena, &.{.{ .insert_str = try self.tabText(arena) }}),
            .backspace => ops(arena, &.{.backspace}),
            .delete => ops(arena, &.{.delete_forward}),
            .left => ops(arena, &.{.move_left}),
            .right => ops(arena, &.{.move_right}),
            .up => ops(arena, &.{.move_up}),
            .down => ops(arena, &.{.move_down}),
            .home => ops(arena, &.{.move_line_start}),
            .end => ops(arena, &.{.move_line_end}),
            else => .ignored,
        };
    }

    fn handleReplace(self: *Vim, key: Key, arena: Allocator) Allocator.Error!InputResult {
        if (modifiedMotion(key)) |m| return ops(arena, &.{m});
        if (isCtrlChar(key, 'c')) {
            self.enterNormal();
            return .consumed;
        }
        return switch (key.code) {
            .esc => blk: {
                self.enterNormal();
                break :blk ops(arena, &.{.move_left});
            },
            .char => |c| if (key.mods.ctrl or key.mods.alt or key.mods.super) .ignored else ops(arena, &.{.{ .overwrite_char_and_advance = c }}),
            .enter => ops(arena, &.{.insert_newline}),
            .tab => ops(arena, &.{.{ .insert_str = try self.tabText(arena) }}),
            .backspace => ops(arena, &.{.replace_undo_one}),
            .delete => ops(arena, &.{.delete_forward}),
            .left => ops(arena, &.{.move_left}),
            .right => ops(arena, &.{.move_right}),
            .up => ops(arena, &.{.move_up}),
            .down => ops(arena, &.{.move_down}),
            .home => ops(arena, &.{.move_line_start}),
            .end => ops(arena, &.{.move_line_end}),
            else => .ignored,
        };
    }

    // ─── normal ───

    /// The op list an operator appends after its range is selected.
    /// `linewise_object` = `ip`/`ap` (yank stays linewise).
    fn finishOperator(self: *Vim, b: *Builder, op: PendingOp, ctx: EditCtx, linewise_object: bool) Allocator.Error!InputResult {
        switch (op) {
            .delete => try b.push(.delete_selection),
            .yank => {
                try b.push(if (linewise_object) .yank_selection_linewise else .yank_selection);
                try b.push(.select_clear);
                try b.push(.{ .set_cursor_byte = ctx.cursor });
            },
            .change => {
                try b.push(.{ .replace_selection = "" });
                try b.push(.continue_insert_run);
                self.vmode = .insert;
            },
            .indent => {
                try b.push(.indent);
                try b.push(.select_clear);
            },
            .outdent => {
                try b.push(.outdent);
                try b.push(.select_clear);
            },
            .reflow => {
                b.list.clearRetainingCapacity();
                try b.push(.{ .reflow_paragraph = .{ .width = self.text_width } });
            },
            .lower => {
                try b.push(.{ .transform_selection_case = .lower });
                try b.push(.select_clear);
            },
            .upper => {
                try b.push(.{ .transform_selection_case = .upper });
                try b.push(.select_clear);
            },
            .toggle_case => {
                try b.push(.{ .transform_selection_case = .toggle });
                try b.push(.select_clear);
            },
            .comment => {
                try b.push(.toggle_line_comment);
                try b.push(.select_clear);
            },
            .surround_add => {
                // The range goes live now; the surround char closes it.
                self.prefix = .surround_add_char_wait;
            },
            .@"align" => {
                self.prefix = .align_char_wait;
            },
            .filter => return .consumed, // TODO(vim-slice: filter) `!{motion}`
        }
        return b.finish();
    }

    fn textObjectOp(key: Key, around: bool) ?EditOp {
        const c = charOf(key) orelse return null;
        return switch (c) {
            'w' => if (around) .select_around_word else .select_inner_word,
            'W' => if (around) .select_around_big_word else .select_inner_big_word,
            '"', '\'', '`' => if (around) .{ .select_around_quote = c } else .{ .select_inner_quote = c },
            'q' => if (around) .select_around_smart_quote else .select_inner_smart_quote,
            'p' => if (around) .select_around_paragraph else .select_inner_paragraph,
            'f' => if (around) .select_around_function else .select_inner_function,
            'c' => if (around) .select_around_class else .select_inner_class,
            'a', ',' => if (around) .select_around_argument else .select_inner_argument,
            'i' => if (around) .select_around_indent_block else .select_inner_indent_block,
            'I' => if (around) .select_outer_indent_block else null,
            't' => if (around) .select_around_tag else .select_inner_tag,
            '(', ')', 'b' => if (around) .{ .select_around_bracket = '(' } else .{ .select_inner_bracket = '(' },
            '[', ']' => if (around) .{ .select_around_bracket = '[' } else .{ .select_inner_bracket = '[' },
            '{', '}', 'B' => if (around) .{ .select_around_bracket = '{' } else .{ .select_inner_bracket = '{' },
            '<', '>' => if (around) .{ .select_around_bracket = '<' } else .{ .select_inner_bracket = '<' },
            else => null,
        };
    }

    fn handleNormal(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const ctrl = key.mods.ctrl;
        const ch = charOf(key);

        // ── prefix states ──
        switch (self.prefix) {
            .none => {},
            .replace => {
                const n = self.count1();
                self.resetPending();
                const c = ch orelse return .consumed;
                var b = Builder.init(arena);
                for (0..n) |i| {
                    try b.push(.{ .replace_char_at_cursor = c });
                    if (i + 1 < n) try b.push(.move_right);
                }
                return b.finish();
            },
            .z => {
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    'Z' => .{ .app = .{ .ex_command = "x" } },
                    'Q' => .{ .app = .{ .ex_command = "q!" } },
                    else => .consumed,
                };
            },
            .block_replace_char => {
                self.resetPending();
                const c = ch orelse return .consumed;
                self.enterNormal();
                return .{ .app = .{ .block_replace_with = .{ .ch = c } } };
            },
            .z_fold => {
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    'a', 'A', 'f' => runCmd(.@"editor.toggle_fold"),
                    'o', 'O' => runCmd(.@"editor.open_fold"),
                    'c', 'C' => runCmd(.@"editor.close_fold"),
                    'R', 'E' => runCmd(.@"editor.unfold_all"),
                    'M' => runCmd(.@"editor.fold_all_brackets"),
                    'z' => runCmd(.@"view.cursor_to_center"),
                    't' => runCmd(.@"view.cursor_to_top"),
                    'b' => runCmd(.@"view.cursor_to_bottom"),
                    'h' => runCmd(.@"view.hscroll_left"),
                    'l' => runCmd(.@"view.hscroll_right"),
                    'j' => runCmd(.@"editor.fold_next"),
                    'k' => runCmd(.@"editor.fold_prev"),
                    else => .consumed,
                };
            },
            .g => return self.handleGPrefix(key, ctx, arena),
            .gc => {
                if (ch == 'c') {
                    const n = self.count1();
                    self.resetPending();
                    return repeated(arena, .toggle_line_comment, n);
                }
                if (ch == 'i' or ch == 'a') {
                    self.op = .comment;
                    self.prefix = if (ch == 'i') .text_object_inner else .text_object_around;
                    return .consumed;
                }
                self.resetPending();
                if (motion(key.code)) |m| return ops(arena, &.{ .select_start, m, .toggle_line_comment, .select_clear });
                return .consumed;
            },
            .gq => {
                // The reflow is paragraph-shaped whatever the range
                // (Rust parity), so any motion or object lands the same op.
                self.resetPending();
                if (ch == 'i' or ch == 'a') {
                    self.op = .reflow;
                    self.prefix = if (ch == 'i') .text_object_inner else .text_object_around;
                    return .consumed;
                }
                if (ch == 'q' or motion(key.code) != null) return ops(arena, &.{.{ .reflow_paragraph = .{ .width = self.text_width } }});
                return .consumed;
            },
            .mark_set => {
                self.resetPending();
                if (asciiLetter(ch)) |c| return .{ .app = .{ .set_mark = c } };
                return .consumed;
            },
            .mark_jump_line => {
                self.resetPending();
                if (asciiLetter(ch)) |c| return .{ .app = .{ .jump_to_mark_line = c } };
                if (ch == '\'') return runCmd(.@"nav.jump_toggle_prev");
                return .consumed;
            },
            .mark_jump_exact => {
                self.resetPending();
                if (asciiLetter(ch)) |c| return .{ .app = .{ .jump_to_mark_exact = c } };
                if (ch == '`') return runCmd(.@"nav.jump_toggle_prev");
                return .consumed;
            },
            .find_char => |f| {
                const op = self.op;
                const n = self.count1();
                self.resetPending();
                const c = ch orelse return .consumed;
                const inclusive = op != null;
                self.last_find_char = .{ .ch = c, .forward = f.forward, .before = f.before };
                var b = Builder.init(arena);
                if (op != null) try b.push(.select_start);
                try b.push(.{ .find_char_on_line = .{ .ch = c, .forward = f.forward, .before = f.before, .inclusive = inclusive, .repeat = false } });
                for (1..n) |_| try b.push(.{ .find_char_on_line = .{ .ch = c, .forward = f.forward, .before = f.before, .inclusive = inclusive, .repeat = true } });
                if (op) |o| return self.finishOperator(&b, o, ctx, false);
                return b.finish();
            },
            .text_object_inner, .text_object_around => {
                const around = self.prefix == .text_object_around;
                const op = self.op orelse {
                    self.resetPending();
                    return .consumed;
                };
                self.resetPending();
                const select_op = textObjectOp(key, around) orelse return .consumed;
                if (op == .filter) {
                    if (ch == 'p') return .{ .app = .{ .filter_paragraph_from_cursor = .{ .around = around } } };
                    return .consumed;
                }
                const linewise = select_op == .select_inner_paragraph or select_op == .select_around_paragraph;
                var b = Builder.init(arena);
                try b.push(select_op);
                return self.finishOperator(&b, op, ctx, linewise);
            },
            .bracket_open => {
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    'c' => runCmd(.@"git.jump_prev_change"),
                    'd' => runCmd(.@"lsp.prev_diagnostic"),
                    'q' => runCmd(.@"qf.prev"),
                    't' => runCmd(.@"project.prev_todo"),
                    '[' => runCmd(.@"editor.section_prev_start"),
                    ']' => runCmd(.@"editor.section_prev_end"),
                    'm' => runCmd(.@"editor.method_prev"),
                    else => .consumed,
                };
            },
            .bracket_close => {
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    'c' => runCmd(.@"git.jump_next_change"),
                    'd' => runCmd(.@"lsp.next_diagnostic"),
                    'q' => runCmd(.@"qf.next"),
                    't' => runCmd(.@"project.next_todo"),
                    ']' => runCmd(.@"editor.section_next_start"),
                    '[' => runCmd(.@"editor.section_next_end"),
                    'm' => runCmd(.@"editor.method_next"),
                    else => .consumed,
                };
            },
            .register => {
                self.prefix = .none;
                if (ch) |c| {
                    const valid = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '+' or c == '*' or c == '_' or c == '-';
                    if (valid) self.pending_register = c;
                }
                return .consumed;
            },
            .macro_record_target => {
                self.prefix = .none;
                const c = ch orelse return .consumed;
                if (c == ':') return runCmd(.@"view.cmdline_history");
                if (c == 'q') {
                    self.is_recording_macro = true;
                    return .{ .app = .{ .macro_record_into = '@' } };
                }
                if (c >= 'a' and c <= 'z') {
                    self.is_recording_macro = true;
                    return .{ .app = .{ .macro_record_into = @intCast(c) } };
                }
                return .consumed;
            },
            .macro_replay_target => {
                self.prefix = .none;
                const count = self.count1();
                self.count = null;
                const c = ch orelse return .consumed;
                if (c == '@') return .{ .app = .{ .macro_replay_from = .{ .reg = '@', .count = count } } };
                if (c >= 'a' and c <= 'z') return .{ .app = .{ .macro_replay_from = .{ .reg = @intCast(c), .count = count } } };
                if (c == ':') return runCmd(.@"vim.replay_last_ex");
                return .consumed;
            },
            .window => {
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    'w' => runCmd(.@"view.focus_next_split"),
                    'q', 'c' => runCmd(.@"view.close_split"),
                    's' => runCmd(.@"view.split_down"),
                    'v' => runCmd(.@"view.split_right"),
                    'o' => runCmd(.@"view.only"),
                    'h' => runCmd(.@"view.focus_left"),
                    'j' => runCmd(.@"view.focus_down"),
                    'k' => runCmd(.@"view.focus_up"),
                    'l' => runCmd(.@"view.focus_right"),
                    'H' => runCmd(.@"view.move_split_left"),
                    'J' => runCmd(.@"view.move_split_down"),
                    'K' => runCmd(.@"view.move_split_up"),
                    'L' => runCmd(.@"view.move_split_right"),
                    '=' => runCmd(.@"view.equalize_splits"),
                    'r' => runCmd(.@"view.rotate_splits"),
                    '_' => runCmd(.@"view.maximize_height"),
                    '|' => runCmd(.@"view.maximize_width"),
                    '+' => runCmd(.@"view.split_grow_height"),
                    '-' => runCmd(.@"view.split_shrink_height"),
                    '>' => runCmd(.@"view.split_grow_width"),
                    '<' => runCmd(.@"view.split_shrink_width"),
                    'n' => runCmd(.@"view.split_new_scratch"),
                    'd' => runCmd(.@"view.split_goto_definition"),
                    'f' => runCmd(.@"view.split_open_file_under_cursor"),
                    // TODO(vim-slice: splits) `T` (view.move_to_new_tab) once it has a runner
                    else => .consumed,
                };
            },
            .surround_delete => {
                self.resetPending();
                const c = ch orelse return .consumed;
                if (!surround.isSurroundChar(c)) return .consumed;
                return ops(arena, &.{.{ .delete_surround = c }});
            },
            .surround_change => |from| {
                const c = ch orelse {
                    self.resetPending();
                    return .consumed;
                };
                if (from == 0) {
                    if (surround.isSurroundChar(c)) self.prefix = .{ .surround_change = c } else self.resetPending();
                    return .consumed;
                }
                self.resetPending();
                if (!surround.isSurroundChar(c)) return .consumed;
                return ops(arena, &.{.{ .change_surround = .{ .from = from, .to = c } }});
            },
            .surround_add_char_wait => {
                // The selection is live; a pair char wraps it, anything
                // else (Esc, `t`, a stray key) drops it and parks the
                // cursor back at the range start.
                self.resetPending();
                const p = surround.pairFor(ch orelse 0) orelse return ops(arena, &.{ .move_cursor_to_selection_start, .select_clear });
                return ops(arena, &.{ .{ .surround_selection = .{ .open = p.open, .close = p.close, .pad = p.pad } }, .select_clear });
            },
            .flash1 => {
                self.prefix = .none;
                const c = ch orelse return .consumed;
                self.prefix = .{ .flash2 = c };
                return .consumed;
            },
            .flash2 => |a| {
                self.resetPending();
                const c = ch orelse return .consumed;
                return .{ .app = .{ .flash_start = .{ .a = a, .b = c } } };
            },
            .align_char_wait => {
                // The range is live; a cancel parks the cursor at its start.
                self.resetPending();
                const c = ch orelse return ops(arena, &.{ .move_cursor_to_selection_start, .select_clear });
                return ops(arena, &.{ .{ .align_selection = .{ .on_char = c } }, .select_clear });
            },
        }

        // ── operator pending ──
        if (self.op) |op| return self.handleOperatorPending(op, key, ctx, arena);

        // ── count ──
        if (ch) |c| {
            if (c >= '0' and c <= '9' and !(c == '0' and self.count == null) and !ctrl) {
                self.pushDigit(c - '0');
                return .consumed;
            }
        }
        if (ch == 'G' and !ctrl) {
            if (self.count) |n| {
                self.resetPending();
                return ops(arena, &.{.{ .move_to_line = n }});
            }
        }
        if (modifiedMotion(key)) |m| {
            const n = self.count1();
            self.resetPending();
            return repeated(arena, m, n);
        }
        if (!ctrl) {
            if (motion(key.code)) |m| {
                const n = self.count1();
                self.resetPending();
                return repeated(arena, m, n);
            }
        }

        const n = self.count1();
        switch (key.code) {
            .esc => {
                self.resetPending();
                return runCmd(.@"find.clear_and_deselect");
            },
            .tab => {
                self.resetPending();
                if (key.mods.shift) return runCmd(.@"buffer.prev");
                if (ctrl) return runCmd(.@"nav.forward");
                return runCmd(.@"buffer.next");
            },
            .backtab => {
                self.resetPending();
                return runCmd(.@"buffer.prev");
            },
            .char => |c| {
                if (ctrl) {
                    self.resetPending();
                    return switch (std.ascii.toLower(@intCast(@min(c, 0x7F)))) {
                        'l' => runCmd(.@"view.redraw"),
                        'g' => runCmd(.@"editor.file_info"),
                        'z' => runCmd(.@"editor.suspend_hint"),
                        ']' => runCmd(.@"lsp.goto_definition"),
                        't', 'o' => runCmd(.@"nav.back"),
                        'i' => runCmd(.@"nav.forward"),
                        'h' => ops(arena, &.{.move_left}),
                        'a' => ops(arena, &.{.{ .change_number_at_cursor = .{ .delta = @intCast(n) } }}),
                        'x' => ops(arena, &.{.{ .change_number_at_cursor = .{ .delta = -@as(i64, @intCast(n)) } }}),
                        'e' => runCmd(.@"view.scroll_buffer_down"),
                        'y' => runCmd(.@"view.scroll_buffer_up"),
                        'r' => repeated(arena, .redo, n),
                        'w' => blk: {
                            self.prefix = .window;
                            break :blk .consumed;
                        },
                        '^', '6' => runCmd(.@"buffer.last"),
                        'd' => ops(arena, &.{.half_page_down}),
                        'u' => ops(arena, &.{.half_page_up}),
                        'f' => ops(arena, &.{.page_down}),
                        'b' => ops(arena, &.{.page_up}),
                        'v' => blk: {
                            self.vmode = .visual_block;
                            break :blk ops(arena, &.{.block_select_start});
                        },
                        '/' => ops(arena, &.{.toggle_line_comment}),
                        else => .ignored,
                    };
                }
                switch (c) {
                    'K' => {
                        self.resetPending();
                        return runCmd(.@"lsp.hover");
                    },
                    'H' => {
                        self.resetPending();
                        return runCmd(.@"view.move_cursor_view_top");
                    },
                    'M' => {
                        self.resetPending();
                        return runCmd(.@"view.move_cursor_view_middle");
                    },
                    'L' => {
                        self.resetPending();
                        return runCmd(.@"view.move_cursor_view_bottom");
                    },
                    'i' => {
                        self.enterInsert();
                        return .consumed;
                    },
                    'I' => {
                        self.enterInsert();
                        return ops(arena, &.{.move_line_first_non_ws});
                    },
                    'a' => {
                        self.enterInsert();
                        return ops(arena, &.{.move_right});
                    },
                    'A' => {
                        self.enterInsert();
                        return ops(arena, &.{.move_line_end});
                    },
                    'o', 'O' => {
                        self.resetPending();
                        const above = c == 'O';
                        if (n > 1) return .{ .app = .{ .repeat_insert_start = .{ .count = n, .above = above } } };
                        self.enterInsert();
                        return ops(arena, &.{if (above) .insert_newline_above else .insert_newline_below});
                    },
                    'x', 'X' => {
                        // `x` is `dl`, `X` is `dh`: a real delete, so the
                        // text lands in the unnamed and `"-` registers
                        // and `xp` swaps two chars. Nothing to take on an
                        // empty line / at the line start.
                        self.resetPending();
                        if (c == 'x' and ctx.line_len == 0) return ops(arena, &.{});
                        if (c == 'X' and ctx.at_line_start) return ops(arena, &.{});
                        const step: EditOp = if (c == 'x') .move_right_no_cross_line else .move_left_no_cross_line;
                        var b = Builder.init(arena);
                        try b.push(.select_start);
                        try b.pushRepeated(step, n);
                        try b.push(.delete_selection);
                        return b.finish();
                    },
                    'D' => {
                        self.resetPending();
                        return ops(arena, &.{.delete_to_line_end});
                    },
                    'C' => {
                        self.enterInsert();
                        return ops(arena, &.{.delete_to_line_end});
                    },
                    's' => {
                        self.resetPending();
                        self.prefix = .flash1;
                        return .consumed;
                    },
                    'S' => {
                        self.enterInsert();
                        var b = Builder.init(arena);
                        try b.push(.move_line_end);
                        try b.push(.select_line);
                        for (1..n) |_| {
                            try b.push(.move_down);
                            try b.push(.move_line_end);
                        }
                        try b.push(.{ .replace_selection = "" });
                        try b.push(.continue_insert_run);
                        return b.finish();
                    },
                    'q' => {
                        if (self.is_recording_macro) {
                            self.is_recording_macro = false;
                            return .{ .app = .{ .macro_record_into = '@' } };
                        }
                        self.prefix = .macro_record_target;
                        return .consumed;
                    },
                    'Q' => {
                        const count = self.count1();
                        self.count = null;
                        return .{ .app = .{ .macro_replay_from = .{ .reg = '@', .count = count } } };
                    },
                    '@' => {
                        self.prefix = .macro_replay_target;
                        return .consumed;
                    },
                    ';', ',' => {
                        self.resetPending();
                        const f = self.last_find_char orelse return .consumed;
                        const forward = if (c == ';') f.forward else !f.forward;
                        return repeated(arena, .{ .find_char_on_line = .{ .ch = f.ch, .forward = forward, .before = f.before, .inclusive = false, .repeat = true } }, n);
                    },
                    '[' => {
                        self.prefix = .bracket_open;
                        return .consumed;
                    },
                    ']' => {
                        self.prefix = .bracket_close;
                        return .consumed;
                    },
                    '"' => {
                        self.prefix = .register;
                        return .consumed;
                    },
                    '~' => {
                        self.resetPending();
                        return repeated(arena, .toggle_case_char, n);
                    },
                    '.' => {
                        // A count replaces the last change's count
                        // (`:help .`); 0 = repeat as recorded.
                        const explicit = self.count orelse 0;
                        self.resetPending();
                        return .{ .app = .{ .dot_repeat = explicit } };
                    },
                    '&' => {
                        self.resetPending();
                        return runCmd(.@"editor.repeat_last_substitute");
                    },
                    'r' => {
                        self.prefix = .replace;
                        return .consumed;
                    },
                    'R' => {
                        self.vmode = .replace;
                        self.resetPending();
                        return ops(arena, &.{.replace_session_begin});
                    },
                    'J' => {
                        self.resetPending();
                        const times = @max(n -| 1, 1);
                        return repeated(arena, .{ .join_lines = .{ .keep_space = true } }, times);
                    },
                    'Y' => {
                        self.resetPending();
                        if (ctx.line_len == 0) return ops(arena, &.{});
                        return ops(arena, &.{ .select_start, .move_line_last_char, .move_right, .yank_selection, .select_clear, .{ .set_cursor_byte = ctx.cursor } });
                    },
                    'p' => {
                        self.resetPending();
                        return repeated(arena, .paste_after, n);
                    },
                    'P' => {
                        self.resetPending();
                        return repeated(arena, .paste_before, n);
                    },
                    'u' => {
                        self.resetPending();
                        return repeated(arena, .undo, n);
                    },
                    'd', 'c', 'y', '>', '<', '!' => {
                        self.op = switch (c) {
                            'd' => .delete,
                            'c' => .change,
                            'y' => .yank,
                            '>' => .indent,
                            '<' => .outdent,
                            else => .filter,
                        };
                        self.count = if (n > 1) n else null;
                        return .consumed;
                    },
                    'g' => {
                        self.prefix = .g;
                        self.count = if (n > 1) n else null;
                        return .consumed;
                    },
                    'Z' => {
                        self.prefix = .z;
                        return .consumed;
                    },
                    'z' => {
                        self.prefix = .z_fold;
                        return .consumed;
                    },
                    '|' => {
                        self.resetPending();
                        return ops(arena, &.{.{ .move_to_col = n }});
                    },
                    '%' => {
                        const pct = self.count;
                        self.resetPending();
                        if (pct) |p| {
                            const clamped: usize = @min(@max(p, 1), 100);
                            const lc = @max(ctx.line_count, 1);
                            const target = @max(@min((clamped * lc + 99) / 100, lc), 1);
                            return ops(arena, &.{.{ .move_to_line = target }});
                        }
                        return runCmd(.@"editor.bracket_match");
                    },
                    '*' => {
                        self.resetPending();
                        self.last_search_backward = false;
                        return runCmd(.@"find.word_forward");
                    },
                    '#' => {
                        self.resetPending();
                        self.last_search_backward = true;
                        return runCmd(.@"find.word_backward");
                    },
                    'n' => {
                        self.resetPending();
                        return runCmd(if (self.last_search_backward) .@"find.prev" else .@"find.next");
                    },
                    'N' => {
                        self.resetPending();
                        return runCmd(if (self.last_search_backward) .@"find.next" else .@"find.prev");
                    },
                    'f', 'F', 't', 'T' => {
                        self.prefix = .{ .find_char = .{ .forward = c == 'f' or c == 't', .before = c == 't' or c == 'T' } };
                        return .consumed;
                    },
                    'm' => {
                        self.prefix = .mark_set;
                        return .consumed;
                    },
                    '\'' => {
                        self.prefix = .mark_jump_line;
                        return .consumed;
                    },
                    '`' => {
                        self.prefix = .mark_jump_exact;
                        return .consumed;
                    },
                    'v' => {
                        self.vmode = .visual;
                        self.resetPending();
                        return ops(arena, &.{.select_start});
                    },
                    'V' => {
                        self.vmode = .visual_line;
                        self.resetPending();
                        return ops(arena, &.{.select_line});
                    },
                    ' ' => {
                        self.resetPending();
                        return runCmd(.@"whichkey.leader");
                    },
                    ':' => {
                        self.resetPending();
                        try self.openCmdline("");
                        return .consumed;
                    },
                    '/' => {
                        self.resetPending();
                        self.last_search_backward = false;
                        return runCmd(.@"find.find");
                    },
                    '?' => {
                        self.resetPending();
                        self.last_search_backward = true;
                        return runCmd(.@"find.find_backward");
                    },
                    else => {
                        self.resetPending();
                        return .ignored;
                    },
                }
            },
            else => {
                self.resetPending();
                return .ignored;
            },
        }
    }

    fn handleGPrefix(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const n = self.count1();
        const count_explicit = self.count != null;
        const pending_op = self.op;
        self.resetPending();
        const c = charOf(key) orelse return .consumed;
        if (key.mods.ctrl and c == 'g') return runCmd(.@"editor.file_stats");
        switch (c) {
            'g' => {
                if (pending_op) |op| {
                    if (op == .delete or op == .yank) {
                        const target: ?u32 = if (count_explicit) n else 0;
                        return .{ .app = .{ .operator_linewise_to = .{ .op = if (op == .delete) 'd' else 'y', .target = target } } };
                    }
                }
                if (count_explicit) return ops(arena, &.{.{ .move_to_line = n }});
                return ops(arena, &.{.move_buffer_start});
            },
            'd' => return runCmd(.@"lsp.goto_definition"),
            'D' => return runCmd(.@"lsp.goto_declaration"),
            'r' => return runCmd(.@"lsp.references"),
            'f' => return runCmd(.@"editor.open_at_cursor"),
            'x' => return runCmd(.@"editor.open_url_at_cursor"),
            'i' => return runCmd(.@"vim.go_to_last_insert"),
            'I' => {
                self.enterInsert();
                return ops(arena, &.{.move_line_start});
            },
            'c' => {
                self.prefix = .gc;
                self.count = if (n > 1) n else null;
                return .consumed;
            },
            'q' => {
                self.prefix = .gq;
                return .consumed;
            },
            'v' => {
                self.vmode = .visual;
                // The remembered range was already widened when it closed.
                self.visual_exact = true;
                return ops(arena, &.{.restore_last_selection});
            },
            ';' => return runCmd(.@"editor.jump_prev_edit"),
            ',' => return runCmd(.@"editor.jump_next_edit"),
            'J' => return repeated(arena, .{ .join_lines = .{ .keep_space = false } }, @max(n -| 1, 1)),
            '_' => return ops(arena, &.{.move_line_last_non_ws}),
            'e' => return repeated(arena, .move_word_end_back, n),
            'E' => return repeated(arena, .move_big_word_end_back, n),
            '0' => return ops(arena, &.{if (ctx.wrap_width) |w| .{ .move_visual_line_start = w } else .move_line_start}),
            '^' => return ops(arena, &.{.move_line_first_non_ws}),
            '$' => return ops(arena, &.{if (ctx.wrap_width) |w| .{ .move_visual_line_end = w } else .move_line_end}),
            'j' => return repeated(arena, if (ctx.wrap_width) |w| .{ .move_visual_down = w } else .move_down, n),
            'k' => return repeated(arena, if (ctx.wrap_width) |w| .{ .move_visual_up = w } else .move_up, n),
            'u', 'U', '~' => {
                self.op = switch (c) {
                    'u' => .lower,
                    'U' => .upper,
                    else => .toggle_case,
                };
                if (count_explicit) self.count = n;
                return .consumed;
            },
            'p' => return repeated(arena, .paste_after_end, n),
            'P' => return repeated(arena, .paste_before_end, n),
            '*' => {
                self.last_search_backward = false;
                return runCmd(.@"find.word_forward");
            },
            '#' => {
                self.last_search_backward = true;
                return runCmd(.@"find.word_backward");
            },
            't' => {
                if (count_explicit) return .{ .app = .{ .tab_page = .{ .count = n, .back = false } } };
                return runCmd(.@"tab.next");
            },
            'T' => {
                if (count_explicit) return .{ .app = .{ .tab_page = .{ .count = n, .back = true } } };
                return runCmd(.@"tab.prev");
            },
            'n', 'N' => {
                const forward = c == 'n';
                const range = if (forward) ctx.next_find_match else ctx.prev_find_match;
                if (pending_op) |op| {
                    const r = range orelse return runCmd(if (forward) .@"find.select_match_forward" else .@"find.select_match_backward");
                    var b = Builder.init(arena);
                    try b.push(.{ .set_cursor_byte = r[0] });
                    try b.push(.select_start);
                    try b.push(.{ .set_cursor_byte = r[1] });
                    return self.finishOperator(&b, op, ctx, false);
                }
                const r = range orelse return runCmd(if (forward) .@"find.select_match_forward" else .@"find.select_match_backward");
                self.vmode = .visual;
                return ops(arena, &.{ .{ .set_cursor_byte = r[0] }, .select_start, .{ .set_cursor_byte = r[1] } });
            },
            'a' => return runCmd(.@"editor.char_info"),
            '8' => return runCmd(.@"editor.char_utf8"),
            'A' => {
                self.op = .@"align";
                return .consumed;
            },
            else => return .consumed,
        }
    }

    fn handleOperatorPending(self: *Vim, op: PendingOp, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const ch = charOf(key);
        if (ch) |c| {
            if (c >= '0' and c <= '9' and !(c == '0' and self.count == null)) {
                self.pushDigit(c - '0');
                return .consumed;
            }
        }
        const doubled = if (ch) |c| switch (op) {
            .delete => c == 'd',
            .change => c == 'c',
            .yank => c == 'y',
            .indent => c == '>',
            .outdent => c == '<',
            .lower => c == 'u',
            .upper => c == 'U',
            .toggle_case => c == '~',
            .surround_add => c == 's',
            .@"align" => c == 'A',
            .filter => c == '!',
            .reflow, .comment => false,
        } else false;
        const n = self.count1();
        self.resetPending();
        if (key.code == .esc) return .consumed;
        if (doubled) {
            switch (op) {
                .delete => return repeated(arena, .delete_line, n),
                .yank => return ops(arena, &.{.{ .yank_lines_count = n }}),
                .change => {
                    self.vmode = .insert;
                    var b = Builder.init(arena);
                    try b.push(.select_line);
                    try b.push(.move_line_end);
                    for (1..n) |_| {
                        try b.push(.move_down);
                        try b.push(.move_line_end);
                    }
                    try b.push(.{ .replace_selection = "" });
                    try b.push(.continue_insert_run);
                    return b.finish();
                },
                .indent, .outdent => {
                    var b = Builder.init(arena);
                    try b.push(.select_start);
                    for (1..n) |_| try b.push(.move_down);
                    try b.push(.move_line_end);
                    try b.push(if (op == .indent) .indent else .outdent);
                    try b.push(.select_clear);
                    return b.finish();
                },
                .lower, .upper, .toggle_case => {
                    const kind: @import("../editor/edit_op.zig").CaseTransform = switch (op) {
                        .lower => .lower,
                        .upper => .upper,
                        else => .toggle,
                    };
                    return ops(arena, &.{ .select_line, .move_line_end, .{ .transform_selection_case = kind }, .select_clear, .move_down, .move_line_start });
                },
                .filter => return .{ .app = .{ .filter_lines_from_cursor = .{ .count = n } } },
                .reflow => return ops(arena, &.{.{ .reflow_paragraph = .{ .width = self.text_width } }}),
                .comment => return ops(arena, &.{.toggle_line_comment}),
                .surround_add => {
                    // `yss<c>`: the line's content, leading blanks excluded.
                    self.prefix = .surround_add_char_wait;
                    return ops(arena, &.{ .move_line_first_non_ws, .select_start, .move_line_end });
                },
                .@"align" => return .consumed, // `gAA` has no meaning
            }
        }
        if (ch == 's' and (op == .delete or op == .change or op == .yank)) {
            // `ds<c>` / `cs<from><to>` name their pair next; `ys` is an
            // operator of its own and waits for a motion first.
            switch (op) {
                .delete => self.prefix = .surround_delete,
                .change => self.prefix = .{ .surround_change = 0 },
                else => self.op = .surround_add,
            }
            return .consumed;
        }
        if (ch == 'i' or ch == 'a') {
            self.op = op;
            self.prefix = if (ch == 'i') .text_object_inner else .text_object_around;
            if (n > 1) self.count = n;
            return .consumed;
        }
        if (ch == 'g') {
            self.op = op;
            self.prefix = .g;
            if (n > 1) self.count = n;
            return .consumed;
        }
        if (ch == 'G' and (op == .delete or op == .yank)) {
            return .{ .app = .{ .operator_linewise_to = .{ .op = if (op == .delete) 'd' else 'y', .target = if (n > 1) n else null } } };
        }
        if (ch) |c| {
            if (c == 'f' or c == 'F' or c == 't' or c == 'T') {
                self.op = op;
                if (n > 1) self.count = n;
                self.prefix = .{ .find_char = .{ .forward = c == 'f' or c == 't', .before = c == 't' or c == 'T' } };
                return .consumed;
            }
        }
        // `cw` is `ce`-shaped (`:help cw`): the current word's end, even
        // when the cursor is already on it, then `e` for the rest of a
        // count — one op carrying the count so `{count}.` can replace it.
        if (op == .change and (ch == 'w' or ch == 'W')) {
            var b = Builder.init(arena);
            try b.push(.select_start);
            try b.push(if (ch == 'w') .{ .move_word_end_cw = n } else .{ .move_big_word_end_cw = n });
            try b.push(.move_right);
            return self.finishOperator(&b, op, ctx, false);
        }
        const code = key.code;
        const vertical: ?i2 = switch (code) {
            .char => |c| switch (c) {
                'j', '+' => 1,
                'k', '-' => -1,
                else => null,
            },
            .down, .enter => 1,
            .up => -1,
            else => null,
        };
        if (vertical) |dir| {
            const total = n + 1;
            var b = Builder.init(arena);
            // `>j` / `<k`: one line op over a selection spanning the lines
            // (a per-line op without a selection would hit the cursor
            // line every time).
            if (op == .indent or op == .outdent or op == .@"align") {
                try b.push(.select_start);
                for (0..n) |_| try b.push(if (dir < 0) .move_up else .move_down);
                // Park at the last line's end so a selection ending on a
                // line start does not exclude that line.
                try b.push(.move_line_end);
                if (op == .@"align") return self.finishOperator(&b, op, ctx, false);
                try b.push(if (op == .indent) .indent else .outdent);
                try b.push(.select_clear);
                return b.finish();
            }
            if (dir < 0) for (0..n) |_| try b.push(.move_up);
            switch (op) {
                .yank => {
                    try b.push(.{ .yank_lines_count = total });
                    return b.finish();
                },
                .filter => return .{ .app = .{ .filter_lines_from_cursor = .{ .count = total } } },
                .delete, .change => {
                    for (0..total) |_| try b.push(.delete_line);
                    if (op == .change) {
                        try b.push(.insert_newline);
                        try b.push(.move_up);
                        self.vmode = .insert;
                    }
                    return b.finish();
                },
                else => {},
            }
        }
        if (motion(code)) |m0| {
            const m: EditOp = if (n == 1 and (op == .delete or op == .yank)) switch (m0) {
                .move_word_right => .move_word_right_no_cross_line,
                .move_big_word_right => .move_big_word_right_no_cross_line,
                else => m0,
            } else m0;
            const inclusive = switch (code) {
                .char => |c| c == 'e' or c == 'E' or c == '$',
                .end => true,
                else => false,
            };
            const empty_dollar = (code == .end or (code == .char and code.char == '$')) and ctx.line_len == 0;
            if (empty_dollar) {
                if (op == .change) self.vmode = .insert;
                return ops(arena, &.{});
            }
            var b = Builder.init(arena);
            try b.push(.select_start);
            // Always a `repeat`, so `3.` can replace the count of `dw`.
            try b.pushRepeated(m, n);
            if (inclusive) try b.push(.move_right);
            return self.finishOperator(&b, op, ctx, false);
        }
        return .consumed;
    }

    // ─── visual ───

    fn handleVisual(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const linewise = self.vmode == .visual_line;
        const ch = charOf(key);
        switch (self.prefix) {
            .g => {
                self.resetPending();
                const c = ch orelse return .consumed;
                switch (c) {
                    'A' => {
                        // The alignment char arrives next; widen now so
                        // the last line is inside the range.
                        self.prefix = .align_char_wait;
                        return ops(arena, &.{if (linewise) .normalize_linewise_selection else .make_selection_inclusive});
                    },
                    'n', 'N' => {
                        const forward = c == 'n';
                        const r = (if (forward) ctx.next_find_match else ctx.prev_find_match) orelse
                            return runCmd(if (forward) .@"find.select_match_forward" else .@"find.select_match_backward");
                        return ops(arena, &.{.{ .set_cursor_byte = if (forward) r[1] else r[0] }});
                    },
                    else => return .consumed,
                }
            },
            .z_fold => {
                self.resetPending();
                const c = ch orelse return .consumed;
                self.enterNormal();
                return switch (c) {
                    'f' => runCmd(.@"editor.fold_selection"),
                    'a', 'A' => runCmd(.@"editor.toggle_fold"),
                    'o', 'O' => runCmd(.@"editor.open_fold"),
                    'c', 'C' => runCmd(.@"editor.close_fold"),
                    'M' => runCmd(.@"editor.fold_all_brackets"),
                    'R', 'E' => runCmd(.@"editor.unfold_all"),
                    else => .consumed,
                };
            },
            .text_object_inner, .text_object_around => {
                const around = self.prefix == .text_object_around;
                self.resetPending();
                const op = textObjectOp(key, around) orelse return .consumed;
                self.visual_exact = true;
                return ops(arena, &.{op});
            },
            .align_char_wait => {
                self.enterNormal();
                const c = ch orelse return ops(arena, &.{.select_clear});
                return ops(arena, &.{ .{ .align_selection = .{ .on_char = c } }, .select_clear });
            },
            else => {},
        }
        // Whatever comes next either widens the range itself or is a
        // motion that makes the exact object range moot.
        const exact = self.visual_exact;
        self.visual_exact = false;
        const widen: EditOp = if (linewise) .normalize_linewise_selection else if (exact) .remember_selection else .make_selection_inclusive;
        if (ch) |c| {
            if (c >= '1' and c <= '9' or (c == '0' and self.count != null)) {
                self.pushDigit(c - '0');
                return .consumed;
            }
        }
        if (key.mods.ctrl) {
            if (ch) |c| {
                const scroll: ?EditOp = switch (std.ascii.toLower(@intCast(@min(c, 0x7F)))) {
                    'b' => .page_up,
                    'f' => .page_down,
                    'u', 'y' => .half_page_up,
                    'd', 'e' => .half_page_down,
                    else => null,
                };
                if (scroll) |s| {
                    const n = self.count1();
                    self.count = null;
                    return repeated(arena, s, n);
                }
            }
        }
        if (modifiedMotion(key)) |m| {
            const n = self.count1();
            self.count = null;
            return repeated(arena, m, n);
        }
        if (motion(key.code)) |m| {
            const n = self.count1();
            self.count = null;
            return repeated(arena, m, n);
        }
        self.count = null;
        if (key.code == .esc) {
            self.enterNormal();
            return ops(arena, &.{.select_clear});
        }
        const c = ch orelse return .consumed;
        switch (c) {
            'v' => {
                if (linewise) {
                    self.vmode = .visual;
                    return .consumed;
                }
                self.enterNormal();
                return ops(arena, &.{.select_clear});
            },
            'V' => {
                if (linewise) {
                    self.enterNormal();
                    return ops(arena, &.{.select_clear});
                }
                self.vmode = .visual_line;
                return ops(arena, &.{.select_line});
            },
            'i' => {
                self.prefix = .text_object_inner;
                return .consumed;
            },
            'a' => {
                self.prefix = .text_object_around;
                return .consumed;
            },
            'z' => {
                self.prefix = .z_fold;
                return .consumed;
            },
            'd', 'x' => {
                self.enterNormal();
                return ops(arena, &.{ widen, .delete_selection });
            },
            'c', 's' => {
                self.vmode = .insert;
                self.resetPending();
                return ops(arena, &.{ widen, .{ .replace_selection = "" }, .continue_insert_run });
            },
            'y' => {
                self.enterNormal();
                if (linewise) return ops(arena, &.{ .normalize_linewise_selection, .yank_selection_linewise, .move_cursor_to_selection_start, .select_clear });
                return ops(arena, &.{ widen, .yank_selection, .move_cursor_to_selection_start, .select_clear });
            },
            'o' => return ops(arena, &.{.swap_anchor_cursor}),
            '>', '<' => {
                self.enterNormal();
                const op: EditOp = if (c == '>') .indent else .outdent;
                if (linewise) return ops(arena, &.{ .normalize_linewise_selection, op, .select_clear });
                return ops(arena, &.{ op, .select_clear });
            },
            'g' => {
                self.prefix = .g;
                return .consumed;
            },
            'u', 'U', '~' => {
                const kind: @import("../editor/edit_op.zig").CaseTransform = switch (c) {
                    'u' => .lower,
                    'U' => .upper,
                    else => .toggle,
                };
                self.enterNormal();
                return ops(arena, &.{ widen, .{ .transform_selection_case = kind }, .select_clear });
            },
            'r' => {
                // Widen now; the replace prefix fills the selection next key.
                self.prefix = .replace;
                self.vmode = .normal;
                return ops(arena, &.{widen});
            },
            'J' => {
                self.enterNormal();
                return ops(arena, &.{ .move_cursor_to_selection_start, .select_clear, .{ .join_lines = .{ .keep_space = true } } });
            },
            'p', 'P' => {
                self.enterNormal();
                return ops(arena, &.{ widen, .{ .replace_selection = "" }, .paste_before });
            },
            '*' => {
                self.enterNormal();
                return runCmd(.@"find.selection_forward");
            },
            '#' => {
                self.enterNormal();
                return runCmd(.@"find.selection_backward");
            },
            ':' => {
                try self.openCmdline("'<,'>");
                return ops(arena, &.{.remember_selection});
            },
            'S' => {
                // vim-surround: wrap the selection with the next char.
                self.vmode = .normal;
                self.prefix = .surround_add_char_wait;
                return ops(arena, &.{widen});
            },
            else => return .consumed,
        }
    }

    fn handleVisualBlock(self: *Vim, key: Key, arena: Allocator) Allocator.Error!InputResult {
        const ch = charOf(key);
        if (self.prefix == .block_replace_char) {
            self.prefix = .none;
            const c = ch orelse return .consumed;
            self.enterNormal();
            return .{ .app = .{ .block_replace_with = .{ .ch = c } } };
        }
        if (ch) |c| {
            if (c >= '1' and c <= '9' or (c == '0' and self.count != null)) {
                self.pushDigit(c - '0');
                return .consumed;
            }
        }
        if (modifiedMotion(key) orelse motion(key.code)) |m| {
            const n = self.count1();
            self.count = null;
            // `$` makes the block ragged-right (`:help v_$`); a vertical
            // motion keeps that, any other horizontal one drops it.
            if (m == .move_line_last_char) return ops(arena, &.{ m, .{ .block_eol = true } });
            if (m.preservesGoalCol()) return repeated(arena, m, n);
            var b = Builder.init(arena);
            try b.pushRepeated(m, n);
            try b.push(.{ .block_eol = false });
            return b.finish();
        }
        self.count = null;
        if (key.code == .esc or isCtrlChar(key, 'v')) {
            self.enterNormal();
            return ops(arena, &.{.block_select_clear});
        }
        const c = ch orelse return .consumed;
        switch (c) {
            'v' => {
                self.vmode = .visual;
                return ops(arena, &.{ .block_select_clear, .select_start });
            },
            'V' => {
                self.vmode = .visual_line;
                return ops(arena, &.{ .block_select_clear, .select_line });
            },
            'y' => {
                self.enterNormal();
                return ops(arena, &.{.yank_block});
            },
            'd', 'x' => {
                self.enterNormal();
                return ops(arena, &.{.delete_block});
            },
            'I' => {
                self.enterNormal();
                return .{ .app = .{ .block_insert_start = .{ .append = false } } };
            },
            'A' => {
                self.enterNormal();
                return .{ .app = .{ .block_insert_start = .{ .append = true } } };
            },
            'c', 's' => {
                self.enterNormal();
                return .{ .app = .block_change_start };
            },
            ':' => {
                try self.openCmdline("'<,'>");
                return ops(arena, &.{.remember_selection});
            },
            'r' => {
                self.prefix = .block_replace_char;
                return .consumed;
            },
            else => return .consumed,
        }
    }
};

/// Grows an op list on the frame arena.
const Builder = struct {
    arena: Allocator,
    list: std.ArrayList(EditOp) = .empty,

    fn init(arena: Allocator) Builder {
        return .{ .arena = arena };
    }

    fn push(b: *Builder, op: EditOp) Allocator.Error!void {
        try b.list.append(b.arena, op);
    }

    /// `op` under a `repeat` — always, even for a count of 1, so a
    /// `{count}.` later can find the count to replace.
    fn pushRepeated(b: *Builder, op: EditOp, n: u32) Allocator.Error!void {
        const inner = try b.arena.create(EditOp);
        inner.* = op;
        try b.push(.{ .repeat = .{ .count = n, .inner = inner } });
    }

    fn finish(b: *Builder) InputResult {
        return .{ .ops = b.list.items };
    }
};

fn asciiLetter(c: ?u21) ?u8 {
    const v = c orelse return null;
    if ((v >= 'a' and v <= 'z') or (v >= 'A' and v <= 'Z')) return @intCast(v);
    return null;
}

fn spaces(arena: Allocator, n: usize) Allocator.Error![]const u8 {
    const s = try arena.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

fn appendChar(list: *std.ArrayList(u8), arena: Allocator, c: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return;
    try list.appendSlice(arena, buf[0..n]);
}

fn prevBoundary(s: []const u8, b: usize) usize {
    if (b == 0) return 0;
    var i = @min(b, s.len) - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn nextBoundary(s: []const u8, b: usize) usize {
    if (b >= s.len) return s.len;
    var i = b + 1;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return i;
}

// ─── tests (handler-level; the end-to-end chord tables live in buffer.zig) ──

const testing = std.testing;

test "classifyEx recognises the file verbs and :s" {
    try testing.expectEqual(ExKind.write, classifyEx("w"));
    try testing.expectEqual(ExKind.write, classifyEx("w foo.txt"));
    try testing.expectEqual(ExKind.quit, classifyEx("q!"));
    try testing.expectEqual(ExKind.write_quit, classifyEx("wq"));
    try testing.expectEqual(ExKind.write_quit, classifyEx("x"));
    try testing.expectEqual(ExKind.edit, classifyEx("e other.zig"));
    try testing.expectEqual(ExKind.substitute, classifyEx("%s/a/b/g"));
    try testing.expectEqual(ExKind.substitute, classifyEx("'<,'>s/a/b/"));
    try testing.expectEqual(ExKind.substitute, classifyEx("s/y/W/g"));
    try testing.expectEqual(ExKind.other, classifyEx("sort u"));
    try testing.expectEqual(ExKind.other, classifyEx("set nowrap"));
}

test "cmdline: typing, caret edits, history walk, enter emits ex_command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char(':'), .{}, a);
    try testing.expect(v.isCmdlineOpen());
    for ("wq") |c| _ = try v.handleKey(Key.char(c), .{}, a);
    _ = try v.handleKey(Key.named(.left), .{}, a);
    _ = try v.handleKey(Key.char('!'), .{}, a);
    try testing.expectEqualStrings("w!q", v.cmdlineGet().?);
    try testing.expectEqualStrings(":w!\u{258f}q", (try v.pendingDisplay(a)).?);
    _ = try v.handleKey(Key.named(.end), .{}, a);
    _ = try v.handleKey(Key.named(.backspace), .{}, a);
    _ = try v.handleKey(Key.named(.home), .{}, a);
    _ = try v.handleKey(Key.named(.delete), .{}, a);
    try testing.expectEqualStrings("!", v.cmdlineGet().?);
    _ = try v.handleKey(Key.ctrl('u'), .{}, a);
    for ("wq") |c| _ = try v.handleKey(Key.char(c), .{}, a);
    const r = try v.handleKey(Key.named(.enter), .{}, a);
    try testing.expectEqualStrings("wq", r.app.ex_command);
    try testing.expect(!v.isCmdlineOpen());
    try testing.expectEqual(@as(usize, 1), v.exHistory().len);
    // Walk history: Up recalls, Down restores what was typed.
    _ = try v.handleKey(Key.char(':'), .{}, a);
    _ = try v.handleKey(Key.char('e'), .{}, a);
    _ = try v.handleKey(Key.named(.up), .{}, a);
    try testing.expectEqualStrings("wq", v.cmdlineGet().?);
    _ = try v.handleKey(Key.named(.down), .{}, a);
    try testing.expectEqualStrings("e", v.cmdlineGet().?);
    _ = try v.handleKey(Key.named(.esc), .{}, a);
    try testing.expect(!v.isCmdlineOpen());
    // Duplicate entries collapse; the cap holds.
    var i: usize = 0;
    while (i < ex_history_max + 10) : (i += 1) {
        _ = try v.handleKey(Key.char(':'), .{}, a);
        var buf: [16]u8 = undefined;
        for (try std.fmt.bufPrint(&buf, "n{d}", .{i})) |c| _ = try v.handleKey(Key.char(c), .{}, a);
        _ = try v.handleKey(Key.named(.enter), .{}, a);
    }
    try testing.expectEqual(@as(usize, ex_history_max), v.exHistory().len);
    try v.setExHistory(&.{ "a", "b" });
    try testing.expectEqualStrings("b", v.exHistory()[1]);
}

test "ctrl+w H/J/K/L move the split; = r _ | + - > < n o w h d f reach their runners; T is still pending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    const Case = struct { key: u21, id: CommandId };
    const cases = [_]Case{
        .{ .key = 'H', .id = .@"view.move_split_left" },
        .{ .key = 'J', .id = .@"view.move_split_down" },
        .{ .key = 'K', .id = .@"view.move_split_up" },
        .{ .key = 'L', .id = .@"view.move_split_right" },
        .{ .key = '=', .id = .@"view.equalize_splits" },
        .{ .key = 'r', .id = .@"view.rotate_splits" },
        .{ .key = '_', .id = .@"view.maximize_height" },
        .{ .key = '|', .id = .@"view.maximize_width" },
        .{ .key = '+', .id = .@"view.split_grow_height" },
        .{ .key = '-', .id = .@"view.split_shrink_height" },
        .{ .key = '>', .id = .@"view.split_grow_width" },
        .{ .key = '<', .id = .@"view.split_shrink_width" },
        .{ .key = 'n', .id = .@"view.split_new_scratch" },
        .{ .key = 'o', .id = .@"view.only" },
        .{ .key = 'w', .id = .@"view.focus_next_split" },
        .{ .key = 'h', .id = .@"view.focus_left" },
        .{ .key = 'd', .id = .@"view.split_goto_definition" },
        .{ .key = 'f', .id = .@"view.split_open_file_under_cursor" },
    };
    for (cases) |c| {
        try testing.expect((try v.handleKey(Key.ctrl('w'), .{}, a)) == .consumed);
        const r = try v.handleKey(Key.char(c.key), .{}, a);
        try testing.expect(r == .app);
        try testing.expectEqual(c.id, r.app.run_command);
        try testing.expect(!v.isOpPending());
    }
    // `T` has no runner yet: the prefix is consumed and nothing runs.
    try testing.expect((try v.handleKey(Key.ctrl('w'), .{}, a)) == .consumed);
    try testing.expect((try v.handleKey(Key.char('T'), .{}, a)) == .consumed);
}

test "gt / gT run tab.next / tab.prev; with a count they name the page (3gt) or the distance back (2gT)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char('g'), .{}, a);
    var r = try v.handleKey(Key.char('t'), .{}, a);
    try testing.expectEqual(CommandId.@"tab.next", r.app.run_command);
    _ = try v.handleKey(Key.char('g'), .{}, a);
    r = try v.handleKey(Key.char('T'), .{}, a);
    try testing.expectEqual(CommandId.@"tab.prev", r.app.run_command);
    _ = try v.handleKey(Key.char('3'), .{}, a);
    _ = try v.handleKey(Key.char('g'), .{}, a);
    r = try v.handleKey(Key.char('t'), .{}, a);
    try testing.expectEqual(@as(u32, 3), r.app.tab_page.count);
    try testing.expect(!r.app.tab_page.back);
    _ = try v.handleKey(Key.char('1'), .{}, a);
    _ = try v.handleKey(Key.char('2'), .{}, a);
    _ = try v.handleKey(Key.char('g'), .{}, a);
    r = try v.handleKey(Key.char('T'), .{}, a);
    try testing.expectEqual(@as(u32, 12), r.app.tab_page.count);
    try testing.expect(r.app.tab_page.back);
    // The count is spent: a plain `gt` follows.
    _ = try v.handleKey(Key.char('g'), .{}, a);
    r = try v.handleKey(Key.char('t'), .{}, a);
    try testing.expectEqual(CommandId.@"tab.next", r.app.run_command);
}

test "pending display shows register, count, operator and prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    try testing.expect((try v.pendingDisplay(a)) == null);
    _ = try v.handleKey(Key.char('"'), .{}, a);
    _ = try v.handleKey(Key.char('a'), .{}, a);
    _ = try v.handleKey(Key.char('2'), .{}, a);
    _ = try v.handleKey(Key.char('d'), .{}, a);
    try testing.expect(v.isOpPending());
    try testing.expectEqualStrings("\"a2d", (try v.pendingDisplay(a)).?);
    _ = try v.handleKey(Key.char('i'), .{}, a);
    try testing.expectEqualStrings("\"a2di", (try v.pendingDisplay(a)).?);
    v.onBlur();
    try testing.expect(!v.isOpPending());
    try testing.expect(v.operatorMenuHint() == null);
    _ = try v.handleKey(Key.char('g'), .{}, a);
    try testing.expectEqualStrings("g", v.operatorMenuHint().?.prefix);
}

test "\"* and \"+ route the next yank / put through the OS registers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char('"'), .{}, a);
    _ = try v.handleKey(Key.char('*'), .{}, a);
    _ = try v.handleKey(Key.char('y'), .{}, a);
    const yank = try v.handleKey(Key.char('y'), .{}, a);
    try testing.expectEqualSlices(EditOp, &.{ .{ .set_register_hint = '*' }, .{ .yank_lines_count = 1 } }, yank.ops);
    _ = try v.handleKey(Key.char('"'), .{}, a);
    _ = try v.handleKey(Key.char('+'), .{}, a);
    const put = try v.handleKey(Key.char('p'), .{}, a);
    try testing.expectEqualSlices(EditOp, &.{ .{ .set_register_hint = '+' }, .paste_after }, put.ops);
    // An unknown register name is dropped; the op runs unhinted.
    _ = try v.handleKey(Key.char('"'), .{}, a);
    _ = try v.handleKey(Key.char('!'), .{}, a);
    const plain = try v.handleKey(Key.char('p'), .{}, a);
    try testing.expectEqualSlices(EditOp, &.{.paste_after}, plain.ops);
}
