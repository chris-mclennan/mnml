//! The Language Server Protocol's nouns as mnml-zig keeps them, and the
//! two conversions every request needs: a byte offset in a buffer ↔ an
//! LSP `Position` (line + character, where "character" counts UTF-16
//! code units unless the server negotiated UTF-8), and a file path ↔ a
//! `file://` URI.
//!
//! Wire values arrive as `std.json.Value` trees; the readers here pull
//! the fields mnml uses into flat structs that borrow the tree (or a
//! snapshot arena, once adopted). `[]const u8` everywhere: borrowed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../rpc/jsonrpc.zig");
const Value = jsonrpc.Value;

pub const Encoding = enum { utf8, utf16 };

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    info = 3,
    hint = 4,

    pub fn fromInt(i: i64) Severity {
        return switch (i) {
            1 => .err,
            2 => .warning,
            3 => .info,
            else => .hint,
        };
    }

    pub fn label(s: Severity) []const u8 {
        return switch (s) {
            .err => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
        };
    }
};

pub const Diagnostic = struct {
    range: Range,
    severity: Severity,
    message: []const u8,
    source: ?[]const u8,
    code: ?[]const u8,
    /// The diagnostic exactly as the server published it (its JSON
    /// object, re-serialised), so a `codeAction` request can hand it
    /// back whole — `code`, `source`, `data`, `tags`,
    /// `relatedInformation` and all. Servers key their fixes on those
    /// (bash-language-server on `data.id`, tsserver on `code`), and the
    /// spec has the client echo the published object untouched. Null
    /// for a diagnostic mnml made itself (a linter's, a script's).
    raw: ?[]const u8 = null,
};

pub const Location = struct {
    /// Absolute path (the URI decoded).
    path: []const u8,
    range: Range,
};

pub const TextEdit = struct { range: Range, new_text: []const u8 };

pub const InsertFormat = enum(u8) { plain = 1, snippet = 2 };

pub const CompletionItem = struct {
    label: []const u8,
    /// LSP `CompletionItemKind`; 0 when absent.
    kind: u8,
    detail: ?[]const u8,
    documentation: ?[]const u8,
    /// LSP 3.17 `labelDetails.detail` — shown right after the label
    /// (a signature, `(x, y)`) — and `labelDetails.description` — the
    /// item's origin (`re`, `typing`), shown in place of `detail`.
    label_detail: ?[]const u8 = null,
    label_description: ?[]const u8 = null,
    /// What accepting inserts: `textEdit.newText` > `insertText` > `label`.
    insert_text: []const u8,
    format: InsertFormat,
    /// The range `textEdit` replaces, when the server gave one.
    edit_range: ?Range,
    sort_text: ?[]const u8,
    filter_text: ?[]const u8,
    /// The raw item, for `completionItem/resolve`. Borrowed.
    raw: Value,
};

pub const Symbol = struct {
    name: []const u8,
    /// LSP `SymbolKind`.
    kind: u8,
    /// Where the name sits (`selectionRange.start`, or `range.start`).
    line: u32,
    character: u32,
    /// The last line of the symbol's full `range` — the closing brace
    /// of a function, not its name — so a caret can be placed inside
    /// it. `line` when the server gave one line.
    end_line: u32 = 0,
    depth: u8,
    /// Set for `SymbolInformation` (workspace symbols).
    path: ?[]const u8 = null,

    /// A kind that holds other code: module, namespace, package,
    /// class, method, constructor, enum, interface, function, struct.
    /// A variable, a constant, a field — what `local` declares inside
    /// a function — is not one, and never names the breadcrumb.
    pub fn isContainer(self: Symbol) bool {
        return switch (self.kind) {
            2, 3, 4, 5, 6, 9, 10, 11, 12, 23 => true,
            else => false,
        };
    }

    /// Does the symbol's range hold `row`?
    pub fn holds(self: Symbol, row: u32) bool {
        return self.line <= row and row <= @max(self.end_line, self.line);
    }
};

