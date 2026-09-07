//! `git.*` runners (D5). Every one resolves the active repo through
//! `git.requireRepo` — outside a repository that is the one place that
//! says so — then submits a job and returns; the result lands through
//! `git.handle` on a later tick. Nothing here waits on git.
//!
//! Three commands keep the Rust wording the gate asserts instead of the
//! generic reason: `recent_branches` says `no branches (not a git
//! repo?)`, and `merge` / `rebase` say `detached HEAD — checkout a
//! branch first` when there is no branch to merge into.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const git = @import("git.zig");
const client = @import("../git/client.zig");
const git_palette = @import("git_palette.zig");

pub const table = .{
    .@"git.status_pane" = &statusPane,
    .@"git.refresh" = &refresh,
    .@"git.diff_file" = &diffFile,
    .@"git.diff" = &diffWorktree,
    .@"git.diff_all" = &diffAll,
    .@"git.diff_orig" = &diffOrig,
    .@"git.diff_toggle_view" = &diffToggleView,
    .@"git.diff_filter" = &diffFilter,
    .@"git.diff_next_file" = &diffNextFile,
    .@"git.diff_prev_file" = &diffPrevFile,
    .@"git.peek_change" = &peekChange,
    .@"git.jump_next_change" = &jumpNextChange,
    .@"git.jump_prev_change" = &jumpPrevChange,
    .@"git.blame_toggle" = &blameToggle,
    .@"git.stage" = &stage,
    .@"git.unstage" = &unstage,
    .@"git.stage_all" = &stageAll,
    .@"git.unstage_all" = &unstageAll,
    .@"git.discard" = &discard,
    .@"git.open_file" = &openFile,
    .@"git.commit" = &commit,
    .@"git.ai_commit" = &aiCommit,
    .@"git.codex_commit" = &codexCommit,
    .@"git.ai_recompose" = &aiRecompose,
    .@"git.branch_rail_toggle" = &branchRailToggle,
    .@"git.checkout" = &checkout,
    .@"git.recent_branches" = &recentBranches,
    .@"git.new_branch" = &newBranch,
    .@"git.delete_branch" = &deleteBranch,
    .@"git.merge" = &merge,
    .@"git.rebase" = &rebase,
    .@"git.branch_menu" = &branchMenu,
    .@"git.copy_current_branch" = &copyCurrentBranch,
    .@"git.copy_head_sha" = &copyHeadSha,
    .@"git.fetch" = &fetch,
    .@"git.pull" = &pull,
    .@"git.push" = &push,
    .@"git.push_tags" = &pushTags,
    .@"git.stash" = &stash,
    .@"git.stash_pop" = &stashPop,
    .@"git.stash_list" = &stashList,
    .@"git.stash_drop" = &stashDrop,
    .@"git.tag" = &tag,
    .@"git.tag_delete" = &tagDelete,
    .@"git.reflog" = &reflog,
    .@"git.undo" = &undo,
    .@"git.redo" = &redo,
    .@"git.graph" = &graph,
    .@"git.graph_filter_branch" = &graphFilterBranch,
    .@"git.graph_filter_clear" = &graphFilterClear,
    .@"git.graph_filter_date" = &graphFilterDate,
    .@"git.graph_filter_author" = &graphFilterAuthor,
    .@"git.graph_filter_subject" = &graphFilterSubject,
    .@"git.graph_filter_reset_all" = &graphFilterResetAll,
    .@"git.cherry_pick" = &cherryPick,
    .@"git.revert" = &revert,
    .@"git.file_history" = &fileHistory,
    .@"git.browse" = &browseLine,
    .@"git.browse_line" = &browseLine,
    .@"git.browse_file" = &browseFile,
    .@"git.browse_commit" = &browseCommit,
    .@"git.graph_sort" = &graphSort,
    .@"git.graph_jump_hash" = &graphJumpHash,
    .@"git.graph_detail" = &graphDetail,
    .@"git.switch_repo" = &switchRepo,
    .@"git.next_repo" = &nextRepo,
    .@"git.prev_repo" = &prevRepo,
    .@"git.refresh_repos" = &refreshRepos,
    .@"git.reopen_repo" = &reopenRepo,
    .@"git.worktree_add" = &worktreeAdd,
    .@"git.worktree_list" = &worktreeList,
    .@"git.worktree_remove" = &worktreeRemove,
    .@"git.worktrees" = &worktrees,
};

fn arena(app: *App) std.mem.Allocator {
    return app.frame.allocator();
}

