//! The indent a text is written in, read off its lines: tabs when the
//! indented lines lead with a tab, else the width its indents step by.
//! A formatting request carries this (`tabSize` / `insertSpaces`), so a
//! two-space script is not sent to shfmt as `-i 4` because the config's
//! tab width is four; a `.editorconfig` that names the indent wins over
//! it (`Document.indent_pinned`).

const std = @import("std");

pub const Indent = struct {
    /// The step, in columns, between one indent level and the next.
    unit: usize,
    use_tabs: bool,
};

/// The widest step counted; deltas past it are alignment, not indent.
const max_unit = 8;

/// Null when no line is indented — the text says nothing.
pub fn detect(text: []const u8) ?Indent {
    var tab_lines: usize = 0;
    var space_lines: usize = 0;
    // Positive steps between an indented line and the last non-blank
    // line before it, by width; the most frequent is the unit.
    var steps = [_]usize{0} ** (max_unit + 1);
    var min_indent: usize = 0;
    var prev: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (line[0] == '\t') {
            tab_lines += 1;
            prev = 0;
            continue;
        }
        var n: usize = 0;
        while (n < line.len and line[n] == ' ') n += 1;
        if (n > 0) {
            space_lines += 1;
            if (min_indent == 0 or n < min_indent) min_indent = n;
            if (n > prev and n - prev <= max_unit) steps[n - prev] += 1;
        }
        prev = n;
    }
    if (tab_lines == 0 and space_lines == 0) return null;
    if (tab_lines >= space_lines) return .{ .unit = 0, .use_tabs = true };
    var best: usize = 0;
    for (steps, 0..) |count, width| if (width > 0 and count > 0 and (best == 0 or count > steps[best])) {
        best = width;
    };
    return .{ .unit = if (best > 0) best else @min(min_indent, max_unit), .use_tabs = false };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "two-space and four-space texts say so; tabs say tabs; a flat text says nothing" {
    const two = detect("main() {\n  case x in\n    a) y ;;\n  esac\n}\n").?;
    try testing.expectEqual(@as(usize, 2), two.unit);
    try testing.expect(!two.use_tabs);
    const four = detect("def f():\n    if x:\n        return 1\n    return 2\n").?;
    try testing.expectEqual(@as(usize, 4), four.unit);
    const tabs = detect("fn f() {\n\tif x {\n\t\ty();\n\t}\n}\n").?;
    try testing.expect(tabs.use_tabs);
    try testing.expect(detect("a\nb\n\nc\n") == null);
    try testing.expect(detect("") == null);
}

test "alignment past eight columns and blank lines do not move the unit; the smallest indent stands in when there is one step" {
    // A continuation aligned under an open paren, past the widest step
    // counted, is not an indent step: the smallest indent stands in.
    const aligned = detect("call(aaaaaa,\n           b)\n  inner\n\n  more\n").?;
    try testing.expectEqual(@as(usize, 2), aligned.unit);
    // A shorter alignment IS counted as a step — and outvoted by the
    // steps the body takes: two-space, twice, over one five-column jump.
    const outvoted = detect("main() {\n  a\n  call(x,\n       y)\n  b\n  if c; then\n    d\n  fi\n}\n").?;
    try testing.expectEqual(@as(usize, 2), outvoted.unit);
    // One indented line: its width is the unit.
    const one = detect("x\n   y\n").?;
    try testing.expectEqual(@as(usize, 3), one.unit);
    // Tabs and spaces mixed: the majority wins.
    const mixed = detect("a\n\tb\n\tc\n  d\n").?;
    try testing.expect(mixed.use_tabs);
}
