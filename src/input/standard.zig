//! Modeless, VS Code-style keymap. Typing inserts; arrows move (Shift
//! extends a selection); Ctrl+C/X/V/Z/Y/A do the usual; Ctrl+←/→ are
//! word motions; Ctrl+Backspace/Delete delete words; Ctrl+/ toggles a
//! line comment; Alt+↑/↓ move the line; Ctrl+S saves; Esc clears a
//! selection. Anything else is `.ignored` so the keymap gets it.
//! `own_keys` names the modified chords it answers itself, so a menu
//! row can print them (`info_view_copy.chordOf`).
//!
//! `[keys.standard]` overrides are a config-phase item. TODO(config)

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("mod.zig");
const Key = input.Key;
const EditOp = input.EditOp;
const EditCtx = input.EditCtx;
const InputResult = input.InputResult;
const ops = input.ops;

/// A modified chord the handler answers itself, and the command that
/// does the same from a menu or the palette (null: none does).
pub const OwnKey = struct {
    spec: []const u8,
    command: ?input.CommandId,
};

/// Every Ctrl chord `handleKey` acts on, by key spec. The keymap does
/// not bind most of them — the handler owns them — so this is how the
/// menus, the hover help and the welcome screen learn that Cut is
/// Ctrl+X under this profile. `Ctrl+S` and `Ctrl+D` are bound in the
/// keymap too, to the same commands; the keymap reaches them first. A
/// test below holds the table to the switch in both directions.
pub const own_keys = [_]OwnKey{
    .{ .spec = "ctrl+x", .command = .@"editor.cut" },
    .{ .spec = "ctrl+c", .command = .@"editor.copy" },
    .{ .spec = "ctrl+v", .command = .@"editor.paste" },
    .{ .spec = "ctrl+z", .command = .@"editor.undo" },
    .{ .spec = "ctrl+y", .command = .@"editor.redo" },
    .{ .spec = "ctrl+shift+z", .command = .@"editor.redo" },
    .{ .spec = "ctrl+a", .command = .@"editor.select_all" },
    .{ .spec = "ctrl+/", .command = .@"editor.toggle_line_comment" },
    .{ .spec = "ctrl+s", .command = .@"file.save" },
    .{ .spec = "ctrl+d", .command = .@"editor.add_cursor_at_next_word" },
    // Select to the line's end: no command runs it.
    .{ .spec = "ctrl+l", .command = null },
};

