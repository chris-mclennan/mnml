//! `Buffer` — one window on a `Document`: the `Editor` view, the
//! handler that drives it, the dot-repeat holder and the macro recording
//! in flight. The file — its path, dirty flag, marks, save settings —
//! is the document's, shared with every other window on it (`initOn`).
//! `feedKey` is THE seam: the only place an `InputResult` is
//! destructured.
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
const Document = editor_mod.Document;
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

/// `append`: `qA` — the keys go after what register `a` already holds.
pub const Recording = struct { reg: u8, keys: std.ArrayList(Key) = .empty, append: bool = false };

pub const commentTokenFor = @import("document.zig").commentTokenFor;
pub const DiskStamp = @import("document.zig").DiskStamp;

pub const Buffer = struct {
    gpa: Allocator,
    /// This window's view. A heap box, owned here.
    editor: *Editor,
    /// `editor.doc` — the shared text and file, here so `buf.doc.path`
    /// reads short. Retained by the editor for as long as it exists.
    doc: *Document,
    input: InputHandler,
    /// `@tagName` of the last op the editor refused with `Unsupported`,
    /// for the app to toast. Static string.
    last_unsupported: ?[]const u8 = null,
    /// The find matches nearest the cursor (`gn` / `gN`), byte ranges.
    /// The find state lives with the app; it seeds these before a key.
    find_next: ?[2]usize = null,
    find_prev: ?[2]usize = null,

    /// Dot-repeat: the last change, gpa-owned ops.
    dot: ?[]EditOp = null,
    /// Index in `dot` of the `repeat` op a counted Insert (`3iab<Esc>`)
    /// appended, so a `{count}.` replaces THAT count rather than the
    /// first counted motion in the record.
    dot_insert_repeat: ?usize = null,
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

    /// vim's `".` register: what the last Insert session typed, derived
    /// from its ops when it closed (a backspace takes a char back).
    /// gpa-owned.
    last_inserted: ?[]u8 = null,

    pub const max_replay_depth = 8;

    /// A window on a fresh document holding `text`; the config's tab
    /// width is the document's indent until a `.editorconfig` says
    /// otherwise.
    pub fn init(gpa: Allocator, text: []const u8, style: input.Style, cfg: input.Config) Allocator.Error!Buffer {
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        return initOwning(gpa, copy, style, cfg);
    }

    /// `init`, taking the (gpa-owned) text instead of copying it. On
    /// error the caller still owns `text`.
    pub fn initOwning(gpa: Allocator, text: []u8, style: input.Style, cfg: input.Config) Allocator.Error!Buffer {
        const doc = try Document.createOwning(gpa, text);
        errdefer {
            // Hand the text back before the document goes.
            doc.text = .empty;
            doc.destroy();
        }
        doc.tab_width = @max(cfg.tab_width, 1);
        doc.indent_unit = @max(cfg.tab_width, 1);
        return initOn(gpa, doc, style, cfg);
    }

    /// A second window on `doc` (vim's `:split`): its own cursor and
    /// handler, the document's indent settings. The document is retained
    /// until `deinit`.
    pub fn initOn(gpa: Allocator, doc: *Document, style: input.Style, cfg: input.Config) Allocator.Error!Buffer {
        const ed = try Editor.initOn(gpa, doc);
        errdefer ed.deinit();
        var handler = InputHandler.init(gpa, style, cfg);
        handler.configure(.{ .tab_width = doc.indent_unit, .text_width = cfg.text_width, .use_tabs = doc.use_tabs });
        return .{
            .gpa = gpa,
            .editor = ed,
            .doc = doc,
            .input = handler,
        };
    }

    pub fn deinit(self: *Buffer) void {
        const gpa = self.gpa;
        self.editor.deinit();
        self.input.deinit();
        if (self.dot) |d| freeOps(gpa, d);
        for (self.dot_pending.items) |o| o.free(gpa);
        self.dot_pending.deinit(gpa);
        if (self.recording) |*r| r.keys.deinit(gpa);
        if (self.last_inserted) |s| gpa.free(s);
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
        const eol = detectEol(raw);
        // What was read becomes the document's text — a large file is in
        // memory once while it opens, not three times.
        const text = if (eol == .lf) raw else blk: {
            defer gpa.free(raw);
            break :blk try normalizeEol(gpa, raw, eol);
        };
        var buf = initOwning(gpa, text, style, cfg) catch |err| {
            gpa.free(text);
            return err;
        };
        errdefer buf.deinit();
        buf.doc.eol = eol;
        try buf.setPath(path);
        return buf;
    }

    /// The file's line ending, chosen so that saving an untouched file
    /// writes its bytes back (Neovim's `fileformats` rule): CRLF only
    /// when EVERY `\n` has a `\r` before it, a lone `\r` only when the
    /// file has no `\n` at all, else LF — and under LF any `\r` is an
    /// ordinary byte of its line, so a mixed file, a progress bar's `\r`
    /// or a `\r\r\n` is kept exactly as it came.
    pub fn detectEol(text: []const u8) editorconfig.Eol {
        const first_lf = std.mem.indexOfScalar(u8, text, '\n') orelse
            return if (std.mem.indexOfScalar(u8, text, '\r') != null) .cr else .lf;
        if (first_lf == 0 or text[first_lf - 1] != '\r') return .lf;
        var i = first_lf + 1;
        while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |j| : (i = j + 1) {
            if (text[j - 1] != '\r') return .lf;
        }
        return .crlf;
    }

    /// The buffer's text for a file read as `eol`: under CRLF each
    /// `\r\n` becomes `\n` (any other `\r` stays), under CR each `\r`
    /// does; LF text is already the buffer's.
    pub fn normalizeEol(gpa: Allocator, text: []const u8, eol: editorconfig.Eol) Allocator.Error![]u8 {
        var out = try std.ArrayList(u8).initCapacity(gpa, text.len);
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            switch (eol) {
                .lf => out.appendAssumeCapacity(c),
                .cr => out.appendAssumeCapacity(if (c == '\r') '\n' else c),
                .crlf => if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
                    out.appendAssumeCapacity('\n');
                    i += 1;
                } else out.appendAssumeCapacity(c),
            }
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
        return self.doc.setPath(path);
    }

    pub const SaveError = Allocator.Error || Io.Dir.WriteFileError || error{NoPath};

    /// Write the document; every window on it is clean afterwards.
    pub fn save(self: *Buffer, io: Io) SaveError!void {
        const path = self.doc.path orelse return error.NoPath;
        if (self.doc.trim_trailing_ws_on_save) try self.trimTrailingWhitespace();
        if (self.doc.ensure_trailing_newline) try self.fixTrailingNewline();
        const data = try withEol(self.gpa, self.editor.bytes(), self.doc.eol);
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
        self.doc.tab_width = @max(tab_display, 1);
        self.doc.use_tabs = use_tabs;
        self.doc.indent_unit = @max(indent_unit, 1);
        self.input.configure(.{ .tab_width = self.doc.indent_unit, .text_width = self.textWidth(), .use_tabs = use_tabs });
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
            const use_tabs = if (r.indent_style) |s| s == .tab else self.doc.use_tabs;
            const unit = r.indentUnit() orelse self.doc.tab_width;
            const display = r.tabDisplayWidth() orelse self.doc.tab_width;
            self.setIndent(display, unit, use_tabs);
            self.doc.indent_pinned = true;
        }
        if (r.end_of_line) |e| self.doc.eol = e;
        if (r.trim_trailing_whitespace) |v| self.doc.trim_trailing_ws_on_save = v;
        if (r.insert_final_newline) |v| self.doc.ensure_trailing_newline = v;
    }

    /// Append the missing final `\n` as one undoable edit. The cursor,
    /// the anchor and the goal column keep their places — every one of
    /// them is at or before the old end, so all stay on the last line;
    /// `replace_range` alone would park the cursor after the newline, on
    /// a phantom line N+1 (the jump Rust mnml's save has). A Normal-mode
    /// cursor past the last char (only reachable through an edit that
    /// left it there) steps back onto that char, where vim keeps it.
    fn fixTrailingNewline(self: *Buffer) Allocator.Error!void {
        const n = self.editor.len();
        if (n == 0 or self.editor.bytes()[n - 1] == '\n') return;
        const cursor = self.editor.cursor;
        const anchor = self.editor.anchor;
        const goal_col = self.editor.goal_col;
        var clip = Clipboard.init(self.gpa);
        defer clip.deinit();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        _ = self.editor.apply(.{ .replace_range = .{ .start = n, .end = n, .text = "\n" } }, 0, &clip, arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return,
        };
        self.editor.cursor = if (cursor >= n and self.input.mode() == .normal) self.editor.prevBoundary(n) else @min(cursor, n);
        self.editor.anchor = if (anchor) |a| @min(a, n) else null;
        self.editor.goal_col = goal_col;
    }

    /// Record the current text as the on-disk text.
    pub fn markSaved(self: *Buffer) Allocator.Error!void {
        return self.doc.markSaved();
    }

    pub fn setInputStyle(self: *Buffer, style: input.Style, cfg: input.Config) void {
        if (self.input.style() == style) return;
        self.input.deinit();
        self.input = InputHandler.init(self.gpa, style, cfg);
        // The file's indent (a `.editorconfig`) outlives the handler.
        self.input.configure(.{ .tab_width = self.doc.indent_unit, .text_width = cfg.text_width, .use_tabs = self.doc.use_tabs });
        self.editor.anchor = null;
    }

    // ─── the seam ───

    pub fn makeCtx(self: *const Buffer, wrap_width: ?usize, clip: *Clipboard) EditCtx {
        const ed = self.editor;
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
            .register_empty = clip.text().len == 0,
        };
    }

    /// Feed one key through the handler → editor. `viewport_rows` sizes
    /// page motions; `wrap_width` is non-null when `[ui] wrap` is on.
    /// `arena` is the frame arena.
    pub fn feedKey(self: *Buffer, key: Key, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        if (self.doc.read_only) return .{ .unhandled = key };
        if (self.recording) |*r| try r.keys.append(self.gpa, key);
        const ctx = self.makeCtx(wrap_width, clip);
        // What a visual operator would act on, before the key resolves —
        // the shape `.` re-applies (`:help visual-repeat`).
        const visual: ?VisualShape = if (self.input.mode().isVisual()) self.visualShape() else null;
        // A session the app ended without a key (a blur) closes before
        // this key's own snapshot lands.
        const undo_before = self.editor.doc.history.undoLen();
        const cursor_before = self.editor.cursor;
        self.syncInsertSession(undo_before);
        const result = try self.input.handleKey(key, ctx, arena);
        const ev: BufferEvent = switch (result) {
            .ops => |list| try self.applyHandlerOps(list, visual, clip, viewport_rows, arena),
            .consumed => .redraw,
            .ignored => .{ .unhandled = key },
            .app => |cmd| try self.handleApp(cmd, clip, viewport_rows, wrap_width, arena),
        };
        self.stampUndoCursor(undo_before, cursor_before);
        self.syncInsertSession(undo_before);
        self.clampNormalCursor();
        return ev;
    }

    /// The undo entry a key pushed remembers where the change began:
    /// the cursor the key started from, or the first changed byte when
    /// that lies before it — vim's `uh_cursor` is taken after an operator
    /// has moved to its area's start (`vim -es`: `Vjygvdu` → 1:1 though
    /// `gv` left the cursor on line 2) — not where the op's own
    /// checkpoint found it after the handler's motions. So `u` after
    /// `3>>`, `dd` or `gvd` lands where the change began
    /// (`undo.placeAfterHistoryHop`).
    fn stampUndoCursor(self: *Buffer, undo_before: usize, cursor_before: usize) void {
        const h = &self.editor.doc.history;
        if (h.undoLen() <= undo_before) return;
        var at = cursor_before;
        // The entry's state, read through its hull against the text as
        // it now is — never built. (Out of memory: the cursor the key
        // started from stands.)
        if (h.undoViewAt(self.gpa, undo_before) catch null) |old| {
            defer self.gpa.free(old.mid);
            const now = self.editor.bytes();
            const old_len = old.len();
            const n = @min(old_len, now.len);
            // The run the two share up to the hull is equal by construction.
            var prefix: usize = @min(old.p, n);
            while (prefix < n and old.at(prefix) == now[prefix]) prefix += 1;
            // A change that starts at a line's `\n` (a deleted last
            // line) begins on the line after it, where the cursor was.
            const changed = if (prefix < old_len and old.at(prefix) == '\n') prefix + 1 else prefix;
            const changed_line_start = if (old.lastIndexOfScalar(changed, '\n')) |i| i + 1 else 0;
            const cursor_line_start = if (old.lastIndexOfScalar(cursor_before, '\n')) |i| i + 1 else 0;
            if (changed_line_start < cursor_line_start) at = changed_line_start;
        }
        h.setUndoCursor(undo_before, at);
    }

    /// vim's Normal mode keeps the cursor ON a character: a motion or an
    /// edit that lands one past a non-empty line's last char (`k` from a
    /// longer line, `Ctrl-F` onto the last line, `D`, `x` on the last
    /// char) steps back onto it (`:help ve`; `vim -es`: `G$k` → 12:6 on
    /// `eleven`). The goal column is untouched, so the next `j` / `k`
    /// still reaches the remembered column. Insert's one-shot `Ctrl-O`
    /// is exempt: there the cursor may sit past the end (`:help i_CTRL-O`).
    fn clampNormalCursor(self: *Buffer) void {
        const v = switch (self.input) {
            .vim => |*v| v,
            .standard => return,
        };
        if (v.vmode != .normal or v.insert_oneshot_normal) return;
        const ed = self.editor;
        if (ed.anchor != null or ed.block_anchor != null) return;
        const line = ed.currentLine();
        const bol = ed.lineStart(line);
        if (ed.cursor > bol and ed.cursor == ed.lineEnd(line)) ed.cursor = ed.prevBoundary(ed.cursor);
    }

    /// A handler's op list: applied fold-aware, then recorded for `.`.
    /// The record keeps the handler's own list, so `.` on another fold
    /// re-expands against that fold.
    fn applyHandlerOps(self: *Buffer, list: []const EditOp, visual: ?VisualShape, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!BufferEvent {
        const changed = try self.applyOps(try self.foldAwareOps(list, arena), clip, viewport_rows, arena);
        try self.trackDot(list, visual, arena);
        return if (changed) .edited else .redraw;
    }

    /// Open / anchor / close the Insert undo session against the mode
    /// the handler is in now. `undo_before` is the undo depth before the
    /// key: the first snapshot pushed past it is the session's — the
    /// `cw` that entered Insert and the text typed after undo together.
    fn syncInsertSession(self: *Buffer, undo_before: usize) void {
        const ed = self.editor;
        const typing = switch (self.input.mode()) {
            .insert, .replace => true,
            else => false,
        };
        if (typing) {
            if (!self.insert_session) {
                self.insert_session = true;
                self.insert_undo_target = null;
            }
            if (self.insert_undo_target == null and ed.doc.history.undoLen() > undo_before) self.insert_undo_target = undo_before + 1;
        } else if (self.insert_session) {
            self.insert_session = false;
            if (self.insert_undo_target) |t| ed.doc.history.truncateUndo(t);
            self.insert_undo_target = null;
            ed.in_insert_run = false;
        }
    }

    /// Apply ops that did not come from a key (LSP edits, replays).
    /// Returns whether the text changed. An op the editor refuses is
    /// recorded in `last_unsupported` and skipped.
    pub fn applyOps(self: *Buffer, list: []const EditOp, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!bool {
        if (self.doc.read_only) return false;
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
        if (changed) self.doc.recomputeDirty();
        return changed;
    }

    fn shiftFoldsAfter(self: *Buffer, line: usize, delta: isize) Allocator.Error!void {
        // Mutate the entry arrays in place, then rebuild the index; the
        // entry count never grows here.
        var i: usize = 0;
        while (i < self.editor.folds.count()) {
            const start = self.editor.folds.keys()[i];
            if (start <= line) {
                i += 1;
                continue;
            }
            const ns: isize = @as(isize, @intCast(start)) + delta;
            const ne: isize = @as(isize, @intCast(self.editor.folds.values()[i])) + delta;
            if (ns < 0 or ne < ns) {
                self.editor.folds.orderedRemoveAt(i);
                continue;
            }
            self.editor.folds.keys()[i] = @intCast(ns);
            self.editor.folds.values()[i] = @intCast(ne);
            i += 1;
        }
        try self.editor.folds.reIndex(self.gpa);
    }

    // ─── folds ───

    /// The closed fold holding `row`, as `(start, end)`.
    pub fn foldAt(self: *const Buffer, row: usize) ?[2]usize {
        for (self.editor.folds.keys(), self.editor.folds.values()) |s, e| if (row >= s and row <= e and e > s) return .{ s, e };
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
        if (self.editor.folds.count() == 0 or list.len == 0) return list;
        const ed = self.editor;
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
                while (i < self.editor.folds.count()) {
                    const start = self.editor.folds.keys()[i];
                    if (start >= first and start <= last) self.editor.folds.orderedRemoveAt(i) else i += 1;
                }
                try self.editor.folds.reIndex(self.gpa);
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
            if (!in_insert) {
                try self.noteInserted();
                try self.finishDot();
            }
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

    /// An op the APP applied on the handler's behalf — the newline of a
    /// counted `<count>o`, the opening move of `<count>A` — is part of
    /// the change, so `.` has to see it. The key path records itself
    /// (`applyHandlerOps`); `App.applyOps` does not.
    pub fn trackAppOps(self: *Buffer, list: []const EditOp, arena: Allocator) Allocator.Error!void {
        try self.trackDot(list, null, arena);
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
        self.dot_insert_repeat = null;
    }

    /// The deferred half of a counted Insert (`3iab<Esc>`, `3ofoo<Esc>`)
    /// joins the change the Esc just closed, so `.` repeats the count
    /// too — vim records the whole command, count and all (`:help .`).
    pub fn appendDotInsertRepeat(self: *Buffer, times: u32, text: []const u8) Allocator.Error!void {
        if (times == 0 or text.len == 0) return;
        const d = self.dot orelse return;
        const gpa = self.gpa;
        const inner = try gpa.create(EditOp);
        errdefer gpa.destroy(inner);
        inner.* = .{ .insert_str = try gpa.dupe(u8, text) };
        errdefer inner.free(gpa);
        // Esc closed the record with its `move_left_no_cross_line`; the
        // copies belong at the insertion point, ahead of that step back.
        var at = d.len;
        if (at > 0 and std.meta.activeTag(d[at - 1]) == .move_left_no_cross_line) at -= 1;
        const grown = try gpa.realloc(d, d.len + 1);
        std.mem.copyBackwards(EditOp, grown[at + 1 ..], grown[at .. grown.len - 1]);
        grown[at] = .{ .repeat = .{ .count = times, .inner = inner } };
        self.dot = grown;
        self.dot_insert_repeat = at;
    }

    /// The Insert session just closed: what it typed, from the pending
    /// dot record, becomes `last_inserted`.
    fn noteInserted(self: *Buffer) Allocator.Error!void {
        var typed: std.ArrayList(u8) = .empty;
        errdefer typed.deinit(self.gpa);
        for (self.dot_pending.items) |o| try collectTyped(&typed, self.gpa, o);
        if (self.last_inserted) |s| self.gpa.free(s);
        self.last_inserted = try typed.toOwnedSlice(self.gpa);
    }

    fn collectTyped(typed: *std.ArrayList(u8), gpa: Allocator, op: EditOp) Allocator.Error!void {
        switch (op) {
            .insert_char => |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return;
                try typed.appendSlice(gpa, buf[0..n]);
            },
            .insert_str => |s| try typed.appendSlice(gpa, s),
            .insert_newline => try typed.append(gpa, '\n'),
            .backspace => {
                // One char back, whatever its byte length.
                while (typed.pop()) |b| if (b & 0xC0 != 0x80) break;
            },
            .repeat => |r| for (0..r.count) |_| try collectTyped(typed, gpa, r.inner.*),
            .atomic => |list| for (list) |o| try collectTyped(typed, gpa, o),
            else => {},
        }
    }

    /// What the last Insert session typed (vim's `".`), null before
    /// the first one.
    pub fn lastInserted(self: *const Buffer) ?[]const u8 {
        return self.last_inserted;
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
            if (self.dot_insert_repeat) |idx| {
                // `2.` after `3ix`: the new count replaces the insert's,
                // and the record already types one copy itself.
                d[idx].repeat.count = count -| 1;
            } else if (countedOp(d)) |n| n.* = count else times = count;
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

    /// `drop_stop_key`: the `q` that stops a recording was itself recorded
    /// (`feedKey` appends before the handler runs) and is dropped; a stop
    /// that came from a runner (`runApp`) recorded no key.
    fn macroToggle(self: *Buffer, reg: u8, clip: *Clipboard, drop_stop_key: bool) Allocator.Error!BufferEvent {
        if (self.recording) |*r| {
            if (drop_stop_key) _ = r.keys.pop();
            const spec = try keysToSpec(self.gpa, r.keys.items);
            defer self.gpa.free(spec);
            if (r.append and clip.macro(r.reg) != null) {
                const joined = try std.mem.concat(self.gpa, u8, &.{ clip.macro(r.reg).?, spec });
                defer self.gpa.free(joined);
                try clip.putMacro(r.reg, joined);
            } else try clip.putMacro(r.reg, spec);
            clip.last_macro = r.reg;
            r.keys.deinit(self.gpa);
            self.recording = null;
            return .redraw;
        }
        // `q<reg>` arrived before recording started, so neither key is in
        // the register. An uppercase name appends to the lowercase
        // register (`:help q`).
        const upper = reg >= 'A' and reg <= 'Z';
        self.recording = .{ .reg = if (upper) reg + ('a' - 'A') else reg, .append = upper };
        return .redraw;
    }

    /// `@reg`: the register's text as keys. A register yanked back with
    /// `yy` ends in a newline, which replays as Enter — vim executes it
    /// the same way.
    fn macroReplay(self: *Buffer, reg_in: u8, count: u32, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        const reg = if (reg_in == '@') (clip.last_macro orelse return .noop) else reg_in;
        const spec = clip.macro(reg) orelse return .noop;
        if (self.replay_depth >= max_replay_depth) return .noop;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        clip.last_macro = reg;
        // The register may be rewritten by what it replays (`"ay$`):
        // take a copy first.
        const keys = try parseKeys(self.gpa, spec);
        defer self.gpa.free(keys);
        var edited = false;
        for (0..@max(count, 1)) |_| {
            for (keys) |k_in| {
                const k: Key = if (k_in.code == .char and k_in.code.char == '\n') Key.named(.enter) else k_in;
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

    /// An `AppCommand` from a runner rather than a key (the palette's
    /// `vim.dot_repeat`, the statusline's macro chip): handled exactly
    /// as one the handler returned, minus the key that would have been
    /// recorded. A read-only document does nothing.
    pub fn runApp(self: *Buffer, cmd: AppCommand, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        if (self.doc.read_only) return .noop;
        const undo_before = self.editor.doc.history.undoLen();
        const cursor_before = self.editor.cursor;
        const ev = switch (cmd) {
            .macro_record_into => |reg| try self.macroToggle(reg, clip, false),
            else => try self.handleApp(cmd, clip, viewport_rows, wrap_width, arena),
        };
        self.stampUndoCursor(undo_before, cursor_before);
        self.clampNormalCursor();
        return ev;
    }

    fn handleApp(self: *Buffer, cmd: AppCommand, clip: *Clipboard, viewport_rows: usize, wrap_width: ?usize, arena: Allocator) Allocator.Error!BufferEvent {
        switch (cmd) {
            .dot_repeat => |n| return self.dotRepeat(n, clip, viewport_rows, arena),
            // Uppercase marks are the app's (a file + position).
            .set_mark => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                try self.doc.marks.put(self.gpa, c, self.editor.cursor);
                return .redraw;
            },
            .jump_to_mark_line => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                const p = self.doc.markPos(c) orelse return .noop;
                const row = @min(p.row, self.editor.lineCount() - 1);
                self.editor.cursor = self.editor.firstNonWs(row);
                self.editor.goal_col = null;
                return .redraw;
            },
            .jump_to_mark_exact => |c| {
                if (c >= 'A' and c <= 'Z') return .{ .app = cmd };
                const p = self.doc.markPos(c) orelse return .noop;
                self.editor.placeCursor(@min(p.row, self.editor.lineCount() - 1), p.col);
                return .redraw;
            },
            .macro_record_into => |reg| return self.macroToggle(reg, clip, true),
            .macro_replay_from => |m| return self.macroReplay(m.reg, m.count, clip, viewport_rows, wrap_width, arena),
            .operator_to_mark => |m| return self.operatorToMark(m.op, m.mark, m.exact, clip, viewport_rows, arena),
            else => return .{ .app = cmd },
        }
    }

    /// `d'a` / `` y`a `` / `c'a` (`:help '`): the range from the cursor to
    /// the mark — whole lines for `'`, charwise and exclusive for the
    /// backtick — as the op list the operator would have built from a
    /// motion, so folds, `.` and the registers see the usual shape. A
    /// mark that is not set does nothing (Vim: E20).
    fn operatorToMark(self: *Buffer, op: u8, mark: u8, exact: bool, clip: *Clipboard, viewport_rows: usize, arena: Allocator) Allocator.Error!BufferEvent {
        const ed = self.editor;
        const mark_byte = @min(self.doc.marks.get(mark) orelse return .noop, ed.len());
        const row = ed.lineOfByte(mark_byte);
        var list: std.ArrayList(EditOp) = .empty;
        if (exact) {
            try list.appendSlice(arena, &.{ .{ .set_cursor_byte = @min(ed.cursor, mark_byte) }, .select_start, .{ .set_cursor_byte = @max(ed.cursor, mark_byte) } });
        } else {
            const lo = @min(ed.currentLine(), row);
            const hi = @max(ed.currentLine(), row);
            try list.appendSlice(arena, &.{ .{ .set_cursor_byte = ed.lineStart(lo) }, .select_start, .{ .set_cursor_byte = ed.lineEnd(hi) } });
        }
        switch (op) {
            'd' => {
                if (!exact) try list.append(arena, .normalize_linewise_selection);
                try list.append(arena, .delete_selection);
            },
            'y' => {
                if (!exact) try list.append(arena, .normalize_linewise_selection);
                try list.appendSlice(arena, &.{ if (exact) .yank_selection else .yank_selection_linewise, .move_cursor_to_selection_start, .select_clear });
            },
            'c' => {
                if (!exact) try list.append(arena, .normalize_linewise_selection_inner);
                try list.appendSlice(arena, &.{ .{ .replace_selection = "" }, .continue_insert_run });
                self.input.requestInsertMode();
            },
            else => return .noop,
        }
        return self.applyHandlerOps(list.items, null, clip, viewport_rows, arena);
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
    // `j` on the last line and `k` on the first stay put (`vim -es`: `G$j` → 13:22).
    try vim("j", "a\nb|c", "a\nb|c");
    try vim("$j", "abc\n|xy", "abc\nx|y");
    try vim("k", "|a\nb", "|a\nb");
    // A shorter line clamps onto its last char; the goal column survives.
    try vim("$k", "ab\n|abcdef", "a|b\nabcdef");
    try vim("$kj", "ab\n|abcdef", "ab\nabcde|f");
    // Ctrl-F onto the last line: on a char, at the goal column (`G$<C-f>` → 13:22).
    try vim("G$<c-f>", "|alpha\nbeta\ngamma", "alpha\nbeta\ngamm|a");
    try vim("<c-f>", "|alpha\nbeta\ngamma", "alpha\nbeta\n|gamma");
    // `}` / `{`: the next EMPTY line after some text — the line just
    // below counts (`5G}` → 6), a blank-only line does not (`2G}` → 6
    // past a `"  "` line 3); at the end, the last line's last char.
    try vim("}", "|a\n\nb\n\nc", "a\n|\nb\n\nc");
    try vim("}", "a\n|b\n\nc", "a\nb\n|\nc");
    try vim("}", "|a\n  \nb\n\nc", "a\n  \nb\n|\nc");
    try vim("}", "a\n|\n\nb\nc", "a\n\n\nb\n|c");
    try vim("}}", "|a\n\nb\n\nc", "a\n\nb\n|\nc");
    try vim("{", "a\n\nb\n|c", "a\n|\nb\nc");
    try vim("{", "a\n\n|b\nc", "a\n|\nb\nc");
    try vim("{", "a\n  \nb\n|c", "|a\n  \nb\nc");
    try vim("d}", "a\n|b\nc", "a\n|");
    try vim("k", "a\nb|c", "|a\nbc"); // onto the last char, never past it (`:help ve`)
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
    try vim("i<cr><esc>", "ab|c", "ab\n|c"); // Esc never crosses a line start (:help i_<Esc>)
    try vim("A<esc>", "|abc", "ab|c");
    try vim("i<esc>", "a|bc", "|abc");
    try vim("i<esc>", "|abc", "|abc"); // column 0 stays
    try vim("o<esc>", "a|b\nc", "ab\n|\nc");
    try vim("O<esc>", "a|b\nc", "|\nab\nc");
    try vim("A<cr><esc>", "|ab", "ab\n|");
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
    try vim("dw", "hello |world\nx", "hello| \nx"); // Normal: onto the last char, never past it
    try vim("d2w", "|a b c d", "|c d");
    try vim("2dw", "|a b c d", "|c d");
    try vim("d3w", "|a b\nc d", "|d");
    try vim("de", "|hello world", "| world");
    try vim("db", "hello |world", "|world");
    try vim("d$", "a|bcd\nx", "|a\nx");
    try vim("D", "a|bcd\nx", "|a\nx");
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
    try vim("da(", "f(a, |b)", "|f");
    try vim("dib", "f(a, |b)", "f(|)");
    try vim("di\"", "x \"a |b\" y", "x \"|\" y");
    try vim("da\"", "x \"a |b\" y", "x | y");
    try vim("dip", "a\n|b\n\nc", "|\nc"); // linewise (`:help ip`); Rust left an empty line
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
    try vim("3~", "|abc", "AB|C");
    try vim("J", "|a\n  b", "a| b");
    try vim("3J", "|a\nb\nc\nd", "a b| c\nd");
    try vim("gJ", "|a\n  b", "a|  b");
    try vim("guiw", "|ABC def", "|abc def");
    try vim("gUiw", "|abc def", "|ABC def");
    // A doubled case operator keeps the cursor on its own line: on the
    // first non-blank without a count (vim: `1G9|g~~` on `    Hello`
    // ends at 1:5), at the original cursor with one (`1G5|2gUU` ends at
    // 1:5); a count covers n lines like `{n}cc`.
    try vim("guu", "|ABC\nD", "|abc\nD");
    try vim("gUU", "|abc\nd", "|ABC\nd");
    try vim("g~~", "|aBc\nd", "|AbC\nd");
    try vim("ll" ++ "g~~", "|aBc\nd", "|AbC\nd");
    try vim("ll" ++ "g~~", "  |aBc\nd", "  |AbC\nd");
    try vim("2gUU", "a|bc\nde\nfg", "A|BC\nDE\nfg");
    try vim("3guu", "|AB\nCD\nEF\nGH", "|ab\ncd\nef\nGH");
    try vim("g~iw", "a|Bc d", "|AbC d");
    // `u` lands on the restored text (vim `u_undoredo`, `vim -es`):
    // the saved cursor when its line is within the changed block
    // (`4Gddu` → 4:1), else the first changed line's first non-blank.
    try vim("ddu", "a\nb\nc\n|d\ne", "a\nb\nc\n|d\ne");
    try vim("ddggu", "a\nb\nc\n|d\ne", "a\nb\nc\n|d\ne");
    try vim("3>>Gu", "|a\nb\nc\nd", "|a\nb\nc\nd");
    try vim("xggu", "a\nb\n  c|d\ne", "a\nb\n  c|d\ne");
    try vim("Gddggu", "a\nb\nc\n|d", "a\nb\nc\n|d");
    try vim("ddu<c-r>", "a\n|b\nc", "a\n|c");
    try vim("A!<esc>ggu", "a\n|b\nc", "a\n|b\nc");
    // A Visual operator's change begins at the area's start, wherever
    // the cursor sat in it (`vim -es`: `ggVjygvdu` → 1:1).
    try vim("Vjygvdu", "|a\nb\nc\nd", "|a\nb\nc\nd");
    try vim("jdkuu", "a\n|b\nc", "a\n|b\nc"); // `dk` is two entries here; the second `u` lands on the area's start
    // `is` / `as` (`:help is`): a sentence ends at `.` `!` `?` + white
    // space or at the paragraph's edge; `as` takes the space after it.
    try vim("dis", "One two. Th|ree four. Five", "One two. | Five"); // `is` keeps the space after (`vim -es`)
    try vim("das", "One two. Th|ree four. Five", "One two. |Five");
    try vim("das", "One two. Th|ree four.", "One two|.");
    try vim("dis", "a|lpha bravo\ncharlie\n\ndelta", "|\ndelta"); // no full stop: the paragraph is the sentence, line break included
    try vim("vis" ++ "y", "One. T|wo? Three", "One. |Two? Three");
    try vim("cis" ++ "X<esc>", "One. T|wo! Three", "One. |X Three");
    // `>` / `<` end on the range's first line, first non-blank
    // (`:help >>`; `vim -es`: `gg3>>` → 1:2 with a tab, `gg3>>j.` → 2:3)
    // — never the last line's end, so `.` shifts the same lines again.
    try vim(">>", "|a\nb", "    |a\nb");
    try vim("<<", "    a|b\nc", "|ab\nc");
    try vim(">j", "|a\nb\nc", "    |a\n    b\nc");
    try vim("2>>", "|a\nb\nc", "    |a\n    b\nc");
    try vim("3>>", "|a\nb\nc\nd\ne", "    |a\n    b\n    c\nd\ne");
    try vim("3>>.", "|a\nb\nc\nd\ne", "        |a\n        b\n        c\nd\ne");
    try vim("3>>j.", "|a\nb\nc\nd\ne", "    a\n        |b\n        c\n    d\ne");
    try vim("Vj>", "|a\nb\nc", "    |a\n    b\nc");
    try vim("Vj>.", "|a\nb\nc", "        |a\n        b\nc");
    try vim(">ip", "a\n|b\nc\n\nd", "    |a\n    b\n    c\n\nd");
    try vim("<j", "    |a\n    b\nc", "|a\nb\nc");
    try vim("<k", "    a\n    |b\nc", "|a\nb\nc");
    try vim(">>", "  |a\nb", "      |a\nb");
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
    try vim("yljp", "|ab\n\nc", "ab\n|a\nc"); // charwise p on an empty line puts on that line
    try vim("yljP", "|ab\n\nc", "ab\n|a\nc");
    try vim("2yyGp", "|a\nb\nc", "a\nb\nc\n|a\nb");
    try vim("ywP", "|ab cd", "ab |ab cd");
    try vim("yw$p", "|ab cd", "ab cdab| "); // `p` ends on the put text's last char
    try vim("yiwwviwp", "|ab cd", "ab a|b");
    try vim("ddp", "|a\nb", "b\n|a");
    try vim("dwwP", "|a b c", "b a |c");
    try vim("\"ayyj\"ap", "|a\nb", "a\nb\n|a");
    try vim("\"ayyj\"Ayy\"ap", "|a\nb", "a\nb\n|a\nb");
    try vim("\"_dd", "|a\nb", "|b");
    try vim("yyjdd\"0p", "|a\nb\nc", "a\nc\n|a");
    try vim("ddjdd\"2p", "|a\nb\nc\nd", "b\nd\n|a");
    try vim("dddd\"1p\"2p", "|a\nb\nc", "c\nb\n|a");
    try vim("Yp", "a|b\nc", "ab|b\nc"); // Rust mnml `Y` yanks cursor→EOL charwise
    try vim("yl$p", "|abc", "abc|a");
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
    try h.buf.editor.folds.put(gpa, 0, 3);
    try h.buf.editor.folds.put(gpa, 4, 6);
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
    try testing.expectEqual(@as(usize, 1), h.buf.editor.folds.count());
    try testing.expectEqual(@as(usize, 0), h.buf.editor.folds.keys()[0]);
    try testing.expectEqual(@as(usize, 2), h.buf.editor.folds.values()[0]);
    // `dj` from a fold takes the fold and the line after it.
    try h.feed("dj");
    try testing.expectEqualStrings("", h.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 0), h.buf.editor.folds.count());
}

test "round two: count p, ci\" forward, dd at EOF, Visual Ctrl-A, gv linewise, d'a, marks follow edits" {
    // `[count]p` puts the text count times in a row (`:help p`).
    try vim("yy3p", "|a\nb", "a\n|a\na\na\nb");
    try vim("yiw3p", "|ab", "aababab|b"); // the put leaves the cursor after the text
    // `ci"` before the first quote takes the first quoted string after it.
    try vim("0ci\"X<esc>", "|x = \"y\"", "x = \"|X\"");
    // `dd` on the last line lands on the new last line, never past it.
    try vim("Gdd", "|a\nb\n", "|a\n");
    try vim("j3dd", "|a\nb\nc\nd\n", "|a\n");
    try vim("G3dd", "a\n|b\nc\nd\n", "a\nb\n|c\n"); // the count takes what is there
    // `v_CTRL-A` bumps every selected line's first number; `g` makes a progression.
    try vim("Vj<c-a>", "|x 1\ny 1", "|x 2\ny 2");
    try vim("Vjg<c-a>", "|x 1\ny 1", "|x 2\ny 3");
    // `gv` comes back in the mode the selection was made in.
    try vim("Vjygvd", "|a\nb\nc", "|c");
    // A mark is a motion: `d'a` is linewise to the mark.
    try vim("majjd'a", "|a\nb\nc\nd", "|d");
    // Marks move with the text: a line opened above shifts `'a` down.
    try vim("jjmaggOn<esc>'ax", "|a\nb\nc", "n\na\nb\n|");
}

test "vim marks, macros and visual mode" {
    try vim("majj'a", "|a\nb\nc", "|a\nb\nc");
    try vim("lmajj`a", "|ab\nb\nc", "a|b\nb\nc");
    try vim("majj'z", "|a\nb\nc", "a\nb\n|c");
    try vim("majj'a", "  |a\nb\nc", "  |a\nb\nc");
    try vim("qaA!<esc>jq@a", "|a\nb\nc", "a!\nb!\n|c");
    try vim("qaA!<esc>jq@a@@", "|a\nb\nc", "a!\nb!\nc|!");
    try vim("qqA!<esc>jq@@", "|a\nb\nc", "a!\nb!\n|c");
    try vim("qaxq2@a", "|abcd", "|d");
    try vim("qaIX<esc>jqqbA!<esc>jq@a@b", "|a\nb\nc\nd", "Xa\nb!\nXc\nd|!");
    try vim("@z", "|a", "|a");
    // A macro is its register: `"ap` pastes the keys, `"ay$` re-records, `:reg`-style read-back.
    try vim("qaA!<esc>q\"ap", "|a", "a!A!<esc|>"); // charwise, like any recorded register
    try vim("qaA!<esc>qj0\"ay$dd@a", "|a\nA?<esc>", "a!|?"); // an edited register replays
    try vim("qaxqj\"ayygg@a", "|abc\nd\ne", "|e"); // `"ayy` holds `d<CR>`: the newline replays as Enter, so `@a` is `dj`
    try vim("\"axjA!<esc>\"ap", "|ab\nc", "b\nc!|a"); // `"ax` fills a named register too
    try vim("vwd", "|hello world", "|orld");
    try vim("vwy$p", "|hello world", "hello worldhello |w");
    try vim("v$d", "a|bc\nd", "|a\nd");
    try vim("vlly", "|abc", "|abc");
    try vim("vllcZ<esc>", "|abcd", "|Zd");
    try vim("Vjd", "|a\nb\nc", "|c");
    try vim("Vjy$p", "|a\nb\nc", "a\n|a\nb\nb\nc");
    try vim("VjyGp", "|a\nb\nc", "a\nb\nc\n|a\nb");
    try vim("Vx", "a\n|b\nc", "a\n|c");
    try vim("V>", "|a\nb", "    |a\nb");
    try vim("Vj<lt>", "    |a\n    b\nc", "|a\nb\nc");
    try vim("vU", "|abc", "|Abc");
    try vim("v~", "|abc", "|Abc");
    try vim("vlu", "|ABC", "|abC");
    try vim("viwd", "hel|lo world", "| world");
    try vim("viwy$p", "hel|lo world", "hello worldhell|o");
    try vim("viwlld", "|ab cd", "|"); // a motion after the object widens again
    try vim("vipd", "|a\nb\n\nc", "|\nc"); // `vip` is linewise (`:help v_ip`); Rust left an empty line
    try vim("vi(d", "f(a|b)", "f(|)");
    try vim("va\"d", "x \"a|b\" y", "x | y");
    try vim("vlold", "|abcd", "a|cd");
    try vim("vly<esc>gvd", "|abc", "|c");
    try vim("v<esc>x", "|abc", "|bc");
    try vim("vjJ", "|a\nb", "a| b");
    try vim("vlrX", "|abc", "|XXc");
    try vim("vlp", "|abc", "a|bc"); // nothing to put: nothing deleted (Vim: E353); Rust dropped the selection
    try vim("ylvlp", "|abc", "a|c");
    try vim("vVd", "a\n|b\nc", "a\n|c");
    try vim("Vvd", "a\n|bc\nd", "a\n|c\nd");
    try vim("vv", "|abc", "|abc");
    try vim("<c-v>jd", "|ab\ncd", "|b\nd");
    try vim("<c-v>jld", "a|bcd\nefgh\nij", "a|d\neh\nij");
    try vim("<c-v>jlx", "a|bcd\nefgh", "a|d\neh");
    try vim("<c-v>jldp", "a|bcd\nefgh", "adbc\nf|g\neh"); // the block is in the register charwise (Rust parity)
    try vim("<c-v>jly$p", "a|bcd\nefgh", "abcdbc\nf|g\nefgh");
    try vim("<c-v>jlyP", "a|bcd\nefgh", "abc\nfg|bcd\nefgh"); // `y` parks at the rectangle's top-left; `P` lands after the text
    try vim("<c-v>jl<esc>x", "a|bcd\nefgh", "abcd\nef|h");
    try vim("<c-v>kd", "ab\n|cd", "|b\nd"); // the rectangle is anchor→cursor in either direction
    try vim("<c-v>jjld", "|abc\nx\nabc", "|c\n\nc"); // a short row contributes nothing
    try vim("<c-v>jvd", "|ab\ncd", "ab\n|d"); // `v` / `V` from V-BLOCK re-anchor at the cursor (Rust parity; vim keeps the anchor)
    try vim("<c-v>jVd", "a|b\ncd\ne", "ab\n|e");
    try vim("<c-v>jd", "|ab\ncd", "|b\nd");
    try vim("<c-v>jdu", "|ab\ncd", "|ab\ncd"); // `u` lands at the block's top-left, where the change began (`vim -es`)
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
    try testing.expectEqualStrings("A!<esc>j", clip.macro('a').?);
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
    try multi("|ab\ncd", &.{ .{ .keys = "i" }, below, .{ .keys = "<cr><esc>" } }, "\n|ab\n\ncd"); // Esc stays on the opened line
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
    // A `-` before the digits is the sign whatever precedes it — Neovim
    // 0.12.5: `a-1` → `a0`, `val-3 abc` → `val-2 abc`, `x_-7` → `x_-6`.
    try vim("<c-a>", "|a-1", "a|0");
    try vim("<c-a>", "|val-3 abc", "val-|2 abc");
    try vim("<c-a>", "|x_-7", "x_-|6");
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
    h.buf.doc.comment_token = "// ";
    try h.feed("gcc");
    try testing.expectEqualStrings("// a\n  b\nc", h.buf.editor.bytes());
    try h.feed("gcj");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 0), h.buf.editor.cursor); // `gc{motion}` ends on the first line
    try testing.expect(h.buf.editor.anchor == null);
    try h.feed("gcip");
    try testing.expectEqualStrings("// a\n  // b\n// c", h.buf.editor.bytes());
    try h.feed("j.");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes()); // `.` replays the whole-paragraph toggle
    try h.feed("<c-/>"); // the paragraph toggle left the cursor on its first line
    try testing.expectEqualStrings("// a\n  b\nc", h.buf.editor.bytes());
    try h.feed("u");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    // Visual `gc` leaves NORMAL on the range's first line, no selection.
    try h.feed("jVjgc");
    try testing.expectEqualStrings("a\n  // b\n// c", h.buf.editor.bytes());
    try testing.expect(h.buf.editor.anchor == null);
    try testing.expectEqual(h.buf.editor.lineStart(1), h.buf.editor.cursor);
    try h.feed("u");
    try testing.expectEqualStrings("a\n  b\nc", h.buf.editor.bytes());
    try testing.expectEqualStrings("// ", commentTokenFor("zig")[0]);
    try testing.expectEqualStrings(" -->", commentTokenFor("html")[1]);
    try testing.expectEqualStrings("", commentTokenFor("txt")[0]);
    try testing.expectEqualStrings("", commentTokenFor(null)[0]);
}

