//! The pluggable input layer (D4). A handler turns one key into a list
//! of `EditOp`s (the editor applies them), a `consumed` (half a chord,
//! typing on the `:` line), an `ignored` (the keymap gets a turn), or a
//! small closed `AppCommand`. The editor, buffer and render layers never
//! branch on which handler is active — only the statusline reads
//! `EditingMode`.
//!
//! `InputHandler` is a `union(enum)` dispatched with `inline else`; the
//! optional methods the Rust trait defaulted are `@hasDecl`-gated so a
//! handler implements only what it has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("../core/key.zig");
pub const Key = key_mod.Key;
pub const KeyCode = key_mod.KeyCode;
const command = @import("../core/command.zig");
pub const CommandId = command.CommandId;
pub const EditOp = @import("../editor/edit_op.zig").EditOp;
pub const Standard = @import("standard.zig").Standard;
pub const Vim = @import("vim.zig").Vim;

/// The only handler-derived fact the render layer may read.
pub const EditingMode = enum {
    /// Modeless handler — no mode chip; bar cursor.
    none,
    normal,
    insert,
    replace,
    visual,
    visual_line,
    visual_block,

    /// `null` ⇒ render no mode chip at all.
    pub fn label(m: EditingMode) ?[]const u8 {
        return switch (m) {
            .none => null,
            .normal => "NORMAL",
            .insert => "INSERT",
            .replace => "REPLACE",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .visual_block => "V-BLOCK",
        };
    }

    pub fn isVisual(m: EditingMode) bool {
        return switch (m) {
            .visual, .visual_line, .visual_block => true,
            else => false,
        };
    }
};

/// Which Insert-entering command a `<count>` is riding on (`:help count`).
/// `o` / `O` replicate as whole new lines; the other four replicate the
/// typed run in place at the insertion point.
pub const RepeatInsertKind = enum {
    open_below,
    open_above,
    /// `i` — insert where the cursor is.
    at_cursor,
    /// `I` — at the line's first non-blank.
    line_first_non_ws,
    /// `a` — one char on.
    after_cursor,
    /// `A` — at the line end.
    line_end,

    pub fn opensLine(self: RepeatInsertKind) bool {
        return self == .open_below or self == .open_above;
    }
};

/// A small, closed set of buffer/app-level intents the editor cannot
/// express. Bigger features are registered commands; this stays tiny.
/// String payloads live in the frame arena.
pub const AppCommand = union(enum) {
    save,
    /// A vim `:` line — the interpreter lives in the app.
    ex_command: []const u8,
    /// Bridge into the command registry (vim `gd` → `lsp.goto_definition`).
    run_command: CommandId,
    /// `.`; the count replaces the recorded change's count, 0 = none given.
    dot_repeat: u32,
    set_mark: u8,
    jump_to_mark_line: u8,
    jump_to_mark_exact: u8,
    /// `q<reg>`; `'@'` = anonymous. Idle ⇒ start; recording ⇒ stop.
    macro_record_into: u8,
    macro_replay_from: struct { reg: u8, count: u32 },
    block_insert_start: struct { append: bool },
    block_change_start,
    block_replace_with: struct { ch: u21 },
    filter_lines_from_cursor: struct { count: u32 },
    filter_paragraph_from_cursor: struct { around: bool },
    repeat_insert_start: struct { count: u32, kind: RepeatInsertKind },
    /// `d`/`y`/`c` + `G` / `gg` / `<n>G`: `target` null = buffer end,
    /// 0 = buffer start, n = 1-based line. `register` is a pending `"x`
    /// the op writes (`"+yG`), null for the unnamed one.
    operator_linewise_to: struct { op: u8, target: ?u32, register: ?u21 = null },
    cmdline_tab_complete,
    cmdline_popup_move: i8,
    /// Enter on the cmdline while a completion popup is showing.
    cmdline_enter: []const u8,
    /// `Ctrl+R Ctrl+W` (false) / `Ctrl+R Ctrl+A` (true) on the cmdline.
    cmdline_insert_cursor_word: bool,
    cmdline_paste_from_clipboard,
    flash_start: struct { a: u21, b: u21 },
    /// `{count}gt` (page `count`, past the end ⇒ the last page) and
    /// `{count}gT` (`count` pages back). Without a count the handler
    /// runs `tab.next` / `tab.prev` instead.
    tab_page: struct { count: u32, back: bool },
    /// `d'a` / `` y`a `` / `c'a`: `op` is `d`, `y` or `c`; `exact` is the
    /// backtick form (charwise, exclusive), else linewise to the mark's
    /// line. The buffer owns the mark, so it builds the range.
    operator_to_mark: struct { op: u8, mark: u8, exact: bool },
    /// `{count} Ctrl-W >` and friends: the active window's width
    /// (`width`) or height by `cells`, negative to shrink.
    split_resize: struct { width: bool, cells: i32 },
    /// `zf{motion}` / `zF`: apply these ops (they select the range),
    /// then fold the selection. Frame arena.
    fold_after: []const EditOp,
    /// `g<letter>{motion}` where the letter is claimed
    /// (`input/script_ops.zig`): apply these ops — they select the
    /// range, exactly as a built-in operator's motion does — then hand
    /// the range to the operator at `index`. Frame arena.
    script_operator: struct { ops: []const EditOp, index: u32, state: u16 = 0, linewise: bool = false },

    comptime {
        std.debug.assert(@typeInfo(AppCommand).@"union".fields.len == 27);
    }
};

