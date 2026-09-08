# Git — what lazygit has that mnml does not

Research note, 2026-09-07. Read-only; every mnml claim below was grepped in
`mnml-zig` (main, `80752e94`) and the Rust `mnml`. lazygit's surface is taken
from `docs/keybindings/Keybindings_en.md` + the README (fetched 2026-09-07).

Shorthand for the mnml-zig column: `specs` = `src/commands/specs.zig`,
`client` = `src/git/client.zig` (the worker's `Job` union and `runJob`),
`git.zig` = `src/app/git.zig`, `cmd_git` = `src/app/cmd_git.zig`,
`palette` = `src/app/git_palette.zig`, `graph_view` = `src/ui/git_graph_view.zig`,
`diff_view` = `src/ui/diff_view.zig`, `parse` = `src/git/parse.zig`.

Gap sizes: **none** = mnml has it · **partial** = a narrower form · **missing**.

## 1. Feature matrix

### Status / global

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Recent-repo switcher (`ctrl+r`) | `git.switch_repo` / `next_repo` / `prev_repo` (`cmd_git:634-653`), repos pill menu `palette.openReposMenu` | `git.switch_repo` | none | mnml's is a multi-root *workspace* discovery (`git.discover`, `walkRepos` in `git.zig:423-514`), not a history of visited repos |
| Undo / redo (`z` / `Z`, reflog-based, covers most ops) | `git.undo` / `git.redo` (`client:234-261`), op-level stack `UndoEntry` (`client:209`) | `git.undo` / `git.redo` (`src/app/git.rs`) | partial | only `commit`, `amend`, `checkout` push an entry (`pushUndo` calls at `client:581,628,636`). Merge / rebase / cherry-pick / revert / reset / stash are not undoable |
| Command log (`@`) | — (each op yields one toast via `runToast`, `git.zig:2564`) | — | missing | the single choke point `git()` at `client:355` makes this a small add |
| Custom commands with git context | `:command` user commands (`src/app/ex_verbs.zig:279-381`), `init.lua` (`src/app/cmd_script.zig`) | — | partial | no `{{SelectedCommit}}`-style substitution of the git selection |
| Execute shell command (`:`) | Pty pane (`:term`), `worktree_shell` (`palette:902`) | Pty pane | none | |
| Diff context size (`{` `}`) | fixed `-U3` / `-U999999` (`client:465`) | fixed | missing | |
| Rename-similarity threshold (`(` `)`) | — | — | missing | `-M<n>%` |
| Toggle whitespace (`ctrl+w`) | — | — | missing | `-w` |
| Cycle diff renderer / pager (delta) | Hunk / Inline / Split in-app (`diff_view` `Mode`, `git.diff_toggle_view`) | same | n/a | mnml renders diffs itself; an external pager is the wrong shape here |
| External difftool (`ctrl+t`) | — | — | missing | `git difftool` in a Pty pane |
| Screen modes (`+` `_`) | pane maximise / splits (app-wide) | same | none | |
| Keybinding customisation | `specs` `.keys` + app keymap | app keymap | none | app-wide, not git-specific |
| Themes | app-wide | app-wide | none | |
| Check for update (`u` in Status) | `src/app/update.zig` | yes | none | |
| Edit config (`e`) | settings overlay / `:e` the TOML | yes | none | |
| Show all-branch logs (`a`) | `git.graph_filter_branch` / `graph_filter_clear` | same | none | the graph shows all refs by default |

### Files (working tree)

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Stage / unstage a file (`space`) | `git.stage` / `unstage` (`cmd_git:281-286`), status pane `s`/`u`/`space` (`git.zig:1887-1889`), WIP row `s`/`u` in the detail column (`git.zig:2376-2377`) | `src/git/stage.rs` | none | |
| Stage all (`a`) | `git.stage_all` / `unstage_all` (`client:597-606`) | same | none | |
| Stage lines (`enter` → `space` per line, `v` range, `a` hunk) | **hunk only**: `applyHunk` (`git.zig:1412`) via `parse.patchForHunk` (`parse:428`) → `apply_patch` job (`client:614`) | hunk only (FEATURES.md "per-hunk stage / unstage / discard") | partial | no line cursor, no range select, no synthesised sub-hunk patch |
| Edit hunk (`E`) | — | — | missing | opens the hunk in `$EDITOR`; in mnml the diff row already opens the file at that line (`openDiffLine`, `git.zig:2087`) |
| Discard file (`d`) | `git.discard` (confirm; `client:604`) | yes | none | |
| Discard hunk | `applyHunk(.discard)` (`x` in the diff pane, `git.zig:1990`) | yes | none | |
| Discard lines | — | — | missing | falls out of line staging |
| Reset / nuke working tree (`D`: soft / mixed / hard / `clean -fd`) | — (only `reset --soft` as the undo action, `client:811`) | — | missing | |
| Commit (`c`) | `git.commit` prompt; the graph's commit box `commitFromTextarea` (`git.zig:2342`) | yes | none | |
| Commit without pre-commit hook (`w`) | — | — | missing | `--no-verify` |
| Commit using git editor (`C`) | — | — | missing | the IDE *is* the editor: `GIT_EDITOR=mnml` on `COMMIT_EDITMSG` |
| Amend last commit with staged changes (`A`) | **message only**: `amend` job = `commit --amend -m` (`client:576-585`), driven by AI recompose | `src/git/commit.rs:18` message only | partial | `commit --amend --no-edit` is one job variant away |
| Find base commit for fixup (`ctrl+f`), create fixup (`F`), apply fixups (`S`) | — | — | missing | `commit --fixup=<sha>` + `rebase -i --autosquash` |
| Ignore / exclude file (`i`) | — (`.gitignore` only read for the tree) | — | missing | append to `.gitignore` / `.git/info/exclude` |
| Stash (`s`) / stash options (`S`: all / staged / unstaged / partial / keep-index) | `git.stash` = `stash push -u [-m]` (`client:660`) | `src/git/stash.rs` | partial | no staged-only / partial / keep-index |
| Filter files by status (`ctrl+b`), search (`/`) | status pane has no filter; the palette has one (`palette` `filter`) | — | missing | |
| Range select (`v`, shift-arrows) for bulk stage / discard | — | — | missing | |
| File tree view toggle, collapse / expand (`` ` `` `-` `=`) | flat A–Z list (`collectFiles`, `git.zig:1105`) | flat | missing | low value; the file tree pane already exists |
| Merge-conflict options (`M`: abort / continue / skip) | — (conflicts only *counted*: `parse:126`, summary `git.zig:2662`) | conflicts counted (`src/git/status.rs:29`) | missing | no `rebase --continue/--abort/--skip`, `merge --abort`, `cherry-pick --continue` |
| Upstream reset options (`g`: to upstream soft / mixed / hard) | — | — | missing | |
| Fetch (`f`) | `git.fetch` = `fetch --all --prune` (`client:644`) | yes | none | |
| Open / edit file (`o` `e`) | `git.open_file` (`cmd_git:296`), Enter in the detail column (`openDetailRow`) | yes | none | inherent to an IDE |
| Copy path (`ctrl+o`) | worktree path only (`palette:903`) | — | partial | |

### Main panel — staging / patch building / merging

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Hunk navigation (`h` `l`) | `n`/`p`, `]c`/`[c` (`moveHunk`, `git.zig:2036`), `]f`/`[f` files | yes | none | |
| Toggle hunk selection (`a`), range select (`v`) | cursor is a row; no selection state on `DiffPane` (`git.zig:170-200`) | — | missing | |
| Copy selected text (`ctrl+o`) | — | — | missing | |
| Custom patch builder (`ctrl+p`: pick lines from an *old* commit, then move to index / new commit / drop from commit) | — | — | missing | lazygit's "rebase magic" |
| Conflict UI: pick hunk / both, prev / next conflict, undo | — | — | missing | see §4.1 |
| Search in view (`/`) | `git.diff_filter` (`refilterDiff`, `git.zig:1277`) with `n`/`p` | yes | none | mnml *filters* to matching hunks rather than scrolling to matches |

### Commits (log)

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Commit graph | `graph_view.layout` lanes, WIP row, detail column | `src/git/graph.rs` | none | mnml's is richer (§2) |
| View files of a commit (`enter`) | `commit_detail` job (`client:556`), `drawDetail`, Enter opens the file diff | yes | none | |
| Interactive rebase (`i`), squash / fixup / reword / drop / edit / pick / move up-down | — (`rebase` job is `git rebase <branch>`, `client:642`; no `GIT_SEQUENCE_EDITOR` anywhere) | — (`src/git/branch.rs:256` plain rebase) | missing | the biggest gap |
| Rebase onto a marked base (`B`) | — | — | missing | `rebase --onto` |
| Amend an old commit with staged changes (`A` on any commit) | — | — | missing | fixup + autosquash |
| Amend commit attribute (`a`: author / co-author) | — | — | missing | `commit --amend --author` / trailer |
| Reword (`r` / `R`) | HEAD only, via AI recompose prompt (`git.ai_recompose`, prompt `.amend`) | HEAD only | partial | older commits need the rebase |
| Cherry-pick copy/paste (`C` / `V`, multi) | `git.cherry_pick` single (`c` in the graph, `git.zig:2294`) | yes | partial | no multi-select, no range |
| Revert (`t`) | `git.revert` (`v` in the graph) | yes | none | |
| Tag commit (`T`) | `git.tag` (annotated; message = name, `client:668`) | `src/git/tag.rs` | partial | no tag message / lightweight choice |
| Checkout commit (`space`, detached) | tags only (`tag_checkout`, `palette:983`) | — | partial | |
| New branch off commit (`n`) | `new_branch` = `checkout -b` from HEAD (`client:641`) | same | partial | needs a start point |
| Move commits to new branch (`N`) | — | — | missing | |
| New worktree from commit / branch (`w`) | `git.worktree_add` prompts path + branch (`cmd_git:666`) | yes | partial | not seeded from the selection |
| Reset to commit (`g`: soft / mixed / hard) | — | — | missing | |
| Bisect (`b`) | — (zero hits) | — (zero hits) | missing | |
| Copy sha (`ctrl+o`), copy attribute (`y`: sha / subject / message / author / URL) | `git.copy_head_sha` (HEAD only), `copy_current_branch` | same | partial | selected commit's attributes aren't copyable |
| Open commit in browser (`o`) | `git.browse_commit` (`remote.commitUrl`, 4 forges) | yes | none | |
| Open pull request in browser (`G`) | statusline PR chip (`src/app/statusline.zig:389`, `gh`-fed `rail.prs`) | `pr.picker` cross-host | none | Rust's cross-forge picker is not yet in Zig (`rail.gh` only) |
| Compare any two commits (`W`: mark, then diff against) | `DiffScope` is `file/head/worktree/staged/commit/orig` (`client:466-482`) | same | missing | no `A..B` scope |
| Log options (`ctrl+l`: order, show-graph, whole-file-history) | `git.graph_sort` (graph / date / author / subject), `git.file_history` | yes | none | |
| Filter by path / author | `git.file_history` (path), `git.graph_filter_author` / `_date` / `_subject` / `_branch` | yes | none | mnml is wider |
| Search (`/`) | `git.graph_jump_hash` + `graph_filter_subject` | yes | none | |
| Select commits of current branch (`*`) | — | — | missing | needs multi-select |
| External difftool (`ctrl+t`) | — | — | missing | |

### Local / remote branches

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Checkout (`space`), by name (`c`) | `git.checkout` picker, palette row / menu (`palette:871`) | `src/git/branch.rs` | none | |
| Checkout previous branch (`-`) | `git.recent_branches` (by commit date) | yes | partial | not "previous", `checkout -` |
| Force checkout (`F`) | — | — | missing | `checkout -f` |
| New branch (`n`) | `git.new_branch` | yes | none | |
| Delete (`d`, local / remote) | `git.delete_branch` (`branch -D`, confirm) | yes | partial | no remote-branch delete (`push origin --delete`) |
| Rebase onto (`r`) | `git.rebase` (`palette:873`) | yes | none | but no conflict continuation |
| Merge into current (`M`) | `git.merge` (`--no-edit`) | yes | none | |
| Fast-forward (`f`) | — (`pull --ff-only` only updates the *current* branch, `client:645`) | — | missing | `fetch origin b:b` |
| Rename branch (`R`) | — | — | missing | `branch -m` |
| Set / unset upstream, view upstream options (`u`) | auto `--set-upstream` on first push only (`client:650-652`) | same | partial | |
| Reset to branch (`g`) | — | — | missing | |
| Sort order (`s`: recency / alphabetical / date) | LOCAL fixed A–Z (`palette:512`); `git.recent_branches` picker | — | partial | |
| Create pull request (`o` / `O`), copy PR URL | — | — | missing | `gh pr create --web` or a forge URL |
| Git-flow (`i`) | — | — | missing | low value |
| Filter (`/`) | palette filter | rail filter | none | |
| Copy branch name | `git.copy_current_branch`, palette `Copy name` (`palette:869`) | yes | none | |

### Remotes · Tags · Stash · Reflog · Worktrees · Submodules

| lazygit | mnml-zig today | Rust mnml | gap | note |
|---|---|---|---|---|
| Remotes: list, fetch one, view branches | REMOTE section per remote (`palette:524`), `Fetch` / `Copy URL` menu (`palette:892-893`), `parse.parseRemotes` | rail | partial | fetch is `--all` |
| Remotes: add / remove / edit URL / add fork | — | — | missing | `remote add/remove/set-url` |
| Tags: new (annotated, with message), delete, push one, checkout, view commits | `git.tag` (message = name), `tag_delete`, `push_tags` (all), `tag_checkout` | `src/git/tag.rs` | partial | no per-tag push, no message |
| Stash: apply / pop / drop | `stash_apply` / `stash_pop` / `stash_drop` (`client:665-667`), STASHES menu (`palette:911-913`) | `src/git/stash.rs` | none | |
| Stash: rename (`r`), new branch (`n`), view files (`enter`) | — | — | missing | `stash branch`, `stash show` |
| Reflog: checkout / reset / cherry-pick / new branch from an entry | `git.reflog` picker → opens the commit diff only (`cmd_git:492`) | same | partial | view-only |
| Worktrees: new / switch / open / remove | `worktree_add` / `worktree_list` (open as workspace) / `worktree_remove` / `worktree_shell` / lock + dirty marks (`palette:573-574`) | yes | none | mnml is wider (§2) |
| Submodules: enter / update / init / add / remove / set URL / bulk | — (zero hits) | — (zero hits) | missing | |
| Confirmation prompts on destructive ops | `openConfirm` (`git.zig:1725`) for discard / delete / worktree remove / tag checkout | yes | none | |

## 2. What mnml has that lazygit lacks

| capability | where |
|---|---|
| A real DAG with coloured lanes, an always-present detail column (files + message) and a draggable divider | `graph_view.layout`, `drawDetail`; `dragGraphDivider` (`git.zig:2546`) |
| Sortable graph columns (graph / date / author / subject) + four composable filters + hash-jump | `git.graph_sort`, `git.graph_filter_*`, `findByHashPrefix` |
| The WIP row *inside* the graph: `Stage All` / per-file stage buttons and a commit textarea pinned to the detail column (`Ctrl+Enter` commits) | `wipButtonId` / `wipFileId` (`graph_view`), `wip_text` / `commitFromTextarea` (`git.zig:2342`) |
| AI commit messages from the staged diff (Claude or Codex) and AI recompose of HEAD, streamed into the commit box | `askAi` (`git.zig:743`), `git.ai_commit` / `codex_commit` / `ai_recompose` |
| One graph tab per repo, the branches panel taking the sidebar, closed-repo reopen | `palette.rebuildTabs`, `git.reopen_repo` |
| Branches panel with LOCAL / REMOTE(per remote) / WORKTREES / STASHES / TAGS, worktree **lock + dirty** marks, forge label, `Viewing N`, and **All repos** across a multi-root workspace | `palette.rows` (`:610`), `.locked` / `.dirty` (`:573`), `State.all` / `setAll` (`:370`) |
| Multi-repo discovery under one workspace, cycle with `Alt+[` / `Alt+]` | `git.discover` / `walkRepos` (`git.zig:423`), `git.next_repo` |
| Worktree as a first-class workspace: open one as the workspace, open a shell in one, add / remove | `git.worktree_list`, `worktree_shell` (`palette:962`) |
| Editor integration: gutter signs, blame gutter, `[c` / `]c` hunk jumps, peek-change popup, diff row → file at line, `:DiffOrig` | `marksFor`, `blameLabels`, `git.jump_*_change`, `git.peek_change`, `openDiffLine`, `git.diff_orig` |
| Diff pane with Inline and Split views plus intraline highlighting and a change-density strip | `diff_view` `Mode`, `src/git/intraline.zig` |
| Browse file / line / commit on GitHub, GitLab, Bitbucket Cloud + Server, Azure DevOps (15 remote shapes tested) | `src/git/remote.zig` |
| Explicit toolbar (Undo · Redo · Pull · Push · Fetch · Branch · Commit · Stash · Pop · Reflog) and right-click menus on every row | `src/ui/git_toolbar.zig`, `openGraphMenu` / `openRowMenu` (`git.zig:2532,2589`), `palette.openRowMenu` |
| Never blocks the UI: one worker thread per repo, `GIT_TERMINAL_PROMPT=0` | `client.worker` (`:311`), `:290` |
| Scriptable: a `git_status` hook event, `:command` user commands, `init.lua` | `git.zig:890`, `ex_verbs.zig`, `cmd_script.zig` |
| Rust-only for now: the cross-forge PR picker (`pr.picker` → `mnml-forge-*`) | Rust `FEATURES.md` Git section; Zig has `rail.gh` PRs only |

## 3. Ranked gap list — to surpass lazygit

Ordered by value to an IDE user. Surfaces: **graph** (graph tab + detail column), **status** (staging pane / WIP row), **diff** (diff pane), **branches** (the sidebar palette), **palette** (command palette / toolbar).

| # | gap | surface | git plumbing | effort | Zig note |
|---|---|---|---|---|---|
| 1 | **Interactive rebase**: squash / fixup / reword / drop / edit / pick / move, "edit this commit" | graph (multi-select rows → a plan) | `rebase -i <base>` with `GIT_SEQUENCE_EDITOR`, `--autosquash`; `GIT_EDITOR=true` for the messages we already know; `rebase --continue/--abort` | L | mnml is its own sequence editor: spawn `git -c sequence.editor='<mnml exe> --write-rebase-todo <plan>'`; that child mode overwrites the todo file and exits 0. New `Job.rebase_plan` in `client`; a `GraphPane.plan` overlay of row ops. Reword needs `-c core.editor=` pointed at a file we pre-write |
| 2 | **In-progress operation state + conflict resolution**: detect rebase / merge / cherry-pick / revert / bisect in flight; continue / abort / skip; resolve per file | status + diff + statusline chip; toolbar swaps to `Continue · Abort · Skip` | read `.git/{rebase-merge,rebase-apply,MERGE_HEAD,CHERRY_PICK_HEAD,REVERT_HEAD,BISECT_LOG}`; `diff --name-only --diff-filter=U`; `show :1:/:2:/:3:<path>`; `checkout --ours/--theirs -- p`; `add p`; `<op> --continue` | L | `parse.Status` already counts `conflicted`; add `Status.in_progress: enum`. The worker can poll those files in the existing status job. Resolution itself: §4.1 |
| 3 | **Line-level stage / unstage / discard with range select** | diff (visual-select rows), status | synthesise a sub-hunk patch → existing `apply_patch` job (`--cached`, `-R`) | M | generalise `parse.patchForHunk` to `patchForLines(f, hunk, lo, hi)` (recount the `@@` header, keep unselected `+` out / turn unselected `-` into context). `DiffPane` gains `anchor: ?usize` |
| 4 | **Amend**: last commit with the staged changes; amend *any* commit; fix author | graph (WIP row `A`; any row `A`), status | `commit --amend --no-edit`; `commit --fixup=<sha>` + `rebase -i --autosquash <sha>^` with `GIT_SEQUENCE_EDITOR=true`; `--amend --author` | S / M | the `--no-edit` case is one `Job` variant + `pushUndo(reset_soft)`; the older-commit case rides on #1's plumbing but needs no plan UI |
| 5 | **Reset**: soft / mixed / hard to a commit or branch, "nuke" the working tree, reset to upstream | graph row menu, branches row menu, status | `reset --soft/--mixed/--hard <rev>`; `checkout -- . && clean -fd` | S | confirm + undo: record HEAD and `stash create` before `--hard` so `git.undo` can restore |
| 6 | **Diff any two refs / mark a compare base / branch vs current** | graph (`W` marks), branches (`Diff against current` menu row), diff | `diff A..B` / `A...B`, `diff <branch>`; `log A..B` | M | `client.DiffScope` gains `.range{from,to}`; `GraphPane.compare_base: ?sha`; the graph could tint rows in `A..B` |
| 7 | **Branch verbs**: rename, fast-forward, set upstream, force checkout, delete on the remote, new branch / worktree from a *commit or tag*, force-push-with-lease | branches menus, graph menu, toolbar Push ⌥ | `branch -m`, `fetch origin b:b`, `branch -u`, `checkout -f`, `push origin --delete b`, `checkout -b b <sha>`, `push --force-with-lease` | S each | `Job.new_branch` gains `start: ?[]u8`; force-push behind a confirm (Rust refused it on principle — `src/git/sync.rs:14` — decide deliberately) |
| 8 | **Undo/redo breadth** — every mutating op undoable | palette / toolbar | reflog-based: snapshot `HEAD`, the branch ref and (for tree-touching ops) `stash create` before each op; undo = `reset --hard <sha>` + `stash apply` | M | extend `client.Action` with `reset_hard{sha, stash: ?sha}`; push in `simple()` for merge / rebase / cherry-pick / revert / reset / stash; lazygit reads the reflog after the fact — mnml can record *before*, which is safer |
| 9 | **Stash depth**: staged-only / selected files / keep-index; view a stash's files; branch from a stash; rename | branches STASHES rows, status (selected rows → `Stash selected`) | `stash push --staged`, `stash push -- <paths>`, `--keep-index`, `stash show --name-status -p`, `stash branch`, drop+`stash store -m` | M | `Job.stash` becomes a struct `{msg, paths, staged_only, keep_index}`; a stash row's detail reuses `commit_detail` on `stash@{n}` |
| 10 | **Command log pane** (every argv the worker ran, exit, duration, stderr) | palette command → a pane; a toast links to it | none — instrument `client.git()` | S | one ring buffer on `Repo`, an `AppEvent.git` payload `.log_line`; makes every "why did that fail" answerable and doubles as the record of an AI-driven session |
| 11 | **Copy commit attributes + multi-select** (sha / subject / body / author / URL; `*` = the current branch's commits) | graph | `log -1 --format=…`; `remote.commitUrl` | S | multi-select on `GraphPane` unlocks #1, cherry-pick ranges and "move commits to new branch" |
| 12 | **Custom patch builder**: pick lines out of an *old* commit → move to index / to a new commit / drop from that commit | diff (on a commit diff) → verbs | `format-patch`/`apply` per selection then `rebase -i` with `edit` on the commit; or `checkout <sha>^ -- p` + `apply` | L | reuses #3's selection and #1's rebase driver; ship after both |
| 13 | **Bisect** | graph (mark good / bad / skip; rows tinted; `Bisect: reset`) | `bisect start/good/bad/skip/reset`, `bisect log` | M | graph rows carry a `bisect: ?enum` from `bisect log`; the statusline shows "bisecting, N steps left" |
| 14 | **Remotes + submodules management** | branches REMOTE rows (add / remove / set URL), a SUBMODULES section | `remote add/remove/set-url`, `submodule status/update --init/add/deinit` | M | `parse.parseRemotes` exists; add `parseSubmodules` from `submodule status`; entering a submodule = `git.switch_repo` on its path |
| 15 | **Small knobs**: diff context size, whitespace toggle, rename threshold, `commit --no-verify`, commit via editor buffer, ignore / exclude file, external difftool, per-tag push with message | diff toolbar chips; commit box; status row menu; TAGS menu | `-U<n>`, `-w`, `-M<n>%`, `--no-verify`, `GIT_EDITOR`, append to `.gitignore`, `difftool`, `tag -a -m`, `push origin <tag>` | S each | `DiffPane` gains `context: u8`, `whitespace: bool` and the worker reads them; the commit box gets a `--no-verify` chip |

## 4. Three things to do better than lazygit — not just match

### 4.1 Resolve conflicts in the real editor, three-way, with the diff pane's Split view

lazygit resolves in a read-only viewer: pick a hunk side, `b` for both, blind to the rest of the file. mnml already owns the buffer, the Split view (`diff_view.drawSplit`), intraline highlighting and LSP. Do it there:

- On a conflicted file the editor buffer opens as usual; the diff pane docks beside it in Split with **ours | theirs** from `show :2:` / `:3:` (base `:1:` on a third strip, toggled). Each conflict block is a hunk; `o` / `t` / `b` write that side into the *buffer* (not the index), the `<<<<<<<` markers vanish, LSP diagnostics keep running on the result, and the user can still edit by hand between picks.
- `]x` / `[x` walk conflicts across files; the gutter marks them like signs.
- `Enter` on the last conflict = save + `git add` + `<op> --continue` in one keystroke; the toolbar shows `Continue · Abort · Skip` while the op is in flight (gap #2).
- The AI hook is free: "resolve this block with Claude" uses the same `askAi` route the commit box does, given base / ours / theirs.

### 4.2 The graph *is* the rebase plan

lazygit's rebase is a TODO list rendered as a log. mnml's graph already has the rows, a detail column, sort, and a drag model (`dragGraphDivider`). Make the plan editable in place:

- `i` on a commit enters plan mode from that commit up: rows become draggable (mouse) and `J` / `K` move them; `s` / `f` / `r` / `d` / `e` set the op glyph in the lane column; a reworded message is typed *in the detail column*, an AI reword comes from the existing commit-box route; a squash is a drop-onto.
- The graph re-lays out **live** — the lanes show what the branch will look like, with "will conflict" rows tinted from a dry `merge-tree` per step.
- `Ctrl+Enter` executes with mnml as `GIT_SEQUENCE_EDITOR` (gap #1); if a step stops, the graph stays in plan mode with the stopped row highlighted and 4.1 takes over; `Esc` aborts. Undo (gap #8) restores the ref.
- Autosquash-aware: `F` on a WIP change creates a `fixup!` for the selected commit and the plan pre-fills.

### 4.3 One selection model in the diff pane, many verbs

lazygit has three separate main-panel modes (staging, patch building, merging), each with its own keys. mnml can use one: **visual selection of rows in the diff pane** (gap #3), then a verb:

- `s` stage · `u` unstage · `x` discard · `S` stash the selection · `c` commit the selection (the AI commit box writes the message from *only* those lines) · `m` move the selection to commit X (patch-builder, gap #12) · `y` copy the text.
- It works identically on a worktree diff, a staged diff, an old commit's diff and a stash's diff — the scope is the pane's, the verb is the same, no mode to remember.
- Because the pane is also a hit-tested UI (`diffClick`, `git.zig:2124`), the same selection is a mouse drag, and the verbs are the right-click menu. That is a thing a terminal git UI has never had: the mouse-first path and the vim path are the same feature.