pub const Standard = struct {
    tab_width: usize,
    use_tabs: bool,

    pub fn init(cfg: input.Config) Standard {
        return .{ .tab_width = @max(cfg.tab_width, 1), .use_tabs = cfg.use_tabs };
    }

    pub fn configure(self: *Standard, cfg: input.Config) void {
        self.tab_width = @max(cfg.tab_width, 1);
        self.use_tabs = cfg.use_tabs;
    }

    pub fn mode(_: *const Standard) input.EditingMode {
        return .none;
    }

    pub fn name(_: *const Standard) []const u8 {
        return "standard";
    }

    pub fn handleKey(self: *Standard, key: Key, ctx: EditCtx, arena: Allocator) Allocator.Error!InputResult {
        const ctrl = key.mods.ctrl;
        const alt = key.mods.alt;
        const shift = key.mods.shift;
        const sup = key.mods.super;

        if (key.typed()) |c| return ops(arena, &.{.{ .insert_char = c }});

        const Mv = struct {
            shift: bool,
            has_sel: bool,
            arena: Allocator,
            fn go(m: @This(), op: EditOp) Allocator.Error!InputResult {
                if (m.shift) {
                    if (m.has_sel) return ops(m.arena, &.{op});
                    return ops(m.arena, &.{ .select_start, op });
                }
                return ops(m.arena, &.{ .select_clear, op });
            }
            fn smartHome(m: @This(), c: EditCtx) Allocator.Error!InputResult {
                if (c.line_first_nonws_col > 0 and c.cursor_col != c.line_first_nonws_col) return m.go(.move_line_first_non_ws);
                return m.go(.move_line_start);
            }
        };
        const mv: Mv = .{ .shift = shift, .has_sel = ctx.has_selection, .arena = arena };

        switch (key.code) {
            .char => |raw| {
                if (!ctrl or alt) {
                    if (alt and !ctrl) switch (raw) {
                        'k', 'K' => return ops(arena, &.{.move_line_up}),
                        'j', 'J' => return ops(arena, &.{.move_line_down}),
                        else => {},
                    };
                    return .ignored;
                }
                const c = std.ascii.toLower(@intCast(@min(raw, 0x7F)));
                return switch (c) {
                    'a' => ops(arena, &.{.select_all}),
                    // changed: Ctrl+C / Ctrl+X / Ctrl+V are the OS clipboard, so
                    // each op list opens with the `"+` hint — the same register
                    // mechanism vim's `"+y` uses, nothing for the editor to branch on.
                    'c' => ops(arena, &.{ os_reg, if (ctx.has_selection) .yank_selection else .yank_line }),
                    'x' => if (ctx.has_selection) ops(arena, &.{ os_reg, .cut_selection }) else ops(arena, &.{ os_reg, .yank_line, .delete_line }),
                    'v' => ops(arena, &.{ os_reg, .paste }),
                    'z' => ops(arena, &.{if (shift) .redo else .undo}),
                    'y' => ops(arena, &.{.redo}),
                    '/' => ops(arena, &.{.toggle_line_comment}),
                    's' => .{ .app = .save },
                    'd' => if (shift) .ignored else .{ .app = .{ .run_command = .@"editor.add_cursor_at_next_word" } },
                    'l' => ops(arena, &.{.select_line_to_end}),
                    else => .ignored,
                };
            },
            .enter => {
                if (ctrl and !alt and shift) return ops(arena, &.{ .move_line_start, .insert_newline, .move_up });
                if (ctrl and !alt) return ops(arena, &.{ .move_line_end, .insert_newline });
                return ops(arena, &.{.insert_newline});
            },
            .tab => {
                if (shift) return ops(arena, &.{.outdent});
                if (ctx.has_selection) return ops(arena, &.{.indent});
                return ops(arena, &.{.{ .insert_str = if (self.use_tabs) "\t" else try spaces(arena, self.tab_width) }});
            },
            .backtab => return ops(arena, &.{.outdent}),
            .backspace => return ops(arena, &.{if (ctrl and !alt) .delete_word_left else .backspace}),
            .delete => return ops(arena, &.{if (ctrl and !alt) .delete_word_right else .delete_forward}),
            .left => {
                if ((alt and !ctrl) or (ctrl and !alt)) return mv.go(.move_word_left);
                if (sup) return mv.smartHome(ctx);
                return mv.go(.move_left);
            },
            .right => {
                if ((alt and !ctrl) or (ctrl and !alt)) return mv.go(.move_word_right);
                if (sup) return mv.go(.move_line_end);
                return mv.go(.move_right);
            },
            .up => {
                if (alt and shift) return ops(arena, &.{ .duplicate_line, .move_up });
                if (alt) return ops(arena, &.{.move_line_up});
                return mv.go(.move_up);
            },
            .down => {
                if (alt and shift) return ops(arena, &.{.duplicate_line});
                if (alt) return ops(arena, &.{.move_line_down});
                return mv.go(.move_down);
            },
            .home => {
                if (ctrl and !alt) return mv.go(.move_buffer_start);
                return mv.smartHome(ctx);
            },
            .end => {
                if (ctrl and !alt) {
                    if (shift) {
                        if (ctx.has_selection) return ops(arena, &.{ .move_buffer_end, .move_line_end });
                        return ops(arena, &.{ .select_start, .move_buffer_end, .move_line_end });
                    }
                    return ops(arena, &.{ .select_clear, .move_buffer_end, .move_line_end });
                }
                return mv.go(.move_line_end);
            },
            .page_up => return mv.go(.page_up),
            .page_down => return mv.go(.page_down),
            .esc => {
                if (ctx.has_selection) return ops(arena, &.{ .select_clear, .clear_extra_cursors });
                return ops(arena, &.{.clear_extra_cursors});
            },
            else => return .ignored,
        }
    }
};

fn spaces(arena: Allocator, n: usize) Allocator.Error![]const u8 {
    const s = try arena.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Chord = @import("../core/key.zig").Chord;

/// The `"+` hint that opens every Ctrl+C / Ctrl+X / Ctrl+V op list.
const os_reg: EditOp = .{ .set_register_hint = '+' };

fn feed(h: *Standard, arena: Allocator, key: Key, ctx: EditCtx) ![]const EditOp {
    const r = try h.handleKey(key, ctx, arena);
    return switch (r) {
        .ops => |o| o,
        else => error.NotOps,
    };
}

test "standard: typing, enter, tab, backspace, word deletes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h = Standard.init(.{ .tab_width = 2 });
    const ctx: EditCtx = .{};
    try testing.expectEqual(EditOp{ .insert_char = 'A' }, (try feed(&h, a, .{ .code = .{ .char = 'A' }, .mods = .{ .shift = true } }, ctx))[0]);
    try testing.expectEqual(EditOp.insert_newline, (try feed(&h, a, Key.named(.enter), ctx))[0]);
    try testing.expectEqualStrings("  ", (try feed(&h, a, Key.named(.tab), ctx))[0].insert_str);
    try testing.expectEqual(EditOp.indent, (try feed(&h, a, Key.named(.tab), .{ .has_selection = true }))[0]);
    try testing.expectEqual(EditOp.backspace, (try feed(&h, a, Key.named(.backspace), ctx))[0]);
    try testing.expectEqual(EditOp.delete_word_left, (try feed(&h, a, .{ .code = .backspace, .mods = .{ .ctrl = true } }, ctx))[0]);
    try testing.expectEqual(EditOp.delete_word_right, (try feed(&h, a, .{ .code = .delete, .mods = .{ .ctrl = true } }, ctx))[0]);
}

