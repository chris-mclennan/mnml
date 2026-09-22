//! External formatters and linters: the builtin table for the common
//! extensions (`.formatters.<ext>` / `.linters.<ext>` in the config
//! override it), `{file}` expansion into an argv, and the output
//! parsers that turn a tool's lines into diagnostics — `vimgrep`
//! (`path:line:col: message`), eslint's `--format=unix`, `tsc`, ruff's
//! concise form, shellcheck's gcc form, and a placeholder template for
//! everything else. Pure: nothing here spawns a process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Config = @import("../config/Config.zig");

pub const LintParser = Config.LintParser;

/// A formatter for an extension: an argv (`{file}` unexpanded) and
/// whether it rewrites the file instead of printing.
pub const Formatter = struct {
    argv: []const []const u8,
    in_place: bool = false,
};

/// A linter for an extension.
pub const Linter = struct {
    argv: []const []const u8,
    parser: LintParser = .vimgrep,
    pattern: []const u8 = "",
};

const FmtEntry = struct { []const u8, Formatter };
const LintEntry = struct { []const u8, Linter };

/// What runs when the config names nothing. The binaries are assumed
/// on PATH; a missing one is reported when the run is asked for.
pub const builtin_formatters = [_]FmtEntry{
    .{ "rs", .{ .argv = &.{ "rustfmt", "--emit", "stdout" } } },
    .{ "ts", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "tsx", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "js", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "jsx", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "json", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "css", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "scss", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "html", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "md", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "yaml", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "yml", .{ .argv = &.{ "prettier", "--stdin-filepath", "{file}" } } },
    .{ "py", .{ .argv = &.{ "ruff", "format", "-" } } },
    .{ "go", .{ .argv = &.{"gofmt"} } },
    .{ "sh", .{ .argv = &.{ "shfmt", "-i", "2" } } },
    .{ "bash", .{ .argv = &.{ "shfmt", "-i", "2" } } },
    .{ "lua", .{ .argv = &.{ "stylua", "-" } } },
    .{ "zig", .{ .argv = &.{ "zig", "fmt", "--stdin" } } },
    .{ "nix", .{ .argv = &.{"nixfmt"} } },
};

pub const builtin_linters = [_]LintEntry{
    .{ "ts", .{ .argv = &.{ "eslint", "--no-color", "--format=unix", "{file}" }, .parser = .eslint } },
    .{ "tsx", .{ .argv = &.{ "eslint", "--no-color", "--format=unix", "{file}" }, .parser = .eslint } },
    .{ "js", .{ .argv = &.{ "eslint", "--no-color", "--format=unix", "{file}" }, .parser = .eslint } },
    .{ "jsx", .{ .argv = &.{ "eslint", "--no-color", "--format=unix", "{file}" }, .parser = .eslint } },
    .{ "py", .{ .argv = &.{ "ruff", "check", "--no-color", "--output-format=concise", "{file}" }, .parser = .ruff } },
    .{ "sh", .{ .argv = &.{ "shellcheck", "--format=gcc", "{file}" }, .parser = .shellcheck } },
    .{ "bash", .{ .argv = &.{ "shellcheck", "--format=gcc", "{file}" }, .parser = .shellcheck } },
};

/// The config's formatter for the file, else the builtin, else null.
/// `ext` is the file's extension (empty for `bin/run-all`) and `key`
/// the language `highlight.detect` named for it (`sh` for that script,
/// by its shebang; empty when no grammar knows the file): a
/// `.formatters.sh` row — or the builtin `shfmt` — answers for both. A
/// row for the exact extension wins over the language's.
pub fn formatterFor(cfg: *const Config, ext: []const u8, key: []const u8) ?Formatter {
    for ([_][]const u8{ ext, key }) |name| {
        if (name.len == 0) continue;
        if (cfg.formatters.get(name)) |f| {
            if (f.cmd.len == 0) return null;
            return .{ .argv = f.cmd, .in_place = f.in_place };
        }
    }
    for ([_][]const u8{ ext, key }) |name| {
        if (name.len == 0) continue;
        for (builtin_formatters) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    }
    return null;
}