pub const CodeAction = struct {
    title: []const u8,
    kind: ?[]const u8,
    /// The raw action / command, applied on accept. Borrowed.
    raw: Value,
};

pub const HintKind = enum(u8) { other = 0, type = 1, parameter = 2 };

/// An inlay hint: virtual text the view paints at `position`.
pub const InlayHint = struct {
    position: Position,
    /// The label parts joined. Borrowed.
    label: []const u8,
    kind: HintKind,
    pad_left: bool,
    pad_right: bool,
};

/// A code lens: a title above `range.start.line` that runs `command`
/// (a raw `Command`, or null until `codeLens/resolve` fills it).
pub const CodeLens = struct {
    range: Range,
    title: ?[]const u8,
    /// The raw lens, for `resolve` and for `command`. Borrowed.
    raw: Value,
    /// A `codeLens/resolve` for its title went out (the view asked).
    resolving: bool = false,
};

/// A colour literal: `range` and its sRGB value.
pub const ColorInfo = struct { range: Range, r: u8, g: u8, b: u8 };

/// A link inside the document: `range` opens `target` (null when the
/// server wants a `documentLink/resolve` mnml does not ask for).
pub const DocumentLink = struct { range: Range, target: ?[]const u8 };

// ─── positions ──────────────────────────────────────────────────────────

/// Byte offset → position. `text` is the whole document.
pub fn positionOf(text: []const u8, byte_in: usize, enc: Encoding) Position {
    const byte = @min(byte_in, text.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (text[0..byte], 0..) |c, i| if (c == '\n') {
        line += 1;
        line_start = i + 1;
    };
    return .{ .line = line, .character = units(text[line_start..byte], enc) };
}

/// Position → byte offset, clamped to the document. A character past
/// the line's end lands on the line's end.
pub fn byteOf(text: []const u8, pos: Position, enc: Encoding) usize {
    var line: u32 = 0;
    var start: usize = 0;
    while (line < pos.line) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len;
        start = nl + 1;
        line += 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return start + byteInLine(text[start..end], pos.character, enc);
}

/// `character` units into one line → the byte offset within it
/// (clamped to the line's length).
pub fn byteInLine(line: []const u8, character: u32, enc: Encoding) usize {
    var i: usize = 0;
    var u: u32 = 0;
    while (i < line.len and u < character) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        u += switch (enc) {
            .utf8 => @as(u32, @intCast(n)),
            .utf16 => if (n == 4) 2 else 1,
        };
        i += n;
    }
    return @min(i, line.len);
}

/// The `character` count of `s` (one line, or a prefix of one).
pub fn units(s: []const u8, enc: Encoding) u32 {
    if (enc == .utf8) return @intCast(s.len);
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

// ─── uris ───────────────────────────────────────────────────────────────

/// `file:///abs/path`, percent-encoding what RFC 3986 says to.
pub fn uriFromPath(arena: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "file://");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(arena);
}

/// The path of a `file://` URI, percent-decoded. Null for other schemes.
pub fn pathFromUri(arena: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // `file://localhost/x` and `file:///C:/x` shapes.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                try out.append(arena, rest[i]);
                continue;
            };
            try out.append(arena, v);
            i += 2;
        } else try out.append(arena, rest[i]);
    }
    return try out.toOwnedSlice(arena);
}

// ─── readers ────────────────────────────────────────────────────────────

pub fn readPosition(v: Value) ?Position {
    return .{
        .line = @intCast(@max(jsonrpc.getInt(v, "line") orelse return null, 0)),
        .character = @intCast(@max(jsonrpc.getInt(v, "character") orelse return null, 0)),
    };
}

pub fn readRange(v: Value) ?Range {
    return .{
        .start = readPosition(jsonrpc.getObj(v, "start") orelse return null) orelse return null,
        .end = readPosition(jsonrpc.getObj(v, "end") orelse return null) orelse return null,
    };
}

