//! mnml-fake-lsp — a deterministic language server over stdio for
//! testing mnml's LSP UI on every platform with no toolchain installed.
//!
//! It speaks JSON-RPC 2.0 with `Content-Length` framing and answers
//! every request from the text of the open documents alone (`README.md`
//! beside this file is the contract): hover on a word is `**word**`,
//! the definition of `foo` is the line that starts with `fn foo`,
//! references are the word's occurrences, completion is the file's
//! identifiers, rename rewrites every occurrence, a line holding `TODO`
//! is a warning, a code action resolves it, formatting trims trailing
//! blanks. No clocks, no environment, no randomness: the same documents
//! and the same requests give the same frames, byte for byte.
//!
//! `main` is the stdio loop; `Server` is the protocol, driven the same
//! way by the tests through an in-memory writer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const version = "0.1.0";

pub const Value = std.json.Value;

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const Location = struct { uri: []const u8, range: Range };
const TextEdit = struct { range: Range, newText: []const u8 };
/// A published diagnostic carries what a real server keys its fixes
/// on: a `code` and a `data` the client must echo back untouched in a
/// `codeAction` context (bash-language-server looks its fix up by
/// `data.id`, tsserver by `code`).
const DiagData = struct { id: []const u8 };
const Diagnostic = struct { range: Range, severity: u8, source: []const u8 = "fake-lsp", code: []const u8 = todo_code, message: []const u8, data: DiagData };
const todo_code = "fk/todo";
const CompletionItem = struct { label: []const u8, kind: u8, detail: []const u8 };
const DocSymbol = struct { name: []const u8, kind: u8, range: Range, selectionRange: Range };

/// What `initialize` answers: the capabilities mnml's client reads,
/// utf-8 positions so a byte offset is a character.
const capabilities = .{
    .positionEncoding = "utf-8",
    .textDocumentSync = .{ .openClose = true, .change = 1, .save = .{ .includeText = false } },
    .hoverProvider = true,
    .definitionProvider = true,
    .referencesProvider = true,
    .completionProvider = .{ .triggerCharacters = &[_][]const u8{"."}, .resolveProvider = false },
    .renameProvider = true,
    .documentSymbolProvider = true,
    .codeActionProvider = .{ .codeActionKinds = &[_][]const u8{"quickfix"} },
    .documentFormattingProvider = true,
};

