# Parity notes — branch `search` (2026-09-05)

The `docs/PARITY.md` rows this branch flips, with the file that proves
each one. PARITY.md itself is the ledger and is edited at merge time,
not here.

## Remaining table (`## Remaining`)

| Row | Was | Now | Proof |
| --- | --- | --- | --- |
| Workspace grep: rg spawn, a results pane, cross-file replace with a per-hit toggle (`find.grep`, `find.grep_replace`, `view.activity_search`) — L | remaining | done | `src/app/grep.zig` tests "walk backend: literal + smart case, .gitignore honoured…", "rg backend: the same tree through `rg --json`…", "rg backend: a stand-in rg proves the --json stream is parsed…", "find.grep opens the pane beside the editor; hits land grouped by file; n steps, fold, filter, toggle", "grep replace: open clean buffer through EditOps and saved, closed file on disk, dirty buffer refused, disabled hit kept", "grep: a stale batch is dropped; the pane's deinit cancels a worker mid-run"; `src/ui/grep_view.zig`; `tests/e2e-zig/grep_pane.test` |
| Multi-root workspaces + the `AddWorkspace` directory-completion prompt + repo switcher — L | remaining | done | `src/app/tree.zig` tests "multi-root: cfg.workspaces become collapsed sections…", "multi-root: view.add_workspace prompts, Tab completes a directory segment and cycles…"; `src/app/git.zig` test "discover: every extra workspace root brings its repo…"; `tests/e2e-zig/jumplist_workspaces.test` |
| A regex engine for find and `:s` (`TODO(find-regex)`; the UI toggle exists) — M–L | remaining | done | `src/regex/regex.zig` (Oniguruma via ghostty's `pkg/oniguruma`) tests "regex: vim-pattern conformance table" (106 rows), "regex: find from an offset, findAll, groups, and the error kinds", "regex: :s replacement expansion…"; `src/regex/vim.zig`; `src/app/cmd_find.zig` test "find: ctrl+r turns the query into a vim pattern; replace expands groups; a bad pattern says so"; `src/app/ex.zig` test "ex: substitute is a vim pattern — groups, &, \\<\\>, \\v, a bad pattern"; `src/app/ex_verbs.zig` test "ex: :g, :s///n and :s///c take vim patterns — word bounds, a group reference under c, a bad pattern" |
| Jumplist (`nav.back` / `nav.forward` / `nav.jump_toggle_prev`) — a ring on `App` plus the push points — S | remaining | done | `src/app/jumplist.zig` tests "jumplist: G / gg / {N}G push; Ctrl+O walks back 7, 4, 1; Ctrl+I forward…", "jumplist: `` toggles with the position before the last jump; a search hit is a jump", "jumplist: opening another file pushes; nav.back returns to the file and row; the cap holds", "jumplist: nav.back as a command (no key) does not record its own landing on the next key" |

## `## Navigation & search` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| In-buffer find — regex | missing | done | `find.zig` (`regex` flag, `bad_pattern`), `cmd_find.zig` | `ctrl+r` / the `.*` chip / `find.toggle_regex` recompute live; sticky per pane; a bad pattern toasts why |
| Workspace grep → results pane | missing | done | `grep.zig`, `ui/grep_view.zig` | `rg --json` when on PATH, else the gitignore walk + `src/regex/`; batches of 64, cap 5000 |
| Cross-file replace, per-hit toggle | missing | done | `grep.replaceAll` | Space disables a hit, `A` / `D` all; clean open buffers via `EditOp`s then saved, closed files on disk, dirty buffers refused |
| Jumplist `Ctrl-O` / `Ctrl-I` | missing | done | `jumplist.zig`, `dispatch.key` | two stacks capped at 100; `''` / ``` `` ``` toggle |
| Multi-root workspaces + repo switcher | missing | done | `tree.zig` (`Root`, `syncRoots`, `addRoot`, `switchTo`), `git.discover` | `cfg.workspaces` as collapsed sections; `view.add_workspace` Tab-completes; `view.switch_workspace` is a picker; every root's repo on the GIT rail |
| Which-key `f` find (`f g` → `find.grep`) | partial | done | `grep.zig` | the runner exists |

## `## Editing & input` table

| Row | Was | Now | Where | Note |
| --- | --- | --- | --- | --- |
| Ex `:%s/old/new/flags` | done (editor-ex; substring) | done, vim patterns | `ex.zig` `substitute` / `compilePattern`, `ex_verbs.zig` `scanMatches` / `lineHas` | pattern is a vim pattern for `:s`, `:s///c`, `:s///n`, `:&` and `:g` / `:v`; `&`, `\0`–`\9`, `\u \l \U \L \E`, `\n \t` in the replacement, expanded per match under `c` |

## Counts

Command ids: 901 — unchanged; every search-track id was already in the
spec table and now has a runner (`find.grep`, `find.grep_replace`,
`view.activity_search`, `nav.back`, `nav.forward`,
`nav.jump_toggle_prev`, `view.add_workspace`, `view.switch_workspace`).
`docs/commands.md` regenerated (`picker.files` lost `ctrl+o` in the vim
profile — that chord is the jumplist).