pub fn readDiagnostic(v: Value) ?Diagnostic {
    return .{
        .range = readRange(jsonrpc.getObj(v, "range") orelse return null) orelse return null,
        .severity = Severity.fromInt(jsonrpc.getInt(v, "severity") orelse 1),
        .message = jsonrpc.getStr(v, "message") orelse "",
        .source = jsonrpc.getStr(v, "source"),
        .code = if (jsonrpc.getField(v, "code")) |c| switch (c) {
            .string => |s| s,
            else => null,
        } else null,
    };
}

/// A `Location` or a `LocationLink` (`targetUri` / `targetRange`).
pub fn readLocation(arena: Allocator, v: Value) Allocator.Error!?Location {
    const uri = jsonrpc.getStr(v, "uri") orelse jsonrpc.getStr(v, "targetUri") orelse return null;
    const range_v = jsonrpc.getObj(v, "range") orelse jsonrpc.getObj(v, "targetSelectionRange") orelse jsonrpc.getObj(v, "targetRange") orelse return null;
    const path = (try pathFromUri(arena, uri)) orelse return null;
    return .{ .path = path, .range = readRange(range_v) orelse return null };
}

/// One location, a list, or null → a list.
pub fn readLocations(arena: Allocator, v: ?Value) Allocator.Error![]Location {
    var out: std.ArrayListUnmanaged(Location) = .empty;
    const val = v orelse return out.items;
    switch (val) {
        .array => |a| for (a.items) |item| {
            if (try readLocation(arena, item)) |l| try out.append(arena, l);
        },
        .object => if (try readLocation(arena, val)) |l| try out.append(arena, l),
        else => {},
    }
    return out.items;
}

pub fn readTextEdit(v: Value) ?TextEdit {
    return .{ .range = readRange(jsonrpc.getObj(v, "range") orelse return null) orelse return null, .new_text = jsonrpc.getStr(v, "newText") orelse "" };
}

pub fn readTextEdits(arena: Allocator, v: ?Value) Allocator.Error![]TextEdit {
    var out: std.ArrayListUnmanaged(TextEdit) = .empty;
    const val = v orelse return out.items;
    switch (val) {
        .array => |a| for (a.items) |item| {
            if (readTextEdit(item)) |e| try out.append(arena, e);
        },
        else => {},
    }
    return out.items;
}

pub fn readCompletionItem(v: Value) ?CompletionItem {
    const label = jsonrpc.getStr(v, "label") orelse return null;
    var insert: []const u8 = jsonrpc.getStr(v, "insertText") orelse label;
    var edit_range: ?Range = null;
    if (jsonrpc.getObj(v, "textEdit")) |te| {
        if (jsonrpc.getStr(te, "newText")) |nt| insert = nt;
        // `InsertReplaceEdit` has `insert` / `replace` instead of `range`.
        edit_range = if (jsonrpc.getObj(te, "range")) |r| readRange(r) else if (jsonrpc.getObj(te, "insert")) |r| readRange(r) else null;
    }
    const doc: ?[]const u8 = if (jsonrpc.getField(v, "documentation")) |d| switch (d) {
        .string => |s| s,
        .object => jsonrpc.getStr(d, "value"),
        else => null,
    } else null;
    return .{
        .label = label,
        .kind = @intCast(std.math.clamp(jsonrpc.getInt(v, "kind") orelse 0, 0, 255)),
        .detail = jsonrpc.getStr(v, "detail"),
        .documentation = doc,
        .label_detail = if (jsonrpc.getObj(v, "labelDetails")) |ld| jsonrpc.getStr(ld, "detail") else null,
        .label_description = if (jsonrpc.getObj(v, "labelDetails")) |ld| jsonrpc.getStr(ld, "description") else null,
        .insert_text = insert,
        .format = if ((jsonrpc.getInt(v, "insertTextFormat") orelse 1) == 2) .snippet else .plain,
        .edit_range = edit_range,
        .sort_text = jsonrpc.getStr(v, "sortText"),
        .filter_text = jsonrpc.getStr(v, "filterText"),
        .raw = v,
    };
}

