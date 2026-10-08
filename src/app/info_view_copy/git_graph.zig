//! Hover help for the git graph pane's own controls — the toolbar, the
//! column headers, the divider, the detail column's working-tree
//! sections and their `[+]` / `[−]`, the commit box and its buttons,
//! the rebase plan's rows. They register `.script_hit{ pane, id }` in
//! the id ranges `ui/git_graph_view.zig` and `ui/git_toolbar.zig`
//! reserve (`0xF000_0000` up), which the generic pane-row reading took
//! for a list panel's kebab: twenty controls read "Row actions". Each
//! entry says what `git.graphClick` does with a press there.

const std = @import("std");
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const graph_view = @import("../../ui/git_graph_view.zig");
const git_toolbar = @import("../../ui/git_toolbar.zig");

/// The entry for a graph control's hit id; null for a commit row (the
/// pane's own row reading answers those) or an id outside the ranges.
pub fn entry(id: u32) ?Entry {
    if (git_toolbar.actionOf(id)) |a| return toolbar(a);
    if (graph_view.sortOf(id)) |c| return column(c);
    if (graph_view.wipButtonOf(id)) |b| return wipButton(b);
    if (graph_view.wipFileOf(id)) |f| return wipFile(f);
    if (graph_view.detailRowOf(id) != null) return detail_row;
    if (graph_view.planRowOf(id) != null) return plan_row;
    if (id == graph_view.divider_id) return divider;
    return null;
}