test "vim Vc keeps an empty line where the lines were" {
    // `V…c` is `cc` over the range: the lines go, one empty line stays,
    // Insert opens on it (`:help v_c`); `R` from any Visual is the same.
    try vim("Vc", "a\n|b\nc", "a\n|\nc");
    try vim("Vjc", "a\n|b\nc\nd", "a\n|\nd");
    try vim("Vkc", "a\nb\n|c\nd", "a\n|\nd");
    try vim("Vcx", "|a\nb", "x|\nb");
    try vim("Vc", "a\n|b", "a\n|");
    try vim("vjR", "a\n|b\nc\nd", "a\n|\nd");
    try vim("vR", "a\n|b\nc", "a\n|\nc");
    try vim("Vc<esc>u", "a\n|b\nc", "a\n|b\nc");
    // Charwise `c` still takes exactly the selection.
    try vim("vjc", "a\n|b\nc", "a\n|");
}

test "vim replace mode and cmdline" {
    try vim("RXY<esc>", "|abc", "X|Yc");
    try vim("RXYZW<esc>", "|abc", "XYZ|W");
    try vim("RXY<bs><bs><esc>", "|abc", "|abc");
    try vim("RX<cr>Y<esc>", "|abc", "X\n|Yc");
    try vim("RX<esc>", "|abc", "|Xbc");
    try vim("R<cr><esc>", "ab|cd", "ab\n|cd"); // Esc stays on the new line
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
    try testing.expect(h.buf.doc.dirty);
    try h.feed("<c-s>");
    try testing.expectEqual(AppCommand.save, h.last_app.?);
    try h.buf.markSaved();
    try testing.expect(!h.buf.doc.dirty);
    try h.feed("<c-z>");
    try testing.expect(h.buf.doc.dirty);
    try h.feed("<c-y>");
    try testing.expect(!h.buf.doc.dirty);
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
    try h.buf.editor.folds.put(testing.allocator, 2, 3);
    try h.feed("diq");
    try testing.expectEqualStrings("select_inner_smart_quote", h.buf.last_unsupported.?);
    try h.feed("O!<esc>");
    try testing.expectEqual(@as(usize, 3), h.buf.editor.folds.keys()[0]);
    try testing.expectEqual(@as(usize, 4), h.buf.editor.folds.values()[0]);
    try h.feed("dd");
    try testing.expectEqual(@as(usize, 2), h.buf.editor.folds.keys()[0]);
}