/// The active editor's path, repo-relative, or the reason there is none.
fn activeRel(app: *App, repo: *client.Repo) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(arena(app), "git: not an editor", .{});
    const p = e.buf.doc.path orelse return app.diag.fail(arena(app), "git: the buffer has no file", .{});
    return git.relToRepo(repo, p);
}

// ─── status / diff ──────────────────────────────────────────────────────

fn statusPane(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    _ = try git.openStatusPane(app, repo);
    try git.requestStatus(app);
}

fn refresh(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    app.git.status_pending = false;
    try git.requestStatus(app);
}

/// The rail / status pane's selected row when one has focus, else the
/// active editor's file.
fn diffFile(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (try selectedRow(app)) |row| return git.actOnRow(app, row, .open);
    const rel = try activeRel(app, repo);
    _ = try git.openDiff(app, repo, .file, rel, null, null);
}

fn diffWorktree(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    _ = try git.openDiff(app, repo, .worktree, null, null, null);
}

fn diffAll(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    _ = try git.openDiff(app, repo, .head, null, null, null);
}

/// vim `:DiffOrig`: the buffer against the file on disk.
fn diffOrig(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const e = app.activeEditor() orelse return app.diag.fail(arena(app), "git: not an editor", .{});
    const p = e.buf.doc.path orelse return app.diag.fail(arena(app), "git: the buffer has no file", .{});
    _ = try git.openDiff(app, repo, .orig, git.relToRepo(repo, p), null, e.buf.editor.bytes());
}

/// Hunk → Inline → Split → Hunk on the active diff pane.
fn diffToggleView(app: *App) CommandError!void {
    const dp = git.activeDiff(app) orelse return app.diag.fail(arena(app), "no diff pane is active", .{});
    try git.setDiffMode(app, dp, dp.mode.next());
}

/// Start typing a `/` filter on the active diff pane.
fn diffFilter(app: *App) CommandError!void {
    const dp = git.activeDiff(app) orelse return app.diag.fail(arena(app), "no diff pane is active", .{});
    dp.filter_mode = true;
    dp.filter.clearRetainingCapacity();
    try git.refilterDiff(app, dp);
    app.needs_render = true;
}

fn diffNextFile(app: *App) CommandError!void {
    const dp = git.activeDiff(app) orelse return app.diag.fail(arena(app), "no diff pane is active", .{});
    git.moveFile(dp, true);
    app.needs_render = true;
}

fn diffPrevFile(app: *App) CommandError!void {
    const dp = git.activeDiff(app) orelse return app.diag.fail(arena(app), "no diff pane is active", .{});
    git.moveFile(dp, false);
    app.needs_render = true;
}

/// The file's diff with the cursor on the hunk that holds the editor's
/// current line (or the first hunk after it).
fn peekChange(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const e = app.activeEditor() orelse return app.diag.fail(arena(app), "git: not an editor", .{});
    const line: u32 = @intCast(e.buf.editor.currentLine() + 1);
    const rel = try activeRel(app, repo);
    const id = try git.openDiff(app, repo, .file, rel, null, null);
    const pane = app.panes.get(id) orelse return;
    const dp = &pane.diff;
    // The rows may already be here (a refresh of an open pane); the
    // split view walks its own rows.
    if (dp.mode == .split) {
        for (dp.split_rows, 0..) |row, i| if (row == .pair) {
            const h = dp.files[row.pair.file].hunks[row.pair.hunk];
            if (h.new_start + h.new_count >= line) {
                dp.cursor = i;
                break;
            }
        };
        return;
    }
    for (dp.rows, 0..) |row, i| if (row == .hunk) {
        const h = dp.files[row.hunk.file].hunks[row.hunk.hunk];
        if (h.new_start + h.new_count >= line) {
            dp.cursor = i;
            break;
        }
    };
}

/// `]c` / `[c` in the editor: the next / previous gutter mark.
fn jumpChange(app: *App, forward: bool) CommandError!void {
    const e = app.activeEditor() orelse return app.diag.fail(arena(app), "git: not an editor", .{});
    const p = e.buf.doc.path orelse return app.diag.fail(arena(app), "git: the buffer has no file", .{});
    _ = try git.requireRepo(app);
    const marks = git.marksFor(app, p);
    if (marks.len == 0) return app.diag.fail(arena(app), "no changes in this file (vs HEAD)", .{});
    const cur: u32 = @intCast(e.buf.editor.currentLine());
    var target: ?u32 = null;
    if (forward) {
        for (marks) |m| if (m.line > cur) {
            target = m.line;
            break;
        };
    } else {
        var i = marks.len;
        while (i > 0) {
            i -= 1;
            if (marks[i].line < cur) {
                target = marks[i].line;
                break;
            }
        }
    }
    const line = target orelse return app.diag.fail(arena(app), "no {s} change", .{if (forward) "next" else "previous"});
    e.buf.editor.anchor = null;
    e.buf.editor.placeCursor(@min(line, e.buf.editor.lineCount() -| 1), 0);
    app.needs_render = true;
}

