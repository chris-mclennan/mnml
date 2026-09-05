//! `Buffer` — an `Editor` plus the handler that drives it, the file it
//! came from, marks, folds, the dot-repeat holder and the macro
//! recording in flight. `feedKey` is THE seam: the only place an
//! `InputResult` is destructured.
//!
//! Buffer-local `AppCommand`s (lowercase marks, dot-repeat, macros) are
//! handled here and come back as `.edited` / `.redraw`; everything else
//! — an uppercase (global) mark included — bubbles up as `.app` for the
//! app to run. Finished macro registers live on the `Clipboard`
//! (`clipboard.zig`), so a macro recorded here replays in any buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editorconfig = @import("editorconfig.zig");
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
pub const KeyCode = input.KeyCode;

pub const Recording = struct { reg: u8, keys: std.ArrayList(Key) = .empty };

/// `(open, close)` comment tokens for a file extension; both empty for a
/// commentless file so a toggle is a no-op instead of a stray literal.
pub fn commentTokenFor(ext: ?[]const u8) [2][]const u8 {
    const e = ext orelse return .{ "", "" };
    const slash = [_][]const u8{ "zig", "rs", "ts", "tsx", "js", "jsx", "cjs", "mjs", "c", "cpp", "h", "hpp", "cs", "go", "java", "kt", "swift", "php", "scss", "less" };
    const hash = [_][]const u8{ "py", "rb", "sh", "bash", "zsh", "toml", "yaml", "yml", "ini", "conf" };
    const dash = [_][]const u8{ "lua", "sql" };
    const angle = [_][]const u8{ "html", "htm", "xml", "vue", "svelte", "astro", "md", "markdown" };
    for (slash) |x| if (std.mem.eql(u8, e, x)) return .{ "// ", "" };
    for (hash) |x| if (std.mem.eql(u8, e, x)) return .{ "# ", "" };
    for (dash) |x| if (std.mem.eql(u8, e, x)) return .{ "-- ", "" };
    for (angle) |x| if (std.mem.eql(u8, e, x)) return .{ "<!-- ", " -->" };
    if (std.mem.eql(u8, e, "css")) return .{ "/* ", " */" };
    return .{ "", "" };
}

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
    /// Rust mnml's `[editor] ensure_trailing_newline`: a file gets its
    /// terminating newline on save. It goes through `apply` so undo can
    /// take it back — and, like any `replace_range`, leaves the cursor
    /// after the inserted text.
    ensure_trailing_newline: bool = true,
    /// `[editor] trim_trailing_ws_on_save` / `.editorconfig`
    /// `trim_trailing_whitespace`: line ends are stripped on save, in
    /// one undo step, the cursor kept.
    trim_trailing_ws_on_save: bool = false,
    /// What a save writes between lines. The text is LF in memory
    /// whatever the file had (`load` normalises and remembers); a
    /// `.editorconfig` `end_of_line` overrides what was found.
    eol: editorconfig.Eol = .lf,
    /// The indent unit the handler types on Tab — kept here so a handler
    /// rebuilt by `setInputStyle` gets the file's value back, not the
    /// config's.
    indent_unit: usize = 4,
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

    /// One Insert / Replace session is one undo step (`:help
    /// undo-blocks`): `insert_undo_target` is the undo depth just past
    /// the snapshot the session's first edit pushed; leaving the mode
    /// truncates the stack back to it.
    insert_session: bool = false,
    insert_undo_target: ?usize = null,

    /// The macro being recorded; the finished keys go to the clipboard.
    recording: ?Recording = null,
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
            .indent_unit = @max(cfg.tab_width, 1),
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
        const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(raw);
        const eol = detectEol(raw);
        const text = if (eol == .lf) raw else try normalizeEol(gpa, raw);
        defer if (eol != .lf) gpa.free(text);
        var buf = try init(gpa, text, style, cfg);
        errdefer buf.deinit();
        buf.eol = eol;
        try buf.setPath(path);
        return buf;
    }

    /// The first line break decides: `\r\n`, a lone `\r`, else LF.
    pub fn detectEol(text: []const u8) editorconfig.Eol {
        const i = std.mem.indexOfAny(u8, text, "\r\n") orelse return .lf;
        if (text[i] == '\n') return .lf;
        return if (i + 1 < text.len and text[i + 1] == '\n') .crlf else .cr;
    }

    /// Every `\r\n` and lone `\r` becomes `\n`.
    pub fn normalizeEol(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
        var out = try std.ArrayList(u8).initCapacity(gpa, text.len);
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                out.appendAssumeCapacity('\n');
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            } else out.appendAssumeCapacity(text[i]);
        }
        return out.toOwnedSlice(gpa);
    }

    /// `text` with `\n` written as `eol`.
    pub fn withEol(gpa: Allocator, text: []const u8, eol: editorconfig.Eol) Allocator.Error![]u8 {
        if (eol == .lf) return gpa.dupe(u8, text);
        const sep: []const u8 = if (eol == .crlf) "\r\n" else "\r";
        const n = std.mem.count(u8, text, "\n");
        var out = try std.ArrayList(u8).initCapacity(gpa, text.len + n * (sep.len - 1));
        errdefer out.deinit(gpa);
        for (text) |c| {
            if (c == '\n') out.appendSliceAssumeCapacity(sep) else out.appendAssumeCapacity(c);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn setPath(self: *Buffer, path: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.path) |p| self.gpa.free(p);
        self.path = copy;
        if (self.language) |l| self.gpa.free(l);
        self.language = null;
        const ext = std.fs.path.extension(path);
        if (ext.len > 1) self.language = try self.gpa.dupe(u8, ext[1..]);
        const tok = commentTokenFor(self.language);
        self.editor.comment_token = tok[0];
        self.editor.comment_token_close = tok[1];
    }

    pub const SaveError = Allocator.Error || Io.Dir.WriteFileError || error{NoPath};

    pub fn save(self: *Buffer, io: Io) SaveError!void {
        const path = self.path orelse return error.NoPath;
        if (self.trim_trailing_ws_on_save) try self.trimTrailingWhitespace();
        if (self.ensure_trailing_newline) try self.fixTrailingNewline();
        const data = try withEol(self.gpa, self.editor.bytes(), self.eol);
        defer self.gpa.free(data);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        try self.markSaved();
    }

    /// Strip the spaces and tabs before every line end, as one undoable
    /// edit; the cursor keeps its place (or moves left with the text
    /// removed before it).
    fn trimTrailingWhitespace(self: *Buffer) Allocator.Error!void {
        const text = self.editor.bytes();
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.gpa);
        var removed_before_cursor: usize = 0;
        var line_start: usize = 0;
        var changed = false;
        while (line_start <= text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            var end = nl;
            while (end > line_start and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
            if (end != nl) {
                changed = true;
                if (self.editor.cursor > end) removed_before_cursor += @min(self.editor.cursor, nl) - end;
            }
            try out.appendSlice(self.gpa, text[line_start..end]);
            if (nl == text.len) break;
            try out.append(self.gpa, '\n');
            line_start = nl + 1;
        }
        if (!changed) return;
        const cursor = self.editor.cursor - removed_before_cursor;
        var clip = Clipboard.init(self.gpa);
        defer clip.deinit();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = self.editor.apply(.{ .replace_range = .{ .start = 0, .end = text.len, .text = out.items } }, 0, &clip, arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return,
        };
        self.editor.anchor = null;
        self.editor.setCursor(cursor);
        self.editor.goal_col = null;
    }

    /// The indent unit and the tab display width, for the editor and
    /// the handler both.
    pub fn setIndent(self: *Buffer, tab_display: usize, indent_unit: usize, use_tabs: bool) void {
        self.editor.tab_width = @max(tab_display, 1);
        self.editor.use_tabs = use_tabs;
        self.indent_unit = @max(indent_unit, 1);
        self.input.configure(.{ .tab_width = self.indent_unit, .text_width = self.textWidth(), .use_tabs = use_tabs });
    }

    fn textWidth(self: *const Buffer) usize {
        return switch (self.input) {
            .vim => |v| v.text_width,
            .standard => 80,
        };
    }

    /// What a `.editorconfig` said about this file, over the config's
    /// defaults already on the buffer. Unset keys leave things alone.
    pub fn applyEditorconfig(self: *Buffer, r: editorconfig.Resolved) void {
        if (r.indent_style != null or r.indentUnit() != null) {
            const use_tabs = if (r.indent_style) |s| s == .tab else self.editor.use_tabs;
            const unit = r.indentUnit() orelse self.editor.tab_width;
            const display = r.tabDisplayWidth() orelse self.editor.tab_width;
            self.setIndent(display, unit, use_tabs);
        }
        if (r.end_of_line) |e| self.eol = e;
        if (r.trim_trailing_whitespace) |v| self.trim_trailing_ws_on_save = v;
        if (r.insert_final_newline) |v| self.ensure_trailing_newline = v;
    }

    fn fixTrailingNewline(self: *Buffer) Allocator.Error!void {
        const n = self.editor.len();
        if (n == 0 or self.editor.bytes()[n - 1] == '\n') return;
        var clip = Clipboard.init(self.gpa);
        defer clip.deinit();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = self.editor.apply(.{ .replace_range = .{ .start = n, .end = n, .text = "\n" } }, 0, &clip, arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return,
        };
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
        // The file's indent (a `.editorconfig`) outlives the handler.
        self.input.configure(.{ .tab_width = self.indent_unit, .text_width = cfg.text_width, .use_tabs = self.editor.use_tabs });
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
        // What a visual operator would act on, before the key resolves —
        // the shape `.` re-applies (`:help visual-repeat`).
        const visual: ?VisualShape = if (self.input.mode().isVisual()) self.visualShape() else null;
        // A session the app ended without a key (a blur) closes before
        // this key's own snapshot lands.
        const undo_before = self.editor.history.undoLen();
        self.syncInsertSession(undo_before);
        const result = try self.input.handleKey(key, ctx, arena);
        const ev: BufferEvent = switch (result) {
            .ops => |list| blk: {
                // The record keeps the handler's list: `.` on another
                // fold re-expands against that fold.
                const changed = try self.applyOps(try self.foldAwareOps(list, arena), clip, viewport_rows, arena);
                try self.trackDot(list, visual, arena);
                break :blk if (changed) .edited else .redraw;
            },
            .consumed => .redraw,
            .ignored => .{ .unhandled = key },
            .app => |cmd| try self.handleApp(cmd, clip, viewport_rows, wrap_width, arena),
        };
        self.syncInsertSession(undo_before);
        return ev;
    }

    /// Open / anchor / close the Insert undo session against the mode
    /// the handler is in now. `undo_before` is the undo depth before the
    /// key: the first snapshot pushed past it is the session's — the
    /// `cw` that entered Insert and the text typed after undo together.
    fn syncInsertSession(self: *Buffer, undo_before: usize) void {
        const ed = &self.editor;
        const typing = switch (self.input.mode()) {
            .insert, .replace => true,
            else => false,
        };
        if (typing) {
            if (!self.insert_session) {
                self.insert_session = true;
                self.insert_undo_target = null;
            }
            if (self.insert_undo_target == null and ed.history.undoLen() > undo_before) self.insert_undo_target = undo_before + 1;
        } else if (self.insert_session) {
            self.insert_session = false;
            if (self.insert_undo_target) |t| ed.history.truncateUndo(t);
            self.insert_undo_target = null;
            ed.in_insert_run = false;
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

    // ─── folds ───

    /// The closed fold holding `row`, as `(start, end)`.
    pub fn foldAt(self: *const Buffer, row: usize) ?[2]usize {
        for (self.folds.keys(), self.folds.values()) |s, e| if (row >= s and row <= e and e > s) return .{ s, e };
        return null;
    }

    /// The row on screen for `row`: itself, or the header of the fold
    /// hiding it.
    fn visibleRow(self: *const Buffer, row: usize) usize {
        return if (self.foldAt(row)) |f| f[0] else row;
    }

    /// Closed folds are one line to `j` / `k` and to the line operators
    /// (`:help fold-behavior`): `j` from a fold header lands on the first
    /// line after the fold, `dd` deletes the whole fold and `yy` yanks
    /// it. The handler's list is rewritten before it is applied; a list
    /// no fold touches comes back as it was. Frame arena.
    fn foldAwareOps(self: *Buffer, list: []const EditOp, arena: Allocator) Allocator.Error![]const EditOp {
        if (self.folds.count() == 0 or list.len == 0) return list;
        const ed = &self.editor;
        const cur = ed.currentLine();
        const count = ed.lineCount();
        // A `"x` prefix stays in front.
        const head: usize = if (list[0] == .set_register_hint) 1 else 0;
        const body = list[head..];
        if (body.len == 0) return list;

        // `j` / `k` / `+` / `-` and their counts.
        if (body.len == 1) {
            var inner = body[0];
            var n: usize = 1;
            if (body[0] == .repeat) {
                n = body[0].repeat.count;
                inner = body[0].repeat.inner.*;
            }
            const vertical: ?bool = switch (inner) {
                .move_down, .move_down_first_non_ws => true,
                .move_up, .move_up_first_non_ws => false,
                else => null,
            };
            if (vertical) |down| {
                var line = self.visibleRow(cur);
                for (0..n) |_| {
                    if (down) {
                        const next = (if (self.foldAt(line)) |f| f[1] else line) + 1;
                        if (next >= count) break;
                        line = next;
                    } else {
                        if (line == 0) break;
                        line = self.visibleRow(line - 1);
                    }
                }
                const steps = if (down) line -| cur else cur -| line;
                if (steps == n) return list;
                if (steps == 0) return list[0..head];
                const ptr = try arena.create(EditOp);
                ptr.* = inner;
                const out = try arena.alloc(EditOp, head + 1);
                @memcpy(out[0..head], list[0..head]);
                out[head] = .{ .repeat = .{ .count = @intCast(steps), .inner = ptr } };
                return out;
            }
        }

        // `dd` / `<n>dd` / `dj` / `yy` / `<n>yy`.
        const Kind = enum { delete, yank };
        var kind: Kind = .delete;
        var n: usize = 0;
        if (body.len == 1 and body[0] == .repeat and body[0].repeat.inner.* == .delete_line) {
            n = body[0].repeat.count;
        } else if (body.len == 1 and body[0] == .yank_line) {
            kind = .yank;
            n = 1;
        } else if (body.len == 1 and body[0] == .yank_lines_count) {
            kind = .yank;
            n = body[0].yank_lines_count;
        } else {
            for (body) |o| if (o != .delete_line) return list;
            n = body.len;
        }
        if (n == 0) return list;
        const first = self.visibleRow(cur);
        var line = first;
        var last = first;
        for (0..n) |i| {
            last = if (self.foldAt(line)) |f| f[1] else line;
            if (i + 1 < n) {
                if (last + 1 >= count) break;
                line = last + 1;
            }
        }
        if (first == cur and last + 1 - first == n) return list;
        var out: std.ArrayList(EditOp) = .empty;
        try out.appendSlice(arena, list[0..head]);
        if (first != cur) try out.append(arena, .{ .move_to_line = first + 1 });
        const covered: u32 = @intCast(last + 1 - first);
        switch (kind) {
            .delete => {
                // The folds going with the lines go first; `applyOps`
                // shifts the ones after.
                var i: usize = 0;
                while (i < self.folds.count()) {
                    const start = self.folds.keys()[i];
                    if (start >= first and start <= last) self.folds.orderedRemoveAt(i) else i += 1;
                }
                try self.folds.reIndex(self.gpa);
                const ptr = try arena.create(EditOp);
                ptr.* = .delete_line;
                try out.append(arena, .{ .repeat = .{ .count = covered, .inner = ptr } });
            },
            .yank => try out.append(arena, .{ .yank_lines_count = covered }),
        }
        return out.items;
    }

    // ─── dot-repeat ───

    /// A visual selection's extent, mode included, as of before a key —
    /// in rows and columns, since the key may have removed the text by
    /// the time the record is built.
    const VisualShape = struct { mode: input.EditingMode, a: Pos, c: Pos };

    fn visualShape(self: *const Buffer) ?VisualShape {
        const a = self.editor.anchor orelse self.editor.block_anchor orelse return null;
        return .{ .mode = self.input.mode(), .a = self.editor.rowColAt(a), .c = self.editor.rowCol() };
    }

    /// The ops that reselect `v`'s amount of text from the cursor: the
    /// same lines for V-LINE, the same rectangle for V-BLOCK, the same
    /// chars on one line or the same lines + end column across several
    /// (`:help visual-repeat`). Frame arena.
    fn reselectOps(self: *const Buffer, v: VisualShape, arena: Allocator) Allocator.Error![]const EditOp {
        _ = self;
        const a = v.a;
        const c = v.c;
        const rows: u32 = @intCast(@max(a.row, c.row) - @min(a.row, c.row));
        var out: std.ArrayList(EditOp) = .empty;
        const down = try arena.create(EditOp);
        down.* = .move_down;
        // Columns never cross a line: a charwise reselect clips at the
        // line end, like the `l` that made the selection would have.
        const right = try arena.create(EditOp);
        right.* = .move_right_no_cross_line;
        switch (v.mode) {
            .visual_line => {
                try out.append(arena, .select_line);
                if (rows > 0) try out.append(arena, .{ .repeat = .{ .count = rows, .inner = down } });
            },
            .visual_block => {
                const cols: u32 = @intCast(@max(a.col, c.col) - @min(a.col, c.col));
                try out.append(arena, .block_select_start);
                if (rows > 0) try out.append(arena, .{ .repeat = .{ .count = rows, .inner = down } });
                if (cols > 0) try out.append(arena, .{ .repeat = .{ .count = cols, .inner = right } });
            },
            else => {
                try out.append(arena, .select_start);
                if (rows == 0) {
                    const cols: u32 = @intCast(@max(a.col, c.col) - @min(a.col, c.col));
                    if (cols > 0) try out.append(arena, .{ .repeat = .{ .count = cols, .inner = right } });
                } else {
                    const end_col: u32 = @intCast(if (a.row > c.row) a.col else c.col);
                    try out.append(arena, .{ .repeat = .{ .count = rows, .inner = down } });
                    try out.append(arena, .move_line_start);
                    if (end_col > 0) try out.append(arena, .{ .repeat = .{ .count = end_col, .inner = right } });
                }
            },
        }
        return out.items;
    }

    fn trackDot(self: *Buffer, list: []const EditOp, visual: ?VisualShape, arena: Allocator) Allocator.Error!void {
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
        // The key that entered Insert is part of the change even when it
        // only moved (`A` is `move_line_end` + the typed text): vim's `.`
        // after `A!<Esc>` appends, it does not insert at the cursor.
        if (!mutates and !in_insert) return;
        for (self.dot_pending.items) |o| o.free(self.gpa);
        self.dot_pending.clearRetainingCapacity();
        if (visual) |v| try self.appendDot(try self.reselectOps(v, arena));
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

    /// `.` (`count` = 0) or `{count}.`: a count replaces the count of
    /// the recorded change — the first `repeat` in the record, where the
    /// handler put the operator's motion — and sticks for the next bare
    /// `.` (`:help .`). A record with no counted op (`A!<Esc>`, `oX<Esc>`)
    /// is replayed `count` times, which is what `3A!` / `3oX` do anyway.
    /// The replay is one undo step whatever it contains.
    fn dotRepeat(self: *Buffer, count: u32, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!BufferEvent {
        const d = self.dot orelse return .noop;
        self.replaying_dot = true;
        defer self.replaying_dot = false;
        var times: u32 = 1;
        if (count > 0) {
            if (countedOp(d)) |n| n.* = count else times = count;
        }
        const tok = try self.editor.beginAtomic();
        var changed = false;
        for (0..times) |_| {
            if (try self.applyOps(d, clip, viewport_rows, arena)) changed = true;
        }
        self.editor.endAtomic(tok);
        if (!changed) self.editor.popCheckpoint();
        // A replayed change that entered insert mode leaves the handler
        // there; the replay already typed the text, so drop back.
        if (self.input.mode() == .insert or self.input.mode() == .replace) self.input.onBlur();
        return if (changed) .edited else .redraw;
    }

    /// The count in a recorded change: the first counted op's.
    fn countedOp(list: []EditOp) ?*u32 {
        for (list) |*o| if (o.countPtr()) |n| return n;
        return null;
    }

    // ─── macros ───

    fn macroToggle(self: *Buffer, reg: u8, clip: *Clipboard) Allocator.Error!BufferEvent {
        if (self.recording) |*r| {
            // The `q` that stopped us was recorded too — drop it.
            _ = r.keys.pop();
            const keys = try r.keys.toOwnedSlice(self.gpa);
            try clip.putMacro(r.reg, keys);
            clip.last_macro = r.reg;
            self.recording = null;
            return .redraw;
        }
        // `q<reg>` arrived before recording started, so neither key is in
        // the register.
        self.recording = .{ .reg = reg };
        return .redraw;
    }

    fn macroReplay(self: *Buffer, reg_in: u8, count: u32, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        const reg = if (reg_in == '@') (clip.last_macro orelse return .noop) else reg_in;
        const keys = clip.macro(reg) orelse return .noop;
        if (self.replay_depth >= max_replay_depth) return .noop;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        clip.last_macro = reg;
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
            // Uppercase marks are the app's (a file + position).
            .set_mark => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                try self.marks.put(self.gpa, c, self.editor.rowCol());
                return .redraw;
            },
            .jump_to_mark_line => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                const p = self.marks.get(c) orelse return .noop;
                const row = @min(p.row, self.editor.lineCount() - 1);
                self.editor.cursor = self.editor.firstNonWs(row);
                self.editor.goal_col = null;
                return .redraw;
            },
            .jump_to_mark_exact => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                const p = self.marks.get(c) orelse return .noop;
                self.editor.placeCursor(@min(p.row, self.editor.lineCount() - 1), p.col);
                return .redraw;
            },
            .macro_record_into => |reg| return self.macroToggle(reg, clip),
            .macro_replay_from => |m| return self.macroReplay(m.reg, m.count, clip, viewport_rows, wrap_width, arena),
            else => return .{ .app = cmd },
        }
    }
};