fn feedSpec(b: *Buffer, c: *Clipboard, a: Allocator, spec: []const u8) !void {
    const keys = try parseKeys(testing.allocator, spec);
    defer testing.allocator.free(keys);
    for (keys) |k| _ = try b.feedKey(k, c, 10, null, a);
}

// This test used to pin the cursor AFTER the appended newline (`cursor ==
// len`, a phantom line 2) as Rust parity, and a `A<esc>R!` chain that only
// appended because Esc then stepped back across the line start onto the
// `\n`. Both were bugs; the save keeps the cursor and vim's `R!` on the
// last char overwrites it.
test "buffer: save adds the trailing newline and the cursor keeps its place (no phantom line 2)" {
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
    try feedSpec(&buf, &clip, arena.allocator(), "RXYZ<esc>");
    try testing.expectEqual(@as(usize, 2), buf.editor.cursor);
    try buf.save(io);
    try testing.expectEqualStrings("XYZdef\n", buf.editor.bytes());
    try testing.expectEqual(@as(usize, 2), buf.editor.cursor);
    try testing.expectEqual(@as(usize, 1), buf.editor.lineCount());
    try testing.expect(!buf.doc.dirty);
    // `A<esc>` lands on `f`; `R!` overwrites it (`:help R`).
    try feedSpec(&buf, &clip, arena.allocator(), "A<esc>R!<esc>");
    try testing.expectEqual(@as(usize, 5), buf.editor.cursor);
    try buf.save(io);
    const back = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1024));
    defer gpa.free(back);
    try testing.expectEqualStrings("XYZde!\n", back);
    // A Normal cursor past the last char (a state only a direct edit
    // reaches) steps back onto that char rather than onto the newline.
    try feedSpec(&buf, &clip, arena.allocator(), "GA<del><esc>");
    try testing.expectEqualStrings("XYZde!", buf.editor.bytes());
    buf.editor.cursor = buf.editor.len();
    try buf.save(io);
    try testing.expectEqualStrings("XYZde!\n", buf.editor.bytes());
    try testing.expectEqual(@as(usize, 5), buf.editor.cursor);
    // Off, the buffer is written verbatim.
    buf.doc.ensure_trailing_newline = false;
    try feedSpec(&buf, &clip, arena.allocator(), "GA<del><esc>");
    try buf.save(io);
    try testing.expectEqualStrings("XYZde!", buf.editor.bytes());
    const verbatim = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1024));
    defer gpa.free(verbatim);
    try testing.expectEqualStrings("XYZde!", verbatim);
}

