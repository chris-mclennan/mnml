//! Capture name → theme role. The queries name captures the neovim way
//! (`function.method`, `string.escape`, `punctuation.bracket`,
//! `markup.heading`); the theme knows ten base16 slots plus a few text
//! modifiers. This is the one table that joins them — longest matching
//! prefix wins, so `string.escape` lands on `special` while `string`
//! stays `string`.

const std = @import("std");

pub const Role = enum(u8) {
    /// Unstyled: the capture exists for other tooling (`spell`, `nospell`).
    none = 0,
    comment,
    /// base05 — operators, plain variables, embedded text.
    default,
    /// base08 — members, properties, parameters, builtins.
    variable,
    /// base09 — numbers, booleans, constants, character literals.
    constant,
    /// base0A — types, attributes, tags, labels, modules.
    type,
    /// base0B — strings.
    string,
    /// base0C — constructors, escapes, uris, symbols.
    special,
    /// base0D — functions, headings.
    function,
    /// base0E — keywords.
    keyword,
    /// base0F — punctuation.
    punctuation,
    /// `**strong**` — base05 bold.
    strong,
    /// `*emphasis*` — base05 italic.
    emphasis,
    /// A heading — base0D bold.
    title,
    /// A link target — base0C underlined.
    uri,

    pub const count = std.meta.tags(Role).len;
};

const Entry = struct { []const u8, Role };

/// Ordered so a longer prefix precedes its shorter parent; `roleFor`
/// takes the FIRST entry whose name is the capture or a dotted prefix
/// of it.
const entries = [_]Entry{
    .{ "comment", .comment },
    .{ "spell", .none },
    .{ "nospell", .none },
    .{ "none", .default },
    .{ "conceal", .none },
    .{ "string.escape", .special },
    .{ "string.special", .special },
    .{ "string.regex", .special },
    .{ "string.regexp", .special },
    .{ "string", .string },
    .{ "character.special", .special },
    .{ "character", .constant },
    .{ "escape", .special },
    .{ "keyword", .keyword },
    .{ "include", .keyword },
    .{ "repeat", .keyword },
    .{ "conditional", .keyword },
    .{ "exception", .keyword },
    .{ "storageclass", .keyword },
    .{ "preproc", .keyword },
    .{ "define", .keyword },
    .{ "macro", .function },
    .{ "function", .function },
    .{ "method", .function },
    .{ "constructor", .special },
    .{ "type", .type },
    .{ "attribute", .type },
    .{ "tag.delimiter", .punctuation },
    .{ "tag.attribute", .variable },
    .{ "tag", .type },
    .{ "label", .type },
    .{ "module", .type },
    .{ "namespace", .type },
    .{ "number", .constant },
    .{ "float", .constant },
    .{ "boolean", .constant },
    .{ "constant", .constant },
    .{ "variable.builtin", .constant },
    .{ "variable.member", .variable },
    .{ "variable.parameter", .variable },
    .{ "variable", .default },
    .{ "property", .variable },
    .{ "field", .variable },
    .{ "parameter", .variable },
    .{ "operator", .default },
    .{ "punctuation", .punctuation },
    .{ "embedded", .default },
    .{ "text.title", .title },
    .{ "text.literal", .string },
    .{ "text.uri", .uri },
    .{ "text.reference", .special },
    .{ "text.strong", .strong },
    .{ "text.emphasis", .emphasis },
    .{ "text.quote", .comment },
    .{ "text", .default },
    .{ "markup.heading", .title },
    .{ "markup.raw", .string },
    .{ "markup.link.url", .uri },
    .{ "markup.link.label", .special },
    .{ "markup.link", .special },
    .{ "markup.strong", .strong },
    .{ "markup.italic", .emphasis },
    .{ "markup.list", .punctuation },
    .{ "markup.quote", .comment },
    .{ "markup", .default },
    .{ "diff.plus", .string },
    .{ "diff.minus", .variable },
    .{ "diff.delta", .type },
    .{ "error", .none },
    .{ "symbol", .special },
    .{ "regex", .special },
};

/// The role a capture name paints with. Unknown names get `default`
/// rather than nothing: a query that bothered to capture a node meant it
/// to stand out from plain text.
pub fn roleFor(name: []const u8) Role {
    inline for (entries) |e| {
        const prefix = e[0];
        if (std.mem.startsWith(u8, name, prefix) and (name.len == prefix.len or name[prefix.len] == '.')) return e[1];
    }
    // Local-scope helpers (`_foo`, `local.definition`) are not paint.
    if (name.len > 0 and name[0] == '_') return .none;
    if (std.mem.startsWith(u8, name, "local.") or std.mem.startsWith(u8, name, "injection.")) return .none;
    return .default;
}

test "longest prefix wins and dotted suffixes inherit" {
    try std.testing.expectEqual(Role.string, roleFor("string"));
    try std.testing.expectEqual(Role.special, roleFor("string.escape"));
    try std.testing.expectEqual(Role.string, roleFor("string.documentation"));
    try std.testing.expectEqual(Role.function, roleFor("function.method.call"));
    try std.testing.expectEqual(Role.punctuation, roleFor("punctuation.bracket"));
    try std.testing.expectEqual(Role.keyword, roleFor("keyword.function"));
    try std.testing.expectEqual(Role.title, roleFor("markup.heading.1"));
    try std.testing.expectEqual(Role.none, roleFor("spell"));
    try std.testing.expectEqual(Role.none, roleFor("_sigil_name"));
    try std.testing.expectEqual(Role.none, roleFor("injection.content"));
    try std.testing.expectEqual(Role.default, roleFor("stringly"));
    try std.testing.expectEqual(Role.constant, roleFor("variable.builtin"));
    try std.testing.expectEqual(Role.variable, roleFor("property"));
}
