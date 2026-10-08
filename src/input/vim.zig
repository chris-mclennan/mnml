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
const script_ops = @import("script_ops.zig");

pub const VimMode = enum { normal, insert, replace, visual, visual_line, visual_block };

/// A verb the handler answers itself, typed in `mode`, and the command
/// a menu row or the palette runs for the same act.
pub const OwnKey = struct {
    spec: []const u8,
    command: CommandId,
    /// Where the keys are typed: Cut and Copy act on a Visual selection.
    mode: enum { normal, visual } = .normal,
};

/// The Neovim verbs this handler answers without the keymap that do
/// what an editor command does — so a menu row prints `u` for Undo
/// under the vim profile, not a standard chord (`info_view_copy.chordOf`
/// reads this table before the keymap for the commands it names).
/// Cut is Visual `d` (Visual `x` is the same act; Normal `x` takes one
/// character, not the selection). Select all is `ggVG`: the handler has
/// no one-key verb for it, and those four keys leave the whole buffer in
/// a V-LINE selection. Save is not here: `:w` is an ex command the app
/// runs, not a key the handler answers, and the keymap's `Ctrl+S` is
/// NvChad's own. A test below holds every row to the handler.
pub const own_keys = [_]OwnKey{
    .{ .spec = "u", .command = .@"editor.undo" },
    .{ .spec = "ctrl+r", .command = .@"editor.redo" },
    .{ .spec = "d", .command = .@"editor.cut", .mode = .visual },
    .{ .spec = "y", .command = .@"editor.copy", .mode = .visual },
    .{ .spec = "p", .command = .@"editor.paste" },
    .{ .spec = "g g V G", .command = .@"editor.select_all" },
    .{ .spec = "z a", .command = .@"editor.toggle_fold" },
};