/// `formatterFor`, for the linter tables.
pub fn linterFor(cfg: *const Config, ext: []const u8, key: []const u8) ?Linter {
    for ([_][]const u8{ ext, key }) |name| {
        if (name.len == 0) continue;
        if (cfg.linters.get(name)) |l| {
            if (l.cmd.len == 0) return null;
            return .{ .argv = l.cmd, .parser = l.parser, .pattern = l.pattern };
        }
    }
    for ([_][]const u8{ ext, key }) |name| {
        if (name.len == 0) continue;
        for (builtin_linters) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    }
    return null;
}

/// Is the tool for the file one the config named (`.formatters.<ext>` /
/// `.linters.<ext>`, by extension or by language key), as opposed to a
/// builtin row?
pub fn linterConfigured(cfg: *const Config, ext: []const u8, key: []const u8) bool {
    return (ext.len > 0 and cfg.linters.get(ext) != null) or (key.len > 0 and cfg.linters.get(key) != null);
}

/// `argv` with every `{file}` replaced by `file` (an argument that is
/// only the placeholder becomes the path; one that embeds it is
/// spliced). On `arena`.
pub fn expandArgv(arena: Allocator, argv: []const []const u8, file: []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| {
        if (std.mem.indexOf(u8, a, "{file}") == null) {
            out[i] = a;
            continue;
        }
        const n = std.mem.replacementSize(u8, a, "{file}", file);
        const buf = try arena.alloc(u8, n);
        _ = std.mem.replace(u8, a, "{file}", file, buf);
        out[i] = buf;
    }
    return out;
}

/// Does `argv` name the file at all (a stdin-only tool does not)?
pub fn takesFile(argv: []const []const u8) bool {
    for (argv) |a| if (std.mem.indexOf(u8, a, "{file}") != null) return true;
    return false;
}

// ─── output parsers ─────────────────────────────────────────────────────

const LineCol = struct { path: []const u8, line: u32, col: u32, rest: []const u8 };

/// `path:line:col: rest` (a `:` after the column is optional).
fn splitPathLineCol(line: []const u8) ?LineCol {
    // Walk from the right: the last two `:`-separated numbers before
    // the message are line and column.
    var probe: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, probe, ':')) |c1| {
        probe = c1 + 1;
        const after1 = line[c1 + 1 ..];
        const c2 = std.mem.indexOfScalar(u8, after1, ':') orelse continue;
        const ln = std.fmt.parseInt(u32, after1[0..c2], 10) catch continue;
        const after2 = after1[c2 + 1 ..];
        var d: usize = 0;
        while (d < after2.len and std.ascii.isDigit(after2[d])) d += 1;
        if (d == 0) continue;
        const col = std.fmt.parseInt(u32, after2[0..d], 10) catch continue;
        var rest = after2[d..];
        if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
        return .{ .path = line[0..c1], .line = ln, .col = col, .rest = std.mem.trim(u8, rest, " \t") };
    }
    return null;
}

/// The tool named this file? Empty, `-` and `<stdin>` mean "the input".
fn pathMatches(reported: []const u8, file: []const u8) bool {
    const r = std.mem.trim(u8, reported, " \t");
    if (r.len == 0 or std.mem.eql(u8, r, "-") or std.mem.eql(u8, r, "<stdin>")) return true;
    if (std.mem.endsWith(u8, file, r) or std.mem.endsWith(u8, r, file)) return true;
    return std.mem.eql(u8, std.fs.path.basename(r), std.fs.path.basename(file));
}

fn oneChar(line: u32, col: u32) types.Range {
    const l = line -| 1;
    const c = col -| 1;
    return .{ .start = .{ .line = l, .character = c }, .end = .{ .line = l, .character = c + 1 } };
}

fn severityWord(w: []const u8) ?types.Severity {
    if (std.ascii.eqlIgnoreCase(w, "error") or std.ascii.eqlIgnoreCase(w, "e")) return .err;
    if (std.ascii.eqlIgnoreCase(w, "warning") or std.ascii.eqlIgnoreCase(w, "warn") or std.ascii.eqlIgnoreCase(w, "w")) return .warning;
    if (std.ascii.eqlIgnoreCase(w, "note") or std.ascii.eqlIgnoreCase(w, "info") or std.ascii.eqlIgnoreCase(w, "information")) return .info;
    if (std.ascii.eqlIgnoreCase(w, "hint") or std.ascii.eqlIgnoreCase(w, "style")) return .hint;
    return null;
}