test "buffer: save keeps an Insert / standard cursor at EOF before the appended newline, and a selection" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const file = try std.fs.path.join(gpa, &.{ path, "tail.txt" });
    defer gpa.free(file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "xy" });
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    {
        var buf = try Buffer.load(gpa, io, file, .vim, .{});
        defer buf.deinit();
        try feedSpec(&buf, &clip, arena.allocator(), "Az");
        try testing.expectEqual(input.EditingMode.insert, buf.input.mode());
        try buf.save(io);
        try testing.expectEqualStrings("xyz\n", buf.editor.bytes());
        try testing.expectEqual(@as(usize, 3), buf.editor.cursor);
        try testing.expectEqual(@as(usize, 0), buf.editor.currentLine());
        try feedSpec(&buf, &clip, arena.allocator(), "!<esc>");
        try testing.expectEqualStrings("xyz!\n", buf.editor.bytes());
        try testing.expectEqual(@as(usize, 3), buf.editor.cursor);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "xy" });
    {
        var buf = try Buffer.load(gpa, io, file, .standard, .{});
        defer buf.deinit();
        try feedSpec(&buf, &clip, arena.allocator(), "<end>z<s-left><s-left>");
        try testing.expectEqual(@as(usize, 1), buf.editor.cursor);
        try testing.expectEqual(@as(?usize, 3), buf.editor.anchor);
        try buf.save(io);
        try testing.expectEqualStrings("xyz\n", buf.editor.bytes());
        try testing.expectEqual(@as(usize, 1), buf.editor.cursor);
        try testing.expectEqual(@as(?usize, 3), buf.editor.anchor);
        try testing.expect(buf.editor.hasSelection());
    }
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
    try testing.expectEqualStrings("md", buf.doc.language.?);
    try testing.expect(!buf.doc.dirty);
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const keys = try parseKeys(gpa, "A!<esc>");
    defer gpa.free(keys);
    for (keys) |k| _ = try buf.feedKey(k, &clip, 10, null, arena.allocator());
    try testing.expect(buf.doc.dirty);
    try buf.save(io);
    try testing.expect(!buf.doc.dirty);
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
    try testing.expectEqual(editorconfig.Eol.crlf, buf.doc.eol);
    try testing.expect(!buf.doc.dirty);
    // The defaults: nothing trimmed, a final newline added, CRLF kept.
    try buf.save(testing.io);
    const first = try tmp.dir.readFileAlloc(testing.io, "win.txt", gpa, .limited(256));
    defer gpa.free(first);
    try testing.expectEqualStrings("one  \r\ntwo\t\r\n  three\r\n", first);
    buf.editor.setCursor(6); // on "two"
    // A `.editorconfig` says: trim, LF, tabs 8 wide, indent with tabs.
    buf.applyEditorconfig(.{ .indent_style = .tab, .tab_width = 8, .end_of_line = .lf, .trim_trailing_whitespace = true, .insert_final_newline = false });
    try testing.expectEqual(@as(usize, 8), buf.doc.tab_width);
    try testing.expect(buf.doc.use_tabs);
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
    try testing.expect(!buf.doc.use_tabs);
    try testing.expectEqual(@as(usize, 2), buf.doc.tab_width);
    try testing.expectEqual(@as(usize, 2), buf.input.vim.tab_width);
    // `indent_size = tab` with a tab_width: the unit is the width.
    buf.applyEditorconfig(.{ .indent_size_is_tab = true, .tab_width = 3 });
    try testing.expectEqual(@as(usize, 3), buf.input.vim.tab_width);
    // An empty resolution changes nothing.
    buf.applyEditorconfig(.{});
    try testing.expectEqual(@as(usize, 3), buf.doc.tab_width);
    try testing.expect(buf.doc.trim_trailing_ws_on_save);
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
    const norm = try Buffer.normalizeEol(gpa, "a\r\nb\rc\r\n", .crlf);
    defer gpa.free(norm);
    try testing.expectEqualStrings("a\nb\rc\n", norm);
}

