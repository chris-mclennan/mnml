---
title: Git
description: Status, staging down to single lines, diffs, blame, a commit graph and conflict resolution, without leaving the editor.
---

mnml runs your own `git` and shows the results in panes. Every git call
happens off the UI thread, so a slow repository never freezes the editor.
A workspace that holds several repositories gets one of each view per
repository; `git.switch_repo` moves between them.

In the tables below, `space …` chords are the vim profile's leader. In the
standard profile `ctrl+k` opens the same which-key menu, so `space g s` is
`ctrl+k g s` there.

## In the editor

Changed lines are marked in the gutter. `git.jump_next_change`
(`space g n`, or `]c` in vim) and `git.jump_prev_change` (`[c`) move
between them, and `git.peek_change` shows the change under the cursor
against `HEAD` in a popup.

`git.blame_toggle` (`space g b`) adds a blame gutter to the file;
`git.toggle_line_blame` shows who last touched the cursor line, at the
end of the line. `git.file_history` lists the commits that touched the
file.

## Status and staging

<!-- video: git -->

| Command | Keys | |
| ------- | ---- | - |
| `git.status_pane` | `space g s` | The status and staging view. |
| `git.diff` | `space g d` | Diff the working tree. |
| `git.diff_file` | `space g f` | Diff this file. |
| `git.commit` | `space g c` | Commit what is staged. |
| `git.ai_commit` | `space g m` | Write the commit message with Claude, from the staged diff. |

The status pane lists staged, unstaged and conflicted files; you stage,
unstage, discard and open them from there, or from the palette
(`git.stage`, `git.stage_all`, `git.discard` and so on).

### Staging lines

In the diff pane you can act on part of a change. Press `v` to start a
selection (or use `shift` with the arrows, or drag with the mouse), then:

| Key | Action |
| --- | ------ |
| `s` | Stage the selected lines — or the whole hunk with no selection. |
| `u` | Unstage them. |
| `x` | Discard them from the working tree, after a confirm. |

`git.diff_stash_lines` stashes just those lines, and
`git.diff_commit_lines` commits just those lines and leaves the rest as it
is. The same selection drives the keys, the chips above the diff, the
right-click menu and the palette. `t` cycles the diff between hunk,
inline and side-by-side views.

## Conflicts

A conflicted file is resolved in the editor. It is listed first in the
status pane; open it and every conflict block is tinted, with a row of
chips above it: **Ours · Theirs · Both · Edit · Split · AI resolve**.

| Action | vim | standard |
| ------ | --- | -------- |
| Next / previous block | `]x` / `[x` | `f8` / `shift+f8` |
| Take ours | `co` | `alt+1` |
| Take theirs | `ct` | `alt+2` |
| Take both, ours first | `cb` | `alt+3` |

*Split* shows ours against theirs side by side in the diff pane. *AI
resolve* asks Claude, with the base, ours and theirs, and shows the
answer before it applies. Saving a file with no conflict markers left
stages it.

When a rebase, merge, cherry-pick or revert is in progress,
`git.op_continue`, `git.op_abort` and `git.op_skip` finish it.

## The commit graph

`git.graph` (`space g l`, or `ctrl+shift+g` in both profiles) opens a
browsable commit graph. Filter it by branch, author, date or subject,
open a commit's detail and its diff, or mark one commit as a base and
diff another against it.

From the graph you can cherry-pick, revert, tag, reword, squash, fixup
or drop commits, start a new branch or worktree from one, and plan an
interactive rebase — pick, reword, edit, squash, fixup, drop and
reorder — without leaving the pane. Destructive operations
(`git.reset_hard`, `git.push_force`, a forced checkout) ask first.

## Everything else

Branches (`git.checkout`, `git.new_branch`, `git.merge`, `git.rebase`,
`git.recent_branches`), remotes (`git.fetch`, `git.pull --ff-only`,
`git.push`), stashes (whole tree, staged only, one file, or selected
lines), worktrees, tags, the reflog, and `git.undo` for the last commit
are all commands. `git.browse` opens the current file on GitHub, GitLab
or Bitbucket.

The [command reference](/docs/reference/commands) lists every `git.*`
command with its keys in both profiles.
