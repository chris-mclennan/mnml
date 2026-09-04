//! `Buffer` — an `Editor` plus the handler that drives it, the file it
//! came from, marks, folds, and the two cross-iteration op holders
//! (dot-repeat and macro registers). `feedKey` is THE seam: the only
//! place an `InputResult` is destructured.
//!
//! Buffer-local `AppCommand`s (marks, dot-repeat, macros) are handled
//! here and come back as `.edited` / `.redraw`; everything else bubbles
//! up as `.app` for the app to run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const Pos = editor_mod.Pos;
pub const Clipboard = editor_mod.Clipboard;
const edit_op = @import("edit_op.zig");
const EditOp = edit_op.EditOp;
const input = @import("../input/mod.zig");
pub const InputHandler = input.InputHandler;
pub const BufferEvent = input.BufferEvent;
pub const AppCommand = input.AppCommand;
pub const EditCtx = input.EditCtx;
pub const Key = input.Key;

pub const Recording = struct { reg: u8, keys: std.ArrayList(Key) = .empty };

pub const Buffer = struct {
    gpa: Allocator,
    editor: Editor,
    input: InputHandler,
    /// Owned. Null for a scratch buffer.
    path: ?[]u8 = null,
    dirty: bool = false,
    /// The text as of the last load / save — `dirty` is a comparison.
    saved_text: []u8,
    /// `m<letter>` positions.
    marks: std.AutoHashMapUnmanaged(u8, Pos) = .empty,
    /// Closed folds: start line → end line.
    folds: std.AutoArrayHashMapUnmanaged(usize, usize) = .empty,
    /// File extension used for language-specific behaviour. Owned.
    language: ?[]u8 = null,
    read_only: bool = false,
    /// `@tagName` of the last op the editor refused with `Unsupported`,
    /// for the app to toast. Static string.
    last_unsupported: ?[]const u8 = null,
    /// The find matches nearest the cursor (`gn` / `gN`), byte ranges.
    /// The find state lives with the app; it seeds these before a key.
    find_next: ?[2]usize = null,
    find_prev: ?[2]usize = null,

    /// Dot-repeat: the last change, gpa-owned ops.
    dot: ?[]EditOp = null,
    dot_pending: std.ArrayList(EditOp) = .empty,
    /// The pending record is still open because the change entered
    /// insert/replace mode — typed keys keep joining it until Esc.
    dot_collecting: bool = false,
    replaying_dot: bool = false,

    /// Macro registers: raw keys, replayed through `feedKey`.
    macros: std.AutoHashMapUnmanaged(u8, []Key) = .empty,
    recording: ?Recording = null,
    last_macro: ?u8 = null,
    replay_depth: u8 = 0,

    pub const max_replay_depth = 8;

    pub fn init(gpa: Allocator, text: []const u8, style: input.Style, cfg: input.Config) Allocator.Error!Buffer {
        var ed = try Editor.init(gpa, text);
        errdefer ed.deinit();
        ed.tab_width = @max(cfg.tab_width, 1);
        const saved = try gpa.dupe(u8, text);
        errdefer gpa.free(saved);
        return .{
            .gpa = gpa,
            .editor = ed,
            .input = InputHandler.init(gpa, style, cfg),
            .saved_text = saved,
        };
    }

    pub fn deinit(self: *Buffer) void {
        const gpa = self.gpa;
        self.editor.deinit();
        self.input.deinit();
        if (self.path) |p| gpa.free(p);
        gpa.free(self.saved_text);
        self.marks.deinit(gpa);
        self.folds.deinit(gpa);
        if (self.language) |l| gpa.free(l);
        if (self.dot) |d| freeOps(gpa, d);
        for (self.dot_pending.items) |o| o.free(gpa);
        self.dot_pending.deinit(gpa);
        var it = self.macros.valueIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.macros.deinit(gpa);
        if (self.recording) |*r| r.keys.deinit(gpa);
    }

    fn freeOps(gpa: Allocator, list: []EditOp) void {
        for (list) |o| o.free(gpa);
        gpa.free(list);
    }

    // ─── files ───

    pub const LoadError = Allocator.Error || Io.Dir.ReadFileAllocError;

    /// Read `path` into a new buffer. A missing file is an error — the
    /// app decides whether that means "new file".
    pub fn load(gpa: Allocator, io: Io, path: []const u8, style: input.Style, cfg: input.Config) LoadError!Buffer {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(text);
        var buf = try init(gpa, text, style, cfg);
        errdefer buf.deinit();
        try buf.setPath(path);
        return buf;
    }

    pub fn setPath(self: *Buffer, path: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.path) |p| self.gpa.free(p);
        self.path = copy;
        if (self.language) |l| self.gpa.free(l);
        self.language = null;
        const ext = std.fs.path.extension(path);
        if (ext.len > 1) self.language = try self.gpa.dupe(u8, ext[1..]);
    }

    pub const SaveError = Allocator.Error || Io.Dir.WriteFileError || error{NoPath};

    pub fn save(self: *Buffer, io: Io) SaveError!void {
        const path = self.path orelse return error.NoPath;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = self.editor.bytes() });
        try self.markSaved();
    }

    /// Record the current text as the on-disk text.
    pub fn markSaved(self: *Buffer) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, self.editor.bytes());
        self.gpa.free(self.saved_text);
        self.saved_text = copy;
        self.dirty = false;
    }

    fn recomputeDirty(self: *Buffer) void {
        self.dirty = !std.mem.eql(u8, self.editor.bytes(), self.saved_text);
    }

    pub fn setInputStyle(self: *Buffer, style: input.Style, cfg: input.Config) void {
        if (self.input.style() == style) return;
        self.input.deinit();
        self.input = InputHandler.init(self.gpa, style, cfg);
        self.editor.anchor = null;
    }

    // ─── the seam ───

    pub fn makeCtx(self: *const Buffer, wrap_width: ?usize) EditCtx {
        const ed = &self.editor;
        const line = ed.currentLine();
        const ls = ed.lineStart(line);
        const le = ed.lineEnd(line);
        return .{
            .cursor = ed.cursor,
            .line_len = le - ls,
            .line_idx = line,
            .line_count = ed.lineCount(),
            .at_line_start = ed.cursor == ls,
            .at_line_end = ed.cursor >= le,
            .has_selection = ed.hasSelection(),
            .line_first_nonws_col = ed.colAtByte(ed.firstNonWs(line)),
            .cursor_col = ed.colAtByte(ed.cursor),
            .next_find_match = self.find_next,
            .prev_find_match = self.find_prev,
            .wrap_width = wrap_width,
        };
    }

    /// Feed one key through the handler → editor. `viewport_rows` sizes
    /// page motions; `wrap_width` is non-null when `[ui] wrap` is on.
    /// `arena` is the frame arena.
    pub fn feedKey(self: *Buffer, key: Key, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        if (self.read_only) return .{ .unhandled = key };
        if (self.recording) |*r| try r.keys.append(self.gpa, key);
        const ctx = self.makeCtx(wrap_width);
        const result = try self.input.handleKey(key, ctx, arena);
        switch (result) {
            .ops => |list| {
                const changed = try self.applyOps(list, clip, viewport_rows, arena);
                try self.trackDot(list);
                return if (changed) .edited else .redraw;
            },
            .consumed => return .redraw,
            .ignored => return .{ .unhandled = key },
            .app => |cmd| return self.handleApp(cmd, clip, viewport_rows, wrap_width, arena),
        }
    }

    /// Apply ops that did not come from a key (LSP edits, replays).
    /// Returns whether the text changed. An op the editor refuses is
    /// recorded in `last_unsupported` and skipped.
    pub fn applyOps(self: *Buffer, list: []const EditOp, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!bool {
        if (self.read_only) return false;
        var changed = false;
        for (list) |op| {
            const cursor_line_before = self.editor.currentLine();
            const lines_before = self.editor.lineCount();
            const out = self.editor.apply(op, viewport_rows, clip, arena) catch |err| switch (err) {
                error.Unsupported => {
                    self.last_unsupported = @tagName(op);
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (out.buffer_changed) {
                const delta: isize = @as(isize, @intCast(self.editor.lineCount())) - @as(isize, @intCast(lines_before));
                if (delta != 0) try self.shiftFoldsAfter(cursor_line_before, delta);
                changed = true;
            }
        }
        if (changed) self.recomputeDirty();
        return changed;
    }

    fn shiftFoldsAfter(self: *Buffer, line: usize, delta: isize) Allocator.Error!void {
        // Mutate the entry arrays in place, then rebuild the index; the
        // entry count never grows here.
        var i: usize = 0;
        while (i < self.folds.count()) {
            const start = self.folds.keys()[i];
            if (start <= line) {
                i += 1;
                continue;
            }
            const ns: isize = @as(isize, @intCast(start)) + delta;
            const ne: isize = @as(isize, @intCast(self.folds.values()[i])) + delta;
            if (ns < 0 or ne < ns) {
                self.folds.orderedRemoveAt(i);
                continue;
            }
            self.folds.keys()[i] = @intCast(ns);
            self.folds.values()[i] = @intCast(ne);
            i += 1;
        }
        try self.folds.reIndex(self.gpa);
    }

    // ─── dot-repeat ───

    fn trackDot(self: *Buffer, list: []const EditOp) Allocator.Error!void {
        if (self.replaying_dot) return;
        const in_insert = switch (self.input.mode()) {
            .insert, .replace => true,
            else => false,
        };
        if (self.dot_collecting) {
            try self.appendDot(list);
            if (!in_insert) try self.finishDot();
            return;
        }
        var mutates = false;
        for (list) |o| {
            if (o.isMutation() and !o.isUndoOrRedo()) mutates = true;
        }
        if (!mutates) return;
        for (self.dot_pending.items) |o| o.free(self.gpa);
        self.dot_pending.clearRetainingCapacity();
        try self.appendDot(list);
        if (in_insert) {
            self.dot_collecting = true;
        } else {
            try self.finishDot();
        }
    }

    fn appendDot(self: *Buffer, list: []const EditOp) Allocator.Error!void {
        for (list) |o| {
            const copy = try o.dupe(self.gpa);
            errdefer copy.free(self.gpa);
            try self.dot_pending.append(self.gpa, copy);
        }
    }

    fn finishDot(self: *Buffer) Allocator.Error!void {
        self.dot_collecting = false;
        if (self.dot) |d| freeOps(self.gpa, d);
        self.dot = try self.dot_pending.toOwnedSlice(self.gpa);
    }

    fn dotRepeat(self: *Buffer, count: u32, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!BufferEvent {
        const d = self.dot orelse return .noop;
        self.replaying_dot = true;
        defer self.replaying_dot = false;
        var changed = false;
        for (0..@max(count, 1)) |_| {
            if (try self.applyOps(d, clip, viewport_rows, arena)) changed = true;
        }
        // A replayed change that entered insert mode leaves the handler
        // there; the replay already typed the text, so drop back.
        if (self.input.mode() == .insert or self.input.mode() == .replace) self.input.onBlur();
        return if (changed) .edited else .redraw;
    }

    // ─── macros ───

    fn macroToggle(self: *Buffer, reg: u8) Allocator.Error!BufferEvent {
        if (self.recording) |*r| {
            // The `q` that stopped us was recorded too — drop it.
            _ = r.keys.pop();
            const keys = try r.keys.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(keys);
            if (self.macros.fetchRemove(r.reg)) |old| self.gpa.free(old.value);
            try self.macros.put(self.gpa, r.reg, keys);
            self.last_macro = r.reg;
            self.recording = null;
            return .redraw;
        }
        // `q<reg>` arrived before recording started, so neither key is in
        // the register.
        self.recording = .{ .reg = reg };
        return .redraw;
    }

    fn macroReplay(self: *Buffer, reg_in: u8, count: u32, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        const reg = if (reg_in == '@') (self.last_macro orelse return .noop) else reg_in;
        const keys = self.macros.get(reg) orelse return .noop;
        if (self.replay_depth >= max_replay_depth) return .noop;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        self.last_macro = reg;
        var edited = false;
        for (0..@max(count, 1)) |_| {
            for (keys) |k| {
                const ev = try self.feedKey(k, clip, viewport_rows, wrap_width, arena);
                if (ev == .edited) edited = true;
            }
        }
        return if (edited) .edited else .redraw;
    }

    pub fn isRecording(self: *const Buffer) bool {
        return self.recording != null;
    }

    // ─── app commands handled here ───

    fn handleApp(self: *Buffer, cmd: AppCommand, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        switch (cmd) {
            .dot_repeat => |n| return self.dotRepeat(n, clip, viewport_rows, arena),
            .set_mark => |c| {
                try self.marks.put(self.gpa, c, self.editor.rowCol());
                return .redraw;
            },
            .jump_to_mark_line => |c| {
                const p = self.marks.get(c) orelse return .noop;
                const row = @min(p.row, self.editor.lineCount() - 1);
                self.editor.cursor = self.editor.firstNonWs(row);
                self.editor.goal_col = null;
                return .redraw;
            },
            .jump_to_mark_exact => |c| {
                const p = self.marks.get(c) orelse return .noop;
                self.editor.placeCursor(@min(p.row, self.editor.lineCount() - 1), p.col);
                return .redraw;
            },
            .macro_record_into => |reg| return self.macroToggle(reg),
            .macro_replay_from => |m| return self.macroReplay(m.reg, m.count, clip, viewport_rows, wrap_width, arena),
            else => return .{ .app = cmd },
        }
    }
};

// ─── tests: the feed harness ────────────────────────────────────────────

const testing = std.testing;

/// Parse `<esc>`, `<cr>`, `<c-r>`, `<a-x>`, `<s-down>`… and plain chars
/// into keys. `<lt>` is a literal `<`.
pub fn parseKeys(gpa: Allocator, spec: []const u8) ![]Key {
    var out = std.ArrayList(Key).empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < spec.len) {
        if (spec[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, spec, i, '>')) |close| {
                const tok = spec[i + 1 .. close];
                if (parseToken(tok)) |k| {
                    try out.append(gpa, k);
                    i = close + 1;
                    continue;
                }
            }
        }
        const n = std.unicode.utf8ByteSequenceLength(spec[i]) catch 1;
        const c = std.unicode.utf8Decode(spec[i .. i + n]) catch spec[i];
        try out.append(gpa, Key.char(c));
        i += n;
    }
    return out.toOwnedSlice(gpa);
}

fn parseToken(tok: []const u8) ?Key {
    var mods: @import("../core/key.zig").Mods = .{};
    var rest = tok;
    while (rest.len > 2 and rest[1] == '-') {
        switch (std.ascii.toLower(rest[0])) {
            'c' => mods.ctrl = true,
            'a', 'm' => mods.alt = true,
            's' => mods.shift = true,
            'd' => mods.super = true,
            else => return null,
        }
        rest = rest[2..];
    }
    const names = .{
        .{ "esc", .esc },    .{ "cr", .enter },  .{ "enter", .enter },  .{ "tab", .tab },        .{ "bs", .backspace },
        .{ "del", .delete }, .{ "left", .left }, .{ "right", .right },  .{ "up", .up },          .{ "down", .down },
        .{ "home", .home },  .{ "end", .end },   .{ "pgup", .page_up }, .{ "pgdn", .page_down }, .{ "backtab", .backtab },
    };
    inline for (names) |n| {
        if (std.ascii.eqlIgnoreCase(rest, n[0])) {
            // Terminals report shift+tab as backtab.
            if (n[1] == .tab and mods.shift) return .{ .code = .backtab, .mods = .{} };
            return .{ .code = n[1], .mods = mods };
        }
    }
    if (std.ascii.eqlIgnoreCase(rest, "lt")) return .{ .code = .{ .char = '<' }, .mods = mods };
    if (std.ascii.eqlIgnoreCase(rest, "space")) return .{ .code = .{ .char = ' ' }, .mods = mods };
    if (rest.len == 1) return .{ .code = .{ .char = rest[0] }, .mods = mods };
    if (rest.len >= 2 and std.ascii.toLower(rest[0]) == 'f') {
        const n = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
        return .{ .code = .{ .f = n }, .mods = mods };
    }
    return null;
}

/// A buffer whose text and cursor come from `marked` (`|` = cursor).
pub const Harness = struct {
    buf: Buffer,
    clip: Clipboard,
    arena: std.heap.ArenaAllocator,
    last_app: ?AppCommand = null,
    unhandled: usize = 0,

    pub fn init(gpa: Allocator, style: input.Style, src: []const u8) !Harness {
        const bar = std.mem.indexOfScalar(u8, src, '|') orelse src.len;
        const text = try std.mem.concat(gpa, u8, &.{ src[0..bar], if (bar < src.len) src[bar + 1 ..] else "" });
        defer gpa.free(text);
        var buf = try Buffer.init(gpa, text, style, .{ .tab_width = 4 });
        errdefer buf.deinit();
        buf.editor.cursor = bar;
        return .{ .buf = buf, .clip = Clipboard.init(gpa), .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(h: *Harness) void {
        h.buf.deinit();
        h.clip.deinit();
        h.arena.deinit();
    }

    pub fn feed(h: *Harness, spec: []const u8) !void {
        const keys = try parseKeys(h.buf.gpa, spec);
        defer h.buf.gpa.free(keys);
        for (keys) |k| {
            _ = h.arena.reset(.retain_capacity);
            const ev = try h.buf.feedKey(k, &h.clip, 10, null, h.arena.allocator());
            switch (ev) {
                .app => |cmd| h.last_app = switch (cmd) {
                    // Frame-arena payloads would dangle; keep the tag only.
                    .ex_command => .{ .ex_command = "" },
                    .cmdline_enter => .{ .cmdline_enter = "" },
                    else => cmd,
                },
                .unhandled => h.unhandled += 1,
                else => {},
            }
        }
    }

    /// Ops that arrive as commands rather than keys (`editor.add_cursor_below`).
    pub fn ops(h: *Harness, list: []const EditOp) !void {
        _ = h.arena.reset(.retain_capacity);
        _ = try h.buf.applyOps(list, &h.clip, 10, h.arena.allocator());
    }

    /// The text with `|` at the cursor.
    pub fn marked(h: *Harness, gpa: Allocator) ![]u8 {
        const t = h.buf.editor.bytes();
        const c = h.buf.editor.cursor;
        return std.mem.concat(gpa, u8, &.{ t[0..c], "|", t[c..] });
    }
};

/// `feed("dw", "hello world|", "world|")`-style table row.
fn check(style: input.Style, keys: []const u8, before: []const u8, after: []const u8) !void {
    var h = try Harness.init(testing.allocator, style, before);
    defer h.deinit();
    try h.feed(keys);
    const got = try h.marked(testing.allocator);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(after, got) catch |err| {
        std.debug.print("\n  keys: {s}\n  before: {s}\n", .{ keys, before });
        return err;
    };
}

fn vim(keys: []const u8, before: []const u8, after: []const u8) !void {
    return check(.vim, keys, before, after);
}

fn std_(keys: []const u8, before: []const u8, after: []const u8) !void {
    return check(.standard, keys, before, after);
}

test "vim motions" {
    try vim("w", "|hello world", "hello |world");
    try vim("2w", "|a b c", "a b |c");
    try vim("b", "hello wor|ld", "hello |world");
    try vim("e", "|hello world", "hell|o world");
    try vim("ge", "hello wor|ld", "hell|o world");
    try vim("W", "|a.b c", "a.b |c");
    try vim("B", "a.b |c", "|a.b c");
    try vim("E", "|a.b c", "a.|b c");
    try vim("gE", "a.b |c", "a.|b c");
    try vim("0", "abc|d", "|abcd");
    try vim("^", "  ab|c", "  |abc");
    try vim("$", "|abc\nx", "ab|c\nx");
    try vim("g_", "|ab  \nx", "a|b  \nx");
    try vim("gg", "a\nb\n|c", "|a\nb\nc");
    try vim("G", "|a\nb\nc\n", "a\nb\n|c\n");
    try vim("2G", "|a\nb\nc", "a\n|b\nc");
    try vim("3gg", "|a\nb\nc", "a\nb\n|c");
    try vim("jj", "ab|c\nd\nefgh", "abc\nd\nef|gh");
    try vim("k", "a\nb|c", "a|\nbc");
    try vim("l", "|ab", "a|b");
    try vim("h", "a|b", "|ab");
    try vim("3l", "|abcd", "abc|d");
    try vim("+", "a|b\n  cd", "ab\n  |cd");
    try vim("-", "ab\n  c|d", "|ab\n  cd");
    try vim("<cr>", "a|b\n  cd", "ab\n  |cd");
    try vim("}", "|a\nb\n\nc", "a\nb\n|\nc");
    try vim("{", "a\n\nb\n|c", "a\n|\nb\nc");
    try vim(")", "|a. b", "a. |b");
    try vim("fc", "|abcabc", "ab|cabc");
    try vim("2fc", "|abcabc", "abcab|c");
    try vim("tc", "|abc", "a|bc");
    try vim("fc;", "|abcabc", "abcab|c");
    try vim("fc,", "|abcabc", "ab|cabc");
    try vim("Fa", "abcab|c", "abc|abc");
    try vim("Ta", "abcab|c", "abca|bc");
    try vim("3|", "|abcdef", "ab|cdef");
    try vim("50%", "|a\nb\nc\nd", "a\n|b\nc\nd");
    try vim("<c-d>", "|a\nb\nc\nd\ne\nf\ng\nh", "a\nb\nc\nd\ne\n|f\ng\nh");
    try vim("<c-f><c-b>", "|a\nb\nc", "|a\nb\nc");
    try vim("<c-right><c-left>", "|hello world", "|hello world");
    try vim("<end><home>", "|abc", "|abc");
}

test "vim inserts, opens and appends" {
    try vim("ihi<esc>", "|abc", "h|iabc");
    try vim("ahi<esc>", "|abc", "ah|ibc");
    try vim("Ax<esc>", "|abc", "abc|x");
    try vim("Ix<esc>", "  ab|c", "  |xabc");
    try vim("gIx<esc>", "  ab|c", "|x  abc");
    try vim("ox<esc>", "a|b\nc", "ab\n|x\nc");
    try vim("Ox<esc>", "a|b\nc", "|x\nab\nc");
    try vim("i<cr><esc>", "ab|c", "ab|\nc"); // move_left crosses lines (Rust parity)
    try vim("i<tab>x<esc>", "|a", "    |xa");
    try vim("i<c-v><tab><esc>", "|a", "|\ta");
    try vim("ib<bs><bs>x<esc>", "a|c", "|xc");
    try vim("A<c-w><esc>", "|foo bar", "foo| ");
    try vim("A<c-u><esc>", "|foo bar", "|");
    try vim("i<c-h><esc>", "ab|c", "|ac");
    try vim("A<c-o>0x<esc>", "|abc", "|xabc");
    try vim("jA<c-y><esc>", "xyz\n|a", "xyz\na|y");
    try vim("A<c-e><esc>", "|a\nxyz", "a|y\nxyz");
    try vim("i<left>x<esc>", "ab|c", "a|xbc");
    try vim("i<c-[>", "ab|c", "a|bc");
    try vim("i<c-c>", "ab|c", "ab|c");
    try vim("i<del><esc>", "a|bc", "|ac");
}

test "vim deletes and changes with motions, counts and text objects" {
    try vim("x", "|abc", "|bc");
    try vim("2x", "|abc", "|c");
    try vim("X", "ab|c", "a|c");
    try vim("dw", "|hello world", "|world");
    try vim("dw", "hello |world\nx", "hello |\nx");
    try vim("d2w", "|a b c d", "|c d");
    try vim("2dw", "|a b c d", "|c d");
    try vim("d3w", "|a b\nc d", "|d");
    try vim("de", "|hello world", "| world");
    try vim("db", "hello |world", "|world");
    try vim("d$", "a|bcd\nx", "a|\nx");
    try vim("D", "a|bcd\nx", "a|\nx");
    try vim("d0", "abc|d", "|d");
    try vim("dd", "a\n|b\nc", "a\n|c");
    try vim("2dd", "|a\nb\nc", "|c");
    try vim("dj", "|a\nb\nc", "|c");
    try vim("dk", "a\nb\n|c", "|a");
    try vim("dG", "a\n|b\nc", "a\n|b\nc"); // operator_linewise_to bubbles to the app
    try vim("dtc", "|abcd", "|cd");
    try vim("dfc", "|abcd", "|d");
    try vim("d2fc", "|abcabcd", "|d");
    try vim("diw", "hello wo|rld!", "hello |!");
    try vim("daw", "hello wo|rld foo", "hello |foo");
    try vim("di(", "f(a, |b)", "f(|)");
    try vim("da(", "f(a, |b)", "f|");
    try vim("dib", "f(a, |b)", "f(|)");
    try vim("di\"", "x \"a |b\" y", "x \"|\" y");
    try vim("da\"", "x \"a |b\" y", "x | y");
    try vim("dip", "a\n|b\n\nc", "|\n\nc"); // charwise range, Rust parity
    try vim("dap", "a\n|b\n\nc", "|c");
    try vim("dit", "<b>hi |there</b>", "<b>|</b>");
    try vim("dat", "<b>hi |there</b>x", "|x");
    try vim("di[", "[|a]", "[|]");
    try vim("cwfoo<esc>", "|hello world", "fo|o world");
    try vim("cefoo<esc>", "|hello world", "fo|o world");
    try vim("ccx<esc>", "|abc\nd", "|x\nd");
    try vim("Sx<esc>", "ab|c\nd", "|x\nd");
    try vim("Cx<esc>", "a|bc\nd", "a|x\nd");
    try vim("ciwZ<esc>", "hello wo|rld", "hello |Z");
    try vim("ci(Z<esc>", "f(a|b)", "f(|Z)");
    try vim("cjZ<esc>", "|a\nb\nc", "|Z\nc");
    try vim("c$Z<esc>", "a|bc", "a|Z");
    try vim("rX", "|abc", "|Xbc");
    try vim("3rX", "|abcd", "XX|Xd");
    try vim("rX", "|\nb", "|\nb");
    try vim("~", "|abc", "A|bc");
    try vim("3~", "|abc", "ABC|");
    try vim("J", "|a\n  b", "a| b");
    try vim("3J", "|a\nb\nc\nd", "a b| c\nd");
    try vim("gJ", "|a\n  b", "a|  b");
    try vim("guiw", "|ABC def", "|abc def");
    try vim("gUiw", "|abc def", "|ABC def");
    try vim("guu", "|ABC\nD", "abc\n|D"); // cursor lands on the next line (Rust parity)
    try vim("gUU", "|abc\nd", "ABC\n|d");
    try vim("g~~", "|aBc\nd", "AbC\n|d");
    try vim("g~iw", "a|Bc d", "|AbC d");
    try vim(">>", "|a\nb", " |   a\nb"); // cursor keeps its column (Rust parity)
    try vim("<<", "    a|b\nc", "ab|\nc");
    try vim(">j", "|a\nb\nc", "    a\n |   b\nc");
    try vim("2>>", "|a\nb\nc", "    a\n |   b\nc");
    try vim("<j", "    |a\n    b\nc", "a\nb|\nc");
    try vim("<k", "    a\n    |b\nc", "a|\nb\nc");
}

test "vim registers, yank and put" {
    try vim("yyp", "|a\nb", "a\n|a\nb");
    try vim("yyP", "|a\nb", "|a\na\nb");
    try vim("yyjp", "|a\nb", "a\nb\n|a");
    try vim("2yyGp", "|a\nb\nc", "a\nb\nc\n|a\nb");
    try vim("ywP", "|ab cd", "ab |ab cd");
    try vim("yw$p", "|ab cd", "ab cdab |");
    try vim("yiwwviwp", "|ab cd", "ab ab|");
    try vim("ddp", "|a\nb", "b\n|a");
    try vim("dwwP", "|a b c", "b a |c");
    try vim("\"ayyj\"ap", "|a\nb", "a\nb\n|a");
    try vim("\"ayyj\"Ayy\"ap", "|a\nb", "a\nb\n|a\nb");
    try vim("\"_dd", "|a\nb", "|b");
    try vim("yyjdd\"0p", "|a\nb\nc", "a\nc\n|a");
    try vim("ddjdd\"2p", "|a\nb\nc\nd", "b\nd\n|a");
    try vim("dddd\"1p\"2p", "|a\nb\nc", "c\nb\n|a");
    try vim("Yp", "a|b\nc", "abb|\nc"); // Rust mnml `Y` yanks cursor→EOL charwise
    try vim("yl$p", "|abc", "abca|");
    try vim("\"qyy\"qp", "|z", "z\n|z");
    try vim("ylgp", "|abc", "aa|bc");
    try vim("ylgP", "|abc", "a|abc");
}

test "vim undo, redo, dot-repeat" {
    try vim("xu", "|abc", "|abc");
    try vim("xxuu", "|abc", "|abc");
    try vim("xxu<c-r>", "|abc", "|c");
    try vim("xx2u", "|abc", "|abc");
    try vim("ifoo<esc>u", "|abc", "|abc");
    try vim("ifoo<esc>lx u", "|abc", "foo|abc");
    try vim("3ddu", "|a\nb\nc\nd", "|a\nb\nc\nd");
    try vim("dw.", "|a b c d", "|c d");
    try vim("x..", "|abcd", "|d");
    try vim("iX<esc>j0.", "|a\nb", "Xa\n|Xb");
    try vim("iX<esc>j0.j0.", "|a\nb\nc", "Xa\nXb\n|Xc");
    try vim("dd.", "|a\nb\nc", "|c");
    try vim("cwZ<esc>w.", "|ab cd ef", "Z |Z ef");
    try vim("A!<esc>j.", "|a\nb", "a!\nb|!");
    try vim("x3.", "|abcdef", "|ef");
    try vim("x.u", "|abcd", "|bcd");
    try vim("p.", "|a", "|a"); // empty register: nothing to repeat
}

test "vim marks, macros and visual mode" {
    try vim("majj'a", "|a\nb\nc", "|a\nb\nc");
    try vim("lmajj`a", "|ab\nb\nc", "a|b\nb\nc");
    try vim("majj'z", "|a\nb\nc", "a\nb\n|c");
    try vim("majj'a", "  |a\nb\nc", "  |a\nb\nc");
    try vim("qaA!<esc>jq@a", "|a\nb\nc", "a!\nb!\nc|");
    try vim("qaA!<esc>jq@a@@", "|a\nb\nc", "a!\nb!\nc!|");
    try vim("qqA!<esc>jq@@", "|a\nb\nc", "a!\nb!\nc|");
    try vim("qaxq2@a", "|abcd", "|d");
    try vim("qaIX<esc>jqqbA!<esc>jq@a@b", "|a\nb\nc\nd", "Xa\nb!\nXc\nd!|");
    try vim("@z", "|a", "|a");
    try vim("vwd", "|hello world", "|orld");
    try vim("vwy$p", "|hello world", "hello worldhello w|");
    try vim("v$d", "a|bc\nd", "a|\nd");
    try vim("vlly", "|abc", "|abc");
    try vim("vllcZ<esc>", "|abcd", "|Zd");
    try vim("Vjd", "|a\nb\nc", "|c");
    try vim("Vjy$p", "|a\nb\nc", "a\n|a\nb\nb\nc");
    try vim("VjyGp", "|a\nb\nc", "a\nb\nc\n|a\nb");
    try vim("Vx", "a\n|b\nc", "a\n|c");
    try vim("V>", "|a\nb", "    a\n|b");
    try vim("Vj<lt>", "    |a\n    b\nc", "a\nb\n|c");
    try vim("vU", "|abc", "|Abc");
    try vim("v~", "|abc", "|Abc");
    try vim("vlu", "|ABC", "|abC");
    try vim("viwd", "hel|lo world", "| world");
    try vim("viwy$p", "hel|lo world", "hello worldhello|");
    try vim("viwlld", "|ab cd", "|"); // a motion after the object widens again
    try vim("vipd", "|a\nb\n\nc", "|\n\nc"); // charwise paragraph range, Rust parity
    try vim("vi(d", "f(a|b)", "f(|)");
    try vim("va\"d", "x \"a|b\" y", "x | y");
    try vim("vlold", "|abcd", "a|cd");
    try vim("vly<esc>gvd", "|abc", "|c");
    try vim("v<esc>x", "|abc", "|bc");
    try vim("vjJ", "|a\nb", "a| b");
    try vim("vlrX", "|abc", "|XXc");
    try vim("vlp", "|abc", "|c"); // empty register: selection deleted
    try vim("ylvlp", "|abc", "a|c");
    try vim("vVd", "a\n|b\nc", "a\n|c");
    try vim("Vvd", "a\n|bc\nd", "a\n|c\nd");
    try vim("vv", "|abc", "|abc");
    try vim("<c-v>jd", "|ab\ncd", "|b\nd");
    try vim("<c-v>jld", "a|bcd\nefgh\nij", "a|d\neh\nij");
    try vim("<c-v>jlx", "a|bcd\nefgh", "a|d\neh");
    try vim("<c-v>jldp", "a|bcd\nefgh", "adbc\nfg|\neh"); // the block is in the register charwise (Rust parity)
    try vim("<c-v>jly$p", "a|bcd\nefgh", "abcdbc\nfg|\nefgh");
    try vim("<c-v>jlyP", "a|bcd\nefgh", "abc\nfg|bcd\nefgh"); // `y` parks at the rectangle's top-left; `P` lands after the text
    try vim("<c-v>jl<esc>x", "a|bcd\nefgh", "abcd\nef|h");
    try vim("<c-v>kd", "ab\n|cd", "|b\nd"); // the rectangle is anchor→cursor in either direction
    try vim("<c-v>jjld", "|abc\nx\nabc", "|c\n\nc"); // a short row contributes nothing
    try vim("<c-v>jvd", "|ab\ncd", "ab\n|d"); // `v` / `V` from V-BLOCK re-anchor at the cursor (Rust parity; vim keeps the anchor)
    try vim("<c-v>jVd", "a|b\ncd\ne", "ab\n|e");
    try vim("<c-v>jd", "|ab\ncd", "|b\nd");
    try vim("<c-v>jdu", "|ab\ncd", "ab\n|cd"); // one undo step; the snapshot cursor comes back
}

/// `feed` / `ops` interleaved: each row is a list of steps.
const Step = union(enum) { keys: []const u8, op: EditOp };

fn multi(before: []const u8, steps: []const Step, after: []const u8) !void {
    var h = try Harness.init(testing.allocator, .vim, before);
    defer h.deinit();
    for (steps) |st| switch (st) {
        .keys => |k| try h.feed(k),
        .op => |o| try h.ops(&.{o}),
    };
    const got = try h.marked(testing.allocator);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(after, got) catch |err| {
        std.debug.print("\n  before: {s}\n", .{before});
        return err;
    };
}

test "vim multi-cursor: typing, deletes, selections and puts fan out over every cursor" {
    const below: Step = .{ .op = .add_cursor_below };
    const next_word: Step = .{ .op = .add_cursor_at_next_word };
    try multi("|alpha\nbeta\ngamma", &.{ .{ .keys = "i" }, below, below, .{ .keys = "X<esc>" } }, "|Xalpha\nXbeta\nXgamma");
    try multi("|Yone\nYtwo", &.{ .{ .keys = "li" }, below, .{ .keys = "<bs><esc>" } }, "|one\ntwo");
    try multi("|foo bar foo baz foo", &.{ .{ .keys = "l" }, next_word, next_word, .{ .keys = "iX<esc>" } }, "|X bar X baz foo");
    try multi("|old one\nold two", &.{ .{ .keys = "ea" }, below, .{ .keys = "<c-w><esc>" } }, "| one\n two");
    try multi("|AAAxxxBBB\nAAAyyyBBB", &.{ .{ .keys = "lllv" }, below, .{ .keys = "lld" } }, "AAA|BBB\nAAABBB");
    try multi("|AAAxxxBBB\nAAAyyyBBB", &.{ .{ .keys = "lllv" }, below, .{ .keys = "llcZ<esc>" } }, "AAA|ZBBB\nAAAZBBB");
    try multi("|A.\nB.", &.{ .{ .keys = "v" }, below, .{ .keys = "y0" }, below, .{ .keys = "P" } }, "A|A.\nBB.");
    try multi("|ab\ncd", &.{ .{ .keys = "i" }, below, .{ .keys = "<cr><esc>" } }, "|\nab\n\ncd");
    try multi("|ab\ncd", &.{ .{ .keys = "A" }, below, .{ .keys = "<bs>!<esc>" } }, "a|!\nc!");
    try multi("|ab cd\nef gh", &.{ .{ .keys = "i" }, below, .{ .keys = "<c-right>-<esc>" } }, "ab |-cd\nef -gh");
    // The clear op collapses to the primary; the next edit is single-cursor again.
    try multi("|a\nb", &.{ .{ .keys = "i" }, below, .{ .op = .clear_extra_cursors }, .{ .keys = "X<esc>" } }, "|Xa\nb");
}

test "vim surround: ys over motions and objects, yss, visual S, ds, cs" {
    try vim("ysiw\"", "hello |world", "hello \"world|\"");
    try vim("ysiw(", "|x y", "( x |) y"); // an opener pads; the cursor lands on the closer
    try vim("ysiw)", "|x y", "(x|) y");
    try vim("ysiwb", "|x y", "(x|) y");
    try vim("ysiwB", "|x y", "{x|} y");
    try vim("ys$'", "a|bc", "a'bc|'");
    try vim("ysfc]", "|abcd", "[abc|]d");
    try vim("ys2w\"", "|a b c", "\"a b |\"c");
    try vim("yss\"", "  |ab cd", "  \"ab cd|\"");
    try vim("yss<esc>", "|ab", "|ab"); // Esc drops the pending range
    try vim("ysiwt", "|ab", "|ab"); // a tag needs a name: not here
    try vim("vllS\"", "|abc def", "\"abc|\" def");
    try vim("vllS{", "|abc def", "{ abc |} def");
    try vim("VS(", "|ab\ncd", "( ab\n |)cd"); // linewise: the whole line, newline included
    try vim("ds\"", "x \"a |b\" y", "x |a b y");
    try vim("ds\"", "x |\"a b\" y", "x |a b y"); // on the opener counts as inside
    try vim("ds(", "f( a|b )", "f|ab");
    try vim("ds)", "f( a|b )", "f| ab ");
    try vim("dsb", "f( a|b )", "f| ab ");
    try vim("ds]", "[[a|b]]", "[|ab]");
    try vim("dst", "<b>h|i</b>", "|hi");
    try vim("dsx", "(a|b)", "(a|b)"); // not a pair char
    try vim("ds(", "a|b", "a|b"); // nothing to delete
    try vim("cs\"'", "s = \"fo|o\";", "s = |'foo';");
    try vim("cs(<", "let t = (|1, 2);", "let t = |<1, 2>;");
    try vim("cs({", "(|a)", "|{ a }");
    try vim("cs{)", "{ |a }", "|(a)");
    try vim("cst\"", "<b>h|i</b>", "|\"hi\"");
    try vim("cs\"x", "\"a|b\"", "\"a|b\""); // not a pair char
    try vim("cs\"<esc>x", "\"a|b\"", "\"a|\""); // Esc cancels
    try vim("ds\"u", "x \"a |b\" y", "x \"a |b\" y"); // one undo step
}

test "vim replace mode and cmdline" {
    try vim("RXY<esc>", "|abc", "X|Yc");
    try vim("RXYZW<esc>", "|abc", "XYZ|W");
    try vim("RXY<bs><bs><esc>", "|abc", "|abc");
    try vim("RX<cr>Y<esc>", "|abc", "X\n|Yc");
    try vim(":wq<cr>", "|abc", "|abc");
    try vim(":%s/a/b/g<cr>", "|abc", "|abc");
    try vim("ZZ", "|abc", "|abc");
    try vim("Vj:d<cr>", "|a\nb\nc", "a\n|b\nc");
}

test "vim: cmdline, ZZ and :s reach the app as ex commands; gd runs a command" {
    var h = try Harness.init(testing.allocator, .vim, "|abc");
    defer h.deinit();
    try h.feed(":wq<cr>");
    try testing.expect(h.last_app.? == .ex_command);
    h.last_app = null;
    try h.feed("ZZ");
    try testing.expect(h.last_app.? == .ex_command);
    try h.feed("gd");
    try testing.expectEqual(input.CommandId.@"lsp.goto_definition", h.last_app.?.run_command);
    try h.feed("/");
    try testing.expectEqual(input.CommandId.@"find.find", h.last_app.?.run_command);
    try h.feed("n");
    try testing.expectEqual(input.CommandId.@"find.next", h.last_app.?.run_command);
    try h.feed("?");
    try h.feed("n");
    try testing.expectEqual(input.CommandId.@"find.prev", h.last_app.?.run_command);
    try h.feed("*");
    try testing.expectEqual(input.CommandId.@"find.word_forward", h.last_app.?.run_command);
    try h.feed("#");
    try testing.expectEqual(input.CommandId.@"find.word_backward", h.last_app.?.run_command);
    try h.feed("N");
    try testing.expectEqual(input.CommandId.@"find.next", h.last_app.?.run_command);
    try h.feed("3o");
    try testing.expectEqual(@as(u32, 3), h.last_app.?.repeat_insert_start.count);
    try h.feed("<c-v>jjI");
    try testing.expect(!h.last_app.?.block_insert_start.append);
    try h.feed("dG");
    try testing.expect(h.last_app.?.operator_linewise_to.target == null);
    try h.feed("3dG");
    try testing.expectEqual(@as(u32, 3), h.last_app.?.operator_linewise_to.target.?);
    try h.feed("ygg");
    try testing.expectEqual(@as(u32, 0), h.last_app.?.operator_linewise_to.target.?);
    try h.feed("sab");
    try testing.expectEqual(@as(u21, 'b'), h.last_app.?.flash_start.b);
    try testing.expectEqual(@as(usize, 0), h.unhandled);
    try h.feed("<f5>");
    try testing.expectEqual(@as(usize, 1), h.unhandled);
    try testing.expectEqual(input.EditingMode.normal, h.buf.input.mode());
}

test "vim: modes as the statusline sees them" {
    var h = try Harness.init(testing.allocator, .vim, "|abc");
    defer h.deinit();
    try testing.expectEqual(input.EditingMode.normal, h.buf.input.mode());
    try h.feed("i");
    try testing.expectEqual(input.EditingMode.insert, h.buf.input.mode());
    try h.feed("<esc>R");
    try testing.expectEqual(input.EditingMode.replace, h.buf.input.mode());
    try h.feed("<esc>v");
    try testing.expectEqual(input.EditingMode.visual, h.buf.input.mode());
    try h.feed("V");
    try testing.expectEqual(input.EditingMode.visual_line, h.buf.input.mode());
    try h.feed("<esc><c-v>");
    try testing.expectEqual(input.EditingMode.visual_block, h.buf.input.mode());
    try h.feed("<esc>:");
    try testing.expect(h.buf.input.isCmdlineOpen());
    try h.feed("<esc>d");
    try testing.expect(h.buf.input.isOpPending());
    try h.feed("<esc>");
    try testing.expect(!h.buf.input.isOpPending());
}

test "standard: typing, selection, clipboard, undo, line ops" {
    try std_("hi", "|abc", "hi|abc");
    try std_("<cr>", "ab|c", "ab\n|c");
    try std_("<bs>", "ab|c", "a|c");
    try std_("<del>", "a|bc", "a|c");
    try std_("<c-bs>", "foo bar|", "foo |");
    try std_("<c-del>", "|foo bar", "|bar");
    try std_("<tab>", "|a", "    |a");
    try std_("<s-right><s-right>x", "|abc", "x|c");
    try std_("<s-end><bs>", "a|bc\nd", "a|\nd");
    try std_("<s-down><del>", "a|b\ncd", "a|d");
    try std_("<c-right><c-right>", "|foo bar baz", "foo bar |baz");
    try std_("<a-left>", "foo bar|", "foo |bar");
    try std_("<end><home>", "|  abc", "  |abc");
    try std_("<home><home>", "  ab|c", "|  abc");
    try std_("<c-end>", "|a\nbc", "a\nbc|");
    try std_("<c-home>", "a\nb|c", "|a\nbc");
    try std_("<c-a><del>", "a|bc", "|");
    try std_("<c-l><del>", "a|b\ncd", "|cd");
    try std_("<c-l><c-l><del>", "a|b\ncd\nef", "|ef");
    try std_("<s-right><c-x><end><c-v>", "|abc", "bca|");
    try std_("<s-right><c-c><end><c-v>", "|abc", "abca|");
    try std_("<c-x>", "|a\nb", "|b");
    try std_("<c-c><c-v>", "|a\nb", "a\n|a\nb");
    try std_("xy<c-z>", "|abc", "|abc");
    try std_("xy<c-z><c-y>", "|abc", "xy|abc");
    try std_("xy<c-z><c-s-z>", "|abc", "xy|abc");
    try std_("<a-s-down>", "|a\nb", "a\n|a\nb");
    try std_("<a-s-up>", "|a\nb", "|a\na\nb");
    try std_("<a-down>", "|a\nb", "b\n|a");
    try std_("<a-up>", "a\n|b", "|b\na");
    try std_("<s-right><esc>x", "|abc", "ax|bc");
    try std_("<c-cr>", "a|b", "ab\n|");
    try std_("<c-s-cr>", "a|b", "|\nab");
    try std_("<s-tab>", "    |a", "a|"); // column kept, clamped (Rust parity)
    try std_("<s-right><tab>", "|a\nb", " |   a\nb"); // column kept (Rust parity)
}

test "standard: ctrl+s escalates save, unknown chords are unhandled, dirty tracks" {
    var h = try Harness.init(testing.allocator, .standard, "|abc");
    defer h.deinit();
    try h.feed("x");
    try testing.expect(h.buf.dirty);
    try h.feed("<c-s>");
    try testing.expectEqual(AppCommand.save, h.last_app.?);
    try h.buf.markSaved();
    try testing.expect(!h.buf.dirty);
    try h.feed("<c-z>");
    try testing.expect(h.buf.dirty);
    try h.feed("<c-y>");
    try testing.expect(!h.buf.dirty);
    try h.feed("<c-p>");
    try testing.expectEqual(@as(usize, 1), h.unhandled);
    try testing.expectEqual(input.EditingMode.none, h.buf.input.mode());
    try testing.expect(h.buf.input.mode().label() == null);
    // Switching styles keeps the text and drops the selection.
    try h.feed("<s-right>");
    try testing.expect(h.buf.editor.hasSelection());
    h.buf.setInputStyle(.vim, .{});
    try testing.expect(!h.buf.editor.hasSelection());
    try testing.expectEqual(input.EditingMode.normal, h.buf.input.mode());
    try h.feed("x");
    try testing.expectEqualStrings("xac", h.buf.editor.bytes());
}

test "buffer: unsupported ops are skipped and named; folds shift with edits" {
    var h = try Harness.init(testing.allocator, .vim, "|a\nb\nc\nd");
    defer h.deinit();
    try h.buf.folds.put(testing.allocator, 2, 3);
    try h.feed("<c-a>");
    try testing.expectEqualStrings("change_number_at_cursor", h.buf.last_unsupported.?);
    try h.feed("O!<esc>");
    try testing.expectEqual(@as(usize, 3), h.buf.folds.keys()[0]);
    try testing.expectEqual(@as(usize, 4), h.buf.folds.values()[0]);
    try h.feed("dd");
    try testing.expectEqual(@as(usize, 2), h.buf.folds.keys()[0]);
}

test "buffer: load and save round-trip through the file system" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const file = try std.fs.path.join(gpa, &.{ path, "note.md" });
    defer gpa.free(file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "hello\n" });
    var buf = try Buffer.load(gpa, io, file, .vim, .{});
    defer buf.deinit();
    try testing.expectEqualStrings("md", buf.language.?);
    try testing.expect(!buf.dirty);
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const keys = try parseKeys(gpa, "A!<esc>");
    defer gpa.free(keys);
    for (keys) |k| _ = try buf.feedKey(k, &clip, 10, null, arena.allocator());
    try testing.expect(buf.dirty);
    try buf.save(io);
    try testing.expect(!buf.dirty);
    const back = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1024));
    defer gpa.free(back);
    try testing.expectEqualStrings("hello!\n", back);
}