test "buffer: a file's line breaks survive a load and a save byte for byte, mixed ones included" {
    const gpa = testing.allocator;
    // Every file Neovim writes back unchanged after an untouched save:
    // the four mixed shapes and the pure ones.
    const cases = [_]struct { raw: []const u8, eol: editorconfig.Eol }{
        .{ .raw = "a\r\r\nb\r\r\nc\r\r\n", .eol = .crlf }, // converted twice
        .{ .raw = "head\r\n50%\r100%\r\ntail\r\n", .eol = .crlf }, // a progress bar's \r
        .{ .raw = "a\rb\nc\n", .eol = .lf }, // a lone \r first, LF after
        .{ .raw = "a\r\nb\nc\r\nd\n", .eol = .lf }, // CRLF and LF mixed
        .{ .raw = "a\r\nb\r\n", .eol = .crlf },
        .{ .raw = "a\rb\r", .eol = .cr },
        .{ .raw = "a\nb\n", .eol = .lf },
        .{ .raw = "\nb\r\n", .eol = .lf },
    };
    for (cases) |c| {
        try testing.expectEqual(c.eol, Buffer.detectEol(c.raw));
        const text = try Buffer.normalizeEol(gpa, c.raw, c.eol);
        defer gpa.free(text);
        const back = try Buffer.withEol(gpa, text, c.eol);
        defer gpa.free(back);
        try testing.expectEqualStrings(c.raw, back);
    }
}