fn jumpNextChange(app: *App) CommandError!void {
    return jumpChange(app, true);
}

fn jumpPrevChange(app: *App) CommandError!void {
    return jumpChange(app, false);
}

// ─── blame ──────────────────────────────────────────────────────────────

fn blameToggle(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const e = app.panes.editor(id) orelse return app.diag.fail(arena(app), "blame: not an editor", .{});
    if (app.git.blames.fetchRemove(id)) |old| {
        var b = old.value;
        b.arena.deinit();
        app.toast("blame: off", .{});
        app.needs_render = true;
        return;
    }
    const p = e.buf.doc.path orelse return app.diag.fail(arena(app), "blame needs a saved file", .{});
    try git.requestBlame(app, id, p);
    app.toast("computing blame…", .{});
}

// ─── staging ────────────────────────────────────────────────────────────

/// The status pane's cursor row when one has focus.
fn selectedRow(app: *App) CommandError!?git.Row {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .git_status => |*s| try git.statusPaneRow(app, s),
        else => null,
    };
}

fn rowOrActiveFile(app: *App, repo: *client.Repo) CommandError!git.Row {
    if (try selectedRow(app)) |row| return row;
    const rel = try activeRel(app, repo);
    return .{ .path = rel, .letter = 'M', .staged = false };
}

fn stage(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.actOnRow(app, try rowOrActiveFile(app, repo), .stage);
}

fn unstage(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.actOnRow(app, try rowOrActiveFile(app, repo), .unstage);
}

fn discard(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.actOnRow(app, try rowOrActiveFile(app, repo), .discard);
}

fn openFile(app: *App) CommandError!void {
    const row = (try selectedRow(app)) orelse return app.diag.fail(arena(app), "git: nothing selected", .{});
    try git.openRowFile(app, row);
}

fn stageAll(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .stage_all);
}

fn unstageAll(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .unstage_all);
}

fn commit(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    git.openPrompt(app, .commit, "Commit message");
}

// ─── AI commit messages ─────────────────────────────────────────────────

/// Claude writes the message from the staged diff; the commit prompt
/// opens with it.
fn aiCommit(app: *App) CommandError!void {
    try git.askAi(app, .staged, .claude);
}

fn codexCommit(app: *App) CommandError!void {
    try git.askAi(app, .staged, .codex);
}

/// With the commit prompt open: its message is recomposed from the
/// staged diff. Otherwise HEAD's message is rewritten (`--amend`).
fn aiRecompose(app: *App) CommandError!void {
    const on_commit_prompt = app.overlay == .prompt and app.git.prompt == .commit;
    try git.askAi(app, if (on_commit_prompt) .staged else .head, .claude);
}

/// In and out of git mode (the Rust rail's toggle).
fn branchRailToggle(app: *App) CommandError!void {
    try git_palette.toggle(app);
}

// ─── branches ───────────────────────────────────────────────────────────

fn checkout(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askBranches(app, repo, .checkout);
}

fn recentBranches(app: *App) CommandError!void {
    const repo = git.requireRepo(app) catch {
        app.diag.clear();
        return app.diag.fail(arena(app), "no branches (not a git repo?)", .{});
    };
    try git.askBranches(app, repo, .recent);
}

fn newBranch(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    git.openPrompt(app, .new_branch, "New branch");
}

fn deleteBranch(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askBranches(app, repo, .delete_branch);
}

/// Merging into nothing is the Rust wording the gate reads; the branch
/// is what the last status reported.
fn onBranchOrDetached(app: *App, what: []const u8) CommandError!void {
    const st = &app.git;
    if (st.status) |s| if (s.branch != null) return;
    return app.diag.fail(arena(app), "{s}: detached HEAD — checkout a branch first", .{what});
}

fn merge(app: *App) CommandError!void {
    const repo = git.requireRepo(app) catch {
        app.diag.clear();
        return onBranchOrDetached(app, "merge");
    };
    try onBranchOrDetached(app, "merge");
    try git.askBranches(app, repo, .merge);
}

fn rebase(app: *App) CommandError!void {
    const repo = git.requireRepo(app) catch {
        app.diag.clear();
        return onBranchOrDetached(app, "rebase");
    };
    try onBranchOrDetached(app, "rebase");
    try git.askBranches(app, repo, .rebase);
}