// ─── tests: the feed harness ────────────────────────────────────────────

const testing = std.testing;

/// Parse `<esc>`, `<cr>`, `<c-r>`, `<a-x>`, `<s-down>`… and plain chars
/// into keys. `<lt>` is a literal `<`, `<gt>` a `>` (needed only under
/// modifiers), `<u+XXXX>` a char UTF-8 cannot spell. The inverse is
/// `formatKeys`; `macros_store.zig` writes registers in this notation.
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
    inline for (token_names) |n| {
        if (std.ascii.eqlIgnoreCase(rest, n[0])) {
            // Terminals report shift+tab as backtab.
            if (n[1] == .tab and mods.shift) {
                var m = mods;
                m.shift = false;
                return .{ .code = .backtab, .mods = m };
            }
            return .{ .code = n[1], .mods = mods };
        }
    }
    if (std.ascii.eqlIgnoreCase(rest, "lt")) return .{ .code = .{ .char = '<' }, .mods = mods };
    if (std.ascii.eqlIgnoreCase(rest, "gt")) return .{ .code = .{ .char = '>' }, .mods = mods };
    if (std.ascii.eqlIgnoreCase(rest, "space")) return .{ .code = .{ .char = ' ' }, .mods = mods };
    if (rest.len > 2 and std.ascii.toLower(rest[0]) == 'u' and rest[1] == '+') {
        const c = std.fmt.parseInt(u21, rest[2..], 16) catch return null;
        return .{ .code = .{ .char = c }, .mods = mods };
    }
    // One char, any script.
    if (rest.len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch 0;
        if (n == rest.len) {
            if (std.unicode.utf8Decode(rest) catch null) |c| return .{ .code = .{ .char = c }, .mods = mods };
        }
    }
    if (rest.len >= 2 and std.ascii.toLower(rest[0]) == 'f') {
        const n = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
        return .{ .code = .{ .f = n }, .mods = mods };
    }
    return null;
}