/// Result of feeding one key to a handler.
pub const InputResult = union(enum) {
    /// Apply these to the active buffer's editor, in order. Frame arena.
    ops: []const EditOp,
    /// Consumed, no edit — the caller should still redraw.
    consumed,
    /// Not wanted — the keymap → command resolver gets it next.
    ignored,
    app: AppCommand,
};

/// Read-only buffer facts a handler may consult. Intentionally tiny.
/// // changed: D4 counted 13 scalars; the Rust struct has 12 — and
/// `register_empty` makes 13 again (a Visual `p` must know before it
/// deletes the selection).
pub const EditCtx = struct {
    cursor: usize = 0,
    line_len: usize = 0,
    line_idx: usize = 0,
    line_count: usize = 1,
    at_line_start: bool = true,
    at_line_end: bool = true,
    has_selection: bool = false,
    /// Char column where the line's leading whitespace ends (Smart Home).
    line_first_nonws_col: usize = 0,
    cursor_col: usize = 0,
    /// Closest find match strictly after the cursor (wraps); `gn`.
    next_find_match: ?[2]usize = null,
    prev_find_match: ?[2]usize = null,
    /// Text width when `[ui] wrap` is on; null aliases `gj` to `j`.
    wrap_width: ?usize = null,
    /// The unnamed register has nothing to put (Vim's E353).
    register_empty: bool = false,
};

/// What `Buffer.feedKey` reports back to the loop.
pub const BufferEvent = union(enum) {
    edited,
    redraw,
    unhandled: Key,
    app: AppCommand,
    noop,
};

pub const Style = enum { vim, standard };

/// The scalar config both handlers read at construction.
pub const Config = struct {
    tab_width: usize = 4,
    text_width: usize = 80,
    /// Tab inserts a `\t` instead of `tab_width` spaces (`.editorconfig`
    /// `indent_style = tab`).
    use_tabs: bool = false,
};

/// A which-key style hint for a pending prefix: the prefix label and its
/// continuations `(key, label, is_group)`.
pub const MenuHint = struct {
    prefix: []const u8,
    items: []const MenuItem,
};

pub const MenuItem = struct { key: u21, label: []const u8, group: bool = false };