fn branchMenu(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Checkout…", .action = .{ .command = .@"git.checkout" } },
        .{ .label = "Recent branches…", .action = .{ .command = .@"git.recent_branches" } },
        .{ .label = "New branch…", .action = .{ .command = .@"git.new_branch" } },
        .{ .label = "Delete branch…", .action = .{ .command = .@"git.delete_branch" } },
        .{ .label = "Fetch", .action = .{ .command = .@"git.fetch" }, .separator_before = true },
        .{ .label = "Pull (ff-only)", .action = .{ .command = .@"git.pull" } },
        .{ .label = "Push", .action = .{ .command = .@"git.push" } },
        .{ .label = "Commit graph", .action = .{ .command = .@"git.graph" }, .separator_before = true },
        .{ .label = "Copy branch name", .action = .{ .command = .@"git.copy_current_branch" } },
    });
    errdefer app.gpa.free(items);
    const x: u16 = 2;
    const y: u16 = @intCast(app.screen.height -| 3);
    try app.openMenu("Branch", items, x, y);
}

fn copyCurrentBranch(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    const b = app.git.branchLabel() orelse return app.diag.fail(arena(app), "git: detached HEAD or not a repo", .{});
    try app.clipboard.setYank(b, false);
    app.toast("copied {s}", .{b});
}

fn copyHeadSha(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submit(app, repo, .head_sha);
}

// ─── sync ───────────────────────────────────────────────────────────────

fn fetch(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    app.toast("fetching…", .{});
    try git.submitOp(app, repo, .fetch);
}

fn pull(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    app.toast("pulling…", .{});
    try git.submitOp(app, repo, .pull);
}

fn push(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    app.toast("pushing…", .{});
    try git.submitOp(app, repo, .push);
}

fn pushTags(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    app.toast("pushing tags…", .{});
    try git.submitOp(app, repo, .push_tags);
}

// ─── stash / tags / reflog ──────────────────────────────────────────────

fn stash(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    git.openPrompt(app, .stash, "Stash message (optional)");
}

fn stashPop(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .{ .stash_pop = null });
}

fn stashList(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askList(app, repo, .stashes, .stash_apply);
}

fn stashDrop(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askList(app, repo, .stashes, .stash_drop);
}

fn tag(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    git.openPrompt(app, .tag, "Tag name (annotated, on HEAD)");
}

fn tagDelete(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askList(app, repo, .tags, .tag_delete);
}

fn reflog(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askList(app, repo, .reflog, .reflog);
}

fn undo(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .undo);
}

fn redo(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .redo);
}

// ─── the graph ──────────────────────────────────────────────────────────

/// Git mode: the palette in the sidebar, one graph tab per repo.
fn graph(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git_palette.enter(app);
}

fn reopenRepo(app: *App) CommandError!void {
    try git_palette.openReopenPicker(app);
}

fn requireGraph(app: *App) CommandError!*git.GraphPane {
    return git.activeGraph(app) orelse app.diag.fail(arena(app), "graph: open the commit graph first (git.graph)", .{});
}

fn graphFilterBranch(app: *App) CommandError!void {
    _ = try requireGraph(app);
    const repo = try git.requireRepo(app);
    try git.askBranches(app, repo, .graph_branch);
}

fn graphFilterClear(app: *App) CommandError!void {
    const g = try requireGraph(app);
    if (g.filter.branch) |b| app.gpa.free(b);
    g.filter.branch = null;
    try git.refreshGraph(app, g);
}

fn graphFilterDate(app: *App) CommandError!void {
    _ = try requireGraph(app);
    git.openPrompt(app, .graph_date, "Graph: date range (since..until, e.g. 2 weeks ago..)");
}

fn graphFilterAuthor(app: *App) CommandError!void {
    _ = try requireGraph(app);
    git.openPrompt(app, .graph_author, "Graph: author (empty clears)");
}

fn graphFilterSubject(app: *App) CommandError!void {
    _ = try requireGraph(app);
    git.openPrompt(app, .graph_subject, "Graph: subject grep (empty clears)");
}

fn graphFilterResetAll(app: *App) CommandError!void {
    const g = try requireGraph(app);
    g.filter.deinit(app.gpa);
    g.filter = .{};
    try git.refreshGraph(app, g);
}

fn selectedCommit(app: *App) CommandError![]const u8 {
    const g = try requireGraph(app);
    const c = g.selected() orelse return app.diag.fail(arena(app), "graph: no commit selected", .{});
    return c.hash;
}

