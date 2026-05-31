---
title: Git
description: mnml's git surface — gutter signs, diff pane with hunk staging, status view, commit graph, branch rail, sync, blame, AI commit messages.
---

mnml's git track shells out to the system `git` binary. There's no libgit2, no daemon, no in-process wire-format reader — every operation is a `git status` / `git diff` / `git log` subprocess whose output mnml parses. That keeps the surface area small (every quirk of your repo's `core.autocrlf`, hooks, submodules, signed commits, sparse checkout … just works because it's still your `git` doing the work) and the failure mode quiet (no `git` on `$PATH`, not a repo, no `HEAD` yet — every reader returns an empty default).

The user-facing pieces are layered over that:

1. **Lightweight status** drives the statusline branch chip and the editor gutter.
2. **The diff pane** (`Pane::Diff`) renders parsed hunks in Hunk / Inline / Split modes with per-hunk stage / unstage / discard.
3. **The staging view** (`Pane::GitStatus`) is the `git status` browser — file-level stage / unstage / commit.
4. **The commit graph** (`Pane::GitGraph`) is the DAG browser with a working-tree (WIP) virtual row at the top, sortable columns, branch / date / author / subject filters.
5. **The branch rail** lives in the left sidebar — current repo's local branches, linked worktrees, and open PRs/MRs (when the SCM dashboards are wired up).
6. **Sync** — fetch, pull (`--ff-only`), push, cherry-pick, revert, tags, stash list, reflog, plus an operation-level undo / redo stack.

This page covers each in depth. Keybindings live where the keys live — global chords in the [keybinding reference](/reference/keybindings/), pane-local chords inline below.

## Statusline & gutter

The statusline carries the branch chip and three NvChad-style file-status chips. The branch chip is `<provider-icon> <branch> ↑N ↓M` when ahead / behind an upstream, plus a `+A ●C -R` triplet for added / changed / removed files. Clicking the branch opens a context menu (checkout, new branch, push, fetch, pull, stash, …); clicking the provider icon (a GitHub / GitLab / Bitbucket / Azure DevOps nerd-font glyph resolved from `remote.origin.url`) opens the repo on the web.

The gutter has per-line signs for everything that differs from `HEAD`:

- `▎` added (green) — line is new
- `▎` modified (yellow) — line existed but was changed
- `_` removed (red) — lines were deleted at this anchor

Signs come from `git diff HEAD --unified=0`, parsed line-by-line. The cache TTL is 3 seconds — the gutter is cheap enough to poll on every tick, and the status reader degrades gracefully (a non-repo workspace just paints no gutter).

## The diff pane

`Pane::Diff` is the dedicated diff viewer. Open it via `:Gdiff` / `git.diff` (the worktree), `git.diff_file` (just the active file), `git.diff_all` (everything vs `HEAD` — staged plus unstaged), or by selecting a commit in the graph (`Enter` opens `git show <hash>` as a Diff pane). It has its own toolbar across the top with the daily git buttons (Pull / Push / Fetch / Branch / Commit / Stash / Pop / Reflog / Term) plus the per-pane mode toggle (Hunk / Inline / Split / Wrap).

### Three view modes

Cycle with `v`, or click the toolbar tabs.

- **Hunk** — focused, expanded-by-default hunks with their `@@ -X,Y +Z,W @@` banner and an `<old> <new>` line-number gutter. Best for "scan the changes."
- **Inline** — the whole file as one continuous column, additions green, removals red. Best when context outside the hunk matters.
- **Split** — old on the left, new on the right, with a 1-cell change-density minimap on the far edge so you can see where edits cluster.

The mode you last used sticks (`app.diff_view_mode_pref`). `w` toggles wrap; long lines clip by default. Intraline highlighting dims the common prefix / suffix so the eye lands on the part that actually changed.

### Hunk navigation + staging

| Key | Action |
|---|---|
| `↑` / `↓` (Hunk / Inline) | Move to prev / next hunk |
| `↑` / `↓` (Split) | Scroll one row |
| `j` / `k` | Scroll one row (vim convention; works in every mode) |
| `n` / `]` | Next hunk (or next `/`-filter match) |
| `p` / `[` | Previous hunk |
| `f` / `F` | Jump to next / previous file in the diff |
| `g` / `G` / `Home` / `End` | Top / bottom |
| `v` | Cycle view modes |
| `w` | Toggle wrap |
| `Enter` | Open the underlying file at the hunk's line |
| `s` | Stage the cursor hunk (`git apply --cached`) |
| `u` | Unstage the cursor hunk (`git apply --cached --reverse`) |
| `r` | Refresh the diff |
| `/` | Open the file-name filter; type chars to narrow, `Enter` to keep, `Esc` to clear |
| `Esc` | Return focus to the file tree |