/// Parse `text` (the tool's stdout, or stderr when stdout was empty)
/// into diagnostics for `file`. Messages borrow `text`.
pub fn parseOutput(arena: Allocator, parser: LintParser, pattern: []const u8, text: []const u8, file: []const u8) Allocator.Error![]types.Diagnostic {
    var out: std.ArrayListUnmanaged(types.Diagnostic) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const d = switch (parser) {
            .vimgrep => parseVimgrep(line, file, "lint"),
            .eslint => parseEslint(line, file),
            .tsc => parseTsc(line, file),
            .ruff => parseVimgrep(line, file, "ruff"),
            .shellcheck => parseShellcheck(line, file),
            .pattern => parsePattern(pattern, line, file),
        } orelse continue;
        try out.append(arena, d);
    }
    return out.items;
}

fn parseVimgrep(line: []const u8, file: []const u8, source: []const u8) ?types.Diagnostic {
    const lc = splitPathLineCol(line) orelse return null;
    if (!pathMatches(lc.path, file)) return null;
    var severity: types.Severity = .warning;
    var msg = lc.rest;
    // `error: …` / `warning: …` prefixes name the severity.
    if (std.mem.indexOfScalar(u8, msg, ':')) |c| if (severityWord(msg[0..c])) |sev| {
        severity = sev;
        msg = std.mem.trimStart(u8, msg[c + 1 ..], " ");
    };
    return .{ .range = oneChar(lc.line, lc.col), .severity = severity, .message = msg, .source = source, .code = null };
}

/// `path:line:col: message [rule] (Severity)`.
fn parseEslint(line: []const u8, file: []const u8) ?types.Diagnostic {
    const lc = splitPathLineCol(line) orelse return null;
    if (!pathMatches(lc.path, file)) return null;
    var msg = lc.rest;
    var severity: types.Severity = .warning;
    if (std.mem.endsWith(u8, msg, " (Error)")) {
        severity = .err;
        msg = msg[0 .. msg.len - " (Error)".len];
    } else if (std.mem.endsWith(u8, msg, " (Warning)")) {
        msg = msg[0 .. msg.len - " (Warning)".len];
    }
    return .{ .range = oneChar(lc.line, lc.col), .severity = severity, .message = msg, .source = "eslint", .code = null };
}

/// `path(line,col): error TSnnnn: message`.
fn parseTsc(line: []const u8, file: []const u8) ?types.Diagnostic {
    const lp = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const rp = std.mem.indexOfScalarPos(u8, line, lp, ')') orelse return null;
    const coords = line[lp + 1 .. rp];
    const comma = std.mem.indexOfScalar(u8, coords, ',') orelse return null;
    const ln = std.fmt.parseInt(u32, std.mem.trim(u8, coords[0..comma], " "), 10) catch return null;
    const col = std.fmt.parseInt(u32, std.mem.trim(u8, coords[comma + 1 ..], " "), 10) catch return null;
    if (!pathMatches(line[0..lp], file)) return null;
    var rest = std.mem.trim(u8, line[rp + 1 ..], " ");
    if (rest.len > 0 and rest[0] == ':') rest = std.mem.trimStart(u8, rest[1..], " ");
    var severity: types.Severity = .err;
    if (std.mem.startsWith(u8, rest, "warning")) {
        severity = .warning;
        rest = std.mem.trimStart(u8, rest["warning".len..], " ");
    } else if (std.mem.startsWith(u8, rest, "error")) {
        rest = std.mem.trimStart(u8, rest["error".len..], " ");
    }
    return .{ .range = oneChar(ln, col), .severity = severity, .message = rest, .source = "tsc", .code = null };
}

/// `path:line:col: severity: code: message`.
fn parseShellcheck(line: []const u8, file: []const u8) ?types.Diagnostic {
    const lc = splitPathLineCol(line) orelse return null;
    if (!pathMatches(lc.path, file)) return null;
    var msg = lc.rest;
    var severity: types.Severity = .warning;
    if (std.mem.indexOfScalar(u8, msg, ':')) |c| if (severityWord(msg[0..c])) |sev| {
        severity = sev;
        msg = std.mem.trimStart(u8, msg[c + 1 ..], " ");
    };
    return .{ .range = oneChar(lc.line, lc.col), .severity = severity, .message = msg, .source = "shellcheck", .code = null };
}