/// `--sync incremental`: the same, advertising range sync (`change:
/// 2`) so the client sends the region it changed instead of the file.
/// A separate constant rather than a field because the reply is a
/// comptime literal either way.
const capabilities_incremental = .{
    .positionEncoding = "utf-8",
    .textDocumentSync = .{ .openClose = true, .change = 2, .save = .{ .includeText = false } },
    .hoverProvider = true,
    .definitionProvider = true,
    .referencesProvider = true,
    .completionProvider = .{ .triggerCharacters = &[_][]const u8{"."}, .resolveProvider = false },
    .renameProvider = true,
    .documentSymbolProvider = true,
    .codeActionProvider = .{ .codeActionKinds = &[_][]const u8{"quickfix"} },
    .documentFormattingProvider = true,
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    /// Where frames go: the process's stdout, or a test's buffer.
    out: *Io.Writer,
    /// Open documents by uri: owned keys, owned text.
    docs: std.StringHashMapUnmanaged([]u8) = .empty,
    /// `--log PATH`: every incoming method, one per line, rewritten on
    /// each message so a test can read it at any point.
    log_path: ?[]const u8 = null,
    /// `--sync incremental`: advertise range sync, apply each
    /// `contentChanges[]` to the stored text in order, and write what
    /// the change was into the log — the only way a script can tell a
    /// range sync from a full one.
    incremental: bool = false,
    /// `--configure`: after `initialized`, ask the client for
    /// `workspace/configuration` and answer `documentSymbol` with `[]`
    /// until it has replied — what bash-language-server does while it
    /// is still configuring, and what left mnml's outline empty.
    configure: bool = false,
    configured: bool = false,
    /// `--symbols rich`: a function's range runs to its closing `}` and
    /// every `let` is a variable symbol, the shape a real server sends;
    /// the default keeps one single-line symbol per `fn`.
    rich_symbols: bool = false,
    log: std.ArrayList(u8) = .empty,
    initialized: bool = false,
    shutdown: bool = false,
    /// `exit` landed: the loop ends.
    done: bool = false,

    pub fn init(gpa: Allocator, io: Io, out: *Io.Writer) Server {
        return .{ .gpa = gpa, .io = io, .out = out };
    }

    pub fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
        self.log.deinit(self.gpa);
        self.* = undefined;
    }

    // ─── the wire ───

    fn emit(self: *Server, json: []const u8) Io.Writer.Error!void {
        try self.out.print("Content-Length: {d}\r\n\r\n", .{json.len});
        try self.out.writeAll(json);
        try self.out.flush();
    }

    /// `{"jsonrpc":"2.0","id":ID,"result":RESULT}` — `result` is JSON text.
    fn respondRaw(self: *Server, id: Value, result: []const u8) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
        try js.beginWriteRaw();
        try js.writer.writeAll(result);
        js.endWriteRaw();
        try js.endObject();
        try self.emit(aw.written());
    }

    fn respond(self: *Server, id: Value, result: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.write(result);
        try self.respondRaw(id, aw.written());
    }

    fn respondError(self: *Server, id: Value, code: i32, message: []const u8) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("error");
        try js.write(.{ .code = code, .message = message });
        try js.endObject();
        try self.emit(aw.written());
    }

    fn notify(self: *Server, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("method");
        try js.write(method);
        try js.objectField("params");
        try js.write(params);
        try js.endObject();
        try self.emit(aw.written());
    }

    /// A request of the server's own (`workspace/configuration`); its
    /// id is one the client never issues.
    fn request_out(self: *Server, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(@as(i64, 900_000));
        try js.objectField("method");
        try js.write(method);
        try js.objectField("params");
        try js.write(params);
        try js.endObject();
        try self.emit(aw.written());
    }

    // ─── messages ───

    /// One frame's body: parse, dispatch, answer. Not JSON: ignored. A
    /// request with an unknown method gets `MethodNotFound`.
    pub fn handle(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(Value, self.gpa, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer parsed.deinit();
        const v = parsed.value;
        const method = getStr(v, "method") orelse {
            // A response to a request of ours: only `--configure` asks.
            if (self.configure and !self.configured and getField(v, "id") != null) {
                self.configured = true;
                try self.logLine("workspace/configuration answered", .{});
            }
            return;
        };
        try self.logMethod(method);
        const params = getField(v, "params") orelse Value.null;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (getField(v, "id")) |id| {
            try self.request(arena, id, method, params);
        } else {
            try self.notification(arena, method, params);
        }
    }

    fn logMethod(self: *Server, method: []const u8) !void {
        const path = self.log_path orelse return;
        try self.log.appendSlice(self.gpa, method);
        try self.log.append(self.gpa, '\n');
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = self.log.items }) catch {};
    }

    fn request(self: *Server, arena: Allocator, id: Value, method: []const u8, params: Value) !void {
        const eql = std.mem.eql;
        if (eql(u8, method, "initialize")) {
            if (self.incremental) {
                try self.respond(id, .{ .capabilities = capabilities_incremental, .serverInfo = .{ .name = "mnml-fake-lsp", .version = version } });
            } else {
                try self.respond(id, .{ .capabilities = capabilities, .serverInfo = .{ .name = "mnml-fake-lsp", .version = version } });
            }
            self.initialized = true;
            // The complaint rust-analyzer makes on a root that is no
            // crate, once, as an Error: mnml toasts it `LSP: …`.
            const root = rootPath(arena, params) orelse return;
            const manifest = try std.fs.path.join(arena, &.{ root, "Cargo.toml" });
            if (Io.Dir.cwd().access(self.io, manifest, .{})) |_| {} else |_| {
                try self.notify("window/showMessage", .{ .type = 1, .message = "Failed to discover workspace.\nConsider adding the `Cargo.toml` of the workspace." });
            }
        } else if (eql(u8, method, "shutdown")) {
            self.shutdown = true;
            try self.respondRaw(id, "null");
        } else if (eql(u8, method, "textDocument/hover")) {
            const d = self.docAt(params) orelse return self.respondRaw(id, "null");
            const word = wordAt(d.text, d.pos) orelse return self.respondRaw(id, "null");
            try self.respond(id, .{ .contents = .{ .kind = "markdown", .value = try std.fmt.allocPrint(arena, "**{s}**", .{word.text}) }, .range = word.range });
        } else if (eql(u8, method, "textDocument/definition")) {
            const d = self.docAt(params) orelse return self.respondRaw(id, "null");
            const word = wordAt(d.text, d.pos) orelse return self.respondRaw(id, "null");
            const def = definitionOf(d.text, word.text) orelse return self.respondRaw(id, "null");
            try self.respond(id, Location{ .uri = d.uri, .range = def });
        } else if (eql(u8, method, "textDocument/references")) {
            const d = self.docAt(params) orelse return self.respondRaw(id, "[]");
            const word = wordAt(d.text, d.pos) orelse return self.respondRaw(id, "[]");
            const ranges = try occurrences(arena, d.text, word.text);
            const locs = try arena.alloc(Location, ranges.len);
            for (ranges, 0..) |r, i| locs[i] = .{ .uri = d.uri, .range = r };
            try self.respond(id, locs);
        } else if (eql(u8, method, "textDocument/completion")) {
            const d = self.docAt(params) orelse return self.respondRaw(id, "null");
            const items = try identifiers(arena, d.text);
            try self.respond(id, .{ .isIncomplete = false, .items = items });
        } else if (eql(u8, method, "textDocument/rename")) {
            const d = self.docAt(params) orelse return self.respondRaw(id, "null");
            const new_name = getStr(params, "newName") orelse return self.respondError(id, -32602, "rename needs newName");
            const word = wordAt(d.text, d.pos) orelse return self.respondRaw(id, "null");
            // The document, then every sibling file of its extension in
            // its directory that holds the word — open ones from their
            // synced text, closed ones from disk — the way a real server
            // renames across a project, so a client's handling of a
            // file it does not have open can be driven.
            var files: std.ArrayList(FileEdits) = .empty;
            const ranges = try occurrences(arena, d.text, word.text);
            try files.append(arena, .{ .uri = d.uri, .edits = try renameEdits(arena, ranges, new_name) });
            try self.siblingEdits(arena, &files, d.uri, word.text, new_name);
            try self.respondRaw(id, try workspaceEditMulti(arena, files.items));
        } else if (eql(u8, method, "textDocument/documentSymbol")) {
            const d = self.doc(params) orelse return self.respondRaw(id, "[]");
            if (self.configure and !self.configured) return self.respondRaw(id, "[]");
            try self.respond(id, try symbols(arena, d.text, self.rich_symbols));
        } else if (eql(u8, method, "textDocument/codeAction")) {
            const d = self.doc(params) orelse return self.respondRaw(id, "[]");
            const range = getObj(params, "range") orelse return self.respondRaw(id, "[]");
            const start = getObj(range, "start") orelse return self.respondRaw(id, "[]");
            const first: u32 = @intCast(@max(getInt(start, "line") orelse 0, 0));
            // The range is what the client asked about — a selection
            // spans lines — so the first TODO anywhere in it answers.
            const last: u32 = if (getObj(range, "end")) |e| @intCast(@max(getInt(e, "line") orelse first, first)) else first;
            const todo = todoIn(d.text, first, last) orelse return self.respondRaw(id, "[]");
            // Only for the diagnostic the client hands back as it was
            // published — its `code` and its `data.id` — the way a real
            // server scopes a quick fix. A projection gets nothing.
            if (!echoesTodo(params, todo.start.line)) return self.respondRaw(id, "[]");
            const edit = try workspaceEdit(arena, d.uri, &.{.{ .range = todo, .newText = "DONE" }});
            const action = try std.fmt.allocPrint(arena, "[{{\"title\":\"Resolve TODO\",\"kind\":\"quickfix\",\"edit\":{s}}}]", .{edit});
            try self.respondRaw(id, action);
        } else if (eql(u8, method, "textDocument/formatting")) {
            if (getObj(params, "options")) |o| try self.logLine("formatting tabSize={d} insertSpaces={}", .{ getInt(o, "tabSize") orelse -1, getBool(o, "insertSpaces") orelse false });
            const d = self.doc(params) orelse return self.respondRaw(id, "null");
            const tidy = try formatted(arena, d.text);
            if (std.mem.eql(u8, tidy, d.text)) return self.respondRaw(id, "[]");
            try self.respond(id, &[_]TextEdit{.{ .range = wholeRange(d.text), .newText = tidy }});
        } else {
            try self.respondError(id, -32601, "method not found");
        }
    }

    fn notification(self: *Server, arena: Allocator, method: []const u8, params: Value) !void {
        const eql = std.mem.eql;
        if (eql(u8, method, "exit")) {
            self.done = true;
        } else if (eql(u8, method, "initialized")) {
            if (self.configure) try self.request_out("workspace/configuration", .{ .items = &[_]struct { section: []const u8 }{.{ .section = "fakeIde" }} });
        } else if (eql(u8, method, "textDocument/didOpen")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            const text = getStr(td, "text") orelse "";
            try self.logLine("didOpen languageId={s}", .{getStr(td, "languageId") orelse "?"});
            try self.setDoc(uri, text);
            try self.publish(arena, uri);
        } else if (eql(u8, method, "textDocument/didChange")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            const changes = getArr(params, "contentChanges") orelse return;
            if (changes.len == 0) return;
            if (self.incremental) {
                try self.applyChanges(arena, uri, changes);
            } else {
                // Full sync (`change: 1`): the last change is the document.
                const text = getStr(changes[changes.len - 1], "text") orelse return;
                try self.setDoc(uri, text);
            }
            try self.publish(arena, uri);
        } else if (eql(u8, method, "textDocument/didClose")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            if (self.docs.fetchRemove(uri)) |kv| {
                self.gpa.free(kv.key);
                self.gpa.free(kv.value);
            }
            try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = &[_]Diagnostic{} });
        }
        // `initialized`, `didSave`, `$/cancelRequest`…: nothing to do.
    }

    /// Apply an incremental `didChange`, in order, exactly as the
    /// protocol says: each change describes the document the one before
    /// it left. A change with no range is the whole text.
    fn applyChanges(self: *Server, arena: Allocator, uri: []const u8, changes: []const Value) !void {
        for (changes) |ch| {
            const text = getStr(ch, "text") orelse return;
            const range = getObj(ch, "range") orelse {
                try self.logChange("full", text.len);
                try self.setDoc(uri, text);
                continue;
            };
            const cur = self.docs.get(uri) orelse return;
            const start = offsetOf(cur, getObj(range, "start").?);
            const end = offsetOf(cur, getObj(range, "end").?);
            try self.logChange(try std.fmt.allocPrint(arena, "range {d}:{d}-{d}:{d}", .{
                getInt(getObj(range, "start").?, "line") orelse 0,
                getInt(getObj(range, "start").?, "character") orelse 0,
                getInt(getObj(range, "end").?, "line") orelse 0,
                getInt(getObj(range, "end").?, "character") orelse 0,
            }), text.len);
            const next = try std.mem.concat(self.gpa, u8, &.{ cur[0..start], text, cur[end..] });
            defer self.gpa.free(next);
            try self.setDoc(uri, next);
        }
    }

    /// An LSP position's byte offset in `text`, utf-8 (a character IS a
    /// byte, as `initialize` promised) and clamped: a line past the end
    /// lands at the end, a character past the line's at the line's end.
    fn offsetOf(text: []const u8, p: Value) usize {
        const want_line: usize = @intCast(@max(getInt(p, "line") orelse 0, 0));
        const want_col: usize = @intCast(@max(getInt(p, "character") orelse 0, 0));
        var line: usize = 0;
        var start: usize = 0;
        while (line < want_line) : (line += 1) {
            const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len;
            start = nl + 1;
        }
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        return @min(start + want_col, end);
    }

    /// The log's extra line in incremental mode: what the change was and
    /// how many bytes it carried, so a script can tell a range sync from
    /// a full one and see it never grew to the file's size.
    fn logChange(self: *Server, what: []const u8, bytes: usize) !void {
        try self.logLine("didChange {s} len={d}", .{ what, bytes });
    }

    /// One more line in the log, under the method that carried it: the
    /// facts of a request the client's side cannot otherwise show — a
    /// `didOpen`'s `languageId`, a `formatting`'s options.
    fn logLine(self: *Server, comptime fmt: []const u8, args: anytype) !void {
        const path = self.log_path orelse return;
        try self.log.print(self.gpa, fmt ++ "\n", args);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = self.log.items }) catch {};
    }

    fn setDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        if (self.docs.getPtr(uri)) |slot| {
            self.gpa.free(slot.*);
            slot.* = copy;
            return;
        }
        const key = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(key);
        try self.docs.put(self.gpa, key, copy);
    }

    /// Every line holding `TODO` is a warning from the marker to the
    /// line's end.
    fn publish(self: *Server, arena: Allocator, uri: []const u8) !void {
        const text = self.docs.get(uri) orelse return;
        var list: std.ArrayList(Diagnostic) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var line: u32 = 0;
        while (it.next()) |l| : (line += 1) {
            if (todoOn(text, line)) |_| {
                const at: u32 = @intCast(std.mem.indexOf(u8, l, "TODO").?);
                try list.append(arena, .{
                    .range = .{ .start = .{ .line = line, .character = at }, .end = .{ .line = line, .character = @intCast(std.mem.trimEnd(u8, l, "\r").len) } },
                    .severity = 2,
                    .message = "unresolved TODO",
                    .data = .{ .id = try todoId(arena, line) },
                });
            }
        }
        try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = list.items });
    }

    const Doc = struct { uri: []const u8, text: []const u8 };
    const DocPos = struct { uri: []const u8, text: []const u8, pos: Position };

    /// Every other file with `uri`'s extension in `uri`'s directory
    /// that holds `word`, with its rename edits: an open one from the
    /// synced text, a closed one from disk.
    fn siblingEdits(self: *Server, arena: Allocator, files: *std.ArrayList(FileEdits), uri: []const u8, word: []const u8, new_name: []const u8) !void {
        const path = uriPath(arena, uri) orelse return;
        const dir_path = std.fs.path.dirname(path) orelse return;
        const ext = std.fs.path.extension(path);
        const uri_dir = uri[0 .. std.mem.lastIndexOfScalar(u8, uri, '/') orelse return];
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ext)) continue;
            if (std.mem.eql(u8, entry.name, std.fs.path.basename(path))) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        // Sorted, so the reply is the same run to run.
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const sib_uri = try std.fmt.allocPrint(arena, "{s}/{s}", .{ uri_dir, name });
            const text: []const u8 = self.docs.get(sib_uri) orelse blk: {
                const full = try std.fs.path.join(arena, &.{ dir_path, name });
                break :blk Io.Dir.cwd().readFileAlloc(self.io, full, arena, .limited(4 << 20)) catch continue;
            };
            const ranges = try occurrences(arena, text, word);
            if (ranges.len == 0) continue;
            try files.append(arena, .{ .uri = sib_uri, .edits = try renameEdits(arena, ranges, new_name) });
        }
    }

    fn doc(self: *Server, params: Value) ?Doc {
        const td = getObj(params, "textDocument") orelse return null;
        const uri = getStr(td, "uri") orelse return null;
        const text = self.docs.get(uri) orelse return null;
        return .{ .uri = uri, .text = text };
    }

    fn docAt(self: *Server, params: Value) ?DocPos {
        const d = self.doc(params) orelse return null;
        const p = getObj(params, "position") orelse return null;
        const line = getInt(p, "line") orelse return null;
        const character = getInt(p, "character") orelse return null;
        if (line < 0 or character < 0) return null;
        return .{ .uri = d.uri, .text = d.text, .pos = .{ .line = @intCast(line), .character = @intCast(character) } };
    }
};

