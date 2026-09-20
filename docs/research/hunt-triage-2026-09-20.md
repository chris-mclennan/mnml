# Hunt triage — 2026-09-20

What the six bug-hunt personas found, re-checked against main at `70e9396`.

## What was triaged

`.mnml/findings/` holds two kinds of thing, and the difference decides
most of the verdicts before any script runs.

**81 per-finding files**, tracked, one per bug, each with `severity:` /
`status:` front matter and a closing `## Fix` section naming a commit, a
branch and the regression `.test` it added. Seventy-nine say `fixed`,
two say `rejected`.

**Two persona summaries**, both untracked, written 2026-09-09 —
`hunt-standard-2026-09-09.md` (21 findings, standard profile,
mouse-first) and `hunt-vim-2026-09-09.md` (22 findings plus two
seen-once notes, NvChad muscle memory).

Both summaries were worked, and the first draft of this document said
otherwise. `docs/PARITY.md:107` records a `vim-fixes` track merged
2026-09-12 that names `hunt-vim-2026-09-09.md` and lists the behaviors
it closed, and `src/app/lsp.zig` carries two source comments citing it.
The standard report is cited nowhere at all — a grep across `docs/`,
`src/` and `tests/` that finds the vim report three times finds the
standard report zero — which made it look untouched. It was not: the
merge `3abbc200` ("Merge branch `std-fixes`", 2026-09-10) describes the
standard-profile findings in its body without ever naming the file.

The lesson is small and worth keeping: a fix track that does not cite
the report it came from is indistinguishable, later, from a report
nobody read. The vim track is auditable; the standard track had to be
rediscovered from commit prose.

## The per-finding fixes did reach main

The hunt work was done on branch `hunt`, whose head `511b6b6c` is *not*
an ancestor of `main`. That looks alarming and is not: the branch was
merged by patch, not by fast-forward. `git cherry HEAD 511b6b6c
4ea0a6bb` reports 63 of its 64 commits already present in main by
patch-id, and the rebased ones match by subject.

One commit did not make it:

```
b513f8e4  the five unread ui.* fields now do something:
          external_browser, click_echo, coverage_chip_mode,
          menu_bar, auto_equalize_splits
```

Every regression `.test` named by a `## Fix` section exists in
`tests/e2e/` today, and the full corpus is green: **668/668 passed**.

## Method

Built ReleaseSafe in an isolated worktree and drove the `.test` runner:

```
zig build -Doptimize=ReleaseSafe
./zig-out/bin/mnml-zig test <script>
```

Each `.test` file gets a fresh temp workspace and a private data root,
so files do not contaminate each other. Vim findings enter the profile
with the step `command editor.use_vim` — inside the runner there is no
CLI flag for it.

Classification:

- **fixed-since** — an assertion of the behavior the finding called
  *correct* passes on main.
- **still-reproduces** — that assertion fails on main.
- **by-design** — main does it differently on purpose, and the repo says
  so somewhere citable.
- **cannot-reproduce** — the preconditions could not be established.

### On trusting a green assertion

Two of this repo's own lessons shaped how the checks were run: a test
can pass because it asserts nothing, and a break-check can look clean
because the break never landed in the file. So a `fixed-since` verdict
resting on a passing script was accepted only after the expectation was
deliberately broken and the runner was watched to fail on that line.
Verdicts resting on reading source rather than running it are marked as
such rather than dressed up as reproductions.

Two live examples of why that matters, both hit during this pass:

- Passing a shell variable of 44 paths to the runner unquoted made it
  one argument. The runner read the joined string as a directory, found
  no `.test` files in it, and printed `0/0 passed` — exiting **0**. A
  green run that tested nothing. Word-splitting the same list gave
  `44/44 passed`.
- One finding's own "Expected" section is wrong about main, and main is
  right. `nvchad-leader-second-key-eaten` asserts that `<leader>e`
  should *toggle* the tree. Main focuses the sidebar on `<leader>e` and
  toggles on `Ctrl-N`, which is what real NvChad does
  (`NvimTreeFocus`). A future pass should not "fix" main to match the
  finding.

## Fixed on branch `hunt-fixes` (2026-09-20)

Every still-reproducing finding below, and both harness traps, were
worked on that branch. Each repro script moved out of
`docs/research/hunt-repros/` into `tests/e2e/` under the corpus's naming,
where it now passes; the directory is gone. The per-finding sections
keep the original diagnosis and name the script's new home.