/// Match `line` against `pattern`, a template of literal text and the
/// placeholders `{file}` `{line}` `{col}` `{severity}` `{message}`
/// (`{_}` skips a field). A placeholder reads up to the literal that
/// follows it (or the line's end); `{line}` / `{col}` must be digits.
pub fn parsePattern(pattern: []const u8, line: []const u8, file: []const u8) ?types.Diagnostic {
    if (pattern.len == 0) return null;
    var path: []const u8 = "";
    var ln: u32 = 0;
    var col: u32 = 1;
    var severity: types.Severity = .warning;
    var message: []const u8 = "";
    var pi: usize = 0;
    var li: usize = 0;
    while (pi < pattern.len) {
        if (pattern[pi] == '{') {
            const close = std.mem.indexOfScalarPos(u8, pattern, pi, '}') orelse return null;
            const name = pattern[pi + 1 .. close];
            pi = close + 1;
            // The literal that ends this field.
            const lit_end = std.mem.indexOfScalarPos(u8, pattern, pi, '{') orelse pattern.len;
            const lit = pattern[pi..lit_end];
            const field_end = if (lit.len == 0) line.len else (std.mem.indexOfPos(u8, line, li, lit) orelse return null);
            const field = line[li..field_end];
            li = field_end;
            if (std.mem.eql(u8, name, "file")) {
                path = field;
            } else if (std.mem.eql(u8, name, "line")) {
                ln = std.fmt.parseInt(u32, std.mem.trim(u8, field, " "), 10) catch return null;
            } else if (std.mem.eql(u8, name, "col")) {
                col = std.fmt.parseInt(u32, std.mem.trim(u8, field, " "), 10) catch return null;
            } else if (std.mem.eql(u8, name, "severity")) {
                severity = severityWord(std.mem.trim(u8, field, " ")) orelse .warning;
            } else if (std.mem.eql(u8, name, "message")) {
                message = std.mem.trim(u8, field, " ");
            }
        } else {
            const lit_end = std.mem.indexOfScalarPos(u8, pattern, pi, '{') orelse pattern.len;
            const lit = pattern[pi..lit_end];
            if (!std.mem.startsWith(u8, line[li..], lit)) return null;
            li += lit.len;
            pi = lit_end;
        }
    }
    if (ln == 0) return null;
    if (!pathMatches(path, file)) return null;
    return .{ .range = oneChar(ln, col), .severity = severity, .message = message, .source = "lint", .code = null };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "formatterFor / linterFor: the config wins over the builtin table; an empty cmd disables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{};
    try testing.expectEqualStrings("rustfmt", formatterFor(&cfg, "rs", "rs").?.argv[0]);
    try testing.expectEqualStrings("eslint", linterFor(&cfg, "TS", "ts").?.argv[0]);
    try testing.expect(formatterFor(&cfg, "unobtanium", "") == null);
    try cfg.formatters.put(arena.allocator(), "rs", .{ .cmd = &.{"my-fmt"}, .in_place = true });
    try cfg.linters.put(arena.allocator(), "ts", .{ .cmd = &.{} });
    const f = formatterFor(&cfg, "rs", "rs").?;
    try testing.expectEqualStrings("my-fmt", f.argv[0]);
    try testing.expect(f.in_place);
    try testing.expect(linterFor(&cfg, "ts", "ts") == null);
    try testing.expect(linterConfigured(&cfg, "ts", "ts"));
    try testing.expect(!linterConfigured(&cfg, "sh", "sh"));
}

test "an extension-less script and a dotfile take the tools of the language the detector named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{};
    // `bin/run-all` under `#!/usr/bin/env bash`: no extension, key `sh`.
    try testing.expectEqualStrings("shfmt", formatterFor(&cfg, "", "sh").?.argv[0]);
    try testing.expectEqualStrings("shellcheck", linterFor(&cfg, "", "sh").?.argv[0]);
    // A `.zshrc` is the same; a `Makefile` (key `make`) has no tool row.
    try testing.expect(formatterFor(&cfg, "", "make") == null);
    try testing.expect(formatterFor(&cfg, "", "") == null);
    // A `.linters.sh` in the config reaches the script too, and a row
    // for the exact extension wins over the language's.
    try cfg.linters.put(arena.allocator(), "sh", .{ .cmd = &.{ "my-sh-lint", "{file}" } });
    try cfg.linters.put(arena.allocator(), "bash", .{ .cmd = &.{ "my-bash-lint", "{file}" } });
    try testing.expectEqualStrings("my-sh-lint", linterFor(&cfg, "", "sh").?.argv[0]);
    try testing.expectEqualStrings("my-bash-lint", linterFor(&cfg, "bash", "sh").?.argv[0]);
    try testing.expect(linterConfigured(&cfg, "", "sh"));
}