// ─── the text ───

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The `line`th line of `text`, without its newline; null past the end.
fn lineAt(text: []const u8, line: u32) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: u32 = 0;
    while (it.next()) |l| : (i += 1) if (i == line) return std.mem.trimEnd(u8, l, "\r");
    return null;
}

const Word = struct { text: []const u8, range: Range };

/// The identifier under `pos`, or the one ending there.
fn wordAt(text: []const u8, pos: Position) ?Word {
    const l = lineAt(text, pos.line) orelse return null;
    if (l.len == 0) return null;
    var c: usize = @min(pos.character, l.len);
    if (c == l.len or !isIdent(l[c])) {
        if (c == 0 or !isIdent(l[c - 1])) return null;
        c -= 1;
    }
    var s = c;
    while (s > 0 and isIdent(l[s - 1])) s -= 1;
    var e = c;
    while (e < l.len and isIdent(l[e])) e += 1;
    return .{ .text = l[s..e], .range = .{ .start = .{ .line = pos.line, .character = @intCast(s) }, .end = .{ .line = pos.line, .character = @intCast(e) } } };
}

/// The name on the first line that starts with `fn <name>`.
fn definitionOf(text: []const u8, name: []const u8) ?Range {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| : (line += 1) {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, l, "fn ")) continue;
        const rest = l[3..];
        var e: usize = 0;
        while (e < rest.len and isIdent(rest[e])) e += 1;
        if (std.mem.eql(u8, rest[0..e], name)) {
            return .{ .start = .{ .line = line, .character = 3 }, .end = .{ .line = line, .character = @intCast(3 + e) } };
        }
    }
    return null;
}