const token_names = .{
    .{ "esc", .esc },       .{ "cr", .enter },  .{ "enter", .enter },  .{ "tab", .tab },        .{ "bs", .backspace },
    .{ "del", .delete },    .{ "left", .left }, .{ "right", .right },  .{ "up", .up },          .{ "down", .down },
    .{ "home", .home },     .{ "end", .end },   .{ "pgup", .page_up }, .{ "pgdn", .page_down }, .{ "backtab", .backtab },
    .{ "insert", .insert },
};

/// The name `parseToken` reads a named key back from.
fn tokenName(code: KeyCode) []const u8 {
    return switch (code) {
        .esc => "esc",
        .enter => "cr",
        .tab => "tab",
        .backtab => "backtab",
        .backspace => "bs",
        .delete => "del",
        .insert => "insert",
        .left => "left",
        .right => "right",
        .up => "up",
        .down => "down",
        .home => "home",
        .end => "end",
        .page_up => "pgup",
        .page_down => "pgdn",
        .char, .f => unreachable,
    };
}

/// Write `keys` in the `parseKeys` notation. Plain chars go out
/// verbatim (`<` as `<lt>`); anything with a modifier, and every named
/// key, goes out in angle brackets. `parseKeys(formatKeys(k)) == k` for
/// every key a terminal can deliver — with one fold: shift+tab is
/// written as `<backtab>`, which is what terminals report anyway.
pub fn formatKeys(w: *std.Io.Writer, keys: []const Key) std.Io.Writer.Error!void {
    for (keys) |k| try formatKey(w, k);
}