test "buffer: the `\".` register is what the last Insert session typed, a backspace taken back; a runner's app command reaches the buffer" {
    var h = try Harness.init(testing.allocator, .vim, "|x");
    defer h.deinit();
    try testing.expect(h.buf.lastInserted() == null);
    try h.feed("iab<bs>c<esc>");
    try testing.expectEqualStrings("ac", h.buf.lastInserted().?);
    // A change with no Insert leaves it alone; the next session replaces it.
    try h.feed("dd");
    try testing.expectEqualStrings("ac", h.buf.lastInserted().?);
    try h.feed("ié<cr><esc>");
    try testing.expectEqualStrings("é\n", h.buf.lastInserted().?);
    // `runApp` is the runner's door: `.` replays the last change here.
    _ = h.arena.reset(.retain_capacity);
    const ev = try h.buf.runApp(.{ .dot_repeat = 0 }, &h.clip, 10, null, h.arena.allocator());
    try testing.expect(ev == .edited);
    try testing.expectEqualStrings("é\né\n", h.buf.editor.bytes());
}

test "buffer: a runner-stopped recording keeps its last key (no `q` to drop)" {
    var h = try Harness.init(testing.allocator, .vim, "|one\ntwo");
    defer h.deinit();
    _ = try h.buf.runApp(.{ .macro_record_into = '@' }, &h.clip, 10, null, h.arena.allocator());
    try testing.expect(h.buf.isRecording());
    try h.feed("A!<esc>");
    _ = try h.buf.runApp(.{ .macro_record_into = '@' }, &h.clip, 10, null, h.arena.allocator());
    try testing.expect(!h.buf.isRecording());
    try testing.expectEqualStrings("A!<esc>", h.clip.macro('@').?);
}