/// Every whole-word occurrence of `name`, in document order.
/// The `data.id` a TODO diagnostic on `line` is published with.
fn todoId(arena: Allocator, line: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "todo|{d}", .{line});
}

/// Does the `codeAction` context carry line `line`'s diagnostic as it
/// was published — `code` and `data.id` intact?
fn echoesTodo(params: Value, line: u32) bool {
    const ctx = getObj(params, "context") orelse return false;
    const diags = getArr(ctx, "diagnostics") orelse return false;
    var buf: [32]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "todo|{d}", .{line}) catch return false;
    for (diags) |d| {
        const code = getStr(d, "code") orelse continue;
        if (!std.mem.eql(u8, code, todo_code)) continue;
        const data = getObj(d, "data") orelse continue;
        const id = getStr(data, "id") orelse continue;
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

fn occurrences(arena: Allocator, text: []const u8, name: []const u8) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| : (line += 1) {
        const l = std.mem.trimEnd(u8, raw, "\r");
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, l, from, name)) |at| {
            const end = at + name.len;
            from = end;
            if (at > 0 and isIdent(l[at - 1])) continue;
            if (end < l.len and isIdent(l[end])) continue;
            try out.append(arena, .{ .start = .{ .line = line, .character = @intCast(at) }, .end = .{ .line = line, .character = @intCast(end) } });
        }
    }
    return out.items;
}

/// The file's identifiers, unique, sorted; a `fn` name is a function.
fn identifiers(arena: Allocator, text: []const u8) ![]CompletionItem {
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!isIdent(text[i]) or std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        var e = i;
        while (e < text.len and isIdent(text[e])) e += 1;
        const w = text[i..e];
        i = e;
        var seen = false;
        for (names.items) |n| if (std.mem.eql(u8, n, w)) {
            seen = true;
            break;
        };
        if (!seen) try names.append(arena, w);
    }
    const Sort = struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };
    std.mem.sort([]const u8, names.items, {}, Sort.lt);
    const out = try arena.alloc(CompletionItem, names.items.len);
    for (names.items, 0..) |n, k| {
        const is_fn = definitionOf(text, n) != null;
        out[k] = .{ .label = n, .kind = if (is_fn) 3 else 6, .detail = if (is_fn) "fn" else "identifier" };
    }
    return out;
}