pub fn formatKey(w: *std.Io.Writer, key_in: Key) std.Io.Writer.Error!void {
    var k = key_in;
    if (k.code == .tab and k.mods.shift) {
        k.code = .backtab;
        k.mods.shift = false;
    }
    const plain = !k.mods.ctrl and !k.mods.alt and !k.mods.shift and !k.mods.super;
    if (plain and k.code == .char) {
        const c = k.code.char;
        if (c == '<') return w.writeAll("<lt>");
        var buf: [4]u8 = undefined;
        if (std.unicode.utf8Encode(c, &buf)) |n| return w.writeAll(buf[0..n]) else |_| return w.print("<u+{x}>", .{c});
    }
    try w.writeByte('<');
    if (k.mods.ctrl) try w.writeAll("c-");
    if (k.mods.alt) try w.writeAll("a-");
    if (k.mods.shift) try w.writeAll("s-");
    if (k.mods.super) try w.writeAll("d-");
    switch (k.code) {
        .char => |c| switch (c) {
            '<' => try w.writeAll("lt"),
            '>' => try w.writeAll("gt"),
            ' ' => try w.writeAll("space"),
            else => {
                var buf: [4]u8 = undefined;
                if (std.unicode.utf8Encode(c, &buf)) |n| try w.writeAll(buf[0..n]) else |_| try w.print("u+{x}", .{c});
            },
        },
        .f => |n| try w.print("f{d}", .{n}),
        else => try w.writeAll(tokenName(k.code)),
    }
    try w.writeByte('>');
}

