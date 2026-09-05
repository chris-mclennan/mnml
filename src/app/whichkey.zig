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

pub const root: Node = .{
    .group = .{
        .label = "<leader>",
        .kids = &.{
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
                cmd('D', .@"git.diff", "diff worktree"),
                cmd('A', .@"git.diff_all", "diff all vs HEAD (multi-file)"),
                cmd('b', .@"git.blame_toggle", "blame toggle"),
                cmd('l', .@"git.graph", "commit graph"),
                cmd('s', .@"git.status_pane", "status / staging"),
                cmd('m', .@"git.ai_commit", "ai (Claude) commit message"),
                cmd('M', .@"git.ai_recompose", "ai rewrite HEAD msg"),
                cmd('x', .@"git.codex_commit", "codex commit message"),
                cmd('o', .@"git.checkout", "checkout branch"),
                cmd('w', .@"git.worktrees", "worktrees → shell"),
                cmd('S', .@"git.stash", "stash (with optional msg)"),
                cmd('P', .@"git.stash_pop", "stash pop"),
            }),
            // `a M` (mixr) is cut with the audio transport (docs/PARITY.md, Cuts).
            group('a', "+ai/term", &.{
                cmd('a', .@"ai.ask", "ask claude…"),
                cmd('b', .@"ai.toggle_backend", "toggle backend (cli ↔ api)"),
                cmd('d', .@"ai.dashboard", "agents dashboard"),
                cmd('e', .@"ai.explain", "explain selection"),
                cmd('f', .@"ai.fix", "fix bugs"),
                cmd('r', .@"ai.refactor", "refactor"),
                cmd('w', .@"ai.write_tests", "write tests"),
                cmd('m', .@"ai.session_view", "mirror session"),
                cmd('t', .@"term.shell", "shell"),
                cmd('c', .@"ai.claude_code", "claude code"),
                cmd('n', .@"ai.claude_code_new", "new claude session"),
                cmd('C', .@"ai.chat", "claude chat (context)"),
                cmd('x', .@"ai.codex", "codex"),
                cmd('X', .@"ai.codex_new", "new codex session"),
            }),
            group('t', "+toggle", &.{
                cmd('e', .@"view.toggle_tree", "explorer"),
                cmd('r', .@"view.toggle_right_panel", "right panel"),
                cmd(']', .@"view.right_panel_next_tab", "right panel: next"),
                cmd('[', .@"view.right_panel_prev_tab", "right panel: prev"),
                cmd('x', .@"view.right_panel_close_tab", "right panel: close tab"),
                cmd('k', .@"editor.toggle_keymap", "vim ⇄ standard"),
                cmd('t', .@"theme.pick", "theme…"),
                cmd('h', .@"view.toggle_hidden", "hidden files (focused)"),
                cmd('H', .@"view.toggle_hidden_all", "hidden files (all)"),
                cmd('w', .@"view.toggle_wrap", "wrap"),
                cmd('n', .@"view.toggle_line_numbers", "line numbers"),
            }),
            group('h', "+http", &.{
                cmd('s', .@"http.send", "send request"),
                cmd('y', .@"http.copy_curl", "copy as curl"),
                cmd('d', .@"http.ai_debug", "ask Claude (debug)"),
                cmd(']', .@"http.next_block", "next ### block"),
                cmd('[', .@"http.prev_block", "previous ### block"),
            }),
            group('T', "+test", &.{
                cmd('a', .@"test.run_all", "run all"),
                cmd('f', .@"test.run_file", "run this file"),
                cmd('t', .@"test.run_at_cursor", "run test at cursor"),
                cmd('l', .@"test.rerun_failed", "re-run last-failed"),
                cmd('h', .@"test.heal", "heal failing test (Claude)"),
                cmd('w', .@"flaky.show", "flaky/wobbly dashboard"),
            }),
            // `L c r` (cargo run) is not an id in this build — `cargo.*` runs
            // the checks; `go.run` / `npm.run` cover the run verbs.
            group('L', "+lang/run", &.{
                group('c', "+cargo", &.{
                    cmd('t', .@"cargo.test", "cargo test"),
                    cmd('b', .@"cargo.build", "cargo build"),
                    cmd('c', .@"cargo.check", "cargo check"),
                    cmd('l', .@"cargo.clippy", "cargo clippy"),
                    cmd('f', .@"cargo.fmt", "cargo fmt"),
                }),
                group('n', "+npm", &.{
                    cmd('t', .@"npm.test", "npm test"),
                    cmd('b', .@"npm.build", "npm run build"),
                    cmd('r', .@"npm.run", "npm run dev"),
                    cmd('s', .@"npm.start", "npm start"),
                    cmd('i', .@"npm.install", "npm install"),
                    cmd('l', .@"npm.lint", "npm run lint"),
                    cmd('x', .@"npm.run_script", "run an npm script (prompt)"),
                }),
                group('p', "+pytest", &.{
                    cmd('t', .@"pytest.run", "pytest"),
                    cmd('l', .@"pytest.failed", "pytest --lf"),
                }),
                group('g', "+go", &.{
                    cmd('t', .@"go.test", "go test ./..."),
                    cmd('b', .@"go.build", "go build"),
                    cmd('r', .@"go.run", "go run ."),
                    cmd('v', .@"go.vet", "go vet ./..."),
                    cmd('p', .@"go.run_path", "go run <path> (prompt)"),
                }),
            }),
            // Rust's `P` (+pr) group is not here: `pr.picker` / `pr.refresh`
            // are cut with the Rust integration binaries (docs/PARITY.md, Cuts).
            // `i p` (`integrations.icon_picker`) waits on the icon-rail track.
            group('i', "+integrations", &.{
                cmd('d', .@"integrations.show_details", "detail pane (description / buttons / links)"),
                cmd('h', .@"tools.htop", "htop — interactive process viewer"),
                cmd('I', .@"tools.iftop", "iftop — interactive bandwidth monitor"),
                cmd('r', .@"tools.btop", "btop — resource monitor"),
                cmd('E', .@"integrations.toggle_enabled", "enable/disable a chip"),
            }),
            group('I', "+insert", &.{
                cmd('s', .@"snippet.pick", "snippet…"),
                cmd('x', .@"snippet.expand", "expand snippet at cursor"),
            }),
            group('H', "+harpoon", &.{
                cmd('a', .@"harpoon.add", "pin active file"),
                cmd('m', .@"harpoon.menu", "menu / picker"),
            }),
            cmd('1', .@"harpoon.goto_1", "harpoon 1"),
            cmd('2', .@"harpoon.goto_2", "harpoon 2"),
            cmd('3', .@"harpoon.goto_3", "harpoon 3"),
            cmd('4', .@"harpoon.goto_4", "harpoon 4"),
            cmd('5', .@"harpoon.goto_5", "harpoon 5"),
            cmd('6', .@"harpoon.goto_6", "harpoon 6"),
            cmd('7', .@"harpoon.goto_7", "harpoon 7"),
            cmd('8', .@"harpoon.goto_8", "harpoon 8"),
            cmd('9', .@"harpoon.goto_9", "harpoon 9"),
            cmd('?', .@"view.cheatsheet", "cheatsheet (all chords)"),
            cmd('B', .@"browser.open", "open browser (Chrome/CDP)"),
            cmd('m', .@"markdown.preview", "markdown preview"),
            cmd('p', .palette, "command palette"),
            cmd('o', .@"task.run", "run task…"),
        },
    },
};

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