/// A `CompletionList` (`items`) or a bare array.
pub fn readCompletions(arena: Allocator, v: ?Value) Allocator.Error![]CompletionItem {
    var out: std.ArrayListUnmanaged(CompletionItem) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        .object => jsonrpc.getArr(val, "items") orelse &.{},
        else => &.{},
    };
    for (items) |it| if (readCompletionItem(it)) |c| try out.append(arena, c);
    return out.items;
}

/// Hover contents in any of the four shapes → lines of plain text.
/// Fenced code is kept, the fences dropped.
pub fn readHover(arena: Allocator, v: ?Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const val = v orelse return out.items;
    const contents = jsonrpc.getField(val, "contents") orelse return out.items;
    try hoverPart(arena, &out, contents);
    return out.items;
}

fn hoverPart(arena: Allocator, out: *std.ArrayListUnmanaged([]const u8), v: Value) Allocator.Error!void {
    switch (v) {
        .string => |s| try pushLines(arena, out, s),
        .array => |a| for (a.items) |item| try hoverPart(arena, out, item),
        .object => if (jsonrpc.getStr(v, "value")) |s| try pushLines(arena, out, s),
        else => {},
    }
}

fn pushLines(arena: Allocator, out: *std.ArrayListUnmanaged([]const u8), s: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "```")) continue;
        try out.append(arena, line);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1].len == 0) out.items.len -= 1;
}

/// `DocumentSymbol[]` (nested) or `SymbolInformation[]` (flat) → a flat
/// list in document order with depths.
pub fn readSymbols(arena: Allocator, v: ?Value) Allocator.Error![]Symbol {
    var out: std.ArrayListUnmanaged(Symbol) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| try symbolInto(arena, &out, it, 0);
    return out.items;
}

fn symbolInto(arena: Allocator, out: *std.ArrayListUnmanaged(Symbol), v: Value, depth: u8) Allocator.Error!void {
    const name = jsonrpc.getStr(v, "name") orelse return;
    const kind: u8 = @intCast(std.math.clamp(jsonrpc.getInt(v, "kind") orelse 0, 0, 255));
    if (jsonrpc.getObj(v, "location")) |loc| {
        // SymbolInformation.
        const range = readRange(jsonrpc.getObj(loc, "range") orelse return) orelse return;
        const path: ?[]u8 = if (jsonrpc.getStr(loc, "uri")) |u| try pathFromUri(arena, u) else null;
        try out.append(arena, .{ .name = name, .kind = kind, .line = range.start.line, .character = range.start.character, .end_line = range.end.line, .depth = depth, .path = path });
        return;
    }
    const full = readRange(jsonrpc.getObj(v, "range") orelse return) orelse return;
    const sel = readRange(jsonrpc.getObj(v, "selectionRange") orelse jsonrpc.getObj(v, "range") orelse return) orelse return;
    try out.append(arena, .{ .name = name, .kind = kind, .line = sel.start.line, .character = sel.start.character, .end_line = @max(full.end.line, sel.start.line), .depth = depth });
    if (jsonrpc.getArr(v, "children")) |kids| for (kids) |k| try symbolInto(arena, out, k, depth +| 1);
}

pub fn readCodeActions(arena: Allocator, v: ?Value) Allocator.Error![]CodeAction {
    var out: std.ArrayListUnmanaged(CodeAction) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const title = jsonrpc.getStr(it, "title") orelse continue;
        try out.append(arena, .{ .title = title, .kind = jsonrpc.getStr(it, "kind"), .raw = it });
    }
    return out.items;
}