/// One symbol per `fn <name>` line (kind 12, Function).
fn symbols(arena: Allocator, text: []const u8, rich: bool) ![]DocSymbol {
    var out: std.ArrayList(DocSymbol) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| : (line += 1) {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "fn ")) {
            var e: usize = 3;
            while (e < l.len and isIdent(l[e])) e += 1;
            if (e == 3) continue;
            // Rich: the function runs to the first later line that starts
            // with `}` (a one-liner holding its own `}` ends where it is).
            const end_line: u32 = if (rich and std.mem.indexOfScalar(u8, l, '}') == null) closingBrace(text, line) orelse line else line;
            const end_len: usize = if (end_line == line) l.len else (lineAt(text, end_line) orelse @as([]const u8, "")).len;
            const whole: Range = .{ .start = .{ .line = line, .character = 0 }, .end = .{ .line = end_line, .character = @intCast(end_len) } };
            const sel: Range = .{ .start = .{ .line = line, .character = 3 }, .end = .{ .line = line, .character = @intCast(e) } };
            try out.append(arena, .{ .name = l[3..e], .kind = 12, .range = whole, .selectionRange = sel });
        } else if (rich) {
            // `let <name>` → a Variable (13) on its line.
            const lead = std.mem.trimStart(u8, l, " \t");
            if (!std.mem.startsWith(u8, lead, "let ")) continue;
            const at: usize = l.len - lead.len + 4;
            var e: usize = at;
            while (e < l.len and isIdent(l[e])) e += 1;
            if (e == at) continue;
            const whole: Range = .{ .start = .{ .line = line, .character = 0 }, .end = .{ .line = line, .character = @intCast(l.len) } };
            const sel: Range = .{ .start = .{ .line = line, .character = @intCast(at) }, .end = .{ .line = line, .character = @intCast(e) } };
            try out.append(arena, .{ .name = l[at..e], .kind = 13, .range = whole, .selectionRange = sel });
        }
    }
    return out.items;
}

/// The first line after `from` that starts with `}`.
fn closingBrace(text: []const u8, from: u32) ?u32 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| : (line += 1) {
        if (line <= from) continue;
        if (std.mem.startsWith(u8, std.mem.trimEnd(u8, raw, "\r"), "}")) return line;
    }
    return null;
}

/// The first `TODO` on lines `first..=last`.
fn todoIn(text: []const u8, first: u32, last: u32) ?Range {
    var line = first;
    while (line <= last) : (line += 1) {
        if (todoOn(text, line)) |r| return r;
        if (line == std.math.maxInt(u32)) break;
    }
    return null;
}

/// The `TODO` marker on `line`, if the line holds one.
fn todoOn(text: []const u8, line: u32) ?Range {
    const l = lineAt(text, line) orelse return null;
    const at = std.mem.indexOf(u8, l, "TODO") orelse return null;
    return .{ .start = .{ .line = line, .character = @intCast(at) }, .end = .{ .line = line, .character = @intCast(at + 4) } };
}

/// Trailing blanks trimmed on every line; exactly one newline at the end.
fn formatted(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, std.mem.trimEnd(u8, raw, " \t\r"));
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    try out.append(arena, '\n');
    return out.items;
}

fn wholeRange(text: []const u8) Range {
    var lines: u32 = 0;
    var last: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        lines += 1;
        last = l.len;
    }
    return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = lines - 1, .character = @intCast(last) } };
}

/// `{"changes":{"<uri>":[edits]}}`.
const FileEdits = struct { uri: []const u8, edits: []const TextEdit };

fn renameEdits(arena: Allocator, ranges: []const Range, new_name: []const u8) ![]TextEdit {
    const edits = try arena.alloc(TextEdit, ranges.len);
    for (ranges, 0..) |r, i| edits[i] = .{ .range = r, .newText = new_name };
    return edits;
}

/// A `WorkspaceEdit` over several files (`changes`, one key per uri).
fn workspaceEditMulti(arena: Allocator, files: []const FileEdits) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    try js.beginObject();
    try js.objectField("changes");
    try js.beginObject();
    for (files) |f| {
        try js.objectField(f.uri);
        try js.write(f.edits);
    }
    try js.endObject();
    try js.endObject();
    return aw.written();
}

/// A `file://` uri's path (`%xx` decoded); null for any other scheme.
fn uriPath(arena: Allocator, uri: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var raw = uri["file://".len..];
    if (raw.len > 2 and raw[0] == '/' and raw[2] == ':') raw = raw[1..];
    return decodePercent(arena, raw) catch raw;
}

fn workspaceEdit(arena: Allocator, uri: []const u8, edits: []const TextEdit) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    try js.beginObject();
    try js.objectField("changes");
    try js.beginObject();
    try js.objectField(uri);
    try js.write(edits);
    try js.endObject();
    try js.endObject();
    return aw.written();
}

/// The `rootUri`'s path (`file://` stripped, `%xx` decoded), or `rootPath`.
fn rootPath(arena: Allocator, params: Value) ?[]const u8 {
    if (getStr(params, "rootUri")) |uri| {
        if (std.mem.startsWith(u8, uri, "file://")) {
            var raw = uri["file://".len..];
            // `file:///C:/…` on Windows: drop the slash before the drive.
            if (raw.len > 2 and raw[0] == '/' and raw[2] == ':') raw = raw[1..];
            return decodePercent(arena, raw) catch raw;
        }
    }
    return getStr(params, "rootPath");
}

fn decodePercent(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, s[i]);
    }
    return out.items;
}

// ─── JSON access ───

fn getField(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(v: Value, key: []const u8) ?i64 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

fn getBool(v: Value, key: []const u8) ?bool {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

fn getArr(v: Value, key: []const u8) ?[]const Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

fn getObj(v: Value, key: []const u8) ?Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .object => f,
        else => null,
    };
}

// ─── framing ───

pub const FrameError = error{ Closed, BadFrame } || Allocator.Error;