fn cherryPick(app: *App) CommandError!void {
    const sha = try selectedCommit(app);
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .{ .cherry_pick = try app.gpa.dupe(u8, sha) });
}

fn revert(app: *App) CommandError!void {
    const sha = try selectedCommit(app);
    const repo = try git.requireRepo(app);
    try git.submitOp(app, repo, .{ .revert = try app.gpa.dupe(u8, sha) });
}

fn graphSort(app: *App) CommandError!void {
    const g = try requireGraph(app);
    try git.setSort(app, g, .{ .col = g.sort.col.next(), .asc = false });
}

fn graphJumpHash(app: *App) CommandError!void {
    _ = try requireGraph(app);
    git.openPrompt(app, .graph_hash, "Jump to commit (hash prefix)");
}

fn graphDetail(app: *App) CommandError!void {
    const g = try requireGraph(app);
    git.syncWip(app, g);
    g.detail_focus = true;
    try git.openDetail(app, g);
}

fn fileHistory(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const rel = try activeRel(app, repo);
    app.git.awaiting = .file_history;
    try git.submit(app, repo, .{ .log = .{ .n = 200, .filter = .{ .path = try app.gpa.dupe(u8, rel) } } });
}

// ─── browse on the remote ───────────────────────────────────────────────

fn browseLine(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const e = app.activeEditor() orelse return app.diag.fail(arena(app), "browse: not an editor", .{});
    const rel = try activeRel(app, repo);
    const line: u32 = @intCast(e.buf.editor.currentLine() + 1);
    try git.submit(app, repo, .{ .browse = .{ .kind = .line, .path = try app.gpa.dupe(u8, rel), .line = line } });
}

fn browseFile(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const rel = try activeRel(app, repo);
    try git.submit(app, repo, .{ .browse = .{ .kind = .file, .path = try app.gpa.dupe(u8, rel) } });
}

/// The graph's selected commit when a graph pane is active, a diff
/// pane's commit, else HEAD.
fn browseCommit(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    var rev: ?[]u8 = null;
    if (git.activeGraph(app)) |g| {
        if (g.selected()) |c| rev = try app.gpa.dupe(u8, c.hash);
    } else if (git.activeDiff(app)) |dp| {
        if (dp.scope == .commit) if (dp.rev) |r| {
            rev = try app.gpa.dupe(u8, r);
        };
    }
    errdefer if (rev) |r| app.gpa.free(r);
    try git.submit(app, repo, .{ .browse = .{ .kind = .commit, .rev = rev } });
}

// ─── repos ──────────────────────────────────────────────────────────────

fn switchRepo(app: *App) CommandError!void {
    try git.openRepoPicker(app);
}

fn cycleRepo(app: *App, forward: bool) CommandError!void {
    const st = &app.git;
    if (!st.discovered) try git.discover(app);
    const n = st.repos.items.len;
    if (n == 0) return app.diag.fail(arena(app), "not a git repository", .{});
    if (n == 1) return app.diag.fail(arena(app), "only one repo under {s}", .{app.workspace});
    const cur = st.active orelse 0;
    const next = if (forward) (cur + 1) % n else (cur + n - 1) % n;
    try git.switchTo(app, next);
}

fn nextRepo(app: *App) CommandError!void {
    return cycleRepo(app, true);
}

fn prevRepo(app: *App) CommandError!void {
    return cycleRepo(app, false);
}

fn refreshRepos(app: *App) CommandError!void {
    try git.discover(app);
    const n = app.git.repos.items.len;
    app.toast("{d} repo{s} under {s}", .{ n, if (n == 1) "" else "s", app.relPath(app.workspace) });
    if (n > 0) try git.requestStatus(app);
}

// ─── worktrees ──────────────────────────────────────────────────────────

fn worktreeAdd(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    git.openPrompt(app, .worktree_add, "Worktree: <path> [new-branch]");
    app.overlay.prompt.state.placeholder = "path [new-branch] — tab completes the path";
}

fn worktreeList(app: *App) CommandError!void {
    const repo = git.requireRepo(app) catch {
        app.diag.clear();
        return app.diag.fail(arena(app), "no worktrees (not a git repo?)", .{});
    };
    try git.askList(app, repo, .worktrees, .worktree_open);
}

fn worktreeRemove(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try git.askList(app, repo, .worktrees, .worktree_remove);
}

fn worktrees(app: *App) CommandError!void {
    const repo = git.requireRepo(app) catch {
        app.diag.clear();
        return app.diag.fail(arena(app), "no worktrees (not a git repo?)", .{});
    };
    try git.askList(app, repo, .worktrees, .worktree_shell);
}