pub fn toolbar(a: git_toolbar.Action) Entry {
    return switch (a) {
        .undo => .{
            .title = "Undo — the last git step",
            .body = "Click undoes the last git step mnml made — a commit or an amend goes back with its changes staged, a checkout returns to the branch before. It refuses when HEAD has moved since, and a commit made outside mnml is not on its list. Redo puts the step back.",
            .links = &.{ .{ .command = .{ .id = .@"git.undo", .label = "Undo the last git step" } }, .{ .command = .{ .id = .@"git.redo", .label = "Redo it" } } },
        },
        .redo => .{
            .title = "Redo — the undone commit",
            .body = "Click puts back the commit the last Undo took away, as it was — message, author and all. It only knows the commit Undo removed; after a new commit there is nothing to redo.",
            .links = &.{ .{ .command = .{ .id = .@"git.redo", .label = "Redo" } }, .{ .command = .{ .id = .@"git.reflog", .label = "The reflog" } } },
        },
        .pull => .{
            .title = "Pull",
            .body = "Click runs `git pull --ff-only`: the branch moves forward to its upstream when that is a fast-forward, and fails with a toast when the two have diverged rather than making a merge commit. The graph refreshes when it lands.",
            .links = &.{ .{ .command = .{ .id = .@"git.pull", .label = "Pull" } }, .{ .command = .{ .id = .@"git.fetch", .label = "Fetch only" } } },
        },
        .push => .{
            .title = "Push",
            .body = "Click runs `git push` for the current branch; on its first push it sets the upstream (`--set-upstream origin <branch>`) itself. A rejected push says why in a toast — fetch and pull first.",
            .links = &.{ .{ .command = .{ .id = .@"git.push", .label = "Push" } }, .{ .command = .{ .id = .@"git.pull", .label = "Pull first" } } },
        },
        .fetch => .{
            .title = "Fetch",
            .body = "Click runs `git fetch --all --prune`: every remote's branches and tags come down and the graph shows them, but no local branch moves and the working tree is untouched. Deleted remote branches drop off.",
            .links = &.{.{ .command = .{ .id = .@"git.fetch", .label = "Fetch" } }},
        },
        .branch => .{
            .title = "Branch",
            .body = "Click opens the branch menu: check out a branch, the recent branches, a new branch, delete one; then fetch, pull and push, the commit graph, and a copy of the current branch's name. The sidebar's LOCAL and REMOTE sections list the branches themselves.",
            .links = &.{ .{ .command = .{ .id = .@"git.branch_menu", .label = "The branch menu" } }, .{ .command = .{ .id = .@"git.checkout", .label = "Check out a branch" } } },
        },
        .commit => .{
            .title = "Commit",
            .body = "Click commits what is staged, asking for the message in a prompt. The commit box under the detail column is the same commit written in place; with nothing staged the commit fails with a toast.",
            .links = &.{ .{ .command = .{ .id = .@"git.commit", .label = "Commit" } }, .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything first" } } },
        },
        .stash => .{
            .title = "Stash",
            .body = "Click stashes the working tree and the index (`git stash push -u`, untracked files included), asking for an optional message first. The tree goes back to HEAD; the STASHES section lists the entry, and Pop brings the newest back.",
            .links = &.{ .{ .command = .{ .id = .@"git.stash", .label = "Stash" } }, .{ .command = .{ .id = .@"git.stash_pop", .label = "Pop it" } } },
        },
        .pop => .{
            .title = "Pop — the newest stash",
            .body = "Shown beside Stash while there is a stash. Click applies the most recent one to the working tree and drops it from the list (`git stash pop`); a conflict leaves the stash in place and the files marked.",
            .links = &.{.{ .command = .{ .id = .@"git.stash_pop", .label = "Pop" } }},
        },
        .reflog => .{
            .title = "Reflog",
            .body = "Click lists where HEAD has been — commits, checkouts, resets, rebases — newest first; picking one opens that commit's diff. It is the way back to a commit an Undo, a reset or a rebase left behind.",
            .links = &.{.{ .command = .{ .id = .@"git.reflog", .label = "The reflog" } }},
        },
        .refresh => .{
            .title = "Refresh the graph",
            .body = "Click reads the repository again — the commits, the refs, the working tree's status — and redraws. The graph refreshes on its own after mnml's own git work and on a save; this is for a change made outside, in a terminal.",
            .links = &.{.{ .command = .{ .id = .@"git.refresh", .label = "Refresh the status" } }},
        },
        .cont => .{
            .title = "Continue",
            .body = "Shown while a rebase, merge, cherry-pick or revert is stopped. Click continues it (`--continue`) once the conflicts are resolved and staged; git says which files are still unmerged if not.",
            .links = &.{ .{ .command = .{ .id = .@"git.op_continue", .label = "Continue" } }, .{ .command = .{ .id = .@"git.op_abort", .label = "Abort instead" } } },
        },
        .abort => .{
            .title = "Abort",
            .body = "Shown while an operation is in progress. Click abandons the rebase, merge, cherry-pick, revert or bisect (`--abort`) and puts the branch back where it was before it began.",
            .links = &.{.{ .command = .{ .id = .@"git.op_abort", .label = "Abort" } }},
        },
        .skip => .{
            .title = "Skip",
            .body = "Shown while a rebase, cherry-pick or revert is stopped. Click drops the commit it stopped on (`--skip`) and carries on with the next one; the dropped commit's changes are not applied.",
            .links = &.{.{ .command = .{ .id = .@"git.op_skip", .label = "Skip this step" } }},
        },
    };
}

pub fn column(c: graph_view.SortCol) Entry {
    return switch (c) {
        .none => .{
            .title = "COMMIT MESSAGE column",
            .body = "The commits' subjects, next to the lanes of the graph. Click puts the list back in graph order (topological, newest first) after a sort on another column.",
            .links = &.{.{ .command = .{ .id = .@"git.graph_sort", .label = "Cycle the sort" } }},
        },
        .author => .{
            .title = "AUTHOR column",
            .body = "Who wrote each commit. Click sorts the list by author; a second click on the same header reverses it, and a click on COMMIT MESSAGE puts back the graph order.",
            .links = &.{.{ .command = .{ .id = .@"git.graph_sort", .label = "Cycle the sort" } }},
        },
        .date => .{
            .title = "DATE / TIME column",
            .body = "When each commit was made. Click sorts the list by date, newest first; a second click reverses it, and a click on COMMIT MESSAGE puts back the graph order.",
            .links = &.{.{ .command = .{ .id = .@"git.graph_sort", .label = "Cycle the sort" } }},
        },
        .sha => .{
            .title = "SHA column",
            .body = "Each commit's short hash. Click sorts the list by hash (a second click reverses it) — handy for finding a hash someone pasted; COMMIT MESSAGE puts back the graph order. Right-click on a row is the commit's menu; its detail pane's row menu copies the full hash.",
            .links = &.{.{ .command = .{ .id = .@"git.graph_sort", .label = "Cycle the sort" } }},
        },
    };
}

pub fn wipButton(b: graph_view.WipButton) Entry {
    return switch (b) {
        .stage_all => .{
            .title = "Stage All",
            .body = "Click stages every change in the working tree, untracked files included (`git add -A`); the files move from Unstaged to Staged. The `[+]` on a row stages that file alone. A narrow column labels it `+ All`.",
            .links = &.{ .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything" } }, .{ .command = .{ .id = .@"git.unstage_all", .label = "Unstage everything" } } },
        },
        .unstage_all => .{
            .title = "Unstage All",
            .body = "Click takes every staged change back out of the index; the edits stay in the files, now under Unstaged. Inert with nothing staged. The `[−]` on a row unstages that file alone. A narrow column labels it `− All`.",
            .links = &.{ .{ .command = .{ .id = .@"git.unstage_all", .label = "Unstage everything" } }, .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything" } } },
        },
        .commit => .{
            .title = "Commit — from the box",
            .body = "Click commits the staged changes with the box's text as the message and empties the box. An empty box asks for the message in a prompt instead; while an AI message is still streaming it refuses and says so.",
            .links = &.{ .{ .command = .{ .id = .@"git.commit", .label = "Commit with a prompt" } }, .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything first" } } },
        },
        .ai_message => .{
            .title = "AI message",
            .body = "Click asks Claude for a commit message written from the staged diff; it streams into the box, where it can be edited before Commit. Nothing is committed by this button. A narrow column labels it `AI`.",
            .links = &.{.{ .command = .{ .id = .@"git.ai_commit", .label = "Write one with Claude" } }},
        },
        .clear => .{
            .title = "Clear the message",
            .body = "Click empties the commit box. Only the text goes — what is staged stays staged.",
        },
        .textarea => .{
            .title = "Commit message box",
            .body = "Click here and type the commit message: the first line is the subject, a blank line then the body. Enter inside the box is a new line and Ctrl+Enter commits what is staged with this text, as the Commit button under it does. Esc or Tab hands the keys back to the graph.",
            .links = &.{ .{ .command = .{ .id = .@"git.commit", .label = "Commit with a prompt" } }, .{ .command = .{ .id = .@"git.ai_commit", .label = "Write one with Claude" } } },
        },
    };
}

pub fn wipFile(f: graph_view.WipFileHit) Entry {
    if (f.button) return if (f.staged) .{
        .title = "[−] — unstage this file",
        .body = "Click takes this file's staged changes back out of the index; the edits stay in the file and it moves to Unstaged. Unstage All does every file at once.",
        .links = &.{ .{ .command = .{ .id = .@"git.unstage", .label = "Unstage the selected file" } }, .{ .command = .{ .id = .@"git.unstage_all", .label = "Unstage everything" } } },
    } else .{
        .title = "[+] — stage this file",
        .body = "Click stages this file's changes — all of them, the whole file — and it moves to Staged. Stage All does every file at once; to stage part of a file, open its diff.",
        .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage the selected file" } }, .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything" } } },
    };
    return if (f.staged) .{
        .title = "A staged file",
        .body = "A file whose changes are in the index and go into the next commit; the letter is its state (`M` modified, `A` added, `D` deleted, `R` renamed). Click opens the staged diff; right-click has open the file, unstage, discard, stash it and copy the path.",
        .keys = &.{.{ .chord = "Right-click", .label = "The file's menu" }},
        .links = &.{ .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } }, .{ .command = .{ .id = .@"git.open_file", .label = "Open the file" } } },
    } else .{
        .title = "A changed file",
        .body = "A file changed in the working tree and not yet staged; `?` is untracked (git does not know it yet), `M` modified, `D` deleted. Click opens its diff against the index; right-click has open the file, stage, discard, stash it and copy the path.",
        .keys = &.{.{ .chord = "Right-click", .label = "The file's menu" }},
        .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } }, .{ .command = .{ .id = .@"git.open_file", .label = "Open the file" } } },
    };
}