test "leader tree: the NvChad groups h T L P i I H, the digits, the root leaves ? B m p o, tr, iE and the t leaves" {
    const t = std.testing;
    for ([_][]const u8{ "h", "T", "L", "i", "I", "H" }) |g| try t.expect(lookup(g).?.* == .group);
    try t.expectEqualStrings("+cargo", lookup("Lc").?.label());
    try t.expectEqual(CommandId.@"cargo.test", lookup("Lct").?.cmd.id);
    try t.expectEqual(CommandId.@"go.run", lookup("Lgr").?.cmd.id);
    try t.expectEqual(CommandId.@"http.send", lookup("hs").?.cmd.id);
    try t.expectEqual(CommandId.@"test.run_at_cursor", lookup("Tt").?.cmd.id);
    try t.expectEqual(CommandId.@"integrations.toggle_enabled", lookup("iE").?.cmd.id);
    try t.expectEqual(CommandId.@"snippet.pick", lookup("Is").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.add", lookup("Ha").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.goto_1", lookup("1").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.goto_9", lookup("9").?.cmd.id);
    try t.expectEqual(CommandId.@"view.cheatsheet", lookup("?").?.cmd.id);
    try t.expectEqual(CommandId.@"browser.open", lookup("B").?.cmd.id);
    try t.expectEqual(CommandId.@"markdown.preview", lookup("m").?.cmd.id);
    try t.expectEqual(CommandId.palette, lookup("p").?.cmd.id);
    try t.expectEqual(CommandId.@"task.run", lookup("o").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_right_panel", lookup("tr").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_hidden", lookup("th").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_hidden_all", lookup("tH").?.cmd.id);
    try t.expectEqual(CommandId.@"editor.toggle_keymap", lookup("tk").?.cmd.id);
    try t.expectEqual(CommandId.@"theme.pick", lookup("tt").?.cmd.id);
    // The cut groups and leaves are not offered.
    try t.expect(lookup("P") == null);
    try t.expect(lookup("aM") == null);
    try t.expect(lookup("ip") == null);
    try t.expect(lookup("Lcr") == null);
    // Every key at the root is unique (a group's kids too) — the trie
    // would silently shadow the second otherwise.
    try expectUniqueKeys(&root);
}

fn expectUniqueKeys(n: *const Node) !void {
    switch (n.*) {
        .cmd => {},
        .group => |g| {
            for (g.kids, 0..) |a, i| {
                for (g.kids[i + 1 ..]) |b| if (a.key == b.key) {
                    std.debug.print("duplicate which-key '{c}' under {s}\n", .{ a.key, g.label });
                    return error.DuplicateKey;
                };
                try expectUniqueKeys(&a.node);
            }
        },
    }
}