The two harness traps are closed too:

- **A path the runner cannot find is a hard error.** `collectFiles`
  returns `error.PathNotFound` instead of an empty list; `runPath` prints
  `mnml-zig test: no such path: <p>` and `mnml-zig test` exits **2**. A
  joined path list therefore fails loudly rather than reporting `0/0
  passed`. Unit-tested in `src/e2e/runner.zig` against both a missing
  path and a space-joined pair of real ones.
- **`tests/e2e/http_directives_not_body.test` reaches the crash site.**
  It sends to the runner's own `serve … @echo` fixture and asserts the
  echoed wire, and it carries a third block — a GET with a REAL body,
  which is the case that reaches `sendInner`'s `sendBodyUnflushed`.

## Where the repro scripts lived

`src/e2e/parser.zig` accepts exactly five header directives —
`requires:`, `width:`, `height:`, `env:` and `shared-data-root`. There
is no expected-fail directive: nothing in `src/e2e/` or `src/main.zig`
matches `expected[_-]?fail|xfail|known[_-]?fail|should[_-]?fail`, while
the same grep finds five hits for `requires_network`, so it is a live
query and not a typo that matched nothing.

A script committed under `tests/e2e/` therefore has no way to say "this
is a known failure" — it would simply turn the suite red. The
reproductions for still-reproducing findings are committed under
`docs/research/hunt-repros/` instead, runnable by hand and harmless to
the gate:

```
./zig-out/bin/mnml-zig test docs/research/hunt-repros/<slug>.test
```

Each asserts the behavior the finding says is *correct*, so each fails
today. When one is fixed, its script can move into `tests/e2e/`
unchanged and become the regression test.

## Result

| | findings | fixed-since | still-reproduces | by-design | cannot-reproduce |
|---|---:|---:|---:|---:|---:|
| `nvchad` + `nvchad2` (per-finding) | 45 | 44 | 0 | 1 | 0 |
| `vscode` + `vscode2` + `api` + `multilang` (per-finding) | 36 | 34 | 1 | 1 | 0 |
| `hunt-standard-2026-09-09` (summary) | 21 | 13 | 4 | 2 | 2 |
| `hunt-vim-2026-09-09` (summary) | 24 | 23 | 1 | 1 | 0 |
| **total** | **126** | **114** | **6** | **5** | **2** |

Counts exceed 84 because three standard findings (1, 13, 14) split — part
fixed or by-design, part still open — and are counted in both columns.
The vim row includes the two seen-once notes.

One finding is not from either report: it was found while triaging
standard #1 and #13, and it is the most serious thing in this document.

## Still-reproducing, ranked by user impact

### 1. A bare `ctrl+k` shadows all eighteen `ctrl+k …` standard chords — SEV-2, new — **fixed (this branch)**

`whichkey.leader` binds a bare `ctrl+k` in the standard profile
(`src/commands/specs.zig`, `.standard = &.{"ctrl+k"}`). Pressing it opens
the which-key overlay, whose handler consumes the next key. Eighteen
standard chords are spelled `ctrl+k <key>`:

```
view.fullscreen  view.close_others  view.focus_right_panel  keys.edit
tab.new  theme.toggle  view.switch_workspace  view.activity_sessions
git.blame_toggle  git.commit  lsp.hover  integrations.show_details
view.focus_left  view.focus_right  view.focus_up  view.focus_down
view.sidebar_pin  view.keep_tab
```

None can fire in the profile that declares them. A character tail toasts
`no leader mapping: <leader>z`; a modified tail (`ctrl+i`, `ctrl+left`)
is dropped silently with the popup left open. `Ctrl+K Ctrl+I` for
`lsp.hover` is actively advertised in the Info panel, so the app is
telling standard users to press a chord it has disabled.

This is why standard #1's "`Ctrl+K Z` does nothing" survived a fix pass
that correctly repaired the rest of zen mode: the chord never reaches
`view.fullscreen` at all.

```
was: docs/research/hunt-repros/standard-ctrl-k-prefix-shadowed.test
  FAIL line 19: screen unexpectedly contains "no leader mapping"
now: tests/e2e/chord_ctrl_k_prefix.test — passes
```

### 2. The tree's delete confirm cancels with no feedback — SEV-3, a regression with its test rewritten — **fixed (this branch)**