/// `keys` as spec text on `gpa`.
pub fn keysToSpec(gpa: Allocator, keys: []const Key) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    formatKeys(&out.writer, keys) catch return error.OutOfMemory;
    return out.toOwnedSlice();
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
    try vim("cwX<esc>", "hell|o world", "hell|X world"); // on the last char: just that char
    try vim("2cwX<esc>", "|a b c", "|X c");
    try vim("c2wX<esc>", "|a.b c", "|Xb c"); // `.` is its own word
    try vim("cwX<esc>", "a| b", "a|Xb"); // on a blank: the blanks
    try vim("cWX<esc>", "|a.b c", "|X c");
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
    // `=` re-indents by the braces above: one line, a motion, the file, a selection.
    try vim("==", "f() {\n|x;\n}", "f() {\n    |x;\n}");
    try vim("gg=G", "f() {\nx;\n  if (a) {\n  y;\n}\n|}", "|f() {\n    x;\n    if (a) {\n        y;\n    }\n}");
    try vim("=j", "f() {\n|x;\n  y;\n}", "f() {\n    |x;\n    y;\n}");
    try vim("Vj=", "f() {\n|x;\n  y;\n}", "f() {\n    |x;\n    y;\n}");
    try vim("G=gg", "|f() {\n  x;\n}\n", "|f() {\n    x;\n}\n");
    try vim("==", "|f() {\nx;\n}", "|f() {\nx;\n}"); // nothing to change: no edit
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
    // One Insert session is one undo step, whatever was typed in it.
    try vim("Oone<cr>two<esc>u", "|abc", "|abc");
    try vim("ia<tab>b<cr>c<bs><esc>u", "|x", "|x");
    try vim("cwfoo<esc>u", "|hello world", "|hello world");
    try vim("Oone<cr>two<esc>u<c-r>", "|abc", "one\ntw|o\nabc");
    try vim("ione<esc>itwo<esc>u", "|x", "on|ex");
    try vim("Rab<esc>u", "|xyz", "|xyz");
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
    // A count replaces the change's count and sticks: `3.` after `cw` is `3cw`.
    try vim("cwX<esc>j03.", "|a b\nc d e f", "X b\n|X f");
    try vim("cwX<esc>j03.j0.", "|a b\nc d e f\ng h i j", "X b\nX f\n|X j");
    try vim("dw2.", "|a b c d e", "|d e");
    try vim("2dd3.", "|a\nb\nc\nd\ne\nf", "|f");
    try vim("A!<esc>j2.", "|a\nb", "a!\nb!|!");
    // `.` with an insert is one undo step.
    try vim("cwX<esc>j0.u", "|a b\nc d", "X b\n|c d");
    try vim("p.", "|a", "|a"); // empty register: nothing to repeat
    // A visual operator repeats over the same amount of text from the cursor.
    try vim("Vjd.", "|a\nb\nc\nd\ne", "|e");
    try vim("vlld.", "|abcdefg", "|g");
    try vim("vjd.", "|ab\ncd\nef\ngh", "|f\ngh"); // one line down, same end column
    try vim("Vjdj.", "|a\nb\nc\nd\ne\nf", "c\n|f");
    try vim("Vjd.", "|alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\n", "|echo\nfoxtrot\n");
    try vim("<c-v>jld.", "|abcd\nefgh\nijkl\nmnop", "|\n\nijkl\nmnop");
}

