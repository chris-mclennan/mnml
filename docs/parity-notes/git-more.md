# Parity notes — branch `git-more` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| Diff pane Inline + Split views, intraline highlighting, the density minimap, the `/`-filter — L | remaining | done | `src/ui/diff_view.zig` tests (split alignment `pairs`, `density`, `filterRows`, the intraline paint); `src/git/intraline.zig` tests; `tests/e2e-zig/git_diff_views.test` |
| Graph detail panel, sortable columns, hash-jump, the WIP row with staging buttons — S–M | remaining | done | `src/ui/git_graph_view.zig` tests (`sortOrder`, `findByHashPrefix`, the WIP buttons + detail panel paint); `src/app/git.zig` tests "the graph pane lays out the log…" and "the WIP row…"; `tests/e2e-zig/git_graph_detail.test` |
| Branch rail (branches / worktrees / open PRs as a collapsible section) — M | remaining | done | `src/app/git.zig` test "the branch rail: toggling it…"; `src/ui/git_status_view.zig` test "rail rows…"; `src/git/parse.zig` tests `parseTrack` / `parsePrs` |
| AI commit messages (`git.ai_commit` / `codex_commit` / `ai_recompose` are `notInBuild` stubs) — M | remaining | done | `src/app/cmd_git.zig` runners `aiCommit` / `codexCommit` / `aiRecompose`; `src/app/git.zig` `askAi` / `aiContextReady` / `pollAiWait`, test "cleanCommitMessage…"; `src/app/ai.zig` `askProduct` (the `// ── git ──` block) |
| Browse-a-commit on the remote; the provider badge — S | remaining | done | `src/git/remote.zig` table test (15 remote shapes × file / line / commit); `src/ui/git_status_view.zig` badge test; `git.browse_commit` in `cmd_git.zig` |

## `## Git` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Clickable provider badge | missing | done | `status_view.drawPane` (`badge_id`), `git.State.provider` | the status pane's header; a click runs `git.browse_commit`; the rail subtitle names the forge |
| Diff pane — Inline view | missing | done | `diff_view.Mode.flat`, `drawUnified` | the whole file (`-U999999`), one number column, changed rows tinted |
| Diff pane — Split view | missing | done | `diff_view.pairs`, `drawSplit`, `git.dragDivider` | removed runs zipped with added runs; the divider drags (15–85 %) |
| Intraline highlighting | missing | done | `src/git/intraline.zig`, `diff_view.rangesFor` | prefix / suffix peel then LCS, capped at 64 K cells |
| Diff `/`-filter | missing | done | `diff_view.filterRows` / `filterSplitRows`, `git.refilterDiff`, `git.diff_filter` | hunks holding the needle, their file headers; `n` / `p` walk the matches |
| Change-density minimap | missing | done | `diff_view.density`, `drawStrip`, `stripCellRow` | one cell per band on the right edge, the visible window as its thumb, clickable |
| Graph — detail panel | missing | done | `git_graph_view.drawDetail`, `git.requestDetail` / `openDetail`, `Job.commit_detail` | enter opens it, tab focuses it, enter on a file opens that file's diff in the commit; the width drags |
| Graph — sortable columns | missing | done | `git_graph_view.sortOrder`, `git.setSort` / `clickSort`, `git.graph_sort` | GRAPH / DATE / AUTHOR / SUBJECT chips; `s` cycles; the lanes fold to a dot off git's order |
| Graph — hash-jump | missing | done | `git_graph_view.findByHashPrefix`, `PromptKind.graph_hash`, `git.graph_jump_hash` | `/` in the pane |
| Graph — WIP row + staging buttons | missing | done | `git_graph_view.drawWipRow`, `git.syncWip`, `graphClick` | `[stage all] [unstage all] [commit…]` through the worker; `a` / `A` / `c` on the row |
| Branch rail | missing | done | `git.appendRailRows` / `requestRail` / `toggleRail`, `Job.rail`, `git.branch_rail_toggle` | three folding sections under the status groups; `b` in the rail; enter on a branch asks before checkout, `x` before delete; PRs via `gh pr list --json`, a toast when `gh` is missing |
| AI commit message (claude) | missing | done | `git.askAi(.staged, .claude)` | the staged diff through the worker, the job through `ai.askProduct`; the commit prompt opens prefilled |
| AI recompose HEAD | missing | done | `git.askAi(.head, …)`, `Job.amend` | with the commit prompt open it recomposes that message instead |
| AI commit via Codex | missing | done | `git.askAi(.staged, .codex)` | the `codex exec` route; its `api` route is refused with a reason |
| Browse current commit | missing | done | `remote.commitUrl`, `Job.browse{ .kind = .commit }`, `git.browse_commit` | the graph's selected commit, a commit diff pane's, else HEAD |

Rows that stay as they are: the two cut forge rows (`pr.picker`,
`pr.refresh`).

## Counts

`## Git` in the summary table moves from 22 done / 0 partial / 2 cut /
15 missing to 37 done / 0 partial / 2 cut / 0 missing. Command ids: 890
(881 at the `panels` merge, plus `git.diff_toggle_view`, `git.diff_filter`, `git.graph_detail`,
`git.graph_sort`, `git.graph_jump_hash`, `git.branch_rail_toggle`,
`git.browse_line`, `git.browse_file`, `git.browse_commit`), every one
with a runner; `docs/commands.md` regenerated.

## Checks run

On the branch rebased onto `main` at `153a4a8` (the `editor-ex` merge):

- `zig fmt --check src build.zig`: clean.
- `zig build test` (Debug and `-Doptimize=ReleaseSafe`): 907/908 —
  829 in the main test binary, 1 skipped by design.
- `mnml-zig test --gate --sizes 80x24,120x40,200x60`: 141/141.
- `MNML_E2E_ALLOW_SHELL=1 mnml-zig test` (the whole corpus): 249/250 —
  the two new scripts pass; the one failure is
  `settings_persist_to_workspace.test`, which asserts TOML by design.
- `zig build gate-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe`: builds.
- Break-checks (`tools/break-check.sh`), each confirmed in the file by
  the tool before the run:
  - `tools/break-check.sh "findByHashPrefix" src/ui/git_graph_view.zig 's/std\.ascii\.eqlIgnoreCase(c\.hash\[0\.\.p\.len\], p)/std.mem.eql(u8, c.hash[0..p.len], p)/'`
    — the case-sensitive match fails the `findByHashPrefix` test.
  - `tools/break-check.sh "the branch rail" src/git/parse.zig 's/%1f/%x1f/g'`
    — `for-each-ref`'s escape back to `%x1f` fails the branch-rail test.
  - `tools/break-check.sh "the WIP row paints its three buttons" src/ui/git_graph_view.zig '412{h;d;};413{G;}'`
    — the WIP row's hit registered after its buttons fails the WIP
    buttons paint test.