/// `InlayHint[]` (or null). A label given as parts is joined on the arena.
pub fn readInlayHints(arena: Allocator, v: ?Value) Allocator.Error![]InlayHint {
    var out: std.ArrayListUnmanaged(InlayHint) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const pos = readPosition(jsonrpc.getObj(it, "position") orelse continue) orelse continue;
        const label_v = jsonrpc.getField(it, "label") orelse continue;
        const label: []const u8 = switch (label_v) {
            .string => |s| s,
            .array => |parts| blk: {
                var joined: std.ArrayListUnmanaged(u8) = .empty;
                for (parts.items) |p| try joined.appendSlice(arena, jsonrpc.getStr(p, "value") orelse "");
                break :blk joined.items;
            },
            else => continue,
        };
        if (label.len == 0) continue;
        try out.append(arena, .{
            .position = pos,
            .label = label,
            .kind = switch (jsonrpc.getInt(it, "kind") orelse 0) {
                1 => .type,
                2 => .parameter,
                else => .other,
            },
            .pad_left = jsonrpc.getBool(it, "paddingLeft") orelse false,
            .pad_right = jsonrpc.getBool(it, "paddingRight") orelse false,
        });
    }
    std.mem.sort(InlayHint, out.items, {}, struct {
        fn lt(_: void, a: InlayHint, b: InlayHint) bool {
            if (a.position.line != b.position.line) return a.position.line < b.position.line;
            return a.position.character < b.position.character;
        }
    }.lt);
    return out.items;
}

/// `CodeLens[]` (or null), in document order.
pub fn readCodeLenses(arena: Allocator, v: ?Value) Allocator.Error![]CodeLens {
    var out: std.ArrayListUnmanaged(CodeLens) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const range = readRange(jsonrpc.getObj(it, "range") orelse continue) orelse continue;
        const title: ?[]const u8 = if (jsonrpc.getObj(it, "command")) |c| jsonrpc.getStr(c, "title") else null;
        try out.append(arena, .{ .range = range, .title = title, .raw = it });
    }
    std.mem.sort(CodeLens, out.items, {}, struct {
        fn lt(_: void, a: CodeLens, b: CodeLens) bool {
            if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
            return a.range.start.character < b.range.start.character;
        }
    }.lt);
    return out.items;
}

/// `ColorInformation[]` (or null); the spec's 0..1 floats become bytes.
pub fn readColors(arena: Allocator, v: ?Value) Allocator.Error![]ColorInfo {
    var out: std.ArrayListUnmanaged(ColorInfo) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const range = readRange(jsonrpc.getObj(it, "range") orelse continue) orelse continue;
        const c = jsonrpc.getObj(it, "color") orelse continue;
        try out.append(arena, .{ .range = range, .r = channel(c, "red"), .g = channel(c, "green"), .b = channel(c, "blue") });
    }
    std.mem.sort(ColorInfo, out.items, {}, struct {
        fn lt(_: void, a: ColorInfo, b: ColorInfo) bool {
            if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
            return a.range.start.character < b.range.start.character;
        }
    }.lt);
    return out.items;
}

fn channel(c: Value, key: []const u8) u8 {
    const f: f64 = switch (jsonrpc.getField(c, key) orelse return 0) {
        .float => |x| x,
        .integer => |i| @floatFromInt(i),
        else => return 0,
    };
    return @intFromFloat(std.math.clamp(f, 0, 1) * 255 + 0.5);
}

/// `DocumentLink[]` (or null).
pub fn readDocumentLinks(arena: Allocator, v: ?Value) Allocator.Error![]DocumentLink {
    var out: std.ArrayListUnmanaged(DocumentLink) = .empty;
    const val = v orelse return out.items;
    const items: []const Value = switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
    for (items) |it| {
        const range = readRange(jsonrpc.getObj(it, "range") orelse continue) orelse continue;
        try out.append(arena, .{ .range = range, .target = jsonrpc.getStr(it, "target") });
    }
    std.mem.sort(DocumentLink, out.items, {}, struct {
        fn lt(_: void, a: DocumentLink, b: DocumentLink) bool {
            if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
            return a.range.start.character < b.range.start.character;
        }
    }.lt);
    return out.items;
}

/// LSP `SymbolKind` → the outline's short label.
pub fn symbolKindLabel(kind: u8) []const u8 {
    return switch (kind) {
        1 => "file",
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "ctor",
        10 => "enum",
        11 => "interface",
        12 => "fn",
        13 => "var",
        14 => "const",
        15 => "string",
        16 => "number",
        17 => "bool",
        18 => "array",
        19 => "object",
        20 => "key",
        21 => "null",
        22 => "member",
        23 => "struct",
        24 => "event",
        25 => "op",
        26 => "type",
        else => "sym",
    };
}