`vscode-delete-dialog-enter-cancels-silently` still reads `status: fixed`
and is not. The fix `387d7a9c` (2026-09-05) made Enter the default
action. Two days later `fcb8b5e6` ("prompts and confirms as Rust paints
them") set `src/app/trash.zig:236` back to `.selected = choices.len - 1`,
and `tests/e2e/tree_delete_enter.test` was rewritten to assert the
behavior the finding had reported as the bug:

```
key enter
expect screen lacks "a.txt?"
expect file a.txt contains "aa"
```

Half of that revert is defensible and cited in the source — "Cancel is
the focus, as in Rust: a destructive box's Enter must not be the
destructive act". The other half is not: pressing Enter tears the dialog
down with **no toast and no statusline line**, which on screen is
indistinguishable from a delete that worked. Nothing anywhere defends
the silence. The committed repro asserts only that undefended half.

```
was: docs/research/hunt-repros/vscode-delete-dialog-enter-cancels-silently.test
  line 22 (file survives — the by-design half) passes
  FAIL line 24: screen does not contain "cancel"
now: tests/e2e/tree_delete_cancel_toast.test — passes
     tests/e2e/tree_delete_enter.test corrected: it asserted the silence
```

The finding file IS tracked here —
`.mnml/findings/vscode-delete-dialog-enter-cancels-silently.md`, one of
the 81 — and its `## Fix` section, which named only `387d7a9c`, now
records the revert and what this branch actually closed. `status:` stays
`fixed`, because it is.

### 3. The standard profile's which-key popup lists vim chords — SEV-3 (standard #13, second half) — **fixed (this branch)**

The Info panel was fixed (`14cb7d9b`) and now reads `[F12] Definition ·
[Shift+F12] References · [Ctrl+K Ctrl+I] Hover · [F2] Rename`. The
overlay behind `Ctrl+K` was not: it is still titled `┌ <leader> ─` and
lists NvChad groups (`harpoon`, `+nvchad`, `+split`) to a user who has no
leader. Same root cause as #1.

```
was: docs/research/hunt-repros/standard-13-which-key-shows-vim-chords.test
  FAIL line 12: screen unexpectedly contains "┌ <leader> "
now: tests/e2e/whichkey_standard_title.test — passes
```

### 4. Tab-strip overflow never shows a hidden count — SEV-3 (standard #12) — **fixed (this branch)**

The `+N hidden` chip exists (`0e3c7a66`) but `src/ui/bufferline.zig:465`
paints it only when the strip is scrolled to a tail that fits whole —
never in the ordinary case where the active tab is cut at the edge. With
twelve buffers at 120x40 nothing says buffers are missing; labels still
clip to `ddd`. Partly mitigated since the report: the `‹ ›` arrows now
paint and are clickable, so it is no longer strictly silent.

```
was: docs/research/hunt-repros/standard-12-tab-strip-no-hidden-count.test
  FAIL line 35: screen does not contain " hidden "
now: tests/e2e/tab_strip_hidden_count.test — passes
```

### 5. Session restore re-spawns terminal panes as live shells — SEV-3 (vim #22) — **fixed (this branch)**

`src/app/session.zig:261-266` saves shell and command ptys; `:621-628`
calls `pty_pane.open` on restore. Relaunching after a session that had a
shell open brings the shell back running. Neovim's `:mksession` does not
restore `:terminal` buffers as live processes, and a shell that starts
itself in a workspace is a surprise. Not in `PARITY.md`'s `vim-fixes`
list; no doc or source comment defends it.

```
was: docs/research/hunt-repros/vim-22-session-restores-terminal.test
  FAIL line 11: file .mnml/session.zon unexpectedly contains "zsh"
now: tests/e2e/session_restore_terminal_dormant.test — passes. The
     assertion moved with the fix: the pane IS saved (losing the tab
     would be its own bug); it comes back DORMANT, `[exited] — any key
     restarts`, which is the half the finding was about.
```

### 6-7. The two remaining, both SEV-3 cosmetic — **both fixed (this branch)**

**Standard #10 — a titled context menu paints one blank row above its
bottom border.** `menuSize` (`src/app/render.zig:2536`) returns
`h = rows + title_rows + 2`, but the title is painted *inside* the top
border, so a titled menu is one row too tall. Dropdowns
(`h = rows + 2`) are correct, which is why the `»` popup has no blank
row. `standard-10-menu-blank-row.test`, FAIL line 14 → `tests/e2e/menu_title_no_blank_row.test`, passes.

**Standard #14 (second half) — the palette box re-anchors as you type.**
`picker.placeWith` sizes the box from the filtered count and
`overlay.place` re-centres it, so the box slides down the screen as the
list shrinks. `standard-14-palette-box-reanchors.test`, FAIL line 18 → `tests/e2e/palette_box_anchor.test`, passes.
(The first half of #14, the wheel moving three rows per event, is
by-design — `src/app/dispatch.zig:1979` documents it as Rust parity.)

## By-design (5)

| finding | why |
|---|---|
| `nvchad2-vblock-cursor-past-eol-short-line` | Block corners are virtual columns (`:help visual-block`, `:help v_b_I`). Real `vim -es -u NONE` reproduces mnml's output exactly; the finding's "expected" clamp is Normal-mode behavior. |
| `multilang-http-history-commands-noop` | Did not reproduce on the hunt's own build. `http.history` opens with both rows; the toast the report quoted is drawn below the excerpt it pasted. `tests/e2e/http_history_picker.test` passes. |
| standard #18 — AI chip spawns `claude` with no confirm | `docs/PARITY.md` (3b8cd89d): Rust's chip spawns at once by design; no `ui.confirm_ai_launch` key exists on either side. |
| standard #14 (wheel half) | `src/app/dispatch.zig:1979-1986` — `wheel_lines` rows per event is Rust's three, deliberately. The list does scroll once the cursor leaves the window. |
| vim #13 (`<leader>th` only) | `<leader>th` is `view.toggle_hidden` on purpose (`whichkey.zig:193`); NvChad's themes picker sits on `<leader>tt`. The other six chords in that finding were bound by `4242bdbe`. |

## Cannot-reproduce (2)

Both are standard-report items already marked *(seen once)* by the
hunter.

**#20 — `status.json` listed the workspace roots with nothing open.**
The exact repro now gives `"panes":[]`. `driver.statusOf` builds the
list strictly from `app.panes.slots`, so only real open panes can
appear. Break-checked.

**#21 — a raw git error in the statusline after Stage All.** Scripted
`git init` → status pane → Stage All → Unstage All → Stage All leaves
no `error:` or `fatal:` on screen.

## Fix tracks

One line each, in the order worth doing them. Items 1-7 shipped on
`hunt-fixes` (2026-09-20); item 8 is still open.

1. ~~**Unbind bare `ctrl+k` from `whichkey.leader` in the standard
   profile.**~~ Done differently, and better: the binding stays, and
   **chord resolution wins over the overlay**. `keymap.resolveSeq`
   already answered `pending_with_fallback` for a chord that is bound on
   its own AND a prefix, and `chordChain` already honoured it — what did
   not was `app/driver.zig`'s `expireChords` hook, which fired every
   pending fallback the moment it was called, so a driven run opened the
   popup on the `ctrl+k` and ate the tail. It reads the deadline now, as
   `App.tick` always has. The eighteen chords work, and a lone `ctrl+k`
   plus a pause still shows the popup — unbinding it would have cost the
   standard profile its which-key door. Pins unchanged.
2. ✅ **Give the delete confirm a cancel toast**, and correct
   `tests/e2e/tree_delete_enter.test` so it stops pinning the silence —
   then flip the finding's front matter off `status: fixed`.
3. ✅ **Title the standard profile's which-key overlay from the active
   profile** rather than always as `<leader>`, once (1) makes it
   reachable again.
4. ✅ **Paint `+N hidden` whenever any tab is off-strip**, not only on a
   whole-tail scroll (`src/ui/bufferline.zig:465`).
5. ✅ **Stop restoring shell ptys as running processes** — persist the pane
   and let the user start it, or restore it exited.
6. ✅ **Subtract the title row from `menuSize`'s height** for titled
   context menus (`src/app/render.zig:2536`).
7. ✅ **Anchor the palette box on open** and let only the list shrink
   (`picker.placeWith` / `overlay.place`).
8. ⬜ **Backport vim #3, #10 and #11 to the Rust `mnml`** — all three
   carried "Rust: same/identical" in the report and only Zig was fixed,
   so the Rust editor is now the wrong one on each.

## Two harness traps worth recording

Neither is a finding; both produced a false green during this pass.
**Both are closed on `hunt-fixes` (2026-09-20)** — what follows is the
diagnosis that led there.

**A path list passed unquoted to the runner reports success having run
nothing.** `./zig-out/bin/mnml-zig test $paths` with 44 paths in the
variable is one argument in zsh. The runner read the joined string as a
directory, found no `.test` files in it, and printed `0/0 passed` —
exit **0**. Word-splitting the same list gave `44/44 passed`. Any CI or
agent script that builds a path list this way is green by construction.

**A shipped regression test can miss the crash it was written for.**
`tests/e2e/http_directives_not_body.test` sends to a closed port
(`127.0.0.1:1`), so `sendInner`'s `sendBodyUnflushed` assert — the actual
SEV-1 crash site in `api-http-send-get-with-body-crashes-process` — is
never reached by it. The fix is real (re-verified against a live `serve`
echo server, both the directives case and a plain literal body), but the
shipped test alone was not evidence for it.

A third, smaller one: `vscode-gitignore-append-defeats-negation` was
first "verified" vacuously because macOS has no `timeout` binary, so the
launch under test never ran. It was re-done with a negative control
proving the writer fires.

## Provenance

- Corpus: `mnml-zig test tests/e2e` — **668/668 passed**, one file
  skipped as network opt-in (669 files).
- Every `fixed-since` verdict resting on a passing script was
  break-checked: the expectation inverted, the break confirmed present
  in the file, the runner watched to fail on that line.
- 43 of the 81 per-finding findings were re-derived independently from
  the finding's own repro steps rather than accepting the shipped
  regression test; the rest rest on that test, and the tables above say
  which is which.
- No live service was contacted except the local `serve` fixture, and no
  real workspace, repo, ticket or person appears in this file or in any
  committed script.

## Appendix — every finding

`re-derived` means a script written from the finding's own repro steps,
asserting its own "Expected", independent of whatever regression test
shipped with the fix. `test` means the verdict rests on that shipped
regression test, which passes. Both were break-checked.

### `nvchad` + `nvchad2` — 45 findings

Re-derived independently (21):

| finding | sev | status | evidence |
|---|---|---|---|
| `nvchad-count-dot-repeat-corrupts` | 2 | fixed-since | `3ddb205` — `3.` after `cwPAPA` leaves no `PAPPAP` |
| `nvchad-x-does-not-set-register` | 2 | fixed-since | `1f132b3` — `lx` then `p` pastes; `:reg` not empty |
| `nvchad-dd-on-closed-fold` | 2 | fixed-since | `1671c9d` — `gg zc dd` removes all 8 fold lines |
| `nvchad-j-enters-closed-fold` | 2 | fixed-since | `1671c9d` — `gg zc j` → line 9, `k` → line 1 |
| `nvchad-undo-granularity` | 3 | fixed-since | `2376e20` — one `u` restores the file exactly |
| `nvchad-w-bang-cmd-writes-file` | 2 | fixed-since | `ba063a8` — `:w !wc -l` pipes, no `!`-named file |
| `nvchad-equals-operator-silent` | 3 | fixed-since | `a4be20a` — `==` restores indent, not a no-op |
| `nvchad-no-autoindent` | 2 | fixed-since | `0828358` — `:set autoindent` then `o`/`O` indent |
| `nvchad-macro-register-hidden` | 3 | fixed-since | `139dde4` — `:reg a` shows it, `"ap` pastes it |
| `nvchad-leader-second-key-eaten` | 2 | fixed-since | `155f734` — tail key never runs as a motion |
| `nvchad-leader-second-key-eaten-regressed` | 2 | fixed-since | `07c02f6`→`b8e53433` — menu leaves fire at speed |
| `nvchad-ctrl-o-opens-picker-in-insert` | 2 | fixed-since | `16ce092` — `A` `Ctrl-O` `0` stays INSERT |
| `nvchad-vsplit-clones-buffer` | 2 | fixed-since | branch `split-buffers` — no pane reports stale `dirty` |
| `nvchad2-visual-p-empty-register-deletes` | 2 | fixed-since | `fa23266`→`1b0bdc6e` — `Vjjp` loses no lines |
| `nvchad2-dd-last-line-cursor-past-eof` | 2 | fixed-since | `e549928`→`6f769296` — `Gdd` → line 8, `ddp` adds no blank |
| `nvchad2-global-not-one-undo-block` | 2 | fixed-since | `782e27e`→`2fc53664` — one `u` removes every `;` |
| `nvchad2-ctrl-w-from-tree-noop` | 2 | fixed-since | `6168280`→`2f829508` — asserted on `status.focus` |
| `nvchad2-marks-not-adjusted-on-edit` | 2 | fixed-since | `ae7bee7`→`8a3abc6d` — mark tracks inserts and deletes |
| `nvchad2-count-p-interleaves` | 2 | fixed-since | `b042377`→`ce2e9a03` — `2yy3p` pastes in sequence |
| `nvchad2-visual-ctrl-a-pending-a` | 2 | fixed-since | `6d427ca`→`d7b1d5b2` — increments and returns to NORMAL |
| `nvchad2-dip-eof-leaves-blank-line` | 2 | fixed-since | `1465ffe`→`804e4710` — `G dip` leaves no stray line |

Verified by the shipped regression test (23), all `fixed-since`:

| finding | sev | test |
|---|---|---|
| `nvchad-b-N-unknown` | 2 | `vim_b_switch` |
| `nvchad-count-gt-ignored` | 2 | `vim_count_gt` |
| `nvchad-ctrl-b-toggles-tree` | 2 | `vim_ctrl_b_pages_back` |
| `nvchad-ctrl-h-cannot-reach-tree` | 2 | `vim_ctrl_h_into_tree` |
| `nvchad-ctrl-w-o-closes-buffers` | 2 | `vim_ctrl_w_o_only_window` |
| `nvchad-dot-no-repeat-visual` | 3 | `vim_dot_visual` |
| `nvchad-ex-verbs-unknown` | 3 | `vim_ex_verbs` |
| `nvchad-phantom-last-line` | 3 | `vim_no_phantom_line` |
| `nvchad-tab-switch-toast-pileup` | 3 | `vim_tab_switch_toast` |
| `nvchad-vblock-dollar-append` | 2 | `vim_vblock_dollar_append` |
| `nvchad2-case-linewise-cursor-drift` | 2 | `vim_case_linewise_cursor` |
| `nvchad2-ci-quote-before-first-quote` | 2 | `vim_ci_quote_forward` |
| `nvchad2-cmdline-ctrl-v-not-literal` | 3 | `vim_cmdline_ctrl_v_literal` |
| `nvchad2-ctrl-a-hex-and-leading-zeros` | 3 | `vim_ctrl_a_hex_zeros` |
| `nvchad2-global-norm-toast-per-line` | 3 | `vim_global_norm_one_toast` |
| `nvchad2-gv-always-charwise` | 2 | `vim_gv_mode` |
| `nvchad2-mark-motion-drops-operator` | 2 | `vim_operator_to_mark` |
| `nvchad2-qA-append-not-recognized` | 3 | `vim_macro_append_upper` |
| `nvchad2-search-offset-taken-literally` | 3 | `vim_search_offset` |
| `nvchad2-tabmove-resize-unknown` | 3 | `vim_tabmove_resize` |
| `nvchad2-v-message-every-line` | 3 | `vim_vglobal_every_line` |
| `nvchad2-zf-normal-acts-as-zc` | 3 | `vim_zf_operator` |
| `nvchad2-zj-into-closed-fold` | 2 | `vim_zj_zk` |

Plus `nvchad2-vblock-cursor-past-eol-short-line` (2) — **by-design**, see above.

### `vscode` + `vscode2` + `api` + `multilang` — 36 findings

Re-derived independently (22):

| finding | sev | status | evidence |
|---|---|---|---|
| `api-http-send-get-with-body-crashes-process` | 1 | fixed-since | live `serve` echo: GET+body and GET+directives both send, no abort |
| `api-http-directives-leak-into-request-body` | 1 | fixed-since | wire body empty; no `@assert`/`@capture` on the wire |
| `api-cookies-dropped-across-redirect` | 2 | fixed-since | both `Set-Cookie` ride the 302 to the next hop |
| `vscode2-grep-long-line-panic` | 1 | fixed-since | 545k line, match late — no overflow |
| `vscode-git-graph-detail-panic` | 1 | fixed-since | the finding's own drive (graph, down, enter) ×2 commits |
| `vscode-delete-dialog-enter-cancels-silently` | 3 | **fixed (this branch)** | the cancel toasts and names the key that deletes |
| `vscode2-files-trash-stacks-tabs-and-leaks-data-root` | 3 | fixed-since | no twin tab; `files.up` stays in Trash, no `.index.zon` |
| `vscode-tree-ctrl-shift-d-duplicates-file` | 2 | fixed-since | on a directory row: no data-copy, DEBUG opens |
| `multilang-project-todos-command-dead` | 2 | fixed-since | lists a `.py` TODO and a `.ts` FIXME |
| `multilang-close-split-noop-sole-pty-pane` | 2 | fixed-since | sole running and sole exited pty both close |
| `vscode-new-note-prefill-appends` | 2 | fixed-since | disk-level: no `note-1.mdzznote` |
| `vscode2-findings-new-bare-name-twin` | 2 | fixed-since | disk-level: exactly one file, no extension-less twin |
| `vscode2-grep-prompt-prefill-appends` | 2 | fixed-since | seed replaced by typing; no concatenation |
| `vscode2-files-open-split-adds-two-panes` | 3 | fixed-since | no third pane hiding on the first strip |
| `vscode2-documented-commands-not-implemented` | 3 | fixed-since | structural: 1099/1101 ids resolve; the 2 are deliberate specials |
| `vscode-gitignore-append-defeats-negation` | 2 | fixed-since | negation rules untouched; negative control proves the writer fires |
| `vscode-ctrl-slash-drops-multiline-selection` | 2 | fixed-since | disk-level: 2 presses restore byte-for-byte |
| `vscode-ctrl-s-swallowed-by-find-bar-and-palette` | 2 | fixed-since | saves from inside the find bar and from the palette |
| `vscode2-dock-drop-on-full-corner-hides-widget` | 2 | fixed-since | all three widgets paint; `dock.close_all` reports 3 |
| `vscode2-ctrl-q-abandons-transfer` | 2 | fixed-since | 4000-file copy refused the quit, then landed 4000/4000 |
| `multilang-lsp-list-pickers-silent-noop` | 1 | fixed-since | real `typescript-language-server`: 4 refs across 2 files |
| `vscode-settings-chip-click-only-focuses` | 2 | fixed-since | the stepper `‹ ›` pages the Theme row both ways |

Verified by the shipped regression test (13), all `fixed-since`:

| finding | sev | test |
|---|---|---|
| `multilang-worktree-add-no-path-autocomplete` | 3 | `git_worktree_add_tab` |
| `vscode-f2-in-tree-is-lsp-rename` | 2 | `tree_f2_rename` |
| `vscode-find-bar-enter-closes-widget` | 3 | `vscode_find_enter_stays_open` |
| `vscode-settings-rows-clip-choices` | 3 | `settings_row_window` |
| `vscode-settings-wheel-does-not-scroll` | 3 | `settings_wheel` |
| `vscode-split-divider-lands-one-column-left` | 3 | `split_divider_lands_on_pointer` |
| `vscode-toast-menu-drawn-under-toast` | 2 | `toast_menu_fits` |
| `vscode2-files-mark-hidden-under-cursor` | 3 | `files_mark_under_cursor` |
| `vscode2-files-pane-no-external-refresh` | 3 | `files_external_refresh` |
| `vscode2-plus-menu-kebab-hit-misaligned` | 3 | `plus_menu_kebab` |
| `vscode2-tab-strip-overflow-no-indicator` | 3 | `tab_strip_overflow` |
| `vscode2-tree-f2-esc-drops-tree-focus` | 3 | `tree_rename_esc_focus` |
| `vscode2-tree-menu-lacks-clipboard-rows` | 3 | `tree_menu_clipboard` |

Plus `multilang-http-history-commands-noop` (2) — **by-design**, see above.

### `hunt-standard-2026-09-09` — 21 findings

| # | sev | status | evidence |
|---|---|---|---|
| 1 | 2 | fixed / **fixed (this branch)** | Esc-Esc + corner exit leave zen (`995320e0`, `4038fc51`); `ctrl+k z` reaches `view.fullscreen` again |
| 2 | 2 | fixed-since | `8c67ebf1` — a pending chord owns the next key; URL not corrupted |
| 3 | 2 | fixed-since | click after `down` opens the right row; break-check fails |
| 4 | 2 | fixed-since | `5637e40c` — wrapped-row clicks give col 13 / 95, the finding's expected |
| 5 | 2 | fixed-since | `aa7b9d14` — every pane kind splits; no `NotAnEditor` |
| 6 | 2 | fixed-since | `5637e40c` — the whole gutter toggles, not just column 0 |
| 7 | 2 | fixed-since | `4c7a7567` — `f5` continue, `shift+f5` terminate |
| 8 | 2 | fixed-since | `954d7b89` — the globe opens a pane |
| 9 | 2 | fixed-since | Welcome paints; it is an overlay, which is why `panes` never changed |
| 10 | 3 | **fixed (this branch)** | `menuSize` is `rows + 2`; the title lives in the border |
| 11 | 3 | fixed-since | `d833b671` — the `»` list is a dropdown, so its cursor shows |
| 12 | 3 | **fixed (this branch)** | the chip is pulled back against the chevrons; it paints on any overflow |
| 13 | 3 | fixed / **fixed (this branch)** | Info panel fixed (`14cb7d9b`); the overlay's header is the active profile's leader |
| 14 | 3 | by-design / **fixed (this branch)** | wheel is Rust parity (`dispatch.zig:1979`); the box anchors on open |
| 15 | 3 | fixed-since | `1b958a17` — one press on a COLLECTIONS row opens it |
| 16 | 3 | fixed-since | `f72f6b62` — the chips moved to their own box |
| 17 | 3 | fixed-since | `tests/e2e/tab_drag_into_split` — edge drop splits, centre drop joins |
| 18 | 3 | by-design | Rust's chip spawns at once; no confirm key on either side |
| 19 | 3 | fixed-since | `74d47e4e` — rows were always registered, now labelled per overlay |
| 20 | 3 | cannot-reproduce | `panes` is built strictly from `app.panes.slots`; now `[]` |
| 21 | 3 | cannot-reproduce | scripted stage/unstage/stage leaves no `error:` on screen |

### `hunt-vim-2026-09-09` — 22 findings + 2 seen-once

| # | sev | status | evidence |
|---|---|---|---|
| 1 | **1** | fixed-since | `c1c47608` — `lsp.zig:1872` clamps the cursor and closes the popup |
| 2 | 2 | fixed-since | `3dcd019a` atomic WorkspaceEdit + `9e3ece6f` gates `onTyped` |
| 3 | 2 | fixed-since | `93cf4746` — the visual range covers the cursor's line, mode leaves |
| 4 | 2 | fixed-since | `8b66f8a8` — `>` / `<` land on the range's first non-blank |
| 5 | 2 | fixed-since | `d40d6824` + `50c5bad4` — unbound leader tails are swallowed |
| 6 | 2 | fixed-since | `344d5d5e` — a pane opened from a file starts browsing |
| 7 | 2 | fixed-since | `2b33721b` — terminal-normal mode; no double dispatch |
| 8 | 2 | fixed-since | `b5ab1971` — `shownElsewhere()` keeps shared panes |
| 9 | 2 | fixed-since | `acd70491` — `<leader>e` focuses, `<C-n>` toggles |
| 10 | 2 | fixed-since | `e5b629ff` — `}` stops at the adjacent blank |
| 11 | 2 | fixed-since | `e5b629ff` — a Normal cursor never rests past the line end |
| 12 | 3 | fixed-since | `c59db8c0` — nvim-tree's `a r d x R E W` |
| 13 | 3 | fixed-since (6/7) | `4242bdbe` binds `ra ca gt cm fo fz`; `th` is by-design |
| 14 | 3 | fixed-since | `50c362a1` — `j`/`k` move the references list |
| 15 | 3 | fixed-since | `1bb44586` — `lsp_fake_hover` asserts the markdown is rendered |
| 16 | 3 | fixed-since | `f291fa9e` — `vim.zig:908` routes `s` to the sentence objects |
| 17 | 3 | fixed-since | `a8dde351` — `Ctrl-W t` / `b` / `p` |
| 18 | 3 | fixed-since | `<leader>tf` enters, Esc Esc leaves; the `.standard`-only row is per `KEYMAP_PROFILES.md:34` |
| 19 | 3 | fixed-since | `28b2632e` — `u` lands on the restored text |
| 20 | 3 | fixed-since | `ex q` leaves `"panes":[]` |
| 21 | 3 | fixed-since | `f573a8bb` — a second Tab descends into the one directory match |
| 22 | 3 | **fixed (this branch)** | `session.zig:261` still saves ptys; `:621` restores them dormant |
| once A | — | fixed-since | `b5fcbcfe` — `acceptsGhost()` guards both accept and fetch |
| once B | — | by-design | `headless.zig:88` emits `signal` only for SIGTERM/INT/HUP — an external kill |