Hunk staging works by piping a minimal patch (`--- a/<file>\n+++ b/<file>\n<body>`) into `git apply --cached --unidiff-zero`. The `--unidiff-zero` flag is what lets staging work on the zero-context hunks mnml parses; the `--reverse` form is unstaging. Discard (the destructive equivalent, via the right-click menu) drops the `--cached` so it reverse-applies against the worktree.

The discard path always goes through a typed-confirmation prompt — you have to type the file name (or hunk identifier) to accept, mirroring the same convention `delete_branch` uses. That makes a slip on the wrong key non-destructive.

### Right-click menu

The diff pane has a per-row context menu (right-click any line): stage / unstage hunk, discard hunk (with confirm), copy hunk to clipboard, open the file at this hunk. Same menu surface lives on the staging view (file-level: stage, unstage, discard file, stash file, add to `.gitignore`).

## The staging view

`Pane::GitStatus` (`git.status_pane` — also reachable as `:Git` for fugitive-trained muscle memory) is the file-level staging surface. Two stacked sections — **Unstaged changes** and **Staged changes** — with `git status --porcelain` driving the lists. The selected row is inverted. The footer hints the active key set.

| Key | Action |
|---|---|
| `↑` / `↓` / `j` / `k` | Move selection |
| `Space` | Toggle stage / unstage (whatever the selected file currently is) |
| `s` | Stage the selected file (`git add`) |
| `u` | Unstage the selected file (`git restore --staged`, falls back to `git reset -q HEAD`) |
| `a` | Stage all (`git add -A`) |
| `A` | Unstage all (`git restore --staged .`) |
| `Enter` | Open the file's diff in a sibling pane |
| `c` | Commit prompt (typing the message inline) |
| `C` | Ask Claude for a commit message from `git diff --cached` |
| `b` / `B` | Checkout branch picker / create new branch |
| `w` | Worktree picker |
| `r` | Refresh |
| `Esc` | Return to file tree |

A file can appear in both sections — staged change with further worktree edits — and stage / unstage are independent. The "discard file" action lives on the right-click menu; it goes through the same typed-confirm prompt as discard-hunk and runs `git restore -- <path>` (falling back to `git checkout HEAD -- <path>`).

`C` (AI commit message) spawns `claude -p` or `codex` as a background job, feeding it the staged diff. While it streams the response goes into the WIP commit textarea on the graph pane (see below) or into the commit prompt directly. The toolbar shows a spinner while the job is in flight; cancel by pressing `Esc` on the prompt.

## The commit graph

`Pane::GitGraph` (`git.graph` — `:GitGraph`) is the DAG browser. It loads up to 800 commits via `git log --all --date-order` (filterable), runs them through a lane-layout algorithm to produce the colored-rail graph you see on the left, and shows the selected commit's metadata + changed-file list in a right-side detail panel.

The list is virtual: when the working tree has uncommitted changes, row 0 is a **WIP** virtual row (above the newest real commit). Selecting it shows the staging-equivalent detail panel — a working-tree summary plus an inline commit-message textarea + buttons.

### The WIP row