test "closed folds are one line to j / k and to dd / yy" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa, .vim, "|fn a() {\n  1\n  2\n}\nfn b() {\n  3\n}\nend");
    defer h.deinit();
    try h.buf.folds.put(gpa, 0, 3);
    try h.buf.folds.put(gpa, 4, 6);
    // `j` from a fold header lands after the fold; `k` from below lands on it.
    try h.feed("j");
    try testing.expectEqual(@as(usize, 4), h.buf.editor.currentLine());
    try h.feed("j");
    try testing.expectEqual(@as(usize, 7), h.buf.editor.currentLine());
    try h.feed("k");
    try testing.expectEqual(@as(usize, 4), h.buf.editor.currentLine());
    try h.feed("2k");
    try testing.expectEqual(@as(usize, 0), h.buf.editor.currentLine());
    // A count walks visible lines; the last visible line stops.
    try h.feed("2j");
    try testing.expectEqual(@as(usize, 7), h.buf.editor.currentLine());
    try h.feed("j");
    try testing.expectEqual(@as(usize, 7), h.buf.editor.currentLine());
    // `yy` on a fold yanks every line of it.
    try h.feed("ggyy");
    try testing.expectEqualStrings("fn a() {\n  1\n  2\n}\n", h.clip.text());
    // `dd` on a fold removes the fold with its lines; the next fold shifts up.
    try h.feed("dd");
    try testing.expectEqualStrings("fn b() {\n  3\n}\nend", h.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 1), h.buf.folds.count());
    try testing.expectEqual(@as(usize, 0), h.buf.folds.keys()[0]);
    try testing.expectEqual(@as(usize, 2), h.buf.folds.values()[0]);
    // `dj` from a fold takes the fold and the line after it.
    try h.feed("dj");
    try testing.expectEqualStrings("", h.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 0), h.buf.folds.count());
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

test "macro registers are shared through the clipboard: `qa` in one buffer, `@a` in another" {
    const gpa = testing.allocator;
    var a = try Buffer.init(gpa, "one\ntwo", .vim, .{ .tab_width = 4 });
    defer a.deinit();
    var b = try Buffer.init(gpa, "three\nfour", .vim, .{ .tab_width = 4 });
    defer b.deinit();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const feed = struct {
        fn run(buf: *Buffer, c: *Clipboard, ar: Allocator, spec: []const u8) !void {
            const keys = try parseKeys(testing.allocator, spec);
            defer testing.allocator.free(keys);
            for (keys) |k| _ = try buf.feedKey(k, c, 10, null, ar);
        }
    }.run;
    try feed(&a, &clip, arena.allocator(), "qaA!<esc>jq");
    try testing.expectEqualStrings("one!\ntwo", a.editor.bytes());
    try testing.expect(!a.isRecording());
    try testing.expectEqual(@as(usize, 4), clip.macro('a').?.len);
    try testing.expectEqual(@as(?u8, 'a'), clip.last_macro);
    // A different buffer, the same clipboard: the register replays.
    try feed(&b, &clip, arena.allocator(), "@a");
    try testing.expectEqualStrings("three!\nfour", b.editor.bytes());
    try feed(&b, &clip, arena.allocator(), "@@");
    try testing.expectEqualStrings("three!\nfour!", b.editor.bytes());
    // A fresh clipboard knows nothing.
    var empty = Clipboard.init(gpa);
    defer empty.deinit();
    try feed(&b, &empty, arena.allocator(), "@a");
    try testing.expectEqualStrings("three!\nfour!", b.editor.bytes());
}