test "vim / standard: motions and deletes step over whole grapheme clusters (an emoji family, e + a combining accent)" {
    const fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const e_acute = "e\u{301}";
    const line = "a" ++ fam ++ "b " ++ e_acute ++ "x 中文z\n";
    // Neovim 0.12.5 (`exe "normal …"` on the same line) for every row.
    try vim("lx", "|" ++ line, "a|b " ++ e_acute ++ "x 中文z\n");
    try vim("3lx", "|" ++ line, "a" ++ fam ++ "b|" ++ e_acute ++ "x 中文z\n");
    try vim("5lx", "|" ++ line, "a" ++ fam ++ "b " ++ e_acute ++ "| 中文z\n");
    try vim("2lvlld", "|" ++ line, "a" ++ fam ++ "|x 中文z\n");
    try vim("$hhx", "|" ++ line, "a" ++ fam ++ "b " ++ e_acute ++ "x |文z\n");
    try vim("A<bs><bs><esc>", "|a" ++ e_acute ++ "z\n", "|a\n");
    try vim("hx", "a" ++ e_acute ++ "|z\n", "a|z\n");
    // Standard: two rights land after the family; Backspace takes all of it.
    try std_("<right><right><bs><del>", "|" ++ line, "a| " ++ e_acute ++ "x 中文z\n");
    try std_("<left><bs>", "a" ++ e_acute ++ "z|\n", "a|z\n");
    // A CR before the LF is its own character (CR LF is one cluster to
    // Unicode, never to a line): `$` lands on it and `x` takes only it.
    try vim("$x", "|ab\r\ncd\n", "a|b\ncd\n");
}