const detail_row: Entry = .{
    .title = "A file of the commit",
    .body = "A file the selected commit changed, with its state letter. Click selects it; click it again, or Enter, opens its diff in that commit. Right-click has the file at that revision, and copies of the hash and the path.",
    .keys = &.{ .{ .chord = "Enter", .label = "Open its diff" }, .{ .chord = "Right-click", .label = "The file's menu" } },
    .links = &.{ .{ .command = .{ .id = .@"git.graph_detail_open", .label = "Open the diff" } }, .{ .command = .{ .id = .@"git.graph_file_at_rev", .label = "The file at that revision" } } },
};

const plan_row: Entry = .{
    .title = "A step of the rebase plan",
    .body = "One commit of the interactive rebase being planned, with the action it will get — pick, reword, edit, squash, fixup or drop. Click selects the row; a click on the selected row steps its action forward, a right-click back.",
    .links = &.{ .{ .command = .{ .id = .@"git.op_abort", .label = "Abort a rebase in progress" } }, .{ .command = .{ .id = .@"git.graph", .label = "The graph" } } },
};

const divider: Entry = .{
    .title = "The graph / detail divider",
    .body = "The line between the commit list and the detail column. Drag it left or right to give either side more room.",
    .keys = &.{.{ .chord = "Drag", .label = "Resize the columns" }},
};

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every git graph control id has an entry of its own, none the generic row actions, and a commit row has none here" {
    inline for (comptime std.enums.values(git_toolbar.Action)) |a| try t.expect(entry(git_toolbar.hitId(a)).?.body.len >= 40);
    inline for (comptime std.enums.values(graph_view.SortCol)) |c| try t.expect(entry(graph_view.sortId(c)).?.body.len >= 40);
    inline for (comptime std.enums.values(graph_view.WipButton)) |b| try t.expect(entry(graph_view.wipButtonId(b)).?.body.len >= 40);
    for ([_]bool{ false, true }) |staged| for ([_]bool{ false, true }) |button| {
        const e = entry(graph_view.wipFileId(.{ .idx = 3, .staged = staged, .button = button })).?;
        try t.expect(!std.mem.eql(u8, e.title, "Row actions"));
    };
    try t.expect(entry(graph_view.detailRowId(2)) != null);
    try t.expect(entry(graph_view.planRowId(0)) != null);
    try t.expect(entry(graph_view.divider_id) != null);
    try t.expect(entry(5) == null);
    // Two different controls read two different titles.
    try t.expect(!std.mem.eql(u8, entry(git_toolbar.hitId(.push)).?.title, entry(graph_view.wipButtonId(.stage_all)).?.title));
}