/// `Content-Length: N\r\n\r\n` then N bytes; other headers are skipped.
pub fn readFrame(gpa: Allocator, r: *Io.Reader) FrameError![]u8 {
    var len: ?usize = null;
    while (true) {
        const raw = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.Closed,
            error.StreamTooLong => return error.BadFrame,
        }) orelse return error.Closed;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (len != null) break;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "Content-Length")) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.BadFrame;
        }
    }
    const n = len.?;
    if (n > 64 * 1024 * 1024) return error.BadFrame;
    const body = try gpa.alloc(u8, n);
    errdefer gpa.free(body);
    r.readSliceAll(body) catch return error.Closed;
    return body;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    var log_path: ?[]const u8 = null;
    var incremental = false;
    var configure = false;
    var rich_symbols = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [128]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.print("mnml-fake-lsp {s}\n", .{version});
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [512]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.writeAll("mnml-fake-lsp [--log PATH] [--sync full|incremental] [--configure] [--symbols plain|rich]: a deterministic language server over stdio (see tools/fake_lsp/README.md)\n");
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--log") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
        }
        if (std.mem.eql(u8, a, "--sync") and i + 1 < args.len) {
            i += 1;
            incremental = std.mem.eql(u8, args[i], "incremental");
        }
        if (std.mem.eql(u8, a, "--configure")) configure = true;
        if (std.mem.eql(u8, a, "--symbols") and i + 1 < args.len) {
            i += 1;
            rich_symbols = std.mem.eql(u8, args[i], "rich");
        }
    }
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &in_buf);
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    var server = Server.init(gpa, io, &writer.interface);
    defer server.deinit();
    server.log_path = log_path;
    server.incremental = incremental;
    server.configure = configure;
    server.rich_symbols = rich_symbols;
    while (!server.done) {
        const body = readFrame(gpa, &reader.interface) catch |err| switch (err) {
            error.Closed, error.BadFrame => break,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(body);
        server.handle(body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break, // the pipe is gone
        };
    }
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// A server on a growable buffer, plus the frames it produced so far.
const Harness = struct {
    aw: Io.Writer.Allocating,
    server: Server,
    parsed: std.ArrayList(std.json.Parsed(Value)) = .empty,
    consumed: usize = 0,

    fn init(h: *Harness) void {
        h.* = .{ .aw = .init(t.allocator), .server = undefined };
        h.server = Server.init(t.allocator, t.io, &h.aw.writer);
    }

    fn deinit(h: *Harness) void {
        for (h.parsed.items) |*p| p.deinit();
        h.parsed.deinit(t.allocator);
        h.server.deinit();
        h.aw.deinit();
    }

    /// Sends a request (`id` > 0) or a notification (`id` == 0) and
    /// returns the frames that came back, parsed.
    fn send(h: *Harness, id: i64, method: []const u8, params_json: []const u8) ![]const Value {
        const body = if (id > 0)
            try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json })
        else
            try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
        defer t.allocator.free(body);
        const before = h.parsed.items.len;
        try h.server.handle(body);
        try h.drain();
        const out = try t.allocator.alloc(Value, h.parsed.items.len - before);
        for (h.parsed.items[before..], 0..) |p, i| out[i] = p.value;
        return out;
    }

    fn drain(h: *Harness) !void {
        const all = h.aw.written();
        var r = Io.Reader.fixed(all[h.consumed..]);
        while (true) {
            const body = readFrame(t.allocator, &r) catch |err| switch (err) {
                error.Closed => break,
                else => return err,
            };
            defer t.allocator.free(body);
            try h.parsed.append(t.allocator, try std.json.parseFromSlice(Value, t.allocator, body, .{}));
        }
        h.consumed = all.len;
    }
};

fn resultOf(v: Value) Value {
    return getField(v, "result") orelse Value.null;
}

const sample = "fn foo() {\n  let x = 1;  \n  foo(x); // TODO later\n}\nfn bar() { foo(); }\n";

test "initialize answers the capabilities and complains once without a Cargo.toml; a crate root is quiet" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const frames = try h.send(1, "initialize", "{\"rootUri\":\"file:///definitely/not/a/dir\",\"capabilities\":{}}");
    defer t.allocator.free(frames);
    try t.expectEqual(@as(usize, 2), frames.len);
    try t.expectEqualStrings("utf-8", getStr(getObj(resultOf(frames[0]), "capabilities").?, "positionEncoding").?);
    try t.expect(getField(getObj(resultOf(frames[0]), "capabilities").?, "hoverProvider").?.bool);
    try t.expectEqualStrings("window/showMessage", getStr(frames[1], "method").?);
    try t.expectEqual(@as(i64, 1), getInt(getObj(frames[1], "params").?, "type").?);
    try t.expect(std.mem.startsWith(u8, getStr(getObj(frames[1], "params").?, "message").?, "Failed to discover workspace.\n"));

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Cargo.toml", .data = "[package]\n" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var g: Harness = undefined;
    g.init();
    defer g.deinit();
    const params = try std.fmt.allocPrint(t.allocator, "{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}", .{root});
    defer t.allocator.free(params);
    const quiet = try g.send(1, "initialize", params);
    defer t.allocator.free(quiet);
    try t.expectEqual(@as(usize, 1), quiet.len);
}

test "didOpen publishes a warning per TODO line; didChange republishes; didClose clears" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const open = try h.send(0, "textDocument/didOpen", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"languageId\":\"fk\",\"version\":1,\"text\":\"fn foo() {\\n  let x = 1;  \\n  foo(x); // TODO later\\n}\\nfn bar() { foo(); }\\n\"}}");
    defer t.allocator.free(open);
    try t.expectEqual(@as(usize, 1), open.len);
    try t.expectEqualStrings("textDocument/publishDiagnostics", getStr(open[0], "method").?);
    const diags = getArr(getObj(open[0], "params").?, "diagnostics").?;
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqualStrings("unresolved TODO", getStr(diags[0], "message").?);
    try t.expectEqual(@as(i64, 2), getInt(diags[0], "severity").?);
    try t.expectEqualStrings("fk/todo", getStr(diags[0], "code").?);
    try t.expectEqualStrings("todo|2", getStr(getObj(diags[0], "data").?, "id").?);
    const start = getObj(getObj(diags[0], "range").?, "start").?;
    try t.expectEqual(@as(i64, 2), getInt(start, "line").?);
    try t.expectEqual(@as(i64, 13), getInt(start, "character").?);

    const change = try h.send(0, "textDocument/didChange", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"version\":2},\"contentChanges\":[{\"text\":\"fn foo() {}\\n\"}]}");
    defer t.allocator.free(change);
    try t.expectEqual(@as(usize, 0), getArr(getObj(change[0], "params").?, "diagnostics").?.len);

    const close = try h.send(0, "textDocument/didClose", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"}}");
    defer t.allocator.free(close);
    try t.expectEqual(@as(usize, 1), close.len);
    try t.expectEqual(@as(usize, 0), h.server.docs.count());

    // The log names every method in order, once `--log` gives it a path
    // (unset here, so nothing was written to the cwd).
    try t.expectEqualStrings("", h.server.log.items);
}