test "standard: arrows clear or extend the selection; ctrl/alt arrows are word motions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h = Standard.init(.{});
    const plain = try feed(&h, a, Key.named(.right), .{});
    try testing.expectEqualSlices(EditOp, &.{ .select_clear, .move_right }, plain);
    const shifted = try feed(&h, a, .{ .code = .right, .mods = .{ .shift = true } }, .{});
    try testing.expectEqualSlices(EditOp, &.{ .select_start, .move_right }, shifted);
    const extend = try feed(&h, a, .{ .code = .right, .mods = .{ .shift = true } }, .{ .has_selection = true });
    try testing.expectEqualSlices(EditOp, &.{.move_right}, extend);
    const word = try feed(&h, a, .{ .code = .left, .mods = .{ .ctrl = true } }, .{});
    try testing.expectEqualSlices(EditOp, &.{ .select_clear, .move_word_left }, word);
    const alt_word = try feed(&h, a, .{ .code = .right, .mods = .{ .alt = true } }, .{});
    try testing.expectEqualSlices(EditOp, &.{ .select_clear, .move_word_right }, alt_word);
    // Smart Home toggles between first-non-ws and column 0.
    const home1 = try feed(&h, a, Key.named(.home), .{ .line_first_nonws_col = 4, .cursor_col = 8 });
    try testing.expectEqual(EditOp.move_line_first_non_ws, home1[1]);
    const home2 = try feed(&h, a, Key.named(.home), .{ .line_first_nonws_col = 4, .cursor_col = 4 });
    try testing.expectEqual(EditOp.move_line_start, home2[1]);
    const pgdn = try feed(&h, a, .{ .code = .page_down, .mods = .{ .shift = true } }, .{});
    try testing.expectEqualSlices(EditOp, &.{ .select_start, .page_down }, pgdn);
}

test "standard: ctrl chords, save, ctrl+l, alt+shift duplicate, esc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h = Standard.init(.{});
    try testing.expectEqual(EditOp.select_all, (try feed(&h, a, Key.ctrl('a'), .{}))[0]);
    // The clipboard chords open with the `"+` hint: they are the OS clipboard.
    try testing.expectEqualSlices(EditOp, &.{ os_reg, .yank_line }, try feed(&h, a, Key.ctrl('c'), .{}));
    try testing.expectEqualSlices(EditOp, &.{ os_reg, .yank_selection }, try feed(&h, a, Key.ctrl('c'), .{ .has_selection = true }));
    try testing.expectEqualSlices(EditOp, &.{ os_reg, .yank_line, .delete_line }, try feed(&h, a, Key.ctrl('x'), .{}));
    try testing.expectEqualSlices(EditOp, &.{ os_reg, .cut_selection }, try feed(&h, a, Key.ctrl('x'), .{ .has_selection = true }));
    try testing.expectEqualSlices(EditOp, &.{ os_reg, .paste }, try feed(&h, a, Key.ctrl('v'), .{}));
    try testing.expectEqual(EditOp.undo, (try feed(&h, a, Key.ctrl('z'), .{}))[0]);
    try testing.expectEqual(EditOp.redo, (try feed(&h, a, .{ .code = .{ .char = 'Z' }, .mods = .{ .ctrl = true, .shift = true } }, .{}))[0]);
    try testing.expectEqual(EditOp.redo, (try feed(&h, a, Key.ctrl('y'), .{}))[0]);
    try testing.expectEqual(EditOp.select_line_to_end, (try feed(&h, a, Key.ctrl('l'), .{}))[0]);
    try testing.expectEqual(EditOp.toggle_line_comment, (try feed(&h, a, Key.ctrl('/'), .{}))[0]);
    const save = try h.handleKey(Key.ctrl('s'), .{}, a);
    try testing.expectEqual(input.AppCommand.save, save.app);
    try testing.expectEqualSlices(EditOp, &.{ .duplicate_line, .move_up }, try feed(&h, a, .{ .code = .up, .mods = .{ .alt = true, .shift = true } }, .{}));
    try testing.expectEqualSlices(EditOp, &.{.duplicate_line}, try feed(&h, a, .{ .code = .down, .mods = .{ .alt = true, .shift = true } }, .{}));
    try testing.expectEqualSlices(EditOp, &.{.move_line_up}, try feed(&h, a, .{ .code = .up, .mods = .{ .alt = true } }, .{}));
    try testing.expectEqualSlices(EditOp, &.{ .select_clear, .clear_extra_cursors }, try feed(&h, a, Key.named(.esc), .{ .has_selection = true }));
    try testing.expectEqualSlices(EditOp, &.{ .move_line_end, .insert_newline }, try feed(&h, a, .{ .code = .enter, .mods = .{ .ctrl = true } }, .{}));
    // Unknown chords fall through to the keymap.
    try testing.expectEqual(InputResult.ignored, try h.handleKey(Key.ctrl('p'), .{}, a));
    try testing.expectEqual(InputResult.ignored, try h.handleKey(.{ .code = .{ .f = 5 } }, .{}, a));
}