/// LSP `CompletionItemKind` → a one-word tag for the popup.
pub fn completionKindLabel(kind: u8) []const u8 {
    return switch (kind) {
        1 => "text",
        2 => "method",
        3 => "fn",
        4 => "ctor",
        5 => "field",
        6 => "var",
        7 => "class",
        8 => "iface",
        9 => "module",
        10 => "prop",
        11 => "unit",
        12 => "value",
        13 => "enum",
        14 => "keyword",
        15 => "snippet",
        16 => "color",
        17 => "file",
        18 => "ref",
        19 => "folder",
        20 => "member",
        21 => "const",
        22 => "struct",
        23 => "event",
        24 => "op",
        25 => "type",
        else => "",
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "positions round-trip in both encodings; astral glyphs count two utf-16 units" {
    const text = "ab\ncd😀e\nx";
    // Line 1 is `c d 😀 e`: the emoji is bytes 5..9, `e` is byte 9.
    try testing.expectEqual(Position{ .line = 1, .character = 6 }, positionOf(text, 9, .utf8));
    try testing.expectEqual(Position{ .line = 1, .character = 4 }, positionOf(text, 9, .utf16));
    try testing.expectEqual(Position{ .line = 1, .character = 2 }, positionOf(text, 5, .utf16));
    try testing.expectEqual(@as(usize, 9), byteOf(text, .{ .line = 1, .character = 4 }, .utf16));
    try testing.expectEqual(@as(usize, 9), byteOf(text, .{ .line = 1, .character = 6 }, .utf8));
    try testing.expectEqual(@as(usize, 5), byteOf(text, .{ .line = 1, .character = 2 }, .utf16));
    // Past the end of a line clamps; past the last line is the length.
    try testing.expectEqual(@as(usize, 2), byteOf(text, .{ .line = 0, .character = 99 }, .utf16));
    try testing.expectEqual(text.len, byteOf(text, .{ .line = 9, .character = 0 }, .utf16));
    try testing.expectEqual(Position{ .line = 2, .character = 1 }, positionOf(text, 99, .utf16));
}

test "uri ↔ path, with percent-encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("file:///ws/a%20b/c.rs", try uriFromPath(a, "/ws/a b/c.rs"));
    try testing.expectEqualStrings("/ws/a b/c.rs", (try pathFromUri(a, "file:///ws/a%20b/c.rs")).?);
    try testing.expect((try pathFromUri(a, "untitled:one")) == null);
}

test "readers: inlay hints (parts joined, sorted), code lenses, colours as bytes, links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try std.json.parseFromSlice(Value, a, "[{\"position\":{\"line\":2,\"character\":1},\"label\":[{\"value\":\": \"},{\"value\":\"u32\"}],\"kind\":1,\"paddingLeft\":true},{\"position\":{\"line\":0,\"character\":7},\"label\":\"x:\",\"kind\":2,\"paddingRight\":true},{\"position\":{\"line\":1,\"character\":0},\"label\":\"\"}]", .{});
    defer h.deinit();
    const hints = try readInlayHints(a, h.value);
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqualStrings("x:", hints[0].label);
    try testing.expectEqual(HintKind.parameter, hints[0].kind);
    try testing.expect(hints[0].pad_right and !hints[0].pad_left);
    try testing.expectEqualStrings(": u32", hints[1].label);
    try testing.expectEqual(HintKind.type, hints[1].kind);
    var l = try std.json.parseFromSlice(Value, a, "[{\"range\":{\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":3}},\"data\":1},{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":2}},\"command\":{\"title\":\"3 references\",\"command\":\"refs\"}}]", .{});
    defer l.deinit();
    const lenses = try readCodeLenses(a, l.value);
    try testing.expectEqual(@as(usize, 2), lenses.len);
    try testing.expectEqualStrings("3 references", lenses[0].title.?);
    try testing.expect(lenses[1].title == null);
    var c = try std.json.parseFromSlice(Value, a, "[{\"range\":{\"start\":{\"line\":0,\"character\":5},\"end\":{\"line\":0,\"character\":12}},\"color\":{\"red\":1,\"green\":0.5,\"blue\":0,\"alpha\":1}}]", .{});
    defer c.deinit();
    const colors = try readColors(a, c.value);
    try testing.expectEqual(@as(usize, 1), colors.len);
    try testing.expectEqual(@as(u8, 255), colors[0].r);
    try testing.expectEqual(@as(u8, 128), colors[0].g);
    try testing.expectEqual(@as(u8, 0), colors[0].b);
    var d = try std.json.parseFromSlice(Value, a, "[{\"range\":{\"start\":{\"line\":3,\"character\":2},\"end\":{\"line\":3,\"character\":20}},\"target\":\"https://ziglang.org\"},{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}]", .{});
    defer d.deinit();
    const links = try readDocumentLinks(a, d.value);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expect(links[0].target == null);
    try testing.expectEqualStrings("https://ziglang.org", links[1].target.?);
    try testing.expectEqual(@as(usize, 0), (try readInlayHints(a, null)).len);
}