test "hover, definition, references, completion, rename, symbols, code action and formatting are all functions of the text" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const open = try h.send(0, "textDocument/didOpen", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"languageId\":\"fk\",\"version\":1,\"text\":\"fn foo() {\\n  let x = 1;  \\n  foo(x); // TODO later\\n}\\nfn bar() { foo(); }\\n\"}}");
    defer t.allocator.free(open);
    const at = "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"position\":{\"line\":2,\"character\":3}}";

    const hover = try h.send(2, "textDocument/hover", at);
    defer t.allocator.free(hover);
    try t.expectEqualStrings("**foo**", getStr(getObj(resultOf(hover[0]), "contents").?, "value").?);

    const def = try h.send(3, "textDocument/definition", at);
    defer t.allocator.free(def);
    try t.expectEqualStrings("file:///ws/a.fk", getStr(resultOf(def[0]), "uri").?);
    try t.expectEqual(@as(i64, 0), getInt(getObj(getObj(resultOf(def[0]), "range").?, "start").?, "line").?);
    try t.expectEqual(@as(i64, 3), getInt(getObj(getObj(resultOf(def[0]), "range").?, "start").?, "character").?);

    const none = try h.send(4, "textDocument/definition", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"position\":{\"line\":1,\"character\":6}}");
    defer t.allocator.free(none);
    try t.expect(resultOf(none[0]) == .null);

    const refs = try h.send(5, "textDocument/references", at);
    defer t.allocator.free(refs);
    try t.expectEqual(@as(usize, 3), resultOf(refs[0]).array.items.len);

    const comp = try h.send(6, "textDocument/completion", at);
    defer t.allocator.free(comp);
    const items = getArr(resultOf(comp[0]), "items").?;
    try t.expectEqual(@as(usize, 7), items.len); // TODO bar fn foo later let x
    try t.expectEqualStrings("TODO", getStr(items[0], "label").?);
    try t.expectEqualStrings("bar", getStr(items[1], "label").?);
    try t.expectEqual(@as(i64, 3), getInt(items[1], "kind").?);
    try t.expectEqualStrings("x", getStr(items[6], "label").?);
    try t.expectEqual(@as(i64, 6), getInt(items[6], "kind").?);

    const ren = try h.send(7, "textDocument/rename", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"position\":{\"line\":2,\"character\":3},\"newName\":\"quux\"}");
    defer t.allocator.free(ren);
    const edits = getArr(getObj(resultOf(ren[0]), "changes").?, "file:///ws/a.fk").?;
    try t.expectEqual(@as(usize, 3), edits.len);
    try t.expectEqualStrings("quux", getStr(edits[0], "newText").?);

    const syms = try h.send(8, "textDocument/documentSymbol", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"}}");
    defer t.allocator.free(syms);
    const list = resultOf(syms[0]).array.items;
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("foo", getStr(list[0], "name").?);
    try t.expectEqualStrings("bar", getStr(list[1], "name").?);
    try t.expectEqual(@as(i64, 4), getInt(getObj(getObj(list[1], "range").?, "start").?, "line").?);

    // The fix comes only with the published diagnostic echoed whole:
    // an empty context and a `{range, severity, message}` projection
    // (what a client that drops `code` / `data` sends) both get [].
    const bare = try h.send(9, "textDocument/codeAction", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":0}},\"context\":{\"diagnostics\":[]}}");
    defer t.allocator.free(bare);
    try t.expectEqual(@as(usize, 0), resultOf(bare[0]).array.items.len);
    const stripped = try h.send(9, "textDocument/codeAction", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":0}},\"context\":{\"diagnostics\":[{\"range\":{\"start\":{\"line\":2,\"character\":13},\"end\":{\"line\":2,\"character\":23}},\"severity\":2,\"message\":\"unresolved TODO\"}]}}");
    defer t.allocator.free(stripped);
    try t.expectEqual(@as(usize, 0), resultOf(stripped[0]).array.items.len);
    const act = try h.send(9, "textDocument/codeAction", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":0}},\"context\":{\"diagnostics\":[{\"range\":{\"start\":{\"line\":2,\"character\":13},\"end\":{\"line\":2,\"character\":23}},\"severity\":2,\"source\":\"fake-lsp\",\"code\":\"fk/todo\",\"message\":\"unresolved TODO\",\"data\":{\"id\":\"todo|2\"}}]}}");
    defer t.allocator.free(act);
    const actions = resultOf(act[0]).array.items;
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("Resolve TODO", getStr(actions[0], "title").?);
    const fix = getArr(getObj(getObj(actions[0], "edit").?, "changes").?, "file:///ws/a.fk").?;
    try t.expectEqualStrings("DONE", getStr(fix[0], "newText").?);
    const no_act = try h.send(10, "textDocument/codeAction", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"context\":{\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"severity\":2,\"code\":\"fk/todo\",\"message\":\"unresolved TODO\",\"data\":{\"id\":\"todo|0\"}}]}}");
    defer t.allocator.free(no_act);
    // A range that spans down onto the TODO's line (a selection) finds it.
    const span_act = try h.send(14, "textDocument/codeAction", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":0}},\"context\":{\"diagnostics\":[]}}");
    defer t.allocator.free(span_act);
    try t.expectEqual(@as(usize, 1), resultOf(span_act[0]).array.items.len);
    try t.expectEqual(@as(usize, 0), resultOf(no_act[0]).array.items.len);

    const fmt = try h.send(11, "textDocument/formatting", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\"},\"options\":{\"tabSize\":2,\"insertSpaces\":true}}");
    defer t.allocator.free(fmt);
    const fedits = resultOf(fmt[0]).array.items;
    try t.expectEqual(@as(usize, 1), fedits.len);
    try t.expectEqualStrings("fn foo() {\n  let x = 1;\n  foo(x); // TODO later\n}\nfn bar() { foo(); }\n", getStr(fedits[0], "newText").?);
    try t.expectEqual(@as(i64, 5), getInt(getObj(getObj(fedits[0], "range").?, "end").?, "line").?);

    const unknown = try h.send(12, "textDocument/nope", "{}");
    defer t.allocator.free(unknown);
    try t.expectEqual(@as(i64, -32601), getInt(getObj(unknown[0], "error").?, "code").?);

    const down = try h.send(13, "shutdown", "null");
    defer t.allocator.free(down);
    try t.expect(resultOf(down[0]) == .null);
    try t.expect(h.server.shutdown);
    const gone = try h.send(0, "exit", "null");
    defer t.allocator.free(gone);
    try t.expect(h.server.done);
}