The WIP row's detail panel is the second place you can commit from (after the staging view). It's a multi-line textarea with its own cursor / cursor-move / backspace / delete / line-start / line-end handlers (it's not an editor pane — just enough to type a message). The same backend that drives `C` on the staging view drives the `AI Message` button here.

Keys when the WIP row is selected:

| Key | Action |
|---|---|
| `c` | Open the commit prompt |
| `C` | AI commit message (Claude) |
| `Enter` | Open the full staging pane |

### Walking commits

| Key | Action |
|---|---|
| `↑` / `↓` / `j` / `k` | Move selection |
| `PgUp` / `PgDn` / `u` / `d` | Page up / down |
| `g` / `G` / `Home` / `End` | First / last commit |
| `Enter` | Open the commit's diff (`git show <hash>`) |
| `y` | Copy the selected commit's hash to the clipboard |
| `/` | Hash-prefix filter — type hex chars and the selection jumps to the first commit whose hash begins with what you typed (`Esc` cancels) |
| `r` | Refresh (re-run `git log` with the current filter) |
| `b` / `B` | Branch filter picker / clear branch filter |
| `D` | Date filter prompt (any git-recognized spec — `"1 week ago"`, `"2026-01-01"`, …) |
| `a` | Author filter (regex against `--author`) |
| `s` | Subject filter (`--grep`, case-insensitive) |
| `F` | Clear ALL filters |
| `Esc` | Return to file tree |

### Sortable columns

Click a header to cycle its sort: native git order → descending → ascending → native. Sortable columns are **Date** (author timestamp), **Author**, and **SHA**. Sort happens in place against the loaded commits, no extra `git log` call.

### Cherry-pick / revert

With a commit selected, `git.cherry_pick` and `git.revert` apply or invert it onto HEAD. Conflicts surface as a toast with git's error message — you resolve them and `git cherry-pick --continue` from a pty pane (no in-pane conflict resolver yet). Revert uses `--no-edit` so the default `Revert "..."` message lands without opening an external editor.

### Embedded diff

Click a file in the right detail panel and the commit list area is *replaced* by an embedded diff view (the right panel stays put). The same chords as the standalone diff pane work (`v`, `w`, `↑↓`, `/`, `f` / `F`, `Enter`, `Esc`). Esc closes the embedded diff and the commit list returns.

## The branch rail

The left sidebar has two persistent sections: **WORKSPACE** (the file tree) and **GIT**. The GIT section is the branch rail — local branches, linked worktrees, and open PRs/MRs for the current repo, all in one collapsible column. The current branch carries a `●` marker; clicking another branch checks it out.

Worktrees come from `git worktree list --porcelain`. Clicking a worktree row opens a shell in that path (a `Pane::Pty`). Worktree management — create / remove — runs through the same typed-confirm safety net as branch delete.

The pulls sub-section is populated lazily from the SCM caches (`bitbucket_pull_requests` / `github_pull_requests` / `gitlab_merge_requests` / `azdevops_pull_requests`). Best-effort match by remote URL against configured hosts; empty when there's no recognized remote. Selecting a PR opens its web URL.

The rail's right-click menu (on a branch row) covers:

- Checkout this branch
- New branch from here…
- Delete branch (typed confirm — type the branch name to accept)
- Push / pull / fetch (acts on the rail's selection, not necessarily HEAD)

## Sync — fetch, pull, push

Three operations, all read-and-write subprocesses against the system `git`:

```text
:Gfetch    git fetch --all --prune
:Gpull     git pull --ff-only
:Gpush     git push     (auto-falls-back to --set-upstream on first push)
```

- **fetch** is always safe. The default is `--all --prune` so every tracked remote refreshes and gone-upstream branches drop their tracking marks.
- **pull** is `--ff-only` on purpose. mnml refuses to land surprise merge commits; on a divergent history you get git's "not possible to fast-forward" error in a toast and have to pick merge / rebase from a pty pane.
- **push** runs without `--force`. Force-push is intentionally not exposed (drop to a pty if you really need it). The first-push case is detected by the "no upstream" error and retried with `--set-upstream origin <current-branch>`.

All three live on the git toolbar at the top of the GitGraph + Diff panes; they also have palette ids (`git.fetch` / `git.pull` / `git.push`).

## Blame

`git.blame_toggle` (`:GBlame`) toggles a per-line blame gutter on the active editor. Each line shows `<sha> <author>` truncated to the gutter width; uncommitted lines render as `• not committed yet` with an all-zeros sha. Hovering a line reveals the full commit summary; clicking opens that commit's diff.

The reader runs `git blame --porcelain` and parses the output into one [`BlameLine`] per file line. Re-runs on file save or when the editor's path changes.

## Stash

| Command | Action |
|---|---|
| `git.stash` | Prompt for a message, then `git stash push -u [-m <msg>]` |
| `git.stash_pop` | `git stash pop` — apply + drop the newest stash |
| `git.stash_list` | Picker over `git stash list` — `Enter` applies (keeps the stash) |
| `git.stash_drop` | Picker — `Enter` deletes the chosen stash from the list |

The `-u` (include untracked) flag is on by default since "stash didn't catch my new file" is the most common surprise. Apply (from the list picker) keeps the stash in the list; pop both applies and drops. Drop reorders the rest — `stash@{1}` becomes `stash@{0}` after dropping `stash@{0}`.

A right-click menu on a file in the staging view has a **Stash this file** entry that runs `git stash push -u -- <path>` so you can park one file's changes without touching the rest.

## Reflog

`git.reflog` opens a picker over `git reflog` — the "where did HEAD just go?" history. Each row carries the `HEAD@{N}` selector, short SHA, op tag (`commit`, `commit (amend)`, `checkout`, `rebase: aborting`, …), and the action description. `Enter` opens that commit's diff so you can confirm what's there before any recovery move. `git reset --hard HEAD@{N}` is intentionally NOT one-key — drop to a pty.

This is the recovery surface for "I just rebased and lost a commit": find the pre-rebase HEAD in the list, open its diff to confirm, then reset.

## Tags

| Command | Action |
|---|---|
| `git.tag` | Create an annotated tag (`git tag -a <name> -m <msg>`) on HEAD or the selected graph commit |
| `git.tag_delete` | Picker over local tags — `Enter` deletes |
| `git.push_tags` | `git push --tags` — publish every local tag |

Annotated only (no lightweight variant in the palette); they carry author, timestamp, and message, and show up more prominently in `git log --tags`.

## AI commit messages

mnml integrates with the `claude` CLI and Codex for commit-message generation — it does not bundle a model. Three entry points:

- `git.ai_commit` (also `C` on the staging view and the WIP row) — write a fresh commit message from `git diff --cached`. The result lands in the commit prompt or the WIP textarea.
- `git.codex_commit` — same flow via Codex instead of Claude.
- `git.ai_recompose` — rewrite HEAD's message with `--amend`. Feeds `git show HEAD` (stat + patch) plus the current message as context. Useful for "I committed in a hurry; tidy the message" without changing the tree.

Both run as background jobs (`ai_msg_job` on the staging view / `ai_streaming` on the WIP textarea); the spinner shows while they're in flight. Cancel with `Esc` on the prompt.

## Browse on remote

`git.browse` (`:GBrowse`) opens the active file at the cursor's line on the remote — GitHub, GitLab, Bitbucket, or Azure DevOps depending on `remote.origin.url`. With a visual selection, the URL fragment becomes `#L<lo>-L<hi>`. The rev in the URL is `HEAD`'s short SHA so the link stays stable across force-pushes. The same helper builds commit URLs for the "open on remote" entry in the graph pane's right-click menu.

GitHub / GitLab use `/blob/<sha>/<path>` URLs; Bitbucket uses `/src/<sha>/<path>` with `#lines-N` fragments; Azure DevOps falls through to GitHub's shape (a generic best-effort).

## Undo / redo for git ops

mnml maintains an operation-level undo stack for git moves that *can* be undone safely — currently commits (via `git reset --soft HEAD~1`) and branch checkouts. The Undo / Redo buttons live at the left edge of the git toolbar (matching most apps' convention), and the palette ids are `git.undo` / `git.redo`.

The redo stack is preserved across undos within a session but cleared by any new git op (the standard undo-redo semantic — diverge once, the redo path is gone). Destructive ops like discard-hunk and discard-file are NOT in the stack; they're already gated by a typed-confirm prompt, which is the safer guarantee here.

## Multi-repo workspaces

A workspace can contain multiple sibling git repos (e.g. `~/Projects/` with several repos as direct children). On startup mnml walks the workspace looking for `.git/` markers (capped at depth 3, skipping `node_modules` / `target` / dot-dirs); if the workspace root *itself* is a repo, that's the only entry — no descent into nested sub-repos in that case.

When more than one repo is found:

- The statusline branch chip shows the active repo's name + branch (`<repo>· <branch>`).
- `git.next_repo` / `git.prev_repo` (`Alt+]` / `Alt+[`) cycle the active repo. Statusline, gutter, branch rail, and any open GitGraph / GitStatus / Diff pane all retarget at once.
- `git.switch_repo` opens a picker; `git.refresh_repos` rediscovers (run after a clone / submodule add).

The `GitStatus` / `GitGraph` panes expose a `retarget(workspace)` method that re-points their cached workspace and refreshes — selection and scroll reset since the new repo's content is unrelated to the old.

## Cursor navigation: jumping changes in a file

While editing, `[c` and `]c` (in vim mode) jump to the previous / next changed hunk in the current buffer — the standard vim-fugitive / vim-gitgutter convention. In standard mode the same lives behind `git.jump_prev_change` / `git.jump_next_change` (no default key — bind in `[keys.standard]`).

`git.peek_change` opens a popup with the diff of the change at the cursor (a single-hunk inline view) without leaving the editor. Esc dismisses it. Useful when you want to see what changed without context-switching to a Diff pane.

## What's safe vs what's gated

- **Always safe (read-only):** every status / log / diff / blame / reflog read. Cached when cheap to do so.
- **Safe (`git`'s own safety):** pull (`--ff-only`), fetch, push (no `--force`).
- **One-key writes:** stage / unstage hunks + files, commit, checkout branch, cherry-pick, revert, tag create, stash push / pop.
- **Typed-confirm:** discard hunk, discard file, branch delete, worktree remove. You have to type the file or branch name to accept.
- **Not exposed:** force-push, hard reset, history rewrite, conflict resolution. All available by dropping to a pty pane.

## Next

- [Editing](/manual/editing/) — the buffer that's diffed and committed
- [Configuration](/reference/configuration/) — `[keys.global]` / `[keys.vim]` / `[keys.standard]` for remapping every git chord
- [Keybindings](/reference/keybindings/) — every default key, including the full git palette
- [SCM & CI dashboards](/manual/scm/) — pipelines + cross-host PR pickers, the layer above the branch rail's `pulls` sub-section
- [AI panes](/manual/ai/) — the Claude / Codex integration that drives `git.ai_commit` and `git.ai_recompose`