test "readers: diagnostics, completion items, hover shapes, nested symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try std.json.parseFromSlice(Value, a, "{\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5}},\"severity\":2,\"message\":\"unused\",\"source\":\"ts\",\"code\":6133}", .{});
    defer p.deinit();
    const d = readDiagnostic(p.value).?;
    try testing.expectEqual(Severity.warning, d.severity);
    try testing.expectEqualStrings("unused", d.message);
    try testing.expect(d.code == null);
    var c = try std.json.parseFromSlice(Value, a, "{\"items\":[{\"label\":\"forEach\",\"kind\":2,\"insertTextFormat\":2,\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":6}},\"newText\":\"forEach($1)\"},\"documentation\":{\"kind\":\"markdown\",\"value\":\"Calls fn\"}},{\"label\":\"x\"}]}", .{});
    defer c.deinit();
    const items = try readCompletions(a, c.value);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("forEach($1)", items[0].insert_text);
    try testing.expectEqual(InsertFormat.snippet, items[0].format);
    try testing.expectEqual(@as(u32, 4), items[0].edit_range.?.start.character);
    try testing.expectEqualStrings("Calls fn", items[0].documentation.?);
    try testing.expectEqualStrings("x", items[1].insert_text);
    try testing.expect(items[1].label_description == null and items[1].label_detail == null);
    // LSP 3.17 `labelDetails`, as pyright sends an auto-import.
    var ld = try std.json.parseFromSlice(Value, a, "[{\"label\":\"Pattern\",\"kind\":7,\"detail\":\"Auto-import\",\"labelDetails\":{\"description\":\"re\"}},{\"label\":\"run\",\"labelDetails\":{\"detail\":\"(main)\"}}]", .{});
    defer ld.deinit();
    const auto = try readCompletions(a, ld.value);
    try testing.expectEqualStrings("re", auto[0].label_description.?);
    try testing.expect(auto[0].label_detail == null);
    try testing.expectEqualStrings("Auto-import", auto[0].detail.?);
    try testing.expectEqualStrings("(main)", auto[1].label_detail.?);
    var h = try std.json.parseFromSlice(Value, a, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```rust\\nfn main()\\n```\\n\\nEntry.\\n\"}}", .{});
    defer h.deinit();
    const lines = try readHover(a, h.value);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("fn main()", lines[0]);
    try testing.expectEqualStrings("Entry.", lines[2]);
    var s = try std.json.parseFromSlice(Value, a, "[{\"name\":\"User\",\"kind\":11,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":1}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":10},\"end\":{\"line\":0,\"character\":14}},\"children\":[{\"name\":\"id\",\"kind\":8,\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":12}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":4}}}]}]", .{});
    defer s.deinit();
    const syms = try readSymbols(a, s.value);
    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("interface", symbolKindLabel(syms[0].kind));
    try testing.expectEqual(@as(u32, 10), syms[0].character);
    try testing.expectEqual(@as(u8, 1), syms[1].depth);
}