test "the text helpers: the word under or before the caret, whole-word occurrences, the trimmed form" {
    try t.expectEqualStrings("foo", wordAt(sample, .{ .line = 2, .character = 5 }).?.text);
    try t.expectEqualStrings("foo", wordAt(sample, .{ .line = 2, .character = 2 }).?.text);
    try t.expect(wordAt(sample, .{ .line = 2, .character = 1 }) == null);
    try t.expect(wordAt(sample, .{ .line = 99, .character = 0 }) == null);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const occ = try occurrences(arena, "foo food foo_ foo", "foo");
    try t.expectEqual(@as(usize, 2), occ.len);
    try t.expectEqual(@as(u32, 14), occ[1].start.character);
    const tidy = try formatted(arena, "a  \n\nb\t\n\n\n");
    try t.expectEqualStrings("a\n\nb\n", tidy);
    try t.expectEqual(@as(u32, 5), wholeRange(sample).end.line);
}

test "--sync incremental: range changes apply in order, and the text they leave is what the client has" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.server.incremental = true;
    const open = try h.send(0, "textDocument/didOpen", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"languageId\":\"fk\",\"version\":1,\"text\":\"fn foo() {\\n  let x = 1;\\n}\\n\"}}");
    defer t.allocator.free(open);
    // Two changes in one notification, the second described against the
    // document the first left — the protocol's own rule, and the shape
    // a folded burst arrives in.
    const two = try h.send(0, "textDocument/didChange", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"version\":2},\"contentChanges\":[" ++
        "{\"range\":{\"start\":{\"line\":1,\"character\":6},\"end\":{\"line\":1,\"character\":7}},\"text\":\"yy\"}," ++
        "{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":1}},\"text\":\"} // TODO\"}]}");
    defer t.allocator.free(two);
    try t.expectEqualStrings("fn foo() {\n  let yy = 1;\n} // TODO\n", h.server.docs.get("file:///ws/a.fk").?);
    // The diagnostics are the proof the client can see: the TODO the
    // second range put there is on the line it was aimed at.
    try t.expectEqual(@as(usize, 1), two.len);
    const diags = getArr(getObj(two[0], "params").?, "diagnostics").?;
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqual(@as(i64, 2), getInt(getObj(getObj(diags[0], "range").?, "start").?, "line").?);
    // A change with no range is still the whole text.
    const full = try h.send(0, "textDocument/didChange", "{\"textDocument\":{\"uri\":\"file:///ws/a.fk\",\"version\":3},\"contentChanges\":[{\"text\":\"fn bar() {}\\n\"}]}");
    defer t.allocator.free(full);
    try t.expectEqualStrings("fn bar() {}\n", h.server.docs.get("file:///ws/a.fk").?);
}

test "rename reaches a sibling file of the same extension: an open one from its synced text, a closed one from disk, in name order" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "closed.fk", .data = "foo();\nlet foo = 1; // foo\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "unrelated.fk", .data = "bar();\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.txt", .data = "foo\n" });
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const a_uri = try std.fmt.allocPrint(t.allocator, "file://{s}/a.fk", .{root});
    defer t.allocator.free(a_uri);
    const open_params = try std.fmt.allocPrint(t.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"fk\",\"version\":1,\"text\":\"fn foo() {{}}\\nfoo();\\n\"}}}}", .{a_uri});
    defer t.allocator.free(open_params);
    const open = try h.send(0, "textDocument/didOpen", open_params);
    defer t.allocator.free(open);
    // A second open document in the directory whose synced text differs
    // from the disk's (the disk holds `foo`, the buffer does not).
    const b_uri = try std.fmt.allocPrint(t.allocator, "file://{s}/b.fk", .{root});
    defer t.allocator.free(b_uri);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.fk", .data = "foo();\n" });
    const open_b_params = try std.fmt.allocPrint(t.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"fk\",\"version\":1,\"text\":\"baz();\\n\"}}}}", .{b_uri});
    defer t.allocator.free(open_b_params);
    const open_b = try h.send(0, "textDocument/didOpen", open_b_params);
    defer t.allocator.free(open_b);
    const ren_params = try std.fmt.allocPrint(t.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":1,\"character\":1}},\"newName\":\"quux\"}}", .{a_uri});
    defer t.allocator.free(ren_params);
    const ren = try h.send(7, "textDocument/rename", ren_params);
    defer t.allocator.free(ren);
    const changes = getObj(resultOf(ren[0]), "changes").?;
    try t.expectEqual(@as(usize, 2), changes.object.count());
    try t.expectEqual(@as(usize, 2), getArr(changes, a_uri).?.len);
    const closed_uri = try std.fmt.allocPrint(t.allocator, "file://{s}/closed.fk", .{root});
    defer t.allocator.free(closed_uri);
    const closed = getArr(changes, closed_uri).?;
    try t.expectEqual(@as(usize, 3), closed.len);
    try t.expectEqualStrings("quux", getStr(closed[0], "newText").?);
    try t.expectEqual(@as(i64, 1), getInt(getObj(getObj(closed[1], "range").?, "start").?, "line").?);
    // b.fk is open and its synced text has no `foo`; unrelated.fk and
    // other.txt hold none / are not the extension.
    try t.expect(getArr(changes, b_uri) == null);
}
