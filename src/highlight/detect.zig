//! The one language detector: a file's table key from its name, its
//! extension, or the interpreter its first line names — in that order,
//! the way `syntax.zig` always decided which grammar to load. Every
//! consumer that used to key on `std.fs.path.extension` alone reads
//! this instead: the language server routing and its `languageId`
//! (`src/lsp/client.zig`), the formatter and linter tables
//! (`src/lsp/tools.zig`), the statusline's language chip and the
//! outline's fallback (`Document.language`). A `bin/run-all` that opens
//! with `#!/usr/bin/env bash`, a `.zshrc`, a `Makefile` all resolve here
//! to the same key the highlighter already used, so what is painted as
//! shell is also linted, formatted and served as shell.

const std = @import("std");
const table = @import("table.zig");

/// Which of the three rules answered.
pub const How = enum { filename, extension, shebang };

pub const Detected = struct {
    /// A `table.entries` key (`sh`, `py`, `make`).
    key: []const u8,
    how: How,

    /// The words the language chip's click uses.
    pub fn viaLabel(self: Detected) []const u8 {
        return switch (self.how) {
            .filename => "file name",
            .extension => "file extension",
            .shebang => "shebang",
        };
    }
};

/// The longest extension the table can answer for.
pub const max_ext = 32;

/// `path`'s language, with `text` (the whole text, or its first line)
/// supplying the shebang of an extension-less script. Null when
/// mnml-zig has no grammar for it.
pub fn detect(path: ?[]const u8, text: []const u8) ?Detected {
    if (path) |p| {
        const base = std.fs.path.basename(p);
        if (table.keyForFilename(base)) |k| return .{ .key = k, .how = .filename };
        const ext = std.fs.path.extension(base);
        if (ext.len > 1 and ext.len - 1 <= max_ext) {
            var lower: [max_ext]u8 = undefined;
            const e = std.ascii.lowerString(&lower, ext[1..]);
            if (table.keyForExtension(e)) |k| return .{ .key = k, .how = .extension };
            if (table.find(e)) |i| return .{ .key = table.entries[i].key, .how = .extension };
        }
    }
    if (keyForShebang(text)) |k| return .{ .key = k, .how = .shebang };
    return null;
}

/// `detect` for a caller that only has the key in mind.
pub fn keyFor(path: ?[]const u8, text: []const u8) ?[]const u8 {
    return if (detect(path, text)) |d| d.key else null;
}

/// `#!/usr/bin/env python3` → `py`, and the other interpreters a
/// script file names. Only the first line is read.
pub fn keyForShebang(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "#!")) return null;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trimEnd(u8, text[2..nl], "\r");
    const interpreters = [_]struct { []const u8, []const u8 }{
        .{ "python", "py" }, .{ "node", "js" }, .{ "deno", "ts" },   .{ "bash", "sh" },
        .{ "zsh", "sh" },    .{ "fish", "sh" }, .{ "ksh", "sh" },    .{ "mksh", "sh" },
        .{ "dash", "sh" },   .{ "ash", "sh" },  .{ "sh", "sh" },     .{ "ruby", "rb" },
        .{ "lua", "lua" },   .{ "php", "php" }, .{ "elixir", "ex" }, .{ "swift", "swift" },
    };
    // The interpreter is the last path segment of the first word, or the
    // word after `env` (skipping env's own `-S` / `-i` style flags).
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var word = it.next() orelse return null;
    if (std.mem.endsWith(u8, word, "/env") or std.mem.eql(u8, word, "env")) {
        word = it.next() orelse return null;
        while (word.len > 0 and word[0] == '-') word = it.next() orelse return null;
    }
    const name = std.fs.path.basename(word);
    for (interpreters) |i| if (std.mem.startsWith(u8, name, i[0])) return i[1];
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the three rules, in order: file name, then extension, then shebang" {
    try testing.expectEqualStrings("make", detect("/x/Makefile", "").?.key);
    try testing.expectEqual(How.filename, detect("/x/Makefile", "").?.how);
    try testing.expectEqualStrings("dockerfile", detect("/x/Dockerfile.dev", "").?.key);
    try testing.expectEqualStrings("tsx", detect("/x/App.tsx", "").?.key);
    try testing.expectEqual(How.extension, detect("/x/LIB.RS", "").?.how);
    try testing.expectEqualStrings("rs", detect("/x/LIB.RS", "").?.key);
    // An extension wins over a shebang that disagrees: the name is what
    // the user chose.
    try testing.expectEqualStrings("py", detect("/x/a.py", "#!/bin/bash\n").?.key);
    try testing.expect(detect("/x/notes.xyz", "plain") == null);
    try testing.expect(detect(null, "") == null);
}

test "an extension-less script takes its interpreter's language" {
    const run = detect("/x/bin/run-all", "#!/usr/bin/env bash\nset -e\n").?;
    try testing.expectEqualStrings("sh", run.key);
    try testing.expectEqual(How.shebang, run.how);
    try testing.expectEqualStrings("shebang", run.viaLabel());
    try testing.expectEqualStrings("sh", keyForShebang("#!/bin/sh\n").?);
    try testing.expectEqualStrings("sh", keyForShebang("#!/usr/bin/env zsh\r\n").?);
    try testing.expectEqualStrings("sh", keyForShebang("#!/usr/bin/env -S bash -euo pipefail\n").?);
    try testing.expectEqualStrings("py", keyForShebang("#!/usr/bin/env python3\nprint(1)\n").?);
    try testing.expectEqualStrings("js", keyFor(null, "#!/usr/bin/env node\n").?);
    try testing.expect(keyForShebang("#!/usr/bin/perl\n") == null);
    try testing.expect(keyForShebang("# not a shebang\n") == null);
    try testing.expect(keyForShebang("#!") == null);
}

test "the shell dotfiles resolve by name, with no extension and no shebang" {
    for ([_][]const u8{ ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases", ".profile", ".shrc", ".env", ".envrc" }) |name| {
        const d = detect(name, "export X=1\n") orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("sh", d.key);
        try testing.expectEqual(How.filename, d.how);
    }
    // A dotfile the table does not know stays plain.
    try testing.expect(detect(".gitconfig", "[user]\n") == null);
}
