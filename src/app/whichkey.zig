//! The which-key leader tree (NvChad-style). `<space>` in vim Normal
//! mode and `Ctrl+K` under the standard keymap open it at the root; each
//! key descends; a leaf runs its command. A binding is a leaf *or* a
//! group, never both, so the state is just the path typed so far.
//!
//! Every leaf names a `CommandId` — a typo is a compile error.

const std = @import("std");
const command = @import("../core/command.zig");
const CommandId = command.CommandId;

pub const Node = union(enum) {
    cmd: struct { id: CommandId, label: []const u8 },
    group: struct { label: []const u8, kids: []const Entry },

    pub fn label(n: *const Node) []const u8 {
        return switch (n.*) {
            .cmd => |c| c.label,
            .group => |g| g.label,
        };
    }
};

pub const Entry = struct { key: u8, node: Node };

fn cmd(key: u8, id: CommandId, label: []const u8) Entry {
    return .{ .key = key, .node = .{ .cmd = .{ .id = id, .label = label } } };
}

fn group(key: u8, label: []const u8, kids: []const Entry) Entry {
    return .{ .key = key, .node = .{ .group = .{ .label = label, .kids = kids } } };
}

pub const root: Node = .{ .group = .{ .label = "<leader>", .kids = &.{
    group('f', "+find", &.{
        cmd('f', .@"picker.files", "files"),
        cmd('b', .@"picker.buffers", "buffers"),
        cmd('g', .@"find.grep", "grep"),
        cmd('m', .@"lsp.format", "format buffer"),
        cmd('r', .@"picker.recent", "recent"),
    }),
    cmd('/', .@"editor.toggle_line_comment", "toggle comment"),
    cmd('n', .@"view.toggle_line_numbers", "line numbers"),
    cmd('e', .@"view.toggle_tree", "file tree"),
    cmd('x', .@"buffer.close", "close buffer"),
    cmd('w', .@"file.save", "save"),
    cmd('q', .@"app.quit", "quit"),
    group('c', "+nvchad", &.{
        cmd('h', .@"view.cheatsheet", "cheatsheet (all chords)"),
    }),
    group('b', "+buffer", &.{
        cmd('n', .@"buffer.next", "next"),
        cmd('p', .@"buffer.prev", "previous"),
        cmd('d', .@"buffer.close", "delete"),
        cmd('r', .@"buffer.reopen", "reopen closed"),
        cmd('b', .@"picker.buffers", "switch"),
    }),
    group('s', "+split", &.{
        cmd('v', .@"view.split_right", "split right"),
        cmd('s', .@"view.split_down", "split down"),
        cmd('h', .@"view.focus_left", "focus left"),
        cmd('j', .@"view.focus_down", "focus down"),
        cmd('k', .@"view.focus_up", "focus up"),
        cmd('l', .@"view.focus_right", "focus right"),
        cmd('w', .@"view.focus_next_split", "focus next"),
        cmd('c', .@"view.close_split", "close split"),
        cmd('o', .@"view.close_others", "close others"),
    }),
    group('l', "+lsp", &.{
        cmd('a', .@"lsp.code_action", "code actions"),
        cmd('c', .@"lsp.completion", "complete at cursor"),
        cmd('s', .@"lsp.symbols", "symbols in this file"),
        cmd('S', .@"lsp.workspace_symbols", "workspace symbols…"),
        cmd('o', .@"outline.show", "outline pane"),
        cmd('d', .@"lsp.goto_definition", "go to definition"),
        cmd('h', .@"lsp.hover", "hover docs"),
        cmd('r', .@"lsp.references", "find references"),
        cmd('R', .@"lsp.rename", "rename symbol"),
        cmd('e', .@"lsp.diagnostics", "diagnostics list"),
        cmd('n', .@"lsp.next_diagnostic", "next diagnostic"),
        cmd('p', .@"lsp.prev_diagnostic", "prev diagnostic"),
    }),
    group('g', "+git", &.{
        cmd('c', .@"git.commit", "commit"),
        cmd('d', .@"git.diff", "diff"),
        cmd('f', .@"git.diff_file", "diff file"),
        cmd('n', .@"git.jump_next_change", "next change"),
        cmd('p', .@"git.jump_prev_change", "prev change"),
    }),
    group('a', "+ai/term", &.{
        cmd('a', .@"ai.ask", "ask claude…"),
        cmd('t', .@"term.shell", "shell"),
    }),
    group('t', "+toggle", &.{
        cmd('w', .@"view.toggle_wrap", "wrap"),
        cmd('n', .@"view.toggle_line_numbers", "line numbers"),
        cmd('t', .@"view.toggle_tree", "file tree"),
    }),
} } };

pub const max_depth = 8;

/// The keys typed since the leader.
pub const State = struct {
    path: [max_depth]u8 = undefined,
    len: usize = 0,

    pub fn slice(s: *const State) []const u8 {
        return s.path[0..s.len];
    }
};

pub fn lookup(path: []const u8) ?*const Node {
    var node: *const Node = &root;
    for (path) |ch| {
        switch (node.*) {
            .group => |g| {
                node = for (g.kids) |*k| {
                    if (k.key == ch) break &k.node;
                } else return null;
            },
            .cmd => return null,
        }
    }
    return node;
}

/// The continuations at `path`; empty when it is not a group.
pub fn continuations(path: []const u8) []const Entry {
    const n = lookup(path) orelse return &.{};
    return switch (n.*) {
        .group => |g| g.kids,
        .cmd => &.{},
    };
}

test "leader tree: root groups, descend, leaves, dead ends" {
    try std.testing.expect(lookup("") != null);
    try std.testing.expectEqualStrings("+split", lookup("s").?.label());
    try std.testing.expectEqual(CommandId.@"view.split_right", lookup("sv").?.cmd.id);
    try std.testing.expect(lookup("zz") == null);
    try std.testing.expect(lookup("svx") == null);
    try std.testing.expect(continuations("s").len == 9);
    try std.testing.expect(continuations("sv").len == 0);
}
