//! Hover help for the editor's own cells: a text cell, the gutter, the
//! fold chevron. The entry names the line and what is on it — a
//! diagnostic, a breakpoint, a closed fold — and while the debugger is
//! stopped the value of the word under the pointer is the body, as the
//! tooltip shows it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const hit = @import("../../ui/hit.zig");
const HitTarget = hit.HitTarget;
const lsp_app = @import("../lsp.zig");
const dap = @import("../dap.zig");

const ask = copy.ask_link;

/// The diagnostics on `line` of the editor pane `pane`, as `error: …`
/// lines; empty when there are none.
fn diagnosticsOn(app: *App, arena: Allocator, pane: app_mod.PaneId, line: u32) Allocator.Error![]const u8 {
    const e = app.panes.editor(pane) orelse return "";
    const path = e.buf.doc.path orelse return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lsp_app.diagnosticsFor(app, path)) |d| if (d.range.start.line == line) {
        try out.print(arena, " {s}: {s}", .{ d.severity.label(), d.message[0 .. std.mem.indexOfScalar(u8, d.message, '\n') orelse d.message.len] });
    };
    return out.items;
}

pub fn cell(app: *App, arena: Allocator, pane: app_mod.PaneId, line: u32, col: u32) Allocator.Error!?Entry {
    if (try dap.hoverValue(app, arena, pane, line, col)) |tip| return .{
        .title = tip.title,
        .body = try std.fmt.allocPrint(arena, "{s} The debugger is stopped, so the word under the pointer shows its value from the variables the last stop fetched — no round trip to the adapter. Add it as a watch to keep it in the Debug column; `dap.evaluate_hover` evaluates an expression the pointer is not on.", .{tip.detail orelse ""}),
        .keys = &.{ .{ .command = .@"dap.add_watch", .label = "Add a watch" }, .{ .command = .@"dap.evaluate_hover", .label = "Evaluate" }, .{ .command = .@"dap.continue", .label = "Continue" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.add_watch", .label = "Watch it" } }, .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } }, ask },
    };
    const diags = try diagnosticsOn(app, arena, pane, line);
    return .{
        .title = try std.fmt.allocPrint(arena, "Line {d}", .{line + 1}),
        .body = if (diags.len > 0)
            try std.fmt.allocPrint(arena, "This line has a diagnostic —{s}. Click places the cursor there and the code action (the lightbulb chord) offers the server's fixes; drag selects; right-click is the editor menu. The statusline's count chip lists every problem in the file, worst first.", .{diags})
        else
            "Click places the cursor on this cell; drag selects; a double-click takes the word and a triple the line; right-click is the editor menu — the clipboard, go to definition and references, the AI rows, format. The wheel scrolls by `ui.wheel_lines`; Ctrl+click on a symbol goes to its definition.",
        .keys = &.{ .{ .command = .@"lsp.goto_definition", .label = "Go to definition" }, .{ .command = .@"lsp.code_action", .label = "Code actions" }, .{ .command = .@"lsp.hover", .label = "Hover" } },
        .links = if (diags.len > 0) &.{ .{ .command = .{ .id = .@"lsp.quick_fix", .label = "Quick fix" } }, .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Every problem in the file" } }, ask } else &.{ .{ .command = .{ .id = .@"lsp.code_action", .label = "Code actions" } }, .{ .command = .{ .id = .@"ai.explain", .label = "Explain the selection" } } },
    };
}

pub fn gutter(app: *App, arena: Allocator, g: hit.GutterRef) Allocator.Error!?Entry {
    const diags = try diagnosticsOn(app, arena, g.pane, g.line);
    return .{
        .title = try std.fmt.allocPrint(arena, "Line {d} — the gutter", .{g.line + 1}),
        .body = if (diags.len > 0)
            try std.fmt.allocPrint(arena, "The line number and the sign cell. The sign here is a diagnostic —{s}. Click the sign cell to toggle a breakpoint on this line (a breakpoint's own sign wins the cell); right-click is the breakpoint menu — conditional, hit count, log message. The pane's colour rail paints into an empty sign cell.", .{diags})
        else
            "The line number and the sign cell beside it. Click the sign cell to set or clear a breakpoint on this line — kept without a debug session and listed in the Debug column; right-click is the breakpoint menu: conditional, hit count, a log message instead of a stop. A diagnostic or a git change paints its sign here, and the pane's colour rail takes the cell when nothing else does.",
        .keys = &.{ .{ .command = .@"dap.toggle_breakpoint", .label = "Toggle a breakpoint" }, .{ .command = .@"dap.toggle_breakpoint_conditional", .label = "Conditional breakpoint" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint", .label = "Toggle a breakpoint" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "List the breakpoints" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.line_numbers"), .label = "Line numbers" } } },
    };
}

pub fn foldArrow(app: *App, arena: Allocator, g: hit.GutterRef) Allocator.Error!?Entry {
    const closed = if (app.panes.editor(g.pane)) |e| e.buf.editor.folds.get(g.line) else null;
    return .{
        .title = try std.fmt.allocPrint(arena, "Line {d} — fold", .{g.line + 1}),
        .body = if (closed) |end|
            try std.fmt.allocPrint(arena, "A closed fold: lines {d} to {d} are hidden behind this one, and the marker at the line's end says how many. Click the chevron to open it; `zo` opens and `zc` closes under vim, `editor.toggle_fold` under either profile. Folds are per window and forgotten when the file closes.", .{ g.line + 1, end + 1 })
        else
            "The chevron marks a block that can fold — a function, a bracket pair, a heading's section. Click it to close the fold: the lines under this one hide behind it and a marker at the line's end counts them. `zc` / `zo` under vim, `editor.toggle_fold` under either profile; `ui.always_show_fold_arrows` keeps the chevrons visible instead of on hover.",
        .keys = &.{ .{ .command = .@"editor.toggle_fold", .label = "Toggle the fold" }, .{ .command = .@"editor.unfold_all", .label = "Open every fold" } },
        .links = &.{ .{ .command = .{ .id = .@"editor.toggle_fold", .label = "Toggle it" } }, .{ .command = .{ .id = .@"editor.unfold_all", .label = "Open every fold" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.always_show_fold_arrows"), .label = "Always show the chevrons" } } },
    };
}

/// For the AI: the line's text and its diagnostics.
pub fn askContext(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?[]const u8 {
    const ref: struct { pane: app_mod.PaneId, line: u32 } = switch (target) {
        .editor_cell => |c| .{ .pane = c.pane, .line = c.line },
        .gutter, .fold_arrow => |g| .{ .pane = g.pane, .line = g.line },
        else => return null,
    };
    const e = app.panes.editor(ref.pane) orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "- file: {s}, line {d}\n", .{ if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]", ref.line + 1 });
    if (ref.line < e.buf.editor.lineCount()) {
        const text = e.buf.editor.lineSlice(ref.line);
        try out.print(arena, "- the line: `{s}`\n", .{text[0..@min(text.len, 200)]});
    }
    const diags = try diagnosticsOn(app, arena, ref.pane, ref.line);
    if (diags.len > 0) try out.print(arena, "- diagnostics on it:{s}\n", .{diags});
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "a cell, the gutter and the fold arrow have entries that name the line" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    const id = try app.openScratch();
    try t.expectEqualStrings("Line 3", (try cell(&app, a, id, 2, 0)).?.title);
    try t.expectEqualStrings("Line 3 — the gutter", (try gutter(&app, a, .{ .pane = id, .line = 2 })).?.title);
    try t.expectEqualStrings("Line 1 — fold", (try foldArrow(&app, a, .{ .pane = id, .line = 0 })).?.title);
    try t.expect(std.mem.indexOf(u8, (try foldArrow(&app, a, .{ .pane = id, .line = 0 })).?.body, "can fold") != null);
}
