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
const line_blame = @import("line_blame.zig");
const client = @import("../git/client.zig");
const parse = @import("../git/parse.zig");
const git_palette = @import("git_palette.zig");
const conflicts = @import("conflicts.zig");

pub const table = .{
    .@"view.git_commit_focus" = &commitFocus,
    .@"git.status_pane" = &statusPane,
    .@"git.refresh" = &refresh,
    .@"git.diff_file" = &diffFile,
    .@"git.diff" = &diffWorktree,
    .@"git.diff_all" = &diffAll,
    .@"git.diff_orig" = &diffOrig,
    .@"git.diff_toggle_view" = &diffToggleView,
    .@"git.diff_filter" = &diffFilter,
    .@"git.diff_select" = &diffSelect,
    .@"git.diff_stage_lines" = &diffStageLines,
    .@"git.diff_unstage_lines" = &diffUnstageLines,
    .@"git.diff_discard_lines" = &diffDiscardLines,
    .@"git.diff_stash_lines" = &diffStashLines,
    .@"git.diff_commit_lines" = &diffCommitLines,
    .@"git.diff_open_line" = &diffOpenLine,
    .@"git.conflict_next" = &conflictNext,
    .@"git.conflict_prev" = &conflictPrev,
    .@"git.conflict_ours" = &conflictOurs,
    .@"git.conflict_theirs" = &conflictTheirs,
    .@"git.conflict_both" = &conflictBoth,
    .@"git.conflict_split" = &conflictSplit,
    .@"git.conflict_ai" = &conflictAi,
    .@"git.diff_next_file" = &diffNextFile,
    .@"git.diff_prev_file" = &diffPrevFile,
    .@"git.peek_change" = &peekChange,
    .@"git.jump_next_change" = &jumpNextChange,
    .@"git.jump_prev_change" = &jumpPrevChange,
    .@"git.blame_toggle" = &blameToggle,
    .@"git.toggle_line_blame" = &line_blame.toggle,
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
    .@"git.repo_prev" = &repoPrev,
    .@"git.repo_next" = &repoNext,
    .@"git.palette_all" = &paletteAll,
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
    .@"git.op_continue" = &opContinue,
    .@"git.op_abort" = &opAbort,
    .@"git.op_skip" = &opSkip,
    .@"git.rebase_plan" = &rebasePlan,
    .@"git.rebase_interactive_onto" = &rebaseInteractiveOnto,
    .@"git.explain_branch" = &explainBranch,
    .@"git.push_start_pr" = &pushStartPr,
    .@"git.worktree_open_tab" = &worktreeOpenTab,
    .@"git.worktree_remove_delete_branch" = &worktreeRemoveDeleteBranch,
    .@"git.worktree_lock" = &worktreeLock,
    .@"git.worktree_unlock" = &worktreeUnlock,
    .@"git.fixup" = &fixup,
    .@"git.squash" = &squash,
    .@"git.drop" = &drop,
    .@"git.reword" = &reword,
    .@"git.select_branch" = &selectBranch,
    .@"git.amend" = &amend,
    .@"git.amend_to" = &amendTo,
    .@"git.reset_soft" = &resetSoft,
    .@"git.reset_mixed" = &resetMixed,
    .@"git.reset_hard" = &resetHard,
    .@"git.compare_base" = &compareBase,
    .@"git.diff_against_base" = &diffAgainstBase,
    .@"git.graph_diff" = &graphDiff,
    .@"git.diff_against_current" = &diffAgainstCurrent,
    .@"git.branch_rename" = &branchRename,
    .@"git.fast_forward" = &fastForward,
    .@"git.set_upstream" = &setUpstream,
    .@"git.checkout_force" = &checkoutForce,
    .@"git.delete_remote_branch" = &deleteRemoteBranch,
    .@"git.new_branch_from" = &newBranchFrom,
    .@"git.worktree_add_from" = &worktreeAddFrom,
    .@"git.push_force" = &pushForce,
    .@"git.stash_staged" = &stashStaged,
    .@"git.stash_file" = &stashFile,
    .@"git.stash_keep_index" = &stashKeepIndex,
    .@"git.stash_show" = &stashShow,
    .@"git.stash_show_diff" = &stashShowDiff,
    .@"git.stash_branch" = &stashBranch,
    .@"git.stash_rename" = &stashRename,
    .@"git.command_log" = &commandLog,
    .@"git.command_log_rerun" = &commandLogRerun,
    .@"git.graph_detail_open" = &graphDetailOpen,
    .@"git.graph_file_at_rev" = &graphFileAtRev,
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

/// `view.git_commit_focus`: the commit textarea lives on the graph
/// pane's working-tree row, so that pane opens (the status refresh with
/// it) and the box takes the keys, as a click on it does.
fn commitFocus(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    const id = try git_palette.showActiveGraph(app);
    try git.requestStatus(app);
    const p = app.panes.get(id) orelse return error.NoActivePane;
    switch (p.*) {
        .git_graph => |*g| {
            // The box takes the keys only with the WIP row selected:
            // the cursor goes to the top row, which is that row on a
            // dirty tree.
            g.cursor = 0;
            g.wip_focused = true;
            g.detail_focus = false;
        },
        else => return error.NoActivePane,
    }
    app.focus = .{ .pane = id };
    app.needs_render = true;
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
    _ = try git.openDiffPlaced(app, repo, .file, rel, null, null, .beside);
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

fn requireDiff(app: *App) CommandError!*git.DiffPane {
    return git.activeDiff(app) orelse app.diag.fail(arena(app), "no diff pane is active", .{});
}

fn diffSelect(app: *App) CommandError!void {
    git.toggleDiffSelect(try requireDiff(app));
}

fn diffStageLines(app: *App) CommandError!void {
    try git.applyHunk(app, try requireDiff(app), .stage);
}

fn diffUnstageLines(app: *App) CommandError!void {
    try git.applyHunk(app, try requireDiff(app), .unstage);
}

fn diffDiscardLines(app: *App) CommandError!void {
    try git.askDiscard(app, app.active.?, try requireDiff(app));
}

fn diffStashLines(app: *App) CommandError!void {
    try git.stashLines(app, try requireDiff(app));
}

fn diffCommitLines(app: *App) CommandError!void {
    try git.commitLinesPrompt(app, try requireDiff(app));
}

fn conflictNext(app: *App) CommandError!void {
    try conflicts.jump(app, true);
}

fn conflictPrev(app: *App) CommandError!void {
    try conflicts.jump(app, false);
}

fn conflictOurs(app: *App) CommandError!void {
    try conflicts.pick(app, .ours);
}

fn conflictTheirs(app: *App) CommandError!void {
    try conflicts.pick(app, .theirs);
}

fn conflictBoth(app: *App) CommandError!void {
    try conflicts.pick(app, .both);
}

fn conflictSplit(app: *App) CommandError!void {
    try conflicts.openSplit(app, try app.requireEditor());
}

fn conflictAi(app: *App) CommandError!void {
    try conflicts.pick(app, .ai);
}

fn diffOpenLine(app: *App) CommandError!void {
    try git.openDiffLine(app, try requireDiff(app));
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

/// `]c` / `[c` in the editor: `git.jumpChange`.
fn jumpChange(app: *App, forward: bool) CommandError!void {
    const id = app.active orelse return app.diag.fail(arena(app), "git: not an editor", .{});
    return git.jumpChange(app, id, forward);
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

/// The status pane's cursor row when one has focus; the graph's
/// working-tree file row when its detail column has the keys.
fn selectedRow(app: *App) CommandError!?git.Row {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .git_status => |*s| try git.statusPaneRow(app, s),
        .git_graph => try git.wipDetailRow(app),
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

/// `git.commit`. A graph whose commit box holds a message commits it
/// (Rust `commit_from_active_wip_textarea_or_prompt`). Otherwise, in
/// git mode, the box IS the commit UI: the active repo's graph opens
/// with the box focused on the WIP row, from an editor tab or a diff
/// as much as from the graph — the keys are the box's (Ctrl+Enter
/// commits, Esc leaves it), on its hint row. Outside git mode the modal
/// prompt, titled with the staged count as Rust titles it.
fn commit(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    if (git.activeGraph(app)) |g| if (g.wipSelected() and std.mem.trim(u8, g.wip_text.items, " \t\r\n").len > 0) return git.commitFromTextarea(app, g);
    if (app.git_palette.active and git.graphPaintsBox(app)) return commitFocus(app);
    git.openPrompt(app, .commit, git.commitPromptTitle(app));
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

fn repoPrev(app: *App) CommandError!void {
    try git_palette.stepRepo(app, false);
}

fn repoNext(app: *App) CommandError!void {
    try git_palette.stepRepo(app, true);
}

fn paletteAll(app: *App) CommandError!void {
    try git_palette.toggleAll(app);
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

// ─── the command log (git-more2) ────────────────────────────────────────

/// The pane, newest first; at the failed-op toast's entry when one is
/// waiting (`State.log_link_seq`).
fn commandLog(app: *App) CommandError!void {
    try git.openCommandLog(app, null);
}

/// Enter's twin for the log pane's row menu.
fn commandLogRerun(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.get(id) orelse return error.NoActivePane;
    const l = switch (p.*) {
        .list => |*l| if (l.kind == .git_log) l else return app.diag.fail(arena(app), "command log: not the log pane", .{}),
        else => return app.diag.fail(arena(app), "command log: not the log pane", .{}),
    };
    const e = (try l.entryAt(arena(app), l.cursor)) orelse return;
    try git.logEnter(app, e.*);
}

// ─── stash depth (git-more2) ────────────────────────────────────────────

fn stashStaged(app: *App) CommandError!void {
    try requireStaged(app, "stash staged");
    try git.stashWith(app, .{ .staged_only = true }, "Stash the index only: message (optional)");
}

/// The status pane's row when it has the focus, else the active buffer's file.
fn stashFile(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    const row = try rowOrActiveFile(app, repo);
    const path = try app.gpa.dupe(u8, row.path);
    errdefer app.gpa.free(path);
    try git.stashWith(app, .{ .path = path }, "Stash this file: message (optional)");
}

fn stashKeepIndex(app: *App) CommandError!void {
    try git.stashWith(app, .{ .keep_index = true }, "Stash keeping the index: message (optional)");
}

/// The STASHES row's files when the panel has one, else a picker.
fn stashRow(app: *App) std.mem.Allocator.Error!?[]const u8 {
    if (app.focus == .panel and app.focus.panel == .git) return git_palette.cursorStash(app);
    return null;
}

fn stashShow(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (try stashRow(app)) |ref| return git.stashShow(app, ref);
    try git.askList(app, repo, .stashes, .stash_show);
}

/// Enter's twin for the files pane's row menu.
fn stashShowDiff(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.get(id) orelse return error.NoActivePane;
    const l = switch (p.*) {
        .list => |*l| if (l.kind == .stash_files) l else return app.diag.fail(arena(app), "stash: not the files pane", .{}),
        else => return app.diag.fail(arena(app), "stash: not the files pane", .{}),
    };
    const e = (try l.entryAt(arena(app), l.cursor)) orelse return;
    try git.stashFileEnter(app, e.*);
}

fn stashBranch(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (try stashRow(app)) |ref| return git.stashBranchPrompt(app, ref);
    try git.askList(app, repo, .stashes, .stash_branch);
}

fn stashRename(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (try stashRow(app)) |ref| return git.stashRenamePrompt(app, ref, git_palette.cursorStashMessage(app) orelse "");
    try git.askList(app, repo, .stashes, .stash_rename);
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

// ─── an operation in progress ───────────────────────────────────────────

/// The rebase / merge / cherry-pick / revert / bisect the last status
/// found waiting, or the reason there is none.
fn inProgress(app: *App) CommandError!parse.InProgress {
    const repo = try git.requireRepo(app);
    const op = git.inProgressOf(app, repo.id);
    if (op == .none) return app.diag.fail(arena(app), "git: nothing in progress (no rebase, merge, cherry-pick, revert or bisect)", .{});
    return op;
}

fn opContinue(app: *App) CommandError!void {
    const op = try inProgress(app);
    try git.submitOp(app, try git.requireRepo(app), .{ .op_continue = op });
}

fn opAbort(app: *App) CommandError!void {
    const op = try inProgress(app);
    try git.submitOp(app, try git.requireRepo(app), .{ .op_abort = op });
}

fn opSkip(app: *App) CommandError!void {
    const op = try inProgress(app);
    try git.submitOp(app, try git.requireRepo(app), .{ .op_skip = op });
}

// ─── the rebase plan, amend, reset ──────────────────────────────────────

/// `r` on the graph: the plan modal over the selection.
fn rebasePlan(app: *App) CommandError!void {
    const g = try requireGraph(app);
    try git.openPlan(app, g);
}

/// `git.rebase_interactive_onto`: the plan modal over everything HEAD
/// has that the target does not. The target is the branches panel's
/// branch row when the panel has the focus, else the graph's selected
/// commit.
fn rebaseInteractiveOnto(app: *App) CommandError!void {
    const g = try requireGraph(app);
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return git.openPlanOnto(app, g, b);
    }
    const c = g.selected() orelse return app.diag.fail(arena(app), "rebase: select a commit, or a branch row in the branches panel", .{});
    try git.openPlanOnto(app, g, c.hash);
}

/// `git.explain_branch`: the branches panel's row when the panel has
/// the focus, else the checked-out branch.
fn explainBranch(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git.explainBranch(app, try verbBranch(app, "explain"));
}

/// `git.push_start_pr`: the branches panel's row when the panel has the
/// focus, else the checked-out branch.
fn pushStartPr(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git.pushStartPr(app, try verbBranch(app, "push and start PR"));
}

/// `git.worktree_open_tab`: the branches panel's WORKTREES row on a tab
/// page of its own.
fn worktreeOpenTab(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    const w = (try git_palette.cursorWorktree(app)) orelse return app.diag.fail(arena(app), "open worktree in a new tab: put the branches panel's cursor on a WORKTREES row first", .{});
    try git_palette.openWorktreeInTab(app, w);
}

/// `git.worktree_remove_delete_branch`: the branches panel's WORKTREES
/// row, behind the confirm that names the tree and its branch.
fn worktreeRemoveDeleteBranch(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    const w = (try git_palette.cursorWorktree(app)) orelse return app.diag.fail(arena(app), "remove worktree and delete branch: put the branches panel's cursor on a WORKTREES row first", .{});
    try git_palette.confirmRemoveWorktreeBranch(app, w);
}

/// `git.worktree_lock` / `git.worktree_unlock`: the branches panel's
/// WORKTREES row. Locking asks for an optional reason first.
fn worktreeLock(app: *App) CommandError!void {
    const w = try cursorWorktreeRow(app, "lock worktree");
    try git.lockWorktreePrompt(app, w.path, w.label());
}

fn worktreeUnlock(app: *App) CommandError!void {
    const w = try cursorWorktreeRow(app, "unlock worktree");
    if (!w.locked) return app.diag.fail(arena(app), "unlock worktree: {s} is not locked", .{w.path});
    try git.unlockWorktree(app, w.path);
}

fn cursorWorktreeRow(app: *App, what: []const u8) CommandError!@import("../git/parse.zig").Worktree {
    _ = try git.requireRepo(app);
    return (try git_palette.cursorWorktree(app)) orelse app.diag.fail(arena(app), "{s}: put the branches panel's cursor on a WORKTREES row first", .{what});
}

fn fixup(app: *App) CommandError!void {
    try git.directVerb(app, try requireGraph(app), .fixup, null);
}

fn squash(app: *App) CommandError!void {
    try git.directVerb(app, try requireGraph(app), .squash, null);
}

fn drop(app: *App) CommandError!void {
    try git.directVerb(app, try requireGraph(app), .drop, null);
}

/// The message first; the one-line plan runs from the prompt's accept.
fn reword(app: *App) CommandError!void {
    const g = try requireGraph(app);
    const c = g.selected() orelse return app.diag.fail(arena(app), "reword: select a commit first", .{});
    // The prompt borrows its title for as long as it is open.
    git.openPrompt(app, .reword, "Reword: the new commit message");
    try app.overlay.prompt.state.setText(app.gpa, c.subject);
}

fn selectBranch(app: *App) CommandError!void {
    try git.selectBranchCommits(app, try requireGraph(app));
}

fn requireStaged(app: *App, what: []const u8) CommandError!void {
    const st = &app.git;
    if (st.status) |s| if (s.staged > 0) return;
    return app.diag.fail(arena(app), "{s}: nothing staged", .{what});
}

/// `A` on the WIP row: the staged changes into HEAD, message kept.
fn amend(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    try requireStaged(app, "amend");
    try git.submitOp(app, repo, .amend_noedit);
}

/// `A` on a commit: the staged changes into that commit (fixup + autosquash).
fn amendTo(app: *App) CommandError!void {
    const g = try requireGraph(app);
    const c = g.selected() orelse return app.diag.fail(arena(app), "amend: select the commit to fold the staged changes into", .{});
    const repo = try git.requireRepo(app);
    try requireStaged(app, "amend");
    try git.submitOp(app, repo, .{ .amend_to = try app.gpa.dupe(u8, c.hash) });
}

/// What `git.reset_*` resets to: the branches panel's row when it has
/// the focus, the graph's selected commit when a graph pane does,
/// else a prompt asks for a rev.
fn resetTarget(app: *App) CommandError!?[]const u8 {
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return b;
    }
    if (app.focus == .pane) if (git.activeGraph(app)) |g| {
        if (g.selected()) |c| return c.hash;
    };
    return null;
}

fn reset(app: *App, mode: client.ResetMode) CommandError!void {
    _ = try git.requireRepo(app);
    if (try resetTarget(app)) |rev| return git.resetTo(app, mode, rev);
    switch (mode) {
        .soft => git.openPrompt(app, .reset_soft, "reset --soft to (a branch, tag or sha)"),
        .mixed => git.openPrompt(app, .reset_mixed, "reset --mixed to (a branch, tag or sha)"),
        .hard => git.openPrompt(app, .reset_hard, "reset --hard to (a branch, tag or sha)"),
    }
}

fn resetSoft(app: *App) CommandError!void {
    try reset(app, .soft);
}

fn resetMixed(app: *App) CommandError!void {
    try reset(app, .mixed);
}

fn resetHard(app: *App) CommandError!void {
    try reset(app, .hard);
}

// ─── diff any two refs (git-more2) ──────────────────────────────────────

/// `W` on the graph: the selected commit is the compare base (again clears).
fn compareBase(app: *App) CommandError!void {
    try git.toggleCompareBase(app, try requireGraph(app));
}

/// The diff pane on `base..selected`.
fn diffAgainstBase(app: *App) CommandError!void {
    try git.diffAgainstBase(app, try requireGraph(app));
}

/// The selected commit's own diff (Enter), whatever the base.
fn graphDiff(app: *App) CommandError!void {
    try git.showSelectedCommit(app, try requireGraph(app));
}

/// The branches panel's row when it has the focus, else a picker: that
/// branch against the checked-out one.
fn diffAgainstCurrent(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return git.diffAgainstCurrent(app, repo, b);
    }
    try git.askBranches(app, repo, .diff_current);
}

// ─── branch verbs (git-more2) ───────────────────────────────────────────

/// The branch a verb acts on: the branches panel's row when it has the
/// focus, else the checked-out branch.
fn verbBranch(app: *App, what: []const u8) CommandError![]const u8 {
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return b;
    }
    return app.git.branchLabel() orelse app.diag.fail(arena(app), "{s}: detached HEAD \u{2014} pick a branch in the branches panel", .{what});
}

fn branchRename(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git.branchRename(app, try verbBranch(app, "rename"));
}

fn fastForward(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git.fastForward(app, try verbBranch(app, "fast-forward"));
}

fn setUpstream(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git.setUpstream(app, try verbBranch(app, "set upstream"));
}

/// The panel's row when it has the focus, else a picker of the local branches.
fn checkoutForce(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return git.checkoutForce(app, b);
    }
    try git.askBranches(app, repo, .checkout_force);
}

fn deleteRemoteBranch(app: *App) CommandError!void {
    const repo = try git.requireRepo(app);
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return git.deleteRemote(app, b, null);
    }
    try git.askBranches(app, repo, .delete_remote);
}

/// The graph's selected commit, else the branches panel's row, else HEAD.
fn verbStart(app: *App) CommandError![]const u8 {
    if (app.focus == .pane) if (git.activeGraph(app)) |g| {
        if (g.selected()) |c| return c.hash;
    };
    if (app.focus == .panel and app.focus.panel == .git) {
        if (try git_palette.cursorBranch(app)) |b| return b;
    }
    return "HEAD";
}

fn newBranchFrom(app: *App) CommandError!void {
    try git.newBranchFrom(app, try verbStart(app));
}

fn worktreeAddFrom(app: *App) CommandError!void {
    try git.worktreeFrom(app, try verbStart(app));
}

fn pushForce(app: *App) CommandError!void {
    try git.pushForce(app);
}

// ─── the graph ──────────────────────────────────────────────────────────

/// Git mode: the palette in the sidebar, one graph tab per repo.
fn graph(app: *App) CommandError!void {
    _ = try git.requireRepo(app);
    try git_palette.enter(app);
    _ = try git_palette.showActiveGraph(app);
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

/// Enter on a detail row: the file's diff (in the commit, or the tree's).
fn graphDetailOpen(app: *App) CommandError!void {
    try git.openDetailRowCmd(app, try requireGraph(app));
}

/// A commit file row: the file as that commit had it, in a scratch buffer.
fn graphFileAtRev(app: *App) CommandError!void {
    try git.showDetailFileAtRev(app, try requireGraph(app));
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

// ─── tests ──────────────────────────────────────────────────────────────

test "view.git_commit_focus opens the repo's graph pane with the commit box focused" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    // The temp dir sits inside this repo's tree, so a repo of its own
    // is made for it: the graph must be the fixture's, not the parent's.
    const res = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "init", "-q" }, .cwd = .{ .path = root } });
    t.allocator.free(res.stdout);
    t.allocator.free(res.stderr);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.git_commit_focus" });
    try t.expectEqualStrings(root, app.git.activeRepo().?.path);
    const p = app.panes.get(app.active.?).?;
    try t.expect(p.* == .git_graph);
    try t.expect(p.git_graph.wip_focused);
    try t.expect(!p.git_graph.detail_focus);
    try t.expect(app.focus == .pane and app.focus.pane == app.active.?);
}