pub const PendingOp = enum {
    delete,
    change,
    yank,
    indent,
    outdent,
    reindent,
    reflow,
    lower,
    upper,
    toggle_case,
    comment,
    surround_add,
    @"align",
    filter,
    /// `zf{motion}`: a manual fold over the range (`:help zf`).
    fold,
    /// `g<letter>{motion}` where a script claimed the letter
    /// (`input/script_ops.zig`); `Vim.script_op` says which.
    script,

    fn glyph(op: PendingOp) []const u8 {
        return switch (op) {
            .fold => "zf",
            .script => "g",
            .delete => "d",
            .change => "c",
            .yank => "y",
            .indent => ">",
            .outdent => "<",
            .reindent => "=",
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
    /// `2d3w`: once a digit follows the operator, the count typed before
    /// it waits here and `count` holds the one after; the two multiply
    /// when the motion comes (`:help operator`), so `2d3w` is `d6w`.
    op_pre_count: ?u32 = null,
    op_count_split: bool = false,
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
    /// `c_CTRL-V`: the next key goes into the `:` line literally.
    cmdline_literal_next: bool = false,
    /// A visual text object just set the selection to its exact range —
    /// the next operator must not widen it. Any other visual key clears it.
    visual_exact: bool = false,
    /// The Visual mode the last selection was made in — what `gv`
    /// comes back to (`:help gv`).
    last_visual: VimMode = .visual,
    /// While `op` is `.script`: which claimed operator is pending, and
    /// the letter that claimed it — `gss` doubles the way `gUU` does.
    script_op: u32 = 0,
    /// Which Lua state owns `script_op` (`input/script_ops.zig`).
    script_op_state: u16 = 0,
    script_letter: u8 = 0,

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

    /// An operator waits for its motion (`d`, `c`, `gU` …) — Neovim's
    /// operator-pending mode, not a register or mark prefix.
    pub fn isOperatorPending(self: *const Vim) bool {
        return self.op != null and !self.cmdline_open;
    }

    pub fn onBlur(self: *Vim) void {
        self.enterNormal();
    }

    /// The end of a pending operator's motion that only the buffer or the
    /// app could find — a mark (`d'a`), a search (`d/pat<CR>`): `motion`
    /// moves the cursor there from the range's start, and the operator
    /// finishes the way it finishes after `j` (`linewise`) or `w`. Null
    /// when no operator is pending.
    pub fn finishPendingMotion(self: *Vim, motion_ops: []const EditOp, linewise: bool, ctx: EditCtx, arena: Allocator) Allocator.Error!?InputResult {
        const op = self.op orelse return null;
        self.resetPending();
        var b = Builder.init(arena);
        try b.push(.select_start);
        for (motion_ops) |m| try b.push(m);
        if (linewise) return try self.finishLinewise(&b, op, ctx);
        return try self.finishExclusive(&b, op, ctx);
    }

    /// Insert-mode `Ctrl+N` / `Ctrl+P` / `Ctrl+O` are vim's before they
    /// are the keymap's (lowercase only: `Ctrl+Shift+P` stays the palette).
    pub fn reservesKey(self: *const Vim, k: Key) bool {
        const typing = self.vmode == .insert or self.vmode == .replace;
        if (!typing or !k.mods.ctrl or k.mods.alt or k.mods.super or k.mods.shift) return false;
        return switch (k.code) {
            // `Ctrl-H` / `J` / `K` / `L` switch windows from Normal only:
            // while typing they are vim's own (`i_CTRL-H` backspace,
            // `i_CTRL-J` a line break), so the editor never stays in
            // Insert with the keyboard gone to the tree.
            .char => |c| c == 'h' or c == 'j' or c == 'k' or c == 'l' or (self.vmode == .insert and (c == 'n' or c == 'p' or c == 'o')),
            else => false,
        };
    }

    pub fn requestInsertMode(self: *Vim) void {
        self.enterInsert();
    }

    pub fn setMacroRecording(self: *Vim, on: bool) void {
        self.is_recording_macro = on;
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
        if (self.op_count_split) {
            if (self.op_pre_count) |n| try s.print(arena, "{d}", .{n});
            if (self.op) |op| try s.appendSlice(arena, op.glyph());
            if (self.count) |n| try s.print(arena, "{d}", .{n});
        } else {
            if (self.count) |n| try s.print(arena, "{d}", .{n});
            if (self.op) |op| try s.appendSlice(arena, op.glyph());
        }
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
                .{ .key = 's', .label = "split down" },     .{ .key = 'v', .label = "split right" },     .{ .key = 'w', .label = "next split" },
                .{ .key = 'W', .label = "previous split" }, .{ .key = 'q', .label = "close split" },     .{ .key = 'o', .label = "only" },
                .{ .key = 'H', .label = "move far left" },  .{ .key = 'J', .label = "move bottom" },     .{ .key = 'K', .label = "move top" },
                .{ .key = 'L', .label = "move far right" }, .{ .key = 'r', .label = "rotate" },          .{ .key = '=', .label = "equalize" },
                .{ .key = 'n', .label = "new scratch" },    .{ .key = 'T', .label = "move to new tab" }, .{ .key = 'z', .label = "zoom the split / restore" },
            } },
            else => null,
        };
    }

    // ─── state helpers ───

    fn resetPending(self: *Vim) void {
        self.count = null;
        self.op_pre_count = null;
        self.op_count_split = false;
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

    /// The window and the cursor move together; the app knows the height.
    fn pageScroll(kind: input.PageScroll, count: u32) InputResult {
        return .{ .app = .{ .page_scroll = .{ .kind = kind, .count = count } } };
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
                'G' => .{ .move_to_line_keep_col = 0 },
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

    fn isVisual(m: VimMode) bool {
        return m == .visual or m == .visual_line or m == .visual_block;
    }

    fn isCtrlChar(key: Key, c: u21) bool {
        if (!key.mods.ctrl) return false;
        const k = charOf(key) orelse return false;
        return k == c or (k < 0x80 and std.ascii.toLower(@intCast(k)) == c);
    }

    // ─── dispatch ───

    pub fn handleKey(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        if (self.cmdline_open) return self.handleCmdline(key, arena);
        const before = self.vmode;
        // The char after `f` `F` `t` `T` is read here, ahead of every
        // mode's own table, so `vf)` finds `)` instead of running the
        // `)` sentence motion.
        const result = if (self.prefix == .find_char) try self.findCharTarget(self.prefix.find_char, key, ctx, arena) else switch (self.vmode) {
            .insert => try self.handleInsert(key, arena),
            .replace => try self.handleReplace(key, arena),
            .normal => try self.handleNormal(key, ctx, arena),
            .visual, .visual_line => try self.handleVisual(key, ctx, arena),
            .visual_block => try self.handleVisualBlock(key, ctx, arena),
        };
        if (isVisual(before) and !isVisual(self.vmode)) self.last_visual = before;
        // `"+yG` / `"adgg`: the linewise-to-an-end ops run in the app, so
        // the pending register rides along with the command.
        if (result == .app and result.app == .operator_linewise_to and self.pending_register != null) {
            var cmd = result.app;
            cmd.operator_linewise_to.register = self.pending_register;
            self.pending_register = null;
            return .{ .app = cmd };
        }
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
        if (self.cmdline_literal_next) {
            // `Ctrl-V Tab` is a tab character, `Ctrl-V Ctrl-X` the control
            // char, whatever the key would otherwise do (`:help c_CTRL-V`).
            self.cmdline_literal_next = false;
            const lit: ?u21 = switch (key.code) {
                .tab => '\t',
                .enter => '\r',
                .esc => 0x1b,
                .char => |c| if (key.mods.ctrl and c < 0x80) @as(u21, std.ascii.toUpper(@intCast(c)) & 0x1f) else c,
                else => null,
            };
            if (lit) |c| try self.insertCmdlineChar(c);
            return .consumed;
        }
        if (self.cmdline_pending_ctrl_r) {
            self.cmdline_pending_ctrl_r = false;
            if (isCtrlChar(key, 'w')) return .{ .app = .{ .cmdline_insert_cursor_word = false } };
            if (isCtrlChar(key, 'a')) return .{ .app = .{ .cmdline_insert_cursor_word = true } };
            // `Ctrl-R "` / `+` / `*`: the register's text (`:help c_CTRL-R`).
            if (charOf(key)) |c| switch (c) {
                '"', '+', '*' => return .{ .app = .cmdline_paste_from_clipboard },
                else => {},
            };
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
            self.stopHistoryWalk();
            return .consumed;
        }
        if (isCtrlChar(key, 'u')) {
            line.clearRetainingCapacity();
            self.cmdline_cursor = 0;
            self.stopHistoryWalk();
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
        if (isCtrlChar(key, 'v') or isCtrlChar(key, 'q')) {
            self.cmdline_literal_next = true;
            return .consumed;
        }
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
            // `:help c_<Up>`: the older entry that starts with what was
            // typed before the walk began; none older leaves the line.
            .up => {
                if (self.ex_history.items.len == 0) return .consumed;
                if (self.ex_history_cursor == null) {
                    if (self.ex_history_typing) |t| gpa.free(t);
                    self.ex_history_typing = try gpa.dupe(u8, line.items);
                    self.ex_history_cursor = self.ex_history.items.len;
                }
                const prefix = self.ex_history_typing orelse "";
                var i = self.ex_history_cursor.?;
                while (i > 0) {
                    i -= 1;
                    if (!std.mem.startsWith(u8, self.ex_history.items[i], prefix)) continue;
                    self.ex_history_cursor = i;
                    try self.setLine(self.ex_history.items[i]);
                    break;
                }
                return .consumed;
            },
            .down => {
                const curh = self.ex_history_cursor orelse return .consumed;
                const prefix = self.ex_history_typing orelse "";
                var i = curh + 1;
                while (i < self.ex_history.items.len) : (i += 1) {
                    if (!std.mem.startsWith(u8, self.ex_history.items[i], prefix)) continue;
                    self.ex_history_cursor = i;
                    try self.setLine(self.ex_history.items[i]);
                    return .consumed;
                }
                // Past the newest match: the typed text again.
                try self.setLine(prefix);
                self.stopHistoryWalk();
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
                try self.insertCmdlineChar(c);
                return .consumed;
            },
            else => return .consumed,
        }
    }

    fn insertCmdlineChar(self: *Vim, c: u21) Allocator.Error!void {
        const cur = @min(self.cmdline_cursor, self.cmdline.items.len);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch return;
        try self.cmdline.insertSlice(self.gpa, cur, buf[0..n]);
        self.cmdline_cursor = cur + n;
        self.stopHistoryWalk();
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
                    return ops(arena, &.{.move_left_no_cross_line});
                },
                'w' => return ops(arena, &.{.delete_word_left_in_insert}),
                'u' => return ops(arena, &.{.delete_to_line_start_in_insert}),
                'h' => return ops(arena, &.{.backspace}),
                // `i_CTRL-T`: the line gains an indent and the cursor
                // stays on the same text (`:help i_CTRL-T`) — `indent`
                // keeps the (row, col), so step over what it added.
                't' => {
                    const step = try arena.create(EditOp);
                    step.* = .move_right;
                    const width: u32 = if (self.use_tabs) 1 else @intCast(self.tab_width);
                    return ops(arena, &.{ .indent, .{ .repeat = .{ .count = width, .inner = step } } });
                },
                'd' => return ops(arena, &.{.outdent}),
                'v', 'q' => {
                    self.insert_literal_next = true;
                    return .consumed;
                },
                'j' => return ops(arena, &.{.insert_newline}),
                // `i_CTRL-L` types a form feed in Neovim (no 'insertmode');
                // `i_CTRL-K`'s digraphs are not supported, and the key is
                // taken so it never reaches the window chord.
                'l' => return ops(arena, &.{.{ .insert_char = 0x0C }}),
                'k' => return .consumed,
                else => return .ignored,
            }
        }
        return switch (key.code) {
            .esc => blk: {
                self.enterNormal();
                break :blk ops(arena, &.{.move_left_no_cross_line});
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
        // As in Insert: `Ctrl-H` steps back (restoring what was
        // overwritten), `Ctrl-J` breaks the line.
        if (isCtrlChar(key, 'h')) return ops(arena, &.{.replace_undo_one});
        if (isCtrlChar(key, 'j')) return ops(arena, &.{.insert_newline});
        if (isCtrlChar(key, 'k') or isCtrlChar(key, 'l')) return .consumed;
        return switch (key.code) {
            .esc => blk: {
                self.enterNormal();
                break :blk ops(arena, &.{.move_left_no_cross_line});
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
    /// `linewise_object` = `ip`/`ap`: the object names whole lines, so
    /// the operator widens to their terminators the way `V…d` does —
    /// `dip` leaves no empty line behind, `cip` opens one to type into
    /// (`:help ip`, `:help v_c`).
    fn finishOperator(self: *Vim, b: *Builder, op: PendingOp, ctx: EditCtx, linewise_object: bool) Allocator.Error!InputResult {
        switch (op) {
            .delete => {
                if (linewise_object) {
                    try b.push(.normalize_linewise_selection);
                    try b.push(.delete_selection_linewise);
                } else try b.push(.delete_selection);
            },
            .yank => {
                if (linewise_object) try b.push(.normalize_linewise_selection);
                try b.push(if (linewise_object) .yank_selection_linewise else .yank_selection);
                try b.push(.select_clear);
                try b.push(.{ .set_cursor_byte = ctx.cursor });
            },
            .change => {
                // The text goes to the registers the way `d` would put it
                // there (`:help c`): linewise for whole lines, into `"-`
                // for a change within one line.
                if (linewise_object) try b.push(.normalize_linewise_selection_inner);
                try b.push(.{ .register_selection_delete = linewise_object });
                // Whole lines keep the first one's indent to type after
                // (Neovim's `autoindent`: `cj` on `  a` → `  X`).
                if (linewise_object) {
                    try b.push(.swap_anchor_cursor);
                    try b.push(.move_line_first_non_ws);
                }
                try b.push(.{ .replace_selection = "" });
                try b.push(.continue_insert_run);
                self.vmode = .insert;
            },
            .indent => {
                try b.push(.indent_to_first_non_blank);
                try b.push(.select_clear);
            },
            .outdent => {
                try b.push(.outdent_to_first_non_blank);
                try b.push(.select_clear);
            },
            .reindent => {
                try b.push(.reindent);
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
                // The toggle keeps the range selected; `gcip` ends on
                // its first line.
                try b.push(.move_cursor_to_selection_start);
                try b.push(.select_clear);
            },
            .surround_add => {
                // The range goes live now; the surround char closes it.
                self.prefix = .surround_add_char_wait;
            },
            .@"align" => {
                self.prefix = .align_char_wait;
            },
            // The range goes live first, as whole lines with the cursor on
            // the last one's end; the app folds the selection.
            .fold => {
                try b.push(.normalize_linewise_selection_inner);
                return .{ .app = .{ .fold_after = b.list.items } };
            },
            .filter => return .consumed, // TODO(vim-slice: filter) `!{motion}`
            // The range goes live the way every other operator's does;
            // the app hands it to the script and clears the selection.
            .script => {
                // A linewise object (`ip` / `ap`) hands over whole lines
                // WITHOUT the last one's terminator: a script that wraps
                // a range wants the text, not the newline after it.
                if (linewise_object) try b.push(.normalize_linewise_selection_inner);
                return .{ .app = .{ .script_operator = .{ .ops = b.list.items, .index = self.script_op, .state = self.script_op_state, .linewise = linewise_object } } };
            },
        }
        return b.finish();
    }

    /// An operator after a linewise motion (`j` `k` `+` `-` `_`, `'a`):
    /// every line the range touches, whole. Delete / yank / change keep
    /// their linewise registers; the case operators and `yk` end where
    /// the range began (`:help y`).
    fn finishLinewise(self: *Vim, b: *Builder, op: PendingOp, ctx: EditCtx) Allocator.Error!InputResult {
        try b.push(.mark_operator_start);
        return self.finishLinewiseMarked(b, op, ctx);
    }

    /// `finishLinewise` once `mark_operator_start` has run.
    fn finishLinewiseMarked(self: *Vim, b: *Builder, op: PendingOp, ctx: EditCtx) Allocator.Error!InputResult {
        switch (op) {
            .delete, .yank, .change, .script => {
                const r = try self.finishOperator(b, op, ctx, true);
                if (op == .yank and r == .ops) {
                    const list: []EditOp = @constCast(r.ops);
                    list[list.len - 1] = .cursor_to_operator_start;
                }
                return r;
            },
            .fold, .reflow, .surround_add, .filter => return self.finishOperator(b, op, ctx, false),
            .lower, .upper, .toggle_case => {
                try b.push(.normalize_linewise_selection);
                _ = try self.finishOperator(b, op, ctx, false);
                try b.push(.cursor_to_operator_start);
                return b.finish();
            },
            else => {
                try b.push(.normalize_linewise_selection);
                return self.finishOperator(b, op, ctx, false);
            },
        }
    }

    /// An operator after an exclusive motion (`w` `b` `}` `` `a `` `/pat`
    /// `n`): `:help exclusive` decides, when the op is applied, whether a
    /// range ending in column 1 stops at the line above's end or turns
    /// linewise. The operators that hand their range to the app keep
    /// the plain range.
    fn finishExclusive(self: *Vim, b: *Builder, op: PendingOp, ctx: EditCtx) Allocator.Error!InputResult {
        switch (op) {
            .fold, .reflow, .surround_add, .@"align", .filter, .script, .comment => return self.finishOperator(b, op, ctx, false),
            else => {},
        }
        // The column the motion ended on is the one a linewise delete
        // keeps (`d/pat` onto a line start lands on column 1).
        try b.push(.mark_operator_start);
        try b.push(.exclusive_motion_rule);
        const vmode_before = self.vmode;
        var lb = Builder.init(b.arena);
        const lines = (try self.finishLinewiseMarked(&lb, op, ctx)).ops;
        self.vmode = vmode_before;
        var cb = Builder.init(b.arena);
        const chars = (try self.finishOperator(&cb, op, ctx, false)).ops;
        try b.push(.{ .if_lines_object = .{ .lines = lines, .chars = chars } });
        return b.finish();
    }

    /// `{n}D` / `{n}C`: the operator over `$` with a count — from the
    /// cursor to the end of the line `n - 1` below (`:help $`).
    fn countedToLineEnd(self: *Vim, n: u32, op: PendingOp, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        var b = Builder.init(arena);
        try b.push(.select_start);
        try b.pushRepeated(.move_down, n - 1);
        try b.push(.move_line_end);
        return self.finishOperator(&b, op, ctx, false);
    }

    /// `{count}cc` / `{count}S`: the lines go to the register whole and
    /// one line stays to type into, keeping the first one's indent
    /// (Neovim's `autoindent`: `  abc` + `ccX` → `  X`).
    fn changeLines(arena: Allocator, n: u32) Allocator.Error![]const EditOp {
        return arena.dupe(EditOp, &.{
            .{ .select_count_lines = n },
            .{ .register_selection_delete = true },
            .swap_anchor_cursor,
            .move_line_first_non_ws,
            .{ .replace_selection = "" },
            .continue_insert_run,
        });
    }

    /// `[(` `[{` `])` `]}` as a motion, or as an operator's target.
    fn unmatchedMotion(self: *Vim, op: ?PendingOp, open: u21, forward: bool, n: u32, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const m: EditOp = .{ .move_to_unmatched = .{ .open = open, .forward = forward } };
        const o = op orelse return repeated(arena, m, n);
        var b = Builder.init(arena);
        try b.push(.select_start);
        try b.pushRepeated(m, n);
        return self.finishOperator(&b, o, ctx, false);
    }

    fn textObjectOp(key: Key, around: bool) ?EditOp {
        const c = charOf(key) orelse return null;
        return switch (c) {
            'w' => if (around) .select_around_word else .select_inner_word,
            'W' => if (around) .select_around_big_word else .select_inner_big_word,
            '"', '\'', '`' => if (around) .{ .select_around_quote = c } else .{ .select_inner_quote = c },
            'q' => if (around) .select_around_smart_quote else .select_inner_smart_quote,
            'p' => if (around) .select_around_paragraph else .select_inner_paragraph,
            's' => if (around) .select_around_sentence else .select_inner_sentence,
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
                // `r<CR>` splits the line; `5r<CR>` replaces five
                // characters with ONE line break (`:help r`).
                if (key.code == .enter and !key.mods.ctrl and !key.mods.alt) return ops(arena, &.{.{ .replace_chars_with_newline = n }});
                const c = ch orelse return .consumed;
                // Visual `r`: every selected char (the selection is live).
                if (ctx.has_selection) return ops(arena, &.{.{ .replace_char_at_cursor = c }});
                // `{n}r` needs `n` chars from the cursor, or does nothing.
                return ops(arena, &.{.{ .replace_chars = .{ .ch = c, .count = n } }});
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
                const n = self.count1();
                self.resetPending();
                const c = ch orelse return .consumed;
                return switch (c) {
                    // `zf{motion}` is an operator (`:help zf`); `zF` folds
                    // `count` lines from the cursor's.
                    'f' => blk: {
                        self.op = .fold;
                        break :blk .consumed;
                    },
                    'F' => blk: {
                        var b = Builder.init(arena);
                        try b.push(.select_start);
                        if (n > 1) try b.pushRepeated(.move_down, n - 1);
                        try b.push(.normalize_linewise_selection_inner);
                        break :blk .{ .app = .{ .fold_after = b.list.items } };
                    },
                    'a', 'A' => runCmd(.@"editor.toggle_fold"),
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
                if (motion(key.code)) |m| return ops(arena, &.{ .select_start, m, .toggle_line_comment, .move_cursor_to_selection_start, .select_clear });
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
            .mark_jump_line, .mark_jump_exact => {
                const exact = self.prefix == .mark_jump_exact;
                const op = self.op;
                self.resetPending();
                // `'[` / `']`: the first / last line of the text last put,
                // yanked or changed (`:help '[`), a buffer mark like `a`.
                const bracket_mark: ?u8 = if (ch == '[' or ch == ']') @intCast(ch.?) else null;
                if (bracket_mark orelse asciiLetter(ch)) |c| {
                    // `d'a` / `` y`a `` / `c'a`: a mark is a motion (`:help
                    // '`). The buffer holds the mark, so it builds the
                    // range; only the buffer-local marks are targets.
                    if (op) |o| {
                        if ((c < 'a' or c > 'z') and bracket_mark == null) return .consumed;
                        // The operator stays pending: the buffer finds
                        // the mark and hands it back as the motion's end
                        // (`finishPendingMotion`), so every operator
                        // takes a mark the way it takes `w` or `j`.
                        self.op = o;
                        return .{ .app = .{ .operator_to_mark = .{ .op = o.glyph()[0], .mark = c, .exact = exact } } };
                    }
                    return .{ .app = if (exact) .{ .jump_to_mark_exact = c } else .{ .jump_to_mark_line = c } };
                }
                if (ch == '\'' and !exact) return runCmd(.@"nav.jump_toggle_prev");
                if (ch == '`' and exact) return runCmd(.@"nav.jump_toggle_prev");
                // `'.` / `` `. ``: the last change.
                if (ch == '.' and op == null) return .{ .app = if (exact) .{ .jump_to_mark_exact = '.' } else .{ .jump_to_mark_line = '.' } };
                return .consumed;
            },
            .find_char => unreachable, // handleKey reads the target
            .text_object_inner, .text_object_around => {
                const around = self.prefix == .text_object_around;
                const op = self.op orelse {
                    self.resetPending();
                    return .consumed;
                };
                const n = self.count1();
                self.resetPending();
                const select_op = textObjectOp(key, around) orelse return .consumed;
                if (op == .filter) {
                    if (ch == 'p') return .{ .app = .{ .filter_paragraph_from_cursor = .{ .around = around } } };
                    return .consumed;
                }
                const linewise = select_op == .select_inner_paragraph or select_op == .select_around_paragraph;
                const counted = select_op == .select_inner_bracket or select_op == .select_around_bracket or select_op == .select_inner_tag or select_op == .select_around_tag;
                var b = Builder.init(arena);
                // `2di{` / `d2it`: the count-th enclosing pair (`:help i{`).
                if (counted and n > 1) try b.pushRepeated(select_op, n) else try b.push(select_op);
                // No object under the cursor (`ci(` outside parens): the
                // operator is abandoned, not run on nothing.
                try b.push(.abort_unless_selection);
                if (select_op == .select_inner_bracket and (op == .delete or op == .change or op == .yank)) {
                    // A body between braces on their own lines is whole
                    // lines: `d` / `y` take them linewise and `c` leaves
                    // one line, its indent kept (Neovim's autoindent).
                    // The editor knows which once the object is chosen.
                    const vmode_before = self.vmode;
                    var lb = Builder.init(arena);
                    const lines = (try self.finishOperator(&lb, op, ctx, true)).ops;
                    const lines_list: []const EditOp = lines;
                    self.vmode = vmode_before;
                    var cb = Builder.init(arena);
                    const chars = (try self.finishOperator(&cb, op, ctx, false)).ops;
                    try b.push(.{ .if_lines_object = .{ .lines = lines_list, .chars = chars } });
                    return b.finish();
                }
                return self.finishOperator(&b, op, ctx, linewise);
            },
            .bracket_open => {
                const n = self.count1();
                const op = self.op;
                self.resetPending();
                const c = ch orelse return .consumed;
                // `[(` / `[{`: back to the unmatched opener — a motion,
                // so `d[{` / `c[(` take it (exclusive, `:help [(`).
                if (c == '(' or c == '{') return self.unmatchedMotion(op, c, false, n, ctx, arena);
                if (op != null) return .consumed;
                return switch (c) {
                    'c' => runCmd(.@"git.jump_prev_change"),
                    'x' => runCmd(.@"git.conflict_prev"),
                    'd' => runCmd(.@"lsp.prev_diagnostic"),
                    'q' => runCmd(.@"qf.prev"),
                    't' => runCmd(.@"project.prev_todo"),
                    '[' => runCmd(.@"editor.section_prev_start"),
                    ']' => runCmd(.@"editor.section_prev_end"),
                    'm' => runCmd(.@"editor.method_prev"),
                    // Neovim's default `[b` (`:bprevious`, `:help [b`).
                    'b' => runCmd(.@"buffer.prev"),
                    // The session ring backwards (`app/session_cycle.zig`).
                    // Neovim's `[a` is the argument list, which mnml has none of.
                    'a' => .{ .app = .{ .session_step = .{ .count = n, .forward = false } } },
                    // `[p` / `[P` / `]P` all put BEFORE with the indent
                    // adjusted (`:help [p`); a count repeats the put.
                    'p', 'P' => repeated(arena, .paste_before_indent, n),
                    else => .consumed,
                };
            },
            .bracket_close => {
                const n = self.count1();
                const op = self.op;
                self.resetPending();
                const c = ch orelse return .consumed;
                // `])` / `]}`: on to the unmatched closer.
                if (c == ')' or c == '}') return self.unmatchedMotion(op, if (c == ')') '(' else '{', true, n, ctx, arena);
                if (op != null) return .consumed;
                return switch (c) {
                    'c' => runCmd(.@"git.jump_next_change"),
                    'x' => runCmd(.@"git.conflict_next"),
                    'd' => runCmd(.@"lsp.next_diagnostic"),
                    'q' => runCmd(.@"qf.next"),
                    't' => runCmd(.@"project.next_todo"),
                    ']' => runCmd(.@"editor.section_next_start"),
                    '[' => runCmd(.@"editor.section_next_end"),
                    'm' => runCmd(.@"editor.method_next"),
                    // Neovim's default `]b` (`:bnext`, `:help ]b`).
                    'b' => runCmd(.@"buffer.next"),
                    // The session ring (`app/session_cycle.zig`); Neovim's
                    // `]a` is the argument list, which mnml has none of.
                    'a' => .{ .app = .{ .session_step = .{ .count = n, .forward = true } } },
                    // `]p` puts AFTER with the indent adjusted; `]P` is
                    // vim's synonym for `[P` (`:help ]p`).
                    'p' => repeated(arena, .paste_after_indent, n),
                    'P' => repeated(arena, .paste_before_indent, n),
                    else => .consumed,
                };
            },
            .register => {
                self.prefix = .none;
                if (ch) |c| {
                    // `".` reads the last inserted text (a put only).
                    const valid = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '+' or c == '*' or c == '_' or c == '-' or c == '.';
                    if (valid) self.pending_register = c;
                }
                return .consumed;
            },
            .macro_record_target => {
                self.prefix = .none;
                const c = ch orelse return .consumed;
                if (c == ':') return runCmd(.@"view.cmdline_history");
                if (c == '/') return runCmd(.@"view.search_history");
                if (c == '?') return runCmd(.@"view.search_history_backward");
                // `qq` is register q like any other letter (`:help q`).
                // `qA` appends to `a` (`:help q`); the buffer folds the case.
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
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
                if (c >= 'a' and c <= 'z' or c >= '0' and c <= '9') return .{ .app = .{ .macro_replay_from = .{ .reg = @intCast(c), .count = count } } };
                if (c >= 'A' and c <= 'Z') return .{ .app = .{ .macro_replay_from = .{ .reg = @intCast(c + ('a' - 'A')), .count = count } } };
                if (c == ':') return runCmd(.@"vim.replay_last_ex");
                return .consumed;
            },
            .window => {
                const count = self.count;
                self.resetPending();
                // `CTRL-W <Left>` … are `CTRL-W h` … (`:help CTRL-W_<Left>`).
                const c: u21 = ch orelse switch (key.code) {
                    .left => 'h',
                    .right => 'l',
                    .up => 'k',
                    .down => 'j',
                    else => return .consumed,
                };
                // `{count} Ctrl-W >` / `<` / `+` / `-`: that many cells
                // (`:help CTRL-W_>`); the bare chord keeps its 5 % step.
                if (count) |n| {
                    const cells: i32 = @intCast(@min(n, 10_000));
                    switch (c) {
                        '>' => return .{ .app = .{ .split_resize = .{ .width = true, .cells = cells } } },
                        '<' => return .{ .app = .{ .split_resize = .{ .width = true, .cells = -cells } } },
                        '+' => return .{ .app = .{ .split_resize = .{ .width = false, .cells = cells } } },
                        '-' => return .{ .app = .{ .split_resize = .{ .width = false, .cells = -cells } } },
                        else => {},
                    }
                }
                return switch (c) {
                    'w' => runCmd(.@"view.focus_next_split"),
                    // `:help CTRL-W_W` — the same walk backwards.
                    'W' => runCmd(.@"view.focus_prev_split"),
                    't' => runCmd(.@"view.focus_top"),
                    'b' => runCmd(.@"view.focus_bottom"),
                    'p' => runCmd(.@"view.focus_previous"),
                    'q', 'c' => runCmd(.@"view.close_split"),
                    's' => runCmd(.@"view.split_down"),
                    'v' => runCmd(.@"view.split_right"),
                    'o' => runCmd(.@"view.only"),
                    'h' => runCmd(.@"view.focus_left"),
                    'j' => runCmd(.@"view.focus_down"),
                    'k' => runCmd(.@"view.focus_up"),
                    'l' => runCmd(.@"view.focus_right"),
                    'D' => runCmd(.@"view.focus_dock"),
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
                    // `:help CTRL-W_T` — the split leaves its tab page for
                    // a new one, the partner of `Ctrl-W s` / `v`.
                    'T' => runCmd(.@"view.move_to_new_tab"),
                    // tmux's zoom letter: the split has the page until
                    // the same chord puts the layout back.
                    'z' => runCmd(.@"view.toggle_zoom"),
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
                return ops(arena, &.{.{ .move_to_line_keep_col = @max(n, 1) }});
            }
        }
        if (modifiedMotion(key)) |m| {
            const n = self.count1();
            self.resetPending();
            return repeated(arena, m, n);
        }
        if (!ctrl) {
            if (motion(key.code)) |m0| {
                const n = self.count1();
                self.resetPending();
                // Insert's one-shot `Ctrl-O $` goes past the last char:
                // the cursor is back in Insert, where that is a place
                // (`:help i_CTRL-O`).
                const m: EditOp = if (self.insert_oneshot_normal and m0 == .move_line_last_char) .move_line_end else wrapHL(m0);
                return repeated(arena, m, n);
            }
        }
        if (try self.findCharKey(key, ctx, arena)) |r| return r;

        const n = self.count1();
        const typed_count: u32 = self.count orelse 0;
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
                        'd' => pageScroll(.half_down, typed_count),
                        'u' => pageScroll(.half_up, typed_count),
                        'f' => pageScroll(.page_down, typed_count),
                        'b' => pageScroll(.page_up, typed_count),
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
                    // `<count>i I a A o O`: the typed run repeats `count`
                    // times when Insert is left (`:help count`) — the
                    // `80i-<Esc>` rule and `3A;<Esc>`. The app arms the
                    // deferred half; the bare form stays a plain key.
                    'i', 'I', 'a', 'A', 'o', 'O' => {
                        self.resetPending();
                        const kind: input.RepeatInsertKind = switch (c) {
                            'i' => .at_cursor,
                            'I' => .line_first_non_ws,
                            'a' => .after_cursor,
                            'A' => .line_end,
                            'O' => .open_above,
                            else => .open_below,
                        };
                        if (n > 1) return .{ .app = .{ .repeat_insert_start = .{ .count = n, .kind = kind } } };
                        self.enterInsert();
                        return switch (kind) {
                            .at_cursor => .consumed,
                            .line_first_non_ws => ops(arena, &.{.move_line_first_non_ws}),
                            .after_cursor => ops(arena, &.{.move_right}),
                            .line_end => ops(arena, &.{.move_line_end}),
                            .open_above => ops(arena, &.{.insert_newline_above}),
                            .open_below => ops(arena, &.{.insert_newline_below}),
                        };
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
                        if (n == 1) return ops(arena, &.{.delete_to_line_end});
                        // `{n}D` is `d$` with a count: to the end of the
                        // line `n - 1` below (clamped); on the last line
                        // it fails (`:help D`).
                        if (ctx.line_idx + 1 >= ctx.line_count) return .consumed;
                        return self.countedToLineEnd(n, .delete, ctx, arena);
                    },
                    'C' => {
                        if (n == 1) {
                            self.enterInsert();
                            return ops(arena, &.{.delete_to_line_end});
                        }
                        if (ctx.line_idx + 1 >= ctx.line_count) {
                            self.resetPending();
                            return .consumed;
                        }
                        self.resetPending();
                        return self.countedToLineEnd(n, .change, ctx, arena);
                    },
                    's' => {
                        self.resetPending();
                        self.prefix = .flash1;
                        return .consumed;
                    },
                    'S' => {
                        if (n > 1 and ctx.line_idx + 1 >= ctx.line_count) {
                            self.resetPending();
                            return .consumed;
                        }
                        self.enterInsert();
                        return ops(arena, try changeLines(arena, n));
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
                        return .{ .app = .{ .macro_replay_from = .{ .reg = '@', .count = count, .recorded = true } } };
                    },
                    '@' => {
                        self.prefix = .macro_replay_target;
                        return .consumed;
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
                    'U' => {
                        self.resetPending();
                        return ops(arena, &.{.undo_line});
                    },
                    'd', 'c', 'y', '>', '<', '=', '!' => {
                        self.op = switch (c) {
                            'd' => .delete,
                            'c' => .change,
                            'y' => .yank,
                            '>' => .indent,
                            '<' => .outdent,
                            '=' => .reindent,
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
                        if (pct) |p| return ops(arena, &.{.{ .move_to_line_keep_col = pctLine(p, ctx.line_count) }});
                        // A motion, so operators and Visual take it too;
                        // `editor.bracket_match` runs the same one.
                        return ops(arena, &.{.move_bracket_match});
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
                    'n', 'N' => {
                        self.resetPending();
                        const forward = (c == 'n') != self.last_search_backward;
                        // `{count}n`: the `count`th match on (`:help n`).
                        if (n > 1) return .{ .app = .{ .find_step = .{ .count = n, .forward = forward } } };
                        return runCmd(if (forward) .@"find.next" else .@"find.prev");
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
                const go: EditOp = .{ .move_to_line_keep_col = if (count_explicit) @max(n, 1) else 1 };
                if (pending_op) |op| {
                    if (op == .delete or op == .yank) {
                        const target: ?u32 = if (count_explicit) n else 0;
                        return .{ .app = .{ .operator_linewise_to = .{ .op = if (op == .delete) 'd' else 'y', .target = target } } };
                    }
                    // `=gg`, `>gg`, `cgg`: linewise back to the top — the
                    // cursor's line counts whole.
                    var b = Builder.init(arena);
                    try b.push(.move_line_end);
                    try b.push(.select_start);
                    try b.push(go);
                    return self.finishOperator(&b, op, ctx, false);
                }
                return ops(arena, &.{go});
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
                // Back in the mode the selection was made in (`:help gv`).
                self.vmode = self.last_visual;
                const shape: @import("../editor/edit_op.zig").SelectionShape = switch (self.last_visual) {
                    .visual_line => .linewise,
                    .visual_block => .block,
                    else => .charwise,
                };
                // The remembered range was already widened when it closed.
                self.visual_exact = true;
                return ops(arena, &.{.{ .restore_last_selection = shape }});
            },
            ';' => return runCmd(.@"editor.jump_prev_edit"),
            ',' => return runCmd(.@"editor.jump_next_edit"),
            'J' => return repeated(arena, .{ .join_lines = .{ .keep_space = false } }, @max(n -| 1, 1)),
            '&' => return runCmd(.@"editor.repeat_last_substitute_all"),
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
                return runCmd(.@"find.word_forward_partial");
            },
            '#' => {
                self.last_search_backward = true;
                return runCmd(.@"find.word_backward_partial");
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
                // No match to take: the command's toast says why.
                if (range == null) return runCmd(if (forward) .@"find.select_match_forward" else .@"find.select_match_backward");
                // The match is picked when the op is applied, not here:
                // `.` after `cgn` takes the match after the one it
                // changed (`:help gn`).
                if (pending_op) |op| {
                    var b = Builder.init(arena);
                    try b.push(.{ .select_find_match = .{ .forward = forward } });
                    return self.finishOperator(&b, op, ctx, false);
                }
                // Visual: the cursor sits ON the match's last char, so
                // the `d` / `y` after it widen to the match and no more.
                self.vmode = .visual;
                return ops(arena, &.{.{ .select_find_match = .{ .forward = forward, .inclusive = true } }});
            },
            'a' => return runCmd(.@"editor.char_info"),
            '8' => return runCmd(.@"editor.char_utf8"),
            'A' => {
                self.op = .@"align";
                return .consumed;
            },
            // A letter vim does not use may be a script's operator
            // (`input/script_ops.zig`). The lookup sits after the switch,
            // so a claim can never shadow one of the chords above.
            else => {
                if (pending_op == null) if (script_ops.lookup(c)) |claim| {
                    self.op = .script;
                    self.script_op = claim.index;
                    self.script_op_state = claim.state;
                    self.script_letter = @intCast(@min(c, std.math.maxInt(u8)));
                    if (count_explicit) self.count = n;
                    return .consumed;
                };
                return .consumed;
            },
        }
    }

    fn handleOperatorPending(self: *Vim, op: PendingOp, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const ch = charOf(key);
        if (ch) |c| {
            // The count after the operator is its own number: `2d0` is
            // `d0` twice over, not `d20`, and `2d2d` is four lines.
            const post: ?u32 = if (self.op_count_split) self.count else null;
            if (c >= '0' and c <= '9' and !(c == '0' and post == null)) {
                if (!self.op_count_split) {
                    self.op_pre_count = self.count;
                    self.count = null;
                    self.op_count_split = true;
                }
                self.pushDigit(c - '0');
                return .consumed;
            }
        }
        if (self.op_count_split) {
            if (self.op_pre_count) |pre| self.count = pre *| (self.count orelse 1);
            self.op_pre_count = null;
            self.op_count_split = false;
        }
        const doubled = if (ch) |c| switch (op) {
            .delete => c == 'd',
            .change => c == 'c',
            .yank => c == 'y',
            .indent => c == '>',
            .outdent => c == '<',
            .reindent => c == '=',
            .lower => c == 'u',
            .upper => c == 'U',
            .toggle_case => c == '~',
            .surround_add => c == 's',
            .@"align" => c == 'A',
            .filter => c == '!',
            .reflow, .comment, .fold => false,
            .script => c == self.script_letter,
        } else false;
        if (!doubled) {
            if (try self.findCharKey(key, ctx, arena)) |r| return r;
        }
        const n = self.count1();
        const self_count_pct = self.count;
        self.resetPending();
        if (key.code == .esc) return .consumed;
        if (doubled) {
            switch (op) {
                // Always a `repeat`, so `{count}.` after a bare `dd`
                // replaces its count instead of running `dd` count times.
                .delete => {
                    var b = Builder.init(arena);
                    try b.pushRepeated(.delete_line, n);
                    return b.finish();
                },
                .yank => return ops(arena, &.{.{ .yank_lines_count = n }}),
                .change => {
                    // `{count}cc` past the last line fails (it is `c{count-1}j`).
                    if (n > 1 and ctx.line_idx + 1 >= ctx.line_count) return .consumed;
                    self.vmode = .insert;
                    return ops(arena, try changeLines(arena, n));
                },
                .indent, .outdent, .reindent => {
                    var b = Builder.init(arena);
                    try b.push(.select_start);
                    for (1..n) |_| try b.push(.move_down);
                    try b.push(.move_line_end);
                    try b.push(switch (op) {
                        .indent => .indent_to_first_non_blank,
                        .outdent => .outdent_to_first_non_blank,
                        else => .reindent,
                    });
                    try b.push(.select_clear);
                    return b.finish();
                },
                .lower, .upper, .toggle_case => {
                    const kind: @import("../editor/edit_op.zig").CaseTransform = switch (op) {
                        .lower => .lower,
                        .upper => .upper,
                        else => .toggle,
                    };
                    // `{n}gUU` covers n lines like `{n}cc`. The cursor stays
                    // on the changed line: without a count vim lands on its
                    // first non-blank (`1G9|g~~` on `    Hello` ends at 1:5);
                    // with one, the original cursor comes back whole
                    // (`1G5|2gUU` ends at 1:5). So `gUUj.` reaches the next
                    // line rather than the one after.
                    var b = Builder.init(arena);
                    try b.push(.select_line);
                    try b.push(.move_line_end);
                    for (1..n) |_| {
                        try b.push(.move_down);
                        try b.push(.move_line_end);
                    }
                    try b.push(.{ .transform_selection_case = kind });
                    try b.push(.select_clear);
                    try b.push(if (n > 1) .{ .set_cursor_byte = ctx.cursor } else .move_line_first_non_ws);
                    return b.finish();
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
                .fold => return .consumed, // `zfzf` has no meaning either
                // `gss` is `count` whole lines, the shape `gUU` has.
                .script => {
                    var b = Builder.init(arena);
                    try b.push(.select_line);
                    try b.push(.move_line_end);
                    for (1..n) |_| {
                        try b.push(.move_down);
                        try b.push(.move_line_end);
                    }
                    // `resetPending` leaves `script_op` alone; it is only
                    // ever read while the pending op is `.script`.
                    return .{ .app = .{ .script_operator = .{ .ops = b.list.items, .index = self.script_op, .state = self.script_op_state, .linewise = true } } };
                },
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
        if (ch == '[' or ch == ']') {
            // `d]}`, `c[(`: the bracket motion comes next.
            self.op = op;
            if (n > 1) self.count = n;
            self.prefix = if (ch == '[') .bracket_open else .bracket_close;
            return .consumed;
        }
        if (ch == '\'' or ch == '`') {
            // `d'a`, `` y`a ``: the mark letter comes next.
            self.op = op;
            self.prefix = if (ch == '\'') .mark_jump_line else .mark_jump_exact;
            return .consumed;
        }
        if (ch == 'G' and (op == .delete or op == .yank)) {
            return .{ .app = .{ .operator_linewise_to = .{ .op = if (op == .delete) 'd' else 'y', .target = if (n > 1) n else null } } };
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
            // `j` / `k` / `+` / `-` are linewise motions (`:help linewise`):
            // the range is every line from the cursor's to where the
            // counted motion stops — at the buffer's edge when the count
            // overshoots (`3Gd9k` takes lines 1-3), nothing at all when
            // it cannot move (`dj` on the last line).
            const step: EditOp = switch (code) {
                .char => |c| switch (c) {
                    '+' => .move_down_first_non_ws,
                    '-' => .move_up_first_non_ws,
                    else => if (dir < 0) .move_up else .move_down,
                },
                .enter => .move_down_first_non_ws,
                else => if (dir < 0) .move_up else .move_down,
            };
            if (op == .filter) return .{ .app = .{ .filter_lines_from_cursor = .{ .count = n + 1 } } };
            var b = Builder.init(arena);
            try b.push(.select_start);
            // Always a `repeat`, so `3.` can replace the count of `dj`.
            try b.pushRepeated(step, n);
            try b.push(.abort_unless_moved);
            return self.finishLinewise(&b, op, ctx);
        }
        // `d_` is `dd`, `d3_` three lines (`:help _`): `count - 1` lines
        // down, linewise.
        if (ch == '_') {
            if (op == .filter) return .{ .app = .{ .filter_lines_from_cursor = .{ .count = n } } };
            var b = Builder.init(arena);
            try b.push(.select_start);
            if (n > 1) {
                try b.pushRepeated(.move_down, n - 1);
                try b.push(.abort_unless_moved);
            }
            return self.finishLinewise(&b, op, ctx);
        }
        // `%` is an inclusive motion (`d%`, `y%`, `c%`); `{count}%` is
        // linewise to that percentage of the file.
        if (ch == '%') {
            var b = Builder.init(arena);
            try b.push(.select_start);
            if (self_count_pct) |p| {
                try b.push(.{ .move_to_line_keep_col = pctLine(p, ctx.line_count) });
                return self.finishLinewise(&b, op, ctx);
            }
            try b.push(.move_bracket_match);
            try b.push(.make_selection_inclusive);
            return self.finishOperator(&b, op, ctx, false);
        }
        // `dn` / `dN` (`:help n`): to the next / previous match of the last
        // search, exclusive. `d/pat<CR>` / `d?pat<CR>`: the find bar opens
        // with the operator still pending; the app hands the match back
        // (`finishPendingMotion`).
        if (ch == 'n' or ch == 'N') {
            var b = Builder.init(arena);
            try b.push(.select_start);
            try b.push(.{ .move_to_find_match = .{ .forward = (ch == 'n') != self.last_search_backward, .count = n } });
            return self.finishExclusive(&b, op, ctx);
        }
        if (ch == '/' or ch == '?') {
            self.op = op;
            self.last_search_backward = ch == '?';
            return .{ .app = .{ .operator_search = .{ .backward = ch == '?' } } };
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
            // `G` is linewise: the last line counts whole.
            if (ch == 'G') try b.push(.move_line_end);
            if (inclusive or ch == 'G') return self.finishOperator(&b, op, ctx, false);
            return self.finishExclusive(&b, op, ctx);
        }
        return .consumed;
    }

    // ─── find-char motions ───

    const FindChar = struct { ch: u21, forward: bool, before: bool, repeat: bool };

    /// `f` `F` `t` `T` wait for a char; `;` `,` re-fire the last find.
    /// Normal, operator-pending, Visual, V-LINE and V-BLOCK all route
    /// these keys here, and `findCharTarget` reads the char after them,
    /// so no mode can let one fall through to a same-glyph motion.
    fn findCharKey(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!?InputResult {
        if (key.mods.ctrl or key.mods.alt or key.mods.super) return null;
        const c = charOf(key) orelse return null;
        switch (c) {
            'f', 'F', 't', 'T' => {
                self.prefix = .{ .find_char = .{ .forward = c == 'f' or c == 't', .before = c == 't' or c == 'T' } };
                return .consumed;
            },
            ';', ',' => {
                const f = self.last_find_char orelse {
                    self.resetPending();
                    return .consumed;
                };
                const forward = if (c == ';') f.forward else !f.forward;
                return try self.findCharMotion(.{ .ch = f.ch, .forward = forward, .before = f.before, .repeat = true }, ctx, arena);
            },
            else => return null,
        }
    }

    /// The char after a pending `f` `F` `t` `T`, in any mode. A find
    /// that misses is remembered all the same: Neovim's `;` after a
    /// failed `fz` looks for `z` again.
    fn findCharTarget(self: *Vim, f: @FieldType(Prefix, "find_char"), key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const c = charOf(key) orelse {
            self.resetPending();
            return .consumed;
        };
        self.last_find_char = .{ .ch = c, .forward = f.forward, .before = f.before };
        return self.findCharMotion(.{ .ch = c, .forward = f.forward, .before = f.before, .repeat = false }, ctx, arena);
    }

    /// One find, the pending count as its all-or-nothing count
    /// (`v5fx` with four `x`s stays put): a plain move in Normal and
    /// Visual — the selection follows the cursor — or the range of a
    /// pending operator, which takes the target (`dfx`).
    fn findCharMotion(self: *Vim, f: FindChar, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const op = self.op;
        const n = self.count1();
        self.resetPending();
        const m: EditOp = .{ .find_char_on_line = .{ .ch = f.ch, .forward = f.forward, .before = f.before, .inclusive = op != null, .repeat = f.repeat } };
        var b = Builder.init(arena);
        if (op) |o| {
            try b.push(.select_start);
            try b.pushRepeated(m, n);
            return self.finishOperator(&b, o, ctx, false);
        }
        try b.pushRepeated(m, n);
        // A horizontal motion drops V-BLOCK's ragged `$` edge.
        if (self.vmode == .visual_block) try b.push(.{ .block_eol = false });
        return b.finish();
    }

    // ─── visual ───

    fn handleVisual(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const linewise = self.vmode == .visual_line;
        const ch = charOf(key);
        switch (self.prefix) {
            .g => {
                const n = self.count1();
                self.resetPending();
                const c = ch orelse return .consumed;
                // `v_g_CTRL-A` / `v_g_CTRL-X`: a progression down the lines.
                if (key.mods.ctrl and (c == 'a' or c == 'x')) {
                    self.enterNormal();
                    const d: i64 = if (c == 'a') @intCast(n) else -@as(i64, @intCast(n));
                    const w: EditOp = if (linewise) .normalize_linewise_selection else .make_selection_inclusive;
                    return ops(arena, &.{ w, .{ .change_numbers_in_selection = .{ .delta = d, .progressive = true } } });
                }
                switch (c) {
                    // `v_gJ`: the selected lines join with nothing between.
                    'J' => {
                        self.enterNormal();
                        return ops(arena, &.{ .remember_selection, .{ .join_selection_lines = .{ .keep_space = false } }, .select_clear });
                    },
                    'A' => {
                        // The alignment char arrives next; widen now so
                        // the last line is inside the range.
                        self.prefix = .align_char_wait;
                        return ops(arena, &.{if (linewise) .normalize_linewise_selection else .make_selection_inclusive});
                    },
                    'n', 'N' => {
                        const forward = c == 'n';
                        if ((if (forward) ctx.next_find_match else ctx.prev_find_match) == null)
                            return runCmd(if (forward) .@"find.select_match_forward" else .@"find.select_match_backward");
                        return ops(arena, &.{.{ .select_find_match = .{ .forward = forward, .inclusive = true, .extend = true } }});
                    },
                    // Neovim's `gc` in Visual: every selected line toggles,
                    // NORMAL resumes at the range's start (`'<`).
                    'c' => {
                        self.enterNormal();
                        const widen: EditOp = if (linewise) .normalize_linewise_selection else .make_selection_inclusive;
                        return ops(arena, &.{ widen, .toggle_line_comment, .move_cursor_to_selection_start, .select_clear });
                    },
                    // `V…gs`: the live selection is the operator's range,
                    // widened the way every other visual operator widens it.
                    else => {
                        const claim = script_ops.lookup(c) orelse return .consumed;
                        self.enterNormal();
                        // `_inner`: whole lines, without the last one's
                        // terminator — the range `gss` hands over too.
                        const widen: EditOp = if (linewise) .normalize_linewise_selection_inner else .make_selection_inclusive;
                        const list = try arena.dupe(EditOp, &.{widen});
                        return .{ .app = .{ .script_operator = .{ .ops = list, .index = claim.index, .state = claim.state, .linewise = linewise } } };
                    },
                }
            },
            .z_fold => {
                self.resetPending();
                const c = ch orelse return .consumed;
                self.enterNormal();
                return switch (c) {
                    // Whole lines, the cursor on the last one's end, so the
                    // fold reads its rows unambiguously.
                    'f' => .{ .app = .{ .fold_after = &.{.normalize_linewise_selection_inner} } },
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
                const n = self.count1();
                self.resetPending();
                const op = textObjectOp(key, around) orelse return .consumed;
                self.visual_exact = true;
                // `v2it` / `v2i(`: the count-th enclosing pair.
                const counted = op == .select_inner_bracket or op == .select_around_bracket or op == .select_inner_tag or op == .select_around_tag;
                if (counted and n > 1 and op != .select_inner_bracket) return repeated(arena, op, n);
                // `vip` / `vap` make the selection linewise (`:help v_ip`).
                if (op == .select_inner_paragraph or op == .select_around_paragraph) self.vmode = .visual_line;
                // `vi{` over a body on its own lines takes the last line's
                // break too, so `vi{d` leaves no empty line (`:help v_i{`).
                if (op == .select_inner_bracket) {
                    var b = Builder.init(arena);
                    if (n > 1) try b.pushRepeated(op, n) else try b.push(op);
                    try b.push(.{ .if_lines_object = .{ .lines = &.{.move_right}, .chars = &.{} } });
                    return b.finish();
                }
                return ops(arena, &.{op});
            },
            .register => {
                // `"ap` / `"+y` over a selection (`:help v_p`).
                self.prefix = .none;
                if (ch) |c| {
                    const valid = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '+' or c == '*' or c == '_' or c == '-' or c == '.';
                    if (valid) self.pending_register = c;
                }
                return .consumed;
            },
            .align_char_wait => {
                self.enterNormal();
                const c = ch orelse return ops(arena, &.{.select_clear});
                return ops(arena, &.{ .{ .align_selection = .{ .on_char = c } }, .select_clear });
            },
            .mark_jump_line, .mark_jump_exact => {
                // `V'a`: the selection extends to the mark.
                const exact = self.prefix == .mark_jump_exact;
                self.resetPending();
                const c = asciiLetter(ch) orelse return .consumed;
                return .{ .app = if (exact) .{ .jump_to_mark_exact = c } else .{ .jump_to_mark_line = c } };
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
            // `v_CTRL-A` / `v_CTRL-X`: every selected line's first number,
            // then Normal — never the `a` text-object prefix.
            if (isCtrlChar(key, 'a') or isCtrlChar(key, 'x')) {
                const n = self.count1();
                self.enterNormal();
                const d: i64 = if (isCtrlChar(key, 'a')) @intCast(n) else -@as(i64, @intCast(n));
                return ops(arena, &.{ widen, .{ .change_numbers_in_selection = .{ .delta = d, .progressive = false } } });
            }
            if (ch) |c| {
                const scroll: ?input.PageScroll = switch (std.ascii.toLower(@intCast(@min(c, 0x7F)))) {
                    'b' => .page_up,
                    'f' => .page_down,
                    'u', 'y' => .half_up,
                    'd', 'e' => .half_down,
                    else => null,
                };
                if (scroll) |s| {
                    const typed: u32 = self.count orelse 0;
                    self.count = null;
                    return pageScroll(s, typed);
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
            return repeated(arena, wrapHL(m), n);
        }
        if (ch == '%' and !key.mods.ctrl) {
            const pct = self.count;
            self.count = null;
            if (pct) |p| return ops(arena, &.{.{ .move_to_line_keep_col = pctLine(p, ctx.line_count) }});
            return ops(arena, &.{.move_bracket_match});
        }
        if (try self.findCharKey(key, ctx, arena)) |r| return r;
        // `v2it`: the count rides on to the text object.
        if (!(ch == 'i' or ch == 'a')) self.count = null;
        // `Esc` / `Ctrl-C` leave Visual; charwise remembers its last
        // character too, so `gv` reselects all of it (`:help gv`).
        if (key.code == .esc or isCtrlChar(key, 'c')) {
            self.enterNormal();
            return ops(arena, &.{if (linewise) .select_clear else .select_clear_inclusive});
        }
        const c = ch orelse return .consumed;
        switch (c) {
            'v' => {
                if (linewise) {
                    self.vmode = .visual;
                    return .consumed;
                }
                self.enterNormal();
                return ops(arena, &.{.select_clear_inclusive});
            },
            'V' => {
                if (linewise) {
                    self.enterNormal();
                    return ops(arena, &.{.select_clear});
                }
                // The selection keeps both ends and names their lines
                // (`:help v_V`): `va{V` is every line the block touches.
                self.vmode = .visual_line;
                return .consumed;
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
                // V-LINE's lines go to the register linewise.
                if (linewise) return ops(arena, &.{ widen, .delete_selection_linewise });
                return ops(arena, &.{ widen, .delete_selection });
            },
            'c', 's', 'R' => {
                self.vmode = .insert;
                self.resetPending();
                // Linewise (`V…c`, and `R` from any Visual — `S` is
                // surround's here): the lines go, one empty line stays
                // (`:help v_c`, `v_R`).
                if (linewise or c == 'R') return ops(arena, &.{ .normalize_linewise_selection_inner, .{ .register_selection_delete = true }, .swap_anchor_cursor, .move_line_first_non_ws, .{ .replace_selection = "" }, .continue_insert_run });
                return ops(arena, &.{ widen, .{ .register_selection_delete = false }, .{ .replace_selection = "" }, .continue_insert_run });
            },
            'y' => {
                self.enterNormal();
                if (linewise) return ops(arena, &.{ .normalize_linewise_selection, .yank_selection_linewise, .move_cursor_to_selection_start, .select_clear });
                return ops(arena, &.{ widen, .yank_selection, .move_cursor_to_selection_start, .select_clear });
            },
            'o' => return ops(arena, &.{.swap_anchor_cursor}),
            '>', '<', '=' => {
                self.enterNormal();
                const op: EditOp = switch (c) {
                    '>' => .indent_to_first_non_blank,
                    '<' => .outdent_to_first_non_blank,
                    else => .reindent,
                };
                // The selection is remembered before the op ends it, so
                // `gv` has it back (`Vj>gv>`, `:help gv`).
                if (linewise) return ops(arena, &.{ .normalize_linewise_selection, .remember_selection, op, .select_clear });
                return ops(arena, &.{ .remember_selection, op, .select_clear });
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
                return ops(arena, &.{ widen, .remember_selection, .{ .transform_selection_case = kind }, .select_clear });
            },
            'r' => {
                // Widen now; the replace prefix fills the selection next key.
                self.prefix = .replace;
                self.vmode = .normal;
                return ops(arena, &.{widen});
            },
            'J' => {
                self.enterNormal();
                return ops(arena, &.{ .remember_selection, .{ .join_selection_lines = .{ .keep_space = true } }, .select_clear });
            },
            'p', 'P' => {
                self.enterNormal();
                // Nothing to put: nothing is deleted either (Vim: E353).
                if (ctx.register_empty and self.pending_register == null) return ops(arena, &.{.select_clear});
                return ops(arena, &.{ widen, .{ .put_over_selection = .{ .swap = c == 'p', .linewise = linewise } } });
            },
            '\'', '`' => {
                self.prefix = if (c == '\'') .mark_jump_line else .mark_jump_exact;
                return .consumed;
            },
            '"' => {
                self.prefix = .register;
                return .consumed;
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
                // `:` ends Visual on the spot (`:help v_:`): the `'<,'>`
                // marks take the whole range — a linewise one widened
                // first, so `'>` is the cursor's line and not the one
                // above it — the selection goes, and the cursor stays
                // where Visual left it (`vim -es`: `2GV2j` → `'<`=2,
                // `'>`=4). Esc on the line then finds Normal, not V-LINE.
                try self.openCmdline("'<,'>");
                self.vmode = .normal;
                var b = Builder.init(arena);
                if (linewise) try b.push(.normalize_linewise_selection);
                try b.push(.remember_selection);
                try b.push(.select_clear);
                try b.push(.{ .set_cursor_byte = ctx.cursor });
                return b.finish();
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

    fn handleVisualBlock(self: *Vim, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
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
        if (try self.findCharKey(key, ctx, arena)) |r| return r;
        const n = self.count1();
        self.count = null;
        if (key.code == .esc or isCtrlChar(key, 'v')) {
            self.enterNormal();
            return ops(arena, &.{.block_select_clear});
        }
        const c = ch orelse return .consumed;
        switch (c) {
            // The other corner (`:help v_o`), the other end of the row
            // (`:help v_b_O`).
            'o' => return ops(arena, &.{.swap_anchor_cursor}),
            'O' => return ops(arena, &.{.block_other_end_of_row}),
            'U', 'u', '~' => {
                self.enterNormal();
                return ops(arena, &.{.{ .block_case = switch (c) {
                    'U' => .upper,
                    'u' => .lower,
                    else => .toggle,
                } }});
            },
            '>', '<' => {
                self.enterNormal();
                return ops(arena, &.{.{ .block_shift = .{ .left = c == '<', .count = n } }});
            },
            'J' => {
                self.enterNormal();
                return ops(arena, &.{.{ .block_join = .{ .keep_space = true } }});
            },
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
                // As in the other Visual modes: the marks are set and
                // the block is gone before the `:` line takes a key.
                try self.openCmdline("'<,'>");
                self.vmode = .normal;
                return ops(arena, &.{ .remember_selection, .block_select_clear });
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

/// Normal and Visual `h` / `l` / `←` / `→` under NvChad's
/// `whichwrap+=<>[]hl`: they cross line ends (an operator's `dl` keeps
/// the plain step, which `:help 'whichwrap'` exempts).
fn wrapHL(m: EditOp) EditOp {
    return switch (m) {
        .move_right => .move_right_wrap,
        .move_left => .move_left_wrap,
        else => m,
    };
}

/// `{count}%` (`:help N%`): the line `count` percent into the file,
/// rounded up, 1-based.
fn pctLine(p: u32, line_count: usize) usize {
    const clamped: usize = @min(@max(p, 1), 100);
    const lc = @max(line_count, 1);
    return @max(@min((clamped * lc + 99) / 100, lc), 1);
}

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

test "a script's g<letter> is operator-pending, and only on a letter vim itself does not use" {
    // The drift check for `script_ops.reserved`: vim's own `g` chords
    // must be exactly the letters the table names, or `mnml.operator`
    // would be refusing a free letter — or accepting a dead one.
    const gpa = std.testing.allocator;
    var letters: [52]u8 = undefined;
    for (0..26) |i| {
        letters[i] = @intCast('a' + i);
        letters[26 + i] = @intCast('A' + i);
    }
    for (letters) |letter| {
        defer script_ops.clear(gpa);
        var buf = [2]u8{ 'g', letter };
        try script_ops.register(gpa, &buf, 0, 7);
        var v = Vim.init(gpa, .{});
        defer v.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        _ = try v.handleKey(Key.char('g'), .{}, arena);
        _ = try v.handleKey(Key.char(letter), .{}, arena);
        const claimed = v.op != null and v.op.? == .script;
        if (script_ops.isReserved(letter)) {
            std.testing.expect(!claimed) catch |err| {
                std.debug.print("g{c} is reserved but reached the script\n", .{letter});
                return err;
            };
        } else {
            std.testing.expect(claimed) catch |err| {
                std.debug.print("g{c} is free in script_ops.reserved but vim took it\n", .{letter});
                return err;
            };
            try std.testing.expectEqual(@as(u32, 7), v.script_op);
        }
    }
}

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
    // Walk history: Up recalls the entries that start with what was
    // typed (`:help c_<Up>`), Down restores what was typed.
    _ = try v.handleKey(Key.char(':'), .{}, a);
    _ = try v.handleKey(Key.char('w'), .{}, a);
    _ = try v.handleKey(Key.named(.up), .{}, a);
    try testing.expectEqualStrings("wq", v.cmdlineGet().?);
    _ = try v.handleKey(Key.named(.down), .{}, a);
    try testing.expectEqualStrings("w", v.cmdlineGet().?);
    // `e` starts no entry: Up leaves the line alone.
    _ = try v.handleKey(Key.named(.backspace), .{}, a);
    _ = try v.handleKey(Key.char('e'), .{}, a);
    _ = try v.handleKey(Key.named(.up), .{}, a);
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

test "every chord a spec lists as the vim handler's own reaches that spec's command through the handler" {
    const specs = @import("../commands/specs.zig");
    const keymap = @import("../core/keymap.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var listed: usize = 0;
    for (specs.specs) |s| for (s.keys.vim_handler) |spec| {
        var v = Vim.init(testing.allocator, .{});
        defer v.deinit();
        var it = std.mem.tokenizeScalar(u8, spec, ' ');
        var last: InputResult = .ignored;
        while (it.next()) |tok| last = try v.handleKey(keymap.parseKeySpec(tok).?, .{}, a);
        try testing.expect(last == .app);
        // `]a` / `[a` carry their count; the command is the step's.
        const id: []const u8 = switch (last.app) {
            .session_step => |ss| if (ss.forward) "ai.focus_next_session" else "ai.focus_prev_session",
            else => @tagName(last.app.run_command),
        };
        try testing.expectEqualStrings(s.id, id);
        listed += 1;
    };
    // `Ctrl-W w` and `Ctrl-W W` at least.
    try testing.expect(listed >= 2);
}

test "own_keys: every row's keys, typed in its mode, do what its command does" {
    const keymap = @import("../core/keymap.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ctx: EditCtx = .{ .line_count = 3, .line_len = 4 };
    for (own_keys) |row| {
        var v = Vim.init(testing.allocator, .{});
        defer v.deinit();
        if (row.mode == .visual) _ = try v.handleKey(Key.char('v'), ctx, a);
        var seen: std.ArrayListUnmanaged(std.meta.Tag(EditOp)) = .empty;
        var it = std.mem.tokenizeScalar(u8, row.spec, ' ');
        var last: InputResult = .ignored;
        while (it.next()) |tok| {
            last = try v.handleKey(keymap.parseKeySpec(tok).?, ctx, a);
            if (last == .ops) for (last.ops) |op| try seen.append(a, std.meta.activeTag(op));
        }
        try testing.expect(last != .ignored);
        // The op the command's runner applies (`app/cmd_editor.zig`), or
        // the vim op that is the same act: Visual `d` deletes into the
        // register, `p` puts after the cursor.
        const want: []const std.meta.Tag(EditOp) = switch (row.command) {
            .@"editor.undo" => &.{.undo},
            .@"editor.redo" => &.{.redo},
            .@"editor.cut" => &.{ .delete_selection, .cut_selection },
            .@"editor.copy" => &.{.yank_selection},
            .@"editor.paste" => &.{ .paste_after, .paste },
            .@"editor.select_all" => &.{.select_line},
            else => &.{},
        };
        if (want.len == 0) {
            try testing.expect(last == .app);
            try testing.expectEqual(row.command, last.app.run_command);
            continue;
        }
        var found = false;
        for (seen.items) |tag| for (want) |w| {
            found = found or tag == w;
        };
        if (!found) std.debug.print("own_keys row `{s}` does not do what {s} does\n", .{ row.spec, @tagName(row.command) });
        try testing.expect(found);
        // `ggVG` ends in V-LINE from the first line to the last.
        if (row.command == .@"editor.select_all") {
            try testing.expectEqual(VimMode.visual_line, v.vmode);
            try testing.expect(last == .ops and last.ops.len > 0);
            try testing.expectEqual(@as(usize, 0), last.ops[last.ops.len - 1].move_to_line_keep_col);
        }
    }
}

test "ctrl+w H/J/K/L move the split; = r _ | + - > < n o w h d f T z reach their runners" {
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
        .{ .key = 'W', .id = .@"view.focus_prev_split" },
        .{ .key = 'h', .id = .@"view.focus_left" },
        .{ .key = 'd', .id = .@"view.split_goto_definition" },
        .{ .key = 'f', .id = .@"view.split_open_file_under_cursor" },
        .{ .key = 't', .id = .@"view.focus_top" },
        .{ .key = 'b', .id = .@"view.focus_bottom" },
        .{ .key = 'p', .id = .@"view.focus_previous" },
        // `:help CTRL-W_T`: the palette title and `docs/commands.md`
        // advertised this chord long before it was bound.
        .{ .key = 'T', .id = .@"view.move_to_new_tab" },
        // tmux's zoom letter — the split fills the page, again restores.
        .{ .key = 'z', .id = .@"view.toggle_zoom" },
    };
    for (cases) |c| {
        try testing.expect((try v.handleKey(Key.ctrl('w'), .{}, a)) == .consumed);
        const r = try v.handleKey(Key.char(c.key), .{}, a);
        try testing.expect(r == .app);
        try testing.expectEqual(c.id, r.app.run_command);
        try testing.expect(!v.isOpPending());
    }
    // A chord the prefix does not claim is still swallowed, not passed on.
    try testing.expect((try v.handleKey(Key.ctrl('w'), .{}, a)) == .consumed);
    try testing.expect((try v.handleKey(Key.char('Z'), .{}, a)) == .consumed);
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

test "[b / ]b are Neovim's :bprevious / :bnext" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char('['), .{}, a);
    var r = try v.handleKey(Key.char('b'), .{}, a);
    try testing.expect(r == .app);
    try testing.expectEqual(CommandId.@"buffer.prev", r.app.run_command);
    _ = try v.handleKey(Key.char(']'), .{}, a);
    r = try v.handleKey(Key.char('b'), .{}, a);
    try testing.expect(r == .app);
    try testing.expectEqual(CommandId.@"buffer.next", r.app.run_command);
}

test "]a / [a step the session ring, a count that many times" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char(']'), .{}, a);
    var r = try v.handleKey(Key.char('a'), .{}, a);
    try testing.expectEqual(@as(u32, 1), r.app.session_step.count);
    try testing.expect(r.app.session_step.forward);
    _ = try v.handleKey(Key.char('2'), .{}, a);
    _ = try v.handleKey(Key.char('['), .{}, a);
    r = try v.handleKey(Key.char('a'), .{}, a);
    try testing.expectEqual(@as(u32, 2), r.app.session_step.count);
    try testing.expect(!r.app.session_step.forward);
}

test "visual `:` opens the line on '<,'>, leaves Visual at once, and widens a linewise range before remembering it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    _ = try v.handleKey(Key.char('V'), .{}, a);
    _ = try v.handleKey(Key.char('j'), .{}, a);
    const r = try v.handleKey(Key.char(':'), .{ .cursor = 7 }, a);
    try testing.expect(v.isCmdlineOpen());
    try testing.expectEqualStrings("'<,'>", v.cmdlineGet().?);
    try testing.expectEqual(input.EditingMode.normal, v.mode());
    try testing.expectEqualSlices(EditOp, &.{ .normalize_linewise_selection, .remember_selection, .select_clear, .{ .set_cursor_byte = 7 } }, r.ops);
    // Esc on the line: Normal, nothing pending; `gv` still knows the shape.
    _ = try v.handleKey(Key.named(.esc), .{}, a);
    try testing.expect(!v.isCmdlineOpen());
    try testing.expectEqual(input.EditingMode.normal, v.mode());
    try testing.expectEqual(VimMode.visual_line, v.last_visual);
    // Charwise: no widening.
    _ = try v.handleKey(Key.char('v'), .{}, a);
    const c = try v.handleKey(Key.char(':'), .{ .cursor = 3 }, a);
    try testing.expectEqualSlices(EditOp, &.{ .remember_selection, .select_clear, .{ .set_cursor_byte = 3 } }, c.ops);
    try testing.expectEqual(input.EditingMode.normal, v.mode());
    _ = try v.handleKey(Key.named(.esc), .{}, a);
    // Block: the block anchor goes with it.
    _ = try v.handleKey(Key.ctrl('v'), .{}, a);
    const bl = try v.handleKey(Key.char(':'), .{}, a);
    try testing.expectEqualSlices(EditOp, &.{ .remember_selection, .block_select_clear }, bl.ops);
    try testing.expectEqual(input.EditingMode.normal, v.mode());
}

fn expectFind(op: EditOp, ch: u21, forward: bool, before: bool, inclusive: bool, repeat: bool, count: u32) !void {
    try testing.expect(op == .repeat);
    try testing.expectEqual(count, op.repeat.count);
    const f = op.repeat.inner.find_char_on_line;
    try testing.expectEqual(ch, f.ch);
    try testing.expectEqual(forward, f.forward);
    try testing.expectEqual(before, f.before);
    try testing.expectEqual(inclusive, f.inclusive);
    try testing.expectEqual(repeat, f.repeat);
}

test "f F t T ; , read their char the same way in Normal, Visual, V-LINE, V-BLOCK and operator-pending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = Vim.init(testing.allocator, .{});
    defer v.deinit();
    // Visual `f)`: a find for `)`, never the `)` sentence motion.
    _ = try v.handleKey(Key.char('v'), .{}, a);
    try testing.expect((try v.handleKey(Key.char('f'), .{}, a)) == .consumed);
    const vf = try v.handleKey(Key.char(')'), .{}, a);
    try testing.expectEqual(@as(usize, 1), vf.ops.len);
    try expectFind(vf.ops[0], ')', true, false, false, false, 1);
    try testing.expectEqual(VimMode.visual, v.vmode);
    // A count is the find's own: `3tx`.
    _ = try v.handleKey(Key.char('3'), .{}, a);
    _ = try v.handleKey(Key.char('t'), .{}, a);
    const vt = try v.handleKey(Key.char('x'), .{}, a);
    try expectFind(vt.ops[0], 'x', true, true, false, false, 3);
    // `;` / `,` repeat it, `,` the other way.
    try expectFind((try v.handleKey(Key.char(';'), .{}, a)).ops[0], 'x', true, true, false, true, 1);
    try expectFind((try v.handleKey(Key.char(','), .{}, a)).ops[0], 'x', false, true, false, true, 1);
    // Esc drops the pending `F` and stays in Visual.
    _ = try v.handleKey(Key.char('F'), .{}, a);
    try testing.expect((try v.handleKey(Key.named(.esc), .{}, a)) == .consumed);
    try testing.expectEqual(VimMode.visual, v.vmode);
    try testing.expect(v.prefix == .none);
    // V-LINE.
    _ = try v.handleKey(Key.char('V'), .{}, a);
    _ = try v.handleKey(Key.char('F'), .{}, a);
    try expectFind((try v.handleKey(Key.char('('), .{}, a)).ops[0], '(', false, false, false, false, 1);
    try testing.expectEqual(VimMode.visual_line, v.vmode);
    _ = try v.handleKey(Key.named(.esc), .{}, a);
    // V-BLOCK: the find, then the ragged `$` edge dropped.
    _ = try v.handleKey(Key.ctrl('v'), .{}, a);
    _ = try v.handleKey(Key.char('2'), .{}, a);
    _ = try v.handleKey(Key.char('f'), .{}, a);
    const bf = try v.handleKey(Key.char('x'), .{}, a);
    try testing.expectEqual(@as(usize, 2), bf.ops.len);
    try expectFind(bf.ops[0], 'x', true, false, false, false, 2);
    try testing.expectEqual(EditOp{ .block_eol = false }, bf.ops[1]);
    try testing.expectEqual(VimMode.visual_block, v.vmode);
    _ = try v.handleKey(Key.named(.esc), .{}, a);
    // Operator-pending: `d;` is inclusive, like `df`.
    _ = try v.handleKey(Key.char('d'), .{}, a);
    const d = try v.handleKey(Key.char(';'), .{}, a);
    try testing.expectEqual(EditOp.select_start, d.ops[0]);
    try expectFind(d.ops[1], 'x', true, false, true, true, 1);
    try testing.expectEqual(EditOp.delete_selection, d.ops[2]);
    try testing.expect(!v.isOpPending());
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