test "own_keys is the handler's own Ctrl chords: every row is a key it acts on, as its command does, and every Ctrl key it acts on is a row" {
    const keymap = @import("../core/keymap.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h = Standard.init(.{});
    const sel: EditCtx = .{ .has_selection = true };
    // Each row's key does what its command does: the op the command's
    // runner applies to a selection (`app/cmd_editor.zig`), or the
    // same command run through the registry.
    for (own_keys) |row| {
        var buf: [keymap.max_seq]Chord = undefined;
        const seq = keymap.parseKeySeqBuf(row.spec, &buf) orelse return error.UnparsedSpec;
        try testing.expectEqual(@as(usize, 1), seq.len);
        const r = try h.handleKey(.{ .code = seq[0].code, .mods = seq[0].mods }, sel, a);
        try testing.expect(r != .ignored);
        const id = row.command orelse continue;
        const want: ?std.meta.Tag(EditOp) = switch (id) {
            .@"editor.cut" => .cut_selection,
            .@"editor.copy" => .yank_selection,
            .@"editor.paste" => .paste,
            .@"editor.undo" => .undo,
            .@"editor.redo" => .redo,
            .@"editor.select_all" => .select_all,
            .@"editor.toggle_line_comment" => .toggle_line_comment,
            else => null,
        };
        if (want) |tag| {
            var found = false;
            for (r.ops) |op| found = found or std.meta.activeTag(op) == tag;
            try testing.expect(found);
        } else switch (r.app) {
            .save => try testing.expectEqual(input.CommandId.@"file.save", id),
            .run_command => |c| try testing.expectEqual(id, c),
            else => return error.UnexpectedAppCommand,
        }
    }
    // The other way: every Ctrl+<char> the switch answers is a row, and
    // so is every Ctrl+Shift+<char> that means something its unshifted
    // twin does not (Ctrl+Shift+Z is redo, not undo).
    var c: u8 = 0x21;
    while (c < 0x7F) : (c += 1) {
        if (std.ascii.isUpper(c)) continue;
        const plain = try h.handleKey(Key.ctrl(c), sel, a);
        if (plain != .ignored) try testing.expect(ownKeyOf(.{ .code = .{ .char = c }, .mods = .{ .ctrl = true } }));
        if (!std.ascii.isLower(c)) continue;
        const shifted = try h.handleKey(.{ .code = .{ .char = std.ascii.toUpper(c) }, .mods = .{ .ctrl = true, .shift = true } }, sel, a);
        const same = std.meta.eql(std.meta.activeTag(plain), std.meta.activeTag(shifted)) and switch (plain) {
            .ops => |p| p.len == shifted.ops.len and for (p, shifted.ops) |x, y| {
                if (std.meta.activeTag(x) != std.meta.activeTag(y)) break false;
            } else true,
            else => true,
        };
        if (!same and shifted != .ignored) try testing.expect(ownKeyOf(.{ .code = .{ .char = c }, .mods = .{ .ctrl = true, .shift = true } }));
    }
}

/// Whether `own_keys` has a row for the chord `k` normalises to.
fn ownKeyOf(k: Key) bool {
    const keymap = @import("../core/keymap.zig");
    const want = Chord.of(k);
    for (own_keys) |row| {
        var buf: [keymap.max_seq]Chord = undefined;
        const seq = keymap.parseKeySeqBuf(row.spec, &buf) orelse continue;
        if (seq.len == 1 and seq[0].eql(want)) return true;
    }
    std.debug.print("standard handler acts on {any} but own_keys has no row for it\n", .{want});
    return false;
}