test "key spec round-trips: every code, every modifier set, chars of every kind" {
    const gpa = testing.allocator;
    const key_mod = @import("../core/key.zig");
    const codes = [_]KeyCode{
        .{ .char = 'a' },     .{ .char = 'Z' },    .{ .char = '<' }, .{ .char = '>' }, .{ .char = ' ' },
        .{ .char = '-' },     .{ .char = '\n' },
        .{ .char = 'é' },
        .{ .char = '日' },
        .{ .char = 0x1F600 }, .{ .char = 0xD800 }, .enter,           .tab,             .backtab,
        .esc,                 .backspace,          .delete,          .insert,          .up,
        .down,                .left,               .right,           .home,            .end,
        .page_up,             .page_down,          .{ .f = 1 },      .{ .f = 12 },     .{ .f = 20 },
    };
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(gpa);
    var bits: u5 = 0;
    while (bits < 16) : (bits += 1) {
        const mods: key_mod.Mods = @bitCast(@as(u4, @intCast(bits)));
        for (codes) |c| try keys.append(gpa, .{ .code = c, .mods = mods });
    }
    const spec = try keysToSpec(gpa, keys.items);
    defer gpa.free(spec);
    const back = try parseKeys(gpa, spec);
    defer gpa.free(back);
    try testing.expectEqual(keys.items.len, back.len);
    for (keys.items, back) |want_in, got| {
        // The one fold: shift+tab is backtab.
        var want = want_in;
        if (want.code == .tab and want.mods.shift) {
            want.code = .backtab;
            want.mods.shift = false;
        }
        testing.expect(want.code.eql(got.code) and want.mods.eql(got.mods)) catch |err| {
            std.debug.print("\n  want {any}\n  got  {any}\n", .{ want, got });
            return err;
        };
    }
    // The plain spellings a human would write come out unchanged.
    const human = "ihello<esc>0<c-v>jl<s-down><lt>x<f5><a-cr>";
    const parsed = try parseKeys(gpa, human);
    defer gpa.free(parsed);
    const again = try keysToSpec(gpa, parsed);
    defer gpa.free(again);
    try testing.expectEqualStrings(human, again);
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

test "vim ctrl+a / ctrl+x, gA align, gq reflow" {
    try vim("<c-a>", "|value = 41", "value = 4|2");
    try vim("<c-x><c-x>", "|value = 41", "value = 3|9");
    try vim("5<c-a>", "|x 9", "x 1|4");
    try vim("10<c-x>", "|5", "-|5");
    try vim("<c-a>", "|a-1", "a-|2"); // a minus glued to an identifier is not a sign
    try vim("<c-a>", "|x -1", "x |0");
    try vim("<c-a>", "|none", "|none");
    try vim("<c-a>u", "|41", "|41");
    try vim("gAip=", "|a = 1\nbb = 2\n\nc = 3", "|a  = 1\nbb = 2\n\nc = 3");
    try vim("gAj=", "|a = 1\nbb = 2\nc = 3", "|a  = 1\nbb = 2\nc = 3");
    try vim("VjgA=", "|a = 1\nbb = 2", "|a  = 1\nbb = 2");
    try vim("vjgA=", "|a = 1\nbb = 2", "|a  = 1\nbb = 2");
    try vim("gAip<esc>x", "|a = 1\nbb = 2", "| = 1\nbb = 2"); // Esc drops the range
    try vim("gAip=", "|a = 1\nb = 2", "|a = 1\nb = 2"); // already aligned
    const long = "word " ** 19 ++ "word";
    try vim("gqq", "|" ++ long, "|" ++ "word " ** 15 ++ "word\n" ++ "word " ** 3 ++ "word");
    try vim("gqip", "|" ++ long, "|" ++ "word " ** 15 ++ "word\n" ++ "word " ** 3 ++ "word");
    try vim("gqj", "|a\nb\n\nc", "|a b\n\nc");
    try vim("gqq", "|a b", "|a b");
}

test "vim comment toggle uses the buffer's token; a commentless buffer is a no-op" {
    var h = try Harness.init(testing.allocator, .vim, "|a\n  b\nc");
    defer h.deinit();
    try h.feed("gcc");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    h.buf.editor.comment_token = "// ";
    try h.feed("gcc");
    try testing.expectEqualStrings("// a\n  b\nc", h.buf.editor.bytes());
    try h.feed("gcj");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    try h.feed("gcip");
    try testing.expectEqualStrings("// a\n  // b\n// c", h.buf.editor.bytes());
    try h.feed("j.");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes()); // `.` replays the whole-paragraph toggle
    try h.feed("<c-/>"); // the paragraph toggle left the cursor on its first line
    try testing.expectEqualStrings("// a\n  b\nc", h.buf.editor.bytes());
    try h.feed("u");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    try testing.expectEqualStrings("// ", commentTokenFor("zig")[0]);
    try testing.expectEqualStrings(" -->", commentTokenFor("html")[1]);
    try testing.expectEqualStrings("", commentTokenFor("txt")[0]);
    try testing.expectEqualStrings("", commentTokenFor(null)[0]);
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
    try h.feed("diq");
    try testing.expectEqualStrings("select_inner_smart_quote", h.buf.last_unsupported.?);
    try h.feed("O!<esc>");
    try testing.expectEqual(@as(usize, 3), h.buf.folds.keys()[0]);
    try testing.expectEqual(@as(usize, 4), h.buf.folds.values()[0]);
    try h.feed("dd");
    try testing.expectEqual(@as(usize, 2), h.buf.folds.keys()[0]);
}