test "expandArgv splices {file} and leaves the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try expandArgv(arena.allocator(), &.{ "prettier", "--stdin-filepath={file}", "{file}" }, "src/a b.ts");
    try testing.expectEqualStrings("prettier", out[0]);
    try testing.expectEqualStrings("--stdin-filepath=src/a b.ts", out[1]);
    try testing.expectEqualStrings("src/a b.ts", out[2]);
    try testing.expect(takesFile(&.{ "x", "{file}" }) and !takesFile(&.{"gofmt"}));
}

test "the five parsers and the pattern template read their line shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vim = try parseOutput(a, .vimgrep, "", "src/a.c:12:5: error: bad thing\nsrc/other.c:1:1: nope\n\nsrc/a.c:3:2: just a note\n", "/ws/src/a.c");
    try testing.expectEqual(@as(usize, 2), vim.len);
    try testing.expectEqual(types.Severity.err, vim[0].severity);
    try testing.expectEqual(@as(u32, 11), vim[0].range.start.line);
    try testing.expectEqual(@as(u32, 4), vim[0].range.start.character);
    try testing.expectEqualStrings("bad thing", vim[0].message);
    try testing.expectEqualStrings("just a note", vim[1].message);
    const es = try parseOutput(a, .eslint, "", "src/x.ts:3:7: 'y' is defined but never used. [no-unused-vars] (Warning)\nsrc/x.ts:9:1: Parsing error [x] (Error)\n\n2 problems", "/ws/src/x.ts");
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqualStrings("'y' is defined but never used. [no-unused-vars]", es[0].message);
    try testing.expectEqual(types.Severity.err, es[1].severity);
    const ts = try parseOutput(a, .tsc, "", "src/x.ts(4,10): error TS2322: Type 'string' is not assignable.\nsrc/y.ts(1,1): error TS1: other file\n", "/ws/src/x.ts");
    try testing.expectEqual(@as(usize, 1), ts.len);
    try testing.expectEqual(@as(u32, 3), ts[0].range.start.line);
    try testing.expectEqualStrings("TS2322: Type 'string' is not assignable.", ts[0].message);
    const ruff = try parseOutput(a, .ruff, "", "app.py:2:8: F401 `os` imported but unused\nFound 1 error.\n", "/ws/app.py");
    try testing.expectEqual(@as(usize, 1), ruff.len);
    try testing.expectEqualStrings("F401 `os` imported but unused", ruff[0].message);
    const sc = try parseOutput(a, .shellcheck, "", "run.sh:5:3: warning: x is referenced but not assigned. [SC2154]\nrun.sh:9:1: note: Double quote to prevent globbing. [SC2086]\n", "/ws/run.sh");
    try testing.expectEqual(@as(usize, 2), sc.len);
    try testing.expectEqual(types.Severity.info, sc[1].severity);
    try testing.expectEqualStrings("shellcheck", sc[0].source.?);
    const pat = try parseOutput(a, .pattern, "{file}|{line}|{col}|{severity}|{message}", "a.zig|7|2|E|unused local\nbogus line\nb.zig|1|1|W|elsewhere", "/ws/a.zig");
    try testing.expectEqual(@as(usize, 1), pat.len);
    try testing.expectEqual(types.Severity.err, pat[0].severity);
    try testing.expectEqual(@as(u32, 6), pat[0].range.start.line);
    try testing.expectEqualStrings("unused local", pat[0].message);
    // A template with a literal head and no column.
    const p2 = parsePattern("E {line} {file}: {message}", "E 3 a.zig: hmm", "/ws/a.zig").?;
    try testing.expectEqual(@as(u32, 2), p2.range.start.line);
    try testing.expectEqualStrings("hmm", p2.message);
    try testing.expect(parsePattern("", "x", "a") == null);
}