pub const InputHandler = union(enum) {
    standard: Standard,
    vim: Vim,

    pub fn init(gpa: Allocator, which: Style, cfg: Config) InputHandler {
        return switch (which) {
            .standard => .{ .standard = Standard.init(cfg) },
            .vim => .{ .vim = Vim.init(gpa, cfg) },
        };
    }

    pub fn deinit(h: *InputHandler) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "deinit")) impl.deinit(),
        }
    }

    /// Re-read the scalars after construction (a `.editorconfig` landed
    /// for the file, `:set tabstop`).
    pub fn configure(h: *InputHandler, cfg: Config) void {
        switch (h.*) {
            inline else => |*impl| impl.configure(cfg),
        }
    }

    pub fn style(h: *const InputHandler) Style {
        return switch (h.*) {
            .standard => .standard,
            .vim => .vim,
        };
    }

    // ─── required ───

    pub fn handleKey(h: *InputHandler, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        return switch (h.*) {
            inline else => |*impl| impl.handleKey(key, ctx, arena),
        };
    }

    pub fn mode(h: *const InputHandler) EditingMode {
        return switch (h.*) {
            inline else => |*impl| impl.mode(),
        };
    }

    pub fn name(h: *const InputHandler) []const u8 {
        return switch (h.*) {
            inline else => |*impl| impl.name(),
        };
    }

    // ─── optional (defaulted in the Rust trait) ───

    /// Text for the statusline's keys area (`:` line, pending chord).
    pub fn pendingDisplay(h: *const InputHandler, arena: Allocator) Allocator.Error!?[]const u8 {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "pendingDisplay")) impl.pendingDisplay(arena) else null,
        };
    }

    pub fn isCmdlineOpen(h: *const InputHandler) bool {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "isCmdlineOpen")) impl.isCmdlineOpen() else false,
        };
    }

    pub fn isOpPending(h: *const InputHandler) bool {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "isOpPending")) impl.isOpPending() else false,
        };
    }

    pub fn onBlur(h: *InputHandler) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "onBlur")) impl.onBlur(),
        }
    }

    pub fn setExHistory(h: *InputHandler, entries: []const []const u8) Allocator.Error!void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "setExHistory")) try impl.setExHistory(entries),
        }
    }

    /// Oldest first. Borrowed from the handler.
    pub fn exHistory(h: *const InputHandler) []const []const u8 {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "exHistory")) impl.exHistory() else &.{},
        };
    }

    pub fn operatorMenuHint(h: *const InputHandler) ?MenuHint {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "operatorMenuHint")) impl.operatorMenuHint() else null,
        };
    }

    /// A key the handler must see before the chord chain, whatever the
    /// keymap binds it to: vim's Insert owns `Ctrl+N` / `Ctrl+P`
    /// (keyword completion) and `Ctrl+O` (one-shot Normal), which the
    /// vim profile binds to the tree and the file picker for Normal.
    pub fn reservesKey(h: *const InputHandler, k: Key) bool {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "reservesKey")) impl.reservesKey(k) else false,
        };
    }

    pub fn requestInsertMode(h: *InputHandler) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "requestInsertMode")) impl.requestInsertMode(),
        }
    }

    /// A recording the app started or stopped without a key (the
    /// statusline's macro chip): the handler's own `q` bookkeeping follows.
    pub fn setMacroRecording(h: *InputHandler, on: bool) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "setMacroRecording")) impl.setMacroRecording(on),
        }
    }

    pub fn requestVisualMode(h: *InputHandler) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "requestVisualMode")) impl.requestVisualMode(),
        }
    }

    pub fn cmdlineGet(h: *const InputHandler) ?[]const u8 {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "cmdlineGet")) impl.cmdlineGet() else null,
        };
    }

    pub fn cmdlineSet(h: *InputHandler, text: ?[]const u8) Allocator.Error!void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "cmdlineSet")) try impl.cmdlineSet(text),
        }
    }

    pub fn cmdlineCaret(h: *const InputHandler) ?usize {
        return switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "cmdlineCaret")) impl.cmdlineCaret() else null,
        };
    }

    pub fn setCmdlineCaret(h: *InputHandler, byte: usize) void {
        switch (h.*) {
            inline else => |*impl| if (@hasDecl(@TypeOf(impl.*), "setCmdlineCaret")) impl.setCmdlineCaret(byte),
        }
    }
};

/// `n` copies of `op`, collapsed into one `repeat` when `n > 1`. The
/// inner op is placed in the arena so the pointer outlives this frame.
pub fn repeated(arena: Allocator, op: EditOp, n: u32) Allocator.Error!InputResult {
    if (n > 1) {
        const inner = try arena.create(EditOp);
        inner.* = op;
        return .{ .ops = try arena.dupe(EditOp, &.{.{ .repeat = .{ .count = n, .inner = inner } }}) };
    }
    return .{ .ops = try arena.dupe(EditOp, &.{op}) };
}

pub fn ops(arena: Allocator, list: []const EditOp) Allocator.Error!InputResult {
    return .{ .ops = try arena.dupe(EditOp, list) };
}

test "editing mode labels; optional methods default on the standard handler" {
    try std.testing.expect(EditingMode.none.label() == null);
    try std.testing.expectEqualStrings("V-BLOCK", EditingMode.visual_block.label().?);
    try std.testing.expect(EditingMode.visual_line.isVisual() and !EditingMode.insert.isVisual());
    var h = InputHandler.init(std.testing.allocator, .standard, .{});
    defer h.deinit();
    try std.testing.expect(!h.isCmdlineOpen());
    try std.testing.expect(!h.isOpPending());
    try std.testing.expect(h.cmdlineGet() == null);
    try std.testing.expectEqual(@as(usize, 0), h.exHistory().len);
    try std.testing.expectEqual(EditingMode.none, h.mode());
    try std.testing.expectEqualStrings("standard", h.name());
    h.onBlur();
    h.requestInsertMode();
    var v = InputHandler.init(std.testing.allocator, .vim, .{});
    defer v.deinit();
    try std.testing.expectEqual(EditingMode.normal, v.mode());
    v.requestInsertMode();
    try std.testing.expectEqual(EditingMode.insert, v.mode());
    v.onBlur();
    try std.testing.expectEqual(EditingMode.normal, v.mode());
}