test "buffer: save adds the trailing newline and parks the cursor after it (Rust parity: R then A<esc>R! appends)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const file = try std.fs.path.join(gpa, &.{ path, "data.txt" });
    defer gpa.free(file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "abcdef" });
    var buf = try Buffer.load(gpa, io, file, .vim, .{});
    defer buf.deinit();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const feed = struct {
        fn run(b: *Buffer, c: *Clipboard, a: Allocator, spec: []const u8) !void {
            const keys = try parseKeys(testing.allocator, spec);
            defer testing.allocator.free(keys);
            for (keys) |k| _ = try b.feedKey(k, c, 10, null, a);
        }
    }.run;
    try feed(&buf, &clip, arena.allocator(), "RXYZ<esc>");
    try buf.save(io);
    try testing.expectEqualStrings("XYZdef\n", buf.editor.bytes());
    try testing.expectEqual(buf.editor.len(), buf.editor.cursor);
    try testing.expect(!buf.dirty);
    try feed(&buf, &clip, arena.allocator(), "A<esc>R!<esc>");
    try buf.save(io);
    const back = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1024));
    defer gpa.free(back);
    try testing.expectEqualStrings("XYZdef!\n", back);
    // Off, the buffer is written verbatim.
    buf.ensure_trailing_newline = false;
    try feed(&buf, &clip, arena.allocator(), "GA<del><esc>");
    try buf.save(io);
    try testing.expectEqualStrings("XYZdef!", buf.editor.bytes());
    const verbatim = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1024));
    defer gpa.free(verbatim);
    try testing.expectEqualStrings("XYZdef!", verbatim);
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

test "editorconfig on a buffer: CRLF files load as LF and save back as CRLF; trim + final newline on save; tabs as the indent" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const path = try std.fs.path.join(gpa, &.{ pbuf[0..n], "win.txt" });
    defer gpa.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "win.txt", .data = "one  \r\ntwo\t\r\n  three" });
    var buf = try Buffer.load(gpa, testing.io, path, .vim, .{ .tab_width = 4 });
    defer buf.deinit();
    try testing.expectEqualStrings("one  \ntwo\t\n  three", buf.editor.bytes());
    try testing.expectEqual(editorconfig.Eol.crlf, buf.eol);
    try testing.expect(!buf.dirty);
    // The defaults: nothing trimmed, a final newline added, CRLF kept.
    try buf.save(testing.io);
    const first = try tmp.dir.readFileAlloc(testing.io, "win.txt", gpa, .limited(256));
    defer gpa.free(first);
    try testing.expectEqualStrings("one  \r\ntwo\t\r\n  three\r\n", first);
    buf.editor.setCursor(6); // on "two"
    // A `.editorconfig` says: trim, LF, tabs 8 wide, indent with tabs.
    buf.applyEditorconfig(.{ .indent_style = .tab, .tab_width = 8, .end_of_line = .lf, .trim_trailing_whitespace = true, .insert_final_newline = false });
    try testing.expectEqual(@as(usize, 8), buf.editor.tab_width);
    try testing.expect(buf.editor.use_tabs);
    try testing.expectEqual(@as(usize, 8), buf.input.vim.tab_width);
    try testing.expect(buf.input.vim.use_tabs);
    try buf.save(testing.io);
    const second = try tmp.dir.readFileAlloc(testing.io, "win.txt", gpa, .limited(256));
    defer gpa.free(second);
    try testing.expectEqualStrings("one\ntwo\n  three\n", second); // the earlier save's newline stays
    // The trim was one undo step; the cursor stayed on "two" (byte 6 → 4).
    try testing.expectEqual(@as(usize, 4), buf.editor.cursor);
    try testing.expectEqualStrings("one\ntwo\n  three\n", buf.editor.bytes());
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try buf.editor.apply(.undo, 10, &clip, arena.allocator());
    try testing.expectEqualStrings("one  \ntwo\t\n  three\n", buf.editor.bytes());
    _ = try buf.editor.apply(.redo, 10, &clip, arena.allocator());
    // Tab in insert mode types a `\t`; `>>` pads with one.
    const keys = try parseKeys(gpa, "ggI<tab><esc>j>>");
    defer gpa.free(keys);
    for (keys) |k| _ = try buf.feedKey(k, &clip, 10, null, arena.allocator());
    try testing.expectEqualStrings("\tone\n\ttwo\n  three\n", buf.editor.bytes());
    // `indent_size` alone sets the unit; the display width follows it.
    buf.applyEditorconfig(.{ .indent_style = .space, .indent_size = 2 });
    try testing.expect(!buf.editor.use_tabs);
    try testing.expectEqual(@as(usize, 2), buf.editor.tab_width);
    try testing.expectEqual(@as(usize, 2), buf.input.vim.tab_width);
    // `indent_size = tab` with a tab_width: the unit is the width.
    buf.applyEditorconfig(.{ .indent_size_is_tab = true, .tab_width = 3 });
    try testing.expectEqual(@as(usize, 3), buf.input.vim.tab_width);
    // An empty resolution changes nothing.
    buf.applyEditorconfig(.{});
    try testing.expectEqual(@as(usize, 3), buf.editor.tab_width);
    try testing.expect(buf.trim_trailing_ws_on_save);
    // A handler rebuilt for the other style keeps the file's indent.
    buf.applyEditorconfig(.{ .indent_style = .tab, .indent_size = 6 });
    buf.setInputStyle(.standard, .{ .tab_width = 4 });
    try testing.expectEqual(@as(usize, 6), buf.input.standard.tab_width);
    try testing.expect(buf.input.standard.use_tabs);
    buf.setInputStyle(.vim, .{ .tab_width = 4 });
    try testing.expectEqual(@as(usize, 6), buf.input.vim.tab_width);
    try testing.expect(buf.input.vim.use_tabs);
    // A lone-CR file is detected too; `withEol` writes it back.
    try testing.expectEqual(editorconfig.Eol.cr, Buffer.detectEol("a\rb\r"));
    try testing.expectEqual(editorconfig.Eol.lf, Buffer.detectEol("no breaks"));
    const cr = try Buffer.withEol(gpa, "a\nb\n", .cr);
    defer gpa.free(cr);
    try testing.expectEqualStrings("a\rb\r", cr);
    const norm = try Buffer.normalizeEol(gpa, "a\r\nb\rc\n");
    defer gpa.free(norm);
    try testing.expectEqualStrings("a\nb\nc\n", norm);
}
